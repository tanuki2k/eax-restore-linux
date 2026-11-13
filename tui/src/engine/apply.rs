//! Writing a game's settings and recording them in the manifest, so an
//! uninstall can put each one back. Ports of `apply_game_settings` (with
//! `_apply_one_setting`, `_apply_prepare_file`, `clear_crash_marker` and the
//! carry-over) and `update_game_settings_in_manifest` in
//! `src/game-config.sh`. Nothing here asks the player anything: what
//! happened comes back in a [`Report`].

use super::config::{self, revert, values_equal, Format, Reverted, Value};
use super::game_settings::PlanRow;
use super::manifest::{self, ConfigRecord};
use anyhow::{Context, Result};
use std::collections::{HashMap, HashSet};
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

/// What the engine needs from outside to change a game's settings.
pub trait Host {
    /// True while the game's own exe is running.
    fn game_running(&mut self) -> bool;
    /// Waits for Wine to save the prefix's registry and exit, before a
    /// registry file is read or changed. False when that can't happen (the
    /// game is running).
    fn registry_quiet(&mut self) -> bool;
}

/// Why one key wasn't changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Skipped {
    /// The file was there when the settings were chosen and isn't now.
    FileGone,
    /// A binary on/off switch that holds something other than 0 or 1, which
    /// putting it back couldn't restore.
    NotOnOff,
    /// The old value holds a tab or a line break, which a manifest line can't.
    UnrecordableOld,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Report {
    /// Titles of the settings changed, in order.
    pub applied: Vec<String>,
    /// How many keys changed in each file.
    pub changed: Vec<(PathBuf, usize)>,
    pub created: Vec<PathBuf>,
    /// Files copied to `<file>.eax-restore.bak` before their first change.
    pub backed_up: Vec<PathBuf>,
    /// Files that couldn't be backed up; the original value is only in the
    /// manifest.
    pub backup_failed: Vec<PathBuf>,
    /// Crash markers removed so the game won't reset a file on its next start.
    pub crash_markers_removed: Vec<PathBuf>,
    /// Files with a crash marker left in place because the game is running,
    /// so it may undo the change when it closes.
    pub may_be_undone: Vec<PathBuf>,
    /// (title, file, why) for keys left alone.
    pub skipped: Vec<(String, PathBuf, Skipped)>,
    /// Files that couldn't be written. A failed setting isn't recorded.
    pub failed: Vec<PathBuf>,
    /// The registry wasn't free (the game is running).
    pub registry_busy: bool,
}

impl Report {
    fn fail(&mut self, path: &Path) {
        self.failed.push(path.to_path_buf());
    }
}

fn key_of(path: &Path, section: &str, key: &str) -> (PathBuf, String, String) {
    (path.to_path_buf(), section.to_string(), key.to_string())
}

/// What `apply` needs from the game's profile and the manifest before it.
pub struct Settings<'a> {
    pub manifest: &'a Path,
    /// The `CONFIG:` lines the last run recorded (format names upgraded).
    pub previous: &'a [Vec<u8>],
    /// Files the last run deployed (its absolute-path lines): a config file
    /// among them was created by it, so there's nothing of the player's to
    /// back up.
    pub previous_files: &'a HashSet<Vec<u8>>,
    /// A file's crash marker, by its name in `game_config.files`.
    pub crash_markers: &'a HashMap<String, String>,
}

fn crash_marker_ok(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"._ -".contains(&c))
}

/// A file named as a crash marker beside `path`, removed unless the game is
/// running (then it's the game's own live marker). Never recorded in the
/// manifest: putting it back would cause exactly the reset it prevents.
fn clear_crash_marker(
    ctx: &Settings,
    file: &str,
    path: &Path,
    host: &mut dyn Host,
    r: &mut Report,
) {
    let Some(name) = ctx.crash_markers.get(file).filter(|n| crash_marker_ok(n)) else {
        return;
    };
    let marker = path.parent().unwrap_or(Path::new("/")).join(name);
    // As the shell's -e: a link to nothing isn't there.
    if !marker.exists() {
        return;
    }
    if host.game_running() {
        r.may_be_undone.push(path.to_path_buf());
        return;
    }
    if std::fs::remove_file(&marker).is_ok() {
        r.crash_markers_removed.push(marker);
    }
}

fn backup_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(".eax-restore.bak");
    PathBuf::from(name)
}

/// `cp -p`: the copy keeps the original's permissions and times.
fn copy_preserving(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::copy(from, to)?;
    let meta = std::fs::metadata(from)?;
    let file = std::fs::File::options().write(true).open(to)?;
    file.set_times(
        std::fs::FileTimes::new()
            .set_accessed(meta.accessed()?)
            .set_modified(meta.modified()?),
    )
}

/// Applies the chosen settings' rows, then carries over the last run's
/// records that are still in effect. Each file is backed up once, as
/// `<file>.eax-restore.bak`, before its first change ever; on a re-run the
/// old value recorded last time is kept, since it is the player's original.
pub fn apply(plan: &[PlanRow], ctx: &Settings, host: &mut dyn Host) -> Report {
    let mut r = Report::default();
    // The last run's original values, by path, section and key.
    let mut previous_old: HashMap<(PathBuf, String, String), Value> = HashMap::new();
    for line in ctx.previous {
        if let Some(rec) = ConfigRecord::parse(line) {
            previous_old.insert(key_of(&rec.path, &rec.section, &rec.key), rec.old);
        }
    }
    let mut recorded: HashSet<(PathBuf, String, String)> = HashSet::new();
    let mut prepared: HashSet<PathBuf> = HashSet::new();
    let mut registry: Option<bool> = None;

    for row in plan {
        if row.format == Format::Registry {
            let quiet = *registry.get_or_insert_with(|| host.registry_quiet());
            if !quiet {
                r.registry_busy = true;
                r.fail(&row.path);
                continue;
            }
        }
        // Get the file ready for its first change.
        if !row.path.is_file() {
            if !row.create {
                r.skipped
                    .push((row.title.clone(), row.path.clone(), Skipped::FileGone));
                continue;
            }
            let made = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&row.path)
                .is_ok();
            if !made {
                r.fail(&row.path);
                continue;
            }
            let _ = manifest::append(ctx.manifest, row.path.as_os_str().as_bytes());
            // Nothing of the player's to back up in a file just created.
            prepared.insert(row.path.clone());
            r.created.push(row.path.clone());
        } else if prepared.insert(row.path.clone()) {
            clear_crash_marker(ctx, &row.file, &row.path, host, &mut r);
            let bak = backup_path(&row.path);
            let ours = ctx.previous_files.contains(row.path.as_os_str().as_bytes());
            if !bak.exists() && !ours {
                match copy_preserving(&row.path, &bak) {
                    Ok(()) => r.backed_up.push(row.path.clone()),
                    Err(_) => r.backup_failed.push(row.path.clone()),
                }
            }
        }

        let mut old = config::get_file(&row.path, row.format, &row.section, &row.key);
        if values_equal(row.format, &old, &row.new) {
            continue;
        }
        if row.format == Format::BinarySwitches && !matches!(old.as_bytes(), b"0" | b"1") {
            r.skipped
                .push((row.title.clone(), row.path.clone(), Skipped::NotOnOff));
            continue;
        }
        if old.as_bytes().iter().any(|&b| b == b'\t' || b == b'\n') {
            r.skipped.push((
                row.title.clone(),
                row.path.clone(),
                Skipped::UnrecordableOld,
            ));
            continue;
        }
        let written = config::set_file(&row.path, row.format, &row.section, &row.key, &row.new);
        let took = written.is_ok()
            && (row.new == Value::Delete
                || values_equal(
                    row.format,
                    &config::get_file(&row.path, row.format, &row.section, &row.key),
                    &row.new,
                ));
        if !took {
            r.fail(&row.path);
            continue;
        }
        let k = key_of(&row.path, &row.section, &row.key);
        if let Some(original) = previous_old.get(&k) {
            old = original.clone();
        }
        let record = ConfigRecord {
            category: row.category.name().to_string(),
            title: row.title.clone(),
            path: row.path.clone(),
            format: row.format.name().to_string(),
            section: row.section.clone(),
            key: row.key.clone(),
            old,
            new: row.new.clone(),
        };
        if manifest::append(ctx.manifest, &record.to_line()).is_err() {
            r.fail(ctx.manifest);
        }
        recorded.insert(k);
        match r.changed.iter_mut().find(|(p, _)| *p == row.path) {
            Some((_, n)) => *n += 1,
            None => r.changed.push((row.path.clone(), 1)),
        }
        if !r.applied.contains(&row.title) {
            r.applied.push(row.title.clone());
        }
    }

    // The last run's records whose change is still in effect stay, so an
    // uninstall can still put them back; the ones just rewritten are new.
    for line in ctx.previous {
        let Some(rec) = ConfigRecord::parse(line) else {
            continue;
        };
        if recorded.contains(&key_of(&rec.path, &rec.section, &rec.key)) {
            continue;
        }
        // A format from a newer build can't be checked, so its record stays:
        // dropping it would leave the change with nothing to put it back.
        let keep = if rec.format_unreadable() {
            true
        } else {
            match rec.known_format() {
                Some(f) if rec.path.is_file() => values_equal(
                    f,
                    &config::get_file(&rec.path, f, &rec.section, &rec.key),
                    &rec.new,
                ),
                _ => false,
            }
        };
        if keep && manifest::append(ctx.manifest, line).is_err() {
            r.fail(ctx.manifest);
        }
    }
    r
}

/// A setting to turn off: its title and the `CONFIG:` lines that recorded it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RevertGroup {
    pub category: String,
    pub title: String,
    pub lines: Vec<Vec<u8>>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct UpdateReport {
    /// Titles with at least one key put back.
    pub restored: Vec<String>,
    /// (title, key, outcome) for every key not put back.
    pub not_restored: Vec<(String, String, Reverted)>,
    pub applied: Report,
}

/// Changes an installed game's settings and rewrites its manifest the way a
/// re-run does: the settings in `revert` are put back (a key that couldn't
/// be keeps its record), every non-`CONFIG:` line stays, and `plan` is
/// applied on top, keeping each key's original value.
pub fn update_in_manifest(
    manifest_path: &Path,
    revert_groups: &[RevertGroup],
    plan: &[PlanRow],
    crash_markers: &HashMap<String, String>,
    host: &mut dyn Host,
) -> Result<UpdateReport> {
    let mut out = UpdateReport::default();
    let mut dropped: HashSet<Vec<u8>> = HashSet::new();
    let mut kept: HashSet<Vec<u8>> = HashSet::new();
    let mut registry: Option<bool> = None;
    for group in revert_groups {
        let mut restored = 0;
        for line in &group.lines {
            if line.is_empty() {
                continue;
            }
            dropped.insert(manifest::upgrade_config_line(line));
            let Some(rec) = ConfigRecord::parse(line) else {
                continue;
            };
            let outcome = revert(&rec, &mut || {
                *registry.get_or_insert_with(|| host.registry_quiet())
            });
            if outcome == Reverted::Restored {
                restored += 1;
            } else {
                out.not_restored
                    .push((group.title.clone(), rec.key.clone(), outcome));
            }
            if outcome.keeps_record() {
                kept.insert(manifest::upgrade_config_line(line));
            }
        }
        if restored > 0 {
            out.restored.push(group.title.clone());
        }
    }
    for line in &kept {
        dropped.remove(line);
    }

    // Every line but the CONFIG ones goes back as it was; those are
    // carried over by apply, if still in effect.
    let data = std::fs::read(manifest_path)
        .with_context(|| format!("can't read {}", manifest_path.display()))?;
    let mut keep_text = Vec::new();
    let mut previous = Vec::new();
    let mut previous_files = HashSet::new();
    let body = data.strip_suffix(b"\n").unwrap_or(&data);
    if !data.is_empty() {
        for line in body.split(|&b| b == b'\n') {
            if line.starts_with(b"CONFIG:") {
                let line = manifest::upgrade_config_line(line);
                if !dropped.contains(&line) {
                    previous.push(line);
                }
            } else {
                keep_text.extend_from_slice(line);
                keep_text.push(b'\n');
                if line.starts_with(b"/") {
                    previous_files.insert(line.to_vec());
                }
            }
        }
    }
    super::files::write_through_temp(manifest_path, &keep_text)?;

    let ctx = Settings {
        manifest: manifest_path,
        previous: &previous,
        previous_files: &previous_files,
        crash_markers,
    };
    out.applied = apply(plan, &ctx, host);
    Ok(out)
}

/// The manifest's `CONFIG:` lines grouped by setting (category and title),
/// in the order they first appear. Manifests written before the rename call
/// optional settings "extras".
pub fn recorded_settings(manifest_data: &[u8]) -> Vec<RevertGroup> {
    let mut groups: Vec<RevertGroup> = Vec::new();
    for line in manifest_data.split(|&b| b == b'\n') {
        let Some(rec) = ConfigRecord::parse(line) else {
            continue;
        };
        let line = manifest::upgrade_config_line(line);
        let category = if rec.category.starts_with("extras") {
            format!("optional{}", &rec.category["extras".len()..])
        } else {
            rec.category.clone()
        };
        match groups
            .iter_mut()
            .find(|g| g.category == category && g.title == rec.title)
        {
            Some(g) => g.lines.push(line),
            None => groups.push(RevertGroup {
                category,
                title: rec.title,
                lines: vec![line],
            }),
        }
    }
    groups
}

/// The manifest line for a path, as bytes.
pub fn path_line(path: &Path) -> &[u8] {
    path.as_os_str().as_bytes()
}

/// A path from a manifest line.
pub fn line_path(line: &[u8]) -> PathBuf {
    PathBuf::from(OsStr::from_bytes(line))
}
