//! The Game Settings editors: read and change one key in a game's config
//! file, in any of the eleven formats the database can name. A port of
//! `config_get_key` / `config_set_key` in `src/game-config.sh`, checked
//! against them byte for byte by `tests/config_oracle.rs`.
//!
//! The core works on the file's bytes ([`get`], [`set`]); [`get_file`] and
//! [`set_file`] add the reading, the temp file and the swap. An edit keeps
//! everything else in the file as it was: CRLF line endings, a BOM, the
//! spelling of an existing key, "key = value" spacing, and whether the file
//! ended with a newline.
//!
//! Which game needs which key is the database's business, never this code's.

mod binary;
mod ini;
mod key_value;
mod pairs;
pub mod paths;
mod registry;
mod revert;
mod safety;
mod set_commands;
mod text;
mod value;
mod xml;

pub use revert::{revert, Reverted};
pub use safety::row_is_safe;
pub use value::{values_equal, Value};

use crate::engine::files;
use anyhow::{bail, Context, Result};
use std::path::Path;
use std::str::FromStr;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Format {
    Ini,
    SetCommands,
    KeyValue,
    BracedPairs,
    IniBraces,
    QuotedPairs,
    XmlAttributes,
    BinaryOffset,
    BinaryText,
    BinarySwitches,
    Registry,
}

impl Format {
    pub const ALL: [Format; 11] = [
        Format::Ini,
        Format::SetCommands,
        Format::KeyValue,
        Format::BracedPairs,
        Format::IniBraces,
        Format::QuotedPairs,
        Format::XmlAttributes,
        Format::BinaryOffset,
        Format::BinaryText,
        Format::BinarySwitches,
        Format::Registry,
    ];

    /// The name the database and the manifest use.
    pub fn name(self) -> &'static str {
        match self {
            Format::Ini => "ini",
            Format::SetCommands => "set_commands",
            Format::KeyValue => "key_value",
            Format::BracedPairs => "braced_pairs",
            Format::IniBraces => "ini_braces",
            Format::QuotedPairs => "quoted_pairs",
            Format::XmlAttributes => "xml_attributes",
            Format::BinaryOffset => "binary_offset",
            Format::BinaryText => "binary_text",
            Format::BinarySwitches => "binary_switches",
            Format::Registry => "registry",
        }
    }

    /// A plain text file, edited line by line; the rest are binary files or
    /// the registry, each with its own reader.
    pub fn is_text(self) -> bool {
        !matches!(
            self,
            Format::BinaryOffset | Format::BinaryText | Format::BinarySwitches | Format::Registry
        )
    }
}

impl FromStr for Format {
    type Err = anyhow::Error;

    /// Current names only. A name this build doesn't know (a newer build
    /// wrote it) is an error, so a registry or binary file is never read as
    /// text.
    fn from_str(name: &str) -> Result<Self> {
        Format::ALL
            .into_iter()
            .find(|f| f.name() == name)
            .with_context(|| format!("unknown config format '{name}'"))
    }
}

/// The key's current value: `Absent` if it isn't set, and for `key_value`
/// `True` for an active bare flag or `False` for one that is only present
/// commented out. Section and key names match without case, like the games
/// themselves read them. A missing file is passed as no bytes.
pub fn get(format: Format, data: &[u8], sec: &str, key: &str) -> Value {
    let (sec, key) = (sec.as_bytes(), key.as_bytes());
    match format {
        Format::Registry => return registry::get(data, sec, key),
        Format::BinaryOffset => return binary::offset_get(data, key),
        Format::BinaryText => return binary::text_get(data, key),
        Format::BinarySwitches => return binary::switch_get(data, key),
        _ => {}
    }
    let doc = text::parse(data);
    let (lsec, lkey) = (sec.to_ascii_lowercase(), key.to_ascii_lowercase());
    let found = match format {
        Format::Ini => ini::get(&doc, false, &lsec, &lkey),
        Format::IniBraces => ini::get(&doc, true, &lsec, &lkey),
        Format::SetCommands => set_commands::get(&doc, &lkey),
        Format::KeyValue => return key_value::get(&doc, &lkey),
        Format::QuotedPairs => pairs::get_quoted(&doc, &lkey),
        Format::BracedPairs => pairs::get_braced(&doc, &lkey),
        Format::XmlAttributes => xml::get(&doc, &lsec, &lkey),
        _ => unreachable!("handled above"),
    };
    // A value that happens to spell a marker reads as that marker, as it
    // does in the script, where values are plain strings.
    found.map_or(Value::Absent, |v| Value::from_bytes(&v))
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

/// Sets (or with `Value::Delete` removes) one key and returns the new file.
/// A missing ini key goes at the end of its section, or in a new section at
/// the end of the file; a missing key in any other text format is appended
/// (`xml_attributes`: added to its tag, and an error when the file has no
/// such tag). The binary formats and the registry only change what their
/// own modules say they can.
pub fn set(format: Format, data: &[u8], sec: &str, key: &str, value: &Value) -> Result<Vec<u8>> {
    set_at(format, data, sec, key, value, now())
}

/// [`set`] with the time a new registry key is stamped with.
pub fn set_at(
    format: Format,
    data: &[u8],
    sec: &str,
    key: &str,
    value: &Value,
    now: u64,
) -> Result<Vec<u8>> {
    let val = value.as_bytes();
    let (bsec, bkey) = (sec.as_bytes(), key.as_bytes());
    match format {
        Format::BinaryOffset => return binary::offset_set(data, bkey, val),
        Format::BinaryText => return binary::text_set(data, bkey, val),
        Format::BinarySwitches => return binary::switch_set(data, bkey, val),
        Format::Registry => return registry::set(data, bsec, bkey, val, now),
        _ => {}
    }
    // UTF-16 text can't be edited as ASCII lines.
    if data.contains(&0) {
        bail!("the file isn't plain text (it has NUL bytes)");
    }
    let doc = text::parse(data);
    let mut w = text::Writer::new(doc.bom);
    let e = text::Edit::new(bsec, bkey, val);
    match format {
        Format::Ini => ini::set(&doc, &mut w, &e),
        Format::IniBraces => ini::set_braces(&doc, &mut w, &e),
        Format::SetCommands => set_commands::set(&doc, &mut w, &e),
        Format::KeyValue => {
            let current = key_value::get(&doc, &e.lkey);
            let active = !matches!(current, Value::Absent | Value::False);
            key_value::set(&doc, &mut w, &e, active);
        }
        Format::QuotedPairs => pairs::set_quoted(&doc, &mut w, &e),
        Format::BracedPairs => pairs::set_braced(&doc, &mut w, &e),
        Format::XmlAttributes => {
            if !xml::set(&doc, &mut w, &e) {
                bail!("the file has no <{sec}> tag to add the attribute to");
            }
        }
        _ => unreachable!("handled above"),
    }
    let mut out = w.finish();
    // A file that ended without a newline still does.
    if !out.is_empty() && data.last().is_some_and(|&b| b != b'\n') {
        out.pop();
    }
    Ok(out)
}

/// [`get`] on a file; one that isn't there reads as `Absent`.
pub fn get_file(path: &Path, format: Format, sec: &str, key: &str) -> Value {
    match std::fs::read(path) {
        Ok(data) if path.is_file() => get(format, &data, sec, key),
        _ => Value::Absent,
    }
}

/// [`set`] on a file. A text file that isn't there yet is created when its
/// folder exists; a binary or registry file must be there already.
pub fn set_file(path: &Path, format: Format, sec: &str, key: &str, value: &Value) -> Result<()> {
    set_file_at(path, format, sec, key, value, now())
}

/// [`set_file`] with the time a new registry key is stamped with.
pub fn set_file_at(
    path: &Path,
    format: Format,
    sec: &str,
    key: &str,
    value: &Value,
    now: u64,
) -> Result<()> {
    let data = match std::fs::read(path) {
        Ok(data) => data,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound && format.is_text() => Vec::new(),
        Err(e) => return Err(e).with_context(|| format!("can't read {}", path.display())),
    };
    let new = set_at(format, &data, sec, key, value, now)?;
    files::write_through_temp(path, &new)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn format_names_round_trip() {
        for f in Format::ALL {
            assert_eq!(f.name().parse::<Format>().unwrap(), f);
        }
        assert!("flat_ini".parse::<Format>().is_err());
        assert!("".parse::<Format>().is_err());
    }

    /// A path a player's own file may hold, put back on uninstall.
    #[test]
    fn backslashes_are_written_as_given() {
        let path = Value::text("C:\\Games\\new");
        let out = set(Format::Ini, b"[a]\nk=1\n", "a", "k", &path).unwrap();
        assert_eq!(out, b"[a]\nk=C:\\Games\\new\n");
        assert_eq!(get(Format::Ini, &out, "a", "k"), path);
    }

    #[test]
    fn set_file_creates_keeps_permissions_and_follows_a_link() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let real = tmp.path().join("real.ini");
        let link = tmp.path().join("link.ini");
        std::fs::write(&real, b"[a]\r\nk=1\r\n").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o640)).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        set_file(&link, Format::Ini, "a", "K", &Value::text("2")).unwrap();
        assert!(link.is_symlink());
        assert_eq!(std::fs::read(&real).unwrap(), b"[a]\r\nk=2\r\n");
        let mode = std::fs::metadata(&real).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o640);

        let new = tmp.path().join("new.ini");
        set_file(&new, Format::Ini, "a", "k", &Value::text("1")).unwrap();
        assert_eq!(std::fs::read(&new).unwrap(), b"[a]\nk=1\n");
        assert_eq!(get_file(&new, Format::Ini, "A", "K"), Value::text("1"));

        // No folder to create it in, and nothing left behind on a refusal.
        let nowhere = tmp.path().join("missing/x.ini");
        assert!(set_file(&nowhere, Format::Ini, "a", "k", &Value::text("1")).is_err());
        let gdb = tmp.path().join("p.gdb");
        assert!(set_file(&gdb, Format::BinarySwitches, "", "k", &Value::text("1")).is_err());
        let names: Vec<_> = std::fs::read_dir(tmp.path())
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with(".eax-restore-cfg"))
            .collect();
        assert!(names.is_empty(), "{names:?}");
    }
}
