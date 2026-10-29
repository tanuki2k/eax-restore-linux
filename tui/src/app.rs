//! Screen state and key handling. No drawing here, so it can be tested.

use crate::games::{Entry, Status};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Matcher, Utf32Str};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

/// What the Tab key cycles the list through.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Filter {
    All,
    OnThisPc,
    Installed,
}

impl Filter {
    pub fn label(self) -> &'static str {
        match self {
            Filter::All => "All games",
            Filter::OnThisPc => "On this PC",
            Filter::Installed => "Installed",
        }
    }

    fn next(self) -> Self {
        match self {
            Filter::All => Filter::OnThisPc,
            Filter::OnThisPc => Filter::Installed,
            Filter::Installed => Filter::All,
        }
    }

    fn allows(self, s: Status) -> bool {
        match self {
            Filter::All => true,
            Filter::OnThisPc => s != Status::NotOnThisPc,
            Filter::Installed => matches!(s, Status::Installed | Status::Manual),
        }
    }
}

pub struct App {
    pub games: Vec<Entry>,
    pub filter: Filter,
    pub query: String,
    /// Indices into `games` that match the query, best match first.
    pub visible: Vec<usize>,
    pub selected: usize,
    pub quit: bool,
    matcher: Matcher,
}

impl App {
    pub fn new(mut games: Vec<Entry>) -> Self {
        games.sort_by_key(|g| g.name.to_lowercase());
        let mut app = App {
            games,
            filter: Filter::All,
            query: String::new(),
            visible: Vec::new(),
            selected: 0,
            quit: false,
            matcher: Matcher::default(),
        };
        app.refilter();
        app
    }

    pub fn current(&self) -> Option<&Entry> {
        self.visible.get(self.selected).map(|&i| &self.games[i])
    }

    fn refilter(&mut self) {
        let allowed: Vec<usize> = (0..self.games.len())
            .filter(|&i| self.filter.allows(self.games[i].status))
            .collect();
        if self.query.trim().is_empty() {
            self.visible = allowed;
        } else {
            let pattern = Pattern::parse(&self.query, CaseMatching::Smart, Normalization::Smart);
            let mut buf = Vec::new();
            let mut scored: Vec<(usize, u32)> = allowed
                .into_iter()
                .filter_map(|i| {
                    pattern
                        .score(Utf32Str::new(&self.games[i].name, &mut buf), &mut self.matcher)
                        .map(|s| (i, s))
                })
                .collect();
            // Equal scores keep the list's name order.
            scored.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            self.visible = scored.into_iter().map(|(i, _)| i).collect();
        }
        self.selected = 0;
    }

    fn move_by(&mut self, delta: isize) {
        let last = self.visible.len().saturating_sub(1) as isize;
        self.selected = (self.selected as isize + delta).clamp(0, last) as usize;
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => self.quit = true,
            KeyCode::Char('c') if ctrl => self.quit = true,
            KeyCode::Tab => {
                self.filter = self.filter.next();
                self.refilter();
            }
            KeyCode::Up => self.move_by(-1),
            KeyCode::Down => self.move_by(1),
            KeyCode::PageUp => self.move_by(-10),
            KeyCode::PageDown => self.move_by(10),
            KeyCode::Home => self.selected = 0,
            KeyCode::End => self.move_by(isize::MAX / 2),
            KeyCode::Backspace => {
                self.query.pop();
                self.refilter();
            }
            KeyCode::Char('u') if ctrl => {
                self.query.clear();
                self.refilter();
            }
            KeyCode::Char(c) if !ctrl => {
                self.query.push(c);
                self.refilter();
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    fn app() -> App {
        let db = Database::parse(
            r#"{"games":[{"id":"b","name":"Beta Quest"},{"id":"a","name":"Alpha Centauri"},
            {"id":"c","name":"Alpha Protocol"}]}"#,
        )
        .unwrap();
        App::new(db.games.into_iter().map(Entry::database_only).collect())
    }

    fn key(c: KeyCode) -> KeyEvent {
        KeyEvent::new(c, KeyModifiers::NONE)
    }

    fn type_str(app: &mut App, s: &str) {
        for c in s.chars() {
            app.handle_key(key(KeyCode::Char(c)));
        }
    }

    #[test]
    fn starts_sorted_by_name() {
        let a = app();
        let names: Vec<_> = a.visible.iter().map(|&i| a.games[i].name.as_str()).collect();
        assert_eq!(names, ["Alpha Centauri", "Alpha Protocol", "Beta Quest"]);
    }

    #[test]
    fn typing_filters_and_backspace_restores() {
        let mut a = app();
        type_str(&mut a, "beta");
        assert_eq!(a.current().unwrap().name, "Beta Quest");
        for _ in 0..4 {
            a.handle_key(key(KeyCode::Backspace));
        }
        assert_eq!(a.visible.len(), 3);
    }

    #[test]
    fn selection_stays_inside_the_list() {
        let mut a = app();
        a.handle_key(key(KeyCode::Up));
        assert_eq!(a.selected, 0);
        a.handle_key(key(KeyCode::End));
        assert_eq!(a.selected, 2);
        a.handle_key(key(KeyCode::Down));
        assert_eq!(a.selected, 2);
    }

    #[test]
    fn no_match_leaves_nothing_selected() {
        let mut a = app();
        type_str(&mut a, "zzzz");
        assert!(a.current().is_none());
        a.handle_key(key(KeyCode::Down));
        assert_eq!(a.selected, 0);
    }

    #[test]
    fn escape_quits() {
        let mut a = app();
        a.handle_key(key(KeyCode::Esc));
        assert!(a.quit);
    }

    #[test]
    fn tab_cycles_the_status_filter() {
        let mut a = app();
        a.games[1].status = Status::OnThisPc;
        a.games[2].status = Status::Installed;
        a.handle_key(key(KeyCode::Tab));
        assert_eq!(a.visible.len(), 2);
        a.handle_key(key(KeyCode::Tab));
        assert_eq!(a.visible, [2]);
        a.handle_key(key(KeyCode::Tab));
        assert_eq!(a.visible.len(), 3);
    }
}
