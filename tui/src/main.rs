mod app;
mod db;
mod ui;

use anyhow::Result;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use std::path::PathBuf;

/// Same override the Bash script uses for a local database edit.
fn database_path() -> PathBuf {
    std::env::args_os()
        .nth(1)
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("EAX_RESTORE_GAME_DATABASE_FILE").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("game-database.json"))
}

fn main() -> Result<()> {
    let db = db::Database::load(&database_path())?;
    let mut app = app::App::new(db.games);

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
