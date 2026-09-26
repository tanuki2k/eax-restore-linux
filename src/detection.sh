# ==============================================================================
# CORE FUNCTIONS
# ==============================================================================

find_local_wine() {
    local search_paths=("$HOME/.config/heroic/tools" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools")
    local found_wine=""
    for path in "${search_paths[@]}"; do
        if [ -d "$path" ]; then
            found_wine=$(find "$path" -type f -path "*/bin/wine" -executable 2>/dev/null | head -n 1)
            [ -n "$found_wine" ] && break
        fi
    done
    echo "$found_wine"
}

prompt_manual_game_dir() {
    # Usage: prompt_manual_game_dir
    # Prompts for a game .exe folder and cleans the entry in place — strips
    # surrounding quotes and a trailing slash, expands a leading ~. Result
    # in GAME_DIR (emptied on EOF or a blank line). Returns 1 on EOF/blank
    # so a caller looping on the read can't spin on closed stdin; callers do
    # their own directory-exists / .exe-count validation afterwards.
    prompt "Enter the full path to the game's .exe folder:"
    if ! read_answer GAME_DIR; then GAME_DIR=""; return 1; fi
    GAME_DIR="${GAME_DIR//\'/}"; GAME_DIR="${GAME_DIR//\"/}"; GAME_DIR="${GAME_DIR%/}"
    GAME_DIR="${GAME_DIR/#\~/$HOME}"
    [ -z "$GAME_DIR" ] && return 1
    return 0
}

pick_directory_gui() {
    # Usage: pick_directory_gui
    # Opens a native folder-picker dialog via zenity (GNOME/GTK desktops) or
    # kdialog (KDE Plasma), whichever is available — covers the popular
    # desktop environments without pulling in a new dependency by default.
    # Prints the chosen path (empty if cancelled/unavailable/failed).
    if command -v zenity &>/dev/null; then
        zenity --file-selection --directory --title="Select the game's .exe folder" 2>/dev/null
    elif command -v kdialog &>/dev/null; then
        kdialog --getexistingdirectory "$HOME" --title "Select the game's .exe folder" 2>/dev/null
    fi
}

show_hidden_folder_tip_popup() {
    # Usage: show_hidden_folder_tip_popup
    # A printed terminal tip is easy to miss once the GUI file picker steals
    # focus, so this shows it as a native popup instead, right before
    # pick_directory_gui opens the picker — the popup's own dismiss click
    # also serves as the "ready to open the picker" acknowledgement a
    # terminal prompt would otherwise need. Only called when have_gui_picker
    # is set, so zenity or kdialog is already known to be present.
    local msg="Steam's default install path (~/.local/share/Steam/...) is inside a hidden folder.\n\nPress Ctrl+H in the file picker if you don't see it."
    if command -v zenity &>/dev/null; then
        zenity --info --title="Tip" --text="$msg" --width=350 2>/dev/null
    elif command -v kdialog &>/dev/null; then
        kdialog --msgbox "$msg" --title "Tip" 2>/dev/null
    fi
}

get_game_directory() {
    GAME_DIR=""
    GAME_NAME=""
    SCANNED_APPID=""
    SCANNED_NOTES_SHOWN=""
    OPENAL_NATIVE_MODE=""

    if [ "$SCRIPT_ACTION" == "u" ] && prompt_recent_game; then
        echo -e "\n${GREEN}Using: $GAME_DIR${NC}"
        record_recent_game "$GAME_DIR"
        return
    fi

    local can_scan=0
    if [ "$SCRIPT_ACTION" == "i" ] && ensure_known_games_json; then
        can_scan=1
        echo ""
    elif [ "$SCRIPT_ACTION" == "i" ]; then
        print_note "Library scanning needs the known-EAX-games database," \
            "which isn't available this run — skipping straight to manual entry."
        echo ""
    else
        # SCRIPT_ACTION == "u" reaching here (prompt_recent_game found no
        # match) — neither branch above ran, so nothing has separated this
        # from print_step's divider yet.
        echo ""
    fi

    echo -e "${WHITE}Common game locations:${NC}\n"
    echo -e "${WHITE} Linux Desktop (Steam): ~/.local/share/Steam/steamapps/common/[Game]${NC}"
    echo -e "${WHITE} Steam Deck (SD Card):  /run/media/mmcblk0p1/steamapps/common/[Game]${NC}"
    echo -e "${WHITE} Heroic / GOG:          ~/Games/Heroic/[Game]${NC}\n"

    local have_gui_picker=0
    if command -v zenity &>/dev/null || command -v kdialog &>/dev/null; then
        have_gui_picker=1
    fi

    while [ -z "$GAME_DIR" ]; do
        # Build the menu fresh each pass: which options apply can shrink
        # (e.g. a scan that just came up empty stays offered — the user
        # might pick something else next time), and skipping straight to
        # the one available action avoids asking a one-choice "choice".
        local -a menu_actions=()
        if [ "$have_gui_picker" -eq 1 ]; then
            print_option "$((${#menu_actions[@]} + 1))" "Browse for the folder using a graphical file picker"
            menu_actions+=("gui")
        fi
        if [ "$can_scan" -eq 1 ]; then
            print_option "$((${#menu_actions[@]} + 1))" "Scan your Steam/Heroic library for known EAX games"
            menu_actions+=("scan")
        fi
        print_option "$((${#menu_actions[@]} + 1))" "Enter the path manually"
        menu_actions+=("manual")

        local action
        if [ "${#menu_actions[@]}" -eq 1 ]; then
            action="${menu_actions[0]}"
        else
            local choice
            while true; do
                prompt "How would you like to locate the game? [1-${#menu_actions[@]}]: "
                read_answer choice
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#menu_actions[@]}" ]; then
                    break
                fi
                print_warning "Invalid selection. Please enter a number 1-${#menu_actions[@]}."
            done
            action="${menu_actions[$((choice - 1))]}"
        fi

        case "$action" in
            scan)
                print_note "the known-EAX-games list is a small, hand-verified, work-in-progress" \
                    "set — it doesn't cover every EAX game. A game you own may still support EAX" \
                    "even if it's not (yet) listed."
                if ! confirm "Understood — it's a work in progress?"; then
                    continue
                fi
                if scan_game_libraries; then
                    echo -e "\n${GREEN}Using: $GAME_DIR${NC}"
                    record_recent_game "$GAME_DIR"
                    return
                fi
                # A scan that bailed (nothing picked, or an EAX-impossible
                # pick where the user chose "different game") drops back to
                # this menu on its own — clear the restart flag so it can't
                # leak past a later successful pick into the Step 1-2 loop.
                RESTART_REQUESTED=""
                continue
                ;;
            gui)
                show_hidden_folder_tip_popup
                GAME_DIR=$(pick_directory_gui)
                GAME_DIR="${GAME_DIR%/}"
                if [ -z "$GAME_DIR" ]; then
                    print_warning "No folder selected."
                    echo ""
                    continue
                fi
                print_status "Selected: $GAME_DIR" "$DIM"
                ;;
            manual)
                prompt_manual_game_dir || true
                ;;
        esac

        if [ -d "$GAME_DIR" ]; then
            if [ "$SCRIPT_ACTION" == "i" ]; then
                EXE_COUNT=$(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" | wc -l)
                if [ "$EXE_COUNT" -eq 0 ]; then
                    print_warning "No .exe files were found in this directory or its immediate subfolders."
                    if confirm "Are you absolutely sure this is the correct game folder?" N; then break; fi
                    echo ""
                    GAME_DIR=""
                else
                    break
                fi
            else
                break
            fi
        else
            print_error "Directory not found. Please check the path and try again."
            echo ""
            GAME_DIR=""
        fi
    done

    record_recent_game "$GAME_DIR"
}

steam_roots() {
    # Usage: steam_roots
    # Prints "label<TAB>dir" for each Steam install present — native first,
    # then Flatpak (its current and older data layouts).
    local d
    for d in "$HOME/.local/share/Steam" "$HOME/.steam/steam"; do
        if [ -d "$d/steamapps" ]; then printf 'native\t%s\n' "$(realpath -m "$d")"; break; fi
    done
    for d in "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"; do
        if [ -d "$d/steamapps" ]; then printf 'flatpak\t%s\n' "$(realpath -m "$d")"; break; fi
    done
    return 0
}

steam_root_for_library() {
    # Usage: steam_root_for_library <library dir>
    # Prints "label<TAB>root" for the Steam install that owns a library
    # folder (the one holding steamapps/): the install root itself, or the
    # install whose libraryfolders.vdf lists it. Returns 1 if none does.
    local lib label root
    lib=$(realpath -m "$1")
    while IFS=$'\t' read -r label root; do
        [ -z "$root" ] && continue
        if [ "$root" == "$lib" ] || grep -Fq -e "\"$lib\"" -e "\"${1%/}\"" "$root/steamapps/libraryfolders.vdf" 2>/dev/null; then
            printf '%s\t%s\n' "$label" "$root"
            return 0
        fi
    done < <(steam_roots)
    return 1
}

pin_steam_dir() {
    # Usage: pin_steam_dir   (reads GAME_DIR, sets STEAM_LIBRARY)
    # protontricks picks a Steam install on its own, and with both native
    # and Flatpak Steam present it can pick the one this game isn't in —
    # then the AppID lookup fails even though the prefix is right beside
    # the game. Exporting STEAM_DIR (which protontricks honours) pins it to
    # the install that owns the game's library, for every protontricks call
    # after this. A STEAM_DIR the user set themselves is left alone.
    local owner label root
    STEAM_LIBRARY="${GAME_DIR%%/steamapps/common/*}"
    if [ -n "$STEAM_DIR" ] && [ -z "$STEAM_DIR_PINNED" ]; then
        log_cmd "steam: library $STEAM_LIBRARY; STEAM_DIR was set by the user ($STEAM_DIR), leaving it"
        return 0
    fi
    if owner=$(steam_root_for_library "$STEAM_LIBRARY"); then
        IFS=$'\t' read -r label root <<< "$owner"
        export STEAM_DIR="$root"; STEAM_DIR_PINNED=1
        log_cmd "steam: library $STEAM_LIBRARY belongs to the $label Steam; STEAM_DIR=$STEAM_DIR for protontricks"
    else
        [ -n "$STEAM_DIR_PINNED" ] && unset STEAM_DIR
        STEAM_DIR_PINNED=""
        log_cmd "steam: no Steam install lists library $STEAM_LIBRARY (found: $(steam_roots | tr '\t\n' ': ')), leaving protontricks to search"
    fi
}

heroic_roots() {
    # Usage: heroic_roots
    # Prints "label<TAB>dir" for each Heroic config folder present — native
    # first, then Flatpak. Both can exist side by side, each with its own
    # library and GamesConfig, so every lookup walks both.
    [ -d "$HOME/.config/heroic" ] && printf 'native\t%s\n' "$HOME/.config/heroic"
    [ -d "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" ] && printf 'flatpak\t%s\n' "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic"
    return 0
}

heroic_json_value() {
    # Usage: heroic_json_value <file> <key>
    # First "key": "value" string in a Heroic JSON file (empty if missing).
    # Heroic writes one key per line, so no jq needed.
    grep -m 1 "\"$2\"[[:space:]]*:[[:space:]]*\"" "$1" 2>/dev/null | awk -F '"' '{print $4}'
}

heroic_prefix_name() {
    # Usage: heroic_prefix_name <title>
    # The folder name Heroic gives a game's default prefix: the title with
    # the characters its removeSpecialcharacters() drops taken out (so
    # "Baldur's Gate 2" becomes "Baldurs Gate 2"). GOG install folders are
    # named the same way.
    printf '%s' "$1" | sed "s/[:|/*?<>\\\\&{}%\$@\`!+'\"™®]//g"
}

heroic_configs_for_prefix() {
    # Usage: heroic_configs_for_prefix <prefix>
    # Every GamesConfig/<id>.json (native and Flatpak) whose winePrefix is
    # exactly this prefix, with or without a trailing slash.
    local p="${1%/}" root
    while IFS=$'\t' read -r _ root; do
        [ -z "$root" ] && continue
        find "$root/GamesConfig" -maxdepth 1 -type f -name "*.json" \
            \( -exec grep -Fq "\"winePrefix\": \"$p\"" {} \; -o -exec grep -Fq "\"winePrefix\": \"$p/\"" {} \; \) -print 2>/dev/null
    done < <(heroic_roots)
}

detect_heroic_prefix_verbose() {
    # Usage: detect_heroic_prefix_verbose <game dir>
    # Finds the game in Heroic's library (installed.json for store games,
    # sideload_apps/library.json for ones added with "Add Game") in every
    # Heroic install present, and works out the prefix Heroic launches it
    # with: the explicit winePrefix in its GamesConfig/<id>.json, else
    # Heroic's own default (config.json's defaultWinePrefix + the title).
    # Progress goes to stderr and the details to the run log; when the game
    # is found, stdout gets one \x1f-separated line:
    #   prefix, GOG app_name (empty for sideloaded), Heroic ID,
    #   prefix source (explicit|default, empty if none), title, config root
    local target_dir="$1"
    local label root json_file install_path record_app_name record_title folder_name executable
    local -a m_label=() m_root=() m_id=() m_gog=() m_title=() m_prefix=() m_source=()

    print_task "Scanning Heroic configuration files" >&2
    log_cmd "heroic: looking up $target_dir"
    if [ -z "$(heroic_roots)" ]; then log_cmd "heroic: no config folder (native or flatpak) found"; fi

    while IFS=$'\t' read -r label root; do
        [ -z "$root" ] && continue
        log_cmd "heroic: $label config folder $root"
        local id="" gog="" title="" is_sideload=0 shown="$label"
        [ "$label" == "flatpak" ] && shown="Flatpak"

        print_status "Looking for the game in $shown Heroic's library..." "" >&2
        while IFS= read -r json_file; do
            [ -z "$json_file" ] && continue
            # Match by install_path rather than a raw substring search, since the
            # user-supplied GAME_DIR may point at a subfolder of the actual
            # install (e.g. GameName/bin/x64) rather than the install root itself.
            while IFS=$'\t' read -r install_path record_app_name; do
                [ -z "$install_path" ] && continue
                if [ "$target_dir" == "$install_path" ] || [[ "$target_dir" == "$install_path"/* ]]; then
                    id="$record_app_name"; gog="$record_app_name"; title="$(basename "$install_path")"
                fi
            done < <(awk 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"(install_path|installPath)"/) { line=$i; sub(/^.*"(install_path|installPath)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); ip=line } if ($i ~ /"(app_name|appName)"/) { line=$i; sub(/^.*"(app_name|appName)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); an=line } } if (ip != "") print ip "\t" an }' "$json_file")
            if [ -n "$id" ]; then log_cmd "heroic: matched in $json_file (ID $id)"; break; fi
        done < <(find "$root" -type f -name "installed.json" 2>/dev/null)

        # Games added manually via Heroic's "Add Game" (sideloaded) aren't in any
        # installed.json -- Heroic lists them in sideload_apps/library.json, keyed
        # by folder_name. Their prefix still lives in GamesConfig/<app_name>.json.
        if [ -z "$id" ]; then
            print_status "Checking $shown Heroic's manually added games..." "" >&2
            json_file="$root/sideload_apps/library.json"
            if [ -f "$json_file" ]; then
                # library.json nests an "install": {...} object inside each game,
                # so the RS="}" record split used for installed.json above would
                # cut each game in half. Track brace depth instead and emit one
                # line per game object (depth 2) when it closes. Fields are split on
                # \037 rather than tab: read collapses runs of whitespace IFS, which
                # would shift fields over whenever one (e.g. folder_name) is empty.
                while IFS=$'\037' read -r record_app_name record_title folder_name executable; do
                    [ -z "$record_app_name" ] && continue
                    [ -z "$folder_name" ] && [ -n "$executable" ] && folder_name=$(dirname "$executable")
                    [ -z "$folder_name" ] && continue
                    if [ "$target_dir" == "$folder_name" ] || [[ "$target_dir" == "$folder_name"/* ]]; then
                        id="$record_app_name"; title="$record_title"; is_sideload=1
                        break
                    fi
                done < <(awk 'function val(s, key) { sub("^.*\"" key "\"[ \t]*:[ \t]*\"", "", s); sub(/".*$/, "", s); return s }
                    { line = $0
                      if (depth == 2) { if (line ~ /"app_name"[ \t]*:/) an = val(line, "app_name"); if (line ~ /"title"[ \t]*:/) ti = val(line, "title"); if (line ~ /"folder_name"[ \t]*:/) fn = val(line, "folder_name") }
                      if (line ~ /"executable"[ \t]*:/) ex = val(line, "executable")
                      opens = gsub(/{/, "{", line); closes = gsub(/}/, "}", line); depth += opens - closes
                      if (closes > 0 && depth <= 1 && an != "") { print an "\037" ti "\037" fn "\037" ex; an = ""; ti = ""; fn = ""; ex = "" } }' "$json_file")
                [ -n "$id" ] && log_cmd "heroic: matched in $json_file (ID $id, title \"$title\")"
            fi
        fi

        if [ -z "$id" ]; then log_cmd "heroic: not in the $label library"; continue; fi

        if [ "$is_sideload" -eq 1 ]; then
            print_status "Found in $shown Heroic's manually added games: ${BOLD}${title:-$id}${NC}" "" >&2
        else
            print_status "Found in $shown Heroic's library: ${BOLD}${title:-$id}${NC}" "" >&2
        fi
        print_status "Reading ${title:-the game}'s Heroic settings..." "" >&2
        local conf="$root/GamesConfig/$id.json" prefix="" source=""
        if [ -f "$conf" ]; then
            prefix=$(heroic_json_value "$conf" winePrefix)
            log_cmd "heroic: $conf winePrefix=\"$prefix\" wineVersion=\"$(heroic_json_value "$conf" name)\" [$(heroic_json_value "$conf" type)]"
        else
            log_cmd "heroic: $conf not found"
        fi
        if [ -n "$prefix" ]; then
            source="explicit"
        else
            # No winePrefix of its own (Heroic 2.22.1's "Add Game" never saved
            # one — Heroic PR #5827) means Heroic launches the game with its
            # global prefix: config.json's "winePrefix", or <prefix folder>/shared
            # when that's unset (game_config.ts: `winePrefix || sharedWinePrefix`).
            # On older installs that global prefix is .../Prefixes/default itself.
            print_status "No prefix of its own, so checking Heroic's shared prefix..." "" >&2
            local default_dir global_prefix cand
            default_dir=$(heroic_json_value "$root/config.json" defaultWinePrefixDir)
            [ -z "$default_dir" ] && default_dir=$(heroic_json_value "$root/config.json" defaultWinePrefix)
            default_dir="${default_dir/#\~/$HOME}"
            global_prefix=$(heroic_json_value "$root/config.json" winePrefix)
            global_prefix="${global_prefix/#\~/$HOME}"
            log_cmd "heroic: $root/config.json winePrefix=\"$global_prefix\" defaultWinePrefixDir/defaultWinePrefix=\"$default_dir\""
            if [ -n "$global_prefix" ]; then
                prefix="${global_prefix%/}"
            elif [ -n "$default_dir" ]; then
                prefix="${default_dir%/}/shared"
            fi
            if [ -n "$prefix" ]; then
                source="shared"
                log_cmd "heroic: no winePrefix of its own, so Heroic uses its shared prefix $prefix ($( [ -d "$prefix/drive_c" ] && echo "exists" || echo "not created yet"))"
            fi
            local fp_data="$HOME/.var/app/com.heroicgameslauncher.hgl/data/heroic/prefixes"
            # What actually exists in each prefix folder, so a report shows
            # the real names.
            local base names seen=""
            for base in ${default_dir:+"$default_dir"} "$HOME/Games/Heroic/Prefixes" "$HOME/Games/Heroic/Prefixes/default" "$fp_data/default" "$fp_data"; do
                base="${base%/}"
                [ -d "$base" ] || continue
                [[ "$seen" == *"|$base|"* ]] && continue
                seen+="|$base|"
                names=$(find "$base" -mindepth 1 -maxdepth 1 -type d ! -name drive_c ! -name dosdevices -printf '"%f"\n' 2>/dev/null | head -n 30 | tr '\n' ' ')
                log_cmd "heroic: prefixes in $base: ${names:-none}"
            done
            # Last resort, only when config.json names no prefix at all: the
            # places a per-game default prefix is usually created.
            if [ -z "$prefix" ]; then
                local -a cands=()
                [ -n "$title" ] && cands+=("$HOME/Games/Heroic/Prefixes/$(heroic_prefix_name "$title")" "$HOME/Games/Heroic/Prefixes/default/$(heroic_prefix_name "$title")")
                cands+=("$HOME/Games/Heroic/Prefixes/$id" "$HOME/Games/Heroic/Prefixes/default/$id")
                [ -n "$title" ] && cands+=("$fp_data/default/$(heroic_prefix_name "$title")" "$fp_data/$(heroic_prefix_name "$title")")
                for cand in "${cands[@]}"; do
                    if [ -d "$cand" ]; then log_cmd "heroic: candidate $cand exists"; prefix="$cand"; source="default"; break; fi
                    log_cmd "heroic: candidate $cand not found"
                done
            fi
        fi

        # Callers treat the returned app_name as a GOG ID (known-games lookups,
        # find_heroic_install_path). A sideloaded game's app_name is a random
        # Heroic-generated ID, so hand back an empty one for those.
        m_label+=("$label"); m_root+=("$root"); m_id+=("$id"); m_gog+=("$gog")
        m_title+=("$title"); m_prefix+=("$prefix"); m_source+=("$source")
    done < <(heroic_roots)

    [ "${#m_id[@]}" -eq 0 ] && { print_status "Search complete. No prefix found." "$YELLOW" >&2; return 0; }

    # First install that yields a prefix wins; if both installs know the game
    # under different prefixes, say so — only the Heroic the user actually
    # launches it from matters.
    local i pick=0
    for i in "${!m_id[@]}"; do
        if [ -n "${m_prefix[$i]}" ]; then pick=$i; break; fi
    done
    for i in "${!m_id[@]}"; do
        if [ "$i" -ne "$pick" ] && [ -n "${m_prefix[$i]}" ] && [ "${m_prefix[$i]%/}" != "${m_prefix[$pick]%/}" ]; then
            local shown_pick="${m_label[$pick]}" shown_other="${m_label[$i]}"
            [ "$shown_pick" == "flatpak" ] && shown_pick="Flatpak"
            [ "$shown_other" == "flatpak" ] && shown_other="Flatpak"
            print_note "${m_title[$pick]:-this game} is set up in both native and Flatpak" \
                "Heroic, and each one uses a different prefix:" \
                "  $shown_pick: ${m_prefix[$pick]}" \
                "  $shown_other: ${m_prefix[$i]}" \
                "The $shown_pick one is suggested below — if you play it from the other" \
                "Heroic, answer no and enter that prefix instead." >&2
            break
        fi
    done

    [ -z "${m_prefix[$pick]}" ] && print_status "Search complete. No prefix found." "$YELLOW" >&2
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "${m_prefix[$pick]}" "${m_gog[$pick]}" "${m_id[$pick]}" \
        "${m_source[$pick]}" "${m_title[$pick]}" "${m_root[$pick]}"
}

check_heroic_prefix_match() {
    # Usage: check_heroic_prefix_match   (returns 1 to ask for a new prefix)
    # A prefix can pass the drive_c check and still not be the one Heroic
    # launches this game with — typed by hand, or left over from an earlier
    # "Add Game" entry — and then the DLL override lands where the game
    # never looks (issue #2). Compares PREFIX_PATH with the game's own
    # Heroic settings and with which Heroic entries claim that prefix. A
    # guessed default that doesn't exist never warns, to avoid false alarms.
    [ -n "$HEROIC_GAME_ID" ] || return 0
    local current expected title="${HEROIC_GAME_TITLE:-this game}" f claimers="" own=0 other=0 reason=""
    current=$(realpath -m "$PREFIX_PATH" 2>/dev/null || echo "${PREFIX_PATH%/}")
    expected=""
    [ -n "$HEROIC_EXPECTED_PREFIX" ] && expected=$(realpath -m "$HEROIC_EXPECTED_PREFIX" 2>/dev/null || echo "${HEROIC_EXPECTED_PREFIX%/}")
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        claimers+="${claimers:+, }$f"
        if [ "$(basename "$f" .json)" == "$HEROIC_GAME_ID" ]; then own=1; else other=1; fi
    done < <(heroic_configs_for_prefix "$PREFIX_PATH")
    log_cmd "heroic prefix check: ID $HEROIC_GAME_ID, Heroic's prefix ${expected:-unknown} (${HEROIC_PREFIX_SOURCE:-none}), using $current, claimed by: ${claimers:-no GamesConfig}"

    # own=1 means this game's own settings (in either Heroic install) use
    # this prefix, which is never a mismatch.
    if [ "$own" -eq 1 ]; then
        :
    elif [[ "$HEROIC_PREFIX_SOURCE" == "explicit" || "$HEROIC_PREFIX_SOURCE" == "shared" ]] && [ "$expected" != "$current" ]; then
        reason="$HEROIC_PREFIX_SOURCE"
    elif [ "$other" -eq 1 ] && [ "$expected" != "$current" ]; then
        reason="other"
    fi
    [ -z "$reason" ] && return 0

    if [ "$reason" == "shared" ]; then
        print_warning "$title has no prefix of its own set" \
            "in Heroic, so Heroic runs it in the shared prefix below instead of the" \
            "one you entered, and EAX wouldn't reach the game:" \
            "  $HEROIC_EXPECTED_PREFIX" \
            "This happens with games added in Heroic 2.22.1. To give the game its" \
            "own prefix, choose one in its Heroic settings (Settings -> WINE)," \
            "launch it once, then run this script again."
    elif [ "$reason" == "explicit" ]; then
        print_warning "Heroic runs $title in a different prefix" \
            "from the one you entered, so EAX wouldn't reach the game from there:" \
            "  $HEROIC_EXPECTED_PREFIX"
    else
        print_warning "This prefix belongs to a different game in Heroic's library," \
            "so it's probably not where $title runs. Its Heroic settings" \
            "(Settings -> WINE) show the WinePrefix folder the game actually uses."
        log_cmd "heroic prefix check: prefix belongs to $claimers"
    fi

    if [ -n "$HEROIC_EXPECTED_PREFIX" ] && [ -d "$HEROIC_EXPECTED_PREFIX/drive_c" ]; then
        [ "$reason" == "other" ] && print_status "A prefix named after $title exists: $HEROIC_EXPECTED_PREFIX" "$WHITE"
        # The shared prefix is every such game's, so switching there puts
        # the audio files and DLL override under all of them — opt-in only.
        local switch_default="Y"
        if [ "$reason" == "shared" ] || [ "$HEROIC_PREFIX_SOURCE" == "shared" ]; then
            switch_default="N"
            print_paragraph "Heroic's shared prefix is used by every game without a prefix of its own," \
                "so installing there would apply the audio files and DLL override to all of" \
                "them, not just $title."
        fi
        if confirm "Use the prefix Heroic uses for $title instead?" "$switch_default"; then
            PREFIX_PATH="$HEROIC_EXPECTED_PREFIX"
            print_status "Using: $PREFIX_PATH" "$GREEN"
            log_cmd "heroic prefix check: switched to $PREFIX_PATH"
            return 0
        fi
    elif confirm "Enter a different prefix path?" N; then
        log_cmd "heroic prefix check: user chose to enter another prefix"
        return 1
    fi
    log_cmd "heroic prefix check: user kept $PREFIX_PATH"
    return 0
}

find_heroic_install_path() {
    # Usage: find_heroic_install_path <gog_app_name_id>
    # Looks up a Heroic-tracked GOG game's install_path by its (confusingly
    # named) numeric app_name/appName ID. detect_heroic_prefix_verbose above
    # discovers this same install_path internally too, but only while
    # matching FROM a target directory, and doesn't expose it back to its
    # caller — this is for callers that already have the ID (e.g. from a
    # confirmed prefix) and just need the folder, to read the game's real
    # name off its own install metadata rather than the curated JSON.
    local want="$1"
    [ -z "$want" ] && return
    local json_file
    find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null | while IFS= read -r json_file; do
        [ -z "$json_file" ] && continue
        awk -v want="$want" 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"(install_path|installPath)"/) { line=$i; sub(/^.*"(install_path|installPath)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); ip=line } if ($i ~ /"(app_name|appName)"/) { line=$i; sub(/^.*"(app_name|appName)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); an=line } } if (an == want && ip != "") { print ip; exit } }' "$json_file"
    done | head -n 1
}

normalize_game_name() {
    # Usage: normalize_game_name <string>
    # Lowercases, converts standalone (word-bounded) roman numerals II-IX to
    # arabic digits, then strips everything but letters/digits. Used to
    # compare a game's folder name against candidate .exe basenames despite
    # "Gothic II" vs "Gothic2.exe"-style numeral-style mismatches. Bare I/V/X
    # are deliberately NOT converted -- unlike II-IX they're also ordinary
    # standalone words/initials (e.g. "X-COM", "I Am Alive"), and converting
    # those would corrupt the comparison instead of fixing it.
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E \
        -e 's/(^|[^a-z0-9])viii([^a-z0-9]|$)/\1 8 \2/g' \
        -e 's/(^|[^a-z0-9])vii([^a-z0-9]|$)/\1 7 \2/g' \
        -e 's/(^|[^a-z0-9])vi([^a-z0-9]|$)/\1 6 \2/g' \
        -e 's/(^|[^a-z0-9])iv([^a-z0-9]|$)/\1 4 \2/g' \
        -e 's/(^|[^a-z0-9])ix([^a-z0-9]|$)/\1 9 \2/g' \
        -e 's/(^|[^a-z0-9])iii([^a-z0-9]|$)/\1 3 \2/g' \
        -e 's/(^|[^a-z0-9])ii([^a-z0-9]|$)/\1 2 \2/g' \
        | tr -dc '[:alnum:]'
}

resolve_exe_manual_entry() {
    # Usage: resolve_exe_manual_entry <scanned_root>
    # Prompts for a game .exe folder, validates it exists, and warns when it
    # falls outside the scanned install (the known-game notes may not apply).
    # Returns 0 with GAME_DIR set, 1 otherwise (GAME_DIR cleared). Shared by
    # every "enter a path manually" branch of resolve_exe_folder so declining
    # a detected folder drops the user straight onto a path prompt instead of
    # unwinding to the top-level locate-the-game menu (which throws away the
    # scanned AppID and its known-games notes).
    local root="$1"
    prompt_manual_game_dir || return 1
    if [ ! -d "$GAME_DIR" ]; then
        print_error "Directory not found. Please check the path and try again."
        GAME_DIR=""
        return 1
    fi
    [[ "$GAME_DIR" == "$root"* ]] || print_warning "That path is outside the scanned install — the known-game notes for this title may not apply to it."
    return 0
}

resolve_exe_folder() {
    # Usage: resolve_exe_folder <install_root> [beta_branch]
    # A scanned install root isn't always the .exe folder — many titles nest
    # it (e.g. GameName/bin/x64), and get_game_directory's own detection
    # comment notes exactly this. Mirrors the prefix stage's shape: first
    # asks whether to auto-detect at all (No -> straight to manual entry),
    # then builds one ranked list of candidate folders (the root itself, if
    # it holds a real .exe, followed by nested folders ranked name-match
    # first) and shows the best one for a "Found ... / Use this location?"
    # (Y/n) confirm. Declining opens a menu -- pick from the other detected
    # folders (when there's more than one), type a path, or go back to game
    # selection -- rather than dead-ending. Returns 1 (GAME_DIR left empty)
    # if the user declines/goes back at any point.
    #
    # beta_branch (optional, from known-eax-games.json's stores.steam.beta_branch)
    # tailors the "no .exe found" case: some titles (e.g. KOTOR2) ship a
    # native Linux port that Steam installs by default, which has no .exe at
    # all -- the Windows build only comes down once the user opts into that
    # beta branch. Passed in by scan_game_libraries, which already knows the
    # matched game's known-games entry at this point.
    local root="$1"
    local beta_branch="$2"
    GAME_DIR=""

    print_step 2 "Locate Game Executable"

    # Nested installs often bundle third-party installers/utilities
    # alongside the real game .exe (redistributables, anti-cheat setup,
    # crash handlers, uninstallers, DRM clients like TAGES). Folder name
    # alone isn't a reliable filter -- "Launcher" or "bin" folders
    # legitimately hold real game exes for some titles too -- so this blocks
    # by the installer/utility's own distinctive basename instead, wherever
    # it's nested.
    local junk_exe_re='^(unins(t(all)?)?[0-9]*|vc_?redist.*|(dx|directx)?setup|dxsetup|dxwebsetup|dx[0-9]+ger|dx[0-9]+ntger|dotnetfx.*|ndp[0-9].*|windowsdesktop-runtime.*|oalinst|physx.*|easyanticheat.*|eac_?setup.*|eaclauncher|be(service|daisy|launcher|_ex)[a-z0-9_]*|battleye.*|unitycrashhandler.*|crashreport(er|client)?|crash_?handler|crashpad_handler|bugsplat.*|epiconlineservices(installer)?|epicwebhelper.*|rockstar-games-launcher|social-club-setup|tagesclient.*|vulkanrt.*installer.*|gamingrepair(tool)?|registrationreminder|overlayinjector|cleanup|touchup|driverversionchecker|layerschecker|supporttool|dowser|iscopyfiles|ue3?redist.*|unrealfrontend|unrealconsole|uescriptprofiler|cookersync|testapp|.*oshelper)\.exe$'

    # Up-front gate, same as the prefix stage's "attempt to automatically
    # find your Proton prefix?" -- a detected folder is still a guess, and
    # some users would rather just type the path. confirm defaults to Yes and
    # returns 1 on EOF, so a closed stdin falls to manual entry, which itself
    # returns 1 on EOF -- a clean bail, no spin.
    if ! confirm "Would you like the script to attempt to automatically find the game's executable folder?"; then
        resolve_exe_manual_entry "$root" && return 0
        return 1
    fi

    local f base exe_norm root_norm
    root_norm="$(normalize_game_name "$(basename "$root")")"

    # One ranked list of candidate folders + a representative .exe name per
    # folder (knowing the location isn't as reassuring as seeing the actual
    # filename about to be treated as the game's executable).
    local -a cand_dirs=()
    local -A cand_exe_name=()

    # The scanned root itself, if it directly holds a real (non-junk) .exe.
    # Pick a representative name to show: prefer one that isn't on the junk
    # list and resembles the folder's own name, falling back to whatever's
    # there so this never reports nothing.
    if find "$root" -maxdepth 1 -type f -iname "*.exe" -print -quit 2>/dev/null | grep -q .; then
        local root_exes=() root_exe_name=""
        while IFS= read -r f; do root_exes+=("$f"); done < <(find "$root" -maxdepth 1 -type f -iname "*.exe" 2>/dev/null)
        for f in "${root_exes[@]}"; do
            base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
            [[ "$base" =~ $junk_exe_re ]] && continue
            [ -z "$root_exe_name" ] && root_exe_name="$(basename "$f")"
            exe_norm="$(normalize_game_name "$(basename "$f" .exe)")"
            if [ -n "$root_norm" ] && { [[ "$exe_norm" == *"$root_norm"* ]] || [[ "$root_norm" == *"$exe_norm"* ]]; }; then
                root_exe_name="$(basename "$f")"
                break
            fi
        done
        [ -z "$root_exe_name" ] && root_exe_name="$(basename "${root_exes[0]}")"
        cand_dirs+=("$root")
        cand_exe_name["$root"]="$root_exe_name"
    fi

    # Then nested folders below the root, ranked name-match first -- e.g. a
    # "Half-Life" install's real exe is more likely hl.exe/Half-Life.exe than
    # something sharing a folder with unrelated bundled tools. Roman numerals
    # are converted to arabic first (word-bounded, so it only touches
    # standalone numeral tokens) since sequel titles are commonly "Gothic II"
    # but "Gothic2.exe"/"gothic 2" in practice.
    # -mindepth 2 so the scanned root's own .exe files (already handled above)
    # aren't re-listed here as if they lived in a nested folder.
    local all_exes=()
    while IFS= read -r f; do all_exes+=("$f"); done < <(find "$root" -mindepth 2 -maxdepth 4 -type f -iname "*.exe" 2>/dev/null)

    local candidates=()
    for f in "${all_exes[@]}"; do
        base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        [[ "$base" =~ $junk_exe_re ]] && continue
        candidates+=("$f")
    done
    # Only fall back to the junk-only set when the root gave us nothing
    # either -- otherwise a game whose real .exe is in the root but which
    # also ships junk installers in subfolders would wrongly become a
    # multi-candidate pick instead of a clean single-candidate confirm.
    [ ${#candidates[@]} -eq 0 ] && [ ${#cand_dirs[@]} -eq 0 ] && candidates=("${all_exes[@]}")

    local -A dir_seen=()
    local ordered_dirs=() d
    for f in "${candidates[@]}"; do
        d="$(dirname "$f")"
        if [ -z "${dir_seen[$d]:-}" ]; then
            dir_seen["$d"]=1
            ordered_dirs+=("$d")
        fi
    done

    # A directory counts as a name match if ANY .exe inside it matches -- not
    # just whichever one find() happens to list first, since a real
    # launcher/helper .exe often sits right next to the actual game .exe in
    # the same folder.
    local -A dir_exe_name=()
    local dirs=() dirs_matched=() dir_is_match
    for d in "${ordered_dirs[@]}"; do
        dir_is_match=""
        for f in "${candidates[@]}"; do
            [ "$(dirname "$f")" = "$d" ] || continue
            [ -z "${dir_exe_name[$d]:-}" ] && dir_exe_name["$d"]="$(basename "$f")"
            exe_norm="$(normalize_game_name "$(basename "$f" .exe)")"
            if [ -n "$root_norm" ] && { [[ "$exe_norm" == *"$root_norm"* ]] || [[ "$root_norm" == *"$exe_norm"* ]]; }; then
                dir_is_match=1
                dir_exe_name["$d"]="$(basename "$f")"
                break
            fi
        done
        if [ -n "$dir_is_match" ]; then
            dirs_matched+=("$d")
        else
            dirs+=("$d")
        fi
    done
    dirs=("${dirs_matched[@]}" "${dirs[@]}")
    for d in "${dirs[@]}"; do
        cand_dirs+=("$d")
        cand_exe_name["$d"]="${dir_exe_name[$d]}"
    done

    if [ ${#cand_dirs[@]} -eq 0 ]; then
        print_warning "No .exe files were found anywhere under this install."
        if [ -n "$beta_branch" ]; then
            print_note "if Steam installed a native Linux build instead of Windows, opting" \
                "into the '$beta_branch' beta branch (right-click the game -> Properties ->" \
                "Betas) switches it to the Windows build this script needs."
        fi
        if confirm "Use the install root anyway?" N; then GAME_DIR="$root"; return 0; fi
        return 1
    fi

    # Confirm the top pick (the scanned root when it holds a real .exe,
    # otherwise the best name-matched nested folder) — the same
    # "Found ... / Use this location?" the prefix stage uses for its detected
    # value. Declining opens a menu rather than dead-ending back at the
    # locate-the-game step: step through the other detected folders, type a
    # path, or go back to game selection.
    echo -e "\n -> ${GREEN}Found the game executable:${NC} ${cand_exe_name[${cand_dirs[0]}]} ${DIM}in ${cand_dirs[0]}${NC}"
    if confirm "Use this location?"; then
        GAME_DIR="${cand_dirs[0]}"
        return 0
    fi

    local have_more=0 fb_max=2
    if [ ${#cand_dirs[@]} -gt 1 ]; then have_more=1; fb_max=3; fi

    echo ""
    if [ "$have_more" -eq 1 ]; then
        print_option 1 "Choose from the other detected folders"
        print_option 2 "Enter the game's .exe folder path manually"
        print_option 3 "Go back and choose a different game"
    else
        print_option 1 "Enter the game's .exe folder path manually"
        print_option 2 "Go back and choose a different game"
    fi
    local choice
    while true; do
        prompt "Selection [1-${fb_max}]: "
        read_answer choice || return 1
        [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$fb_max" ] && break
        print_warning "That's not a valid option — please enter a number from 1-${fb_max}."
    done

    if [ "$have_more" -eq 1 ] && [ "$choice" -eq 1 ]; then
        print_result "Detected folders with .exe files — pick the one with the game's main executable:"
        local i
        for i in "${!cand_dirs[@]}"; do
            print_option "$((i + 1))" "${cand_exe_name[${cand_dirs[$i]}]}" "in ${cand_dirs[$i]}"
        done
        print_option 0 "None of these / enter a path manually"
        while true; do
            prompt "Selection [0-${#cand_dirs[@]}]: "
            read_answer choice || return 1
            if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le ${#cand_dirs[@]} ]; then
                break
            fi
            print_warning "That's not a valid option — please enter a number from 0-${#cand_dirs[@]}."
        done
        if [ "$choice" -eq 0 ]; then
            resolve_exe_manual_entry "$root" && return 0
            return 1
        fi
        GAME_DIR="${cand_dirs[$((choice - 1))]}"
        return 0
    fi

    # Collapse to manual=1 / go-back=2 whether or not the "other folders"
    # entry was present.
    [ "$have_more" -eq 1 ] && choice=$((choice - 1))
    [ "$choice" -eq 1 ] && resolve_exe_manual_entry "$root" && return 0
    return 1
}

detect_api_from_binary() {
    # Usage: detect_api_from_binary <game_dir>
    # Fallback heuristic for games with no known-eax-games.json entry: greps
    # the game's own .exe/.dll files for the literal ASCII import-table
    # strings "OpenAL32.dll" / "dsound.dll" — the same signature-grepping
    # trick is_genuine_dll() uses on PE binaries, and the same `file`-based
    # PE inspection select_architecture uses to walk GAME_DIR. Prints
    # "openal", "directsound3d", or "both" on stdout, or nothing if
    # inconclusive. "both" means the imports reference both APIs — the caller
    # treats that as a low-confidence DirectSound3D guess, not a confirmation.
    # Not certain: a dynamically-LoadLibrary'd audio backend won't show up
    # in the import table at all, and an engine that supports multiple
    # backends may reference both. On a reinstall, this script's own
    # previously-deployed dsound.dll/dsoal-aldrv.dll/OpenAL32.dll would
    # otherwise sit right here and get read back as if they were evidence
    # about the game itself — excluded by name.
    local dir="$1"
    local has_openal=0 has_dsound=0
    local f
    while IFS= read -r -d '' f; do
        case "$(basename "$f")" in
            dsound.dll|dsoal-aldrv.dll|OpenAL32.dll) continue ;;
        esac
        grep -qa "OpenAL32\.dll" "$f" 2>/dev/null && has_openal=1
        grep -qa "dsound\.dll" "$f" 2>/dev/null && has_dsound=1
    done < <(find "$dir" -maxdepth 2 -type f \( -iname "*.exe" -o -iname "*.dll" \) -print0 2>/dev/null)

    if [ "$has_openal" -eq 1 ] && [ "$has_dsound" -eq 1 ]; then
        echo "both"
    elif [ "$has_openal" -eq 1 ]; then
        echo "openal"
    elif [ "$has_dsound" -eq 1 ]; then
        echo "directsound3d"
    fi
}

confirm_continue_if_openal_native() {
    # Usage: confirm_continue_if_openal_native <id> <steam|gog> <game_name>
    # A resolved audio API of "openal" means this game's own EAX
    # implementation routes through OpenAL natively rather than DirectSound3D — the
    # dsound.dll/DSOAL swap has nothing to intercept here. Offers a distinct
    # remediation (direct OpenAL32.dll + alsoft.ini deployment) instead of a
    # hard stop. Opens with a single upfront gate ("attempt to automatically
    # detect $game_name's audio API?") governing everything below it -- when
    # show_game_details_block already showed this game's documented API
    # (KNOWN_GAME_API set), accepting the gate cross-checks that value
    # against a live file scan instead of re-querying the database from
    # scratch (the user was already told the answer), while declining it
    # just trusts the documented value as-is with no file scan. When nothing
    # is already known, the same gate governs the known-games database check
    # and detect_api_from_binary()'s lower-confidence
    # filesystem guess whenever there's no authoritative JSON answer to go
    # on — either the game isn't in known-eax-games.json, OR the database
    # itself couldn't be loaded at all (offline, not yet merged to the
    # branch it's fetched from, etc.). When even that comes back empty (scan
    # declined, or ran but matched neither import string), it spells out what
    # couldn't be checked and prompts a DirectSound3D-vs-OpenAL choice rather
    # than assuming DirectSound3D — the "Audio Engine Selection" step only
    # lists the DSOAL builds, so this is the sole route into OpenAL-native
    # mode for a title nothing could identify. Every outcome prints a line
    # explaining what was checked and what was concluded; this step should
    # never end in total silence, which reads as broken rather than "nothing
    # to do."
    # A confirmed known-games match still gets a (Y/n) before continuing,
    # same as the openal/binary-scan branches below it — it's still an
    # auto-detected value driving what the script does next.
    # Sets OPENAL_NATIVE_MODE, which the "Audio Engine Selection" step alone
    # consumes to pick ENGINE_CHOICE=2 (the direct OpenAL Soft swap).
    OPENAL_NATIVE_MODE=""
    # Set only when the API is *positively* identified as DirectSound3D (a
    # known-games entry that resolves to "directsound3d" for this store, a
    # single-API binary scan, or the user explicitly choosing DirectSound3D
    # at the fallback prompt below). The "Audio Engine Selection" step skips
    # its menu when this is set, the same way OPENAL_NATIVE_MODE forces the
    # native swap. A bare default / early return leaves it empty so the menu
    # still appears.
    API_CONFIRMED_DS3D=""
    [ "$SCRIPT_ACTION" == "i" ] || return
    # No early return on an empty store ID (a manually entered Heroic
    # prefix with no GamesConfig match, say): only the database lookup
    # needs it. The file scan and the DirectSound3D/OpenAL choice below
    # still apply, and skipping them left the step as a bare header.

    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local game_name="${3:-this game}"

    local attempt_auto_detect=1
    confirm "Would you like the script to attempt to automatically detect $game_name's audio API?" || attempt_auto_detect=0

    local json_available=0 match_count=0
    local api="" matched=0 scanned=0 json_checked=0 declined=0
    # The known-games entry's audio API for this store, exactly as stored —
    # the per-store override (stores.<store>.api) if present, else default_api,
    # else "" when the entry omits both. Distinct from $api, which is
    # defaulted to "directsound3d" for display. Only a literal "directsound3d"
    # here counts as confirmed.
    local db_api_raw=""

    if [ -n "$KNOWN_GAME_API" ]; then
        # Already resolved and displayed in the GAME DETAILS block shown
        # earlier this run (show_game_details_block sets this alongside
        # SCANNED_NOTES_SHOWN) -- no need to re-query the database from
        # scratch. The gate above still governs whether it's cross-checked
        # against the installed files or simply trusted as-is.
        api="$KNOWN_GAME_API"
        db_api_raw="$api"
        matched=1
        json_checked=1

        local api_display="DirectSound3D"
        [ "$api" == "openal" ] && api_display="OpenAL"

        if [ "$attempt_auto_detect" -eq 0 ]; then
            print_note "Skipping the file cross-check -- using the known-games database's documented" \
                "$api_display API as-is."
        elif [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ]; then
            print_task "Cross-checking $game_name's installed files against the documented $api_display API"
            local scan_result
            scan_result=$(detect_api_from_binary "$GAME_DIR")
            if [ -z "$scan_result" ] || [ "$scan_result" == "both" ] || [ "$scan_result" == "$api" ]; then
                print_status "Consistent with the known-games database." "$GREEN"
            else
                local scan_display="DirectSound3D"
                [ "$scan_result" == "openal" ] && scan_display="OpenAL"
                print_warning "$game_name's installed files appear to reference $scan_display, which" \
                    "conflicts with the known-games database's documented $api_display."
                if ! confirm "Trust the known-games database ($api_display) over the file scan?"; then
                    api="$scan_result"
                    scanned=1
                fi
            fi
        else
            print_note "$game_name's folder isn't resolved yet, so the documented API couldn't be" \
                "cross-checked against its installed files."
        fi
    elif [ "$attempt_auto_detect" -eq 0 ]; then
        declined=1
    else
        # Availability is already known by this point (the REPOSITORY CACHE
        # CHECK step fetches/memoizes it before Phase 1 even starts), so
        # there's nothing further to ask permission for here — the gate
        # above already covers it.
        ensure_known_games_json && json_available=1

        if [ "$json_available" -eq 0 ]; then
            json_checked=1
            print_note "known-eax-games.json isn't available this run."
        elif [ -z "$1" ]; then
            json_checked=1
            print_note "$game_name's store ID isn't known, so it can't be looked up in the" \
                "known-games database."
        else
            json_checked=1
            echo ""
            print_status "Checking known-games database for $game_name's audio API..."

            match_count=$(jq -r --arg id "$1" --arg store "$store" '[.games[] | select((.stores[$store].id // "") | tostring == $id)] | length' "$KNOWN_GAMES_FILE" 2>/dev/null)

            if [ "${match_count:-0}" -gt 0 ]; then
                db_api_raw=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | (.stores[$store].api // .default_api // "")' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
                api="${db_api_raw:-directsound3d}"
                matched=1
            else
                print_note "$game_name isn't in the known-games database."
            fi
        fi
    fi

    if [ "$matched" -eq 0 ] && [ "$attempt_auto_detect" -eq 1 ] && [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ]; then
        print_task "Searching for Audio APIs"
        print_status "Scanning $game_name's .exe/.dll files for OpenAL32.dll/dsound.dll references..."  ""
        api=$(detect_api_from_binary "$GAME_DIR")
        scanned=1
    fi

    if [ -n "$api" ]; then
        local api_display="DirectSound3D"
        [ "$api" == "openal" ] && api_display="OpenAL"
        print_status "Detected: ${BOLD}$api_display${NC}" ""
        [ "$matched" -eq 1 ] && [ -z "$SCANNED_NOTES_SHOWN" ] && show_game_details_block "$1" "$2" "$GAME_DIR"

        if [ "$api" == "openal" ]; then
            print_note "This game routes EAX through OpenAL rather than DirectSound3D, so kcat's" \
                "OpenAL Soft will be deployed."
            if ! confirm "Continue with OpenAL Soft deployment?"; then
                echo -e "\n${WHITE}Install cancelled.${NC}"
                exit 0
            fi
            OPENAL_NATIVE_MODE=1
        elif confirm "Continue with the DSOAL/DirectSound3D install?"; then
            # A known-games entry that resolves to "directsound3d" for this
            # store, or a single-API binary scan, is a positive identification — the
            # engine-selection menu can be skipped. A "both" scan result
            # references both APIs and stays low-confidence, so the menu is
            # kept as the route into OpenAL-native mode.
            if { [ "$matched" -eq 1 ] && [ "$db_api_raw" == "directsound3d" ]; } ||
               { [ "$scanned" -eq 1 ] && [ "$api" == "directsound3d" ]; }; then
                API_CONFIRMED_DS3D=1
            fi
        else
            echo -e "\n${WHITE}Install cancelled.${NC}"
            exit 0
        fi
        return
    fi

    # Nothing authoritative to go on — no known-games entry (or the database
    # wasn't available), and the file scan was either declined or turned up
    # neither import string. Rather than assume DirectSound3D outright, spell
    # out what couldn't be checked and let the user pick: the "Audio Engine
    # Selection" step only lists the DSOAL builds, so this prompt is also the
    # only way into OpenAL-native mode for a title the scan can't identify.
    if [ "$scanned" -eq 1 ]; then
        print_note_arrow "The scan found no OpenAL or DirectSound3D references in $game_name's" \
            "files, so its audio API couldn't be confirmed."
    elif [ "$declined" -eq 1 ]; then
        print_note_arrow "Auto-detection was skipped, so $game_name's audio API is unconfirmed."
    elif [ "$json_checked" -eq 0 ]; then
        print_note_arrow "The known-games check was skipped and $game_name's files couldn't be" \
            "scanned, so its audio API is unconfirmed."
    elif [ "$json_available" -eq 0 ]; then
        print_note_arrow "known-eax-games.json isn't available this run and $game_name's files" \
            "couldn't be scanned, so its audio API is unconfirmed."
    else
        print_note_arrow "$game_name isn't in the known-games database and its files couldn't be" \
            "scanned, so its audio API is unconfirmed."
    fi

    echo -e "\n${WHITE}Almost every classic EAX title uses DirectSound3D; only a handful route"
    echo -e "EAX through OpenAL natively. Choose DirectSound3D unless you know this"
    echo -e "game is one of the exceptions.${NC}"
    echo ""
    print_option 1 "DirectSound3D / DSOAL   [default]"
    print_option 2 "OpenAL native           (deploy kcat's OpenAL Soft directly)"

    local api_choice explicit=0
    while true; do
        prompt "Selection (1 or 2) [Default: 1]: "
        # EOF / empty falls back to 1: DirectSound3D is the safe default for
        # the overwhelming majority of EAX titles. Only a typed "1" is an
        # explicit choice — an accepted default doesn't confirm the API, so
        # the engine-selection menu still appears for it.
        read_answer api_choice || api_choice=""
        if [ "$api_choice" == "1" ]; then explicit=1; else explicit=0; fi
        api_choice="${api_choice:-1}"
        [[ "$api_choice" =~ ^[12]$ ]] && break
        print_warning "That's not a valid option — please type 1 or 2."
    done

    if [ "$api_choice" == "2" ]; then
        print_status "Proceeding with kcat's OpenAL Soft." "$WHITE"
        OPENAL_NATIVE_MODE=1
    else
        [ "$explicit" -eq 1 ] && API_CONFIRMED_DS3D=1
        print_status "Proceeding with DSOAL / DirectSound3D." "$WHITE"
    fi
}

detect_game_environment() {
    APPID=""
    PREFIX_PATH=""

    local attempt_auto_detect=1
    confirm "Would you like the script to attempt to automatically find the game's prefix?" || attempt_auto_detect=0

    if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
        LAUNCHER_TYPE="1"
        print_result "Steam installation detected!" "$GREEN"

        if [ -n "$SCANNED_APPID" ]; then
            # Already known from the library scanner in get_game_directory —
            # skip the redundant search and go straight to prefix
            # verification below regardless of the gate above: the AppID is
            # already known, and the prefix lookup after it is a mandatory
            # protontricks query with no manual alternative, so there's
            # nothing left here for the gate to meaningfully govern.
            APPID="$SCANNED_APPID"
            print_status "Using AppID ${BOLD}$APPID${NC} from the library scan." ""
        else
            if [ "$attempt_auto_detect" -eq 1 ]; then
                print_task "Searching for Steam AppID"
                # Use the top-level folder directly under steamapps/common/, not
                # the leaf of GAME_DIR — the .exe is often nested in a subfolder
                # (e.g. GameName/bin/x64), whose basename won't match the
                # appmanifest's "installdir" value.
                INSTALL_DIR="${GAME_DIR#*/steamapps/common/}"
                INSTALL_DIR="${INSTALL_DIR%%/*}"
                print_status "Scanning local appmanifest files for folder: $INSTALL_DIR" ""
                # Escape BRE metacharacters (folder names with brackets, dots, etc.
                # are common — e.g. "[Definitive Edition]") since this pattern
                # also relies on \s as a wildcard, which -F would otherwise take
                # away by disabling regex interpretation entirely.
                INSTALL_DIR_ESCAPED=$(printf '%s' "$INSTALL_DIR" | sed 's/[][\.*^$]/\\&/g')
                MANIFEST_FILE=$(grep -il "\"installdir\"\s*\"$INSTALL_DIR_ESCAPED\"" "${GAME_DIR%/common/*}"/appmanifest_*.acf 2>/dev/null | head -n 1)

                if [ -n "$MANIFEST_FILE" ]; then
                    AUTO_APPID=$(basename "$MANIFEST_FILE" | tr -dc '0-9')
                    print_status "Found AppID: ${BOLD}$AUTO_APPID${NC}" ""
                    if confirm "Use this detected Steam AppID?"; then APPID="$AUTO_APPID"; fi
                else
                    print_status "Search complete. No matching AppID found." "$YELLOW"
                fi
            fi
        fi

        pin_steam_dir
        print_task "Verifying Wine Prefix"
        while true; do
            if [ -z "$APPID" ]; then
                echo -e "\n${YELLOW}Enter the Steam AppID manually: ${NC}"
                echo -e "${WHITE} Tip: Found on the game's Steam Store URL, or in Steam by right-clicking the game -> Properties -> Updates.${NC}"
                echo -e -n "> "
                if ! read_answer APPID; then
                    # stdin closed (piped/exhausted) — can't keep prompting, so
                    # offer game reselection / exit rather than spinning.
                    print_error "A Steam AppID is required — protontricks uses it to locate the game's Proton prefix."
                    prompt_restart_or_quit 0
                    return
                fi
                APPID=$(echo "$APPID" | tr -dc '0-9')
                # Empty / non-numeric entry: re-prompt. There's no skip — the
                # AppID is required for protontricks to locate the prefix.
                [ -z "$APPID" ] && continue
            fi

            echo ""
            print_status "Querying Protontricks database for AppID ${BOLD}${APPID}${NC}..." ""
            # Output (and errors) go to the log too, so a failed lookup shows why.
            log_cmd "protontricks -c 'echo \$WINEPREFIX' $APPID${STEAM_DIR:+ (STEAM_DIR=$STEAM_DIR)}"
            DETECTED_STEAM_PREFIX=$(protontricks -c 'echo $WINEPREFIX' "$APPID" 2>> "$EAX_LOG_FILE" | tee -a "$EAX_LOG_FILE" | grep "/pfx" | tail -n 1 | tr -d '\r')

            if [ -n "$DETECTED_STEAM_PREFIX" ] && [ -d "$DETECTED_STEAM_PREFIX" ]; then
                echo -e " -> ${GREEN}Detected Prefix:${NC} $DETECTED_STEAM_PREFIX"
                if confirm "Use this detected prefix?"; then
                    PREFIX_PATH="$DETECTED_STEAM_PREFIX"
                    ACF_FILE="${GAME_DIR%/common/*}/appmanifest_${APPID}.acf"
                    confirm_continue_if_eax_impossible "$APPID" "steam" "$ACF_FILE"
                    # User chose to go back and pick a different game — unwind
                    # to the config flow's Step 1-2 loop.
                    [ -n "$RESTART_REQUESTED" ] && return
                    if [ -z "$GAME_NAME" ]; then
                        # Same source appid/gog_id already come from, not the
                        # curated JSON — the appmanifest's own "name" key.
                        [ -f "$ACF_FILE" ] && GAME_NAME=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ACF_FILE" 2>/dev/null | head -n 1)
                        [ -z "$GAME_NAME" ] && GAME_NAME="AppID $APPID"
                    fi
                    break
                fi
                APPID=""
            elif [ -d "$STEAM_LIBRARY/steamapps/compatdata/$APPID/pfx/drive_c" ]; then
                # The prefix is right there beside the game, so it's
                # protontricks that can't see it — and every later registry
                # step goes through protontricks too, so it has to be fixed
                # rather than worked around.
                log_cmd "steam: $STEAM_LIBRARY/steamapps/compatdata/$APPID/pfx exists, but protontricks didn't report it"
                print_error "The Proton prefix for AppID ${APPID} exists, but protontricks couldn't find it:" \
                    "  $STEAM_LIBRARY/steamapps/compatdata/$APPID/pfx"
                if declare -F protontricks &>/dev/null; then
                    # Preflight only defines the function for the Flatpak build.
                    print_paragraph "Flatpak protontricks can only see the folders it has been given access to." \
                        "Allow it to read this Steam library by running the command below, then" \
                        "check again:" \
                        "" \
                        "  flatpak override --user --filesystem=\"$STEAM_LIBRARY\" com.github.Matoking.protontricks"
                else
                    print_paragraph "protontricks' own output is in the run log, and usually says why."
                fi
                if ! confirm "Check this AppID again?"; then APPID=""; fi
            else
                print_error "Proton prefix not found for AppID ${APPID}."
                echo -e "\n${WHITE}If you just installed this game, Proton has not generated the prefix yet."
                echo -e "Please launch the game at least once, close it, and try again.${NC}"
                if ensure_known_games_json; then
                    local beta_branch
                    beta_branch=$(jq -r --arg id "$APPID" \
                        '.games[] | select((.stores.steam.id // "") | tostring == $id) | .stores.steam.beta_branch // empty' \
                        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
                    if [ -n "$beta_branch" ]; then
                        print_note "no prefix at all can also mean Steam installed a native Linux build" \
                            "instead of Windows — no Proton is used for that. Opting into the" \
                            "'$beta_branch' beta branch (right-click the game -> Properties -> Betas)" \
                            "switches it to the Windows build this script needs."
                    fi
                fi
                # "No" clears the AppID and drops back to the manual prompt for a
                # corrected value; an empty entry there triggers restart/quit.
                if ! confirm "Check this AppID again?"; then APPID=""; fi
            fi
        done
    else
        LAUNCHER_TYPE="2"
        print_result "Non-Steam installation detected (Heroic/GOG, or a manually created Wine prefix)!" "$GREEN"
        HEROIC_APP_NAME=""
        HEROIC_GAME_ID=""; HEROIC_EXPECTED_PREFIX=""; HEROIC_PREFIX_SOURCE=""; HEROIC_GAME_TITLE=""; HEROIC_ROOT=""
        DETECTED_PREFIX=""; DETECTED_APP_NAME=""
        if [ "$attempt_auto_detect" -eq 1 ]; then
            IFS=$'\x1f' read -r DETECTED_PREFIX DETECTED_APP_NAME HEROIC_GAME_ID HEROIC_PREFIX_SOURCE HEROIC_GAME_TITLE HEROIC_ROOT \
                <<< "$(detect_heroic_prefix_verbose "$GAME_DIR")"
        else
            # Still look the game up (quietly) so the prefix check below can
            # compare a hand-typed prefix with the one Heroic uses.
            IFS=$'\x1f' read -r DETECTED_PREFIX DETECTED_APP_NAME HEROIC_GAME_ID HEROIC_PREFIX_SOURCE HEROIC_GAME_TITLE HEROIC_ROOT \
                <<< "$(detect_heroic_prefix_verbose "$GAME_DIR" 2>/dev/null)"
        fi
        HEROIC_EXPECTED_PREFIX="$DETECTED_PREFIX"
        if [ "$attempt_auto_detect" -eq 1 ]; then
            if [ -n "$DETECTED_PREFIX" ]; then
                echo -e " -> ${GREEN}Detected Prefix:${NC} $DETECTED_PREFIX"
                [ "$HEROIC_PREFIX_SOURCE" == "shared" ] && print_status "This is Heroic's shared prefix, because ${HEROIC_GAME_TITLE:-this game} has no prefix of its own." "$DIM"
                if confirm "Use this detected prefix?"; then
                    PREFIX_PATH="$DETECTED_PREFIX"
                    HEROIC_APP_NAME="$DETECTED_APP_NAME"
                fi
            fi
        fi

        while true; do
            if [ -z "$PREFIX_PATH" ]; then
                echo -e "\n${YELLOW}Enter the Wine prefix path: ${NC}"
                echo -e "${WHITE} Example Heroic: ~/Games/Heroic/Prefixes/[Game-Name]${NC}"
                echo -e -n "> "
                if ! read_answer PREFIX_PATH; then
                    # stdin closed (piped/exhausted) — can't keep prompting, so
                    # offer game reselection / exit rather than spinning.
                    print_error "A Wine prefix is required — it's where the DLL override and prefix-side files go."
                    prompt_restart_or_quit 0
                    return
                fi
                # Empty entry: re-prompt. There's no skip — the prefix is where
                # the DLL override, the system32/syswow64 copy and the VC++
                # check all happen.
                [ -z "$PREFIX_PATH" ] && continue
                PREFIX_PATH="${PREFIX_PATH//\'/}"; PREFIX_PATH="${PREFIX_PATH//\"/}"; PREFIX_PATH="${PREFIX_PATH%/}"
                PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
            fi

            if [ -d "$PREFIX_PATH/drive_c" ]; then
                echo ""
                print_status "Prefix verified!" "$GREEN"
                if ! check_heroic_prefix_match; then PREFIX_PATH=""; continue; fi
                confirm_continue_if_eax_impossible "$HEROIC_APP_NAME" "gog"
                # User chose to go back and pick a different game — unwind to
                # the config flow's Step 1-2 loop.
                [ -n "$RESTART_REQUESTED" ] && return
                if [ -z "$GAME_NAME" ] && [ -n "$HEROIC_APP_NAME" ]; then
                    # Same source the GOG ID already comes from, not the
                    # curated JSON — Heroic's own install folder name.
                    HEROIC_INSTALL_PATH=$(find_heroic_install_path "$HEROIC_APP_NAME")
                    [ -n "$HEROIC_INSTALL_PATH" ] && GAME_NAME="$(basename "$HEROIC_INSTALL_PATH")"
                    [ -z "$GAME_NAME" ] && GAME_NAME="GOG ID $HEROIC_APP_NAME"
                fi
                break
            else
                print_error "Initialised Wine prefix not found at that location."
                echo -e "\n${WHITE}If you just installed this game, the launcher has not generated the prefix yet."
                echo -e "Please run the game at least once, close it, and try again.${NC}"

                # "No" clears the path and drops back to the manual prompt for a
                # corrected value; an empty entry there triggers restart/quit.
                if ! confirm "Check this path again?"; then PREFIX_PATH=""; fi
            fi
        done

        # Runs for uninstall too: its registry cleanup goes through the
        # same Wine binary, so it needs the game's own runner just as much.
        # Not gated or confirmed, unlike the prefix search: this reads the
        # settings of the prefix just confirmed rather than guessing, and
        # any other Wine would reintroduce the mismatch this fixes.
        if [ -n "$PREFIX_PATH" ]; then
            print_task "Checking which Wine version Heroic uses for this game"
            resolve_heroic_runner
        fi
    fi
}

resolve_heroic_runner() {
    # Points WINE_CMD/WINESERVER_CMD at the Wine build Heroic actually runs
    # this game with, read from its GamesConfig/<app>.json "wineVersion".
    # Preflight's default is whatever `wine` is on PATH (or the first one
    # under Heroic's tools folder) — e.g. a system Wine 8.0 writing into a
    # GE-Proton 11 prefix, which is what a Halo CE bug report showed. Wine
    # and Proton keep the registry in different layouts between versions,
    # so the game's own runner is the only one whose changes are sure to
    # land where the game will read them. Heroic's Proton prefixes keep
    # drive_c at the prefix root (pfx is a symlink to "."), so Proton's own
    # files/bin/wine can run against PREFIX_PATH directly.
    local json="" runner_type runner_bin runner_name dir wine_bin="" server_bin=""
    # The game's own settings first (when it was found in Heroic's library
    # and they name a Wine version), else whichever entry claims this prefix.
    if [ -n "$HEROIC_GAME_ID" ] && [ -n "$HEROIC_ROOT" ] && grep -q '"wineVersion"' "$HEROIC_ROOT/GamesConfig/$HEROIC_GAME_ID.json" 2>/dev/null; then
        json="$HEROIC_ROOT/GamesConfig/$HEROIC_GAME_ID.json"
    else
        json=$(heroic_configs_for_prefix "$PREFIX_PATH" | head -n 1)
    fi
    log_cmd "heroic runner: reading ${json:-no GamesConfig found}"
    HEROIC_JSON="$json"
    if [ -n "$json" ]; then
        # \x1f-separated rather than @tsv: tab is IFS whitespace, so an
        # empty field (no "name", say) would shift the rest one to the left.
        IFS=$'\x1f' read -r runner_type runner_bin runner_name server_bin <<< "$(jq -r \
            'first(.[] | objects | select(.wineVersion?) | .wineVersion) | [.type // "", .bin // "", .name // "", .wineserver // ""] | join("\u001f")' \
            "$json" 2>/dev/null)"
        case "$runner_type" in
            proton)
                dir=$(dirname "$runner_bin")
                for d in "$dir/files/bin" "$dir/dist/bin"; do
                    if [ -x "$d/wine" ]; then wine_bin="$d/wine"; server_bin="$d/wineserver"; break; fi
                done
                ;;
            wine)
                [ -x "$runner_bin" ] && wine_bin="$runner_bin"
                [ -z "$server_bin" ] && server_bin="$(dirname "$runner_bin")/wineserver"
                ;;
        esac
    fi

    if [ -n "$wine_bin" ]; then
        WINE_CMD="$wine_bin"
        WINESERVER_CMD=""
        [ -x "$server_bin" ] && WINESERVER_CMD="$server_bin"
        # Name only, as Heroic's own Wine Version dropdown shows it; the
        # full path goes in the run log's "Wine used:" summary line.
        print_status "Using the same Wine version Heroic launches ${GAME_NAME:-this game} with: ${runner_name:-$runner_type}" "$GREEN"
        return 0
    fi

    WINESERVER_CMD=""
    if [ -n "$runner_type" ]; then
        print_note_arrow "the Wine version Heroic launches ${GAME_NAME:-this game} with (${runner_name:-$runner_type}) wasn't found at" \
            "$runner_bin, so ${WINE_CMD:-no Wine binary} will be used instead. If EAX doesn't show up" \
            "in-game, that's the likely cause."
    elif [ -n "$WINE_CMD" ]; then
        print_note_arrow "no Heroic settings were found for this prefix, so $WINE_CMD will be used. If" \
            "${GAME_NAME:-the game} runs on Proton or a different Wine build, EAX may not show up in-game."
    fi
    return 1
}

flush_wine_registry() {
    # Wine keeps the registry in wineserver's memory and only writes
    # user.reg once the server shuts down, so wait for that before reading
    # the file back. Best-effort: a timeout just means the check below may
    # not see the change yet.
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$APPID" ]; then
        log_cmd "protontricks wineserver -w (AppID $APPID)"
        # timeout goes inside -c: the Flatpak protontricks is a shell
        # function, which timeout can't run.
        run_with_spinner "Checking the DLL override..." "$EAX_LOG_FILE" protontricks -c "timeout 60 wineserver -w" "$APPID"
    elif [ -n "$WINE_CMD" ]; then
        local server="${WINESERVER_CMD:-$(dirname "$WINE_CMD")/wineserver}"
        [ -x "$server" ] || server="wineserver"
        log_cmd "$server -w (prefix $PREFIX_PATH)"
        run_with_spinner "Checking the DLL override..." "$EAX_LOG_FILE" env WINEPREFIX="$PREFIX_PATH" timeout 60 "$server" -w
    fi
}

registry_has_value() {
    # Usage: registry_has_value <reg file> <section> <line>
    # e.g. registry_has_value "$PREFIX_PATH/user.reg" 'Software\\Wine\\DllOverrides' '"dsound"="native,builtin"'
    # Looks for an exact value line inside one section of a Wine .reg store
    # file. Values go through ENVIRON, not awk -v, because -v would collapse
    # the doubled backslashes Wine writes in section names.
    SEC="[$2]" WANT="$3" awk 'BEGIN { sec = ENVIRON["SEC"]; want = tolower(ENVIRON["WANT"]) }
        index($0, sec " ") == 1 || $0 == sec { in_sec = 1; next }
        /^\[/ { in_sec = 0 }
        in_sec && tolower($0) == want { found = 1 }
        END { exit !found }' "$1"
}

verify_dll_override() {
    # Usage: verify_dll_override <dll name>
    # Reads the override back from the prefix's user.reg after regedit
    # reported success — regedit can exit 0 without the key ever landing
    # (e.g. a different Wine build than the prefix's own). Returns 0 if
    # found, 1 if missing, 2 if there's no user.reg to check (never treated
    # as a failure, since that says nothing about the override itself).
    local dll="$1" store="$PREFIX_PATH/user.reg"
    flush_wine_registry
    [ -f "$store" ] || { log_cmd "override check skipped: $store not found"; return 2; }
    if registry_has_value "$store" 'Software\\Wine\\DllOverrides' "\"$dll\"=\"native,builtin\""; then
        log_cmd "override check: \"$dll\"=\"native,builtin\" found in $store"
        return 0
    fi
    log_cmd "override check: \"$dll\"=\"native,builtin\" NOT found in $store"
    return 1
}

apply_registry_patch() {
    # Returns regedit's exit status, or 1 when there was nothing to run it
    # with (no AppID / Wine binary / prefix) or the .reg file couldn't be
    # written — callers use this to decide whether to report "Injected" or
    # "removed", so it must never look like success when nothing happened.
    local reg_file="$1" rc=1
    if [ ! -s "$reg_file" ]; then
        log_cmd "regedit skipped: $reg_file is missing or empty"
        return 1
    fi
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$APPID" ]; then
        log_cmd "protontricks regedit $reg_file (AppID $APPID)"; sed 's/^/  | /' "$reg_file" >> "$EAX_LOG_FILE" 2>/dev/null
        run_with_spinner "Updating the prefix's registry..." "$EAX_LOG_FILE" protontricks -c "regedit \"$reg_file\"" "$APPID"
        rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    elif [ "$LAUNCHER_TYPE" == "2" ] && [ -d "$PREFIX_PATH/drive_c" ] && [ -n "$WINE_CMD" ]; then
        log_cmd "$WINE_CMD regedit $reg_file (prefix $PREFIX_PATH)"; sed 's/^/  | /' "$reg_file" >> "$EAX_LOG_FILE" 2>/dev/null
        run_with_spinner "Updating the prefix's registry..." "$EAX_LOG_FILE" env WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" regedit "$reg_file"
        rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    else
        log_cmd "regedit skipped: no AppID, Wine binary, or prefix to apply $reg_file to"
    fi
    return "$rc"
}

select_architecture() {
    # Usage: select_architecture [step_number]
    # Sets ARCH ("32" or "64") and ARCH_FOLDER ("Win32" or "Win64") based on
    # the game's executable(s) in GAME_DIR, either via auto-detection or a
    # manual prompt. Shared by the normal install flow and any standalone
    # flow that needs to know the game's architecture (e.g. VC++-only mode) —
    # each caller has its own step sequence, so the displayed step number is
    # a parameter rather than hardcoded.
    local step="${1:-3}"
    print_step "$step" "Architecture Selection"
    print_paragraph "This step determines whether the game executable is 32-bit or 64-bit." \
        "If the wrong version is selected, the game will crash without showing an error message."

    ARCH="MANUAL"
    if command -v file &> /dev/null; then
        if confirm "Attempt to auto-detect 32/64-bit architecture?"; then
            A32=0; A64=0
            while IFS= read -r -d '' exe; do
                [[ $(file "$exe") == *"PE32+"* ]] && ((A64++)) || ((A32++))
            done < <(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" -print0)
            if [ "$A64" -gt 0 ] && [ "$A32" -eq 0 ]; then
                DETECTED="64"
            elif [ "$A32" -gt 0 ] && [ "$A64" -eq 0 ]; then
                DETECTED="32"
            else
                DETECTED="UNKNOWN"
            fi
            if [ "$DETECTED" != "UNKNOWN" ]; then
                if confirm "Detected ${DETECTED}-bit. Continue?"; then ARCH="$DETECTED"; fi
            fi
        fi
    fi
    if [ "$ARCH" == "MANUAL" ]; then
        while true; do
            prompt "Architecture (32/64): "
            read_answer ARCH
            if [[ "$ARCH" == "32" || "$ARCH" == "64" ]]; then break
            else print_warning "Invalid selection. Please type 32 or 64."; fi
        done
    fi
    ARCH_FOLDER=$([ "$ARCH" == "64" ] && echo "Win64" || echo "Win32")
}
