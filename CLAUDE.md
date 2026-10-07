# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project goal

`eax-restore-linux.sh` is a single-file Bash installer that restores EAX/DirectSound3D
hardware audio in classic Windows games running under Steam/Proton or Heroic/Wine on
Linux. It deploys [DSOAL](https://github.com/kcat/dsoal) and
[OpenAL Soft](https://github.com/kcat/openal-soft) — which translate legacy EAX/A3D
calls into OpenAL — into both the game folder and the Wine/Proton prefix, with engine
choice, architecture detection, prefix/library auto-detection, conflict backups, an
install manifest for clean uninstall, and checksum-verified downloads with local
caching. `game-database.json` is the companion community-maintained database that
drives library scanning, install-time compatibility notes and the Game Settings step
(changes to a game's own config files) for specific titles. It's **generated**: each
game is edited as `<id>.json` in `data/games/tested/` (checked against a real install)
or `data/games/untested/` (not yet) — both shipped — or `data/drafts/` (never shipped),
defined by `data/schema.json`; `tools/build-game-database.sh` combines the two shipped
folders. See `README.md` for the full feature list
and user-facing docs, and its "Contributing to the game database" section for
the fields.

**Design rule: anything specific to a game or engine lives in the database, never as a
special case in the script's code** — config edits, the audio API (and so the engine),
alsoft.ini values, recommended tweaks. The script only knows how to read and edit the
six config formats (`ini`, `flat_ini`, `idtech_cfg`, `dark_cfg`, `brace_cfg`, and the binary `gadb`),
not which game needs what.

`eax-restore-linux.sh` is **not committed to the repo** — it's a generated build
artifact. Its source lives split across `src/*.sh` (one file per functional group);
`build.sh` concatenates them, in the order listed in its `COMPONENTS` array, into
`dist/eax-restore-linux.sh` (`dist/` is gitignored). Edit the relevant `src/*.sh`
file and re-run `./build.sh` to regenerate it — never hand-edit
`dist/eax-restore-linux.sh` directly. There's no other build tooling and no package
manifest — the repo is the split source, the JSON database, and their docs and
metadata (`README.md`, `CONTRIBUTING.md`, `LICENSE`, `.github/`, the `.desktop`
launcher).

End users get the script from a **GitHub Release asset**, not the repo directly —
`README.md`'s `curl` command and `eax-restore-linux.desktop`'s launcher both fetch
`.../releases/latest/download/eax-restore-linux.sh`. Cutting the **stable** release is
a manual step: bump `SCRIPT_VERSION` in `src/globals.sh`, run
`./build.sh`, generate `dist/eax-restore-linux.sh.sha256` with
`sha256sum dist/eax-restore-linux.sh > dist/eax-restore-linux.sh.sha256` (lets users
verify the download — see README's "Verifying the download"), and create a GitHub
release tagged `vX.Y` with `dist/eax-restore-linux.sh`,
`dist/eax-restore-linux.sh.sha256`, and `eax-restore-linux.desktop` attached as assets
(matching the existing `v0.28` release) — mark it as the latest release so the
`releases/latest/download/` URLs resolve to it. `SCRIPT_DATE` is **not** bumped by
hand: `build.sh` derives it from the HEAD commit date (`git show -s --format=%cs`)
at build time — a plain `vX.Y` checkout gets that tag's commit date. The
`SCRIPT_DATE="..."` literal in `src/globals.sh` is only the fallback for a build
with no git available (e.g. a source tarball); refresh it opportunistically so
those stay roughly current.

Every push to `dev` (and manual `workflow_dispatch`) instead auto-publishes a rolling
**`dev` prerelease** via `.github/workflows/dev-release.yml`: `build.sh` itself
stamps the version `<base>-dev` (base from `src/globals.sh`, triggered by
`GITHUB_REF_NAME=dev`) and puts the commit date + short SHA in the date field, then
the workflow updates the single `dev`-tagged release in place
with `dist/eax-restore-linux.sh` attached. It's marked `--prerelease` so
`releases/latest` keeps resolving to the stable `vX.Y`, and the workflow fails if that
ever stops holding. The `dev` prerelease never carries the `.desktop` launcher (the
launcher hardcodes `releases/latest`).

## Commands

- **Rebuild after editing anything in `src/`:** `./build.sh` (writes
  `dist/eax-restore-linux.sh`). By default it stamps the assembled output's
  `SCRIPT_VERSION`/`SCRIPT_DATE` from the checkout: a `dev`/feature branch gets
  `<base>-dev` + `<commit-date> build g<sha>` (`-dirty` appended when the tree has
  uncommitted changes), `main` or a `vX.Y` tag gets the clean base version +
  `<commit-date>`, and a git-less checkout leaves the `src/globals.sh` literals
  untouched. Setting `BUILD_VERSION=` and/or `BUILD_DATE=` in the environment
  overrides the corresponding stamp (assembled output only, never
  `src/globals.sh`) — handy locally; the `dev` workflow no longer needs them.
- **Syntax-check after any edit:** `bash -n dist/eax-restore-linux.sh`
- **Shellcheck (if installed):** `shellcheck dist/eax-restore-linux.sh`
- **After editing the database** (`data/games/{tested,untested}/*.json` or
  `data/drafts/*.json`, never `game-database.json` directly): `tools/format-game-database.sh` (canonical key order, empty/default fields
  dropped), then `tools/build-game-database.sh` (regenerates `game-database.json`).
  CI (`.github/workflows/game-database.yml`) runs `check-jsonschema --schemafile
  data/schema.json` over all three folders plus both scripts' `--check` modes; the build
  also fails if a game's file name is in more than one folder.
  `tools/probe-game.sh` (dev-only, read-only towards the game) finds what a new
  game setting should change: `scan <game dir> [prefix]` lists config files with
  line endings, setting names in the exes, the bundled OpenAL and Miles 3D
  providers; `snap <name> [<game dir> [prefix]]` copies the config files into
  numbered snapshots under `~/.cache/eax-probe/<name>/`, and `diff <name>` shows
  what changed between the last two. Snap before the first launch, after
  quitting at the main menu (defaults), and after switching the option in-game.
  `tools/browse-game-database.sh [file]` (needs fzf) browses the built
  database with the Tools menu's browser — a quick look at how an entry's
  profile reads. `tools/migrate-v2-to-v3.sh` is the one-off that split the old single-file (schema 2)
  database; kept for reference only.
- **Run the script:** `./dist/eax-restore-linux.sh` (interactive; requires `curl`, `unzip`,
  `file`, `jq`, plus `protontricks` for Steam games or `winetricks` for Heroic/GOG
  games — the script's own pre-flight check offers to install missing ones).
  `EAX_RESTORE_SKIP_PREFLIGHT=1`, `EAX_RESTORE_SKIP_CACHE_CHECK=1`, and
  `EAX_RESTORE_GAME_DATABASE_FILE=/path/to/file.json` (point at a local JSON edit before
  it's pushed) are useful when iterating — see the script's own
  `--- Environment Variables ---` header comment for the full list.
- There is no test suite or CI test job; verification is manual (`bash -n`, running the
  install/uninstall flow against a real game prefix, checking `README.md` and the
  script's own header/inline docs stay in sync with behavior changes).

## Architecture

The source is split across `src/*.sh`, one file per functional group, listed here in
the order `build.sh` concatenates them into `dist/eax-restore-linux.sh` (which is also
their execution order in the assembled script):

1. **`header.sh`** — shebang + top header comment block: features list and the
   authoritative list of `EAX_RESTORE_*` env vars. Keep this in sync with
   `README.md`'s Environment Variables table whenever a var is added/changed — every
   existing var should be documented in both places.
2. **`globals.sh`** — `SCRIPT_VERSION`, colour vars, `BASE_SHARE` and friends
   (`DSOAL_SHARE`, `OPENAL_SHARE`, `GAME_DATABASE_*`), pinned download URLs/SHA256s,
   `VCRUN_DLL_NAMES`, `EAX_IMPOSSIBLE_FALLBACK_STEAM`. Pure variable/array
   assignments only — safe to source before the guards run.
3. **`args.sh`** — `-h`/`--help` and `-v`/`--version` command-line flag handling
   (exits before anything else runs). Only needs `globals.sh`'s `SCRIPT_VERSION`/
   `SCRIPT_DATE`/colour vars, not the `ui.sh` helpers. Keep its `--help` env-var
   summary in sync with `header.sh`/`README.md` the same way those two are kept
   in sync with each other.
4. **`ui.sh`** — the text/output styling helpers (`print_banner`, `print_step`,
   `print_status`, `print_note`/`print_warning`/`print_error` and their `_arrow`
   variants, `print_wrapped`, `confirm`, `read_answer`, plus `print_divider`/`print_line`). Sourced
   right after `globals.sh` since every helper depends on the colour vars defined
   there. See "Text/output style conventions" below. Also `checklist_select`, the
   tick list (↑/↓, Space, Enter; Esc cancels and returns 1) for picking any of
   several items: the optional game settings and uninstall's settings to put
   back. Use it for any new multi-pick. `CHECKLIST_INITIAL` sets the starting
   ticks and `CHECKLIST_DETAILS` gives each item a body drawn under its box. It
   draws to `/dev/tty` so the run log only gets the final list, falls back to
   titles-only boxes when the list doesn't fit the terminal, and to a numbered
   "type the numbers" prompt when stdin isn't a terminal.
5. **`common.sh`** — small helpers used throughout every other file: `is_truthy`,
   `is_genuine_dll`, `parse_selection`, `is_steamos`, `install_packages` (apt /
   pacman / dnf via sudo; pre-flight and the fzf offer).
6. **`guards.sh`** — refuses root / Steam Gaming Mode, runs before any real work
   starts.
7. **`detection.sh`** — Steam AppID / Heroic prefix / architecture detection,
   `get_game_directory`, `detect_game_environment`, `select_architecture`, etc.
8. **`game-database.sh`** — the `game-database.json` helpers:
   `ensure_game_database`, `scan_game_libraries`, `show_game_details_block`
   (the install's GAME PROFILE: sets `PROFILE_API`/`PROFILE_PATCHES` and the
   recommended tweaks, then draws it with `print_game_profile`, which only
   prints: a one-store wrapper around `print_game_profile_stores`, which
   takes one or more `<store>:<id>` entries of a game; both screens show
   `released` via `format_release_date`, and without a location (the
   browser) it adds a `<Store> ID` row per store and opens with the game's
   `description`), `browse_game_database` (Tools → [B]rowse game profiles and
   `tools/browse-game-database.sh`: one fzf row per game from
   `browse_game_rows`; the preview, `browse_game_preview`, draws one
   `print_game_profile_stores` covering every store entry that passes the
   filters (what they share once, what differs per store; no banner: the pane's label names
   it), run in a new shell from a `declare -f` dump, or with Tab
   `print_game_settings_details`, or with F1 `browse_help`; both read
   `browse_game_stores`, which applies the Ctrl-S / Ctrl-A store (Steam,
   GOG, or delisted from either or one) and audio (API or EAX version)
   filters. The keys' state
   (filters, view, help, order, layout) is one temp file that
   `browse_state_next` updates; Ctrl-R is fzf's `toggle-sort` (`--tiebreak
   index` otherwise); Ctrl-L swaps the right pane between beside the list
   (`BROWSE_SIDE_PERCENT` of the width) and under it, and
   `browse_filter_header` refits the Filters box (three filters on one, two
   or three lines, by the list's width) through
   `transform-header` after every key and resize; Enter and double-click are
   ignored, so only Esc and fzf's abort keys close it;
   Ctrl-F is `browse_zoom` (the pane in `less -R`). Needs fzf 0.35
   (`fzf_at_least`). 0.58+ gets the boxed sections and runs with
   `--height=-1` on the alternate screen, so `browse_key_bar` can draw the
   key bar and version on the last row; older fzf puts the bar on a border
   line and the filters in four `--header-lines` (`BROWSE_HEADER_LINES`)),
   `confirm_continue_if_eax_impossible`, etc.
9. **`game-config.sh`** — the Game Settings feature: `config_get_key` /
   `config_set_key` (awk readers/writers for the five text config formats, keeping CRLF,
   key spelling and spacing, plus `_gadb_find`/`_gadb_set`, which switch an on/off
   setting in place in Monolith's binary `gadb` profile), `resolve_config_file`, `print_game_settings_details` (the database browser's Tab view: every setting's reason, file, keys and values, via `load_game_config_rows` and `print_config_rows` with `__ANY__` for the unknown current value), `offer_alsoft_settings` (step 8),
   `game_settings_step` (step 11), `apply_game_settings` (Phase 2, writes `CONFIG:`
   manifest lines), `print_game_settings_summary`, `revert_game_settings`
   (uninstall step 7). All of it driven by the entry's `game_config` /
   `install.alsoft_ini`. The speaker step lives here too, shared by install
   step 8 and Tools → Speaker configuration: `ask_speaker_configuration` (the
   questions), `speaker_alsoft_values` (answers → alsoft.ini values),
   `speaker_label` and `speaker_config_from_alsoft` (reads them back). The Tools
   items change an installed game through `game_settings_step`'s two modes
   (`GAME_SETTINGS_SPEAKERS_ONLY`, `GAME_SETTINGS_EDIT_OPTIONAL`) and
   `update_game_settings_in_manifest`, which puts settings back and rewrites the
   manifest the way a reinstall does.
10. **`launcher-config.sh`** — step 10's DLL override via the launcher: reads and
   writes Steam's `localconfig.vdf` launch options (awk, scoped to the game's block
   under `UserLocalConfigStore/Software/Valve/Steam/apps`) and Heroic's
   `GamesConfig/<app>.json` `enviromentOptions` (jq), merging into any existing
   `WINEDLLOVERRIDES`; `choose_override_method` (step 10's launcher / registry /
   manual menu, launcher first), `apply_launcher_override` (Phase 2, writes `LAUNCHER:` manifest
   lines), `revert_launcher_overrides` (uninstall step 5). Both launchers keep these
   files in memory, so before writing, `offer_close_launcher` offers to close the
   copy that owns the file (`launcher_kind`: native/AppImage or Flatpak, from the
   file's path) and `reopen_launchers` starts it again afterwards; declining, a
   running game, or a timeout falls back to waiting for the player to close it.
   Those messages name the change through `LAUNCHER_CHANGE` (empty: the DLL
   override; `dsoal_log`: DSOAL logging). Also holds the DSOAL logging helpers
   (`launch_options_with_dsoal_log` / `_without_`, `heroic_get_env` /
   `heroic_set_env`); uninstall's revert ignores and drops those variables.
11. **`vcrun.sh`** — the standalone VC++ runtime installer: `verify_vcrun_files`,
   `install_vcrun_dependencies`, `uninstall_vcrun_dependencies`, etc. —
   independently triggerable via `EAX_RESTORE_VCRUN_ONLY`, with its own `"VCRUN"`
   manifest entries.
12. **`verify.sh`** — download verification: `verify_checksum`, `verify_or_confirm`,
    `get_asset_digest`, `confirm_unverified_download`.
13. **`cache.sh`** — `update_local_cache` (the repository-cache step), plus
    `handle_conflict` and `auto_backup_and_overwrite`.
14. **`preflight.sh`** through **`install-flow.sh`** — top-level script flow:
    pre-flight dependency check, the main menu and the `EAX_RESTORE_VCRUN_ONLY`
    early-exit path (`vcrun-only-flow.sh`), Tools → DSOAL logging
    (`dsoal-log-flow.sh`, another early exit), Tools → Optional settings /
    Speaker configuration (`settings-flow.sh`, which identifies the game from
    its own folder with `identify_game_dir` and the prefix from the manifest,
    so it has no launcher step), `ACTION: UNINSTALL`, `ACTION: INSTALL`. The `ACTION: INSTALL` block itself
    spans two files sharing one `if [ "$SCRIPT_ACTION" == "i" ]` — opened in
    `config-flow.sh` (Phase 1: Configuration, all the interactive prompts)
    and closed in `install-flow.sh` (Phase 2: Execution, actually deploying
    files/running protontricks/winetricks). Around all of that, a `while true`
    loop opened just above the main menu in `vcrun-only-flow.sh` and closed
    (`break; done`) at the bottom of `install-flow.sh` lets install step 1 go
    back to the main menu: when the menu was shown (`MAIN_MENU_SHOWN`), a "no"
    while picking a game sets `RESTART_REQUESTED` and the steps 1-2 loop does
    `continue 2`. Uninstall, VC++ runtime install and DSOAL logging keep step
    1's own menu, which then offers "[R]eturn to the main menu" the same way.
    The Tools items go back to the Tools menu instead (`OPEN_TOOLS_MENU`, set
    before each way out short of finishing; their [R]eturn label comes from
    `return_menu_label`). `config-flow.sh` also defines
    `print_choices_summary`, the recap of every Phase 1 answer shown under
    "Configuration finished!" before the "Proceed?" — a new Phase 1 question
    should add its answer there. `uninstall-flow.sh` follows the
    same split in one file: Phase 1 (steps 1-7) only asks and records answers
    (e.g. `choose_game_settings_to_revert`, `ask_close_launcher_early`), then
    one "Proceed?" and Phase 2 makes every change under the phase progress bar.
    Keep new uninstall questions in Phase 1.

All of the above communicate via shared globals (from `globals.sh`, or set by one
function and read by another) rather than function parameters/return values — that
convention is unchanged from before the split and spans file boundaries same as it
previously spanned banner sections within the one file.

**Caching model:** nothing is downloaded up front. `check_download_readiness()` (start
of the install) only probes GitHub, and stops early when it's offline with no OpenAL
Soft cached. Step 6's `choose_builds()` asks Stable / Latest / each separately, then
`ensure_dsoal_build()` / `ensure_openal_build()` fetch just the chosen builds: check
remote version metadata (release `updated_at`, the redirect-resolved tag, or the newest
`archive` asset while `latest-master` is missing upstream) against a local marker,
download only on change, verify integrity (`unzip -tq` + the pinned SHA256 via
`verify_checksum`, or a live GitHub-published digest via `verify_or_confirm`), and keep
the existing cache on a failed download. Stable DSOAL is the pinned
`DSOAL_PINNED_REV` (`src/globals.sh`): advancing it after testing a newer archive build
is part of the release routine. `game-database.json` is fetched separately (on dev, from the
`dev` branch and cached as `game-database.v3.json`, since schema 3 only exists there
until 0.29 merges) by
`ensure_game_database()` (called on demand from step 1's scan and several other call
sites — memoized per run) — it deliberately always fetches fresh (no staleness check)
since it's a small, community-edited file where PRs should take effect immediately,
unlike the large versioned binary bundles; a fetch failure falls back to the last
cached copy.

**Manifest-driven uninstall:** installs write a manifest of every file/registry key
they touched; when a manifest exists, uninstall only ever removes what's in it and
restores the timestamped backups made at install time. If no manifest is found (e.g.
an install predating this mechanism), uninstall falls back to a best-effort scan for
known filenames (`dsound.dll`, `dsoal-aldrv.dll`, `OpenAL32.dll`, etc.) — a last resort
that's less precise than the manifest path, so avoid removing/renaming the manifest
mechanism itself.
The manifest (`.eax-restore-manifest.txt` in the game's exe folder) is plain
text, one line per change: a deployed file's path, `VCRUN`, `REGISTRY:…`,
`LAUNCHER:…` or `CONFIG:…` (tab-separated). New manifests start with
`MANIFEST_HEADER` ("# EAX Restore manifest, format 1", written by
`start_manifest`); older ones have no header and the same lines, and every
reader skips `#` lines. After an uninstall the whole file is the "# EAX
Restore: uninstalled …" marker. Uninstall's and Tools' game list is built from
the live manifests on disk (`find_installed_game_dirs`: Steam libraries and
Heroic's game folders) — `$XDG_STATE_HOME/eax-restore-linux/installed-games.txt`
only stores its most-recently-used order (`note_game_used`,
`installed_game_dirs`).

## Text/output style conventions

All user-facing output goes through `echo -e` with the colour vars defined in
`globals.sh` (`GREEN`, `YELLOW`, `CYAN`, `WHITE`, `BOLD`, `DIM`, `NOTE`, reset via
`NC`) — there's no other formatting mechanism (no `tput`, no external color library).
The recurring shapes built from those vars — banners, prompts, arrow sub-steps,
Note:/Warning:/Error: messages, wrapped prose — are centralized as helper functions in
`ui.sh`; **use the helper for any of the shapes below instead of hand-rolling the
`echo -e` sequence.** Preflight through the Stage 2 "Launcher Identification" step
(`preflight.sh`, `config-flow.sh` header/steps, `get_game_directory`/
`detect_game_environment` in `detection.sh`) is the canonical example of the helpers
in use — match its look when extending any of these flows. The rest of the script is
still being migrated onto these helpers incrementally; a raw `echo -e "...${COLOR}"`
call site elsewhere in `src/` is a pre-migration leftover, not a second sanctioned
style — convert it to the matching helper when you touch it, rather than copying it
for a new call site.

- `print_banner "LABEL" [COLOR=GREEN]` — the `--- LABEL ---` section banner (blank
  line, divider, bold label, divider, blank line), e.g. `--- PHASE 1: CONFIGURATION ---`,
  `--- GAME PROFILE ---`.
- `print_step N "Label"` — the same banner wrapper for a numbered, non-dashed,
  non-bold CYAN sub-step header, e.g. `2. Launcher Identification`.
- `print_status "text" [COLOR=CYAN]` — an ` -> ` arrow sub-step/result line.
- `print_detected "Label" "value"` — the ` -> Label: value` line (label in GREEN)
  reporting what auto-detection found, right before the `confirm` asking whether
  to use it, e.g. `Detected Prefix:`, `Detected Architecture:`.
- `print_task "text"` — the `\n${CYAN}STATUS: text...${NC}` header announcing a chunk
  of work about to run (a scan, a download, a deploy step). Own leading blank line;
  the trailing `...` is added by the helper, so pass just the phrase. A capturing
  call site redirects itself (`print_task "..." >&2`).
- `print_note "text" ["more text" ...]` / `print_warning "..."` / `print_error "..."`
  — standalone-paragraph `Note:`/`Warning:`/`Error:` messages (each argument is one
  already-wrapped physical line; the helper colors and joins them without
  reflowing). `print_note_arrow`/`print_warning_arrow`/`print_error_arrow` are the
  ` -> `-prefixed inline sub-step forms of the same three. These standalone forms
  always emit their own leading blank line, which is exactly the one blank line of
  separation wanted after a `print_banner`/`print_step` header (those no longer emit
  a trailing blank of their own) — so a `Note:`/`Warning:`/`Error:` message right
  after a step header uses the helper directly, same as anywhere else.
- `confirm "Question?" [default=Y|N]` — the two-line `(Y/n)`/`(y/N)` prompt (question
  line, then a separate `"> "` read line), returns 0/1. Only for actual yes/no
  confirms.
- `confirm_countdown "Question?" [default=Y|N] [seconds=25]` — `confirm` that
  counts down on the `"> "` line (`(Yes in 25s)`) and takes the default when
  nothing is typed, setting `CONFIRM_TIMED_OUT=1` so the caller can say so. Only
  for a default that's safe to act on unattended (closing a launcher with no
  game running, in `offer_close_launcher` / `ask_close_launcher_early`).
  Non-tty input falls back to plain `confirm`.
- `prompt "question text: "` — the non-yes/no counterpart of `confirm`: a leading
  blank line, the `${YELLOW}` question line, then the separate `"> "` read line — but
  **no `read`**, because these call sites need the raw typed value (menu numbers,
  free-text paths) and loop on their own validation. The caller still writes its own
  `read_answer VAR` right after. (Hand-rolled `(y/N)` prompts that predate `confirm` are
  a separate migration — leave those for a dedicated pass.)
- `read_answer VAR` — use instead of a bare `read -r VAR` for every user answer
  (prompts, menus, free-text paths). The terminal's own echo of typed keys never
  reaches the run log, so this replays the answer into it (see its comment in
  `ui.sh`); a bare `read -r` leaves the answer out of bug-report logs.
- `print_option N "Label" ["dim detail"]` — one ` N) Label` row of a numbered
  selection menu, plain/uncolored (the sanctioned menu-row look — don't wrap rows in
  `${WHITE}`, which renders bold). An optional third arg is appended as a
  de-emphasized ` detail` in `DIM` (e.g. `in /path/to/dir`, `(Steam)`). The caller
  still owns the menu's `${WHITE}` header line, its leading/trailing blank lines, and
  the `${YELLOW}` `Selection [...]:` prompt + `read_answer` loop.
- `tilde_path "text"` — shortens every `$HOME/...` path in the text to `~/...` for
  display. Every helper above and below already runs its text through it, so only a
  raw `echo -e`/`printf` that prints a path needs to call it itself
  (`"$(tilde_path "$GAME_DIR")"`). Display only — keep the real path in variables.
- `print_wrapped "free text"` — wraps data-sourced prose (e.g. the `notes` field in
  `game-database.json`, not already hand-wrapped script text) at 76 columns
  (`WRAP_COLUMNS` overrides it, for the browser's narrower preview) and
  indents it, in WHITE. Don't hardcode line breaks into stored data; wrap at render
  time instead.

Color meaning, unchanged by the helpers:

- `CYAN` — section headers and "in progress" status lines (e.g. `Checking ...`).
- `GREEN` — success (`Done.`, `Up to date [...]`, `Loaded (...)`.).
- `YELLOW` (always bold — the var itself carries `\033[1;33m`) — warnings, errors, and
  every `(Y/n)`/`(y/N)` prompt. Reserved for things that want the user's attention;
  don't use it for routine/expected branching (that's `NOTE`, below).
- `Error: ` (`YELLOW`) prefixes a message where something the script tried genuinely
  failed and there's no further fallback left for that capability this run (a required
  download/verification fails with no usable cache, a hard dependency is missing,
  etc.).
- `Warning: ` is always bold YELLOW, in both its standalone-paragraph form (gating a
  following `(y/N)`/`(Y/n)` prompt, e.g. "No .exe files were found...") and its
  inline ` -> `-prefixed arrow sub-step form — `print_warning`/`print_warning_arrow`
  keep the two visually identical on purpose.
- `Note: ` (`NOTE`, a dedicated bright-blue, non-bold color — deliberately not in the
  `YELLOW` family) prefixes a routine "the preferred path wasn't available, here's the
  automatic fallback" notice — distinct from `Warning:`/`Error:` (something to flag or
  that failed) and from the `YELLOW` `(Y/n)` prompts themselves: nothing is broken,
  this is expected, ordinary branching (e.g. the game database being
  unavailable and falling back to manual entry, or reusing a stale cache while
  offline).
- `WHITE` — general prose/body text and prompts.
- `DIM` — secondary/de-emphasized text, e.g. supplementary detail alongside a primary
  status line.
- Diagnostic/warning output that shouldn't pollute stdout capture is sent to stderr
  by redirecting the call site itself (`print_status "..." >&2`, or a raw
  `echo -e ... >&2`) — used throughout `ensure_game_database`,
  `detect_heroic_prefix_verbose`, and similar functions whose own stdout is captured
  via `$(...)`. The helpers themselves always write to stdout; there's no separate
  `_err` helper family.
- Inline comments favor explaining *why* a non-obvious choice was made (e.g. why a
  cache is preserved on failure, why a check is memoized) over restating *what* the
  next line does — follow that tone when adding comments.

## Writing style conventions

The section above covers *mechanics* — which helper/color to use. This one covers
*wording*: the tone and voice established over many past commits for the two kinds
of prose in this repo, `game-database.json`'s free-text fields and the script's
own user-facing strings. Neither is enforceable by a linter, so match the examples
below when writing or editing either.

**Database prose fields** (`notes`, `store_details`, `patches`, `eax.problem`,
`eax.fix`, `description`, and a game setting's `title`, `reason` and `follow_up` — see README's "Contributing
to the game database" for what belongs in which field):

- Keep each field to its one job; don't restate content that belongs in a sibling
  field just because it's related to the same title.
- State the game/build fact and let the script's own output explain what it does
  with it — don't write "DSOAL", "OpenAL Soft", "paths", or "intercepts" into data
  fields.
- Frame a community patch/reimplementation as a legitimate alternative worth using,
  not an inferior fallback to apologize for (e.g. OldUnreal's OpenAL renderer).
- Write each store's `store_details`/`patches` prose to stand on its own — never
  reference "the other store's block" or "the Steam version" from within a
  different store's block, since a user only ever sees one block at a time.
- State only what's actually verified, and say exactly what was checked — avoid
  hedge words ("probably", "should") where a concrete fact is possible, and don't
  imply an install was checked locally if it wasn't. In `store_details`, `notes`,
  `patches` and `eax.problem`/`eax.fix` — shown on the game profile screen,
  above its Sources section — cite a source in parentheses when the claim is
  non-obvious, e.g. "(per PCGamingWiki)", and put its page in `sources`. Never in a
  game setting's `title`, `reason` or `follow_up` (see below).
- Be concrete and current rather than generic — name the actual tweak label,
  mission, mod, or date — but keep each note to 1-3 sentences confined to its
  field's job; don't pad it with everything known about the title.
- `description` (browser only) is one sentence in PCGamingWiki's pattern, own
  words, starting with the entry's exact `name`: modes, perspective, genres, "in
  the <series> series" — e.g. "Thief Gold is a singleplayer first-person stealth
  and immersive sim game in the Thief series." No opinions, no EAX talk (the
  profile covers that); a bundle names its expansions; leave out a mode or
  perspective you can't confirm. `released` is the first Windows release,
  earliest region, checked against two sources; bundles/Gold/Complete/GOTY/Classic
  take the base game's date, Enhanced Editions/Remasters/Anniversary editions
  their own; never a store's listing date.
- A `notes` entry in practice: short, plain prose (no markdown), em-dashes for
  parenthetical asides, occasionally addressing the user directly in a conditional
  ("If you also own the classic build..."), one caveat or fact per note. E.g.
  "Bloodlines isn't documented (per PCGamingWiki) as having hardware EAX... That's
  expected, not a fault."

**Game setting `title` and `reason`** (`game_config.audio_settings` / `optional_settings`).
They automate a change the player would otherwise make by hand. Players
see these in the Game Settings step, directly above rows showing each file, setting,
and its current → new value, read live from their own install.

`title`:
- A fixed verb + the result: **Enable** for a feature that's off, **Fix** for a bug,
  **Remove** for something unwanted, **Raise** for a quality level. Sentence case, no
  full stop, about 5 words at most.
- Name the result the player gets, not the setting (`Enable EAX reverb`, not
  `Set UseEAX to True`), even when the setting changes several keys — the rows list
  them.
- Reuse the same title for the same result across games.
- Don't repeat the game name; the step's header already shows it.

`reason`:
- One sentence, or two short ones: what the game does out of the box, and what that
  costs the player where it isn't obvious.
- Start with the game's name. Name concrete files the game itself uses (e.g.
  `DefOpenAL32.dll`). When the game passes over a file the script installs, name
  that file and say the script installs it ("the OpenAL32.dll this script
  installs"), but never name the script's own parts (DSOAL, OpenAL Soft).
- Be specific: never "any other" or "the other one"; name what it's chosen over
  ("loads its bundled DefOpenAL32.dll instead of the OpenAL32.dll this script
  installs").
- Don't restate setting names, values or paths already shown in the rows, and don't
  cite where a default was checked — the row's current value proves it. Never cite a
  source in a reason ("(per PCGamingWiki)" and the like): players read it at the
  Game Settings step, where they can't see or check it. A claim that needs a source
  gets its page in `sources`, which the game profile screen lists.
- Plain English for effects ("muffling of sounds through walls", not "occlusion").
  Game menu labels may be quoted when they help a player find the same option in-game.
- Only state what's verified by a real install, the game's own docs, or a source in
  `sources`.

Examples:
- `Enable EAX reverb` — "Brothers in Arms ships with EAX and 3D sound off and loads its
  bundled DefOpenAL32.dll instead of the OpenAL32.dll this script installs."
- `Enable EAX effects` — "Quake 4 ships with its EAX sound options off, so there's no
  reverb and no muffling of sounds through walls."
- `Fix low-res textures` — "Quake 4 can't detect how much memory modern graphics cards
  have, so it loads its lowest-resolution textures."
- `Enable underwater reverb` — "Some System Shock 2 maps don't mark their underwater
  areas, so they play the wrong reverb there."

**Script user-facing strings** (banners, `Note:`/`Warning:`/`Error:` messages,
prompts — see "Text/output style conventions" above for which helper/color to use):

- Prefer natural, polite, causal prose over log/debug-style boilerplate. Rewrite
  mechanical fragments into a conversational phrasing of the same information,
  e.g. `"Invalid selection. Please type 1, 2, or 3."` →
  `"That's not a valid option — please type 1, 2, or 3."`, or a bare
  `"Conflict: $(basename "$target_file")"` header → a question,
  `"What would you like to do? [B]ackup & overwrite (default), [o]verwrite, [s]kip:"`.
- Join cause and effect with a contraction and a causal "so" clause instead of two
  clipped declarative sentences, e.g.
  `"...checksum verification. This engine will be unavailable this run."` →
  `"...checksum verification, so this engine will be unavailable this run."`
- Explain jargon in plain English instead of using the internal term, e.g.
  `"installing DSOAL here would be a functional no-op"` →
  `"installing DSOAL here wouldn't do anything — there's nothing for it to hook
  into"`.
- Don't refer to steps the user hasn't reached yet or to the tools behind them
  ("the registry and winetricks steps") — someone running the script for the
  first time can't know what those are. Say what the choice means for their
  game instead, e.g. `"Use this detected runner for the registry and winetricks
  steps?"` → `"Use the same Wine version Heroic launches $GAME_NAME with?"`.
- When something the script needs doesn't exist yet — a Wine/Proton prefix, the
  launcher's saved settings for the game, a game config file it writes on first
  launch — never tell the player to finish and run the script again. Do what the
  prefix step (`src/detection.sh`) does: say what's missing and why ("If you just
  installed …, it creates … the first time it runs."), ask them to launch the game
  at least once and close it, then `confirm "Check … again?"` — Yes looks again,
  No carries on without whatever needed it.
- Name the actual subject instead of a generic stand-in wherever the variable is
  available — the real game name instead of "this edition", `$GAME_NAME`'s prefix
  instead of "this prefix".
- Trim explanatory copy down to the fact and its concrete, relatable consequence
  rather than a throat-clearing reasoning paragraph, e.g. "will silently fail to
  load the custom audio engine" → "the game will crash without showing an error
  message".
- When the script detects a problem, state the problem and offer the fix — don't
  explain what the script would otherwise fail to do. E.g. step 8's
  `"Deus Ex's reverb is quiet at the default level."` + `"Raise the reverb boost to
  +6 dB? (Y/n)"`, not a paragraph about why an unboosted reverb goes unnoticed.
