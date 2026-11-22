#!/usr/bin/env bats
# Line breaks in the database's long text fields, and the browser profile's
# "Before you play" section of setting follow-ups.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/game-database.json"
    jq '(.games[] | select(.stores.steam.id == 424242)) |=
            (.notes = "First line of the notes.\n\nSecond paragraph."
             | .game_config.audio_settings[0].reason = "Test Game ships with EAX off.\nIt says so twice."
             | .game_config.audio_settings[0].follow_up = "Set your receiver to Dolby Pro Logic.\nThen start the game.")' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$GAME_DATABASE_FILE"
}

plain() { sed 's/\x1b\[[0-9;]*m//g' <<< "$1"; }

@test "wrap_text keeps line breaks and blank lines, and wraps each line" {
    run wrap_text 20 "  " "one two three four five six"$'\x1e\x1e'"seven"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" == "  one two three four" ]
    [ "${lines[1]}" == "  five six" ]
    [ "$output" == "  one two three four"$'\n'"  five six"$'\n\n'"  seven" ]
}

@test "gdb_fields keeps a multi-line field as one record" {
    run gdb_fields 424242 steam '.name // ""' '.notes // ""'
    [ "${#lines[@]}" -eq 1 ]
    IFS=$'\x1f' read -r name notes <<< "$output"
    [ "$name" == "Test Game" ]
    [ "$notes" == "First line of the notes."$'\x1e\x1e'"Second paragraph." ]
}

@test "the profile shows multi-line notes on their own lines" {
    out="$(plain "$(print_game_profile_stores "" steam:424242)")"
    grep -qx "  First line of the notes." <<< "$out"
    grep -qx "  Second paragraph." <<< "$out"
    grep -B1 -x "  Second paragraph." <<< "$out" | head -n 1 | grep -qx ""
}

@test "a multi-line reason still loads as one row per key, and the Tab view shows both lines" {
    rows="$(load_game_config_rows 424242 steam all)"
    while IFS= read -r row; do
        [[ "$row" == audio* || "$row" == optional* ]]
    done <<< "$rows"
    out="$(plain "$(print_game_settings_details "$(jq -r '.games[] | select(.stores.steam.id == 424242) | .id' "$GAME_DATABASE_FILE")")")"
    grep -qx "    Test Game ships with EAX off." <<< "$out"
    grep -qx "    It says so twice." <<< "$out"
    grep -qx "    Then start the game." <<< "$out"
}

@test "the browser profile lists follow-ups under Before you play" {
    out="$(plain "$(print_game_profile_stores "" steam:424242)")"
    grep -A3 "Before you play:" <<< "$out" | grep -qx "  Enable EAX effects"
    grep -qx "  Set your receiver to Dolby Pro Logic." <<< "$out"
    grep -qx "  Then start the game." <<< "$out"
}

@test "the install's profile has no Before you play section" {
    out="$(plain "$(print_game_profile_stores "$BATS_TEST_TMPDIR" steam:424242)")"
    ! grep -q "Before you play" <<< "$out"
}

@test "the browser profile's paragraphs aren't bold, the install's still are" {
    browser="$(print_game_profile_stores "" steam:424242)"
    install="$(print_game_profile_stores "$BATS_TEST_TMPDIR" steam:424242)"
    grep "First line of the notes." <<< "$browser" | grep -vqF $'\033[1;37m'
    grep "First line of the notes." <<< "$install" | grep -qF $'\033[1;37m'
}

# KOTOR II: Steam's beta branch and GOG's older version are different ways
# back, so each store gets a Restore section, straight under Status. A retail
# copy gets one shared section; a community patch stays under Additional steps.
@test "profile: a patched-out game says up front how to restore it" {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/stores.json"
    echo '{"games":[{"id":"p","name":"Patched","stores":{"steam":{"id":1,"rollback_steps":"Pick the old branch.","store_details":"Steam text."},"gog":{"id":2,"rollback_steps":"Pick the old version."}},
                    "eax":{"api":"directsound3d","versions":["3.0"],"status":"removed_by_patch","fix_in_place":true,"problem":"An update took it out."}},
                    {"id":"r","name":"Retail","stores":{"steam":{"id":3},"gog":{"id":4,"rollback_steps":""}},
                    "eax":{"api":"directsound3d","status":"removed_by_patch","fix":"Use the retail copy."}},
                    {"id":"m","name":"Modded","stores":{"steam":{"id":5}},
                    "eax":{"api":"directsound3d","fix":"A community patch adds more."}}]}' > "$GAME_DATABASE_FILE"
    out="$(plain "$(print_game_profile_stores "" steam:1 gog:2)")"
    [[ "$out" == *"3.0 (restorable)"* ]]
    [[ "$out" == *"Status:"*"An update took it out."*"Restore on Steam:"*"Pick the old branch."*"Restore on GOG:"*"Pick the old version."*"Steam details:"* ]]
    [[ "$out" != *"Removed by"* ]]
    [[ "$out" != *"Additional steps"* ]]
    out="$(plain "$(print_game_profile_stores "" steam:3 gog:4)")"
    [[ "$out" == *"(originally supported)"* ]]
    [[ "$out" == *"Status:"*"An update removed EAX from Retail."*"Restore EAX:"*"Use the retail copy."* ]]
    [[ "$out" != *"Restore on"* ]]
    [ "$(grep -c "Use the retail copy." <<< "$out")" -eq 1 ]
    out="$(plain "$(print_game_profile_stores "" steam:5)")"
    [[ "$out" == *"Additional steps:"*"A community patch adds more."* ]]
    [[ "$out" != *"Restore EAX"* ]]
}
