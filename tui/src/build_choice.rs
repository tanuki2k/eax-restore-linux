//! The DSOAL and OpenAL Soft build choices, as the game page and the settings
//! screen list them: two that always fetch the newest build when it installs,
//! then every numbered build kcat has published, newest first.
//! Each option has a key ("rolling", "numbered", or the version
//! itself) that stays the same when the list is filled in from GitHub.

use crate::engine::builds::{self, Build, Cache, Catalog, Net, Pins};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Comp {
    Dsoal,
    Openal,
}

pub const ROLLING: &str = "rolling";
pub const NUMBERED: &str = "numbered";
/// No longer offered; a saved "tested" reads as Latest numbered.
pub const TESTED: &str = "tested";
/// Only on an installed game: leave its files as they are.
pub const KEEP: &str = "keep";

/// What GitHub (or, offline, the cache) says is there: the builds to list,
/// and the versions the "Latest" options stand for right now.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BuildInfo {
    pub catalog: Catalog,
    /// latest-master's revision, e.g. `r697`.
    pub dsoal_rolling: String,
    /// The pre-release's version and date, e.g. `1.25.2 (2026-11-15)`.
    pub openal_rolling: String,
    /// The newest numbered OpenAL Soft release, e.g. `1.25.2`.
    pub openal_numbered: String,
}

/// Looks it all up on a thread of its own, without downloading any build.
pub fn spawn(home: PathBuf) -> Receiver<BuildInfo> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let cache = Cache::new(&home);
        let mut net = builds::Curl::default();
        let github = net.reachable();
        let v = builds::lookup(&cache, &mut net, github, &Pins::default());
        let catalog = builds::catalog(&cache, &mut net, github);
        let _ = tx.send(BuildInfo {
            catalog,
            dsoal_rolling: v.dsoal_latest,
            openal_rolling: v.oal_latest,
            openal_numbered: v.oal_stable,
        });
    });
    rx
}

/// One option: its key, its label, and the line that explains it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuildOpt {
    pub key: String,
    pub label: String,
    pub help: String,
}

fn with_version(name: &str, version: &str) -> String {
    if version.is_empty() || version == "cached" {
        return name.to_string();
    }
    // "1.25.2 (2026-11-15)" reads as "1.25.2, 2026-11-15" inside brackets.
    let version = match version.strip_suffix(')').and_then(|v| v.split_once(" (")) {
        Some((v, date)) => format!("{v}, {date}"),
        None => version.to_string(),
    };
    format!("{name} ({version})")
}

/// The options for one component, in order. `also` is a version that must be
/// listed even when the catalog doesn't have it (a saved default, before the
/// list has arrived or while offline).
pub fn options(comp: Comp, info: Option<&BuildInfo>, also: Option<&str>) -> Vec<BuildOpt> {
    let opt = |key: &str, label: String, help: String| BuildOpt {
        key: key.to_string(),
        label,
        help,
    };
    let empty = BuildInfo::default();
    let i = info.unwrap_or(&empty);
    let mut out = match comp {
        Comp::Dsoal => vec![
            opt(
                ROLLING,
                with_version("Latest rolling", &i.dsoal_rolling),
                "kcat's newest DSOAL build, fetched when you install. It may not have been tested yet.".into(),
            ),
            opt(
                NUMBERED,
                with_version(
                    "Latest numbered",
                    i.catalog.dsoal.first().map_or("", |r| r.tag.as_str()),
                ),
                "The highest-numbered DSOAL build at the time you install.".into(),
            ),
        ],
        Comp::Openal => vec![
            opt(
                ROLLING,
                with_version("Latest rolling", &i.openal_rolling),
                "kcat's newest OpenAL Soft build, fetched when you install. It may not have been tested yet.".into(),
            ),
            opt(
                NUMBERED,
                with_version("Latest numbered", &i.openal_numbered),
                "The newest numbered OpenAL Soft release at the time you install.".into(),
            ),
        ],
    };
    // Each numbered build: its name and version, and under it when it came out.
    let name = match comp {
        Comp::Dsoal => "DSOAL",
        Comp::Openal => "OpenAL Soft",
    };
    let released = |date: &str| {
        if date.is_empty() {
            String::new()
        } else {
            format!("Released on {date}.")
        }
    };
    let listed = match comp {
        Comp::Dsoal => &i.catalog.dsoal,
        Comp::Openal => &i.catalog.openal,
    };
    for r in listed {
        out.push(opt(&r.tag, format!("{name} {}", r.tag), released(&r.date)));
    }
    if let Some(v) = also.filter(|v| builds::safe_name(v)) {
        if !out.iter().any(|o| o.key == v) {
            out.push(opt(v, format!("{name} {v}"), String::new()));
        }
    }
    out
}

/// The "Keep the installed one" option for a game that has the fix, naming
/// the version it has when its manifest recorded one.
pub fn keep_option(comp: Comp, installed: Option<&str>) -> BuildOpt {
    let name = match comp {
        Comp::Dsoal => "DSOAL",
        Comp::Openal => "OpenAL Soft",
    };
    BuildOpt {
        key: KEEP.into(),
        label: "Keep the installed one".into(),
        help: match installed {
            Some(v) => format!("Keeps {name} {v}, which is in the game now."),
            None => "Leaves the files in the game as they are.".into(),
        },
    }
}

/// What an option's key installs. "Keep" with a version recorded installs
/// that version again if something else needs a reinstall; without one, the
/// newest numbered one.
pub fn to_build(comp: Comp, key: &str, installed: Option<&str>) -> Build {
    match (comp, key) {
        (_, ROLLING) => Build::Latest,
        (_, NUMBERED) => Build::Numbered,
        (Comp::Dsoal, TESTED) => Build::Stable,
        (Comp::Openal, TESTED) => Build::Exact(Pins::default().openal_tag),
        (_, KEEP) => match installed.filter(|v| builds::safe_name(v)) {
            Some(v) => Build::Exact(v.to_string()),
            None => Build::Numbered,
        },
        (_, v) => Build::Exact(v.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::builds::Release;

    fn info() -> BuildInfo {
        BuildInfo {
            catalog: Catalog {
                dsoal: vec![
                    Release {
                        tag: "r697".into(),
                        date: "2026-11-17".into(),
                    },
                    "r696".into(),
                ],
                openal: vec![Release {
                    tag: "1.25.2".into(),
                    date: "2026-05-12".into(),
                }],
            },
            dsoal_rolling: "r697".into(),
            openal_rolling: "1.25.2 (2026-11-15)".into(),
            openal_numbered: "1.25.2".into(),
        }
    }

    #[test]
    fn the_latest_two_then_every_build_newest_first() {
        let info = info();
        let labels = |c| -> Vec<String> {
            options(c, Some(&info), None)
                .into_iter()
                .map(|o| o.label)
                .collect()
        };
        assert_eq!(
            labels(Comp::Dsoal),
            [
                "Latest rolling (r697)",
                "Latest numbered (r697)",
                "DSOAL r697",
                "DSOAL r696"
            ]
        );
        assert_eq!(
            labels(Comp::Openal),
            [
                "Latest rolling (1.25.2, 2026-11-15)",
                "Latest numbered (1.25.2)",
                "OpenAL Soft 1.25.2"
            ]
        );
        // Under each: when it came out, or nothing when that isn't known.
        let helps: Vec<String> = options(Comp::Dsoal, Some(&info), None)
            .into_iter()
            .skip(2)
            .map(|o| o.help)
            .collect();
        assert_eq!(helps, ["Released on 2026-11-17.", ""]);
        assert_eq!(
            options(Comp::Openal, Some(&info), None)[2].help,
            "Released on 2026-05-12."
        );
        // Before the list arrives: the two that need no list, plus a saved
        // version so the choice isn't lost.
        let keys: Vec<String> = options(Comp::Dsoal, None, Some("r650"))
            .into_iter()
            .map(|o| o.key)
            .collect();
        assert_eq!(keys, [ROLLING, NUMBERED, "r650"]);
    }

    #[test]
    fn each_key_installs_its_build() {
        assert_eq!(to_build(Comp::Dsoal, ROLLING, None), Build::Latest);
        assert_eq!(to_build(Comp::Dsoal, NUMBERED, None), Build::Numbered);
        assert_eq!(to_build(Comp::Dsoal, TESTED, None), Build::Stable);
        assert_eq!(
            to_build(Comp::Openal, TESTED, None),
            Build::Exact(Pins::default().openal_tag)
        );
        assert_eq!(
            to_build(Comp::Openal, "1.24.3", None),
            Build::Exact("1.24.3".into())
        );
        assert_eq!(
            to_build(Comp::Dsoal, KEEP, Some("r690")),
            Build::Exact("r690".into())
        );
        // A rolling label isn't a version to fetch again: the newest numbered.
        assert_eq!(
            to_build(Comp::Openal, KEEP, Some("1.25.2 (2026-11-15)")),
            Build::Numbered
        );
    }
}
