#!/usr/bin/env bats
# hrtf-paths in the generated alsoft.ini must end with a comma. Without it
# OpenAL Soft searches only the listed folders (empty since 0.29 stopped
# copying .mhr files) and never adds its built-in HRTF, so HRTF stays off.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
}

@test "the generated alsoft.ini keeps OpenAL Soft's default and built-in HRTF" {
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    grep -Eq '^hrtf-paths = .*,$' "$GAME/alsoft.ini" || { grep hrtf-paths "$GAME/alsoft.ini"; false; }
}
