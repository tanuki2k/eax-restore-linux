#!/usr/bin/env bash
# Builds the single known-eax-games.json the script downloads from the per-game
# files in data/games/tested/ and data/games/untested/. data/drafts/ is never
# built. Never hand-edit known-eax-games.json — edit the game's <id>.json and
# re-run this.
#
# Each game gets an "id" (its file name without .json); the "$schema" editor
# hint is dropped. Also checks what data/schema.json can't express: every file
# a fix changes must be defined in that game's game_config.files.
#
# Usage: tools/build-known-games.sh           # write known-eax-games.json
#        tools/build-known-games.sh --check   # exit 1 if the committed file is out of date
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

check=0
[ "${1:-}" == "--check" ] && check=1

shopt -s nullglob
game_files=(data/games/tested/*.json data/games/untested/*.json)
all_files=("${game_files[@]}" data/drafts/*.json)

# A game lives in exactly one folder; its file name is its id.
dupes="$(for f in "${all_files[@]}"; do basename "$f"; done | sort | uniq -d)"
if [ -n "$dupes" ]; then
    echo "These games are in more than one of data/games/tested, data/games/untested and data/drafts — keep one copy:" >&2
    printf '  %s\n' $dupes >&2
    exit 1
fi

errors="$(for f in "${all_files[@]}"; do
    jq -r --arg f "$f" '
        (.game_config.files // {} | keys) as $defined
        | (.game_config.audio_settings // []) + (.game_config.optional_settings // [])
        | .[] | .title as $title | .changes | keys[]
        | select(. as $file | $defined | index($file) | not)
        | "\($f): \"\($title)\" changes \(.), which isn'\''t defined in game_config.files"' "$f"
done)"
if [ -n "$errors" ]; then
    printf '%s\n' "$errors" >&2
    exit 1
fi

built="$(for f in "${game_files[@]}"; do
    jq --arg id "$(basename "$f" .json)" '{ id: $id } + del(.["$schema"])' "$f"
done | jq -s '{
    schema_version: 3,
    _readme: "Generated from data/games/tested/*.json and data/games/untested/*.json by tools/build-known-games.sh; do not edit by hand. Field reference: data/schema.json and README.md, \"Contributing to the known games database\".",
    games: sort_by(.name | ascii_downcase)
}')"

if [ "$check" -eq 1 ]; then
    if [ "$built" != "$(cat known-eax-games.json)" ]; then
        echo "known-eax-games.json is out of date — run tools/build-known-games.sh and commit the result." >&2
        exit 1
    fi
else
    printf '%s\n' "$built" > known-eax-games.json
fi
