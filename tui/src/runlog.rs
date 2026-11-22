//! The run log, as the script's `src/logging.sh` writes it, so a bug report
//! can attach the whole picture: a header with the system details the bug
//! report template asks for, every step, detail, warning and answer, the
//! output of the Wine / winetricks / protontricks runs that the screen hides
//! (the prefix's `log` points here), and a summary of what was found.
//!
//! The TUI's logs are kept apart from the script's: their own folder
//! (`tui-logs/`, `tui-logs/dev/` for a dev build), their own file names
//! (`eax-restore-tui-<stamp>.log`), their own `latest.log` and their own
//! newest 10, so neither program rotates the other's out.
//! `EAX_RESTORE_NO_LOG` turns it off, as for the script.

use crate::engine::identify::Store;
use crate::engine::manifest;
use crate::engine::prepare::Facts;
use crate::engine::roots;
use crate::engine::wine::Runner;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const BUG_REPORT_PAGE: &str = "https://github.com/tanuki2k/eax-restore-linux/issues";
pub const BUG_REPORT_URL: &str =
    "https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md";
const PREFIX: &str = "eax-restore-tui-";
const KEEP: usize = 10;

/// `~/.local/state/eax-restore-linux/tui-logs`, with `dev/` for a dev build.
pub fn dir(home: &Path) -> PathBuf {
    let d = roots::xdg_state(home).join("eax-restore-linux/tui-logs");
    if crate::fetch::CHANNEL == "dev" {
        d.join("dev")
    } else {
        d
    }
}

/// The script's `is_truthy`.
fn truthy(v: &str) -> bool {
    matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "y")
}

pub fn disabled() -> bool {
    std::env::var("EAX_RESTORE_NO_LOG").is_ok_and(|v| truthy(&v))
}

/// One line of a command's output, or none when it isn't there or fails.
fn first_line(prog: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text.lines().next()?.trim().to_string();
    (out.status.success() && !line.is_empty()).then_some(line)
}

fn date(format: &str) -> String {
    first_line("date", &[format]).unwrap_or_default()
}

/// `$HOME/` as `~/` wherever it starts a path, as the script's log does; a
/// path that only has the home folder inside it (`/mnt/home/me/…`) is left
/// alone.
pub fn tilde_text(s: &str, home: &Path) -> String {
    let h = format!("{}/", home.display().to_string().trim_end_matches('/'));
    if h == "/" {
        return s.to_string();
    }
    let mut out = String::new();
    let mut rest = s;
    while let Some(i) = rest.find(&h) {
        let pre = &rest[..i];
        let word = pre.rsplit(char::is_whitespace).next().unwrap_or("");
        out.push_str(pre);
        out.push_str(if word.starts_with('/') { &h } else { "~/" });
        rest = &rest[i + h.len()..];
    }
    out.push_str(rest);
    out
}

/// Keeps the newest `KEEP` of the TUI's logs in `dir`. The stamp in the name
/// sorts them by time.
fn rotate(dir: &Path) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut logs: Vec<PathBuf> = rd
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with(PREFIX) && n.ends_with(".log"))
                && !p.is_symlink()
        })
        .collect();
    logs.sort();
    let extra = logs.len().saturating_sub(KEEP);
    for p in &logs[..extra] {
        let _ = fs::remove_file(p);
    }
}

/// What the summary at the end of the log says about the run.
pub struct Summary<'a> {
    pub ok: bool,
    pub title: &'a str,
    pub game: &'a str,
    pub facts: Option<&'a Facts>,
    pub last_step: Option<&'a str>,
}

#[derive(Debug, Clone)]
pub struct RunLog {
    path: PathBuf,
    home: PathBuf,
}

impl RunLog {
    /// A new log for this run, or none when logging is off or the folder
    /// can't be written. `what` says what the run is ("Install BioShock").
    pub fn start(home: &Path, what: &str) -> Option<Self> {
        if disabled() {
            return None;
        }
        Self::start_in(&dir(home), home, what)
    }

    pub fn start_in(dir: &Path, home: &Path, what: &str) -> Option<Self> {
        fs::create_dir_all(dir).ok()?;
        let stamp = date("+%Y%m%d-%H%M%S");
        let mut path = dir.join(format!("{PREFIX}{stamp}.log"));
        let mut n = 2;
        while path.exists() {
            path = dir.join(format!("{PREFIX}{stamp}-{n}.log"));
            n += 1;
        }
        fs::File::create(&path).ok()?;
        let latest = dir.join("latest.log");
        let _ = fs::remove_file(&latest);
        if let Some(name) = path.file_name() {
            let _ = std::os::unix::fs::symlink(name, &latest);
        }
        rotate(dir);
        let log = RunLog {
            path,
            home: home.to_path_buf(),
        };
        log.raw(&header(home, what));
        Some(log)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn raw(&self, s: &str) {
        if let Ok(mut f) = OpenOptions::new().append(true).open(&self.path) {
            let _ = f.write_all(s.as_bytes());
        }
    }

    /// One line, with the home folder shown as `~`.
    pub fn line(&self, s: &str) {
        self.raw(&format!("{}\n", tilde_text(s, &self.home)));
    }

    pub fn step(&self, s: &str) {
        self.line(&format!("\n--- {s} ---"));
    }

    pub fn detail(&self, s: &str) {
        self.line(&format!("    {s}"));
    }

    pub fn warning(&self, s: &str) {
        self.line(&format!("Warning: {s}"));
    }

    pub fn question(&self, text: &str, ask: &str, yes: bool) {
        self.line(&format!("{text}\n{ask} {}", if yes { "Yes" } else { "No" }));
    }

    /// How the run ended, then the summary block the script writes last.
    pub fn summary(&self, s: &Summary, closing: &[String]) {
        self.line("");
        self.line(&format!("=== {} ===", s.title));
        for l in closing {
            self.line(l);
        }
        let mut out = vec![
            String::new(),
            "=== Run summary ===".to_string(),
            format!(
                "Result:          {}",
                if s.ok { "finished" } else { "failed" }
            ),
            format!("Bug report:      {BUG_REPORT_URL}"),
            format!("Finished:        {}", date("+%Y-%m-%d %H:%M:%S %z")),
            format!("Last step:       {}", s.last_step.unwrap_or("none")),
        ];
        if !s.game.is_empty() {
            out.push(format!("Game name:       {}", s.game));
        }
        if let Some(f) = s.facts {
            out.extend(facts_lines(f));
            let m = manifest::path_in(&f.game_dir);
            if let Ok(text) = fs::read_to_string(&m) {
                out.push(format!("Install manifest ({}):", m.display()));
                out.extend(text.lines().map(|l| format!("  {l}")));
            }
        }
        out.push("===================".into());
        for l in out {
            self.line(&l);
        }
    }
}

/// The game's side of the summary: folder, store, prefix, runner, arch.
fn facts_lines(f: &Facts) -> Vec<String> {
    let mut out = vec![format!("Game folder:     {}", f.game_dir.display())];
    let id = if f.id.is_empty() {
        String::new()
    } else {
        format!(" {}", f.id)
    };
    let store = match (f.store, &f.wine_launcher, &f.heroic) {
        (Some(Store::Steam), _, _) => format!("Steam (AppID{id})"),
        (s, Some(w), _) => format!(
            "{}{} through {}",
            if s == Some(Store::Gog) {
                "GOG"
            } else {
                "a game"
            },
            id,
            w.launcher
        ),
        (_, _, Some(_)) => format!("GOG{id} through Heroic"),
        (Some(Store::Gog), _, _) => format!("GOG{id}"),
        (None, None, None) => "not detected".into(),
    };
    out.push(format!("Launcher:        {store}"));
    let prefix = f
        .prefix
        .as_ref()
        .map_or_else(|| "not set".into(), |p| p.display().to_string());
    out.push(format!("Prefix:          {prefix}"));
    // Proton records its version beside the prefix (Steam's compatdata/<id>/
    // version), or in the prefix itself for Heroic's Proton prefixes.
    let proton = f.prefix.as_ref().and_then(|p| {
        [
            p.parent().map(|d| d.join("version")),
            Some(p.join("version")),
        ]
        .into_iter()
        .flatten()
        .find_map(|v| fs::read_to_string(v).ok())
        .and_then(|t| t.lines().next().map(|l| format!("Proton {}", l.trim())))
    });
    let runner = match &f.runner {
        Some(Runner::Protontricks { cmd, app_id }) => {
            format!("protontricks ({}) for AppID {app_id}", cmd.join(" "))
        }
        Some(Runner::Wine { wine, wineserver }) => format!(
            "Wine {}{}",
            wine.display(),
            wineserver
                .as_ref()
                .map_or_else(String::new, |w| format!(" (wineserver {})", w.display()))
        ),
        None => "none".into(),
    };
    out.push(format!(
        "Runner:          {}{runner}",
        proton.map_or_else(String::new, |p| format!("{p}; "))
    ));
    out.push(format!(
        "Architecture:    {}",
        f.arch
            .map_or_else(|| "not detected".into(), |a| format!("{a}-bit"))
    ));
    out
}

/// The header the bug report template asks for.
fn header(home: &Path, what: &str) -> String {
    let distro = fs::read_to_string("/etc/os-release")
        .ok()
        .and_then(|t| {
            let get = |k: &str| {
                t.lines()
                    .find_map(|l| l.strip_prefix(k))
                    .map(|v| v.trim_matches('"').to_string())
            };
            get("PRETTY_NAME=").or_else(|| get("NAME="))
        })
        .unwrap_or_else(|| "unknown".into());
    let kinds = |found: &[(&str, bool)]| {
        let k: Vec<&str> = found.iter().filter(|(_, f)| *f).map(|(n, _)| *n).collect();
        if k.is_empty() {
            "not found".to_string()
        } else {
            k.join(" + ")
        }
    };
    let steam = kinds(&[
        (
            "native",
            home.join(".steam/steam").is_dir() || home.join(".local/share/Steam").is_dir(),
        ),
        (
            "flatpak",
            home.join(".var/app/com.valvesoftware.Steam").is_dir(),
        ),
        ("snap", home.join("snap/steam/common").is_dir()),
    ]);
    let heroic = kinds(&[
        (
            "native",
            roots::xdg_home(home, false).join("heroic").is_dir(),
        ),
        (
            "flatpak",
            home.join(".var/app/com.heroicgameslauncher.hgl/config/heroic")
                .is_dir(),
        ),
    ]);
    let env_var = |k: &str| std::env::var(k).unwrap_or_else(|_| "unknown".into());
    let protontricks = first_line("protontricks", &["--version"])
        .map(|v| format!("{v} (native)"))
        .or_else(|| {
            let info = Command::new("flatpak")
                .args(["info", "com.github.Matoking.protontricks"])
                .stdin(Stdio::null())
                .stderr(Stdio::null())
                .output()
                .ok()
                .filter(|o| o.status.success())?;
            let text = String::from_utf8_lossy(&info.stdout).to_string();
            let v = text
                .lines()
                .find_map(|l| l.trim().strip_prefix("Version:"))
                .map_or("", str::trim)
                .to_string();
            Some(format!("{v} (flatpak)"))
        })
        .unwrap_or_else(|| "not found".into());
    let mut vars: Vec<String> = std::env::vars()
        .filter(|(k, _)| k.starts_with("EAX_RESTORE_"))
        .map(|(k, v)| format!("  {k}={v}"))
        .collect();
    vars.sort();
    let lines = [
        "=== eax-restore-linux TUI run log ===".to_string(),
        format!(
            "Program:         eax-restore TUI {}",
            crate::build_info::label()
        ),
        format!("Run:             {what}"),
        format!("Started:         {}", date("+%Y-%m-%d %H:%M:%S %z")),
        format!("Distro:          {distro}"),
        format!(
            "Kernel:          {}",
            first_line("uname", &["-srm"]).unwrap_or_else(|| "unknown".into())
        ),
        format!(
            "Desktop:         {} ({})",
            env_var("XDG_CURRENT_DESKTOP"),
            env_var("XDG_SESSION_TYPE")
        ),
        format!("Steam install:   {steam}"),
        format!("Heroic install:  {heroic}"),
        format!(
            "wine:            {}",
            first_line("wine", &["--version"]).unwrap_or_else(|| "not in PATH".into())
        ),
        format!(
            "winetricks:      {}",
            first_line("winetricks", &["--version"]).unwrap_or_else(|| "not in PATH".into())
        ),
        format!("protontricks:    {protontricks}"),
        "EAX_RESTORE_* set:".to_string(),
    ];
    let mut out: Vec<String> = lines.to_vec();
    out.extend(vars);
    out.push("=====================================".into());
    out.push(String::new());
    let text = out.join("\n") + "\n";
    tilde_text(&text, home)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn home_becomes_a_tilde_only_where_it_starts_a_path() {
        let home = Path::new("/home/me");
        assert_eq!(
            tilde_text("Prefix: /home/me/.steam/x and /mnt/home/me/y", home),
            "Prefix: ~/.steam/x and /mnt/home/me/y"
        );
        assert_eq!(tilde_text("/home/me/a=/home/me/b", home), "~/a=~/b");
        assert_eq!(tilde_text("nothing here", home), "nothing here");
    }

    #[test]
    fn a_log_has_its_header_and_latest_points_at_it() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("tui-logs");
        let log = RunLog::start_in(&dir, t.path(), "Install BioShock").unwrap();
        let name = log
            .path()
            .file_name()
            .unwrap()
            .to_str()
            .unwrap()
            .to_string();
        assert!(name.starts_with("eax-restore-tui-") && name.ends_with(".log"));
        assert_eq!(
            fs::read_link(dir.join("latest.log")).unwrap(),
            Path::new(&name)
        );
        log.step("Installing the EAX fix");
        log.detail(&format!("Copied {}/game/dsound.dll", t.path().display()));
        log.question("Steam is running.", "Close Steam?", true);
        log.summary(
            &Summary {
                ok: false,
                title: "Not fully installed",
                game: "BioShock",
                facts: None,
                last_step: Some("Installing the EAX fix"),
            },
            &["Something went wrong.".into()],
        );
        let text = fs::read_to_string(log.path()).unwrap();
        assert!(text.contains("Program:         eax-restore TUI "));
        assert!(text.contains("Run:             Install BioShock"));
        assert!(text.contains("--- Installing the EAX fix ---"));
        assert!(text.contains("    Copied ~/game/dsound.dll"));
        assert!(text.contains("Close Steam? Yes"));
        assert!(text.contains("=== Not fully installed ==="));
        assert!(text.contains("Result:          failed"));
        assert!(text.contains("Game name:       BioShock"));
        assert!(text.trim_end().ends_with("==================="));
    }

    #[test]
    fn only_the_newest_ten_tui_logs_stay_and_script_logs_are_left_alone() {
        let t = tempfile::tempdir().unwrap();
        let dir = t.path().join("tui-logs");
        fs::create_dir_all(&dir).unwrap();
        for i in 0..12 {
            fs::write(
                dir.join(format!("eax-restore-tui-2020010{i:02}-000000.log")),
                "",
            )
            .unwrap();
        }
        // A script log that somehow ended up here, and the script's own folder.
        fs::write(dir.join("eax-restore-20200101-000000.log"), "").unwrap();
        let script_logs = t.path().join("logs");
        fs::create_dir_all(&script_logs).unwrap();
        fs::write(script_logs.join("eax-restore-20200101-000000.log"), "").unwrap();

        let log = RunLog::start_in(&dir, t.path(), "Uninstall").unwrap();
        let tui: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| {
                let n = e.file_name();
                let n = n.to_string_lossy();
                n.starts_with("eax-restore-tui-")
            })
            .collect();
        assert_eq!(tui.len(), KEEP);
        assert!(log.path().exists());
        assert!(!dir.join("eax-restore-tui-202001000-000000.log").exists());
        assert!(dir.join("eax-restore-20200101-000000.log").exists());
        assert!(script_logs.join("eax-restore-20200101-000000.log").exists());
    }

    #[test]
    fn the_log_folder_is_the_tuis_own() {
        let home = Path::new("/nonexistent-home");
        let d = dir(home);
        assert!(d.starts_with("/nonexistent-home/.local/state/eax-restore-linux/tui-logs"));
    }

    #[test]
    fn no_log_values() {
        for v in ["1", "true", "YES", "y"] {
            assert!(truthy(v), "{v}");
        }
        for v in ["", "0", "no", "off"] {
            assert!(!truthy(v), "{v}");
        }
    }
}
