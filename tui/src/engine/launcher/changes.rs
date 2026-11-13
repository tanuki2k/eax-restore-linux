//! Changing a game's launcher settings: the DLL override an install adds
//! and an uninstall takes out, and the sound-log variables Tools → DSOAL
//! logging turns on and off. Ports of `_write_launcher_override`,
//! `revert_launcher_overrides` and the change half of
//! `src/dsoal-log-flow.sh`. The launcher must be closed first (it keeps
//! these files in memory and writes them back); that is the caller's,
//! through [`super::control`].

use super::options;
use super::target::{Held, Launcher, Target};
use std::path::{Path, PathBuf};

fn backup_once(file: &Path) {
    let mut bak = file.as_os_str().to_owned();
    bak.push(".eax-restore.bak");
    let bak = PathBuf::from(bak);
    if !bak.exists() {
        let _ = std::fs::copy(file, &bak).and_then(|_| {
            let meta = std::fs::metadata(file)?;
            std::fs::File::options()
                .write(true)
                .open(&bak)?
                .set_modified(meta.modified()?)
        });
    }
}

/// What writing the override came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Written {
    /// The launcher no longer has settings for the game.
    NoApp,
    /// The setting holds a tab or line break, which a manifest line can't
    /// record, so it was left alone.
    Unrecordable,
    /// Set by an earlier install: its manifest line, when one was found, is
    /// carried over (with the value from before that install).
    Already(Option<String>),
    /// Set now; the manifest line to record.
    Set(String),
    /// Couldn't be saved.
    Failed,
}

/// A manifest `LAUNCHER:` line's fields.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LauncherRecord {
    pub launcher: String,
    pub file: PathBuf,
    pub id: String,
    pub old: String,
    pub new: String,
}

impl LauncherRecord {
    pub fn parse(line: &str) -> Option<Self> {
        let body = line.strip_prefix("LAUNCHER:")?;
        let mut f = body.split('\t');
        let mut next = || f.next().unwrap_or("").to_string();
        Some(LauncherRecord {
            launcher: next(),
            file: PathBuf::from(next()),
            id: next(),
            old: next(),
            new: next(),
        })
    }

    pub fn to_line(&self) -> String {
        format!(
            "LAUNCHER:{}\t{}\t{}\t{}\t{}",
            self.launcher,
            self.file.display(),
            self.id,
            self.old,
            self.new
        )
    }
}

/// Adds `<dll>=n,b` to the game's WINEDLLOVERRIDES in the launcher. Steam's
/// sound-log variables are set aside while the override is merged and put
/// back after it, since they aren't part of what the manifest records.
/// `previous` is the last install's `LAUNCHER:` lines; `game_dir` is where
/// a log with no file of its own goes.
pub fn write_override(t: &Target, dll: &str, previous: &[String], game_dir: &str) -> Written {
    let old_held = t.get();
    if old_held == Held::NoApp {
        return Written::NoApp;
    }
    let mut old = old_held.manifest_text();
    let mut logs = None;
    let new = match t.launcher {
        Launcher::Steam => {
            let v = |engine, kind| options::log_value(&old, engine, kind);
            let (dl, df, al, af) = (
                v("DSOAL", "LEVEL"),
                v("DSOAL", "FILE"),
                v("ALSOFT", "LEVEL"),
                v("ALSOFT", "FILE"),
            );
            if !dl.is_empty() || !al.is_empty() {
                old = options::without_log(&old);
                logs = Some((dl, df, al, af));
            }
            let base = if old == "__ABSENT__" {
                ""
            } else {
                old.as_str()
            };
            options::with_override(base, dll)
        }
        Launcher::Heroic => {
            let base = if old == "__ABSENT__" {
                ""
            } else {
                old.as_str()
            };
            options::merge_dll_override(base, dll)
        }
    };
    // A one-time copy before the first change; Heroic's file is
    // re-serialised, so it gets one too.
    backup_once(&t.file);

    if format!("{old}{new}").contains(['\t', '\n', '\r']) {
        return Written::Unrecordable;
    }
    if old == new {
        let carried = previous.iter().find(|line| {
            LauncherRecord::parse(line).is_some_and(|r| {
                r.launcher == t.launcher.key() && r.file == t.file && r.id == t.id && r.new == new
            })
        });
        return Written::Already(carried.cloned());
    }
    let written = match logs {
        Some((dl, df, al, af)) => {
            let al = if al.is_empty() { "3".to_string() } else { al };
            let af = if af.is_empty() {
                options::alsoft_log_path_for_wine(game_dir)
            } else {
                af
            };
            options::with_sound_log(&new, &dl, &df, &al, &af)
        }
        None => new.clone(),
    };
    if t.set(Some(&written)).is_err() || t.get() != Held::Set(written.clone()) {
        return Written::Failed;
    }
    Written::Set(
        LauncherRecord {
            launcher: t.launcher.key().into(),
            file: t.file.clone(),
            id: t.id.clone(),
            old,
            new,
        }
        .to_line(),
    )
}

/// What putting one `LAUNCHER:` line back came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reverted {
    /// The launcher's file is gone; nothing to do.
    NoFile,
    /// The player changed the setting since; it is left alone.
    ChangedSince,
    /// Removed, or put back to what it was.
    Restored,
    /// Couldn't be written; the record stays.
    Failed,
}

const LOG_VARS: [&str; 4] = [
    "DSOAL_LOGLEVEL",
    "DSOAL_LOGFILE",
    "ALSOFT_LOGLEVEL",
    "ALSOFT_LOGFILE",
];

/// Puts a recorded override back, only where it still holds what the
/// install set. The sound-log variables don't count as a change since: with
/// the audio fix gone they're pointless, so they go too.
pub fn revert_override(line: &str) -> Reverted {
    let Some(r) = LauncherRecord::parse(line) else {
        return Reverted::NoFile;
    };
    if !r.file.is_file() {
        return Reverted::NoFile;
    }
    // An unknown launcher reads like Heroic, as in the script.
    let launcher = Launcher::from_key(&r.launcher).unwrap_or(Launcher::Heroic);
    let t = Target {
        launcher,
        file: r.file.clone(),
        id: r.id.clone(),
    };
    let mut current = t.get().manifest_text();
    if launcher == Launcher::Steam {
        current = options::without_log(&current);
    }
    if current != r.new {
        return Reverted::ChangedSince;
    }
    if launcher == Launcher::Heroic {
        for var in LOG_VARS {
            if let Held::Set(_) = t.env(var) {
                let _ = t.set_env(var, None);
            }
        }
    }
    let target = (r.old != "__ABSENT__").then_some(r.old.as_str());
    if t.set(target).is_err() {
        return Reverted::Failed;
    }
    // The one-time copy has served its purpose; left behind it would hold an
    // old launcher config for good.
    let mut bak = r.file.as_os_str().to_owned();
    bak.push(".eax-restore.bak");
    let _ = std::fs::remove_file(PathBuf::from(bak));
    Reverted::Restored
}

/// The sound logs as the launcher has them for the game.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LogState {
    pub dsoal_level: String,
    pub dsoal_file: String,
    pub alsoft_level: String,
    pub alsoft_file: String,
}

impl LogState {
    pub fn on(&self) -> bool {
        !self.dsoal_level.is_empty() || !self.alsoft_level.is_empty()
    }

    /// Where the logs are written on this machine; a missing file name is
    /// the default one in the game folder.
    pub fn paths(&self, game_dir: &str) -> (String, String) {
        let or = |v: &str, d: &str| {
            if v.is_empty() {
                d.to_string()
            } else {
                v.to_string()
            }
        };
        (
            options::log_path_for_linux(&or(&self.dsoal_file, "dsoal.log"), game_dir),
            options::log_path_for_linux(&or(&self.alsoft_file, "openal.log"), game_dir),
        )
    }
}

pub fn log_state(t: &Target) -> LogState {
    match t.launcher {
        Launcher::Steam => {
            let opts = t.get().or_empty();
            let v = |e, k| options::log_value(&opts, e, k);
            LogState {
                dsoal_level: v("DSOAL", "LEVEL"),
                dsoal_file: v("DSOAL", "FILE"),
                alsoft_level: v("ALSOFT", "LEVEL"),
                alsoft_file: v("ALSOFT", "FILE"),
            }
        }
        Launcher::Heroic => {
            let v = |var| t.env(var).or_empty();
            LogState {
                dsoal_level: v("DSOAL_LOGLEVEL"),
                dsoal_file: v("DSOAL_LOGFILE"),
                alsoft_level: v("ALSOFT_LOGLEVEL"),
                alsoft_file: v("ALSOFT_LOGFILE"),
            }
        }
    }
}

/// How much DSOAL logs: 3 traces startup and the API calls, 4 adds every
/// EAX property call, which shows which EAX version a game uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Basic,
    Full,
}

impl LogLevel {
    pub fn dsoal_value(self) -> &'static str {
        match self {
            LogLevel::Basic => "3",
            LogLevel::Full => "4",
        }
    }
}

/// Turns the sound logs on (`Some`) or off (`None`). OpenAL Soft's log is
/// always set; DSOAL's only when `has_dsoal` (DSOAL is the game's dsound.dll).
/// Returns false when the change didn't save. Not recorded in the manifest:
/// turning it off again is this, and an uninstall drops the variables.
pub fn set_sound_log(t: &Target, game_dir: &str, has_dsoal: bool, level: Option<LogLevel>) -> bool {
    let dsoal_wine = options::dsoal_log_path_for_wine(game_dir);
    let alsoft_wine = options::alsoft_log_path_for_wine(game_dir);
    match t.launcher {
        Launcher::Steam => {
            // Read now, as the launcher may have saved changes as it quit.
            let opts = t.get().or_empty();
            let mut new = match level {
                Some(l) => options::with_sound_log(
                    &opts,
                    if has_dsoal { l.dsoal_value() } else { "" },
                    &dsoal_wine,
                    "3",
                    &alsoft_wine,
                ),
                None => options::without_log(&opts),
            };
            backup_once(&t.file);
            let mut expect = Held::Set(new.clone());
            // Empty options, or a bare %command% left over, mean none.
            let squeezed: String = new.chars().filter(|c| !c.is_whitespace()).collect();
            let delete = squeezed.is_empty() || squeezed == "%command%";
            if delete {
                new.clear();
                expect = Held::Absent;
            }
            t.set((!delete).then_some(new.as_str())).is_ok() && t.get() == expect
        }
        Launcher::Heroic => match level {
            Some(l) => {
                let dsoal_ok = !has_dsoal
                    || (t.set_env("DSOAL_LOGLEVEL", Some(l.dsoal_value())).is_ok()
                        && t.set_env("DSOAL_LOGFILE", Some(&dsoal_wine)).is_ok());
                dsoal_ok
                    && t.set_env("ALSOFT_LOGLEVEL", Some("3")).is_ok()
                    && t.set_env("ALSOFT_LOGFILE", Some(&alsoft_wine)).is_ok()
                    && t.env("ALSOFT_LOGLEVEL") == Held::Set("3".into())
            }
            None => {
                let mut ok = true;
                for var in LOG_VARS {
                    if let Held::Set(_) = t.env(var) {
                        ok &= t.set_env(var, None).is_ok();
                    }
                }
                ok
            }
        },
    }
}
