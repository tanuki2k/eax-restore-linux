#!/usr/bin/env bats
# Database lookups: the alsoft_verified flag, Steam's library folders, the
# installs sharing a prefix, and the scan spinner.

load ../helpers

setup() {
    load_script_functions
    load_src game-database detection cache
    use_temp_home
}

@test "alsoft_verified: only true counts as verified, an absent flag does not" {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"games":[{"id":"g","stores":{"steam":{"id":1}},"install":{"alsoft_ini":{"reverb":{"boost":"6"}},"alsoft_verified":false}},
                      {"id":"h","stores":{"steam":{"id":2}},"install":{"alsoft_ini":{"reverb":{"boost":"6"}}}}]}' > "$GAME_DATABASE_FILE"
    run gdb_jq 1 steam 'entry0 | (.install.alsoft_verified == true)'
    [ "$output" == "false" ]
    run gdb_jq 2 steam 'entry0 | (.install.alsoft_verified == true)'
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

# KOTOR II: an update took EAX out, and the store says which build is
# installed. On the update there's nothing to install until it's rolled back,
# so the install waits with a "Check again?" loop; on the original it carries
# on; when the store can't tell, it warns and lets the player continue.
_rollback_db() {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"games":[{"id":"k","name":"Patched Game",
        "stores":{"steam":{"id":1,"compatibility":"verified","beta_branch":"legacypc","rollback_steps":"Pick the old branch."},
                  "gog":{"id":100,"compatibility":"verified","rollback_builds":["111","222"],"rollback_steps":"Pick the old version."}},
        "eax":{"api":"directsound3d"}}]}' > "$GAME_DATABASE_FILE"
    ensure_game_database() { return 0; }
    prompt_restart_or_quit() { echo "BLOCKED"; }
    SCRIPT_ACTION=i
}

@test "confirm_continue_if_eax_impossible: GOG waits for the rollback, then carries on" {
    _rollback_db
    local root="$BATS_TEST_TMPDIR/game"
    mkdir -p "$root"
    echo '{"buildId": "999"}' > "$root/goggame-100.info"
    # Check again once while still on the update, then the player gives up.
    confirm() {
        echo "ASKED: $*"
        [ -f "$BATS_TEST_TMPDIR/checked" ] && return 1
        touch "$BATS_TEST_TMPDIR/checked"
    }
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"The current build of Patched Game has no EAX"*"Pick the old version."* ]]
    [ "$(grep -c "ASKED: Check again?" <<< "$output")" -eq 2 ]
    [[ "$output" == *BLOCKED* ]]
    [[ "$output" != *"Continue installing anyway"* ]]

    # Rolled back: no question at all.
    confirm() { echo "ASKED: $*"; return 0; }
    echo '{"buildId": "222"}' > "$root/goggame-100.info"
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"Patched Game is on the build that keeps EAX."* ]]
    [[ "$output" != *ASKED* && "$output" != *BLOCKED* ]]

    # GOG didn't record a build: warn and let the player decide.
    echo '{"gameId": "100"}' > "$root/goggame-100.info"
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"An update removed EAX from the current build of Patched Game"*"get it back."*"Pick the old version."* ]]
    [[ "$output" == *"ASKED: Continue installing anyway?"* ]]
}

@test "confirm_continue_if_eax_impossible: Steam waits for the beta branch" {
    _rollback_db
    confirm() { echo "ASKED: $*"; return 1; }
    local acf="$BATS_TEST_TMPDIR/appmanifest_1.acf"
    printf '"AppState"\n{\n\t"appid"\t\t"1"\n}\n' > "$acf"
    run confirm_continue_if_eax_impossible 1 steam "$acf"
    [[ "$output" == *"The current build of Patched Game has no EAX"*"Pick the old branch."* ]]
    [[ "$output" == *"ASKED: Check again?"* && "$output" == *BLOCKED* ]]
    printf '"AppState"\n{\n\t"MountedConfig"\n\t{\n\t\t"BetaKey"\t\t"legacypc"\n\t}\n}\n' > "$acf"
    run confirm_continue_if_eax_impossible 1 steam "$acf"
    [[ "$output" == *"Patched Game is on the build that keeps EAX."* ]]
    [[ "$output" != *BLOCKED* ]]
}

# Picked from the library scan: the same wait runs at once, before "Continue
# with this game?", as the TUI's pop-up does on Enter.
@test "block_if_not_rolled_back: waits at the pick, and spares the prefix step a second look" {
    _rollback_db
    local root="$BATS_TEST_TMPDIR/game"
    mkdir -p "$root"
    echo '{"buildId": "999"}' > "$root/goggame-100.info"
    confirm() { echo "ASKED: $*"; return 1; }
    run block_if_not_rolled_back 100 gog "$root"
    [[ "$output" == *"Patched Game has no EAX"*"Pick the old version."*"ASKED: Check again?"* ]]
    [[ "$output" == *BLOCKED* ]]

    # Rolled back: nothing to say yet, and the prefix step trusts it.
    echo '{"buildId": "111"}' > "$root/goggame-100.info"
    ROLLBACK_CONFIRMED=""
    block_if_not_rolled_back 100 gog "$root" > "$BATS_TEST_TMPDIR/out"
    [ ! -s "$BATS_TEST_TMPDIR/out" ]
    [ "$ROLLBACK_CONFIRMED" == 1 ]
    echo '{"buildId": "999"}' > "$root/goggame-100.info"
    run confirm_continue_if_eax_impossible 100 gog "$root"
    [[ "$output" == *"Patched Game is on the build that keeps EAX."* ]]
    [[ "$output" != *ASKED* ]]

    # The store can't tell: left for the prefix step's warning.
    ROLLBACK_CONFIRMED=""
    echo '{"gameId": "100"}' > "$root/goggame-100.info"
    run block_if_not_rolled_back 100 gog "$root"
    [ -z "$output" ]

    # Steam finds the appmanifest beside the library from the game's folder.
    local game="$BATS_TEST_TMPDIR/SteamLibrary/steamapps/common/Patched"
    mkdir -p "$game"
    printf '"AppState"\n{\n\t"appid"\t\t"1"\n}\n' > "$BATS_TEST_TMPDIR/SteamLibrary/steamapps/appmanifest_1.acf"
    run block_if_not_rolled_back 1 steam "$game"
    [[ "$output" == *"Pick the old branch."*"ASKED: Check again?"* ]]
}

# KOTOR II's long name and steps used to run off the edge as one line.
@test "the rollback warning wraps to the terminal, steps as their own paragraph" {
    _rollback_db
    confirm() { return 1; }
    local name="Star Wars: Knights of the Old Republic II - The Sith Lords"
    jq --arg n "$name" '.games[0].name = $n | .games[0].stores.gog.rollback_steps = "In Heroic, open Modify Installation, then on the Game Version tab tick \"Keep the game at specific version\" and choose Version 1.0b (2019)."' \
        "$GAME_DATABASE_FILE" > "$BATS_TEST_TMPDIR/long.json"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/long.json"
    local root="$BATS_TEST_TMPDIR/game"
    mkdir -p "$root"
    echo '{"buildId": "999"}' > "$root/goggame-100.info"
    run block_if_not_rolled_back 100 gog "$root"
    local plain longest
    plain=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$output")
    longest=$(awk '{ if (length > m) m = length } END { print m }' <<< "$plain")
    [ "$longest" -le 80 ]
    [[ "$plain" == *"removed it."$'\n\n'"  In Heroic, open Modify Installation"* ]]
}

# An unsupported copy stops the install. Without the profile on screen just
# before, the error says why with the store's own problem text, and a copy
# the game's other store sells still installs.
@test "an unsupported store copy is blocked with its problem text; the other store's isn't" {
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    echo '{"games":[{"id":"x","name":"Split Game",
        "stores":{"steam":{"id":1,"compatibility":"unsupported","problem":"The Steam build has no EAX."},
                  "gog":{"id":2,"compatibility":"verified"}},
        "eax":{"api":"directsound3d"}}]}' > "$GAME_DATABASE_FILE"
    ensure_game_database() { return 0; }
    prompt_restart_or_quit() { echo "BLOCKED"; }
    SCRIPT_ACTION=i SCANNED_NOTES_SHOWN=""
    run confirm_continue_if_eax_impossible 1 steam
    [[ "$output" == *"There's nothing for this script to restore in Split Game."*"The Steam build has no EAX."*BLOCKED* ]]
    run confirm_continue_if_eax_impossible 2 gog
    [ -z "$output" ]
    SCANNED_NOTES_SHOWN=1
    run block_if_eax_not_implemented 1 steam "Split Game"
    [[ "$output" == *"There's nothing for this script to restore in Split Game."*BLOCKED* ]]
    [[ "$output" != *"The Steam build has no EAX."* ]]
}
