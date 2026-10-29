//! Drawing. Reads `App`, never changes it.

use crate::app::App;
use crate::db::Game;
use ratatui::layout::{Constraint, Direction, Layout};
use ratatui::style::{Modifier, Style, Stylize};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;

pub fn draw(f: &mut Frame, app: &App) {
    let rows = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(3), Constraint::Length(1)])
        .split(f.area());

    let input = Paragraph::new(format!("> {}", app.query)).block(
        Block::bordered()
            .border_type(BorderType::Rounded)
            .title(format!(" Find a game ({}/{}) ", app.visible.len(), app.games.len())),
    );
    f.render_widget(input, rows[0]);

    let panes = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(40), Constraint::Percentage(60)])
        .split(rows[1]);

    let items: Vec<ListItem> = app
        .visible
        .iter()
        .map(|&i| ListItem::new(app.games[i].name.as_str()))
        .collect();
    let list = List::new(items)
        .block(Block::bordered().border_type(BorderType::Rounded).title(" Games "))
        .highlight_style(Style::new().add_modifier(Modifier::REVERSED));
    let mut state = ListState::default().with_selected(app.current().map(|_| app.selected));
    f.render_stateful_widget(list, panes[0], &mut state);

    let detail = Paragraph::new(match app.current() {
        Some(game) => profile(game),
        None => vec![Line::from("No game matches.").dim()],
    })
    .wrap(Wrap { trim: false })
    .block(Block::bordered().border_type(BorderType::Rounded).title(" Profile "));
    f.render_widget(detail, panes[1]);

    f.render_widget(
        Paragraph::new("Type to filter · ↑/↓ PgUp/PgDn move · Ctrl-U clear · Esc quit").dim(),
        rows[2],
    );
}

fn field(label: &str, value: impl Into<String>) -> Line<'static> {
    Line::from(vec![
        Span::raw(format!("{label}: ")).bold(),
        Span::raw(value.into()),
    ])
}

fn profile(g: &Game) -> Vec<Line<'static>> {
    let mut lines = vec![Line::from(g.name.clone()).bold().cyan(), Line::raw("")];
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
    fn shows_the_list_and_the_selected_games_profile() {
        let db = Database::parse(
            r#"{"games":[{"id":"a","name":"Alpha Centauri","released":"1999-02-09",
            "stores":{"steam":{"id":2204130}},"eax":{"api":"directsound3d","versions":["1.0"]}}]}"#,
        )
        .unwrap();
        let s = screen(&App::new(db.games), 100, 14);
        println!("{s}");
        assert!(s.contains("Find a game (1/1)"));
        assert!(s.contains("Alpha Centauri"));
        assert!(s.contains("Steam 2204130"));
        assert!(s.contains("directsound3d (EAX 1.0)"));
    }

    #[test]
    fn an_empty_result_says_so_and_does_not_panic() {
        let db = Database::parse(r#"{"games":[{"id":"a","name":"Alpha"}]}"#).unwrap();
        let mut app = App::new(db.games);
        app.query = "zzz".into();
        app.visible.clear();
        assert!(screen(&app, 60, 10).contains("No game matches."));
    }

    #[test]
    fn a_tiny_terminal_does_not_panic() {
        let db = Database::parse(r#"{"games":[{"id":"a","name":"Alpha"}]}"#).unwrap();
        screen(&App::new(db.games), 10, 3);
    }
}
