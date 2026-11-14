//! The headless commands, run as a program in the integration tests' fake
//! world: an install matches the script's default install file for file,
//! and every command afterwards, down to the uninstall, leaves the world as
//! it was before.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Once;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_path_buf()
}

fn build_script() {
    static BUILD: Once = Once::new();
    BUILD.call_once(|| {
        let ok = Command::new("./build.sh")
            .current_dir(repo_root())
            .stdout(std::process::Stdio::null())
            .status()
            .is_ok_and(|s| s.success());
        assert!(ok, "build.sh failed");
    });
}

/// Runs a script in a new fake world in `dir`; `$BIN` is this program and
/// `$EMPTY` an empty folder standing in for /proc, so no real launcher is
/// ever seen or closed.
fn world(dir: &Path, make: &str, body: &str) -> String {
    std::fs::create_dir_all(dir.join("proc")).unwrap();
    let out = Command::new("bash")
        .arg("-c")
        .arg(format!(
            "export BATS_TEST_TMPDIR=\"$1\"; source \"$REPO/tests/integration/env.bash\"\n{make}\n\
             export EAX_RESTORE_GAME_DATABASE_FILE=\"${{DB_FILE:-$1/db.json}}\"\n\
             [ -f \"$EAX_RESTORE_GAME_DATABASE_FILE\" ] || echo '{{\"games\":[]}}' > \"$EAX_RESTORE_GAME_DATABASE_FILE\"\n\
             export EAX_RESTORE_PROC_ROOT=\"$1/proc\"\n{body}"
        ))
        .arg("world")
        .arg(dir)
        .env("REPO", repo_root())
        .env("BIN", env!("CARGO_BIN_EXE_eax-restore"))
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        out.status.success(),
        "{text}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    text
}

/// Every file under the fake home, with its path and backup times made alike.
fn snapshot(home: &Path) -> Vec<(String, String)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let p = e.path();
            let rel = p.strip_prefix(root).unwrap().display().to_string();
            if rel == ".local/share/eax-restore-linux" || rel == ".local/state" {
                continue;
            }
            if p.is_dir() {
                walk(root, &p, out);
                continue;
            }
            let rel = match rel.find(".bak.") {
                Some(at) => format!("{}.bak", &rel[..at]),
                None => rel,
            };
            let text = String::from_utf8_lossy(&std::fs::read(&p).unwrap())
                .replace(&root.display().to_string(), "<home>");
            out.push((rel, text));
        }
    }
    let mut out = Vec::new();
    walk(home, home, &mut out);
    out.sort();
    out
}

#[test]
fn install_matches_the_scripts_default_install() {
    build_script();
    let tmp = tempfile::tempdir().unwrap();
    for (make, answers) in [
        ("make_world", "install_answers"),
        ("make_heroic_world", "heroic_install_answers"),
    ] {
        let (a, b) = (
            tmp.path().join(format!("{make}-a")),
            tmp.path().join(format!("{make}-b")),
        );
        world(&a, make, &format!("{answers} \"$1/in\"; run_script \"$1/in\"; grep -q 'INSTALLATION COMPLETE' \"$OUT\""));
        let out = world(&b, make, "\"$BIN\" install \"$GAME\" --yes");
        assert!(out.contains("The EAX fix is installed."), "{out}");
        assert_eq!(
            snapshot(&a.join("home")),
            snapshot(&b.join("home")),
            "{make}\n{out}"
        );
    }
}

#[test]
fn every_command_then_uninstall_leaves_the_world_as_it_was() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let out = world(
        d,
        "make_profile_world",
        "snapshot \"$1/before\"\n\
         \"$BIN\" install \"$GAME\" --yes --setting 'Skip intro movies' --vcrun skip\n\
         \"$BIN\" status \"$GAME\"\n\
         \"$BIN\" speakers \"$GAME\" 5.1 --yes\n\
         \"$BIN\" settings \"$GAME\" --off 'Skip intro movies' --yes\n\
         \"$BIN\" sound-log \"$GAME\" full --yes\n\
         \"$BIN\" sound-log \"$GAME\" off --yes\n\
         \"$BIN\" uninstall \"$GAME\" --yes\n\
         snapshot \"$1/after\"; diff \"$1/before\" \"$1/after\" && echo ROUND_TRIP_OK",
    );
    for want in [
        "The EAX fix is installed.",
        "Skip intro movies — on",
        "is now set up for Surround 5.1",
        "Put back \"Skip intro movies\".",
        "The sound log is on.",
        "The sound log is off for Test Game.",
        "The EAX fix is removed from Test Game.",
        "ROUND_TRIP_OK",
    ] {
        assert!(out.contains(want), "missing {want:?} in:\n{out}");
    }
}

#[test]
fn nothing_changes_without_yes() {
    let tmp = tempfile::tempdir().unwrap();
    let out = world(
        tmp.path(),
        "make_world",
        "snapshot \"$1/before\"; \"$BIN\" install \"$GAME\" < /dev/null; echo \"rc=$?\"; snapshot \"$1/after\"; diff \"$1/before\" \"$1/after\" && echo SAME",
    );
    assert!(out.contains("rc=1") && out.contains("SAME"), "{out}");
}
