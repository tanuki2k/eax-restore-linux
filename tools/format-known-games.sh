#!/usr/bin/env bash
# Rewrites every game file (data/games/tested, data/games/untested, data/drafts)
# into canonical form: fixed key order, empty and default-valued fields dropped,
# short objects/arrays kept on one line. Also points each file's "$schema" at
# data/schema.json from wherever the file sits, so moving a game between
# folders only needs a re-run of this.
#
# Usage: tools/format-known-games.sh           # rewrite files in place
#        tools/format-known-games.sh --check   # exit 1 (listing files) if any would change
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

check=0
[ "${1:-}" == "--check" ] && check=1

shopt -s nullglob
unformatted=()
for f in data/games/tested/*.json data/games/untested/*.json data/drafts/*.json; do
    case "$f" in
        data/games/*) schema="../../schema.json" ;;
        *) schema="../schema.json" ;;
    esac
    formatted="$(jq -r -L tools --arg schema "$schema" 'include "known-games"; .["$schema"] = $schema | normalize_game | render_game' "$f")"
    if [ "$formatted" != "$(cat "$f")" ]; then
        if [ "$check" -eq 1 ]; then
            unformatted+=("$f")
        else
            printf '%s\n' "$formatted" > "$f"
        fi
    fi
done

if [ "$check" -eq 1 ] && [ ${#unformatted[@]} -gt 0 ]; then
    echo "These game files aren't in canonical form (run tools/format-known-games.sh):" >&2
    printf '  %s\n' "${unformatted[@]}" >&2
    exit 1
fi
