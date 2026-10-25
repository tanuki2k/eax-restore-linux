# Library Scanning & the Game Database

During install, the script can optionally scan your Steam and Heroic libraries for titles it recognises, so you can pick a game from a list instead of browsing to its folder manually.

Matches are checked against [`game-database.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/game-database.json), a community-maintained database in this repo (built from the per-game files in [`data/games/`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/games/)). It's fetched fresh on every run from the `dev` branch and cached locally as `game-database.v3.json`, so a later offline run still works.

The same database also drives:

* the install-time "Heads up" notes
* the "this install would be a no-op" warnings
* the delisted-storefront notice
* the OpenAL-vs-DirectSound3D compatibility check ("Audio API Detection") for specific titles
* the **Game Audio Settings** and **Optional Game Settings** steps. For games that ship with EAX (or other things) switched off in their own config files, they show each setting's current and recommended value and apply the ones you accept: the audio settings together, once you agree to change them, and the optional non-audio ones (like Quake 4's low image quality fix) one by one, only if you choose to review them.

## A game that isn't in the database

The list is deliberately small and hand-verified, so it will only ever cover a fraction of EAX-capable games. If your game isn't in it, the OpenAL-vs-DirectSound3D check falls back to scanning the game's own `.exe`/`.dll` files for `OpenAL32.dll`/`dsound.dll` references. That's a lower-confidence guess, clearly flagged as such.

When even that is inconclusive (or you skip the scan), the script asks you to pick between DirectSound3D/DSOAL and OpenAL native rather than silently assuming DirectSound3D. DirectSound3D is the default, and this prompt is also the only way to select OpenAL-native mode for a game nothing could identify.

## Retail/CD copies and other installs

**Retail/CD copies and other non-Steam, non-Heroic installs** (e.g. an original pre-Steam Half-Life disc, run in a Wine prefix you set up yourself) aren't covered by the scanner at all, since there's no launcher library to scan, but the script still supports them. Point it at the game's `.exe` folder and provide the Wine prefix path manually when prompted.

## Adding or fixing a game

See [Contributing a game](contributing-games.md).
