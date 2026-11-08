# Reading a game profile

A game profile is the summary the script shows for a game it recognises. It tells you what the game does with EAX, how the script will restore it, and anything you should know before you start. It comes from the [game database](game-database.md), so a game the database doesn't know has no profile.

## Where you see one

* **During an install.** Once you've picked a game that's in the database, the install shows its profile under a **GAME PROFILE** heading, so you can read it before you choose anything.
* **In the profile browser.** In the Tools menu, **Browse game profiles** opens a searchable list of every game in the database, with the profile of the highlighted game next to it. You don't need to own the game, so it's a quick way to check whether the script knows yours and what it would do. It needs `fzf`, and the script offers to install it the first time you open it.

## The details at the top

Every profile starts with a short block of facts.

| Row | What it tells you |
| --- | --- |
| Name | The game's name |
| Profile | **Tested** means someone checked the entry against a real install. **Untested** means it's in the database but nobody has checked it yet |
| Released | The date of the game's first Windows release |
| Steam ID, GOG ID | The game's ID in each store that sells it. The browser lists both when a game is sold on two stores |
| Availability | Shown when a store has delisted the game. Existing owners keep access |
| EAX Support | Which versions of EAX the game supports, for example `4.0, 5.0`. `None` means the game never had EAX, so there's nothing for the script to restore. A note beside the versions says if a later patch removed EAX, or if the game already has it built in |
| Audio API | How the game plays 3D sound: **DirectSound3D** or **OpenAL**. This decides which fix the script installs |
| Sound system | Shown for games that use the Miles Sound System |
| EAX Unified | `Yes` for a game that needs Creative's `eax.dll`. The script installs it for you |
| Audio settings, Optional settings | How many changes to the game's own settings the script can make, as described below |

When a game is sold on more than one store, the profile shows what the stores share once and what differs between them under the store's name.

## The sections underneath

Only the sections that have something to say appear.

**Description.** One sentence about the game, such as its genre and series. The browser shows it. The install doesn't.

**Status.** Appears when something about the game's EAX is worth knowing before you install. For a game with no EAX it explains why. For a game that lost EAX in a patch it says so. For a game that already has EAX built in, it says the install is optional.

**Store details.** Facts about a store's version of the game, such as which edition it is or why it was delisted.

**Restoring EAX with.** Which fix the script will use for this game, for instance OpenAL Soft.

**Audio settings.** Changes to the game's own configuration that switch on EAX or set up your speakers. The script offers these during the install. Each one is marked **tested** when someone has confirmed it works on a real install.

**Optional settings.** Fixes that aren't needed for EAX, such as a texture or graphics fix. The script offers them one at a time, only if you ask to look through them.

**Before you play.** Things you still have to do yourself after the install, like setting your receiver to Dolby Pro Logic.

**Additional steps and Notes.** Anything extra that applies to the game, such as a quirk of one edition or a setting that has to be changed inside the game.

**Suggested community patches.** Community patches that are worth using with the game. They're separate from the script and you install them yourself.

**Sources.** The pages the entry's claims come from. The names are clickable links in most terminals, and the plain address sits underneath for the rest.

## Seeing exactly what a setting changes

In the browser, press **Tab** to switch the right-hand pane from the profile to the game's settings in full. For each setting it shows why it's offered, the file it changes and where that file lives, and the exact value it would set. During an install the script shows the same rows, with the value your install has now beside the new one, before it changes anything.

The browser's other keys are listed under [Browser keys](how-it-works.md#browser-keys).

## If the game has no profile

The install still works. The script guesses whether the game uses DirectSound3D or OpenAL from its files, or asks you, and it skips the settings step because it doesn't know where the game keeps its options. [Library scanning and the game database](game-database.md#when-your-game-isnt-in-the-database) explains what happens, and [Contributing a game](contributing-games.md) shows how to add one.
