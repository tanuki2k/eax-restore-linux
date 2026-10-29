//! Getting the Bash installer when it isn't beside this program: download it
//! from the release on this program's channel, check it against the release's
//! .sha256 (like the script's own self-update), and keep it in the cache.

use crate::db::Database;
use anyhow::{anyhow, bail, Result};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const NAME: &str = "eax-restore-linux.sh";
const REPO: &str = "tanuki2k/eax-restore-linux";
/// A script without this can't be started on one action and one game.
const MARKER: &[u8] = b"EAX_RESTORE_ACTION";

/// "dev" for the rolling prerelease build, set by CI; otherwise "stable".
pub const CHANNEL: &str = match option_env!("EAX_RESTORE_CHANNEL") {
    Some(c) => c,
    None => "stable",
};

pub fn script_url(channel: &str) -> String {
    if channel == "dev" {
        format!("https://github.com/{REPO}/releases/download/dev/{NAME}")
    } else {
        format!("https://github.com/{REPO}/releases/latest/download/{NAME}")
    }
}

/// `$XDG_DATA_HOME`, else `~/.local/share`.
pub fn data_home() -> Option<PathBuf> {
    std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
}

/// Each channel keeps its own copy, beside the script's own cache.
pub fn cache_path(data_home: &Path, channel: &str) -> PathBuf {
    data_home
        .join("eax-restore-linux/tui")
        .join(channel)
        .join(NAME)
}

fn has_marker(bytes: &[u8]) -> bool {
    bytes.windows(MARKER.len()).any(|w| w == MARKER)
}

/// True when the file can be driven by this program.
pub fn supports_actions(path: &Path) -> bool {
    fs::read(path).is_ok_and(|b| has_marker(&b))
}

/// The hash in a `sha256sum` line, if it looks like one.
fn first_sha(text: &str) -> Option<String> {
    let word = text.split_whitespace().next()?.to_lowercase();
    (word.len() == 64 && word.bytes().all(|b| b.is_ascii_hexdigit())).then_some(word)
}

/// The real download: curl, which the installer needs anyway.
pub fn curl_download(url: &str) -> Result<Vec<u8>> {
    let out = Command::new("curl")
        .args(["-fsSL", "--max-time", "60", url])
        .output()
        .map_err(|_| {
            anyhow!("Couldn't download the installer script because curl isn't installed.")
        })?;
    if !out.status.success() {
        bail!(
            "Couldn't download the installer script. Check your internet connection and try again."
        );
    }
    Ok(out.stdout)
}

/// Downloads `url`, checks it and puts it at `target`. On any failure the
/// target is left as it was.
pub fn install_script(
    download: &dyn Fn(&str) -> Result<Vec<u8>>,
    url: &str,
    target: &Path,
) -> Result<()> {
    let script = download(url)?;
    let sums = download(&format!("{url}.sha256"))?;
    let expected = first_sha(&String::from_utf8_lossy(&sums)).ok_or_else(|| {
        anyhow!("Couldn't check that the downloaded installer script is intact, so it wasn't kept.")
    })?;
    if format!("{:x}", Sha256::digest(&script)) != expected {
        bail!(
            "The installer script didn't download correctly, so it wasn't kept. Please try again."
        );
    }
    if !has_marker(&script) {
        bail!(
            "The installer script on GitHub is older than this program and can't be used with it."
        );
    }

    let dir = target
        .parent()
        .ok_or_else(|| anyhow!("Couldn't find a folder to save the installer script in."))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{NAME}.part{}", std::process::id()));
    let result = (|| -> Result<()> {
        fs::write(&tmp, &script)?;
        let ok = Command::new("bash")
            .arg("-n")
            .arg(&tmp)
            .status()
            .is_ok_and(|s| s.success());
        if !ok {
            bail!(
                "The downloaded installer script was damaged, so it wasn't kept. Please try again."
            );
        }
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))?;
        fs::rename(&tmp, target)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// Downloads this channel's script into the cache and returns where it is.
pub fn ensure_script() -> Result<PathBuf> {
    let home = data_home().ok_or_else(|| anyhow!("Couldn't find your home folder."))?;
    let target = cache_path(&home, CHANNEL);
    eprintln!("Downloading the installer script...");
    install_script(&curl_download, &script_url(CHANNEL), &target)?;
    Ok(target)
}

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

    const GOOD: &str = "#!/bin/bash\n# EAX_RESTORE_ACTION is read here\necho hi\n";

    fn sha(s: &str) -> String {
        format!("{:x}  {NAME}\n", Sha256::digest(s.as_bytes()))
    }

    /// A downloader that serves the script and its checksum from memory.
    fn serve(script: &str, sums: &str) -> impl Fn(&str) -> Result<Vec<u8>> {
        let (script, sums) = (script.to_string(), sums.to_string());
        move |url: &str| {
            Ok(if url.ends_with(".sha256") {
                sums.clone()
            } else {
                script.clone()
            }
            .into_bytes())
        }
    }

    fn leftovers(dir: &Path) -> Vec<String> {
        fs::read_dir(dir)
            .map(|d| {
                d.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .collect()
            })
            .unwrap_or_default()
    }

    #[test]
    fn each_channel_has_its_own_url_and_cache_folder() {
        assert!(script_url("dev").ends_with("/releases/download/dev/eax-restore-linux.sh"));
        assert!(script_url("stable").ends_with("/releases/latest/download/eax-restore-linux.sh"));
        let a = cache_path(Path::new("/d"), "dev");
        assert_eq!(
            a,
            Path::new("/d/eax-restore-linux/tui/dev/eax-restore-linux.sh")
        );
        assert_ne!(a, cache_path(Path::new("/d"), "stable"));
    }

    #[test]
    fn reads_the_hash_out_of_a_sha256sum_line() {
        let h = "a".repeat(64);
        assert_eq!(first_sha(&format!("{h}  file.sh\n")), Some(h.clone()));
        assert_eq!(first_sha(&h.to_uppercase()), Some(h));
        assert_eq!(first_sha("not a hash  file"), None);
        assert_eq!(first_sha(""), None);
    }

    #[test]
    fn a_script_must_mention_the_action_variable() {
        let d = tempfile::tempdir().unwrap();
        let (new, old) = (d.path().join("new.sh"), d.path().join("old.sh"));
        fs::write(&new, GOOD).unwrap();
        fs::write(&old, "#!/bin/bash\necho old\n").unwrap();
        assert!(supports_actions(&new));
        assert!(!supports_actions(&old));
        assert!(!supports_actions(&d.path().join("missing.sh")));
    }

    #[test]
    fn a_good_download_is_kept_executable_with_nothing_left_over() {
        let d = tempfile::tempdir().unwrap();
        let target = d.path().join("tui/dev").join(NAME);
        install_script(&serve(GOOD, &sha(GOOD)), "https://x/a.sh", &target).unwrap();
        assert_eq!(fs::read_to_string(&target).unwrap(), GOOD);
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o111,
            0o111
        );
        assert_eq!(leftovers(target.parent().unwrap()), [NAME]);
    }

    #[test]
    fn a_checksum_mismatch_keeps_the_old_script() {
        let d = tempfile::tempdir().unwrap();
        let target = d.path().join(NAME);
        fs::write(&target, "old").unwrap();
        let e = install_script(&serve(GOOD, &sha("something else")), "u", &target).unwrap_err();
        assert!(e.to_string().contains("didn't download correctly"));
        assert_eq!(fs::read_to_string(&target).unwrap(), "old");
        assert_eq!(leftovers(d.path()), [NAME]);
    }

    #[test]
    fn a_script_from_before_the_action_variable_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let old = "#!/bin/bash\necho old\n";
        let target = d.path().join(NAME);
        let e = install_script(&serve(old, &sha(old)), "u", &target).unwrap_err();
        assert!(e.to_string().contains("older than this program"));
        assert!(!target.exists());
    }

    #[test]
    fn a_script_with_a_syntax_error_is_refused_and_cleaned_up() {
        let d = tempfile::tempdir().unwrap();
        let bad = "# EAX_RESTORE_ACTION\nif then fi (\n";
        let target = d.path().join(NAME);
        let e = install_script(&serve(bad, &sha(bad)), "u", &target).unwrap_err();
        assert!(e.to_string().contains("was damaged"));
        assert!(leftovers(d.path()).is_empty());
    }

    #[test]
    fn an_unreadable_checksum_file_is_refused() {
        let d = tempfile::tempdir().unwrap();
        let e = install_script(&serve(GOOD, "<html>404</html>"), "u", &d.path().join(NAME))
            .unwrap_err();
        assert!(e.to_string().contains("is intact"));
    }

    #[test]
    fn a_failed_download_is_passed_on_and_changes_nothing() {
        let d = tempfile::tempdir().unwrap();
        let target = d.path().join(NAME);
        let down =
            |_: &str| -> Result<Vec<u8>> { bail!("Couldn't download the installer script.") };
        assert!(install_script(&down, "u", &target).is_err());
        assert!(!target.exists());
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
