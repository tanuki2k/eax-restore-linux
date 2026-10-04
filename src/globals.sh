# --- Build Info ---
# build.sh stamps these in the assembled dist/ output from the git checkout
# (branch -> -dev suffix, HEAD commit date -> SCRIPT_DATE). The values here are
# the fallback used only when building without git (e.g. a source tarball):
# SCRIPT_VERSION is the release base, SCRIPT_DATE just needs to stay roughly
# current.
SCRIPT_VERSION="0.29"
SCRIPT_DATE="2026-08-13"

# --- Colour Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
NOTE='\033[0;94m'
NC='\033[0m'

# Collects each Warning: message emitted this run (see print_warning /
# print_warning_arrow in ui.sh) so print_run_summary can recap them right
# before a completion banner — one buried mid-scroll is otherwise easy to miss.
RUN_WARNINGS=()

# --- Yes/No Input Matching ---
# Used unquoted against =~ so bash treats these as regexes, not literal
# strings. Matches "y"/"yes" and "n"/"no" (any case) instead of just a bare
# single letter, so typing the full word doesn't silently fall through to
# whichever branch a lone "y" or "n" wasn't handling.
YES_RE='^[Yy]([Ee][Ss])?$'
NO_RE='^[Nn][Oo]?$'

# Paths
BASE_SHARE="$HOME/.local/share/eax-restore-linux"
RECENT_GAMES_FILE="$BASE_SHARE/recent_games.txt"
DSOAL_SHARE="$BASE_SHARE/dsoal"
DSOAL_OFFICIAL="$DSOAL_SHARE/official"
DSOAL_PINNED="$DSOAL_SHARE/pinned"
OPENAL_SHARE="$BASE_SHARE/openal-soft"
OPENAL_OFFICIAL="$OPENAL_SHARE/official"

# Matches exactly what winetricks' own vcrun2022 verb overrides — Wine prefers
# its own (partial, ~80%-complete) builtin implementations of these DLLs over
# native ones by default, even when the real file is sitting right there on
# disk. Without this override, a game can crash on an "unimplemented
# function" that's simply missing from Wine's builtin, despite the genuine
# DLL being correctly installed and verified present.
VCRUN_DLL_NAMES=("concrt140" "msvcp140" "msvcp140_1" "msvcp140_2" "msvcp140_atomic_wait" "msvcp140_codecvt_ids" "vcamp140" "vccorlib140" "vcomp140" "vcruntime140" "vcruntime140_1")

DSOAL_OFFICIAL_URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
DSOAL_OFFICIAL_API_URL="https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master"

# Frozen fallback, fetched only when EAX_RESTORE_DSOAL_PIN is set: one pinned
# DSOAL revision from kcat's own "archive" release tag. CI keeps re-uploading
# the newest revision's asset with a fresher OpenAL Soft, but every
# already-superseded revision is static forever — so a non-newest asset has a
# stable SHA256 and can be hard-verified, unlike the rolling latest-master
# build above. To advance the pin, bump all three of these together (pick a
# revision that is no longer the newest one in the archive release).
DSOAL_PINNED_REV="r693"
DSOAL_PINNED_URL="https://github.com/kcat/dsoal/releases/download/archive/DSOAL_r693.zip"
DSOAL_PINNED_SHA256="5abe990ff5692fa070d549a8c28df2435842c5d3f586a59b0da5281bc1cb6605"

# Community-maintained database of well-known EAX games (edited as
# data/games/<id>.json in this repo; tools/build-known-games.sh combines them
# into known-eax-games.json). Powers the install-time game details, the opt-in
# library scanner and the Game Settings step. Fetched fresh each run so PRs
# against the data take effect without users needing a new script version;
# cached locally so a fetch failure (offline, rate-limited) degrades to the
# last-known-good copy instead of losing the feature entirely.
# Schema 3 only exists on dev, so dev fetches its own branch's copy and caches
# it under its own name. Revisit when 0.29 merges into main.
KNOWN_GAMES_URL="https://raw.githubusercontent.com/tanuki2k/eax-restore-linux/dev/known-eax-games.json"
KNOWN_GAMES_CACHE="$BASE_SHARE/known-eax-games.v3.json"
KNOWN_GAMES_FILE=""
KNOWN_GAMES_ATTEMPTED=""
# Schema version this script expects. ensure_known_games_json warns once if the
# loaded copy is older (a branch that hasn't merged a schema bump yet, or a
# stale offline cache) so the silent `//` fallbacks below are visible.
KNOWN_GAMES_SCHEMA_VERSION=3
# Set by resolve_recommended_tweaks / show_game_details_block from the picked
# game's known-games entry's install.tweaks array. EAX_UNIFIED,
# RECOMMENDED_AUDIO_LIMITS, and RECOMMENDED_COM_ROUTING mirror membership of
# "eax_unified", "expand_audio_limits", and "com_registry_routing"
# respectively. The Advanced Compatibility Tweaks step reads these to
# pre-decide the EAX Unified Dummy Files / Expand Audio Limits / COM Registry
# Routing tweaks with a default-Y prompt instead of the generic default-N one.
EAX_UNIFIED=""
RECOMMENDED_AUDIO_LIMITS=""
RECOMMENDED_COM_ROUTING=""
# Set (unconditionally, once an id lookup is attempted) by
# resolve_recommended_tweaks so a caller besides show_game_details_block (i.e.
# the Advanced Compatibility Tweaks step) can tell "already resolved this run"
# apart from "resolved, but nothing was flagged" — the three flags above alone
# can't disambiguate that now that more than one of them exists.
RECOMMENDED_TWEAKS_RESOLVED=""

# Set by show_game_details_block to the known-games entry's resolved audio
# API (the same value it displays as "Audio API" in the KNOWN GAMES DATABASE block),
# "" when no match was found/shown. confirm_continue_if_openal_native reads
# this to cross-check the documented value against a live file scan instead
# of re-deriving it from scratch.
KNOWN_GAME_API=""

# Game Settings (src/game-config.sh). GAME_INSTALL_ROOT is the install folder
# the library scan matched (for "install:" config locations). The rest are
# filled in during Phase 1 and used by Phase 2, the final summary and
# uninstall: accepted alsoft.ini values, accepted config rows, settings whose
# config file doesn't exist yet, settings the player turned down, settings
# left out because this build has no such file, follow-ups for the summary,
# fixes applied, last install's CONFIG manifest lines, and (uninstall) this
# install's.
GAME_INSTALL_ROOT=""
ALSOFT_OVERRIDES=()
GAME_SETTINGS_PLAN=()
GAME_SETTINGS_MISSING=()
GAME_SETTINGS_DECLINED=()
GAME_SETTINGS_ABSENT=()
GAME_SETTINGS_FOLLOW_UPS=()
GAME_SETTINGS_APPLIED=()
# The game's audio settings this run (titles), and the ones already in place, so
# the closing steps can leave out "turn EAX on in the game" when it's done.
GAME_AUDIO_FIX_TITLES=()
GAME_AUDIO_FIX_ALREADY=()
PREV_CONFIG_LINES=()
CONFIG_LINES=()
GAME_SETTINGS_KEPT=()
# Uninstall: the game settings chosen in Phase 1 to put back in Phase 2
# (see choose_game_settings_to_revert), and whether to remove the VC++ runtime.
GAME_SETTINGS_REVERT_GROUPS=()
UNINSTALL_VCRUN="n"

# DLL override (src/launcher-config.sh). OVERRIDE_METHOD is step 10's choice:
# registry | launcher | manual. OVERRIDE_LAUNCHER / OVERRIDE_FILE / OVERRIDE_ID
# name the launcher settings it goes into (Steam localconfig.vdf + AppID, or
# Heroic GamesConfig file + app name). LAUNCHER_LINES / LAUNCHER_LINES_KEPT are
# uninstall's LAUNCHER: manifest lines and the ones left in place.
OVERRIDE_METHOD=""
# "proton" or "wine", from the Heroic game's own settings (empty when unknown).
HEROIC_RUNNER_TYPE=""
OVERRIDE_LAUNCHER=""
OVERRIDE_FILE=""
OVERRIDE_ID=""
LAUNCHER_LINES=()
LAUNCHER_LINES_KEPT=()
# Uninstall: the answer to "Close <launcher>, …?" given in Phase 1 for a
# launcher that was running then (y or n), keyed steam/heroic, so Phase 2
# doesn't ask again. Empty during install, which asks when it gets there.
declare -A LAUNCHER_CLOSE_ANSWER=()

# Set by prompt_restart_or_quit when the user, at an EAX-impossible dead end,
# chooses to go back and pick a different game rather than quit. The config
# flow's Steps 1-2 loop and the functions between it and the check
# (get_game_directory / scan_game_libraries / detect_game_environment) unwind
# on this instead of the script exiting.
RESTART_REQUESTED=""

# The main menu's install choice — scan, gui or manual — so step 1 goes
# straight to it instead of asking again. get_game_directory uses it once and
# clears it.
LOCATE_METHOD=""

# Minimal hardcoded safety net for confirm_continue_if_eax_impossible, used
# only if ensure_known_games_json can't produce a file at all (e.g. first
# run, offline, no cache yet). Keeps the "this install is a functional
# no-op" warning working even before the JSON database is ever reachable.
# AppID 70 is Half-Life, whose original DirectSound3D/EAX audio was
# permanently removed by a 2013 engine update — a safe, well-known example
# to seed the safety net with.
declare -A EAX_IMPOSSIBLE_FALLBACK_STEAM=(
    [70]=1
)
