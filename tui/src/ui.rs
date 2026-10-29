//! Drawing. Reads `App`, never changes it.

use crate::app::{App, Filter, Layout as PaneLayout, Pane};
use crate::filters::Filters;
use crate::games::{Entry, Status};
use crate::help;
use crate::library::StoreKind;
use crate::settings;
use ratatui::layout::Rect;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

pub fn draw(f: &mut Frame, app: &App) {
    if app.zoom {
        // The pane alone, with the key bar under it.
        let rows = Layout::default()
            .direction(Direction::Vertical)
            .constraints([
                Constraint::Min(3),
                Constraint::Length(bar_rows(app, f.area().width)),
            ])
            .split(f.area());
        draw_pane(f, app, rows[0], true);
        draw_bar(f, app, rows[1]);
    } else {
        draw_main(f, app);
    }
    // Popups leave the key bar showing, however many rows it needs.
    let screen = f.area();
    let above_bar = Rect {
        height: screen.height.saturating_sub(bar_rows(app, screen.width)),
        ..screen
    };
    if let (Some(menu), Some(e)) = (&app.menu, app.current()) {
        draw_menu(f, menu, &e.name, above_bar);
    }
    if let Some(p) = &app.picker {
        draw_picker(f, p, above_bar);
    }
    if app.help {
        draw_help(f, app, above_bar);
    }
}

fn draw_main(f: &mut Frame, app: &App) {
    // The filters wrap onto a second line on a narrow terminal.
    let filter_rows = if f.area().width < 100 { 2 } else { 1 };
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Length(3),
            Constraint::Length(filter_rows),
            Constraint::Min(3),
            Constraint::Length(bar_rows(app, f.area().width)),
        ])
        .split(f.area());

    let input = Paragraph::new(format!("> {}", app.query)).block(
        Block::bordered()
            .border_type(BorderType::Rounded)
            .title(format!(
                " Find a game ({}/{}) ",
                app.visible.len(),
                app.games.len()
            )),
    );
    f.render_widget(input, rows[0]);
    f.render_widget(
        Paragraph::new(filter_line(app)).wrap(Wrap { trim: true }),
        rows[1],
    );

    // Beside the list, or under it on a narrow window (or after Ctrl-L).
    let (direction, split) = match app.layout {
        PaneLayout::Side => (Direction::Horizontal, [40, 60]),
        PaneLayout::Stacked => (Direction::Vertical, [45, 55]),
    };
    let panes = Layout::default()
        .direction(direction)
        .constraints(split.map(Constraint::Percentage))
        .split(rows[2]);

    let items: Vec<ListItem> = app
        .visible
        .iter()
        .map(|&i| {
            let e = &app.games[i];
            let (mark, colour) = marker(e.status);
            ListItem::new(Line::from(vec![
                Span::styled(mark, Style::new().fg(colour)),
                Span::raw(" "),
                Span::raw(e.name.as_str()),
            ]))
        })
        .collect();
    let list = List::new(items)
        .block(
            Block::bordered()
                .border_type(BorderType::Rounded)
                .title(" Games "),
        )
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    let mut state = ListState::default().with_selected(app.current().map(|_| app.selected));
    f.render_stateful_widget(list, panes[0], &mut state);

    draw_pane(f, app, panes[1], false);

    draw_bar(f, app, rows[3]);
}

/// The right-hand pane: the profile or the settings. `zoomed` is the full-screen
/// view, where the game's name goes in the title because the list is hidden.
fn draw_pane(f: &mut Frame, app: &App, area: Rect, zoomed: bool) {
    let pane_block = Block::bordered()
        .border_type(BorderType::Rounded)
        .title(pane_title(
            app.pane,
            app.current().filter(|_| zoomed).map(|e| e.name.as_str()),
        ));
    match (app.pane, app.current()) {
        (Pane::Settings, Some(e)) => {
            let inner = pane_block.inner(area);
            let lines = match &e.game {
                Some(g) => settings::lines(g, inner.width as usize),
                None => vec![Line::from(format!(
                    "The game database has no profile for {}.",
                    e.name
                ))],
            };
            let max = lines.len().saturating_sub(inner.height as usize);
            let max = u16::try_from(max).unwrap_or(u16::MAX);
            app.pane_max.set(max);
            let detail = Paragraph::new(lines)
                .scroll((app.pane_scroll.min(max), 0))
                .block(pane_block);
            f.render_widget(detail, area);
        }
        (_, current) => {
            app.pane_max.set(0);
            let lines = match current {
                Some(e) => profile(e),
                None => vec![
                    Line::from("No game matches.").dim(),
                    Line::from("Press Ctrl-A to add a game by its folder.").dim(),
                ],
            };
            let detail = Paragraph::new(lines)
                .wrap(Wrap { trim: false })
                .block(pane_block);
            f.render_widget(detail, area);
        }
    }
}

/// What the bottom bar says for what is on screen.
fn bar_text(app: &App) -> &str {
    if !app.message.is_empty() {
        app.message.as_str()
    } else if app.help {
        "↑/↓ scroll · Esc or F1 close"
    } else if app.picker.is_some() {
        "↑/↓ move · Enter open · ←/Backspace up · Space use this folder · . show hidden folders · ~ home · Esc cancel"
    } else if app.menu.is_some() {
        "↑/↓ choose · Enter run · Esc back"
    } else if app.zoom {
        "↑/↓ scroll · ←/→ Profile/Settings · Enter actions · F1 help · Esc back"
    } else if app.pane == Pane::Settings {
        "Shift-↑/↓ scroll · Ctrl-F full screen · ←/→ Profile/Settings · Enter actions · F1 help · Esc quit"
    } else {
        "Type to filter · Enter actions · ←/→ Profile/Settings · Ctrl-A add game · F1 help · Esc quit"
    }
}

/// Rows the bar needs at this width: one, or two when the text would be cut off.
fn bar_rows(app: &App, width: u16) -> u16 {
    if bar_text(app).chars().count() > usize::from(width) {
        2
    } else {
        1
    }
}

fn draw_bar(f: &mut Frame, app: &App, area: Rect) {
    let text = Paragraph::new(bar_text(app)).wrap(Wrap { trim: true });
    f.render_widget(
        if app.message.is_empty() {
            text.dim()
        } else {
            text.yellow().bold()
        },
        area,
    );
}

/// The F1 key list, over whatever is on screen.
fn draw_help(f: &mut Frame, app: &App, area: Rect) {
    let w = area.width.min(90);
    let h = area.height.saturating_sub(2).max(3).min(area.height);
    let popup = Rect::new(
        area.x + (area.width - w) / 2,
        area.y + (area.height - h) / 2,
        w,
        h,
    );
    f.render_widget(Clear, popup);
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .title(" Keys ");
    let inner = block.inner(popup);
    let lines = help::lines(inner.width as usize);
    let max = u16::try_from(lines.len().saturating_sub(inner.height as usize)).unwrap_or(u16::MAX);
    app.help_max.set(max);
    f.render_widget(
        Paragraph::new(lines)
            .scroll((app.help_scroll.min(max), 0))
            .block(block),
        popup,
    );
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
    let block = Block::bordered()
        .border_type(BorderType::Rounded)
        .title(" Choose the folder with the game's .exe ");
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
        vec![ListItem::new("(no folders here)").dim()]
    } else {
        p.dirs
            .iter()
            .map(|d| ListItem::new(format!("{d}/")))
            .collect()
    };
    let list = List::new(items).highlight_style(Style::new().add_modifier(Modifier::REVERSED));
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
    let w = ((widest + 6).max(title.chars().count() + 4) as u16).min(area.width);
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
        .map(|a| ListItem::new(a.label()))
        .collect();
    let list = List::new(items)
        .block(
            Block::bordered()
                .border_type(BorderType::Rounded)
                .title(format!(" {title} ")),
        )
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    f.render_widget(Clear, popup);
    f.render_stateful_widget(
        list,
        popup,
        &mut ListState::default().with_selected(Some(menu.selected)),
    );
}

/// The pane's title: both views named, the one showing lit.
fn pane_title(active: Pane, game: Option<&str>) -> Line<'static> {
    let name = |text: &'static str, on: bool| {
        if on {
            Span::raw(text).bold().cyan()
        } else {
            Span::raw(text).dim()
        }
    };
    let mut spans = vec![Span::raw(" ")];
    if let Some(game) = game {
        spans.push(Span::raw(format!("{game}: ")).bold());
    }
    spans.extend([
        name("Profile", active == Pane::Profile),
        Span::raw(" | ").dim(),
        name("Settings", active == Pane::Settings),
        Span::raw(" "),
    ]);
    Line::from(spans)
}

/// Each filter with its key and value; one that narrows the list is lit.
fn filter_line(app: &App) -> Line<'static> {
    let d = Filters::default();
    let cells = [
        (
            "Tab",
            "Show",
            app.filter.label().to_string(),
            app.filter != Filter::All,
        ),
        (
            "Ctrl-S",
            "Store",
            app.filters.store.label().to_string(),
            app.filters.store != d.store,
        ),
        (
            "Ctrl-E",
            "Audio",
            app.filters.audio.label(),
            app.filters.audio != d.audio,
        ),
        (
            "Ctrl-T",
            "Tested",
            app.filters.tested.label().to_string(),
            app.filters.tested != d.tested,
        ),
    ];
    let mut spans = Vec::new();
    for (i, (key, name, value, lit)) in cells.into_iter().enumerate() {
        if i > 0 {
            spans.push(Span::raw("  ").dim());
        }
        spans.push(Span::raw(format!("{key} ")).dim());
        spans.push(Span::raw(format!("{name}: ")));
        let v = Span::raw(value);
        spans.push(if lit { v.cyan().bold() } else { v });
    }
    Line::from(spans)
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

fn field(label: &str, value: impl Into<String>) -> Line<'static> {
    Line::from(vec![
        Span::raw(format!("{label}: ")).bold(),
        Span::raw(value.into()),
    ])
}

fn profile(e: &Entry) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(e.name.clone()).bold().cyan(), Line::raw("")];
    let (_, colour) = marker(e.status);
    lines.push(Line::from(vec![
        Span::raw("Status: ").bold(),
        Span::styled(e.status.label(), Style::new().fg(colour)),
    ]));
    if let Some(p) = &e.path {
        let store = match e.store {
            Some(StoreKind::Steam) => " (Steam)",
            Some(StoreKind::Gog) => " (GOG)",
            None => "",
        };
        lines.push(field("Folder", format!("{}{store}", p.display())));
    }
    let Some(g) = &e.game else {
        lines.push(Line::raw(""));
        lines.push(Line::raw(format!(
            "The game database has no profile for {}.",
            e.name
        )));
        return lines;
    };
    if !g.released.is_empty() {
        lines.push(field("Released", g.released.clone()));
    }
    let mut stores = Vec::new();
    if let Some(s) = &g.stores.steam {
        stores.push(format!("Steam {}", s.id));
    }
    if let Some(s) = &g.stores.gog {
        stores.push(format!("GOG {}", s.id));
    }
    if !stores.is_empty() {
        lines.push(field("Stores", stores.join(", ")));
    }
    if !g.eax.api.is_empty() {
        let versions = if g.eax.versions.is_empty() {
            String::new()
        } else {
            format!(" (EAX {})", g.eax.versions.join(", "))
        };
        lines.push(field("Audio", format!("{}{}", g.eax.api, versions)));
    }
    lines.push(field("Tested", if g.tested { "yes" } else { "not yet" }));
    if !g.description.is_empty() {
        lines.push(Line::raw(""));
        lines.push(Line::raw(g.description.clone()));
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
        assert!(s.contains("Find a game (1/1)"));
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
        assert!(before.contains("Profile | Settings"));
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
        let s = screen(&app, 100, 40);
        println!("{s}");
        assert!(s.contains(" Keys "));
        assert!(s.contains("The basics"));
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
        assert!(normal.contains("Find a game"));
        ctrl_key(&mut app, 'f');
        let s = screen(&app, 100, 20);
        println!("{s}");
        assert!(!s.contains(" Games "));
        assert!(!s.contains("Find a game"));
        assert!(s.contains("Quake 4: Profile | Settings"));
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
        assert!(screen(&app, 100, 30).contains(" Keys "));
        press(&mut app, ratatui::crossterm::event::KeyCode::Esc);
        let s = screen(&app, 100, 30);
        assert!(!s.contains(" Keys "));
        assert!(s.contains("Quake 4: Profile | Settings"));
    }

    fn row_of(screen: &str, needle: &str) -> usize {
        screen.lines().position(|l| l.contains(needle)).unwrap()
    }

    #[test]
    fn the_pane_is_beside_the_list_on_a_wide_window_and_under_it_on_a_narrow_one() {
        let mut app = App::new(entries(WITH_SETTINGS));
        app.resize(120);
        let wide = screen(&app, 120, 24);
        assert_eq!(
            row_of(&wide, " Games "),
            row_of(&wide, "Profile | Settings")
        );
        app.resize(90);
        let narrow = screen(&app, 90, 24);
        println!("{narrow}");
        assert!(row_of(&narrow, " Games ") < row_of(&narrow, "Profile | Settings"));
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
        assert!(row_of(&s, " Games ") < row_of(&s, "Profile | Settings"));
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
