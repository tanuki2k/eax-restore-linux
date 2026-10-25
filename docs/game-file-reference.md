# Game file reference

Every field of a game file, in the order of the [example](contributing-games.md#a-game-file). The formal definition is [`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json).

## Basics

### `name`

The display name.

### `description`

One sentence on what the game is, shown in its profile's Description section in Tools → **[B]rowse game profiles** (not during an install).

Follow PCGamingWiki's pattern in your own words: modes, perspective, genres, then the series if it has one. "Deus Ex is a singleplayer and multiplayer first-person action role-playing and immersive sim game in the Deus Ex series."

- Don't repeat what another field already says. What a bundle includes, which build it is, or a delisting belongs in `store_details` or `notes`.
- An Enhanced Edition, remaster or Anniversary Edition names the original and its year ("…, an enhanced edition of 2000's Baldur's Gate II: Shadows of Amn.").
- A bundle names its base game ("…, an expanded edition of Thief: The Dark Project.") only when no other field already does.
- An expansion names the game it's for rather than its series ("…horror expansion for F.E.A.R.").
- Leave out anything you can't confirm (e.g. the modes) rather than guess.

### `released`

The game's first Windows release, earliest region, as `YYYY-MM-DD` (or `YYYY-MM` / `YYYY` when only that much is verifiable), shown as the profile's "Released" row.

- Cross-check at least two sources (Wikipedia's infobox is a good start). A console release that came first doesn't count.
- A bundle, Gold, Complete, GOTY or Classic edition takes its base game's date.
- An Enhanced Edition, Remaster or Anniversary Edition, which is a separate build, takes its own.
- Don't use the date a store started selling it. Stores often show the original date anyway, or a re-listing.

### `exe`

The main game executable's **file name only**, e.g. `"DeusEx.exe"`, as it appears in a real install.

The scanner picks the folder holding it, which handles layouts its name matching gets wrong (e.g. Splinter Cell: Double Agent's separate single-player and multiplayer builds), and a hand-typed folder that doesn't contain it gets a warning. Only add it after checking a real install.

## `stores`

An object with a `"steam"` and/or `"gog"` key. **Omit a store key entirely when the game isn't sold there** (a GOG-only game has no `"steam"` key, so "GOG only" needs no prose). Each store block holds the fields below.

### `stores.*.id`

The numeric Steam AppID / GOG game ID, used for library-scan matching.

For GOG, use the ID Heroic installs the game under (its `appName`, the same as the `gameId` in the game folder's `goggame-<id>.info`). For a game GOG only sells inside a pack, that's the game inside it, never the pack: Dungeon Siege's store page is the Dungeon Siege Collection (1142020247), but the game is 1185868626. `https://api.gog.com/products/<id>` reports `"game_type": "pack"` for a pack.

### `stores.*.delisted`

`true` when the game has been pulled from sale there (existing owners keep access). Availability only, not pricing.

### `stores.*.id_source`

Omit it when you checked the ID against the store's own page/API (the default).

- `"local_install_verified"` means it was also confirmed against a real local install.
- `"steamdb_historical"` means the store page is gone and the ID is SteamDB's historical record, not checked locally. Only that one shows a line in the game-details display.

### `stores.*.api`

`"directsound3d"` / `"openal"` to override `eax.api` for **this store's build only**. Set it only where a storefront's current build genuinely differs.

For example, Thief Gold / Thief II: `eax.api` is `"directsound3d"`, but GOG's build comes with NewDark pre-installed, which runs audio and EAX reverb through OpenAL, so its `gog` block has `"api": "openal"`.

### `stores.*.beta_branch`

Steam only. The exact `BetaKey` name (right-click the game -> Properties -> Betas) of a beta branch that restores EAX on this store's build. Set it only when `eax.fix` names one.

It lets the install-time check detect whether the user's local appmanifest already has this branch opted into/mounted, instead of always showing the `removed_by_patch` warning.

### `stores.*.extra_exe_folders`

Folders that hold another exe started from the same title, e.g. `["FEARXP", "FEARXP2"]` for F.E.A.R. Platinum, whose expansions Heroic launches from the one install.

- A plain name is a folder under the game's exe folder. One starting `game_root:` is under the install folder instead, for builds that sit side by side: Steam's Aliens versus Predator Classic 2000 lists `["game_root:bin", "game_root:bin_Crossplay"]`, since its launcher runs either one.
- List every such folder, the main one included: whichever is the exe folder is skipped.
- Each gets the same game-folder files as the main exe (folders missing from an install are skipped), and the prefix, registry and launcher override are shared.
- Where Steam lists the extra games as separate apps with their own prefixes (F.E.A.R.'s expansions are AppIDs 21110 and 21120), give each one its own entry with its own `exe` instead. The exception is apps that run this entry's own exe from its own folder, which is what `companion_apps` is for.

### `stores.*.companion_apps`

Steam only. AppIDs of other Steam apps that run this game's exe from its own folder with different arguments, e.g. `[9070]` for DOOM 3's Resurrection of Evil (`Doom3.exe +set fs_game d3xp`).

The game-folder files and its settings are already shared, but Steam gives each one its own Proton prefix and launch options. So installing the game sets those up too (OpenAL runtime, prefix DLLs, VC++ runtime, registry, DLL override), uninstall puts them back, and Tools → VC++ install covers them.

A companion that isn't installed is skipped. One that hasn't been launched yet (no prefix) gets the usual "launch it once, then check again".

### `stores.*.store_details`

Prose about what's specific to **this store's listing**:

- engine/audio-path differences ("It comes with NewDark pre-installed…")
- delisting circumstances
- bundling/packaging quirks ("Heroic installs this bundle as two separate library entries")
- build-identity/disambiguation facts ("Both stores sell this as the 'Planetary Pack'", "This is the original 1999 Planescape: Torment")

Rules:

- A game that isn't itself an Enhanced Edition, remaster or remake never mentions one, not in `store_details`, `notes` or any other field, even to say it isn't one. Only an Enhanced Edition or remaster's own `notes` may point to the classic build ("If you also own the classic…").
- The exception is a store that sells them together: `store_details` may then name every game in the bundle, the Enhanced Edition or remaster included ("DOOM 3 is sold as a bundle with Resurrection of Evil and DOOM 3: BFG Edition.").
- When a fact applies identically to more than one store, duplicate the prose into each relevant store block. Write each store's copy to stand on its own, never referencing "the other store's block" or "the Steam version" from within the GOG block (a user only ever sees one store's block).
- Don't name the script's own parts (DSOAL / OpenAL Soft) or talk about "paths" / "intercepting". State the fact and let the script say what it will use.

### `stores.*.patches`

Prose for **this store's build**, shown under "Suggested community patches:": community patch/mod recommendations (TFix / T2Fix, SilentPatch, Sneaky Upgrade, SCP…).

- It includes patches that, for a delisted game, are also the practical way to get a legitimate full copy (e.g. OldUnreal's patches). Present a community OpenAL reimplementation as a strong alternative to this script's approach, not as an inferior fallback.
- Don't use it for "go buy it from a different retailer" content. That stays in `notes`.

## `eax`

How the game does 3D audio and whether EAX works on the current build.

### `eax.api`

Required. `"directsound3d"` or `"openal"`. The game-level audio API, used for any store without its own `api` override and for non-store installs; it also decides which engine the script installs.

### `eax.versions`

Supported EAX version strings. Only set from a verifiable source (the game's manual/readme, an in-game audio settings menu, or a maintained compatibility database), and cite it in `sources` or the PR description. Omit for a `"not_implemented"` game.

### `eax.status`

Omit when EAX works (the default, `"supported"`).

- `"removed_by_patch"`: a software update stripped EAX/A3D from the current build (an alternate build/branch may restore it).
- `"not_implemented"`: a remaster/rewrite that never had EAX. No build-level fix exists.
- `"built_in"`: EAX already works in this build without the script (e.g. it ships its own OpenAL32.dll with EAX). The install-time check says so and asks "Install anyway?", defaulting to No.

### `eax.problem`

Prose explaining *why* the current build is in that state, shown in the game-details `Status:` block. A game with `supported` status can fill it in too, for a known limitation; leave it empty otherwise. Since every entry is a current digital-store listing, don't add "make sure you're patched to at least version X" trivia.

### `eax.fix`

Prose saying *how* to get a build where EAX works (a Steam beta branch, a retail/CD copy…). Game-level, not per store. Settings in the game's own config files belong in `game_config`, not here.

### `eax.fix_in_place`

`true` only when `fix` works on the *same install* the script is already pointed at (e.g. a Steam beta branch): the install-time check then warns and still offers "Continue installing anyway?". Omit it when the only fix is a separate install (e.g. a pre-patch retail copy). The check then blocks, the same as `"not_implemented"`.

## `install`

What the install itself does differently for this game.

### `install.tweaks`

Any of `"eax_unified"`, `"expand_audio_limits"`, `"com_registry_routing"`. Each turns the matching Advanced Compatibility Tweak into a default-yes prompt.

- `"eax_unified"`: for titles that reach EAX through Creative's `eax.dll` "EAX Unified" shim rather than native DirectSound3D. Drives a guarded prompt for the EAX Unified Dummy Files tweak (it checks whether the game ships its own `eax.dll` first).
- `"expand_audio_limits"`: for a title independently verified to need it, e.g. F.E.A.R.'s audio dropping out during large firefights.
- `"com_registry_routing"`: for a title independently verified to need it, e.g. Grand Theft Auto: San Andreas.

### `install.alsoft_ini`

OpenAL Soft settings offered for this game in the Game Audio Settings step (phase 3), as section → key → value strings. Only these are allowed:

- `reverb.boost`: decibels added to all reverb; raise it for a game whose reverb is hard to hear.
- `general.sources`: how many sounds the game can play at once.
- `general.frequency`: the sample rate sound is mixed at, in Hz.
- `general.default-reverb`: the reverb preset used where the game doesn't choose one.
- `general.resampler`: how sounds at another sample rate are converted.

E.g. `{ "reverb": { "boost": "6" } }` for a game whose reverb is quiet. Test that the value doesn't make the reverb pop.

### `install.alsoft_tested`

Optional. `true` once the `alsoft_ini` values are verified on a real install. Without it they're unverified and handled like an untested setting (hidden unless `EAX_RESTORE_UNTESTED_SETTINGS=1`, tagged "(untested)").

## `game_config`

Changes to the game's **own** config files (or its registry settings), offered in the Game Settings step. The player sees each file, setting and its current → new value, confirms, and uninstall puts the original values back (leaving anything the player has changed since alone).

### `game_config.files`

Each config file, keyed by its file name. A file has the fields below.

#### `format`

- `"ini"`: `[Section]` + `key=value`.
- `"flat_ini"`: `key=value` lines with no `[Section]` headers, e.g. Thief: Deadly Shadows' `options.ini`.
- `"idtech_cfg"`: `seta key "value"`, id Tech games.
- `"dark_cfg"`: NewDark's `key value` lines, where a bare `key` turns a flag on and `;key` turns it off.
- `"brace_cfg"`: `{key} = {value}` lines, e.g. Fallout Tactics' `bos.cfg`.
- `"gas_cfg"`: a `[section]` with `key = value;` lines between `{` and `}`, e.g. Dungeon Siege's `prefs.gas`.
- `"ltx"`: `key value` lines with no sections, e.g. S.T.A.L.K.E.R.'s `user.ltx`.
- `"gadb"`: Monolith's binary game database, e.g. F.E.A.R.'s `Profile000.gdb`. It can only switch a setting the file already has on or off, so its values are `"0"` or `"1"`.
- `"wine_reg"`: for a game that keeps its options in the registry, e.g. Descent 3.
  - The prefix's `system.reg` for `HKEY_LOCAL_MACHINE` or `user.reg` for `HKEY_CURRENT_USER`, keyed `"system.reg"` / `"user.reg"`.
  - Only number (dword) and text values can be changed, a number written in decimal.
  - The script waits for Wine to save the registry and exit before changing it, and won't while the game is running.

#### `locations`

Where to look, in order, as `"base:path"`; the first that exists is used. Bases:

- `game_exe`: the folder the game's exe runs from.
- `game_root`: the game's top-level install folder.
- `prefix_documents`, `prefix_appdata`, `prefix_localappdata`: inside the Wine prefix's user folder.
- `prefix_public_documents`: the prefix's shared `Public\Documents`, where F.E.A.R. keeps its profiles.
- `prefix`: for a `wine_reg` file, only as `"prefix:system.reg"` or `"prefix:user.reg"`.

No `..`, leading `/` or backslashes.

#### `all_locations`

Optional. `true` to change the file in every location that exists, not just the first (Brothers in Arms keeps `bia.ini` in its game folder and in the prefix's AppData). Leave it out when the locations are alternatives for different builds, as in STALKER's `user.ltx`. The Game Settings step names each file it changes by its full path.

#### `if_missing`

What to do when the file doesn't exist.

- Omit it for files the game writes on first launch (the script asks the player to launch the game once, then checks again).
- `"skip"` for files only some builds have (NewDark's `cam_ext.cfg` isn't in the stock Steam Thief games). Only that file's part of a setting is left out, and the Game Settings step and the closing summary tell the player ("left out: Thief Gold has no cam_ext.cfg").
- `"create"` to create it (e.g. Quake 4's `autoexec.cfg`).

#### `crash_marker`

Optional. The name of a file the game keeps next to this config file while it's running and deletes when quit from its own menu, which makes it reset the config file on its next start if left behind (BioShock's `Running.ini`). The script removes it, when the game isn't running, before changing the file, and never puts it back on uninstall.

### `game_config.audio_settings`

Settings that turn on EAX and 3D sound (or make them sound right), so the player doesn't have to. They are confirmed together with one default-yes prompt.

### `game_config.optional_settings`

Optional quality-of-life settings that aren't needed for EAX (e.g. Quake 4's low-res textures fix), offered separately so the player picks which to apply.

### A setting

Each entry in `audio_settings` and `optional_settings` has these fields.

#### `title` and `reason`

`title` is **Enable** / **Fix** / **Remove** / **Raise** plus the result the player gets (`"Enable EAX reverb"`), reused across games for the same result. `reason` is one or two short sentences, starting with the game's name, on what the game does out of the box, without repeating the settings the rows below it show.

#### `changes`

File → section → key → value for `ini` files, file → key → value for `flat_ini` and the cfg formats, and file → registry key → value name → value for `wine_reg`.

- For `wine_reg`, give the key path as the `.reg` file shows it below its hive (`{ "system.reg": { "Software\\Wow6432Node\\Outrage\\Descent3": { "Name": "3" } } }`). The script also finds it without `Wow6432Node\` in a 32-bit prefix.
- Values are strings; `true`/`false` switches a `dark_cfg` flag; `null` removes the key.
- Every file must be listed in `files`.

#### `only_if`

Optional conditions: `{ "stores": ["gog"] }` and/or `{ "speakers": ... }` (the Speaker Configuration answer). The speaker values are:

- `"stereo"`: also covers Headphones, unless the game has its own `"headphones"` setting.
- `"headphones"`: Stereo, then Headphones.
- `"matrix"`.
- `"surround"`: any surround layout.
- One exact layout: `"quad"` / `"surround51"` / `"surround61"` / `"surround71"`.
- A list such as `["surround51", "surround61"]` matches any of them.

Prefer `if_missing: "skip"` over a store condition when a setting depends on a file only some builds have.

#### `follow_up`

Optional. Something the player does after installing, shown in the final summary's "Before you play" box and in the game profile browser (`"Open Options -> Video and click Autodetect."`).

#### `tested`

Optional. `true` once the setting is verified on a real install, and it then shows "(tested)". A setting without it (or `false`) is unverified: hidden unless the player sets `EAX_RESTORE_UNTESTED_SETTINGS=1`, and tagged "(untested)" when shown.

## `sources`

Pages backing the entry's claims (the short "(per PCGamingWiki)" citations in the prose point here). They're listed last on the script's game profile screen as clickable links.

Give each a name with `{ "title": "PCGamingWiki: Quake 4", "url": "https://www.pcgamingwiki.com/wiki/Quake_4" }`; a bare URL string still works and shows just the address. Each source's address is printed under its name, so it can be opened in any terminal.

## `notes`

Prose caveats not covered by the fields above: cross-references to sibling entries, limitation/expectation-setting caveats ("reverb here is subtle, that's expected not a bug"), controller/multiplayer/mod quirks.

## Line breaks in long text

The long text fields (`description`, `notes`, `store_details`, `patches`, `eax.problem`, `eax.fix`, and a setting's `reason` and `follow_up`) can hold line breaks: `\n` in the JSON (or Enter in the profiler's editor) starts a new line, and `\n\n` leaves a blank line between paragraphs. Don't break lines just to wrap them; the script wraps the text to fit the screen.
