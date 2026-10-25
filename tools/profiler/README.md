# Game profile editor and capture tool

This is a local web page for editing the game files in `data/games/` and `data/drafts/`. It can also work out what a game's settings should be by watching what changes when you turn the sound options on. It's plain Python 3 from the standard library, plus `jsonschema` for validation.

```bash
tools/profiler/eax-profiler               # starts it and opens http://127.0.0.1:8765
```

You need `python3`, `jq`, `curl` and the Python `jsonschema` package (`python3-jsonschema` on most distros). `--port N` picks another port. It builds `dist/` itself when that's missing or out of date.

## Contents

[Starting it](#starting-it) · [Editing](#editing) · [AI](#ai) · [Capture](#capture) · [Submit](#submit) · [Manage installs](#manage-installs) · [Housekeeping](#housekeeping)

## Starting it

Run `tools/profiler/install-launcher.sh` once to get it into your app menu as "EAX profile editor". `--remove` takes it out again.

Started from the menu, it has no terminal, so the **Quit** button in the page's header stops it. It also stops on its own a few minutes after you close the page, by default 180 seconds (`EAX_PROFILER_QUIT_SECONDS`). It never stops during a capture, or while a game is open from the page. If you start it a second time while it's running, it just opens the page again. When `chromium` or `google-chrome` is installed, the page opens in its own window without the browser's toolbars.

The plain command still works: `python3 tools/profiler/profiler.py [--port 8765] [--no-open] [--quit-when-closed]`.

## Editing

The **Edit** tab builds its forms from `data/schema.json`, with dropdowns, checkboxes and a table for a setting's changes. It validates as you type. When you save, it first shows the exact change to the file, then writes it, runs `tools/format-game-database.sh` and lists anything still invalid. "Move to..." does the `git mv` between drafts, untested and tested. **Rebuild database** runs `tools/build-game-database.sh`.

**Verified.** Each game setting, and a game's alsoft.ini values, has a *Verified* or *Not verified* button in its header. It's visible even when the card is folded, and a click switches it. The Audio and Optional settings headings count how many are not verified yet. If you edit a verified setting's changes, its *Only offer when...* or the alsoft.ini values, it goes back to not verified, because what was checked has changed. The card's ↺ undoes that along with the edit. The list under the search box can show only the games with no game settings, or only those with something not verified. An amber *cfg* tag marks the second kind.

**Build status.** The tool compares each saved game file with `game-database.json`, the way `tools/build-game-database.sh` would write it. A game that differs gets an amber "changed" or "not built" tag in the list and a badge in its header. The **Rebuild database** button shows how many games it's behind, including entries whose file has been removed. Drafts are never built, so they show nothing. This reflects the saved file, not edits you haven't saved yet.

## AI

The ✨ buttons, Research and the setting titles and reasons use AI. The editor looks for credentials in this order: the `ANTHROPIC_API_KEY` environment variable, an API key saved from the editor, and the logged-in `claude` command. Open **Settings** in the top bar to set it up without a terminal.

Everything starts off, so nothing is sent until you turn something on. **Use AI** is the master switch, and each feature has its own:

* Research, Description, Notes, and Setting titles and reasons each control a ✨ button. Research is at the top of a game, Description and Notes are on the Overview tab, and setting titles are on the Game settings tab. A button is hidden while its switch is off.
* "Untick unrelated changes" lets the AI untick captured changes it judges to be bookkeeping.
* Under **Experimental** there are two more, "Setting titles and reasons from captures" and "Suggest values". Their results are often wrong.
* The switches that only work on captures are greyed out while the Capture tab is off.

**Appearance** switches between light, dark and your system's setting, and the browser remembers it.

To sign in, **Sign in** runs the `claude` command's own browser sign-in, and **Sign out** reverses it. You can also paste an Anthropic API key into the key field. The editor checks it with Anthropic and saves it to `~/.config/eax-restore-linux/profiler.json`, readable only by you. **Remove** deletes it. The page never gets the key back, only its last four characters.

Here is what goes to Anthropic. It's the game's name and, when drafting, the file names, section names, keys and old and new values of the captured changes (up to 150), after your home folder, user name and any number of nine digits or more have been replaced. Nothing else from your machine is sent. The `claude` command runs from an empty folder with its tools off. Whatever comes back is only a suggestion. Store IDs are never filled in, and `id_source` is never set for you.

## Capture

Capture replaces doing the comparison by hand.

> [!NOTE]
> It's experimental, so its tab is hidden until you turn on **Show the Capture tab** under **Capture** in Settings. The browser remembers the setting.

There are three stages, all on one screen.

**1. Prepare.** This takes one click and no input. Open the *Capture* tab for an installed Steam or Heroic game and press *Start capture*. Steps you captured earlier are already there. The tool then:

* snapshots the config files and the prefix registry
* installs the fix unattended, by running `dist/eax-restore-linux.sh` with `EAX_RESTORE_ANSWERS_FILE` and a database that holds only this game's exe, audio API and extra exe folders, so the right engine goes into the folder the exe is in
* applies no game settings, and uses the registry route for the DLL override so the launcher is left alone
* starts the game once and closes it by itself, launching it first if the prefix doesn't exist yet

That baseline run is how options the game rewrites by itself get ignored.

The executable name comes from the entry's `exe`, and it follows the entry if you edit it while capturing. If it's empty, type the name in the field or use *Browse...* to pick the `.exe`. Without it the baseline run is skipped and *Open the game* won't work. If the game is installed in both Steam and GOG, the tool asks which copy to capture first. Each copy has its own session.

**2. Your turn.** This is the only manual part. *Open the game* starts it once and keeps the page's buttons live. In the game:

1. Switch EAX or hardware audio on, and change any other options you want to offer, like resolution or textures. Press *Snapshot: changed options*.
2. For each speaker setup the game's audio menu offers (headphones, Pro Logic, 4.0, 5.1, 6.1, 7.1, stereo), pick it in the game and press its button.
3. Press *Close the game* when you're done.

Each snapshot first waits for Wine to write its registry changes to disk. Wine does that about every 30 seconds, so a snapshot can take up to 35 seconds, or less when the write comes sooner. Leave the game as it is meanwhile.

**3. Review.** *Build settings from the captures* compares the snapshots and drafts the settings.

* Changes whose names look like timestamps or window positions, and anything the AI judges to be the game's own bookkeeping, come up unticked with the reason shown. Tick one to keep it.
* Each change has a *Category*, Audio or Optional, guessed from its name. Flip it where the guess is wrong.
* Your ticks, categories and the draft are saved with the session, so reloading the page keeps them.
* With "Setting titles and reasons from captures" on (Experimental), the AI writes each setting's title and reason.
* The AI may also suggest `alsoft_ini` values and EAX versions. Each has an Apply button, and none is applied for you.

What each snapshot is compared with is fixed. The options snapshot is compared with the baseline. Sessions captured before the two were merged also have a separate *other options* snapshot, which is compared the old way and drafted into the same table. Speaker layouts are compared with the audio snapshot. Redoing an unrelated step doesn't change any of that.

Layouts that change the same values are merged into one setting. 5.1 and 6.1 go together if the game has no 6.1, and all four surround layouts together become "surround". Each merged setting gets `only_if.speakers`, the way BioShock and Neverwinter Nights do. Skip layouts the game doesn't have.

The diffs become a `game_config` draft, which is merged into the entry for you to review. The merge never overwrites what's already there:

* A setting whose changes are all present, with the same keys, values and `only_if`, is skipped.
* A partly new setting keeps only the new keys.
* A key that exists with a different value is kept and flagged.
* A config file the entry already defines keeps its own definition.

## Submit

**Submit...**, in a game's header, sends the profile to the project. It first checks the profile against the schema and lists anything that looks like it came from your computer, such as your home folder, your user name or a long number. You have to tick that each one is fine to share.

If the GitHub CLI (`gh`) is installed and you're logged in, it then forks the repo if you don't have a fork. It puts the profile and the matching `game-database.json` entry on a new `profile/<id>-<date>` branch of your fork through GitHub's API, so your own clone's git state isn't touched. Finally it opens a pull request against `dev`.

Without `gh`, or if you pick *Use the browser instead*, it opens GitHub's new-file page with the profile filled in. A profile too long for the address comes with a Copy button. A maintainer rebuilds `game-database.json` when merging.

A new game goes in `data/games/untested/`, and one that already exists upstream keeps its folder. Only the game file is sent. Your captured snapshots stay in the sessions folder described below. `EAX_PROFILER_UPSTREAM=owner/repo` and `EAX_PROFILER_BASE=branch` point it at a test repo.

## Manage installs

**Manage installs...**, in the sidebar next to + Add game, lists every install of the script. That includes leftovers of games you've since removed from Steam or Heroic, and every prefix of a game that has a profile. For each game you can:

* **Remove install.** For a game still in your library, this runs the script's own uninstall unattended. For a game that's gone, the tool deletes the files in the install record itself, puts back the backed-up originals and removes the folder if it's empty. If Steam or Heroic is running, the launch-option override is left in place instead of closing the launcher.
* **Delete prefix.** This deletes the game's Wine prefix, which is Steam's `compatdata/<AppID>` or the Heroic prefix. The launcher makes a new one on the next launch. It refuses a symlink, a folder that isn't a Steam compatdata or Heroic prefix folder, a prefix shared by several Heroic games, and anything while the game or Wine is running.
* **Start fresh.** This does both, plus removes the capture session, for a clean test.

Every action shows exactly what it will delete first, and nothing is touched until you confirm. Prefixes are only offered for games that have a profile, never from a blanket list of orphan folders.

## Housekeeping

**Clearing a game's captures.** *Clear this game's captured data*, at the top right of the Capture tab, deletes that game's snapshots, draft and ticks after asking. It won't run while the game is open from the page. The game's profile and anything installed are left alone. **Manage installs...** → *Start fresh* also removes the install and prefix.

**Seeing what a step captured.** Every finished capture step has a **View** button. It lists the files that step watched and the keys that changed since the step before it, or since the audio run for a speaker layout. Next to each change is the reason it would be left out of the draft: it looks like bookkeeping, such as timestamps and window positions, or the baseline run showed that the game rewrites it by itself. The install step's own changes, like the OpenAL registry count, show up there too, though they never feed the draft.

**Problems.** Click one in the right-hand list and the editor switches to the right tab, opens any collapsed setting around it, scrolls to the field, flashes it and puts the cursor in it.

**Setting order.** On the Game settings tab, each setting has ↑ and ↓ to reorder it, and **→ Optional** or **→ Audio** to move it to the other list. The order in the file is the order the player sees.

**Source order.** On the Overview tab, each source has ↑ and ↓ to move it. The game profile lists them in that order.

Sessions are kept in `~/.local/state/eax-restore-linux/profiler/<store>-<id>/`, under `$XDG_STATE_HOME` if it's set. The saved AI key lives under `$XDG_CONFIG_HOME`, which defaults to `~/.config`.

When it starts, the editor fetches its checkout's upstream branch in the background. If you're behind, a banner offers **Update**. That runs `git pull --ff-only` (or `git merge --ff-only` onto the upstream branch it fetched), rebuilds `dist/` and asks you to restart the editor. A checkout with commits of its own, no upstream or no network gets no offer. `EAX_PROFILER_NO_UPDATE_CHECK=1` turns the check off.

The header shows a build number next to the title, with the branch and commit the editor is running from. It's the number of commits that have touched `tools/profiler`, counted from git, so there's nothing to bump.

Binary `gadb` files, like F.E.A.R.'s profile, are read by key name, the same way the script reads them, so a switched on or off setting comes through like any other change. Launching through Heroic's `heroic://launch?appName=...&runner=gog` URL has been checked on a real install.

## For developers

The code is in `capture.py` (library, snapshots, diffs), `classify.py` (noise flags, the drafted `game_config`, the AI passes), `cleanup.py`, `dbio.py`, `ai.py`, `profiler.py` (the server), `submit.py` (the Submit button), `update.py` (the Update banner), `web/` (the page) and `install-launcher.sh` (the app-menu entry).

The tests run with `python3 -I -m unittest discover -s tools/profiler/tests`. They include golden checks that F.E.A.R.'s `gadb` changes and Descent 3's registry changes come out as their database entries say. `tests/integration/profiler-answers.bats` fails if the script's prompts drift from the canned answers in `capture.py`.
