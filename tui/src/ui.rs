//! Drawing. Reads `App`, never changes it.

use crate::app::App;
use crate::games::{Entry, Status};
use crate::library::StoreKind;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Color, Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::layout::Rect;
use ratatui::widgets::{Block, BorderType, Clear, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

pub fn draw(f: &mut Frame, app: &App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3), Constraint::Length(1)])
        .split(f.area());

    let input = Paragraph::new(format!("> {}", app.query)).block(
        Block::bordered().border_type(BorderType::Rounded).title(format!(
            " Find a game ({}/{}) · {} ",
            app.visible.len(),
            app.games.len(),
            app.filter.label()
        )),
    );
    f.render_widget(input, rows[0]);

    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(rows[1]);

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
        .block(Block::bordered().border_type(BorderType::Rounded).title(" Games "))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    let mut state = ListState::default().with_selected(app.current().map(|_| app.selected));
    f.render_stateful_widget(list, panes[0], &mut state);

    let detail = Paragraph::new(match app.current() {
        Some(e) => profile(e),
        None => vec![Line::from("No game matches.").dim()],
    })
    .wrap(Wrap { trim: false })
    .block(Block::bordered().border_type(BorderType::Rounded).title(" Profile "));
    f.render_widget(detail, panes[1]);

    let bar = if !app.message.is_empty() {
        Paragraph::new(app.message.as_str()).yellow().bold()
    } else if app.menu.is_some() {
        Paragraph::new("↑/↓ choose · Enter run · Esc back").dim()
    } else {
        Paragraph::new("Type to filter · Enter actions · Tab: all/on this PC/installed · ↑/↓ move · Esc quit").dim()
    };
    f.render_widget(bar, rows[2]);

    if let (Some(menu), Some(e)) = (&app.menu, app.current()) {
        draw_menu(f, menu, &e.name);
    }
}

fn draw_menu(f: &mut Frame, menu: &crate::app::Menu, title: &str) {
    let area = f.area();
    let widest = menu.actions.iter().map(|a| a.label().chars().count()).max().unwrap_or(0);
    let w = ((widest + 6).max(title.chars().count() + 4) as u16).min(area.width);
    let h = (menu.actions.len() as u16 + 2).min(area.height);
    let popup = Rect::new(area.x + (area.width - w) / 2, area.y + (area.height - h) / 2, w, h);
    let items: Vec<ListItem> = menu.actions.iter().map(|a| ListItem::new(a.label())).collect();
    let list = List::new(items)
        .block(Block::bordered().border_type(BorderType::Rounded).title(format!(" {title} ")))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    f.render_widget(Clear, popup);
    f.render_stateful_widget(list, popup, &mut ListState::default().with_selected(Some(menu.selected)));
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
    Line::from(vec![Span::raw(format!("{label}: ")).bold(), Span::raw(value.into())])
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
        lines.push(Line::raw("The game database has no profile for this game."));
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
        Database::parse(json).unwrap().games.into_iter().map(Entry::database_only).collect()
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
        assert!(s.contains("Find a game (1/1) · All games"));
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
        assert!(s.contains("no profile for this game"));
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
        screen(&App::new(entries(r#"{"games":[{"id":"a","name":"Alpha"}]}"#)), 10, 3);
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
}
