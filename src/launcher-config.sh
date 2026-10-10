# ==============================================================================
# DLL OVERRIDE VIA THE LAUNCHER (Steam launch options / Heroic env variables)
# ==============================================================================
# Step 10's "launcher" choice: instead of the Wine prefix registry, the
# WINEDLLOVERRIDES rule goes where a player would put it by hand — Steam's
# per-game launch options (userdata/<account>/config/localconfig.vdf) or
# Heroic's per-game environment variables (GamesConfig/<appName>.json, key
# "enviromentOptions", Heroic's spelling). Both launchers keep these files in
# memory and write them back themselves (Steam on exit, Heroic when a game's
# settings change), so they must be closed while this edits them: the script
# offers to close the one that owns the file (native or Flatpak) and reopen it
# afterwards, or waits for the player to close it.
#
# Values travel as plain strings plus two markers: __ABSENT__ (no launch
# options line / no WINEDLLOVERRIDES variable) and __NOAPP__ (the launcher has
# no settings entry for this game at all, e.g. a Steam game never launched).
# Changes are recorded in the manifest as
#   LAUNCHER:<steam|heroic>\t<file>\t<id>\t<old value|__ABSENT__>\t<new value>

HEROIC_PROC_RE='heroic-games-launcher|com\.heroicgameslauncher\.hgl|/heroic/heroic|Heroic[^/]*\.AppImage'

# Usage: launcher_flatpak_id <steam|heroic>
launcher_flatpak_id() { [ "$1" == "steam" ] && echo "com.valvesoftware.Steam" || echo "com.heroicgameslauncher.hgl"; }

# Usage: launcher_kind <steam|heroic>
# "flatpak" when the settings file being edited (OVERRIDE_FILE) belongs to the
# Flatpak copy, "native" when it belongs to a native or AppImage one, "" when
# there's no file yet. Decided by the file rather than by what's running, so a
# player with both copies only ever has the one that owns it closed.
launcher_kind() {
    [ -n "${OVERRIDE_FILE:-}" ] || return 0
    case "$OVERRIDE_FILE" in
        "$HOME/.var/app/$(launcher_flatpak_id "$1")/"*) echo "flatpak" ;;
        *) echo "native" ;;
    esac
}

# Usage: launcher_native_pids <steam|heroic>
# The launcher's processes outside any Flatpak sandbox: a sandboxed Steam is
# also a process called "steam", so a plain pgrep can't tell the two apart,
# but its cgroup can (app-flatpak-<id>-N.scope).
launcher_native_pids() {
    local pid
    while read -r pid; do
        grep -q 'app-flatpak-' "/proc/$pid/cgroup" 2>/dev/null || echo "$pid"
    done < <(if [ "$1" == "steam" ]; then pgrep -x steam; else pgrep -f "$HEROIC_PROC_RE"; fi 2>/dev/null)
}

# Usage: launcher_running <steam|heroic>
launcher_running() {
    case "$1:$(launcher_kind "$1")" in
        *:flatpak) flatpak ps --columns=application 2>/dev/null | grep -qx "$(launcher_flatpak_id "$1")" ;;
        *:native) [ -n "$(launcher_native_pids "$1")" ] ;;
        steam:) pgrep -x steam >/dev/null 2>&1 ;;
        heroic:) pgrep -f "$HEROIC_PROC_RE" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

# Usage: launcher_label <steam|heroic>
launcher_label() { [ "$1" == "steam" ] && echo "Steam" || echo "Heroic"; }

# Usage: launcher_launch_cmd <steam|heroic>
# How to start the launcher again the way it's running now, as \x1f-separated
# words: "flatpak run <id>", the AppImage it was started from, or the command
# on PATH. Prints nothing when there's no way to tell, and then the script
# doesn't offer to close it.
launcher_launch_cmd() {
    local pid appimage=""
    if [ "$(launcher_kind "$1")" == "flatpak" ]; then
        command -v flatpak >/dev/null 2>&1 && printf 'flatpak\x1frun\x1f%s' "$(launcher_flatpak_id "$1")"
        return 0
    fi
    for pid in $(launcher_native_pids "$1"); do
        appimage="$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^APPIMAGE=//p' | head -n 1)"
        [ -n "$appimage" ] && break
    done
    if [ -n "$appimage" ] && [ -x "$appimage" ]; then printf '%s' "$appimage"
    elif command -v "$1" >/dev/null 2>&1; then printf '%s' "$1"
    fi
}

# Usage: launcher_game_running <steam|heroic>
# True while a game started from the launcher is still running, since closing
# the launcher would quit it. Steam starts every game through its "reaper
# SteamLaunch" process; Heroic's games run as Wine/Proton children of it.
launcher_game_running() {
    if [ "$1" == "steam" ]; then
        pgrep -f 'reaper SteamLaunch' >/dev/null 2>&1
        return
    fi
    local roots
    roots="$(pgrep -f "$HEROIC_PROC_RE" 2>/dev/null | tr '\n' ' ')"
    [ -n "$roots" ] || return 1
    # This script's own processes are left out: a command line that happens
    # to mention Heroic, or this check's own pattern, isn't a game.
    ps -eo pid=,ppid=,args= 2>/dev/null | awk -v roots="$roots" -v self="$$" '
        function ours(x) { for (; x > 1; x = ppid[x]) if (x == self) return 1; return 0 }
        { p = $1; ppid[p] = $2; $1 = ""; $2 = ""; args[p] = $0 }
        END {
            n = split(roots, r, " "); for (i = 1; i <= n; i++) if (!ours(r[i])) heroic[r[i]] = 1
            for (p in args) {
                if (ours(p)) continue
                if (args[p] !~ /wine|proton|\.exe/) continue
                for (a = ppid[p]; a > 1; a = ppid[a]) if (a in heroic) { found = 1; break }
                if (found) break
            }
            exit !found
        }'
}

# Usage: _close_launcher_and_wait <steam|heroic> <seconds>
# Asks the launcher to quit, then waits for it to be gone. Runs behind
# run_with_spinner. Steam's own -shutdown hands the request to the running
# Steam, which saves and exits; Heroic has no such switch, but it saves a
# game's settings the moment they change, so stopping it loses nothing.
_close_launcher_and_wait() {
    local kind waited=0 pid
    kind="$(launcher_kind "$1")"
    case "$1:$kind" in
        steam:flatpak) timeout 20 flatpak run com.valvesoftware.Steam -shutdown & ;;
        steam:*) timeout 20 steam -shutdown & ;;
        heroic:flatpak) flatpak kill com.heroicgameslauncher.hgl ;;
        heroic:*)
            for pid in $(launcher_native_pids heroic); do
                tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- '--type=' || kill -TERM "$pid" 2>/dev/null
            done ;;
    esac
    while launcher_running "$1"; do
        [ "$waited" -ge "$2" ] && return 1
        sleep 1; waited=$(( waited + 1 ))
    done
}

# What the launcher-closing messages say is being changed: the DLL override
# (install and uninstall), or "dsoal_log" for the DSOAL logging utility.
LAUNCHER_CHANGE=""

# Usage: launcher_change_text <add|remove> <short|where>
# The change, for the launcher-closing messages: "add the override" (short,
# for the question) or "add the DLL override to" (where, followed by
# launcher_override_where), or the DSOAL logging equivalents.
launcher_change_text() {
    if [ "$LAUNCHER_CHANGE" == "dsoal_log" ]; then
        local onoff="on"; [ "$1" == "remove" ] && onoff="off"
        if [ "$2" == "where" ]; then echo "turn ${onoff} DSOAL logging in"; else echo "turn DSOAL logging ${onoff}"; fi
    elif [ "$2" == "where" ]; then
        if [ "$1" == "remove" ]; then echo "remove the DLL override from"; else echo "add the DLL override to"; fi
    else
        echo "$1 the override"
    fi
}

# Usage: print_launcher_open <steam|heroic> <add|remove>
# The problem and what it's holding up: the launcher is running, so the
# change can't be made yet. Wrapped at the script's 76 columns, since the
# game name's length varies.
print_launcher_open() {
    local label text
    label="$(launcher_label "$1")"
    text="${label} is running, so the script can't $(launcher_change_text "$2" where) $(launcher_override_where)."
    echo -e "\n${YELLOW}$(printf '%s' "$text" | fold -s -w 76 | sed 's/ $//')${NC}"
}

# Usage: offer_close_launcher <steam|heroic> <add|remove>
# When the launcher can safely be closed and started again, offers to do it.
# Returns 0 once it's closed (and queues it in LAUNCHERS_TO_REOPEN), 1 if the
# player has to close it themselves. Sets LAUNCHER_CLOSE_ASKED to 1 when it
# showed the "is open" message and asked, and LAUNCHER_CLOSE_DECLINED to 1
# when the player said No, which means skip the override rather than close it
# themselves. When uninstall's Phase 1 already had the player choose to
# remove the override (LAUNCHER_CLOSE_ANSWER y), it closes without asking.
offer_close_launcher() {
    local label cmd
    LAUNCHER_CLOSE_ASKED=0; LAUNCHER_CLOSE_DECLINED=0
    label="$(launcher_label "$1")"
    if launcher_game_running "$1"; then
        print_note "A game is running from ${label}, so the script can't close ${label} for you."
        return 1
    fi
    cmd="$(launcher_launch_cmd "$1")"
    [ -n "$cmd" ] || return 1
    case "${LAUNCHER_CLOSE_ANSWER[$1]:-}" in
        y) ;;
        *)
            print_launcher_open "$1" "$2"
            LAUNCHER_CLOSE_ASKED=1
            confirm_countdown "Close ${label}, $(launcher_change_text "$2" short), then reopen ${label}?" Y 25 || { LAUNCHER_CLOSE_DECLINED=1; return 1; }
            [ "$CONFIRM_TIMED_OUT" -eq 1 ] && print_status "No answer after 25 seconds, so closing ${label}." ;;
    esac
    if run_with_spinner "Waiting for ${label} to close..." "$EAX_LOG_FILE" _close_launcher_and_wait "$1" 30; then
        log_cmd "closed $1 ($(launcher_kind "$1")); will reopen with: ${cmd//$'\x1f'/ }"
        LAUNCHERS_TO_REOPEN+=("${label}"$'\x1f'"${cmd}")
        print_status "Closed ${label}."
        return 0
    fi
    print_warning_arrow "${label} didn't close in time."
    return 1
}

# Usage: reopen_launchers
# Starts every launcher offer_close_launcher closed, detached from this
# terminal so it keeps running after the script ends.
LAUNCHERS_TO_REOPEN=()
reopen_launchers() {
    local entry label
    local -a cmd
    for entry in "${LAUNCHERS_TO_REOPEN[@]}"; do
        label="${entry%%$'\x1f'*}"
        IFS=$'\x1f' read -r -a cmd <<< "${entry#*$'\x1f'}"
        if setsid -f "${cmd[@]}" >/dev/null 2>&1 </dev/null; then
            print_status "Reopened ${label}." "$GREEN"
        else
            print_warning_arrow "Couldn't reopen ${label}, so you'll need to start it yourself."
        fi
    done
    LAUNCHERS_TO_REOPEN=()
}

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

# Usage: launch_options_without_dsoal_log <Steam launch options>
# The launch options with any DSOAL_LOGLEVEL=… / DSOAL_LOGFILE=… removed
# (bare, "…" or '…' values), everything else left as it was.
launch_options_without_dsoal_log() {
    local opts="$1" re
    re='(^|[[:space:]]+)DSOAL_LOG(LEVEL|FILE)=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]*)'
    while [[ "$opts" =~ $re ]]; do
        opts="${opts/"${BASH_REMATCH[0]}"/}"
    done
    echo "${opts#"${opts%%[![:space:]]*}"}"
}

# Usage: launch_options_with_dsoal_log <Steam launch options> <level> <log file>
# Returns the launch options with DSOAL's logging variables placed right
# before %command% (replacing any already there), adding %command% the same
# way launch_options_with_override does when it's missing.
launch_options_with_dsoal_log() {
    local opts vars
    opts="$(launch_options_without_dsoal_log "$1")"
    vars="DSOAL_LOGLEVEL=$2 DSOAL_LOGFILE=\"$3\""
    if [[ "$opts" == *%command%* ]]; then
        echo "${opts/\%command\%/$vars %command%}"
    elif [ -z "${opts//[[:space:]]/}" ]; then
        echo "$vars %command%"
    else
        echo "$vars %command% $opts"
    fi
}

# Usage: dsoal_log_path_for_wine <folder>
# The Windows path DSOAL_LOGFILE needs for dsoal.log in <folder>: Wine maps
# Z: to /, and accepts forward slashes. Absolute, so the log lands in that
# folder whichever directory the launcher starts the game in.
dsoal_log_path_for_wine() { echo "Z:$1/dsoal.log"; }

# Usage: dsoal_log_path_for_linux <DSOAL_LOGFILE value>
# Where a DSOAL_LOGFILE value points on this machine: a Z: path maps back to
# /, and a bare name (as typed by hand) sits in the game folder, the folder
# Steam starts the game in.
dsoal_log_path_for_linux() {
    local p="${1//\\//}"
    case "$p" in
        [Zz]:/*) echo "${p:2}" ;;
        [A-Za-z]:*) echo "$p" ;;
        *) echo "$GAME_DIR/$p" ;;
    esac
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
    swap_in "$tmp" "$file"
}

# Usage: heroic_get_env <GamesConfig file> <appName> <variable>
# Prints the game's value for an environment variable, __ABSENT__, or
# __NOAPP__ when the file or the game's settings are missing.
heroic_get_env() {
    [ -f "$1" ] || { echo "__NOAPP__"; return; }
    jq -r --arg a "$2" --arg k "$3" '
        if (type == "object") and has($a) and (.[$a] | type == "object") then
            ([(.[$a].enviromentOptions // [])[] | select(.key == $k) | .value] | first) // "__ABSENT__"
        else "__NOAPP__" end' "$1" 2>/dev/null || echo "__NOAPP__"
}

# Usage: heroic_set_env <GamesConfig file> <appName> <variable> <value|__DELETE__>
heroic_set_env() {
    local file="$1" tmp out
    tmp="$(mktemp "$(dirname "$file")/.eax-restore-heroic.XXXXXX" 2>/dev/null)" || return 1
    # Heroic writes its files without a trailing newline; $(...) drops jq's so
    # an untouched round trip stays byte-identical.
    out="$(jq --arg a "$2" --arg k "$3" --arg v "$4" '
        .[$a].enviromentOptions = ((.[$a].enviromentOptions // [])
            | if $v == "__DELETE__" then map(select(.key != $k))
              elif any(.[]; .key == $k) then map(if .key == $k then .value = $v else . end)
              else . + [{ key: $k, value: $v }] end)' "$file" 2>/dev/null)" \
        || { rm -f "$tmp"; return 1; }
    printf '%s' "$out" > "$tmp" || { rm -f "$tmp"; return 1; }
    swap_in "$tmp" "$file"
}

# Usage: heroic_get_override <GamesConfig file> <appName>
# Usage: heroic_set_override <GamesConfig file> <appName> <value|__DELETE__>
# The game's WINEDLLOVERRIDES variable.
heroic_get_override() { heroic_get_env "$1" "$2" WINEDLLOVERRIDES; }
heroic_set_override() { heroic_set_env "$1" "$2" WINEDLLOVERRIDES "$3"; }

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
    # A companion app's line (another AppID than the game's) names the companion.
    if [ "$OVERRIDE_LAUNCHER" == "steam" ] && [ -n "${OVERRIDE_ID:-}" ] && [ "$OVERRIDE_ID" != "${APPID:-}" ]; then
        echo "Steam's launch options for $(companion_name_for_id "$OVERRIDE_ID")"
    elif [ "$OVERRIDE_LAUNCHER" == "steam" ]; then echo "Steam's launch options for $GAME_NAME"
    else echo "Heroic's environment variables for $GAME_NAME"; fi
}

# Usage: wait_for_launcher_closed <steam|heroic> <add|remove> <what to type to give up>
# While the launcher is open, first offers to close it (and reopen it later) —
# one question, where No skips the override. Only when the script can't close
# it (a game is running from it, or it didn't close in time) does it say so and
# wait for the player to close it, carrying on by itself once it's gone (piped
# input still presses Enter). Returns 1 if the player skipped.
wait_for_launcher_closed() {
    local label answer asked key rest rc
    label="$(launcher_label "$1")"
    launcher_running "$1" || return 0
    offer_close_launcher "$1" "$2" && return 0
    [ "$LAUNCHER_CLOSE_DECLINED" -eq 1 ] && return 1
    # The offer already said it's open whenever it got as far as asking.
    asked="$LAUNCHER_CLOSE_ASKED"
    if interactive_tty; then
        [ "$asked" -eq 1 ] || print_launcher_open "$1" "$2"
        prompt "Close ${label} and the script will carry on by itself, or $3:"
        # Checked once a second. No timeout: the script couldn't close it
        # because a game is running from it, so waiting is all it can do.
        # Enter just checks again; anything else typed skips, as before.
        while launcher_running "$1"; do
            printf '\r\033[K> %b(waiting for %s to close…)%b' "$DIM" "$label" "$NC"
            read -r -s -n 1 -t 1 key; rc=$?
            [ "$rc" -gt 128 ] && continue
            [ "$rc" -eq 0 ] || { printf '\r\033[K> \n'; return 1; }
            [ -n "$key" ] || continue
            printf '\r\033[K> %s' "$key"
            read -r rest || rest=""
            _log_answer "$rest" 0
            return 1
        done
        printf '\r\033[K> \n'
        print_status "${label} is closed."
        return 0
    fi
    while launcher_running "$1"; do
        [ "$asked" -eq 1 ] || print_launcher_open "$1" "$2"
        asked=0
        prompt "Close ${label}, then press Enter, or $3:"
        read_answer answer || return 1
        [ -n "$answer" ] && return 1
    done
    return 0
}

# Usage: apply_launcher_override
# Phase 2 for OVERRIDE_METHOD=launcher: writes the merged override into the
# launcher's settings, reads it back, and records it in the manifest. Any
# reason it can't happen drops back to OVERRIDE_METHOD=manual so the final
# instructions are shown; a failed write also counts as a deploy failure.
# A launcher the script closed for this is reopened whichever way it ends.
apply_launcher_override() {
    [ "$OVERRIDE_METHOD" == "launcher" ] || return 0
    _apply_launcher_override
    reopen_launchers
}
_apply_launcher_override() {
    print_phase_task "Setting the DLL override in $(launcher_label "$OVERRIDE_LAUNCHER")"
    if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" add "type 's' to set it yourself instead"; then
        print_status "Skipped — the instructions to set it yourself are below." "$YELLOW"
        OVERRIDE_METHOD="manual"
        local i
        for i in "${!COMPANION_IDS[@]}"; do
            [ "${COMPANION_OVERRIDE[$i]:-}" == "launcher" ] && COMPANION_OVERRIDE[i]="manual"
        done
        return 0
    fi
    _write_launcher_override || OVERRIDE_METHOD="manual"
    apply_companion_launcher_overrides
}

# Usage: _write_launcher_override
# Writes the override into the current target (OVERRIDE_LAUNCHER / _FILE /
# _ID), reads it back and records it in the manifest. Returns 1 when it
# couldn't be set (the caller drops that app to manual instructions).
_write_launcher_override() {
    local old new
    old="$(launcher_override_get)"
    if [ "$old" == "__NOAPP__" ]; then
        print_warning_arrow "$(launcher_label "$OVERRIDE_LAUNCHER") no longer has settings for this game, so the override wasn't added to $(launcher_override_where)."
        return 1
    fi
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then
        new="$(launch_options_with_override "$( [ "$old" == "__ABSENT__" ] || echo "$old")" "$PRIMARY_DLL_NAME")"
        [ -e "$OVERRIDE_FILE.eax-restore.bak" ] || cp -p "$OVERRIDE_FILE" "$OVERRIDE_FILE.eax-restore.bak" 2>/dev/null
    else
        new="$(merge_dll_override "$( [ "$old" == "__ABSENT__" ] || echo "$old")" "$PRIMARY_DLL_NAME")"
    fi

    if [ "$old" == "$new" ]; then
        # Set by an earlier install: keep its manifest line (with the value
        # from before that install), or uninstall would never put it back.
        local line
        local -a f
        for line in "${PREV_LAUNCHER_LINES[@]}"; do
            mapfile -t -d $'\t' f < <(printf '%s' "${line#LAUNCHER:}")
            if [ "${f[0]}" == "$OVERRIDE_LAUNCHER" ] && [ "${f[1]}" == "$OVERRIDE_FILE" ] \
                && [ "${f[2]}" == "$OVERRIDE_ID" ] && [ "${f[4]}" == "$new" ]; then
                printf '%s\n' "$line" >> "$INSTALL_MANIFEST"
                break
            fi
        done
        print_status "Already set: $(launcher_override_where)"
        return 0
    fi
    if ! launcher_override_set "$new" || [ "$(launcher_override_get)" != "$new" ]; then
        print_error_arrow "Couldn't save the override to $(launcher_override_where), so it isn't set." \
            "The run log has the details."
        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
        return 1
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
        # Phase 1's "No" to removing it means leave it.
        if [ -n "${LAUNCHER_REMOVE_DECLINED[$line]:-}" ]; then
            LAUNCHER_LINES_KEPT+=("$line"); continue
        fi
        if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" remove "type 's' to leave it as it is"; then
            print_status "Left the DLL override in $(launcher_override_where)." "$YELLOW"
            LAUNCHER_LINES_KEPT+=("$line"); continue
        fi
        # DSOAL's logging variables don't count as a change since install:
        # the logging utility adds them, and with DSOAL gone they're pointless,
        # so reverting drops them too (Steam's go with the restored launch
        # options; Heroic's are removed below).
        current="$(launcher_override_get)"
        [ "$OVERRIDE_LAUNCHER" == "steam" ] && current="$(launch_options_without_dsoal_log "$current")"
        if [ "$OVERRIDE_LAUNCHER" == "heroic" ]; then
            local var
            for var in DSOAL_LOGLEVEL DSOAL_LOGFILE; do
                case "$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" "$var")" in
                    __ABSENT__|__NOAPP__) ;;
                    *) heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" "$var" __DELETE__ ;;
                esac
            done
        fi
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
    # Once, after every line, so a launcher with several lines is only
    # closed and reopened once.
    reopen_launchers
}

# Usage: choose_override_method
# Step 10's menu. Sets OVERRIDE_METHOD to registry | launcher | manual.
# Steam and Heroic games get 1) launcher (default) / 2) registry / 3) manual; a
# plain Wine prefix gets 1) registry (default) / 2) manual. Choosing the launcher
# when it hasn't saved any settings for the game yet works like the prefix
# step's "not found yet" check: explain, then offer to check again (No goes
# back to the menu).
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
            print_option 2 "$(runner_label) prefix registry"
            print_option 3 "I'll do it myself" "(instructions at the end)"
            max=3
        else
            print_option 1 "$(runner_label) prefix registry" "(default)"
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
        # The launcher itself is dealt with when the override is written
        # (apply_launcher_override offers to close and reopen it), so the
        # player isn't asked to close it in the middle of configuring.
    done
}
