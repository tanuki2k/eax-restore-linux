//! What the headless commands and the TUI's game panel both need around a
//! `Plan`: the game's settings looked at for this install, the profile's
//! alsoft.ini values, crash markers, companion apps' overrides, and changing
//! an installed game's speakers and settings.

use super::apply::{self, Host, RevertGroup, UpdateReport};
use super::config::{self, Format};
use super::game_settings::{self, Fix, PlanRow, Purpose, Survey};
use super::identify::Store;
use super::install::{Override, Plan};
use super::installed::Installed;
use super::launcher::target::Target;
use super::prepare::Facts;
use super::speakers::Speakers;
use crate::db::Game;
use anyhow::Result;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// EAX_RESTORE_UNTESTED_SETTINGS, as the script reads it.
pub fn untested_from_env() -> bool {
    std::env::var("EAX_RESTORE_UNTESTED_SETTINGS")
        .is_ok_and(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "y"))
}

/// The game's settings as they stand in its files now.
pub fn survey(
    facts: &Facts,
    game: &Game,
    speakers: Option<Speakers>,
    purpose: Purpose,
    recorded: HashSet<String>,
    include_untested: bool,
) -> Vec<Fix> {
    let survey = Survey {
        store: facts.store.unwrap_or(Store::Steam),
        places: config::paths::Places {
            game_dir: &facts.game_dir,
            install_root: &facts.install_root,
            prefix: facts.prefix.as_deref(),
            user: &std::env::var("USER").unwrap_or_default(),
        },
        speakers,
        purpose,
        recorded,
        include_untested,
    };
    game_settings::survey(game, &survey)
}

/// Each config file's crash marker, by its name in the profile.
pub fn crash_markers(game: Option<&Game>) -> HashMap<String, String> {
    game.map(|g| {
        g.game_config
            .files
            .iter()
            .filter(|(_, f)| !f.crash_marker.is_empty())
            .map(|(n, f)| (n.clone(), f.crash_marker.clone()))
            .collect()
    })
    .unwrap_or_default()
}

/// The profile's alsoft.ini values, when they're verified (or untested ones
/// are wanted): (section, key, value).
pub fn alsoft_values(game: &Game, include_untested: bool) -> Vec<(String, String, String)> {
    if game.install.alsoft_tested != Some(true) && !include_untested {
        return Vec::new();
    }
    let mut out = Vec::new();
    for (sec, keys) in game.install.alsoft_ini.iter().flatten() {
        for (key, value) in keys.as_object().into_iter().flatten() {
            let v = match value {
                serde_json::Value::String(s) => s.clone(),
                other => other.to_string(),
            };
            if config::row_is_safe(Format::Ini, "game:alsoft.ini", sec, key, &v) {
                out.push((sec.clone(), key.clone(), v));
            }
        }
    }
    out
}

/// Companion apps follow the game's override: its launcher when Steam has
/// settings for the app, else the app's own prefix registry.
pub fn companion_overrides(plan: &mut Plan, home: &Path) {
    let over = plan.over.clone();
    for c in plan.companions.iter_mut() {
        c.over = match &over {
            Override::Launcher(_) => {
                Target::steam(home, None, &c.app_id).map_or(Override::Registry, Override::Launcher)
            }
            other => other.clone(),
        };
    }
}

/// The rows to apply for the chosen settings, and (title, file) for the
/// chosen ones whose file the game hasn't written yet.
pub fn chosen_rows(
    fixes: &[Fix],
    chosen: &HashSet<String>,
) -> (Vec<PlanRow>, Vec<(String, String)>) {
    let mut rows = Vec::new();
    let mut waiting = Vec::new();
    for f in fixes.iter().filter(|f| chosen.contains(&f.title)) {
        match f.status {
            game_settings::Status::Offer => rows.extend(f.plan.iter().cloned()),
            game_settings::Status::Missing => {
                waiting.push((f.title.clone(), f.missing_file.clone().unwrap_or_default()))
            }
            _ => {}
        }
    }
    (rows, waiting)
}

/// Writes a new speaker setup into an installed game's alsoft.ini files,
/// puts back the settings set for the old layout, and turns on the ones for
/// the new. The files that couldn't be written, and what the settings did.
pub fn change_speakers(
    facts: &Facts,
    game: Option<&Game>,
    inst: &Installed,
    new: Speakers,
    include_untested: bool,
    host: &mut dyn Host,
) -> Result<(Vec<PathBuf>, Option<UpdateReport>)> {
    host.step("Changing the speaker setup");
    let failed: Vec<PathBuf> = inst
        .alsoft_files
        .iter()
        .filter(|f| new.write_alsoft(f).is_err())
        .cloned()
        .collect();
    let Some(g) = game else {
        return Ok((failed, None));
    };
    let revert = inst.settings_for_other_speakers(g, &new, include_untested);
    let plan: Vec<PlanRow> = survey(
        facts,
        g,
        Some(new),
        Purpose::SpeakersOnly,
        HashSet::new(),
        include_untested,
    )
    .into_iter()
    .filter(|f| f.status == game_settings::Status::Offer)
    .flat_map(|f| f.plan)
    .collect();
    if revert.is_empty() && plan.is_empty() {
        return Ok((failed, None));
    }
    let report = change_settings(facts, game, &revert, &plan, host)?;
    Ok((failed, Some(report)))
}

/// Puts back recorded settings and turns on new ones, rewriting the manifest
/// the way a reinstall does.
pub fn change_settings(
    facts: &Facts,
    game: Option<&Game>,
    revert: &[RevertGroup],
    plan: &[PlanRow],
    host: &mut dyn Host,
) -> Result<UpdateReport> {
    host.step("Changing the game's settings");
    apply::update_in_manifest(
        &super::manifest::path_in(&facts.game_dir),
        revert,
        plan,
        &crash_markers(game),
        host,
    )
}
