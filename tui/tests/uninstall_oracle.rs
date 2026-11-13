//! Parity with the Bash script for a whole uninstall. Each case installs the
//! same game twice with the real built script, in two copies of the
//! integration tests' fake world (`tests/integration/env.bash`), then
//! uninstalls one copy with the script and the other with the Rust engine,
//! and compares the two home folders file for file.
//!
//! The Wine side (the registry keys) is done for the Rust engine by the
//! script's own `remove_prefix_registry`, through the same protontricks
//! stub: porting that is a later stage.

use eax_restore::engine::apply::Host;
use eax_restore::engine::config::paths::game_install_root;
use eax_restore::engine::launcher::target::Target;
use eax_restore::engine::manifest::Companion;
use eax_restore::engine::uninstall::{
    execute, survey, Choices, Location, RegistryWork, Surveyed, UninstallHost,
};
use eax_restore::library;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Once;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// The script the worlds run: built once per test run.
fn build_script() {
    static BUILD: Once = Once::new();
    BUILD.call_once(|| {
        let status = Command::new("./build.sh")
            .current_dir(repo_root())
            .stdout(std::process::Stdio::null())
            .status()
            .expect("build.sh runs");
        assert!(status.success(), "build.sh failed");
    });
}

/// Exports the fake world's environment for a world already made in `$1`.
const WORLD_ENV: &str = r#"
export BATS_TEST_TMPDIR="$1"
source "$REPO/tests/integration/env.bash"
export HOME="$BATS_TEST_TMPDIR/home"
export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
export STUB_LOG="$BATS_TEST_TMPDIR/stub.log" STUB_PREFIX="$WORLD_PREFIX"
export PATH="$REPO/tests/fixtures/bin:$PATH"
export EAX_RESTORE_SKIP_PREFLIGHT=1 EAX_RESTORE_SKIP_CACHE_CHECK=1 EAX_RESTORE_NO_LOG=1 EAX_RESTORE_SKIP_UPDATE_CHECK=1
export TERM=dumb
"#;

fn run(script: &str, dir: &Path, prefix: &Path) -> String {
    let out = Command::new("bash")
        .arg("-c")
        .arg(script)
        .arg("world")
        .arg(dir)
        .env("REPO", repo_root())
        .env("WORLD_PREFIX", prefix)
        .stdin(std::process::Stdio::null())
        .output()
        .expect("bash runs");
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        out.status.success(),
        "the world script failed:\n{text}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    text
}

/// One kind of install: how the world is made and answered.
#[derive(Clone, Copy)]
struct Kind {
    name: &'static str,
    make: &'static str,
    install: &'static str,
    uninstall: &'static str,
    /// Run after the install, before either uninstall.
    after_install: &'static str,
    steam: bool,
}

struct World {
    dir: PathBuf,
    home: PathBuf,
    game: PathBuf,
    prefix: PathBuf,
}

fn make(kind: &Kind, dir: &Path) -> World {
    std::fs::create_dir_all(dir).unwrap();
    let out = run(
        &format!(
            "export BATS_TEST_TMPDIR=\"$1\"; source \"$REPO/tests/integration/env.bash\"\n\
             {make}\n{install} \"$1/in\"; run_script \"$1/in\"\n\
             grep -q 'INSTALLATION COMPLETE' \"$OUT\" || {{ tail -40 \"$OUT\"; exit 1; }}\n\
             {after}\nprintf '%s\\n' \"$HOME\" \"$GAME\" \"$PREFIX\"",
            make = kind.make,
            install = kind.install,
            after = kind.after_install,
        ),
        dir,
        Path::new(""),
    );
    let mut lines = out.lines().rev().take(3).collect::<Vec<_>>();
    lines.reverse();
    World {
        dir: dir.to_path_buf(),
        home: PathBuf::from(lines[0]),
        game: PathBuf::from(lines[1]),
        prefix: PathBuf::from(lines[2]),
    }
}

/// The host for the Rust side: nothing is running in the fake world, and
/// the registry keys go out through the script's own function.
struct FakeWorld<'a> {
    w: &'a World,
    steam: bool,
}

impl Host for FakeWorld<'_> {
    fn game_running(&mut self) -> bool {
        false
    }
    fn registry_quiet(&mut self) -> bool {
        true
    }
}

impl UninstallHost for FakeWorld<'_> {
    fn launcher_closed(&mut self, _target: &Target) -> bool {
        true
    }
    fn remove_registry(&mut self, work: &RegistryWork) -> bool {
        let script = format!(
            "{WORLD_ENV}\nfor f in globals ui common logging detection game-database game-config launcher-config vcrun verify cache prefix-steps; do source \"$REPO/src/$f.sh\"; done\n\
             LAUNCHER_TYPE={lt} APPID={appid} PREFIX_PATH=\"$2\" GAME_DIR=\"$3\" GAME_NAME='Test Game'\n\
             remove_prefix_registry {com} '{dll}' > /dev/null && echo cleaned",
            lt = if self.steam { 1 } else { 2 },
            appid = if self.steam { "424242" } else { "" },
            com = if work.com { "y" } else { "n" },
            dll = work.dll.clone().unwrap_or_default(),
        );
        let out = Command::new("bash")
            .arg("-c")
            .arg(script)
            .arg("world")
            .arg(&self.w.dir)
            .arg(&self.w.prefix)
            .arg(&self.w.game)
            .env("REPO", repo_root())
            .env("WORLD_PREFIX", &self.w.prefix)
            .stdin(std::process::Stdio::null())
            .output()
            .unwrap();
        String::from_utf8_lossy(&out.stdout).contains("cleaned")
    }
    fn remove_vcrun(&mut self) {
        panic!("the cases here don't remove the VC++ runtime");
    }
    fn remove_eax_unified(&mut self) -> bool {
        panic!("the cases here don't install EAX Unified");
    }
    fn clean_companion(&mut self, _c: &Companion, _vcrun: bool) {
        panic!("the cases here have no companion apps");
    }
}

/// Every file under the home folder an uninstall may touch, with the home
/// path and the "uninstalled" marker's time made the same on both sides.
fn snapshot(w: &World) -> Vec<(String, String)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let p = e.path();
            let rel = p.strip_prefix(root).unwrap().display().to_string();
            if rel == ".local/share/eax-restore-linux" || rel == ".local/state" {
                continue;
            }
            if p.is_dir() && !p.is_symlink() {
                walk(root, &p, out);
                continue;
            }
            let text = String::from_utf8_lossy(&std::fs::read(&p).unwrap_or_default())
                .replace(&root.display().to_string(), "<home>");
            let text = text
                .lines()
                .map(|l| {
                    if l.starts_with("# EAX Restore: uninstalled on ") {
                        "# EAX Restore: uninstalled on <time>. Nothing left to remove."
                    } else {
                        l
                    }
                })
                .collect::<Vec<_>>()
                .join("\n");
            // A backup's name carries the second it was made.
            let rel = match rel.find(".bak.") {
                Some(at) => format!("{}.bak.<time>", &rel[..at]),
                None => rel,
            };
            out.push((rel, text));
        }
    }
    let mut out = Vec::new();
    walk(&w.home, &w.home, &mut out);
    out
}

fn compare(kind: Kind) {
    build_script();
    let tmp = tempfile::tempdir().unwrap();
    let a = make(&kind, &tmp.path().join("bash"));
    let b = make(&kind, &tmp.path().join("rust"));
    assert_eq!(
        snapshot(&a),
        snapshot(&b),
        "{}: the two installs differ",
        kind.name
    );

    let out = run(
        &format!(
            "{WORLD_ENV}\nDB_FILE=\"${{DB_FILE:-}}\"; {make_db}\n{u} \"$1/un\"; run_script \"$1/un\"\n\
             grep -q 'UNINSTALL COMPLETE' \"$OUT\" || {{ tail -60 \"$OUT\"; exit 1; }}",
            make_db = if kind.make.contains("profile") {
                "DB_FILE=\"$REPO/tests/fixtures/game-database.json\""
            } else {
                ""
            },
            u = kind.uninstall,
        ),
        &a.dir,
        &a.prefix,
    );
    let _ = out;

    // With no manifest the game isn't in the installed list either.
    let state = library::installed_games_file(&b.home);
    let installed: Vec<PathBuf> = library::live_manifest_dirs(&b.home, &state)
        .into_iter()
        .collect();
    let root = game_install_root(&b.game, None, &[]);
    let at = Location {
        game_dir: &b.game,
        install_root: &root,
        prefix: Some(&b.prefix),
        extra_dirs: &[],
        installed_dirs: &installed,
        has_app_id: kind.steam,
    };
    let Surveyed::Found(s) = survey(&at) else {
        panic!("{}: the Rust survey found nothing to uninstall", kind.name);
    };
    // Every default the Bash answers take: remove every file, take every
    // DLL override out, keep the VC++ runtime, put every setting back.
    let choices = Choices {
        remove: s.files.iter().map(|f| f.path.clone()).collect(),
        revert: s.settings.clone(),
        ..Choices::default()
    };
    let mut host = FakeWorld {
        w: &b,
        steam: kind.steam,
    };
    let report = execute(&s, &choices, &mut host, "2026-01-01T00:00:00Z");
    assert!(report.not_removed.is_empty(), "{report:#?}");

    assert_eq!(
        snapshot(&a),
        snapshot(&b),
        "{}: the uninstalls differ",
        kind.name
    );
}

#[test]
fn launch_options_install() {
    compare(Kind {
        name: "Steam, override in the launch options",
        make: "make_world",
        install: "install_answers",
        uninstall: "uninstall_answers",
        after_install: "",
        steam: true,
    });
}

#[test]
fn registry_install() {
    compare(Kind {
        name: "Steam, override in the registry",
        make: "make_world; export OVERRIDE_CHOICE=2",
        install: "install_answers",
        uninstall: "uninstall_answers",
        after_install: "",
        steam: true,
    });
}

#[test]
fn install_with_game_settings() {
    compare(Kind {
        name: "Steam, with game settings",
        make: "make_profile_world",
        install: "profile_install_answers",
        uninstall: "uninstall_profile_answers",
        after_install: "",
        steam: true,
    });
}

#[test]
fn heroic_install() {
    compare(Kind {
        name: "Heroic",
        make: "make_heroic_world",
        install: "heroic_install_answers",
        uninstall: "heroic_uninstall_answers",
        after_install: "",
        steam: false,
    });
}

#[test]
fn launch_options_changed_since_and_a_file_gone() {
    compare(Kind {
        name: "Steam, the player changed things since",
        make: "make_world",
        install: "install_answers",
        uninstall: "uninstall_answers",
        // The player's own launch options, and a deployed file deleted by hand.
        after_install: "sed -i 's/%command%/%command% -windowed/' \"$STEAM/userdata/1/config/localconfig.vdf\"; \
                        rm -f \"$PREFIX/drive_c/windows/syswow64/dsound.dll\"",
        steam: true,
    });
}

#[test]
fn no_manifest_scans_for_the_files() {
    compare(Kind {
        name: "Steam, the manifest deleted",
        make: "make_world",
        install: "install_answers",
        // Not in the list of installs any more, so its path is typed in.
        uninstall: "by_path() { answers \"$1\" u m \"$HOME/.local/share/Steam/steamapps/common/Test Game\" \"\" \"\" \"\" \"\" \"\" \"\" \"\" \"\"; }; by_path",
        after_install: "rm -f \"$GAME/.eax-restore-manifest.txt\"",
        steam: true,
    });
}
