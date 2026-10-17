#!/usr/bin/env bats
# The database browser's tested / untested filter: the key's cycle and which
# games each setting lists.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    cat > "$GAME_DATABASE_FILE" <<'JSON'
{"schema_version":3,"games":[
 {"id":"alpha","name":"Alpha","stores":{"steam":{"id":1}},"eax":{"api":"directsound3d"}},
 {"id":"beta","name":"Beta","stores":{"steam":{"id":2}},"eax":{"api":"openal"},"tested":false},
 {"id":"gamma","name":"Gamma","stores":{"gog":{"id":3}},"eax":{"api":"openal"},"tested":false}
]}
JSON
    STATE="$BATS_TEST_TMPDIR/state"
}

listed() { browse_game_stores "$STATE" | cut -f1 | paste -sd,; }

@test "the browser opens on tested games only" {
    echo "all all profile 0 match side side tested" > "$STATE"
    [ "$(listed)" == "alpha" ]
}

@test "all shows every game, untested shows only the untested ones" {
    echo "all all profile 0 match side side all" > "$STATE"
    [ "$(listed)" == "alpha,beta,gamma" ]
    echo "all all profile 0 match side side untested" > "$STATE"
    [ "$(listed)" == "beta,gamma" ]
}

@test "the tested filter combines with the store and audio filters" {
    echo "gog all profile 0 match side side untested" > "$STATE"
    [ "$(listed)" == "gamma" ]
    echo "all openal profile 0 match side side tested" > "$STATE"
    [ "$(listed)" == "" ]
}

@test "a state file without the field still lists the tested games" {
    echo "all all profile 0 match side side" > "$STATE"
    [ "$(listed)" == "alpha" ]
}

@test "Ctrl-T cycles tested, all, untested and leaves the other fields alone" {
    echo "steam eax2.0 settings 0 az stack side tested" > "$STATE"
    browse_state_next "$STATE" tested
    [ "$(cat "$STATE")" == "steam eax2.0 settings 0 az stack side all" ]
    browse_state_next "$STATE" tested
    [ "$(cat "$STATE")" == "steam eax2.0 settings 0 az stack side untested" ]
    browse_state_next "$STATE" tested
    [ "$(cat "$STATE")" == "steam eax2.0 settings 0 az stack side tested" ]
}

@test "the other keys keep the tested field" {
    echo "all all profile 0 match side side untested" > "$STATE"
    browse_state_next "$STATE" store
    browse_state_next "$STATE" order
    [ "$(cat "$STATE")" == "steam all profile 0 az side side untested" ]
}

@test "the Filters box shows the tested filter and its key" {
    echo "all all profile 0 match side side untested" > "$STATE"
    NC="" CYAN="" BOLD="" GREEN="" BROWSE_SIDE_PERCENT=50
    run browse_filter_header "$STATE" list
    [[ "$output" == *"Ctrl-T Verified"*"Untested"* ]]
}

# ensure_game_database leaves the untested games out unless EAX_RESTORE_UNTESTED is set;
# the browser starts from the full file.
@test "ensure_game_database hides untested games unless EAX_RESTORE_UNTESTED is set" {
    export EAX_RESTORE_GAME_DATABASE_FILE="$GAME_DATABASE_FILE"
    GAME_DATABASE_FILE=""; GAME_DATABASE_ATTEMPTED=""
    GAME_DATABASE_CACHE="$BATS_TEST_TMPDIR/cache.json"; GAME_DATABASE_SCHEMA_VERSION=3
    ensure_game_database 2>/dev/null
    [ "$(jq -r '[.games[].id]|join(",")' "$GAME_DATABASE_FILE")" == "alpha" ]
    [ "$(jq -r '[.games[].id]|join(",")' "$GAME_DATABASE_FULL_FILE")" == "alpha,beta,gamma" ]

    GAME_DATABASE_FILE=""; GAME_DATABASE_ATTEMPTED=""
    EAX_RESTORE_UNTESTED=1 ensure_game_database 2>/dev/null
    [ "$(jq -r '[.games[].id]|join(",")' "$GAME_DATABASE_FILE")" == "alpha,beta,gamma" ]
}
