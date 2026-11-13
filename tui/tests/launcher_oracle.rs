//! Parity with the Bash script for launcher settings: the launch-option
//! string functions, Steam's localconfig.vdf, Heroic's GamesConfig JSON,
//! finding the settings file, and adding, removing and logging changes.
//! Each case runs through `src/launcher-config.sh` and its Rust port.

use eax_restore::engine::launcher::changes::{self, LogLevel, Written};
use eax_restore::engine::launcher::target::{steam_localconfig_for_app, Launcher, Target};
use eax_restore::engine::launcher::{heroic, options, vdf};
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// Runs a script with the launcher functions loaded; `$1` is `dir`, and
/// `$HOME` is `home`.
fn bash(script: &str, dir: &Path, home: &Path) -> String {
    let full = format!(
        "for f in globals ui common logging detection launcher-config; do source \"$SRC/$f.sh\"; done\n\
         log_cmd() {{ :; }}\ncompanion_name_for_id() {{ echo companion; }}\n{script}"
    );
    let file = dir.join(".oracle.sh");
    std::fs::write(&file, full).unwrap();
    let out = Command::new("bash")
        .arg(&file)
        .arg(dir)
        .env("SRC", repo_root().join("src"))
        .env("HOME", home)
        .env("LC_ALL", "C.UTF-8")
        .env("EAX_RESTORE_NO_LOG", "1")
        .stdin(std::process::Stdio::null())
        .output()
        .expect("bash runs");
    assert!(
        out.status.success(),
        "the Bash script failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// Writes each input to its own file, runs `body` once per file with the
/// input in `$v`, and returns one output per input (each ends with a NUL).
fn per_input(inputs: &[String], body: &str) -> Vec<String> {
    let tmp = tempfile::tempdir().unwrap();
    for (i, v) in inputs.iter().enumerate() {
        std::fs::write(tmp.path().join(format!("in{i}")), v).unwrap();
    }
    let out = bash(
        &format!(
            "for ((i = 0; i < {}; i++)); do v=\"$(cat \"$1/in$i\"; printf x)\"; v=\"${{v%x}}\"\n{body}\nprintf '\\0'\ndone",
            inputs.len()
        ),
        tmp.path(),
        tmp.path(),
    );
    let mut parts: Vec<String> = out.split('\0').map(str::to_string).collect();
    parts.pop();
    assert_eq!(parts.len(), inputs.len());
    parts
}

fn launch_options() -> Vec<String> {
    let mut v: Vec<String> = [
        "",
        "   ",
        "%command%",
        "-fps 60",
        "FOO=1 %command% -windowed",
        "WINEDLLOVERRIDES=\"d3d9=n,b\" %command%",
        "WINEDLLOVERRIDES=dsound=b %command%",
        "WINEDLLOVERRIDES='dsound,winmm=n' %command%",
        "WINEDLLOVERRIDES=\"ab\"cd e",
        "WINEDLLOVERRIDES=\"a b\"",
        "XWINEDLLOVERRIDES=x %command%",
        "A=1  WINEDLLOVERRIDES=\"x\"\tB=2 %command% %command%",
        "WINEDLLOVERRIDES=\"DSOUND.DLL=n;;x=b;\" %command%",
        "WINEDLLOVERRIDES= %command%",
        "DSOAL_LOGLEVEL=4 DSOAL_LOGFILE=\"Z:/g/dsoal.log\" %command%",
        "WINEDLLOVERRIDES=\"dsound=n,b\" DSOAL_LOGLEVEL=3 DSOAL_LOGFILE='a b' ALSOFT_LOGLEVEL=3 ALSOFT_LOGFILE=\"Z:/g/openal.log\" %command% -x",
        "  ALSOFT_LOGLEVEL=3   %command%",
        "%command% DSOAL_LOGFILE=x",
        "ADSOAL_LOGLEVEL=4 DSOAL_LOGLEVEL=4 %command%",
        "DSOAL_LOGFILE=\"x\"y %command%",
        "gamemoderun %command%\n",
        "a\nWINEDLLOVERRIDES=x\n%command%",
        "Ünïcode=1 %command% -näme",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    v.push(String::new());
    v
}

#[test]
fn launch_option_strings_match() {
    let inputs = launch_options();
    let body = r#"
        printf '%s\x1f' "$(launch_options_with_override "$v" dsound)" "$(launch_options_with_override "$v" OpenAL32.dll)" \
            "$(launch_options_without_dsoal_log "$v")" \
            "$(launch_options_with_dsoal_log "$v" 4 "Z:/g/dsoal.log")" \
            "$(launch_options_with_sound_log "$v" 3 "Z:/g/d.log" 3 "Z:/g/o.log")" \
            "$(launch_options_with_sound_log "$v" "" "" 3 "Z:/g/o.log")" \
            "$(launch_options_log_value "$v" DSOAL LEVEL)" "$(launch_options_log_value "$v" DSOAL FILE)" \
            "$(launch_options_log_value "$v" ALSOFT FILE)" \
            "$(merge_dll_override "$v" dsound)" "$(GAME_DIR=/g dsoal_log_path_for_linux "$v")"
    "#;
    for (v, b) in inputs.iter().zip(per_input(&inputs, body)) {
        let rust = [
            options::with_override(v, "dsound"),
            options::with_override(v, "OpenAL32.dll"),
            options::without_log(v),
            options::with_dsoal_log(v, "4", "Z:/g/dsoal.log"),
            options::with_sound_log(v, "3", "Z:/g/d.log", "3", "Z:/g/o.log"),
            options::with_sound_log(v, "", "", "3", "Z:/g/o.log"),
            options::log_value(v, "DSOAL", "LEVEL"),
            options::log_value(v, "DSOAL", "FILE"),
            options::log_value(v, "ALSOFT", "FILE"),
            options::merge_dll_override(v, "dsound"),
            options::log_path_for_linux(v, "/g"),
        ]
        .iter()
        .map(|s| format!("{s}\x1f"))
        .collect::<String>();
        assert_eq!(b, rust, "launch options {v:?}");
    }
    // Override lists, including ones the launch options never hold.
    let lists: Vec<String> = [
        "",
        ";",
        "dsound",
        "DSOUND=n;winmm=n",
        "dsound,winmm=n,b",
        ",dsound,=b",
        "a=b=c;dsound.DLL",
        "x;;y;",
        "  dsound =n",
        "a\nb",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let out = per_input(
        &lists,
        r#"merge_dll_override "$v" dsound; merge_dll_override "$v" OpenAL32.DLL"#,
    );
    for (l, b) in lists.iter().zip(out) {
        let rust = format!(
            "{}\n{}\n",
            options::merge_dll_override(l, "dsound"),
            options::merge_dll_override(l, "OpenAL32.DLL")
        );
        assert_eq!(b, rust, "override list {l:?}");
    }
}

const VDF: &str = "\"UserLocalConfigStore\"\n{\n\t\"Software\"\n\t{\n\t\t\"Valve\"\n\t\t{\n\t\t\t\"Steam\"\n\t\t\t{\n\t\t\t\t\"apps\"\n\t\t\t\t{\n\t\t\t\t\t\"111\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"LaunchOptions\"\t\t\"-old \\\"quoted\\\" C:\\\\dir\"\n\t\t\t\t\t\t\"Playtime\"\t\t\"5\"\n\t\t\t\t\t}\n\t\t\t\t\t\"222\"\n\t\t\t\t\t{\n\t\t\t\t\t\t\"Playtime\"\t\t\"7\"\n\t\t\t\t\t\t\"cloud\"\n\t\t\t\t\t\t{\n\t\t\t\t\t\t\t\"LaunchOptions\"\t\t\"nested\"\n\t\t\t\t\t\t}\n\t\t\t\t\t}\n\t\t\t\t\t\"333\"\n\t\t\t\t\t{\n\t\t\t\t\t}\n\t\t\t\t}\n\t\t\t}\n\t\t}\n\t}\n\t\"apps\"\n\t{\n\t\t\"111\"\n\t\t{\n\t\t\t\"LaunchOptions\"\t\t\"decoy\"\n\t\t}\n\t}\n}";

#[test]
fn vdf_reads_and_writes_match() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let values = [
        Some("WINEDLLOVERRIDES=\"dsound=n,b\" %command%"),
        Some("a\\b \"c\"\ttab\nline"),
        Some(""),
        None,
    ];
    let mut script = String::new();
    let mut cases = Vec::new();
    // The last one's 333 block starts with an unindented line, so the indent
    // for a new LaunchOptions line comes from the line after it.
    let odd = VDF.replace(
        "\t\t\t\t\t\"333\"\n\t\t\t\t\t{\n\t\t\t\t\t}",
        "\t\t\t\t\t\"333\"\n\t\t\t\t\t{\n\"a\"\t\"1\"\n\t\t\t\t\t\t\"b\"\t\"2\"\n\t\t\t\t\t}",
    );
    assert_ne!(odd, VDF);
    let files = [
        VDF.to_string(),
        format!("{VDF}\n"),
        VDF.replace('\t', "  "),
        odd,
    ];
    for (vi, text) in files.iter().enumerate() {
        for app in ["111", "222", "333", "444"] {
            script.push_str(&format!(
                "vdf_get_launch_options \"$1/v{vi}\" {app}; printf '\\0'\n"
            ));
            for (k, val) in values.iter().enumerate() {
                let name = format!("v{vi}-{app}-{k}");
                for side in ["bash", "rust"] {
                    std::fs::write(d.join(format!("{side}-{name}")), text).unwrap();
                }
                let arg = val.map_or("__DELETE__".to_string(), str::to_string);
                std::fs::write(d.join(format!("val-{name}")), &arg).unwrap();
                script.push_str(&format!(
                    "vdf_set_launch_options \"$1/bash-{name}\" {app} \"$(cat \"$1/val-{name}\")\"\n"
                ));
                vdf::set_file(&d.join(format!("rust-{name}")), app, *val).unwrap();
                cases.push(name);
            }
        }
        std::fs::write(d.join(format!("v{vi}")), text).unwrap();
    }
    let out = bash(&script, d, d);
    let gets: Vec<&str> = out.split('\0').collect();
    let mut i = 0;
    for vi in 0..files.len() {
        for app in ["111", "222", "333", "444"] {
            let rust = match vdf::get_file(&d.join(format!("v{vi}")), app) {
                vdf::LaunchOptions::NoApp => "__NOAPP__\n".to_string(),
                vdf::LaunchOptions::Absent => "__ABSENT__\n".to_string(),
                vdf::LaunchOptions::Set(s) => format!("{s}\n"),
            };
            assert_eq!(gets[i], rust, "reading {app} from file {vi}");
            i += 1;
        }
    }
    for name in cases {
        let read = |side: &str| std::fs::read_to_string(d.join(format!("{side}-{name}"))).unwrap();
        assert_eq!(read("bash"), read("rust"), "writing {name}");
    }
}

const HEROIC: &str = r#"{
  "1207658938": {
    "autoInstallDxvk": true,
    "enviromentOptions": [
      {
        "key": "WINEDLLOVERRIDES",
        "value": "d3d9=n"
      },
      {
        "key": "NUM",
        "value": 5
      },
      {
        "key": "OFF",
        "value": false
      }
    ],
    "wineVersion": {
      "bin": "/usr/bin/wine",
      "name": "Wine Default",
      "type": "wine"
    },
    "nothing": {},
    "none": []
  },
  "other": {
    "enviromentOptions": []
  },
  "version": "v0"
}"#;

#[test]
fn heroic_reads_and_writes_match() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let files = [
        HEROIC.to_string(),
        r#"{"1207658938":{"language":"en"}}"#.to_string(),
        r#"{"x":1}"#.to_string(),
        "not json".to_string(),
    ];
    let apps = ["1207658938", "other", "missing"];
    let vars = ["WINEDLLOVERRIDES", "NUM", "OFF", "NEW"];
    let vals = [Some("dsound=n,b"), Some("a \"b\" \\c"), None];
    let mut script = String::new();
    let mut cases = Vec::new();
    for (fi, text) in files.iter().enumerate() {
        std::fs::write(d.join(format!("h{fi}")), text).unwrap();
        for app in apps {
            for var in vars {
                script.push_str(&format!(
                    "heroic_get_env \"$1/h{fi}\" {app} {var}; printf '\\0'\n"
                ));
                for (k, val) in vals.iter().enumerate() {
                    let name = format!("h{fi}-{app}-{var}-{k}");
                    for side in ["bash", "rust"] {
                        std::fs::write(d.join(format!("{side}-{name}")), text).unwrap();
                    }
                    let arg = val.map_or("__DELETE__".to_string(), str::to_string);
                    std::fs::write(d.join(format!("val-{name}")), &arg).unwrap();
                    script.push_str(&format!(
                        "if heroic_set_env \"$1/bash-{name}\" {app} {var} \"$(cat \"$1/val-{name}\")\"; then echo 1; else echo 0; fi > \"$1/rc-{name}\"\n"
                    ));
                    let ok = heroic::set_env_file(&d.join(format!("rust-{name}")), app, var, *val)
                        .is_ok();
                    cases.push((name, ok));
                }
            }
        }
    }
    script.push_str("heroic_get_env \"$1/nofile\" a WINEDLLOVERRIDES; printf '\\0'\n");
    let out = bash(&script, d, d);
    let mut gets = out.split('\0');
    for fi in 0..files.len() {
        for app in apps {
            for var in vars {
                let rust = match heroic::get_env(&d.join(format!("h{fi}")), app, var) {
                    heroic::EnvValue::NoApp => "__NOAPP__\n".to_string(),
                    heroic::EnvValue::Absent => "__ABSENT__\n".to_string(),
                    heroic::EnvValue::Set(s) => format!("{s}\n"),
                };
                assert_eq!(
                    gets.next().unwrap(),
                    rust,
                    "reading {var} for {app} from file {fi}"
                );
            }
        }
    }
    assert_eq!(gets.next().unwrap(), "__NOAPP__\n");
    for (name, ok) in cases {
        let rc = std::fs::read_to_string(d.join(format!("rc-{name}"))).unwrap();
        assert_eq!(rc.trim() == "1", ok, "{name}: did the write succeed");
        let read = |side: &str| std::fs::read_to_string(d.join(format!("{side}-{name}"))).unwrap();
        assert_eq!(read("bash"), read("rust"), "writing {name}");
    }
}

fn touch(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn set_mtime(path: &Path, secs: u64) {
    let t = std::time::UNIX_EPOCH + std::time::Duration::from_secs(secs);
    std::fs::File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_modified(t)
        .unwrap();
}

#[test]
fn finding_the_localconfig_matches() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let native = home.join(".local/share/Steam");
    let flat = home.join(".var/app/com.valvesoftware.Steam/.local/share/Steam");
    for root in [&native, &flat] {
        std::fs::create_dir_all(root.join("steamapps")).unwrap();
    }
    let a = native.join("userdata/100/config/localconfig.vdf");
    let b = native.join("userdata/200/config/localconfig.vdf");
    let c = flat.join("userdata/300/config/localconfig.vdf");
    touch(&a, VDF);
    touch(&b, &VDF.replace("\"111\"", "\"999\""));
    touch(&c, VDF);
    set_mtime(&a, 1_000);
    set_mtime(&b, 3_000);
    set_mtime(&c, 2_000);
    let out = bash(
        "for app in 111 222 999 444; do steam_localconfig_for_app $app; done",
        tmp.path(),
        &home,
    );
    let bash: Vec<&str> = out.lines().collect();
    let rust: Vec<String> = ["111", "222", "999", "444"]
        .iter()
        .map(|app| {
            steam_localconfig_for_app(&home, None, app)
                .map_or(String::new(), |p| p.display().to_string())
        })
        .collect();
    assert_eq!(bash, rust);
}

/// Writes, reverts and turns logging on and off in matching Steam and Heroic
/// files on both sides, comparing the files and outcomes after each step.
#[test]
fn launcher_changes_match() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let starts = [
        ("steam", "111", VDF.to_string()),
        ("steam", "222", VDF.to_string()),
        (
            "steam",
            "111",
            VDF.replace(
                "-old \\\"quoted\\\" C:\\\\dir",
                "DSOAL_LOGLEVEL=4 DSOAL_LOGFILE=\\\"Z:/x/dsoal.log\\\" %command%",
            ),
        ),
        (
            "steam",
            "111",
            VDF.replace("-old \\\"quoted\\\" C:\\\\dir", "a\\tb"),
        ),
        ("heroic", "1207658938", HEROIC.to_string()),
        ("heroic", "other", HEROIC.to_string()),
    ];
    let mut script = String::from(
        "wait_for_launcher_closed() { return 0; }\nreopen_launchers() { :; }\n\
         print_status() { :; }; print_warning_arrow() { :; }; print_error_arrow() { :; }\n",
    );
    let mut rust_out = Vec::new();
    for (i, (launcher, id, text)) in starts.iter().enumerate() {
        let file = |side: &str| d.join(format!("{side}{i}/cfg"));
        for side in ["bash", "rust"] {
            touch(&file(side), text);
        }
        let game_dir = format!("/games/G{i}");
        // An install adds the override, then the log goes on and off, then
        // an uninstall takes the override out.
        script.push_str(&format!(
            "OVERRIDE_LAUNCHER={launcher} OVERRIDE_FILE=\"$1/bash{i}/cfg\" OVERRIDE_ID={id} APPID={id} GAME_DIR={game_dir} GAME_NAME=G\n\
             PRIMARY_DLL_NAME=dsound INSTALL_MANIFEST=\"$1/bash{i}/m\"; PREV_LAUNCHER_LINES=(); : > \"$INSTALL_MANIFEST\"\n\
             if _write_launcher_override > /dev/null; then echo ok; else echo no; fi; cat \"$INSTALL_MANIFEST\"; echo .\n"
        ));
        let t = Target {
            launcher: Launcher::from_key(launcher).unwrap(),
            file: file("rust"),
            id: id.to_string(),
        };
        let w = changes::write_override(&t, "dsound", &[], &game_dir);
        let line = match &w {
            Written::Set(l) => format!("{l}\n"),
            Written::Already(Some(l)) => format!("{l}\n"),
            _ => String::new(),
        };
        let ok = matches!(w, Written::Set(_) | Written::Already(_));
        rust_out.push(format!(
            "{}\n{}.\n",
            if ok { "ok" } else { "no" },
            line.replace(
                &d.join(format!("rust{i}")).display().to_string(),
                &d.join(format!("bash{i}")).display().to_string()
            )
        ));
        // Logging on, the way the Tools flow does it (inline there).
        for (level, has_dsoal) in [
            (Some(LogLevel::Full), true),
            (None, true),
            (Some(LogLevel::Basic), false),
            (None, false),
        ] {
            let snippet = match (*launcher, level) {
                ("steam", _) => format!(
                    "o=\"$(launcher_override_get)\"; [ \"$o\" == \"__ABSENT__\" ] && o=\"\"\n\
                     {}\n\
                     [ -e \"$OVERRIDE_FILE.eax-restore.bak\" ] || cp -p \"$OVERRIDE_FILE\" \"$OVERRIDE_FILE.eax-restore.bak\"\n\
                     e=\"$n\"; case \"${{n//[[:space:]]/}}\" in \"\"|\"%command%\") n=__DELETE__; e=__ABSENT__ ;; esac\n\
                     if launcher_override_set \"$n\" && [ \"$(launcher_override_get)\" == \"$e\" ]; then echo ok; else echo no; fi\n",
                    match level {
                        Some(l) => format!(
                            "n=\"$(launch_options_with_sound_log \"$o\" \"{}\" \"$(dsoal_log_path_for_wine \"$GAME_DIR\")\" 3 \"$(alsoft_log_path_for_wine \"$GAME_DIR\")\")\"",
                            if has_dsoal { l.dsoal_value() } else { "" }
                        ),
                        None => "n=\"$(launch_options_without_dsoal_log \"$o\")\"".to_string(),
                    }
                ),
                (_, Some(l)) => format!(
                    "w=\"$(dsoal_log_path_for_wine \"$GAME_DIR\")\"; a=\"$(alsoft_log_path_for_wine \"$GAME_DIR\")\"\n\
                     if {{ {} || {{ heroic_set_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" DSOAL_LOGLEVEL {} && heroic_set_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" DSOAL_LOGFILE \"$w\"; }}; }} \
                     && heroic_set_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" ALSOFT_LOGLEVEL 3 && heroic_set_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" ALSOFT_LOGFILE \"$a\" \
                     && [ \"$(heroic_get_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" ALSOFT_LOGLEVEL)\" == 3 ]; then echo ok; else echo no; fi\n",
                    if has_dsoal { "false" } else { "true" },
                    l.dsoal_value()
                ),
                (_, None) => "ok=ok; for x in DSOAL_LOGLEVEL DSOAL_LOGFILE ALSOFT_LOGLEVEL ALSOFT_LOGFILE; do \
                     case \"$(heroic_get_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" \"$x\")\" in __ABSENT__|__NOAPP__) ;; *) heroic_set_env \"$OVERRIDE_FILE\" \"$OVERRIDE_ID\" \"$x\" __DELETE__ || ok=no ;; esac; done; echo $ok\n"
                    .to_string(),
            };
            script.push_str(&snippet);
            let ok = changes::set_sound_log(&t, &game_dir, has_dsoal, level);
            rust_out.push(format!("{}\n", if ok { "ok" } else { "no" }));
        }
        // And on once more, so the uninstall below has logs to drop.
        script.push_str(&format!(
            "OVERRIDE_LAUNCHER={launcher} OVERRIDE_FILE=\"$1/bash{i}/cfg\" OVERRIDE_ID={id}\n"
        ));
        let lines = std::fs::read_to_string(d.join(format!("bash{i}/m"))).unwrap_or_default();
        let _ = lines;
        script.push_str(
            "LAUNCHER_LINES=(); while IFS= read -r l; do [[ \"$l\" == LAUNCHER:* ]] && LAUNCHER_LINES+=(\"$l\"); done < \"$INSTALL_MANIFEST\"\n\
             declare -A LAUNCHER_REMOVE_DECLINED=(); revert_launcher_overrides > /dev/null; echo \"kept ${#LAUNCHER_LINES_KEPT[@]}\"\n",
        );
        let mut kept = 0;
        if let Written::Set(l) = &w {
            if changes::revert_override(l) == changes::Reverted::Failed {
                kept += 1;
            }
        }
        rust_out.push(format!("kept {kept}\n"));
    }
    let out = bash(&script, d, d);
    assert_eq!(out, rust_out.concat());
    for i in 0..starts.len() {
        let read = |side: &str| std::fs::read_to_string(d.join(format!("{side}{i}/cfg"))).unwrap();
        assert_eq!(read("bash"), read("rust"), "case {i}: the settings file");
        let bak = |side: &str| {
            std::fs::read_to_string(d.join(format!("{side}{i}/cfg.eax-restore.bak"))).ok()
        };
        assert_eq!(bak("bash"), bak("rust"), "case {i}: the backup");
    }
}
