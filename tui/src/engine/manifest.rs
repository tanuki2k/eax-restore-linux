//! The install manifest: `.eax-restore-manifest.txt` in the game's exe
//! folder, plain text with one line per change an install made. A deployed
//! file's absolute path, `VCRUN`, `REGISTRY:…`, `EAXUNIFIED`, `LAUNCHER:…`
//! or `CONFIG:…` (tab-separated); a companion app's `VCRUN` / `REGISTRY:…`
//! lines end in a tab and its AppID. New manifests start with [`HEADER`];
//! every reader skips `#` lines. After an uninstall the whole file is the
//! "# EAX Restore: uninstalled …" marker.
//!
//! Uninstall deletes what a manifest lists, and a manifest sits in a folder
//! anyone can write to, so [`read`] is the guard: a file line is only acted
//! on when it is absolute, has no `..`, has one of the deployed names and is
//! inside the game's install or a Wine prefix's C: drive.
//!
//! Lines are bytes, not text: a path isn't always UTF-8.

use super::config::{Format, Value};
use super::files;
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

pub const FILE_NAME: &str = ".eax-restore-manifest.txt";
pub const HEADER: &str = "# EAX Restore manifest, format 2";
const UNINSTALLED: &[u8] = b"# EAX Restore: uninstalled";

pub fn path_in(game_dir: &Path) -> PathBuf {
    game_dir.join(FILE_NAME)
}

fn lines(data: &[u8]) -> impl Iterator<Item = &[u8]> {
    // As the shell's `read` loop: a last line without a newline still counts.
    data.strip_suffix(b"\n")
        .unwrap_or(data)
        .split(|&b| b == b'\n')
        .filter(move |_| !data.is_empty())
}

/// True when the manifest is the marker an uninstall leaves behind, not a
/// record of what an install changed.
pub fn is_uninstalled(manifest: &Path) -> bool {
    std::fs::read(manifest).is_ok_and(|data| {
        let first = data.split(|&b| b == b'\n').next().unwrap_or(b"");
        first.starts_with(UNINSTALLED)
    })
}

/// True when the game folder holds a record of an install that is still there.
pub fn is_live(manifest: &Path) -> bool {
    std::fs::metadata(manifest).is_ok_and(|m| m.len() > 0) && !is_uninstalled(manifest)
}

/// The marker line; `when` is the UTC time as `2026-11-13T10:00:00Z`.
pub fn uninstalled_marker(when: &str) -> String {
    format!("# EAX Restore: uninstalled on {when}. Nothing left to remove.\n")
}

// ---- CONFIG lines ----------------------------------------------------------

/// One game setting an install changed:
/// `CONFIG:<audio|optional>\t<title>\t<path>\t<format>\t<section>\t<key>\t<old>\t<new>`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigRecord {
    pub category: String,
    pub title: String,
    pub path: PathBuf,
    /// As written: a name this build doesn't know came from a newer one, and
    /// an empty one from a damaged line.
    pub format: String,
    pub section: String,
    pub key: String,
    /// The player's original value, `Absent` when the key wasn't there.
    pub old: Value,
    /// The value the install set.
    pub new: Value,
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

impl ConfigRecord {
    /// A missing field reads as empty, as it does in the script.
    pub fn parse(line: &[u8]) -> Option<Self> {
        let body = line.strip_prefix(b"CONFIG:")?;
        let mut f = body.split(|&b| b == b'\t');
        let mut next = || f.next().unwrap_or(b"");
        Some(ConfigRecord {
            category: text(next()),
            title: text(next()),
            path: PathBuf::from(OsStr::from_bytes(next())),
            format: text(next()),
            section: text(next()),
            key: text(next()),
            old: Value::from_bytes(next()),
            new: Value::from_bytes(next()),
        })
    }

    pub fn to_line(&self) -> Vec<u8> {
        let mut out = b"CONFIG:".to_vec();
        let fields: [&[u8]; 8] = [
            self.category.as_bytes(),
            self.title.as_bytes(),
            self.path.as_os_str().as_bytes(),
            self.format.as_bytes(),
            self.section.as_bytes(),
            self.key.as_bytes(),
            self.old.as_bytes(),
            self.new.as_bytes(),
        ];
        out.extend_from_slice(&fields.join(&b'\t'));
        out
    }

    /// The format, when this build can read it.
    pub fn known_format(&self) -> Option<Format> {
        self.format.parse().ok()
    }

    /// A format that is named but not one this build knows: the record can't
    /// be checked or put back, so it is kept in the manifest.
    pub fn format_unreadable(&self) -> bool {
        !self.format.is_empty() && self.known_format().is_none()
    }
}

/// The current name of a format: dev builds from before the formats were
/// renamed wrote the old names into the manifest. Delete this once no dev
/// install from before 0.29 is expected to still be around.
fn upgrade_format_name(name: &[u8]) -> &[u8] {
    match name {
        b"flat_ini" => b"ini",
        b"gas_cfg" => b"ini_braces",
        b"idtech_cfg" => b"set_commands",
        b"dark_cfg" | b"ltx" => b"key_value",
        b"brace_cfg" => b"braced_pairs",
        b"quoted_cfg" => b"quoted_pairs",
        b"byte_cfg" => b"binary_offset",
        b"lenstr_cfg" => b"binary_text",
        b"gadb" => b"binary_switches",
        b"wine_reg" => b"registry",
        other => other,
    }
}

/// A `CONFIG:` line with its format field in the current spelling; any other
/// line as it is. The lines kept and dropped by a revert are compared as
/// text, so both sides go through this.
pub fn upgrade_config_line(line: &[u8]) -> Vec<u8> {
    let mut fields: Vec<&[u8]> = line.split(|&b| b == b'\t').collect();
    if !line.starts_with(b"CONFIG:") || fields.len() < 4 {
        return line.to_vec();
    }
    fields[3] = upgrade_format_name(fields[3]);
    fields.join(&b'\t')
}

// ---- reading a manifest for an uninstall -----------------------------------

/// A Steam companion app's own prefix changes (DOOM 3's Resurrection of
/// Evil), recorded on lines tagged with its AppID.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Companion {
    pub app_id: String,
    pub vcrun: Option<Vcrun>,
    pub registry_com: bool,
    /// The DLL the registry override names: `dsound` or `openal32`.
    pub registry_override: Option<String>,
}

/// What an install did about the VC++ runtime in a prefix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vcrun {
    /// Installed it.
    Installed,
    /// Found it there already and only added the DLL overrides.
    OverridesOnly,
}

/// What a manifest says an install changed, sorted for an uninstall.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Recorded {
    /// Deployed files that are still there, in the manifest's order.
    pub files: Vec<PathBuf>,
    /// Lines with nothing left to act on (a file already gone, or a line
    /// refused below); dropped from the manifest so they can't keep it from
    /// ever reading as uninstalled.
    pub stale: Vec<Vec<u8>>,
    /// The refused lines among `stale`, for the "Skipped …" warning: not one
    /// of the files an install deploys, or outside the game and its prefix.
    pub refused: Vec<Vec<u8>>,
    pub registry_com: bool,
    pub registry_override: Option<String>,
    pub vcrun: bool,
    pub vcrun_overrides: bool,
    pub eax_unified: bool,
    /// `CONFIG:` lines, format names upgraded.
    pub config: Vec<Vec<u8>>,
    pub launcher: Vec<Vec<u8>>,
    pub companions: Vec<Companion>,
}

fn note_companion(companions: &mut Vec<Companion>, line: &[u8]) {
    let id = line.rsplit(|&b| b == b'\t').next().unwrap_or(b"");
    let what = line.split(|&b| b == b'\t').next().unwrap_or(b"");
    if id.is_empty() || !id.iter().all(u8::is_ascii_digit) {
        return;
    }
    if !matches!(
        what,
        b"VCRUN"
            | b"VCRUN:OVERRIDES"
            | b"REGISTRY:COM"
            | b"REGISTRY:OVERRIDE:dsound"
            | b"REGISTRY:OVERRIDE:openal32"
    ) {
        return;
    }
    let id = text(id);
    let at = companions
        .iter()
        .position(|c| c.app_id == id)
        .unwrap_or_else(|| {
            companions.push(Companion {
                app_id: id,
                vcrun: None,
                registry_com: false,
                registry_override: None,
            });
            companions.len() - 1
        });
    let c = &mut companions[at];
    match what {
        b"VCRUN" => c.vcrun = Some(Vcrun::Installed),
        b"VCRUN:OVERRIDES" => c.vcrun = Some(Vcrun::OverridesOnly),
        b"REGISTRY:COM" => c.registry_com = true,
        other => c.registry_override = Some(text(&other[b"REGISTRY:OVERRIDE:".len()..])),
    }
}

/// Reads a manifest's bytes. `install_root` is the game's install root
/// (`game_install_root`), not just the exe folder: a profile's extra exe
/// folders sit beside it.
pub fn read(data: &[u8], install_root: &Path) -> Recorded {
    let root = install_root.as_os_str().as_bytes();
    let mut r = Recorded::default();
    let mut seen: HashSet<&[u8]> = HashSet::new();
    for line in lines(data) {
        if line.is_empty() || line.starts_with(b"#") {
            continue;
        }
        let tagged = line.contains(&b'\t');
        if tagged
            && (line.starts_with(b"VCRUN\t")
                || line.starts_with(b"VCRUN:OVERRIDES\t")
                || line.starts_with(b"REGISTRY:"))
        {
            note_companion(&mut r.companions, line);
            continue;
        }
        match line {
            b"REGISTRY:COM" => r.registry_com = true,
            // The bare form is from before the DLL name was appended, when
            // dsound was the only possible override.
            b"REGISTRY:OVERRIDE" | b"REGISTRY:OVERRIDE:dsound" => {
                r.registry_override = Some("dsound".into());
            }
            b"REGISTRY:OVERRIDE:openal32" => r.registry_override = Some("openal32".into()),
            b"VCRUN" => r.vcrun = true,
            b"VCRUN:OVERRIDES" => r.vcrun_overrides = true,
            b"EAXUNIFIED" => r.eax_unified = true,
            _ if line.starts_with(b"CONFIG:") => r.config.push(upgrade_config_line(line)),
            _ if line.starts_with(b"LAUNCHER:") => r.launcher.push(line.to_vec()),
            _ => {
                let entry = line.strip_suffix(b"\r").unwrap_or(line);
                let path = Path::new(OsStr::from_bytes(entry));
                // 0.28.x also recorded the folder it copied the HRTF profiles
                // to; it's taken back whole, but only a real folder.
                let legacy_dir = files::is_legacy_hrtf_dir(entry)
                    && !path.is_symlink()
                    && (path.is_dir() || !path.exists());
                let dotdot = [b"/", entry, b"/"].concat();
                let dotdot = dotdot.windows(4).any(|w| w == b"/../");
                if !entry.starts_with(b"/")
                    || dotdot
                    || !(legacy_dir || files::file_is_ours(path))
                    || !files::path_in_scope(entry, root)
                {
                    r.refused.push(entry.to_vec());
                    r.stale.push(entry.to_vec());
                } else if seen.insert(entry) {
                    if path.symlink_metadata().is_ok() {
                        r.files.push(path.to_path_buf());
                    } else {
                        r.stale.push(entry.to_vec());
                    }
                }
            }
        }
    }
    r
}

// ---- writing ---------------------------------------------------------------

fn replace(manifest: &Path, data: &[u8]) -> Result<()> {
    // The same temp name the script uses, so a run cut short by either
    // leaves the same thing behind.
    let mut tmp = manifest.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    let done = std::fs::write(&tmp, data).and_then(|()| std::fs::rename(&tmp, manifest));
    if done.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    done.with_context(|| format!("can't write {}", manifest.display()))
}

fn joined<'a>(kept: impl Iterator<Item = &'a [u8]>) -> Vec<u8> {
    let mut out = Vec::new();
    for line in kept {
        out.extend_from_slice(line);
        out.push(b'\n');
    }
    out
}

/// Starts a new manifest with the format header. With `keep_previous` the
/// old one is set aside first as `<manifest>.prev` (returned): an install
/// carries its records over only near the end, so a run that is cut short
/// can merge them back instead of losing them.
pub fn start(manifest: &Path, keep_previous: bool) -> Result<Option<PathBuf>> {
    let mut prev = None;
    if keep_previous && is_live(manifest) {
        let mut name = manifest.as_os_str().to_owned();
        name.push(".prev");
        let path = PathBuf::from(name);
        if std::fs::copy(manifest, &path).is_ok() {
            prev = Some(path);
        }
    }
    std::fs::write(manifest, format!("{HEADER}\n"))
        .with_context(|| format!("can't write {}", manifest.display()))?;
    Ok(prev)
}

pub fn append(manifest: &Path, line: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(manifest)
        .with_context(|| format!("can't write {}", manifest.display()))?;
    file.write_all(&[line, b"\n"].concat())
        .with_context(|| format!("can't write {}", manifest.display()))
}

/// Drops repeated lines, keeping the first of each: a reinstall carries the
/// last install's records over, and some are then written again.
pub fn dedupe(manifest: &Path) -> Result<()> {
    let Ok(data) = std::fs::read(manifest) else {
        return Ok(());
    };
    let mut seen = HashSet::new();
    let out = joined(lines(&data).filter(|l| seen.insert(*l)));
    replace(manifest, &out)
}

/// Drops exactly these lines, for what an uninstall has dealt with.
pub fn forget(manifest: &Path, gone: &[Vec<u8>]) -> Result<()> {
    if gone.is_empty() {
        return Ok(());
    }
    let Ok(data) = std::fs::read(manifest) else {
        return Ok(());
    };
    let gone: HashSet<&[u8]> = gone.iter().flat_map(|g| g.split(|&b| b == b'\n')).collect();
    let out = joined(lines(&data).filter(|l| !gone.contains(l)));
    replace(manifest, &out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch(path: &Path) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, b"x").unwrap();
    }

    fn s(path: &Path) -> String {
        path.display().to_string()
    }

    #[test]
    fn config_records_round_trip() {
        let line = b"CONFIG:audio\tEnable EAX\t/g/a.ini\tini\tAudio\tUseEAX\t__ABSENT__\t1";
        let r = ConfigRecord::parse(line).unwrap();
        assert_eq!(r.title, "Enable EAX");
        assert_eq!(r.path, Path::new("/g/a.ini"));
        assert_eq!(r.known_format(), Some(Format::Ini));
        assert_eq!(r.old, Value::Absent);
        assert_eq!(r.new, Value::text("1"));
        assert_eq!(r.to_line(), line);
        // An empty value at the end of the line is still a value.
        let r = ConfigRecord::parse(b"CONFIG:audio\tT\t/g/a\tini\t\tk\told\t").unwrap();
        assert_eq!(r.section, "");
        assert_eq!(r.new, Value::text(""));
        assert!(ConfigRecord::parse(b"LAUNCHER:steam").is_none());
    }

    #[test]
    fn a_format_from_a_newer_build_is_unreadable_and_a_missing_one_is_damage() {
        let newer = ConfigRecord::parse(b"CONFIG:a\tT\t/g/a\ttoml\ts\tk\t0\t1").unwrap();
        assert!(newer.format_unreadable());
        let damaged = ConfigRecord::parse(b"CONFIG:a\tT").unwrap();
        assert!(!damaged.format_unreadable());
        assert!(damaged.known_format().is_none());
    }

    #[test]
    fn old_format_names_are_upgraded_in_config_lines_only() {
        assert_eq!(
            upgrade_config_line(b"CONFIG:a\tT\t/g/a\tgadb\t\tk\t0\t1"),
            b"CONFIG:a\tT\t/g/a\tbinary_switches\t\tk\t0\t1"
        );
        let launcher = b"LAUNCHER:a\tb\tc\tgadb\te";
        assert_eq!(upgrade_config_line(launcher), launcher);
        assert_eq!(upgrade_config_line(b"CONFIG:a\tT"), b"CONFIG:a\tT");
    }

    #[test]
    fn read_sorts_every_kind_of_line() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("lib/Game");
        let pfx = tmp.path().join("pfx/drive_c/windows/system32");
        touch(&game.join("dsound.dll"));
        touch(&game.join("alsoft.ini"));
        touch(&pfx.join("OpenAL32.dll"));
        let text = format!(
            "{HEADER}\n{g}/dsound.dll\n{g}/dsound.dll\n{g}/dsoal-aldrv.dll\n{p}/OpenAL32.dll\r\n\n\
             {g}/alsoft.ini\nVCRUN\nVCRUN:OVERRIDES\nEAXUNIFIED\nREGISTRY:COM\nREGISTRY:OVERRIDE:openal32\n\
             VCRUN\t9070\nREGISTRY:COM\t9070\nREGISTRY:OVERRIDE:dsound\t9070\nVCRUN:OVERRIDES\t9071\n\
             REGISTRY:COM\tnot-an-id\nREGISTRY:BOGUS\t9072\n\
             CONFIG:audio\tT\t{g}/a.cfg\tdark_cfg\t\tk\t__ABSENT__\t__TRUE__\nLAUNCHER:steam\tf\t1\ta\tb",
            g = s(&game),
            p = s(&pfx)
        );
        let r = read(text.as_bytes(), &game);
        assert_eq!(
            r.files,
            vec![
                game.join("dsound.dll"),
                pfx.join("OpenAL32.dll"),
                game.join("alsoft.ini")
            ]
        );
        // Already gone: dropped, but nothing to warn about.
        assert_eq!(
            r.stale,
            vec![format!("{}/dsoal-aldrv.dll", s(&game)).into_bytes()]
        );
        assert!(r.refused.is_empty());
        assert!(r.vcrun && r.vcrun_overrides && r.eax_unified && r.registry_com);
        assert_eq!(r.registry_override.as_deref(), Some("openal32"));
        assert_eq!(
            r.companions,
            vec![
                Companion {
                    app_id: "9070".into(),
                    vcrun: Some(Vcrun::Installed),
                    registry_com: true,
                    registry_override: Some("dsound".into()),
                },
                Companion {
                    app_id: "9071".into(),
                    vcrun: Some(Vcrun::OverridesOnly),
                    registry_com: false,
                    registry_override: None,
                },
            ]
        );
        assert_eq!(r.config.len(), 1);
        assert!(r.config[0].windows(9).any(|w| w == b"key_value"));
        assert_eq!(r.launcher, vec![b"LAUNCHER:steam\tf\t1\ta\tb".to_vec()]);
    }

    /// The cases tests/integration/roundtrip.bats forges, and their relatives.
    #[test]
    fn read_refuses_what_an_install_never_deploys() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("lib/Game");
        let other = tmp.path().join("lib/OtherGame");
        let precious = tmp.path().join("precious");
        touch(&game.join("dsound.dll"));
        touch(&game.join("game.exe"));
        touch(&other.join("dsound.dll"));
        touch(&precious.join("note.txt"));
        touch(&tmp.path().join("lib/Game2/dsound.dll"));
        let forged = [
            // A folder of the player's own.
            s(&precious),
            // A script-named file in another game.
            s(&other.join("dsound.dll")),
            // The game's own file.
            s(&game.join("game.exe")),
            // Out of the game folder by way of "..".
            format!("{}/../OtherGame/dsound.dll", s(&game)),
            // A folder whose name only starts like the game's.
            s(&tmp.path().join("lib/Game2/dsound.dll")),
            // Not absolute.
            "dsound.dll".to_string(),
            "REGISTRY:SOMETHING".to_string(),
        ];
        let text = format!("{}\n{}\n", s(&game.join("dsound.dll")), forged.join("\n"));
        let r = read(text.as_bytes(), &game);
        assert_eq!(r.files, vec![game.join("dsound.dll")]);
        let refused: Vec<String> = r.refused.iter().map(|l| text_of(l)).collect();
        assert_eq!(refused, forged);
        assert_eq!(r.stale, r.refused);
    }

    fn text_of(line: &[u8]) -> String {
        String::from_utf8_lossy(line).into_owned()
    }

    #[test]
    fn the_legacy_hrtf_folder_counts_only_as_a_real_folder_in_the_game() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("Game");
        std::fs::create_dir_all(game.join("OpenAL/HRTF")).unwrap();
        let elsewhere = tmp.path().join("Else/OpenAL");
        std::fs::create_dir_all(&elsewhere).unwrap();
        // A file, and a link, with the folder's name.
        touch(&game.join("sub/OpenAL"));
        std::fs::create_dir_all(game.join("link")).unwrap();
        std::os::unix::fs::symlink(&elsewhere, game.join("link/OpenAL")).unwrap();
        let text = format!(
            "{g}/OpenAL\n{g}/OpenAL/HRTF\n{e}\n{g}/sub/OpenAL\n{g}/link/OpenAL\n{g}/gone/OpenAL\n",
            g = s(&game),
            e = s(&elsewhere)
        );
        let r = read(text.as_bytes(), &game);
        assert_eq!(r.files, vec![game.join("OpenAL"), game.join("OpenAL/HRTF")]);
        assert_eq!(r.refused.len(), 3);
        // Recorded, in scope, and no longer there.
        assert_eq!(r.stale.len(), 4);
    }

    #[test]
    fn start_sets_the_old_manifest_aside_only_when_asked_and_live() {
        let tmp = tempfile::tempdir().unwrap();
        let m = tmp.path().join(FILE_NAME);
        assert_eq!(start(&m, true).unwrap(), None);
        assert_eq!(std::fs::read_to_string(&m).unwrap(), format!("{HEADER}\n"));
        append(&m, b"/g/dsound.dll").unwrap();
        assert!(is_live(&m));
        assert_eq!(start(&m, false).unwrap(), None);
        append(&m, b"VCRUN").unwrap();
        let prev = start(&m, true).unwrap().unwrap();
        assert_eq!(
            std::fs::read_to_string(prev).unwrap(),
            format!("{HEADER}\nVCRUN\n")
        );
        std::fs::write(&m, uninstalled_marker("2026-11-13T00:00:00Z")).unwrap();
        assert!(is_uninstalled(&m) && !is_live(&m));
        assert_eq!(start(&m, true).unwrap(), None);
    }
}
