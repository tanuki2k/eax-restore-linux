//! Draws the panel: its header and status, the Sound and Setup choices side
//! by side, the game's settings, a line of help for what has focus, and the
//! buttons. The confirm, uninstall and progress screens take the body's place.

use super::{Button, Item, Panel, Row, Screen};
use crate::engine::game_settings::{Fix, Status};
use crate::engine::identify::Store;
use crate::engine::install::Engine;
use crate::engine::installed::OverrideKind;
use crate::theme;
use crate::ui::{boxed, boxed_line, gutter};
use ratatui::layout::{Constraint, Layout, Rect};
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Clear, Paragraph, Wrap};
use ratatui::Frame;

pub fn draw(f: &mut Frame, p: &Panel) {
    let area = f.area();
    let block = boxed_line(title(p));
    let inner = block.inner(area);
    f.render_widget(Clear, area);
    f.render_widget(block, area);
    let [body, help, buttons, keys] = Layout::vertical([
        Constraint::Min(3),
        Constraint::Length(3),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);
    match &p.screen {
        Screen::Main => draw_main(f, p, body),
        Screen::Confirm { lines, jobs } => draw_confirm(f, lines, jobs.is_empty(), body),
        Screen::Uninstall(u) => draw_uninstall(f, p, u, body),
        Screen::Run(r) => draw_run(f, r, body),
    }
    f.render_widget(
        Paragraph::new(help_text(p))
            .wrap(Wrap { trim: true })
            .block(plain())
            .style(theme::dim()),
        help,
    );
    draw_buttons(f, p, buttons);
    f.render_widget(Paragraph::new(key_line(p)).centered(), keys);
    if p.list.is_some() {
        draw_list(f, p, area);
    }
    if let Some(q) = &p.question {
        draw_question(f, &q.text, &q.ask, area);
    }
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
    let (state, style) = if p.installed.is_some() {
        ("EAX fix installed", theme::green())
    } else {
        ("Not installed", Style::new().fg(theme::LABEL))
    };
    let mut parts = vec![Span::styled(format!(" {} ", p.name), theme::white())];
    if !store.is_empty() {
        parts.push(Span::styled(
            format!("─ {store} "),
            Style::new().fg(theme::LABEL),
        ));
    }
    parts.push(Span::styled("─ ", Style::new().fg(theme::LABEL)));
    parts.push(Span::styled(format!("{state} "), style));
    Line::from(parts)
}

/// One line about what's installed now.
pub fn status_line(p: &Panel) -> String {
    let Some(i) = &p.installed else {
        return format!("{} is in {}", p.name, p.facts.game_dir.display());
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

fn draw_main(f: &mut Frame, p: &Panel, area: Rect) {
    if let Some(problem) = &p.problem {
        f.render_widget(
            Paragraph::new(problem.as_str())
                .wrap(Wrap { trim: true })
                .block(plain().padding(ratatui::widgets::Padding::uniform(1))),
            area,
        );
        return;
    }
    let rows = p.sound.len().max(p.setup.len()) as u16 + 2;
    let [status, choices, settings] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(rows),
        Constraint::Min(3),
    ])
    .areas(area);
    f.render_widget(
        Paragraph::new(Line::from(vec![
            Span::styled(" Status  ", theme::label()),
            Span::raw(status_line(p)),
        ])),
        status,
    );
    let [left, right] =
        Layout::horizontal([Constraint::Percentage(50), Constraint::Percentage(50)]).areas(choices);
    let focus = p.focused();
    draw_rows(
        f,
        "Sound",
        &p.sound,
        |i| focus == Some(Item::Sound(i)),
        left,
    );
    draw_rows(
        f,
        "Setup",
        &p.setup,
        |i| focus == Some(Item::Setup(i)),
        right,
    );
    draw_settings(f, p, settings);
}

fn draw_rows(
    f: &mut Frame,
    title: &str,
    rows: &[Row],
    focused: impl Fn(usize) -> bool,
    area: Rect,
) {
    let block = boxed(title);
    let inner = block.inner(area);
    f.render_widget(block, area);
    let width = rows
        .iter()
        .map(|r| r.title.chars().count())
        .max()
        .unwrap_or(0)
        + 2;
    let lines: Vec<Line> = rows
        .iter()
        .enumerate()
        .map(|(i, r)| {
            let sel = focused(i);
            let bg = if sel {
                Style::new().bg(theme::SELECT_BG)
            } else {
                Style::new()
            };
            let value = if r.chosen != r.original {
                Style::new()
                    .fg(ratatui::style::Color::LightYellow)
                    .add_modifier(Modifier::BOLD)
            } else {
                Style::new()
            };
            Line::from(vec![
                gutter(sel),
                Span::styled(format!("{:width$}", r.title), theme::label()),
                Span::styled(r.value().to_string(), value),
            ])
            .style(bg)
        })
        .collect();
    f.render_widget(Paragraph::new(lines), inner);
}

/// The values a setting changes, as "file  key old → new".
fn setting_detail(fix: &Fix) -> String {
    match fix.status {
        Status::Missing => format!(
            "waits for {}, which the game writes the first time it runs",
            fix.missing_file.as_deref().unwrap_or("its settings file")
        ),
        Status::Already => "already set".into(),
        Status::Applied => fix
            .view
            .iter()
            .map(|v| {
                let file = v
                    .path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                format!("{file} {} = {}", v.key, v.new.display())
            })
            .collect::<Vec<_>>()
            .join(", "),
        Status::Absent => "this version of the game doesn't have the file".into(),
        _ => fix
            .view
            .iter()
            .map(|v| {
                let file = v
                    .path
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                let old = v
                    .old
                    .as_ref()
                    .map(|o| o.display())
                    .unwrap_or_else(|| "(not set)".into());
                format!("{file} {} {old} → {}", v.key, v.new.display())
            })
            .collect::<Vec<_>>()
            .join(", "),
    }
}

fn draw_settings(f: &mut Frame, p: &Panel, area: Rect) {
    let block = boxed("Game settings");
    let inner = block.inner(area);
    f.render_widget(block, area);
    if p.fixes.is_empty() {
        let text = if p.game.is_some() {
            "The game's profile has no settings to change."
        } else {
            "There's no profile for this game, so there are no settings to change."
        };
        f.render_widget(Paragraph::new(text).style(theme::dim()), inner);
        return;
    }
    let selected = match p.focused() {
        Some(Item::Setting(i)) => Some(i),
        _ => None,
    };
    let height = usize::from(inner.height);
    let top = selected.map_or(0, |s| s.saturating_sub(height.saturating_sub(1)));
    let width = p
        .fixes
        .iter()
        .map(|x| x.title.chars().count())
        .max()
        .unwrap_or(0)
        .min(40)
        + 2;
    let lines: Vec<Line> = p
        .fixes
        .iter()
        .enumerate()
        .skip(top)
        .take(height)
        .map(|(i, fix)| {
            let sel = selected == Some(i);
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
                    .fg(ratatui::style::Color::LightYellow)
                    .add_modifier(Modifier::BOLD)
            } else if Panel::tickable(fix) {
                Style::new()
            } else {
                theme::dim()
            };
            let mut spans = vec![
                gutter(sel),
                Span::raw(format!("{mark} ")),
                Span::styled(format!("{:width$}", truncate(&fix.title, 40)), title_style),
                Span::styled(setting_detail(fix), theme::dim()),
            ];
            if fix.untested {
                spans.push(Span::styled(" (untested)", theme::note()));
            }
            Line::from(spans).style(if sel {
                Style::new().bg(theme::SELECT_BG)
            } else {
                Style::new()
            })
        })
        .collect();
    f.render_widget(Paragraph::new(lines), inner);
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

fn draw_confirm(f: &mut Frame, lines: &[(String, String)], nothing: bool, area: Rect) {
    let mut text: Vec<Line> = Vec::new();
    if nothing {
        text.push(Line::from(
            "Nothing has changed, so there's nothing to apply.",
        ));
    } else {
        text.push(Line::from(Span::styled(
            "Apply these changes?",
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
                Span::styled(format!("  {what:width$}"), theme::label()),
                Span::raw(change.clone()),
            ]));
        }
    }
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .block(boxed("Apply changes")),
        area,
    );
}

fn draw_uninstall(f: &mut Frame, p: &Panel, u: &super::UninstallView, area: Rect) {
    let mut text: Vec<Line> = vec![Line::from(Span::styled(
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
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .block(boxed("Uninstall")),
        area,
    );
}

const SPINNER: [&str; 4] = ["|", "/", "-", "\\"];

fn draw_run(f: &mut Frame, r: &super::run::RunView, area: Rect) {
    let mut text: Vec<Line> = Vec::new();
    let done = r.finished();
    for (i, s) in r.steps.iter().enumerate() {
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
    }
    for n in &r.notes {
        text.push(Line::from(vec![
            Span::styled(" ! ", theme::label()),
            Span::raw(n.clone()),
        ]));
    }
    if let Some((ok, lines)) = &r.result {
        text.push(Line::from(""));
        let style = if *ok { theme::white() } else { theme::label() };
        for l in lines {
            text.push(Line::from(Span::styled(l.clone(), style)));
        }
    }
    // Keep the end in view.
    let height = usize::from(area.height.saturating_sub(2));
    let skip = text.len().saturating_sub(height) as u16;
    let title = if done { "Done" } else { "Working" };
    f.render_widget(
        Paragraph::new(text)
            .wrap(Wrap { trim: false })
            .scroll((skip, 0))
            .block(boxed(title)),
        area,
    );
}

pub fn button_label(p: &Panel, b: Button) -> &'static str {
    match b {
        Button::Install => "Install",
        Button::Apply => "Apply changes",
        Button::Uninstall => "Uninstall…",
        Button::SoundLog if p.sound_log_on => "Turn the sound log off",
        Button::SoundLog => "Turn the sound log on",
        Button::OtherTools => "Other tools…",
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
        Some(Item::Sound(i)) => p.sound[i].options[p.sound[i].chosen].help.clone(),
        Some(Item::Setup(i)) => p.setup[i].options[p.setup[i].chosen].help.clone(),
        Some(Item::Setting(i)) => {
            let fix = &p.fixes[i];
            if fix.follow_up.is_empty() {
                fix.reason.clone()
            } else {
                format!("{} {}", fix.reason, fix.follow_up)
            }
        }
        Some(Item::Button(b)) => match b {
            Button::Install => "Installs the EAX fix with the choices above.".into(),
            Button::Apply => "Shows what will change before anything is changed.".into(),
            Button::Uninstall => "Shows what uninstalling removes and puts back.".into(),
            Button::SoundLog if p.sound_log_on => "Stops writing openal.log the next time the game runs.".into(),
            Button::SoundLog => "Writes openal.log in the game's folder the next time it runs, for working out a sound problem.".into(),
            Button::OtherTools => "The VC++ runtime, EAX Unified and the rest of the game's tools.".into(),
            Button::CheckAgain => "Looks at the game's folder and prefix again.".into(),
            _ => String::new(),
        },
        None => String::new(),
    }
}

fn key_line(p: &Panel) -> Line<'static> {
    let keys: &[(&str, &str)] = if p.question.is_some() {
        &[("y", "yes"), ("n", "no")]
    } else if p.list.is_some() {
        &[("↑/↓", "move"), ("Enter", "pick"), ("Esc", "keep")]
    } else if p.running() {
        &[]
    } else if matches!(p.screen, Screen::Run(_)) {
        &[("Enter", "back to the game")]
    } else if matches!(p.screen, Screen::Confirm { .. }) {
        &[("←/→", "move"), ("Enter", "press"), ("Esc", "cancel")]
    } else if matches!(p.screen, Screen::Uninstall(_)) {
        &[
            ("↑/↓", "move"),
            ("Space", "tick"),
            ("Enter", "press"),
            ("Esc", "cancel"),
        ]
    } else {
        &[
            ("↑/↓", "move"),
            ("Tab", "next section"),
            ("Enter", "open"),
            ("Space", "tick"),
            ("Esc", "back"),
            ("F1", "help"),
        ]
    };
    let mut spans = Vec::new();
    for (k, what) in keys {
        spans.push(Span::styled(*k, theme::key()));
        spans.push(Span::raw(format!(" {what}   ")));
    }
    Line::from(spans)
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
        Item::Sound(i) => &p.sound[i],
        Item::Setup(i) => &p.setup[i],
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
    let r = popup(area, w as u16, h);
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
