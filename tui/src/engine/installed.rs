//! What an install left in a game folder, read from its manifest: the
//! generated alsoft.ini files, the Wine prefix, and the game settings it
//! changed. The start of `src/settings-flow.sh` (Tools → Game settings and
//! Speaker configuration), which is inline there, not a function; a panel
//! shows this as the install's status.

use super::apply::{recorded_settings, RevertGroup};
use super::config::paths::game_install_root;
use super::files;
use super::game_settings;
use super::identify::{heroic_installed_jsons, identify_game_dir, Identified};
use super::install::Engine;
use super::manifest;
use super::speakers::Speakers;
use crate::db::Game;
use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct Installed {
    pub game_dir: PathBuf,
    pub manifest: PathBuf,
    /// The store and ID, when the folder says.
    pub identified: Option<Identified>,
    /// The game's install root, for `game_root:` locations.
    pub install_root: PathBuf,
    /// The generated alsoft.ini files that are still there.
    pub alsoft_files: Vec<PathBuf>,
    /// The Wine prefix the install put DLLs in.
    pub prefix: Option<PathBuf>,
    /// The game settings it changed, by setting.
    pub settings: Vec<RevertGroup>,
    /// What the last install chose, as far as its manifest and files say.
    pub state: InstalledState,
}

/// Where an install put the DLL override.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OverrideKind {
    Launcher,
    Registry,
    /// Neither: the player set it by hand.
    Manual,
}

/// What an install chose.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InstalledState {
    pub engine: Engine,
    pub over: OverrideKind,
    /// 32 or 64, from which system folder the prefix's DLLs went in.
    pub arch: Option<u8>,
    /// The VC++ runtime was installed or set up by it.
    pub vcrun: bool,
    pub com_routing: bool,
    pub eax_unified: bool,
    /// The generated alsoft.ini has the advanced tweaks.
    pub advanced_limits: bool,
    /// The DSOAL and OpenAL Soft versions it put in (`r693`, `1.25.2`), when
    /// its manifest records them; older installs don't.
    pub dsoal_version: Option<String>,
    pub openal_version: Option<String>,
}

/// DSOAL leaves a dsound.dll in the game's folder; OpenAL Soft alone leaves only
/// an OpenAL32.dll.
fn engine_from(lines: &[&[u8]], game_dir: &Path) -> Engine {
    let game = game_dir.as_os_str().as_bytes();
    let ours = |name: &[u8]| {
        lines.iter().any(|l| {
            l.len() > game.len() + 1
                && l.starts_with(game)
                && l[game.len()] == b'/'
                && l[game.len() + 1..].eq_ignore_ascii_case(name)
        })
    };
    if ours(b"OpenAL32.dll") && !ours(b"dsound.dll") {
        Engine::OpenAlSoft
    } else {
        Engine::Dsoal
    }
}

/// The engine a live install put in `game_dir`, without the rest of `read`'s
/// work, for the game list. `None` when there is no live install.
pub fn engine_in(game_dir: &Path) -> Option<Engine> {
    let manifest_path = manifest::path_in(game_dir);
    if !manifest::is_live(&manifest_path) {
        return None;
    }
    let data = std::fs::read(&manifest_path).ok()?;
    let lines: Vec<&[u8]> = data.split(|&b| b == b'\n').collect();
    Some(engine_from(&lines, game_dir))
}

fn state_from(lines: &[&[u8]], game_dir: &Path, alsoft: Option<&PathBuf>) -> InstalledState {
    let has = |l: &[u8]| lines.contains(&l);
    let engine = engine_from(lines, game_dir);
    let over = if lines.iter().any(|l| l.starts_with(b"LAUNCHER:")) {
        OverrideKind::Launcher
    } else if lines
        .iter()
        .any(|l| l.starts_with(b"REGISTRY:OVERRIDE") && !l.contains(&b'\t'))
    {
        OverrideKind::Registry
    } else {
        OverrideKind::Manual
    };
    let arch = lines.iter().find_map(|l| {
        let text = String::from_utf8_lossy(l);
        if text.contains("/drive_c/windows/syswow64/") {
            Some(32)
        } else if let Some(at) = text.find("/drive_c/windows/system32/") {
            // system32 is 64-bit only on a prefix that also has syswow64.
            let wow = Path::new(&text[..at]).join("drive_c/windows/syswow64");
            Some(if wow.is_dir() { 64 } else { 32 })
        } else {
            None
        }
    });
    InstalledState {
        engine,
        over,
        arch,
        vcrun: has(b"VCRUN") || has(b"VCRUN:OVERRIDES"),
        com_routing: has(b"REGISTRY:COM"),
        eax_unified: has(b"EAXUNIFIED"),
        advanced_limits: alsoft.is_some_and(|f| {
            std::fs::read_to_string(f).is_ok_and(|t| t.contains("(Advanced Tweaks)"))
        }),
        dsoal_version: None,
        openal_version: None,
    }
}

fn has_dotdot(line: &[u8]) -> bool {
    [b"/", line, b"/"].concat().windows(4).any(|w| w == b"/../")
}

/// Every install path Heroic records, for working out an install root.
fn heroic_install_paths(home: &Path) -> Vec<PathBuf> {
    fn walk(v: &serde_json::Value, out: &mut Vec<PathBuf>) {
        match v {
            serde_json::Value::Object(m) => {
                for key in ["install_path", "installPath"] {
                    if let Some(p) = m.get(key).and_then(|p| p.as_str()) {
                        out.push(PathBuf::from(p));
                        break;
                    }
                }
                m.values().for_each(|x| walk(x, out));
            }
            serde_json::Value::Array(a) => a.iter().for_each(|x| walk(x, out)),
            _ => {}
        }
    }
    let mut out = Vec::new();
    for json in heroic_installed_jsons(home) {
        if let Some(v) = std::fs::read_to_string(&json)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
        {
            walk(&v, &mut out);
        }
    }
    out
}

impl Installed {
    /// `None` when the folder holds no live install.
    pub fn read(game_dir: &Path, home: &Path) -> Option<Self> {
        let manifest_path = manifest::path_in(game_dir);
        if !manifest::is_live(&manifest_path) {
            return None;
        }
        let data = std::fs::read(&manifest_path).ok()?;
        let identified = identify_game_dir(game_dir, home);
        let install_root = game_install_root(
            game_dir,
            identified.as_ref().map(|i| i.root.as_path()),
            &heroic_install_paths(home),
        );
        let root = install_root.as_os_str().as_bytes();
        let lines: Vec<&[u8]> = data.split(|&b| b == b'\n').collect();
        let alsoft_files: Vec<PathBuf> = lines
            .iter()
            .filter(|l| l.starts_with(b"/") && l.ends_with(b"/alsoft.ini") && !has_dotdot(l))
            .filter(|l| files::path_in_scope(l, root))
            .map(|l| PathBuf::from(OsStr::from_bytes(l)))
            .filter(|p| p.is_file())
            .collect();
        let prefix = lines.iter().find_map(|l| {
            let at = l.windows(9).position(|w| w == b"/drive_c/")?;
            (l.starts_with(b"/")
                && at > 0
                && !has_dotdot(l)
                && files::file_is_ours(Path::new(OsStr::from_bytes(l))))
            .then(|| PathBuf::from(OsStr::from_bytes(&l[..at])))
        });
        let versions = manifest::recorded_versions(&manifest_path);
        Some(Installed {
            game_dir: game_dir.to_path_buf(),
            manifest: manifest_path,
            identified,
            install_root,
            prefix,
            settings: recorded_settings(&data),
            state: {
                let mut st = state_from(&lines, game_dir, alsoft_files.first());
                (st.dsoal_version, st.openal_version) = versions;
                st
            },
            alsoft_files,
        })
    }

    /// The speaker setup in the first generated alsoft.ini.
    pub fn speakers(&self) -> Option<Speakers> {
        self.alsoft_files
            .first()
            .and_then(|f| Speakers::from_alsoft(f))
    }

    /// The recorded settings that were set for a speaker layout the new setup
    /// doesn't fit (BioShock's 5.1 mode after switching to headphones), so
    /// changing the speakers puts them back. The rule is the game's current
    /// profile's, found by title.
    pub fn settings_for_other_speakers(
        &self,
        game: &Game,
        speakers: &Speakers,
        include_untested: bool,
    ) -> Vec<RevertGroup> {
        let rows = game_settings::rows(game, include_untested);
        let has_headphones = rows
            .iter()
            .any(|r| r.speakers.iter().any(|v| v == "headphones"));
        self.settings
            .iter()
            .filter(|g| {
                // The last row with a rule decides, as in the script.
                let rule = rows
                    .iter()
                    .rfind(|r| r.title == g.title && !r.speakers.is_empty());
                rule.is_some_and(|r| !speakers.matches(&r.speakers, has_headphones))
            })
            .cloned()
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use crate::engine::speakers::{Layout, Listening};

    fn touch(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn reads_an_install_and_picks_the_settings_a_new_layout_drops() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path().join("home");
        let lib = tmp.path().join("lib/steamapps");
        touch(
            &lib.join("appmanifest_7670.acf"),
            "\"AppState\"\n{\n\t\"name\"\t\t\"BioShock\"\n\t\"installdir\"\t\t\"BioShock\"\n}\n",
        );
        let game = lib.join("common/BioShock/Builds/Release");
        let pfx = tmp.path().join("compatdata/7670/pfx");
        touch(&game.join("alsoft.ini"), "[general]\nchannels=surround51\n");
        touch(&pfx.join("drive_c/windows/syswow64/dsound.dll"), "x");
        let elsewhere = tmp.path().join("Other/alsoft.ini");
        touch(&elsewhere, "[general]\nchannels=quad\n");
        let g = game.display();
        touch(
            &game.join(manifest::FILE_NAME),
            &format!(
                "{}\n{g}/dsound.dll\n{p}/drive_c/windows/syswow64/dsound.dll\n{e}\n{g}/../x/alsoft.ini\n{g}/alsoft.ini\n\
                 CONFIG:audio\tSet 5.1\t{g}/a.ini\tini\tS\tSpeakers\t2\t6\n\
                 CONFIG:extras\tShow FPS\t{g}/a.ini\tini\tS\tFps\t0\t1\n",
                manifest::HEADER,
                p = pfx.display(),
                e = elsewhere.display()
            ),
        );
        let i = Installed::read(&game, &home).unwrap();
        assert_eq!(i.identified.as_ref().unwrap().id, "7670");
        assert_eq!(i.install_root, lib.join("common/BioShock"));
        assert_eq!(i.alsoft_files, vec![game.join("alsoft.ini")]);
        assert_eq!(i.prefix.as_deref(), Some(pfx.as_path()));
        assert_eq!(i.speakers(), Some(Speakers::surround(Layout::Surround51)));
        assert_eq!(
            i.state,
            InstalledState {
                engine: Engine::Dsoal,
                over: OverrideKind::Manual,
                arch: Some(32),
                vcrun: false,
                com_routing: false,
                eax_unified: false,
                advanced_limits: false,
                dsoal_version: None,
                openal_version: None,
            }
        );
        let titles: Vec<_> = i
            .settings
            .iter()
            .map(|s| (s.category.as_str(), s.title.as_str()))
            .collect();
        assert_eq!(titles, [("audio", "Set 5.1"), ("optional", "Show FPS")]);

        let db = Database::parse(
            r#"{"games":[{"id":"b","name":"BioShock","game_config":{
              "files":{"a.ini":{"format":"ini","locations":["game_exe:a.ini"]}},
              "audio_settings":[{"title":"Set 5.1","reason":"r","tested":true,
                "only_if":{"speakers":["surround51"]},"changes":{"a.ini":{"S":{"Speakers":"6"}}}}],
              "optional_settings":[{"title":"Show FPS","reason":"r","tested":true,
                "changes":{"a.ini":{"S":{"Fps":"1"}}}}]}}]}"#,
        )
        .unwrap();
        let phones = Speakers::stereo(Listening::Headphones, true);
        let drop = i.settings_for_other_speakers(&db.games[0], &phones, false);
        assert_eq!(drop.len(), 1);
        assert_eq!(drop[0].title, "Set 5.1");
        let same = Speakers::surround(Layout::Surround51);
        assert!(i
            .settings_for_other_speakers(&db.games[0], &same, false)
            .is_empty());

        std::fs::write(
            game.join(manifest::FILE_NAME),
            manifest::uninstalled_marker("x"),
        )
        .unwrap();
        assert!(Installed::read(&game, &home).is_none());
    }
}
