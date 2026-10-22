#!/usr/bin/env bats
# Regressions from the second script audit: menu numbers with a leading zero,
# half-extracted caches, uninstall scope, and the database build on bad JSON.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    source "$REPO_ROOT/src/detection.sh" 2>/dev/null || true
    source "$REPO_ROOT/src/cache.sh" 2>/dev/null || true
}

make_zip() {  # <zip> <file name> <content>; python, so zip(1) isn't needed
    python3 -I - "$1" "$2" "$3" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z: z.writestr(sys.argv[2], sys.argv[3])
PY
}

@test "paged_select: 08 and 09 are decimal, not a bad octal number" {
    PAGED_LABELS=(a b c d e f g h i j); PAGED_DETAILS=()
    paged_select "Games" <<< "08" >/dev/null
    [ "$PAGED_CHOICE" == "8" ]
    [ "$((PAGED_CHOICE - 1))" == "7" ]
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

@test "manifest_path_in_scope: the game folder and prefix drives only" {
    manifest_path_in_scope /g/Game/sub/dsound.dll /g/Game
    manifest_path_in_scope /h/pfx/drive_c/windows/system32/OpenAL32.dll /g/Game
    ! manifest_path_in_scope /g/Other/dsound.dll /g/Game
    ! manifest_path_in_scope /g/Game2/dsound.dll /g/Game
}

@test "build-game-database: a file that isn't valid JSON fails the build" {
    local w="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$w/tools" "$w/data/games/tested" "$w/data/games/untested" "$w/data/drafts"
    cp "$REPO_ROOT"/tools/*.sh "$REPO_ROOT"/tools/*.jq "$w/tools/" 2>/dev/null || cp -r "$REPO_ROOT"/tools/. "$w/tools/"
    echo '{ not json' > "$w/data/games/tested/broken.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *broken.json* ]]
    [ ! -e "$w/game-database.json" ]
}
