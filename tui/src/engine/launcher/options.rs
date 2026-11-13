//! Steam launch options and WINEDLLOVERRIDES as text: adding the DLL
//! override and the sound-log variables, taking them out, reading them back.
//! Ports of the string functions in `src/launcher-config.sh`, quirks
//! included: Bash's regex takes the longest value at the leftmost match
//! (`"ab"cd` reads as that whole word, quotes and all, while `"ab"` reads as
//! `ab`), and every result loses its trailing line breaks, as `$(...)` does.

fn is_space(c: char) -> bool {
    // [[:space:]]
    matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r')
}

fn chomp(mut s: String) -> String {
    while s.ends_with('\n') {
        s.pop();
    }
    s
}

/// The value after `NAME=` at the start of `rest`: its length in `rest`
/// and what it holds. `"…"` and `'…'` lose their quotes, but only when they
/// are the longest reading; ties go to the quoted one.
fn value_at(rest: &str) -> (usize, String) {
    let unquoted = rest.find(is_space).unwrap_or(rest.len());
    let mut best = (unquoted, rest[..unquoted].to_string());
    for q in ['"', '\''] {
        if let Some(body) = rest.strip_prefix(q) {
            if let Some(end) = body.find(q) {
                let len = end + 2;
                if len >= best.0 {
                    best = (len, body[..end].to_string());
                }
            }
        }
    }
    best
}

/// The leftmost `NAME=value` that starts the text or follows whitespace:
/// where the match starts (at the whitespace, if any), where the name
/// starts, the match's end and the value.
struct Found {
    start: usize,
    name: usize,
    end: usize,
    value: String,
}

/// `lead_run`: the whitespace before the name is `[[:space:]]+` (all of it)
/// rather than one character.
fn find_assignment(text: &str, names: &[&str], lead_run: bool) -> Option<Found> {
    let mut best: Option<Found> = None;
    for name in names {
        let pat = format!("{name}=");
        let mut from = 0;
        while let Some(at) = text[from..].find(&pat) {
            let at = from + at;
            from = at + 1;
            let before = &text[..at];
            let ok = at == 0 || before.ends_with(is_space);
            if !ok {
                continue;
            }
            let start = if at == 0 {
                0
            } else if lead_run {
                before.trim_end_matches(is_space).len()
            } else {
                at - before.chars().next_back().map_or(0, char::len_utf8)
            };
            let (len, value) = value_at(&text[at + pat.len()..]);
            let found = Found {
                start,
                name: at,
                end: at + pat.len() + len,
                value,
            };
            if best.as_ref().is_none_or(|b| found.start < b.start) {
                best = Some(found);
            }
            break;
        }
    }
    best
}

/// Adds `<dll>=n,b` to a `;`-separated override list, dropping any earlier
/// rule for the same DLL (including from grouped `a,b=mode` entries) and
/// leaving every other rule as it was.
pub fn merge_dll_override(list: &str, dll: &str) -> String {
    let dll = dll.to_lowercase();
    let dll = dll.strip_suffix(".dll").unwrap_or(&dll).to_string();
    // `read` stops at the first line break.
    let list = list.split('\n').next().unwrap_or("");
    let mut entries: Vec<&str> = list.split(';').collect();
    if entries.last() == Some(&"") {
        entries.pop();
    }
    let mut out: Vec<String> = Vec::new();
    for entry in entries.into_iter().filter(|e| !e.is_empty()) {
        let (names, mode) = match entry.find('=') {
            Some(p) => (&entry[..p], &entry[p..]),
            None => (entry, ""),
        };
        let kept: Vec<&str> = names
            .split(',')
            .filter(|n| {
                let l = n.to_lowercase();
                !n.is_empty() && l.strip_suffix(".dll").unwrap_or(&l) != dll
            })
            .collect();
        if !kept.is_empty() {
            out.push(format!("{}{mode}", kept.join(",")));
        }
    }
    out.push(format!("{dll}=n,b"));
    out.join(";")
}

fn blank(s: &str) -> bool {
    s.chars().all(is_space)
}

/// The launch options with the override added, keeping everything else the
/// player had: an existing WINEDLLOVERRIDES is merged into, other variables
/// and arguments stay put, and %command% is added if missing.
pub fn with_override(opts: &str, dll: &str) -> String {
    let out = if let Some(f) = find_assignment(opts, &["WINEDLLOVERRIDES"], false) {
        let merged = merge_dll_override(&f.value, dll);
        format!(
            "{}WINEDLLOVERRIDES=\"{merged}\"{}",
            &opts[..f.name],
            &opts[f.end..]
        )
    } else if opts.contains("%command%") {
        format!("WINEDLLOVERRIDES=\"{dll}=n,b\" {opts}")
    } else if blank(opts) {
        format!("WINEDLLOVERRIDES=\"{dll}=n,b\" %command%")
    } else {
        format!("WINEDLLOVERRIDES=\"{dll}=n,b\" %command% {opts}")
    };
    chomp(out)
}

const LOG_VARS: [&str; 4] = [
    "DSOAL_LOGLEVEL",
    "DSOAL_LOGFILE",
    "ALSOFT_LOGLEVEL",
    "ALSOFT_LOGFILE",
];

/// The launch options with any DSOAL_LOGLEVEL / DSOAL_LOGFILE and
/// ALSOFT_LOGLEVEL / ALSOFT_LOGFILE removed (bare, "…" or '…' values), and
/// the whitespace before each; everything else as it was.
pub fn without_log(opts: &str) -> String {
    let mut opts = opts.to_string();
    while let Some(f) = find_assignment(&opts, &LOG_VARS, true) {
        opts.replace_range(f.start..f.end, "");
    }
    chomp(opts.trim_start_matches(is_space).to_string())
}

/// The launch options with the given logging variables right before
/// %command% (replacing any already there), adding %command% when missing.
pub fn with_log_vars(opts: &str, vars: &str) -> String {
    let opts = without_log(opts);
    let out = if let Some(at) = opts.find("%command%") {
        format!(
            "{}{vars} %command%{}",
            &opts[..at],
            &opts[at + "%command%".len()..]
        )
    } else if blank(&opts) {
        format!("{vars} %command%")
    } else {
        format!("{vars} %command% {opts}")
    };
    chomp(out)
}

/// DSOAL's logging variables only; the other engine's are dropped.
pub fn with_dsoal_log(opts: &str, level: &str, file: &str) -> String {
    with_log_vars(
        opts,
        &format!("DSOAL_LOGLEVEL={level} DSOAL_LOGFILE=\"{file}\""),
    )
}

/// DSOAL's and OpenAL Soft's logging variables together. An empty DSOAL
/// level leaves DSOAL's out, for a game that uses OpenAL Soft alone.
pub fn with_sound_log(
    opts: &str,
    dsoal_level: &str,
    dsoal_file: &str,
    alsoft_level: &str,
    alsoft_file: &str,
) -> String {
    let mut vars = String::new();
    if !dsoal_level.is_empty() {
        vars = format!("DSOAL_LOGLEVEL={dsoal_level} DSOAL_LOGFILE=\"{dsoal_file}\" ");
    }
    vars.push_str(&format!(
        "ALSOFT_LOGLEVEL={alsoft_level} ALSOFT_LOGFILE=\"{alsoft_file}\""
    ));
    with_log_vars(opts, &vars)
}

/// The value of `<DSOAL|ALSOFT>_LOG<LEVEL|FILE>` in the launch options, or
/// an empty string when it isn't there.
pub fn log_value(opts: &str, engine: &str, kind: &str) -> String {
    let name = format!("{engine}_LOG{kind}");
    find_assignment(opts, &[&name], false).map_or(String::new(), |f| chomp(f.value))
}

/// The Windows path DSOAL_LOGFILE needs for dsoal.log in `folder`: Wine maps
/// Z: to /, and takes forward slashes.
pub fn dsoal_log_path_for_wine(folder: &str) -> String {
    format!("Z:{folder}/dsoal.log")
}

/// The same for ALSOFT_LOGFILE: openal.log in `folder`.
pub fn alsoft_log_path_for_wine(folder: &str) -> String {
    format!("Z:{folder}/openal.log")
}

/// Where a log file value points on this machine: a Z: path maps back to /,
/// another drive letter is left as it is, and a bare name sits in the game
/// folder, where the launcher starts the game.
pub fn log_path_for_linux(value: &str, game_dir: &str) -> String {
    let p = value.replace('\\', "/");
    let b = p.as_bytes();
    let out = if b.len() >= 3 && (b[0] == b'Z' || b[0] == b'z') && b[1] == b':' && b[2] == b'/' {
        p[2..].to_string()
    } else if b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':' {
        p
    } else {
        format!("{game_dir}/{p}")
    };
    chomp(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merging() {
        assert_eq!(merge_dll_override("", "dsound"), "dsound=n,b");
        assert_eq!(
            merge_dll_override("d3d9=n;dsound=b", "DSOUND.dll"),
            "d3d9=n;dsound=n,b"
        );
        assert_eq!(
            merge_dll_override("dsound,dinput8=n,b;x", "dsound"),
            "dinput8=n,b;x;dsound=n,b"
        );
    }

    #[test]
    fn quoted_and_unquoted_values() {
        let o = |s: &str| with_override(s, "dsound");
        assert_eq!(
            o("WINEDLLOVERRIDES=\"ab\""),
            "WINEDLLOVERRIDES=\"ab;dsound=n,b\""
        );
        assert_eq!(
            o("WINEDLLOVERRIDES=\"ab\"cd e"),
            "WINEDLLOVERRIDES=\"\"ab\"cd;dsound=n,b\" e"
        );
        assert_eq!(o(""), "WINEDLLOVERRIDES=\"dsound=n,b\" %command%");
        assert_eq!(o("-fps"), "WINEDLLOVERRIDES=\"dsound=n,b\" %command% -fps");
    }

    #[test]
    fn log_variables() {
        let on = with_sound_log("-x", "4", "Z:/g/dsoal.log", "3", "Z:/g/openal.log");
        assert_eq!(
            on,
            "DSOAL_LOGLEVEL=4 DSOAL_LOGFILE=\"Z:/g/dsoal.log\" ALSOFT_LOGLEVEL=3 ALSOFT_LOGFILE=\"Z:/g/openal.log\" %command% -x"
        );
        assert_eq!(log_value(&on, "DSOAL", "FILE"), "Z:/g/dsoal.log");
        assert_eq!(without_log(&on), "%command% -x");
        assert_eq!(log_path_for_linux("Z:\\g\\dsoal.log", "/x"), "/g/dsoal.log");
        assert_eq!(log_path_for_linux("dsoal.log", "/x"), "/x/dsoal.log");
    }
}
