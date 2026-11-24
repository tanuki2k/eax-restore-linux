# Shared jq helpers for the game database tooling (data/games/*.json).
# Used by tools/format-game-database.sh and tools/build-game-database.sh.

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
    | order_keys(["id", "delisted", "id_source", "compatibility", "problem", "api", "beta_branch", "rollback_builds", "rollback_steps", "extra_exe_folders", "companion_apps", "store_details", "patches"]);

def normalize_eax:
    drop_empty
    | if .built_in == false then del(.built_in) else . end
    | order_keys(["api", "sound_system", "versions", "built_in", "problem", "fix"]);

def normalize_install:
    drop_empty
    | order_keys(["tweaks", "alsoft_ini", "alsoft_verified"]);

def normalize_fix:
    (.changes // {}) as $changes
    | del(.changes) | drop_empty
    | if .only_if then .only_if |= (drop_empty | order_keys(["stores", "speakers"])) else . end
    | .changes = $changes
    | order_keys(["title", "reason", "only_if", "changes", "follow_up", "verified"]);

def normalize_game_config:
    drop_empty
    | if .files then .files |= map_values(drop_empty | order_keys(["format", "locations", "all_locations", "if_missing"])) else . end
    | if .audio_settings then .audio_settings |= map(normalize_fix) else . end
    | if .optional_settings then .optional_settings |= map(normalize_fix) else . end
    | order_keys(["files", "audio_settings", "optional_settings"]);

def normalize_game:
    (if .stores then .stores |= (map_values(normalize_store) | order_keys(["steam", "gog"])) else . end)
    | (if .eax then .eax |= normalize_eax else . end)
    | (if .install then .install |= normalize_install else . end)
    | (if .game_config then .game_config |= normalize_game_config else . end)
    | drop_empty
    | order_keys(["$schema", "name", "description", "released", "exe", "compatibility", "stores", "eax", "install", "game_config", "sources", "notes"]);

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

# A store's compatibility: its own, else the game's, else unknown (nobody has
# checked it).
def store_compatibility($game):
    .compatibility // $game.compatibility // "unknown";

# The store can roll back to a build that keeps EAX.
def has_rollback:
    (.beta_branch // "") != "" or ((.rollback_builds // []) | length) > 0;

# The fields scripts released before the compatibility field read, worked out
# from the new ones: the game's tested flag, eax.status and eax.fix_in_place,
# and each setting's tested and install.alsoft_tested. Drop this once no
# released script reads them (see .claude/context/release.md).
def legacy_fields:
    . as $g
    | ([.stores[] | store_compatibility($g)]) as $per_store
    | (if all($per_store[]; . == "unknown") then .tested = false else . end)
    | (if .compatibility == "unsupported" then
           .eax.status = (if ((.eax.versions // []) | length) > 0 then "removed_by_patch" else "not_implemented" end)
       elif .eax.built_in == true then .eax.status = "built_in"
       elif any(.stores[]; has_rollback) then .eax.status = "removed_by_patch" | .eax.fix_in_place = true
       else . end)
    | (if .install.alsoft_verified == true then .install.alsoft_tested = true else . end)
    | (if .game_config then
           .game_config |= (
               (if .audio_settings then .audio_settings |= map(if .verified == true then .tested = true else . end) else . end)
               | (if .optional_settings then .optional_settings |= map(if .verified == true then .tested = true else . end) else . end))
       else . end);

# One game's entry in game-database.json: its id and file (minus the editor's
# "$schema" hint), each store's compatibility and problem worked out so readers
# never have to fall back from store to game themselves, and the legacy fields.
def built_entry($id):
    del(.["$schema"]) as $g
    | { id: $id } + $g
    | .stores |= map_values(
        .compatibility = store_compatibility($g)
        | (.problem // $g.eax.problem) as $p | if $p then .problem = $p else . end)
    | legacy_fields;

# A built game-database.json with this entry added, or replacing the one with
# the same id, sorted the way tools/build-game-database.sh sorts it. How the
# profile editor adds one submitted game without rebuilding from its own files.
def splice_entry($entry):
    .games |= ((map(select(.id != $entry.id)) + [$entry]) | sort_by(.name | ascii_downcase));
