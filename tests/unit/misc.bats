#!/usr/bin/env bats
# parse_selection and the speaker answers <-> alsoft.ini values round trip.

load ../helpers

setup() { load_script_functions; source "$REPO_ROOT/src/detection.sh"; source "$REPO_ROOT/src/game-database.sh"; }

sel() { parse_selection "$1" "$2"; local i out=""; for ((i = 1; i <= $1; i++)); do out+="${SELECTED[$i]}"; done; echo "$out"; }

@test "parse_selection: empty input selects everything" {
    [ "$(sel 4 "")" == "1111" ]
}

@test "parse_selection: numbers and ranges narrow the selection" {
    [ "$(sel 5 "1 3")" == "10100" ]
    [ "$(sel 5 "2-4")" == "01110" ]
    [ "$(sel 5 "1,5")" == "10001" ]
}

@test "parse_selection: ^ excludes, whatever the order" {
    [ "$(sel 4 "^2")" == "1011" ]
    [ "$(sel 4 "^2 1-3")" == "1010" ]
    [ "$(sel 4 "1-3 ^2")" == "1010" ]
}

@test "parse_selection: unrecognised tokens are ignored" {
    [ "$(sel 3 "banana 2")" == "010" ]
}

# YES_RE is what the script uses to read y/n answers
@test "speaker values -> alsoft.ini -> speaker answers round-trips" {
    local f="$BATS_TEST_TMPDIR/alsoft.ini" mode ch hrtf
    for mode in "stereo n" "stereo y" "matrix n" "surround n"; do
        set -- $mode
        OUTPUT_MODE="$1"; ENABLE_HRTF="$2"; STEREO_MODE="auto"; SURROUND_CHANNELS="surround51"
        speaker_alsoft_values
        write_file "$f" "[general]\nchannels = $ALSOFT_CHANNELS\nstereo-mode = $STEREO_MODE\nstereo-encoding = $STEREO_ENCODING\n"
        OUTPUT_MODE="" ENABLE_HRTF="" SURROUND_CHANNELS=""
        speaker_config_from_alsoft "$f"
        [ "$OUTPUT_MODE" == "$1" ] || { echo "$mode: mode $OUTPUT_MODE"; return 1; }
        [ "$ENABLE_HRTF" == "$2" ] || { echo "$mode: hrtf $ENABLE_HRTF"; return 1; }
        [ "$1" != surround ] || [ "$SURROUND_CHANNELS" == surround51 ]
    done
}

@test "speaker_config_from_alsoft: a file without channels returns 1" {
    write_file "$BATS_TEST_TMPDIR/a.ini" '[general]\nfoo=1\n'
    run speaker_config_from_alsoft "$BATS_TEST_TMPDIR/a.ini"
    [ "$status" -eq 1 ]
}

@test "speaker_alsoft_values: HRTF off comments hrtf-mode out" {
    OUTPUT_MODE=stereo ENABLE_HRTF=n
    speaker_alsoft_values
    [ "$HRTF_MODE_PREFIX" == "# " ]
    OUTPUT_MODE=stereo ENABLE_HRTF=y
    speaker_alsoft_values
    [ -z "$HRTF_MODE_PREFIX" ]
}

@test "speaker_label: names each configuration" {
    OUTPUT_MODE=surround SURROUND_CHANNELS=surround51; [ "$(speaker_label)" == "Surround 5.1" ]
    OUTPUT_MODE=matrix; [ "$(speaker_label)" == "Matrix encoding" ]
    OUTPUT_MODE=stereo STEREO_MODE=headphones ENABLE_HRTF=y; [ "$(speaker_label)" == "Headphones, HRTF on" ]
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

@test "paged_select: Enter alone is refused when there is no next page" {
    PAGED_LABELS=(a b); PAGED_DETAILS=()
    run paged_select "Games" <<< $'\n2'
    [[ "$output" == *"not a valid option"* ]]
    paged_select "Games" <<< $'\n2' >/dev/null
    [ "$PAGED_CHOICE" == "2" ]
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

@test "scan_with_spinner: keeps what the command printed, arguments intact" {
    scan() { printf '%s\n' "$1" "$2"; }
    scan_with_spinner "Looking" scan "a b" c
    [ "$SCAN_RESULT" == $'a b\nc' ]
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
