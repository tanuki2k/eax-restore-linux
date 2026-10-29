//! Finds what is on this machine: Steam and Heroic game folders, and the folders
//! holding a live install (`.eax-restore-manifest.txt`). A port of the Bash
//! `steam_library_dirs`, `scan_game_libraries` and `find_installed_game_dirs`;
//! every function takes `home` so tests can use a fake one.

use serde_json::Value;
use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub const MANIFEST_NAME: &str = ".eax-restore-manifest.txt";
const UNINSTALLED_MARKER: &str = "# EAX Restore: uninstalled";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreKind {
    Steam,
    Gog,
}

/// A database game found installed by its store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Found {
    pub store: StoreKind,
    pub id: String,
    /// The store's install folder (the manifest may sit in a subfolder).
    pub path: PathBuf,
}

fn canon(p: &Path) -> PathBuf {
    fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// `"key"   "value"` as Steam's VDF/ACF files write it. The value runs to the
/// line's last quote, like the Bash sed.
fn quoted_pair(line: &str) -> Option<(&str, &str)> {
    let rest = line.trim_start().strip_prefix('"')?;
    let (key, rest) = rest.split_once('"')?;
    let rest = rest.trim_start().strip_prefix('"')?;
    Some((key, rest.trim_end().strip_suffix('"')?))
}

/// Every value of `key`, in file order.
fn vdf_values(text: &str, key: &str) -> Vec<String> {
    text.lines()
        .filter_map(quoted_pair)
        .filter(|(k, _)| *k == key)
        .map(|(_, v)| v.to_string())
        .collect()
}

/// Steam installs present: the native one, then Flatpak's (each with two
/// layouts, first that exists wins).
fn steam_roots(home: &Path) -> Vec<PathBuf> {
    let sets: [&[&str]; 2] = [
        &[".local/share/Steam", ".steam/steam"],
        &[
            ".var/app/com.valvesoftware.Steam/.local/share/Steam",
            ".var/app/com.valvesoftware.Steam/data/Steam",
        ],
    ];
    sets.iter()
        .filter_map(|set| {
            set.iter()
                .map(|p| home.join(p))
                .find(|d| d.join("steamapps").is_dir())
        })
        .map(|d| canon(&d))
        .collect()
}

/// Every Steam library's `steamapps` folder, once each: the roots' own plus the
/// `"path"` entries of their `libraryfolders.vdf`.
pub fn steam_library_dirs(home: &Path) -> Vec<PathBuf> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    let mut add = |root: &Path| {
        let steamapps = root.join("steamapps");
        // Keyed by the real folder: a symlinked root would list its own
        // library a second time through libraryfolders.vdf.
        if steamapps.is_dir() && seen.insert(canon(&steamapps)) {
            out.push(steamapps);
        }
    };
    for root in steam_roots(home) {
        add(&root);
        if let Ok(text) = fs::read_to_string(root.join("steamapps/libraryfolders.vdf")) {
            for p in vdf_values(&text, "path") {
                add(Path::new(&p.replace("\\\\", "\\")));
            }
        }
    }
    out
}

/// Database games installed through Steam, by matching `appmanifest_<id>.acf`.
pub fn scan_steam(home: &Path, ids: &HashSet<u64>) -> Vec<Found> {
    let mut out = Vec::new();
    for lib in steam_library_dirs(home) {
        let Ok(dir) = fs::read_dir(&lib) else { continue };
        for entry in dir.flatten() {
            let file = entry.file_name().to_string_lossy().into_owned();
            let Some(id) = file
                .strip_prefix("appmanifest_")
                .and_then(|r| r.strip_suffix(".acf"))
                .and_then(|r| r.parse::<u64>().ok())
            else {
                continue;
            };
            if !ids.contains(&id) {
                continue;
            }
            let Ok(text) = fs::read_to_string(entry.path()) else { continue };
            let Some(installdir) = vdf_values(&text, "installdir").into_iter().next() else {
                continue;
            };
            let path = lib.join("common").join(installdir);
            if path.is_dir() {
                out.push(Found { store: StoreKind::Steam, id: id.to_string(), path });
            }
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out
}

fn heroic_roots(home: &Path) -> Vec<PathBuf> {
    [
        ".config/heroic",
        ".var/app/com.heroicgameslauncher.hgl/config/heroic",
    ]
    .iter()
    .map(|p| home.join(p))
    .filter(|d| d.is_dir())
    .collect()
}

/// Files called `name` below `root`, at most `max_depth` levels down (the root's
/// own files are depth 1). Symlinks are not followed, like `find`.
fn find_files(root: &Path, name: &str, max_depth: usize) -> Vec<PathBuf> {
    fn walk(dir: &Path, name: &str, depth: usize, max: usize, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let Ok(t) = e.file_type() else { continue };
            if t.is_file() && e.file_name() == name {
                out.push(e.path());
            } else if t.is_dir() && depth < max {
                walk(&e.path(), name, depth + 1, max, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, name, 1, max_depth, &mut out);
    out
}

fn read_json(p: &Path) -> Option<Value> {
    serde_json::from_str(&fs::read_to_string(p).ok()?).ok()
}

/// Every object with an `install_path`/`installPath`, however deep: GOG's, Epic's
/// and older Heroic files nest and spell the keys differently.
fn install_records(v: &Value, out: &mut Vec<(PathBuf, String)>) {
    match v {
        Value::Object(m) => {
            let get = |a: &str, b: &str| m.get(a).or_else(|| m.get(b)).and_then(Value::as_str);
            if let Some(path) = get("install_path", "installPath") {
                let app = get("app_name", "appName").unwrap_or("");
                out.push((PathBuf::from(path), app.to_string()));
            }
            m.values().for_each(|c| install_records(c, out));
        }
        Value::Array(a) => a.iter().for_each(|c| install_records(c, out)),
        _ => {}
    }
}

/// Database games installed through Heroic (GOG ids), from every `installed.json`.
pub fn scan_heroic(home: &Path, gog_ids: &HashSet<String>) -> Vec<Found> {
    let mut out = Vec::new();
    for root in heroic_roots(home) {
        for json in find_files(&root, "installed.json", 8) {
            let Some(v) = read_json(&json) else { continue };
            let mut records = Vec::new();
            install_records(&v, &mut records);
            for (path, app) in records {
                if gog_ids.contains(&app) && path.is_dir() {
                    out.push(Found { store: StoreKind::Gog, id: app, path });
                }
            }
        }
    }
    out.sort_by(|a, b| a.id.cmp(&b.id).then(a.path.cmp(&b.path)));
    out.dedup();
    out
}

/// Where Heroic keeps games: its default install folder plus the GOG, Epic and
/// sideloaded installs it records.
fn heroic_game_folders(home: &Path) -> BTreeSet<PathBuf> {
    let mut out = BTreeSet::new();
    let strings = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).map(PathBuf::from);
    for root in heroic_roots(home) {
        if let Some(v) = read_json(&root.join("config.json")) {
            if let Some(p) = v.pointer("/defaultSettings/defaultInstallPath").and_then(Value::as_str) {
                out.insert(PathBuf::from(p));
            }
        }
        if let Some(v) = read_json(&root.join("gog_store/installed.json")) {
            for g in v.get("installed").and_then(Value::as_array).into_iter().flatten() {
                out.extend(strings(g, "install_path"));
            }
        }
        if let Some(v) = read_json(&root.join("legendaryConfig/legendary/installed.json")) {
            let games: Vec<&Value> = match &v {
                Value::Object(m) => m.values().collect(),
                Value::Array(a) => a.iter().collect(),
                _ => Vec::new(),
            };
            out.extend(games.into_iter().filter_map(|g| strings(g, "install_path")));
        }
        if let Some(v) = read_json(&root.join("sideload_apps/library.json")) {
            for g in v.get("games").and_then(Value::as_array).into_iter().flatten() {
                out.extend(strings(g, "folder_name"));
            }
        }
    }
    out
}

/// True when the folder holds this tool's install: a non-empty manifest that
/// isn't the "uninstalled" marker an uninstall leaves behind.
pub fn manifest_is_live(dir: &Path) -> bool {
    match fs::read_to_string(dir.join(MANIFEST_NAME)) {
        Ok(text) => !text.is_empty() && !text.starts_with(UNINSTALLED_MARKER),
        Err(_) => false,
    }
}

/// Every folder holding a live install, found on disk under the Steam libraries
/// and Heroic's game folders.
pub fn live_manifest_dirs(home: &Path) -> BTreeSet<PathBuf> {
    let mut manifests = Vec::new();
    for lib in steam_library_dirs(home) {
        let common = lib.join("common");
        // Not directly in `common`: that is a game folder's parent.
        manifests.extend(
            find_files(&common, MANIFEST_NAME, 5)
                .into_iter()
                .filter(|m| m.parent() != Some(common.as_path())),
        );
    }
    for folder in heroic_game_folders(home) {
        if folder.is_dir() {
            manifests.extend(find_files(&folder, MANIFEST_NAME, 5));
        }
    }
    manifests
        .into_iter()
        .filter_map(|m| m.parent().map(Path::to_path_buf))
        .filter(|d| manifest_is_live(d))
        .collect()
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A fake home: Steam with a second library, one Heroic GOG game.
    pub struct World {
        pub home: tempfile::TempDir,
    }

    impl World {
        pub fn new() -> Self {
            let home = tempfile::tempdir().unwrap();
            let w = World { home };
            w.write(".local/share/Steam/steamapps/libraryfolders.vdf", &format!(
                "\"libraryfolders\"\n{{\n\t\"0\"\n\t{{\n\t\t\"path\"\t\t\"{}\"\n\t}}\n}}\n",
                w.p("games2").display()
            ));
            w
        }

        pub fn p(&self, rel: &str) -> PathBuf {
            self.home.path().join(rel)
        }

        pub fn write(&self, rel: &str, text: &str) {
            let p = self.p(rel);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, text).unwrap();
        }

        pub fn steam_game(&self, lib: &str, id: u64, dir: &str) {
            self.write(
                &format!("{lib}/steamapps/appmanifest_{id}.acf"),
                &format!("\"AppState\"\n{{\n\t\"appid\"\t\t\"{id}\"\n\t\"installdir\"\t\t\"{dir}\"\n}}\n"),
            );
            fs::create_dir_all(self.p(&format!("{lib}/steamapps/common/{dir}"))).unwrap();
        }
    }

    #[test]
    fn finds_both_steam_libraries_once() {
        let w = World::new();
        fs::create_dir_all(w.p("games2/steamapps")).unwrap();
        let libs = steam_library_dirs(w.home.path());
        assert_eq!(libs.len(), 2);
        assert!(libs[0].ends_with("Steam/steamapps"));
        assert!(libs[1].ends_with("games2/steamapps"));
    }

    #[test]
    fn scans_steam_games_from_the_database_only() {
        let w = World::new();
        fs::create_dir_all(w.p("games2/steamapps")).unwrap();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.steam_game("games2", 20, "Beta");
        w.steam_game("games2", 99, "NotInDatabase");
        let ids: HashSet<u64> = [10, 20].into();
        let found = scan_steam(w.home.path(), &ids);
        assert_eq!(found.iter().map(|f| f.id.as_str()).collect::<Vec<_>>(), ["10", "20"]);
        assert!(found[1].path.ends_with("games2/steamapps/common/Beta"));
    }

    #[test]
    fn an_appmanifest_without_its_folder_is_not_installed() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        fs::remove_dir_all(w.p(".local/share/Steam/steamapps/common/Alpha")).unwrap();
        assert!(scan_steam(w.home.path(), &[10].into()).is_empty());
    }

    #[test]
    fn scans_heroic_gog_installs_at_any_depth_and_spelling() {
        let w = World::new();
        let game = w.p("Games/Heroic/Gamma");
        fs::create_dir_all(&game).unwrap();
        w.write(
            ".config/heroic/gog_store/installed.json",
            &format!(r#"{{"installed":[{{"appName":"555","installPath":"{}"}}]}}"#, game.display()),
        );
        let found = scan_heroic(w.home.path(), &["555".to_string()].into());
        assert_eq!(found, [Found { store: StoreKind::Gog, id: "555".into(), path: game }]);
        assert!(scan_heroic(w.home.path(), &["556".to_string()].into()).is_empty());
    }

    #[test]
    fn live_manifests_skip_the_uninstalled_marker() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.steam_game(".local/share/Steam", 11, "Beta");
        w.write(
            ".local/share/Steam/steamapps/common/Alpha/bin/.eax-restore-manifest.txt",
            "# EAX Restore manifest, format 2\n/x/dsound.dll\n",
        );
        w.write(
            ".local/share/Steam/steamapps/common/Beta/.eax-restore-manifest.txt",
            "# EAX Restore: uninstalled 2026-01-01\n",
        );
        let live = live_manifest_dirs(w.home.path());
        assert_eq!(live.len(), 1);
        assert!(live.iter().next().unwrap().ends_with("common/Alpha/bin"));
    }

    #[test]
    fn live_manifests_are_found_in_heroic_folders() {
        let w = World::new();
        let game = w.p("Games/Heroic/Gamma");
        w.write("Games/Heroic/Gamma/.eax-restore-manifest.txt", "/x/dsound.dll\n");
        w.write(
            ".config/heroic/config.json",
            &format!(r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#, w.p("Games/Heroic").display()),
        );
        assert_eq!(live_manifest_dirs(w.home.path()), BTreeSet::from([game]));
    }

    #[test]
    fn no_launchers_means_nothing_found() {
        let home = tempfile::tempdir().unwrap();
        assert!(steam_library_dirs(home.path()).is_empty());
        assert!(live_manifest_dirs(home.path()).is_empty());
    }
}
