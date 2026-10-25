# Features

## Install and detection

* **Dual-copy deployment:** DSOAL and OpenAL files go into both your game folder *and* the Wine/Proton prefix's system folders, with conflict backups in both.
* **Engine choice:** kcat's DSOAL + OpenAL Soft (translates DirectSound3D/EAX to OpenAL) for the vast majority of games, or a direct OpenAL Soft swap for the handful that call OpenAL natively. If the Audio API Detection step has already pinned down which one the game uses, the engine menu is skipped, and you're only asked when the API couldn't be confirmed.
* **Build choice:** pick **Stable** (a tested DSOAL revision + OpenAL Soft's newest release, the default), **Latest** (DSOAL's newest build + OpenAL Soft's pre-release), or each separately. Only the builds you pick are downloaded, and every download is checked against its SHA256.
* **HRTF and speaker setup:** generates an `alsoft.ini` for your output (stereo, headphones, surround or matrix). For headphones it turns on OpenAL Soft's HRTF binaural rendering.
* **Architecture detection:** checks whether the game executable is 32-bit or 64-bit and fetches the matching dependencies, so the game doesn't crash on launch.
* **Prefix detection:** opt-in detection of Steam AppIDs and Heroic prefix paths, to find where your game is installed.
* **Prefix validation:** verifies Steam AppIDs via Protontricks and checks that Heroic prefixes are fully initialized before touching any files.
* **Library scanning:** opt-in scan of your Steam and Heroic libraries against the community-maintained game database. You pick a match from the list instead of hunting for the install folder.

## Tweaks and overrides

* **COM registry injection:** optional routing of DirectSound CLSIDs in the Wine registry. This fixes grayed-out EAX menus in games like *Grand Theft Auto: San Andreas* and *Halo: Combat Evolved*.
* **Engine tweaks:** optional EAX Unified dummy files (`eax.dll`/`eaxunified.dll`) and expanded audio limits to fix stuttering in busy, high-channel games like *F.E.A.R.*
* **Automatic DLL overrides:** sets the `dsound`/`openal32` override for you in the game's Steam launch options or Heroic environment variables (the default, because it's visible and easy to undo there), or in the Wine prefix registry. Or you can set it yourself: the script then prints the instructions and changes nothing. Existing launch options are kept, and uninstall puts them back.
* **VC++ runtime handling:** detects and installs the Microsoft VC++ 2022 Redistributable that older Proton/Wine builds need to load kcat's DSOAL and OpenAL Soft. If winetricks/protontricks fails, it falls back to a direct Microsoft download. It verifies the DLLs on disk instead of trusting exit codes.

## Safety and cleanup

* **Cache and offline mode:** downloads from GitHub are cached locally, so installing the fix to several games downloads the files once. Pinned or live checksum verification guards against corrupt or tampered downloads.
* **File backups and manifest:** any file already where the fix goes is backed up with a timestamp before it's replaced, so you keep the original game data. Every install writes a manifest of what it deployed, so uninstall only removes what this script put there and restores your backups.
* **Uninstall list:** Uninstall and Tools list every game this script is installed in, most recently used first, found from the install manifests in your Steam and Heroic game folders.
* **Safety guards:** refuses to run as root or from Steam's Gaming Mode, and won't automatically modify SteamOS's immutable filesystem.
* **Update check:** at start-up, offers to download a newer version of the script and restart with it (checked against the release's `.sha256`). Set `EAX_RESTORE_SKIP_UPDATE_CHECK=1` to skip it.

## Tools menu

* **Change an installed game:** Tools → **[O]ptional settings** turns a game's optional settings on or off after the install. **[S]peaker configuration** switches its speaker setup (stereo, headphones/HRTF, surround, matrix) along with any of the game's own settings that go with it, like BioShock's speaker mode. Both only touch games this script installed to, and uninstall still puts back every original value.
* **DSOAL logging:** Tools → **[D]SOAL logging** turns DSOAL's own log on or off for one game, without editing launch options by hand. The log records which EAX versions the game asks for (Full level logs every call), which helps with bug reports.
* **Browse game profiles:** Tools → **[B]rowse game profiles** lists every game in the database with a fuzzy search. The selected game's profile appears beside the list. It's the screen the install shows when you pick the game, covers every store the game is on, and shows anything that differs between Steam and GOG for each.

### Profile browser keys

| Key | What it does |
| --- | --- |
| **Ctrl-A** | Narrow by audio: DirectSound3D, OpenAL or an EAX version |
| **Ctrl-S** | Narrow by store: Steam, GOG, or the games delisted from either or one of them |
| **Ctrl-T** | Switch between the games checked on a real install (the default), all of them, and the ones nobody has checked yet |
| **Ctrl-R** | Switch between best match first and A–Z |
| **Ctrl-L** | Put the profile beside or under the list (it moves under by itself when the window gets narrow) |
| **Tab** | Show the game's settings in full: why each one is offered, the file and where it lives, and the exact values it sets |
| **Shift-↑/↓**, **PgUp/PgDn** | Scroll the profile |
| **Ctrl-F** | Open the profile full screen (q comes back) |
| **F1** | List every key, most useful first |
