# ==============================================================================
# TOOLS → GAME SETTINGS ([O]ptional settings / [S]peaker configuration)
# ==============================================================================
# Changes a game this script already installed to, without reinstalling:
# Optional settings turns the game's optional Game Settings on or off, and
# Speaker configuration switches the speaker setup in its alsoft.ini plus any
# Game Settings tied to a speaker layout. Both pick the game from the list of
# installs, ask everything first, then change things after one "Proceed?".
# The install manifest is rewritten the way a reinstall does
# (update_game_settings_in_manifest), so uninstall still puts back every
# setting's original value.
if [ -n "$SETTINGS_TOOL_MODE" ]; then
    if [ "$SETTINGS_TOOL_MODE" == "speakers" ]; then
        print_banner "SPEAKER CONFIGURATION"
        print_paragraph "This changes the speaker setup for a game the EAX fix is installed in, and any of" \
            "the game's own settings that go with it. Nothing else is touched."
        STEP_TOTAL=3
    else
        print_banner "OPTIONAL SETTINGS"
        print_paragraph "This turns a game's optional settings on or off after the EAX fix is installed." \
            "Turning one off puts back the value the game had before."
        STEP_TOTAL=2
    fi
    SCRIPT_ACTION="i"

    # Step 1 only: these tools change files in the game folder and its
    # prefix, so there's no launcher step. The game is identified from its
    # own folder (identify_game_dir) and the prefix from the manifest.
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        get_game_directory ""
        # Step 1's [R]eturn to the main menu, or a retry handed back to it.
        [ -n "$RESTART_REQUESTED" ] && continue 2

        # The game folder has to hold this script's install; with no manifest
        # there's nothing to change, so it's back to the main menu.
        INSTALL_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
        settings_alsoft_files=()
        if [ -s "$INSTALL_MANIFEST" ] && ! head -n 1 "$INSTALL_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
            while IFS= read -r line; do
                [[ "$line" == /*/alsoft.ini ]] && [ -f "$line" ] && settings_alsoft_files+=("$line")
            done < "$INSTALL_MANIFEST"
        fi
        if [ ! -s "$INSTALL_MANIFEST" ] || head -n 1 "$INSTALL_MANIFEST" | grep -q "^# EAX Restore: uninstalled" \
            || { [ "$SETTINGS_TOOL_MODE" == "speakers" ] && [ ${#settings_alsoft_files[@]} -eq 0 ]; }; then
            print_note "The EAX fix isn't installed in $(tilde_path "$GAME_DIR")."
            print_paragraph "Install it first (Scan, Browse or Manually on the main menu), then come back here."
            continue 2
        fi

        break
    done

    APPID=""; HEROIC_APP_NAME=""; PREFIX_PATH=""; LAUNCHER_TYPE=""
    GAME_NAME="$(basename "$GAME_DIR")"; GAME_INSTALL_ROOT=""
    if identify_game_dir "$GAME_DIR"; then
        [ -n "$GAME_ID_NAME" ] && GAME_NAME="$GAME_ID_NAME"
        GAME_INSTALL_ROOT="$GAME_ID_ROOT"
        if [ "$GAME_ID_STORE" == "steam" ]; then LAUNCHER_TYPE="1"; APPID="$GAME_ID"
        else LAUNCHER_TYPE="2"; HEROIC_APP_NAME="$GAME_ID"; fi
    fi
    while IFS= read -r line; do
        [[ "$line" == /*/drive_c/* ]] && { PREFIX_PATH="${line%%/drive_c/*}"; break; }
    done < "$INSTALL_MANIFEST"
    print_status "Game: ${GAME_NAME}" ""

    # This install's game settings, by title: their CONFIG lines and category.
    declare -A settings_lines=() settings_cat=()
    settings_titles=()
    while IFS= read -r line; do
        [[ "$line" == CONFIG:* ]] || continue
        mapfile -t -d $'\t' settings_f < <(printf '%s' "${line#CONFIG:}")
        settings_title="${settings_f[1]}"
        [ -n "${settings_lines[$settings_title]+x}" ] || settings_titles+=("$settings_title")
        settings_lines[$settings_title]+="$line"$'\n'
        settings_cat[$settings_title]="${settings_f[0]/#extras/optional}"
    done < "$INSTALL_MANIFEST"

    GAME_SETTINGS_REVERT_GROUPS=()
    GAME_SETTINGS_PLAN=()
    settings_speakers_changed=0

    if [ "$SETTINGS_TOOL_MODE" == "speakers" ]; then
        print_step 2 "Speaker Configuration"
        settings_old_label=""
        if speaker_config_from_alsoft "${settings_alsoft_files[0]}"; then
            settings_old_label="$(speaker_label)"
            print_status "Currently: ${settings_old_label}" ""
        fi
        ask_speaker_configuration
        settings_new_label="$(speaker_label)"
        [ "$settings_new_label" != "$settings_old_label" ] && settings_speakers_changed=1

        # Settings applied for the old layout that don't fit the new one go
        # back to their original values (e.g. BioShock's 5.1 mode after
        # switching to headphones). Found by title among the entry's
        # speaker-dependent settings.
        declare -A settings_speaker_rule=()
        if current_known_game; then
            while IFS= read -r row; do
                mapfile -t -d $'\x1f' settings_f < <(printf '%s' "$row")
                [ -n "${settings_f[5]}" ] && settings_speaker_rule[${settings_f[2]}]="${settings_f[5]}"
            done < <(load_game_config_rows "$KG_ID" "$KG_STORE")
        fi
        for settings_title in "${settings_titles[@]}"; do
            [ -n "${settings_speaker_rule[$settings_title]+x}" ] || continue
            speakers_match "${settings_speaker_rule[$settings_title]}" && continue
            GAME_SETTINGS_REVERT_GROUPS+=("${settings_cat[$settings_title]}"$'\x1f'"${settings_title}"$'\x1f'"${settings_lines[$settings_title]}")
        done
        # The settings for the new layout first (the step prints its own
        # heading when it has any), then the ones going back.
        GAME_SETTINGS_SPEAKERS_ONLY=1 game_settings_step 3
        if [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ]; then
            [ -n "$GAME_SETTINGS_STEP_SHOWN" ] || print_step 3 "Game Settings"
            echo -e "\n${WHITE}These were set for your old speakers, so they'll be put back:${NC}"
            for entry in "${GAME_SETTINGS_REVERT_GROUPS[@]}"; do
                settings_title="${entry#*$'\x1f'}"; settings_title="${settings_title%%$'\x1f'*}"
                echo -e "  ${YELLOW}-${NC} ${WHITE}${settings_title}${NC}"
            done
        fi
    else
        GAME_SETTINGS_RECORDED=()
        for settings_title in "${settings_titles[@]}"; do
            [ "${settings_cat[$settings_title]}" == "optional" ] && GAME_SETTINGS_RECORDED[$settings_title]="${settings_lines[$settings_title]}"
        done
        settings_optional=0
        if current_known_game; then
            read -r _ settings_optional <<< "$(count_game_settings "$KG_ID" "$KG_STORE")"
        fi
        if [ "${settings_optional:-0}" -eq 0 ]; then
            print_note "${GAME_NAME} has no optional settings."
            continue
        fi
        GAME_SETTINGS_EDIT_OPTIONAL=1 game_settings_step 2
    fi

    if [ "$settings_speakers_changed" -eq 0 ] && [ ${#GAME_SETTINGS_PLAN[@]} -eq 0 ] \
        && [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -eq 0 ]; then
        print_result "Nothing changed." "$GREEN"
        continue
    fi

    # The recap, then one "Proceed?" before anything is written.
    echo -e "\n${WHITE}Your changes:${NC}"
    [ "$settings_speakers_changed" -eq 1 ] \
        && echo -e " -> ${YELLOW}Speakers${NC}: ${WHITE}${settings_old_label:-unknown} → ${settings_new_label}${NC}"
    settings_on=""
    for line in "${GAME_SETTINGS_PLAN[@]}"; do
        mapfile -t -d $'\x1f' settings_f < <(printf '%s' "$line")
        [[ $'\n'"$settings_on"$'\n' == *$'\n'"${settings_f[1]}"$'\n'* ]] || settings_on+="${settings_on:+$'\n'}${settings_f[1]}"
    done
    while IFS= read -r settings_title; do
        [ -n "$settings_title" ] && echo -e " -> ${YELLOW}Turn on${NC}: ${WHITE}${settings_title}${NC}"
    done <<< "$settings_on"
    for entry in "${GAME_SETTINGS_REVERT_GROUPS[@]}"; do
        settings_title="${entry#*$'\x1f'}"; settings_title="${settings_title%%$'\x1f'*}"
        echo -e " -> ${YELLOW}Put back${NC}: ${WHITE}${settings_title}${NC}"
    done
    if ! confirm "Ready to change ${GAME_NAME}. Proceed?"; then
        print_result "Cancelled — nothing was changed." "$YELLOW"
        continue
    fi

    DEPLOY_FAILURES=0
    if [ "$settings_speakers_changed" -eq 1 ]; then
        print_task "Updating the speaker setup"
        speaker_alsoft_values
        for settings_file in "${settings_alsoft_files[@]}"; do
            settings_ok=1
            config_set_key "$settings_file" ini general channels "$ALSOFT_CHANNELS" || settings_ok=0
            config_set_key "$settings_file" ini general stereo-mode "$STEREO_MODE" || settings_ok=0
            config_set_key "$settings_file" ini general stereo-encoding "$STEREO_ENCODING" || settings_ok=0
            [ -z "$HRTF_MODE_PREFIX" ] && { config_set_key "$settings_file" ini general hrtf-mode "$HRTF_MODE" || settings_ok=0; }
            [ "$OUTPUT_MODE" == "surround" ] && { config_set_key "$settings_file" ini decoder hq-mode true || settings_ok=0; }
            if [ "$settings_ok" -eq 1 ]; then
                print_status "Updated: $(tilde_path "$settings_file")"
            else
                record_deploy_failure "$settings_file"
            fi
        done
    fi
    if [ ${#GAME_SETTINGS_PLAN[@]} -gt 0 ] || [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ]; then
        print_task "Updating ${GAME_NAME}'s settings"
        update_game_settings_in_manifest
    fi

    print_run_summary
    if [ "${DEPLOY_FAILURES:-0}" -gt 0 ]; then
        print_banner "SETTINGS NOT FULLY CHANGED" "$YELLOW"
        print_error "$DEPLOY_FAILURES change(s) couldn't be written (see the errors above)." \
            "The run log has the details."
        exit 1
    fi
    if [ "$SETTINGS_TOOL_MODE" == "speakers" ]; then
        print_banner "SPEAKER CONFIGURATION CHANGED"
    else
        print_banner "OPTIONAL SETTINGS CHANGED"
    fi
    print_game_settings_summary
    exit 0
fi
