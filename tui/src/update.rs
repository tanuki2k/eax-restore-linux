//! The update check, as the script's `src/self-update.sh` does it for a dev
//! build: only the nightly prerelease carries the TUI, so only a dev build
//! checks. CI uploads `eax-restore-linux-tui-x86_64.build` (the build
//! number) with the binary, so a higher number there means a newer binary
//! is up, and a failed Rust build leaves the old number in place. Every
//! failure is silent: being offline mustn't cost the player anything.

use sha2::{Digest, Sha256};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const BINARY: &str = "eax-restore-linux-tui-x86_64";
const BASE: &str = "https://github.com/tanuki2k/eax-restore-linux/releases/download/nightly";
pub const RELEASES_PAGE: &str = "https://github.com/tanuki2k/eax-restore-linux/releases";

fn url(file: &str) -> String {
    format!("{BASE}/{file}")
}

/// This build checks for updates: a clean dev build with a number, and the
/// player hasn't turned the check off.
pub fn wanted() -> bool {
    crate::fetch::CHANNEL == "dev"
        && crate::build_info::number().is_some()
        && !crate::build_info::DIRTY
        && !std::env::var("EAX_RESTORE_SKIP_UPDATE_CHECK")
            .is_ok_and(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "y"))
}

/// The text of a small file, or none on any failure.
fn fetch_text(curl: &str, url: &str) -> Option<String> {
    let out = Command::new(curl)
        .args(["-fsSL", "--max-time", "5", url])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// A build number file's number.
pub fn parse_build(text: &str) -> Option<u32> {
    text.trim().parse().ok()
}

/// The remote build, when it's newer than this one.
pub fn newer(remote: Option<u32>, local: Option<u32>) -> Option<u32> {
    match (remote, local) {
        (Some(r), Some(l)) if r > l => Some(r),
        _ => None,
    }
}

/// The newer build on the nightly, if there is one. Meant for a thread.
pub fn check() -> Option<u32> {
    if !wanted() {
        return None;
    }
    check_with("curl", crate::build_info::number())
}

pub fn check_with(curl: &str, local: Option<u32>) -> Option<u32> {
    let remote = fetch_text(curl, &url(&format!("{BINARY}.build"))).and_then(|t| parse_build(&t));
    newer(remote, local)
}

/// Why an update didn't happen; the binary is left as it was.
#[derive(Debug, PartialEq, Eq)]
pub enum Failed {
    /// The folder the binary is in can't be written.
    ReadOnly,
    /// It didn't download, or its checksum didn't match.
    Download,
}

/// Downloads the new binary beside `exe`, checks it against the release's
/// `.sha256`, and swaps it in (same folder, so the rename is atomic).
pub fn install(curl: &str, exe: &Path) -> Result<(), Failed> {
    let dir = exe.parent().ok_or(Failed::ReadOnly)?;
    if !crate::engine::files::writable(dir) {
        return Err(Failed::ReadOnly);
    }
    let tmp = dir.join(format!(".eax-restore-update.{}", std::process::id()));
    let result = download(curl, &tmp).and_then(|()| {
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o755))
            .map_err(|_| Failed::Download)?;
        fs::rename(&tmp, exe).map_err(|_| Failed::Download)
    });
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn download(curl: &str, tmp: &Path) -> Result<(), Failed> {
    let expected = fetch_text(curl, &url(&format!("{BINARY}.sha256")))
        .and_then(|t| t.split_whitespace().next().map(str::to_lowercase))
        .filter(|s| s.len() == 64)
        .ok_or(Failed::Download)?;
    let ok = Command::new(curl)
        .args(["-fsSL", "--max-time", "120", "-o"])
        .arg(tmp)
        .arg(url(BINARY))
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    let bytes = fs::read(tmp).ok().filter(|_| ok).ok_or(Failed::Download)?;
    if format!("{:x}", Sha256::digest(&bytes)) != expected {
        return Err(Failed::Download);
    }
    Ok(())
}

/// Starts the new binary in this one's place, with the same arguments.
/// Only returns if that fails.
pub fn restart(exe: &Path) -> std::io::Error {
    use std::os::unix::process::CommandExt;
    let _ = std::io::stdout().flush();
    Command::new(exe).args(std::env::args_os().skip(1)).exec()
}

/// The running binary's path, read before it's replaced (afterwards Linux
/// shows it as "… (deleted)").
pub fn current_exe() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stub_curl(dir: &Path, build: &str, binary: &[u8], sha: Option<&str>) -> String {
        let files = dir.join("files");
        fs::create_dir_all(&files).unwrap();
        fs::write(files.join("build"), build).unwrap();
        fs::write(files.join("bin"), binary).unwrap();
        let sha = sha.map_or_else(|| format!("{:x}", Sha256::digest(binary)), str::to_string);
        fs::write(files.join("sha"), format!("{sha}  {BINARY}\n")).unwrap();
        let f = files.display();
        let curl = dir.join("curl");
        fs::write(
            &curl,
            format!(
                "#!/bin/sh\nout=\"\"\nfor a in \"$@\"; do\n  [ \"$prev\" = -o ] && out=\"$a\"\n  prev=\"$a\"; url=\"$a\"\ndone\n\
                 case \"$url\" in\n  *.build) src={f}/build ;;\n  *.sha256) src={f}/sha ;;\n  *{BINARY}) src={f}/bin ;;\n  *) exit 22 ;;\nesac\n\
                 [ -s \"$src\" ] || exit 22\nif [ -n \"$out\" ]; then cp \"$src\" \"$out\"; else cat \"$src\"; fi\n"
            ),
        )
        .unwrap();
        fs::set_permissions(&curl, fs::Permissions::from_mode(0o755)).unwrap();
        curl.display().to_string()
    }

    #[test]
    fn only_a_higher_number_is_an_update() {
        assert_eq!(newer(Some(1850), Some(1842)), Some(1850));
        assert_eq!(newer(Some(1842), Some(1842)), None);
        assert_eq!(newer(Some(1800), Some(1842)), None);
        assert_eq!(newer(None, Some(1842)), None);
        assert_eq!(newer(Some(1850), None), None);
        assert_eq!(parse_build("1850\n"), Some(1850));
        assert_eq!(parse_build("<html>"), None);
    }

    #[test]
    fn the_check_reads_the_nightlys_build_file() {
        let t = tempfile::tempdir().unwrap();
        let curl = stub_curl(t.path(), "1850\n", b"new", None);
        assert_eq!(check_with(&curl, Some(1842)), Some(1850));
        assert_eq!(check_with(&curl, Some(1850)), None);
        let junk = tempfile::tempdir().unwrap();
        let curl = stub_curl(junk.path(), "Not Found", b"new", None);
        assert_eq!(check_with(&curl, Some(1842)), None);
        // No network: curl fails.
        assert_eq!(check_with("false", Some(1842)), None);
    }

    #[test]
    fn a_good_download_replaces_the_binary() {
        let t = tempfile::tempdir().unwrap();
        let curl = stub_curl(t.path(), "1850", b"new binary", None);
        let exe = t.path().join("app/eax-restore");
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        fs::write(&exe, "old binary").unwrap();
        assert_eq!(install(&curl, &exe), Ok(()));
        assert_eq!(fs::read(&exe).unwrap(), b"new binary");
        assert!(fs::metadata(&exe).unwrap().permissions().mode() & 0o111 != 0);
        assert_eq!(fs::read_dir(exe.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn a_bad_checksum_leaves_the_binary_alone() {
        let t = tempfile::tempdir().unwrap();
        let curl = stub_curl(t.path(), "1850", b"new binary", Some(&"0".repeat(64)));
        let exe = t.path().join("app/eax-restore");
        fs::create_dir_all(exe.parent().unwrap()).unwrap();
        fs::write(&exe, "old binary").unwrap();
        assert_eq!(install(&curl, &exe), Err(Failed::Download));
        assert_eq!(fs::read(&exe).unwrap(), b"old binary");
        assert_eq!(fs::read_dir(exe.parent().unwrap()).unwrap().count(), 1);
    }

    #[test]
    fn a_folder_that_cant_be_written_says_so() {
        let t = tempfile::tempdir().unwrap();
        let curl = stub_curl(t.path(), "1850", b"new binary", None);
        let app = t.path().join("app");
        fs::create_dir_all(&app).unwrap();
        let exe = app.join("eax-restore");
        fs::write(&exe, "old binary").unwrap();
        fs::set_permissions(&app, fs::Permissions::from_mode(0o555)).unwrap();
        let writable = crate::engine::files::writable(&app);
        let r = install(&curl, &exe);
        fs::set_permissions(&app, fs::Permissions::from_mode(0o755)).unwrap();
        // root can write anywhere, so there's nothing to see then.
        if !writable {
            assert_eq!(r, Err(Failed::ReadOnly));
            assert_eq!(fs::read(&exe).unwrap(), b"old binary");
        }
    }
}
