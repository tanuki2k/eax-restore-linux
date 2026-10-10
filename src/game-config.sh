# ==============================================================================
# GAME SETTINGS (game profile game_config / install.alsoft_ini)
# ==============================================================================
# Everything the script changes in a game's own config files comes from that
# game's profile (game_config.audio_settings / optional_settings) — the script
# itself only knows how to read and edit the seven config formats, never which
# game needs what. Decided in Phase 1 (Speaker Configuration offers the
# alsoft.ini values, step 11 offers the game's own settings), applied in
# Phase 2, recorded in the manifest as CONFIG: lines, reverted on uninstall.
#
# Values travel through here as plain strings plus three markers:
#   __TRUE__ / __FALSE__  a dark_cfg flag switched on / off (true/false in JSON)
#   __DELETE__            remove the key (null in JSON)
#   __ABSENT__            (read side only) the key isn't in the file

# Usage: _gadb_find <file> <key>
# gadb is Monolith's binary game database, which F.E.A.R. keeps its player
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

# wine_reg is one of Wine's registry files, system.reg (HKLM) or user.reg
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
        function hex2dec(h,   i, d) { d = 0; h = tolower(h)
            for (i = 1; i <= length(h); i++) d = d * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
            return d }
        /^\[/ { h = $0; sub(/\][^]]*$/, "]", h); insec = (tolower(h) == want); next }
        insec && tolower(substr($0, 1, length(pre))) == pre {
            v = substr($0, length(pre) + 1)
            if (v ~ /^dword:[0-9a-fA-F]+$/) printf "dword\t%d\n", hex2dec(substr(v, 7))
            else if (v ~ /^".*"$/) {
                v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v)
                printf "string\t%s\n", v
            } else print "raw\t__RAW__"
            found = 1; exit
        }
        END { if (!found) print "absent\t__ABSENT__" }' "$1"
}

# Usage: _wine_reg_set <file> <key path> <value name> <value>
# config_set_key for wine_reg. A value keeps its type: a dword stays a dword
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
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Usage: config_get_key <file> <ini|flat_ini|idtech_cfg|dark_cfg|brace_cfg|gadb|wine_reg> <section> <key>
# Prints the key's current value, __ABSENT__ if it isn't set, or (dark_cfg
# only) __TRUE__ for an active bare flag and __FALSE__ for a flag that's only
# present commented out. Section and key names match case-insensitively, like
# the games themselves read them. brace_cfg is Fallout Tactics' "{key} = {value}"
# lines. A gadb key is one on/off setting, 0 or 1.
config_get_key() {
    local file="$1" fmt="$2" sec="$3" key="$4" found
    [ -f "$file" ] || { echo "__ABSENT__"; return; }
    if [ "$fmt" == "wine_reg" ]; then
        found="$(_wine_reg_read "$file" "$sec" "$key")"; echo "${found#*$'\t'}"
        return
    fi
    if [ "$fmt" == "gadb" ]; then
        found="$(_gadb_find "$file" "$key")"
        if [ -n "$found" ]; then echo "${found#* }"; else echo "__ABSENT__"; fi
        return
    fi
    LC_ALL=C awk -v fmt="$fmt" -v sec="$sec" -v key="$key" '
        BEGIN { lsec = tolower(sec); lkey = tolower(key); insec = (fmt != "ini"); found = 0; commented = 0 }
        { sub(/\r$/, "") }
        fmt == "ini" || fmt == "flat_ini" {
            if (fmt == "ini" && $0 ~ /^[ \t]*\[.*\][ \t]*$/) {
                s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (tolower(s) == lsec); next
            }
            if (!insec) next
            p = index($0, "="); if (p == 0) next
            k = substr($0, 1, p - 1); gsub(/^[ \t]+|[ \t]+$/, "", k)
            if (tolower(k) != lkey) next
            v = substr($0, p + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            print v; found = 1; exit
        }
        fmt == "idtech_cfg" {
            line = $0; if (!match(tolower(line), /^[ \t]*seta?[ \t]+/)) next
            rest = substr(line, RLENGTH + 1); split(rest, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) next
            v = substr(rest, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
            print v; found = 1; exit
        }
        fmt == "dark_cfg" {
            line = $0; is_comment = (line ~ /^[ \t]*;/)
            sub(/^[ \t]*;?[ \t]*/, "", line); split(line, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) next
            if (is_comment) { commented = 1; next }
            v = substr(line, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            print (v == "" ? "__TRUE__" : v); found = 1; exit
        }
        fmt == "brace_cfg" {
            if (!match($0, /^[ \t]*\{[^}]*\}[ \t]*=[ \t]*\{/)) next
            k = substr($0, 1, RLENGTH); sub(/^[ \t]*\{[ \t]*/, "", k); sub(/[ \t]*\}.*$/, "", k)
            if (tolower(k) != lkey) next
            v = substr($0, RLENGTH + 1); sub(/\}[ \t]*$/, "", v)
            print v; found = 1; exit
        }
        END { if (!found) print ((fmt == "dark_cfg" && commented) ? "__FALSE__" : "__ABSENT__") }
    ' "$file"
}

# Usage: _gadb_set <file> <key> <0|1>
# config_set_key for gadb: overwrites the value of the key's existing on/off
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
        chmod --reference="$file" "$tmp" 2>/dev/null
        mv -f "$tmp" "$file" 2>/dev/null && return 0
    fi
    rm -f "$tmp"
    return 1
}

# Usage: config_set_key <file> <ini|flat_ini|idtech_cfg|dark_cfg|brace_cfg|gadb|wine_reg> <section> <key> <value>
# Sets (or with __DELETE__ removes) one key, keeping everything else in the
# file as it was — including CRLF line endings, the original spelling of an
# existing key, and "key = value" spacing. A missing ini key goes at the end
# of its section (or a new section at the end of the file); a missing flat_ini
# or cfg key is appended. An existing brace_cfg key only has the text between
# its value's braces replaced. flat_ini is ini without [sections] — the whole file
# is one section, so its rows carry no section name. For dark_cfg, a commented-out example line is left in place and
# the active line is added right after it. gadb only switches an existing
# on/off setting (see _gadb_set). Writes through a temp file in the
# same folder and swaps it in, so a failure never leaves a half-written file.
# Returns 1 if the file couldn't be written.
config_set_key() {
    local file="$1" fmt="$2" sec="$3" key="$4" value="$5"
    local crlf=0 current tmp
    [ "$fmt" == "gadb" ] && { _gadb_set "$file" "$key" "$value"; return; }
    [ "$fmt" == "wine_reg" ] && { _wine_reg_set "$file" "$sec" "$key" "$value"; return; }
    [ -f "$file" ] && LC_ALL=C grep -q $'\r' "$file" 2>/dev/null && crlf=1
    current="$(config_get_key "$file" "$fmt" "$sec" "$key")"
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-cfg.XXXXXX" 2>/dev/null)" || return 1
    { [ -f "$file" ] && cat "$file"; } | LC_ALL=C awk -v fmt="$fmt" -v sec="$sec" -v key="$key" -v val="$value" \
        -v crlf="$crlf" -v current="$current" '
        function out(line) { printf "%s%s", line, (crlf ? "\r\n" : "\n") }
        function flush_blanks() { while (nb > 0) { out(""); nb-- } }
        function ini_line() { return key "=" val }
        BEGIN {
            lsec = tolower(sec); lkey = tolower(key); insec = (fmt == "flat_ini"); seen_sec = insec; done = 0; nb = 0
            del = (val == "__DELETE__")
            active = (current != "__ABSENT__" && current != "__FALSE__")
        }
        { sub(/\r$/, "") }
        fmt == "ini" || fmt == "flat_ini" {
            if (fmt == "ini" && $0 ~ /^[ \t]*\[.*\][ \t]*$/) {
                if (insec && !done && !del) { out(ini_line()); done = 1 }
                flush_blanks()
                s = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", s); insec = (tolower(s) == lsec); if (insec) seen_sec = 1
                out($0); next
            }
            if ($0 ~ /^[ \t]*$/) { nb++; next }
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
        fmt == "idtech_cfg" {
            line = $0
            if (!done && match(tolower(line), /^[ \t]*seta?[ \t]+/)) {
                rest = substr(line, RLENGTH + 1); split(rest, a, /[ \t]+/)
                if (tolower(a[1]) == lkey) { done = 1; if (!del) out("seta " a[1] " \"" val "\""); next }
            }
            out(line); next
        }
        fmt == "dark_cfg" {
            line = $0; is_comment = (line ~ /^[ \t]*;/)
            t = line; sub(/^[ \t]*;?[ \t]*/, "", t); split(t, a, /[ \t]+/)
            if (tolower(a[1]) != lkey) { out(line); next }
            if (!is_comment) {
                if (del) next
                if (val == "__FALSE__") { out(";" line); next }
                if (done) { out(line); next }
                done = 1
                out(val == "__TRUE__" ? a[1] : a[1] " " val); next
            }
            out(line)
            if (!active && !done && !del && val != "__FALSE__") {
                done = 1
                out(val == "__TRUE__" ? a[1] : a[1] " " val)
            }
            next
        }
        fmt == "brace_cfg" {
            if (!done && match($0, /^[ \t]*\{[^}]*\}[ \t]*=[ \t]*\{/)) {
                head = substr($0, 1, RLENGTH); k = head
                sub(/^[ \t]*\{[ \t]*/, "", k); sub(/[ \t]*\}.*$/, "", k)
                if (tolower(k) == lkey) { done = 1; if (!del) out(head val "}"); next }
            }
            out($0); next
        }
        END {
            if (fmt == "ini" || fmt == "flat_ini") {
                if (insec && !done && !del) { out(ini_line()); done = 1 }
                flush_blanks()
                if (!seen_sec && !done && !del) {
                    if (NR > 0) out("")
                    out("[" sec "]"); out(ini_line())
                }
            } else if (!done && !del && val != "__FALSE__") {
                if (fmt == "idtech_cfg") out("seta " key " \"" val "\"")
                else if (fmt == "brace_cfg") out("{" key "} = {" val "}")
                else out(val == "__TRUE__" ? key : key " " val)
            }
        }
    ' > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -f "$file" ] && chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Usage: config_values_equal <format> <a> <b>
# ini values compare case-insensitively (Unreal reads "True" and "true" the
# same), and so do wine_reg strings, while its dwords compare as numbers
# ("03" is 3); everything else must match exactly.
config_values_equal() {
    if [ "$1" == "wine_reg" ] && [[ "$2" =~ ^[0-9]{1,10}$ && "$3" =~ ^[0-9]{1,10}$ ]]; then
        [ "$((10#$2))" -eq "$((10#$3))" ]
    elif [ "$1" == "ini" ] || [ "$1" == "wine_reg" ]; then [ "${2,,}" == "${3,,}" ]
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
# The game's install root, for "install:" locations: the folder the library
# scan matched, else the steamapps/common/<Game> folder GAME_DIR sits in, else
# the Heroic install_path GAME_DIR sits in, else GAME_DIR itself.
game_install_root() {
    if [ -n "${GAME_INSTALL_ROOT:-}" ] && [[ "$GAME_DIR" == "$GAME_INSTALL_ROOT"* ]]; then
        echo "$GAME_INSTALL_ROOT"; return
    fi
    if [[ "$GAME_DIR" == */steamapps/common/* ]]; then
        local rest="${GAME_DIR#*/steamapps/common/}"
        echo "${GAME_DIR%%/steamapps/common/*}/steamapps/common/${rest%%/*}"; return
    fi
    local json path best=""
    while IFS= read -r json; do
        while IFS= read -r path; do
            [ -n "$path" ] && [[ "$GAME_DIR" == "$path"* ]] && [ ${#path} -gt ${#best} ] && best="$path"
        done < <(jq -r '.. | objects | (.install_path // .installPath // empty)' "$json" 2>/dev/null)
    done < <(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)
    echo "${best:-$GAME_DIR}"
}

# Usage: resolve_config_file <"base:path|base:path…">
# Prints the first location that exists (matching the file name's case
# loosely, like find_existing_variant does for DLLs). Prints nothing if none
# does. With a second argument "create", prints the first location whose
# folder exists instead, for a file that's about to be created.
resolve_config_file() {
    local locations="$1" mode="${2:-}" loc base rel dir candidate found u
    local -a dirs
    IFS='|' read -ra locs <<< "$locations"
    for loc in "${locs[@]}"; do
        base="${loc%%:*}"; rel="${loc#*:}"
        dirs=()
        case "$base" in
            game) dirs=("$GAME_DIR") ;;
            install) dirs=("$(game_install_root)") ;;
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
            # The prefix's own registry files (wine_reg), nothing else.
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
                [ -n "$found" ] && [ -f "$found" ] && { echo "$found"; return; }
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
    jq -r --arg id "$1" --arg store "$2" '
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))] | length;
          "\(.audio_settings | offered) \(.optional_settings | offered)"' "$GAME_DATABASE_FILE" 2>/dev/null
}

# Usage: game_setting_titles <id> <steam|gog>
# One "audio|optional<TAB>title" line per setting count_game_settings counts,
# audio settings first, for the game profile screen.
game_setting_titles() {
    jq -r --arg id "$1" --arg store "$2" '
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))];
          (.audio_settings | offered | .[] | "audio\t\(.title)"),
          (.optional_settings | offered | .[] | "optional\t\(.title)")' "$GAME_DATABASE_FILE" 2>/dev/null
}

# Usage: speakers_match <comma list>
# True when the Speaker Configuration answer is one of the listed values:
# stereo / matrix / surround (any layout) match OUTPUT_MODE, headphones
# matches the Stereo → Headphones answer (not Auto), and an exact layout
# (quad, surround51, ...) matches SURROUND_CHANNELS.
speakers_match() {
    local v
    local -a wanted
    IFS=',' read -ra wanted <<< "$1"
    for v in "${wanted[@]}"; do
        [ "$v" == "$OUTPUT_MODE" ] && return 0
        [ "$v" == "headphones" ] && [ "$OUTPUT_MODE" == "stereo" ] && [ "${STEREO_MODE:-}" == "headphones" ] && return 0
        [ "$OUTPUT_MODE" == "surround" ] && [ "$v" == "${SURROUND_CHANNELS:-}" ] && return 0
    done
    return 1
}

# Usage: load_game_config_rows <id> <steam|gog>
# Flattens the entry's fixes into one \x1f-separated row per changed key:
# category, fix number, title, reason, only_if stores (comma list),
# only_if speakers (comma list), follow_up, file, format, if_missing, locations
# (|-joined), section ("" for cfg formats), key, value (with the markers
# above). \x1f rather than tabs so empty fields survive `read`.
load_game_config_rows() {
    jq -r --arg id "$1" --arg store "$2" '
        def enc: if type == "boolean" then (if . then "__TRUE__" else "__FALSE__" end)
                 elif . == null then "__DELETE__" else tostring end;
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].game_config // empty
        | (.files // {}) as $files
        | ((.audio_settings // []) | to_entries[] | {cat: "audio", i: .key, f: .value}),
          ((.optional_settings // []) | to_entries[] | {cat: "optional", i: .key, f: .value})
        | .cat as $cat | .i as $i | .f as $f
        | $f.changes | to_entries[] | .key as $file | ($files[$file] // {}) as $def
        | (if $def.format == "ini" or $def.format == "wine_reg"
             then (.value | to_entries[] | .key as $sec | .value | to_entries[] | [$sec, .key, .value])
             else (.value | to_entries[] | ["", .key, .value]) end) as $kv
        | [$cat, ($i | tostring), $f.title, $f.reason, (($f.only_if.stores // []) | join(",")),
           ([$f.only_if.speakers // empty] | flatten | join(",")), ($f.follow_up // ""), $file, ($def.format // ""),
           ($def.if_missing // ""), (($def.locations // []) | join("|")), $kv[0], $kv[1], ($kv[2] | enc)]
        | join("\u001f")' "$GAME_DATABASE_FILE" 2>/dev/null
}

# Usage: config_row_is_safe <format> <locations> <section> <key> <value>
# The schema already enforces all this in CI; this re-checks only what could
# touch the wrong file or corrupt one, in case a bad entry slips through.
# wine_reg is the only format for the prefix's registry files, and only
# them; its section is a registry key path, backslash-separated.
config_row_is_safe() {
    local fmt="$1" locations="$2" sec="$3" key="$4" value="$5" loc
    local name_re='^[A-Za-z0-9._ -]+$' value_re='^[A-Za-z0-9._ ()-]*$'
    local reg_key_re='^[A-Za-z0-9._ ()-]+(\\[A-Za-z0-9._ ()-]+)*$'
    [[ "$fmt" =~ ^(ini|flat_ini|idtech_cfg|dark_cfg|brace_cfg|gadb|wine_reg)$ ]] || return 1
    [ -n "$locations" ] || return 1
    IFS='|' read -ra locs <<< "$locations"
    for loc in "${locs[@]}"; do
        if [ "$fmt" == "wine_reg" ]; then
            [[ "$loc" =~ ^prefix:(system|user)\.reg$ ]] || return 1
            continue
        fi
        [[ "$loc" =~ ^(game|install|prefix_documents|prefix_appdata|prefix_localappdata|prefix_public_documents):[^/\\] ]] || return 1
        [[ "$loc" == *..* || "$loc" == *\\* ]] && return 1
    done
    [[ "$key" =~ $name_re ]] || return 1
    if [ "$fmt" == "ini" ]; then [[ "$sec" =~ $name_re ]] || return 1; fi
    if [ "$fmt" == "wine_reg" ]; then [[ "$sec" =~ $reg_key_re ]] && [[ "$sec" != *..* ]] || return 1; fi
    # A gadb setting can only be switched on or off in place.
    if [ "$fmt" == "gadb" ]; then [[ "$value" =~ ^[01]$ ]] || return 1; fi
    case "$value" in
        __TRUE__|__FALSE__) [ "$fmt" == "dark_cfg" ] || return 1 ;;
        __DELETE__) ;;
        *) [[ "$value" =~ $value_re ]] || return 1 ;;
    esac
}

# Usage: print_config_rows <rows>
# Prints a fix's changes as a tree: the file on its own line, its [section]
# under it (ini only), then one "key  old → new" line per change, with the
# keys lined up. A file or section line is only printed when it differs from
# the row above. <rows> is newline-separated \x1f rows of
# file, section, key, old, new. An old value of __ANY__ prints just
# "key  → new", for the database browser, which has no install to read the
# current value from.
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
        if [ "$old" == "__ANY__" ]; then
            printf "%s${WHITE}%-${key_len}s${NC}  → ${GREEN}%s${NC}\n" "$indent" "$key" "$(config_display_value "$new")"
        else
            printf "%s${WHITE}%-${key_len}s${NC}  %s → ${GREEN}%s${NC}\n" "$indent" "$key" "$(config_display_value "$old")" "$(config_display_value "$new")"
        fi
        prev_file="$file"; prev_sec="$sec"
    done <<< "$1"
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
        < <([ -n "$store_id" ] && load_game_config_rows "$store_id" "$store_key")
    if [ ${#rows[@]} -eq 0 ]; then
        echo ""
        print_wrapped "${name:-This game} has no game settings in the database."
        return
    fi

    local -A location_label=([game]="game folder" [install]="install folder" [prefix_documents]="Documents"
        [prefix_appdata]="AppData" [prefix_public_documents]="Public Documents")
    local -A speaker_name=([stereo]="Stereo" [headphones]="Headphones" [matrix]="Matrix encoding"
        [surround]="Surround (any layout)" [quad]="Quad (4.0)" [surround51]="Surround 5.1"
        [surround61]="Surround 6.1" [surround71]="Surround 7.1")
    local width=$(( ${WRAP_COLUMNS:-76} - 2 ))
    local id prev_id="" prev_cat="" display_rows="" stores speakers follow file_label loc s
    local -a locs labels
    # One setting's rows are printed together, after its last row is read.
    _flush_setting() {
        [ -n "$prev_id" ] || return 0
        print_config_rows "$display_rows"
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
            echo -e "${WHITE}$(printf '%s' "$follow" | fold -s -w "$width" | sed 's/^/    /')${NC}"
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
            echo -e "\n  ${BOLD}${f[2]}${NC}"
            echo -e "${WHITE}$(printf '%s' "${f[3]}" | fold -s -w "$width" | sed 's/^/    /')${NC}"
            echo ""
            display_rows="" stores="${f[4]}" speakers="${f[5]}" follow="${f[6]}"
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
        file_label="${f[7]}  ($(IFS='|'; s="${labels[*]}"; echo "${s//|/ or }"))"
        display_rows+="${file_label}"$'\x1f'"${f[11]}"$'\x1f'"${f[12]}"$'\x1f'"__ANY__"$'\x1f'"${f[13]}"$'\n'
    done
    _flush_setting
    unset -f _flush_setting
    echo ""
}

# Usage: fix_rows_for_display <plan rows>
# Turns GAME_SETTINGS_PLAN-style rows into print_config_rows input.
fix_rows_for_display() {
    local r
    local -a g
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        mapfile -t -d $'\x1f' g < <(printf '%s' "$r")
        printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${g[7]}" "${g[4]}" "${g[5]}" "${g[8]}" "${g[6]}"
    done <<< "$1"
}

# Usage: ask_speaker_configuration
# Step 8's speaker questions, shared with Tools → Speaker configuration. Sets
# OUTPUT_MODE (stereo / surround / matrix), STEREO_MODE (stereo only),
# ENABLE_HRTF (the y/n answer) and SURROUND_CHANNELS (surround only).
ask_speaker_configuration() {
    echo -e "\n${WHITE}What kind of audio output are you using?${NC}\n"
    print_option 1 "Stereo (headphones or 2-speaker setup)"
    print_option 2 "Surround Sound (4.0/5.1/6.1/7.1 speaker setup)"
    print_option 3 "Matrix Encoding (stereo output decoded to surround by a receiver/soundbar)"

    while true; do
        prompt "Selection [1-3, Default: 1]: "
        read_answer OUTPUT_MODE_CHOICE
        OUTPUT_MODE_CHOICE="${OUTPUT_MODE_CHOICE:-1}"
        if [[ "$OUTPUT_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_result "That's not a valid option — please type 1, 2, or 3." "$YELLOW"; fi
    done

    ENABLE_HRTF=""
    SURROUND_CHANNELS=""

    if [ "$OUTPUT_MODE_CHOICE" == "1" ]; then
        OUTPUT_MODE="stereo"

        echo ""
        echo -e "${WHITE}What are you listening on?${NC}\n"
        print_option 1 "Auto (let OpenAL Soft decide)"
        print_option 2 "Speakers"
        print_option 3 "Headphones"

        while true; do
            prompt "Selection [1-3, Default: 1]: "
            read_answer STEREO_MODE_CHOICE
            STEREO_MODE_CHOICE="${STEREO_MODE_CHOICE:-1}"
            if [[ "$STEREO_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_result "That's not a valid option — please type 1, 2, or 3." "$YELLOW"; fi
        done

        case "$STEREO_MODE_CHOICE" in
            1) STEREO_MODE="auto" ;;
            2) STEREO_MODE="speakers" ;;
            3) STEREO_MODE="headphones" ;;
        esac

        if [ "$STEREO_MODE_CHOICE" == "2" ]; then
            # HRTF is a headphone-only binaural technique — meaningless (and
            # actively harmful to positional accuracy) over real speakers.
            ENABLE_HRTF="n"
        else
            echo ""
            echo -e "${CYAN}Headphones Configuration (HRTF)${NC}\n"
            echo -e "${WHITE}Head-Related Transfer Function (HRTF) translates 3D positional audio into a binaural"
            echo -e "format specifically designed for standard stereo headphones. Turning this on will"
            echo -e "allow you to hear exactly whether a sound is coming from above, below, or behind you.${NC}\n"
            echo -e "${YELLOW}Do you want to enable HRTF for headphones? (y/N): ${NC}"
            echo -e -n "> "
            read_answer ENABLE_HRTF
        fi
    elif [ "$OUTPUT_MODE_CHOICE" == "2" ]; then
        OUTPUT_MODE="surround"

        echo ""
        echo -e "${WHITE}Select your speaker channel configuration:${NC}\n"
        print_option 1 "Quad       (4.0)"
        print_option 2 "Surround51 (5.1)"
        print_option 3 "Surround61 (6.1)"
        print_option 4 "Surround71 (7.1)"

        while true; do
            prompt "Selection [1-4]: "
            read_answer SURROUND_CHOICE || exit 0
            case "$SURROUND_CHOICE" in
                1) SURROUND_CHANNELS="quad"; break ;;
                2) SURROUND_CHANNELS="surround51"; break ;;
                3) SURROUND_CHANNELS="surround61"; break ;;
                4) SURROUND_CHANNELS="surround71"; break ;;
                *) print_result "That's not a valid option — please type 1, 2, 3, or 4." "$YELLOW" ;;
            esac
        done
    else
        OUTPUT_MODE="matrix"
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
}

# Usage: offer_alsoft_settings
# Speaker Configuration's last question: the game profile's
# install.alsoft_ini values, each stated as a fact about the game plus a
# default-yes offer. Accepted ones land in ALSOFT_OVERRIDES
# ("section\x1fkey\x1fvalue") for Phase 2 to write into the generated
# alsoft.ini.
offer_alsoft_settings() {
    ALSOFT_OVERRIDES=()
    current_profile || return
    local sec key value
    while IFS=$'\x1f' read -r sec key value; do
        [ -n "$key" ] || continue
        if [ "$sec/$key" == "reverb/boost" ]; then
            echo ""
            echo -e "${WHITE}${GAME_NAME}'s reverb is quiet at the default level.${NC}"
            confirm "Raise the reverb boost to +${value} dB?" Y || continue
        else
            confirm "Set ${key} to ${value} in alsoft.ini for ${GAME_NAME}?" Y || continue
        fi
        ALSOFT_OVERRIDES+=("$sec"$'\x1f'"$key"$'\x1f'"$value")
    done < <(jq -r --arg id "$KG_ID" --arg store "$KG_STORE" '
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].install.alsoft_ini // {}
        | to_entries[] | .key as $sec | .value | to_entries[] | [$sec, .key, (.value | tostring)] | join("\u001f")' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
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

# Usage: game_settings_step <step_number>
# Phase 1's Game Settings step. Reads each fix's config files as they are now,
# so every row shows the real current → new value; nothing is written here.
# Accepted rows go into GAME_SETTINGS_PLAN for Phase 2. For the final summary,
# settings whose file doesn't exist yet go into GAME_SETTINGS_MISSING, ones the
# player turns down into GAME_SETTINGS_DECLINED, and ones left out because this
# build has no such file (if_missing "skip") into GAME_SETTINGS_ABSENT. A
# skipped file only drops its own rows; a setting is left out entirely when
# every file it changes is skipped, and either way the player is told.
# Prints nothing at all for a game with no fixes to offer.
# Tools → Game settings runs it in one of two modes (see settings-flow.sh):
# GAME_SETTINGS_SPEAKERS_ONLY=1 offers only the settings tied to a speaker
# layout; GAME_SETTINGS_EDIT_OPTIONAL=1 offers only the optional settings,
# with the ones this script already applied (GAME_SETTINGS_RECORDED: title →
# its manifest CONFIG lines) ticked, and unticking one queues its CONFIG lines
# in GAME_SETTINGS_REVERT_GROUPS to be put back.
game_settings_step() {
    local step="$1"
    GAME_SETTINGS_PLAN=(); GAME_SETTINGS_MISSING=(); GAME_SETTINGS_FOLLOW_UPS=()
    GAME_SETTINGS_DECLINED=(); GAME_SETTINGS_ABSENT=()
    GAME_AUDIO_FIX_TITLES=(); GAME_AUDIO_FIX_ALREADY=()
    GAME_SETTINGS_CANCELLED=""
    current_profile || return

    local -a rows=()
    local row
    while IFS= read -r row; do [ -n "$row" ] && rows+=("$row"); done < <(load_game_config_rows "$KG_ID" "$KG_STORE")
    [ ${#rows[@]} -eq 0 ] && return

    # The step's heading, printed the first time something needs it: the
    # missing-file prompt below can come before the fix list, and a game with
    # nothing to show gets no heading at all.
    local heading_shown=0
    GAME_SETTINGS_STEP_SHOWN=""
    _game_settings_heading() {
        [ "$heading_shown" -eq 1 ] && return
        print_step "$step" "Game Settings"
        print_paragraph "This step offers changes to ${GAME_NAME:-the game}'s own settings, such as switching on" \
            "its EAX options."
        heading_shown=1
        GAME_SETTINGS_STEP_SHOWN=1
    }

    # Per-fix state, keyed "category:number" in database order.
    local -a fix_order=()
    local -A fix_title=() fix_reason=() fix_follow=() fix_status=() fix_rows=() fix_missing_file=()
    # Per fix: |-joined files it changes that this build doesn't have, whether
    # any of its files was found, and the files its offered rows change.
    local -A fix_absent_files=() fix_has_file=() fix_files=()
    local -A file_path=() file_state=()
    local cat idx title reason stores speakers follow file fmt ifmissing locs sec key value id path old
    local -a f
    for row in "${rows[@]}"; do
        mapfile -t -d $'\x1f' f < <(printf '%s' "$row")
        cat="${f[0]}"; idx="${f[1]}"; title="${f[2]}"; reason="${f[3]}"; stores="${f[4]}"; speakers="${f[5]}"
        follow="${f[6]}"; file="${f[7]}"; fmt="${f[8]}"; ifmissing="${f[9]}"; locs="${f[10]}"
        sec="${f[11]}"; key="${f[12]}"; value="${f[13]}"
        id="$cat:$idx"

        if [ -z "${fix_status[$id]+x}" ]; then
            fix_order+=("$id"); fix_title[$id]="$title"; fix_reason[$id]="$reason"; fix_follow[$id]="$follow"
            fix_status[$id]="already"; fix_rows[$id]=""
            if [ -n "$stores" ] && [[ ",$stores," != *",$KG_STORE,"* ]]; then fix_status[$id]="skip"; fi
            if [ -n "$speakers" ] && ! speakers_match "$speakers"; then fix_status[$id]="skip"; fi
            [ -n "${GAME_SETTINGS_SPEAKERS_ONLY:-}" ] && [ -z "$speakers" ] && fix_status[$id]="skip"
            [ -n "${GAME_SETTINGS_EDIT_OPTIONAL:-}" ] && [ "$cat" != "optional" ] && fix_status[$id]="skip"
        fi
        [[ "${fix_status[$id]}" =~ ^(skip|invalid)$ ]] && continue

        if ! config_row_is_safe "$fmt" "$locs" "$sec" "$key" "$value"; then
            log_cmd "game settings: skipped \"$title\" — its entry for $file/$sec/$key failed the safety check"
            fix_status[$id]="invalid"; continue
        fi

        # Find the file once per run.
        if [ -z "${file_state[$file]+x}" ]; then
            path="$(resolve_config_file "$locs")"
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
                    _game_settings_heading
                    print_note "${GAME_NAME} hasn't created ${file} yet."
                    print_paragraph "If you just installed ${GAME_NAME}, it creates ${file} the first time it runs." \
                        "Please launch the game at least once, close it, and try again."
                    confirm "Check for ${file} again?" || break
                    path="$(resolve_config_file "$locs")"
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

        path="${file_path[$file]}"
        old="$(config_get_key "$path" "$fmt" "$sec" "$key")"
        if [ "$value" == "__FALSE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
        if [ "$value" == "__DELETE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
        config_values_equal "$fmt" "$old" "$value" && continue
        fix_status[$id]="offer"
        [[ "|${fix_files[$id]:-}|" == *"|$file|"* ]] || fix_files[$id]+="${fix_files[$id]:+|}$file"
        fix_rows[$id]+="$cat"$'\x1f'"$title"$'\x1f'"$path"$'\x1f'"$fmt"$'\x1f'"$sec"$'\x1f'"$key"$'\x1f'"$value"$'\x1f'"$file"$'\x1f'"$old"$'\x1f'"${file_state[$file]}"$'\n'
    done

    # Every file this setting changes is one this build doesn't have.
    for id in "${fix_order[@]}"; do
        [ "${fix_status[$id]}" == "already" ] && [ -n "${fix_absent_files[$id]:-}" ] \
            && [ -z "${fix_has_file[$id]:-}" ] && fix_status[$id]="absent"
    done
    # Tools → Optional settings: in place because this script put it there,
    # so it can be turned off again (put back from the manifest).
    if [ -n "${GAME_SETTINGS_EDIT_OPTIONAL:-}" ]; then
        for id in "${fix_order[@]}"; do
            [ "${fix_status[$id]}" == "already" ] && [ -n "${GAME_SETTINGS_RECORDED[${fix_title[$id]}]:-}" ] \
                && fix_status[$id]="applied"
        done
    fi

    local shown=0
    for id in "${fix_order[@]}"; do
        [[ "${fix_status[$id]}" =~ ^(offer|applied|already|missing|absent)$ ]] && shown=1
    done
    [ "$shown" -eq 0 ] && return

    _game_settings_heading

    # Prints one fix: title, reason, and each row's current → new value.
    _print_fix() {
        echo -e "\n  ${BOLD}${fix_title[$1]}${NC}"
        _fix_body "$1"
    }
    # A fix's reason and rows, under its title (or its box in a tick list).
    _fix_body() {
        local id="$1"
        echo -e "${WHITE}$(printf '%s' "${fix_reason[$id]}" | fold -s -w 74 | sed 's/^/    /')${NC}"
        echo ""
        print_config_rows "$(fix_rows_for_display "${fix_rows[$id]}")"
        _print_absent_note "$id"
    }
    # Tools → Optional settings: the body of one this script applied, with
    # each key's original value (from the manifest) → the value it has now.
    _applied_fix_body() {
        local id="$1" line display_rows=""
        local -a c
        echo -e "${WHITE}$(printf '%s' "${fix_reason[$id]}" | fold -s -w 74 | sed 's/^/    /')${NC}"
        echo ""
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            mapfile -t -d $'\t' c < <(printf '%s' "${line#CONFIG:}")
            display_rows+="$(basename "${c[2]}")"$'\x1f'"${c[4]}"$'\x1f'"${c[5]}"$'\x1f'"${c[6]}"$'\x1f'"${c[7]}"$'\n'
        done <<< "${GAME_SETTINGS_RECORDED[${fix_title[$id]}]}"
        print_config_rows "$display_rows"
    }
    # A setting that still applies, minus the part for a file this build
    # doesn't have.
    _print_absent_note() {
        local id="$1"
        [ -n "${fix_absent_files[$id]:-}" ] || return 0
        echo -e "${DIM}    ${GAME_NAME} has no ${fix_absent_files[$id]//|/ or }, so that part is left out.${NC}"
    }
    # Remembers settings the player turned down, for the final summary.
    _decline_fix() {
        GAME_SETTINGS_DECLINED+=("${fix_title[$1]}"$'\x1f'"${fix_files[$1]//|/ and }")
    }
    _plan_fix() {
        local id="$1" r
        while IFS= read -r r; do [ -n "$r" ] && GAME_SETTINGS_PLAN+=("$r"); done <<< "${fix_rows[$id]}"
        [ -n "${fix_follow[$id]}" ] && GAME_SETTINGS_FOLLOW_UPS+=("${fix_title[$id]}"$'\x1f'"${fix_follow[$id]}")
    }
    _print_status_line() {
        local id="$1"
        if [ "${fix_status[$id]}" == "already" ]; then
            echo -e "\n  ${GREEN}✓${NC} ${fix_title[$id]} ${DIM}— already set${NC}"
            _print_absent_note "$id"
        elif [ "${fix_status[$id]}" == "absent" ]; then
            echo -e "\n  ${YELLOW}-${NC} ${fix_title[$id]} ${DIM}— left out: ${GAME_NAME} has no ${fix_absent_files[$id]//|/ or }${NC}"
            GAME_SETTINGS_ABSENT+=("${fix_title[$id]}"$'\x1f'"${fix_absent_files[$id]//|/ or }")
        else
            echo -e "\n  ${YELLOW}-${NC} ${fix_title[$id]} ${DIM}— skipped: ${GAME_NAME} hasn't created ${fix_missing_file[$id]} yet${NC}"
            GAME_SETTINGS_MISSING+=("${fix_title[$id]}"$'\x1f'"${fix_missing_file[$id]}")
        fi
    }

    local any_audio=0 audio_offer=0
    for id in "${fix_order[@]}"; do
        [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing|absent)$ ]] && any_audio=1
        [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] && audio_offer=1
        if [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]]; then
            GAME_AUDIO_FIX_TITLES+=("${fix_title[$id]}")
            [ "${fix_status[$id]}" == "already" ] && GAME_AUDIO_FIX_ALREADY+=("${fix_title[$id]}")
        fi
    done
    if [ "$any_audio" -eq 1 ]; then
        echo -e "\n${WHITE}Audio settings for ${GAME_NAME}:${NC}"
        for id in "${fix_order[@]}"; do
            [[ "$id" == audio:* ]] || continue
            case "${fix_status[$id]}" in
                offer) _print_fix "$id" ;;
                already|missing|absent) _print_status_line "$id" ;;
            esac
        done
        if [ "$audio_offer" -eq 1 ]; then
            local accepted=0
            confirm "Apply these settings?" Y && accepted=1
            for id in "${fix_order[@]}"; do
                [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] || continue
                if [ "$accepted" -eq 1 ]; then _plan_fix "$id"; else _decline_fix "$id"; fi
            done
        fi
    fi

    local -a optional=()
    for id in "${fix_order[@]}"; do
        [[ "$id" == optional:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|applied|already|missing|absent)$ ]] && optional+=("$id")
    done
    if [ ${#optional[@]} -gt 0 ]; then
        echo -e "\n${WHITE}Optional settings for ${GAME_NAME}:${NC}"
        # The ones to choose from go in the tick list, each with its reason
        # and rows under its box; the rest get their status line first.
        local -a offered=() offered_titles=() initial=() bodies=()
        for id in "${optional[@]}"; do
            if [ "${fix_status[$id]}" == "offer" ]; then
                offered+=("$id"); offered_titles+=("${fix_title[$id]}"); initial+=(0)
                bodies+=("$(_fix_body "$id")")
            elif [ "${fix_status[$id]}" == "applied" ]; then
                offered+=("$id"); offered_titles+=("${fix_title[$id]} (Active)"); initial+=(1)
                bodies+=("$(_applied_fix_body "$id")")
            else
                _print_status_line "$id"
            fi
        done
        if [ ${#offered[@]} -gt 0 ]; then
            local example="1" i
            [ ${#offered[@]} -gt 1 ] && example="1 2"
            if [ -n "${GAME_SETTINGS_EDIT_OPTIONAL:-}" ]; then
                # Starts from what's on now; nothing is declined, only changed.
                CHECKLIST_INITIAL=("${initial[@]}"); CHECKLIST_DETAILS=("${bodies[@]}")
                if ! checklist_select "Press Enter to keep these as they are, type the numbers you want on (e.g. \"$example\"), or 'n' for none:" \
                    "${offered_titles[@]}"; then
                    GAME_SETTINGS_CANCELLED=1
                    unset -f _print_fix _fix_body _applied_fix_body _print_absent_note _decline_fix _plan_fix _print_status_line
                    return
                fi
                for i in "${!offered[@]}"; do
                    id="${offered[$i]}"
                    if [ "${fix_status[$id]}" == "offer" ] && [ "${SELECTED[$((i + 1))]}" == "1" ]; then
                        _plan_fix "$id"
                    elif [ "${fix_status[$id]}" == "applied" ] && [ "${SELECTED[$((i + 1))]}" == "0" ]; then
                        GAME_SETTINGS_REVERT_GROUPS+=("optional"$'\x1f'"${fix_title[$id]}"$'\x1f'"${GAME_SETTINGS_RECORDED[${fix_title[$id]}]}")
                    fi
                done
            else
                # Esc applies none of them, like 'n'.
                CHECKLIST_DETAILS=("${bodies[@]}")
                if ! checklist_select "Press Enter to apply all, type the numbers you want (e.g. \"$example\"), or 'n' to skip:" \
                    "${offered_titles[@]}"; then
                    for ((i = 1; i <= ${#offered[@]}; i++)); do SELECTED[i]=0; done
                fi
                for i in "${!offered[@]}"; do
                    if [ "${SELECTED[$((i + 1))]}" == "1" ]; then _plan_fix "${offered[$i]}"; else _decline_fix "${offered[$i]}"; fi
                done
            fi
        fi
    fi
    unset -f _print_fix _fix_body _applied_fix_body _print_absent_note _decline_fix _plan_fix _print_status_line
}

# Usage: profile_field <jq path, e.g. .exe>
# One field of the current game's profile (KG_ID / KG_STORE), or
# nothing.
profile_field() {
    jq -r --arg id "$KG_ID" --arg store "$KG_STORE" \
        "[.games[] | select((.stores[\$store].id // \"\") | tostring == \$id)][0] | $1 // empty" \
        "$GAME_DATABASE_FILE" 2>/dev/null
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
# Before the first wine_reg change of a run: Wine keeps the registry in
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

# Usage: apply_game_settings
# Phase 2: writes GAME_SETTINGS_PLAN into the game's config files and records
# each change in the manifest as
#   CONFIG:<audio|optional>\t<title>\t<path>\t<format>\t<section>\t<key>\t<old>\t<new>
# Each file is backed up once as <file>.eax-restore.bak before its first edit
# ever, and re-read first so a change made since Phase 1 isn't clobbered
# needlessly. On a reinstall, the old value recorded last time is kept (it's
# the player's original), and last run's CONFIG lines for settings still in
# effect are carried over so uninstall can still revert them.
apply_game_settings() {
    local -A recorded=() prev_old=()
    local line cat title path fmt sec key new file old state reg_state=""
    local -a f

    # Last install's original values, by path/section/key.
    for line in "${PREV_CONFIG_LINES[@]}"; do
        mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
        prev_old["${f[2]}"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"]="${f[6]}"
    done

    if [ ${#GAME_SETTINGS_PLAN[@]} -gt 0 ]; then
        print_phase_task "Applying game settings"
        local -A changed_count=() backed_up=()
        for line in "${GAME_SETTINGS_PLAN[@]}"; do
            mapfile -t -d $'\x1f' f < <(printf '%s' "$line")
            cat="${f[0]}"; title="${f[1]}"; path="${f[2]}"; fmt="${f[3]}"; sec="${f[4]}"; key="${f[5]}"
            new="${f[6]}"; file="${f[7]}"; state="${f[9]}"

            # Once, before the registry file is backed up or read.
            if [ "$fmt" == "wine_reg" ]; then
                [ -n "$reg_state" ] || { wine_registry_quiet && reg_state="ok" || reg_state="busy"; }
                [ "$reg_state" == "ok" ] || { record_deploy_failure "$path"; continue; }
            fi

            if [ ! -f "$path" ]; then
                if [ "$state" != "create" ]; then
                    print_warning_arrow "$(basename "$path") has gone missing since the settings were chosen, so \"$title\" wasn't applied."
                    continue
                fi
                if touch "$path" 2>/dev/null; then
                    echo "$path" >> "$INSTALL_MANIFEST"
                    print_status "Created: $(basename "$path")"
                else
                    record_deploy_failure "$path"; continue
                fi
            elif [ -z "${backed_up[$path]:-}" ]; then
                clear_crash_marker "$file" "$path"
                if [ ! -e "$path.eax-restore.bak" ] && [ -z "${PREV_MANIFEST_FILES[$path]:-}" ]; then
                    cp -p "$path" "$path.eax-restore.bak" 2>/dev/null \
                        && print_status "Backed up $(basename "$path") to $(basename "$path").eax-restore.bak"
                fi
                backed_up[$path]=1
            fi

            old="$(config_get_key "$path" "$fmt" "$sec" "$key")"
            config_values_equal "$fmt" "$old" "$new" && continue
            if ! config_set_key "$path" "$fmt" "$sec" "$key" "$new" \
                || ! { [ "$new" == "__DELETE__" ] || config_values_equal "$fmt" "$(config_get_key "$path" "$fmt" "$sec" "$key")" "$new"; }; then
                record_deploy_failure "$path"; continue
            fi
            old="${prev_old["$path"$'\x1f'"$sec"$'\x1f'"$key"]:-$old}"
            printf 'CONFIG:%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cat" "$title" "$path" "$fmt" "$sec" "$key" "$old" "$new" >> "$INSTALL_MANIFEST"
            recorded["$path"$'\x1f'"$sec"$'\x1f'"$key"]=1
            changed_count[$path]=$(( ${changed_count[$path]:-0} + 1 ))
            [[ " ${GAME_SETTINGS_APPLIED[*]-} " == *" $title "* ]] || GAME_SETTINGS_APPLIED+=("$title")
        done
        for path in "${!changed_count[@]}"; do
            local n="${changed_count[$path]}" noun="setting"
            [ "$n" -ne 1 ] && noun="settings"
            print_status "Updated $(basename "$path") ($n $noun)"
        done
    fi

    # Carry over last install's changes that are still in effect.
    for line in "${PREV_CONFIG_LINES[@]}"; do
        mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
        [ -n "${recorded["${f[2]}"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"]:-}" ] && continue
        [ -f "${f[2]}" ] || continue
        config_values_equal "${f[3]}" "$(config_get_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}")" "${f[7]}" \
            && echo "$line" >> "$INSTALL_MANIFEST"
    done
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
    DEPLOY_FAILURES=0
    revert_game_settings
    for entry in "${GAME_SETTINGS_REVERT_GROUPS[@]}"; do
        lines="${entry#*$'\x1f'}"; lines="${lines#*$'\x1f'}"
        while IFS= read -r line; do [ -n "$line" ] && dropped["$line"]=1; done <<< "$lines"
    done
    for line in "${GAME_SETTINGS_KEPT[@]}"; do unset 'dropped[$line]'; done

    declare -gA PREV_MANIFEST_FILES=()
    PREV_CONFIG_LINES=()
    tmp="$(mktemp "$(dirname "$INSTALL_MANIFEST")/.eax-restore-manifest.XXXXXX" 2>/dev/null)" || {
        record_deploy_failure "$INSTALL_MANIFEST"; return 1; }
    while IFS= read -r line; do
        if [[ "$line" == CONFIG:* ]]; then
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
    # One " - " line, wrapped with its continuation lines under the text.
    _summary_skipped() {
        local text first rest
        text="$(printf '%s' "$1" | fold -s -w 74 | sed 's/ *$//')"
        first="${text%%$'\n'*}"; rest=""
        [ "$first" != "$text" ] && rest="$(printf '%s' "${text#*$'\n'}" | sed 's/^/   /')"
        echo -e " ${YELLOW}-${NC} ${WHITE}${first}${NC}"
        [ -n "$rest" ] && echo -e "${WHITE}${rest}${NC}"
        return 0
    }
    echo -e "\n${YELLOW}${BOLD}Game settings:${NC}"
    for title in "${GAME_SETTINGS_APPLIED[@]}"; do
        fu=""
        for entry in "${GAME_SETTINGS_FOLLOW_UPS[@]}"; do
            IFS=$'\x1f' read -r t fu <<< "$entry"
            [ "$t" == "$title" ] && break
            fu=""
        done
        echo -e " ${GREEN}✓${NC} ${WHITE}${title}${NC}"
        # Under the title rather than after it: a follow-up can run to a few
        # sentences, so it's wrapped and indented like a fix's reason.
        [ -n "$fu" ] && echo -e "${WHITE}$(printf '%s' "$fu" | fold -s -w 74 | sed 's/^/    /; s/ *$//')${NC}"
    done
    for entry in "${GAME_SETTINGS_DECLINED[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "${title} wasn't applied, so you'll have to turn it on manually in ${GAME_NAME}'s in-game settings or by editing ${files}."
    done
    for entry in "${GAME_SETTINGS_MISSING[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "${GAME_NAME} hasn't created ${files} yet, so ${title} wasn't applied. You'll have to turn it on manually in the game's in-game settings or by editing ${files}."
    done
    for entry in "${GAME_SETTINGS_ABSENT[@]}"; do
        IFS=$'\x1f' read -r title files <<< "$entry"
        _summary_skipped "${title} — left out: ${GAME_NAME} has no ${files}."
    done
    unset -f _summary_skipped
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
        mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
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
                mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
                display_rows+="$(basename "${f[2]}")"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"$'\x1f'"${f[7]}"$'\x1f'"${f[6]}"$'\n'
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
            mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
            [ -f "${f[2]}" ] || continue
            if [ "${f[3]}" == "wine_reg" ]; then
                [ -n "$reg_state" ] || { wine_registry_quiet && reg_state="ok" || reg_state="busy"; }
                if [ "$reg_state" != "ok" ]; then GAME_SETTINGS_KEPT+=("$line"); continue; fi
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
