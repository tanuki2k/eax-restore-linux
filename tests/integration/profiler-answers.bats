#!/usr/bin/env bats
# tools/profiler runs the built script from a canned answers file; these run those answers
# for real, so a new prompt that makes them drift fails here.

load env

# The profiler runs the script with EAX_RESTORE_DSOAL_PIN=1, which skips the main menu, so its
# answers differ from install_answers in where the first ones land. Run them for real.
profiler_install() {
    python3 "$REPO_ROOT/tools/profiler/capture.py" --print-answers "$1" "$GAME" > "$BATS_TEST_TMPDIR/in"
    EAX_RESTORE_DSOAL_PIN=1 run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
}

@test "the profiler's Steam install answers install the game" {
    make_world
    profiler_install steam
    [ -f "$GAME/.eax-restore-manifest.txt" ]
    grep -q '^REGISTRY:OVERRIDE:dsound' "$GAME/.eax-restore-manifest.txt"
}

@test "the profiler's Heroic install answers install the game" {
    make_world
    profiler_install gog
    [ -f "$GAME/.eax-restore-manifest.txt" ]
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

# What a capture snapshot is compared with must not depend on which step was redone last.
@test "the profiler compares each snapshot with a fixed reference" {
    run python3 -I -c '
import sys; sys.path.insert(0, sys.argv[1])
import profiler
s = {k: {"time": t} for t, k in enumerate(["pre", "installed", "baseline", "audio", "optional"])}
p = lambda k: profiler.previous_label(s, k)
assert (p("pre"), p("installed"), p("baseline"), p("audio"), p("optional"), p("spk-quad")) == (None, "pre", "installed", "baseline", "audio", "audio")
s["baseline"]["time"] = 99  # redoing the baseline must not move the audio comparison
assert p("audio") == "baseline" and p("optional") == "audio"
s["optional"]["time"] = 0.5  # optional first: audio compares with it
assert p("audio") == "optional"
' "$REPO_ROOT/tools/profiler"
    [ "$status" -eq 0 ]
}
