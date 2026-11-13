//! Closing a launcher before its settings file is changed, and starting it
//! again after. Steam and Heroic keep these files in memory and write them
//! back themselves, so an edit made while one runs is lost. Ports of
//! `launcher_native_pids`, `launcher_running`, `launcher_launch_cmd`,
//! `launcher_game_running`, `_close_launcher_and_wait` and
//! `reopen_launchers` in `src/launcher-config.sh`. Whether to close it is
//! the caller's question to ask; nothing here asks.

use super::target::{Launcher, Target};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// One process, read from `/proc`.
#[derive(Debug, Clone)]
struct Proc {
    pid: u32,
    ppid: u32,
    /// The executable's name (`comm`).
    name: String,
    /// The arguments joined by spaces.
    args: String,
    flatpak: bool,
}

fn processes(proc_root: &Path) -> Vec<Proc> {
    let Ok(entries) = std::fs::read_dir(proc_root) else {
        return Vec::new();
    };
    entries
        .flatten()
        .filter_map(|e| {
            let pid: u32 = e.file_name().to_str()?.parse().ok()?;
            let dir = e.path();
            let stat = std::fs::read_to_string(dir.join("stat")).ok()?;
            let open = stat.find('(')?;
            let close = stat.rfind(')')?;
            let name = stat[open + 1..close].to_string();
            let ppid = stat[close + 1..].split_whitespace().nth(1)?.parse().ok()?;
            let raw = std::fs::read(dir.join("cmdline")).unwrap_or_default();
            let args = String::from_utf8_lossy(&raw)
                .trim_end_matches('\0')
                .replace('\0', " ");
            let flatpak = std::fs::read_to_string(dir.join("cgroup"))
                .is_ok_and(|c| c.contains("app-flatpak-"));
            Some(Proc {
                pid,
                ppid,
                name,
                args,
                flatpak,
            })
        })
        .collect()
}

/// `heroic-games-launcher|com\.heroicgameslauncher\.hgl|/heroic/heroic|Heroic[^/]*\.AppImage`
fn is_heroic(args: &str) -> bool {
    if args.contains("heroic-games-launcher")
        || args.contains("com.heroicgameslauncher.hgl")
        || args.contains("/heroic/heroic")
    {
        return true;
    }
    args.match_indices("Heroic").any(|(at, _)| {
        let rest = &args[at + "Heroic".len()..];
        let stop = rest.find('/').unwrap_or(rest.len());
        rest[..stop].contains(".AppImage")
    })
}

fn is_launcher(p: &Proc, l: Launcher) -> bool {
    match l {
        Launcher::Steam => p.name == "steam",
        Launcher::Heroic => is_heroic(&p.args),
    }
}

/// The launcher's processes outside any Flatpak sandbox: a sandboxed Steam
/// is also called "steam", but its cgroup tells them apart.
fn native_pids(procs: &[Proc], l: Launcher) -> Vec<u32> {
    procs
        .iter()
        .filter(|p| is_launcher(p, l) && !p.flatpak)
        .map(|p| p.pid)
        .collect()
}

fn on_path(cmd: &str) -> Option<PathBuf> {
    std::env::var_os("PATH").and_then(|paths| {
        std::env::split_paths(&paths)
            .map(|d| d.join(cmd))
            .find(|p| p.is_file())
    })
}

/// The copy of a launcher a target belongs to.
pub struct Control {
    pub launcher: Launcher,
    pub flatpak: bool,
    proc_root: PathBuf,
}

impl Control {
    pub fn for_target(t: &Target, home: &Path) -> Self {
        Control {
            launcher: t.launcher,
            flatpak: t.is_flatpak(home),
            proc_root: PathBuf::from("/proc"),
        }
    }

    pub fn running(&self) -> bool {
        if self.flatpak {
            return Command::new("flatpak")
                .args(["ps", "--columns=application"])
                .stderr(Stdio::null())
                .output()
                .is_ok_and(|o| {
                    String::from_utf8_lossy(&o.stdout)
                        .lines()
                        .any(|l| l == self.launcher.flatpak_id())
                });
        }
        !native_pids(&processes(&self.proc_root), self.launcher).is_empty()
    }

    /// How to start it again the way it runs now: `flatpak run <id>`, the
    /// AppImage it was started from, or the command on PATH. `None` when
    /// there's no telling, and then it shouldn't be closed for the player.
    pub fn launch_command(&self) -> Option<Vec<String>> {
        if self.flatpak {
            return on_path("flatpak").map(|_| {
                vec![
                    "flatpak".into(),
                    "run".into(),
                    self.launcher.flatpak_id().into(),
                ]
            });
        }
        for pid in native_pids(&processes(&self.proc_root), self.launcher) {
            let environ = std::fs::read(self.proc_root.join(pid.to_string()).join("environ"))
                .unwrap_or_default();
            let appimage = environ
                .split(|&b| b == 0)
                .find_map(|v| v.strip_prefix(b"APPIMAGE="))
                .map(|v| PathBuf::from(String::from_utf8_lossy(v).into_owned()));
            if let Some(a) = appimage {
                use std::os::unix::fs::PermissionsExt;
                if std::fs::metadata(&a)
                    .is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
                {
                    return Some(vec![a.display().to_string()]);
                }
            }
        }
        let name = match self.launcher {
            Launcher::Steam => "steam",
            Launcher::Heroic => "heroic",
        };
        on_path(name).map(|_| vec![name.to_string()])
    }

    /// True while a game started from the launcher runs, since closing the
    /// launcher would quit it. Steam starts every game through its "reaper
    /// SteamLaunch" process; Heroic's run as Wine/Proton children of it.
    pub fn game_running(&self) -> bool {
        game_running_in(
            &processes(&self.proc_root),
            self.launcher,
            std::process::id(),
        )
    }

    /// Asks the launcher to quit, then waits up to `timeout` for it to go.
    /// Steam's -shutdown has the running Steam save and exit; Heroic has no
    /// such switch, but saves a game's settings as soon as they change.
    pub fn close_and_wait(&self, timeout: Duration) -> bool {
        match (self.launcher, self.flatpak) {
            (Launcher::Steam, true) => spawn_detached(&[
                "timeout",
                "20",
                "flatpak",
                "run",
                Launcher::Steam.flatpak_id(),
                "-shutdown",
            ]),
            (Launcher::Steam, false) => spawn_detached(&["timeout", "20", "steam", "-shutdown"]),
            (Launcher::Heroic, true) => {
                let _ = Command::new("flatpak")
                    .args(["kill", Launcher::Heroic.flatpak_id()])
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .status();
            }
            (Launcher::Heroic, false) => {
                for p in processes(&self.proc_root) {
                    // Electron's helpers (--type=…) go with the main process.
                    if is_heroic(&p.args) && !p.flatpak && !p.args.contains("--type=") {
                        let _ = Command::new("kill")
                            .args(["-TERM", &p.pid.to_string()])
                            .stderr(Stdio::null())
                            .status();
                    }
                }
            }
        }
        let start = Instant::now();
        while self.running() {
            if start.elapsed() >= timeout {
                return false;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
        true
    }
}

fn spawn_detached(cmd: &[&str]) {
    let _ = Command::new(cmd[0])
        .args(&cmd[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Starts a launcher again, detached from this program so it keeps running
/// after it ends.
pub fn reopen(cmd: &[String]) -> bool {
    Command::new("setsid")
        .arg("-f")
        .args(cmd)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

fn game_running_in(procs: &[Proc], l: Launcher, me: u32) -> bool {
    let parent: HashMap<u32, u32> = procs.iter().map(|p| (p.pid, p.ppid)).collect();
    // This program's own processes are left out: a command line that
    // mentions the launcher, or this check, isn't a game.
    let ours = |mut p: u32| {
        while p > 1 {
            if p == me {
                return true;
            }
            p = parent.get(&p).copied().unwrap_or(1);
        }
        false
    };
    match l {
        Launcher::Steam => procs
            .iter()
            .any(|p| p.args.contains("reaper SteamLaunch") && !ours(p.pid)),
        Launcher::Heroic => {
            let roots: HashSet<u32> = procs
                .iter()
                .filter(|p| is_heroic(&p.args) && !ours(p.pid))
                .map(|p| p.pid)
                .collect();
            procs.iter().any(|p| {
                if ours(p.pid) {
                    return false;
                }
                let a = p.args.to_lowercase();
                if !(a.contains("wine") || a.contains("proton") || p.args.contains(".exe")) {
                    return false;
                }
                let mut up = p.ppid;
                while up > 1 {
                    if roots.contains(&up) {
                        return true;
                    }
                    up = parent.get(&up).copied().unwrap_or(1);
                }
                false
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(pid: u32, ppid: u32, name: &str, args: &str, flatpak: bool) -> Proc {
        Proc {
            pid,
            ppid,
            name: name.into(),
            args: args.into(),
            flatpak,
        }
    }

    #[test]
    fn heroic_command_lines() {
        assert!(is_heroic("/opt/heroic/heroic"));
        // The pattern is case-sensitive, as pgrep -f has it.
        assert!(!is_heroic("/opt/Heroic/heroic"));
        assert!(is_heroic("/usr/bin/heroic-games-launcher --no-sandbox"));
        assert!(is_heroic("/home/u/Apps/Heroic-2.15.AppImage"));
        assert!(!is_heroic("/home/u/Heroic/x.AppImage"));
        assert!(!is_heroic("/usr/bin/steam"));
    }

    #[test]
    fn sandboxed_steam_is_not_the_native_one() {
        let procs = [
            p(10, 1, "steam", "/usr/bin/steam", false),
            p(20, 1, "steam", "/app/bin/steam", true),
        ];
        assert_eq!(native_pids(&procs, Launcher::Steam), vec![10]);
    }

    #[test]
    fn games_running_from_a_launcher() {
        let steam = [p(
            5,
            1,
            "reaper",
            "reaper SteamLaunch AppId=2210 -- x",
            false,
        )];
        assert!(game_running_in(&steam, Launcher::Steam, 999));
        let heroic = [
            p(10, 1, "heroic", "/opt/heroic/heroic", false),
            p(11, 10, "sh", "sh -c run", false),
            p(12, 11, "wine", "wine64 Z:\\games\\game.exe", false),
        ];
        assert!(game_running_in(&heroic, Launcher::Heroic, 999));
        // The same tree started by this program doesn't count.
        let ours = [
            p(999, 1, "eax", "eax-restore", false),
            p(10, 999, "heroic", "/opt/heroic/heroic", false),
            p(12, 10, "wine", "wine64 game.exe", false),
        ];
        assert!(!game_running_in(&ours, Launcher::Heroic, 999));
        assert!(!game_running_in(&heroic[..1], Launcher::Heroic, 999));
    }
}
