#!/usr/bin/env bats
# 0.28.x copied the HRTF profiles into <game>/OpenAL and listed that folder in
# the manifest as a bare path. 0.29 no longer deploys it, but uninstalling an
# install from 0.28 has to take the folder back (and not touch anything else).

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
}

# An install, then the folder and manifest line a 0.28 install would have added.
install_with_legacy_hrtf() {
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    mkdir -p "$GAME/OpenAL/HRTF"
    printf 'hrtf data\n' > "$GAME/OpenAL/HRTF/irc_1018_48000.mhr"
    printf 'credits\n' > "$GAME/OpenAL/HRTF/HRTF_CREDITS.txt"
    printf '%s\n' "$GAME/OpenAL" >> "$GAME/.eax-restore-manifest.txt"
}

@test "uninstall removes the HRTF folder a 0.28 install recorded" {
    snapshot "$BATS_TEST_TMPDIR/before"
    install_with_legacy_hrtf
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    ! grep -q "Skipped .*OpenAL" "$OUT" || { tail -30 "$OUT"; false; }
    [ ! -e "$GAME/OpenAL" ]
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -20 "$OUT"; false; }
}

@test "uninstall keeps an OpenAL folder that holds a file of the player's own" {
    install_with_legacy_hrtf
    printf 'mine\n' > "$GAME/OpenAL/my-notes.dat"
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    [ -f "$GAME/OpenAL/my-notes.dat" ]
    [ -f "$GAME/OpenAL/HRTF/irc_1018_48000.mhr" ]
    grep -q "Couldn't remove .*OpenAL" "$OUT" || { tail -30 "$OUT"; false; }
}

@test "uninstall ignores an OpenAL line that is a symlink" {
    install_with_legacy_hrtf
    rm -rf "$GAME/OpenAL"
    mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
    printf 'keep\n' > "$BATS_TEST_TMPDIR/elsewhere/x.mhr"
    ln -s "$BATS_TEST_TMPDIR/elsewhere" "$GAME/OpenAL"
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    [ -f "$BATS_TEST_TMPDIR/elsewhere/x.mhr" ]
}
