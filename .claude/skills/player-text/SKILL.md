---
name: player-text
description: Wording rules and past corrections for any text a player reads in eax-restore-linux. Load BEFORE writing or changing any string passed to print_banner, print_step, print_status, print_detected, print_task, print_note, print_warning, print_error, print_paragraph, print_option, confirm, confirm_countdown, prompt, run_with_spinner, or a raw echo -e/printf in src/ or tools/, and before writing a game database prose field (notes, store_details, patches, eax.problem, eax.fix, description, or a setting's title, reason, follow_up) in data/games/*.json. Also load it when reviewing or rewording such text.
---

# Player-facing text

Text written in the middle of a code edit comes out describing what the code
does. Write the text as its own step, after the logic is settled, and read it
the way a player sees it.

## Before writing a string

1. **Picture the reader.** Someone running the script for the first time.
   They've never seen the code, don't know the internal names (DSOAL,
   installed.json, gog_id, "fixes" vs "settings"), and don't know which steps
   come later.
2. **Picture the screen.** Work out what's printed just above this line and
   what the player is being asked to do next. Fill in the variables (the real
   game name, the real file) and read the line in that context.
3. **Write it the way you'd say it.** Would a person say this out loud to a
   friend sitting next to them? If it reads like a log line, a label with a
   colon, or a comment from the code, rewrite it.
4. **Check it against the rules and the corrections below.** The corrections
   are the user's own rewrites of text like yours, so they're the closest
   thing to the target. Match their shape.
5. **Get a cold read.** Before handing over, run the `copy-editor` agent on
   every new or changed string (the PostToolUse hook lists them for you).
   Give it each string as the player sees it: variables filled in, the screen
   lines around it, and no code.

## When handing over

Along with the usual hand-over for testing, add a **"Text the player will see"**
list: every new or changed string, after the copy-editor pass, as plain text
with sample values filled in (not a diff). The user reviews the wording there
rather than finding it while testing.

## The rules

CLAUDE.md's "Text/output style conventions" covers *mechanics* — which helper/color to use. This covers
*wording*: the tone and voice established over many past commits for the two kinds
of prose in this repo, `game-database.json`'s free-text fields and the script's
own user-facing strings. Neither is enforceable by a linter, so match the examples
below when writing or editing either.

**Database prose fields** (`notes`, `store_details`, `patches`, `eax.problem`,
`eax.fix`, `description`, and a game setting's `title`, `reason` and `follow_up` — see README's "Contributing
to the game database" for what belongs in which field):

- Keep each field to its one job; don't restate content that belongs in a sibling
  field just because it's related to the same title.
- State the game/build fact and let the script's own output explain what it does
  with it — don't write "DSOAL", "OpenAL Soft", "paths", or "intercepts" into data
  fields.
- Frame a community patch/reimplementation as a legitimate alternative worth using,
  not an inferior fallback to apologize for (e.g. OldUnreal's OpenAL renderer).
- Write each store's `store_details`/`patches` prose to stand on its own — never
  reference "the other store's block" or "the Steam version" from within a
  different store's block, since a user only ever sees one block at a time.
- State only what's actually verified, and say exactly what was checked — avoid
  hedge words ("probably", "should") where a concrete fact is possible, and don't
  imply an install was checked locally if it wasn't. In `store_details`, `notes`,
  `patches` and `eax.problem`/`eax.fix` — shown on the game profile screen,
  above its Sources section — cite a source in parentheses when the claim is
  non-obvious, e.g. "(per PCGamingWiki)", and put its page in `sources`. Never in a
  game setting's `title`, `reason` or `follow_up` (see below).
- A game that isn't itself an Enhanced Edition, remaster or remake never
  mentions one (or a same-named remake on another store) in any field, not even
  "not the Enhanced Edition" — the player is looking at the classic. Only an
  EE/remaster entry's `notes` may point back to the classic build. The
  exception is a store that sells them as one bundle: its `store_details` may
  name every game in it, the EE/remaster included ("DOOM 3 is sold as a
  bundle with Resurrection of Evil and DOOM 3: BFG Edition.").
- Be concrete and current rather than generic — name the actual tweak label,
  mission, mod, or date — but keep each note to 1-3 sentences confined to its
  field's job; don't pad it with everything known about the title.
- `description` (browser only) is one sentence in PCGamingWiki's pattern, own
  words, starting with the entry's exact `name`: modes, perspective, genres, "in
  the <series> series" — e.g. "Thief Gold is a singleplayer first-person stealth
  and immersive sim game in the Thief series." No opinions, no EAX talk (the
  profile covers that), and nothing another field already says — what a bundle
  includes, which build it is, a delisting all belong in `store_details`/`notes`,
  an EE/remaster names the original and its year ("an enhanced edition of
  2000's Baldur's Gate II: Shadows of Amn"), a bundle its base game only when
  no other field does ("an expanded edition of Thief: The Dark Project"); an
  expansion names the game it's for ("…horror expansion for F.E.A.R.") rather
  than its series;
  leave out a mode or perspective you can't confirm. `released` is the first Windows release,
  earliest region, checked against two sources; bundles/Gold/Complete/GOTY/Classic
  take the base game's date, Enhanced Editions/Remasters/Anniversary editions
  their own; never a store's listing date.
- A `notes` entry in practice: short, plain prose (no markdown), em-dashes for
  parenthetical asides, occasionally addressing the user directly in a conditional
  ("If you also own the classic build..."), one caveat or fact per note. E.g.
  "Bloodlines isn't documented (per PCGamingWiki) as having hardware EAX... That's
  expected, not a fault."

**Game setting `title` and `reason`** (`game_config.audio_settings` / `optional_settings`).
They automate a change the player would otherwise make by hand. Players
see these in the Game Settings step, directly above rows showing each file, setting,
and its current → new value, read live from their own install.

`title`:
- A fixed verb + the result: **Enable** for a feature that's off, **Fix** for a bug,
  **Remove** for something unwanted, **Raise** for a quality level. Sentence case, no
  full stop, about 5 words at most.
- Name the result the player gets, not the setting (`Enable EAX reverb`, not
  `Set UseEAX to True`), even when the setting changes several keys — the rows list
  them.
- Reuse the same title for the same result across games.
- Don't repeat the game name; the step's header already shows it.

`reason`:
- One sentence, or two short ones: what the game does out of the box, and what that
  costs the player where it isn't obvious.
- Start with the game's name. Name concrete files the game itself uses (e.g.
  `DefOpenAL32.dll`). When the game passes over a file the script installs, name
  that file and say the script installs it ("the OpenAL32.dll this script
  installs"), but never name the script's own parts (DSOAL, OpenAL Soft).
- Be specific: never "any other" or "the other one"; name what it's chosen over
  ("loads its bundled DefOpenAL32.dll instead of the OpenAL32.dll this script
  installs").
- Don't restate setting names, values or paths already shown in the rows, and don't
  cite where a default was checked — the row's current value proves it. Never cite a
  source in a reason ("(per PCGamingWiki)" and the like): players read it at the
  Game Settings step, where they can't see or check it. A claim that needs a source
  gets its page in `sources`, which the game profile screen lists.
- Plain English for effects ("muffling of sounds through walls", not "occlusion").
  Game menu labels may be quoted when they help a player find the same option in-game.
- Only state what's verified by a real install, the game's own docs, or a source in
  `sources`.

Examples:
- `Enable EAX reverb` — "Brothers in Arms ships with EAX and 3D sound off and loads its
  bundled DefOpenAL32.dll instead of the OpenAL32.dll this script installs."
- `Enable EAX effects` — "Quake 4 ships with its EAX sound options off, so there's no
  reverb and no muffling of sounds through walls."
- `Fix low-res textures` — "Quake 4 can't detect how much memory modern graphics cards
  have, so it loads its lowest-resolution textures."
- `Enable underwater reverb` — "Some System Shock 2 maps don't mark their underwater
  areas, so they play the wrong reverb there."

**Script user-facing strings** (banners, `Note:`/`Warning:`/`Error:` messages,
prompts — see CLAUDE.md's "Text/output style conventions" for which helper/color to use):

- Prefer natural, polite, causal prose over log/debug-style boilerplate. Rewrite
  mechanical fragments into a conversational phrasing of the same information,
  e.g. `"Invalid selection. Please type 1, 2, or 3."` →
  `"That's not a valid option — please type 1, 2, or 3."`, or a bare
  `"Conflict: $(basename "$target_file")"` header → a question,
  `"What would you like to do? [B]ackup & overwrite (default), [o]verwrite, [s]kip:"`.
- Join cause and effect with a contraction and a causal "so" clause instead of two
  clipped declarative sentences, e.g.
  `"...checksum verification. This engine will be unavailable this run."` →
  `"...checksum verification, so this engine will be unavailable this run."`
- Explain jargon in plain English instead of using the internal term, e.g.
  `"installing DSOAL here would be a functional no-op"` →
  `"installing DSOAL here wouldn't do anything — there's nothing for it to hook
  into"`.
- Don't refer to steps the user hasn't reached yet or to the tools behind them
  ("the registry and winetricks steps") — someone running the script for the
  first time can't know what those are. Say what the choice means for their
  game instead, e.g. `"Use this detected runner for the registry and winetricks
  steps?"` → `"Use the same Wine version Heroic launches $GAME_NAME with?"`.
- When something the script needs doesn't exist yet — a Wine/Proton prefix, the
  launcher's saved settings for the game, a game config file it writes on first
  launch — never tell the player to finish and run the script again. Do what the
  prefix step (`src/detection.sh`) does: say what's missing and why ("If you just
  installed …, it creates … the first time it runs."), ask them to launch the game
  at least once and close it, then `confirm "Check … again?"` — Yes looks again,
  No carries on without whatever needed it.
- Name the actual subject instead of a generic stand-in wherever the variable is
  available — the real game name instead of "this edition", `$GAME_NAME`'s prefix
  instead of "this prefix".
- Trim explanatory copy down to the fact and its concrete, relatable consequence
  rather than a throat-clearing reasoning paragraph, e.g. "will silently fail to
  load the custom audio engine" → "the game will crash without showing an error
  message".
- When the script detects a problem, state the problem and offer the fix — don't
  explain what the script would otherwise fail to do. E.g. step 8's
  `"Deus Ex's reverb is quiet at the default level."` + `"Raise the reverb boost to
  +6 dB? (Y/n)"`, not a paragraph about why an unboosted reverb goes unnoticed.

## The user's corrections

Each pair below is text that was written first, followed by the user's
rewrite, taken from git history. Some "before" lines came from rules that no
longer apply; the "after" lines all follow the current rules. When writing
something similar, copy the shape of the "after".

### Script output

**Log-style messages → something a person would say**
- Before: `Invalid selection. Please type 1, 2, or 3.`
- After: `That's not a valid option — please type 1, 2, or 3.`

**Two clipped sentences → one sentence joined with "so"**
- Before: `Download failed or file was corrupt. Game database will be unavailable this run.`
- After: `The download failed or the file was corrupt, so the game database will be unavailable this run.`

**Label-and-colon headers → plain statement and a real question**
- Before: `Conflict: alsoft.ini already exists at ~/…` then `Action - [o]verwrite, [B]ackup & overwrite (default), [s]kip:`
- After: `alsoft.ini already exists at ~/…` then `What would you like to do? [o]verwrite, [b]ackup & overwrite (default), [s]kip:`

**Internal file names in status lines → what the player knows**
- Before: `Searching installed.json for matching game path (native Heroic)...`
- After: `Looking for the game in native Heroic's library...`
- Before: `Parsing GamesConfig/abc123.json for custom prefix paths...`
- After: `Reading BioShock's Heroic settings...`

**Internal IDs → the game's name**
- Before: `Game found in native Heroic! Internal ID: abc123`
- After: `Found in native Heroic's library: BioShock`

**Terse declaratives → cause and effect**
- Before: `No custom prefix defined. Checking Heroic's shared prefix...`
- After: `No prefix of its own, so checking Heroic's shared prefix...`

**Tool jargon → what's actually being installed**
- Before: `STATUS: Executing system verbs via winetricks (Silent Mode)...`
- After: `STATUS: Installing Creative's OpenAL runtime into the prefix...`
- Before: `The OpenAL package didn't install (exit code 1), so…`
- After: `Creative's OpenAL runtime didn't install (exit code 1), so…`

**Implementation details → leave them out**
- Before: `Using local known-games file (EAX_RESTORE_KNOWN_GAMES_FILE):`
- After: `Using local known-games file:`

**A vague warning and question → say what's blocked and exactly what Yes does**
- Before: `Steam is open, and it would overwrite the change when it next saves its settings.` / `Close Steam now and reopen it once that's done?`
- After: `Steam is running, so the script can't add the DLL override to Steam's launch options for BioShock.` / `Close Steam, add the override, then reopen Steam?`

**Long preamble on a yes/no question → ask it directly**
- Before: `Would you like the script to attempt to automatically find the game's prefix?`
- After: `Find BioShock's prefix automatically?`

**A hedged caveat and an "Understood?" (Y/n) → the fact, the way out, and a Y/n that names what they agree to**
- Before: `Note: the game database is a small, hand-verified, work-in-progress set — it doesn't cover every EAX game. A game you own may still support EAX even if it's not (yet) listed.` / `Understood — it's a work in progress? (Y/n)`
- Then: `Note: the scan only finds games in the game database, which is still growing. If your game isn't listed, it may still have EAX — choose [M] under the list to type its path yourself.` / `Press Enter to scan your libraries, or type B to go back:`
- After: `Note: the game database is a work in progress, so the scan only finds the games added so far. If your game isn't listed, it may still have EAX — choose [M] under the list to type its path yourself.` / `Scan your libraries, knowing the game database is a work in progress? (Y/n)`
  The player has to agree that the database is a work in progress before the
  scan, so keep it a Y/n with those words in it, not "press Enter to carry on".

**One long sentence listing every answer → a short question and one row per answer**
- Before: `Press Enter to remove all of these, or type the numbers of just the ones you want (e.g. "1 2 3", "1-3", or "^4" to remove everything except 4), or 'n' to keep them:`
- After: `Which files should be removed?` / `  Enter      remove all of them` / `  1 2 3      remove only these (or a range: 1-3)` / `  ^2         remove all except 2` / `  n          keep them all`
  With one file there's nothing to pick from, so it names that file instead: `Should this file be removed?` / `  Enter      remove it` / `  n          keep it`

**"Run the script again" → launch the game and check again**
- Before: `Quake 4 creates Quake4Config.cfg the first time it runs, so launch it once and run this again to apply this setting.`
- After: `Note: Quake 4 hasn't created Quake4Config.cfg yet.` / `If you just installed Quake 4, it creates Quake4Config.cfg the first time it runs. Please launch the game at least once, close it, and try again.` / `Check for Quake4Config.cfg again?`

**A paragraph of explanation → the fact on its own**
- Before: `This NTFS drive is mounted read-only. That usually means Windows didn't fully shut down (Fast Startup or hibernation left the drive marked as in use), so Linux refuses to write to it. Boot into Windows and use Shut Down while holding Shift (or turn off Fast Startup in Power Options), then remount the drive and re-run.`
- After: `Windows didn't fully shut down (Fast Startup or hibernation), so Linux mounted this drive read-only.`

**Internal terms in headers → the player's terms**
- Before: `Recommended audio settings for Quake 4:` / `Optional fixes for Quake 4 — not needed for EAX:`
- After: `Audio settings for Quake 4:` / `Optional settings for Quake 4 — not needed for EAX:`

### Game database prose

**Setting `reason`: no source citations**
- Before: `Quake 4 can't detect how much memory modern graphics cards have, so it loads its lowest-resolution textures (per PCGamingWiki).`
- After: `Quake 4 can't detect how much memory modern graphics cards have, so it loads its lowest-resolution textures.`

**`eax.problem`: technical history → the plain fact**
- Before: `The Enhanced Edition runs on a from-scratch OpenAL engine, built for its native Linux and macOS ports — it never had DirectSound3D EAX to begin with.`
- After: `This is the Enhanced Edition, not the classic Baldur's Gate, and it has no EAX.`

**`notes`: database internals → what the player can buy**
- Before: `If you also own the classic build, it's a separate GOG product the scanner detects on its own — see the 'Baldur's Gate: The Original Saga' entry (gog_id 1207658886), which has real DirectSound3D EAX.`
- After: `If you also own the classic Baldur's Gate, it's a separate GOG purchase, 'Baldur's Gate: The Original Saga', and that one has EAX.`

**`store_details`: no bookkeeping, no remaster on a classic entry**
- Before: `The original 2007 game, not 2016's 'BioShock Remastered'. GOG sells only the Remastered version, so no gog id is set here.`
- After: `This is the original 2007 BioShock, an ideal candidate for restoring EAX sound.`

**`store_details`: store mechanics → what the player is looking at**
- Before: `The classic pre-2017 build, sold by GOG as a standalone product separate from 'Planescape: Torment: Enhanced Edition'. GOG's catalogue search doesn't surface it, but the product page and existing owners' libraries resolve normally.`
- After: `This is the original 1999 Planescape: Torment. GOG stopped selling it on its own in April 2017 (per GOG's forums), but it's still an ideal candidate for restoring EAX sound.`

**`store_details`: each store's text stands on its own**
- Before: `Square Enix removed the Steam version from sale in February 2021 and has said it has no plans to restore it. The GOG release is unaffected.`
- After: `Square Enix removed it from sale on Steam in February 2021 and has said it has no plans to restore it.`

**`store_details`: say what's sold, not how it's installed**
- Before: `Comes only with the 'DOOM 3' purchase, together with Resurrection of Evil, which Steam lists as a separate game but installs into this folder and runs from the same exe.`
- After: `DOOM 3 is sold as a bundle with Resurrection of Evil and DOOM 3: BFG Edition. Steam lists Resurrection of Evil as its own game.`

**Same fact, same words across games**
- Before: `Delisted from Steam in December 2022, along with the rest of the Unreal series.`
- After: `Delisted in December 2022, when Epic pulled the entire classic Unreal series from sale.`

**The user's preferred `reason` style: name the files**
- `Brothers in Arms ships with EAX and 3D sound off and loads its bundled DefOpenAL32.dll instead of the OpenAL32.dll this script installs.`
  Concrete file names are wanted. Don't swap them for a vague plain-language
  version ("uses its own audio library").

## Adding to this list

When the user rewords text, add the before → after pair here under the
matching heading (or a new one), with a one-line heading saying what was
wrong.
