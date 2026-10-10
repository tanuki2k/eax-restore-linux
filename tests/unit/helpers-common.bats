#!/usr/bin/env bats
# Small shared helpers in common.sh.

load ../helpers

setup() { load_script_functions; F="$BATS_TEST_TMPDIR/file"; }

@test "acf_value: reads name and installdir, ignoring indentation and other keys" {
    printf '"AppState"\n{\n\t"appid"\t\t"42"\n\t"name"\t\t"Half-Life: Source"\n\t"installdir"\t\t"Half-Life 2"\n}\n' > "$F"
    [ "$(acf_value "$F" name)" == "Half-Life: Source" ]
    [ "$(acf_value "$F" installdir)" == "Half-Life 2" ]
}

@test "acf_value: a missing key or file gives nothing" {
    printf '"AppState"\n{\n\t"appid"\t\t"42"\n}\n' > "$F"
    [ -z "$(acf_value "$F" name)" ]
    [ -z "$(acf_value "$BATS_TEST_TMPDIR/none" name)" ]
}

@test "acf_value: takes only the first match" {
    printf '\t"name"\t\t"One"\n\t"name"\t\t"Two"\n' > "$F"
    [ "$(acf_value "$F" name)" == "One" ]
}

@test "manifest_is_uninstalled: true only for the marker's first line" {
    echo "# EAX Restore: uninstalled on 2026-01-01T00:00:00Z. Nothing left to remove." > "$F"
    manifest_is_uninstalled "$F"
    printf '# EAX Restore manifest, format 2\n/a/dsound.dll\n' > "$F"
    ! manifest_is_uninstalled "$F"
    printf '/a/dsound.dll\n# EAX Restore: uninstalled later\n' > "$F"
    ! manifest_is_uninstalled "$F"
}

@test "manifest_is_uninstalled: a missing or empty file is not the marker" {
    ! manifest_is_uninstalled "$BATS_TEST_TMPDIR/none"
    : > "$F"
    ! manifest_is_uninstalled "$F"
}

@test "swap_in: replaces the target and keeps its permissions" {
    printf 'old\n' > "$F"; chmod 640 "$F"
    printf 'new\n' > "$F.tmp"
    swap_in "$F.tmp" "$F"
    [ "$(cat "$F")" == "new" ]
    [ "$(stat -c %a "$F")" == "640" ]
    [ ! -e "$F.tmp" ]
}

@test "swap_in: a target that does not exist yet is just created" {
    printf 'new\n' > "$F.tmp"
    swap_in "$F.tmp" "$F"
    [ "$(cat "$F")" == "new" ]
}

@test "swap_in: a failed move removes the temp file and returns 1" {
    printf 'new\n' > "$F.tmp"
    run swap_in "$F.tmp" "$BATS_TEST_TMPDIR/no/such/dir/file"
    [ "$status" -eq 1 ]
    [ ! -e "$F.tmp" ]
}
