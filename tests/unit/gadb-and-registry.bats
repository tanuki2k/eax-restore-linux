#!/usr/bin/env bats
# The binary gadb on/off switch and the Wine registry text editor.

load ../helpers

setup() {
    load_script_functions
    F="$BATS_TEST_TMPDIR/file"
}

# ---- gadb ------------------------------------------------------------------

@test "gadb: reads an on/off setting" {
    make_gadb "$F" EAX=1 Music=0
    [ "$(config_get_key "$F" gadb "" eax)" == "1" ]
    [ "$(config_get_key "$F" gadb "" Music)" == "0" ]
}

@test "gadb: unknown key reads as __ABSENT__" {
    make_gadb "$F" EAX=1
    [ "$(config_get_key "$F" gadb "" nothing)" == "__ABSENT__" ]
}

@test "gadb: switches a value in place without changing the file size" {
    make_gadb "$F" EAX=0 Music=1
    local before; before="$(stat -c %s "$F")"
    config_set_key "$F" gadb "" EAX 1
    [ "$(config_get_key "$F" gadb "" EAX)" == "1" ]
    [ "$(config_get_key "$F" gadb "" Music)" == "1" ]
    [ "$(stat -c %s "$F")" -eq "$before" ]
}

@test "gadb: refuses a value other than 0/1 and an absent key" {
    make_gadb "$F" EAX=0
    cp "$F" "$F.orig"
    run config_set_key "$F" gadb "" EAX 5
    [ "$status" -ne 0 ]
    run config_set_key "$F" gadb "" nothing 1
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "gadb: a file that is not GADB reads as absent and is not edited" {
    write_file "$F" 'not a gadb file at all, just some text here\n'
    [ "$(config_get_key "$F" gadb "" EAX)" == "__ABSENT__" ]
    run config_set_key "$F" gadb "" EAX 1
    [ "$status" -ne 0 ]
}

# ---- wine_reg --------------------------------------------------------------

make_reg() {
    cat > "$F" <<'REG'
WINE REGISTRY Version 2
;; All keys relative to \\Machine

[Software\\Wow6432Node\\Creative Labs\\Test] 1700000000
#time=1d9
"Speakers"=dword:00000002
"Name"="Hello"
"Blob"=hex:01,02,03

[Software\\Other] 1700000001
#time=1d9
"X"=dword:0000000a
REG
}

@test "wine_reg: reads dword (decimal), string, raw and absent" {
    make_reg
    S='Software\Wow6432Node\Creative Labs\Test'
    [ "$(config_get_key "$F" wine_reg "$S" Speakers)" == "2" ]
    [ "$(config_get_key "$F" wine_reg "$S" Name)" == "Hello" ]
    [ "$(config_get_key "$F" wine_reg "$S" Blob)" == "__RAW__" ]
    [ "$(config_get_key "$F" wine_reg "$S" Nope)" == "__ABSENT__" ]
}

@test "wine_reg: finds the key in the other registry view" {
    make_reg
    [ "$(config_get_key "$F" wine_reg 'Software\Creative Labs\Test' Speakers)" == "2" ]
}

@test "wine_reg: key and value names match case-insensitively" {
    make_reg
    [ "$(config_get_key "$F" wine_reg 'software\wow6432node\creative labs\test' speakers)" == "2" ]
}

@test "wine_reg: a dword stays a dword, written as 8 hex digits" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Speakers 255
    grep -q '^"Speakers"=dword:000000ff$' "$F"
}

@test "wine_reg: a string stays a string" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Name World
    grep -q '^"Name"="World"$' "$F"
}

@test "wine_reg: never touches a raw value" {
    make_reg; cp "$F" "$F.orig"
    run config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Blob 1
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "wine_reg: a dword rejects a non-number and an over-range number" {
    make_reg; cp "$F" "$F.orig"
    run config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Speakers abc
    [ "$status" -ne 0 ]
    run config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Speakers 4294967296
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "wine_reg: other keys are untouched by an edit" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Other' X 1
    [ "$(config_get_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Speakers)" == "2" ]
    [ "$(config_get_key "$F" wine_reg 'Software\Other' X)" == "1" ]
}

@test "wine_reg: a new value in an existing key is a dword when numeric" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Other' Y 16
    grep -q '^"Y"=dword:00000010$' "$F"
}

@test "wine_reg: a new key gets Wine's header lines at the end" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Brand New' Z 1
    grep -q '^\[Software\\\\Brand New\] [0-9]' "$F"
    [ "$(config_get_key "$F" wine_reg 'Software\Brand New' Z)" == "1" ]
}

@test "wine_reg: __DELETE__ removes the value" {
    make_reg
    config_set_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Name __DELETE__
    [ "$(config_get_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Name)" == "__ABSENT__" ]
    [ "$(config_get_key "$F" wine_reg 'Software\Wow6432Node\Creative Labs\Test' Speakers)" == "2" ]
}
