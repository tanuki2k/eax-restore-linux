#!/usr/bin/env bats
# EAX_RESTORE_ACTION / EAX_RESTORE_GAME_DIR / EAX_RESTORE_GAME: a program with
# its own menu (the TUI) picks what runs and which game, so the script asks
# neither.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
}

plain() { sed 's/\x1b\[[0-9;]*m//g' "$OUT"; }

# The install's answers without the main menu's "m", the blank "go back" and
# the typed path: the env vars already gave those.
install_rest() { install_answers "$BATS_TEST_TMPDIR/full"; tail -n +4 "$BATS_TEST_TMPDIR/full" > "$1"; }

# Uninstall without the menu letter and the pick from the installed-games list.
uninstall_rest() { uninstall_answers "$BATS_TEST_TMPDIR/full"; tail -n +3 "$BATS_TEST_TMPDIR/full" > "$1"; }

@test "ACTION=install with GAME_DIR installs without the main menu or a path prompt" {
    install_rest "$BATS_TEST_TMPDIR/in"
    EAX_RESTORE_ACTION=install EAX_RESTORE_GAME_DIR="$GAME" run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    ! plain | grep -q "SELECT OPERATION"
    ! plain | grep -q "Enter the full path"
    [ "$(cat "$GAME/dsound.dll")" == "fake dsound Win32" ]
}

@test "ACTION=uninstall with GAME_DIR puts everything back, with no installed-games list" {
    snapshot "$BATS_TEST_TMPDIR/before"
    install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    uninstall_rest "$BATS_TEST_TMPDIR/un"
    EAX_RESTORE_ACTION=uninstall EAX_RESTORE_GAME_DIR="$GAME" run_script "$BATS_TEST_TMPDIR/un"
    ! plain | grep -q "Games with something installed"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -20 "$OUT"; false; }
}

@test "an unknown ACTION is refused with the list of valid ones" {
    : > "$BATS_TEST_TMPDIR/in"
    run env EAX_RESTORE_ACTION=bogus EAX_RESTORE_GAME_DIR="$GAME" bash -c \
        "EAX_RESTORE_GAME_DATABASE_FILE='$BATS_TEST_TMPDIR/none.json' '$REPO_ROOT/dist/eax-restore-linux.sh' < '$BATS_TEST_TMPDIR/in'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"EAX_RESTORE_ACTION is set to 'bogus', which isn't one of install,"* ]]
    [[ "$output" == *"uninstall, optional-settings, speakers, vcrun or dsoal-log."* ]]
}

@test "a tool that is declined ends the run instead of showing the Tools menu" {
    answers "$BATS_TEST_TMPDIR/in" n
    EAX_RESTORE_ACTION=vcrun EAX_RESTORE_GAME_DIR="$GAME" run_script "$BATS_TEST_TMPDIR/in"
    ! plain | grep -q "TOOLS"
    ! plain | grep -q "What would you like to do"
}

@test "GAME=steam:ID picks that game from the library scan without the list" {
    DB_FILE="$BATS_TEST_TMPDIR/db.json"
    cp "$REPO_ROOT/tests/fixtures/game-database.json" "$DB_FILE"
    export EAX_RESTORE_UNTESTED=1
    answers "$BATS_TEST_TMPDIR/in" n
    EAX_RESTORE_ACTION=install EAX_RESTORE_GAME="steam:$APPID" run_script "$BATS_TEST_TMPDIR/in"
    # The game's profile and the "Continue?" come up as they do for a scan pick;
    # the "n" declines, which only goes back to the locate menu.
    plain | grep -q "Name: *Test Game" || { tail -30 "$OUT"; false; }
    plain | grep -q "Continue with this game?"
    ! plain | grep -q "Games with a profile in your libraries"
    ! plain | grep -q "Scan your libraries, knowing"
}

@test "GAME naming a game that isn't installed falls back to the list, naming the game" {
    DB_FILE="$BATS_TEST_TMPDIR/db.json"
    jq '.games += [{"id":"other","name":"Other Game","stores":{"steam":{"id":5}}}]' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$DB_FILE"
    export EAX_RESTORE_UNTESTED=1
    answers "$BATS_TEST_TMPDIR/in" ""
    EAX_RESTORE_ACTION=install EAX_RESTORE_GAME="steam:5" run_script "$BATS_TEST_TMPDIR/in"
    plain | grep -q "Other Game isn't in your Steam or Heroic libraries" || { tail -20 "$OUT"; false; }
    plain | grep -q "Games with a profile in your libraries"
}

@test "GAME naming a game the database doesn't list still falls back to the list" {
    DB_FILE="$BATS_TEST_TMPDIR/db.json"
    cp "$REPO_ROOT/tests/fixtures/game-database.json" "$DB_FILE"
    export EAX_RESTORE_UNTESTED=1
    answers "$BATS_TEST_TMPDIR/in" ""
    EAX_RESTORE_ACTION=install EAX_RESTORE_GAME="steam:1" run_script "$BATS_TEST_TMPDIR/in"
    plain | grep -q "That game isn't in your Steam or Heroic libraries"
    plain | grep -q "Games with a profile in your libraries"
}

@test "a GAME that finds nothing doesn't skip the scan's question the next time" {
    DB_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"schema_version":3,"games":[{"id":"other","name":"Other Game","stores":{"steam":{"id":5}}}]}' > "$DB_FILE"
    export EAX_RESTORE_UNTESTED=1
    # The first scan finds no game from the database and goes back to the
    # locate menu (the first answer is the Press Enter gate); choosing [S]can
    # again has to ask its question this time.
    answers "$BATS_TEST_TMPDIR/in" "" s n
    EAX_RESTORE_ACTION=install EAX_RESTORE_GAME="steam:5" run_script "$BATS_TEST_TMPDIR/in"
    plain | grep -q "Scan your libraries, knowing" || { tail -20 "$OUT"; false; }
}
