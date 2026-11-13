//! Line handling shared by the text formats. Everything works on bytes with
//! ASCII-only case folding, as the script's awk does under `LC_ALL=C`, so
//! Latin-1 or any other non-UTF-8 text passes through untouched.

pub const BOM: &[u8] = b"\xEF\xBB\xBF";
const LF: &[u8] = b"\n";
const CRLF: &[u8] = b"\r\n";

/// One line without its ending (and without the BOM, on line 1).
pub struct Line<'a> {
    pub text: &'a [u8],
    /// The ending the line had; a last line with none counts as `\n`.
    pub eol: &'static [u8],
}

pub struct Document<'a> {
    pub lines: Vec<Line<'a>>,
    pub bom: bool,
}

/// The file's lines as awk reads them: split at `\n`, no empty record after
/// a final newline, nothing at all for an empty file.
pub fn records(data: &[u8]) -> Vec<&[u8]> {
    if data.is_empty() {
        return Vec::new();
    }
    let body = data.strip_suffix(LF).unwrap_or(data);
    body.split(|&b| b == b'\n').collect()
}

pub fn parse(data: &[u8]) -> Document<'_> {
    let mut bom = false;
    let lines = records(data)
        .into_iter()
        .enumerate()
        .map(|(i, raw)| {
            let (mut text, eol) = match raw.strip_suffix(b"\r") {
                Some(t) => (t, CRLF),
                None => (raw, LF),
            };
            if i == 0 {
                if let Some(t) = text.strip_prefix(BOM) {
                    bom = true;
                    text = t;
                }
            }
            Line { text, eol }
        })
        .collect();
    Document { lines, bom }
}

/// Collects the edited file. A line this adds takes the ending of the line
/// being read (`eol`), and a BOM goes back in front of the first line written.
pub struct Writer {
    out: Vec<u8>,
    bom: bool,
    pub eol: &'static [u8],
    blanks: Vec<&'static [u8]>,
}

impl Writer {
    pub fn new(bom: bool) -> Self {
        Writer {
            out: Vec::new(),
            bom,
            eol: LF,
            blanks: Vec::new(),
        }
    }

    fn line_with(&mut self, line: &[u8], eol: &[u8]) {
        if self.bom {
            self.out.extend_from_slice(BOM);
            self.bom = false;
        }
        self.out.extend_from_slice(line);
        self.out.extend_from_slice(eol);
    }

    pub fn line(&mut self, line: &[u8]) {
        let eol = self.eol;
        self.line_with(line, eol);
    }

    /// Holds a blank line back, so a key added to a section lands above the
    /// blank lines that close it.
    pub fn hold_blank(&mut self) {
        self.blanks.push(self.eol);
    }

    pub fn flush_blanks(&mut self) {
        for eol in std::mem::take(&mut self.blanks) {
            self.line_with(b"", eol);
        }
    }

    pub fn finish(self) -> Vec<u8> {
        self.out
    }
}

/// What one `set` call is changing.
pub struct Edit<'a> {
    pub sec: &'a [u8],
    pub key: &'a [u8],
    pub lsec: Vec<u8>,
    pub lkey: Vec<u8>,
    /// The new value as text (markers included).
    pub val: &'a [u8],
    pub del: bool,
}

impl<'a> Edit<'a> {
    pub fn new(sec: &'a [u8], key: &'a [u8], val: &'a [u8]) -> Self {
        Edit {
            sec,
            key,
            lsec: sec.to_ascii_lowercase(),
            lkey: key.to_ascii_lowercase(),
            val,
            del: val == b"__DELETE__",
        }
    }
}

pub fn is_ws(b: u8) -> bool {
    b == b' ' || b == b'\t'
}

pub fn trim_start(s: &[u8]) -> &[u8] {
    let n = s.iter().take_while(|&&b| is_ws(b)).count();
    &s[n..]
}

pub fn trim_end(s: &[u8]) -> &[u8] {
    let n = s.iter().rev().take_while(|&&b| is_ws(b)).count();
    &s[..s.len() - n]
}

pub fn trim(s: &[u8]) -> &[u8] {
    trim_end(trim_start(s))
}

pub fn is_blank(s: &[u8]) -> bool {
    s.iter().all(|&b| is_ws(b))
}

/// The text up to the first space or tab: awk's `a[1]` after
/// `split(s, a, /[ \t]+/)`.
pub fn first_token(s: &[u8]) -> &[u8] {
    let n = s.iter().take_while(|&&b| !is_ws(b)).count();
    &s[..n]
}

pub fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > hay.len() {
        return None;
    }
    hay.windows(needle.len()).position(|w| w == needle)
}

/// awk's `gsub(/^"|"$/, "", v)`: one quote off each end.
pub fn strip_quotes(v: &[u8]) -> &[u8] {
    // A lone quote is taken as the leading one, leaving nothing to end with.
    let rest = v.strip_prefix(b"\"").unwrap_or(v);
    rest.strip_suffix(b"\"").unwrap_or(rest)
}

/// A `[section]` line (comment after it allowed): the name inside the
/// brackets, as it is spelled.
pub fn header_name(line: &[u8]) -> Option<&[u8]> {
    let rest = trim_start(line).strip_prefix(b"[")?;
    let close = rest.iter().position(|&b| b == b']')?;
    let after = trim_start(&rest[close + 1..]);
    let comment = after.is_empty()
        || after.starts_with(b";")
        || after.starts_with(b"#")
        || after.starts_with(b"//");
    comment.then_some(&rest[..close])
}

/// Joins byte strings into one line.
pub fn cat(parts: &[&[u8]]) -> Vec<u8> {
    parts.concat()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_match_awk() {
        assert!(records(b"").is_empty());
        assert_eq!(records(b"a\n"), vec![b"a".as_slice()]);
        assert_eq!(records(b"a\n\n"), vec![b"a".as_slice(), b"".as_slice()]);
        assert_eq!(records(b"a\nb"), vec![b"a".as_slice(), b"b".as_slice()]);
        assert_eq!(records(b"\n"), vec![b"".as_slice()]);
    }

    #[test]
    fn headers() {
        assert_eq!(header_name(b" [Audio] ; x"), Some(b"Audio".as_slice()));
        assert_eq!(header_name(b"[a] // c"), Some(b"a".as_slice()));
        assert_eq!(header_name(b"[a]=1"), None);
        assert_eq!(header_name(b"[a"), None);
    }

    #[test]
    fn quotes() {
        assert_eq!(strip_quotes(b"\"a\""), b"a");
        assert_eq!(strip_quotes(b"\""), b"");
        assert_eq!(strip_quotes(b"a\""), b"a");
        assert_eq!(strip_quotes(b"\"\""), b"");
    }
}
