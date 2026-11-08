# Your first install

This walks you through restoring EAX sound in one old game and then taking the fix out again. EAX is the set of reverb and 3D positioning effects those games used on Creative sound cards. The example is a Steam game, and a game from Heroic goes the same way.

## Before you start

You need a game from the late 90s or early 2000s that used EAX, and a terminal. Start the game once and close it, so Proton or Wine creates the game's prefix. The script needs that prefix, and if it can't find one it asks you to launch the game and then looks again.

## 1. Get the script

Download it from the latest release and make it executable:

```bash
curl -LO https://github.com/tanuki2k/eax-restore-linux/releases/latest/download/eax-restore-linux.sh
chmod +x eax-restore-linux.sh
```

On a Steam Deck, the [README](https://github.com/tanuki2k/eax-restore-linux#steam-deck) has a launcher you can double-click instead.

## 2. Start it

```bash
./eax-restore-linux.sh
```

The script first checks that your tools are there: `curl`, `unzip`, `file`, `grep`, `awk` and `jq`, plus `protontricks` for Steam games or `winetricks` for Heroic. On apt, pacman and dnf systems it offers to install what's missing. On other distros it tells you what to install.

## 3. Pick your game

The main menu asks what you want to do. Press `S` to scan your Steam and Heroic libraries, and the script lists the games it recognises. Pick yours by number. If it isn't listed, press `M` and type the path to the folder that holds the game's `.exe`. The script then guesses the audio API from the game's files, and asks you if it can't tell.

For a game in the database, the script prints its profile before it asks anything else. It shows which EAX versions the game supports, which audio API it uses, and anything you should know about it. Read it, because it tells you what the install is going to do. [Library scanning](../script/library-scanning.md) explains what the profile contains.

## 4. Answer the questions

The script asks a series of questions and changes nothing yet.

* Which engine and builds to install. Latest is the default, and Stable is a build that has been tested with this script.
* Whether to install the VC++ runtime, which older Proton and Wine builds need before they can load the new files.
* Whether you use stereo, headphones or surround sound. The script writes an `alsoft.ini` to match.
* Where to put the DLL override, the setting that tells Wine to load the new sound files instead of the game's own. The default is the game's Steam launch options or Heroic environment variables, where you can see it and undo it.
* Which of the game's own settings to change. The script shows each file, the current value and the new one, and asks first.

[How it works](../script/how-it-works.md) covers each of these in detail.

## 5. Let it run

When the questions are done, the script shows a summary and asks "Proceed?". Nothing on your system has changed up to this point, so you can still quit. Say yes and it copies the files into the game folder and the prefix, backing up anything it replaces, then applies the override and the settings you accepted. It records everything in a manifest in the game folder.

When it finishes, it lists any steps you still have to do yourself, such as switching your receiver to Dolby Pro Logic.

## 6. Check it worked

Start the game and open its audio options. Look for the EAX or hardware 3D sound choices. With the fix in place you can pick them. If you can't, [Troubleshooting](../script/troubleshooting.md) explains how to find the run log and how to turn on DSOAL's own log. DSOAL is the part that handles the game's 3D sound.

## 7. Undo it

Run the script again and press `U`. Pick the game, and the script lists what it will remove and which backed-up originals it will restore. Say yes at the final "Proceed?" and it puts the game back as it was, including your game settings, unless you changed them yourself since.

## Where to go next

* [Environment variables](../script/environment-variables.md) for repeat runs and scripting.
* The Tools menu, described in [How it works](../script/how-it-works.md#tools), changes a game's settings or speakers without reinstalling.
* If your game isn't in the database, the [Add a game tutorial](add-a-game.md) shows how to add it.
