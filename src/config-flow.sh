# ==============================================================================
# ACTION: INSTALL (PHASE 1: CONFIGURATION)
# ==============================================================================
if [ "$SCRIPT_ACTION" == "i" ]; then
    EAX_RESTORE_SKIP_CACHE_CHECK="${EAX_RESTORE_SKIP_CACHE_CHECK:-}"
    if is_truthy "$EAX_RESTORE_SKIP_CACHE_CHECK"; then
        print_note "EAX_RESTORE_SKIP_CACHE_CHECK is set — skipping the REPOSITORY CACHE CHECK" \
            "and trusting whatever DSOAL/OpenAL Soft builds are already cached."
    else
        update_local_cache
    fi

    print_banner "PHASE 1: CONFIGURATION"

    # 1. Game Location
    print_step 1 "Game Location"
    get_game_directory ""

    # 2. Game Identification & Launcher Auto-Detect
    print_step 2 "Launcher Identification"
    detect_game_environment

    # 3. Audio API Detection
    print_step 3 "Audio API Detection"
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        confirm_continue_if_openal_native "$APPID" "steam" "$GAME_NAME"
    else
        confirm_continue_if_openal_native "$HEROIC_APP_NAME" "gog" "$GAME_NAME"
    fi

    # 4. Architecture Scan
    select_architecture 4

    # 5. Engine Selection
    print_step 5 "Audio Engine Selection"

    if [ -n "$OPENAL_NATIVE_MODE" ]; then
        ENGINE_CHOICE=4
        print_paragraph "This game routes EAX through OpenAL natively, so only kcat's OpenAL Soft build applies" \
            "here (it's the only bundle that ships a standalone OpenAL32.dll) — using it automatically."
    else
    DSOAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    DSOAL_VER=${DSOAL_DATE%%T*}
    [ -z "$DSOAL_VER" ] && DSOAL_VER="Unknown"
    OAL_VER=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    [ -z "$OAL_VER" ] && OAL_VER="Unknown"

    echo -e "\n${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"
    echo -e " * ${BOLD}ThreeDeeJay Community:${NC} The best \"plug-and-play\" choice for older Windows 98/XP games."
    echo -e "   Specific compatibility tweaks curated by the retro-gaming community, though it relies on a"
    echo -e "   slightly older, locked codebase.\n"
    echo -e " * ${BOLD}PCGamingWiki Community DSOAL:${NC} A popular updated community fork offering compatibility"
    echo -e "   fixes for mid-2000s titles. PCGamingWiki blocks automated downloads, so this build is served"
    echo -e "   from a self-hosted mirror rather than their site directly.\n"
    echo -e " * ${BOLD}kcat DSOAL + OpenAL Soft:${NC} The official, rock-solid baseline from the original wrapper developer"
    echo -e "   paired directly with the newest, bleeding-edge audio renderer for the highest fidelity algorithms.\n"

    EAX_RESTORE_DSOAL_COMMUNITY_V13="${EAX_RESTORE_DSOAL_COMMUNITY_V13:-}"
    EAX_RESTORE_DSOAL_COMMUNITY_V14="${EAX_RESTORE_DSOAL_COMMUNITY_V14:-}"
    EAX_RESTORE_DSOAL_OFFICIAL="${EAX_RESTORE_DSOAL_OFFICIAL:-}"

    ENGINE_ENV_SET=0
    is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13" && ((ENGINE_ENV_SET++))
    is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14" && ((ENGINE_ENV_SET++))
    is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL" && ((ENGINE_ENV_SET++))

    if [ "$ENGINE_ENV_SET" -gt 1 ]; then
        print_error "More than one EAX_RESTORE_DSOAL_* variable is set. Set only one and re-run."
        exit 1
    fi

    if is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13"; then
        ENGINE_CHOICE=1
        echo -e "${GREEN}EAX_RESTORE_DSOAL_COMMUNITY_V13 is set — using ThreeDeeJay Community DSOAL.${NC}"
    elif is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14"; then
        ENGINE_CHOICE=2
        echo -e "${GREEN}EAX_RESTORE_DSOAL_COMMUNITY_V14 is set — using PCGamingWiki Community DSOAL.${NC}"
    elif is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL"; then
        ENGINE_CHOICE=3
        echo -e "${GREEN}EAX_RESTORE_DSOAL_OFFICIAL is set — using kcat DSOAL + OpenAL Soft.${NC}"
    else
        echo -e "${YELLOW}Selection (1, 2, or 3) [Default: 3]: ${NC}"
        echo -e "\n 1) ThreeDeeJay Community DSOAL [v1.31a]"
        echo -e " 2) PCGamingWiki Community DSOAL (self-hosted mirror) [v1.4]"
        echo -e " 3) kcat DSOAL + OpenAL Soft    [DSOAL: $DSOAL_VER | OAL: $OAL_VER]"

        while true; do
            echo -e -n "\n> "
            read -r ENGINE_CHOICE
            ENGINE_CHOICE="${ENGINE_CHOICE:-3}"
            if [[ "$ENGINE_CHOICE" =~ ^[123]$ ]]; then break; else print_warning "Invalid selection. Please type 1, 2, or 3."; fi
        done
    fi
    fi

    # The Wine DLL override this install ultimately needs — dsound.dll for
    # engines 1-3 (DSOAL intercepts DirectSound3D), OpenAL32.dll for engine 4
    # (OpenAL Soft deployed directly, nothing for DSOAL to intercept). Set
    # once here so every later step (override wording, registry, deployment,
    # final launch instructions) reads the same value instead of each
    # re-deriving it from ENGINE_CHOICE or OPENAL_NATIVE_MODE separately.
    # PRIMARY_DLL_NAME is the lowercase WINEDLLOVERRIDES key; PRIMARY_DLL_FILENAME
    # is the on-disk filename (Wine treats overrides case-insensitively, but
    # the actual deployed file is written with its conventional casing).
    PRIMARY_DLL_NAME="dsound"
    PRIMARY_DLL_FILENAME="dsound.dll"
    if [ "$ENGINE_CHOICE" == "4" ]; then
        PRIMARY_DLL_NAME="openal32"
        PRIMARY_DLL_FILENAME="OpenAL32.dll"
    fi

    # 6. VC++ Runtime Dependencies
    INSTALL_VCRUN="n"
    if [ "$ENGINE_CHOICE" == "3" ] || [ "$ENGINE_CHOICE" == "4" ]; then
        print_step 6 "VC++ Runtime Dependencies"
        print_paragraph "The modern kcat engine needs genuine Microsoft C++ runtime libraries. Older Proton/Wine" \
            "builds (9 and below) tend to be missing them more often than newer ones — but rather" \
            "than guess from a version number, this can check the prefix directly."

        if confirm "Check this prefix for existing VC++ runtime files?"; then
            echo -e "\n${CYAN}STATUS: Checking prefix for existing VC++ runtime files...${NC}"

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
    fi

    # 7. Audio Configuration
    print_step 7 "Speaker Configuration"
    echo -e "\n${WHITE}What kind of audio output are you using?${NC}\n"
    echo -e " 1) Stereo (headphones or 2-speaker setup)"
    echo -e " 2) Surround Sound (4.0/5.1/6.1/7.1 speaker setup)"
    echo -e " 3) Matrix Encoding (stereo output decoded to surround by a receiver/soundbar)\n"

    while true; do
        echo -e "${YELLOW}Selection [1-3, Default: 1]: ${NC}"
        echo -e -n "> "
        read -r OUTPUT_MODE_CHOICE
        OUTPUT_MODE_CHOICE="${OUTPUT_MODE_CHOICE:-1}"
        if [[ "$OUTPUT_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_warning "Invalid selection. Please type 1, 2, or 3."; fi
    done

    ENABLE_HRTF=""
    SURROUND_CHANNELS=""

    if [ "$OUTPUT_MODE_CHOICE" == "1" ]; then
        OUTPUT_MODE="stereo"

        echo ""
        echo -e "${WHITE}What are you listening on?${NC}\n"
        echo -e " 1) Auto (let OpenAL Soft decide)"
        echo -e " 2) Speakers"
        echo -e " 3) Headphones\n"

        while true; do
            echo -e "${YELLOW}Selection [1-3, Default: 1]: ${NC}"
            echo -e -n "> "
            read -r STEREO_MODE_CHOICE
            STEREO_MODE_CHOICE="${STEREO_MODE_CHOICE:-1}"
            if [[ "$STEREO_MODE_CHOICE" =~ ^[123]$ ]]; then break; else print_warning "Invalid selection. Please type 1, 2, or 3."; fi
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
        echo -e " 1) Quad       (4.0)"
        echo -e " 2) Surround51 (5.1)"
        echo -e " 3) Surround61 (6.1)"
        echo -e " 4) Surround71 (7.1)\n"

        while true; do
            echo -e "${YELLOW}Selection [1-4]: ${NC}"
            echo -e -n "> "
            read -r SURROUND_CHOICE
            case "$SURROUND_CHOICE" in
                1) SURROUND_CHANNELS="quad"; break ;;
                2) SURROUND_CHANNELS="surround51"; break ;;
                3) SURROUND_CHANNELS="surround61"; break ;;
                4) SURROUND_CHANNELS="surround71"; break ;;
                *) print_warning "Invalid selection. Please type 1, 2, 3, or 4." ;;
            esac
        done
    else
        OUTPUT_MODE="matrix"
    fi

    # 8. Advanced Compatibility Tweaks
    print_step 8 "Advanced Compatibility Tweaks"
    echo -e "\n${WHITE}These optional workarounds are designed for extremely stubborn games"
    echo -e "that refuse to load EAX normally. In 90% of cases, you do not need these.${NC}\n"

    ADVANCED_DUMMY="n"
    ADVANCED_LIMITS="n"
    ADVANCED_COM="n"

    # Tweaks A (EAX Unified dummy files) and C (COM registry routing) both
    # target DirectSound3D specifically and have nothing to attach to on a
    # direct OpenAL32.dll swap — so engine 4 only ever offers Tweak B.
    TWEAK_A_APPLICABLE=1
    TWEAK_C_APPLICABLE=1
    if [ "$ENGINE_CHOICE" == "4" ]; then
        TWEAK_A_APPLICABLE=0
        TWEAK_C_APPLICABLE=0
    fi

    if [ "$TWEAK_A_APPLICABLE" -eq 0 ] && [ "$TWEAK_C_APPLICABLE" -eq 0 ]; then
        echo -e "${WHITE}Tweaks A and C target DirectSound3D specifically (the EAX Unified menu gate and"
        echo -e "dsound.dll COM routing), which don't apply to a direct OpenAL32.dll swap — only Tweak B applies here.${NC}\n"

        echo -e "${CYAN}${BOLD}Tweak B: Expand Audio Limits${NC}"
        echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
        echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
        echo -e "\n${YELLOW}Expand OpenAL audio limits? (y/N): ${NC}"
        echo -e -n "> "
        read -r ADVANCED_LIMITS
    else
        echo -e "${YELLOW}Would you like to view and opt-in to these advanced tweaks? (y/N): ${NC}"
        echo -e -n "> "
        read -r SHOW_ADVANCED

        if [[ "$SHOW_ADVANCED" =~ $YES_RE ]]; then
            if [ "$TWEAK_A_APPLICABLE" -eq 1 ]; then
                echo -e "\n${CYAN}${BOLD}Tweak A: EAX Unified Dummy Files${NC}"
                echo -e "${WHITE}Tricks certain games (like KOTOR, Max Payne, and early Unreal Engine titles)"
                echo -e "into unlocking the EAX menu option by creating harmless, empty eax.dll and eaxunified.dll files.${NC}"
                echo -e "\n${YELLOW}Inject EAX Unified dummy files? (y/N): ${NC}"
                echo -e -n "> "
                read -r ADVANCED_DUMMY
                echo ""
            fi

            echo -e "${CYAN}${BOLD}Tweak B: Expand Audio Limits${NC}"
            echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
            echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
            echo -e "\n${YELLOW}Expand OpenAL audio limits? (y/N): ${NC}"
            echo -e -n "> "
            read -r ADVANCED_LIMITS

            if [ "$TWEAK_C_APPLICABLE" -eq 1 ]; then
                echo ""
                echo -e "${CYAN}${BOLD}Tweak C: COM Registry Routing${NC}"
                echo -e "${WHITE}Explicitly forces the Windows registry to point directly to our custom dsound.dll."
                echo -e "Beneficial for stubborn late-90s and early-2000s games that actively ignore local DLL files.${NC}"
                echo -e "\n${YELLOW}Inject COM registry routing? (y/N): ${NC}"
                echo -e -n "> "
                read -r ADVANCED_COM
            fi
        fi
    fi

    # 9. Automatic DLL Override
    print_step 9 "Automatic DLL Override"
    print_paragraph "Wine needs to be told to use the new ${PRIMARY_DLL_FILENAME} file instead of its built-in one." \
        "We can inject this rule directly into the Wine prefix registry so you don't have to" \
        "manually type WINEDLLOVERRIDES=\"${PRIMARY_DLL_NAME}=n,b\" %command% into your launcher."
    echo -e "\n${YELLOW}Automatically set ${PRIMARY_DLL_FILENAME} override in Wine registry? (y/N): ${NC}"
    echo -e -n "> "
    read -r AUTO_OVERRIDE

    # (continues below: "if" opened above closes at the bottom of install-flow.sh)
