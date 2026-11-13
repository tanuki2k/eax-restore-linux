//! Putting one recorded setting back: the inside of `revert_game_settings`.

use super::{get_file, set_file, values_equal, Format, Value};
use crate::engine::manifest::ConfigRecord;

/// What became of one `CONFIG:` record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reverted {
    /// The original value is back.
    Restored,
    /// Nothing to put back: a damaged line, or the game's file is gone.
    Nothing,
    /// The setting no longer has the value the install set, so the player
    /// changed it since; it is left alone.
    ChangedSince,
    /// Written by a newer build in a format this one can't read.
    Unreadable,
    /// Wine is still running in the prefix, so its registry can't be changed.
    RegistryBusy,
    /// The file couldn't be written.
    Failed,
}

impl Reverted {
    /// The record stays in the manifest, so a later uninstall can still put
    /// the setting back.
    pub fn keeps_record(self) -> bool {
        matches!(
            self,
            Reverted::Unreadable | Reverted::RegistryBusy | Reverted::Failed
        )
    }
}

/// Puts back the original value, but only where the setting still has the
/// value the install set. `registry_quiet` is asked before the prefix's
/// registry is read: it waits for Wine to save and exit, and says whether it
/// did.
pub fn revert(record: &ConfigRecord, registry_quiet: &mut dyn FnMut() -> bool) -> Reverted {
    if record.format.is_empty() {
        return Reverted::Nothing;
    }
    let Some(format) = record.known_format() else {
        return Reverted::Unreadable;
    };
    if !record.path.is_file() {
        return Reverted::Nothing;
    }
    if format == Format::Registry && !registry_quiet() {
        return Reverted::RegistryBusy;
    }
    let current = get_file(&record.path, format, &record.section, &record.key);
    if !values_equal(format, &current, &record.new) {
        return Reverted::ChangedSince;
    }
    // A key that wasn't there before is taken out again.
    let target = match &record.old {
        Value::Absent => &Value::Delete,
        other => other,
    };
    match set_file(&record.path, format, &record.section, &record.key, target) {
        Ok(()) => Reverted::Restored,
        Err(_) => Reverted::Failed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(path: &std::path::Path, format: &str, old: &str, new: &str) -> ConfigRecord {
        ConfigRecord {
            category: "audio".into(),
            title: "Enable EAX".into(),
            path: path.to_path_buf(),
            format: format.into(),
            section: "Audio".into(),
            key: "UseEAX".into(),
            old: Value::text(old),
            new: Value::text(new),
        }
    }

    #[test]
    fn each_outcome() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("a.ini");
        let mut quiet = || true;
        std::fs::write(&f, "[Audio]\r\nUseEAX=True\r\n").unwrap();

        // Ini values compare without case: "True" is still the "true" it set.
        let r = record(&f, "ini", "0", "true");
        assert_eq!(revert(&r, &mut quiet), Reverted::Restored);
        assert_eq!(std::fs::read(&f).unwrap(), b"[Audio]\r\nUseEAX=0\r\n");

        // The player's own change stays.
        assert_eq!(revert(&r, &mut quiet), Reverted::ChangedSince);
        assert_eq!(std::fs::read(&f).unwrap(), b"[Audio]\r\nUseEAX=0\r\n");

        // A key the install added is removed.
        let added = record(&f, "ini", "__ABSENT__", "0");
        assert_eq!(revert(&added, &mut quiet), Reverted::Restored);
        assert_eq!(std::fs::read(&f).unwrap(), b"[Audio]\r\n");

        assert_eq!(
            revert(&record(&f, "", "0", "1"), &mut quiet),
            Reverted::Nothing
        );
        let gone = tmp.path().join("gone.ini");
        assert_eq!(
            revert(&record(&gone, "ini", "0", "1"), &mut quiet),
            Reverted::Nothing
        );
        let newer = revert(&record(&f, "toml", "0", "1"), &mut quiet);
        assert_eq!(newer, Reverted::Unreadable);
        assert!(newer.keeps_record());
    }

    #[test]
    fn the_registry_waits_for_wine() {
        let tmp = tempfile::tempdir().unwrap();
        let f = tmp.path().join("user.reg");
        std::fs::write(&f, "[Software\\\\G] 1\n\"UseEAX\"=dword:00000001\n").unwrap();
        let mut r = record(&f, "registry", "0", "1");
        r.section = "Software\\G".into();
        let mut asked = 0;
        let busy = revert(&r, &mut || {
            asked += 1;
            false
        });
        assert_eq!((busy, asked), (Reverted::RegistryBusy, 1));
        assert!(busy.keeps_record());
        assert_eq!(revert(&r, &mut || true), Reverted::Restored);
        assert!(std::fs::read_to_string(&f)
            .unwrap()
            .contains("dword:00000000"));
    }
}
