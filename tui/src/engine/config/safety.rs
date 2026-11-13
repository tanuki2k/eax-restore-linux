//! `config_row_is_safe`: the schema already enforces all this in CI; this
//! re-checks only what could touch the wrong file or corrupt one, in case a
//! bad entry slips through.

use super::{binary, Format};

fn name_char(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"._ -".contains(&c)
}

fn value_char(c: u8) -> bool {
    name_char(c) || c == b'(' || c == b')'
}

fn is_name(s: &[u8]) -> bool {
    !s.is_empty() && s.iter().all(|&c| name_char(c))
}

fn is_byte(value: &[u8]) -> bool {
    !value.is_empty()
        && value.len() <= 3
        && value.iter().all(u8::is_ascii_digit)
        && std::str::from_utf8(value)
            .ok()
            .and_then(|s| s.parse::<u16>().ok())
            .is_some_and(|n| n <= 255)
}

/// 1 to 16 bytes written as hex.
fn is_anchor(s: &[u8]) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.len().is_multiple_of(2)
        && s.iter().all(u8::is_ascii_hexdigit)
}

const FILE_BASES: [&str; 8] = [
    "game_exe",
    "game_root",
    // The old names for game_exe / game_root.
    "game",
    "install",
    "prefix_documents",
    "prefix_appdata",
    "prefix_localappdata",
    "prefix_public_documents",
];

fn location_ok(format: Format, loc: &str) -> bool {
    if format == Format::Registry {
        // The only format for the prefix's registry files, and only them.
        return loc == "prefix:system.reg" || loc == "prefix:user.reg";
    }
    let Some((base, rel)) = loc.split_once(':') else {
        return false;
    };
    FILE_BASES.contains(&base)
        && !rel.is_empty()
        && !rel.starts_with('/')
        && !loc.contains("..")
        && !loc.contains('\\')
}

/// The locations as the script's `IFS='|' read -ra` splits them: the first
/// line only, and no empty field after a trailing `|`.
pub(super) fn split_locations(locations: &str) -> Vec<&str> {
    let line = locations.lines().next().unwrap_or("");
    let mut locs: Vec<&str> = line.split('|').collect();
    if locs.last() == Some(&"") {
        locs.pop();
    }
    locs
}

pub fn row_is_safe(format: Format, locations: &str, sec: &str, key: &str, value: &str) -> bool {
    let (sec, key, value) = (sec.as_bytes(), key.as_bytes(), value.as_bytes());
    if locations.is_empty()
        || !split_locations(locations)
            .iter()
            .all(|loc| location_ok(format, loc))
    {
        return false;
    }
    let plus = key.iter().position(|&b| b == b'+');
    let key_ok = match (format, plus) {
        // A binary_text key may carry one "+" before its byte distance.
        (Format::BinaryText, Some(p)) => is_name(&[&key[..p], &key[p + 1..]].concat()),
        _ => is_name(key),
    };
    if !key_ok {
        return false;
    }
    let format_ok = match format {
        // An ini file's own top, before its first [header], has no section name.
        Format::Ini => sec.is_empty() || is_name(sec),
        Format::IniBraces => is_name(sec),
        // A registry key path, backslash-separated.
        Format::Registry => {
            sec.split(|&b| b == b'\\')
                .all(|part| !part.is_empty() && part.iter().all(|&c| value_char(c)))
                && !sec.windows(2).any(|w| w == b"..")
        }
        Format::BinaryOffset => binary::offset(key).is_some() && is_byte(value),
        // The hex bytes in front of the text, plus +N for a byte N past its
        // end, which takes a number 0-255.
        Format::BinaryText => match plus {
            Some(p) => {
                let n = &key[p + 1..];
                is_anchor(&key[..p])
                    && !n.is_empty()
                    && n.len() <= 5
                    && n.iter().all(u8::is_ascii_digit)
                    && is_byte(value)
            }
            None => is_anchor(key) && !value.is_empty() && value.len() <= 64,
        },
        // A switch can only be turned on or off in place.
        Format::BinarySwitches => value == b"0" || value == b"1",
        _ => true,
    };
    if !format_ok {
        return false;
    }
    match value {
        b"__TRUE__" | b"__FALSE__" => format == Format::KeyValue,
        b"__DELETE__" => true,
        _ => value.iter().all(|&c| value_char(c)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locations() {
        let ok = |f, l| row_is_safe(f, l, "s", "k", "v");
        assert!(ok(
            Format::Ini,
            "game_exe:a.ini|prefix_documents:My Games/a.ini"
        ));
        assert!(!ok(Format::Ini, ""));
        assert!(!ok(Format::Ini, "game_exe:/etc/passwd"));
        assert!(!ok(Format::Ini, "game_exe:../a.ini"));
        assert!(!ok(Format::Ini, "game_exe:a\\b.ini"));
        assert!(!ok(Format::Ini, "home:a.ini"));
        assert!(!ok(Format::Ini, "prefix:user.reg"));
        assert!(!ok(Format::Ini, "game_exe:a.ini||game_exe:b.ini"));
        assert!(ok(Format::Ini, "game_exe:a.ini|"));
    }

    #[test]
    fn per_format_rules() {
        let loc = "game_exe:a";
        assert!(row_is_safe(Format::Ini, loc, "", "k", "v"));
        assert!(!row_is_safe(Format::IniBraces, loc, "", "k", "v"));
        assert!(row_is_safe(Format::KeyValue, loc, "", "k", "__TRUE__"));
        assert!(!row_is_safe(Format::Ini, loc, "s", "k", "__TRUE__"));
        assert!(row_is_safe(Format::Ini, loc, "s", "k", "__DELETE__"));
        assert!(!row_is_safe(Format::Ini, loc, "s", "k", "a;b"));
        assert!(row_is_safe(Format::BinaryOffset, loc, "", "0x1F", "255"));
        assert!(!row_is_safe(Format::BinaryOffset, loc, "", "0x1F", "256"));
        assert!(row_is_safe(Format::BinaryText, loc, "", "0a0B+12", "3"));
        assert!(!row_is_safe(Format::BinaryText, loc, "", "0a0+12", "3"));
        assert!(row_is_safe(
            Format::BinaryText,
            loc,
            "",
            "0a0b",
            "Miles Fast 2D"
        ));
        assert!(row_is_safe(Format::BinarySwitches, loc, "", "EAX", "1"));
        assert!(!row_is_safe(Format::BinarySwitches, loc, "", "EAX", "2"));
        let reg = "prefix:user.reg";
        assert!(row_is_safe(
            Format::Registry,
            reg,
            "Software\\A (x)\\B",
            "k",
            "1"
        ));
        assert!(!row_is_safe(
            Format::Registry,
            reg,
            "Software\\\\B",
            "k",
            "1"
        ));
        assert!(!row_is_safe(Format::Registry, loc, "Software\\B", "k", "1"));
    }
}
