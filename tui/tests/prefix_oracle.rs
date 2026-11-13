//! Parity with the Bash script for the changes an install makes inside a
//! Wine prefix: the registry patches (through the tests' protontricks stub
//! for Steam, a fake wine for Heroic), reading the override back, the DLL
//! copy into the system folder, Creative's OpenAL runtime, finding a Steam
//! prefix, Heroic's Wine build, and the 32/64-bit count.

use eax_restore::engine::prefix::{self, RegStatus};
use eax_restore::engine::wine::{self, Prefix, Runner};
use std::collections::HashSet;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

fn stubs() -> PathBuf {
    repo_root().join("tests/fixtures/bin")
}

fn exe(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

/// A fake Wine for Heroic games: `wine regedit <file>` applies it the way
/// the protontricks stub does; everything is logged.
fn fake_wine(dir: &Path, works: bool) -> PathBuf {
    let wine = dir.join("wine");
    exe(
        &wine,
        &format!(
            "#!/usr/bin/env bash\necho \"wine $*\" >> \"$STUB_LOG\"\n\
             [ \"$1\" == regedit ] && {} STUB_PREFIX=\"$WINEPREFIX\" python3 -I \"{}\" \"$2\"\nexit 0\n",
            if works { "" } else { "false &&" },
            stubs().join("regedit-apply.py").display()
        ),
    );
    exe(
        &dir.join("wineserver"),
        "#!/usr/bin/env bash\necho \"wineserver $*\" >> \"$STUB_LOG\"\n",
    );
    wine
}

fn make_prefix(dir: &Path) {
    for d in ["drive_c/windows/system32", "drive_c/windows/syswow64"] {
        std::fs::create_dir_all(dir.join(d)).unwrap();
    }
    std::fs::write(
        dir.join("user.reg"),
        "WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n[Software\\\\Wine\\\\DllOverrides] 1\n\"winmm\"=\"native\"\n\n",
    )
    .unwrap();
}

const SOURCES: &str = "globals ui common logging detection game-database game-config launcher-config vcrun verify cache prefix-steps";

/// Runs `script` with the script's functions loaded, the stubs first on
/// PATH, and `env` set. Returns its output.
fn bash(script: &str, dir: &Path, env: &[(&str, String)]) -> String {
    let full = format!(
        "for f in {SOURCES}; do source \"$REPO/src/$f.sh\"; done\nEAX_LOG_FILE=\"$1/bash.log\"\n{script}"
    );
    let file = dir.join(".oracle.sh");
    std::fs::write(&file, full).unwrap();
    let out = Command::new("bash")
        .arg(&file)
        .arg(dir)
        .env("REPO", repo_root())
        .env("HOME", dir)
        .env(
            "PATH",
            format!("{}:{}", stubs().display(), std::env::var("PATH").unwrap()),
        )
        .env("TERM", "dumb")
        .env("EAX_RESTORE_NO_LOG", "1")
        .envs(env.iter().map(|(k, v)| (*k, v.as_str())))
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

#[test]
fn registry_patches_match() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let mut script = String::new();
    let mut cases = Vec::new();
    for com in [false, true] {
        for dll in [None, Some("dsound"), Some("openal32")] {
            let n = cases.len();
            script.push_str(&format!(
                "apply_registry_patch() {{ cp \"$1\" \"$OUT/apply{n}\"; return 0; }}\nverify_dll_override() {{ return 0; }}\n\
                 GAME_DIR=\"$OUT\"; INSTALL_MANIFEST=\"$OUT/m{n}\" PRIMARY_DLL_NAME={} apply_prefix_registry {} {} > /dev/null\n\
                 remove_prefix_registry {} '{}' > /dev/null; cp \"$OUT\"/.eax-restore-registry-clean-*.reg \"$OUT/remove{n}\" 2>/dev/null\n",
                dll.unwrap_or("dsound"),
                if com { "y" } else { "n" },
                if dll.is_some() { "y" } else { "n" },
                if com { "y" } else { "n" },
                dll.unwrap_or(""),
            ));
            cases.push((com, dll));
        }
    }
    // remove_prefix_registry deletes its file; catch it before that.
    let script = script.replace(
        "remove_prefix_registry",
        "apply_registry_patch() { cp \"$1\" \"$OUT/remove_now\"; return 0; }; remove_prefix_registry",
    );
    let script = script.replace(
        "cp \"$OUT\"/.eax-restore-registry-clean-*.reg",
        "mv \"$OUT/remove_now\"",
    );
    bash(&script, d, &[("OUT", d.display().to_string())]);
    for (n, (com, dll)) in cases.iter().enumerate() {
        let read = |f: &str| std::fs::read_to_string(d.join(format!("{f}{n}"))).unwrap_or_default();
        assert_eq!(
            read("apply"),
            prefix::patch_text(*com, *dll),
            "applying com={com} {dll:?}"
        );
        assert_eq!(
            read("remove"),
            prefix::removal_text(*com, *dll),
            "removing com={com} {dll:?}"
        );
        assert_eq!(
            read("m"),
            prefix::registry_lines(*com, *dll, "")
                .iter()
                .map(|l| format!("{l}\n"))
                .collect::<String>(),
            "manifest lines com={com} {dll:?}"
        );
    }
    assert_eq!(prefix::removal_text(false, Some("both")), "Windows Registry Editor Version 5.00\n\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n\"dsound\"=-\n\"openal32\"=-\n\n");
}

/// Applies and removes the registry changes in a prefix on each side, for a
/// Steam game (protontricks stub) and a Heroic one (fake wine).
#[test]
fn registry_round_trips_match() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    for (k, steam) in [true, false].iter().enumerate() {
        for works in [true, false] {
            if *steam && !works {
                continue;
            }
            for (com, dll) in [
                (true, Some("dsound")),
                (false, Some("openal32")),
                (true, None),
            ] {
                let case = format!("{k}-{works}-{com}-{}", dll.unwrap_or("none"));
                let (b, r) = (t.join(format!("b{case}")), t.join(format!("r{case}")));
                for side in [&b, &r] {
                    make_prefix(&side.join("pfx"));
                    std::fs::create_dir_all(side.join("game")).unwrap();
                }
                let wine_b = fake_wine(&b.join("bin"), works);
                let wine_r = fake_wine(&r.join("bin"), works);
                let out = bash(
                    &format!(
                        "GAME_DIR=\"$1/game\" PREFIX_PATH=\"$1/pfx\" INSTALL_MANIFEST=\"$1/m\" GAME_NAME=G PRIMARY_DLL_NAME={dll}\n\
                         LAUNCHER_TYPE={lt} APPID=42 WINE_CMD=\"{wine}\" WINESERVER_CMD=\n\
                         apply_prefix_registry {com} {ov} > /dev/null; echo \"$REG_STATUS\"\n\
                         cp \"$1/pfx/user.reg\" \"$1/applied.reg\"\n\
                         if remove_prefix_registry {com} '{rm}' > /dev/null; then echo removed; else echo kept; fi",
                        dll = dll.unwrap_or("dsound"),
                        lt = if *steam { 1 } else { 2 },
                        wine = wine_b.display(),
                        com = if com { "y" } else { "n" },
                        ov = if dll.is_some() { "y" } else { "n" },
                        rm = dll.unwrap_or(""),
                    ),
                    &b,
                    &[
                        ("STUB_PREFIX", b.join("pfx").display().to_string()),
                        ("STUB_LOG", b.join("stub.log").display().to_string()),
                    ],
                );
                let p = Prefix {
                    path: r.join("pfx"),
                    runner: Some(if *steam {
                        Runner::Protontricks {
                            cmd: vec![stubs().join("protontricks").display().to_string()],
                            app_id: "42".into(),
                        }
                    } else {
                        Runner::Wine {
                            wine: wine_r.clone(),
                            wineserver: None,
                        }
                    }),
                    log: None,
                };
                // The stubs read these from the environment of the process
                // that runs them.
                let status = with_env(&r, || prefix::apply_registry(&p, &r.join("game"), com, dll));
                std::fs::copy(r.join("pfx/user.reg"), r.join("applied.reg")).unwrap();
                let removed = with_env(&r, || {
                    prefix::remove_registry(&p, &r.join("game"), com, dll)
                });
                let rust = format!(
                    "{}\n{}\n",
                    match status {
                        RegStatus::Ok => "ok",
                        RegStatus::Failed => "failed",
                        RegStatus::Missing => "missing",
                    },
                    if removed { "removed" } else { "kept" }
                );
                assert_eq!(
                    out,
                    rust,
                    "{case}\n{}",
                    std::fs::read_to_string(b.join("bash.log")).unwrap_or_default()
                );
                for f in ["applied.reg", "pfx/user.reg"] {
                    let read = |s: &Path| {
                        std::fs::read_to_string(s.join(f))
                            .unwrap()
                            .replace(&s.display().to_string(), "<dir>")
                    };
                    assert_eq!(read(&b), read(&r), "{case}: {f}");
                }
                let leftovers = |s: &Path| std::fs::read_dir(s.join("game")).unwrap().count();
                assert_eq!(leftovers(&b), 0, "{case}: no .reg file left behind");
                assert_eq!(leftovers(&r), 0, "{case}: no .reg file left behind");
                let calls = |s: &Path, log: &str| {
                    std::fs::read_to_string(s.join(log))
                        .unwrap_or_default()
                        .lines()
                        .map(|l| {
                            l.split(".eax-restore-")
                                .next()
                                .unwrap()
                                .replace(&s.display().to_string(), "<dir>")
                        })
                        .collect::<Vec<_>>()
                };
                assert_eq!(
                    calls(&b, "stub.log"),
                    calls(&r, "stub.log"),
                    "{case}: what ran"
                );
            }
        }
    }
}

/// Sets the stubs' variables for this process while `f` runs.
fn with_env<T>(side: &Path, f: impl FnOnce() -> T) -> T {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _g = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    std::env::set_var("STUB_PREFIX", side.join("pfx"));
    std::env::set_var("STUB_LOG", side.join("stub.log"));
    f()
}

#[test]
fn dll_copies_match() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    for arch in [32u8, 64] {
        for wow in [true, false] {
            let case = format!("{arch}-{wow}");
            let (b, r) = (t.join(format!("b{case}")), t.join(format!("r{case}")));
            for side in [&b, &r] {
                make_prefix(&side.join("pfx"));
                if !wow {
                    std::fs::remove_dir(side.join("pfx/drive_c/windows/syswow64")).unwrap();
                }
                let sys = prefix::system_dir(&side.join("pfx"), arch);
                // The prefix's own dsound.dll (Wine's), a DSOAL one an earlier
                // install left (recorded in its manifest), and no OpenAL32.
                std::fs::write(sys.join("DSOUND.DLL"), "wine's dsound").unwrap();
                std::fs::write(sys.join("dsoal-aldrv.dll"), "OpenAL Soft from before").unwrap();
                std::fs::create_dir_all(side.join("src")).unwrap();
                for f in ["dsound.dll", "aldrv.dll", "soft_oal.dll"] {
                    std::fs::write(side.join("src").join(f), format!("new {f}")).unwrap();
                }
            }
            let prev = |s: &Path| prefix::system_dir(&s.join("pfx"), arch).join("dsoal-aldrv.dll");
            bash(
                &format!(
                    "PREFIX_PATH=\"$1/pfx\" ARCH={arch} INSTALL_MANIFEST=\"$1/m\"\n\
                     declare -A PREV_MANIFEST_FILES=([\"{prev}\"]=1)\n\
                     DEPLOY_SRC=(\"$1/src/dsound.dll\" \"$1/src/aldrv.dll\" \"$1/src/soft_oal.dll\" \"$1/src/missing.dll\")\n\
                     DEPLOY_DEST_NAME=(dsound.dll dsoal-aldrv.dll OpenAL32.dll eax.dll)\n\
                     deploy_prefix_dlls > /dev/null 2>&1; true",
                    prev = prev(&b).display()
                ),
                &b,
                &[],
            );
            let previous: HashSet<Vec<u8>> = [prev(&r).display().to_string().into_bytes()].into();
            let files = [
                (r.join("src/dsound.dll"), "dsound.dll".to_string()),
                (r.join("src/aldrv.dll"), "dsoal-aldrv.dll".to_string()),
                (r.join("src/soft_oal.dll"), "OpenAL32.dll".to_string()),
                (r.join("src/missing.dll"), "eax.dll".to_string()),
            ];
            prefix::deploy_prefix_dlls(
                &r.join("pfx"),
                arch,
                &files,
                &previous,
                "STAMP",
                &r.join("m"),
            );
            let tree = |s: &Path| {
                let mut out = Vec::new();
                for sub in ["system32", "syswow64"] {
                    let Ok(e) = std::fs::read_dir(s.join("pfx/drive_c/windows").join(sub)) else {
                        continue;
                    };
                    let mut names: Vec<_> = e
                        .flatten()
                        .map(|e| {
                            let n = e.file_name().to_string_lossy().into_owned();
                            let n = n.split(".bak.").next().unwrap().to_string()
                                + if n.contains(".bak.") { ".bak" } else { "" };
                            (
                                format!("{sub}/{n}"),
                                std::fs::read_to_string(e.path()).unwrap(),
                            )
                        })
                        .collect();
                    names.sort();
                    out.extend(names);
                }
                out.push((
                    "manifest".into(),
                    std::fs::read_to_string(s.join("m"))
                        .unwrap_or_default()
                        .replace(&s.display().to_string(), "<dir>"),
                ));
                out
            };
            assert_eq!(tree(&b), tree(&r), "{case}");
        }
    }
}

#[test]
fn openal_runtime_and_prefix_lookup_match() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let (b, r) = (t.join("b"), t.join("r"));
    for side in [&b, &r] {
        make_prefix(&side.join("pfx"));
    }
    let wine_b = fake_wine(&b.join("bin"), true);
    let wine_r = fake_wine(&r.join("bin"), true);
    let out = bash(
        &format!(
            "PREFIX_PATH=\"$1/pfx\" GAME_NAME=G\n\
             LAUNCHER_TYPE=1 APPID=42; install_openal_runtime > /dev/null\n\
             LAUNCHER_TYPE=2 WINE_CMD=\"{}\" WINESERVER_CMD=\"$1/bin/wineserver\"; install_openal_runtime > /dev/null\n\
             LAUNCHER_TYPE=2; flush_wine_registry > /dev/null\n\
             steam_prefix_for_appid 42; echo \"[$?]\"",
            wine_b.display()
        ),
        &b,
        &[
            ("STUB_PREFIX", b.join("pfx").display().to_string()),
            ("STUB_LOG", b.join("stub.log").display().to_string()),
        ],
    );
    let pt = vec![stubs().join("protontricks").display().to_string()];
    let steam = Prefix {
        path: r.join("pfx"),
        runner: Some(Runner::Protontricks {
            cmd: pt.clone(),
            app_id: "42".into(),
        }),
        log: None,
    };
    let heroic = Prefix {
        path: r.join("pfx"),
        runner: Some(Runner::Wine {
            wine: wine_r,
            wineserver: Some(r.join("bin/wineserver")),
        }),
        log: None,
    };
    // winetricks is the stub on PATH for the Bash side; here it's run by name.
    let found = with_env(&r, || {
        let path = std::env::var("PATH").unwrap();
        std::env::set_var("PATH", format!("{}:{path}", stubs().display()));
        assert_eq!(steam.install_openal_runtime(), Some(0));
        assert_eq!(heroic.install_openal_runtime(), Some(0));
        heroic.wait_for_wineserver();
        let found = wine::steam_prefix_for_appid(&pt, "42");
        std::env::set_var("PATH", path);
        found
    });
    let rust = match found {
        Some(p) => format!("{}\n[0]\n", p.display()),
        None => "[1]\n".to_string(),
    };
    assert_eq!(
        out.replace(&b.display().to_string(), "<dir>"),
        rust.replace(&r.display().to_string(), "<dir>")
    );
    let calls = |s: &Path| {
        std::fs::read_to_string(s.join("stub.log"))
            .unwrap()
            .replace(&s.display().to_string(), "<dir>")
    };
    assert_eq!(calls(&b), calls(&r));
}

#[test]
fn heroic_runners_match() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let conf = home.join(".config/heroic/GamesConfig");
    std::fs::create_dir_all(&conf).unwrap();
    let ge = home.join("tools/proton/GE-Proton9");
    exe(&ge.join("files/bin/wine"), "");
    exe(&ge.join("files/bin/wineserver"), "");
    let wine = home.join("tools/wine/Wine-GE/bin");
    exe(&wine.join("wine"), "");
    exe(&wine.join("wineserver"), "");
    let pfx = home.join("Prefixes/G");
    let write = |id: &str, body: serde_json::Value| {
        std::fs::write(
            conf.join(format!("{id}.json")),
            serde_json::to_string_pretty(&body).unwrap(),
        )
        .unwrap();
    };
    write(
        "1",
        serde_json::json!({"1": {"winePrefix": pfx, "wineVersion": {"type": "proton", "name": "GE-Proton9", "bin": ge.join("proton")}}}),
    );
    write(
        "2",
        serde_json::json!({"2": {"winePrefix": format!("{}/", pfx.display()), "wineVersion": {"type": "wine", "name": "Wine-GE", "bin": wine.join("wine")}}}),
    );
    write(
        "3",
        serde_json::json!({"3": {"wineVersion": {"type": "wine", "name": "Gone", "bin": "/nowhere/wine", "wineserver": "/nowhere/wineserver"}}}),
    );
    write("4", serde_json::json!({"4": {"language": "en"}}));
    let mut script = String::new();
    let mut cases = Vec::new();
    for (id, use_own) in [
        ("1", true),
        ("2", true),
        ("3", true),
        ("4", true),
        ("4", false),
        ("9", true),
    ] {
        script.push_str(&format!(
            "HEROIC_GAME_ID={id} HEROIC_ROOT={} PREFIX_PATH=\"{}\" WINE_CMD=/usr/bin/wine WINESERVER_CMD= HEROIC_RUNNER_TYPE=\n\
             resolve_heroic_runner > /dev/null 2>&1; echo \"$?|$HEROIC_RUNNER_TYPE|$WINE_CMD|$WINESERVER_CMD|$HEROIC_JSON\"\n",
            if use_own { home.join(".config/heroic").display().to_string() } else { String::new() },
            pfx.display()
        ));
        cases.push((id, use_own));
    }
    let out = bash(&script, home, &[]);
    let lines: Vec<&str> = out.lines().collect();
    for ((id, use_own), b) in cases.iter().zip(lines) {
        let root = home.join(".config/heroic");
        let json =
            wine::heroic_runner_config(home, use_own.then_some(root.as_path()), Some(id), &pfx);
        let runner = json.as_deref().and_then(wine::heroic_runner);
        let found = runner.as_ref().and_then(|r| r.wine.clone());
        let rust = format!(
            "{}|{}|{}|{}|{}",
            if found.is_some() { 0 } else { 1 },
            runner.as_ref().map_or(String::new(), |r| r.kind.clone()),
            found.map_or("/usr/bin/wine".to_string(), |w| w.display().to_string()),
            runner
                .as_ref()
                .and_then(|r| r.wineserver.clone())
                .map_or(String::new(), |w| w.display().to_string()),
            json.map_or(String::new(), |j| j.display().to_string()),
        );
        assert_eq!(b, rust, "game {id}, own settings {use_own}");
    }
}

#[test]
fn exe_bitness_counts_match() {
    let tmp = tempfile::tempdir().unwrap();
    let g = tmp.path().join("game");
    let fx = repo_root().join("tests/fixtures");
    std::fs::create_dir_all(g.join("bin/deeper")).unwrap();
    std::fs::copy(fx.join("pe32.exe"), g.join("game.exe")).unwrap();
    std::fs::copy(fx.join("pe64.exe"), g.join("bin/Game64.EXE")).unwrap();
    std::fs::copy(fx.join("pe64.exe"), g.join("bin/tool.exe")).unwrap();
    std::fs::copy(fx.join("pe64.exe"), g.join("bin/setup.exe")).unwrap();
    std::fs::copy(fx.join("pe64.exe"), g.join("bin/deeper/too-deep.exe")).unwrap();
    std::fs::write(g.join("readme.exe"), "not a program").unwrap();
    std::os::unix::fs::symlink(g.join("game.exe"), g.join("link.exe")).unwrap();
    let out = bash(
        "A32=0; A64=0\n\
         while IFS= read -r -d '' exe; do if [[ $(file \"$exe\") == *\"PE32+\"* ]]; then A64=$((A64 + 1)); else A32=$((A32 + 1)); fi\n\
         done < <(find \"$1/game\" -maxdepth 2 -type f -iname \"*.exe\" -print0); echo \"$A32 $A64\"",
        tmp.path(),
        &[],
    );
    let (a32, a64) = wine::count_exe_bitness(&g);
    assert_eq!(out.trim(), format!("{a32} {a64}"));
    assert_eq!(wine::detect_architecture(&g), Some(64));
}
