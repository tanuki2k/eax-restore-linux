# CLAUDE.md

## Project

`eax-restore-linux` restores EAX/DirectSound3D hardware audio in classic Windows
games under Steam/Proton or Heroic/Wine on Linux, by deploying DSOAL and OpenAL
Soft into the game folder and the Wine prefix. `game-database.json` is the
community database that drives library scanning, compatibility notes and the
Game Settings step.

**Design rule: anything specific to a game or engine lives in the database, never
as a special case in the script's code.** The script only knows how to read and
edit the eleven config formats (`ini`, `ini_braces`, `set_commands`, `key_value`,
`braced_pairs`, `quoted_pairs`, `xml_attributes`, `binary_offset`, `binary_text`,
`binary_switches`, `registry`), not which game needs what.

## Generated files — never edit these by hand

- `dist/eax-restore-linux.sh` is built from `src/*.sh` by `./build.sh` (order in
  its `COMPONENTS` array). Edit `src/`, then rebuild.
- `game-database.json` is built from `data/games/{tested,untested}/<id>.json`
  (`data/drafts/` never ships). Edit those, then run
  `tools/format-game-database.sh` and `tools/build-game-database.sh`.

## Commands

- Build: `./build.sh` · syntax: `bash -n dist/eax-restore-linux.sh` ·
  lint: `shellcheck dist/eax-restore-linux.sh`
- Tests: `./build.sh && bats tests/unit tests/integration`; profiler:
  `cd tools/profiler && python3 -m unittest discover -s tests`.
  **Add a test with each bug fix.**
- Rust (`tui/`): `cd tui && cargo fmt --check && cargo clippy --locked
  --all-targets -- -D warnings && cargo test --locked`
- Run: `./dist/eax-restore-linux.sh`. Handy while iterating:
  `EAX_RESTORE_SKIP_PREFLIGHT=1`, `EAX_RESTORE_SKIP_CACHE_CHECK=1`,
  `EAX_RESTORE_GAME_DATABASE_FILE=/path/to/file.json`.
- Wiki preview: `tools/build-wiki.py docs tools/profiler/README.md /tmp/wiki`.

## Branches

`dev` takes new work; `main` is stable and only takes fixes and game data that
went through `dev` first. Every push to `dev` publishes the rolling `dev`
prerelease. A tag named `dev` exists, so push with
`refs/heads/dev:refs/heads/dev`.

## Conventions that apply to most changes

- **Player-facing text:** load the `player-text` skill before writing or changing
  any string a player reads (script output or database prose), and run the
  `copy-editor` agent on it before handing over.
- **Output:** use the `src/ui.sh` helpers (`print_banner`, `print_step`,
  `print_status`, `print_note`/`print_warning`/`print_error`, `confirm`,
  `prompt` + `read_answer`, `print_wrapped`, …), never a hand-rolled `echo -e`
  with colour vars. Every user answer goes through `read_answer`.
- **Shared globals:** the `src/*.sh` files talk through globals, not parameters.
- **Comments** explain why, not what.
- **Docs:** keep `README.md`, `docs/` and the script's header comments in step
  with behaviour changes; a new `EAX_RESTORE_*` variable goes in `src/header.sh`,
  `src/args.sh` and `docs/script/environment-variables.md`.

## Read these when the task touches them

| Working on | Read first |
|---|---|
| Releases, version bumps, `main` vs `dev`, CI workflows | `.claude/context/release.md` |
| Any `src/*.sh` file, the manifest, uninstall, caching | `.claude/context/architecture.md` |
| Output helpers, colours, menus, tick lists, prompts | `.claude/context/output-style.md` |
| The Rust TUI or the engine port (`tui/`) | `.claude/context/tui.md` |
| Database fields and workflow | `docs/database/game-file-reference.md`, `docs/database/contributing.md` |
