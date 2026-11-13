//! Which launcher settings file holds a game's launch options or environment
//! variables, and reading and writing the DLL override there. Ports of
//! `steam_roots`, `steam_localconfig_for_app`, `launcher_override_target`,
//! `launcher_override_get` and `launcher_override_set`.

use super::heroic::{self, EnvValue};
use super::vdf::{self, LaunchOptions};
use anyhow::Result;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Launcher {
    Steam,
    Heroic,
}

impl Launcher {
    /// The name in a manifest's `LAUNCHER:` lines.
    pub fn key(self) -> &'static str {
        match self {
            Launcher::Steam => "steam",
            Launcher::Heroic => "heroic",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Launcher::Steam => "Steam",
            Launcher::Heroic => "Heroic",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        match key {
            "steam" => Some(Launcher::Steam),
            "heroic" => Some(Launcher::Heroic),
            _ => None,
        }
    }

    pub fn flatpak_id(self) -> &'static str {
        match self {
            Launcher::Steam => "com.valvesoftware.Steam",
            Launcher::Heroic => "com.heroicgameslauncher.hgl",
        }
    }
}

/// One game's settings in one launcher's file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub launcher: Launcher,
    pub file: PathBuf,
    /// The Steam AppID, or Heroic's appName.
    pub id: String,
}

/// What the target holds: Steam's launch options, or Heroic's
/// WINEDLLOVERRIDES variable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Held {
    NoApp,
    Absent,
    Set(String),
}

impl Held {
    /// The manifest's spelling: the value, or `__ABSENT__` / `__NOAPP__`.
    pub fn manifest_text(&self) -> String {
        match self {
            Held::NoApp => "__NOAPP__".into(),
            Held::Absent => "__ABSENT__".into(),
            Held::Set(s) => s.clone(),
        }
    }

    /// The value, with nothing there read as empty.
    pub fn or_empty(&self) -> String {
        match self {
            Held::Set(s) => s.clone(),
            _ => String::new(),
        }
    }
}

/// Every Steam install present, native first, then Flatpak (its current
/// and older data layouts), each resolved through links.
pub fn steam_roots(home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for group in [
        [".local/share/Steam", ".steam/steam"],
        [
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/data/Steam",
        ],
    ] {
        if let Some(d) = group
            .iter()
            .map(|d| home.join(d))
            .find(|d| d.join("steamapps").is_dir())
        {
            out.push(std::fs::canonicalize(&d).unwrap_or(d));
        }
    }
    out
}

/// The localconfig.vdf (across Steam installs and accounts) that has a
/// settings block for the game; if more than one does, the one changed most
/// recently. `extra_root` is a Steam folder found some other way.
pub fn steam_localconfig_for_app(
    home: &Path,
    extra_root: Option<&Path>,
    app_id: &str,
) -> Option<PathBuf> {
    let mut roots: Vec<PathBuf> = extra_root.map(Path::to_path_buf).into_iter().collect();
    roots.extend(steam_roots(home));
    let mut best: Option<(PathBuf, std::time::SystemTime)> = None;
    for root in roots {
        let Ok(users) = std::fs::read_dir(root.join("userdata")) else {
            continue;
        };
        let mut users: Vec<PathBuf> = users.flatten().map(|e| e.path()).collect();
        users.sort();
        for user in users {
            let f = user.join("config/localconfig.vdf");
            if !f.is_file() || vdf::get_file(&f, app_id) == LaunchOptions::NoApp {
                continue;
            }
            let t = std::fs::metadata(&f)
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            // Whole seconds, as stat -c %Y compares them.
            let secs = |t: std::time::SystemTime| {
                t.duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |d| d.as_secs())
            };
            if best.as_ref().is_none_or(|(_, b)| secs(t) > secs(*b)) {
                best = Some((f, t));
            }
        }
    }
    best.map(|(f, _)| f)
}

impl Target {
    /// A Steam game's target, when Steam has settings for it.
    pub fn steam(home: &Path, extra_root: Option<&Path>, app_id: &str) -> Option<Self> {
        Some(Target {
            launcher: Launcher::Steam,
            file: steam_localconfig_for_app(home, extra_root, app_id)?,
            id: app_id.to_string(),
        })
    }

    /// A Heroic game's target in the Heroic config folder `root`, when its
    /// GamesConfig file has settings for it.
    pub fn heroic(root: &Path, app_name: &str) -> Option<Self> {
        let t = Target {
            launcher: Launcher::Heroic,
            file: root.join("GamesConfig").join(format!("{app_name}.json")),
            id: app_name.to_string(),
        };
        (t.get() != Held::NoApp).then_some(t)
    }

    pub fn get(&self) -> Held {
        match self.launcher {
            Launcher::Steam => match vdf::get_file(&self.file, &self.id) {
                LaunchOptions::NoApp => Held::NoApp,
                LaunchOptions::Absent => Held::Absent,
                LaunchOptions::Set(s) => Held::Set(s),
            },
            Launcher::Heroic => self.env(super::OVERRIDE_VAR),
        }
    }

    /// `None` removes it.
    pub fn set(&self, value: Option<&str>) -> Result<()> {
        match self.launcher {
            Launcher::Steam => vdf::set_file(&self.file, &self.id, value),
            Launcher::Heroic => self.set_env(super::OVERRIDE_VAR, value),
        }
    }

    /// A Heroic environment variable.
    pub fn env(&self, var: &str) -> Held {
        match heroic::get_env(&self.file, &self.id, var) {
            EnvValue::NoApp => Held::NoApp,
            EnvValue::Absent => Held::Absent,
            EnvValue::Set(s) => Held::Set(s),
        }
    }

    pub fn set_env(&self, var: &str, value: Option<&str>) -> Result<()> {
        heroic::set_env_file(&self.file, &self.id, var, value)
    }

    /// Whether the file belongs to the Flatpak copy of the launcher: decided
    /// by the file, so a player with both copies only has the one that owns
    /// it closed.
    pub fn is_flatpak(&self, home: &Path) -> bool {
        self.file
            .starts_with(home.join(".var/app").join(self.launcher.flatpak_id()))
    }
}
