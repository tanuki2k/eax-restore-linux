mod app;
mod db;
mod games;
mod library;
mod ui;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use std::path::PathBuf;

/// Same override the Bash script uses for a local database edit.
fn database_path() -> PathBuf {
    std::env::args_os()
        .skip(1)
        .find(|a| !a.to_string_lossy().starts_with("--"))
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("EAX_RESTORE_GAME_DATABASE_FILE").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("game-database.json"))
}

fn main() -> Result<()> {
    let db = db::Database::load(&database_path())?;
    let home = PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?);
    let entries = games::build(&db, &home);

    // `--list` prints the list and exits, for scripts and quick checks.
    if std::env::args().any(|a| a == "--list") {
        let mut entries = entries;
        entries.sort_by_key(|e| e.name.to_lowercase());
        for e in entries.iter().filter(|e| e.status != games::Status::NotOnThisPc) {
            let path = e.path.as_ref().map_or_else(String::new, |p| p.display().to_string());
            println!("{:<10} {}\t{}", format!("{:?}", e.status), e.name, path);
        }
        return Ok(());
    }

    let mut app = app::App::new(entries);

    // init() also installs a panic hook that puts the terminal back.
    let mut terminal = ratatui::init();
    let result = (|| -> Result<()> {
        while !app.quit {
            terminal.draw(|f| ui::draw(f, &app))?;
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    app.handle_key(key);
                }
            }
        }
        Ok(())
    })();
    ratatui::restore();
    result
}
