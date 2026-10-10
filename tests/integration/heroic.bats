#!/usr/bin/env bats
# A GOG game launched through Heroic: prefix found from Heroic's own config,
# the DLL override goes into the game's environment variables, uninstall
# restores everything.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_heroic_world
    CONF="$HOME/.config/heroic/GamesConfig/$HEROIC_ID.json"
}

install_heroic() {
    heroic_install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
}

@test "install deploys to the game folder and the prefix Heroic uses" {
    install_heroic
    [ "$(cat "$GAME/dsoal-aldrv.dll")" == "fake soft_oal 32" ]
    [ "$(cat "$PREFIX/drive_c/windows/syswow64/dsound.dll")" == "fake dsound Win32" ]
    grep -q "dsoal-aldrv.dll" "$GAME/.eax-restore-manifest.txt"
}

@test "install adds WINEDLLOVERRIDES to the game's Heroic settings and keeps the rest" {
    install_heroic
    [ "$(jq -r --arg a "$HEROIC_ID" '.[$a].enviromentOptions[] | select(.key=="WINEDLLOVERRIDES") | .value' "$CONF")" == "dsound=n,b" ]
    [ "$(jq -r --arg a "$HEROIC_ID" '.[$a].enviromentOptions[] | select(.key=="FOO") | .value' "$CONF")" == "1" ]
    [ "$(jq -r --arg a "$HEROIC_ID" '.[$a].winePrefix' "$CONF")" == "$PREFIX" ]
    grep -q "^LAUNCHER:heroic" "$GAME/.eax-restore-manifest.txt"
}

@test "uninstall restores the game, the prefix and Heroic's settings byte for byte" {
    snapshot "$BATS_TEST_TMPDIR/before"
    install_heroic
    heroic_uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -25 "$OUT"; false; }
}

@test "uninstall removes only the override and keeps the player's other variables" {
    install_heroic
    heroic_uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    [ "$(jq -r --arg a "$HEROIC_ID" '[.[$a].enviromentOptions[].key] | join(",")' "$CONF")" == "FOO" ]
}
