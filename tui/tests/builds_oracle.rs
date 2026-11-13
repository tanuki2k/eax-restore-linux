//! Parity with the Bash script for getting DSOAL and OpenAL Soft into the
//! cache. A stub curl serves fake GitHub pages and zips from a folder; the
//! script (`lookup_build_versions`, `ensure_dsoal_build`,
//! `ensure_openal_build`) and the Rust engine each get their own home folder
//! and the same answers, and their labels, results, downloads and caches
//! must match.

use eax_restore::engine::builds::{self, Build, Cache, Curl, Pins};
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// Serves `$STUB_ROOT/<url, with every other character than a letter or
/// digit as _>`; `<name>.head` for a header request. Logs every call.
const STUB_CURL: &str = r#"#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
[ -n "${STUB_OFFLINE:-}" ] && exit 6
head=0 fail=0 out="" url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -m|--connect-timeout|--max-time|--speed-limit|--speed-time) shift ;;
        http*) url="$1" ;;
        --*) ;;
        -*) [[ "$1" == *I* ]] && head=1; [[ "$1" == *f* ]] && fail=1 ;;
    esac
    shift
done
name="$(printf '%s' "$url" | sed 's/[^A-Za-z0-9]/_/g')"
if [ "$head" -eq 1 ]; then
    [ -f "$STUB_ROOT/$name.head" ] && cat "$STUB_ROOT/$name.head"
    exit 0
fi
if [ -f "$STUB_ROOT/$name" ]; then
    if [ -n "$out" ]; then cp "$STUB_ROOT/$name" "$out"; else cat "$STUB_ROOT/$name"; fi
    exit 0
fi
[ "$fail" -eq 1 ] && exit 22
echo "Not Found"
"#;

fn url_file(root: &Path, url: &str) -> PathBuf {
    let name: String = url
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    root.join(name)
}

/// A zip with these (path, text) entries, made with Python's zipfile.
fn zip(dest: &Path, entries: &[(&str, &[u8])]) {
    let dir = dest.with_extension("parts");
    std::fs::create_dir_all(&dir).unwrap();
    let mut args = Vec::new();
    for (i, (name, data)) in entries.iter().enumerate() {
        let f = dir.join(i.to_string());
        std::fs::write(&f, data).unwrap();
        args.push(format!("{}={}", f.display(), name));
    }
    let status = Command::new("python3")
        .arg("-I")
        .arg("-c")
        .arg(
            "import sys, zipfile\n\
             with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:\n\
             \x20   for a in sys.argv[2:]:\n\
             \x20       src, name = a.split('=', 1)\n\
             \x20       z.write(src, name)\n",
        )
        .arg(dest)
        .args(&args)
        .status()
        .unwrap();
    assert!(status.success());
    std::fs::remove_dir_all(dir).unwrap();
}

fn sha(path: &Path) -> String {
    builds::sha256_of(path).unwrap()
}

/// The fake GitHub. Every switch is one way the real one can be.
#[derive(Clone, Copy, Default)]
struct Github {
    offline: bool,
    /// latest-master is missing, so the archive release is followed.
    no_latest_master: bool,
    /// The published digests are wrong.
    bad_digests: bool,
    /// No digests are published.
    no_digests: bool,
    /// The downloads are not zips.
    corrupt: bool,
    /// kcat's DSOAL zip wraps another DSOAL_*.zip.
    nested: bool,
}

const PIN_URL: &str = "https://example.test/archive/DSOAL_r693.zip";
const TAG: &str = "1.24.3";

/// Writes the fake GitHub into `root` and returns the pins to use.
fn serve(root: &Path, g: Github) -> Pins {
    std::fs::create_dir_all(root).unwrap();
    let work = root.join(".work");
    std::fs::create_dir_all(&work).unwrap();
    let dsoal_zip = |path: &Path, tag: &str| {
        let files: Vec<(String, Vec<u8>)> = [
            "DSOAL/Win32",
            "DSOAL/Win64",
            "DSOAL+HRTF/Win32",
            "DSOAL+HRTF/Win64",
        ]
        .iter()
        .flat_map(|d| {
            [
                (
                    format!("{d}/dsound.dll"),
                    format!("dsound {tag} {d}").into_bytes(),
                ),
                (
                    format!("{d}/dsoal-aldrv.dll"),
                    format!("aldrv {tag} {d}").into_bytes(),
                ),
            ]
        })
        .collect();
        let entries: Vec<(&str, &[u8])> = files
            .iter()
            .map(|(n, d)| (n.as_str(), d.as_slice()))
            .collect();
        if g.nested {
            let inner = work.join(format!("DSOAL_{tag}.zip"));
            zip(&inner, &entries);
            let data = std::fs::read(&inner).unwrap();
            zip(
                path,
                &[
                    (&format!("DSOAL_{tag}.zip"), &data),
                    ("README.txt", b"readme"),
                ],
            );
        } else {
            zip(path, &entries);
        }
    };
    let put = |url: &str, from: &Path| {
        if g.corrupt {
            std::fs::write(url_file(root, url), b"<html>not a zip</html>").unwrap();
        } else {
            std::fs::copy(from, url_file(root, url)).unwrap();
        }
    };
    let digest = |path: &Path| {
        if g.no_digests {
            serde_json::Value::Null
        } else if g.bad_digests {
            serde_json::json!(format!("sha256:{}", "0".repeat(64)))
        } else {
            serde_json::json!(format!("sha256:{}", sha(path)))
        }
    };
    if !g.offline {
        std::fs::write(url_file(root, builds::GITHUB_PROBE_URL), "{}").unwrap();
    }

    // DSOAL: the pinned build, latest-master, and the archive release.
    let pinned = work.join("pinned.zip");
    dsoal_zip(&pinned, "r693");
    put(PIN_URL, &pinned);
    let latest = work.join("latest.zip");
    dsoal_zip(&latest, "r701");
    put(builds::DSOAL_OFFICIAL_URL, &latest);
    if !g.no_latest_master {
        let json = serde_json::json!({
            "name": "DSOAL r701 (latest-master)",
            "updated_at": "2026-11-01T12:00:00Z",
            "assets": [{"name": "DSOAL.zip", "digest": digest(&latest)}]
        });
        std::fs::write(
            url_file(root, builds::DSOAL_OFFICIAL_API_URL),
            json.to_string(),
        )
        .unwrap();
    }
    let a699 = work.join("a699.zip");
    dsoal_zip(&a699, "r699");
    let a700 = work.join("a700.zip");
    dsoal_zip(&a700, "r700");
    let arch_url =
        |r: &str| format!("https://github.com/kcat/dsoal/releases/download/archive/DSOAL_{r}.zip");
    put(&arch_url("r699"), &a699);
    put(&arch_url("r700"), &a700);
    let archive = serde_json::json!({"assets": [
        {"name": "DSOAL_r699.zip", "browser_download_url": arch_url("r699"), "digest": digest(&a699)},
        {"name": "DSOAL_r700.zip", "browser_download_url": arch_url("r700"), "digest": digest(&a700)},
        {"name": "DSOAL_r9x.zip", "browser_download_url": "https://x"},
        {"name": "notes.txt"}
    ]});
    std::fs::write(
        url_file(root, builds::DSOAL_ARCHIVE_API_URL),
        archive.to_string(),
    )
    .unwrap();

    // OpenAL Soft: the tagged release (found by its redirect) and the pre-release.
    let stable = work.join("oal.zip");
    zip(
        &stable,
        &[
            (
                &format!("openal-soft-{TAG}-bin/bin/Win32/soft_oal.dll"),
                b"soft_oal 32",
            ),
            (
                &format!("openal-soft-{TAG}-bin/bin/Win64/soft_oal.dll"),
                b"soft_oal 64",
            ),
        ],
    );
    let asset = format!("openal-soft-{TAG}-bin.zip");
    put(
        &format!("https://github.com/kcat/openal-soft/releases/download/{TAG}/{asset}"),
        &stable,
    );
    std::fs::write(
        url_file(root, builds::OPENAL_LATEST_RELEASE_URL).with_extension("head"),
        format!("HTTP/2 302\r\nlocation: https://github.com/kcat/openal-soft/releases/tag/{TAG}\r\n\r\n"),
    )
    .unwrap();
    let tag_json = serde_json::json!({"assets": [{"name": asset, "digest": digest(&stable)}]});
    std::fs::write(
        url_file(
            root,
            &format!("https://api.github.com/repos/kcat/openal-soft/releases/tags/{TAG}"),
        ),
        tag_json.to_string(),
    )
    .unwrap();
    let pre = work.join("pre.zip");
    zip(
        &pre,
        &[
            ("Win32/OpenAL32.dll", b"OpenAL32 pre 32"),
            ("Win64/OpenAL32.dll", b"OpenAL32 pre 64"),
        ],
    );
    let pre_url = "https://github.com/kcat/openal-soft/releases/download/latest/OpenALSoft.zip";
    put(pre_url, &pre);
    let pre_json = serde_json::json!({"name": "OpenAL Soft v1.24.3-git", "assets": [{
        "name": "OpenALSoft.zip", "browser_download_url": pre_url,
        "updated_at": "2026-11-02T08:00:00Z", "digest": digest(&pre)}]});
    std::fs::write(
        url_file(root, builds::OPENAL_PRERELEASE_API_URL),
        pre_json.to_string(),
    )
    .unwrap();

    Pins {
        dsoal_rev: "r693".into(),
        dsoal_url: PIN_URL.into(),
        dsoal_sha256: sha(&pinned),
    }
}

/// One run of the two downloads on each side.
#[derive(Clone, Copy)]
struct Case {
    name: &'static str,
    github: Github,
    dsoal: Build,
    oal: Build,
    /// The answer to "install it without a checksum?".
    accept_unverified: bool,
    /// Runs first, with everything published and correct, to fill the cache.
    seed: Option<(Build, Build)>,
    /// A wrong pinned SHA256.
    bad_pin: bool,
}

fn build_name(b: Build) -> &'static str {
    match b {
        Build::Stable => "stable",
        Build::Latest => "latest",
    }
}

/// Every file under the cache, as (path, text).
fn tree(dir: &Path) -> Vec<(String, String)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let p = e.path();
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                out.push((
                    p.strip_prefix(root).unwrap().display().to_string(),
                    String::from_utf8_lossy(&std::fs::read(&p).unwrap()).into_owned(),
                ));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out
}

/// The zips one side fetched, from the stub's log.
fn downloads(log: &Path) -> Vec<String> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter(|l| l.contains(" -o ") && !l.contains("/dev/null"))
        .filter_map(|l| {
            l.split_whitespace()
                .find(|w| w.starts_with("http"))
                .map(str::to_string)
        })
        .collect()
}

const BASH_RUN: &str = r#"
for f in globals ui common logging cache verify; do source "$REPO/src/$f.sh"; done
export HOME="$1"; source "$REPO/src/globals.sh"
DSOAL_PINNED_REV=r693 DSOAL_PINNED_URL="$PIN_URL" DSOAL_PINNED_SHA256="$PIN_SHA"
mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"
GITHUB_REACHABLE=0; curl -s -o /dev/null -m 10 "$GITHUB_PROBE_URL" && GITHUB_REACHABLE=1
lookup_build_versions
printf '%s|%s|%s|%s\n' "$DSOAL_STABLE_LABEL" "$DSOAL_LATEST_LABEL" "$OAL_STABLE_LABEL" "$OAL_LATEST_LABEL" > "$1/labels"
if ensure_dsoal_build "$DSOAL_WANT" > /dev/null 2>&1; then echo 1; else echo 0; fi > "$1/dsoal"
if ensure_openal_build "$OAL_WANT" > /dev/null 2>&1; then echo 1; else echo 0; fi > "$1/oal"
"#;

#[allow(clippy::too_many_arguments)]
fn run_bash(
    home: &Path,
    stub_dir: &Path,
    root: &Path,
    pins: &Pins,
    c: &Case,
    d: Build,
    o: Build,
    offline: bool,
) {
    std::fs::create_dir_all(home).unwrap();
    let answer = if c.accept_unverified {
        "y\ny\ny\n"
    } else {
        "n\nn\nn\n"
    };
    std::fs::write(home.join(".answers"), answer).unwrap();
    let out = Command::new("bash")
        .arg("-c")
        .arg(BASH_RUN)
        .arg("bash")
        .arg(home)
        .env("REPO", repo_root())
        .env(
            "PATH",
            format!("{}:{}", stub_dir.display(), std::env::var("PATH").unwrap()),
        )
        .env("STUB_ROOT", root)
        .env("STUB_LOG", home.join(".curl.log"))
        .env("STUB_OFFLINE", if offline { "1" } else { "" })
        .env("PIN_URL", &pins.dsoal_url)
        .env("PIN_SHA", &pins.dsoal_sha256)
        .env("DSOAL_WANT", build_name(d))
        .env("OAL_WANT", build_name(o))
        .env("EAX_RESTORE_NO_LOG", "1")
        .env("TERM", "dumb")
        .stdin(std::fs::File::open(home.join(".answers")).unwrap())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

/// The Rust side; returns (labels, dsoal usable, openal usable).
fn run_rust(
    home: &Path,
    stub: &Path,
    pins: &Pins,
    c: &Case,
    d: Build,
    o: Build,
) -> (String, bool, bool) {
    let cache = Cache::new(home);
    let mut net = Curl {
        program: stub.to_path_buf(),
    };
    let github = builds::Net::reachable(&mut net);
    let mut v = builds::lookup(&cache, &mut net, github, pins);
    let labels = format!(
        "{}|{}|{}|{}",
        v.dsoal_stable, v.dsoal_latest, v.oal_stable, v.oal_latest
    );
    let answer = c.accept_unverified;
    let mut confirm = |_: &str| answer;
    let dg = builds::ensure_dsoal(&cache, &mut net, &mut v, d, pins, &mut confirm);
    let og = builds::ensure_openal(&cache, &mut net, &v, o, &mut confirm);
    (labels, dg.usable(), og.usable())
}

fn compare(c: Case) {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let stub_dir = t.join("bin");
    std::fs::create_dir_all(&stub_dir).unwrap();
    let stub = stub_dir.join("curl");
    std::fs::write(&stub, STUB_CURL).unwrap();
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    let (hb, hr) = (t.join("bash"), t.join("rust"));
    std::fs::create_dir_all(&hr).unwrap();

    // Fill both caches first, from a fake GitHub with everything right.
    if let Some((d, o)) = c.seed {
        let good = t.join("good");
        let pins = serve(&good, Github::default());
        let seed = Case {
            accept_unverified: true,
            ..Case { seed: None, ..c }
        };
        run_bash(&hb, &stub_dir, &good, &pins, &seed, d, o, false);
        // The Rust side's stub reads the same environment variables.
        unsafe_env(&good, &hr, false, || {
            run_rust(&hr, &stub, &pins, &seed, d, o)
        });
        std::fs::remove_file(hb.join(".curl.log")).ok();
        std::fs::remove_file(hr.join(".curl.log")).ok();
    }

    let root = t.join("github");
    let mut pins = serve(&root, c.github);
    if c.bad_pin {
        pins.dsoal_sha256 = "0".repeat(64);
    }
    run_bash(
        &hb,
        &stub_dir,
        &root,
        &pins,
        &c,
        c.dsoal,
        c.oal,
        c.github.offline,
    );
    let (labels, d_ok, o_ok) = unsafe_env(&root, &hr, c.github.offline, || {
        run_rust(&hr, &stub, &pins, &c, c.dsoal, c.oal)
    });

    let read = |f: &str| {
        std::fs::read_to_string(hb.join(f))
            .unwrap()
            .trim()
            .to_string()
    };
    assert_eq!(read("labels"), labels, "{}: the labels", c.name);
    assert_eq!(read("dsoal") == "1", d_ok, "{}: DSOAL usable", c.name);
    assert_eq!(read("oal") == "1", o_ok, "{}: OpenAL Soft usable", c.name);
    assert_eq!(
        downloads(&hb.join(".curl.log")),
        downloads(&hr.join(".curl.log")),
        "{}: what was downloaded",
        c.name
    );
    let cache = |h: &Path| tree(&h.join(".local/share/eax-restore-linux"));
    assert_eq!(cache(&hb), cache(&hr), "{}: the caches", c.name);
}

/// Runs `f` with the stub's environment variables set for this process (the
/// Rust side runs curl as a child, which inherits them). Tests in this file
/// take a lock so they don't set them over each other.
fn unsafe_env<T>(root: &Path, home: &Path, offline: bool, f: impl FnOnce() -> T) -> T {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    // Every test in this binary that touches these variables holds the lock
    // above, and nothing else in it reads them.
    std::env::set_var("STUB_ROOT", root);
    std::env::set_var("STUB_LOG", home.join(".curl.log"));
    std::env::set_var("STUB_OFFLINE", if offline { "1" } else { "" });
    f()
}

fn case(name: &'static str) -> Case {
    Case {
        name,
        github: Github::default(),
        dsoal: Build::Latest,
        oal: Build::Latest,
        accept_unverified: false,
        seed: None,
        bad_pin: false,
    }
}

#[test]
fn first_downloads() {
    compare(case("latest, nothing cached"));
    compare(Case {
        dsoal: Build::Stable,
        oal: Build::Stable,
        ..case("stable, nothing cached")
    });
}

#[test]
fn up_to_date_downloads_nothing() {
    compare(Case {
        seed: Some((Build::Latest, Build::Latest)),
        ..case("latest, cached")
    });
    compare(Case {
        dsoal: Build::Stable,
        oal: Build::Stable,
        seed: Some((Build::Stable, Build::Stable)),
        ..case("stable, cached")
    });
}

#[test]
fn latest_master_missing_follows_the_archive() {
    let g = Github {
        no_latest_master: true,
        ..Github::default()
    };
    compare(Case {
        github: g,
        ..case("archive, nothing cached")
    });
    compare(Case {
        github: g,
        seed: Some((Build::Latest, Build::Latest)),
        ..case("archive over latest-master")
    });
}

#[test]
fn bad_checksums_are_refused() {
    let g = Github {
        bad_digests: true,
        ..Github::default()
    };
    compare(Case {
        github: g,
        ..case("wrong digests, nothing cached")
    });
    compare(Case {
        github: g,
        seed: Some((Build::Stable, Build::Latest)),
        ..case("wrong digests, old cache kept")
    });
    compare(Case {
        dsoal: Build::Stable,
        bad_pin: true,
        ..case("wrong pinned checksum")
    });
}

#[test]
fn unpublished_checksums_ask() {
    let g = Github {
        no_digests: true,
        ..Github::default()
    };
    compare(Case {
        github: g,
        accept_unverified: true,
        ..case("no digests, accepted")
    });
    compare(Case {
        github: g,
        ..case("no digests, declined")
    });
}

#[test]
fn offline_uses_the_cache() {
    let g = Github {
        offline: true,
        ..Github::default()
    };
    compare(Case {
        github: g,
        ..case("offline, nothing cached")
    });
    compare(Case {
        github: g,
        seed: Some((Build::Latest, Build::Stable)),
        ..case("offline, cached")
    });
    compare(Case {
        github: g,
        dsoal: Build::Stable,
        oal: Build::Stable,
        seed: Some((Build::Latest, Build::Stable)),
        ..case("offline, the other build cached")
    });
}

#[test]
fn corrupt_and_nested_zips() {
    compare(Case {
        github: Github {
            corrupt: true,
            ..Github::default()
        },
        ..case("not zips")
    });
    compare(Case {
        github: Github {
            corrupt: true,
            ..Github::default()
        },
        seed: Some((Build::Latest, Build::Latest)),
        ..case("not zips, old cache kept")
    });
    compare(Case {
        github: Github {
            nested: true,
            ..Github::default()
        },
        ..case("nested DSOAL zip")
    });
}

#[test]
fn source_folders_match() {
    let tmp = tempfile::tempdir().unwrap();
    let cache = Cache::new(tmp.path());
    for (dir, file) in [
        (
            cache.dsoal_official().join("x/DSOAL+HRTF/Win32"),
            "dsound.dll",
        ),
        (cache.dsoal_official().join("x/DSOAL/Win32"), "dsound.dll"),
        (cache.dsoal_pinned().join("Win64"), "dsound.dll"),
        (
            cache
                .openal_official()
                .join("openal-soft-1.0-bin/bin/Win32"),
            "soft_oal.dll",
        ),
    ] {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(file), "x").unwrap();
    }
    let out = Command::new("bash")
        .arg("-c")
        .arg(
            "for f in globals ui common cache; do source \"$REPO/src/$f.sh\"; done\n\
             export HOME=\"$1\"; source \"$REPO/src/globals.sh\"\n\
             for b in stable latest; do for a in Win32 Win64; do DSOAL_BUILD=$b OAL_BUILD=$b ARCH_FOLDER=$a; \
             echo \"$(dsoal_source_dir)|$(openal_source_dll)\"; done; done",
        )
        .arg("bash")
        .arg(tmp.path())
        .env("REPO", repo_root())
        .output()
        .unwrap();
    let bash: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect();
    let mut rust = Vec::new();
    for b in [Build::Stable, Build::Latest] {
        for a in ["Win32", "Win64"] {
            rust.push(format!(
                "{}|{}",
                builds::dsoal_source_dir(&cache, b, a)
                    .map_or(String::new(), |p| p.display().to_string()),
                builds::openal_source_dll(&cache, b, a).display()
            ));
        }
    }
    assert_eq!(bash, rust);
}
