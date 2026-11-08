# Using the game profile editor

The profile editor is a web page that runs on your own computer. You use it to add a game to the [game database](game-database.md), correct an existing entry, or check how a game's settings should read. It edits the game files in `data/games/` through forms, so there's no JSON to type, and it checks what you enter as you go. You don't need it to *use* the script. It's for people adding or fixing games.

Contributing a game starts with [Contributing a game](contributing-games.md), which explains the folders and the rules. This page is the walkthrough of the editor itself.

## Before you start

You need a checkout of the project, because the editor works on the files in it. You also need `python3`, `jq`, `curl` and the Python `jsonschema` package (`python3-jsonschema` on most distros).

```bash
tools/profiler/eax-profiler
```

This opens `http://127.0.0.1:8765` in your browser. `--port N` picks another port. If `chromium` or `google-chrome` is installed, the page opens in its own window without the browser's toolbars.

To start it from your app menu instead, run `tools/profiler/install-launcher.sh` once. It adds an entry called "EAX profile editor", and `--remove` takes it out again. Started that way there's no terminal, so use the **Quit** button in the page's header to stop it. It also stops by itself a few minutes after you close the page.

## Finding a game

The list down the left side holds every game file. Type in the search box to narrow it, and use the dropdown under it to show only some games, such as the ones with no game settings or the ones with something not verified yet. A coloured tag next to a game means its saved file differs from `game-database.json`, so the database needs rebuilding.

To add a game, press **+ Add game**. You can pick one that's installed in Steam or Heroic but has no profile yet, or type its name.

## Editing a game

A game's page has these tabs.

| Tab | What it holds |
| --- | --- |
| Overview | The name, one-sentence description, release date, `exe`, EAX versions, sources and notes |
| Stores | The Steam and GOG IDs, and the text that's specific to each store |
| DSOAL settings | The audio API and the `alsoft.ini` values the install writes |
| Game settings | Changes to the game's own config files that switch on EAX, set up speakers or fix something else |
| Capture | Works out the game settings for you. It's hidden until you turn it on (see below) |

The fields are the ones in the [game file reference](game-file-reference.md), shown as dropdowns, checkboxes and tables. A problem shows up in the list on the right. Click it and the editor jumps to the field.

On the Game settings tab, each setting has ↑ and ↓ to put it in order, and **→ Optional** or **→ Audio** to move it between the two lists. The order in the file is the order players see.

### Verified

Each game setting, and the `alsoft.ini` values, has a **Verified** or **Not verified** button. Click it once you've checked the setting on a real install. If you later change what a verified setting does, it goes back to not verified, because what was checked has changed.

### Saving

Press **Save** (or Ctrl+S). The editor shows you the exact change to the file, writes it, tidies it with the project's formatter and lists anything that is still invalid.

Use **Move to…** to move a game between `drafts`, `untested` and `tested`. Move one to `tested` only once you've checked every store ID against the store's own page.

When you're done, press **Rebuild database** at the bottom of the list. That regenerates `game-database.json` from your game files, as `tools/build-game-database.sh` would.

## Working out the settings with Capture

Capture finds which config keys change when you turn a game's sound options on, so you don't compare files by hand. It's experimental. To see its tab, open **Settings** in the header and tick **Show the Capture tab**.

It works for a game installed in Steam or Heroic, in three steps:

1. **Prepare.** Press *Start capture*. The editor saves a copy of the game's config files and the prefix registry, installs the EAX fix without asking you anything, and runs the game once and closes it. That baseline run lets it ignore options the game rewrites by itself.
2. **Your turn.** Press *Open the game*. Switch EAX on and change any other options you want to offer, then press *Snapshot: changed options*. For each speaker setup the game offers, pick it in the game and press its button. Press *Close the game* when you've finished. A snapshot can take up to about 35 seconds, because it waits for Wine to write its registry to disk.
3. **Review.** Press *Build settings from the captures*. The editor drafts the settings. Untick anything that isn't a real setting, and fix the Audio or Optional label where it guessed wrong. Check the result against the game before you save it.

The editor never overwrites what's already in the entry. A setting that's already there is skipped, and a key that exists with a different value is kept and flagged for you.

The tab has more detail, such as viewing what each step captured and clearing a game's captures. The [profiler README](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/tools/profiler/README.md#capture) covers them.

## Optional: AI help

The ✨ buttons can draft a description, notes, and setting titles and reasons. Everything is off until you switch it on in **Settings**, where you can sign in with the `claude` command or paste an Anthropic API key. Only the game's name and, when drafting from a capture, the changed keys and values are sent, with your home folder and user name removed. Whatever comes back is only a suggestion, so read it before you keep it. Store IDs are never filled in for you.

## Sending your profile in

Press **Submit…** in the game's header. The editor checks the profile against the schema and lists anything that looks like it came from your computer, such as your home folder, your user name or a long number. You have to tick that each one is fine to share.

If the GitHub CLI (`gh`) is installed and you're logged in, it forks the repo if you don't have a fork and opens a pull request for you against the `dev` branch. Without `gh`, it opens GitHub's new-file page with the profile filled in, with a Copy button if it's too long for the address. A new game goes in `untested/` until someone has checked it on a real install.

## Cleaning up after testing

**Manage installs…**, in the sidebar, lists every install of the script on your machine, including ones for games you've since removed. For each you can remove the install, delete the game's Wine prefix, or do both for a clean start. It shows exactly what it will delete first, and nothing is touched until you confirm.

## When something goes wrong

* **The page won't open.** Check the terminal for an error, or try `--port` with a different number.
* **A message says a tool is missing.** Install `python3-jsonschema`, `jq` and `curl`.
* **The editor says you're behind.** A banner at the top offers an **Update** that pulls the latest commits and rebuilds. It only appears when your checkout has no commits of its own.
* **Your edits vanished.** The editor asks before leaving a game with unsaved changes, so save or discard when it asks. Captured sessions are kept in `~/.local/state/eax-restore-linux/profiler/`.

The full reference for every button is the [profiler README](https://github.com/tanuki2k/eax-restore-linux/blob/HEAD/tools/profiler/README.md).
