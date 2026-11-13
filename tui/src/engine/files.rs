//! What the engine may touch on disk, and how it replaces a file: the name
//! and content checks that stand between a manifest and a delete, the
//! backups an install leaves, and the temp-file swap every write goes
//! through. Ports of the helpers in `src/common.sh`, checked against them by
//! `tests/manifest_oracle.rs`.

use anyhow::{bail, Context, Result};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

/// What follows the last `/`, as the script's `${1##*/}`: nothing for a
/// path that ends in one.
fn file_name(path: &Path) -> &[u8] {
    let bytes = path.as_os_str().as_bytes();
    bytes.rsplit(|&b| b == b'/').next().unwrap_or(bytes)
}

/// Wine puts a placeholder with the real DLL's name in system32/syswow64 for
/// each of its own builtin implementations, so apps that check "does this
/// file exist" still start. They are real PE files with no code, and Wine
/// marks every one with "Wine builtin DLL" or "Wine placeholder DLL". True
/// only for a file that exists, isn't empty and doesn't carry that mark.
pub fn is_genuine_dll(path: &Path) -> bool {
    match std::fs::read(path) {
        Ok(data) => {
            !data.is_empty()
                && !contains(&data, b"Wine builtin DLL")
                && !contains(&data, b"Wine placeholder DLL")
        }
        Err(_) => false,
    }
}

/// Tells kcat's OpenAL Soft from Creative's OpenAL32.dll by content, since
/// the file name is the same: OpenAL Soft carries its own name and its
/// `ALSOFT_` environment variable prefix; Creative's router names neither.
pub fn is_openal_soft_dll(path: &Path) -> bool {
    std::fs::read(path).is_ok_and(|data| {
        !data.is_empty() && (contains(&data, b"OpenAL Soft") || contains(&data, b"ALSOFT_"))
    })
}

/// True when the file's name is one the install deploys. Uninstall only
/// deletes manifest entries that pass, whatever else a manifest says.
pub fn file_is_ours(path: &Path) -> bool {
    let name = file_name(path);
    [
        b"dsound.dll".as_slice(),
        b"dsound.vxd",
        b"dsoal-aldrv.dll",
        b"openal32.dll",
        b"eax.dll",
        b"eaxunified.dll",
    ]
    .iter()
    .any(|n| name.eq_ignore_ascii_case(n))
        // The one the script writes itself, always in this spelling.
        || name == b"alsoft.ini"
}

/// True when the manifest line names the folder 0.28.x copied the HRTF
/// profiles into (`<game>/OpenAL`, or `<game>/OpenAL/HRTF` when OpenAL was
/// already there). Only the name: the caller still checks the path is inside
/// the game's install and is a real folder.
pub fn is_legacy_hrtf_dir(path: &[u8]) -> bool {
    path.ends_with(b"/OpenAL") || path.ends_with(b"/OpenAL/HRTF")
}

fn only_hrtf_data(dir: &Path) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    entries.flatten().all(|entry| {
        let path = entry.path();
        let Ok(kind) = entry.file_type() else {
            return false;
        };
        if kind.is_dir() {
            return only_hrtf_data(&path);
        }
        let name = entry.file_name().as_bytes().to_ascii_lowercase();
        kind.is_file()
            && [b".mhr".as_slice(), b".txt", b".json", b".ini"]
                .iter()
                .any(|e| name.ends_with(e))
    })
}

/// Removes the 0.28.x HRTF folder only when it holds nothing but what the
/// install put in it: HRTF data sets (.mhr) and the small .txt/.json/.ini
/// files that come with them. Anything else (a mod's own file, a symlink)
/// leaves the folder as it is. True when the folder is gone.
pub fn remove_legacy_hrtf_dir(dir: &Path) -> bool {
    if dir.is_symlink() || !dir.is_dir() || !only_hrtf_data(dir) {
        return false;
    }
    let _ = std::fs::remove_dir_all(dir);
    dir.symlink_metadata().is_err()
}

/// True when the path is inside the game's install or inside a Wine prefix's
/// C: drive, the only places an install deploys to. A name check alone would
/// let a copied or edited manifest point at another game's dsound.dll.
pub fn path_in_scope(path: &[u8], install_root: &[u8]) -> bool {
    path.strip_prefix(install_root)
        .is_some_and(|rest| rest.starts_with(b"/"))
        || contains(path, b"/drive_c/")
}

/// True when a regular file with one of the deployed names has the content
/// of what the install puts there: DSOAL's dsound.dll, OpenAL Soft's DLLs,
/// the empty eax dummies, the alsoft.ini it generates. The scan used when
/// there's no manifest relies on this, so a game's own file of the same name
/// is left alone.
pub fn looks_like_our_file(path: &Path) -> bool {
    let Ok(meta) = path.symlink_metadata() else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    let name = file_name(path).to_ascii_lowercase();
    let has = |needle: &[u8]| std::fs::read(path).is_ok_and(|d| contains(&d, needle));
    match name.as_slice() {
        b"dsound.dll" => has(b"DSOAL"),
        b"dsoal-aldrv.dll" | b"openal32.dll" => is_openal_soft_dll(path),
        b"eax.dll" | b"eaxunified.dll" => meta.len() == 0,
        b"alsoft.ini" => has(b"Auto-generated by EAX Restore Script"),
        _ => false,
    }
}

/// `<digit>…_<digit>…`: the tail of a `.bak.YYYYmmdd_HHMMSS` backup name.
fn is_stamp(tail: &[u8]) -> bool {
    tail.first().is_some_and(u8::is_ascii_digit)
        && tail[1..]
            .windows(2)
            .any(|w| w[0] == b'_' && w[1].is_ascii_digit())
}

/// The timestamped backups an install made of `path`
/// (`<path>.bak.YYYYmmdd_HHMMSS`), oldest first by the timestamp in the name:
/// file dates don't say which came first, and other files that merely start
/// with ".bak" aren't ours.
pub fn backups(path: &Path) -> Vec<PathBuf> {
    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return Vec::new();
    };
    let prefix = [name.as_bytes(), b".bak."].concat();
    let mut found: Vec<PathBuf> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| {
            e.file_name()
                .as_bytes()
                .strip_prefix(prefix.as_slice())
                .is_some_and(is_stamp)
        })
        .map(|e| e.path())
        // A link to nothing isn't a backup of anything.
        .filter(|p| p.exists())
        .collect();
    found.sort();
    found
}

/// The oldest of [`backups`]: the player's own original.
pub fn oldest_backup(path: &Path) -> Option<PathBuf> {
    backups(path).into_iter().next()
}

/// The path if it exists, otherwise a same-named file in that folder that
/// differs only by case (DSOUND.DLL for dsound.dll). Linux filesystems are
/// case-sensitive, so an exact-name check alone would put a second
/// dsound.dll beside a game's own DSOUND.DLL instead of backing it up.
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

static TEMP_COUNTER: AtomicU32 = AtomicU32::new(0);

/// A new, empty file beside `target`, so the rename that swaps it in stays
/// on one filesystem.
pub fn temp_beside(target: &Path) -> Result<(PathBuf, std::fs::File)> {
    let dir = target
        .parent()
        .filter(|d| !d.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.subsec_nanos());
    for _ in 0..16 {
        let name = format!(
            ".eax-restore-cfg.{}-{nanos}-{}",
            std::process::id(),
            TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
        );
        let path = dir.join(name);
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(file) => return Ok((path, file)),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e).with_context(|| format!("can't write in {}", dir.display())),
        }
    }
    bail!("can't make a temporary file in {}", dir.display())
}

/// Replaces the target with the temp file written next to it, keeping the
/// target's permissions. A target that is a symlink (a dotfile-managed
/// config, say) is written through, so the link stays a link.
pub fn swap_in(temp: &Path, target: &Path) -> Result<()> {
    let target = if target.is_symlink() {
        std::fs::canonicalize(target).unwrap_or_else(|_| target.to_path_buf())
    } else {
        target.to_path_buf()
    };
    if let Ok(meta) = std::fs::metadata(&target) {
        if meta.is_file() {
            let _ = std::fs::set_permissions(temp, meta.permissions());
        }
    }
    std::fs::rename(temp, &target).with_context(|| format!("can't replace {}", target.display()))
}

/// Writes `data` to `target` through a temp file beside it, so a failure
/// never leaves a half-written file (and leaves no temp file either).
pub fn write_through_temp(target: &Path, data: &[u8]) -> Result<()> {
    let (temp, mut file) = temp_beside(target)?;
    let written = std::io::Write::write_all(&mut file, data)
        .with_context(|| format!("can't write {}", temp.display()))
        .and_then(|()| {
            drop(file);
            swap_in(&temp, target)
        });
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamps() {
        assert!(is_stamp(b"20230101_000000"));
        assert!(is_stamp(b"1_2"));
        assert!(!is_stamp(b"old"));
        assert!(!is_stamp(b"2023"));
        assert!(!is_stamp(b"2023_x"));
        assert!(!is_stamp(b""));
    }

    #[test]
    fn scope_is_the_install_or_a_prefix_drive() {
        assert!(path_in_scope(b"/g/Game/sub/dsound.dll", b"/g/Game"));
        assert!(path_in_scope(b"/h/pfx/drive_c/windows/x.dll", b"/g/Game"));
        assert!(!path_in_scope(b"/g/Game2/dsound.dll", b"/g/Game"));
        assert!(!path_in_scope(b"/g/Game", b"/g/Game"));
    }

    #[test]
    fn a_failed_write_leaves_nothing_behind() {
        let tmp = tempfile::tempdir().unwrap();
        // A folder can't be replaced by a file.
        let target = tmp.path().join("dir");
        std::fs::create_dir(&target).unwrap();
        std::fs::write(target.join("keep"), b"x").unwrap();
        assert!(write_through_temp(&target, b"new").is_err());
        let left: Vec<_> = std::fs::read_dir(tmp.path()).unwrap().flatten().collect();
        assert_eq!(left.len(), 1);
    }
}
