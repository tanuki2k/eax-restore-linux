#!/usr/bin/env bats
# The database browser's compatibility filter: the key's cycle and which
# games each setting lists. Each store entry is filtered on its own rating.

load ../helpers

setup() {
    load_script_functions
    load_src game-database
    write_db <<'JSON'
{"schema_version":3,"games":[
 {"id":"alpha","name":"Alpha","stores":{"steam":{"id":1,"compatibility":"verified"}},"eax":{"api":"directsound3d"}},
 {"id":"beta","name":"Beta","stores":{"steam":{"id":2,"compatibility":"unknown"}},"eax":{"api":"openal"}},
 {"id":"delta","name":"Delta","stores":{"steam":{"id":4,"compatibility":"unknown"},"gog":{"id":5,"compatibility":"playable"}},"eax":{"api":"directsound3d"}},
 {"id":"gamma","name":"Gamma","stores":{"gog":{"id":3,"compatibility":"unsupported"}},"eax":{"api":"openal"}}
]}
JSON
    STATE="$BATS_TEST_TMPDIR/state"
}

listed() { browse_game_stores "$STATE" | cut -f1,3 | tr '\t' : | paste -sd,; }

@test "the browser opens on every rated store entry" {
    echo "all all profile 0 match side side rated" > "$STATE"
    [ "$(listed)" == "alpha:steam,delta:gog,gamma:gog" ]
}

@test "all shows every entry, and each rating only its own" {
    echo "all all profile 0 match side side all" > "$STATE"
    [ "$(listed)" == "alpha:steam,beta:steam,delta:steam,delta:gog,gamma:gog" ]
    echo "all all profile 0 match side side unknown" > "$STATE"
    [ "$(listed)" == "beta:steam,delta:steam" ]
    echo "all all profile 0 match side side playable" > "$STATE"
    [ "$(listed)" == "delta:gog" ]
    echo "all all profile 0 match side side unsupported" > "$STATE"
    [ "$(listed)" == "gamma:gog" ]
}

@test "the compatibility filter combines with the store and audio filters" {
    echo "steam all profile 0 match side side unknown" > "$STATE"
    [ "$(listed)" == "beta:steam,delta:steam" ]
    echo "all openal profile 0 match side side verified" > "$STATE"
    [ "$(listed)" == "" ]
}

@test "a state file without the field lists the rated entries" {
    echo "all all profile 0 match side side" > "$STATE"
    [ "$(listed)" == "alpha:steam,delta:gog,gamma:gog" ]
}

@test "Ctrl-T cycles rated, all and each rating, and leaves the other fields alone" {
    echo "steam eax2.0 settings 0 az stack side rated" > "$STATE"
    local want
    for want in all verified playable unsupported unknown rated; do
        browse_state_next "$STATE" compat
        [ "$(cat "$STATE")" == "steam eax2.0 settings 0 az stack side $want" ]
    done
}

@test "the other keys keep the compatibility field" {
    echo "all all profile 0 match side side unknown" > "$STATE"
    browse_state_next "$STATE" store
    browse_state_next "$STATE" order
    [ "$(cat "$STATE")" == "steam all profile 0 az side side unknown" ]
}

@test "the Filters box shows each key and its value, without filter names" {
    echo "all all profile 0 match side side unknown" > "$STATE"
    NC="" CYAN="" BOLD="" GREEN="" BROWSE_SIDE_PERCENT=50
    run browse_filter_header "$STATE" list
    [ "$output" == $'Ctrl-S All stores\nCtrl-A All APIs\nCtrl-R Best match\nCtrl-T Unknown' ]
    echo "all all profile 0 match side side all" > "$STATE"
    run browse_filter_header "$STATE" list
    [[ "$output" == *"Ctrl-T All games"* ]]
    echo "all all profile 0 match side side rated" > "$STATE"
    run browse_filter_header "$STATE" list
    [[ "$output" == *"Ctrl-T Rated"* ]]
}

@test "the Filters box keeps every key in the same column as the filters change" {
    NC="" CYAN="" BOLD="" GREEN="" BROWSE_SIDE_PERCENT=50
    local a b key
    echo "gog openal profile 0 match stack stack unsupported" > "$STATE"
    a="$(FZF_COLUMNS=200 browse_filter_header "$STATE")"
    echo "steam-delisted directsound3d profile 0 match stack stack all" > "$STATE"
    b="$(FZF_COLUMNS=200 browse_filter_header "$STATE")"
    [ "$(wc -l <<< "$a")" -eq 1 ]
    for key in Ctrl-A Ctrl-R Ctrl-T; do
        local before_a="${a%%"$key"*}" before_b="${b%%"$key"*}"
        [ "${#before_a}" -eq "${#before_b}" ]
    done
}

# ensure_game_database leaves the unknown store entries out unless
# EAX_RESTORE_UNKNOWN_GAMES is set; the browser starts from the full file.
@test "ensure_game_database hides unknown store entries unless EAX_RESTORE_UNKNOWN_GAMES is set" {
    export EAX_RESTORE_GAME_DATABASE_FILE="$GAME_DATABASE_FILE"
    GAME_DATABASE_FILE=""; GAME_DATABASE_ATTEMPTED=""
    GAME_DATABASE_CACHE="$BATS_TEST_TMPDIR/cache.json"; GAME_DATABASE_SCHEMA_VERSION=3
    ensure_game_database 2>/dev/null
    [ "$(jq -r '[.games[] | .id + ":" + (.stores | keys | join("+"))] | join(",")' "$GAME_DATABASE_FILE")" == "alpha:steam,delta:gog,gamma:gog" ]
    [ "$(jq -r '[.games[].id]|join(",")' "$GAME_DATABASE_FULL_FILE")" == "alpha,beta,delta,gamma" ]

    GAME_DATABASE_FILE=""; GAME_DATABASE_ATTEMPTED=""
    EAX_RESTORE_UNKNOWN_GAMES=1 ensure_game_database 2>/dev/null
    [ "$(jq -r '[.games[].id]|join(",")' "$GAME_DATABASE_FILE")" == "alpha,beta,delta,gamma" ]
}

@test "ensure_game_database works out the ratings for a database built before them" {
    write_db <<'JSON'
{"schema_version":3,"games":[
 {"id":"old","name":"Old","stores":{"steam":{"id":1}},"eax":{"api":"openal"},
  "game_config":{"files":{},"audio_settings":[{"title":"Enable EAX","tested":true},{"title":"Other"}]},
  "install":{"alsoft_ini":{"reverb":{"boost":"6"}},"alsoft_tested":true}},
 {"id":"new","name":"New","stores":{"steam":{"id":2}},"eax":{"api":"openal"},"tested":false},
 {"id":"remaster","name":"Remaster","stores":{"steam":{"id":3}},"eax":{"api":"openal","status":"not_implemented","problem":"No EAX."}},
 {"id":"rolled","name":"Rolled","stores":{"steam":{"id":4,"beta_branch":"old"}},"eax":{"api":"openal","status":"removed_by_patch","fix_in_place":true}},
 {"id":"builtin","name":"Builtin","stores":{"steam":{"id":5}},"eax":{"api":"openal","status":"built_in"},"tested":false}
]}
JSON
    export EAX_RESTORE_GAME_DATABASE_FILE="$GAME_DATABASE_FILE"
    GAME_DATABASE_FILE=""; GAME_DATABASE_ATTEMPTED=""
    GAME_DATABASE_CACHE="$BATS_TEST_TMPDIR/cache.json"; GAME_DATABASE_SCHEMA_VERSION=3
    EAX_RESTORE_UNKNOWN_GAMES=1 ensure_game_database 2>/dev/null
    [ "$(jq -c '[.games[] | .stores.steam.compatibility]' "$GAME_DATABASE_FILE")" == '["verified","unknown","unsupported","verified","unknown"]' ]
    [ "$(jq -c '.games[0] | [[.game_config.audio_settings[].verified], .install.alsoft_verified]' "$GAME_DATABASE_FILE")" == '[[true,null],true]' ]
    [ "$(jq -c '[.games[2].stores.steam.problem, .games[4].eax.built_in]' "$GAME_DATABASE_FILE")" == '["No EAX.",true]' ]
    [ "$(game_eax_gate 3 steam)" == "unsupported" ]
    [ "$(game_eax_gate 4 steam)" == "rollback" ]
    [ "$(game_eax_gate 5 steam)" == "built_in" ]
    [ -z "$(game_eax_gate 1 steam)" ]
}

@test "the Miles filter lists the games built on the Miles Sound System, and Ctrl-A steps through it" {
    jq '.games[1].eax.sound_system = "miles"' "$GAME_DATABASE_FILE" > "$BATS_TEST_TMPDIR/m.json" && mv "$BATS_TEST_TMPDIR/m.json" "$GAME_DATABASE_FILE"
    echo "all miles profile 0 match side side all" > "$STATE"
    [ "$(listed)" == "beta:steam" ]
    echo "all openal profile 0 match side side all" > "$STATE"
    browse_state_next "$STATE" audio
    [ "$(cut -d' ' -f2 "$STATE")" == "miles" ]
    browse_state_next "$STATE" audio
    [ "$(cut -d' ' -f2 "$STATE")" == "eax1.0" ]
}
