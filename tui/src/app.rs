//! Screen state and key handling. No drawing here, so it can be tested.

use crate::filters::{Column, Filters, Item, View};
use crate::games::{Entry, Status};
use crate::picker::{self, Picker};
use nucleo_matcher::pattern::{CaseMatching, Normalization, Pattern};
use nucleo_matcher::{Matcher, Utf32Str};
use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use std::path::PathBuf;

/// The boxes Tab and Shift-Tab move between on the main screen. ↑/↓ always
/// move the games list, whichever has focus; letters type into the search
/// only when it has focus, and elsewhere sort by a column.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Focus {
    /// The view bar: ←/→ pick a view.
    Views,
    /// The search: letters type into it (`/` jumps here).
    Search,
    /// The Filters line: Enter opens the pop-up.
    Filters,
    /// The games list: ↑/↓ move, Enter opens the game.
    Games,
    /// The right pane (list + card layouts only): ←/→ pick profile or settings.
    Card,
}

/// The game details screen (Enter on a game): its profile on the left, its
/// settings on the right, each scrolling on its own. Installing goes on from
/// here.
pub struct Details {
    pub entry: Entry,
    /// Which part has focus: the game details (0), the settings (1) or the
    /// install button (2).
    pub at: u8,
    pub scroll: [u16; 2],
    /// How far each box can scroll; known only once it's drawn.
    pub max: [std::cell::Cell<u16>; 2],
}

impl Details {
    fn new(entry: Entry) -> Self {
        Details {
            entry,
            at: 0,
            scroll: [0, 0],
            max: Default::default(),
        }
    }

    /// The box ↑/↓ scroll: the one with focus, or the settings from the button.
    pub fn scrolled(&self) -> usize {
        usize::from(self.at.min(1))
    }

    fn scroll_by(&mut self, delta: i32) {
        let i = self.scrolled();
        let max = i32::from(self.max[i].get());
        self.scroll[i] = (i32::from(self.scroll[i]) + delta).clamp(0, max) as u16;
    }
}

/// One row of the Filters pop-up.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MenuRow {
    Item(Item),
    ClearAll,
    Done,
}

/// The Filters pop-up while it's open: its rows, the highlighted one, and the
/// filters as they were when it opened, for Esc.
pub struct FilterMenu {
    pub rows: Vec<MenuRow>,
    pub at: usize,
    pub before: Filters,
}

impl FilterMenu {
    fn new(filters: &Filters) -> Self {
        let mut rows: Vec<MenuRow> = Vec::new();
        for (_, items) in crate::filters::groups() {
            rows.extend(items.into_iter().map(MenuRow::Item));
        }
        rows.extend([MenuRow::ClearAll, MenuRow::Done]);
        FilterMenu {
            rows,
            at: 0,
            before: filters.clone(),
        }
    }
}

/// A pop-up in place of a game's page: its name, what to say, and for a
/// game with no prefix yet, a Check again button that tries the page again.
/// The update offer uses it too, with Update and restart in Check again's place.
pub struct Notice {
    pub title: String,
    pub lines: Vec<String>,
    pub retry: Option<Retry>,
    /// The newer build Update and restart installs.
    pub update: Option<u32>,
    /// Check again (or Update and restart) is the highlighted button, rather
    /// than OK (or Later).
    pub on_retry: bool,
}

/// What Check again opens.
pub struct Retry {
    pub dir: PathBuf,
    pub game: Option<crate::db::Game>,
}

/// How the games are laid out (F8 goes round them in this order).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layout {
    /// One table across the screen, a column per detail, no card.
    Table,
    /// The list, with the game's card beside it.
    Side,
    /// The table on top, the game's card under it.
    Stacked,
}

impl Layout {
    fn next(self) -> Self {
        match self {
            Layout::Table => Layout::Side,
            Layout::Side => Layout::Stacked,
            Layout::Stacked => Layout::Table,
        }
    }
}

/// Narrower than this and a pane beside the list leaves both too cramped.
pub const STACK_BELOW: u16 = 104;

/// What the right-hand pane shows for the selected game.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pane {
    Profile,
    Settings,
}

pub struct App {
    pub games: Vec<Entry>,
    /// The open game's page, drawn over the list.
    pub panel: Option<crate::panel::Panel>,
    /// The panel changed something on disk, so the list needs a fresh scan.
    pub rescan: bool,
    /// The right pane takes the whole screen (Ctrl-F).
    pub zoom: bool,
    /// The pop-up for a game with no EAX or no prefix yet, or the update offer.
    pub notice: Option<Notice>,
    /// The update check's answer, while it's on its way.
    pub update_rx: Option<std::sync::mpsc::Receiver<Option<u32>>>,
    /// A newer build, waiting for the screen to be free to offer it.
    pub update_waiting: Option<u32>,
    /// The player chose Update and restart: `main` does it outside the TUI.
    pub update_now: Option<u32>,
    /// The F1 key list is open.
    pub help: bool,
    pub help_scroll: u16,
    /// Like `pane_max`: set by `draw`, since it depends on the terminal's size.
    pub help_max: std::cell::Cell<u16>,
    /// The "Add a game" folder picker, while it is open.
    pub picker: Option<Picker>,
    /// The F2 settings screen, while it is open.
    pub prefs: Option<crate::prefs_screen::PrefsScreen>,
    /// The Filters pop-up (F3), while it is open.
    pub filter_menu: Option<FilterMenu>,
    /// The game details screen, while it is open.
    pub details: Option<Details>,
    /// Which box on the main screen the keys go to.
    pub focus: Focus,
    /// The starred games (F4): database ids, or a folder for a game the
    /// database doesn't list.
    pub favorites: std::collections::BTreeSet<String>,
    pub(crate) home: PathBuf,
    /// Shown on the key bar's row until the next key.
    pub message: String,
    pub view: View,
    pub filters: Filters,
    /// Names on this PC from both Steam and GOG, whose rows say which store.
    /// From every game, not just the listed ones, so the label stays put
    /// whatever the filters hide.
    pub both_stores: std::collections::HashSet<String>,
    /// Each found game's exe, looked up the first time its profile shows,
    /// since the look walks its folder and the pane redraws all the time.
    exes: std::cell::RefCell<std::collections::HashMap<PathBuf, Option<crate::profile::FoundExe>>>,
    pub pane: Pane,
    /// The first row of the games list that is showing, kept between redraws so the
    /// window only moves when the highlight gets near its edge. Set by `draw`.
    pub list_offset: std::cell::Cell<usize>,
    pub layout: Layout,
    /// The window got too narrow for the card beside the list, so it went
    /// under the table; a wide window puts it back beside.
    auto_stacked: bool,
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
            panel: None,
            rescan: false,
            zoom: false,
            notice: None,
            update_rx: None,
            update_waiting: None,
            update_now: None,
            help: false,
            help_scroll: 0,
            help_max: std::cell::Cell::new(0),
            picker: None,
            prefs: None,
            filter_menu: None,
            details: None,
            focus: Focus::Games,
            favorites: Default::default(),
            home: PathBuf::from("/"),
            message: String::new(),
            view: View::All,
            filters: Filters::default(),
            both_stores: Default::default(),
            exes: Default::default(),
            pane: Pane::Profile,
            list_offset: std::cell::Cell::new(0),
            layout: Layout::Side,
            auto_stacked: false,
            pane_scroll: 0,
            pane_max: std::cell::Cell::new(0),
            query: String::new(),
            visible: Vec::new(),
            selected: 0,
            quit: false,
            matcher: Matcher::default(),
        };
        app.find_both_stores();
        app.refilter();
        app
    }

    /// The game's exe, for its profile; None when it isn't on this PC.
    pub fn exe_of(&self, e: &Entry) -> Option<crate::profile::FoundExe> {
        let dir = e
            .path
            .as_ref()
            .filter(|_| e.status != Status::NotOnThisPc)?;
        self.exes
            .borrow_mut()
            .entry(dir.clone())
            .or_insert_with(|| crate::profile::find_exe(dir, e))
            .clone()
    }

    fn find_both_stores(&mut self) {
        let mut seen: std::collections::HashMap<&str, crate::library::StoreKind> =
            Default::default();
        let mut both = std::collections::HashSet::new();
        for e in self
            .games
            .iter()
            .filter(|e| e.status != Status::NotOnThisPc)
        {
            let Some(store) = e.store else { continue };
            match seen.get(e.name.as_str()) {
                Some(s) if *s != store => {
                    both.insert(e.name.clone());
                }
                Some(_) => {}
                None => {
                    seen.insert(&e.name, store);
                }
            }
        }
        self.both_stores = both;
    }

    /// The Show and Compatibility filters the player saved on the settings screen.
    pub fn apply_list_prefs(&mut self, p: &crate::prefs::Prefs) {
        self.view = p.view.view();
        self.favorites = p.favorites.clone();
        self.selected = 0;
        self.refilter();
    }

    /// What a game is starred under: its database id, else its folder.
    pub fn favorite_key(e: &Entry) -> Option<String> {
        match (&e.game, &e.path) {
            (Some(g), _) if !g.id.is_empty() => Some(g.id.clone()),
            (_, Some(p)) => Some(p.display().to_string()),
            _ => None,
        }
    }

    pub fn is_favorite(&self, e: &Entry) -> bool {
        Self::favorite_key(e).is_some_and(|k| self.favorites.contains(&k))
    }

    /// F4: stars the highlighted game, or unstars it, and saves the list.
    /// Tests never write the player's own file.
    fn toggle_favorite(&mut self) {
        if let Some(e) = self.current().cloned() {
            self.toggle_favorite_of(&e);
        }
    }

    fn toggle_favorite_of(&mut self, e: &Entry) {
        let Some(key) = Self::favorite_key(e) else {
            return;
        };
        if !self.favorites.remove(&key) {
            self.favorites.insert(key);
        }
        if !cfg!(test) {
            let mut p = crate::prefs::Prefs::load();
            p.favorites = self.favorites.clone();
            if let Err(e) = p.save() {
                self.message = format!("Couldn't save your favorites: {e}");
            }
        }
        // Unstarring a game in Favorites takes it off the list.
        if self.view == View::Favorites {
            let keep = self.visible.get(self.selected).copied();
            self.refilter_keep(keep);
        }
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
        self.exes.borrow_mut().clear();
        self.find_both_stores();
        self.refilter();
        if let Some((name, path)) = keep {
            let same = |e: &Entry| e.name == name && e.path == path;
            if let Some(pos) = self.visible.iter().position(|&i| same(&self.games[i])) {
                self.selected = pos;
            }
        }
        // The open details screen shows the game as the scan now finds it (an
        // install just done, say).
        if let Some(d) = self.details.as_mut() {
            let (name, store) = (d.entry.name.clone(), d.entry.store);
            let path = d.entry.path.clone();
            if let Some(e) = self
                .games
                .iter()
                .find(|e| e.name == name && e.store == store && (path.is_none() || e.path == path))
            {
                d.entry = e.clone();
            }
        }
    }

    /// Which characters of `name` the search matched, for the list to light up.
    pub fn match_indices(&self, name: &str) -> Vec<u32> {
        if self.query.trim().is_empty() {
            return Vec::new();
        }
        let pattern = Pattern::parse(&self.query, CaseMatching::Smart, Normalization::Smart);
        let (mut buf, mut found) = (Vec::new(), Vec::new());
        let mut matcher = Matcher::default();
        pattern.indices(Utf32Str::new(name, &mut buf), &mut matcher, &mut found);
        found.sort_unstable();
        found.dedup();
        found
    }

    pub fn current(&self) -> Option<&Entry> {
        self.visible.get(self.selected).map(|&i| &self.games[i])
    }

    fn refilter(&mut self) {
        self.refilter_keep(None);
    }

    /// Lists the games the view and filters let through, in the chosen order,
    /// with the highlight on `keep` if it's still listed, else the top.
    fn refilter_keep(&mut self, keep: Option<usize>) {
        let allowed: Vec<usize> = (0..self.games.len())
            .filter(|&i| {
                let e = &self.games[i];
                self.view.allows(e, self.is_favorite(e)) && self.filters.passes(e)
            })
            .collect();
        let mut v: Vec<usize> = if self.query.trim().is_empty() {
            allowed
        } else {
            // The search only narrows the list; the sort order stays.
            let pattern = Pattern::parse(&self.query, CaseMatching::Smart, Normalization::Smart);
            let mut buf = Vec::new();
            allowed
                .into_iter()
                .filter(|&i| {
                    pattern
                        .score(
                            Utf32Str::new(&self.games[i].name, &mut buf),
                            &mut self.matcher,
                        )
                        .is_some()
                })
                .collect()
        };
        let sort = self.filters.sort;
        v.sort_by_cached_key(|&i| crate::filters::sort_key(&self.games[i], sort.column));
        if sort.descending {
            v.reverse();
        }
        self.visible = v;
        self.selected = keep
            .and_then(|k| self.visible.iter().position(|&i| i == k))
            .unwrap_or(0);
    }

    /// The boxes Tab moves between, in order; the card only beside the list.
    fn focus_ring(&self) -> Vec<Focus> {
        let mut ring = vec![Focus::Views, Focus::Search, Focus::Filters, Focus::Games];
        if self.layout != Layout::Table {
            ring.push(Focus::Card);
        }
        ring
    }

    fn move_focus(&mut self, forward: bool) {
        let ring = self.focus_ring();
        let i = ring.iter().position(|f| *f == self.focus).unwrap_or(3);
        let n = ring.len();
        self.focus = ring[if forward {
            (i + 1) % n
        } else {
            (i + n - 1) % n
        }];
    }

    fn set_view(&mut self, view: View) {
        self.view = view;
        self.refilter();
    }

    fn open_filters(&mut self) {
        self.filter_menu = Some(FilterMenu::new(&self.filters));
    }

    /// Keys in the Filters pop-up. Ticks apply as they're made, so the list
    /// behind shows what they do; Esc puts back what was there before.
    fn handle_filter_menu_key(&mut self, key: KeyEvent) {
        let Some(m) = self.filter_menu.as_mut() else {
            return;
        };
        let last = m.rows.len() - 1;
        match key.code {
            KeyCode::Esc => {
                self.filters = m.before.clone();
                self.filter_menu = None;
                self.refilter();
            }
            KeyCode::Up | KeyCode::Left | KeyCode::BackTab => m.at = m.at.saturating_sub(1),
            KeyCode::Down | KeyCode::Right | KeyCode::Tab => m.at = (m.at + 1).min(last),
            KeyCode::Home => m.at = 0,
            KeyCode::End => m.at = last,
            KeyCode::Char(' ') | KeyCode::Enter => {
                let row = m.rows[m.at];
                match row {
                    MenuRow::Item(item) => self.filters.toggle(item),
                    MenuRow::ClearAll => self.filters.ticked.clear(),
                    MenuRow::Done => {}
                }
                // Enter closes, as Done does, except on Clear all; Space only
                // ticks, so several boxes can be ticked in one go.
                if row == MenuRow::Done || (key.code == KeyCode::Enter && row != MenuRow::ClearAll)
                {
                    self.filter_menu = None;
                }
                self.refilter();
            }
            _ => {}
        }
    }

    fn move_by(&mut self, delta: isize) {
        let last = self.visible.len().saturating_sub(1) as isize;
        self.selected = (self.selected as isize + delta).clamp(0, last) as usize;
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
                // The game's page for that folder, with the game's profile when
                // the picker was opened for one.
                let dir = p.dir.clone();
                let game = p.game.take();
                let name = dir
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                self.picker = None;
                self.open_folder(&name, &dir, game);
            }
            _ => {}
        }
    }

    /// The window is now `width` columns wide. Crossing the narrow/wide line
    /// switches the layout by itself, even over a Ctrl-L; otherwise a choice stays.
    pub fn resize(&mut self, width: u16) {
        let narrow = width < STACK_BELOW;
        if narrow && self.layout == Layout::Side {
            self.layout = Layout::Stacked;
            self.auto_stacked = true;
        } else if !narrow && self.auto_stacked {
            self.auto_stacked = false;
            if self.layout == Layout::Stacked {
                self.layout = Layout::Side;
            }
        }
    }

    /// F8: the table, the list beside the card, the table over the card.
    fn next_layout(&mut self) {
        self.layout = self.layout.next();
        self.auto_stacked = false;
        if self.layout == Layout::Table && self.focus == Focus::Card {
            self.focus = Focus::Games;
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

    /// Enter on a game: its page. A game that wasn't found on this PC needs
    /// its folder first, so the folder picker asks for it, unless its profile
    /// says it has no EAX, whose page needs no folder. A game with no EAX or
    /// no prefix yet gets a pop-up instead of the page.
    fn open_details(&mut self) {
        if let Some(e) = self.current() {
            self.details = Some(Details::new(e.clone()));
        }
    }

    /// Keys on the game details screen. Enter goes on to install, change or
    /// uninstall the fix, as the list's Enter used to.
    fn handle_details_key(&mut self, key: KeyEvent) {
        let Some(d) = self.details.as_mut() else {
            return;
        };
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Esc => self.details = None,
            KeyCode::Char('c') if ctrl => self.quit = true,
            KeyCode::F(1) => self.open_help(),
            KeyCode::F(4) => {
                let e = d.entry.clone();
                self.toggle_favorite_of(&e);
            }
            KeyCode::Tab | KeyCode::Right => d.at = (d.at + 1) % 3,
            KeyCode::BackTab | KeyCode::Left => d.at = (d.at + 2) % 3,
            KeyCode::Up => d.scroll_by(-1),
            KeyCode::Down => d.scroll_by(1),
            KeyCode::PageUp => d.scroll_by(-10),
            KeyCode::PageDown => d.scroll_by(10),
            KeyCode::Home => d.scroll[d.scrolled()] = 0,
            KeyCode::End => {
                let i = d.scrolled();
                d.scroll[i] = d.max[i].get();
            }
            KeyCode::Enter => {
                let e = d.entry.clone();
                self.install_game(e);
            }
            _ => {}
        }
    }

    fn install_game(&mut self, e: Entry) {
        let (name, game, path) = (e.name.clone(), e.game.clone(), e.path.clone());
        let store = e.store.map(crate::library::StoreKind::key);
        if let Some(lines) = game
            .as_ref()
            .and_then(|g| crate::cli::no_eax_lines(g, store))
        {
            self.no_eax_notice(&name, lines);
        } else if let Some(dir) = path {
            let panel = self.open_panel(&name, &dir, game);
            self.show_page(panel);
        } else {
            let mut picker = Picker::new(picker::start_dir(&self.home), self.home.clone());
            picker.game = game;
            self.picker = Some(picker);
        }
    }

    /// A game with no EAX to restore opens no page: a pop-up says why.
    fn no_eax_notice(&mut self, title: &str, lines: Vec<String>) {
        self.notice = Some(Notice {
            title: title.to_string(),
            lines,
            retry: None,
            update: None,
            on_retry: false,
        });
    }

    /// Takes the update check's answer, and offers a newer build once
    /// nothing else is open, so it never lands on top of a game's page.
    pub fn poll_update(&mut self) {
        if let Some(rx) = &self.update_rx {
            match rx.try_recv() {
                Ok(found) => {
                    self.update_rx = None;
                    self.update_waiting = found;
                }
                Err(std::sync::mpsc::TryRecvError::Disconnected) => self.update_rx = None,
                Err(std::sync::mpsc::TryRecvError::Empty) => {}
            }
        }
        let free = self.notice.is_none()
            && self.panel.is_none()
            && self.picker.is_none()
            && self.prefs.is_none()
            && !self.help;
        if free {
            if let Some(n) = self.update_waiting.take() {
                self.offer_update(n);
            }
        }
    }

    fn offer_update(&mut self, build: u32) {
        let mine = crate::build_info::number().unwrap_or_default();
        self.notice = Some(Notice {
            title: "New build".into(),
            lines: vec![
                format!("Dev build {build} is out. You're running build {mine}."),
                "Download it and restart with it now?".into(),
            ],
            retry: None,
            update: Some(build),
            on_retry: true,
        });
    }

    /// The update didn't happen: say why and where to get it by hand.
    pub fn update_failed(&mut self, build: u32, why: &crate::update::Failed) {
        let mine = crate::build_info::number().unwrap_or_default();
        let first = match why {
            crate::update::Failed::ReadOnly => {
                "This copy of eax-restore is in a folder it can't write to, so it can't update itself.".to_string()
            }
            crate::update::Failed::Download => format!(
                "The update didn't download, so you're staying on build {mine} for now."
            ),
        };
        self.notice = Some(Notice {
            title: "Not updated".into(),
            lines: vec![
                first,
                format!("You can download build {build} here:"),
                crate::update::RELEASES_PAGE.to_string(),
            ],
            retry: None,
            update: None,
            on_retry: false,
        });
    }

    /// The page for a folder picked by hand. Without a game from the list,
    /// the folder's store ID finds it in the database, as the script looks
    /// a hand-typed folder up.
    fn open_folder(&mut self, name: &str, dir: &std::path::Path, game: Option<crate::db::Game>) {
        let id = crate::engine::identify::identify_game_dir(dir, &self.home);
        let store = id.as_ref().map(|i| i.store.key());
        let game = game.or_else(|| {
            let id = id.as_ref()?;
            let games = self.games.iter().filter_map(|e| e.game.as_ref());
            crate::cli::game_by_store(games, Some(id.store), &id.id).cloned()
        });
        let no_eax = game
            .as_ref()
            .and_then(|g| crate::cli::no_eax_lines(g, store));
        match (game, no_eax) {
            (Some(g), Some(lines)) => self.no_eax_notice(&g.name, lines),
            (game, _) => {
                let panel = self.open_panel(name, dir, game);
                self.show_page(panel);
            }
        }
    }

    /// Before the game's first run, or while it's the Linux version, there's
    /// nothing to choose on its page, so a pop-up says what's in the way.
    fn show_page(&mut self, panel: crate::panel::Panel) {
        if let Some(lines) = panel.gate_lines() {
            self.notice = Some(Notice {
                lines,
                retry: Some(Retry {
                    dir: panel.facts.game_dir.clone(),
                    game: panel.game.clone(),
                }),
                update: None,
                title: panel.name,
                on_retry: true,
            });
        } else {
            self.notice = None;
            self.panel = Some(panel);
        }
    }

    /// Enter, Esc or the arrows while a pop-up shows. Check again looks at the
    /// game again (its prefix, its Windows build, its rolled-back build): the
    /// page opens once nothing's in the way, else the pop-up stays.
    fn handle_notice_key(&mut self, key: KeyEvent) {
        let Some(n) = self.notice.as_mut() else {
            return;
        };
        match key.code {
            KeyCode::Esc => self.notice = None,
            KeyCode::Left | KeyCode::Right | KeyCode::Tab | KeyCode::BackTab
                if n.retry.is_some() || n.update.is_some() =>
            {
                n.on_retry = !n.on_retry;
            }
            KeyCode::Enter if n.update.is_some() => {
                self.update_now = n.update.filter(|_| n.on_retry);
                self.notice = None;
            }
            KeyCode::Enter => match n.retry.take().filter(|_| n.on_retry) {
                Some(r) => {
                    let name = n.title.clone();
                    let panel = self.open_panel(&name, &r.dir, r.game);
                    self.show_page(panel);
                }
                None => self.notice = None,
            },
            _ => {}
        }
    }

    fn open_panel(
        &self,
        name: &str,
        dir: &std::path::Path,
        game: Option<crate::db::Game>,
    ) -> crate::panel::Panel {
        crate::panel::Panel::open(name, dir, game, &self.home)
    }

    /// The settings screen, on what's saved. Tests never read or write the
    /// player's own file.
    fn open_prefs(&mut self) {
        let (prefs, path) = if cfg!(test) {
            (crate::prefs::Prefs::default(), None)
        } else {
            (crate::prefs::Prefs::load(), crate::prefs::path())
        };
        let mut screen = crate::prefs_screen::PrefsScreen::new(prefs, path);
        if !cfg!(test) {
            screen = screen.with_build_lookup(self.home.clone());
        }
        self.prefs = Some(screen);
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
            KeyCode::Enter => {
                self.zoom = false;
                self.open_details();
            }
            _ => {}
        }
    }

    fn handle_panel_key(&mut self, key: KeyEvent) {
        let Some(p) = self.panel.as_mut() else { return };
        p.handle_key(key);
        if p.changed_disk {
            self.rescan = true;
        }
        if p.closed {
            self.panel = None;
        }
    }

    fn handle_key_inner(&mut self, key: KeyEvent) {
        self.message.clear();
        if self.notice.is_some() {
            return self.handle_notice_key(key);
        }
        if self.picker.is_some() {
            return self.handle_picker_key(key);
        }
        if self.filter_menu.is_some() {
            return self.handle_filter_menu_key(key);
        }
        if let Some(s) = self.prefs.as_mut() {
            let before = s.prefs.view;
            s.handle_key(key);
            // A changed View shows at once; a view picked on the bar stays when
            // only something else changed.
            let after = s.prefs.view;
            if after != before {
                self.set_view(after.view());
            }
            if self.prefs.as_ref().is_some_and(|s| s.closed) {
                self.prefs = None;
            }
            return;
        }
        if self.help {
            return self.handle_help_key(key);
        }
        if self.panel.is_some() {
            if key.code == KeyCode::F(1)
                && self
                    .panel
                    .as_ref()
                    .is_some_and(|p| p.list.is_none() && p.question.is_none())
            {
                return self.open_help();
            }
            return self.handle_panel_key(key);
        }
        if self.details.is_some() {
            return self.handle_details_key(key);
        }
        if self.zoom {
            return self.handle_zoom_key(key);
        }
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let shift = key.modifiers.contains(KeyModifiers::SHIFT);
        // In the search, letters, Backspace and Esc are the search's.
        if self.focus == Focus::Search && !ctrl {
            match key.code {
                KeyCode::Char(c) => {
                    self.query.push(c);
                    return self.refilter();
                }
                KeyCode::Backspace => {
                    self.query.pop();
                    return self.refilter();
                }
                // Done typing: on to the games found.
                KeyCode::Esc | KeyCode::Enter => return self.focus = Focus::Games,
                _ => {}
            }
        }
        // Keys that do the same whichever box has focus.
        match key.code {
            KeyCode::Esc | KeyCode::F(10) => return self.quit = true,
            KeyCode::Char('c') if ctrl => return self.quit = true,
            KeyCode::F(1) => return self.open_help(),
            KeyCode::F(2) => return self.open_prefs(),
            KeyCode::F(3) => return self.open_filters(),
            KeyCode::F(4) => return self.toggle_favorite(),
            KeyCode::F(5) => {
                self.rescan = true;
                self.message = "Looking for your games again…".into();
                return;
            }
            KeyCode::F(6) => return self.set_view(self.view.next()),
            KeyCode::F(7) => return self.open_add_picker(),
            KeyCode::F(8) => return self.next_layout(),
            // The table has no pane to enlarge, so its full-screen view of the
            // game is the details screen.
            KeyCode::F(9) if self.layout == Layout::Table => return self.open_details(),
            KeyCode::F(9) => return self.zoom = self.current().is_some(),
            KeyCode::Tab => return self.move_focus(true),
            KeyCode::BackTab => return self.move_focus(false),
            KeyCode::Char('/') => return self.focus = Focus::Search,
            // The keys the old browser used, kept for whoever knows them.
            KeyCode::Char('a') if ctrl => return self.open_add_picker(),
            KeyCode::Char('f') if ctrl => {
                return self.zoom = self.current().is_some() && self.layout != Layout::Table
            }
            KeyCode::Up if shift => return self.scroll_pane(-1),
            KeyCode::Down if shift => return self.scroll_pane(1),
            KeyCode::PageUp if shift => return self.scroll_pane(-10),
            KeyCode::PageDown if shift => return self.scroll_pane(10),
            KeyCode::Char('u') if ctrl => {
                self.query.clear();
                return self.refilter();
            }
            // A column's first letter sorts by it; again, the other way round.
            KeyCode::Char(c) if !ctrl => {
                if let Some(col) = Column::for_key(c) {
                    let keep = self.visible.get(self.selected).copied();
                    self.filters.sort.press(col);
                    self.refilter_keep(keep);
                }
                return;
            }
            // ↑/↓ and the page keys move the games list from any box.
            KeyCode::Up => return self.move_by(-1),
            KeyCode::Down => return self.move_by(1),
            KeyCode::PageUp => return self.move_by(-10),
            KeyCode::PageDown => return self.move_by(10),
            KeyCode::Home => return self.selected = 0,
            KeyCode::End => return self.move_by(isize::MAX / 2),
            _ => {}
        }
        // Keys for the box with focus.
        match (self.focus, key.code) {
            (Focus::Views, KeyCode::Left) => self.set_view(self.view.prev()),
            (Focus::Views, KeyCode::Right) => self.set_view(self.view.next()),
            (Focus::Filters, KeyCode::Enter) => self.open_filters(),
            (Focus::Games | Focus::Card, KeyCode::Right) => self.show_pane(Pane::Settings),
            (Focus::Games | Focus::Card, KeyCode::Left) => self.show_pane(Pane::Profile),
            (_, KeyCode::Enter) => self.open_details(),
            _ => {}
        }
    }

    /// F7 (and Ctrl-A): the folder picker, for a game that isn't listed.
    fn open_add_picker(&mut self) {
        let start = picker::start_dir(&self.home);
        self.picker = Some(Picker::new(start, self.home.clone()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;

    #[test]
    fn f2_opens_the_settings_and_esc_comes_back_to_the_list() {
        let mut a = app();
        a.handle_key(key(KeyCode::F(2)));
        assert!(a.prefs.is_some());
        // Typing there doesn't reach the search.
        a.handle_key(key(KeyCode::Char('x')));
        assert!(a.query.is_empty());
        a.handle_key(key(KeyCode::Esc));
        assert!(a.prefs.is_none() && !a.quit);
    }

    #[test]
    fn the_saved_view_and_favorites_narrow_the_list() {
        use crate::prefs::{Prefs, ViewPref};
        let mut a = app();
        a.games[0].status = Status::Installed; // Alpha Centauri
        a.games[1].status = Status::Installed; // Alpha Protocol
        a.apply_list_prefs(&Prefs {
            view: ViewPref::Patched,
            ..Prefs::default()
        });
        assert!(a.view == View::Patched);
        assert_eq!(a.visible.len(), 2);
        a.apply_list_prefs(&Prefs {
            view: ViewPref::Favorites,
            favorites: ["c".to_string()].into(),
            ..Prefs::default()
        });
        assert_eq!(a.current().unwrap().name, "Alpha Protocol");
        assert_eq!(a.visible.len(), 1);
    }

    #[test]
    fn changing_the_view_in_f2_changes_the_list_but_other_settings_leave_it() {
        let mut a = app();
        // A view picked with F6 stays while F2 changes the speakers.
        a.handle_key(key(KeyCode::F(6)));
        assert!(a.view == View::MyLibrary);
        a.handle_key(key(KeyCode::F(2)));
        for _ in 0..4 {
            a.handle_key(key(KeyCode::Down)); // to Speakers
        }
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Enter));
        assert!(a.view == View::MyLibrary);

        // View set to Patched shows at once.
        a.handle_key(key(KeyCode::Home));
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Esc));
        assert!(a.prefs.is_none());
        assert!(a.view == View::Patched);
        assert!(a.visible.is_empty());
    }

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

    /// `/` to the search, then the text.
    fn search(app: &mut App, s: &str) {
        app.handle_key(key(KeyCode::Char('/')));
        type_str(app, s);
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
        search(&mut a, "beta");
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
        search(&mut a, "zzzz");
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
    fn f6_cycles_the_views_and_the_view_bar_takes_the_arrows() {
        let mut a = app();
        a.games[1].status = Status::OnThisPc;
        a.games[2].status = Status::Installed;
        a.handle_key(key(KeyCode::F(6))); // My library
        assert_eq!(a.visible.len(), 2);
        a.handle_key(key(KeyCode::F(6))); // Patched
        assert_eq!(a.visible, [2]);
        a.handle_key(key(KeyCode::F(6))); // Favorites
        assert!(a.visible.is_empty());
        a.handle_key(key(KeyCode::F(6))); // All games
        assert_eq!(a.visible.len(), 3);
        // From the list, Shift-Tab three times reaches the view bar, where ←
        // and → pick the view.
        for _ in 0..3 {
            a.handle_key(key(KeyCode::BackTab));
        }
        assert_eq!(a.focus, Focus::Views);
        a.handle_key(key(KeyCode::Right));
        assert!(a.view == View::MyLibrary);
        a.handle_key(key(KeyCode::Left));
        a.handle_key(key(KeyCode::Left));
        assert!(a.view == View::Favorites);
    }

    #[test]
    fn tab_goes_round_the_boxes_and_skips_the_card_in_the_table() {
        let mut a = app();
        assert_eq!(a.focus, Focus::Games);
        let mut seen = Vec::new();
        for _ in 0..5 {
            a.handle_key(key(KeyCode::Tab));
            seen.push(a.focus);
        }
        assert_eq!(
            seen,
            [
                Focus::Card,
                Focus::Views,
                Focus::Search,
                Focus::Filters,
                Focus::Games
            ]
        );
        a.handle_key(key(KeyCode::Tab)); // Card
        a.handle_key(key(KeyCode::F(8))); // the list over the card
        a.handle_key(key(KeyCode::F(8))); // the table: no card to stay on
        assert!(a.layout == Layout::Table && a.focus == Focus::Games);
        a.handle_key(key(KeyCode::F(9)));
        assert!(
            a.details.is_some() && !a.zoom,
            "F9 in the table opens the details"
        );
        a.handle_key(key(KeyCode::Esc));
        a.handle_key(key(KeyCode::Tab));
        assert_eq!(a.focus, Focus::Views);
        // Letters sort there; only the search box takes them as text.
        a.handle_key(key(KeyCode::Char('p')));
        assert!(a.query.is_empty());
    }

    #[test]
    fn f4_stars_a_game_and_favorites_lists_it() {
        let mut a = app();
        a.handle_key(key(KeyCode::Down)); // Alpha Protocol
        a.handle_key(key(KeyCode::F(4)));
        assert!(a.favorites.contains("c"));
        a.set_view(View::Favorites);
        assert_eq!(a.current().unwrap().name, "Alpha Protocol");
        // Unstarring it in Favorites takes it off the list.
        a.handle_key(key(KeyCode::F(4)));
        assert!(a.visible.is_empty() && a.favorites.is_empty());
    }

    #[test]
    fn enter_on_a_game_not_on_this_pc_asks_for_its_folder_and_esc_does_not_quit() {
        let mut a = app();
        // Enter opens the game's details; Enter there goes on to install.
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Enter));
        assert!(a.picker.is_some());
        a.handle_key(key(KeyCode::Char('z')));
        assert!(
            a.query.is_empty(),
            "typing in the picker stays out of the filter"
        );
        a.handle_key(key(KeyCode::Esc));
        assert!(a.picker.is_none() && !a.quit);
    }

    #[test]
    fn enter_with_nothing_listed_opens_nothing() {
        let mut a = app();
        search(&mut a, "zzzz");
        a.handle_key(key(KeyCode::Enter));
        assert!(a.picker.is_none() && a.panel.is_none() && a.notice.is_none());
    }

    #[test]
    fn a_fresh_scan_keeps_the_query_and_the_selected_game() {
        let mut a = app();
        search(&mut a, "alpha");
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

    #[test]
    fn a_newer_build_is_offered_once_the_screen_is_free() {
        let mut a = app();
        let (tx, rx) = std::sync::mpsc::channel();
        a.update_rx = Some(rx);
        a.help = true;
        tx.send(Some(9999)).unwrap();
        a.poll_update();
        // F1's list is open, so the offer waits.
        assert!(a.notice.is_none() && a.update_rx.is_none());
        assert_eq!(a.update_waiting, Some(9999));
        a.help = false;
        a.poll_update();
        let n = a.notice.as_ref().unwrap();
        assert_eq!(n.update, Some(9999));
        assert!(n.lines[0].starts_with("Dev build 9999 is out."));

        // Later closes it and does nothing.
        a.handle_key(key(KeyCode::Right));
        a.handle_key(key(KeyCode::Enter));
        assert!(a.notice.is_none() && a.update_now.is_none());

        a.update_waiting = Some(9999);
        a.poll_update();
        a.handle_key(key(KeyCode::Enter));
        assert_eq!(a.update_now, Some(9999));
    }

    #[test]
    fn no_answer_means_no_offer() {
        let mut a = app();
        let (tx, rx) = std::sync::mpsc::channel();
        a.update_rx = Some(rx);
        tx.send(None).unwrap();
        a.poll_update();
        assert!(a.notice.is_none() && a.update_waiting.is_none() && a.update_rx.is_none());
    }

    fn app_with_folders() -> (tempfile::TempDir, App) {
        let home = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(home.path().join("Games/Heroic/My Game")).unwrap();
        let mut a = app();
        a.set_home(home.path().to_path_buf());
        (home, a)
    }

    #[test]
    fn a_folder_picked_by_hand_finds_its_game_in_the_database() {
        let db = Database::parse(
            r#"{"games":[{"id":"a","name":"Never Had It","stores":{"steam":{"id":11}},"eax":{"status":"not_implemented"}},
               {"id":"b","name":"Has It","stores":{"steam":{"id":22}}}]}"#,
        )
        .unwrap();
        let mut a = App::new(db.games.into_iter().map(Entry::database_only).collect());
        let home = tempfile::tempdir().unwrap();
        a.set_home(home.path().to_path_buf());
        let steam = home.path().join("Steam/steamapps");
        for (id, dir) in [(11, "Never"), (22, "Has")] {
            std::fs::create_dir_all(steam.join("common").join(dir)).unwrap();
            std::fs::create_dir_all(steam.join(format!("compatdata/{id}/pfx/drive_c"))).unwrap();
            std::fs::write(
                steam.join(format!("appmanifest_{id}.acf")),
                format!("\"AppState\"\n{{\n\t\"appid\"\t\t\"{id}\"\n\t\"installdir\"\t\t\"{dir}\"\n}}\n"),
            )
            .unwrap();
        }
        a.open_folder("Has", &steam.join("common/Has"), None);
        assert_eq!(a.panel.take().unwrap().game.unwrap().name, "Has It");
        // One with no EAX gets the pop-up, as from the list.
        a.open_folder("Never", &steam.join("common/Never"), None);
        assert!(a.panel.is_none());
        assert_eq!(a.notice.as_ref().unwrap().title, "Never Had It");
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
    fn escape_cancels_the_picker_without_quitting_or_launching() {
        let (_h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        a.handle_key(key(KeyCode::Esc));
        assert!(a.picker.is_none() && !a.quit && a.panel.is_none());
    }

    #[test]
    fn typing_in_the_picker_does_not_reach_the_game_filter() {
        let (_h, mut a) = app_with_folders();
        a.handle_key(ctrl('a'));
        type_str(&mut a, "abc");
        assert!(a.query.is_empty());
    }

    #[test]
    fn the_filters_pop_up_ticks_boxes_and_esc_puts_them_back() {
        let db = Database::parse(
            r#"{"games":[
            {"id":"a","name":"Alpha","stores":{"steam":{"id":1}},"eax":{"api":"openal","versions":["2.0"]}},
            {"id":"b","name":"Beta","tested":false,"stores":{"gog":{"id":2,"delisted":true}}}]}"#,
        )
        .unwrap();
        let mut a = App::new(db.games.into_iter().map(Entry::database_only).collect());
        let row = |a: &App, r: MenuRow| {
            a.filter_menu
                .as_ref()
                .unwrap()
                .rows
                .iter()
                .position(|x| *x == r)
                .unwrap()
        };
        let go = |a: &mut App, r: MenuRow| {
            let at = row(a, r);
            a.handle_key(key(KeyCode::Home));
            for _ in 0..at {
                a.handle_key(key(KeyCode::Down));
            }
        };
        a.handle_key(key(KeyCode::F(3)));
        go(&mut a, MenuRow::Item(Item::Gog));
        a.handle_key(key(KeyCode::Char(' ')));
        assert_eq!(a.current().unwrap().name, "Beta");
        // Space ticks without closing; a second box in another group narrows.
        go(
            &mut a,
            MenuRow::Item(Item::Compat(crate::db::Compat::Verified)),
        );
        a.handle_key(key(KeyCode::Char(' ')));
        assert!(a.visible.is_empty());
        // Esc puts the filters back as they were.
        a.handle_key(key(KeyCode::Esc));
        assert!(a.filter_menu.is_none() && a.filters.is_clear());
        assert_eq!(a.visible.len(), 2);
        // Enter on a box ticks it and closes.
        a.handle_key(key(KeyCode::F(3)));
        go(&mut a, MenuRow::Item(Item::OpenAl));
        a.handle_key(key(KeyCode::Enter));
        assert!(a.filter_menu.is_none());
        assert_eq!(a.current().unwrap().name, "Alpha");
        // The Filters box opens it with Enter too.
        a.handle_key(key(KeyCode::BackTab));
        assert_eq!(a.focus, Focus::Filters);
        a.handle_key(key(KeyCode::Enter));
        go(&mut a, MenuRow::ClearAll);
        a.handle_key(key(KeyCode::Enter));
        assert!(a.filter_menu.is_some() && a.filters.is_clear());
        a.handle_key(key(KeyCode::Esc));
    }

    #[test]
    fn a_columns_letter_sorts_by_it_and_again_the_other_way() {
        let db = Database::parse(
            r#"{"games":[
            {"id":"a","name":"Alpha","released":"2005","stores":{"steam":{"id":1,"compatibility":"unknown"}}},
            {"id":"b","name":"Beta","released":"1999","stores":{"steam":{"id":2,"compatibility":"verified"}}}]}"#,
        )
        .unwrap();
        let mut a = App::new(db.games.into_iter().map(Entry::database_only).collect());
        let names = |a: &App| {
            a.visible
                .iter()
                .map(|&i| a.games[i].name.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(names(&a), ["Alpha", "Beta"], "Name ▲ to start");
        type_str(&mut a, "c"); // Compatibility: Verified first
        assert_eq!(names(&a), ["Beta", "Alpha"]);
        type_str(&mut a, "c"); // again: the other way round
        assert_eq!(names(&a), ["Alpha", "Beta"]);
        assert!(a.filters.sort.descending);
        type_str(&mut a, "y"); // Year, oldest first
        assert_eq!(names(&a), ["Beta", "Alpha"]);
        assert!(a.query.is_empty(), "letters sort; they don't search");
        // A letter that's no column's does nothing.
        type_str(&mut a, "q");
        assert_eq!(names(&a), ["Beta", "Alpha"]);
    }

    #[test]
    fn slash_jumps_to_the_search_where_letters_type_and_enter_goes_back_to_the_games() {
        let mut a = app();
        type_str(&mut a, "/");
        assert_eq!(a.focus, Focus::Search);
        type_str(&mut a, "proto");
        assert_eq!(a.query, "proto");
        assert_eq!(a.current().unwrap().name, "Alpha Protocol");
        a.handle_key(key(KeyCode::Enter));
        assert_eq!(a.focus, Focus::Games);
        // Esc in the search goes back to the games too, rather than quitting.
        type_str(&mut a, "/");
        a.handle_key(key(KeyCode::Esc));
        assert!(!a.quit && a.focus == Focus::Games);
        // The search is a Tab stop, after the views.
        a.handle_key(key(KeyCode::BackTab));
        a.handle_key(key(KeyCode::BackTab));
        assert_eq!(a.focus, Focus::Search);
    }

    #[test]
    fn enter_on_the_view_bar_opens_the_game_and_the_arrows_always_move_the_list() {
        let mut a = app();
        a.handle_key(key(KeyCode::BackTab)); // Filters
        a.handle_key(key(KeyCode::BackTab)); // Search
        a.handle_key(key(KeyCode::BackTab)); // Views
        assert_eq!(a.focus, Focus::Views);
        a.handle_key(key(KeyCode::Down));
        assert_eq!(a.selected, 1, "↓ moves the list from the view bar");
        a.handle_key(key(KeyCode::Enter));
        assert!(a.details.is_some());
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
    fn full_screen_still_switches_panes_opens_games_and_help() {
        let mut a = app();
        a.handle_key(ctrl('f'));
        a.handle_key(key(KeyCode::Right));
        assert_eq!(a.pane, Pane::Settings);
        // Enter opens the game's details, and Enter there asks for its folder.
        a.handle_key(key(KeyCode::Enter));
        assert!(a.details.is_some() && !a.zoom);
        a.handle_key(key(KeyCode::Enter));
        assert!(a.picker.is_some());
        a.handle_key(key(KeyCode::Esc));
        assert!(a.details.is_some(), "Esc closed only the picker");
        a.handle_key(key(KeyCode::F(1)));
        assert!(a.help);
    }

    #[test]
    fn there_is_nothing_to_show_full_screen_when_nothing_is_listed() {
        let mut a = app();
        search(&mut a, "zzzz");
        a.handle_key(ctrl('f'));
        assert!(!a.zoom);
    }

    #[test]
    fn a_narrow_window_stacks_the_card_under_the_table_and_a_wide_one_puts_it_beside() {
        let mut a = app();
        assert_eq!(a.layout, Layout::Side);
        a.resize(103);
        assert_eq!(a.layout, Layout::Stacked);
        a.resize(104);
        assert_eq!(a.layout, Layout::Side);
    }

    #[test]
    fn f8_goes_round_the_table_the_two_columns_and_top_and_bottom() {
        let mut a = app();
        a.resize(120);
        a.handle_key(key(KeyCode::F(8)));
        assert_eq!(a.layout, Layout::Stacked);
        a.handle_key(key(KeyCode::F(8)));
        assert_eq!(a.layout, Layout::Table);
        a.handle_key(key(KeyCode::F(8)));
        assert_eq!(a.layout, Layout::Side);
        // A layout picked with F8 stays through resizes; only the one the
        // window forced goes back.
        a.handle_key(key(KeyCode::F(8))); // top and bottom, chosen
        a.resize(150);
        assert_eq!(a.layout, Layout::Stacked);
        a.handle_key(key(KeyCode::F(8)));
        a.handle_key(key(KeyCode::F(8))); // beside, chosen
        a.resize(90); // too narrow: it goes under
        a.resize(130); // wide again: back beside
        assert_eq!(a.layout, Layout::Side);
        // Ctrl-L does nothing any more.
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Side);
    }
}
