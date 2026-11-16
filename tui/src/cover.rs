//! A game's cover art for the game page, drawn as coloured ASCII. The art comes
//! from what the launchers already keep on disk (Steam's library cache,
//! Heroic's image cache) and, when the player gives their own key, from
//! SteamGridDB. Finding and decoding run on a thread of their own, since
//! SteamGridDB means the network.

use crate::engine::identify::Store;
use ratatui::style::{Color, Style};
use ratatui::text::{Line, Span};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::mpsc::{self, Receiver};

/// A cover, shrunk to a size that's plenty for a terminal column.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pixels {
    pub w: u32,
    pub h: u32,
    pub rgb: Vec<[u8; 3]>,
}

/// Who the cover is for: the store and ID the game is known by there, and its
/// name for a SteamGridDB search.
#[derive(Debug, Clone)]
pub struct Wanted {
    pub store: Option<Store>,
    pub id: String,
    pub name: String,
}

/// Darkest to brightest.
const RAMP: &[u8] = b" .:-=+*#%@";

/// The largest the decoded cover is kept at; a terminal column never needs more.
const KEEP_W: u32 = 160;
const KEEP_H: u32 = 240;

/// Steam's own copy of the cover it shows in its library.
fn steam_cover(home: &Path, app_id: &str) -> Option<PathBuf> {
    let p = home
        .join(".local/share/Steam/appcache/librarycache")
        .join(app_id)
        .join("library_600x900.jpg");
    p.is_file().then_some(p)
}

/// Heroic keeps the cover it shows (`art_square` in its GOG library) in
/// `images-cache`, named by the SHA-256 of its URL.
fn heroic_cover(home: &Path, gog_id: &str) -> Option<PathBuf> {
    for root in crate::library::heroic_roots(home) {
        let Ok(text) = std::fs::read_to_string(root.join("store_cache/gog_library.json")) else {
            continue;
        };
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) else {
            continue;
        };
        let games = v.get("games").and_then(|g| g.as_array());
        let url = games
            .into_iter()
            .flatten()
            .find(|g| g.get("app_name").and_then(|a| a.as_str()) == Some(gog_id))
            .and_then(|g| g.get("art_square").and_then(|u| u.as_str()));
        if let Some(url) = url {
            let hash = format!("{:x}", Sha256::digest(url.as_bytes()));
            let p = root.join("images-cache").join(hash);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

/// Where a cover from SteamGridDB is kept, so it's fetched once.
fn cached_name(w: &Wanted) -> String {
    match w.store {
        Some(Store::Steam) => format!("steam-{}", w.id),
        Some(Store::Gog) => format!("gog-{}", w.id),
        None => {
            let slug: String = w
                .name
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() {
                        c.to_ascii_lowercase()
                    } else {
                        '-'
                    }
                })
                .collect();
            format!("name-{slug}")
        }
    }
}

pub fn cache_dir(home: &Path) -> PathBuf {
    home.join(".cache/eax-restore-linux/covers")
}

/// A GET to SteamGridDB's API with the player's key; empty when it fails.
fn sgdb_get(key: &str, url: &str) -> String {
    Command::new("curl")
        .args([
            "-fs",
            "--connect-timeout",
            "10",
            "--max-time",
            "20",
            "-H",
            &format!("Authorization: Bearer {key}"),
            url,
        ])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn first_url(json: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(json).ok()?;
    v.get("data")?
        .as_array()?
        .first()?
        .get("url")?
        .as_str()
        .map(str::to_string)
}

/// A portrait cover from SteamGridDB: by Steam AppID when there is one, else
/// the first game its search finds for the name.
fn steamgriddb_cover(home: &Path, key: &str, w: &Wanted) -> Option<PathBuf> {
    let dest = cache_dir(home).join(cached_name(w));
    if dest.is_file() {
        return Some(dest);
    }
    const API: &str = "https://www.steamgriddb.com/api/v2";
    const SIZE: &str = "dimensions=600x900";
    let grids = match w.store {
        Some(Store::Steam) => sgdb_get(key, &format!("{API}/grids/steam/{}?{SIZE}", w.id)),
        _ => {
            let term: String = w
                .name
                .bytes()
                .map(|b| match b {
                    b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' => {
                        (b as char).to_string()
                    }
                    _ => format!("%{b:02X}"),
                })
                .collect();
            let found = sgdb_get(key, &format!("{API}/search/autocomplete/{term}"));
            let v: serde_json::Value = serde_json::from_str(&found).ok()?;
            let id = v.get("data")?.as_array()?.first()?.get("id")?.as_u64()?;
            sgdb_get(key, &format!("{API}/grids/game/{id}?{SIZE}"))
        }
    };
    let url = first_url(&grids)?;
    std::fs::create_dir_all(dest.parent()?).ok()?;
    let ok = Command::new("curl")
        .args([
            "-fsSL",
            "--connect-timeout",
            "10",
            "--max-time",
            "30",
            &url,
            "-o",
        ])
        .arg(&dest)
        .status()
        .is_ok_and(|s| s.success());
    if ok {
        Some(dest)
    } else {
        let _ = std::fs::remove_file(&dest);
        None
    }
}

/// The cover's file, from the first place that has one: Steam's cache,
/// Heroic's, then SteamGridDB when `key` is set.
pub fn find(home: &Path, w: &Wanted, key: Option<&str>) -> Option<PathBuf> {
    let local = match w.store {
        Some(Store::Steam) => steam_cover(home, &w.id),
        Some(Store::Gog) => heroic_cover(home, &w.id),
        None => None,
    };
    local.or_else(|| key.and_then(|k| steamgriddb_cover(home, k, w)))
}

/// Decodes a JPEG or PNG and shrinks it to at most 160×240.
pub fn load(path: &Path) -> Option<Pixels> {
    let img = image::ImageReader::open(path)
        .ok()?
        .with_guessed_format()
        .ok()?
        .decode()
        .ok()?;
    let small = img.thumbnail(KEEP_W, KEEP_H).to_rgb8();
    Some(Pixels {
        w: small.width(),
        h: small.height(),
        rgb: small.pixels().map(|p| p.0).collect(),
    })
}

/// Finds and decodes the cover on a thread of its own; the answer arrives
/// on the channel (None when there's no cover).
pub fn spawn(home: PathBuf, wanted: Wanted) -> Receiver<Option<Pixels>> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let key = std::env::var("EAX_RESTORE_STEAMGRIDDB_KEY")
            .ok()
            .filter(|k| !k.trim().is_empty());
        let pixels = find(&home, &wanted, key.as_deref()).and_then(|p| load(&p));
        let _ = tx.send(pixels);
    });
    rx
}

/// The nearest of the terminal's 256 colours: the 6×6×6 cube or the grey ramp.
fn nearest_256(c: [u8; 3]) -> Color {
    let level = |v: u8| -> u8 {
        if v < 48 {
            0
        } else if v < 115 {
            1
        } else {
            (v - 35) / 40
        }
    };
    let (r, g, b) = (level(c[0]), level(c[1]), level(c[2]));
    let cube = [0u8, 95, 135, 175, 215, 255];
    let cube_c = [cube[r as usize], cube[g as usize], cube[b as usize]];
    let avg = (u16::from(c[0]) + u16::from(c[1]) + u16::from(c[2])) / 3;
    let grey_i = if avg > 238 {
        23
    } else {
        (avg.saturating_sub(3)) / 10
    } as u8;
    let grey = 8 + 10 * grey_i;
    let dist = |a: [u8; 3]| -> u32 {
        a.iter()
            .zip(c)
            .map(|(x, y)| (i32::from(*x) - i32::from(y)).pow(2) as u32)
            .sum()
    };
    if dist([grey, grey, grey]) < dist(cube_c) {
        Color::Indexed(232 + grey_i)
    } else {
        Color::Indexed(16 + 36 * r + 6 * g + b)
    }
}

/// Whether the terminal takes 24-bit colour.
pub fn truecolor() -> bool {
    std::env::var("COLORTERM").is_ok_and(|v| v == "truecolor" || v == "24bit")
}

/// The cover as lines of coloured characters, as large as fits in
/// `cols`×`rows` with its shape kept (a character cell is about twice as tall
/// as it's wide), centred across `cols`.
pub fn ascii(p: &Pixels, cols: u16, rows: u16, true_colour: bool) -> Vec<Line<'static>> {
    if p.w == 0 || p.h == 0 || cols == 0 || rows == 0 {
        return Vec::new();
    }
    let (pw, ph) = (f64::from(p.w), f64::from(p.h));
    let mut c = f64::from(cols);
    let mut r = c * ph / pw / 2.0;
    if r > f64::from(rows) {
        r = f64::from(rows);
        c = r * 2.0 * pw / ph;
    }
    let (c, r) = (c.round().max(1.0) as u32, r.round().max(1.0) as u32);
    let pad = " ".repeat(usize::from(cols).saturating_sub(c as usize) / 2);
    let mut out = Vec::with_capacity(r as usize);
    for y in 0..r {
        let (y0, y1) = (y * p.h / r, ((y + 1) * p.h / r).max(y * p.h / r + 1));
        let mut spans = vec![Span::raw(pad.clone())];
        for x in 0..c {
            let (x0, x1) = (x * p.w / c, ((x + 1) * p.w / c).max(x * p.w / c + 1));
            let mut sum = [0u32; 3];
            let mut n = 0u32;
            for yy in y0..y1.min(p.h) {
                for xx in x0..x1.min(p.w) {
                    let px = p.rgb[(yy * p.w + xx) as usize];
                    for i in 0..3 {
                        sum[i] += u32::from(px[i]);
                    }
                    n += 1;
                }
            }
            let n = n.max(1);
            let avg = [(sum[0] / n) as u8, (sum[1] / n) as u8, (sum[2] / n) as u8];
            let lum = (299 * u32::from(avg[0]) + 587 * u32::from(avg[1]) + 114 * u32::from(avg[2]))
                / 1000;
            let ch = RAMP[(lum as usize * RAMP.len() / 256).min(RAMP.len() - 1)] as char;
            let colour = if true_colour {
                Color::Rgb(avg[0], avg[1], avg[2])
            } else {
                nearest_256(avg)
            };
            spans.push(Span::styled(ch.to_string(), Style::new().fg(colour)));
        }
        out.push(Line::from(spans));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn dark_is_blank_bright_is_full_and_the_colour_is_kept() {
        // Left half black, right half pure red at full brightness... and white.
        let mut rgb = Vec::new();
        for _ in 0..4 {
            rgb.extend([[0, 0, 0], [0, 0, 0], [255, 255, 255], [255, 255, 255]]);
        }
        let p = Pixels { w: 4, h: 4, rgb };
        let lines = ascii(&p, 4, 2, true);
        assert_eq!(text(&lines), ["  @@", "  @@"]);
        let white = &lines[0].spans[3];
        assert_eq!(white.style.fg, Some(Color::Rgb(255, 255, 255)));
        let lines = ascii(&p, 4, 2, false);
        assert_eq!(lines[0].spans[3].style.fg, Some(Color::Indexed(231)));
    }

    #[test]
    fn the_shape_is_kept_and_centred() {
        // A 2:3 portrait cover in a 20×40 column: 20 wide makes 15 rows.
        let p = Pixels {
            w: 20,
            h: 30,
            rgb: vec![[128, 128, 128]; 600],
        };
        let lines = ascii(&p, 20, 40, true);
        assert_eq!(lines.len(), 15);
        // Too short for that: 10 rows, about 13 wide, centred.
        let lines = ascii(&p, 20, 10, true);
        assert_eq!(lines.len(), 10);
        let row = &text(&lines)[0];
        assert!(
            row.starts_with("  ") && row.chars().count() <= 20,
            "{row:?}"
        );
    }

    #[test]
    fn steam_then_heroic_then_nothing() {
        let home = tempfile::tempdir().unwrap();
        let h = home.path();
        let steam = h.join(".local/share/Steam/appcache/librarycache/211740");
        std::fs::create_dir_all(&steam).unwrap();
        std::fs::write(steam.join("library_600x900.jpg"), "x").unwrap();
        let w = |store, id: &str| Wanted {
            store,
            id: id.into(),
            name: "Thief Gold".into(),
        };
        assert_eq!(
            find(h, &w(Some(Store::Steam), "211740"), None),
            Some(steam.join("library_600x900.jpg"))
        );

        let url = "https://images.gog.com/abc.jpg?namespace=gamesdb";
        let root = h.join(".config/heroic");
        std::fs::create_dir_all(root.join("store_cache")).unwrap();
        std::fs::create_dir_all(root.join("images-cache")).unwrap();
        std::fs::write(
            root.join("store_cache/gog_library.json"),
            format!(r#"{{"games":[{{"app_name":"1207658997","art_square":"{url}"}}]}}"#),
        )
        .unwrap();
        let hash = format!("{:x}", Sha256::digest(url.as_bytes()));
        std::fs::write(root.join("images-cache").join(&hash), "x").unwrap();
        assert_eq!(
            find(h, &w(Some(Store::Gog), "1207658997"), None),
            Some(root.join("images-cache").join(hash))
        );

        assert_eq!(find(h, &w(Some(Store::Gog), "999"), None), None);
        assert_eq!(find(h, &w(None, ""), None), None);
    }

    #[test]
    fn a_real_jpeg_decodes_and_shrinks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("c.png");
        let img = image::RgbImage::from_pixel(600, 900, image::Rgb([10, 200, 30]));
        img.save(&path).unwrap();
        let p = load(&path).unwrap();
        assert_eq!((p.w, p.h), (160, 240));
        assert_eq!(p.rgb[0], [10, 200, 30]);
    }
}
