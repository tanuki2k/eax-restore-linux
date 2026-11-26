//! Runs the panel's jobs on a worker thread, so the TUI keeps drawing. The
//! worker sends each step as it starts, notes, questions (closing a
//! launcher, a build with no checksum) and a summary; the panel answers
//! questions over a second channel.

use super::Job;
use crate::db::Game;
use crate::engine::builds::{self, Cache, Curl, Got, Pins};
use crate::engine::host::{Event, SystemHost};
use crate::engine::install::{self, Engine, Override};
use crate::engine::installed::Installed;
use crate::engine::launcher::changes;
use crate::engine::launcher::control::{self, Control};
use crate::engine::launcher::target::{Launcher, Target};
use crate::engine::ops;
use crate::engine::prepare::Facts;
use crate::engine::uninstall;
use crate::engine::wine::Prefix;
use crate::runlog::{self, RunLog};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub enum Msg {
    Step(String),
    /// One thing the current step did.
    Detail(String),
    /// Something that went wrong, or that the player should know.
    Note(String),
    Question(String, String),
    Done(Finish),
}

/// How the work ended, as the script's closing screen: a title, numbered
/// next steps, the game settings changed (with what the player still has to
/// do for each), and anything else to say.
#[derive(Debug, Clone, Default)]
pub struct Finish {
    pub ok: bool,
    pub title: String,
    pub next: Vec<String>,
    /// (title, follow-up), the follow-up empty when there's none.
    pub settings: Vec<(String, String)>,
    pub lines: Vec<String>,
    /// The run log, when there is one, with `~` for the home folder.
    pub log: Option<String>,
}

/// The page's channel. Everything sent down it also goes into the run log.
#[derive(Clone)]
struct Out {
    tx: Sender<Msg>,
    log: Option<RunLog>,
    last_step: Arc<Mutex<Option<String>>>,
}

impl Out {
    fn send(&self, m: Msg) {
        if let Msg::Step(s) = &m {
            if let Ok(mut l) = self.last_step.lock() {
                *l = Some(s.clone());
            }
        }
        if let Some(log) = &self.log {
            match &m {
                Msg::Step(s) => log.step(s),
                Msg::Detail(s) => log.detail(s),
                Msg::Note(s) => log.warning(s),
                // A question goes in with its answer; the finish with the summary.
                Msg::Question(..) | Msg::Done(_) => {}
            }
        }
        let _ = self.tx.send(m);
    }

    fn answered(&self, text: &str, ask: &str, yes: bool) {
        if let Some(log) = &self.log {
            log.question(text, ask, yes);
        }
    }

    fn log_path(&self) -> Option<PathBuf> {
        self.log.as_ref().map(|l| l.path().to_path_buf())
    }

    fn last_step(&self) -> Option<String> {
        self.last_step.lock().ok().and_then(|l| l.clone())
    }
}

/// Sends the engine's steps, details and warnings to the page.
fn sender(out: Out) -> impl FnMut(Event, &str) {
    move |e, s| {
        let s = s.to_string();
        out.send(match e {
            Event::Step => Msg::Step(s),
            Event::Detail => Msg::Detail(s),
            Event::Warning => Msg::Note(s),
        });
    }
}

pub struct RunView {
    /// Each step and what it did; the last one is still running.
    pub steps: Vec<(String, Vec<String>)>,
    pub notes: Vec<String>,
    /// Set when the work is over.
    pub result: Option<Finish>,
    rx: Receiver<Msg>,
    answers: Sender<bool>,
}

impl RunView {
    pub fn finished(&self) -> bool {
        self.result.is_some()
    }

    /// Takes the worker's messages; a question it asks comes back.
    pub fn poll(&mut self) -> Option<(String, String)> {
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Msg::Step(s) => self.steps.push((s, Vec::new())),
                Msg::Detail(d) => match self.steps.last_mut() {
                    Some((_, details)) => details.push(d),
                    None => self.steps.push((d, Vec::new())),
                },
                Msg::Note(n) => self.notes.push(n),
                Msg::Question(text, ask) => return Some((text, ask)),
                Msg::Done(f) => self.result = Some(f),
            }
        }
        None
    }

    /// A run that's over, for tests of how it's drawn.
    #[cfg(test)]
    pub fn finished_with(
        steps: Vec<(String, Vec<String>)>,
        notes: Vec<String>,
        finish: Finish,
    ) -> Self {
        let (_tx, rx) = mpsc::channel();
        let (answers, _) = mpsc::channel();
        RunView {
            steps,
            notes,
            result: Some(finish),
            rx,
            answers,
        }
    }

    pub fn answer(&mut self, yes: bool) {
        let _ = self.answers.send(yes);
    }
}

/// Starts the jobs on a worker thread.
pub fn start(
    jobs: Vec<Job>,
    facts: Facts,
    game: Option<Game>,
    installed: Option<Installed>,
    home: PathBuf,
    untested: bool,
) -> RunView {
    let (tx, rx) = mpsc::channel();
    let (answers, answer_rx) = mpsc::channel();
    let titles = titles(&jobs);
    let name = game
        .as_ref()
        .map_or_else(|| facts.game_dir.display().to_string(), |g| g.name.clone());
    let what = format!("{} {name}", run_label(&jobs));
    std::thread::spawn(move || {
        let out = Out {
            tx,
            log: RunLog::start(&home, &what),
            last_step: Arc::default(),
        };
        let mut w = Worker {
            out: out.clone(),
            answers: answer_rx,
            home,
            reopen: Vec::new(),
            next: Vec::new(),
            settings: Vec::new(),
            title: None,
        };
        let mut lines = Vec::new();
        let mut ok = true;
        for job in jobs {
            match w.run(job, &facts, game.as_ref(), installed.as_ref(), untested) {
                Ok(l) => lines.extend(l),
                Err(e) => {
                    ok = false;
                    // One line each, so a command in it isn't run into the text.
                    lines.extend(e.lines().map(String::from));
                    break;
                }
            }
        }
        w.reopen_launchers();
        let title = match w.title {
            Some(t) if ok => t,
            _ if ok => titles.0,
            _ => titles.1,
        };
        if let Some(log) = &out.log {
            let last = out.last_step();
            log.summary(
                &runlog::Summary {
                    ok,
                    title,
                    game: &name,
                    facts: Some(&facts),
                    last_step: last.as_deref(),
                },
                &lines,
            );
        }
        out.send(Msg::Done(Finish {
            ok,
            title: title.to_string(),
            next: w.next,
            settings: w.settings,
            lines,
            log: out
                .log_path()
                .map(|p| runlog::tilde_text(&p.display().to_string(), &w.home)),
        }));
    });
    RunView {
        steps: Vec::new(),
        notes: Vec::new(),
        result: None,
        rx,
        answers,
    }
}

/// What the run is, for the log's header: "Install BioShock".
fn run_label(jobs: &[Job]) -> &'static str {
    match jobs.first() {
        Some(Job::Install { .. }) => "Install",
        Some(Job::Uninstall { .. }) => "Uninstall",
        Some(Job::SoundLog(_)) => "Sound log",
        Some(Job::Speakers(_)) => "Speakers",
        Some(Job::Vcrun(_)) => "VC++ runtime",
        Some(Job::EaxUnified(_)) => "EAX Unified",
        Some(Job::Settings { .. }) => "Game settings",
        None => "Nothing for",
    }
}

/// The finish box's title when it all worked, and when it didn't, from the
/// first job (an Apply that reinstalls starts with the install).
fn titles(jobs: &[Job]) -> (&'static str, &'static str) {
    match jobs.first() {
        Some(Job::Vcrun(_)) if jobs.len() == 1 => {
            ("VC++ runtime installed", "VC++ runtime not installed")
        }
        Some(Job::EaxUnified(_)) if jobs.len() == 1 => {
            ("EAX Unified installed", "EAX Unified not installed")
        }
        Some(Job::Install { .. }) => ("Installed", "Not fully installed"),
        Some(Job::Uninstall { .. }) => ("Uninstalled", "Not fully uninstalled"),
        Some(Job::SoundLog(Some(_))) => ("Sound log on", "Sound log not changed"),
        Some(Job::SoundLog(None)) => ("Sound log off", "Sound log not changed"),
        _ => ("Changes applied", "Not all changes applied"),
    }
}

struct Worker {
    out: Out,
    answers: Receiver<bool>,
    home: PathBuf,
    reopen: Vec<(String, Vec<String>)>,
    /// The finish box's numbered steps and changed settings.
    next: Vec<String>,
    settings: Vec<(String, String)>,
    /// The finish title, when a job ended in a state of its own ("Partly
    /// uninstalled") rather than plain success or failure.
    title: Option<&'static str>,
}

impl Worker {
    fn step(&self, s: &str) {
        self.out.send(Msg::Step(s.to_string()));
    }
    fn detail(&self, s: &str) {
        self.out.send(Msg::Detail(s.to_string()));
    }
    fn note(&self, s: String) {
        self.out.send(Msg::Note(s));
    }
    fn ask(&self, text: String, ask: String) -> bool {
        self.out.send(Msg::Question(text.clone(), ask.clone()));
        let yes = self.answers.recv().unwrap_or(false);
        self.out.answered(&text, &ask, yes);
        yes
    }

    /// Closes a running launcher before its settings change, when the
    /// player agrees, and remembers how to start it again.
    fn launcher_closed(&mut self, t: &Target, game: &str, blocked: &str, yes_does: &str) -> bool {
        let c = Control::for_target(t, &self.home);
        if !c.running() {
            return true;
        }
        let label = t.launcher.label();
        let what = match t.launcher {
            Launcher::Steam => format!("Steam's launch options for {game}"),
            Launcher::Heroic => format!("Heroic's environment variables for {game}"),
        };
        if c.game_running() {
            self.note(format!("A game is running from {label}, so {label} can't be closed and {what} were left alone."));
            return false;
        }
        let Some(cmd) = c.launch_command() else {
            self.note(format!("{label} is running and can't be started again afterwards, so {what} were left alone."));
            return false;
        };
        let yes = self.ask(
            format!("{label} is running, so {blocked} {what}."),
            format!("Close {label}, {yes_does}, then reopen {label}?"),
        );
        if !yes {
            self.note(format!("{what} were left alone."));
            return false;
        }
        self.step(&format!("Waiting for {label} to close"));
        if c.close_and_wait(Duration::from_secs(30)) {
            if !self.reopen.iter().any(|(l, _)| l == label) {
                self.reopen.push((label.to_string(), cmd));
            }
            true
        } else {
            self.note(format!(
                "{label} didn't close in time, so {what} were left alone."
            ));
            false
        }
    }

    fn reopen_launchers(&mut self) {
        for (label, cmd) in std::mem::take(&mut self.reopen) {
            if control::reopen(&cmd) {
                self.note(format!("Reopened {label}."));
            } else {
                self.note(format!(
                    "Couldn't reopen {label}, so you'll need to start it yourself."
                ));
            }
        }
    }

    fn run(
        &mut self,
        job: Job,
        facts: &Facts,
        game: Option<&Game>,
        inst: Option<&Installed>,
        untested: bool,
    ) -> Result<Vec<String>, String> {
        let name = game.map_or_else(|| facts.game_dir.display().to_string(), |g| g.name.clone());
        let cache = Cache::new(&self.home);
        let mut net = Curl::default();
        let mut lines = Vec::new();
        match job {
            Job::Install {
                plan,
                revert,
                audio_done,
            } => {
                if let Some(why) = crate::cli::tools_problem(facts, &name, "try again") {
                    return Err(why);
                }
                if let Some(why) = crate::cli::protontricks_problem(facts, &name) {
                    return Err(why);
                }
                self.step("Getting DSOAL and OpenAL Soft");
                let pins = Pins::default();
                let github = builds::Net::reachable(&mut net);
                let mut v = builds::lookup(&cache, &mut net, github, &pins);
                let out = self.out.clone();
                let answers = &self.answers;
                let mut confirm = |label: &str| {
                    let text = format!(
                        "GitHub publishes no checksum for {label}, so the download can't be checked."
                    );
                    let ask = "Install it anyway?";
                    out.send(Msg::Question(text.clone(), ask.into()));
                    let yes = answers.recv().unwrap_or(false);
                    out.answered(&text, ask, yes);
                    yes
                };
                let mut plan = plan;
                plan.log_to(self.out.log_path().as_deref());
                plan.dsoal_build =
                    builds::resolve_dsoal(plan.dsoal_build.clone(), &cache, &mut net, &v);
                plan.openal_build = builds::resolve_openal(plan.openal_build.clone());
                if plan.engine == Engine::Dsoal {
                    let got = builds::ensure_dsoal(
                        &cache,
                        &mut net,
                        &mut v,
                        plan.dsoal_build.clone(),
                        &pins,
                        &mut confirm,
                    );
                    if let Got::Failed(_) = got {
                        return Err(
                            "DSOAL couldn't be downloaded, so nothing was installed.".into()
                        );
                    }
                    self.detail(&got_text("DSOAL", &got));
                }
                let got = builds::ensure_openal(
                    &cache,
                    &mut net,
                    &v,
                    plan.openal_build.clone(),
                    &mut confirm,
                );
                if let Got::Failed(_) = got {
                    return Err(
                        "OpenAL Soft couldn't be downloaded, so nothing was installed.".into(),
                    );
                }
                self.detail(&got_text("OpenAL Soft", &got));
                plan.dsoal_version = builds::dsoal_version(&plan.dsoal_build, &v, &pins);
                plan.openal_version = builds::openal_version(&plan.openal_build, &v);
                let r = {
                    let log = self.out.log_path();
                    let mut on_step = sender(self.out.clone());
                    let me = std::cell::RefCell::new(&mut *self);
                    let mut close = |t: &Target| {
                        me.borrow_mut().launcher_closed(
                            t,
                            &name,
                            "the DLL override can't be added to",
                            "add the override",
                        )
                    };
                    let mut h = host(facts, game, &mut net, &mut close, &mut on_step, &cache, log);
                    install::execute(&plan, &cache, &crate::cli::eax_installer(), &mut h)
                };
                if r.no_sources {
                    return Err(format!(
                        "The downloaded builds don't have {}-bit files, so nothing was installed.",
                        plan.arch
                    ));
                }
                if !revert.is_empty() {
                    let report = self.with_host(facts, game, &cache, |h| {
                        ops::change_settings(facts, game, &revert, &[], h)
                    });
                    report.map_err(|e| e.to_string())?;
                }
                let over = r.over.clone().unwrap_or(Override::Manual);
                let steam = facts.store == Some(crate::engine::identify::Store::Steam);
                self.next = install::next_steps(&plan, &over, &name, steam, audio_done);
                if let Some(s) = &r.settings {
                    self.settings = s
                        .applied
                        .iter()
                        .map(|t| (t.clone(), follow_up(game, t)))
                        .collect();
                }
                if !r.failures.is_empty() {
                    return Err(format!(
                        "The EAX fix isn't fully installed, so {name} may run without it or fail to start. Fix what's listed under Warnings, then install again, or uninstall to remove what was put in."
                    ));
                }
            }
            Job::Vcrun(mut plan) => {
                if let Some(why) = crate::cli::tools_problem(facts, &name, "try again") {
                    return Err(why);
                }
                if let Some(why) = crate::cli::protontricks_problem(facts, &name) {
                    return Err(why);
                }
                plan.log_to(self.out.log_path().as_deref());
                let added = self.with_host(facts, game, &cache, |h| {
                    ops::add_vcrun(&plan, &facts.game_dir, &cache, h)
                });
                if !added.ok {
                    return Err(format!("The MS VC++ 2022 Redistributable isn't installed in {name}'s prefix. See Warnings."));
                }
                if !added.companions_failed.is_empty() {
                    return Err(format!(
                        "The MS VC++ 2022 Redistributable is installed in {name}'s prefix, but not in {}'s. See Warnings.",
                        added.companions_failed.join(" or ")
                    ));
                }
                lines.push(format!(
                    "The MS VC++ 2022 Redistributable is installed in {name}'s prefix."
                ));
            }
            Job::EaxUnified(mut plan) => {
                if let Some(why) = crate::cli::tools_problem(facts, &name, "try again") {
                    return Err(why);
                }
                if let Some(why) = crate::cli::protontricks_problem(facts, &name) {
                    return Err(why);
                }
                plan.log_to(self.out.log_path().as_deref());
                let added = self.with_host(facts, game, &cache, |h| {
                    ops::add_eax_unified(
                        &plan,
                        &facts.game_dir,
                        &cache,
                        &crate::cli::eax_installer(),
                        h,
                    )
                });
                if !added.ok {
                    return Err(format!(
                        "Creative's EAX Unified isn't installed in {name}'s prefix. See Warnings."
                    ));
                }
                lines.push(format!(
                    "Creative's EAX Unified is installed in {name}'s prefix."
                ));
            }
            Job::Speakers(new) => {
                let Some(inst) = inst else {
                    return Err("The EAX fix isn't installed.".into());
                };
                let (failed, report) = self
                    .with_host(facts, game, &cache, |h| {
                        ops::change_speakers(facts, game, inst, new, untested, h)
                    })
                    .map_err(|e| e.to_string())?;
                if let Some(r) = report {
                    self.settings.extend(
                        r.applied
                            .applied
                            .iter()
                            .map(|t| (t.clone(), follow_up(game, t))),
                    );
                }
                if !failed.is_empty() {
                    return Err(format!(
                        "{name}'s speaker setup wasn't fully changed. See Warnings."
                    ));
                }
                lines.push(format!(
                    "{name} is now set up for {}.",
                    mid_sentence(&super::speakers_label(&new))
                ));
            }
            Job::Settings { revert, plan } => {
                let report = self
                    .with_host(facts, game, &cache, |h| {
                        ops::change_settings(facts, game, &revert, &plan, h)
                    })
                    .map_err(|e| e.to_string())?;
                self.settings.extend(
                    report
                        .applied
                        .applied
                        .iter()
                        .map(|t| (t.clone(), follow_up(game, t))),
                );
                if !report.applied.failed.is_empty() {
                    return Err(format!(
                        "Some of {name}'s settings weren't changed. See Warnings."
                    ));
                }
            }
            Job::SoundLog(level) => {
                let Some(t) = facts.launcher.clone() else {
                    return Err("There are no launcher settings to change.".into());
                };
                let (blocked, yes_does) = if level.is_some() {
                    ("the sound log can't be turned on in", "turn it on")
                } else {
                    ("the sound log can't be turned off in", "turn it off")
                };
                if !self.launcher_closed(&t, &name, blocked, yes_does) {
                    return Err("Nothing was changed.".into());
                }
                self.step(if level.is_some() {
                    "Turning the sound log on"
                } else {
                    "Turning the sound log off"
                });
                let game_dir = facts.game_dir.display().to_string();
                let has_dsoal = facts.game_dir.join("dsoal-aldrv.dll").exists();
                if !changes::set_sound_log(&t, &game_dir, has_dsoal, level) {
                    return Err(format!(
                        "Couldn't save the change to {}'s settings for {name}.",
                        t.launcher.label()
                    ));
                }
                if level.is_some() {
                    lines.push(format!("The sound log is on. Start {name} and the log will be written to its folder (openal.log{}).", if has_dsoal { " and dsoal.log" } else { "" }));
                } else {
                    lines.push(format!("The sound log is off for {name}."));
                }
            }
            Job::Uninstall { survey, choices } => {
                let when = std::process::Command::new("date")
                    .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_default();
                let r = {
                    let log = self.out.log_path();
                    let mut on_step = sender(self.out.clone());
                    let me = std::cell::RefCell::new(&mut *self);
                    let mut close = |t: &Target| {
                        me.borrow_mut().launcher_closed(
                            t,
                            &name,
                            "the DLL override can't be removed from",
                            "remove it",
                        )
                    };
                    let mut h = host(facts, game, &mut net, &mut close, &mut on_step, &cache, log);
                    uninstall::execute(&survey, &choices, &mut h, &when)
                };
                if r.fully_uninstalled {
                    lines.push(format!("The EAX fix is removed from {name}."));
                } else if r.partly_uninstalled {
                    self.title = Some("Partly uninstalled");
                    let kept = uninstall::kept_parts(&r.launcher_kept, &r.settings_kept);
                    lines.push(format!(
                        "The EAX fix is removed from {name}, apart from {}, which you chose to keep.",
                        kept.join(" and ")
                    ));
                } else {
                    return Err(format!("Some of the EAX fix is still in {name}, listed under Warnings. Uninstall again to try those once more."));
                }
            }
        }
        Ok(lines)
    }

    fn with_host<T>(
        &mut self,
        facts: &Facts,
        game: Option<&Game>,
        cache: &Cache,
        f: impl FnOnce(&mut SystemHost) -> T,
    ) -> T {
        let mut net = Curl::default();
        let mut on_step = sender(self.out.clone());
        let mut never = |_: &Target| true;
        let log = self.out.log_path();
        let mut h = host(facts, game, &mut net, &mut never, &mut on_step, cache, log);
        f(&mut h)
    }
}

/// A changed setting's follow-up from the game's profile ("Don't forget to
/// set your AV receiver…"), or empty.
fn follow_up(game: Option<&Game>, title: &str) -> String {
    game.into_iter()
        .flat_map(|g| {
            g.game_config
                .audio_settings
                .iter()
                .chain(&g.game_config.optional_settings)
        })
        .find(|s| s.title == title)
        .and_then(|s| s.follow_up.clone())
        .unwrap_or_default()
}

/// What happened to a download, as a line under "Getting DSOAL and OpenAL Soft".
fn got_text(what: &str, got: &Got) -> String {
    match got {
        Got::UpToDate => format!("{what} is up to date"),
        Got::Downloaded => format!("Downloaded {what}"),
        Got::Cached => format!("GitHub can't be reached, so using the {what} downloaded earlier"),
        Got::KeptOld => format!("The download failed, so using the {what} downloaded earlier"),
        Got::Failed(_) => format!("{what} couldn't be downloaded"),
    }
}

fn host<'a>(
    facts: &Facts,
    game: Option<&Game>,
    net: &'a mut Curl,
    close: &'a mut dyn FnMut(&Target) -> bool,
    on_step: &'a mut dyn FnMut(Event, &str),
    cache: &Cache,
    // The run log, where the Wine side's own output goes.
    log: Option<PathBuf>,
) -> SystemHost<'a> {
    SystemHost {
        prefix: Prefix {
            path: facts.prefix.clone().unwrap_or_default(),
            runner: facts.runner.clone(),
            log,
        },
        game_dir: facts.game_dir.clone(),
        game_exe: game.map(|g| g.exe.clone()).unwrap_or_default(),
        protontricks: crate::cli::protontricks(),
        net,
        cache: cache.root.clone(),
        eax_unified: crate::cli::eax_installer(),
        close_launcher: close,
        on_step,
    }
}

/// A row's value inside a sentence: lowercase, but "Pro Logic" is a name.
fn mid_sentence(label: &str) -> String {
    if label.starts_with("Pro Logic") {
        return label.to_string();
    }
    let mut c = label.chars();
    c.next()
        .map(|f| f.to_lowercase().chain(c).collect())
        .unwrap_or_default()
}
