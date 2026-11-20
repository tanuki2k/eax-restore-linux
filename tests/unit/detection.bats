#!/usr/bin/env bats
# Detection helpers: typed paths, Heroic's records, the registry file, the
# exe scan, and picking an installed game.

load ../helpers

setup() {
    load_script_functions
    load_src game-database detection cache
    use_temp_home
}

@test "heroic_installed_records: a comma in the install path survives" {
    echo '{"installed":[{"install_path":"/g/Test, Part 1/Game","appName":"abc"}]}' > "$BATS_TEST_TMPDIR/installed.json"
    run heroic_installed_records "$BATS_TEST_TMPDIR/installed.json"
    [ "$output" == $'/g/Test, Part 1/Game\tabc' ]
}

@test "clean_typed_path expands only ~ and ~/..." {
    HOME=/home/u
    [ "$(clean_typed_path '~/games')" == "/home/u/games" ]
    [ "$(clean_typed_path '~')" == "/home/u" ]
    [ "$(clean_typed_path '~foo')" == "~foo" ]
}

@test "make_reg_file: a private file in the game folder, removed at exit" {
    GAME_DIR="$BATS_TEST_TMPDIR/game"; mkdir -p "$GAME_DIR"
    TEMP_FILES_AT_EXIT=()
    make_reg_file test
    [ -f "$REG_FILE" ] && [ "$(dirname "$REG_FILE")" == "$GAME_DIR" ]
    [ "${TEMP_FILES_AT_EXIT[0]}" == "$REG_FILE" ]
}

@test "detect_api_from_binary: the profile's exe mentioning DirectSound beats a side DLL naming it" {
    local d="$BATS_TEST_TMPDIR/tron"
    mkdir -p "$d"
    printf 'xx DirectSound xx' > "$d/Lithtech.exe"
    printf 'xx dsound.dll xx' > "$d/binkw32.dll"
    printf 'launcher' > "$d/TRON.exe"
    IFS=$'\x1f' read -r api ds _ < <(detect_api_from_binary "$d" Lithtech.exe)
    [ "$api" == "directsound3d" ]
    [ "$ds" == "Lithtech.exe" ]
}

@test "prompt_installed_game: a number picks the game, M and R set the way out" {
    installed_game_dirs() { printf '%s\n' /g/one /g/two; }
    identify_game_dir() { GAME_ID_NAME="Game ${1##*/}"; GAME_ID_STORE=steam; }
    gui_picker_available() { return 1; }
    MAIN_MENU_SHOWN=1
    prompt_installed_game <<< "2" >/dev/null
    [ "$GAME_DIR" == "/g/two" ]
    run prompt_installed_game <<< "m"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Game one"* && "$output" == *"[R]eturn"* ]]
    prompt_installed_game <<< "m" >/dev/null || true
    [ "$LOCATE_METHOD" == "manual" ]
    prompt_installed_game <<< "r" >/dev/null || true
    [ "$RESTART_REQUESTED" == "1" ]
}

@test "prompt_installed_game: says it is looking, and the list still comes back" {
    installed_game_dirs() { printf '%s\n' /g/one; }
    identify_game_dir() { GAME_ID_NAME="Game one"; GAME_ID_STORE=steam; }
    gui_picker_available() { return 1; }
    MAIN_MENU_SHOWN=1
    run prompt_installed_game <<< "1"
    [[ "$output" == *"Looking for games installed with this script"* && "$output" == *"Game one"* ]]
}

@test "prompt_installed_game: Optional settings and Speaker don't offer Browse or Manually" {
    installed_game_dirs() { printf '%s\n' /g/one; }
    identify_game_dir() { GAME_ID_NAME="Game one"; GAME_ID_STORE=steam; }
    gui_picker_available() { return 0; }
    MAIN_MENU_SHOWN=1
    SETTINGS_TOOL_MODE=speakers
    run prompt_installed_game <<< "1"
    [[ "$output" != *"[M]anually"* && "$output" != *"[B]rowse"* && "$output" == *"[R]eturn"* ]]
    SETTINGS_TOOL_MODE=""
    run prompt_installed_game <<< "1"
    [[ "$output" == *"[M]anually"* && "$output" == *"[B]rowse"* ]]
}
