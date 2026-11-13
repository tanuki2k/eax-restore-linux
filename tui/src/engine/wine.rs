//! Running things in a game's Wine prefix: through protontricks for a Steam
//! game (Proton's own Wine, inside the Steam Runtime), or the Wine build
//! Heroic runs the game with. Ports of `apply_registry_patch`,
//! `flush_wine_registry`, `install_openal_runtime`,
//! `steam_prefix_for_appid`, `resolve_heroic_runner` and the architecture
//! check in `select_architecture`.

use serde_json::Value;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// How to run Wine in a game's prefix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Runner {
    /// A Steam game: protontricks with its AppID. `cmd` is how to run
    /// protontricks (`protontricks`, or the Flatpak's `flatpak run …`).
    Protontricks { cmd: Vec<String>, app_id: String },
    /// A Heroic (or plain Wine) game.
    Wine {
        wine: PathBuf,
        /// Heroic's own wineserver, when it names one that exists.
        wineserver: Option<PathBuf>,
    },
}

/// One prefix, how to reach it, and where to log what runs in it.
#[derive(Debug, Clone)]
pub struct Prefix {
    pub path: PathBuf,
    pub runner: Option<Runner>,
    /// The run log; commands' output is appended there.
    pub log: Option<PathBuf>,
}

/// The way the script quotes an argument for `sh -c` (protontricks -c runs
/// its argument through sh).
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

impl Prefix {
    fn log_line(&self, text: &str) {
        if let Some(log) = &self.log {
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(log)
            {
                let _ = writeln!(f, "{text}");
            }
        }
    }

    /// Runs a command with its output in the log; its exit code, or `None`
    /// when it couldn't start.
    fn run(&self, mut cmd: Command) -> Option<i32> {
        let out = match &self.log {
            Some(log) => std::fs::OpenOptions::new()
                .append(true)
                .create(true)
                .open(log)
                .map(Stdio::from)
                .unwrap_or_else(|_| Stdio::null()),
            None => Stdio::null(),
        };
        let err = match &self.log {
            Some(log) => std::fs::OpenOptions::new()
                .append(true)
                .open(log)
                .map(Stdio::from)
                .unwrap_or_else(|_| Stdio::null()),
            None => Stdio::null(),
        };
        let code = cmd
            .stdin(Stdio::null())
            .stdout(out)
            .stderr(err)
            .status()
            .ok()?
            .code();
        let code = code.unwrap_or(1);
        self.log_line(&format!("[exit {code}]"));
        Some(code)
    }

    fn protontricks(cmd: &[String]) -> Command {
        let mut c = Command::new(&cmd[0]);
        c.args(&cmd[1..]);
        c
    }

    /// The wineserver to wait on for a plain Wine runner: Heroic's own, or
    /// the one beside the wine binary, or the one on PATH.
    fn wineserver(wine: &Path, own: Option<&Path>) -> PathBuf {
        if let Some(s) = own {
            return s.to_path_buf();
        }
        let beside = wine.parent().unwrap_or(Path::new("")).join("wineserver");
        if is_executable(&beside) {
            beside
        } else {
            PathBuf::from("wineserver")
        }
    }

    /// Imports a .reg file into the prefix. `None` when there's nothing to
    /// run it with (no AppID, Wine binary or prefix) or the file is empty.
    pub fn regedit(&self, reg: &Path) -> Option<i32> {
        if std::fs::metadata(reg).map_or(true, |m| m.len() == 0) {
            self.log_line(&format!(
                "regedit skipped: {} is missing or empty",
                reg.display()
            ));
            return None;
        }
        match &self.runner {
            Some(Runner::Protontricks { cmd, app_id }) => {
                self.log_line(&format!(
                    "protontricks regedit {} (AppID {app_id})",
                    reg.display()
                ));
                let mut c = Self::protontricks(cmd);
                c.arg("-c")
                    .arg(format!("regedit {}", shell_quote(&reg.to_string_lossy())))
                    .arg(app_id);
                self.run(c)
            }
            Some(Runner::Wine { wine, .. }) if self.path.join("drive_c").is_dir() => {
                self.log_line(&format!("{} regedit {}", wine.display(), reg.display()));
                let mut c = Command::new(wine);
                c.env("WINEPREFIX", &self.path).arg("regedit").arg(reg);
                self.run(c)
            }
            _ => {
                self.log_line(&format!(
                    "regedit skipped: no AppID, Wine binary, or prefix to apply {} to",
                    reg.display()
                ));
                None
            }
        }
    }

    /// Waits (up to a minute) for wineserver to save the registry and exit:
    /// Wine keeps it in memory and writes user.reg / system.reg back only
    /// then. Best effort.
    pub fn wait_for_wineserver(&self) {
        match &self.runner {
            Some(Runner::Protontricks { cmd, app_id }) => {
                let mut c = Self::protontricks(cmd);
                c.arg("-c").arg("timeout 60 wineserver -w").arg(app_id);
                self.run(c);
            }
            Some(Runner::Wine { wine, wineserver }) => {
                let server = Self::wineserver(wine, wineserver.as_deref());
                let mut c = Command::new("timeout");
                c.env("WINEPREFIX", &self.path)
                    .arg("60")
                    .arg(server)
                    .arg("-w");
                self.run(c);
            }
            None => {}
        }
    }

    /// Creative's OpenAL runtime, through protontricks or winetricks. Its
    /// exit code, or `None` when there's no Wine to run it with.
    pub fn install_openal_runtime(&self) -> Option<i32> {
        match &self.runner {
            Some(Runner::Protontricks { cmd, app_id }) => {
                let mut c = Self::protontricks(cmd);
                c.arg(app_id).arg("-q").arg("openal");
                self.run(c)
            }
            Some(Runner::Wine { wine, wineserver }) => {
                // --force gets past winetricks' safety blocks in Heroic's prefixes.
                let mut c = Command::new("winetricks");
                c.env("WINEPREFIX", &self.path)
                    .env("WINE", wine)
                    .env(
                        "WINESERVER",
                        wineserver
                            .as_deref()
                            .map(Path::as_os_str)
                            .unwrap_or_default(),
                    )
                    .args(["--force", "-q", "openal"]);
                self.run(c)
            }
            None => None,
        }
    }
}

pub fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// A Steam app's Proton prefix as protontricks reports it, or `None` when it
/// has none yet (never launched) or protontricks can't see it.
pub fn steam_prefix_for_appid(protontricks: &[String], app_id: &str) -> Option<PathBuf> {
    let out = Command::new(&protontricks[0])
        .args(&protontricks[1..])
        .arg("-c")
        .arg("echo $WINEPREFIX")
        .arg(app_id)
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&out.stdout);
    let line = text
        .lines()
        .rfind(|l| l.contains("/pfx"))?
        .replace('\r', "");
    let p = PathBuf::from(line);
    (!p.as_os_str().is_empty() && p.join("drive_c").is_dir()).then_some(p)
}

/// The Wine build Heroic runs a game with, from its GamesConfig file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeroicRunner {
    /// `wine` or `proton`, as Heroic records it.
    pub kind: String,
    /// The name Heroic's Wine Version list shows.
    pub name: String,
    /// The binary Heroic records.
    pub bin: String,
    /// The wine binary to use, when it was found.
    pub wine: Option<PathBuf>,
    pub wineserver: Option<PathBuf>,
}

/// Every GamesConfig file (native, then Flatpak Heroic) whose winePrefix is
/// exactly this prefix, with or without a trailing slash.
pub fn heroic_configs_for_prefix(home: &Path, prefix: &Path) -> Vec<PathBuf> {
    let p = prefix.to_string_lossy();
    let p = p.strip_suffix('/').unwrap_or(&p);
    let wanted = [
        format!("\"winePrefix\": \"{p}\""),
        format!("\"winePrefix\": \"{p}/\""),
    ];
    let mut out = Vec::new();
    for root in [
        ".config/heroic",
        ".var/app/com.heroicgameslauncher.hgl/config/heroic",
    ] {
        let Ok(entries) = std::fs::read_dir(home.join(root).join("GamesConfig")) else {
            continue;
        };
        let mut files: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|e| e == "json"))
            .collect();
        files.sort();
        out.extend(files.into_iter().filter(|f| {
            std::fs::read_to_string(f).is_ok_and(|t| wanted.iter().any(|w| t.contains(w.as_str())))
        }));
    }
    out
}

/// Reads the runner from `json` (the game's GamesConfig file, or one that
/// claims its prefix). `None` when the file names none.
pub fn heroic_runner(json: &Path) -> Option<HeroicRunner> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(json).ok()?).ok()?;
    let wv = v
        .as_object()?
        .values()
        .filter_map(Value::as_object)
        .find_map(|o| {
            o.get("wineVersion")
                .filter(|w| !w.is_null() && *w != &Value::Bool(false))
        })?;
    let text = |k: &str| match wv.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | Some(Value::Bool(false)) | None => String::new(),
        Some(other) => other.to_string(),
    };
    let (kind, bin, name, server) = (text("type"), text("bin"), text("name"), text("wineserver"));
    let mut wine = None;
    let mut wineserver = PathBuf::from(&server);
    match kind.as_str() {
        "proton" => {
            let dir = Path::new(&bin).parent().unwrap_or(Path::new(""));
            for d in ["files/bin", "dist/bin"] {
                let w = dir.join(d).join("wine");
                if is_executable(&w) {
                    wineserver = dir.join(d).join("wineserver");
                    wine = Some(w);
                    break;
                }
            }
        }
        "wine" => {
            if is_executable(Path::new(&bin)) {
                wine = Some(PathBuf::from(&bin));
            }
            if server.is_empty() {
                wineserver = Path::new(&bin)
                    .parent()
                    .unwrap_or(Path::new(""))
                    .join("wineserver");
            }
        }
        _ => {}
    }
    Some(HeroicRunner {
        kind,
        name,
        bin,
        wineserver: (wine.is_some() && is_executable(&wineserver)).then_some(wineserver),
        wine,
    })
}

/// Which GamesConfig file to read a Heroic game's runner from: its own when
/// that names a Wine version, else the first that claims the prefix.
pub fn heroic_runner_config(
    home: &Path,
    heroic_root: Option<&Path>,
    app_name: Option<&str>,
    prefix: &Path,
) -> Option<PathBuf> {
    if let (Some(root), Some(app)) = (heroic_root, app_name) {
        let own = root.join("GamesConfig").join(format!("{app}.json"));
        if std::fs::read_to_string(&own).is_ok_and(|t| t.contains("\"wineVersion\"")) {
            return Some(own);
        }
    }
    heroic_configs_for_prefix(home, prefix).into_iter().next()
}

/// A Windows executable's kind, the way `file` tells PE32 from PE32+.
fn is_pe32_plus(path: &Path) -> bool {
    let Ok(data) = std::fs::read(path) else {
        return false;
    };
    let u32_at = |at: usize| -> Option<usize> {
        let b = data.get(at..at + 4)?;
        Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize)
    };
    if !data.starts_with(b"MZ") {
        return false;
    }
    let Some(pe) = u32_at(0x3c) else { return false };
    data.get(pe..pe + 4) == Some(b"PE\0\0") && data.get(pe + 24..pe + 26) == Some(&[0x0b, 0x02][..])
}

/// How many `.exe` files in the game folder (and the folders right under
/// it) are 32-bit and how many 64-bit. Anything that isn't a 64-bit PE
/// counts as 32-bit, as in the script.
pub fn count_exe_bitness(game_dir: &Path) -> (usize, usize) {
    fn walk(dir: &Path, depth: usize, out: &mut (usize, usize)) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let Ok(t) = e.file_type() else { continue };
            let p = e.path();
            if t.is_dir() && depth < 2 {
                walk(&p, depth + 1, out);
            } else if t.is_file() && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("exe")) {
                if is_pe32_plus(&p) {
                    out.1 += 1;
                } else {
                    out.0 += 1;
                }
            }
        }
    }
    let mut out = (0, 0);
    walk(game_dir, 1, &mut out);
    out
}

/// The game's architecture from its exes: the majority, since an
/// uninstaller or patcher of the other kind often sits beside the game.
/// `None` on a tie or with no exes.
pub fn detect_architecture(game_dir: &Path) -> Option<u8> {
    let (a32, a64) = count_exe_bitness(game_dir);
    match a64.cmp(&a32) {
        std::cmp::Ordering::Greater => Some(64),
        std::cmp::Ordering::Less => Some(32),
        std::cmp::Ordering::Equal => None,
    }
}
