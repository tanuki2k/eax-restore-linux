//! What can be done to a game in the list, and how each action is handed to the
//! Bash installer (EAX_RESTORE_ACTION, EAX_RESTORE_GAME_DIR, EAX_RESTORE_GAME).

use crate::games::{Entry, Status};
use crate::library::StoreKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Install,
    Reinstall,
    GameSettings,
    Speakers,
    DsoalLog,
    Vcrun,
    EaxUnified,
    Uninstall,
}

impl Action {
    pub fn label(self) -> &'static str {
        match self {
            Action::Install => "Install the EAX fix",
            Action::Reinstall => "Install again",
            Action::GameSettings => "Change game settings",
            Action::Speakers => "Change speaker configuration",
            Action::DsoalLog => "Turn logging for the EAX fix on or off",
            Action::Vcrun => "Install the VC++ runtime",
            Action::EaxUnified => "Install EAX Unified",
            Action::Uninstall => "Uninstall the EAX fix",
        }
    }

    /// The value the script's EAX_RESTORE_ACTION takes.
    fn script_name(self) -> &'static str {
        match self {
            Action::Install | Action::Reinstall => "install",
            Action::GameSettings => "game-settings",
            Action::Speakers => "speakers",
            Action::DsoalLog => "dsoal-log",
            Action::Vcrun => "vcrun",
            Action::EaxUnified => "eax-unified",
            Action::Uninstall => "uninstall",
        }
    }
}

/// The actions that make sense for this game, in menu order.
pub fn available(e: &Entry) -> Vec<Action> {
    match e.status {
        Status::NotOnThisPc | Status::OnThisPc => vec![Action::Install],
        Status::Installed | Status::Manual => {
            let mut v = vec![Action::Reinstall];
            // The game settings come from the game's database profile.
            if e.game.is_some() {
                v.push(Action::GameSettings);
            }
            v.extend([
                Action::Speakers,
                Action::DsoalLog,
                Action::Vcrun,
                Action::EaxUnified,
                Action::Uninstall,
            ]);
            v
        }
    }
}

/// `steam:2210` / `gog:1207658936`, for an install of a game found in a library.
/// A copy Lutris, Bottles or Faugus runs goes by its folder instead, since the
/// same ID can belong to a Heroic copy too.
fn store_game(e: &Entry) -> Option<String> {
    if e.via.is_some() {
        return None;
    }
    let g = e.game.as_ref()?;
    match e.store? {
        StoreKind::Steam => Some(format!("steam:{}", g.stores.steam.as_ref()?.id)),
        StoreKind::Gog => Some(format!("gog:{}", g.stores.gog.as_ref()?.id)),
    }
}

/// The headless command (`eax-restore <command> GAME_FOLDER`) that does this
/// action with the Rust engine, when there is one and the game's folder is
/// known. `EAX_RESTORE_ENGINE=bash` sends every action to the script instead.
pub fn engine_args(e: &Entry, a: Action) -> Option<Vec<String>> {
    if std::env::var("EAX_RESTORE_ENGINE").is_ok_and(|v| v == "bash") {
        return None;
    }
    let command = match a {
        Action::Install | Action::Reinstall => "install",
        Action::Uninstall => "uninstall",
        Action::Speakers => "speakers",
        Action::GameSettings => "settings",
        Action::DsoalLog => "sound-log",
        // No Rust command yet.
        Action::Vcrun | Action::EaxUnified => return None,
    };
    let path = e.path.as_ref()?;
    Some(vec![command.to_string(), path.display().to_string()])
}

/// The environment variables that start the script on this game and action.
pub fn script_env(e: &Entry, a: Action) -> Vec<(&'static str, String)> {
    let mut env = vec![("EAX_RESTORE_ACTION", a.script_name().to_string())];
    let in_library = e.status == Status::OnThisPc;
    match (a, store_game(e), &e.path) {
        (Action::Install, Some(game), _) if in_library => env.push(("EAX_RESTORE_GAME", game)),
        // A game with no known folder: the script asks where it is.
        (Action::Install, _, _) if e.status == Status::NotOnThisPc => {}
        (_, _, Some(path)) => env.push(("EAX_RESTORE_GAME_DIR", path.display().to_string())),
        _ => {}
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::Database;
    use std::path::PathBuf;

    fn entry(status: Status, store: Option<StoreKind>, path: Option<&str>) -> Entry {
        let db = Database::parse(
            r#"{"games":[{"id":"a","name":"Alpha","stores":{"steam":{"id":10},"gog":{"id":77}}}]}"#,
        )
        .unwrap();
        let mut e = Entry::database_only(db.games[0].clone());
        e.status = status;
        e.store = store;
        e.path = path.map(PathBuf::from);
        e
    }

    fn get<'a>(env: &'a [(&str, String)], k: &str) -> Option<&'a str> {
        env.iter().find(|(n, _)| *n == k).map(|(_, v)| v.as_str())
    }

    #[test]
    fn actions_with_a_rust_command_use_it() {
        let e = entry(
            Status::Installed,
            Some(StoreKind::Steam),
            Some("/lib/Alpha"),
        );
        assert_eq!(
            engine_args(&e, Action::Uninstall),
            Some(vec!["uninstall".to_string(), "/lib/Alpha".to_string()])
        );
        assert_eq!(engine_args(&e, Action::Reinstall).unwrap()[0], "install");
        assert_eq!(engine_args(&e, Action::Vcrun), None);
        assert_eq!(engine_args(&e, Action::EaxUnified), None);
        // A game with no known folder is left to the script, which asks.
        let nowhere = entry(Status::NotOnThisPc, None, None);
        assert_eq!(engine_args(&nowhere, Action::Install), None);
    }

    #[test]
    fn a_game_that_is_not_installed_can_only_be_installed() {
        assert_eq!(
            available(&entry(Status::NotOnThisPc, None, None)),
            [Action::Install]
        );
        assert_eq!(
            available(&entry(Status::OnThisPc, Some(StoreKind::Steam), Some("/g"))),
            [Action::Install]
        );
    }

    #[test]
    fn an_installed_game_gets_every_tool_and_uninstall_last() {
        let a = available(&entry(
            Status::Installed,
            Some(StoreKind::Steam),
            Some("/g"),
        ));
        assert_eq!(a.first(), Some(&Action::Reinstall));
        assert_eq!(a.last(), Some(&Action::Uninstall));
        assert!(a.contains(&Action::GameSettings));
    }

    #[test]
    fn a_manual_game_has_no_optional_settings() {
        let mut e = entry(Status::Manual, None, Some("/g"));
        e.game = None;
        let a = available(&e);
        assert!(!a.contains(&Action::GameSettings));
        assert!(a.contains(&Action::Uninstall));
    }

    #[test]
    fn installing_a_library_game_names_it_by_store_and_id() {
        let e = entry(Status::OnThisPc, Some(StoreKind::Steam), Some("/lib/Alpha"));
        let env = script_env(&e, Action::Install);
        assert_eq!(get(&env, "EAX_RESTORE_ACTION"), Some("install"));
        assert_eq!(get(&env, "EAX_RESTORE_GAME"), Some("steam:10"));
        assert_eq!(get(&env, "EAX_RESTORE_GAME_DIR"), None);
        let gog = entry(Status::OnThisPc, Some(StoreKind::Gog), Some("/lib/Alpha"));
        assert_eq!(
            get(&script_env(&gog, Action::Install), "EAX_RESTORE_GAME"),
            Some("gog:77")
        );
    }

    #[test]
    fn installing_a_game_that_is_not_here_leaves_the_folder_to_the_script() {
        let env = script_env(&entry(Status::NotOnThisPc, None, None), Action::Install);
        assert_eq!(env.len(), 1);
    }

    #[test]
    fn tools_and_uninstall_use_the_installs_folder() {
        let e = entry(
            Status::Installed,
            Some(StoreKind::Steam),
            Some("/lib/Alpha/bin"),
        );
        for (a, name) in [
            (Action::Uninstall, "uninstall"),
            (Action::Speakers, "speakers"),
            (Action::Reinstall, "install"),
            (Action::GameSettings, "game-settings"),
            (Action::Vcrun, "vcrun"),
            (Action::DsoalLog, "dsoal-log"),
            (Action::EaxUnified, "eax-unified"),
        ] {
            let env = script_env(&e, a);
            assert_eq!(get(&env, "EAX_RESTORE_ACTION"), Some(name));
            assert_eq!(get(&env, "EAX_RESTORE_GAME_DIR"), Some("/lib/Alpha/bin"));
            assert_eq!(get(&env, "EAX_RESTORE_GAME"), None);
        }
    }

    #[test]
    fn a_copy_a_wine_launcher_runs_goes_to_the_script_by_its_folder() {
        let mut e = entry(Status::OnThisPc, Some(StoreKind::Gog), Some("/g/Thief"));
        e.via = Some("Lutris");
        let env = script_env(&e, Action::Install);
        assert_eq!(get(&env, "EAX_RESTORE_GAME"), None);
        assert_eq!(get(&env, "EAX_RESTORE_GAME_DIR"), Some("/g/Thief"));
    }
}
