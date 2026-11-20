#!/usr/bin/env bats
# The speaker setup in game-config.sh: matching a game's speaker settings,
# the alsoft.ini values, and the speaker questions.

load ../helpers

setup() {
    load_script_functions
}

# ---- speakers_match ----------------------------------------------------------
# speakers_match: a Stereo → Headphones answer picks a game's own headphones
# setting over its stereo one, and still gets the stereo one when the game
# has no headphones setting.

@test "headphones answer skips stereo when the game has a headphones setting" {
    OUTPUT_MODE=stereo STEREO_MODE=headphones
    ! speakers_match stereo 1
    speakers_match headphones 1
}

@test "headphones answer still matches stereo when the game has no headphones setting" {
    OUTPUT_MODE=stereo STEREO_MODE=headphones
    speakers_match stereo ""
}

@test "speakers and auto answers match stereo, not headphones" {
    OUTPUT_MODE=stereo
    for STEREO_MODE in speakers auto; do
        speakers_match stereo 1
        ! speakers_match headphones 1
    done
}

@test "surround layouts are unaffected" {
    OUTPUT_MODE=surround SURROUND_CHANNELS=surround51 STEREO_MODE=""
    speakers_match surround 1
    speakers_match quad,surround51 1
    ! speakers_match stereo 1
}

# ---- alsoft.ini speaker values -----------------------------------------------

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

# ---- ask_speaker_configuration -----------------------------------------------

ask() {
    ask_speaker_configuration <<< "$1" >/dev/null
    echo "$OUTPUT_MODE|${STEREO_MODE:-}|${ENABLE_HRTF:-}|${SURROUND_CHANNELS:-}"
}

@test "speaker questions: stereo on speakers turns HRTF off without asking" {
    [ "$(ask $'1\n2')" == "stereo|speakers|n|" ]
}

@test "speaker questions: stereo on headphones asks about HRTF" {
    [ "$(ask $'1\n3\ny')" == "stereo|headphones|y|" ]
    [ "$(ask $'1\n3\nn')" == "stereo|headphones|n|" ]
}

@test "speaker questions: surround asks for the layout" {
    [ "$(ask $'2\n1')" == "surround|||quad" ]
    [ "$(ask $'2\n4')" == "surround|||surround71" ]
}

@test "speaker questions: matrix asks nothing more" {
    [ "$(ask $'3')" == "matrix|||" ]
}

@test "speaker questions: Enter keeps what Tools read from the current setup" {
    OUTPUT_MODE=surround SURROUND_CHANNELS=surround61
    [ "$(ask $'\n\n')" == "surround|||surround61" ]
    OUTPUT_MODE=stereo STEREO_MODE=speakers
    [ "$(ask $'\n\n')" == "stereo|speakers|n|" ]
}
