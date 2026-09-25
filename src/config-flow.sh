# ==============================================================================
# ACTION: INSTALL (PHASE 1: CONFIGURATION)
# ==============================================================================
if [ "$SCRIPT_ACTION" == "i" ]; then
    # Fixed step count for this flow (1-10, same regardless of launcher/engine
    # branch) — read by print_step via the STEP_TOTAL global so headers show
    # "N/10. Label" instead of just "N. Label". Step 2 ("Locate Game
    # Executable") only ever appears on the scan path — resolve_exe_folder
    # prints it itself — so browse/manual users jump straight from 1 to 3.
    STEP_TOTAL=10

    EAX_RESTORE_SKIP_CACHE_CHECK="${EAX_RESTORE_SKIP_CACHE_CHECK:-}"
    if is_truthy "$EAX_RESTORE_SKIP_CACHE_CHECK"; then
        print_note "EAX_RESTORE_SKIP_CACHE_CHECK is set — skipping the REPOSITORY CACHE CHECK" \
            "and trusting whatever DSOAL/OpenAL Soft builds are already cached."
    else
        update_local_cache
    fi

    print_banner "PHASE 1: CONFIGURATION"

    # Steps 1-2 loop: at an EAX-impossible dead end (see prompt_restart_or_quit)
    # the user can choose to go back and pick a different game instead of the
    # script exiting. get_game_directory / scan_game_libraries /
    # detect_game_environment all unwind on RESTART_REQUESTED; this re-runs
    # them from the top with a clean slate (get_game_directory resets the
    # per-game globals on entry).
    while true; do
        RESTART_REQUESTED=""

        # 1. Game Location
        print_step 1 "Game Location"
        get_game_directory ""
        [ -n "$RESTART_REQUESTED" ] || check_target_writable "$GAME_DIR" "game folder"

        # 3. Game Identification & Launcher Auto-Detect
        print_step 3 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    # 4. Audio API Detection
    print_step 4 "Audio API Detection"
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
        # Mirrors the OPENAL_NATIVE_MODE branch above. EAX_RESTORE_DSOAL_PIN
        # lands on ENGINE_CHOICE=1 too, so it only changes the wording.
        ENGINE_CHOICE=1
        if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
            print_paragraph "$GAME_NAME uses DirectSound3D — deploying kcat DSOAL (pinned [$DSOAL_PINNED_REV]) + OpenAL Soft."
        else
            print_paragraph "$GAME_NAME uses DirectSound3D — deploying kcat DSOAL + OpenAL Soft."
        fi
    else
    DSOAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    DSOAL_VER=${DSOAL_DATE%%T*}
    [ -z "$DSOAL_VER" ] && DSOAL_VER="Unknown"
    OAL_VER=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    [ -z "$OAL_VER" ] && OAL_VER="Unknown"

    echo -e "\n${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"
    echo -e " * ${BOLD}kcat DSOAL + OpenAL Soft:${NC} The standard choice. Intercepts a game's"
    echo -e "   DirectSound3D/EAX calls and translates them to OpenAL — the right pick for the"
    echo -e "   vast majority of classic Windows games."
    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        echo -e "   ${DIM}EAX_RESTORE_DSOAL_PIN is set: the frozen [$DSOAL_PINNED_REV] DSOAL build will be used"
        echo -e "   in place of the rolling one.${NC}"
    fi
    echo ""
    echo -e " * ${BOLD}OpenAL native:${NC} Only for the handful of games that already call OpenAL directly"
    echo -e "   (no DirectSound3D layer to intercept) — swaps OpenAL Soft in as OpenAL32.dll.\n"

    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        ENGINE_CHOICE=1
        echo -e "${GREEN}EAX_RESTORE_DSOAL_PIN is set — using kcat DSOAL (pinned [$DSOAL_PINNED_REV]) + OpenAL Soft.${NC}"
    else
        echo -e "${YELLOW}Selection (1 or 2) [Default: 1]: ${NC}"
        echo ""
        # Engine 1 stays the default even when its download failed -- engine
        # 2 is only right for OpenAL-native games, so it's never picked for
        # the user; an unavailable engine is shown but refused instead.
        print_option 1 "kcat DSOAL + OpenAL Soft    [DSOAL: $DSOAL_VER | OAL: $OAL_VER]$(engine_available 1 || echo -e " ${YELLOW}[unavailable this run]${NC}")"
        print_option 2 "OpenAL native (direct OpenAL32.dll swap)"

        while true; do
            echo -e -n "\n> "
            read -r ENGINE_CHOICE
            ENGINE_CHOICE="${ENGINE_CHOICE:-1}"
            if [[ ! "$ENGINE_CHOICE" =~ ^[12]$ ]]; then print_warning "That's not a valid option — please type 1 or 2."
            elif ! engine_available "$ENGINE_CHOICE"; then print_warning "kcat DSOAL couldn't be downloaded this run (see the Repository Cache Check above). Pick 2 only if this game uses OpenAL natively; otherwise quit and re-run later."
            else break; fi
        done
    fi
    fi

    # Covers the paths above that pick engine 1 without the menu (a confirmed
    # DirectSound3D game, or EAX_RESTORE_DSOAL_PIN) -- stop here rather than
    # after the rest of the configuration steps.
    if ! engine_available "$ENGINE_CHOICE"; then
        print_error "kcat DSOAL couldn't be downloaded this run, and this game needs it."
        echo -e "${WHITE}Check the Repository Cache Check output above, then re-run the script later.${NC}"
        exit 1
    fi

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
            print_status "Core VC++ runtime files are already present." "$GREEN"
            echo -e "${WHITE}This will set the DLL overrides so Wine actually loads them (file presence alone"
            echo -e "doesn't guarantee that) once you confirm and deploy below, and skip the install step"
            echo -e "itself.${NC}"
            APPLY_VCRUN_OVERRIDES_NEEDED=1
        else
            echo -e "\n${WHITE}These files are missing or incomplete here. Without them, the game may crash"
            echo -e "silently on startup when it tries to load the audio engine.${NC}"
            if confirm "Install genuine MS VC++ runtimes?" N; then INSTALL_VCRUN="y"; else INSTALL_VCRUN="n"; fi
        fi
    else
        echo -e "\n${WHITE}Skipping. You can revisit this later with EAX_RESTORE_VCRUN_ONLY=1 without redoing"
        echo -e "the rest of the install.${NC}"
    fi

    # 8. Audio Configuration
    print_step 8 "Speaker Configuration"
    echo -e "\n${WHITE}What kind of audio output are you using?${NC}\n"
    print_option 1 "Stereo (headphones or 2-speaker setup)"
    print_option 2 "Surround Sound (4.0/5.1/6.1/7.1 speaker setup)"
    print_option 3 "Matrix Encoding (stereo output decoded to surround by a receiver/soundbar)"

    while true; do
        prompt "Selection [1-3, Default: 1]: "
        read -r OUTPUT_MODE_CHOICE
        OUTPUT_MODE_CHOICE="${OUTPUT_MODE_CHOICE:-1}"
        if [[ "$OUTPUT_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_warning "That's not a valid option — please type 1, 2, or 3."; fi
    done

    ENABLE_HRTF=""
    SURROUND_CHANNELS=""

    if [ "$OUTPUT_MODE_CHOICE" == "1" ]; then
        OUTPUT_MODE="stereo"

        echo ""
        echo -e "${WHITE}What are you listening on?${NC}\n"
        print_option 1 "Auto (let OpenAL Soft decide)"
        print_option 2 "Speakers"
        print_option 3 "Headphones"

        while true; do
            prompt "Selection [1-3, Default: 1]: "
            read -r STEREO_MODE_CHOICE
            STEREO_MODE_CHOICE="${STEREO_MODE_CHOICE:-1}"
            if [[ "$STEREO_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_warning "That's not a valid option — please type 1, 2, or 3."; fi
        done

        case "$STEREO_MODE_CHOICE" in
            1) STEREO_MODE="auto" ;;
            2) STEREO_MODE="speakers" ;;
            3) STEREO_MODE="headphones" ;;
        esac

        if [ "$STEREO_MODE_CHOICE" == "2" ]; then
            # HRTF is a headphone-only binaural technique — meaningless (and
            # actively harmful to positional accuracy) over real speakers.
            ENABLE_HRTF="n"
        else
            echo ""
            echo -e "${CYAN}Headphones Configuration (HRTF)${NC}\n"
            echo -e "${WHITE}Head-Related Transfer Function (HRTF) translates 3D positional audio into a binaural"
            echo -e "format specifically designed for standard stereo headphones. Turning this on will"
            echo -e "allow you to hear exactly whether a sound is coming from above, below, or behind you.${NC}\n"
            echo -e "${YELLOW}Do you want to enable HRTF for headphones? (y/N): ${NC}"
            echo -e -n "> "
            read -r ENABLE_HRTF
        fi
    elif [ "$OUTPUT_MODE_CHOICE" == "2" ]; then
        OUTPUT_MODE="surround"

        echo ""
        echo -e "${WHITE}Select your speaker channel configuration:${NC}\n"
        print_option 1 "Quad       (4.0)"
        print_option 2 "Surround51 (5.1)"
        print_option 3 "Surround61 (6.1)"
        print_option 4 "Surround71 (7.1)"

        while true; do
            prompt "Selection [1-4]: "
            read -r SURROUND_CHOICE
            case "$SURROUND_CHOICE" in
                1) SURROUND_CHANNELS="quad"; break ;;
                2) SURROUND_CHANNELS="surround51"; break ;;
                3) SURROUND_CHANNELS="surround61"; break ;;
                4) SURROUND_CHANNELS="surround71"; break ;;
                *) print_warning "That's not a valid option — please type 1, 2, 3, or 4." ;;
            esac
        done
    else
        OUTPUT_MODE="matrix"
    fi

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

    # known-eax-games.json's recommended_tweaks array (see
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

    # recommended_tweaks can flag Expand Audio Limits for a game independently
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
    print_step 10 "Automatic DLL Override"
    print_paragraph "Wine needs to be told to use the new ${PRIMARY_DLL_FILENAME} file instead of its built-in one." \
        "We can inject this rule directly into the Wine prefix registry so you don't have to" \
        "manually type WINEDLLOVERRIDES=\"${PRIMARY_DLL_NAME}=n,b\" %command% into your launcher."
    echo -e "\n${YELLOW}Automatically set ${PRIMARY_DLL_FILENAME} override in Wine registry? (y/N): ${NC}"
    echo -e -n "> "
    read -r AUTO_OVERRIDE

    # (continues below: "if" opened above closes at the bottom of install-flow.sh)
