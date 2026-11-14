//! The game panel: everything for one game on one screen. Its status, every
//! choice an install takes, its own settings, then one action, which runs
//! inside the TUI (`run`). State and keys only; `view` draws it.

pub mod run;
pub mod view;

use crate::db::Game;
use crate::engine::apply::RevertGroup;
use crate::engine::builds::Build;
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

/// One value a row can take, and a sentence about it.
#[derive(Debug, Clone)]
pub struct Opt {
    pub label: String,
    pub help: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RowKind {
    Engine,
    Builds,
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
        }
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
    Sound(usize),
    Setup(usize),
    Setting(usize),
    Button(Button),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    Install,
    Apply,
    Uninstall,
    SoundLog,
    OtherTools,
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
    /// What Apply will do, and the jobs that do it.
    Confirm {
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
    pub sound: Vec<Row>,
    pub setup: Vec<Row>,
    pub fixes: Vec<Fix>,
    pub ticked: HashSet<String>,
    pub ticked_before: HashSet<String>,
    pub focus: usize,
    /// The open list of the focused row's values, and its highlight.
    pub list: Option<usize>,
    pub screen: Screen,
    pub question: Option<Question>,
    pub sound_log_on: bool,
    /// The panel asked to close; the app drops it.
    pub closed: bool,
    /// The panel asked for the game menu (VC++, EAX Unified).
    pub other_tools: bool,
    /// Something was changed on disk, so the game list needs reading again.
    pub changed_disk: bool,
    home: PathBuf,
    untested: bool,
}

impl Panel {
    /// Looks at the game folder and everything around it, as the headless
    /// commands do.
    pub fn open(name: &str, dir: &Path, game: Option<Game>, home: &Path) -> Self {
        let pt = crate::cli::protontricks();
        let facts = prepare::gather(dir, game.as_ref(), home, &pt);
        let installed = Installed::read(&facts.game_dir, home);
        let mut p = Panel {
            name: game
                .as_ref()
                .map_or_else(|| name.to_string(), |g| g.name.clone()),
            facts,
            game,
            installed,
            problem: None,
            sound: Vec::new(),
            setup: Vec::new(),
            fixes: Vec::new(),
            ticked: HashSet::new(),
            ticked_before: HashSet::new(),
            focus: 0,
            list: None,
            screen: Screen::Main,
            question: None,
            sound_log_on: false,
            closed: false,
            other_tools: false,
            changed_disk: false,
            home: home.to_path_buf(),
            untested: ops::untested_from_env(),
        };
        p.build();
        p
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
        )];
        let builds = if self.installed.is_some() {
            vec![
                (
                    "Keep the installed ones",
                    "Leaves the files in the game as they are.",
                ),
                ("Stable", "The tested builds of DSOAL and OpenAL Soft."),
                (
                    "Latest",
                    "The newest builds, which may not have been tested yet.",
                ),
            ]
        } else {
            vec![
                ("Stable", "The tested builds of DSOAL and OpenAL Soft."),
                (
                    "Latest",
                    "The newest builds, which may not have been tested yet.",
                ),
            ]
        };
        sound.push(Row::new(RowKind::Builds, "Builds", builds, 0));
        let current = self
            .installed
            .as_ref()
            .and_then(Installed::speakers)
            .unwrap_or(plan.speakers);
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
        let mut sprow = Row::new(RowKind::Speakers, "Speakers", Vec::new(), at);
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
                );
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
            _ => match plan.over {
                Override::Launcher(_) => 0,
                Override::Registry => usize::from(has_launcher),
                Override::Manual => usize::from(has_launcher) + 1,
            },
        };
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
                0,
            )
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
                0,
            )
        };
        setup.push(vc);
        let arch = st.as_ref().and_then(|s| s.arch).unwrap_or(plan.arch);
        setup.push(Row::new(
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
        ));
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
        ));
        setup.push(Row::new(
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
        ));
        if f.wants_eax_unified || st.as_ref().is_some_and(|s| s.eax_unified) {
            setup.push(Row::new(
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
            ));
        }
        self.sound = sound;
        self.setup = setup;
        self.sound_log_on = f
            .launcher
            .as_ref()
            .is_some_and(|t| changes::log_state(t).on());
        self.survey_settings(true);
        self.focus = 0;
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
        self.sound
            .iter()
            .chain(&self.setup)
            .find(|r| r.kind == kind)
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
            Screen::Main if self.problem.is_some() => vec![Button::CheckAgain, Button::OtherTools],
            Screen::Main if self.installed.is_some() => {
                let mut b = vec![Button::Apply, Button::Uninstall];
                if self.facts.launcher.is_some() {
                    b.push(Button::SoundLog);
                }
                b.push(Button::OtherTools);
                b
            }
            Screen::Main => vec![Button::Install, Button::OtherTools],
        }
    }

    /// Everything that can have focus, top to bottom.
    pub fn items(&self) -> Vec<Item> {
        let mut out = Vec::new();
        match &self.screen {
            Screen::Main if self.problem.is_none() => {
                out.extend((0..self.sound.len()).map(Item::Sound));
                out.extend((0..self.setup.len()).map(Item::Setup));
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
            Item::Sound(i) => self.sound.get_mut(i),
            Item::Setup(i) => self.setup.get_mut(i),
            _ => None,
        }
    }

    /// The panel's choices differ from what it opened with.
    pub fn dirty(&self) -> bool {
        self.sound.iter().chain(&self.setup).any(Row::changed) || self.ticked != self.ticked_before
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
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
            Item::Sound(_) => 0,
            Item::Setup(_) => 1,
            Item::Setting(_) => 2,
            Item::Button(_) => 3,
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
            Item::Sound(i) => self.sound[i].options.len(),
            Item::Setup(i) => self.setup[i].options.len(),
            _ => 0,
        };
        match key.code {
            KeyCode::Up => self.list = Some(sel.saturating_sub(1)),
            KeyCode::Down => self.list = Some((sel + 1).min(len.saturating_sub(1))),
            KeyCode::Esc => self.list = None,
            KeyCode::Enter => {
                let speakers_before = self.speakers();
                if let Some(r) = self.rows_mut(item) {
                    r.chosen = sel;
                }
                self.list = None;
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
            Item::Sound(i) => self.list = Some(self.sound[i].chosen),
            Item::Setup(i) => self.list = Some(self.setup[i].chosen),
            Item::Setting(i) => self.toggle(i),
            Item::Button(b) => self.button(b),
        }
    }

    fn button(&mut self, b: Button) {
        match b {
            Button::Install => {
                let plan = self.plan();
                let revert = Vec::new();
                self.start(vec![Job::Install {
                    plan: Box::new(plan),
                    revert,
                }]);
            }
            Button::Apply => {
                let (lines, jobs) = self.changes();
                self.screen = Screen::Confirm { lines, jobs };
                self.focus = 0;
            }
            Button::Uninstall => self.open_uninstall(),
            Button::SoundLog => {
                let level = (!self.sound_log_on).then_some(LogLevel::Full);
                self.start(vec![Job::SoundLog(level)]);
            }
            Button::OtherTools => {
                self.other_tools = true;
                self.closed = true;
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
        let installed = self.installed.is_some();
        let build = match (installed, pick(RowKind::Builds)) {
            (true, 2) | (false, 1) => Build::Latest,
            _ => Build::Stable,
        };
        plan.dsoal_build = build;
        plan.openal_build = build;
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
            RowKind::Builds,
            RowKind::Override,
            RowKind::Arch,
            RowKind::Com,
            RowKind::Limits,
            RowKind::EaxUnified,
            RowKind::Vcrun,
        ];
        let mut reinstall = false;
        for r in self.sound.iter().chain(&self.setup) {
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
                Item::Sound(n) => p.sound[*n].kind == kind,
                Item::Setup(n) => p.setup[*n].kind == kind,
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
        assert_eq!(p.buttons(), [Button::CheckAgain, Button::OtherTools]);
        p.facts.prefix = Some(home.join(".local/share/Steam/steamapps/compatdata/424242/pfx"));
        p.build();
        assert!(p.problem.is_none(), "{:?}", p.problem);
        assert_eq!(p.buttons(), [Button::Install, Button::OtherTools]);
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

        pick(&mut p, RowKind::Builds, 2);
        let (_, jobs) = p.changes();
        assert!(
            matches!(&jobs[..], [Job::Install { plan, .. }] if plan.dsoal_build == Build::Latest)
        );
    }
}
