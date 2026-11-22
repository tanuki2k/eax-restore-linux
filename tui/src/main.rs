use anyhow::{Context, Result};
use eax_restore::engine::config;
use eax_restore::{app, cli, db, fetch, games, library, prefs, profile, settings, ui};
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use std::io::Write;
use std::path::PathBuf;

/// A database named on the command line, or by the variable the Bash script
/// also reads for a local edit.
fn chosen_database() -> Option<PathBuf> {
    // The first argument that is neither a flag nor a flag's value.
    let mut args = std::env::args_os().skip(1);
    let mut positional = None;
    while let Some(a) = args.next() {
        if a == "--settings" || a == "--profile" {
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

/// Prints styled lines as plain text. A closed pipe (`| head`) just ends the output.
fn print_lines(lines: Vec<ratatui::text::Line<'static>>) {
    let mut out = std::io::stdout().lock();
    for line in lines {
        let text: String = line.spans.iter().map(|s| s.content.as_ref()).collect();
        if writeln!(out, "{text}").is_err() {
            break;
        }
    }
}

/// `config get|set FILE FORMAT SECTION KEY [VALUE]`: reads or changes one key
/// with the Rust editors, for checking them by hand against the script's
/// `config_get_key` / `config_set_key`. Values are spelled as the script
/// spells them, markers included (`__ABSENT__`, `__TRUE__`, `__DELETE__`).
fn config_command(args: &[String]) -> Result<()> {
    const USAGE: &str = "Usage: eax-restore config get FILE FORMAT SECTION KEY\n       eax-restore config set FILE FORMAT SECTION KEY VALUE";
    match args {
        [verb, file, format, sec, key] if verb == "get" => {
            let value = config::get_file(file.as_ref(), format.parse()?, sec, key);
            let mut out = std::io::stdout().lock();
            out.write_all(value.as_bytes())?;
            out.write_all(b"\n")?;
            Ok(())
        }
        [verb, file, format, sec, key, value] if verb == "set" => config::set_file(
            file.as_ref(),
            format.parse()?,
            sec,
            key,
            &config::Value::text(value),
        ),
        _ => anyhow::bail!(USAGE),
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `--build` prints the bare build number, for CI and the update check's
    // tests; `--version` the label the bottom bar shows.
    if args.first().is_some_and(|a| a == "--build") {
        let n = eax_restore::build_info::number().context("This build has no build number.")?;
        println!("{n}");
        return Ok(());
    }
    if args.first().is_some_and(|a| a == "--version") {
        println!("eax-restore {}", eax_restore::build_info::label());
        return Ok(());
    }
    if args.first().is_some_and(|a| a == "config") {
        return config_command(&args[1..]);
    }
    if args.first().is_some_and(|a| a == "--help" || a == "help") {
        return cli::run(&["status".to_string(), "--help".to_string()]);
    }
    if args
        .first()
        .is_some_and(|a| cli::COMMANDS.contains(&a.as_str()))
    {
        return cli::run(&args);
    }
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

    // `--profile NAME` prints that game's profile from the database and exits.
    if let Some(name) = std::env::args().skip_while(|a| a != "--profile").nth(1) {
        let game = db
            .games
            .iter()
            .find(|g| g.name.eq_ignore_ascii_case(&name))
            .with_context(|| format!("No game called {name:?} in the database."))?;
        print_lines(profile::database_lines(game, 76));
        return Ok(());
    }

    // `--settings NAME` prints that game's settings view and exits.
    if let Some(name) = std::env::args().skip_while(|a| a != "--settings").nth(1) {
        let game = db
            .games
            .iter()
            .find(|g| g.name.eq_ignore_ascii_case(&name))
            .with_context(|| format!("No game called {name:?} in the database."))?;
        print_lines(settings::lines(game, 76));
        return Ok(());
    }

    let mut app = app::App::new(entries);
    app.set_home(home.clone());
    if eax_restore::update::wanted() {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(eax_restore::update::check());
        });
        app.update_rx = Some(rx);
    }
    app.apply_list_prefs(&prefs::Prefs::load());
    if let Ok((width, _)) = ratatui::crossterm::terminal::size() {
        app.resize(width);
    }

    // init() also installs a panic hook that puts the terminal back.
    let mut terminal = ratatui::init();
    let result = run(&mut terminal, &mut app, &db, &home, &state_file);
    ratatui::restore();
    result
}

/// Update and restart: on the normal screen, download the new build, swap it
/// in and start it in this one's place. On any failure the TUI comes back
/// with a pop-up saying why.
fn update_and_restart(terminal: &mut ratatui::DefaultTerminal, app: &mut app::App, build: u32) {
    use eax_restore::update;
    let Some(exe) = update::current_exe() else {
        app.update_failed(build, &update::Failed::ReadOnly);
        return;
    };
    ratatui::restore();
    println!("Downloading build {build}...");
    let result = update::install("curl", &exe);
    if result.is_ok() {
        println!("Updated to build {build}. Restarting...");
        // Only comes back if the new binary didn't start.
        let _ = update::restart(&exe);
    }
    *terminal = ratatui::init();
    app.update_failed(build, &result.err().unwrap_or(update::Failed::Download));
}

fn run(
    terminal: &mut ratatui::DefaultTerminal,
    app: &mut app::App,
    db: &db::Database,
    home: &std::path::Path,
    state_file: &std::path::Path,
) -> Result<()> {
    while !app.quit {
        terminal.draw(|f| ui::draw(f, app))?;
        // While something on the page moves by itself (the work's progress,
        // the build lists on their way), redraw between keys.
        let wait = app
            .panel
            .as_ref()
            .and_then(|p| p.animating().then_some(150))
            .or_else(|| app.prefs.as_ref().filter(|s| s.waiting()).map(|_| 150))
            // The update check's answer, or a page closing with one waiting.
            .or_else(|| (app.update_rx.is_some() || app.update_waiting.is_some()).then_some(250));
        let key_waiting = match wait {
            None => true,
            Some(ms) => event::poll(std::time::Duration::from_millis(ms))?,
        };
        if key_waiting {
            match event::read()? {
                Event::Key(key) if key.kind == KeyEventKind::Press => app.handle_key(key),
                Event::Resize(width, _) => app.resize(width),
                _ => {}
            }
        }
        if let Some(p) = app.panel.as_mut() {
            p.tick();
        }
        if let Some(s) = app.prefs.as_mut() {
            s.tick();
        }
        app.poll_update();
        if let Some(build) = app.update_now.take() {
            update_and_restart(terminal, app, build);
        }
        if app.rescan && app.panel.is_none() {
            app.rescan = false;
            app.replace_games(games::build(db, home, state_file));
        }
    }
    Ok(())
}
