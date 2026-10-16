#!/usr/bin/env bats
# A game whose profile says OpenAL: the game's own OpenAL32.dll is backed up
# and replaced without a question, and uninstall puts it back.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
    DB_FILE="$BATS_TEST_TMPDIR/openal-db.json"
    jq '.games[0] |= (del(.game_config) | .eax.api = "openal")' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$DB_FILE"
    printf 'game own openal\n' > "$GAME/OpenAL32.dll"
}

openal_answers() {
    answers "$1" m "$GAME" \
        "" "" "" \
        "" "" \
        "" "" \
        "" "" \
        "" n \
        "" "" "" \
        "" \
        "" \
        "" "" "" ""
}

@test "an existing OpenAL32.dll is backed up and replaced without asking" {
    snapshot "$BATS_TEST_TMPDIR/before"
    openal_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -40 "$OUT"; false; }
    ! grep -q "What would you like to do" "$OUT"
    [ "$(cat "$GAME/OpenAL32.dll")" == "fake soft_oal 32" ]
    [ "$(cat "$GAME"/OpenAL32.dll.bak.*)" == "game own openal" ]
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}
