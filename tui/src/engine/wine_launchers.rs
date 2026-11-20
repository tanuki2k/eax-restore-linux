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
    let pick = pick?;
    ["files/bin/wine", "dist/bin/wine"]
        .iter()
        .map(|b| pick.join(b))
        .find(|b| super::wine::is_executable(b))
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
    let folder = conf.parent().unwrap_or(conf).to_path_buf();
    let prefix = if custom == "true" && bpath.starts_with('/') {
        PathBuf::from(&bpath)
    } else {
        folder
    };
    let wine = Some(root.join("runners").join(&runner).join("bin/wine")).filter(|w| {
        !runner.is_empty() && !runner.starts_with("sys-") && super::wine::is_executable(w)
    });
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

// ---- Faugus -----------------------------------------------------------------

fn faugus(home: &Path, out: &mut Vec<LauncherGame>) {
    for f in [
        xdg_home(home, false).join("faugus-launcher/games.json"),
        home.join(".var/app/io.github.Faugus.faugus-launcher/config/faugus-launcher/games.json"),
    ] {
        let Some(list) = std::fs::read_to_string(&f)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        else {
            continue;
        };
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
            let runner = text("runner");
            if runner == "Linux-Native" || runner.eq_ignore_ascii_case("steam") {
                continue;
            }
            let exe = PathBuf::from(text("path"));
            if !is_exe(&exe) {
                continue;
            }
            let mut title = text("title");
            if title.is_empty() {
                title = text("gameid");
            }
            let prefix = text("prefix");
            out.push(LauncherGame {
                launcher: "Faugus",
                title,
                exe,
                prefix: (!prefix.is_empty()).then(|| PathBuf::from(prefix)),
                wine: proton_wine_for(home, &runner),
            });
        }
    }
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

/// `pga_path` from the `[lutris]` section of lutris.conf (the config
/// folder's, then the data folder's, read as one, like awk over both).
fn pga_path(cfg: &Path, data: &Path) -> String {
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
            if l.len() >= 8 && l[..8].eq_ignore_ascii_case("pga_path") {
                let rest = l[8..].trim_start_matches([' ', '\t']);
                if let Some(v) = rest.strip_prefix(['=', ':']) {
                    return v.trim_matches([' ', '\t', '\r']).to_string();
                }
            }
        }
    }
    String::new()
}

fn lutris_record(
    home: &Path,
    cfg: &Path,
    data: &Path,
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
    let prefix = lutris_path(&yaml_value(&yml, "game", "prefix"), dir, home);
    let mut version = yaml_value(&yml, "wine", "version");
    for y in [cfg.join("runners/wine.yml"), data.join("runners/wine.yml")] {
        if !version.is_empty() {
            break;
        }
        version = yaml_value(&y, "wine", "version");
    }
    let wine = Some(data.join("runners/wine").join(&version).join("bin/wine"))
        .filter(|w| !version.is_empty() && !version.contains('/') && super::wine::is_executable(w));
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
        let pga =
            lutris_path(&pga_path(&cfg, &data), "", home).unwrap_or_else(|| data.join("pga.db"));
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
                    lutris_record(home, &cfg, &data, t, c, d, out);
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
                        lutris_record(home, &cfg, &data, &lutris_slug_title(&cp), &cp, "", out);
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
    fn slugs_become_titles() {
        assert_eq!(lutris_slug_title("deus-ex-1700000000"), "Deus Ex");
        assert_eq!(
            lutris_slug_title("thief-ii-the-metal-age"),
            "Thief Ii The Metal Age"
        );
        assert_eq!(lutris_slug_title("1234"), "1234");
    }
}
