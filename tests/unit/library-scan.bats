#!/usr/bin/env bats
# scan_game_libraries: which installed Steam and Heroic games it lists, under
# which names, in which order.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/detection.sh"
    source "$REPO_ROOT/src/game-database.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    STEAM="$HOME/.local/share/Steam"
    mkdir -p "$STEAM/steamapps/common"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    cat > "$GAME_DATABASE_FILE" <<'JSON'
{"schema_version":3,"games":[
 {"id":"zeta","name":"Zeta Quest","stores":{"steam":{"id":300},"gog":{"id":9003}}},
 {"id":"alpha","name":"alpha trek","stores":{"steam":{"id":100}}},
 {"id":"mid","name":"Middle Earth","stores":{"steam":{"id":200}}},
 {"id":"gogonly","name":"Gog Only","stores":{"gog":{"id":9001}}},
 {"id":"nofolder","name":"No Folder","stores":{"steam":{"id":400}}}
]}
JSON
    ensure_game_database() { return 0; }
    MAIN_MENU_SHOWN=""
    # paged_select would draw a menu: record what it was given and pick [M]anual.
    paged_select() {
        { printf '%s\n' "${PAGED_LABELS[@]}"; printf -- '--\n'; printf '%s\n' "${PAGED_DETAILS[@]}"; } > "$BATS_TEST_TMPDIR/listed"
        PAGED_CHOICE=m
    }
}

acf() { # appid name installdir
    printf '"AppState"\n{\n\t"appid"\t\t"%s"\n\t"name"\t\t"%s"\n\t"installdir"\t\t"%s"\n}\n' "$1" "$2" "$3" \
        > "$STEAM/steamapps/appmanifest_$1.acf"
}

@test "lists installed database games from Steam and Heroic, sorted by name, Steam before GOG" {
    acf 300 "Zeta Quest" "Zeta"; mkdir -p "$STEAM/steamapps/common/Zeta"
    acf 100 "Alpha Trek" "Alpha"; mkdir -p "$STEAM/steamapps/common/Alpha"
    acf 200 "Middle Earth" "Middle"; mkdir -p "$STEAM/steamapps/common/Middle"
    acf 400 "No Folder" "Missing"
    acf 999 "Not In Database" "Other"; mkdir -p "$STEAM/steamapps/common/Other"
    mkdir -p "$HOME/Games/g1" "$HOME/Games/g3" "$HOME/.config/heroic/gog_store"
    printf '{"installed":[{"appName":"9001","install_path":"%s"},{"appName":"9003","install_path":"%s"},{"appName":"9999","install_path":"%s"}]}' \
        "$HOME/Games/g1" "$HOME/Games/g3" "$HOME/Games/none" > "$HOME/.config/heroic/gog_store/installed.json"
    run scan_game_libraries
    [ "$status" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/listed")" == "$(printf '%s\n' 'alpha trek' 'Gog Only' 'Middle Earth' 'Zeta Quest' 'Zeta Quest' -- '(Steam)' '(GOG)' '(Steam)' '(Steam)' '(GOG)')" ]
}

@test "a game whose folder is gone, or that the database lacks, is not listed" {
    acf 400 "No Folder" "Missing"
    acf 999 "Not In Database" "Other"; mkdir -p "$STEAM/steamapps/common/Other"
    run scan_game_libraries
    [ "$status" -eq 1 ]
    [ ! -e "$BATS_TEST_TMPDIR/listed" ]
}
