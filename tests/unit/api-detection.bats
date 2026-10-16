#!/usr/bin/env bats
# The no-profile detection: which folder the exe scan offers first, and which
# audio API the file scan reports.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/detection.sh"
    GAME="$BATS_TEST_TMPDIR/Stalker Test"
    mkdir -p "$GAME/bin"
}

creative_dll() { printf 'MZ Generic Software Generic Hardware wrap_oal\n' > "$1"; }
soft_dll()     { printf 'MZ OpenAL Soft ALSOFT_DRIVERS\n' > "$1"; }
scan()         { detect_api_from_binary "$GAME" | tr '\037' '|'; }

@test "is_openal_soft_dll: OpenAL Soft yes, Creative's router no" {
    soft_dll "$BATS_TEST_TMPDIR/soft.dll"; creative_dll "$BATS_TEST_TMPDIR/creative.dll"
    is_openal_soft_dll "$BATS_TEST_TMPDIR/soft.dll"
    ! is_openal_soft_dll "$BATS_TEST_TMPDIR/creative.dll"
    ! is_openal_soft_dll "$BATS_TEST_TMPDIR/missing.dll"
}

@test "an engine naming both APIs is OpenAL when the game ships Creative's OpenAL32.dll" {
    printf 'MZ dsound.dll OpenAL32.dll\n' > "$GAME/bin/xrSound.dll"
    creative_dll "$GAME/bin/OpenAL32.dll"
    [ "$(scan)" == "openal|bin/xrSound.dll|bin/OpenAL32.dll" ]
}

@test "the same engine stays 'both' when the OpenAL32.dll is OpenAL Soft (ours)" {
    printf 'MZ dsound.dll OpenAL32.dll\n' > "$GAME/bin/xrSound.dll"
    soft_dll "$GAME/bin/OpenAL32.dll"
    [[ "$(scan)" == both\|* ]]
}

@test "an engine naming both APIs stays 'both' without a shipped OpenAL32.dll" {
    printf 'MZ dsound.dll OpenAL32.dll\n' > "$GAME/bin/xrSound.dll"
    [[ "$(scan)" == both\|* ]]
}

@test "a DirectSound-only game is untouched by a shipped OpenAL32.dll" {
    printf 'MZ dsound.dll\n' > "$GAME/game.exe"
    creative_dll "$GAME/OpenAL32.dll"
    [ "$(scan)" == "directsound3d|game.exe|" ]
}

@test "folder_names_audio_api: the engine folder yes, the launcher folder no" {
    printf 'MZ launcher only\n' > "$GAME/launcher.exe"
    printf 'MZ dsound.dll\n' > "$GAME/bin/engine.exe"
    ! folder_names_audio_api "$GAME"
    folder_names_audio_api "$GAME/bin"
}

@test "folder_names_audio_api: our own DLLs don't count" {
    soft_dll "$GAME/bin/OpenAL32.dll"; printf 'MZ dsound.dll\n' > "$GAME/bin/dsound.dll"
    ! folder_names_audio_api "$GAME/bin"
}

@test "the exe scan offers the engine's bin/ before a root with only a launcher" {
    printf 'MZ prelaunch\n' > "$GAME/xrPreLaunch.exe"
    printf 'MZ dsound.dll OpenAL32.dll\n' > "$GAME/bin/XR_3DA.exe"
    confirm() { return 0; }
    GAME_NAME="Stalker Test"
    resolve_exe_folder "$GAME" "" "" > "$BATS_TEST_TMPDIR/out"
    [ "$GAME_DIR" == "$GAME/bin" ]
}

@test "the exe scan keeps a root that holds the engine itself" {
    printf 'MZ dsound.dll\n' > "$GAME/game.exe"
    printf 'MZ tools\n' > "$GAME/bin/editor.exe"
    confirm() { return 0; }
    GAME_NAME="Stalker Test"
    resolve_exe_folder "$GAME" "" "" > "$BATS_TEST_TMPDIR/out"
    [ "$GAME_DIR" == "$GAME" ]
}
