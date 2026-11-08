#!/usr/bin/env bats
# ask_speaker_configuration, read through the numbered menus (no terminal).

load ../helpers

setup() { load_script_functions; source "$REPO_ROOT/src/detection.sh"; source "$REPO_ROOT/src/game-database.sh"; }

# Usage: ask <answers, one per line>; prints the four answers it sets.
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
