//! A folder picker for "Add a game": walk the disk to the folder with the
//! game's .exe. Logic only; drawing is in `ui`.

use crate::library;
use std::fs;
use std::path::{Path, PathBuf};

pub struct Picker {
    pub dir: PathBuf,
    /// Sub-folders of `dir`, by name.
    pub dirs: Vec<String>,
    pub selected: usize,
    pub show_hidden: bool,
    /// How many .exe files sit directly in `dir`.
    pub exes: usize,
    home: PathBuf,
}

/// Where the picker opens: the first Steam library's games, else Heroic's
/// games folder, else the home folder.
pub fn start_dir(home: &Path) -> PathBuf {
    for lib in library::steam_library_dirs(home) {
        let common = lib.join("common");
        if common.is_dir() {
            return common;
        }
    }
    let heroic = home.join("Games/Heroic");
    if heroic.is_dir() {
        return heroic;
    }
    home.to_path_buf()
}

impl Picker {
    pub fn new(start: PathBuf, home: PathBuf) -> Self {
        let mut p = Picker {
            dir: start,
            dirs: Vec::new(),
            selected: 0,
            show_hidden: false,
            exes: 0,
            home,
        };
        p.reload();
        p
    }

    fn reload(&mut self) {
        let (mut dirs, mut exes) = (Vec::new(), 0);
        for e in fs::read_dir(&self.dir).into_iter().flatten().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if e.path().is_dir() {
                if self.show_hidden || !name.starts_with('.') {
                    dirs.push(name);
                }
            } else if name.to_lowercase().ends_with(".exe") {
                exes += 1;
            }
        }
        dirs.sort_by_key(|n| n.to_lowercase());
        self.dirs = dirs;
        self.exes = exes;
        self.selected = 0;
    }

    pub fn move_by(&mut self, delta: isize) {
        let last = self.dirs.len().saturating_sub(1) as isize;
        self.selected = (self.selected as isize + delta).clamp(0, last) as usize;
    }

    /// Goes into the highlighted folder.
    pub fn open(&mut self) {
        if let Some(name) = self.dirs.get(self.selected) {
            self.dir = self.dir.join(name);
            self.reload();
        }
    }

    /// Goes to the parent folder, with the one just left highlighted.
    pub fn up(&mut self) {
        let Some(parent) = self.dir.parent().map(Path::to_path_buf) else {
            return;
        };
        let came_from = self
            .dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned());
        self.dir = parent;
        self.reload();
        if let Some(i) = came_from.and_then(|n| self.dirs.iter().position(|d| *d == n)) {
            self.selected = i;
        }
    }

    pub fn go_home(&mut self) {
        self.dir = self.home.clone();
        self.reload();
    }

    pub fn toggle_hidden(&mut self) {
        self.show_hidden = !self.show_hidden;
        let keep = self.dirs.get(self.selected).cloned();
        self.reload();
        if let Some(i) = keep.and_then(|n| self.dirs.iter().position(|d| *d == n)) {
            self.selected = i;
        }
    }

    /// The path for display, with the home folder as `~`.
    pub fn shown_dir(&self) -> String {
        match self.dir.strip_prefix(&self.home) {
            Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
            Ok(rest) => format!("~/{}", rest.display()),
            Err(_) => self.dir.display().to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn world() -> (tempfile::TempDir, Picker) {
        let home = tempfile::tempdir().unwrap();
        for d in [
            "Games/zeta",
            "Games/Alpha",
            "Games/.hidden",
            "Games/Alpha/bin",
        ] {
            fs::create_dir_all(home.path().join(d)).unwrap();
        }
        fs::write(home.path().join("Games/Alpha/game.EXE"), "").unwrap();
        fs::write(home.path().join("Games/Alpha/readme.txt"), "").unwrap();
        let p = Picker::new(home.path().join("Games"), home.path().to_path_buf());
        (home, p)
    }

    #[test]
    fn lists_folders_by_name_without_the_hidden_ones() {
        let (_h, p) = world();
        assert_eq!(p.dirs, ["Alpha", "zeta"]);
    }

    #[test]
    fn hidden_folders_can_be_shown_and_the_highlight_stays_put() {
        let (_h, mut p) = world();
        p.move_by(1);
        p.toggle_hidden();
        assert_eq!(p.dirs, [".hidden", "Alpha", "zeta"]);
        assert_eq!(p.dirs[p.selected], "zeta");
    }

    #[test]
    fn opening_a_folder_counts_its_exes_and_going_up_highlights_where_it_came_from() {
        let (_h, mut p) = world();
        p.open();
        assert!(p.dir.ends_with("Games/Alpha"));
        assert_eq!(
            (p.exes, p.dirs.as_slice()),
            (1, ["bin".to_string()].as_slice())
        );
        p.up();
        assert_eq!(p.dirs[p.selected], "Alpha");
    }

    #[test]
    fn the_selection_stays_inside_the_list() {
        let (_h, mut p) = world();
        p.move_by(-5);
        assert_eq!(p.selected, 0);
        p.move_by(50);
        assert_eq!(p.selected, 1);
    }

    #[test]
    fn an_empty_or_missing_folder_is_an_empty_list() {
        let h = tempfile::tempdir().unwrap();
        let mut p = Picker::new(h.path().join("nope"), h.path().to_path_buf());
        assert!(p.dirs.is_empty());
        p.open();
        p.move_by(1);
        assert_eq!(p.selected, 0);
    }

    #[test]
    fn the_path_is_shown_with_a_tilde() {
        let (_h, mut p) = world();
        assert_eq!(p.shown_dir(), "~/Games");
        p.go_home();
        assert_eq!(p.shown_dir(), "~");
    }

    #[test]
    fn opens_in_the_steam_library_then_heroic_then_home() {
        let h = tempfile::tempdir().unwrap();
        assert_eq!(start_dir(h.path()), h.path());
        fs::create_dir_all(h.path().join("Games/Heroic")).unwrap();
        assert_eq!(start_dir(h.path()), h.path().join("Games/Heroic"));
        fs::create_dir_all(h.path().join(".local/share/Steam/steamapps/common")).unwrap();
        assert!(start_dir(h.path()).ends_with("steamapps/common"));
    }
}
