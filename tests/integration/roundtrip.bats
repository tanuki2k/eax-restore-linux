#!/usr/bin/env bats
# Installs into a fake Steam world with the real built script, then checks the
# result; the uninstall half is in the same file.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
}

@test "install deploys DSOAL to the game folder and prefix, with a manifest" {
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    [ "$(cat "$GAME/dsoal-aldrv.dll")" == "fake soft_oal 32" ]
    [ "$(cat "$GAME/dsound.dll")" == "fake dsound Win32" ]
    ls "$GAME"/dsound.dll.bak.* >/dev/null
    [ "$(cat "$PREFIX/drive_c/windows/syswow64/dsound.dll")" == "fake dsound Win32" ]
    [ -f "$GAME/.eax-restore-manifest.txt" ]
    grep -q "dsoal-aldrv.dll" "$GAME/.eax-restore-manifest.txt"
}

@test "install writes the DLL override into Steam's launch options" {
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q 'LaunchOptions.*WINEDLLOVERRIDES=\\"dsound=n,b\\" %command%' "$STEAM/userdata/1/config/localconfig.vdf" || { tail -30 "$OUT"; false; }
    grep -q '^LAUNCHER:' "$GAME/.eax-restore-manifest.txt"
}

@test "uninstall puts every file back exactly as it was before the install" {
    snapshot "$BATS_TEST_TMPDIR/before"
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    snapshot "$BATS_TEST_TMPDIR/installed"
    ! diff -q "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/installed" >/dev/null   # the install did something
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    snapshot "$BATS_TEST_TMPDIR/after"
    diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after" || { tail -20 "$OUT"; false; }
}

@test "uninstall leaves the 'uninstalled' marker and no backups behind" {
    install_answers "$BATS_TEST_TMPDIR/in"; run_script "$BATS_TEST_TMPDIR/in"
    uninstall_answers "$BATS_TEST_TMPDIR/un"; run_script "$BATS_TEST_TMPDIR/un"
    grep -q "uninstalled" "$GAME/.eax-restore-manifest.txt"
    ! ls "$GAME"/*.bak.* 2>/dev/null
}

@test "a 64-bit game gets the Win64 builds, in the game folder and system32" {
    cp "$REPO_ROOT/tests/fixtures/pe64.exe" "$GAME/game.exe"
    install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "Detected Architecture: 64-bit" <(sed 's/\x1b\[[0-9;]*m//g' "$OUT") || { tail -30 "$OUT"; false; }
    [ "$(cat "$GAME/dsound.dll")" == "fake dsound Win64" ]
    [ "$(cat "$GAME/dsoal-aldrv.dll")" == "fake soft_oal 64" ]
    [ "$(cat "$PREFIX/drive_c/windows/system32/dsound.dll")" == "fake dsound Win64" ]
}

@test "registry route: the override lands in the prefix's user.reg, not in Steam's options" {
    OVERRIDE_CHOICE=2 install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    grep -q '^"dsound"="native,builtin"$' "$PREFIX/user.reg"
    grep -q '^\[Software\\\\Wine\\\\DllOverrides\]' "$PREFIX/user.reg"
    grep -q '^REGISTRY:OVERRIDE:dsound' "$GAME/.eax-restore-manifest.txt"
    ! grep -q '^LAUNCHER:' "$GAME/.eax-restore-manifest.txt"
    ! grep -q LaunchOptions "$STEAM/userdata/1/config/localconfig.vdf"
}

@test "registry route: uninstall takes the override out and restores the tree" {
    snapshot "$BATS_TEST_TMPDIR/before"
    OVERRIDE_CHOICE=2 install_answers "$BATS_TEST_TMPDIR/in"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q '"dsound"=' "$PREFIX/user.reg"
    uninstall_answers "$BATS_TEST_TMPDIR/un"
    run_script "$BATS_TEST_TMPDIR/un"
    ! grep -q '"dsound"=' "$PREFIX/user.reg"
    snapshot "$BATS_TEST_TMPDIR/after"
    # user.reg keeps the emptied DllOverrides key, as regedit leaves it; the rest is identical
    diff <(grep -v 'pfx/user.reg' "$BATS_TEST_TMPDIR/before") <(grep -v 'pfx/user.reg' "$BATS_TEST_TMPDIR/after") || { tail -25 "$OUT"; false; }
}
