//! A game's launch options in Steam's `localconfig.vdf`: only its own block
//! under UserLocalConfigStore/Software/Valve/Steam/apps is touched (the file
//! has other "apps" blocks elsewhere), and every other byte stays as it was.
//! Ports of `vdf_get_raw_launch_options`, `vdf_get_launch_options` and
//! `vdf_set_launch_options` in `src/launcher-config.sh`.

use anyhow::Result;
use std::path::Path;

/// What a localconfig.vdf says about a game's launch options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchOptions {
    /// Steam has no settings block for the game (it was never launched).
    NoApp,
    /// The block has no LaunchOptions line.
    Absent,
    Set(String),
}

fn trim(s: &[u8]) -> &[u8] {
    let start = s.iter().take_while(|&&b| b == b' ' || b == b'\t').count();
    let end = s.len()
        - s[start..]
            .iter()
            .rev()
            .take_while(|&&b| b == b' ' || b == b'\t')
            .count();
    &s[start..end]
}

/// Where a line is: the key path of the blocks around it.
struct Path6<'a> {
    app: &'a [u8],
    stack: Vec<Vec<u8>>,
    depth: usize,
    pending: Vec<u8>,
}

impl Path6<'_> {
    fn in_app(&self) -> bool {
        const WANT: [&[u8]; 5] = [
            b"userlocalconfigstore",
            b"software",
            b"valve",
            b"steam",
            b"apps",
        ];
        self.depth == 6
            && WANT
                .iter()
                .enumerate()
                .all(|(i, w)| self.stack.get(i).is_some_and(|s| s.eq_ignore_ascii_case(w)))
            && self.stack.get(5).is_some_and(|s| s.as_slice() == self.app)
    }

    fn open(&mut self) {
        self.depth += 1;
        if self.stack.len() < self.depth {
            self.stack.resize(self.depth, Vec::new());
        }
        self.stack[self.depth - 1] = self.pending.clone();
    }

    fn close(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }

    /// A `"key"` line on its own names the block that follows.
    fn note_key(&mut self, line: &[u8]) {
        if line.len() >= 2
            && line[0] == b'"'
            && line[line.len() - 1] == b'"'
            && !line[1..line.len() - 1].contains(&b'"')
        {
            self.pending = line[1..line.len() - 1].to_vec();
        }
    }
}

fn is_launch_options(line: &[u8]) -> bool {
    const KEY: &[u8] = b"\"launchoptions\"";
    line.len() > KEY.len()
        && line[..KEY.len()].eq_ignore_ascii_case(KEY)
        && matches!(line[KEY.len()], b' ' | b'\t')
}

fn lines(data: &[u8]) -> Vec<&[u8]> {
    if data.is_empty() {
        return Vec::new();
    }
    data.strip_suffix(b"\n")
        .unwrap_or(data)
        .split(|&b| b == b'\n')
        .collect()
}

/// The LaunchOptions value as written in the file, still VDF-escaped.
pub fn get_raw(data: &[u8], app_id: &str) -> LaunchOptions {
    let mut p = Path6 {
        app: app_id.as_bytes(),
        stack: Vec::new(),
        depth: 0,
        pending: Vec::new(),
    };
    let mut seen = false;
    for raw in lines(data) {
        let line = trim(raw);
        if line == b"{" {
            p.open();
            seen |= p.in_app();
            continue;
        }
        if line == b"}" {
            p.close();
            continue;
        }
        if line.len() >= 2
            && line[0] == b'"'
            && line[line.len() - 1] == b'"'
            && !line[1..line.len() - 1].contains(&b'"')
        {
            p.note_key(line);
            continue;
        }
        if p.in_app() && is_launch_options(line) {
            let v = trim(&line[b"\"LaunchOptions\"".len()..]);
            // The quotes around the value, or whatever stands there.
            let inner = if v.len() >= 2 {
                &v[1..v.len() - 1]
            } else {
                &[][..]
            };
            return LaunchOptions::Set(String::from_utf8_lossy(inner).into_owned());
        }
    }
    if seen {
        LaunchOptions::Absent
    } else {
        LaunchOptions::NoApp
    }
}

/// The game's launch options with VDF's `\" \\ \n \t \r` undone.
pub fn get(data: &[u8], app_id: &str) -> LaunchOptions {
    match get_raw(data, app_id) {
        LaunchOptions::Set(raw) => {
            let mut out = String::with_capacity(raw.len());
            let mut chars = raw.chars().peekable();
            while let Some(c) = chars.next() {
                if c == '\\' {
                    let next = chars.peek().copied();
                    let mapped = match next {
                        Some('\\') => Some('\\'),
                        Some('"') => Some('"'),
                        Some('n') => Some('\n'),
                        Some('t') => Some('\t'),
                        Some('r') => Some('\r'),
                        _ => None,
                    };
                    if let Some(m) = mapped {
                        chars.next();
                        out.push(m);
                        continue;
                    }
                }
                out.push(c);
            }
            // The script prints it and reads it back through $(...).
            while out.ends_with('\n') {
                out.pop();
            }
            LaunchOptions::Set(out)
        }
        other => other,
    }
}

pub fn get_file(path: &Path, app_id: &str) -> LaunchOptions {
    match std::fs::read(path) {
        Ok(data) => get(&data, app_id),
        // awk on a missing file prints the "no block" answer.
        Err(_) => LaunchOptions::NoApp,
    }
}

fn escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\t', "\\t")
        .replace('\r', "\\r")
}

/// Replaces the game's LaunchOptions line, adds one at the end of its
/// block, or with `None` removes it.
pub fn set(data: &[u8], app_id: &str, value: Option<&str>) -> Vec<u8> {
    let entry = |indent: &[u8], v: &str| {
        let mut out = indent.to_vec();
        out.extend_from_slice(b"\"LaunchOptions\"\t\t\"");
        out.extend_from_slice(escape(v).as_bytes());
        out.push(b'"');
        out
    };
    let mut p = Path6 {
        app: app_id.as_bytes(),
        stack: Vec::new(),
        depth: 0,
        pending: Vec::new(),
    };
    let mut out = Vec::with_capacity(data.len() + 64);
    let mut emit = |line: &[u8]| {
        out.extend_from_slice(line);
        out.push(b'\n');
    };
    let mut done = false;
    let mut child_indent: Option<Vec<u8>> = None;
    for raw in lines(data) {
        let line = trim(raw);
        let lead = &raw[..raw.len() - raw.iter().skip_while(|&&b| b == b' ' || b == b'\t').count()];
        if line == b"{" {
            p.open();
            emit(raw);
            continue;
        }
        if line == b"}" {
            if p.in_app() && !done {
                if let Some(v) = value {
                    emit(&entry(child_indent.as_deref().unwrap_or(b""), v));
                    done = true;
                }
            }
            p.close();
            emit(raw);
            continue;
        }
        p.note_key(line);
        if p.in_app() {
            if child_indent.as_deref().is_none_or(<[u8]>::is_empty) {
                child_indent = Some(lead.to_vec());
            }
            if is_launch_options(line) {
                done = true;
                if let Some(v) = value {
                    emit(&entry(lead, v));
                }
                continue;
            }
        }
        emit(raw);
    }
    out
}

/// [`set`] on the file, through a temp file beside it.
pub fn set_file(path: &Path, app_id: &str, value: Option<&str>) -> Result<()> {
    let data = std::fs::read(path)?;
    crate::engine::files::write_through_temp(path, &set(&data, app_id, value))
}

#[cfg(test)]
mod tests {
    use super::*;

    const VDF: &str = "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"apps\"\n\t\t\t\t{\n\t\t\t\t\t\"2210\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LastPlayed\"\t\t\"1\"\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n}\n";

    #[test]
    fn adds_reads_and_removes() {
        assert_eq!(get(VDF.as_bytes(), "2210"), LaunchOptions::Absent);
        assert_eq!(get(VDF.as_bytes(), "9"), LaunchOptions::NoApp);
        let with = set(VDF.as_bytes(), "2210", Some("A=\"b\\c\" %command%"));
        assert!(String::from_utf8_lossy(&with).contains(
            "\t\t\t\t\t\t\"LaunchOptions\"\t\t\"A=\\\"b\\\\c\\\" %command%\"\n\t\t\t\t\t}"
        ));
        assert_eq!(
            get(&with, "2210"),
            LaunchOptions::Set("A=\"b\\c\" %command%".into())
        );
        assert_eq!(set(&with, "2210", None), VDF.as_bytes());
    }
}
