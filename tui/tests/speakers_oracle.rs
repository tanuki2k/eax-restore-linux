//! Parity with the Bash script for the speaker setup and game identification:
//! each case runs through the function in `src/*.sh` and its Rust port.

use eax_restore::engine::identify::{identify_game_dir, Store};
use eax_restore::engine::speakers::{Layout, Listening, Output, Speakers};
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// Runs a snippet with the script's functions loaded and returns what it
/// printed. `$1` is `dir`, which is also `$HOME`.
fn bash(script: &str, dir: &Path) -> String {
    let full = format!(
        "for f in globals ui common detection game-config; do source \"$SRC/$f.sh\"; done\n{script}"
    );
    // From a file: a long script is more than one argument may hold.
    let file = dir.join(".oracle.sh");
    std::fs::write(&file, full).unwrap();
    let out = Command::new("bash")
        .arg(&file)
        .arg(dir)
        .env("SRC", repo_root().join("src"))
        .env("HOME", dir)
        .env("LC_ALL", "C.UTF-8")
        .output()
        .expect("bash runs");
    assert!(
        out.status.success(),
        "the Bash snippet failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn output_name(o: Output) -> &'static str {
    match o {
        Output::Stereo => "stereo",
        Output::Surround => "surround",
        Output::Matrix => "matrix",
    }
}

/// Every combination the struct can hold, including ones the questions never
/// give (HRTF on with stereo speakers can be read back from a file).
fn every_setup() -> Vec<Speakers> {
    let mut all = Vec::new();
    for output in [Output::Stereo, Output::Surround, Output::Matrix] {
        for listening in [Listening::Auto, Listening::Speakers, Listening::Headphones] {
            for hrtf in [false, true] {
                for layout in Layout::ALL {
                    all.push(Speakers {
                        output,
                        listening,
                        hrtf,
                        layout,
                    });
                }
            }
        }
    }
    all
}

/// The script's variables for a setup.
fn shell_vars(s: &Speakers) -> String {
    format!(
        "OUTPUT_MODE={} STEREO_MODE={} ENABLE_HRTF={} SURROUND_CHANNELS={}",
        output_name(s.output),
        s.listening.name(),
        if s.hrtf { "y" } else { "n" },
        if s.output == Output::Surround {
            s.layout.name()
        } else {
            ""
        },
    )
}

#[test]
fn alsoft_values_and_labels_match() {
    let tmp = tempfile::tempdir().unwrap();
    let setups = every_setup();
    let script: String = setups
        .iter()
        .map(|s| {
            format!(
                "{}; label=\"$(speaker_label)\"; speaker_alsoft_values; \
                 echo \"$ALSOFT_CHANNELS|$STEREO_MODE|$STEREO_ENCODING|$HRTF_MODE_PREFIX|$HRTF_MODE|$label\"\n",
                shell_vars(s)
            )
        })
        .collect();
    let out = bash(&script, tmp.path());
    let bash: Vec<&str> = out.lines().collect();
    assert_eq!(bash.len(), setups.len());
    for (s, b) in setups.iter().zip(bash) {
        let v = s.alsoft_values();
        let rust = format!(
            "{}|{}|{}|{}|full|{}",
            v.channels,
            v.stereo_mode,
            v.stereo_encoding,
            if v.hrtf_on { "" } else { "# " },
            s.label()
        );
        assert_eq!(b, rust, "{s:?}");
    }
}

#[test]
fn matching_matches() {
    let tmp = tempfile::tempdir().unwrap();
    let lists: Vec<Vec<&str>> = vec![
        vec!["stereo"],
        vec!["headphones"],
        vec!["surround"],
        vec!["matrix"],
        vec!["quad"],
        vec!["surround51", "surround71"],
        vec!["stereo", "headphones"],
        vec!["stereo", "matrix"],
        vec!["surround61"],
        vec![],
    ];
    let mut script = String::new();
    let mut cases = Vec::new();
    for s in every_setup() {
        for list in &lists {
            for has_headphones in [false, true] {
                script.push_str(&format!(
                    "{}; if speakers_match '{}' '{}'; then echo 1; else echo 0; fi\n",
                    shell_vars(&s),
                    list.join(","),
                    if has_headphones { "1" } else { "" }
                ));
                cases.push((s, list.clone(), has_headphones));
            }
        }
    }
    let out = bash(&script, tmp.path());
    let bash: Vec<&str> = out.lines().collect();
    assert_eq!(bash.len(), cases.len());
    for ((s, list, hp), b) in cases.iter().zip(bash) {
        let wanted: Vec<String> = list.iter().map(|x| x.to_string()).collect();
        assert_eq!(
            b == "1",
            s.matches(&wanted, *hp),
            "{s:?} against {list:?}, has headphones {hp}"
        );
    }
}

#[test]
fn reading_and_writing_alsoft_ini_match() {
    let tmp = tempfile::tempdir().unwrap();
    let d = tmp.path();
    let generated = "# Auto-generated by EAX Restore Script\r\n[general]\r\nchannels = stereo\r\nstereo-mode = auto\r\nstereo-encoding = basic\r\n# hrtf-mode = full\r\n\r\n[reverb]\r\nboost = 6\r\n";
    let files = [
        generated.to_string(),
        "[general]\nchannels=surround51\nstereo-mode=headphones\n".into(),
        "[general]\nchannels=stereo\nstereo-encoding=hrtf\nstereo-mode=speakers\n".into(),
        "[general]\nchannels=stereo\nstereo-encoding=tsme\n".into(),
        "[general]\nchannels=quad\n".into(),
        "[general]\nchannels=mono\n".into(),
        "[general]\nstereo-mode=headphones\n".into(),
        String::new(),
    ];
    // Read each file back.
    let mut script = String::new();
    for (i, text) in files.iter().enumerate() {
        std::fs::write(d.join(format!("read{i}.ini")), text).unwrap();
        script.push_str(&format!(
            "OUTPUT_MODE=; STEREO_MODE=; ENABLE_HRTF=; SURROUND_CHANNELS=\n\
             if speaker_config_from_alsoft \"$1/read{i}.ini\"; then \
             echo \"$OUTPUT_MODE|$STEREO_MODE|$ENABLE_HRTF|$SURROUND_CHANNELS|$(speaker_label)\"; else echo none; fi\n"
        ));
    }
    let out = bash(&script, d);
    let read_back: Vec<&str> = out.lines().collect();
    assert_eq!(read_back.len(), files.len());
    for (i, b) in read_back.iter().enumerate() {
        let rust = match Speakers::from_alsoft(&d.join(format!("read{i}.ini"))) {
            None => "none".to_string(),
            Some(s) => format!(
                "{}|{}|{}|{}|{}",
                output_name(s.output),
                s.listening.name(),
                if s.hrtf { "y" } else { "n" },
                if s.output == Output::Surround {
                    s.layout.name()
                } else {
                    ""
                },
                s.label()
            ),
        };
        assert_eq!(*b, rust, "reading {:?}", files[i]);
    }

    // Write every setup over the generated file, the way Tools → Speaker
    // configuration does (that code is inline in src/settings-flow.sh).
    let mut script = String::new();
    let setups = every_setup();
    for (i, s) in setups.iter().enumerate() {
        for side in ["bash", "rust"] {
            std::fs::write(d.join(format!("{side}{i}.ini")), generated).unwrap();
        }
        script.push_str(&format!(
            "{}; speaker_alsoft_values; f=\"$1/bash{i}.ini\"\n\
             config_set_key \"$f\" ini general channels \"$ALSOFT_CHANNELS\"\n\
             config_set_key \"$f\" ini general stereo-mode \"$STEREO_MODE\"\n\
             config_set_key \"$f\" ini general stereo-encoding \"$STEREO_ENCODING\"\n\
             [ -z \"$HRTF_MODE_PREFIX\" ] && config_set_key \"$f\" ini general hrtf-mode \"$HRTF_MODE\"\n\
             [ \"$OUTPUT_MODE\" == \"surround\" ] && config_set_key \"$f\" ini decoder hq-mode true\n\
             true\n",
            shell_vars(s)
        ));
        s.write_alsoft(&d.join(format!("rust{i}.ini"))).unwrap();
    }
    bash(&script, d);
    for (i, s) in setups.iter().enumerate() {
        let read = |side: &str| std::fs::read_to_string(d.join(format!("{side}{i}.ini"))).unwrap();
        assert_eq!(read("bash"), read("rust"), "writing {s:?}");
    }
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn acf(id: u32, name: &str, dir: &str) -> String {
    format!(
        "\"AppState\"\n{{\n\t\"appid\"\t\t\"{id}\"\n\t\"name\"\t\t\"{name}\"\n\t\"installdir\"\t\t\"{dir}\"\n}}\n"
    )
}

#[test]
fn identifying_a_game_folder_matches() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let lib = home.join("lib/steamapps");
    write(
        &lib.join("appmanifest_2210.acf"),
        &acf(2210, "Quake 4", "Quake 4"),
    );
    write(
        &lib.join("appmanifest_9050.acf"),
        &acf(9050, "DOOM 3", "Doom 3"),
    );
    std::fs::create_dir_all(lib.join("common/Quake 4/q4base")).unwrap();
    std::fs::create_dir_all(lib.join("common/Doom 3/base")).unwrap();
    std::fs::create_dir_all(lib.join("common/Unknown Game")).unwrap();

    // GOG: a base game with a DLC's info beside it, a DLC-only folder, a
    // broken info file, and one Heroic records under another ID.
    let gog = home.join("Games/Heroic");
    write(
        &gog.join("Base/goggame-200.info"),
        r#"{"gameId":"200","rootGameId":"100","name":"DLC"}"#,
    );
    write(
        &gog.join("Base/goggame-100.info"),
        r#"{"gameId":"100","rootGameId":"100","name":"Base Game"}"#,
    );
    std::fs::create_dir_all(gog.join("Base/bin/x86/deep/er")).unwrap();
    write(
        &gog.join("DlcOnly/goggame-300.info"),
        r#"{"gameId":"300","rootGameId":"299","name":"Only a DLC"}"#,
    );
    write(&gog.join("Broken/goggame-1.info"), "not json");
    write(
        &gog.join("Tactics/goggame-3.info"),
        r#"{"gameId":"3","rootGameId":"3","name":"Fallout Tactics"}"#,
    );
    write(&gog.join("NoIds/goggame-5.info"), r#"{"name":"No IDs"}"#);
    write(
        &home.join(".config/heroic/gog_store/installed.json"),
        &format!(
            r#"{{"installed":[{{"appName":"1207658938","install_path":"{}/"}}]}}"#,
            gog.join("Tactics").display()
        ),
    );

    let dirs: Vec<PathBuf> = vec![
        lib.join("common/Quake 4"),
        lib.join("common/Quake 4/q4base"),
        lib.join("common/Doom 3/base/"),
        lib.join("common/Unknown Game"),
        gog.join("Base"),
        gog.join("Base/bin/x86"),
        gog.join("Base/bin/x86/deep/er"),
        gog.join("DlcOnly"),
        gog.join("Broken"),
        gog.join("Tactics"),
        gog.join("NoIds"),
        home.join("Games"),
        home.to_path_buf(),
    ];
    let list: Vec<String> = dirs.iter().map(|d| d.display().to_string()).collect();
    std::fs::write(home.join("cases"), list.join("\n") + "\n").unwrap();
    let out = bash(
        "while IFS= read -r d; do
             if identify_game_dir \"$d\"; then echo \"$GAME_ID_STORE|$GAME_ID|$GAME_ID_NAME|$GAME_ID_ROOT\"
             else echo none; fi
         done < \"$1/cases\"",
        home,
    );
    let bash: Vec<&str> = out.lines().collect();
    assert_eq!(bash.len(), dirs.len());
    for (dir, b) in dirs.iter().zip(bash) {
        let rust = match identify_game_dir(dir, home) {
            None => "none".to_string(),
            Some(found) => format!(
                "{}|{}|{}|{}",
                match found.store {
                    Store::Steam => "steam",
                    Store::Gog => "gog",
                },
                found.id,
                found.name,
                found.root.display()
            ),
        };
        assert_eq!(b, rust, "identifying {}", dir.display());
    }
}
