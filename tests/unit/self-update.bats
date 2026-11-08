#!/usr/bin/env bats
# The start-up check for a newer script: version order, channel, the skips,
# and swapping a verified download over the running file.

load ../helpers

setup() {
    load_script_functions
    SCRIPT_VERSION="0.29"
}

@test "version_is_newer: orders dotted versions numerically" {
    version_is_newer 0.30 0.29
    version_is_newer 0.29 0.28.6
    version_is_newer 1.0 0.99
    ! version_is_newer 0.28.6 0.29
    ! version_is_newer 0.29 0.29
}

@test "script_update_channel: -dev builds follow dev, others stable" {
    [ "$(script_update_channel)" == stable ]
    SCRIPT_VERSION="0.29-dev"
    [ "$(script_update_channel)" == dev ]
}

@test "dev build without a commit in its date has nothing to compare" {
    SCRIPT_VERSION="0.29-dev"; SCRIPT_DATE="2026-08-13"
    ! script_update_available
    SCRIPT_DATE="2026-08-13 build g1a2b3c4-dirty"
    ! script_update_available
}

@test "check_for_script_update: silent when skipped" {
    EAX_RESTORE_SKIP_UPDATE_CHECK=1 run check_for_script_update
    [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "install_script_update: swaps in a download that matches its checksum" {
    local dir="$BATS_TEST_TMPDIR/u"; mkdir "$dir"
    printf '#!/bin/bash\necho new\n' > "$dir/new.sh"
    printf 'echo old\n' > "$dir/run.sh"; chmod 750 "$dir/run.sh"
    ( cd "$dir" && sha256sum new.sh > new.sh.sha256 )
    curl() { case "$*" in *.sha256*) cat "$dir/new.sh.sha256" ;; *) cp "$dir/new.sh" "${@: -1}" ;; esac; }
    fetch_with_progress() { cp "$dir/new.sh" "$2"; }
    install_script_update "http://x/new.sh" "$dir/run.sh"
    grep -q "echo new" "$dir/run.sh"
    [ "$(stat -c %a "$dir/run.sh")" == 750 ]
    [ -z "$(ls -A "$dir" | grep eax-restore-update)" ]
}

@test "install_script_update: a checksum mismatch leaves the script alone" {
    local dir="$BATS_TEST_TMPDIR/u"; mkdir "$dir"
    printf 'echo old\n' > "$dir/run.sh"
    curl() { echo "0000000000000000000000000000000000000000000000000000000000000000  x"; }
    fetch_with_progress() { echo 'echo evil' > "$2"; }
    ! install_script_update "http://x/new.sh" "$dir/run.sh"
    [ "$(cat "$dir/run.sh")" == "echo old" ]
    [ -z "$(ls -A "$dir" | grep eax-restore-update)" ]
}
