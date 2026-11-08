# The game database

The game database is the list of games the script knows about. Each entry records which audio API a game uses, which EAX versions it supports, where its config files are and which of its settings the script can change for you. The script reads it to recognise games in your library, to show a game's profile, and to offer the Game settings step during an install.

## How it's stored

Each game is one JSON file named after the game, like `quake-4.json`, under `data/games/`. The script doesn't read those files directly. `tools/build-game-database.sh` combines them into a single `game-database.json`, which is the file the script downloads. Don't edit `game-database.json` by hand, because CI checks that it matches the game files. [`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json) defines every field, and the [game file reference](game-file-reference.md) explains them.

## Where a game file lives

The folder a file is in says how far along it is.

| Folder | What it means | Shipped to players? |
| --- | --- | --- |
| `data/games/tested/` | Checked against a real install: its store IDs match, its `exe` exists if it has one, and every config file and setting is where the file says. | Yes |
| `data/games/untested/` | Not checked on a real install yet. New games start here. | Yes, but hidden unless the player sets `EAX_RESTORE_UNTESTED=1`. The profile browser can show them with Ctrl-T. |
| `data/drafts/` | Incomplete or doubtful entries. They are validated against the schema and formatted, nothing more. | No |

## Tested and untested games

A game in `tested/` has had its entry checked by someone with the game installed. A game in `untested/` is in the database but nobody has done that yet, so the script ignores it unless the player asks for it.

Single settings can be unverified too, even in a tested game. Each setting carries its own verified flag, and the script hides the unverified ones unless the player sets `EAX_RESTORE_UNTESTED_SETTINGS=1`. See [Environment variables](../script/environment-variables.md).

## How the script gets it

The script downloads `game-database.json` on every run, so a fix to a game's entry reaches players straight away. A stable release reads it from the `main` branch and a dev build reads it from `dev`. It keeps a local copy as `game-database.v3.json` and falls back to that copy when you're offline. To try an edit before it's pushed, point `EAX_RESTORE_GAME_DATABASE_FILE` at your own copy.

## Where to go next

* [Library scanning](../script/library-scanning.md) shows what the script does with an entry.
* The [Add a game tutorial](../tutorials/add-a-game.md) walks through writing one.
* [Contributing a game](contributing.md) has the rules for pull requests.
* The [game file reference](game-file-reference.md) lists every field.
