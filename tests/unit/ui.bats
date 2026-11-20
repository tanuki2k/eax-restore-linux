#!/usr/bin/env bats
# ui.sh: the titled box, numbered menus and wrapped text.

load ../helpers

setup() {
    load_script_functions
}

strip() { sed -e 's/\x1b\[[0-9;]*m//g'; }

# ---- print_titled_box --------------------------------------------------------
# print_titled_box draws a frame as wide as the dividers with the title in its
# top edge, and the install summary puts settings' follow-ups in one.

@test "every line of the box is as wide as a divider" {
    run print_titled_box "$YELLOW" "Before you play" "${BOLD}Enable EAX" "  Some text."
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
    GAME_SETTINGS_APPLIED=("Enable EAX")
    GAME_SETTINGS_FOLLOW_UPS=("Enable EAX"$'\x1f'"If there's no music when Jedi Academy starts, open the console with Shift + ~, type snd_restart and press Enter.")
    GAME_SETTINGS_MISSING=() GAME_SETTINGS_DECLINED=() GAME_SETTINGS_ABSENT=()
    run print_game_settings_summary
    output="$(strip <<< "$output")"
    [[ "$output" == *"╭─ Before you play"* ]]
    [[ "$output" == *"│ Enable EAX "*"│"* ]]
    [[ "$output" == *"│   If there's no music"* ]]
    [[ "$output" != *$'\n    If there'* ]]
}

@test "no box when no applied setting has a follow-up" {
    GAME_SETTINGS_APPLIED=("Enable EAX")
    GAME_SETTINGS_FOLLOW_UPS=()
    GAME_SETTINGS_MISSING=() GAME_SETTINGS_DECLINED=() GAME_SETTINGS_ABSENT=()
    run print_game_settings_summary
    [[ "$output" != *"Before you play"* ]]
}

# ---- menus and wrapped text --------------------------------------------------

@test "paged_select: 08 and 09 are decimal, not a bad octal number" {
    PAGED_LABELS=(a b c d e f g h i j); PAGED_DETAILS=()
    paged_select "Games" <<< "08" >/dev/null
    [ "$PAGED_CHOICE" == "8" ]
    [ "$((PAGED_CHOICE - 1))" == "7" ]
}

@test "paged_select: Enter alone is refused when there is no next page" {
    PAGED_LABELS=(a b); PAGED_DETAILS=()
    run paged_select "Games" <<< $'\n2'
    [[ "$output" == *"not a valid option"* ]]
    paged_select "Games" <<< $'\n2' >/dev/null
    [ "$PAGED_CHOICE" == "2" ]
}

@test "print_wrapped: written-out escapes in database text stay text" {
    run print_wrapped '\0033[2J and \033[31m and \ec'
    [[ "$output" == *'\0033[2J and \033[31m and \ec'* ]]
    ! printf '%s' "$output" | grep -q $'\x1b\\[2J'
}
