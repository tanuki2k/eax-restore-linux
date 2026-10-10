#!/usr/bin/env bats
# parse_selection and the speaker answers <-> alsoft.ini values round trip.

load ../helpers

setup() { load_script_functions; }

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
