# --- Build Info ---
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
DSOAL_COMMUNITY_V13="$DSOAL_SHARE/community_v1.3"
DSOAL_COMMUNITY_V14="$DSOAL_SHARE/community_v1.4"
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
DSOAL_COMMUNITY_V13_URL="https://github.com/ThreeDeeJay/dsoal/releases/download/0.9.6/DSOAL+HRTF.zip"
DSOAL_COMMUNITY_V13_SHA256="271db46cffb086ffc0af06956ade3ee8e645e05fb108b5b6d1f74b733ecaf984"
# PCGamingWiki blocks automated/bot downloads from their site, so this build is
# re-hosted on our own GitHub release. The pinned SHA256 verifies the mirrored
# file matches what we uploaded; bump it whenever the mirrored zip is updated.
DSOAL_COMMUNITY_V14_URL="https://github.com/tanuki2k/eax-restore-linux/releases/download/assets/DSOALv1.4.zip"
DSOAL_COMMUNITY_V14_SHA256="064f600eac5637d8a8ea6b6cd0172b42202b792406530bf867c0144e722e7414"

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

# Minimal hardcoded safety net for confirm_continue_if_eax_impossible, used
# only if ensure_known_games_json can't produce a file at all (e.g. first
# run, offline, no cache yet). Keeps the "this install is a functional
# no-op" warning working even before the JSON database is ever reachable.
declare -A EAX_IMPOSSIBLE_FALLBACK_STEAM=(
    [70]=1
)
