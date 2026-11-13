//! Parity with the Bash script for an install's detection: name matching,
//! the exe folder's ranking, Linux builds, extra exe folders, the audio API
//! read from the game's files, the Steam AppID, companion apps, and a Heroic
//! game's prefix. Each case runs through `src/detection.sh` (and friends)
//! and the engine on the same fake folders.

use eax_restore::db::Database;
use eax_restore::engine::detect::{self, PrefixSource};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// Runs `script` with the script's functions loaded; `$1` is `dir`, also
/// `$HOME`. The C locale keeps `sort` in byte order, as the engine sorts.
fn bash(script: &str, dir: &Path, env: &[(&str, String)]) -> String {
    let full = format!(
        "for f in globals ui common logging detection game-database game-config launcher-config vcrun verify cache prefix-steps; do source \"$REPO/src/$f.sh\"; done\n\
         log_cmd() {{ :; }}\n[ -n \"${{ORACLE_DB:-}}\" ] && GAME_DATABASE_FILE=\"$ORACLE_DB\"\n{script}"
    );
    std::fs::write(dir.join(".oracle.sh"), full).unwrap();
    let out = Command::new("bash")
        .arg(dir.join(".oracle.sh"))
        .arg(dir)
        .env("REPO", repo_root())
        .env("HOME", dir)
        .env("LC_ALL", "C")
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

fn put(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

#[test]
fn names_and_junk_match() {
    let tmp = tempfile::tempdir().unwrap();
    let names = [
        "Gothic II",
        "Gothic II: Gold Edition",
        "Final Fantasy VII",
        "Rocky IV",
        "X-COM: Enforcer",
        "I Am Alive",
        "ii",
        "Vi Vii viii Ix",
        "Thief™ II: The Metal Age",
        "Baldur's Gate",
        "Half-Life 2",
        "Ünïcode Gäme",
        "",
    ];
    let exes = [
        "unins000.exe",
        "Uninstall.exe",
        "vc_redist.x86.exe",
        "DXSETUP.exe",
        "Game.exe",
        "GameLauncher.exe",
        "UnityCrashHandler64.exe",
        "reg.exe",
        "regedit.exe",
        "EAX4Unified_redist_4001.exe",
        "SomeUpdateLauncher.exe",
        "testapp.exe",
        "setup.exe",
        "physx_installer.exe",
        "game.EXE",
    ];
    let mut script = String::new();
    for n in names {
        std::fs::write(tmp.path().join("n"), n).unwrap();
        // It prints no line break of its own.
        script.push_str(&format!("normalize_game_name {}; echo\n", shell_quote(n)));
    }
    for e in exes {
        script.push_str(&format!(
            "_exe_is_junk {} && echo junk || echo game\n",
            shell_quote(&format!("/g/{e}"))
        ));
    }
    let out = bash(&script, tmp.path(), &[]);
    let rust: String = names
        .iter()
        .map(|n| format!("{}\n", detect::normalize_game_name(n)))
        .chain(exes.iter().map(|e| {
            format!(
                "{}\n",
                if detect::exe_is_junk(Path::new(&format!("/g/{e}"))) {
                    "junk"
                } else {
                    "game"
                }
            )
        }))
        .collect();
    assert_eq!(out, rust);
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// A set of installs, each a different way a game's folder can look.
fn installs(root: &Path) -> Vec<(PathBuf, &'static str)> {
    let g = |name: &str, files: &[(&str, &str)]| {
        let dir = root.join(name);
        std::fs::create_dir_all(&dir).unwrap();
        for (f, text) in files {
            put(&dir.join(f), text);
        }
        dir
    };
    vec![
        (
            g(
                "Simple Game",
                &[("Game.exe", "uses dsound.dll"), ("unins000.exe", "")],
            ),
            "",
        ),
        (
            g(
                "Gothic II",
                &[
                    ("System/Gothic2.exe", "DirectSound"),
                    ("Launcher/launcher.exe", ""),
                    ("Tools/editor.exe", ""),
                ],
            ),
            "",
        ),
        (
            g(
                "Nested",
                &[
                    ("bin/x64/Nested.exe", "OpenAL32.dll"),
                    ("bin/x86/tool.exe", "alcOpenDevice"),
                    ("redist/vcredist_x86.exe", ""),
                ],
            ),
            "",
        ),
        (
            g(
                "Double Agent",
                &[
                    ("launcher.exe", ""),
                    ("SCDA-Offline/System/SplinterCell4.exe", "dsound.dll"),
                    ("SCDA-Online/System/SCDA_MP.exe", "dsound.dll"),
                ],
            ),
            "SplinterCell4.exe",
        ),
        (
            g(
                "Hinted Upper",
                &[("Bin/GAME.EXE", "dsound.dll"), ("other.exe", "")],
            ),
            "game.exe",
        ),
        (
            g(
                "Only Junk",
                &[("setup/setup.exe", ""), ("redist/unins000.exe", "")],
            ),
            "",
        ),
        (
            g(
                "Audio Ranks",
                &[("aaa/Audio.exe", ""), ("zzz/Audio.exe", "DirectSound")],
            ),
            "",
        ),
        (
            g(
                "Stalker",
                &[
                    ("bin/xrEngine.exe", "OpenAL32.dll"),
                    ("bin/xrSound.dll", "dsound.dll"),
                    ("bin/OpenAL32.dll", "Creative router"),
                    ("bin/wrap_oal.dll", ""),
                ],
            ),
            "",
        ),
        (
            g("Both", &[("both.exe", "dsound.dll and OpenAL32.dll")]),
            "",
        ),
        (
            g(
                "Ours",
                &[
                    ("game.exe", ""),
                    ("dsound.dll", "dsound.dll DSOAL"),
                    ("OpenAL32.dll", "OpenAL Soft"),
                    ("a3dapi.dll", "DirectSound"),
                ],
            ),
            "",
        ),
        (
            g(
                "Main Wins",
                &[
                    ("Lithtech.exe", "DirectSound"),
                    ("binkw32.dll", "dsound.dll"),
                ],
            ),
            "Lithtech.exe",
        ),
        (g("Empty", &[]), ""),
        (
            g(
                "Linux Port",
                &[
                    ("game.x86_64", "\u{7f}ELFlinux"),
                    ("lib/libfoo.so.1", "\u{7f}ELF"),
                ],
            ),
            "",
        ),
    ]
}

#[test]
fn exe_folders_and_api_match() {
    let tmp = tempfile::tempdir().unwrap();
    let list = installs(&tmp.path().join("lib"));
    std::fs::set_permissions(
        tmp.path().join("lib/Linux Port/game.x86_64"),
        std::fs::Permissions::from_mode(0o755),
    )
    .unwrap();
    let mut script = String::from(
        "cands() { local root=\"$1\" exe_hint=\"$2\" root_norm; root_norm=\"$(normalize_game_name \"$(basename \"$root\")\")\"\n\
         local -a cand_dirs=(); local -A cand_exe_name=(); _exe_collect_candidates\n\
         for d in \"${cand_dirs[@]}\"; do printf '%s|%s\\n' \"$d\" \"${cand_exe_name[$d]}\"; done; }\n",
    );
    for (dir, hint) in &list {
        let d = shell_quote(&dir.display().to_string());
        let h = shell_quote(hint);
        script.push_str(&format!(
            "echo '--'; cands {d} {h}\n\
             install_is_linux_build {d} && echo linux || echo windows\n\
             folder_names_audio_api {d} && echo audio || echo quiet\n\
             detect_api_from_binary {d} {h} | tr '\\037' '|'; echo .\n"
        ));
    }
    let out = bash(&script, tmp.path(), &[]);
    let blocks: Vec<&str> = out.split("--\n").skip(1).collect();
    assert_eq!(blocks.len(), list.len());
    for ((dir, hint), b) in list.iter().zip(blocks) {
        let mut rust = String::new();
        for (d, name) in detect::exe_candidates(dir, hint) {
            rust.push_str(&format!("{}|{name}\n", d.display()));
        }
        rust.push_str(if detect::install_is_linux_build(dir) {
            "linux\n"
        } else {
            "windows\n"
        });
        rust.push_str(if detect::folder_names_audio_api(dir) {
            "audio\n"
        } else {
            "quiet\n"
        });
        if let Some(e) = detect::detect_api(dir, hint) {
            rust.push_str(&format!(
                "{}|{}|{}\n",
                e.api.name(),
                e.ds_file,
                e.openal_file
            ));
        }
        rust.push_str(".\n");
        assert_eq!(b, rust, "{}", dir.display());
    }
}

const DB: &str = r#"{"games":[{"id":"g","name":"Doom","exe":"Doom3.exe","stores":{
  "steam":{"id":9050,"extra_exe_folders":["game_root:bin_Crossplay","base","missing","../escape","/abs","BASE"],
           "companion_apps":[9070,"9071",9050,"x"]},
  "gog":{"id":77}}}]}"#;

#[test]
fn steam_lookups_match() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let lib = t.join("lib/steamapps");
    let acf = |id: &str, name: &str, dir: &str| {
        put(
            &lib.join(format!("appmanifest_{id}.acf")),
            &format!("\"AppState\"\n{{\n\t\"appid\"\t\t\"{id}\"\n\t\"name\"\t\t\"{name}\"\n\t\"installdir\"\t\t\"{dir}\"\n}}\n"),
        )
    };
    acf("9050", "DOOM 3", "Doom 3");
    acf("9070", "Resurrection of Evil", "Doom 3");
    acf("9100", "Other", "other game");
    let game = lib.join("common/Doom 3/bin");
    std::fs::create_dir_all(game.join("base")).unwrap();
    std::fs::create_dir_all(lib.join("common/Doom 3/bin_Crossplay")).unwrap();
    std::fs::create_dir_all(lib.join("common/Other Game")).unwrap();
    let pfx = t.join("pfx");
    std::fs::create_dir_all(pfx.join("drive_c")).unwrap();
    std::fs::write(t.join("db.json"), DB).unwrap();
    let stubs = repo_root().join("tests/fixtures/bin");
    let env = [
        ("ORACLE_DB", t.join("db.json").display().to_string()),
        ("STUB_PREFIX", pfx.display().to_string()),
        (
            "PATH",
            format!("{}:{}", stubs.display(), std::env::var("PATH").unwrap()),
        ),
    ];
    let out = bash(
        &format!(
            "for d in {g} {o}; do INSTALL_DIR=\"${{d#*/steamapps/common/}}\"; INSTALL_DIR=\"${{INSTALL_DIR%%/*}}\"\n\
             INSTALL_DIR_ESCAPED=$(printf '%s' \"$INSTALL_DIR\" | sed 's/[][\\.*^$]/\\\\&/g')\n\
             m=$(grep -il \"\\\"installdir\\\"\\s*\\\"$INSTALL_DIR_ESCAPED\\\"\" \"${{d%%/steamapps/common/*}}/steamapps\"/appmanifest_*.acf 2>/dev/null | head -n 1)\n\
             echo \"id:$(basename \"$m\" | tr -dc '0-9')\"; done\n\
             GAME_DIR={g}; GAME_INSTALL_ROOT=\"$(dirname {g})\"; resolve_extra_exe_folders 9050 steam; printf 'extra:%s\\n' \"${{EXTRA_GAME_DIRS[@]}}\"\n\
             LAUNCHER_TYPE=1; resolve_companion_apps 9050 > /dev/null 2>&1\n\
             for i in \"${{!COMPANION_IDS[@]}}\"; do echo \"companion:${{COMPANION_IDS[$i]}}|${{COMPANION_NAMES[$i]}}|${{COMPANION_PREFIXES[$i]}}\"; done",
            g = shell_quote(&game.display().to_string()),
            o = shell_quote(&lib.join("common/Other Game").display().to_string()),
        ),
        t,
        &env,
    );
    let db = Database::parse(DB).unwrap();
    let list = &db.games[0].stores.steam.as_ref().unwrap().extra_exe_folders;
    let mut rust = String::new();
    for d in [game.clone(), lib.join("common/Other Game")] {
        rust.push_str(&format!(
            "id:{}\n",
            detect::steam_appid_for_dir(&d).unwrap_or_default()
        ));
    }
    for e in detect::extra_exe_folders(&game, game.parent().unwrap(), list) {
        rust.push_str(&format!("extra:{}\n", e.display()));
    }
    let comps = {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let _g = LOCK.lock().unwrap();
        std::env::set_var("STUB_PREFIX", &pfx);
        detect::companion_apps(
            &db.games[0],
            "9050",
            &game,
            &[stubs.join("protontricks").display().to_string()],
        )
    };
    for c in comps {
        rust.push_str(&format!(
            "companion:{}|{}|{}\n",
            c.app_id,
            c.name,
            c.prefix.map_or(String::new(), |p| p.display().to_string())
        ));
    }
    assert_eq!(out, rust);
}

#[test]
fn heroic_prefixes_match() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let native = home.join(".config/heroic");
    let flat = home.join(".var/app/com.heroicgameslauncher.hgl/config/heroic");
    let games = home.join("Games/Heroic");
    // Installed from GOG, with its own prefix; nested under another key in a
    // second file; one with no prefix of its own (shared); one added by hand.
    put(
        &native.join("gog_store/installed.json"),
        &serde_json::json!({"installed": [
            {"appName": "100", "install_path": games.join("Own Prefix"), "platform": "windows"},
            {"appName": "200", "install_path": games.join("Shared"), "platform": "windows"},
            {"appName": "300", "install_path": games.join("Defaulted"), "platform": "windows"}
        ]})
        .to_string(),
    );
    put(
        &native.join("legendary/installed.json"),
        &serde_json::json!({"Epic": {"app_name": "epic1", "installPath": games.join("Epic Game")}})
            .to_string(),
    );
    put(
        &native.join("GamesConfig/100.json"),
        &format!(
            "{{\n  \"100\": {{\n    \"winePrefix\": \"{}\",\n    \"wineVersion\": {{}}\n  }}\n}}",
            games.join("Prefixes/Own").display()
        ),
    );
    put(&native.join("config.json"), "{\n  \"defaultSettings\": {\n    \"defaultWinePrefix\": \"~/Games/Heroic/Prefixes/default\"\n  }\n}");
    put(
        &native.join("sideload_apps/library.json"),
        &serde_json::to_string_pretty(&serde_json::json!({"games": [
            {"app_name": "sideXYZ", "title": "Hand Added", "folder_name": games.join("Hand Added"),
             "install": {"executable": games.join("Hand Added/bin/game.exe"), "platform": "windows"}},
            {"app_name": "sideABC", "title": "No Folder", "folder_name": "",
             "install": {"executable": games.join("No Folder/run/game.exe")}}
        ]}))
        .unwrap(),
    );
    // Flatpak Heroic knows the shared game under its own prefix.
    put(
        &flat.join("gog_store/installed.json"),
        &serde_json::json!({"installed": [
            {"appName": "200", "install_path": games.join("Shared")},
            {"appName": "400", "install_path": games.join("Flatpak Only")}
        ]})
        .to_string(),
    );
    // Flatpak Heroic sets a global prefix, which a game with none of its own uses.
    put(&flat.join("config.json"), "{\n  \"defaultSettings\": {\n    \"winePrefix\": \"~/Games/Heroic/Prefixes/Global/\"\n  }\n}");
    put(
        &flat.join("GamesConfig/200.json"),
        &format!(
            "{{\n  \"200\": {{\n    \"winePrefix\": \"{}/\"\n  }}\n}}",
            games.join("Prefixes/Flat").display()
        ),
    );
    std::fs::create_dir_all(games.join("Prefixes/default/Defaulted")).unwrap();
    let dirs = [
        games.join("Own Prefix"),
        games.join("Own Prefix/bin/x64"),
        games.join("Shared"),
        games.join("Defaulted"),
        games.join("Epic Game/sub"),
        games.join("Hand Added/bin"),
        games.join("No Folder/run"),
        games.join("Flatpak Only"),
        games.join("Unknown"),
        games.join("Own Prefix2"),
    ];
    let mut script = String::new();
    for d in &dirs {
        script.push_str(&format!(
            "detect_heroic_prefix_verbose {} 2>/dev/null | tr '\\037' '|'; echo .\n",
            shell_quote(&d.display().to_string())
        ));
    }
    let out = bash(&script, home, &[]);
    let rust: String = dirs
        .iter()
        .map(|d| match detect::heroic_game(d, home) {
            None => ".\n".to_string(),
            Some(g) => format!(
                "{}|{}|{}|{}|{}|{}\n.\n",
                g.prefix.map_or(String::new(), |p| p.display().to_string()),
                g.gog_app,
                g.id,
                match g.source {
                    Some(PrefixSource::Explicit) => "explicit",
                    Some(PrefixSource::Shared) => "shared",
                    Some(PrefixSource::Default) => "default",
                    None => "",
                },
                g.title,
                g.root.display()
            ),
        })
        .collect();
    assert_eq!(out, rust);
}
