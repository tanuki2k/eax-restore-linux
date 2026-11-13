//! Parity with the Bash script for a game's own settings: the rows built
//! from the database, the survey that sorts each setting (`_gs_build_plan`,
//! run without its prompts), and applying a plan and rewriting the
//! manifest (`apply_game_settings`, `update_game_settings_in_manifest`).

use eax_restore::db::{Database, Game};
use eax_restore::engine::apply::{self, Host, RevertGroup};
use eax_restore::engine::config::paths::Places;
use eax_restore::engine::game_settings::{self, Category, Fix, Purpose, Status, Survey};
use eax_restore::engine::identify::Store;
use eax_restore::engine::speakers::{Layout, Listening, Speakers};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("tui/ sits in the repository")
        .to_path_buf()
}

/// Runs a script with the script's functions loaded. `$1` is `dir`; `$HOME`
/// is a folder of its own so no path is shortened to `~`.
fn bash(script: &str, dir: &Path, env: &[(&str, String)]) -> String {
    let full = format!(
        "for f in globals ui common logging cache detection game-database game-config; do source \"$SRC/$f.sh\"; done\n\
         log_cmd() {{ :; }}\n\
         # globals.sh sets its own; the test's database goes in after it.\n\
         [ -n \"${{ORACLE_DB:-}}\" ] && GAME_DATABASE_FILE=\"$ORACLE_DB\"\n{script}"
    );
    let file = dir.join(".oracle.sh");
    std::fs::write(&file, full).unwrap();
    let home = dir.join(".home");
    std::fs::create_dir_all(&home).unwrap();
    let out = Command::new("bash")
        .arg(&file)
        .arg(dir)
        .env("SRC", repo_root().join("src"))
        .env("HOME", &home)
        .env("USER", "player")
        .env("LC_ALL", "C.UTF-8")
        .envs(env.iter().map(|(k, v)| (*k, v.as_str())))
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

fn database() -> Database {
    Database::load(&repo_root().join("game-database.json")).unwrap()
}

/// The store and id to look a game up by, and whether it's the first game
/// with that id (the script's lookup takes the first).
fn lookup(db: &Database, game: &Game) -> Option<(Store, String)> {
    let (store, id) = match (&game.stores.steam, &game.stores.gog) {
        (Some(s), _) => (Store::Steam, s.id),
        (None, Some(g)) => (Store::Gog, g.id),
        _ => return None,
    };
    let first = db.games.iter().find(|g| {
        let s = match store {
            Store::Steam => g.stores.steam.as_ref(),
            Store::Gog => g.stores.gog.as_ref(),
        };
        s.is_some_and(|s| s.id == id)
    })?;
    std::ptr::eq(first, game).then(|| (store, id.to_string()))
}

fn rust_row(r: &game_settings::Row) -> String {
    let br = |s: &str| s.replace('\n', "\x1e");
    [
        r.category.name().to_string(),
        r.index.to_string(),
        r.title.clone(),
        br(&r.reason),
        r.stores.join(","),
        r.speakers.join(","),
        br(&r.follow_up),
        r.file.clone(),
        r.format.clone(),
        r.if_missing.clone(),
        r.locations.clone(),
        r.section.clone(),
        r.key.clone(),
        String::from_utf8_lossy(r.value.as_bytes()).into_owned(),
        if r.untested { "1" } else { "" }.to_string(),
        if r.all_locations { "1" } else { "" }.to_string(),
    ]
    .join("\x1f")
}

#[test]
fn every_games_rows_match() {
    let tmp = tempfile::tempdir().unwrap();
    let db = database();
    let games: Vec<(&Game, Store, String)> = db
        .games
        .iter()
        .filter_map(|g| lookup(&db, g).map(|(s, id)| (g, s, id)))
        .collect();
    assert!(games.len() > 50);
    let mut script = String::new();
    for (_, store, id) in &games {
        for mode in ["", "all"] {
            script.push_str(&format!(
                "load_game_config_rows {id} {} {mode}; echo '--end--'\n",
                store.key()
            ));
        }
    }
    let env = [(
        "ORACLE_DB",
        repo_root().join("game-database.json").display().to_string(),
    )];
    let out = bash(&script, tmp.path(), &env);
    let mut blocks = out.split("--end--\n");
    let mut checked = 0;
    for (game, _, _) in &games {
        for all in [false, true] {
            let bash: Vec<&str> = blocks.next().unwrap().lines().collect();
            let rust: Vec<String> = game_settings::rows(game, all)
                .iter()
                .map(rust_row)
                .collect();
            assert_eq!(bash, rust, "{} (untested included: {all})", game.name);
            checked += rust.len();
        }
    }
    assert!(checked > 200, "only {checked} rows compared");
}

fn status_name(s: Status) -> &'static str {
    match s {
        Status::Offer => "offer",
        Status::Already => "already",
        Status::Applied => "applied",
        Status::Missing => "missing",
        Status::Absent => "absent",
        Status::Skip => "skip",
        Status::Invalid => "invalid",
    }
}

/// A fix as the Bash harness below prints it.
fn rust_fix(f: &Fix) -> Vec<String> {
    let mut out = vec![format!(
        "{}:{}|{}|{}|{}|{}",
        f.category.name(),
        f.index,
        status_name(f.status),
        f.missing_file.clone().unwrap_or_default(),
        f.absent_files.join("|"),
        f.files.join("|")
    )];
    for r in &f.plan {
        out.push(format!(
            "R {}",
            [
                r.category.name().to_string(),
                r.title.clone(),
                r.path.display().to_string(),
                r.format.name().to_string(),
                r.section.clone(),
                r.key.clone(),
                String::from_utf8_lossy(r.new.as_bytes()).into_owned(),
                r.file.clone(),
                String::from_utf8_lossy(r.old.as_bytes()).into_owned(),
                if r.create { "create" } else { "found" }.to_string(),
            ]
            .join("\x1f")
        ));
    }
    for v in &f.view {
        let old = v.old.as_ref().map_or("__SET__".to_string(), |o| {
            String::from_utf8_lossy(o.as_bytes()).into_owned()
        });
        out.push(format!(
            "V {}\x1f{}\x1f{}\x1f{}\x1f{}",
            v.path.display(),
            v.section,
            v.key,
            old,
            String::from_utf8_lossy(v.new.as_bytes())
        ));
    }
    out
}

/// Runs `_gs_build_plan` with game_settings_step's locals and prints every
/// fix's status, plan rows and view rows.
const SURVEY: &str = r#"
survey() {
    local -a rows=()
    local row
    while IFS= read -r row; do [ -n "$row" ] && rows+=("$row"); done < <(load_game_config_rows "$KG_ID" "$KG_STORE")
    local has_headphones=""
    for row in "${rows[@]}"; do
        [[ ",$(cut -d $'\x1f' -f 6 <<< "$row")," == *",headphones,"* ]] && has_headphones=1 && break
    done
    local step=1 audio_heading_shown=1 optional_heading_shown=1 audio_seen=0
    local -a fix_order=()
    local -A fix_title=() fix_reason=() fix_follow=() fix_status=() fix_rows=() fix_missing_file=() fix_untested=() fix_view=()
    local -A fix_absent_files=() fix_has_file=() fix_files=()
    local -A file_path=() file_state=()
    [ ${#rows[@]} -gt 0 ] && _gs_build_plan > /dev/null
    local id
    for id in "${fix_order[@]}"; do
        printf '%s|%s|%s|%s|%s\n' "$id" "${fix_status[$id]}" "${fix_missing_file[$id]:-}" "${fix_absent_files[$id]:-}" "${fix_files[$id]:-}"
        printf '%s' "${fix_rows[$id]}" | sed 's/^/R /'
        printf '%s' "${fix_view[$id]}" | sed 's/^/V /'
    done
}
"#;

fn shell_speakers(s: &Option<Speakers>) -> String {
    match s {
        None => "OUTPUT_MODE= STEREO_MODE= ENABLE_HRTF= SURROUND_CHANNELS=".into(),
        Some(s) => format!(
            "OUTPUT_MODE={} STEREO_MODE={} ENABLE_HRTF={} SURROUND_CHANNELS={}",
            match s.output {
                eax_restore::engine::speakers::Output::Stereo => "stereo",
                eax_restore::engine::speakers::Output::Surround => "surround",
                eax_restore::engine::speakers::Output::Matrix => "matrix",
            },
            s.listening.name(),
            if s.hrtf { "y" } else { "n" },
            if s.output == eax_restore::engine::speakers::Output::Surround {
                s.layout.name()
            } else {
                ""
            }
        ),
    }
}

struct World {
    game_dir: PathBuf,
    root: PathBuf,
    prefix: PathBuf,
}

/// One case: a game, the world it is installed in, and how it's surveyed.
struct Case<'a> {
    game: &'a Game,
    store: Store,
    id: String,
    world: &'a World,
    speakers: Option<Speakers>,
    purpose: Purpose,
    recorded: Vec<String>,
    untested: bool,
}

fn survey_both(cases: &[Case], db_file: &Path, dir: &Path) {
    let mut script = String::from(SURVEY);
    for c in cases {
        let recorded: String = c
            .recorded
            .iter()
            .map(|t| format!("GAME_SETTINGS_RECORDED[{}]=x; ", shell_quote(t)))
            .collect();
        script.push_str(&format!(
            "(KG_ID={} KG_STORE={} GAME_DIR={} GAME_INSTALL_ROOT={} PREFIX_PATH={} {}\n\
             GAME_SETTINGS_SPEAKERS_ONLY={} GAME_SETTINGS_EDIT={} EAX_RESTORE_UNTESTED_SETTINGS={}\n\
             declare -A GAME_SETTINGS_RECORDED=(); {recorded}\n\
             survey); echo '--end--'\n",
            c.id,
            c.store.key(),
            shell_quote(&c.world.game_dir.display().to_string()),
            shell_quote(&c.world.root.display().to_string()),
            shell_quote(&c.world.prefix.display().to_string()),
            shell_speakers(&c.speakers),
            if c.purpose == Purpose::SpeakersOnly { "1" } else { "" },
            if c.purpose == Purpose::Edit { "1" } else { "" },
            if c.untested { "1" } else { "" },
        ));
    }
    let out = bash(
        &script,
        dir,
        &[("ORACLE_DB", db_file.display().to_string())],
    );
    let mut blocks = out.split("--end--\n");
    for c in cases {
        let bash: Vec<&str> = blocks.next().unwrap().lines().collect();
        let places = Places {
            game_dir: &c.world.game_dir,
            install_root: &c.world.root,
            prefix: Some(&c.world.prefix),
            user: "player",
        };
        let survey = Survey {
            store: c.store,
            places,
            speakers: c.speakers,
            purpose: c.purpose,
            recorded: c.recorded.iter().cloned().collect(),
            include_untested: c.untested,
        };
        let rust: Vec<String> = game_settings::survey(c.game, &survey)
            .iter()
            .flat_map(rust_fix)
            .collect();
        assert_eq!(
            bash,
            rust,
            "{} ({:?}, {:?}, untested {})",
            c.game.name,
            c.purpose,
            c.speakers.map(|s| s.label()),
            c.untested
        );
    }
}

fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

fn touch(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// Every game in the database, installed with each of its config files
/// present (empty) at its first location, surveyed for an install.
#[test]
fn surveying_every_game_matches() {
    let tmp = tempfile::tempdir().unwrap();
    let db = database();
    let mut worlds = Vec::new();
    let mut picked = Vec::new();
    for (i, game) in db.games.iter().enumerate() {
        let Some((store, id)) = lookup(&db, game) else {
            continue;
        };
        if game.game_config.files.is_empty() {
            continue;
        }
        let root = tmp.path().join(format!("g{i}"));
        let world = World {
            game_dir: root.join("bin"),
            root: root.clone(),
            prefix: tmp.path().join(format!("p{i}")),
        };
        std::fs::create_dir_all(&world.game_dir).unwrap();
        // Every second game gets its files; the rest have none, so their
        // settings come out missing, created or left out.
        if i % 2 == 0 {
            for def in game.game_config.files.values() {
                let Some(loc) = def.locations.first() else {
                    continue;
                };
                let (base, rel) = loc.split_once(':').unwrap();
                let dir = match base {
                    "game_exe" | "game" => world.game_dir.clone(),
                    "game_root" | "install" => world.root.clone(),
                    "prefix_documents" => world.prefix.join("drive_c/users/steamuser/Documents"),
                    "prefix_appdata" => {
                        world.prefix.join("drive_c/users/steamuser/AppData/Roaming")
                    }
                    "prefix_localappdata" => {
                        world.prefix.join("drive_c/users/player/AppData/Local")
                    }
                    "prefix_public_documents" => {
                        world.prefix.join("drive_c/users/Public/Documents")
                    }
                    _ => world.prefix.clone(),
                };
                touch(&dir.join(rel), "");
            }
        }
        worlds.push(world);
        picked.push((game, store, id));
    }
    assert!(picked.len() > 30);
    let speakers = [
        Some(Speakers::stereo(Listening::Headphones, true)),
        Some(Speakers::surround(Layout::Surround51)),
    ];
    let mut cases = Vec::new();
    for ((game, store, id), world) in picked.iter().zip(&worlds) {
        for (k, sp) in speakers.iter().enumerate() {
            cases.push(Case {
                game,
                store: *store,
                id: id.clone(),
                world,
                speakers: *sp,
                purpose: if k == 0 {
                    Purpose::Install
                } else {
                    Purpose::SpeakersOnly
                },
                recorded: Vec::new(),
                untested: k == 0,
            });
        }
    }
    survey_both(&cases, &repo_root().join("game-database.json"), tmp.path());
}

const TEST_DB: &str = r#"{"games":[{"id":"t","name":"Test Game","exe":"game.exe",
 "stores":{"steam":{"id":4242},"gog":{"id":77}},
 "game_config":{
  "files":{
    "a.ini":{"format":"ini","locations":["game_exe:a.ini"],"crash_marker":"running.lock"},
    "new.cfg":{"format":"key_value","locations":["game_exe:cfg/new.cfg"],"if_missing":"create"},
    "dlc.ini":{"format":"ini","locations":["game_exe:dlc.ini"],"if_missing":"skip"},
    "late.cfg":{"format":"set_commands","locations":["game_exe:late.cfg"]},
    "both.ini":{"format":"ini","locations":["prefix_documents:G/both.ini"],"all_locations":true},
    "user.reg":{"format":"registry","locations":["prefix:user.reg"]},
    "p.gdb":{"format":"binary_switches","locations":["game_exe:p.gdb"]},
    "bad.ini":{"format":"ini","locations":["game_exe:../bad.ini"]}
  },
  "audio_settings":[
    {"title":"Enable EAX","reason":"r","tested":true,"changes":{"a.ini":{"Audio":{"UseEAX":"1","Rate":"44100","Gone":null}},"new.cfg":{"eax":true}}},
    {"title":"Enable Steam sound","reason":"r","tested":true,"only_if":{"stores":["steam"]},"changes":{"a.ini":{"Audio":{"Steam":"1"}}}},
    {"title":"Set surround","reason":"r","tested":true,"only_if":{"speakers":["surround"]},"changes":{"a.ini":{"Audio":{"Channels":"6"}}}},
    {"title":"Set headphones","reason":"r","tested":true,"only_if":{"speakers":"headphones"},"changes":{"a.ini":{"Audio":{"Channels":"2"}}}},
    {"title":"Set stereo","reason":"r","tested":true,"only_if":{"speakers":["stereo"]},"changes":{"a.ini":{"Audio":{"Channels":"2s"}}}},
    {"title":"Fix the DLC","reason":"r","tested":true,"changes":{"dlc.ini":{"S":{"k":"1"}}}},
    {"title":"Fix late","reason":"r","tested":true,"changes":{"late.cfg":{"s_eax":"1"},"a.ini":{"Audio":{"Late":"1"}}}},
    {"title":"Fix both","reason":"r","tested":true,"changes":{"both.ini":{"S":{"k":"2"}}}},
    {"title":"Set the registry","reason":"r","tested":true,"changes":{"user.reg":{"Software\\Test":{"EAX":"1","Name":"Creative"}}}},
    {"title":"Switch on","reason":"r","tested":true,"changes":{"p.gdb":{"UseEAX":"1","Missing":"1"}}},
    {"title":"Bad entry","reason":"r","tested":true,"changes":{"bad.ini":{"S":{"k":"1"}}}},
    {"title":"Untested one","reason":"r","changes":{"a.ini":{"Audio":{"Maybe":"1"}}}}
  ],
  "optional_settings":[
    {"title":"Already done","reason":"r","tested":true,"changes":{"a.ini":{"Video":{"Fps":"60"}}}},
    {"title":"Turn off flag","reason":"r","tested":true,"changes":{"new.cfg":{"flag":false,"gone":null}}},
    {"title":"Only the DLC","reason":"r","tested":true,"changes":{"dlc.ini":{"S":{"k":"2"}}}}
  ]}}]}"#;

/// GADB bytes with on/off records for `names`, all off.
fn gadb(names: &[&str]) -> Vec<u8> {
    let mut table = Vec::new();
    let mut offsets = Vec::new();
    for n in names {
        offsets.push(table.len() as u32);
        table.extend_from_slice(n.as_bytes());
        table.push(0);
    }
    let mut out = b"GADB\0\0\0\0".to_vec();
    out.extend_from_slice(&(table.len() as u32).to_le_bytes());
    out.extend_from_slice(&[0; 16]);
    out.extend_from_slice(&table);
    while !out.len().is_multiple_of(4) {
        out.push(0);
    }
    for o in offsets {
        for n in [o, 1, 0, 1, 0] {
            out.extend_from_slice(&n.to_le_bytes());
        }
    }
    out
}

fn test_world(root: &Path) -> World {
    let w = World {
        game_dir: root.join("Game"),
        root: root.join("Game"),
        prefix: root.join("pfx"),
    };
    touch(
        &w.game_dir.join("a.ini"),
        "[Audio]\r\nUseEAX=0\r\nRate=22050\r\nGone=x\r\n\r\n[Video]\r\nFps=60\r\n",
    );
    touch(&w.game_dir.join("running.lock"), "");
    std::fs::create_dir_all(w.game_dir.join("cfg")).unwrap();
    touch(
        &w.prefix
            .join("drive_c/users/steamuser/Documents/G/both.ini"),
        "[S]\nk=1\n",
    );
    touch(
        &w.prefix.join("drive_c/users/player/Documents/G/both.ini"),
        "[S]\nk=2\n",
    );
    touch(
        &w.prefix.join("user.reg"),
        "WINE REGISTRY Version 2\n\n[Software\\\\Test] 1\n\"EAX\"=dword:00000000\n",
    );
    std::fs::write(w.game_dir.join("p.gdb"), gadb(&["UseEAX"])).unwrap();
    w
}

#[test]
fn surveying_a_test_game_matches() {
    let tmp = tempfile::tempdir().unwrap();
    let db_file = tmp.path().join("db.json");
    std::fs::write(&db_file, TEST_DB).unwrap();
    let db = Database::parse(TEST_DB).unwrap();
    let world = test_world(&tmp.path().join("w"));
    let mut cases = Vec::new();
    let setups = [
        None,
        Some(Speakers::stereo(Listening::Headphones, true)),
        Some(Speakers::stereo(Listening::Auto, false)),
        Some(Speakers::surround(Layout::Quad)),
        Some(Speakers::matrix()),
    ];
    for (store, id) in [(Store::Steam, "4242"), (Store::Gog, "77")] {
        for sp in setups {
            for purpose in [Purpose::Install, Purpose::SpeakersOnly, Purpose::Edit] {
                for untested in [false, true] {
                    cases.push(Case {
                        game: &db.games[0],
                        store,
                        id: id.into(),
                        world: &world,
                        speakers: sp,
                        purpose,
                        recorded: vec!["Already done".into(), "Enable EAX".into()],
                        untested,
                    });
                }
            }
        }
    }
    survey_both(&cases, &db_file, tmp.path());
}

/// A host that never sees the game running and always finds Wine quiet.
struct Quiet;

impl Host for Quiet {
    fn game_running(&mut self) -> bool {
        false
    }
    fn registry_quiet(&mut self) -> bool {
        true
    }
}

/// The file tree under `root`, paths relative to it, contents as text.
fn snapshot(root: &Path) -> Vec<(String, String)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
        let mut entries: Vec<_> = std::fs::read_dir(dir).unwrap().flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let p = e.path();
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                let rel = p.strip_prefix(root).unwrap().display().to_string();
                let text = String::from_utf8_lossy(&std::fs::read(&p).unwrap())
                    .replace(&root.display().to_string(), "<root>");
                out.push((rel, text));
            }
        }
    }
    let mut out = Vec::new();
    walk(root, root, &mut out);
    out
}

fn bash_plan_row(r: &game_settings::PlanRow, from: &Path, to: &Path) -> String {
    let path = to.join(r.path.strip_prefix(from).unwrap());
    [
        r.category.name().to_string(),
        r.title.clone(),
        path.display().to_string(),
        r.format.name().to_string(),
        r.section.clone(),
        r.key.clone(),
        String::from_utf8_lossy(r.new.as_bytes()).into_owned(),
        r.file.clone(),
        String::from_utf8_lossy(r.old.as_bytes()).into_owned(),
        if r.create { "create" } else { "found" }.to_string(),
    ]
    .join("\x1f")
}

/// The manifest an earlier run left: the files it deployed, and records for
/// keys it changed (one still in effect, one the player changed back, one
/// from a newer build, one for a key this run changes again).
fn previous_manifest(w: &World) -> String {
    let g = w.game_dir.display();
    format!(
        "# EAX Restore manifest, format 2\n{g}/dsound.dll\nVCRUN\n\
         CONFIG:audio\tEnable EAX\t{g}/a.ini\tini\tAudio\tUseEAX\toriginal\t1\n\
         CONFIG:optional\tAlready done\t{g}/a.ini\tini\tVideo\tFps\t30\t60\n\
         CONFIG:optional\tChanged back\t{g}/a.ini\tini\tVideo\tVsync\t0\t1\n\
         CONFIG:audio\tFrom a newer build\t{g}/x.toml\ttoml\ts\tk\t0\t1\n\
         CONFIG:audio\tOld spelling\t{g}/new.cfg\tdark_cfg\t\tother\t__ABSENT__\t__TRUE__\n"
    )
}

#[test]
fn applying_and_updating_match() {
    let tmp = tempfile::tempdir().unwrap();
    let db_file = tmp.path().join("db.json");
    std::fs::write(&db_file, TEST_DB).unwrap();
    let db = Database::parse(TEST_DB).unwrap();
    let (b, r) = (tmp.path().join("bash"), tmp.path().join("rust"));
    let wb = test_world(&b);
    let wr = test_world(&r);
    for w in [&wb, &wr] {
        touch(&w.game_dir.join("dsound.dll"), "DSOAL");
        std::fs::write(
            w.game_dir.join(".eax-restore-manifest.txt"),
            previous_manifest(w),
        )
        .unwrap();
    }
    // The survey on the Rust side gives the plan both sides apply.
    let survey = Survey {
        store: Store::Steam,
        places: Places {
            game_dir: &wr.game_dir,
            install_root: &wr.root,
            prefix: Some(&wr.prefix),
            user: "player",
        },
        speakers: Some(Speakers::surround(Layout::Surround51)),
        purpose: Purpose::Edit,
        recorded: HashSet::new(),
        include_untested: false,
    };
    let fixes = game_settings::survey(&db.games[0], &survey);
    let plan: Vec<_> = fixes
        .iter()
        .filter(|f| f.status == Status::Offer)
        .flat_map(|f| f.plan.clone())
        .collect();
    assert!(plan.len() >= 6, "{plan:#?}");
    // Turn off two recorded settings: one still in effect, one not.
    let manifest_r = wr.game_dir.join(".eax-restore-manifest.txt");
    let groups: Vec<RevertGroup> = apply::recorded_settings(&std::fs::read(&manifest_r).unwrap())
        .into_iter()
        .filter(|g| g.title == "Already done" || g.title == "Changed back")
        .collect();
    assert_eq!(groups.len(), 2);

    let plan_lines: Vec<String> = plan.iter().map(|p| bash_plan_row(p, &r, &b)).collect();
    let group_lines: Vec<String> = groups
        .iter()
        .map(|g| {
            let lines: Vec<String> = g
                .lines
                .iter()
                .map(|l| {
                    String::from_utf8_lossy(l)
                        .replace(&r.display().to_string(), &b.display().to_string())
                })
                .collect();
            format!("{}\x1f{}\x1f{}\n", g.category, g.title, lines.join("\n"))
        })
        .collect();
    std::fs::write(tmp.path().join("plan"), plan_lines.join("\n") + "\n").unwrap();
    std::fs::write(tmp.path().join("groups"), group_lines.join("\x00")).unwrap();
    bash(
        r#"
        game_exe_running() { return 1; }
        wine_registry_quiet() { return 0; }
        GAME_NAME="Test Game"; KG_ID=4242; KG_STORE=steam
        INSTALL_MANIFEST="$GAME/.eax-restore-manifest.txt"
        mapfile -t GAME_SETTINGS_PLAN < "$1/plan"
        mapfile -t -d '' GAME_SETTINGS_REVERT_GROUPS < "$1/groups"
        update_game_settings_in_manifest > /dev/null
        "#,
        tmp.path(),
        &[
            ("ORACLE_DB", db_file.display().to_string()),
            ("GAME", wb.game_dir.display().to_string()),
        ],
    );
    let markers: HashMap<String, String> = db.games[0]
        .game_config
        .files
        .iter()
        .filter(|(_, d)| !d.crash_marker.is_empty())
        .map(|(n, d)| (n.clone(), d.crash_marker.clone()))
        .collect();
    let report =
        apply::update_in_manifest(&manifest_r, &groups, &plan, &markers, &mut Quiet).unwrap();
    assert!(report.applied.failed.is_empty(), "{report:#?}");
    assert_eq!(snapshot(&b), snapshot(&r));
    assert!(
        report.applied.crash_markers_removed.len() == 1,
        "{report:#?}"
    );
    assert_eq!(report.restored, vec!["Already done".to_string()]);
    let _ = Category::Audio;
}
