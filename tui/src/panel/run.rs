//! Runs the panel's jobs on a worker thread, so the TUI keeps drawing. The
//! worker sends each step as it starts, notes, questions (closing a
//! launcher, a build with no checksum) and a summary; the panel answers
//! questions over a second channel.

use super::Job;
use crate::db::Game;
use crate::engine::builds::{self, Cache, Curl, Got, Pins};
use crate::engine::host::SystemHost;
use crate::engine::install::{self, Engine, Override};
use crate::engine::installed::Installed;
use crate::engine::launcher::changes;
use crate::engine::launcher::control::{self, Control};
use crate::engine::launcher::target::{Launcher, Target};
use crate::engine::ops;
use crate::engine::prepare::Facts;
use crate::engine::uninstall;
use crate::engine::wine::Prefix;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::time::Duration;

pub enum Msg {
    Step(String),
    Note(String),
    Question(String, String),
    Done { ok: bool, lines: Vec<String> },
}

pub struct RunView {
    /// Each step, and whether it finished (the last one is still running).
    pub steps: Vec<String>,
    pub notes: Vec<String>,
    /// Set when the work is over: whether it all went through, and what it did.
    pub result: Option<(bool, Vec<String>)>,
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
                Msg::Step(s) => self.steps.push(s),
                Msg::Note(n) => self.notes.push(n),
                Msg::Question(text, ask) => return Some((text, ask)),
                Msg::Done { ok, lines } => self.result = Some((ok, lines)),
            }
        }
        None
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
    std::thread::spawn(move || {
        let mut w = Worker {
            tx: tx.clone(),
            answers: answer_rx,
            home,
            reopen: Vec::new(),
        };
        let mut lines = Vec::new();
        let mut ok = true;
        for job in jobs {
            match w.run(job, &facts, game.as_ref(), installed.as_ref(), untested) {
                Ok(l) => lines.extend(l),
                Err(e) => {
                    ok = false;
                    lines.push(e);
                    break;
                }
            }
        }
        w.reopen_launchers();
        let _ = tx.send(Msg::Done { ok, lines });
    });
    RunView {
        steps: Vec::new(),
        notes: Vec::new(),
        result: None,
        rx,
        answers,
    }
}

struct Worker {
    tx: Sender<Msg>,
    answers: Receiver<bool>,
    home: PathBuf,
    reopen: Vec<(String, Vec<String>)>,
}

impl Worker {
    fn step(&self, s: &str) {
        let _ = self.tx.send(Msg::Step(s.to_string()));
    }
    fn note(&self, s: String) {
        let _ = self.tx.send(Msg::Note(s));
    }
    fn ask(&self, text: String, ask: String) -> bool {
        let _ = self.tx.send(Msg::Question(text, ask));
        self.answers.recv().unwrap_or(false)
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
            Job::Install { plan, revert } => {
                self.step("Getting DSOAL and OpenAL Soft");
                let pins = Pins::default();
                let github = builds::Net::reachable(&mut net);
                let mut v = builds::lookup(&cache, &mut net, github, &pins);
                let tx = self.tx.clone();
                let answers = &self.answers;
                let mut confirm = |label: &str| {
                    let _ = tx.send(Msg::Question(
                        format!(
                            "GitHub publishes no checksum for {label}, so the download can't be checked."
                        ),
                        "Install it anyway?".into(),
                    ));
                    answers.recv().unwrap_or(false)
                };
                if plan.engine == Engine::Dsoal {
                    if let Got::Failed(_) = builds::ensure_dsoal(
                        &cache,
                        &mut net,
                        &mut v,
                        plan.dsoal_build,
                        &pins,
                        &mut confirm,
                    ) {
                        return Err(
                            "DSOAL couldn't be downloaded, so nothing was installed.".into()
                        );
                    }
                }
                if let Got::Failed(_) =
                    builds::ensure_openal(&cache, &mut net, &v, plan.openal_build, &mut confirm)
                {
                    return Err(
                        "OpenAL Soft couldn't be downloaded, so nothing was installed.".into(),
                    );
                }
                let r = {
                    let tx = self.tx.clone();
                    let mut on_step = move |s: &str| {
                        let _ = tx.send(Msg::Step(s.to_string()));
                    };
                    let me = std::cell::RefCell::new(&mut *self);
                    let mut close = |t: &Target| {
                        me.borrow_mut().launcher_closed(
                            t,
                            &name,
                            "the DLL override can't be added to",
                            "add the override",
                        )
                    };
                    let mut h = host(facts, game, &mut net, &mut close, &mut on_step, &cache);
                    install::execute(&plan, &cache, &crate::cli::eax_installer(), &mut h)
                };
                if r.no_sources {
                    return Err(format!(
                        "The downloaded builds don't have {}-bit files, so nothing was installed.",
                        plan.arch
                    ));
                }
                lines.push(format!("Copied {} files.", r.copied.len()));
                if let Some(s) = &r.settings {
                    lines.extend(s.applied.iter().map(|t| format!("Turned on \"{t}\".")));
                }
                match &r.over {
                    Some(Override::Launcher(_)) | Some(Override::Registry) => {}
                    _ => {
                        let value = format!("{}=n,b", plan.engine.primary_dll());
                        lines.push("Set the DLL override yourself:".into());
                        if facts.store == Some(crate::engine::identify::Store::Steam) {
                            lines.push(format!(
                                "  Steam launch options: WINEDLLOVERRIDES=\"{value}\" %command%"
                            ));
                        } else {
                            lines.push(format!(
                                "  Heroic environment variable: WINEDLLOVERRIDES = {value}"
                            ));
                        }
                    }
                }
                if !revert.is_empty() {
                    let report = self.with_host(facts, game, &cache, |h| {
                        ops::change_settings(facts, game, &revert, &[], h)
                    });
                    lines.extend(settings_lines(report)?);
                }
                if !r.failures.is_empty() {
                    lines.extend(r.failures.iter().map(|f| format!("Couldn't write {f}.")));
                    return Err(format!(
                        "The EAX fix isn't fully installed, so {name} may run without it."
                    ));
                }
                lines.push(format!("The EAX fix is installed. Launch {name} and turn on EAX in its sound options if it has one."));
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
                for f in &failed {
                    lines.push(format!("Couldn't write {}.", f.display()));
                }
                if let Some(r) = report {
                    lines.extend(settings_lines(Ok(r))?);
                }
                lines.push(format!(
                    "{name} is now set up for {}.",
                    mid_sentence(&super::speakers_label(&new))
                ));
            }
            Job::Settings { revert, plan } => {
                let report = self.with_host(facts, game, &cache, |h| {
                    ops::change_settings(facts, game, &revert, &plan, h)
                });
                lines.extend(settings_lines(report)?);
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
                    let tx = self.tx.clone();
                    let mut on_step = move |s: &str| {
                        let _ = tx.send(Msg::Step(s.to_string()));
                    };
                    let me = std::cell::RefCell::new(&mut *self);
                    let mut close = |t: &Target| {
                        me.borrow_mut().launcher_closed(
                            t,
                            &name,
                            "the DLL override can't be removed from",
                            "remove it",
                        )
                    };
                    let mut h = host(facts, game, &mut net, &mut close, &mut on_step, &cache);
                    uninstall::execute(&survey, &choices, &mut h, &when)
                };
                lines.extend(r.restored.iter().map(|p| {
                    format!(
                        "Put back the original {}.",
                        p.file_name().unwrap_or_default().to_string_lossy()
                    )
                }));
                lines.extend(
                    r.settings_restored
                        .iter()
                        .map(|t| format!("Put back \"{t}\".")),
                );
                lines.extend(r.not_removed.iter().map(|p| {
                    format!(
                        "Couldn't remove {}, so it's still listed as part of the EAX fix.",
                        p.display()
                    )
                }));
                if r.fully_uninstalled {
                    lines.push(format!("The EAX fix is removed from {name}."));
                } else {
                    lines.push(format!("Some of the EAX fix is still in {name}, listed above. Uninstall again to try those once more."));
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
        let tx = self.tx.clone();
        let mut on_step = move |s: &str| {
            let _ = tx.send(Msg::Step(s.to_string()));
        };
        let mut never = |_: &Target| true;
        let mut h = host(facts, game, &mut net, &mut never, &mut on_step, cache);
        f(&mut h)
    }
}

fn settings_lines(
    r: anyhow::Result<crate::engine::apply::UpdateReport>,
) -> Result<Vec<String>, String> {
    let r = r.map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    out.extend(r.restored.iter().map(|t| format!("Put back \"{t}\".")));
    out.extend(
        r.applied
            .applied
            .iter()
            .map(|t| format!("Turned on \"{t}\".")),
    );
    out.extend(
        r.applied
            .failed
            .iter()
            .map(|f| format!("Couldn't write {}.", f.display())),
    );
    Ok(out)
}

fn host<'a>(
    facts: &Facts,
    game: Option<&Game>,
    net: &'a mut Curl,
    close: &'a mut dyn FnMut(&Target) -> bool,
    on_step: &'a mut dyn FnMut(&str),
    cache: &Cache,
) -> SystemHost<'a> {
    SystemHost {
        prefix: Prefix {
            path: facts.prefix.clone().unwrap_or_default(),
            runner: facts.runner.clone(),
            log: None,
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
