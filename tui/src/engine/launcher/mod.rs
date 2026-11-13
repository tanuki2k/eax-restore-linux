//! A game's settings in its launcher: Steam's launch options in
//! localconfig.vdf and Heroic's environment variables in GamesConfig, where
//! the DLL override (WINEDLLOVERRIDES) and the sound-log variables go.
//! Ports of `src/launcher-config.sh` and the change half of
//! `src/dsoal-log-flow.sh`.

pub mod changes;
pub mod control;
pub mod heroic;
pub mod options;
pub mod target;
pub mod vdf;

/// The environment variable the DLL override goes in.
pub const OVERRIDE_VAR: &str = "WINEDLLOVERRIDES";
