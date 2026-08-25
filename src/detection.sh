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
        echo -e "${NOTE}Note: library scanning needs the known-EAX-games database, which isn't"
        echo -e "available this run — skipping straight to manual entry.${NC}\n"
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
        if [ "$can_scan" -eq 1 ]; then
            echo -e "${WHITE} $((${#menu_actions[@]} + 1))) Scan your Steam/Heroic library for known EAX games${NC}"
            menu_actions+=("scan")
        fi
        if [ "$have_gui_picker" -eq 1 ]; then
            echo -e "${WHITE} $((${#menu_actions[@]} + 1))) Browse for the folder using a graphical file picker${NC}"
            menu_actions+=("gui")
        fi
        echo -e "${WHITE} $((${#menu_actions[@]} + 1))) Enter the path manually${NC}"
        menu_actions+=("manual")

        local action
        if [ "${#menu_actions[@]}" -eq 1 ]; then
            action="${menu_actions[0]}"
        else
            local choice
            while true; do
                echo -e "\n${YELLOW}How would you like to locate the game? [1-${#menu_actions[@]}]: ${NC}"
                echo -e -n "> "
                read -r choice
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
                if ! confirm "Continue with the scan?"; then
                    continue
                fi
                if scan_game_libraries; then
                    echo -e "\n${GREEN}Using: $GAME_DIR${NC}"
                    record_recent_game "$GAME_DIR"
                    return
                fi
                continue
                ;;
            gui)
                show_hidden_folder_tip_popup
                GAME_DIR=$(pick_directory_gui)
                GAME_DIR="${GAME_DIR%/}"
                if [ -z "$GAME_DIR" ]; then
                    print_warning "No folder selected."
                    continue
                fi
                ;;
            manual)
                echo -e "\n${YELLOW}Enter the full path to the game's .exe folder:${NC}"
                echo -e -n "> "
                read -r GAME_DIR

                GAME_DIR="${GAME_DIR//\'/}"; GAME_DIR="${GAME_DIR//\"/}"; GAME_DIR="${GAME_DIR%/}"
                GAME_DIR="${GAME_DIR/#\~/$HOME}"
                ;;
        esac

        if [ -d "$GAME_DIR" ]; then
            if [ "$SCRIPT_ACTION" == "i" ]; then
                EXE_COUNT=$(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" | wc -l)
                if [ "$EXE_COUNT" -eq 0 ]; then
                    print_warning "No .exe files were found in this directory or its immediate subfolders."
                    if confirm "Are you absolutely sure this is the correct game folder?" N; then break; fi
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

detect_heroic_prefix_verbose() {
    local target_dir="$1"
    local auto_prefix=""
    local app_name=""

    echo -e "\n${CYAN}STATUS: Scanning Heroic configuration files...${NC}" >&2
    local installed_jsons
    installed_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)

    print_status "Searching installed.json for matching game path..." "" >&2
    while IFS= read -r json_file; do
        [ -z "$json_file" ] && continue
        app_name=""
        # Match by install_path rather than a raw substring search, since the
        # user-supplied GAME_DIR may point at a subfolder of the actual
        # install (e.g. GameName/bin/x64) rather than the install root itself.
        while IFS=$'\t' read -r install_path record_app_name; do
            [ -z "$install_path" ] && continue
            if [ "$target_dir" == "$install_path" ] || [[ "$target_dir" == "$install_path"/* ]]; then
                app_name="$record_app_name"
            fi
        done < <(awk 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"(install_path|installPath)"/) { line=$i; sub(/^.*"(install_path|installPath)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); ip=line } if ($i ~ /"(app_name|appName)"/) { line=$i; sub(/^.*"(app_name|appName)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); an=line } } if (ip != "") print ip "\t" an }' "$json_file")

        if [ -n "$app_name" ]; then
            print_status "Game found! Internal ID: ${BOLD}$app_name${NC}" "" >&2
            print_status "Parsing GamesConfig/$app_name.json for custom prefix paths..." "" >&2
            local config_jsons
            config_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/$app_name.json" 2>/dev/null)
            while IFS= read -r conf_file; do
                [ -z "$conf_file" ] && continue
                auto_prefix=$(grep '"winePrefix"' "$conf_file" | awk -F '"' '{print $4}')
                [ -n "$auto_prefix" ] && break
            done <<< "$config_jsons"
        fi
        [ -n "$auto_prefix" ] && break
    done <<< "$installed_jsons"

    if [ -n "$app_name" ] && [ -z "$auto_prefix" ]; then
        print_status "No custom prefix defined. Checking default Heroic locations..." "" >&2
        if [ -d "$HOME/Games/Heroic/Prefixes/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/$app_name"
        elif [ -d "$HOME/Games/Heroic/Prefixes/default/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/default/$app_name"
        fi
    fi

    if [ -n "$auto_prefix" ]; then printf '%s\t%s\n' "$auto_prefix" "$app_name"; else echo -e " -> ${YELLOW}Search complete. No prefix found.${NC}" >&2; fi
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

resolve_exe_folder() {
    # Usage: resolve_exe_folder <install_root>
    # A scanned install root isn't always the .exe folder — many titles nest
    # it (e.g. GameName/bin/x64), and get_game_directory's own detection
    # comment notes exactly this. Finds where the .exe(s) actually live,
    # always asks the user to confirm before setting GAME_DIR (a detected
    # location is a guess, not an action taken on the user's behalf), and
    # prompts to pick between candidates when more than one folder qualifies.
    # Returns 1 (GAME_DIR left empty) if the user declines at any point.
    local root="$1"
    GAME_DIR=""

    # Nested installs often bundle third-party installers/utilities
    # alongside the real game .exe (redistributables, anti-cheat setup,
    # crash handlers, uninstallers). Folder name alone isn't a reliable
    # filter -- "Launcher" or "bin" folders legitimately hold real game
    # exes for some titles too -- so this blocks by the installer/utility's
    # own distinctive basename instead, wherever it's nested.
    local junk_exe_re='^(unins(t(all)?)?[0-9]*|vc_?redist.*|(dx|directx)?setup|dxsetup|dxwebsetup|dx[0-9]+ger|dx[0-9]+ntger|dotnetfx.*|ndp[0-9].*|windowsdesktop-runtime.*|oalinst|physx.*|easyanticheat.*|eac_?setup.*|eaclauncher|be(service|daisy|launcher|_ex)[a-z0-9_]*|battleye.*|unitycrashhandler.*|crashreport(er|client)?|crash_?handler|crashpad_handler|bugsplat.*|epiconlineservices(installer)?|epicwebhelper.*|rockstar-games-launcher|social-club-setup|vulkanrt.*installer.*|gamingrepair(tool)?|registrationreminder|overlayinjector|cleanup|touchup|driverversionchecker|layerschecker|supporttool|dowser|iscopyfiles|ue3?redist.*|unrealfrontend|unrealconsole|uescriptprofiler|cookersync|testapp|.*oshelper)\.exe$'

    if find "$root" -maxdepth 1 -type f -iname "*.exe" -print -quit 2>/dev/null | grep -q .; then
        # Pick a representative exe name to show: prefer one whose name
        # isn't on the junk list and resembles the folder's own name,
        # falling back to whatever's there so this never reports nothing.
        local root_exes=() f base root_norm exe_norm root_exe_name=""
        while IFS= read -r f; do root_exes+=("$f"); done < <(find "$root" -maxdepth 1 -type f -iname "*.exe" 2>/dev/null)
        root_norm="$(normalize_game_name "$(basename "$root")")"
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

        echo -e "\n -> ${GREEN}Found the game executable:${NC} $root_exe_name ${DIM}in $root${NC}"
        if confirm "Use this location?"; then
            GAME_DIR="$root"
            return 0
        fi
        return 1
    fi

    local all_exes=()
    while IFS= read -r f; do all_exes+=("$f"); done < <(find "$root" -mindepth 1 -maxdepth 4 -type f -iname "*.exe" 2>/dev/null)

    local candidates=() f base
    for f in "${all_exes[@]}"; do
        base="$(basename "$f" | tr '[:upper:]' '[:lower:]')"
        [[ "$base" =~ $junk_exe_re ]] && continue
        candidates+=("$f")
    done
    # If every .exe found happened to match the junk list, fall back to the
    # unfiltered set rather than wrongly reporting none were found at all.
    [ ${#candidates[@]} -eq 0 ] && candidates=("${all_exes[@]}")

    # Rank folders whose .exe name resembles the game's own folder name
    # first -- e.g. a "Half-Life" install's real exe is more likely
    # hl.exe/Half-Life.exe than something sharing a folder with unrelated
    # bundled tools. Roman numerals are converted to arabic first (word-
    # bounded, so it only touches standalone numeral tokens) since sequel
    # titles are commonly "Gothic II" but "Gothic2.exe"/"gothic 2" in
    # practice -- a plain substring match would miss that pairing.
    local root_norm
    root_norm="$(normalize_game_name "$(basename "$root")")"

    local -A dir_seen=()
    local ordered_dirs=() f d
    for f in "${candidates[@]}"; do
        d="$(dirname "$f")"
        if [ -z "${dir_seen[$d]:-}" ]; then
            dir_seen["$d"]=1
            ordered_dirs+=("$d")
        fi
    done

    # A directory counts as a name match if ANY .exe inside it matches --
    # not just whichever one find() happens to list first, since a real
    # launcher/helper .exe often sits right next to the actual game .exe
    # in the same folder.
    # Also remembers a representative .exe name per folder to show the user
    # (the name-matching one if there is one, otherwise whichever candidate
    # came first) -- knowing the location isn't as reassuring as seeing the
    # actual filename that's about to be treated as the game's executable.
    local -A dir_exe_name=()
    local dirs=() dirs_matched=() exe_norm dir_is_match
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

    if [ ${#dirs[@]} -eq 1 ]; then
        echo -e "\n -> ${GREEN}Found the game executable:${NC} ${dir_exe_name[${dirs[0]}]} ${DIM}in ${dirs[0]}${NC}"
        if confirm "Use this location?"; then
            GAME_DIR="${dirs[0]}"
            return 0
        fi
        return 1
    elif [ ${#dirs[@]} -gt 1 ]; then
        echo -e "\n${WHITE}Multiple folders with .exe files were found under this install — pick the one"
        echo -e "with the game's main executable:${NC}"
        local i
        for i in "${!dirs[@]}"; do
            echo -e "${WHITE} $((i + 1))) ${BOLD}${dir_exe_name[${dirs[$i]}]}${NC}${DIM} in ${dirs[$i]}${NC}"
        done
        echo -e "${WHITE} 0) None of these / enter a path manually${NC}"
        echo -e "\n${YELLOW}Selection [0-${#dirs[@]}]: ${NC}"
        echo -e -n "> "
        local choice
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#dirs[@]} ]; then
            GAME_DIR="${dirs[$((choice - 1))]}"
            return 0
        fi
        return 1
    else
        print_warning "No .exe files were found anywhere under this install."
        if confirm "Use the install root anyway?" N; then GAME_DIR="$root"; return 0; fi
        return 1
    fi
}

detect_api_from_binary() {
    # Usage: detect_api_from_binary <game_dir>
    # Fallback heuristic for games with no known-eax-games.json entry: greps
    # the game's own .exe/.dll files for the literal ASCII import-table
    # strings "OpenAL32.dll" / "dsound.dll" — the same signature-grepping
    # trick is_genuine_dll() uses on PE binaries, and the same `file`-based
    # PE inspection select_architecture uses to walk GAME_DIR. Prints
    # "openal" or "directsound3d" on stdout, or nothing if inconclusive.
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

    if [ "$has_openal" -eq 1 ] && [ "$has_dsound" -eq 0 ]; then
        echo "openal"
    elif [ "$has_dsound" -eq 1 ]; then
        echo "directsound3d"
    fi
}

confirm_continue_if_openal_native() {
    # Usage: confirm_continue_if_openal_native <id> <steam|gog> <game_name>
    # api == "openal" means this game's own EAX implementation routes
    # through OpenAL natively rather than DirectSound3D — the
    # dsound.dll/DSOAL swap has nothing to intercept here. Offers a distinct
    # remediation (direct OpenAL32.dll + alsoft.ini deployment) instead of a
    # hard stop. Falls back to detect_api_from_binary()'s lower-confidence
    # filesystem guess whenever there's no authoritative JSON answer to go
    # on — either the game isn't in known-eax-games.json, OR the database
    # itself couldn't be loaded at all (offline, not yet merged to the
    # branch it's fetched from, etc.) — rather than silently assuming
    # DirectSound3D in either case. Every outcome prints a line explaining
    # what was checked and what was concluded; this step should never end
    # in total silence, which reads as broken rather than "nothing to do."
    # A confirmed known-games match still gets a (Y/n) before continuing,
    # same as the openal/binary-scan branches below it — it's still an
    # auto-detected value driving what the script does next.
    # Sets OPENAL_NATIVE_MODE, which the "Audio Engine Selection" step alone
    # consumes to pick ENGINE_CHOICE=4.
    OPENAL_NATIVE_MODE=""
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return

    local field="steam_appid"
    [ "$2" == "gog" ] && field="gog_id"
    local game_name="${3:-this game}"

    local json_available=0 match_count=0
    local api="" matched=0 scanned=0 json_checked=0 declined=0

    # Availability is already known by this point (the REPOSITORY CACHE CHECK
    # step fetches/memoizes it before Phase 1 even starts), so there's nothing
    # to ask permission for when it's simply not there — go straight to the
    # scan gate below instead of prompting a question with a foregone answer.
    ensure_known_games_json && json_available=1

    if [ "$json_available" -eq 0 ]; then
        json_checked=1
        print_note "known-eax-games.json isn't available this run."
    elif confirm "Would you like the script to check the known-games database for $game_name's audio API?"; then
        json_checked=1
        echo ""
        print_status "Checking known-games database for $game_name's audio API..."

        match_count=$(jq -r --arg id "$1" --arg field "$field" '[.games[] | select((.[$field] // "") | tostring == $id)] | length' "$KNOWN_GAMES_FILE" 2>/dev/null)

        if [ "${match_count:-0}" -gt 0 ]; then
            api=$(jq -r --arg id "$1" --arg field "$field" '.games[] | select((.[$field] // "") | tostring == $id) | .api // "directsound3d"' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
            matched=1
        else
            print_note "$game_name isn't in the known-games database."
        fi
    fi

    if [ "$matched" -eq 0 ] && [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ]; then
        if confirm "Would you like the script to attempt to detect whether $game_name uses OpenAL or DirectSound3D?"; then
            echo ""
            print_status "Scanning $game_name's .exe/.dll files for OpenAL32.dll/dsound.dll references..."
            api=$(detect_api_from_binary "$GAME_DIR")
            scanned=1
        else
            declined=1
        fi
    fi

    local api_display="DirectSound3D"
    [ "$api" == "openal" ] && api_display="OpenAL"

    if [ -n "$api" ]; then
        print_status "Detected: $api_display" "$GREEN"
        [ "$matched" -eq 1 ] && [ -z "$SCANNED_NOTES_SHOWN" ] && show_game_details_block "$1" "$2" "$GAME_DIR"
    fi

    if [ "$api" == "openal" ]; then
        print_note "This game routes EAX through OpenAL rather than DirectSound3D, so kcat's" \
            "OpenAL Soft will be deployed."
        if ! confirm "Continue with OpenAL Soft deployment?"; then
            echo -e "\n${WHITE}Install cancelled.${NC}"
            exit 0
        fi
        OPENAL_NATIVE_MODE=1
        return
    fi

    if [ "$matched" -eq 1 ] || [ "$scanned" -eq 1 ]; then
        if ! confirm "Continue with the DSOAL/DirectSound3D install?"; then
            echo -e "\n${WHITE}Install cancelled.${NC}"
            exit 0
        fi
    elif [ "$declined" -eq 1 ]; then
        print_status "Skipped the file scan — assuming standard DirectSound3D." "$WHITE"
    elif [ "$json_checked" -eq 0 ]; then
        print_note_arrow "Skipped the known-games check, and $game_name's files couldn't be" \
            "scanned either — assuming standard DirectSound3D."
    else
        if [ "$json_available" -eq 0 ]; then
            print_note_arrow "known-eax-games.json isn't available this run, and $game_name's files" \
                "couldn't be scanned either — assuming standard DirectSound3D."
        else
            print_note_arrow "$game_name isn't in the known-games database, and its files couldn't be" \
                "scanned either — assuming standard DirectSound3D."
        fi
    fi
}

detect_game_environment() {
    APPID=""
    PREFIX_PATH=""

    if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
        LAUNCHER_TYPE="1"
        print_result "Steam installation detected!" "$GREEN"

        if [ -n "$SCANNED_APPID" ]; then
            # Already known from the library scanner in get_game_directory —
            # skip the redundant search/confirmation and go straight to
            # prefix verification below.
            APPID="$SCANNED_APPID"
            print_status "Using AppID ${BOLD}$APPID${NC} from the library scan." ""
        else
            if confirm "Would you like the script to attempt to automatically find your Proton prefix?"; then
                echo -e "\n${CYAN}STATUS: Searching for Steam AppID...${NC}"
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

        echo -e "\n${CYAN}Verifying Wine Prefix...${NC}"
        while true; do
            if [ -z "$APPID" ]; then
                echo -e "\n${YELLOW}Enter the Steam AppID manually (or press Enter to skip): ${NC}"
                echo -e "${WHITE} Tip: Found on the game's Steam Store URL, or in Steam by right-clicking the game -> Properties -> Updates.${NC}"
                echo -e -n "> "
                read -r APPID
                APPID=$(echo "$APPID" | tr -dc '0-9')
                [ -z "$APPID" ] && break
            fi

            print_status "Querying Protontricks database for AppID ${BOLD}${APPID}${NC}..." ""
            DETECTED_STEAM_PREFIX=$(protontricks -c 'echo $WINEPREFIX' "$APPID" 2>/dev/null | grep "/pfx" | tail -n 1 | tr -d '\r')

            if [ -n "$DETECTED_STEAM_PREFIX" ] && [ -d "$DETECTED_STEAM_PREFIX" ]; then
                echo -e " -> ${GREEN}Detected Prefix:${NC} $DETECTED_STEAM_PREFIX"
                if confirm "Use this detected prefix?"; then
                    PREFIX_PATH="$DETECTED_STEAM_PREFIX"
                    confirm_continue_if_eax_impossible "$APPID" "steam"
                    if [ -z "$GAME_NAME" ]; then
                        # Same source appid/gog_id already come from, not the
                        # curated JSON — the appmanifest's own "name" key.
                        ACF_FILE="${GAME_DIR%/common/*}/appmanifest_${APPID}.acf"
                        [ -f "$ACF_FILE" ] && GAME_NAME=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$ACF_FILE" 2>/dev/null | head -n 1)
                        [ -z "$GAME_NAME" ] && GAME_NAME="AppID $APPID"
                    fi
                    break
                fi
                APPID=""
            else
                print_error "Proton prefix not found for AppID ${APPID}."
                echo -e "\n${WHITE}If you just installed this game, Proton has not generated the prefix yet."
                echo -e "Please launch the game at least once, close it, and try again.${NC}"
                if ! confirm "Check this AppID again?"; then APPID=""; fi
            fi
        done
    else
        LAUNCHER_TYPE="2"
        print_result "Non-Steam installation detected (Heroic/GOG, or a manually created Wine prefix)!" "$GREEN"
        HEROIC_APP_NAME=""
        if confirm "Would you like the script to attempt to automatically find your Wine prefix?"; then
            IFS=$'\t' read -r DETECTED_PREFIX DETECTED_APP_NAME <<< "$(detect_heroic_prefix_verbose "$GAME_DIR")"
            if [ -n "$DETECTED_PREFIX" ]; then
                echo -e " -> ${GREEN}Detected Prefix:${NC} $DETECTED_PREFIX"
                if confirm "Use this detected prefix?"; then
                    PREFIX_PATH="$DETECTED_PREFIX"
                    HEROIC_APP_NAME="$DETECTED_APP_NAME"
                fi
            fi
        fi

        while true; do
            if [ -z "$PREFIX_PATH" ]; then
                echo -e "\n${YELLOW}Enter the Wine Prefix path manually (or press Enter to skip): ${NC}"
                echo -e "${WHITE} Example Heroic: ~/Games/Heroic/Prefixes/[Game-Name]${NC}"
                echo -e -n "> "
                read -r PREFIX_PATH
                [ -z "$PREFIX_PATH" ] && break
                PREFIX_PATH="${PREFIX_PATH//\'/}"; PREFIX_PATH="${PREFIX_PATH//\"/}"; PREFIX_PATH="${PREFIX_PATH%/}"
                PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
            fi

            if [ -d "$PREFIX_PATH/drive_c" ]; then
                print_status "Prefix verified!" "$GREEN"
                confirm_continue_if_eax_impossible "$HEROIC_APP_NAME" "gog"
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

                if ! confirm "Check this path again?"; then PREFIX_PATH=""; fi
            fi
        done

        if [ "$SCRIPT_ACTION" == "i" ] && [ -n "$PREFIX_PATH" ]; then
            echo -e "\n${CYAN}STATUS: Analysing Heroic runner configuration...${NC}"
            HEROIC_JSON=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/*.json" -exec grep -Fl "\"winePrefix\": \"$PREFIX_PATH\"" {} + 2>/dev/null | head -n 1)

            if [ -n "$HEROIC_JSON" ]; then
                if grep -iq '"type": "proton"\|"name": ".*proton' "$HEROIC_JSON"; then
                    print_status "Proton runner detected within Heroic configuration." "$YELLOW"
                else
                    print_status "Standard Wine runner detected." "$GREEN"
                fi
            fi
        fi
    fi
}

apply_registry_patch() {
    local reg_file="$1"
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$APPID" ]; then
        protontricks -c "regedit \"$reg_file\"" "$APPID" &>/dev/null
    elif [ "$LAUNCHER_TYPE" == "2" ] && [ -d "$PREFIX_PATH/drive_c" ]; then
        if [ -n "$WINE_CMD" ]; then
            WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" regedit "$reg_file" &>/dev/null
        fi
    fi
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
    print_paragraph "This step determines whether the game executable is 32-bit or 64-bit so the script" \
        "can deploy the correct architecture for the audio wrapper files. If the wrong version" \
        "is selected, the game will silently fail to load the custom audio engine."

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
                if confirm "Detected ${DETECTED}-bit. Correct?"; then ARCH="$DETECTED"; fi
            fi
        fi
    fi
    if [ "$ARCH" == "MANUAL" ]; then
        while true; do
            echo -e "\n${YELLOW}Architecture (32/64): ${NC}"
            echo -e -n "> "
            read -r ARCH
            if [[ "$ARCH" == "32" || "$ARCH" == "64" ]]; then break
            else print_warning "Invalid selection. Please type 32 or 64."; fi
        done
    fi
    ARCH_FOLDER=$([ "$ARCH" == "64" ] && echo "Win64" || echo "Win32")
}
