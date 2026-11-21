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

@test "sound log: DSOAL and OpenAL Soft variables are added together and removed together" {
    local orig='WINEDLLOVERRIDES="dsound=n,b" %command% -x' with
    with="$(launch_options_with_sound_log "$orig" 4 'Z:/g/dsoal.log' 3 'Z:/g/openal.log')"
    [ "$with" == 'WINEDLLOVERRIDES="dsound=n,b" DSOAL_LOGLEVEL=4 DSOAL_LOGFILE="Z:/g/dsoal.log" ALSOFT_LOGLEVEL=3 ALSOFT_LOGFILE="Z:/g/openal.log" %command% -x' ]
    [ "$(launch_options_without_dsoal_log "$with")" == "$orig" ]
}

@test "sound log: a blank DSOAL level leaves DSOAL's variables out" {
    [ "$(launch_options_with_sound_log '' '' 'Z:/x' 3 'Z:/g/openal.log')" == 'ALSOFT_LOGLEVEL=3 ALSOFT_LOGFILE="Z:/g/openal.log" %command%' ]
}

@test "sound log: values are read back per engine" {
    local o='DSOAL_LOGLEVEL=4 ALSOFT_LOGLEVEL=3 ALSOFT_LOGFILE="Z:/a b/openal.log" %command%'
    [ "$(launch_options_log_value "$o" DSOAL LEVEL)" == "4" ]
    [ "$(launch_options_log_value "$o" ALSOFT LEVEL)" == "3" ]
    [ "$(launch_options_log_value "$o" ALSOFT FILE)" == "Z:/a b/openal.log" ]
    [ -z "$(launch_options_log_value "$o" DSOAL FILE)" ]
}

# ---- launch_options_with_env / without_env (CPU thread limit) -------------

@test "env: added right before %command%, after the override" {
    [ "$(launch_options_with_env 'WINEDLLOVERRIDES="dsound=n,b" %command% -nointro' WINE_CPU_TOPOLOGY 8:0,1,2,3,4,5,6,7)" \
        == 'WINEDLLOVERRIDES="dsound=n,b" WINE_CPU_TOPOLOGY=8:0,1,2,3,4,5,6,7 %command% -nointro' ]
}

@test "env: empty options get %command%, bare arguments move after it" {
    [ "$(launch_options_with_env "" V 1)" == "V=1 %command%" ]
    [ "$(launch_options_with_env "-nointro" V 1)" == "V=1 %command% -nointro" ]
}

@test "env: replaces the variable rather than duplicating it, any quoting" {
    [ "$(launch_options_with_env 'V=0 %command%' V 1)" == "V=1 %command%" ]
    [ "$(launch_options_with_env 'A=1 V="x y" %command%' V 1)" == "A=1 V=1 %command%" ]
    [ "$(launch_options_with_env "V='x' %command%" V 1)" == "V=1 %command%" ]
}

@test "env: removing leaves the other variables and arguments" {
    [ "$(launch_options_without_env 'A=1 V=2 %command% -x' V)" == "A=1 %command% -x" ]
    [ "$(launch_options_without_env 'VV=1 %command%' V)" == "VV=1 %command%" ]
}

@test "cpu_thread_count: what nproc says" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    printf '#!/bin/sh\necho 16\n' > "$BATS_TEST_TMPDIR/bin/nproc"; chmod +x "$BATS_TEST_TMPDIR/bin/nproc"
    PATH="$BATS_TEST_TMPDIR/bin:$PATH" run cpu_thread_count
    [ "$output" == "16" ]
}

@test "dsoal log paths: Z: maps back to /, bare names sit in the game folder" {
    GAME_DIR=/games/x
    [ "$(dsoal_log_path_for_wine /games/x)" == "Z:/games/x/dsoal.log" ]
    [ "$(dsoal_log_path_for_linux 'Z:\games\x\dsoal.log')" == "/games/x/dsoal.log" ]
    [ "$(alsoft_log_path_for_wine /games/x)" == "Z:/games/x/openal.log" ]
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

# ---- from the script audits --------------------------------------------------

@test "merge_dll_override: dsound.dll and dsound are the same rule" {
    [ "$(merge_dll_override 'dsound.dll=n;foo=b' dsound)" == "foo=b;dsound=n,b" ]
    [ "$(merge_dll_override 'DSOUND=n,b' dsound)" == "dsound=n,b" ]
    [ "$(merge_dll_override 'a.dll,dsound.dll=n' dsound)" == "a.dll=n;dsound=n,b" ]
}

@test "launch options: an & in the options or log path is kept as typed" {
    run launch_options_with_override 'WINEDLLOVERRIDES="d3d9=n" MY=a&b %command%' dsound
    [[ "$output" == *'MY=a&b %command%' ]]
    [[ "$output" != *'WINEDLLOVERRIDES="d3d9=n" '* ]]
    run launch_options_with_dsoal_log 'FOO=1 %command% -x' 4 'Z:/g/Rock & Roll/dsoal.log'
    [ "$output" == 'FOO=1 DSOAL_LOGLEVEL=4 DSOAL_LOGFILE="Z:/g/Rock & Roll/dsoal.log" %command% -x' ]
}

@test "vdf launch options: \\n and \\t escapes survive a read and write" {
    f="$BATS_TEST_TMPDIR/localconfig.vdf"
    printf '%s\n' '"UserLocalConfigStore"' '{' '	"Software"' '	{' '		"Valve"' '		{' '			"Steam"' '			{' '				"apps"' '				{' '					"7"' '					{' '						"LaunchOptions"		"a\tb\\c"' '					}' '				}' '			}' '		}' '	}' '}' > "$f"
    v="$(vdf_get_launch_options "$f" 7)"
    [ "$v" == $'a\tb\\c' ]
    vdf_set_launch_options "$f" 7 "$v"
    grep -qF '"a\tb\\c"' "$f"
}
