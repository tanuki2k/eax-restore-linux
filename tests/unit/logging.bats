#!/usr/bin/env bats
# The run log's helpers.

load ../helpers

setup() {
    load_script_functions
    load_src game-database detection cache
    use_temp_home
    # logging.sh also starts the run log when sourced, so take just log_cmd.
    source <(sed -n '/^log_cmd()/,/^}/p' "$REPO_ROOT/src/logging.sh")
}

@test "log_cmd: shows \$HOME as ~ and leaves a backslash alone" {
    EAX_LOG_FILE="$BATS_TEST_TMPDIR/run.log"
    log_cmd "regedit $HOME/My\\new Game/x.reg"
    grep -qF 'regedit ~/My\new Game/x.reg' "$EAX_LOG_FILE"
}

@test "end_run_log_for_restart: does nothing when there is no run log" {
    source <(sed -n '/^end_run_log_for_restart()/,/^}/p' "$REPO_ROOT/src/logging.sh")
    run end_run_log_for_restart
    [ "$status" -eq 0 ]
}
