#!/usr/bin/env bats
# Launch-option text handling (WINEDLLOVERRIDES merge, DSOAL log variables),
# Steam localconfig.vdf and Heroic GamesConfig editing.

load ../helpers

setup() {
    load_script_functions
    F="$BATS_TEST_TMPDIR/file"
}

# ---- merge_dll_override ----------------------------------------------------

@test "merge_dll_override: empty list gets just the rule" {
    [ "$(merge_dll_override "" dsound)" == "dsound=n,b" ]
}

@test "merge_dll_override: keeps other rules and appends ours" {
    [ "$(merge_dll_override "winmm=n,b" dsound)" == "winmm=n,b;dsound=n,b" ]
}

@test "merge_dll_override: replaces an earlier rule for the same DLL, any case" {
    [ "$(merge_dll_override "DSOUND=n;winmm=n" dsound)" == "winmm=n;dsound=n,b" ]
}

@test "merge_dll_override: drops the DLL from a grouped rule, keeps the rest" {
    [ "$(merge_dll_override "dsound,winmm=n,b" dsound)" == "winmm=n,b;dsound=n,b" ]
}

# ---- launch_options_with_override ------------------------------------------

@test "launch options: empty becomes override plus %command%" {
    [ "$(launch_options_with_override "" dsound)" == 'WINEDLLOVERRIDES="dsound=n,b" %command%' ]
}

@test "launch options: existing %command% line keeps its other parts" {
    [ "$(launch_options_with_override 'FOO=1 %command% -windowed' dsound)" \
        == 'WINEDLLOVERRIDES="dsound=n,b" FOO=1 %command% -windowed' ]
}

@test "launch options: bare arguments are moved after %command%" {
    [ "$(launch_options_with_override '-windowed' dsound)" == 'WINEDLLOVERRIDES="dsound=n,b" %command% -windowed' ]
}

@test "launch options: merges into a quoted WINEDLLOVERRIDES in place" {
    [ "$(launch_options_with_override 'A=1 WINEDLLOVERRIDES="winmm=n" %command%' dsound)" \
        == 'A=1 WINEDLLOVERRIDES="winmm=n;dsound=n,b" %command%' ]
}

@test "launch options: merges into an unquoted WINEDLLOVERRIDES" {
    [ "$(launch_options_with_override 'WINEDLLOVERRIDES=winmm=n %command%' dsound)" \
        == 'WINEDLLOVERRIDES="winmm=n;dsound=n,b" %command%' ]
}

# ---- DSOAL log variables ---------------------------------------------------

@test "dsoal log: added right before %command%" {
    [ "$(launch_options_with_dsoal_log 'A=1 %command%' 3 'Z:/g/dsoal.log')" \
        == 'A=1 DSOAL_LOGLEVEL=3 DSOAL_LOGFILE="Z:/g/dsoal.log" %command%' ]
}

@test "dsoal log: empty options get %command% added" {
    [ "$(launch_options_with_dsoal_log '' 1 'Z:/x')" == 'DSOAL_LOGLEVEL=1 DSOAL_LOGFILE="Z:/x" %command%' ]
}

@test "dsoal log: replaces earlier variables rather than duplicating" {
    local once twice
    once="$(launch_options_with_dsoal_log 'A=1 %command%' 1 'Z:/x')"
    twice="$(launch_options_with_dsoal_log "$once" 2 'Z:/y')"
    [ "$twice" == 'A=1 DSOAL_LOGLEVEL=2 DSOAL_LOGFILE="Z:/y" %command%' ]
}

@test "dsoal log: removing handles bare, double- and single-quoted values" {
    [ "$(launch_options_without_dsoal_log "DSOAL_LOGLEVEL=1 DSOAL_LOGFILE='a b' X=1 %command%")" == 'X=1 %command%' ]
    [ "$(launch_options_without_dsoal_log 'X=1 DSOAL_LOGFILE="a b" %command%')" == 'X=1 %command%' ]
}

@test "dsoal log: add then remove restores the original options" {
    local orig='WINEDLLOVERRIDES="dsound=n,b" %command% -x'
    [ "$(launch_options_without_dsoal_log "$(launch_options_with_dsoal_log "$orig" 3 'Z:/g/dsoal.log')")" == "$orig" ]
}

@test "dsoal log paths: Z: maps back to /, bare names sit in the game folder" {
    GAME_DIR=/games/x
    [ "$(dsoal_log_path_for_wine /games/x)" == "Z:/games/x/dsoal.log" ]
    [ "$(dsoal_log_path_for_linux 'Z:\games\x\dsoal.log')" == "/games/x/dsoal.log" ]
    [ "$(dsoal_log_path_for_linux dsoal.log)" == "/games/x/dsoal.log" ]
}

# ---- Steam localconfig.vdf -------------------------------------------------

make_vdf() {
    printf '%s\n' \
        '"UserLocalConfigStore"' '{' \
        '	"Software"' '	{' '		"Valve"' '		{' '			"Steam"' '			{' '				"apps"' '				{' \
        '					"111"' '					{' '						"LaunchOptions"		"-old \"quoted\" C:\\dir"' '						"Playtime"		"5"' '					}' \
        '					"222"' '					{' '						"Playtime"		"7"' '					}' \
        '				}' '			}' '		}' '	}' \
        '	"apps"' '	{' '		"111"' '		{' '			"LaunchOptions"		"decoy"' '		}' '	}' \
        '}' > "$F"
}

@test "vdf: reads and unescapes the game's LaunchOptions" {
    make_vdf
    [ "$(vdf_get_launch_options "$F" 111)" == '-old "quoted" C:\dir' ]
}

@test "vdf: __ABSENT__ with a block but no options, __NOAPP__ with no block" {
    make_vdf
    [ "$(vdf_get_launch_options "$F" 222)" == "__ABSENT__" ]
    [ "$(vdf_get_launch_options "$F" 999)" == "__NOAPP__" ]
}

@test "vdf: set replaces the line, escaping quotes and backslashes" {
    make_vdf
    vdf_set_launch_options "$F" 111 'A="b c" D:\x %command%'
    [ "$(vdf_get_launch_options "$F" 111)" == 'A="b c" D:\x %command%' ]
}

@test "vdf: set adds a line to a block that has none, in the right block" {
    make_vdf
    vdf_set_launch_options "$F" 222 'WINEDLLOVERRIDES="dsound=n,b" %command%'
    [ "$(vdf_get_launch_options "$F" 222)" == 'WINEDLLOVERRIDES="dsound=n,b" %command%' ]
    [ "$(vdf_get_launch_options "$F" 111)" == '-old "quoted" C:\dir' ]
}

@test "vdf: only the game's block under Steam/apps changes, not the decoy" {
    make_vdf
    vdf_set_launch_options "$F" 111 new
    grep -q '"decoy"' "$F"
}

@test "vdf: delete removes the line; set back restores the original bytes" {
    make_vdf; cp "$F" "$F.orig"
    vdf_set_launch_options "$F" 111 __DELETE__
    [ "$(vdf_get_launch_options "$F" 111)" == "__ABSENT__" ]
    vdf_set_launch_options "$F" 111 '-old "quoted" C:\dir'
    # the line moves to the end of the block; everything else is byte-identical
    diff <(sort "$F") <(sort "$F.orig")
}

@test "vdf: set to the same value leaves the file byte-identical" {
    make_vdf; cp "$F" "$F.orig"
    vdf_set_launch_options "$F" 111 '-old "quoted" C:\dir'
    cmp "$F" "$F.orig"
}

# ---- Heroic GamesConfig ----------------------------------------------------

make_heroic() {
    printf '%s' '{"version":"v0","MyGame":{"enviromentOptions":[{"key":"FOO","value":"1"}],"other":true}}' > "$F"
}

@test "heroic: reads a variable, __ABSENT__ and __NOAPP__" {
    make_heroic
    [ "$(heroic_get_env "$F" MyGame FOO)" == "1" ]
    [ "$(heroic_get_env "$F" MyGame BAR)" == "__ABSENT__" ]
    [ "$(heroic_get_env "$F" Nope FOO)" == "__NOAPP__" ]
    [ "$(heroic_get_env "$BATS_TEST_TMPDIR/missing" MyGame FOO)" == "__NOAPP__" ]
}

@test "heroic: set adds, updates and keeps other variables and settings" {
    make_heroic
    heroic_set_override "$F" MyGame 'dsound=n,b'
    heroic_set_env "$F" MyGame FOO 2
    [ "$(heroic_get_override "$F" MyGame)" == "dsound=n,b" ]
    [ "$(heroic_get_env "$F" MyGame FOO)" == "2" ]
    [ "$(jq -r '.MyGame.other' "$F")" == "true" ]
    [ "$(jq -r '.version' "$F")" == "v0" ]
}

@test "heroic: __DELETE__ removes only that variable" {
    make_heroic
    heroic_set_override "$F" MyGame 'dsound=n,b'
    heroic_set_override "$F" MyGame __DELETE__
    [ "$(heroic_get_override "$F" MyGame)" == "__ABSENT__" ]
    [ "$(heroic_get_env "$F" MyGame FOO)" == "1" ]
}

@test "heroic: other games' entries are untouched" {
    printf '%s' '{"A":{"enviromentOptions":[]},"B":{"enviromentOptions":[{"key":"X","value":"y"}]}}' > "$F"
    heroic_set_env "$F" A K V
    [ "$(jq -c '.B' "$F")" == '{"enviromentOptions":[{"key":"X","value":"y"}]}' ]
}

@test "heroic: no trailing newline is added (Heroic writes none)" {
    make_heroic
    heroic_set_env "$F" MyGame BAR 1
    [ "$(tail -c1 "$F" | xxd -p)" == "7d" ]
}

@test "heroic: a file that isn't JSON is left alone and the set fails" {
    printf 'not json' > "$F"
    run heroic_set_env "$F" MyGame K V
    [ "$status" -ne 0 ]
    [ "$(cat "$F")" == "not json" ]
}
