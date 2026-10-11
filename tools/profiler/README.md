# Game profile editor and capture tool

A local web UI over `data/games/*` and `data/drafts/`. Standard-library Python; validation uses `jsonschema`.

    python3 tools/profiler/profiler.py        # opens http://127.0.0.1:8765

**Edit**: forms are generated from `data/schema.json` (dropdowns, checkboxes, a table for a setting's changes), with live validation. Save shows the exact change to the file first, then writes it, runs `tools/format-game-database.sh`, and shows what's still invalid. "Move to…" does the `git mv` between drafts / untested / tested. **Rebuild database** runs `tools/build-game-database.sh`.

**Build status:** the tool compares each saved game file with `game-database.json`, the way `tools/build-game-database.sh` would write it. A game that differs gets an amber "changed" or "not built" tag in the list and a badge in its header, and the **Rebuild database** button shows how many games it's behind (including entries whose file has been removed). Drafts are never built, so they show nothing. It reflects the saved file, not edits you haven't saved yet.

**AI** (the ✨ buttons, "Research game", setting titles/reasons): uses `ANTHROPIC_API_KEY` if set, otherwise the logged-in `claude` CLI. Everything it returns is a suggestion; store IDs are never filled in, and `id_source` is never set for you.

**Capture** (the part that replaces doing it by hand):
1. Pick an installed Steam/Heroic game. 2. *Snapshot* config files and the prefix registry. 3. *Install DSOAL* unattended: runs `dist/eax-restore-linux.sh` with `EAX_RESTORE_ANSWERS_FILE`, an empty game database (so no Game Settings are applied) and the registry override route (the launcher is left alone). 4. Optional *baseline* run, so options the game rewrites by itself are ignored. 5. *Audio run*: the game starts; you switch EAX / hardware audio on and quit. 6. Optional run for optional settings. 7. Changes whose names look like timestamps or window positions, and anything the AI judges to be the game's own bookkeeping, come up unticked with the reason shown; tick them to keep them. The AI may also suggest `alsoft_ini` values and EAX versions; each has an Apply button and none is applied for you.
8. **Speaker layouts** (optional, after the audio run): for each speaker setup the game's own audio menu offers (headphones, Pro Logic, 4.0, 5.1, 6.1, 7.1, stereo), press Run, pick that layout in the game, and quit. The tool compares each run with the audio run. Layouts that change the same values are merged into one setting (5.1 and 6.1 together if the game has no 6.1; all four surround layouts together become "surround"), each gated with `only_if.speakers` the way BioShock and Neverwinter Nights are. Skip layouts the game doesn't have.
9. The diffs become a `game_config` draft that is merged into the entry for review. Merging into an entry leaves out anything it already has: a setting whose changes are all present (same keys and values, same `only_if`) is skipped, a partly new one keeps only the new keys, a key that exists with a different value is kept and flagged, and a config file the entry already defines keeps its own definition.

**Clean up** (top bar, or a game's header): lists every install of the script, including leftovers of games you've since removed from Steam or Heroic, and every prefix of a profiled game. Per game:
- **Remove install**: for a game still in your library this runs the script's own uninstall unattended. For a game that's gone, the tool deletes the files in the install record itself, puts back backed-up originals, and removes the folder if it's empty. If Steam or Heroic is running, its launch-option override is left in place rather than closing the launcher.
- **Delete prefix**: deletes the game's Wine prefix (Steam's `compatdata/<AppID>` or the Heroic prefix); the launcher makes a new one on the next launch. It refuses a symlink, a folder that isn't a Steam compatdata or Heroic prefix folder, a prefix shared by several Heroic games, and anything while the game or Wine is running.
- **Start fresh**: both, plus the capture session, for a clean test.

Every action shows exactly what it will delete first, and nothing is touched until you confirm. Prefixes are only offered for games that have a profile, never from a blanket list of orphan folders.

**Seeing what a step captured:** every finished capture step has a **View** button. It lists the files that step watched and the keys that changed since the step before it (or since the audio run, for a speaker layout), with the reason a change would be left out of the draft: it looks like bookkeeping (timestamps, window positions), or the baseline run showed the game rewrites it on its own. The install step's own changes (for example the OpenAL registry count) show up there too, though they never feed the draft.

**Problems:** clicking one in the right-hand list switches to the right tab, opens any collapsed setting around it, scrolls to the field, flashes it and puts the cursor in it.

**Setting order:** in Game settings each setting has ↑ and ↓ to reorder it, and **→ Optional** / **→ Audio** to move it to the other list. The order in the file is the order the player sees.

Sessions are kept in `~/.local/state/eax-restore-linux/profiler/<store>-<id>/`.

Layout: `capture.py` (library, snapshots, diffs), `classify.py` (noise flags, the drafted `game_config`, the AI passes), `cleanup.py`, `dbio.py`, `ai.py`, `profiler.py` (server). Tests: `python3 -I -m unittest discover -s tools/profiler/tests` (includes golden checks that F.E.A.R.'s `gadb` and Descent 3's registry changes come out as their database entries say); `tests/integration/profiler-answers.bats` fails if the script's prompts drift from the canned answers in `capture.py`.

Binary `gadb` files (F.E.A.R.'s profile) are read by key name, the same way the script reads them, so a switched on/off setting comes through like any other change. Launching through Heroic's `heroic://launch?appName=…&runner=gog` URL has been checked on a real install.
