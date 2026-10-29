//! Loads `game-database.json`. Only reads the fields the list, the profile pane
//! and the settings view need; unknown fields are ignored so a newer database
//! still loads.

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct Database {
    pub games: Vec<Game>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Game {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub released: String,
    #[serde(default)]
    pub exe: String,
    #[serde(default)]
    pub stores: Stores,
    #[serde(default)]
    pub eax: Eax,
    /// Absent means checked on a real install; only `false` is untested.
    #[serde(default = "yes")]
    pub tested: bool,
    #[serde(default)]
    pub install: Install,
    #[serde(default)]
    pub game_config: GameConfig,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Stores {
    pub steam: Option<Store>,
    pub gog: Option<Store>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Store {
    pub id: u64,
    #[serde(default)]
    pub delisted: bool,
    /// This store's own audio API, when it differs from the game's.
    pub api: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Eax {
    #[serde(default)]
    pub api: String,
    #[serde(default)]
    pub versions: Vec<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Install {
    /// section -> key -> value, in the database's order.
    pub alsoft_ini: Option<Map<String, Value>>,
    pub alsoft_tested: Option<bool>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct GameConfig {
    #[serde(default)]
    pub files: BTreeMap<String, ConfigFile>,
    #[serde(default)]
    pub audio_settings: Vec<Setting>,
    #[serde(default)]
    pub optional_settings: Vec<Setting>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct ConfigFile {
    #[serde(default)]
    pub format: String,
    /// `game_exe:q4base/Quake4Config.cfg`: where it is, then the path there.
    #[serde(default)]
    pub locations: Vec<String>,
    /// Every listed location is changed, not just the first that exists.
    #[serde(default)]
    pub all_locations: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Setting {
    pub title: String,
    #[serde(default)]
    pub reason: String,
    pub only_if: Option<OnlyIf>,
    /// file -> what to set there. The shape under a file depends on its
    /// format (section -> key -> value for ini-like files, else key -> value).
    #[serde(default)]
    pub changes: Map<String, Value>,
    pub follow_up: Option<String>,
    /// Only `true` counts as checked; a setting without the flag is untested.
    #[serde(default)]
    pub tested: bool,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct OnlyIf {
    /// A list of store names.
    pub stores: Option<Value>,
    /// One speaker layout or a list of them.
    pub speakers: Option<Value>,
}

impl OnlyIf {
    /// A string or a list of strings, as a list.
    pub fn list(v: &Option<Value>) -> Vec<String> {
        match v {
            Some(Value::String(s)) => vec![s.clone()],
            Some(Value::Array(a)) => a
                .iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect(),
            _ => Vec::new(),
        }
    }
}

impl Database {
    pub fn load(path: &Path) -> Result<Self> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        Self::parse(&text).with_context(|| format!("parsing {}", path.display()))
    }

    pub fn parse(text: &str) -> Result<Self> {
        Ok(serde_json::from_str(text)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_a_game_and_ignores_unknown_fields() {
        let db = Database::parse(
            r#"{"schema_version":3,"games":[{"id":"a","name":"A","future":1,
            "stores":{"steam":{"id":5}},"eax":{"api":"openal","versions":["2.0"]}}]}"#,
        )
        .unwrap();
        assert_eq!(db.games[0].stores.steam.as_ref().unwrap().id, 5);
        assert!(db.games[0].stores.gog.is_none());
        assert!(db.games[0].tested, "a missing flag means tested");
        let db = Database::parse(r#"{"games":[{"id":"a","name":"A","tested":false}]}"#).unwrap();
        assert!(!db.games[0].tested);
    }

    #[test]
    fn the_shipped_database_loads() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../game-database.json");
        let db = Database::load(&path).unwrap();
        assert!(db.games.len() > 50);
    }
}
