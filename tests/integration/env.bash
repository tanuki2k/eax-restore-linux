# Builds a throwaway HOME with a fake Steam library, a Proton prefix, a game and
# pre-seeded DSOAL/OpenAL Soft caches, then runs the real built script in it.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APPID=424242

make_world() {
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_STATE_HOME="$HOME/.local/state" XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share"
    export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"; : > "$STUB_LOG"
    export STUB_PREFIX
    STEAM="$HOME/.local/share/Steam"
    GAME="$STEAM/steamapps/common/Test Game"
    PREFIX="$STEAM/steamapps/compatdata/$APPID/pfx"
    export STUB_PREFIX="$PREFIX"
    mkdir -p "$GAME" "$PREFIX/drive_c/windows/system32" "$PREFIX/drive_c/windows/syswow64" "$STEAM/userdata/1/config"
    cat > "$STEAM/steamapps/libraryfolders.vdf" <<VDF
"libraryfolders"
{
	"0"
	{
		"path"		"$STEAM"
		"apps"
		{
			"$APPID"		"1"
		}
	}
}
VDF
    cat > "$STEAM/steamapps/appmanifest_$APPID.acf" <<ACF
"AppState"
{
	"appid"		"$APPID"
	"name"		"Test Game"
	"installdir"		"Test Game"
}
ACF
    cp "$REPO_ROOT/tests/fixtures/pe32.exe" "$GAME/game.exe"
    printf 'original dsound\n' > "$GAME/dsound.dll"
    printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n' > "$PREFIX/system.reg"
    printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n' > "$PREFIX/user.reg"
    cat > "$STEAM/userdata/1/config/localconfig.vdf" <<VDF
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"$APPID"
					{
						"Playtime"		"3"
					}
				}
			}
		}
	}
}
VDF
    # Caches the script finds ready, so nothing is downloaded (see SKIP_CACHE_CHECK).
    local share="$HOME/.local/share/eax-restore-linux" a d
    for a in Win32 Win64; do
        mkdir -p "$share/dsoal/pinned/DSOAL/$a" "$share/dsoal/pinned/DSOAL+HRTF/$a"
        for d in "$share/dsoal/pinned/DSOAL/$a" "$share/dsoal/pinned/DSOAL+HRTF/$a"; do
            printf 'fake dsound %s\n' "$a" > "$d/dsound.dll"
            printf 'fake aldrv %s\n' "$a" > "$d/dsoal-aldrv.dll"
            printf '[general]\nchannels = stereo\n' > "$d/alsoft.ini"
        done
    done
    mkdir -p "$share/openal-soft/official/openal-soft-test-bin/bin/Win32" "$share/openal-soft/official/openal-soft-test-bin/bin/Win64"
    printf 'fake soft_oal 32\n' > "$share/openal-soft/official/openal-soft-test-bin/bin/Win32/soft_oal.dll"
    printf 'fake soft_oal 64\n' > "$share/openal-soft/official/openal-soft-test-bin/bin/Win64/soft_oal.dll"
    echo "test" > "$share/openal-soft/updated_at.txt"
    export PATH="$REPO_ROOT/tests/fixtures/bin:$PATH"
    export EAX_RESTORE_SKIP_PREFLIGHT=1 EAX_RESTORE_SKIP_CACHE_CHECK=1 EAX_RESTORE_NO_LOG=1
    export TERM=dumb
}

# Usage: snapshot <out file>
# Relative path + sha256 of every file under $HOME the script may touch (games,
# prefixes, launcher config), not its own cache/state (which an uninstall keeps
# on purpose), the manifest (an uninstall leaves an "uninstalled" marker) or the
# one-time <file>.eax-restore.bak copies of launcher/game config it keeps.
snapshot() {
    ( cd "$HOME" && find . -type f ! -name '.eax-restore-manifest.txt' ! -name '*.eax-restore.bak' \
        ! -path './.local/share/eax-restore-linux/*' ! -path './.local/state/*' -print0 \
        | sort -z | xargs -0 -r sha256sum ) > "$1"
}

# Usage: run_script <answers file>
# Runs the built script with the answers on stdin (read_answer takes one per
# prompt; running out of input makes the script exit), output in $OUT. The game
# database is the empty one unless the test set DB_FILE (e.g. the fixture with
# "Test Game" in it).
run_script() {
    OUT="$BATS_TEST_TMPDIR/out.txt"
    if [ -z "${DB_FILE:-}" ]; then
        echo '{"schema_version":3,"games":[]}' > "$BATS_TEST_TMPDIR/db.json"; DB_FILE="$BATS_TEST_TMPDIR/db.json"
    fi
    export EAX_RESTORE_GAME_DATABASE_FILE="$DB_FILE"
    ( cd "$BATS_TEST_TMPDIR" && timeout 120 "$REPO_ROOT/dist/eax-restore-linux.sh" < "$1" > "$OUT" 2>&1 )
}

# Usage: answers <file> <line>...   (an empty argument is Enter)
answers() {
    local f="$1"; shift
    printf '%s\n' "$@" > "$f"
}

# A Steam install of the fake game: Steam's "manually type the path" route,
# every default accepted except the VC++ download (the network is off).
# OVERRIDE_CHOICE picks step 10's DLL override method (default 1: launch options;
# 2: the prefix registry).
install_answers() {
    answers "$1" m "$GAME" \
        "" "" "" \
        "" "" \
        "" "" \
        "" "" \
        "" n \
        "" "" "" \
        "" \
        "${OVERRIDE_CHOICE:-}" \
        "" \
        ""
}

# Usage: uninstall_answers <file>
# Main menu [U]ninstall, the one installed game, every default accepted.
uninstall_answers() {
    answers "$1" u 1 "" "" "" "" "" ""
}

# The same install for a game that has a profile in the fixture database:
# adds the API confirmation, Game Audio Settings (apply) and Optional Game
# Settings (review: y, pick #1 "Skip intro movies"). The last Enter is spare: a typed pick
# is followed by an "Apply?" question in some versions of the script, not others.
profile_install_answers() {
    answers "$1" m "$GAME" \
        "" "" "" \
        "" "" \
        "" "" \
        "" \
        "" n \
        "" "" "" \
        "" \
        "" \
        "" "" \
        y 1 \
        "" "" ""
}

# Usage: make_profile_world
# make_world plus the fixture database and a CRLF settings.ini in the game.
make_profile_world() {
    make_world
    DB_FILE="$REPO_ROOT/tests/fixtures/game-database.json"
    printf '[Audio]\r\nUseEAX=0\r\nProvider=Auto\r\n[Video]\r\nWidth=640\r\n' > "$GAME/settings.ini"
}

# Uninstall of a game whose install changed its settings: one more question,
# which settings to put back ($2: Enter = all, n = none, or numbers).
uninstall_profile_answers() {
    answers "$1" u 1 "" "" "" "" "" "${2:-}" ""
}

# Usage: make_heroic_world
# A GOG game in Heroic instead of Steam: library entry, GamesConfig with its
# own prefix, the game under ~/Games/Heroic. Same caches and stubs as make_world.
HEROIC_ID=987654321
make_heroic_world() {
    make_world
    rm -rf "$STEAM"
    local conf="$HOME/.config/heroic"
    GAME="$HOME/Games/Heroic/Test Game"
    PREFIX="$HOME/Games/Heroic/Prefixes/Test Game"
    export STUB_PREFIX="$PREFIX"
    mkdir -p "$GAME" "$PREFIX/drive_c/windows/system32" "$PREFIX/drive_c/windows/syswow64" \
        "$conf/gog_store" "$conf/GamesConfig"
    cp "$REPO_ROOT/tests/fixtures/pe32.exe" "$GAME/game.exe"
    printf 'original dsound\n' > "$GAME/dsound.dll"
    printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n' > "$PREFIX/system.reg"
    printf 'WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n' > "$PREFIX/user.reg"
    cat > "$conf/gog_store/installed.json" <<JSON
{
  "installed": [
    {
      "appName": "$HEROIC_ID",
      "install_path": "$GAME",
      "platform": "windows"
    }
  ]
}
JSON
    # Heroic writes JSON.stringify(..., null, 2), which is jq's own layout, and
    # no trailing newline.
    jq -n --arg id "$HEROIC_ID" --arg p "$PREFIX" '{version: "v0"} + {($id): {
            winePrefix: $p, wineVersion: {name: "Wine-GE", type: "wine"},
            enviromentOptions: [{key: "FOO", value: "1"}]}}' \
        | { out="$(cat)"; printf '%s' "$out"; } > "$conf/GamesConfig/$HEROIC_ID.json"
    printf '{\n  "defaultSettings": {}\n}\n' > "$conf/config.json"
}

# Heroic has no AppID step, so one prompt fewer in launcher identification.
heroic_install_answers() {
    answers "$1" m "$GAME" \
        "" "" \
        "" "" \
        "" "" \
        "" "" \
        "" n \
        "" "" "" \
        "" \
        "" \
        "" \
        ""
}

# Uninstall of the Heroic game: prefix identification takes two answers.
heroic_uninstall_answers() {
    answers "$1" u 1 "" "" "" "" ""
}
