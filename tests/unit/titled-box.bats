#!/usr/bin/env bats
# print_titled_box draws a frame as wide as the dividers with the title in its
# top edge, and the install summary puts settings' follow-ups in one.

load ../helpers

setup() {
    load_script_functions
}

strip() { sed -e 's/\x1b\[[0-9;]*m//g'; }

@test "every line of the box is as wide as a divider" {
    run print_titled_box "$YELLOW" "Before you play" "${BOLD}Enable EAX reverb" "  Some text."
    [ "$status" -eq 0 ]
    local width line
    width=$(print_divider | strip | awk '{ print length }')
    while IFS= read -r line; do
        [ "$(printf '%s' "$line" | strip | awk '{ print length }')" -eq "$width" ]
    done <<< "$output"
    [[ "$(head -n 1 <<< "$output" | strip)" == "╭─ Before you play ─"*"╮" ]]
}

@test "the summary puts a follow-up in the box, not under its tick" {
    GAME_NAME="Jedi Academy"
    GAME_SETTINGS_APPLIED=("Enable EAX reverb")
    GAME_SETTINGS_FOLLOW_UPS=("Enable EAX reverb"$'\x1f'"If there's no music when Jedi Academy starts, open the console with Shift + ~, type snd_restart and press Enter.")
    GAME_SETTINGS_MISSING=() GAME_SETTINGS_DECLINED=() GAME_SETTINGS_ABSENT=()
    run print_game_settings_summary
    output="$(strip <<< "$output")"
    [[ "$output" == *"╭─ Before you play"* ]]
    [[ "$output" == *"│ Enable EAX reverb "*"│"* ]]
    [[ "$output" == *"│   If there's no music"* ]]
    [[ "$output" != *$'\n    If there'* ]]
}

@test "no box when no applied setting has a follow-up" {
    GAME_SETTINGS_APPLIED=("Enable EAX reverb")
    GAME_SETTINGS_FOLLOW_UPS=()
    GAME_SETTINGS_MISSING=() GAME_SETTINGS_DECLINED=() GAME_SETTINGS_ABSENT=()
    run print_game_settings_summary
    [[ "$output" != *"Before you play"* ]]
}
