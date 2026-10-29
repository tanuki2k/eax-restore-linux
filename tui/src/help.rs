//! The F1 help: every key the program answers to. When a key is added or
//! changed in `app`, change it here too; a test checks the main ones appear.

use crate::settings::wrap;
use crate::theme;
use ratatui::text::{Line, Span};

/// (key, what it does). An empty key starts a heading.
const ROWS: &[(&str, &str)] = &[
    ("", "The basics"),
    ("F1", "Show or hide this help."),
    ("Type", "Search the game names: any part of a name, words in any order."),
    ("↑/↓", "Move through the list; PgUp/PgDn ten at a time."),
    ("Enter", "Open the actions for the game: install, uninstall, settings and more."),
    ("←/→", "Switch the right pane between the game's profile and its settings."),
    ("Shift-↑/↓", "Scroll the right pane; Shift-PgUp/PgDn a page at a time."),
    ("Esc", "Close the program (Ctrl-C too)."),
    ("Mouse", "The program doesn't use it, so selecting text to copy it works as usual."),
    ("", "Filters"),
    (
        "Tab",
        "Show: All games → On this PC → Installed. On this PC means found in your Steam or Heroic libraries, or installed by hand.",
    ),
    (
        "Ctrl-S",
        "Store: All stores → Steam → GOG → Delisted → Delisted on Steam → Delisted on GOG. Delisted games are no longer sold on that store. A game on this PC is listed under the store you got it from; one that isn't on this PC, under every store that sells it.",
    ),
    ("Ctrl-E", "Audio: Any audio → DirectSound3D → OpenAL → EAX 1.0 … 5.0."),
    ("Ctrl-T", "Tested: Any → Yes → Not yet. Yes means checked on a real install."),
    ("", "Adding and viewing"),
    ("Ctrl-A", "Add a game that isn't in the list: choose its folder."),
    ("Ctrl-F", "Show the right pane full screen, where ↑/↓ scroll it. Esc or Ctrl-F comes back."),
    ("Ctrl-L", "Put the right pane under the list instead of beside it, and back. It moves by itself when the window gets narrow or wide."),
    ("Ctrl-U", "Clear the search. Backspace deletes a letter."),
    ("", "The marks in the list"),
    ("+", "The fix is installed."),
    ("o", "The game is on this PC, without the fix."),
    ("*", "The fix is installed, but the game isn't in the game database."),
    ("(blank)", "The game isn't on this PC."),
];

/// The key column, as the old browser's `browse_help` set it: a space, the key
/// padded to 13, a space, then the text.
const KEY_COLUMN: usize = 13;

pub fn lines(width: usize) -> Vec<Line<'static>> {
    let text_width = width.saturating_sub(KEY_COLUMN + 2);
    let mut out = Vec::new();
    for (key, text) in ROWS {
        if key.is_empty() {
            out.push(Line::raw(""));
            out.push(Line::from(Span::styled(format!("{text}:"), theme::white())));
            continue;
        }
        for (i, part) in wrap(text, text_width, "").into_iter().enumerate() {
            let lead = if i == 0 {
                Span::styled(format!(" {key:<KEY_COLUMN$} "), theme::key())
            } else {
                Span::raw(" ".repeat(KEY_COLUMN + 2))
            };
            out.push(Line::from(vec![lead, Span::raw(part)]));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

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

    #[test]
    fn every_main_key_is_explained() {
        let t = text(&lines(80));
        for key in [
            "F1",
            "Enter",
            "Tab",
            "Ctrl-S",
            "Ctrl-E",
            "Ctrl-T",
            "Ctrl-A",
            "Ctrl-F",
            "Ctrl-L",
            "Ctrl-U",
            "Shift-↑/↓",
            "←/→",
            "Esc",
        ] {
            assert!(t.contains(key), "help does not mention {key}");
        }
    }

    #[test]
    fn the_list_marks_are_explained() {
        let t = text(&lines(80));
        let row = |key: &str, text: &str| format!(" {key:<13} {text}");
        assert!(t.contains(&row("+", "The fix is installed.")));
        assert!(t.contains(&row(
            "*",
            "The fix is installed, but the game isn't in the game database."
        )));
    }

    #[test]
    fn long_entries_wrap_under_their_own_text_not_the_key() {
        let l = lines(50);
        let t = text(&l);
        // A wrapped entry continues under its own text, in the key column's width.
        assert!(t
            .lines()
            .any(|l| l.starts_with("            ") && !l.trim().is_empty()));
        for line in t.lines() {
            assert!(line.chars().count() <= 50, "too wide: {line:?}");
        }
    }

    #[test]
    fn headings_are_separated_by_a_blank_line() {
        let t = text(&lines(80));
        // Each heading has a blank line before it, even the first, as in the old help.
        assert!(t.starts_with("\nThe basics:\n"));
        assert!(t.contains("\n\nFilters:\n"));
    }
}
