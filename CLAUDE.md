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

There are no other source files, no build step, and no package manifest — the repo is
the script, the JSON database, and their docs (`README.md`, `CONTRIBUTING.md`,
`.github/`).

## Commands

- **Syntax-check after any edit:** `bash -n eax-restore-linux.sh`
- **Shellcheck (if installed):** `shellcheck eax-restore-linux.sh`
- **Validate the JSON database after editing it:** `jq empty known-eax-games.json`
- **Run the script:** `./eax-restore-linux.sh` (interactive; requires `curl`, `unzip`,
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

The script is a linear, banner-delimited sequence of sections (search for
`# ====...====` dividers), roughly:

1. **Header comment block** (top of file) — features list and the authoritative list
   of `EAX_RESTORE_*` env vars. Keep this in sync with `README.md`'s Environment
   Variables table whenever a var is added/changed — every existing var is documented
   in both places.
2. **Constants & globals** — `BASE_SHARE` and friends (`DSOAL_SHARE`, `OPENAL_SHARE`,
   `KNOWN_GAMES_*`), pinned download URLs/SHA256s, colour vars, `print_divider`/
   `print_line`/`is_truthy` helpers.
3. **Function definitions** — detection (Steam AppID, Heroic prefix, architecture),
   verification (`verify_checksum`, `verify_or_confirm`, `get_asset_digest`), the
   `update_local_cache` repository-cache step, install/uninstall logic, and the
   `known-eax-games.json` helpers (`ensure_known_games_json`, `scan_game_libraries`,
   `show_known_game_notes`, `confirm_continue_if_eax_impossible`, etc.).
4. **Top-level script flow** — safety guards (refuses root / Steam Gaming Mode),
   pre-flight dependency check, `ACTION: INSTALL` / `ACTION: UNINSTALL` phases.

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
they touched; uninstall only ever removes what's in that manifest and restores the
timestamped backups made at install time — it never guesses by filename.

## Text/output style conventions

All user-facing output goes through `echo -e` with the colour vars defined near the
top of the script (`GREEN`, `YELLOW`, `CYAN`, `WHITE`, `BOLD`, reset via `NC`) —
there's no other formatting mechanism (no `tput`, no external color library). Match
existing usage rather than introducing new colors or styles:

- `CYAN` — section headers and "in progress" status lines (e.g. `Checking ...`).
- `GREEN` — success (`Done.`, `Up to date [...]`, `Loaded (...)`.).
- `YELLOW` (often with `BOLD`) — warnings and recoverable errors; plain `YELLOW` for
  softer advisory notes.
- `WHITE` — general prose/body text and prompts.
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
