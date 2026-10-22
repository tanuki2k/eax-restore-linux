#!/usr/bin/env bats
# The database browser draws its preview in a fresh shell that only has what
# game-database.sh's browse dump hands it (declare -p of a few variables plus
# declare -f of every function). A helper that reads a variable outside that
# list shows nothing there, silently, so this runs the profile the same way.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    GAME_DATABASE_FILE="$REPO_ROOT/tests/fixtures/game-database.json"
    DUMP="$BATS_TEST_TMPDIR/dump.sh"
    { declare -p GREEN YELLOW CYAN WHITE BOLD DIM NOTE NC GAME_DATABASE_FILE SCRIPT_VERSION; declare -f; } > "$DUMP"
}

in_fresh_shell() {
    env -i HOME="$HOME" TERM=dumb PATH="$PATH" bash -c 'source "$1"; shift; "$@"' _ "$DUMP" "$@"
}

@test "the profile in a fresh shell has the name, EAX status and setting titles" {
    run in_fresh_shell print_game_profile_stores "" steam:424242
    [ "$status" -eq 0 ]
    plain="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")"
    grep -q "Test Game" <<< "$plain"
    grep -q "2001" <<< "$plain"
    grep -q "Enable EAX effects" <<< "$plain"
    grep -q "Skip intro movies" <<< "$plain"
}

@test "the fresh-shell profile is the same as the one in this shell" {
    here="$(print_game_profile_stores "" steam:424242)"
    run in_fresh_shell print_game_profile_stores "" steam:424242
    [ "$output" == "$here" ]
}

@test "the profile says Verified: Tested for a tested game" {
    run in_fresh_shell print_game_profile_stores "" steam:424242
    plain="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")"
    grep -Eq "Verified: +Tested" <<< "$plain"
    grep -q "Enable EAX effects (tested)" <<< "$plain"
}

@test "a supported game shows its eax.problem under Status, and without one has no Status" {
    run in_fresh_shell print_game_profile_stores "" steam:424242
    ! grep -q "Status" <<< "$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    jq '.games[0].eax.problem = "The maps have no environmental audio."' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$GAME_DATABASE_FILE"
    { declare -p GREEN YELLOW CYAN WHITE BOLD DIM NOTE NC GAME_DATABASE_FILE SCRIPT_VERSION; declare -f; } > "$DUMP"
    run in_fresh_shell print_game_profile_stores "" steam:424242
    plain="$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")"
    grep -q "Status" <<< "$plain"
    grep -q "The maps have no environmental audio." <<< "$plain"
}

@test "the browser's right pane has text at every window width" {
    echo "all all profile 0 match side side tested" > "$BATS_TEST_TMPDIR/state"
    for cols in 1 3 5 8 12 16 19 24 40 80 120; do
        wrap="$(browse_wrap_columns "$cols")"
        [ "$wrap" -ge 24 ]
        out="$(WRAP_COLUMNS=$wrap browse_game_preview "$BATS_TEST_TMPDIR/state" test-game)"
        [ -n "$out" ] || { echo "profile empty at $cols"; false; }
        help="$(WRAP_COLUMNS=$wrap browse_help)"
        [ -n "$help" ] || { echo "help empty at $cols"; false; }
        [ "$(wc -l <<< "$help")" -gt 20 ]
    done
}
