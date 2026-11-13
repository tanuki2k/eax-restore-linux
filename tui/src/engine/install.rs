//! Installing the audio fix: Phase 4 of `src/install-flow.sh`, run from a
//! finished [`Plan`] (every choice already made, by a panel or by the
//! detection stage), with no questions. Each step runs in the script's
//! order and the manifest comes out the same, so an uninstall by either
//! the script or the engine can take it back.
//!
//! A reinstall carries the last install's records over: its registry, VC++
//! and companion lines, its files that are still ours, its launcher line for
//! an override that's still set, and its game settings' original values.

use super::alsoft_template as tpl;
use super::apply::{self, Host};
use super::builds::{dsoal_source_dir, openal_source_dll, Build, Cache, Net};
use super::config::{self, Format, Value};
use super::deploy::{deploy_copy, handle_conflict, timestamp, Cleared};
use super::eax_unified::{self, Installer};
use super::files;
use super::game_settings::PlanRow;
use super::launcher::changes::{self, Written};
use super::launcher::options;
use super::launcher::target::{Held, Launcher, Target};
use super::manifest;
use super::prefix::{self, RegStatus};
use super::speakers::Speakers;
use super::vcrun;
use super::wine::Prefix;
use std::collections::{HashMap, HashSet};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Which DLLs the game gets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Engine {
    /// DSOAL's dsound.dll, with OpenAL Soft as dsoal-aldrv.dll beside it.
    Dsoal,
    /// OpenAL Soft alone, as OpenAL32.dll, for a game that uses OpenAL.
    OpenAlSoft,
}

impl Engine {
    /// The DLL Wine is told to load from the game folder.
    pub fn primary_dll(self) -> &'static str {
        match self {
            Engine::Dsoal => "dsound",
            Engine::OpenAlSoft => "openal32",
        }
    }
}

/// Where the DLL override goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Override {
    /// Steam's launch options or Heroic's environment variables.
    Launcher(Target),
    /// The prefix's registry.
    Registry,
    /// The player sets it by hand.
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Vcrun {
    Skip,
    Install,
    /// It's in the prefix already: only the DLL overrides are set.
    OverridesOnly,
}

/// A Steam companion app (DOOM 3's Resurrection of Evil): it runs the
/// game's exe from its folder but has its own prefix and launch options.
#[derive(Debug, Clone)]
pub struct Companion {
    pub app_id: String,
    pub name: String,
    pub prefix: Prefix,
    pub vcrun: Vcrun,
    pub over: Override,
}

/// Every choice an install needs.
#[derive(Debug, Clone)]
pub struct Plan {
    /// The folder with the game's exe; the manifest goes here.
    pub game_dir: PathBuf,
    /// Further exe folders from the profile, which get the same files.
    pub extra_dirs: Vec<PathBuf>,
    pub prefix: Option<Prefix>,
    /// 32 or 64.
    pub arch: u8,
    pub engine: Engine,
    pub dsoal_build: Build,
    pub openal_build: Build,
    pub speakers: Speakers,
    /// The profile's alsoft.ini values the player accepted: (section, key, value).
    pub alsoft_overrides: Vec<(String, String, String)>,
    /// More sources and a fixed frequency in alsoft.ini.
    pub advanced_limits: bool,
    /// DirectSound's COM objects routed to dsound.dll in the registry.
    pub com_routing: bool,
    pub over: Override,
    pub vcrun: Vcrun,
    pub eax_unified: bool,
    pub game_settings: Vec<PlanRow>,
    /// Crash markers by config file name, from the profile.
    pub crash_markers: HashMap<String, String>,
    pub companions: Vec<Companion>,
    /// EAX_RESTORE_DSOAL_LOG: turn the sound logs on at their fullest.
    pub sound_log: bool,
}

/// What an install needs from outside: the [`Host`] checks, closing a
/// launcher (asking the player), and the network.
pub trait InstallHost: Host {
    fn launcher_closed(&mut self, target: &Target) -> bool;
    fn net(&mut self) -> &mut dyn Net;
}

#[derive(Debug, Default)]
pub struct Report {
    /// The deploy steps that failed (files, registry, settings files).
    pub failures: Vec<String>,
    pub openal_runtime: Option<i32>,
    pub vcrun: Option<vcrun::InstallReport>,
    pub eax_unified: Option<eax_unified::Outcome>,
    pub backed_up: Vec<PathBuf>,
    pub copied: Vec<PathBuf>,
    pub registry: Option<RegStatus>,
    /// Where the override ended up: a launcher, the registry, or by hand.
    pub over: Option<Override>,
    pub launcher: Option<Written>,
    pub settings: Option<apply::Report>,
    /// Missing builds stopped the install before anything changed.
    pub no_sources: bool,
    /// The launcher couldn't be closed, so its overrides are left to the player.
    pub launcher_left_open: bool,
}

/// What to copy into the game and prefix: (source, name), the primary DLL
/// first.
fn sources(plan: &Plan, cache: &Cache) -> Option<Vec<(PathBuf, String)>> {
    let arch = if plan.arch == 64 { "Win64" } else { "Win32" };
    let list = match plan.engine {
        Engine::OpenAlSoft => vec![(
            openal_source_dll(cache, plan.openal_build, arch),
            "OpenAL32.dll".to_string(),
        )],
        Engine::Dsoal => {
            let dsound = dsoal_source_dir(cache, plan.dsoal_build, arch)
                .map(|d| d.join("dsound.dll"))
                .unwrap_or_else(|| PathBuf::from("/dsound.dll"));
            vec![
                (dsound, "dsound.dll".to_string()),
                (
                    openal_source_dll(cache, plan.openal_build, arch),
                    "dsoal-aldrv.dll".to_string(),
                ),
            ]
        }
    };
    list.iter().all(|(s, _)| s.is_file()).then_some(list)
}

/// The alsoft.ini text for the speaker setup.
pub fn alsoft_ini(speakers: &Speakers, advanced: bool) -> String {
    let v = speakers.alsoft_values();
    let header = if advanced {
        "# Auto-generated by EAX Restore Script for Linux (Advanced Tweaks)"
    } else {
        "# Auto-generated by EAX Restore Script for Linux"
    };
    let mut out = tpl::MAIN
        .replace("{HEADER}", header)
        .replace("{CHANNELS}", v.channels)
        .replace("{STEREO_MODE}", v.stereo_mode)
        .replace("{STEREO_ENCODING}", v.stereo_encoding)
        .replace("{HRTF_PREFIX}", if v.hrtf_on { "" } else { "# " })
        .replace("{HRTF_MODE}", "full");
    out.push('\n');
    if advanced {
        out.push_str(tpl::ADVANCED);
        out.push('\n');
    }
    if v.hq_decoder {
        out.push_str(tpl::DECODER);
        out.push('\n');
    }
    out.push_str(tpl::TAIL);
    out.push('\n');
    out
}

/// What the last install recorded, read before its manifest is replaced.
struct Previous {
    files: HashSet<Vec<u8>>,
    file_lines: Vec<Vec<u8>>,
    state: Vec<Vec<u8>>,
    config: Vec<Vec<u8>>,
    launcher: Vec<String>,
}

fn read_previous(manifest_path: &Path) -> Previous {
    let mut p = Previous {
        files: HashSet::new(),
        file_lines: Vec::new(),
        state: Vec::new(),
        config: Vec::new(),
        launcher: Vec::new(),
    };
    let data = std::fs::read(manifest_path).unwrap_or_default();
    if data.is_empty() {
        return p;
    }
    let body = data.strip_suffix(b"\n").unwrap_or(&data);
    for line in body.split(|&b| b == b'\n') {
        if line.starts_with(b"/") {
            p.files.insert(line.to_vec());
            p.file_lines.push(line.to_vec());
        }
        if line.starts_with(b"REGISTRY:")
            || line == b"VCRUN"
            || line.starts_with(b"VCRUN:")
            || line.starts_with(b"VCRUN\t")
            || line == b"EAXUNIFIED"
        {
            p.state.push(line.to_vec());
        }
        if line.starts_with(b"CONFIG:") {
            p.config.push(manifest::upgrade_config_line(line));
        }
        if line.starts_with(b"LAUNCHER:") {
            p.launcher.push(String::from_utf8_lossy(line).into_owned());
        }
    }
    p
}

fn append(m: &Path, line: &[u8]) {
    let _ = manifest::append(m, line);
}

fn path_line(p: &Path) -> &[u8] {
    p.as_os_str().as_bytes()
}

/// Copies the files into one folder, backing up what's there.
fn deploy_into(
    dir: &Path,
    list: &[(PathBuf, String)],
    prev: &Previous,
    stamp: &str,
    m: &Path,
    r: &mut Report,
) {
    for (src, name) in list {
        let dest = dir.join(name);
        match handle_conflict(&dest, &prev.files, stamp) {
            Cleared::Failed => {
                r.failures.push(dest.display().to_string());
                continue;
            }
            Cleared::BackedUp(b) => r.backed_up.push(b),
            _ => {}
        }
        if deploy_copy(src, &dest, m) {
            r.copied.push(dest);
        } else {
            r.failures.push(dest.display().to_string());
        }
    }
}

/// The DLL override in a launcher, once it's closed. Drops to manual when
/// it can't be written.
fn launcher_override(
    t: &Target,
    plan: &Plan,
    prev: &Previous,
    m: &Path,
    host: &mut dyn InstallHost,
    r: &mut Report,
) -> Override {
    if !host.launcher_closed(t) {
        r.launcher_left_open = true;
        return Override::Manual;
    }
    let game_dir = plan.game_dir.display().to_string();
    let w = changes::write_override(t, plan.engine.primary_dll(), &prev.launcher, &game_dir);
    let over = match &w {
        Written::Set(line) => {
            append(m, line.as_bytes());
            Override::Launcher(t.clone())
        }
        Written::Already(line) => {
            if let Some(l) = line {
                append(m, l.as_bytes());
            }
            Override::Launcher(t.clone())
        }
        Written::Failed => {
            r.failures.push(t.file.display().to_string());
            Override::Manual
        }
        Written::NoApp | Written::Unrecordable => Override::Manual,
    };
    r.launcher = Some(w);
    over
}

/// EAX_RESTORE_DSOAL_LOG: the sound logs on at their fullest (DSOAL's at 4
/// when it's installed, OpenAL Soft's at 3). Not recorded: uninstall drops
/// the variables with the DLL override.
fn sound_log_on(t: &Target, plan: &Plan) -> bool {
    let game_dir = plan.game_dir.display().to_string();
    let dsoal = if plan.engine == Engine::Dsoal {
        "4"
    } else {
        ""
    };
    let dsoal_log = options::dsoal_log_path_for_wine(&game_dir);
    let alsoft_log = options::alsoft_log_path_for_wine(&game_dir);
    let mut bak = t.file.as_os_str().to_owned();
    bak.push(".eax-restore.bak");
    let backup = |file: &Path| {
        if !Path::new(&bak).exists() {
            let _ = std::fs::copy(file, &bak);
        }
    };
    match t.launcher {
        Launcher::Steam => {
            let opts = t.get().or_empty();
            let new = options::with_sound_log(&opts, dsoal, &dsoal_log, "3", &alsoft_log);
            if new == opts {
                return true;
            }
            backup(&t.file);
            t.set(Some(&new)).is_ok() && t.get() == Held::Set(new)
        }
        Launcher::Heroic => {
            backup(&t.file);
            (dsoal.is_empty()
                || (t.set_env("DSOAL_LOGLEVEL", Some(dsoal)).is_ok()
                    && t.set_env("DSOAL_LOGFILE", Some(&dsoal_log)).is_ok()))
                && t.set_env("ALSOFT_LOGLEVEL", Some("3")).is_ok()
                && t.set_env("ALSOFT_LOGFILE", Some(&alsoft_log)).is_ok()
                && t.env("ALSOFT_LOGLEVEL") == Held::Set("3".into())
        }
    }
}

/// Runs the install. `eax_unified` names the installer and its checksums.
pub fn execute(plan: &Plan, cache: &Cache, eax: &Installer, host: &mut dyn InstallHost) -> Report {
    let mut r = Report::default();
    // Checked before anything changes, so a missing build never leaves the
    // prefix half set up.
    let Some(list) = sources(plan, cache) else {
        r.no_sources = true;
        return r;
    };
    let game_dir = &plan.game_dir;
    let m = manifest::path_in(game_dir);
    let stamp = timestamp();
    let primary = plan.engine.primary_dll();
    let prefix_ready = plan
        .prefix
        .as_ref()
        .filter(|p| !p.path.as_os_str().is_empty() && p.path.join("drive_c/windows").is_dir());

    if let Some(p) = &plan.prefix {
        r.openal_runtime = p.install_openal_runtime();
    }
    let mut vcrun_record: Option<&[u8]> = None;
    match (&plan.vcrun, &plan.prefix) {
        (Vcrun::Install, Some(p)) => {
            let rep = vcrun::install(
                p,
                game_dir,
                plan.arch,
                &cache.root.join("vcrun2022"),
                host.net(),
            );
            if rep.ok() {
                vcrun_record = Some(b"VCRUN");
            }
            r.vcrun = Some(rep);
        }
        (Vcrun::OverridesOnly, Some(p)) => {
            // Recorded even if setting them failed, so uninstall still tries
            // to clear any that did get written.
            vcrun::set_overrides(p, game_dir, true);
            vcrun_record = Some(b"VCRUN:OVERRIDES");
        }
        _ => {}
    }
    let mut eax_recorded = false;
    if let (true, Some(p)) = (plan.eax_unified, &plan.prefix) {
        let o = eax_unified::install(
            p,
            &cache.root.join("eax-unified"),
            eax,
            host.net(),
            Duration::from_secs(1),
        );
        eax_recorded = o == eax_unified::Outcome::Installed;
        r.eax_unified = Some(o);
    }

    let prev = read_previous(&m);
    let prev_manifest = manifest::start(&m, true).ok().flatten();
    for line in &prev.state {
        append(&m, line);
    }
    if let Some(line) = vcrun_record {
        append(&m, line);
    }
    if eax_recorded {
        append(&m, b"EAXUNIFIED");
    }

    for dir in std::iter::once(game_dir).chain(&plan.extra_dirs) {
        deploy_into(dir, &list, &prev, &stamp, &m, &mut r);
    }
    if let Some(p) = prefix_ready {
        let (copied, failed) =
            prefix::deploy_prefix_dlls(&p.path, plan.arch, &list, &prev.files, &stamp, &m);
        r.copied.extend(copied);
        r.failures
            .extend(failed.iter().map(|f| f.display().to_string()));
    }

    // alsoft.ini, written fresh, then the profile's values on top, then the
    // same file into every extra exe folder.
    let ini = game_dir.join("alsoft.ini");
    match handle_conflict(&ini, &prev.files, &stamp) {
        Cleared::Failed => r.failures.push(ini.display().to_string()),
        cleared => {
            if let Cleared::BackedUp(b) = cleared {
                r.backed_up.push(b);
            }
            let text = alsoft_ini(&plan.speakers, plan.advanced_limits);
            if std::fs::write(&ini, text).is_ok()
                && std::fs::metadata(&ini).is_ok_and(|x| x.len() > 0)
            {
                append(&m, path_line(&ini));
                for (sec, key, val) in &plan.alsoft_overrides {
                    if config::set_file(&ini, Format::Ini, sec, key, &Value::text(val)).is_err() {
                        r.failures.push(ini.display().to_string());
                    }
                }
                for dir in &plan.extra_dirs {
                    let dest = dir.join("alsoft.ini");
                    match handle_conflict(&dest, &prev.files, &stamp) {
                        Cleared::Failed => r.failures.push(dest.display().to_string()),
                        _ => {
                            if !deploy_copy(&ini, &dest, &m) {
                                r.failures.push(dest.display().to_string());
                            }
                        }
                    }
                }
            } else {
                r.failures.push(ini.display().to_string());
            }
        }
    }

    let mut over = plan.over.clone();
    if plan.com_routing || over == Override::Registry {
        let registry_override = (over == Override::Registry).then_some(primary);
        for line in prefix::registry_lines(plan.com_routing, registry_override, "") {
            append(&m, line.as_bytes());
        }
        let status = match &plan.prefix {
            Some(p) => prefix::apply_registry(p, game_dir, plan.com_routing, registry_override),
            None => RegStatus::Failed,
        };
        if status != RegStatus::Ok {
            r.failures.push("registry".into());
            if registry_override.is_some() {
                over = Override::Manual;
            }
        }
        r.registry = Some(status);
    }

    // Companion apps: the same prefix steps in each one's own prefix.
    let mut companion_launchers = Vec::new();
    for c in &plan.companions {
        let tag = format!("\t{}", c.app_id);
        let p = &c.prefix;
        if c.vcrun == Vcrun::Install
            && vcrun::install(
                p,
                game_dir,
                plan.arch,
                &cache.root.join("vcrun2022"),
                host.net(),
            )
            .ok()
        {
            append(&m, format!("VCRUN{tag}").as_bytes());
        }
        if c.vcrun == Vcrun::OverridesOnly {
            vcrun::set_overrides(p, game_dir, true);
            append(&m, format!("VCRUN:OVERRIDES{tag}").as_bytes());
        }
        p.install_openal_runtime();
        let (_, failed) =
            prefix::deploy_prefix_dlls(&p.path, plan.arch, &list, &prev.files, &stamp, &m);
        r.failures
            .extend(failed.iter().map(|f| f.display().to_string()));
        let reg_override = (c.over == Override::Registry).then_some(primary);
        if plan.com_routing || reg_override.is_some() {
            for line in prefix::registry_lines(plan.com_routing, reg_override, &tag) {
                append(&m, line.as_bytes());
            }
            if prefix::apply_registry(p, game_dir, plan.com_routing, reg_override) != RegStatus::Ok
            {
                r.failures.push(format!("registry for {}", c.name));
            }
        }
        if let Override::Launcher(t) = &c.over {
            companion_launchers.push(t.clone());
        }
    }

    // The launcher last of the deploy steps, so it's closed only once.
    if let Override::Launcher(t) = &over {
        over = launcher_override(t, plan, &prev, &m, host, &mut r);
        // As in the script: the companions' launch options are written once
        // the launcher is closed, even when the game's own didn't save.
        if !r.launcher_left_open {
            for ct in &companion_launchers {
                let w = changes::write_override(
                    ct,
                    primary,
                    &prev.launcher,
                    &game_dir.display().to_string(),
                );
                match w {
                    Written::Set(line) | Written::Already(Some(line)) => {
                        append(&m, line.as_bytes())
                    }
                    _ => {}
                }
            }
        }
    }
    if plan.sound_log {
        if let Some(t) = match (&plan.over, &over) {
            (Override::Launcher(t), _) => Some(t),
            _ => None,
        } {
            if host.launcher_closed(t) {
                sound_log_on(t, plan);
            }
        }
    }
    r.over = Some(over);

    // Files from the last install that this one didn't write again are still
    // ours and still in the folder, so they stay recorded.
    let now = std::fs::read(&m).unwrap_or_default();
    let have: HashSet<&[u8]> = now.split(|&b| b == b'\n').collect();
    for line in &prev.file_lines {
        if have.contains(line.as_slice()) {
            continue;
        }
        let p = Path::new(std::ffi::OsStr::from_bytes(line));
        if files::file_is_ours(p) && files::looks_like_our_file(p) {
            append(&m, line);
        }
    }
    let _ = manifest::dedupe(&m);

    // Always, even with nothing new: it also carries the last install's
    // settings that are still in effect into the new manifest.
    let settings = apply::apply(
        &plan.game_settings,
        &apply::Settings {
            manifest: &m,
            previous: &prev.config,
            previous_files: &prev.files,
            crash_markers: &plan.crash_markers,
        },
        host,
    );
    r.failures
        .extend(settings.failed.iter().map(|f| f.display().to_string()));
    r.settings = Some(settings);
    if let Some(p) = prev_manifest {
        let _ = std::fs::remove_file(p);
    }
    r
}
