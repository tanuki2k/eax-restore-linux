#!/usr/bin/env bats
# The binary gadb on/off switch and the Wine registry text editor.

load ../helpers

setup() {
    load_script_functions
    F="$BATS_TEST_TMPDIR/file"
}

# ---- binary_switches ---------------------------------------------------

@test "binary_switches: reads an on/off setting" {
    make_gadb "$F" EAX=1 Music=0
    [ "$(config_get_key "$F" binary_switches "" eax)" == "1" ]
    [ "$(config_get_key "$F" binary_switches "" Music)" == "0" ]
}

@test "binary_switches: unknown key reads as __ABSENT__" {
    make_gadb "$F" EAX=1
    [ "$(config_get_key "$F" binary_switches "" nothing)" == "__ABSENT__" ]
}

@test "binary_switches: switches a value in place without changing the file size" {
    make_gadb "$F" EAX=0 Music=1
    local before; before="$(stat -c %s "$F")"
    config_set_key "$F" binary_switches "" EAX 1
    [ "$(config_get_key "$F" binary_switches "" EAX)" == "1" ]
    [ "$(config_get_key "$F" binary_switches "" Music)" == "1" ]
    [ "$(stat -c %s "$F")" -eq "$before" ]
}

@test "binary_switches: refuses a value other than 0/1 and an absent key" {
    make_gadb "$F" EAX=0
    cp "$F" "$F.orig"
    run config_set_key "$F" binary_switches "" EAX 5
    [ "$status" -ne 0 ]
    run config_set_key "$F" binary_switches "" nothing 1
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "binary_switches: a file that is not GADB reads as absent and is not edited" {
    write_file "$F" 'not a gadb file at all, just some text here\n'
    [ "$(config_get_key "$F" binary_switches "" EAX)" == "__ABSENT__" ]
    run config_set_key "$F" binary_switches "" EAX 1
    [ "$status" -ne 0 ]
}

# ---- registry --------------------------------------------------------------

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

@test "registry: reads dword (decimal), string, raw and absent" {
    make_reg
    S='Software\Wow6432Node\Creative Labs\Test'
    [ "$(config_get_key "$F" registry "$S" Speakers)" == "2" ]
    [ "$(config_get_key "$F" registry "$S" Name)" == "Hello" ]
    [ "$(config_get_key "$F" registry "$S" Blob)" == "__RAW__" ]
    [ "$(config_get_key "$F" registry "$S" Nope)" == "__ABSENT__" ]
}

@test "registry: finds the key in the other registry view" {
    make_reg
    [ "$(config_get_key "$F" registry 'Software\Creative Labs\Test' Speakers)" == "2" ]
}

@test "registry: key and value names match case-insensitively" {
    make_reg
    [ "$(config_get_key "$F" registry 'software\wow6432node\creative labs\test' speakers)" == "2" ]
}

@test "registry: a dword stays a dword, written as 8 hex digits" {
    make_reg
    config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Speakers 255
    grep -q '^"Speakers"=dword:000000ff$' "$F"
}

@test "registry: a string stays a string" {
    make_reg
    config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Name World
    grep -q '^"Name"="World"$' "$F"
}

@test "registry: never touches a raw value" {
    make_reg; cp "$F" "$F.orig"
    run config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Blob 1
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "registry: a dword rejects a non-number and an over-range number" {
    make_reg; cp "$F" "$F.orig"
    run config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Speakers abc
    [ "$status" -ne 0 ]
    run config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Speakers 4294967296
    [ "$status" -ne 0 ]
    cmp "$F" "$F.orig"
}

@test "registry: other keys are untouched by an edit" {
    make_reg
    config_set_key "$F" registry 'Software\Other' X 1
    [ "$(config_get_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Speakers)" == "2" ]
    [ "$(config_get_key "$F" registry 'Software\Other' X)" == "1" ]
}

@test "registry: a new value in an existing key is a dword when numeric" {
    make_reg
    config_set_key "$F" registry 'Software\Other' Y 16
    grep -q '^"Y"=dword:00000010$' "$F"
}

@test "registry: a new key gets Wine's header lines at the end" {
    make_reg
    config_set_key "$F" registry 'Software\Brand New' Z 1
    grep -q '^\[Software\\\\Brand New\] [0-9]' "$F"
    [ "$(config_get_key "$F" registry 'Software\Brand New' Z)" == "1" ]
}

@test "registry: __DELETE__ removes the value" {
    make_reg
    config_set_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Name __DELETE__
    [ "$(config_get_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Name)" == "__ABSENT__" ]
    [ "$(config_get_key "$F" registry 'Software\Wow6432Node\Creative Labs\Test' Speakers)" == "2" ]
}
