//! The EAX Restore TUI as a library, so `tests/` can reach the engine. The
//! binary in `main.rs` is the only other user.

pub mod actions;
pub mod app;
pub mod cli;
pub mod db;
pub mod engine;
pub mod fetch;
pub mod filters;
pub mod games;
pub mod help;
pub mod library;
pub mod picker;
pub mod profile;
pub mod runner;
pub mod settings;
pub mod theme;
pub mod ui;
