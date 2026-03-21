# DSOAL & OpenAL Universal Installer for Linux

A streamlined Bash script designed to automate the restoration of EAX 3D audio in older Windows games running on Linux via Steam (Proton) or Heroic Games Launcher (Wine/Proton).

Older Windows games often rely on DirectSound3D and EAX for surround sound and environmental audio effects. Modern systems and Wine/Proton do not support this natively. This script automates the installation of DSOAL (DirectSound Over OpenAL) to translate those old audio calls into modern OpenAL, restoring full 3D audio and HRTF support.

## Features

* **Centralized Caching:** Downloads DSOAL to `~/.local/share/dsoal` just once to save bandwidth and disk space.
* **Smart Updater:** Checks the GitHub API to ensure your cached version is always up-to-date.
* **Hybrid Installation:** Symlinks the core DLLs for instant global updates across all your games, but copies the `alsoft.ini` file so every game retains its own independent audio settings.
* **Auto-Dependencies:** Detects your Linux distribution and automatically installs required tools (`curl`, `unzip`, `file`, `protontricks`, `winetricks`).
* **Universal Compatibility:** Works seamlessly with both Steam and GOG (Heroic) prefixes.
* **Uninstall Option:** Safely checks for and removes the audio fix from a specific game directory if needed.

## Prerequisites

If you choose not to let the script install them automatically, ensure you have the following installed on your system:

* `curl`
* `unzip`
* `file`
* `protontricks` (Required if installing for Steam games)
* `winetricks` (Required if installing for GOG (Heroic) games)

## Installation and Usage

1. Clone the repository to your local machine:
   ```bash
   git clone [https://github.com/tanuki2k/eax-steam-proton.git](https://github.com/tanuki2k/eax-steam-proton.git)
   cd eax-steam-proton
