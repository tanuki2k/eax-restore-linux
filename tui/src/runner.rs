//! Runs the Bash installer for an action, outside the TUI.

use std::io::{self, BufRead, IsTerminal, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::fetch::{self, NAME as SCRIPT_NAME};

/// Where to look, best first: the caller's choice, beside this program, the
/// copy fetched for this channel, and (for a build from the repo) where
/// `./build.sh` puts it.
fn candidates() -> Vec<PathBuf> {
    let mut c = Vec::new();
    if let Some(p) = std::env::var_os("EAX_RESTORE_SCRIPT") {
        c.push(PathBuf::from(p));
    }
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf))
    {
        c.push(dir.join(SCRIPT_NAME));
    }
    if let Some(home) = fetch::data_home() {
        c.push(fetch::cache_path(&home, fetch::CHANNEL));
    }
    c.push(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../dist")
            .join(SCRIPT_NAME),
    );
    c
}

pub fn find_script() -> Option<PathBuf> {
    first_usable(&candidates())
}

/// The first that exists and can be driven; an older script that lacks the
/// action variable is passed over, so the right one gets fetched.
fn first_usable(paths: &[PathBuf]) -> Option<PathBuf> {
    paths
        .iter()
        .find(|p| p.is_file() && fetch::supports_actions(p))
        .cloned()
}

/// An I/O error without Rust's "(os error N)" tail.
fn plain_error(e: &io::Error) -> String {
    let text = e.to_string();
    text.split(" (os error").next().unwrap_or(&text).to_string()
}

/// Runs the script with `env` set, on the real terminal, then waits for Enter so
/// its closing summary can be read. The terminal must already be restored.
pub fn run(script: &Path, env: &[(&str, String)], database: &Path) {
    let mut cmd = Command::new("bash");
    cmd.arg(script)
        .env("EAX_RESTORE_GAME_DATABASE_FILE", database);
    for (k, v) in env {
        cmd.env(k, v);
    }
    // The alternate screen, like the TUI's own, so quitting leaves the shell's
    // screen as it was.
    print!("\x1b[?1049h\x1b[2J\x1b[H");
    let _ = io::stdout().flush();
    match cmd.status() {
        Ok(s) if s.success() => {}
        Ok(s) => match s.code() {
            Some(code) => println!("\nThe installer stopped with exit status {code}."),
            None => println!("\nThe installer was stopped before it finished."),
        },
        Err(e) => println!("\nCouldn't start the installer ({}).", plain_error(&e)),
    }
    // Without a terminal there is nobody to press Enter.
    if io::stdin().is_terminal() {
        print!("\nPress Enter to go back to the game list. ");
        let _ = io::stdout().flush();
        let _ = io::stdin().lock().read_line(&mut String::new());
    }
    print!("\x1b[?1049l");
    let _ = io::stdout().flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_usable_file_wins_and_missing_or_old_ones_are_skipped() {
        let dir = tempfile::tempdir().unwrap();
        let (old, new) = (dir.path().join("old.sh"), dir.path().join("new.sh"));
        std::fs::write(&old, "echo old\n").unwrap();
        std::fs::write(&new, "# EAX_RESTORE_ACTION\n").unwrap();
        let missing = dir.path().join("nope.sh");
        assert_eq!(
            first_usable(&[missing.clone(), old.clone(), new.clone()]),
            Some(new)
        );
        assert_eq!(first_usable(&[missing, old]), None);
    }

    #[test]
    fn an_io_error_loses_its_os_error_number() {
        let e = std::fs::read("/definitely/not/here").unwrap_err();
        assert_eq!(plain_error(&e), "No such file or directory");
    }

    #[test]
    fn the_run_hands_the_environment_to_the_script() {
        let dir = tempfile::tempdir().unwrap();
        let script = dir.path().join("s.sh");
        let out = dir.path().join("out.txt");
        std::fs::write(&script, format!("echo \"$EAX_RESTORE_ACTION|$EAX_RESTORE_GAME_DIR|$EAX_RESTORE_GAME_DATABASE_FILE\" > '{}'\n", out.display())).unwrap();
        run(
            &script,
            &[
                ("EAX_RESTORE_ACTION", "uninstall".into()),
                ("EAX_RESTORE_GAME_DIR", "/g".into()),
            ],
            Path::new("/db.json"),
        );
        assert_eq!(
            std::fs::read_to_string(out).unwrap().trim(),
            "uninstall|/g|/db.json"
        );
    }
}
