# Shared jq helpers for the game database tooling (data/games/*.json).
# Used by tools/format-game-database.sh, tools/build-game-database.sh and the
# one-off tools/migrate-v2-to-v3.sh via `jq -L tools 'include "game-database"; ...'`.

# Rebuilds an object with the listed keys first, in that order, followed by
# any other keys in their existing order (the schema rejects unknown keys, so
# those only survive long enough to fail validation with a clear message).
def order_keys($keys):
    . as $o
    | ([$keys[] | select(. as $k | $o | has($k))] + [keys_unsorted[] | select(. as $k | $keys | index($k) | not)]) as $ks
    | reduce $ks[] as $k ({}; .[$k] = $o[$k]);

# Drops keys whose value is null, an empty array or an empty object — the
# "omit when empty" rule. Never applied to a fix's `changes`, where null means
# "delete this key from the game's config file".
def drop_empty:
    with_entries(select(.value != null and .value != [] and .value != {}));

def normalize_store:
    drop_empty
    | if .delisted == false then del(.delisted) else . end
    | if .id_source == "storefront_verified" then del(.id_source) else . end
    | order_keys(["id", "delisted", "id_source", "api", "beta_branch", "extra_exe_folders", "store_details", "patches"]);

def normalize_eax:
    drop_empty
    | if .status == "supported" then del(.status) else . end
    | if .fix_in_place == false then del(.fix_in_place) else . end
    | order_keys(["api", "versions", "status", "problem", "fix", "fix_in_place"]);

def normalize_install:
    drop_empty | order_keys(["tweaks", "alsoft_ini"]);

def normalize_fix:
    (.changes // {}) as $changes
    | del(.changes) | drop_empty
    | if .only_if then .only_if |= (drop_empty | order_keys(["stores", "speakers"])) else . end
    | .changes = $changes
    | order_keys(["title", "reason", "only_if", "changes", "follow_up"]);

def normalize_game_config:
    drop_empty
    | if .files then .files |= map_values(drop_empty | order_keys(["format", "locations", "if_missing"])) else . end
    | if .audio_fixes then .audio_fixes |= map(normalize_fix) else . end
    | if .extra_fixes then .extra_fixes |= map(normalize_fix) else . end
    | order_keys(["files", "audio_fixes", "extra_fixes"]);

def normalize_game:
    (if .stores then .stores |= (map_values(normalize_store) | order_keys(["steam", "gog"])) else . end)
    | (if .eax then .eax |= normalize_eax else . end)
    | (if .install then .install |= normalize_install else . end)
    | (if .game_config then .game_config |= normalize_game_config else . end)
    | drop_empty
    | order_keys(["$schema", "name", "exe", "stores", "eax", "install", "game_config", "sources", "notes"]);

# One-line rendering with spaces inside braces: { "id": 6910 }, ["1.0", "2.0"].
def compact:
    if type == "object" then
        if length == 0 then "{}"
        else "{ " + ([to_entries[] | (.key | tojson) + ": " + (.value | compact)] | join(", ")) + " }" end
    elif type == "array" then "[" + (map(compact) | join(", ")) + "]"
    else tojson end;

# Pretty-prints with 2-space indents, but keeps an object/array on one line when
# it fits within 100 columns at its position. $force makes this level
# multi-line regardless (used for the game object and its larger blocks).
def render($indent; $prefix_len; $force):
    if (type == "object" or type == "array") and length > 0
       and ($force or (($indent | length) + $prefix_len + (compact | length) > 100)) then
        ($indent + "  ") as $inner
        | if type == "object" then
            "{\n" + ([to_entries[] | (.key | tojson) as $k
                | $inner + $k + ": " + (.value | render($inner; ($k | length) + 2; false))] | join(",\n"))
            + "\n" + $indent + "}"
          else
            "[\n" + (map($inner + render($inner; 0; false)) | join(",\n")) + "\n" + $indent + "]"
          end
    else compact end;

# A whole game file: the game object and its stores / install / game_config
# blocks are always multi-line so every file reads the same way.
def render_game:
    "{\n" + ([to_entries[] | .key as $key | ($key | tojson) as $k
        | "  " + $k + ": " + (.value | render("  "; ($k | length) + 2;
            ($key == "stores" or $key == "install" or $key == "game_config")))] | join(",\n"))
    + "\n}";
