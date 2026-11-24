#!/usr/bin/env bash
# The maintainer's list of games they own (data/owned.json), for keeping track
# of which database games are in their own library. It's committed but never
# built into game-database.json, so players never see it.
#
# Usage: tools/owned.sh                 # games you own, with their compatibility
#        tools/owned.sh --not-owned     # games in the database you don't own
#        tools/owned.sh add <id>...     # mark games as owned (the file name without .json)
#        tools/owned.sh remove <id>...  # unmark them
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

list=data/owned.json
[ -f "$list" ] || echo '[]' > "$list"

game_file() {
    if [ -f "data/games/$1.json" ]; then echo "data/games/$1.json"
    elif [ -f "data/drafts/$1.json" ]; then echo "data/drafts/$1.json"
    fi
}

# One line per game: its compatibility, then its name and id.
show() {
    local id f
    while read -r id; do
        f="$(game_file "$id")"
        if [ -z "$f" ]; then
            printf '%-12s %s (no game file)\n' "?" "$id"
        elif [[ "$f" == data/drafts/* ]]; then
            printf '%-12s %s (%s)\n' "draft" "$(jq -r .name "$f")" "$id"
        else
            printf '%-12s %s (%s)\n' "$(jq -r '.compatibility // "unknown"' "$f")" "$(jq -r .name "$f")" "$id"
        fi
    done
}

case "${1:-}" in
    "")
        jq -r '.[]' "$list" | show
        echo "$(jq length "$list") games owned."
        ;;
    --not-owned)
        for f in data/games/*.json; do basename "$f" .json; done \
            | grep -vxF -f <(jq -r '.[]' "$list") | show || true
        ;;
    add|remove)
        action="$1"; shift
        [ $# -gt 0 ] || { echo "Give the game's id (its file name without .json)." >&2; exit 1; }
        for id in "$@"; do
            if [ "$action" == "add" ] && [ -z "$(game_file "$id")" ]; then
                echo "There's no data/games/$id.json or data/drafts/$id.json, so $id wasn't added." >&2
                exit 1
            fi
        done
        ids="$(printf '%s\n' "$@" | jq -R . | jq -s .)"
        if [ "$action" == "add" ]; then
            jq --argjson ids "$ids" '(. + $ids) | unique' "$list" > "$list.new"
        else
            jq --argjson ids "$ids" '. - $ids' "$list" > "$list.new"
        fi
        mv "$list.new" "$list"
        echo "Done. $(jq length "$list") games owned."
        ;;
    *)
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
        exit 1
        ;;
esac
