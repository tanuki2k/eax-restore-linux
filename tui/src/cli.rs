//! The headless commands: install, uninstall and change a game's settings
//! from the command line with the Rust engine, without the TUI or the Bash
//! script. Every choice has the script's default, a flag changes it, and
//! nothing is changed until the player agrees (or passes `--yes`).

use crate::db::{Database, Game};
use crate::engine::apply::{self, RevertGroup};
use crate::engine::builds::{self, Build, Cache, Curl, Got, Pins};
use crate::engine::config::{self, Format};
use crate::engine::detect;
use crate::engine::eax_unified::Installer;
use crate::engine::game_settings::{self, Category, Fix, Purpose, Status, Survey};
use crate::engine::host::SystemHost;
use crate::engine::identify::Store;
use crate::engine::install::{self, Engine, Override, Vcrun};
use crate::engine::installed::Installed;
use crate::engine::launcher::changes::{self, LogLevel};
use crate::engine::launcher::control::{self, Control};
use crate::engine::launcher::target::{Launcher, Target};
use crate::engine::prepare::{self, Facts};
use crate::engine::speakers::{Layout, Listening, Speakers};
use crate::engine::uninstall::{self, Choices, Location, Surveyed};
use crate::engine::wine::{self, Prefix};
use crate::{fetch, library};
use anyhow::{bail, Context, Result};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

pub const COMMANDS: [&str; 6] = [
    "status",
    "install",
    "uninstall",
    "speakers",
    "settings",
    "sound-log",
];

const HELP: &str = "\
Usage: eax-restore <command> GAME_FOLDER [options]

Commands:
  status      Show what's found about the game and what's installed
  install     Install the EAX fix
  uninstall   Remove the EAX fix and put back what it changed
  speakers    Change the speaker setup:  speakers GAME_FOLDER SETUP
              (stereo, speakers, headphones, matrix, quad, 5.1, 6.1, 7.1)
  settings    Turn the game's own settings on or off:
              settings GAME_FOLDER --on TITLE --off TITLE
              (with neither, lists them)
  sound-log   Turn the sound log on or off:  sound-log GAME_FOLDER full|basic|off

Options for every command:
  --yes                Don't ask before making the changes
  --close-launcher     Close Steam or Heroic when they're running, and reopen them after
  --database FILE      Use this game database instead of downloading it
  --untested           Include settings nobody has checked on a real install yet

Install options (the defaults are the script's):
  --engine dsoal|openal-soft   --arch 32|64
  --builds stable|latest       --dsoal-build stable|latest   --openal-build stable|latest
  --speakers SETUP             --hrtf on|off
  --override launcher|registry|manual
  --vcrun install|skip         --com   --advanced-limits
  --setting TITLE              (an optional setting to turn on; repeat for more)
  --no-audio-settings          --no-alsoft-values
  --allow-unverified           (install a build GitHub publishes no checksum for)

Uninstall options:
  --keep-settings   --keep-launcher   --remove-vcrun
";

/// Options that take a value, and switches.
const VALUED: [&str; 13] = [
    "--database",
    "--engine",
    "--arch",
    "--builds",
    "--dsoal-build",
    "--openal-build",
    "--speakers",
    "--hrtf",
    "--override",
    "--vcrun",
    "--setting",
    "--on",
    "--off",
];
const SWITCHES: [&str; 12] = [
    "--yes",
    "--close-launcher",
    "--untested",
    "--com",
    "--advanced-limits",
    "--no-audio-settings",
    "--no-alsoft-values",
    "--allow-unverified",
    "--keep-settings",
    "--keep-launcher",
    "--remove-vcrun",
    "--help",
];

struct Args {
    positional: Vec<String>,
    values: HashMap<String, Vec<String>>,
    switches: HashSet<String>,
}

impl Args {
    fn parse(raw: &[String]) -> Result<Self> {
        let mut a = Args {
            positional: Vec::new(),
            values: HashMap::new(),
            switches: HashSet::new(),
        };
        let mut it = raw.iter();
        while let Some(x) = it.next() {
            if VALUED.contains(&x.as_str()) {
                let v = it.next().with_context(|| format!("{x} needs a value."))?;
                a.values.entry(x.clone()).or_default().push(v.clone());
            } else if SWITCHES.contains(&x.as_str()) {
                a.switches.insert(x.clone());
            } else if x.starts_with("--") {
                bail!("There's no option called {x}. Run eax-restore --help to see them.");
            } else {
                a.positional.push(x.clone());
            }
        }
        Ok(a)
    }
    fn get(&self, k: &str) -> Option<&str> {
        self.values
            .get(k)
            .and_then(|v| v.last())
            .map(String::as_str)
    }
    fn all(&self, k: &str) -> Vec<String> {
        self.values.get(k).cloned().unwrap_or_default()
    }
    fn on(&self, k: &str) -> bool {
        self.switches.contains(k)
    }
}

fn say(s: impl AsRef<str>) {
    println!("{}", s.as_ref());
}

fn home() -> Result<PathBuf> {
    Ok(PathBuf::from(
        std::env::var_os("HOME").context("HOME is not set.")?,
    ))
}

fn tilde(p: &Path, home: &Path) -> String {
    match p.strip_prefix(home) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

/// How to run protontricks: the program on PATH, or the Flatpak.
fn protontricks() -> Vec<String> {
    let on_path = std::env::var_os("PATH").is_some_and(|p| {
        std::env::split_paths(&p).any(|d| wine::is_executable(&d.join("protontricks")))
    });
    if on_path {
        vec!["protontricks".into()]
    } else {
        ["flatpak", "run", "com.github.Matoking.protontricks"]
            .map(String::from)
            .to_vec()
    }
}

fn load_database(args: &Args) -> Result<Database> {
    let path = match args
        .get("--database")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("EAX_RESTORE_GAME_DATABASE_FILE").map(PathBuf::from))
    {
        Some(p) => p,
        None => fetch::ensure_database()?,
    };
    Database::load(&path)
}

fn find_game<'a>(db: &'a Database, store: Option<Store>, id: &str) -> Option<&'a Game> {
    let id: u64 = id.parse().ok()?;
    db.games.iter().find(|g| match store {
        Some(Store::Steam) => g.stores.steam.as_ref().is_some_and(|s| s.id == id),
        Some(Store::Gog) => g.stores.gog.as_ref().is_some_and(|s| s.id == id),
        None => false,
    })
}

/// The game folder as given, or the exe folder found under it when it holds
/// no .exe itself (an install root).
fn exe_folder(dir: &Path, exe_hint: &str, home: &Path) -> Result<PathBuf> {
    let has_exe = std::fs::read_dir(dir)?.flatten().any(|e| {
        e.file_name()
            .to_string_lossy()
            .to_lowercase()
            .ends_with(".exe")
    });
    if has_exe {
        return Ok(dir.to_path_buf());
    }
    match detect::exe_candidates(dir, exe_hint).into_iter().next() {
        Some((d, exe)) => {
            say(format!(
                "Using {}, the folder {exe} is in.",
                tilde(&d, home)
            ));
            Ok(d)
        }
        None => Ok(dir.to_path_buf()),
    }
}

/// The facts, looked at twice: once to find the game, then with its profile.
fn facts_for(dir: &Path, db: &Database, home: &Path) -> (Facts, Option<Game>) {
    let pt = protontricks();
    let first = prepare::gather(dir, None, home, &pt);
    match find_game(db, first.store, &first.id).cloned() {
        Some(g) => (prepare::gather(dir, Some(&g), home, &pt), Some(g)),
        None => (first, None),
    }
}

fn game_name(facts: &Facts, game: Option<&Game>) -> String {
    game.map(|g| g.name.clone())
        .or_else(|| {
            facts
                .identified
                .as_ref()
                .map(|i| i.name.clone())
                .filter(|n| !n.is_empty())
        })
        .or_else(|| {
            facts
                .heroic
                .as_ref()
                .map(|h| h.title.clone())
                .filter(|t| !t.is_empty())
        })
        // The install's own folder, not the exe folder ("System", "bin").
        .unwrap_or_else(|| {
            facts
                .install_root
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default()
        })
}

fn confirm(question: &str, args: &Args) -> Result<bool> {
    if args.on("--yes") {
        return Ok(true);
    }
    if !std::io::stdin().is_terminal() {
        bail!("There's no terminal to ask you on, so nothing was changed. Add --yes to make these changes without being asked.");
    }
    print!("\n{question} (Y/n) ");
    std::io::stdout().flush()?;
    let mut line = String::new();
    std::io::stdin().lock().read_line(&mut line)?;
    Ok(matches!(
        line.trim().to_lowercase().as_str(),
        "" | "y" | "yes"
    ))
}

/// Closes a running launcher before its settings file is changed, when
/// `--close-launcher` allows it, and remembers how to start it again.
struct Launchers {
    close: bool,
    home: PathBuf,
    /// The game's name, for saying whose settings were left alone.
    game: String,
    reopen: Vec<(String, Vec<String>)>,
}

impl Launchers {
    fn closed(&mut self, t: &Target) -> bool {
        let c = Control::for_target(t, &self.home);
        if !c.running() {
            return true;
        }
        let label = t.launcher.label();
        if c.game_running() {
            say(format!("A game is running from {label}, so {label} can't be closed and its settings were left alone."));
            return false;
        }
        if !self.close {
            let what = match t.launcher {
                Launcher::Steam => "launch options",
                Launcher::Heroic => "environment variables",
            };
            say(format!(
                "{label} is running, so {}'s {what} were left alone. Close {label}, or add --close-launcher to have it closed and reopened for you.",
                self.game
            ));
            return false;
        }
        let Some(cmd) = c.launch_command() else {
            say(format!("{label} is running, and eax-restore doesn't know how to start it again afterwards, so its settings were left alone."));
            return false;
        };
        if c.close_and_wait(Duration::from_secs(30)) {
            say(format!("Closed {label}."));
            if !self.reopen.iter().any(|(l, _)| l == label) {
                self.reopen.push((label.to_string(), cmd));
            }
            true
        } else {
            say(format!(
                "{label} didn't close in time, so its settings were left alone."
            ));
            false
        }
    }

    fn reopen(&mut self) {
        for (label, cmd) in std::mem::take(&mut self.reopen) {
            if control::reopen(&cmd) {
                say(format!("Reopened {label}."));
            } else {
                say(format!(
                    "Couldn't reopen {label}, so you'll need to start it yourself."
                ));
            }
        }
    }
}

fn eax_installer() -> Installer {
    Installer::for_branch(if fetch::CHANNEL == "dev" {
        "dev"
    } else {
        "main"
    })
}

fn speakers_from(name: &str, hrtf: bool) -> Result<Speakers> {
    Ok(match name {
        "stereo" | "auto" => Speakers::stereo(Listening::Auto, hrtf),
        "speakers" => Speakers::stereo(Listening::Speakers, false),
        "headphones" => Speakers::stereo(Listening::Headphones, hrtf),
        "matrix" => Speakers::matrix(),
        "quad" | "4.0" => Speakers::surround(Layout::Quad),
        "5.1" | "surround51" => Speakers::surround(Layout::Surround51),
        "6.1" | "surround61" => Speakers::surround(Layout::Surround61),
        "7.1" | "surround71" => Speakers::surround(Layout::Surround71),
        other => bail!("\"{other}\" isn't a speaker setup — use stereo, speakers, headphones, matrix, quad, 5.1, 6.1 or 7.1."),
    })
}

/// Why a build couldn't be had.
fn why_text(what: &str, why: &builds::Why) -> String {
    match why {
        builds::Why::Offline => format!("{what} couldn't be downloaded because there's no internet connection, so nothing was installed."),
        builds::Why::Download => format!("{what} couldn't be downloaded, so nothing was installed."),
        builds::Why::Checksum(_) => format!("The {what} download didn't match its published checksum, so nothing was installed."),
        builds::Why::Unpack => format!("The {what} download couldn't be unpacked, so nothing was installed."),
        builds::Why::NotPublished => format!("GitHub has no download of {what} right now, so nothing was installed."),
    }
}

/// "Steam" or "Heroic", for a game whose launcher has no settings yet.
fn launcher_label(facts: &Facts) -> &'static str {
    if facts.store == Some(Store::Steam)
        || facts
            .game_dir
            .to_string_lossy()
            .contains("/steamapps/common/")
    {
        "Steam"
    } else {
        "Heroic"
    }
}

/// Why a recorded setting wasn't put back, in a few words.
fn kept_text(why: config::Reverted) -> &'static str {
    match why {
        config::Reverted::ChangedSince => "it's been changed since the EAX fix set it",
        config::Reverted::Unreadable => "a newer version of eax-restore changed it",
        config::Reverted::RegistryBusy => "the game is running, so its registry can't be changed",
        config::Reverted::Failed => "the file couldn't be written",
        config::Reverted::Nothing | config::Reverted::Restored => "the file is gone",
    }
}

fn build_from(v: &str) -> Result<Build> {
    match v {
        "stable" => Ok(Build::Stable),
        "latest" => Ok(Build::Latest),
        other => bail!("\"{other}\" isn't a build — use stable or latest."),
    }
}

fn include_untested(args: &Args) -> bool {
    args.on("--untested")
        || std::env::var("EAX_RESTORE_UNTESTED_SETTINGS")
            .is_ok_and(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "y"))
}

fn crash_markers(game: Option<&Game>) -> HashMap<String, String> {
    game.map(|g| {
        g.game_config
            .files
            .iter()
            .filter(|(_, f)| !f.crash_marker.is_empty())
            .map(|(n, f)| (n.clone(), f.crash_marker.clone()))
            .collect()
    })
    .unwrap_or_default()
}

fn survey(
    facts: &Facts,
    game: &Game,
    speakers: Option<Speakers>,
    purpose: Purpose,
    recorded: HashSet<String>,
    args: &Args,
) -> Vec<Fix> {
    let survey = Survey {
        store: facts.store.unwrap_or(Store::Steam),
        places: config::paths::Places {
            game_dir: &facts.game_dir,
            install_root: &facts.install_root,
            prefix: facts.prefix.as_deref(),
            user: &std::env::var("USER").unwrap_or_default(),
        },
        speakers,
        purpose,
        recorded,
        include_untested: include_untested(args),
    };
    game_settings::survey(game, &survey)
}

/// A setting's state in a few words, with the game's own names.
fn status_word(f: &Fix, name: &str) -> String {
    match f.status {
        Status::Offer => "off".into(),
        Status::Already => "already on".into(),
        Status::Applied => "on".into(),
        Status::Missing => format!(
            "{name} hasn't created {} yet",
            f.missing_file.clone().unwrap_or_default()
        ),
        Status::Absent => format!(
            "{name} has no {} in this folder",
            f.absent_files.join(" or ")
        ),
        Status::Skip | Status::Invalid => String::new(),
    }
}

fn host<'a>(
    facts: &Facts,
    game: Option<&Game>,
    net: &'a mut Curl,
    close: &'a mut dyn FnMut(&Target) -> bool,
    home: &Path,
) -> SystemHost<'a> {
    SystemHost {
        prefix: Prefix {
            path: facts.prefix.clone().unwrap_or_default(),
            runner: facts.runner.clone(),
            log: None,
        },
        game_dir: facts.game_dir.clone(),
        game_exe: game.map(|g| g.exe.clone()).unwrap_or_default(),
        protontricks: protontricks(),
        net,
        cache: Cache::new(home).root,
        eax_unified: eax_installer(),
        close_launcher: close,
    }
}

/// Runs a headless command. `raw` is everything after the program's name.
pub fn run(raw: &[String]) -> Result<()> {
    let args = Args::parse(&raw[1..])?;
    if args.on("--help") {
        print!("{HELP}");
        return Ok(());
    }
    let cmd = raw[0].as_str();
    let Some(dir) = args.positional.first() else {
        bail!("Which game? Give its folder, like eax-restore {cmd} GAME_FOLDER.");
    };
    let home = home()?;
    let db = load_database(&args)?;
    let dir = std::fs::canonicalize(dir).with_context(|| format!("There's no folder at {dir}."))?;
    // The game is looked up first, so its profile's exe picks the exe
    // folder when the folder given is the install's top folder.
    let hint = {
        let first = prepare::gather(&dir, None, &home, &protontricks());
        find_game(&db, first.store, &first.id)
            .map(|g| g.exe.clone())
            .unwrap_or_default()
    };
    let dir = exe_folder(&dir, &hint, &home)?;
    let (facts, game) = facts_for(&dir, &db, &home);
    let mut launchers = Launchers {
        close: args.on("--close-launcher"),
        home: home.clone(),
        game: String::new(),
        reopen: Vec::new(),
    };
    launchers.game = game_name(&facts, game.as_ref());
    let result = match cmd {
        "status" => status(&facts, game.as_ref(), &args, &home),
        "install" => install(&facts, game.as_ref(), &args, &home, &mut launchers),
        "uninstall" => uninstall(&facts, game.as_ref(), &args, &home, &mut launchers),
        "speakers" => speakers(&facts, game.as_ref(), &args, &home),
        "settings" => settings(&facts, game.as_ref(), &args, &home),
        "sound-log" => sound_log(&facts, game.as_ref(), &args, &mut launchers),
        _ => unreachable!("only the commands in COMMANDS get here"),
    };
    launchers.reopen();
    result
}

fn status(facts: &Facts, game: Option<&Game>, args: &Args, home: &Path) -> Result<()> {
    let name = game_name(facts, game);
    say(&name);
    say(format!("  Folder:        {}", tilde(&facts.game_dir, home)));
    let store = match (facts.store, &facts.heroic) {
        (Some(Store::Steam), _) => format!("Steam (AppID {})", facts.id),
        (_, Some(_)) => "Heroic".to_string(),
        _ => "not found in Steam or Heroic".to_string(),
    };
    say(format!("  Launcher:      {store}"));
    say(format!(
        "  Prefix:        {}",
        facts
            .prefix
            .as_ref()
            .map_or("not found".to_string(), |p| tilde(p, home))
    ));
    say(format!(
        "  Architecture:  {}",
        facts
            .arch
            .map_or("can't tell from the .exe files".to_string(), |a| format!(
                "{a}-bit"
            ))
    ));
    say(format!(
        "  Audio:         {}{}",
        match facts.engine() {
            Engine::Dsoal => "DirectSound3D",
            Engine::OpenAlSoft => "OpenAL",
        },
        if facts.api_disagrees() {
            " (the game's files point to a different audio system than its profile lists)"
        } else {
            ""
        }
    ));
    say(format!(
        "  Profile:       {}",
        if game.is_some() {
            "in the game database"
        } else {
            "not in the game database"
        }
    ));
    for c in &facts.companions {
        let prefix = if c.prefix.is_some() {
            "has its own prefix"
        } else {
            "has no prefix yet"
        };
        say(format!("  Also:          {} ({prefix})", c.name));
    }
    if facts.linux_build {
        say(format!(
            "  {name} is the Linux version, which the EAX fix can't work with."
        ));
    }
    match Installed::read(&facts.game_dir, home) {
        None => say("  EAX fix:       not installed"),
        Some(i) => {
            say("  EAX fix:       installed");
            if let Some(s) = i.speakers() {
                say(format!("  Speakers:      {}", s.label()));
            }
        }
    }
    if let Some(g) = game {
        let recorded: HashSet<String> = Installed::read(&facts.game_dir, home)
            .map(|i| i.settings.iter().map(|s| s.title.clone()).collect())
            .unwrap_or_default();
        let fixes: Vec<Fix> = survey(facts, g, None, Purpose::Edit, recorded, args)
            .into_iter()
            .filter(Fix::shown)
            .collect();
        if !fixes.is_empty() {
            say("  Game settings:");
            for f in fixes {
                say(format!("    {} — {}", f.title, status_word(&f, &name)));
            }
        }
    }
    Ok(())
}

fn install(
    facts: &Facts,
    game: Option<&Game>,
    args: &Args,
    home: &Path,
    launchers: &mut Launchers,
) -> Result<()> {
    let name = game_name(facts, game);
    if facts.linux_build {
        bail!("{name} is the Linux version, which the EAX fix can't work with. Switch the game to its Windows version in its launcher first.");
    }
    if facts.prefix.is_none() {
        bail!("{name}'s Wine prefix wasn't found. If you just installed {name}, its launcher creates it the first time it runs: launch the game once, close it, and try again.");
    }
    let mut plan = facts.default_plan();
    if let Some(e) = args.get("--engine") {
        plan.engine = match e {
            "dsoal" => Engine::Dsoal,
            "openal-soft" => Engine::OpenAlSoft,
            other => bail!("\"{other}\" isn't an audio engine — use dsoal or openal-soft."),
        };
    }
    if let Some(a) = args.get("--arch") {
        plan.arch = match a {
            "32" => 32,
            "64" => 64,
            other => bail!("\"{other}\" isn't an architecture — use 32 or 64."),
        };
    }
    if let Some(b) = args.get("--builds") {
        plan.dsoal_build = build_from(b)?;
        plan.openal_build = build_from(b)?;
    }
    if let Some(b) = args.get("--dsoal-build") {
        plan.dsoal_build = build_from(b)?;
    }
    if let Some(b) = args.get("--openal-build") {
        plan.openal_build = build_from(b)?;
    }
    let hrtf = match args.get("--hrtf") {
        None | Some("on") => true,
        Some("off") => false,
        Some(other) => bail!("\"{other}\" isn't a choice for --hrtf — use on or off."),
    };
    plan.speakers = speakers_from(args.get("--speakers").unwrap_or("stereo"), hrtf)?;
    if let Some(o) = args.get("--override") {
        plan.over = match o {
            "launcher" => Override::Launcher(facts.launcher.clone().with_context(|| {
                format!("{} has no settings saved for {name} yet. If you just installed {name}, launch it once, close it, and try again.", launcher_label(facts))
            })?),
            "registry" => Override::Registry,
            "manual" => Override::Manual,
            other => bail!("\"{other}\" isn't a place for the DLL override — use launcher, registry or manual."),
        };
    }
    for c in plan.companions.iter_mut() {
        c.over = match &plan.over {
            Override::Launcher(_) => {
                Target::steam(home, None, &c.app_id).map_or(Override::Registry, Override::Launcher)
            }
            other => other.clone(),
        };
    }
    if let Some(v) = args.get("--vcrun") {
        plan.vcrun = match v {
            "install" if facts.vcrun_present => Vcrun::OverridesOnly,
            "install" => Vcrun::Install,
            "skip" => Vcrun::Skip,
            other => bail!("\"{other}\" isn't a choice for --vcrun — use install or skip."),
        };
    }
    plan.com_routing = args.on("--com");
    plan.advanced_limits = args.on("--advanced-limits");
    plan.crash_markers = crash_markers(game);

    // The game's own settings: every audio one, and the optional ones asked for.
    let wanted: Vec<String> = args.all("--setting");
    let mut waiting = Vec::new();
    if let Some(g) = game {
        let fixes = survey(
            facts,
            g,
            Some(plan.speakers),
            Purpose::Install,
            HashSet::new(),
            args,
        );
        for w in &wanted {
            if !fixes
                .iter()
                .any(|f| f.shown() && f.title.eq_ignore_ascii_case(w))
            {
                bail!("{name} has no setting called \"{w}\". Run eax-restore status to see them.");
            }
        }
        for f in fixes {
            let audio = f.category == Category::Audio && !args.on("--no-audio-settings");
            let asked = wanted.iter().any(|w| w.eq_ignore_ascii_case(&f.title));
            if (audio || asked) && f.status == Status::Offer {
                plan.game_settings.extend(f.plan);
            } else if (audio || asked) && f.status == Status::Missing {
                waiting.push((f.title, f.missing_file.unwrap_or_default()));
            }
        }
        // The profile's alsoft.ini values, when they're verified.
        let tested = g.install.alsoft_tested == Some(true) || include_untested(args);
        if tested && !args.on("--no-alsoft-values") {
            for (sec, keys) in g.install.alsoft_ini.iter().flatten() {
                for (key, value) in keys.as_object().into_iter().flatten() {
                    let v = match value {
                        serde_json::Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    if config::row_is_safe(Format::Ini, "game:alsoft.ini", sec, key, &v) {
                        plan.alsoft_overrides.push((sec.clone(), key.clone(), v));
                    }
                }
            }
        }
    }

    say(format!("Ready to install the EAX fix for {name}:"));
    say(format!("  Folder:        {}", tilde(&plan.game_dir, home)));
    for d in &plan.extra_dirs {
        say(format!("                 {}", tilde(d, home)));
    }
    say(format!(
        "  Prefix:        {}",
        tilde(&facts.prefix.clone().unwrap_or_default(), home)
    ));
    say(format!("  Architecture:  {}-bit", plan.arch));
    say(format!(
        "  Audio engine:  {}",
        match plan.engine {
            Engine::Dsoal => "DSOAL with OpenAL Soft",
            Engine::OpenAlSoft => "OpenAL Soft",
        }
    ));
    say(format!("  Speakers:      {}", plan.speakers.label()));
    say(format!(
        "  DLL override:  {}",
        match &plan.over {
            Override::Launcher(t) if t.launcher == Launcher::Steam =>
                format!("Steam's launch options for {name}"),
            Override::Launcher(_) => format!("Heroic's environment variables for {name}"),
            Override::Registry => "the prefix's registry".to_string(),
            Override::Manual => "you set it yourself".to_string(),
        }
    ));
    say(format!(
        "  VC++ runtime:  {}",
        match plan.vcrun {
            Vcrun::Install => "install it",
            Vcrun::OverridesOnly => "already there",
            Vcrun::Skip => "skip",
        }
    ));
    for c in &plan.companions {
        say(format!(
            "  Also:          {}, which runs from the same folder with a prefix of its own",
            c.name
        ));
    }
    if plan.eax_unified {
        say("  EAX Unified:   install it");
    }
    let mut titles: Vec<&str> = plan
        .game_settings
        .iter()
        .map(|r| r.title.as_str())
        .collect();
    titles.dedup();
    for t in titles {
        say(format!("  Turn on:       {t}"));
    }
    for (t, file) in &waiting {
        say(format!(
            "  Left out:      {t} ({name} hasn't created {file} yet)"
        ));
    }
    if !confirm("Install it?", args)? {
        say("Nothing was changed.");
        return Ok(());
    }

    // The builds, downloaded when missing or out of date.
    let cache = Cache::new(home);
    let mut net = Curl::default();
    let pins = Pins::default();
    let github = builds::Net::reachable(&mut net);
    let mut versions = builds::lookup(&cache, &mut net, github, &pins);
    let allow = args.on("--allow-unverified");
    let mut confirm_unverified = |label: &str| {
        if !allow {
            say(format!("GitHub publishes no checksum for {}, so it wasn't installed. Add --allow-unverified to install it anyway.", label.replace(" [", " (").replace(']', ")").replacen("kcat ", "kcat's ", 1)));
        }
        allow
    };
    if plan.engine == Engine::Dsoal {
        let got = builds::ensure_dsoal(
            &cache,
            &mut net,
            &mut versions,
            plan.dsoal_build,
            &pins,
            &mut confirm_unverified,
        );
        if let Got::Failed(why) = got {
            bail!("{}", why_text("DSOAL", &why));
        }
    }
    if let Got::Failed(why) = builds::ensure_openal(
        &cache,
        &mut net,
        &versions,
        plan.openal_build,
        &mut confirm_unverified,
    ) {
        bail!("{}", why_text("OpenAL Soft", &why));
    }

    let mut close = |t: &Target| launchers.closed(t);
    let mut h = host(facts, game, &mut net, &mut close, home);
    let r = install::execute(&plan, &cache, &eax_installer(), &mut h);
    if r.no_sources {
        bail!(
            "The downloaded builds don't have {}-bit files, so nothing was installed.",
            plan.arch
        );
    }
    for b in &r.backed_up {
        say(format!(
            "Backed up the original {} to {}",
            b.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .split(".bak.")
                .next()
                .unwrap_or(""),
            tilde(b, home)
        ));
    }
    say(format!("Copied {} files.", r.copied.len()));
    if let Some(s) = &r.settings {
        for t in &s.applied {
            say(format!("Turned on \"{t}\"."));
        }
    }
    match &r.over {
        Some(Override::Launcher(_)) | Some(Override::Registry) => {}
        _ => {
            let value = format!("{}=n,b", plan.engine.primary_dll());
            say("Set the DLL override yourself:");
            if facts.store == Some(Store::Steam) {
                say(format!(
                    "  Steam launch options: WINEDLLOVERRIDES=\"{value}\" %command%"
                ));
            } else {
                say(format!(
                    "  Heroic environment variable: WINEDLLOVERRIDES = {value}"
                ));
            }
        }
    }
    if !r.failures.is_empty() {
        for f in &r.failures {
            say(format!("Couldn't write {f}."));
        }
        bail!("The EAX fix isn't fully installed, so {name} may run without it.");
    }
    say(format!("The EAX fix is installed. Launch {name} and turn on EAX in its sound options if it has one."));
    Ok(())
}

fn uninstall(
    facts: &Facts,
    game: Option<&Game>,
    args: &Args,
    home: &Path,
    launchers: &mut Launchers,
) -> Result<()> {
    let name = game_name(facts, game);
    let state = library::installed_games_file(home);
    let installed: Vec<PathBuf> = library::live_manifest_dirs(home, &state)
        .into_iter()
        .collect();
    let at = Location {
        game_dir: &facts.game_dir,
        install_root: &facts.install_root,
        prefix: facts.prefix.as_deref(),
        extra_dirs: &facts.extra_dirs,
        installed_dirs: &installed,
        has_app_id: facts.store == Some(Store::Steam),
    };
    let s = match uninstall::survey(&at) {
        Surveyed::AlreadyUninstalled => {
            say(format!("The EAX fix was already removed from {name}."));
            return Ok(());
        }
        Surveyed::Nothing => {
            say(format!(
                "Nothing from the EAX fix was found in {name}'s folder or prefix."
            ));
            return Ok(());
        }
        Surveyed::Found(s) => s,
    };
    let choices = Choices {
        remove: s.files.iter().map(|f| f.path.clone()).collect(),
        keep_launcher: if args.on("--keep-launcher") {
            s.launcher_lines()
        } else {
            Vec::new()
        },
        registry_without_manifest: false,
        remove_vcrun: args.on("--remove-vcrun"),
        companion_vcrun: if args.on("--remove-vcrun") {
            s.recorded
                .companions
                .iter()
                .map(|c| c.app_id.clone())
                .collect()
        } else {
            Vec::new()
        },
        revert: if args.on("--keep-settings") {
            Vec::new()
        } else {
            s.settings.clone()
        },
    };
    say(format!("Ready to remove the EAX fix from {name}:"));
    for f in &s.files {
        let back = if f.backup.is_some() {
            " (the original is put back)"
        } else {
            ""
        };
        say(format!("  Remove:        {}{back}", tilde(&f.path, home)));
    }
    if !s.shared_with.is_empty() {
        say("  Kept:          the prefix's files and registry keys, since another game uses the prefix");
    }
    for l in s.launcher_lines() {
        if !choices.keep_launcher.contains(&l) {
            say("  Remove:        the DLL override from the launcher");
        }
    }
    if s.registry_work(&choices).is_some() {
        say("  Remove:        the registry changes");
    }
    for g in &choices.revert {
        say(format!("  Put back:      {}", g.title));
    }
    if choices.remove_vcrun && s.vcrun_present {
        say("  Remove:        the VC++ runtime");
    }
    if !s.has_work(&choices) {
        say("There's nothing to change.");
        return Ok(());
    }
    if !confirm("Remove it?", args)? {
        say("Nothing was changed.");
        return Ok(());
    }
    let mut net = Curl::default();
    let mut close = |t: &Target| launchers.closed(t);
    let mut h = host(facts, game, &mut net, &mut close, home);
    let when = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .unwrap_or_default();
    let r = uninstall::execute(&s, &choices, &mut h, &when);
    for p in &r.restored {
        say(format!(
            "Put back the original {}.",
            p.file_name().unwrap_or_default().to_string_lossy()
        ));
    }
    for t in &r.settings_restored {
        say(format!("Put back \"{t}\"."));
    }
    for (t, _key, why) in &r.settings_not_restored {
        say(format!("Kept \"{t}\" as it is, since {}.", kept_text(*why)));
    }
    for p in &r.not_removed {
        say(format!(
            "Couldn't remove {}, so it's still listed as part of the EAX fix.",
            tilde(p, home)
        ));
    }
    if r.fully_uninstalled {
        say(format!("The EAX fix is removed from {name}."));
    } else {
        say(format!("Some of the EAX fix is still in {name}, listed above. Uninstall again to try those once more."));
    }
    Ok(())
}

/// Puts back recorded settings and turns on new ones, as the Tools do.
fn change_settings(
    facts: &Facts,
    game: Option<&Game>,
    revert: &[RevertGroup],
    plan: &[game_settings::PlanRow],
    home: &Path,
) -> Result<apply::UpdateReport> {
    let mut net = Curl::default();
    let mut never = |_: &Target| true;
    let mut h = host(facts, game, &mut net, &mut never, home);
    apply::update_in_manifest(
        &crate::engine::manifest::path_in(&facts.game_dir),
        revert,
        plan,
        &crash_markers(game),
        &mut h,
    )
}

fn report_change(r: &apply::UpdateReport) {
    for t in &r.restored {
        say(format!("Put back \"{t}\"."));
    }
    for t in &r.applied.applied {
        say(format!("Turned on \"{t}\"."));
    }
    for f in &r.applied.failed {
        say(format!("Couldn't write {}.", f.display()));
    }
}

fn speakers(facts: &Facts, game: Option<&Game>, args: &Args, home: &Path) -> Result<()> {
    let name = game_name(facts, game);
    let Some(setup) = args.positional.get(1) else {
        bail!("Which speaker setup? eax-restore speakers GAME_FOLDER stereo|speakers|headphones|matrix|quad|5.1|6.1|7.1");
    };
    let hrtf = !matches!(args.get("--hrtf"), Some("off"));
    let new = speakers_from(setup, hrtf)?;
    let Some(inst) = Installed::read(&facts.game_dir, home).filter(|i| !i.alsoft_files.is_empty())
    else {
        bail!(
            "The EAX fix isn't installed in {}. Install it first.",
            tilde(&facts.game_dir, home)
        );
    };
    let old = inst.speakers();
    let (revert, plan) = match game {
        Some(g) => (
            inst.settings_for_other_speakers(g, &new, include_untested(args)),
            survey(
                facts,
                g,
                Some(new),
                Purpose::SpeakersOnly,
                HashSet::new(),
                args,
            )
            .into_iter()
            .filter(|f| f.status == Status::Offer)
            .flat_map(|f| f.plan)
            .collect::<Vec<_>>(),
        ),
        None => (Vec::new(), Vec::new()),
    };
    if old == Some(new) && revert.is_empty() && plan.is_empty() {
        say(format!("{name} is already set up for {}.", new.label()));
        return Ok(());
    }
    say(format!(
        "Ready to change {name}'s speakers: {} → {}",
        old.map_or("unknown".to_string(), |s| s.label()),
        new.label()
    ));
    for g in &revert {
        say(format!("  Put back:      {}", g.title));
    }
    let mut titles: Vec<&str> = plan.iter().map(|r| r.title.as_str()).collect();
    titles.dedup();
    for t in titles {
        say(format!("  Turn on:       {t}"));
    }
    if !confirm("Change them?", args)? {
        say("Nothing was changed.");
        return Ok(());
    }
    let mut ok = true;
    for f in &inst.alsoft_files {
        if new.write_alsoft(f).is_err() {
            say(format!("Couldn't write {}.", tilde(f, home)));
            ok = false;
        }
    }
    if !revert.is_empty() || !plan.is_empty() {
        report_change(&change_settings(facts, game, &revert, &plan, home)?);
    }
    if ok {
        say(format!("{name} is now set up for {}.", new.label()));
    }
    Ok(())
}

fn settings(facts: &Facts, game: Option<&Game>, args: &Args, home: &Path) -> Result<()> {
    let name = game_name(facts, game);
    let Some(g) = game else {
        bail!("{name} has no profile in the game database, so it has no game settings to change.");
    };
    let Some(inst) = Installed::read(&facts.game_dir, home) else {
        bail!(
            "The EAX fix isn't installed in {}. Install it first.",
            tilde(&facts.game_dir, home)
        );
    };
    let recorded: HashSet<String> = inst.settings.iter().map(|s| s.title.clone()).collect();
    let fixes: Vec<Fix> = survey(facts, g, inst.speakers(), Purpose::Edit, recorded, args)
        .into_iter()
        .filter(Fix::shown)
        .collect();
    let (on, off) = (args.all("--on"), args.all("--off"));
    if on.is_empty() && off.is_empty() {
        if fixes.is_empty() {
            say(format!("{name} has no game settings to change."));
        }
        for f in &fixes {
            say(format!("{} — {}", f.title, status_word(f, &name)));
        }
        return Ok(());
    }
    let find = |t: &str| fixes.iter().find(|f| f.title.eq_ignore_ascii_case(t));
    let mut plan = Vec::new();
    let mut revert = Vec::new();
    for t in &on {
        let f = find(t).with_context(|| format!("{name} has no setting called \"{t}\"."))?;
        match f.status {
            Status::Offer => plan.extend(f.plan.clone()),
            Status::Missing => say(format!(
                "{name} hasn't created {} yet, so \"{}\" was left out. If you just installed {name}, it creates it the first time it runs.",
                f.missing_file.clone().unwrap_or_default(),
                f.title
            )),
            _ => say(format!("\"{}\" is already on.", f.title)),
        }
    }
    for t in &off {
        let f = find(t).with_context(|| format!("{name} has no setting called \"{t}\"."))?;
        match inst.settings.iter().find(|g| g.title == f.title) {
            Some(group) => revert.push(group.clone()),
            None => say(format!(
                "\"{}\" wasn't turned on by the EAX fix, so there's nothing to put back.",
                f.title
            )),
        }
    }
    if plan.is_empty() && revert.is_empty() {
        return Ok(());
    }
    if !confirm(&format!("Change {name}'s settings?"), args)? {
        say("Nothing was changed.");
        return Ok(());
    }
    report_change(&change_settings(facts, game, &revert, &plan, home)?);
    Ok(())
}

fn sound_log(
    facts: &Facts,
    game: Option<&Game>,
    args: &Args,
    launchers: &mut Launchers,
) -> Result<()> {
    let name = game_name(facts, game);
    let level = match args.positional.get(1).map(String::as_str) {
        Some("full") | Some("on") => Some(LogLevel::Full),
        Some("basic") => Some(LogLevel::Basic),
        Some("off") => None,
        _ => bail!("Turn the sound log full, basic or off? eax-restore sound-log GAME_FOLDER full|basic|off"),
    };
    let Some(t) = facts.launcher.clone() else {
        bail!("{} has no settings saved for {name} yet. If you just installed {name}, launch it once, close it, and try again.", launcher_label(facts));
    };
    let state = changes::log_state(&t);
    if level.is_none() && !state.on() {
        say(format!("The sound log is already off for {name}."));
        return Ok(());
    }
    if !confirm(
        &format!(
            "Turn the sound log {} for {name}?",
            if level.is_some() { "on" } else { "off" }
        ),
        args,
    )? {
        say("Nothing was changed.");
        return Ok(());
    }
    if !launchers.closed(&t) {
        bail!("Nothing was changed.");
    }
    let game_dir = facts.game_dir.display().to_string();
    let has_dsoal = facts.game_dir.join("dsoal-aldrv.dll").exists();
    if !changes::set_sound_log(&t, &game_dir, has_dsoal, level) {
        bail!(
            "Couldn't save the change to {}'s settings for {name}.",
            t.launcher.label()
        );
    }
    if level.is_some() {
        say(format!(
            "The sound log is on. Start {name} and the log will be written to:"
        ));
        let (dsoal, alsoft) = changes::LogState::default().paths(&game_dir);
        if has_dsoal {
            say(format!("  {dsoal}"));
        }
        say(format!("  {alsoft}"));
    } else {
        say(format!("The sound log is off for {name}."));
    }
    Ok(())
}
