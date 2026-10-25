# Game profile editor and capture tool

A local web UI over `data/games/*` and `data/drafts/`. Standard-library Python; validation uses `jsonschema`.

```bash
tools/profiler/eax-profiler               # starts it and opens http://127.0.0.1:8765
```

It needs `python3`, `jq`, `curl` and the Python `jsonschema` package (`python3-jsonschema`). `--port N` picks another port, and it builds `dist/` itself when that is missing or out of date.

## Contents

[Starting it](#starting-it) · [Editing](#editing) · [AI](#ai) · [Capture](#capture) · [Submit](#submit) · [Manage installs](#manage-installs) · [Housekeeping](#housekeeping)

## Starting it

To get it in the app menu as "EAX profile editor", run `tools/profiler/install-launcher.sh` once (`--remove` takes it out again). Launched this way there is no terminal: the **Quit** button in the page's header stops it, and it also stops by itself a few minutes after the page is closed (`EAX_PROFILER_QUIT_SECONDS`, default 180) (never during a capture or while a game is open from the page). Running it a second time while it is up only opens the page again. If `chromium` or `google-chrome` is installed the page opens in its own window without browser chrome. The plain command still works: `python3 tools/profiler/profiler.py [--port 8765] [--no-open] [--quit-when-closed]`.

## Editing

**Edit**: forms are generated from `data/schema.json` (dropdowns, checkboxes, a table for a setting's changes), with live validation. Save shows the exact change to the file first, then writes it, runs `tools/format-game-database.sh`, and shows what's still invalid. "Move to…" does the `git mv` between drafts / untested / tested. **Rebuild database** runs `tools/build-game-database.sh`.

**Verified:** each game setting, and a game's alsoft.ini values, has a *Verified* / *Not verified* button in its header. It's visible with the card folded, and clicking it switches it. The Audio and Optional settings headings count how many aren't verified. Editing a verified setting's changes or its *Only offer when…* (or the alsoft.ini values) sets it back to not verified, since what was checked has changed; the card's ↺ undoes that along with the edit. The list under the search box can show only the games with no game settings, or only those with something not verified yet; the amber *cfg* tag marks the second kind.

**Build status:** the tool compares each saved game file with `game-database.json`, the way `tools/build-game-database.sh` would write it. A game that differs gets an amber "changed" or "not built" tag in the list and a badge in its header, and the **Rebuild database** button shows how many games it's behind (including entries whose file has been removed). Drafts are never built, so they show nothing. It reflects the saved file, not edits you haven't saved yet.

## AI

The ✨ buttons, "Research" and setting titles/reasons use AI. It uses `ANTHROPIC_API_KEY` if set, otherwise an API key saved from the editor, otherwise the logged-in `claude` CLI. Open **Settings** in the top bar to set it up without a terminal. **Use AI** there turns every AI feature off. Each feature has its own switch and they all start off, so nothing is sent until you turn one on. Research, Description, Notes and Setting titles and reasons each control a ✨ button (Research at the top of a game, Description and Notes on the Overview tab, setting titles on the Game settings tab), hidden while its switch is off, and "Untick unrelated changes" lets the AI untick captured changes it judges to be bookkeeping. Under **Experimental** there are two more, "Setting titles and reasons from captures" and "Suggest values", whose results are often wrong. The AI switches that only work on captures are greyed out while the Capture tab is off. **Appearance** switches between light, dark and matching your system (saved in the browser). The sign-in options: **Sign in** runs the claude command's own browser sign-in (**Sign out** reverses it), and the key field checks a pasted Anthropic API key with Anthropic and saves it to `~/.config/eax-restore-linux/profiler.json`, readable only by you (**Remove** deletes it). The page never gets the key back, only its last four characters. What is sent to Anthropic: the game's name and, when drafting, the file names, section names, keys and old/new values of the captured changes (up to 150), with your home folder, user name and numbers of nine digits or more replaced first. Nothing else from your machine goes. The `claude` command runs from an empty folder with its tools off. Everything it returns is a suggestion; store IDs are never filled in, and `id_source` is never set for you.

## Capture

Capture is the part that replaces doing it by hand.

> [!NOTE]
> It's experimental, so its tab is hidden until you turn on **Show the Capture tab** under **Capture** in Settings (saved in the browser).

It's three stages on one screen:

1. **Prepare** (one click, no input). Open the *Capture* tab for an installed Steam/Heroic game (steps captured earlier are already there) and press *Start capture*. The tool snapshots the config files and the prefix registry, installs the fix unattended (runs `dist/eax-restore-linux.sh` with `EAX_RESTORE_ANSWERS_FILE`, a database holding only this game's exe and audio API (and extra exe folders), so it deploys the right engine in the folder the exe is in, and no Game Settings are applied, and the registry override route so the launcher is left alone), then starts the game once and closes it itself: that baseline run is how options the game rewrites by itself get ignored. It launches the game first if the prefix doesn't exist yet. The executable name comes from the entry's `exe` and follows it if you edit it in the profile while capturing; type it in the field or use *Browse…* to pick the .exe if it's empty (without it the baseline run is skipped and *Open the game* won't work). A game installed in both Steam and GOG asks which copy to capture first; each copy has its own session.
2. **Your turn** (the only manual part). *Open the game* starts it once and keeps the page's buttons live. Switch EAX / hardware audio on in the game, change any other options you want to offer (resolution, textures…), and press *Snapshot: changed options*; then, for each speaker setup the game's audio menu offers (headphones, Pro Logic, 4.0, 5.1, 6.1, 7.1, stereo), pick it in the game and press its button. *Close the game* when done. Each snapshot first waits for Wine to write its registry changes to disk (it does so about every 30 seconds, so up to 35 seconds; less when the write comes sooner); leave the game as it is meanwhile.
3. **Review**. *Build settings from the captures* compares the snapshots and drafts the settings. Changes whose names look like timestamps or window positions, and anything the AI judges to be the game's own bookkeeping, come up unticked with the reason shown; tick them to keep them. Each change has a *Category* (Audio or Optional), guessed from its name; flip it where the guess is wrong. Your ticks, categories and the draft are saved with the session, so a page reload keeps them. With "Setting titles and reasons from captures" on (Experimental), the AI writes each drafted setting's title and reason. The AI may also suggest `alsoft_ini` values and EAX versions; each has an Apply button and none is applied for you.

What each snapshot is compared with is fixed: the options snapshot with the baseline (sessions captured before the two were merged also have a separate *other options* snapshot, which is compared the old way and drafted into the same table), speaker layouts with the audio snapshot. Redoing an unrelated step doesn't change it. Layouts that change the same values are merged into one setting (5.1 and 6.1 together if the game has no 6.1; all four surround layouts together become "surround"), each gated with `only_if.speakers` the way BioShock and Neverwinter Nights are. Skip layouts the game doesn't have.

The diffs become a `game_config` draft that is merged into the entry for review. Merging into an entry leaves out anything it already has: a setting whose changes are all present (same keys and values, same `only_if`) is skipped, a partly new one keeps only the new keys, a key that exists with a different value is kept and flagged, and a config file the entry already defines keeps its own definition.

## Submit

**Submit…** (a game's header) sends the profile to the project. It first checks the profile against the schema and lists anything that looks like it came from your computer (your home folder or user name, a long number), which you have to tick as fine to share. Then, with the GitHub CLI (`gh`) installed and logged in, it forks the repo if you don't have a fork, puts the profile and the matching `game-database.json` entry on a new `profile/<id>-<date>` branch of your fork through GitHub's API (your clone's git state isn't touched), and opens a pull request against `dev`. Without `gh`, or with *Use the browser instead*, it opens GitHub's new-file page with the profile filled in (a profile too long for the address comes with a Copy button), and a maintainer rebuilds `game-database.json` when merging. A new game goes in `data/games/untested/`; one that already exists upstream keeps its folder. Only the game file is sent: your captured snapshots stay in the sessions folder below. `EAX_PROFILER_UPSTREAM=owner/repo` and `EAX_PROFILER_BASE=branch` point it at a test repo.

## Manage installs

**Manage installs…** (sidebar, next to + Add game) lists every install of the script, including leftovers of games you've since removed from Steam or Heroic, and every prefix of a profiled game. Per game:
- **Remove install**: for a game still in your library this runs the script's own uninstall unattended. For a game that's gone, the tool deletes the files in the install record itself, puts back backed-up originals, and removes the folder if it's empty. If Steam or Heroic is running, its launch-option override is left in place rather than closing the launcher.
- **Delete prefix**: deletes the game's Wine prefix (Steam's `compatdata/<AppID>` or the Heroic prefix); the launcher makes a new one on the next launch. It refuses a symlink, a folder that isn't a Steam compatdata or Heroic prefix folder, a prefix shared by several Heroic games, and anything while the game or Wine is running.
- **Start fresh**: both, plus the capture session, for a clean test.

Every action shows exactly what it will delete first, and nothing is touched until you confirm. Prefixes are only offered for games that have a profile, never from a blanket list of orphan folders.

## Housekeeping

**Clearing a game's captures:** *Clear this game's captured data*, top right of the Capture tab, deletes that game's snapshots, draft and ticks after asking (not while the game is open from the page). The game's profile and anything installed are left alone; **Manage installs…** → *Start fresh* also removes the install and prefix.

**Seeing what a step captured:** every finished capture step has a **View** button. It lists the files that step watched and the keys that changed since the step before it (or since the audio run, for a speaker layout), with the reason a change would be left out of the draft: it looks like bookkeeping (timestamps, window positions), or the baseline run showed the game rewrites it on its own. The install step's own changes (for example the OpenAL registry count) show up there too, though they never feed the draft.

**Problems:** clicking one in the right-hand list switches to the right tab, opens any collapsed setting around it, scrolls to the field, flashes it and puts the cursor in it.

**Setting order:** in Game settings each setting has ↑ and ↓ to reorder it, and **→ Optional** / **→ Audio** to move it to the other list. The order in the file is the order the player sees.

**Source order:** on the Overview tab each source has ↑ and ↓ to move it. The game profile lists them in that order.

Sessions are kept in `~/.local/state/eax-restore-linux/profiler/<store>-<id>/` (under `$XDG_STATE_HOME` if it is set); the saved AI key lives under `$XDG_CONFIG_HOME` (default `~/.config`).

On start the editor fetches its checkout's upstream branch in the background; when it is behind, a banner offers **Update**, which runs `git pull --ff-only` (or `git merge --ff-only` onto the upstream branch it fetched) and rebuilds `dist/`, then asks you to restart the editor. A checkout with commits of its own, no upstream or no network gets no offer. `EAX_PROFILER_NO_UPDATE_CHECK=1` turns the check off.

The header shows a build number: how many commits have touched `tools/profiler`, counted from git, so there is nothing to bump. It sits next to the title with the branch and commit the editor runs from.

Layout: `capture.py` (library, snapshots, diffs), `classify.py` (noise flags, the drafted `game_config`, the AI passes), `cleanup.py`, `dbio.py`, `ai.py`, `profiler.py` (server), `submit.py` (the Submit button), `update.py` (the Update banner), `web/` (the page), `install-launcher.sh` (the app-menu entry). Tests: `python3 -I -m unittest discover -s tools/profiler/tests` (includes golden checks that F.E.A.R.'s `gadb` and Descent 3's registry changes come out as their database entries say); `tests/integration/profiler-answers.bats` fails if the script's prompts drift from the canned answers in `capture.py`.

Binary `gadb` files (F.E.A.R.'s profile) are read by key name, the same way the script reads them, so a switched on/off setting comes through like any other change. Launching through Heroic's `heroic://launch?appName=…&runner=gog` URL has been checked on a real install.
