//! What narrows and orders the games list: the view (the bar along the top),
//! the Filters pop-up's tick boxes, and the sort order (a column's letter). The tick boxes work
//! per store entry, as the Bash browser's filters did, with each store's own
//! rating, `delisted` flag and API: within a group a game needs any ticked box,
//! across groups every group, and a group with nothing ticked lets all through.

use crate::db::Compat;
use crate::games::{Entry, Status};
use crate::library::StoreKind;
use std::collections::BTreeSet;

/// The bar along the top: which games the list holds before any filter.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum View {
    #[default]
    All,
    /// Games found on this PC.
    MyLibrary,
    /// Games with the EAX fix installed.
    Patched,
    /// Games the player starred with F4.
    Favorites,
}

impl View {
    pub const ALL: [View; 4] = [View::All, View::MyLibrary, View::Patched, View::Favorites];

    pub fn label(self) -> &'static str {
        match self {
            View::All => "All games",
            View::MyLibrary => "My library",
            View::Patched => "Patched",
            View::Favorites => "Favorites",
        }
    }

    pub fn next(self) -> Self {
        let i = View::ALL.iter().position(|v| *v == self).unwrap_or(0);
        View::ALL[(i + 1) % View::ALL.len()]
    }

    pub fn prev(self) -> Self {
        let i = View::ALL.iter().position(|v| *v == self).unwrap_or(0);
        View::ALL[(i + View::ALL.len() - 1) % View::ALL.len()]
    }

    pub fn allows(self, e: &Entry, favorite: bool) -> bool {
        match self {
            View::All => true,
            View::MyLibrary => e.status != Status::NotOnThisPc,
            View::Patched => matches!(e.status, Status::Installed | Status::Manual),
            View::Favorites => favorite,
        }
    }
}

/// A column of the games table, which the list can be sorted by: its first
/// letter sorts by it.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum Column {
    #[default]
    Name,
    Compatibility,
    Store,
    Audio,
    Eax,
    Year,
}

impl Column {
    pub const ALL: [Column; 6] = [
        Column::Name,
        Column::Compatibility,
        Column::Store,
        Column::Audio,
        Column::Eax,
        Column::Year,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Column::Name => "Name",
            Column::Compatibility => "Compatibility",
            Column::Store => "Store",
            Column::Audio => "Audio",
            Column::Eax => "EAX",
            Column::Year => "Year",
        }
    }

    /// The column a key sorts by: its heading's first letter.
    pub fn for_key(c: char) -> Option<Column> {
        let c = c.to_ascii_lowercase();
        Column::ALL
            .into_iter()
            .find(|col| col.label().to_ascii_lowercase().starts_with(c))
    }
}

/// The list's order: a column, up or down. A search only narrows the list;
/// the matches keep this order.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Sort {
    pub column: Column,
    pub descending: bool,
}

impl Sort {
    /// A column's letter: that column, or the other way round if it's
    /// already the one sorted by.
    pub fn press(&mut self, column: Column) {
        if self.column == column {
            self.descending = !self.descending;
        } else {
            *self = Sort {
                column,
                descending: false,
            };
        }
    }

    /// "Name ▲": the column and its direction.
    pub fn label(self) -> String {
        format!(
            "{} {}",
            self.column.label(),
            if self.descending { "▼" } else { "▲" }
        )
    }
}

/// This copy's stores, its audio API, its EAX versions and its year, as the
/// table shows them and sorts by them.
pub fn cells(e: &Entry) -> [String; 4] {
    let Some(g) = &e.game else {
        return Default::default();
    };
    let game_api = if g.eax.api.is_empty() {
        "directsound3d"
    } else {
        g.eax.api.as_str()
    };
    let api_name = |a: &str| {
        if a == "openal" {
            "OpenAL"
        } else {
            "DirectSound3D"
        }
    };
    let stores: Vec<(&str, &crate::db::Store)> = g
        .store_list()
        .into_iter()
        .filter(|(k, _)| e.store.is_none_or(|s| s.key() == *k))
        .collect();
    let names: Vec<&str> = stores
        .iter()
        .map(|(k, _)| if *k == "gog" { "GOG" } else { "Steam" })
        .collect();
    let mut apis: Vec<&str> = stores
        .iter()
        .map(|(_, s)| api_name(s.api.as_deref().unwrap_or(game_api)))
        .collect();
    apis.dedup();
    if apis.is_empty() {
        apis.push(api_name(game_api));
    }
    let eax = if g.eax.versions.is_empty() {
        "—".to_string()
    } else {
        g.eax
            .versions
            .iter()
            .map(|v| v.trim_end_matches(".0"))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let year: String = g.released.chars().take(4).collect();
    [names.join(", "), apis.join(", "), eax, year]
}

/// What an entry sorts by in a column, then its name.
pub fn sort_key(e: &Entry, column: Column) -> (String, String) {
    let name = e.name.to_lowercase();
    let by = match column {
        Column::Name => String::new(),
        Column::Compatibility => rating_rank(entry_compat(e)).to_string(),
        Column::Store => cells(e)[0].clone(),
        Column::Audio => cells(e)[1].clone(),
        Column::Eax => cells(e)[2].clone(),
        Column::Year => cells(e)[3].clone(),
    };
    (by, name)
}

/// One tick box in the Filters pop-up.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub enum Item {
    Compat(Compat),
    Steam,
    Gog,
    /// A store entry that store no longer sells.
    Delisted,
    DirectSound3d,
    OpenAl,
    /// A game built on the Miles Sound System.
    Miles,
    /// A game whose profile lists this EAX version (1 to 5).
    Eax(u8),
}

impl Item {
    pub fn label(self) -> String {
        match self {
            Item::Compat(c) => c.label().into(),
            Item::Steam => "Steam".into(),
            Item::Gog => "GOG".into(),
            Item::Delisted => "Delisted".into(),
            Item::DirectSound3d => "DirectSound3D".into(),
            Item::OpenAl => "OpenAL".into(),
            Item::Miles => "Miles".into(),
            Item::Eax(n) => format!("{n}.0"),
        }
    }
}

/// The pop-up's groups in order, each with its boxes.
pub fn groups() -> Vec<(&'static str, Vec<Item>)> {
    vec![
        (
            "Compatibility",
            [
                Compat::Verified,
                Compat::Playable,
                Compat::Unsupported,
                Compat::Unknown,
            ]
            .map(Item::Compat)
            .to_vec(),
        ),
        ("Store", vec![Item::Steam, Item::Gog, Item::Delisted]),
        (
            "Audio",
            vec![Item::DirectSound3d, Item::OpenAl, Item::Miles],
        ),
        ("EAX version", (1..=5).map(Item::Eax).collect()),
    ]
}

#[derive(Clone, PartialEq, Eq, Default, Debug)]
pub struct Filters {
    pub ticked: BTreeSet<Item>,
    pub sort: Sort,
}

/// One store entry's facts, as the boxes test them.
struct Candidate<'a> {
    store: Option<StoreKind>,
    delisted: bool,
    api: &'a str,
    compat: Compat,
}

impl Filters {
    pub fn toggle(&mut self, item: Item) {
        if !self.ticked.remove(&item) {
            self.ticked.insert(item);
        }
    }

    pub fn is_ticked(&self, item: Item) -> bool {
        self.ticked.contains(&item)
    }

    /// Nothing ticked: every game passes.
    pub fn is_clear(&self) -> bool {
        self.ticked.is_empty()
    }

    /// The Filters line: each group's ticked boxes, or "none".
    pub fn summary(&self) -> String {
        let parts: Vec<String> = groups()
            .into_iter()
            .filter_map(|(name, items)| {
                let on: Vec<String> = items
                    .into_iter()
                    .filter(|i| self.is_ticked(*i))
                    .map(Item::label)
                    .collect();
                match (on.is_empty(), name) {
                    (true, _) => None,
                    (false, "EAX version") => Some(format!("EAX {}", on.join(", "))),
                    (false, _) => Some(on.join(", ")),
                }
            })
            .collect();
        if parts.is_empty() {
            "none".into()
        } else {
            parts.join(";  ")
        }
    }

    /// Within a group any ticked box; a group with none ticked lets all through.
    fn group_ok(&self, items: &[Item], pass: impl Fn(Item) -> bool) -> bool {
        let on: Vec<Item> = items
            .iter()
            .copied()
            .filter(|i| self.is_ticked(*i))
            .collect();
        on.is_empty() || on.into_iter().any(pass)
    }

    pub fn passes(&self, e: &Entry) -> bool {
        if self.is_clear() {
            return true;
        }
        // A game the database doesn't list has no store, API or rating.
        let Some(g) = &e.game else { return false };
        let game_api = if g.eax.api.is_empty() {
            "directsound3d"
        } else {
            g.eax.api.as_str()
        };
        // A copy whose store is known is that store's alone, even when the game is
        // sold on both; a game not on this PC is every store that sells it.
        let mut candidates: Vec<Candidate> = g
            .store_list()
            .into_iter()
            .map(|(k, s)| {
                let kind = if k == "gog" {
                    StoreKind::Gog
                } else {
                    StoreKind::Steam
                };
                (kind, k, s)
            })
            .filter(|(kind, _, _)| e.store.is_none() || e.store == Some(*kind))
            .map(|(kind, k, s)| Candidate {
                store: Some(kind),
                delisted: s.delisted,
                api: s.api.as_deref().unwrap_or(game_api),
                compat: g.compat(Some(k)),
            })
            .collect();
        if candidates.is_empty() {
            candidates.push(Candidate {
                store: e.store,
                delisted: false,
                api: game_api,
                compat: g.compat(None),
            });
        }
        let miles = g.eax.sound_system.as_deref() == Some("miles");
        let groups = groups();
        candidates.iter().any(|c| {
            self.group_ok(&groups[0].1, |i| i == Item::Compat(c.compat))
                && self.group_ok(&[Item::Steam, Item::Gog], |i| match i {
                    Item::Steam => c.store == Some(StoreKind::Steam),
                    _ => c.store == Some(StoreKind::Gog),
                })
                && (!self.is_ticked(Item::Delisted) || (c.store.is_some() && c.delisted))
                && self.group_ok(&groups[2].1, |i| match i {
                    Item::DirectSound3d => c.api == "directsound3d",
                    Item::OpenAl => c.api == "openal",
                    _ => miles,
                })
                && self.group_ok(&groups[3].1, |i| match i {
                    Item::Eax(n) => g.eax.versions.iter().any(|v| *v == format!("{n}.0")),
                    _ => false,
                })
        })
    }
}

/// Where a rating comes in the Rating order.
pub fn rating_rank(c: Compat) -> u8 {
    match c {
        Compat::Verified => 0,
        Compat::Playable => 1,
        Compat::Unsupported => 2,
        Compat::Unknown => 3,
    }
}

/// An entry's own rating: its store's, else the game's; a game the database
/// doesn't list is unknown.
pub fn entry_compat(e: &Entry) -> Compat {
    let key = e.store.map(StoreKind::key);
    e.game.as_ref().map_or(Compat::Unknown, |g| g.compat(key))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    fn entry(json: &str) -> Entry {
        let db = Database::parse(&format!(r#"{{"games":[{json}]}}"#)).unwrap();
        Entry::database_only(db.games[0].clone())
    }

    fn with(items: &[Item]) -> Filters {
        let mut x = Filters::default();
        for i in items {
            x.toggle(*i);
        }
        x
    }

    const BOTH: &str = r#"{"id":"a","name":"A","tested":false,
        "stores":{"steam":{"id":1,"delisted":true},"gog":{"id":2,"api":"openal"}},
        "eax":{"api":"directsound3d","versions":["1.0","3.0"]}}"#;

    #[test]
    fn nothing_ticked_lets_everything_through() {
        assert!(Filters::default().passes(&entry(BOTH)));
        assert!(Filters::default().passes(&entry(r#"{"id":"a","name":"A"}"#)));
        assert_eq!(Filters::default().summary(), "none");
    }

    #[test]
    fn each_store_entry_is_filtered_on_its_own_rating() {
        let mut e = entry(
            r#"{"id":"a","name":"A","stores":{"steam":{"id":1,"compatibility":"unknown"},
            "gog":{"id":2,"compatibility":"playable"}}}"#,
        );
        // No store of its own (only in the database): any store's rating will do.
        assert!(with(&[Item::Compat(Compat::Playable)]).passes(&e));
        assert!(with(&[Item::Compat(Compat::Unknown)]).passes(&e));
        assert!(!with(&[Item::Compat(Compat::Verified)]).passes(&e));
        e.store = Some(StoreKind::Steam);
        assert!(!with(&[Item::Compat(Compat::Playable)]).passes(&e));
        e.store = Some(StoreKind::Gog);
        assert!(with(&[Item::Compat(Compat::Playable)]).passes(&e));
    }

    #[test]
    fn boxes_in_one_group_widen_and_across_groups_narrow() {
        let e = entry(BOTH); // unknown on both stores; GOG is OpenAL
        let either = with(&[
            Item::Compat(Compat::Verified),
            Item::Compat(Compat::Unknown),
        ]);
        assert!(either.passes(&e));
        let gog_openal = with(&[Item::Gog, Item::OpenAl]);
        assert!(gog_openal.passes(&e));
        // Steam is DirectSound3D, so Steam and OpenAL never meet on one store.
        assert!(!with(&[Item::Steam, Item::OpenAl]).passes(&e));
    }

    #[test]
    fn delisted_is_the_stores_own_flag() {
        let e = entry(BOTH);
        assert!(with(&[Item::Delisted]).passes(&e));
        assert!(with(&[Item::Steam, Item::Delisted]).passes(&e));
        assert!(!with(&[Item::Gog, Item::Delisted]).passes(&e));
    }

    #[test]
    fn eax_versions_and_miles_come_from_the_profile() {
        let e = entry(BOTH);
        assert!(with(&[Item::Eax(3)]).passes(&e));
        assert!(with(&[Item::Eax(2), Item::Eax(3)]).passes(&e));
        assert!(!with(&[Item::Eax(2)]).passes(&e));
        assert!(!with(&[Item::Miles]).passes(&e));
        let mut g = e.game.clone().unwrap();
        g.eax.sound_system = Some("miles".into());
        let mut miles = e.clone();
        miles.game = Some(g);
        assert!(with(&[Item::Miles]).passes(&miles));
    }

    #[test]
    fn a_game_the_database_lacks_only_shows_with_nothing_ticked() {
        let mut e = entry(BOTH);
        e.game = None;
        assert!(Filters::default().passes(&e));
        assert!(!with(&[Item::Steam]).passes(&e));
    }

    #[test]
    fn ticking_twice_unticks_and_the_summary_names_what_is_on() {
        let mut f = with(&[
            Item::Compat(Compat::Verified),
            Item::Gog,
            Item::Eax(1),
            Item::Eax(2),
        ]);
        assert_eq!(f.summary(), "Verified;  GOG;  EAX 1.0, 2.0");
        f.toggle(Item::Gog);
        assert_eq!(f.summary(), "Verified;  EAX 1.0, 2.0");
    }

    #[test]
    fn the_views_cycle_both_ways() {
        assert_eq!(View::All.next(), View::MyLibrary);
        assert_eq!(View::Favorites.next(), View::All);
        assert_eq!(View::All.prev(), View::Favorites);
    }

    fn copy(store: Option<StoreKind>) -> Entry {
        let mut e = entry(BOTH);
        e.store = store;
        e
    }

    #[test]
    fn an_installed_copy_belongs_to_the_store_it_came_from() {
        let (steam, gog) = (copy(Some(StoreKind::Steam)), copy(Some(StoreKind::Gog)));
        let on_steam = with(&[Item::Steam]);
        let on_gog = with(&[Item::Gog]);
        assert!(on_steam.passes(&steam) && !on_steam.passes(&gog));
        assert!(on_gog.passes(&gog) && !on_gog.passes(&steam));
    }

    #[test]
    fn a_copy_of_unknown_origin_and_a_game_not_here_match_every_store_that_sells_them() {
        let unknown = copy(None);
        assert!(with(&[Item::Steam]).passes(&unknown));
        assert!(with(&[Item::Gog]).passes(&unknown));
    }

    #[test]
    fn a_copys_own_store_decides_delisted_and_the_audio_api() {
        // BOTH: Steam is delisted; GOG has its own OpenAL api.
        let (steam, gog) = (copy(Some(StoreKind::Steam)), copy(Some(StoreKind::Gog)));
        let delisted = with(&[Item::Delisted]);
        assert!(delisted.passes(&steam) && !delisted.passes(&gog));
        let openal = with(&[Item::OpenAl]);
        assert!(openal.passes(&gog) && !openal.passes(&steam));
    }
}
