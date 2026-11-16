//! Draws the game page in three columns, like Optiscaler-Client: the cover
//! and the game's name on the left, its choices in numbered boxes in the
//! middle (in the order the script asks them), and on the right a Status box
//! that types itself out like a boot, with the game's profile under it. While
//! work runs, the right column shows its progress and then how it ended.

use super::{Button, Item, Panel, Row, Screen};
use crate::engine::game_settings::{Category, Fix, Status};
use crate::engine::identify::Store;
use crate::engine::install::Engine;
use crate::engine::installed::OverrideKind;
use crate::theme;
use crate::ui::{boxed, boxed_line, gutter};
use ratatui::buffer::Buffer;
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Widget, Wrap};
use ratatui::Frame;

/// From this width the cover gets a column of its own.
pub const COVER_FROM: u16 = 150;
/// From this width the Status column sits beside the choices, not under them.
pub const BESIDE_FROM: u16 = 100;
const COVER_W: u16 = 30;
const RIGHT_W: u16 = 50;
/// Status box: the badge, then the label column.
const BADGE_W: usize = 5;
const LABEL_W: usize = 12;

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

/// Draws the page over `area`, the whole body.
pub fn draw(f: &mut Frame, p: &Panel, area: Rect) {
    f.render_widget(Clear, area);
    let (cover, rest) = if area.width >= COVER_FROM {
        let [c, r] =
            Layout::horizontal([Constraint::Length(COVER_W), Constraint::Min(0)]).areas(area);
        (Some(c), r)
    } else {
        (None, area)
    };
    let [middle, right] = if area.width >= BESIDE_FROM {
        Layout::horizontal([Constraint::Min(0), Constraint::Length(RIGHT_W)]).areas(rest)
    } else {
        Layout::vertical([Constraint::Percentage(55), Constraint::Percentage(45)]).areas(rest)
    };
    if let Some(c) = cover {
        draw_cover(f, p, c);
    }
    draw_middle(f, p, middle);
    draw_right(f, p, right);
    if p.list.is_some() {
        draw_list(f, p, area);
    }
    if let Some(q) = &p.question {
        draw_question(f, &q.text, &q.ask, area);
    }
}

/// The left column: the cover as coloured ASCII, then the game's name, its
/// store, and at the bottom its folder.
fn draw_cover(f: &mut Frame, p: &Panel, area: Rect) {
    let block = plain();
    let inner = block.inner(area);
    f.render_widget(block, area);
    let w = usize::from(inner.width.saturating_sub(2)).max(1);
    let mut below: Vec<Line> = wrap(&p.name, w)
        .into_iter()
        .map(|l| Line::from(Span::styled(format!(" {l}"), theme::white())))
        .collect();
    if let Some(store) = store_name(p) {
        below.push(Line::from(Span::styled(
            format!(" {store}"),
            theme::green(),
        )));
    }
    let folder: Vec<Line> = wrap(&crate::library::tilde(&p.facts.game_dir, &p.home), w)
        .into_iter()
        .map(|l| Line::from(Span::styled(format!(" {l}"), theme::dim())))
        .collect();
    let art_rows = inner
        .height
        .saturating_sub((below.len() + folder.len() + 2) as u16);
    let mut lines = match &p.cover {
        Some(px) => crate::cover::ascii(px, inner.width, art_rows, crate::cover::truecolor()),
        None => Vec::new(),
    };
    lines.push(Line::from(""));
    lines.extend(below);
    let top = Rect {
        height: inner.height.saturating_sub(folder.len() as u16),
        ..inner
    };
    f.render_widget(Paragraph::new(lines), top);
    let bottom = Rect {
        y: inner.y + inner.height.saturating_sub(folder.len() as u16),
        height: (folder.len() as u16).min(inner.height),
        ..inner
    };
    f.render_widget(Paragraph::new(folder), bottom);
}

fn store_name(p: &Panel) -> Option<&'static str> {
    match p.facts.store {
        Some(Store::Steam) => Some("Steam"),
        Some(Store::Gog) => Some("GOG, through Heroic"),
        None => None,
    }
}

/// The middle column: the choices (or the confirm and uninstall screens), a
/// line of help for what has focus, and the buttons.
fn draw_middle(f: &mut Frame, p: &Panel, area: Rect) {
    let block = boxed_line(title(p));
    let inner = block.inner(area);
    f.render_widget(block, area);
    p.field.set(None);
    let [banner, inner] =
        Layout::vertical([Constraint::Length(4), Constraint::Min(0)]).areas(inner);
    f.render_widget(
        Paragraph::new(banner_lines(p)).block(boxed("EAX fix")),
        banner,
    );
    // Nothing to choose until the Status box has finished typing.
    if p.revealing() {
        return;
    }
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
        Screen::Main | Screen::Run(_) => draw_choices(f, p, body),
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
    if let (Some(fy), Some(Item::Choice(..))) = (focus_y, p.focused()) {
        if fy >= top && fy < top + area.height {
            let (title_w, field_w) = field_geometry(p, usize::from(area.width));
            // Past the box's border and the gutter, then the row's name.
            let x = area.x + 1 + 2 + title_w as u16;
            p.field.set(Some(Rect::new(
                x,
                area.y + fy - top,
                (field_w as u16 + 6).min(area.width.saturating_sub(x - area.x)),
                1,
            )));
        }
    }
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

/// The right column: the work's progress while it runs (and how it ended),
/// else the Status box with the game's profile under it.
fn draw_right(f: &mut Frame, p: &Panel, area: Rect) {
    if let Screen::Run(r) = &p.screen {
        return draw_run(f, p, r, area);
    }
    let status = status_box_lines(p, usize::from(area.width.saturating_sub(2)));
    let full = p.status_lines();
    let full_rows = status_box_lines_all(&full, usize::from(area.width.saturating_sub(2))).len();
    let h = (full_rows as u16 + 2).min(area.height);
    let [top, rest] = Layout::vertical([Constraint::Length(h), Constraint::Min(0)]).areas(area);
    f.render_widget(Paragraph::new(status).block(boxed("Status")), top);
    if p.revealing() || rest.height < 3 {
        return;
    }
    let w = usize::from(rest.width.saturating_sub(4)).max(10);
    let lines = match &p.game {
        Some(g) => crate::profile::database_lines(g, w),
        None => vec![Line::from(Span::styled(
            format!(" The game database has no profile for {}.", p.name),
            theme::dim(),
        ))],
    };
    let max = rows_of(&lines, rest.width.saturating_sub(2)).saturating_sub(rest.height - 2);
    f.render_widget(
        Paragraph::new(lines)
            .wrap(Wrap { trim: false })
            .scroll((p.info_scroll.min(max), 0))
            .block(boxed("Game profile")),
        rest,
    );
}

/// One Status line: a green `[OK]` or yellow `[!!]`, the label, then the
/// value, wrapped under its own column.
fn status_line_rows(l: &super::StatusLine, width: usize) -> Vec<Line<'static>> {
    let value_w = width.saturating_sub(1 + BADGE_W + LABEL_W).max(8);
    let pad = " ".repeat(1 + BADGE_W + LABEL_W);
    let (badge, style) = if l.ok {
        ("[OK] ", theme::green())
    } else {
        ("[!!] ", theme::label())
    };
    wrap(&l.value, value_w)
        .into_iter()
        .enumerate()
        .map(|(i, part)| {
            if i == 0 {
                Line::from(vec![
                    Span::raw(" "),
                    Span::styled(badge, style),
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

/// The Status box as it stands: every line, or while it types itself out,
/// the lines done so far, the one being typed, and a blinking cursor.
fn status_box_lines(p: &Panel, width: usize) -> Vec<Line<'static>> {
    let all = p.status_lines();
    let Some((done, chars)) = p.revealed() else {
        return status_box_lines_all(&all, width);
    };
    let mut out = status_box_lines_all(&all[..done.min(all.len())], width);
    let cursor_on = p
        .reveal
        .is_some_and(|t| (t.elapsed().as_millis() / 500) % 2 == 0);
    let cursor = Span::styled(if cursor_on { "█" } else { " " }, theme::white());
    if let Some(l) = all.get(done) {
        // The badge comes last, once the line is typed out, as a boot does.
        let typed: String = format!("{:LABEL_W$}{}", l.label, l.value)
            .chars()
            .take(chars)
            .collect();
        let label: String = typed.chars().take(LABEL_W).collect();
        let value: String = typed.chars().skip(LABEL_W).collect();
        out.push(Line::from(vec![
            Span::raw(" "),
            Span::raw(" ".repeat(BADGE_W)),
            Span::styled(label, Style::new().fg(theme::FILTER_LABEL)),
            Span::raw(value),
            cursor,
        ]));
    } else {
        out.push(Line::from(vec![Span::raw(" "), cursor]));
    }
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
    let store = match p.facts.store {
        Some(Store::Steam) => "Steam",
        Some(Store::Gog) => "Heroic",
        None => "",
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

/// The banner's two lines, like Optiscaler-Client's status and compatibility:
/// whether the fix is in, and what the game's profile says about EAX.
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
        (Some(i), _) => dot(
            theme::green(),
            format!(
                "Installed: {}",
                match i.state.engine {
                    Engine::Dsoal => "DSOAL with OpenAL Soft",
                    Engine::OpenAlSoft => "OpenAL Soft",
                }
            ),
        ),
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
    let compat = match &p.game {
        None => dot(
            dim,
            "Not in the game database, so compatibility isn't known".into(),
        ),
        Some(g) => match g.eax.status.as_str() {
            "built_in" => dot(
                theme::green(),
                "Already has EAX, so this adds a newer OpenAL Soft and speaker settings".into(),
            ),
            "not_implemented" => dot(yellow, format!("This version of {} has no EAX", p.name)),
            "removed_by_patch" => dot(yellow, "EAX was removed by a later patch".into()),
            _ => {
                let store = match p.facts.store {
                    Some(Store::Steam) => g.stores.steam.as_ref(),
                    Some(Store::Gog) => g.stores.gog.as_ref(),
                    None => None,
                };
                let api = store.map_or(g.eax.api.as_str(), |s| crate::profile::api_of(g, s));
                let with = if api == "openal" {
                    "OpenAL Soft"
                } else {
                    "DSOAL + OpenAL Soft"
                };
                let text = if g.eax.versions.is_empty() {
                    format!("Compatible, restored with {with}")
                } else {
                    let v = &g.eax.versions;
                    let list = match v.split_last() {
                        Some((last, rest)) if !rest.is_empty() => {
                            format!("{} and {last}", rest.join(", "))
                        }
                        _ => v.join(""),
                    };
                    format!("Compatible with EAX {list}, restored with {with}")
                };
                dot(theme::green(), text)
            }
        },
    };
    vec![install, compat]
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
    text.push(Line::from(Span::styled(
        heading.to_string(),
        theme::white(),
    )));
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

/// The work's box in the right column. While it runs, its end stays in view;
/// once it's over, PgUp/PgDn scroll it.
fn draw_run(f: &mut Frame, p: &Panel, r: &super::run::RunView, area: Rect) {
    let width = usize::from(area.width.saturating_sub(2));
    let text = run_lines(r, width);
    let shown = area.height.saturating_sub(2);
    let rows = rows_of(&text, area.width.saturating_sub(2));
    let max = rows.saturating_sub(shown);
    let (title, style) = match &r.result {
        None => ("Working".to_string(), Style::new().fg(theme::LABEL)),
        Some(fin) if fin.ok => (fin.title.clone(), theme::green()),
        Some(fin) => (fin.title.clone(), theme::label()),
    };
    let skip = if r.finished() {
        p.info_scroll.min(max)
    } else {
        max
    };
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .scroll((skip, 0))
            .block(boxed_line(Line::from(Span::styled(
                format!(" {title} "),
                style,
            )))),
        area,
    );
}

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
        vec![("y", "yes"), ("n", "no")]
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

fn draw_list(f: &mut Frame, p: &Panel, area: Rect) {
    let (Some(sel), Some(item)) = (p.list, p.focused()) else {
        return;
    };
    let row = match item {
        Item::Choice(si, ri) => p.choice(si, ri),
        _ => return,
    };
    let w = row
        .options
        .iter()
        .map(|o| o.label.chars().count().max(o.help.chars().count()))
        .max()
        .unwrap_or(20)
        .max(row.title.len())
        + 8;
    let mut lines = Vec::new();
    for (i, o) in row.options.iter().enumerate() {
        let on = i == sel;
        let bg = if on {
            Style::new().bg(theme::SELECT_BG)
        } else {
            Style::new()
        };
        let mark = if i == row.chosen { "• " } else { "  " };
        lines.push(
            Line::from(vec![
                gutter(on),
                Span::raw(mark),
                Span::styled(o.label.clone(), theme::white()),
            ])
            .style(bg),
        );
        lines.push(
            Line::from(vec![
                gutter(on),
                Span::raw("  "),
                Span::styled(o.help.clone(), theme::dim()),
            ])
            .style(bg),
        );
    }
    let h = lines.len() as u16 + 2;
    // Under its field, like a dropdown: above it when there's no room below,
    // in the middle when the field isn't on screen.
    let r = match p.field.get() {
        Some(field) => {
            let w = (w as u16).max(field.width).min(area.width);
            let x = field.x.min(area.x + area.width - w);
            let below = field.y + 1;
            let y = if below + h <= area.y + area.height {
                below
            } else if field.y >= area.y + h {
                field.y - h
            } else {
                area.y + area.height.saturating_sub(h)
            };
            Rect::new(x, y, w, h.min(area.height))
        }
        None => popup(area, w as u16, h),
    };
    f.render_widget(Clear, r);
    f.render_widget(Paragraph::new(lines).block(boxed(row.title)), r);
}

fn draw_question(f: &mut Frame, text: &str, ask: &str, area: Rect) {
    let w = (text.chars().count().max(ask.chars().count()) + 6).min(70) as u16;
    let lines = vec![
        Line::from(text.to_string()),
        Line::from(""),
        Line::from(Span::styled(ask.to_string(), theme::white())),
        Line::from(""),
        Line::from(vec![
            Span::styled("y", theme::key()),
            Span::raw(" yes   "),
            Span::styled("n", theme::key()),
            Span::raw(" no"),
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
