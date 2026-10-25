# How it works

This page follows one install from start to finish, then covers the Tools menu and the safety nets. You don't need any of it to use the script, since it explains each step as it goes. It's here for when you want to know what's about to happen.

An install has four phases. The first three only ask questions and look around. Nothing on your system changes until the fourth, and only after you've answered a final "Proceed?".

## Phase 1: Game

The script starts by finding the game. It can scan your Steam and Heroic libraries and show the games it recognises, or you can browse to the game's folder or type the path. Scanning is the easier route, because the script already knows the game, its store IDs and its Wine prefix. A game that isn't on the list still works. [Library scanning and the game database](game-database.md) covers both cases.

Next it works out how the game is launched, so it can find the right Wine prefix. For Steam it looks up the AppID and checks it with protontricks. For Heroic it finds the game's prefix and makes sure it has been set up, meaning the game has been launched at least once. If it hasn't, the script says so and waits while you start the game and close it again. Steam and Heroic aren't the only options: a retail copy running in a prefix you made yourself works too, and the script asks you for the path.

Then it works out how the game plays 3D sound. Some games use DirectSound3D, which is what DSOAL translates. A few talk to OpenAL directly and need a different fix. If the game is in the database, the script already knows. If it isn't, it looks through the game's own `.exe` and `.dll` files for hints and tells you it's only guessing. If that doesn't settle it either, it asks you, and DirectSound3D is the default.

Last, it checks whether the game is 32-bit or 64-bit by reading its executables, so it fetches the matching files. A wrong guess here is a game that crashes on launch.

## Phase 2: Sound fix

This phase chooses what gets installed.

**The engine.** For most games this is kcat's DSOAL together with OpenAL Soft. A handful of games use OpenAL themselves and only need OpenAL Soft swapped in. When phase 1 already settled which one the game uses, the script doesn't ask.

**The builds.** You pick Stable, Latest, or each separately. Stable is a DSOAL revision that has been tested with this script, plus OpenAL Soft's newest release. Latest is DSOAL's newest build plus OpenAL Soft's rolling pre-release. Stable is the default. Only the builds you pick are downloaded, and each download is checked against its SHA256, so a corrupt or tampered file is caught. Downloads are cached, so installing to a second game doesn't fetch them again.

**The VC++ runtime.** Older Proton and Wine builds need Microsoft's VC++ 2022 runtime before they can load DSOAL and OpenAL Soft. The script checks whether the prefix has it and offers to install it through winetricks or protontricks. If those fail, it downloads it from Microsoft directly. It checks that the DLLs are really there afterwards, because the exit codes of those tools can't be trusted.

**Your speakers.** You say whether you're on stereo, headphones, surround or a matrix setup, and the script writes an `alsoft.ini` to match. For headphones it turns on OpenAL Soft's HRTF, a binaural mode that gives headphones a convincing sense of direction.

**Workarounds.** A few games stay silent or stutter even with the fix in place. For those the script offers an EAX Unified dummy (`eax.dll` and `eaxunified.dll`), routing of the DirectSound CLSIDs through the Wine registry (what fixes grayed-out EAX menus in *Grand Theft Auto: San Andreas* and *Halo: Combat Evolved*), and higher audio limits, which stop busy games like *F.E.A.R.* from stuttering. When the database knows a game needs one, it recommends it.

**The DLL override.** Wine only loads the new `dsound` and `openal32` files if told to. The script can set that for you in the game's Steam launch options or Heroic environment variables, which is the default because you can see it there and undo it easily. It can also write it into the Wine registry, or you can do it yourself and it prints the instructions. Any launch options you already have are kept. If Steam or Heroic is running, the script offers to close it for the change and reopen it afterwards, since both keep these settings in memory and would overwrite the edit.

## Phase 3: Game settings

Many games ship with EAX switched off in their own config files, or load their own audio DLL instead of the one the script installs. If the database knows about the game, this phase lists what it would change, with each file, the current value and the new one, and asks first. Audio settings are applied together. Optional settings, like Quake 4's low-resolution texture fix, are offered one at a time. If the game has nothing to change, the phase says so and moves on.

A game that hasn't created its config file yet, because you haven't launched it, gets the same treatment as a missing prefix: the script asks you to launch it once and then looks again.

## Phase 4: Install

Now the script does the work. It puts the files in the game folder and the Wine prefix. Anything already sitting where a file goes is backed up with a timestamp first, so you keep your original game data. It applies the DLL override and the game settings you accepted, and it writes a manifest, a list in the game folder of every file, registry key, launch option and setting it touched.

## Uninstalling

The manifest is what makes the uninstall safe. The script removes only what is listed there and restores your backups. If you changed a game setting yourself after the install, it leaves that alone. For an install that predates the manifest, the script falls back to looking for its known file names and only offers to remove files whose contents match what it installs. Running the uninstall twice on the same game does nothing the second time.

## Tools

The main menu has a Tools submenu for after the install.

**Optional settings** turns a game's optional settings on or off again. **Speaker configuration** changes the speaker setup, along with any of the game's own settings that depend on it, like BioShock's speaker mode. Both work on games this script has installed to, and uninstall still restores the original values.

**DSOAL logging** turns DSOAL's own log on or off for a game, so you don't edit launch options by hand. It's mainly for bug reports. See [Troubleshooting](troubleshooting.md#dsoal-logging).

**VC++ install** installs the VC++ runtime into a game's prefix without a full install, which helps if you skipped it the first time.

**Browse game profiles** opens a searchable list of every game in the database. The profile of the selected game appears next to the list, the same screen the install shows when you pick that game. It covers every store the game is sold on and shows where Steam and GOG differ.

### Browser keys

| Key | What it does |
| --- | --- |
| Ctrl-A | Narrow by audio: DirectSound3D, OpenAL or an EAX version |
| Ctrl-S | Narrow by store: Steam, GOG, or games delisted from either or one of them |
| Ctrl-T | Switch between games checked on a real install (the default), all games, and the ones nobody has checked yet |
| Ctrl-R | Switch between best match first and A to Z |
| Ctrl-L | Put the profile beside or under the list (it moves under by itself in a narrow window) |
| Tab | Show the game's settings in full: why each is offered, the file and where it lives, and the exact values |
| Shift-↑/↓, PgUp/PgDn | Scroll the profile |
| Ctrl-F | Open the profile full screen (q comes back) |
| F1 | List every key, most useful first |

## Safety

The script won't run as root or from Steam's Gaming Mode, and it doesn't modify SteamOS's read-only filesystem. At start-up it checks for a newer version of itself and offers to download it, checking the download against the release's `.sha256` (set `EAX_RESTORE_SKIP_UPDATE_CHECK=1` to skip that). Every run is logged, and [Troubleshooting](troubleshooting.md) says where to find the log.
