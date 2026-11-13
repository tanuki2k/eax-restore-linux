//! Which game a folder holds, from the store's own records in and around it:
//! a Steam appmanifest, a GOG `goggame-*.info`, Heroic's installed.json.
//! A port of `identify_game_dir` in `src/detection.sh`.

use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Store {
    Steam,
    Gog,
}

impl Store {
    /// The key under a game's `stores` in the database.
    pub fn key(self) -> &'static str {
        match self {
            Store::Steam => "steam",
            Store::Gog => "gog",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Identified {
    pub store: Store,
    /// The Steam AppID or the GOG game ID, as text.
    pub id: String,
    /// The store's name for the game; may be empty.
    pub name: String,
    /// The game's install root: steamapps/common/<Game>, or the GOG folder
    /// that holds the info file.
    pub root: PathBuf,
}

/// One top-level `"key" "value"` line from a Steam appmanifest.
pub fn acf_value(text: &str, key: &str) -> Option<String> {
    let want = format!("\"{key}\"");
    text.lines().find_map(|line| {
        let rest = line.trim_start().strip_prefix(&want)?;
        let rest = rest.trim_start().strip_prefix('"')?;
        Some(rest.trim_end().strip_suffix('"')?.to_string())
    })
}

fn steam(dir: &str) -> Option<Identified> {
    const COMMON: &str = "/steamapps/common/";
    let at = dir.find(COMMON)?;
    let want = dir[at + COMMON.len()..].split('/').next()?;
    let steamapps = format!("{}/steamapps", &dir[..at]);
    let mut manifests: Vec<PathBuf> = std::fs::read_dir(&steamapps)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default();
            name.starts_with("appmanifest_") && name.ends_with(".acf") && p.is_file()
        })
        .collect();
    // The order the shell's glob lists them in.
    manifests.sort();
    manifests.into_iter().find_map(|acf| {
        let text = std::fs::read_to_string(&acf).ok()?;
        if acf_value(&text, "installdir")? != want {
            return None;
        }
        let file = acf.file_name()?.to_string_lossy().into_owned();
        Some(Identified {
            store: Store::Steam,
            id: file.chars().filter(char::is_ascii_digit).collect(),
            name: acf_value(&text, "name").unwrap_or_default(),
            root: PathBuf::from(format!("{steamapps}/common/{want}")),
        })
    })
}

fn json_text(v: &Value, key: &str) -> String {
    match v.get(key) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        // jq's `.x // empty` drops false as well as null.
        Some(Value::Bool(true)) => "true".into(),
        _ => String::new(),
    }
}

/// Every installed.json under a Heroic config folder (native, then Flatpak).
pub fn heroic_installed_jsons(home: &Path) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        let mut entries: Vec<_> = entries.flatten().collect();
        entries.sort_by_key(|e| e.file_name());
        for e in entries {
            let Ok(t) = e.file_type() else { continue };
            if t.is_dir() {
                walk(&e.path(), out);
            } else if t.is_file() && e.file_name() == "installed.json" {
                out.push(e.path());
            }
        }
    }
    let mut out = Vec::new();
    for root in [
        ".config/heroic",
        ".var/app/com.heroicgameslauncher.hgl/config/heroic",
    ] {
        walk(&home.join(root), &mut out);
    }
    out
}

/// Heroic's appName for the install at `dir`: its own record wins over the
/// info file, since a few info files carry another ID (Fallout Tactics'
/// says 3).
fn heroic_app_name(home: &Path, dir: &str) -> Option<String> {
    heroic_installed_jsons(home).iter().find_map(|json| {
        let v: Value = serde_json::from_str(&std::fs::read_to_string(json).ok()?).ok()?;
        let installed = v.get("installed")?;
        // jq's `.installed[]?` walks an object's values as well as a list.
        let records: Vec<&Value> = match installed {
            Value::Array(a) => a.iter().collect(),
            Value::Object(o) => o.values().collect(),
            _ => Vec::new(),
        };
        records.into_iter().find_map(|rec| {
            let path = rec
                .get("install_path")
                .and_then(Value::as_str)
                .unwrap_or("");
            (path.strip_suffix('/').unwrap_or(path) == dir)
                .then(|| json_text(rec, "appName"))
                .filter(|a| !a.is_empty())
        })
    })
}

fn gog(dir: &str, home: &Path) -> Option<Identified> {
    let home_text = home.to_string_lossy();
    let mut dir = dir.to_string();
    for _ in 0..=3 {
        if dir.is_empty() || dir == home_text || dir == "/" {
            break;
        }
        let mut infos: Vec<PathBuf> = std::fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                let name = p
                    .file_name()
                    .map(|n| n.to_string_lossy())
                    .unwrap_or_default();
                name.starts_with("goggame-") && name.ends_with(".info") && p.is_file()
            })
            .collect();
        infos.sort();
        let (mut id, mut name) = (String::new(), String::new());
        for info in infos {
            let v: Value = std::fs::read_to_string(&info)
                .ok()
                .and_then(|t| serde_json::from_str(&t).ok())
                .unwrap_or(Value::Null);
            // The base game's file (its gameId is its rootGameId) wins over a
            // DLC's; failing that, the first one. As in the script's jq, two
            // missing IDs count as equal, and stop the search empty-handed.
            let root_id = match v.as_object() {
                Some(o) if o.get("gameId") == o.get("rootGameId") => match o.get("gameId") {
                    None | Some(Value::Null) => "null".to_string(),
                    Some(Value::String(s)) => s.clone(),
                    Some(other) => other.to_string(),
                },
                _ => String::new(),
            };
            if !root_id.is_empty() || id.is_empty() {
                id = json_text(&v, "gameId");
                name = json_text(&v, "name");
            }
            if !root_id.is_empty() {
                break;
            }
        }
        if !id.is_empty() {
            let id = heroic_app_name(home, &dir).unwrap_or(id);
            return Some(Identified {
                store: Store::Gog,
                id,
                name,
                root: PathBuf::from(dir),
            });
        }
        match dir.rfind('/') {
            Some(p) => dir.truncate(p),
            None => break,
        }
    }
    None
}

/// The game in `dir` (an exe folder), looking up to three folders above it
/// for a GOG install. `home` is where Heroic's config lives.
pub fn identify_game_dir(dir: &Path, home: &Path) -> Option<Identified> {
    let text = dir.to_string_lossy();
    let dir = text.strip_suffix('/').unwrap_or(&text);
    if dir.contains("/steamapps/common/") {
        if let Some(found) = steam(dir) {
            return Some(found);
        }
    }
    gog(dir, home)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn acf_values() {
        let acf = "\"AppState\"\n{\n\t\"appid\"\t\t\"2210\"\n\t\"name\"\t\t\"Quake 4\"\n\t\"installdir\"\t\t\"Quake 4\"\n}\n";
        assert_eq!(acf_value(acf, "name").as_deref(), Some("Quake 4"));
        assert_eq!(acf_value(acf, "installdir").as_deref(), Some("Quake 4"));
        assert_eq!(acf_value(acf, "nope"), None);
        assert_eq!(acf_value("\"name\"\"x\"", "name").as_deref(), Some("x"));
    }
}
