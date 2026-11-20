#!/usr/bin/env bats
# apply_game_settings: writing a planned row, the cases where it skips one, and
# the manifest lines it leaves.

load ../helpers

setup() {
    load_script_functions
    clear_crash_marker() { :; }   # needs a game profile; not what's tested here
    F="$BATS_TEST_TMPDIR/game.ini"
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/manifest"; : > "$INSTALL_MANIFEST"
    PREV_CONFIG_LINES=(); declare -gA PREV_MANIFEST_FILES=()
    GAME_SETTINGS_APPLIED=(); DEPLOY_FAILURES=0
}

# plan_row <path> <section> <key> <new> [state]: one GAME_SETTINGS_PLAN row.
plan_row() {
    local u=$'\x1f'
    echo "audio${u}Turn on EAX${u}$1${u}ini${u}$2${u}$3${u}$4${u}game.ini${u}${6:-}${u}${5:-found}"
}

@test "applies a row, backs the file up once and records the original value" {
    printf '[Sound]\nEAX=0\n' > "$F"
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 1)")
    apply_game_settings >/dev/null
    [ "$(config_get_key "$F" ini Sound EAX)" == "1" ]
    [ "$(cat "$F.eax-restore.bak")" == $'[Sound]\nEAX=0' ]
    local expect=$'CONFIG:audio\tTurn on EAX\t'"$F"$'\tini\tSound\tEAX\t0\t1'
    [ "$(cat "$INSTALL_MANIFEST")" == "$expect" ]
    [ "${GAME_SETTINGS_APPLIED[*]}" == "Turn on EAX" ]
}

@test "a reinstall keeps the original value from the last install's record" {
    printf '[Sound]\nEAX=1\n' > "$F"
    PREV_CONFIG_LINES=($'CONFIG:audio\tTurn on EAX\t'"$F"$'\tini\tSound\tEAX\t0\t1')
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 2)")
    apply_game_settings >/dev/null
    [ "$(cat "$INSTALL_MANIFEST")" == $'CONFIG:audio\tTurn on EAX\t'"$F"$'\tini\tSound\tEAX\t0\t2' ]
}

@test "a file that went missing since the plan is skipped with a warning" {
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 1)")
    run apply_game_settings
    [[ "$output" == *"game.ini has gone missing"*"\"Turn on EAX\" wasn't applied"* ]]
    [ ! -e "$F" ]
    [ ! -s "$INSTALL_MANIFEST" ]
}

@test "a file the plan says to create is created, recorded and written" {
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 1 create)")
    apply_game_settings >/dev/null
    [ "$(config_get_key "$F" ini Sound EAX)" == "1" ]
    [ ! -e "$F.eax-restore.bak" ]
    [ "$(head -1 "$INSTALL_MANIFEST")" == "$F" ]
}

@test "an old value with a tab can't be recorded, so that row is skipped" {
    printf '[Sound]\nEAX=a\tb\n' > "$F"
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 1)")
    run apply_game_settings
    [[ "$output" == *"EAX in game.ini holds a tab or line break"*"wasn't applied there"* ]]
    [ "$(cat "$F")" == $'[Sound]\nEAX=a\tb' ]
    ! grep -q '^CONFIG:' "$INSTALL_MANIFEST"
}

@test "a value that is already set is left alone and not recorded" {
    printf '[Sound]\nEAX=1\n' > "$F"
    GAME_SETTINGS_PLAN=("$(plan_row "$F" Sound EAX 1)")
    apply_game_settings >/dev/null
    ! grep -q '^CONFIG:' "$INSTALL_MANIFEST"
    [ "${#GAME_SETTINGS_APPLIED[@]}" -eq 0 ]
}

@test "a binary_switches flag that isn't 0 or 1 is skipped" {
    printf 'junk' > "$F"
    config_get_key() { echo "maybe"; }
    local u=$'\x1f'
    GAME_SETTINGS_PLAN=("audio${u}T${u}$F${u}binary_switches${u}${u}Flag${u}1${u}game.ini${u}${u}found")
    run apply_game_settings
    [[ "$output" == *"Flag in game.ini isn't a plain on/off value"*"wasn't applied there"* ]]
    [ "$(cat "$F")" == "junk" ]
}
