#!/usr/bin/env bash
# One-off: splits the v2 game-database.json (one big file, schema_version 2)
# into v3 per-game files under data/games/, renaming fields to the v3 names and
# dropping empty/default values. Kept in the repo for reference; not part of
# the normal build.
#
# Usage: tools/migrate-v2-to-v3.sh [path/to/v2.json]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

src="${1:-game-database.json}"
jq -e '.schema_version == 2' "$src" >/dev/null || { echo "$src isn't a schema_version 2 file" >&2; exit 1; }

mkdir -p data/games

# Emits two lines per game: the id, then the v3 game as one line of JSON. The
# id is a kebab-case slug of the name ("&" -> "and", apostrophes/dots dropped,
# anything else non-alphanumeric -> "-").
jq -r -L tools 'include "game-database";
    def slug: ascii_downcase | gsub("&"; " and ") | gsub("['\''’.]"; "") | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-");
    .games[] | (.name | slug), ({
            "$schema": "../schema.json",
            name,
            exe: ([.stores[].exe_path // empty | split("/") | last] | first),
            stores: (.stores | map_values({
                id,
                delisted: (.listing == "delisted"),
                id_source: .id_confidence,
                api, beta_branch, store_details, patches
            })),
            eax: {
                api: .default_api,
                versions: .eax_versions,
                status: .eax_status,
                problem: .eax_status_details,
                fix: .restore_details,
                fix_in_place: .build_workaround_available
            },
            install: { tweaks: .recommended_tweaks },
            notes
        } | normalize_game | tojson)' "$src" |
while IFS= read -r id && IFS= read -r game; do
    out="data/games/$id.json"
    [ -e "$out" ] && { echo "Duplicate id: $id" >&2; exit 1; }
    printf '%s' "$game" | jq -r -L tools 'include "game-database"; render_game' > "$out"
done

echo "Wrote $(ls data/games/*.json | wc -l) game files to data/games/"
