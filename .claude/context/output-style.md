# Text/output style conventions

Moved out of CLAUDE.md so it isn't loaded into every session; CLAUDE.md says when to read it.

All user-facing output goes through `echo -e` with the colour vars defined in
`globals.sh` (`GREEN`, `YELLOW`, `CYAN`, `WHITE`, `BOLD`, `DIM`, `NOTE`, reset via
`NC`) — there's no other formatting mechanism (no `tput`, no external color library).
The recurring shapes built from those vars — banners, prompts, arrow sub-steps,
Note:/Warning:/Error: messages, wrapped prose — are centralized as helper functions in
`ui.sh`; **use the helper for any of the shapes below instead of hand-rolling the
`echo -e` sequence.** Preflight through Phase 1 step 3, "Launcher Identification",
(`preflight.sh`, `config-flow.sh` header/steps, `get_game_directory`/
`detect_game_environment` in `detection.sh`) is the canonical example of the helpers
in use — match its look when extending any of these flows. The rest of the script is
still being migrated onto these helpers incrementally; a raw `echo -e "...${COLOR}"`
call site elsewhere in `src/` is a pre-migration leftover, not a second sanctioned
style — convert it to the matching helper when you touch it, rather than copying it
for a new call site.

- `print_banner "LABEL" [COLOR=GREEN]` — the `--- LABEL ---` section banner (blank
  line, divider, bold label, divider, blank line), e.g. `--- PHASE 1: CONFIGURATION ---`,
  `--- GAME PROFILE ---`.
- `print_step N "Label"` — the same banner wrapper for a numbered, non-dashed,
  non-bold CYAN sub-step header, e.g. `2. Launcher Identification`. A flow sets
  `STEP_TOTAL` first to get `N/TOTAL.` headers.
- `print_result "text" [COLOR]` — the blank-line-led first line of a component;
  `print_subheading "Label"` is the `Label:` header above a `print_wrapped` body;
  `print_paragraph "line" ...` prints already-wrapped prose lines;
  `print_key_option` is `print_option` for letter keys; `print_phase_task` is
  `print_task` under the phase progress bar; `run_with_spinner` and
  `fetch_with_progress` wrap a slow command or download; `tool_gate` is a Tools
  item's opening "Continue?"; `print_run_summary` closes a run.
- `print_status "text" [COLOR=CYAN]` — an ` -> ` arrow sub-step/result line.
- `print_detected "Label" "value"` — the ` -> Label: value` line (label in GREEN)
  reporting what auto-detection found, right before the `confirm` asking whether
  to use it, e.g. `Detected Prefix:`, `Detected Architecture:`.
- `print_final_step N "Label:" "text"` — one numbered line of INSTALLATION COMPLETE's
  "Final Steps to activate EAX": bold yellow label, text wrapped at 72 columns (`WRAP_COLUMNS` less 4) with
  the continuation lined up under the label.
- `print_titled_box <colour> "Title" "line" ...` — a rounded frame as wide as the
  dividers with the title in its top edge and the lines left-aligned (already
  wrapped to 54 columns): a callout for something the player still has to do, e.g.
  the install's "Before you play" box of settings' follow-ups. `print_centred_box`
  is its centred counterpart (the end-of-run log box).
- `print_task "text"` — the `\n${CYAN}STATUS: text...${NC}` header announcing a chunk
  of work about to run (a scan, a download, a deploy step). Own leading blank line;
  the trailing `...` is added by the helper, so pass just the phrase. A capturing
  call site redirects itself (`print_task "..." >&2`).
- `print_note "text" ["more text" ...]` / `print_warning "..."` / `print_error "..."`
  — standalone-paragraph `Note:`/`Warning:`/`Error:` messages (each argument is one
  already-wrapped physical line; the helper colors and joins them without
  reflowing). `print_note_arrow`/`print_warning_arrow`/`print_error_arrow` are the
  ` -> `-prefixed inline sub-step forms of the same three. These standalone forms
  always emit their own leading blank line, which is exactly the one blank line of
  separation wanted after a `print_banner`/`print_step` header (those no longer emit
  a trailing blank of their own) — so a `Note:`/`Warning:`/`Error:` message right
  after a step header uses the helper directly, same as anywhere else.
- `confirm "Question?" [default=Y|N]` — the two-line `(Y/n)`/`(y/N)` prompt (question
  line, then a separate `"> "` read line), returns 0/1. Only for actual yes/no
  confirms.
- `confirm_countdown "Question?" [default=Y|N] [seconds=25]` — `confirm` that
  counts down on the `"> "` line (`(Yes in 25s)`) and takes the default when
  nothing is typed, setting `CONFIRM_TIMED_OUT=1` so the caller can say so. Only
  for a default that's safe to act on unattended (closing a launcher with no
  game running, in `offer_close_launcher`).
  Non-tty input falls back to plain `confirm`.
- `prompt "question text: "` — the non-yes/no counterpart of `confirm`: a leading
  blank line, the `${YELLOW}` question line, then the separate `"> "` read line — but
  **no `read`**, because these call sites need the raw typed value (menu numbers,
  free-text paths) and loop on their own validation. The caller still writes its own
  `read_answer VAR` right after. (Hand-rolled `(y/N)` prompts that predate `confirm` are
  a separate migration — leave those for a dedicated pass.)
- `read_answer VAR` — use instead of a bare `read -r VAR` for every user answer
  (prompts, menus, free-text paths). The terminal's own echo of typed keys never
  reaches the run log, so this replays the answer into it (see its comment in
  `ui.sh`); a bare `read -r` leaves the answer out of bug-report logs.
- `print_option N "Label" ["dim detail"]` — one ` N) Label` row of a numbered
  selection menu, plain/uncolored (the sanctioned menu-row look — don't wrap rows in
  `${WHITE}`, which renders bold). An optional third arg is appended as a
  de-emphasized ` detail` in `DIM` (e.g. `in /path/to/dir`, `(Steam)`). The caller
  still owns the menu's `${WHITE}` header line, its leading/trailing blank lines, and
  the `${YELLOW}` `Selection [...]:` prompt + `read_answer` loop.
- `print_link "title" "url"` — the way to print a URL: the title as a clickable
  terminal link (OSC 8), with the plain address dimmed under it (an empty title
  prints just the address). Konsole ignores OSC 8 links unless its profile allows
  them, but every terminal opens a plain address it can see, so a URL the player
  needs is always printed in full. `term_link url text` is the low-level link for
  inside another line (the end-of-run box); a caller using it prints the plain
  address itself. Never hand-write an OSC 8 sequence. The run log keeps just the
  link text.
- `tilde_path "text"` — shortens every `$HOME/...` path in the text to `~/...` for
  display. Every helper above and below already runs its text through it, so only a
  raw `echo -e`/`printf` that prints a path needs to call it itself
  (`"$(tilde_path "$GAME_DIR")"`). Display only — keep the real path in variables.
- `print_wrapped "free text"` — wraps data-sourced prose (e.g. the `notes` field in
  `game-database.json`, not already hand-wrapped script text) at 76 columns
  (`WRAP_COLUMNS` overrides it, for the browser's narrower preview) and
  indents it, in WHITE (`WRAP_COLOUR` overrides it; empty is the terminal's
  normal-weight text, which the browser's profile uses for its paragraphs). Don't hardcode line breaks into stored data just to wrap
  it; wrap at render time instead. A break the writer meant (a new line or
  paragraph) is kept: the database readers (`gdb_fields`,
  `load_game_config_rows`) carry it as `\x1e` so a record stays one line, and
  `wrap_text <width> <indent> "text"` (which `print_wrapped` uses) turns it back.
  Wrap database prose with `wrap_text`, never a bare `fold`.

Color meaning, unchanged by the helpers:

- `CYAN` — section headers and "in progress" status lines (e.g. `Checking ...`).
- `GREEN` — success (`Done.`, `Up to date [...]`, `Loaded (...)`.).
- `YELLOW` (always bold — the var itself carries `\033[1;33m`) — warnings, errors, and
  every `(Y/n)`/`(y/N)` prompt. Reserved for things that want the user's attention;
  don't use it for routine/expected branching (that's `NOTE`, below).
- `Error: ` (`YELLOW`) prefixes a message where something the script tried genuinely
  failed and there's no further fallback left for that capability this run (a required
  download/verification fails with no usable cache, a hard dependency is missing,
  etc.).
- `Warning: ` is always bold YELLOW, in both its standalone-paragraph form (gating a
  following `(y/N)`/`(Y/n)` prompt, e.g. "No .exe files were found...") and its
  inline ` -> `-prefixed arrow sub-step form — `print_warning`/`print_warning_arrow`
  keep the two visually identical on purpose.
- `Note: ` (`NOTE`, a dedicated bright-blue, non-bold color — deliberately not in the
  `YELLOW` family) prefixes a routine "the preferred path wasn't available, here's the
  automatic fallback" notice — distinct from `Warning:`/`Error:` (something to flag or
  that failed) and from the `YELLOW` `(Y/n)` prompts themselves: nothing is broken,
  this is expected, ordinary branching (e.g. the game database being
  unavailable and falling back to manual entry, or reusing a stale cache while
  offline).
- `WHITE` — general prose/body text and prompts.
- `DIM` — secondary/de-emphasized text, e.g. supplementary detail alongside a primary
  status line.
- Diagnostic/warning output that shouldn't pollute stdout capture is sent to stderr
  by redirecting the call site itself (`print_status "..." >&2`, or a raw
  `echo -e ... >&2`) — used throughout `ensure_game_database`,
  `detect_heroic_prefix_verbose`, and similar functions whose own stdout is captured
  via `$(...)`. The helpers themselves always write to stdout; there's no separate
  `_err` helper family.
- Inline comments favor explaining *why* a non-obvious choice was made (e.g. why a
  cache is preserved on failure, why a check is memoized) over restating *what* the
  next line does — follow that tone when adding comments.

## Writing style conventions

The wording rules for any text a player reads (script output and game database
prose), plus the user's past corrections, are in the `player-text` skill
(`.claude/skills/player-text/SKILL.md`). **Load it before writing or changing
any such string**, and run the `copy-editor` agent on new or changed text before
handing over. A PostToolUse hook lists the changed strings after each edit.
