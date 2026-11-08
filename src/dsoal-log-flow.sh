# ==============================================================================
# DSOAL LOGGING (Tools → [D]SOAL logging)
# ==============================================================================
# Turns the sound logs on or off for one game by setting variables in its Steam
# launch options or Heroic environment variables — what you'd otherwise type in
# by hand to see what a game asks the audio fix to do. OpenAL Soft's log
# (ALSOFT_LOGLEVEL 3 and ALSOFT_LOGFILE, openal.log) is always set; DSOAL's
# (DSOAL_LOGLEVEL and DSOAL_LOGFILE, dsoal.log) too when DSOAL is installed in
# the game folder. DSOAL_LOGLEVEL is one less than DSOAL's internal level: 3 traces startup
# and the API calls, 4 (Debug) adds every EAX property call, which is what
# shows which EAX version a game actually uses. Changes nothing else, and
# isn't recorded in the install manifest: running this again turns it off,
# and uninstall drops the variables along with the DLL override when that was
# set through the launcher (it has no launcher record otherwise).
if [ -n "$DSOAL_LOG_MODE" ]; then
    print_banner "DSOAL LOGGING"
    tool_gate "This turns the sound log on or off for one game. It records what the game asks" \
        "the audio fix to do, which helps when EAX doesn't sound right or when you're writing a bug report." \
        || { OPEN_TOOLS_MENU=1; continue; }

    SCRIPT_ACTION="i"
    STEP_TOTAL=3

    # Steps 1-2 loop, same as the other flows (see prompt_restart_or_quit).
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        print_paragraph "This step finds the folder the game is installed in."
        get_game_directory ""
        # Only step 1's [R]eturn sets it here: back to the Tools menu.
        [ -n "$RESTART_REQUESTED" ] && { OPEN_TOOLS_MENU=1; continue 2; }

        print_step 2 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    print_step 3 "Sound Logging"
    print_paragraph "This step turns the log files on or off. They show whether" \
        "${GAME_NAME:-the game} is loading the audio fix."
    LAUNCHER_CHANGE="dsoal_log"
    dsoal_log_wine="$(dsoal_log_path_for_wine "$GAME_DIR")"
    alsoft_log_wine="$(alsoft_log_path_for_wine "$GAME_DIR")"
    # DSOAL only writes its log when it's the game's dsound.dll; a game running
    # OpenAL Soft alone has just OpenAL Soft's.
    dsoal_log_has_dsoal=""
    [ -e "$GAME_DIR/dsoal-aldrv.dll" ] && dsoal_log_has_dsoal=1

    # The launcher has to have saved settings for the game to add to.
    launcher_override_target
    dsoal_log_label="$(launcher_label "$OVERRIDE_LAUNCHER")"
    while [ -n "$OVERRIDE_LAUNCHER" ] && [ -z "$OVERRIDE_FILE" ]; do
        print_note "${dsoal_log_label} has no settings saved for ${GAME_NAME} yet."
        print_paragraph "If you just installed this game, ${dsoal_log_label} hasn't created its settings yet." \
            "Please launch the game at least once, close it, and try again."
        confirm "Check ${dsoal_log_label}'s settings for ${GAME_NAME} again?" || break
        launcher_override_target
    done
    if [ -z "$OVERRIDE_FILE" ]; then
        print_result "To turn on logging yourself, set these environment variables for ${GAME_NAME}"
        echo -e "${WHITE}(in Steam, put them in front of %command% in its launch options):${NC}"
        if [ -n "$dsoal_log_has_dsoal" ]; then
            echo -e "  ${CYAN}DSOAL_LOGLEVEL=4${NC}"
            echo -e "  ${CYAN}DSOAL_LOGFILE=\"${dsoal_log_wine}\"${NC}"
        fi
        echo -e "  ${CYAN}ALSOFT_LOGLEVEL=3${NC}"
        echo -e "  ${CYAN}ALSOFT_LOGFILE=\"${alsoft_log_wine}\"${NC}"
        [ -n "$dsoal_log_has_dsoal" ] && print_result "Use 3 instead of 4 for a smaller log that leaves out the EAX calls."
        exit 0
    fi

    # What's set now.
    dsoal_log_level=""; dsoal_log_file=""; alsoft_log_level=""; alsoft_log_file=""
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then
        dsoal_log_opts="$(launcher_override_get)"
        [ "$dsoal_log_opts" == "__ABSENT__" ] && dsoal_log_opts=""
        dsoal_log_level="$(launch_options_log_value "$dsoal_log_opts" DSOAL LEVEL)"
        dsoal_log_file="$(launch_options_log_value "$dsoal_log_opts" DSOAL FILE)"
        alsoft_log_level="$(launch_options_log_value "$dsoal_log_opts" ALSOFT LEVEL)"
        alsoft_log_file="$(launch_options_log_value "$dsoal_log_opts" ALSOFT FILE)"
    else
        dsoal_log_level="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGLEVEL)"
        dsoal_log_file="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGFILE)"
        alsoft_log_level="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" ALSOFT_LOGLEVEL)"
        alsoft_log_file="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" ALSOFT_LOGFILE)"
        [[ "$dsoal_log_level" == __*__ ]] && dsoal_log_level=""
        [[ "$dsoal_log_file" == __*__ ]] && dsoal_log_file=""
        [[ "$alsoft_log_level" == __*__ ]] && alsoft_log_level=""
        [[ "$alsoft_log_file" == __*__ ]] && alsoft_log_file=""
    fi

    if [ -n "$dsoal_log_level$alsoft_log_level" ]; then
        dsoal_log_action="remove"
        dsoal_log_linux="$(dsoal_log_path_for_linux "${dsoal_log_file:-dsoal.log}")"
        alsoft_log_linux="$(dsoal_log_path_for_linux "${alsoft_log_file:-openal.log}")"
        if [ -n "$dsoal_log_level" ]; then
            if [ "$dsoal_log_level" == "3" ]; then dsoal_log_word="Basic"; else dsoal_log_word="Full"; fi
            print_status "${dsoal_log_word} DSOAL logging is on for ${GAME_NAME}, writing to $(tilde_path "$dsoal_log_linux")."
        fi
        if [ -n "$alsoft_log_level" ]; then
            print_status "OpenAL Soft logging is on for ${GAME_NAME}, writing to $(tilde_path "$alsoft_log_linux")."
        fi
        if ! confirm "Turn logging off for ${GAME_NAME}?" Y; then
            print_result "No changes were made." "$YELLOW"
            exit 0
        fi
    else
        dsoal_log_action="add"
        dsoal_log_linux="$GAME_DIR/dsoal.log"
        alsoft_log_linux="$GAME_DIR/openal.log"
        alsoft_log_level=3
        if [ -n "$dsoal_log_has_dsoal" ]; then
            echo -e "\n${WHITE}How much should the audio fix log?${NC}\n"
        else
            echo -e "\n${WHITE}How much should be logged?${NC}\n"
        fi
        print_option 1 "Full — every EAX call the game makes" "(default; the log grows fast and the game may stutter)"
        print_option 2 "Basic — startup, and which EAX versions the game asks for"
        while true; do
            prompt "Selection [1-2, Default: 1]:"
            read_answer dsoal_log_choice || exit 0
            case "${dsoal_log_choice:-1}" in
                1) dsoal_log_level=4; break ;;
                2) dsoal_log_level=3; break ;;
                *) print_result "That's not a valid option — please type 1 or 2." "$YELLOW" ;;
            esac
        done
    fi

    if ! wait_for_launcher_closed "$OVERRIDE_LAUNCHER" "$dsoal_log_action" "type 's' to skip"; then
        print_result "Skipped — no changes were made." "$YELLOW"
        reopen_launchers
        exit 0
    fi

    dsoal_log_ok=1
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then
        # Re-read now the launcher is closed: it may have saved changes as it quit.
        dsoal_log_opts="$(launcher_override_get)"
        [ "$dsoal_log_opts" == "__ABSENT__" ] && dsoal_log_opts=""
        if [ "$dsoal_log_action" == "add" ]; then
            dsoal_log_new="$(launch_options_with_sound_log "$dsoal_log_opts" "${dsoal_log_has_dsoal:+$dsoal_log_level}" "$dsoal_log_wine" "$alsoft_log_level" "$alsoft_log_wine")"
        else
            dsoal_log_new="$(launch_options_without_dsoal_log "$dsoal_log_opts")"
        fi
        # Same one-time backup the DLL override makes before touching the file.
        [ -e "$OVERRIDE_FILE.eax-restore.bak" ] || cp -p "$OVERRIDE_FILE" "$OVERRIDE_FILE.eax-restore.bak" 2>/dev/null
        dsoal_log_expect="$dsoal_log_new"
        # Turning logging on adds %command% to empty launch options; a bare
        # %command% left over means the same as none, so clear it.
        case "${dsoal_log_new//[[:space:]]/}" in
            ""|"%command%") dsoal_log_new="__DELETE__"; dsoal_log_expect="__ABSENT__" ;;
        esac
        if ! launcher_override_set "$dsoal_log_new" || [ "$(launcher_override_get)" != "$dsoal_log_expect" ]; then
            dsoal_log_ok=0
        fi
        log_cmd "dsoal logging: $OVERRIDE_FILE [$OVERRIDE_ID] '$dsoal_log_opts' -> '$dsoal_log_new'"
    else
        if [ "$dsoal_log_action" == "add" ]; then
            { [ -z "$dsoal_log_has_dsoal" ] \
                || { heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGLEVEL "$dsoal_log_level" \
                    && heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGFILE "$dsoal_log_wine"; }; } \
                && heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" ALSOFT_LOGLEVEL "$alsoft_log_level" \
                && heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" ALSOFT_LOGFILE "$alsoft_log_wine" \
                && [ "$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" ALSOFT_LOGLEVEL)" == "$alsoft_log_level" ] \
                || dsoal_log_ok=0
        else
            for dsoal_log_var in DSOAL_LOGLEVEL DSOAL_LOGFILE ALSOFT_LOGLEVEL ALSOFT_LOGFILE; do
                case "$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" "$dsoal_log_var")" in
                    __ABSENT__|__NOAPP__) ;;
                    *) heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" "$dsoal_log_var" __DELETE__ || dsoal_log_ok=0 ;;
                esac
            done
        fi
        log_cmd "dsoal logging: $OVERRIDE_FILE [$OVERRIDE_ID] $dsoal_log_action level=$dsoal_log_level"
    fi
    reopen_launchers

    if [ "$dsoal_log_ok" -ne 1 ]; then
        print_error "Couldn't save the change to $(launcher_override_where)." \
            "The run log has the details."
        exit 1
    fi

    if [ "$dsoal_log_action" == "add" ]; then
        dsoal_log_paths=()
        [ -n "$dsoal_log_has_dsoal" ] && dsoal_log_paths+=("$dsoal_log_linux")
        dsoal_log_paths+=("$alsoft_log_linux")
        # The box doesn't reflow, so each path is split at its slashes: a cut
        # in the middle of a folder name would look like a different folder.
        if [ ${#dsoal_log_paths[@]} -gt 1 ]; then
            dsoal_log_intro="Start ${GAME_NAME} to make the logs. They go in:"
        else
            dsoal_log_intro="Start ${GAME_NAME} to make the log. It goes in:"
        fi
        mapfile -t dsoal_log_box < <(fold -s -w 54 <<< "$dsoal_log_intro" | sed 's/ *$//')
        dsoal_log_box+=("")
        for dsoal_log_path in "${dsoal_log_paths[@]}"; do
            dsoal_log_chunk="" dsoal_log_first=1
            IFS='/' read -ra dsoal_log_parts <<< "$(tilde_path "$dsoal_log_path")"
            for dsoal_log_part in "${dsoal_log_parts[@]}"; do
                if [ "$dsoal_log_first" -eq 1 ]; then
                    dsoal_log_chunk="$dsoal_log_part"; dsoal_log_first=0
                # 53 leaves room for the slash that ends a broken line.
                elif [ $(( ${#dsoal_log_chunk} + ${#dsoal_log_part} + 1 )) -gt 53 ]; then
                    dsoal_log_box+=("${dsoal_log_chunk}/"); dsoal_log_chunk="$dsoal_log_part"
                else
                    dsoal_log_chunk+="/$dsoal_log_part"
                fi
                while [ ${#dsoal_log_chunk} -gt 54 ]; do
                    dsoal_log_box+=("${dsoal_log_chunk:0:54}"); dsoal_log_chunk="${dsoal_log_chunk:54}"
                done
            done
            [ -n "$dsoal_log_chunk" ] && dsoal_log_box+=("$dsoal_log_chunk")
            dsoal_log_box+=("")
        done
        mapfile -t -O "${#dsoal_log_box[@]}" dsoal_log_box < <(fold -s -w 54 \
            <<< "Each time the game starts, it replaces the log. To turn logging off, choose Tools → DSOAL logging again." | sed 's/ *$//')
        echo ""
        TITLED_BOX_CENTRE=1 print_titled_box "$YELLOW" "Sound logging turned on" "${dsoal_log_box[@]}"
    else
        print_banner "SOUND LOGGING TURNED OFF"
        for dsoal_log_path in "$dsoal_log_linux" "$alsoft_log_linux"; do
            [ -f "$dsoal_log_path" ] || continue
            print_status "The last log is still at $(tilde_path "$dsoal_log_path")."
            # Only a log inside the game folder is offered for deletion: the
            # path comes from launcher settings the player may have edited.
            if [[ "$dsoal_log_path" == "$GAME_DIR"/* && "$dsoal_log_path" != *"/../"* ]] && confirm "Delete it?" N; then
                rm -f "$dsoal_log_path" && print_status "Deleted." "$GREEN"
            fi
        done
    fi
    exit 0
fi
