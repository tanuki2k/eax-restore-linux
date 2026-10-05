# ==============================================================================
# DSOAL LOGGING (Utilities → [D]SOAL logging for a game)
# ==============================================================================
# Turns DSOAL's own log on or off for one game by setting DSOAL_LOGLEVEL and
# DSOAL_LOGFILE in its Steam launch options or Heroic environment variables —
# what you'd otherwise type in by hand to see what a game asks DSOAL to do.
# DSOAL_LOGLEVEL is one less than DSOAL's internal level: 3 traces startup
# and the API calls, 4 (Debug) adds every EAX property call, which is what
# shows which EAX version a game actually uses. Changes nothing else, and
# isn't recorded in the install manifest: running this again turns it off,
# and uninstall drops the variables along with the DLL override.
if [ -n "$DSOAL_LOG_MODE" ]; then
    print_banner "DSOAL LOGGING"
    echo -e "\n${WHITE}This turns DSOAL's own log on or off for one game. It records what the game asks${NC}"
    echo -e "${WHITE}DSOAL to do, which helps when EAX doesn't sound right or for a bug report.${NC}"

    SCRIPT_ACTION="i"
    STEP_TOTAL=3

    # Steps 1-2 loop, same as the other flows (see prompt_restart_or_quit).
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        get_game_directory ""

        print_step 2 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    print_step 3 "DSOAL Logging"
    LAUNCHER_CHANGE="dsoal_log"
    dsoal_log_wine="$(dsoal_log_path_for_wine "$GAME_DIR")"

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
        echo -e "\n${WHITE}To turn on DSOAL logging yourself, set these environment variables for ${GAME_NAME}${NC}"
        echo -e "${WHITE}(in Steam, put them in front of %command% in its launch options):${NC}"
        echo -e "  ${CYAN}DSOAL_LOGLEVEL=4${NC}"
        echo -e "  ${CYAN}DSOAL_LOGFILE=\"${dsoal_log_wine}\"${NC}"
        echo -e "\n${WHITE}Use 3 instead of 4 for a smaller log without every EAX call.${NC}"
        exit 0
    fi

    # What's set now.
    dsoal_log_level=""; dsoal_log_file=""
    if [ "$OVERRIDE_LAUNCHER" == "steam" ]; then
        dsoal_log_opts="$(launcher_override_get)"
        [ "$dsoal_log_opts" == "__ABSENT__" ] && dsoal_log_opts=""
        dsoal_log_re='(^|[[:space:]])DSOAL_LOGLEVEL=("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]]*))'
        [[ "$dsoal_log_opts" =~ $dsoal_log_re ]] && dsoal_log_level="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
        dsoal_log_re='(^|[[:space:]])DSOAL_LOGFILE=("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]]*))'
        [[ "$dsoal_log_opts" =~ $dsoal_log_re ]] && dsoal_log_file="${BASH_REMATCH[3]}${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
    else
        dsoal_log_level="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGLEVEL)"
        dsoal_log_file="$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGFILE)"
        [[ "$dsoal_log_level" == __*__ ]] && dsoal_log_level=""
        [[ "$dsoal_log_file" == __*__ ]] && dsoal_log_file=""
    fi

    if [ -n "$dsoal_log_level" ]; then
        dsoal_log_action="remove"
        dsoal_log_linux="$(dsoal_log_path_for_linux "${dsoal_log_file:-dsoal.log}")"
        print_status "DSOAL logging is on for ${GAME_NAME} (level ${dsoal_log_level}), writing to $(tilde_path "$dsoal_log_linux")."
        if ! confirm "Turn DSOAL logging off for ${GAME_NAME}?" Y; then
            print_result "No changes were made." "$YELLOW"
            exit 0
        fi
    else
        dsoal_log_action="add"
        dsoal_log_linux="$GAME_DIR/dsoal.log"
        echo -e "\n${WHITE}How much should DSOAL log?${NC}\n"
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
            dsoal_log_new="$(launch_options_with_dsoal_log "$dsoal_log_opts" "$dsoal_log_level" "$dsoal_log_wine")"
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
            heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGLEVEL "$dsoal_log_level" \
                && heroic_set_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGFILE "$dsoal_log_wine" \
                && [ "$(heroic_get_env "$OVERRIDE_FILE" "$OVERRIDE_ID" DSOAL_LOGLEVEL)" == "$dsoal_log_level" ] \
                || dsoal_log_ok=0
        else
            for dsoal_log_var in DSOAL_LOGLEVEL DSOAL_LOGFILE; do
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
        print_banner "DSOAL LOGGING TURNED ON"
        print_paragraph "DSOAL will log to $(tilde_path "$dsoal_log_linux") the next time you start ${GAME_NAME}." \
            "It's replaced each time the game starts. Run this again to turn it off."
    else
        print_banner "DSOAL LOGGING TURNED OFF"
        if [ -f "$dsoal_log_linux" ]; then
            print_status "The last log is still at $(tilde_path "$dsoal_log_linux")."
            if confirm "Delete it?" N; then
                rm -f "$dsoal_log_linux" && print_status "Deleted." "$GREEN"
            fi
        fi
    fi
    exit 0
fi
