# Environment variables

These change how the script behaves, mostly to skip prompts on repeat runs or to run it unattended. Put them in front of the command:

```bash
EAX_RESTORE_SKIP_PREFLIGHT=1 EAX_RESTORE_SKIP_UPDATE_CHECK=1 ./eax-restore-linux.sh
```

## For repeat runs

| Variable | What it does |
| --- | --- |
| `EAX_RESTORE_SKIP_PREFLIGHT=1` | Skips the check for required tools and trusts that `curl`, `unzip`, `file`, `grep`, `awk`, `jq`, `protontricks`, `winetricks` and `wine` are all installed. |
| `EAX_RESTORE_SKIP_UPDATE_CHECK=1` | Skips the check for a newer version of the script. Normally a stable build looks at the latest release and a `-dev` build at the `dev` one, then offers to download the newer script and restart with it, after checking it against the release's `.sha256`. The check is also skipped when there's no terminal or `EAX_RESTORE_ANSWERS_FILE` is set. |
| `EAX_RESTORE_SKIP_CACHE_CHECK=1` | Doesn't contact GitHub for DSOAL or OpenAL Soft. The build choice then offers only what's already in the local cache. |
| `EAX_RESTORE_DSOAL_PIN=1` | Uses the stable `kcat/dsoal` build without asking (the revision pinned in the script, from kcat's `archive` release), so you only choose an OpenAL Soft build. It also picks the DSOAL engine and goes straight to the install, except for a game known to use OpenAL, which still gets OpenAL Soft. |
| `EAX_RESTORE_VCRUN_ONLY=1` | Skips the install and uninstall and only installs the VC++ 2022 runtime into a game's prefix. **Tools → [V]C++ install** in the main menu does the same. |
| `EAX_RESTORE_NO_LOG=1` | Turns off the log file each run normally writes. See [Troubleshooting](troubleshooting.md#logs-and-bug-reports). |

## For game profiles

| Variable | What it does |
| --- | --- |
| `EAX_RESTORE_UNTESTED=1` | Includes game profiles nobody has checked on a real install (the ones built from `data/games/untested/`). Without it, those games are treated as having no profile. The profile browser always lists them. |
| `EAX_RESTORE_UNTESTED_SETTINGS=1` | Offers game settings marked `"tested": false`, and `alsoft_ini` values when `install.alsoft_tested` is `false`. Without it they're left out. With it they're marked "(untested)", and the checked ones "(tested)". The profile browser always shows them. |
| `EAX_RESTORE_GAME_DATABASE_FILE=/path/to/game-database.json` | Uses a local file instead of fetching `game-database.json`, for example one you built with `tools/build-game-database.sh`. It's for testing database edits before they're pushed. |

## For debugging

| Variable | What it does |
| --- | --- |
| `EAX_RESTORE_DSOAL_LOG=1` | Turns DSOAL's own log on at its fullest level (4, every EAX call) as part of an install, so you don't have to run **Tools → DSOAL logging** afterwards. It adds `DSOAL_LOGLEVEL` and `DSOAL_LOGFILE` to the game's Steam launch options or Heroic environment variables, whichever way the DLL override was set, and the log goes to `dsoal.log` in the game folder. The game needs launcher settings to add them to. Uninstalling removes them along with the DLL override if it was set through the launcher. |

## For scripting

| Variable | What it does |
| --- | --- |
| `EAX_RESTORE_ANSWERS_FILE=/path/to/answers.txt` | Answers every prompt from a file, one line per prompt, instead of asking you. Lines starting with `#` are ignored. `tools/profiler` uses this for unattended runs. |
| `EAX_RESTORE_ACTION=install` | Runs one action without showing the main menu: `install`, `uninstall`, `optional-settings`, `speakers`, `vcrun` or `dsoal-log`. It's for a program that has its own menu, like the TUI. Where the script would go back to a menu, it ends instead. |
| `EAX_RESTORE_GAME_DIR=/path/to/game` | The game's `.exe` folder. The script uses it in place of asking where the game is, and skips the list of installed games. |
| `EAX_RESTORE_GAME=steam:2210` | For an install, picks that game (`steam:` or `gog:` and its id) from the library scan, so the list is skipped. If the game isn't in your libraries, the list comes up as usual. |
