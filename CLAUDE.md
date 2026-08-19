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
`.../releases/latest/download/eax-restore-linux.sh`. Cutting a release is a manual
step (no CI automation exists for it yet): bump `SCRIPT_VERSION`/`SCRIPT_DATE` in
`src/globals.sh`, run `./build.sh`, and create a GitHub release tagged `vX.Y` with
`dist/eax-restore-linux.sh` and `eax-restore-linux.desktop` attached as assets
(matching the existing `v0.28` release) — mark it as the latest release so the
`releases/latest/download/` URLs resolve to it.

## Commands

- **Rebuild after editing anything in `src/`:** `./build.sh` (writes
  `dist/eax-restore-linux.sh`)
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
3. **`common.sh`** — small helpers used throughout every other file:
   `print_divider`/`print_line`/`is_truthy`, `is_genuine_dll`, `parse_selection`.
4. **`guards.sh`** — refuses root / Steam Gaming Mode, runs before any real work
   starts.
5. **`detection.sh`** — Steam AppID / Heroic prefix / architecture detection,
   `get_game_directory`, `detect_game_environment`, `select_architecture`, etc.
6. **`known-games.sh`** — the `known-eax-games.json` helpers:
   `ensure_known_games_json`, `scan_game_libraries`, `show_known_game_notes`,
   `confirm_continue_if_eax_impossible`, etc.
7. **`vcrun.sh`** — the standalone VC++ runtime installer: `verify_vcrun_files`,
   `install_vcrun_dependencies`, `uninstall_vcrun_dependencies`, etc. —
   independently triggerable via `EAX_RESTORE_VCRUN_ONLY`, with its own `"VCRUN"`
   manifest entries.
8. **`verify.sh`** — download verification: `verify_checksum`, `verify_or_confirm`,
   `get_asset_digest`, `confirm_unverified_download`.
9. **`cache.sh`** — `update_local_cache` (the repository-cache step), plus
   `handle_conflict` and `auto_backup_and_overwrite`.
10. **`preflight.sh`** through **`install-flow.sh`** — top-level script flow:
    pre-flight dependency check, the `EAX_RESTORE_VCRUN_ONLY` early-exit path,
    `ACTION: UNINSTALL`, `ACTION: INSTALL`.

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

All user-facing output goes through `echo -e` with the colour vars defined near the
top of the script (`GREEN`, `YELLOW`, `CYAN`, `WHITE`, `BOLD`, `DIM`, `NOTE`, reset via
`NC`) — there's no other formatting mechanism (no `tput`, no external color library).
Match existing usage rather than introducing new colors or styles:

- `CYAN` — section headers and "in progress" status lines (e.g. `Checking ...`).
- `GREEN` — success (`Done.`, `Up to date [...]`, `Loaded (...)`.).
- `YELLOW` (always bold — the var itself carries `\033[1;33m`) — warnings, errors, and
  every `(Y/n)`/`(y/N)` prompt. Reserved for things that want the user's attention;
  don't use it for routine/expected branching (that's `NOTE`, below).
- `Error: ` (`YELLOW`) prefixes a message where something the script tried genuinely
  failed and there's no further fallback left for that capability this run (a required
  download/verification fails with no usable cache, a hard dependency is missing,
  etc.).
- `Warning: ` is `YELLOW` when it's a standalone paragraph-level message that gates a
  following `(y/N)`/`(Y/n)` prompt (e.g. "No .exe files were found..."), and `YELLOW`
  without the surrounding paragraph spacing when it's an inline ` -> `-prefixed
  sub-step result line with no prompt following it — match whichever of the two shapes
  the new `Warning:` line is.
- `Note: ` (`NOTE`, a dedicated bright-blue, non-bold color — deliberately not in the
  `YELLOW` family) prefixes a routine "the preferred path wasn't available, here's the
  automatic fallback" notice — distinct from `Warning:`/`Error:` (something to flag or
  that failed) and from the `YELLOW` `(Y/n)` prompts themselves: nothing is broken,
  this is expected, ordinary branching (e.g. the known-games database being
  unavailable and falling back to manual entry, or reusing a stale cache while
  offline). Keeping `Note:` out of the yellow family entirely is intentional — it
  previously shared `YELLOW` with prompts and warnings, which made advisory notices
  visually indistinguishable from things that actually needed attention.
- `WHITE` — general prose/body text and prompts.
- `DIM` — secondary/de-emphasized text, e.g. supplementary detail alongside a primary
  status line.
- Section banners use `print_divider` + a `${GREEN}${BOLD}--- LABEL ---${NC}` line +
  `print_line`, matching the existing `--- REPOSITORY CACHE CHECK ---`,
  `--- PHASE 1: CONFIGURATION ---`, etc.
- Sub-step results use the ` -> ` arrow prefix (e.g. `" -> ${GREEN}Done.${NC}"`).
- Diagnostic/warning output that shouldn't pollute stdout capture is sent to stderr
  (`>&2`) — used throughout `ensure_known_games_json` and similar helper functions.
- Free-text prose sourced from data (e.g. the `notes` field in
  `known-eax-games.json`) is word-wrapped at display time to 76 columns via
  `fold -s -w 76`, then indented — see `show_known_game_notes`. Don't hardcode
  line breaks into stored data; wrap at render time instead.
- Inline comments favor explaining *why* a non-obvious choice was made (e.g. why a
  cache is preserved on failure, why a check is memoized) over restating *what* the
  next line does — follow that tone when adding comments.
