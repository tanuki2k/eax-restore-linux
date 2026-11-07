# ==============================================================================
# GAME SETTINGS (game profile game_config / install.alsoft_ini)
# ==============================================================================
# Everything the script changes in a game's own config files comes from that
# game's profile (game_config.audio_settings / optional_settings) — the script
# itself only knows how to read and edit the ten config formats, never which
# game needs what. Decided in phases 2-3 (Speaker Configuration, then phase 3's Game Audio
# Settings offers the alsoft.ini values and the game's own settings), applied in
# Phase 4, recorded in the manifest as CONFIG: lines, reverted on uninstall.
#
# Values travel through here as plain strings plus three markers:
#   __TRUE__ / __FALSE__  a key_value flag switched on / off (true/false in JSON)
#   __DELETE__            remove the key (null in JSON)
#   __ABSENT__            (read side only) the key isn't in the file

# Usage: _gadb_find <file> <key>
# The binary_switches format is Monolith's binary game database, which F.E.A.R. keeps its player
# profile in (Profile000.gdb): a "GADB" header with the string table's size
# at byte 8, the string table from byte 28 (NUL-separated names), then
# 4-byte-aligned little-endian records of [name's offset in the string
# table, type, 0, count, value...]. Prints "<byte position of the value>
# <value>" for the key's one on/off record (type 1, count 1), and nothing
# when there's none, more than one, or the file isn't a GADB file. Read a
# byte at a time through od, so it's endian-safe and needs nothing extra.
_gadb_find() {
    od -An -v -tu1 -w1 "$1" 2>/dev/null | LC_ALL=C awk -v key="$2" '
        { b[n++] = $1 + 0 }
        function u32(i) { return b[i] + b[i+1] * 256 + b[i+2] * 65536 + b[i+3] * 16777216 }
        END {
            if (n < 28 || b[0] != 71 || b[1] != 65 || b[2] != 68 || b[3] != 66) exit
            sl = u32(8); end = 28 + sl; if (end > n) exit
            lkey = tolower(key); ko = -1; s = ""; start = 28
            for (i = 28; i < end; i++) {
                if (b[i] == 0) {
                    if (ko < 0 && tolower(s) == lkey) ko = start - 28
                    s = ""; start = i + 1
                } else s = s sprintf("%c", b[i])
            }
            if (ko < 0) exit
            hits = 0
            for (i = end + (4 - end % 4) % 4; i + 20 <= n; i += 4)
                if (u32(i) == ko && u32(i+4) == 1 && u32(i+8) == 0 && u32(i+12) == 1) { hits++; pos = i + 16 }
            if (hits == 1) print pos, u32(pos)
        }'
}

# registry is one of Wine's registry files, system.reg (HKLM) or user.reg
# (HKCU), which Wine keeps as text in the prefix: "[Key\\Path] <time>"
# headers with doubled backslashes, then "Name"=dword:0000000a or
# "Name"="text" lines. The section is the key's path with single
# backslashes, the key a value name, both matched case-insensitively like
# Windows. A dword reads and is written as a decimal number. Any other type
# (hex:, str(2):, ...) reads as __RAW__ and is never changed.

# Usage: _wine_reg_section <file> <key path>
# The key path to use: the given one, or when the file doesn't have it, the
# same key in the other registry view (with or without Wow6432Node\, so an
# entry written for a 64-bit prefix also finds a 32-bit prefix's key).
# Prints the given path when neither exists.
_wine_reg_section() {
    local alt
    if [[ "${2,,}" == software\\wow6432node\\* ]]; then alt="Software\\${2:21}"
    elif [[ "${2,,}" == software\\* ]]; then alt="Software\\Wow6432Node\\${2:9}"; fi
    if [ -n "$alt" ] && ! _wine_reg_has_key "$1" "$2" && _wine_reg_has_key "$1" "$alt"; then
        echo "$alt"
    else
        echo "$2"
    fi
}

# Usage: _wine_reg_has_key <file> <key path>
# Names reach awk through ENVIRON, since -v would collapse the backslashes.
_wine_reg_has_key() {
    SEC="${2//\\/\\\\}" LC_ALL=C awk 'BEGIN { want = "[" tolower(ENVIRON["SEC"]) "]" }
        /^\[/ { h = $0; sub(/\][^]]*$/, "]", h); if (tolower(h) == want) { found = 1; exit } }
        END { exit !found }' "$1"
}

# Usage: _wine_reg_read <file> <key path> <value name>
# Prints "<type><TAB><value>": dword (as a decimal number), string,
# raw (any other type; value __RAW__) or absent (value __ABSENT__).
_wine_reg_read() {
    local sec
    sec="$(_wine_reg_section "$1" "$2")"
    SEC="${sec//\\/\\\\}" NAME="$3" LC_ALL=C awk '
        BEGIN { want = "[" tolower(ENVIRON["SEC"]) "]"; pre = tolower("\"" ENVIRON["NAME"] "\"=") }
        function unesc(t,   i, n, c, d, o) {
            n = length(t); o = ""
            for (i = 1; i <= n; i++) {
                c = substr(t, i, 1)
                if (c == "\\" && i < n) { d = substr(t, i + 1, 1); if (d == "\\" || d == "\"") { c = d; i++ } }
                o = o c
            }
            return o
        }
        function hex2dec(h,   i, d) { d = 0; h = tolower(h)
            for (i = 1; i <= length(h); i++) d = d * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
            return d }
        /^\[/ { h = $0; sub(/\][^]]*$/, "]", h); insec = (tolower(h) == want); next }
        insec && tolower(substr($0, 1, length(pre))) == pre {
            v = substr($0, length(pre) + 1)
            if (v ~ /^dword:[0-9a-fA-F]+$/) printf "dword\t%d\n", hex2dec(substr(v, 7))
            else if (v ~ /^".*"$/) {
                v = unesc(substr(v, 2, length(v) - 2))
                printf "string\t%s\n", v
            } else print "raw\t__RAW__"
            found = 1; exit
        }
        END { if (!found) print "absent\t__ABSENT__" }' "$1"
}

# Usage: _wine_reg_set <file> <key path> <value name> <value>
# config_set_key for registry. A value keeps its type: a dword stays a dword
# (so the new value must be a number), a string stays a string. A new value
# is a dword when it's a number, else a string; a new key goes at the end of
# the file with Wine's own header lines. Never touches a raw value. Only
# safe while Wine isn't running in the prefix (wine_registry_quiet), since
# wineserver writes the file back from memory when it exits.
_wine_reg_set() {
    local file="$1" sec key="$3" value="$4" type now tmp
    [ -f "$file" ] || return 1
    sec="$(_wine_reg_section "$file" "$2")"
    type="$(_wine_reg_read "$file" "$sec" "$key")"; type="${type%%$'\t'*}"
    [ "$type" == "raw" ] && return 1
    if [ "$value" != "__DELETE__" ]; then
        if [ "$type" == "dword" ] || { [ "$type" == "absent" ] && [[ "$value" =~ ^[0-9]+$ ]]; }; then
            [[ "$value" =~ ^[0-9]{1,10}$ ]] && [ "$((10#$value))" -le 4294967295 ] || return 1
            value="dword:$(printf '%08x' "$((10#$value))")"
        else
            value="${value//\\/\\\\}"; value="${value//\"/\\\"}"
            value="\"$value\""
        fi
    fi
    now="$(date +%s)"
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    # #time= is the key's FILETIME (100 ns steps since 1601), as Wine writes it.
    SEC="${sec//\\/\\\\}" NAME="$key" VAL="$value" NOW="$now" \
        FT="$(printf '%x' $(( (now + 11644473600) * 10000000 )))" LC_ALL=C awk '
        BEGIN { sec = ENVIRON["SEC"]; want = "[" tolower(sec) "]"; name = ENVIRON["NAME"]
            pre = tolower("\"" name "\"="); val = ENVIRON["VAL"]; del = (val == "__DELETE__") }
        function line() { return "\"" name "\"=" val }
        function flush_blanks() { while (nb > 0) { print ""; nb-- } }
        /^\[/ {
            if (insec && !done && !del) { print line(); done = 1 }
            flush_blanks()
            h = $0; sub(/\][^]]*$/, "]", h); insec = (tolower(h) == want); if (insec) seen = 1
            print; next
        }
        /^$/ { nb++; next }
        { flush_blanks() }
        insec && !done && tolower(substr($0, 1, length(pre))) == pre {
            done = 1
            if (!del) print substr($0, 1, length(pre)) val
            next
        }
        { print }
        END {
            if (insec && !done && !del) { print line(); done = 1 }
            flush_blanks()
            if (!seen && !del) { print ""; print "[" sec "] " ENVIRON["NOW"]; print "#time=" ENVIRON["FT"]; print line() }
        }' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    swap_in "$tmp" "$file"
}

# Usage: _byte_offset <key>
# binary_offset keys are byte positions in the file, counted from 0, written in
# decimal or as 0x hex. Prints the decimal position, or fails for anything else.
_byte_offset() {
    if [[ "$1" =~ ^0[xX][0-9a-fA-F]{1,8}$ ]]; then echo "$((16#${1:2}))"
    elif [[ "$1" =~ ^[0-9]{1,9}$ ]]; then echo "$((10#$1))"
    else return 1; fi
}

# Usage: _byte_get <file> <key>
# Prints the byte at the key's position as a decimal 0-255, or __ABSENT__
# when the file is shorter than that.
_byte_get() {
    local off value
    off="$(_byte_offset "$2")" || { echo "__ABSENT__"; return; }
    [ "$off" -lt "$(stat -c %s "$1" 2>/dev/null || echo 0)" ] || { echo "__ABSENT__"; return; }
    value="$(od -An -v -tu1 -j "$off" -N1 "$1" 2>/dev/null | tr -d ' ')"
    echo "${value:-__ABSENT__}"
}

# Usage: _byte_set <file> <key> <0-255>
# config_set_key for binary_offset: overwrites the one byte in place (Messiah's
# Messiah.cfg keeps its sound driver in a byte or two). Never grows the file,
# so a position past its end or a value outside 0-255 returns 1. Writes a
# copy in the same folder, checks the byte reads back, then swaps it in.
_byte_set() {
    local file="$1" key="$2" value="$3" off tmp
    [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 255 ] || return 1
    off="$(_byte_offset "$key")" || return 1
    [ "$(_byte_get "$file" "$key")" != "__ABSENT__" ] || return 1
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    if cp -f "$file" "$tmp" 2>/dev/null \
        && printf "$(printf '\\%03o' "$((10#$value))")" | dd of="$tmp" bs=1 seek="$off" conv=notrunc status=none 2>/dev/null \
        && [ "$(_byte_get "$tmp" "$key")" == "$((10#$value))" ]; then
        swap_in "$tmp" "$file" && return 0
    fi
    rm -f "$tmp"
    return 1
}

# Usage: _lenstr_find <file> <anchor>
# binary_text keys are an even-length hex string, the bytes that sit right
# before a 4-byte little-endian length and then that many characters of text
# (Freedom Force's options.dat keeps its sound driver's name that way). Prints
# "<position of the length> <length> <text>" for the first match whose length
# is 1-64 and whose text is all printable ASCII, so a stray copy of the anchor
# bytes inside other data is skipped. Fails when there's no such match.
_lenstr_find() {
    local file="$1" anchor="${2,,}" hex
    [[ "$anchor" =~ ^([0-9a-f]{2}){1,16}$ ]] || return 1
    [ -f "$file" ] || return 1
    hex="$(od -An -v -tx1 "$file" 2>/dev/null | tr -d ' \n')"
    [ -n "$hex" ] || return 1
    LC_ALL=C awk -v hex="$hex" -v anchor="$anchor" '
        function byte(i) { return 16 * index(digits, substr(hex, 2 * i + 1, 1)) - 16 + index(digits, substr(hex, 2 * i + 2, 1)) - 1 }
        BEGIN {
            digits = "0123456789abcdef"
            size = length(hex) / 2; alen = length(anchor) / 2; from = 1
            while ((at = index(substr(hex, from), anchor)) > 0) {
                at += from - 1; from = at + 1
                if ((at - 1) % 2) continue
                pos = (at - 1) / 2 + alen
                if (pos + 4 > size) continue
                n = byte(pos) + 256 * byte(pos + 1) + 65536 * byte(pos + 2) + 16777216 * byte(pos + 3)
                if (n < 1 || n > 64 || pos + 4 + n > size) continue
                text = ""; ok = 1
                for (i = 0; i < n; i++) {
                    c = byte(pos + 4 + i)
                    if (c < 32 || c > 126) { ok = 0; break }
                    text = text sprintf("%c", c)
                }
                if (ok) { print pos, n, text; exit 0 }
            }
            exit 1
        }'
}

# Usage: _lenstr_get <file> <key>
# Prints the text, or __ABSENT__ when the anchor isn't in the file. A key written
# <anchor>+<N> names the single byte N bytes past the end of that text instead
# (Freedom Force keeps its speaker layout there), as a decimal 0-255. That
# distance holds when the text changes length, which a position from the
# start of the file doesn't.
_lenstr_get() {
    local file="$1" key="$2" found pos len off value
    found="$(_lenstr_find "$file" "${key%%+*}")" || { echo "__ABSENT__"; return; }
    if [[ "$key" == *+* ]]; then
        [[ "${key#*+}" =~ ^[0-9]{1,5}$ ]] || { echo "__ABSENT__"; return; }
        pos="${found%% *}"; len="${found#* }"; len="${len%% *}"
        off=$((pos + 4 + len + 10#${key#*+}))
        [ "$off" -lt "$(stat -c %s "$file" 2>/dev/null || echo 0)" ] || { echo "__ABSENT__"; return; }
        value="$(od -An -v -tu1 -j "$off" -N1 "$file" 2>/dev/null | tr -d ' ')"
        echo "${value:-__ABSENT__}"
        return
    fi
    echo "${found#* * }"
}

# Usage: _lenstr_set <file> <key> <value>
# config_set_key for binary_text. For a plain anchor it swaps the text for a new
# one of any length (1-64 characters), writing its new length in front. For
# <anchor>+<N> it overwrites that one byte with a number 0-255. Every other
# byte stays as it was, and a file that doesn't have the text or the byte is
# never grown. Writes a copy in the same folder, checks the new value reads
# back, then swaps it in.
_lenstr_set() {
    local file="$1" key="$2" value="$3" found pos len tmp n
    found="$(_lenstr_find "$file" "${key%%+*}")" || return 1
    pos="${found%% *}"; len="${found#* }"; len="${len%% *}"
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    if [[ "$key" == *+* ]]; then
        [[ "${key#*+}" =~ ^[0-9]{1,5}$ ]] && [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 255 ] || { rm -f "$tmp"; return 1; }
        [ "$(_lenstr_get "$file" "$key")" != "__ABSENT__" ] || { rm -f "$tmp"; return 1; }
        if cp -f "$file" "$tmp" 2>/dev/null \
            && printf "$(printf '\\%03o' "$((10#$value))")" | dd of="$tmp" bs=1 seek="$((pos + 4 + len + 10#${key#*+}))" conv=notrunc status=none 2>/dev/null \
            && [ "$(_lenstr_get "$tmp" "$key")" == "$((10#$value))" ]; then
            swap_in "$tmp" "$file" && return 0
        fi
        rm -f "$tmp"
        return 1
    fi
    n="${#value}"
    if [[ "$value" =~ ^[A-Za-z0-9._\ ()-]{1,64}$ ]] \
        && { head -c "$pos" "$file"
             printf "$(printf '\\%03o\\000\\000\\000' "$n")"
             printf '%s' "$value"
             tail -c +"$((pos + 4 + len + 1))" "$file"
           } > "$tmp" 2>/dev/null \
        && [ "$(_lenstr_get "$tmp" "$key")" == "$value" ]; then
        swap_in "$tmp" "$file" && return 0
    fi
    rm -f "$tmp"
    return 1
}

# The current format names: every one, and the ones that are plain text
# files (the rest are binary files or the registry, each with its own
# reader). Edit these when a format is added or renamed; the usage comments
# of config_get_key and config_set_key, upgrade_format_name and the schema
# list the names too.
CONFIG_FORMATS_RE='^(ini|set_commands|key_value|braced_pairs|ini_braces|quoted_pairs|binary_offset|binary_text|binary_switches|registry)$'
CONFIG_TEXT_FORMATS_RE='^(ini|set_commands|key_value|braced_pairs|ini_braces|quoted_pairs)$'

# Usage: config_format_unreadable <format>
# True for a record's format that is named but not one this script knows (a
# newer build wrote it). Such a record can't be checked or put back, so it is
# kept in the manifest. An empty format is a damaged line, not an unknown
# format, and is treated like any other record with nothing to act on.
config_format_unreadable() {
    [ -n "$1" ] && [[ ! "$1" =~ $CONFIG_FORMATS_RE ]]
}

# Usage: upgrade_format_name <format>
# Sets UPGRADED_FORMAT to the format's current name: dev builds from before
# the formats were renamed wrote the old names into the manifest. A current
# or unknown name is kept as it is. Only upgrade_config_line calls it: a
# manifest line is upgraded once, where it is read, because everything after
# that (the registry guard, config_values_equal, config_get_key and
# config_set_key, the kept-versus-dropped comparison) tests the current
# spelling. Delete this once no dev install from before 0.29 is expected to
# still be around.
UPGRADED_FORMAT=""
upgrade_format_name() {
    case "$1" in
        flat_ini) UPGRADED_FORMAT="ini" ;;
        gas_cfg) UPGRADED_FORMAT="ini_braces" ;;
        idtech_cfg) UPGRADED_FORMAT="set_commands" ;;
        dark_cfg|ltx) UPGRADED_FORMAT="key_value" ;;
        brace_cfg) UPGRADED_FORMAT="braced_pairs" ;;
        quoted_cfg) UPGRADED_FORMAT="quoted_pairs" ;;
        byte_cfg) UPGRADED_FORMAT="binary_offset" ;;
        lenstr_cfg) UPGRADED_FORMAT="binary_text" ;;
        gadb) UPGRADED_FORMAT="binary_switches" ;;
        wine_reg) UPGRADED_FORMAT="registry" ;;
        *) UPGRADED_FORMAT="$1" ;;
    esac
}

# Usage: upgrade_config_line <manifest line>
# Sets UPGRADED_LINE to the line with its format field (the fourth of a
# CONFIG: line) in the current spelling; any other line is kept as it is.
# The manifest lines kept and dropped by a revert are compared as text, so
# both sides go through this. Sets a variable instead of printing so the
# callers don't fork a subshell per line.
UPGRADED_LINE=""
upgrade_config_line() {
    local line="$1" rest old
    UPGRADED_LINE="$line"
    [[ "$line" == CONFIG:*$'\t'*$'\t'*$'\t'* ]] || return 0
    rest="${line#*$'\t'*$'\t'*$'\t'}"
    old="${rest%%$'\t'*}"
    upgrade_format_name "$old"
    UPGRADED_LINE="${line%"$rest"}${UPGRADED_FORMAT}${rest#"$old"}"
}

# awk source shared by config_get_key and config_set_key, so the two agree on
# what a section header is. Spliced into each program between its quotes.
_CONFIG_AWK_IS_HEADER='        function is_header(l,   n, r) {
            if (!match(l, /^[ \t]*\[[^]]*\]/)) return 0
            n = substr(l, 1, RLENGTH); r = substr(l, RLENGTH + 1)
            if (r !~ /^[ \t]*(([;#]|\/\/).*)?$/) return 0
            sub(/^[ \t]*\[/, "", n); sub(/\]$/, "", n); hname = n
            return 1
        }'

# Usage: config_get_key <file> <ini|set_commands|key_value|braced_pairs|ini_braces|quoted_pairs|binary_offset|binary_text|binary_switches|registry> <section> <key>
# Prints the key's current value, __ABSENT__ if it isn't set, or (key_value
# only) __TRUE__ for an active bare flag and __FALSE__ for a flag that's only
# present commented out. Section and key names match case-insensitively, like
# the games themselves read them. braced_pairs is "{key} = {value}"
# lines. ini_braces is a "[section]" line, "{" on its own
# line, then "key = value;" lines up to "}". A binary_switches key is one on/off setting, 0 or 1.
# Takes the current format names only: a manifest line's format goes through
# upgrade_config_line first. An unknown name prints a message to stderr and
# returns 1 rather than reading a registry or binary file as text.
config_get_key() {
    local file="$1" fmt="$2" sec="$3" key="$4" found
    # Checked before the file exists, so a stale name fails the same way
    # whether or not the game's file is there.
    [[ "$fmt" =~ $CONFIG_FORMATS_RE ]] || {
        echo "config_get_key: unknown format '$fmt'" >&2; return 1; }
    [ -f "$file" ] || { echo "__ABSENT__"; return; }
    if [ "$fmt" == "registry" ]; then
        found="$(_wine_reg_read "$file" "$sec" "$key")"; echo "${found#*$'\t'}"
        return
    fi
    if [ "$fmt" == "binary_offset" ]; then _byte_get "$file" "$key"; return; fi
    if [ "$fmt" == "binary_text" ]; then _lenstr_get "$file" "$key"; return; fi
    if [ "$fmt" == "binary_switches" ]; then
        found="$(_gadb_find "$file" "$key")"
        if [ -n "$found" ]; then echo "${found#* }"; else echo "__ABSENT__"; fi
        return
    fi
    LC_ALL=C awk -v fmt="$fmt" -v sec="$sec" -v key="$key" '
'"$_CONFIG_AWK_IS_HEADER"'
        BEGIN { lsec = tolower(sec); lkey = tolower(key); insec = (fmt != "ini" && fmt != "ini_braces") || (fmt == "ini" && sec == ""); found = 0; commented = 0 }
        { sub(/\r$/, "") }
        NR == 1 && substr($0, 1, 3) == "\357\273\277" { $0 = substr($0, 4) }
        fmt == "ini" {
            if (is_header($0)) { insec = (tolower(hname) == lsec); next }
            if (!insec) next
            p = index($0, "="); if (p == 0) next
            k = substr($0, 1, p - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (tolower(k) != lkey) next
            v = substr($0, p + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v; found = 1; exit
        }
        fmt == "set_commands" {
            line = $0; if (!match(tolower(line), /^[ \t]*seta?[ \t]+/)) next
            rest = substr(line, RLENGTH + 1); split(rest, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) next
            v = substr(rest, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
            print v; found = 1; exit
        }
        fmt == "key_value" {
            line = $0; is_comment = (line ~ /^[ \t]*;/)
            sub(/^[ \t]*;?[ \t]*/, "", line); split(line, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) next
            if (is_comment) { commented = 1; next }
            v = substr(line, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            print (v == "" ? "__TRUE__" : v); found = 1; exit
        }
        fmt == "quoted_pairs" {
            if (!match($0, /^[ \t]*"[^"]*"[ \t]*/)) next
            k = substr($0, 1, RLENGTH); v = substr($0, RLENGTH + 1)
            sub(/^[ \t]*"/, "", k); sub(/"[ \t]*$/, "", k)
            if (tolower(k) != lkey) next
            sub(/[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
            print v; found = 1; exit
        }
        fmt == "braced_pairs" {
            if (!match($0, /^[ \t]*\{[^}]*\}[ \t]*=[ \t]*\{/)) next
            k = substr($0, 1, RLENGTH); sub(/^[ \t]*\{[ \t]*/, "", k); sub(/[ \t]*\}.*$/, "", k)
            if (tolower(k) != lkey) next
            v = substr($0, RLENGTH + 1); sub(/\}[ \t]*$/, "", v)
            print v; found = 1; exit
        }
        fmt == "ini_braces" {
            if (is_header($0)) { insec = (tolower(hname) == lsec); next }
            if (!insec) next
            p = index($0, "="); if (p == 0) next
            k = substr($0, 1, p - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (tolower(k) != lkey) next
            v = substr($0, p + 1); gsub(/^[ \t]+|;?[ \t]*$/, "", v)
            print v; found = 1; exit
        }
        END { if (!found) print ((fmt == "key_value" && commented) ? "__FALSE__" : "__ABSENT__") }
    ' "$file"
}

# Usage: _gadb_set <file> <key> <0|1>
# config_set_key for binary_switches: overwrites the value of the key's existing on/off
# record in place. Never adds or removes a record, since the file's offsets
# would all move, so an absent key or any value but 0/1 returns 1. Writes a
# copy in the same folder, checks the new value reads back, then swaps it in.
_gadb_set() {
    local file="$1" key="$2" value="$3" found tmp
    [[ "$value" =~ ^[01]$ ]] || return 1
    found="$(_gadb_find "$file" "$key")"
    [ -n "$found" ] || return 1
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    if cp -f "$file" "$tmp" 2>/dev/null \
        && { if [ "$value" == "1" ]; then printf '\x01\x00\x00\x00'; else printf '\x00\x00\x00\x00'; fi; } \
            | dd of="$tmp" bs=1 seek="${found%% *}" conv=notrunc status=none 2>/dev/null \
        && [ "$(_gadb_find "$tmp" "$key")" == "${found%% *} $value" ]; then
        swap_in "$tmp" "$file" && return 0
    fi
    rm -f "$tmp"
    return 1
}

# Usage: config_set_key <file> <ini|set_commands|key_value|braced_pairs|ini_braces|quoted_pairs|binary_offset|binary_text|binary_switches|registry> <section> <key> <value>
# Sets (or with __DELETE__ removes) one key, keeping everything else in the
# file as it was — including CRLF line endings, the original spelling of an
# existing key, and "key = value" spacing. A missing ini key goes at the end
# of its section (or a new section at the end of the file); a missing key in
# any other format is appended. Section "" is the top of an ini file, before its
# first [header], or a whole file with no headers.
# quoted_pairs is "key" "value" lines, both quoted. An existing braced_pairs key only has the text between
# its value's braces replaced. For key_value, a commented-out example line is left in place and
# the active line is added right after it. binary_switches only switches an existing
# on/off setting (see _gadb_set), binary_offset one byte at a position (_byte_set), and binary_text a length-prefixed text found by the bytes before it (_lenstr_set). Writes through a temp file in the
# same folder and swaps it in, so a failure never leaves a half-written file.
# Returns 1 if the file couldn't be written or the format isn't a current name
# (a manifest line's format goes through upgrade_config_line first).
config_set_key() {
    local file="$1" fmt="$2" sec="$3" key="$4" value="$5"
    local crlf=0 current tmp
    [ "$fmt" == "binary_offset" ] && { _byte_set "$file" "$key" "$value"; return; }
    [ "$fmt" == "binary_text" ] && { _lenstr_set "$file" "$key" "$value"; return; }
    [ "$fmt" == "binary_switches" ] && { _gadb_set "$file" "$key" "$value"; return; }
    [ "$fmt" == "registry" ] && { _wine_reg_set "$file" "$sec" "$key" "$value"; return; }
    # Anything else would match no rule below and write out an empty file.
    [[ "$fmt" =~ $CONFIG_TEXT_FORMATS_RE ]] || return 1
    # Judged by the first line for lines this adds to an empty or new file; every
    # existing line keeps its own ending.
    [ -f "$file" ] && head -n 1 "$file" 2>/dev/null | LC_ALL=C grep -q $'\r' && crlf=1
    # UTF-16 text (NUL bytes) can't be edited as ASCII lines.
    if [ -s "$file" ] && ! tr -d '\0' < "$file" | cmp -s - "$file"; then return 1; fi
    current="$(config_get_key "$file" "$fmt" "$sec" "$key")"
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    { [ -f "$file" ] && cat "$file"; } | LC_ALL=C awk -v fmt="$fmt" -v sec="$sec" -v key="$key" -v val="$value" \
        -v crlf="$crlf" -v current="$current" '
        function outl(line, e) {
            if (bom) { line = "\357\273\277" line; bom = 0 }
            printf "%s%s", line, e
        }
        function out(line) { outl(line, eol) }
        function flush_blanks(   i) { for (i = 1; i <= nb; i++) outl("", beol[i]); nb = 0 }
'"$_CONFIG_AWK_IS_HEADER"'
        function ini_line() { return key "=" val }
        BEGIN {
            lsec = tolower(sec); lkey = tolower(key); insec = (fmt == "ini" && sec == ""); seen_sec = insec; done = 0; nb = 0
            del = (val == "__DELETE__"); eol = (crlf ? "\r\n" : "\n"); prev_c = 0
            active = (current != "__ABSENT__" && current != "__FALSE__")
        }
        # Each line keeps its own ending, and a UTF-8 BOM stays on line 1;
        # lines this adds take the ending of the line before them.
        { eol = ($0 ~ /\r$/) ? "\r\n" : "\n"; sub(/\r$/, "") }
        NR == 1 && substr($0, 1, 3) == "\357\273\277" { bom = 1; $0 = substr($0, 4) }
        fmt == "ini" {
            if (is_header($0)) {
                if (insec && !done && !del) { out(ini_line()); done = 1 }
                flush_blanks()
                insec = (tolower(hname) == lsec); if (insec) seen_sec = 1
                out($0); next
            }
            if ($0 ~ /^[ \t]*$/) { nb++; beol[nb] = eol; next }
            flush_blanks()
            if (insec && !done) {
                p = index($0, "=")
                if (p > 0) {
                    k = substr($0, 1, p - 1); kt = k; gsub(/^[ \t]+|[ \t]+$/, "", kt)
                    if (tolower(kt) == lkey) {
                        done = 1
                        if (del) next
                        sp = (substr($0, p + 1, 1) == " ") ? " " : ""
                        out(k "=" sp val); next
                    }
                }
            }
            out($0); next
        }
        fmt == "ini_braces" {
            if (is_header($0)) {
                if (insec && !done && !del) { out("\t" key " = " val ";"); done = 1 }
                insec = (tolower(hname) == lsec); if (insec) seen_sec = 1
                out($0); next
            }
            if (insec && !done && $0 ~ /^[ \t]*\}/) {
                if (!del) out("\t" key " = " val ";")
                done = 1; out($0); insec = 0; next
            }
            if (insec && !done) {
                p = index($0, "=")
                if (p > 0) {
                    k = substr($0, 1, p - 1); kt = k; gsub(/^[ \t]+|[ \t]+$/, "", kt)
                    if (tolower(kt) == lkey) {
                        done = 1
                        if (del) next
                        sp = (substr($0, p + 1, 1) == " ") ? " " : ""
                        out(k "=" sp val ";"); next
                    }
                }
            }
            out($0); next
        }
        fmt == "set_commands" {
            line = $0
            if (!done && match(tolower(line), /^[ \t]*seta?[ \t]+/)) {
                lead = substr(line, 1, RLENGTH); rest = substr(line, RLENGTH + 1); split(rest, a, /[ \t]+/)
                if (tolower(a[1]) == lkey) {
                    done = 1; if (del) next
                    # Keep set / seta, the spacing and whether the value was quoted.
                    vrest = substr(rest, length(a[1]) + 1); match(vrest, /^[ \t]*/)
                    gap = substr(vrest, 1, RLENGTH); if (gap == "") gap = " "
                    quoted = (substr(vrest, RLENGTH + 1, 1) == "\"")
                    out(lead a[1] gap ((quoted || val == "" || val ~ /[ \t]/) ? "\"" val "\"" : val)); next
                }
            }
            out(line); next
        }
        fmt == "key_value" {
            line = $0; is_comment = (line ~ /^[ \t]*;/)
            t = line; sub(/^[ \t]*;?[ \t]*/, "", t); split(t, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) { prev_c = 0; out(line); next }
            if (!is_comment) {
                if (del) next
                # An active line straight after the commented example of the key is
                # one an earlier write added: turning it off removes it, so the
                # file goes back to just the example.
                if (val == "__FALSE__") { if (prev_c) { prev_c = 0; next } out(";" line); next }
                prev_c = 0
                if (done) { out(line); next }
                done = 1
                out(val == "__TRUE__" ? a[1] : a[1] " " val); next
            }
            prev_c = 1
            out(line)
            if (!active && !done && !del && val != "__FALSE__") {
                done = 1
                out(val == "__TRUE__" ? a[1] : a[1] " " val)
            }
            next
        }
        fmt == "quoted_pairs" {
            if (!done && match($0, /^[ \t]*"[^"]*"[ \t]*/)) {
                head = substr($0, 1, RLENGTH); k = head
                sub(/^[ \t]*"/, "", k); sub(/"[ \t]*$/, "", k)
                if (tolower(k) == lkey) { done = 1; if (!del) out(head "\"" val "\""); next }
            }
            out($0); next
        }
        fmt == "braced_pairs" {
            if (!done && match($0, /^[ \t]*\{[^}]*\}[ \t]*=[ \t]*\{/)) {
                head = substr($0, 1, RLENGTH); k = head
                sub(/^[ \t]*\{[ \t]*/, "", k); sub(/[ \t]*\}.*$/, "", k)
                if (tolower(k) == lkey) { done = 1; if (!del) out(head val "}"); next }
            }
            out($0); next
        }
        END {
            if (fmt == "ini_braces") {
                if (insec && !done && !del) { out("\t" key " = " val ";"); out("}"); done = 1 }
                else if (!seen_sec && !done && !del) { if (NR > 0) out(""); out("[" sec "]"); out("{"); out("\t" key " = " val ";"); out("}") }
                flush_blanks()
            } else if (fmt == "ini") {
                if (insec && !done && !del) { out(ini_line()); done = 1 }
                flush_blanks()
                if (!seen_sec && !done && !del) {
                    if (NR > 0) out("")
                    out("[" sec "]"); out(ini_line())
                }
            } else if (!done && !del && val != "__FALSE__") {
                if (fmt == "set_commands") out("seta " key " \"" val "\"")
                else if (fmt == "braced_pairs") out("{" key "} = {" val "}")
                else if (fmt == "quoted_pairs") out("\"" key "\" \"" val "\"")
                else out(val == "__TRUE__" ? key : key " " val)
            }
        }
    ' > "$tmp" || { rm -f "$tmp"; return 1; }
    # A file that ended without a newline still does.
    if [ -s "$file" ] && [ -s "$tmp" ] && [ -n "$(tail -c1 "$file")" ]; then truncate -s -1 "$tmp" || { rm -f "$tmp"; return 1; }; fi
    swap_in "$tmp" "$file"
}

# Usage: config_values_equal <format> <a> <b>
# ini values compare case-insensitively (Unreal reads "True" and "true" the
# same), and so do registry strings, while its dwords compare as numbers
# ("03" is 3); everything else must match exactly.
config_values_equal() {
    # Removing a key and the key not being there are the same state.
    if { [ "$2" == "__ABSENT__" ] && [ "$3" == "__DELETE__" ]; } || { [ "$2" == "__DELETE__" ] && [ "$3" == "__ABSENT__" ]; }; then return 0
    elif { [ "$1" == "registry" ] || [ "$1" == "binary_offset" ] || [ "$1" == "binary_text" ]; } && [[ "$2" =~ ^[0-9]{1,10}$ && "$3" =~ ^[0-9]{1,10}$ ]]; then
        [ "$((10#$2))" -eq "$((10#$3))" ]
    elif [ "$1" == "ini" ] || [ "$1" == "ini_braces" ] || [ "$1" == "registry" ]; then [ "${2,,}" == "${3,,}" ]
    else [ "$2" == "$3" ]; fi
}

# Usage: config_display_value <value>
config_display_value() {
    case "$1" in
        __ABSENT__) echo "(not set)" ;;
        "") echo "(empty)" ;;
        __TRUE__) echo "on" ;;
        __FALSE__) echo "off" ;;
        __DELETE__) echo "(removed)" ;;
        __RAW__) echo "(binary)" ;;
        *) echo "$1" ;;
    esac
}

# Usage: game_install_root
# The game's install root, for "game_root:" locations: the folder the library
# scan matched, else the steamapps/common/<Game> folder GAME_DIR sits in, else
# the Heroic install_path GAME_DIR sits in, else GAME_DIR itself.
game_install_root() {
    if [ -n "${GAME_INSTALL_ROOT:-}" ] && { [ "$GAME_DIR" == "$GAME_INSTALL_ROOT" ] || [[ "$GAME_DIR" == "$GAME_INSTALL_ROOT"/* ]]; }; then
        echo "$GAME_INSTALL_ROOT"; return
    fi
    if [[ "$GAME_DIR" == */steamapps/common/* ]]; then
        local rest="${GAME_DIR#*/steamapps/common/}"
        echo "${GAME_DIR%%/steamapps/common/*}/steamapps/common/${rest%%/*}"; return
    fi
    local json path best=""
    while IFS= read -r json; do
        while IFS= read -r path; do
            [ -n "$path" ] && { [ "$GAME_DIR" == "$path" ] || [[ "$GAME_DIR" == "$path"/* ]]; } && [ ${#path} -gt ${#best} ] && best="$path"
        done < <(jq -r '.. | objects | (.install_path // .installPath // empty)' "$json" 2>/dev/null)
    done < <(heroic_installed_jsons)
    echo "${best:-$GAME_DIR}"
}

# Usage: resolve_config_file <"base:path|base:path…">
# Prints the first location that exists (matching the file name's case
# loosely, like find_existing_variant does for DLLs). Prints nothing if none
# does. With a second argument "create", prints the first location whose
# folder exists instead, for a file that's about to be created. With "all",
# prints every location that exists, one per line, for a game that keeps
# the same file in several places (the file's all_locations).
resolve_config_file() {
    local locations="$1" mode="${2:-}" loc base rel dir candidate found u p seen
    # locs is local: the caller's own list of locations has the same name.
    local -a dirs have=() locs
    IFS='|' read -ra locs <<< "$locations"
    for loc in "${locs[@]}"; do
        base="${loc%%:*}"; rel="${loc#*:}"
        dirs=()
        case "$base" in
            # game / install are the old names for game_exe / game_root.
            game_exe|game) dirs=("$GAME_DIR") ;;
            game_root|install) dirs=("$(game_install_root)") ;;
            prefix_documents|prefix_appdata|prefix_localappdata)
                [ -n "${PREFIX_PATH:-}" ] || continue
                for u in steamuser "$USER"; do
                    case "$base" in
                        prefix_documents) dirs+=("$PREFIX_PATH/drive_c/users/$u/Documents") ;;
                        prefix_appdata) dirs+=("$PREFIX_PATH/drive_c/users/$u/AppData/Roaming") ;;
                        prefix_localappdata) dirs+=("$PREFIX_PATH/drive_c/users/$u/AppData/Local") ;;
                    esac
                done ;;
            # Shared by every user, so one folder (F.E.A.R. keeps its
            # profiles here).
            prefix_public_documents)
                [ -n "${PREFIX_PATH:-}" ] || continue
                dirs=("$PREFIX_PATH/drive_c/users/Public/Documents") ;;
            # The prefix's own registry files (registry), nothing else.
            prefix)
                [ -n "${PREFIX_PATH:-}" ] && [[ "$rel" =~ ^(system|user)\.reg$ ]] || continue
                dirs=("$PREFIX_PATH") ;;
            *) continue ;;
        esac
        for dir in "${dirs[@]}"; do
            candidate="$dir/$rel"
            if [ "$mode" == "create" ]; then
                [ -d "$(dirname "$candidate")" ] && { echo "$candidate"; return; }
            else
                found="$(find_existing_variant "$candidate")"
                [ -n "$found" ] && [ -f "$found" ] || continue
                [ "$mode" == "all" ] || { echo "$found"; return; }
                # steamuser and $USER can be the same folder.
                seen=""
                for p in "${have[@]}"; do [ "$p" -ef "$found" ] && seen=1; done
                [ -n "$seen" ] || { have+=("$found"); echo "$found"; }
            fi
        done
    done
}

# Usage: current_profile
# Sets KG_ID / KG_STORE to the picked game's store id, and returns 1 when
# there's no game profile for it.
current_profile() {
    KG_ID=""; KG_STORE=""
    if [ "$LAUNCHER_TYPE" == "1" ]; then KG_ID="$APPID"; KG_STORE="steam"
    else KG_ID="${HEROIC_APP_NAME:-}"; KG_STORE="gog"; fi
    [ -n "$KG_ID" ] && ensure_game_database || return 1
    jq -e --arg id "$KG_ID" --arg store "$KG_STORE" \
        'any(.games[]; (.stores[$store].id // "") | tostring == $id)' "$GAME_DATABASE_FILE" >/dev/null 2>&1
}

# Usage: count_game_settings <id> <steam|gog>
# Prints "<audio> <optional>": settings this store's build can be offered (only_if
# stores match). Used by the GAME PROFILE block's fix counts before the game folder is known.
count_game_settings() {
    gdb_jq "$1" "$2" '
        entry0 | .game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))] | length;
          "\(.audio_settings | offered) \(.optional_settings | offered)"'
}

# Usage: game_setting_titles <id> <steam|gog>
# One "audio|optional<TAB>title<TAB>flag" line per setting count_game_settings
# counts, audio settings first, for the game profile screen; flag is "1" for a
# setting unverified. Then one "openal<TAB>key =
# value<TAB>flag" line per alsoft.ini value, flagged when install.alsoft_tested
# is false.
game_setting_titles() {
    gdb_jq "$1" "$2" '
        entry0 | . as $e | .game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))];
          def flag: if .tested != true then "1" else "" end;
          (.audio_settings | offered | .[] | "audio\t\(.title)\t\(flag)"),
          (.optional_settings | offered | .[] | "optional\t\(.title)\t\(flag)"),
          ($e.install.alsoft_ini // {} | to_entries[] | .key as $sec | .value | to_entries[]
           | "openal\t\($sec) \(.key) = \(.value)\t\(if $e.install.alsoft_tested != true then "1" else "" end)")'
}

# Usage: game_setting_follow_ups <id> <steam|gog>
# "<title>\t<follow_up>" for every audio and optional setting offered on
# that store that has a follow_up, in database order; a line break in it
# comes out as \x1e (see wrap_text).
game_setting_follow_ups() {
    gdb_jq "$1" "$2" '
        entry0 | .game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))];
          (.audio_settings | offered | .[]), (.optional_settings | offered | .[])
        | select((.follow_up // "") != "")
        | "\(.title)\t\(.follow_up | gsub("\n"; "\u001e"))"'
}

# Usage: speakers_match <comma list>
# True when the Speaker Configuration answer is one of the listed values:
# stereo / matrix / surround (any layout) match OUTPUT_MODE, headphones
# matches the Stereo → Headphones answer (not Auto), and an exact layout
# (quad, surround51, ...) matches SURROUND_CHANNELS. A non-empty
# <has_headphones> (the entry has its own headphones setting) keeps stereo
# from also matching Headphones: both usually set the same key.
speakers_match() {
    local v
    local -a wanted
    IFS=',' read -ra wanted <<< "$1"
    for v in "${wanted[@]}"; do
        if [ "$v" == "stereo" ] && [ -n "${2:-}" ] && [ "${STEREO_MODE:-}" == "headphones" ]; then continue; fi
        [ "$v" == "$OUTPUT_MODE" ] && return 0
        [ "$v" == "headphones" ] && [ "$OUTPUT_MODE" == "stereo" ] && [ "${STEREO_MODE:-}" == "headphones" ] && return 0
        [ "$OUTPUT_MODE" == "surround" ] && [ "$v" == "${SURROUND_CHANNELS:-}" ] && return 0
    done
    return 1
}

# Usage: load_game_config_rows <id> <steam|gog> [all]
# Flattens the entry's fixes into one \x1f-separated row per changed key:
# category, fix number, title, reason, only_if stores (comma list),
# only_if speakers (comma list), follow_up, file, format, if_missing, locations
# (|-joined), section ("" for cfg formats), key, value (with the markers
# above), "1" for a setting not marked "tested": true, then "1" when the file's
# all_locations is set. A line break in the reason or follow_up comes out as
# \x1e (see wrap_text), so each row stays one line. Untested ones are left out unless
# EAX_RESTORE_UNTESTED_SETTINGS is set, or the caller passes "all" (the
# database browser, which shows everything). \x1f rather than tabs so empty
# fields survive `read`.
load_game_config_rows() {
    local with_untested=false
    { is_truthy "${EAX_RESTORE_UNTESTED_SETTINGS:-}" || [ "${3:-}" == "all" ]; } && with_untested=true
    gdb_jq "$1" "$2" '
        def br: gsub("\n"; "\u001e");
        def enc: if type == "boolean" then (if . then "__TRUE__" else "__FALSE__" end)
                 elif . == null then "__DELETE__" else tostring end;
        entry0 | .game_config // empty
        | (.files // {}) as $files
        | ((.audio_settings // []) | to_entries[] | {cat: "audio", i: .key, f: .value}),
          ((.optional_settings // []) | to_entries[] | {cat: "optional", i: .key, f: .value})
        | select('"$with_untested"' or .f.tested == true)
        | .cat as $cat | .i as $i | .f as $f
        | $f.changes | to_entries[] | .key as $file | ($files[$file] // {}) as $def
        | (if $def.format == "ini" or $def.format == "ini_braces" or $def.format == "registry"
             then (.value | to_entries[]
                   | if (.value | type) == "object"
                     then .key as $sec | .value | to_entries[] | [$sec, .key, .value]
                     else ["", .key, .value] end)
             else (.value | to_entries[] | ["", .key, .value]) end) as $kv
        | [$cat, ($i | tostring), $f.title, ($f.reason | br), (($f.only_if.stores // []) | join(",")),
           ([$f.only_if.speakers // empty] | flatten | join(",")), ($f.follow_up // "" | br), $file, ($def.format // ""),
           ($def.if_missing // ""), (($def.locations // []) | join("|")), $kv[0], $kv[1], ($kv[2] | enc),
           (if $f.tested != true then "1" else "" end),
           (if $def.all_locations then "1" else "" end)]
        | join("\u001f")'
}

# Usage: config_row_is_safe <format> <locations> <section> <key> <value>
# The schema already enforces all this in CI; this re-checks only what could
# touch the wrong file or corrupt one, in case a bad entry slips through.
# registry is the only format for the prefix's registry files, and only
# them; its section is a registry key path, backslash-separated.
config_row_is_safe() {
    local fmt="$1" locations="$2" sec="$3" key="$4" value="$5" loc
    local -a locs
    local name_re='^[A-Za-z0-9._ -]+$' value_re='^[A-Za-z0-9._ ()-]*$'
    local reg_key_re='^[A-Za-z0-9._ ()-]+(\\[A-Za-z0-9._ ()-]+)*$'
    [[ "$fmt" =~ $CONFIG_FORMATS_RE ]] || return 1
    [ -n "$locations" ] || return 1
    IFS='|' read -ra locs <<< "$locations"
    for loc in "${locs[@]}"; do
        if [ "$fmt" == "registry" ]; then
            [[ "$loc" =~ ^prefix:(system|user)\.reg$ ]] || return 1
            continue
        fi
        [[ "$loc" =~ ^(game_exe|game_root|game|install|prefix_documents|prefix_appdata|prefix_localappdata|prefix_public_documents):[^/\\] ]] || return 1
        [[ "$loc" == *..* || "$loc" == *\\* ]] && return 1
    done
    if [ "$fmt" == "binary_text" ]; then [[ "${key/+/}" =~ $name_re ]] || return 1; else [[ "$key" =~ $name_re ]] || return 1; fi
    # An ini file's own top, before its first [header], has no section name.
    if [ "$fmt" == "ini" ]; then [ -z "$sec" ] || [[ "$sec" =~ $name_re ]] || return 1; fi
    if [ "$fmt" == "ini_braces" ]; then [[ "$sec" =~ $name_re ]] || return 1; fi
    if [ "$fmt" == "registry" ]; then [[ "$sec" =~ $reg_key_re ]] && [[ "$sec" != *..* ]] || return 1; fi
    if [ "$fmt" == "binary_offset" ]; then
        _byte_offset "$key" >/dev/null && [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 255 ] || return 1
    fi
    # A binary_text key is the hex bytes in front of the text, plus +N for a byte
    # N past its end, which takes a number 0-255.
    if [ "$fmt" == "binary_text" ]; then
        if [[ "$key" == *+* ]]; then
            [[ "$key" =~ ^([0-9A-Fa-f]{2}){1,16}\+[0-9]{1,5}$ ]] && [[ "$value" =~ ^[0-9]{1,3}$ ]] && [ "$((10#$value))" -le 255 ] || return 1
        else
            [[ "$key" =~ ^([0-9A-Fa-f]{2}){1,16}$ ]] && [ -n "$value" ] && [ "${#value}" -le 64 ] || return 1
        fi
    fi
    # A binary_switches setting can only be switched on or off in place.
    if [ "$fmt" == "binary_switches" ]; then [[ "$value" =~ ^[01]$ ]] || return 1; fi
    case "$value" in
        __TRUE__|__FALSE__) [ "$fmt" == "key_value" ] || return 1 ;;
        __DELETE__) ;;
        *) [[ "$value" =~ $value_re ]] || return 1 ;;
    esac
}

# Usage: print_config_rows <rows>
# Prints a fix's changes as a tree: the file on its own line, its [section]
# under it (ini, ini_braces and registry), then one "key  old → new" line per change, with the
# keys lined up. A file or section line is only printed when it differs from
# the row above. <rows> is newline-separated \x1f rows of
# file, section, key, old, new. An old value of __ANY__ prints just
# "key  → new", for the database browser, which has no install to read the
# current value from, and one of __SET__ prints "key  value ✓ already set",
# for a key that already has its new value.
print_config_rows() {
    local r prev_file="" prev_sec="" file sec key old new indent
    local -a g
    local key_len=0
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        mapfile -t -d $'\x1f' g < <(printf '%s' "$r")
        [ ${#g[2]} -gt $key_len ] && key_len=${#g[2]}
    done <<< "$1"
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        mapfile -t -d $'\x1f' g < <(printf '%s' "$r")
        file="${g[0]}"; sec="${g[1]}"; key="${g[2]}"; old="${g[3]}"; new="${g[4]}"
        if [ "$file" != "$prev_file" ]; then
            echo -e "    ${DIM}${file}${NC}"
            prev_sec=""
        fi
        if [ -n "$sec" ]; then
            [ "$sec" != "$prev_sec" ] && echo -e "      ${DIM}[${sec}]${NC}"
            indent="        "
        else
            indent="      "
        fi
        if [ "$old" == "__SET__" ]; then
            printf "%s%-${key_len}s  ${DIM}%s${NC} ${GREEN}✓${NC} ${DIM}already set${NC}\n" "$indent" "$key" "$(config_display_value "$new")"
        elif [ "$old" == "__ANY__" ]; then
            printf "%s%-${key_len}s  → ${GREEN}%s${NC}\n" "$indent" "$key" "$(config_display_value "$new")"
        else
            printf "%s%-${key_len}s  %s → ${GREEN}%s${NC}\n" "$indent" "$key" "$(config_display_value "$old")" "$(config_display_value "$new")"
        fi
        prev_file="$file"; prev_sec="$sec"
    done <<< "$1"
}

# Usage: print_alsoft_details <name> <store key> <store id>
# The Tab view's OpenAL section: the game's alsoft.ini values, each with a
# short explanation, and whether they are verified.
print_alsoft_details() {
    local line sec key value
    local -a lines
    mapfile -t lines < <(gdb_jq "$3" "$2" 'entry0 | .install.alsoft_ini // {}
        | to_entries[] | .key as $sec | .value | to_entries[] | [$sec, .key, (.value | tostring)] | join("\u001f")')
    [ ${#lines[@]} -gt 0 ] && [ -n "${lines[0]}" ] || return 0
    local flag
    flag="$(gdb_jq "$3" "$2" 'entry0 | if .install.alsoft_tested != true then "1" else "" end')"
    echo -e "\n${WHITE}OpenAL settings for ${1}:${NC}"
    for line in "${lines[@]}"; do
        IFS=$'\x1f' read -r sec key value <<< "$line"
        echo -e "\n  ${BOLD}${key} = ${value}${NC} $(verified_tag "$flag")"
        case "$sec/$key" in
            reverb/boost) echo "    Makes all reverb louder by this many decibels." ;;
            general/sources) echo "    How many sounds the game can play at once." ;;
            general/frequency) echo "    The sample rate the sound is mixed at, in Hz." ;;
            general/default-reverb) echo "    The reverb preset used where the game doesn't choose one." ;;
            general/resampler) echo "    How sounds at another sample rate are converted." ;;
        esac
        echo -e "    ${DIM}In alsoft.ini, section [${sec}]${NC}"
    done
    [ -n "$flag" ] && echo -e "    ${DIM}Unverified.${NC}"
}

# Usage: print_game_settings_details <game id>
# The database browser's Game settings view: every audio and optional
# setting in the game's entry, each with its reason, the file (and where it
# lives), the keys and the values it sets, and when it applies. Laid out
# like the install's Game Settings step, minus the current values, which
# only an install has. Settings belong to the game, not a store, so this is
# one view for both; a store-only one says so.
print_game_settings_details() {
    local name store_key store_id
    IFS=$'\t' read -r name store_key store_id < <(jq -r --arg game "$1" '
        .games[] | select(.id == $game) | [.name, (.stores | to_entries[0] | .key, (.value.id | tostring))] | join("\t")' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
    local -a rows f
    local row
    while IFS= read -r row; do [ -n "$row" ] && rows+=("$row"); done \
        < <([ -n "$store_id" ] && load_game_config_rows "$store_id" "$store_key" all)
    if [ ${#rows[@]} -eq 0 ]; then
        echo ""
        print_wrapped "${name:-This game} has no game settings in the database."
        [ -n "$store_id" ] && print_alsoft_details "$name" "$store_key" "$store_id" && echo ""
        return
    fi

    local -A location_label=([game]="game folder" [install]="install folder" [prefix_documents]="Documents"
        [prefix_appdata]="AppData" [prefix_public_documents]="Public Documents")
    local -A speaker_name=([stereo]="Stereo" [headphones]="Headphones" [matrix]="Matrix encoding"
        [surround]="Surround (any layout)" [quad]="Quad (4.0)" [surround51]="Surround 5.1"
        [surround61]="Surround 6.1" [surround71]="Surround 7.1")
    local width=$(( ${WRAP_COLUMNS:-76} - 2 ))
    local id prev_id="" prev_cat="" display_rows="" stores speakers follow untested file_label loc s joiner
    local -a locs labels
    # One setting's rows are printed together, after its last row is read.
    _flush_setting() {
        [ -n "$prev_id" ] || return 0
        print_config_rows "$display_rows"
        [ -n "$untested" ] && echo -e "    ${DIM}Unverified.${NC}"
        if [ -n "$stores" ]; then
            labels=()
            for s in ${stores//,/ }; do [ "$s" == "gog" ] && labels+=("GOG") || labels+=("Steam"); done
            echo -e "    ${DIM}Only on ${labels[*]}${NC}"
        fi
        if [ -n "$speakers" ]; then
            labels=()
            for s in ${speakers//,/ }; do labels+=("${speaker_name[$s]:-$s}"); done
            echo -e "    ${DIM}Only with $(IFS='|'; s="${labels[*]}"; echo "${s//|/ or }")${NC}"
        fi
        if [ -n "$follow" ]; then
            echo -e "    ${DIM}Afterwards:${NC}"
            wrap_text "$width" "    " "$follow"
        fi
    }
    for row in "${rows[@]}"; do
        mapfile -t -d $'\x1f' f < <(printf '%s' "$row")
        id="${f[0]}:${f[1]}"
        if [ "$id" != "$prev_id" ]; then
            _flush_setting
            if [ "${f[0]}" != "$prev_cat" ]; then
                [ "${f[0]}" == "audio" ] && echo -e "\n${WHITE}Audio settings for ${name}:${NC}" \
                    || echo -e "\n${WHITE}Optional settings for ${name}:${NC}"
                prev_cat="${f[0]}"
            fi
            echo -e "\n  ${BOLD}${f[2]}${NC} $(verified_tag "${f[14]:-}")"
            wrap_text "$width" "    " "${f[3]}"
            echo ""
            display_rows="" stores="${f[4]}" speakers="${f[5]}" follow="${f[6]}" untested="${f[14]:-}"
            prev_id="$id"
        fi
        # The file as the rows group it, then where the game keeps it.
        IFS='|' read -ra locs <<< "${f[10]}"
        labels=()
        for loc in "${locs[@]}"; do
            s="${location_label[${loc%%:*}]:-${loc%%:*}}"
            [ "${loc#*:}" == "${f[7]}" ] || s+=": ${loc#*:}"
            labels+=("$s")
        done
        joiner=" or "; [ -n "${f[15]:-}" ] && joiner=" and "
        file_label="${f[7]}  ($(IFS='|'; s="${labels[*]}"; echo "${s//|/$joiner}"))"
        display_rows+="${file_label}"$'\x1f'"${f[11]}"$'\x1f'"${f[12]}"$'\x1f'"__ANY__"$'\x1f'"${f[13]}"$'\n'
    done
    _flush_setting
    unset -f _flush_setting
    print_alsoft_details "$name" "$store_key" "$store_id"
    echo ""
}

# Usage: _speaker_radio <result var> <question> <record label> <start on> <fallback> <value> <title> <detail> [<value> <title> <detail> ...]
# One speaker question as a radio_select: the dot starts on the item whose value
# is <start on> (or <fallback> when that matches none), and the picked item's
# value goes into <result var>.
_speaker_radio() {
    local -n _result="$1"
    local question="$2" label="$3" start="$4" fallback="$5"
    shift 5
    local -a values=() titles=()
    RADIO_DETAILS=()
    while [ $# -ge 3 ]; do values+=("$1"); titles+=("$2"); RADIO_DETAILS+=("$3"); shift 3; done
    local i
    RADIO_INITIAL=1
    for i in "${!values[@]}"; do
        [ "${values[$i]}" == "$fallback" ] && RADIO_INITIAL=$((i + 1))
    done
    for i in "${!values[@]}"; do
        [ -n "$start" ] && [ "${values[$i]}" == "$start" ] && RADIO_INITIAL=$((i + 1))
    done
    print_result "$question"
    radio_select "$label" "${titles[@]}"
    _result="${values[$((RADIO_CHOICE - 1))]}"
}

# Usage: ask_speaker_configuration
# Step 8's speaker questions, shared with Tools → Speaker configuration. Sets
# OUTPUT_MODE (stereo / surround / matrix), STEREO_MODE (stereo only),
# ENABLE_HRTF (the y/n answer) and SURROUND_CHANNELS (surround only). When
# Tools has already read the current setup into those (speaker_config_from_alsoft),
# each question starts on it, so Enter all the way through changes nothing.
ask_speaker_configuration() {
    local prev_mode="${OUTPUT_MODE:-}" prev_stereo="${STEREO_MODE:-}"
    local prev_hrtf="${ENABLE_HRTF:-}" prev_channels="${SURROUND_CHANNELS:-}"

    _speaker_radio OUTPUT_MODE "What kind of audio output are you using?" "Audio output" "$prev_mode" stereo \
        stereo "Stereo" "Headphones, or two speakers." \
        surround "Surround sound" "Four to eight speakers, such as 5.1 or 7.1." \
        matrix "Matrix encoding" "Stereo that a receiver or soundbar decodes into surround."

    ENABLE_HRTF=""
    SURROUND_CHANNELS=""

    if [ "$OUTPUT_MODE" == "stereo" ]; then
        # Starts on the saved choice only when the saved output was stereo.
        local start_stereo=""
        [ "$prev_mode" == "stereo" ] && start_stereo="$prev_stereo"
        _speaker_radio STEREO_MODE "What are you listening on?" "Listening on" "$start_stereo" auto \
            auto "Auto" "Leaves it to the sound engine to work out whether it's speakers or headphones." \
            speakers "Speakers" "Two speakers in front of you." \
            headphones "Headphones" "Headphones or earbuds."

        if [ "$STEREO_MODE" == "speakers" ]; then
            # HRTF is a headphone-only binaural technique — meaningless (and
            # actively harmful to positional accuracy) over real speakers.
            ENABLE_HRTF="n"
        else
            echo ""
            echo -e "${CYAN}Headphones Configuration (HRTF)${NC}\n"
            echo -e "${WHITE}Head-Related Transfer Function (HRTF) translates 3D positional audio into a binaural"
            echo -e "format specifically designed for standard stereo headphones. Turning this on will"
            echo -e "allow you to hear exactly whether a sound is coming from above, below, or behind you.${NC}"
            # On by default; only a stereo setup that already has it off
            # (Tools) keeps No as the default, so Enter doesn't switch it on.
            local hrtf_default="Y"
            [ "$prev_mode" == "stereo" ] && ! [[ "$prev_hrtf" =~ $YES_RE ]] && hrtf_default="N"
            if confirm "Do you want to enable HRTF for headphones?" "$hrtf_default"; then
                ENABLE_HRTF="y"
            else
                ENABLE_HRTF="n"
            fi
        fi
    elif [ "$OUTPUT_MODE" == "surround" ]; then
        # Same names as speaker_label, so the recap matches the pick.
        _speaker_radio SURROUND_CHANNELS "Which speaker layout do you have?" "Speaker layout" "$prev_channels" surround51 \
            quad "Quad (4.0)" "Front left and right, rear left and right." \
            surround51 "Surround 5.1" "Front left, centre and right, two surrounds and a subwoofer." \
            surround61 "Surround 6.1" "5.1 plus a rear centre speaker." \
            surround71 "Surround 7.1" "5.1 plus rear left and right speakers."
    fi
}

# Usage: speaker_alsoft_values
# The alsoft.ini values for the speaker answers (see ask_speaker_configuration):
# sets ALSOFT_CHANNELS, STEREO_MODE (auto for surround and matrix),
# STEREO_ENCODING, HRTF_MODE and HRTF_MODE_PREFIX ("# " comments hrtf-mode out
# when HRTF is off). Used by the install's alsoft.ini and by Tools → Speaker
# configuration.
speaker_alsoft_values() {
    if [ "$OUTPUT_MODE" == "surround" ]; then
        # Surround speaker setups bypass HRTF (headphone-only binaural
        # processing) and stereo-only encodings entirely.
        ALSOFT_CHANNELS="$SURROUND_CHANNELS"
        STEREO_MODE="auto"
        STEREO_ENCODING="basic"
        HRTF_MODE=""
    elif [ "$OUTPUT_MODE" == "matrix" ]; then
        # Matrix-encoded stereo output also bypasses HRTF — the
        # matrix decoder (tsme) needs an unprocessed stereo signal.
        ALSOFT_CHANNELS="stereo"
        STEREO_MODE="auto"
        STEREO_ENCODING="tsme"
        HRTF_MODE=""
    elif [[ "$ENABLE_HRTF" =~ $YES_RE ]]; then
        ALSOFT_CHANNELS="stereo"
        STEREO_ENCODING="hrtf"
        HRTF_MODE="full"
    else
        ALSOFT_CHANNELS="stereo"
        STEREO_ENCODING="basic"
        HRTF_MODE=""
    fi

    if [ -n "$HRTF_MODE" ]; then
        HRTF_MODE_PREFIX=""
    else
        HRTF_MODE_PREFIX="# "
        HRTF_MODE="full"
    fi
}

# Usage: speaker_label
# The speaker answers in a few words ("Headphones, HRTF on", "Surround 5.1"),
# for the install's choices recap and Tools → Speaker configuration.
speaker_label() {
    local speakers
    case "$OUTPUT_MODE" in
        stereo)
            case "$STEREO_MODE" in
                speakers) speakers="Stereo speakers" ;;
                headphones) speakers="Headphones" ;;
                *) speakers="Stereo (OpenAL Soft decides)" ;;
            esac
            [[ "$ENABLE_HRTF" =~ $YES_RE ]] && speakers+=", HRTF on"
            ;;
        surround)
            case "$SURROUND_CHANNELS" in
                quad) speakers="Quad (4.0)" ;;
                surround51) speakers="Surround 5.1" ;;
                surround61) speakers="Surround 6.1" ;;
                *) speakers="Surround 7.1" ;;
            esac
            ;;
        *) speakers="Matrix encoding" ;;
    esac
    printf '%s' "$speakers"
}

# Usage: speaker_config_from_alsoft <alsoft.ini>
# The reverse of speaker_alsoft_values: reads a generated alsoft.ini's
# channels, stereo-mode and stereo-encoding back into OUTPUT_MODE,
# STEREO_MODE, ENABLE_HRTF and SURROUND_CHANNELS. Returns 1 when the file
# doesn't say (no channels line).
speaker_config_from_alsoft() {
    local file="$1" channels encoding
    channels="$(config_get_key "$file" ini general channels)"
    [ "$channels" == "__ABSENT__" ] && return 1
    encoding="$(config_get_key "$file" ini general stereo-encoding)"
    STEREO_MODE="$(config_get_key "$file" ini general stereo-mode)"
    [ "$STEREO_MODE" == "__ABSENT__" ] && STEREO_MODE="auto"
    ENABLE_HRTF="n"; SURROUND_CHANNELS=""
    case "$channels" in
        quad|surround51|surround61|surround71) OUTPUT_MODE="surround"; SURROUND_CHANNELS="$channels" ;;
        *)
            if [ "$encoding" == "tsme" ]; then OUTPUT_MODE="matrix"
            else
                OUTPUT_MODE="stereo"
                [ "$encoding" == "hrtf" ] && ENABLE_HRTF="y"
            fi
            ;;
    esac
    return 0
}

# Usage: offer_alsoft_settings [heading command...]
# Game Audio Settings' first question: the game profile's
# install.alsoft_ini values, each stated as a fact about the game plus a
# default-yes offer. The heading command (the step's header) runs once,
# right before the first question, so a game with none gets no header.
# Accepted ones land in ALSOFT_OVERRIDES ("section\x1fkey\x1fvalue") for
# Phase 4 to write into the generated alsoft.ini.
offer_alsoft_settings() {
    ALSOFT_OVERRIDES=()
    current_profile || return
    local sec key value asked="" entry tag
    # Unverified values are held back like
    # untested game settings.
    if ! is_truthy "${EAX_RESTORE_UNTESTED_SETTINGS:-}" \
        && [ "$(gdb_jq "$KG_ID" "$KG_STORE" 'entry0 | (.install.alsoft_tested == true)')" == "false" ]; then
        return
    fi
    tag="$(verified_tag "$(gdb_jq "$KG_ID" "$KG_STORE" 'entry0 | if .install.alsoft_tested != true then "1" else "" end')")"
    # Read first, then ask: a confirm inside a loop fed by the query would
    # read its answer from the query's output, not from the player.
    local -a entries=()
    mapfile -t entries < <(gdb_jq "$KG_ID" "$KG_STORE" '
        entry0 | .install.alsoft_ini // {}
        | to_entries[] | .key as $sec | .value | to_entries[] | [$sec, .key, (.value | tostring)] | join("\u001f")')
    for entry in "${entries[@]}"; do
        IFS=$'\x1f' read -r sec key value <<< "$entry"
        [ -n "$key" ] || continue
        # The same check every other database-driven write gets.
        config_row_is_safe ini "game:alsoft.ini" "$sec" "$key" "$value" || continue
        if [ -z "$asked" ] && [ $# -gt 0 ]; then "$@"; fi
        asked=1
        if [ "$sec/$key" == "reverb/boost" ]; then
            echo ""
            echo -e "${WHITE}${GAME_NAME}'s reverb is quiet at the default level.${NC}"
            confirm "Raise the reverb boost to +${value} dB? ${tag}" Y || continue
        elif [ "$sec/$key" == "general/sources" ]; then
            confirm "Let ${GAME_NAME} play up to ${value} sounds at once, set in alsoft.ini? ${tag}" Y || continue
        else
            confirm "Set ${key} to ${value} in alsoft.ini for ${GAME_NAME}? ${tag}" Y || continue
        fi
        ALSOFT_OVERRIDES+=("$sec"$'\x1f'"$key"$'\x1f'"$value")
    done
}

# Usage: apply_alsoft_overrides
# Writes the accepted ALSOFT_OVERRIDES into the freshly generated alsoft.ini.
apply_alsoft_overrides() {
    local entry sec key value
    for entry in "${ALSOFT_OVERRIDES[@]}"; do
        IFS=$'\x1f' read -r sec key value <<< "$entry"
        if config_set_key "$GAME_DIR/alsoft.ini" ini "$sec" "$key" "$value"; then
            print_status "Set $key = $value in alsoft.ini"
        else
            record_deploy_failure "$GAME_DIR/alsoft.ini"
        fi
    done
}

# The steps of game_settings_step below. They share its locals (the fix_*
# tables, the heading flags, the lists) through bash's dynamic scope, so
# they only run from it.

# Prints a step's heading the first time something needs it (usage:
# _gs_heading audio|optional); a part with nothing to show gets none.
_gs_heading() {
    if [ "$1" == "audio" ]; then
        [ "$audio_heading_shown" -eq 1 ] && return
        print_step "$step" "Game Audio Settings"
        if [ -n "${GAME_SETTINGS_SPEAKERS_ONLY:-}" ]; then
            print_paragraph "This step changes ${GAME_NAME:-the game}'s own settings to match your speakers."
        else
            print_paragraph "This step sets up ${GAME_NAME:-the game}'s own sound options for EAX."
        fi
        audio_heading_shown=1
    else
        [ "$optional_heading_shown" -eq 1 ] && return
        if [ -n "${GAME_SETTINGS_EDIT:-}" ]; then
            print_step "$step" "Game Settings"
            print_paragraph "This step turns ${GAME_NAME:-the game}'s own settings on or off."
        else
            print_step "$((step + 1))" "Optional Game Settings"
            print_paragraph "This step offers changes to ${GAME_NAME:-the game} that aren't needed for EAX."
        fi
        optional_heading_shown=1
    fi
    GAME_SETTINGS_STEP_SHOWN=1
}

# "(tested)" or "(untested)" after a setting's title; untested ones only
# show when EAX_RESTORE_UNTESTED_SETTINGS lets them through.
_gs_untested_suffix() { printf ' %s' "$(verified_tag "${fix_untested[$1]:-}")"; return 0; }
# Prints one fix: title, reason, and each row's current → new value.
_gs_print_fix() {
    echo -e "\n  ${BOLD}${fix_title[$1]}${NC}$(_gs_untested_suffix "$1")"
    _gs_fix_body "$1"
}
# A fix's reason and rows, under its title (or its box in a tick list).
_gs_fix_body() {
    local id="$1"
    wrap_text 74 "    " "${fix_reason[$id]}"
    echo ""
    print_config_rows "${fix_view[$id]}"
    _gs_print_absent_note "$id"
}
# Tools → Game settings: the body of one this script applied, with
# each key's original value (from the manifest) → the value it has now.
_gs_applied_fix_body() {
    local id="$1" line display_rows=""
    local -a c
    wrap_text 74 "    " "${fix_reason[$id]}"
    echo ""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        parse_config_line "$line" c
        display_rows+="$(tilde_path "${c[2]}")"$'\x1f'"${c[4]}"$'\x1f'"${c[5]}"$'\x1f'"${c[6]}"$'\x1f'"${c[7]}"$'\n'
    done <<< "${GAME_SETTINGS_RECORDED[${fix_title[$id]}]}"
    print_config_rows "$display_rows"
}
# A setting that still applies, minus the part for a file this build
# doesn't have.
_gs_print_absent_note() {
    local id="$1"
    [ -n "${fix_absent_files[$id]:-}" ] || return 0
    echo -e "${DIM}    ${GAME_NAME} has no ${fix_absent_files[$id]//|/ or }, so that part is left out.${NC}"
}
# Remembers settings the player turned down, for the final summary.
_gs_decline_fix() {
    GAME_SETTINGS_DECLINED+=("${fix_title[$1]}"$'\x1f'"${fix_files[$1]//|/ and }")
}
_gs_plan_fix() {
    local id="$1" r
    while IFS= read -r r; do [ -n "$r" ] && GAME_SETTINGS_PLAN+=("$r"); done <<< "${fix_rows[$id]}"
    [ -n "${fix_follow[$id]}" ] && GAME_SETTINGS_FOLLOW_UPS+=("${fix_title[$id]}"$'\x1f'"${fix_follow[$id]}")
}
_gs_print_status_line() {
    local id="$1"
    if [ "${fix_status[$id]}" == "already" ]; then
        echo -e "\n  ${GREEN}✓${NC} ${fix_title[$id]} ${DIM}— already set${NC}"
        _gs_print_absent_note "$id"
    elif [ "${fix_status[$id]}" == "absent" ]; then
        echo -e "\n  ${YELLOW}-${NC} ${fix_title[$id]} ${DIM}— left out: ${GAME_NAME} has no ${fix_absent_files[$id]//|/ or }${NC}"
        GAME_SETTINGS_ABSENT+=("${fix_title[$id]}"$'\x1f'"${fix_absent_files[$id]//|/ or }")
    else
        echo -e "\n  ${YELLOW}-${NC} ${fix_title[$id]} ${DIM}— skipped: ${GAME_NAME} hasn't created ${fix_missing_file[$id]} yet${NC}"
        GAME_SETTINGS_MISSING+=("${fix_title[$id]}"$'\x1f'"${fix_missing_file[$id]}")
    fi
}

# Reads every setting's config files and sorts each fix into fix_status:
# offer, already, applied, missing, absent, skip or invalid. Fills fix_rows
# and fix_view for the ones with something to change.
_gs_build_plan() {
    local cat idx title reason stores speakers follow file fmt ifmissing locs sec key value id path old all_locs
    local -a paths
    local -a f
    for row in "${rows[@]}"; do
        mapfile -t -d $'\x1f' f < <(printf '%s' "$row")
        cat="${f[0]}"; idx="${f[1]}"; title="${f[2]}"; reason="${f[3]}"; stores="${f[4]}"; speakers="${f[5]}"
        follow="${f[6]}"; file="${f[7]}"; fmt="${f[8]}"; ifmissing="${f[9]}"; locs="${f[10]}"
        sec="${f[11]}"; key="${f[12]}"; value="${f[13]}"; all_locs="${f[15]:-}"
        id="$cat:$idx"
        [ -n "${f[14]:-}" ] && fix_untested[$id]=1

        if [ -z "${fix_status[$id]+x}" ]; then
            fix_order+=("$id"); fix_title[$id]="$title"; fix_reason[$id]="$reason"; fix_follow[$id]="$follow"
            fix_status[$id]="already"; fix_rows[$id]=""
            if [ -n "$stores" ] && [[ ",$stores," != *",$KG_STORE,"* ]]; then fix_status[$id]="skip"; fi
            if [ -n "$speakers" ] && ! speakers_match "$speakers" "$has_headphones"; then fix_status[$id]="skip"; fi
            [ -n "${GAME_SETTINGS_SPEAKERS_ONLY:-}" ] && [ -z "$speakers" ] && fix_status[$id]="skip"
        fi
        [[ "${fix_status[$id]}" =~ ^(skip|invalid)$ ]] && continue
        [ "$cat" == "audio" ] && audio_seen=1

        if ! config_row_is_safe "$fmt" "$locs" "$sec" "$key" "$value"; then
            log_cmd "game settings: skipped \"$title\" — its entry for $file/$sec/$key failed the safety check"
            fix_status[$id]="invalid"; continue
        fi

        # Find the file once per run.
        if [ -z "${file_state[$file]+x}" ]; then
            path="$(resolve_config_file "$locs" ${all_locs:+all})"
            if [ -n "$path" ]; then file_state[$file]="found"
            elif [ "$ifmissing" == "create" ]; then
                path="$(resolve_config_file "$locs" create)"
                file_state[$file]="$( [ -n "$path" ] && echo create || echo missing )"
            elif [ "$ifmissing" == "skip" ]; then file_state[$file]="skip"
            else
                # The game writes it on first launch. Like the prefix step's
                # "not found yet" check: explain, let the player launch the
                # game, and look again; No carries on without this file's fixes.
                while [ -z "$path" ]; do
                    # Under the first step to show, so the steps stay in
                    # order: the optional heading only comes after the
                    # audio list.
                    if [ "$audio_seen" -eq 1 ]; then _gs_heading audio
                    else _gs_heading optional; fi
                    print_note "${GAME_NAME} hasn't created ${file} yet."
                    print_paragraph "If you just installed ${GAME_NAME}, it creates ${file} the first time it runs." \
                        "Please launch the game at least once, close it, and try again."
                    confirm "Check for ${file} again?" || break
                    path="$(resolve_config_file "$locs" ${all_locs:+all})"
                done
                file_state[$file]="$( [ -n "$path" ] && echo found || echo missing )"
            fi
            file_path[$file]="$path"
        fi
        case "${file_state[$file]}" in
            skip)
                [[ "|${fix_absent_files[$id]:-}|" == *"|$file|"* ]] \
                    || fix_absent_files[$id]+="${fix_absent_files[$id]:+|}$file"
                continue ;;
            missing) fix_status[$id]="missing"; fix_missing_file[$id]="$file"; continue ;;
        esac
        [ "${fix_status[$id]}" == "missing" ] && continue
        fix_has_file[$id]=1

        # One copy, or every copy found when the file's all_locations is set.
        mapfile -t paths <<< "${file_path[$file]}"
        for path in "${paths[@]}"; do
            old="$(config_get_key "$path" "$fmt" "$sec" "$key")"
            if [ "$value" == "__FALSE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
            if [ "$value" == "__DELETE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
            # A key that already has its value still shows (ticked) under a setting
            # that has other keys to change, so the player sees what's done.
            if config_values_equal "$fmt" "$old" "$value"; then
                fix_view[$id]+="$(tilde_path "$path")"$'\x1f'"$sec"$'\x1f'"$key"$'\x1f'"__SET__"$'\x1f'"$value"$'\n'
                continue
            fi
            fix_status[$id]="offer"
            fix_view[$id]+="$(tilde_path "$path")"$'\x1f'"$sec"$'\x1f'"$key"$'\x1f'"$old"$'\x1f'"$value"$'\n'
            [[ "|${fix_files[$id]:-}|" == *"|$file|"* ]] || fix_files[$id]+="${fix_files[$id]:+|}$file"
            fix_rows[$id]+="$cat"$'\x1f'"$title"$'\x1f'"$path"$'\x1f'"$fmt"$'\x1f'"$sec"$'\x1f'"$key"$'\x1f'"$value"$'\x1f'"$file"$'\x1f'"$old"$'\x1f'"${file_state[$file]}"$'\n'
        done
    done

    # Every file this setting changes is one this build doesn't have.
    for id in "${fix_order[@]}"; do
        [ "${fix_status[$id]}" == "already" ] && [ -n "${fix_absent_files[$id]:-}" ] \
            && [ -z "${fix_has_file[$id]:-}" ] && fix_status[$id]="absent"
    done
    # Tools → Game settings: in place because this script put it there,
    # so it can be turned off again (put back from the manifest).
    if [ -n "${GAME_SETTINGS_EDIT:-}" ]; then
        for id in "${fix_order[@]}"; do
            [ "${fix_status[$id]}" == "already" ] && [ -n "${GAME_SETTINGS_RECORDED[${fix_title[$id]}]:-}" ] \
                && fix_status[$id]="applied"
        done
    fi
}

# Usage: _gs_audio_list decline|show
# Lists the audio fixes in order: the ones to offer are declined or shown in
# full, the rest get their status line.
_gs_audio_list() {
    local id
    for id in "${fix_order[@]}"; do
        [[ "$id" == audio:* ]] || continue
        case "${fix_status[$id]}" in
            offer) if [ "$1" == "decline" ]; then _gs_decline_fix "$id"; else _gs_print_fix "$id"; fi ;;
            already|missing|absent) _gs_print_status_line "$id" ;;
        esac
    done
}

# The audio part: the settings EAX needs, asked about once.
_gs_audio_flow() {
    local id
    local any_audio=0 audio_offer=0
    for id in "${fix_order[@]}"; do
        # Tools → Game settings lists the audio settings in the tick list below.
        [ -n "${GAME_SETTINGS_EDIT:-}" ] && break
        [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing|absent)$ ]] && any_audio=1
        [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] && audio_offer=1
        if [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]]; then
            GAME_AUDIO_FIX_TITLES+=("${fix_title[$id]}")
            [ "${fix_status[$id]}" == "already" ] && GAME_AUDIO_FIX_ALREADY+=("${fix_title[$id]}")
        fi
    done
    # Asked before the list, so a player who'd rather set the game up by
    # hand doesn't read through it; Tools → Speaker configuration already
    # chose to change these. A No still shows why the rest aren't offered.
    [ "$any_audio" -eq 1 ] && _gs_heading audio
    local wanted=1
    if [ "$audio_offer" -eq 1 ] && [ -z "${GAME_SETTINGS_SPEAKERS_ONLY:-}" ] \
        && ! confirm "Change ${GAME_NAME}'s settings to turn on EAX?" Y; then
        wanted=0
        print_note "${GAME_NAME}'s EAX options will stay off, so you'll need to turn them on yourself in the game's own settings."
        _gs_audio_list decline
    fi
    if [ "$any_audio" -eq 1 ] && [ "$wanted" -eq 1 ]; then
        print_result "Audio settings for ${GAME_NAME}:"
        _gs_audio_list show
        if [ "$audio_offer" -eq 1 ]; then
            local accepted=0
            confirm "Apply these settings?" Y && accepted=1
            for id in "${fix_order[@]}"; do
                [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] || continue
                if [ "$accepted" -eq 1 ]; then _gs_plan_fix "$id"; else _gs_decline_fix "$id"; fi
            done
        fi
    fi
}

# Tools → Game settings: the tick list starts from what is on now; nothing is
# declined, only changed. Esc leaves everything as it was.
_gs_optional_edit_list() {
    local i id
    while true; do
        CHECKLIST_INITIAL=("${picks[@]}"); CHECKLIST_DETAILS=("${bodies[@]}")
        if ! checklist_select "Press Enter to keep these as they are, type the numbers you want on (e.g. \"$example\"), or 'n' for none:" \
            "${offered_titles[@]}"; then
        GAME_SETTINGS_CANCELLED=1
        return
        fi
        picks=("${SELECTED[@]}")
        if [ "${picks[*]}" == "${initial[*]}" ] || [ "$CHECKLIST_TYPED" -eq 1 ]; then break; fi
        confirm "Apply these changes?" Y && break
    done
    for i in "${!offered[@]}"; do
        id="${offered[$i]}"
        if [ "${fix_status[$id]}" == "offer" ] && [ "${SELECTED[$((i + 1))]}" == "1" ]; then
            _gs_plan_fix "$id"
        elif [ "${fix_status[$id]}" == "applied" ] && [ "${SELECTED[$((i + 1))]}" == "0" ]; then
            GAME_SETTINGS_REVERT_GROUPS+=("${id%%:*}"$'\x1f'"${fix_title[$id]}"$'\x1f'"${GAME_SETTINGS_RECORDED[${fix_title[$id]}]}")
        fi
    done
}

# The install's optional settings: Esc applies none of them, like 'n'.
_gs_optional_install_list() {
    local i ticked
    while true; do
        CHECKLIST_INITIAL=("${picks[@]}"); CHECKLIST_DETAILS=("${bodies[@]}")
        if ! checklist_select "Type the numbers you want (e.g. \"$example\"), or press Enter for none:" \
            "${offered_titles[@]}"; then
            for ((i = 1; i <= ${#offered[@]}; i++)); do SELECTED[i]=0; done
            break
        fi
        [ "$CHECKLIST_TYPED" -eq 1 ] && break
        picks=("${SELECTED[@]}")
        ticked=0
        for i in "${picks[@]}"; do [ "$i" == "1" ] && ticked=$((ticked + 1)); done
        if [ "$ticked" -eq 0 ]; then
            confirm "Skip ${GAME_NAME}'s optional settings?" N && break
        elif [ "$ticked" -eq 1 ]; then
            confirm "Apply 1 optional setting?" Y && break
        else
            confirm "Apply ${ticked} optional settings?" Y && break
        fi
    done
    for i in "${!offered[@]}"; do
        if [ "${SELECTED[$((i + 1))]}" == "1" ]; then _gs_plan_fix "${offered[$i]}"; else _gs_decline_fix "${offered[$i]}"; fi
    done
}

# The optional part (and, in Tools → Game settings, the audio settings too).
_gs_optional_flow() {
    local id
    local -a optional=()
    for id in "${fix_order[@]}"; do
        [[ "$id" == optional:* || ( -n "${GAME_SETTINGS_EDIT:-}" && "$id" == audio:* ) ]] \
            && [[ "${fix_status[$id]}" =~ ^(offer|applied|already|missing|absent)$ ]] && optional+=("$id")
    done
    if [ ${#optional[@]} -gt 0 ]; then
        # The ones to choose from go in the tick list, each with its reason
        # and rows under its box; the rest get their status line first.
        local -a offered=() offered_titles=() initial=() bodies=() unoffered=()
        for id in "${optional[@]}"; do
            if [ "${fix_status[$id]}" == "offer" ]; then
                offered+=("$id"); offered_titles+=("${fix_title[$id]} $(verified_tag plain "${fix_untested[$id]:-}")"); initial+=(0)
                bodies+=("$(_gs_fix_body "$id")")
            elif [ "${fix_status[$id]}" == "applied" ]; then
                offered+=("$id"); offered_titles+=("${fix_title[$id]} (Active)"); initial+=(1)
                bodies+=("$(_gs_applied_fix_body "$id")")
            else
                unoffered+=("$id")
            fi
        done
        _gs_heading optional
        # Not needed for EAX, so each one starts unticked and only the ones
        # the player ticks are applied; looking at them costs nothing, so
        # Yes is the default here. Tools → Game settings is the player
        # choosing to edit them, so it goes straight to the list.
        local review="Review them?" count="${#offered[@]} optional settings"
        [ ${#offered[@]} -eq 1 ] && { review="Review it?"; count="1 optional setting"; }
        if [ ${#offered[@]} -gt 0 ] && [ -z "${GAME_SETTINGS_EDIT:-}" ] \
            && ! confirm "${GAME_NAME} has ${count}. ${review}" Y; then
            print_note "${GAME_NAME}'s optional settings will stay as they are — you can review them later from Tools → Game settings in this script's main menu."
            for id in "${offered[@]}"; do _gs_decline_fix "$id"; done
            offered=()
        else
            if [ -n "${GAME_SETTINGS_EDIT:-}" ]; then print_result "Settings for ${GAME_NAME}:"
            else print_result "Optional settings for ${GAME_NAME}:"; fi
        fi
        for id in "${unoffered[@]}"; do _gs_print_status_line "$id"; done
        if [ ${#offered[@]} -gt 0 ]; then
            local example="1"
            [ ${#offered[@]} -gt 1 ] && example="1 2"
            # The tick list's Enter isn't the last word: a player who presses
            # it by mistake (or without seeing that Space ticks) gets a
            # question naming what it would do, and No goes back to the list
            # with the ticks kept. A typed answer (no terminal) is already
            # deliberate, and asking again there could loop on empty input.
            local -a picks=("${initial[@]}")
            if [ -n "${GAME_SETTINGS_EDIT:-}" ]; then _gs_optional_edit_list; else _gs_optional_install_list; fi
        fi
    fi
}

# Usage: game_settings_step <step_number>
# Phase 3's Game Settings step. Reads each fix's config files as they are now,
# so every row shows the real current → new value; nothing is written here.
# Accepted rows go into GAME_SETTINGS_PLAN for Phase 4. For the final summary,
# settings whose file doesn't exist yet go into GAME_SETTINGS_MISSING, ones the
# player turns down into GAME_SETTINGS_DECLINED, and ones left out because this
# build has no such file (if_missing "skip") into GAME_SETTINGS_ABSENT. A
# skipped file only drops its own rows; a setting is left out entirely when
# every file it changes is skipped, and either way the player is told.
# Prints nothing at all for a game with no fixes to offer.
# Tools → Game settings runs it in one of two modes (see settings-flow.sh):
# GAME_SETTINGS_SPEAKERS_ONLY=1 offers only the settings tied to a speaker
# layout; GAME_SETTINGS_EDIT=1 offers every setting in one tick list (audio
# first, then optional), with the ones this script already applied (GAME_SETTINGS_RECORDED: title →
# its manifest CONFIG lines) ticked, and unticking one queues its CONFIG lines
# in GAME_SETTINGS_REVERT_GROUPS to be put back.
game_settings_step() {
    local step="$1"
    GAME_SETTINGS_PLAN=(); GAME_SETTINGS_MISSING=(); GAME_SETTINGS_FOLLOW_UPS=()
    GAME_SETTINGS_DECLINED=(); GAME_SETTINGS_ABSENT=()
    GAME_AUDIO_FIX_TITLES=(); GAME_AUDIO_FIX_ALREADY=()
    GAME_SETTINGS_CANCELLED=""
    current_profile || return

    # Two steps: the audio settings (step <step>) and the optional ones (the
    # next step; in Tools → Game settings, which shows both in one list, the
    # caller's step). Each heading is printed the first time something needs
    # it: the missing-file prompt below can come before the lists, and a part
    # with nothing to show gets no heading at all.
    local audio_heading_shown=0 optional_heading_shown=0 audio_seen=0
    GAME_SETTINGS_STEP_SHOWN=""

    # The profile's alsoft.ini values (a reverb boost) are about the game,
    # not the player's speakers, so they're offered here under the audio
    # heading, not in Speaker Configuration. Only the install asks; both
    # Tools modes leave them alone. Before the rows check below, since a game
    # can have a boost and no config files to change.
    if [ -z "${GAME_SETTINGS_SPEAKERS_ONLY:-}" ] && [ -z "${GAME_SETTINGS_EDIT:-}" ]; then
        offer_alsoft_settings _gs_heading audio
    fi

    local -a rows=()
    local row
    while IFS= read -r row; do [ -n "$row" ] && rows+=("$row"); done < <(load_game_config_rows "$KG_ID" "$KG_STORE")
    [ ${#rows[@]} -eq 0 ] && return
    local has_headphones=""
    for row in "${rows[@]}"; do
        [[ ",$(cut -d $'\x1f' -f 6 <<< "$row")," == *",headphones,"* ]] && has_headphones=1 && break
    done

    # Per-fix state, keyed "category:number" in database order.
    local -a fix_order=()
    local -A fix_title=() fix_reason=() fix_follow=() fix_status=() fix_rows=() fix_missing_file=() fix_untested=() fix_view=()
    # Per fix: |-joined files it changes that this build doesn't have, whether
    # any of its files was found, and the files its offered rows change.
    local -A fix_absent_files=() fix_has_file=() fix_files=()
    local -A file_path=() file_state=()

    _gs_build_plan

    local shown=0 id
    for id in "${fix_order[@]}"; do
        [[ "${fix_status[$id]}" =~ ^(offer|applied|already|missing|absent)$ ]] && shown=1
    done
    [ "$shown" -eq 0 ] && return

    _gs_audio_flow
    _gs_optional_flow
    return 0
}

# Usage: profile_field <jq path, e.g. .exe>
# One field of the current game's profile (KG_ID / KG_STORE), or
# nothing.
profile_field() {
    gdb_jq "$KG_ID" "$KG_STORE" "entry0 | $1 // empty"
}

# Usage: game_exe_running
# True while the game's own exe (the entry's "exe") is running. Wine and
# Proton keep the Windows path in the command line, so the name is matched
# there, ignoring case as Windows does. This script's own process tree is
# left out: a shell whose command line merely mentions the exe isn't the game.
game_exe_running() {
    local exe pid p
    local -A ours=()
    exe="$(profile_field .exe)"
    [ -n "$exe" ] || return 1
    for (( p = $$; p > 1; p = $(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1) )); do ours[$p]=1; done
    while read -r pid; do
        [ -n "${ours[$pid]:-}" ] && continue
        for (( p = pid; p > 1; p = $(awk '{print $4}' "/proc/$p/stat" 2>/dev/null || echo 1) )); do
            [ "$p" == "$$" ] && continue 2
        done
        return 0
    done < <(pgrep -i -f "(\\\\|/)${exe//./\\.}( |$)" 2>/dev/null)
    return 1
}

# Usage: clear_crash_marker <config file name in game_config.files> <path>
# A config file can name a crash marker (game_config.files.<name>.crash_marker):
# a file the game keeps next to it while running and deletes when quit
# normally. Left behind, the game treats its last run as a crash and resets
# the config file on its next start, undoing these changes, so it's removed
# first. Only while the game isn't running, since then it's the game's own
# live marker. Never recorded in the manifest: putting it back on uninstall
# would cause exactly that reset.
clear_crash_marker() {
    local marker dir
    marker="$(profile_field ".game_config.files[\"$1\"].crash_marker")"
    [ -n "$marker" ] || return 0
    [[ "$marker" =~ ^[A-Za-z0-9._\ -]+$ ]] && [ "$marker" != "." ] && [ "$marker" != ".." ] || return 0
    dir="$(dirname "$2")"
    [ -e "$dir/$marker" ] || return 0
    if game_exe_running; then
        print_warning_arrow "$GAME_NAME is running, so it may undo this change when it closes."
        return 0
    fi
    if rm -f "$dir/$marker" 2>/dev/null; then
        log_cmd "removed crash marker $dir/$marker before changing $2"
        print_status "Removed ${marker}, left over from a time $GAME_NAME didn't quit from its menu, so it won't reset $(basename "$2") on its next start."
    fi
}

# Usage: wine_registry_quiet
# Before the first registry change of a run: Wine keeps the registry in
# wineserver's memory and writes system.reg / user.reg back when it exits,
# which would undo an edit made while it runs. So this waits for it to save
# and exit (e.g. after the install's own registry import). Returns 1 while
# the game is running, since then wineserver won't exit.
wine_registry_quiet() {
    if game_exe_running; then
        print_warning_arrow "$GAME_NAME is running, so its registry settings can't be changed until it's closed."
        return 1
    fi
    flush_wine_registry "Waiting for Wine to save the registry..."
    return 0
}

# Splits a manifest "CONFIG:" line (tab-separated) into the array named by $2.
parse_config_line() {
    local -n _out="$2"
    mapfile -t -d $'\t' _out < <(printf '%s' "${1#CONFIG:}")
}

# Waits for wineserver to save the registry the first time it is called in a
# loop; $1 names the caller's state variable ("" until asked, then ok/busy), so
# later registry rows reuse the answer. Returns 0 when the files are safe to edit.
registry_quiet_once() {
    local -n _state="$1"
    [ -n "$_state" ] || { wine_registry_quiet && _state="ok" || _state="busy"; }
    [ "$_state" == "ok" ]
}

# Usage: _apply_skip_there <key> <path> <title> <why>
# The warning for one setting that can't be applied to one file, e.g. "<key>
# in <file> <why>, so "<title>" wasn't applied there."
_apply_skip_there() {
    print_warning_arrow "$1 in $(basename "$2") $4, so \"$3\" wasn't applied there."
}

# Usage: _apply_prepare_file <path> <file> <state> <title>
# Gets one config file ready for its first edit: creates it when the plan says
# to, otherwise backs it up once. Returns 1 when its settings must be skipped.
# Uses apply_game_settings' backed_up table.
_apply_prepare_file() {
    local path="$1" file="$2" state="$3" title="$4"
    if [ ! -f "$path" ]; then
        if [ "$state" != "create" ]; then
            print_warning_arrow "$(basename "$path") has gone missing since the settings were chosen, so \"$title\" wasn't applied."
            return 1
        fi
        if touch "$path" 2>/dev/null; then
            echo "$path" >> "$INSTALL_MANIFEST"
            backed_up[$path]=1   # nothing of the player's to back up in a file just created
            print_status "Created: $(basename "$path")"
        else
            record_deploy_failure "$path"; return 1
        fi
    elif [ -z "${backed_up[$path]:-}" ]; then
        clear_crash_marker "$file" "$path"
        if [ ! -e "$path.eax-restore.bak" ] && [ -z "${PREV_MANIFEST_FILES[$path]:-}" ]; then
            if cp -p "$path" "$path.eax-restore.bak" 2>/dev/null; then
                print_status "Backed up $(basename "$path") to $(basename "$path").eax-restore.bak"
            else
                print_warning_arrow "Couldn't back up $(basename "$path") first, so the original value is only in the install record."
            fi
        fi
        backed_up[$path]=1
    fi
}

# Usage: _apply_one_setting <GAME_SETTINGS_PLAN row>
# Writes one planned row, checks it took and records it in the manifest. Uses
# apply_game_settings' tables (prev_old, recorded, changed_count, backed_up,
# reg_state), so it only runs from there.
_apply_one_setting() {
    local -a f
    mapfile -t -d $'\x1f' f < <(printf '%s' "$1")
    local cat="${f[0]}" title="${f[1]}" path="${f[2]}" fmt="${f[3]}" sec="${f[4]}" key="${f[5]}"
    local new="${f[6]}" file="${f[7]}" state="${f[9]}" old

    # Once, before the registry file is backed up or read.
    if [ "$fmt" == "registry" ]; then
        registry_quiet_once reg_state || { record_deploy_failure "$path"; return; }
    fi
    _apply_prepare_file "$path" "$file" "$state" "$title" || return

    old="$(config_get_key "$path" "$fmt" "$sec" "$key")"
    config_values_equal "$fmt" "$old" "$new" && return
    # Revert can only write 0 or 1 back to a binary_switches flag, so any other
    # original value would be changed for good.
    if [ "$fmt" == "binary_switches" ] && [[ ! "$old" =~ ^[01]$ ]]; then
        _apply_skip_there "$key" "$path" "$title" "isn't a plain on/off value"
        return
    fi
    # A value with a tab or line break can't go in a manifest line
    # (tab-separated), so uninstall couldn't put it back.
    if [[ "$old" == *[$'\t\n']* ]]; then
        _apply_skip_there "$key" "$path" "$title" "holds a tab or line break"
        return
    fi
    if ! config_set_key "$path" "$fmt" "$sec" "$key" "$new" \
        || ! { [ "$new" == "__DELETE__" ] || config_values_equal "$fmt" "$(config_get_key "$path" "$fmt" "$sec" "$key")" "$new"; }; then
        record_deploy_failure "$path"; return
    fi
    [ -n "${prev_old["$path"$'\x1f'"$sec"$'\x1f'"$key"]+x}" ] && old="${prev_old["$path"$'\x1f'"$sec"$'\x1f'"$key"]}"
    printf 'CONFIG:%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cat" "$title" "$path" "$fmt" "$sec" "$key" "$old" "$new" >> "$INSTALL_MANIFEST"
    recorded["$path"$'\x1f'"$sec"$'\x1f'"$key"]=1
    changed_count[$path]=$(( ${changed_count[$path]:-0} + 1 ))
    [[ " ${GAME_SETTINGS_APPLIED[*]-} " == *" $title "* ]] || GAME_SETTINGS_APPLIED+=("$title")
}

# Carries over last install's CONFIG lines whose change is still in effect, so
# uninstall can still revert them. Skips the ones apply_game_settings just
# rewrote (its recorded table).
_apply_carry_over_config_lines() {
    local line
    local -a f
    for line in "${PREV_CONFIG_LINES[@]}"; do
        parse_config_line "$line" f
        [ -n "${recorded["${f[2]}"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"]:-}" ] && continue
        # A format this script can't read (from a newer build) can't be
        # checked, file or no file, so the record stays: dropping it would
        # leave the change with nothing to put it back.
        if config_format_unreadable "${f[3]}"; then echo "$line" >> "$INSTALL_MANIFEST"; continue; fi
        [ -n "${f[3]}" ] && [ -f "${f[2]}" ] || continue
        config_values_equal "${f[3]}" "$(config_get_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}")" "${f[7]}" \
            && echo "$line" >> "$INSTALL_MANIFEST"
    done
}

# Usage: apply_game_settings
# Phase 4: writes GAME_SETTINGS_PLAN into the game's config files and records
# each change in the manifest as
#   CONFIG:<audio|optional>\t<title>\t<path>\t<format>\t<section>\t<key>\t<old>\t<new>
# Each file is backed up once as <file>.eax-restore.bak before its first edit
# ever, and re-read first so a change made since Phase 3 isn't clobbered
# needlessly. On a reinstall, the old value recorded last time is kept (it's
# the player's original), and last run's CONFIG lines for settings still in
# effect are carried over so uninstall can still revert them.
apply_game_settings() {
    local -A recorded=() prev_old=()
    local line path reg_state=""
    local -a f

    # Last install's original values, by path/section/key.
    for line in "${PREV_CONFIG_LINES[@]}"; do
        parse_config_line "$line" f
        prev_old["${f[2]}"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"]="${f[6]}"
    done

    if [ ${#GAME_SETTINGS_PLAN[@]} -gt 0 ]; then
        print_phase_task "Applying game settings"
        local -A changed_count=() backed_up=()
        for line in "${GAME_SETTINGS_PLAN[@]}"; do _apply_one_setting "$line"; done
        for path in "${!changed_count[@]}"; do
            local n="${changed_count[$path]}" noun="setting"
            [ "$n" -ne 1 ] && noun="settings"
            print_status "Updated $(basename "$path") ($n $noun)"
        done
    fi

    _apply_carry_over_config_lines
}

# Usage: update_game_settings_in_manifest
# Tools → Game settings' Phase 2, for a game that's already installed: puts
# back GAME_SETTINGS_REVERT_GROUPS (revert_game_settings), then rewrites
# INSTALL_MANIFEST the way a reinstall does — every non-CONFIG line kept, the
# CONFIG lines of the settings just put back dropped (a failed put-back stays,
# via GAME_SETTINGS_KEPT), and apply_game_settings writes GAME_SETTINGS_PLAN,
# keeping each key's original value, and carries over the rest still in
# effect. Returns 1 if the manifest couldn't be rewritten.
update_game_settings_in_manifest() {
    local entry lines line tmp
    local -A dropped=()
    GAME_SETTINGS_KEPT=()
    revert_game_settings
    for entry in "${GAME_SETTINGS_REVERT_GROUPS[@]}"; do
        lines="${entry#*$'\x1f'}"; lines="${lines#*$'\x1f'}"
        while IFS= read -r line; do [ -n "$line" ] || continue; upgrade_config_line "$line"; dropped["$UPGRADED_LINE"]=1; done <<< "$lines"
    done
    for line in "${GAME_SETTINGS_KEPT[@]}"; do upgrade_config_line "$line"; unset 'dropped[$UPGRADED_LINE]'; done

    declare -gA PREV_MANIFEST_FILES=()
    PREV_CONFIG_LINES=()
    tmp="$(mktemp "$(dirname "$INSTALL_MANIFEST")/.eax-restore-manifest.XXXXXX" 2>/dev/null)" || {
        record_deploy_failure "$INSTALL_MANIFEST"; return 1; }
    while IFS= read -r line; do
        if [[ "$line" == CONFIG:* ]]; then
            upgrade_config_line "$line"; line="$UPGRADED_LINE"
            [ -n "${dropped[$line]:-}" ] || PREV_CONFIG_LINES+=("$line")
        else
            printf '%s\n' "$line"
            [[ "$line" == /* ]] && PREV_MANIFEST_FILES["$line"]=1
        fi
    done < "$INSTALL_MANIFEST" > "$tmp"
    chmod --reference="$INSTALL_MANIFEST" "$tmp" 2>/dev/null
    if ! mv "$tmp" "$INSTALL_MANIFEST" 2>/dev/null; then
        rm -f "$tmp"; record_deploy_failure "$INSTALL_MANIFEST"; return 1
    fi
    apply_game_settings
}

# Usage: game_audio_settings_done
# True when the game has audio settings and every one of them is now in place
# (applied this run or already set), so EAX needs nothing more from the
# player in the game's own menus. A declined fix, or one whose config file
# doesn't exist yet, leaves it false.
game_audio_settings_done() {
    [ ${#GAME_AUDIO_FIX_TITLES[@]} -gt 0 ] || return 1
    local t
    for t in "${GAME_AUDIO_FIX_TITLES[@]}"; do
        [[ " ${GAME_SETTINGS_APPLIED[*]-} ${GAME_AUDIO_FIX_ALREADY[*]-} " == *" $t "* ]] || return 1
    done
}

# Usage: print_game_settings_summary
# INSTALLATION COMPLETE's "Game settings" section: fixes applied (with any
# follow-up the player still has to do), and every setting that wasn't — its
# config file doesn't exist yet, the player turned it down, or this build has
# no such file. Game Settings only save the player time, so one that wasn't
# applied is theirs to set by hand; this never asks them to run the script
# again.
print_game_settings_summary() {
    [ ${#GAME_SETTINGS_APPLIED[@]} -gt 0 ] || [ ${#GAME_SETTINGS_MISSING[@]} -gt 0 ] \
        || [ ${#GAME_SETTINGS_DECLINED[@]} -gt 0 ] || [ ${#GAME_SETTINGS_ABSENT[@]} -gt 0 ] || return
    local title entry fu t files
    local -a box=()
    # One line per setting: a tick if it's in place, a cross if not, with a
    # short reason only when the player didn't choose to skip it.
    _summary_skipped() {
        echo -e " ${YELLOW}✗${NC} ${WHITE}${1}${NC}${2:+${DIM} (${2})${NC}}"
    }
    print_result "${BOLD}Game settings:" "$YELLOW"
    for title in "${GAME_SETTINGS_APPLIED[@]}"; do
        echo -e " ${GREEN}✓${NC} ${WHITE}${title}${NC}"
        # Follow-ups go in a box of their own after the list: at the end of
        # a long run, a line of text under a tick is easy to scroll past.
        for entry in "${GAME_SETTINGS_FOLLOW_UPS[@]}"; do
            IFS=$'\x1f' read -r t fu <<< "$entry"
            [ "$t" == "$title" ] || continue
            [ ${#box[@]} -gt 0 ] && box+=("")
            box+=("${BOLD}${title}")
            mapfile -t -O "${#box[@]}" box < <(wrap_text 52 "  " "$fu")
            break
        done
    done
    for entry in "${GAME_SETTINGS_DECLINED[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "$title"
    done
    for entry in "${GAME_SETTINGS_MISSING[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "$title" "${GAME_NAME} hasn't created ${files} yet"
    done
    for entry in "${GAME_SETTINGS_ABSENT[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "$title" "${GAME_NAME} has no ${files}"
    done
    unset -f _summary_skipped
    if [ ${#box[@]} -gt 0 ]; then
        echo ""
        print_titled_box "$YELLOW" "Before you play" "${box[@]}"
    fi
}

# Usage: choose_game_settings_to_revert <step_number>
# Uninstall's Game Settings step (Phase 1). Lists the manifest's CONFIG lines
# as audio / optional settings and asks which to put back; nothing is written
# here. Sets GAME_SETTINGS_REVERT_GROUPS to the chosen settings (each entry is
# "category\x1ftitle\x1f" followed by that setting's CONFIG lines, one per line)
# and GAME_SETTINGS_KEPT to the CONFIG lines of the ones left in place.
choose_game_settings_to_revert() {
    local step="$1"
    GAME_SETTINGS_KEPT=(); GAME_SETTINGS_REVERT_GROUPS=()
    [ ${#CONFIG_LINES[@]} -gt 0 ] || return 0

    print_step "$step" "Game Settings"
    print_paragraph "This step asks which of ${GAME_NAME:-the game}'s own settings to put back to what they" \
        "were before the install."
    print_task "Reading the game settings this install changed"

    # Group lines by setting (category + title), keeping manifest order.
    # Manifests written before the rename call optional settings "extras".
    local -a groups=()
    local -A group_lines=()
    local line g
    local -a f
    for line in "${CONFIG_LINES[@]}"; do
        parse_config_line "$line" f
        g="${f[0]/#extras/optional}"$'\x1f'"${f[1]}"
        [ -n "${group_lines[$g]+x}" ] || groups+=("$g")
        group_lines[$g]+="$line"$'\n'
    done

    local titles="" noun="settings"
    for g in "${groups[@]}"; do titles+="${titles:+, }${g#*$'\x1f'}"; done
    [ ${#groups[@]} -eq 1 ] && noun="setting"
    print_status "${#groups[@]} ${noun} changed: ${titles}" ""

    # Audio settings first, then optional ones, each with its rows (what it
    # changed → the original it goes back to) under its box in the tick list.
    local -a order=() pick_titles=() bodies=()
    local cat display_rows i
    for cat in audio optional; do
        for g in "${groups[@]}"; do
            [[ "$g" == "$cat"$'\x1f'* ]] || continue
            order+=("$g"); pick_titles+=("${g#*$'\x1f'}")
            display_rows=""
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                parse_config_line "$line" f
                display_rows+="$(tilde_path "${f[2]}")"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"$'\x1f'"${f[7]}"$'\x1f'"${f[6]}"$'\n'
            done <<< "${group_lines[$g]}"
            bodies+=("$(print_config_rows "$display_rows")")
        done
    done

    # Esc puts none of them back, like 'n'.
    CHECKLIST_DETAILS=("${bodies[@]}")
    if ! checklist_select "Press Enter to put all of these back, type the numbers you want (e.g. \"1\"), or 'n' to keep them:" \
        "${pick_titles[@]}"; then
        for ((i = 1; i <= ${#order[@]}; i++)); do SELECTED[i]=0; done
    fi
    for i in "${!order[@]}"; do
        g="${order[$i]}"
        if [ "${SELECTED[$((i + 1))]}" == "1" ]; then
            GAME_SETTINGS_REVERT_GROUPS+=("$g"$'\x1f'"${group_lines[$g]}")
        else
            while IFS= read -r line; do [ -n "$line" ] && GAME_SETTINGS_KEPT+=("$line"); done <<< "${group_lines[$g]}"
        fi
    done
}

# Usage: revert_game_settings
# Uninstall Phase 2: puts back the original value of each setting chosen in
# choose_game_settings_to_revert — but only where the setting still has the
# value this script set, so anything the player changed since is left alone.
# A setting that can't be written stays in GAME_SETTINGS_KEPT, so the manifest
# keeps it.
revert_game_settings() {
    local entry g lines line current restored target reg_state=""
    local -a f
    for entry in "${GAME_SETTINGS_REVERT_GROUPS[@]}"; do
        g="${entry%%$'\x1f'*}"$'\x1f'; lines="${entry#*$'\x1f'}"; g+="${lines%%$'\x1f'*}"
        lines="${lines#*$'\x1f'}"
        restored=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            parse_config_line "$line" f
            # A damaged line (no format at all) has nothing to put back.
            [ -n "${f[3]}" ] || continue
            # A format from a newer build: leave it recorded, and say so, since
            # the game's file still has the changed value.
            if config_format_unreadable "${f[3]}"; then
                print_warning_arrow "Kept ${f[5]} in $(basename "${f[2]}") — a newer version of this script changed it, so this version can't put it back."
                GAME_SETTINGS_KEPT+=("$line"); continue
            fi
            [ -f "${f[2]}" ] || continue
            if [ "${f[3]}" == "registry" ]; then
                registry_quiet_once reg_state || { GAME_SETTINGS_KEPT+=("$line"); continue; }
            fi
            current="$(config_get_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}")"
            if ! config_values_equal "${f[3]}" "$current" "${f[7]}"; then
                print_status "Kept ${f[5]} in $(basename "${f[2]}") — it's been changed since install." "$DIM"
                continue
            fi
            target="${f[6]}"
            [ "$target" == "__ABSENT__" ] && target="__DELETE__"
            if config_set_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "$target"; then
                restored=$((restored + 1))
            else
                print_error_arrow "Couldn't write $(basename "${f[2]}"), so ${f[5]} wasn't put back."
                GAME_SETTINGS_KEPT+=("$line")
            fi
        done <<< "$lines"
        [ "$restored" -gt 0 ] && print_status "Put back: ${g#*$'\x1f'}"
    done
}
