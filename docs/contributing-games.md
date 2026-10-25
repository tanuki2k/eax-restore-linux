# Contributing a game

Pull requests that add or correct a game are welcome. Each game is one file named `<id>.json`, where `<id>` is the game's name in kebab-case, like `quake-4.json` or `thief-ii-the-metal-age.json`.

## Where a game file lives

The folder a file is in says how far along it is.

| Folder | What it means | Shipped to players? |
| --- | --- | --- |
| `data/games/tested/` | Checked against a real install: its store IDs match, its `exe` exists if it has one, and every config file and setting is where the file says. | Yes |
| `data/games/untested/` | Not checked on a real install yet. New games start here. | Yes, but hidden unless the player sets `EAX_RESTORE_UNTESTED=1`. The profile browser always lists them. |
| `data/drafts/` | Incomplete or doubtful entries. They are validated against the schema and formatted, nothing more. | No |

To promote a game, `git mv` its file to the next folder and run `tools/format-game-database.sh`. That also updates the file's `"$schema"` line for the new location.

## Adding a game

The quickest route is the profile editor, `tools/profiler/eax-profiler`. It opens in your browser and edits a game file through forms, so there's no JSON to type.

If you have the game installed through Steam or Heroic, the editor's Capture tab does most of the work:

1. It saves a copy of the game's config files and the prefix's registry, installs the EAX fix without asking you anything, and launches the game.
2. You switch the sound options on in the game and quit.
3. It compares the files, ignores keys that look like the game's own bookkeeping (timestamps, window positions), and drafts a setting for you to review.

With an `ANTHROPIC_API_KEY`, or after logging in to the `claude` command, the editor can also draft titles, descriptions and reasons. Every AI feature is off until you switch it on in the editor's Settings. Whatever it drafts, check it against the game, and check every store ID against the store's own page, before you open a PR. The [profiler README](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/tools/profiler/README.md) has the details.

You can also do it by hand. Compare the game's config files before and after you switch its sound options on (for settings kept in the registry, compare the prefix's `user.reg` and `system.reg`), then write the keys that changed into the game's file as an audio setting.

## Formatting and building

[`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json) defines every field. Each game file's `"$schema"` line points at it, so VS Code and most JSON-aware editors will autocomplete and flag mistakes as you type.

Don't edit `game-database.json` yourself. It's generated from the per-game files. After you edit a game, run:

```bash
tools/format-game-database.sh      # standard key order; drops empty fields and per-field defaults
tools/build-game-database.sh       # regenerates game-database.json
```

CI checks every file against the schema, checks that it's formatted, and checks that `game-database.json` is up to date.

To see how your entry reads to a player, rebuild and run `tools/browse-game-database.sh [database.json]`. It opens the same browser as Tools → **[B]rowse game profiles** and needs `fzf` 0.35 or newer.

## Two rules

> [!IMPORTANT]
> * Only add a store `id` you've checked against the store's own page or API. A wrong ID points the script at somebody else's prefix.
> * Leave a field out when it's empty or at its default. These files have no `null`s. The formatter drops empty fields and each field's default, though `tested: false` is accepted and kept as written.

## A game file

Here is a trimmed example. `data/games/tested/` has plenty more, and the [game file reference](game-file-reference.md) explains every field.

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
