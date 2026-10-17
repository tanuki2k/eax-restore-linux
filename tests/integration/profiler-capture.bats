#!/usr/bin/env bats
# The profiler's capture install: it hands the script a database with just the
# game's exe and API (no Game Settings), and types the folder the exe is in.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
    # Like S.T.A.L.K.E.R.: the exe is in bin/, not the install root.
    mkdir -p "$GAME/bin"
    mv "$GAME/game.exe" "$GAME/bin/Game.exe"
    rm -f "$GAME/dsound.dll"
}

# Usage: capture_install <directsound3d|openal>
capture_install() {
    DB_FILE="$BATS_TEST_TMPDIR/capture-db.json"
    python3 -I - "$REPO_ROOT/tools/profiler" "$GAME" "$APPID" "$1" "$DB_FILE" "$BATS_TEST_TMPDIR/in" <<'PY'
import sys; sys.path.insert(0, sys.argv[1])
import capture
root, appid, api, db, answers = sys.argv[2:7]
game = {"store": "steam", "id": appid, "dir": root}
profile = {"name": "Test Game", "exe": "game.exe", "api": api, "versions": ["2.0"]}
open(db, "w").write(capture.profile_db(game, profile))
open(answers, "w").write("\n".join(capture.install_answers(capture.find_exe_dir(root, "game.exe"), "steam")) + "\n")
PY
    # As the profiler runs it: DSOAL_PIN skips the main menu.
    EAX_RESTORE_DSOAL_PIN=1 run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -40 "$OUT"; false; }
}

@test "an OpenAL game gets OpenAL32.dll, next to the exe in bin/" {
    capture_install openal
    [ "$(cat "$GAME/bin/OpenAL32.dll")" == "fake soft_oal 32" ]
    [ ! -e "$GAME/OpenAL32.dll" ]
    [ ! -e "$GAME/bin/dsoal-aldrv.dll" ]
    # the registry route, so a running Steam is left alone
    grep -q '"openal32"="native,builtin"' "$PREFIX/user.reg" || { grep -i openal "$PREFIX/user.reg"; false; }
    ! grep -q WINEDLLOVERRIDES "$STEAM/userdata/1/config/localconfig.vdf"
}

@test "a DirectSound3D game gets DSOAL, next to the exe in bin/" {
    capture_install directsound3d
    [ "$(cat "$GAME/bin/dsoal-aldrv.dll")" == "fake soft_oal 32" ]
    [ ! -e "$GAME/dsound.dll" ]
}
