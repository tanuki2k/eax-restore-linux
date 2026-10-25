#!/usr/bin/env bats
# Two install layouts: a store's native Linux build (KOTOR 2, Psychonauts),
# which the exe step spots and explains, and side-by-side builds in one
# install (AvP Classic 2000's bin/ and bin_Crossplay/), which game_root:
# extra_exe_folders fill together.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/detection.sh"
    source "$REPO_ROOT/src/game-database.sh"
    source "$REPO_ROOT/src/cache.sh"
    ROOT="$BATS_TEST_TMPDIR/steamapps/common/Test Game"
    mkdir -p "$ROOT"
    GAME_NAME="Test Game"
}

elf() { mkdir -p "$(dirname "$1")"; printf '\x7fELF\x02\x01\x01' > "$1"; chmod +x "$1"; }

@test "install_is_linux_build: ELF and no .exe yes, an .exe or nothing no" {
    elf "$ROOT/bin/game.x86_64"
    install_is_linux_build "$ROOT"
    printf 'MZ' > "$ROOT/bin/game.exe"
    ! install_is_linux_build "$ROOT"
    ! install_is_linux_build "$BATS_TEST_TMPDIR/empty"
    mkdir -p "$BATS_TEST_TMPDIR/data"; printf 'not a program' > "$BATS_TEST_TMPDIR/data/readme"
    ! install_is_linux_build "$BATS_TEST_TMPDIR/data"
}

@test "a Steam Linux build without a beta branch: says so, shows the Proton fix, no root fallback" {
    elf "$ROOT/Psychonauts"
    confirm() { echo "ASK: $1"; [[ "$1" == Find* ]]; }
    run resolve_exe_folder "$ROOT" "" "" steam
    [ "$status" -eq 1 ]
    [[ "$output" == *"Steam installed the Linux version of Test Game"* ]]
    [[ "$output" == *"Force the use of a specific Steam Play compatibility tool"* ]]
    [[ "$output" == *"ASK: Look for Test Game's .exe again?"* ]]
    [[ "$output" != *"install root anyway"* ]]
}

@test "a Steam Linux build with a beta branch names the branch instead" {
    elf "$ROOT/KOTOR2"
    confirm() { [[ "$1" == Find* ]]; }
    run resolve_exe_folder "$ROOT" "legacypc" "" steam
    [[ "$output" == *"'legacypc' beta branch"* ]]
    [[ "$output" != *"Force the use"* ]]
}

@test "a Heroic Linux build says to reinstall with Windows" {
    root="$BATS_TEST_TMPDIR/Games/Test Game"; elf "$root/game.bin"
    confirm() { [[ "$1" == Find* ]]; }
    run resolve_exe_folder "$root" "" ""
    [[ "$output" == *"Heroic installed the Linux version"* ]]
    [[ "$output" == *"Windows chosen as the platform"* ]]
}

@test "looking again after the switch finds the Windows build's folder" {
    elf "$ROOT/game.x86_64"
    # First answer (the retry) swaps the build on disk, as Steam would.
    confirm() {
        if [[ "$1" == "Look for"* ]]; then rm -f "$ROOT/game.x86_64"; mkdir -p "$ROOT/bin"; printf 'MZ' > "$ROOT/bin/Game.exe"; fi
        return 0
    }
    resolve_exe_folder "$ROOT" "" "Game.exe" steam > "$BATS_TEST_TMPDIR/out"
    [ "$GAME_DIR" == "$ROOT/bin" ]
    [ "$(grep -c 'Locate Game Executable' "$BATS_TEST_TMPDIR/out")" -eq 1 ]
}

@test "no .exe and no Linux build keeps the plain warning and root fallback" {
    confirm() { echo "ASK: $1"; [[ "$1" == Find* ]]; }
    run resolve_exe_folder "$ROOT" "" "" steam
    [[ "$output" == *"No .exe files were found"* ]]
    [[ "$output" == *"ASK: Use the install root anyway?"* ]]
}

@test "the exe hint breaks a same-depth tie by byte order: bin before bin_Crossplay" {
    mkdir -p "$ROOT/bin_Crossplay" "$ROOT/bin"
    printf 'MZ' > "$ROOT/bin_Crossplay/AvP_Classic.exe"; printf 'MZ' > "$ROOT/bin/AvP_Classic.exe"
    confirm() { return 0; }
    LC_ALL=en_US.UTF-8 resolve_exe_folder "$ROOT" "" "AvP_Classic.exe" steam > /dev/null
    [ "$GAME_DIR" == "$ROOT/bin" ]
}

extra_db() { # extra_exe_folders JSON array
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    printf '{"schema_version":3,"games":[{"id":"g","name":"G","stores":{"steam":{"id":3730,"extra_exe_folders":%s}},"eax":{"api":"directsound3d"}}]}' "$1" > "$GAME_DATABASE_FILE"
    ensure_game_database() { return 0; }
}

@test "game_root: folders resolve under the install root, skipping the exe folder itself" {
    mkdir -p "$ROOT/bin" "$ROOT/bin_Crossplay"
    extra_db '["game_root:bin","game_root:bin_Crossplay"]'
    GAME_DIR="$ROOT/bin"; GAME_INSTALL_ROOT="$ROOT"
    resolve_extra_exe_folders 3730 steam
    [ "${#EXTRA_GAME_DIRS[@]}" -eq 1 ]
    [ "${EXTRA_GAME_DIRS[0]}" == "$ROOT/bin_Crossplay" ]
    GAME_DIR="$ROOT/bin_Crossplay"
    resolve_extra_exe_folders 3730 steam
    [ "${EXTRA_GAME_DIRS[*]}" == "$ROOT/bin" ]
}

@test "game_root: works without a scanned root, from the steamapps/common path" {
    mkdir -p "$ROOT/bin" "$ROOT/bin_Crossplay"
    extra_db '["game_root:bin_Crossplay"]'
    GAME_DIR="$ROOT/bin"; GAME_INSTALL_ROOT=""
    resolve_extra_exe_folders 3730 steam
    [ "${EXTRA_GAME_DIRS[*]}" == "$ROOT/bin_Crossplay" ]
}

@test "plain entries stay under the exe folder; .. and missing folders are skipped" {
    mkdir -p "$ROOT/FEARXP" "$ROOT/other"
    extra_db '["FEARXP","game_root:../escape","../other","Missing"]'
    GAME_DIR="$ROOT"; GAME_INSTALL_ROOT="$ROOT"
    resolve_extra_exe_folders 3730 steam
    [ "${EXTRA_GAME_DIRS[*]}" == "$ROOT/FEARXP" ]
}
