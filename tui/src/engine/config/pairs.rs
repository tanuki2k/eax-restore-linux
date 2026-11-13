//! `braced_pairs` ("{key} = {value}" lines) and `quoted_pairs`
//! ("key" "value" lines, both quoted).

use super::text::{cat, is_ws, strip_quotes, trim, trim_end, Document, Edit, Writer};

fn skip_ws(line: &[u8], from: usize) -> usize {
    from + line[from..].iter().take_while(|&&b| is_ws(b)).count()
}

/// A line that opens `"key"`: the key, and where the text after it (and the
/// spaces that follow) starts.
fn quoted_head(line: &[u8]) -> Option<(&[u8], usize)> {
    let open = skip_ws(line, 0);
    if line.get(open) != Some(&b'"') {
        return None;
    }
    let close = open + 1 + line[open + 1..].iter().position(|&b| b == b'"')?;
    Some((&line[open + 1..close], skip_ws(line, close + 1)))
}

/// A line that opens `{key} = {`: the key, and where the value starts.
fn braced_head(line: &[u8]) -> Option<(&[u8], usize)> {
    let open = skip_ws(line, 0);
    if line.get(open) != Some(&b'{') {
        return None;
    }
    let close = open + 1 + line[open + 1..].iter().position(|&b| b == b'}')?;
    let eq = skip_ws(line, close + 1);
    if line.get(eq) != Some(&b'=') {
        return None;
    }
    let brace = skip_ws(line, eq + 1);
    if line.get(brace) != Some(&b'{') {
        return None;
    }
    Some((trim(&line[open + 1..close]), brace + 1))
}

pub fn get_quoted(doc: &Document, lkey: &[u8]) -> Option<Vec<u8>> {
    doc.lines.iter().find_map(|line| {
        let (key, at) = quoted_head(line.text)?;
        key.eq_ignore_ascii_case(lkey)
            .then(|| strip_quotes(trim_end(&line.text[at..])).to_vec())
    })
}

pub fn get_braced(doc: &Document, lkey: &[u8]) -> Option<Vec<u8>> {
    doc.lines.iter().find_map(|line| {
        let (key, at) = braced_head(line.text)?;
        if !key.eq_ignore_ascii_case(lkey) {
            return None;
        }
        // Up to the closing brace when the line ends with one.
        let v = &line.text[at..];
        let closed = trim_end(v).strip_suffix(b"}");
        Some(closed.unwrap_or(v).to_vec())
    })
}

/// Finds a line's key and where its value starts.
type Head = fn(&[u8]) -> Option<(&[u8], usize)>;

fn set_with(
    doc: &Document,
    w: &mut Writer,
    e: &Edit,
    head: Head,
    open: &[u8],
    close: &[u8],
    new_line: Vec<u8>,
) {
    let mut done = false;
    for line in &doc.lines {
        w.eol = line.eol;
        let hit = (!done)
            .then(|| head(line.text))
            .flatten()
            .filter(|(key, _)| key.eq_ignore_ascii_case(&e.lkey));
        match hit {
            Some((_, at)) => {
                done = true;
                if !e.del {
                    // Anything after the old value is dropped.
                    w.line(&cat(&[&line.text[..at], open, e.val, close]));
                }
            }
            None => w.line(line.text),
        }
    }
    if !done && !e.del && e.val != b"__FALSE__" {
        w.line(&new_line);
    }
}

pub fn set_quoted(doc: &Document, w: &mut Writer, e: &Edit) {
    let new_line = cat(&[b"\"", e.key, b"\" \"", e.val, b"\""]);
    set_with(doc, w, e, quoted_head, b"\"", b"\"", new_line);
}

pub fn set_braced(doc: &Document, w: &mut Writer, e: &Edit) {
    let new_line = cat(&[b"{", e.key, b"} = {", e.val, b"}"]);
    set_with(doc, w, e, braced_head, b"", b"}", new_line);
}
