# Library scanning and the game database

When you start an install, the script can scan your game libraries for games it recognises. You pick one from the list instead of hunting for its folder.

What it recognises comes from the [game database](../database/database-overview.md), a community-maintained list the script downloads on every run.

## Where it looks

* Steam, native, Flatpak or Snap, in every library folder it knows about. A game that's still downloading shows up once Steam has finished installing it.
* Heroic, native or Flatpak, for GOG and Epic games and the ones you added yourself.
* Lutris, Bottles and Faugus, native or Flatpak, for the Windows games they run. The list says which launcher has the game, for example "(Lutris)".

Steam and Heroic games are matched by their store IDs. For the other three, the script reads the GOG ID from the game's own folder when it's a GOG install, and otherwise matches the `.exe` the launcher starts against the one the database names.

The script also takes the Wine prefix and the Wine version from the launcher, so the DLL override is written with the same Wine the game runs on. Lutris, Bottles and Faugus have no launch options the script edits, so for their games the override goes in the prefix's registry.

Lutris keeps its game list in a small database. The script reads it with `sqlite3` if that's installed. Without it, a Lutris game whose `.exe` path is relative to the game's folder can't be found, and you'll need to type its path.

## What a game's entry gives you

If the game is in the database, the install can do a lot more than copy files:

* show a "heads up" with anything worth knowing about the game before you start
* warn you when an install wouldn't do anything, for example because the game has no EAX to restore
* tell you when a game has been delisted from a store
* skip the guessing about whether the game uses DirectSound3D or OpenAL
* offer changes to the game's own settings, which is where most of the benefit comes from

That last one needs an explanation. Plenty of games ship with EAX turned off in their config files, or load their own copy of an audio library instead of the one the script installs. The entry lists those settings. For each one the script shows the file, the value it has now and the value it would set, and applies the ones you accept. Audio settings go in together, once you agree. Optional ones, like a fix for Quake 4's low-resolution textures, are offered one at a time, and only if you want to look through them.

## Compatibility

Every game in the database has a compatibility rating: Verified, Playable, Unsupported or Unknown. The game's profile shows it, one per store when the stores differ. The [database overview](../database/database-overview.md#compatibility) explains each one.

* **Unknown** games, the ones nobody has checked on a real install yet, are left out of the scan and the install, so they're treated as having no entry. Set `EAX_RESTORE_UNKNOWN_GAMES=1` to include them. The profile browser in the Tools menu can show them too: press Ctrl-T to switch the filter.
* **Unsupported** games show up in the scan, but the install stops and says why, because there's no EAX for the script to restore in that build.

Single settings can be unverified too, even in a verified game. Those stay hidden unless you set `EAX_RESTORE_UNVERIFIED_SETTINGS=1`, and then they're marked "(unverified)". See [Environment variables](environment-variables.md).

## When your game isn't in the database

The list is small and checked by hand, so plenty of EAX games aren't on it. The install still works, and the script falls back in two steps.

First it reads the game's own `.exe` and `.dll` files for references to OpenAL or DirectSound, to guess which one the game uses. This is less reliable than the database, and the script tells you so.

If that doesn't settle it, or you skip it, the script asks you to choose between DirectSound3D with DSOAL and native OpenAL. DirectSound3D is the default. That prompt is the only way to pick OpenAL for a game nothing could identify.

> [!NOTE]
> The scan only finds games that are in the database. If yours isn't listed, choose the option under the list to type its path yourself.

## Retail and CD copies

The scanner can't see a game that no launcher knows about, because there's no library to read. A retail copy of Half-Life from a disc, running in a Wine prefix you set up yourself, is an example. Adding it to Lutris, Bottles or Faugus is enough for the scan to find it. Otherwise the install still handles it. Point the script at the folder with the game's `.exe` and give it the prefix path when it asks.

## Adding or fixing a game

The [Add a game tutorial](../tutorials/add-a-game.md) walks through it, and [Contributing a game](../database/contributing.md) has the rules.
