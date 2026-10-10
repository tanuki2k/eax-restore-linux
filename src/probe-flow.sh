# ==============================================================================
# TOOLS → PROBE GAME SETTINGS (EAX_RESTORE_DEV=1 only)
# ==============================================================================
# A contributor's tool for finding which of a game's own settings the database
# should change. It launches the game twice around an install of the EAX fix
# and snapshots every config file the game keeps, so the difference between
# the two runs is exactly what the player switched in-game:
#   snapshot 0  before the first launch (shows which files the game creates)
#   snapshot 1  after run A, quit at the main menu without changing anything
#   snapshot 2  after the install (shows what the install's Game Settings wrote)
#   snapshot 3  after run B, with the EAX/3D sound options switched on
#   snapshot 4  after run C (if wanted), with the optional settings changed
# 2 → 3 becomes a proposed audio setting and 3 → 4 an optional one, merged
# into the game's file in a repo
# checkout (data/games/*/ or data/drafts/); only games with a file there
# are listed (or, outside a checkout, an entry in the built database). The
# install in the middle is the normal install flow with step 1 skipped
# (PRESET_GAME_DIR); install-flow.sh hands back to probe_after_install when
# it's done. Each session's state and snapshots live in PROBE_DIR/<slug>/,
# so one cut short (a failed install, a closed terminal) can carry on from
# where it stopped.

# Config file names a game's settings can live in. The schema only takes
# .ini/.cfg/.gdb, so other matches are reported but never proposed.
PROBE_CONFIG_RE='.*\.(cfg|ini|ltx|gdb|con)$'
# Prefix folders where games keep their settings, below drive_c/users/<user>.
PROBE_USER_DIRS=("Documents" "AppData" "Saved Games")
# Paths under those that are Wine's or Windows' own, never the game's.
PROBE_NOISE_RE='/(Microsoft|Temp|wine_gecko|Mozilla|Steam|Valve|GOG\.com/Galaxy)/'
# Processes in a game's prefix that are Wine's, Proton's or a launcher's own,
# never the game's exe.
PROBE_NOT_GAME_EXE_RE='(^|[\\/])(steam|explorer|services|winedevice|plugplay|svchost|rpcss|tabtip|conhost|start|wineboot|winemenubuilder|rundll32|iexplore|regedit|cmd|mscorsvw|crashpad_handler|steamerrorreporter(64)?|eosoverlayrenderer.*|unins[0-9]*|.*setup.*|.*redist.*|dxsetup)\.exe$'

# Usage: probe_repo_dir
# The repo checkout this script runs from — dist/eax-restore-linux.sh beside
# data/schema.json — or EAX_RESTORE_REPO. Prints nothing outside a checkout.
probe_repo_dir() {
    local dir
    if [ -n "${EAX_RESTORE_REPO:-}" ]; then
        [ -f "$EAX_RESTORE_REPO/data/schema.json" ] && realpath "$EAX_RESTORE_REPO"
        return 0
    fi
    dir="$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")"
    [ "$(basename "$dir")" == "dist" ] && [ -f "$dir/../data/schema.json" ] && realpath "$dir/.."
    return 0
}

# Usage: probe_entry_file <repo> <steam|gog> <id>
# The game's file in the repo (tested, untested or drafts), if it has one.
# One jq over every file, since a jq per file is slow with a hundred-odd.
probe_entry_file() {
    local f
    f="$(jq -r --arg s "$2" --arg id "$3" \
        'select((.stores[$s].id // "") | tostring == $id) | input_filename' \
        "$1"/data/games/tested/*.json "$1"/data/games/untested/*.json "$1"/data/drafts/*.json \
        2>/dev/null | head -n 1)"
    [ -n "$f" ] && echo "$f"
}

# Usage: probe_load_database [repo]
# Fills PROBE_DB ("<store>:<id>" → the game's file in the repo, or "-" for
# an entry in the built database outside a checkout) with one jq call, so
# the installed-games list can skip a game with one lookup, the way
# scan_game_libraries does.
probe_load_database() {
    local store id file
    declare -gA PROBE_DB=()
    while IFS=$'\t' read -r store id file; do
        [ -n "$id" ] && PROBE_DB["$store:$id"]="$file"
    done < <(
        if [ -n "${1:-}" ]; then
            jq -r '(.stores // {}) | to_entries[] | select(.value.id != null)
                | [.key, (.value.id | tostring), input_filename] | @tsv' \
                "$1"/data/games/tested/*.json "$1"/data/games/untested/*.json "$1"/data/drafts/*.json 2>/dev/null
        else
            jq -r '.games[]? | (.stores // {}) | to_entries[] | select(.value.id != null)
                | [.key, (.value.id | tostring), "-"] | @tsv' "${GAME_DATABASE_FILE:-/dev/null}" 2>/dev/null
        fi)
}

# Usage: probe_list_games
# Every installed Steam game and Heroic GOG game in PROBE_DB, one per line:
# store<TAB>id<TAB>name<TAB>install folder<TAB>prefix. The prefix is where the
# launcher keeps it, or will create it on the first launch (it may not exist
# yet). A game is checked against PROBE_DB before anything else is read.
probe_list_games() {
    local lib acf id name dir root conf
    while IFS= read -r lib; do
        for acf in "$lib"/appmanifest_*.acf; do
            [ -f "$acf" ] || continue
            id="$(basename "$acf" | tr -dc '0-9')"
            [ -n "${PROBE_DB["steam:$id"]+x}" ] || continue
            name="$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" | head -n 1)"
            dir="$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" | head -n 1)"
            [ -d "$lib/common/$dir" ] || continue
            printf 'steam\t%s\t%s\t%s\t%s\n' "$id" "$name" "$lib/common/$dir" "$lib/compatdata/$id/pfx"
        done
    done < <(steam_library_dirs)
    while IFS=$'\t' read -r _ conf; do
        [ -f "$conf/gog_store/installed.json" ] || continue
        while IFS=$'\t' read -r id dir; do
            [ -n "$id" ] && [ -n "${PROBE_DB["gog:$id"]+x}" ] && [ -d "$dir" ] || continue
            name="$(jq -r --arg id "$id" '.games[]? | select(.app_name == $id) | .title // empty' \
                "$conf/store_cache/gog_library.json" 2>/dev/null | head -n 1)"
            [ -n "$name" ] || name="$(basename "$dir")"
            root="$(probe_heroic_prefix "$conf" "$id" "$name")"
            printf 'gog\t%s\t%s\t%s\t%s\n' "$id" "$name" "${dir%/}" "$root"
        done < <(jq -r '.installed[]? | select((.platform // "windows") == "windows") | [.appName, .install_path] | @tsv' \
            "$conf/gog_store/installed.json" 2>/dev/null)
    done < <(heroic_roots)
}

# Usage: probe_heroic_prefix <heroic config dir> <appName> <title>
# The game's prefix as Heroic has it in GamesConfig/<appName>.json, else the
# one it creates on the first launch: the default prefix folder plus the
# title as heroic_prefix_name spells it.
probe_heroic_prefix() {
    local pfx
    pfx="$(jq -r '.[]? | objects | .winePrefix // empty' "$1/GamesConfig/$2.json" 2>/dev/null | head -n 1)"
    if [ -z "$pfx" ]; then
        pfx="$(jq -r '.defaultSettings.winePrefix // empty' "$1/config.json" 2>/dev/null)"
        [ -n "$pfx" ] || pfx="$HOME/Games/Heroic/Prefixes/default"
        pfx="$pfx/$(heroic_prefix_name "$3")"
    fi
    echo "${pfx%/}"
}

# Usage: probe_prefix_exists
probe_prefix_exists() { [ -n "$PROBE_PREFIX" ] && [ -d "$PROBE_PREFIX/drive_c" ]; }

# Usage: probe_slug <name>
probe_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-//' -e 's/-$//'
}

# Usage: probe_save_session
# Writes the PROBE_* globals to the session file, one key=value per line.
probe_save_session() {
    mkdir -p "$PROBE_SESSION_DIR"
    {
        printf 'store=%s\nid=%s\nname=%s\nroot=%s\nprefix=%s\n' \
            "$PROBE_STORE" "$PROBE_ID" "$PROBE_NAME" "$PROBE_ROOT" "$PROBE_PREFIX"
        printf 'exe=%s\nexe_dir=%s\nstage=%s\n' "$PROBE_EXE" "$PROBE_EXE_DIR" "$PROBE_STAGE"
    } > "$PROBE_SESSION_DIR/session"
}

# Usage: probe_load_session <dir>
# Read back field by field rather than sourced: it's plain data.
probe_load_session() {
    local key value
    PROBE_SESSION_DIR="$1"
    while IFS='=' read -r key value; do
        case "$key" in
            store) PROBE_STORE="$value" ;; id) PROBE_ID="$value" ;; name) PROBE_NAME="$value" ;;
            root) PROBE_ROOT="$value" ;; prefix) PROBE_PREFIX="$value" ;; exe) PROBE_EXE="$value" ;;
            exe_dir) PROBE_EXE_DIR="$value" ;; stage) PROBE_STAGE="$value" ;;
        esac
    done < "$1/session"
}

# Usage: probe_config_files
# Every config file under the game's install folder, and under the prefix's
# user folders, one absolute path per line.
probe_config_files() {
    local u d
    find "$PROBE_ROOT" -maxdepth 5 -type f -regextype posix-extended -iregex "$PROBE_CONFIG_RE" 2>/dev/null
    probe_prefix_exists || return 0
    for u in "$PROBE_PREFIX"/drive_c/users/*/; do
        # Wine links users/<you> to users/steamuser; only look once.
        [ -L "${u%/}" ] && continue
        for d in "${PROBE_USER_DIRS[@]}"; do
            [ -d "$u$d" ] || continue
            find "$u$d" -maxdepth 6 -type f -regextype posix-extended -iregex "$PROBE_CONFIG_RE" 2>/dev/null
        done
    done | grep -v -E "$PROBE_NOISE_RE" || true
}

# DLLs that ship with many games and never hold the game's own setting names.
PROBE_SKIP_DLL_RE='^(binkw?32|mss32|openal32|soft_oal|wrap_oal|dsound|dsoal-aldrv|steam_api(64)?|d3d.*|dxgi|msvc.*|vcruntime.*|ucrtbase|goggame-.*|galaxy(64)?|sdl2?|nvngx.*|sl\..*|amd_.*|gfsdk.*|dxcompiler|lua51|dbghelp|bugtrap)\.dll$'

# Usage: probe_scan_report
# Step 1's look at the game before any launch, as plain text with "== "
# section lines: its config files (line endings, size, date), the names in
# its exes and DLLs that look like sound options or config files, its
# bundled OpenAL, and its Miles 3D providers. Read-only towards the game.
probe_scan_report() {
    local f name hits found=0 ver kind m3d le
    echo "== Config files"
    while IFS= read -r f; do
        if ! LC_ALL=C grep -qI '' "$f" 2>/dev/null; then le="binary"
        elif LC_ALL=C grep -q $'\r$' "$f" 2>/dev/null; then le="CRLF"
        else le="LF"; fi
        printf '  %-6s %8s  %s  %s\n' "$le" "$(stat -c %s "$f")" "$(date -r "$f" '+%F %R')" "$(tilde_path "$f")"
    done < <(probe_config_files | sort)

    echo "== Setting names in $PROBE_NAME's exes and DLLs"
    if ! command -v strings &>/dev/null; then
        echo "  (strings isn't installed, so they weren't searched; it's in binutils)"
    else
        while IFS= read -r f; do
            name="$(basename "$f")"
            [[ "${name,,}" =~ $PROBE_SKIP_DLL_RE ]] && continue
            [[ "${name,,}" =~ ^(unins[0-9]*|.*setup.*|.*redist.*|dxsetup)\.exe$ ]] && continue
            hits="$(strings -n 4 "$f" | grep -a -i -E \
                '\.(cfg|ini|ltx|gdb)$|eax|efx|a3d|3d ?sound|sound.*(provider|hardware|quality|device)|^snd_|reverb|environment(al)? audio' \
                | grep -v -E '@@|^\?|^\.\?A' | sort -u | head -40 || true)"
            [ -n "$hits" ] || continue
            echo "  $name:"
            printf '      %s\n' "${hits//$'\n'/$'\n      '}"
        done < <(find "$PROBE_ROOT" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.dll' \) | sort)
    fi

    echo "== OpenAL"
    while IFS= read -r f; do
        found=1
        ver="$(strings -n 6 "$f" 2>/dev/null | grep -m1 -o -E 'ALSOFT [0-9.]+' || true)"
        if [ -n "$ver" ]; then kind="OpenAL Soft ${ver#ALSOFT }"
        elif [ -f "$(dirname "$f")/wrap_oal.dll" ]; then kind="Creative router (wrap_oal.dll next to it: DirectSound3D path)"
        else kind="not OpenAL Soft"; fi
        printf '  %s: %s, %s\n' "${f#"$PROBE_ROOT"/}" "$kind" "$(file -b "$f" | cut -d, -f1-2)"
    done < <(find "$PROBE_ROOT" -maxdepth 3 -type f \( -iname 'openal32.dll' -o -iname 'soft_oal.dll' \))
    [ "$found" -eq 1 ] || echo "  (none bundled)"

    m3d="$(find "$PROBE_ROOT" -maxdepth 3 -type f -iname '*.m3d' | sort)"
    [ -n "$m3d" ] || return 0
    echo "== Miles 3D providers"
    while IFS= read -r f; do
        # The provider's display name is the first vendor/API string that
        # isn't an error message; strings keeps the length byte in front.
        printf '  %-14s %s\n' "$(basename "$f")" "$(strings -n 6 "$f" 2>/dev/null \
            | grep -v -i -E 'error|fail|could|unable|missing|_AIL_|@' \
            | grep -m1 -E '^[^A-Za-z]?(Miles|Creative|Dolby|DirectSound|RAD Game Tools|Aureal|Sensaura|QSound)' \
            | sed 's/^[^A-Za-z]//' || true)"
    done <<< "$m3d"
}

# Usage: probe_show_scan
# Prints probe_scan_report, its sections as subheadings, and keeps a copy
# in the session folder (scan.txt) to look back at while writing the entry.
probe_show_scan() {
    local report line
    print_task "Looking through $PROBE_NAME's folder"
    report="$(probe_scan_report)"
    printf '%s\n' "$report" > "$PROBE_SESSION_DIR/scan.txt"
    while IFS= read -r line; do
        if [[ "$line" == "== "* ]]; then print_subheading "${line#== }"
        else echo -e "${WHITE}${line}${NC}"; fi
    done <<< "$report"
    print_status "Kept in $(tilde_path "$PROBE_SESSION_DIR/scan.txt")." "$DIM"
}

# Usage: probe_snap <n>
# Copies every config file, plus the prefix's user.reg and system.reg (some
# games keep their options machine-wide), into snapshot <n>.
# Files keep their full path under it, so a game-folder file and a prefix
# file of the same name can't collide.
probe_snap() {
    local dir="$PROBE_SESSION_DIR/$1" f count=0
    rm -rf "$dir"
    mkdir -p "$dir/files"
    while IFS= read -r f; do
        mkdir -p "$dir/files$(dirname "$f")"
        cp -p "$f" "$dir/files$f"
        count=$((count + 1))
    done < <(probe_config_files)
    for f in user.reg system.reg; do
        [ -n "$PROBE_PREFIX" ] && [ -f "$PROBE_PREFIX/$f" ] && cp -p "$PROBE_PREFIX/$f" "$dir/$f"
    done
    print_status "Snapshot $1: $count config file$([ "$count" -eq 1 ] || echo s)" "$DIM"
}

# Usage: probe_game_pids
# The processes running the game, one PID per line. Matched two ways, so a
# game without a database entry is found, and so is one whose prefix isn't
# where it was expected (see probe_learn_prefix):
#  - by environment: Proton's processes carry STEAM_COMPAT_DATA_PATH (the
#    reaper from the moment Steam starts the game), Wine's WINEPREFIX. Proton
#    points WINEPREFIX at <compat data>/pfx/, which for a Heroic game run with
#    Proton is the prefix's own pfx -> . link, and Heroic's compat data is the
#    prefix itself (Steam's is the folder above it). wineserver counts until
#    it's gone, by which time config files are written.
#  - by command line: a process running an exe inside the install folder, as
#    a Linux path or through any of the prefix's drive letters (Heroic maps
#    X: to the home folder, so a game there runs as X:\...).
probe_game_pids() {
    local pfx p link drive target root rest
    local -a pats=() cmd_pats=()
    if [ -n "$PROBE_PREFIX" ]; then
        pfx="${PROBE_PREFIX%/}"
        for p in "$pfx" "$(realpath -m "$pfx")"; do
            pats+=(-e "WINEPREFIX=$p" -e "WINEPREFIX=$p/" -e "WINEPREFIX=$p/pfx" -e "WINEPREFIX=$p/pfx/"
                -e "STEAM_COMPAT_DATA_PATH=$p" -e "STEAM_COMPAT_DATA_PATH=$p/")
            [ "$PROBE_STORE" == "steam" ] && pats+=(-e "STEAM_COMPAT_DATA_PATH=$(dirname "$p")")
        done
    fi
    root="$(realpath -m "$PROBE_ROOT")"
    cmd_pats=(-e "$root/")
    for link in "$PROBE_PREFIX"/dosdevices/?:; do
        [ -L "$link" ] || continue
        target="$(readlink -f "$link" 2>/dev/null)" || continue
        target="${target%/}"
        [[ "$root/" == "$target/"* ]] || continue
        rest="${root#"$target"}"; rest="${rest#/}"
        drive="$(basename "$link")"; drive="${drive%:}"
        for p in "${drive^^}" "${drive,,}"; do
            cmd_pats+=(-e "$p:\\${rest//\//\\}\\")
        done
    done
    # No prefix yet (or no drive links): Wine's usual Z: for /.
    [ ${#cmd_pats[@]} -gt 1 ] || cmd_pats+=(-e "Z:${root//\//\\}\\")
    {
        [ ${#pats[@]} -gt 0 ] && grep -lzsxF "${pats[@]}" /proc/[0-9]*/environ 2>/dev/null
        grep -lzsF "${cmd_pats[@]}" /proc/[0-9]*/cmdline 2>/dev/null \
            | while IFS= read -r f; do
                # Only an argument that's an exe there, not a shell or editor
                # that merely mentions the folder.
                { tr '\0' '\n' < "$f"; } 2>/dev/null | grep -qiE '\.exe$' && echo "$f"
            done
    } | sed 's|^/proc/\([0-9]*\)/.*$|\1|' | sort -un | grep -vx "$$" || true
}

# Usage: probe_learn_prefix <pid>...
# When the expected prefix doesn't exist, takes the real one from the
# running game's environment (WINEPREFIX, or Steam's
# STEAM_COMPAT_DATA_PATH/pfx) and saves it to the session.
probe_learn_prefix() {
    local pid env found
    probe_prefix_exists && return 0
    for pid in "$@"; do
        env="$( { tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null)"
        found="$(sed -n 's/^WINEPREFIX=//p' <<< "$env" | head -n 1)"
        if [ -z "$found" ]; then
            found="$(sed -n 's/^STEAM_COMPAT_DATA_PATH=//p' <<< "$env" | head -n 1)"
            [ -n "$found" ] && found="${found%/}/pfx"
        fi
        found="${found%/}"
        if [ -n "$found" ] && [ "$found" != "${PROBE_PREFIX%/}" ]; then
            PROBE_PREFIX="$found"
            log_cmd "probe: $PROBE_NAME runs in $found"
            probe_save_session
            return 0
        fi
    done
}

# Usage: probe_exe_path <argument>
# A Windows or Linux .exe path from a command line, as a Linux path: Z:\ is
# /, any other drive goes through the prefix's dosdevices links.
probe_exe_path() {
    local arg="$1" drive rest
    if [[ "$arg" =~ ^([A-Za-z]):[\\/](.*)$ ]]; then
        drive="${BASH_REMATCH[1],,}"; rest="${BASH_REMATCH[2]//\\//}"
        if [ "$drive" == "z" ]; then echo "/$rest"
        else echo "$(readlink -f "$PROBE_PREFIX/dosdevices/$drive:" 2>/dev/null || echo "$PROBE_PREFIX/drive_c")/$rest"; fi
    else
        echo "${arg//\\//}"
    fi
}

# Usage: probe_record_exes <pid>...
# Adds the game exes in these processes' command lines to PROBE_SEEN_EXES
# (Linux paths, in the order they were first seen). Only exes inside the
# game's install folder count, so Wine's and the launchers' own don't.
probe_record_exes() {
    local pid arg path seen
    for pid in "$@"; do
        while IFS= read -r -d '' arg; do
            [[ "${arg,,}" == *.exe ]] || continue
            [[ "${arg,,}" =~ $PROBE_NOT_GAME_EXE_RE ]] && continue
            path="$(probe_exe_path "$arg")"
            [ -f "$path" ] || path="$(find_existing_variant "$path")"
            [ -n "$path" ] && [ -f "$path" ] || continue
            path="$(realpath "$path")"
            [[ "$path" == "$(realpath "$PROBE_ROOT")"/* ]] || continue
            for seen in "${PROBE_SEEN_EXES[@]}"; do [ "$seen" == "$path" ] && continue 2; done
            PROBE_SEEN_EXES+=("$path")
        done < <({ cat "/proc/$pid/cmdline"; } 2>/dev/null)
    done
}

# Usage: probe_launch
# Starts the game through its launcher's URL handler. False when there's no
# way to, so the caller asks the player to start it themselves.
probe_launch() {
    local url
    command -v xdg-open &>/dev/null || return 1
    if [ "$PROBE_STORE" == "steam" ]; then url="steam://rungameid/$PROBE_ID"
    else url="heroic://launch?appName=$PROBE_ID&runner=gog"; fi
    log_cmd "probe: xdg-open $url"
    setsid xdg-open "$url" >> "$EAX_LOG_FILE" 2>&1 < /dev/null &
    return 0
}

# Usage: probe_run_game "what to do in-game" ["more lines" ...]
# Launches the game, waits for it to start and then to quit, and records the
# exes it ran (PROBE_SEEN_EXES). Enter while waiting asks what to do, for a
# game that never shows up or a process that outlives the game. Returns 1 if
# the player gives up on this run.
probe_run_game() {
    local pids waited=0 key
    PROBE_SEEN_EXES=()
    if [ -n "$(probe_game_pids)" ]; then
        print_warning "$PROBE_NAME is already running. Quit it first, so this run starts from its saved settings."
        while [ -n "$(probe_game_pids)" ]; do sleep 2; done
    fi
    print_paragraph "$@"
    if probe_launch; then
        print_status "Starting $PROBE_NAME through $([ "$PROBE_STORE" == "steam" ] && echo Steam || echo Heroic)."
    else
        print_status "Start $PROBE_NAME from its launcher now." "$YELLOW"
    fi
    print_status "Waiting for it to start (press Enter if it doesn't)." "$DIM"
    while true; do
        pids="$(probe_game_pids)"
        [ -n "$pids" ] && break
        if read -r -t 2 key || [ "$waited" -ge 180 ]; then
            waited=0
            print_warning_arrow "$PROBE_NAME hasn't been seen running yet."
            confirm "Keep waiting? (Start it yourself if the launcher didn't.)" Y || return 1
            continue
        fi
        waited=$((waited + 2))
    done
    print_status "$PROBE_NAME is running. Waiting for it to quit (press Enter if it has and this doesn't move on)." "$DIM"
    while [ -n "$pids" ]; do
        # shellcheck disable=SC2086
        probe_record_exes $pids
        # shellcheck disable=SC2086
        probe_learn_prefix $pids
        if read -r -t 2 key; then
            print_warning_arrow "These are still running in $PROBE_NAME's prefix:"
            # shellcheck disable=SC2086
            ps -o pid=,args= -p "$(echo $pids | tr ' ' ',')" 2>/dev/null | cut -c1-110 | sed 's/^/      /'
            confirm "Carry on anyway? Config files may not be written yet." N && break
        fi
        pids="$(probe_game_pids)"
        # Only a launcher or wrapper process was seen, never the game's own
        # exe: it may still be running somewhere the probe can't see.
        if [ -z "$pids" ] && [ ${#PROBE_SEEN_EXES[@]} -eq 0 ] \
            && ! confirm "$PROBE_NAME's own exe was never seen running, so this may be wrong: has it really quit?" N; then
            # Picks the watch up again if the game shows up; otherwise
            # the player says when it's done.
            print_status "Press Enter once $PROBE_NAME has quit." "$YELLOW"
            while [ -z "$pids" ]; do
                read -r -t 2 key && break
                pids="$(probe_game_pids)"
            done
        fi
    done
    # A game may write its config a moment after its window closes.
    sleep 1
    print_result "$PROBE_NAME has quit." "$GREEN"
    return 0
}

# Usage: probe_pick_exe
# Sets PROBE_EXE / PROBE_EXE_DIR from the exes run A saw: the only one, or
# the player's pick when the game went through a launcher exe first. Kept as
# they were when nothing was seen.
probe_pick_exe() {
    local i choice
    [ ${#PROBE_SEEN_EXES[@]} -gt 0 ] || {
        [ -n "$PROBE_EXE_DIR" ] || print_note "No game exe was seen running, so the install will start from the install folder."
        return 0
    }
    if [ ${#PROBE_SEEN_EXES[@]} -eq 1 ]; then
        choice=1
    else
        echo -e "\n${WHITE}$PROBE_NAME ran more than one exe. Which one is the game?${NC}\n"
        for i in "${!PROBE_SEEN_EXES[@]}"; do
            print_option "$((i + 1))" "$(basename "${PROBE_SEEN_EXES[$i]}")" "in $(tilde_path "$(dirname "${PROBE_SEEN_EXES[$i]}")")"
        done
        while true; do
            prompt "Selection [1-${#PROBE_SEEN_EXES[@]}, default ${#PROBE_SEEN_EXES[@]}]: "
            read_answer choice || exit 0
            choice="${choice:-${#PROBE_SEEN_EXES[@]}}"
            [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#PROBE_SEEN_EXES[@]} ] && break
            print_result "That's not a valid option — please type a number from 1 to ${#PROBE_SEEN_EXES[@]}." "$YELLOW"
        done
    fi
    PROBE_EXE="$(basename "${PROBE_SEEN_EXES[$((choice - 1))]}")"
    PROBE_EXE_DIR="$(dirname "${PROBE_SEEN_EXES[$((choice - 1))]}")"
    print_detected "Game exe" "$(tilde_path "$PROBE_EXE_DIR")/$PROBE_EXE"
}

# Usage: probe_guess_format <file>
# Which of the config file formats a file looks like, from its contents.
probe_guess_format() {
    local f="$1"
    if [[ "${f,,}" == *.gdb ]]; then echo "gadb"
    elif LC_ALL=C grep -qE '^[[:space:]]*\[[^]]+\][[:space:]]*$' "$f"; then echo "ini"
    elif LC_ALL=C grep -qiE '^[[:space:]]*seta?[[:space:]]+[A-Za-z_]' "$f"; then echo "idtech_cfg"
    elif LC_ALL=C grep -qE '^[[:space:]]*\{[^}]*\}[[:space:]]*=[[:space:]]*\{' "$f"; then echo "brace_cfg"
    elif LC_ALL=C grep -qE '^[^;#[:space:]][^=]*=' "$f"; then echo "flat_ini"
    else echo "dark_cfg"; fi
}

# Usage: probe_dump <file> <format>
# Every setting in the file as "section␟key␟value␟Section␟Key" (\x1f
# between, section empty outside ini), read the way config_get_key reads
# them: lowercased for matching, then their spelling in the file. Not tabs,
# since read would merge the empty fields. A key
# set more than once in the same section (Unreal's Paths= lists) is left out,
# since a single change can't express it. dark_cfg flags read __TRUE__, and
# __FALSE__ when only commented out.
probe_dump() {
    local file="$1" fmt="$2"
    [ -f "$file" ] || return 0
    if [ "$fmt" == "gadb" ]; then
        od -An -v -tu1 -w1 "$file" 2>/dev/null | LC_ALL=C awk '
            { b[n++] = $1 + 0 }
            function u32(i) { return b[i] + b[i+1] * 256 + b[i+2] * 65536 + b[i+3] * 16777216 }
            END {
                if (n < 28 || b[0] != 71 || b[1] != 65 || b[2] != 68 || b[3] != 66) exit
                end = 28 + u32(8); if (end > n) exit
                s = ""; start = 28
                for (i = 28; i < end; i++) {
                    if (b[i] == 0) { if (s != "") name[start - 28] = s; s = ""; start = i + 1 }
                    else s = s sprintf("%c", b[i])
                }
                for (i = end + (4 - end % 4) % 4; i + 20 <= n; i += 4) {
                    o = u32(i)
                    if ((o in name) && u32(i+4) == 1 && u32(i+8) == 0 && u32(i+12) == 1) { hits[o]++; val[o] = u32(i+16) }
                }
                for (o in hits) if (hits[o] == 1) printf "\037%s\037%s\037\037%s\n", tolower(name[o]), val[o], name[o]
            }'
        return
    fi
    LC_ALL=C awk -v fmt="$fmt" '
        { sub(/\r$/, "") }
        function add(s, k, v,   id) {
            id = tolower(s) SUBSEP tolower(k)
            if (id in seen) { dup[id] = 1; return }
            seen[id] = 1; order[++n] = id; S[id] = s; K[id] = k; V[id] = v
        }
        fmt == "ini" && /^[ \t]*\[.*\][ \t]*$/ { sec = $0; gsub(/^[ \t]*\[|\][ \t]*$/, "", sec); next }
        fmt == "ini" || fmt == "flat_ini" {
            if ($0 ~ /^[ \t]*[;#]/) next
            p = index($0, "="); if (p == 0) next
            k = substr($0, 1, p - 1); gsub(/^[ \t]+|[ \t]+$/, "", k); if (k == "") next
            v = substr($0, p + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            add(fmt == "ini" ? sec : "", k, v); next
        }
        fmt == "idtech_cfg" {
            line = $0; if (!match(tolower(line), /^[ \t]*seta?[ \t]+/)) next
            rest = substr(line, RLENGTH + 1); split(rest, a, /[ \t]+/)
            v = substr(rest, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); gsub(/^"|"$/, "", v)
            add("", a[1], v); next
        }
        fmt == "dark_cfg" {
            line = $0; is_comment = (line ~ /^[ \t]*;/)
            sub(/^[ \t]*;?[ \t]*/, "", line); if (line == "") next
            split(line, a, /[ \t]+/)
            if (a[1] !~ /^[A-Za-z_][A-Za-z0-9_.]*$/) next
            if (is_comment) { if (!(tolower(a[1]) in commented)) commented[tolower(a[1])] = a[1]; next }
            v = substr(line, length(a[1]) + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
            add("", a[1], (v == "" ? "__TRUE__" : v)); next
        }
        fmt == "brace_cfg" {
            if (!match($0, /^[ \t]*\{[^}]*\}[ \t]*=[ \t]*\{/)) next
            k = substr($0, 1, RLENGTH); sub(/^[ \t]*\{[ \t]*/, "", k); sub(/[ \t]*\}.*$/, "", k)
            v = substr($0, RLENGTH + 1); sub(/\}[ \t]*$/, "", v)
            add("", k, v)
        }
        END {
            for (i = 1; i <= n; i++) {
                id = order[i]; if (id in dup) continue
                printf "%s\037%s\037%s\037%s\037%s\n", tolower(S[id]), tolower(K[id]), V[id], S[id], K[id]
            }
            for (k in commented) if (!(SUBSEP k in seen)) printf "\037%s\037__FALSE__\037\037%s\n", k, commented[k]
        }' "$file"
}

# Usage: probe_location <path>
# The game_config location ("base:relative path") a live config file's path
# matches, or nothing when it's somewhere the database can't point to.
probe_location() {
    local path="$1" rel u
    if [ -n "$PROBE_EXE_DIR" ] && [[ "$path" == "$PROBE_EXE_DIR"/* ]]; then
        echo "game:${path#"$PROBE_EXE_DIR"/}"; return
    fi
    if [[ "$path" == "$PROBE_ROOT"/* ]]; then echo "install:${path#"$PROBE_ROOT"/}"; return; fi
    [ -n "$PROBE_PREFIX" ] || return 0
    rel="${path#"$PROBE_PREFIX"/drive_c/users/}"
    [ "$rel" != "$path" ] || return 0
    u="${rel%%/*}"; rel="${rel#*/}"
    case "$u/$rel" in
        Public/Documents/*) echo "prefix_public_documents:${rel#Documents/}" ;;
        */Documents/*) echo "prefix_documents:${rel#Documents/}" ;;
        */AppData/Roaming/*) echo "prefix_appdata:${rel#AppData/Roaming/}" ;;
        */AppData/Local/*) echo "prefix_localappdata:${rel#AppData/Local/}" ;;
    esac
}

# Usage: probe_reg_dump <user.reg or system.reg>
# The registry values under the game's own keys, as "key<TAB>value line":
# Wine's, Windows' and the launchers' keys left out, since they change on
# every start, and so are system.reg's System and Hardware branches (devices).
probe_reg_dump() {
    [ -f "$1" ] || return 0
    LC_ALL=C awk '
        /^\[/ { key = $0; sub(/\][^]]*$/, "]", key); skip = (key ~ /^\[(System|Hardware)\\/ || key ~ /(Wine|Microsoft|Classes|Valve|Steam|Policies|Control Panel|Environment|Volatile|AppEvents|Keyboard|Printers|ShellNoRoam|EUDC|GOG\\.com)/); next }
        /^#/ || /^$/ { next }
        !skip && key != "" { print key "\t" $0 }' "$1" | sort
}

# Usage: probe_reg_changes <from .reg> <to .reg>
# The values that differ between two copies of one registry file (outside
# probe_reg_dump's noise), one per line, \x1f-separated: key path (single
# backslashes), value name, old value, new value, and 1 when it can be a
# wine_reg setting or a reason it can't. Values read like config_get_key's:
# a dword as a decimal number, a string unquoted, __ABSENT__ / __DELETE__ for
# one that's new / gone, and __RAW__ for any other type.
probe_reg_changes() {
    LC_ALL=C awk -F '\t' '
        function hex2dec(h,   i, d) { d = 0; h = tolower(h)
            for (i = 1; i <= length(h); i++) d = d * 16 + index("0123456789abcdef", substr(h, i, 1)) - 1
            return d }
        function decode(v) {
            if (v ~ /^dword:[0-9a-fA-F]+$/) return sprintf("%d", hex2dec(substr(v, 7)))
            if (v ~ /^".*"$/) { v = substr(v, 2, length(v) - 2); gsub(/\\"/, "\"", v); gsub(/\\\\/, "\\", v); return v }
            return "__RAW__"
        }
        # A value line is "Name"=data; a default value (@=) or a hex
        # continuation line has no name to set.
        function parse(line,   p) {
            if (substr(line, 1, 1) != "\"") return 0
            p = index(line, "\"="); if (p < 3) return 0
            pname = substr(line, 2, p - 2); praw = substr(line, p + 2); pdata = decode(praw); return 1
        }
        FNR == 1 { file++ }
        {
            sec = $1; sub(/^\[/, "", sec); sub(/\]$/, "", sec); gsub(/\\\\/, "\\", sec)
            if (!parse($2)) next
            k = sec SUBSEP pname
            # Compared raw, so a change between two binary values shows too.
            if (file == 1) { old[k] = pdata; oraw[k] = praw }
            else { new[k] = pdata; nraw[k] = praw; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
        }
        END {
            for (k in old) if (!(k in new)) order[++n] = k
            for (i = 1; i <= n; i++) {
                k = order[i]; split(k, part, SUBSEP)
                o = (k in old) ? old[k] : "__ABSENT__"; v = (k in new) ? new[k] : "__DELETE__"
                if ((k in oraw) && (k in nraw) && oraw[k] == nraw[k]) continue
                why = 1
                if (o == "__RAW__" || v == "__RAW__") why = "not a number or text value"
                else if (part[2] !~ /^[A-Za-z0-9._ -]+$/ || part[1] !~ /^[A-Za-z0-9._ ()-]+(\\[A-Za-z0-9._ ()-]+)+$/) why = "its name has characters the database can'"'"'t hold"
                else if (v != "__DELETE__" && v !~ /^[A-Za-z0-9._ ()-]*$/) why = "its value has characters the database can'"'"'t hold"
                printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\n", part[1], part[2], o, v, why
            }
        }' <(probe_reg_dump "$1") <(probe_reg_dump "$2")
}

# Usage: probe_propose <from> <to>
# Compares two snapshots and builds PROBE_PROPOSAL: a game_config fragment
# ({files, changes}) with the settings that changed, ready to merge. Prints
# what changed as it goes, including what can't be proposed (a file the
# database can't point to, the registry).
probe_propose() {
    local from="$PROBE_SESSION_DIR/$1/files" to="$PROBE_SESSION_DIR/$2/files"
    local rel live name fmt loc changes="{}" files="{}" lines s k v sk kk old
    local -A before=() spelled=() matched=() seen_names=()
    PROBE_PROPOSAL=""
    while IFS= read -r rel; do
        live="/${rel#./}"; name="$(basename "$live")"
        cmp -s "$from$live" "$to$live" && continue
        echo ""
        if [ -f "$from$live" ]; then echo -e "${WHITE}Changed:${NC} $(tilde_path "$live")"
        else echo -e "${WHITE}New:${NC} $(tilde_path "$live")"; fi
        if [[ ! "${name,,}" =~ \.(ini|cfg|gdb)$ ]]; then
            print_status "Not an .ini, .cfg or .gdb file, so the database can't change it." "$DIM"; continue
        fi
        loc="$(probe_location "$live")"
        if [ -z "$loc" ]; then
            print_status "Not in a folder the database can point to, so it's left out." "$DIM"; continue
        fi
        if [ -n "${seen_names[${name,,}]:-}" ]; then
            print_status "Another changed file is also called $name; only the first is proposed." "$DIM"; continue
        fi
        fmt="$(probe_guess_format "$to$live")"
        print_status "Format $fmt, location $loc" "$DIM"
        before=(); spelled=(); matched=()
        while IFS=$'\x1f' read -r s k v sk kk; do
            before["$s"$'\x1f'"$k"]="$v"; spelled["$s"$'\x1f'"$k"]="$sk"$'\x1f'"$kk"
        done < <(probe_dump "$from$live" "$fmt")
        lines=""
        while IFS=$'\x1f' read -r s k v sk kk; do
            matched["$s"$'\x1f'"$k"]=1
            old="${before["$s"$'\x1f'"$k"]-__ABSENT__}"
            [ "$old" == "$v" ] && continue
            echo -e "      ${sk:+[$sk] }$kk: ${DIM}$(config_display_value "$old")${NC} → ${GREEN}$(config_display_value "$v")${NC}"
            lines+="$sk"$'\x1f'"$kk"$'\x1f'"$v"$'\n'
        done < <(probe_dump "$to$live" "$fmt")
        # Keys the game removed: null deletes them (a dark_cfg flag only
        # commented out again shows up above as __FALSE__).
        for s in "${!before[@]}"; do
            [ -n "${matched[$s]:-}" ] && continue
            IFS=$'\x1f' read -r sk kk <<< "${spelled[$s]}"
            echo -e "      ${sk:+[$sk] }$kk: ${DIM}$(config_display_value "${before[$s]}")${NC} → ${GREEN}(removed)${NC}"
            lines+="$sk"$'\x1f'"$kk"$'\x1f'"__DELETE__"$'\n'
        done
        [ -n "$lines" ] || { print_status "Only its layout changed, no values." "$DIM"; continue; }
        seen_names[${name,,}]=1
        files="$(jq -c --arg n "$name" --arg f "$fmt" --arg l "$loc" '. + {($n): {format: $f, locations: [$l]}}' <<< "$files")"
        changes="$(printf '%s' "$lines" | jq -R -s -c --arg n "$name" --argjson base "$changes" '
            def val: if . == "__TRUE__" then true elif . == "__FALSE__" then false elif . == "__DELETE__" then null else . end;
            reduce (split("\n")[] | select(length > 0) | split("\u001f")) as $r ($base;
                if $r[0] == "" then .[$n][$r[1]] = ($r[2] | val)
                else .[$n][$r[0]][$r[1]] = ($r[2] | val) end)')"
    done < <(cd "$PROBE_SESSION_DIR/$2/files" 2>/dev/null && find . -type f | sort)

    # Files the game deleted aren't something the database can propose.
    while IFS= read -r rel; do
        [ -f "$to/${rel#./}" ] || echo -e "\n${WHITE}Deleted:${NC} $(tilde_path "/${rel#./}") ${DIM}(left out)${NC}"
    done < <(cd "$from" 2>/dev/null && find . -type f | sort)

    # Both hives, as wine_reg files: HKCU (user.reg) and HKLM (system.reg).
    # A snapshot from before system.reg was kept has none, so HKLM is
    # skipped for it rather than shown as all new.
    local hive reg_file reg_rows why prev_sec
    PROBE_REG_CHANGED=""
    for hive in "HKCU user.reg" "HKLM system.reg"; do
        read -r hive reg_file <<< "$hive"
        [ -f "$PROBE_SESSION_DIR/$1/$reg_file" ] && [ -f "$PROBE_SESSION_DIR/$2/$reg_file" ] || continue
        reg_rows="$(probe_reg_changes "$PROBE_SESSION_DIR/$1/$reg_file" "$PROBE_SESSION_DIR/$2/$reg_file")"
        [ -n "$reg_rows" ] || continue
        PROBE_REG_CHANGED=1
        echo ""
        echo -e "${WHITE}Changed:${NC} the $hive registry ($reg_file)"
        print_status "Format wine_reg, location prefix:$reg_file" "$DIM"
        lines=""; prev_sec=""
        while IFS=$'\x1f' read -r s kk old v why; do
            [ "$s" != "$prev_sec" ] && echo -e "      ${DIM}[$s]${NC}"; prev_sec="$s"
            if [ "$why" == "1" ]; then
                echo -e "        $kk: ${DIM}$(config_display_value "$old")${NC} → ${GREEN}$(config_display_value "$v")${NC}"
                lines+="$s"$'\x1f'"$kk"$'\x1f'"$v"$'\n'
            else
                echo -e "        ${DIM}$kk: $(config_display_value "$old") → $(config_display_value "$v") (left out: $why)${NC}"
            fi
        done <<< "$reg_rows"
        [ -n "$lines" ] || continue
        files="$(jq -c --arg n "$reg_file" '. + {($n): {format: "wine_reg", locations: ["prefix:\($n)"]}}' <<< "$files")"
        changes="$(printf '%s' "$lines" | jq -R -s -c --arg n "$reg_file" --argjson base "$changes" '
            reduce (split("\n")[] | select(length > 0) | split("\u001f")) as $r ($base;
                .[$n][$r[0]][$r[1]] = (if $r[2] == "__DELETE__" then null else $r[2] end))')"
    done

    [ "$changes" != "{}" ] || return 1
    PROBE_PROPOSAL="$(jq -n -c --argjson f "$files" --argjson c "$changes" '{files: $f, changes: $c}')"
}

# Usage: probe_merge <audio|optional>
# Merges PROBE_PROPOSAL into the game's file (tested, untested or drafts)
# as one new audio or optional setting, plus any file it changes that isn't
# defined yet. An audio setting is titled "Enable EAX reverb", the title
# most of them share; an optional one, and every reason, says TODO. Shows the
# result first. Outside a repo checkout, saves the proposal in the session
# folder (proposal-<audio|optional>.json) instead.
probe_merge() {
    local cat="$1" repo entry new tmp title="TODO" saved
    [ "$cat" == "audio" ] && title="Enable EAX reverb"
    saved="$PROBE_SESSION_DIR/proposal-$cat.json"
    repo="$(probe_repo_dir)"
    if [ -z "$repo" ]; then
        jq . <<< "$PROBE_PROPOSAL" > "$saved"
        print_note "this script isn't running from a repo checkout (set EAX_RESTORE_REPO to point at one)," \
            "so the proposal is saved in $(tilde_path "$saved")."
        return 0
    fi
    entry="$(probe_entry_file "$repo" "$PROBE_STORE" "$PROBE_ID")"
    if [ -z "$entry" ]; then
        jq . <<< "$PROBE_PROPOSAL" > "$saved"
        print_note "$PROBE_NAME has no file in this checkout's data/ folders any more, so the proposal is" \
            "saved in $(tilde_path "$saved")."
        return 0
    fi
    new="$(cat "$entry")"
    new="$(jq --argjson p "$PROBE_PROPOSAL" '
        .game_config.files = (($p.files) + (.game_config.files // {}))
        | .game_config[$list] = ((.game_config[$list] // []) + [{title: $title, reason: "TODO", changes: $p.changes}])
        | if (.exe // "") == "" and $exe != "" then .exe = $exe else . end' \
        --arg exe "$PROBE_EXE" --arg list "${cat}_settings" --arg title "$title" <<< "$new")"

    print_result "Proposed change to $(tilde_path "${entry#"$repo"/}"):" "$CYAN"
    if [ -f "$entry" ]; then
        diff -u --label current --label proposed <(jq . "$entry") <(jq . <<< "$new") | tail -n +3 \
            | sed -e "s/^+.*/$(printf '\033[0;32m')&$(printf '\033[0m')/" -e "s/^-.*/$(printf '\033[1;33m')&$(printf '\033[0m')/"
    else
        jq -C . <<< "$new"
    fi
    confirm "Write this to ${entry#"$repo"/}?" Y || {
        jq . <<< "$PROBE_PROPOSAL" > "$saved"
        print_status "Saved in $(tilde_path "$saved") instead." "$DIM"
        return 0
    }
    tmp="$(mktemp)"
    jq . <<< "$new" > "$tmp" && mv -f "$tmp" "$entry"
    if "$repo/tools/format-game-database.sh" >> "$EAX_LOG_FILE" 2>&1 \
        && "$repo/tools/build-game-database.sh" >> "$EAX_LOG_FILE" 2>&1; then
        print_status "Written, formatted and game-database.json rebuilt." "$GREEN"
    else
        print_warning_arrow "Written, but formatting or rebuilding the database failed — the log has the details."
    fi
    if command -v check-jsonschema &>/dev/null; then
        if check-jsonschema --schemafile "$repo/data/schema.json" "$entry" >> "$EAX_LOG_FILE" 2>&1; then
            print_status "It passes the schema." "$GREEN"
        else
            print_warning_arrow "It doesn't pass the schema yet — run check-jsonschema on it to see why."
        fi
    fi
    if [ "$cat" == "audio" ]; then
        print_paragraph "Next: write the new setting's reason, change its title if \"Enable EAX reverb\" doesn't" \
            "fit (CLAUDE.md's style rules), move any change that isn't about sound into optional_settings," \
            "and review it all with git diff."
    else
        print_paragraph "Next: give the new optional setting its title and reason (CLAUDE.md's style rules)," \
            "split it in two if it changes unrelated things, and review it all with git diff."
    fi
}

# Usage: probe_pick_game
# Step 1: the installed-games list. Sets the PROBE_* globals and
# PROBE_SESSION_DIR, carrying on an unfinished session for the same game
# when the player wants to. Returns 1 to go back to the Tools menu.
probe_pick_game() {
    local -a rows=()
    local repo row store id name root prefix status
    repo="$(probe_repo_dir)"
    print_task "Looking for installed Steam and Heroic (GOG) games in the game database"
    # Only games with an entry: in a checkout, a file in tested, untested or
    # drafts; elsewhere, the built database.
    probe_load_database "$repo"
    PAGED_LABELS=(); PAGED_DETAILS=()
    while IFS= read -r row; do
        IFS=$'\t' read -r store id name root prefix <<< "$row"
        case "${PROBE_DB["$store:$id"]}" in
            */tested/*) status="tested" ;; */untested/*) status="untested" ;;
            */drafts/*) status="draft" ;; *) status="in the database" ;;
        esac
        [ -f "$PROBE_DIR/$(probe_slug "$name")-$store/session" ] && status+=", probe in progress"
        [ -d "$prefix/drive_c" ] || status+=", never run"
        rows+=("$row")
        PAGED_LABELS+=("$name")
        PAGED_DETAILS+=("($([ "$store" == "steam" ] && echo Steam || echo GOG), $status)")
    done < <(probe_list_games | sort -t $'\t' -k3,3f)
    if [ ${#rows[@]} -eq 0 ]; then
        print_error "None of your installed Steam or Heroic GOG games are in the game database."
        [ -n "$repo" ] && print_note "to probe a game that isn't in it yet, add a file for it in data/drafts/" \
            "first (a name and its store ID are enough), then come back here."
        return 1
    fi
    paged_select "Installed games" "|" "r|[R]eturn to the Tools menu" || exit 0
    [ "$PAGED_CHOICE" == "r" ] && return 1
    IFS=$'\t' read -r store id name root prefix <<< "${rows[$((PAGED_CHOICE - 1))]}"

    PROBE_SESSION_DIR="$PROBE_DIR/$(probe_slug "$name")-$store"
    if [ -f "$PROBE_SESSION_DIR/session" ]; then
        probe_load_session "$PROBE_SESSION_DIR"
        if [ "$PROBE_STAGE" != "done" ] && probe_offer_resume "$name"; then
            # The prefix may have been created since.
            probe_prefix_exists || PROBE_PREFIX="$prefix"
            return 0
        fi
        rm -rf "$PROBE_SESSION_DIR"
    fi
    PROBE_STORE="$store"; PROBE_ID="$id"; PROBE_NAME="$name"; PROBE_ROOT="$root"; PROBE_PREFIX="$prefix"
    PROBE_EXE="$(jq -r --arg s "$store" --arg id "$id" \
        '[.games[]? | select((.stores[$s].id // "") | tostring == $id) | .exe // empty][0] // empty' \
        "${GAME_DATABASE_FILE:-/dev/null}" 2>/dev/null)"
    PROBE_EXE_DIR=""
    PROBE_STAGE="new"
    probe_save_session
}

# Usage: probe_offer_resume <name>
# An earlier probe of the same game that stopped part-way: says what it got
# done and what's next, and asks whether to pick it up. No starts over.
probe_offer_resume() {
    local so_far next
    case "$PROBE_STAGE" in
        new) so_far="You picked $1 here before, but it wasn't launched."
             next="Next: the first launch." ;;
        defaults) so_far="You already ran $1 once here, and its default settings were recorded."
                  next="Next: installing the EAX fix, then the second launch." ;;
        installed) so_far="You already ran $1 once here, and the EAX fix is installed."
                   next="Next: the second launch, where you switch its sound options on." ;;
        changed) so_far="You already ran $1 twice here."
                 next="Next: the proposed sound settings from those two runs." ;;
        proposed) so_far="You already ran $1 twice here, and its sound settings were proposed."
                  next="Next: a third launch, where you change the options worth offering as optional settings." ;;
        optional) so_far="You already ran $1 three times here."
                  next="Next: the proposed optional settings from the third run." ;;
    esac
    print_note "$so_far" "$next"
    confirm "Pick up from there? (No starts over from the first launch.)" Y
}

# Usage: probe_check_prefix
# After run A, the game's prefix has to exist: it holds the AppData and
# Documents config files, and the install goes into it. A game that ran from
# somewhere else than expected and wasn't spotted gets asked for. Returns 1
# when the player stops (the session is kept for later).
probe_check_prefix() {
    local typed
    while ! probe_prefix_exists; do
        print_warning "$PROBE_NAME's Wine/Proton prefix isn't at $(tilde_path "$PROBE_PREFIX")."
        prompt "Type the path to its prefix (the folder holding drive_c), or leave it blank to look again: "
        read_answer typed || exit 0
        typed="$(clean_typed_path "$typed")"
        if [ -n "$typed" ]; then
            if [ -d "$typed/drive_c" ]; then PROBE_PREFIX="$typed"
            else print_error_arrow "There's no drive_c in $(tilde_path "$typed")."; fi
        elif ! confirm "Check again?" Y; then
            return 1
        fi
    done
    probe_save_session
}

# Usage: probe_session
# Steps 1-3 of the tool: pick, snapshot, run A, then hand off to the install
# (returns 0 with SCRIPT_ACTION=i and PRESET_GAME_DIR set) or, when the fix is
# already installed, go straight on to probe_after_install. Returns 1 to go
# back to the Tools menu.
probe_session() {
    STEP_TOTAL=6
    print_step 1 "Game"
    print_paragraph "This step lists your installed Steam and GOG games that have a game database entry, so" \
        "you can pick one to probe."
    probe_pick_game || return 1
    [ "$PROBE_STAGE" == "new" ] && [ ! -f "$PROBE_SESSION_DIR/scan.txt" ] && probe_show_scan

    if [ "$PROBE_STAGE" == "new" ]; then
        print_step 2 "First Run: Defaults"
        # Before any launch, even when the game has never run: a prefix that
        # doesn't exist yet just adds nothing, so every file the first run
        # creates shows up as new.
        probe_snap 0
        probe_run_game "Play to the main menu, change nothing, and quit from the menu. This captures the" \
            "settings $PROBE_NAME starts with." || return 1
        probe_pick_exe
        probe_check_prefix || return 1
        probe_snap 1
        PROBE_STAGE="defaults"; probe_save_session
    fi

    if [ "$PROBE_STAGE" == "defaults" ]; then
        print_step 3 "Install"
        print_paragraph "This step installs the EAX fix into $PROBE_NAME, so the next run shows what its sound" \
            "options change with the fix in place."
        local dir="${PROBE_EXE_DIR:-$PROBE_ROOT}"
        if manifest_is_live "$dir" && confirm "The EAX fix is already installed in $PROBE_NAME. Skip installing it again?" Y; then
            probe_snap 2
            PROBE_STAGE="installed"; probe_save_session
        else
            print_paragraph "Now the normal install, with $PROBE_NAME already picked. Once it's done, this tool" \
                "carries on with the second run."
            PRESET_GAME_DIR="$dir"
            PRESET_GAME_NAME="$PROBE_NAME"
            PRESET_GAME_ROOT="$PROBE_ROOT"
            [ "$PROBE_STORE" == "steam" ] && PRESET_APPID="$PROBE_ID"
            PROBE_PENDING=1
            SCRIPT_ACTION="i"
            return 0
        fi
    fi
    probe_after_install
}

# Usage: probe_after_install
# Steps 4-6: snapshot after the install (when it just ran), run B and the
# sound settings it proposes, then, if the player wants, run C and the
# optional settings it proposes. Called by probe_session, or by
# install-flow.sh once the install it handed off to is done. Leaves the
# script by exit, since the install (if any) has already printed its own
# ending.
probe_after_install() {
    STEP_TOTAL=6
    if [ -n "$PROBE_PENDING" ]; then
        PROBE_PENDING=""
        print_banner "PROBE GAME SETTINGS"
        probe_snap 2
        PROBE_STAGE="installed"; probe_save_session
    fi

    if [ "$PROBE_STAGE" == "installed" ]; then
        print_step 4 "Second Run: Sound Options"
        probe_run_game "Switch on $PROBE_NAME's EAX and 3D sound options (and anything else that belongs with" \
            "them, like a hardware sound or surround setting), then quit from the main menu." || exit 0
        probe_snap 3
        PROBE_STAGE="changed"; probe_save_session
    fi

    if [ "$PROBE_STAGE" == "changed" ]; then
        print_step 5 "Sound Settings"
        print_paragraph "This step compares the snapshots from each run and proposes the audio settings for" \
            "$PROBE_NAME's database entry."
        print_subheading "Files $PROBE_NAME created on its first run"
        local created
        created="$(cd "$PROBE_SESSION_DIR/1/files" 2>/dev/null && find . -type f | sort | while IFS= read -r f; do
            [ -f "$PROBE_SESSION_DIR/0/files/${f#./}" ] || echo "  /${f#./}"
        done)"
        echo -e "${WHITE}${created:-  (none — they all existed before snapshot 0)}${NC}"

        if ! cmp -s <(cd "$PROBE_SESSION_DIR/1/files" && find . -type f -exec md5sum {} + | sort) \
            <(cd "$PROBE_SESSION_DIR/2/files" && find . -type f -exec md5sum {} + | sort); then
            print_subheading "What the install changed"
            probe_propose 1 2 || true
        fi

        print_subheading "What changed in the second run"
        if probe_propose 2 3; then
            echo ""
            probe_merge audio
        else
            probe_nothing_changed second
        fi
        PROBE_STAGE="proposed"; probe_save_session
    fi

    if [ "$PROBE_STAGE" == "proposed" ]; then
        print_step 6 "Third Run: Optional Settings"
        print_paragraph "Optional settings are changes that aren't needed for EAX but are worth offering, like" \
            "a texture quality fix. A third launch captures them the same way."
        if confirm "Launch $PROBE_NAME a third time for optional settings?" Y; then
            probe_run_game "Change the options worth offering as optional settings, leave the sound options" \
                "as they are, then quit from the main menu." || exit 0
            probe_snap 4
            PROBE_STAGE="optional"; probe_save_session
        else
            PROBE_STAGE="done"; probe_save_session
        fi
    fi

    if [ "$PROBE_STAGE" == "optional" ]; then
        print_subheading "What changed in the third run"
        if probe_propose 3 4; then
            echo ""
            probe_merge optional
        else
            probe_nothing_changed third
        fi
        PROBE_STAGE="done"; probe_save_session
    fi
    print_status "Snapshots kept in $(tilde_path "$PROBE_SESSION_DIR")." "$DIM"
    exit 0
}

# Usage: probe_nothing_changed <second|third>
# When a run changed nothing a setting can hold, says why that might be.
probe_nothing_changed() {
    if [ -n "$PROBE_REG_CHANGED" ]; then
        print_note "nothing the database can change was switched in the $1 run: the registry values" \
            "listed above are a type a game setting can't hold."
    else
        print_note "nothing changed in $PROBE_NAME's config files or registry keys in the $1 run." \
            "Check the options were saved: some games only save them when you quit from their menu."
    fi
}

if [ -n "$PROBE_TOOL_MODE" ]; then
    print_banner "PROBE GAME SETTINGS"
    tool_gate "This launches a game twice around an install of the EAX fix (and a third time for" \
        "optional settings, if you like), compares its config files and registry, then proposes the game" \
        "settings for its database entry." \
        || { OPEN_TOOLS_MENU=1; continue; }
    probe_session || { OPEN_TOOLS_MENU=1; continue; }
fi
