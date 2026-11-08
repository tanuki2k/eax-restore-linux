#!/usr/bin/env bats
# Regressions from the second script audit (hardening): quoting helpers,
# symlinked Steam roots, the log's paths, set-aside manifests, self-update
# through a symlink.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    source "$REPO_ROOT/src/detection.sh" 2>/dev/null || true
    source "$REPO_ROOT/src/cache.sh" 2>/dev/null || true
    # logging.sh also starts the run log when sourced, so take just log_cmd.
    source <(sed -n '/^log_cmd()/,/^}/p' "$REPO_ROOT/src/logging.sh")
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

@test "shell_quote: a path with quotes, spaces and \$ survives sh -c" {
    local p="$BATS_TEST_TMPDIR/it's a \$dir \"x\""
    mkdir -p "$p"; touch "$p/f.reg"
    run sh -c "ls $(shell_quote "$p/f.reg")"
    [ "$status" -eq 0 ]
    [ "$output" == "$p/f.reg" ]
}

@test "find_glob_escape: an exe name with brackets matches only itself" {
    local d="$BATS_TEST_TMPDIR/g"; mkdir -p "$d"; touch "$d/Game [GOG].exe" "$d/Game G.exe"
    run find "$d" -type f -iname "$(find_glob_escape 'game [gog].exe')"
    [ "$output" == "$d/Game [GOG].exe" ]
}

@test "steam_library_dirs: a symlinked Steam root isn't listed twice" {
    local real="$BATS_TEST_TMPDIR/ssd/Steam"
    mkdir -p "$real/steamapps" "$HOME/.local/share"
    ln -s "$real" "$HOME/.local/share/Steam"
    printf '"libraryfolders"\n{\n"0"\n{\n"path"\t\t"%s"\n}\n}\n' "$real" > "$real/steamapps/libraryfolders.vdf"
    [ "$(steam_library_dirs | wc -l)" -eq 1 ]
}

@test "log_cmd: shows \$HOME as ~ and leaves a backslash alone" {
    EAX_LOG_FILE="$BATS_TEST_TMPDIR/run.log"
    log_cmd "regedit $HOME/My\\new Game/x.reg"
    grep -qF 'regedit ~/My\new Game/x.reg' "$EAX_LOG_FILE"
}

@test "make_reg_file: a private file in the game folder, removed at exit" {
    GAME_DIR="$BATS_TEST_TMPDIR/game"; mkdir -p "$GAME_DIR"
    TEMP_FILES_AT_EXIT=()
    make_reg_file test
    [ -f "$REG_FILE" ] && [ "$(dirname "$REG_FILE")" == "$GAME_DIR" ]
    [ "${TEMP_FILES_AT_EXIT[0]}" == "$REG_FILE" ]
}

@test "start_manifest: sets the old one aside only when asked" {
    local m="$BATS_TEST_TMPDIR/m.txt"
    printf '%s\n/g/dsound.dll\nCONFIG:x\n' "$MANIFEST_HEADER" > "$m"
    start_manifest "$m"
    [ -z "$MANIFEST_PREV" ] && [ ! -e "$m.prev" ]
    printf '%s\n/g/dsound.dll\nCONFIG:x\n' "$MANIFEST_HEADER" > "$m"
    start_manifest "$m" keep
    [ "$MANIFEST_PREV" == "$m.prev" ] && grep -q '^CONFIG:x' "$m.prev"
    [ "$(cat "$m")" == "$MANIFEST_HEADER" ]
}

@test "install_script_update: a symlinked script stays a symlink and the target is updated" {
    local dir="$BATS_TEST_TMPDIR/u"; mkdir -p "$dir/real" "$dir/bin"
    printf '#!/bin/bash\necho new\n' > "$dir/new.sh"
    printf 'echo old\n' > "$dir/real/run.sh"; chmod 750 "$dir/real/run.sh"
    ln -s "$dir/real/run.sh" "$dir/bin/run.sh"
    ( cd "$dir" && sha256sum new.sh > new.sh.sha256 )
    curl() { cat "$dir/new.sh.sha256"; }
    fetch_with_progress() { cp "$dir/new.sh" "$2"; }
    install_script_update "http://x/new.sh" "$dir/bin/run.sh"
    [ -L "$dir/bin/run.sh" ]
    grep -q "echo new" "$dir/real/run.sh"
}

@test "print_wrapped: written-out escapes in database text stay text" {
    run print_wrapped '\0033[2J and \033[31m and \ec'
    [[ "$output" == *'\0033[2J and \033[31m and \ec'* ]]
    ! printf '%s' "$output" | grep -q $'\x1b\\[2J'
}

@test "end_run_log_for_restart: does nothing when there is no run log" {
    source <(sed -n '/^end_run_log_for_restart()/,/^}/p' "$REPO_ROOT/src/logging.sh")
    run end_run_log_for_restart
    [ "$status" -eq 0 ]
}

@test "build.sh: a src file missing from COMPONENTS stops the build" {
    local w="$BATS_TEST_TMPDIR/b"; mkdir -p "$w"
    cp -r "$REPO_ROOT/src" "$REPO_ROOT/build.sh" "$w/"
    echo '# stray' > "$w/src/not-listed.sh"
    run "$w/build.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-listed.sh"* ]]
}
