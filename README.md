# EAX Restore for Linux (Steam/Proton & Heroic/Wine)

A Bash script that installs DSOAL and OpenAL Soft for classic Windows games running on Linux.

**How it works:** In the late 90s and early 2000s, PC games used DirectSound3D and Creative's EAX for hardware-accelerated spatial audio and environmental reverb. Walking into a cave changed the echoes, and a thick wall between you and a guard muffled his footsteps. *Thief: The Dark Project*, *F.E.A.R.*, *Max Payne 2* and *Star Wars: Knights of the Old Republic* all used EAX, and modern software audio often ignores it.

Modern operating systems and Proton/Wine don't support that old hardware pipeline, so the games' advanced audio options are usually grayed out. The script deploys **[DSOAL](https://github.com/kcat/dsoal)** (DirectSound3D Object Audio Library) and **[OpenAL Soft](https://github.com/kcat/openal-soft)** into your game folder. Together they translate legacy EAX calls into standard OpenAL. The game sees the hardware it expects, unlocks its audio options, and the 3D sound is processed on your CPU.

**Disclaimer:** I've tested this script on a range of games and launchers, but use it at your own risk. If you find a bug, please report it on the issue tracker.

**A Personal Note:** Installing DSOAL by hand is a known process, but it takes many steps, including hunting for files and editing the registry. kevinlekiller's project **[reshade-steam-proton](https://github.com/kevinlekiller/reshade-steam-proton)** inspired me to automate it. I'm not a coder, so I built the first version with Google Gemini, and it has kept growing with the help of Claude.


## Features

* **Dual-copy deployment:** DSOAL and OpenAL Soft go into both the game folder and the Wine/Proton prefix, with a timestamped backup of anything they replace.
* **Engine choice:** kcat's DSOAL + OpenAL Soft for the vast majority of games, or a direct OpenAL Soft swap for the few that call OpenAL natively. Stable or Latest builds, each download checked against its SHA256.
* **Speaker setup:** generates an `alsoft.ini` for stereo, headphones (HRTF), surround or matrix output.
* **Detection:** 32/64-bit architecture, Steam AppIDs, Heroic prefixes, and a scan of your Steam and Heroic libraries against the community game database.
* **Game settings:** switches on a game's own EAX and sound options, from the same database.
* **Automatic DLL overrides:** set in Steam launch options, Heroic environment variables or the Wine registry.
* **Clean uninstall:** every install writes a manifest, so uninstall removes only what the script put there and restores your backups.
* **Tools:** change an installed game's settings, browse game profiles, turn DSOAL logging on or off, install the VC++ runtime.

The full list, with the profile browser's keys, is in [docs/features.md](docs/features.md).

## Prerequisites

The script checks for these and offers to install any that are missing:
* `curl`, `unzip`, `file`, `grep`, `awk`, `jq`

**Launcher dependencies:**
* **Steam games:** `protontricks`.
* **Heroic/GOG games:** `winetricks` and `wine`.

`jq` powers checksum verification for kcat's official builds, as well as the game database used for install-time notes and library scanning (see [docs/game-database.md](docs/game-database.md)).

**Optional:** `fzf` 0.35 or newer for Tools → **[B]rowse game profiles** (0.58 or newer draws each part in its own box). The script offers to install it the first time you open the browser.

## Usage

> Prefer a manual download? Grab the script and the Steam Deck `.desktop` launcher from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) instead of the steps below.

> **Testing the development build?** Every change on the `dev` branch is auto-published as a pre-release. Download it from `https://github.com/tanuki2k/eax-restore-linux/releases/download/dev/eax-restore-linux.sh`. Its startup banner shows a `-dev` version plus the build date and commit, so you can tell it from a stable build. It's unstable and unsupported, and the `.desktop` launcher only ever fetches the stable release.

> **Want to check what it does or which version you have?** Run `./eax-restore-linux.sh --help` or `--version`. Both print at once and don't start the install or uninstall flow.

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

> **Verifying the download (optional):** every release also publishes a `.sha256` checksum file for the script. To confirm your download wasn't corrupted or tampered with:
> ```bash
> curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh.sha256
> sha256sum -c eax-restore-linux.sh.sha256
> ```

**3. Run the installer:**

```bash
./eax-restore-linux.sh
```

**4. Follow the prompts:**
Pick from the main menu: scan your Steam/Heroic library, browse for the game folder, or type its path to install; or uninstall the fix, or open Tools. An install has four phases: **Game** (find the game and work out how it plays sound), **Sound fix** (pick the audio files and your speakers), **Game settings** (offer changes to the game's own settings) and **Install**. The first three only ask questions. Nothing on your system changes until you confirm the final "Proceed?".

### Steam Deck Quick Install (Desktop Mode)

As an alternative to the terminal steps above, [`eax-restore-linux.desktop`](eax-restore-linux.desktop) is a double-click launcher for Desktop Mode:

1. Switch to **Desktop Mode** and download [`eax-restore-linux.desktop`](https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.desktop) from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest) (e.g. to your Desktop or Downloads folder).
2. In Dolphin, right-click it and enable **Allow Executing File as Program** (Properties → Permissions), since Plasma won't run it otherwise.
3. Double-click it and select **Execute**. It fetches the latest script into your home folder (`~/eax-restore-linux.sh`, overwriting any previous copy) and runs it in a terminal. As with running the script yourself, nothing is installed until you follow the prompts. The downloaded copy stays in your home folder, so you can run it again later (for an uninstall or another game) without the `.desktop` file.

Since the script itself refuses to run in Gaming Mode, this only works from Desktop Mode.

### Uninstallation
Run the script, choose **[U]ninstall the EAX fix**, and provide the game directory. The script removes the EAX files, restores the original backups, removes the DLL override (from the registry or the launcher's settings), optionally removes the VC++ runtime it installed, and offers to put back any game settings it changed, leaving alone anything you've changed yourself since. Like the install, it asks all its questions first (which files to remove, whether to close a running launcher, whether to remove the VC++ runtime, which game settings to put back) and changes nothing until you confirm with one final "Proceed?".

## Documentation

* [Features](docs/features.md)
* [Library scanning & the game database](docs/game-database.md)
* [Contributing a game](docs/contributing-games.md): add or fix a game profile
* [Game file reference](docs/game-file-reference.md): every field of a game file
* [Environment variables](docs/environment-variables.md)
* [Troubleshooting](docs/troubleshooting.md): run logs, DSOAL logging and bug reports

The same pages are on the project's wiki, generated from `docs/`.

## Credits & Upstream Sources

This script automates the deployment of the following projects:

* **kcat (Christopher Robinson)** - [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft). The script deploys kcat's own builds: a pinned, tested DSOAL revision from the [`archive`](https://github.com/kcat/dsoal/releases/tag/archive) release or the newest `latest-master`/archive build, with OpenAL Soft's newest release or its rolling pre-release.
* **ThreeDeeJay** - upstreamed the Win32/Win64 packaging pipeline that kcat's daily DSOAL builds are now produced by.

## License
This script is provided under the [MIT License](LICENSE).
