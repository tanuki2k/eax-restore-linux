# ==============================================================================
# GAME SETTINGS (known-games game_config / install.alsoft_ini)
# ==============================================================================
# Everything the script changes in a game's own config files comes from that
# game's known-games entry (game_config.audio_fixes / extra_fixes) — the script
# itself only knows how to read and edit the four config formats, never which
# game needs what. Decided in Phase 1 (Speaker Configuration offers the
# alsoft.ini values, step 11 offers the game's own settings), applied in
# Phase 2, recorded in the manifest as CONFIG: lines, reverted on uninstall.
#
# Values travel through here as plain strings plus three markers:
#   __TRUE__ / __FALSE__  a dark_cfg flag switched on / off (true/false in JSON)
#   __DELETE__            remove the key (null in JSON)
#   __ABSENT__            (read side only) the key isn't in the file

# Usage: config_get_key <file> <ini|flat_ini|idtech_cfg|dark_cfg> <section> <key>
# Prints the key's current value, __ABSENT__ if it isn't set, or (dark_cfg
# only) __TRUE__ for an active bare flag and __FALSE__ for a flag that's only
# present commented out. Section and key names match case-insensitively, like
# the games themselves read them.
config_get_key() {
    local file="$1" fmt="$2" sec="$3" key="$4"
    [ -f "$file" ] || { echo "__ABSENT__"; return; }
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
        END { if (!found) print ((fmt == "dark_cfg" && commented) ? "__FALSE__" : "__ABSENT__") }
    ' "$file"
}

# Usage: config_set_key <file> <ini|flat_ini|idtech_cfg|dark_cfg> <section> <key> <value>
# Sets (or with __DELETE__ removes) one key, keeping everything else in the
# file as it was — including CRLF line endings, the original spelling of an
# existing key, and "key = value" spacing. A missing ini key goes at the end
# of its section (or a new section at the end of the file); a missing flat_ini
# or cfg key is appended. flat_ini is ini without [sections] — the whole file
# is one section, so its rows carry no section name. For dark_cfg, a commented-out example line is left in place and
# the active line is added right after it. Writes through a temp file in the
# same folder and swaps it in, so a failure never leaves a half-written file.
# Returns 1 if the file couldn't be written.
config_set_key() {
    local file="$1" fmt="$2" sec="$3" key="$4" value="$5"
    local crlf=0 current tmp
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
                else out(val == "__TRUE__" ? key : key " " val)
            }
        }
    ' > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -f "$file" ] && chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Usage: config_values_equal <format> <a> <b>
# ini values compare case-insensitively (Unreal reads "True" and "true" the
# same); everything else must match exactly.
config_values_equal() {
    if [ "$1" == "ini" ]; then [ "${2,,}" == "${3,,}" ]; else [ "$2" == "$3" ]; fi
}

# Usage: config_display_value <value>
config_display_value() {
    case "$1" in
        __ABSENT__) echo "(not set)" ;;
        "") echo "(empty)" ;;
        __TRUE__) echo "on" ;;
        __FALSE__) echo "off" ;;
        __DELETE__) echo "(removed)" ;;
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

# Usage: current_known_game
# Sets KG_ID / KG_STORE to the picked game's store id, and returns 1 when
# there's no known-games entry for it.
current_known_game() {
    KG_ID=""; KG_STORE=""
    if [ "$LAUNCHER_TYPE" == "1" ]; then KG_ID="$APPID"; KG_STORE="steam"
    else KG_ID="${HEROIC_APP_NAME:-}"; KG_STORE="gog"; fi
    [ -n "$KG_ID" ] && ensure_known_games_json || return 1
    jq -e --arg id "$KG_ID" --arg store "$KG_STORE" \
        'any(.games[]; (.stores[$store].id // "") | tostring == $id)' "$KNOWN_GAMES_FILE" >/dev/null 2>&1
}

# Usage: count_game_fixes <id> <steam|gog>
# Prints "<audio> <extras>": fixes this store's build can be offered (only_if
# stores match). Used by the GAME DETAILS line before the game folder is known.
count_game_fixes() {
    jq -r --arg id "$1" --arg store "$2" '
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].game_config // {}
        | def offered: [.[]? | select((.only_if.stores // [$store]) | index($store))] | length;
          "\(.audio_fixes | offered) \(.extra_fixes | offered)"' "$KNOWN_GAMES_FILE" 2>/dev/null
}

# Usage: load_game_config_rows <id> <steam|gog>
# Flattens the entry's fixes into one \x1f-separated row per changed key:
# category, fix number, title, reason, only_if stores (comma list),
# only_if speakers, follow_up, file, format, if_missing, locations
# (|-joined), section ("" for cfg formats), key, value (with the markers
# above). \x1f rather than tabs so empty fields survive `read`.
load_game_config_rows() {
    jq -r --arg id "$1" --arg store "$2" '
        def enc: if type == "boolean" then (if . then "__TRUE__" else "__FALSE__" end)
                 elif . == null then "__DELETE__" else tostring end;
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].game_config // empty
        | (.files // {}) as $files
        | ((.audio_fixes // []) | to_entries[] | {cat: "audio", i: .key, f: .value}),
          ((.extra_fixes // []) | to_entries[] | {cat: "extras", i: .key, f: .value})
        | .cat as $cat | .i as $i | .f as $f
        | $f.changes | to_entries[] | .key as $file | ($files[$file] // {}) as $def
        | (if $def.format == "ini"
             then (.value | to_entries[] | .key as $sec | .value | to_entries[] | [$sec, .key, .value])
             else (.value | to_entries[] | ["", .key, .value]) end) as $kv
        | [$cat, ($i | tostring), $f.title, $f.reason, (($f.only_if.stores // []) | join(",")),
           ($f.only_if.speakers // ""), ($f.follow_up // ""), $file, ($def.format // ""),
           ($def.if_missing // ""), (($def.locations // []) | join("|")), $kv[0], $kv[1], ($kv[2] | enc)]
        | join("\u001f")' "$KNOWN_GAMES_FILE" 2>/dev/null
}

# Usage: config_row_is_safe <format> <locations> <section> <key> <value>
# The schema already enforces all this in CI; this re-checks only what could
# touch the wrong file or corrupt one, in case a bad entry slips through.
config_row_is_safe() {
    local fmt="$1" locations="$2" sec="$3" key="$4" value="$5" loc
    local name_re='^[A-Za-z0-9._ -]+$' value_re='^[A-Za-z0-9._ ()-]*$'
    [[ "$fmt" =~ ^(ini|flat_ini|idtech_cfg|dark_cfg)$ ]] || return 1
    [ -n "$locations" ] || return 1
    IFS='|' read -ra locs <<< "$locations"
    for loc in "${locs[@]}"; do
        [[ "$loc" =~ ^(game|install|prefix_documents|prefix_appdata|prefix_localappdata):[^/\\] ]] || return 1
        [[ "$loc" == *..* || "$loc" == *\\* ]] && return 1
    done
    [[ "$key" =~ $name_re ]] || return 1
    if [ "$fmt" == "ini" ]; then [[ "$sec" =~ $name_re ]] || return 1; fi
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
# file, section, key, old, new.
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
        printf "%s${WHITE}%-${key_len}s${NC}  %s → ${GREEN}%s${NC}\n" "$indent" "$key" "$(config_display_value "$old")" "$(config_display_value "$new")"
        prev_file="$file"; prev_sec="$sec"
    done <<< "$1"
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

# Usage: offer_alsoft_settings
# Speaker Configuration's last question: the known-games entry's
# install.alsoft_ini values, each stated as a fact about the game plus a
# default-yes offer. Accepted ones land in ALSOFT_OVERRIDES
# ("section\x1fkey\x1fvalue") for Phase 2 to write into the generated
# alsoft.ini.
offer_alsoft_settings() {
    ALSOFT_OVERRIDES=()
    current_known_game || return
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
        "$KNOWN_GAMES_FILE" 2>/dev/null)
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
# Accepted rows go into GAME_SETTINGS_PLAN, fixes whose file doesn't exist
# yet into GAME_SETTINGS_MISSING, both for Phase 2 and the final summary.
# Prints nothing at all for a game with no fixes to offer.
game_settings_step() {
    local step="$1"
    GAME_SETTINGS_PLAN=(); GAME_SETTINGS_MISSING=(); GAME_SETTINGS_FOLLOW_UPS=()
    GAME_AUDIO_FIX_TITLES=(); GAME_AUDIO_FIX_ALREADY=()
    current_known_game || return

    local -a rows=()
    local row
    while IFS= read -r row; do [ -n "$row" ] && rows+=("$row"); done < <(load_game_config_rows "$KG_ID" "$KG_STORE")
    [ ${#rows[@]} -eq 0 ] && return

    # Per-fix state, keyed "category:number" in database order.
    local -a fix_order=()
    local -A fix_title=() fix_reason=() fix_follow=() fix_status=() fix_rows=() fix_missing_file=()
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
            if [ -n "$speakers" ] && [ "$speakers" != "$OUTPUT_MODE" ]; then fix_status[$id]="skip"; fi
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
            skip) fix_status[$id]="skip"; continue ;;
            missing) fix_status[$id]="missing"; fix_missing_file[$id]="$file"; continue ;;
        esac
        [ "${fix_status[$id]}" == "missing" ] && continue

        path="${file_path[$file]}"
        old="$(config_get_key "$path" "$fmt" "$sec" "$key")"
        if [ "$value" == "__FALSE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
        if [ "$value" == "__DELETE__" ] && [ "$old" == "__ABSENT__" ]; then continue; fi
        config_values_equal "$fmt" "$old" "$value" && continue
        fix_status[$id]="offer"
        fix_rows[$id]+="$cat"$'\x1f'"$title"$'\x1f'"$path"$'\x1f'"$fmt"$'\x1f'"$sec"$'\x1f'"$key"$'\x1f'"$value"$'\x1f'"$file"$'\x1f'"$old"$'\x1f'"${file_state[$file]}"$'\n'
    done

    local shown=0
    for id in "${fix_order[@]}"; do
        [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]] && shown=1
    done
    [ "$shown" -eq 0 ] && return

    print_step "$step" "Game Settings"

    # Prints one fix: title, reason, and each row's current → new value.
    _print_fix() {
        local id="$1"
        echo -e "\n  ${BOLD}${fix_title[$id]}${NC}"
        echo -e "${WHITE}$(printf '%s' "${fix_reason[$id]}" | fold -s -w 74 | sed 's/^/    /')${NC}"
        echo ""
        print_config_rows "$(fix_rows_for_display "${fix_rows[$id]}")"
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
        else
            echo -e "\n  ${YELLOW}-${NC} ${fix_title[$id]} ${DIM}— skipped: ${GAME_NAME} hasn't created ${fix_missing_file[$id]} yet${NC}"
            GAME_SETTINGS_MISSING+=("${fix_title[$id]}"$'\x1f'"${fix_missing_file[$id]}")
        fi
    }

    local any_audio=0 audio_offer=0
    for id in "${fix_order[@]}"; do
        [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]] && any_audio=1
        [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] && audio_offer=1
        if [[ "$id" == audio:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]]; then
            GAME_AUDIO_FIX_TITLES+=("${fix_title[$id]}")
            [ "${fix_status[$id]}" == "already" ] && GAME_AUDIO_FIX_ALREADY+=("${fix_title[$id]}")
        fi
    done
    if [ "$any_audio" -eq 1 ]; then
        echo -e "\n${WHITE}Recommended audio settings for ${GAME_NAME}:${NC}"
        for id in "${fix_order[@]}"; do
            [[ "$id" == audio:* ]] || continue
            case "${fix_status[$id]}" in
                offer) _print_fix "$id" ;;
                already|missing) _print_status_line "$id" ;;
            esac
        done
        if [ "$audio_offer" -eq 1 ] && confirm "Apply these settings?" Y; then
            for id in "${fix_order[@]}"; do
                [[ "$id" == audio:* ]] && [ "${fix_status[$id]}" == "offer" ] && _plan_fix "$id"
            done
        fi
    fi

    local -a extras=()
    for id in "${fix_order[@]}"; do
        [[ "$id" == extras:* ]] && [[ "${fix_status[$id]}" =~ ^(offer|already|missing)$ ]] && extras+=("$id")
    done
    if [ ${#extras[@]} -gt 0 ]; then
        echo -e "\n${WHITE}Optional fixes for ${GAME_NAME} — not needed for EAX:${NC}"
        local -a offered=()
        for id in "${extras[@]}"; do
            if [ "${fix_status[$id]}" == "offer" ]; then
                offered+=("$id")
                echo ""
                print_option "${#offered[@]}" "${fix_title[$id]}"
                echo -e "${WHITE}$(printf '%s' "${fix_reason[$id]}" | fold -s -w 74 | sed 's/^/    /')${NC}"
                echo ""
                print_config_rows "$(fix_rows_for_display "${fix_rows[$id]}")"
            else
                _print_status_line "$id"
            fi
        done
        if [ ${#offered[@]} -gt 0 ]; then
            local example="1"
            [ ${#offered[@]} -gt 1 ] && example="1 2"
            prompt "Press Enter to apply all, type the numbers you want (e.g. \"$example\"), or 'n' to skip:"
            local answer i
            read_answer answer || answer="n"
            if [[ ! "$answer" =~ $NO_RE ]]; then
                parse_selection "${#offered[@]}" "$answer"
                for i in "${!offered[@]}"; do
                    [ "${SELECTED[$((i + 1))]}" == "1" ] && _plan_fix "${offered[$i]}"
                done
            fi
        fi
    fi
    unset -f _print_fix _plan_fix _print_status_line
}

# Usage: known_game_field <jq path, e.g. .exe>
# One field of the current game's known-games entry (KG_ID / KG_STORE), or
# nothing.
known_game_field() {
    jq -r --arg id "$KG_ID" --arg store "$KG_STORE" \
        "[.games[] | select((.stores[\$store].id // \"\") | tostring == \$id)][0] | $1 // empty" \
        "$KNOWN_GAMES_FILE" 2>/dev/null
}

# Usage: game_exe_running
# True while the game's own exe (the entry's "exe") is running. Wine and
# Proton keep the Windows path in the command line, so the name is matched
# there, ignoring case as Windows does. This script's own process tree is
# left out: a shell whose command line merely mentions the exe isn't the game.
game_exe_running() {
    local exe pid p
    local -A ours=()
    exe="$(known_game_field .exe)"
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
    marker="$(known_game_field ".game_config.files[\"$1\"].crash_marker")"
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

# Usage: apply_game_settings
# Phase 2: writes GAME_SETTINGS_PLAN into the game's config files and records
# each change in the manifest as
#   CONFIG:<audio|extras>\t<title>\t<path>\t<format>\t<section>\t<key>\t<old>\t<new>
# Each file is backed up once as <file>.eax-restore.bak before its first edit
# ever, and re-read first so a change made since Phase 1 isn't clobbered
# needlessly. On a reinstall, the old value recorded last time is kept (it's
# the player's original), and last run's CONFIG lines for settings still in
# effect are carried over so uninstall can still revert them.
apply_game_settings() {
    local -A recorded=() prev_old=()
    local line cat title path fmt sec key new file old state
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

# Usage: game_audio_fixes_done
# True when the game has audio fixes and every one of them is now in place
# (applied this run or already set), so EAX needs nothing more from the
# player in the game's own menus. A declined fix, or one whose config file
# doesn't exist yet, leaves it false.
game_audio_fixes_done() {
    [ ${#GAME_AUDIO_FIX_TITLES[@]} -gt 0 ] || return 1
    local t
    for t in "${GAME_AUDIO_FIX_TITLES[@]}"; do
        [[ " ${GAME_SETTINGS_APPLIED[*]-} ${GAME_AUDIO_FIX_ALREADY[*]-} " == *" $t "* ]] || return 1
    done
}

# Usage: print_game_settings_summary
# INSTALLATION COMPLETE's "Game settings" section: fixes applied (with any
# follow-up the player still has to do) and fixes skipped because the game
# hasn't created its config file yet.
print_game_settings_summary() {
    [ ${#GAME_SETTINGS_APPLIED[@]} -gt 0 ] || [ ${#GAME_SETTINGS_MISSING[@]} -gt 0 ] || return
    local title entry fu t
    echo -e "${YELLOW}${BOLD}Game settings:${NC}"
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
    for entry in "${GAME_SETTINGS_MISSING[@]}"; do
        IFS=$'\x1f' read -r title fu <<< "$entry"
        echo -e " ${YELLOW}-${NC} ${WHITE}${title}${NC} — launch ${GAME_NAME} once, then run this again."
    done
    echo ""
}

# Usage: revert_game_settings <step_number>
# Uninstall's Game Settings step. Lists the manifest's CONFIG lines as
# audio / optional fixes and puts back each chosen setting's original value —
# but only where the setting still has the value this script set, so anything
# the player changed since is left alone. Sets GAME_SETTINGS_KEPT to the
# CONFIG lines left in place, so the manifest can keep them.
revert_game_settings() {
    local step="$1"
    GAME_SETTINGS_KEPT=()
    [ ${#CONFIG_LINES[@]} -gt 0 ] || return

    print_step "$step" "Game Settings"

    # Group lines by fix (category + title), keeping manifest order.
    local -a groups=()
    local -A group_lines=()
    local line g
    local -a f
    for line in "${CONFIG_LINES[@]}"; do
        mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
        g="${f[0]}"$'\x1f'"${f[1]}"
        [ -n "${group_lines[$g]+x}" ] || groups+=("$g")
        group_lines[$g]+="$line"$'\n'
    done

    local -a order=()
    local cat idx=1 label
    for cat in audio extras; do
        local header_shown=0
        for g in "${groups[@]}"; do
            [[ "$g" == "$cat"$'\x1f'* ]] || continue
            if [ "$header_shown" -eq 0 ]; then
                [ "$cat" == "audio" ] && label="Audio settings" || label="Optional fixes"
                echo -e "\n${WHITE}${label}:${NC}"
                header_shown=1
            fi
            order+=("$g")
            print_option "$idx" "${g#*$'\x1f'}"
            local display_rows=""
            while IFS= read -r line; do
                [ -n "$line" ] || continue
                mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
                display_rows+="$(basename "${f[2]}")"$'\x1f'"${f[4]}"$'\x1f'"${f[5]}"$'\x1f'"${f[7]}"$'\x1f'"${f[6]}"$'\n'
            done <<< "${group_lines[$g]}"
            print_config_rows "$display_rows"
            idx=$((idx + 1))
        done
    done

    prompt "Press Enter to put all of these back, type the numbers you want (e.g. \"1\"), or 'n' to keep them:"
    local answer i
    read_answer answer || answer="n"
    if [[ "$answer" =~ $NO_RE ]]; then
        GAME_SETTINGS_KEPT=("${CONFIG_LINES[@]}")
        return
    fi
    parse_selection "${#order[@]}" "$answer"

    echo ""
    local current restored
    for i in "${!order[@]}"; do
        g="${order[$i]}"
        if [ "${SELECTED[$((i + 1))]}" != "1" ]; then
            while IFS= read -r line; do [ -n "$line" ] && GAME_SETTINGS_KEPT+=("$line"); done <<< "${group_lines[$g]}"
            continue
        fi
        restored=0
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            mapfile -t -d $'\t' f < <(printf '%s' "${line#CONFIG:}")
            [ -f "${f[2]}" ] || continue
            current="$(config_get_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}")"
            if ! config_values_equal "${f[3]}" "$current" "${f[7]}"; then
                print_status "Kept ${f[5]} in $(basename "${f[2]}") — it's been changed since install." "$DIM"
                continue
            fi
            local target="${f[6]}"
            [ "$target" == "__ABSENT__" ] && target="__DELETE__"
            if config_set_key "${f[2]}" "${f[3]}" "${f[4]}" "${f[5]}" "$target"; then
                restored=$((restored + 1))
            else
                print_error_arrow "Couldn't write $(basename "${f[2]}"), so ${f[5]} wasn't put back."
                GAME_SETTINGS_KEPT+=("$line")
            fi
        done <<< "${group_lines[$g]}"
        [ "$restored" -gt 0 ] && print_status "Put back: ${g#*$'\x1f'}"
    done
}
