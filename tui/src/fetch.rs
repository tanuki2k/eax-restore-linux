//! Downloads the TUI needs from GitHub: the game database, and which
//! channel this build came from (the update check and the run log's folder
//! follow it).

use crate::db::Database;
use anyhow::{anyhow, bail, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

/// "dev" for the rolling prerelease build, set by CI; otherwise "stable".
pub const CHANNEL: &str = match option_env!("EAX_RESTORE_CHANNEL") {
    Some(c) => c,
    None => "stable",
};

/// The same file the script fetches (`GAME_DATABASE_URL` in src/globals.sh).
const DATABASE_URL: &str =
    "https://raw.githubusercontent.com/tanuki2k/eax-restore-linux/dev/game-database.json";

/// The script's own cache file, so there is one saved copy on the machine.
pub fn database_cache(home: &Path) -> PathBuf {
    home.join(".local/share/eax-restore-linux/game-database.v3.json")
}

pub fn curl_database(url: &str) -> Result<Vec<u8>> {
    let out = Command::new("curl")
        .args([
            "-fsSL",
            "--compressed",
            "--connect-timeout",
            "5",
            "--max-time",
            "15",
            url,
        ])
        .output()?;
    if !out.status.success() {
        bail!("The game database download failed.");
    }
    Ok(out.stdout)
}

fn is_usable_database(bytes: &[u8]) -> bool {
    Database::parse(&String::from_utf8_lossy(bytes)).is_ok_and(|d| !d.games.is_empty())
}

/// Fetches a fresh database into `cache`. A download that fails or isn't a
/// database leaves the saved copy as it was, which is used instead; with
/// neither there is nothing to show.
pub fn refresh_database(
    download: &dyn Fn(&str) -> Result<Vec<u8>>,
    url: &str,
    cache: &Path,
) -> Result<PathBuf> {
    if let Some(bytes) = download(url).ok().filter(|b| is_usable_database(b)) {
        let saved = cache.parent().map(fs::create_dir_all).transpose().is_ok() && {
            let tmp = cache.with_extension(format!("part{}", std::process::id()));
            let ok = fs::write(&tmp, &bytes).is_ok() && fs::rename(&tmp, cache).is_ok();
            if !ok {
                let _ = fs::remove_file(&tmp);
            }
            ok
        };
        if saved {
            // The script's etag was for the copy that was just replaced.
            let _ = fs::remove_file(cache.with_extension("json.etag"));
        }
    }
    if fs::read(cache).is_ok_and(|b| is_usable_database(&b)) {
        return Ok(cache.to_path_buf());
    }
    bail!("Couldn't download the game database, and there's no saved copy to use instead, so check your internet connection and try again.")
}

/// The database to use when none was named: fetched, or the saved copy.
pub fn ensure_database() -> Result<PathBuf> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| anyhow!("Couldn't find your home folder."))?;
    eprintln!("Updating the game database...");
    refresh_database(&curl_database, DATABASE_URL, &database_cache(&home))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn leftovers(dir: &Path) -> Vec<String> {
        fs::read_dir(dir)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }

    const DB_OLD: &str = r#"{"games":[{"id":"old","name":"Old"}]}"#;
    const DB_NEW: &str = r#"{"games":[{"id":"new","name":"New"}]}"#;

    fn db_in(dir: &Path, text: &str) -> PathBuf {
        let p = dir.join("game-database.v3.json");
        fs::write(&p, text).unwrap();
        p
    }

    fn serve_db(body: &'static str) -> impl Fn(&str) -> Result<Vec<u8>> {
        move |_: &str| Ok(body.as_bytes().to_vec())
    }

    #[test]
    fn a_fresh_database_replaces_the_saved_one_and_drops_its_etag() {
        let d = tempfile::tempdir().unwrap();
        let cache = db_in(d.path(), DB_OLD);
        fs::write(d.path().join("game-database.v3.json.etag"), "\"abc\"").unwrap();
        refresh_database(&serve_db(DB_NEW), "u", &cache).unwrap();
        assert_eq!(fs::read_to_string(&cache).unwrap(), DB_NEW);
        assert!(!d.path().join("game-database.v3.json.etag").exists());
        assert_eq!(leftovers(d.path()), ["game-database.v3.json"]);
    }

    #[test]
    fn a_first_run_with_no_saved_copy_creates_the_folder_and_the_file() {
        let d = tempfile::tempdir().unwrap();
        let cache = d.path().join("a/b/game-database.v3.json");
        refresh_database(&serve_db(DB_NEW), "u", &cache).unwrap();
        assert_eq!(fs::read_to_string(cache).unwrap(), DB_NEW);
    }

    #[test]
    fn a_page_that_is_not_a_database_is_ignored_and_the_saved_copy_is_used() {
        let d = tempfile::tempdir().unwrap();
        let cache = db_in(d.path(), DB_OLD);
        for junk in ["<html>rate limited</html>", r#"{"games":[]}"#] {
            let got = refresh_database(&serve_db(junk), "u", &cache).unwrap();
            assert_eq!(
                (got.as_path(), fs::read_to_string(&cache).unwrap().as_str()),
                (cache.as_path(), DB_OLD)
            );
        }
    }

    #[test]
    fn offline_falls_back_to_the_saved_copy_or_says_there_is_none() {
        let d = tempfile::tempdir().unwrap();
        let down = |_: &str| -> Result<Vec<u8>> { bail!("offline") };
        let cache = d.path().join("game-database.v3.json");
        let e = refresh_database(&down, "u", &cache).unwrap_err();
        assert!(e.to_string().contains("no saved copy"));
        fs::write(&cache, DB_OLD).unwrap();
        assert_eq!(refresh_database(&down, "u", &cache).unwrap(), cache);
    }

    #[test]
    fn the_cache_is_the_scripts_own_file() {
        assert_eq!(
            database_cache(Path::new("/h")),
            Path::new("/h/.local/share/eax-restore-linux/game-database.v3.json")
        );
    }
}
