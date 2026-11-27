//! The F1 help: every key the program answers to. When a key is added or
//! changed in `app`, change it here too; a test checks the main ones appear.

use crate::settings::wrap;
use crate::theme;
use ratatui::text::{Line, Span};

/// (key, what it does). An empty key starts a heading.
const ROWS: &[(&str, &str)] = &[
    ("", "The basics"),
    ("Type", "Search the game names: any part of a name, words in any order. Letters always go to the search, whichever box has the cursor."),
    ("Tab", "Move to the next box: the views, the filters, the games, the game's details. Shift-Tab goes back. The box you're in has a cyan border."),
    ("↑/↓", "Move through the games; PgUp/PgDn ten at a time. In the game's details, scroll them."),
    ("Enter", "Open the game's page, where you can install or uninstall the EAX fix and change its sound and game settings. If the game wasn't found on this PC, it asks for its folder first. In the filters box, it opens the filters."),
    ("←/→", "In the views, pick one. Beside the games, switch the game's details between its profile and its settings."),
    ("Shift-↑/↓", "Scroll the game's details from anywhere; Shift-PgUp/PgDn a page at a time."),
    ("Esc", "Close the program (Ctrl-C too)."),
    ("Mouse", "The program doesn't use it, so selecting text to copy it works as usual."),
    ("", "The F-keys"),
    ("F1", "Show or hide this help."),
    ("F2", "Opens Settings, where you choose which view the list starts on and your defaults for new installs (the builds, the DLL override, speakers and the VC++ runtime). They're kept for next time."),
    ("F3", "Open the filters."),
    ("F4", "Star the game, or unstar it. Starred games are in Favorites."),
    ("F5", "Look for your games again, after you've installed or moved one."),
    ("F6", "Show the next view: All games → My library → Patched → Favorites. My library is the games found in your Steam, Heroic, Lutris, Bottles or Faugus libraries, plus any you added yourself; Patched is the ones with the EAX fix."),
    ("F7", "Add a game that isn't in the list: choose its folder (Ctrl-A too)."),
    ("F8", "Show the games as a table, with a column for each detail, or as a list beside the game's details."),
    ("F9", "Show the game's details full screen, where ↑/↓ scroll them. Esc comes back (Ctrl-F too)."),
    ("F10", "Close the program."),
    ("", "The filters"),
    ("Space", "Tick or untick a box. Ticking two boxes in one group shows games that match either; boxes in different groups must all match. Nothing ticked shows every game."),
    ("Enter", "Tick the box and close the filters. On a sort order, pick it and close."),
    ("Esc", "Close the filters and put them back as they were."),
    ("Store", "A game on this PC counts under the store you got it from; one that isn't on this PC, under every store that sells it. Delisted games are no longer sold on that store."),
    ("Sort", "A to Z, Best match (the closest names to the search first), or Rating (Verified, Playable, Unsupported, then Unknown)."),
    ("", "On a game's page"),
    ("↑/↓", "Move between the choices, the game's settings and the buttons."),
    ("Tab", "Jump to the next section."),
    ("Enter", "Open a choice's list (Enter picks, Esc keeps it as it was), or press a button."),
    ("Space", "Tick or untick a game setting."),
    ("Esc", "Back to the list. If you changed something and didn't apply it, it asks first."),
    ("PgUp/PgDn", "Scroll through what an install or uninstall did, once it's finished."),
    ("", "Colours on a game's page"),
    ("Green", "A value marked (detected) was worked out from your PC or the game's profile."),
    ("Yellow", "A value you've changed and haven't applied yet."),
    ("", "More keys"),
    ("Ctrl-L", "Put the game's details under the games instead of beside them, and back. They move by themselves when the window gets narrow or wide."),
    ("Ctrl-U", "Clear the search. Backspace deletes a letter."),
    ("", "The marks in the list"),
    ("✓", "The fix is installed."),
    ("Magenta ✓", "The fix is installed, but the game isn't in the game database."),
    ("★", "You starred the game (F4)."),
    ("Bright name", "The game is on this PC."),
    ("Grey name", "The game isn't on this PC."),
    ("[Steam] [GOG]", "You have it from both stores, so each copy names its store."),
    ("Verified", "Someone checked the game on a real install, and EAX works without problems. Playable: EAX works, with a problem the game's profile describes. Unsupported: there's no EAX to restore in this build. Unknown: nobody has checked it yet."),
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
            "F2",
            "F3",
            "F4",
            "F5",
            "F6",
            "F7",
            "F8",
            "F9",
            "F10",
            "Space",
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
        assert!(t.contains(&row("✓", "The fix is installed.")));
        assert!(t.contains(&row("Grey name", "The game isn't on this PC.")));
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
        assert!(t.contains("\n\nThe filters:\n"));
    }
}
