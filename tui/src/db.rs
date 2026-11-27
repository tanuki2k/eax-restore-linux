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
    /// The game's file name in the database (`deus-ex`), which the build adds.
    #[serde(default)]
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
    /// The game's own compatibility as its file sets it; each store's,
    /// worked out by the build, is under `stores`. See [`Game::compat`].
    pub compatibility: Option<String>,
    /// Before the compatibility field: absent meant checked on a real
    /// install, `false` not yet. Only read to upgrade an older database.
    #[serde(default = "yes")]
    pub(crate) tested: bool,
    #[serde(default)]
    pub notes: String,
    #[serde(default)]
    pub sources: Vec<Source>,
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
    /// Where the id came from, e.g. `steamdb_historical` for one not checked on an install.
    pub id_source: Option<String>,
    #[serde(default)]
    pub store_details: String,
    #[serde(default)]
    pub patches: String,
    /// This store's own audio API, when it differs from the game's.
    pub api: Option<String>,
    /// More exe folders that need the same files (`game_root:` for one
    /// beside the exe folder rather than under it).
    #[serde(default)]
    pub extra_exe_folders: Vec<String>,
    /// Steam apps that run the game's exe from its folder with a prefix of
    /// their own (DOOM 3's Resurrection of Evil).
    #[serde(default)]
    pub companion_apps: Vec<Value>,
    /// The Steam beta branch that keeps EAX, for a build a patch took it out of.
    #[serde(default)]
    pub beta_branch: String,
    /// GOG build IDs (`goggame-<id>.info`'s buildId) that keep EAX: an
    /// install on one has already rolled back.
    #[serde(default)]
    pub rollback_builds: Vec<String>,
    /// This store's own steps to roll back to a build with EAX, in place of
    /// `eax.fix`.
    #[serde(default)]
    pub rollback_steps: String,
    /// `verified`, `playable`, `unsupported` or `unknown`, as the build works
    /// it out for this store.
    pub compatibility: Option<String>,
    /// This store's problem text, else the game's (`eax.problem`).
    pub problem: Option<String>,
}

impl Store {
    /// The store can roll back to a build that keeps EAX, so the current
    /// one has none: an install waits until the game is on that build.
    pub fn has_rollback(&self) -> bool {
        !self.beta_branch.is_empty() || !self.rollback_builds.is_empty()
    }
}

/// How well EAX works with the fix: a game's rating, like a store's
/// compatibility rating.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Compat {
    /// Checked on a real install; EAX works without problems.
    Verified,
    /// EAX works, but something sounds wrong with it restored.
    Playable,
    /// The fix can't restore EAX on this build, so there's no install.
    Unsupported,
    /// Nobody has checked it yet.
    Unknown,
}

impl Compat {
    pub fn parse(s: &str) -> Self {
        match s {
            "verified" => Compat::Verified,
            "playable" => Compat::Playable,
            "unsupported" => Compat::Unsupported,
            _ => Compat::Unknown,
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Compat::Verified => "Verified",
            Compat::Playable => "Playable",
            Compat::Unsupported => "Unsupported",
            Compat::Unknown => "Unknown",
        }
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Eax {
    #[serde(default)]
    pub api: String,
    #[serde(default)]
    pub versions: Vec<String>,
    /// The audio middleware the game is built on: `miles`, or absent.
    pub sound_system: Option<String>,
    /// EAX already works in this build without the fix, so an install asks first.
    #[serde(default)]
    pub built_in: bool,
    /// What's wrong: what sounds wrong (playable), why there's no EAX
    /// (unsupported), or a known limitation.
    #[serde(default)]
    pub problem: String,
    /// Extra steps the player takes to get EAX back.
    #[serde(default)]
    pub fix: String,
    /// Before the compatibility field: `supported`, `built_in`,
    /// `not_implemented` or `removed_by_patch`. Only read to upgrade an
    /// older database, as is `fix_in_place`.
    #[serde(default)]
    pub(crate) status: String,
    #[serde(default)]
    pub(crate) fix_in_place: bool,
}

impl Game {
    /// The block under `stores` for a database store key ("steam", "gog").
    pub fn store(&self, key: Option<&str>) -> Option<&Store> {
        match key? {
            "steam" => self.stores.steam.as_ref(),
            "gog" => self.stores.gog.as_ref(),
            _ => None,
        }
    }

    /// How to get back to a build with EAX on this store: its own `fix`, else
    /// the game's. No store (a retail copy) takes the game's.
    pub fn fix(&self, store: Option<&str>) -> &str {
        self.store(store)
            .map(|s| s.rollback_steps.as_str())
            .filter(|f| !f.is_empty())
            .unwrap_or(&self.eax.fix)
    }

    /// The stores the game is sold on, Steam's first, with their keys.
    pub fn store_list(&self) -> Vec<(&'static str, &Store)> {
        [("steam", &self.stores.steam), ("gog", &self.stores.gog)]
            .into_iter()
            .filter_map(|(k, s)| s.as_ref().map(|s| (k, s)))
            .collect()
    }

    /// This store's compatibility. With no store (a retail copy), the
    /// game's own, else the one its stores share, else unknown.
    pub fn compat(&self, store: Option<&str>) -> Compat {
        let of = |s: &Store| Compat::parse(s.compatibility.as_deref().unwrap_or(""));
        if let Some(s) = self.store(store) {
            return of(s);
        }
        if let Some(c) = &self.compatibility {
            return Compat::parse(c);
        }
        let all: Vec<Compat> = self.store_list().into_iter().map(|(_, s)| of(s)).collect();
        match all.first() {
            Some(c) if all.iter().all(|x| x == c) => *c,
            _ => Compat::Unknown,
        }
    }

    /// Someone has rated at least one of its stores.
    pub fn rated(&self) -> bool {
        self.store_list()
            .iter()
            .any(|(k, _)| self.compat(Some(k)) != Compat::Unknown)
    }

    /// This store's problem text, else the game's.
    pub fn problem(&self, store: Option<&str>) -> &str {
        self.store(store)
            .and_then(|s| s.problem.as_deref())
            .filter(|p| !p.is_empty())
            .unwrap_or(&self.eax.problem)
    }

    /// The store can roll back to a build with EAX (see [`Store::has_rollback`]).
    pub fn has_rollback(&self, store: Option<&str>) -> bool {
        self.store(store).is_some_and(Store::has_rollback)
    }

    /// Nothing for an install to restore on this store's copy: it's
    /// unsupported. The script's `block_if_eax_not_implemented` rule.
    pub fn none_to_restore(&self, store: Option<&str>) -> bool {
        self.compat(store) == Compat::Unsupported
    }

    /// Fills in the compatibility fields for a database built before them,
    /// from the fields it had, as the script's GDB_UPGRADE_JQ does.
    fn upgrade(&mut self) {
        let legacy = self.compatibility.is_none()
            && self
                .store_list()
                .iter()
                .all(|(_, s)| s.compatibility.is_none());
        if self.eax.status == "built_in" {
            self.eax.built_in = true;
        }
        if self.install.alsoft_tested == Some(true) && self.install.alsoft_verified.is_none() {
            self.install.alsoft_verified = Some(true);
        }
        for s in self
            .game_config
            .audio_settings
            .iter_mut()
            .chain(self.game_config.optional_settings.iter_mut())
        {
            s.verified |= s.tested;
        }
        if !legacy {
            return;
        }
        let status = self.eax.status.as_str();
        let c = if status == "not_implemented"
            || (status == "removed_by_patch" && !self.eax.fix_in_place)
        {
            "unsupported"
        } else if !self.tested {
            "unknown"
        } else {
            "verified"
        };
        for s in [&mut self.stores.steam, &mut self.stores.gog]
            .into_iter()
            .flatten()
        {
            s.compatibility = Some(c.to_string());
        }
        // For a game with no store entry (and a copy found without one).
        self.compatibility = Some(c.to_string());
    }
}

/// A page behind the entry's claims: a bare address, or a titled one.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum Source {
    Url(String),
    Page { title: String, url: String },
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Install {
    /// section -> key -> value, in the database's order.
    pub alsoft_ini: Option<Map<String, Value>>,
    /// Only `Some(true)` counts as checked on a real install.
    pub alsoft_verified: Option<bool>,
    /// The name `alsoft_verified` had before; only read to upgrade.
    pub(crate) alsoft_tested: Option<bool>,
    /// Named fixes, such as `eax_unified`.
    #[serde(default)]
    pub tweaks: Vec<String>,
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
    /// `skip` or `create` when no location exists; empty means the game
    /// writes the file on its first run.
    #[serde(default)]
    pub if_missing: String,
    /// A file the game keeps beside this one while it runs; left behind, the
    /// game resets this file on its next start.
    #[serde(default)]
    pub crash_marker: String,
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
    /// Only `true` counts as checked; a setting without the flag is unverified.
    #[serde(default)]
    pub verified: bool,
    /// The name `verified` had before; only read to upgrade.
    #[serde(default)]
    pub(crate) tested: bool,
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
        let mut db: Self = serde_json::from_str(text)?;
        db.games.iter_mut().for_each(Game::upgrade);
        Ok(db)
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
    }

    #[test]
    fn each_store_has_its_own_compatibility_and_problem() {
        let db = Database::parse(
            r#"{"games":[{"id":"a","name":"A","compatibility":"verified","eax":{"problem":"Game text."},
            "stores":{"steam":{"id":1,"compatibility":"verified","problem":"Game text.","beta_branch":"old"},
                      "gog":{"id":2,"compatibility":"playable","problem":"GOG text."}}}]}"#,
        )
        .unwrap();
        let g = &db.games[0];
        assert_eq!(g.compat(Some("steam")), Compat::Verified);
        assert_eq!(g.compat(Some("gog")), Compat::Playable);
        assert_eq!(
            g.compat(None),
            Compat::Verified,
            "a retail copy takes the game's own"
        );
        assert_eq!(g.problem(Some("gog")), "GOG text.");
        assert!(g.has_rollback(Some("steam")) && !g.has_rollback(Some("gog")));
        assert!(g.rated());
    }

    #[test]
    fn an_older_database_gets_its_compatibility_worked_out() {
        let db = Database::parse(
            r#"{"games":[
            {"id":"a","name":"A","stores":{"steam":{"id":1}},
             "game_config":{"audio_settings":[{"title":"T","tested":true}]},"install":{"alsoft_tested":true}},
            {"id":"b","name":"B","tested":false,"stores":{"steam":{"id":2}}},
            {"id":"c","name":"C","stores":{"gog":{"id":3}},"eax":{"status":"not_implemented"}},
            {"id":"d","name":"D","stores":{"steam":{"id":4,"beta_branch":"old"}},"eax":{"status":"removed_by_patch","fix_in_place":true}},
            {"id":"e","name":"E","stores":{"steam":{"id":5}},"eax":{"status":"built_in"}}]}"#,
        )
        .unwrap();
        let c: Vec<Compat> = db.games.iter().map(|g| g.compat(None)).collect();
        use Compat::*;
        assert_eq!(c, [Verified, Unknown, Unsupported, Verified, Verified]);
        assert!(db.games[0].game_config.audio_settings[0].verified);
        assert_eq!(db.games[0].install.alsoft_verified, Some(true));
        assert!(db.games[2].none_to_restore(Some("gog")));
        assert!(
            !db.games[3].none_to_restore(Some("steam")) && db.games[3].has_rollback(Some("steam"))
        );
        assert!(db.games[4].eax.built_in);
        assert!(!db.games[1].rated());
    }

    #[test]
    fn the_shipped_database_loads() {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../game-database.json");
        let db = Database::load(&path).unwrap();
        assert!(db.games.len() > 50);
    }
}
