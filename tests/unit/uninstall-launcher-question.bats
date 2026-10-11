#!/usr/bin/env bats
# Uninstall step 5's question about the launcher's DLL override.

load ../helpers

setup() {
    load_script_functions
    OVERRIDE_LAUNCHER=steam; OVERRIDE_ID=424242; OVERRIDE_FILE=/x/localconfig.vdf
    GAME_NAME="Test Game"; APPID=424242; LAUNCHER_CHANGE=""; CONFIRM_TIMED_OUT=0
    confirm_countdown() { echo "COUNTDOWN: $1 ($3s)"; CONFIRM_TIMED_OUT="${TIMED_OUT:-0}"; return "${ANSWER:-0}"; }
    confirm() { echo "PLAIN: $1"; return "${ANSWER:-0}"; }
}

@test "Steam open and closable: asks to close and reopen it, with the countdown" {
    launcher_running() { return 0; }; launcher_game_running() { return 1; }; launcher_launch_cmd() { echo steam; }
    run confirm_override_removal "Steam's launch options for Test Game"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam is running"* ]]
    [[ "$output" == *"COUNTDOWN: Close Steam, remove the override, then reopen Steam? (25s)"* ]]
}

@test "saying No leaves the override" {
    launcher_running() { return 0; }; launcher_game_running() { return 1; }; launcher_launch_cmd() { echo steam; }
    ANSWER=1 run confirm_override_removal "Steam's launch options for Test Game"
    [ "$status" -eq 1 ]
}

@test "no answer in time: says what happens, and goes ahead" {
    launcher_running() { return 0; }; launcher_game_running() { return 1; }; launcher_launch_cmd() { echo steam; }
    TIMED_OUT=1 run confirm_override_removal "Steam's launch options for Test Game"
    [ "$status" -eq 0 ]
    [[ "$output" == *"No answer after 25 seconds, so that's a Yes: Steam will be closed, the override removed and Steam reopened once you confirm."* ]]
}

@test "launcher not running: the plain question, no countdown" {
    launcher_running() { return 1; }
    run confirm_override_removal "Steam's launch options for Test Game"
    [ "$output" == "PLAIN: Remove the DLL override from Steam's launch options for Test Game?" ]
}

@test "a game running from the launcher: the plain question (Phase 2 waits for it)" {
    launcher_running() { return 0; }; launcher_game_running() { return 0; }; launcher_launch_cmd() { echo steam; }
    run confirm_override_removal "Steam's launch options for Test Game"
    [[ "$output" == PLAIN:* ]]
}
