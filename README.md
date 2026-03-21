# DSOAL & OpenAL Universal Installer for Linux

A streamlined Bash script designed to automate the restoration of EAX 3D audio in older Windows games running on Linux via Steam (Proton) or Heroic Games Launcher (Wine/Proton).

Older Windows games often rely on DirectSound3D and EAX for surround sound and environmental audio effects. Modern systems and Wine/Proton do not support this natively. This script automates the installation of DSOAL (DirectSound Over OpenAL) to translate those old audio calls into modern OpenAL, restoring full 3D audio and HRTF support.

## Features

* **Universal Compatibility:** Works with both Steam prefixes (via Protontricks) and Heroic/GOG custom prefixes (via Winetricks).
* **Automated Downloads:** Fetches the latest continuous master build directly from the official DSOAL GitHub repository.
* **Dependency Handling:** Automatically installs the required core `openal` Windows dependencies into the game's prefix.
* **Architecture Smart:** Defaults to 32-bit DLLs, which are required by 99% of legacy EAX titles.
* **HRTF Support:** Includes an option to automatically generate an `alsoft.ini` configuration file to enable Head-Related Transfer Function for realistic 3D spatial audio on headphones.

## Prerequisites

Before running the script, ensure you have the following installed on your system:

* `curl` (for downloading the archive)
* `unzip` (for extracting the files)
* `protontricks` (Required if installing for Steam games)
* `winetricks` (Required if installing for Heroic/GOG games)

## Installation and Usage

1. Download the script or clone the repository to your local machine:
   ```bash
   git clone [https://github.com/YOUR_USERNAME/YOUR_REPOSITORY_NAME.git](https://github.com/YOUR_USERNAME/YOUR_REPOSITORY_NAME.git)
   cd YOUR_REPOSITORY_NAME
