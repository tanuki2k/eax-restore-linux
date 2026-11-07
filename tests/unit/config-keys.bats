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

# ---- ini, no section ----------------------------------------------------

@test "ini with no section: reads and replaces in a file without headers" {
    write_file "$F" 'a=1\nSound = on\n'
    [ "$(config_get_key "$F" ini "" sound)" == "on" ]
    config_set_key "$F" ini "" sound off
    [ "$(config_get_key "$F" ini "" sound)" == "off" ]
    [ "$(config_get_key "$F" ini "" a)" == "1" ]
}

@test "ini with no section: appends a missing key to a file without headers" {
    write_file "$F" 'a=1\n'
    config_set_key "$F" ini "" b 2
    [ "$(cat "$F")" == $'a=1\nb=2' ]
}

@test "ini with no section: the top of a file with headers is the part before the first one" {
    write_file "$F" 'a=1\n[one]\na=2\n'
    [ "$(config_get_key "$F" ini "" a)" == "1" ]
    config_set_key "$F" ini "" b 3
    [ "$(cat "$F")" == $'a=1\nb=3\n[one]\na=2' ]
    [ "$(config_get_key "$F" ini one a)" == "2" ]
}

@test "key_value: a commented-out line starting with the key is an example, the active line goes after it" {
    write_file "$F" '; snd_efx off\nsnd_volume 1\n'
    [ "$(config_get_key "$F" key_value "" snd_efx)" == "__FALSE__" ]
    config_set_key "$F" key_value "" snd_efx on
    [ "$(cat "$F")" == $'; snd_efx off\nsnd_efx on\nsnd_volume 1' ]
    [ "$(config_get_key "$F" key_value "" snd_efx)" == "on" ]
}

@test "upgrade_config_line: maps every old format name in a CONFIG line and leaves others alone" {
    local old new
    for pair in flat_ini:ini gas_cfg:ini_braces idtech_cfg:set_commands dark_cfg:key_value ltx:key_value \
                brace_cfg:braced_pairs quoted_cfg:quoted_pairs byte_cfg:binary_offset lenstr_cfg:binary_text \
                gadb:binary_switches wine_reg:registry ini:ini registry:registry; do
        old="${pair%%:*}"; new="${pair##*:}"
        upgrade_config_line "CONFIG:audio"$'\t'"Enable EAX"$'\t'"/p/f"$'\t'"$old"$'\t'"s"$'\t'"k"$'\t'$'\t'"1"
        [ "$UPGRADED_LINE" == \
          "CONFIG:audio"$'\t'"Enable EAX"$'\t'"/p/f"$'\t'"$new"$'\t'"s"$'\t'"k"$'\t'$'\t'"1" ]
    done
    upgrade_config_line "/some/file"; [ "$UPGRADED_LINE" == "/some/file" ]
    upgrade_config_line "VCRUN"; [ "$UPGRADED_LINE" == "VCRUN" ]
    upgrade_config_line "CONFIG:audio"$'\t'"t"; [ "$UPGRADED_LINE" == "CONFIG:audio"$'\t'"t" ]
}

# ---- set_commands ------------------------------------------------------------

@test "set_commands: reads set/seta values with quotes stripped" {
    write_file "$F" 'seta s_numberOfSpeakers "6"\nset other 1\n'
    [ "$(config_get_key "$F" set_commands "" s_numberofspeakers)" == "6" ]
    [ "$(config_get_key "$F" set_commands "" other)" == "1" ]
}

@test "set_commands: rewrites the line as seta with a quoted value" {
    write_file "$F" 'seta s_numberOfSpeakers "2"\nseta keep "x"\n'
    config_set_key "$F" set_commands "" s_numberOfSpeakers 6
    [ "$(cat "$F")" == $'seta s_numberOfSpeakers "6"\nseta keep "x"' ]
}

@test "set_commands: ignores commented lines and appends when missing" {
    write_file "$F" '// seta foo "1"\nseta bar "2"\n'
    [ "$(config_get_key "$F" set_commands "" foo)" == "__ABSENT__" ]
    config_set_key "$F" set_commands "" foo 5
    [ "$(config_get_key "$F" set_commands "" foo)" == "5" ]
    [ "$(config_get_key "$F" set_commands "" bar)" == "2" ]
}

@test "set_commands: __DELETE__ removes the line" {
    write_file "$F" 'seta a "1"\nseta b "2"\n'
    config_set_key "$F" set_commands "" a __DELETE__
    [ "$(cat "$F")" == 'seta b "2"' ]
}

# ---- key_value --------------------------------------------------------------

@test "key_value: bare flag reads __TRUE__, commented flag __FALSE__, none __ABSENT__" {
    write_file "$F" 'dx_flag\n;off_flag\nvalue_key 5\n'
    [ "$(config_get_key "$F" key_value "" dx_flag)" == "__TRUE__" ]
    [ "$(config_get_key "$F" key_value "" off_flag)" == "__FALSE__" ]
    [ "$(config_get_key "$F" key_value "" value_key)" == "5" ]
    [ "$(config_get_key "$F" key_value "" nothing)" == "__ABSENT__" ]
}

@test "key_value: __TRUE__ activates after a commented example, which stays" {
    write_file "$F" '; comment\n;eax\nother\n'
    config_set_key "$F" key_value "" eax __TRUE__
    [ "$(cat "$F")" == $'; comment\n;eax\neax\nother' ]
}

@test "key_value: __FALSE__ comments an active flag out" {
    write_file "$F" 'eax\nother\n'
    config_set_key "$F" key_value "" eax __FALSE__
    [ "$(cat "$F")" == $';eax\nother' ]
    [ "$(config_get_key "$F" key_value "" eax)" == "__FALSE__" ]
}

@test "key_value: sets a value on a keyed line" {
    write_file "$F" 'snd_vol 3\n'
    config_set_key "$F" key_value "" snd_vol 8
    [ "$(config_get_key "$F" key_value "" snd_vol)" == "8" ]
}

# ---- key_value, plain lines -----------------------------------------

@test "key_value, plain lines: reads a key=value line, case-insensitive, absent otherwise" {
    write_file "$F" 'snd_efx on\r\nvid_mode 1024x768\r\n'
    [ "$(config_get_key "$F" key_value "" SND_EFX)" == "on" ]
    [ "$(config_get_key "$F" key_value "" vid_mode)" == "1024x768" ]
    [ "$(config_get_key "$F" key_value "" nothing)" == "__ABSENT__" ]
}

@test "key_value, plain lines: replaces in place keeping spelling and CRLF, appends and deletes" {
    write_file "$F" 'Snd_Efx off\r\nsnd_targets 32\r\n'
    config_set_key "$F" key_value "" snd_efx on
    [ "$(cat "$F")" == $'Snd_Efx on\r\nsnd_targets 32\r' ]
    config_set_key "$F" key_value "" snd_volume_eff 1.0
    [ "$(config_get_key "$F" key_value "" snd_volume_eff)" == "1.0" ]
    config_set_key "$F" key_value "" snd_targets __DELETE__
    [ "$(config_get_key "$F" key_value "" snd_targets)" == "__ABSENT__" ]
}

# ---- braced_pairs -------------------------------------------------------------

@test "braced_pairs: reads and replaces only the text inside the value braces" {
    write_file "$F" '{Sound} = {on}\n{Other} = {1}\n'
    [ "$(config_get_key "$F" braced_pairs "" sound)" == "on" ]
    config_set_key "$F" braced_pairs "" Sound off
    [ "$(cat "$F")" == $'{Sound} = {off}\n{Other} = {1}' ]
}

# ---- quoted_pairs ------------------------------------------------------------

@test "quoted_pairs: reads and replaces a quoted value, keeping the other lines" {
    write_file "$F" '"MusicVolume" "50.000000"\n"3dsoundprovider" "0"\n"Renderer" "Primary Display Driver"\n'
    [ "$(config_get_key "$F" quoted_pairs "" 3DSoundProvider)" == "0" ]
    [ "$(config_get_key "$F" quoted_pairs "" Renderer)" == "Primary Display Driver" ]
    config_set_key "$F" quoted_pairs "" 3dsoundprovider 2
    [ "$(cat "$F")" == $'"MusicVolume" "50.000000"\n"3dsoundprovider" "2"\n"Renderer" "Primary Display Driver"' ]
}

@test "quoted_pairs: a missing key is appended quoted, and __DELETE__ removes the line" {
    write_file "$F" '"a" "1"\r\n"b" "2"\r\n'
    config_set_key "$F" quoted_pairs "" 3dsoundprovidername "Microsoft DirectSound3D with Creative Labs EAX(TM)"
    [ "$(config_get_key "$F" quoted_pairs "" 3dsoundprovidername)" == "Microsoft DirectSound3D with Creative Labs EAX(TM)" ]
    config_set_key "$F" quoted_pairs "" a __DELETE__
    [ "$(config_get_key "$F" quoted_pairs "" a)" == "__ABSENT__" ]
    [ "$(config_get_key "$F" quoted_pairs "" b)" == "2" ]
}

# ---- binary_offset --------------------------------------------------------------

@test "binary_offset: reads and replaces one byte by decimal or hex position, leaving the rest" {
    printf '\x15\x00\x03\x00\xff' > "$F"
    [ "$(config_get_key "$F" binary_offset "" 0x2)" == "3" ]
    [ "$(config_get_key "$F" binary_offset "" 4)" == "255" ]
    config_set_key "$F" binary_offset "" 0x2 2
    [ "$(od -An -v -tx1 "$F" | tr -d ' \n')" == "15000200ff" ]
}

@test "binary_offset: a position past the end is absent and is never written" {
    printf '\x01\x02' > "$F"
    [ "$(config_get_key "$F" binary_offset "" 0x10)" == "__ABSENT__" ]
    ! config_set_key "$F" binary_offset "" 0x10 1
    ! config_set_key "$F" binary_offset "" 0 256
    [ "$(stat -c %s "$F")" == "2" ]
}

# ---- binary_text ------------------------------------------------------------

# A stand-in for Freedom Force's options.dat: a binary file with a 4-byte
# little-endian length and then text, found by the bytes just before the length.
lenstr_file() {  # <driver text> <name text before it>
    { printf 'HDR4\x01\x00\x00\x00\x0a\x00\x00\x00%s' "$2"
      printf '\x02\x00\x00\x00\x00\x00\x80\x3f'
      printf "$(printf '\\x%02x\\x00\\x00\\x00' "${#1}")"; printf '%s' "$1"
      printf '\x00\x00\x80\x3f\x00\x00\x40\x3fplayer 1\x04\x00\x00\x00'
    } > "$F"
}

config_find_text_end() {  # <file> -> byte position just past the anchored text
    local found pos len
    found="$(_lenstr_find "$1" 0000803f)"; pos="${found%% *}"; len="${found#* }"; len="${len%% *}"
    echo "$((pos + 4 + len))"
}

@test "binary_text: reads the text after the anchor and writes a longer one, fixing its length and keeping the rest" {
    lenstr_file "any" "minute_man"
    [ "$(config_get_key "$F" binary_text "" 0000803f)" == "any" ]
    config_set_key "$F" binary_text "" 0000803f "Creative Labs EAX 2 (TM)"
    [ "$(config_get_key "$F" binary_text "" 0000803f)" == "Creative Labs EAX 2 (TM)" ]
    lenstr_file "Creative Labs EAX 2 (TM)" "minute_man"
    cp "$F" "$F.expected"
    lenstr_file "any" "minute_man"
    config_set_key "$F" binary_text "" 0000803f "Creative Labs EAX 2 (TM)"
    cmp "$F" "$F.expected"
}

@test "binary_text: setting the old text back restores the original bytes" {
    lenstr_file "any" "minute_man"
    cp "$F" "$F.orig"
    config_set_key "$F" binary_text "" 0000803f "Creative Labs EAX 2 (TM)"
    config_set_key "$F" binary_text "" 0000803f "any"
    cmp "$F" "$F.orig"
}

@test "binary_text: skips an anchor that isn't followed by a sane length and printable text" {
    printf '\x00\x00\x80\x3f\x02\x00\x00\x00\x00\x40' > "$F"
    printf '\x00\x00\x80\x3f\x03\x00\x00\x00any' >> "$F"
    [ "$(config_get_key "$F" binary_text "" 0000803f)" == "any" ]
}

@test "binary_text: an anchor that isn't there is absent and is never written" {
    printf 'HDR4\x01\x02\x03\x04' > "$F"
    [ "$(config_get_key "$F" binary_text "" 0000803f)" == "__ABSENT__" ]
    ! config_set_key "$F" binary_text "" 0000803f "any"
    ! config_set_key "$F" binary_text "" nothex "any"
    [ "$(cat "$F")" == $'HDR4\x01\x02\x03\x04' ]
}

@test "binary_text: a row needs a hex anchor and plain text" {
    config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f "Creative Labs EAX 2 (TM)"
    ! config_row_is_safe binary_text "game_exe:Data/options.dat" "" 803 "any"
    ! config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f ""
}

@test "binary_text: a key with +N reads and sets the byte N past the end of the text, wherever the text ends" {
    lenstr_file "any" "minute_man"
    printf '\x00\x00\x00\x00\x07' >> "$F"
    local at=$(( $(stat -c %s "$F") - 1 ))
    # The byte is 7 now; its distance from the text's end is what the key names.
    local d=$(( at - ( $(config_find_text_end "$F") ) ))
    [ "$(config_get_key "$F" binary_text "" "0000803f+$d")" == "7" ]
    config_set_key "$F" binary_text "" "0000803f+$d" 2
    [ "$(config_get_key "$F" binary_text "" "0000803f+$d")" == "2" ]
    # A longer driver name moves the byte; the same key still finds it.
    config_set_key "$F" binary_text "" 0000803f "Creative Labs EAX 2 (TM)"
    [ "$(config_get_key "$F" binary_text "" "0000803f+$d")" == "2" ]
    [ "$(stat -c %s "$F")" == "$(( at + 1 + 21 ))" ]
}

@test "binary_text: a +N byte past the end of the file is absent and never written; its value must be 0-255" {
    lenstr_file "any" "minute_man"
    [ "$(config_get_key "$F" binary_text "" 0000803f+9999)" == "__ABSENT__" ]
    ! config_set_key "$F" binary_text "" 0000803f+9999 1
    ! config_set_key "$F" binary_text "" 0000803f+2 256
    ! config_set_key "$F" binary_text "" 0000803f+2 x
}

@test "binary_text: a row with a +N key needs a number from 0 to 255" {
    config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f+46 1
    ! config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f+46 300
    ! config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f+46 ""
    ! config_row_is_safe binary_text "game_exe:Data/options.dat" "" 0000803f+x 1
}

# ---- ini_braces ---------------------------------------------------------------

@test "ini_braces: reads a value without its semicolon and keeps tabs, spacing and the semicolon on a change" {
    write_file "$F" '[prefs]\n{\n\tblood = red;\n\teax_enabled = false;\n}\n'
    [ "$(config_get_key "$F" ini_braces prefs EAX_Enabled)" == "false" ]
    config_set_key "$F" ini_braces prefs eax_enabled true
    [ "$(cat "$F")" == $'[prefs]\n{\n\tblood = red;\n\teax_enabled = true;\n}' ]
}

@test "ini_braces: a missing key goes before the closing brace, and a missing section is added" {
    write_file "$F" '[prefs]\r\n{\r\n\tblood = red;\r\n}\r\n'
    config_set_key "$F" ini_braces prefs eax_enabled true
    [ "$(cat "$F")" == $'[prefs]\r\n{\r\n\tblood = red;\r\n\teax_enabled = true;\r\n}\r' ]
    [ "$(config_get_key "$F" ini_braces prefs eax_enabled)" == "true" ]
    [ "$(config_get_key "$F" ini_braces other eax_enabled)" == "__ABSENT__" ]
    config_set_key "$F" ini_braces other a 1
    [ "$(config_get_key "$F" ini_braces other a)" == "1" ]
    [ "$(config_get_key "$F" ini_braces prefs blood)" == "red" ]
}

@test "ini_braces: __DELETE__ removes the line" {
    write_file "$F" '[prefs]\n{\n\ta = 1;\n\tb = 2;\n}\n'
    config_set_key "$F" ini_braces prefs a __DELETE__
    [ "$(cat "$F")" == $'[prefs]\n{\n\tb = 2;\n}' ]
}

# ---- cross-format ----------------------------------------------------------

@test "a set then get round-trips for every text format" {
    local fmt
    for fmt in ini set_commands key_value braced_pairs ini_braces quoted_pairs; do
        rm -f "$F"
        write_file "$F" ''
        config_set_key "$F" "$fmt" sec key 7
        # braced_pairs only edits keys already in the file, so it can't add one
        [ "$fmt" == braced_pairs ] && continue
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

@test "config_get_key and config_set_key refuse an old or unknown format name" {
    local f="$BATS_TEST_TMPDIR/a.ini"
    printf '[S]\nk=1\n' > "$f"
    run config_get_key "$f" flat_ini S k
    [ "$status" -eq 1 ]
    run config_get_key "$f" wine_reg S k
    [ "$status" -eq 1 ]
    run config_set_key "$f" flat_ini S k 2
    [ "$status" -eq 1 ]
    [ "$(config_get_key "$f" ini S k)" == "1" ]
}

@test "config_get_key refuses an old format name whether or not the file exists" {
    run config_get_key "$BATS_TEST_TMPDIR/missing.ini" flat_ini S k
    [ "$status" -eq 1 ]
}

@test "an old-name CONFIG line works with config_get_key and config_set_key once upgraded" {
    local f="$BATS_TEST_TMPDIR/a.ini" line fmt
    printf '[S]\nk=1\n' > "$f"
    line="CONFIG:audio"$'\t'"t"$'\t'"$f"$'\t'"flat_ini"$'\t'"S"$'\t'"k"$'\t'"1"$'\t'"2"
    upgrade_config_line "$line"
    mapfile -t -d $'\t' fields < <(printf '%s' "${UPGRADED_LINE#CONFIG:}")
    fmt="${fields[3]}"
    [ "$fmt" == "ini" ]
    config_set_key "${fields[2]}" "$fmt" "${fields[4]}" "${fields[5]}" "${fields[7]}"
    [ "$(config_get_key "${fields[2]}" "$fmt" "${fields[4]}" "${fields[5]}")" == "2" ]
}

@test "apply_game_settings keeps a previous record whose format it can't read" {
    local f="$BATS_TEST_TMPDIR/a.ini" line
    printf '[S]\nk=1\n' > "$f"
    line="CONFIG:audio"$'\t'"t"$'\t'"$f"$'\t'"future_format"$'\t'"S"$'\t'"k"$'\t'"1"$'\t'"2"
    PREV_CONFIG_LINES=("$line")
    GAME_SETTINGS_PLAN=()
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/manifest"
    : > "$INSTALL_MANIFEST"
    apply_game_settings
    [ "$(cat "$INSTALL_MANIFEST")" == "$line" ]
}

@test "apply_game_settings keeps an unreadable-format record even when its file is missing, and still drops a known one" {
    local gone="$BATS_TEST_TMPDIR/gone.ini" unknown known
    unknown="CONFIG:audio"$'\t'"t"$'\t'"$gone"$'\t'"future_format"$'\t'"S"$'\t'"k"$'\t'"1"$'\t'"2"
    known="CONFIG:audio"$'\t'"t"$'\t'"$gone"$'\t'"ini"$'\t'"S"$'\t'"k"$'\t'"1"$'\t'"2"
    PREV_CONFIG_LINES=("$unknown" "$known")
    GAME_SETTINGS_PLAN=()
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/manifest"
    : > "$INSTALL_MANIFEST"
    apply_game_settings
    [ "$(cat "$INSTALL_MANIFEST")" == "$unknown" ]
}

@test "apply_game_settings drops a record with an empty format field" {
    local f="$BATS_TEST_TMPDIR/a.ini"
    printf '[S]\nk=1\n' > "$f"
    PREV_CONFIG_LINES=("CONFIG:audio"$'\t'"t"$'\t'"$f")
    GAME_SETTINGS_PLAN=()
    INSTALL_MANIFEST="$BATS_TEST_TMPDIR/manifest"
    : > "$INSTALL_MANIFEST"
    apply_game_settings
    [ ! -s "$INSTALL_MANIFEST" ]
}

@test "revert_game_settings leaves a record with an unreadable format recorded and the file alone" {
    local f="$BATS_TEST_TMPDIR/a.ini" line
    printf '[S]\nk=2\n' > "$f"
    line="CONFIG:audio"$'\t'"t"$'\t'"$f"$'\t'"future_format"$'\t'"S"$'\t'"k"$'\t'"1"$'\t'"2"
    GAME_SETTINGS_REVERT_GROUPS=("audio"$'\x1f'"t"$'\x1f'"$line")
    GAME_SETTINGS_KEPT=()
    revert_game_settings || true
    [ "${#GAME_SETTINGS_KEPT[@]}" -eq 1 ]
    [ "${GAME_SETTINGS_KEPT[0]}" == "$line" ]
    [ "$(config_get_key "$f" ini S k)" == "2" ]
}
