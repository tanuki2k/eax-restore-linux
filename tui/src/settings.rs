//! The settings view: every audio and optional setting in a game's profile, with
//! its reason, the file it changes, and the keys and values it sets. The Bash
//! browser's Tab view (`print_game_settings_details`), minus the current values,
//! which only an install has.

use crate::db::{ConfigFile, Game, OnlyIf, Setting};
use ratatui::style::{Color, Style, Stylize};
use ratatui::text::{Line, Span};
use serde_json::Value;

/// Same blue the Bash script's `Note:` uses.
const NOTE: Color = Color::LightBlue;

/// Splits `text` into lines of at most `width` characters, each starting with
/// `indent`. A line break the writer meant is kept, and a blank line stays one.
pub fn wrap(text: &str, width: usize, indent: &str) -> Vec<String> {
    let room = width.saturating_sub(indent.chars().count()).max(8);
    let mut out = Vec::new();
    for para in text.split('\n') {
        let mut line = String::new();
        for word in para.split_whitespace() {
            let would_be =
                line.chars().count() + usize::from(!line.is_empty()) + word.chars().count();
            if !line.is_empty() && would_be > room {
                out.push(format!("{indent}{line}"));
                line.clear();
            }
            if !line.is_empty() {
                line.push(' ');
            }
            line.push_str(word);
        }
        out.push(if line.is_empty() {
            String::new()
        } else {
            format!("{indent}{line}")
        });
    }
    out
}

/// A value as the player reads it.
fn show_value(v: &Value) -> String {
    match v {
        Value::Null => "(removed)".into(),
        Value::Bool(true) => "on".into(),
        Value::Bool(false) => "off".into(),
        Value::String(s) if s.is_empty() => "(empty)".into(),
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// `folder with the game's .exe: q4base/Quake4Config.cfg`, or just the folder
/// when the path is the file's own name.
fn location_label(loc: &str, file: &str) -> String {
    let (base, rel) = loc.split_once(':').unwrap_or((loc, ""));
    let name = match base {
        "game_exe" | "game" => "folder with the game's .exe",
        "game_root" | "install" => "game's install folder",
        "prefix_documents" => "Documents in the Wine prefix",
        "prefix_appdata" => "AppData in the Wine prefix",
        "prefix_localappdata" => "Local AppData in the Wine prefix",
        "prefix_public_documents" => "Public Documents in the Wine prefix",
        "prefix" => "Wine prefix",
        other => other,
    };
    if rel == file || rel.is_empty() {
        name.to_string()
    } else {
        format!("{name}: {rel}")
    }
}

/// `Quake4Config.cfg (folder with the game's .exe: q4base/Quake4Config.cfg)`
fn file_label(name: &str, def: Option<&ConfigFile>) -> String {
    let Some(def) = def.filter(|d| !d.locations.is_empty()) else {
        return name.to_string();
    };
    let places: Vec<String> = def
        .locations
        .iter()
        .map(|l| location_label(l, name))
        .collect();
    let joiner = if def.all_locations { " and " } else { " or " };
    format!("{name}  ({})", places.join(joiner))
}

fn speaker_name(s: &str) -> &str {
    match s {
        "stereo" => "Stereo",
        "headphones" => "Headphones",
        "matrix" => "Matrix encoding",
        "surround" => "Surround (any layout)",
        "quad" => "Quad (4.0)",
        "surround51" => "Surround 5.1",
        "surround61" => "Surround 6.1",
        "surround71" => "Surround 7.1",
        other => other,
    }
}

fn tag(tested: bool) -> Span<'static> {
    if tested {
        Span::styled("(tested)", Style::new().fg(Color::Green))
    } else {
        Span::styled("(untested)", Style::new().fg(NOTE))
    }
}

/// One key a setting changes.
struct Row {
    file: String,
    section: String,
    key: String,
    value: String,
}

/// The keys a setting changes, in the database's order. Ini-like files nest
/// section -> key -> value; the rest are key -> value.
fn rows(s: &Setting, files: &std::collections::BTreeMap<String, ConfigFile>) -> Vec<Row> {
    let mut out = Vec::new();
    for (file, change) in &s.changes {
        let sectioned = files
            .get(file)
            .is_some_and(|d| matches!(d.format.as_str(), "ini" | "gas_cfg" | "wine_reg"));
        let Value::Object(map) = change else { continue };
        for (k, v) in map {
            match v {
                Value::Object(inner) if sectioned => {
                    for (key, val) in inner {
                        out.push(Row {
                            file: file.clone(),
                            section: k.clone(),
                            key: key.clone(),
                            value: show_value(val),
                        });
                    }
                }
                _ => out.push(Row {
                    file: file.clone(),
                    section: String::new(),
                    key: k.clone(),
                    value: show_value(v),
                }),
            }
        }
    }
    out
}

fn dim(s: impl Into<String>) -> Line<'static> {
    Line::from(s.into()).dim()
}

fn push_setting(out: &mut Vec<Line<'static>>, s: &Setting, game: &Game, width: usize) {
    out.push(Line::raw(""));
    out.push(Line::from(vec![
        Span::raw("  "),
        Span::raw(s.title.clone()).bold(),
        Span::raw(" "),
        tag(s.tested),
    ]));
    out.extend(wrap(&s.reason, width, "    ").into_iter().map(Line::from));
    out.push(Line::raw(""));

    let rows = rows(s, &game.game_config.files);
    let key_len = rows
        .iter()
        .map(|r| r.key.chars().count())
        .max()
        .unwrap_or(0);
    let (mut prev_file, mut prev_section) = (None::<&str>, None::<&str>);
    for r in &rows {
        if prev_file != Some(r.file.as_str()) {
            let label = file_label(&r.file, game.game_config.files.get(&r.file));
            out.extend(wrap(&label, width, "    ").into_iter().map(dim));
            prev_section = None;
        }
        let indent = if r.section.is_empty() {
            "      "
        } else {
            if prev_section != Some(r.section.as_str()) {
                out.push(dim(format!("      [{}]", r.section)));
            }
            "        "
        };
        out.push(Line::from(vec![
            Span::raw(format!("{indent}{:<key_len$}  → ", r.key)),
            Span::styled(r.value.clone(), Style::new().fg(Color::Green)),
        ]));
        prev_file = Some(&r.file);
        prev_section = Some(&r.section);
    }

    if !s.tested {
        out.push(dim("    Unverified."));
    }
    if let Some(only) = &s.only_if {
        let stores: Vec<&str> = OnlyIf::list(&only.stores)
            .iter()
            .map(|x| if x == "gog" { "GOG" } else { "Steam" })
            .collect();
        if !stores.is_empty() {
            let note = format!("Only on {}", stores.join(" or "));
            out.extend(wrap(&note, width, "    ").into_iter().map(dim));
        }
        let speakers = OnlyIf::list(&only.speakers);
        if !speakers.is_empty() {
            let names: Vec<&str> = speakers.iter().map(|x| speaker_name(x)).collect();
            let note = format!("Only with {}", names.join(" or "));
            out.extend(wrap(&note, width, "    ").into_iter().map(dim));
        }
    }
    if let Some(follow) = s.follow_up.as_deref().filter(|f| !f.is_empty()) {
        out.push(dim("    Afterwards:"));
        out.extend(wrap(follow, width, "    ").into_iter().map(Line::from));
    }
}

/// What a known alsoft.ini key does, in plain words.
fn alsoft_help(section: &str, key: &str) -> Option<&'static str> {
    Some(match (section, key) {
        ("reverb", "boost") => "Makes all reverb louder by this many decibels.",
        ("general", "sources") => "How many sounds the game can play at once.",
        ("general", "frequency") => "The sample rate the sound is mixed at, in Hz.",
        ("general", "default-reverb") => {
            "The reverb preset used where the game doesn't choose one."
        }
        ("general", "resampler") => "How sounds at another sample rate are converted.",
        _ => return None,
    })
}

/// The whole view, wrapped to `width` columns.
pub fn lines(game: &Game, width: usize) -> Vec<Line<'static>> {
    let mut out = Vec::new();
    let cfg = &game.game_config;
    let heading = |text: String| Line::from(text).bold();

    if cfg.audio_settings.is_empty() && cfg.optional_settings.is_empty() {
        out.extend(
            wrap(
                &format!("{} has no game settings in the database.", game.name),
                width,
                "",
            )
            .into_iter()
            .map(Line::from),
        );
    }
    for (title, list) in [
        ("Audio settings", &cfg.audio_settings),
        ("Optional settings", &cfg.optional_settings),
    ] {
        if list.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push(Line::raw(""));
        }
        out.push(heading(format!("{title} for {}:", game.name)));
        for s in list {
            push_setting(&mut out, s, game, width);
        }
    }

    if let Some(ini) = game.install.alsoft_ini.as_ref().filter(|m| !m.is_empty()) {
        if !out.is_empty() {
            out.push(Line::raw(""));
        }
        out.push(heading(format!("OpenAL settings for {}:", game.name)));
        let tested = game.install.alsoft_tested == Some(true);
        for (section, keys) in ini {
            let Value::Object(keys) = keys else { continue };
            for (key, value) in keys {
                out.push(Line::raw(""));
                out.push(Line::from(vec![
                    Span::raw(format!("  {key} = {}", show_value(value))).bold(),
                    Span::raw(" "),
                    tag(tested),
                ]));
                if let Some(help) = alsoft_help(section, key) {
                    out.extend(wrap(help, width, "    ").into_iter().map(Line::from));
                }
                out.push(dim(format!("    In alsoft.ini, section [{section}]")));
            }
        }
        if !tested {
            out.push(dim("    Unverified."));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

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

    const QUAKE: &str = r#"{"id":"q","name":"Quake 4",
      "install":{"alsoft_ini":{"reverb":{"boost":6}},"alsoft_tested":true},
      "game_config":{
        "files":{"Quake4Config.cfg":{"format":"idtech_cfg","locations":["game_exe:q4base/Quake4Config.cfg"]}},
        "audio_settings":[{"title":"Enable EAX effects","tested":true,
          "reason":"Quake 4 ships with its EAX sound options off, so there's no reverb and no muffling of sounds through walls.",
          "changes":{"Quake4Config.cfg":{"s_useOpenAL":"1","s_useEAXReverb":"1","s_numberOfSpeakers":"6"}}},
          {"title":"Enable 5.1 surround sound","reason":"It mixes for two speakers.",
           "only_if":{"speakers":["surround","surround51"],"stores":["steam"]},
           "changes":{"Quake4Config.cfg":{"s_numberOfSpeakers":"6"}}}],
        "optional_settings":[{"title":"Skip intro","tested":true,"reason":"r","follow_up":"Restart the game.\nThen load a save.",
          "changes":{"Quake4Config.cfg":{"com_skipIntro":true,"old_key":null}}}]}}"#;

    #[test]
    fn shows_each_setting_with_its_reason_file_keys_and_values() {
        let t = text(&lines(&game(QUAKE), 100));
        println!("{t}");
        assert!(t.contains("Audio settings for Quake 4:"));
        assert!(t.contains("Optional settings for Quake 4:"));
        assert!(t.contains("  Enable EAX effects (tested)"));
        assert!(t.contains(
            "    Quake4Config.cfg (folder with the game's .exe: q4base/Quake4Config.cfg)"
        ));
        assert!(t.contains("      s_useOpenAL         → 1"));
        assert!(t.contains("      s_numberOfSpeakers  → 6"));
    }

    #[test]
    fn the_reason_is_wrapped_to_the_width() {
        let l = lines(&game(QUAKE), 40);
        // Everything that is prose or a file name fits; only a key row can run on.
        for line in l.iter().map(|x| text(std::slice::from_ref(x))) {
            if !line.contains('→') {
                assert!(line.chars().count() <= 40, "too wide: {line:?}");
            }
        }
        // Wrapping loses nothing: the whole reason reads out in order.
        let flat = text(&l).split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(flat.contains(
            "Quake 4 ships with its EAX sound options off, so there's no reverb and no muffling of sounds through walls."
        ));
    }

    #[test]
    fn untested_settings_say_so_and_scoped_ones_name_their_store_and_speakers() {
        let t = text(&lines(&game(QUAKE), 60));
        assert!(t.contains("Enable 5.1 surround sound (untested)"));
        assert!(t.contains("    Unverified."));
        assert!(t.contains("    Only on Steam"));
        assert!(t.contains("    Only with Surround (any layout) or Surround 5.1"));
    }

    #[test]
    fn booleans_and_removals_read_as_words_and_a_follow_up_keeps_its_line_break() {
        let t = text(&lines(&game(QUAKE), 60));
        assert!(t.contains("com_skipIntro  → on"));
        assert!(t.contains("old_key        → (removed)"));
        assert!(t.contains("    Afterwards:\n    Restart the game.\n    Then load a save."));
    }

    #[test]
    fn the_alsoft_values_come_last_with_a_plain_explanation() {
        let t = text(&lines(&game(QUAKE), 60));
        let at = t.find("OpenAL settings for Quake 4:").unwrap();
        assert!(at > t.find("Optional settings").unwrap());
        assert!(t[at..].contains("boost = 6 (tested)"));
        assert!(t[at..].contains("Makes all reverb louder by this many decibels."));
        assert!(t[at..].contains("In alsoft.ini, section [reverb]"));
    }

    #[test]
    fn ini_files_group_keys_under_their_section() {
        let g = game(
            r#"{"id":"a","name":"A","game_config":{
              "files":{"a.ini":{"format":"ini","locations":["game_root:a.ini","prefix_documents:A/a.ini"],"all_locations":true}},
              "optional_settings":[{"title":"T","reason":"r","tested":true,
                "changes":{"a.ini":{"Audio":{"UseEAX":"1","Rate":"44100"},"Video":{"Fps":"60"}}}}]}}"#,
        );
        let t = text(&lines(&g, 100));
        assert!(
            t.contains("a.ini (game's install folder and Documents in the Wine prefix: A/a.ini)")
        );
        assert!(t.contains("      [Audio]\n        UseEAX  → 1\n        Rate    → 44100\n      [Video]\n        Fps     → 60"));
    }

    #[test]
    fn a_game_with_no_settings_says_so() {
        let t = text(&lines(&game(r#"{"id":"a","name":"Alpha"}"#), 60));
        assert_eq!(t, "Alpha has no game settings in the database.");
    }

    #[test]
    fn location_labels_use_plain_words() {
        assert_eq!(
            location_label("game_exe:a.cfg", "a.cfg"),
            "folder with the game's .exe"
        );
        assert_eq!(
            location_label("game_root:sub/a.cfg", "a.cfg"),
            "game's install folder: sub/a.cfg"
        );
        assert_eq!(location_label("prefix:user.reg", "user.reg"), "Wine prefix");
    }

    #[test]
    fn wrap_keeps_meant_breaks_and_never_splits_a_word() {
        assert_eq!(wrap("aaa bbb ccc", 11, ""), ["aaa bbb ccc"]);
        // Lines are never squeezed below 8 characters of text.
        assert_eq!(wrap("aaa bbb ccc", 10, "  "), ["  aaa bbb", "  ccc"]);
        assert_eq!(wrap("one\n\ntwo", 20, "> "), ["> one", "", "> two"]);
        assert_eq!(
            wrap("supercalifragilistic", 8, ""),
            ["supercalifragilistic"]
        );
    }
}
