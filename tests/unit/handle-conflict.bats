#!/usr/bin/env bats
# handle_conflict runs in the middle of Phase 4, which asks nothing: a file
# already where one is deployed is backed up without a prompt.

load ../helpers

setup() {
    load_script_functions
    for f in detection cache; do source "$REPO_ROOT/src/$f.sh"; done
    declare -gA PREV_MANIFEST_FILES=()
    DEPLOY_FAILURES=0
    DIR="$BATS_TEST_TMPDIR/game"
    mkdir -p "$DIR"
}

@test "an existing dsound.dll is backed up without reading an answer" {
    echo "the game's own" > "$DIR/dsound.dll"
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$DIR/dsound.dll" ]
    [ "$(cat "$DIR"/dsound.dll.bak.*)" == "the game's own" ]
    [[ "$output" == *"Backed up the original dsound.dll to dsound.dll.bak."* ]]
    [[ "$output" != *"What would you like to do"* ]]
}

@test "a differently-cased original is backed up under the target's name" {
    echo "orig" > "$DIR/DSOUND.DLL"
    handle_conflict "$DIR/dsound.dll" < /dev/null
    [ ! -e "$DIR/DSOUND.DLL" ]
    ls "$DIR"/dsound.dll.bak.* >/dev/null
}

@test "nothing there: nothing to do" {
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a folder that can't be written keeps the original and skips the copy" {
    [ "$(id -u)" -ne 0 ] || skip "root can always write"
    echo "orig" > "$DIR/dsound.dll"
    chmod a-w "$DIR"
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    chmod u+w "$DIR"
    [ "$status" -eq 1 ]
    [ "$(cat "$DIR/dsound.dll")" == "orig" ]
}
