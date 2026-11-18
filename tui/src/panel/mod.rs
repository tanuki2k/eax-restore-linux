//! The game panel: everything for one game on one screen. Its status, every
//! choice an install takes, its own settings, then one action, which runs
//! inside the TUI (`run`). State and keys only; `view` draws it.

pub mod run;
pub mod view;

use crate::db::Game;
use crate::engine::apply::RevertGroup;
use crate::engine::game_settings::{Category, Fix, Purpose, Status};
use crate::engine::install::{Engine, Override, Plan, Vcrun};
use crate::engine::installed::{Installed, OverrideKind};
use crate::engine::launcher::changes::{self, LogLevel};
use crate::engine::launcher::target::Launcher;
use crate::engine::ops;
use crate::engine::prepare::{self, Facts};
use crate::engine::speakers::{Layout, Listening, Speakers};
use crate::engine::uninstall::{self, Choices, Location, Surveyed};
use ratatui::crossterm::event::{KeyCode, KeyEvent};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

/// One value a row can take, and a sentence about it.
#[derive(Debug, Clone)]
pub struct Opt {
    pub label: String,
    pub help: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Engine,
    DsoalBuild,
    OpenalBuild,
    Speakers,
    /// The profile's alsoft.ini values.
    Profile,
    Override,
    Vcrun,
    Arch,
    Com,
    Limits,
    EaxUnified,
}

#[derive(Debug, Clone)]
pub struct Row {
    pub kind: RowKind,
    pub title: &'static str,
    pub options: Vec<Opt>,
    pub chosen: usize,
    /// What it was when the panel opened: the installed choice, or the default.
    pub original: usize,
    /// The opening value came from this PC or the game's profile, not a
    /// default; shown as "(detected)" until it's changed.
    pub detected: bool,
    /// A key per option, for rows whose options can change while the page
    /// is open (the build lists); empty for the others.
    pub keys: Vec<String>,
}

/// One numbered box of choices, in the order the script asks them.
#[derive(Debug, Clone)]
pub struct Section {
    pub title: &'static str,
    pub rows: Vec<Row>,
}

impl Row {
    fn new(kind: RowKind, title: &'static str, options: Vec<(&str, &str)>, chosen: usize) -> Self {
        Row {
            kind,
            title,
            options: options
                .into_iter()
                .map(|(l, h)| Opt {
                    label: l.into(),
                    help: h.into(),
                })
                .collect(),
            chosen,
            original: chosen,
            detected: false,
            keys: Vec::new(),
        }
    }
    fn detected(mut self, yes: bool) -> Self {
        self.detected = yes;
        self
    }
    /// Shown as detected: it came from the PC or profile and wasn't changed.
    pub fn shows_detected(&self) -> bool {
        self.detected && !self.changed()
    }
    pub fn value(&self) -> &str {
        &self.options[self.chosen].label
    }
    fn changed(&self) -> bool {
        self.chosen != self.original
    }
}

/// The speaker setups the panel offers, in its order.
pub fn speaker_choices() -> Vec<(&'static str, &'static str, Speakers)> {
    vec![
        (
            "Headphones, with 3D positioning",
            "Sounds come from all around you, including above and below.",
            Speakers::stereo(Listening::Headphones, true),
        ),
        (
            "Headphones, without 3D positioning",
            "Plain stereo for headphones.",
            Speakers::stereo(Listening::Headphones, false),
        ),
        (
            "Two speakers",
            "Two speakers in front of you.",
            Speakers::stereo(Listening::Speakers, false),
        ),
        (
            "Stereo, detects headphones or speakers",
            "Leaves it to the sound engine to work out what you're listening on.",
            Speakers::stereo(Listening::Auto, true),
        ),
        (
            "Pro Logic surround sound",
            "Stereo that a receiver or soundbar decodes into surround.",
            Speakers::matrix(),
        ),
        (
            "4.0 surround sound",
            "Front left and right, rear left and right.",
            Speakers::surround(Layout::Quad),
        ),
        (
            "5.1 surround sound",
            "Front left, centre and right, two surrounds and a subwoofer.",
            Speakers::surround(Layout::Surround51),
        ),
        (
            "6.1 surround sound",
            "5.1 plus a rear centre speaker.",
            Speakers::surround(Layout::Surround61),
        ),
        (
            "7.1 surround sound",
            "5.1 plus rear left and right speakers.",
            Speakers::surround(Layout::Surround71),
        ),
    ]
}

/// The panel's name for a speaker setup, or the engine's for one it doesn't offer.
pub fn speakers_label(s: &Speakers) -> String {
    speaker_choices()
        .into_iter()
        .find(|(_, _, x)| x == s)
        .map_or_else(|| s.label(), |(l, _, _)| l.to_string())
}

/// What has focus: a row, a game setting, or a button.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Item {
    /// (section, row) in [`Panel::sections`].
    Choice(usize, usize),
    Setting(usize),
    Button(Button),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    Install,
    Apply,
    Uninstall,
    SoundLog,
    CheckAgain,
    // On the confirm and uninstall screens.
    Confirm,
    Back,
    KeepSettings,
    KeepOverride,
    RemoveVcrun,
}

/// A job for the worker.
#[derive(Debug, Clone)]
pub enum Job {
    /// An install or reinstall; then put back the settings unticked.
    Install {
        plan: Box<Plan>,
        revert: Vec<RevertGroup>,
        /// Every audio setting is on, so the game's own EAX switch needs no
        /// step at the end.
        audio_done: bool,
    },
    Speakers(Speakers),
    Settings {
        revert: Vec<RevertGroup>,
        plan: Vec<crate::engine::game_settings::PlanRow>,
    },
    SoundLog(Option<LogLevel>),
    Uninstall {
        survey: Box<uninstall::Survey>,
        choices: Box<Choices>,
    },
}

/// The uninstall screen's choices.
#[derive(Debug, Clone)]
pub struct UninstallView {
    pub survey: Box<uninstall::Survey>,
    pub put_back_settings: bool,
    pub keep_override: bool,
    pub remove_vcrun: bool,
}

pub enum Screen {
    Main,
    /// What Install or Apply will do, and the jobs that do it.
    Confirm {
        /// The box's title: "Install" or "Apply changes".
        title: &'static str,
        /// The line above the list.
        heading: String,
        lines: Vec<(String, String)>,
        jobs: Vec<Job>,
    },
    Uninstall(UninstallView),
    Run(run::RunView),
}

/// A yes/no question asked over the panel.
pub struct Question {
    pub text: String,
    pub ask: String,
    /// Where the answer goes: the worker, or the panel itself.
    pub to: Asker,
}

pub enum Asker {
    Worker,
    /// Leaving with choices not applied.
    Leave,
}

pub struct Panel {
    pub name: String,
    pub facts: Facts,
    pub game: Option<Game>,
    pub installed: Option<Installed>,
    /// A Linux build or a missing prefix: there's nothing to choose yet.
    pub problem: Option<String>,
    pub sections: Vec<Section>,
    /// Audio settings first, then optional ones, as the page lists them.
    pub fixes: Vec<Fix>,
    pub ticked: HashSet<String>,
    pub ticked_before: HashSet<String>,
    pub focus: usize,
    /// The open list of the focused row's values, and its highlight.
    pub list: Option<usize>,
    /// The first line of that list that shows, when it's too long to fit.
    pub list_top: std::cell::Cell<usize>,
    pub screen: Screen,
    pub question: Option<Question>,
    pub sound_log_on: bool,
    /// The panel asked to close; the app drops it.
    pub closed: bool,
    /// Something was changed on disk, so the game list needs reading again.
    pub changed_disk: bool,
    /// When the Status box started typing itself out; None once it's shown
    /// in full (or with EAX_RESTORE_NO_ANIMATION).
    pub reveal: Option<Instant>,
    /// How far the right column's game profile is scrolled.
    pub info_scroll: u16,
    /// Where the focused choice's field was last drawn, so its list opens
    /// under it like a dropdown.
    pub field: std::cell::Cell<Option<ratatui::layout::Rect>>,
    pub(crate) home: PathBuf,
    untested: bool,
    /// The player's defaults for a new install, from the settings screen.
    pub prefs: crate::prefs::Prefs,
    /// The build lists and the versions the "Latest" options stand for,
    /// while they're looked up, then once they're here.
    builds_rx: Option<Receiver<crate::build_choice::BuildInfo>>,
    pub build_info: Option<crate::build_choice::BuildInfo>,
    /// The DSOAL build row while the audio engine is OpenAL Soft on its own,
    /// which doesn't use DSOAL; it comes back as it was if DSOAL is chosen.
    dsoal_row: Option<Row>,
}

/// One line of the Status box: fine, or a problem worth a look.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusLine {
    pub ok: bool,
    pub label: &'static str,
    pub value: String,
}

/// The pause before each Status line and the time per character it types.
const LINE_PAUSE_MS: u64 = 60;
const CHAR_MS: u64 = 3;

impl Panel {
    /// Looks at the game folder and everything around it, as the headless
    /// commands do.
    pub fn open(name: &str, dir: &Path, game: Option<Game>, home: &Path) -> Self {
        let pt = crate::cli::protontricks();
        // A library hands over the install's top folder; the game's files
        // go next to its exe, which can be folders below it.
        let (dir, _) =
            crate::engine::detect::exe_folder(dir, game.as_ref().map_or("", |g| g.exe.as_str()));
        let facts = prepare::gather(&dir, game.as_ref(), home, &pt);
        let installed = Installed::read(&facts.game_dir, home);
        let name = game
            .as_ref()
            .map_or_else(|| name.to_string(), |g| g.name.clone());
        let animate = !cfg!(test)
            && std::env::var("EAX_RESTORE_NO_ANIMATION").map_or(true, |v| v.is_empty() || v == "0");
        let mut p = Panel {
            name,
            facts,
            game,
            installed,
            problem: None,
            sections: Vec::new(),
            fixes: Vec::new(),
            ticked: HashSet::new(),
            ticked_before: HashSet::new(),
            focus: 0,
            list: None,
            list_top: std::cell::Cell::new(0),
            screen: Screen::Main,
            question: None,
            sound_log_on: false,
            closed: false,
            changed_disk: false,
            reveal: animate.then(Instant::now),
            info_scroll: 0,
            field: std::cell::Cell::new(None),
            home: home.to_path_buf(),
            untested: ops::untested_from_env(),
            // Tests start from the shipped defaults, whatever this PC saved.
            prefs: if cfg!(test) {
                crate::prefs::Prefs::default()
            } else {
                crate::prefs::Prefs::load()
            },
            dsoal_row: None,
            // Tests fill the lists in themselves rather than ask GitHub.
            builds_rx: (!cfg!(test)).then(|| crate::build_choice::spawn(home.to_path_buf())),
            build_info: None,
        };
        p.build();
        p
    }

    /// The Status box: where the game is, what's installed, and what was
    /// found around it. A line that isn't `ok` is a problem the page knows of.
    pub fn status_lines(&self) -> Vec<StatusLine> {
        let f = &self.facts;
        let line = |ok, label, value: String| StatusLine { ok, label, value };
        let folder = crate::library::tilde(&f.game_dir, &self.home);
        let wanted = &f.exe_hint;
        let mut out = vec![match &f.exe {
            Some(e) if wanted.is_empty() || e.eq_ignore_ascii_case(wanted) => line(
                true,
                "Game",
                crate::library::tilde(&f.game_dir.join(e), &self.home),
            ),
            _ if !wanted.is_empty() => line(false, "Game", format!("{wanted} isn't in {folder}")),
            _ => line(false, "Game", format!("Couldn't find an .exe in {folder}")),
        }];
        if self.installed.is_some() {
            out.push(line(true, "Installed", view::status_line(self)));
        }
        for (ok, label, value) in f.summary(&self.home) {
            out.push(line(ok, label, value));
        }
        out
    }

    /// How long each Status line takes to type out, in order.
    fn reveal_times(&self) -> Vec<Duration> {
        self.status_lines()
            .iter()
            .map(|l| {
                let chars = (l.label.chars().count() + l.value.chars().count()) as u64;
                Duration::from_millis(LINE_PAUSE_MS + CHAR_MS * chars)
            })
            .collect()
    }

    /// While the Status box is still typing: how many lines are done, and how
    /// many characters of the next one show. None once it's all shown.
    pub fn revealed(&self) -> Option<(usize, usize)> {
        let start = self.reveal?;
        let mut t = start.elapsed();
        for (i, d) in self.reveal_times().into_iter().enumerate() {
            if t < d {
                let typed = t.saturating_sub(Duration::from_millis(LINE_PAUSE_MS));
                return Some((i, (typed.as_millis() / u128::from(CHAR_MS)) as usize));
            }
            t -= d;
        }
        None
    }

    pub fn revealing(&self) -> bool {
        self.revealed().is_some()
    }

    /// Something on the page moves by itself: the work's progress, the
    /// Status box typing, or the build lists still on their way.
    pub fn animating(&self) -> bool {
        self.running() || self.revealing() || self.builds_rx.is_some()
    }

    fn build(&mut self) {
        let f = &self.facts;
        let name = &self.name;
        self.problem = if f.linux_build && self.installed.is_none() {
            Some(format!("{name} is installed as its Linux version, which the EAX fix can't work with. Switch it to the Windows version in its launcher, then check again."))
        } else if f.prefix.is_none() && self.installed.is_none() {
            Some(format!("{name} doesn't have a Wine prefix yet. If you just installed {name}, its launcher creates it the first time it runs. Please launch the game at least once, close it, and check again."))
        } else {
            None
        };
        let st = self.installed.as_ref().map(|i| i.state.clone());
        let plan = f.default_plan();

        let installed = self.installed.is_some();
        let engine = st.as_ref().map_or(plan.engine, |s| s.engine);
        let mut sound = vec![Row::new(
            RowKind::Engine,
            "Audio engine",
            vec![
                (
                    "DSOAL with OpenAL Soft",
                    "For a game that plays its sound through DirectSound3D.",
                ),
                (
                    "OpenAL Soft",
                    "For a game that plays its sound through OpenAL.",
                ),
            ],
            usize::from(engine == Engine::OpenAlSoft),
        )
        .detected(installed || f.profile_api.is_some() || f.files_api.is_some())];
        let prefs = self.prefs.clone();
        let start = |pref: &crate::prefs::BuildPref| {
            if installed {
                crate::build_choice::KEEP.to_string()
            } else {
                pref.0.clone()
            }
        };
        let (dsoal_at, openal_at) = (start(&prefs.dsoal_build), start(&prefs.openal_build));
        let mut d = Row::new(RowKind::DsoalBuild, "DSOAL build", Vec::new(), 0).detected(installed);
        let mut o =
            Row::new(RowKind::OpenalBuild, "OpenAL Soft build", Vec::new(), 0).detected(installed);
        self.fill_build_row(&mut d, &dsoal_at, &dsoal_at);
        self.fill_build_row(&mut o, &openal_at, &openal_at);
        sound.push(d);
        sound.push(o);
        let current = self
            .installed
            .as_ref()
            .and_then(Installed::speakers)
            .unwrap_or_else(|| {
                if installed {
                    plan.speakers
                } else {
                    speaker_choices()[prefs.speakers.index()].2
                }
            });
        let mut sp: Vec<(String, String)> = speaker_choices()
            .into_iter()
            .map(|(l, h, _)| (l.to_string(), h.to_string()))
            .collect();
        let at = speaker_choices()
            .iter()
            .position(|(_, _, s)| *s == current)
            .unwrap_or_else(|| {
                sp.push((current.label(), "The setup the game has now.".into()));
                sp.len() - 1
            });
        let speakers_found = self
            .installed
            .as_ref()
            .and_then(Installed::speakers)
            .is_some();
        let mut sprow =
            Row::new(RowKind::Speakers, "Speakers", Vec::new(), at).detected(speakers_found);
        sprow.options = sp
            .into_iter()
            .map(|(label, help)| Opt { label, help })
            .collect();
        sound.push(sprow);
        if let Some(g) = &self.game {
            let values = ops::alsoft_values(g, self.untested);
            if !values.is_empty() && self.installed.is_none() {
                let list: Vec<String> = values
                    .iter()
                    .map(|(s, k, v)| format!("{s} {k} = {v}"))
                    .collect();
                let help = format!("The game's profile sets {} in alsoft.ini.", list.join(", "));
                let mut r = Row::new(
                    RowKind::Profile,
                    "Profile's sound values",
                    vec![("Use them", ""), ("Leave them out", "")],
                    0,
                )
                .detected(true);
                r.options[0].help = help.clone();
                r.options[1].help = help;
                sound.push(r);
            }
        }

        let mut over: Vec<(String, String)> = Vec::new();
        if let Some(t) = &f.launcher {
            let (l, h) = match t.launcher {
                Launcher::Steam => (
                    "Steam's launch options",
                    "Adds WINEDLLOVERRIDES to the game's launch options in Steam.",
                ),
                Launcher::Heroic => (
                    "Heroic's environment variables",
                    "Adds WINEDLLOVERRIDES to the game's environment variables in Heroic.",
                ),
            };
            over.push((l.into(), h.into()));
        }
        over.push((
            "The prefix's registry".into(),
            "Sets the override in the game's Wine prefix.".into(),
        ));
        over.push((
            "I'll set it myself".into(),
            "Shows the line to add yourself.".into(),
        ));
        let has_launcher = f.launcher.is_some();
        let over_at = match st.as_ref().map(|s| s.over) {
            Some(OverrideKind::Launcher) if has_launcher => 0,
            Some(OverrideKind::Registry) => usize::from(has_launcher),
            Some(OverrideKind::Manual) => usize::from(has_launcher) + 1,
            _ if installed => match plan.over {
                Override::Launcher(_) => 0,
                Override::Registry => usize::from(has_launcher),
                Override::Manual => usize::from(has_launcher) + 1,
            },
            // A new install starts on the player's default; launch options
            // fall back to the registry when there's no launcher to use.
            _ => match prefs.over {
                crate::prefs::OverridePref::LaunchOptions => 0,
                crate::prefs::OverridePref::Registry => usize::from(has_launcher),
                crate::prefs::OverridePref::Manual => usize::from(has_launcher) + 1,
            },
        };
        // Where the override goes is the page's choice, not something read
        // from the game, so it's never shown as detected.
        let mut orow = Row::new(RowKind::Override, "DLL override", Vec::new(), over_at);
        orow.options = over
            .into_iter()
            .map(|(label, help)| Opt { label, help })
            .collect();
        let mut setup = vec![orow];
        let vc = if f.vcrun_present || st.as_ref().is_some_and(|s| s.vcrun) {
            Row::new(
                RowKind::Vcrun,
                "VC++ runtime",
                vec![
                    (
                        "Already there",
                        "Tells Wine to use Microsoft's VC++ files the prefix already has.",
                    ),
                    ("Leave it alone", "Doesn't touch the VC++ runtime."),
                ],
                usize::from(!installed && prefs.vcrun == crate::prefs::VcPref::LeaveAlone),
            )
            .detected(true)
        } else {
            Row::new(
                RowKind::Vcrun,
                "VC++ runtime",
                vec![
                    (
                        "Skip",
                        "Some builds need Microsoft's VC++ runtime; most games run without it.",
                    ),
                    (
                        "Install it",
                        "Installs Microsoft's VC++ 2022 runtime into the prefix.",
                    ),
                ],
                usize::from(!installed && prefs.vcrun == crate::prefs::VcPref::InstallIfMissing),
            )
        };
        setup.push(vc);
        let arch = st.as_ref().and_then(|s| s.arch).unwrap_or(plan.arch);
        setup.push(
            Row::new(
                RowKind::Arch,
                "Architecture",
                vec![
                (
                    "32-bit",
                    "The game's .exe is 32-bit, and 64-bit files would crash it without an error.",
                ),
                (
                    "64-bit",
                    "The game's .exe is 64-bit, and 32-bit files would crash it without an error.",
                ),
            ],
                usize::from(arch == 64),
            )
            .detected(st.as_ref().and_then(|s| s.arch).is_some() || f.arch.is_some()),
        );
        setup.push(Row::new(
            RowKind::Com,
            "COM routing",
            vec![
                ("Off", "Most games load DirectSound straight from its file."),
                (
                    "On",
                    "For a game that asks Windows for DirectSound by name instead of loading the file.",
                ),
            ],
            usize::from(st.as_ref().is_some_and(|s| s.com_routing)),
        )
        .detected(installed));
        setup.push(
            Row::new(
                RowKind::Limits,
                "More sounds at once",
                vec![
                    ("Off", "The usual number of sounds."),
                    (
                        "On",
                        "Lets the game play up to 256 sounds at once, at 48 kHz.",
                    ),
                ],
                usize::from(st.as_ref().is_some_and(|s| s.advanced_limits)),
            )
            .detected(installed),
        );
        if f.wants_eax_unified || st.as_ref().is_some_and(|s| s.eax_unified) {
            setup.push(
                Row::new(
                    RowKind::EaxUnified,
                    "EAX Unified",
                    vec![
                        (
                            "Install it",
                            "The game's profile says it needs Creative's EAX Unified.",
                        ),
                        ("Skip", "Leaves it out, so the game may play without EAX."),
                    ],
                    0,
                )
                .detected(true),
            );
        }
        // The script's order: audio engine, runtimes, speakers, tweaks, then
        // the DLL override.
        let mut all: Vec<Row> = sound.into_iter().chain(setup).collect();
        let mut take = |kinds: &[RowKind]| -> Vec<Row> {
            kinds
                .iter()
                .filter_map(|k| {
                    let at = all.iter().position(|r| r.kind == *k)?;
                    Some(all.remove(at))
                })
                .collect()
        };
        let sections = vec![
            Section {
                title: "Audio engine",
                rows: take(&[
                    RowKind::Engine,
                    RowKind::DsoalBuild,
                    RowKind::OpenalBuild,
                    RowKind::Arch,
                    RowKind::Profile,
                ]),
            },
            Section {
                title: "Runtimes",
                rows: take(&[RowKind::Vcrun, RowKind::EaxUnified]),
            },
            Section {
                title: "Speakers",
                rows: take(&[RowKind::Speakers]),
            },
            Section {
                title: "Compatibility tweaks",
                rows: take(&[RowKind::Com, RowKind::Limits]),
            },
            Section {
                title: "DLL override",
                rows: take(&[RowKind::Override]),
            },
        ];
        self.sections = sections
            .into_iter()
            .filter(|s| !s.rows.is_empty())
            .collect();
        self.sound_log_on = f
            .launcher
            .as_ref()
            .is_some_and(|t| changes::log_state(t).on());
        self.dsoal_row = None;
        self.place_dsoal_row();
        self.survey_settings(true);
        self.focus = 0;
    }

    /// The DSOAL and OpenAL Soft versions the game has now, when its install
    /// recorded them.
    pub fn installed_versions(&self) -> (Option<String>, Option<String>) {
        self.installed.as_ref().map_or((None, None), |i| {
            (
                i.state.dsoal_version.clone(),
                i.state.openal_version.clone(),
            )
        })
    }

    /// Sets a build row's options from what's known now, keeping the one
    /// chosen (`chosen`) and the one it opened on (`original`) by key.
    fn fill_build_row(&self, row: &mut Row, chosen: &str, original: &str) {
        use crate::build_choice::{self as bc, Comp};
        let comp = if row.kind == RowKind::DsoalBuild {
            Comp::Dsoal
        } else {
            Comp::Openal
        };
        let (had_dsoal, had_openal) = self.installed_versions();
        let had = if comp == Comp::Dsoal {
            had_dsoal
        } else {
            had_openal
        };
        let saved = [chosen, original]
            .into_iter()
            .find(|k| ![bc::KEEP, bc::ROLLING, bc::NUMBERED, bc::TESTED].contains(k));
        let mut opts = bc::options(comp, self.build_info.as_ref(), saved);
        if self.installed.is_some() {
            opts.insert(0, bc::keep_option(comp, had.as_deref()));
        }
        let at = |key: &str| opts.iter().position(|o| o.key == key).unwrap_or(0);
        row.chosen = at(chosen);
        row.original = at(original);
        row.keys = opts.iter().map(|o| o.key.clone()).collect();
        row.options = opts
            .into_iter()
            .map(|o| Opt {
                label: o.label,
                help: o.help,
            })
            .collect();
    }

    /// The build lists have arrived: fill both build rows in again, keeping
    /// what's chosen.
    pub fn set_build_info(&mut self, info: crate::build_choice::BuildInfo) {
        self.build_info = Some(info);
        let key = |r: &Row, i: usize| r.keys.get(i).cloned().unwrap_or_default();
        let mut rows: Vec<Row> = Vec::new();
        for kind in [RowKind::DsoalBuild, RowKind::OpenalBuild] {
            if let Some(r) = self.row(kind) {
                rows.push(r.clone());
            }
        }
        if let Some(r) = &self.dsoal_row {
            rows.push(r.clone());
        }
        for mut r in rows {
            let (c, o) = (key(&r, r.chosen), key(&r, r.original));
            self.fill_build_row(&mut r, &c, &o);
            let kind = r.kind;
            if let Some(stash) = self.dsoal_row.as_mut().filter(|s| s.kind == kind) {
                *stash = r;
            } else if let Some(slot) = self
                .sections
                .iter_mut()
                .flat_map(|s| s.rows.iter_mut())
                .find(|x| x.kind == kind)
            {
                *slot = r;
            }
        }
    }

    /// Shows the DSOAL build row only while the audio engine uses DSOAL. It
    /// sits under the engine row, which keeps the focus where it is.
    fn place_dsoal_row(&mut self) {
        let dsoal = self.row(RowKind::Engine).is_none_or(|r| r.chosen == 0);
        let Some(sec) = self
            .sections
            .iter_mut()
            .find(|s| s.rows.iter().any(|r| r.kind == RowKind::Engine))
        else {
            return;
        };
        let at = sec.rows.iter().position(|r| r.kind == RowKind::DsoalBuild);
        match (dsoal, at) {
            (false, Some(i)) => self.dsoal_row = Some(sec.rows.remove(i)),
            (true, None) => {
                if let Some(r) = self.dsoal_row.take() {
                    let engine = sec.rows.iter().position(|r| r.kind == RowKind::Engine);
                    sec.rows.insert(engine.map_or(0, |e| e + 1), r);
                }
            }
            _ => {}
        }
    }

    pub fn speakers(&self) -> Speakers {
        let row = self
            .row(RowKind::Speakers)
            .expect("there's always a speakers row");
        match speaker_choices().get(row.chosen) {
            Some((_, _, s)) => *s,
            None => self
                .installed
                .as_ref()
                .and_then(Installed::speakers)
                .unwrap_or_default(),
        }
    }

    fn survey_settings(&mut self, reset: bool) {
        let Some(g) = &self.game else { return };
        let speakers = Some(self.speakers());
        let (purpose, recorded) = match &self.installed {
            Some(i) => (
                Purpose::Edit,
                i.settings.iter().map(|s| s.title.clone()).collect(),
            ),
            None => (Purpose::Install, HashSet::new()),
        };
        self.fixes = ops::survey(&self.facts, g, speakers, purpose, recorded, self.untested)
            .into_iter()
            .filter(Fix::shown)
            .collect();
        self.fixes
            .sort_by_key(|f| u8::from(f.category != Category::Audio));
        if reset {
            self.ticked = self
                .fixes
                .iter()
                .filter(|f| match f.status {
                    Status::Applied => true,
                    Status::Offer => self.installed.is_none() && f.category == Category::Audio,
                    _ => false,
                })
                .map(|f| f.title.clone())
                .collect();
            self.ticked_before = self.ticked.clone();
        }
    }

    pub fn row(&self, kind: RowKind) -> Option<&Row> {
        self.rows().find(|r| r.kind == kind)
    }

    pub fn rows(&self) -> impl Iterator<Item = &Row> {
        self.sections.iter().flat_map(|s| &s.rows)
    }

    pub fn choice(&self, s: usize, r: usize) -> &Row {
        &self.sections[s].rows[r]
    }

    /// A setting that can be ticked: one there's something to switch.
    pub fn tickable(f: &Fix) -> bool {
        matches!(f.status, Status::Offer | Status::Applied)
    }

    pub fn buttons(&self) -> Vec<Button> {
        match &self.screen {
            Screen::Confirm { .. } => vec![Button::Confirm, Button::Back],
            Screen::Uninstall(_) => vec![Button::Confirm, Button::Back],
            Screen::Run(_) => vec![Button::Back],
            Screen::Main if self.problem.is_some() => vec![Button::CheckAgain],
            Screen::Main if self.installed.is_some() => {
                let mut b = vec![Button::Apply, Button::Uninstall];
                if self.facts.launcher.is_some() {
                    b.push(Button::SoundLog);
                }
                b
            }
            Screen::Main => vec![Button::Install],
        }
    }

    /// Everything that can have focus, top to bottom.
    pub fn items(&self) -> Vec<Item> {
        let mut out = Vec::new();
        match &self.screen {
            Screen::Main if self.problem.is_none() => {
                for (si, sec) in self.sections.iter().enumerate() {
                    out.extend((0..sec.rows.len()).map(|ri| Item::Choice(si, ri)));
                }
                out.extend((0..self.fixes.len()).map(Item::Setting));
            }
            Screen::Uninstall(u) => {
                if !u.survey.settings.is_empty() {
                    out.push(Item::Button(Button::KeepSettings));
                }
                if !u.survey.launcher_lines().is_empty() {
                    out.push(Item::Button(Button::KeepOverride));
                }
                if u.survey.vcrun_present {
                    out.push(Item::Button(Button::RemoveVcrun));
                }
            }
            _ => {}
        }
        out.extend(self.buttons().into_iter().map(Item::Button));
        out
    }

    pub fn focused(&self) -> Option<Item> {
        self.items().get(self.focus).copied()
    }

    fn rows_mut(&mut self, item: Item) -> Option<&mut Row> {
        match item {
            Item::Choice(s, r) => self.sections.get_mut(s)?.rows.get_mut(r),
            _ => None,
        }
    }

    /// The panel's choices differ from what it opened with.
    pub fn dirty(&self) -> bool {
        self.rows().any(Row::changed) || self.ticked != self.ticked_before
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        // A key while the Status box types itself out only finishes it, so a
        // stray Enter doesn't press anything.
        if self.revealing() {
            self.reveal = None;
            return;
        }
        if self.question.is_some() {
            return self.answer_key(key);
        }
        if let Some(sel) = self.list {
            return self.list_key(key, sel);
        }
        if let Screen::Run(r) = &self.screen {
            if !r.finished() {
                return;
            }
        }
        let n = self.items().len();
        match key.code {
            KeyCode::Up => self.focus = self.focus.saturating_sub(1),
            KeyCode::Down => self.focus = (self.focus + 1).min(n.saturating_sub(1)),
            KeyCode::Left | KeyCode::Right if matches!(self.focused(), Some(Item::Button(_))) => {
                let items = self.items();
                let step: isize = if key.code == KeyCode::Left { -1 } else { 1 };
                let next = self.focus as isize + step;
                if next >= 0
                    && (next as usize) < n
                    && matches!(items[next as usize], Item::Button(_))
                {
                    self.focus = next as usize;
                }
            }
            KeyCode::Tab => self.next_section(),
            KeyCode::PageUp => self.info_scroll = self.info_scroll.saturating_sub(5),
            KeyCode::PageDown => self.info_scroll = self.info_scroll.saturating_add(5),
            KeyCode::Char(' ') => match self.focused() {
                Some(Item::Setting(i)) => self.toggle(i),
                Some(Item::Button(
                    b @ (Button::KeepSettings | Button::KeepOverride | Button::RemoveVcrun),
                )) => self.button(b),
                _ => {}
            },
            KeyCode::Enter => self.press(),
            KeyCode::Esc => self.escape(),
            _ => {}
        }
    }

    fn next_section(&mut self) {
        let items = self.items();
        let kind = |i: &Item| match i {
            Item::Choice(s, _) => *s,
            Item::Setting(f) => 100 + usize::from(self.fixes[*f].category != Category::Audio),
            Item::Button(_) => 1000,
        };
        let here = items.get(self.focus).map_or(0, kind);
        self.focus = items.iter().position(|i| kind(i) > here).unwrap_or(0);
    }

    fn toggle(&mut self, i: usize) {
        let Some(f) = self.fixes.get(i) else { return };
        if !Self::tickable(f) {
            return;
        }
        if !self.ticked.remove(&f.title) {
            self.ticked.insert(f.title.clone());
        }
    }

    fn escape(&mut self) {
        match &self.screen {
            Screen::Main => {
                if self.dirty() {
                    self.question = Some(Question {
                        text: "Your changes for this game haven't been applied.".into(),
                        ask: "Leave without applying them?".into(),
                        to: Asker::Leave,
                    });
                } else {
                    self.closed = true;
                }
            }
            Screen::Run(_) => self.reload(),
            _ => {
                self.screen = Screen::Main;
                self.focus = 0;
            }
        }
    }

    fn list_key(&mut self, key: KeyEvent, sel: usize) {
        let Some(item) = self.focused() else { return };
        let len = match item {
            Item::Choice(s, r) => self.choice(s, r).options.len(),
            _ => 0,
        };
        match key.code {
            KeyCode::Up => self.list = Some(sel.saturating_sub(1)),
            KeyCode::Down => self.list = Some((sel + 1).min(len.saturating_sub(1))),
            KeyCode::PageUp => self.list = Some(sel.saturating_sub(5)),
            KeyCode::PageDown => self.list = Some((sel + 5).min(len.saturating_sub(1))),
            KeyCode::Home => self.list = Some(0),
            KeyCode::End => self.list = Some(len.saturating_sub(1)),
            KeyCode::Esc => self.list = None,
            KeyCode::Enter => {
                let speakers_before = self.speakers();
                if let Some(r) = self.rows_mut(item) {
                    r.chosen = sel;
                }
                self.list = None;
                self.place_dsoal_row();
                if self.speakers() != speakers_before {
                    // The settings tied to a speaker layout follow it.
                    let ticked = self.ticked.clone();
                    self.survey_settings(false);
                    self.ticked = ticked;
                    let titles: HashSet<String> =
                        self.fixes.iter().map(|f| f.title.clone()).collect();
                    for f in &self.fixes {
                        if self.installed.is_none()
                            && f.category == Category::Audio
                            && f.status == Status::Offer
                        {
                            self.ticked.insert(f.title.clone());
                        }
                    }
                    self.ticked.retain(|t| titles.contains(t));
                }
            }
            _ => {}
        }
    }

    fn answer_key(&mut self, key: KeyEvent) {
        let answer = match key.code {
            KeyCode::Char('y') | KeyCode::Char('Y') | KeyCode::Enter => true,
            KeyCode::Char('n') | KeyCode::Char('N') | KeyCode::Esc => false,
            _ => return,
        };
        let Some(q) = self.question.take() else {
            return;
        };
        match q.to {
            Asker::Leave => {
                if answer {
                    self.closed = true;
                }
            }
            Asker::Worker => {
                if let Screen::Run(r) = &mut self.screen {
                    r.answer(answer);
                }
            }
        }
    }

    fn press(&mut self) {
        let Some(item) = self.focused() else { return };
        match item {
            Item::Choice(s, r) => {
                self.list_top.set(0);
                self.list = Some(self.choice(s, r).chosen);
            }
            Item::Setting(i) => self.toggle(i),
            Item::Button(b) => self.button(b),
        }
    }

    fn button(&mut self, b: Button) {
        match b {
            Button::Install => {
                let plan = self.plan();
                let mut lines = plan.summary(&self.home);
                // The page's own name for the setup, as its Speakers row shows it.
                for (label, value) in &mut lines {
                    if label == "Speakers" {
                        *value = speakers_label(&plan.speakers);
                    }
                }
                self.screen = Screen::Confirm {
                    title: "Install",
                    heading: format!("Ready to install the EAX fix for {}:", self.name),
                    lines,
                    jobs: vec![Job::Install {
                        plan: Box::new(plan),
                        revert: Vec::new(),
                        audio_done: self.audio_done(),
                    }],
                };
                self.focus = 0;
            }
            Button::Apply => {
                let (lines, jobs) = self.changes();
                self.screen = Screen::Confirm {
                    title: "Apply changes",
                    heading: "Apply these changes?".into(),
                    lines,
                    jobs,
                };
                self.focus = 0;
            }
            Button::Uninstall => self.open_uninstall(),
            Button::SoundLog => {
                let level = (!self.sound_log_on).then_some(LogLevel::Full);
                self.start(vec![Job::SoundLog(level)]);
            }
            Button::CheckAgain => self.reload(),
            Button::Back => {
                if matches!(self.screen, Screen::Run(_)) {
                    self.reload();
                } else {
                    self.screen = Screen::Main;
                    self.focus = 0;
                }
            }
            Button::Confirm => match std::mem::replace(&mut self.screen, Screen::Main) {
                Screen::Confirm { jobs, .. } if !jobs.is_empty() => self.start(jobs),
                Screen::Uninstall(u) => {
                    let choices = Choices {
                        remove: u.survey.files.iter().map(|f| f.path.clone()).collect(),
                        keep_launcher: if u.keep_override {
                            u.survey.launcher_lines()
                        } else {
                            Vec::new()
                        },
                        registry_without_manifest: false,
                        remove_vcrun: u.remove_vcrun,
                        companion_vcrun: if u.remove_vcrun {
                            u.survey
                                .recorded
                                .companions
                                .iter()
                                .map(|c| c.app_id.clone())
                                .collect()
                        } else {
                            Vec::new()
                        },
                        revert: if u.put_back_settings {
                            u.survey.settings.clone()
                        } else {
                            Vec::new()
                        },
                    };
                    self.start(vec![Job::Uninstall {
                        survey: u.survey,
                        choices: Box::new(choices),
                    }]);
                }
                _ => self.focus = 0,
            },
            Button::KeepSettings | Button::KeepOverride | Button::RemoveVcrun => {
                if let Screen::Uninstall(u) = &mut self.screen {
                    match b {
                        Button::KeepSettings => u.put_back_settings = !u.put_back_settings,
                        Button::KeepOverride => u.keep_override = !u.keep_override,
                        _ => u.remove_vcrun = !u.remove_vcrun,
                    }
                }
            }
        }
    }

    fn open_uninstall(&mut self) {
        let state = crate::library::installed_games_file(&self.home);
        let installed: Vec<PathBuf> = crate::library::live_manifest_dirs(&self.home, &state)
            .into_iter()
            .collect();
        let f = &self.facts;
        let at = Location {
            game_dir: &f.game_dir,
            install_root: &f.install_root,
            prefix: f.prefix.as_deref(),
            extra_dirs: &f.extra_dirs,
            installed_dirs: &installed,
            has_app_id: f.store == Some(crate::engine::identify::Store::Steam),
        };
        if let Surveyed::Found(s) = uninstall::survey(&at) {
            self.screen = Screen::Uninstall(UninstallView {
                survey: s,
                put_back_settings: true,
                keep_override: false,
                remove_vcrun: false,
            });
            self.focus = 0;
        }
    }

    /// The install plan the panel's choices make.
    pub fn plan(&self) -> Plan {
        let mut plan = self.facts.default_plan();
        let pick = |k: RowKind| self.row(k).map_or(0, |r| r.chosen);
        plan.engine = if pick(RowKind::Engine) == 1 {
            Engine::OpenAlSoft
        } else {
            Engine::Dsoal
        };
        // Keeping the installed build reinstalls the same version when
        // something else needs a reinstall, or the newest numbered one if
        // it's unknown.
        let (had_dsoal, had_openal) = self.installed_versions();
        let build = |r: Option<&Row>, comp, had: Option<&str>| {
            let key = r
                .and_then(|r| r.keys.get(r.chosen))
                .map_or(crate::build_choice::NUMBERED, String::as_str);
            crate::build_choice::to_build(comp, key, had)
        };
        plan.dsoal_build = build(
            self.row(RowKind::DsoalBuild).or(self.dsoal_row.as_ref()),
            crate::build_choice::Comp::Dsoal,
            had_dsoal.as_deref(),
        );
        plan.openal_build = build(
            self.row(RowKind::OpenalBuild),
            crate::build_choice::Comp::Openal,
            had_openal.as_deref(),
        );
        plan.speakers = self.speakers();
        plan.alsoft_overrides = match (&self.game, self.row(RowKind::Profile)) {
            (Some(g), Some(r)) if r.chosen == 0 => ops::alsoft_values(g, self.untested),
            _ => Vec::new(),
        };
        let has_launcher = self.facts.launcher.is_some();
        let o = pick(RowKind::Override);
        plan.over = match (has_launcher, o) {
            (true, 0) => Override::Launcher(self.facts.launcher.clone().expect("checked")),
            (true, 1) | (false, 0) => Override::Registry,
            _ => Override::Manual,
        };
        ops::companion_overrides(&mut plan, &self.home);
        let vc = self.row(RowKind::Vcrun).expect("always there");
        plan.vcrun = match (vc.options[0].label.as_str(), vc.chosen) {
            ("Already there", 0) => Vcrun::OverridesOnly,
            ("Skip", 1) => Vcrun::Install,
            _ => Vcrun::Skip,
        };
        plan.arch = if pick(RowKind::Arch) == 1 { 64 } else { 32 };
        plan.com_routing = pick(RowKind::Com) == 1;
        plan.advanced_limits = pick(RowKind::Limits) == 1;
        plan.eax_unified = self.row(RowKind::EaxUnified).is_some_and(|r| r.chosen == 0);
        plan.crash_markers = ops::crash_markers(self.game.as_ref());
        let chosen: HashSet<String> = self.ticked.clone();
        plan.game_settings = ops::chosen_rows(&self.fixes, &chosen).0;
        plan
    }

    /// For Apply on an installed game: a line per change, and the jobs.
    pub fn changes(&self) -> (Vec<(String, String)>, Vec<Job>) {
        let mut lines = Vec::new();
        let mut jobs = Vec::new();
        let reinstall_rows = [
            RowKind::Engine,
            RowKind::DsoalBuild,
            RowKind::OpenalBuild,
            RowKind::Override,
            RowKind::Arch,
            RowKind::Com,
            RowKind::Limits,
            RowKind::EaxUnified,
            RowKind::Vcrun,
        ];
        let mut reinstall = false;
        for r in self.rows() {
            if r.changed() {
                lines.push((
                    r.title.to_string(),
                    format!("{} → {}", r.options[r.original].label, r.value()),
                ));
                reinstall |= reinstall_rows.contains(&r.kind);
            }
        }
        let turn_on: Vec<&Fix> = self
            .fixes
            .iter()
            .filter(|f| self.ticked.contains(&f.title) && !self.ticked_before.contains(&f.title))
            .collect();
        let turn_off: Vec<&Fix> = self
            .fixes
            .iter()
            .filter(|f| !self.ticked.contains(&f.title) && self.ticked_before.contains(&f.title))
            .collect();
        for f in &turn_on {
            lines.push(("Turn on".into(), f.title.clone()));
        }
        for f in &turn_off {
            lines.push(("Put back".into(), f.title.clone()));
        }
        let revert: Vec<RevertGroup> = self
            .installed
            .as_ref()
            .map(|i| {
                i.settings
                    .iter()
                    .filter(|g| turn_off.iter().any(|f| f.title == g.title))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        let on_titles: HashSet<String> = turn_on.iter().map(|f| f.title.clone()).collect();
        let (on_rows, _) = ops::chosen_rows(&self.fixes, &on_titles);
        let speakers_changed = self.row(RowKind::Speakers).is_some_and(Row::changed);
        if reinstall {
            lines.push(("Reinstall".into(), "with the choices above".into()));
            jobs.push(Job::Install {
                plan: Box::new(self.plan()),
                revert,
                audio_done: self.audio_done(),
            });
        } else {
            if speakers_changed {
                jobs.push(Job::Speakers(self.speakers()));
            }
            if !revert.is_empty() || !on_rows.is_empty() {
                jobs.push(Job::Settings {
                    revert,
                    plan: on_rows,
                });
            }
        }
        (lines, jobs)
    }

    /// Every audio setting the game has is on (ticked, or already set), as
    /// the script's `game_audio_settings_done`.
    fn audio_done(&self) -> bool {
        let mut audio = self
            .fixes
            .iter()
            .filter(|f| f.category == Category::Audio)
            .peekable();
        audio.peek().is_some()
            && audio.all(|f| self.ticked.contains(&f.title) || f.status == Status::Already)
    }

    fn start(&mut self, jobs: Vec<Job>) {
        let view = run::start(
            jobs,
            self.facts.clone(),
            self.game.clone(),
            self.installed.clone(),
            self.home.clone(),
            self.untested,
        );
        self.screen = Screen::Run(view);
        self.focus = 0;
        self.changed_disk = true;
    }

    /// Reads the game again, after a change or a "Check again".
    pub fn reload(&mut self) {
        let fresh = Panel::open(
            &self.name,
            &self.facts.game_dir,
            self.game.clone(),
            &self.home,
        );
        let changed = self.changed_disk;
        *self = fresh;
        self.changed_disk = changed;
    }

    /// Called often while work runs: takes the worker's messages, and opens
    /// its questions.
    pub fn tick(&mut self) {
        if let Some(rx) = &self.builds_rx {
            match rx.try_recv() {
                Ok(info) => {
                    self.builds_rx = None;
                    self.set_build_info(info);
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.builds_rx = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
        if let Screen::Run(r) = &mut self.screen {
            if let Some((text, ask)) = r.poll() {
                self.question = Some(Question {
                    text,
                    ask,
                    to: Asker::Worker,
                });
            }
        }
    }

    pub fn running(&self) -> bool {
        matches!(&self.screen, Screen::Run(r) if !r.finished())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::builds::Build;
    use crate::theme;
    use ratatui::crossterm::event::KeyModifiers;

    fn key(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn touch(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    /// A Steam game with a prefix, as the integration tests' fake world has.
    fn steam_game(home: &Path) -> PathBuf {
        let steam = home.join(".local/share/Steam/steamapps");
        touch(
            &steam.join("appmanifest_424242.acf"),
            "\"AppState\"\n{\n\t\"appid\"\t\t\"424242\"\n\t\"name\"\t\t\"Test Game\"\n\t\"installdir\"\t\t\"Test Game\"\n}\n",
        );
        touch(
            &steam.join("libraryfolders.vdf"),
            &format!(
                "\"libraryfolders\"\n{{\n\t\"0\"\n\t{{\n\t\t\"path\"\t\t\"{}\"\n\t}}\n}}\n",
                steam.parent().unwrap().display()
            ),
        );
        std::fs::create_dir_all(steam.join("compatdata/424242/pfx/drive_c/windows/syswow64"))
            .unwrap();
        let game = steam.join("common/Test Game");
        let exe = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/fixtures/pe32.exe");
        std::fs::create_dir_all(&game).unwrap();
        std::fs::copy(exe, game.join("game.exe")).unwrap();
        game
    }

    fn pick(p: &mut Panel, kind: RowKind, option: usize) {
        p.focus = p
            .items()
            .iter()
            .position(|i| match i {
                Item::Choice(si, ri) => p.choice(*si, *ri).kind == kind,
                _ => false,
            })
            .unwrap();
        p.handle_key(key(KeyCode::Enter));
        let at = p.list.unwrap();
        for _ in 0..at {
            p.handle_key(key(KeyCode::Up));
        }
        for _ in 0..option {
            p.handle_key(key(KeyCode::Down));
        }
        p.handle_key(key(KeyCode::Enter));
    }

    #[test]
    fn a_fresh_game_installs_with_the_choices_made() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let game = steam_game(&home);
        let mut p = Panel::open("Test Game", &game, None, &home);
        // Steam's prefix is found through protontricks, which isn't here.
        assert!(p.problem.is_some());
        assert_eq!(p.buttons(), [Button::CheckAgain]);
        p.facts.prefix = Some(home.join(".local/share/Steam/steamapps/compatdata/424242/pfx"));
        p.build();
        assert!(p.problem.is_none(), "{:?}", p.problem);
        assert_eq!(p.buttons(), [Button::Install]);
        let default = p.facts.default_plan();
        assert_eq!(p.plan().speakers, default.speakers);
        assert!(!p.dirty());

        pick(&mut p, RowKind::Speakers, 6);
        pick(&mut p, RowKind::Arch, 1);
        let plan = p.plan();
        assert_eq!(plan.speakers, Speakers::surround(Layout::Surround51));
        assert_eq!(plan.arch, 64);
        assert!(p.dirty());

        // Leaving with choices made asks first; "no" stays.
        p.handle_key(key(KeyCode::Esc));
        assert!(p.question.is_some());
        p.handle_key(key(KeyCode::Char('n')));
        assert!(!p.closed);
        p.handle_key(key(KeyCode::Esc));
        p.handle_key(key(KeyCode::Char('y')));
        assert!(p.closed);
    }

    #[test]
    fn an_installed_game_names_its_builds_and_keeps_them() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let game = steam_game(&home);
        touch(&game.join("dsound.dll"), "x");
        touch(
            &game.join(crate::engine::manifest::FILE_NAME),
            &format!(
                "{}\n# DSOAL: r690\n# OpenAL Soft: 1.24.3\n{g}/dsound.dll\n",
                crate::engine::manifest::HEADER,
                g = game.display()
            ),
        );
        let mut p = Panel::open("Test Game", &game, None, &home);
        let banner: String = view::banner_lines(&p)[0]
            .spans
            .iter()
            .map(|s| s.content.as_ref())
            .collect();
        assert_eq!(banner, " ● DSOAL r690 and OpenAL Soft 1.24.3 are installed");
        let keep = p.row(RowKind::DsoalBuild).unwrap();
        assert_eq!(keep.value(), "Keep the installed one");
        assert_eq!(
            keep.options[0].help,
            "Keeps DSOAL r690, which is in the game now."
        );
        // A reinstall for another reason puts the same versions back.
        pick(&mut p, RowKind::Arch, 1);
        let plan = p.plan();
        assert_eq!(plan.dsoal_build, Build::Exact("r690".into()));
        assert_eq!(plan.openal_build, Build::Exact("1.24.3".into()));
    }

    #[test]
    fn apply_on_an_installed_game_reinstalls_only_for_install_choices() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let game = steam_game(&home);
        touch(&game.join("alsoft.ini"), "[general]\nchannels=surround51\n");
        touch(&game.join("dsound.dll"), "x");
        touch(
            &game.join(crate::engine::manifest::FILE_NAME),
            &format!(
                "{}\n{g}/dsound.dll\n{g}/alsoft.ini\n",
                crate::engine::manifest::HEADER,
                g = game.display()
            ),
        );
        let mut p = Panel::open("Test Game", &game, None, &home);
        assert!(p.installed.is_some());
        assert_eq!(p.buttons()[..2], [Button::Apply, Button::Uninstall]);
        assert_eq!(p.speakers(), Speakers::surround(Layout::Surround51));
        let (lines, jobs) = p.changes();
        assert!(lines.is_empty() && jobs.is_empty());

        pick(&mut p, RowKind::Speakers, 0);
        let (lines, jobs) = p.changes();
        assert_eq!(lines.len(), 1);
        assert!(matches!(jobs[..], [Job::Speakers(_)]));

        // Each build is its own choice: the rolling DSOAL (after Keep) leaves
        // OpenAL Soft as it is, which with no version recorded is the newest
        // numbered one.
        pick(&mut p, RowKind::DsoalBuild, 1);
        let (_, jobs) = p.changes();
        assert!(matches!(
            &jobs[..],
            [Job::Install { plan, .. }]
                if plan.dsoal_build == Build::Latest && plan.openal_build == Build::Numbered
        ));
    }

    fn screen(p: &Panel, w: u16, h: u16) -> Vec<String> {
        use ratatui::backend::TestBackend;
        let mut t = ratatui::Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| view::draw(f, p, f.area())).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect())
            .collect()
    }

    /// The fake Steam game with its prefix found, ready to install.
    fn ready(home: &Path) -> Panel {
        let game = steam_game(home);
        let mut p = Panel::open("Test Game", &game, None, home);
        p.facts.prefix = Some(home.join(".local/share/Steam/steamapps/compatdata/424242/pfx"));
        p.build();
        p
    }

    fn col_of(row: &str, s: &str) -> usize {
        row[..row.find(s).unwrap()].chars().count()
    }

    #[test]
    fn the_boxes_follow_the_scripts_steps() {
        let tmp = tempfile::tempdir().unwrap();
        let p = ready(&tmp.path().join("home"));
        let titles: Vec<&str> = p.sections.iter().map(|s| s.title).collect();
        assert_eq!(
            titles,
            [
                "Audio engine",
                "Runtimes",
                "Speakers",
                "Compatibility tweaks",
                "DLL override"
            ]
        );
        let rows = screen(&p, 160, 50);
        let order: Vec<usize> = [
            "1. Audio engine",
            "2. Runtimes",
            "3. Speakers",
            "4. Compatibility tweaks",
            "5. DLL override",
            "6. Game settings",
        ]
        .iter()
        .map(|t| row_of(&rows, t))
        .collect();
        assert!(order.windows(2).all(|w| w[0] < w[1]), "{}", rows.join("\n"));
    }

    #[test]
    fn two_columns_when_wide_then_one_under_another() {
        let tmp = tempfile::tempdir().unwrap();
        let p = ready(&tmp.path().join("home"));

        // The choices from the left edge, the profile beside them.
        let rows = screen(&p, 160, 50);
        let title = row_of(&rows, "Test Game ─ Steam");
        assert!(rows[title].starts_with('╭'), "{}", rows.join("\n"));
        let profile = row_of(&rows, " Game profile ");
        assert!(col_of(&rows[profile], " Game profile ") > 110);
        assert!(rows.iter().any(|r| r.contains("[OK] Game")));
        assert!(rows.iter().any(|r| r.contains(" Game profile ")));
        assert!(rows.iter().any(|r| r.contains("[ Install ]")));

        let rows = screen(&p, 120, 50);
        let profile = row_of(&rows, " Game profile ");
        assert!(col_of(&rows[profile], " Game profile ") > 70);

        let rows = screen(&p, 90, 60);
        let profile = row_of(&rows, " Game profile ");
        assert!(
            profile > row_of(&rows, "1. Audio engine"),
            "under the choices"
        );
    }

    #[test]
    fn the_status_box_says_what_was_found_and_flags_problems() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let mut p = ready(&home);
        let lines = p.status_lines();
        let labels: Vec<&str> = lines.iter().map(|l| l.label).collect();
        assert_eq!(labels[0], "Game");
        assert!(lines[0].value.starts_with("~/"), "{:?}", lines[0]);
        let store = lines.iter().find(|l| l.label == "Store").unwrap();
        assert_eq!(store.value, "Steam (AppID 424242)");
        assert!(lines.iter().all(|l| l.label != "Installed"));

        p.facts.prefix = None;
        let prefix = p
            .status_lines()
            .into_iter()
            .find(|l| l.label == "Prefix")
            .unwrap();
        assert!(!prefix.ok);
        assert_eq!(prefix.value, "not found yet");
    }

    #[test]
    fn detected_values_say_so_until_changed() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        // The test game's .exe is 32-bit, so the architecture was detected;
        // the builds are a default.
        assert!(p.row(RowKind::Arch).unwrap().shows_detected());
        assert!(!p.row(RowKind::DsoalBuild).unwrap().shows_detected());
        assert!(!p.row(RowKind::OpenalBuild).unwrap().shows_detected());
        let rows = screen(&p, 160, 50);
        let arch = &rows[row_of(&rows, "Architecture")];
        assert!(
            arch.contains("[ 32-bit") && arch.contains("▾ ] (detected)"),
            "{arch}"
        );
        assert!(!rows[row_of(&rows, "DSOAL build")].contains("(detected)"));

        // Where the override goes is the page's choice, never "detected".
        assert!(!p.row(RowKind::Override).unwrap().shows_detected());
        assert!(!rows[row_of(&rows, "DLL override  ")].contains("(detected)"));

        pick(&mut p, RowKind::Arch, 1);
        let rows = screen(&p, 160, 50);
        assert!(!rows[row_of(&rows, "Architecture")].contains("(detected)"));
        pick(&mut p, RowKind::Arch, 0);
        assert!(p.row(RowKind::Arch).unwrap().shows_detected());
    }

    #[test]
    fn the_page_uses_the_lists_colours() {
        use ratatui::backend::TestBackend;
        let tmp = tempfile::tempdir().unwrap();
        let p = ready(&tmp.path().join("home"));
        let mut t = ratatui::Terminal::new(TestBackend::new(160, 50)).unwrap();
        t.draw(|f| view::draw(f, &p, f.area())).unwrap();
        let buf = t.backend().buffer().clone();
        let rows = screen(&p, 160, 50);
        let cell = |row: usize, s: &str| {
            let x = col_of(&rows[row], s) as u16;
            buf[(x, row as u16)].clone()
        };
        // The focused first row: list selection colours.
        let engine = row_of(&rows, "Audio engine  ");
        let c = cell(engine, "Audio engine  ");
        assert_eq!(c.fg, theme::SELECT_TEXT);
        assert_eq!(c.bg, theme::SELECT_BG);
        // Another row's name: the filters' colour; a detected value: green.
        let arch = row_of(&rows, "Architecture");
        assert_eq!(cell(arch, "Architecture").fg, theme::FILTER_LABEL);
        assert_eq!(cell(arch, "32-bit").fg, ratatui::style::Color::Green);
    }

    #[test]
    fn install_shows_what_it_will_do_first() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        p.focus = p.items().len() - 1;
        assert_eq!(p.focused(), Some(Item::Button(Button::Install)));
        p.handle_key(key(KeyCode::Enter));
        let Screen::Confirm {
            title,
            heading,
            lines,
            jobs,
        } = &p.screen
        else {
            panic!("no confirm screen");
        };
        assert_eq!(*title, "Install");
        assert_eq!(heading, "Ready to install the EAX fix for Test Game:");
        assert!(lines
            .iter()
            .any(|(l, v)| l == "Audio engine" && v == "DSOAL with OpenAL Soft"));
        assert!(matches!(jobs[..], [Job::Install { .. }]));
        assert_eq!(p.buttons(), [Button::Confirm, Button::Back]);
        p.handle_key(key(KeyCode::Esc));
        assert!(matches!(p.screen, Screen::Main));
    }

    #[test]
    fn the_status_box_types_itself_out_and_a_key_skips_it() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        assert!(!p.revealing(), "tests open with it shown");
        p.reveal = Some(Instant::now() - Duration::from_millis(LINE_PAUSE_MS + 20));
        let (done, chars) = p.revealed().unwrap();
        assert_eq!(done, 0);
        assert!(chars > 0);
        let rows = screen(&p, 160, 50);
        assert!(
            !rows.iter().any(|r| r.contains("[ Install ]")),
            "no buttons yet"
        );
        assert!(
            !rows.iter().any(|r| r.contains("[OK]")),
            "no line finished yet"
        );

        // A key finishes it and does nothing else.
        let focus = p.focus;
        p.handle_key(key(KeyCode::Enter));
        assert!(!p.revealing());
        assert!(matches!(p.screen, Screen::Main));
        assert_eq!(p.focus, focus);
        assert!(p.list.is_none());
    }

    fn fix(title: &str, status: Status, keys: &[&str]) -> Fix {
        use crate::engine::config::Value;
        use crate::engine::game_settings::ViewRow;
        Fix {
            category: Category::Optional,
            index: 0,
            title: title.into(),
            reason: String::new(),
            follow_up: String::new(),
            untested: false,
            status,
            plan: Vec::new(),
            view: keys
                .iter()
                .map(|k| ViewRow {
                    path: PathBuf::from("/g/autoexec.cfg"),
                    section: String::new(),
                    key: k.to_string(),
                    old: None,
                    new: Value::text("1"),
                })
                .collect(),
            missing_file: Some("Quake4Config.cfg".into()),
            absent_files: Vec::new(),
            files: Vec::new(),
        }
    }

    #[test]
    fn settings_read_like_the_settings_pane() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        let many = [
            "com_videoRam",
            "r_renderer",
            "r_shadows",
            "image_anisotropy",
        ];
        p.fixes = vec![
            fix("Fix low image quality", Status::Offer, &many),
            fix("Fix blurry text", Status::Offer, &["gui_smallFontLimit"]),
            fix("Fix low-res textures", Status::Missing, &[]),
        ];
        let rows = screen(&p, 160, 60);
        // Each title with its tag at the right; an unfocused big setting says
        // how many keys, a small one lists them.
        let big = row_of(&rows, "Fix low image quality");
        assert!(rows[big].contains("(tested)"));
        assert!(
            rows[big + 1].contains("4 changes in autoexec.cfg"),
            "{}",
            rows.join("\n")
        );
        let small = row_of(&rows, "Fix blurry text");
        assert!(rows[small + 1].contains("autoexec.cfg"));
        assert!(rows[small + 2].contains("gui_smallFontLimit  (not set) → 1"));
        let waits = row_of(&rows, "Fix low-res textures");
        assert!(rows[waits + 1].contains("Needs Quake4Config.cfg, which Test Game creates"));

        // Focused, the big one lists every key, the arrows in one column.
        p.focus = p
            .items()
            .iter()
            .position(|i| *i == Item::Setting(0))
            .unwrap();
        let rows = screen(&p, 160, 60);
        let big = row_of(&rows, "Fix low image quality");
        let arrows: Vec<usize> = (0..many.len())
            .map(|k| col_of(&rows[big + 2 + k], "→"))
            .collect();
        assert!(rows[big + 2].contains("com_videoRam"));
        assert!(
            arrows.windows(2).all(|w| w[0] == w[1]),
            "{}",
            rows.join("\n")
        );
    }

    #[test]
    fn the_banner_says_whether_its_installed() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        let text = |p: &Panel| -> Vec<String> {
            view::banner_lines(p)
                .iter()
                .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
                .collect()
        };
        assert_eq!(text(&p), [" ● Not installed"]);
        p.facts.prefix = None;
        p.build();
        assert_eq!(
            text(&p)[0],
            " ● Can't install yet, because Test Game has no Wine prefix"
        );
        let rows = screen(&p, 160, 50);
        assert!(rows.iter().any(|r| r.contains(" EAX fix ")));
        // The Status box sits right under the EAX fix box, in the same column.
        let eax = row_of(&rows, " EAX fix ");
        let status = row_of(&rows, " Status ");
        assert_eq!(status, eax + 3, "{}", rows.join("\n"));
        assert_eq!(
            col_of(&rows[status], "╭"),
            col_of(&rows[eax], "╭"),
            "{}",
            rows.join("\n")
        );
        assert!(!rows.iter().any(|r| r.contains("ompatib")));
    }

    #[test]
    fn choices_are_dropdowns_that_open_under_their_row() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        let rows = screen(&p, 160, 50);
        let chevrons: Vec<usize> = [
            "Audio engine  ",
            "DSOAL build",
            "OpenAL Soft build",
            "Architecture",
            "COM routing",
        ]
        .iter()
        .map(|name| {
            let r = &rows[row_of(&rows, name)];
            assert!(r.contains("[ "), "{r}");
            col_of(r, "▾")
        })
        .collect();
        assert!(
            chevrons.windows(2).all(|w| w[0] == w[1]),
            "{}",
            rows.join("\n")
        );

        // Enter on a build: its list's top border is the row under the field.
        pick_focus(&mut p, RowKind::OpenalBuild);
        p.handle_key(key(KeyCode::Enter));
        let rows = screen(&p, 160, 50);
        let builds = row_of(&rows, "OpenAL Soft build  ");
        let top = &rows[builds + 1];
        assert!(
            top.contains("╭") && top.contains(" OpenAL Soft build "),
            "{}",
            rows.join("\n")
        );
    }

    #[test]
    fn the_dsoal_build_is_only_offered_while_the_engine_uses_dsoal() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        pick(&mut p, RowKind::DsoalBuild, 0);
        pick_focus(&mut p, RowKind::Engine);
        p.list = Some(1);
        p.handle_key(key(KeyCode::Enter));
        assert!(p.row(RowKind::DsoalBuild).is_none());
        assert!(p.row(RowKind::OpenalBuild).is_some());
        // Back to DSOAL: the row returns under the engine, as it was left.
        p.list = Some(0);
        p.handle_key(key(KeyCode::Enter));
        let sound: Vec<RowKind> = p.sections[0].rows.iter().map(|r| r.kind).collect();
        assert_eq!(
            sound[..3],
            [RowKind::Engine, RowKind::DsoalBuild, RowKind::OpenalBuild]
        );
        assert_eq!(p.plan().dsoal_build, Build::Latest);
    }

    #[test]
    fn a_page_opened_on_the_install_folder_moves_to_the_exes_folder() {
        // BioShock: the library gives the install's top folder, the exe is in
        // Builds/Release and names "openal32.dll" in lower case, and a
        // launcher DLL beside the top folder only mentions DirectSound.
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let top = steam_game(&home);
        std::fs::remove_file(top.join("game.exe")).unwrap();
        touch(&top.join("Redist/dxsetup.dll"), "DirectSound dsound.dll");
        let release = top.join("Builds/Release");
        std::fs::create_dir_all(&release).unwrap();
        let pe = Path::new(env!("CARGO_MANIFEST_DIR")).join("../tests/fixtures/pe32.exe");
        let mut exe = std::fs::read(pe).unwrap();
        exe.extend_from_slice(b"openal32.dll\0dsound.dll\0");
        std::fs::write(release.join("Bioshock.exe"), exe).unwrap();
        let game = profile(r#"{"api":"openal","versions":["4.0"]}"#);
        let game = crate::db::Game {
            exe: "Bioshock.exe".into(),
            ..game
        };
        let p = Panel::open("BioShock", &top, Some(game), &home);
        assert_eq!(p.facts.game_dir, release);
        let lines = p.status_lines();
        assert_eq!(lines[0].label, "Game");
        assert!(
            lines[0].value.ends_with("Builds/Release/Bioshock.exe"),
            "{}",
            lines[0].value
        );
        // The exe names both, so the files agree with the profile's OpenAL.
        let files = lines.iter().find(|l| l.label == "Game files").unwrap();
        assert!(files.ok, "{}", files.value);
        assert_eq!(files.value, "32-bit, OpenAL");
    }

    #[test]
    fn when_the_files_disagree_the_status_says_which_says_what() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        p.facts.profile_api = Some("openal".into());
        p.facts.files_api = Some(crate::engine::detect::ApiEvidence {
            api: crate::engine::detect::Api::DirectSound3d,
            ds_file: "Galaxy.dll".into(),
            openal_file: String::new(),
        });
        let files = p
            .status_lines()
            .into_iter()
            .find(|l| l.label == "Game files")
            .unwrap();
        assert!(!files.ok);
        assert_eq!(
            files.value,
            "32-bit, OpenAL, as its profile says, but Galaxy.dll points to DirectSound3D."
        );
    }

    #[test]
    fn a_long_list_scrolls_to_keep_the_highlight_on_screen() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        let revs: Vec<String> = (660..=697).rev().map(|n| format!("r{n}")).collect();
        p.set_build_info(crate::build_choice::BuildInfo {
            catalog: crate::engine::builds::Catalog {
                dsoal: revs
                    .iter()
                    .map(|r| crate::engine::builds::Release {
                        tag: r.clone(),
                        date: "2026-01-01".into(),
                    })
                    .collect(),
                openal: Vec::new(),
            },
            ..crate::build_choice::BuildInfo::default()
        });
        pick_focus(&mut p, RowKind::DsoalBuild);
        p.handle_key(key(KeyCode::Enter));
        let list = open_list(&p, "DSOAL build");
        let rows = screen(&p, 160, 50);
        // No taller than the screen, with a scroll bar inside its right edge.
        assert!(list.len() < 50, "{}", rows.join("\n"));
        assert!(list.iter().any(|r| r.contains("Latest rolling")));
        assert!(
            list.iter().any(|r| r.ends_with("││")),
            "{}",
            list.join("\n")
        );

        // End: the last build in full, the first options scrolled away.
        p.handle_key(key(KeyCode::End));
        let list = open_list(&p, "DSOAL build");
        // The last build in full: its name, then when it came out.
        let at = list
            .iter()
            .position(|r| r.contains("DSOAL r660"))
            .unwrap_or_else(|| panic!("{}", list.join("\n")));
        assert!(
            list[at + 1].contains("Released on 2026-01-01."),
            "{}",
            list.join("\n")
        );
        assert!(!list.iter().any(|r| r.contains("Latest rolling")));
        // PgUp moves five builds up and the window follows.
        p.handle_key(key(KeyCode::PageUp));
        let list = open_list(&p, "DSOAL build");
        assert!(
            list.iter().any(|r| r.contains("r665")),
            "{}",
            list.join("\n")
        );
        p.handle_key(key(KeyCode::Enter));
        assert_eq!(p.plan().dsoal_build, Build::Exact("r665".into()));
    }

    #[test]
    fn when_the_files_dont_say_the_status_says_so_without_a_warning() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        p.facts.profile_api = Some("openal".into());
        p.facts.files_api = None;
        let files = p
            .status_lines()
            .into_iter()
            .find(|l| l.label == "Game files")
            .unwrap();
        assert!(files.ok);
        assert_eq!(files.value, "32-bit, OpenAL (per its profile)");
        // With no profile either, it's a guess, and flagged.
        p.facts.profile_api = None;
        let files = p
            .status_lines()
            .into_iter()
            .find(|l| l.label == "Game files")
            .unwrap();
        assert!(!files.ok);
        assert_eq!(
            files.value,
            "32-bit, DirectSound3D (a guess). Its files don't mention OpenAL or DirectSound3D."
        );
    }

    #[test]
    fn the_build_lists_fill_in_and_keep_whats_chosen() {
        use crate::build_choice::{BuildInfo, ROLLING};
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        pick(&mut p, RowKind::DsoalBuild, 0);
        assert_eq!(p.row(RowKind::DsoalBuild).unwrap().keys[0], ROLLING);
        p.set_build_info(BuildInfo {
            catalog: crate::engine::builds::Catalog {
                dsoal: vec!["r697".into(), "r690".into()],
                openal: Vec::new(),
            },
            dsoal_rolling: "r697".into(),
            ..BuildInfo::default()
        });
        let r = p.row(RowKind::DsoalBuild).unwrap();
        let labels: Vec<&str> = r.options.iter().map(|o| o.label.as_str()).collect();
        assert_eq!(
            labels,
            [
                "Latest rolling (r697)",
                "Latest numbered (r697)",
                "DSOAL r697",
                "DSOAL r690"
            ]
        );
        // Still on Latest rolling, still a change from the default.
        assert_eq!(r.value(), "Latest rolling (r697)");
        assert!(r.changed());
        // An exact build goes to the install as that version.
        pick(&mut p, RowKind::DsoalBuild, 3);
        assert_eq!(p.plan().dsoal_build, Build::Exact("r690".into()));
    }

    #[test]
    fn a_new_install_starts_on_the_saved_defaults() {
        use crate::prefs::{BuildPref, OverridePref, Prefs, SpeakerPref, VcPref};
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        p.prefs = Prefs {
            dsoal_build: BuildPref("rolling".into()),
            openal_build: BuildPref("1.24.3".into()),
            over: OverridePref::Manual,
            vcrun: VcPref::InstallIfMissing,
            speakers: SpeakerPref::Surround51,
        };
        p.build();
        let plan = p.plan();
        assert_eq!(plan.dsoal_build, Build::Latest);
        // A saved version is listed even before the list arrives.
        assert_eq!(plan.openal_build, Build::Exact("1.24.3".into()));
        assert_eq!(plan.over, Override::Manual);
        assert_eq!(plan.vcrun, Vcrun::Install);
        assert_eq!(plan.speakers, Speakers::surround(Layout::Surround51));
        // They're where the page starts, not changes the player made.
        assert!(!p.rows().any(Row::changed));

        // Launch options with no launcher to put them in: the registry.
        p.prefs.over = OverridePref::LaunchOptions;
        p.facts.launcher = None;
        p.build();
        assert_eq!(p.plan().over, Override::Registry);
    }

    #[test]
    fn each_vc_default_picks_its_choice_with_the_runtime_there_or_not() {
        use crate::prefs::VcPref;
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        for (pref, present, want) in [
            (VcPref::UseIfThere, false, Vcrun::Skip),
            (VcPref::UseIfThere, true, Vcrun::OverridesOnly),
            (VcPref::InstallIfMissing, false, Vcrun::Install),
            (VcPref::InstallIfMissing, true, Vcrun::OverridesOnly),
            (VcPref::LeaveAlone, false, Vcrun::Skip),
            (VcPref::LeaveAlone, true, Vcrun::Skip),
        ] {
            p.prefs.vcrun = pref;
            p.facts.vcrun_present = present;
            p.build();
            assert_eq!(p.plan().vcrun, want, "{pref:?}, present: {present}");
        }
    }

    /// The open pop-up's rows, from its top border to its bottom one, cut to
    /// its own columns.
    fn open_list(p: &Panel, title: &str) -> Vec<String> {
        let rows = screen(p, 160, 50);
        let top = rows
            .iter()
            .position(|r| {
                r.contains(&format!("╭─ {title} ")) || r.contains(&format!("─ {title} ─"))
            })
            .unwrap_or_else(|| panic!("{}", rows.join("\n")));
        let left = rows[top].chars().position(|c| c == '╭').unwrap();
        let width = rows[top].chars().skip(left).position(|c| c == '╮').unwrap() + 1;
        rows[top..]
            .iter()
            .map(|r| r.chars().skip(left).take(width).collect::<String>())
            .take_while(|r| !r.starts_with('╰'))
            .collect()
    }

    #[test]
    fn setting_pop_ups_are_one_width_with_room_around_their_text() {
        let tmp = tempfile::tempdir().unwrap();
        let mut p = ready(&tmp.path().join("home"));
        let mut widths = Vec::new();
        for (kind, title) in [
            (RowKind::Speakers, "Speakers"),
            (RowKind::Arch, "Architecture"),
        ] {
            pick_focus(&mut p, kind);
            p.handle_key(key(KeyCode::Enter));
            let list = open_list(&p, title);
            widths.push(list[0].chars().count());
            // A blank margin row under the top border, and nothing in the two
            // columns inside the side borders.
            assert_eq!(list[1].trim_matches('│').trim(), "", "{}", list.join("\n"));
            for r in &list[1..] {
                let inside: Vec<char> = r.chars().collect();
                assert_eq!(&inside[1..3], [' ', ' '], "{}", list.join("\n"));
            }
            p.handle_key(key(KeyCode::Esc));
        }
        assert_eq!(widths, [usize::from(view::LIST_W); 2]);

        // Options sit apart: a blank row before each label after the first, and
        // a description too long for one row wraps instead of widening the box.
        pick_focus(&mut p, RowKind::Speakers);
        p.handle_key(key(KeyCode::Enter));
        let list = open_list(&p, "Speakers");
        let second = list
            .iter()
            .position(|r| r.contains("Headphones, without 3D"))
            .unwrap();
        assert_eq!(list[second - 1].trim_matches('│').trim(), "");
        let mut row = p.row(RowKind::Speakers).unwrap().clone();
        row.options[0].help = "word ".repeat(40);
        let lines = view::list_lines(&row.options, row.chosen, 0, 40);
        assert!(lines.iter().take_while(|l| !l.spans.is_empty()).count() > 3);
    }

    fn profile(eax: &str) -> crate::db::Game {
        crate::db::Database::parse(&format!(
            r#"{{"games":[{{"id":"t","name":"Test Game EE","stores":{{"steam":{{"id":424242}}}},
              "eax":{eax}}}]}}"#
        ))
        .unwrap()
        .games
        .remove(0)
    }

    #[test]
    fn a_patch_that_removed_eax_with_a_fix_in_place_still_installs() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let game = steam_game(&home);
        let g = profile(r#"{"status":"removed_by_patch","fix_in_place":true,"fix":"Roll back."}"#);
        let mut p = Panel::open("Test Game", &game, Some(g), &home);
        p.facts.prefix = Some(home.join(".local/share/Steam/steamapps/compatdata/424242/pfx"));
        p.build();
        assert!(p.problem.is_none());
        assert_eq!(p.buttons(), [Button::Install]);
    }

    fn pick_focus(p: &mut Panel, kind: RowKind) {
        p.focus = p
            .items()
            .iter()
            .position(|i| matches!(i, Item::Choice(si, ri) if p.choice(*si, *ri).kind == kind))
            .unwrap();
    }

    fn row_of(rows: &[String], s: &str) -> usize {
        rows.iter().position(|r| r.contains(s)).unwrap()
    }
}
