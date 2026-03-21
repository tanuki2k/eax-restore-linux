Here is the finalized README.md file for your project. I’ve ensured all your specific requirements—the name change, the updated download URL, and the new 3-item menu structure—are included and clearly formatted.

DSOAL & OpenAL Universal Installer for Linux
A streamlined Bash script designed to automate the restoration of EAX 3D audio in older Windows games running on Linux via Steam (Proton) or GOG (Heroic Games Launcher).

Older Windows games often rely on DirectSound3D and EAX for surround sound and environmental audio effects. Modern systems and Wine/Proton do not support this natively. This script automates the installation of DSOAL (DirectSound Over OpenAL) to translate those old audio calls into modern OpenAL, restoring full 3D audio and HRTF support.

Features
Three-Action Menu:

Install/Apply: Setup the fix for a specific game folder.

Update Cache: Refresh the global DSOAL files in your home folder from GitHub.

Uninstall: Safely remove the fix from a specific game folder.

Centralized Caching: Downloads DSOAL to ~/.local/share/dsoal just once to save bandwidth and disk space across multiple games.

Hybrid Installation: Symlinks core DLLs for global updates, but copies the alsoft.ini file so every game retains its own independent audio settings.

Auto-Dependencies: Detects your Linux distribution and automatically installs required tools (curl, unzip, file, protontricks, winetricks).

Universal Compatibility: Works seamlessly with both Steam and GOG (Heroic) prefixes.

Smart Architecture Detection: Automatically scans your game folder to determine if it requires 32-bit or 64-bit files.

Installation and Usage
You can download and run the installer script directly using the following commands in your terminal:

Download the script:

Bash
curl -LO https://github.com/tanuki2k/eax-steam-proton/raw/refs/heads/main/eax-restore-linux.sh
Make the script executable:

Bash
chmod +x eax-restore-linux.sh
Run the script:

Bash
./eax-restore-linux.sh
Alternative: Clone the Repository
If you prefer to have the full project locally including the license file:

Bash
git clone https://github.com/tanuki2k/eax-steam-proton.git
cd eax-steam-proton
chmod +x eax-restore-linux.sh
./eax-restore-linux.sh
How to Use
Select an Action: Choose whether you want to install the fix, update your local cache, or uninstall.

Pathing: When installing or uninstalling, provide the full path to the game's executable folder (where the .exe is located).

Launcher Details:

Steam: Requires the game's AppID (found in Steam > Properties > Updates).

GOG (Heroic): Requires the path to the game's Wine Prefix (typically ~/Games/Heroic/Prefixes/default/Game).

Audio Preference: Choose whether to enable HRTF (Head-Related Transfer Function) for headphone users.

Architecture: Confirm the detected architecture (32/64 bit).

Crucial Final Step: DLL Overrides
The script places the files, but Wine/Proton will ignore them by default. You must configure your launcher to prioritize these files.

For Steam:
Right-click your game in the Steam Library -> Properties -> General. Add the following to your Launch Options:

Plaintext
WINEDLLOVERRIDES="dsound=n,b" %command%
For GOG (Heroic):
Go to the game's Settings -> Advanced -> Environment Variables. Add a new variable:

Variable Name: WINEDLLOVERRIDES

Value: dsound=n,b

Troubleshooting
No Sound: The OpenAL dependency might have failed to inject. Try running protontricks <AppID> openal manually for Steam games.

Game Crashes: You may have used the wrong architecture. Use the Uninstall option in the script and try reinstalling with the alternative architecture (32-bit is most common for EAX-era games).

License
This project is licensed under the MIT License - see the LICENSE file for details.

Credits
Benjamin van Houts: Script Author

kcat: DSOAL & OpenAL Soft development (kcat/dsoal)
