//! Getting DSOAL and OpenAL Soft into this program's own cache, never the
//! game or prefix. A port of the download half of `src/cache.sh` and of
//! `src/verify.sh`. Each component has two builds:
//!
//! - DSOAL stable: a pinned, tested revision from kcat's "archive" release,
//!   checked against its SHA256 ([`Pins`]).
//! - DSOAL latest: kcat's latest-master, or the newest archived build while
//!   latest-master is missing upstream.
//! - OpenAL Soft stable: the newest tagged release.
//! - OpenAL Soft latest: its rolling "latest" pre-release.
//!
//! A build is fetched only when it's missing or out of date (a marker file
//! records what's cached), checked (zip test, then the pinned SHA256 or the
//! digest GitHub publishes), and swapped in only once it unpacked, so a
//! failed download keeps the cached build. The network goes through [`Net`]
//! (curl, as in the script); unpacking uses `unzip`, which it needs too.

use serde_json::Value;
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// The pinned stable DSOAL build. Advancing it after testing a newer
/// archive build is part of the release routine.
#[derive(Debug, Clone)]
pub struct Pins {
    pub dsoal_rev: String,
    pub dsoal_url: String,
    pub dsoal_sha256: String,
}

impl Default for Pins {
    /// The script's `DSOAL_PINNED_*` in `src/globals.sh`.
    fn default() -> Self {
        Pins {
            dsoal_rev: "r693".into(),
            dsoal_url: "https://github.com/kcat/dsoal/releases/download/archive/DSOAL_r693.zip"
                .into(),
            dsoal_sha256: "5abe990ff5692fa070d549a8c28df2435842c5d3f586a59b0da5281bc1cb6605".into(),
        }
    }
}

pub const DSOAL_OFFICIAL_URL: &str =
    "https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip";
pub const DSOAL_OFFICIAL_API_URL: &str =
    "https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master";
pub const DSOAL_ARCHIVE_API_URL: &str =
    "https://api.github.com/repos/kcat/dsoal/releases/tags/archive";
pub const OPENAL_LATEST_RELEASE_URL: &str = "https://github.com/kcat/openal-soft/releases/latest";
pub const OPENAL_PRERELEASE_API_URL: &str =
    "https://api.github.com/repos/kcat/openal-soft/releases/tags/latest";
pub const GITHUB_PROBE_URL: &str = "https://api.github.com";

/// The cache folders, under `~/.local/share/eax-restore-linux`.
#[derive(Debug, Clone)]
pub struct Cache {
    pub root: PathBuf,
}

impl Cache {
    pub fn new(home: &Path) -> Self {
        Cache {
            root: home.join(".local/share/eax-restore-linux"),
        }
    }
    pub fn dsoal(&self) -> PathBuf {
        self.root.join("dsoal")
    }
    pub fn dsoal_official(&self) -> PathBuf {
        self.dsoal().join("official")
    }
    pub fn dsoal_pinned(&self) -> PathBuf {
        self.dsoal().join("pinned")
    }
    pub fn openal(&self) -> PathBuf {
        self.root.join("openal-soft")
    }
    pub fn openal_official(&self) -> PathBuf {
        self.openal().join("official")
    }
    pub fn openal_prerelease(&self) -> PathBuf {
        self.openal().join("prerelease")
    }
}

/// A folder that exists and isn't empty.
pub fn cached(dir: &Path) -> bool {
    std::fs::read_dir(dir).is_ok_and(|mut d| d.next().is_some())
}

/// A marker file's text as `$(cat …)` gives it: trailing line breaks gone.
fn read_marker(path: &Path) -> String {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .trim_end_matches('\n')
        .to_string()
}

/// The network, as the script uses curl.
pub trait Net {
    /// Whether GitHub answers at all.
    fn reachable(&mut self) -> bool;
    /// A page's body; empty when it fails (`curl -fs`).
    fn get(&mut self, url: &str) -> String;
    /// The `Location:` a URL redirects to, without following it.
    fn location(&mut self, url: &str) -> String;
    /// Downloads to `dest`; false when it fails.
    fn download(&mut self, url: &str, dest: &Path) -> bool;
}

/// [`Net`] through the curl program, with the script's options.
pub struct Curl {
    pub program: PathBuf,
}

impl Default for Curl {
    fn default() -> Self {
        Curl {
            program: PathBuf::from("curl"),
        }
    }
}

impl Curl {
    fn run(&self, args: &[&str]) -> (bool, String) {
        match Command::new(&self.program)
            .args(args)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        {
            Ok(o) => (
                o.status.success(),
                String::from_utf8_lossy(&o.stdout).into_owned(),
            ),
            Err(_) => (false, String::new()),
        }
    }
}

impl Net for Curl {
    fn reachable(&mut self) -> bool {
        self.run(&["-s", "-o", "/dev/null", "-m", "10", GITHUB_PROBE_URL])
            .0
    }
    fn get(&mut self, url: &str) -> String {
        self.run(&["-fs", "--connect-timeout", "10", "--max-time", "30", url])
            .1
    }
    fn location(&mut self, url: &str) -> String {
        let (_, head) = self.run(&["-sI", "--connect-timeout", "10", "--max-time", "30", url]);
        head.lines()
            .filter(|l| l.len() >= 9 && l[..9].eq_ignore_ascii_case("location:"))
            .map(|l| {
                l.rsplit('/')
                    .next()
                    .unwrap_or("")
                    .trim_end_matches('\r')
                    .to_string()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
    fn download(&mut self, url: &str, dest: &Path) -> bool {
        let _ = std::fs::remove_file(dest);
        let dest = dest.to_string_lossy();
        self.run(&[
            "-fsSL",
            "--connect-timeout",
            "15",
            "--speed-limit",
            "1000",
            "--speed-time",
            "30",
            url,
            "-o",
            &dest,
        ])
        .0
    }
}

fn unzip(args: &[&std::ffi::OsStr]) -> bool {
    Command::new("unzip")
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success())
}

/// `unzip -tq`: the archive reads back whole.
pub fn zip_ok(zip: &Path) -> bool {
    unzip(&["-tq".as_ref(), zip.as_os_str()])
}

fn unzip_into(zip: &Path, dir: &Path) -> bool {
    unzip(&[
        "-q".as_ref(),
        zip.as_os_str(),
        "-d".as_ref(),
        dir.as_os_str(),
    ])
}

fn sibling(dir: &Path, suffix: &str) -> PathBuf {
    let mut s = dir.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

fn fresh_dir(dir: &Path) {
    let _ = std::fs::remove_dir_all(dir);
    let _ = std::fs::create_dir_all(dir);
}

/// Unpacks into a sibling folder and swaps it in only when that worked, so a
/// full disk or an interrupt can't leave a half-filled cache that the marker
/// then calls up to date. The zip stays.
pub fn extract_zip_into(zip: &Path, dir: &Path) -> bool {
    let tmp = sibling(dir, ".new");
    fresh_dir(&tmp);
    if !unzip_into(zip, &tmp) {
        let _ = std::fs::remove_dir_all(&tmp);
        return false;
    }
    let _ = std::fs::remove_dir_all(dir);
    std::fs::rename(&tmp, dir).is_ok()
}

/// Like [`extract_zip_into`], for kcat's DSOAL zips, which sometimes wrap
/// their contents in a further `DSOAL_*.zip`. The zip is deleted either way.
pub fn unpack_dsoal_zip(zip: &Path, dir: &Path) -> bool {
    let tmp = sibling(dir, ".new");
    fresh_dir(&tmp);
    let fail = |tmp: &Path| {
        let _ = std::fs::remove_dir_all(tmp);
        let _ = std::fs::remove_file(zip);
        false
    };
    if !unzip_into(zip, &tmp) {
        return fail(&tmp);
    }
    let nested = std::fs::read_dir(&tmp).ok().and_then(|d| {
        d.flatten().map(|e| e.path()).find(|p| {
            let n = p
                .file_name()
                .map(|n| n.to_string_lossy())
                .unwrap_or_default();
            n.starts_with("DSOAL_") && n.ends_with(".zip")
        })
    });
    if let Some(nested) = nested.filter(|n| zip_ok(n)) {
        if !unzip_into(&nested, &tmp) {
            return fail(&tmp);
        }
    }
    let _ = std::fs::remove_dir_all(dir);
    let moved = std::fs::rename(&tmp, dir).is_ok();
    let _ = std::fs::remove_file(zip);
    moved
}

pub fn sha256_of(path: &Path) -> Option<String> {
    let data = std::fs::read(path).ok()?;
    Some(format!("{:x}", Sha256::digest(&data)))
}

/// The SHA256 GitHub publishes for a named asset in a release's JSON, or
/// empty when there's none.
pub fn asset_digest(release_json: &str, asset: &str) -> String {
    let Ok(v) = serde_json::from_str::<Value>(release_json) else {
        return String::new();
    };
    let assets = v
        .get("assets")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    assets
        .iter()
        .filter(|a| a.get("name").and_then(Value::as_str) == Some(asset))
        .filter_map(|a| a.get("digest").and_then(Value::as_str))
        .filter_map(|d| d.strip_prefix("sha256:"))
        .collect::<Vec<_>>()
        .join("\n")
}

/// What one checksum check came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verified {
    Matched,
    /// A mismatch: (expected, actual).
    Mismatch(String, String),
    /// No digest was published, and the player was asked.
    Unverified {
        accepted: bool,
    },
}

impl Verified {
    pub fn ok(&self) -> bool {
        matches!(
            self,
            Verified::Matched | Verified::Unverified { accepted: true }
        )
    }
}

/// Checks a download against a digest when there is one; without one, asks
/// `confirm` (given the build's name) whether to install it unchecked.
pub fn verify_or_confirm(
    file: &Path,
    digest: &str,
    label: &str,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Verified {
    if digest.is_empty() {
        return Verified::Unverified {
            accepted: confirm(label),
        };
    }
    let actual = sha256_of(file).unwrap_or_default();
    if actual == digest {
        Verified::Matched
    } else {
        Verified::Mismatch(digest.to_string(), actual)
    }
}

/// kcat's newest archived DSOAL build.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Archive {
    /// `r695`.
    pub rev: String,
    pub url: String,
    /// GitHub's SHA256 for it; empty when it has none.
    pub digest: String,
}

/// The newest `DSOAL_r<N>.zip` in kcat's "archive" release.
pub fn newest_archive_dsoal(net: &mut dyn Net) -> Option<Archive> {
    let json = net.get(DSOAL_ARCHIVE_API_URL);
    let v: Value = serde_json::from_str(&json).ok()?;
    let assets = v.get("assets").and_then(Value::as_array)?;
    assets
        .iter()
        .filter_map(|a| {
            let name = a.get("name")?.as_str()?;
            let n = name.strip_prefix("DSOAL_r")?.strip_suffix(".zip")?;
            if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let rev: u64 = n.parse().ok()?;
            let digest = a.get("digest").and_then(Value::as_str).unwrap_or("");
            Some((
                rev,
                Archive {
                    rev: format!("r{rev}"),
                    url: a.get("browser_download_url")?.as_str()?.to_string(),
                    digest: digest.strip_prefix("sha256:").unwrap_or(digest).to_string(),
                },
            ))
        })
        // The last of the highest revision, as jq's sort_by | last.
        .fold(None::<(u64, Archive)>, |best, (rev, a)| match best {
            Some((b, _)) if b > rev => best,
            _ => Some((rev, a)),
        })
        .map(|(_, a)| a)
        .filter(|a| !a.rev.is_empty() && !a.url.is_empty())
}

/// What's available this run, looked up without downloading anything: the
/// labels a build choice shows (empty when it can't be had: offline and not
/// cached), and what the downloads need from the release pages.
#[derive(Debug, Clone, Default)]
pub struct Versions {
    pub github: bool,
    pub dsoal_stable: String,
    pub dsoal_latest: String,
    pub oal_stable: String,
    pub oal_latest: String,
    dsoal_json: String,
    /// latest-master's `updated_at`; empty when it's missing upstream.
    dsoal_date: String,
    archive: Option<Archive>,
    oal_tag: String,
    oal_prerelease_json: String,
}

fn first_rev(name: &str) -> Option<String> {
    let b = name.as_bytes();
    (0..b.len()).find_map(|i| {
        if b[i] != b'r' {
            return None;
        }
        let digits = b[i + 1..].iter().take_while(|c| c.is_ascii_digit()).count();
        (digits > 0).then(|| name[i..i + 1 + digits].to_string())
    })
}

/// The prerelease's version label: "1.24.3 (2026-05-01)".
fn prerelease_label(json: &str) -> String {
    let Ok(v) = serde_json::from_str::<Value>(json) else {
        return String::new();
    };
    let name = v.get("name").and_then(Value::as_str).unwrap_or("");
    let version = name.strip_prefix("OpenAL Soft v").unwrap_or(name);
    if version.is_empty() {
        return String::new();
    }
    v.get("assets")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .find(|a| a.get("name").and_then(Value::as_str) == Some("OpenALSoft.zip"))
        .and_then(|a| match a.get("updated_at") {
            Some(Value::String(d)) => Some(d.get(..10).unwrap_or(d).to_string()),
            // jq prints a missing date as null.
            Some(Value::Null) | None => Some("null".to_string()),
            Some(_) => None,
        })
        .map(|d| format!("{version} ({d})"))
        .unwrap_or_default()
}

/// `lookup_build_versions`.
pub fn lookup(cache: &Cache, net: &mut dyn Net, github: bool, pins: &Pins) -> Versions {
    let mut v = Versions {
        github,
        ..Versions::default()
    };
    if github || cached(&cache.dsoal_pinned()) {
        v.dsoal_stable = pins.dsoal_rev.clone();
    }
    if github {
        v.dsoal_json = net.get(DSOAL_OFFICIAL_API_URL);
        let j: Value = serde_json::from_str(&v.dsoal_json).unwrap_or(Value::Null);
        v.dsoal_date = j
            .get("updated_at")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if !v.dsoal_date.is_empty() {
            let name = j.get("name").and_then(Value::as_str).unwrap_or("");
            v.dsoal_latest = first_rev(name)
                .unwrap_or_else(|| v.dsoal_date.split('T').next().unwrap_or("").to_string());
        } else if let Some(a) = newest_archive_dsoal(net) {
            v.dsoal_latest = a.rev.clone();
            v.archive = Some(a);
        }
    }
    if v.dsoal_latest.is_empty() && cached(&cache.dsoal_official()) {
        let marker = read_marker(&cache.dsoal().join("updated_at.txt"));
        let label = marker.strip_prefix("archive-").unwrap_or(&marker);
        let label = label.split('T').next().unwrap_or("");
        v.dsoal_latest = if label.is_empty() {
            "cached".into()
        } else {
            label.to_string()
        };
    }
    if github {
        v.oal_tag = net.location(OPENAL_LATEST_RELEASE_URL);
        v.oal_stable = v.oal_tag.clone();
        v.oal_prerelease_json = net.get(OPENAL_PRERELEASE_API_URL);
        v.oal_latest = prerelease_label(&v.oal_prerelease_json);
    }
    if v.oal_stable.is_empty() && cached(&cache.openal_official()) {
        let tag = read_marker(&cache.openal().join("updated_at.txt"));
        v.oal_stable = if tag.is_empty() { "cached".into() } else { tag };
    }
    if v.oal_latest.is_empty() && cached(&cache.openal_prerelease()) {
        let label = read_marker(&cache.openal_prerelease().join(".version"))
            .lines()
            .nth(1)
            .unwrap_or("")
            .to_string();
        v.oal_latest = if label.is_empty() {
            "cached".into()
        } else {
            label
        };
    }
    v
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Build {
    Stable,
    Latest,
}

/// What getting a build came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Got {
    UpToDate,
    Downloaded,
    /// Offline, or the release page couldn't be read: the cached build.
    Cached,
    /// The download failed, so the cached build is kept.
    KeptOld,
    /// It can't be had this run.
    Failed(Why),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Why {
    Offline,
    Download,
    Checksum(Verified),
    Unpack,
    NotPublished,
}

impl Got {
    pub fn usable(&self) -> bool {
        !matches!(self, Got::Failed(_))
    }
}

/// Downloads, tests and checks one zip; the reason it failed, if it did.
fn fetch_checked(
    net: &mut dyn Net,
    url: &str,
    zip: &Path,
    digest: impl FnOnce(&mut dyn Net) -> String,
    label: &str,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Result<(), Why> {
    if !net.download(url, zip) || !zip_ok(zip) {
        return Err(Why::Download);
    }
    let digest = digest(net);
    let v = verify_or_confirm(zip, &digest, label, confirm);
    if v.ok() {
        Ok(())
    } else {
        Err(Why::Checksum(v))
    }
}

/// `ensure_dsoal_build`.
pub fn ensure_dsoal(
    cache: &Cache,
    net: &mut dyn Net,
    v: &mut Versions,
    build: Build,
    pins: &Pins,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Got {
    let share = cache.dsoal();
    let _ = std::fs::create_dir_all(&share);
    if build == Build::Stable {
        if cached(&cache.dsoal_pinned()) {
            return Got::UpToDate;
        }
        if !v.github {
            return Got::Failed(Why::Offline);
        }
        let zip = share.join("pinned.zip");
        let mut why = Why::Download;
        if net.download(&pins.dsoal_url, &zip) && zip_ok(&zip) {
            // A frozen archive asset has a stable SHA256, so a mismatch
            // means the file is wrong: never asked about.
            let actual = sha256_of(&zip).unwrap_or_default();
            if actual == pins.dsoal_sha256 {
                if unpack_dsoal_zip(&zip, &cache.dsoal_pinned()) {
                    return Got::Downloaded;
                }
                why = Why::Unpack;
            } else {
                why = Why::Checksum(Verified::Mismatch(pins.dsoal_sha256.clone(), actual));
            }
        }
        let _ = std::fs::remove_file(&zip);
        let _ = std::fs::remove_dir_all(cache.dsoal_pinned());
        return Got::Failed(why);
    }

    let marker = share.join("updated_at.txt");
    let local = read_marker(&marker);
    if !v.github {
        return if cached(&cache.dsoal_official()) {
            Got::Cached
        } else {
            Got::Failed(Why::Offline)
        };
    }
    let zip = share.join("dsoal.zip");
    let result = if v.dsoal_date.is_empty() {
        // latest-master is missing upstream (kcat's nightly CI deletes it
        // before re-creating it): follow the newest archived build until it
        // is back. Its "archive-r<N>" marker never matches a real
        // latest-master date, so the next run that finds it switches back.
        if v.archive.is_none() {
            v.archive = newest_archive_dsoal(net);
        }
        let Some(a) = v.archive.clone() else {
            return if cached(&cache.dsoal_official()) {
                Got::Cached
            } else {
                Got::Failed(Why::NotPublished)
            };
        };
        let stamp = format!("archive-{}", a.rev);
        if local == stamp && cached(&cache.dsoal_official()) {
            return Got::UpToDate;
        }
        let label = format!("kcat archived DSOAL [{}]", a.rev);
        fetch_checked(net, &a.url, &zip, |_| a.digest.clone(), &label, confirm).map(|()| stamp)
    } else {
        if v.dsoal_date == local && cached(&cache.dsoal_official()) {
            return Got::UpToDate;
        }
        let label = format!("kcat DSOAL [{}]", v.dsoal_latest);
        let json = v.dsoal_json.clone();
        fetch_checked(
            net,
            DSOAL_OFFICIAL_URL,
            &zip,
            |_| asset_digest(&json, "DSOAL.zip"),
            &label,
            confirm,
        )
        .map(|()| v.dsoal_date.clone())
    };
    let why = match result {
        Ok(stamp) => {
            if unpack_dsoal_zip(&zip, &cache.dsoal_official()) {
                let _ = std::fs::write(&marker, format!("{stamp}\n"));
                return Got::Downloaded;
            }
            Why::Unpack
        }
        Err(why) => why,
    };
    let _ = std::fs::remove_file(&zip);
    if cached(&cache.dsoal_official()) {
        Got::KeptOld
    } else {
        Got::Failed(why)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PrereleaseAsset {
    url: String,
    digest: String,
    updated: String,
    version: String,
}

fn prerelease_asset(json: &str) -> Option<PrereleaseAsset> {
    let v: Value = serde_json::from_str(json).ok()?;
    let name = v.get("name").and_then(Value::as_str).unwrap_or("");
    let version = name
        .strip_prefix("OpenAL Soft v")
        .unwrap_or(name)
        .to_string();
    let a = v
        .get("assets")
        .and_then(Value::as_array)?
        .iter()
        .find(|a| a.get("name").and_then(Value::as_str) == Some("OpenALSoft.zip"))?;
    let text = |k: &str| match a.get(k) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Null) | None => "null".into(),
        Some(other) => other.to_string(),
    };
    let digest = a.get("digest").and_then(Value::as_str).unwrap_or("");
    Some(PrereleaseAsset {
        url: text("browser_download_url"),
        digest: digest.strip_prefix("sha256:").unwrap_or(digest).to_string(),
        updated: text("updated_at"),
        version,
    })
}

/// `ensure_openal_build`. The two builds are laid out differently: stable is
/// openal-soft-<v>-bin/bin/<Arch>/soft_oal.dll, the pre-release
/// <Arch>/OpenAL32.dll (see [`openal_source_dll`]).
pub fn ensure_openal(
    cache: &Cache,
    net: &mut dyn Net,
    v: &Versions,
    build: Build,
    confirm: &mut dyn FnMut(&str) -> bool,
) -> Got {
    let share = cache.openal();
    let _ = std::fs::create_dir_all(&share);
    if build == Build::Stable {
        let marker = share.join("updated_at.txt");
        let local = read_marker(&marker);
        let official = cache.openal_official();
        if !v.github || v.oal_tag.is_empty() {
            return if cached(&official) {
                Got::Cached
            } else {
                Got::Failed(Why::Offline)
            };
        }
        if v.oal_tag == local && cached(&official) {
            return Got::UpToDate;
        }
        let asset = format!("openal-soft-{}-bin.zip", v.oal_tag);
        let url = format!(
            "https://github.com/kcat/openal-soft/releases/download/{}/{asset}",
            v.oal_tag
        );
        let zip = share.join("openal.zip");
        let tag = v.oal_tag.clone();
        let label = format!("kcat OpenAL Soft [{tag}]");
        let fetched = fetch_checked(
            net,
            &url,
            &zip,
            |n| {
                let api =
                    format!("https://api.github.com/repos/kcat/openal-soft/releases/tags/{tag}");
                asset_digest(&n.get(&api), &asset)
            },
            &label,
            confirm,
        );
        let why = match fetched {
            Ok(()) if extract_zip_into(&zip, &official) => {
                let _ = std::fs::write(&marker, format!("{}\n", v.oal_tag));
                let _ = std::fs::remove_file(&zip);
                return Got::Downloaded;
            }
            Ok(()) => Why::Unpack,
            Err(why) => why,
        };
        let _ = std::fs::remove_file(&zip);
        return if cached(&official) {
            Got::KeptOld
        } else {
            Got::Failed(why)
        };
    }

    // The pre-release is rebuilt in place, so its marker is the asset's
    // upload time, plus the version to show.
    let pre = cache.openal_prerelease();
    let version_file = pre.join(".version");
    let local = read_marker(&version_file)
        .lines()
        .next()
        .unwrap_or("")
        .to_string();
    if !v.github || v.oal_prerelease_json.is_empty() {
        return if cached(&pre) {
            Got::Cached
        } else {
            Got::Failed(Why::Offline)
        };
    }
    let Some(a) = prerelease_asset(&v.oal_prerelease_json).filter(|a| !a.url.is_empty()) else {
        return if cached(&pre) {
            Got::Cached
        } else {
            Got::Failed(Why::NotPublished)
        };
    };
    if a.updated == local && cached(&pre) {
        return Got::UpToDate;
    }
    let zip = share.join("prerelease.zip");
    let label = format!("kcat OpenAL Soft pre-release [{}]", a.version);
    let digest = a.digest.clone();
    let why = match fetch_checked(net, &a.url, &zip, |_| digest, &label, confirm) {
        Ok(()) if extract_zip_into(&zip, &pre) => {
            let _ = std::fs::write(&version_file, format!("{}\n{}\n", a.updated, v.oal_latest));
            let _ = std::fs::remove_file(&zip);
            return Got::Downloaded;
        }
        Ok(()) => Why::Unpack,
        Err(why) => why,
    };
    let _ = std::fs::remove_file(&zip);
    if cached(&pre) {
        Got::KeptOld
    } else {
        Got::Failed(why)
    }
}

/// Folders under `root` whose path ends `<…>/<tail>`, ignoring case, in the
/// order `find` walks them (directory order, parents first).
fn find_dirs(root: &Path, tail: &[&str]) -> Vec<PathBuf> {
    fn walk(dir: &Path, tail: &[&str], out: &mut Vec<PathBuf>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for e in entries.flatten() {
            let p = e.path();
            if !e.file_type().is_ok_and(|t| t.is_dir()) {
                continue;
            }
            let parts: Vec<String> = p
                .components()
                .map(|c| c.as_os_str().to_string_lossy().to_lowercase())
                .collect();
            let n = tail.len();
            if parts.len() > n
                && parts[parts.len() - n..]
                    .iter()
                    .zip(tail)
                    .all(|(a, b)| *a == b.to_lowercase())
            {
                out.push(p.clone());
            }
            walk(&p, tail, out);
        }
    }
    let mut out = Vec::new();
    walk(root, tail, &mut out);
    out
}

/// Where the chosen DSOAL build's DLLs for an architecture (`Win32` /
/// `Win64`) are: the zip has DSOAL/<Arch> and DSOAL+HRTF/<Arch>, and the
/// plain one is preferred.
pub fn dsoal_source_dir(cache: &Cache, build: Build, arch: &str) -> Option<PathBuf> {
    let root = match build {
        Build::Stable => cache.dsoal_pinned(),
        Build::Latest => cache.dsoal_official(),
    };
    find_dirs(&root, &["DSOAL", arch])
        .into_iter()
        .next()
        .or_else(|| find_dirs(&root, &[arch]).into_iter().next())
}

/// The OpenAL Soft DLL to deploy for an architecture.
pub fn openal_source_dll(cache: &Cache, build: Build, arch: &str) -> PathBuf {
    match build {
        Build::Latest => cache.openal_prerelease().join(arch).join("OpenAL32.dll"),
        Build::Stable => {
            let dir = find_dirs(&cache.openal_official(), &["bin", arch])
                .into_iter()
                .next()
                .unwrap_or_default();
            PathBuf::from(format!("{}/soft_oal.dll", dir.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn revisions_in_a_release_name() {
        assert_eq!(
            first_rev("DSOAL r695 (latest-master)").as_deref(),
            Some("r695")
        );
        assert_eq!(first_rev("master build").as_deref(), None);
        assert_eq!(first_rev("rr12").as_deref(), Some("r12"));
    }

    #[test]
    fn digests() {
        let json = r#"{"assets":[{"name":"DSOAL.zip","digest":"sha256:abc"},{"name":"x","digest":"sha256:def"}]}"#;
        assert_eq!(asset_digest(json, "DSOAL.zip"), "abc");
        assert_eq!(asset_digest(json, "nope"), "");
        assert_eq!(asset_digest("not json", "x"), "");
    }

    #[test]
    fn prerelease_labels() {
        let json = r#"{"name":"OpenAL Soft v1.24.3","assets":[{"name":"OpenALSoft.zip","updated_at":"2026-05-01T10:00:00Z"}]}"#;
        assert_eq!(prerelease_label(json), "1.24.3 (2026-05-01)");
        assert_eq!(prerelease_label(r#"{"name":"","assets":[]}"#), "");
    }
}
