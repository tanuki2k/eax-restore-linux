//! Creative's EAX Unified in a game's prefix, for games whose profile asks
//! for it (`install.tweaks: ["eax_unified"]`): its installer puts eax.dll in
//! the system folder and registers the COM object those games ask Windows
//! for. Ports of `eax_unified_dll`, `game_ships_eax_dll`,
//! `ensure_eax_unified_installer`, `install_eax_unified` and
//! `uninstall_eax_unified` in `src/prefix-steps.sh`.

use super::builds::{sha256_of, Net};
use super::files::{find_existing_variant, is_genuine_dll};
use super::wine::Prefix;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

/// The installer, kept in this project's own repository, and its checksums.
#[derive(Debug, Clone)]
pub struct Installer {
    pub zip_url: String,
    pub zip_sha256: String,
    /// The exe's name inside the zip.
    pub exe: String,
    pub exe_sha256: String,
    /// Windows Installer's product code, for removing it.
    pub product_code: String,
}

impl Installer {
    /// The script's `EAX_UNIFIED_*` in `src/globals.sh`, for the data branch
    /// this build reads (`main` or `dev`).
    pub fn for_branch(branch: &str) -> Self {
        Installer {
            zip_url: format!(
                "https://raw.githubusercontent.com/tanuki2k/eax-restore-linux/{branch}/assets/EAX4Unified_redist_4001.zip"
            ),
            zip_sha256: "2502b6ffebb360549a049baf345048323ee3ddef9983ac2e9f91f9eef5d660d9".into(),
            exe: "EAX4Unified_redist_4001.exe".into(),
            exe_sha256: "c10e904a6f9869009307f5ca6484c9a0cebb90698e6cc404d7901353f25ff484".into(),
            product_code: "{89661B04-C646-4412-B6D3-5E19F02F1F37}".into(),
        }
    }
}

/// The eax.dll EAX Unified left in the prefix's system folder (the 32-bit
/// one is in syswow64 on a 64-bit prefix). Wine's placeholder doesn't count.
pub fn installed_dll(prefix: &Path) -> Option<PathBuf> {
    ["syswow64", "system32"].iter().find_map(|d| {
        let f = prefix.join("drive_c/windows").join(d).join("eax.dll");
        let ours = is_genuine_dll(&f)
            && std::fs::read(&f).is_ok_and(|b| b.windows(11).any(|w| w == b"EAX Unified"));
        ours.then_some(f)
    })
}

/// The game folder already has a real eax.dll or eaxunified.dll, so the
/// game loads its own (an empty file from the old dummy tweak doesn't count).
pub fn game_ships_eax_dll(game_dir: &Path) -> bool {
    ["eax.dll", "eaxunified.dll"]
        .iter()
        .any(|n| find_existing_variant(&game_dir.join(n)).is_some_and(|f| is_genuine_dll(&f)))
}

/// Puts the installer in `cache`: reused while its checksum still matches,
/// otherwise unpacked from the checksum-verified zip. Nothing is kept on a
/// failed download.
pub fn ensure_installer(cache: &Path, inst: &Installer, net: &mut dyn Net) -> Option<PathBuf> {
    let _ = std::fs::create_dir_all(cache);
    let exe = cache.join(&inst.exe);
    if sha256_of(&exe).is_some_and(|s| s == inst.exe_sha256)
        && std::fs::metadata(&exe).is_ok_and(|m| m.len() > 0)
    {
        return Some(exe);
    }
    let zip = cache.join("installer.zip");
    let mut part = exe.as_os_str().to_owned();
    part.push(".part");
    let part = PathBuf::from(part);
    let ok = net.download(&inst.zip_url, &zip)
        && sha256_of(&zip).is_some_and(|s| s == inst.zip_sha256)
        && Command::new("unzip")
            .arg("-p")
            .arg(&zip)
            .arg(&inst.exe)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .is_some_and(|o| std::fs::write(&part, o.stdout).is_ok())
        && sha256_of(&part).is_some_and(|s| s == inst.exe_sha256)
        && std::fs::rename(&part, &exe).is_ok();
    let _ = std::fs::remove_file(&zip);
    if ok {
        Some(exe)
    } else {
        let _ = std::fs::remove_file(&part);
        let _ = std::fs::remove_file(&exe);
        None
    }
}

/// Waits up to ten seconds for `done`: the installer can return before the
/// prefix's files and registry are written out.
fn wait_for(mut done: impl FnMut() -> bool, poll: Duration) -> bool {
    for _ in 0..10 {
        if done() {
            return true;
        }
        std::thread::sleep(poll);
    }
    done()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Installed,
    /// The prefix already had it, so the manifest mustn't claim it.
    AlreadyThere,
    NoInstaller,
    Failed,
}

/// Runs the installer silently in the prefix.
pub fn install(
    prefix: &Prefix,
    cache: &Path,
    inst: &Installer,
    net: &mut dyn Net,
    poll: Duration,
) -> Outcome {
    if installed_dll(&prefix.path).is_some() {
        return Outcome::AlreadyThere;
    }
    let Some(exe) = ensure_installer(cache, inst, net) else {
        return Outcome::NoInstaller;
    };
    prefix.run_program(&[exe.display().to_string(), "/s".into(), "/v/qn".into()]);
    if wait_for(|| installed_dll(&prefix.path).is_some(), poll) {
        Outcome::Installed
    } else {
        Outcome::Failed
    }
}

/// Removes it through Windows Installer, so the file and its COM
/// registration go together. True once it's gone (or was already).
pub fn uninstall(prefix: &Prefix, inst: &Installer, poll: Duration) -> bool {
    if prefix.path.as_os_str().is_empty() || installed_dll(&prefix.path).is_none() {
        return true;
    }
    prefix.run_program(&[
        "msiexec".into(),
        "/x".into(),
        inst.product_code.clone(),
        "/qn".into(),
    ]);
    wait_for(|| installed_dll(&prefix.path).is_none(), poll)
}
