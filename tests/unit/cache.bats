#!/usr/bin/env bats
# cache.sh and verify.sh: deploying over a file that's already there,
# downloads and their checksums, unpacking, and the install manifest.

load ../helpers

setup() {
    load_script_functions
    load_src detection cache
    declare -gA PREV_MANIFEST_FILES=()
    DEPLOY_FAILURES=0
    DIR="$BATS_TEST_TMPDIR/game"
    mkdir -p "$DIR"
}

# ---- handle_conflict ---------------------------------------------------------
# handle_conflict runs in the middle of Phase 4, which asks nothing: a file
# already where one is deployed is backed up without a prompt.

@test "an existing dsound.dll is backed up without reading an answer" {
    echo "the game's own" > "$DIR/dsound.dll"
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -e "$DIR/dsound.dll" ]
    [ "$(cat "$DIR"/dsound.dll.bak.*)" == "the game's own" ]
    [[ "$output" == *"Backed up the original dsound.dll to dsound.dll.bak."* ]]
    [[ "$output" != *"What would you like to do"* ]]
}

@test "a differently-cased original is backed up under the target's name" {
    echo "orig" > "$DIR/DSOUND.DLL"
    handle_conflict "$DIR/dsound.dll" < /dev/null
    [ ! -e "$DIR/DSOUND.DLL" ]
    ls "$DIR"/dsound.dll.bak.* >/dev/null
}

@test "nothing there: nothing to do" {
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "a folder that can't be written keeps the original and skips the copy" {
    [ "$(id -u)" -ne 0 ] || skip "root can always write"
    echo "orig" > "$DIR/dsound.dll"
    chmod a-w "$DIR"
    run handle_conflict "$DIR/dsound.dll" < /dev/null
    chmod u+w "$DIR"
    [ "$status" -eq 1 ]
    [ "$(cat "$DIR/dsound.dll")" == "orig" ]
}

# ---- downloads, manifests and checksums --------------------------------------

make_zip() {  # <zip> <file name> <content>; python, so zip(1) isn't needed
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z: z.writestr(sys.argv[2], sys.argv[3])
PY
}

@test "extract_zip_into: swaps the new contents in" {
    make_zip "$BATS_TEST_TMPDIR/a.zip" new.txt hello
    mkdir "$BATS_TEST_TMPDIR/cache"; echo old > "$BATS_TEST_TMPDIR/cache/old.txt"
    extract_zip_into "$BATS_TEST_TMPDIR/a.zip" "$BATS_TEST_TMPDIR/cache"
    [ -f "$BATS_TEST_TMPDIR/cache/new.txt" ] && [ ! -e "$BATS_TEST_TMPDIR/cache/old.txt" ]
    [ ! -e "$BATS_TEST_TMPDIR/cache.new" ]
}

@test "extract_zip_into: a corrupt zip fails and the old cache stays" {
    printf 'not a zip' > "$BATS_TEST_TMPDIR/bad.zip"
    mkdir "$BATS_TEST_TMPDIR/cache"; echo old > "$BATS_TEST_TMPDIR/cache/old.txt"
    run extract_zip_into "$BATS_TEST_TMPDIR/bad.zip" "$BATS_TEST_TMPDIR/cache"
    [ "$status" -ne 0 ]
    [ -f "$BATS_TEST_TMPDIR/cache/old.txt" ]
    [ ! -e "$BATS_TEST_TMPDIR/cache.new" ]
}

@test "unpack_dsoal_zip: a corrupt zip fails, keeps the old cache and writes no marker" {
    DSOAL_OFFICIAL="$BATS_TEST_TMPDIR/official"; DSOAL_SHARE="$BATS_TEST_TMPDIR"
    mkdir "$DSOAL_OFFICIAL"; echo old > "$DSOAL_OFFICIAL/old.txt"
    printf 'not a zip' > "$BATS_TEST_TMPDIR/bad.zip"
    run install_dsoal_zip_into_official "$BATS_TEST_TMPDIR/bad.zip" marker
    [ "$status" -ne 0 ]
    [ -f "$DSOAL_OFFICIAL/old.txt" ]
    [ ! -e "$BATS_TEST_TMPDIR/updated_at.txt" ]
}

@test "an empty digest keeps its field when the line is split on the unit separator" {
    IFS=$'\x1f' read -r url digest updated version <<< $'u\x1f\x1f2024-01-01\x1f1.2'
    [ "$url" == u ] && [ -z "$digest" ] && [ "$updated" == 2024-01-01 ] && [ "$version" == 1.2 ]
}

@test "manifest_forget_paths drops exactly those lines" {
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/m.txt"
    printf '%s\n' "# EAX Restore manifest, format 2" /g/dsound.dll /g/alsoft.ini "REGISTRY:COM" > "$INSTALL_MANIFEST"
    manifest_forget_paths /g/dsound.dll
    [ "$(cat "$INSTALL_MANIFEST")" == "$(printf '%s\n' "# EAX Restore manifest, format 2" /g/alsoft.ini "REGISTRY:COM")" ]
}

@test "manifest_dedupe keeps the first of each line" {
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/m.txt"
    printf '%s\n' "VCRUN" /g/a.dll "VCRUN" /g/a.dll > "$INSTALL_MANIFEST"
    manifest_dedupe
    [ "$(cat "$INSTALL_MANIFEST")" == "$(printf '%s\n' VCRUN /g/a.dll)" ]
}

@test "verify_checksum fails when sha256sum is missing" {
    printf x > "$BATS_TEST_TMPDIR/f"
    PATH="$BATS_TEST_TMPDIR/nopath" run verify_checksum "$BATS_TEST_TMPDIR/f" deadbeef
    [ "$status" -eq 1 ]
}

@test "start_manifest: sets the old one aside only when asked" {
    local m="$BATS_TEST_TMPDIR/m.txt"
    printf '%s\n/g/dsound.dll\nCONFIG:x\n' "$MANIFEST_HEADER" > "$m"
    start_manifest "$m"
    [ -z "$MANIFEST_PREV" ] && [ ! -e "$m.prev" ]
    printf '%s\n/g/dsound.dll\nCONFIG:x\n' "$MANIFEST_HEADER" > "$m"
    start_manifest "$m" keep
    [ "$MANIFEST_PREV" == "$m.prev" ] && grep -q '^CONFIG:x' "$m.prev"
    [ "$(cat "$m")" == "$MANIFEST_HEADER" ]
}
