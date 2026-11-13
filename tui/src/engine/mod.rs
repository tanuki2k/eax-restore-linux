//! The installer's engine, ported from the Bash script one stage at a time.
//! Nothing in here knows about the screens; until a stage reaches parity
//! with `src/*.sh` the TUI still hands the action to the script.

pub mod config;
pub mod files;
pub mod manifest;
