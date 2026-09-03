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

# Community-maintained database of well-known EAX games (see
# known-eax-games.json in this repo). Powers both the install-time "Heads
# up" notes and the opt-in library scanner. Fetched fresh each run so PRs
# against the file take effect without users needing a new script version;
# cached locally so a fetch failure (offline, rate-limited) degrades to the
# last-known-good copy instead of losing the feature entirely.
KNOWN_GAMES_URL="https://raw.githubusercontent.com/tanuki2k/eax-restore-linux/main/known-eax-games.json"
KNOWN_GAMES_CACHE="$BASE_SHARE/known-eax-games.json"
KNOWN_GAMES_FILE=""
KNOWN_GAMES_ATTEMPTED=""

# Set by prompt_restart_or_quit when the user, at an EAX-impossible dead end,
# chooses to go back and pick a different game rather than quit. The config
# flow's Steps 1-2 loop and the functions between it and the check
# (get_game_directory / scan_game_libraries / detect_game_environment) unwind
# on this instead of the script exiting.
RESTART_REQUESTED=""

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
