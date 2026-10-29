//! Screen state and key handling. No drawing here, so it can be tested.

use crate::actions::{self, Action};
use crate::filters::Filters;
use crate::games::{Entry, Status};
use crate::picker::{self, Picker};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Matcher, Utf32Str};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::path::PathBuf;

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

/// What the right-hand pane shows for the selected game.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pane {
    Profile,
    Settings,
}

/// The popup of actions for the selected game.
pub struct Menu {
    pub actions: Vec<Action>,
    pub selected: usize,
}

/// What `main` runs outside the TUI: the environment for the Bash installer.
pub struct Launch {
    pub env: Vec<(&'static str, String)>,
}

pub struct App {
    pub games: Vec<Entry>,
    pub menu: Option<Menu>,
    /// The right pane takes the whole screen (Ctrl-F).
    pub zoom: bool,
    /// The F1 key list is open.
    pub help: bool,
    pub help_scroll: u16,
    /// Like `pane_max`: set by `draw`, since it depends on the terminal's size.
    pub help_max: std::cell::Cell<u16>,
    /// The "Add a game" folder picker, while it is open.
    pub picker: Option<Picker>,
    home: PathBuf,
    pub launch: Option<Launch>,
    /// Shown on the key bar's row until the next key.
    pub message: String,
    pub filter: Filter,
    pub filters: Filters,
    pub pane: Pane,
    /// Lines the settings view is scrolled down.
    pub pane_scroll: u16,
    /// How far it can scroll; known only once it is drawn, so `draw` sets it.
    pub pane_max: std::cell::Cell<u16>,
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
            menu: None,
            zoom: false,
            help: false,
            help_scroll: 0,
            help_max: std::cell::Cell::new(0),
            picker: None,
            home: PathBuf::from("/"),
            launch: None,
            message: String::new(),
            filter: Filter::All,
            filters: Filters::default(),
            pane: Pane::Profile,
            pane_scroll: 0,
            pane_max: std::cell::Cell::new(0),
            query: String::new(),
            visible: Vec::new(),
            selected: 0,
            quit: false,
            matcher: Matcher::default(),
        };
        app.refilter();
        app
    }

    pub fn set_home(&mut self, home: PathBuf) {
        self.home = home;
    }

    /// Puts a fresh scan in place after an action ran, keeping the query, the
    /// filter and, when it is still listed, the selected game.
    pub fn replace_games(&mut self, mut games: Vec<Entry>) {
        let keep = self.current().map(|e| (e.name.clone(), e.path.clone()));
        games.sort_by_key(|g| g.name.to_lowercase());
        self.games = games;
        self.refilter();
        if let Some((name, path)) = keep {
            let same = |e: &Entry| e.name == name && e.path == path;
            if let Some(pos) = self.visible.iter().position(|&i| same(&self.games[i])) {
                self.selected = pos;
            }
        }
    }

    pub fn current(&self) -> Option<&Entry> {
        self.visible.get(self.selected).map(|&i| &self.games[i])
    }

    fn refilter(&mut self) {
        let allowed: Vec<usize> = (0..self.games.len())
            .filter(|&i| {
                self.filter.allows(self.games[i].status) && self.filters.passes(&self.games[i])
            })
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
                        .score(
                            Utf32Str::new(&self.games[i].name, &mut buf),
                            &mut self.matcher,
                        )
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

    fn handle_menu_key(&mut self, key: KeyEvent) {
        let Some(menu) = self.menu.as_mut() else {
            return;
        };
        let last = menu.actions.len().saturating_sub(1);
        match key.code {
            KeyCode::Esc => self.menu = None,
            KeyCode::Up => menu.selected = menu.selected.saturating_sub(1),
            KeyCode::Down => menu.selected = (menu.selected + 1).min(last),
            KeyCode::Enter => {
                let action = menu.actions[menu.selected];
                self.menu = None;
                if let Some(&game) = self.visible.get(self.selected) {
                    self.launch = Some(Launch {
                        env: actions::script_env(&self.games[game], action),
                    });
                }
            }
            _ => {}
        }
    }

    fn handle_picker_key(&mut self, key: KeyEvent) {
        let Some(p) = self.picker.as_mut() else {
            return;
        };
        match key.code {
            KeyCode::Esc => self.picker = None,
            KeyCode::Up => p.move_by(-1),
            KeyCode::Down => p.move_by(1),
            KeyCode::PageUp => p.move_by(-10),
            KeyCode::PageDown => p.move_by(10),
            KeyCode::Enter | KeyCode::Right => p.open(),
            KeyCode::Left | KeyCode::Backspace => p.up(),
            KeyCode::Char('.') => p.toggle_hidden(),
            KeyCode::Char('~') => p.go_home(),
            KeyCode::Char(' ') => {
                let env = vec![
                    ("EAX_RESTORE_ACTION", "install".to_string()),
                    ("EAX_RESTORE_GAME_DIR", p.dir.display().to_string()),
                ];
                self.picker = None;
                self.launch = Some(Launch { env });
            }
            _ => {}
        }
    }

    fn scroll_pane(&mut self, delta: i32) {
        let max = i32::from(self.pane_max.get());
        self.pane_scroll = (i32::from(self.pane_scroll) + delta).clamp(0, max) as u16;
    }

    fn show_pane(&mut self, pane: Pane) {
        self.pane = pane;
        self.pane_scroll = 0;
    }

    /// Moving to another game starts its pane at the top.
    pub fn handle_key(&mut self, key: KeyEvent) {
        let before = self.visible.get(self.selected).copied();
        self.handle_key_inner(key);
        if self.visible.get(self.selected).copied() != before {
            self.pane_scroll = 0;
        }
    }

    fn open_menu(&mut self) {
        if let Some(e) = self.current() {
            self.menu = Some(Menu {
                actions: actions::available(e),
                selected: 0,
            });
        }
    }

    fn open_help(&mut self) {
        self.help = true;
        self.help_scroll = 0;
    }

    fn scroll_help(&mut self, delta: i32) {
        let max = i32::from(self.help_max.get());
        self.help_scroll = (i32::from(self.help_scroll) + delta).clamp(0, max) as u16;
    }

    fn handle_help_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Esc | KeyCode::F(1) | KeyCode::Char('q') => self.help = false,
            KeyCode::Up => self.scroll_help(-1),
            KeyCode::Down => self.scroll_help(1),
            KeyCode::PageUp => self.scroll_help(-10),
            KeyCode::PageDown => self.scroll_help(10),
            KeyCode::Home => self.help_scroll = 0,
            KeyCode::End => self.help_scroll = self.help_max.get(),
            _ => {}
        }
    }

    /// With the right pane full screen there is no list to move through, so
    /// the arrows scroll it, and typing does nothing rather than change a
    /// search nobody can see.
    fn handle_zoom_key(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => self.zoom = false,
            KeyCode::Char('f') if ctrl => self.zoom = false,
            KeyCode::Char('c') if ctrl => self.quit = true,
            KeyCode::F(1) => self.open_help(),
            KeyCode::Up => self.scroll_pane(-1),
            KeyCode::Down => self.scroll_pane(1),
            KeyCode::PageUp => self.scroll_pane(-10),
            KeyCode::PageDown => self.scroll_pane(10),
            KeyCode::Home => self.pane_scroll = 0,
            KeyCode::End => self.pane_scroll = self.pane_max.get(),
            KeyCode::Left => self.show_pane(Pane::Profile),
            KeyCode::Right => self.show_pane(Pane::Settings),
            KeyCode::Enter => self.open_menu(),
            _ => {}
        }
    }

    fn handle_key_inner(&mut self, key: KeyEvent) {
        self.message.clear();
        if self.picker.is_some() {
            return self.handle_picker_key(key);
        }
        if self.menu.is_some() {
            return self.handle_menu_key(key);
        }
        if self.help {
            return self.handle_help_key(key);
        }
        if self.zoom {
            return self.handle_zoom_key(key);
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        match key.code {
            KeyCode::Esc => self.quit = true,
            KeyCode::Char('c') if ctrl => self.quit = true,
            KeyCode::Char('s') if ctrl => {
                self.filters.next_store();
                self.refilter();
            }
            KeyCode::Char('e') if ctrl => {
                self.filters.next_audio();
                self.refilter();
            }
            KeyCode::Char('t') if ctrl => {
                self.filters.next_tested();
                self.refilter();
            }
            KeyCode::Char('a') if ctrl => {
                let start = picker::start_dir(&self.home);
                self.picker = Some(Picker::new(start, self.home.clone()));
            }
            KeyCode::Enter => self.open_menu(),
            KeyCode::F(1) => self.open_help(),
            KeyCode::Char('f') if ctrl => self.zoom = self.current().is_some(),
            KeyCode::Tab => {
                self.filter = self.filter.next();
                self.refilter();
            }
            KeyCode::Up if shift => self.scroll_pane(-1),
            KeyCode::Down if shift => self.scroll_pane(1),
            KeyCode::PageUp if shift => self.scroll_pane(-10),
            KeyCode::PageDown if shift => self.scroll_pane(10),
            KeyCode::Right => self.show_pane(Pane::Settings),
            KeyCode::Left => self.show_pane(Pane::Profile),
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
        let names: Vec<_> = a
            .visible
            .iter()
            .map(|&i| a.games[i].name.as_str())
            .collect();
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

    #[test]
    fn enter_opens_the_menu_and_choosing_an_action_queues_it() {
        let mut a = app();
        a.handle_key(key(KeyCode::Enter));
        assert_eq!(a.menu.as_ref().unwrap().actions, [Action::Install]);
        a.handle_key(key(KeyCode::Enter));
        assert!(a.menu.is_none());
        let l = a.launch.take().unwrap();
        assert!(l
            .env
            .contains(&("EAX_RESTORE_ACTION", "install".to_string())));
    }

    #[test]
    fn escape_closes_the_menu_and_does_not_quit() {
        let mut a = app();
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Esc));
        assert!(a.menu.is_none() && !a.quit && a.launch.is_none());
    }

    #[test]
    fn typing_while_the_menu_is_open_does_not_change_the_filter() {
        let mut a = app();
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Char('z')));
        assert!(a.query.is_empty());
    }

    #[test]
    fn enter_with_nothing_listed_opens_nothing() {
        let mut a = app();
        type_str(&mut a, "zzzz");
        a.handle_key(key(KeyCode::Enter));
        assert!(a.menu.is_none());
    }

    #[test]
    fn a_fresh_scan_keeps_the_query_and_the_selected_game() {
        let mut a = app();
        type_str(&mut a, "alpha");
        a.handle_key(key(KeyCode::Down));
        let mut fresh: Vec<Entry> = a.games.clone();
        fresh[0].status = Status::Installed;
        a.replace_games(fresh);
        assert_eq!(a.query, "alpha");
        assert_eq!(a.current().unwrap().name, "Alpha Protocol");
    }

    fn ctrl(c: char) -> KeyEvent {
        KeyEvent::new(KeyCode::Char(c), KeyModifiers::CONTROL)
    }

    fn app_with_folders() -> (tempfile::TempDir, App) {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join("Games/Heroic/My Game")).unwrap();
        let mut a = app();
        a.set_home(home.path().to_path_buf());
        (home, a)
    }

    #[test]
    fn ctrl_a_opens_the_picker_in_the_games_folder() {
        let (h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        assert_eq!(
            a.picker.as_ref().unwrap().dir,
            h.path().join("Games/Heroic")
        );
    }

    #[test]
    fn space_in_the_picker_starts_an_install_of_that_folder() {
        let (h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        a.handle_key(key(KeyCode::Enter)); // into "My Game"
        a.handle_key(key(KeyCode::Char(' ')));
        assert!(a.picker.is_none());
        let l = a.launch.take().unwrap();
        let dir = h.path().join("Games/Heroic/My Game").display().to_string();
        assert!(l
            .env
            .contains(&("EAX_RESTORE_ACTION", "install".to_string())));
        assert!(l.env.contains(&("EAX_RESTORE_GAME_DIR", dir)));
    }

    #[test]
    fn escape_cancels_the_picker_without_quitting_or_launching() {
        let (_h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        a.handle_key(key(KeyCode::Esc));
        assert!(a.picker.is_none() && !a.quit && a.launch.is_none());
    }

    #[test]
    fn typing_in_the_picker_does_not_reach_the_game_filter() {
        let (_h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        type_str(&mut a, "abc");
        assert!(a.query.is_empty());
    }

    #[test]
    fn ctrl_s_ctrl_e_and_ctrl_t_narrow_the_list() {
        let db = Database::parse(
            r#"{"games":[
            {"id":"a","name":"Alpha","stores":{"steam":{"id":1}},"eax":{"api":"openal","versions":["2.0"]}},
            {"id":"b","name":"Beta","tested":false,"stores":{"gog":{"id":2,"delisted":true}}}]}"#,
        )
        .unwrap();
        let mut a = App::new(db.games.into_iter().map(Entry::database_only).collect());
        a.handle_key(ctrl('s')); // Steam
        assert_eq!(a.visible.len(), 1);
        a.handle_key(ctrl('s')); // GOG
        a.handle_key(ctrl('t')); // Tested
        assert!(a.visible.is_empty());
        a.handle_key(ctrl('t')); // Not yet tested
        assert_eq!(a.current().unwrap().name, "Beta");
        a.handle_key(ctrl('e')); // DirectSound3D
        assert_eq!(a.visible.len(), 1);
        a.handle_key(ctrl('e')); // OpenAL
        assert!(a.visible.is_empty());
    }

    fn shift(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::SHIFT)
    }

    #[test]
    fn right_shows_the_settings_and_left_the_profile() {
        let mut a = app();
        assert_eq!(a.pane, Pane::Profile);
        a.handle_key(key(KeyCode::Right));
        assert_eq!(a.pane, Pane::Settings);
        a.handle_key(key(KeyCode::Left));
        assert_eq!(a.pane, Pane::Profile);
    }

    #[test]
    fn shift_arrows_scroll_the_pane_but_never_past_its_ends() {
        let mut a = app();
        a.pane_max.set(5);
        for _ in 0..9 {
            a.handle_key(shift(KeyCode::Down));
        }
        assert_eq!(a.pane_scroll, 5);
        // No hidden overshoot: one step up moves it at once.
        a.handle_key(shift(KeyCode::Up));
        assert_eq!(a.pane_scroll, 4);
        a.handle_key(shift(KeyCode::PageUp));
        assert_eq!(a.pane_scroll, 0);
        a.handle_key(shift(KeyCode::Up));
        assert_eq!(a.pane_scroll, 0);
    }

    #[test]
    fn plain_arrows_still_move_the_selection_and_only_shift_scrolls() {
        let mut a = app();
        a.pane_max.set(5);
        a.handle_key(key(KeyCode::Down));
        assert_eq!((a.selected, a.pane_scroll), (1, 0));
    }

    #[test]
    fn another_game_starts_at_the_top_of_the_pane() {
        let mut a = app();
        a.pane_max.set(5);
        a.handle_key(shift(KeyCode::Down));
        assert_eq!(a.pane_scroll, 1);
        a.handle_key(key(KeyCode::Down));
        assert_eq!(a.pane_scroll, 0);
    }

    #[test]
    fn switching_panes_starts_at_the_top() {
        let mut a = app();
        a.pane_max.set(5);
        a.handle_key(shift(KeyCode::Down));
        a.handle_key(key(KeyCode::Right));
        assert_eq!(a.pane_scroll, 0);
    }

    #[test]
    fn f1_opens_the_help_and_escape_closes_it_without_quitting() {
        let mut a = app();
        a.handle_key(key(KeyCode::F(1)));
        assert!(a.help);
        a.handle_key(key(KeyCode::Esc));
        assert!(!a.help && !a.quit);
        a.handle_key(key(KeyCode::F(1)));
        a.handle_key(key(KeyCode::F(1)));
        assert!(!a.help, "F1 again closes it");
    }

    #[test]
    fn the_help_scrolls_within_its_length_and_typing_does_not_reach_the_search() {
        let mut a = app();
        a.handle_key(key(KeyCode::F(1)));
        a.help_max.set(4);
        for _ in 0..9 {
            a.handle_key(key(KeyCode::Down));
        }
        assert_eq!(a.help_scroll, 4);
        a.handle_key(key(KeyCode::Up));
        assert_eq!(a.help_scroll, 3);
        a.handle_key(key(KeyCode::Home));
        assert_eq!(a.help_scroll, 0);
        type_str(&mut a, "zz");
        assert!(a.query.is_empty());
    }

    #[test]
    fn ctrl_f_takes_the_pane_full_screen_and_escape_gives_the_list_back() {
        let mut a = app();
        a.handle_key(ctrl('f'));
        assert!(a.zoom);
        a.handle_key(key(KeyCode::Esc));
        assert!(!a.zoom && !a.quit);
        a.handle_key(ctrl('f'));
        a.handle_key(ctrl('f'));
        assert!(!a.zoom, "Ctrl-F again returns");
    }

    #[test]
    fn full_screen_arrows_scroll_the_pane_not_the_selection() {
        let mut a = app();
        a.handle_key(ctrl('f'));
        a.pane_max.set(6);
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Down));
        assert_eq!((a.pane_scroll, a.selected), (2, 0));
        a.handle_key(key(KeyCode::End));
        assert_eq!(a.pane_scroll, 6);
        type_str(&mut a, "zz");
        assert!(a.query.is_empty());
    }

    #[test]
    fn full_screen_still_switches_panes_opens_actions_and_help() {
        let mut a = app();
        a.handle_key(ctrl('f'));
        a.handle_key(key(KeyCode::Right));
        assert_eq!(a.pane, Pane::Settings);
        a.handle_key(key(KeyCode::Enter));
        assert!(a.menu.is_some());
        a.handle_key(key(KeyCode::Esc));
        assert!(a.zoom, "Esc closed only the menu");
        a.handle_key(key(KeyCode::F(1)));
        assert!(a.help);
    }

    #[test]
    fn there_is_nothing_to_show_full_screen_when_nothing_is_listed() {
        let mut a = app();
        type_str(&mut a, "zzzz");
        a.handle_key(ctrl('f'));
        assert!(!a.zoom);
    }
}
