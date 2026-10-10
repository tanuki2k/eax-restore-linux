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
