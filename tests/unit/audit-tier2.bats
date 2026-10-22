#!/usr/bin/env bats
# Regressions from the second script audit: config edits that must round-trip
# byte for byte, and the launcher's DLL override list.

load ../helpers

setup() {
    load_script_functions
    F="$BATS_TEST_TMPDIR/cfg"
}

# Sets a key, then puts the original value back; the file must match what it was.
round_trip() {  # <fmt> <section> <key> <new> <original value to put back>
    cp "$F" "$F.orig"
    config_set_key "$F" "$1" "$2" "$3" "$4"
    config_set_key "$F" "$1" "$2" "$3" "$5"
    cmp "$F" "$F.orig"
}

@test "__ABSENT__ and __DELETE__ compare equal, so a deleted key can be reverted" {
    config_values_equal ini "__ABSENT__" "__DELETE__"
    config_values_equal ini "__DELETE__" "__ABSENT__"
    ! config_values_equal ini "x" "__DELETE__"
}

@test "ini: a file with LF first and CRLF after keeps each line's ending" {
    write_file "$F" '[a]\nx=1\r\ny=2\r\n'
    config_set_key "$F" ini a y 3
    [ "$(od -An -c "$F" | tr -d ' \n')" == '[a]\nx=1\r\ny=3\r\n' ]
}

@test "ini: a file with no final newline still has none after an edit" {
    write_file "$F" '[a]\nx=1\ny=2'
    config_set_key "$F" ini a y 3
    [ "$(tail -c1 "$F")" == "3" ]
    [ "$(cat "$F")" == $'[a]\nx=1\ny=3' ]
}

@test "ini: a UTF-8 BOM on the first line doesn't hide the first section" {
    write_file "$F" '\xef\xbb\xbf[a]\nx=1\n'
    [ "$(config_get_key "$F" ini a x)" == "1" ]
    config_set_key "$F" ini a x 2
    [ "$(grep -c '\[a\]' "$F")" -eq 1 ]
    [ "$(head -c3 "$F" | od -An -tx1 | tr -d ' ')" == "efbbbf" ]
    [ "$(config_get_key "$F" ini a x)" == "2" ]
}

@test "ini: a section header with a trailing comment still counts as the section" {
    write_file "$F" '[a] ; sound\nx=1\n[b]\nx=9\n'
    [ "$(config_get_key "$F" ini a x)" == "1" ]
    config_set_key "$F" ini a x 2
    [ "$(cat "$F")" == $'[a] ; sound\nx=2\n[b]\nx=9' ]
}

@test "ini: a UTF-16 file is refused rather than appended to" {
    printf '[\0a\0]\0\n\0' > "$F"
    cp "$F" "$F.orig"
    ! config_set_key "$F" ini a x 1
    cmp "$F" "$F.orig"
}

@test "gas_cfg: a header with a trailing comment is found" {
    write_file "$F" '[prefs] // audio\n{\n\ta = 1;\n}\n'
    [ "$(config_get_key "$F" gas_cfg prefs a)" == "1" ]
}

@test "idtech_cfg: set stays set and an unquoted value stays unquoted" {
    write_file "$F" 'set s_volume 5\nseta s_other "1"\n'
    config_set_key "$F" idtech_cfg "" s_volume 7
    config_set_key "$F" idtech_cfg "" s_other 2
    [ "$(cat "$F")" == $'set s_volume 7\nseta s_other "2"' ]
}

@test "dark_cfg: turning a flag back off removes the line the install added" {
    write_file "$F" 'Key1\n;eax_on\nKey2\n'
    cp "$F" "$F.orig"
    config_set_key "$F" dark_cfg "" eax_on __TRUE__
    [ "$(config_get_key "$F" dark_cfg "" eax_on)" == "__TRUE__" ]
    config_set_key "$F" dark_cfg "" eax_on __FALSE__
    cmp "$F" "$F.orig"
}

@test "wine_reg: a string with an escaped backslash before a quote reads back as written" {
    printf 'WINE REGISTRY Version 2\n\n[Software\\\\T] 1\n"N"="a\\\\\\"b"\n' > "$F"
    [ "$(config_get_key "$F" wine_reg 'Software\T' N)" == 'a\"b' ]
}

@test "merge_dll_override: dsound.dll and dsound are the same rule" {
    [ "$(merge_dll_override 'dsound.dll=n;foo=b' dsound)" == "foo=b;dsound=n,b" ]
    [ "$(merge_dll_override 'DSOUND=n,b' dsound)" == "dsound=n,b" ]
    [ "$(merge_dll_override 'a.dll,dsound.dll=n' dsound)" == "a.dll=n;dsound=n,b" ]
}
