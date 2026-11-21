//! Draws the game page: one column in a pop-up over the games list. The
//! Status box says whether the fix is in and lists any check that needs a
//! look, then the game's choices in numbered boxes (in the order the script
//! asks them). While work runs, its progress and then how it ended take the
//! choices' place.

use super::{Button, Item, Panel, Row, Screen};
use crate::engine::game_settings::{Category, Fix, Status};
use crate::engine::identify::Store;
use crate::engine::install::Engine;
use crate::engine::installed::OverrideKind;
use crate::theme;
use crate::ui::{boxed, boxed_line, gutter};
use ratatui::buffer::Buffer;
use ratatui::crossterm::event::KeyCode;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Widget, Wrap};
use ratatui::Frame;

/// The page's width, border included.
pub const LEFT_W: u16 = 64;
/// The Status box's tallest, border included, so the choices keep room.
const STATUS_MAX_H: u16 = 8;
/// A check's line: the badge, then the label column.
const BADGE_W: usize = 7;
const LABEL_W: usize = 10;

/// Words wrapped at `width`; a word longer than that is cut across lines
/// rather than run off the edge. A path is cut by character only, so a space
/// in a folder's name ("Quake 4") doesn't leave its last word on a line alone.
fn wrap(text: &str, width: usize) -> Vec<String> {
    let width = width.max(1);
    if text.starts_with('/') || text.starts_with("~/") {
        let chars: Vec<char> = text.chars().collect();
        return chars
            .chunks(width)
            .map(|c| c.iter().collect::<String>())
            .collect();
    }
    crate::settings::wrap(text, width, "")
        .into_iter()
        .flat_map(|line| {
            let chars: Vec<char> = line.chars().collect();
            chars
                .chunks(width)
                .map(|c| c.iter().collect::<String>())
                .collect::<Vec<_>>()
        })
        .collect()
}

/// The page's pop-up: `LEFT_W` wide, centred, as tall as its content but a
/// row short of the body at top and bottom, so the list shows round it.
pub fn page_area(p: &Panel, area: Rect) -> Rect {
    let most = if area.height > 12 {
        area.height - 2
    } else {
        area.height
    };
    popup(area, LEFT_W, page_rows(p).min(most))
}

/// The rows the page wants. It never shrinks below what the choices take,
/// so it keeps its size going from the choices to a run and back.
fn page_rows(p: &Panel) -> u16 {
    let inner = LEFT_W.saturating_sub(2);
    let status = u16::try_from(status_card_lines(p, usize::from(inner.saturating_sub(2))).len())
        .unwrap_or(u16::MAX)
        .saturating_add(2)
        .min(STATUS_MAX_H);
    let choices: u16 = match &p.problem {
        Some(problem) => rows_of(&[Line::from(problem.as_str())], inner.saturating_sub(4)) + 4,
        None => choice_boxes(p, usize::from(inner))
            .iter()
            .map(|b| b.lines.len() as u16 + 2)
            .sum(),
    };
    let text_rows = |lines: &[Line]| rows_of(lines, inner.saturating_sub(2)) + 2;
    let body = match &p.screen {
        Screen::Main => choices,
        Screen::Run(r) => choices.max(text_rows(&run_lines(r, usize::from(inner) - 2))),
        Screen::Confirm {
            heading,
            lines,
            jobs,
            ..
        } => choices.max(text_rows(&confirm_lines(heading, lines, jobs.is_empty()))),
        Screen::Uninstall(u) => choices.max(text_rows(&uninstall_lines(p, u))),
    };
    // Borders, the Status box, the body, room for the longest help (three
    // lines in a box) so moving the focus doesn't resize it, the buttons.
    2 + status + body + 5 + 1
}

/// Draws the page as a pop-up over `area`, the whole body.
pub fn draw(f: &mut Frame, p: &Panel, area: Rect) {
    let page = page_area(p, area);
    f.render_widget(Clear, page);
    draw_middle(f, p, page);
    if p.list.is_some() {
        draw_list(f, p, area);
    }
    if let Some(q) = &p.question {
        draw_question(f, &q.text, &q.ask, q.yes, area);
    }
}

/// The middle column: the EAX fix and Status boxes, the choices (or the
/// confirm and uninstall screens), a line of help for what has focus, and the
/// buttons.
fn draw_middle(f: &mut Frame, p: &Panel, area: Rect) {
    let block = boxed_line(title(p));
    let inner = block.inner(area);
    f.render_widget(block, area);
    let status = status_card_lines(p, usize::from(inner.width.saturating_sub(2)));
    let status_h = (u16::try_from(status.len()).unwrap_or(u16::MAX) + 2).min(STATUS_MAX_H);
    let [banner, inner] =
        Layout::vertical([Constraint::Length(status_h), Constraint::Min(0)]).areas(inner);
    f.render_widget(Paragraph::new(status).block(boxed("Status")), banner);
    let help = help_text(p);
    let help_rows = if help.is_empty() {
        0
    } else {
        rows_of(&[Line::from(help.as_str())], inner.width.saturating_sub(4)).min(3) + 2
    };
    let [body, help_area, buttons] = Layout::vertical([
        Constraint::Min(1),
        Constraint::Length(help_rows),
        Constraint::Length(1),
    ])
    .areas(inner);
    match &p.screen {
        Screen::Main => draw_choices(f, p, body),
        Screen::Run(r) => draw_run(f, p, r, body),
        Screen::Confirm {
            title,
            heading,
            lines,
            jobs,
        } => boxed_text(
            f,
            title,
            confirm_lines(heading, lines, jobs.is_empty()),
            body,
        ),
        Screen::Uninstall(u) => boxed_text(f, "Uninstall", uninstall_lines(p, u), body),
    }
    if help_rows > 0 {
        f.render_widget(
            Paragraph::new(help)
                .wrap(Wrap { trim: true })
                .block(plain())
                .style(theme::dim()),
            help_area,
        );
    }
    draw_buttons(f, p, buttons);
}

/// One numbered box on the page: its title, its lines, and the line that
/// has focus, if any.
struct PageBox {
    title: String,
    lines: Vec<Line<'static>>,
    /// The focused item's first and last line: a setting that's opened up
    /// takes several.
    focus: Option<(usize, usize)>,
}

/// The row names' column, and the dropdown field's text width: as wide as the
/// longest option on the page, so picking a value never moves anything, but no
/// wider than the column leaves room for.
fn field_geometry(p: &Panel, width: usize) -> (usize, usize) {
    let title_w = p.rows().map(|r| r.title.chars().count()).max().unwrap_or(0) + 2;
    let longest = p
        .rows()
        .flat_map(|r| r.options.iter().map(|o| o.label.chars().count()))
        .max()
        .unwrap_or(0);
    // Box borders, the gutter, "[ " and " ▾ ]", and " (detected)" after it.
    let room = width.saturating_sub(2 + 2 + title_w + 6 + 11).max(8);
    (title_w, longest.min(room))
}

/// A row's value as a dropdown field, `[ value ▾ ]`, then "(detected)" in green
/// when the value came from the PC or the profile. The value is green when
/// detected, yellow when changed; the focused field's chevron is cyan.
fn field_spans(r: &Row, sel: bool, field_w: usize) -> Vec<Span<'static>> {
    let frame = Style::new().fg(theme::LABEL);
    let value_style = if r.chosen != r.original {
        Style::new()
            .fg(Color::LightYellow)
            .add_modifier(Modifier::BOLD)
    } else if r.shows_detected() {
        theme::green()
    } else if sel {
        Style::new().fg(theme::SELECT_TEXT)
    } else {
        Style::new()
    };
    let value = truncate(r.value(), field_w);
    let pad = field_w.saturating_sub(value.chars().count());
    let mut out = vec![
        Span::styled("[ ", frame),
        Span::styled(value, value_style),
        Span::raw(" ".repeat(pad)),
        Span::styled(" ▾", if sel { theme::key() } else { frame }),
        Span::styled(" ]", frame),
    ];
    if r.shows_detected() {
        out.push(Span::styled(" (detected)", theme::green()));
    }
    out
}

fn selected_bg(sel: bool) -> Style {
    if sel {
        Style::new().bg(theme::SELECT_BG)
    } else {
        Style::new()
    }
}

fn choice_boxes(p: &Panel, width: usize) -> Vec<PageBox> {
    let focus = p.focused();
    let (title_w, field_w) = field_geometry(p, width);
    let mut boxes: Vec<PageBox> = p
        .sections
        .iter()
        .enumerate()
        .map(|(si, sec)| {
            let mut at = None;
            let lines = sec
                .rows
                .iter()
                .enumerate()
                .map(|(ri, r)| {
                    let sel = focus == Some(Item::Choice(si, ri));
                    if sel {
                        at = Some(ri);
                    }
                    let name = if sel {
                        Style::new().fg(theme::SELECT_TEXT)
                    } else {
                        Style::new().fg(theme::FILTER_LABEL)
                    };
                    let mut spans = vec![
                        gutter(sel),
                        Span::styled(format!("{:title_w$}", r.title), name),
                    ];
                    spans.extend(field_spans(r, sel, field_w));
                    Line::from(spans).style(selected_bg(sel))
                })
                .collect();
            PageBox {
                title: sec.title.to_string(),
                lines,
                focus: at.map(|a| (a, a)),
            }
        })
        .collect();
    let audio: Vec<usize> = (0..p.fixes.len())
        .filter(|&i| p.fixes[i].category == Category::Audio)
        .collect();
    let optional: Vec<usize> = (0..p.fixes.len())
        .filter(|&i| p.fixes[i].category != Category::Audio)
        .collect();
    if p.fixes.is_empty() {
        let text = if p.game.is_some() {
            "The game's profile has no settings to change."
        } else {
            "There's no profile for this game, so there are no settings to change."
        };
        boxes.push(PageBox {
            title: "Game settings".into(),
            lines: wrap(text, width.saturating_sub(4).max(1))
                .into_iter()
                .map(|l| Line::from(Span::styled(format!(" {l}"), theme::dim())))
                .collect(),
            focus: None,
        });
    }
    for (title, list) in [("Audio settings", audio), ("Optional settings", optional)] {
        if list.is_empty() {
            continue;
        }
        let (lines, at) = setting_lines(p, &list, width.saturating_sub(2));
        boxes.push(PageBox {
            title: title.into(),
            lines,
            focus: at,
        });
    }
    for (n, b) in boxes.iter_mut().enumerate() {
        b.title = format!("{}. {}", n + 1, b.title);
    }
    boxes
}

/// A setting's state, for one that can't be ticked; None for the rest.
fn setting_state(fix: &Fix, game: &str) -> Option<String> {
    match fix.status {
        Status::Missing => Some(format!(
            "Needs {}, which {game} creates the first time it runs",
            fix.missing_file.as_deref().unwrap_or("its settings file")
        )),
        Status::Already => Some("Already set".into()),
        Status::Absent => Some(format!(
            "This version of {game} has no {}",
            fix.absent_files
                .first()
                .map_or("file this setting changes", String::as_str)
        )),
        _ => None,
    }
}

/// The game's settings in `list`, laid out as the settings pane does: each
/// title with its tested tag on the right, then what it changes. The focused
/// one (and any with three keys or fewer) lists every key under its file, one
/// per line with the arrows lined up; the rest say how many keys each file
/// gets. A blank line between settings.
fn setting_lines(
    p: &Panel,
    list: &[usize],
    width: usize,
) -> (Vec<Line<'static>>, Option<(usize, usize)>) {
    let selected = match p.focused() {
        Some(Item::Setting(i)) => Some(i),
        _ => None,
    };
    let mut lines: Vec<Line<'static>> = Vec::new();
    let mut at: Option<(usize, usize)> = None;
    for (n, &i) in list.iter().enumerate() {
        // The focused setting runs to the line before the next one starts.
        if let Some((start, _)) = at.filter(|_| n > 0 && selected == Some(list[n - 1])) {
            at = Some((start, lines.len().saturating_sub(1)));
        }
        let fix = &p.fixes[i];
        let sel = selected == Some(i);
        let bg = selected_bg(sel);
        if n > 0 {
            lines.push(Line::raw(""));
        }
        if sel {
            at = Some((lines.len(), lines.len()));
        }
        let mark = if !Panel::tickable(fix) {
            " – "
        } else if p.ticked.contains(&fix.title) {
            "[x]"
        } else {
            "[ ]"
        };
        let changed = p.ticked.contains(&fix.title) != p.ticked_before.contains(&fix.title);
        let title_style = if changed {
            Style::new()
                .fg(Color::LightYellow)
                .add_modifier(Modifier::BOLD)
        } else if !Panel::tickable(fix) {
            theme::dim()
        } else if sel {
            Style::new()
                .fg(theme::SELECT_TEXT)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().add_modifier(Modifier::BOLD)
        };
        let (tag, tag_style) = if fix.untested {
            ("(untested)", theme::note())
        } else {
            ("(tested)", theme::green())
        };
        // Gutter, mark and a space before the title; the tag at the right.
        let title_room = width.saturating_sub(2 + 4 + tag.len() + 2);
        let title = truncate(&fix.title, title_room);
        let pad = title_room.saturating_sub(title.chars().count()) + 1;
        lines.push(
            Line::from(vec![
                gutter(sel),
                Span::raw(format!("{mark} ")),
                Span::styled(title, title_style),
                Span::raw(" ".repeat(pad)),
                Span::styled(tag, tag_style),
            ])
            .style(bg),
        );
        // The selection bar is on the title only; the rest of the setting
        // keeps its background.
        let under = |text: Span<'static>, indent: usize| {
            Line::from(vec![gutter(false), Span::raw(" ".repeat(indent)), text]).style(bg)
        };
        if let Some(state) = setting_state(fix, &p.name) {
            for part in wrap(&state, width.saturating_sub(8)) {
                lines.push(under(Span::styled(part, theme::dim()), 4));
            }
            continue;
        }
        // The keys, grouped by file, in the order the setting lists them.
        let mut files: Vec<(String, Vec<&crate::engine::game_settings::ViewRow>)> = Vec::new();
        for v in &fix.view {
            let name = v
                .path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            match files.iter_mut().find(|(f, _)| *f == name) {
                Some((_, rows)) => rows.push(v),
                None => files.push((name, vec![v])),
            }
        }
        if !(sel || fix.view.len() <= 3) {
            for (file, rows) in &files {
                let n = rows.len();
                let what = if n == 1 {
                    "1 change".to_string()
                } else {
                    format!("{n} changes")
                };
                lines.push(under(
                    Span::styled(format!("{what} in {file}"), theme::dim()),
                    4,
                ));
            }
            continue;
        }
        let key_w = fix
            .view
            .iter()
            .map(|v| v.key.chars().count())
            .max()
            .unwrap_or(0);
        let applied = fix.status == Status::Applied;
        for (file, rows) in &files {
            lines.push(under(Span::styled(file.clone(), theme::dim()), 4));
            let mut section: Option<&str> = None;
            for v in rows {
                let indent = if v.section.is_empty() {
                    6
                } else {
                    if section != Some(v.section.as_str()) {
                        lines.push(under(
                            Span::styled(format!("[{}]", v.section), theme::dim()),
                            6,
                        ));
                    }
                    8
                };
                section = Some(v.section.as_str());
                let mut spans = vec![
                    gutter(false),
                    Span::raw(" ".repeat(indent)),
                    Span::raw(format!("{:key_w$}  ", v.key)),
                ];
                if applied {
                    spans.push(Span::styled(v.new.display(), theme::green()));
                } else {
                    let old = v
                        .old
                        .as_ref()
                        .map_or("(not set)".to_string(), |o| o.display());
                    spans.push(Span::styled(old, theme::dim()));
                    spans.push(Span::raw(" → "));
                    spans.push(Span::styled(v.new.display(), theme::green()));
                }
                lines.push(Line::from(spans).style(bg));
            }
        }
    }
    if let Some((start, _)) = at.filter(|_| list.last().copied() == selected) {
        at = Some((start, lines.len().saturating_sub(1)));
    }
    (lines, at)
}

/// The numbered boxes, one under another. When they're taller than the
/// column, the page scrolls to keep the focused row in view.
fn draw_choices(f: &mut Frame, p: &Panel, area: Rect) {
    if let Some(problem) = &p.problem {
        f.render_widget(
            Paragraph::new(problem.as_str())
                .wrap(Wrap { trim: true })
                .block(plain().padding(ratatui::widgets::Padding::uniform(1))),
            area,
        );
        return;
    }
    if area.width == 0 || area.height == 0 {
        return;
    }
    let boxes = choice_boxes(p, usize::from(area.width));
    let total: u16 = boxes.iter().map(|b| b.lines.len() as u16 + 2).sum();
    let mut page = Buffer::empty(Rect::new(0, 0, area.width, total.max(1)));
    let mut y = 0;
    let mut focus_y = None;
    let mut focus_end = 0;
    for b in &boxes {
        let h = b.lines.len() as u16 + 2;
        if let Some((at, end)) = b.focus {
            focus_y = Some(y + 1 + at as u16);
            focus_end = y + 1 + end as u16;
        }
        Paragraph::new(b.lines.clone())
            .block(boxed(&b.title))
            .render(Rect::new(0, y, area.width, h), &mut page);
        y += h;
    }
    // The focused item stays in view a row clear of the bottom, all of it when
    // it fits (an opened setting's keys), else from its first line; the
    // buttons below the boxes show the end.
    let top = match focus_y {
        Some(fy) => {
            let want_end = focus_end + 2;
            let top = want_end.saturating_sub(area.height).min(fy);
            top.min(total.saturating_sub(area.height))
        }
        None if matches!(p.focused(), Some(Item::Button(_))) => total.saturating_sub(area.height),
        None => 0,
    };
    let buf = f.buffer_mut();
    for row in 0..area.height.min(total.saturating_sub(top)) {
        for col in 0..area.width {
            buf[(area.x + col, area.y + row)] = page[(col, top + row)].clone();
        }
    }
    let more = |text: &str, at_y: u16, buf: &mut Buffer| {
        let w = text.chars().count() as u16;
        if area.width > w + 2 {
            buf.set_string(
                area.x + area.width - w - 2,
                at_y,
                text,
                Style::new().fg(theme::COUNT),
            );
        }
    };
    if top > 0 {
        more(" ↑ more ", area.y, buf);
    }
    if top + area.height < total {
        more(" ↓ more ", area.y + area.height - 1, buf);
    }
}

/// The work's progress while it runs, then how it ended, where the choices
/// were.
fn draw_run(f: &mut Frame, p: &Panel, r: &super::run::RunView, area: Rect) {
    let width = usize::from(area.width.saturating_sub(2));
    let (heading, style) = match &r.result {
        None => ("Working".to_string(), theme::white()),
        Some(fin) if fin.ok => (fin.title.clone(), theme::green()),
        Some(fin) => (fin.title.clone(), theme::label()),
    };
    let text = run_lines(r, width);
    let shown = area.height.saturating_sub(2);
    let rows = rows_of(&text, area.width.saturating_sub(2));
    let max = rows.saturating_sub(shown);
    // While work runs its end stays in view; otherwise PgUp/PgDn scroll.
    let skip = if r.finished() {
        p.info_scroll.min(max)
    } else {
        max
    };
    let block = crate::ui::boxed_line(Line::from(Span::styled(format!(" {heading} "), style)));
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .scroll((skip, 0))
            .block(block),
        area,
    );
}

/// One check's line: the badge, the label, then the value, wrapped under
/// its own column.
fn status_line_rows(l: &super::StatusLine, width: usize) -> Vec<Line<'static>> {
    use super::Check;
    let value_w = width.saturating_sub(1 + BADGE_W + LABEL_W).max(8);
    let pad = " ".repeat(1 + BADGE_W + LABEL_W);
    let style = match l.level {
        Check::Ok => theme::green(),
        Check::Warn => theme::label(),
        Check::Fail => Style::new()
            .fg(Color::LightRed)
            .add_modifier(Modifier::BOLD),
        Check::Unknown => theme::dim(),
    };
    wrap(&l.value, value_w)
        .into_iter()
        .enumerate()
        .map(|(i, part)| {
            if i == 0 {
                Line::from(vec![
                    Span::raw(" "),
                    Span::styled(format!("{} ", l.level.badge()), style),
                    Span::styled(
                        format!("{:LABEL_W$}", l.label),
                        Style::new().fg(theme::FILTER_LABEL),
                    ),
                    Span::raw(part),
                ])
            } else {
                Line::from(vec![Span::raw(pad.clone()), Span::raw(part)])
            }
        })
        .collect()
}

fn status_box_lines_all(lines: &[super::StatusLine], width: usize) -> Vec<Line<'static>> {
    lines
        .iter()
        .flat_map(|l| status_line_rows(l, width))
        .collect()
}

/// The Status box: whether the fix is in, then each check that needs a
/// look. The ones that came out fine aren't listed.
fn status_card_lines(p: &Panel, width: usize) -> Vec<Line<'static>> {
    use super::Check;
    let problems: Vec<super::StatusLine> = p
        .status_lines()
        .into_iter()
        .filter(|l| matches!(l.level, Check::Warn | Check::Fail))
        .collect();
    let mut out = banner_lines(p);
    out.extend(status_box_lines_all(&problems, width));
    out
}

/// Rows `lines` take, wrapped at `width`.
fn rows_of(lines: &[Line], width: u16) -> u16 {
    let w = usize::from(width.max(1));
    lines
        .iter()
        .map(|l| l.width().div_ceil(w).max(1))
        .sum::<usize>()
        .try_into()
        .unwrap_or(u16::MAX)
}

fn boxed_text(f: &mut Frame, title: &str, text: Vec<Line<'static>>, area: Rect) {
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .block(boxed(title)),
        area,
    );
}

/// A box with no title.
fn plain() -> ratatui::widgets::Block<'static> {
    ratatui::widgets::Block::bordered()
        .border_type(ratatui::widgets::BorderType::Rounded)
        .border_style(Style::new().fg(theme::BORDER))
}

fn title(p: &Panel) -> Line<'static> {
    let store = match (&p.facts.wine_launcher, p.facts.store) {
        (Some(w), _) => w.launcher,
        (None, Some(Store::Steam)) => "Steam",
        (None, Some(Store::Gog)) => "Heroic",
        (None, None) => "",
    };
    let mut parts = vec![Span::styled(format!(" {} ", p.name), theme::white())];
    if !store.is_empty() {
        parts.push(Span::styled(
            format!("─ {store} "),
            Style::new().fg(theme::LABEL),
        ));
    }
    Line::from(parts)
}

/// The banner's line: whether the fix is in. The game's profile says what it
/// knows about EAX.
pub fn banner_lines(p: &Panel) -> Vec<Line<'static>> {
    let dot = |style: Style, text: String| {
        Line::from(vec![
            Span::raw(" "),
            Span::styled("●", style),
            Span::raw(" "),
            Span::styled(text, style),
        ])
    };
    let dim = Style::new().fg(theme::LABEL);
    let yellow = theme::label();
    let install = match (&p.installed, &p.problem) {
        (Some(i), _) => {
            // With the versions when the install recorded them.
            let named = |name: &str, v: &Option<String>| match v {
                Some(v) => format!("{name} {v}"),
                None => name.to_string(),
            };
            let oal = named("OpenAL Soft", &i.state.openal_version);
            dot(
                theme::green(),
                match i.state.engine {
                    Engine::Dsoal => format!(
                        "{} and {oal} are installed",
                        named("DSOAL", &i.state.dsoal_version)
                    ),
                    Engine::OpenAlSoft => format!("{oal} is installed"),
                },
            )
        }
        (None, Some(_)) if p.facts.linux_build => dot(
            yellow,
            format!(
                "Can't install, because this is the Linux version of {}",
                p.name
            ),
        ),
        (None, Some(_)) => dot(
            yellow,
            format!("Can't install yet, because {} has no Wine prefix", p.name),
        ),
        (None, None) => dot(dim, "Not installed".into()),
    };
    vec![install]
}

/// One line about what's installed now.
pub fn status_line(p: &Panel) -> String {
    let Some(i) = &p.installed else {
        let dir = crate::library::tilde(&p.facts.game_dir, &p.home);
        return format!("{} is in {dir}", p.name);
    };
    let s = &i.state;
    let mut parts = vec![match s.engine {
        Engine::Dsoal => "DSOAL with OpenAL Soft".to_string(),
        Engine::OpenAlSoft => "OpenAL Soft".to_string(),
    }];
    if let Some(sp) = i.speakers() {
        parts.push(super::speakers_label(&sp));
    }
    parts.push(match s.over {
        OverrideKind::Launcher => match p.facts.launcher.as_ref().map(|t| t.launcher.label()) {
            Some(l) => format!("DLL override in {l}"),
            None => "DLL override in the launcher".into(),
        },
        OverrideKind::Registry => "DLL override in the prefix's registry".into(),
        OverrideKind::Manual => "DLL override set by hand".into(),
    });
    if s.vcrun {
        parts.push("VC++ runtime".into());
    }
    if s.eax_unified {
        parts.push("EAX Unified".into());
    }
    if p.facts.launcher.is_some() {
        parts.push(
            if p.sound_log_on {
                "sound log on"
            } else {
                "sound log off"
            }
            .into(),
        );
    }
    parts.join(" · ")
}

fn truncate(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        s.to_string()
    } else {
        let mut t: String = s.chars().take(max - 1).collect();
        t.push('…');
        t
    }
}

fn confirm_lines(heading: &str, lines: &[(String, String)], nothing: bool) -> Vec<Line<'static>> {
    let mut text: Vec<Line> = Vec::new();
    if nothing {
        text.push(Line::from(
            "Nothing has changed, so there's nothing to apply.",
        ));
        return text;
    }
    // A caution goes above the usual heading, a blank line between them.
    for part in heading.split('\n') {
        text.push(Line::from(Span::styled(part.to_string(), theme::white())));
    }
    text.push(Line::from(""));
    let width = lines
        .iter()
        .map(|(a, _)| a.chars().count())
        .max()
        .unwrap_or(0)
        + 2;
    for (what, change) in lines {
        text.push(Line::from(vec![
            Span::styled(
                format!("  {what:width$}"),
                Style::new().fg(theme::FILTER_LABEL),
            ),
            Span::raw(change.clone()),
        ]));
    }
    text
}

fn uninstall_lines(p: &Panel, u: &super::UninstallView) -> Vec<Line<'static>> {
    let mut text: Vec<Line<'static>> = vec![Line::from(Span::styled(
        "Uninstalling removes:",
        theme::white(),
    ))];
    for r in &u.survey.files {
        let mut line = format!("  {}", short_path(p, &r.path));
        if r.backup.is_some() {
            line.push_str("  (the original is put back)");
        }
        text.push(Line::from(line));
    }
    if !u.survey.shared_with.is_empty() {
        text.push(Line::from(""));
        let n = u.survey.shared_with.len();
        text.push(Line::from(if n == 1 {
            "1 other game uses the same prefix, so the prefix's files stay until it's uninstalled too.".to_string()
        } else {
            format!("{n} other games use the same prefix, so the prefix's files stay until the last of them is uninstalled.")
        }));
    }
    text.push(Line::from(""));
    let focus = p.focused();
    let tick = |on: bool| if on { "[x]" } else { "[ ]" };
    let mut toggle = |b: Button, on: bool, label: String| {
        let sel = focus == Some(Item::Button(b));
        text.push(
            Line::from(vec![
                gutter(sel),
                Span::raw(format!("{} {label}", tick(on))),
            ])
            .style(if sel {
                Style::new().bg(theme::SELECT_BG)
            } else {
                Style::new()
            }),
        );
    };
    if !u.survey.settings.is_empty() {
        let titles: Vec<&str> = u.survey.settings.iter().map(|s| s.title.as_str()).collect();
        toggle(
            Button::KeepSettings,
            u.put_back_settings,
            format!("Put back the game's settings: {}", titles.join(", ")),
        );
    }
    if !u.survey.launcher_lines().is_empty() {
        toggle(
            Button::KeepOverride,
            u.keep_override,
            "Keep the DLL override in the launcher".into(),
        );
    }
    if u.survey.vcrun_present {
        toggle(
            Button::RemoveVcrun,
            u.remove_vcrun,
            "Remove Microsoft's VC++ 2022 runtime from the prefix".into(),
        );
    }
    text
}

const SPINNER: [&str; 4] = ["|", "/", "-", "\\"];

/// Each step with a tick (the running one with a spinner) and what it did
/// under it. Once it's over the details fold away and the finish follows:
/// what happened, the numbered next steps, the settings changed, and every
/// warning from the run.
fn run_lines(r: &super::run::RunView, width: usize) -> Vec<Line<'static>> {
    let mut text: Vec<Line<'static>> = Vec::new();
    let done = r.finished();
    for (i, (s, details)) in r.steps.iter().enumerate() {
        let last = i + 1 == r.steps.len();
        let mark = if last && !done {
            let tick = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() / 150) as usize;
            Span::styled(format!(" {} ", SPINNER[tick % 4]), theme::key())
        } else {
            Span::styled(" ✓ ", theme::green())
        };
        text.push(Line::from(vec![mark, Span::raw(s.clone())]));
        if !done {
            for d in details {
                text.push(Line::from(Span::styled(format!("     {d}"), theme::dim())));
            }
        }
    }
    if !done {
        for n in &r.notes {
            text.push(Line::from(vec![
                Span::styled(" ! ", theme::label()),
                Span::raw(n.clone()),
            ]));
        }
        return text;
    }
    let Some(fin) = &r.result else { return text };
    let heading = |text: &mut Vec<Line<'static>>, h: String, style: Style| {
        text.push(Line::from(""));
        text.push(Line::from(Span::styled(format!(" {h}"), style)));
    };
    if !fin.lines.is_empty() {
        text.push(Line::from(""));
        let style = if fin.ok {
            theme::white()
        } else {
            theme::label()
        };
        for l in &fin.lines {
            for part in wrap(l, width.saturating_sub(2)) {
                text.push(Line::from(Span::styled(format!(" {part}"), style)));
            }
        }
    }
    if !fin.next.is_empty() {
        heading(&mut text, "Next steps".into(), theme::note());
        for (n, step) in fin.next.iter().enumerate() {
            for (i, part) in wrap(step, width.saturating_sub(5)).into_iter().enumerate() {
                text.push(if i == 0 {
                    Line::from(vec![
                        Span::styled(format!("  {}. ", n + 1), theme::key()),
                        Span::raw(part),
                    ])
                } else {
                    Line::from(format!("     {part}"))
                });
            }
        }
    }
    if !fin.settings.is_empty() {
        heading(&mut text, "Game settings changed".into(), theme::note());
        for (title, follow) in &fin.settings {
            text.push(Line::from(vec![
                Span::styled("  • ", theme::green()),
                Span::raw(title.clone()),
            ]));
            for part in wrap(follow, width.saturating_sub(4)) {
                text.push(Line::from(Span::styled(
                    format!("    {part}"),
                    theme::dim(),
                )));
            }
        }
    }
    if !r.notes.is_empty() {
        let n = r.notes.len();
        let h = if n == 1 {
            "1 warning".to_string()
        } else {
            format!("{n} warnings")
        };
        heading(&mut text, h, theme::label());
        for note in &r.notes {
            for (i, part) in wrap(note, width.saturating_sub(4)).into_iter().enumerate() {
                let lead = if i == 0 { "  ! " } else { "    " };
                text.push(Line::from(vec![
                    Span::styled(lead, theme::label()),
                    Span::raw(part),
                ]));
            }
        }
    }
    text
}

pub fn button_label(p: &Panel, b: Button) -> &'static str {
    match b {
        Button::Install => "Install",
        Button::Apply => "Apply changes",
        Button::Uninstall => "Uninstall…",
        Button::SoundLog if p.sound_log_on => "Turn the sound log off",
        Button::SoundLog => "Turn the sound log on",
        Button::CheckAgain => "Check again",
        Button::Confirm => match &p.screen {
            Screen::Uninstall(_) => "Uninstall",
            _ => "Apply",
        },
        Button::Back => match &p.screen {
            Screen::Run(_) => "Back to the game",
            _ => "Cancel",
        },
        Button::KeepSettings | Button::KeepOverride | Button::RemoveVcrun => "",
    }
}

fn draw_buttons(f: &mut Frame, p: &Panel, area: Rect) {
    if p.running() {
        return;
    }
    let focus = p.focused();
    let mut spans = Vec::new();
    for b in p.buttons() {
        if matches!(&p.screen, Screen::Confirm { jobs, .. } if jobs.is_empty())
            && b == Button::Confirm
        {
            continue;
        }
        let sel = focus == Some(Item::Button(b));
        let style = if sel {
            Style::new()
                .fg(theme::SELECT_TEXT)
                .bg(theme::SELECT_BAR)
                .add_modifier(Modifier::BOLD)
        } else {
            Style::new().fg(theme::LABEL)
        };
        spans.push(Span::styled(format!("[ {} ]", button_label(p, b)), style));
        spans.push(Span::raw("  "));
    }
    f.render_widget(Paragraph::new(Line::from(spans)).centered(), area);
}

fn help_text(p: &Panel) -> String {
    if p.running() {
        return "Working. This can take a minute while files download.".into();
    }
    match p.focused() {
        Some(Item::Choice(si, ri)) => {
            let r = p.choice(si, ri);
            r.options[r.chosen].help.clone()
        }
        Some(Item::Setting(i)) => {
            let fix = &p.fixes[i];
            if fix.follow_up.is_empty() {
                fix.reason.clone()
            } else {
                format!("{} {}", fix.reason, fix.follow_up)
            }
        }
        Some(Item::Button(b)) => match b {
            Button::Install => "Shows what will be installed before anything is changed.".into(),
            Button::Apply => "Shows what will change before anything is changed.".into(),
            Button::Uninstall => "Shows what uninstalling removes and puts back.".into(),
            Button::SoundLog if p.sound_log_on => "Stops writing openal.log the next time the game runs.".into(),
            Button::SoundLog => "Writes openal.log in the game's folder the next time it runs, for working out a sound problem.".into(),
            Button::CheckAgain => "Looks at the game's folder and prefix again.".into(),
            _ => String::new(),
        },
        None => String::new(),
    }
}

/// The page's keys, for the browser's key bar.
pub fn keys(p: &Panel) -> Vec<(&'static str, &'static str)> {
    if p.question.is_some() {
        QUESTION_KEYS.to_vec()
    } else if p.list.is_some() {
        vec![("↑/↓", "move"), ("Enter", "pick"), ("Esc", "keep")]
    } else if p.running() {
        Vec::new()
    } else if matches!(p.screen, Screen::Run(_)) {
        vec![("Enter", "back to the game")]
    } else if matches!(p.screen, Screen::Confirm { .. }) {
        vec![("←/→", "move"), ("Enter", "press"), ("Esc", "cancel")]
    } else if matches!(p.screen, Screen::Uninstall(_)) {
        vec![
            ("↑/↓", "move"),
            ("Space", "tick"),
            ("Enter", "press"),
            ("Esc", "cancel"),
        ]
    } else {
        vec![
            ("↑/↓", "move"),
            ("Tab", "next section"),
            ("Enter", "choose"),
            ("Space", "tick"),
            ("Esc", "back"),
            ("F1", "help"),
        ]
    }
}

fn popup(area: Rect, w: u16, h: u16) -> Rect {
    let w = w.min(area.width);
    let h = h.min(area.height);
    Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    )
}

/// Every setting's pop-up is this wide, whatever its text, so they all look
/// alike; long descriptions wrap instead of widening the box.
pub const LIST_W: u16 = 60;

fn draw_list(f: &mut Frame, p: &Panel, area: Rect) {
    let (Some(sel), Some(item)) = (p.list, p.focused()) else {
        return;
    };
    let row = match item {
        Item::Choice(si, ri) => p.choice(si, ri),
        _ => return,
    };
    draw_dropdown(
        f,
        row.title,
        &row.options,
        (row.chosen, sel),
        area,
        &p.list_top,
    );
}

/// Rows kept between the highlighted option and the edge of a scrolling list.
const LIST_SCROLL_OFF: usize = 2;

/// The first line of a list's window: where it was (`top`), moved only as far
/// as it takes to show all of the highlighted option's lines (`first` to
/// `last`) with a little room either side, within the list's `total` lines.
pub fn list_window(top: usize, first: usize, last: usize, viewport: usize, total: usize) -> usize {
    if total <= viewport {
        return 0;
    }
    let room = LIST_SCROLL_OFF.min(viewport.saturating_sub(last - first + 1) / 2);
    let mut top = top.min(total - viewport);
    if first < top + room {
        top = first.saturating_sub(room);
    }
    if last + room >= top + viewport {
        top = (last + room + 1).saturating_sub(viewport);
    }
    top.min(total - viewport)
}

/// A list of options in a pop-up `LIST_W` wide, under `field` like a
/// dropdown (above it when there's no room below), or in the middle of `area`
/// when there's no field on screen.
pub fn draw_dropdown(
    f: &mut Frame,
    title: &str,
    options: &[super::Opt],
    (chosen, sel): (usize, usize),
    area: Rect,
    top: &std::cell::Cell<usize>,
) {
    let w = LIST_W.min(area.width);
    // Inside the border and the margin, after the gutter and the mark.
    let text_w = usize::from(w.saturating_sub(2 + 4))
        .saturating_sub(4)
        .max(1);
    let (lines, spans) = list_lines_and_spans(options, chosen, sel, text_w);
    // As tall as its lines, or the screen; a longer list scrolls.
    let h = (lines.len() as u16 + 4).min(area.height);
    // Always in the middle of the screen, wherever its field is.
    let r = popup(area, w, h);
    let viewport = usize::from(r.height.saturating_sub(4)).max(1);
    let total = lines.len();
    let (first, last) = spans.get(sel).copied().unwrap_or((0, 0));
    let at = list_window(top.get(), first, last, viewport, total);
    top.set(at);
    f.render_widget(Clear, r);
    f.render_widget(
        Paragraph::new(lines)
            .scroll((u16::try_from(at).unwrap_or(u16::MAX), 0))
            .block(boxed(title).padding(crate::ui::MARGIN)),
        r,
    );
    crate::ui::scroll_bar(f, r, viewport, total, at);
}

/// [`list_lines`], and each option's first and last line among them.
pub fn list_lines_and_spans(
    options: &[super::Opt],
    chosen: usize,
    sel: usize,
    text_w: usize,
) -> (Vec<Line<'static>>, Vec<(usize, usize)>) {
    let mut lines = Vec::new();
    let mut spans = Vec::new();
    for (i, o) in options.iter().enumerate() {
        if i > 0 {
            lines.push(Line::from(""));
        }
        let one = option_lines(o, i == chosen, i == sel, text_w);
        spans.push((lines.len(), lines.len() + one.len().max(1) - 1));
        lines.extend(one);
    }
    (lines, spans)
}

/// A setting's options for its pop-up: each label with its description
/// wrapped under it, a blank row between options, the highlighted one on a
/// dark background.
pub fn list_lines(
    options: &[super::Opt],
    chosen: usize,
    sel: usize,
    text_w: usize,
) -> Vec<Line<'static>> {
    list_lines_and_spans(options, chosen, sel, text_w).0
}

/// One option: its label (marked when it's the one chosen), then its
/// description, wrapped at `text_w`.
fn option_lines(o: &super::Opt, chosen: bool, on: bool, text_w: usize) -> Vec<Line<'static>> {
    let bg = if on {
        Style::new().bg(theme::SELECT_BG)
    } else {
        Style::new()
    };
    let mark = if chosen { "• " } else { "  " };
    let mut lines = Vec::new();
    for (j, l) in wrap(&o.label, text_w).into_iter().enumerate() {
        lines.push(
            Line::from(vec![
                gutter(on),
                Span::raw(if j == 0 { mark } else { "  " }),
                Span::styled(l, theme::white()),
            ])
            .style(bg),
        );
    }
    if !o.help.is_empty() {
        for l in wrap(&o.help, text_w) {
            lines.push(
                Line::from(vec![
                    gutter(on),
                    Span::raw("  "),
                    Span::styled(l, theme::dim()),
                ])
                .style(bg),
            );
        }
    }
    lines
}

/// A yes/no question in a pop-up, with Yes and No buttons; `yes` is the
/// highlighted one.
pub(crate) fn draw_question(f: &mut Frame, text: &str, ask: &str, yes: bool, area: Rect) {
    let w = (text.chars().count().max(ask.chars().count()) + 6).min(70) as u16;
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
    let lines = vec![
        Line::from(text.to_string()),
        Line::from(""),
        Line::from(Span::styled(ask.to_string(), theme::white())),
        Line::from(""),
        Line::from(vec![
            button("Yes", yes),
            Span::raw("  "),
            button("No", !yes),
        ])
        .centered(),
    ];
    let inner_w = usize::from(w.saturating_sub(4)).max(1);
    let rows: usize = [text, "", ask, "", ""]
        .iter()
        .map(|l| l.chars().count().div_ceil(inner_w).max(1))
        .sum();
    let r = popup(area, w, rows as u16 + 2);
    f.render_widget(Clear, r);
    f.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: true })
            .block(plain().padding(ratatui::widgets::Padding::horizontal(1))),
        r,
    );
}

/// A key pressed while a yes/no question shows: the arrows and Tab move
/// between Yes and No, Enter presses the highlighted one, and y, n and Esc
/// answer straight away. `None` while there's no answer yet.
pub(crate) fn question_key(code: KeyCode, yes: &mut bool) -> Option<bool> {
    match code {
        KeyCode::Char('y' | 'Y') => Some(true),
        KeyCode::Char('n' | 'N') | KeyCode::Esc => Some(false),
        KeyCode::Enter => Some(*yes),
        KeyCode::Left | KeyCode::Right | KeyCode::Tab | KeyCode::BackTab => {
            *yes = !*yes;
            None
        }
        _ => None,
    }
}

/// The key bar while a yes/no question shows.
pub(crate) const QUESTION_KEYS: [(&str, &str); 4] = [
    ("←/→", "move"),
    ("Enter", "press"),
    ("y", "yes"),
    ("n", "no"),
];

/// A path inside the game's folder or its prefix, from there.
fn short_path(p: &Panel, path: &std::path::Path) -> String {
    if let Ok(rest) = path.strip_prefix(&p.facts.game_dir) {
        return format!("game folder/{}", rest.display());
    }
    if let Some(rest) = p
        .facts
        .prefix
        .as_deref()
        .and_then(|x| path.strip_prefix(x).ok())
    {
        return format!("prefix/{}", rest.display());
    }
    path.display().to_string()
}

#[cfg(test)]
mod tests {
    use super::super::run::{Finish, RunView};
    use super::*;

    #[test]
    fn a_list_window_moves_only_as_far_as_the_highlight_needs() {
        // 100 lines, 20 showing, two rows of room kept either side.
        assert_eq!(list_window(0, 0, 1, 20, 100), 0);
        // Within the window: it stays.
        assert_eq!(list_window(0, 10, 11, 20, 100), 0);
        // Near the bottom edge: just enough to show it with its room.
        assert_eq!(list_window(0, 18, 19, 20, 100), 2);
        // Back up near the top: the window follows.
        assert_eq!(list_window(30, 30, 31, 20, 100), 28);
        // The end of the list, and a list that fits.
        assert_eq!(list_window(0, 98, 99, 20, 100), 80);
        assert_eq!(list_window(5, 3, 4, 20, 10), 0);
    }

    fn text(lines: &[Line]) -> Vec<String> {
        lines
            .iter()
            .map(|l| l.spans.iter().map(|s| s.content.as_ref()).collect())
            .collect()
    }

    #[test]
    fn the_finish_folds_the_details_and_lists_next_steps_settings_and_warnings() {
        let r = RunView::finished_with(
            vec![(
                "Copying the files into the game's folder".into(),
                vec!["Copied dsound.dll to the game folder".into()],
            )],
            vec!["Couldn't write /x/dsound.dll.".into()],
            Finish {
                ok: true,
                title: "Installed".into(),
                next: vec![
                    "Launch Thief Gold. The DLL override is in Steam's launch options, so just hit Play.".into(),
                ],
                settings: vec![(
                    "Enable Pro Logic surround sound".into(),
                    "Don't forget to set your AV receiver or Soundbar to Dolby Pro Logic.".into(),
                )],
                lines: Vec::new(),
            },
        );
        let t = text(&run_lines(&r, 60)).join("\n");
        assert!(t.contains(" ✓ Copying the files into the game's folder"));
        assert!(!t.contains("Copied dsound.dll to the game folder"), "{t}");
        let order = [
            " Next steps",
            "  1. Launch Thief Gold.",
            " Game settings changed",
            "  • Enable Pro Logic surround sound",
            "    Don't forget to set your AV receiver",
            " 1 warning",
            "  ! Couldn't write /x/dsound.dll.",
        ];
        let at: Vec<usize> = order
            .iter()
            .map(|s| t.find(s).unwrap_or_else(|| panic!("{s:?} in\n{t}")))
            .collect();
        assert!(at.windows(2).all(|w| w[0] < w[1]), "{t}");
    }
}
