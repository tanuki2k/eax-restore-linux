# The Rust TUI and the engine port

Moved out of CLAUDE.md so it isn't loaded into every session; CLAUDE.md says when to read it.

- **Rust TUI (`tui/`):** a full-screen front end that lists database, library and
  manually installed games and hands install, uninstall and the Tools to this
  script through `EAX_RESTORE_ACTION`, `EAX_RESTORE_GAME_DIR` and
  `EAX_RESTORE_GAME`; the script stays the engine until the Rust port replaces
  it. Checks, as `.github/workflows/tui.yml` runs them: `cd tui && cargo fmt --check
  && cargo clippy --locked --all-targets -- -D warnings && cargo test --locked`.
  Run it with `cargo run -- ../game-database.json` after `./build.sh`. Its look copies the old fzf browser's (boxed Search,
  Filters and Games beside a full-height pane; the colours are in `tui/src/theme.rs`,
  taken from fzf's palette and the script's `GREEN`/`YELLOW`/`WHITE`; the script's bold
  colours use ratatui's `Light*` names because crossterm writes the plain ones as the dark palette
  entry, where a terminal draws `\033[1;33m` bright). The right pane switches between
  Profile and Settings with ←/→ (Shift-↑/↓ scrolls it); F1 lists every key (`tui/src/help.rs`: keep it in step
  with `app.rs`), Ctrl-F gives the pane the whole screen, and Ctrl-L puts it under the list instead of
  beside it (it does that by itself below 104 columns); `--list`, `--settings NAME` and `--profile NAME`
  print the game list, one game's settings view or its profile without the TUI, which is
  how the Rust views are compared with the Bash browser's `print_game_settings_details`
  and `print_game_profile_stores` (word for word, for every game). The Games list keeps its window between redraws (`App::list_offset`) and moves it only
  when the highlight is within 3 rows of an edge, like fzf's `--scroll-off`. It finds the
  script via `EAX_RESTORE_SCRIPT`, beside itself, its cache (`~/.local/share/
  eax-restore-linux/tui/<channel>/`) or `dist/`, skipping any that lacks
  `EAX_RESTORE_ACTION`; if none, it downloads its channel's release script and
  checks it against the `.sha256` (`EAX_RESTORE_CHANNEL=dev` at build time picks
  the dev channel). The engine is moving into Rust a stage at a time under
  `tui/src/engine/` (no TUI types in there; the crate is a library, `src/lib.rs`, plus
  a thin `main.rs`). Stages 1 to 6 are done, and no screen calls them yet apart from
  the list's "is this game installed" check. Stage 1: `engine/config/` is
  `config_get_key` / `config_set_key`, `config_values_equal`, `config_row_is_safe` and
  `resolve_config_file` for the eleven formats. Stage 2: `engine/files.rs` is the
  name, scope and content checks, the backups and `swap_in` from `src/common.sh`;
  `engine/manifest.rs` reads a manifest for an uninstall (`read`, the guard against a
  forged one), parses `CONFIG:` lines and has the writers (`start`, `append`,
  `dedupe`, `forget`); `engine/config/revert.rs` puts one recorded setting back.
  `tui/tests/config_oracle.rs` and `tui/tests/manifest_oracle.rs` run each case
  through the Bash functions and the Rust ones and compare the answers and the files
  byte for byte (the bats tests' own cases, a generated corpus, every setting in the
  database), so a change to one of those functions in `src/` needs the same change in
  `engine/`. The uninstall's manifest reader is inline in `src/uninstall-flow.sh`, so
  `manifest::read` is checked by its own tests instead. `eax-restore config
  get|set FILE FORMAT SECTION KEY [VALUE]` runs the Rust editors by hand.
  Stage 3 (engine only, no screens: the user will design a panel later, see below):
  `engine/speakers.rs` (the speaker setup, its alsoft.ini values and label, reading it
  back, `only_if.speakers` matching), `engine/identify.rs` (`identify_game_dir`),
  `engine/game_settings.rs` (`rows` = `load_game_config_rows`; `survey` = `_gs_build_plan`
  without its prompts, a file the game hasn't written yet comes back as `Missing`),
  `engine/apply.rs` (`apply` = `apply_game_settings`, `update_in_manifest` =
  `update_game_settings_in_manifest`; what happened comes back in a `Report`, and the
  game-running and wineserver waits come from a `Host` the caller supplies),
  `engine/installed.rs` (an install's alsoft.ini files, prefix and recorded settings,
  the start of `src/settings-flow.sh`) and `engine/process.rs` (`game_exe_running`).
  Checked by `tui/tests/speakers_oracle.rs` and `tui/tests/game_settings_oracle.rs`;
  `installed.rs` copies inline flow code, so it has unit tests only.
  Stage 4 (engine only): `engine/launcher/` is `src/launcher-config.sh` plus the change
  half of `src/dsoal-log-flow.sh`. `options.rs` is the launch-option string functions
  (Bash's regex quirks kept: the longest value wins at the leftmost match, a tie goes to
  the quoted one, and results lose trailing line breaks as `$(...)` does); `vdf.rs`
  Steam's localconfig.vdf; `heroic.rs` Heroic's GamesConfig JSON, written the way jq
  prints it; `target.rs` finds the settings file (`steam_localconfig_for_app`);
  `changes.rs` writes and reverts the DLL override and turns the sound logs on and off;
  `control.rs` sees, closes and reopens a launcher from `/proc`. Asking the player
  whether to close a launcher is the caller's. Checked by `tui/tests/launcher_oracle.rs`.
  Stage 5 (engine only): `engine/uninstall.rs` is `src/uninstall-flow.sh` without its
  questions: `survey` (Phase 1's findings: the manifest's files and their oldest
  backups, or the scan when there's no manifest, a prefix shared with another install,
  the VC++ runtime), `Choices` (its answers) and `execute` (Phase 2, then the manifest
  rewrite or the "uninstalled" marker). The registry keys, VC++, EAX Unified, companion
  prefixes and closing a launcher go through an `UninstallHost`, until Stage 7 ports the
  Wine side. `tui/tests/uninstall_oracle.rs` builds the script (`./build.sh`), installs
  the same game twice in the integration tests' fake world, uninstalls one copy with the
  script and the other with the engine, and compares the home folders file for file.
  Stage 6 (engine only): `engine/builds.rs` is the download half of `src/cache.sh` and
  `src/verify.sh`: `lookup` (the build labels, without downloading), `ensure_dsoal` /
  `ensure_openal` (fetch when missing or out of date, `unzip -t`, the pinned SHA256 or
  GitHub's published digest, swap in only once unpacked), `dsoal_source_dir` and
  `openal_source_dll`. The network is the `Net` trait (`Curl` runs curl with the
  script's options); unpacking still shells out to `unzip`, which the script needs too.
  Installing a build with no published checksum is a callback, not a prompt.
  `tui/tests/builds_oracle.rs` serves a fake GitHub through a stub curl to both sides.

The planned interface (the user's design, not built yet) is a panel like
Optiscaler-Client's: every choice for an install or uninstall on one screen, plus
the install's status. So engine code stays prompt-free: read state, take choices,
plan, apply.
