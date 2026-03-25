# EAX Restore for Linux (Steam/Proton & Heroic/Wine)

A streamlined Bash script designed to automate the installation of DSOAL and OpenAL Soft for classic Windows games running on Linux.

**How it works:** Back in the late 90s and early 2000s, PC audio was built differently. Games relied heavily on DirectSound3D and Creative's EAX technology to deliver hardware-accelerated spatial audio and dynamic environmental reverb. If you walked into a cave, the echoes changed; if a guard walked behind a thick wall, their footsteps became muffled. Games like *Thief: The Dark Project*, *F.E.A.R.*, *Max Payne 2*, and *Star Wars: Knights of the Old Republic* used EAX to create incredibly immersive soundscapes that modern software audio often flat-out ignores.

Because modern operating systems and Proton/Wine don't natively support this old hardware pipeline, those advanced audio options are usually grayed out. This script fixes that by deploying **[DSOAL](https://github.com/kcat/dsoal)** (DirectSound3D Object Audio Library) alongside **[OpenAL Soft](https://github.com/kcat/openal-soft)** directly into your game folder. Together, they act as a translation layer. They intercept legacy EAX calls and convert them into standard OpenAL, tricking the game into unlocking its hardware-accelerated audio options and processing the 3D sound flawlessly on your modern CPU.

**Disclaimer:** I've tested this script heavily across various games and launchers, but please use it at your own risk. If you find any bugs, please report them on the issue tracker and I'll do my best to fix them!

**A Personal Note:** While installing DSOAL manually is a known process, it's a tedious, multi-step task involving file hunting and registry edits, inspired by kevinlekiller's project **[reshade-steam-proton](https://github.com/kevinlekiller/reshade-steam-proton)** I wanted a way to streamline the procress. Since I'm not a coder, I built this tool with the assistance of Google Gemini.

## Features

* **Full Audio Stack Deployment:** Automatically links the correct DSOAL and OpenAL Soft `.dll` files directly to your game executable, bypassing the need for manual extraction.
* **Engine Choice:** Toggle between the "plug-and-play" ThreeDeeJay community fork (great for older titles) or the official kcat baseline builds.
* **Dynamic HRTF Integration:** Automatically generates optimized `alsoft.ini` configurations and deploys headphone profiles for incredible 3D binaural audio.
* **Smart Architecture Scanner:** Automatically detects whether the game executable is 32-bit or 64-bit and grabs the exact right dependencies so the game doesn't crash on launch.
* **Intelligent Prefix Routing:** Opt-in auto-detection for Steam AppIDs and Heroic Prefix paths, making it easy to find where your game is actually installed.
* **Deep Prefix Validation:** Verifies Steam AppIDs via Protontricks and ensures Heroic prefixes are fully initialized before touching any files.
* **Cache & Offline Mode:** Smart GitHub API downloading with local caching, so if you install the fix to multiple games, it only downloads the files once.
* **Safe File Management:** Interactive conflict resolution safely backs up pre-existing files with timestamps so you never lose original game data.
* **COM Registry Injection:** Optional routing of DirectSound CLSIDs directly in the Wine registry. This fixes the stubbornly grayed-out EAX menus in games like *Grand Theft Auto: San Andreas* or *Halo: Combat Evolved*.
* **Legacy 90s Support:** Optional safe injection of `dsound.vxd` dummy files to bypass driver checks from the Windows 95/98 era.
* **Advanced Engine Tweaks:** Optional EAX Unified dummy files and expanded audio limits to fix stuttering in chaotic, high-channel games like *F.E.A.R.*
* **Native Auto-Overrides:** Injects `WINEDLLOVERRIDES="dsound=n"` natively into the Wine registry so you don't have to clutter up your Steam launch options.

## Prerequisites

The script checks for these dependencies and offers to install them if they are missing:
* `curl`, `unzip`, `file`, `grep`, `awk`

**Launcher Dependencies:**
* **Steam Games:** Requires `protontricks`.
* **Heroic/GOG Games:** Requires `winetricks`.

## Usage

**1. Download the script:**
Open your terminal and run:

```bash
curl -LO https://github.com/tanuki2k/eax-steam-proton/raw/refs/heads/main/eax-restore-linux.sh
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

### Uninstallation
Run the script, select **(u)ninstall**, and provide the game directory. The script will remove the EAX files, restore original backups, and remove the registry overrides.

## Credits & Upstream Sources

This script automates the deployment of the following projects:

* **kcat (Christopher Robinson)** - [DSOAL](https://github.com/kcat/dsoal) and [OpenAL Soft](https://github.com/kcat/openal-soft).
* **ThreeDeeJay** - [DSOAL Community Fork](https://github.com/ThreeDeeJay/dsoal).

## License
This script is provided under the [MIT License](LICENSE).
