#!/usr/bin/env bats
# speakers_match: a Stereo → Headphones answer picks a game's own headphones
# setting over its stereo one, and still gets the stereo one when the game
# has no headphones setting.

load ../helpers

setup() {
    load_script_functions
}

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
