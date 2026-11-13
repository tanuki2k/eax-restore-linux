//! Microsoft's VC++ 2015-2022 runtime in a game's prefix, which DSOAL and
//! OpenAL Soft need. Ports of `src/vcrun.sh`. Wine puts a same-named
//! placeholder of every one of these DLLs in each prefix, so a file being
//! there proves nothing: only a genuine DLL counts (`is_genuine_dll`).

use super::builds::Net;
use super::files::is_genuine_dll;
use super::prefix::system_dir;
use super::wine::Prefix;
use std::path::{Path, PathBuf};

/// Every DLL the runtime installs and the install sets an override for.
pub const DLL_NAMES: [&str; 11] = [
    "concrt140",
    "msvcp140",
    "msvcp140_1",
    "msvcp140_2",
    "msvcp140_atomic_wait",
    "msvcp140_codecvt_ids",
    "vcamp140",
    "vccorlib140",
    "vcomp140",
    "vcruntime140",
    "vcruntime140_1",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileState {
    /// Microsoft's own.
    Genuine,
    /// Wine's placeholder.
    Wine,
    Missing,
}

/// One DLL's state; `optional` ones are reported but not needed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileRow {
    pub name: &'static str,
    pub state: FileState,
    pub optional: bool,
}

/// The runtime's DLLs in the folder an architecture's game loads them from.
/// `None` when the prefix has no such folder. The second value is whether
/// the core files (what DSOAL and OpenAL Soft need) are genuine.
pub fn verify_files(prefix: &Path, arch: u8) -> Option<(Vec<FileRow>, bool)> {
    let dir = system_dir(prefix, arch);
    if !dir.is_dir() {
        return None;
    }
    let state = |name: &str| {
        let f = dir.join(name);
        if is_genuine_dll(&f) {
            FileState::Genuine
        } else if std::fs::metadata(&f).is_ok_and(|m| m.len() > 0) {
            FileState::Wine
        } else {
            FileState::Missing
        }
    };
    let mut extra = vec!["vcomp140.dll", "concrt140.dll"];
    if arch == 64 {
        extra.push("vcruntime140_1.dll");
    }
    let mut rows = Vec::new();
    let mut core_ok = true;
    for name in ["vcruntime140.dll", "msvcp140.dll"] {
        let s = state(name);
        core_ok &= s == FileState::Genuine;
        rows.push(FileRow {
            name,
            state: s,
            optional: false,
        });
    }
    for name in extra {
        rows.push(FileRow {
            name,
            state: state(name),
            optional: true,
        });
    }
    Some((rows, core_ok))
}

fn core_ok(prefix: &Path, arch: u8) -> bool {
    verify_files(prefix, arch).is_some_and(|(_, ok)| ok)
}

/// The .reg text telling Wine to load Microsoft's files rather than its
/// own (`set`), or to stop doing so.
pub fn overrides_text(set: bool) -> String {
    let mut out = String::from(
        "Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n",
    );
    for dll in DLL_NAMES {
        if set {
            out.push_str(&format!("\"{dll}\"=\"native,builtin\"\n"));
        } else {
            out.push_str(&format!("\"{dll}\"=-\n"));
        }
    }
    out
}

/// Sets (or removes) the VC++ DLL overrides. Needed whichever way the
/// runtime got in: winetricks' verb sets them itself, but Microsoft's
/// installer only places the files, and a game then crashes on Wine's
/// unimplemented functions despite every file being there.
pub fn set_overrides(prefix: &Prefix, game_dir: &Path, set: bool) -> bool {
    let name = if set {
        "vcrun-overrides"
    } else {
        "vcrun-overrides-clean"
    };
    super::prefix::import_text(prefix, game_dir, name, &overrides_text(set)) == Some(0)
}

/// Microsoft's installer name and link for an architecture.
pub fn installer(arch: u8) -> (&'static str, &'static str) {
    if arch == 64 {
        (
            "vc_redist.x64.exe",
            "https://aka.ms/vs/17/release/vc_redist.x64.exe",
        )
    } else {
        (
            "vc_redist.x86.exe",
            "https://aka.ms/vs/17/release/vc_redist.x86.exe",
        )
    }
}

/// Downloads Microsoft's installer to a `.part` file and keeps it only when
/// the download worked and it starts like a Windows program ("MZ"), since
/// Microsoft publishes no fixed checksum for this "latest" link.
pub fn fetch_installer(net: &mut dyn Net, url: &str, dest: &Path) -> bool {
    let mut part = dest.as_os_str().to_owned();
    part.push(".part");
    let part = PathBuf::from(part);
    let ok = net.download(url, &part)
        && std::fs::read(&part).is_ok_and(|d| d.starts_with(b"MZ"))
        && std::fs::rename(&part, dest).is_ok();
    if !ok {
        let _ = std::fs::remove_file(&part);
    }
    ok
}

fn non_empty(p: &Path) -> bool {
    std::fs::metadata(p).is_ok_and(|m| m.len() > 0)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Installed {
    /// protontricks or winetricks put the core files in.
    ByPackageManager,
    /// Microsoft's installer did (or repaired them, when it was already
    /// registered but a prefix update had swapped a file for Wine's).
    ByMicrosoft { repaired: bool },
    /// Microsoft's installer couldn't be downloaded.
    NoInstaller,
    /// Both ran, and the core files still aren't genuine.
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstallReport {
    pub result: Installed,
    /// The DLL overrides were set (only tried once the runtime is in).
    pub overrides_set: bool,
}

impl InstallReport {
    pub fn ok(&self) -> bool {
        matches!(
            self.result,
            Installed::ByPackageManager | Installed::ByMicrosoft { .. }
        )
    }
}

/// Installs the runtime: the package manager first, checked by the files
/// rather than its exit code, then Microsoft's installer. `cache` is where
/// Microsoft's installers are kept (`…/eax-restore-linux/vcrun2022`).
pub fn install(
    prefix: &Prefix,
    game_dir: &Path,
    arch: u8,
    cache: &Path,
    net: &mut dyn Net,
) -> InstallReport {
    let _ = std::fs::create_dir_all(cache);
    prefix.install_verb("vcrun2022");
    let done = |result| InstallReport {
        result,
        overrides_set: set_overrides(prefix, game_dir, true),
    };
    if core_ok(&prefix.path, arch) {
        return done(Installed::ByPackageManager);
    }
    let (name, url) = installer(arch);
    let exe = cache.join(name);
    if !non_empty(&exe) {
        fetch_installer(net, url, &exe);
    }
    if !non_empty(&exe) {
        return InstallReport {
            result: Installed::NoInstaller,
            overrides_set: false,
        };
    }
    // Already registered: a plain install sees "already installed" and
    // copies nothing, so it's asked to repair instead.
    let label = format!(
        "\"DisplayName\"=\"Microsoft Visual C++ 2022 {} Minimum Runtime",
        if arch == 64 { "X64" } else { "X86" }
    );
    let repaired = std::fs::read(prefix.path.join("system.reg"))
        .is_ok_and(|d| d.windows(label.len()).any(|w| w == label.as_bytes()));
    let flags: &[&str] = if repaired {
        &["/repair", "/quiet"]
    } else {
        &["/q"]
    };
    prefix.run_vc_installer(&exe, flags);
    if core_ok(&prefix.path, arch) {
        done(Installed::ByMicrosoft { repaired })
    } else {
        InstallReport {
            result: Installed::Failed,
            overrides_set: false,
        }
    }
}

const UNINSTALL_HIVES: [&str; 2] = [
    "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
    "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
];

fn is_runtime_name(line: &str) -> bool {
    ["2015", "2017", "2019", "2022", "v14"]
        .iter()
        .any(|y| line.contains(&format!("Visual C++ {y}")))
}

/// A key name safe to hand to a shell: a plain registry path.
fn plain_key(key: &str) -> bool {
    let Some(rest) = key.strip_prefix("HKEY_LOCAL_MACHINE") else {
        return false;
    };
    !rest.is_empty()
        && rest.split('\\').skip(1).all(|part| {
            !part.is_empty()
                && part
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_{}.() +-".contains(c))
        })
        && rest.starts_with('\\')
}

/// The 2015-2022 runtime's "Programs and Features" keys in a `reg query /s`
/// listing: a key line, then the values that matched under it. Older
/// redistributables may belong to other software in the prefix.
pub fn runtime_keys(listing: &str) -> Vec<String> {
    let mut keys = Vec::new();
    let mut current: Option<String> = None;
    for line in listing.lines() {
        let line = line.strip_suffix('\r').unwrap_or(line);
        if line.starts_with("HKEY_LOCAL_MACHINE") {
            current = Some(line.to_string());
        } else if let Some(key) = &current {
            if line.contains("DisplayName") && is_runtime_name(line) && plain_key(key) {
                keys.push(key.clone());
                current = None;
            }
        }
    }
    keys
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct UninstallReport {
    /// Nothing genuine was there.
    pub nothing: bool,
    pub removed: Vec<PathBuf>,
    pub registrations_removed: usize,
    /// Core files still there afterwards ("system32/msvcp140.dll").
    pub left: Vec<String>,
}

/// Removes the runtime: Microsoft's own uninstaller first (it also cleans
/// up files this list doesn't know), but never trusted alone, since Wine's
/// installer engine can report success without doing anything. Then the
/// genuine DLLs themselves, the "Programs and Features" registration (which
/// would make a later install think it's still there), and the overrides.
/// Every folder with a genuine runtime is handled, each with its own
/// architecture's uninstaller.
pub fn uninstall(
    prefix: &Prefix,
    game_dir: &Path,
    cache: &Path,
    net: &mut dyn Net,
) -> UninstallReport {
    let mut r = UninstallReport::default();
    let win = prefix.path.join("drive_c/windows");
    if prefix.path.as_os_str().is_empty() || !win.is_dir() {
        r.nothing = true;
        return r;
    }
    // winetricks' verb installs both runtimes: on a 64-bit prefix system32
    // holds the 64-bit copy and syswow64 the 32-bit one.
    let folders: Vec<(PathBuf, &str)> = if win.join("syswow64").is_dir() {
        vec![(win.join("system32"), "x64"), (win.join("syswow64"), "x86")]
    } else {
        vec![(win.join("system32"), "x86")]
    };
    let present: Vec<&(PathBuf, &str)> = folders
        .iter()
        .filter(|(d, _)| {
            is_genuine_dll(&d.join("vcruntime140.dll")) || is_genuine_dll(&d.join("msvcp140.dll"))
        })
        .collect();
    if present.is_empty() {
        r.nothing = true;
        return r;
    }
    let _ = std::fs::create_dir_all(cache);
    for (dir, arch) in present {
        let name = format!("vc_redist.{arch}.exe");
        let exe = cache.join(&name);
        if !non_empty(&exe) {
            fetch_installer(net, &format!("https://aka.ms/vs/17/release/{name}"), &exe);
        }
        if non_empty(&exe) {
            prefix.run_vc_installer(&exe, &["/uninstall", "/q"]);
        }
        for dll in DLL_NAMES {
            let f = dir.join(format!("{dll}.dll"));
            if is_genuine_dll(&f) && std::fs::remove_file(&f).is_ok() {
                r.removed.push(f);
            }
        }
    }
    for hive in UNINSTALL_HIVES {
        let Some(listing) = prefix.reg_query_visual_cpp(hive) else {
            continue;
        };
        for key in runtime_keys(&listing) {
            prefix.reg_delete(&key);
            r.registrations_removed += 1;
        }
    }
    set_overrides(prefix, game_dir, false);
    for (dir, _) in &folders {
        for dll in ["vcruntime140", "msvcp140"] {
            if is_genuine_dll(&dir.join(format!("{dll}.dll"))) {
                let folder = dir.file_name().unwrap_or_default().to_string_lossy();
                r.left.push(format!("{folder}/{dll}.dll"));
            }
        }
    }
    r
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn programs_and_features_keys() {
        let listing = "\r\nHKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{A1}\r\n    DisplayName    REG_SZ    Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.40\r\n\
HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{B2}\r\n    DisplayName    REG_SZ    Microsoft Visual C++ 2010 x86 Redistributable\r\n\
HKEY_LOCAL_MACHINE\\Software\\Odd\\Key;rm -rf\r\n    DisplayName    REG_SZ    Microsoft Visual C++ 2019 X64\r\n";
        assert_eq!(
            runtime_keys(listing),
            vec![
                "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{A1}"
                    .to_string()
            ]
        );
    }
}
