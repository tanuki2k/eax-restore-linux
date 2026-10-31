#!/usr/bin/env bats
# config_get_key / config_set_key for the five text formats: values, and that
# an edit keeps CRLF endings, key spelling and spacing.

load ../helpers

setup() {
    load_script_functions
    F="$BATS_TEST_TMPDIR/cfg"
}

# ---- ini -------------------------------------------------------------------

@test "ini: reads a key, case-insensitive section and key" {
    write_file "$F" '[General]\nChannels = stereo\n[Other]\nchannels=quad\n'
    [ "$(config_get_key "$F" ini general CHANNELS)" == "stereo" ]
    [ "$(config_get_key "$F" ini other channels)" == "quad" ]
}

@test "ini: absent key and missing file read as __ABSENT__" {
    write_file "$F" '[general]\na=1\n'
    [ "$(config_get_key "$F" ini general b)" == "__ABSENT__" ]
    [ "$(config_get_key "$BATS_TEST_TMPDIR/nope" ini general b)" == "__ABSENT__" ]
}

@test "ini: replaces a value in place, keeping the key's spelling" {
    write_file "$F" '[general]\nChannels=stereo\nother=1\n'
    config_set_key "$F" ini general channels quad
    [ "$(cat "$F")" == $'[general]\nChannels=quad\nother=1' ]
}

@test "ini: keeps the 'key = value' spacing style" {
    write_file "$F" '[general]\nchannels= stereo\n'
    config_set_key "$F" ini general channels quad
    [ "$(cat "$F")" == $'[general]\nchannels= quad' ]
}

@test "ini: keeps CRLF line endings on replace" {
    write_file "$F" '[general]\r\nchannels=stereo\r\n'
    config_set_key "$F" ini general channels quad
    [ "$(cat "$F")" == $'[general]\r\nchannels=quad\r' ]
    [ "$(grep -c $'\r$' "$F")" -eq 2 ]
}

@test "ini: adds a missing key at the end of its section" {
    write_file "$F" '[general]\na=1\n\n[other]\nb=2\n'
    config_set_key "$F" ini general c 3
    [ "$(cat "$F")" == $'[general]\na=1\nc=3\n\n[other]\nb=2' ]
}

@test "ini: adds a new section when the file lacks it" {
    write_file "$F" '[general]\na=1\n'
    config_set_key "$F" ini reverb boost 1
    [ "$(cat "$F")" == $'[general]\na=1\n\n[reverb]\nboost=1' ]
}

@test "ini: creates a file that does not exist" {
    config_set_key "$F" ini general a 1
    [ "$(cat "$F")" == $'[general]\na=1' ]
}

@test "ini: __DELETE__ removes the key and leaves the rest" {
    write_file "$F" '[general]\na=1\nb=2\n'
    config_set_key "$F" ini general a __DELETE__
    [ "$(cat "$F")" == $'[general]\nb=2' ]
}

@test "ini: only touches the named section" {
    write_file "$F" '[one]\nk=1\n[two]\nk=2\n'
    config_set_key "$F" ini two k 9
    [ "$(cat "$F")" == $'[one]\nk=1\n[two]\nk=9' ]
}

# ---- flat_ini --------------------------------------------------------------

@test "flat_ini: reads and replaces without sections" {
    write_file "$F" 'a=1\nSound = on\n'
    [ "$(config_get_key "$F" flat_ini "" sound)" == "on" ]
    config_set_key "$F" flat_ini "" sound off
    [ "$(config_get_key "$F" flat_ini "" sound)" == "off" ]
    [ "$(config_get_key "$F" flat_ini "" a)" == "1" ]
}

@test "flat_ini: appends a missing key" {
    write_file "$F" 'a=1\n'
    config_set_key "$F" flat_ini "" b 2
    [ "$(cat "$F")" == $'a=1\nb=2' ]
}

# ---- idtech_cfg ------------------------------------------------------------

@test "idtech_cfg: reads set/seta values with quotes stripped" {
    write_file "$F" 'seta s_numberOfSpeakers "6"\nset other 1\n'
    [ "$(config_get_key "$F" idtech_cfg "" s_numberofspeakers)" == "6" ]
    [ "$(config_get_key "$F" idtech_cfg "" other)" == "1" ]
}

@test "idtech_cfg: rewrites the line as seta with a quoted value" {
    write_file "$F" 'seta s_numberOfSpeakers "2"\nseta keep "x"\n'
    config_set_key "$F" idtech_cfg "" s_numberOfSpeakers 6
    [ "$(cat "$F")" == $'seta s_numberOfSpeakers "6"\nseta keep "x"' ]
}

@test "idtech_cfg: ignores commented lines and appends when missing" {
    write_file "$F" '// seta foo "1"\nseta bar "2"\n'
    [ "$(config_get_key "$F" idtech_cfg "" foo)" == "__ABSENT__" ]
    config_set_key "$F" idtech_cfg "" foo 5
    [ "$(config_get_key "$F" idtech_cfg "" foo)" == "5" ]
    [ "$(config_get_key "$F" idtech_cfg "" bar)" == "2" ]
}

@test "idtech_cfg: __DELETE__ removes the line" {
    write_file "$F" 'seta a "1"\nseta b "2"\n'
    config_set_key "$F" idtech_cfg "" a __DELETE__
    [ "$(cat "$F")" == 'seta b "2"' ]
}

# ---- dark_cfg --------------------------------------------------------------

@test "dark_cfg: bare flag reads __TRUE__, commented flag __FALSE__, none __ABSENT__" {
    write_file "$F" 'dx_flag\n;off_flag\nvalue_key 5\n'
    [ "$(config_get_key "$F" dark_cfg "" dx_flag)" == "__TRUE__" ]
    [ "$(config_get_key "$F" dark_cfg "" off_flag)" == "__FALSE__" ]
    [ "$(config_get_key "$F" dark_cfg "" value_key)" == "5" ]
    [ "$(config_get_key "$F" dark_cfg "" nothing)" == "__ABSENT__" ]
}

@test "dark_cfg: __TRUE__ activates after a commented example, which stays" {
    write_file "$F" '; comment\n;eax\nother\n'
    config_set_key "$F" dark_cfg "" eax __TRUE__
    [ "$(cat "$F")" == $'; comment\n;eax\neax\nother' ]
}

@test "dark_cfg: __FALSE__ comments an active flag out" {
    write_file "$F" 'eax\nother\n'
    config_set_key "$F" dark_cfg "" eax __FALSE__
    [ "$(cat "$F")" == $';eax\nother' ]
    [ "$(config_get_key "$F" dark_cfg "" eax)" == "__FALSE__" ]
}

@test "dark_cfg: sets a value on a keyed line" {
    write_file "$F" 'snd_vol 3\n'
    config_set_key "$F" dark_cfg "" snd_vol 8
    [ "$(config_get_key "$F" dark_cfg "" snd_vol)" == "8" ]
}

# ---- ltx -------------------------------------------------------------------

@test "ltx: reads a key=value line, case-insensitive, absent otherwise" {
    write_file "$F" 'snd_efx on\r\nvid_mode 1024x768\r\n'
    [ "$(config_get_key "$F" ltx "" SND_EFX)" == "on" ]
    [ "$(config_get_key "$F" ltx "" vid_mode)" == "1024x768" ]
    [ "$(config_get_key "$F" ltx "" nothing)" == "__ABSENT__" ]
}

@test "ltx: replaces in place keeping spelling and CRLF, appends and deletes" {
    write_file "$F" 'Snd_Efx off\r\nsnd_targets 32\r\n'
    config_set_key "$F" ltx "" snd_efx on
    [ "$(cat "$F")" == $'Snd_Efx on\r\nsnd_targets 32\r' ]
    config_set_key "$F" ltx "" snd_volume_eff 1.0
    [ "$(config_get_key "$F" ltx "" snd_volume_eff)" == "1.0" ]
    config_set_key "$F" ltx "" snd_targets __DELETE__
    [ "$(config_get_key "$F" ltx "" snd_targets)" == "__ABSENT__" ]
}

# ---- brace_cfg -------------------------------------------------------------

@test "brace_cfg: reads and replaces only the text inside the value braces" {
    write_file "$F" '{Sound} = {on}\n{Other} = {1}\n'
    [ "$(config_get_key "$F" brace_cfg "" sound)" == "on" ]
    config_set_key "$F" brace_cfg "" Sound off
    [ "$(cat "$F")" == $'{Sound} = {off}\n{Other} = {1}' ]
}

# ---- quoted_cfg ------------------------------------------------------------

@test "quoted_cfg: reads and replaces a quoted value, keeping the other lines" {
    write_file "$F" '"MusicVolume" "50.000000"\n"3dsoundprovider" "0"\n"Renderer" "Primary Display Driver"\n'
    [ "$(config_get_key "$F" quoted_cfg "" 3DSoundProvider)" == "0" ]
    [ "$(config_get_key "$F" quoted_cfg "" Renderer)" == "Primary Display Driver" ]
    config_set_key "$F" quoted_cfg "" 3dsoundprovider 2
    [ "$(cat "$F")" == $'"MusicVolume" "50.000000"\n"3dsoundprovider" "2"\n"Renderer" "Primary Display Driver"' ]
}

@test "quoted_cfg: a missing key is appended quoted, and __DELETE__ removes the line" {
    write_file "$F" '"a" "1"\r\n"b" "2"\r\n'
    config_set_key "$F" quoted_cfg "" 3dsoundprovidername "Microsoft DirectSound3D with Creative Labs EAX(TM)"
    [ "$(config_get_key "$F" quoted_cfg "" 3dsoundprovidername)" == "Microsoft DirectSound3D with Creative Labs EAX(TM)" ]
    config_set_key "$F" quoted_cfg "" a __DELETE__
    [ "$(config_get_key "$F" quoted_cfg "" a)" == "__ABSENT__" ]
    [ "$(config_get_key "$F" quoted_cfg "" b)" == "2" ]
}

# ---- byte_cfg --------------------------------------------------------------

@test "byte_cfg: reads and replaces one byte by decimal or hex position, leaving the rest" {
    printf '\x15\x00\x03\x00\xff' > "$F"
    [ "$(config_get_key "$F" byte_cfg "" 0x2)" == "3" ]
    [ "$(config_get_key "$F" byte_cfg "" 4)" == "255" ]
    config_set_key "$F" byte_cfg "" 0x2 2
    [ "$(od -An -v -tx1 "$F" | tr -d ' \n')" == "15000200ff" ]
}

@test "byte_cfg: a position past the end is absent and is never written" {
    printf '\x01\x02' > "$F"
    [ "$(config_get_key "$F" byte_cfg "" 0x10)" == "__ABSENT__" ]
    ! config_set_key "$F" byte_cfg "" 0x10 1
    ! config_set_key "$F" byte_cfg "" 0 256
    [ "$(stat -c %s "$F")" == "2" ]
}

# ---- gas_cfg ---------------------------------------------------------------

@test "gas_cfg: reads a value without its semicolon and keeps tabs, spacing and the semicolon on a change" {
    write_file "$F" '[prefs]\n{\n\tblood = red;\n\teax_enabled = false;\n}\n'
    [ "$(config_get_key "$F" gas_cfg prefs EAX_Enabled)" == "false" ]
    config_set_key "$F" gas_cfg prefs eax_enabled true
    [ "$(cat "$F")" == $'[prefs]\n{\n\tblood = red;\n\teax_enabled = true;\n}' ]
}

@test "gas_cfg: a missing key goes before the closing brace, and a missing section is added" {
    write_file "$F" '[prefs]\r\n{\r\n\tblood = red;\r\n}\r\n'
    config_set_key "$F" gas_cfg prefs eax_enabled true
    [ "$(cat "$F")" == $'[prefs]\r\n{\r\n\tblood = red;\r\n\teax_enabled = true;\r\n}\r' ]
    [ "$(config_get_key "$F" gas_cfg prefs eax_enabled)" == "true" ]
    [ "$(config_get_key "$F" gas_cfg other eax_enabled)" == "__ABSENT__" ]
    config_set_key "$F" gas_cfg other a 1
    [ "$(config_get_key "$F" gas_cfg other a)" == "1" ]
    [ "$(config_get_key "$F" gas_cfg prefs blood)" == "red" ]
}

@test "gas_cfg: __DELETE__ removes the line" {
    write_file "$F" '[prefs]\n{\n\ta = 1;\n\tb = 2;\n}\n'
    config_set_key "$F" gas_cfg prefs a __DELETE__
    [ "$(cat "$F")" == $'[prefs]\n{\n\tb = 2;\n}' ]
}

# ---- cross-format ----------------------------------------------------------

@test "a set then get round-trips for every text format" {
    local fmt
    for fmt in ini flat_ini idtech_cfg dark_cfg ltx brace_cfg gas_cfg quoted_cfg; do
        rm -f "$F"
        write_file "$F" ''
        config_set_key "$F" "$fmt" sec key 7
        # brace_cfg only edits keys already in the file, so it can't add one
        [ "$fmt" == brace_cfg ] && continue
        [ "$(config_get_key "$F" "$fmt" sec key)" == "7" ] || { echo "$fmt failed"; return 1; }
    done
}

@test "an edit leaves no temp file behind" {
    write_file "$F" '[general]\na=1\n'
    config_set_key "$F" ini general a 2
    [ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep eax-restore-cfg)" ]
}

@test "ini: Player.txt style spacing around = is kept (TRON 2.0)" {
    write_file "$F" '[Sound]\nsoundvolume = 75\neaxenabled = 0\n'
    config_set_key "$F" ini sound eaxenabled 1
    [ "$(cat "$F")" == $'[Sound]\nsoundvolume = 75\neaxenabled = 1' ]
}

# ---- location bases ----------------------------------------------------------

@test "resolve_config_file: game_exe and game_root, and the old game / install names, find the same folders" {
    GAME_DIR="$BATS_TEST_TMPDIR/steamapps/common/Game/bin"
    mkdir -p "$GAME_DIR"
    write_file "$GAME_DIR/a.ini" 'x=1\n'
    write_file "$BATS_TEST_TMPDIR/steamapps/common/Game/b.ini" 'x=1\n'
    GAME_INSTALL_ROOT=""
    find_existing_variant() { echo "$1"; }  # the real one matches case loosely
    [ "$(resolve_config_file "game_exe:a.ini")" == "$GAME_DIR/a.ini" ]
    [ "$(resolve_config_file "game:a.ini")" == "$GAME_DIR/a.ini" ]
    [ "$(resolve_config_file "game_root:b.ini")" == "$BATS_TEST_TMPDIR/steamapps/common/Game/b.ini" ]
    [ "$(resolve_config_file "install:b.ini")" == "$BATS_TEST_TMPDIR/steamapps/common/Game/b.ini" ]
}

@test "config_row_is_safe accepts the new base names" {
    config_row_is_safe ini "game_exe:a.ini" s k v
    config_row_is_safe ini "game_root:a.ini" s k v
}

@test "print_config_rows: a key that already has its value shows ticked" {
    NC="" DIM="" GREEN=""
    run print_config_rows $'bia.ini\x1fA\x1fUseEAX\x1f__SET__\x1fTrue\nbia.ini\x1fA\x1fUse3DSound\x1fFalse\x1fTrue\n'
    [[ "$output" == *"UseEAX"*"True ✓ already set"* ]]
    [[ "$output" == *"Use3DSound"*"False → True"* ]]
}
