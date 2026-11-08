//! The old browser's colours: fzf's own palette (as the terminal's 256-colour
//! numbers) and the script's ANSI colours (`GREEN`, `YELLOW`, `WHITE`... in
//! src/globals.sh), so the two look alike.

use ratatui::style::{Color, Modifier, Style};

/// Box borders.
pub const BORDER: Color = Color::Indexed(59);
/// Box titles ("Search", "Games").
pub const LABEL: Color = Color::Indexed(145);
/// The search prompt.
pub const PROMPT: Color = Color::Indexed(110);
/// The counts: "12/96" in the search box, the pane's scroll position.
pub const COUNT: Color = Color::Indexed(144);
/// A filter's name, between its key and its value.
pub const FILTER_LABEL: Color = Color::Indexed(109);
/// The selected row's bar, background, text and matched letters.
pub const SELECT_BAR: Color = Color::Indexed(161);
pub const SELECT_BG: Color = Color::Indexed(236);
pub const SELECT_TEXT: Color = Color::Indexed(254);
pub const SELECT_MATCH: Color = Color::Indexed(151);
/// Matched letters in the other rows.
pub const MATCH: Color = Color::Indexed(108);

// The script prints these as bold + a plain colour (`\033[1;33m`), which a
// terminal draws in the bright shade of that colour. ratatui's `Color::Yellow`
// is written as the dark entry (38;5;3), so the bold ones use the Light* names,
// which are the bright entries (38;5;11).

/// `WHITE` in the script: bold, for headings and values.
pub fn white() -> Style {
    Style::new().fg(Color::White).add_modifier(Modifier::BOLD)
}

/// `YELLOW`: the labels in front of a value.
pub fn label() -> Style {
    Style::new()
        .fg(Color::LightYellow)
        .add_modifier(Modifier::BOLD)
}

/// A key name: bold cyan.
pub fn key() -> Style {
    Style::new()
        .fg(Color::LightCyan)
        .add_modifier(Modifier::BOLD)
}

/// `GREEN` + `BOLD`: the EAX versions a game supports.
pub fn strong_green() -> Style {
    Style::new()
        .fg(Color::LightGreen)
        .add_modifier(Modifier::BOLD)
}

/// `GREEN`: good news, and values being set.
pub fn green() -> Style {
    Style::new().fg(Color::Green)
}

/// `NOTE`: a section heading in the profile, and "untested".
pub fn note() -> Style {
    Style::new().fg(Color::LightBlue)
}

/// `DIM`.
pub fn dim() -> Style {
    Style::new().add_modifier(Modifier::DIM)
}
