//! Drawing. Reads `App`, never changes it. The look is the old fzf browser's:
//! boxed Search, Filters and Games sections beside a full-height pane, its colours
//! (see `theme`), a counter in the pane's corner, a centred key bar with the
//! version at its right.

use crate::app::{App, Filter, Layout as PaneLayout, Pane};
use crate::filters::Filters;
use crate::games::{Entry, Status};
use crate::help;
use crate::library::StoreKind;
use crate::settings::{self, wrap};
use crate::theme;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Clear, HighlightSpacing, List, ListItem, ListState, Paragraph, Wrap,
};
use ratatui::Frame;
use std::collections::HashSet;

pub fn draw(f: &mut Frame, app: &App) {
    let screen = f.area();
    let bar_height = bar_rows(app, screen.width);
    let [body, bar] =
        Layout::vertical([Constraint::Min(3), Constraint::Length(bar_height)]).areas(screen);
    if app.zoom {
        draw_pane(f, app, body, true);
    } else {
        draw_body(f, app, body);
    }
    draw_bar(f, app, bar);
    // Popups sit over the body and leave the key bar showing.
    if let (Some(menu), Some(e)) = (&app.menu, app.current()) {
        draw_menu(f, menu, &e.name, body);
    }
    if let Some(p) = &app.picker {
        draw_picker(f, p, body);
    }
}

/// A rounded box in the old browser's colours, its title centred in the top edge.
fn boxed(title: &str) -> Block<'static> {
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::new().fg(theme::BORDER))
        .title(Span::styled(
            format!(" {title} "),
            Style::new().fg(theme::LABEL),
        ))
        .title_alignment(Alignment::Center)
}

/// The list and its selection: the chosen row has a dark background and, in
/// front of it, a pink bar (see `gutter`).
fn selection<'a>(list: List<'a>) -> List<'a> {
    list.highlight_style(Style::new().bg(theme::SELECT_BG))
        .highlight_spacing(HighlightSpacing::Never)
}

/// The two columns in front of a row: the bar on the chosen one, blank on the rest.
fn gutter(selected: bool) -> Span<'static> {
    if selected {
        Span::styled(
            "▌ ",
            Style::new()
                .fg(theme::SELECT_BAR)
                .bg(theme::SELECT_BG)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        Span::raw("  ")
    }
}

fn draw_body(f: &mut Frame, app: &App, body: Rect) {
    let (left, pane) = match app.layout {
        PaneLayout::Side => {
            let [l, r] =
                Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)])
                    .areas(body);
            (l, r)
        }
        PaneLayout::Stacked => {
            let [t, p] = Layout::vertical([Constraint::Percentage(45), Constraint::Percentage(55)])
                .areas(body);
            (t, p)
        }
    };
    draw_left(f, app, left);
    draw_pane(f, app, pane, false);
}

/// Search, Filters and Games, one above the other.
fn draw_left(f: &mut Frame, app: &App, area: Rect) {
    let rows = filter_rows(app, area.width.saturating_sub(2));
    let [search, filters, games] = Layout::vertical([
        Constraint::Length(3),
        Constraint::Length(rows + 2),
        Constraint::Min(3),
    ])
    .areas(area);
    draw_search(f, app, search);
    draw_filters(f, app, filters, rows);
    draw_games(f, app, games);
}

fn draw_search(f: &mut Frame, app: &App, area: Rect) {
    let block = boxed("Search");
    let inner = block.inner(area);
    let width = usize::from(inner.width);
    let count = format!("{}/{}", app.visible.len(), app.games.len());
    // " > " in front, the count behind; a long search shows its end.
    let room = width.saturating_sub(count.chars().count() + 4);
    let chars: Vec<char> = app.query.chars().collect();
    let shown: String = chars[chars.len().saturating_sub(room)..].iter().collect();
    let used = 3 + shown.chars().count();
    let pad = width.saturating_sub(used + count.chars().count());
    let line = Line::from(vec![
        Span::raw(" "),
        Span::styled(
            "> ",
            Style::new().fg(theme::PROMPT).add_modifier(Modifier::BOLD),
        ),
        Span::styled(shown, Style::new().add_modifier(Modifier::BOLD)),
        Span::raw(" ".repeat(pad)),
        Span::styled(count, Style::new().fg(theme::COUNT)),
    ]);
    f.render_widget(Paragraph::new(line).block(block), area);
    if app.menu.is_none() && app.picker.is_none() && !app.help {
        f.set_cursor_position((inner.x + u16::try_from(used).unwrap_or(0), inner.y));
    }
}

/// One filter: its key, its name and what it is set to.
struct Cell {
    key: &'static str,
    name: &'static str,
    value: String,
    /// Narrowing the list.
    lit: bool,
}

impl Cell {
    fn width(&self) -> usize {
        self.key.chars().count() + self.name.chars().count() + self.value.chars().count() + 3
    }

    fn spans(&self, pad_to: usize) -> Vec<Span<'static>> {
        let value = Style::new().fg(Color::Green);
        vec![
            Span::styled(self.key, theme::key()),
            Span::raw(" "),
            Span::styled(
                format!("{}:", self.name),
                Style::new().fg(theme::FILTER_LABEL),
            ),
            Span::raw(" "),
            Span::styled(
                self.value.clone(),
                if self.lit {
                    value.add_modifier(Modifier::BOLD)
                } else {
                    value
                },
            ),
            Span::raw(" ".repeat(pad_to.saturating_sub(self.width()))),
        ]
    }
}

fn filter_cells(app: &App) -> [Cell; 4] {
    let d = Filters::default();
    [
        Cell {
            key: "Tab",
            name: "Show",
            value: app.filter.label().to_string(),
            lit: app.filter != Filter::All,
        },
        Cell {
            key: "Ctrl-S",
            name: "Store",
            value: app.filters.store.label().to_string(),
            lit: app.filters.store != d.store,
        },
        Cell {
            key: "Ctrl-E",
            name: "Audio",
            value: app.filters.audio.label(),
            lit: app.filters.audio != d.audio,
        },
        Cell {
            key: "Ctrl-T",
            name: "Tested",
            value: app.filters.tested.label().to_string(),
            lit: app.filters.tested != d.tested,
        },
    ]
}

/// Rows the four filters need: one line, two by two, or one under another.
fn filter_rows(app: &App, inner_width: u16) -> u16 {
    let cells = filter_cells(app);
    let room = usize::from(inner_width);
    let all: usize = cells.iter().map(Cell::width).sum::<usize>() + 3 * 3 + 2;
    let two =
        cells[0].width().max(cells[2].width()) + 3 + cells[1].width().max(cells[3].width()) + 2;
    if all <= room {
        1
    } else if two <= room {
        2
    } else {
        4
    }
}

fn draw_filters(f: &mut Frame, app: &App, area: Rect, rows: u16) {
    let cells = filter_cells(app);
    let lead = || Span::raw(" ");
    let line = |cells: &[&Cell], first: usize| {
        let mut spans = vec![lead()];
        for (i, c) in cells.iter().enumerate() {
            if i == 0 {
                spans.extend(c.spans(first));
            } else {
                spans.push(Span::raw("   "));
                spans.extend(c.spans(0));
            }
        }
        Line::from(spans)
    };
    let lines: Vec<Line> = match rows {
        1 => vec![line(&cells.iter().collect::<Vec<_>>(), 0)],
        // Two columns, lined up on the wider cell of the first.
        2 => {
            let first = cells[0].width().max(cells[2].width());
            vec![
                line(&[&cells[0], &cells[1]], first),
                line(&[&cells[2], &cells[3]], first),
            ]
        }
        _ => cells.iter().map(|c| line(&[c], 0)).collect(),
    };
    f.render_widget(Paragraph::new(lines).block(boxed("Filters")), area);
}

fn draw_games(f: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app
        .visible
        .iter()
        .enumerate()
        .map(|(row, &i)| ListItem::new(game_line(app, &app.games[i], row == app.selected)))
        .collect();
    let list = selection(List::new(items).block(boxed("Games")));
    let mut state = ListState::default().with_selected(app.current().map(|_| app.selected));
    f.render_stateful_widget(list, area, &mut state);
}

/// A row: its mark, then the name with the letters the search matched lit.
fn game_line(app: &App, e: &Entry, selected: bool) -> Line<'static> {
    let (mark, colour) = marker(e.status);
    let (base, hit) = if selected {
        (
            Style::new()
                .fg(theme::SELECT_TEXT)
                .add_modifier(Modifier::BOLD),
            Style::new()
                .fg(theme::SELECT_MATCH)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        (Style::new(), Style::new().fg(theme::MATCH))
    };
    let matched: HashSet<u32> = app.match_indices(&e.name).into_iter().collect();
    let mut spans = vec![
        gutter(selected),
        Span::styled(mark, Style::new().fg(colour)),
        Span::raw(" "),
    ];
    let mut run = String::new();
    let mut run_hit = false;
    for (i, c) in e.name.chars().enumerate() {
        let is_hit = matched.contains(&(i as u32));
        if is_hit != run_hit && !run.is_empty() {
            spans.push(Span::styled(
                std::mem::take(&mut run),
                if run_hit { hit } else { base },
            ));
        }
        run_hit = is_hit;
        run.push(c);
    }
    if !run.is_empty() {
        spans.push(Span::styled(run, if run_hit { hit } else { base }));
    }
    Line::from(spans)
}

/// What the right-hand pane is showing.
#[derive(Clone, Copy, PartialEq)]
enum View {
    Help,
    Settings,
    Profile,
}

/// The right-hand pane: help, the settings or the profile. `zoomed` is the
/// full-screen view, where the game's name goes in the title because the list is
/// hidden.
fn draw_pane(f: &mut Frame, app: &App, area: Rect, zoomed: bool) {
    let current = app.current();
    let view = if app.help {
        View::Help
    } else if app.pane == Pane::Settings && current.is_some() {
        View::Settings
    } else {
        View::Profile
    };
    let name = match view {
        View::Help => "Help",
        View::Settings => "Game settings",
        View::Profile => "Game profile",
    };
    let title = match current.filter(|_| zoomed && view != View::Help) {
        Some(e) => format!("{}: {name}", e.name),
        None => name.to_string(),
    };
    let block = boxed(&title);
    let inner = block.inner(area);
    let width = usize::from(inner.width);

    // The first row is kept free for the scroll position, as in the old browser.
    let mut lines = vec![Line::raw("")];
    match view {
        View::Help => lines.extend(help::lines(width)),
        View::Settings => lines.extend(match current.and_then(|e| e.game.as_ref()) {
            Some(g) => settings::lines(g, width),
            None => wrap(
                &format!(
                    "The game database has no profile for {}.",
                    current.map_or("", |e| e.name.as_str())
                ),
                width,
                "",
            )
            .into_iter()
            .map(Line::from)
            .collect(),
        }),
        View::Profile => lines.extend(match current {
            Some(e) => profile(e, width),
            None => vec![
                Line::from("No game matches.").dim(),
                Line::from("Press Ctrl-A to add a game by its folder.").dim(),
            ],
        }),
    }

    let total = lines.len();
    let max = u16::try_from(total.saturating_sub(usize::from(inner.height))).unwrap_or(u16::MAX);
    let (scroll, max_cell) = if view == View::Help {
        (app.help_scroll, &app.help_max)
    } else {
        (app.pane_scroll, &app.pane_max)
    };
    max_cell.set(max);
    let top = scroll.min(max);
    f.render_widget(Paragraph::new(lines).scroll((top, 0)).block(block), area);

    if inner.height > 0 {
        let position = format!("{}/{total}", usize::from(top) + 1);
        f.render_widget(
            Paragraph::new(Span::styled(
                position,
                Style::new()
                    .fg(theme::COUNT)
                    .add_modifier(Modifier::REVERSED),
            ))
            .alignment(Alignment::Right),
            Rect::new(inner.x, inner.y, inner.width, 1),
        );
    }
}

/// The key bar: each key in cyan, what it does after it.
fn bar_items(app: &App) -> Vec<(&'static str, &'static str)> {
    if app.help {
        vec![("↑/↓", "scroll"), ("Esc or F1", "close")]
    } else if app.picker.is_some() {
        vec![
            ("↑/↓", "move"),
            ("Enter", "open"),
            ("←/Backspace", "up"),
            ("Space", "use this folder"),
            (".", "show hidden folders"),
            ("~", "home"),
            ("Esc", "cancel"),
        ]
    } else if app.menu.is_some() {
        vec![("↑/↓", "choose"), ("Enter", "run"), ("Esc", "back")]
    } else if app.zoom {
        vec![
            ("↑/↓", "scroll"),
            ("←/→", "Profile/Settings"),
            ("Enter", "actions"),
            ("F1", "help"),
            ("Esc", "back"),
        ]
    } else if app.pane == Pane::Settings {
        vec![
            ("Shift-↑/↓", "scroll"),
            ("Ctrl-F", "full screen"),
            ("←/→", "Profile/Settings"),
            ("Enter", "actions"),
            ("F1", "help"),
            ("Esc", "quit"),
        ]
    } else {
        vec![
            ("Type", "to filter"),
            ("Enter", "actions"),
            ("←/→", "Profile/Settings"),
            ("Ctrl-A", "add game"),
            ("F1", "help"),
            ("Esc", "quit"),
        ]
    }
}

/// How wide the bar is on one line.
fn bar_len(app: &App) -> usize {
    if !app.message.is_empty() {
        return app.message.chars().count();
    }
    let items = bar_items(app);
    let text: usize = items
        .iter()
        .map(|(k, d)| k.chars().count() + 1 + d.chars().count())
        .sum();
    text + 3 * items.len().saturating_sub(1)
}

/// Rows the bar needs at this width: one, or two when the text would be cut off.
fn bar_rows(app: &App, width: u16) -> u16 {
    if bar_len(app) > usize::from(width) {
        2
    } else {
        1
    }
}

fn version() -> String {
    let dev = if crate::fetch::CHANNEL == "dev" {
        "-dev"
    } else {
        ""
    };
    format!("v{}{dev}", env!("CARGO_PKG_VERSION"))
}

fn draw_bar(f: &mut Frame, app: &App, area: Rect) {
    if !app.message.is_empty() {
        f.render_widget(
            Paragraph::new(app.message.as_str())
                .style(Style::new().fg(Color::Yellow).add_modifier(Modifier::BOLD))
                .alignment(Alignment::Center)
                .wrap(Wrap { trim: true }),
            area,
        );
        return;
    }
    let mut spans = Vec::new();
    for (i, (key, what)) in bar_items(app).into_iter().enumerate() {
        if i > 0 {
            spans.push(Span::styled(" · ", theme::dim()));
        }
        spans.push(Span::styled(key, theme::key()));
        spans.push(Span::raw(format!(" {what}")));
    }
    f.render_widget(
        Paragraph::new(Line::from(spans))
            .alignment(Alignment::Center)
            .wrap(Wrap { trim: true }),
        area,
    );
    // The version at the right edge, if the centred keys leave room for it.
    let v = version();
    let room = usize::from(area.width).saturating_sub(bar_len(app)) / 2;
    if area.height == 1 && room > v.chars().count() + 1 {
        let w = u16::try_from(v.chars().count()).unwrap_or(0);
        f.render_widget(
            Paragraph::new(Span::styled(v, theme::dim())),
            Rect::new(area.x + area.width - w - 1, area.y, w, 1),
        );
    }
}

fn draw_picker(f: &mut Frame, p: &crate::picker::Picker, area: Rect) {
    let w = area.width.min(90);
    let h = area.height.saturating_sub(2).max(3).min(area.height);
    let popup = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, popup);
    let block = boxed("Choose the folder with the game's .exe");
    let inner = block.inner(popup);
    f.render_widget(block, popup);
    let parts = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(1)])
        .split(inner);

    let exes = match p.exes {
        0 => "No .exe files in this folder.".to_string(),
        1 => "1 .exe file in this folder.".to_string(),
        n => format!("{n} .exe files in this folder."),
    };
    let head = Paragraph::new(vec![
        Line::from(p.shown_dir()).bold().cyan(),
        if p.exes == 0 {
            Line::from(exes).yellow()
        } else {
            Line::from(exes).green()
        },
    ]);
    f.render_widget(head, parts[0]);

    let items: Vec<ListItem> = if p.dirs.is_empty() {
        vec![ListItem::new("  (no folders here)").dim()]
    } else {
        p.dirs
            .iter()
            .enumerate()
            .map(|(i, d)| {
                ListItem::new(Line::from(vec![
                    gutter(i == p.selected),
                    Span::raw(format!("{d}/")),
                ]))
            })
            .collect()
    };
    let list = selection(List::new(items));
    let selected = if p.dirs.is_empty() {
        None
    } else {
        Some(p.selected)
    };
    f.render_stateful_widget(
        list,
        parts[1],
        &mut ListState::default().with_selected(selected),
    );
}

fn draw_menu(f: &mut Frame, menu: &crate::app::Menu, title: &str, area: Rect) {
    let widest = menu
        .actions
        .iter()
        .map(|a| a.label().chars().count())
        .max()
        .unwrap_or(0);
    let w = ((widest + 8).max(title.chars().count() + 6) as u16).min(area.width);
    let h = (menu.actions.len() as u16 + 2).min(area.height);
    let popup = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    let items: Vec<ListItem> = menu
        .actions
        .iter()
        .enumerate()
        .map(|(i, a)| {
            ListItem::new(Line::from(vec![
                gutter(i == menu.selected),
                Span::raw(a.label()),
            ]))
        })
        .collect();
    let list = selection(List::new(items).block(boxed(title)));
    f.render_widget(Clear, popup);
    f.render_stateful_widget(
        list,
        popup,
        &mut ListState::default().with_selected(Some(menu.selected)),
    );
}

/// Plain ASCII so the column lines up in every terminal; the profile pane spells
/// the status out.
fn marker(s: Status) -> (&'static str, Color) {
    match s {
        Status::Installed => ("+", Color::Green),
        Status::OnThisPc => ("o", Color::Cyan),
        Status::NotOnThisPc => (" ", Color::Reset),
        Status::Manual => ("*", Color::Magenta),
    }
}

/// `Label: value`, wrapped to `width`, the label in bold.
fn field(label: &str, value: impl Into<String>, width: usize) -> Vec<Line<'static>> {
    let prefix = format!("{label}: ");
    let wrapped = wrap(&format!("{prefix}{}", value.into()), width, "");
    wrapped
        .into_iter()
        .enumerate()
        .map(|(i, text)| match text.strip_prefix(&prefix) {
            Some(rest) if i == 0 => Line::from(vec![
                Span::styled(prefix.clone(), theme::label()),
                Span::raw(rest.to_string()),
            ]),
            _ => Line::from(text),
        })
        .collect()
}

fn profile(e: &Entry, width: usize) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(e.name.clone()).bold().cyan(), Line::raw("")];
    let (_, colour) = marker(e.status);
    lines.push(Line::from(vec![
        Span::styled("Status: ", theme::label()),
        Span::styled(e.status.label(), Style::new().fg(colour)),
    ]));
    if let Some(p) = &e.path {
        let store = match e.store {
            Some(StoreKind::Steam) => " (Steam)",
            Some(StoreKind::Gog) => " (GOG)",
            None => "",
        };
        lines.extend(field("Folder", format!("{}{store}", p.display()), width));
    }
    let Some(g) = &e.game else {
        lines.push(Line::raw(""));
        lines.extend(
            wrap(
                &format!("The game database has no profile for {}.", e.name),
                width,
                "",
            )
            .into_iter()
            .map(Line::from),
        );
        return lines;
    };
    if !g.released.is_empty() {
        lines.extend(field("Released", g.released.clone(), width));
    }
    let mut stores = Vec::new();
    if let Some(s) = &g.stores.steam {
        stores.push(format!("Steam {}", s.id));
    }
    if let Some(s) = &g.stores.gog {
        stores.push(format!("GOG {}", s.id));
    }
    if !stores.is_empty() {
        lines.extend(field("Stores", stores.join(", "), width));
    }
    if !g.eax.api.is_empty() {
        let versions = if g.eax.versions.is_empty() {
            String::new()
        } else {
            format!(" (EAX {})", g.eax.versions.join(", "))
        };
        lines.extend(field("Audio", format!("{}{}", g.eax.api, versions), width));
    }
    lines.extend(field(
        "Tested",
        if g.tested { "yes" } else { "not yet" },
        width,
    ));
    if !g.description.is_empty() {
        lines.push(Line::raw(""));
        lines.extend(wrap(&g.description, width, "").into_iter().map(Line::from));
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use ratatui::backend::TestBackend;
    use ratatui::Terminal;
    use std::path::PathBuf;

    fn screen(app: &App, w: u16, h: u16) -> String {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, app)).unwrap();
        let buf = t.backend().buffer().clone();
        (0..h)
            .map(|y| (0..w).map(|x| buf[(x, y)].symbol()).collect::<String>())
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn entries(json: &str) -> Vec<Entry> {
        Database::parse(json)
            .unwrap()
            .games
            .into_iter()
            .map(Entry::database_only)
            .collect()
    }

    #[test]
    fn shows_the_list_and_the_selected_games_profile() {
        let mut games = entries(
            r#"{"games":[{"id":"a","name":"Alpha Centauri","released":"1999-02-09",
            "stores":{"steam":{"id":2204130}},"eax":{"api":"directsound3d","versions":["1.0"]}}]}"#,
        );
        games[0].status = Status::Installed;
        games[0].store = Some(StoreKind::Steam);
        games[0].path = Some(PathBuf::from("/lib/Alpha"));
        let s = screen(&App::new(games), 100, 14);
        println!("{s}");
        assert!(s.contains(" Search "));
        assert!(s.contains("1/1"));
        assert!(s.contains("Show: All games"));
        assert!(s.contains("Ctrl-E Audio: Any audio"));
        assert!(s.contains("+ Alpha Centauri"));
        assert!(s.contains("Status: Installed"));
        assert!(s.contains("Folder: /lib/Alpha (Steam)"));
        assert!(s.contains("directsound3d (EAX 1.0)"));
    }

    #[test]
    fn a_manual_game_says_the_database_has_no_profile() {
        let manual = Entry {
            name: "Obscure".into(),
            status: Status::Manual,
            game: None,
            store: None,
            path: Some(PathBuf::from("/g/Obscure")),
        };
        let s = screen(&App::new(vec![manual]), 100, 14);
        assert!(s.contains("* Obscure"));
        assert!(s.contains("no profile for Obscure."));
    }

    #[test]
    fn an_empty_result_says_so_and_does_not_panic() {
        let mut app = App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#));
        app.query = "zzz".into();
        app.visible.clear();
        assert!(screen(&app, 60, 10).contains("No game matches."));
    }

    #[test]
    fn a_tiny_terminal_does_not_panic() {
        screen(
            &App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#)),
            10,
            3,
        );
    }

    #[test]
    fn the_action_menu_lists_what_applies_to_the_game() {
        let mut games = entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#);
        games[0].status = Status::Installed;
        games[0].path = Some(PathBuf::from("/g/Alpha"));
        let mut app = App::new(games);
        app.handle_key(ratatui::crossterm::event::KeyEvent::from(
            ratatui::crossterm::event::KeyCode::Enter,
        ));
        let s = screen(&app, 100, 20);
        println!("{s}");
        assert!(s.contains("Install again"));
        assert!(s.contains("Uninstall the EAX fix"));
        assert!(s.contains("Esc back"));
    }

    #[test]
    fn a_message_replaces_the_key_bar() {
        let mut app = App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#));
        app.message = "Can't find the installer script.".into();
        assert!(screen(&app, 80, 10).contains("Can't find the installer script."));
    }

    #[test]
    fn the_picker_shows_the_folder_its_exe_count_and_its_sub_folders() {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join("Games/Heroic/Some Game")).unwrap();
        std::fs::write(home.path().join("Games/Heroic/launcher.exe"), "").unwrap();
        let mut app = App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#));
        app.set_home(home.path().to_path_buf());
        app.handle_key(ratatui::crossterm::event::KeyEvent::new(
            ratatui::crossterm::event::KeyCode::Char('a'),
            ratatui::crossterm::event::KeyModifiers::CONTROL,
        ));
        let s = screen(&app, 100, 16);
        println!("{s}");
        assert!(s.contains("Choose the folder with the game's .exe"));
        assert!(s.contains("~/Games/Heroic"));
        assert!(s.contains("1 .exe file in this folder."));
        assert!(s.contains("Some Game/"));
        assert!(s.contains("Space use this folder"));
    }

    #[test]
    fn a_filter_that_narrows_the_list_is_named_on_screen() {
        let mut app = App::new(entries(
            r#"{"games":[{"id":"a","name":"Alpha","stores":{"gog":{"id":1}}}]}"#,
        ));
        app.handle_key(ratatui::crossterm::event::KeyEvent::new(
            ratatui::crossterm::event::KeyCode::Char('s'),
            ratatui::crossterm::event::KeyModifiers::CONTROL,
        ));
        let s = screen(&app, 110, 12);
        assert!(s.contains("Store: Steam"));
        assert!(s.contains("No game matches."));
    }

    #[test]
    fn the_filters_wrap_on_a_narrow_terminal_without_losing_the_list() {
        let app = App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#));
        let s = screen(&app, 70, 14);
        assert!(s.contains("Ctrl-T Tested: Any"));
        assert!(s.contains("Alpha"));
    }

    const WITH_SETTINGS: &str = r#"{"games":[{"id":"q","name":"Quake 4",
      "game_config":{
        "files":{"q.cfg":{"format":"idtech_cfg","locations":["game_exe:q4base/q.cfg"]}},
        "audio_settings":[{"title":"Enable EAX effects","tested":true,"reason":"It ships with EAX off.",
          "changes":{"q.cfg":{"s_useOpenAL":"1"}}}]}}]}"#;

    fn press(app: &mut App, code: ratatui::crossterm::event::KeyCode) {
        app.handle_key(ratatui::crossterm::event::KeyEvent::from(code));
    }

    #[test]
    fn the_right_arrow_shows_the_settings_and_the_title_names_both_views() {
        let mut app = App::new(entries(WITH_SETTINGS));
        let before = screen(&app, 100, 20);
        assert!(before.contains("Game profile"));
        assert!(!before.contains("Enable EAX effects"));
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        let s = screen(&app, 100, 20);
        println!("{s}");
        assert!(s.contains("Audio settings for Quake 4:"));
        assert!(s.contains("Enable EAX effects (tested)"));
        assert!(s.contains("s_useOpenAL  → 1"));
        assert!(s.contains("Shift-↑/↓ scroll"));
    }

    #[test]
    fn a_long_settings_list_scrolls_and_stops_at_its_end() {
        let many: String = (0..30)
            .map(|i| format!(r#"{{"title":"Setting {i}","tested":true,"reason":"r","changes":{{"q.cfg":{{"k{i}":"1"}}}}}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let json = format!(
            r#"{{"games":[{{"id":"q","name":"Quake 4","game_config":{{"files":{{"q.cfg":{{"format":"idtech_cfg"}}}},"audio_settings":[{many}]}}}}]}}"#
        );
        let mut app = App::new(entries(&json));
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        assert!(screen(&app, 100, 20).contains("Setting 0"));
        assert!(app.pane_max.get() > 0);
        for _ in 0..500 {
            app.handle_key(ratatui::crossterm::event::KeyEvent::new(
                ratatui::crossterm::event::KeyCode::Down,
                ratatui::crossterm::event::KeyModifiers::SHIFT,
            ));
        }
        let end = screen(&app, 100, 20);
        assert!(end.contains("Setting 29"));
        assert!(!end.contains("Setting 0 "));
        assert_eq!(app.pane_scroll, app.pane_max.get());
    }

    #[test]
    fn a_game_the_database_lacks_has_no_settings_to_show() {
        let manual = Entry {
            name: "Obscure".into(),
            status: Status::Manual,
            game: None,
            store: None,
            path: None,
        };
        let mut app = App::new(vec![manual]);
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        assert!(screen(&app, 100, 14).contains("The game database has no profile for Obscure."));
    }

    fn ctrl_key(app: &mut App, c: char) {
        app.handle_key(ratatui::crossterm::event::KeyEvent::new(
            ratatui::crossterm::event::KeyCode::Char(c),
            ratatui::crossterm::event::KeyModifiers::CONTROL,
        ));
    }

    #[test]
    fn f1_shows_the_key_list_over_the_screen_and_the_bar_says_how_to_close_it() {
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        let s = screen(&app, 100, 70);
        println!("{s}");
        assert!(s.contains(" Help "));
        assert!(s.contains("The basics:"));
        assert!(s.contains("Ctrl-F"));
        assert!(s.contains("The marks in the list"));
        assert!(s.contains("Esc or F1 close"));
    }

    #[test]
    fn on_a_short_terminal_the_help_scrolls_to_its_last_line() {
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        assert!(!screen(&app, 100, 14).contains("The game isn't on this PC."));
        assert!(app.help_max.get() > 0);
        press(&mut app, ratatui::crossterm::event::KeyCode::End);
        assert!(screen(&app, 100, 14).contains("The game isn't on this PC."));
    }

    #[test]
    fn full_screen_hides_the_list_and_names_the_game_in_the_title() {
        let mut app = App::new(entries(WITH_SETTINGS));
        let normal = screen(&app, 100, 20);
        assert!(normal.contains(" Games "));
        assert!(normal.contains(" Search "));
        ctrl_key(&mut app, 'f');
        let s = screen(&app, 100, 20);
        println!("{s}");
        assert!(!s.contains(" Games "));
        assert!(!s.contains(" Search "));
        assert!(s.contains("Quake 4: Game profile"));
        assert!(s.contains("Esc back"));
    }

    #[test]
    fn full_screen_settings_use_the_whole_width() {
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        ctrl_key(&mut app, 'f');
        let wide = screen(&app, 120, 20);
        // The folder label fits on one line only because the pane is wide now.
        assert!(wide.contains("q.cfg (folder with the game's .exe: q4base/q.cfg)"));
    }

    #[test]
    fn the_help_also_opens_from_full_screen_and_returns_there() {
        let mut app = App::new(entries(WITH_SETTINGS));
        ctrl_key(&mut app, 'f');
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        assert!(screen(&app, 100, 30).contains(" Help "));
        press(&mut app, ratatui::crossterm::event::KeyCode::Esc);
        let s = screen(&app, 100, 30);
        assert!(!s.contains(" Help "));
        assert!(s.contains("Quake 4: Game profile"));
    }

    fn row_of(screen: &str, needle: &str) -> usize {
        screen.lines().position(|l| l.contains(needle)).unwrap()
    }

    /// Where along its line the text starts, in characters.
    fn col_of(screen: &str, needle: &str) -> usize {
        let line = screen.lines().find(|l| l.contains(needle)).unwrap();
        line.chars().count()
            - line.split(needle).last().unwrap().chars().count()
            - needle.chars().count()
    }

    #[test]
    fn the_pane_is_beside_the_list_on_a_wide_window_and_under_it_on_a_narrow_one() {
        let mut app = App::new(entries(WITH_SETTINGS));
        app.resize(120);
        let wide = screen(&app, 120, 24);
        // Beside the list: the pane is to its right and starts at the top.
        assert!(col_of(&wide, "Game profile") > col_of(&wide, " Games "));
        assert!(row_of(&wide, "Game profile") < row_of(&wide, " Games "));
        app.resize(90);
        let narrow = screen(&app, 90, 24);
        println!("{narrow}");
        assert!(row_of(&narrow, " Games ") < row_of(&narrow, "Game profile"));
        // Both still show their text.
        assert!(narrow.contains("Quake 4"));
        assert!(narrow.contains("Status:"));
    }

    #[test]
    fn ctrl_l_moves_the_pane_under_the_list_on_a_wide_window() {
        let mut app = App::new(entries(WITH_SETTINGS));
        app.resize(120);
        ctrl_key(&mut app, 'l');
        let s = screen(&app, 120, 24);
        assert!(row_of(&s, " Games ") < row_of(&s, "Game profile"));
    }

    #[test]
    fn a_stacked_layout_on_a_tiny_terminal_does_not_panic() {
        let mut app = App::new(entries(WITH_SETTINGS));
        app.resize(20);
        screen(&app, 20, 6);
    }

    #[test]
    fn the_key_bar_wraps_instead_of_being_cut_off_on_a_narrow_window() {
        let app = App::new(entries(WITH_SETTINGS));
        let narrow = screen(&app, 60, 20);
        println!("{narrow}");
        assert!(narrow.contains("Esc quit"), "the end of the bar is lost");
        assert!(narrow.contains("Type to filter"));
        // On a wide window it needs only the last row.
        let wide = screen(&app, 130, 20);
        assert!(wide.lines().last().unwrap().contains("Esc quit"));
    }

    #[test]
    fn a_long_message_wraps_too() {
        let mut app = App::new(entries(WITH_SETTINGS));
        app.message =
            "Couldn't download the installer script. Check your internet connection and try again."
                .into();
        assert!(screen(&app, 50, 14).contains("try again."));
    }

    #[test]
    fn popups_leave_a_wrapped_key_bar_showing() {
        let home = tempfile::tempdir().unwrap();
        let mut app = App::new(entries(WITH_SETTINGS));
        app.set_home(home.path().to_path_buf());
        ctrl_key(&mut app, 'a');
        // The picker's bar needs two rows at this width; the popup must not cover them.
        let s = screen(&app, 70, 16);
        println!("{s}");
        assert!(s.contains("Esc cancel"));
        assert!(s.contains("Space use this folder"));
    }
}
