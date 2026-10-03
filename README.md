# EAX Restore for Linux (Steam/Proton & Heroic/Wine)

A streamlined Bash script designed to automate the installation of DSOAL and OpenAL Soft for classic Windows games running on Linux.

**How it works:** Back in the late 90s and early 2000s, PC audio was built differently. Games relied heavily on DirectSound3D and Creative's EAX technology to deliver hardware-accelerated spatial audio and dynamic environmental reverb. If you walked into a cave, the echoes changed; if a guard walked behind a thick wall, their footsteps became muffled. Games like *Thief: The Dark Project*, *F.E.A.R.*, *Max Payne 2*, and *Star Wars: Knights of the Old Republic* used EAX to create incredibly immersive soundscapes that modern software audio often flat-out ignores.

Because modern operating systems and Proton/Wine don't natively support this old hardware pipeline, those advanced audio options are usually grayed out. This script fixes that by deploying **[DSOAL](https://github.com/kcat/dsoal)** (DirectSound3D Object Audio Library) alongside **[OpenAL Soft](https://github.com/kcat/openal-soft)** directly into your game folder. Together, they act as a translation layer. They intercept legacy EAX calls and convert them into standard OpenAL, tricking the game into unlocking its hardware-accelerated audio options and processing the 3D sound flawlessly on your modern CPU.

**Disclaimer:** I've tested this script heavily across various games and launchers, but please use it at your own risk. If you find any bugs, please report them on the issue tracker and I'll do my best to fix them!

**A Personal Note:** While installing DSOAL manually is a known process, it's a tedious, multi-step task involving file hunting and registry edits, inspired by kevinlekiller's project **[reshade-steam-proton](https://github.com/kevinlekiller/reshade-steam-proton)** I wanted a way to streamline the procress. Since I'm not a coder, I built this tool with the assistance of Google Gemini, and it's continued to evolve since with the help of Claude.

## Features

* **Dual-Copy Deployment:** Deploys DSOAL/OpenAL files to both your local game folder *and* the Wine/Proton prefix's system folders, with conflict backups on both — not just the game folder.
* **Engine Choice:** kcat's DSOAL + OpenAL Soft (translates DirectSound3D/EAX to OpenAL) for the vast majority of games, or a direct OpenAL Soft swap for the handful that call OpenAL natively. When the Audio API Detection step has already pinned down which one the game uses, the engine menu is skipped automatically; you're only asked to pick when the API couldn't be confirmed. `EAX_RESTORE_DSOAL_PIN` swaps in a frozen known-good DSOAL revision if a rolling build ever regresses.
* **Dynamic HRTF Integration:** Automatically generates an `alsoft.ini` tuned to your output (stereo/headphones/surround/matrix), enabling OpenAL Soft's HRTF binaural rendering for headphone users.
* **Smart Architecture Scanner:** Automatically detects whether the game executable is 32-bit or 64-bit and grabs the exact right dependencies so the game doesn't crash on launch.
* **Intelligent Prefix Routing:** Opt-in auto-detection for Steam AppIDs and Heroic Prefix paths, making it easy to find where your game is actually installed. Recently used game folders are remembered and offered as a quick pick on future runs.
* **Library Scanning:** Opt-in scan of your Steam and Heroic libraries against a community-maintained list of known EAX games — pick a match from the list instead of hunting down the install folder yourself.
* **Deep Prefix Validation:** Verifies Steam AppIDs via Protontricks and ensures Heroic prefixes are fully initialized before touching any files.
* **Cache & Offline Mode:** Smart GitHub API downloading with local caching, so if you install the fix to multiple games, it only downloads the files once. Pinned/live checksum verification guards against corrupt or tampered downloads.
* **Safe File Management:** Interactive conflict resolution safely backs up pre-existing files with timestamps so you never lose original game data. Every install writes a manifest of exactly what it deployed, so uninstall only ever removes what this script actually put there and restores your backups automatically.
* **COM Registry Injection:** Optional routing of DirectSound CLSIDs directly in the Wine registry. This fixes the stubbornly grayed-out EAX menus in games like *Grand Theft Auto: San Andreas* or *Halo: Combat Evolved*.
* **Advanced Engine Tweaks:** Optional EAX Unified dummy files (`eax.dll`/`eaxunified.dll`) and expanded audio limits to fix stuttering in chaotic, high-channel games like *F.E.A.R.*
* **Automatic DLL Overrides:** Sets the `dsound`/`openal32` override for you — in the game's Steam launch options or Heroic environment variables (the default, so it's visible and easy to undo there), or in the Wine prefix registry — or leaves it to you, with instructions. Existing launch options are kept, and uninstall puts them back.
* **VC++ Runtime Handling:** Detects and installs the Microsoft VC++ 2022 Redistributable that older Proton/Wine builds need to load kcat's DSOAL / OpenAL Soft, falling back to a direct Microsoft download if winetricks/protontricks fails, and verifying the actual DLLs on disk rather than trusting exit codes.
* **Safety Guards:** Refuses to run as root or from Steam's Gaming Mode, and won't auto-modify SteamOS's immutable filesystem.

## Prerequisites

The script checks for these dependencies and offers to install them if they are missing:
* `curl`, `unzip`, `file`, `grep`, `awk`, `jq`

**Launcher Dependencies:**
* **Steam Games:** Requires `protontricks`.
* **Heroic/GOG Games:** Requires `winetricks`.

`jq` powers checksum verification for kcat's official builds, as well as the known-EAX-games database used for install-time notes and library scanning (see below).

## Usage

> Prefer a manual download? Grab the script and the Steam Deck `.desktop` launcher from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) instead of the steps below.

> **Testing the development build?** Every change on the `dev` branch is auto-published as a pre-release. Download it from `https://github.com/tanuki2k/eax-restore-linux/releases/download/dev/eax-restore-linux.sh` — its startup banner shows a `-dev` version plus the build date and commit, so you can always tell it apart from a stable build. It's unstable and unsupported; the `.desktop` launcher always fetches the stable latest release only.

> **Just want to check what it does or which version you have?** Run `./eax-restore-linux.sh --help` or `--version` — both print instantly without starting the interactive install/uninstall flow.

### What it looks like

A real terminal session, from launch through the first configuration step (`EAX_RESTORE_SKIP_PREFLIGHT`/`EAX_RESTORE_SKIP_CACHE_CHECK` used here only to keep this excerpt short and reproducible — a normal run also includes the pre-flight tool scan and repository cache check before reaching this point):

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

[1;33mWould you like to (i)nstall or (u)ninstall the EAX audio fix? (i/u): [0m
> 
[0;94mNote: EAX_RESTORE_SKIP_CACHE_CHECK is set — skipping the REPOSITORY CACHE CHECK
and trusting whatever DSOAL/OpenAL Soft builds are already cached.[0m

[0;36m----------------------------------------------------------[0m
[0;32m[1m--- PHASE 1: CONFIGURATION ---[0m
[0;36m----------------------------------------------------------[0m

[0;36m----------------------------------------------------------[0m
[0;36m1/9. Game Location[0m
[0;36m----------------------------------------------------------[0m

[0;94mNote: Library scanning needs the known-EAX-games database,
which isn't available this run — skipping straight to manual entry.[0m

[1;37mCommon game locations:[0m

[1;37m Linux Desktop (Steam): ~/.local/share/Steam/steamapps/common/[Game][0m
[1;37m Steam Deck (SD Card):  /run/media/mmcblk0p1/steamapps/common/[Game][0m
[1;37m Heroic / GOG:          ~/Games/Heroic/[Game][0m

 1) Browse for the folder using a graphical file picker
 2) Enter the path manually

[1;33mHow would you like to locate the game? [1-2]: [0m
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
Choose to install or uninstall, provide the game directory, and select your preferred audio configuration.

### Steam Deck Quick Install (Desktop Mode)

As an alternative to the terminal steps above, [`eax-restore-linux.desktop`](eax-restore-linux.desktop) is a double-click launcher for Desktop Mode:

1. Switch to **Desktop Mode** and download [`eax-restore-linux.desktop`](https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.desktop) from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) (e.g. to your Desktop or Downloads folder).
2. In Dolphin, right-click it and enable **Allow Executing File as Program** (Properties → Permissions), since Plasma won't run it otherwise.
3. Double-click it and select **Execute**. It fetches the latest script into your home folder (`~/eax-restore-linux.sh`, overwriting any previous copy) and runs it in a terminal — nothing is installed until you follow the prompts, same as running the script manually. The downloaded copy is left behind afterward, so you can re-run it later (e.g. for uninstalls, or another game) without launching the `.desktop` file again.

Since the script itself refuses to run in Gaming Mode, this only works from Desktop Mode.

### Uninstallation
Run the script, select **(u)ninstall**, and provide the game directory. The script will remove the EAX files, restore original backups, remove the DLL override (from the registry or the launcher's settings), optionally remove the VC++ runtime it installed, and offer to put back any game settings it changed (leaving alone anything you've changed yourself since).

### Library Scanning & the Known Games Database

During install, the script can optionally scan your Steam and Heroic libraries for titles it recognises, so you can pick a game from a list instead of browsing to its folder manually. Matches are checked against [`known-eax-games.json`](known-eax-games.json), a community-maintained database in this repo (built from the per-game files in [`data/games/`](data/games/)) that's fetched fresh on every run (and cached locally so a later offline run still works). The same database also drives the install-time "Heads up" notes, the "this install would be a no-op" warnings, the delisted-storefront notice, the OpenAL-vs-DirectSound3D compatibility check ("Audio API Detection") for specific titles, and the **Game Settings** step: for games that ship with EAX (or other things) switched off in their own config files, it shows each setting's current and recommended value and applies the ones you accept — audio fixes together, optional non-audio fixes (like Quake 4's low-res textures) one by one.

This list is deliberately small and hand-verified — it will only ever cover a fraction of EAX-capable games. If your game isn't in it, the OpenAL-vs-DirectSound3D check falls back to scanning the game's own `.exe`/`.dll` files for `OpenAL32.dll`/`dsound.dll` references — a lower-confidence guess, clearly flagged as such. When even that is inconclusive (or you skip the scan), the script asks you to pick between DirectSound3D/DSOAL and OpenAL native rather than silently assuming DirectSound3D — DirectSound3D is the default, and this prompt is also the only way to select OpenAL-native mode for a game nothing could identify.

**Retail/CD copies and other non-Steam, non-Heroic installs** (e.g. an original pre-Steam Half-Life disc, run in a Wine prefix you set up yourself) aren't covered by the scanner at all, since there's no launcher library to scan — but the script still supports them. Point it at the game's `.exe` folder and provide the Wine prefix path manually when prompted.

**Contributing to the known games database:** PRs adding or correcting games are welcome. Each game is its own file, `<id>.json`, where `<id>` is a kebab-case version of its name (`quake-4.json`, `thief-ii-the-metal-age.json`). Which folder it's in says how far it's got:

- `data/games/tested/` — checked against a real install: its store IDs match, its `exe` exists, and any config files and settings it changes are where it says. Shipped.
- `data/games/untested/` — not checked on a real install yet. Shipped all the same. New games go here.
- `data/drafts/` — incomplete or doubtful entries. Checked against the schema and formatted, but **not** shipped.

To promote a game, move its file (`git mv`) and re-run `tools/format-known-games.sh`, which also updates its `"$schema"` line for the new folder. The formal definition of every field is [`data/schema.json`](data/schema.json); pointing your editor at it (each file's `"$schema"` line does this in VS Code and most JSON-aware editors) gives autocompletion and flags mistakes as you type. Don't edit `known-eax-games.json` by hand — it's generated from the per-game files. After editing, run:

```bash
tools/format-known-games.sh      # puts keys in the standard order and drops empty/default fields
tools/build-known-games.sh       # regenerates known-eax-games.json
```

CI checks every file against the schema, that it's formatted, and that `known-eax-games.json` is up to date. Please only add a store `id` you've independently verified against the storefront's own page or API — a wrong ID would point the script at someone else's prefix. **Leave a field out when it's empty or at its default** — there are no `null`s in these files.

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
    "audio_fixes": [
      {
        "title": "Enable EAX effects",
        "reason": "Quake 4 ships with its EAX sound options off, so there's no reverb and no muffling of sounds through walls.",
        "changes": { "Quake4Config.cfg": { "s_useOpenAL": "1", "s_useEAXReverb": "1", "s_useEAXOcclusion": "1" } }
      }
    ]
  },
  "sources": ["https://www.pcgamingwiki.com/wiki/Quake_4"]
}
```

- `name` — display name.
- `exe` — the main game executable's **file name only**, e.g. `"DeusEx.exe"`, as it appears in a real install. The scanner picks the folder holding it, which handles layouts its name matching gets wrong (e.g. Splinter Cell: Double Agent's separate single-player and multiplayer builds), and a hand-typed folder that doesn't contain it gets a warning. Only add it after checking a real install.
- `stores` — an object with a `"steam"` and/or `"gog"` key; **omit a store key entirely when the game isn't sold there** (a GOG-only game has no `"steam"` key, so "GOG only" needs no prose). Each store block holds:
  - `id` — the numeric Steam AppID / GOG product ID, used for library-scan matching.
  - `delisted` — `true` when the game has been pulled from sale there (existing owners keep access). Availability only, not pricing.
  - `id_source` — omit it when you checked the ID against the store's own page/API (the default). `"local_install_verified"` means it was also confirmed against a real local install; `"steamdb_historical"` means the store page is gone and the ID is SteamDB's historical record, not checked locally — only that one shows a line in the game-details display.
  - `api` — `"directsound3d"` / `"openal"` to override `eax.api` for **this store's build only**. Set it only where a storefront's current build genuinely differs (e.g. Thief Gold / Thief II: `eax.api` is `"directsound3d"`, but GOG's build comes with NewDark pre-installed, which runs audio and EAX reverb through OpenAL, so its `gog` block has `"api": "openal"`).
  - `beta_branch` — Steam only. The exact `BetaKey` name (right-click the game -> Properties -> Betas) of a beta branch that restores EAX on this store's build — set only when `eax.fix` names one. Lets the install-time check detect whether the user's local appmanifest already has this branch opted into/mounted, instead of always showing the `removed_by_patch` warning.
  - `store_details` — prose about what's specific to **this store's listing**: engine/audio-path differences ("It comes with NewDark pre-installed…"), delisting circumstances, bundling/packaging quirks ("Heroic installs this bundle as two separate library entries"), and build-identity/disambiguation facts ("Both stores sell this as the 'Planetary Pack'", "This is the pre-2017 classic build, not the Enhanced Edition"). When a fact applies identically to more than one store, duplicate the prose into each relevant store block — and write each store's copy to stand on its own, never referencing "the other store's block" or "the Steam version" from within the GOG block (a user only ever sees one store's block). Don't name the script's own parts (DSOAL / OpenAL Soft) or talk about "paths" / "intercepting" — state the fact and let the script say what it will use.
  - `patches` — prose for **this store's build**, shown under "Suggested community patches:": community patch/mod recommendations (TFix / T2Fix, SilentPatch, Sneaky Upgrade, SCP…), including ones that — for a delisted game — also happen to be the practical way to get a legitimate full copy (e.g. OldUnreal's patches; frame a community OpenAL reimplementation as a strong alternative worth using instead of this script's approach, not as an inferior fallback). Not for "go buy it from a different retailer" content — that stays in `notes`.
- `eax` — how the game does 3D audio and whether EAX works on the current build:
  - `api` (required) — `"directsound3d"` or `"openal"`. The game-level audio API, used for any store without its own `api` override and for non-store installs; it also decides which engine the script installs.
  - `versions` — supported EAX version strings; only set from a verifiable source (the game's manual/readme, an in-game audio settings menu, or a maintained compatibility database) — cite it in `sources` or the PR description. Omit for a `"not_implemented"` game.
  - `status` — omit when EAX works (the default, `"supported"`). `"removed_by_patch"`: a software update stripped EAX/A3D from the current build (an alternate build/branch may restore it). `"not_implemented"`: a remaster/rewrite that never had EAX — no build-level fix exists.
  - `problem` — prose explaining *why* the current build is in that state, shown in the game-details `Status:` block. Since every entry is a current digital-store listing, don't add "make sure you're patched to at least version X" trivia.
  - `fix` — prose saying *how* to get a build where EAX works (a Steam beta branch, a retail/CD copy…). Game-level, not per store. Settings in the game's own config files belong in `game_config`, not here.
  - `fix_in_place` — `true` only when `fix` works on the *same install* the script is already pointed at (e.g. a Steam beta branch): the install-time check then warns and still offers "Continue installing anyway?". Omit it when the only fix is a separate install (e.g. a pre-patch retail copy) — the check then blocks, the same as `"not_implemented"`.
- `install` — what the install itself does differently for this game:
  - `tweaks` — any of `"eax_unified"`, `"expand_audio_limits"`, `"com_registry_routing"`. Each turns the matching Advanced Compatibility Tweak into a default-yes prompt:
    - `"eax_unified"` — for titles that reach EAX through Creative's `eax.dll` "EAX Unified" shim rather than native DirectSound3D. Drives a guarded prompt for the EAX Unified Dummy Files tweak (it checks whether the game ships its own `eax.dll` first).
    - `"expand_audio_limits"` — for a title independently verified to need it, e.g. F.E.A.R.'s audio dropping out during large firefights.
    - `"com_registry_routing"` — for a title independently verified to need it, e.g. Grand Theft Auto: San Andreas.
  - `alsoft_ini` — OpenAL Soft settings offered for this game in the Speaker Configuration step, as section → key → value strings. Only `reverb.boost` and `general.sources` / `frequency` / `default-reverb` / `resampler` are allowed. E.g. `{ "reverb": { "boost": "6" } }` for a game whose reverb is quiet — test that the value doesn't make the reverb pop.
- `game_config` — changes to the game's **own** config files, offered in the Game Settings step. The player sees each file, setting and its current → new value, confirms, and uninstall puts the original values back (leaving anything the player has changed since alone).
  - `files` — each config file, keyed by its file name:
    - `format` — `"ini"` (`[Section]` + `key=value`), `"flat_ini"` (`key=value` lines with no `[Section]` headers, e.g. Thief: Deadly Shadows' `options.ini`), `"idtech_cfg"` (`seta key "value"`, id Tech games) or `"dark_cfg"` (NewDark's `key value` lines, where a bare `key` turns a flag on and `;key` turns it off).
    - `locations` — where to look, in order, as `"base:path"`; the first that exists is used. Bases: `game` (the exe's folder), `install` (the install root), `prefix_documents`, `prefix_appdata`, `prefix_localappdata` (inside the Wine prefix's user folder). No `..`, leading `/` or backslashes.
    - `if_missing` — what to do when the file doesn't exist. Omit it for files the game writes on first launch (the player is told to launch once and run the script again); `"skip"` for files only some builds have (NewDark's `cam_ext.cfg` isn't in the stock Steam Thief games) — their fixes are skipped silently; `"create"` to create it (e.g. Quake 4's `autoexec.cfg`).
    - `crash_marker` — optional: the name of a file the game keeps next to this config file while it's running and deletes when quit from its own menu, which makes it reset the config file on its next start if left behind (BioShock's `Running.ini`). The script removes it, when the game isn't running, before changing the file, and never puts it back on uninstall.
  - `audio_fixes` — fixes that make EAX work or sound right, confirmed together with one default-yes prompt.
  - `extra_fixes` — optional fixes that aren't needed for EAX (e.g. low-res textures), offered separately so the player picks which to apply.
  - Each fix has:
    - `title` and `reason` — see CLAUDE.md's "Game fix `title` and `reason`" rules. In short: `title` is **Enable** / **Fix** / **Remove** / **Raise** plus the result the player gets (`"Enable EAX reverb"`), reused across games for the same result; `reason` is one or two short sentences, starting with the game's name, on what the game does out of the box — without repeating the settings the rows below it show.
    - `changes` — file → section → key → value for `ini` files, file → key → value for `flat_ini` and the cfg formats. Values are strings; `true`/`false` switches a `dark_cfg` flag; `null` removes the key. Every file must be listed in `files`.
    - `only_if` — optional conditions: `{ "stores": ["gog"] }` and/or `{ "speakers": "stereo" | "surround" | "matrix" }` (the Speaker Configuration answer). Prefer `if_missing: "skip"` over a store condition when a fix depends on a file only some builds have.
    - `follow_up` — optional: something the player does after installing, shown in the final summary (`"Open Options -> Video and click Autodetect."`).
- `sources` — URLs backing the entry's claims (the short "(per PCGamingWiki)" citations in the prose point here).
- `notes` — prose caveats not covered by the fields above: cross-references to sibling entries, limitation/expectation-setting caveats ("reverb here is subtle, that's expected not a bug"), controller/multiplayer/mod quirks.

### Environment Variables

For repeat runs or scripting, these can be set to skip prompts:

| Variable | Effect |
| --- | --- |
| `EAX_RESTORE_SKIP_PREFLIGHT=1` | Skips the pre-flight tool scan, trusting that `curl`, `unzip`, `file`, `protontricks`, `winetricks`, and `wine` are already available. |
| `EAX_RESTORE_DSOAL_PIN=1` | Installs a frozen, known-good `kcat/dsoal` build (the revision pinned in the script, from kcat's `archive` release) instead of the rolling `latest-master` — a break-glass lever for when a daily build regresses a game. Pairs the pinned DSOAL with the current OpenAL Soft, selects the DSOAL engine, and jumps straight to install. |
| `EAX_RESTORE_VCRUN_ONLY=1` | Skips the full install/uninstall flow and just (re)installs the MS VC++ 2022 Redistributable into a game's prefix. |
| `EAX_RESTORE_SKIP_CACHE_CHECK=1` | Skips the repository cache check (the GitHub update check/download for DSOAL and OpenAL Soft), trusting whatever's already in the local cache. |
| `EAX_RESTORE_KNOWN_GAMES_FILE=/path/to/known-eax-games.json` | Uses a local file (e.g. one you built with `tools/build-known-games.sh`) instead of fetching `known-eax-games.json` — mainly for testing edits to the database itself before they're pushed. |
| `EAX_RESTORE_NO_LOG=1` | Turns off the per-run log file (see [Logs & Bug Reports](#logs--bug-reports)). |

### Logs & Bug Reports

Every run is saved to a log file in `~/.local/state/eax-restore-linux/logs/`, and the script prints its path when the run finishes. Each run gets its own timestamped file (the newest 10 are kept), and `latest.log` always points at the most recent one. Dev builds log separately, to `~/.local/state/eax-restore-linux/logs/dev/`.

The log contains everything shown on screen and your answers to the script's prompts, plus details useful for troubleshooting: your distro, kernel, and Wine/winetricks/protontricks versions, the output of the Wine, winetricks, and protontricks commands the script runs, and a summary of the detected game, prefix, runner (Proton/Wine version), architecture, and chosen engine.

If something goes wrong, please [open a bug report](https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md) and attach `~/.local/state/eax-restore-linux/logs/latest.log`. The log includes local file paths, which contain your username — feel free to redact them.

## Credits & Upstream Sources

This script automates the deployment of the following projects:

* **kcat (Christopher Robinson)** - [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft). The script deploys kcat's own `latest-master` DSOAL build and stable OpenAL Soft release, with `EAX_RESTORE_DSOAL_PIN` falling back to a pinned revision from the [`archive`](https://github.com/kcat/dsoal/releases/tag/archive) release when needed.
* **ThreeDeeJay** - upstreamed the Win32/Win64 packaging pipeline that kcat's daily DSOAL builds are now produced by.

## License
This script is provided under the [MIT License](LICENSE).
