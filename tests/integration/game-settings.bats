#!/usr/bin/env bats
# A game with a profile in the database: the install changes its own config
# files (audio setting on request, optional ones picked), the manifest records
# them, and uninstall puts them back.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_profile_world
}

install_profile() {
    profile_install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
}

@test "install applies the audio setting and the picked optional setting" {
    install_profile
    [ "$(config_get_ini Audio UseEAX)" == "1" ]
    [ "$(config_get_ini Audio Provider)" == "DSOUND" ]
    [ "$(config_get_ini Video SkipIntro)" == "1" ]
    [ "$(config_get_ini Video Width)" == "640" ]
}

config_get_ini() {
    awk -v sec="$1" -v key="$2" -F= '
        /^\[/ { s = $0; gsub(/[\[\]\r]/, "", s); insec = (s == sec); next }
        insec { k = $1; sub(/\r$/, "", $2); if (k == key) { print $2; exit } }' "$GAME/settings.ini"
}

@test "install keeps the file's CRLF line endings" {
    install_profile
    [ "$(grep -c $'\r$' "$GAME/settings.ini")" -eq "$(wc -l < "$GAME/settings.ini")" ]
}

@test "install records each change in the manifest with its old and new value" {
    install_profile
    grep -P "^CONFIG:audio\tEnable EAX effects\t.*settings.ini\tini\tAudio\tUseEAX\t0\t1$" "$GAME/.eax-restore-manifest.txt"
    grep -P "^CONFIG:optional\tSkip intro movies\t.*\tVideo\tSkipIntro\t__ABSENT__\t1$" "$GAME/.eax-restore-manifest.txt"
}

@test "install leaves the optional setting alone when none is picked" {
    profile_install_answers "$BATS_TEST_TMPDIR/in"
    # the "pick" answer becomes n (none), which means none in every version
    sed -i 's/^1$/n/' "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    [ "$(config_get_ini Audio UseEAX)" == "1" ]
    [ -z "$(config_get_ini Video SkipIntro)" ]
}

@test "uninstall puts the settings back and the whole tree is byte-identical" {
    snapshot "$BATS_TEST_TMPDIR/before"
    install_profile
    uninstall_profile_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -25 "$OUT"; false; }
}

@test "uninstall can keep the settings while removing everything else" {
    install_profile
    uninstall_profile_answers "$BATS_TEST_TMPDIR/un" n
    run_script "$BATS_TEST_TMPDIR/un"
    [ "$(config_get_ini Audio UseEAX)" == "1" ]
    [ "$(config_get_ini Video SkipIntro)" == "1" ]
    [ ! -e "$GAME/dsoal-aldrv.dll" ]
}

@test "uninstall puts back only the settings picked" {
    install_profile
    uninstall_profile_answers "$BATS_TEST_TMPDIR/un" 2
    run_script "$BATS_TEST_TMPDIR/un"
    [ "$(config_get_ini Audio UseEAX)" == "1" ]
    [ -z "$(config_get_ini Video SkipIntro)" ]
}
