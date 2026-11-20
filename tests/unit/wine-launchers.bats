#!/usr/bin/env bats
# Finding games beyond Steam's and Heroic's own lists: Snap Steam, Heroic under
# XDG_CONFIG_HOME, the games Lutris, Bottles and Faugus run (their exe, prefix
# and Wine build), the launcher's exe and junk folders in the exe ranking, and
# the prefix step for those games.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/detection.sh"
    source "$REPO_ROOT/src/game-database.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    unset XDG_DATA_HOME XDG_CONFIG_HOME
    mkdir -p "$HOME"
    log_cmd() { :; }
}

# Usage: runner <path to bin/wine>
runner() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n' > "$1"; chmod +x "$1"; }

# A Lutris game whose exe path is relative to its folder (only pga.db says
# which), with a ~ prefix and the Wine version set for every Wine game.
lutris_game() {
    local data="$HOME/.local/share/lutris"
    mkdir -p "$HOME/Games/Deus Ex/System" "$data/games" "$HOME/.config/lutris/runners"
    : > "$HOME/Games/Deus Ex/System/DeusEx.exe"
    runner "$data/runners/wine/wine-ge-8/bin/wine"
    printf 'game:\n  exe: System/DeusEx.exe\n  prefix: ~/pfx/deus\nwine:\n  dxvk: true\n' > "$data/games/deus-ex-1700.yml"
    printf 'wine:\n  version: wine-ge-8\n' > "$HOME/.config/lutris/runners/wine.yml"
    sqlite3 "$data/pga.db" "CREATE TABLE games (id INTEGER PRIMARY KEY, name TEXT, slug TEXT, runner TEXT, directory TEXT, installed INTEGER, configpath TEXT);
        INSERT INTO games VALUES (1, 'Deus Ex: GOTY', 'deus-ex', 'wine', '~/Games/Deus Ex', 1, 'deus-ex-1700');
        INSERT INTO games VALUES (2, 'Not Installed', 'gone', 'wine', '~/Games/Gone', 0, 'gone-1');
        INSERT INTO games VALUES (3, 'Native', 'tux', 'linux', '~/Games/Tux', 1, 'tux-1');"
}

bottles_game() {
    local root="$HOME/.local/share/bottles"
    mkdir -p "$HOME/Games/Thief" "$root/bottles/Gaming/drive_c"
    : > "$HOME/Games/Thief/THIEF.EXE"
    runner "$root/runners/soda-9/bin/wine"
    cat > "$root/bottles/Gaming/bottle.yml" <<YML
Arch: win64
External_Programs:
  a1:
    executable: THIEF.EXE
    name: 'Thief: Gold'
    path: $HOME/Games/Thief/THIEF.EXE
  c3:
    name: Old
    path: $HOME/Games/Thief/THIEF.EXE
    removed: true
Name: Gaming
Runner: soda-9
YML
}

faugus_game() {
    local tools="$HOME/.local/share/Steam/compatibilitytools.d" list="$HOME/.local/share/faugus-launcher"
    mkdir -p "$HOME/Games/Rune/System" "$HOME/Games/Sq5" "$list" "$HOME/.config/faugus-launcher"
    : > "$HOME/Games/Rune/System/Rune.exe"; : > "$HOME/Games/Sq5/Play Space Quest V.exe"
    runner "$tools/GE-Proton9-20/files/bin/wine"
    runner "$tools/GE-Proton10-1/files/bin/wine"
    runner "$tools/Proton-CachyOS Latest/files/bin/wine"
    printf '{"default-prefix": "%s/Faugus", "default-runner": "Proton-CachyOS Latest"}' "$HOME" > "$HOME/.config/faugus-launcher/config.json"
    printf '[{"gameid":"rune","title":"Rune","path":"%s","prefix":"%s/Faugus/rune","runner":"GE-Proton"},
             {"gameid":"play-space-quest-v","title":"Play Space Quest V","path":"%s","prefix":"","runner":"Default"},
             {"gameid":"tux","title":"Tux","path":"%s","runner":"Linux-Native"}]' \
        "$HOME/Games/Rune/System/Rune.exe" "$HOME" "$HOME/Games/Sq5/Play Space Quest V.exe" "$HOME/Games/Rune/System/Rune.exe" > "$list/games.json"
}

@test "Snap Steam is one of the Steam installs" {
    mkdir -p "$HOME/snap/steam/common/.local/share/Steam/steamapps"
    run steam_roots
    [ "$output" == "$(printf 'snap\t%s' "$HOME/snap/steam/common/.local/share/Steam")" ]
}

@test "Heroic's config folder follows XDG_CONFIG_HOME, and a relative value is ignored" {
    mkdir -p "$BATS_TEST_TMPDIR/cfg/heroic" "$HOME/.config/heroic"
    XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg" run heroic_roots
    [ "$output" == "$(printf 'native\t%s' "$BATS_TEST_TMPDIR/cfg/heroic")" ]
    XDG_CONFIG_HOME="cfg" run heroic_roots
    [ "$output" == "$(printf 'native\t%s' "$HOME/.config/heroic")" ]
}

@test "Lutris, Bottles and Faugus games come with their exe, prefix and Wine build" {
    lutris_game; bottles_game; faugus_game
    run wine_launcher_records
    [ "$status" -eq 0 ]
    local tools="$HOME/.local/share/Steam/compatibilitytools.d"
    [ "${output//$'\x1f'/|}" == "$(printf '%s\n' \
        "Lutris|Deus Ex: GOTY|$HOME/Games/Deus Ex/System/DeusEx.exe|$HOME/pfx/deus|$HOME/.local/share/lutris/runners/wine/wine-ge-8/bin/wine" \
        "Bottles|Thief: Gold|$HOME/Games/Thief/THIEF.EXE|$HOME/.local/share/bottles/bottles/Gaming|$HOME/.local/share/bottles/runners/soda-9/bin/wine" \
        "Faugus|Rune|$HOME/Games/Rune/System/Rune.exe|$HOME/Faugus/rune|$tools/GE-Proton10-1/files/bin/wine" \
        "Faugus|Play Space Quest V|$HOME/Games/Sq5/Play Space Quest V.exe|$HOME/Faugus/default|$tools/Proton-CachyOS Latest/files/bin/wine")" ]
}

@test "without sqlite3, Lutris games come from their YAML files alone" {
    lutris_game
    # An absolute exe path still works; the relative one needs pga.db's folder.
    mkdir -p "$HOME/Games/Thief2"; : > "$HOME/Games/Thief2/thief2.exe"
    printf 'game:\n  exe: "%s"\n' "$HOME/Games/Thief2/thief2.exe" > "$HOME/.local/share/lutris/games/thief-ii-the-metal-age-1800.yml"
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    local f
    for f in awk sed jq basename dirname cat sort tail cut head tr uname realpath readlink; do ln -s "$(command -v "$f")" "$BATS_TEST_TMPDIR/bin/$f"; done
    PATH="$BATS_TEST_TMPDIR/bin" run _lutris_records
    [ "${output//$'\x1f'/|}" == "Lutris|Thief Ii The Metal Age|$HOME/Games/Thief2/thief2.exe||$HOME/.local/share/lutris/runners/wine/wine-ge-8/bin/wine" ]
}

@test "the scan lists Lutris, Bottles and Faugus games, by GOG ID or by the database's exe" {
    lutris_game; bottles_game; faugus_game
    printf '{"gameId":"1207658"}' > "$HOME/Games/Thief/goggame-1207658.info"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    cat > "$GAME_DATABASE_FILE" <<'JSON'
{"schema_version":3,"games":[
 {"id":"deusex","name":"Deus Ex","exe":"deusex.exe","stores":{"steam":{"id":6910},"gog":{"id":1207658995}}},
 {"id":"thief","name":"Thief Gold","exe":"Thief.exe","stores":{"gog":{"id":1207658}}},
 {"id":"rune","name":"Rune","exe":"Rune.exe","stores":{"steam":{"id":210950}}}
]}
JSON
    ensure_game_database() { return 0; }
    MAIN_MENU_SHOWN=""
    paged_select() {
        { printf '%s\n' "${PAGED_LABELS[@]}"; printf -- '--\n'; printf '%s\n' "${PAGED_DETAILS[@]}"; } > "$BATS_TEST_TMPDIR/listed"
        PAGED_CHOICE=m
    }
    run scan_game_libraries
    [ "$status" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/listed")" == "$(printf '%s\n' 'Deus Ex' 'Rune' 'Thief Gold' -- '(Lutris)' '(Faugus)' '(Bottles)')" ]
}

@test "the launcher's exe ranks right after the database's, and junk folders are never searched" {
    local root="$HOME/Games/Painkiller"
    mkdir -p "$root/Bin" "$root/Data" "$root/_CommonRedist/painkiller" "$HOME/.config/heroic/gog_store"
    : > "$root/Bin/Painkiller.exe"; : > "$root/Data/Editor.exe"; : > "$root/_CommonRedist/painkiller/painkiller.exe"
    printf '{"installed":[{"appName":"1","install_path":"%s","executable":"Data/Editor.exe"}]}' "$root" > "$HOME/.config/heroic/gog_store/installed.json"
    run launcher_exe_for_root "$root/"
    [ "$output" == "$root/Data/Editor.exe" ]
    cands() {
        local root="$1" exe_hint="$2" launcher_exe="$3" root_norm d
        root_norm="$(normalize_game_name "$(basename "$root")")"
        local -a cand_dirs=(); local -A cand_exe_name=()
        _exe_collect_candidates
        for d in "${cand_dirs[@]}"; do printf '%s|%s\n' "${d#"$root"/}" "${cand_exe_name[$d]}"; done
    }
    run cands "$root" "" "$root/Data/Editor.exe"
    [ "$output" == "$(printf '%s\n' 'Data|Editor.exe' 'Bin|Painkiller.exe')" ]
    run cands "$root" "Painkiller.exe" "$root/Data/Editor.exe"
    [ "$output" == "$(printf '%s\n' 'Bin|Painkiller.exe' 'Data|Editor.exe')" ]
}

@test "a game Lutris runs gets Lutris's prefix and its Wine build" {
    lutris_game
    mkdir -p "$HOME/pfx/deus/drive_c"
    GAME_DIR="$HOME/Games/Deus Ex/System"; GAME_NAME="Deus Ex"; PREFIX_PATH=""
    HEROIC_GAME_ID=""; WINE_CMD="/usr/bin/wine"
    confirm() { return 0; }
    local attempt_auto_detect=1
    _env_find_wine_launcher_prefix > "$BATS_TEST_TMPDIR/out"
    [ "$WINE_LAUNCHER" == "Lutris" ]
    [ "$PREFIX_PATH" == "$HOME/pfx/deus" ]
    grep -q "Found in Lutris" "$BATS_TEST_TMPDIR/out"
    resolve_heroic_runner > "$BATS_TEST_TMPDIR/out"
    [ "$WINE_CMD" == "$HOME/.local/share/lutris/runners/wine/wine-ge-8/bin/wine" ]
    [ "$HEROIC_RUNNER_TYPE" == "wine" ]
    grep -q "Lutris launches Deus Ex with: wine-ge-8" "$BATS_TEST_TMPDIR/out"
    # Nothing for Heroic's settings file to hold, so the override goes in the registry.
    LAUNCHER_TYPE=2
    ! launcher_override_target
}

@test "a Faugus game on Proton is labelled Proton, and a missing build keeps the default Wine" {
    faugus_game
    GAME_DIR="$HOME/Games/Rune/System"; GAME_NAME="Rune"; PREFIX_PATH=""; HEROIC_GAME_ID=""; WINE_CMD="/usr/bin/wine"
    confirm() { return 0; }
    local attempt_auto_detect=1
    _env_find_wine_launcher_prefix > /dev/null
    resolve_heroic_runner > /dev/null
    [ "$(runner_label)" == "Proton" ]
    rm -r "$HOME/.local/share/Steam/compatibilitytools.d"
    WINE_CMD="/usr/bin/wine"
    _env_find_wine_launcher_prefix > /dev/null
    run resolve_heroic_runner
    [ "$status" -eq 1 ]
    [[ "$output" == *"Couldn't find the Wine version Faugus runs Rune with, so /usr/bin/wine will be used instead."* ]]
}

@test "a game none of them runs leaves the prefix to be typed, and forgets an earlier game's Wine" {
    lutris_game
    GAME_DIR="$HOME/Games/Other"; PREFIX_PATH=""; HEROIC_GAME_ID=""
    WINE_LAUNCHER="Lutris"; WINE_LAUNCHER_WINE="/stale/bin/wine"
    local attempt_auto_detect=1
    _env_find_wine_launcher_prefix
    [ -z "$WINE_LAUNCHER" ]
    [ -z "$WINE_LAUNCHER_WINE" ]
    [ -z "$PREFIX_PATH" ]
}

@test "an install in a Lutris game's folder is listed as installed" {
    lutris_game
    printf 'FILE: x\n' > "$HOME/Games/Deus Ex/System/.eax-restore-manifest.txt"
    run find_installed_game_dirs
    [ "$output" == "$HOME/Games/Deus Ex/System" ]
}

@test "an older Faugus that kept games.json beside config.json is still read" {
    faugus_game
    mv "$HOME/.local/share/faugus-launcher/games.json" "$HOME/.config/faugus-launcher/games.json"
    run _faugus_records
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "Faugus runners resolve the way Faugus resolves them" {
    local tools="$HOME/.local/share/Steam/compatibilitytools.d" sys="$BATS_TEST_TMPDIR/share"
    mkdir -p "$HOME/.local/share/Steam/steamapps"
    runner "$tools/UMU-Proton-9.0-3/files/bin/wine"
    runner "$tools/UMU-Proton-10.0-1/files/bin/wine"
    runner "$tools/Proton-CachyOS Latest/files/bin/wine"
    runner "$sys/steam/compatibilitytools.d/proton-cachyos-slr/files/bin/wine"
    runner "$BATS_TEST_TMPDIR/my-proton/files/bin/wine"
    run faugus_runner_wine "" "Proton-CachyOS Latest"
    [ "$output" == "$tools/UMU-Proton-10.0-1/files/bin/wine" ]
    run faugus_runner_wine "Default" "Proton-CachyOS Latest"
    [ "$output" == "$tools/Proton-CachyOS Latest/files/bin/wine" ]
    XDG_DATA_DIRS="/nowhere:$sys" run faugus_runner_wine "Proton-CachyOS" "x"
    [ "$output" == "$sys/steam/compatibilitytools.d/proton-cachyos-slr/files/bin/wine" ]
    run faugus_runner_wine "$BATS_TEST_TMPDIR/my-proton" "x"
    [ "$output" == "$BATS_TEST_TMPDIR/my-proton/files/bin/wine" ]
    run faugus_runner_wine "Missing" "x"
    [ -z "$output" ]
}

@test "an older Faugus's config.ini gives the default runner and prefix" {
    faugus_game
    rm "$HOME/.config/faugus-launcher/config.json"
    printf 'default-prefix="~/Prefixes"\ndefault-runner="GE-Proton9-20"\n' > "$HOME/.config/faugus-launcher/config.ini"
    run _faugus_records
    [[ "${output//$'\x1f'/|}" == *"|Play Space Quest V|$HOME/Games/Sq5/Play Space Quest V.exe|$HOME/Prefixes/default|$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton9-20/files/bin/wine"* ]]
}

@test "Lutris Wine versions resolve the way Lutris resolves them" {
    local tools="$HOME/.local/share/Steam/compatibilitytools.d" wd="$HOME/.local/share/lutris/runners/wine"
    mkdir -p "$HOME/.local/share/Steam/steamapps" "$BATS_TEST_TMPDIR/bin"
    runner "$tools/GE-Proton9-20/files/bin/wine"
    runner "$tools/GE-Proton10-1/files/bin/wine"
    runner "$tools/Proton-Custom/files/bin/wine"; : > "$tools/Proton-Custom/proton"
    runner "$wd/lutris-7/bin/wine"
    runner "$BATS_TEST_TMPDIR/bin/wine"
    runner "$BATS_TEST_TMPDIR/mywine/bin/wine"
    run lutris_wine_for "" "$wd"
    [ "$output" == "$tools/GE-Proton10-1/files/bin/wine" ]
    run lutris_wine_for "ge-proton" "$wd"
    [ "$output" == "$tools/GE-Proton10-1/files/bin/wine" ]
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run lutris_wine_for "system" "$wd"
    [ "$output" == "$BATS_TEST_TMPDIR/bin/wine" ]
    run lutris_wine_for "custom" "$wd" "$BATS_TEST_TMPDIR/mywine/bin/wine"
    [ "$output" == "$BATS_TEST_TMPDIR/mywine/bin/wine" ]
    run lutris_wine_for "Proton-Custom" "$wd"
    [ "$output" == "$tools/Proton-Custom/files/bin/wine" ]
    run lutris_wine_for "lutris-7" "$wd"
    [ "$output" == "$wd/lutris-7/bin/wine" ]
    # Not installed: Lutris falls back to its default, the newest GE-Proton.
    run lutris_wine_for "lutris-gone" "$wd"
    [ "$output" == "$tools/GE-Proton10-1/files/bin/wine" ]
}

@test "lutris.conf's runner_dir moves Lutris's Wine builds" {
    lutris_game
    mkdir -p "$HOME/.config/lutris"
    printf '[lutris]\nrunner_dir = ~/Runners\n' > "$HOME/.config/lutris/lutris.conf"
    runner "$HOME/Runners/wine/wine-ge-8/bin/wine"
    run _lutris_records
    [[ "${output//$'\x1f'/|}" == *"|$HOME/Runners/wine/wine-ge-8/bin/wine" ]]
}

@test "Bottles: sys- runners use the system Wine, Custom_Path may be text, and Steam bottles are left out" {
    bottles_game
    local yml="$HOME/.local/share/bottles/bottles/Gaming/bottle.yml"
    mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/Elsewhere"
    runner "$BATS_TEST_TMPDIR/bin/wine"
    sed -i "s|^Runner: soda-9|Runner: sys-wine-9.0\nCustom_Path: '$BATS_TEST_TMPDIR/Elsewhere'\nPath: $BATS_TEST_TMPDIR/Elsewhere|" "$yml"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run _bottles_records
    [ "${output//$'\x1f'/|}" == "Bottles|Thief: Gold|$HOME/Games/Thief/THIEF.EXE|$BATS_TEST_TMPDIR/Elsewhere|$BATS_TEST_TMPDIR/bin/wine" ]
    printf 'Environment: Steam\n' >> "$yml"
    run _bottles_records
    [ -z "$output" ]
}
