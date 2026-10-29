//! Loads `game-database.json`. Only reads the fields the list and profile pane
//! need; unknown fields are ignored so a newer database still loads.

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Clone, Deserialize)]
pub struct Database {
    pub games: Vec<Game>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Game {
    pub id: String,
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
    #[serde(default)]
    pub tested: bool,
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
    pub store_details: String,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Eax {
    #[serde(default)]
    pub api: String,
    #[serde(default)]
    pub versions: Vec<String>,
}

impl Database {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading {}", path.display()))?;
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
        assert!(!db.games[0].tested);
    }

    #[test]
    fn the_shipped_database_loads() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../game-database.json");
        let db = Database::load(&path).unwrap();
        assert!(db.games.len() > 50);
    }
}
