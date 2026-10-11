#!/usr/bin/env bats
# tools/profiler runs the built script from a canned answers file; this fails
# when a new prompt makes those answers drift from the ones the tests use.

load env

@test "the profiler's Steam install answers match install_answers" {
    make_world
    OVERRIDE_CHOICE=2 install_answers "$BATS_TEST_TMPDIR/want"
    python3 "$REPO_ROOT/tools/profiler/capture.py" --print-answers steam "$GAME" > "$BATS_TEST_TMPDIR/got"
    diff "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
}

@test "the profiler's Heroic install answers match heroic_install_answers" {
    make_world
    heroic_install_answers "$BATS_TEST_TMPDIR/want"
    python3 "$REPO_ROOT/tools/profiler/capture.py" --print-answers gog "$GAME" > "$BATS_TEST_TMPDIR/got"
    diff "$BATS_TEST_TMPDIR/want" "$BATS_TEST_TMPDIR/got"
}

# The profiler's "Remove install" runs the script's uninstall unattended, choosing the game by
# typing its folder. These run it for real and check the tree comes back byte for byte.
profiler_uninstall() {
    python3 "$REPO_ROOT/tools/profiler/cleanup.py" --print-answers "$1" "$GAME" ${2:-} > "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
}

@test "the profiler's Steam uninstall answers put the tree back" {
    make_world
    snapshot "$BATS_TEST_TMPDIR/before"
    install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    profiler_uninstall steam
    grep -q "UNINSTALL COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

@test "the profiler's Heroic uninstall answers put the tree back" {
    make_heroic_world
    snapshot "$BATS_TEST_TMPDIR/before"
    heroic_install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    profiler_uninstall gog
    grep -q "UNINSTALL COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

@test "the profiler can leave the launch-option override alone while still uninstalling" {
    make_world
    install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    profiler_uninstall steam keep
    grep -q "UNINSTALL COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    [ ! -e "$GAME/dsoal-aldrv.dll" ]
    grep -q 'WINEDLLOVERRIDES' "$STEAM/userdata/1/config/localconfig.vdf"
}

@test "the same for Heroic: files removed, override kept" {
    make_heroic_world
    heroic_install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    profiler_uninstall gog keep
    grep -q "UNINSTALL COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    [ ! -e "$GAME/dsoal-aldrv.dll" ]
    grep -q 'WINEDLLOVERRIDES' "$HOME/.config/heroic/GamesConfig/$HEROIC_ID.json"
}
