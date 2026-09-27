#!/usr/bin/env bash
# Rewrites data/games/*.json into canonical form: fixed key order, empty and
# default-valued fields dropped, short objects/arrays kept on one line.
#
# Usage: tools/format-known-games.sh           # rewrite files in place
#        tools/format-known-games.sh --check   # exit 1 (listing files) if any would change
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

check=0
[ "${1:-}" == "--check" ] && check=1

unformatted=()
for f in data/games/*.json; do
    formatted="$(jq -r -L tools 'include "known-games"; normalize_game | render_game' "$f")"
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
