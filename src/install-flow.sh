    # Continues the "if [ "$SCRIPT_ACTION" == "i" ]" block opened at the top
    # of config-flow.sh.
    # ==============================================================================
    # PHASE 2: EXECUTION
    # ==============================================================================
    print_banner "PHASE 2: EXECUTION"
    echo -e "\n${CYAN}${BOLD}Configuration finished!${NC}"
    echo -e -n "${CYAN}Ready to deploy the audio files to your game and system prefix. Proceed? (Y/n): ${NC}"; read -r CONFIRM_FIN
    if [[ "$CONFIRM_FIN" =~ $NO_RE ]]; then echo -e "\n${YELLOW}Installation aborted.${NC}"; exit 0; fi

    echo -e "\n${CYAN}STATUS: Executing system verbs via $( [ "$LAUNCHER_TYPE" == "1" ] && echo "protontricks" || echo "winetricks" ) (Silent Mode)...${NC}"
    print_status "Installing the OpenAL package via $( [ "$LAUNCHER_TYPE" == "1" ] && echo "protontricks" || echo "winetricks" )..."

    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks "$APPID" -q openal 2>/dev/null
        print_status "OpenAL was installed successfully." "$GREEN"
    else
        if [ -n "$WINE_CMD" ] && [ -n "$PREFIX_PATH" ]; then
            # Using --force to bypass winetricks safety blocks in Heroic
            WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" winetricks --force -q openal 2>/dev/null
            print_status "OpenAL was installed successfully." "$GREEN"
        else
            print_warning_arrow "No local Wine binary or resolved prefix was found, so this step is being skipped."
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
