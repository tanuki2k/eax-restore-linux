//! The home list: database games and manual installs, each with a status for
//! this machine.

use crate::db::{Database, Game};
use crate::library::{self, Found, StoreKind};
use std::collections::HashSet;
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
        StoreKind::Steam => g.stores.steam.as_ref().is_some_and(|s| s.id.to_string() == f.id),
        StoreKind::Gog => g.stores.gog.as_ref().is_some_and(|s| s.id.to_string() == f.id),
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
const EXE_FOLDERS: [&str; 8] = ["bin", "system", "binaries", "win32", "win64", "x64", "x86", "release"];

/// A name for a game the database doesn't know: the Steam folder it sits in, or
/// else its own folder's name (its parent's when that is only the exe folder).
fn folder_name(dir: &Path) -> String {
    let parts: Vec<_> = dir.components().map(|c| c.as_os_str().to_string_lossy()).collect();
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

pub fn build(db: &Database, home: &Path) -> Vec<Entry> {
    let steam_ids: HashSet<u64> = db.games.iter().filter_map(|g| g.stores.steam.as_ref().map(|s| s.id)).collect();
    let gog_ids: HashSet<String> = db.games.iter().filter_map(|g| g.stores.gog.as_ref().map(|s| s.id.to_string())).collect();
    // Steam first, so a game owned on both stores shows its Steam copy.
    let mut found = library::scan_steam(home, &steam_ids);
    found.extend(library::scan_heroic(home, &gog_ids));
    let live = library::live_manifest_dirs(home);

    let mut claimed: HashSet<&PathBuf> = HashSet::new();
    let mut entries: Vec<Entry> = db
        .games
        .iter()
        .map(|g| {
            let mut e = Entry::database_only(g.clone());
            let Some(f) = found.iter().find(|f| is_match(g, f)) else { return e };
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
            e
        })
        .collect();

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
        let found_before = |i: usize| entries[i].status == Status::NotOnThisPc;
        match owners[..] {
            // The database order is the order of `entries`' first part.
            [i] if found_before(i) => {
                entries[i].status = Status::Installed;
                entries[i].path = Some(dir.clone());
            }
            // Another install of a game already listed: its own row.
            [i] => {
                let mut e = Entry::database_only(db.games[i].clone());
                e.status = Status::Installed;
                e.path = Some(dir.clone());
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
        let entries = build(&Database::parse(DB).unwrap(), w.home.path());
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
        w.write("Games/Obscure Game/.eax-restore-manifest.txt", "/x/dsound.dll\n");
        w.write(
            ".config/heroic/config.json",
            &format!(r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#, w.p("Games").display()),
        );
        let entries = build(&Database::parse(DB).unwrap(), w.home.path());
        let m = by_name(&entries, "Obscure Game");
        assert_eq!(m.status, Status::Manual);
        assert!(m.game.is_none());
        assert_eq!(entries.len(), 5);
    }

    #[test]
    fn a_hand_installed_database_game_is_recognised_by_its_exe() {
        let w = World::new();
        w.write("Games/Whatever/delta.exe", "");
        w.write("Games/Whatever/.eax-restore-manifest.txt", "/x/dsound.dll\n");
        w.write(
            ".config/heroic/config.json",
            &format!(r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#, w.p("Games").display()),
        );
        let entries = build(&Database::parse(DB).unwrap(), w.home.path());
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
        let entries = build(&Database::parse(DB).unwrap(), w.home.path());
        assert_eq!(by_name(&entries, "Alpha").status, Status::OnThisPc);
        fs::remove_dir_all(w.p(".local")).unwrap();
    }

    #[test]
    fn manual_games_inside_a_steam_library_are_named_for_their_folder() {
        assert_eq!(folder_name(Path::new("/h/steamapps/common/Cool Game/bin")), "Cool Game");
        assert_eq!(folder_name(Path::new("/h/Games/Other")), "Other");
        assert_eq!(folder_name(Path::new("/h/Games/STALKER Clear Sky/bin")), "STALKER Clear Sky");
    }

    #[test]
    fn a_second_install_of_a_listed_game_gets_its_own_row() {
        let w = World::new();
        w.steam_game(".local/share/Steam", 10, "Alpha");
        w.write(".local/share/Steam/steamapps/common/Alpha/.eax-restore-manifest.txt", "/x\n");
        w.write("Games/Alpha copy/alpha.exe", "");
        w.write("Games/Alpha copy/.eax-restore-manifest.txt", "/x\n");
        w.write(
            ".config/heroic/config.json",
            &format!(r#"{{"defaultSettings":{{"defaultInstallPath":"{}"}}}}"#, w.p("Games").display()),
        );
        let entries = build(&Database::parse(DB).unwrap(), w.home.path());
        let alphas: Vec<_> = entries.iter().filter(|e| e.name == "Alpha").collect();
        assert_eq!(alphas.len(), 2);
        assert!(alphas.iter().all(|e| e.status == Status::Installed && e.game.is_some()));
    }
}
