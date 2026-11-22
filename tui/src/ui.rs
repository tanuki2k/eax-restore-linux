//! Drawing. Reads `App`, never changes it. The look is the old fzf browser's:
//! boxed Search, Filters and Games sections beside a full-height pane, its colours
//! (see `theme`), a counter in the pane's corner, a centred key bar with the
//! build number at its right.

use crate::app::{App, Filter, Layout as PaneLayout, Pane};
use crate::filters::Filters;
use crate::games::{Entry, Status};
use crate::help;
use crate::profile;
use crate::settings::{self, wrap};
use crate::theme;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{
    Block, BorderType, Clear, HighlightSpacing, List, ListItem, ListState, Padding, Paragraph, Wrap,
};
use ratatui::Frame;
use std::collections::HashSet;

pub fn draw(f: &mut Frame, app: &App) {
    let screen = f.area();
    let bar_height = bar_rows(app, screen.width);
    let [body, bar] =
        Layout::vertical([Constraint::Min(3), Constraint::Length(bar_height)]).areas(screen);
    draw_bar(f, app, bar);
    if app.zoom {
        draw_pane(f, app, body, true);
    } else {
        draw_body(f, app, body);
    }
    // A game's page is a pop-up: the list stays in sight round it.
    if let Some(p) = &app.panel {
        crate::panel::view::draw(f, p, body);
        if app.help {
            draw_help(f, app, body);
        }
        return;
    }
    // Popups sit over the body and leave the key bar showing.
    if let Some(p) = &app.picker {
        draw_picker(f, p, body);
    }
    if let Some(s) = &app.prefs {
        s.draw(f, body);
    }
    if let Some(n) = &app.notice {
        draw_notice(f, n, body);
    }
    if app.help {
        draw_help(f, app, body);
    }
}

/// The pop-up for a game with no EAX or no prefix yet: the first paragraph
/// in yellow, the profile's own words under it, then its buttons. Sized to
/// its text.
fn draw_notice(f: &mut Frame, n: &crate::app::Notice, area: Rect) {
    let title = n.title.as_str();
    let w = area.width.min(64);
    let text_w = usize::from(w.saturating_sub(6)).max(10);
    let mut lines: Vec<Line> = Vec::new();
    for (i, para) in n.lines.iter().enumerate() {
        if i > 0 {
            lines.push(Line::from(""));
        }
        let style = if i == 0 { theme::label() } else { Style::new() };
        lines.extend(
            wrap(para, text_w, "")
                .into_iter()
                .map(|l| Line::from(Span::styled(l, style))),
        );
    }
    lines.push(Line::from(""));
    let button = |label: &str, sel: bool| {
        let style = if sel {
            Style::new()
                .fg(theme::SELECT_TEXT)
                .bg(theme::SELECT_BAR)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(theme::LABEL)
        };
        Span::styled(format!("[ {label} ]"), style)
    };
    let buttons = if n.update.is_some() {
        vec![
            button("Update and restart", n.on_retry),
            Span::raw("  "),
            button("Later", !n.on_retry),
        ]
    } else if n.retry.is_some() {
        vec![
            button("Check again", n.on_retry),
            Span::raw("  "),
            button("OK", !n.on_retry),
        ]
    } else {
        vec![button("OK", true)]
    };
    lines.push(Line::from(buttons).centered());
    let h = (lines.len() as u16 + 4).min(area.height);
    let popup = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, popup);
    f.render_widget(
        Paragraph::new(lines).block(boxed(title).padding(MARGIN)),
        popup,
    );
}

/// A rounded box in the old browser's colours, its title centred in the top edge.
pub(crate) fn boxed(title: &str) -> Block<'static> {
    boxed_line(Line::from(Span::styled(
        format!(" {title} "),
        Style::new().fg(theme::LABEL),
    )))
}

/// The same box with a title made of several styled parts.
pub(crate) fn boxed_line(title: Line<'static>) -> Block<'static> {
    Block::bordered()
        .border_type(BorderType::Rounded)
        .border_style(Style::new().fg(theme::BORDER))
        .title(title)
        .title_alignment(Alignment::Center)
}

/// The list and its selection: the chosen row has a dark background and, in
/// front of it, a pink bar (see `gutter`).
pub(crate) fn selection<'a>(list: List<'a>) -> List<'a> {
    list.highlight_style(Style::new().bg(theme::SELECT_BG))
        .highlight_spacing(HighlightSpacing::Never)
}

/// The two columns in front of a row: the bar on the chosen one, blank on the rest.
pub(crate) fn gutter(selected: bool) -> Span<'static> {
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

/// The list's area and the right pane's: side by side, or the pane under the
/// list when the window is narrow.
fn split(app: &App, body: Rect) -> (Rect, Rect) {
    match app.layout {
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
    }
}

fn draw_body(f: &mut Frame, app: &App, body: Rect) {
    let (left, pane) = split(app, body);
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
    if app.picker.is_none() && !app.help && app.prefs.is_none() {
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
    // A column on the right keeps a long name from running under the scroll bar.
    let block = boxed("Games").padding(Padding::new(0, 1, 0, 0));
    let rows = usize::from(block.inner(area).height);
    let offset = window_offset(
        app.selected,
        app.list_offset.get(),
        rows,
        app.visible.len(),
        SCROLL_OFF,
    );
    app.list_offset.set(offset);
    let list = selection(List::new(items).block(block));
    let mut state = ListState::default()
        .with_offset(offset)
        .with_selected(app.current().map(|_| app.selected));
    f.render_stateful_widget(list, area, &mut state);
    scroll_bar(f, area, rows, app.visible.len(), offset);
}

/// Rows kept between the highlight and the edge of the list while it scrolls: the
/// old browser's (fzf's `--scroll-off`).
const SCROLL_OFF: usize = 3;

/// The first row of a list window. The window stays where it was (`offset`) while
/// the highlight moves about inside it, and only moves when the highlight gets
/// within `margin` rows of an edge, so going up from the bottom the highlight
/// climbs to near the top before the list starts to scroll, as in the old browser.
/// At the ends of the list the highlight can reach the edge.
fn window_offset(
    selected: usize,
    offset: usize,
    rows: usize,
    total: usize,
    margin: usize,
) -> usize {
    if total <= rows {
        return 0;
    }
    // A window too small for the margin on both sides keeps the highlight centred.
    let margin = margin.min(rows.saturating_sub(1) / 2);
    let furthest = total - rows;
    let offset = offset.min(furthest);
    let moved = if selected < offset + margin {
        selected.saturating_sub(margin)
    } else if selected + margin >= offset + rows {
        selected + margin + 1 - rows
    } else {
        offset
    };
    moved.min(furthest)
}

/// A row: its mark, then the name with the letters the search matched lit.
fn game_line(app: &App, e: &Entry, selected: bool) -> Line<'static> {
    let (mark, colour) = marker(e.status);
    let here = e.status != Status::NotOnThisPc;
    let (base, hit) = if selected {
        (
            Style::new()
                .fg(if here {
                    theme::SELECT_TEXT
                } else {
                    theme::NOT_ON_PC_SELECTED
                })
                .add_modifier(Modifier::BOLD),
            Style::new()
                .fg(theme::SELECT_MATCH)
                .add_modifier(Modifier::BOLD),
        )
    } else {
        (
            Style::new().fg(if here { theme::ON_PC } else { theme::NOT_ON_PC }),
            Style::new().fg(theme::MATCH),
        )
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
    // The same game from both stores: two rows of one name, told apart here.
    if let Some(store) = e.store.filter(|_| app.both_stores.contains(&e.name)) {
        let label = match store {
            crate::library::StoreKind::Steam => " [Steam]",
            crate::library::StoreKind::Gog => " [GOG]",
        };
        let colour = if selected {
            theme::NOT_ON_PC_SELECTED
        } else {
            theme::NOT_ON_PC
        };
        spans.push(Span::styled(label, Style::new().fg(colour)));
    }
    Line::from(spans)
}

/// The right-hand pane: the settings or the profile. `zoomed` is the full-screen
/// view, where the game's name goes in the title because the list is hidden.
fn draw_pane(f: &mut Frame, app: &App, area: Rect, zoomed: bool) {
    let current = app.current();
    let settings = app.pane == Pane::Settings && current.is_some();
    let title = pane_title(
        settings,
        current.filter(|_| zoomed).map(|e| e.name.as_str()),
    );
    let block = boxed_line(title).padding(MARGIN);
    let width = usize::from(block.inner(area).width);

    let lines = if settings {
        match current.and_then(|e| e.game.as_ref()) {
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
        }
    } else {
        match current {
            Some(e) => profile::lines(e, width, &app.home, app.exe_of(e).as_ref()),
            None => vec![
                Line::from("No game matches.").dim(),
                Line::from("Press Ctrl-A to add a game by its folder.").dim(),
            ],
        }
    };
    scrolling(f, area, block, lines, app.pane_scroll, &app.pane_max);
}

/// The pane's title: both views named, the one showing lit.
fn pane_title(settings: bool, game: Option<&str>) -> Line<'static> {
    let name = |text: &'static str, on: bool| {
        Span::styled(
            text,
            if on {
                theme::key()
            } else {
                Style::new().fg(theme::LABEL)
            },
        )
    };
    let mut spans = vec![Span::raw(" ")];
    if let Some(game) = game {
        spans.push(Span::styled(
            format!("{game}: "),
            Style::new().fg(theme::LABEL),
        ));
    }
    spans.extend([
        name("Game profile", !settings),
        Span::styled(" | ", Style::new().fg(theme::BORDER)),
        name("Game settings", settings),
        Span::raw(" "),
    ]);
    Line::from(spans)
}

fn is_blank(line: &Line) -> bool {
    line.spans.iter().all(|s| s.content.trim().is_empty())
}

/// The space inside a scrolling box's border: a row above and below the text and
/// two columns either side (a row is about twice as tall as a column is wide).
pub(crate) const MARGIN: Padding = Padding::new(2, 2, 1, 1);

/// Where the scroll bar's thumb is on a track `track` rows tall, as (first row,
/// length), or None when everything is in view. `viewport` rows of `total` are
/// showing, from line `top`.
fn thumb(track: usize, viewport: usize, total: usize, top: usize) -> Option<(usize, usize)> {
    if total <= viewport || track == 0 {
        return None;
    }
    let len = ((track * viewport + total / 2) / total).clamp(1, track);
    let max = total - viewport;
    let start = ((track - len) * top.min(max) + max / 2) / max;
    Some((start, len))
}

/// The old browser's scroll bar: a `│` in the border's grey in the column just
/// inside the right border, on the rows where the thumb is and nowhere else (no
/// track). Drawn only when there is something to scroll.
pub(crate) fn scroll_bar(f: &mut Frame, area: Rect, viewport: usize, total: usize, top: usize) {
    let inside = Block::bordered().inner(area);
    let Some((start, len)) = thumb(usize::from(inside.height), viewport, total, top) else {
        return;
    };
    if inside.width == 0 {
        return;
    }
    let x = inside.x + inside.width - 1;
    for row in start..start + len {
        let y = inside.y + u16::try_from(row).unwrap_or(0);
        f.render_widget(
            Paragraph::new(Span::styled("│", Style::new().fg(theme::BORDER))),
            Rect::new(x, y, 1, 1),
        );
    }
}

/// Text in a box that scrolls. The block carries the margin, so it stays when the
/// text is scrolled; the text's own leading blank lines (the profile and the help
/// start with one) are dropped so the margin is not doubled. When there is more
/// text than fits, the scroll position (`3/36`) sits in the top margin row and the
/// scroll bar in the right one, as in the old browser. `max_cell` is told how far
/// the text can scroll.
fn scrolling(
    f: &mut Frame,
    area: Rect,
    block: Block<'static>,
    mut lines: Vec<Line<'static>>,
    scroll: u16,
    max_cell: &std::cell::Cell<u16>,
) {
    let inner = block.inner(area);
    let blank = lines.iter().take_while(|l| is_blank(l)).count();
    lines.drain(..blank);
    let total = lines.len();
    let viewport = usize::from(inner.height);
    let max = u16::try_from(total.saturating_sub(viewport)).unwrap_or(u16::MAX);
    max_cell.set(max);
    let top = scroll.min(max);
    f.render_widget(Paragraph::new(lines).scroll((top, 0)).block(block), area);
    if max == 0 {
        return;
    }

    let inside = Block::bordered().inner(area);
    if inside.height > 0 && inside.width > 4 {
        // Two columns in from the border, level with the text's edge.
        f.render_widget(
            Paragraph::new(Span::styled(
                format!("{}/{total}", usize::from(top) + 1),
                Style::new()
                    .fg(theme::COUNT)
                    .add_modifier(Modifier::REVERSED),
            ))
            .alignment(Alignment::Right),
            Rect::new(inside.x + 2, inside.y, inside.width - 4, 1),
        );
    }
    scroll_bar(f, area, viewport, total, usize::from(top));
}

/// The width of the F1 help and the F2 settings pop-ups.
pub(crate) const POPUP_W: u16 = 90;

/// A pop-up `POPUP_W` wide, as tall as `text_rows` plus the margin and border,
/// or as tall as the screen allows with a row to spare above and below (a
/// shorter screen scrolls), centred in `area`.
pub(crate) fn centred_popup(area: Rect, text_rows: usize) -> Rect {
    let w = POPUP_W.min(area.width);
    let h = u16::try_from(text_rows + 4)
        .unwrap_or(u16::MAX)
        .min(area.height.saturating_sub(2).max(3))
        .min(area.height);
    Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    )
}

/// The F1 key list, over whatever is on screen.
fn draw_help(f: &mut Frame, app: &App, area: Rect) {
    let w = POPUP_W.min(area.width);
    // Inside the border and the margin.
    let lines = help::lines(usize::from(w.saturating_sub(6)));
    let text_rows = lines.iter().skip_while(|l| is_blank(l)).count();
    let popup = centred_popup(area, text_rows);
    f.render_widget(Clear, popup);
    scrolling(
        f,
        popup,
        boxed("Help").padding(MARGIN),
        lines,
        app.help_scroll,
        &app.help_max,
    );
}

/// The key bar: each key in cyan, what it does after it.
fn bar_items(app: &App) -> Vec<(&'static str, &'static str)> {
    if let Some(n) = &app.notice {
        if n.retry.is_some() {
            vec![("←/→", "move"), ("Enter", "press"), ("Esc", "close")]
        } else {
            vec![("Enter", "close")]
        }
    } else if app.help {
        vec![("↑/↓", "scroll"), ("Esc or F1", "close")]
    } else if let Some(s) = &app.prefs {
        s.keys()
    } else if let Some(p) = &app.panel {
        crate::panel::view::keys(p)
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
    } else if app.zoom {
        vec![
            ("↑/↓", "scroll"),
            ("←/→", "Profile/Settings"),
            ("Enter", "open"),
            ("F1", "help"),
            ("Esc", "back"),
        ]
    } else if app.pane == Pane::Settings {
        vec![
            ("Shift-↑/↓", "scroll"),
            ("Ctrl-F", "full screen"),
            ("←/→", "Profile/Settings"),
            ("Enter", "open"),
            ("F1", "help"),
            ("Esc", "quit"),
        ]
    } else {
        vec![
            ("Type", "to filter"),
            ("Enter", "open"),
            ("←/→", "Profile/Settings"),
            ("Ctrl-A", "add game"),
            ("F1", "help"),
            ("F2", "settings"),
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
    crate::build_info::label()
}

fn draw_bar(f: &mut Frame, app: &App, area: Rect) {
    if !app.message.is_empty() {
        f.render_widget(
            Paragraph::new(app.message.as_str())
                .style(theme::label())
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
    // The build number at the right edge, if the centred keys leave room for it.
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
    let title = match &p.game {
        Some(g) => format!("Choose the folder with {}'s .exe", g.name),
        None => "Choose the folder with the game's .exe".to_string(),
    };
    let block = boxed(&title);
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
        Line::from(Span::styled(p.shown_dir(), theme::key())),
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
    // The window stays put while the highlight moves about inside it, as in the
    // Games list.
    let offset = window_offset(
        p.selected,
        p.offset.get(),
        usize::from(parts[1].height),
        p.dirs.len(),
        SCROLL_OFF,
    );
    p.offset.set(offset);
    f.render_stateful_widget(
        list,
        parts[1],
        &mut ListState::default()
            .with_offset(offset)
            .with_selected(selected),
    );
}

/// The list's mark for a game: a tick once the fix is in (magenta when it was
/// put in by hand), nothing otherwise. `✓` is one column wide in the usual
/// terminal fonts, so the names stay lined up. The profile pane spells the
/// status out.
pub(crate) fn marker(s: Status) -> (&'static str, Color) {
    match s {
        Status::Installed => ("✓", Color::Green),
        Status::OnThisPc => (" ", Color::Cyan),
        Status::NotOnThisPc => (" ", Color::Reset),
        Status::Manual => ("✓", Color::Magenta),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use crate::library::StoreKind;
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

    #[test]
    fn a_game_on_this_pc_from_both_stores_says_which_store_each_row_is() {
        let json = r#"{"games":[{"id":"q","name":"Quake 4"},{"id":"a","name":"Alpha"}]}"#;
        let mut games = entries(json);
        let mut gog = games[0].clone();
        games[0].status = Status::OnThisPc;
        games[0].store = Some(StoreKind::Steam);
        gog.status = Status::Installed;
        gog.store = Some(StoreKind::Gog);
        games[1].status = Status::OnThisPc;
        games[1].store = Some(StoreKind::Steam);
        games.push(gog.clone());
        let s = screen(&App::new(games.clone()), 120, 30);
        assert!(s.contains("  Quake 4 [Steam]"), "{s}");
        assert!(s.contains("✓ Quake 4 [GOG]"), "{s}");
        assert!(!s.contains("Alpha ["), "one store, no label: {s}");

        // Only one copy on this PC: no label.
        games[2].status = Status::NotOnThisPc;
        let s = screen(&App::new(games), 120, 30);
        assert!(!s.contains("Quake 4 ["), "{s}");
    }

    #[test]
    fn the_list_ticks_installed_games_and_greys_out_ones_not_on_this_pc() {
        let mut games = entries(
            r#"{"games":[{"id":"a","name":"Alpha","stores":{},"eax":{"api":"directsound3d"}},
            {"id":"b","name":"Bravo","stores":{},"eax":{"api":"directsound3d"}},
            {"id":"c","name":"Charlie","stores":{},"eax":{"api":"directsound3d"}}]}"#,
        );
        games[0].status = Status::Installed;
        games[1].status = Status::OnThisPc;
        games[2].status = Status::NotOnThisPc;
        let app = App::new(games);
        let mut t = Terminal::new(TestBackend::new(100, 30)).unwrap();
        t.draw(|f| draw(f, &app)).unwrap();
        let buf = t.backend().buffer().clone();
        let find = |name: &str| {
            (0..30u16)
                .find_map(|y| {
                    // The list is the left-hand box; the pane beside it names the game too.
                    let row: String = (0..40u16).map(|x| buf[(x, y)].symbol()).collect();
                    row.find(name)
                        .map(|i| (row[..i].chars().count() as u16, y, row))
                })
                .unwrap()
        };
        let (x, y, row) = find("Alpha");
        assert!(row.contains("✓ Alpha"), "{row}");
        assert_eq!(buf[(x - 2, y)].fg, Color::Green);
        let (_, _, row) = find("Bravo");
        assert!(!row.contains('✓'), "{row}");
        // Alpha is selected; the other two show their own shade.
        let (x, y, _) = find("Bravo");
        assert_eq!(buf[(x, y)].fg, theme::ON_PC);
        let (x, y, _) = find("Charlie");
        assert_eq!(buf[(x, y)].fg, theme::NOT_ON_PC);
    }

    #[test]
    fn settings_are_a_pop_up_as_wide_as_the_help_over_the_list() {
        use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
        let edges = |app: &App, title: &str| {
            let rows: Vec<String> = screen(app, 120, 40).lines().map(String::from).collect();
            let top = rows
                .iter()
                .position(|r| r.contains(&format!(" {title} ")))
                .unwrap();
            let left = rows[top].chars().position(|c| c == '╭').unwrap();
            let right = rows[top].chars().position(|c| c == '╮').unwrap();
            let bottom = (top..rows.len())
                .find(|&y| rows[y].chars().nth(left) == Some('╰'))
                .unwrap();
            (rows, top, left, right, bottom)
        };
        let mut app = App::new(entries(WITH_SETTINGS));
        app.handle_key(KeyEvent::new(KeyCode::F(1), KeyModifiers::NONE));
        let (_, _, help_l, help_r, _) = edges(&app, "Help");
        app.handle_key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
        app.handle_key(KeyEvent::new(KeyCode::F(2), KeyModifiers::NONE));
        let (rows, top, left, right, bottom) = edges(&app, "Settings");
        assert_eq!((left, right), (help_l, help_r), "{}", rows.join("\n"));
        // Fitted to its text: the focused row's help, room under it for the
        // longest help, a margin row, the border.
        assert!(
            rows[bottom - 3].contains("The game list starts with every game."),
            "{}",
            rows.join("\n")
        );
        // The list is still showing around it.
        assert!(rows[..top].iter().any(|r| r.contains(" Games ")));
    }

    fn entries(json: &str) -> Vec<Entry> {
        Database::parse(json)
            .unwrap()
            .games
            .into_iter()
            .map(Entry::database_only)
            .collect()
    }

    /// A Steam game's folder whose prefix Proton has made, so its page opens.
    fn steam_folder(home: &std::path::Path, dir: &str, app_id: u32) -> std::path::PathBuf {
        let lib = home.join("SteamLibrary/steamapps");
        let game = lib.join("common").join(dir);
        std::fs::create_dir_all(&game).unwrap();
        std::fs::create_dir_all(lib.join(format!("compatdata/{app_id}/pfx/drive_c"))).unwrap();
        std::fs::write(
            lib.join(format!("appmanifest_{app_id}.acf")),
            format!("\"AppState\"\n{{\n\t\"appid\"\t\t\"{app_id}\"\n\t\"installdir\"\t\t\"{dir}\"\n}}\n"),
        )
        .unwrap();
        game
    }

    /// Quake 4 with a folder, its page opened with Enter.
    fn app_with_a_page_open(width: u16) -> (tempfile::TempDir, App) {
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Quake 4", 2210);
        let mut games = entries(WITH_SETTINGS);
        games[0].status = Status::OnThisPc;
        games[0].path = Some(dir);
        let mut app = App::new(games);
        app.set_home(home.path().to_path_buf());
        app.resize(width);
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_some());
        (home, app)
    }

    /// The row and column of the page's top-left corner: the `╭` in front of
    /// its title.
    /// The page's top-left corner: the Status box sits just inside it.
    fn page_corner(app: &App, w: u16, h: u16) -> (usize, usize) {
        let s = screen(app, w, h);
        let y = s.lines().position(|l| l.contains(" Status ")).unwrap();
        let line: Vec<char> = s.lines().nth(y).unwrap().chars().collect();
        let x = line.iter().rposition(|c| *c == '╭').unwrap();
        (y - 1, x - 1)
    }

    /// Where the page's pop-up should sit on a `w` by `h` screen.
    fn page_spot(app: &App, w: u16, h: u16) -> (usize, usize) {
        let body = Rect::new(0, 0, w, h - bar_rows(app, w));
        let r = crate::panel::view::page_area(app.panel.as_ref().unwrap(), body);
        (usize::from(r.y), usize::from(r.x))
    }

    #[test]
    fn enter_on_a_game_that_wasnt_found_asks_for_its_folder_then_opens_its_page() {
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Quake 4", 2210);
        let mut app = App::new(entries(WITH_SETTINGS));
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        assert!(screen(&app, 120, 40).contains("Choose the folder with Quake 4's .exe"));

        // Space in the folder picks it: the page opens with the game's profile.
        app.picker.as_mut().unwrap().dir = dir;
        press(&mut app, ratatui::crossterm::event::KeyCode::Char(' '));
        assert!(app.picker.is_none());
        let p = app.panel.as_ref().expect("the page");
        assert_eq!(p.name, "Quake 4");
        assert!(p.game.is_some());
    }

    #[test]
    fn ctrl_a_then_space_opens_a_page_for_that_folder() {
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Obscure", 1234);
        let mut app = App::new(entries(WITH_SETTINGS));
        app.set_home(home.path().to_path_buf());
        ctrl_key(&mut app, 'a');
        assert!(screen(&app, 120, 40).contains("Choose the folder with the game's .exe"));
        app.picker.as_mut().unwrap().dir = dir;
        press(&mut app, ratatui::crossterm::event::KeyCode::Char(' '));
        let p = app.panel.as_ref().expect("the page");
        assert_eq!(p.name, "Obscure");
        assert!(p.game.is_none());
    }

    #[test]
    fn enter_on_a_game_with_no_eax_shows_a_pop_up_saying_why() {
        let home = tempfile::tempdir().unwrap();
        let mut games = entries(
            r#"{"games":[{"id":"bg","name":"Baldur's Gate: Enhanced Edition",
              "eax":{"status":"not_implemented","problem":"It has no EAX."}}]}"#,
        );
        let mut app = App::new(games.clone());
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none() && app.picker.is_none());
        let s = screen(&app, 120, 40);
        assert!(s.contains(" Baldur's Gate: Enhanced Edition "), "{s}");
        assert!(s.contains("Baldur's Gate: Enhanced Edition has no EAX, so there's"));
        assert!(s.contains("nothing to install."));
        assert!(s.contains("It has no EAX."));
        assert!(s.contains("[ OK ]"));
        assert!(s.contains("Search"), "the list stays under it");
        // Other keys do nothing; Esc closes it.
        press(&mut app, ratatui::crossterm::event::KeyCode::Down);
        assert!(app.notice.is_some());
        press(&mut app, ratatui::crossterm::event::KeyCode::Esc);
        assert!(app.notice.is_none());
        assert!(!app.quit);

        // Found on this PC too: the same pop-up, not the page.
        let dir = home.path().join("Games/BGEE");
        std::fs::create_dir_all(&dir).unwrap();
        games[0].status = Status::OnThisPc;
        games[0].path = Some(dir);
        let mut app = App::new(games);
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        assert!(app.notice.is_some());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_none());
    }

    #[test]
    fn enter_on_a_linux_version_shows_a_pop_up_with_the_way_to_windows() {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Psychonauts", 3830);
        // Psychonauts' Linux port: an ELF program and no .exe.
        let elf = dir.join("Psychonauts");
        std::fs::write(&elf, b"\x7fELF\x01\x01\x01").unwrap();
        std::fs::set_permissions(&elf, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut games = entries(
            r#"{"games":[{"id":"p","name":"Psychonauts","stores":{"steam":{"id":3830}}}]}"#,
        );
        games[0].status = Status::OnThisPc;
        games[0].path = Some(dir.clone());
        let mut app = App::new(games);
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        let s = screen(&app, 120, 40);
        assert!(s.contains(" Psychonauts "), "{s}");
        assert!(s.contains("installed as its Linux version"), "{s}");
        assert!(s.contains("Compatibility"), "forcing Proton: {s}");
        assert!(s.contains("launch Psychonauts once"), "{s}");
        assert!(!s.contains(" Status "), "no Status box: {s}");
        assert!(s.contains("[ Check again ]  [ OK ]"), "{s}");

        // Check again while it's still the Linux version: the pop-up stays.
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        assert!(app.notice.as_ref().is_some_and(|n| n.retry.is_some()));

        // Steam swapped in the Windows build and Proton ran it: the page opens.
        std::fs::remove_file(&elf).unwrap();
        std::fs::write(dir.join("Psychonauts.exe"), b"MZ").unwrap();
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_none());
        assert!(app.panel.is_some());
    }

    /// KOTOR II on Steam's default branch: the update has no EAX, so the
    /// page waits for the beta branch the database names, like the prefix
    /// pop-up waits for a prefix.
    #[test]
    fn enter_on_a_build_that_isnt_rolled_back_shows_a_pop_up_with_the_way_back() {
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Patched Game", 4242);
        std::fs::write(dir.join("game.exe"), b"MZ").unwrap();
        let mut games = entries(
            r#"{"games":[{"id":"p","name":"Patched Game",
              "stores":{"steam":{"id":4242,"beta_branch":"legacypc","rollback_steps":"Switch to the legacypc branch."}},
              "eax":{"status":"removed_by_patch","fix_in_place":true}}]}"#,
        );
        games[0].status = Status::OnThisPc;
        games[0].store = Some(crate::library::StoreKind::Steam);
        games[0].path = Some(dir);
        let mut app = App::new(games);
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        let s = screen(&app, 120, 40);
        assert!(
            s.contains("The current build of Patched Game has no EAX"),
            "{s}"
        );
        assert!(s.contains("Switch to the legacypc branch."), "{s}");
        assert!(!s.contains(" Status "), "no Status box: {s}");
        assert!(s.contains("[ Check again ]  [ OK ]"), "{s}");

        // Still on the default branch: the pop-up stays.
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        assert!(app.notice.as_ref().is_some_and(|n| n.retry.is_some()));

        // Steam has switched to the branch: Check again opens the page.
        let acf = home
            .path()
            .join("SteamLibrary/steamapps/appmanifest_4242.acf");
        let text = std::fs::read_to_string(&acf).unwrap().replace(
            "}\n",
            "\t\"MountedConfig\"\n\t{\n\t\t\"BetaKey\"\t\t\"legacypc\"\n\t}\n}\n",
        );
        std::fs::write(&acf, text).unwrap();
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_none());
        assert!(app.panel.is_some());
    }

    #[test]
    fn enter_on_a_game_with_no_prefix_yet_shows_a_pop_up_not_its_page() {
        let home = tempfile::tempdir().unwrap();
        let dir = steam_folder(home.path(), "Quake 4", 2210);
        std::fs::remove_dir_all(home.path().join("SteamLibrary/steamapps/compatdata")).unwrap();
        let mut games = entries(WITH_SETTINGS);
        games[0].status = Status::OnThisPc;
        games[0].path = Some(dir);
        let mut app = App::new(games);
        app.set_home(home.path().to_path_buf());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        let s = screen(&app, 120, 40);
        assert!(s.contains(" Quake 4 "), "{s}");
        assert!(s.contains("Quake 4 doesn't have a Wine prefix yet."), "{s}");
        assert!(s.contains("check again."), "{s}");
        assert!(!s.contains(" Status "), "no Status box: {s}");
        assert!(s.contains("[ Check again ]  [ OK ]"), "{s}");

        // Check again with still no prefix: the pop-up stays.
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.panel.is_none());
        assert!(app.notice.as_ref().is_some_and(|n| n.retry.is_some()));

        // Once the game has made it, Check again opens the page.
        std::fs::create_dir_all(
            home.path()
                .join("SteamLibrary/steamapps/compatdata/2210/pfx/drive_c"),
        )
        .unwrap();
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_none());
        assert!(app.panel.is_some());

        // OK, picked with the arrows, closes it; so does Esc.
        app.panel = None;
        std::fs::remove_dir_all(home.path().join("SteamLibrary/steamapps/compatdata")).unwrap();
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_some());
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        assert!(app.notice.is_none() && app.panel.is_none());
        press(&mut app, ratatui::crossterm::event::KeyCode::Enter);
        press(&mut app, ratatui::crossterm::event::KeyCode::Esc);
        assert!(app.notice.is_none());
    }

    #[test]
    fn a_games_page_is_a_pop_up_over_the_list_and_esc_goes_back() {
        let (_home, mut app) = app_with_a_page_open(120);
        let s = screen(&app, 120, 40);
        assert!(s.contains(" Search "), "the list shows round it: {s}");
        let spot = page_spot(&app, 120, 40);
        assert_eq!(page_corner(&app, 120, 40), spot);
        assert_eq!(spot.1, usize::from((120 - crate::panel::view::LEFT_W) / 2));
        assert!(s.contains(" Status "));
        // Ctrl-L and Ctrl-F are the list's; the page ignores them.
        ctrl_key(&mut app, 'l');
        ctrl_key(&mut app, 'f');
        assert!(app.panel.is_some());
        assert_eq!(page_corner(&app, 120, 40), spot);

        press(&mut app, ratatui::crossterm::event::KeyCode::Esc);
        assert!(app.panel.is_none());
        assert!(screen(&app, 120, 40).contains(" Search "));
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
        let s = screen(&App::new(games), 100, 30);
        println!("{s}");
        assert!(s.contains(" Search "));
        assert!(s.contains("1/1"));
        assert!(s.contains("Show: All games"));
        assert!(s.contains("Ctrl-E Audio: Any audio"));
        assert!(s.contains("✓ Alpha Centauri"));
        assert!(s.contains("System details:"));
        assert!(s.contains("Status:") && s.contains("DSOAL installed"));
        assert!(s.contains("Platform:") && s.contains("Steam"));
        assert!(s.contains("Location:") && s.contains("/lib/Alpha"));
        assert!(s.contains("EAX Support:") && s.contains("1.0"));
        assert!(s.contains("Audio API:") && s.contains("DirectSound3D"));
    }

    #[test]
    fn a_manual_game_says_the_database_has_no_profile() {
        let manual = Entry {
            name: "Obscure".into(),
            status: Status::Manual,
            game: None,
            store: None,
            via: None,
            path: Some(PathBuf::from("/g/Obscure")),
            engine: None,
        };
        let s = screen(&App::new(vec![manual]), 120, 14);
        assert!(s.contains("✓ Obscure"));
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
    fn a_message_replaces_the_key_bar() {
        let mut app = App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#));
        app.message = "Couldn't read the game database.".into();
        assert!(screen(&app, 80, 10).contains("Couldn't read the game database."));
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
        "files":{"q.cfg":{"format":"set_commands","locations":["game_exe:q4base/q.cfg"]}},
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
            r#"{{"games":[{{"id":"q","name":"Quake 4","game_config":{{"files":{{"q.cfg":{{"format":"set_commands"}}}},"audio_settings":[{many}]}}}}]}}"#
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
            via: None,
            path: None,
            engine: None,
        };
        let mut app = App::new(vec![manual]);
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        assert!(screen(&app, 120, 14).contains("The game database has no profile for Obscure."));
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
        assert!(narrow.contains("Game details:"));
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
            "Couldn't download the game database. Check your internet connection and try again."
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

    /// The style of the first cell of `needle` as drawn.
    fn style_of(app: &App, w: u16, h: u16, needle: &str) -> Style {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, app)).unwrap();
        let buf = t.backend().buffer().clone();
        for y in 0..h {
            let row: String = (0..w).map(|x| buf[(x, y)].symbol()).collect();
            if let Some(at) = row.find(needle) {
                let col = u16::try_from(row[..at].chars().count()).unwrap();
                return buf[(col, y)].style();
            }
        }
        panic!("{needle:?} is not on screen");
    }

    #[test]
    fn f1_is_a_popup_over_the_screen_not_a_replacement_for_the_pane() {
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        let s = screen(&app, 120, 40);
        println!("{s}");
        // The Search box is still the first row; the popup's own box starts below it.
        assert!(row_of(&s, " Search ") == 0);
        assert!(row_of(&s, " Help ") > 0);
        assert!(s.contains("The basics:"));
        // The pane's own title, on the top row above the popup, is untouched.
        assert!(s
            .lines()
            .next()
            .unwrap()
            .contains("Game profile | Game settings"));
    }

    #[test]
    fn the_pane_title_names_both_views_and_lights_the_one_showing() {
        let mut app = App::new(entries(WITH_SETTINGS));
        let lit = Some(Color::LightCyan);
        let plain = Some(Color::Indexed(145));
        assert!(screen(&app, 120, 24).contains("Game profile | Game settings"));
        assert_eq!(style_of(&app, 120, 24, "Game profile").fg, lit);
        assert_eq!(style_of(&app, 120, 24, "Game settings").fg, plain);
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        assert!(screen(&app, 120, 24).contains("Game profile | Game settings"));
        assert_eq!(style_of(&app, 120, 24, "Game profile").fg, plain);
        assert_eq!(style_of(&app, 120, 24, "Game settings").fg, lit);
    }

    #[test]
    fn there_is_one_blank_row_above_the_text_in_both_views() {
        // Full screen, so the pane is the whole width and its rows are easy to read.
        let mut app = App::new(entries(WITH_SETTINGS));
        ctrl_key(&mut app, 'f');
        let profile = grid(&app, 100, 24);
        assert!(inside_is_blank(&profile[1]), "the margin row");
        assert!(
            row_text(&profile[2]).contains("Game details:"),
            "{:?}",
            row_text(&profile[2])
        );
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        let settings = grid(&app, 100, 24);
        assert!(inside_is_blank(&settings[1]));
        assert!(row_text(&settings[2]).contains("Audio settings for Quake 4:"));
    }

    #[test]
    fn bold_colours_are_the_bright_ones_as_the_old_script_gets_from_bold() {
        let app = App::new(entries(WITH_SETTINGS));
        let bold = |fg: Color| (Some(fg), true);
        let seen = |needle: &str| {
            let st = style_of(&app, 100, 40, needle);
            (st.fg, st.add_modifier.contains(Modifier::BOLD))
        };
        // ` -> Name:` was `\033[1;33m`: bold yellow, drawn bright.
        assert_eq!(seen("Name:"), bold(Color::LightYellow));
        // `Game details:` was `\033[1;37m`: bold white.
        assert_eq!(seen("Game details:"), bold(Color::White));
        // The EAX versions were bold green.
        assert_eq!(seen("Unknown"), bold(Color::LightGreen));
        // A key in the bar was bold cyan.
        assert_eq!(seen("Enter"), bold(Color::LightCyan));
    }

    #[test]
    fn the_help_popup_is_as_tall_as_its_text_not_the_screen() {
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        // Far taller than the text needs.
        let s = screen(&app, 120, 80);
        let rows: Vec<&str> = s.lines().collect();
        let top = row_of(&s, " Help ");
        // 90 wide, less the border and the 2-column margins.
        let text = help::lines(84).iter().skip_while(|l| is_blank(l)).count();
        // Border, a margin row, the text, a margin row, border.
        assert!(
            rows[top + 1 + text].contains("so each copy names its store."),
            "{:?}",
            rows[top + 1 + text]
        );
        assert!(rows[top + text + 3].contains('╰'));
        assert!(top + text + 3 < 70, "popup reaches row {}", top + text + 3);
        // It is centred in the space above the key bar.
        assert!(top > 1);
        assert_eq!(app.help_max.get(), 0, "nothing left to scroll");
    }

    /// The characters of each screen row.
    fn grid(app: &App, w: u16, h: u16) -> Vec<Vec<char>> {
        screen(app, w, h)
            .lines()
            .map(|l| l.chars().collect())
            .collect()
    }

    fn row_text(row: &[char]) -> String {
        row.iter().collect()
    }

    /// True when a box row holds nothing between its two borders.
    fn inside_is_blank(row: &[char]) -> bool {
        row[1..row.len() - 1].iter().all(|c| *c == ' ')
    }

    /// The screen as cells, for their styles.
    fn drawn(app: &App, w: u16, h: u16) -> ratatui::buffer::Buffer {
        let mut t = Terminal::new(TestBackend::new(w, h)).unwrap();
        t.draw(|f| draw(f, app)).unwrap();
        t.backend().buffer().clone()
    }

    /// A settings list far longer than any box.
    fn long_settings_app() -> App {
        let many: String = (0..40)
            .map(|i| format!(r#"{{"title":"Setting {i}","tested":true,"reason":"r","changes":{{"q.cfg":{{"k{i}":"1"}}}}}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let json = format!(
            r#"{{"games":[{{"id":"q","name":"Quake 4","game_config":{{"files":{{"q.cfg":{{"format":"set_commands"}}}},"audio_settings":[{many}]}}}}]}}"#
        );
        let mut app = App::new(entries(&json));
        press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        app
    }

    #[test]
    fn the_pane_has_a_margin_on_every_side() {
        let mut app = App::new(entries(WITH_SETTINGS));
        ctrl_key(&mut app, 'f');
        for view in 0..2 {
            let g = grid(&app, 100, 24);
            // Border row 0, a blank margin row, the text, a blank margin row, border row 22.
            assert!(inside_is_blank(&g[1]), "top margin");
            assert!(inside_is_blank(&g[21]), "bottom margin");
            assert_eq!(g[22][0], '╰');
            // The text starts after the border and two columns of margin.
            let first = g[2].iter().position(|c| *c != ' ' && *c != '│').unwrap();
            assert_eq!(first, 3, "left margin, view {view}: {:?}", row_text(&g[2]));
            // Nothing in the two columns before the right border.
            for (y, row) in g.iter().enumerate().take(22).skip(1) {
                assert_eq!((row[97], row[98]), (' ', ' '), "right margin on row {y}");
            }
            press(&mut app, ratatui::crossterm::event::KeyCode::Right);
        }
    }

    #[test]
    fn the_scroll_position_shows_only_when_the_text_scrolls() {
        // Fits: no position, the margin row is empty.
        let mut app = App::new(entries(WITH_SETTINGS));
        ctrl_key(&mut app, 'f');
        assert!(inside_is_blank(&grid(&app, 100, 24)[1]));
        // Does not fit: the position is in the top margin row, and stays there
        // while the text moves under it.
        let mut app = long_settings_app();
        ctrl_key(&mut app, 'f');
        let first = row_text(&grid(&app, 100, 24)[1]);
        assert!(first.contains("1/"), "{first:?}");
        for _ in 0..5 {
            press(&mut app, ratatui::crossterm::event::KeyCode::Down);
        }
        let g = grid(&app, 100, 24);
        let row = row_text(&g[1]);
        assert!(row.contains("6/"), "{row:?}");
        assert!(
            !row.contains("Setting"),
            "the margin row never holds text: {row:?}"
        );
    }

    #[test]
    fn the_thumb_fits_its_track() {
        assert_eq!(thumb(10, 10, 10, 0), None);
        assert_eq!(thumb(10, 10, 5, 0), None);
        assert_eq!(thumb(0, 5, 10, 0), None);
        // A little over: nearly the whole track, sliding down by a row.
        assert_eq!(thumb(10, 10, 11, 0), Some((0, 9)));
        assert_eq!(thumb(10, 10, 11, 1), Some((1, 9)));
        // Far over: one row, from the top to the bottom of the track.
        assert_eq!(thumb(10, 10, 1000, 0), Some((0, 1)));
        assert_eq!(thumb(10, 10, 1000, 990), Some((9, 1)));
        // Never empty, never past the track; a top beyond the end counts as the end.
        for top in 0..=200 {
            let (start, len) = thumb(12, 12, 212, top).unwrap();
            assert!(len >= 1 && start + len <= 12, "top {top}: {start}+{len}");
        }
        assert_eq!(thumb(10, 10, 1000, 5000), thumb(10, 10, 1000, 990));
    }

    /// The rows of the screen that hold a thumb in column `col`.
    fn thumb_rows(app: &App, w: u16, h: u16, col: u16) -> Vec<u16> {
        let buf = drawn(app, w, h);
        (0..h)
            .filter(|y| {
                let cell = &buf[(col, *y)];
                cell.symbol() == "│" && cell.style().fg == Some(Color::Indexed(59))
            })
            .collect()
    }

    #[test]
    fn a_long_text_has_a_scroll_bar_inside_its_right_border_that_moves_with_it() {
        let mut app = long_settings_app();
        ctrl_key(&mut app, 'f');
        // Border at column 99; the bar is the column inside it. Rows 1..=21 are inside the box.
        let top = thumb_rows(&app, 100, 24, 98);
        assert!(!top.is_empty(), "no scroll bar");
        assert_eq!(top[0], 1, "starts at the top of the box");
        assert!(top.windows(2).all(|w| w[1] == w[0] + 1), "one run: {top:?}");
        press(&mut app, ratatui::crossterm::event::KeyCode::End);
        let end = thumb_rows(&app, 100, 24, 98);
        assert_eq!(*end.last().unwrap(), 21, "ends at the bottom of the box");
        assert_eq!(end.len(), top.len(), "the same size at both ends");
        // The border itself is in the next column and is not mistaken for the bar.
        assert!(thumb_rows(&app, 100, 24, 99).len() >= 21);
    }

    #[test]
    fn text_that_fits_has_no_scroll_bar() {
        let mut app = App::new(entries(WITH_SETTINGS));
        ctrl_key(&mut app, 'f');
        assert!(thumb_rows(&app, 100, 24, 98).is_empty());
        // The F1 popup is fitted to its text, so it has none either.
        let mut app = App::new(entries(WITH_SETTINGS));
        press(&mut app, ratatui::crossterm::event::KeyCode::F(1));
        let g = grid(&app, 120, 80);
        let top = row_of(&screen(&app, 120, 80), " Help ");
        // The popup is columns 15 to 104; its top margin row holds no scroll position.
        assert!(
            g[top + 1][16..104].iter().all(|c| *c == ' '),
            "{:?}",
            row_text(&g[top + 1])
        );
    }

    #[test]
    fn the_games_list_has_a_scroll_bar_when_there_are_more_games_than_rows() {
        let games: String = (0..60)
            .map(|i| format!(r#"{{"id":"g{i}","name":"Game {i:02}"}}"#))
            .collect::<Vec<_>>()
            .join(",");
        let mut app = App::new(entries(&format!(r#"{{"games":[{games}]}}"#)));
        // The Games box is the left half; its right border is column 49, the bar column 48.
        let first = thumb_rows(&app, 100, 24, 48);
        assert!(!first.is_empty(), "no scroll bar on the list");
        let games_top = u16::try_from(row_of(&screen(&app, 100, 24), " Games ")).unwrap();
        assert_eq!(first[0], games_top + 1, "starts at the top of the list");
        press(&mut app, ratatui::crossterm::event::KeyCode::End);
        let last = thumb_rows(&app, 100, 24, 48);
        let g = grid(&app, 100, 24);
        let bottom = (usize::from(games_top)..24)
            .find(|&y| g[y][0] == '╰')
            .unwrap();
        assert_eq!(
            usize::from(*last.last().unwrap()),
            bottom - 1,
            "the bottom of the list"
        );
        // A short list needs none.
        let few = App::new(entries(WITH_SETTINGS));
        assert!(thumb_rows(&few, 100, 24, 48).is_empty());
    }

    #[test]
    fn a_long_name_stops_before_the_scroll_bar() {
        let name = "A".repeat(80);
        let mut games: Vec<String> = (0..40)
            .map(|i| format!(r#"{{"id":"g{i}","name":"G{i:02}"}}"#))
            .collect();
        games.push(format!(r#"{{"id":"long","name":"{name}"}}"#));
        let app = App::new(entries(&format!(r#"{{"games":[{}]}}"#, games.join(","))));
        let g = grid(&app, 100, 24);
        // Column 48 holds the bar or nothing, never a letter of a name.
        assert!(g.iter().all(|row| row[48] != 'A'));
    }

    #[test]
    fn the_window_only_moves_when_the_highlight_nears_its_edge() {
        // The old browser, measured: 24 rows of 111, three kept clear at each edge.
        let (rows, total) = (24, 111);
        // Going down from the top the highlight (row = selected - offset + 1) runs to
        // row 21 with the window still, then holds there while the list scrolls.
        let mut offset = 0;
        for (selected, row) in [
            (0, 1),
            (5, 6),
            (19, 20),
            (20, 21),
            (21, 21),
            (22, 21),
            (29, 21),
        ] {
            offset = window_offset(selected, offset, rows, total, 3);
            assert_eq!(selected - offset + 1, row, "going down to {selected}");
        }
        // Going up from the bottom it climbs from row 24 to row 4 with the window
        // still, and only then does the list scroll under it.
        let mut offset = total - rows;
        for (selected, row, first) in [
            (110, 24, 87),
            (105, 19, 87),
            (91, 5, 87),
            (90, 4, 87),
            (89, 4, 86),
            (88, 4, 85),
        ] {
            offset = window_offset(selected, offset, rows, total, 3);
            assert_eq!(
                (selected - offset + 1, offset),
                (row, first),
                "going up to {selected}"
            );
        }
    }

    #[test]
    fn the_window_stays_inside_the_list_and_copes_with_small_ones() {
        // Everything fits: always from the top.
        assert_eq!(window_offset(3, 5, 10, 8, 3), 0);
        // A stale offset past the end is pulled back to the last window, and the highlight
        // on that window's top row is inside the margin, so the window moves up three more.
        assert_eq!(window_offset(50, 500, 10, 60, 3), 47);
        assert_eq!(window_offset(55, 500, 10, 60, 3), 50);
        // The last games can be reached at the very bottom.
        assert_eq!(window_offset(59, 40, 10, 60, 3), 50);
        // A window too small for the margin keeps the highlight in the middle.
        assert_eq!(window_offset(10, 0, 3, 40, 3), 9);
        assert_eq!(window_offset(0, 0, 1, 5, 3), 0);
        assert_eq!(window_offset(4, 0, 1, 5, 3), 4);
        // Never past the furthest window, never a negative one.
        for total in 1..30 {
            for selected in 0..total {
                for offset in [0, 3, 40] {
                    let o = window_offset(selected, offset, 7, total, 3);
                    assert!(
                        o <= total.saturating_sub(7),
                        "{selected}/{total} from {offset}: {o}"
                    );
                    assert!(
                        selected >= o && selected < o + 7.min(total),
                        "highlight out of view"
                    );
                }
            }
        }
    }

    /// The first game showing, the highlighted row (1-based) and the number of rows
    /// in the Games list.
    fn list_view(app: &App) -> (String, usize, usize) {
        let (w, h) = (100, 24);
        let buf = drawn(app, w, h);
        let g = grid(app, w, h);
        let games_top = row_of(&screen(app, w, h), " Games ");
        // Inside the box: after its top border, before the bottom one (the key
        // bar under it can take more than one row).
        let bottom = (games_top + 1..usize::from(h))
            .find(|&y| g[y][0] == '╰')
            .unwrap();
        let inside = games_top + 1..bottom;
        let first = row_text(&g[inside.start][3..48]).trim().to_string();
        let lit = inside
            .clone()
            .position(|y| buf[(10, u16::try_from(y).unwrap())].bg == Color::Indexed(236))
            .map(|p| p + 1)
            .unwrap();
        (first, lit, inside.len())
    }

    fn sixty_games() -> App {
        let games: String = (0..60)
            .map(|i| format!(r#"{{"id":"g{i}","name":"Game {i:02}"}}"#))
            .collect::<Vec<_>>()
            .join(",");
        App::new(entries(&format!(r#"{{"games":[{games}]}}"#)))
    }

    #[test]
    fn going_up_from_the_bottom_the_highlight_climbs_before_the_list_scrolls() {
        use ratatui::crossterm::event::KeyCode::{Down, End, Up};
        let name = |i: usize| format!("Game {i:02}");
        let mut app = sixty_games();
        press(&mut app, End);
        let (first, row, rows) = list_view(&app);
        assert!(rows >= 8, "a list tall enough to show the margin: {rows}");
        // The last game sits on the last row.
        assert_eq!((first, row), (name(60 - rows), rows));
        // Up until the highlight is on row 4 (three clear of the top): the list has
        // not moved, only the highlight has.
        for _ in 0..rows - 4 {
            press(&mut app, Up);
        }
        assert_eq!(list_view(&app), (name(60 - rows), 4, rows));
        // Now the list scrolls under it and the highlight holds at row 4.
        press(&mut app, Up);
        assert_eq!(list_view(&app), (name(60 - rows - 1), 4, rows));
        press(&mut app, Up);
        assert_eq!(list_view(&app), (name(60 - rows - 2), 4, rows));
        // Going down from the top is the mirror image: the highlight runs to three
        // clear of the bottom (row rows - 3), then the list scrolls.
        let mut app = sixty_games();
        for _ in 0..rows - 4 {
            press(&mut app, Down);
        }
        assert_eq!(list_view(&app), (name(0), rows - 3, rows));
        press(&mut app, Down);
        assert_eq!(list_view(&app), (name(1), rows - 3, rows));
    }

    /// A picker over 40 sub-folders, d00 to d39, opened on a screen.
    fn picker_with_many_folders() -> (tempfile::TempDir, App) {
        let home = tempfile::tempdir().unwrap();
        for i in 0..40 {
            std::fs::create_dir_all(home.path().join(format!("Games/Heroic/d{i:02}"))).unwrap();
        }
        let mut app = App::new(entries(WITH_SETTINGS));
        app.set_home(home.path().to_path_buf());
        ctrl_key(&mut app, 'a');
        (home, app)
    }

    /// The first folder showing, the highlighted row (1-based) and the rows in the
    /// picker's list.
    fn picker_view(app: &App) -> (String, usize, usize) {
        let (w, h) = (100, 24);
        let buf = drawn(app, w, h);
        let g = grid(app, w, h);
        let top = row_of(&screen(app, w, h), "Choose the folder");
        // The popup's left border is column 5; below its three header rows the list
        // runs to the bottom border.
        let bottom = (top + 1..usize::from(h)).find(|y| g[*y][5] == '╰').unwrap();
        let rows = top + 4..bottom;
        let first = row_text(&g[rows.start][8..20])
            .split('/')
            .next()
            .unwrap()
            .to_string();
        let lit = rows
            .clone()
            .position(|y| buf[(12, u16::try_from(y).unwrap())].bg == Color::Indexed(236))
            .map(|p| p + 1)
            .unwrap();
        (first, lit, rows.len())
    }

    #[test]
    fn the_folder_picker_scrolls_like_the_games_list() {
        use ratatui::crossterm::event::KeyCode::{Down, PageDown, Up};
        let (_home, mut app) = picker_with_many_folders();
        let name = |i: usize| format!("d{i:02}");
        let (first, row, rows) = picker_view(&app);
        assert_eq!((first.as_str(), row), ("d00", 1));
        assert!((8..40).contains(&rows), "a list that scrolls: {rows}");
        // Down from the top: the highlight runs to three clear of the bottom, then
        // the list scrolls and the highlight holds.
        for _ in 0..rows - 4 {
            press(&mut app, Down);
        }
        assert_eq!(picker_view(&app), (name(0), rows - 3, rows));
        press(&mut app, Down);
        assert_eq!(picker_view(&app), (name(1), rows - 3, rows));
        // To the bottom: the last folder on the last row.
        for _ in 0..5 {
            press(&mut app, PageDown);
        }
        assert_eq!(picker_view(&app), (name(40 - rows), rows, rows));
        // Up from the bottom: the highlight climbs to row 4 with the list still, then
        // the list scrolls under it.
        for _ in 0..rows - 4 {
            press(&mut app, Up);
        }
        assert_eq!(picker_view(&app), (name(40 - rows), 4, rows));
        press(&mut app, Up);
        assert_eq!(picker_view(&app), (name(40 - rows - 1), 4, rows));
    }

    #[test]
    fn a_folder_entered_starts_at_the_top_of_its_list() {
        use ratatui::crossterm::event::KeyCode::{Enter, PageDown};
        let (home, mut app) = picker_with_many_folders();
        for i in 0..40 {
            std::fs::create_dir_all(home.path().join(format!("Games/Heroic/d39/s{i:02}"))).unwrap();
        }
        for _ in 0..5 {
            press(&mut app, PageDown);
        }
        // Into d39 (the highlighted, last folder), whose own list is long too.
        press(&mut app, Enter);
        let (first, row, _) = picker_view(&app);
        assert_eq!(
            (first.as_str(), row),
            ("s00", 1),
            "not left scrolled from the parent"
        );
    }
}
