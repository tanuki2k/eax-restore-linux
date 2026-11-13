//! `registry`: one of Wine's registry files, system.reg (HKLM) or user.reg
//! (HKCU), kept as text in the prefix: "[Key\\Path] <time>" headers with
//! doubled backslashes, then "Name"=dword:0000000a or "Name"="text" lines.
//! The section is the key's path with single backslashes and the key a value
//! name, both matched without case, like Windows. A dword reads and is
//! written as a decimal number; any other type (hex:, str(2):, ...) reads as
//! `__RAW__` and is never changed.
//!
//! Only safe to write while Wine isn't running in the prefix: wineserver
//! writes the file back from memory when it exits.

use super::text::{cat, records};
use super::Value;
use anyhow::{bail, Result};

fn double_backslashes(path: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(path.len());
    for &b in path {
        out.push(b);
        if b == b'\\' {
            out.push(b);
        }
    }
    out
}

/// A header line cut after its last `]`, so the time after it is ignored.
fn header(line: &[u8]) -> Option<&[u8]> {
    if !line.starts_with(b"[") {
        return None;
    }
    Some(match line.iter().rposition(|&b| b == b']') {
        Some(p) => &line[..=p],
        None => line,
    })
}

fn wanted(path: &[u8]) -> Vec<u8> {
    cat(&[b"[", &double_backslashes(path), b"]"]).to_ascii_lowercase()
}

fn has_key(data: &[u8], path: &[u8]) -> bool {
    let want = wanted(path);
    records(data)
        .into_iter()
        .filter_map(header)
        .any(|h| h.eq_ignore_ascii_case(&want))
}

/// The key path to use: the given one, or when the file doesn't have it, the
/// same key in the other registry view (with or without Wow6432Node\, so an
/// entry written for a 64-bit prefix also finds a 32-bit prefix's key).
fn section(data: &[u8], path: &[u8]) -> Vec<u8> {
    const WOW: &[u8] = b"software\\wow6432node\\";
    const SOFT: &[u8] = b"software\\";
    let starts = |p: &[u8]| path.len() >= p.len() && path[..p.len()].eq_ignore_ascii_case(p);
    let alt = if starts(WOW) {
        Some(cat(&[b"Software\\", &path[WOW.len()..]]))
    } else if starts(SOFT) {
        Some(cat(&[b"Software\\Wow6432Node\\", &path[SOFT.len()..]]))
    } else {
        None
    };
    match alt {
        Some(alt) if !has_key(data, path) && has_key(data, &alt) => alt,
        _ => path.to_vec(),
    }
}

enum Kind {
    Dword(u64),
    Text(Vec<u8>),
    Raw,
    Absent,
}

fn name_prefix(name: &[u8]) -> Vec<u8> {
    cat(&[b"\"", name, b"\"="]).to_ascii_lowercase()
}

fn has_prefix(line: &[u8], prefix: &[u8]) -> bool {
    line.len() >= prefix.len() && line[..prefix.len()].eq_ignore_ascii_case(prefix)
}

/// `\\` and `\"` back to the characters they stand for.
fn unescape(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while i < text.len() {
        if text[i] == b'\\' && matches!(text.get(i + 1), Some(b'\\' | b'"')) {
            i += 1;
        }
        out.push(text[i]);
        i += 1;
    }
    out
}

fn read(data: &[u8], sec: &[u8], name: &[u8]) -> Kind {
    let want = wanted(sec);
    let prefix = name_prefix(name);
    let mut insec = false;
    for line in records(data) {
        if let Some(h) = header(line) {
            insec = h.eq_ignore_ascii_case(&want);
            continue;
        }
        if !insec || !has_prefix(line, &prefix) {
            continue;
        }
        let v = &line[prefix.len()..];
        if let Some(hex) = v.strip_prefix(b"dword:") {
            if !hex.is_empty() && hex.iter().all(u8::is_ascii_hexdigit) {
                let n = hex.iter().fold(0u64, |n, &d| {
                    n.saturating_mul(16)
                        .saturating_add((d as char).to_digit(16).unwrap_or(0).into())
                });
                return Kind::Dword(n);
            }
        }
        if v.len() >= 2 && v.starts_with(b"\"") && v.ends_with(b"\"") {
            return Kind::Text(unescape(&v[1..v.len() - 1]));
        }
        return Kind::Raw;
    }
    Kind::Absent
}

pub fn get(data: &[u8], sec: &[u8], name: &[u8]) -> Value {
    match read(data, &section(data, sec), name) {
        Kind::Dword(n) => Value::Text(n.to_string().into_bytes()),
        Kind::Text(t) => Value::Text(t),
        Kind::Raw => Value::Raw,
        Kind::Absent => Value::Absent,
    }
}

/// A value keeps its type: a dword stays a dword (so the new value must be a
/// number), a string stays a string. A new value is a dword when it's a
/// number, else a string; a new key goes at the end of the file with Wine's
/// own header lines, stamped with `now` (seconds since 1970).
pub fn set(data: &[u8], sec: &[u8], name: &[u8], value: &[u8], now: u64) -> Result<Vec<u8>> {
    let sec = section(data, sec);
    let kind = read(data, &sec, name);
    if matches!(kind, Kind::Raw) {
        bail!("that registry value has a type this can't change");
    }
    let del = value == b"__DELETE__";
    let numeric = !value.is_empty() && value.iter().all(u8::is_ascii_digit);
    let val = if del {
        Vec::new()
    } else if matches!(kind, Kind::Dword(_)) || (matches!(kind, Kind::Absent) && numeric) {
        let n = std::str::from_utf8(value)
            .ok()
            .filter(|_| numeric && value.len() <= 10)
            .and_then(|s| s.parse::<u64>().ok())
            .filter(|&n| n <= u64::from(u32::MAX));
        let Some(n) = n else {
            bail!("a dword takes a number up to 4294967295");
        };
        format!("dword:{n:08x}").into_bytes()
    } else {
        let mut quoted = vec![b'"'];
        for &b in value {
            if b == b'\\' || b == b'"' {
                quoted.push(b'\\');
            }
            quoted.push(b);
        }
        quoted.push(b'"');
        quoted
    };

    let want = wanted(&sec);
    let prefix = name_prefix(name);
    let new_line = cat(&[b"\"", name, b"\"=", &val]);
    let mut out: Vec<u8> = Vec::with_capacity(data.len() + 128);
    let mut print = |line: &[u8]| {
        out.extend_from_slice(line);
        out.push(b'\n');
    };
    // Blank lines are held back, so a new value lands above the ones that
    // close its key.
    let mut blanks = 0usize;
    let (mut insec, mut seen, mut done) = (false, false, false);
    for line in records(data) {
        if let Some(h) = header(line) {
            if insec && !done && !del {
                print(&new_line);
                done = true;
            }
            for _ in 0..std::mem::take(&mut blanks) {
                print(b"");
            }
            insec = h.eq_ignore_ascii_case(&want);
            seen |= insec;
            print(line);
            continue;
        }
        if line.is_empty() {
            blanks += 1;
            continue;
        }
        for _ in 0..std::mem::take(&mut blanks) {
            print(b"");
        }
        if insec && !done && has_prefix(line, &prefix) {
            done = true;
            if !del {
                print(&cat(&[&line[..prefix.len()], &val]));
            }
            continue;
        }
        print(line);
    }
    if insec && !done && !del {
        print(&new_line);
    }
    for _ in 0..blanks {
        print(b"");
    }
    if !seen && !del {
        // #time= is the key's FILETIME (100 ns steps since 1601), as Wine writes it.
        let filetime = (u128::from(now) + 11_644_473_600) * 10_000_000;
        print(b"");
        print(&cat(&[
            b"[",
            &double_backslashes(&sec),
            b"] ",
            now.to_string().as_bytes(),
        ]));
        print(format!("#time={filetime:x}").as_bytes());
        print(&new_line);
    }
    Ok(out)
}
