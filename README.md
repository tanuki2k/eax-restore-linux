<div align="center">

# EAX Restore for Linux

**Bring back EAX and DirectSound3D audio in classic Windows games on Steam/Proton and Heroic/Wine.**

[![Latest release](https://img.shields.io/github/v/release/tanuki2k/eax-restore-linux?label=release)](https://github.com/tanuki2k/eax-restore-linux/releases/latest)
[![License: MIT](https://img.shields.io/github/license/tanuki2k/eax-restore-linux)](LICENSE)
[![Dev build](https://img.shields.io/badge/dev%20build-pre--release-orange)](https://github.com/tanuki2k/eax-restore-linux/releases/tag/dev)

[What it does](#what-it-does) · [Install](#install) · [Steam Deck](#steam-deck) · [Uninstall](#uninstall) · [Docs](#documentation)

</div>

## What it does

Games from the late 90s and early 2000s used DirectSound3D and Creative's EAX for spatial audio and environmental reverb. Walk into a cave and the echoes change. Put a thick wall between you and a guard and his footsteps get muffled. *Thief: The Dark Project*, *F.E.A.R.*, *Max Payne 2* and *Star Wars: Knights of the Old Republic* all did this, and on a modern system you mostly don't hear it.

Windows no longer supports that old hardware pipeline, and neither do Proton or Wine, so the games' advanced audio options are usually grayed out. This script puts **[DSOAL](https://github.com/kcat/dsoal)** and **[OpenAL Soft](https://github.com/kcat/openal-soft)** into your game folder and your Wine prefix. Between them they turn the game's old EAX calls into ordinary OpenAL, so the game finds the sound card it expects, unlocks its audio options, and your CPU does the 3D processing.

It also does the fiddly parts around that: it works out whether the game is 32 or 64-bit, finds the right Wine prefix, backs up any file it replaces, sets the DLL override so the game actually loads the new files, and switches on the game's own EAX options when it knows where they are. Every install writes a list of what it touched, so uninstalling puts everything back.

> [!WARNING]
> I've tested this on a range of games and launchers, but use it at your own risk. If you hit a bug, please report it on the issue tracker.

### Why I made it

Setting up DSOAL by hand works, but it takes a lot of steps: hunting down the right files, copying them to the right places, editing the registry. kevinlekiller's **[reshade-steam-proton](https://github.com/kevinlekiller/reshade-steam-proton)** showed me this kind of thing could be automated. I'm not a coder, so I built the first version with Google Gemini, and it has kept growing with Claude's help.

## Install

You need a terminal and a few common tools. The script checks for them when it starts and offers to install what's missing on apt, pacman and dnf systems. On other distros it asks you to install them yourself, and on SteamOS it points you to Discover.

| You need | For |
| --- | --- |
| `curl`, `unzip`, `file`, `grep`, `awk`, `jq` | everything |
| `protontricks` | Steam games |
| `winetricks` and `wine` | Heroic and GOG games |
| `fzf` 0.35 or newer | the profile browser (optional; 0.58 or newer draws it in boxes). The script offers to install it the first time you open the browser. |

Then download the script, make it executable and run it:

```bash
curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh
chmod +x eax-restore-linux.sh
./eax-restore-linux.sh
```

The main menu lets you scan your Steam and Heroic libraries for the game, browse to its folder, or type the path. It also has uninstall and a Tools menu.

An install has four phases. The first three only ask questions: which game, which audio files and speakers, and which of the game's own settings to change. Nothing on your system changes until you answer the final "Proceed?". [How it works](docs/how-it-works.md) goes through each step.

To see what the script does or which version you have, run `./eax-restore-linux.sh --help` or `--version`. Both print and exit without starting anything.

<details>
<summary>Checking your download</summary>

Every release also has a `.sha256` file for the script. To check that your copy arrived intact:

```bash
curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh.sha256
sha256sum -c eax-restore-linux.sh.sha256
```

</details>

> [!NOTE]
> Every change on the `dev` branch is published as a pre-release you can try at `https://github.com/tanuki2k/eax-restore-linux/releases/download/dev/eax-restore-linux.sh`. Its startup banner shows a `-dev` version with the build date and commit. It's unstable and unsupported, and the `.desktop` launcher below only ever fetches the stable release.

## Steam Deck

In Desktop Mode you can skip the terminal. [`eax-restore-linux.desktop`](eax-restore-linux.desktop) is a launcher you double-click.

1. Switch to Desktop Mode and download [`eax-restore-linux.desktop`](https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.desktop) from the [latest release](https://github.com/tanuki2k/eax-restore-linux/releases/latest), to your Desktop or Downloads folder.
2. In Dolphin, right-click it, open Properties → Permissions and turn on **Allow Executing File as Program**. Plasma won't run it otherwise.
3. Double-click it and choose **Execute**.

The launcher downloads the newest script to `~/eax-restore-linux.sh` (replacing any older copy) and runs it in a terminal. It asks the same questions as running the script yourself, and installs nothing until you say so. The copy stays in your home folder, so you can run it again for an uninstall or another game without the launcher.

> [!NOTE]
> The script refuses to run in Gaming Mode, so use Desktop Mode.

## Uninstall

Run the script, choose **[U]ninstall the EAX fix** and give it the game's folder. It removes the files it installed and puts your original files back from the backups. It also takes out the DLL override, wherever it was set (the registry or the launcher's settings). It can remove the VC++ runtime it installed, and put back any game settings it changed, leaving alone anything you've changed yourself since.

Like the install, it asks everything first (which files to remove, whether to close a running launcher, whether to remove the VC++ runtime, which settings to restore) and changes nothing until you confirm one final "Proceed?".

## Documentation

| Page | What's in it |
| --- | --- |
| [How it works](docs/how-it-works.md) | An install step by step, plus the Tools menu and profile browser |
| [Library scanning and the game database](docs/game-database.md) | How the script recognises your games and what it knows about them |
| [Environment variables](docs/environment-variables.md) | Options for repeat runs and scripting |
| [Troubleshooting](docs/troubleshooting.md) | Run logs, DSOAL logging and bug reports |
| [Contributing a game](docs/contributing-games.md) | Adding or fixing a game profile |
| [Game file reference](docs/game-file-reference.md) | Every field in a game's file |

The same pages are on the project's wiki, which is generated from `docs/`.

## Credits

The script deploys other people's work:

* **kcat (Christopher Robinson)** writes [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft). The script uses kcat's own builds: a tested DSOAL revision pinned from the [`archive`](https://github.com/kcat/dsoal/releases/tag/archive) release, or the newest `latest-master` or archive build, together with OpenAL Soft's newest release or its rolling pre-release.
* **ThreeDeeJay** contributed the Win32/Win64 packaging pipeline that kcat's daily DSOAL builds now come from.

## License

[MIT](LICENSE).
