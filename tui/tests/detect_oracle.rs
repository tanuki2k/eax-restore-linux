//! Parity with the Bash script for an install's detection: name matching,
//! the exe folder's ranking, Linux builds, extra exe folders, the audio API
//! read from the game's files, the Steam AppID, companion apps, and a Heroic
//! game's prefix. Each case runs through `src/detection.sh` (and friends)
//! and the engine on the same fake folders.

use eax_restore::db::Database;
use eax_restore::engine::detect::{self, PrefixSource};
use eax_restore::engine::wine_launchers;
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
        // The engine only reads these for the real home, so a fake one gets
        // the default folders on both sides.
        .env_remove("XDG_DATA_HOME")
        .env_remove("XDG_CONFIG_HOME")
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
        // BioShock names "openal32.dll" in lower case (the script's 260a578).
        (
            g(
                "Lower Case",
                &[("Game.exe", "openal32.dll"), ("sound.dll", "DirectSound")],
            ),
            "Game.exe",
        ),
        // BioShock's layout: the library gives the top folder, and the exe is
        // two folders below it, beside a redistributable naming dsound.dll.
        (
            g(
                "BioShock Layout",
                &[
                    ("Redist/dxsetup.dll", "dsound.dll"),
                    ("Builds/Release/Bioshock.exe", "openal32.dll and dsound.dll"),
                ],
            ),
            "Bioshock.exe",
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
    // The page and the headless install both move to the exe's folder.
    let (top, hint) = list
        .iter()
        .find(|(d, _)| d.ends_with("BioShock Layout"))
        .unwrap();
    let (dir, exe) = detect::exe_folder(top, hint);
    assert_eq!(dir, top.join("Builds/Release"));
    assert_eq!(exe.as_deref(), Some("Bioshock.exe"));
    let e = detect::detect_api(&dir, hint).unwrap();
    assert_eq!(e.api.name(), "both");
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

/// A fake home with a game in each Wine launcher, a Heroic GOG game whose
/// recorded exe is a tool, and junk folders.
fn launcher_world(h: &Path) {
    let exe = |p: &str| put(&h.join(p), "");
    let wine = |p: &str| {
        put(&h.join(p), "#!/bin/sh\n");
        std::fs::set_permissions(h.join(p), std::fs::Permissions::from_mode(0o755)).unwrap();
    };
    exe("Games/Deus Ex/System/DeusEx.exe");
    exe("Games/Deus Ex/Help/Readme.exe");
    exe("Games/Thief/THIEF.EXE");
    exe("Games/Rune/System/Rune.exe");
    exe("Games/Thief2/thief2.exe");
    exe("Games/Pk/Bin/Painkiller.exe");
    exe("Games/Pk/Data/Editor.exe");
    exe("Games/Pk/_CommonRedist/pk/pk.exe");
    exe("Games/Pk/Redist/DirectX/dxsetup.exe");
    wine(".local/share/lutris/runners/wine/wine-ge-8/bin/wine");
    wine(".local/share/bottles/runners/soda-9/bin/wine");
    wine(".local/share/bottles/runners/soda-9/bin/wineserver");
    wine(".local/share/Steam/compatibilitytools.d/GE-Proton9-20/files/bin/wine");
    wine(".local/share/Steam/compatibilitytools.d/GE-Proton10-1/files/bin/wine");
    std::fs::create_dir_all(h.join(".local/share/Steam/steamapps")).unwrap();
    put(
        &h.join(".local/share/lutris/games/deus-ex-1700.yml"),
        "game:\n  exe: System/DeusEx.exe  # the game\n  prefix: ~/pfx/deus\nwine:\n  dxvk: true\n",
    );
    put(
        &h.join(".local/share/lutris/games/thief-ii-the-metal-age-1800.yml"),
        &format!(
            "game:\n  exe: \"{}\"\n",
            h.join("Games/Thief2/thief2.exe").display()
        ),
    );
    put(
        &h.join(".config/lutris/runners/wine.yml"),
        "wine:\n  version: wine-ge-8\n",
    );
    let pga = h.join(".local/share/lutris/pga.db");
    let ok = Command::new("sqlite3")
        .arg(&pga)
        .arg(
            "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, slug TEXT, runner TEXT, directory TEXT, installed INTEGER, configpath TEXT);
             INSERT INTO games VALUES (1, 'Deus Ex: GOTY', 'deus-ex', 'wine', '~/Games/Deus Ex', 1, 'deus-ex-1700');
             INSERT INTO games VALUES (2, 'Gone', 'gone', 'wine', '~/Games/Gone', 0, 'gone-1');",
        )
        .status()
        .unwrap()
        .success();
    assert!(ok, "sqlite3 made the fake pga.db");
    put(
        &h.join(".local/share/bottles/bottles/Gaming/bottle.yml"),
        &format!(
            "Arch: win64\nExternal_Programs:\n  a1:\n    executable: THIEF.EXE\n    name: 'Thief: Gold'\n    path: {thief}\n  c3:\n    name: Old\n    path: {thief}\n    removed: true\nName: Gaming\nRunner: soda-9\n",
            thief = h.join("Games/Thief/THIEF.EXE").display()
        ),
    );
    wine(".local/share/Steam/compatibilitytools.d/Proton-CachyOS Latest/files/bin/wine");
    exe("Games/Sq5/Play Space Quest V.exe");
    put(
        &h.join(".config/faugus-launcher/config.json"),
        &serde_json::json!({"default-prefix": h.join("Faugus"), "default-runner": "Proton-CachyOS Latest"}).to_string(),
    );
    put(
        &h.join(".local/share/faugus-launcher/games.json"),
        &serde_json::json!([
            {"gameid": "rune", "title": " Rune ", "path": h.join("Games/Rune/System/Rune.exe"),
             "prefix": h.join("Faugus/rune"), "runner": "GE-Proton"},
            {"gameid": "play-space-quest-v", "title": "Play Space Quest V", "path": h.join("Games/Sq5/Play Space Quest V.exe"),
             "prefix": "", "runner": "Default"},
            {"gameid": "tux", "title": "Tux", "path": h.join("Games/Rune/System/Rune.exe"), "runner": "Linux-Native"}
        ])
        .to_string(),
    );
    put(
        &h.join(".config/heroic/gog_store/installed.json"),
        &serde_json::json!({"installed": [
            {"appName": "1", "install_path": format!("{}/", h.join("Games/Pk").display()), "executable": "Data/Editor.exe"}
        ]})
        .to_string(),
    );
}

fn records_text(list: &[wine_launchers::LauncherGame]) -> String {
    let p = |o: &Option<PathBuf>| {
        o.as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_default()
    };
    list.iter()
        .map(|g| {
            format!(
                "{}|{}|{}|{}|{}\n",
                g.launcher,
                g.title,
                g.exe.display(),
                p(&g.prefix),
                p(&g.wine)
            )
        })
        .collect()
}

#[test]
fn wine_launchers_match() {
    let tmp = tempfile::tempdir().unwrap();
    let h = tmp.path();
    launcher_world(h);
    let script = "wine_launcher_records | tr '\\037' '|'\n\
         echo --\n\
         for r in \"$HOME/Games/Pk\" \"$HOME/Games/Deus Ex\" \"$HOME/Games/Rune\" \"$HOME/Games/None\"; do printf '%s\\n' \"$(launcher_exe_for_root \"$r\")\"; done\n\
         echo --\n\
         for d in \"$HOME/Games/Thief\" \"$HOME/Games/Deus Ex\" \"$HOME/Games/Rune/System/sub\" \"$HOME/Games/Other\"; do\n\
           WINE_LAUNCHER=''; PREFIX_PATH=''; GAME_DIR=\"$d\"; attempt_auto_detect=0; _env_find_wine_launcher_prefix\n\
           echo \"$WINE_LAUNCHER|$WINE_LAUNCHER_WINE\"; done\n\
         echo --\n\
         for n in GE-Proton GE-Proton9-20 Missing ''; do printf '%s\\n' \"$(proton_wine_for \"$n\")\"; done\n\
         echo --\n\
         cands() { local root=\"$1\" exe_hint=\"$2\" launcher_exe=\"$3\" root_norm; root_norm=\"$(normalize_game_name \"$(basename \"$root\")\")\"\n\
           local -a cand_dirs=(); local -A cand_exe_name=(); _exe_collect_candidates\n\
           for d in \"${cand_dirs[@]}\"; do printf '%s|%s\\n' \"$d\" \"${cand_exe_name[$d]}\"; done; }\n\
         cands \"$HOME/Games/Pk\" '' \"$(launcher_exe_for_root \"$HOME/Games/Pk\")\"; echo .\n\
         cands \"$HOME/Games/Pk\" 'pk.exe' ''; echo .\n\
         cands \"$HOME/Games/Deus Ex\" '' \"$(launcher_exe_for_root \"$HOME/Games/Deus Ex\")\"; echo .\n";
    let out = bash(script, h, &[]);
    let parts: Vec<&str> = out.split("--\n").collect();
    assert_eq!(parts.len(), 5, "{out}");

    let list = wine_launchers::records(h);
    // No prefix of its own: Faugus's default-prefix/default.
    assert!(
        parts[0].contains(&format!("|{}|", h.join("Faugus/default").display())),
        "{}",
        parts[0]
    );
    assert_eq!(parts[0], records_text(&list));
    // pga.db decides which Lutris games there are: Thief II's YAML file
    // alone doesn't count while sqlite3 can read it.
    assert_eq!(list.len(), 4, "{}", parts[0]);
    assert!(
        parts[0].contains("|Play Space Quest V|")
            && parts[0].contains("Proton-CachyOS Latest/files/bin/wine"),
        "{}",
        parts[0]
    );

    let mut rust = String::new();
    for r in ["Games/Pk", "Games/Deus Ex", "Games/Rune", "Games/None"] {
        let e = wine_launchers::launcher_exe_for_root(h, &h.join(r));
        rust.push_str(&format!(
            "{}\n",
            e.map(|p| p.display().to_string()).unwrap_or_default()
        ));
    }
    assert_eq!(parts[1], rust);

    let mut rust = String::new();
    for d in [
        "Games/Thief",
        "Games/Deus Ex",
        "Games/Rune/System/sub",
        "Games/Other",
    ] {
        let g = wine_launchers::for_dir(h, &h.join(d));
        rust.push_str(&format!(
            "{}|{}\n",
            g.as_ref().map_or("", |g| g.launcher),
            g.and_then(|g| g.wine)
                .map(|w| w.display().to_string())
                .unwrap_or_default()
        ));
    }
    assert_eq!(parts[2], rust);

    let mut rust = String::new();
    for n in ["GE-Proton", "GE-Proton9-20", "Missing", ""] {
        rust.push_str(&format!(
            "{}\n",
            wine_launchers::proton_wine_for(h, n)
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        ));
    }
    assert_eq!(parts[3], rust);

    let mut rust = String::new();
    for (root, hint, launcher) in [
        ("Games/Pk", "", true),
        ("Games/Pk", "pk.exe", false),
        ("Games/Deus Ex", "", true),
    ] {
        let root = h.join(root);
        let le = launcher
            .then(|| wine_launchers::launcher_exe_for_root(h, &root))
            .flatten();
        for (d, name) in detect::exe_candidates_with(&root, hint, le.as_deref()) {
            rust.push_str(&format!("{}|{name}\n", d.display()));
        }
        rust.push_str(".\n");
    }
    assert_eq!(parts[4], rust);
    // The junk folders' exes are never offered, and the launcher's pick leads.
    assert!(!parts[4].contains("_CommonRedist") && !parts[4].contains("dxsetup"));
    assert!(parts[4].starts_with(&format!(
        "{}|Editor.exe\n",
        h.join("Games/Pk/Data").display()
    )));

    // Without pga.db both read the YAML files alone: Thief II's absolute
    // path counts, Deus Ex's relative one has no folder to go under.
    std::fs::remove_file(h.join(".local/share/lutris/pga.db")).unwrap();
    let out = bash("_lutris_records | tr '\\037' '|'", h, &[]);
    let rust = records_text(&wine_launchers::records(h)[..1]);
    assert_eq!(out, rust);
    assert!(out.starts_with("Lutris|Thief Ii The Metal Age|"), "{out}");

    // An older Faugus's config.ini, quotes and ~ included.
    std::fs::remove_file(h.join(".config/faugus-launcher/config.json")).unwrap();
    put(
        &h.join(".config/faugus-launcher/config.ini"),
        "default-prefix=\"~/Prefixes\"\ndefault-runner = \"GE-Proton9-20\"\n",
    );
    let out = bash("_faugus_records | tr '\\037' '|'", h, &[]);
    let faugus: Vec<_> = wine_launchers::records(h)
        .into_iter()
        .filter(|g| g.launcher == "Faugus")
        .collect();
    assert_eq!(out, records_text(&faugus));
    assert!(
        out.contains(&format!("|{}|", h.join("Prefixes/default").display())),
        "{out}"
    );
    assert!(out.contains("GE-Proton9-20/files/bin/wine"), "{out}");
}
