# Game file reference

This page covers every field of a game file, in the order of the [example](contributing-games.md#a-game-file). The formal definition is [`data/schema.json`](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/data/schema.json).

## At a glance

Only three things are required: `name`, `stores` (each store with an `id`) and `eax` (with `api`). If you add a `game_config`, it needs `files`, and each setting in it needs a `title`, a `reason` and `changes`.

| Section | Fields | What it holds |
| --- | --- | --- |
| [Basics](#basics) | `name`, `description`, `released`, `exe` | Who the game is and how to find it |
| [`stores`](#stores) | `id`, `delisted`, `api`, `store_details`, `patches`, ... | What's specific to the Steam or GOG listing |
| [`eax`](#eax) | `api`, `versions`, `status`, `problem`, `fix` | How the game does 3D audio |
| [`install`](#install) | `tweaks`, `alsoft_ini` | What the install does differently |
| [`game_config`](#game_config) | `files`, `audio_settings`, `optional_settings` | Edits to the game's own config files |
| [`sources`](#sources) | | Pages that back up the entry's claims |
| [`notes`](#notes) | | Caveats that fit nowhere else |

> [!TIP]
> Leave a field out when it's empty or at its default. Long text fields can hold line breaks, covered [at the end](#line-breaks-in-long-text).

## Basics

### `name`

The game's display name.

### `description`

One sentence about what the game is. It appears in the profile's Description section in Tools → **[B]rowse game profiles**, not during an install.

Follow PCGamingWiki's pattern, in your own words: modes, then perspective and genres, then the series if there is one. For example: "Deus Ex is a singleplayer and multiplayer first-person action role-playing and immersive sim game in the Deus Ex series."

* Don't repeat what another field says. What a bundle includes, which build this is and a delisting all belong in `store_details` or `notes`.
* An Enhanced Edition, remaster or Anniversary Edition names the original and its year: "...an enhanced edition of 2000's Baldur's Gate II: Shadows of Amn."
* A bundle names its base game ("...an expanded edition of Thief: The Dark Project.") only when no other field already does.
* An expansion names the game it's for rather than the series: "...horror expansion for F.E.A.R."
* If you can't confirm something, like the modes, leave it out.

### `released`

The date of the game's first Windows release, in its earliest region, written `YYYY-MM-DD`. Use `YYYY-MM` or `YYYY` if that's all you can verify. It shows as the "Released" row of the profile.

* Check at least two sources. Wikipedia's infobox is a good start. A console release that came earlier doesn't count.
* A bundle, or a Gold, Complete, GOTY or Classic edition, takes the base game's date.
* An Enhanced Edition, remaster or Anniversary Edition is a separate build and takes its own date.
* Don't use the date a store started selling the game. Stores often show the original date anyway, or the date of a re-listing.

### `exe`

The main game executable, as a file name only, like `"DeusEx.exe"`, exactly as it appears in a real install.

The scanner uses it to pick the folder to work in. That handles layouts that name matching gets wrong, like Splinter Cell: Double Agent's separate single-player and multiplayer builds. If someone types a folder that doesn't contain the exe, they get a warning. Only add it after you've checked a real install.

## `stores`

An object with a `"steam"` key, a `"gog"` key or both. Every field below goes inside a store's block.

> [!IMPORTANT]
> Leave out the key for a store that doesn't sell the game. A GOG-only game has no `"steam"` key, so there's no need to write "GOG only" anywhere.

### `stores.*.id`

The numeric Steam AppID or GOG game ID. Library scanning matches on it.

For GOG, use the ID Heroic installs the game under. That's its `appName`, which is also the `gameId` in the game folder's `goggame-<id>.info`. If GOG only sells the game inside a pack, use the ID of the game and not the pack. Dungeon Siege's store page is the Dungeon Siege Collection (1142020247), but the game itself is 1185868626. `https://api.gog.com/products/<id>` says `"game_type": "pack"` for a pack.

### `stores.*.delisted`

`true` when the store has pulled the game from sale. People who already own it keep access. This is only about availability, not price.

### `stores.*.id_source`

Leave it out if you checked the ID against the store's own page or API. That's the default.

* `"local_install_verified"` means you also confirmed the ID against a real local install.
* `"steamdb_historical"` means the store page is gone and the ID comes from SteamDB's history, not from a local check. This is the only value that adds a line to the game profile.

### `stores.*.api`

`"directsound3d"` or `"openal"`, to override `eax.api` for this store's build only. Set it only where a store's current build really differs.

Thief Gold and Thief II are an example. Their `eax.api` is `"directsound3d"`, but GOG's build comes with NewDark pre-installed, which runs audio and EAX reverb through OpenAL, so the `gog` block says `"api": "openal"`.

### `stores.*.beta_branch`

Steam only. The exact `BetaKey` name of a beta branch that restores EAX on this store's build (right-click the game, then Properties → Betas). Set it only when `eax.fix` names such a branch.

With it, the install can tell whether the player's Steam manifest already has the branch selected. Without it, the `removed_by_patch` warning would always show.

### `stores.*.extra_exe_folders`

Folders holding other executables that the same title starts, like `["FEARXP", "FEARXP2"]` for F.E.A.R. Platinum, whose expansions Heroic launches from the one install.

* A plain name is a folder under the game's exe folder. A name starting with `game_root:` is under the install folder instead, for builds that sit side by side. Steam's Aliens versus Predator Classic 2000 lists `["game_root:bin", "game_root:bin_Crossplay"]`, because its launcher runs either one.
* List every such folder, including the main one. Whichever folder is the exe folder gets skipped.
* Each folder gets the same game-folder files as the main exe, and folders missing from an install are skipped. The prefix, the registry and the launcher override are shared.
* When Steam lists the extra games as separate apps with their own prefixes, as it does for F.E.A.R.'s expansions (AppIDs 21110 and 21120), give each its own entry with its own `exe` instead. The exception is an app that runs this entry's exe from its own folder. That's what `companion_apps` is for.

### `stores.*.companion_apps`

Steam only. AppIDs of other Steam apps that run this game's exe from its folder with different arguments. DOOM 3's Resurrection of Evil is `[9070]`, and it runs `Doom3.exe +set fs_game d3xp`.

The game-folder files and settings are shared already, but Steam gives each of these apps its own Proton prefix and launch options. So the install also sets up each one's OpenAL runtime, prefix DLLs, VC++ runtime, registry and DLL override. Uninstall puts them back, and Tools → VC++ install covers them.

A companion app that isn't installed is skipped. One that hasn't been launched yet, so it has no prefix, gets the usual "launch it once, then check again" prompt.

### `stores.*.store_details`

Prose about what's specific to this store's listing, such as:

* differences in the engine or audio path ("It comes with NewDark pre-installed...")
* how the game came to be delisted
* packaging quirks ("Heroic installs this bundle as two separate library entries")
* facts that say which build it is ("Both stores sell this as the 'Planetary Pack'", "This is the original 1999 Planescape: Torment")

A few rules apply:

* A game that isn't an Enhanced Edition, remaster or remake never mentions one. That goes for `store_details`, `notes` and every other field, even to say it isn't one. Only the Enhanced Edition's or remaster's own `notes` may point back to the classic ("If you also own the classic...").
* The exception is a store that sells them together. Its `store_details` may name everything in the bundle, remaster included: "DOOM 3 is sold as a bundle with Resurrection of Evil and DOOM 3: BFG Edition."
* If a fact applies to more than one store, repeat the text in each store's block. Write each copy so it stands on its own and never refers to "the other store" or "the Steam version", because a player only sees one store's block.
* Don't name the script's own parts (DSOAL, OpenAL Soft) or talk about "paths" or "intercepting". State the fact and let the script say what it will use.

### `stores.*.patches`

Prose for this store's build, shown under "Suggested community patches:". It lists community patches and mods worth knowing about: TFix and T2Fix, SilentPatch, Sneaky Upgrade, the Unofficial Patches and so on.

Include patches that are also the practical way to get a legitimate copy of a delisted game, like OldUnreal's patches. Present a community OpenAL reimplementation as a good alternative to this script's approach, not as a second-best fallback. Don't use `patches` to suggest buying the game from another retailer. That goes in `notes`.

## `eax`

How the game does 3D audio, and whether EAX works in the current build.

### `eax.api`

Required: `"directsound3d"` or `"openal"`. This is the game-level audio API. It applies to any store without its own `api` override and to installs outside a store, and it decides which engine the script installs.

### `eax.versions`

The EAX versions the game supports, as strings. Only fill it in from a source you can point to: the game's manual or readme, its in-game audio menu, or a maintained compatibility database. Cite the source in `sources` or in your PR description. Leave it out for a `"not_implemented"` game.

### `eax.status`

Leave it out when EAX works. `"supported"` is the default.

| Value | Meaning |
| --- | --- |
| `"removed_by_patch"` | An update stripped EAX or A3D from the current build. An older build or a branch may restore it. |
| `"not_implemented"` | A remaster or rewrite that never had EAX. No build-level fix exists. |
| `"built_in"` | EAX already works in this build without the script, for example because it ships its own OpenAL32.dll with EAX. The install says so and asks "Install anyway?", which defaults to No. |

### `eax.problem`

Why the current build is in that state. It appears in the profile's `Status:` block. A game with `supported` status can fill it in too, for a known limitation. Otherwise leave it empty. Every entry is a current store listing, so don't add "make sure you're patched to at least version X" advice.

### `eax.fix`

How to get a build where EAX works, such as a Steam beta branch or a retail or CD copy. It applies to the whole game, not to one store. Settings in the game's own config files belong in `game_config`, not here.

### `eax.fix_in_place`

Set it to `true` only when `fix` works on the same install the script is already looking at, like a Steam beta branch. The install then warns and still offers "Continue installing anyway?". Leave it out when the only fix is a separate install, such as a pre-patch retail copy. The install then stops, as it does for `"not_implemented"`.

## `install`

What the install itself does differently for this game.

### `install.tweaks`

A list drawn from the values below. Each one turns the matching Advanced Compatibility Tweak into a prompt that defaults to yes. For an OpenAL-native install (`eax.api` is `openal`), only `expand_audio_limits` is offered, and the other two are ignored.

| Value | Use it for |
| --- | --- |
| `"eax_unified"` | Games that reach EAX through Creative's `eax.dll` "EAX Unified" shim instead of native DirectSound3D. It offers the EAX Unified dummy files, after checking whether the game ships its own `eax.dll`. |
| `"expand_audio_limits"` | A game independently verified to need it, like F.E.A.R., whose audio drops out in large firefights. |
| `"com_registry_routing"` | A game independently verified to need it, like Grand Theft Auto: San Andreas. |

### `install.alsoft_ini`

OpenAL Soft settings offered for this game in the Game Audio Settings step (phase 3), written as section, key, value strings. Only these keys are allowed:

| Key | What it does |
| --- | --- |
| `reverb.boost` | Decibels added to all reverb. Raise it for a game whose reverb is hard to hear. |
| `general.sources` | How many sounds the game can play at once. |
| `general.frequency` | The sample rate sound is mixed at, in Hz. |
| `general.default-reverb` | The reverb preset used where the game doesn't choose one. |
| `general.resampler` | How sounds at another sample rate are converted. |

For a game with quiet reverb that's `{ "reverb": { "boost": "6" } }`. Listen for the reverb popping before you settle on a value.

### `install.alsoft_tested`

Set it to `true` once the `alsoft_ini` values are verified on a real install. Without it they count as unverified and are treated like an untested setting: hidden unless `EAX_RESTORE_UNTESTED_SETTINGS=1`, and tagged "(untested)" when shown.

## `game_config`

Changes to the game's own config files, or to its registry settings, offered in the Game Settings step. The player sees each file, each setting and its current and new values, and confirms. Uninstall puts the original values back and leaves alone anything the player has changed since.

### `game_config.files`

The config files, each keyed by file name. A file has the fields below.

#### `format`

| Value | Layout | Example |
| --- | --- | --- |
| `"ini"` | `[Section]` headers with `key=value` lines | |
| `"flat_ini"` | `key=value` lines with no `[Section]` headers | Thief: Deadly Shadows' `options.ini` |
| `"idtech_cfg"` | `seta key "value"` lines | id Tech games |
| `"dark_cfg"` | NewDark's `key value` lines, where a bare `key` turns a flag on and `;key` turns it off | |
| `"brace_cfg"` | `{key} = {value}` lines | Fallout Tactics' `bos.cfg` |
| `"gas_cfg"` | A `[section]` with `key = value;` lines between `{` and `}` | Dungeon Siege's `prefs.gas` |
| `"ltx"` | `key value` lines with no sections | S.T.A.L.K.E.R.'s `user.ltx` |
| `"gadb"` | Monolith's binary game database. The script can only switch a setting the file already has on or off, so the values are `"0"` or `"1"`. | F.E.A.R.'s `Profile000.gdb` |
| `"wine_reg"` | For a game that keeps its options in the registry | Descent 3 |

A `"wine_reg"` file works differently from the rest:

* The "file" is the prefix's `system.reg` (for `HKEY_LOCAL_MACHINE`) or `user.reg` (for `HKEY_CURRENT_USER`), and it is keyed `"system.reg"` or `"user.reg"`.
* Only number (dword) and text values can be changed, and numbers are written in decimal.
* The script waits for Wine to save the registry and exit before it changes anything, and it won't do that while the game is running.

#### `locations`

Where to look, in order, written as `"base:path"`. The first one that exists is used. The bases are:

| Base | Points at |
| --- | --- |
| `game_exe` | The folder the game's exe runs from |
| `game_root` | The game's top-level install folder |
| `prefix_documents`, `prefix_appdata`, `prefix_localappdata` | Inside the Wine prefix's user folder |
| `prefix_public_documents` | The prefix's shared `Public\Documents`, where F.E.A.R. keeps its profiles |
| `prefix` | For a `wine_reg` file only, as `"prefix:system.reg"` or `"prefix:user.reg"` |

> [!WARNING]
> Paths can't contain `..`, a leading `/` or backslashes. A file name under `files` must end in `.ini`, `.cfg`, `.gdb`, `.reg`, `.txt`, `.ltx` or `.gas`. A location must end in `.ini`, `.cfg`, `.gdb`, `.txt`, `.ltx` or `.gas`, except that a `wine_reg` file takes only `prefix:` locations.

#### `all_locations`

Set it to `true` to change the file in every location that exists, not just the first. Brothers in Arms keeps `bia.ini` in its game folder and also in the prefix's AppData, so it needs this. Leave it out when the locations are alternatives for different builds, as in STALKER's `user.ltx`. The Game Settings step shows the full path of every file it changes.

#### `if_missing`

What to do when the file doesn't exist.

| Value | What happens |
| --- | --- |
| Omitted | For files the game writes on first launch. The script asks the player to launch the game once, then looks again. |
| `"skip"` | For files only some builds have. NewDark's `cam_ext.cfg` isn't in the stock Steam Thief games, for instance. Only that file's part of a setting is left out, and the Game Settings step and the closing summary say so ("left out: Thief Gold has no cam_ext.cfg"). |
| `"create"` | Creates the file in the first location whose folder exists, like Quake 4's `autoexec.cfg`. |

#### `crash_marker`

Optional. The name of a file the game keeps next to this config file while it runs and deletes when you quit from its own menu. If it's left behind, the game resets the config file on its next start. BioShock's `Running.ini` is one. The script removes the marker before changing the file, as long as the game isn't running, and never puts it back on uninstall.

### `game_config.audio_settings`

Settings that turn on EAX and 3D sound, or make them sound right, so the player doesn't have to. They're confirmed together with one prompt that defaults to yes.

### `game_config.optional_settings`

Quality-of-life settings that EAX doesn't need, like Quake 4's low-resolution textures fix. They're offered separately, and the player picks which to apply.

### A setting

Each entry in `audio_settings` and `optional_settings` has the fields below.

#### `title` and `reason`

The `title` starts with Enable, Fix, Remove or Raise, followed by the result the player gets, like `"Enable EAX reverb"`. Reuse the same title for the same result across games. It can be at most 60 characters.

The `reason` is one or two short sentences. It starts with the game's name and says what the game does out of the box. It doesn't repeat the settings that the rows beneath it already show.

#### `changes`

The shape depends on the file's format:

* `ini` and `gas_cfg` files: file, then section, then key, then value.
* `flat_ini`, `idtech_cfg`, `dark_cfg`, `brace_cfg`, `ltx` and `gadb` files: file, then key, then value.
* `wine_reg` files: file, then registry key, then value name, then value.

For `wine_reg`, give the key path as the `.reg` file shows it below its hive: `{ "system.reg": { "Software\\Wow6432Node\\Outrage\\Descent3": { "Name": "3" } } }`. The script also finds it without `Wow6432Node\` in a 32-bit prefix.

Values are strings made of letters, digits, spaces and the characters `. _ ( ) -`. Section and key names allow the same, without the brackets. Anything else fails the schema. `true` and `false` switch a `dark_cfg` flag, and `null` removes the key. Every file you mention must be listed in `files`.

#### `only_if`

Optional conditions. `{ "stores": ["gog"] }` limits a setting to some stores, and `{ "speakers": ... }` limits it to an answer from the Speaker Configuration step. The speaker values are:

| Value | Matches |
| --- | --- |
| `"stereo"` | Stereo. It also covers Headphones, unless the game has its own `"headphones"` setting. |
| `"headphones"` | Stereo first, then Headphones |
| `"matrix"` | Matrix |
| `"surround"` | Any surround layout |
| `"quad"`, `"surround51"`, `"surround61"`, `"surround71"` | That exact layout |
| `["surround51", "surround61"]` | Any layout in the list |

If a setting depends on a file that only some builds have, use `if_missing: "skip"` instead of a store condition.

#### `follow_up`

Optional. Something the player should do after the install. It appears in the final summary's "Before you play" box and in the profile browser: `"Open Options -> Video and click Autodetect."`

#### `tested`

Optional. Set it to `true` once the setting is verified on a real install, and it shows "(tested)". A setting without it, or with `false`, is unverified. It stays hidden unless the player sets `EAX_RESTORE_UNTESTED_SETTINGS=1`, and shows "(untested)" when it appears.

## `sources`

The pages that back up the entry's claims. The short "(per PCGamingWiki)" citations in the prose point here. They're listed last on the script's game profile screen as clickable links.

Give each one a name: `{ "title": "PCGamingWiki: Quake 4", "url": "https://www.pcgamingwiki.com/wiki/Quake_4" }`. A bare URL string still works, and it shows just the address. The script prints each address under its name, so any terminal can open it.

## `notes`

Caveats that no other field covers: pointers to sibling entries, notes that set expectations ("reverb here is subtle, and that's expected, not a bug"), and controller, multiplayer or mod quirks.

## Line breaks in long text

These fields can hold line breaks: `description`, `notes`, `store_details`, `patches`, `eax.problem`, `eax.fix`, and a setting's `reason` and `follow_up`. Write `\n` in the JSON (or press Enter in the profiler's editor) for a new line, and `\n\n` for a blank line between paragraphs. Don't break lines just to wrap them. The script wraps text to fit the screen.
