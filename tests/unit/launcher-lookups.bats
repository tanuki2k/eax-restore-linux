#!/usr/bin/env bats
# Where Steam and Heroic keep their libraries, found through steam_roots and
# heroic_roots (native and Flatpak) instead of fixed paths in each caller.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/detection.sh"
    source "$REPO_ROOT/src/game-database.sh"
    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
}

@test "heroic_installed_records: GOG and Epic spellings, one install_path/app_name line each" {
    mkdir -p "$HOME/.config/heroic/gog_store" "$HOME/.config/heroic/legendaryConfig/legendary"
    printf '{"installed":[{"appName":"111","install_path":"/g/one"},{"appName":"222","install_path":"/g/two"}]}' \
        > "$HOME/.config/heroic/gog_store/installed.json"
    run heroic_installed_records "$HOME/.config/heroic/gog_store/installed.json"
    [ "$output" == $'/g/one\t111\n/g/two\t222' ]
}

@test "heroic_installed_jsons: finds installed.json in native and Flatpak Heroic" {
    mkdir -p "$HOME/.config/heroic/gog_store" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/gog_store"
    : > "$HOME/.config/heroic/gog_store/installed.json"
    : > "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/gog_store/installed.json"
    [ "$(heroic_installed_jsons | wc -l)" -eq 2 ]
}

@test "heroic_installed_jsons: nothing when Heroic isn't installed" {
    [ -z "$(heroic_installed_jsons)" ]
}

@test "steam_library_dirs: the root's own library plus those in libraryfolders.vdf, no repeats" {
    mkdir -p "$HOME/.local/share/Steam/steamapps" "$BATS_TEST_TMPDIR/second/steamapps"
    printf '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"%s"\n\t}\n}\n' \
        "$HOME/.local/share/Steam" "$BATS_TEST_TMPDIR/second" > "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
    run steam_library_dirs
    [ "$output" == "$(printf '%s\n%s' "$HOME/.local/share/Steam/steamapps" "$BATS_TEST_TMPDIR/second/steamapps")" ]
}

@test "steam_library_dirs: also sees ~/.steam/steam and Flatpak's data/Steam layout" {
    mkdir -p "$HOME/.steam/steam/steamapps" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps"
    [ "$(steam_library_dirs | wc -l)" -eq 2 ]
}

@test "heroic_configs_for_prefix: the GamesConfig files naming exactly that prefix, in either Heroic" {
    local n="$HOME/.config/heroic/GamesConfig" f="$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/GamesConfig"
    mkdir -p "$n" "$f"
    printf '{"1":{"winePrefix": "/p/one"}}' > "$n/1.json"
    printf '{"2":{"winePrefix": "/p/one/"}}' > "$f/2.json"
    printf '{"3":{"winePrefix": "/p/one-other"}}' > "$n/3.json"
    printf '{"4":{"winePrefix": "/p/two"}}' > "$n/4.json"
    run heroic_configs_for_prefix /p/one
    [ "$(sort <<< "$output")" == "$(printf '%s\n%s' "$n/1.json" "$f/2.json")" ]
}
