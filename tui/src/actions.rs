//! What can be done to a game in the list, and how each action is handed to the
//! Bash installer (EAX_RESTORE_ACTION, EAX_RESTORE_GAME_DIR, EAX_RESTORE_GAME).

use crate::games::{Entry, Status};
use crate::library::StoreKind;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    Install,
    Reinstall,
    OptionalSettings,
    Speakers,
    DsoalLog,
    Vcrun,
    Uninstall,
}

impl Action {
    pub fn label(self) -> &'static str {
        match self {
            Action::Install => "Install the EAX fix",
            Action::Reinstall => "Install again",
            Action::OptionalSettings => "Change optional settings",
            Action::Speakers => "Change speaker configuration",
            Action::DsoalLog => "Turn logging for the EAX fix on or off",
            Action::Vcrun => "Install the VC++ runtime",
            Action::Uninstall => "Uninstall the EAX fix",
        }
    }

    /// The value the script's EAX_RESTORE_ACTION takes.
    fn script_name(self) -> &'static str {
        match self {
            Action::Install | Action::Reinstall => "install",
            Action::OptionalSettings => "optional-settings",
            Action::Speakers => "speakers",
            Action::DsoalLog => "dsoal-log",
            Action::Vcrun => "vcrun",
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
            // The optional settings come from the game's database profile.
            if e.game.is_some() {
                v.push(Action::OptionalSettings);
            }
            v.extend([
                Action::Speakers,
                Action::DsoalLog,
                Action::Vcrun,
                Action::Uninstall,
            ]);
            v
        }
    }
}

/// `steam:2210` / `gog:1207658936`, for an install of a game found in a library.
fn store_game(e: &Entry) -> Option<String> {
    let g = e.game.as_ref()?;
    match e.store? {
        StoreKind::Steam => Some(format!("steam:{}", g.stores.steam.as_ref()?.id)),
        StoreKind::Gog => Some(format!("gog:{}", g.stores.gog.as_ref()?.id)),
    }
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
        assert!(a.contains(&Action::OptionalSettings));
    }

    #[test]
    fn a_manual_game_has_no_optional_settings() {
        let mut e = entry(Status::Manual, None, Some("/g"));
        e.game = None;
        let a = available(&e);
        assert!(!a.contains(&Action::OptionalSettings));
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
            (Action::OptionalSettings, "optional-settings"),
            (Action::Vcrun, "vcrun"),
            (Action::DsoalLog, "dsoal-log"),
        ] {
            let env = script_env(&e, a);
            assert_eq!(get(&env, "EAX_RESTORE_ACTION"), Some(name));
            assert_eq!(get(&env, "EAX_RESTORE_GAME_DIR"), Some("/lib/Alpha/bin"));
            assert_eq!(get(&env, "EAX_RESTORE_GAME"), None);
        }
    }
}
