# Contributing a game

PRs adding or correcting games are welcome. Each game is its own file, `<id>.json`, where `<id>` is a kebab-case version of its name (`quake-4.json`, `thief-ii-the-metal-age.json`).

## Where a game file lives

Which folder it's in says how far it's got:

| Folder | Meaning | Shipped |
| --- | --- | --- |
| `data/games/tested/` | Checked against a real install. Its store IDs match, its `exe` exists, and any config files and settings it changes are where it says. | Yes |
| `data/games/untested/` | Not checked on a real install yet. New games go here. | Yes |
| `data/drafts/` | Incomplete or doubtful entries. Checked against the schema and formatted. | **No** |

To promote a game, move its file (`git mv`) and re-run `tools/format-game-database.sh`, which also updates its `"$schema"` line for the new folder.

## Adding a game

The quickest way to add a game or its settings is the profile editor, `tools/profiler/eax-profiler`, which opens in your browser. It edits any game file through forms, so there's no JSON to type.

For a game you have installed in Steam or Heroic, the editor's **Capture** tab does most of the work:

1. It saves a copy of the game's config files and the prefix's registry, installs the EAX fix without asking you anything, and launches the game.
2. You switch the sound options on and quit.
3. It works out which keys changed, skips the ones that look like the game's own bookkeeping (timestamps, window positions), and drafts the setting for you to review.

If you have an `ANTHROPIC_API_KEY`, or are logged in to the `claude` command, the editor can also draft titles, descriptions and reason text. Each AI feature can be switched off in the editor's Settings. Check everything it drafts against the game, and every store ID against the store's own page, before you open a PR. See [`tools/profiler/README.md`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/tools/profiler/README.md).

To do it by hand instead, compare the game's config files (and, for registry settings, the prefix's `user.reg`/`system.reg`) before and after switching its sound options on, then write the keys that changed into the game's file as an audio setting.

### Format and build

The formal definition of every field is [`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json); pointing your editor at it (each file's `"$schema"` line does this in VS Code and most JSON-aware editors) gives autocompletion and flags mistakes as you type. Don't edit `game-database.json` by hand, because it's generated from the per-game files. After editing, run:

```bash
tools/format-game-database.sh      # puts keys in the standard order and drops empty/default fields
tools/build-game-database.sh       # regenerates game-database.json
```

CI checks every file against the schema, that it's formatted, and that `game-database.json` is up to date.

`tools/browse-game-database.sh [database.json]` browses the built `game-database.json` with the same browser as Tools → **[B]rowse game profiles** (it needs `fzf`): rebuild, then check how your entry's profile reads to players.

## Rules

> [!IMPORTANT]
> * Only add a store `id` you've verified against the storefront's own page or API. A wrong ID would point the script at someone else's prefix.
> * **Leave a field out when it's empty or at its default.** There are no `null`s in these files.

## A game file

A game file looks like this, trimmed (see `data/games/tested/` for more). Every field is described in the [game file reference](game-file-reference.md).

```json
{
  "$schema": "../../schema.json",
  "name": "Quake 4",
  "description": "Quake 4 is a singleplayer and multiplayer first-person shooter game and the fourth in the Quake series.",
  "released": "2005-10-18",
  "exe": "Quake4.exe",
  "stores": {
    "steam": { "id": 2210 },
    "gog": { "id": 1836059896 }
  },
  "eax": { "api": "openal", "versions": ["4.0", "5.0"] },
  "game_config": {
    "files": {
      "Quake4Config.cfg": { "format": "idtech_cfg", "locations": ["game_exe:q4base/Quake4Config.cfg"] }
    },
    "audio_settings": [
      {
        "title": "Enable EAX effects",
        "reason": "Quake 4 ships with its EAX sound options off, so there's no reverb and no muffling of sounds through walls.",
        "changes": { "Quake4Config.cfg": { "s_useOpenAL": "1", "s_useEAXReverb": "1", "s_useEAXOcclusion": "1" } }
      }
    ]
  },
  "sources": [{ "title": "PCGamingWiki: Quake 4", "url": "https://www.pcgamingwiki.com/wiki/Quake_4" }]
}
```
