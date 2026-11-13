//! Everything detection finds about a game folder, in one place, and the
//! install [`Plan`] the script's defaults would make from it. A panel shows
//! the [`Facts`] and lets the player change the plan before installing.

use super::builds::Build;
use super::config::paths::game_install_root;
use super::detect::{self, Api, ApiEvidence, CompanionApp, HeroicGame};
use super::eax_unified;
use super::identify::{identify_game_dir, Identified, Store};
use super::install::{self, Engine, Override, Plan, Vcrun};
use super::launcher::target::Target;
use super::speakers::{Listening, Speakers};
use super::vcrun;
use super::wine::{self, Prefix, Runner};
use crate::db::Game;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// What's known about the game before anything is installed.
#[derive(Debug, Clone)]
pub struct Facts {
    /// The exe folder.
    pub game_dir: PathBuf,
    pub install_root: PathBuf,
    pub identified: Option<Identified>,
    /// The Steam AppID or GOG ID the database knows the game by.
    pub store: Option<Store>,
    pub id: String,
    pub heroic: Option<HeroicGame>,
    pub prefix: Option<PathBuf>,
    pub runner: Option<Runner>,
    /// A native Linux build, which this can't fix.
    pub linux_build: bool,
    /// Other folders the game's exe might be in, best first.
    pub exe_folders: Vec<(PathBuf, String)>,
    pub extra_dirs: Vec<PathBuf>,
    /// The audio API the profile names (the store's own, else the game's).
    pub profile_api: Option<String>,
    /// What the game's files say.
    pub files_api: Option<ApiEvidence>,
    pub arch: Option<u8>,
    pub companions: Vec<CompanionApp>,
    /// Where a launcher keeps the game's launch options or variables.
    pub launcher: Option<Target>,
    /// The VC++ runtime is already genuine in the prefix.
    pub vcrun_present: bool,
    /// The profile asks for EAX Unified, and the game doesn't ship its own.
    pub wants_eax_unified: bool,
}

/// The Wine to use for a game Heroic doesn't name one for: `wine` on PATH,
/// else the first in Heroic's own tools folder.
pub fn fallback_wine(home: &Path) -> Option<PathBuf> {
    if let Some(paths) = std::env::var_os("PATH") {
        if let Some(w) = std::env::split_paths(&paths)
            .map(|d| d.join("wine"))
            .find(|p| wine::is_executable(p))
        {
            return Some(w);
        }
    }
    for root in [
        ".config/heroic",
        ".var/app/com.heroicgameslauncher.hgl/config/heroic",
    ] {
        fn walk(dir: &Path) -> Option<PathBuf> {
            for e in std::fs::read_dir(dir).ok()?.flatten() {
                let p = e.path();
                let t = e.file_type().ok()?;
                if t.is_dir() {
                    if let Some(f) = walk(&p) {
                        return Some(f);
                    }
                } else if t.is_file() && p.ends_with("bin/wine") && wine::is_executable(&p) {
                    return Some(p);
                }
            }
            None
        }
        if let Some(w) = walk(&home.join(root).join("tools")) {
            return Some(w);
        }
    }
    None
}

/// Looks at the game folder (its exe folder) and everything around it.
/// `protontricks` is how to run it, for a Steam game's prefix.
pub fn gather(game_dir: &Path, game: Option<&Game>, home: &Path, protontricks: &[String]) -> Facts {
    let identified = identify_game_dir(game_dir, home);
    let install_root = game_install_root(
        game_dir,
        identified.as_ref().map(|i| i.root.as_path()),
        &detect::heroic_install_paths(home),
    );
    let steam = identified.as_ref().is_some_and(|i| i.store == Store::Steam)
        || game_dir.to_string_lossy().contains("/steamapps/common/");
    let mut f = Facts {
        game_dir: game_dir.to_path_buf(),
        install_root: install_root.clone(),
        identified: identified.clone(),
        store: None,
        id: String::new(),
        heroic: None,
        prefix: None,
        runner: None,
        linux_build: detect::install_is_linux_build(&install_root),
        exe_folders: Vec::new(),
        extra_dirs: Vec::new(),
        profile_api: None,
        files_api: None,
        arch: wine::detect_architecture(game_dir),
        companions: Vec::new(),
        launcher: None,
        vcrun_present: false,
        wants_eax_unified: false,
    };
    let exe = game.map_or("", |g| g.exe.as_str());
    f.exe_folders = detect::exe_candidates(&install_root, exe);

    if steam {
        let app_id = identified
            .as_ref()
            .filter(|i| i.store == Store::Steam)
            .map(|i| i.id.clone())
            .or_else(|| detect::steam_appid_for_dir(game_dir))
            .unwrap_or_default();
        if !app_id.is_empty() {
            f.store = Some(Store::Steam);
            f.id = app_id.clone();
            f.prefix = wine::steam_prefix_for_appid(protontricks, &app_id);
            f.runner = Some(Runner::Protontricks {
                cmd: protontricks.to_vec(),
                app_id: app_id.clone(),
            });
            f.launcher = Target::steam(home, None, &app_id);
            if let Some(g) = game {
                f.companions = detect::companion_apps(g, &app_id, game_dir, protontricks);
            }
        }
    } else {
        f.heroic = detect::heroic_game(game_dir, home);
        if let Some(h) = &f.heroic {
            f.prefix = h.prefix.clone();
            if !h.gog_app.is_empty() {
                f.store = Some(Store::Gog);
                f.id = h.gog_app.clone();
            }
            f.launcher = Target::heroic(&h.root, &h.id);
        }
        let prefix = f.prefix.clone().unwrap_or_default();
        let runner = wine::heroic_runner_config(
            home,
            f.heroic.as_ref().map(|h| h.root.as_path()),
            f.heroic.as_ref().map(|h| h.id.as_str()),
            &prefix,
        )
        .as_deref()
        .and_then(wine::heroic_runner);
        let wine_bin = runner
            .as_ref()
            .and_then(|r| r.wine.clone())
            .or_else(|| fallback_wine(home));
        f.runner = wine_bin.map(|w| Runner::Wine {
            wine: w,
            wineserver: runner.as_ref().and_then(|r| r.wineserver.clone()),
        });
    }

    if let Some(g) = game {
        let store = match f.store {
            Some(Store::Steam) => g.stores.steam.as_ref(),
            Some(Store::Gog) => g.stores.gog.as_ref(),
            None => None,
        };
        f.profile_api = store
            .and_then(|s| s.api.clone())
            .or_else(|| (!g.eax.api.is_empty()).then(|| g.eax.api.clone()));
        if let Some(s) = store {
            f.extra_dirs = detect::extra_exe_folders(game_dir, &install_root, &s.extra_exe_folders);
        }
        f.wants_eax_unified = g.install.tweaks.iter().any(|t| t == "eax_unified")
            && !eax_unified::game_ships_eax_dll(game_dir);
    }
    f.files_api = detect::detect_api(game_dir, exe);
    if let (Some(p), Some(arch)) = (&f.prefix, f.arch) {
        f.vcrun_present = vcrun::verify_files(p, arch).is_some_and(|(_, ok)| ok);
    }
    f
}

impl Facts {
    /// The engine the audio API calls for: OpenAL Soft alone for an OpenAL
    /// game, DSOAL otherwise (the profile's word first, then the files').
    pub fn engine(&self) -> Engine {
        let api = self
            .profile_api
            .clone()
            .or_else(|| self.files_api.as_ref().map(|e| e.api.name().to_string()));
        match api.as_deref() {
            Some("openal") => Engine::OpenAlSoft,
            _ => Engine::Dsoal,
        }
    }

    /// The plan the script's defaults make: the files' architecture (32-bit
    /// when they can't tell), stable builds, stereo with HRTF left to OpenAL
    /// Soft, the override in the launcher when it has settings for the game
    /// (else the registry), no VC++ unless it's already there, EAX Unified
    /// when the profile asks for it, and no game settings (the panel adds
    /// the ones the player picks).
    pub fn default_plan(&self) -> Plan {
        let prefix = self.prefix.as_ref().map(|p| Prefix {
            path: p.clone(),
            runner: self.runner.clone(),
            log: None,
        });
        let over = match &self.launcher {
            Some(t) => Override::Launcher(t.clone()),
            None => Override::Registry,
        };
        Plan {
            game_dir: self.game_dir.clone(),
            extra_dirs: self.extra_dirs.clone(),
            prefix,
            arch: self.arch.unwrap_or(32),
            engine: self.engine(),
            dsoal_build: Build::Stable,
            openal_build: Build::Stable,
            speakers: Speakers::stereo(Listening::Auto, true),
            alsoft_overrides: Vec::new(),
            advanced_limits: false,
            com_routing: false,
            over,
            vcrun: if self.vcrun_present {
                Vcrun::OverridesOnly
            } else {
                Vcrun::Skip
            },
            eax_unified: self.wants_eax_unified,
            game_settings: Vec::new(),
            crash_markers: HashMap::new(),
            companions: self
                .companions
                .iter()
                .filter_map(|c| {
                    let path = c.prefix.clone()?;
                    let Some(Runner::Protontricks { cmd, .. }) = &self.runner else {
                        return None;
                    };
                    Some(install::Companion {
                        app_id: c.app_id.clone(),
                        name: c.name.clone(),
                        prefix: Prefix {
                            path,
                            runner: Some(Runner::Protontricks {
                                cmd: cmd.clone(),
                                app_id: c.app_id.clone(),
                            }),
                            log: None,
                        },
                        vcrun: Vcrun::Skip,
                        over: Override::Registry,
                    })
                })
                .collect(),
            sound_log: false,
        }
    }

    /// The files point to a different API than the profile names, which the
    /// player should be told about.
    pub fn api_disagrees(&self) -> bool {
        match (&self.profile_api, &self.files_api) {
            (Some(p), Some(e)) => e.api != Api::Both && e.api.name() != p,
            _ => false,
        }
    }
}
