//! The Windows games Lutris, Bottles and Faugus run, with their exe, prefix
//! and Wine build, and the exe a launcher starts for an install folder. A
//! port of `wine_launcher_records`, `launcher_exe_for_root` and the prefix
//! step's `_env_find_wine_launcher_prefix` in `src/detection.sh`. None of
//! these launchers keeps a settings file the DLL override goes in, so their
//! games get it in the prefix's registry, written with this Wine build.

use super::roots::{heroic_dirs, steam_roots, xdg_home};
use serde_json::Value;
use std::cmp::Ordering;
use std::path::{Path, PathBuf};
use std::process::Command;

/// One game a Wine launcher runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LauncherGame {
    /// "Lutris", "Bottles" or "Faugus".
    pub launcher: &'static str,
    pub title: String,
    /// Always an existing .exe.
    pub exe: PathBuf,
    /// May not exist yet.
    pub prefix: Option<PathBuf>,
    /// The launcher's Wine binary for the game, when it's found.
    pub wine: Option<PathBuf>,
}

// ---- YAML, as these launchers write it --------------------------------------

/// One scalar: plain, 'single' or "double" quoted (`yaml_unquote`).
fn unquote(v: &str) -> String {
    let v = v
        .trim_start_matches([' ', '\t'])
        .trim_end_matches([' ', '\t', '\r']);
    let n = v.len();
    if n >= 2 && v.starts_with('\'') && v.ends_with('\'') {
        return v[1..n - 1].replace("''", "'");
    }
    if n >= 2 && v.starts_with('"') && v.ends_with('"') {
        return v[1..n - 1].replace("\\\"", "\"");
    }
    let plain = first_comment_cut(v).unwrap_or(v);
    if plain == "~" || plain == "null" {
        String::new()
    } else {
        plain.to_string()
    }
}

/// `v` up to its first run of blanks followed by `#`, as awk's leftmost match.
fn first_comment_cut(v: &str) -> Option<&str> {
    let b = v.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b' ' || b[i] == b'\t' {
            let mut j = i;
            while j < b.len() && (b[j] == b' ' || b[j] == b'\t') {
                j += 1;
            }
            if j < b.len() && b[j] == b'#' {
                return Some(&v[..i]);
            }
            i = j;
        } else {
            i += 1;
        }
    }
    None
}

/// A key one level under a top-level section (`yaml_value`).
pub fn yaml_value(file: &Path, section: &str, key: &str) -> String {
    let Ok(text) = std::fs::read_to_string(file) else {
        return String::new();
    };
    let head = format!("{section}:");
    let item = format!("  {key}:");
    let mut inside = false;
    for line in text.lines() {
        if line.starts_with(|c: char| c != ' ' && c != '\t' && c != '#') {
            inside = line.starts_with(&head);
            continue;
        }
        if inside && line.starts_with(&item) {
            return unquote(&line[item.len()..]);
        }
    }
    String::new()
}

// ---- Proton builds ----------------------------------------------------------

/// `sort -V` order: runs of digits compare as numbers, the rest byte by byte.
fn version_cmp(a: &str, b: &str) -> Ordering {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let si = i;
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            let sj = j;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let na = std::str::from_utf8(&a[si..i])
                .unwrap()
                .trim_start_matches('0');
            let nb = std::str::from_utf8(&b[sj..j])
                .unwrap()
                .trim_start_matches('0');
            let o = na.len().cmp(&nb.len()).then_with(|| na.cmp(nb));
            if o != Ordering::Equal {
                return o;
            }
        } else {
            if a[i] != b[j] {
                return a[i].cmp(&b[j]);
            }
            i += 1;
            j += 1;
        }
    }
    (a.len() - i).cmp(&(b.len() - j))
}

/// The wine binary of the Proton build called `name` in a
/// compatibilitytools.d folder; a name without its version takes the newest
/// build whose folder starts with it (`proton_wine_for`).
pub fn proton_wine_for(home: &Path, name: &str) -> Option<PathBuf> {
    if name.is_empty() {
        return None;
    }
    let mut bases: Vec<PathBuf> = steam_roots(home)
        .iter()
        .map(|r| r.join("compatibilitytools.d"))
        .collect();
    bases.push(home.join(".local/share/Steam/compatibilitytools.d"));
    let mut pick = None;
    let mut found: Vec<PathBuf> = Vec::new();
    for base in &bases {
        if base.join(name).is_dir() {
            pick = Some(base.join(name));
            break;
        }
        let mut dirs: Vec<PathBuf> = std::fs::read_dir(base)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir() && file_name(p).starts_with(name))
            .collect();
        dirs.sort();
        found.extend(dirs);
    }
    if pick.is_none() {
        pick = found
            .into_iter()
            .max_by(|a, b| version_cmp(&file_name(a), &file_name(b)));
    }
    proton_dir_wine(&pick?)
}

/// A Proton build's wine binary (files/bin, or dist/bin in older builds).
pub fn proton_dir_wine(dir: &Path) -> Option<PathBuf> {
    ["files/bin/wine", "dist/bin/wine"]
        .iter()
        .map(|b| dir.join(b))
        .find(|b| super::wine::is_executable(b))
}

/// The wine binary of a Faugus game's runner, chosen as Faugus does
/// (`faugus_runner_wine`): "Default" is the default runner, an empty one the
/// newest UMU-Proton build, "Proton-CachyOS (System)" the build in a system
/// data folder's steam/compatibilitytools.d (`data_dirs`, from
/// `$XDG_DATA_DIRS`), a folder path that folder, any other name a build in a
/// compatibilitytools.d folder.
pub fn faugus_runner_wine(
    home: &Path,
    runner: &str,
    default_runner: &str,
    data_dirs: &str,
) -> Option<PathBuf> {
    let mut runner = if runner == "Proton-CachyOS" {
        "Proton-CachyOS (System)"
    } else {
        runner
    };
    if runner.is_empty() {
        if let Some(w) = proton_wine_for(home, "UMU-Proton-") {
            return Some(w);
        }
        runner = default_runner;
    }
    if runner == "Default" {
        runner = default_runner;
    }
    if runner == "Proton-CachyOS (System)" {
        let dirs = if data_dirs.is_empty() {
            "/usr/local/share:/usr/share"
        } else {
            data_dirs
        };
        return dirs
            .split(':')
            .map(|d| Path::new(d).join("steam/compatibilitytools.d/proton-cachyos-slr"))
            .find(|d| d.is_dir())
            .and_then(|d| proton_dir_wine(&d));
    }
    if runner.starts_with('/') {
        return Some(Path::new(runner))
            .filter(|d| d.is_dir())
            .and_then(proton_dir_wine);
    }
    proton_wine_for(home, runner)
}

fn file_name(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

fn is_exe(p: &Path) -> bool {
    p.to_string_lossy().to_lowercase().ends_with(".exe") && p.is_file()
}

// ---- Bottles ----------------------------------------------------------------

fn bottles(home: &Path, out: &mut Vec<LauncherGame>) {
    for root in [
        xdg_home(home, true).join("bottles"),
        home.join(".var/app/com.usebottles.bottles/data/bottles"),
    ] {
        if !root.is_dir() {
            continue;
        }
        let mut bottles_dir = root.join("bottles");
        if let Ok(text) = std::fs::read_to_string(root.join("data.yml")) {
            if let Some(line) = text.lines().find(|l| l.starts_with("custom_bottles_path:")) {
                let custom = PathBuf::from(unquote(&line["custom_bottles_path:".len()..]));
                if custom.is_absolute() && custom.is_dir() {
                    bottles_dir = custom;
                }
            }
        }
        let mut confs: Vec<PathBuf> = std::fs::read_dir(&bottles_dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path().join("bottle.yml"))
            .filter(|p| p.is_file())
            .collect();
        confs.sort();
        for conf in confs {
            bottle(&root, &conf, out);
        }
    }
}

/// One bottle.yml: its programs, then its own settings, read the way the
/// script's awk does.
fn bottle(root: &Path, conf: &Path, out: &mut Vec<LauncherGame>) {
    let Ok(text) = std::fs::read_to_string(conf) else {
        return;
    };
    let (mut runner, mut custom, mut bpath) = (String::new(), String::new(), String::new());
    let (mut arch, mut env) = (String::new(), String::new());
    // (name, path, removed)
    let mut programs: Vec<(String, String, String)> = Vec::new();
    let mut current: Option<(String, String, String)> = None;
    let mut section = String::new();
    for line in text.lines() {
        if line.starts_with(|c: char| c != ' ' && c != '\t' && c != '#') {
            programs.extend(current.take());
            section = line.split(':').next().unwrap_or("").to_string();
            if let Some(v) = line.strip_prefix("Runner:") {
                runner = unquote(v);
            }
            if let Some(v) = line.strip_prefix("Path:") {
                bpath = unquote(v);
            }
            if let Some(v) = line.strip_prefix("Custom_Path:") {
                custom = unquote(v);
            }
            if let Some(v) = line.strip_prefix("Arch:") {
                arch = unquote(v);
            }
            if let Some(v) = line.strip_prefix("Environment:") {
                env = unquote(v);
            }
            continue;
        }
        if section != "External_Programs" {
            continue;
        }
        if line.starts_with("  ") && !line[2..].starts_with([' ']) && line.len() > 2 {
            programs.extend(current.take());
            current = Some(Default::default());
            continue;
        }
        if let Some(p) = current.as_mut() {
            if let Some(v) = line.strip_prefix("    name:") {
                p.0 = unquote(v);
            }
            if let Some(v) = line.strip_prefix("    path:") {
                p.1 = unquote(v);
            }
            if let Some(v) = line.strip_prefix("    removed:") {
                p.2 = unquote(v);
            }
        }
    }
    programs.extend(current.take());
    // A Steam bottle is a Steam game's own Proton prefix, which the Steam
    // route handles.
    if env == "Steam" {
        return;
    }
    // Custom_Path is true (or, in newer files, any non-empty text) when the
    // bottle lives at Path rather than in this folder.
    let folder = conf.parent().unwrap_or(conf).to_path_buf();
    let custom_on = !matches!(custom.as_str(), "" | "false" | "False" | "FALSE");
    let prefix = if custom_on && bpath.starts_with('/') {
        PathBuf::from(&bpath)
    } else {
        folder
    };
    let wine = bottles_runner_wine(root, &runner, &arch);
    for (name, path, removed) in programs {
        let exe = PathBuf::from(&path);
        if removed == "true" || !is_exe(&exe) {
            continue;
        }
        let mut title = if name.is_empty() {
            file_name(&exe)
        } else {
            name
        };
        if title.to_lowercase().ends_with(".exe") {
            title.truncate(title.len() - 4);
        }
        out.push(LauncherGame {
            launcher: "Bottles",
            title,
            exe,
            prefix: Some(prefix.clone()),
            wine: wine.clone(),
        });
    }
}

/// `wine` on PATH, as `command -v wine` finds it.
fn system_wine() -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|d| d.join("wine"))
        .find(|p| super::wine::is_executable(p))
}

/// The wine binary of a bottle's runner, as Bottles picks it
/// (`bottles_runner_wine`): a sys-* runner is the system's wine, a Proton
/// build (it has toolmanifest.vdf) has it in dist/ or files/, any other
/// runner in bin/, and a win64 bottle uses wine64 when the runner has one.
pub fn bottles_runner_wine(root: &Path, runner: &str, arch: &str) -> Option<PathBuf> {
    if runner.is_empty() {
        return None;
    }
    if runner.starts_with("sys-") {
        return system_wine();
    }
    let dir = root.join("runners").join(runner);
    let mut wine = dir.join("bin/wine");
    if dir.join("toolmanifest.vdf").is_file() {
        wine = if dir.join("dist").is_dir() {
            dir.join("dist/bin/wine")
        } else {
            dir.join("files/bin/wine")
        };
    }
    let arch = if arch.is_empty() { "win64" } else { arch };
    let wine64 = PathBuf::from(format!("{}64", wine.display()));
    if arch == "win64" && wine64.exists() {
        wine = wine64;
    }
    super::wine::is_executable(&wine).then_some(wine)
}

// ---- Faugus -----------------------------------------------------------------

fn faugus(home: &Path, out: &mut Vec<LauncherGame>) {
    let data_dirs = std::env::var("XDG_DATA_DIRS").unwrap_or_default();
    let flatpak = home.join(".var/app/io.github.Faugus.faugus-launcher");
    for (data, cfg) in [
        (
            xdg_home(home, true).join("faugus-launcher"),
            xdg_home(home, false).join("faugus-launcher"),
        ),
        (
            flatpak.join("data/faugus-launcher"),
            flatpak.join("config/faugus-launcher"),
        ),
    ] {
        // The game list is in Faugus's data folder; older versions kept it
        // beside their settings.
        let f = Some(data.join("games.json"))
            .filter(|f| f.is_file())
            .unwrap_or_else(|| cfg.join("games.json"));
        let Some(list) = std::fs::read_to_string(&f)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        else {
            continue;
        };
        let (default_runner, default_prefix) = faugus_defaults(home, &cfg);
        let games: Vec<&Value> = match &list {
            Value::Array(a) => a.iter().collect(),
            Value::Object(o) => o.values().collect(),
            _ => Vec::new(),
        };
        for g in games.into_iter().filter(|g| g.is_object()) {
            let text = |k: &str| match g.get(k) {
                Some(Value::String(s)) => s.trim().to_string(),
                _ => String::new(),
            };
            let mut runner = text("runner");
            if runner == "Linux-Native" || runner.eq_ignore_ascii_case("steam") {
                continue;
            }
            let exe = PathBuf::from(text("path"));
            if !is_exe(&exe) {
                continue;
            }
            let gameid = text("gameid");
            let mut title = text("title");
            if title.is_empty() {
                title = gameid.clone();
            }
            // No prefix of its own: Faugus runs it in default-prefix/default,
            // on the default runner.
            let mut prefix = text("prefix");
            if prefix.is_empty() {
                if !default_prefix.is_empty() {
                    let base = default_prefix.strip_suffix('/').unwrap_or(&default_prefix);
                    prefix = format!("{base}/default");
                }
                runner = "Default".into();
            }
            out.push(LauncherGame {
                launcher: "Faugus",
                title,
                exe,
                prefix: (!prefix.is_empty()).then(|| PathBuf::from(prefix)),
                wine: faugus_runner_wine(home, &runner, &default_runner, &data_dirs),
            });
        }
    }
}

/// Faugus's default runner and prefix folder: config.json, or config.ini
/// (key=value) in older versions, else Faugus's own defaults.
fn faugus_defaults(home: &Path, cfg: &Path) -> (String, String) {
    let (mut runner, mut prefix) = (String::new(), String::new());
    if let Ok(t) = std::fs::read_to_string(cfg.join("config.json")) {
        if let Ok(v) = serde_json::from_str::<Value>(&t) {
            let get = |k: &str| match v.get(k) {
                Some(Value::String(s)) => s.clone(),
                _ => String::new(),
            };
            runner = get("default-runner");
            prefix = get("default-prefix");
        }
    } else if let Ok(t) = std::fs::read_to_string(cfg.join("config.ini")) {
        let value = |key: &str| {
            t.lines()
                .find_map(|l| {
                    let (k, v) = l.split_once('=')?;
                    (k.trim() == key).then(|| v.trim_start().to_string())
                })
                .unwrap_or_default()
        };
        runner = value("default-runner");
        prefix = value("default-prefix");
    }
    let clean = |s: String| s.replace('"', "").trim_end_matches('\r').to_string();
    let (mut runner, mut prefix) = (clean(runner), clean(prefix));
    if runner.is_empty() {
        runner = "Proton-CachyOS Latest".into();
    }
    if prefix.is_empty() {
        prefix = home.join("Faugus").display().to_string();
    }
    let prefix = lutris_path(&prefix, "", home)
        .map(|p| p.display().to_string())
        .unwrap_or_default();
    (runner, prefix)
}

// ---- Lutris -----------------------------------------------------------------

/// "config dir, data dir" per Lutris install, native then Flatpak.
fn lutris_installs(home: &Path) -> Vec<(PathBuf, PathBuf)> {
    [
        (
            xdg_home(home, false).join("lutris"),
            xdg_home(home, true).join("lutris"),
        ),
        (
            home.join(".var/app/net.lutris.Lutris/config/lutris"),
            home.join(".var/app/net.lutris.Lutris/data/lutris"),
        ),
    ]
    .into_iter()
    .filter(|(c, d)| c.is_dir() || d.is_dir())
    .collect()
}

/// A path from Lutris's files: `~` is the home folder, a relative one is
/// under the game's folder (`lutris_path`).
pub fn lutris_path(p: &str, dir: &str, home: &Path) -> Option<PathBuf> {
    if p.is_empty() {
        return None;
    }
    let p = if p == "~" {
        home.display().to_string()
    } else if let Some(r) = p.strip_prefix("~/") {
        format!("{}/{r}", home.display())
    } else {
        p.to_string()
    };
    let dir = match dir.strip_prefix("~/") {
        Some(r) => format!("{}/{r}", home.display()),
        None => dir.to_string(),
    };
    if p.starts_with('/') {
        return Some(PathBuf::from(p));
    }
    if !dir.starts_with('/') {
        return None;
    }
    Some(PathBuf::from(format!(
        "{}/{p}",
        dir.strip_suffix('/').unwrap_or(&dir)
    )))
}

/// A title from a game's YAML file name: "deus-ex-1700000000" is "Deus Ex".
pub fn lutris_slug_title(slug: &str) -> String {
    let base = match slug.rfind('-') {
        Some(i) if i + 1 < slug.len() && slug[i + 1..].bytes().all(|b| b.is_ascii_digit()) => {
            &slug[..i]
        }
        _ => slug,
    };
    let words: Vec<String> = base
        .split('-')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_ascii_uppercase().to_string() + c.as_str(),
                None => String::new(),
            }
        })
        .collect();
    let t = words.join(" ");
    if t.is_empty() {
        slug.to_string()
    } else {
        t
    }
}

/// A `[lutris]` setting from lutris.conf (the config folder's, then the data
/// folder's, read as one, like awk over both): `lutris_conf_value`.
fn lutris_conf_value(cfg: &Path, data: &Path, key: &str) -> String {
    let mut inside = false;
    for f in [cfg.join("lutris.conf"), data.join("lutris.conf")] {
        let Ok(text) = std::fs::read_to_string(f) else {
            continue;
        };
        for line in text.lines() {
            if line.starts_with('[') {
                inside = line.trim_end_matches([' ', '\t', '\r']) == "[lutris]";
                continue;
            }
            if !inside {
                continue;
            }
            let l = line.trim_start_matches([' ', '\t']);
            let n = key.len();
            if l.len() >= n && l.is_char_boundary(n) && l[..n].eq_ignore_ascii_case(key) {
                let rest = l[n..].trim_start_matches([' ', '\t']);
                if let Some(v) = rest.strip_prefix(['=', ':']) {
                    return v.trim_matches([' ', '\t', '\r']).to_string();
                }
            }
        }
    }
    String::new()
}

/// The wine binary of a Lutris Wine version, as Lutris picks it
/// (`lutris_wine_for`): none set (or "ge-proton") is the newest GE-Proton,
/// "system" and "System wine-x" the system's, "custom" the custom path, a
/// Proton build (a folder with a proton file, in Lutris's Wine folder,
/// compatibilitytools.d or a Steam library) its dist/ or files/, else
/// `<wine_dir>/<version>`. A missing version falls back to the newest
/// GE-Proton, as Lutris does.
pub fn lutris_wine_for(
    home: &Path,
    version: &str,
    wine_dir: &Path,
    custom: Option<&Path>,
) -> Option<PathBuf> {
    let version = if version.is_empty() {
        "ge-proton"
    } else {
        version
    };
    match version {
        "ge-proton" => return proton_wine_for(home, "GE-Proton"),
        "system" => return system_wine(),
        "custom" => {
            return custom
                .filter(|c| super::wine::is_executable(c))
                .map(Path::to_path_buf)
        }
        _ => {}
    }
    if let Some(name) = version.strip_prefix("System wine-") {
        let f = PathBuf::from(format!("/usr/lib/wine-{name}/bin/wine"));
        return super::wine::is_executable(&f).then_some(f);
    }
    if !version.contains('/') {
        let mut bases = vec![wine_dir.to_path_buf()];
        bases.extend(
            steam_roots(home)
                .iter()
                .map(|r| r.join("compatibilitytools.d")),
        );
        bases.push(home.join(".local/share/Steam/compatibilitytools.d"));
        for lib in crate::library::steam_library_dirs(home) {
            bases.push(lib.join("common"));
            bases.push(lib);
        }
        let arch_name = format!("{version}-{}", std::env::consts::ARCH);
        for base in &bases {
            for d in [base.join(version), base.join(&arch_name)] {
                if !d.join("proton").is_file() {
                    continue;
                }
                if let Some(f) = ["dist/bin/wine", "files/bin/wine"]
                    .iter()
                    .map(|f| d.join(f))
                    .find(|f| f.exists())
                {
                    return Some(f);
                }
            }
        }
        let own = wine_dir.join(version).join("bin/wine");
        if super::wine::is_executable(&own) {
            return Some(own);
        }
    }
    proton_wine_for(home, "GE-Proton")
}

/// The prefix above a game's exe, for a game with none set: the first folder
/// up from it that is a prefix (drive_c and user.reg), or has one in prefix/
/// or pfx/ (`lutris_find_prefix`).
pub fn lutris_find_prefix(exe: &Path) -> Option<PathBuf> {
    let is_prefix = |p: &Path| p.join("drive_c").is_dir() && p.join("user.reg").exists();
    exe.ancestors()
        .skip(1)
        .take_while(|d| !d.as_os_str().is_empty() && *d != Path::new("/"))
        .flat_map(|d| [d.to_path_buf(), d.join("prefix"), d.join("pfx")])
        .find(|p| is_prefix(p))
}

#[allow(clippy::too_many_arguments)]
fn lutris_record(
    home: &Path,
    cfg: &Path,
    data: &Path,
    runner_dir: &Path,
    title: &str,
    cp: &str,
    dir: &str,
    out: &mut Vec<LauncherGame>,
) {
    if cp.is_empty() || cp.contains('/') || cp == "." || cp == ".." {
        return;
    }
    let Some(yml) = [
        cfg.join(format!("games/{cp}.yml")),
        data.join(format!("games/{cp}.yml")),
    ]
    .into_iter()
    .find(|y| y.is_file()) else {
        return;
    };
    let Some(exe) = lutris_path(&yaml_value(&yml, "game", "exe"), dir, home) else {
        return;
    };
    if !is_exe(&exe) {
        return;
    }
    let prefix = lutris_path(&yaml_value(&yml, "game", "prefix"), dir, home)
        .or_else(|| lutris_find_prefix(&exe));
    // The game's own Wine version (and custom path), else the ones set for
    // every Wine game.
    let mut version = yaml_value(&yml, "wine", "version");
    let mut custom = yaml_value(&yml, "wine", "custom_wine_path");
    for y in [cfg.join("runners/wine.yml"), data.join("runners/wine.yml")] {
        if version.is_empty() {
            version = yaml_value(&y, "wine", "version");
        }
        if custom.is_empty() {
            custom = yaml_value(&y, "wine", "custom_wine_path");
        }
    }
    let custom = lutris_path(&custom, "", home);
    let wine = lutris_wine_for(home, &version, &runner_dir.join("wine"), custom.as_deref());
    out.push(LauncherGame {
        launcher: "Lutris",
        title: if title.is_empty() { cp } else { title }.to_string(),
        exe,
        prefix,
        wine,
    });
}

fn lutris(home: &Path, out: &mut Vec<LauncherGame>) {
    for (cfg, data) in lutris_installs(home) {
        let pga = lutris_path(&lutris_conf_value(&cfg, &data, "pga_path"), "", home)
            .unwrap_or_else(|| data.join("pga.db"));
        let runner_dir = lutris_path(&lutris_conf_value(&cfg, &data, "runner_dir"), "", home)
            .unwrap_or_else(|| data.join("runners"));
        let rows = if pga.is_file() {
            // Read-only: a running Lutris keeps the file open.
            Command::new("sqlite3")
                .arg("-readonly")
                .arg("-separator")
                .arg("\x1f")
                .arg(&pga)
                .arg("SELECT name, configpath, directory FROM games WHERE runner = 'wine' AND installed = 1 ORDER BY id")
                .stderr(std::process::Stdio::null())
                .output()
                .ok()
        } else {
            None
        };
        match rows {
            Some(o) => {
                for row in String::from_utf8_lossy(&o.stdout).lines() {
                    let mut f = row.splitn(3, '\x1f');
                    let (t, c, d) = (
                        f.next().unwrap_or(""),
                        f.next().unwrap_or(""),
                        f.next().unwrap_or(""),
                    );
                    lutris_record(home, &cfg, &data, &runner_dir, t, c, d, out);
                }
            }
            // No database, or no sqlite3 to read it: the YAML files alone,
            // without the game folder a relative exe path needs.
            None => {
                let mut seen = std::collections::HashSet::new();
                for dir in [cfg.join("games"), data.join("games")] {
                    let mut ymls: Vec<PathBuf> = std::fs::read_dir(&dir)
                        .into_iter()
                        .flatten()
                        .flatten()
                        .map(|e| e.path())
                        .filter(|p| p.extension().is_some_and(|e| e == "yml") && p.is_file())
                        .collect();
                    ymls.sort();
                    for y in ymls {
                        let cp = y
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                            .unwrap_or_default();
                        if !seen.insert(cp.clone()) {
                            continue;
                        }
                        lutris_record(
                            home,
                            &cfg,
                            &data,
                            &runner_dir,
                            &lutris_slug_title(&cp),
                            &cp,
                            "",
                            out,
                        );
                    }
                }
            }
        }
    }
}

// ---- together ---------------------------------------------------------------

/// Every Windows game Lutris, Bottles and Faugus run whose exe exists
/// (`wine_launcher_records`).
pub fn records(home: &Path) -> Vec<LauncherGame> {
    let mut out = Vec::new();
    lutris(home, &mut out);
    bottles(home, &mut out);
    faugus(home, &mut out);
    out
}

/// The launcher game whose exe is in `game_dir`, a folder above it or one
/// below it: the first that matches (`_env_find_wine_launcher_prefix`).
pub fn for_dir(home: &Path, game_dir: &Path) -> Option<LauncherGame> {
    let gd = game_dir.to_string_lossy();
    let gd = gd.strip_suffix('/').unwrap_or(&gd).to_string();
    records(home).into_iter().find(|g| {
        let dir = g
            .exe
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        gd == dir || gd.starts_with(&format!("{dir}/")) || dir.starts_with(&format!("{gd}/"))
    })
}

/// The exe a launcher starts for the game installed at `root`: Heroic's
/// `executable` for a store game (relative to its folder) or a game added by
/// hand, else the exe Lutris, Bottles or Faugus runs from that folder or one
/// under it (`launcher_exe_for_root`).
pub fn launcher_exe_for_root(home: &Path, root: &Path) -> Option<PathBuf> {
    let r = root.to_string_lossy();
    let r = r.strip_suffix('/').unwrap_or(&r).to_string();
    if r.is_empty() {
        return None;
    }
    let trimmed = |v: Option<&Value>| -> String {
        let s = match v {
            Some(Value::String(s)) => s.clone(),
            None | Some(Value::Null) | Some(Value::Bool(false)) => String::new(),
            Some(o) => o.to_string(),
        };
        // jq's rtrimstr("/") takes off one slash.
        s.strip_suffix('/').unwrap_or(&s).to_string()
    };
    for conf in heroic_dirs(home) {
        let mut exes: Vec<String> = Vec::new();
        for json in super::identify::installed_jsons_under(&conf) {
            let Some(v) = std::fs::read_to_string(&json)
                .ok()
                .and_then(|t| serde_json::from_str::<Value>(&t).ok())
            else {
                continue;
            };
            fn walk(
                v: &Value,
                r: &str,
                trimmed: &dyn Fn(Option<&Value>) -> String,
                out: &mut Vec<String>,
            ) {
                match v {
                    Value::Object(o) => {
                        let path = o
                            .get("install_path")
                            .filter(|x| !matches!(x, Value::Null | Value::Bool(false)))
                            .or_else(|| o.get("installPath"));
                        if trimmed(path) == r {
                            if let Some(Value::String(e)) = o.get("executable") {
                                out.push(e.clone());
                            }
                        }
                        o.values().for_each(|x| walk(x, r, trimmed, out));
                    }
                    Value::Array(a) => a.iter().for_each(|x| walk(x, r, trimmed, out)),
                    _ => {}
                }
            }
            walk(&v, &r, &trimmed, &mut exes);
        }
        if let Some(v) = std::fs::read_to_string(conf.join("sideload_apps/library.json"))
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        {
            let games: Vec<&Value> = match v.get("games") {
                Some(Value::Array(a)) => a.iter().collect(),
                Some(Value::Object(o)) => o.values().collect(),
                _ => Vec::new(),
            };
            for g in games.into_iter().filter(|g| g.is_object()) {
                if trimmed(g.get("folder_name")) != r {
                    continue;
                }
                fn last(v: &Value, out: &mut Option<String>) {
                    match v {
                        Value::Object(o) => {
                            if let Some(Value::String(s)) = o.get("executable") {
                                *out = Some(s.clone());
                            }
                            o.values().for_each(|x| last(x, out));
                        }
                        Value::Array(a) => a.iter().for_each(|x| last(x, out)),
                        _ => {}
                    }
                }
                let mut e = None;
                last(g, &mut e);
                exes.extend(e);
            }
        }
        for e in exes.into_iter().filter(|e| !e.is_empty()) {
            let p = if e.starts_with('/') {
                PathBuf::from(e)
            } else {
                PathBuf::from(format!("{r}/{e}"))
            };
            if p.is_file() {
                return Some(p);
            }
        }
    }
    records(home)
        .into_iter()
        .find(|g| {
            let s = g.exe.to_string_lossy();
            g.exe.parent().is_some_and(|d| d.to_string_lossy() == r)
                || s.starts_with(&format!("{r}/"))
        })
        .map(|g| g.exe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalars_unquote_like_the_script() {
        assert_eq!(unquote(" 'Thief: Gold'"), "Thief: Gold");
        assert_eq!(unquote(" 'it''s'"), "it's");
        assert_eq!(unquote(" \"a \\\"b\\\"\""), "a \"b\"");
        assert_eq!(unquote(" /a/b # note"), "/a/b");
        assert_eq!(unquote(" a#b"), "a#b");
        assert_eq!(unquote(" ~"), "");
        assert_eq!(unquote(" ~/Games"), "~/Games");
    }

    #[test]
    fn versions_sort_like_sort_v() {
        assert_eq!(
            version_cmp("GE-Proton10-1", "GE-Proton9-20"),
            Ordering::Greater
        );
        assert_eq!(version_cmp("GE-Proton9-2", "GE-Proton9-20"), Ordering::Less);
    }

    #[test]
    fn faugus_runners_resolve_the_way_faugus_resolves_them() {
        let t = tempfile::tempdir().unwrap();
        let h = t.path();
        let wine = |rel: &str| {
            let p = h.join(rel).join("files/bin/wine");
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(&p, "#!/bin/sh\n").unwrap();
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
            p
        };
        std::fs::create_dir_all(h.join(".local/share/Steam/steamapps")).unwrap();
        let tools = ".local/share/Steam/compatibilitytools.d";
        wine(&format!("{tools}/UMU-Proton-9.0-3"));
        let umu = wine(&format!("{tools}/UMU-Proton-10.0-1"));
        let cachy = wine(&format!("{tools}/Proton-CachyOS Latest"));
        let system = wine("share/steam/compatibilitytools.d/proton-cachyos-slr");
        let own = wine("my-proton");
        let data_dirs = format!("/nowhere:{}", h.join("share").display());
        let r = |runner: &str| faugus_runner_wine(h, runner, "Proton-CachyOS Latest", &data_dirs);
        assert_eq!(r(""), Some(umu));
        assert_eq!(r("Default"), Some(cachy));
        assert_eq!(r("Proton-CachyOS"), Some(system));
        assert_eq!(r(&h.join("my-proton").display().to_string()), Some(own));
        assert_eq!(r("Missing"), None);
    }

    fn fake_wine(p: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o755)).unwrap();
        p.to_path_buf()
    }

    #[test]
    fn lutris_versions_resolve_the_way_lutris_resolves_them() {
        let t = tempfile::tempdir().unwrap();
        let h = t.path();
        std::fs::create_dir_all(h.join(".local/share/Steam/steamapps")).unwrap();
        let tools = h.join(".local/share/Steam/compatibilitytools.d");
        fake_wine(&tools.join("GE-Proton9-20/files/bin/wine"));
        let ge = fake_wine(&tools.join("GE-Proton10-1/files/bin/wine"));
        let custom_proton = fake_wine(&tools.join("Proton-Custom/files/bin/wine"));
        std::fs::write(tools.join("Proton-Custom/proton"), "").unwrap();
        let wd = h.join(".local/share/lutris/runners/wine");
        let own = fake_wine(&wd.join("lutris-7/bin/wine"));
        let mine = fake_wine(&h.join("mywine/bin/wine"));
        let r = |v: &str| lutris_wine_for(h, v, &wd, Some(&mine));
        assert_eq!(r(""), Some(ge.clone()));
        assert_eq!(r("ge-proton"), Some(ge.clone()));
        assert_eq!(r("custom"), Some(mine.clone()));
        assert_eq!(r("Proton-Custom"), Some(custom_proton));
        assert_eq!(r("lutris-7"), Some(own));
        assert_eq!(r("lutris-gone"), Some(ge));
    }

    #[test]
    fn bottles_runners_resolve_the_way_bottles_resolves_them() {
        let t = tempfile::tempdir().unwrap();
        let root = t.path();
        let soda = fake_wine(&root.join("runners/soda-9/bin/wine"));
        let px = root.join("runners/proton-x");
        std::fs::create_dir_all(&px).unwrap();
        std::fs::write(px.join("toolmanifest.vdf"), "").unwrap();
        fake_wine(&px.join("files/bin/wine"));
        let dist = fake_wine(&px.join("dist/bin/wine"));
        let dist64 = fake_wine(&px.join("dist/bin/wine64"));
        assert_eq!(bottles_runner_wine(root, "soda-9", "win64"), Some(soda));
        assert_eq!(bottles_runner_wine(root, "proton-x", ""), Some(dist64));
        assert_eq!(bottles_runner_wine(root, "proton-x", "win32"), Some(dist));
        assert_eq!(bottles_runner_wine(root, "gone", "win64"), None);
        assert_eq!(bottles_runner_wine(root, "", "win64"), None);
    }

    #[test]
    fn a_lutris_prefix_is_found_above_the_exe() {
        let t = tempfile::tempdir().unwrap();
        let g = t.path().join("Game");
        std::fs::create_dir_all(g.join("pfx/drive_c")).unwrap();
        std::fs::write(g.join("pfx/user.reg"), "").unwrap();
        assert_eq!(
            lutris_find_prefix(&g.join("bin/x/game.exe")),
            Some(g.join("pfx"))
        );
        assert_eq!(lutris_find_prefix(&t.path().join("Other/game.exe")), None);
    }

    #[test]
    fn slugs_become_titles() {
        assert_eq!(lutris_slug_title("deus-ex-1700000000"), "Deus Ex");
        assert_eq!(
            lutris_slug_title("thief-ii-the-metal-age"),
            "Thief Ii The Metal Age"
        );
        assert_eq!(lutris_slug_title("1234"), "1234");
    }
}
