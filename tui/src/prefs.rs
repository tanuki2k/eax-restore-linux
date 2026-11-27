//! The player's defaults for new installs, from the F2 settings screen, kept
//! between runs in `$XDG_CONFIG_HOME/eax-restore-linux/tui.json`. A game that
//! already has the fix opens on what it has, not on these.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// A build choice as the settings screen saves it: an option's key from
/// `build_choice` ("numbered", which the list calls Latest, or a version).
/// Older files said "stable", "tested", "latest" or "rolling", which all
/// read as Latest now.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(from = "String", into = "String")]
pub struct BuildPref(pub String);

impl Default for BuildPref {
    fn default() -> Self {
        BuildPref(crate::build_choice::NUMBERED.into())
    }
}

impl From<String> for BuildPref {
    fn from(s: String) -> Self {
        use crate::build_choice::{NUMBERED, ROLLING, TESTED};
        match s.as_str() {
            "stable" | TESTED | "latest" | ROLLING | NUMBERED => BuildPref(NUMBERED.into()),
            v if crate::engine::builds::safe_name(v) => BuildPref(s),
            _ => BuildPref::default(),
        }
    }
}

impl From<BuildPref> for String {
    fn from(b: BuildPref) -> String {
        b.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum OverridePref {
    /// Steam's launch options or Heroic's environment variables; the registry
    /// for a game with neither.
    #[default]
    LaunchOptions,
    Registry,
    Manual,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum VcPref {
    /// Use Microsoft's VC++ files when the prefix has them, else skip.
    #[default]
    UseIfThere,
    InstallIfMissing,
    LeaveAlone,
}

/// The speaker setups, in `panel::speaker_choices()`'s order. Saved by name so
/// a reordered list doesn't change anyone's choice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum SpeakerPref {
    Headphones3d,
    Headphones,
    TwoSpeakers,
    #[default]
    Auto,
    ProLogic,
    Quad,
    Surround51,
    Surround61,
    Surround71,
}

impl SpeakerPref {
    pub const ALL: [SpeakerPref; 9] = [
        SpeakerPref::Headphones3d,
        SpeakerPref::Headphones,
        SpeakerPref::TwoSpeakers,
        SpeakerPref::Auto,
        SpeakerPref::ProLogic,
        SpeakerPref::Quad,
        SpeakerPref::Surround51,
        SpeakerPref::Surround61,
        SpeakerPref::Surround71,
    ];
    /// Its place in `panel::speaker_choices()`.
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|s| *s == self).unwrap_or(0)
    }
}

/// Which view the list opens on (the bar along the top). Older files saved
/// "on-this-pc" and "installed" under "show", which read as My library and
/// Patched.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ViewPref {
    #[default]
    All,
    #[serde(alias = "on-this-pc")]
    MyLibrary,
    #[serde(alias = "installed")]
    Patched,
    Favorites,
}

impl ViewPref {
    pub fn view(self) -> crate::filters::View {
        use crate::filters::View;
        match self {
            ViewPref::All => View::All,
            ViewPref::MyLibrary => View::MyLibrary,
            ViewPref::Patched => View::Patched,
            ViewPref::Favorites => View::Favorites,
        }
    }
}

/// The settings an older file has but this version doesn't use (the list's
/// starting compatibility filter, now the Filters pop-up's tick boxes) are
/// skipped when it's read.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    #[serde(alias = "show")]
    pub view: ViewPref,
    /// The starred games (F4), by their database id, or the folder of a game
    /// the database doesn't list.
    pub favorites: std::collections::BTreeSet<String>,
    pub dsoal_build: BuildPref,
    pub openal_build: BuildPref,
    pub over: OverridePref,
    pub vcrun: VcPref,
    pub speakers: SpeakerPref,
}

/// `$XDG_CONFIG_HOME`, else `~/.config`.
fn config_home() -> Option<PathBuf> {
    std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
}

pub fn path() -> Option<PathBuf> {
    config_home().map(|c| c.join("eax-restore-linux/tui.json"))
}

impl Prefs {
    /// The saved defaults; the shipped ones when there's no file or it can't
    /// be read.
    pub fn load() -> Self {
        path().map_or_else(Self::default, |p| Self::load_from(&p))
    }

    pub fn load_from(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    pub fn save(&self) -> std::io::Result<()> {
        match path() {
            Some(p) => self.save_to(&p),
            None => Ok(()),
        }
    }

    /// Written beside the file and renamed over it, so a crash never leaves
    /// half a file.
    pub fn save_to(&self, path: &Path) -> std::io::Result<()> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(std::io::Error::other)?;
        std::fs::write(&tmp, text + "\n")?;
        std::fs::rename(&tmp, path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saved_defaults_come_back_and_a_bad_file_gives_the_shipped_ones() {
        let tmp = tempfile::tempdir().unwrap();
        let file = tmp.path().join("eax-restore-linux/tui.json");
        assert_eq!(Prefs::load_from(&file), Prefs::default());

        let p = Prefs {
            view: ViewPref::Favorites,
            favorites: ["deus-ex".to_string()].into(),
            dsoal_build: BuildPref("r690".into()),
            openal_build: BuildPref("numbered".into()),
            over: OverridePref::Manual,
            vcrun: VcPref::InstallIfMissing,
            speakers: SpeakerPref::Surround51,
        };
        p.save_to(&file).unwrap();
        assert_eq!(Prefs::load_from(&file), p);

        std::fs::write(&file, "{ not json").unwrap();
        assert_eq!(Prefs::load_from(&file), Prefs::default());

        // A file from before: stable, tested, latest and rolling all read
        // as Latest.
        std::fs::write(&file, r#"{"dsoal_build":"latest","openal_build":"stable"}"#).unwrap();
        let old = Prefs::load_from(&file);
        assert_eq!(old.dsoal_build.0, "numbered");
        assert_eq!(old.openal_build.0, "numbered");

        // A setting this version doesn't have any more (the cover art) is skipped.
        std::fs::write(&file, r#"{"speakers":"quad","cover":"colour"}"#).unwrap();
        assert_eq!(Prefs::load_from(&file).speakers, SpeakerPref::Quad);

        // A file from an older version, missing settings, keeps the ones it has.
        std::fs::write(&file, r#"{"speakers":"quad"}"#).unwrap();
        let old = Prefs::load_from(&file);
        assert_eq!(old.speakers, SpeakerPref::Quad);
        assert_eq!(old.over, OverridePref::LaunchOptions);
        assert_eq!(old.view, ViewPref::All);
        assert!(old.favorites.is_empty());

        // A file from before the views: "show" reads as the view, and the old
        // starting compatibility filter is skipped.
        std::fs::write(&file, r#"{"show":"installed","tested":"tested"}"#).unwrap();
        assert_eq!(Prefs::load_from(&file).view, ViewPref::Patched);
        std::fs::write(&file, r#"{"show":"on-this-pc","compat":"unknown"}"#).unwrap();
        assert_eq!(Prefs::load_from(&file).view, ViewPref::MyLibrary);
    }

    #[test]
    fn the_speaker_list_matches_the_game_pages() {
        let page = crate::panel::speaker_choices();
        assert_eq!(page.len(), SpeakerPref::ALL.len());
        // The shipped default is the engine's own.
        use crate::engine::speakers::{Listening, Speakers};
        assert_eq!(
            page[SpeakerPref::default().index()].2,
            Speakers::stereo(Listening::Auto, true)
        );
    }
}
