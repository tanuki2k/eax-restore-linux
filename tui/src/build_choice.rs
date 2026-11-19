//! The DSOAL and OpenAL Soft build choices, as the game page and the settings
//! screen list them: "Latest", which fetches whatever is newest when the
//! install runs, then every numbered build kcat has published, newest first,
//! each of which installs exactly that build. Each option has a key
//! ("numbered", or the version itself) that stays the same when the list is
//! filled in from GitHub.

use crate::engine::builds::{self, Build, Cache, Catalog, Net, Pins};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Comp {
    Dsoal,
    Openal,
}

/// No longer offered (kcat's untested rolling builds); a saved "rolling"
/// reads as Latest.
pub const ROLLING: &str = "rolling";
pub const NUMBERED: &str = "numbered";
/// No longer offered; a saved "tested" reads as Latest.
pub const TESTED: &str = "tested";
/// Only on an installed game: leave its files as they are.
pub const KEEP: &str = "keep";

/// What GitHub (or, offline, the cache) says is there: the builds to list.
#[derive(Debug, Clone, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct BuildInfo {
    pub catalog: Catalog,
    /// When it was read from GitHub, in seconds since 1970.
    pub fetched_at: u64,
    /// GitHub couldn't be read and nothing was saved: the lists hold only
    /// builds already downloaded.
    #[serde(skip)]
    pub offline: bool,
}

/// How long a saved lookup is used before GitHub is asked again. GitHub
/// answers 60 API requests an hour from a machine that isn't logged in, and
/// a lookup takes about five, so asking on every page open ran out quickly.
pub const FRESH_SECS: u64 = 60 * 60;

/// Where the last lookup is kept, beside the downloaded builds.
pub fn saved_path(home: &std::path::Path) -> PathBuf {
    Cache::new(home).root.join("build-lists.json")
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

fn load_saved(home: &std::path::Path) -> Option<BuildInfo> {
    let text = std::fs::read_to_string(saved_path(home)).ok()?;
    serde_json::from_str(&text).ok()
}

fn save(home: &std::path::Path, info: &BuildInfo) {
    let path = saved_path(home);
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if let Ok(text) = serde_json::to_string_pretty(info) {
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, text).is_ok() {
            let _ = std::fs::rename(&tmp, &path);
        }
    }
}

/// The build lists: the saved lookup while it's under an hour old, else a
/// fresh one from GitHub (saved for next time), else the saved one however
/// old, else only the builds already downloaded.
pub fn load(home: &std::path::Path, net: &mut dyn Net, at: u64) -> BuildInfo {
    let saved = load_saved(home);
    if let Some(s) = saved
        .as_ref()
        .filter(|s| at.saturating_sub(s.fetched_at) < FRESH_SECS)
    {
        return s.clone();
    }
    let cache = Cache::new(home);
    if net.reachable() {
        let dsoal: Vec<builds::Release> = builds::dsoal_archive(net)
            .into_iter()
            .map(|a| builds::Release {
                tag: a.rev,
                date: a.date,
            })
            .collect();
        let openal = builds::openal_releases(net);
        // Both lists back means GitHub answered; a refusal (its hourly limit)
        // or no network gives empty ones, which aren't worth saving.
        if !dsoal.is_empty() && !openal.is_empty() {
            let info = BuildInfo {
                catalog: Catalog { dsoal, openal },
                fetched_at: at,
                offline: false,
            };
            save(home, &info);
            return info;
        }
    }
    if let Some(s) = saved {
        return s;
    }
    BuildInfo {
        catalog: builds::catalog(&cache, net, false),
        offline: true,
        ..BuildInfo::default()
    }
}

/// Looks it all up on a thread of its own, without downloading any build.
pub fn spawn(home: PathBuf) -> Receiver<BuildInfo> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut net = builds::Curl::default();
        let _ = tx.send(load(&home, &mut net, now()));
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
    let mut out = vec![opt(
        NUMBERED,
        "Latest".into(),
        match comp {
            Comp::Dsoal => "The newest DSOAL build at the time you install.",
            Comp::Openal => "The newest OpenAL Soft build at the time you install.",
        }
        .into(),
    )];
    if i.offline {
        // Nothing from GitHub and nothing saved: say why the list is short.
        for o in &mut out {
            o.help
                .push_str(" Couldn't reach GitHub, so only downloaded builds are listed.");
        }
    }
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
        (_, ROLLING | NUMBERED) => Build::Numbered,
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
            ..BuildInfo::default()
        }
    }

    #[test]
    fn latest_then_every_build_newest_first() {
        let info = info();
        let labels = |c| -> Vec<String> {
            options(c, Some(&info), None)
                .into_iter()
                .map(|o| o.label)
                .collect()
        };
        assert_eq!(labels(Comp::Dsoal), ["Latest", "DSOAL r697", "DSOAL r696"]);
        assert_eq!(labels(Comp::Openal), ["Latest", "OpenAL Soft 1.25.2"]);
        // Under each: when it came out, or nothing when that isn't known.
        let helps: Vec<String> = options(Comp::Dsoal, Some(&info), None)
            .into_iter()
            .skip(1)
            .map(|o| o.help)
            .collect();
        assert_eq!(helps, ["Released on 2026-11-17.", ""]);
        assert_eq!(
            options(Comp::Openal, Some(&info), None)[1].help,
            "Released on 2026-05-12."
        );
        // Before the list arrives: Latest, which needs no list, plus a saved
        // version so the choice isn't lost.
        let keys: Vec<String> = options(Comp::Dsoal, None, Some("r650"))
            .into_iter()
            .map(|o| o.key)
            .collect();
        assert_eq!(keys, [NUMBERED, "r650"]);
    }

    /// A network that answers from canned pages, counts the requests, and
    /// downloads nothing.
    struct Net2 {
        pages: Vec<(&'static str, String)>,
        asked: usize,
    }

    impl Net for Net2 {
        fn reachable(&mut self) -> bool {
            true
        }
        fn get(&mut self, url: &str) -> String {
            self.asked += 1;
            self.pages
                .iter()
                .find(|(u, _)| *u == url)
                .map(|(_, b)| b.clone())
                .unwrap_or_default()
        }
        fn location(&mut self, _: &str) -> String {
            String::new()
        }
        fn download(&mut self, _: &str, _: &std::path::Path) -> bool {
            false
        }
    }

    fn github() -> Net2 {
        Net2 {
            pages: vec![
                (
                    builds::DSOAL_ARCHIVE_API_URL,
                    r#"{"assets":[{"name":"DSOAL_r697.zip","browser_download_url":"u","updated_at":"2026-11-17T00:00:00Z"}]}"#.into(),
                ),
                (
                    builds::OPENAL_RELEASES_API_URL,
                    r#"[{"tag_name":"1.25.2","prerelease":false,"published_at":"2026-05-12T00:00:00Z","assets":[{"name":"openal-soft-1.25.2-bin.zip"}]}]"#.into(),
                ),
            ],
            asked: 0,
        }
    }

    #[test]
    fn the_lists_are_asked_for_once_an_hour_and_kept_when_github_refuses() {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        // First look: from GitHub, and saved.
        let mut net = github();
        let first = load(home, &mut net, 1_000);
        assert_eq!(first.catalog.dsoal[0].tag, "r697");
        assert!(net.asked > 0 && saved_path(home).is_file());

        // Within the hour: the saved lists, without asking GitHub.
        let mut net = github();
        assert_eq!(load(home, &mut net, 1_000 + FRESH_SECS - 1), first);
        assert_eq!(net.asked, 0);

        // Later, with GitHub refusing (empty answers): still the saved lists.
        let mut refused = Net2 {
            pages: Vec::new(),
            asked: 0,
        };
        let later = load(home, &mut refused, 1_000 + FRESH_SECS * 3);
        assert_eq!(later.catalog, first.catalog);
        assert!(!later.offline);

        // Nothing saved and GitHub refusing: the downloaded builds, said so.
        let empty = tempfile::tempdir().unwrap();
        let none = load(empty.path(), &mut refused, 0);
        assert!(none.offline && none.catalog.dsoal.is_empty());
        let help = &options(Comp::Dsoal, Some(&none), None)[0].help;
        assert!(help.ends_with("Couldn't reach GitHub, so only downloaded builds are listed."));
    }

    #[test]
    fn each_key_installs_its_build() {
        assert_eq!(to_build(Comp::Dsoal, ROLLING, None), Build::Numbered);
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
