//! `ini` ("[section]" headers over "key=value" lines; section "" is the top
//! of the file, before its first header) and `ini_braces` (a "[section]"
//! line, "{" on its own line, "key = value;" lines up to "}").

use super::text::{cat, header_name, is_blank, is_ws, trim, trim_start, Document, Edit, Writer};

/// The key and value around a line's first `=`, when the key is the one wanted.
fn value_of<'a>(line: &'a [u8], lkey: &[u8]) -> Option<&'a [u8]> {
    let p = line.iter().position(|&b| b == b'=')?;
    trim(&line[..p])
        .eq_ignore_ascii_case(lkey)
        .then_some(&line[p + 1..])
}

pub fn get(doc: &Document, braces: bool, lsec: &[u8], lkey: &[u8]) -> Option<Vec<u8>> {
    let mut insec = !braces && lsec.is_empty();
    for line in &doc.lines {
        if let Some(name) = header_name(line.text) {
            insec = name.eq_ignore_ascii_case(lsec);
            continue;
        }
        if !insec {
            continue;
        }
        let Some(v) = value_of(line.text, lkey) else {
            continue;
        };
        if !braces {
            return Some(trim(v).to_vec());
        }
        // The closing ";" and the spaces after it go; spaces before it stay.
        let v = trim_start(v);
        let end = v.len() - v.iter().rev().take_while(|&&b| is_ws(b)).count();
        let end = if end > 0 && v[end - 1] == b';' {
            end - 1
        } else {
            end
        };
        return Some(v[..end].to_vec());
    }
    None
}

/// Rewrites or drops the line when it is the key, keeping the key's spelling
/// and whether a space followed the `=`. True when it handled the line.
fn replace_key(w: &mut Writer, line: &[u8], e: &Edit, suffix: &[u8]) -> bool {
    let Some(p) = line.iter().position(|&b| b == b'=') else {
        return false;
    };
    if !trim(&line[..p]).eq_ignore_ascii_case(&e.lkey) {
        return false;
    }
    if !e.del {
        let space: &[u8] = if line.get(p + 1) == Some(&b' ') {
            b" "
        } else {
            b""
        };
        w.line(&cat(&[&line[..p], b"=", space, e.val, suffix]));
    }
    true
}

pub fn set(doc: &Document, w: &mut Writer, e: &Edit) {
    let new_line = cat(&[e.key, b"=", e.val]);
    let mut insec = e.sec.is_empty();
    let mut seen = insec;
    let mut done = false;
    for line in &doc.lines {
        w.eol = line.eol;
        if let Some(name) = header_name(line.text) {
            if insec && !done && !e.del {
                w.line(&new_line);
                done = true;
            }
            w.flush_blanks();
            insec = name.eq_ignore_ascii_case(&e.lsec);
            seen |= insec;
            w.line(line.text);
            continue;
        }
        if is_blank(line.text) {
            w.hold_blank();
            continue;
        }
        w.flush_blanks();
        if insec && !done && replace_key(w, line.text, e, b"") {
            done = true;
            continue;
        }
        w.line(line.text);
    }
    if insec && !done && !e.del {
        w.line(&new_line);
        done = true;
    }
    w.flush_blanks();
    if !seen && !done && !e.del {
        if !doc.lines.is_empty() {
            w.line(b"");
        }
        w.line(&cat(&[b"[", e.sec, b"]"]));
        w.line(&new_line);
    }
}

pub fn set_braces(doc: &Document, w: &mut Writer, e: &Edit) {
    let new_line = cat(&[b"\t", e.key, b" = ", e.val, b";"]);
    let mut insec = false;
    let mut seen = false;
    let mut done = false;
    for line in &doc.lines {
        w.eol = line.eol;
        if let Some(name) = header_name(line.text) {
            if insec && !done && !e.del {
                w.line(&new_line);
                done = true;
            }
            insec = name.eq_ignore_ascii_case(&e.lsec);
            seen |= insec;
            w.line(line.text);
            continue;
        }
        if insec && !done && trim_start(line.text).starts_with(b"}") {
            if !e.del {
                w.line(&new_line);
            }
            done = true;
            insec = false;
            w.line(line.text);
            continue;
        }
        if insec && !done && replace_key(w, line.text, e, b";") {
            done = true;
            continue;
        }
        w.line(line.text);
    }
    if insec && !done && !e.del {
        w.line(&new_line);
        w.line(b"}");
    } else if !seen && !done && !e.del {
        if !doc.lines.is_empty() {
            w.line(b"");
        }
        w.line(&cat(&[b"[", e.sec, b"]"]));
        w.line(b"{");
        w.line(&new_line);
        w.line(b"}");
    }
}
