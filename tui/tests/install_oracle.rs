//! Parity with the Bash script for an install. Each case makes the same
//! fake world twice (`tests/integration/env.bash`), installs with the real
//! built script in one and with the engine in the other, given the choices
//! the script's answers make, and compares the home folders file for file:
//! the deployed DLLs and their backups, alsoft.ini, the launcher's settings,
//! the prefix's registry, the game's settings file and the manifest.

use eax_restore::db::Database;
use eax_restore::engine::apply::Host;
use eax_restore::engine::builds::{Build, Cache, Curl, Net};
use eax_restore::engine::config::paths::Places;
use eax_restore::engine::eax_unified::Installer;
use eax_restore::engine::game_settings::{self, Purpose, Status, Survey};
use eax_restore::engine::identify::Store;
use eax_restore::engine::install::{self, Engine, InstallHost, Override, Plan, Vcrun};
use eax_restore::engine::launcher::target::Target;
use eax_restore::engine::prepare;
use eax_restore::engine::speakers::{Listening, Speakers};
use eax_restore::engine::wine::{Prefix, Runner};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Once;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
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

fn run(script: &str, dir: &Path) -> String {
    let out = Command::new("bash")
        .arg("-c")
        .arg(script)
        .arg("world")
        .arg(dir)
        .env("REPO", repo_root())
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert!(
        out.status.success(),
        "the world script failed:\n{text}\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    text
}

#[derive(Clone, Copy)]
struct Kind {
    name: &'static str,
    /// Makes the world (env.bash's function, and any exports for the answers).
    make: &'static str,
    /// The answers for the install being compared.
    install: &'static str,
    /// An install both sides get first with the script, for a reinstall.
    before: Option<&'static str>,
    heroic: bool,
    registry: bool,
    profile: bool,
    /// The plan comes from detection (`prepare::gather`), not by hand.
    gathered: bool,
}

struct World {
    home: PathBuf,
    game: PathBuf,
    prefix: PathBuf,
}

/// Makes the world and runs `installs` (answer functions) with the script.
fn make(kind: &Kind, dir: &Path, installs: &[&str]) -> World {
    std::fs::create_dir_all(dir).unwrap();
    let mut script = format!(
        "export BATS_TEST_TMPDIR=\"$1\"; source \"$REPO/tests/integration/env.bash\"\n{}\n",
        kind.make
    );
    // A backup's name is the second it was made, so a second install in the
    // same second as the first would overwrite its backup: each install is
    // followed by a second's wait.
    for (n, i) in installs.iter().enumerate() {
        script.push_str(&format!(
            "{i} \"$1/in{n}\"; run_script \"$1/in{n}\"\n\
             grep -q 'INSTALLATION COMPLETE' \"$OUT\" || {{ tail -40 \"$OUT\"; exit 1; }}\nsleep 1\n"
        ));
    }
    script.push_str("printf '%s\\n' \"$HOME\" \"$GAME\" \"$PREFIX\"");
    let out = run(&script, dir);
    let lines: Vec<&str> = out.lines().rev().take(3).collect();
    World {
        home: PathBuf::from(lines[2]),
        game: PathBuf::from(lines[1]),
        prefix: PathBuf::from(lines[0]),
    }
}

/// Nothing runs in the fake world, launchers close at once, and the network
/// is off (the curl stub).
struct FakeHost {
    net: Curl,
}

impl Host for FakeHost {
    fn game_running(&mut self) -> bool {
        false
    }
    fn registry_quiet(&mut self) -> bool {
        true
    }
}

impl InstallHost for FakeHost {
    fn launcher_closed(&mut self, _t: &Target) -> bool {
        true
    }
    fn net(&mut self) -> &mut dyn Net {
        &mut self.net
    }
}

/// The choices the script's answers make in the fake world: DSOAL with
/// OpenAL Soft, both stable (the cache has nothing else), 32-bit, stereo
/// with HRTF, no advanced tweaks, no VC++.
fn plan(kind: &Kind, w: &World) -> Plan {
    let stubs = repo_root().join("tests/fixtures/bin");
    let runner = if kind.heroic {
        None
    } else {
        Some(Runner::Protontricks {
            cmd: vec![stubs.join("protontricks").display().to_string()],
            app_id: "424242".into(),
        })
    };
    let over = if kind.registry {
        Override::Registry
    } else if kind.heroic {
        Override::Launcher(
            Target::heroic(&w.home.join(".config/heroic"), "987654321")
                .expect("Heroic has the game's settings"),
        )
    } else {
        Override::Launcher(
            Target::steam(&w.home, None, "424242").expect("Steam has the game's settings"),
        )
    };
    let speakers = Speakers::stereo(Listening::Auto, true);
    let mut game_settings = Vec::new();
    if kind.profile {
        // The answers apply the audio settings and the first optional one.
        let db = Database::load(&repo_root().join("tests/fixtures/game-database.json")).unwrap();
        let places = Places {
            game_dir: &w.game,
            install_root: &w.game,
            prefix: Some(&w.prefix),
            user: "player",
        };
        let survey = Survey {
            store: Store::Steam,
            places,
            speakers: Some(speakers),
            purpose: Purpose::Install,
            recorded: HashSet::new(),
            include_untested: false,
        };
        for f in game_settings::survey(&db.games[0], &survey) {
            if f.status == Status::Offer
                && (f.category == game_settings::Category::Audio || f.title == "Skip intro movies")
            {
                game_settings.extend(f.plan);
            }
        }
        // A reinstall finds them already set.
        assert!(!game_settings.is_empty() || kind.before.is_some());
    }
    Plan {
        game_dir: w.game.clone(),
        extra_dirs: Vec::new(),
        prefix: Some(Prefix {
            path: w.prefix.clone(),
            runner,
            log: None,
        }),
        arch: 32,
        engine: Engine::Dsoal,
        dsoal_build: Build::Stable,
        openal_build: Build::Stable,
        speakers,
        alsoft_overrides: Vec::new(),
        advanced_limits: false,
        com_routing: false,
        over,
        vcrun: Vcrun::Skip,
        eax_unified: false,
        game_settings,
        crash_markers: HashMap::new(),
        companions: Vec::new(),
        sound_log: false,
    }
}

/// The home folder as files, the home path and backup times made the same.
fn snapshot(home: &Path) -> Vec<(String, String)> {
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
            out.push((rel, text));
        }
    }
    let mut out = Vec::new();
    walk(home, home, &mut out);
    out.sort();
    // Backups by their order, not the second they were made.
    let mut seen: HashMap<String, usize> = HashMap::new();
    for (rel, _) in out.iter_mut() {
        if let Some(at) = rel.find(".bak.") {
            let base = rel[..at].to_string();
            let n = seen.entry(base.clone()).or_insert(0);
            *n += 1;
            *rel = format!("{base}.bak.{n}");
        }
    }
    out
}

fn compare(kind: Kind) {
    build_script();
    let tmp = tempfile::tempdir().unwrap();
    let before: Vec<&str> = kind.before.into_iter().collect();
    let mut a_installs = before.clone();
    a_installs.push(kind.install);
    let a = make(&kind, &tmp.path().join("bash"), &a_installs);
    let b = make(&kind, &tmp.path().join("rust"), &before);

    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let report = {
        let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
        std::env::set_var("STUB_PREFIX", &b.prefix);
        std::env::set_var("STUB_LOG", tmp.path().join("rust/stub.log"));
        // The stubs first, as the script's side has them: never the
        // machine's own winetricks or wineserver.
        let path = std::env::var("PATH").unwrap_or_default();
        let stubs = repo_root().join("tests/fixtures/bin");
        if !path.starts_with(&stubs.display().to_string()) {
            std::env::set_var("PATH", format!("{}:{path}", stubs.display()));
        }
        let mut host = FakeHost {
            net: Curl {
                program: repo_root().join("tests/fixtures/bin/curl"),
            },
        };
        let p = if kind.gathered {
            let pt = vec![repo_root()
                .join("tests/fixtures/bin/protontricks")
                .display()
                .to_string()];
            prepare::gather(&b.game, None, &b.home, &pt).default_plan()
        } else {
            plan(&kind, &b)
        };
        install::execute(
            &p,
            &Cache::new(&b.home),
            &Installer::for_branch("main"),
            &mut host,
        )
    };
    assert!(
        report.failures.is_empty() && !report.no_sources,
        "{}: {report:#?}",
        kind.name
    );
    let (sa, sb) = (snapshot(&a.home), snapshot(&b.home));
    if sa != sb {
        let ma: HashMap<_, _> = sa.iter().cloned().collect();
        let mb: HashMap<_, _> = sb.iter().cloned().collect();
        let mut diffs = Vec::new();
        for k in ma
            .keys()
            .chain(mb.keys())
            .collect::<std::collections::BTreeSet<_>>()
        {
            if ma.get(k) != mb.get(k) {
                diffs.push(format!(
                    "{k}:\n  bash: {:?}\n  rust: {:?}",
                    ma.get(k),
                    mb.get(k)
                ));
            }
        }
        panic!("{}: the installs differ\n{}", kind.name, diffs.join("\n"));
    }
}

fn kind(name: &'static str) -> Kind {
    Kind {
        name,
        make: "make_world",
        install: "install_answers",
        before: None,
        heroic: false,
        registry: false,
        profile: false,
        gathered: false,
    }
}

#[test]
fn a_first_install() {
    compare(kind("Steam, launch options"));
}

#[test]
fn the_registry_route() {
    compare(Kind {
        make: "make_world; export OVERRIDE_CHOICE=2",
        registry: true,
        ..kind("Steam, registry")
    });
}

#[test]
fn with_game_settings() {
    compare(Kind {
        make: "make_profile_world",
        install: "profile_install_answers",
        profile: true,
        ..kind("Steam, game settings")
    });
}

#[test]
fn heroic() {
    compare(Kind {
        make: "make_heroic_world",
        install: "heroic_install_answers",
        heroic: true,
        ..kind("Heroic")
    });
}

#[test]
fn reinstalls_carry_the_last_install_over() {
    compare(Kind {
        before: Some("install_answers"),
        ..kind("Steam, the same install again")
    });
    compare(Kind {
        make: "make_profile_world",
        install: "profile_install_answers",
        before: Some("profile_install_answers"),
        profile: true,
        ..kind("Steam, game settings again")
    });
    // The registry first, then the launcher: the registry records stay.
    compare(Kind {
        make: "make_world; reg() { OVERRIDE_CHOICE=2 install_answers \"$@\"; }",
        before: Some("reg"),
        ..kind("Steam, registry then launch options")
    });
}

#[test]
fn a_plan_from_detection_matches_the_scripts_defaults() {
    compare(Kind {
        gathered: true,
        ..kind("Steam, detected")
    });
    compare(Kind {
        make: "make_heroic_world",
        install: "heroic_install_answers",
        heroic: true,
        gathered: true,
        ..kind("Heroic, detected")
    });
}
