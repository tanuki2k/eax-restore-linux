# EAX Restore for Linux (Steam/Proton & Heroic/Wine)

A streamlined Bash script designed to automate the installation of DSOAL and OpenAL Soft for classic Windows games running on Linux.

**How it works:** Back in the late 90s and early 2000s, PC audio was built differently. Games relied heavily on DirectSound3D and Creative's EAX technology to deliver hardware-accelerated spatial audio and dynamic environmental reverb. If you walked into a cave, the echoes changed; if a guard walked behind a thick wall, their footsteps became muffled. Games like *Thief: The Dark Project*, *F.E.A.R.*, *Max Payne 2*, and *Star Wars: Knights of the Old Republic* used EAX to create incredibly immersive soundscapes that modern software audio often flat-out ignores.

Because modern operating systems and Proton/Wine don't natively support this old hardware pipeline, those advanced audio options are usually grayed out. This script fixes that by deploying **[DSOAL](https://github.com/kcat/dsoal)** (DirectSound3D Object Audio Library) alongside **[OpenAL Soft](https://github.com/kcat/openal-soft)** directly into your game folder. Together, they act as a translation layer. They intercept legacy EAX calls and convert them into standard OpenAL, tricking the game into unlocking its hardware-accelerated audio options and processing the 3D sound flawlessly on your modern CPU.

**Disclaimer:** I've tested this script heavily across various games and launchers, but please use it at your own risk. If you find any bugs, please report them on the issue tracker and I'll do my best to fix them!

**A Personal Note:** While installing DSOAL manually is a known process, it's a tedious, multi-step task involving file hunting and registry edits, inspired by kevinlekiller's project **[reshade-steam-proton](https://github.com/kevinlekiller/reshade-steam-proton)** I wanted a way to streamline the procress. Since I'm not a coder, I built this tool with the assistance of Google Gemini, and it's continued to evolve since with the help of Claude.

## Features

* **Dual-Copy Deployment:** Deploys DSOAL/OpenAL files to both your local game folder *and* the Wine/Proton prefix's system folders, with conflict backups on both — not just the game folder.
* **Engine Choice:** kcat's DSOAL + OpenAL Soft (translates DirectSound3D/EAX to OpenAL) for the vast majority of games, or a direct OpenAL Soft swap for the handful that call OpenAL natively. When the Audio API Detection step has already pinned down which one the game uses, the engine menu is skipped automatically; you're only asked to pick when the API couldn't be confirmed. You then pick the builds: **Stable** (a tested DSOAL revision + OpenAL Soft's newest release, the default), **Latest** (DSOAL's newest build + OpenAL Soft's pre-release), or each separately. Only the builds you pick are downloaded, and every download is checked against its SHA256.
* **Dynamic HRTF Integration:** Automatically generates an `alsoft.ini` tuned to your output (stereo/headphones/surround/matrix), enabling OpenAL Soft's HRTF binaural rendering for headphone users.
* **Smart Architecture Scanner:** Automatically detects whether the game executable is 32-bit or 64-bit and grabs the exact right dependencies so the game doesn't crash on launch.
* **Intelligent Prefix Routing:** Opt-in auto-detection for Steam AppIDs and Heroic Prefix paths, making it easy to find where your game is actually installed. Uninstall and Tools list every game this script is installed in, most recently used first, found from the install records in your Steam and Heroic folders.
* **Library Scanning:** Opt-in scan of your Steam and Heroic libraries against the community-maintained game database — pick a match from the list instead of hunting down the install folder yourself.
* **Deep Prefix Validation:** Verifies Steam AppIDs via Protontricks and ensures Heroic prefixes are fully initialized before touching any files.
* **Cache & Offline Mode:** Smart GitHub API downloading with local caching, so if you install the fix to multiple games, it only downloads the files once. Pinned/live checksum verification guards against corrupt or tampered downloads.
* **Safe File Management:** Interactive conflict resolution safely backs up pre-existing files with timestamps so you never lose original game data. Every install writes a manifest of exactly what it deployed, so uninstall only ever removes what this script actually put there and restores your backups automatically.
* **COM Registry Injection:** Optional routing of DirectSound CLSIDs directly in the Wine registry. This fixes the stubbornly grayed-out EAX menus in games like *Grand Theft Auto: San Andreas* or *Halo: Combat Evolved*.
* **Advanced Engine Tweaks:** Optional EAX Unified dummy files (`eax.dll`/`eaxunified.dll`) and expanded audio limits to fix stuttering in chaotic, high-channel games like *F.E.A.R.*
* **Automatic DLL Overrides:** Sets the `dsound`/`openal32` override for you — in the game's Steam launch options or Heroic environment variables (the default, so it's visible and easy to undo there), or in the Wine prefix registry — or leaves it to you, with instructions. Existing launch options are kept, and uninstall puts them back.
* **Change an Installed Game:** Tools → **[O]ptional settings** turns a game's optional settings on or off after the install, and **[S]peaker configuration** switches its speaker setup (stereo, headphones/HRTF, surround, matrix) along with any of the game's own settings that go with it, like BioShock's speaker mode. Both only touch games this script installed to, and uninstall still puts back every original value.
* **Browse Game Profiles:** Tools → **[B]rowse game profiles** lists every game in the database with a fuzzy search — **Ctrl-A** and **Ctrl-S** narrow it by audio (DirectSound3D, OpenAL or an EAX version) and store (Steam, GOG, or the games delisted from either or one of them), **Ctrl-R** switches between best match first and A–Z, and **Ctrl-L** puts the profile beside or under the list — and shows the selected game's profile beside the list — the same screen the install shows when you pick it, covering every store it's on, with anything that differs between Steam and GOG shown for each. **Tab** switches to the game's settings in full: why each one is offered, the file and where it lives, and the exact values it sets. **Shift-↑/↓** and **PgUp/PgDn** scroll the profile, and **Ctrl-F** opens it full screen (q comes back). **F1** lists every key, most useful first.
* **DSOAL Logging:** Tools → **[D]SOAL logging** turns DSOAL's own log on or off for one game, without editing launch options by hand. Useful for checking which EAX version a game really uses, or for a bug report.
* **VC++ Runtime Handling:** Detects and installs the Microsoft VC++ 2022 Redistributable that older Proton/Wine builds need to load kcat's DSOAL / OpenAL Soft, falling back to a direct Microsoft download if winetricks/protontricks fails, and verifying the actual DLLs on disk rather than trusting exit codes.
* **Safety Guards:** Refuses to run as root or from Steam's Gaming Mode, and won't auto-modify SteamOS's immutable filesystem.

## Prerequisites

The script checks for these dependencies and offers to install them if they are missing:
* `curl`, `unzip`, `file`, `grep`, `awk`, `jq`

**Launcher Dependencies:**
* **Steam Games:** Requires `protontricks`.
* **Heroic/GOG Games:** Requires `winetricks`.

`jq` powers checksum verification for kcat's official builds, as well as the game database used for install-time notes and library scanning (see below).

**Optional:** `fzf` 0.35 or newer for Tools → **[B]rowse game profiles** (0.58 or newer draws each part in its own box). The script offers to install it the first time you open the browser.

## Usage

> Prefer a manual download? Grab the script and the Steam Deck `.desktop` launcher from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) instead of the steps below.

> **Testing the development build?** Every change on the `dev` branch is auto-published as a pre-release. Download it from `https://github.com/tanuki2k/eax-restore-linux/releases/download/dev/eax-restore-linux.sh` — its startup banner shows a `-dev` version plus the build date and commit, so you can always tell it apart from a stable build. It's unstable and unsupported; the `.desktop` launcher always fetches the stable latest release only.

> **Just want to check what it does or which version you have?** Run `./eax-restore-linux.sh --help` or `--version` — both print instantly without starting the interactive install/uninstall flow.

### What it looks like

A real terminal session, from launch through the first configuration step (`EAX_RESTORE_SKIP_PREFLIGHT`/`EAX_RESTORE_SKIP_CACHE_CHECK` used here only to keep this excerpt short and reproducible — a normal run also includes the pre-flight tool scan before reaching this point):

```ansi
[0;36m[1m==========================================================[0m
[0;36m[1m   DSOAL & OpenAL Soft Universal Installer                [0m
[0;36m[1m   v0.29  (2026-08-13)[0m
[0;36m[1m==========================================================[0m

[0;36m----------------------------------------------------------[0m
[0;32m[1m--- PRE-FLIGHT SYSTEM CHECK ---[0m
[0;36m----------------------------------------------------------[0m

[0;94mNote: EAX_RESTORE_SKIP_PREFLIGHT is set — skipping the tool scan and trusting that curl,
unzip, file, protontricks, winetricks, wine, and jq are already available.[0m

[0;36m----------------------------------------------------------[0m
[0;32m[1m--- SELECT OPERATION ---[0m
[0;36m----------------------------------------------------------[0m

[1;37mWhat would you like to do?[0m

 [S]can your Steam/Heroic library
 [B]rowse for the game folder
 [M]anually type the game path

 [U]ninstall the EAX fix
 [T]ools

 [Q]uit

[1;33mSelection [s/b/m/u/t/q]: [0m
> m

[0;36m----------------------------------------------------------[0m
[0;32m[1m--- PHASE 1: CONFIGURATION ---[0m
[0;36m----------------------------------------------------------[0m

[0;36m----------------------------------------------------------[0m
[0;36m1/11. Game Location[0m
[0;36m----------------------------------------------------------[0m

[1;37mCommon game locations:[0m

[1;37m Linux Desktop (Steam): ~/.local/share/Steam/steamapps/common/[Game][0m
[1;37m Steam Deck (SD Card):  /run/media/mmcblk0p1/steamapps/common/[Game][0m
[1;37m Heroic / GOG:          ~/Games/Heroic/[Game][0m

[1;33mEnter the full path to the game's .exe folder:[0m
> 

```

**1. Download the script:**
Open your terminal and run:

```bash
curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh
```

**2. Make it executable:**
In the same terminal, run:

```bash
chmod +x eax-restore-linux.sh
```

> **Verifying the download (optional):** every release also publishes a `.sha256` checksum file for the script. If you'd like to confirm your download hasn't been corrupted or tampered with:
> ```bash
> curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh.sha256
> sha256sum -c eax-restore-linux.sh.sha256
> ```

**3. Run the installer:**

```bash
./eax-restore-linux.sh
```

**4. Follow the prompts:**
Pick from the main menu — scan your Steam/Heroic library, browse for the game folder, or type its path to install; or uninstall the fix, or open Tools — then follow the steps for your game and select your preferred audio configuration.

### Steam Deck Quick Install (Desktop Mode)

As an alternative to the terminal steps above, [`eax-restore-linux.desktop`](eax-restore-linux.desktop) is a double-click launcher for Desktop Mode:

1. Switch to **Desktop Mode** and download [`eax-restore-linux.desktop`](https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.desktop) from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) (e.g. to your Desktop or Downloads folder).
2. In Dolphin, right-click it and enable **Allow Executing File as Program** (Properties → Permissions), since Plasma won't run it otherwise.
3. Double-click it and select **Execute**. It fetches the latest script into your home folder (`~/eax-restore-linux.sh`, overwriting any previous copy) and runs it in a terminal — nothing is installed until you follow the prompts, same as running the script manually. The downloaded copy is left behind afterward, so you can re-run it later (e.g. for uninstalls, or another game) without launching the `.desktop` file again.

Since the script itself refuses to run in Gaming Mode, this only works from Desktop Mode.

### Uninstallation
Run the script, choose **[U]ninstall the EAX fix**, and provide the game directory. The script will remove the EAX files, restore original backups, remove the DLL override (from the registry or the launcher's settings), optionally remove the VC++ runtime it installed, and offer to put back any game settings it changed (leaving alone anything you've changed yourself since). Like the install, it asks everything first — which files to remove, whether to close a running launcher, the VC++ runtime, which game settings to put back — and changes nothing until you confirm with one final "Proceed?".

### Library Scanning & the Game Database

During install, the script can optionally scan your Steam and Heroic libraries for titles it recognises, so you can pick a game from a list instead of browsing to its folder manually. Matches are checked against [`game-database.json`](game-database.json), a community-maintained database in this repo (built from the per-game files in [`data/games/`](data/games/)) that's fetched fresh on every run (and cached locally so a later offline run still works). The same database also drives the install-time "Heads up" notes, the "this install would be a no-op" warnings, the delisted-storefront notice, the OpenAL-vs-DirectSound3D compatibility check ("Audio API Detection") for specific titles, and the **Game Settings** step: for games that ship with EAX (or other things) switched off in their own config files, it shows each setting's current and recommended value and applies the ones you accept — audio fixes together, optional non-audio fixes (like Quake 4's low-res textures) one by one.

This list is deliberately small and hand-verified — it will only ever cover a fraction of EAX-capable games. If your game isn't in it, the OpenAL-vs-DirectSound3D check falls back to scanning the game's own `.exe`/`.dll` files for `OpenAL32.dll`/`dsound.dll` references — a lower-confidence guess, clearly flagged as such. When even that is inconclusive (or you skip the scan), the script asks you to pick between DirectSound3D/DSOAL and OpenAL native rather than silently assuming DirectSound3D — DirectSound3D is the default, and this prompt is also the only way to select OpenAL-native mode for a game nothing could identify.

**Retail/CD copies and other non-Steam, non-Heroic installs** (e.g. an original pre-Steam Half-Life disc, run in a Wine prefix you set up yourself) aren't covered by the scanner at all, since there's no launcher library to scan — but the script still supports them. Point it at the game's `.exe` folder and provide the Wine prefix path manually when prompted.

**Contributing to the game database:** PRs adding or correcting games are welcome. Each game is its own file, `<id>.json`, where `<id>` is a kebab-case version of its name (`quake-4.json`, `thief-ii-the-metal-age.json`). Which folder it's in says how far it's got:

- `data/games/tested/` — checked against a real install: its store IDs match, its `exe` exists, and any config files and settings it changes are where it says. Shipped.
- `data/games/untested/` — not checked on a real install yet. Shipped all the same. New games go here.
- `data/drafts/` — incomplete or doubtful entries. Checked against the schema and formatted, but **not** shipped.

To promote a game, move its file (`git mv`) and re-run `tools/format-game-database.sh`, which also updates its `"$schema"` line for the new folder. The formal definition of every field is [`data/schema.json`](data/schema.json); pointing your editor at it (each file's `"$schema"` line does this in VS Code and most JSON-aware editors) gives autocompletion and flags mistakes as you type. Don't edit `game-database.json` by hand — it's generated from the per-game files. After editing, run:

```bash
tools/format-game-database.sh      # puts keys in the standard order and drops empty/default fields
tools/build-game-database.sh       # regenerates game-database.json
```

CI checks every file against the schema, that it's formatted, and that `game-database.json` is up to date. Please only add a store `id` you've independently verified against the storefront's own page or API — a wrong ID would point the script at someone else's prefix. **Leave a field out when it's empty or at its default** — there are no `null`s in these files.

To find what a game setting should change, run the script from a checkout with `EAX_RESTORE_DEV=1 ./dist/eax-restore-linux.sh` and pick Tools → **Probe game settings**. It snapshots the game's config files, launches the game (quit from the main menu without changing anything), installs the fix, launches it again (switch the sound options on, then quit), and proposes the keys that changed (in its config files or its registry) as a new audio setting in the game's file, titled "Enable EAX reverb" with a TODO reason for you to write. It can then launch the game a third time (change the other options worth offering, then quit) and propose those as an optional setting with a TODO title and reason. Only games that already have a file are listed — for a new one, add a `data/drafts/` file with its name and store ID first. Before the first launch it also lists the game's config files, the setting names in its exes and DLLs, and its bundled OpenAL and Miles 3D providers.

`tools/browse-game-database.sh [database.json]` browses the built `game-database.json` with the same browser as Tools → **[B]rowse game profiles** (it needs `fzf`): rebuild, then check how your entry's profile reads to players.

A game file looks like this (see `data/games/tested/` for more):

```json
{
  "$schema": "../../schema.json",
  "name": "Quake 4",
  "exe": "Quake4.exe",
  "stores": {
    "steam": { "id": 2210 },
    "gog": { "id": 1836059896 }
  },
  "eax": { "api": "openal", "versions": ["4.0", "5.0"] },
  "game_config": {
    "files": {
      "Quake4Config.cfg": { "format": "idtech_cfg", "locations": ["game:q4base/Quake4Config.cfg"] }
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

- `name` — display name.
- `description` — one sentence on what the game is, shown in its profile's Description section in Tools → **[B]rowse game profiles** (not during an install). Follow PCGamingWiki's pattern in your own words — modes, perspective, genres, then the series if it has one: "Deus Ex is a singleplayer and multiplayer first-person action role-playing and immersive sim game in the Deus Ex series." Don't repeat what another field already says — what a bundle includes, which build it is, or a delisting belongs in `store_details` or `notes`. An Enhanced Edition, remaster or Anniversary Edition names the original and its year ("…, an enhanced edition of 2000's Baldur's Gate II: Shadows of Amn."); a bundle names its base game ("…, an expanded edition of Thief: The Dark Project.") only when no other field already does. An expansion names the game it's for rather than its series ("…horror expansion for F.E.A.R."). Leave out anything you can't confirm (e.g. the modes) rather than guess.
- `released` — the game's first Windows release, earliest region, as `YYYY-MM-DD` (or `YYYY-MM` / `YYYY` when only that much is verifiable), shown as the profile's "Released" row. Cross-check at least two sources (Wikipedia's infobox is a good start); a console release that came first doesn't count. A bundle, Gold, Complete, GOTY or Classic edition takes its base game's date; an Enhanced Edition, Remaster or Anniversary Edition — a separate build — its own. Not the date a store started selling it: stores often show the original date anyway, or a re-listing.
- `exe` — the main game executable's **file name only**, e.g. `"DeusEx.exe"`, as it appears in a real install. The scanner picks the folder holding it, which handles layouts its name matching gets wrong (e.g. Splinter Cell: Double Agent's separate single-player and multiplayer builds), and a hand-typed folder that doesn't contain it gets a warning. Only add it after checking a real install.
- `stores` — an object with a `"steam"` and/or `"gog"` key; **omit a store key entirely when the game isn't sold there** (a GOG-only game has no `"steam"` key, so "GOG only" needs no prose). Each store block holds:
  - `id` — the numeric Steam AppID / GOG game ID, used for library-scan matching. For GOG, use the ID Heroic installs the game under (its `appName`, the same as the `gameId` in the game folder's `goggame-<id>.info`). For a game GOG only sells inside a pack, that's the game inside it, never the pack: Dungeon Siege's store page is the Dungeon Siege Collection (1142020247), but the game is 1185868626. `https://api.gog.com/products/<id>` reports `"game_type": "pack"` for a pack.
  - `delisted` — `true` when the game has been pulled from sale there (existing owners keep access). Availability only, not pricing.
  - `id_source` — omit it when you checked the ID against the store's own page/API (the default). `"local_install_verified"` means it was also confirmed against a real local install; `"steamdb_historical"` means the store page is gone and the ID is SteamDB's historical record, not checked locally — only that one shows a line in the game-details display.
  - `api` — `"directsound3d"` / `"openal"` to override `eax.api` for **this store's build only**. Set it only where a storefront's current build genuinely differs (e.g. Thief Gold / Thief II: `eax.api` is `"directsound3d"`, but GOG's build comes with NewDark pre-installed, which runs audio and EAX reverb through OpenAL, so its `gog` block has `"api": "openal"`).
  - `beta_branch` — Steam only. The exact `BetaKey` name (right-click the game -> Properties -> Betas) of a beta branch that restores EAX on this store's build — set only when `eax.fix` names one. Lets the install-time check detect whether the user's local appmanifest already has this branch opted into/mounted, instead of always showing the `removed_by_patch` warning.
  - `extra_exe_folders` — GOG only. Folders under the game's exe folder that hold another exe started from the same title, e.g. `["FEARXP", "FEARXP2"]` for F.E.A.R. Platinum, whose expansions Heroic launches from the one install. Each gets the same game-folder files as the main exe (folders missing from an install are skipped), and the prefix, registry and launcher override are shared. Where Steam lists the extra games as separate apps with their own prefixes (F.E.A.R.'s expansions are AppIDs 21110 and 21120), give each one its own entry with its own `exe` instead — unless they run this entry's own exe from its own folder, which is what `companion_apps` is for.
  - `companion_apps` — Steam only. AppIDs of other Steam apps that run this game's exe from its own folder with different arguments, e.g. `[9070]` for DOOM 3's Resurrection of Evil (`Doom3.exe +set fs_game d3xp`). The game-folder files and its settings are already shared, but Steam gives each one its own Proton prefix and launch options, so installing the game sets those up too (OpenAL runtime, prefix DLLs, VC++ runtime, registry, DLL override), uninstall puts them back, and Tools → VC++ install covers them. A companion that isn't installed is skipped; one that hasn't been launched yet (no prefix) gets the usual "launch it once, then check again".
  - `store_details` — prose about what's specific to **this store's listing**: engine/audio-path differences ("It comes with NewDark pre-installed…"), delisting circumstances, bundling/packaging quirks ("Heroic installs this bundle as two separate library entries"), and build-identity/disambiguation facts ("Both stores sell this as the 'Planetary Pack'", "This is the original 1999 Planescape: Torment"). A game that isn't itself an Enhanced Edition, remaster or remake never mentions one — not in `store_details`, `notes` or any other field — even to say it isn't one; only an Enhanced Edition or remaster's own `notes` may point to the classic build ("If you also own the classic…"). The exception is a store that sells them together: `store_details` may then name every game in the bundle, the Enhanced Edition or remaster included ("DOOM 3 is sold as a bundle with Resurrection of Evil and DOOM 3: BFG Edition."). When a fact applies identically to more than one store, duplicate the prose into each relevant store block — and write each store's copy to stand on its own, never referencing "the other store's block" or "the Steam version" from within the GOG block (a user only ever sees one store's block). Don't name the script's own parts (DSOAL / OpenAL Soft) or talk about "paths" / "intercepting" — state the fact and let the script say what it will use.
  - `patches` — prose for **this store's build**, shown under "Suggested community patches:": community patch/mod recommendations (TFix / T2Fix, SilentPatch, Sneaky Upgrade, SCP…), including ones that — for a delisted game — also happen to be the practical way to get a legitimate full copy (e.g. OldUnreal's patches; frame a community OpenAL reimplementation as a strong alternative worth using instead of this script's approach, not as an inferior fallback). Not for "go buy it from a different retailer" content — that stays in `notes`.
- `eax` — how the game does 3D audio and whether EAX works on the current build:
  - `api` (required) — `"directsound3d"` or `"openal"`. The game-level audio API, used for any store without its own `api` override and for non-store installs; it also decides which engine the script installs.
  - `versions` — supported EAX version strings; only set from a verifiable source (the game's manual/readme, an in-game audio settings menu, or a maintained compatibility database) — cite it in `sources` or the PR description. Omit for a `"not_implemented"` game.
  - `status` — omit when EAX works (the default, `"supported"`). `"removed_by_patch"`: a software update stripped EAX/A3D from the current build (an alternate build/branch may restore it). `"not_implemented"`: a remaster/rewrite that never had EAX — no build-level fix exists. `"built_in"`: EAX already works in this build without the script (e.g. it ships its own OpenAL32.dll with EAX); the install-time check says so and asks "Install anyway?", defaulting to No.
  - `problem` — prose explaining *why* the current build is in that state, shown in the game-details `Status:` block. Since every entry is a current digital-store listing, don't add "make sure you're patched to at least version X" trivia.
  - `fix` — prose saying *how* to get a build where EAX works (a Steam beta branch, a retail/CD copy…). Game-level, not per store. Settings in the game's own config files belong in `game_config`, not here.
  - `fix_in_place` — `true` only when `fix` works on the *same install* the script is already pointed at (e.g. a Steam beta branch): the install-time check then warns and still offers "Continue installing anyway?". Omit it when the only fix is a separate install (e.g. a pre-patch retail copy) — the check then blocks, the same as `"not_implemented"`.
- `install` — what the install itself does differently for this game:
  - `tweaks` — any of `"eax_unified"`, `"expand_audio_limits"`, `"com_registry_routing"`. Each turns the matching Advanced Compatibility Tweak into a default-yes prompt:
    - `"eax_unified"` — for titles that reach EAX through Creative's `eax.dll` "EAX Unified" shim rather than native DirectSound3D. Drives a guarded prompt for the EAX Unified Dummy Files tweak (it checks whether the game ships its own `eax.dll` first).
    - `"expand_audio_limits"` — for a title independently verified to need it, e.g. F.E.A.R.'s audio dropping out during large firefights.
    - `"com_registry_routing"` — for a title independently verified to need it, e.g. Grand Theft Auto: San Andreas.
  - `alsoft_ini` — OpenAL Soft settings offered for this game in the Speaker Configuration step, as section → key → value strings. Only `reverb.boost` and `general.sources` / `frequency` / `default-reverb` / `resampler` are allowed. E.g. `{ "reverb": { "boost": "6" } }` for a game whose reverb is quiet — test that the value doesn't make the reverb pop.
- `game_config` — changes to the game's **own** config files (or its registry settings), offered in the Game Settings step. The player sees each file, setting and its current → new value, confirms, and uninstall puts the original values back (leaving anything the player has changed since alone).
  - `files` — each config file, keyed by its file name:
    - `format` — `"ini"` (`[Section]` + `key=value`), `"flat_ini"` (`key=value` lines with no `[Section]` headers, e.g. Thief: Deadly Shadows' `options.ini`), `"idtech_cfg"` (`seta key "value"`, id Tech games), `"dark_cfg"` (NewDark's `key value` lines, where a bare `key` turns a flag on and `;key` turns it off), `"brace_cfg"` (`{key} = {value}` lines, e.g. Fallout Tactics' `bos.cfg`), `"gadb"` (Monolith's binary game database, e.g. F.E.A.R.'s `Profile000.gdb`; it can only switch a setting the file already has on or off, so its values are `"0"` or `"1"`) or `"wine_reg"` (for a game that keeps its options in the registry, e.g. Descent 3: the prefix's `system.reg` for `HKEY_LOCAL_MACHINE` or `user.reg` for `HKEY_CURRENT_USER`, keyed `"system.reg"` / `"user.reg"`. Only number (dword) and text values can be changed, a number written in decimal; the script waits for Wine to save the registry and exit before changing it, and won't while the game is running).
    - `locations` — where to look, in order, as `"base:path"`; the first that exists is used. Bases: `game` (the exe's folder), `install` (the install root), `prefix_documents`, `prefix_appdata`, `prefix_localappdata` (inside the Wine prefix's user folder), `prefix_public_documents` (the prefix's shared `Public\Documents`, where F.E.A.R. keeps its profiles), and `prefix` for a `wine_reg` file, only as `"prefix:system.reg"` or `"prefix:user.reg"`. No `..`, leading `/` or backslashes.
    - `if_missing` — what to do when the file doesn't exist. Omit it for files the game writes on first launch (the script asks the player to launch the game once, then checks again); `"skip"` for files only some builds have (NewDark's `cam_ext.cfg` isn't in the stock Steam Thief games) — only that file's part of a setting is left out, and the Game Settings step and the closing summary tell the player ("left out: Thief Gold has no cam_ext.cfg"); `"create"` to create it (e.g. Quake 4's `autoexec.cfg`).
    - `crash_marker` — optional: the name of a file the game keeps next to this config file while it's running and deletes when quit from its own menu, which makes it reset the config file on its next start if left behind (BioShock's `Running.ini`). The script removes it, when the game isn't running, before changing the file, and never puts it back on uninstall.
  - `audio_settings` — settings that turn on EAX and 3D sound (or make them sound right), so the player doesn't have to; confirmed together with one default-yes prompt.
  - `optional_settings` — optional quality-of-life settings that aren't needed for EAX (e.g. Quake 4's low-res textures fix), offered separately so the player picks which to apply.
  - Each setting has:
    - `title` and `reason` — see CLAUDE.md's "Game setting `title` and `reason`" rules. In short: `title` is **Enable** / **Fix** / **Remove** / **Raise** plus the result the player gets (`"Enable EAX reverb"`), reused across games for the same result; `reason` is one or two short sentences, starting with the game's name, on what the game does out of the box — without repeating the settings the rows below it show.
    - `changes` — file → section → key → value for `ini` files, file → key → value for `flat_ini` and the cfg formats, and file → registry key → value name → value for `wine_reg`, with the key path as the `.reg` file shows it below its hive (`{ "system.reg": { "Software\\Wow6432Node\\Outrage\\Descent3": { "Name": "3" } } }`; the script also finds it without `Wow6432Node\` in a 32-bit prefix). Values are strings; `true`/`false` switches a `dark_cfg` flag; `null` removes the key. Every file must be listed in `files`.
    - `only_if` — optional conditions: `{ "stores": ["gog"] }` and/or `{ "speakers": ... }` (the Speaker Configuration answer): `"stereo"`, `"headphones"` (Stereo, then Headphones), `"matrix"`, `"surround"` (any surround layout) or one exact layout, `"quad"` / `"surround51"` / `"surround61"` / `"surround71"`; a list such as `["surround51", "surround61"]` matches any of them. Prefer `if_missing: "skip"` over a store condition when a setting depends on a file only some builds have.
    - `follow_up` — optional: something the player does after installing, shown in the final summary (`"Open Options -> Video and click Autodetect."`).
- `sources` — pages backing the entry's claims (the short "(per PCGamingWiki)" citations in the prose point here). They're listed last on the script's game profile screen as clickable links. Give each a name with `{ "title": "PCGamingWiki: Quake 4", "url": "https://www.pcgamingwiki.com/wiki/Quake_4" }`; a bare URL string still works and shows the site's address.
- `notes` — prose caveats not covered by the fields above: cross-references to sibling entries, limitation/expectation-setting caveats ("reverb here is subtle, that's expected not a bug"), controller/multiplayer/mod quirks.

### Environment Variables

For repeat runs or scripting, these can be set to skip prompts:

| Variable | Effect |
| --- | --- |
| `EAX_RESTORE_SKIP_PREFLIGHT=1` | Skips the pre-flight tool scan, trusting that `curl`, `unzip`, `file`, `protontricks`, `winetricks`, and `wine` are already available. |
| `EAX_RESTORE_DSOAL_PIN=1` | Uses the stable `kcat/dsoal` build (the revision pinned in the script, from kcat's `archive` release) without asking, so only the OpenAL Soft build is chosen. Also selects the DSOAL engine and jumps straight to install. |
| `EAX_RESTORE_VCRUN_ONLY=1` | Skips the full install/uninstall flow and just (re)installs the MS VC++ 2022 Redistributable into a game's prefix. The main menu offers the same under **Tools → [V]C++ install**. |
| `EAX_RESTORE_SKIP_CACHE_CHECK=1` | Doesn't contact GitHub for DSOAL or OpenAL Soft: the build choice only offers what's already in the local cache. |
| `EAX_RESTORE_GAME_DATABASE_FILE=/path/to/game-database.json` | Uses a local file (e.g. one you built with `tools/build-game-database.sh`) instead of fetching `game-database.json` — mainly for testing edits to the database itself before they're pushed. |
| `EAX_RESTORE_NO_LOG=1` | Turns off the per-run log file (see [Logs & Bug Reports](#logs--bug-reports)). |
| `EAX_RESTORE_DEV=1` | Adds Tools → **Probe game settings**, for adding a game's settings to the database. It lists the installed games that already have an entry, launches the one you pick, notices when it quits, installs the fix, launches it again while you switch its sound options on, then proposes the `game_config` for those changes (and, if you like, launches it a third time for optional settings). Run from a repo checkout's `dist/`, it merges the proposal into the game's file; elsewhere it saves it under `~/.cache/eax-restore-linux/probe/`. |
| `EAX_RESTORE_REPO=/path/to/checkout` | The repo checkout Probe game settings merges into, when the script isn't run from that checkout's `dist/`. |

### Logs & Bug Reports

Every run is saved to a log file in `~/.local/state/eax-restore-linux/logs/`, and the script prints its path when the run finishes. Each run gets its own timestamped file (the newest 10 are kept), and `latest.log` always points at the most recent one. Dev builds log separately, to `~/.local/state/eax-restore-linux/logs/dev/`.

The log contains everything shown on screen and your answers to the script's prompts, plus details useful for troubleshooting: your distro, kernel, and Wine/winetricks/protontricks versions, the output of the Wine, winetricks, and protontricks commands the script runs, and a summary of the detected game, prefix, runner (Proton/Wine version), architecture, and chosen engine.

For problems with how a game *sounds* once it's running, DSOAL's own log helps more. **Tools → [D]SOAL logging** adds `DSOAL_LOGLEVEL` and `DSOAL_LOGFILE` to the game's Steam launch options or Heroic environment variables, so DSOAL writes `dsoal.log` to the game folder each time the game starts. **Full** (level 4) logs every EAX call the game makes, which shows which EAX version it actually uses, but the log grows fast and the game may stutter. **Basic** (level 3) only covers startup and which EAX versions the game asks for. Run the utility again to turn it off; uninstalling the fix turns it off too.

If something goes wrong, please [open a bug report](https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md) and attach `~/.local/state/eax-restore-linux/logs/latest.log`. The log includes local file paths, which contain your username — feel free to redact them.

## Credits & Upstream Sources

This script automates the deployment of the following projects:

* **kcat (Christopher Robinson)** - [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft). The script deploys kcat's own builds: a pinned, tested DSOAL revision from the [`archive`](https://github.com/kcat/dsoal/releases/tag/archive) release or the newest `latest-master`/archive build, with OpenAL Soft's newest release or its rolling pre-release.
* **ThreeDeeJay** - upstreamed the Win32/Win64 packaging pipeline that kcat's daily DSOAL builds are now produced by.

## License
This script is provided under the [MIT License](LICENSE).
