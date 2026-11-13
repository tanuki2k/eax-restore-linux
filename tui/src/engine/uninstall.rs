//! Taking the audio fix out of a game: what an install left (from its
//! manifest, or a scan when there's none), the player's choices, and doing
//! it. A port of `src/uninstall-flow.sh` without its questions: [`survey`]
//! is Phase 1's findings, [`Choices`] its answers, [`execute`] Phase 2.
//!
//! Only files the manifest lists, that pass `manifest::read`'s guard, are
//! ever deleted. The Wine side (registry keys, the VC++ runtime, EAX
//! Unified, a companion app's prefix) and closing a launcher go through an
//! [`UninstallHost`] the caller supplies.

use super::apply::{recorded_settings, Host, RevertGroup};
use super::config::{revert, Reverted};
use super::files;
use super::launcher::changes::{self, LauncherRecord};
use super::launcher::target::{Launcher, Target};
use super::manifest::{self, Companion, ConfigRecord, Recorded};
use std::collections::HashSet;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// The file names an install deploys, for the scan when there's no manifest.
const GAME_FILES: [&str; 6] = [
    "dsound.dll",
    "dsoal-aldrv.dll",
    "OpenAL32.dll",
    "eax.dll",
    "eaxunified.dll",
    "alsoft.ini",
];
const PREFIX_FILES: [&str; 3] = ["dsound.dll", "dsoal-aldrv.dll", "OpenAL32.dll"];

/// One file to take out, and the original to put back in its place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Removal {
    pub path: PathBuf,
    /// The oldest timestamped backup: the one most likely to be the
    /// player's own original.
    pub backup: Option<PathBuf>,
}

/// Where the game is.
pub struct Location<'a> {
    pub game_dir: &'a Path,
    /// For the manifest's scope check: a profile's extra exe folders sit
    /// beside the exe folder.
    pub install_root: &'a Path,
    pub prefix: Option<&'a Path>,
    /// Extra exe folders that exist, for the scan when there's no manifest.
    pub extra_dirs: &'a [PathBuf],
    /// Every game folder with a live install, to see who else uses the prefix.
    pub installed_dirs: &'a [PathBuf],
    /// A Steam AppID is known for the game.
    pub has_app_id: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Survey {
    pub manifest: PathBuf,
    pub manifest_found: bool,
    pub recorded: Recorded,
    pub files: Vec<Removal>,
    /// Other games installed into the same prefix: the prefix's files and
    /// registry keys stay until the last of them is uninstalled.
    pub shared_with: Vec<PathBuf>,
    /// The VC++ runtime is in the prefix (recorded, or found there).
    pub vcrun_present: bool,
    pub settings: Vec<RevertGroup>,
    prefix: Option<PathBuf>,
    has_app_id: bool,
}

pub enum Surveyed {
    /// The manifest is the marker an earlier uninstall left.
    AlreadyUninstalled,
    /// Nothing from the audio fix is there.
    Nothing,
    Found(Box<Survey>),
}

fn has_genuine_vcrun(prefix: &Path) -> bool {
    ["system32", "syswow64"].iter().any(|d| {
        files::is_genuine_dll(
            &prefix
                .join("drive_c/windows")
                .join(d)
                .join("vcruntime140.dll"),
        )
    })
}

/// Phase 1: what the install left, as it is now. Changes nothing.
pub fn survey(at: &Location) -> Surveyed {
    let manifest_path = manifest::path_in(at.game_dir);
    let data = std::fs::read(&manifest_path).unwrap_or_default();
    if !data.is_empty() && manifest::is_uninstalled(&manifest_path) {
        return Surveyed::AlreadyUninstalled;
    }
    let manifest_found = !data.is_empty();
    let (recorded, mut paths) = if manifest_found {
        let r = manifest::read(&data, at.install_root);
        let files = r.files.clone();
        (r, files)
    } else {
        // No manifest (an install from before them, or it was deleted): only
        // files whose content is what an install puts there.
        let mut found = Vec::new();
        for dir in std::iter::once(&at.game_dir.to_path_buf()).chain(at.extra_dirs) {
            for name in GAME_FILES {
                let p = dir.join(name);
                if files::looks_like_our_file(&p) {
                    found.push(p);
                }
            }
        }
        if let Some(pfx) = at.prefix.filter(|p| p.join("drive_c/windows").is_dir()) {
            for name in PREFIX_FILES {
                for sub in ["syswow64", "system32"] {
                    let p = pfx.join("drive_c/windows").join(sub).join(name);
                    if files::looks_like_our_file(&p) {
                        found.push(p);
                    }
                }
            }
        }
        (Recorded::default(), found)
    };

    let vcrun_present =
        recorded.vcrun || recorded.vcrun_overrides || at.prefix.is_some_and(has_genuine_vcrun);

    let mut shared_with = Vec::new();
    if let Some(pfx) = at.prefix {
        let touches_prefix =
            !paths.is_empty() || recorded.registry_com || recorded.registry_override.is_some();
        if touches_prefix {
            let needle = [pfx.as_os_str().as_bytes(), b"/"].concat();
            shared_with = at
                .installed_dirs
                .iter()
                .filter(|d| d.as_path() != at.game_dir)
                .filter(|d| {
                    std::fs::read(manifest::path_in(d))
                        .is_ok_and(|m| m.windows(needle.len()).any(|w| w == needle))
                })
                .cloned()
                .collect();
            if !shared_with.is_empty() {
                paths.retain(|p| !p.as_os_str().as_bytes().starts_with(&needle));
            }
        }
    }

    let files = paths
        .into_iter()
        .map(|path| Removal {
            backup: files::oldest_backup(&path),
            path,
        })
        .collect::<Vec<_>>();
    let settings = recorded_settings(&recorded.config.join(&b'\n'));

    let nothing = files.is_empty()
        && !recorded.registry_com
        && recorded.registry_override.is_none()
        && !vcrun_present
        && !recorded.eax_unified
        && recorded.config.is_empty()
        && recorded.launcher.is_empty()
        && recorded.companions.is_empty();
    if nothing {
        return Surveyed::Nothing;
    }
    Surveyed::Found(Box::new(Survey {
        manifest: manifest_path,
        manifest_found,
        recorded,
        files,
        shared_with,
        vcrun_present,
        settings,
        prefix: at.prefix.map(Path::to_path_buf),
        has_app_id: at.has_app_id,
    }))
}

/// Phase 1's answers.
#[derive(Debug, Clone, Default)]
pub struct Choices {
    /// The files to take out (from [`Survey::files`]).
    pub remove: Vec<PathBuf>,
    /// `LAUNCHER:` lines whose DLL override the player keeps.
    pub keep_launcher: Vec<String>,
    /// With no manifest to say, whether to clear the DLL override and COM
    /// keys from the registry anyway.
    pub registry_without_manifest: bool,
    pub remove_vcrun: bool,
    /// Companion AppIDs whose VC++ runtime goes too.
    pub companion_vcrun: Vec<String>,
    /// The settings to put back (from [`Survey::settings`]).
    pub revert: Vec<RevertGroup>,
}

/// The registry keys to clear: COM routing, and the override for which DLL
/// (`dsound`, `openal32`, or `both` when no manifest says).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryWork {
    pub com: bool,
    pub dll: Option<String>,
}

impl Survey {
    /// What Phase 2 would do to the registry, or `None`.
    pub fn registry_work(&self, c: &Choices) -> Option<RegistryWork> {
        let (com, dll) = if self.manifest_found {
            (
                self.recorded.registry_com,
                self.recorded.registry_override.clone(),
            )
        } else if c.registry_without_manifest {
            (true, Some("both".to_string()))
        } else {
            (false, None)
        };
        let wanted = com || dll.is_some();
        let no_prefix = !self.has_app_id
            && !self
                .prefix
                .as_ref()
                .is_some_and(|p| p.join("drive_c").is_dir());
        (wanted && self.shared_with.is_empty() && !no_prefix).then_some(RegistryWork { com, dll })
    }

    /// The launcher lines whose settings file is still there.
    pub fn launcher_lines(&self) -> Vec<String> {
        self.recorded
            .launcher
            .iter()
            .map(|l| String::from_utf8_lossy(l).into_owned())
            .filter(|l| LauncherRecord::parse(l).is_some_and(|r| r.file.is_file()))
            .collect()
    }

    /// False when the answers change nothing; then nothing is touched, not
    /// even the manifest.
    pub fn has_work(&self, c: &Choices) -> bool {
        let launcher_work = self
            .launcher_lines()
            .iter()
            .any(|l| !c.keep_launcher.contains(l));
        let companion_work = self.recorded.companions.iter().any(|co| {
            co.registry_com
                || co.registry_override.is_some()
                || (co.vcrun.is_some() && c.companion_vcrun.contains(&co.app_id))
        });
        !c.remove.is_empty()
            || launcher_work
            || self.registry_work(c).is_some()
            || (self.vcrun_present && c.remove_vcrun)
            || self.recorded.eax_unified
            || !c.revert.is_empty()
            || companion_work
    }
}

/// The Wine side of an uninstall, and closing a launcher, which the engine
/// leaves to the caller.
pub trait UninstallHost: Host {
    /// Called before a launcher's settings file is changed; false leaves its
    /// DLL override in place (the launcher couldn't be closed).
    fn launcher_closed(&mut self, target: &Target) -> bool;
    fn remove_registry(&mut self, work: &RegistryWork) -> bool;
    fn remove_vcrun(&mut self);
    fn remove_eax_unified(&mut self) -> bool;
    fn clean_companion(&mut self, companion: &Companion, remove_vcrun: bool);
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    pub removed: Vec<PathBuf>,
    pub not_removed: Vec<PathBuf>,
    pub restored: Vec<PathBuf>,
    /// (target, the backup that couldn't be moved back and is kept).
    pub restore_failed: Vec<(PathBuf, PathBuf)>,
    pub launcher: Vec<(String, changes::Reverted)>,
    pub launcher_left: Vec<String>,
    pub registry_cleaned: Option<bool>,
    pub settings_restored: Vec<String>,
    pub settings_not_restored: Vec<(String, String, Reverted)>,
    /// The manifest now reads as uninstalled.
    pub fully_uninstalled: bool,
}

/// Every timestamped backup of `target`, removed once its original is back:
/// any others are leftovers of an older install's own output.
fn remove_other_backups(target: &Path) {
    for b in files::backups(target) {
        let _ = std::fs::remove_file(b);
    }
}

/// `when` is the UTC time for the "uninstalled" marker.
pub fn execute(s: &Survey, c: &Choices, host: &mut dyn UninstallHost, when: &str) -> Report {
    let mut r = Report::default();
    if !s.has_work(c) {
        return r;
    }

    // Game files, then the originals back in their place.
    let chosen: Vec<&Removal> = s
        .files
        .iter()
        .filter(|f| c.remove.contains(&f.path))
        .collect();
    for f in &chosen {
        let p = &f.path;
        let legacy =
            files::is_legacy_hrtf_dir(p.as_os_str().as_bytes()) && p.is_dir() && !p.is_symlink();
        if legacy {
            files::remove_legacy_hrtf_dir(p);
        } else {
            let _ = std::fs::remove_file(p);
        }
        if p.symlink_metadata().is_err() {
            r.removed.push(p.clone());
        } else {
            r.not_removed.push(p.clone());
        }
    }
    for f in &chosen {
        let Some(bak) = &f.backup else { continue };
        if std::fs::rename(bak, &f.path).is_ok() {
            remove_other_backups(&f.path);
            r.restored.push(f.path.clone());
        } else {
            r.restore_failed.push((f.path.clone(), bak.clone()));
        }
    }
    let removed_lines: Vec<Vec<u8>> = r
        .removed
        .iter()
        .map(|p| p.as_os_str().as_bytes().to_vec())
        .collect();
    let _ = manifest::forget(&s.manifest, &removed_lines);

    // The launchers' DLL overrides.
    for raw in &s.recorded.launcher {
        let line = String::from_utf8_lossy(raw).into_owned();
        let Some(rec) = LauncherRecord::parse(&line) else {
            continue;
        };
        if !rec.file.is_file() {
            continue;
        }
        if c.keep_launcher.contains(&line) {
            r.launcher_left.push(line);
            continue;
        }
        let t = Target {
            launcher: Launcher::from_key(&rec.launcher).unwrap_or(Launcher::Heroic),
            file: rec.file.clone(),
            id: rec.id.clone(),
        };
        if !host.launcher_closed(&t) {
            r.launcher_left.push(line);
            continue;
        }
        let outcome = changes::revert_override(&line);
        if outcome == changes::Reverted::Failed {
            r.launcher_left.push(line.clone());
        }
        r.launcher.push((line, outcome));
    }

    let mut registry_cleaned = false;
    if let Some(work) = s.registry_work(c) {
        registry_cleaned = host.remove_registry(&work);
        r.registry_cleaned = Some(registry_cleaned);
    }
    let vcrun_removed = s.vcrun_present && c.remove_vcrun;
    if vcrun_removed {
        host.remove_vcrun();
    }
    let eax_unified_removed = s.recorded.eax_unified && host.remove_eax_unified();
    for co in &s.recorded.companions {
        let vc = co.vcrun.is_some() && c.companion_vcrun.contains(&co.app_id);
        if vc || co.registry_com || co.registry_override.is_some() {
            host.clean_companion(co, vc);
        }
    }

    // Game settings: the chosen ones go back, the rest stay recorded.
    let mut settings_kept: Vec<Vec<u8>> = Vec::new();
    for g in &s.settings {
        if !c
            .revert
            .iter()
            .any(|x| x.category == g.category && x.title == g.title)
        {
            settings_kept.extend(g.lines.iter().cloned());
        }
    }
    let mut registry_quiet: Option<bool> = None;
    for g in &c.revert {
        let mut restored = 0;
        for line in &g.lines {
            let Some(rec) = ConfigRecord::parse(line) else {
                continue;
            };
            let outcome = revert(&rec, &mut || {
                *registry_quiet.get_or_insert_with(|| host.registry_quiet())
            });
            if outcome == Reverted::Restored {
                restored += 1;
            } else {
                r.settings_not_restored
                    .push((g.title.clone(), rec.key.clone(), outcome));
            }
            if outcome.keeps_record() {
                settings_kept.push(line.clone());
            }
        }
        if restored > 0 {
            r.settings_restored.push(g.title.clone());
        }
    }

    // Last of all, so an uninstall that stops part way still has the
    // manifest to go on: what was done is dropped from it.
    let stale = s.recorded.stale.clone();
    let _ = manifest::forget(&s.manifest, &stale);
    let kept: Vec<Vec<u8>> = settings_kept
        .into_iter()
        .chain(r.launcher_left.iter().map(|l| l.as_bytes().to_vec()))
        .collect();
    if manifest::is_live(&s.manifest) {
        r.fully_uninstalled = rewrite_manifest(
            &s.manifest,
            &kept,
            registry_cleaned,
            vcrun_removed,
            eax_unified_removed,
            when,
        );
    }
    r
}

/// What's left to undo stays in the manifest: files, and registry keys that
/// weren't cleaned. The VC++ and companion records only matter while one of
/// those is left. Settings and overrides the player kept stay so a later
/// uninstall can still put them back. With nothing left, the whole file
/// becomes the "uninstalled" marker. True when it did.
fn rewrite_manifest(
    path: &Path,
    kept: &[Vec<u8>],
    registry_cleaned: bool,
    vcrun_removed: bool,
    eax_unified_removed: bool,
    when: &str,
) -> bool {
    let data = std::fs::read(path).unwrap_or_default();
    let mut core: Vec<&[u8]> = Vec::new();
    let mut extra: Vec<&[u8]> = Vec::new();
    let body = data.strip_suffix(b"\n").unwrap_or(&data);
    for line in body.split(|&b| b == b'\n').filter(|_| !data.is_empty()) {
        let tagged = line.contains(&b'\t');
        if line.is_empty() || line.starts_with(b"#") {
            continue;
        }
        if line.starts_with(b"CONFIG:") || line.starts_with(b"LAUNCHER:") {
            continue;
        }
        if tagged
            && (line.starts_with(b"REGISTRY:")
                || line.starts_with(b"VCRUN\t")
                || line.starts_with(b"VCRUN:OVERRIDES\t"))
        {
            extra.push(line);
        } else if line.starts_with(b"REGISTRY:") {
            if !registry_cleaned {
                core.push(line);
            }
        } else if line == b"VCRUN" || line == b"VCRUN:OVERRIDES" {
            if !vcrun_removed {
                extra.push(line);
            }
        } else if line == b"EAXUNIFIED" {
            if !eax_unified_removed {
                core.push(line);
            }
        } else {
            core.push(line);
        }
    }
    let mut left = core.clone();
    if !core.is_empty() {
        left.extend(extra);
    }
    if left.is_empty() && kept.is_empty() {
        let _ = std::fs::write(path, manifest::uninstalled_marker(when));
        return true;
    }
    let mut out = format!("{}\n", manifest::HEADER).into_bytes();
    for line in left.iter().copied().chain(kept.iter().map(Vec::as_slice)) {
        out.extend_from_slice(line);
        out.push(b'\n');
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    if std::fs::write(&tmp, &out)
        .and_then(|()| std::fs::rename(&tmp, path))
        .is_err()
    {
        let _ = std::fs::remove_file(&tmp);
    }
    false
}

/// Every game folder with a live install whose manifest names `prefix`,
/// other than `game_dir`.
pub fn games_sharing_prefix(prefix: &Path, game_dir: &Path, installed: &[PathBuf]) -> Vec<PathBuf> {
    let needle = [prefix.as_os_str().as_bytes(), b"/"].concat();
    let mut seen = HashSet::new();
    installed
        .iter()
        .filter(|d| d.as_path() != game_dir && seen.insert(d.as_path()))
        .filter(|d| {
            std::fs::read(manifest::path_in(d))
                .is_ok_and(|m| m.windows(needle.len()).any(|w| w == needle))
        })
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn touch(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn found(s: Surveyed) -> Survey {
        match s {
            Surveyed::Found(s) => *s,
            _ => panic!("expected an install"),
        }
    }

    #[test]
    fn a_shared_prefix_keeps_its_files_and_registry_keys() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("A");
        let other = tmp.path().join("B");
        let pfx = tmp.path().join("pfx");
        let sys = pfx.join("drive_c/windows/syswow64/dsound.dll");
        touch(&game.join("dsound.dll"), "x");
        touch(&sys, "x");
        let lines = |dir: &Path| {
            format!(
                "{}\n{}/dsound.dll\n{}\nREGISTRY:COM\n",
                manifest::HEADER,
                dir.display(),
                sys.display()
            )
        };
        touch(&manifest::path_in(&game), &lines(&game));
        touch(&manifest::path_in(&other), &lines(&other));
        let installed = vec![game.clone(), other.clone()];
        let at = Location {
            game_dir: &game,
            install_root: &game,
            prefix: Some(&pfx),
            extra_dirs: &[],
            installed_dirs: &installed,
            has_app_id: true,
        };
        let s = found(survey(&at));
        assert_eq!(s.shared_with, vec![other.clone()]);
        let paths: Vec<_> = s.files.iter().map(|f| f.path.clone()).collect();
        assert_eq!(paths, vec![game.join("dsound.dll")]);
        assert_eq!(s.registry_work(&Choices::default()), None);

        // Alone in the prefix, both go.
        let alone = vec![game.clone()];
        let s = found(survey(&Location {
            installed_dirs: &alone,
            ..at
        }));
        assert_eq!(s.files.len(), 2);
        assert_eq!(
            s.registry_work(&Choices::default()),
            Some(RegistryWork {
                com: true,
                dll: None
            })
        );
    }

    #[test]
    fn an_uninstalled_or_empty_game_has_nothing_to_do() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("G");
        std::fs::create_dir_all(&game).unwrap();
        let at = Location {
            game_dir: &game,
            install_root: &game,
            prefix: None,
            extra_dirs: &[],
            installed_dirs: &[],
            has_app_id: false,
        };
        assert!(matches!(survey(&at), Surveyed::Nothing));
        // A game's own dsound.dll isn't taken for ours.
        touch(&game.join("dsound.dll"), "the game's own");
        assert!(matches!(survey(&at), Surveyed::Nothing));
        touch(
            &manifest::path_in(&game),
            &manifest::uninstalled_marker("x"),
        );
        assert!(matches!(survey(&at), Surveyed::AlreadyUninstalled));
    }

    #[test]
    fn choosing_nothing_changes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let game = tmp.path().join("G");
        touch(&game.join("dsound.dll"), "x");
        let text = format!(
            "{}\n{}/dsound.dll\n{}/gone.dll\n",
            manifest::HEADER,
            game.display(),
            game.display()
        );
        touch(&manifest::path_in(&game), &text);
        let at = Location {
            game_dir: &game,
            install_root: &game,
            prefix: None,
            extra_dirs: &[],
            installed_dirs: &[],
            has_app_id: false,
        };
        let s = found(survey(&at));
        assert!(!s.has_work(&Choices::default()));
        struct Never;
        impl Host for Never {
            fn game_running(&mut self) -> bool {
                unreachable!()
            }
            fn registry_quiet(&mut self) -> bool {
                unreachable!()
            }
        }
        impl UninstallHost for Never {
            fn launcher_closed(&mut self, _: &Target) -> bool {
                unreachable!()
            }
            fn remove_registry(&mut self, _: &RegistryWork) -> bool {
                unreachable!()
            }
            fn remove_vcrun(&mut self) {
                unreachable!()
            }
            fn remove_eax_unified(&mut self) -> bool {
                unreachable!()
            }
            fn clean_companion(&mut self, _: &Companion, _: bool) {
                unreachable!()
            }
        }
        let r = execute(&s, &Choices::default(), &mut Never, "now");
        assert_eq!(r, Report::default());
        // Not even the stale line is dropped, as in the script.
        assert_eq!(
            std::fs::read_to_string(manifest::path_in(&game)).unwrap(),
            text
        );
    }
}
