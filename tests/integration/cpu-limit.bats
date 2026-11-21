#!/usr/bin/env bats
# The limit_cpu_threads tweak: a game flagged in its profile gets
# WINE_CPU_TOPOLOGY in its Steam launch options or Heroic environment
# variables, but only on a PC with more than 8 threads, and uninstall takes it
# out again.

load env

LIMIT='WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7'

# Usage: fake_threads <n>
fake_threads() {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho %s\n' "$1" > "$BATS_TEST_TMPDIR/bin/nproc"
    chmod +x "$BATS_TEST_TMPDIR/bin/nproc"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# The fixture database's Test Game, flagged, on Steam and in Heroic.
cpu_db() {
    DB_FILE="$BATS_TEST_TMPDIR/cpudb.json"
    jq --argjson h "$HEROIC_ID" '.games[0].install = {tweaks: ["limit_cpu_threads"]}
        | .games[0].stores.gog = {id: $h} | .games[0].game_config = null' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$DB_FILE"
}

# Usage: cpu_install_answers <file> [CPU answer] [override method]
# A Steam install of the flagged game. On a PC with 8 threads or fewer the
# CPU question isn't asked and its answer lands on the next default prompt.
cpu_install_answers() {
    answers "$1" m "" "$GAME" \
        "" "" "" \
        "" "" \
        "" "" \
        "" "" \
        "" n \
        "" "" "" \
        "${2:-}" \
        "" \
        "${3:-}" \
        "" \
        "" "" ""
}

launch_options() {
    sed -n 's/.*"LaunchOptions"[[:space:]]*"\(.*\)"$/\1/p' "$STEAM/userdata/1/config/localconfig.vdf"
}

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
}

@test "steam, 16 threads: the limit goes in the launch options and the manifest, and uninstall takes it out" {
    make_world; fake_threads 16; cpu_db
    snapshot "$BATS_TEST_TMPDIR/before"
    cpu_install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    grep -q "Limit Test Game to 8 CPU threads?" "$OUT"
    sed 's/\x1b\[[0-9;]*m//g' "$OUT" | grep -q "Advanced tweaks: Limit to 8 CPU threads"
    [[ "$(launch_options)" == *"$LIMIT %command%"* ]] || { launch_options; false; }
    grep "^LAUNCHER:steam" "$GAME/.eax-restore-manifest.txt" | grep -qF "$LIMIT"
    uninstall_answers "$BATS_TEST_TMPDIR/un"; run_script "$BATS_TEST_TMPDIR/un"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -25 "$OUT"; false; }
}

@test "steam, 8 threads: no question and no limit" {
    make_world; fake_threads 8; cpu_db
    cpu_install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    ! grep -q "CPU threads?" "$OUT"
    [[ "$(launch_options)" != *WINE_CPU_TOPOLOGY* ]]
}

@test "steam, 16 threads, answered No: no limit" {
    make_world; fake_threads 16; cpu_db
    cpu_install_answers "$BATS_TEST_TMPDIR/in" n
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    sed 's/\x1b\[[0-9;]*m//g' "$OUT" | grep -q "Advanced tweaks: None"
    [[ "$(launch_options)" != *WINE_CPU_TOPOLOGY* ]]
    ! grep -q "still needs its CPU thread limit" "$OUT"
}

@test "steam, override in the registry: the limit is shown to add by hand" {
    make_world; fake_threads 16; cpu_db
    cpu_install_answers "$BATS_TEST_TMPDIR/in" "" 2
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    [[ "$(launch_options)" != *WINE_CPU_TOPOLOGY* ]]
    grep -q "still needs its CPU thread limit" "$OUT"
    grep -qF "$LIMIT" "$OUT"
}

@test "heroic, 16 threads: the limit is its own variable, recorded, and uninstall removes only what it added" {
    make_heroic_world; fake_threads 16; cpu_db
    local conf="$HOME/.config/heroic/GamesConfig/$HEROIC_ID.json"
    snapshot "$BATS_TEST_TMPDIR/before"
    answers "$BATS_TEST_TMPDIR/in" m "" "$GAME" \
        "" "" \
        "" "" \
        "" "" \
        "" "" \
        "" n \
        "" "" "" \
        "" \
        "" \
        "" \
        "" \
        "" "" ""
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    [ "$(jq -r --arg a "$HEROIC_ID" '.[$a].enviromentOptions[] | select(.key=="WINE_CPU_TOPOLOGY") | .value' "$conf")" == "8:0,1,2,3,4,5,6,7" ]
    grep -q "^LAUNCHERENV:heroic" "$GAME/.eax-restore-manifest.txt"
    heroic_uninstall_answers "$BATS_TEST_TMPDIR/un"; run_script "$BATS_TEST_TMPDIR/un"
    grep -q "Removed the CPU thread limit" "$OUT" || { tail -25 "$OUT"; false; }
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -25 "$OUT"; false; }
}
