//! Working out an install's facts from the game's files and its launcher:
//! which folder holds its exe, whether it's a Linux build, its extra exe
//! folders, which audio API it uses, its Steam AppID or Heroic prefix, and
//! its companion apps. Ports of the detection in `src/detection.sh`,
//! `resolve_extra_exe_folders` and `resolve_companion_apps`, without their
//! questions: each returns what it found, ranked when there's a choice.

use super::files::{find_existing_variant, is_openal_soft_dll};
use super::identify::{acf_value, heroic_installed_jsons};
use super::wine;
use crate::db::Game;
use regex::Regex;
use serde_json::Value;
use std::collections::HashSet;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

// ---- names ------------------------------------------------------------------

/// Installers and utilities, by their own file name (lowercased).
const EXE_JUNK: &str = r"^(unins(t(all)?)?[0-9]*|vc_?redist.*|(dx|directx)?setup|dxsetup|dxwebsetup|dx[0-9]+ger|dx[0-9]+ntger|dotnetfx.*|ndp[0-9].*|windowsdesktop-runtime.*|oalinst|physx.*|easyanticheat.*|eac_?setup.*|eaclauncher|be(service|daisy|launcher|_ex)[a-z0-9_]*|battleye.*|unitycrashhandler.*|crashreport(er|client)?|crash_?handler|crashpad_handler|bugsplat.*|epiconlineservices(installer)?|epicwebhelper.*|rockstar-games-launcher|social-club-setup|tagesclient.*|vulkanrt.*installer.*|gamingrepair(tool)?|registrationreminder|overlayinjector|cleanup|touchup|driverversionchecker|layerschecker|supporttool|dowser|iscopyfiles|detectionui.*|eax[0-9]*unified_redist.*|reg|.*updatelauncher|adb?e?rdr.*|ue3?redist.*|unrealfrontend|unrealconsole|uescriptprofiler|cookersync|testapp|.*oshelper)\.exe$";

fn junk_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(EXE_JUNK).expect("the junk pattern compiles"))
}

fn file_name_of(p: &Path) -> String {
    p.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// An installer or utility, by its own name.
pub fn exe_is_junk(p: &Path) -> bool {
    junk_re().is_match(&file_name_of(p).to_ascii_lowercase())
}

/// A name for comparing folder and exe names: lowercased, Roman numerals
/// II–IX standing alone turned into digits ("Gothic II" and Gothic2.exe
/// meet), then only letters and digits kept. Bare I, V and X are ordinary
/// words too, so they're left alone.
pub fn normalize_game_name(s: &str) -> String {
    static RES: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    let res = RES.get_or_init(|| {
        [
            ("viii", "8"),
            ("vii", "7"),
            ("vi", "6"),
            ("iv", "4"),
            ("ix", "9"),
            ("iii", "3"),
            ("ii", "2"),
        ]
        .iter()
        .map(|(n, d)| {
            (
                Regex::new(&format!("(^|[^a-z0-9]){n}([^a-z0-9]|$)")).expect("compiles"),
                *d,
            )
        })
        .collect()
    });
    let mut t = s.to_ascii_lowercase();
    for (re, d) in res {
        t = re
            .replace_all(&t, format!("${{1}} {d} ${{2}}").as_str())
            .into_owned();
    }
    t.bytes()
        .filter(u8::is_ascii_alphanumeric)
        .map(char::from)
        .collect()
}

/// The exe's name (without `.exe`) and the folder's, one inside the other.
fn exe_name_matches(root_norm: &str, exe: &Path) -> bool {
    if root_norm.is_empty() {
        return false;
    }
    let name = file_name_of(exe);
    let stem = name.strip_suffix(".exe").unwrap_or(&name);
    let n = normalize_game_name(stem);
    n.contains(root_norm) || root_norm.contains(&n)
}

// ---- walking folders --------------------------------------------------------

/// Regular files (not links) under `root`, `min..=max` levels down (its own
/// files are level 1), as (level, path), in the order `find` lists them.
fn files_at(
    root: &Path,
    min: usize,
    max: usize,
    keep: &dyn Fn(&Path) -> bool,
) -> Vec<(usize, PathBuf)> {
    fn walk(
        dir: &Path,
        level: usize,
        min: usize,
        max: usize,
        keep: &dyn Fn(&Path) -> bool,
        out: &mut Vec<(usize, PathBuf)>,
    ) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let Ok(t) = e.file_type() else { continue };
            let p = e.path();
            if t.is_file() {
                if level >= min && keep(&p) {
                    out.push((level, p));
                }
            } else if t.is_dir() && level < max {
                walk(&p, level + 1, min, max, keep, out);
            }
        }
    }
    let mut out = Vec::new();
    walk(root, 1, min, max, keep, &mut out);
    out
}

fn has_ext(p: &Path, ext: &str) -> bool {
    file_name_of(p)
        .to_ascii_lowercase()
        .ends_with(&format!(".{ext}"))
}

/// Sorted by level, then path, as `sort -t$'\t' -k1,1n -k2,2` does in the C locale.
fn by_level(mut v: Vec<(usize, PathBuf)>) -> Vec<PathBuf> {
    v.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then_with(|| a.1.as_os_str().cmp(b.1.as_os_str()))
    });
    v.into_iter().map(|(_, p)| p).collect()
}

fn contains_ci(hay: &[u8], needle: &str) -> bool {
    let n = needle.to_ascii_lowercase();
    let n = n.as_bytes();
    hay.len() >= n.len() && hay.windows(n.len()).any(|w| w.eq_ignore_ascii_case(n))
}

fn read(p: &Path) -> Vec<u8> {
    std::fs::read(p).unwrap_or_default()
}

/// A store's native Linux port: no .exe anywhere in the install, but Linux
/// programs (ELF files). Steam installs it by default for games that have
/// one, and nothing here can fix that build.
pub fn install_is_linux_build(root: &Path) -> bool {
    if !root.is_dir() {
        return false;
    }
    if !files_at(root, 1, 4, &|p| has_ext(p, "exe")).is_empty() {
        return false;
    }
    let candidates = files_at(root, 1, 4, &|p| {
        let exec = std::fs::metadata(p).is_ok_and(|m| m.permissions().mode() & 0o100 != 0);
        exec || file_name_of(p).contains(".so")
    });
    candidates.iter().take(200).any(|(_, p)| {
        let mut head = [0u8; 4];
        std::fs::File::open(p)
            .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut head))
            .is_ok()
            && head == *b"\x7fELF"
    })
}

// ---- the exe folder ---------------------------------------------------------

/// An .exe or .dll directly in `dir` that names an audio API, which tells
/// the engine's folder from a launcher's or a setup program's.
pub fn folder_names_audio_api(dir: &Path) -> bool {
    files_at(dir, 1, 1, &|p| has_ext(p, "exe") || has_ext(p, "dll"))
        .iter()
        .any(|(_, f)| {
            let lower = file_name_of(f).to_ascii_lowercase();
            if matches!(
                lower.as_str(),
                "dsound.dll" | "dsoal-aldrv.dll" | "openal32.dll"
            ) {
                return false;
            }
            let d = read(f);
            ["dsound.dll", "DirectSound", "OpenAL32.dll", "alcOpenDevice"]
                .iter()
                .any(|s| contains_ci(&d, s))
        })
}

/// The folders under an install root that hold the game's exe, best first,
/// each with the exe to show for it. `exe_hint` is the profile's exe name:
/// when it's there, its shallowest folder comes first, since it was checked
/// against a real install.
pub fn exe_candidates(root: &Path, exe_hint: &str) -> Vec<(PathBuf, String)> {
    let mut cands: Vec<(PathBuf, String)> = Vec::new();
    let has = |c: &Vec<(PathBuf, String)>, d: &Path| c.iter().any(|(x, _)| x == d);
    let root_norm = normalize_game_name(&file_name_of(root));

    let mut hinted = false;
    if !exe_hint.is_empty() {
        let hint = exe_hint.to_lowercase();
        let found = by_level(files_at(root, 1, 4, &|p| {
            file_name_of(p).to_lowercase() == hint
        }));
        if let Some(f) = found.first() {
            cands.push((f.parent().unwrap().to_path_buf(), file_name_of(f)));
            hinted = true;
        }
    }

    // The root itself, when it holds a real .exe: shown by one that isn't an
    // installer and resembles the folder's own name.
    let root_exes: Vec<PathBuf> = files_at(root, 1, 1, &|p| has_ext(p, "exe"))
        .into_iter()
        .map(|(_, p)| p)
        .collect();
    if !has(&cands, root) && !root_exes.is_empty() {
        let mut name = String::new();
        for f in root_exes.iter().filter(|f| !exe_is_junk(f)) {
            if name.is_empty() {
                name = file_name_of(f);
            }
            if exe_name_matches(&root_norm, f) {
                name = file_name_of(f);
                break;
            }
        }
        if name.is_empty() {
            name = file_name_of(&root_exes[0]);
        }
        cands.push((root.to_path_buf(), name));
    }

    // Nested folders, shallowest first, the ones whose exe resembles the
    // root's name ahead of the rest.
    let all = by_level(files_at(root, 2, 4, &|p| has_ext(p, "exe")));
    let mut chosen: Vec<PathBuf> = all.iter().filter(|f| !exe_is_junk(f)).cloned().collect();
    if chosen.is_empty() && cands.is_empty() {
        chosen = all;
    }
    let mut dirs: Vec<PathBuf> = Vec::new();
    for f in &chosen {
        let d = f.parent().unwrap().to_path_buf();
        if !dirs.contains(&d) {
            dirs.push(d);
        }
    }
    let (mut matched, mut rest) = (Vec::new(), Vec::new());
    for d in dirs {
        let mut name = String::new();
        let mut is_match = false;
        for f in chosen.iter().filter(|f| f.parent() == Some(d.as_path())) {
            if name.is_empty() {
                name = file_name_of(f);
            }
            if exe_name_matches(&root_norm, f) {
                is_match = true;
                name = file_name_of(f);
                break;
            }
        }
        if is_match {
            matched.push((d, name));
        } else {
            rest.push((d, name));
        }
    }
    for (d, name) in matched.into_iter().chain(rest) {
        if !has(&cands, &d) {
            cands.push((d, name));
        }
    }

    // A folder whose own files name an audio API is the engine's; one that
    // doesn't goes after. The profile's pick stays first.
    let keep = usize::from(hinted);
    let (head, tail) = cands.split_at(keep.min(cands.len()));
    let (audio, quiet): (Vec<_>, Vec<_>) = tail
        .iter()
        .cloned()
        .partition(|(d, _)| folder_names_audio_api(d));
    if !audio.is_empty() && !quiet.is_empty() {
        let mut out = head.to_vec();
        out.extend(audio);
        out.extend(quiet);
        return out;
    }
    cands
}

/// The profile's extra exe folders that exist: under the exe folder, or
/// with `game_root:` under the install root. One that's the exe folder
/// itself, or already listed, is left out.
pub fn extra_exe_folders(game_dir: &Path, install_root: &Path, list: &[String]) -> Vec<PathBuf> {
    let same = |a: &Path, b: &Path| match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    };
    let mut out: Vec<PathBuf> = Vec::new();
    for entry in list {
        let (base, rel) = match entry.strip_prefix("game_root:") {
            Some(r) => (install_root, r),
            None => (game_dir, entry.as_str()),
        };
        if rel.is_empty() || rel.starts_with('/') || rel.contains("..") || rel.contains('\\') {
            continue;
        }
        let Some(dir) = find_existing_variant(&base.join(rel)).filter(|d| d.is_dir()) else {
            continue;
        };
        if same(&dir, game_dir) || out.iter().any(|o| same(&dir, o)) {
            continue;
        }
        out.push(dir);
    }
    out
}

// ---- the audio API ----------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Api {
    OpenAl,
    DirectSound3d,
    /// Both named: a low-confidence DirectSound3D guess.
    Both,
}

impl Api {
    pub fn name(self) -> &'static str {
        match self {
            Api::OpenAl => "openal",
            Api::DirectSound3d => "directsound3d",
            Api::Both => "both",
        }
    }
}

/// What the game's files say, and the files that said it (relative to the
/// exe folder).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ApiEvidence {
    pub api: Api,
    pub ds_file: String,
    pub openal_file: String,
}

/// Reads the game's own .exe and .dll files for signs of each audio API,
/// ignoring case as Windows does: "dsound.dll" or "DirectSound", and
/// "OpenAL32.dll" or "alcOpenDevice". The profile's exe goes first, then the
/// exe folder's .exe files, its .dll files, then the subfolders'. A file
/// naming the DLL beats one only mentioning the API, and whatever the
/// profile's exe shows wins. An OpenAL32.dll is read for what it is:
/// Creative's router (or wrap_oal.dll) shipped with the game means OpenAL,
/// while OpenAL Soft is this program's own. This program's dsound.dll and
/// dsoal-aldrv.dll, and Aureal's A3D libraries, aren't evidence.
pub fn detect_api(game_dir: &Path, exe_hint: &str) -> Option<ApiEvidence> {
    let main = (!exe_hint.is_empty())
        .then(|| {
            let hint = exe_hint.to_lowercase();
            files_at(game_dir, 1, 1, &|p| file_name_of(p).to_lowercase() == hint)
                .into_iter()
                .next()
                .map(|(_, p)| p)
        })
        .flatten();
    let rel = |p: &Path| p.strip_prefix(game_dir).unwrap_or(p).display().to_string();
    let (mut ds_named, mut ds_mentioned, mut oal_named, mut oal_mentioned) =
        (String::new(), String::new(), String::new(), String::new());
    let (mut ds_main, mut oal_main, mut shipped) = (String::new(), String::new(), String::new());

    let mut passes: Vec<(bool, Vec<PathBuf>)> = Vec::new();
    if let Some(m) = &main {
        passes.push((true, vec![m.clone()]));
    }
    for level in [1, 2] {
        for ext in ["exe", "dll"] {
            let mut files: Vec<PathBuf> = files_at(game_dir, level, level, &|p| has_ext(p, ext))
                .into_iter()
                .map(|(_, p)| p)
                .collect();
            files.sort_by(|a, b| a.as_os_str().cmp(b.as_os_str()));
            passes.push((false, files));
        }
    }
    for (is_main, files) in passes {
        for f in files {
            let name = file_name_of(&f);
            if name == "dsound.dll" || name == "dsoal-aldrv.dll" {
                continue;
            }
            let lower = name.to_ascii_lowercase();
            if lower == "a3dapi.dll" || lower == "a3dsnd.dll" {
                continue;
            }
            if lower == "openal32.dll" {
                if !is_openal_soft_dll(&f) && shipped.is_empty() {
                    shipped = rel(&f);
                }
                continue;
            }
            if lower == "wrap_oal.dll" && shipped.is_empty() {
                shipped = rel(&f);
            }
            if !is_main && main.as_deref() == Some(f.as_path()) {
                continue;
            }
            let data = read(&f);
            if oal_named.is_empty() {
                if contains_ci(&data, "OpenAL32.dll") {
                    oal_named = rel(&f);
                } else if oal_mentioned.is_empty() && contains_ci(&data, "alcOpenDevice") {
                    oal_mentioned = rel(&f);
                }
            }
            if ds_named.is_empty() {
                if contains_ci(&data, "dsound.dll") {
                    ds_named = rel(&f);
                } else if ds_mentioned.is_empty() && contains_ci(&data, "DirectSound") {
                    ds_mentioned = rel(&f);
                }
            }
            if is_main {
                ds_main = if ds_named.is_empty() {
                    ds_mentioned.clone()
                } else {
                    ds_named.clone()
                };
                oal_main = if oal_named.is_empty() {
                    oal_mentioned.clone()
                } else {
                    oal_named.clone()
                };
            }
        }
    }
    let pick = |a: &str, b: &str, c: &str| {
        [a, b, c]
            .into_iter()
            .find(|s| !s.is_empty())
            .unwrap_or("")
            .to_string()
    };
    let ds = pick(&ds_main, &ds_named, &ds_mentioned);
    let mut oal = pick(&oal_main, &oal_named, &oal_mentioned);
    let api = match (oal.is_empty(), ds.is_empty()) {
        (false, false) if !shipped.is_empty() => {
            oal = shipped;
            Api::OpenAl
        }
        (false, false) => Api::Both,
        (false, true) => Api::OpenAl,
        (true, false) => Api::DirectSound3d,
        (true, true) => return None,
    };
    Some(ApiEvidence {
        api,
        ds_file: ds,
        openal_file: oal,
    })
}

// ---- Steam ------------------------------------------------------------------

/// The AppID whose appmanifest names this game folder's top-level folder
/// under steamapps/common (ignoring case), from the first manifest that does.
pub fn steam_appid_for_dir(game_dir: &Path) -> Option<String> {
    let text = game_dir.to_string_lossy();
    const COMMON: &str = "/steamapps/common/";
    let at = text.find(COMMON)?;
    let want = text[at + COMMON.len()..].split('/').next()?.to_lowercase();
    let steamapps = PathBuf::from(format!("{}/steamapps", &text[..at]));
    let mut acfs: Vec<PathBuf> = std::fs::read_dir(&steamapps)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let n = file_name_of(p);
            n.starts_with("appmanifest_") && n.ends_with(".acf")
        })
        .collect();
    acfs.sort();
    acfs.into_iter()
        .find(|acf| {
            std::fs::read_to_string(acf).is_ok_and(|t| {
                t.to_lowercase().lines().any(|l| {
                    l.find("\"installdir\"").is_some_and(|i| {
                        let rest = l[i + "\"installdir\"".len()..].trim_start();
                        rest.starts_with(&format!("\"{want}\""))
                    })
                })
            })
        })
        .map(|acf| {
            file_name_of(&acf)
                .chars()
                .filter(char::is_ascii_digit)
                .collect()
        })
}

/// A Steam companion app that's installed beside the game.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompanionApp {
    pub app_id: String,
    pub name: String,
    /// Its own Proton prefix; `None` until it has been launched once.
    pub prefix: Option<PathBuf>,
}

/// The profile's companion apps installed in the game's Steam library.
pub fn companion_apps(
    game: &Game,
    app_id: &str,
    game_dir: &Path,
    protontricks: &[String],
) -> Vec<CompanionApp> {
    let Some(steam) = &game.stores.steam else {
        return Vec::new();
    };
    let text = game_dir.to_string_lossy();
    let Some(at) = text.find("/steamapps/common/") else {
        return Vec::new();
    };
    let lib = PathBuf::from(format!("{}/steamapps", &text[..at]));
    steam
        .companion_apps
        .iter()
        .filter_map(|v| match v {
            Value::Number(n) => Some(n.to_string()),
            Value::String(s) => Some(s.clone()),
            _ => None,
        })
        .filter(|id| !id.is_empty() && id.bytes().all(|b| b.is_ascii_digit()) && id != app_id)
        .filter_map(|id| {
            let acf = lib.join(format!("appmanifest_{id}.acf"));
            let t = std::fs::read_to_string(&acf).ok()?;
            let name = acf_value(&t, "name")
                .filter(|n| !n.is_empty())
                .unwrap_or_else(|| format!("AppID {id}"));
            let prefix = wine::steam_prefix_for_appid(protontricks, &id);
            Some(CompanionApp {
                app_id: id,
                name,
                prefix,
            })
        })
        .collect()
}

// ---- Heroic -----------------------------------------------------------------

/// Where Heroic's prefix for a game came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrefixSource {
    /// The game's own GamesConfig winePrefix.
    Explicit,
    /// Heroic's global prefix, since the game has none of its own.
    Shared,
    /// A per-game default folder that exists.
    Default,
}

/// A game found in Heroic's library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeroicGame {
    pub prefix: Option<PathBuf>,
    pub source: Option<PrefixSource>,
    /// The GOG app name (a store ID); empty for a game added by hand, whose
    /// ID Heroic made up.
    pub gog_app: String,
    /// Heroic's own ID, for its GamesConfig file.
    pub id: String,
    pub title: String,
    /// The Heroic config folder (native or Flatpak) it was found in.
    pub root: PathBuf,
}

/// Every installed record in an installed.json: (install path, app name),
/// in jq's `..` order (an object before what's inside it).
fn installed_records(v: &Value, out: &mut Vec<(String, String)>) {
    let text = |o: &serde_json::Map<String, Value>, a: &str, b: &str| -> Option<String> {
        let pick = |k: &str| match o.get(k) {
            None | Some(Value::Null) | Some(Value::Bool(false)) => None,
            Some(Value::String(s)) => Some(s.clone()),
            Some(other) => Some(other.to_string()),
        };
        pick(a).or_else(|| pick(b))
    };
    match v {
        Value::Object(o) => {
            if let Some(path) = text(o, "install_path", "installPath") {
                out.push((path, text(o, "app_name", "appName").unwrap_or_default()));
            }
            o.values().for_each(|x| installed_records(x, out));
        }
        Value::Array(a) => a.iter().for_each(|x| installed_records(x, out)),
        _ => {}
    }
}

/// The first `"key": "value"` string in a Heroic file, read the way the
/// script does: Heroic writes one key per line.
fn json_value(file: &Path, key: &str) -> String {
    let Ok(text) = std::fs::read_to_string(file) else {
        return String::new();
    };
    let re = Regex::new(&format!(
        "\"{}\"[[:space:]]*:[[:space:]]*\"",
        regex::escape(key)
    ))
    .expect("compiles");
    text.lines()
        .find(|l| re.is_match(l))
        .and_then(|l| l.split('"').nth(3))
        .unwrap_or("")
        .to_string()
}

/// The folder name Heroic gives a game's default prefix: the title without
/// the characters its removeSpecialcharacters() drops.
pub fn heroic_prefix_name(title: &str) -> String {
    title
        .chars()
        .filter(|c| !":|/*?<>\\&{}%$@`!+'\"™®".contains(*c))
        .collect()
}

fn expand_home(p: &str, home: &Path) -> String {
    match p.strip_prefix('~') {
        Some(rest) => format!("{}{rest}", home.display()),
        None => p.to_string(),
    }
}

/// The game in one Heroic config folder: from its library (installed.json)
/// or the games added by hand (sideload_apps/library.json).
fn heroic_find(root: &Path, target: &str) -> Option<(String, String, String, bool)> {
    let mut found: Option<(String, String, String, bool)> = None;
    let mut jsons = Vec::new();
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() {
                walk(&e.path(), out);
            } else if t.is_file() && e.file_name() == "installed.json" {
                out.push(e.path());
            }
        }
    }
    walk(root, &mut jsons);
    for json in jsons {
        let mut recs = Vec::new();
        if let Some(v) = std::fs::read_to_string(&json)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        {
            installed_records(&v, &mut recs);
        }
        // The last matching record of a file, as the script's loop leaves it.
        for (path, app) in recs {
            if path.is_empty() {
                continue;
            }
            if target == path || target.starts_with(&format!("{path}/")) {
                found = Some((app.clone(), app, file_name_of(Path::new(&path)), false));
            }
        }
        if found.as_ref().is_some_and(|f| !f.0.is_empty()) {
            return found;
        }
    }
    // Added by hand: keyed by folder_name, or the executable's folder.
    let lib = root.join("sideload_apps/library.json");
    let v: Value = serde_json::from_str(&std::fs::read_to_string(&lib).ok()?).ok()?;
    let games: Vec<&Value> = match &v {
        Value::Object(o) => o
            .values()
            .flat_map(|x| x.as_array().into_iter().flatten())
            .collect(),
        Value::Array(a) => a.iter().collect(),
        _ => Vec::new(),
    };
    fn last_executable(v: &Value, out: &mut Option<String>) {
        match v {
            Value::Object(o) => {
                for (k, x) in o {
                    if k == "executable" {
                        if let Value::String(s) = x {
                            *out = Some(s.clone());
                        }
                    }
                    last_executable(x, out);
                }
            }
            Value::Array(a) => a.iter().for_each(|x| last_executable(x, out)),
            _ => {}
        }
    }
    for g in games {
        let get = |k: &str| g.get(k).and_then(Value::as_str).unwrap_or("").to_string();
        let app = get("app_name");
        if app.is_empty() {
            continue;
        }
        let mut folder = get("folder_name");
        if folder.is_empty() {
            let mut exe = None;
            last_executable(g, &mut exe);
            if let Some(e) = exe {
                folder = Path::new(&e)
                    .parent()
                    .map(|p| p.display().to_string())
                    .unwrap_or_default();
            }
        }
        if folder.is_empty() {
            continue;
        }
        if target == folder || target.starts_with(&format!("{folder}/")) {
            return Some((app, String::new(), get("title"), true));
        }
    }
    None
}

/// The prefix Heroic launches the game with: its own winePrefix, else
/// Heroic's shared one, else a per-game default folder that exists.
fn heroic_prefix(
    root: &Path,
    id: &str,
    title: &str,
    home: &Path,
) -> (Option<PathBuf>, Option<PrefixSource>) {
    let own = json_value(
        &root.join("GamesConfig").join(format!("{id}.json")),
        "winePrefix",
    );
    if !own.is_empty() {
        return (Some(PathBuf::from(own)), Some(PrefixSource::Explicit));
    }
    let config = root.join("config.json");
    let mut default_dir = json_value(&config, "defaultWinePrefixDir");
    if default_dir.is_empty() {
        default_dir = json_value(&config, "defaultWinePrefix");
    }
    let default_dir = expand_home(&default_dir, home);
    let global = expand_home(&json_value(&config, "winePrefix"), home);
    if !global.is_empty() {
        return (
            Some(PathBuf::from(global.trim_end_matches('/'))),
            Some(PrefixSource::Shared),
        );
    }
    if !default_dir.is_empty() {
        return (
            Some(PathBuf::from(format!(
                "{}/shared",
                default_dir.strip_suffix('/').unwrap_or(&default_dir)
            ))),
            Some(PrefixSource::Shared),
        );
    }
    let fp = home.join(".var/app/com.heroicgameslauncher.hgl/data/heroic/prefixes");
    let games = home.join("Games/Heroic/Prefixes");
    let named = heroic_prefix_name(title);
    let mut cands = Vec::new();
    if !title.is_empty() {
        cands.extend([games.join(&named), games.join("default").join(&named)]);
    }
    cands.extend([games.join(id), games.join("default").join(id)]);
    if !title.is_empty() {
        cands.extend([fp.join("default").join(&named), fp.join(&named)]);
    }
    match cands.into_iter().find(|c| c.is_dir()) {
        Some(c) => (Some(c), Some(PrefixSource::Default)),
        None => (None, None),
    }
}

/// Finds the game at `game_dir` in Heroic (native, then Flatpak) and the
/// prefix it launches it with. When both know it, the first with a prefix
/// wins.
pub fn heroic_game(game_dir: &Path, home: &Path) -> Option<HeroicGame> {
    let target = game_dir.to_string_lossy().into_owned();
    let mut found: Vec<HeroicGame> = Vec::new();
    for rel in [
        ".config/heroic",
        ".var/app/com.heroicgameslauncher.hgl/config/heroic",
    ] {
        let root = home.join(rel);
        if !root.is_dir() {
            continue;
        }
        let Some((id, gog, title, _)) = heroic_find(&root, &target) else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        let (prefix, source) = heroic_prefix(&root, &id, &title, home);
        found.push(HeroicGame {
            prefix,
            source,
            gog_app: gog,
            id,
            title,
            root,
        });
    }
    let pick = found.iter().position(|g| g.prefix.is_some()).unwrap_or(0);
    found.into_iter().nth(pick)
}

/// The game folder's own set of installed Heroic install paths, for working
/// out an install root.
pub fn heroic_install_paths(home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for json in heroic_installed_jsons(home) {
        let mut recs = Vec::new();
        if let Some(v) = std::fs::read_to_string(&json)
            .ok()
            .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        {
            installed_records(&v, &mut recs);
        }
        out.extend(recs.into_iter().map(|(p, _)| PathBuf::from(p)));
    }
    let mut seen = HashSet::new();
    out.retain(|p| seen.insert(p.clone()));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(normalize_game_name("Gothic II: Gold"), "gothic2gold");
        assert_eq!(normalize_game_name("X-COM Enforcer"), "xcomenforcer");
        assert_eq!(normalize_game_name("Final Fantasy VII"), "finalfantasy7");
        assert!(exe_is_junk(Path::new("/g/unins000.exe")));
        assert!(exe_is_junk(Path::new("/g/VC_redist.x86.exe")));
        assert!(!exe_is_junk(Path::new("/g/Game.exe")));
        assert_eq!(
            heroic_prefix_name("Baldur's Gate 2: Shadows"),
            "Baldurs Gate 2 Shadows"
        );
    }
}
