//! Parity with the Bash script: every case here runs through
//! `config_get_key` / `config_set_key` from `src/game-config.sh` and through
//! the Rust editors, and the values read and the files written must match
//! byte for byte. The Bash functions are the specification until the script
//! is retired, quirks included.
//!
//! Needs bash, awk, od and the usual coreutils, like the script itself.

use eax_restore::engine::config::{self, Format, Value};
use std::collections::HashSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::process::Command;

/// What the fake `date` prints, so a new registry key's timestamp is the same
/// on both sides.
const NOW: u64 = 1_700_000_000;

#[derive(Clone)]
struct Op {
    set: bool,
    format: Format,
    sec: String,
    key: String,
    /// Unused by a read.
    val: String,
}

fn get(format: Format, sec: &str, key: &str) -> Op {
    Op {
        set: false,
        format,
        sec: sec.into(),
        key: key.into(),
        val: String::new(),
    }
}

fn set(format: Format, sec: &str, key: &str, val: &str) -> Op {
    Op {
        set: true,
        val: val.into(),
        ..get(format, sec, key)
    }
}

/// A starting file (`None`: no file) and the calls made on it in order.
struct Scenario {
    name: String,
    input: Option<Vec<u8>>,
    ops: Vec<Op>,
}

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

const DRIVER: &str = r#"
for f in globals ui common game-config; do source "$SRC/$f.sh"; done
for d in "$@"; do
    f="$d/f"
    [ -f "$d/in" ] && cp "$d/in" "$f"
    j=0
    while IFS=$'\x1f' read -r -u 3 kind fmt sec key val; do
        if [ "$kind" == "get" ]; then
            config_get_key "$f" "$fmt" "$sec" "$key" > "$d/out.$j" 2>/dev/null
        else
            config_set_key "$f" "$fmt" "$sec" "$key" "$val" >/dev/null 2>&1
            echo $? > "$d/rc.$j"
            [ -f "$f" ] && cp "$f" "$d/f.$j"
        fi
        j=$((j + 1))
    done 3< "$d/ops"
done
"#;

/// Runs every scenario through the Bash functions, leaving each one's results
/// in its own folder under `root`.
fn run_bash(root: &Path, scenarios: &[Scenario]) -> Vec<PathBuf> {
    let bin = root.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    let date = bin.join("date");
    std::fs::write(&date, format!("#!/bin/sh\necho {NOW}\n")).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&date, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let dirs: Vec<PathBuf> = scenarios
        .iter()
        .enumerate()
        .map(|(i, s)| {
            let dir = root.join(format!("case{i}"));
            std::fs::create_dir(&dir).unwrap();
            if let Some(input) = &s.input {
                std::fs::write(dir.join("in"), input).unwrap();
            }
            let mut ops = String::new();
            for op in &s.ops {
                for text in [&op.sec, &op.key, &op.val] {
                    assert!(
                        !text.contains(['\n', '\x1f']),
                        "{}: an argument can't hold a line break",
                        s.name
                    );
                }
                let kind = if op.set { "set" } else { "get" };
                let name = op.format.name();
                writeln!(
                    ops,
                    "{kind}\x1f{name}\x1f{}\x1f{}\x1f{}",
                    op.sec, op.key, op.val
                )
                .unwrap();
            }
            std::fs::write(dir.join("ops"), ops).unwrap();
            dir
        })
        .collect();

    let jobs = std::thread::available_parallelism().map_or(2, |n| n.get());
    let per_job = dirs.len().div_ceil(jobs).max(1);
    let path = format!(
        "{}:{}",
        bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );
    std::thread::scope(|scope| {
        for chunk in dirs.chunks(per_job) {
            let path = &path;
            scope.spawn(move || {
                let status = Command::new("bash")
                    .arg("-c")
                    .arg(DRIVER)
                    .arg("oracle")
                    .args(chunk)
                    .env("SRC", repo_root().join("src"))
                    .env("PATH", path)
                    .env("HOME", root)
                    .env("LC_ALL", "C.UTF-8")
                    .status()
                    .expect("bash runs");
                assert!(status.success(), "the Bash driver failed");
            });
        }
    });
    dirs
}

fn show(bytes: Option<&[u8]>) -> String {
    match bytes {
        None => "(no file)".into(),
        Some(b) => format!("{:?}", String::from_utf8_lossy(b)),
    }
}

/// Runs the scenarios through both and panics with the first differences.
fn compare(scenarios: Vec<Scenario>) {
    assert!(!scenarios.is_empty());
    let tmp = tempfile::tempdir().unwrap();
    let dirs = run_bash(tmp.path(), &scenarios);
    let mut failures: Vec<String> = Vec::new();
    let mut checked = 0;
    for (s, dir) in scenarios.iter().zip(&dirs) {
        let file = dir.join("rust");
        if let Some(input) = &s.input {
            std::fs::write(&file, input).unwrap();
        }
        for (j, op) in s.ops.iter().enumerate() {
            checked += 1;
            let call = format!(
                "{} #{j} {} {} [{}] {} = {:?}\n  input: {}",
                s.name,
                if op.set { "set" } else { "get" },
                op.format.name(),
                op.sec,
                op.key,
                op.val,
                show(s.input.as_deref())
            );
            if !op.set {
                let mut rust = config::get_file(&file, op.format, &op.sec, &op.key)
                    .as_bytes()
                    .to_vec();
                rust.push(b'\n');
                let bash = std::fs::read(dir.join(format!("out.{j}"))).unwrap();
                if rust != bash {
                    failures.push(format!(
                        "{call}\n  bash: {}\n  rust: {}",
                        show(Some(&bash)),
                        show(Some(&rust))
                    ));
                    break;
                }
                continue;
            }
            let value = Value::text(&op.val);
            let rust_ok =
                config::set_file_at(&file, op.format, &op.sec, &op.key, &value, NOW).is_ok();
            let rc = std::fs::read_to_string(dir.join(format!("rc.{j}"))).unwrap();
            let bash_ok = rc.trim() == "0";
            let bash = std::fs::read(dir.join(format!("f.{j}"))).ok();
            let rust = std::fs::read(&file).ok();
            if rust_ok != bash_ok || rust != bash {
                failures.push(format!(
                    "{call}\n  bash: ok={bash_ok} {}\n  rust: ok={rust_ok} {}",
                    show(bash.as_deref()),
                    show(rust.as_deref())
                ));
                // The two files differ from here on, so the rest says nothing.
                break;
            }
        }
    }
    assert!(
        failures.is_empty(),
        "{} of {} scenarios differ ({checked} calls checked). The first:\n\n{}",
        failures.len(),
        scenarios.len(),
        failures
            .iter()
            .take(8)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n\n")
    );
}

// ---- the bats tests' own cases -----------------------------------------------

/// `printf '%b'` escapes, as `write_file` in tests/helpers.bash expands them.
fn printf_b(text: &str) -> Option<Vec<u8>> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i] != b'\\' || i + 1 == b.len() {
            out.push(b[i]);
            i += 1;
            continue;
        }
        i += 1;
        match b[i] {
            b'n' => out.push(b'\n'),
            b'r' => out.push(b'\r'),
            b't' => out.push(b'\t'),
            b'\\' => out.push(b'\\'),
            b'x' => {
                let hex = std::str::from_utf8(b.get(i + 1..i + 3)?).ok()?;
                out.push(u8::from_str_radix(hex, 16).ok()?);
                i += 2;
            }
            b'0'..=b'7' => {
                let start = if b[i] == b'0' { i + 1 } else { i };
                let len = b[start..]
                    .iter()
                    .take(3)
                    .take_while(|c| (b'0'..=b'7').contains(c))
                    .count();
                let digits = std::str::from_utf8(&b[start..start + len]).ok()?;
                out.push(u8::try_from(u32::from_str_radix(digits, 8).unwrap_or(0)).ok()?);
                i = start + len - 1;
            }
            _ => return None,
        }
        i += 1;
    }
    Some(out)
}

/// The next `count` shell words of `text`, when they are all literal (no
/// variables or substitutions).
fn shell_words(text: &str, count: usize) -> Option<Vec<String>> {
    let b = text.as_bytes();
    let mut i = 0;
    let mut words = Vec::new();
    while words.len() < count {
        while b.get(i) == Some(&b' ') {
            i += 1;
        }
        let mut word: Vec<u8> = Vec::new();
        let mut any = false;
        while let Some(&c) = b.get(i) {
            match c {
                b' ' | b')' | b';' | b'|' | b'&' => break,
                b'\'' => {
                    let end = i + 1 + b[i + 1..].iter().position(|&c| c == b'\'')?;
                    word.extend_from_slice(&b[i + 1..end]);
                    i = end;
                }
                b'"' => {
                    i += 1;
                    loop {
                        match *b.get(i)? {
                            b'"' => break,
                            b'$' | b'`' => return None,
                            b'\\' if matches!(b.get(i + 1), Some(b'"' | b'\\' | b'$')) => {
                                word.push(b[i + 1]);
                                i += 1;
                            }
                            c => word.push(c),
                        }
                        i += 1;
                    }
                }
                b'$' | b'`' | b'\\' => return None,
                c => word.push(c),
            }
            any = true;
            i += 1;
        }
        if !any {
            return None;
        }
        words.push(String::from_utf8(word).ok()?);
    }
    Some(words)
}

/// The cases a bats file makes with `write_file "$F" '...'` followed by
/// `config_get_key "$F" ...` / `config_set_key "$F" ...` calls.
fn bats_scenarios(file: &str) -> Vec<Scenario> {
    let path = repo_root().join("tests/unit").join(file);
    let text = std::fs::read_to_string(&path).unwrap();
    let mut scenarios: Vec<Scenario> = Vec::new();
    // False while the file's content isn't known (written some other way).
    let mut known = false;
    for (n, line) in text.lines().enumerate() {
        let line = line.trim();
        if line.starts_with("@test") {
            known = false;
            continue;
        }
        if let Some(rest) = line.strip_prefix("write_file \"$F\" ") {
            let input = rest
                .strip_prefix('\'')
                .and_then(|r| r.strip_suffix('\''))
                .filter(|r| !r.contains('\''))
                .and_then(printf_b);
            known = input.is_some();
            if known {
                scenarios.push(Scenario {
                    name: format!("{file}:{}", n + 1),
                    input,
                    ops: Vec::new(),
                });
            }
            continue;
        }
        if line.contains("> \"$F\"") || line.contains("rm ") {
            known = false;
            continue;
        }
        if !known {
            continue;
        }
        for (verb, is_set) in [
            ("config_get_key \"$F\" ", false),
            ("config_set_key \"$F\" ", true),
        ] {
            let mut rest = line;
            while let Some(at) = rest.find(verb) {
                rest = &rest[at + verb.len()..];
                let words = shell_words(rest, if is_set { 4 } else { 3 });
                let op = words.and_then(|w| {
                    let format = w[0].parse::<Format>().ok()?;
                    let val = if is_set { w[3].as_str() } else { "" };
                    Some(Op {
                        set: is_set,
                        format,
                        sec: w[1].clone(),
                        key: w[2].clone(),
                        val: val.into(),
                    })
                });
                match op {
                    Some(op) => scenarios.last_mut().unwrap().ops.push(op),
                    // A write this can't replay leaves the file unknown.
                    None if is_set => known = false,
                    None => {}
                }
            }
        }
    }
    scenarios.retain(|s| !s.ops.is_empty());
    scenarios
}

#[test]
fn the_bats_tests_cases_match() {
    let mut scenarios = Vec::new();
    for file in [
        "config-keys.bats",
        "audit-tier2.bats",
        "apply-game-settings.bats",
        "gadb-and-registry.bats",
    ] {
        scenarios.extend(bats_scenarios(file));
    }
    let calls: usize = scenarios.iter().map(|s| s.ops.len()).sum();
    // Guards the extraction: if the bats files change shape and this stops
    // finding their cases, the test must not pass by checking nothing.
    assert!(calls >= 90, "only {calls} calls found in the bats tests");
    compare(scenarios);
}

// ---- a generated corpus of text files ------------------------------------------

/// The same lines with each kind of line ending, with and without a final
/// newline and a BOM.
fn variants(lf: &str) -> Vec<(&'static str, Vec<u8>)> {
    let crlf = lf.replace('\n', "\r\n");
    let mut mixed = String::new();
    for (i, line) in lf.split_inclusive('\n').enumerate() {
        if i % 2 == 0 {
            mixed.push_str(&line.replace('\n', "\r\n"));
        } else {
            mixed.push_str(line);
        }
    }
    let bom = |s: &str| [b"\xEF\xBB\xBF".as_slice(), s.as_bytes()].concat();
    let all = vec![
        ("lf", lf.as_bytes().to_vec()),
        (
            "crlf, no final newline",
            crlf.strip_suffix("\r\n")
                .unwrap_or(&crlf)
                .as_bytes()
                .to_vec(),
        ),
        ("crlf", crlf.as_bytes().to_vec()),
        ("mixed", mixed.into_bytes()),
        (
            "lf, no final newline",
            lf.strip_suffix('\n').unwrap_or(lf).as_bytes().to_vec(),
        ),
        ("bom, lf", bom(lf)),
        ("bom, crlf", bom(&crlf)),
    ];
    let mut seen = HashSet::new();
    all.into_iter()
        .filter(|(_, bytes)| seen.insert(bytes.clone()))
        .collect()
}

struct Family {
    format: Format,
    files: &'static [&'static str],
    secs: &'static [&'static str],
    keys: &'static [&'static str],
}

const FAMILIES: &[Family] = &[
    Family {
        format: Format::Ini,
        files: &[
            "[General]\nChannels = stereo\nUseEAX=0\n\n[Other]\nchannels=quad\n; note\nPath= C:/x\n\n\n[Empty]\n",
            "top=1\nSound = on\n[general] ; main\n  UseEAX\t=\t1  \nnot a pair\n[general]\nuseeax=2\n\n",
            "",
            "\n\n",
            "[general]\n[other]\nk=v\n  \n\t\n",
        ],
        secs: &["general", "Other", "Missing", ""],
        keys: &["UseEAX", "channels", "nokey", "top"],
    },
    Family {
        format: Format::IniBraces,
        files: &[
            "[prefs]\n{\n\tblood = red;\n\tsound=on ;  \n\tx = 1\n}\n\n[other]\n{\n}\n",
            "[prefs]\n{\n\tblood = red;\n",
            "",
            "[prefs] // c\n{\n  Blood=blue;;\n}\ntext\n",
        ],
        secs: &["prefs", "PREFS", "other", "missing"],
        keys: &["blood", "sound", "x", "new"],
    },
    Family {
        format: Format::SetCommands,
        files: &[
            "seta s_volume \"0.8\"\nset  s_useEAX   1\n// comment\nSETA Name \"two words\"\nbind x \"y\"\nseta s_volume \"0.5\"\n",
            "set a\nseta\nseta  b\t\"\"\nsetab 1\n  seta c 3 \n",
            "",
        ],
        secs: &[""],
        keys: &["s_volume", "S_USEEAX", "name", "a", "b", "c", "missing"],
    },
    Family {
        format: Format::KeyValue,
        files: &[
            "snd_vol 3\n; snd_efx on\nfullscreen\n;eax\n  ; eax\nSND_TARGETS  5 1\n",
            "; eax\neax\nother\n; flag\nflag on\nflag off\n",
            "",
            "eax\n;eax\neax 1\n",
        ],
        secs: &[""],
        keys: &["snd_vol", "snd_efx", "fullscreen", "eax", "flag", "snd_targets", "missing"],
    },
    Family {
        format: Format::QuotedPairs,
        files: &[
            "\"MusicVolume\" \"50.0\"\n\"3dsoundprovider\"\t\"0\"\n  \"Renderer\" \"Primary Display Driver\"  \nplain line\n\"bare\"\n\"k\" v w\n",
            "",
        ],
        secs: &[""],
        keys: &["musicvolume", "3dsoundprovider", "Renderer", "bare", "k", "missing"],
    },
    Family {
        format: Format::BracedPairs,
        files: &[
            "{Sound} = {1}\n{ Music Volume } = { 50 } \n{eax}={0} trailing\nnot\n{open} = {x\n",
            "",
        ],
        secs: &[""],
        keys: &["sound", "music volume", "eax", "open", "missing"],
    },
    Family {
        format: Format::XmlAttributes,
        files: &[
            "<?xml version=\"1.0\"?>\n<Config>\n  <Sound UseEAX=\"1\" NumBuffers=\"8\"/>\n  <SoundFX Vol = \"3\" >\n  <Video a=\"1\"><Sound2/></Video> <sound useeax=\"0\" />\n<Open x=\"1\"\n</Config>\n",
            "",
        ],
        secs: &["Sound", "soundfx", "Video", "Sound2", "Config", "Open", "Missing"],
        keys: &["UseEAX", "numbuffers", "Vol", "a", "new"],
    },
];

const VALUES: [&str; 8] = [
    "quad",
    "__DELETE__",
    "",
    "two words",
    "__TRUE__",
    "__FALSE__",
    "7",
    // awk -v would read these as escapes; the script passes values another way.
    "C:\\Games\\new\\t",
];

/// One family's cases: a read of every key in every variant of every file,
/// and for each value a write followed by a write of what was there before.
fn corpus(family: &Family) -> Vec<Scenario> {
    let mut scenarios = Vec::new();
    for (f, file) in family.files.iter().enumerate() {
        for (v, (variant, input)) in variants(file).into_iter().enumerate() {
            for sec in family.secs {
                for key in family.keys {
                    let name = format!("{} file {f} ({variant})", family.format.name());
                    scenarios.push(Scenario {
                        name: name.clone(),
                        input: Some(input.clone()),
                        ops: vec![get(family.format, sec, key)],
                    });
                    // What a revert would write: the value there now, or a
                    // removal when there is none.
                    let before = match config::get(family.format, &input, sec, key) {
                        Value::Absent => Value::Delete,
                        other => other,
                    };
                    let before = String::from_utf8(before.as_bytes().to_vec()).unwrap();
                    // Every value on the first two variants, two on the rest.
                    let values = if v < 2 { &VALUES[..] } else { &VALUES[..2] };
                    for val in values {
                        scenarios.push(Scenario {
                            name: name.clone(),
                            input: Some(input.clone()),
                            ops: vec![
                                set(family.format, sec, key, val),
                                get(family.format, sec, key),
                                set(family.format, sec, key, &before),
                            ],
                        });
                    }
                }
            }
        }
    }
    scenarios
}

macro_rules! corpus_test {
    ($name:ident, $format:expr) => {
        #[test]
        fn $name() {
            let family = FAMILIES.iter().find(|f| f.format == $format).unwrap();
            compare(corpus(family));
        }
    };
}

corpus_test!(corpus_ini, Format::Ini);
corpus_test!(corpus_ini_braces, Format::IniBraces);
corpus_test!(corpus_set_commands, Format::SetCommands);
corpus_test!(corpus_key_value, Format::KeyValue);
corpus_test!(corpus_quoted_pairs, Format::QuotedPairs);
corpus_test!(corpus_braced_pairs, Format::BracedPairs);
corpus_test!(corpus_xml_attributes, Format::XmlAttributes);

#[test]
fn a_missing_file_and_a_utf16_file_match() {
    let mut scenarios = Vec::new();
    for format in Format::ALL {
        scenarios.push(Scenario {
            name: format!("{} with no file", format.name()),
            input: None,
            ops: vec![
                get(format, "Sound", "4"),
                set(format, "Sound", "4", "1"),
                get(format, "Sound", "4"),
            ],
        });
        if format.is_text() {
            scenarios.push(Scenario {
                name: format!("{} on UTF-16 text", format.name()),
                input: Some(b"\xFF\xFEk\0=\x001\0\r\0\n\0".to_vec()),
                ops: vec![get(format, "", "k"), set(format, "", "k", "2")],
            });
        }
    }
    compare(scenarios);
}

// ---- the binary formats --------------------------------------------------------

#[test]
fn binary_offset_matches() {
    let input: Vec<u8> = (0u8..16).map(|b| b.wrapping_mul(17)).collect();
    let mut scenarios = Vec::new();
    for key in [
        "0", "4", "0x0f", "0X0F", "16", "0x10", "abc", "007", "0x", "-1", "",
    ] {
        for val in ["0", "255", "256", "x", "7", "007", "", "__DELETE__"] {
            scenarios.push(Scenario {
                name: "binary_offset".into(),
                input: Some(input.clone()),
                ops: vec![
                    get(Format::BinaryOffset, "", key),
                    set(Format::BinaryOffset, "", key, val),
                    get(Format::BinaryOffset, "", key),
                ],
            });
        }
    }
    compare(scenarios);
}

/// Bytes, the anchor, a 4-byte length, the text, then the bytes after it.
fn text_file(before: &[u8], text: &[u8], after: &[u8]) -> Vec<u8> {
    let mut out = before.to_vec();
    out.extend_from_slice(&[0x00, 0x00, 0x80, 0x3f]);
    out.extend_from_slice(&(text.len() as u32).to_le_bytes());
    out.extend_from_slice(text);
    out.extend_from_slice(after);
    out
}

#[test]
fn binary_text_matches() {
    let files = [
        text_file(
            b"\x01\x02\x03",
            b"Creative Labs EAX 2 (TM)",
            b"\x07\x00\x02\x09",
        ),
        // A stray copy of the anchor in front of a length that is too large.
        text_file(
            b"\x00\x00\x80\x3f\xff\xff\xff\x7f",
            b"Miles Fast 2D",
            b"\x05",
        ),
        // The text is not printable, and one that runs past the end.
        text_file(b"", b"a\x01b", b"\x00"),
        b"\x00\x00\x80\x3f\x09\x00\x00\x00abc".to_vec(),
        Vec::new(),
    ];
    let long = "x".repeat(65);
    let max = "y".repeat(64);
    let mut scenarios = Vec::new();
    for file in &files {
        for key in [
            "0000803f",
            "0000803F",
            "0000803f+0",
            "0000803f+2",
            "0000803f+3",
            "0000803f+99999",
            "0000803f+x",
            "ffff",
            "0000803",
            "",
        ] {
            for val in [
                "Miles Fast 2D",
                "A",
                max.as_str(),
                long.as_str(),
                "bad/char",
                "",
                "3",
                "255",
                "300",
            ] {
                scenarios.push(Scenario {
                    name: "binary_text".into(),
                    input: Some(file.clone()),
                    ops: vec![
                        get(Format::BinaryText, "", key),
                        set(Format::BinaryText, "", key, val),
                        get(Format::BinaryText, "", key),
                        get(Format::BinaryText, "", "0000803f+0"),
                    ],
                });
            }
        }
    }
    compare(scenarios);
}

/// A GADB file like `make_gadb` in tests/helpers.bash builds: header, string
/// table, then one record per (name's offset, type, count, value).
fn gadb(names: &[&str], records: &[(u32, u32, u32, u32)]) -> Vec<u8> {
    let mut table = Vec::new();
    for name in names {
        table.extend_from_slice(name.as_bytes());
        table.push(0);
    }
    let mut out = b"GADB\0\0\0\0".to_vec();
    out.extend_from_slice(&(table.len() as u32).to_le_bytes());
    out.extend_from_slice(&[0; 16]);
    out.extend_from_slice(&table);
    while !out.len().is_multiple_of(4) {
        out.push(0);
    }
    for (name_at, kind, count, value) in records {
        for n in [*name_at, *kind, 0, *count, *value] {
            out.extend_from_slice(&n.to_le_bytes());
        }
    }
    out
}

#[test]
fn binary_switches_matches() {
    let names = ["UseEAX", "HWSound", "Volume", "Twice"];
    let good = gadb(
        &names,
        &[
            (0, 1, 1, 0),
            (7, 1, 1, 1),
            // Not an on/off record: another type, and a count of two.
            (15, 2, 1, 80),
            (22, 1, 1, 0),
            (22, 1, 1, 1),
        ],
    );
    let mut cut = good.clone();
    cut.truncate(good.len() - 30);
    let mut bad_table = good.clone();
    bad_table[8..12].copy_from_slice(&9999u32.to_le_bytes());
    let files = [
        good,
        cut,
        bad_table,
        b"NOPE\0\0\0\0".to_vec(),
        gadb(&["A"], &[(0, 1, 1, 7)]),
        Vec::new(),
    ];
    let mut scenarios = Vec::new();
    for file in &files {
        for key in [
            "UseEAX", "useeax", "HWSound", "Volume", "Twice", "A", "Missing", "",
        ] {
            for val in ["0", "1", "2", "", "01", "__DELETE__"] {
                scenarios.push(Scenario {
                    name: "binary_switches".into(),
                    input: Some(file.clone()),
                    ops: vec![
                        get(Format::BinarySwitches, "", key),
                        set(Format::BinarySwitches, "", key, val),
                        get(Format::BinarySwitches, "", key),
                    ],
                });
            }
        }
    }
    compare(scenarios);
}

// ---- the registry --------------------------------------------------------------

const REG: &str = r#"WINE REGISTRY Version 2
;; All keys relative to \\Machine

#arch=win64

[Software\\Wow6432Node\\Outrage\\Descent3] 1700000001
#time=1dc0000000000aa
"SoundMixer"=dword:00000002
"SoundcardName"="Primary Sound Driver"
"Path"="C:\\Games\\D3 \"Gold\""
"Blob"=hex:01,02,03
@="default"

[Software\\Vendor\\Game] 1700000002
#time=1dc0000000000bb
"EAX"=dword:0000000a
"Big"=dword:ffffffff


[Software\\Empty] 1700000003
"#;

#[test]
fn registry_matches() {
    let f = Format::Registry;
    let d3 = "Software\\Wow6432Node\\Outrage\\Descent3";
    // The same key as the database would name it for the other registry view.
    let d3_other_view = "Software\\Outrage\\Descent3";
    let game = "software\\vendor\\game";
    let game_other_view = "Software\\Wow6432Node\\Vendor\\Game";
    let mut cases: Vec<(&str, &str, &str)> = Vec::new();
    for sec in [d3, d3_other_view] {
        cases.extend([
            (sec, "SoundMixer", "6"),
            (sec, "soundmixer", "abc"),
            (sec, "SoundMixer", "4294967295"),
            (sec, "SoundMixer", "4294967296"),
            (sec, "SoundMixer", "007"),
            (sec, "SoundMixer", "__DELETE__"),
            (sec, "SoundcardName", "Creative EAX"),
            (sec, "SoundcardName", "12"),
            (sec, "SoundcardName", "say \"hi\" in C:\\dir"),
            (sec, "SoundcardName", ""),
            (sec, "Path", "__DELETE__"),
            (sec, "Blob", "1"),
            (sec, "Blob", "__DELETE__"),
            (sec, "NewNumber", "3"),
            (sec, "NewText", "three"),
            (sec, "Missing", "__DELETE__"),
        ]);
    }
    cases.extend([
        (game, "EAX", "1"),
        (game, "Big", "0"),
        (game, "New", "1"),
        (game_other_view, "EAX", "1"),
        ("Software\\Empty", "New", "text"),
        ("Software\\Empty", "New", "5"),
        ("Software\\Brand New\\Key", "Value", "1"),
        ("Software\\Brand New\\Key", "Value", "text"),
        ("Software\\Brand New\\Key", "Value", "__DELETE__"),
        ("Software\\Wow6432Node\\Brand New", "Value", "1"),
        ("Other\\Root", "Value", "1"),
    ]);
    let crlf = REG.replace('\n', "\r\n");
    let inputs = [
        REG.as_bytes().to_vec(),
        REG.trim_end().as_bytes().to_vec(),
        // Wine writes \n; with \r\n a value's type isn't recognised.
        crlf.into_bytes(),
        Vec::new(),
    ];
    let mut scenarios = Vec::new();
    for input in &inputs {
        for (sec, key, val) in &cases {
            scenarios.push(Scenario {
                name: "registry".into(),
                input: Some(input.clone()),
                ops: vec![
                    get(f, sec, key),
                    set(f, sec, key, val),
                    get(f, sec, key),
                    set(f, sec, key, "__DELETE__"),
                    get(f, sec, key),
                ],
            });
        }
    }
    compare(scenarios);
}

// ---- every setting in the database -----------------------------------------------

/// The database's value as the script spells it: true / false / null become
/// the markers.
fn marker(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Bool(true) => "__TRUE__".into(),
        serde_json::Value::Bool(false) => "__FALSE__".into(),
        serde_json::Value::Null => "__DELETE__".into(),
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// Every (format, section, key, value) the database asks for, once.
fn database_rows() -> Vec<(Format, String, String, String)> {
    let text = std::fs::read_to_string(repo_root().join("game-database.json")).unwrap();
    let db: serde_json::Value = serde_json::from_str(&text).unwrap();
    let mut rows = Vec::new();
    let mut seen = HashSet::new();
    for game in db["games"].as_array().unwrap() {
        let cfg = &game["game_config"];
        let settings = ["audio_settings", "optional_settings"]
            .into_iter()
            .filter_map(|k| cfg[k].as_array())
            .flatten();
        for setting in settings {
            let Some(changes) = setting["changes"].as_object() else {
                continue;
            };
            for (file, keys) in changes {
                let format: Format = cfg["files"][file]["format"]
                    .as_str()
                    .unwrap_or_default()
                    .parse()
                    .unwrap_or_else(|e| panic!("{}: {e}", game["name"]));
                for (name, value) in keys.as_object().unwrap() {
                    let flat = match value.as_object() {
                        Some(inner) => inner
                            .iter()
                            .map(|(k, v)| (name.clone(), k.clone(), marker(v)))
                            .collect(),
                        None => vec![(String::new(), name.clone(), marker(value))],
                    };
                    for (sec, key, val) in flat {
                        if seen.insert((format, sec.clone(), key.clone(), val.clone())) {
                            rows.push((format, sec, key, val));
                        }
                    }
                }
            }
        }
    }
    rows
}

#[test]
fn every_database_setting_applies_and_reverts_the_same() {
    let rows = database_rows();
    assert!(rows.len() > 100, "only {} settings found", rows.len());
    let mut scenarios = Vec::new();
    for (format, sec, key, val) in &rows {
        assert!(
            config::row_is_safe(*format, "game_exe:file", sec, key, val)
                || *format == Format::Registry
                    && config::row_is_safe(*format, "prefix:user.reg", sec, key, val),
            "the database has a row the safety check refuses: {} [{sec}] {key} = {val}",
            format.name()
        );
        // A starting file the change can land in: the binary formats only
        // change what is already there, and are covered by their own tests.
        let (input, other): (Vec<u8>, &str) = match format {
            Format::BinaryOffset | Format::BinaryText | Format::BinarySwitches => continue,
            Format::XmlAttributes => (
                format!("<Root>\n  <{sec} Other=\"x\"/>\n</Root>\n").into(),
                "0",
            ),
            Format::Registry => (b"WINE REGISTRY Version 2\n\n".to_vec(), "0"),
            Format::KeyValue => (b"other 1\r\n".to_vec(), "__FALSE__"),
            _ => (b"other=1\r\n".to_vec(), "0"),
        };
        scenarios.push(Scenario {
            name: "database row".into(),
            input: Some(input),
            ops: vec![
                // Into a file without the key, to another value, and out again.
                get(*format, sec, key),
                set(*format, sec, key, val),
                get(*format, sec, key),
                set(*format, sec, key, other),
                get(*format, sec, key),
                set(*format, sec, key, val),
                set(*format, sec, key, "__DELETE__"),
                get(*format, sec, key),
            ],
        });
    }
    compare(scenarios);
}
