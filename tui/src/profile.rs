//! The Game profile pane: the old browser's `print_game_profile_stores`. The
//! game's details as ` -> Label: value` rows, then the sections under blue
//! headings (Description, Status, Restoring EAX with, the settings, Sources).
//! This TUI adds a "System details" block, the install screen's own heading, for
//! what it knows about this PC.

use crate::db::{Game, OnlyIf, Setting, Source, Store};
use crate::games::Entry;
use crate::library::StoreKind;
use crate::settings::wrap;
use crate::theme;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};

fn label_of(k: StoreKind) -> &'static str {
    match k {
        StoreKind::Steam => "Steam",
        StoreKind::Gog => "GOG",
    }
}

fn key_of(k: StoreKind) -> &'static str {
    match k {
        StoreKind::Steam => "steam",
        StoreKind::Gog => "gog",
    }
}

/// The game's store entries, Steam's first; just `only` when a copy of it is known.
fn stores_of(g: &Game, only: Option<StoreKind>) -> Vec<(StoreKind, &Store)> {
    let all = [
        (StoreKind::Steam, g.stores.steam.as_ref()),
        (StoreKind::Gog, g.stores.gog.as_ref()),
    ];
    let wanted: Vec<_> = all
        .iter()
        .filter_map(|(k, s)| s.map(|s| (*k, s)))
        .filter(|(k, _)| only.is_none() || only == Some(*k))
        .collect();
    if wanted.is_empty() {
        all.iter().filter_map(|(k, s)| s.map(|s| (*k, s))).collect()
    } else {
        wanted
    }
}

fn api_of<'a>(g: &'a Game, s: &'a Store) -> &'a str {
    match s.api.as_deref() {
        Some(a) if !a.is_empty() => a,
        _ if !g.eax.api.is_empty() => &g.eax.api,
        _ => "directsound3d",
    }
}

fn api_name(api: &str) -> &'static str {
    if api == "openal" {
        "OpenAL"
    } else {
        "DirectSound3D"
    }
}

/// A setting this store's build is offered: all of them, unless it names stores.
fn offered(s: &Setting, k: StoreKind) -> bool {
    match s.only_if.as_ref().and_then(|o| o.stores.as_ref()) {
        None => true,
        Some(_) => OnlyIf::list(&s.only_if.as_ref().and_then(|o| o.stores.clone()))
            .iter()
            .any(|x| x == key_of(k)),
    }
}

/// `2000-06-23` as `23 June 2000`; `2000-06` as `June 2000`; `2000` as it is.
pub fn release_date(s: &str) -> String {
    const MONTHS: [&str; 12] = [
        "January",
        "February",
        "March",
        "April",
        "May",
        "June",
        "July",
        "August",
        "September",
        "October",
        "November",
        "December",
    ];
    let mut parts = s.split('-');
    let (y, m, d) = (parts.next().unwrap_or(""), parts.next(), parts.next());
    let month = m
        .and_then(|m| m.parse::<usize>().ok())
        .and_then(|m| MONTHS.get(m.wrapping_sub(1)));
    match (d.and_then(|d| d.parse::<u32>().ok()), month) {
        (Some(d), Some(month)) => format!("{d} {month} {y}"),
        (_, Some(month)) => format!("{month} {y}"),
        _ => y.to_string(),
    }
}

/// One ` -> Label: value` row; a value of several lines continues under the first.
struct Row {
    label: &'static str,
    value: Value,
}

enum Value {
    /// Lines that are already as they should be.
    Lines(Vec<Vec<Span<'static>>>),
    /// Text that may be long, wrapped to what is left of the line.
    Text(String, Style),
}

enum Item {
    Heading(&'static str),
    Row(Row),
}

fn row(label: &'static str, spans: Vec<Span<'static>>) -> Item {
    Item::Row(Row {
        label,
        value: Value::Lines(vec![spans]),
    })
}

fn lined(label: &'static str, lines: Vec<Vec<Span<'static>>>) -> Item {
    Item::Row(Row {
        label,
        value: Value::Lines(lines),
    })
}

/// The rows, every value lined up after the longest label.
fn detail_lines(items: Vec<Item>, width: usize) -> Vec<Line<'static>> {
    let w = items
        .iter()
        .map(|i| match i {
            Item::Row(r) => r.label.chars().count(),
            Item::Heading(_) => 0,
        })
        .max()
        .unwrap_or(0);
    // " -> " + the label + ":" + a space.
    let lead = w + 6;
    let mut out = Vec::new();
    for item in items {
        match item {
            Item::Heading(text) => {
                out.push(Line::raw(""));
                out.push(Line::from(Span::styled(format!("{text}:"), theme::white())));
            }
            Item::Row(r) => {
                let lines = match r.value {
                    Value::Lines(l) => l,
                    Value::Text(t, style) => wrap(&t, width.saturating_sub(lead).max(8), "")
                        .into_iter()
                        .map(|l| vec![Span::styled(l, style)])
                        .collect(),
                };
                for (i, value) in lines.into_iter().enumerate() {
                    let mut spans = if i == 0 {
                        vec![
                            Span::raw(" -> "),
                            Span::styled(r.label, theme::label()),
                            Span::raw(format!(":{} ", " ".repeat(w - r.label.chars().count()))),
                        ]
                    } else {
                        vec![Span::raw(" ".repeat(lead))]
                    };
                    spans.extend(value);
                    out.push(Line::from(spans));
                }
            }
        }
    }
    out
}

fn white(s: impl Into<String>) -> Span<'static> {
    Span::styled(s.into(), theme::white())
}

fn dim(s: impl Into<String>) -> Span<'static> {
    Span::styled(s.into(), theme::dim())
}

fn subheading(out: &mut Vec<Line<'static>>, label: &str) {
    out.push(Line::raw(""));
    out.push(Line::from(Span::styled(
        format!("  {label}:"),
        theme::note(),
    )));
}

/// A paragraph in the terminal's normal weight, indented two.
fn prose(out: &mut Vec<Line<'static>>, text: &str, width: usize) {
    out.extend(wrap(text, width, "  ").into_iter().map(Line::from));
}

/// A line in bold white, indented two, as the script's `print_wrapped` prints it.
fn strong(out: &mut Vec<Line<'static>>, text: &str, width: usize) {
    out.extend(
        wrap(text, width, "  ")
            .into_iter()
            .map(|l| Line::from(white(l))),
    );
}

/// A setting's title in bold white with its (tested) or (untested) after it.
fn titled(out: &mut Vec<Line<'static>>, title: &str, untested: bool, width: usize) {
    let tag = if untested { "(untested)" } else { "(tested)" };
    let tag_style = if untested {
        theme::note()
    } else {
        theme::green()
    };
    let mut lines = wrap(&format!("{title} {tag}"), width, "  ");
    let last = lines.pop().unwrap_or_default();
    out.extend(lines.into_iter().map(|l| Line::from(white(l))));
    match last.strip_suffix(tag) {
        Some(head) => out.push(Line::from(vec![
            white(head.to_string()),
            Span::styled(tag, tag_style),
        ])),
        None => out.push(Line::from(white(last))),
    }
}

/// A title with the stores that offer it.
struct Titles {
    audio: Vec<(String, bool, Vec<StoreKind>)>,
    optional: Vec<(String, bool, Vec<StoreKind>)>,
    openal: Vec<(String, bool, Vec<StoreKind>)>,
}

fn note_title(
    list: &mut Vec<(String, bool, Vec<StoreKind>)>,
    title: String,
    untested: bool,
    k: StoreKind,
) {
    match list.iter_mut().find(|(t, _, _)| *t == title) {
        Some((_, _, stores)) => stores.push(k),
        None => list.push((title, untested, vec![k])),
    }
}

fn alsoft_value(v: &serde_json::Value) -> String {
    match v {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

fn collect_titles(g: &Game, stores: &[(StoreKind, &Store)]) -> Titles {
    let mut t = Titles {
        audio: Vec::new(),
        optional: Vec::new(),
        openal: Vec::new(),
    };
    for (k, _) in stores {
        for s in g
            .game_config
            .audio_settings
            .iter()
            .filter(|s| offered(s, *k))
        {
            note_title(&mut t.audio, s.title.clone(), !s.tested, *k);
        }
        for s in g
            .game_config
            .optional_settings
            .iter()
            .filter(|s| offered(s, *k))
        {
            note_title(&mut t.optional, s.title.clone(), !s.tested, *k);
        }
        let untested = g.install.alsoft_tested != Some(true);
        for (section, keys) in g.install.alsoft_ini.iter().flatten() {
            if let serde_json::Value::Object(keys) = keys {
                for (key, value) in keys {
                    let title = format!("{section} {key} = {}", alsoft_value(value));
                    note_title(&mut t.openal, title, untested, *k);
                }
            }
        }
    }
    t
}

fn setting_titles(
    out: &mut Vec<Line<'static>>,
    heading: &str,
    list: &[(String, bool, Vec<StoreKind>)],
    n_stores: usize,
    width: usize,
) {
    if list.is_empty() {
        return;
    }
    subheading(out, heading);
    for (title, untested, stores) in list {
        let only = if n_stores > 1 && stores.len() < n_stores {
            let names: Vec<_> = stores.iter().map(|k| label_of(*k)).collect();
            format!("{title} ({} only)", names.join(" and "))
        } else {
            title.clone()
        };
        titled(out, &only, *untested, width);
    }
}

fn all_same<T: PartialEq>(v: &[T]) -> bool {
    v.iter().all(|x| *x == v[0])
}

/// A source: its title in bold white, its address dim under it.
fn source_lines(out: &mut Vec<Line<'static>>, s: &Source) {
    let (title, url) = match s {
        Source::Url(u) => ("", u.as_str()),
        Source::Page { title, url } => (title.as_str(), url.as_str()),
    };
    if url.is_empty() {
        return;
    }
    if !title.is_empty() {
        out.push(Line::from(vec![Span::raw("  "), white(title.to_string())]));
    }
    let lead = if title.is_empty() { "  " } else { "    " };
    out.push(Line::from(vec![Span::raw(lead), dim(url.to_string())]));
}

/// The profile of one game for the stores shown: its details, then its sections.
/// `system` is what this PC adds, as `(label, value)` rows.
fn game_lines(
    g: &Game,
    only: Option<StoreKind>,
    system: Vec<Item>,
    width: usize,
) -> Vec<Line<'static>> {
    let stores = stores_of(g, only);
    let n = stores.len();
    // A game with no store entry still has its own API to show.
    let apis: Vec<&str> = if stores.is_empty() {
        vec![if g.eax.api.is_empty() {
            "directsound3d"
        } else {
            g.eax.api.as_str()
        }]
    } else {
        stores.iter().map(|(_, s)| api_of(g, s)).collect()
    };
    let status = if g.eax.status.is_empty() {
        "supported"
    } else {
        g.eax.status.as_str()
    };

    let mut items = vec![Item::Heading("Game details")];
    items.push(row(
        "Name",
        vec![Span::styled(
            g.name.clone(),
            Style::new().add_modifier(Modifier::BOLD),
        )],
    ));
    items.push(row(
        "Profile",
        vec![if g.tested {
            Span::styled("Tested", theme::green())
        } else {
            Span::styled("Untested", theme::note())
        }],
    ));
    if !g.released.is_empty() {
        items.push(row("Released", vec![white(release_date(&g.released))]));
    }
    for (k, s) in &stores {
        // "Steam ID" and "GOG ID" are the one label with two spellings.
        let label = if *k == StoreKind::Steam {
            "Steam ID"
        } else {
            "GOG ID"
        };
        items.push(row(label, vec![white(s.id.to_string())]));
    }
    let delisted: Vec<_> = stores
        .iter()
        .filter(|(_, s)| s.delisted)
        .map(|(k, _)| label_of(*k))
        .collect();
    if !delisted.is_empty() {
        items.push(row(
            "Availability",
            vec![
                white(format!("Delisted from {} ", delisted.join(" and "))),
                dim("(existing owners keep access)"),
            ],
        ));
    }
    for (_, s) in &stores {
        if s.id_source.as_deref() == Some("steamdb_historical") {
            items.push(row(
                "ID source",
                vec![
                    white("SteamDB records "),
                    dim("(not verified against a local install)"),
                ],
            ));
        }
    }
    let versions = if g.eax.versions.is_empty() {
        "Unknown".to_string()
    } else {
        g.eax.versions.join(", ")
    };
    let (strong_green, strong_yellow) = (theme::strong_green(), theme::label());
    items.push(row(
        "EAX Support",
        match status {
            "supported" => vec![Span::styled(versions, strong_green)],
            "removed_by_patch" => vec![
                Span::styled(versions, strong_yellow),
                dim(" (originally supported)"),
            ],
            "built_in" => vec![
                Span::styled(versions, strong_green),
                dim(" (already built in)"),
            ],
            _ => vec![Span::styled("None", strong_yellow)],
        },
    ));
    items.push(if all_same(&apis) {
        row("Audio API", vec![white(api_name(apis[0]))])
    } else {
        lined(
            "Audio API",
            stores
                .iter()
                .zip(&apis)
                .map(|((k, _), a)| {
                    vec![
                        white(api_name(a)),
                        Span::raw(format!(" on {}", label_of(*k))),
                    ]
                })
                .collect(),
        )
    });
    if g.eax.sound_system.as_deref() == Some("miles") {
        items.push(row("Sound system", vec![white("Miles Sound System")]));
    }
    if g.install.tweaks.iter().any(|t| t == "eax_unified") {
        items.push(row("EAX Unified", vec![white("Yes")]));
    }
    // Always shown, even at 0, so the labels keep one width from game to game.
    for (label, audio) in [("Audio settings", true), ("Optional settings", false)] {
        let list = if audio {
            &g.game_config.audio_settings
        } else {
            &g.game_config.optional_settings
        };
        let counts: Vec<usize> = if stores.is_empty() {
            vec![list.len()]
        } else {
            stores
                .iter()
                .map(|(k, _)| list.iter().filter(|s| offered(s, *k)).count())
                .collect()
        };
        items.push(if all_same(&counts) {
            row(label, vec![white(counts[0].to_string())])
        } else {
            lined(
                label,
                stores
                    .iter()
                    .zip(&counts)
                    .map(|((k, _), c)| {
                        vec![
                            white(c.to_string()),
                            Span::raw(format!(" on {}", label_of(*k))),
                        ]
                    })
                    .collect(),
            )
        });
    }
    items.extend(system);
    let mut out = detail_lines(items, width);

    if !g.description.is_empty() {
        subheading(&mut out, "Description");
        prose(&mut out, &g.description, width);
    }
    if status != "supported" || !g.eax.problem.is_empty() {
        // The entry's own problem text says why; the lead-in is only for an entry without one.
        let (mut state, mut after) = (String::new(), String::new());
        if g.eax.problem.is_empty() {
            state = "Never implemented in this edition.".into();
        }
        if status == "removed_by_patch" {
            state = "Removed by a later patch.".into();
        }
        if status == "built_in" {
            state.clear();
            after = " Installing is optional: it swaps in a newer OpenAL Soft and adds speaker and headphone settings.".into();
        }
        let problem = if g.eax.problem.is_empty() {
            String::new()
        } else {
            format!(" {}", g.eax.problem)
        };
        let text = format!("{state}{problem}{after}");
        subheading(&mut out, "Status");
        prose(&mut out, text.strip_prefix(' ').unwrap_or(&text), width);
    }
    // What the stores share is said once, under both names.
    let details: Vec<&str> = stores
        .iter()
        .map(|(_, s)| s.store_details.as_str())
        .collect();
    if n > 1 && !details[0].is_empty() && all_same(&details) {
        let names: Vec<_> = stores.iter().map(|(k, _)| label_of(*k)).collect();
        subheading(&mut out, &format!("{} details", names.join(" and ")));
        prose(&mut out, details[0], width);
    } else {
        for ((k, _), d) in stores.iter().zip(&details) {
            if !d.is_empty() {
                subheading(&mut out, &format!("{} details", label_of(*k)));
                prose(&mut out, d, width);
            }
        }
    }
    if status == "supported" {
        let solution = |api: &str| {
            if api == "openal" {
                "OpenAL Soft"
            } else {
                "DSOAL + OpenAL Soft"
            }
        };
        subheading(&mut out, "Restoring EAX with");
        if all_same(&apis) {
            strong(&mut out, solution(apis[0]), width);
        } else {
            for ((k, _), a) in stores.iter().zip(&apis) {
                strong(
                    &mut out,
                    &format!("{}: {}", label_of(*k), solution(a)),
                    width,
                );
            }
        }
    }
    let titles = collect_titles(g, &stores);
    setting_titles(&mut out, "Audio settings", &titles.audio, n, width);
    setting_titles(&mut out, "Optional settings", &titles.optional, n, width);
    setting_titles(&mut out, "OpenAL settings", &titles.openal, n, width);

    // What the player does after installing; a setting more than one store offers shows once.
    let mut seen: Vec<&str> = Vec::new();
    for (k, _) in &stores {
        let settings = g
            .game_config
            .audio_settings
            .iter()
            .chain(&g.game_config.optional_settings)
            .filter(|s| offered(s, *k));
        for s in settings {
            let Some(follow) = s.follow_up.as_deref().filter(|f| !f.is_empty()) else {
                continue;
            };
            if seen.contains(&s.title.as_str()) {
                continue;
            }
            if seen.is_empty() {
                subheading(&mut out, "Before you play");
            } else {
                out.push(Line::raw(""));
            }
            seen.push(&s.title);
            out.push(Line::from(vec![Span::raw("  "), white(s.title.clone())]));
            prose(&mut out, follow, width);
        }
    }
    if !g.eax.fix.is_empty() {
        subheading(&mut out, "Additional steps");
        prose(&mut out, &g.eax.fix, width);
    }
    if !g.notes.is_empty() {
        subheading(&mut out, "Notes");
        prose(&mut out, &g.notes, width);
    }
    let patches: Vec<&str> = stores.iter().map(|(_, s)| s.patches.as_str()).collect();
    if n <= 1 || (!patches[0].is_empty() && all_same(&patches)) {
        if let Some(p) = patches.first().filter(|p| !p.is_empty()) {
            subheading(&mut out, "Suggested community patches");
            prose(&mut out, p, width);
        }
    } else {
        for ((k, _), p) in stores.iter().zip(&patches) {
            if !p.is_empty() {
                subheading(
                    &mut out,
                    &format!("Suggested community patches for {}", label_of(*k)),
                );
                prose(&mut out, p, width);
            }
        }
    }
    let sources: Vec<&Source> = g
        .sources
        .iter()
        .filter(|s| match s {
            Source::Url(u) => !u.is_empty(),
            Source::Page { url, .. } => !url.is_empty(),
        })
        .collect();
    if !sources.is_empty() {
        subheading(&mut out, "Sources");
        for s in sources {
            source_lines(&mut out, s);
        }
    }
    out.push(Line::raw(""));
    out
}

/// A game's profile from the database alone, for every store it is sold in.
pub fn database_lines(g: &Game, width: usize) -> Vec<Line<'static>> {
    game_lines(g, None, Vec::new(), width)
}

/// What this PC says about a game: whether the fix is on it, from which store,
/// and where.
fn system_rows(e: &Entry) -> Vec<Item> {
    let (_, colour) = crate::ui::marker(e.status);
    let mut items = vec![
        Item::Heading("System details"),
        row(
            "Status",
            vec![Span::styled(e.status.label(), Style::new().fg(colour))],
        ),
    ];
    if let Some(k) = e.store {
        items.push(row(
            "Platform",
            vec![Span::styled(label_of(k), theme::green())],
        ));
    }
    if let Some(p) = &e.path {
        items.push(Item::Row(Row {
            label: "Location",
            value: Value::Text(p.display().to_string(), theme::dim()),
        }));
    }
    items
}

/// The pane for a game: the profile from the database, with what this PC says.
pub fn lines(e: &Entry, width: usize) -> Vec<Line<'static>> {
    let system = system_rows(e);
    match &e.game {
        Some(g) => game_lines(g, e.store, system, width),
        None => {
            let mut out = detail_lines(system, width);
            out.push(Line::raw(""));
            out.extend(
                wrap(
                    &format!("The game database has no profile for {}.", e.name),
                    width,
                    "  ",
                )
                .into_iter()
                .map(Line::from),
            );
            out
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use crate::games::Status;

    fn game(json: &str) -> Game {
        Database::parse(&format!(r#"{{"games":[{json}]}}"#))
            .unwrap()
            .games
            .remove(0)
    }

    fn text(lines: &[Line]) -> String {
        lines
            .iter()
            .map(|l| {
                l.spans
                    .iter()
                    .map(|s| s.content.as_ref())
                    .collect::<String>()
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    const QUAKE: &str = r#"{"name":"Quake 4","released":"2005-10-18",
      "description":"Quake 4 is a shooter.",
      "stores":{"steam":{"id":2210},"gog":{"id":1836059896}},
      "eax":{"api":"openal","versions":["4.0","5.0"]},
      "sources":[{"title":"PCGamingWiki: Quake 4","url":"https://example.org/q4"}],
      "game_config":{"files":{"q.cfg":{"format":"idtech_cfg"}},
        "audio_settings":[{"title":"Enable EAX effects","tested":true,"reason":"r","changes":{"q.cfg":{"a":"1"}}},
          {"title":"Steam only thing","tested":false,"reason":"r","only_if":{"stores":["steam"]},"changes":{"q.cfg":{"b":"1"}}}],
        "optional_settings":[{"title":"Fix blurry text","tested":true,"reason":"r","follow_up":"Restart once.","changes":{"q.cfg":{"c":"1"}}}]}}"#;

    #[test]
    fn the_details_are_arrow_rows_with_the_values_lined_up() {
        let t = text(&game_lines(&game(QUAKE), None, Vec::new(), 70));
        println!("{t}");
        assert!(t.starts_with("\nGame details:\n -> Name:              Quake 4\n"));
        assert!(t.contains(" -> Profile:           Tested\n"));
        assert!(t.contains(" -> Released:          18 October 2005\n"));
        assert!(t.contains(" -> Steam ID:          2210\n"));
        assert!(t.contains(" -> GOG ID:            1836059896\n"));
        assert!(t.contains(" -> EAX Support:       4.0, 5.0\n"));
        assert!(t.contains(" -> Audio API:         OpenAL\n"));
    }

    #[test]
    fn a_miles_game_shows_its_sound_system_under_the_audio_api() {
        let miles = QUAKE.replace(
            r#""api":"openal","#,
            r#""api":"openal","sound_system":"miles","#,
        );
        let t = text(&game_lines(&game(&miles), None, Vec::new(), 70));
        assert!(t.contains(
            " -> Audio API:         OpenAL\n -> Sound system:      Miles Sound System\n"
        ));
        let t = text(&game_lines(&game(QUAKE), None, Vec::new(), 70));
        assert!(!t.contains("Sound system"));
    }

    #[test]
    fn counts_are_per_store_when_a_setting_is_limited_to_one() {
        let t = text(&game_lines(&game(QUAKE), None, Vec::new(), 70));
        assert!(t.contains(" -> Audio settings:    2 on Steam\n                       1 on GOG\n"));
        assert!(t.contains(" -> Optional settings: 1\n"));
    }

    #[test]
    fn the_sections_follow_in_the_old_order_under_blue_headings() {
        let t = text(&game_lines(&game(QUAKE), None, Vec::new(), 70));
        let at = |s: &str| t.find(s).unwrap_or_else(|| panic!("missing {s}"));
        let order = [
            "  Description:",
            "  Restoring EAX with:",
            "  Audio settings:",
            "  Optional settings:",
            "  Before you play:",
            "  Sources:",
        ];
        for pair in order.windows(2) {
            assert!(at(pair[0]) < at(pair[1]), "{} before {}", pair[0], pair[1]);
        }
        assert!(t.contains("  OpenAL Soft\n"));
        assert!(t.contains("  Steam only thing (Steam only) (untested)\n"));
        assert!(t.contains("  Fix blurry text (tested)\n"));
        assert!(t.contains("  Fix blurry text\n  Restart once.\n"));
        assert!(t.contains("  PCGamingWiki: Quake 4\n    https://example.org/q4\n"));
        assert!(t.ends_with('\n'));
    }

    #[test]
    fn a_game_with_no_eax_says_why_and_has_nothing_to_restore() {
        let g = game(
            r#"{"name":"Plain","eax":{"status":"not_implemented","problem":"It has no EAX."}}"#,
        );
        let t = text(&game_lines(&g, None, Vec::new(), 70));
        assert!(t.contains(" -> EAX Support:       None\n"));
        assert!(t.contains("  Status:\n  It has no EAX.\n"));
        assert!(!t.contains("Restoring EAX with"));
    }

    #[test]
    fn built_in_and_removed_games_get_their_own_status_text() {
        let built = game(r#"{"name":"B","eax":{"status":"built_in","versions":["2.0"]}}"#);
        let t = text(&game_lines(&built, None, Vec::new(), 100));
        assert!(t.contains("2.0 (already built in)"));
        assert!(t.contains("Installing is optional: it swaps in a newer OpenAL Soft"));
        let removed = game(
            r#"{"name":"R","eax":{"status":"removed_by_patch","problem":"Patch 1.2 took it out."}}"#,
        );
        let t = text(&game_lines(&removed, None, Vec::new(), 100));
        assert!(t.contains("(originally supported)"));
        assert!(t.contains("  Removed by a later patch. Patch 1.2 took it out.\n"));
    }

    #[test]
    fn delisted_stores_and_unverified_ids_get_their_rows() {
        let g = game(
            r#"{"name":"D","stores":{"steam":{"id":1,"delisted":true,"id_source":"steamdb_historical"},"gog":{"id":2,"delisted":true}}}"#,
        );
        let t = text(&game_lines(&g, None, Vec::new(), 100));
        assert!(t.contains("Delisted from Steam and GOG (existing owners keep access)"));
        assert!(t.contains("SteamDB records (not verified against a local install)"));
    }

    #[test]
    fn a_known_copy_shows_only_its_store() {
        let t = text(&game_lines(
            &game(QUAKE),
            Some(StoreKind::Gog),
            Vec::new(),
            70,
        ));
        assert!(t.contains(" GOG ID:"));
        assert!(!t.contains("Steam ID"));
        assert!(
            !t.contains("Steam only thing"),
            "a Steam-only setting is not offered on GOG"
        );
    }

    #[test]
    fn the_system_block_follows_the_game_rows_and_shares_their_width() {
        let mut e = Entry::database_only(game(QUAKE));
        e.status = Status::Installed;
        e.store = Some(StoreKind::Steam);
        e.path = Some("/lib/Quake 4".into());
        let t = text(&lines(&e, 70));
        assert!(t.contains("\nSystem details:\n -> Status:            Installed\n"));
        assert!(t.contains(" -> Platform:          Steam\n"));
        assert!(t.contains(" -> Location:          /lib/Quake 4\n"));
    }

    #[test]
    fn a_game_the_database_lacks_gets_only_the_system_block_and_a_message() {
        let e = Entry {
            name: "Obscure".into(),
            status: Status::Manual,
            game: None,
            store: None,
            path: Some("/g/Obscure".into()),
        };
        let t = text(&lines(&e, 60));
        assert!(t.contains("System details:"));
        assert!(t.contains("  The game database has no profile for Obscure."));
        assert!(!t.contains("Game details"));
    }

    #[test]
    fn release_dates_read_in_full_when_the_day_is_known() {
        assert_eq!(release_date("2000-06-23"), "23 June 2000");
        assert_eq!(release_date("2000-06"), "June 2000");
        assert_eq!(release_date("2000"), "2000");
    }

    #[test]
    fn wrapped_lines_never_pass_the_width() {
        for line in text(&game_lines(&game(QUAKE), None, Vec::new(), 40)).lines() {
            assert!(line.chars().count() <= 40, "too wide: {line:?}");
        }
    }

    #[test]
    fn a_game_with_no_store_entry_does_not_panic_and_shows_its_own_api() {
        let t = text(&game_lines(
            &game(r#"{"name":"Storeless","eax":{"api":"openal"}}"#),
            None,
            Vec::new(),
            70,
        ));
        assert!(t.contains(" -> Audio API:         OpenAL\n"));
        assert!(t.contains("  Restoring EAX with:\n  OpenAL Soft\n"));
        // The same with a copy's store named that the game does not have.
        game_lines(
            &game(r#"{"name":"Storeless"}"#),
            Some(StoreKind::Gog),
            Vec::new(),
            70,
        );
    }
}
