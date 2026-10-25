# Environment variables

For repeat runs or scripting, these can be set to skip prompts. Set them in front of the command:

```bash
EAX_RESTORE_SKIP_PREFLIGHT=1 EAX_RESTORE_SKIP_UPDATE_CHECK=1 ./eax-restore-linux.sh
```

| Variable | Effect |
| --- | --- |
| `EAX_RESTORE_SKIP_PREFLIGHT=1` | Skips the pre-flight tool scan, trusting that `curl`, `unzip`, `file`, `jq`, `protontricks`, `winetricks`, and `wine` are already available. |
| `EAX_RESTORE_SKIP_UPDATE_CHECK=1` | Skips the start-up check for a newer version of the script (a stable build looks at the latest release, a `-dev` build at the `dev` one). Without it, the script offers to download the newer version and restart with it; the download is checked against the release's `.sha256` first. |
| `EAX_RESTORE_DSOAL_PIN=1` | Uses the stable `kcat/dsoal` build (the revision pinned in the script, from kcat's `archive` release) without asking, so only the OpenAL Soft build is chosen. Also selects the DSOAL engine and jumps straight to install, except for a game known to use OpenAL, which still gets OpenAL Soft. |
| `EAX_RESTORE_VCRUN_ONLY=1` | Skips the full install/uninstall flow and just (re)installs the MS VC++ 2022 Redistributable into a game's prefix. The main menu offers the same under **Tools → [V]C++ install**. |
| `EAX_RESTORE_SKIP_CACHE_CHECK=1` | Doesn't contact GitHub for DSOAL or OpenAL Soft: the build choice only offers what's already in the local cache. |
| `EAX_RESTORE_GAME_DATABASE_FILE=/path/to/game-database.json` | Uses a local file (e.g. one you built with `tools/build-game-database.sh`) instead of fetching `game-database.json`. Mainly for testing edits to the database before they're pushed. |
| `EAX_RESTORE_UNTESTED=1` | Includes the unverified game profiles (the ones built from `data/games/untested/`). Without it they're left out, so those games are treated as having no profile. The profile browser (Tools → Browse game profiles) always lists them, behind its own tested / untested filter. |
| `EAX_RESTORE_UNTESTED_SETTINGS=1` | Offers the game settings (audio and optional) marked `"tested": false`, and the `alsoft_ini` values when `install.alsoft_tested` is `false`, since they're unverified. Without it they're left out; with it they're tagged "(untested)", and checked ones "(tested)". The profile browser always shows them. |
| `EAX_RESTORE_ANSWERS_FILE=/path/to/answers.txt` | Answers every prompt from the file (one line per prompt; lines starting with `#` are ignored) instead of the terminal, for unattended runs such as `tools/profiler`. |
| `EAX_RESTORE_NO_LOG=1` | Turns off the per-run log file (see [Logs & Bug Reports](troubleshooting.md#logs--bug-reports)). |
