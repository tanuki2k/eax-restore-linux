//! The home list: database games and manual installs, each with a status for
//! this machine.

use crate::db::{Database, Game};
use crate::library::{self, Found, StoreKind};
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// The fix is installed (a live manifest in the game's folder).
    Installed,
    /// In a Steam or Heroic library here, without the fix.
    OnThisPc,
    /// In the database, not found here.
    NotOnThisPc,
    /// A live install of a game the database doesn't list.
    Manual,
}

impl Status {
    pub fn label(self) -> &'static str {
        match self {
            Status::Installed => "Installed",
            Status::OnThisPc => "On this PC, not installed",
            Status::NotOnThisPc => "Not on this PC",
            Status::Manual => "Installed manually (not in the game database)",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Entry {
    pub name: String,
    pub status: Status,
    /// None for a manual game the database doesn't list.
    pub game: Option<Game>,
    pub store: Option<StoreKind>,
    /// The game's folder: the install's folder when installed, else the store's.
    pub path: Option<PathBuf>,
}

impl Entry {
    pub fn database_only(game: Game) -> Self {
        Entry {
            name: game.name.clone(),
            status: Status::NotOnThisPc,
            game: Some(game),
            store: None,
            path: None,
        }
    }
}

fn is_match(g: &Game, f: &Found) -> bool {
    match f.store {
        StoreKind::Steam => g
            .stores
            .steam
            .as_ref()
            .is_some_and(|s| s.id.to_string() == f.id),
        StoreKind::Gog => g
            .stores
            .gog
            .as_ref()
            .is_some_and(|s| s.id.to_string() == f.id),
    }
}

fn dir_has_file(dir: &Path, name: &str) -> bool {
    !name.is_empty()
        && std::fs::read_dir(dir)
            .into_iter()
            .flatten()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().eq_ignore_ascii_case(name))
}

/// Folders a game's exe usually sits in, not its name.
const EXE_FOLDERS: [&str; 8] = [
    "bin", "system", "binaries", "win32", "win64", "x64", "x86", "release",
];

/// A name for a game the database doesn't know: the Steam folder it sits in, or
/// else its own folder's name (its parent's when that is only the exe folder).
fn folder_name(dir: &Path) -> String {
    let parts: Vec<_> = dir
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect();
    for w in parts.windows(3) {
        if w[0] == "steamapps" && w[1] == "common" {
            return w[2].to_string();
        }
    }
    let own = |d: &Path| d.file_name().map(|n| n.to_string_lossy().into_owned());
    match own(dir) {
        Some(n) if EXE_FOLDERS.iter().any(|f| n.eq_ignore_ascii_case(f)) => {
            dir.parent().and_then(own).unwrap_or(n)
        }
        Some(n) => n,
        None => dir.display().to_string(),
    }
}

/// The store a copy found by its exe came from, as far as its folder says:
/// inside a Steam library's `steamapps/common` it is Steam's, inside one of
/// Heroic's game folders it is GOG's. Only a store the database lists for the
/// game counts, and a copy anywhere else stays unknown.
fn store_of_copy(g: &Game, dir: &Path, heroic: &BTreeSet<PathBuf>) -> Option<StoreKind> {
    let parts: Vec<_> = dir.components().map(|c| c.as_os_str()).collect();
    let in_steam = parts
        .windows(2)
        .any(|w| w[0] == "steamapps" && w[1] == "common");
    if in_steam && g.stores.steam.is_some() {
        Some(StoreKind::Steam)
    } else if heroic.iter().any(|h| dir.starts_with(h)) && g.stores.gog.is_some() {
        Some(StoreKind::Gog)
    } else {
        None
    }
}

pub fn build(db: &Database, home: &Path, state_file: &Path) -> Vec<Entry> {
    let steam_ids: HashSet<u64> = db
        .games
        .iter()
        .filter_map(|g| g.stores.steam.as_ref().map(|s| s.id))
        .collect();
    let gog_ids: HashSet<String> = db
        .games
        .iter()
        .filter_map(|g| g.stores.gog.as_ref().map(|s| s.id.to_string()))
        .collect();
    // Steam's copies first, so they are listed before a GOG copy of the same game.
    let mut found = library::scan_steam(home, &steam_ids);
    found.extend(library::scan_heroic(home, &gog_ids));
    let live = library::live_manifest_dirs(home, state_file);
    let heroic = library::heroic_game_folders(home);

    let mut claimed: HashSet<&PathBuf> = HashSet::new();
    let mut entries: Vec<Entry> = Vec::new();
    // Where each database game's first entry is; a game has more than one when
    // it is found in more than one store.
    let mut first_entry: Vec<usize> = Vec::with_capacity(db.games.len());
    for g in &db.games {
        first_entry.push(entries.len());
        let copies: Vec<&Found> = found.iter().filter(|f| is_match(g, f)).collect();
        if copies.is_empty() {
            entries.push(Entry::database_only(g.clone()));
            continue;
        }
        // One row per copy, each with its own store and folder: a game installed
        // from both Steam and GOG is two installs, and each may have the fix.
        for f in copies {
            let mut e = Entry::database_only(g.clone());
            e.store = Some(f.store);
            e.path = Some(f.path.clone());
            e.status = Status::OnThisPc;
            for d in live.iter().filter(|d| d.starts_with(&f.path)) {
                if e.status != Status::Installed {
                    e.status = Status::Installed;
                    e.path = Some(d.clone());
                }
                claimed.insert(d);
            }
            entries.push(e);
        }
    }

    for dir in live.iter().filter(|d| !claimed.contains(d)) {
        // A game installed by hand outside any library: recognise it by its exe,
        // but only when exactly one database game owns that file name.
        let owners: Vec<usize> = db
            .games
            .iter()
            .enumerate()
            .filter(|(_, g)| dir_has_file(dir, &g.exe))
            .map(|(i, _)| i)
            .collect();
        // A game with no copy found has one entry, a database-only one.
        let found_before = |i: usize| entries[first_entry[i]].status == Status::NotOnThisPc;
        match owners[..] {
            [i] if found_before(i) => {
                let entry = &mut entries[first_entry[i]];
                entry.status = Status::Installed;
                entry.path = Some(dir.clone());
                entry.store = store_of_copy(&db.games[i], dir, &heroic);
            }
            // Another install of a game already listed: its own row.
            [i] => {
                let mut e = Entry::database_only(db.games[i].clone());
                e.status = Status::Installed;
                e.path = Some(dir.clone());
                e.store = store_of_copy(&db.games[i], dir, &heroic);
                entries.push(e);
            }
            _ => entries.push(Entry {
                name: folder_name(dir),
                status: Status::Manual,
                game: None,
                store: None,
                path: Some(dir.clone()),
            }),
        }
    }
    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::library::tests::World;
    use std::fs;

    const DB: &str = r#"{"games":[
        {"id":"alpha","name":"Alpha","exe":"alpha.exe","stores":{"steam":{"id":10}}},
        {"id":"beta","name":"Beta","exe":"beta.exe","stores":{"steam":{"id":20}}},
        {"id":"gamma","name":"Gamma","exe":"gamma.exe","stores":{"gog":{"id":555}}},
        {"id":"delta","name":"Delta","exe":"delta.exe"}]}"#;

    fn by_name<'a>(entries: &'a [Entry], name: &str) -> &'a Entry {
        entries.iter().find(|e| e.name == name).unwrap()
    }

    #[test]
    fn marks_each_game_installed_on_this_pc_or_neither() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.steam_game(".local/share/Steam", 20, "Beta");
        w.write(
            ".local/share/Steam/steamapps/common/Alpha/bin/.eax-restore-manifest.txt",
            "/x/dsound.dll\n",
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        let alpha = by_name(&entries, "Alpha");
        assert_eq!(alpha.status, Status::Installed);
        assert!(alpha.path.as_ref().unwrap().ends_with("Alpha/bin"));
        assert_eq!(by_name(&entries, "Beta").status, Status::OnThisPc);
        assert_eq!(by_name(&entries, "Gamma").status, Status::NotOnThisPc);
        assert_eq!(entries.len(), 4);
    }

    #[test]
    fn a_live_install_nobody_claims_is_manual() {
        let w = World::new();
        w.write(
            "Games/Obscure Game/.eax-restore-manifest.txt",
            "/x/dsound.dll\n",
        );
        w.write(
            ".config/heroic/config.json",
            &format!(
                r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#,
                w.p("Games").display()
            ),
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        let m = by_name(&entries, "Obscure Game");
        assert_eq!(m.status, Status::Manual);
        assert!(m.game.is_none());
        assert_eq!(entries.len(), 5);
    }

    #[test]
    fn a_hand_installed_database_game_is_recognised_by_its_exe() {
        let w = World::new();
        w.write("Games/Whatever/delta.exe", "");
        w.write(
            "Games/Whatever/.eax-restore-manifest.txt",
            "/x/dsound.dll\n",
        );
        w.write(
            ".config/heroic/config.json",
            &format!(
                r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#,
                w.p("Games").display()
            ),
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        assert_eq!(by_name(&entries, "Delta").status, Status::Installed);
        assert_eq!(entries.len(), 4);
    }

    #[test]
    fn an_uninstalled_game_goes_back_to_on_this_pc() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.write(
            ".local/share/Steam/steamapps/common/Alpha/.eax-restore-manifest.txt",
            "# EAX Restore: uninstalled 2026-01-01\n",
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        assert_eq!(by_name(&entries, "Alpha").status, Status::OnThisPc);
        fs::remove_dir_all(w.p(".local")).unwrap();
    }

    #[test]
    fn manual_games_inside_a_steam_library_are_named_for_their_folder() {
        assert_eq!(
            folder_name(Path::new("/h/steamapps/common/Cool Game/bin")),
            "Cool Game"
        );
        assert_eq!(folder_name(Path::new("/h/Games/Other")), "Other");
        assert_eq!(
            folder_name(Path::new("/h/Games/STALKER Clear Sky/bin")),
            "STALKER Clear Sky"
        );
    }

    #[test]
    fn a_second_install_of_a_listed_game_gets_its_own_row() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.write(
            ".local/share/Steam/steamapps/common/Alpha/.eax-restore-manifest.txt",
            "/x\n",
        );
        w.write("Games/Alpha copy/alpha.exe", "");
        w.write("Games/Alpha copy/.eax-restore-manifest.txt", "/x\n");
        w.write(
            ".config/heroic/config.json",
            &format!(
                r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#,
                w.p("Games").display()
            ),
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        let alphas: Vec<_> = entries.iter().filter(|e| e.name == "Alpha").collect();
        assert_eq!(alphas.len(), 2);
        assert!(alphas
            .iter()
            .all(|e| e.status == Status::Installed && e.game.is_some()));
    }

    #[test]
    fn a_game_installed_outside_every_library_still_gets_a_row() {
        let w = World::new();
        w.write("mnt/games/Obscure/.eax-restore-manifest.txt", "/x\n");
        w.write(
            ".local/state/eax-restore-linux/installed-games.txt",
            &format!("{}\n", w.p("mnt/games/Obscure").display()),
        );
        let entries = build(
            &Database::parse(DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        assert_eq!(by_name(&entries, "Obscure").status, Status::Manual);
    }

    const BOTH_DB: &str = r#"{"games":[
        {"id":"both","name":"Both","exe":"both.exe","stores":{"steam":{"id":70},"gog":{"id":71}}},
        {"id":"steamonly","name":"Steam Only","exe":"so.exe","stores":{"steam":{"id":72}}}]}"#;

    fn heroic_config(w: &World) {
        w.write(
            ".config/heroic/config.json",
            &format!(
                r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#,
                w.p("Games/Heroic").display()
            ),
        );
    }

    fn copies<'a>(entries: &'a [Entry], name: &str) -> Vec<&'a Entry> {
        entries.iter().filter(|e| e.name == name).collect()
    }

    #[test]
    fn copies_found_by_their_exe_get_the_store_their_folder_says() {
        let w = World::new();
        // Neither has an appmanifest or a Heroic record, so only the exe finds them.
        w.write(".local/share/Steam/steamapps/common/Both/both.exe", "");
        w.write(
            ".local/share/Steam/steamapps/common/Both/.eax-restore-manifest.txt",
            "/x\n",
        );
        w.write("Games/Heroic/Both GOTY/both.exe", "");
        w.write("Games/Heroic/Both GOTY/.eax-restore-manifest.txt", "/x\n");
        heroic_config(&w);
        let entries = build(
            &Database::parse(BOTH_DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        let both = copies(&entries, "Both");
        assert_eq!(both.len(), 2);
        let store_at = |part: &str| {
            both.iter()
                .find(|e| {
                    e.path
                        .as_ref()
                        .is_some_and(|p| p.to_string_lossy().contains(part))
                })
                .and_then(|e| e.store)
        };
        assert_eq!(store_at("steamapps/common"), Some(StoreKind::Steam));
        assert_eq!(store_at("Heroic/Both GOTY"), Some(StoreKind::Gog));
    }

    #[test]
    fn a_copy_elsewhere_or_in_a_store_that_does_not_sell_the_game_stays_unknown() {
        let w = World::new();
        w.write("mnt/games/Both/both.exe", "");
        w.write("mnt/games/Both/.eax-restore-manifest.txt", "/x\n");
        // In Heroic's folder, but this game is not sold on GOG.
        w.write("Games/Heroic/So/so.exe", "");
        w.write("Games/Heroic/So/.eax-restore-manifest.txt", "/x\n");
        heroic_config(&w);
        w.write(
            ".local/state/eax-restore-linux/installed-games.txt",
            &format!("{}\n", w.p("mnt/games/Both").display()),
        );
        let entries = build(
            &Database::parse(BOTH_DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        assert_eq!(copies(&entries, "Both")[0].store, None);
        assert_eq!(copies(&entries, "Steam Only")[0].store, None);
    }

    #[test]
    fn the_store_filter_follows_the_copy_not_the_game() {
        use crate::filters::{Filters, StoreFilter};
        let w = World::new();
        w.write(".local/share/Steam/steamapps/common/Both/both.exe", "");
        w.write(
            ".local/share/Steam/steamapps/common/Both/.eax-restore-manifest.txt",
            "/x\n",
        );
        w.write("Games/Heroic/Both GOTY/both.exe", "");
        w.write("Games/Heroic/Both GOTY/.eax-restore-manifest.txt", "/x\n");
        heroic_config(&w);
        let entries = build(
            &Database::parse(BOTH_DB).unwrap(),
            w.home.path(),
            &w.state_file(),
        );
        let shown = |f: StoreFilter| -> Vec<String> {
            let filters = Filters {
                store: f,
                ..Filters::default()
            };
            copies(&entries, "Both")
                .into_iter()
                .filter(|e| filters.passes(e))
                .map(|e| e.path.as_ref().unwrap().display().to_string())
                .collect()
        };
        let (steam, gog) = (shown(StoreFilter::Steam), shown(StoreFilter::Gog));
        assert_eq!((steam.len(), gog.len()), (1, 1));
        assert!(steam[0].contains("steamapps/common"));
        assert!(gog[0].contains("Heroic"));
    }

    /// Two games share the exe name, as the STALKER ones do; the first is sold on
    /// both stores.
    const SHARED_EXE_DB: &str = r#"{"games":[
        {"name":"Pripyat","exe":"xrEngine.exe","stores":{"steam":{"id":80},"gog":{"id":81}}},
        {"name":"Clear Sky","exe":"xrEngine.exe","stores":{"steam":{"id":82},"gog":{"id":83}}}]}"#;

    /// Pripyat installed from both stores: Steam through an appmanifest, GOG through
    /// Heroic's record. The exe sits in `bin/`, where the fix goes.
    fn pripyat_world(steam_fix: bool, gog_fix: bool) -> World {
        let w = World::new();
        w.steam_game(".local/share/Steam", 80, "Pripyat");
        w.write(
            ".local/share/Steam/steamapps/common/Pripyat/bin/xrEngine.exe",
            "",
        );
        w.write("Games/Heroic/Pripyat/bin/xrEngine.exe", "");
        w.write(
            ".config/heroic/gog_store/installed.json",
            &format!(
                r#"{{"installed":[{{"appName":"81","install_path":"{}"}}]}}"#,
                w.p("Games/Heroic/Pripyat").display()
            ),
        );
        if steam_fix {
            w.write(
                ".local/share/Steam/steamapps/common/Pripyat/bin/.eax-restore-manifest.txt",
                "/x\n",
            );
        }
        if gog_fix {
            w.write("Games/Heroic/Pripyat/bin/.eax-restore-manifest.txt", "/x\n");
        }
        w
    }

    fn pripyat_rows(w: &World) -> Vec<Entry> {
        let db = Database::parse(SHARED_EXE_DB).unwrap();
        build(&db, w.home.path(), &w.state_file())
    }

    #[test]
    fn a_game_installed_from_both_stores_is_two_rows_each_with_its_own_store() {
        let w = pripyat_world(true, true);
        let entries = pripyat_rows(&w);
        let both = copies(&entries, "Pripyat");
        assert_eq!(both.len(), 2);
        assert!(both.iter().all(|e| e.status == Status::Installed));
        let gog = both
            .iter()
            .find(|e| e.store == Some(StoreKind::Gog))
            .unwrap();
        assert!(gog.path.as_ref().unwrap().ends_with("Heroic/Pripyat/bin"));
        assert!(both.iter().any(|e| e.store == Some(StoreKind::Steam)));
        // The shared exe name no longer matters: nothing is left to guess at.
        assert!(entries.iter().all(|e| e.status != Status::Manual));
        assert_eq!(entries.len(), 3, "Pripyat twice and Clear Sky once");
    }

    #[test]
    fn only_the_copy_with_the_fix_is_installed() {
        let entries = pripyat_rows(&pripyat_world(true, false));
        let both = copies(&entries, "Pripyat");
        assert_eq!(both.len(), 2);
        let status_of = |k| both.iter().find(|e| e.store == Some(k)).unwrap().status;
        assert_eq!(status_of(StoreKind::Steam), Status::Installed);
        assert_eq!(status_of(StoreKind::Gog), Status::OnThisPc);
    }

    #[test]
    fn two_copies_without_the_fix_are_two_rows_on_this_pc() {
        let entries = pripyat_rows(&pripyat_world(false, false));
        let both = copies(&entries, "Pripyat");
        assert_eq!(both.len(), 2);
        assert!(both.iter().all(|e| e.status == Status::OnThisPc));
    }

    #[test]
    fn a_hand_install_is_still_found_by_its_exe_after_games_with_two_rows() {
        // A game with two rows ahead of it in the list must not shift the lookup
        // of a later game that is matched by its exe.
        let w = pripyat_world(true, true);
        w.write("mnt/games/Later/later.exe", "");
        w.write("mnt/games/Later/.eax-restore-manifest.txt", "/x\n");
        w.write(
            ".local/state/eax-restore-linux/installed-games.txt",
            &format!("{}\n", w.p("mnt/games/Later").display()),
        );
        let db = Database::parse(
            r#"{"games":[
            {"name":"Pripyat","exe":"xrEngine.exe","stores":{"steam":{"id":80},"gog":{"id":81}}},
            {"name":"Later","exe":"later.exe","stores":{"steam":{"id":99}}}]}"#,
        )
        .unwrap();
        let entries = build(&db, w.home.path(), &w.state_file());
        let later = copies(&entries, "Later");
        assert_eq!(later.len(), 1);
        assert_eq!(later[0].status, Status::Installed);
        assert!(later[0].path.as_ref().unwrap().ends_with("mnt/games/Later"));
        assert!(entries.iter().all(|e| e.status != Status::Manual));
    }
}
