# The game database

The game database is the list of games the script knows about. Each entry records which audio API a game uses, which EAX versions it supports, where its config files are and which of its settings the script can change for you. The script reads it to recognise games in your library, to show a game's profile, and to offer the Game settings step during an install.

## How it's stored

Each game is one JSON file named after the game, like `quake-4.json`, under `data/games/`. The script doesn't read those files directly. `tools/build-game-database.sh` combines them into a single `game-database.json`, which is the file the script downloads. Don't edit `game-database.json` by hand, because CI checks that it matches the game files. [`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json) defines every field, and the [game file reference](game-file-reference.md) explains them.

## Where a game file lives

| Folder | What it holds | Shipped to players? |
| --- | --- | --- |
| `data/games/` | Every game in the database, whatever its compatibility. | Yes |
| `data/drafts/` | Incomplete or doubtful entries. They are validated against the schema and formatted, nothing more. | No |

## Compatibility

Each game says how well EAX works with the script, in its `compatibility` field. It works like the ratings on Steam's store pages.

| Compatibility | What it means |
| --- | --- |
| Verified | Someone checked it on a real install, and EAX works without problems. |
| Playable | EAX works with the script, but something sounds wrong with it restored that sounds right without it. The game's `eax.problem` says what. |
| Unsupported | The script can't restore EAX on this build: a remaster that never had EAX, or an update removed it with no way back. The install stops and says why. |
| Unknown | Nobody has checked it yet. This is a game with no `compatibility`. |

To choose one, ask in order: does the script refuse to install it (Unsupported)? Has anyone played it with the fix (if not, Unknown)? Does anything sound wrong with the fix that sounds right without it (Playable), or not (Verified)? A bug the game has anyway doesn't count, and nor does a step the script does for the player, like a setting it changes or EAX Unified. How bad a problem is doesn't change the rating. The problem text says that.

A store's copy can rate differently from the game, for example when only the GOG copy was checked. See [`stores.*.compatibility`](game-file-reference.md#storescompatibility).

The script hides Unknown games unless the player sets `EAX_RESTORE_UNKNOWN_GAMES=1`. The profile browser can show them with Ctrl-T.

Single settings carry their own `verified` flag, whatever the game's compatibility. The script hides unverified ones unless the player sets `EAX_RESTORE_UNVERIFIED_SETTINGS=1`. See [Environment variables](../script/environment-variables.md).

## How the script gets it

The script downloads `game-database.json` on every run, so a fix to a game's entry reaches players straight away. A stable release reads it from the `main` branch and a dev build reads it from `dev`. It keeps a local copy as `game-database.v3.json` and falls back to that copy when you're offline. To try an edit before it's pushed, point `EAX_RESTORE_GAME_DATABASE_FILE` at your own copy.

## Where to go next

* [Library scanning](../script/library-scanning.md) shows what the script does with an entry.
* The [Add a game tutorial](../tutorials/add-a-game.md) walks through writing one.
* [Contributing a game](contributing.md) has the rules for pull requests.
* The [game file reference](game-file-reference.md) lists every field.
