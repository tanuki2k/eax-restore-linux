# Contributing

This is a hobby project: one Bash script and a database of games. Contributions are welcome, and the process is light.

| I want to... | Read |
| --- | --- |
| Report a bug | [Reporting bugs](#reporting-bugs) |
| Suggest something | [Suggesting enhancements](#suggesting-enhancements) |
| Fix or add code | [Pull requests](#pull-requests) |
| Add or fix a game | [Adding or fixing a game](#adding-or-fixing-a-game) |

## Reporting bugs

[Open an issue](../../issues/new) and tell me which game and launcher you were using (Steam/Proton or Heroic/Wine), what went wrong and the exact error message if there was one. If you can, paste the relevant part of the script's output. The log file helps even more, and [Troubleshooting](docs/troubleshooting.md) says where it is.

## Suggesting enhancements

Open an issue and describe what you were trying to do. If it only matters for one game or one engine build, say so, because that changes how I'd approach it.

## Pull requests

1. Fork the repo, branch from `dev` and open your pull request against `dev`. Everything is developed there for now. `main` becomes the base once the project goes public.
2. Keep each PR to one fix or feature. Unrelated changes bundled together are hard to review.
3. Test on a real game install when you can. The script has a lot of branches that depend on the environment (Steam or Heroic, 32 or 64-bit, Proton or native Wine), and a syntax check won't catch them.
4. Run `./build.sh && bash -n dist/eax-restore-linux.sh && bats tests/unit tests/integration`, after installing `bats`. CI also runs shellcheck and the profiler's Python tests. If you touched `data/`, `tools/` or `game-database.json`, it runs the game database checks as well. A bug fix should come with a test.
5. Say in the PR description what you tested.

## Adding or fixing a game

Game profiles are the JSON files under `data/games/` and `data/drafts/`. [Contributing a game](docs/contributing-games.md) covers the workflow, and the [game file reference](docs/game-file-reference.md) describes every field. You can also use the profile editor, `tools/profiler/eax-profiler`. It runs in your browser, and its Capture tab can find the config keys for you (see [its README](tools/profiler/README.md)).

A new entry starts in `data/games/untested/`. Before moving one to `tested/`, check each store ID against the store's own page. The editor marks IDs it found on your install as `local_install_verified`, but that only means they were seen locally.

The easiest way to send a profile is the editor's **Submit...** button. If the GitHub CLI (`gh`) is installed and you're logged in, it forks the repo if needed and opens a pull request against `dev` with just that game's profile and its entry in `game-database.json`. Without `gh`, it opens GitHub's new-file page with the profile filled in, and a maintainer rebuilds `game-database.json` when merging. Either way, the profile stays in `untested/` until someone has checked it on a real install.

## Style

Follow the conventions already in the script: `UPPER_CASE` for variables that live across functions, `snake_case` for variables local to a function, and the existing colour and echo helpers for output.

Please don't add a new external dependency unless there's really no way around it. The script needs `curl`, `unzip`, `file`, `grep`, `awk` and `jq`, plus `protontricks` or `winetricks` depending on the launcher, and I'd like to keep it that way.
