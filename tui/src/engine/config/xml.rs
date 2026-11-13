//! `xml_attributes`: a tag's attributes on one line,
//! `<Sound UseEAX="1" NumBuffers="8"/>`. The section is the tag's name and
//! the key an attribute's, both matched without case.

use super::text::{cat, find, is_ws, trim_end, Document, Edit, Writer};

/// The first tag with that name on the line: the positions of its `<` and `>`.
fn tag_span(line: &[u8], lname: &[u8]) -> Option<(usize, usize)> {
    let lower = line.to_ascii_lowercase();
    let needle = cat(&[b"<", lname]);
    let mut base = 0;
    loop {
        let p = base + find(&lower[base..], &needle)?;
        let next = lower.get(p + needle.len());
        if next.is_none_or(|&c| is_ws(c) || c == b'/' || c == b'>') {
            let close = lower[p..].iter().position(|&b| b == b'>')?;
            return Some((p, p + close));
        }
        base = p + 1;
    }
}

struct Attr {
    /// The name's first character.
    name: usize,
    /// The value's first character.
    value: usize,
    /// The closing quote.
    end: usize,
}

/// The length of `[ws]=[ws]"..."` at the start of `rest`.
fn assignment_len(rest: &[u8]) -> Option<usize> {
    let skip = |from: usize| from + rest[from..].iter().take_while(|&&b| is_ws(b)).count();
    let eq = skip(0);
    if rest.get(eq) != Some(&b'=') {
        return None;
    }
    let open = skip(eq + 1);
    if rest.get(open) != Some(&b'"') {
        return None;
    }
    let close = rest[open + 1..].iter().position(|&b| b == b'"')?;
    Some(open + 1 + close + 1)
}

fn attr(tag: &[u8], lname: &[u8]) -> Option<Attr> {
    let lower = tag.to_ascii_lowercase();
    let mut base = 0;
    loop {
        let p = base + find(&lower[base..], lname)?;
        let rest = &tag[p + lname.len()..];
        if p > 0 && is_ws(lower[p - 1]) {
            if let Some(len) = assignment_len(rest) {
                let quote = rest.iter().position(|&b| b == b'"').unwrap_or(0);
                return Some(Attr {
                    name: p,
                    value: p + lname.len() + quote + 1,
                    end: p + lname.len() + len - 1,
                });
            }
        }
        base = p + 1;
    }
}

pub fn get(doc: &Document, lsec: &[u8], lkey: &[u8]) -> Option<Vec<u8>> {
    doc.lines.iter().find_map(|line| {
        let (s, e) = tag_span(line.text, lsec)?;
        let tag = &line.text[s..=e];
        let a = attr(tag, lkey)?;
        Some(tag[a.value..a.end].to_vec())
    })
}

/// False when the file has no such tag to add the attribute to.
pub fn set(doc: &Document, w: &mut Writer, e: &Edit) -> bool {
    let mut done = false;
    for line in &doc.lines {
        w.eol = line.eol;
        let span = (!done).then(|| tag_span(line.text, &e.lsec)).flatten();
        let Some((s, end)) = span else {
            w.line(line.text);
            continue;
        };
        done = true;
        let tag = &line.text[s..=end];
        let new_tag = match attr(tag, &e.lkey) {
            Some(a) if e.del => {
                let mut cut = a.name;
                while cut > 0 && is_ws(tag[cut - 1]) {
                    cut -= 1;
                }
                cat(&[&tag[..cut], &tag[a.end + 1..]])
            }
            Some(a) => cat(&[&tag[..a.value], e.val, &tag[a.end..]]),
            None if e.del => tag.to_vec(),
            None => {
                let closer: &[u8] = if tag.ends_with(b"/>") { b"/>" } else { b">" };
                let body = &tag[..tag.len() - closer.len()];
                let kept = trim_end(body);
                let trail = &body[kept.len()..];
                cat(&[kept, b" ", e.key, b"=\"", e.val, b"\"", trail, closer])
            }
        };
        w.line(&cat(&[&line.text[..s], &new_tag, &line.text[end + 1..]]));
    }
    done || e.del
}
