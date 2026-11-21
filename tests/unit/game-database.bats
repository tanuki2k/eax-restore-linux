#!/usr/bin/env bats
# Database lookups: the alsoft_tested flag, Steam's library folders, the
# installs sharing a prefix, and the scan spinner.

load ../helpers

setup() {
    load_script_functions
    load_src game-database detection cache
    use_temp_home
}

@test "alsoft_tested: only true counts as verified, an absent flag does not" {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"games":[{"id":"g","stores":{"steam":{"id":1}},"install":{"alsoft_ini":{"reverb":{"boost":"6"}},"alsoft_tested":false}},
                      {"id":"h","stores":{"steam":{"id":2}},"install":{"alsoft_ini":{"reverb":{"boost":"6"}}}}]}' > "$GAME_DATABASE_FILE"
    run gdb_jq 1 steam 'entry0 | (.install.alsoft_tested == true)'
    [ "$output" == "false" ]
    run gdb_jq 2 steam 'entry0 | (.install.alsoft_tested == true)'
    [ "$output" == "false" ]
}

@test "games_sharing_prefix: other installs with files in the same prefix" {
    mkdir -p "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" "$BATS_TEST_TMPDIR/c"
    printf '%s\n' "/p/pfx/drive_c/windows/syswow64/dsound.dll" > "$BATS_TEST_TMPDIR/a/.eax-restore-manifest.txt"
    printf '%s\n' "/p/pfx/drive_c/windows/syswow64/dsound.dll" > "$BATS_TEST_TMPDIR/b/.eax-restore-manifest.txt"
    printf '%s\n' "/q/pfx/drive_c/windows/syswow64/dsound.dll" > "$BATS_TEST_TMPDIR/c/.eax-restore-manifest.txt"
    find_installed_game_dirs() { printf '%s\n' "$BATS_TEST_TMPDIR/a" "$BATS_TEST_TMPDIR/b" "$BATS_TEST_TMPDIR/c"; }
    run games_sharing_prefix /p/pfx "$BATS_TEST_TMPDIR/a"
    [ "$output" == "$BATS_TEST_TMPDIR/b" ]
}

@test "steam_library_dirs: a symlinked Steam root isn't listed twice" {
    local real="$BATS_TEST_TMPDIR/ssd/Steam"
    mkdir -p "$real/steamapps" "$HOME/.local/share"
    ln -s "$real" "$HOME/.local/share/Steam"
    printf '"libraryfolders"\n{\n"0"\n{\n"path"\t\t"%s"\n}\n}\n' "$real" > "$real/steamapps/libraryfolders.vdf"
    [ "$(steam_library_dirs | wc -l)" -eq 1 ]
}

@test "scan_with_spinner: keeps what the command printed, arguments intact" {
    scan() { printf '%s\n' "$1" "$2"; }
    scan_with_spinner "Looking" scan "a b" c
    [ "$SCAN_RESULT" == $'a b\nc' ]
}

@test "detect_gog_build_id: the buildId GOG records, nothing without one" {
    local root="$BATS_TEST_TMPDIR/game"
    mkdir -p "$root"
    printf '{\n  "buildId": "52315880824487880",\n  "gameId": "100"\n}\n' > "$root/goggame-100.info"
    [ "$(detect_gog_build_id "$root" 100)" == "52315880824487880" ]
    echo '{"gameId": "100"}' > "$root/goggame-100.info"
    [ -z "$(detect_gog_build_id "$root" 100)" ]
    [ -z "$(detect_gog_build_id "$root" 200)" ]
}

# KOTOR II on GOG: a player already rolled back to a build the database lists
# can skip the warning that the current build has no EAX.
@test "confirm_continue_if_eax_impossible: a GOG install on a rollback build skips the warning" {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"games":[{"id":"k","name":"Patched Game","stores":{"gog":{"id":100,"rollback_builds":["111","222"],"rollback_steps":"Pick the old version."}},
        "eax":{"status":"removed_by_patch","fix_in_place":true}}]}' > "$GAME_DATABASE_FILE"
    ensure_game_database() { return 0; }
    prompt_restart_or_quit() { echo "BLOCKED"; }
    confirm() { echo "ASKED: $*"; return 0; }
    SCRIPT_ACTION=i
    local root="$BATS_TEST_TMPDIR/game"
    mkdir -p "$root"
    echo '{"buildId": "222"}' > "$root/goggame-100.info"
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"You're on GOG build 222."* ]]
    [[ "$output" == *"ASKED: This build keeps EAX intact, so skip the warning that an update removed it?"* ]]
    [[ "$output" != *"An update removed EAX"* ]]

    echo '{"buildId": "999"}' > "$root/goggame-100.info"
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"You're on GOG build 999."* ]]
    [[ "$output" == *"An update removed EAX from the current build of Patched Game, but you can get it back. Pick the old version."* ]]
    [[ "$output" == *"ASKED: Continue installing anyway?"* ]]
}
