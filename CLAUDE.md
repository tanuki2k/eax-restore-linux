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
caching. `known-eax-games.json` is the companion community-maintained database that
drives library scanning and install-time compatibility notes for specific titles. See
`README.md` for the full feature list and user-facing docs, and its "Contributing to
the known games database" section for the JSON schema.

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
`./build.sh`, and create a GitHub release tagged `vX.Y` with
`dist/eax-restore-linux.sh` and `eax-restore-linux.desktop` attached as assets
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
- **Validate the JSON database after editing it:** `jq empty known-eax-games.json`
- **Run the script:** `./dist/eax-restore-linux.sh` (interactive; requires `curl`, `unzip`,
  `file`, `jq`, plus `protontricks` for Steam games or `winetricks` for Heroic/GOG
  games — the script's own pre-flight check offers to install missing ones).
  `EAX_RESTORE_SKIP_PREFLIGHT=1`, `EAX_RESTORE_SKIP_CACHE_CHECK=1`, and
  `EAX_RESTORE_KNOWN_GAMES_FILE=/path/to/file.json` (point at a local JSON edit before
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
   (`DSOAL_SHARE`, `OPENAL_SHARE`, `KNOWN_GAMES_*`), pinned download URLs/SHA256s,
   `VCRUN_DLL_NAMES`, `EAX_IMPOSSIBLE_FALLBACK_STEAM`. Pure variable/array
   assignments only — safe to source before the guards run.
3. **`ui.sh`** — the text/output styling helpers (`print_banner`, `print_step`,
   `print_status`, `print_note`/`print_warning`/`print_error` and their `_arrow`
   variants, `print_wrapped`, `confirm`, plus `print_divider`/`print_line`). Sourced
   right after `globals.sh` since every helper depends on the colour vars defined
   there. See "Text/output style conventions" below.
4. **`common.sh`** — small helpers used throughout every other file: `is_truthy`,
   `is_genuine_dll`, `parse_selection`.
5. **`guards.sh`** — refuses root / Steam Gaming Mode, runs before any real work
   starts.
6. **`detection.sh`** — Steam AppID / Heroic prefix / architecture detection,
   `get_game_directory`, `detect_game_environment`, `select_architecture`, etc.
7. **`known-games.sh`** — the `known-eax-games.json` helpers:
   `ensure_known_games_json`, `scan_game_libraries`, `show_known_game_notes`,
   `confirm_continue_if_eax_impossible`, etc.
8. **`vcrun.sh`** — the standalone VC++ runtime installer: `verify_vcrun_files`,
   `install_vcrun_dependencies`, `uninstall_vcrun_dependencies`, etc. —
   independently triggerable via `EAX_RESTORE_VCRUN_ONLY`, with its own `"VCRUN"`
   manifest entries.
9. **`verify.sh`** — download verification: `verify_checksum`, `verify_or_confirm`,
   `get_asset_digest`, `confirm_unverified_download`.
10. **`cache.sh`** — `update_local_cache` (the repository-cache step), plus
    `handle_conflict` and `auto_backup_and_overwrite`.
11. **`preflight.sh`** through **`install-flow.sh`** — top-level script flow:
    pre-flight dependency check, the `EAX_RESTORE_VCRUN_ONLY` early-exit path,
    `ACTION: UNINSTALL`, `ACTION: INSTALL`. The `ACTION: INSTALL` block itself
    spans two files sharing one `if [ "$SCRIPT_ACTION" == "i" ]` — opened in
    `config-flow.sh` (Phase 1: Configuration, all the interactive prompts)
    and closed in `install-flow.sh` (Phase 2: Execution, actually deploying
    files/running protontricks/winetricks).

All of the above communicate via shared globals (from `globals.sh`, or set by one
function and read by another) rather than function parameters/return values — that
convention is unchanged from before the split and spans file boundaries same as it
previously spanned banner sections within the one file.

**Caching model:** `update_local_cache()` (the `--- REPOSITORY CACHE CHECK ---` step)
owns fetch/verify/cache for the DSOAL and OpenAL Soft binary bundles: check remote
version metadata (GitHub release `updated_at` / redirect-resolved tag) against a local
marker file, download only on change, verify integrity (`unzip -tq` + a pinned SHA256
via `verify_checksum`, or a live GitHub-published digest via `verify_or_confirm`), and
always preserve the existing cache rather than wiping it on a failed
download/verification. `known-eax-games.json` is fetched separately by
`ensure_known_games_json()` (called from `update_local_cache` and several other call
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
  `--- GAME DETAILS ---`.
- `print_step N "Label"` — the same banner wrapper for a numbered, non-dashed,
  non-bold CYAN sub-step header, e.g. `2. Launcher Identification`.
- `print_status "text" [COLOR=CYAN]` — an ` -> ` arrow sub-step/result line.
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
  confirms — a prompt that needs the raw typed value (menu numbers, free-text paths)
  still hand-rolls its own `echo -e` + `echo -e -n "> "` + `read -r`.
- `print_option N "Label" ["dim detail"]` — one ` N) Label` row of a numbered
  selection menu, plain/uncolored (the sanctioned menu-row look — don't wrap rows in
  `${WHITE}`, which renders bold). An optional third arg is appended as a
  de-emphasized ` detail` in `DIM` (e.g. `in /path/to/dir`, `(Steam)`). The caller
  still owns the menu's `${WHITE}` header line, its leading/trailing blank lines, and
  the `${YELLOW}` `Selection [...]:` prompt + `read -r` loop.
- `print_wrapped "free text"` — wraps data-sourced prose (e.g. the `notes` field in
  `known-eax-games.json`, not already hand-wrapped script text) at 76 columns and
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
  this is expected, ordinary branching (e.g. the known-games database being
  unavailable and falling back to manual entry, or reusing a stale cache while
  offline).
- `WHITE` — general prose/body text and prompts.
- `DIM` — secondary/de-emphasized text, e.g. supplementary detail alongside a primary
  status line.
- Diagnostic/warning output that shouldn't pollute stdout capture is sent to stderr
  by redirecting the call site itself (`print_status "..." >&2`, or a raw
  `echo -e ... >&2`) — used throughout `ensure_known_games_json`,
  `detect_heroic_prefix_verbose`, and similar functions whose own stdout is captured
  via `$(...)`. The helpers themselves always write to stdout; there's no separate
  `_err` helper family.
- Inline comments favor explaining *why* a non-obvious choice was made (e.g. why a
  cache is preserved on failure, why a check is memoized) over restating *what* the
  next line does — follow that tone when adding comments.
