# Add a game

This tutorial adds a game to the database. You'll write its entry in the profile editor, test it with the script, and send it in.

You need a clone of this repository, `python3`, `jq`, `curl`, the Python `jsonschema` package and `fzf` (for the profile browser), and the game installed through Steam or Heroic. If you haven't run the script yet, do [Your first install](first-install.md) first so you know what a profile is for.

## 1. Check the game isn't there

Open the script and go to Tools, then Browse game profiles, and search for the game. The browser hides games nobody has checked yet, so press Ctrl-T to include them. The editor's sidebar lists every game file. If an entry exists but is wrong, open it from the sidebar instead of pressing **+ Add game**. [The game database](../database/overview.md) explains how entries are stored.

## 2. Start the editor

From the repository folder:

```bash
tools/profiler/eax-profiler
```

It opens in your browser. The [editor guide](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/tools/profiler/README.md) describes every button, and this page only follows the path you need.

## 3. Add the game

Press **+ Add game** and pick the game from the ones installed in Steam or Heroic, or type its name. Then fill in the tabs:

* Overview: the name, a one-sentence description, the release date, the file name of the game's main program (the `exe`), the audio API (DirectSound3D or OpenAL) and the EAX versions. Check them against a source such as PCGamingWiki and add that source to the Sources list.
* Stores: the Steam or GOG ID. Check each ID against the store's own page, because the script finds your game in the database by that ID.
* DSOAL settings: install options such as `alsoft.ini` values and recommended tweaks. Most games need nothing here.

The editor lists problems on the right as you go. The [game file reference](../database/game-file-reference.md) explains every field.

## 4. Find the game's settings

The Game settings tab lists the changes to the game's own config files, such as the ones that switch EAX on. You can write them by hand, or use Capture.

Capture is experimental, so its tab is hidden until you turn on **Show the Capture tab** in Settings. It works in four moves:

1. Open the game's Capture tab and press **Start capture**. The editor installs the fix and runs the game once by itself, so it can ignore options the game rewrites on its own.
2. Press **Open the game**. Switch EAX on in the game's audio menu and press **Snapshot: changed options**. For each speaker setup the game offers, pick it in the game and press its button. Then press **Close the game**.
3. Press **Build settings from the captures**. The editor drafts a setting for each difference.
4. Untick anything that isn't a real setting and check the rest against the game.

If you'd rather work by hand, compare the game's config files before and after you switch its sound options on. For settings kept in the registry, compare the prefix's `user.reg` and `system.reg`.

## 5. Save and rebuild

Press **Save**. The editor shows the exact change to the file, and you press **Write file** to confirm. Then press **Rebuild database** at the bottom of the sidebar. That regenerates `game-database.json` from your game file.

## 6. Test it with the script

Build the script and run it against your rebuilt database. `EAX_RESTORE_UNTESTED` makes it include an entry that's still in `untested/`, and `EAX_RESTORE_UNTESTED_SETTINGS` makes it offer settings you haven't marked verified yet, which is all of them for now.

```bash
./build.sh
EAX_RESTORE_GAME_DATABASE_FILE="$PWD/game-database.json" EAX_RESTORE_UNTESTED=1 EAX_RESTORE_UNTESTED_SETTINGS=1 ./dist/eax-restore-linux.sh
```

If you used Capture, the fix is already installed in the game. Run the script's uninstall for that game first, so you test a clean install.

Press `S` to scan, pick your game, and read the profile on screen. It should say what you wrote. Go through the install, start the game and check that the EAX options and the settings you added work. Then run the uninstall and confirm it puts the files and settings back.

To look at the profile on its own, run `tools/browse-game-database.sh game-database.json`. It opens the same browser as Tools, then Browse game profiles, and it needs `fzf`.

## 7. Mark what you verified

Back in the editor, click **Not verified** on each setting you confirmed in the game, so it shows as verified. Leave a new game in `untested/`. Submitting puts a new game there whatever folder it's in here, and a maintainer promotes it after checking every store ID and setting on a real install. If you're correcting a game that's already in `tested/`, it keeps its folder.

## 8. Send it in

Press **Submit...** in the game's header. The editor checks the entry against the schema and lists anything that looks personal, such as your home folder or user name, and you tick each one that's fine to share. With the GitHub CLI installed and logged in, it opens a pull request against `dev` for you. Without it, it opens GitHub's new-file page with the entry filled in. [Contributing a game](../database/contributing.md) lists what reviewers look for.
