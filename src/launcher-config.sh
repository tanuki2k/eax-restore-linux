# ==============================================================================
# DLL OVERRIDE VIA THE LAUNCHER (Steam launch options / Heroic env variables)
# ==============================================================================
# Step 10's "launcher" choice: instead of the Wine prefix registry, the
# WINEDLLOVERRIDES rule goes where a player would put it by hand — Steam's
# per-game launch options (userdata/<account>/config/localconfig.vdf) or
# Heroic's per-game environment variables (GamesConfig/<appName>.json, key
# "enviromentOptions", Heroic's spelling). Both launchers keep these files in
# memory and write them back themselves (Steam on exit, Heroic when a game's
# settings change), so they must be closed while this edits them.
#
# Values travel as plain strings plus two markers: __ABSENT__ (no launch
# options line / no WINEDLLOVERRIDES variable) and __NOAPP__ (the launcher has
# no settings entry for this game at all, e.g. a Steam game never launched).
# Changes are recorded in the manifest as
#   LAUNCHER:<steam|heroic>\t<file>\t<id>\t<old value|__ABSENT__>\t<new value>

# Usage: launcher_running <steam|heroic>
launcher_running() {
    case "$1" in
        steam) pgrep -x steam >/dev/null 2>&1 ;;
        heroic) pgrep -f 'heroic-games-launcher|com\.heroicgameslauncher\.hgl|/heroic/heroic|Heroic[^/]*\.AppImage' >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# Usage: launcher_label <steam|heroic>
launcher_label() { [ "$1" == "steam" ] && echo "Steam" || echo "Heroic"; }

# Usage: merge_dll_override <WINEDLLOVERRIDES value> <dll>
# Adds "<dll>=n,b" to a ;-separated override list, dropping any earlier rule
# for the same DLL (including from grouped "a,b=mode" entries) and leaving
# every other rule as it was.
merge_dll_override() {
    local list="$1" dll="${2,,}" entry names mode name kept out=""
    local -a entries
    IFS=';' read -ra entries <<< "$list"
    for entry in "${entries[@]}"; do
        [ -n "$entry" ] || continue
        if [[ "$entry" == *=* ]]; then names="${entry%%=*}"; mode="=${entry#*=}"; else names="$entry"; mode=""; fi
        kept=""
        IFS=',' read -ra parts <<< "$names"
        for name in "${parts[@]}"; do
            [ -n "$name" ] && [ "${name,,}" != "$dll" ] && kept+="${kept:+,}$name"
        done
        [ -n "$kept" ] && out+="${out:+;}$kept$mode"
    done
    echo "${out:+$out;}$dll=n,b"
}

# Usage: launch_options_with_override <Steam launch options> <dll>
# Returns the launch options with the override added, keeping everything
# else the player had: an existing WINEDLLOVERRIDES is merged into, other
# variables and arguments stay put, and %command% is added if missing.
launch_options_with_override() {
    local opts="$1" dll="$2" re current merged
    re='(^|[[:space:]])WINEDLLOVERRIDES=("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]]*))'
    if [[ "$opts" =~ $re ]]; then
        current="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        merged="$(merge_dll_override "$current" "$dll")"
        echo "${opts/"${BASH_REMATCH[0]}"/${BASH_REMATCH[1]}WINEDLLOVERRIDES=\"$merged\"}"
    elif [[ "$opts" == *%command%* ]]; then
        echo "WINEDLLOVERRIDES=\"$dll=n,b\" $opts"
    elif [ -z "${opts//[[:space:]]/}" ]; then
        echo "WINEDLLOVERRIDES=\"$dll=n,b\" %command%"
    else
        echo "WINEDLLOVERRIDES=\"$dll=n,b\" %command% $opts"
    fi
}

# Usage: steam_localconfig_for_app <appid>
# The localconfig.vdf (across native/Flatpak Steam and every account) that has
# a settings block for the game; if more than one account does, the one
# changed most recently. Prints nothing if none does.
steam_localconfig_for_app() {
    local appid="$1" label root f best="" best_t=0 t
    local -a roots=()
    [ -n "${STEAM_DIR:-}" ] && roots+=("$STEAM_DIR")
    while IFS=$'\t' read -r label root; do roots+=("$root"); done < <(steam_roots)
    for root in "${roots[@]}"; do
        for f in "$root"/userdata/*/config/localconfig.vdf; do
            [ -f "$f" ] || continue
            [ "$(vdf_get_launch_options "$f" "$appid")" == "__NOAPP__" ] && continue
            t="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
            if [ "$t" -gt "$best_t" ] || [ -z "$best" ]; then best="$f"; best_t="$t"; fi
        done
    done
    echo "$best"
}

# Shared awk preamble: tracks the VDF key path so only the game's own block
# under UserLocalConfigStore/Software/Valve/Steam/apps is ever touched (the file
# has other "apps" blocks elsewhere).
_VDF_AWK_PATH='
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function in_app() {
        return depth == 6 && tolower(stack[1]) == "userlocalconfigstore" && tolower(stack[2]) == "software" \
            && tolower(stack[3]) == "valve" && tolower(stack[4]) == "steam" && tolower(stack[5]) == "apps" \
            && stack[6] == appid
    }
'

# Usage: vdf_get_launch_options <localconfig.vdf> <appid>
# Prints the game's LaunchOptions (unescaped), __ABSENT__ if its block has
# none, or __NOAPP__ if there's no block for it. VDF escapes \" and \\ inside
# values; those are undone in bash rather than awk, whose backslash handling
# in gsub differs between gawk and mawk.
vdf_get_launch_options() {
    local raw
    raw="$(vdf_get_raw_launch_options "$@")"
    case "$raw" in
        __ABSENT__|__NOAPP__) echo "$raw"; return ;;
    esac
    raw="${raw//\\\\/$'\001'}"
    raw="${raw//\\\"/\"}"
    printf '%s\n' "${raw//$'\001'/\\}"
}

vdf_get_raw_launch_options() {
    LC_ALL=C awk -v appid="$2" "$_VDF_AWK_PATH"'
        { line = trim($0) }
        line == "{" { depth++; stack[depth] = pending; if (in_app()) seen = 1; next }
        line == "}" { depth--; next }
        line ~ /^"[^"]*"$/ { pending = substr(line, 2, length(line) - 2); next }
        in_app() && tolower(line) ~ /^"launchoptions"[ \t]/ {
            v = trim(substr(line, length("\"LaunchOptions\"") + 1))
            print substr(v, 2, length(v) - 2); found = 1; exit
        }
        END { if (!found) print (seen ? "__ABSENT__" : "__NOAPP__") }
    ' "$1"
}

# Usage: vdf_set_launch_options <localconfig.vdf> <appid> <value|__DELETE__>
# Replaces the game's LaunchOptions line, adds one at the end of its block, or
# (with __DELETE__) removes it. Everything else in the file stays byte for byte.
# The value is passed through the environment, not awk -v, so its backslashes
# reach awk untouched; it's escaped for VDF in bash first.
vdf_set_launch_options() {
    local file="$1" value="$3" tmp
    if [ "$value" != "__DELETE__" ]; then
        value="${value//\\/\\\\}"
        value="${value//\"/\\\"}"
    fi
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-vdf.XXXXXX" 2>/dev/null)" || return 1
    VDF_VALUE="$value" LC_ALL=C awk -v appid="$2" "$_VDF_AWK_PATH"'
        function entry_line(indent) { return indent "\"LaunchOptions\"\t\t\"" ENVIRON["VDF_VALUE"] "\"" }
        BEGIN { del = (ENVIRON["VDF_VALUE"] == "__DELETE__") }
        {
            raw = $0; line = trim($0)
            if (line == "{") { depth++; stack[depth] = pending; print raw; next }
            if (line == "}") {
                if (in_app() && !done && !del) { print entry_line(child_indent); done = 1 }
                depth--; print raw; next
            }
            if (line ~ /^"[^"]*"$/) { pending = substr(line, 2, length(line) - 2) }
            if (in_app()) {
                if (child_indent == "") { match(raw, /^[ \t]*/); child_indent = substr(raw, 1, RLENGTH) }
                if (tolower(line) ~ /^"launchoptions"[ \t]/) {
                    done = 1
                    if (del) next
                    match(raw, /^[ \t]*/); print entry_line(substr(raw, 1, RLENGTH)); next
                }
            }
            print raw
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Usage: heroic_get_override <GamesConfig file> <appName>
# Prints the game's WINEDLLOVERRIDES environment value, __ABSENT__, or
# __NOAPP__ when the file or the game's settings are missing.
heroic_get_override() {
    [ -f "$1" ] || { echo "__NOAPP__"; return; }
    jq -r --arg a "$2" '
        if (type == "object") and has($a) and (.[$a] | type == "object") then
            ([(.[$a].enviromentOptions // [])[] | select(.key == "WINEDLLOVERRIDES") | .value] | first) // "__ABSENT__"
        else "__NOAPP__" end' "$1" 2>/dev/null || echo "__NOAPP__"
}

# Usage: heroic_set_override <GamesConfig file> <appName> <value|__DELETE__>
heroic_set_override() {
    local file="$1" tmp out
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-heroic.XXXXXX" 2>/dev/null)" || return 1
    # Heroic writes its files without a trailing newline; $(...) drops jq's so
    # an untouched round trip stays byte-identical.
    out="$(jq --arg a "$2" --arg v "$3" '
        .[$a].enviromentOptions = ((.[$a].enviromentOptions // [])
            | if $v == "__DELETE__" then map(select(.key != "WINEDLLOVERRIDES"))
              elif any(.[]; .key == "WINEDLLOVERRIDES") then map(if .key == "WINEDLLOVERRIDES" then .value = $v else . end)
              else . + [{ key: "WINEDLLOVERRIDES", value: $v }] end)' "$file" 2>/dev/null)" \
        || { rm -f "$tmp"; return 1; }
    printf '%s' "$out" > "$tmp" || { rm -f "$tmp"; return 1; }
    chmod --reference="$file" "$tmp" 2>/dev/null
    mv -f "$tmp" "$file" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

# Usage: launcher_override_target
# Sets OVERRIDE_LAUNCHER (steam|heroic), OVERRIDE_FILE and OVERRIDE_ID for the
# picked game, and returns 1 when its launcher has no settings for it that
# could hold the override (a plain Wine prefix, or a Steam game never
# launched).
launcher_override_target() {
    OVERRIDE_LAUNCHER=""; OVERRIDE_FILE=""; OVERRIDE_ID=""
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "${APPID:-}" ]; then
        OVERRIDE_LAUNCHER="steam"; OVERRIDE_ID="$APPID"
        OVERRIDE_FILE="$(steam_localconfig_for_app "$APPID")"
    elif [ -n "${HEROIC_GAME_ID:-}" ] && [ -n "${HEROIC_ROOT:-}" ]; then
        OVERRIDE_LAUNCHER="heroic"; OVERRIDE_ID="$HEROIC_GAME_ID"
        OVERRIDE_FILE="$HEROIC_ROOT/GamesConfig/$HEROIC_GAME_ID.json"
        [ "$(heroic_get_override "$OVERRIDE_FILE" "$OVERRIDE_ID")" == "__NOAPP__" ] && OVERRIDE_FILE=""
    fi
    [ -n "$OVERRIDE_FILE" ]
}

# Usage: launcher_override_get / launcher_override_set <value|__DELETE__>
# Read/write the current target (OVERRIDE_LAUNCHER / OVERRIDE_FILE / OVERRIDE_ID).
launcher_override_get() {
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then vdf_get_launch_options "$OVERRIDE_FILE" "$OVERRIDE_ID"
    else heroic_get_override "$OVERRIDE_FILE" "$OVERRIDE_ID"; fi
}
launcher_override_set() {
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then vdf_set_launch_options "$OVERRIDE_FILE" "$OVERRIDE_ID" "$1"
    else heroic_set_override "$OVERRIDE_FILE" "$OVERRIDE_ID" "$1"; fi
}

# Usage: runner_label
# "Proton" for Steam games and Heroic games that run on Proton, else "Wine" —
# what the player knows their game's prefix as.
runner_label() {
    if [ "$LAUNCHER_TYPE" == "1" ] || [ "${HEROIC_RUNNER_TYPE:-}" == "proton" ]; then echo "Proton"; else echo "Wine"; fi
}

# Usage: launcher_override_where
# Where the override goes, for prompts and the summary.
launcher_override_where() {
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then echo "Steam's launch options for $GAME_NAME"
    else echo "Heroic's environment variables for $GAME_NAME"; fi
}

# Usage: wait_for_launcher_closed <steam|heroic> <what to type to give up>
# While the launcher is open, says so and waits for Enter. Returns 1 if the
# player typed something else instead (sets LAUNCHER_WAIT_ANSWER to it).
wait_for_launcher_closed() {
    local label answer
    label="$(launcher_label "$1")"
    LAUNCHER_WAIT_ANSWER=""
    while launcher_running "$1"; do
        echo -e "\n${YELLOW}${label} is open, and it would overwrite the change when it next saves its settings.${NC}"
        prompt "Close ${label}, then press Enter, or $2:"
        read_answer answer || { LAUNCHER_WAIT_ANSWER="eof"; return 1; }
        [ -n "$answer" ] && { LAUNCHER_WAIT_ANSWER="$answer"; return 1; }
    done
    return 0
}

# Usage: apply_launcher_override
# Phase 2 for OVERRIDE_METHOD=launcher: writes the merged override into the
# launcher's settings, reads it back, and records it in the manifest. Any
# reason it can't happen drops back to OVERRIDE_METHOD=manual so the final
# instructions are shown; a failed write also counts as a deploy failure.
apply_launcher_override() {
    [ "$OVERRIDE_METHOD" == "launcher" ] || return 0
    print_phase_task "Setting the DLL override in $(launcher_label "$OVERRIDE_LAUNCHER")"
    if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" "type 's' to set it yourself instead"; then
        print_status "Skipped — the instructions to set it yourself are below." "$YELLOW"
        OVERRIDE_METHOD="manual"; return 0
    fi

    local old new current
    old="$(launcher_override_get)"
    if [ "$old" == "__NOAPP__" ]; then
        print_warning_arrow "$(launcher_label "$OVERRIDE_LAUNCHER") no longer has settings for $GAME_NAME, so the override wasn't added there."
        OVERRIDE_METHOD="manual"; return 0
    fi
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then
        new="$(launch_options_with_override "$( [ "$old" == "__ABSENT__" ] || echo "$old")" "$PRIMARY_DLL_NAME")"
        [ -e "$OVERRIDE_FILE.eax-restore.bak" ] || cp -p "$OVERRIDE_FILE" "$OVERRIDE_FILE.eax-restore.bak" 2>/dev/null
    else
        new="$(merge_dll_override "$( [ "$old" == "__ABSENT__" ] || echo "$old")" "$PRIMARY_DLL_NAME")"
    fi

    if [ "$old" == "$new" ]; then
        print_status "Already set: $(launcher_override_where)"
        return 0
    fi
    if ! launcher_override_set "$new" || [ "$(launcher_override_get)" != "$new" ]; then
        print_error_arrow "Couldn't save the override to $(launcher_override_where), so it isn't set." \
            "The run log has the details."
        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
        OVERRIDE_METHOD="manual"; return 0
    fi
    printf 'LAUNCHER:%s\t%s\t%s\t%s\t%s\n' "$OVERRIDE_LAUNCHER" "$OVERRIDE_FILE" "$OVERRIDE_ID" "$old" "$new" >> "$INSTALL_MANIFEST"
    log_cmd "launcher override: $OVERRIDE_FILE [$OVERRIDE_ID] '$old' -> '$new'"
    print_status "Set: WINEDLLOVERRIDES in $(launcher_override_where)"
}

# Usage: revert_launcher_overrides
# Uninstall: puts each LAUNCHER: manifest line's setting back — but only where
# it still holds what the install set, so the player's own later changes stay.
# Sets LAUNCHER_LINES_KEPT to the lines left in place.
revert_launcher_overrides() {
    LAUNCHER_LINES_KEPT=()
    [ ${#LAUNCHER_LINES[@]} -gt 0 ] || return 0
    local line current
    local -a f
    for line in "${LAUNCHER_LINES[@]}"; do
        mapfile -t -d $'\t' f < <(printf '%s' "${line#LAUNCHER:}")
        OVERRIDE_LAUNCHER="${f[0]}"; OVERRIDE_FILE="${f[1]}"; OVERRIDE_ID="${f[2]}"
        if [ ! -f "$OVERRIDE_FILE" ]; then continue; fi
        if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" "type 's' to leave it as it is"; then
            print_status "Left the DLL override in $(launcher_override_where)." "$YELLOW"
            LAUNCHER_LINES_KEPT+=("$line"); continue
        fi
        current="$(launcher_override_get)"
        if [ "$current" != "${f[4]}" ]; then
            print_status "Kept $(launcher_override_where) as they are — they've been changed since install." "$DIM"
            continue
        fi
        local target="${f[3]}"
        [ "$target" == "__ABSENT__" ] && target="__DELETE__"
        if launcher_override_set "$target"; then
            if [ "$target" == "__DELETE__" ]; then
                print_status "Removed the DLL override from $(launcher_override_where)." "$GREEN"
            else
                print_status "Put $(launcher_override_where) back as they were." "$GREEN"
            fi
        else
            print_warning_arrow "Couldn't update $(launcher_override_where), so the DLL override is still there."
            LAUNCHER_LINES_KEPT+=("$line")
        fi
    done
}

# Usage: choose_override_method
# Step 10's menu. Sets OVERRIDE_METHOD to registry | launcher | manual.
# Steam and Heroic games get 1) launcher (default) / 2) registry / 3) manual; a
# plain Wine prefix gets 1) registry (default) / 2) manual. Choosing the launcher
# when it hasn't saved any settings for the game yet works like the prefix
# step's "not found yet" check: explain, then offer to check again (No goes
# back to the menu). It also waits for the launcher to be closed, since it
# would otherwise overwrite the change.
choose_override_method() {
    OVERRIDE_METHOD=""
    launcher_override_target
    local has_launcher=0 max answer label
    [ -n "$OVERRIDE_LAUNCHER" ] && has_launcher=1
    label="$(launcher_label "$OVERRIDE_LAUNCHER")"

    while [ -z "$OVERRIDE_METHOD" ]; do
        echo ""
        if [ "$has_launcher" -eq 1 ]; then
            print_option 1 "$(launcher_override_where)" "(default)"
            print_option 2 "$(runner_label) prefix registry" "(applies whenever this prefix runs)"
            print_option 3 "I'll do it myself" "(instructions at the end)"
            max=3
        else
            print_option 1 "$(runner_label) prefix registry" "(applies whenever this prefix runs) (default)"
            print_option 2 "I'll do it myself" "(instructions at the end)"
            max=2
        fi
        prompt "Selection [1-${max}, Default: 1]:"
        read_answer answer || answer="$max"
        answer="${answer:-1}"
        case "$has_launcher:$answer" in
            1:1) OVERRIDE_METHOD="launcher" ;;
            1:2|0:1) OVERRIDE_METHOD="registry" ;;
            1:3|0:2) OVERRIDE_METHOD="manual" ;;
        esac
        if [ -z "$OVERRIDE_METHOD" ]; then
            if [ "$has_launcher" -eq 1 ]; then
                print_result "That's not a valid option — please type 1, 2, or 3." "$YELLOW"
            else
                print_result "That's not a valid option — please type 1 or 2." "$YELLOW"
            fi
            continue
        fi
        [ "$OVERRIDE_METHOD" == "launcher" ] || break

        # The launcher has to have saved settings for the game to add to.
        while [ -z "$OVERRIDE_FILE" ]; do
            print_note "${label} has no settings saved for ${GAME_NAME} yet."
            print_paragraph "If you just installed this game, ${label} hasn't created its settings yet." \
                "Please launch the game at least once, close it, and try again."
            if confirm "Check ${label}'s settings for ${GAME_NAME} again?"; then
                launcher_override_target
            else
                OVERRIDE_METHOD=""; break
            fi
        done
        [ "$OVERRIDE_METHOD" == "launcher" ] || continue

        if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" "type 2 or 3 to choose another way"; then
            case "$LAUNCHER_WAIT_ANSWER" in
                2) OVERRIDE_METHOD="registry" ;;
                3|eof) OVERRIDE_METHOD="manual" ;;
                *) OVERRIDE_METHOD="" ;;
            esac
        fi
    done
}
