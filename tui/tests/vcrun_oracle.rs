//! Parity with the Bash script for the VC++ runtime and EAX Unified. A fake
//! protontricks (Steam) and a fake wine (Heroic) stand in for the Windows
//! installers: they drop or remove "genuine" DLLs in the prefix, as told by
//! environment switches, and answer `reg query` from a file. The script's
//! functions and the engine each work on their own copy of a prefix; the
//! results, the commands run and the prefixes must match.

use eax_restore::engine::builds::Curl;
use eax_restore::engine::eax_unified::{self, Installer, Outcome};
use eax_restore::engine::vcrun::{self, Installed};
use eax_restore::engine::wine::{Prefix, Runner};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// What the Windows programs do, shared by both fakes. `$@` is the program
/// and its arguments; the prefix is `$STUB_PREFIX`.
const WINDOWS: &str = r#"
sys32="$STUB_PREFIX/drive_c/windows/system32"; wow="$STUB_PREFIX/drive_c/windows/syswow64"
x86="$sys32"; [ -d "$wow" ] && x86="$wow"
genuine() { for f in vcruntime140 msvcp140 vcomp140 concrt140; do printf 'MZ Microsoft %s\n' "$f" > "$1/$f.dll"; done; }
case "$1" in
    regedit) python3 -I "$REGEDIT" "$2" ;;
    reg) [ "$2" == query ] && cat "$STUB_REG_QUERY" 2>/dev/null ;;
    *vc_redist.x64.exe) [ "$2" != /uninstall ] && [ -n "${STUB_MS_WORKS:-}" ] && genuine "$sys32" ;;
    *vc_redist.x86.exe) [ "$2" != /uninstall ] && [ -n "${STUB_MS_WORKS:-}" ] && genuine "$x86" ;;
    *EAX4Unified*) printf 'MZ EAX Unified\n' > "$x86/eax.dll" ;;
    msiexec) rm -f "$x86/eax.dll" ;;
esac
exit 0
"#;

fn exe(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// The fakes in `dir`: protontricks, wine, wineserver and winetricks.
fn fakes(dir: &Path) {
    let windows = dir.join("windows");
    exe(&windows, &format!("#!/usr/bin/env bash\n{WINDOWS}"));
    let verb = "[ \"$verb\" == vcrun2022 ] && [ -n \"${STUB_VERB_WORKS:-}\" ] && { genuine() { for f in vcruntime140 msvcp140 vcomp140 concrt140; do printf 'MZ Microsoft %s\\n' \"$f\" > \"$1/$f.dll\"; done; }; for d in system32 syswow64; do [ -d \"$STUB_PREFIX/drive_c/windows/$d\" ] && genuine \"$STUB_PREFIX/drive_c/windows/$d\"; done; }";
    exe(
        &dir.join("protontricks"),
        &format!(
            "#!/usr/bin/env bash\necho \"protontricks $*\" >> \"$STUB_LOG\"\n\
             if [ \"$1\" == -c ]; then\n\
               case \"$2\" in\n\
                 *WINEPREFIX*) echo \"$STUB_PREFIX\" ;;\n\
                 regedit*|wine*) eval \"args=($2)\"; [ \"${{args[0]}}\" == wine ] && args=(\"${{args[@]:1}}\"); \"{w}\" \"${{args[@]}}\" ;;\n\
               esac\n\
             else verb=\"${{@: -1}}\"; {verb}; fi\nexit 0\n",
            w = windows.display()
        ),
    );
    exe(
        &dir.join("wine"),
        &format!(
            "#!/usr/bin/env bash\necho \"wine $*\" >> \"$STUB_LOG\"\nSTUB_PREFIX=\"$WINEPREFIX\" \"{}\" \"$@\"\n",
            windows.display()
        ),
    );
    exe(&dir.join("wineserver"), "#!/usr/bin/env bash\nexit 0\n");
    exe(
        &dir.join("winetricks"),
        &format!("#!/usr/bin/env bash\necho \"winetricks $*\" >> \"$STUB_LOG\"\nSTUB_PREFIX=\"$WINEPREFIX\"; verb=\"${{@: -1}}\"; {verb}\nexit 0\n"),
    );
    // Offline: Microsoft's installer can't be downloaded.
    exe(
        &dir.join("curl"),
        "#!/usr/bin/env bash\necho \"curl $*\" >> \"$STUB_LOG\"\nexit 6\n",
    );
}

#[derive(Clone, Copy, Default)]
struct World {
    heroic: bool,
    wow: bool,
    verb_works: bool,
    ms_works: bool,
    /// Microsoft's installer is in the cache already.
    cached_installer: bool,
    /// The runtime is registered in the prefix, so Microsoft's is asked to repair.
    registered: bool,
}

fn make_side(side: &Path, w: World) {
    for d in ["drive_c/windows/system32", "game"] {
        std::fs::create_dir_all(side.join(d)).unwrap();
    }
    if w.wow {
        std::fs::create_dir_all(side.join("drive_c/windows/syswow64")).unwrap();
    }
    // Wine's own placeholders, which never count.
    for d in ["system32", "syswow64"] {
        let dir = side.join("drive_c/windows").join(d);
        if dir.is_dir() {
            std::fs::write(dir.join("vcruntime140.dll"), "MZ Wine builtin DLL").unwrap();
            // Ones no installer here replaces, which must never be removed.
            std::fs::write(dir.join("vcruntime140_1.dll"), "MZ Wine builtin DLL").unwrap();
            std::fs::write(dir.join("msvcp140_2.dll"), "MZ Wine placeholder DLL").unwrap();
        }
    }
    std::fs::write(side.join("user.reg"), "WINE REGISTRY Version 2\n\n").unwrap();
    let reg = if w.registered {
        "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\x] 1\n\"DisplayName\"=\"Microsoft Visual C++ 2022 X86 Minimum Runtime - 14.40\"\n\"DisplayName\"=\"Microsoft Visual C++ 2022 X64 Minimum Runtime - 14.40\"\n"
    } else {
        "WINE REGISTRY Version 2\n\n"
    };
    std::fs::write(side.join("system.reg"), reg).unwrap();
    std::fs::write(
        side.join("query.txt"),
        "\r\nHKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{AA}\r\n    DisplayName    REG_SZ    Microsoft Visual C++ 2022 X86 Minimum Runtime\r\n\
         HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{BB}\r\n    DisplayName    REG_SZ    Microsoft Visual C++ 2010 Redistributable\r\n",
    )
    .unwrap();
    let cache = side.join("home/.local/share/eax-restore-linux/vcrun2022");
    std::fs::create_dir_all(&cache).unwrap();
    if w.cached_installer {
        for a in ["x86", "x64"] {
            std::fs::write(cache.join(format!("vc_redist.{a}.exe")), "MZ installer").unwrap();
        }
    }
}

fn env_for(side: &Path, bin: &Path, w: World) -> Vec<(&'static str, String)> {
    vec![
        ("STUB_PREFIX", side.display().to_string()),
        ("STUB_LOG", side.join("stub.log").display().to_string()),
        (
            "STUB_REG_QUERY",
            side.join("query.txt").display().to_string(),
        ),
        (
            "STUB_VERB_WORKS",
            if w.verb_works {
                "1".into()
            } else {
                String::new()
            },
        ),
        (
            "STUB_MS_WORKS",
            if w.ms_works {
                "1".into()
            } else {
                String::new()
            },
        ),
        (
            "REGEDIT",
            repo_root()
                .join("tests/fixtures/bin/regedit-apply.py")
                .display()
                .to_string(),
        ),
        (
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        ),
    ]
}

/// Runs `body` in Bash with the script's functions and this side's world.
fn bash(side: &Path, bin: &Path, w: World, body: &str) -> String {
    let script = format!(
        "for f in globals ui common logging detection game-database game-config launcher-config vcrun verify cache prefix-steps; do source \"$REPO/src/$f.sh\"; done\n\
         export HOME=\"$1/home\"; source \"$REPO/src/globals.sh\"\n\
         EAX_LOG_FILE=\"$1/bash.log\" GAME_DIR=\"$1/game\" PREFIX_PATH=\"$1\" GAME_NAME=G APPID=42\n\
         LAUNCHER_TYPE={lt}; WINE_CMD={wine}; WINESERVER_CMD={server}\n{body}",
        lt = if w.heroic { 2 } else { 1 },
        wine = if w.heroic { bin.join("wine").display().to_string() } else { String::new() },
        server = if w.heroic { bin.join("wineserver").display().to_string() } else { String::new() },
    );
    std::fs::write(side.join(".oracle.sh"), script).unwrap();
    let out = Command::new("bash")
        .arg(side.join(".oracle.sh"))
        .arg(side)
        .env("REPO", repo_root())
        .env("TERM", "dumb")
        .env("EAX_RESTORE_NO_LOG", "1")
        .envs(env_for(side, bin, w))
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Runs `f` with this side's world in the process environment.
fn rust<T>(side: &Path, bin: &Path, w: World, f: impl FnOnce(&Prefix, &mut Curl) -> T) -> T {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let saved = std::env::var("PATH").unwrap();
    for (k, v) in env_for(side, bin, w) {
        std::env::set_var(k, v);
    }
    let p = Prefix {
        path: side.to_path_buf(),
        runner: Some(if w.heroic {
            Runner::Wine {
                wine: bin.join("wine"),
                wineserver: Some(bin.join("wineserver")),
            }
        } else {
            Runner::Protontricks {
                cmd: vec![bin.join("protontricks").display().to_string()],
                app_id: "42".into(),
            }
        }),
        log: None,
    };
    let mut net = Curl {
        program: bin.join("curl"),
    };
    let out = f(&p, &mut net);
    std::env::set_var("PATH", saved);
    out
}

/// The prefix's system folders and registry, and the commands that ran,
/// with this side's path taken out.
fn state(side: &Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for d in [
        "drive_c/windows/system32",
        "drive_c/windows/syswow64",
        "home/.local/share/eax-restore-linux/vcrun2022",
        "home/.local/share/eax-restore-linux/eax-unified",
    ] {
        let Ok(e) = std::fs::read_dir(side.join(d)) else {
            continue;
        };
        let mut files: Vec<_> = e
            .flatten()
            .filter(|e| !e.file_name().to_string_lossy().ends_with(".log"))
            .map(|e| {
                (
                    format!("{d}/{}", e.file_name().to_string_lossy()),
                    std::fs::read_to_string(e.path()).unwrap_or_default(),
                )
            })
            .collect();
        files.sort();
        out.extend(files);
    }
    let norm = |t: String| {
        t.replace(&side.display().to_string(), "<side>")
            .lines()
            // The script's progress bar asks for the size first; that's display.
            .filter(|l| !l.starts_with("curl -sIL"))
            .map(|l| l.split(".eax-restore-").next().unwrap().to_string())
            .collect::<Vec<_>>()
            .join("\n")
    };
    out.push((
        "user.reg".into(),
        norm(std::fs::read_to_string(side.join("user.reg")).unwrap()),
    ));
    out.push((
        "stub.log".into(),
        norm(std::fs::read_to_string(side.join("stub.log")).unwrap_or_default()),
    ));
    out
}

fn compare_vcrun(name: &str, w: World, arch: u8) {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let (b, r) = (t.join("b"), t.join("r"));
    let (bb, rb) = (t.join("bin-b"), t.join("bin-r"));
    fakes(&bb);
    fakes(&rb);
    make_side(&b, w);
    make_side(&r, w);

    let out = bash(
        &b,
        &bb,
        w,
        &format!(
            "ARCH={arch}; if install_vcrun_dependencies > /dev/null 2>&1; then echo 1; else echo 0; fi\n\
             uninstall_vcrun_dependencies > /dev/null 2>&1; echo done"
        ),
    );
    let (installed, _) = rust(&r, &rb, w, |p, net| {
        let cache = r.join("home/.local/share/eax-restore-linux/vcrun2022");
        let i = vcrun::install(p, &r.join("game"), arch, &cache, net);
        let u = vcrun::uninstall(p, &r.join("game"), &cache, net);
        (i, u)
    });
    assert_eq!(
        out,
        format!("{}\ndone\n", if installed.ok() { 1 } else { 0 }),
        "{name}: {installed:?}"
    );
    assert_eq!(state(&b), state(&r), "{name}");
}

#[test]
fn the_package_manager_installs_it() {
    for heroic in [false, true] {
        for wow in [false, true] {
            let w = World {
                heroic,
                wow,
                verb_works: true,
                ..World::default()
            };
            compare_vcrun(
                &format!("verb, heroic {heroic}, wow {wow}"),
                w,
                if wow { 32 } else { 64 },
            );
        }
    }
}

#[test]
fn microsofts_installer_is_the_fallback() {
    for heroic in [false, true] {
        for arch in [32, 64] {
            let w = World {
                heroic,
                wow: true,
                ms_works: true,
                cached_installer: true,
                ..World::default()
            };
            compare_vcrun(&format!("Microsoft, heroic {heroic}, {arch}-bit"), w, arch);
            let w = World {
                registered: true,
                ..w
            };
            compare_vcrun(&format!("repair, heroic {heroic}, {arch}-bit"), w, arch);
            let w = World {
                ms_works: false,
                ..w
            };
            compare_vcrun(
                &format!("Microsoft fails, heroic {heroic}, {arch}-bit"),
                w,
                arch,
            );
        }
    }
}

#[test]
fn no_installer_offline() {
    for heroic in [false, true] {
        let w = World {
            heroic,
            wow: true,
            ..World::default()
        };
        compare_vcrun(&format!("offline, heroic {heroic}"), w, 32);
    }
}

#[test]
fn eax_unified_matches() {
    for heroic in [false, true] {
        for cached in [true, false] {
            let tmp = tempfile::tempdir().unwrap();
            let t = tmp.path();
            let w = World {
                heroic,
                wow: true,
                ..World::default()
            };
            let (b, r) = (t.join("b"), t.join("r"));
            let (bb, rb) = (t.join("bin-b"), t.join("bin-r"));
            fakes(&bb);
            fakes(&rb);
            make_side(&b, w);
            make_side(&r, w);
            let mut inst = Installer::for_branch("main");
            inst.exe_sha256 = format!(
                "{:x}",
                <sha2::Sha256 as sha2::Digest>::digest(b"MZ EAX Unified installer")
            );
            for side in [&b, &r] {
                let dir = side.join("home/.local/share/eax-restore-linux/eax-unified");
                std::fs::create_dir_all(&dir).unwrap();
                if cached {
                    std::fs::write(dir.join(&inst.exe), "MZ EAX Unified installer").unwrap();
                }
            }
            let out = bash(
                &b,
                &bb,
                w,
                &format!(
                    "EAX_UNIFIED_EXE_SHA256={sha}\n\
                     install_eax_unified > /dev/null 2>&1; echo $?\n\
                     install_eax_unified > /dev/null 2>&1; echo $?\n\
                     if uninstall_eax_unified > /dev/null 2>&1; then echo gone; else echo left; fi",
                    sha = inst.exe_sha256
                ),
            );
            let rust_out = rust(&r, &rb, w, |p, net| {
                let cache = r.join("home/.local/share/eax-restore-linux/eax-unified");
                let code = |o: Outcome| match o {
                    Outcome::Installed => 0,
                    Outcome::AlreadyThere => 2,
                    Outcome::NoInstaller | Outcome::Failed => 1,
                };
                let a = eax_unified::install(p, &cache, &inst, net, Duration::from_millis(10));
                let b2 = eax_unified::install(p, &cache, &inst, net, Duration::from_millis(10));
                let gone = eax_unified::uninstall(p, &inst, Duration::from_millis(10));
                format!(
                    "{}\n{}\n{}\n",
                    code(a),
                    code(b2),
                    if gone { "gone" } else { "left" }
                )
            });
            assert_eq!(
                out, rust_out,
                "EAX Unified, heroic {heroic}, cached {cached}"
            );
            assert_eq!(
                state(&b),
                state(&r),
                "EAX Unified, heroic {heroic}, cached {cached}"
            );
        }
    }
    let _ = Installed::Failed;
}
