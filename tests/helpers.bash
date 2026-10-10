# Shared bats helpers. Sources the script's function files straight from src/
# (they only define functions and variables, so nothing runs).

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

load_script_functions() {
    local f
    # shellcheck disable=SC1090
    for f in globals ui common game-config launcher-config; do
        source "$REPO_ROOT/src/$f.sh"
    done
}

# Usage: write_file <path> <text...>
# Writes the text with printf '%b', so \r and \n escapes work.
write_file() {
    local path="$1"; shift
    printf '%b' "$*" > "$path"
}

# Usage: make_gadb <file> <name>=<0|1> ...
# A minimal valid GADB file: header, string table, one on/off record per
# setting ([name offset, type 1, 0, count 1, value], little-endian).
make_gadb() {
    local file="$1"; shift
    local table="" offsets=() kv name
    for kv in "$@"; do
        name="${kv%%=*}"
        offsets+=("${#table}")
        table+="$name"$'\x01'   # placeholder, swapped for NUL below
    done
    local tlen=${#table}
    u32() { printf "\\x%02x\\x%02x\\x%02x\\x%02x" $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }
    {
        printf 'GADB'; printf '\x00\x00\x00\x00'
        printf "$(u32 "$tlen")"
        printf '\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00'
        printf '%s' "$table" | tr '\001' '\000'
        # pad the string table to a 4-byte boundary like the real format
        local end=$((28 + tlen)) pad=$(( (4 - (28 + tlen) % 4) % 4 ))
        for ((i = 0; i < pad; i++)); do printf '\x00'; done
        local idx=0
        for kv in "$@"; do
            printf "$(u32 "${offsets[$idx]}")"; printf "$(u32 1)"; printf "$(u32 0)"; printf "$(u32 1)"
            printf "$(u32 "${kv#*=}")"
            idx=$((idx + 1))
        done
    } > "$file"
}
