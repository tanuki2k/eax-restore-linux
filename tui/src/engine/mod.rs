//! The installer's engine, ported from the Bash script one stage at a time.
//! Nothing in here knows about the screens; until a stage reaches parity
//! with `src/*.sh` the TUI still hands the action to the script.

pub mod apply;
pub mod config;
pub mod files;
pub mod game_settings;
pub mod identify;
pub mod installed;
pub mod launcher;
pub mod manifest;
pub mod process;
pub mod speakers;
pub mod uninstall;
