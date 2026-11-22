//! The EAX Restore TUI as a library, so `tests/` can reach the engine. The
//! binary in `main.rs` is the only other user.

pub mod app;
pub mod build_choice;
pub mod build_info;
pub mod cli;
pub mod db;
pub mod engine;
pub mod fetch;
pub mod filters;
pub mod games;
pub mod help;
pub mod library;
pub mod panel;
pub mod picker;
pub mod prefs;
pub mod prefs_screen;
pub mod profile;
pub mod runlog;
pub mod settings;
pub mod theme;
pub mod ui;
pub mod update;
