//! Screen state and key handling. No drawing here, so it can be tested.

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
            Filter::OnThisPc => "Games on this PC",
            Filter::Installed => "EAX fix installed",
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

/// Where the right-hand pane sits.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layout {
    /// Beside the list.
    Side,
    /// Under the list, for a narrow window.
    Stacked,
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
    pub(crate) home: PathBuf,
    /// Shown on the key bar's row until the next key.
    pub message: String,
    pub filter: Filter,
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
    /// The layout this window width calls for; Ctrl-L swaps away from it.
    natural: Layout,
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
            home: PathBuf::from("/"),
            message: String::new(),
            filter: Filter::All,
            filters: Filters::default(),
            both_stores: Default::default(),
            exes: Default::default(),
            pane: Pane::Profile,
            list_offset: std::cell::Cell::new(0),
            layout: Layout::Side,
            natural: Layout::Side,
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

    /// The Show and Tested filters the player saved on the settings screen.
    pub fn apply_list_prefs(&mut self, p: &crate::prefs::Prefs) {
        use crate::filters::TestedFilter;
        use crate::prefs::{ShowPref, TestedPref};
        self.filter = match p.show {
            ShowPref::All => Filter::All,
            ShowPref::OnThisPc => Filter::OnThisPc,
            ShowPref::Installed => Filter::Installed,
        };
        self.filters.tested = match p.tested {
            TestedPref::Any => TestedFilter::All,
            TestedPref::Tested => TestedFilter::Tested,
            TestedPref::Untested => TestedFilter::Untested,
        };
        self.selected = 0;
        self.refilter();
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
        let natural = if width < STACK_BELOW {
            Layout::Stacked
        } else {
            Layout::Side
        };
        if natural != self.natural {
            self.natural = natural;
            self.layout = natural;
        }
    }

    /// Ctrl-L: away from the layout the window calls for, or back to it.
    fn swap_layout(&mut self) {
        self.layout = if self.layout == self.natural {
            match self.natural {
                Layout::Side => Layout::Stacked,
                Layout::Stacked => Layout::Side,
            }
        } else {
            self.natural
        };
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
    fn open_game(&mut self) {
        let Some(e) = self.current() else { return };
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

    /// Enter, Esc or the arrows while a pop-up shows. Check again looks for
    /// the prefix again: the page opens once it's there, else the pop-up stays.
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
            KeyCode::Enter => self.open_game(),
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
        if let Some(s) = self.prefs.as_mut() {
            let before = (s.prefs.show, s.prefs.tested);
            s.handle_key(key);
            // A changed Show or Tested shows at once; a filter picked with
            // Tab or Ctrl-T stays when only something else changed.
            if (s.prefs.show, s.prefs.tested) != before {
                let p = s.prefs.clone();
                self.apply_list_prefs(&p);
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
            KeyCode::Enter => self.open_game(),
            KeyCode::F(1) => self.open_help(),
            KeyCode::F(2) => self.open_prefs(),
            KeyCode::Char('l') if ctrl => self.swap_layout(),
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
    fn the_saved_show_and_tested_filters_narrow_the_list() {
        use crate::prefs::{Prefs, ShowPref, TestedPref};
        let mut a = app();
        a.games[0].status = Status::Installed; // Alpha Centauri
        a.games[1].status = Status::Installed; // Alpha Protocol
        a.games[0].game.as_mut().unwrap().tested = false;
        a.apply_list_prefs(&Prefs {
            show: ShowPref::Installed,
            tested: TestedPref::Tested,
            ..Prefs::default()
        });
        assert!(a.filter == Filter::Installed);
        assert_eq!(a.current().unwrap().name, "Alpha Protocol");
        assert_eq!(a.visible.len(), 1);
    }

    #[test]
    fn changing_show_in_f2_changes_the_list_but_other_settings_leave_it() {
        let mut a = app();
        // A filter picked with Tab stays while F2 changes the speakers.
        a.handle_key(key(KeyCode::Tab));
        assert!(a.filter == Filter::OnThisPc);
        a.handle_key(key(KeyCode::F(2)));
        for _ in 0..5 {
            a.handle_key(key(KeyCode::Down)); // to Speakers
        }
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Enter));
        assert!(a.filter == Filter::OnThisPc);

        // Show set to EAX fix installed shows at once.
        a.handle_key(key(KeyCode::Home));
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Down));
        a.handle_key(key(KeyCode::Enter));
        a.handle_key(key(KeyCode::Esc));
        assert!(a.prefs.is_none());
        assert!(a.filter == Filter::Installed);
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
    fn enter_on_a_game_not_on_this_pc_asks_for_its_folder_and_esc_does_not_quit() {
        let mut a = app();
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
        type_str(&mut a, "zzzz");
        a.handle_key(key(KeyCode::Enter));
        assert!(a.picker.is_none() && a.panel.is_none() && a.notice.is_none());
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
    fn full_screen_still_switches_panes_opens_games_and_help() {
        let mut a = app();
        a.handle_key(ctrl('f'));
        a.handle_key(key(KeyCode::Right));
        assert_eq!(a.pane, Pane::Settings);
        a.handle_key(key(KeyCode::Enter));
        assert!(a.picker.is_some());
        a.handle_key(key(KeyCode::Esc));
        assert!(a.zoom, "Esc closed only the picker");
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

    #[test]
    fn a_narrow_window_stacks_the_pane_under_the_list_and_a_wide_one_puts_it_beside() {
        let mut a = app();
        assert_eq!(a.layout, Layout::Side);
        a.resize(103);
        assert_eq!(a.layout, Layout::Stacked);
        a.resize(104);
        assert_eq!(a.layout, Layout::Side);
    }

    #[test]
    fn ctrl_l_swaps_away_from_the_natural_layout_and_back() {
        let mut a = app();
        a.resize(120);
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Stacked);
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Side);
        a.resize(80);
        a.handle_key(ctrl('l'));
        assert_eq!(
            a.layout,
            Layout::Side,
            "a narrow window can still be put beside"
        );
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Stacked);
    }

    #[test]
    fn a_choice_stays_through_resizes_on_the_same_side_of_the_line() {
        let mut a = app();
        a.resize(120);
        a.handle_key(ctrl('l'));
        a.resize(150);
        a.resize(110);
        assert_eq!(a.layout, Layout::Stacked);
    }

    #[test]
    fn crossing_the_line_overrides_a_choice() {
        let mut a = app();
        a.resize(120);
        a.handle_key(ctrl('l')); // stacked, though wide
        a.resize(90); // narrow: stacked is now what the window calls for
        assert_eq!(a.layout, Layout::Stacked);
        a.handle_key(ctrl('l')); // beside, though narrow
        a.resize(130); // wide again
        assert_eq!(a.layout, Layout::Side);
    }

    #[test]
    fn ctrl_l_is_ignored_in_full_screen_and_help() {
        let mut a = app();
        a.resize(120);
        a.handle_key(ctrl('f'));
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Side);
        a.handle_key(key(KeyCode::Esc));
        a.handle_key(key(KeyCode::F(1)));
        a.handle_key(ctrl('l'));
        assert_eq!(a.layout, Layout::Side);
    }
}
