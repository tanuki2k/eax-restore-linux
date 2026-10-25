# Contributing

This is a single Bash script maintained as a hobby project. Contributions are welcome, and the process is light.

## Reporting Bugs

Please [open an issue](../../issues/new) and include:

* The game and launcher (Steam/Proton or Heroic/Wine) you were using
* The exact error message or unexpected behavior
* If possible, the relevant section of the script's console output

## Suggesting Enhancements

Open an issue describing the use case. If it's specific to one game or an engine build quirk, say so, since that helps with prioritizing.

## Pull Requests

1. Fork the repo and create a branch from `main`.
2. Keep changes focused. One fix or feature per PR is easier to review than a bundle of unrelated changes.
3. Test your change against a real game install where you can. The script has many environment-dependent branches (Steam vs. Heroic, 32-bit vs. 64-bit, Proton vs. native Wine) that a syntax check won't catch.
4. Run `./build.sh && bats -r tests` (install `bats` first); it also covers `bash -n` via CI. Add a test with a bug fix.
5. Describe what you tested in the PR description.

## Adding or fixing a game

Game profiles are the JSON files under `data/games/` and `data/drafts/`. [docs/contributing-games.md](docs/contributing-games.md) covers the workflow and [docs/game-file-reference.md](docs/game-file-reference.md) the fields, and `tools/profiler/eax-profiler` is a browser editor whose Capture tab finds the config keys for you (see `tools/profiler/README.md`). A new entry starts in `data/games/untested/`. Please check each store ID against the store's own page before you move an entry to `tested/`; the editor marks IDs it found on your install as `local_install_verified`, which only means they were seen locally.

The easy way to send a profile is the editor's **Submit…** button. With the GitHub CLI (`gh`) installed and logged in, it forks the repo if needed and opens a pull request against `dev` containing just that game's profile and the matching `game-database.json` entry. Without it, it opens GitHub's new-file page with the profile filled in, and a maintainer rebuilds `game-database.json` when merging. Either way the profile goes in `data/games/untested/` (or stays in the folder it's already in) until someone has checked it on a real install. Branching from `dev` instead of `main` applies to game profiles until `dev` becomes `main`; the steps above still work if you'd rather do the pull request yourself.

## Style

* Match the existing script's conventions: `UPPER_CASE` for variables that persist across functions, `snake_case` for function-local variables, and the existing color/echo helpers for output.
* Avoid adding new external dependencies unless there's no reasonable way around it. The script currently only requires `curl`, `unzip`, `file`, `grep`, `awk`, and `jq`, plus `protontricks`/`winetricks` depending on launcher.
