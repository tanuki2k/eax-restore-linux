//! `set_commands`: id Tech's `seta name "value"` / `set name value` lines.

use super::text::{cat, first_token, is_ws, strip_quotes, trim, Document, Edit, Writer};

/// The length of a leading `set ` / `seta ` (any case, any spacing).
fn command_len(line: &[u8]) -> Option<usize> {
    let mut i = line.iter().take_while(|&&b| is_ws(b)).count();
    if !line.get(i..i + 3)?.eq_ignore_ascii_case(b"set") {
        return None;
    }
    i += 3;
    if line.get(i).is_some_and(|b| b.eq_ignore_ascii_case(&b'a'))
        && line.get(i + 1).is_some_and(|&b| is_ws(b))
    {
        i += 1;
    }
    let gap = line[i..].iter().take_while(|&&b| is_ws(b)).count();
    (gap > 0).then_some(i + gap)
}

pub fn get(doc: &Document, lkey: &[u8]) -> Option<Vec<u8>> {
    for line in &doc.lines {
        let Some(n) = command_len(line.text) else {
            continue;
        };
        let rest = &line.text[n..];
        let name = first_token(rest);
        if name.eq_ignore_ascii_case(lkey) {
            return Some(strip_quotes(trim(&rest[name.len()..])).to_vec());
        }
    }
    None
}

pub fn set(doc: &Document, w: &mut Writer, e: &Edit) {
    let mut done = false;
    for line in &doc.lines {
        w.eol = line.eol;
        let hit = (!done)
            .then(|| command_len(line.text))
            .flatten()
            .filter(|&n| first_token(&line.text[n..]).eq_ignore_ascii_case(&e.lkey));
        let Some(n) = hit else {
            w.line(line.text);
            continue;
        };
        done = true;
        if e.del {
            continue;
        }
        // Keep set / seta, the spacing and whether the value was quoted.
        let (lead, rest) = line.text.split_at(n);
        let name = first_token(rest);
        let after = &rest[name.len()..];
        let gap_len = after.iter().take_while(|&&b| is_ws(b)).count();
        let gap: &[u8] = if gap_len == 0 {
            b" "
        } else {
            &after[..gap_len]
        };
        let quoted = after.get(gap_len) == Some(&b'"')
            || e.val.is_empty()
            || e.val.iter().any(|&b| is_ws(b));
        let q: &[u8] = if quoted { b"\"" } else { b"" };
        w.line(&cat(&[lead, name, gap, q, e.val, q]));
    }
    if !done && !e.del && e.val != b"__FALSE__" {
        w.line(&cat(&[b"seta ", e.key, b" \"", e.val, b"\""]));
    }
}
