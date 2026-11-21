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
  a thin `main.rs`). Stages 1 to 8 are done, and no screen calls them yet apart from
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
  Stage 7a (engine only): `engine/wine.rs` runs things in a prefix (`Runner`:
  protontricks with the AppID for Steam, Heroic's own Wine build otherwise): `regedit`,
  waiting for wineserver, Creative's OpenAL runtime, `steam_prefix_for_appid`, Heroic's
  runner (`heroic_runner`, `heroic_runner_config`) and the exes' 32/64-bit count read
  from their PE headers. `engine/prefix.rs` is the registry patches (with the override
  read back from user.reg), their removal and the DLL copy into system32/syswow64;
  `engine/deploy.rs` is `handle_conflict` and `deploy_copy`. Checked by
  `tui/tests/prefix_oracle.rs` (the protontricks stub for Steam, a fake wine for Heroic).
  Stage 7b (engine only): `engine/vcrun.rs` is `src/vcrun.sh` (genuine-DLL check, the
  package manager then Microsoft's installer, in repair mode when it's registered, the
  DLL overrides, the uninstall with its Programs and Features clean-up);
  `engine/eax_unified.rs` is EAX Unified's install and removal; `engine/host.rs` is
  `SystemHost`, the real `Host` / `UninstallHost` (the game running from `/proc`,
  wineserver, the Wine side above, a companion app's own prefix), with closing a
  launcher left to a callback. Checked by `tui/tests/vcrun_oracle.rs` (a fake
  protontricks and wine that act as the Windows installers). Finding a Heroic game's
  prefix is detection, so it comes with Stage 8.
  Stage 8a (engine only): `engine/install.rs` is Phase 4 of `src/install-flow.sh`, run
  from a finished `Plan` (game and extra exe folders, prefix, architecture, engine,
  builds, speakers, alsoft.ini values, override method, VC++, EAX Unified, game
  settings, companion apps) through an `InstallHost`, with the last install's records
  carried over on a reinstall. `engine/alsoft_template.rs` is the alsoft.ini text,
  copied out of `install-flow.sh` by a script, so keep the two in step.
  `tui/tests/install_oracle.rs` installs the same game in two copies of the fake world,
  one with the script and one with the engine, and compares the home folders. Still to
  come in 8b: Phases 1-3, the detection that makes a `Plan`.
  Stage 8b (engine only): `engine/detect.rs` is the detection in `src/detection.sh`
  without its questions (name matching with the `regex` crate, the ranked exe folders,
  Linux builds, extra exe folders, the audio API from the game's files, the Steam AppID,
  companion apps, a Heroic game's prefix); `engine/prepare.rs` gathers it into `Facts`
  and the `Plan` the script's defaults make. Checked by `tui/tests/detect_oracle.rs`, and
  end to end by `install_oracle.rs`, which installs with a detected plan too. Every
  oracle test puts `tests/fixtures/bin` first on PATH for the Rust side as well, so the
  machine's own winetricks or Wine never runs.
  `engine/roots.rs` is the one list of Steam (native, Flatpak, Snap) and Heroic
  folders (`xdg_home` reads `XDG_*` only for the real home, so tests get the
  defaults). `engine/wine_launchers.rs` is `wine_launcher_records`,
  `launcher_exe_for_root` and the prefix step's lookup for Lutris, Bottles and
  Faugus (it runs `sqlite3` as the script does); `prepare::gather` uses it when
  Heroic doesn't know the game, `library::scan_wine_launchers` lists them with
  `Found::via`, and such a copy goes to the script by folder. Checked by
  `detect_oracle.rs`'s `wine_launchers_match`.

The game panel (`tui/src/panel/`, the user's Optiscaler-Client-style design): Enter on a game
with a folder opens its page, one column `view::LEFT_W` wide in a pop-up over the games list
(`view::draw`, `view::page_area`: as tall as its content, never shrinking going from the
choices to a run, so the list shows round it), on the folder holding
the profile's exe (`detect::exe_folder`, as the script moves `GAME_DIR` after a library scan
and as the headless CLI does: a library gives the install's top folder, and BioShock's exe is
in Builds/Release). The Status card (whether the fix is installed, `view::banner_lines`,
then each preflight check that came out Warn or Fail, `view::status_card_lines`; the ones that
came out fine aren't shown), then the choices in numbered boxes in the script's order (`Panel::sections`: audio engine,
runtimes, speakers, compatibility tweaks, DLL override, then audio and optional settings),
drawn into an off-screen buffer and scrolled to keep the focus in view; a value from the PC or
profile shows green with "(detected)" until changed (`Row::detected`). DSOAL and OpenAL Soft
each have a build row (`src/build_choice.rs`: Latest rolling, Latest numbered (the default), then
every numbered build, looked up on a thread by `build_choice::load`, which keeps the lookup in
`~/.local/share/eax-restore-linux/build-lists.json` for an hour (GitHub allows 60 API requests an
hour without a login, and a lookup takes about five) and falls back to it however old when GitHub
refuses; `Row::keys` keeps the
choice when the list arrives); the DSOAL one is hidden while the engine is OpenAL Soft alone
(`Panel::place_dsoal_row`). `builds::Build` has `Numbered` (resolved to the newest at install
time) and `Exact(version)` (cached in `dsoal/builds/<rev>`, `openal-soft/builds/<tag>`); installs
record the versions as `# DSOAL:` / `# OpenAL Soft:` manifest comments (the script too), shown
on the Status card. Setting dropdowns are all `view::LIST_W` wide and wrap their
descriptions (`view::draw_dropdown`). The preflight (`Panel::status_lines`, `Check`
Ok/Warn/Fail/Unknown badges: exe, store, audio API from the profile vs. the files, arch, prefix,
Wine, config files the settings need) is terse badge lines, not the script's full sentences.
It carries the script's checks before install: a fresh install is offered only with no FAIL line
(`Panel::has_fail`); a prefix counts only with `drive_c` (Heroic and the other launchers name one
before the first run makes it); the folders the install writes to must be writable
(`Facts::unwritable`, `files::writable`, the script's NTFS wording in `cli::unwritable_problem`);
`built_in` and a `removed_by_patch` game off its EAX beta branch (`Facts::eax_caution`) get a WARN
line and the script's "Install anyway?" on the confirm screen, with Back first. `cli::protontricks()`
is empty when neither protontricks nor its Flatpak is installed (a Steam game then has no runner),
and because the page finds a Steam prefix in compatdata without protontricks, the install job first
checks protontricks sees it (`cli::protontricks_problem`, with the Flatpak `--filesystem` fix).
The headless `install` makes the same checks and refuses a `none_to_restore` game. A folder picked
with Ctrl-A is matched to its database game by store ID (`App::open_folder`).
A game with no EAX, or with no prefix yet and no install, gets a pop-up (`app::Notice`)
instead of its page; the no-prefix one has Check again, which opens the page once the prefix is there.
There's no Console any more: a run's steps and its finish take the choices' place
(`view::draw_run`), following the end while it runs; PgUp/PgDn scroll it once the work is over. The game's database profile isn't on this
page (it's in the games list's right pane); `Facts::summary` still serves `eax-restore status`.
F2 opens the settings screen (`src/prefs_screen.rs`): the Show and Tested filters the list
starts on (`App::apply_list_prefs`, at startup and when F2 changes them), then the player's
defaults for a new install (DSOAL and OpenAL Soft builds, DLL override, speakers, VC++ runtime) saved on
every change to `$XDG_CONFIG_HOME/eax-restore-linux/tui.json`; a pop-up sized like F1's help via `ui::centred_popup` (`src/prefs.rs`; a missing or bad
file gives the shipped defaults, and "Reset to defaults" puts them back). `Panel` starts a game
without the fix on them; an installed game opens on what it has. Tests never load the real file.
The list marks a game with the fix with a green ✓ (magenta when it isn't in the database) and
greys out the names of games not on this PC (`ui::marker`, `ui::game_line`). A name on this PC
from both Steam and GOG gets a grey `[Steam]`/`[GOG]` after it (`App::both_stores`).
Dropdowns are `view::LIST_W` wide
and scroll (`view::list_window`, PgUp/PgDn/Home/End) when longer than the screen. The
preflight's first line is the game's exe (`Facts::exe`), a FAIL when the profile's exe isn't there. Colours all come from `theme.rs`, as the list uses them. `mod.rs`
holds state and keys, `view.rs` draws, `run.rs` runs the jobs on a worker thread: steps,
details and warnings come back over a channel (`Host::step`/`detail`/`warning`, which the
install, uninstall and `ops` call as the script prints its phase tasks and results), questions
(closing a launcher, a build with no checksum) open a y/n popup and the answer goes back over
a second channel. The run ends with a `Finish`: a title, numbered next steps
(`install::next_steps`, shared with the CLI), the settings changed with their follow-ups, and
every warning recapped. Install shows `Plan::summary` (shared with `eax-restore install`) on
the confirm screen before it starts. On an installed game Apply lists the changes first and only
reinstalls for engine, builds, override, VC++, architecture, COM routing, limits or EAX Unified;
speakers and settings change in place (`engine/ops.rs`, shared with the headless commands).
`engine/installed.rs`'s `InstalledState` is what the rows start at. Enter on a game with no
folder on this PC opens the folder picker for it (`Picker::game`), and Space there opens the
page for the folder chosen (Ctrl-A's picker too). A game whose profile has no EAX to restore
(`Eax::none_to_restore`: `not_implemented`, or `removed_by_patch` without `fix_in_place`, the
script's `block_if_eax_not_implemented`) opens no page: a pop-up over the list (`App::notice`,
`ui::draw_notice`) says why, with the profile's own problem and fix text. The old action menu
is only for `EAX_RESTORE_ENGINE=bash`. Engine code stays prompt-free: read state, take
choices, plan, apply.

Headless mode (`tui/src/cli.rs`): `eax-restore status|install|uninstall|speakers|settings|sound-log
GAME_FOLDER [options]` (`eax-restore --help` lists them) runs the Rust engine with no TUI and
no Bash script: the script's defaults, flags to change them, and one "(Y/n)" before any change
(`--yes` skips it; with no terminal and no `--yes` nothing changes). A running Steam or Heroic is
only closed with `--close-launcher`. The TUI's Enter menu runs these commands
(`actions::engine_args`, `runner::run_engine`) for install, reinstall, uninstall, speakers, game
settings and sound logging, so from the TUI those use the Rust engine; VC++ and EAX Unified,
and an install with no known folder, still run the script, and `EAX_RESTORE_ENGINE=bash` sends
every action to the script. Started from a terminal with no choice given, `speakers` and
`settings` ask for it and `sound-log` switches the log the other way. `EAX_RESTORE_PROC_ROOT` (tests only) points the
launcher and game checks at an empty folder instead of `/proc`, so a test never sees or closes a
real launcher. `tui/tests/headless.rs` runs the program in the fake world: its install matches
the script's default install, and every command then the uninstall leaves the world as it was.

