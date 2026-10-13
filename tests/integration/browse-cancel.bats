#!/usr/bin/env bats
# Cancelling the folder picker asks whether to browse again; No goes back to
# the main menu instead of leaving the player at a dead end.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
    mkdir -p "$BATS_TEST_TMPDIR/picker"
    # A folder picker the player always cancels (no output, non-zero exit).
    printf '#!/bin/sh\necho "$1" >> "%s"\nexit 1\n' "$STUB_LOG" > "$BATS_TEST_TMPDIR/picker/zenity"
    chmod +x "$BATS_TEST_TMPDIR/picker/zenity"
    export PATH="$BATS_TEST_TMPDIR/picker:$PATH"
}

@test "cancelling the picker and answering Yes opens it again" {
    answers "$BATS_TEST_TMPDIR/in" b y n q
    run_script "$BATS_TEST_TMPDIR/in"
    [ "$(grep -c -- '--file-selection' "$STUB_LOG")" -eq 2 ]
    [ "$(grep -c 'Browse for the game folder again?' "$OUT")" -eq 2 ]
}

@test "cancelling the picker and answering No goes back to the main menu" {
    answers "$BATS_TEST_TMPDIR/in" b n q
    run_script "$BATS_TEST_TMPDIR/in"
    [ "$(grep -c -- '--file-selection' "$STUB_LOG")" -eq 1 ]
    # the main menu is shown a second time
    [ "$(grep -c 'Selection \[' "$OUT")" -eq 2 ]
}
