# DSOAL & OpenAL Universal Installer for Linux

A streamlined Bash script designed to automate the restoration of **EAX 3D audio** in older Windows games running on Linux via **Steam (Proton)** or **GOG (Heroic Games Launcher)**.

Older Windows games often rely on DirectSound3D and EAX for surround sound and environmental audio effects. Modern systems and Wine/Proton do not support this natively. This script automates the installation of **DSOAL** (DirectSound Over OpenAL) to translate those old audio calls into modern OpenAL, restoring full 3D audio and HRTF support.

## Features

* **Centralized Caching:** Downloads DSOAL to `~/.local/share/dsoal` just once to save bandwidth and disk space.
* **Smart Updater:** Checks the GitHub API to ensure your cached version is always up-to-date.
* **Hybrid Installation:** Symlinks core DLLs for global updates, but copies the `alsoft.ini` file so every game retains its own independent audio settings.
* **Auto-Dependencies:** Detects your Linux distribution and automatically installs required tools (`curl`, `unzip`, `file`, `protontricks`, `winetricks`).
* **Universal Compatibility:** Works seamlessly with both Steam and GOG (Heroic) prefixes.
* **Uninstall Option:** Safely checks for and removes the audio fix from a specific game directory if needed.
* **Smart Architecture Detection:** Automatically scans your game folder to determine if it requires 32-bit or 64-bit files.

## Installation and Usage

You can download and run the installer script directly using the following commands in your terminal:

1.  **Download the script:**
    ```bash
curl -LO https://github.com/tanuki2k/eax-steam-proton/raw/refs/heads/main/eax-restore-linux.sh
    ```

2.  **Make the script executable:**
    ```bash
    chmod +x install_dsoal.sh
    ```

3.  **Run the script:**
    ```bash
    ./install_dsoal.sh
    ```

### Alternative: Clone the Repository
If you prefer to have the full project locally:
```bash
git clone [https://github.com/tanuki2k/eax-steam-proton.git](https://github.com/tanuki2k/eax-steam-proton.git)
cd eax-steam-proton
chmod +x install_dsoal.sh
./install_dsoal.sh
