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
* **Native Auto-Overrides:** Injects the `dsound` override natively into the Wine registry so you don't have to clutter up your Steam launch options.
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
Run the script, select **(u)ninstall**, and provide the game directory. The script will remove the EAX files, restore original backups, remove the registry overrides, and optionally remove the VC++ runtime it installed.

### Library Scanning & the Known Games Database

During install, the script can optionally scan your Steam and Heroic libraries for titles it recognises, so you can pick a game from a list instead of browsing to its folder manually. Matches are checked against [`known-eax-games.json`](known-eax-games.json), a community-maintained file in this repo that's fetched fresh on every run (and cached locally so a later offline run still works). The same file also drives the install-time "Heads up" notes, the "this install would be a no-op" warnings, the delisted-storefront notice, and the OpenAL-vs-DirectSound3D compatibility check ("Audio API Detection") for specific titles.

This list is deliberately small and hand-verified — it will only ever cover a fraction of EAX-capable games. If your game isn't in it, the OpenAL-vs-DirectSound3D check falls back to scanning the game's own `.exe`/`.dll` files for `OpenAL32.dll`/`dsound.dll` references — a lower-confidence guess, clearly flagged as such. When even that is inconclusive (or you skip the scan), the script asks you to pick between DirectSound3D/DSOAL and OpenAL native rather than silently assuming DirectSound3D — DirectSound3D is the default, and this prompt is also the only way to select OpenAL-native mode for a game nothing could identify.

**Retail/CD copies and other non-Steam, non-Heroic installs** (e.g. an original pre-Steam Half-Life disc, run in a Wine prefix you set up yourself) aren't covered by the scanner at all, since there's no launcher library to scan — but the script still supports them. Point it at the game's `.exe` folder and provide the Wine prefix path manually when prompted.

**Contributing to the known games database:** PRs adding or correcting entries in `known-eax-games.json` are welcome. Please only add a `steam_appid`/`gog_id` you've independently verified against the storefront's own page or API — a wrong ID would point the script at someone else's prefix. See the existing entries for the expected shape:

- `name` — display name.
- `steam_appid` / `gog_id` — nullable per-store IDs used for library-scan matching.
- `steam_listing` / `gog_listing` — `"available"` or `"delisted"` (pulled from sale, existing owners keep access), `null` when that entry has no ID for that store. Availability only, not discount pricing.
- `edition` — `"original"` or `"remaster"`, shown as a field in the scanner's game details display.
- `api` — `"directsound3d"` or `"openal"`. Only meaningful when `eax_status` is `"supported"`; drives the Audio API Detection step's remediation choice.
- `eax_status` — `"supported"`, `"removed_by_patch"` (a software update stripped EAX/A3D from the current default build; an alternate build/branch may restore it), or `"not_implemented"` (a remaster/rewrite that never had EAX at all — no build-level fix exists).
- `eax_status_notes` — free-text prose explaining *why* the current build is in the state `eax_status` describes, shown in the scanner's EAX STATUS block. Use it for the story behind the status: a remaster's rewritten audio engine, the patch that dropped EAX, a launcher setting that gates EAX on an otherwise-supported build, or a source port that later added native OpenAL. `null` when `eax_status` is `"supported"` and there's nothing worth explaining.
- `eax_restore_hint` — short text pointing at a known fix for a `"removed_by_patch"` entry (e.g. a Steam beta branch name), `null` if none exists. This is the "how to fix it" pointer; `eax_status_notes` is the "why it's like this" context.
- `notes` — free-text prose caveats unrelated to EAX status (multiplayer quirks, controller issues, mod conflicts, library-matching gotchas), shown at install time.
- `eax_versions` — array of supported EAX version strings; only set from a verifiable source (the game's manual/readme, an in-game audio settings menu, or a maintained compatibility database) — cite it in the PR description.

### Environment Variables

For repeat runs or scripting, these can be set to skip prompts:

| Variable | Effect |
| --- | --- |
| `EAX_RESTORE_SKIP_PREFLIGHT=1` | Skips the pre-flight tool scan, trusting that `curl`, `unzip`, `file`, `protontricks`, `winetricks`, and `wine` are already available. |
| `EAX_RESTORE_DSOAL_PIN=1` | Installs a frozen, known-good `kcat/dsoal` build (the revision pinned in the script, from kcat's `archive` release) instead of the rolling `latest-master` — a break-glass lever for when a daily build regresses a game. Pairs the pinned DSOAL with the current OpenAL Soft, selects the DSOAL engine, and jumps straight to install. |
| `EAX_RESTORE_VCRUN_ONLY=1` | Skips the full install/uninstall flow and just (re)installs the MS VC++ 2022 Redistributable into a game's prefix. |
| `EAX_RESTORE_SKIP_CACHE_CHECK=1` | Skips the repository cache check (the GitHub update check/download for DSOAL and OpenAL Soft), trusting whatever's already in the local cache. |
| `EAX_RESTORE_KNOWN_GAMES_FILE=/path/to/known-eax-games.json` | Uses a local file instead of fetching `known-eax-games.json` — mainly for testing edits to the database itself before they're pushed. |

## Credits & Upstream Sources

This script automates the deployment of the following projects:

* **kcat (Christopher Robinson)** - [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft). The script deploys kcat's own `latest-master` DSOAL build and stable OpenAL Soft release, with `EAX_RESTORE_DSOAL_PIN` falling back to a pinned revision from the [`archive`](https://github.com/kcat/dsoal/releases/tag/archive) release when needed.
* **ThreeDeeJay** - upstreamed the Win32/Win64 packaging pipeline that kcat's daily DSOAL builds are now produced by.

## License
This script is provided under the [MIT License](LICENSE).
