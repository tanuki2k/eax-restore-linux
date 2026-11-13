//! A game's own settings (its profile's `game_config`): what each one would
//! change in the game's files as they are now, so a panel can show them all
//! before anything is written. Ports of `load_game_config_rows` and the
//! sorting in `_gs_build_plan` (`src/game-config.sh`), without its prompts:
//! a file the game hasn't written yet is reported as missing, and looking
//! again is the caller's to offer.

use super::config::paths::{resolve_config_file, Mode, Places};
use super::config::{self, values_equal, Format, Value};
use super::identify::Store;
use super::speakers::Speakers;
use crate::db::{Game, OnlyIf};
use serde_json::Value as Json;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Category {
    /// Needed for EAX.
    Audio,
    /// Not needed for EAX.
    Optional,
}

impl Category {
    /// The name the manifest's `CONFIG:` lines use.
    pub fn name(self) -> &'static str {
        match self {
            Category::Audio => "audio",
            Category::Optional => "optional",
        }
    }
}

/// One key one setting changes, flattened from the database.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub category: Category,
    /// The setting's place in its list, from 0.
    pub index: usize,
    pub title: String,
    pub reason: String,
    pub stores: Vec<String>,
    pub speakers: Vec<String>,
    pub follow_up: String,
    /// The file's name in `game_config.files`.
    pub file: String,
    /// As the database spells it; empty when the file isn't described.
    pub format: String,
    pub if_missing: String,
    /// The locations joined with `|`.
    pub locations: String,
    pub all_locations: bool,
    pub section: String,
    pub key: String,
    /// The value, `true` / `false` / `null` as the markers.
    pub value: Value,
    /// Not marked `"tested": true`.
    pub untested: bool,
}

/// The database's value as the script spells it.
fn encode(v: &Json) -> Value {
    match v {
        Json::Bool(true) => Value::True,
        Json::Bool(false) => Value::False,
        Json::Null => Value::Delete,
        Json::String(s) => Value::text(s),
        other => Value::text(&other.to_string()),
    }
}

/// The formats whose changes nest section → key → value.
fn sectioned(format: &str) -> bool {
    matches!(format, "ini" | "ini_braces" | "xml_attributes" | "registry")
}

/// Every key the game's settings change, audio settings first, in the
/// database's order. Untested settings only with `include_untested`.
pub fn rows(game: &Game, include_untested: bool) -> Vec<Row> {
    let gc = &game.game_config;
    let lists = [
        (Category::Audio, &gc.audio_settings),
        (Category::Optional, &gc.optional_settings),
    ];
    let mut out = Vec::new();
    for (category, settings) in lists {
        for (index, s) in settings.iter().enumerate() {
            if !include_untested && !s.tested {
                continue;
            }
            let only_if = s.only_if.clone().unwrap_or_default();
            for (file, change) in &s.changes {
                let def = gc.files.get(file).cloned().unwrap_or_default();
                let mut kv: Vec<(String, String, Value)> = Vec::new();
                if let Json::Object(map) = change {
                    for (k, v) in map {
                        match v {
                            Json::Object(inner) if sectioned(&def.format) => {
                                for (key, val) in inner {
                                    kv.push((k.clone(), key.clone(), encode(val)));
                                }
                            }
                            _ => kv.push((String::new(), k.clone(), encode(v))),
                        }
                    }
                }
                for (section, key, value) in kv {
                    out.push(Row {
                        category,
                        index,
                        title: s.title.clone(),
                        reason: s.reason.clone(),
                        stores: OnlyIf::list(&only_if.stores),
                        speakers: OnlyIf::list(&only_if.speakers),
                        follow_up: s.follow_up.clone().unwrap_or_default(),
                        file: file.clone(),
                        format: def.format.clone(),
                        if_missing: def.if_missing.clone(),
                        locations: def.locations.join("|"),
                        all_locations: def.all_locations,
                        section,
                        key,
                        value,
                        untested: !s.tested,
                    });
                }
            }
        }
    }
    out
}

/// Which settings a survey looks at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    /// An install: every setting for this store and speaker setup.
    Install,
    /// Changing the speaker setup: only settings tied to a speaker layout.
    SpeakersOnly,
    /// Changing an installed game's settings: the ones this tool applied
    /// before show as [`Status::Applied`], so they can be turned off.
    Edit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    /// Something to change.
    Offer,
    /// Every key already has the value.
    Already,
    /// Already set, by an earlier run of this tool (Edit only).
    Applied,
    /// A file it changes isn't there yet: the game writes it on its first run.
    Missing,
    /// Every file it changes is one this build of the game doesn't have.
    Absent,
    /// Not for this store or speaker setup, or not looked at in this purpose.
    Skip,
    /// Its database entry failed the safety check.
    Invalid,
}

/// One key a setting would change, ready to apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanRow {
    pub category: Category,
    pub title: String,
    pub path: PathBuf,
    pub format: Format,
    pub section: String,
    pub key: String,
    pub new: Value,
    /// The file's name in `game_config.files`.
    pub file: String,
    /// The value it has now.
    pub old: Value,
    /// The file doesn't exist yet and is created (`if_missing: create`).
    pub create: bool,
}

/// One line of what a setting changes, for showing: `old` is `None` for a
/// key that already has its value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ViewRow {
    pub path: PathBuf,
    pub section: String,
    pub key: String,
    pub old: Option<Value>,
    pub new: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fix {
    pub category: Category,
    pub index: usize,
    pub title: String,
    pub reason: String,
    pub follow_up: String,
    pub untested: bool,
    pub status: Status,
    pub plan: Vec<PlanRow>,
    pub view: Vec<ViewRow>,
    /// The file it is waiting for ([`Status::Missing`]).
    pub missing_file: Option<String>,
    /// Files it changes that this build of the game doesn't have.
    pub absent_files: Vec<String>,
    /// The files its plan changes.
    pub files: Vec<String>,
}

impl Fix {
    /// Shown to the player: everything but the skipped and the invalid.
    pub fn shown(&self) -> bool {
        !matches!(self.status, Status::Skip | Status::Invalid)
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum FileState {
    Found,
    Create,
    Missing,
    Skip,
}

/// What a survey needs to know about the install.
pub struct Survey<'a> {
    pub store: Store,
    pub places: Places<'a>,
    /// The speaker setup; `None` matches no speaker-limited setting.
    pub speakers: Option<Speakers>,
    pub purpose: Purpose,
    /// Titles of the settings this tool applied before (Edit).
    pub recorded: HashSet<String>,
    pub include_untested: bool,
}

/// Reads every setting's config files as they are now and sorts each
/// setting by what it would do. Nothing is written.
pub fn survey(game: &Game, s: &Survey) -> Vec<Fix> {
    let rows = rows(game, s.include_untested);
    let has_headphones = rows
        .iter()
        .any(|r| r.speakers.iter().any(|v| v == "headphones"));
    let mut fixes: Vec<Fix> = Vec::new();
    let mut at: HashMap<(Category, usize), usize> = HashMap::new();
    let mut has_file: HashSet<usize> = HashSet::new();
    let mut files: HashMap<String, (FileState, Vec<PathBuf>)> = HashMap::new();

    for row in &rows {
        let i = *at.entry((row.category, row.index)).or_insert_with(|| {
            let wrong_store =
                !row.stores.is_empty() && !row.stores.iter().any(|x| x == s.store.key());
            let wrong_speakers = !row.speakers.is_empty()
                && !s
                    .speakers
                    .is_some_and(|sp| sp.matches(&row.speakers, has_headphones));
            let not_speakers = s.purpose == Purpose::SpeakersOnly && row.speakers.is_empty();
            fixes.push(Fix {
                category: row.category,
                index: row.index,
                title: row.title.clone(),
                reason: row.reason.clone(),
                follow_up: row.follow_up.clone(),
                untested: row.untested,
                status: if wrong_store || wrong_speakers || not_speakers {
                    Status::Skip
                } else {
                    Status::Already
                },
                plan: Vec::new(),
                view: Vec::new(),
                missing_file: None,
                absent_files: Vec::new(),
                files: Vec::new(),
            });
            fixes.len() - 1
        });
        let fix = &mut fixes[i];
        if matches!(fix.status, Status::Skip | Status::Invalid) {
            continue;
        }
        let format = row.format.parse::<Format>();
        let safe = format.as_ref().is_ok_and(|f| {
            config::row_is_safe(
                *f,
                &row.locations,
                &row.section,
                &row.key,
                &String::from_utf8_lossy(row.value.as_bytes()),
            )
        });
        let (true, Ok(format)) = (safe, format) else {
            fix.status = Status::Invalid;
            continue;
        };

        // Each file is looked for once per survey.
        let (state, paths) = files
            .entry(row.file.clone())
            .or_insert_with(|| {
                let mode = if row.all_locations {
                    Mode::All
                } else {
                    Mode::First
                };
                let found = resolve_config_file(&row.locations, mode, &s.places);
                if !found.is_empty() {
                    (FileState::Found, found)
                } else if row.if_missing == "create" {
                    let at = resolve_config_file(&row.locations, Mode::Create, &s.places);
                    let state = if at.is_empty() {
                        FileState::Missing
                    } else {
                        FileState::Create
                    };
                    (state, at)
                } else if row.if_missing == "skip" {
                    (FileState::Skip, Vec::new())
                } else {
                    (FileState::Missing, Vec::new())
                }
            })
            .clone();
        match state {
            FileState::Skip => {
                if !fix.absent_files.contains(&row.file) {
                    fix.absent_files.push(row.file.clone());
                }
                continue;
            }
            FileState::Missing => {
                fix.status = Status::Missing;
                fix.missing_file = Some(row.file.clone());
                continue;
            }
            _ => {}
        }
        if fix.status == Status::Missing {
            continue;
        }
        has_file.insert(i);

        for path in paths {
            let old = config::get_file(&path, format, &row.section, &row.key);
            let nothing_to_remove =
                old == Value::Absent && matches!(row.value, Value::False | Value::Delete);
            if nothing_to_remove {
                continue;
            }
            // A key that already has its value still shows (ticked) under a
            // setting that has other keys to change.
            if values_equal(format, &old, &row.value) {
                fix.view.push(ViewRow {
                    path,
                    section: row.section.clone(),
                    key: row.key.clone(),
                    old: None,
                    new: row.value.clone(),
                });
                continue;
            }
            fix.status = Status::Offer;
            fix.view.push(ViewRow {
                path: path.clone(),
                section: row.section.clone(),
                key: row.key.clone(),
                old: Some(old.clone()),
                new: row.value.clone(),
            });
            if !fix.files.contains(&row.file) {
                fix.files.push(row.file.clone());
            }
            fix.plan.push(PlanRow {
                category: row.category,
                title: row.title.clone(),
                path,
                format,
                section: row.section.clone(),
                key: row.key.clone(),
                new: row.value.clone(),
                file: row.file.clone(),
                old,
                create: state == FileState::Create,
            });
        }
    }

    for (i, fix) in fixes.iter_mut().enumerate() {
        if fix.status == Status::Already && !fix.absent_files.is_empty() && !has_file.contains(&i) {
            fix.status = Status::Absent;
        }
        if s.purpose == Purpose::Edit
            && fix.status == Status::Already
            && s.recorded.contains(&fix.title)
        {
            fix.status = Status::Applied;
        }
    }
    fixes
}
