//! The install's changes inside a Wine prefix: the DLLs in its system
//! folder, COM routing and the DLL override in its registry. Ports of
//! `deploy_prefix_dlls`, `apply_prefix_registry`, `remove_prefix_registry`,
//! `registry_has_value` and `verify_dll_override`.

use super::deploy::{deploy_copy, handle_conflict, Cleared};
use super::wine::Prefix;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const DSOUND_CLSIDS: [&str; 2] = [
    "{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}",
    "{47D4D946-62E8-11CF-93BC-444553540000}",
];

/// The .reg text that routes DirectSound's COM objects to dsound.dll and/or
/// sets `<dll>` to native-then-builtin.
pub fn patch_text(com: bool, override_dll: Option<&str>) -> String {
    let mut out = String::from("Windows Registry Editor Version 5.00\n\n");
    if com {
        for node in ["", "WOW6432Node\\"] {
            for clsid in DSOUND_CLSIDS {
                out.push_str(&format!(
                    "[HKEY_CURRENT_USER\\Software\\Classes\\{node}CLSID\\{clsid}\\InprocServer32]\n@=\"dsound.dll\"\n\n"
                ));
            }
        }
    }
    if let Some(dll) = override_dll {
        out.push_str(&format!(
            "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"{dll}\"=\"native,builtin\"\n\n"
        ));
    }
    out
}

/// The .reg text that takes them out again. `dll` is the overridden DLL, or
/// `both` (dsound and openal32) when no manifest says which.
pub fn removal_text(com: bool, dll: Option<&str>) -> String {
    let mut out = String::from("Windows Registry Editor Version 5.00\n\n");
    match dll {
        Some("both") => out.push_str(
            "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"dsound\"=-\n\"openal32\"=-\n\n",
        ),
        Some(d) if !d.is_empty() => out.push_str(&format!(
            "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"{d}\"=-\n\n"
        )),
        _ => {}
    }
    if com {
        for node in ["", "WOW6432Node\\"] {
            for clsid in DSOUND_CLSIDS {
                out.push_str(&format!(
                    "[-HKEY_CURRENT_USER\\Software\\Classes\\{node}CLSID\\{clsid}]\n"
                ));
            }
        }
    }
    out
}

/// True when one section of a Wine .reg store file has exactly this value
/// line (any case). `section` is written as the file has it, with doubled
/// backslashes.
pub fn registry_has_value(store: &Path, section: &str, line: &str) -> bool {
    let Ok(data) = std::fs::read(store) else {
        return false;
    };
    let text = String::from_utf8_lossy(&data);
    let head = format!("[{section}]");
    let want = line.to_lowercase();
    let mut inside = false;
    let mut found = false;
    for l in text.split('\n') {
        if l.starts_with(&format!("{head} ")) || l == head {
            inside = true;
            continue;
        }
        if l.starts_with('[') {
            inside = false;
        }
        if inside && l.to_lowercase() == want {
            found = true;
        }
    }
    found
}

/// A new, empty .reg file in the game folder rather than /tmp: protontricks
/// runs regedit inside the Steam Runtime's container, which may not see
/// /tmp, while the game's own library folder is always visible.
fn reg_file(game_dir: &Path, name: &str) -> Option<(PathBuf, std::fs::File)> {
    for n in 0..64u32 {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.subsec_nanos());
        let p = game_dir.join(format!(
            ".eax-restore-{name}-{:06x}.reg",
            (stamp ^ std::process::id().wrapping_mul(2_654_435_761) ^ n) & 0xff_ffff
        ));
        if let Ok(f) = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&p)
        {
            return Some((p, f));
        }
    }
    None
}

/// Writes `text` to a new .reg file in the game folder, imports it, and
/// removes the file. regedit's exit code, or `None` when it couldn't run.
pub fn import_text(prefix: &Prefix, game_dir: &Path, name: &str, text: &str) -> Option<i32> {
    import(prefix, game_dir, name, text)
}

fn import(prefix: &Prefix, game_dir: &Path, name: &str, text: &str) -> Option<i32> {
    let (path, mut f) = reg_file(game_dir, name)?;
    let ok = std::io::Write::write_all(&mut f, text.as_bytes()).is_ok();
    drop(f);
    let rc = if ok { prefix.regedit(&path) } else { None };
    let _ = std::fs::remove_file(&path);
    rc
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RegStatus {
    Ok,
    /// regedit failed, or there was nothing to run it with.
    Failed,
    /// regedit said it worked, but the override isn't in the prefix (a
    /// different Wine build than the prefix's own, say).
    Missing,
}

/// The override, read back from the prefix's user.reg once wineserver has
/// saved it. `None` when there's no user.reg to check, which says nothing
/// about the override itself.
pub fn verify_dll_override(prefix: &Prefix, dll: &str) -> Option<bool> {
    prefix.wait_for_wineserver();
    let store = prefix.path.join("user.reg");
    if !store.is_file() {
        return None;
    }
    Some(registry_has_value(
        &store,
        "Software\\\\Wine\\\\DllOverrides",
        &format!("\"{dll}\"=\"native,builtin\""),
    ))
}

/// The manifest lines for registry changes (`tag` is `\t<appid>` for a
/// companion app, else empty). They're recorded whether or not regedit
/// succeeds: a partial import can still leave keys behind, and removing a
/// key that was never set is harmless.
pub fn registry_lines(com: bool, override_dll: Option<&str>, tag: &str) -> Vec<String> {
    let mut out = Vec::new();
    if com {
        out.push(format!("REGISTRY:COM{tag}"));
    }
    if let Some(dll) = override_dll {
        out.push(format!("REGISTRY:OVERRIDE:{dll}{tag}"));
    }
    out
}

/// Writes COM routing and/or the DLL override into the prefix's registry.
/// The override is read back rather than trusting regedit's exit code: it's
/// the one change EAX can't work without.
pub fn apply_registry(
    prefix: &Prefix,
    game_dir: &Path,
    com: bool,
    override_dll: Option<&str>,
) -> RegStatus {
    let text = patch_text(com, override_dll);
    if import(prefix, game_dir, "master-patch", &text) != Some(0) {
        return RegStatus::Failed;
    }
    match override_dll {
        Some(dll) if verify_dll_override(prefix, dll) == Some(false) => RegStatus::Missing,
        _ => RegStatus::Ok,
    }
}

/// Takes COM routing and/or the override out of the prefix's registry.
pub fn remove_registry(prefix: &Prefix, game_dir: &Path, com: bool, dll: Option<&str>) -> bool {
    import(prefix, game_dir, "registry-clean", &removal_text(com, dll)) == Some(0)
}

/// The prefix's system folder for an architecture: a 32-bit game's DLLs go
/// in syswow64 on a 64-bit prefix.
pub fn system_dir(prefix: &Path, arch: u8) -> PathBuf {
    let wow = prefix.join("drive_c/windows/syswow64");
    if arch == 32 && wow.is_dir() {
        wow
    } else {
        prefix.join("drive_c/windows/system32")
    }
}

/// Copies each (source, name) into the prefix's system folder, backing up
/// a file already there, as for the game folder. The paths copied.
pub fn deploy_prefix_dlls(
    prefix: &Path,
    arch: u8,
    files: &[(PathBuf, String)],
    previous: &HashSet<Vec<u8>>,
    stamp: &str,
    manifest: &Path,
) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let dir = system_dir(prefix, arch);
    let (mut copied, mut failed) = (Vec::new(), Vec::new());
    for (src, name) in files {
        let dest = dir.join(name);
        let cleared = handle_conflict(&dest, previous, stamp);
        if cleared != Cleared::Failed && deploy_copy(src, &dest, manifest) {
            copied.push(dest);
        } else {
            failed.push(dest);
        }
    }
    (copied, failed)
}
