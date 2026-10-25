# Library scanning and the game database

When you start an install, the script can scan your Steam and Heroic libraries for games it recognises. You pick one from the list instead of hunting for its folder.

What it recognises comes from [`game-database.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/game-database.json), a community-maintained file in this repo, built from one small file per game in [`data/games/`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/games/). The script fetches it fresh on every run from the `dev` branch, so a fix to a game's entry reaches you straight away. It keeps a local copy as `game-database.v3.json`, which it falls back to when you're offline.

## What a game's entry gives you

If the game is in the database, the install can do a lot more than copy files:

* show a "heads up" with anything worth knowing about the game before you start
* warn you when an install wouldn't do anything, for example because the game has no EAX to restore
* tell you when a game has been delisted from a store
* skip the guessing about whether the game uses DirectSound3D or OpenAL
* offer changes to the game's own settings, which is where most of the benefit comes from

That last one needs an explanation. Plenty of games ship with EAX turned off in their config files, or load their own copy of an audio library instead of the one the script installs. The entry lists those settings. For each one the script shows the file, the value it has now and the value it would set, and applies the ones you accept. Audio settings go in together, once you agree. Optional ones, like a fix for Quake 4's low-resolution textures, are offered one at a time, and only if you want to look through them.

## Tested and untested games

Each game's file lives in one of two folders. `data/games/tested/` holds games someone has checked on a real install. `data/games/untested/` holds games that are in the database but nobody has checked yet. The install and the library scan ignore the untested ones, so those games are treated as having no entry. Set `EAX_RESTORE_UNTESTED=1` to include them. The profile browser in the Tools menu always lists them, behind its own filter.

Single settings can be unverified too, even in a tested game. Those are left out unless you set `EAX_RESTORE_UNTESTED_SETTINGS=1`, and then they're marked "(untested)". See [Environment variables](environment-variables.md).

## When your game isn't in the database

The list is small and checked by hand, so plenty of EAX games aren't on it. The install still works, and the script falls back in two steps.

First it reads the game's own `.exe` and `.dll` files for references to OpenAL or DirectSound, to guess which one the game uses. This is less reliable than the database, and the script tells you so.

If that doesn't settle it, or you skip it, the script asks you to choose between DirectSound3D with DSOAL and native OpenAL. DirectSound3D is the default. That prompt is the only way to pick OpenAL for a game nothing could identify.

> [!NOTE]
> The scan only finds games that are in the database. If yours isn't listed, choose the option under the list to type its path yourself.

## Retail and CD copies

The scanner can't see games that aren't in Steam or Heroic, because there's no library to read. A retail copy of Half-Life from a disc, running in a Wine prefix you set up yourself, is an example. The install still handles it. Point the script at the folder with the game's `.exe` and give it the prefix path when it asks.

## Adding or fixing a game

[Contributing a game](contributing-games.md) walks through it.
