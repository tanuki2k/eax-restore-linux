# ==============================================================================
# ACTION: INSTALL (PHASE 1: CONFIGURATION)
# ==============================================================================

# Usage: print_choices_summary
# Phase 2's "Configuration finished!" recap of every Phase 1 answer, shown
# before the player confirms the deploy so they can check it all in one place.
# Labels line up like the KNOWN GAMES DATABASE details; a value with more than
# one line (the game settings list) continues under the first.
print_choices_summary() {
    local -a labels=() values=()
    _choice() { labels+=("$1"); values+=("$2"); }

    _choice "Game" "${BOLD}${GAME_NAME}${NC}"
    _choice "Location" "$(tilde_path "$GAME_DIR")"
    if [ "$LAUNCHER_TYPE" == "1" ]; then _choice "Launcher" "Steam"
    elif [ -n "${HEROIC_APP_NAME:-}" ]; then _choice "Launcher" "Heroic"
    else _choice "Launcher" "Wine prefix"; fi
    [ -n "$PREFIX_PATH" ] && _choice "Prefix" "$(tilde_path "$PREFIX_PATH")"
    _choice "Architecture" "${ARCH}-bit"

    if [ "$ENGINE_CHOICE" == "2" ]; then
        _choice "Audio engine" "OpenAL Soft as OpenAL32.dll"
        _choice "Builds" "OpenAL Soft ${OAL_BUILD^} ${DIM}(${OAL_SELECTED_LABEL:-unknown})${NC}"
    else
        _choice "Audio engine" "DSOAL + OpenAL Soft"
        _choice "Builds" "DSOAL ${DSOAL_BUILD^} ${DIM}(${DSOAL_SELECTED_LABEL:-unknown})${NC}"$'\n'"OpenAL Soft ${OAL_BUILD^} ${DIM}(${OAL_SELECTED_LABEL:-unknown})${NC}"
    fi

    if [ "$INSTALL_VCRUN" == "y" ]; then _choice "VC++ runtimes" "Install"
    elif [ "${APPLY_VCRUN_OVERRIDES_NEEDED:-0}" == "1" ]; then _choice "VC++ runtimes" "Already in the prefix"
    else _choice "VC++ runtimes" "Skip"; fi

    _choice "Speakers" "$(speaker_label)"

    local entry sec key value line list=""
    for entry in "${ALSOFT_OVERRIDES[@]}"; do
        IFS=$'\x1f' read -r sec key value <<< "$entry"
        if [ "$sec/$key" == "reverb/boost" ]; then list+="${list:+$'\n'}Reverb boost +${value} dB"
        else list+="${list:+$'\n'}${key} = ${value}"; fi
    done
    [ -n "$list" ] && _choice "alsoft.ini" "$list"

    list=""
    [ "$ADVANCED_DUMMY" == "y" ] && list+="${list:+$'\n'}EAX Unified dummy files"
    [ "$ADVANCED_LIMITS" == "y" ] && list+="${list:+$'\n'}Expand audio limits"
    [ "$ADVANCED_COM" == "y" ] && list+="${list:+$'\n'}COM registry routing"
    _choice "Advanced tweaks" "${list:-None}"

    case "$OVERRIDE_METHOD" in
        launcher) _choice "DLL override" "$(launcher_override_where)" ;;
        registry) _choice "DLL override" "$(runner_label) prefix registry" ;;
        *) _choice "DLL override" "You'll set it yourself (instructions at the end)" ;;
    esac

    # Only for a game that offered settings: the ones chosen, in order.
    if [ ${#GAME_SETTINGS_PLAN[@]} -gt 0 ] || [ ${#GAME_SETTINGS_DECLINED[@]} -gt 0 ]; then
        local title
        local -a f
        list=""
        for line in "${GAME_SETTINGS_PLAN[@]}"; do
            mapfile -t -d $'\x1f' f < <(printf '%s' "$line")
            title="${f[1]}"
            [[ $'\n'"$list"$'\n' == *$'\n'"$title"$'\n'* ]] || list+="${list:+$'\n'}${title}"
        done
        _choice "Game settings" "${list:-None}"
    fi

    local i width=0 first rest pad
    for i in "${!labels[@]}"; do
        [ ${#labels[$i]} -gt "$width" ] && width=${#labels[$i]}
    done
    echo -e "\n${WHITE}Your choices:${NC}"
    for i in "${!labels[@]}"; do
        first="${values[$i]%%$'\n'*}"
        printf ' -> %b%s%b:%*s %b%b%b\n' "$YELLOW" "${labels[$i]}" "$NC" \
            $(( width - ${#labels[$i]} )) "" "$WHITE" "$first" "$NC"
        [ "$first" == "${values[$i]}" ] && continue
        printf -v pad '%*s' $(( width + 6 )) ""
        rest="${values[$i]#*$'\n'}"
        while IFS= read -r line; do
            echo -e "${pad}${WHITE}${line}${NC}"
        done <<< "$rest"
    done
    unset -f _choice
}

if [ "$SCRIPT_ACTION" == "i" ]; then
    # Fixed step count for this flow (1-11, same regardless of launcher/engine
    # branch) — read by print_step via the STEP_TOTAL global so headers show
    # "N/11. Label" instead of just "N. Label". Step 11 ("Game Settings") only
    # appears for a known game with config fixes to offer. Step 2 ("Locate Game
    # Executable") only ever appears on the scan path — resolve_exe_folder
    # prints it itself — so browse/manual users jump straight from 1 to 3.
    STEP_TOTAL=11

    # Nothing is downloaded yet: step 6 fetches only the builds that get
    # picked. This only checks GitHub can be reached, and stops now if it
    # can't and nothing usable is cached.
    check_download_readiness

    print_banner "PHASE 1: CONFIGURATION"

    # Steps 1-2 loop: at an EAX-impossible dead end (see prompt_restart_or_quit)
    # the user can choose to go back and pick a different game instead of the
    # script exiting, and step 1 hands a "no" while picking a game back the
    # same way. get_game_directory / scan_game_libraries /
    # detect_game_environment all unwind on RESTART_REQUESTED. When the main
    # menu was shown, continue 2 goes back to it (the loop around the main
    # menu, see vcrun-only-flow.sh); otherwise this re-runs them from the top
    # with a clean slate (get_game_directory resets the per-game globals on
    # entry).
    while true; do
        RESTART_REQUESTED=""

        # 1. Game Location
        print_step 1 "Game Location"
        get_game_directory ""
        if [ -n "$RESTART_REQUESTED" ]; then
            [ -n "$MAIN_MENU_SHOWN" ] && continue 2
            continue
        fi
        check_target_writable "$GAME_DIR" "game folder"

        # 3. Game Identification & Launcher Auto-Detect
        print_step 3 "Launcher Identification"
        detect_game_environment
        if [ -n "$RESTART_REQUESTED" ]; then
            [ -n "$MAIN_MENU_SHOWN" ] && continue 2
            continue
        fi

        break
    done

    # A title that launches more than one exe from its own folders (GOG's
    # F.E.A.R. Platinum and its expansions) gets the game-folder files in
    # each of them too — checked for write access now, like GAME_DIR above.
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        resolve_extra_exe_folders "$APPID" "steam"
    else
        resolve_extra_exe_folders "${HEROIC_APP_NAME:-}" "gog"
    fi
    if [ ${#EXTRA_GAME_DIRS[@]} -gt 0 ]; then
        for extra_dir in "${EXTRA_GAME_DIRS[@]}"; do
            check_target_writable "$extra_dir" "game folder"
        done
        print_status "$GAME_NAME also starts games from $(extra_exe_folders_list), so they get the same files."
    fi

    # 4. Audio API Detection
    print_step 4 "Audio API Detection"
    print_paragraph "This step works out whether the game plays its 3D sound through DirectSound3D or" \
        "OpenAL, so the matching audio fix is installed."
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        confirm_continue_if_openal_native "$APPID" "steam" "$GAME_NAME"
    else
        confirm_continue_if_openal_native "$HEROIC_APP_NAME" "gog" "$GAME_NAME"
    fi

    # 5. Architecture Scan
    select_architecture 5

    # 6. Engine Selection
    print_step 6 "Audio Engine Selection"

    if [ -n "$OPENAL_NATIVE_MODE" ]; then
        ENGINE_CHOICE=2
        print_paragraph "$GAME_NAME uses OpenAL natively — deploying kcat's OpenAL Soft."
    elif [ -n "$API_CONFIRMED_DS3D" ]; then
        # The Audio API Detection step positively identified this as a
        # DirectSound3D title, so there's no menu to show — OpenAL-native
        # would be a silent no-op here (the game never loads OpenAL32.dll).
        # Mirrors the OPENAL_NATIVE_MODE branch above.
        ENGINE_CHOICE=1
        print_paragraph "$GAME_NAME uses DirectSound3D — deploying kcat DSOAL + OpenAL Soft."
    else
    echo -e "\n${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"
    echo -e " * ${BOLD}kcat DSOAL + OpenAL Soft:${NC} The standard choice. Intercepts a game's"
    echo -e "   DirectSound3D/EAX calls and translates them to OpenAL — the right pick for the"
    echo -e "   vast majority of classic Windows games."
    echo ""
    echo -e " * ${BOLD}OpenAL native:${NC} Only for the handful of games that already call OpenAL directly"
    echo -e "   (no DirectSound3D layer to intercept) — swaps OpenAL Soft in as OpenAL32.dll.\n"

    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        ENGINE_CHOICE=1
        echo -e "${GREEN}EAX_RESTORE_DSOAL_PIN is set — using kcat DSOAL + OpenAL Soft.${NC}"
    else
        echo -e "${YELLOW}Selection (1 or 2) [Default: 1]: ${NC}"
        echo ""
        print_option 1 "kcat DSOAL + OpenAL Soft"
        print_option 2 "OpenAL native (direct OpenAL32.dll swap)"

        while true; do
            echo -e -n "\n> "
            read_answer ENGINE_CHOICE || exit 0
            ENGINE_CHOICE="${ENGINE_CHOICE:-1}"
            if [[ "$ENGINE_CHOICE" =~ ^[12]$ ]]; then break; fi
            print_result "That's not a valid option — please type 1 or 2." "$YELLOW"
        done
    fi
    fi

    # Which builds to deploy, then download just those (choose_builds).
    choose_builds
    # Read here, not earlier: the run log's summary records the builds chosen.
    DSOAL_VER="${DSOAL_BUILD} ${DSOAL_SELECTED_LABEL:-}"
    OAL_VER="${OAL_BUILD} ${OAL_SELECTED_LABEL:-}"

    # The Wine DLL override this install ultimately needs — dsound.dll for
    # engine 1 (DSOAL intercepts DirectSound3D), OpenAL32.dll for engine 2
    # (OpenAL Soft deployed directly, nothing for DSOAL to intercept). Set
    # once here so every later step (override wording, registry, deployment,
    # final launch instructions) reads the same value instead of each
    # re-deriving it from ENGINE_CHOICE or OPENAL_NATIVE_MODE separately.
    # PRIMARY_DLL_NAME is the lowercase WINEDLLOVERRIDES key; PRIMARY_DLL_FILENAME
    # is the on-disk filename (Wine treats overrides case-insensitively, but
    # the actual deployed file is written with its conventional casing).
    PRIMARY_DLL_NAME="dsound"
    PRIMARY_DLL_FILENAME="dsound.dll"
    if [ "$ENGINE_CHOICE" == "2" ]; then
        PRIMARY_DLL_NAME="openal32"
        PRIMARY_DLL_FILENAME="OpenAL32.dll"
    fi

    # 7. VC++ Runtime Dependencies
    # Both engines are kcat builds (DSOAL, OpenAL Soft) that need the genuine
    # MS runtime on older Proton/Wine, so this step always runs now rather
    # than being gated on the engine choice.
    INSTALL_VCRUN="n"
    print_step 7 "VC++ Runtime Dependencies"
    print_paragraph "Genuine Microsoft C++ runtime libraries are needed for older Proton/Wine" \
        "builds (9 and below) to load kcat's DSOAL / OpenAL Soft."

    if confirm "Check $GAME_NAME's prefix for existing VC++ runtime files?"; then
        print_task "Checking prefix for existing VC++ runtime files"

        if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
            verify_vcrun_files
        else
            VCRUN_SUCCESS=0
            print_status "Prefix not resolved yet, can't check. Defaulting to asking below." "$YELLOW"
        fi

        if [ "$VCRUN_SUCCESS" -eq 1 ]; then
            print_status "Core VC++ runtime files are already present, so there's nothing to install." "$GREEN"
            print_paragraph "Wine will still be told to use them instead of its own copies, which it" \
                "prefers by default even when Microsoft's files are there."
            APPLY_VCRUN_OVERRIDES_NEEDED=1
        else
            echo -e "\n${WHITE}These files are missing or incomplete here. Without them, the game may crash"
            echo -e "silently on startup when it tries to load the audio engine.${NC}"
            if confirm "Install genuine MS VC++ runtimes?"; then INSTALL_VCRUN="y"; else INSTALL_VCRUN="n"; fi
        fi
    else
        echo -e "\n${WHITE}Skipping. You can revisit this later with EAX_RESTORE_VCRUN_ONLY=1 without redoing"
        echo -e "the rest of the install.${NC}"
    fi

    # 8. Audio Configuration
    print_step 8 "Speaker Configuration"
    ask_speaker_configuration

    # The known-games entry's alsoft.ini values (e.g. a reverb boost) are
    # OpenAL Soft settings, so they're offered here with the rest of them.
    offer_alsoft_settings

    # 9. Advanced Compatibility Tweaks
    print_step 9 "Advanced Compatibility Tweaks"
    echo -e "\n${WHITE}These optional workarounds are designed for extremely stubborn games"
    echo -e "that refuse to load EAX normally. In 90% of cases, you do not need these.${NC}"

    ADVANCED_DUMMY="n"
    ADVANCED_LIMITS="n"
    ADVANCED_COM="n"

    # EAX Unified Dummy Files and COM Registry Routing both target
    # DirectSound3D specifically and have nothing to attach to on a direct
    # OpenAL32.dll swap — so engine 2 only ever offers Expand Audio Limits.
    EAX_UNIFIED_DUMMY_APPLICABLE=1
    COM_ROUTING_APPLICABLE=1
    if [ "$ENGINE_CHOICE" == "2" ]; then
        EAX_UNIFIED_DUMMY_APPLICABLE=0
        COM_ROUTING_APPLICABLE=0
    fi

    # the known-games entry's install.tweaks array (see
    # resolve_recommended_tweaks in known-games.sh) may flag any combination of
    # the three tweaks below for this game. Each flagged, applicable tweak is
    # decided here — before the generic opt-in gate further down — with a
    # default-Y prompt instead of the generic default-N one, since the
    # database recommends it specifically for this title.
    EAX_UNIFIED_DUMMY_HANDLED=0
    AUDIO_LIMITS_HANDLED=0
    COM_ROUTING_HANDLED=0
    if [ -z "$RECOMMENDED_TWEAKS_RESOLVED" ]; then
        if [ "$LAUNCHER_TYPE" == "1" ]; then
            resolve_recommended_tweaks "$APPID" "steam"
        else
            resolve_recommended_tweaks "$HEROIC_APP_NAME" "gog"
        fi
    fi

    # A game flagged EAX Unified reaches EAX through Creative's eax.dll shim.
    # This tweak creates empty eax.dll/eaxunified.dll to satisfy a title that
    # only checks for the file's presence to unlock its EAX menu — but one
    # that ships and loads a real eax.dll (GTA: San Andreas, Far Cry 2) would
    # get it shadowed and can fail to boot. So for a flagged game, decide it
    # here with a guarded check instead of the generic prompt.
    if [ -n "$EAX_UNIFIED" ] && [ "$EAX_UNIFIED_DUMMY_APPLICABLE" -eq 1 ]; then
        echo -e "\n${WHITE}$GAME_NAME is one of those exceptions — it reaches EAX through an eax.dll shim (EAX Unified),${NC}"
        echo -e "${WHITE}so it's worth checking whether it already ships its own eax.dll before deciding${NC}"
        echo -e "${WHITE}whether to create dummy eax.dll files to unlock the game's EAX menu.${NC}"
        if confirm "Check whether it ships its own eax.dll?" Y; then
            if is_genuine_dll "$GAME_DIR/eax.dll" || is_genuine_dll "$GAME_DIR/eaxunified.dll"; then
                print_note "$GAME_NAME already ships its own eax.dll — the EAX Unified dummy-file tweak" \
                    "isn't needed here and could stop the game booting, so it's being skipped."
                ADVANCED_DUMMY="n"
            elif confirm "Inject EAX Unified dummy files? $GAME_NAME is flagged EAX Unified and has no eax.dll of its own." Y; then
                ADVANCED_DUMMY="y"
            else
                ADVANCED_DUMMY="n"
            fi
            EAX_UNIFIED_DUMMY_HANDLED=1
        fi
    fi

    # install.tweaks can flag Expand Audio Limits for a game independently
    # verified to need it (e.g. F.E.A.R.'s audio dropping out during large
    # firefights). Applies to both engines, so — unlike the other two — it has
    # no applicability gate.
    if [ -n "$RECOMMENDED_AUDIO_LIMITS" ]; then
        echo -e "\n${CYAN}${BOLD}Expand Audio Limits${NC}"
        echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
        echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
        if confirm "Expand OpenAL audio limits? $GAME_NAME is flagged in the known-games database as benefiting from this." Y; then
            ADVANCED_LIMITS="y"
        else
            ADVANCED_LIMITS="n"
        fi
        AUDIO_LIMITS_HANDLED=1
    fi

    # Same idea for COM Registry Routing (e.g. GTA: San Andreas, which needs
    # it in addition to EAX Unified Dummy Files for EAX to work under
    # Wine/Proton).
    if [ -n "$RECOMMENDED_COM_ROUTING" ] && [ "$COM_ROUTING_APPLICABLE" -eq 1 ]; then
        echo -e "\n${CYAN}${BOLD}COM Registry Routing${NC}"
        echo -e "${WHITE}Explicitly forces the Windows registry to point directly to our custom dsound.dll."
        echo -e "Beneficial for stubborn late-90s and early-2000s games that actively ignore local DLL files.${NC}"
        if confirm "Inject COM registry routing? $GAME_NAME is flagged in the known-games database as needing this." Y; then
            ADVANCED_COM="y"
        else
            ADVANCED_COM="n"
        fi
        COM_ROUTING_HANDLED=1
    fi

    if [ "$EAX_UNIFIED_DUMMY_APPLICABLE" -eq 0 ] && [ "$COM_ROUTING_APPLICABLE" -eq 0 ]; then
        # Engine 2: only Expand Audio Limits could possibly apply, and it's
        # already been decided above if the database recommended it.
        if [ "$AUDIO_LIMITS_HANDLED" -eq 0 ]; then
            echo -e "\n${WHITE}EAX Unified Dummy Files and COM Registry Routing both target DirectSound3D"
            echo -e "specifically, which doesn't apply to a direct OpenAL32.dll swap — only Expand Audio Limits applies here.${NC}"

            if confirm "Would you like to view and opt-in to this advanced tweak?" N; then
                echo -e "\n${CYAN}${BOLD}Expand Audio Limits${NC}"
                echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
                echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
                if confirm "Expand OpenAL audio limits?" N; then
                    ADVANCED_LIMITS="y"
                fi
            fi
        fi
    else
        ANY_TWEAK_HANDLED=0
        [ "$EAX_UNIFIED_DUMMY_HANDLED" -eq 1 ] && ANY_TWEAK_HANDLED=1
        [ "$AUDIO_LIMITS_HANDLED" -eq 1 ] && ANY_TWEAK_HANDLED=1
        [ "$COM_ROUTING_HANDLED" -eq 1 ] && ANY_TWEAK_HANDLED=1

        ALL_HANDLED=1
        [ "$EAX_UNIFIED_DUMMY_APPLICABLE" -eq 1 ] && [ "$EAX_UNIFIED_DUMMY_HANDLED" -eq 0 ] && ALL_HANDLED=0
        [ "$AUDIO_LIMITS_HANDLED" -eq 0 ] && ALL_HANDLED=0
        [ "$COM_ROUTING_APPLICABLE" -eq 1 ] && [ "$COM_ROUTING_HANDLED" -eq 0 ] && ALL_HANDLED=0

        if [ "$ALL_HANDLED" -eq 0 ]; then
            if [ "$ANY_TWEAK_HANDLED" -eq 1 ]; then
                GATE_PROMPT="Would you like to view and opt-in to the additional advanced tweaks?"
            else
                GATE_PROMPT="Would you like to view and opt-in to these advanced tweaks?"
            fi

            if confirm "$GATE_PROMPT" N; then
                if [ "$EAX_UNIFIED_DUMMY_APPLICABLE" -eq 1 ] && [ "$EAX_UNIFIED_DUMMY_HANDLED" -eq 0 ]; then
                    echo -e "\n${CYAN}${BOLD}EAX Unified Dummy Files${NC}"
                    echo -e "${WHITE}Tricks certain games (like KOTOR, Max Payne, and early Unreal Engine titles)"
                    echo -e "into unlocking the EAX menu option by creating harmless, empty eax.dll and eaxunified.dll files.${NC}"
                    if confirm "Inject EAX Unified dummy files?" N; then
                        ADVANCED_DUMMY="y"
                    fi
                fi

                if [ "$AUDIO_LIMITS_HANDLED" -eq 0 ]; then
                    echo -e "\n${CYAN}${BOLD}Expand Audio Limits${NC}"
                    echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
                    echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
                    if confirm "Expand OpenAL audio limits?" N; then
                        ADVANCED_LIMITS="y"
                    fi
                fi

                if [ "$COM_ROUTING_APPLICABLE" -eq 1 ] && [ "$COM_ROUTING_HANDLED" -eq 0 ]; then
                    echo -e "\n${CYAN}${BOLD}COM Registry Routing${NC}"
                    echo -e "${WHITE}Explicitly forces the Windows registry to point directly to our custom dsound.dll."
                    echo -e "Beneficial for stubborn late-90s and early-2000s games that actively ignore local DLL files.${NC}"
                    if confirm "Inject COM registry routing?" N; then
                        ADVANCED_COM="y"
                    fi
                fi
            fi
        fi
    fi

    # 10. Automatic DLL Override
    print_step 10 "DLL Override"
    print_paragraph "$(runner_label) needs to be told to load the new ${PRIMARY_DLL_FILENAME} instead of its built-in one." \
        "Where would you like to set that up?"

    # The launcher choice (the default for Steam and Heroic games) writes the
    # override where a player would by hand — Steam's launch options or
    # Heroic's environment variables for this game — so it's visible there and
    # easy to undo.
    choose_override_method

    # 11. Game Settings — changes to the game's own config files, from its
    # known-games entry. Last, since it's about the game rather than the
    # audio fix, and the speaker answer from step 8 decides some of them.
    game_settings_step 11

    # (continues below: "if" opened above closes at the bottom of install-flow.sh)
