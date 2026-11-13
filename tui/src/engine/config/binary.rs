//! The three binary formats. None of them ever grows or shrinks a file
//! except `binary_text`, which swaps one length-prefixed text for another.

use super::text::find;
use super::Value;
use anyhow::{bail, Result};

fn all_digits(s: &[u8], max_len: usize) -> bool {
    !s.is_empty() && s.len() <= max_len && s.iter().all(u8::is_ascii_digit)
}

fn number(s: &[u8], max_len: usize) -> Option<u64> {
    if !all_digits(s, max_len) {
        return None;
    }
    std::str::from_utf8(s).ok()?.parse().ok()
}

/// A value that fits one byte, written as up to three digits.
fn byte_value(value: &[u8]) -> Option<u8> {
    number(value, 3).and_then(|n| u8::try_from(n).ok())
}

fn decimal(n: impl std::fmt::Display) -> Value {
    Value::Text(n.to_string().into_bytes())
}

// ---- binary_offset ---------------------------------------------------------

/// `binary_offset` keys are byte positions counted from 0, in decimal or as
/// 0x hex.
pub fn offset(key: &[u8]) -> Option<usize> {
    let hex = key.strip_prefix(b"0x").or_else(|| key.strip_prefix(b"0X"));
    let n = match hex {
        Some(h) if !h.is_empty() && h.len() <= 8 && h.iter().all(u8::is_ascii_hexdigit) => {
            u64::from_str_radix(std::str::from_utf8(h).ok()?, 16).ok()?
        }
        Some(_) => return None,
        None => number(key, 9)?,
    };
    usize::try_from(n).ok()
}

pub fn offset_get(data: &[u8], key: &[u8]) -> Value {
    match offset(key).and_then(|o| data.get(o)) {
        Some(b) => decimal(b),
        None => Value::Absent,
    }
}

/// Overwrites the one byte in place; a position past the end or a value
/// outside 0-255 is refused.
pub fn offset_set(data: &[u8], key: &[u8], value: &[u8]) -> Result<Vec<u8>> {
    let Some(byte) = byte_value(value) else {
        bail!("a byte takes a number from 0 to 255");
    };
    let Some(at) = offset(key).filter(|&o| o < data.len()) else {
        bail!("the file has no byte at that position");
    };
    let mut out = data.to_vec();
    out[at] = byte;
    Ok(out)
}

// ---- binary_text -----------------------------------------------------------

/// A found text: where its 4-byte length sits, and the text.
struct Found<'a> {
    pos: usize,
    text: &'a [u8],
}

fn parse_hex(anchor: &[u8]) -> Option<Vec<u8>> {
    if anchor.is_empty() || anchor.len() > 32 || !anchor.len().is_multiple_of(2) {
        return None;
    }
    anchor
        .chunks(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).ok()?, 16).ok())
        .collect()
}

/// `binary_text` keys are the bytes (as hex) that sit right before a 4-byte
/// little-endian length and that many characters of text. The first match
/// whose length is 1-64 and whose text is all printable ASCII wins, so a
/// stray copy of the anchor inside other data is skipped.
fn text_find<'a>(data: &'a [u8], anchor: &[u8]) -> Option<Found<'a>> {
    if !anchor.iter().all(u8::is_ascii_hexdigit) {
        return None;
    }
    let anchor = parse_hex(anchor)?;
    let mut from = 0;
    while let Some(hit) = find(&data[from..], &anchor) {
        let at = from + hit;
        from = at + 1;
        let pos = at + anchor.len();
        let Some(len) = data.get(pos..pos + 4) else {
            continue;
        };
        let n = u32::from_le_bytes([len[0], len[1], len[2], len[3]]) as usize;
        if !(1..=64).contains(&n) {
            continue;
        }
        let Some(text) = data.get(pos + 4..pos + 4 + n) else {
            continue;
        };
        if text.iter().all(|&c| (32..=126).contains(&c)) {
            return Some(Found { pos, text });
        }
    }
    None
}

/// The anchor, and the `+N` after it when the key names the single byte N
/// bytes past the end of the text.
fn split_key(key: &[u8]) -> (&[u8], Option<&[u8]>) {
    match key.iter().position(|&b| b == b'+') {
        Some(p) => (&key[..p], Some(&key[p + 1..])),
        None => (key, None),
    }
}

/// Where a `+N` key's byte sits, when the file reaches that far.
fn text_byte_at(data: &[u8], found: &Found, plus: &[u8]) -> Option<usize> {
    let n = usize::try_from(number(plus, 5)?).ok()?;
    let at = found.pos + 4 + found.text.len() + n;
    (at < data.len()).then_some(at)
}

pub fn text_get(data: &[u8], key: &[u8]) -> Value {
    let (anchor, plus) = split_key(key);
    let Some(found) = text_find(data, anchor) else {
        return Value::Absent;
    };
    match plus {
        None => Value::Text(found.text.to_vec()),
        Some(plus) => match text_byte_at(data, &found, plus) {
            Some(at) => decimal(data[at]),
            None => Value::Absent,
        },
    }
}

fn text_char_ok(c: u8) -> bool {
    c.is_ascii_alphanumeric() || b"._ ()-".contains(&c)
}

/// Swaps the text for a new one of any length (1-64 characters) with its
/// length in front, or for `<anchor>+<N>` overwrites that one byte.
pub fn text_set(data: &[u8], key: &[u8], value: &[u8]) -> Result<Vec<u8>> {
    let (anchor, plus) = split_key(key);
    let Some(found) = text_find(data, anchor) else {
        bail!("the file doesn't have that text");
    };
    if let Some(plus) = plus {
        let Some(byte) = byte_value(value) else {
            bail!("a byte takes a number from 0 to 255");
        };
        let Some(at) = text_byte_at(data, &found, plus) else {
            bail!("the file has no byte at that position");
        };
        let mut out = data.to_vec();
        out[at] = byte;
        return Ok(out);
    }
    if value.is_empty() || value.len() > 64 || !value.iter().all(|&c| text_char_ok(c)) {
        bail!("the text must be 1 to 64 plain characters");
    }
    let mut out = data[..found.pos].to_vec();
    out.extend_from_slice(&(value.len() as u32).to_le_bytes());
    out.extend_from_slice(value);
    out.extend_from_slice(&data[found.pos + 4 + found.text.len()..]);
    // The first match must still be this text, or it can't be found again.
    if text_get(&out, key) != Value::Text(value.to_vec()) {
        bail!("the new text doesn't read back");
    }
    Ok(out)
}

// ---- binary_switches -------------------------------------------------------

fn u32_at(data: &[u8], at: usize) -> Option<u32> {
    let b = data.get(at..at + 4)?;
    Some(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
}

/// `binary_switches` is Monolith's binary game database (F.E.A.R.'s
/// Profile000.gdb): a "GADB" header with the string table's size at byte 8,
/// the string table from byte 28 (NUL-separated names), then 4-byte-aligned
/// little-endian records of [name's offset in the string table, type, 0,
/// count, value...]. Finds the key's one on/off record (type 1, count 1):
/// the position of its value and the value. Nothing when there's no such
/// record, more than one, or the file isn't a GADB file.
fn switch_find(data: &[u8], key: &[u8]) -> Option<(usize, u32)> {
    if data.len() < 28 || !data.starts_with(b"GADB") {
        return None;
    }
    let end = 28 + u32_at(data, 8)? as usize;
    if end > data.len() {
        return None;
    }
    // A name counts only when a NUL closes it inside the table.
    let mut name_at = None;
    let mut start = 28;
    for i in 28..end {
        if data[i] == 0 {
            if data[start..i].eq_ignore_ascii_case(key) {
                name_at = Some((start - 28) as u32);
                break;
            }
            start = i + 1;
        }
    }
    let name_at = name_at?;
    let mut hit = None;
    let mut hits = 0;
    let mut i = end + (4 - end % 4) % 4;
    while i + 20 <= data.len() {
        if u32_at(data, i) == Some(name_at)
            && u32_at(data, i + 4) == Some(1)
            && u32_at(data, i + 8) == Some(0)
            && u32_at(data, i + 12) == Some(1)
        {
            hits += 1;
            hit = Some(i + 16);
        }
        i += 4;
    }
    let pos = hit.filter(|_| hits == 1)?;
    Some((pos, u32_at(data, pos)?))
}

pub fn switch_get(data: &[u8], key: &[u8]) -> Value {
    match switch_find(data, key) {
        Some((_, v)) => decimal(v),
        None => Value::Absent,
    }
}

/// Overwrites the value of the key's existing on/off record. Never adds or
/// removes a record, since the file's offsets would all move.
pub fn switch_set(data: &[u8], key: &[u8], value: &[u8]) -> Result<Vec<u8>> {
    let v: u32 = match value {
        b"0" => 0,
        b"1" => 1,
        _ => bail!("a switch takes 0 or 1"),
    };
    let Some((pos, _)) = switch_find(data, key) else {
        bail!("the file doesn't have that one on/off setting");
    };
    let mut out = data.to_vec();
    out[pos..pos + 4].copy_from_slice(&v.to_le_bytes());
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offsets() {
        assert_eq!(offset(b"16"), Some(16));
        assert_eq!(offset(b"0x10"), Some(16));
        assert_eq!(offset(b"0X1f"), Some(31));
        assert_eq!(offset(b"010"), Some(10));
        assert_eq!(offset(b"0x"), None);
        assert_eq!(offset(b"x10"), None);
        assert_eq!(offset(b"1234567890"), None);
        assert_eq!(offset(b"-1"), None);
    }

    #[test]
    fn offset_set_never_grows_the_file() {
        assert_eq!(offset_set(b"abc", b"1", b"65").unwrap(), b"aAc");
        assert!(offset_set(b"abc", b"3", b"65").is_err());
        assert!(offset_set(b"abc", b"1", b"256").is_err());
        assert_eq!(offset_get(b"abc", b"3"), Value::Absent);
    }

    #[test]
    fn text_skips_a_stray_anchor() {
        // The anchor first appears before a length that is far too large.
        let mut data = vec![0xAA, 0xBB, 0xFF, 0xFF, 0xFF, 0xFF];
        data.extend_from_slice(&[0xAA, 0xBB, 3, 0, 0, 0]);
        data.extend_from_slice(b"EAX\x07");
        assert_eq!(text_get(&data, b"aabb"), Value::text("EAX"));
        assert_eq!(text_get(&data, b"AABB+0"), Value::text("7"));
        assert_eq!(text_get(&data, b"aabb+1"), Value::Absent);
        let out = text_set(&data, b"aabb", b"Miles Fast 2D").unwrap();
        assert_eq!(text_get(&out, b"aabb"), Value::text("Miles Fast 2D"));
        assert_eq!(text_get(&out, b"aabb+0"), Value::text("7"));
        assert!(text_set(&data, b"aabb", b"bad/char").is_err());
    }
}
