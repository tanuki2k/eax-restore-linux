#!/usr/bin/env bats
# The prefix step's checks.

load ../helpers

setup() {
    load_script_functions
    load_src game-database detection cache
    use_temp_home
}

@test "EAX Unified: a game's own eax.dll skips it, an empty dummy or Wine's placeholder does not" {
    source "$REPO_ROOT/src/prefix-steps.sh" 2>/dev/null || true
    GAME_DIR="$BATS_TEST_TMPDIR/game"; PREFIX_PATH="$BATS_TEST_TMPDIR/pfx"
    mkdir -p "$GAME_DIR" "$PREFIX_PATH/drive_c/windows/syswow64"
    ! game_ships_eax_dll
    : > "$GAME_DIR/eax.dll"
    ! game_ships_eax_dll
    printf 'MZ real code' > "$GAME_DIR/EAXUnified.dll"
    game_ships_eax_dll

    ! eax_unified_dll
    printf 'MZ Wine placeholder DLL' > "$PREFIX_PATH/drive_c/windows/syswow64/eax.dll"
    ! eax_unified_dll
    printf 'MZ EAX Unified Interface' > "$PREFIX_PATH/drive_c/windows/syswow64/eax.dll"
    [ "$(eax_unified_dll)" == "$PREFIX_PATH/drive_c/windows/syswow64/eax.dll" ]
}
