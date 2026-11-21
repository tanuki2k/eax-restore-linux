//! Everything detection finds about a game folder, in one place, and the
//! install [`Plan`] the script's defaults would make from it. A panel shows
//! the [`Facts`] and lets the player change the plan before installing.

use super::builds::Build;
use super::config::paths::game_install_root;
use super::detect::{self, Api, ApiEvidence, CompanionApp, HeroicGame};
use super::eax_unified;
use super::files;
use super::identify::{identify_game_dir, Identified, Store};
use super::install::{self, Engine, Override, Plan, Vcrun};
use super::launcher::target::Target;
use super::speakers::{Listening, Speakers};
use super::vcrun;
use super::wine::{self, Prefix, Runner};
use super::wine_launchers::{self, LauncherGame};
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
    /// The Lutris, Bottles or Faugus game, for one Heroic doesn't know.
    pub wine_launcher: Option<LauncherGame>,
    pub prefix: Option<PathBuf>,
    pub runner: Option<Runner>,
    /// A native Linux build, which this can't fix.
    pub linux_build: bool,
    /// The game's exe in `game_dir`, when there is one: the profile's, else
    /// the one that looks most like the game's.
    pub exe: Option<String>,
    /// The exe the game's profile names; empty without a profile.
    pub exe_hint: String,
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
    /// The profile flags the CPU thread limit, and this PC has more than 8.
    pub wants_cpu_limit: bool,
    /// Folders the install writes to that can't be written: the game's,
    /// its extra exe folders, the prefixes' system32.
    pub unwritable: Vec<PathBuf>,
    /// The drive the game folder is on.
    pub game_mount: Option<files::Mount>,
    /// The Steam beta branch the game is on; empty for the default build.
    pub beta_branch: String,
    /// The GOG build installed (`goggame-<id>.info`); empty when unknown.
    pub gog_build: String,
}

/// An install the script asks about before going ahead (y/N).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EaxCaution {
    /// EAX already works without the fix.
    BuiltIn,
    /// A patch took EAX out of the current build, and the fix is another
    /// build of the same install (a beta branch) the game isn't on.
    RemovedByPatch,
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
    for root in super::roots::heroic_dirs(home) {
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
        if let Some(w) = walk(&root.join("tools")) {
            return Some(w);
        }
    }
    None
}

/// Looks at the game folder (its exe folder) and everything around it.
/// `protontricks` is how to run it, for a Steam game's prefix.
/// This PC's logical CPUs, as `nproc` counts them.
pub fn cpu_threads() -> usize {
    std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get)
}

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
        wine_launcher: None,
        prefix: None,
        runner: None,
        linux_build: detect::install_is_linux_build(&install_root),
        exe: None,
        exe_hint: String::new(),
        exe_folders: Vec::new(),
        extra_dirs: Vec::new(),
        profile_api: None,
        files_api: None,
        arch: wine::detect_architecture(game_dir),
        companions: Vec::new(),
        launcher: None,
        vcrun_present: false,
        wants_eax_unified: false,
        wants_cpu_limit: false,
        unwritable: Vec::new(),
        game_mount: files::mount_of(game_dir),
        beta_branch: String::new(),
        gog_build: String::new(),
    };
    let exe = game.map_or("", |g| g.exe.as_str());
    let launcher_exe = wine_launchers::launcher_exe_for_root(home, &install_root);
    f.exe_folders = detect::exe_candidates_with(&install_root, exe, launcher_exe.as_deref());
    let (found_in, found) = detect::exe_folder_with(game_dir, exe, launcher_exe.as_deref());
    f.exe = found.filter(|_| found_in == game_dir);
    f.exe_hint = exe.to_string();

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
            f.prefix = wine::steam_prefix_for_appid(protontricks, &app_id, game_dir);
            // No protontricks installed: nothing can run in the prefix.
            f.runner = (!protontricks.is_empty()).then(|| Runner::Protontricks {
                cmd: protontricks.to_vec(),
                app_id: app_id.clone(),
            });
            let dir = game_dir.to_string_lossy();
            if let Some((library, _)) = dir.split_once("/steamapps/common/") {
                f.beta_branch = detect::steam_beta_branch(Path::new(&format!(
                    "{library}/steamapps/appmanifest_{app_id}.acf"
                )));
            }
            f.launcher = Target::steam(home, None, &app_id);
            if let Some(g) = game {
                f.companions = detect::companion_apps(g, &app_id, game_dir, protontricks);
            }
        }
    } else {
        f.heroic = detect::heroic_game(game_dir, home);
        // Not in Heroic's library: Lutris, Bottles or Faugus may run it, and
        // then its DLL override goes in the registry (no launcher target).
        if f.heroic.is_none() {
            f.wine_launcher = wine_launchers::for_dir(home, game_dir);
        }
        if let Some(w) = &f.wine_launcher {
            f.prefix = w.prefix.clone();
            let gog = identified
                .as_ref()
                .filter(|i| i.store == Store::Gog)
                .map(|i| i.id.clone())
                .or_else(|| {
                    game.and_then(|g| g.stores.gog.as_ref())
                        .map(|s| s.id.to_string())
                });
            if let Some(id) = gog {
                f.store = Some(Store::Gog);
                f.id = id;
            }
        }
        if let Some(h) = &f.heroic {
            f.prefix = h.prefix.clone();
            if !h.gog_app.is_empty() {
                f.store = Some(Store::Gog);
                f.id = h.gog_app.clone();
            }
            f.launcher = Target::heroic(&h.root, &h.id);
        }
        let prefix = f.prefix.clone().unwrap_or_default();
        let runner = if let Some(w) = &f.wine_launcher {
            w.wine.clone().map(|wine| {
                let server = wine.with_file_name("wineserver");
                wine::HeroicRunner {
                    wineserver: wine::is_executable(&server).then_some(server),
                    wine: Some(wine),
                    ..Default::default()
                }
            })
        } else {
            wine::heroic_runner_config(
                home,
                f.heroic.as_ref().map(|h| h.root.as_path()),
                f.heroic.as_ref().map(|h| h.id.as_str()),
                &prefix,
            )
            .as_deref()
            .and_then(wine::heroic_runner)
        };
        let wine_bin = runner
            .as_ref()
            .and_then(|r| r.wine.clone())
            .or_else(|| fallback_wine(home));
        f.runner = wine_bin.map(|w| Runner::Wine {
            wine: w,
            wineserver: runner.as_ref().and_then(|r| r.wineserver.clone()),
        });
    }
    if f.store == Some(Store::Gog) {
        f.gog_build = detect::gog_build_id(&install_root, &f.id);
    }
    // A launcher names the prefix before the game's first run makes it, so a
    // path without drive_c isn't a prefix yet (the script's own check).
    // After the runner lookup, which finds Heroic's settings by that path.
    f.prefix = f.prefix.take().filter(|p| p.join("drive_c").is_dir());

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
        f.wants_cpu_limit =
            g.install.tweaks.iter().any(|t| t == "limit_cpu_threads") && cpu_threads() > 8;
    }
    f.files_api = detect::detect_api(game_dir, exe);
    if let (Some(p), Some(arch)) = (&f.prefix, f.arch) {
        f.vcrun_present = vcrun::verify_files(p, arch).is_some_and(|(_, ok)| ok);
    }
    // check_target_writable's folders, checked before anything changes.
    let system32 = |p: &Path| p.join("drive_c/windows/system32");
    let mut dirs = vec![game_dir.to_path_buf()];
    dirs.extend(f.extra_dirs.iter().cloned());
    dirs.extend(f.prefix.as_deref().map(system32).filter(|d| d.is_dir()));
    dirs.extend(
        f.companions
            .iter()
            .filter_map(|c| c.prefix.as_deref())
            .map(system32),
    );
    f.unwritable = dirs.into_iter().filter(|d| !files::writable(d)).collect();
    f
}

impl Facts {
    /// What `confirm_continue_if_eax_impossible` asks about for this game.
    /// (`none_to_restore` games don't get this far.)
    pub fn eax_caution(&self, game: &Game) -> Option<EaxCaution> {
        match game.eax.status.as_str() {
            "built_in" => Some(EaxCaution::BuiltIn),
            "removed_by_patch" if game.eax.fix_in_place => {
                // Already rolled back: Steam's beta branch, or a GOG build
                // the database lists.
                let on_it = match self.store {
                    Some(Store::Steam) => game.stores.steam.as_ref().is_some_and(|s| {
                        !s.beta_branch.is_empty() && self.beta_branch == s.beta_branch
                    }),
                    Some(Store::Gog) => game.stores.gog.as_ref().is_some_and(|s| {
                        !self.gog_build.is_empty() && s.rollback_builds.contains(&self.gog_build)
                    }),
                    None => false,
                };
                (!on_it).then_some(EaxCaution::RemovedByPatch)
            }
            _ => None,
        }
    }

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
            dsoal_version: String::new(),
            openal_version: String::new(),
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
            cpu_limit: self.wants_cpu_limit,
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
    /// What was found around the game, one line each, for the page's Status
    /// box and `eax-restore status`: (fine, label, value). A line that isn't
    /// fine is a problem: no prefix yet, a Linux build, no store.
    pub fn summary(&self, home: &Path) -> Vec<(bool, &'static str, String)> {
        let tilde = |p: &Path| crate::library::tilde(p, home);
        let mut out = Vec::new();
        out.push(match (self.store, &self.heroic) {
            (Some(Store::Steam), _) => (true, "Store", format!("Steam (AppID {})", self.id)),
            (_, Some(_)) => (true, "Store", "GOG, through Heroic".to_string()),
            _ => (false, "Store", "not found in Steam or Heroic".to_string()),
        });
        out.push(match &self.prefix {
            Some(p) => (true, "Prefix", tilde(p)),
            None => (false, "Prefix", "not found yet".to_string()),
        });
        if self.prefix.is_some() {
            out.push(match &self.runner {
                Some(Runner::Protontricks { .. }) => (
                    true,
                    "Runs with",
                    "Proton, through protontricks".to_string(),
                ),
                Some(Runner::Wine { wine, .. }) => {
                    (true, "Runs with", format!("Wine, {}", tilde(wine)))
                }
                None => (
                    false,
                    "Runs with",
                    "no Wine found to run it with".to_string(),
                ),
            });
        }
        let files = if self.linux_build {
            (
                false,
                "the Linux version, which the EAX fix can't work with".to_string(),
            )
        } else {
            let arch = self
                .arch
                .map_or("couldn't tell if 32 or 64-bit".to_string(), |a| {
                    format!("{a}-bit")
                });
            let api = match self.engine() {
                Engine::Dsoal => "DirectSound3D",
                Engine::OpenAlSoft => "OpenAL",
            };
            if let (true, Some(e)) = (self.api_disagrees(), &self.files_api) {
                // As the script says it: what the files point to, and that
                // the profile's answer is the one used.
                let (other, file) = match e.api {
                    Api::OpenAl => ("OpenAL", &e.openal_file),
                    _ => ("DirectSound3D", &e.ds_file),
                };
                (
                    false,
                    format!("{arch}, {api}, as its profile says, but {file} points to {other}."),
                )
            } else {
                // As the script's "Can't tell from the files": not a
                // problem, but the answer rests on the profile alone.
                // With no profile either, it's a guess, as the script's own
                // "almost every classic EAX title uses DirectSound3D".
                match (&self.files_api, &self.profile_api) {
                    (None, Some(_)) => (true, format!("{arch}, {api} (per its profile)")),
                    (None, None) => (
                        false,
                        format!("{arch}, {api} (a guess). Its files don't mention OpenAL or DirectSound3D."),
                    ),
                    _ => (true, format!("{arch}, {api}")),
                }
            }
        };
        out.push((files.0, "Game files", files.1));
        out
    }

    pub fn api_disagrees(&self) -> bool {
        match (&self.profile_api, &self.files_api) {
            (Some(p), Some(e)) => e.api != Api::Both && e.api.name() != p,
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    /// KOTOR II on GOG: rolling back to a build the database lists means
    /// the update's no-EAX warning no longer applies; any other build, or
    /// one GOG didn't record, keeps it.
    #[test]
    fn a_gog_install_already_rolled_back_gets_no_eax_warning() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let game = home.join("Games/Heroic/Test Game");
        put(&game.join("game.exe"), "MZ");
        put(
            &home.join(".config/heroic/gog_store/installed.json"),
            &serde_json::json!({"installed": [
                {"appName": "100", "install_path": game, "platform": "windows"}
            ]})
            .to_string(),
        );
        let g = crate::db::Database::parse(
            r#"{"games":[{"id":"t","name":"Test Game",
                "stores":{"gog":{"id":100,"rollback_builds":["111","222"]}},
                "eax":{"status":"removed_by_patch","fix_in_place":true}}]}"#,
        )
        .unwrap()
        .games
        .remove(0);
        let info = game.join("goggame-100.info");
        let caution = |build: Option<&str>| {
            match build {
                Some(b) => put(
                    &info,
                    &format!("{{\n  \"buildId\": \"{b}\",\n  \"gameId\": \"100\"\n}}"),
                ),
                None => put(&info, r#"{"gameId": "100"}"#),
            }
            let f = gather(&game, Some(&g), home, &[]);
            assert_eq!(f.store, Some(Store::Gog));
            (f.gog_build.clone(), f.eax_caution(&g))
        };
        assert_eq!(caution(Some("222")), ("222".into(), None));
        assert_eq!(
            caution(Some("999")),
            ("999".into(), Some(EaxCaution::RemovedByPatch))
        );
        assert_eq!(
            caution(None),
            (String::new(), Some(EaxCaution::RemovedByPatch))
        );
        std::fs::remove_file(&info).unwrap();
        assert_eq!(
            detect::gog_build_id(&game, "100"),
            "",
            "no file means unknown"
        );
    }

    #[test]
    fn a_launcher_prefix_counts_once_the_game_has_made_it() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let game = home.join("Games/Heroic/Test Game");
        put(&game.join("game.exe"), "MZ");
        let heroic = home.join(".config/heroic");
        put(
            &heroic.join("gog_store/installed.json"),
            &serde_json::json!({"installed": [
                {"appName": "100", "install_path": game, "platform": "windows"}
            ]})
            .to_string(),
        );
        // Heroic writes the prefix's path when it installs the game.
        let pfx = home.join("Games/Heroic/Prefixes/Test Game");
        put(
            &heroic.join("GamesConfig/100.json"),
            &format!(
                "{{\n  \"100\": {{\n    \"winePrefix\": \"{}\",\n    \"wineVersion\": {{}}\n  }}\n}}",
                pfx.display()
            ),
        );
        let f = gather(&game, None, home, &[]);
        assert!(f.heroic.is_some(), "Heroic should know the game");
        assert_eq!(f.prefix, None);

        // The game's first run makes it.
        std::fs::create_dir_all(pfx.join("drive_c")).unwrap();
        let f = gather(&game, None, home, &[]);
        assert_eq!(f.prefix.as_deref(), Some(pfx.as_path()));
    }
}
