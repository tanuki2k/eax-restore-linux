mod actions;
mod app;
mod db;
mod fetch;
mod filters;
mod games;
mod help;
mod library;
mod picker;
mod runner;
mod settings;
mod theme;
mod ui;

use anyhow::{Context, Result};
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use std::io::Write;
use std::path::PathBuf;

/// A database named on the command line or by the same variable the Bash
/// script uses for a local edit.
fn chosen_database() -> Option<PathBuf> {
    // The first argument that is neither a flag nor a flag's value.
    let mut args = std::env::args_os().skip(1);
    let mut positional = None;
    while let Some(a) = args.next() {
        if a == "--settings" {
            args.next();
        } else if !a.to_string_lossy().starts_with("--") {
            positional = Some(a);
            break;
        }
    }
    positional
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("EAX_RESTORE_GAME_DATABASE_FILE").map(PathBuf::from))
}

fn main() -> Result<()> {
    // The script runs from another folder, so a chosen path must be absolute.
    let chosen = chosen_database().map(|p| std::fs::canonicalize(&p).unwrap_or(p));
    let db_path = match &chosen {
        Some(p) => p.clone(),
        None => fetch::ensure_database()?,
    };
    let db = db::Database::load(&db_path)?;
    let home = PathBuf::from(std::env::var_os("HOME").context("HOME is not set")?);
    let state_file = library::installed_games_file(&home);
    let entries = games::build(&db, &home, &state_file);

    // `--list` prints the list and exits, for scripts and quick checks.
    if std::env::args().any(|a| a == "--list") {
        let mut entries = entries;
        entries.sort_by_key(|e| e.name.to_lowercase());
        for e in entries
            .iter()
            .filter(|e| e.status != games::Status::NotOnThisPc)
        {
            let path = e
                .path
                .as_ref()
                .map_or_else(String::new, |p| p.display().to_string());
            let row = format!("{:<10} {}\t{}", format!("{:?}", e.status), e.name, path);
            if writeln!(std::io::stdout(), "{row}").is_err() {
                break;
            }
        }
        return Ok(());
    }

    // `--settings NAME` prints that game's settings view and exits.
    if let Some(name) = std::env::args().skip_while(|a| a != "--settings").nth(1) {
        let game = db
            .games
            .iter()
            .find(|g| g.name.eq_ignore_ascii_case(&name))
            .with_context(|| format!("No game called {name:?} in the database."))?;
        let mut out = std::io::stdout().lock();
        for line in settings::lines(game, 76) {
            let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
            // A closed pipe (`| head`) just ends the output.
            if writeln!(out, "{text}").is_err() {
                break;
            }
        }
        return Ok(());
    }

    let mut app = app::App::new(entries);
    app.set_home(home.clone());
    if let Ok((width, _)) = ratatui::crossterm::terminal::size() {
        app.resize(width);
    }

    // init() also installs a panic hook that puts the terminal back.
    let mut terminal = ratatui::init();
    let result = run(
        &mut terminal,
        &mut app,
        &db,
        &home,
        &state_file,
        chosen.as_deref(),
    );
    ratatui::restore();
    result
}

fn run(
    terminal: &mut ratatui::DefaultTerminal,
    app: &mut app::App,
    db: &db::Database,
    home: &std::path::Path,
    state_file: &std::path::Path,
    chosen_db: Option<&std::path::Path>,
) -> Result<()> {
    while !app.quit {
        terminal.draw(|f| ui::draw(f, app))?;
        match event::read()? {
            Event::Key(key) if key.kind == KeyEventKind::Press => app.handle_key(key),
            Event::Resize(width, _) => app.resize(width),
            _ => {}
        }
        let Some(launch) = app.launch.take() else {
            continue;
        };
        let script = match runner::find_script() {
            Some(s) => s,
            None => {
                // Not beside this program or cached: fetch it, on the normal screen.
                ratatui::restore();
                let fetched = fetch::ensure_script();
                *terminal = ratatui::init();
                match fetched {
                    Ok(path) => path,
                    Err(e) => {
                        app.message = e.to_string();
                        continue;
                    }
                }
            }
        };
        let env = launch.env;
        ratatui::restore();
        runner::run(&script, &env, chosen_db);
        *terminal = ratatui::init();
        // The window may have been resized while the installer ran.
        if let Ok((width, _)) = ratatui::crossterm::terminal::size() {
            app.resize(width);
        }
        // The action may have installed or removed a game.
        app.replace_games(games::build(db, home, state_file));
    }
    Ok(())
}
