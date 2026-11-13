//! Where a game's config file is: `resolve_config_file` and
//! `game_install_root`.

use super::safety::split_locations;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// The folders a location's base name can stand for.
pub struct Places<'a> {
    /// The folder the game's exe is in (`game_exe:`).
    pub game_dir: &'a Path,
    /// The game's install root (`game_root:`), from `game_install_root`.
    pub install_root: &'a Path,
    /// The Wine/Proton prefix, when one is known (`prefix_*:`).
    pub prefix: Option<&'a Path>,
    /// The Linux user's name: a Wine prefix names its user folder after it,
    /// where Proton uses `steamuser`.
    pub user: &'a str,
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// The first location that exists.
    First,
    /// The first location whose folder exists, for a file about to be created.
    Create,
    /// Every location that exists, for a game that keeps the same file in
    /// several places (the file's `all_locations`).
    All,
}

/// The path if it exists, otherwise a same-named file in that folder that
/// differs only by case. Linux filesystems are case-sensitive, and a game's
/// file isn't always spelled the way the database has it.
pub fn find_existing_variant(path: &Path) -> Option<PathBuf> {
    if path.symlink_metadata().is_ok() {
        return Some(path.to_path_buf());
    }
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    let dir = path.parent()?;
    std::fs::read_dir(dir)
        .ok()?
        .flatten()
        .find(|e| e.file_name().to_string_lossy().to_lowercase() == name)
        .map(|e| e.path())
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (a.metadata(), b.metadata()) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

fn candidate_dirs(base: &str, rel: &str, places: &Places) -> Vec<PathBuf> {
    let users = |tail: &str| -> Vec<PathBuf> {
        let Some(prefix) = places.prefix else {
            return Vec::new();
        };
        ["steamuser", places.user]
            .iter()
            .map(|u| prefix.join("drive_c/users").join(u).join(tail))
            .collect()
    };
    match base {
        // game / install are the old names for game_exe / game_root.
        "game_exe" | "game" => vec![places.game_dir.to_path_buf()],
        "game_root" | "install" => vec![places.install_root.to_path_buf()],
        "prefix_documents" => users("Documents"),
        "prefix_appdata" => users("AppData/Roaming"),
        "prefix_localappdata" => users("AppData/Local"),
        // Shared by every user, so one folder (F.E.A.R. keeps its profiles here).
        "prefix_public_documents" => places
            .prefix
            .map(|p| p.join("drive_c/users/Public/Documents"))
            .into_iter()
            .collect(),
        // The prefix's own registry files, nothing else.
        "prefix" if rel == "system.reg" || rel == "user.reg" => {
            places.prefix.map(Path::to_path_buf).into_iter().collect()
        }
        _ => Vec::new(),
    }
}

/// `locations` is the database's "base:path|base:path…" list. Returns at
/// most one path unless the mode is `All`.
pub fn resolve_config_file(locations: &str, mode: Mode, places: &Places) -> Vec<PathBuf> {
    let mut have: Vec<PathBuf> = Vec::new();
    for loc in split_locations(locations) {
        let (base, rel) = loc.split_once(':').unwrap_or((loc, loc));
        for dir in candidate_dirs(base, rel, places) {
            let candidate = PathBuf::from(format!("{}/{rel}", dir.display()));
            if mode == Mode::Create {
                if candidate.parent().is_some_and(Path::is_dir) {
                    return vec![candidate];
                }
                continue;
            }
            let Some(found) = find_existing_variant(&candidate).filter(|f| f.is_file()) else {
                continue;
            };
            if mode == Mode::First {
                return vec![found];
            }
            // steamuser and the user's own name can be the same folder.
            if !have.iter().any(|p| same_file(p, &found)) {
                have.push(found);
            }
        }
    }
    have
}

/// The game's install root, for "game_root:" locations: the folder the
/// library scan matched (`scanned`), else the steamapps/common/<Game> folder
/// the game's folder sits in, else the longest Heroic install path it sits
/// in, else the game's folder itself.
pub fn game_install_root(
    game_dir: &Path,
    scanned: Option<&Path>,
    heroic_install_paths: &[PathBuf],
) -> PathBuf {
    if let Some(root) = scanned.filter(|r| game_dir.starts_with(r)) {
        return root.to_path_buf();
    }
    const COMMON: &str = "/steamapps/common/";
    let text = game_dir.to_string_lossy();
    if let Some(at) = text.find(COMMON) {
        let rest = &text[at + COMMON.len()..];
        let game = rest.split('/').next().unwrap_or(rest);
        return PathBuf::from(format!("{}{COMMON}{game}", &text[..at]));
    }
    heroic_install_paths
        .iter()
        .filter(|p| !p.as_os_str().is_empty() && game_dir.starts_with(p))
        .max_by_key(|p| p.as_os_str().len())
        .map_or_else(|| game_dir.to_path_buf(), |p| p.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn touch(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, b"x").unwrap();
    }

    #[test]
    fn install_root_rules() {
        let dir = Path::new("/lib/steamapps/common/Game/bin/x86");
        assert_eq!(
            game_install_root(dir, None, &[]),
            Path::new("/lib/steamapps/common/Game")
        );
        assert_eq!(
            game_install_root(dir, Some(Path::new("/lib/steamapps/common/Game/bin")), &[]),
            Path::new("/lib/steamapps/common/Game/bin")
        );
        let gog = Path::new("/games/Heroic/Game/System");
        let paths = [
            PathBuf::from("/games/Heroic"),
            PathBuf::from("/games/Heroic/Game"),
        ];
        assert_eq!(
            game_install_root(gog, None, &paths),
            Path::new("/games/Heroic/Game")
        );
        assert_eq!(game_install_root(gog, None, &[]), gog);
    }

    #[test]
    fn resolves_first_all_and_create() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("game");
        let prefix = tmp.path().join("pfx");
        touch(&game.join("System/Game.INI"));
        touch(&prefix.join("drive_c/users/steamuser/Documents/G/a.ini"));
        touch(&prefix.join("drive_c/users/me/Documents/G/a.ini"));
        touch(&prefix.join("user.reg"));
        let places = Places {
            game_dir: &game,
            install_root: &game,
            prefix: Some(&prefix),
            user: "me",
        };
        let first = |l| resolve_config_file(l, Mode::First, &places);
        // The file name's case is matched loosely, the folders' exactly.
        assert_eq!(
            first("game_exe:System/game.ini"),
            vec![game.join("System/Game.INI")]
        );
        assert!(first("game_exe:system/game.ini").is_empty());
        assert_eq!(
            first("game_exe:nope.ini|prefix_documents:G/a.ini"),
            vec![prefix.join("drive_c/users/steamuser/Documents/G/a.ini")]
        );
        assert_eq!(first("prefix:user.reg"), vec![prefix.join("user.reg")]);
        assert!(first("prefix:other.reg").is_empty());
        assert_eq!(
            resolve_config_file("prefix_documents:G/a.ini", Mode::All, &places).len(),
            2
        );
        assert_eq!(
            resolve_config_file(
                "game_exe:Missing/a.ini|game_exe:System/new.ini",
                Mode::Create,
                &places
            ),
            vec![game.join("System/new.ini")]
        );
        let no_prefix = Places {
            prefix: None,
            ..places
        };
        assert!(
            resolve_config_file("prefix_documents:G/a.ini", Mode::First, &no_prefix).is_empty()
        );
    }

    #[test]
    fn one_file_reached_twice_is_listed_once() {
        let tmp = tempfile::tempdir().unwrap();
        let prefix = tmp.path().join("pfx");
        touch(&prefix.join("drive_c/users/steamuser/Documents/a.ini"));
        let places = Places {
            game_dir: tmp.path(),
            install_root: tmp.path(),
            prefix: Some(&prefix),
            user: "steamuser",
        };
        assert_eq!(
            resolve_config_file("prefix_documents:a.ini", Mode::All, &places).len(),
            1
        );
    }
}
