ensure_game_database() {
    # Usage: ensure_game_database
    # Fetches game-database.json fresh into a temp file, validates it's
    # well-formed JSON, then promotes it over the cached copy — never
    # overwrites a good cache with a truncated/bad response. Falls back to
    # the last-good cache if the fetch or validation fails, and to nothing
    # (GAME_DATABASE_FILE stays empty, return 1) if there's no usable cache
    # either. Memoized per run via GAME_DATABASE_FILE on success — but this
    # function is called several times per install (notes, no-op warning,
    # Audio API Detection), so a *failure* is memoized too via
    # GAME_DATABASE_ATTEMPTED, otherwise a genuinely offline run retries the
    # full fetch (10s timeout each) and reprints the same failure message
    # on every single call instead of once.
    #
    # EAX_RESTORE_GAME_DATABASE_FILE points this at a local file instead of
    # fetching — for testing schema/data edits to game-database.json
    # before they've been pushed to the branch GAME_DATABASE_URL fetches from.
    [ -n "$GAME_DATABASE_FILE" ] && return 0
    [ -n "$GAME_DATABASE_ATTEMPTED" ] && return 1
    GAME_DATABASE_ATTEMPTED=1
    command -v jq &> /dev/null || return 1

    if [ -n "${EAX_RESTORE_GAME_DATABASE_FILE:-}" ]; then
        if [ -s "$EAX_RESTORE_GAME_DATABASE_FILE" ] && jq empty "$EAX_RESTORE_GAME_DATABASE_FILE" 2>/dev/null; then
            GAME_DATABASE_FILE="$EAX_RESTORE_GAME_DATABASE_FILE"
            print_note "Using a local game database file:" "$EAX_RESTORE_GAME_DATABASE_FILE" >&2
        else
            print_error "EAX_RESTORE_GAME_DATABASE_FILE is set but the file is missing or not valid JSON." >&2
            return 1
        fi
    else
        # Small (~100 KB, ~13 KB compressed), so a status line before and
        # the result after rather than a progress bar — enough to explain a
        # slow network's pause. On stderr, like this function's other
        # messages, since some callers capture stdout.
        # Only fetched when it changed: GitHub sends an ETag with the file,
        # kept next to the cache, and answers a request carrying it with an
        # empty 304 when nothing changed. --compressed asks for gzip.
        local tmp hdr code etag="" cache_ok=0
        local -a if_changed=()
        # The cache's name before the database was renamed; nothing reads it.
        rm -f "$BASE_SHARE/known-eax-games.v3.json" 2>/dev/null
        print_task "Updating the game database" >&2
        [ -s "$GAME_DATABASE_CACHE" ] && jq empty "$GAME_DATABASE_CACHE" 2>/dev/null && cache_ok=1
        [ "$cache_ok" -eq 1 ] && etag="$(cat "$GAME_DATABASE_CACHE.etag" 2>/dev/null)"
        [ -n "$etag" ] && if_changed=(-H "If-None-Match: $etag")
        tmp=$(mktemp 2>/dev/null); hdr=$(mktemp 2>/dev/null)
        code=""
        if [ -n "$tmp" ] && [ -n "$hdr" ]; then
            code=$(curl -fsSL --compressed --max-time 10 "${if_changed[@]}" -D "$hdr" -o "$tmp" \
                -w '%{http_code}' "$GAME_DATABASE_URL" 2>/dev/null)
        fi
        if [ "$code" == "200" ] && jq empty "$tmp" 2>/dev/null; then
            mkdir -p "$BASE_SHARE" 2>/dev/null
            mv "$tmp" "$GAME_DATABASE_CACHE"
            etag="$(grep -i '^etag:' "$hdr" | tail -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r')"
            if [ -n "$etag" ]; then printf '%s\n' "$etag" > "$GAME_DATABASE_CACHE.etag"
            else rm -f "$GAME_DATABASE_CACHE.etag"; fi
            rm -f "$hdr"
            GAME_DATABASE_FILE="$GAME_DATABASE_CACHE"
            print_status "Updated: $(jq '.games | length' "$GAME_DATABASE_FILE" 2>/dev/null) games" "$GREEN" >&2
        elif [ "$code" == "304" ] && [ "$cache_ok" -eq 1 ]; then
            # Unchanged: the cache's date now says when it was last checked.
            rm -f "$tmp" "$hdr"
            touch "$GAME_DATABASE_CACHE" 2>/dev/null
            GAME_DATABASE_FILE="$GAME_DATABASE_CACHE"
            print_status "Up to date: $(jq '.games | length' "$GAME_DATABASE_FILE" 2>/dev/null) games" "$GREEN" >&2
        else
            rm -f "$tmp" "$hdr" 2>/dev/null
            if [ "$cache_ok" -eq 1 ]; then
                GAME_DATABASE_FILE="$GAME_DATABASE_CACHE"
                print_status "Couldn't reach GitHub, so the copy from $(date -r "$GAME_DATABASE_CACHE" +%F) is used." "$YELLOW" >&2
            else
                # The first call is the pre-flight check's, so this shows
                # under its STATUS header before the main menu, which then
                # leaves out what needs the database. Later callers still
                # say what's missing in their own step.
                print_status "Couldn't reach GitHub and there's no saved copy, so scanning and optional settings are hidden." "$YELLOW" >&2
                return 1
            fi
        fi
    fi

    # The database schema evolves alongside this script. If the loaded copy
    # predates the schema this version expects (served from a branch that
    # hasn't merged a schema change yet, or a stale offline cache), several
    # checks below silently fall back to a default instead of erroring —
    # jq's `//` can't tell "key legitimately absent" from "key doesn't
    # exist in this schema yet" apart. Warn once so that's visible instead
    # of a checkbox that quietly never fires.
    if ! jq -e --argjson want "$GAME_DATABASE_SCHEMA_VERSION" \
        '(.schema_version // 1) >= $want' "$GAME_DATABASE_FILE" >/dev/null 2>&1; then
        { echo ""; print_warning_arrow "$GAME_DATABASE_FILE predates the schema this script version expects" \
            "— it looks like an older database. Audio API Detection, the game details and" \
            "the Game Settings step won't work correctly until it updates."; } >&2
    fi

    return 0
}

# Usage: manifest_is_live <game dir>
# True when the folder holds this script's install: a non-empty manifest that
# isn't the "uninstalled" marker.
manifest_is_live() {
    local m="$1/.eax-restore-manifest.txt"
    [ -s "$m" ] && ! head -n 1 "$m" | grep -q "^# EAX Restore: uninstalled"
}

# Usage: steam_library_dirs
# Every Steam library's steamapps folder, one per line: each Steam root's own
# plus the "path" entries in its libraryfolders.vdf, without repeats.
steam_library_dirs() {
    local root vdf extra
    local -A seen=()
    for root in "$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
        if [ -d "$root/steamapps" ] && [ -z "${seen["$root/steamapps"]:-}" ]; then
            printf '%s\n' "$root/steamapps"; seen["$root/steamapps"]=1
        fi
        vdf="$root/steamapps/libraryfolders.vdf"
        [ -f "$vdf" ] || continue
        while IFS= read -r extra; do
            [ -n "$extra" ] || continue
            if [ -d "$extra/steamapps" ] && [ -z "${seen["$extra/steamapps"]:-}" ]; then
                printf '%s\n' "$extra/steamapps"; seen["$extra/steamapps"]=1
            fi
        done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf" 2>/dev/null)
    done
}

# Usage: find_installed_game_dirs
# Every game folder holding this script's live install, found on disk: under
# each Steam library's steamapps/common, and under every Heroic game folder —
# its default install folder plus the GOG, Epic and sideloaded installs it
# records (native and Flatpak). One folder per line.
find_installed_game_dirs() {
    local lib conf m
    {
        while IFS= read -r lib; do
            find "$lib/common" -mindepth 2 -maxdepth 5 -name .eax-restore-manifest.txt 2>/dev/null
        done < <(steam_library_dirs)
        for conf in "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic"; do
            [ -d "$conf" ] || continue
            {
                jq -r '.defaultSettings.defaultInstallPath // empty' "$conf/config.json" 2>/dev/null
                jq -r '.installed[]?.install_path // empty' "$conf/gog_store/installed.json" 2>/dev/null
                jq -r '.[]?.install_path // empty' "$conf/legendaryConfig/legendary/installed.json" 2>/dev/null
                jq -r '.games[]?.folder_name // empty' "$conf/sideload_apps/library.json" 2>/dev/null
            } | sort -u | while IFS= read -r lib; do
                [ -d "$lib" ] && find "$lib" -maxdepth 5 -name .eax-restore-manifest.txt 2>/dev/null
            done
        done
    } | while IFS= read -r m; do
        m="$(dirname "$m")"
        manifest_is_live "$m" && printf '%s\n' "$m"
    done | sort -u
}

# Usage: migrate_recent_games
# Moves the old recent-games history ($BASE_SHARE/recent_games.txt) into
# INSTALLED_GAMES_FILE once: entries already in the new file stay first (they
# were used since), then the old file's in their order; the old file is then
# deleted. Run by both note_game_used and installed_game_dirs, so whichever
# comes first in a run does it.
migrate_recent_games() {
    local old="$BASE_SHARE/recent_games.txt" tmp
    [ -f "$old" ] || return 0
    mkdir -p "$(dirname "$INSTALLED_GAMES_FILE")" 2>/dev/null || return 0
    tmp=$(mktemp 2>/dev/null) || return 0
    {
        [ -f "$INSTALLED_GAMES_FILE" ] && cat "$INSTALLED_GAMES_FILE"
        if [ -s "$INSTALLED_GAMES_FILE" ]; then grep -Fxv -f "$INSTALLED_GAMES_FILE" -- "$old"; else cat "$old"; fi
    } > "$tmp" 2>/dev/null
    if mv "$tmp" "$INSTALLED_GAMES_FILE" 2>/dev/null; then rm -f "$old"; else rm -f "$tmp"; fi
}

# Usage: note_game_used <game dir>
# Moves a game folder to the top of INSTALLED_GAMES_FILE (most recently used
# first, no repeats, no limit), which only orders the installed-games list;
# what's installed comes from the manifests (installed_game_dirs).
# Best-effort: never blocks anything if it can't write.
note_game_used() {
    local path="$1" tmp
    [ -n "$path" ] || return 0
    migrate_recent_games
    mkdir -p "$(dirname "$INSTALLED_GAMES_FILE")" 2>/dev/null || return 0
    tmp=$(mktemp 2>/dev/null) || return 0
    { printf '%s\n' "$path"; [ -f "$INSTALLED_GAMES_FILE" ] && grep -Fxv -- "$path" "$INSTALLED_GAMES_FILE"; } > "$tmp" 2>/dev/null
    mv "$tmp" "$INSTALLED_GAMES_FILE" 2>/dev/null || rm -f "$tmp"
}

# Usage: installed_game_dirs
# The games this script is installed in, one folder per line: the ones in
# INSTALLED_GAMES_FILE first, in its most-recently-used order, then any
# found on disk (find_installed_game_dirs) it doesn't list yet, by name.
# Folders whose install is gone drop out, and the file is rewritten to match.
# The old recent-games history is folded in first (migrate_recent_games).
installed_game_dirs() {
    local p tmp
    local -a ordered=() found=()
    local -A seen=()
    migrate_recent_games
    if [ -f "$INSTALLED_GAMES_FILE" ]; then
        while IFS= read -r p; do
            if [ -n "$p" ] && [ -z "${seen[$p]:-}" ] && manifest_is_live "$p"; then
                ordered+=("$p"); seen[$p]=1
            fi
        done < "$INSTALLED_GAMES_FILE"
    fi
    while IFS= read -r p; do
        [ -n "$p" ] && [ -z "${seen[$p]:-}" ] || continue
        identify_game_dir "$p"
        found+=("${GAME_ID_NAME:-$(basename "$p")}"$'\t'"$p"); seen[$p]=1
    done < <(find_installed_game_dirs)
    if [ ${#found[@]} -gt 0 ]; then
        while IFS=$'\t' read -r _ p; do ordered+=("$p"); done < <(printf '%s\n' "${found[@]}" | sort -f -t$'\t' -k1,1)
    fi
    if mkdir -p "$(dirname "$INSTALLED_GAMES_FILE")" 2>/dev/null && tmp=$(mktemp 2>/dev/null); then
        [ ${#ordered[@]} -gt 0 ] && printf '%s\n' "${ordered[@]}" > "$tmp"
        mv "$tmp" "$INSTALLED_GAMES_FILE" 2>/dev/null || rm -f "$tmp"
    fi
    [ ${#ordered[@]} -gt 0 ] && printf '%s\n' "${ordered[@]}"
    return 0
}

prompt_installed_game() {
    # Usage: prompt_installed_game
    # Uninstall's and Tools' game list: the games this script is installed in
    # (installed_game_dirs), most recently used first, plus the options to
    # browse for or type another folder.
    # Sets GAME_DIR and returns 0 if the user picked an entry;
    # returns 1 with RESTART_REQUESTED set for [R]eturn;
    # returns 1 with LOCATE_METHOD set (gui or manual) for [B]rowse or
    # [M]anually, so get_game_directory goes straight there; returns 1 with
    # neither when nothing is installed, and step 1's menu is shown.
    GAME_DIR=""
    local -a paths=()
    local p
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(installed_game_dirs)
    [ ${#paths[@]} -eq 0 ] && return 1

    echo -e "${WHITE}Games with something installed via this script:${NC}"
    # One line per game, its name and storefront like the library scan's
    # list; a folder is added only under entries that would otherwise read
    # the same, and shown on its own for a folder that can't be placed.
    local i
    local -a labels=() details=()
    local -A seen=()
    for i in "${!paths[@]}"; do
        if identify_game_dir "${paths[$i]}" && [ -n "$GAME_ID_NAME" ]; then
            labels[i]="$GAME_ID_NAME"
            details[i]="(Steam)"; [ "$GAME_ID_STORE" == "gog" ] && details[i]="(GOG)"
        else
            labels[i]="${paths[$i]}"; details[i]=""
        fi
        seen["${labels[i]}${details[i]}"]=$(( ${seen["${labels[i]}${details[i]}"]:-0} + 1 ))
    done
    for i in "${!paths[@]}"; do
        print_option "$((i + 1))" "${labels[i]}" "${details[i]}"
        if [ -n "${details[i]}" ] && [ "${seen["${labels[i]}${details[i]}"]}" -gt 1 ]; then
            echo -e "    ${DIM}$(tilde_path "${paths[$i]}")${NC}"
        fi
    done
    # Another game: the same ways step 1's own menu offers, chosen here so
    # get_game_directory goes straight to it (LOCATE_METHOD).
    local -a keys=()
    echo ""
    if gui_picker_available; then
        print_key_option "[B]rowse for the game folder"; keys+=(b)
    fi
    print_key_option "[M]anually type the game path"; keys+=(m)
    # The way back to the main menu, as step 1's own menu offers it (see
    # MAIN_MENU_SHOWN); get_game_directory unwinds on RESTART_REQUESTED.
    if [ -n "$MAIN_MENU_SHOWN" ]; then
        echo ""
        print_key_option "[R]eturn to the $(return_menu_label)"; keys+=(r)
    fi

    local choice
    while true; do
        local nums="1-${#paths[@]}"
        [ ${#paths[@]} -eq 1 ] && nums="1"
        prompt "Selection [${nums}/$(IFS=/; echo "${keys[*]}")]: "
        read_answer choice || return 1
        choice="${choice,,}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#paths[@]} ]; then
            GAME_DIR="${paths[$((choice - 1))]}"
            return 0
        fi
        [[ " ${keys[*]} " == *" $choice "* ]] && break
        print_result "That's not a valid option — please type $( [ ${#paths[@]} -eq 1 ] && echo "1" || echo "a number from 1-${#paths[@]}"), $(join_choices "${keys[@]}")." "$YELLOW"
    done
    case "$choice" in
        b) LOCATE_METHOD="gui" ;;
        m) LOCATE_METHOD="manual" ;;
        r) RESTART_REQUESTED=1 ;;
    esac
    return 1
}

game_eax_status() {
    # Usage: game_eax_status <id> <steam|gog>
    # The entry's eax.status ("supported" when it has none), or nothing when
    # the game isn't in the database.
    jq -r --arg id "$1" --arg store "$2" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.status // "supported"' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1
}

confirm_built_in_install() {
    # Usage: confirm_built_in_install <game_name>
    # For an eax.status "built_in" game (EAX already works without this
    # script, e.g. an edition that ships its own OpenAL32.dll with EAX).
    # Installing still swaps in a newer OpenAL32.dll and adds alsoft.ini, so
    # it's offered, but defaults to No. Asked once per game: a Yes sets
    # BUILT_IN_CONFIRMED so confirm_continue_if_eax_impossible doesn't ask
    # again after the prefix step. Right after show_game_details_block, its
    # Status block has already said all this, so only the question is asked.
    if [ -z "$SCANNED_NOTES_SHOWN" ]; then
        print_note "${1:-This game} already has working EAX reverb" \
            "through its own OpenAL Soft. Installing is optional: it swaps in a newer" \
            "OpenAL Soft and adds speaker and headphone settings."
    fi
    confirm "Install anyway?" N || return 1
    BUILT_IN_CONFIRMED=1
}

block_if_eax_not_implemented() {
    # Usage: block_if_eax_not_implemented <id> <steam|gog> <game_name>
    # Early twin of confirm_continue_if_eax_impossible's hard-block branches
    # (not_implemented, and removed_by_patch without eax.fix_in_place)
    # — called right after the scan pick so a known dead end is caught before
    # wasting the user's time on AppID/prefix detection. On a match it hands
    # off to prompt_restart_or_quit, which either exits or sets
    # RESTART_REQUESTED for scan_game_libraries to unwind on.
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return
    ensure_game_database || return

    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local status workaround
    status=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.status // "supported"' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    workaround=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.fix_in_place // false' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)

    if [ "$status" == "not_implemented" ]; then
        if [ -n "$SCANNED_NOTES_SHOWN" ]; then
            print_eax_block_error "$1" "$store"
        else
            print_error "$3 never implemented EAX/environmental audio in the first place, so" \
                "there would be nothing here for this script to restore."
        fi
        prompt_restart_or_quit 1
        return
    fi

    if [ "$status" == "removed_by_patch" ] && [ "$workaround" != "true" ]; then
        if [ -n "$SCANNED_NOTES_SHOWN" ]; then
            print_eax_block_error "$1" "$store"
        else
            print_error "EAX/A3D support was removed from $3's current build by a software update," \
                "and there's no known in-place fix — restoring it would need a separate install this" \
                "script isn't pointed at."
        fi
        prompt_restart_or_quit 1
        return
    fi
}

# Usage: print_eax_block_error <id> <steam|gog>
# The hard block's error when the GAME PROFILE was just shown: its Status
# already says why, so this only names the game (as the profile does) and
# the outcome.
print_eax_block_error() {
    local name
    name=$(jq -r --arg id "$1" --arg store "$2" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .name' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    print_error "There's nothing for this script to restore in ${name:-this game}."
}

detect_steam_beta_branch() {
    # Usage: detect_steam_beta_branch <acf_file>
    # Echoes the appmanifest's opted-in/mounted Steam beta branch ("BetaKey"),
    # or nothing if there isn't one. Both "MountedConfig" (the branch actually
    # installed — only present once Steam finishes updating to it) and
    # "UserConfig" (the branch selected, which may not be downloaded yet)
    # carry a same-named "BetaKey" key, so a plain grep across the whole file
    # can't tell them apart — awk scopes the match to whichever block it's
    # inside. MountedConfig wins when both are present since it reflects the
    # actually-installed content, which is what the game will actually run.
    local acf="$1"
    [ -f "$acf" ] || return
    local key
    key=$(awk '/"MountedConfig"/{f=1} f&&/"BetaKey"/{print;exit}' "$acf" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"BetaKey"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')
    if [ -z "$key" ]; then
        key=$(awk '/"UserConfig"/{f=1} f&&/"BetaKey"/{print;exit}' "$acf" 2>/dev/null \
            | sed -n 's/^[[:space:]]*"BetaKey"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')
    fi
    echo "$key"
}

scan_game_libraries() {
    # Usage: scan_game_libraries
    # Opt-in alternative to browsing/typing a path: scans Steam and Heroic
    # libraries for games present in game-database.json, lists the
    # matches, and resolves the pick's actual .exe folder (via
    # resolve_exe_folder) into GAME_DIR. Also sets SCANNED_APPID so
    # detect_game_environment's Steam branch can skip its own redundant
    # AppID search/confirmation. Returns 1 (GAME_DIR left empty) if nothing
    # was found or picked, so get_game_directory falls through to its
    # normal manual/GUI-picker flow.
    SCAN_NEXT=""
    GAME_DIR=""
    GAME_NAME=""
    GAME_INSTALL_ROOT=""
    SCANNED_APPID=""
    SCANNED_NOTES_SHOWN=""
    BUILT_IN_CONFIRMED=""
    OPENAL_NATIVE_MODE=""
    EAX_UNIFIED=""
    RECOMMENDED_AUDIO_LIMITS=""
    RECOMMENDED_COM_ROUTING=""
    RECOMMENDED_TWEAKS_RESOLVED=""

    if ! ensure_game_database; then
        print_note "library scanning needs the game database, which isn't available this run."
        echo ""
        return 1
    fi

    print_task "Scanning Steam and Heroic libraries for games with a profile"

    # names[] is the curated game-database.json display name, used only for
    # the pick-list menu below. meta_names[] is the name as reported by the
    # game's OWN install metadata (the Steam appmanifest's "name" key, or the
    # GOG/Heroic install folder itself) — sourced the same way appid/gog_id
    # already are, independent of the JSON — and becomes GAME_NAME once a
    # pick is made, for use in prompts that need the actual game's name.
    local names=() meta_names=() paths=() stores=() ids=()

    # --- Steam ---
    local steam_ids
    steam_ids=$(jq -r '.games[] | select(.stores.steam.id != null) | .stores.steam.id' "$GAME_DATABASE_FILE" 2>/dev/null)
    if [ -n "$steam_ids" ]; then
        local libs=() lib
        while IFS= read -r lib; do libs+=("$lib"); done < <(steam_library_dirs)
        print_status "Checking ${#libs[@]} Steam library folder(s)..." ""

        local acf appid installdir name meta_name
        for lib in "${libs[@]}"; do
            for acf in "$lib"/appmanifest_*.acf; do
                [ -f "$acf" ] || continue
                appid=$(basename "$acf" | tr -dc '0-9')
                [ -z "$appid" ] && continue
                echo "$steam_ids" | grep -qx "$appid" || continue
                installdir=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" 2>/dev/null | head -n 1)
                [ -n "$installdir" ] && [ -d "$lib/common/$installdir" ] || continue
                name=$(jq -r --arg id "$appid" '.games[] | select((.stores.steam.id | tostring) == $id) | .name' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
                [ -z "$name" ] && name="AppID $appid"
                meta_name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" 2>/dev/null | head -n 1)
                [ -z "$meta_name" ] && meta_name="AppID $appid"
                names+=("$name")
                meta_names+=("$meta_name")
                paths+=("$lib/common/$installdir")
                stores+=("steam")
                ids+=("$appid")
            done
        done
    fi

    # --- Heroic ---
    local gog_ids
    gog_ids=$(jq -r '.games[] | select(.stores.gog.id != null) | .stores.gog.id' "$GAME_DATABASE_FILE" 2>/dev/null)
    if [ -n "$gog_ids" ]; then
        local installed_jsons
        installed_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)
        print_status "Checking Heroic installed.json files..." ""
        local json_file install_path app_name name meta_name
        while IFS= read -r json_file; do
            [ -z "$json_file" ] && continue
            while IFS=$'\t' read -r install_path app_name; do
                [ -z "$install_path" ] || [ -z "$app_name" ] && continue
                echo "$gog_ids" | grep -qx "$app_name" || continue
                [ -d "$install_path" ] || continue
                name=$(jq -r --arg id "$app_name" '.games[] | select((.stores.gog.id | tostring) == $id) | .name' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
                [ -z "$name" ] && name="GOG ID $app_name"
                meta_name="$(basename "$install_path")"
                [ -z "$meta_name" ] && meta_name="GOG ID $app_name"
                names+=("$name")
                meta_names+=("$meta_name")
                paths+=("$install_path")
                stores+=("gog")
                ids+=("$app_name")
            done < <(awk 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"(install_path|installPath)"/) { line=$i; sub(/^.*"(install_path|installPath)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); ip=line } if ($i ~ /"(app_name|appName)"/) { line=$i; sub(/^.*"(app_name|appName)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); an=line } } if (ip != "") print ip "\t" an }' "$json_file")
        done <<< "$installed_jsons"
    fi

    if [ ${#names[@]} -eq 0 ]; then
        print_warning "No games with a profile were found in your Steam or Heroic libraries."
        print_note "this only checks the community-maintained game database, which currently" \
            "covers a small, hand-verified set of titles — it will grow over time. A game" \
            "you own may still support EAX even if it's not listed yet."
        return 1
    fi

    # Discovery order is appmanifest glob order (AppIDs compared as text)
    # with Heroic tacked on after, which means nothing to someone scanning
    # the list by eye -- sort by display name instead, Steam before GOG for
    # a title owned on both.
    local i order=() s_names=() s_meta=() s_paths=() s_stores=() s_ids=()
    while IFS= read -r i; do order+=("$i"); done < <(
        for i in "${!names[@]}"; do printf '%s\t%s\t%d\n' "${names[$i]}" "${stores[$i]}" "$i"; done \
            | sort -f -t$'\t' -k1,1 -k2,2r | cut -f3)
    for i in "${order[@]}"; do
        s_names+=("${names[$i]}"); s_meta+=("${meta_names[$i]}"); s_paths+=("${paths[$i]}")
        s_stores+=("${stores[$i]}"); s_ids+=("${ids[$i]}")
    done
    names=("${s_names[@]}"); meta_names=("${s_meta[@]}"); paths=("${s_paths[@]}")
    stores=("${s_stores[@]}"); ids=("${s_ids[@]}")

    # A long list goes in pages (paged_select). Not in the list: type the
    # path instead, or go back (SCAN_NEXT tells get_game_directory which).
    PAGED_LABELS=("${names[@]}"); PAGED_DETAILS=()
    for i in "${!stores[@]}"; do
        if [ "${stores[$i]}" == "gog" ]; then PAGED_DETAILS+=("(GOG)"); else PAGED_DETAILS+=("(Steam)"); fi
    done
    local -a extra=("m|[M]anually type the game path")
    [ -n "$MAIN_MENU_SHOWN" ] && extra+=("|" "r|[R]eturn to the $(return_menu_label)")
    paged_select "Games with a profile in your libraries" "${extra[@]}" || exit 0
    case "$PAGED_CHOICE" in
        m) SCAN_NEXT="manual"; return 1 ;;
        r) SCAN_NEXT="return"; return 1 ;;
    esac
    local choice="$PAGED_CHOICE"

    local idx=$((choice - 1))

    show_game_details_block "${ids[$idx]}" "${stores[$idx]}" "${paths[$idx]}"
    block_if_eax_not_implemented "${ids[$idx]}" "${stores[$idx]}" "${meta_names[$idx]}"
    # User chose "pick a different game" at the EAX-impossible prompt — bail
    # back to get_game_directory's menu instead of asking to continue with it.
    [ -n "$RESTART_REQUESTED" ] && return 1

    if [ "$(game_eax_status "${ids[$idx]}" "${stores[$idx]}")" == "built_in" ]; then
        confirm_built_in_install "${meta_names[$idx]}" || return 1
    else
        confirm "Continue with this game?" || return 1
    fi

    GAME_NAME="${meta_names[$idx]}"

    local beta_branch="" exe_name
    if [ "${stores[$idx]}" == "steam" ]; then
        beta_branch=$(jq -r --arg id "${ids[$idx]}" \
            '.games[] | select((.stores.steam.id // "") | tostring == $id) | .stores.steam.beta_branch // empty' \
            "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    fi
    exe_name=$(jq -r --arg id "${ids[$idx]}" --arg store "${stores[$idx]}" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .exe // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    resolve_exe_folder "${paths[$idx]}" "$beta_branch" "$exe_name" || return 1
    GAME_INSTALL_ROOT="${paths[$idx]}"

    [ "${stores[$idx]}" == "steam" ] && SCANNED_APPID="${ids[$idx]}"
    return 0
}

# Per-game notes and EAX-impossible flags now live in the community-
# maintained game-database.json (see ensure_game_database above and
# game-database.json in this repo) rather than hardcoded here, so entries
# can be added/corrected via PR without touching this script. Entries are
# still only added when independently verified against the storefront's
# own API — a wrong/stale ID would misdirect users to the wrong game.

resolve_recommended_tweaks() {
    # Usage: resolve_recommended_tweaks <id> <steam|gog>
    # Reads the game profile's install.tweaks array once and sets
    # EAX_UNIFIED / RECOMMENDED_AUDIO_LIMITS / RECOMMENDED_COM_ROUTING to 1
    # (else "") based on membership of "eax_unified" / "expand_audio_limits" /
    # "com_registry_routing" respectively — the ~32 titles that reach EAX
    # through Creative's eax.dll shim, plus any game independently verified to
    # need the Expand Audio Limits or COM Registry Routing tweaks specifically.
    # Cheap and idempotent — safe to call from more than one step.
    # show_game_details_block calls it for the common (matched) path; the
    # Advanced Compatibility Tweaks step calls it too (guarded on
    # RECOMMENDED_TWEAKS_RESOLVED) so the pre-handled tweak sub-flows still
    # fire when the user skipped the Audio API Detection database check.
    EAX_UNIFIED=""
    RECOMMENDED_AUDIO_LIMITS=""
    RECOMMENDED_COM_ROUTING=""
    RECOMMENDED_TWEAKS_RESOLVED=1
    [ -z "$1" ] && return
    ensure_game_database || return
    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local tweaks
    tweaks=$(jq -r --arg id "$1" --arg store "$store" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)][0] | .install.tweaks // [] | .[]' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
    [ -z "$tweaks" ] && return
    grep -qx "eax_unified" <<< "$tweaks" && EAX_UNIFIED=1
    grep -qx "expand_audio_limits" <<< "$tweaks" && RECOMMENDED_AUDIO_LIMITS=1
    grep -qx "com_registry_routing" <<< "$tweaks" && RECOMMENDED_COM_ROUTING=1
}

resolve_extra_exe_folders() {
    # Usage: resolve_extra_exe_folders <id> <steam|gog>
    # Sets EXTRA_GAME_DIRS to the store's extra_exe_folders that exist under
    # GAME_DIR (matched case-insensitively, like the DLLs). These are folders
    # holding another exe launched from the same title — e.g. GOG's F.E.A.R.
    # Platinum starts its expansions from FEARXP/ and FEARXP2/ — so each needs
    # its own copy of the game-folder files, while the prefix, registry and
    # launcher override are already shared. A folder missing from this build
    # is skipped without a word.
    EXTRA_GAME_DIRS=()
    [ -n "$1" ] && [ -n "$GAME_DIR" ] || return 0
    ensure_game_database || return 0
    local rel dir
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [[ "$rel" == /* || "$rel" == *..* || "$rel" == *\\* ]] && continue
        dir="$(find_existing_variant "$GAME_DIR/$rel")"
        [ -n "$dir" ] && [ -d "$dir" ] && EXTRA_GAME_DIRS+=("$dir")
    done < <(jq -r --arg id "$1" --arg store "$2" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)][0] | .stores[$store].extra_exe_folders // [] | .[]' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
}

# Usage: extra_exe_folders_list
# The EXTRA_GAME_DIRS folder names joined for prose: "A", "A and B", "A, B and C".
extra_exe_folders_list() {
    local n=${#EXTRA_GAME_DIRS[@]} i out=""
    for (( i = 0; i < n; i++ )); do
        if [ "$i" -eq 0 ]; then out="$(basename "${EXTRA_GAME_DIRS[$i]}")"
        elif [ "$i" -eq $((n - 1)) ]; then out+=" and $(basename "${EXTRA_GAME_DIRS[$i]}")"
        else out+=", $(basename "${EXTRA_GAME_DIRS[$i]}")"; fi
    done
    echo "$out"
}

show_game_details_block() {
    # Usage: show_game_details_block <id> <steam|gog> <location>
    # The richer "--- GAME PROFILE ---" banner scan_game_libraries shows when
    # a game is picked from a library scan, factored out so the manual/GUI
    # path can show the same thing once detect_game_environment has confirmed
    # a prefix and therefore knows the id to look this up by (see
    # show_profile_if_unseen, ahead of the EAX status check). Only prints
    # when game-database.json actually has a matching entry — an unmatched
    # manual pick has nothing to show, same as before this existed. The
    # screen itself is print_game_profile; this adds what the install reads
    # back from it (PROFILE_API, PROFILE_PATCHES, the recommended tweaks).
    local id="$1" store="$2" location="$3"
    PROFILE_API=""
    PROFILE_PATCHES=""
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$id" ] && return
    ensure_game_database || return

    local match_count
    match_count=$(jq -r --arg id "$id" --arg store "$store" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)] | length' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
    [ "${match_count:-0}" -gt 0 ] || return

    PROFILE_API=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | (.stores[$store].api // .eax.api // "directsound3d")' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    # The first match's whole text, not its first line: patches can hold a
    # line break between suggestions.
    PROFILE_PATCHES=$(jq -r --arg id "$id" --arg store "$store" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)][0].stores[$store].patches // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
    resolve_recommended_tweaks "$id" "$store"

    print_banner "GAME PROFILE"
    print_game_profile "$id" "$store" "$location"
    SCANNED_NOTES_SHOWN=1
}

# Usage: format_release_date <YYYY-MM-DD | YYYY-MM | YYYY>
# A game's release date as the profile shows it: "23 June 2000",
# "June 2000" or "2000", depending on how much of it is known.
format_release_date() {
    local -a months=(January February March April May June July August September October November December)
    local y m d
    IFS=- read -r y m d <<< "$1"
    if [ -n "$d" ]; then printf '%d %s %s' "$((10#$d))" "${months[$((10#$m - 1))]}" "$y"
    elif [ -n "$m" ]; then printf '%s %s' "${months[$((10#$m - 1))]}" "$y"
    else printf '%s' "$y"; fi
}

print_game_profile() {
    # Usage: print_game_profile <id> <steam|gog> [location]
    # The GAME PROFILE screen's body for one store's entry; see
    # print_game_profile_stores.
    print_game_profile_stores "${3:-}" "$2:$1"
}

print_game_profile_stores() {
    # Usage: print_game_profile_stores <location> <store>:<id> [<store>:<id> ...]
    # The GAME PROFILE screen's body, read straight from GAME_DATABASE_FILE;
    # the caller prints the banner above it (the database browser's pane has
    # its own label instead). Output only — it sets nothing — so the browser
    # can draw it outside an install. Each <store>:<id> is one of the game's
    # store entries: the install passes the one it found, the browser every
    # one that passes its filters. With more than one, what the stores share
    # (most of it, since it's stored once per game) is shown once, and only
    # what differs (the audio API, store details, patches, delisted) per
    # store. With a location (the install) the fields end with "System
    # details" (where this install was found); without one (the browser),
    # each store's ID gets a row under the name, and a Description section
    # follows the fields.
    local location="$1"; shift
    local -a stores=() ids=() labels=() apis=() listings=() id_sources=() details=() patches=() counts=()
    local entry
    for entry in "$@"; do
        stores+=("${entry%%:*}"); ids+=("${entry#*:}")
        [ "${entry%%:*}" == "gog" ] && labels+=("GOG") || labels+=("Steam")
    done
    local n=${#stores[@]} i id="${ids[0]}" store="${stores[0]}"

    # Game-level fields: the same for every store entry, so read from the
    # first.
    local name eax_versions eax_status eax_status_details restore_details eax_unified notes
    local released description
    name=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .name' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    released=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .released // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    description=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .description // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    eax_versions=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.versions // [] | join(", ")' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    eax_status=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.status // "supported"' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    [ -z "$eax_status" ] && eax_status="supported"
    eax_status_details=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.problem // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    restore_details=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.fix // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    # Read here rather than through resolve_recommended_tweaks, which sets
    # the install's tweak globals.
    eax_unified=$(jq -r --arg id "$id" --arg store "$store" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)][0] | .install.tweaks // [] | index("eax_unified") != null' \
        "$GAME_DATABASE_FILE" 2>/dev/null)
    notes=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .notes // empty' \
        "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)

    # Store-level fields, one per entry.
    for i in "${!stores[@]}"; do
        apis[i]=$(jq -r --arg id "${ids[i]}" --arg store "${stores[i]}" \
            '.games[] | select((.stores[$store].id // "") | tostring == $id) | (.stores[$store].api // .eax.api // "directsound3d")' \
            "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        listings[i]=$(jq -r --arg id "${ids[i]}" --arg store "${stores[i]}" \
            '.games[] | select((.stores[$store].id // "") | tostring == $id) | (if .stores[$store].delisted then "delisted" else empty end)' \
            "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        id_sources[i]=$(jq -r --arg id "${ids[i]}" --arg store "${stores[i]}" \
            '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].id_source // empty' \
            "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        details[i]=$(jq -r --arg id "${ids[i]}" --arg store "${stores[i]}" \
            '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].store_details // empty' \
            "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        # The first match's whole text, not its first line: patches can hold
        # a line break between suggestions.
        patches[i]=$(jq -r --arg id "${ids[i]}" --arg store "${stores[i]}" \
            '[.games[] | select((.stores[$store].id // "") | tostring == $id)][0].stores[$store].patches // empty' \
            "$GAME_DATABASE_FILE" 2>/dev/null)
        counts[i]="$(count_game_settings "${ids[i]}" "${stores[i]}")"
    done

    # Usage: _same_for_all <array name>
    # True when every store's value in the array is the same.
    _same_for_all() {
        local -n _vals="$1"
        local v
        for v in "${_vals[@]}"; do [ "$v" == "${_vals[0]}" ] || return 1; done
    }

    # --- Field lines: what the database has on file, then what was found here ---
    # Everything under "Game details" comes from game-database.json, not
    # from the install, so it's kept apart from the two facts the library
    # scan found on this system. The lines are collected first and printed
    # together, so every value lines up after the longest label shown. A
    # value with one line per store continues under the first.
    local -a detail_labels=() detail_values=()
    _detail() { detail_labels+=("$1"); detail_values+=("$2"); }
    _detail_heading() { detail_labels+=(""); detail_values+=("$1"); }
    _print_details() {
        local i width=0 pad
        for i in "${!detail_labels[@]}"; do
            [ ${#detail_labels[$i]} -gt "$width" ] && width=${#detail_labels[$i]}
        done
        printf -v pad '%*s' $(( width + 6 )) ""
        for i in "${!detail_labels[@]}"; do
            if [ -z "${detail_labels[$i]}" ]; then
                echo -e "\n${WHITE}${detail_values[$i]}:${NC}"
            else
                printf ' -> %b%s%b:%*s %b\n' "$YELLOW" "${detail_labels[$i]}" "$NC" \
                    $(( width - ${#detail_labels[$i]} )) "" "${detail_values[$i]//$'\n'/$'\n'$pad}"
            fi
        done
    }
    local value sep
    _detail_heading "Game details"
    _detail "Name" "${BOLD}${name}${NC}"
    [ -n "$released" ] && _detail "Released" "${WHITE}$(format_release_date "$released")${NC}"
    # The browser names each store's ID; the install shows its one store
    # under System details instead.
    if [ -z "$location" ]; then
        for i in "${!stores[@]}"; do
            _detail "${labels[i]} ID" "${WHITE}${ids[i]}${NC}"
        done
    fi
    # One row naming every store it's delisted from.
    value=""
    for i in "${!stores[@]}"; do
        [ "${listings[i]}" == "delisted" ] && value+="${value:+ and }${labels[i]}"
    done
    [ -n "$value" ] && _detail "Availability" "${WHITE}Delisted from $value ${DIM}(existing owners keep access)${NC}"
    for i in "${!stores[@]}"; do
        if [ "${id_sources[i]}" == "steamdb_historical" ]; then
            _detail "ID source" "${WHITE}SteamDB records ${DIM}(not verified against a local install)${NC}"
        fi
    done
    # eax_versions sits in the same slot for every game — the qualifier for a
    # patch-removed build comes after the list, not in place of it.
    local ver_display="${eax_versions:-Unknown}"
    if [ "$eax_status" == "supported" ]; then
        _detail "EAX Support" "${GREEN}${BOLD}${ver_display}${NC}"
    elif [ "$eax_status" == "removed_by_patch" ]; then
        _detail "EAX Support" "${YELLOW}${BOLD}${ver_display}${NC} ${DIM}(originally supported)${NC}"
    elif [ "$eax_status" == "built_in" ]; then
        _detail "EAX Support" "${GREEN}${BOLD}${ver_display}${NC} ${DIM}(already built in)${NC}"
    else
        _detail "EAX Support" "${YELLOW}${BOLD}None${NC}"
    fi
    _api_name() { [ "$1" == "openal" ] && echo "OpenAL" || echo "DirectSound3D"; }
    if _same_for_all apis; then
        _detail "Audio API" "${WHITE}$(_api_name "${apis[0]}")${NC}"
    else
        value="" sep=""
        for i in "${!stores[@]}"; do
            value+="${sep}${WHITE}$(_api_name "${apis[i]}")${NC} on ${labels[i]}"; sep=$'\n'
        done
        _detail "Audio API" "$value"
    fi
    [ "$eax_unified" == "true" ] && _detail "EAX Unified" "${WHITE}Yes${NC}"
    # Settings limited to one store (only_if.stores) can make the counts
    # differ; each count is then shown with its store.
    local col label_text
    local -a nums fields
    for col in 0 1; do
        [ "$col" -eq 0 ] && label_text="Audio settings" || label_text="Optional settings"
        nums=()
        for i in "${!stores[@]}"; do
            read -ra fields <<< "${counts[i]:-0 0}"
            nums[i]="${fields[col]:-0}"
        done
        if _same_for_all nums; then
            [ "${nums[0]}" -gt 0 ] && _detail "$label_text" "${WHITE}${nums[0]}${NC}"
        else
            value="" sep=""
            for i in "${!stores[@]}"; do value+="${sep}${WHITE}${nums[i]}${NC} on ${labels[i]}"; sep=$'\n'; done
            _detail "$label_text" "$value"
        fi
    done

    if [ -n "$location" ]; then
        _detail_heading "System details"
        _detail "Platform" "${GREEN}${labels[0]}${NC}"
        _detail "Location" "${DIM}$(tilde_path "$location")${NC}"
    fi
    _print_details
    # What the game is, for the browser; the install already knows.
    if [ -z "$location" ] && [ -n "$description" ]; then
        print_subheading "Description"
        print_wrapped "$description"
    fi

    # --- Blocks: status -> problem -> solution ---
    if [ "$eax_status" != "supported" ]; then
        # The entry's own problem text says why; the generic lead-in is only
        # for an entry without one.
        local state_line="" after_line=""
        [ -z "$eax_status_details" ] && state_line="Never implemented in this edition."
        [ "$eax_status" == "removed_by_patch" ] && state_line="Removed by a later patch."
        if [ "$eax_status" == "built_in" ]; then
            state_line=""
            after_line=" Installing is optional: it swaps in a newer OpenAL Soft and adds speaker and headphone settings."
        fi
        print_subheading "Status"
        local status_text="${state_line}${eax_status_details:+ $eax_status_details}${after_line}"
        print_wrapped "${status_text# }"
    fi
    # Store texts the stores share are shown once, under both their names.
    if [ "$n" -gt 1 ] && [ -n "${details[0]}" ] && _same_for_all details; then
        print_subheading "$(printf '%s and ' "${labels[@]:0:n-1}")${labels[n-1]} details"
        print_wrapped "${details[0]}"
    else
        for i in "${!stores[@]}"; do
            [ -n "${details[i]}" ] || continue
            print_subheading "${labels[i]} details"
            print_wrapped "${details[i]}"
        done
    fi
    if [ "$eax_status" == "supported" ]; then
        _solution() { [ "$1" == "openal" ] && echo "OpenAL Soft" || echo "DSOAL + OpenAL Soft"; }
        print_subheading "Restoring EAX with"
        if _same_for_all apis; then
            print_wrapped "$(_solution "${apis[0]}")"
        else
            for i in "${!stores[@]}"; do print_wrapped "${labels[i]}: $(_solution "${apis[i]}")"; done
        fi
        unset -f _solution
    fi
    # Every store's titles, in database order; one only some stores offer
    # says which.
    local cat title
    local -a eax_titles=() extra_titles=()
    local -A title_stores=()
    for i in "${!stores[@]}"; do
        while IFS=$'\t' read -r cat title; do
            if [ -z "${title_stores[$cat$'\t'$title]+x}" ]; then
                [ "$cat" == "audio" ] && eax_titles+=("$title") || extra_titles+=("$title")
                title_stores[$cat$'\t'$title]="${labels[i]}"
            else
                title_stores[$cat$'\t'$title]+=" and ${labels[i]}"
            fi
        done < <(game_setting_titles "${ids[i]}" "${stores[i]}")
    done
    _setting_title() {
        local only="${title_stores[$1$'\t'$2]}"
        if [ "$n" -gt 1 ] && [ "$(grep -o ' and ' <<< "$only" | wc -l)" -lt $(( n - 1 )) ]; then
            echo "$2 ($only only)"
        else
            echo "$2"
        fi
    }
    if [ ${#eax_titles[@]} -gt 0 ]; then
        print_subheading "Audio settings"
        for title in "${eax_titles[@]}"; do print_wrapped "$(_setting_title audio "$title")"; done
    fi
    if [ ${#extra_titles[@]} -gt 0 ]; then
        print_subheading "Optional settings"
        for title in "${extra_titles[@]}"; do print_wrapped "$(_setting_title optional "$title")"; done
    fi
    unset -f _setting_title
    if [ -n "$restore_details" ]; then
        print_subheading "Additional steps"
        print_wrapped "$restore_details"
    fi
    if [ -n "$notes" ]; then
        print_subheading "Notes"
        print_wrapped "$notes"
    fi
    if [ "$n" -eq 1 ] || { [ -n "${patches[0]}" ] && _same_for_all patches; }; then
        if [ -n "${patches[0]}" ]; then
            print_subheading "Suggested community patches"
            print_wrapped "${patches[0]}"
        fi
    else
        for i in "${!stores[@]}"; do
            [ -n "${patches[i]}" ] || continue
            print_subheading "Suggested community patches for ${labels[i]}"
            print_wrapped "${patches[i]}"
        done
    fi
    unset -f _same_for_all _api_name
    # Always the last section: the pages behind the entry's claims, as
    # clickable names. A bare URL is shown by its site's address.
    local src_title src_url shown_sources=0
    while IFS=$'\t' read -r src_title src_url; do
        [ -n "$src_url" ] || continue
        [ "$shown_sources" -eq 0 ] && print_subheading "Sources"
        print_link "$src_title" "$src_url"
        shown_sources=1
    done < <(jq -r --arg id "$id" --arg store "$store" '
        [.games[] | select((.stores[$store].id // "") | tostring == $id)][0].sources // [] | .[]
        | if type == "string" then [(capture("^https?://(www\\.)?(?<h>[^/]+)").h), .] else [.title, .url] end
        | join("\t")' "$GAME_DATABASE_FILE" 2>/dev/null)
    echo ""
}

# Usage: fzf_at_least <version>
# True when the installed fzf is at least that version.
fzf_at_least() {
    printf '%s\n%s\n' "$1" "$(fzf --version 2>/dev/null | awk '{ print $1 }')" | sort -V -C
}

# Usage: browse_game_database
# Every game in GAME_DATABASE_FILE in two panes: one row per game on the
# left, fuzzy-searched by fzf, and on the right the selected game's profile
# for each of its stores, Steam's first, or with Tab its game settings in
# full. Ctrl-A and Ctrl-S narrow the list, and the profiles shown, by
# audio and by store, delisted ones included (see browse_game_stores);
# Ctrl-R swaps the order between best match and A–Z; Ctrl-L puts the right pane beside or
# under the list; F1 shows every key (browse_help); Ctrl-F opens the right
# pane full screen (browse_zoom). View only: Enter and double-click do
# nothing, so only Esc and fzf's other abort keys close it. fzf draws on
# /dev/tty, so none of it reaches the run log. Needs fzf 0.35; 0.58 or
# newer draws each part in its own box, with the filters laid out to fit
# the list (browse_filter_header) and the key bar on the last row
# (browse_key_bar), and an older one gets the same browser with the
# filters as four lines and the key bar on a border line.
browse_game_database() {
    local dir defs state
    # A run killed while browsing (its terminal closed) leaves its folder
    # behind, so each start clears out any a day old.
    find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'eax-restore-browse.*' -user "$(id -u)" -mmin +1440 \
        -exec rm -rf {} + 2>/dev/null
    dir="$(mktemp -d -t eax-restore-browse.XXXXXX)" || return 1
    defs="$dir/defs.sh" state="$dir/state"
    # The right pane sits beside the list (BROWSE_SIDE_PERCENT of the
    # width). Below 104 columns that leaves both too narrow, so it starts
    # under the list instead.
    local cols boxed=0 layout=side
    read -r _ cols < <({ stty size < /dev/tty; } 2>/dev/null)
    [ "${cols:-0}" -lt 104 ] && layout=stack
    fzf_at_least 0.58 && boxed=1
    # wrap: a profile row longer than the pane goes on to the next line
    # rather than being cut off.
    local border="border-left" stack="down,55%,wrap,border-top"
    [ "$boxed" -eq 1 ] && border="border-rounded" stack="down,55%,wrap,border-rounded"
    local side="right,$BROWSE_SIDE_PERCENT%,wrap,$border"
    local now="$side" other="$stack"
    [ "$layout" == "stack" ] && now="$stack" other="$side"
    # fzf runs the preview and the keys' commands in a new shell, which has
    # none of this script's functions or colours. Every function goes in,
    # not a list of the ones print_game_profile calls, so a helper it picks
    # up later can't be missing there. BROWSE_HEADER_LINES: the filters go
    # in the list's first lines (older fzf) rather than fzf's header.
    local BROWSE_HEADER_LINES=$(( 1 - boxed ))
    { declare -p GREEN YELLOW CYAN WHITE BOLD DIM NOTE NC GAME_DATABASE_FILE SCRIPT_VERSION \
        BROWSE_SIDE_PERCENT BROWSE_HEADER_LINES; declare -f; } > "$defs"
    echo "all all profile 0 match $layout" > "$state"
    # The key bar's own small script: it's redrawn on every move through
    # the list, too often to load all of the above each time.
    local bar="$dir/bar.sh"
    { declare -p CYAN BOLD DIM NC SCRIPT_VERSION; declare -f browse_key_bar browse_key_legend
        echo browse_key_bar; } > "$bar"
    local load="source ${defs@Q}"
    local next="$load; browse_state_next ${state@Q}" rows="$load; browse_game_rows ${state@Q}"
    local header="" label=""
    local -a fzf_opts=()
    if [ "$boxed" -eq 1 ]; then
        header="+transform-header($load; browse_filter_header ${state@Q})"
        label="+transform-preview-label($load; browse_pane_label ${state@Q})"
        # The key bar sits on the last row, outside fzf (whose own labels
        # only go on a border line): fzf gets every row above it, on the
        # alternate screen so the menu underneath is back afterwards. fzf
        # clears below itself as it starts, at a moment none of its events
        # reliably follow, so the bar is drawn again whenever the selection
        # moves as well as on every resize, which also refits the filters.
        fzf_opts=(--height=-1 --input-border rounded --input-label " Search " --prompt "> " --info inline-right
            --header "$(browse_filter_header "$state")"
            --header-border rounded --header-label " Filters "
            --list-border rounded --list-label " Games "
            --preview-label " Game profile "
            --bind "start,load,focus:execute-silent(bash ${bar@Q})"
            --bind "resize:execute-silent(bash ${bar@Q})$header")
    else
        fzf_opts=(--header-lines 4 --prompt "Search: " --info inline
            --border bottom --border-label-pos 0:bottom --border-label " $(browse_key_legend) ")
    fi
    # Ctrl-F (browse_zoom) needs less; without it the key does nothing.
    command -v less &> /dev/null && fzf_opts+=(--bind "ctrl-f:execute($load; browse_zoom ${state@Q} {1})")
    if [ "$boxed" -eq 1 ]; then
        printf '\e[?1049h\e[H\e[2J' > /dev/tty
        browse_key_bar
        printf '\e[H' > /dev/tty
    fi
    # Ctrl-L's change-preview-window takes its argument in [...]: fzf ends
    # a (...) one at the first ")", and a layout can hold parentheses.
    browse_game_rows "$state" \
        | SHELL="$BASH" fzf --ansi --delimiter $'\t' --with-nth 2 \
            --layout reverse --tiebreak index "${fzf_opts[@]}" \
            --preview "$load; WRAP_COLUMNS=\$((FZF_PREVIEW_COLUMNS < 100 ? FZF_PREVIEW_COLUMNS - 4 : 96)) browse_game_preview ${state@Q} {1}" \
            --preview-window "$now" \
            --bind "enter:ignore,double-click:ignore" \
            --bind "shift-up:preview-up,shift-down:preview-down,page-up:preview-page-up,page-down:preview-page-down" \
            --bind "f1:execute-silent($next help)+refresh-preview$label" \
            --bind "tab:execute-silent($next view)+refresh-preview$label" \
            --bind "ctrl-s:execute-silent($next store)+reload($rows)$header" \
            --bind "ctrl-a:execute-silent($next audio)+reload($rows)$header" \
            --bind "ctrl-r:execute-silent($next order)+toggle-sort+reload($rows)$header" \
            --bind "ctrl-l:execute-silent($next layout)+change-preview-window[$other|$now]$header" \
            > /dev/null || true
    [ "$boxed" -eq 1 ] && printf '\e[?1049l' > /dev/tty
    rm -rf "$dir"
    return 0
}

# Usage: browse_key_legend
# The browser's key legend, keys in bold cyan. The filter keys are in the
# Filters box beside their filters, and the rest in the F1 help.
browse_key_legend() {
    local -a keys=("F1" "help" "Tab" "game settings" "Ctrl-L" "layout" "Shift-↑/↓" "scroll" "Esc" "back")
    local i out="" sep=""
    for ((i = 0; i < ${#keys[@]}; i += 2)); do
        out+="${sep}${CYAN}${BOLD}${keys[i]}${NC} ${keys[i + 1]}"
        sep=" ${DIM}·${NC} "
    done
    printf '%b' "$out"
}

# Usage: browse_key_bar
# Draws the key legend centred on the terminal's last row, with the script
# version at the far right, straight to /dev/tty; the cursor is put back
# where fzf left it. Also run on every resize.
browse_key_bar() {
    local rows cols legend plain version="v${SCRIPT_VERSION}" col
    read -r rows cols < <({ stty size < /dev/tty; } 2>/dev/null)
    [ -n "$rows" ] || return 0
    legend="$(browse_key_legend)"
    plain="$(printf '%s' "$legend" | sed 's/\x1b\[[0-9;]*m//g')"
    col=$(( (cols - ${#plain}) / 2 + 1 ))
    # Clear of the version on a narrow terminal.
    [ $(( col + ${#plain} )) -gt $(( cols - ${#version} - 1 )) ] && col=$(( cols - ${#version} - ${#plain} - 1 ))
    [ "$col" -lt 1 ] && col=1
    printf '\e7\e[%d;1H\e[2K\e[%d;%dH%s\e[%d;%dH%b%s%b\e8' "$rows" "$rows" "$col" "$legend" \
        "$rows" $(( cols - ${#version} + 1 )) "$DIM" "$version" "$NC" > /dev/tty 2>/dev/null
}

# Usage: browse_game_stores <state file> [game id]
# One "<game id>\t<name>\t<store>\t<store id>" line per store entry that
# passes the browser's filters, games sorted by name and Steam before GOG.
# The state file holds "<store> <audio> <view> <help> <order> <layout>":
# store all, steam, gog, or delisted / steam-delisted / gog-delisted (the
# entries with the store's own delisted flag, from any store or that one);
# audio all, directsound3d, openal or eax1.0 to eax5.0 (games whose
# eax.versions lists it); then what the right pane shows, the list's order
# and where the right pane is. The API is the store's own, else the
# game's. With a game id, just that game's.
browse_game_stores() {
    local store audio
    read -r store audio _ < "$1"
    jq -r --arg store "$store" --arg audio "$audio" --arg game "${2:-}" '
        ($store | sub("-?delisted$"; "")) as $only
        | ($store | endswith("delisted")) as $delisted
        | .games | sort_by(.name | ascii_downcase) | .[]
        | select($game == "" or .id == $game) | . as $g
        | ("steam", "gog") as $key | .stores[$key] // empty
        | select(($only == "all" or $only == "" or $key == $only)
            and (($delisted | not) or (.delisted // false))
            and ($audio == "all"
                or (.api // $g.eax.api // "directsound3d") == $audio
                or (($audio | startswith("eax")) and (($g.eax.versions // []) | index($audio[3:])) != null)))
        | "\($g.id)\t\($g.name)\t\($key)\t\(.id)"' "$GAME_DATABASE_FILE" 2>/dev/null
}

# Usage: browse_game_rows <state file>
# browse_game_database's list: one "<game id>\t<name>" row per game with a
# store entry that passes the filters, after the four filter lines when
# they go in the list (BROWSE_HEADER_LINES, older fzf).
browse_game_rows() {
    if [ "${BROWSE_HEADER_LINES:-0}" == "1" ]; then
        browse_filter_header "$1" list | sed 's/^/\t/'
    fi
    browse_game_stores "$1" | awk -F '\t' '!seen[$1]++ { print $1 "\t" $2 }'
}

# Usage: browse_filter_header <state file> [list]
# The Filters box: each filter's key (bold cyan), then the filter and its
# value (green). All four on one line when the game list is wide enough,
# else two a line, else (or with "list") one a line. The list is as wide as
# the terminal when the right pane is under it, and BROWSE_SIDE_PERCENT
# narrower when it's beside it. Values are padded to the longest each can
# be, so nothing moves as a filter cycles; by character count, since
# printf pads bytes and "A–Z" has a multi-byte dash.
browse_filter_header() {
    local store audio order layout cols width
    read -r store audio _ _ order layout < "$1"
    local -A label=([all]="All" [steam]="Steam" [gog]="GOG" [delisted]="Delisted"
        [steam-delisted]="Steam delisted" [gog-delisted]="GOG delisted"
        [directsound3d]="DirectSound3D" [openal]="OpenAL" [match]="Best match" [az]="A–Z")
    local -a names=("Store" "Audio" "Order") keys=("Ctrl-S" "Ctrl-A" "Ctrl-R") values=()
    local v
    for v in "$store" "$audio" "$order"; do values+=("${label[$v]:-EAX ${v#eax}}"); done
    # Usage: _browse_cell <filter> [value width]
    # "Ctrl-S Store All": the key, then its filter and value; the value is
    # padded only when another cell follows it on the line.
    _browse_cell() {
        printf '%b%s%b %-6s%b%s%b%*s' "${CYAN}${BOLD}" "${keys[$1]}" "$NC" "${names[$1]}" \
            "$GREEN" "${values[$1]}" "$NC" $(( ${2:-0} > ${#values[$1]} ? ${2:-0} - ${#values[$1]} : 0 )) ""
    }
    cols="${FZF_COLUMNS:-}"
    [ -n "$cols" ] || read -r _ cols < <({ stty size < /dev/tty; } 2>/dev/null)
    # Less the list's border and the gutter fzf indents its lines by, and
    # beside the right pane, that pane.
    width=$(( ${cols:-0} - 5 ))
    [ "$layout" == "side" ] && width=$(( width - ${cols:-0} * BROWSE_SIDE_PERCENT / 100 ))
    [ "${2:-}" == "list" ] && width=0
    if [ "$width" -ge 80 ]; then
        # 7 + 6 + 14, 7 + 6 + 13, 7 + 6 + 10, two spaces between.
        printf '%s  %s  %s\n' "$(_browse_cell 0 14)" "$(_browse_cell 1 13)" "$(_browse_cell 2)"
    elif [ "$width" -ge 55 ]; then
        # Store and Order in the left column, Audio on the right.
        printf '%s  %s\n' "$(_browse_cell 0 14)" "$(_browse_cell 1)"
        printf '%s\n' "$(_browse_cell 2)"
    else
        for v in 0 1 2; do printf '%s\n' "$(_browse_cell "$v")"; done
    fi
    unset -f _browse_cell
}

# Usage: browse_game_preview <state file> <game id>
# The browser's right pane: the F1 help when it's on; else one profile for
# the game, covering each of its store entries that passes the filters
# (print_game_profile_stores shows what they share once), or in the
# settings view its game settings. No banner: the pane's label names it.
browse_game_preview() {
    local -a entries=()
    local row store_key store_id view help
    read -r _ _ view help _ < "$1"
    if [ "$help" == "1" ]; then
        browse_help
        return
    fi
    if [ "$view" == "settings" ]; then
        print_game_settings_details "$2"
        return
    fi
    while IFS=$'\t' read -r _ _ store_key store_id; do
        entries+=("$store_key:$store_id")
    done < <(browse_game_stores "$1" "$2")
    [ ${#entries[@]} -gt 0 ] && print_game_profile_stores "" "${entries[@]}"
}

# Usage: browse_help
# F1 in the browser: every key that does something, fzf's own included,
# most needed first, wrapped to the pane. A "" key starts a heading.
browse_help() {
    local -a help=(
        "" "The basics"
        "Type" "Search the game names: any part of a name, words in any order."
        "↑/↓" "Move through the list. A mouse click shows a game too."
        "Tab" "Switch the right pane between the game's profile and its settings."
        "Shift-↑/↓" "Scroll the right pane; PgUp/PgDn a page at a time, or the mouse wheel over it."
        "Esc" "Close the browser (Ctrl-C, Ctrl-G and Ctrl-Q too, and Ctrl-D when the search is empty)."
        "F1" "Show or hide this help."
        "" "Filters"
        "Ctrl-A" "Audio: All → DirectSound3D → OpenAL → EAX 1.0 … 5.0."
        "Ctrl-S" "Store: All → Steam → GOG → Delisted → Steam delisted → GOG delisted. Delisted games are no longer sold on that store."
        "Ctrl-R" "Order: best match first, or A–Z."
        "" "View"
        "Ctrl-F" "Open the right pane full screen; q comes back."
        "Ctrl-L" "Layout: side by side, or top and bottom."
        "Ctrl-/" "Wrap long game names onto a second line."
        "" "Editing the search"
        "Ctrl-U" "Clear the search."
        "Backspace/Del" "Delete a letter. Alt-Backspace or Ctrl-W deletes a word back, Alt-D a word forward."
        "←/→" "Move along the search text; Alt-←/→ a word at a time."
        "Home/End" "Go to the start or end of the search text (Ctrl-E: the end)."
        "Ctrl-Y" "Put back the text Ctrl-U, Ctrl-W or Alt-D removed."
        "" "More ways to move"
        "Ctrl-K/Ctrl-J" "Up and down the list, like ↑/↓ (Ctrl-P/Ctrl-N too)."
        "Mouse wheel" "Over the list, scrolls it."
    )
    local width=$(( ${WRAP_COLUMNS:-76} - 15 )) i line first
    for ((i = 0; i < ${#help[@]}; i += 2)); do
        if [ -z "${help[i]}" ]; then
            echo -e "\n${WHITE}${help[i + 1]}:${NC}"
            continue
        fi
        first=1
        while IFS= read -r line; do
            if [ "$first" -eq 1 ]; then
                printf ' %b%s%b%*s %s\n' "${CYAN}${BOLD}" "${help[i]}" "$NC" $(( 13 - ${#help[i]} )) "" "$line"
                first=0
            else
                printf ' %13s %s\n' "" "$line"
            fi
        done < <(printf '%s\n' "${help[i + 1]}" | fold -s -w "$width")
    done
}

# Usage: browse_state_next <state file> <store|audio|view|help|order|layout>
# The browser's keys: Ctrl-S / Ctrl-A move that filter on to its
# next value (back to All after the last), Tab switches the right pane
# between the profile and the settings (and closes the help), F1 shows or
# hides the help, Ctrl-R swaps the order, Ctrl-L the layout.
browse_state_next() {
    local store audio view help order layout
    read -r store audio view help order layout < "$1"
    case "$2" in
        store)
            case "$store" in
                all) store=steam ;; steam) store=gog ;; gog) store=delisted ;;
                delisted) store="steam-delisted" ;; steam-delisted) store="gog-delisted" ;; *) store=all ;;
            esac ;;
        audio)
            case "$audio" in
                all) audio=directsound3d ;; directsound3d) audio=openal ;; openal) audio=eax1.0 ;;
                eax1.0) audio=eax2.0 ;; eax2.0) audio=eax3.0 ;; eax3.0) audio=eax4.0 ;; eax4.0) audio=eax5.0 ;;
                *) audio=all ;;
            esac ;;
        view) [ "$view" == "settings" ] && view=profile || view=settings; help=0 ;;
        help) [ "$help" == "1" ] && help=0 || help=1 ;;
        order) [ "$order" == "az" ] && order=match || order=az ;;
        layout) [ "$layout" == "stack" ] && layout=side || layout=stack ;;
    esac
    echo "$store $audio $view $help $order $layout" > "$1"
}

# Usage: browse_pane_label <state file>
# The right pane's label for what it shows.
browse_pane_label() {
    local view help
    read -r _ _ view help _ < "$1"
    if [ "$help" == "1" ]; then echo " Help "
    elif [ "$view" == "settings" ]; then echo " Game settings "
    else echo " Game profile "; fi
}

# Usage: browse_zoom <state file> <game id>
# Ctrl-F in the browser: the right pane's text in less, across the whole
# terminal (fzf can't give the pane all of it), wrapped like the pane. less -R keeps the colours; the Sources links' escape codes are
# dropped, since an older less shows them as junk. q goes back.
browse_zoom() {
    local cols
    read -r _ cols < <({ stty size < /dev/tty; } 2>/dev/null)
    WRAP_COLUMNS=$(( ${cols:-80} < 100 ? ${cols:-80} - 4 : 96 )) browse_game_preview "$1" "$2" \
        | sed $'s/\e]8;;[^\e]*\e\\\\//g' | less -R
}

# Usage: print_community_patches_summary
# INSTALLATION COMPLETE's "Suggested community patches" section: the same text
# the GAME PROFILE block showed, repeated where the player will still
# see it when they go to play.
print_community_patches_summary() {
    [ -n "$PROFILE_PATCHES" ] || return 0
    echo -e "\n${YELLOW}${BOLD}Suggested community patches:${NC}"
    print_wrapped "$PROFILE_PATCHES"
}

confirm_continue_if_eax_impossible() {
    # Usage: confirm_continue_if_eax_impossible <id> <steam|gog> [acf_file]
    # "built_in" (EAX already works without this script) only asks whether
    # to install anyway. Otherwise eax.status distinguishes two reasons this
    # script has nothing to restore on a build: "removed_by_patch" (a software update stripped EAX/A3D
    # calls from an otherwise-DirectSound3D game) vs. "not_implemented" (a
    # remaster/rewrite that never had EAX in the first place — no
    # build-level fix exists). "not_implemented" is an unconditional no-op,
    # so it skips straight to prompt_restart_or_quit. "removed_by_patch" is
    # only a confirmable warning ("install anyway" stays offered) when
    # eax.fix_in_place is true — meaning eax.fix documents
    # an in-place fix within this same store install (e.g. a Steam beta
    # branch) the user might already be on or willing to switch to;
    # otherwise (the field is absent) the only fix is a separate install this
    # run isn't pointed at, so it hard-blocks exactly like "not_implemented".
    # Either way the dead end offers "pick a different game" rather than just
    # ending the script — see prompt_restart_or_quit / the Steps 1-2 loop in
    # config-flow.sh.
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return

    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local acf_file="$3"

    local status="" workaround="false" beta_branch=""
    if ensure_game_database; then
        status=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.status // "supported"' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        workaround=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax.fix_in_place // false' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        beta_branch=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].beta_branch // empty' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
    elif [ "$store" != "gog" ] && [ -n "${EAX_IMPOSSIBLE_FALLBACK_STEAM[$1]:-}" ]; then
        # Only ever seeds Half-Life (AppID 70), which has no in-place
        # workaround — workaround stays "false".
        status="removed_by_patch"
    fi
    if [ -z "$status" ] || [ "$status" == "supported" ]; then
        return
    fi

    # EAX already works without anything installed. Already asked when the
    # game was picked from the library scan; asked here for a game found
    # any other way.
    if [ "$status" == "built_in" ]; then
        [ -n "$BUILT_IN_CONFIRMED" ] && return
        local name
        name=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .name' "$GAME_DATABASE_FILE" 2>/dev/null | head -n 1)
        confirm_built_in_install "$name" || prompt_restart_or_quit 0
        return
    fi

    # Right after the GAME PROFILE (always the case unless the database is
    # missing and the hardcoded fallback matched), its Status has said why.
    if [ "$status" == "not_implemented" ]; then
        if [ -n "$SCANNED_NOTES_SHOWN" ]; then
            print_eax_block_error "$1" "$store"
        else
            print_error "This edition never implemented EAX/environmental audio in the first place, so" \
                "there would be nothing here for this script to restore."
        fi
        prompt_restart_or_quit 1
        return
    fi

    if [ "$workaround" != "true" ]; then
        if [ -n "$SCANNED_NOTES_SHOWN" ]; then
            print_eax_block_error "$1" "$store"
        else
            print_error "EAX/A3D support was removed from this build by a software update, and there's" \
                "no known in-place fix — restoring it would need a separate install this script" \
                "isn't pointed at."
        fi
        prompt_restart_or_quit 1
        return
    fi

    # A known beta branch restores EAX in place — offer to check whether the
    # user is already on it before showing a warning that wouldn't apply to
    # them. Opt-in and reported before acting on it, same as every other
    # auto-detect in this script (Proton prefix, AppID search): ask first,
    # detect, report the raw result, then a separate confirm before it's
    # allowed to skip the warning below.
    if [ "$store" == "steam" ] && [ -n "$beta_branch" ] && [ -n "$acf_file" ]; then
        if confirm "Check if you're already on Steam's '$beta_branch' beta branch, which keeps EAX intact?"; then
            local detected
            detected=$(detect_steam_beta_branch "$acf_file")
            print_status "Detected beta branch: ${detected:-none}" ""
            if [ "$detected" == "$beta_branch" ]; then
                if confirm "Skip the EAX-removed warning — this build should already have EAX intact?"; then
                    return
                fi
            fi
        fi
    fi

    print_warning "EAX/A3D support was removed from this build by a software update, so there's" \
        "nothing for this script to restore on the current default build."

    if ! confirm "Continue installing anyway?" N; then
        prompt_restart_or_quit 0
        return
    fi
}
