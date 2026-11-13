//! `key_value`: "name value" lines and bare flags, `;` for a comment (the
//! Dark engine's cfg files, the X-Ray engine's user.ltx). A flag reads
//! `__TRUE__` when it is active and `__FALSE__` when it is only there as a
//! commented-out example.

use super::text::{cat, first_token, trim, trim_start, Document, Edit, Writer};
use super::Value;

/// The line without its leading spaces and comment mark, and whether it had one.
fn uncomment(line: &[u8]) -> (&[u8], bool) {
    let t = trim_start(line);
    match t.strip_prefix(b";") {
        Some(rest) => (trim_start(rest), true),
        None => (t, false),
    }
}

pub fn get(doc: &Document, lkey: &[u8]) -> Value {
    let mut commented = false;
    for line in &doc.lines {
        let (t, is_comment) = uncomment(line.text);
        let name = first_token(t);
        if !name.eq_ignore_ascii_case(lkey) {
            continue;
        }
        if is_comment {
            commented = true;
            continue;
        }
        let v = trim(&t[name.len()..]);
        return if v.is_empty() {
            Value::True
        } else {
            Value::Text(v.to_vec())
        };
    }
    if commented {
        Value::False
    } else {
        Value::Absent
    }
}

/// `active`: the key has an active line already (it reads as neither absent
/// nor `__FALSE__`), so a commented example of it is left alone.
pub fn set(doc: &Document, w: &mut Writer, e: &Edit, active: bool) {
    let off = e.val == b"__FALSE__";
    let on = e.val == b"__TRUE__";
    let written = |name: &[u8]| {
        if on {
            name.to_vec()
        } else {
            cat(&[name, b" ", e.val])
        }
    };
    let mut done = false;
    // The line before was the key's commented example.
    let mut after_example = false;
    for line in &doc.lines {
        w.eol = line.eol;
        let (t, is_comment) = uncomment(line.text);
        let name = first_token(t);
        if !name.eq_ignore_ascii_case(&e.lkey) {
            after_example = false;
            w.line(line.text);
            continue;
        }
        if is_comment {
            after_example = true;
            w.line(line.text);
            if !active && !done && !e.del && !off {
                done = true;
                w.line(&written(name));
            }
            continue;
        }
        if e.del {
            continue;
        }
        if off {
            // An active line straight after the commented example is one an
            // earlier write added: turning it off removes it, so the file
            // goes back to just the example.
            if after_example {
                after_example = false;
            } else {
                w.line(&cat(&[b";", line.text]));
            }
            continue;
        }
        after_example = false;
        if done {
            w.line(line.text);
        } else {
            done = true;
            w.line(&written(name));
        }
    }
    if !done && !e.del && !off {
        w.line(&written(e.key));
    }
}
