//! The browser's store, audio and tested filters. They work the way the Bash
//! browser's did: per store entry, with the store's own `delisted` flag and API.

use crate::games::Entry;
use crate::library::StoreKind;

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum StoreFilter {
    #[default]
    All,
    Steam,
    Gog,
    Delisted,
    SteamDelisted,
    GogDelisted,
}

impl StoreFilter {
    pub fn label(self) -> &'static str {
        match self {
            StoreFilter::All => "All stores",
            StoreFilter::Steam => "Steam",
            StoreFilter::Gog => "GOG",
            StoreFilter::Delisted => "Delisted",
            StoreFilter::SteamDelisted => "Delisted on Steam",
            StoreFilter::GogDelisted => "Delisted on GOG",
        }
    }

    fn next(self) -> Self {
        match self {
            StoreFilter::All => StoreFilter::Steam,
            StoreFilter::Steam => StoreFilter::Gog,
            StoreFilter::Gog => StoreFilter::Delisted,
            StoreFilter::Delisted => StoreFilter::SteamDelisted,
            StoreFilter::SteamDelisted => StoreFilter::GogDelisted,
            StoreFilter::GogDelisted => StoreFilter::All,
        }
    }

    /// `key` is None for a game with no store entry at all.
    fn allows(self, key: Option<StoreKind>, delisted: bool) -> bool {
        match self {
            StoreFilter::All => true,
            StoreFilter::Steam => key == Some(StoreKind::Steam),
            StoreFilter::Gog => key == Some(StoreKind::Gog),
            StoreFilter::Delisted => key.is_some() && delisted,
            StoreFilter::SteamDelisted => key == Some(StoreKind::Steam) && delisted,
            StoreFilter::GogDelisted => key == Some(StoreKind::Gog) && delisted,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum AudioFilter {
    #[default]
    All,
    DirectSound3d,
    OpenAl,
    /// A game whose profile lists this EAX version (1 to 5).
    Eax(u8),
}

impl AudioFilter {
    pub fn label(self) -> String {
        match self {
            AudioFilter::All => "Any audio".into(),
            AudioFilter::DirectSound3d => "DirectSound3D".into(),
            AudioFilter::OpenAl => "OpenAL".into(),
            AudioFilter::Eax(n) => format!("EAX {n}.0"),
        }
    }

    fn next(self) -> Self {
        match self {
            AudioFilter::All => AudioFilter::DirectSound3d,
            AudioFilter::DirectSound3d => AudioFilter::OpenAl,
            AudioFilter::OpenAl => AudioFilter::Eax(1),
            AudioFilter::Eax(5) => AudioFilter::All,
            AudioFilter::Eax(n) => AudioFilter::Eax(n + 1),
        }
    }

    fn allows(self, api: &str, versions: &[String]) -> bool {
        match self {
            AudioFilter::All => true,
            AudioFilter::DirectSound3d => api == "directsound3d",
            AudioFilter::OpenAl => api == "openal",
            AudioFilter::Eax(n) => versions.iter().any(|v| *v == format!("{n}.0")),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum TestedFilter {
    #[default]
    All,
    Tested,
    Untested,
}

impl TestedFilter {
    pub fn label(self) -> &'static str {
        match self {
            TestedFilter::All => "Any",
            TestedFilter::Tested => "Yes",
            TestedFilter::Untested => "Not yet",
        }
    }

    fn next(self) -> Self {
        match self {
            TestedFilter::All => TestedFilter::Tested,
            TestedFilter::Tested => TestedFilter::Untested,
            TestedFilter::Untested => TestedFilter::All,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub struct Filters {
    pub store: StoreFilter,
    pub audio: AudioFilter,
    pub tested: TestedFilter,
}

impl Filters {
    pub fn next_store(&mut self) {
        self.store = self.store.next();
    }

    pub fn next_audio(&mut self) {
        self.audio = self.audio.next();
    }

    pub fn next_tested(&mut self) {
        self.tested = self.tested.next();
    }

    pub fn passes(&self, e: &Entry) -> bool {
        // A game the database doesn't list has no store, API or tested flag.
        let Some(g) = &e.game else {
            return *self == Filters::default();
        };
        match self.tested {
            TestedFilter::All => {}
            TestedFilter::Tested if !g.tested => return false,
            TestedFilter::Untested if g.tested => return false,
            _ => {}
        }
        let game_api = if g.eax.api.is_empty() {
            "directsound3d"
        } else {
            g.eax.api.as_str()
        };
        // A copy whose store is known is that store's alone, even when the game is
        // sold on both; a game not on this PC is every store that sells it.
        let mut candidates: Vec<(Option<StoreKind>, bool, &str)> = [
            (StoreKind::Steam, &g.stores.steam),
            (StoreKind::Gog, &g.stores.gog),
        ]
        .into_iter()
        .filter(|(k, _)| e.store.is_none() || e.store == Some(*k))
        .filter_map(|(k, s)| {
            s.as_ref()
                .map(|s| (Some(k), s.delisted, s.api.as_deref().unwrap_or(game_api)))
        })
        .collect();
        if candidates.is_empty() {
            candidates.push((e.store, false, game_api));
        }
        candidates.iter().any(|&(k, delisted, api)| {
            self.store.allows(k, delisted) && self.audio.allows(api, &g.eax.versions)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    fn entry(json: &str) -> Entry {
        let db = Database::parse(&format!(r#"{{"games":[{json}]}}"#)).unwrap();
        Entry::database_only(db.games[0].clone())
    }

    fn with(f: impl FnOnce(&mut Filters)) -> Filters {
        let mut x = Filters::default();
        f(&mut x);
        x
    }

    const BOTH: &str = r#"{"id":"a","name":"A","tested":false,
        "stores":{"steam":{"id":1,"delisted":true},"gog":{"id":2,"api":"openal"}},
        "eax":{"api":"directsound3d","versions":["1.0","3.0"]}}"#;

    #[test]
    fn the_defaults_let_everything_through() {
        assert!(Filters::default().passes(&entry(BOTH)));
        assert!(Filters::default().passes(&entry(r#"{"id":"a","name":"A"}"#)));
    }

    #[test]
    fn a_missing_tested_field_counts_as_tested() {
        let e = entry(r#"{"id":"a","name":"A"}"#);
        assert!(with(|f| f.tested = TestedFilter::Tested).passes(&e));
        assert!(!with(|f| f.tested = TestedFilter::Untested).passes(&e));
        let u = entry(BOTH);
        assert!(with(|f| f.tested = TestedFilter::Untested).passes(&u));
    }

    #[test]
    fn delisted_is_the_stores_own_flag() {
        let e = entry(BOTH);
        assert!(with(|f| f.store = StoreFilter::SteamDelisted).passes(&e));
        assert!(!with(|f| f.store = StoreFilter::GogDelisted).passes(&e));
        assert!(with(|f| f.store = StoreFilter::Delisted).passes(&e));
        assert!(with(|f| f.store = StoreFilter::Gog).passes(&e));
    }

    #[test]
    fn a_store_can_override_the_games_api() {
        let e = entry(BOTH);
        assert!(with(|f| f.audio = AudioFilter::OpenAl).passes(&e)); // via GOG
        assert!(with(|f| f.audio = AudioFilter::DirectSound3d).passes(&e)); // via Steam
                                                                            // Together they must hold for one store: Steam is not OpenAL.
        let both = with(|f| {
            f.store = StoreFilter::Steam;
            f.audio = AudioFilter::OpenAl;
        });
        assert!(!both.passes(&e));
    }

    #[test]
    fn eax_versions_come_from_the_profile() {
        let e = entry(BOTH);
        assert!(with(|f| f.audio = AudioFilter::Eax(3)).passes(&e));
        assert!(!with(|f| f.audio = AudioFilter::Eax(2)).passes(&e));
    }

    #[test]
    fn a_game_the_database_lacks_only_shows_with_no_filters_set() {
        let mut e = entry(BOTH);
        e.game = None;
        assert!(Filters::default().passes(&e));
        assert!(!with(|f| f.store = StoreFilter::Steam).passes(&e));
        assert!(!with(|f| f.tested = TestedFilter::Tested).passes(&e));
    }

    #[test]
    fn every_filter_cycles_back_to_where_it_started() {
        let mut f = Filters::default();
        for _ in 0..6 {
            f.next_store();
        }
        for _ in 0..8 {
            f.next_audio();
        }
        for _ in 0..3 {
            f.next_tested();
        }
        assert_eq!(f, Filters::default());
        assert_eq!(AudioFilter::Eax(5).next(), AudioFilter::All);
    }

    fn copy(store: Option<StoreKind>) -> Entry {
        let mut e = entry(BOTH);
        e.store = store;
        e
    }

    #[test]
    fn an_installed_copy_belongs_to_the_store_it_came_from() {
        let (steam, gog) = (copy(Some(StoreKind::Steam)), copy(Some(StoreKind::Gog)));
        let on_steam = with(|f| f.store = StoreFilter::Steam);
        let on_gog = with(|f| f.store = StoreFilter::Gog);
        assert!(on_steam.passes(&steam) && !on_steam.passes(&gog));
        assert!(on_gog.passes(&gog) && !on_gog.passes(&steam));
    }

    #[test]
    fn a_copy_of_unknown_origin_and_a_game_not_here_match_every_store_that_sells_them() {
        let unknown = copy(None);
        assert!(with(|f| f.store = StoreFilter::Steam).passes(&unknown));
        assert!(with(|f| f.store = StoreFilter::Gog).passes(&unknown));
    }

    #[test]
    fn every_copy_is_listed_when_no_store_is_chosen() {
        for store in [None, Some(StoreKind::Steam), Some(StoreKind::Gog)] {
            assert!(Filters::default().passes(&copy(store)));
        }
    }

    #[test]
    fn a_copys_own_store_decides_delisted_and_the_audio_api() {
        // BOTH: Steam is delisted; GOG has its own OpenAL api.
        let (steam, gog) = (copy(Some(StoreKind::Steam)), copy(Some(StoreKind::Gog)));
        let delisted = with(|f| f.store = StoreFilter::Delisted);
        assert!(delisted.passes(&steam) && !delisted.passes(&gog));
        let openal = with(|f| f.audio = AudioFilter::OpenAl);
        assert!(openal.passes(&gog) && !openal.passes(&steam));
    }
}
