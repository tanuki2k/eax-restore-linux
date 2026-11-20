#!/usr/bin/env bats
# Uninstall Phase 2's question before closing the launcher to remove its DLL override.

load ../helpers

setup() {
    load_script_functions
    OVERRIDE_LAUNCHER=steam; OVERRIDE_ID=424242; OVERRIDE_FILE=/x/localconfig.vdf
    GAME_NAME="Test Game"; APPID=424242; LAUNCHER_CHANGE=""; CONFIRM_TIMED_OUT=0
    confirm_countdown() { echo "COUNTDOWN: $1 ($3s)"; CONFIRM_TIMED_OUT="${TIMED_OUT:-0}"; return "${ANSWER:-0}"; }
    launcher_game_running() { return 1; }; launcher_launch_cmd() { echo steam; }
    run_with_spinner() { return 0; }; _close_launcher_and_wait() { return 0; }
    log_cmd() { :; }
}

@test "asks to close and reopen the launcher, with the countdown" {
    run offer_close_launcher steam remove
    [ "$status" -eq 0 ]
    [[ "$output" == *"Steam is running"* ]]
    [[ "$output" == *"COUNTDOWN: Close Steam, remove the override, then reopen Steam? (25s)"* ]]
}

@test "saying No skips the override" {
    ANSWER=1 offer_close_launcher steam remove || true
    [ "$LAUNCHER_CLOSE_DECLINED" -eq 1 ]
}

@test "no answer in time: says so, and closes it" {
    TIMED_OUT=1 run offer_close_launcher steam remove
    [ "$status" -eq 0 ]
    [[ "$output" == *"No answer after 25 seconds, so closing Steam."* ]]
}
