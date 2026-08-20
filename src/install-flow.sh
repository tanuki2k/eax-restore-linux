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
        echo -e "${WHITE}This game routes EAX through OpenAL natively, so only kcat's OpenAL Soft build applies"
        echo -e "here (it's the only bundle that ships a standalone OpenAL32.dll) — using it automatically.${NC}"
    else
    DSOAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    DSOAL_VER=${DSOAL_DATE%%T*}
    [ -z "$DSOAL_VER" ] && DSOAL_VER="Unknown"
    OAL_VER=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    [ -z "$OAL_VER" ] && OAL_VER="Unknown"

    echo -e "${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"
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
        echo -e "${WHITE}The modern kcat engine needs genuine Microsoft C++ runtime libraries. Older Proton/Wine"
        echo -e "builds (9 and below) tend to be missing them more often than newer ones — but rather"
        echo -e "than guess from a version number, this can check the prefix directly.${NC}"

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
    echo -e "${WHITE}What kind of audio output are you using?${NC}\n"
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
    echo -e "${WHITE}These optional workarounds are designed for extremely stubborn games"
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
    echo -e "${WHITE}Wine needs to be told to use the new ${PRIMARY_DLL_FILENAME} file instead of its built-in one."
    echo -e "We can inject this rule directly into the Wine prefix registry so you don't have to"
    echo -e "manually type WINEDLLOVERRIDES=\"${PRIMARY_DLL_NAME}=n,b\" %command% into your launcher.${NC}"
    echo -e "\n${YELLOW}Automatically set ${PRIMARY_DLL_FILENAME} override in Wine registry? (y/N): ${NC}"
    echo -e -n "> "
    read -r AUTO_OVERRIDE

    # ==============================================================================
    # PHASE 2: EXECUTION
    # ==============================================================================
    print_banner "PHASE 2: EXECUTION"
    echo -e "\n${CYAN}${BOLD}Configuration finished!${NC}"
    echo -e -n "${CYAN}Ready to deploy the audio files to your game and system prefix. Proceed? (Y/n): ${NC}"; read -r CONFIRM_FIN
    if [[ "$CONFIRM_FIN" =~ $NO_RE ]]; then echo -e "\n${YELLOW}Installation aborted.${NC}"; exit 0; fi

    echo -e "\n${CYAN}STATUS: Executing system verbs via $( [ "$LAUNCHER_TYPE" == "1" ] && echo "protontricks" || echo "winetricks" ) (Silent Mode)...${NC}"
    print_status "Applying core package: openal"

    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks "$APPID" -q openal 2>/dev/null
        print_status "Core package (openal) applied successfully." "$GREEN"
    else
        if [ -n "$WINE_CMD" ]; then
            # Using --force to bypass winetricks safety blocks in Heroic
            WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" winetricks --force -q openal 2>/dev/null
            print_status "Core package (openal) applied successfully." "$GREEN"
        else
            print_warning_arrow "No local Wine binary found. Skipping core package."
        fi
    fi

   VCRUN_INSTALLED_THIS_RUN="0"
   if [[ "$INSTALL_VCRUN" =~ $YES_RE ]]; then
        install_vcrun_dependencies && VCRUN_INSTALLED_THIS_RUN="1"
    elif [ -n "${APPLY_VCRUN_OVERRIDES_NEEDED:-}" ]; then
        # Deferred from step 5: the runtime was already present, so this just
        # sets the DLL overrides, only now that the user has confirmed and
        # this is actually happening (not back during configuration).
        apply_vcrun_dll_overrides
        VCRUN_INSTALLED_THIS_RUN="1"
    fi

    # Engine-specific paths
    case "$ENGINE_CHOICE" in
        1)
            TARGET_COMMUNITY=$(find "$DSOAL_COMMUNITY_V13" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
            DSOUND_SRC="$TARGET_COMMUNITY/dsound.dll"
            DSOAL_SRC="$TARGET_COMMUNITY/dsoal-aldrv.dll"
            ;;
        2)
            TARGET_V14=$(find "$DSOAL_COMMUNITY_V14" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
            DSOUND_SRC="$TARGET_V14/dsound.dll"
            DSOAL_SRC="$TARGET_V14/dsoal-aldrv.dll"
            ;;
        3)
            TARGET_DSOAL=$(find "$DSOAL_OFFICIAL" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
            TARGET_OAL=$(find "$OPENAL_OFFICIAL" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)
            DSOUND_SRC="$TARGET_DSOAL/dsound.dll"
            DSOAL_SRC="$TARGET_OAL/soft_oal.dll"
            ;;
        4)
            TARGET_OAL=$(find "$OPENAL_OFFICIAL" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)
            OPENAL_SRC="$TARGET_OAL/soft_oal.dll"
            ;;
    esac

    if [ "$ENGINE_CHOICE" == "4" ]; then
        if [ ! -f "$OPENAL_SRC" ]; then
            print_error "Required OpenAL Soft source file was not found in the cache."
            echo -e "\n${WHITE}This usually means the download failed or was incomplete earlier in this run"
            echo -e "(check the REPOSITORY CACHE CHECK output above), or the ${ARCH_FOLDER} build isn't present in it."
            echo -e "Re-run the script to retry the download.${NC}"
            exit 1
        fi
    elif [ ! -f "$DSOUND_SRC" ] || [ ! -f "$DSOAL_SRC" ]; then
        print_error "Required source files for the selected engine were not found in the cache."
        echo -e "\n${WHITE}This usually means the download for this engine failed or was incomplete earlier in this run"
        echo -e "(check the REPOSITORY CACHE CHECK output above), or the ${ARCH_FOLDER} build isn't present in it."
        echo -e "Re-run the script to retry the download, or choose a different engine.${NC}"
        exit 1
    fi

    # Manifest of everything THIS run actually deploys, so uninstall only ever
    # touches files the script itself put there (never pre-existing user files
    # that were left alone because of a [s]kip during a conflict prompt).
    INSTALL_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"

    # On a reinstall, files this script placed last time (e.g. dsound.dll)
    # are still sitting there and will look like a "conflict" to
    # handle_conflict() below — but they're not a genuine original worth
    # backing up, they're just our own previous output. Capture the old
    # manifest's file list BEFORE truncating it so conflict handling can
    # tell the two apart and skip a backup that would otherwise bury the
    # real original (if one exists) under a backup of our own DLL.
    declare -A PREV_MANIFEST_FILES
    if [ -s "$INSTALL_MANIFEST" ]; then
        while IFS= read -r line; do
            [[ "$line" == /* ]] && PREV_MANIFEST_FILES["$line"]=1
        done < "$INSTALL_MANIFEST"
    fi

    : > "$INSTALL_MANIFEST"
    [ "$VCRUN_INSTALLED_THIS_RUN" == "1" ] && echo "VCRUN" >> "$INSTALL_MANIFEST"

    echo -e "\n${CYAN}STATUS: Deploying files to local game folder...${NC}"

    # DEPLOY_SRC/DEPLOY_DEST_NAME[0] is always the "primary" override DLL
    # (dsound.dll for engines 1-3, OpenAL32.dll for engine 4) — the one Wine
    # gets told to override. Any further entries are secondary implementation
    # files DSOAL itself needs (dsoal-aldrv.dll) that aren't overridden
    # directly. One shared list/loop serves all 4 engine choices instead of
    # a separate copy-block per engine.
    DEPLOY_SRC=(); DEPLOY_DEST_NAME=()
    if [ "$ENGINE_CHOICE" == "4" ]; then
        DEPLOY_SRC=("$OPENAL_SRC")
        DEPLOY_DEST_NAME=("OpenAL32.dll")
    else
        DEPLOY_SRC=("$DSOUND_SRC" "$DSOAL_SRC")
        DEPLOY_DEST_NAME=("dsound.dll" "dsoal-aldrv.dll")
    fi

    for i in "${!DEPLOY_SRC[@]}"; do
        DEPLOY_DEST="$GAME_DIR/${DEPLOY_DEST_NAME[$i]}"
        if handle_conflict "$DEPLOY_DEST"; then
            cp -f "${DEPLOY_SRC[$i]}" "$DEPLOY_DEST"
            echo "$DEPLOY_DEST" >> "$INSTALL_MANIFEST"
            print_status "Copied: ${DEPLOY_DEST_NAME[$i]} to $(basename "$GAME_DIR")"
        fi
    done

    # V14 is the only bundle with genuine curated HRTF profiles (V13 has
    # none, despite its zip's name — see engine descriptions above). Since
    # update_local_cache always fetches V14 up front regardless of which
    # engine ends up chosen, its HRTF set is layered onto whichever engine's
    # DLLs are actually being deployed, rather than only being available
    # when V14 itself is the chosen engine.
    HRTF_SRC_DIR=$(find "$DSOAL_COMMUNITY_V14" -type d -iname "HRTF" 2>/dev/null | head -n 1)

    if [ -n "$HRTF_SRC_DIR" ]; then
        OPENAL_DIR_PREEXISTED=0
        [ -d "$GAME_DIR/OpenAL" ] && OPENAL_DIR_PREEXISTED=1

        mkdir -p "$GAME_DIR/OpenAL/HRTF"
        cp -r "$HRTF_SRC_DIR/"* "$GAME_DIR/OpenAL/HRTF/"

        if [ "$OPENAL_DIR_PREEXISTED" -eq 1 ]; then
            # The OpenAL folder was already there before this run (game files
            # or an unrelated mod) — only track the HRTF subfolder we added,
            # so uninstall can't wipe out whatever else lives alongside it.
            echo "$GAME_DIR/OpenAL/HRTF" >> "$INSTALL_MANIFEST"
        else
            echo "$GAME_DIR/OpenAL" >> "$INSTALL_MANIFEST"
        fi
        print_status "Deployed: HRTF profile directory to $(basename "$GAME_DIR")"
    fi

    if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
        echo -e "\n${CYAN}STATUS: Duplicating files to Wine/Proton system prefix...${NC}"
        if [ "$ARCH" == "32" ] && [ -d "$PREFIX_PATH/drive_c/windows/syswow64" ]; then
            PREFIX_TARGET_DIR="$PREFIX_PATH/drive_c/windows/syswow64"
        else
            PREFIX_TARGET_DIR="$PREFIX_PATH/drive_c/windows/system32"
        fi

        # Index 0 (the primary override DLL) is unconditionally backed up
        # and overwritten — it's the one file Wine is being told to
        # override anyway. Any secondary files (dsoal-aldrv.dll) go through
        # the interactive conflict prompt instead, same as the game-dir copy
        # above, since a pre-existing file of that exact name is unusual.
        for i in "${!DEPLOY_SRC[@]}"; do
            DEPLOY_DEST="$PREFIX_TARGET_DIR/${DEPLOY_DEST_NAME[$i]}"
            if [ "$i" -eq 0 ]; then
                auto_backup_and_overwrite "$DEPLOY_DEST"
                cp -f "${DEPLOY_SRC[$i]}" "$DEPLOY_DEST"
                echo "$DEPLOY_DEST" >> "$INSTALL_MANIFEST"
                print_status "Duplicated: ${DEPLOY_DEST_NAME[$i]} to $(basename "$PREFIX_TARGET_DIR")"
            elif handle_conflict "$DEPLOY_DEST"; then
                cp -f "${DEPLOY_SRC[$i]}" "$DEPLOY_DEST"
                echo "$DEPLOY_DEST" >> "$INSTALL_MANIFEST"
                print_status "Duplicated: ${DEPLOY_DEST_NAME[$i]} to $(basename "$PREFIX_TARGET_DIR")"
            fi
        done
    fi

    echo -e "\n${CYAN}STATUS: Applying configurations and tweaks...${NC}"

    if [[ "$ADVANCED_DUMMY" =~ $YES_RE ]]; then
        if handle_conflict "$GAME_DIR/eax.dll"; then
            touch "$GAME_DIR/eax.dll"; echo "$GAME_DIR/eax.dll" >> "$INSTALL_MANIFEST"
            print_status "Created: eax.dll dummy"
        fi
        if handle_conflict "$GAME_DIR/eaxunified.dll"; then
            touch "$GAME_DIR/eaxunified.dll"; echo "$GAME_DIR/eaxunified.dll" >> "$INSTALL_MANIFEST"
            print_status "Created: eaxunified.dll dummy"
        fi
    fi

    if handle_conflict "$GAME_DIR/alsoft.ini"; then
        echo "$GAME_DIR/alsoft.ini" >> "$INSTALL_MANIFEST"
        if [ "$OUTPUT_MODE" == "surround" ]; then
            # Surround speaker setups bypass HRTF (headphone-only binaural
            # processing) and stereo-only encodings entirely.
            channels="$SURROUND_CHANNELS"
            STEREO_MODE="auto"
            STEREO_ENCODING="basic"
            HRTF_MODE=""
        elif [ "$OUTPUT_MODE" == "matrix" ]; then
            # Matrix-encoded stereo output also bypasses HRTF — the
            # matrix decoder (tsme) needs an unprocessed stereo signal.
            channels="stereo"
            STEREO_MODE="auto"
            STEREO_ENCODING="tsme"
            HRTF_MODE=""
        elif [[ "$ENABLE_HRTF" =~ $YES_RE ]]; then
            channels="stereo"
            STEREO_ENCODING="hrtf"
            HRTF_MODE="full"
        else
            channels="stereo"
            STEREO_ENCODING="basic"
            HRTF_MODE=""
        fi

        if [ -n "$HRTF_MODE" ]; then
            HRTF_MODE_PREFIX=""
            HRTF_VALUE="auto"
        else
            HRTF_MODE_PREFIX="# "
            HRTF_MODE="full"
            HRTF_VALUE="off"
        fi

        if [[ "$ADVANCED_LIMITS" =~ $YES_RE ]]; then
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux (Advanced Tweaks)

[general]
channels = $channels
sample-type = float32
stereo-mode = $STEREO_MODE
stereo-encoding = $STEREO_ENCODING
# hrtf is deprecated in favor of hrtf-mode, kept here for older builds
hrtf = $HRTF_VALUE
${HRTF_MODE_PREFIX}hrtf-mode = $HRTF_MODE
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

# Advanced Audio Limit Expansion
sources = 256
frequency = 48000

[decoder]
resampler = spline

[EAX]
enable = true
EOF
            print_status "Generated: Advanced alsoft.ini with expanded channel limits"
        else
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux

[general]
channels = $channels
sample-type = float32
stereo-mode = $STEREO_MODE
stereo-encoding = $STEREO_ENCODING
# hrtf is deprecated in favor of hrtf-mode, kept here for older builds
hrtf = $HRTF_VALUE
${HRTF_MODE_PREFIX}hrtf-mode = $HRTF_MODE
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

[decoder]
resampler = spline

[EAX]
enable = true
EOF
            print_status "Generated: Linux-optimised alsoft.ini"
        fi
    fi

    if [[ "$ADVANCED_COM" =~ $YES_RE ]] || [[ "$AUTO_OVERRIDE" =~ $YES_RE ]]; then
        # Written into GAME_DIR rather than a temp dir: apply_registry_patch
        # (detection.sh) runs `protontricks -c` for Steam games, which
        # executes inside a Steam Runtime container that may not have /tmp
        # bind-mounted — the game's own library folder is guaranteed to be
        # visible instead.
        REG_FILE="$GAME_DIR/dsoal_master_patch_$$.reg"
        echo "Windows Registry Editor Version 5.00" > "$REG_FILE"
        echo "" >> "$REG_FILE"

        if [[ "$ADVANCED_COM" =~ $YES_RE ]]; then
            cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"

EOF
        fi

        if [[ "$AUTO_OVERRIDE" =~ $YES_RE ]]; then
            cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"${PRIMARY_DLL_NAME}"="native,builtin"

EOF
        fi

        apply_registry_patch "$REG_FILE"
        rm -f "$REG_FILE"

        [[ "$ADVANCED_COM" =~ $YES_RE ]] && echo "REGISTRY:COM" >> "$INSTALL_MANIFEST" && print_status "Injected: COM Registry Routing"
        if [[ "$AUTO_OVERRIDE" =~ $YES_RE ]]; then
            echo "REGISTRY:OVERRIDE:${PRIMARY_DLL_NAME}" >> "$INSTALL_MANIFEST"
            print_status "Injected: WINEDLLOVERRIDES (native,builtin) into registry"
        fi
    fi

    print_banner "INSTALLATION COMPLETE!"

    if [[ "$AUTO_OVERRIDE" =~ $YES_RE ]]; then
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}The DLL Override was handled automatically! Just hit Play.${NC}"
        echo -e " 2. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}\n"
    else
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Set the Override:${NC} ${WHITE}Apply the WINEDLLOVERRIDES rule (see below).${NC}"
        echo -e " 2. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}Start the game as you normally would.${NC}"
        echo -e " 3. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}\n"

        OVERRIDE_VALUE="${PRIMARY_DLL_NAME}=n,b"
        if [ "$LAUNCHER_TYPE" == "1" ]; then
            echo -e "${BOLD}Steam Launch Options:${NC}"
            echo -e "${CYAN}WINEDLLOVERRIDES=\"$OVERRIDE_VALUE\" %command%${NC}"
        else
            echo -e "${BOLD}Heroic Environment Variable:${NC}"
            echo -e "Name:  ${CYAN}WINEDLLOVERRIDES${NC}"
            echo -e "Value: ${CYAN}$OVERRIDE_VALUE${NC}"
        fi
    fi
    echo ""
fi
