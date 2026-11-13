//! Putting one file where the install deploys it: a file already there is
//! backed up first (or replaced, when it's this install's own from before),
//! and the copy is recorded in the manifest only once it succeeded. Ports
//! of `handle_conflict` and `deploy_copy` in `src/cache.sh`.

use super::{files, manifest};
use std::collections::HashSet;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The local time as `YYYYmmdd_HHMMSS`, for a backup's name, as `date` gives it.
pub fn timestamp() -> String {
    Command::new("date")
        .arg("+%Y%m%d_%H%M%S")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|t| !t.is_empty())
        .unwrap_or_else(|| "00000000_000000".into())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Cleared {
    /// Nothing was there.
    Empty,
    /// The last install's own copy, removed.
    ReplacedOurs,
    /// The file there was moved to this backup.
    BackedUp(PathBuf),
    /// It couldn't be moved aside, so it's left alone and nothing should be
    /// copied over it (a copy can succeed where a move can't, and would
    /// destroy the original with no backup left).
    Failed,
}

impl Cleared {
    pub fn ok(&self) -> bool {
        !matches!(self, Cleared::Failed)
    }
}

/// Clears the way for a file about to be put at `target`. A file there
/// (matched case-insensitively) is backed up as `<target>.bak.<stamp>`,
/// named after the target rather than a differently-cased original, so
/// uninstall finds it. `previous` is the last install's file lines: a file
/// it deployed that still looks like ours is just replaced, since it isn't
/// an original worth keeping.
pub fn handle_conflict(target: &Path, previous: &HashSet<Vec<u8>>, stamp: &str) -> Cleared {
    let Some(existing) = files::find_existing_variant(target) else {
        return Cleared::Empty;
    };
    if previous.contains(target.as_os_str().as_bytes()) && files::looks_like_our_file(&existing) {
        return if std::fs::remove_file(&existing).is_ok() {
            Cleared::ReplacedOurs
        } else {
            Cleared::Failed
        };
    }
    let mut bak = target.as_os_str().to_owned();
    bak.push(format!(".bak.{stamp}"));
    let bak = PathBuf::from(bak);
    match std::fs::rename(&existing, &bak) {
        Ok(()) => Cleared::BackedUp(bak),
        Err(_) => Cleared::Failed,
    }
}

/// Copies one file and records it in the manifest only if the copy
/// succeeded. A failed copy after the original was moved aside puts the
/// original back, so the game isn't left without it. True when copied.
pub fn deploy_copy(src: &Path, dest: &Path, manifest_path: &Path) -> bool {
    if std::fs::copy(src, dest).is_ok() {
        let _ = manifest::append(manifest_path, dest.as_os_str().as_bytes());
        return true;
    }
    // The newest backup, as the script's glob loop leaves it.
    if dest.symlink_metadata().is_err() {
        if let Some(last) = files::backups(dest).pop() {
            let _ = std::fs::rename(last, dest);
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backs_up_replaces_ours_and_restores_on_failure() {
        let tmp = tempfile::tempdir().unwrap();
        let d = tmp.path();
        let m = d.join("m");
        let target = d.join("dsound.dll");
        std::fs::write(d.join("DSOUND.DLL"), "the game's").unwrap();
        let none = HashSet::new();
        assert_eq!(
            handle_conflict(&target, &none, "20260101_000000"),
            Cleared::BackedUp(d.join("dsound.dll.bak.20260101_000000"))
        );
        std::fs::write(d.join("src"), "DSOAL build").unwrap();
        assert!(deploy_copy(&d.join("src"), &target, &m));
        assert_eq!(
            std::fs::read_to_string(&m).unwrap(),
            format!("{}\n", target.display())
        );

        let ours: HashSet<Vec<u8>> = [target.as_os_str().as_bytes().to_vec()].into();
        assert_eq!(handle_conflict(&target, &ours, "x"), Cleared::ReplacedOurs);
        assert!(!target.exists());

        // A copy from nowhere fails and puts the newest backup back.
        std::fs::write(d.join("dsound.dll.bak.20250101_000000"), "older").unwrap();
        assert!(!deploy_copy(&d.join("missing"), &target, &m));
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "the game's");
    }
}
