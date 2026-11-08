#!/usr/bin/env bash
# Dev helper: browse the game database the way players see it. The game list
# on the left (fuzzy search: type any part of a name, or "gog"/"steam"), and
# the selected game's GAME PROFILE on the right, drawn by the script's own
# print_game_profile from src/. Same browser as the script's Tools → [B]rowse
# game profiles. Not part of the shipped script.
#
# Usage: tools/browse-game-database.sh [database.json]
#            Default: the repo's game-database.json. Run
#            tools/build-game-database.sh first to see edits to
#            data/games/*.json.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

for cmd in fzf jq; do
    command -v "$cmd" > /dev/null || { echo "$cmd isn't installed." >&2; exit 1; }
done
database="$(realpath "${1:-game-database.json}")"
[ -f "$database" ] || { echo "No such file: $database" >&2; exit 1; }

# Function and variable definitions only; nothing in these runs on load.
set +u
for f in globals ui common game-database game-config; do
    # shellcheck source=/dev/null
    source "src/$f.sh"
done
# After globals.sh, which sets it empty.
GAME_DATABASE_FILE="$database"
fzf_at_least 0.35 || { echo "The browser needs fzf 0.35 or newer; this is $(fzf --version)." >&2; exit 1; }
browse_game_database
