    # Continues the "if [ "$SCRIPT_ACTION" == "i" ]" block opened at the top
    # of config-flow.sh.
    # ==============================================================================
    # PHASE 2: EXECUTION
    # ==============================================================================
    print_banner "PHASE 2: EXECUTION"
    echo -e "\n${CYAN}${BOLD}Configuration finished!${NC}"
    print_choices_summary
    if ! confirm "Ready to deploy the audio files to your game and system prefix. Proceed?"; then
        echo -e "\n${YELLOW}Installation aborted.${NC}"
        exit 0
    fi

    # Checks that can stop the install run before anything is changed, so
    # a failure never leaves the prefix half-set-up (and its error isn't
    # shown under an unrelated step's header).

    # Engine-specific paths, from the builds chosen in step 6 (stable or
    # latest, per component — see dsoal_source_dir / openal_source_dll).
    # Engine 1 deploys DSOAL's dsound.dll plus OpenAL Soft as
    # dsoal-aldrv.dll; engine 2 deploys only OpenAL Soft, as OpenAL32.dll.
    case "$ENGINE_CHOICE" in
        1)
            DSOUND_SRC="$(dsoal_source_dir)/dsound.dll"
            DSOAL_SRC="$(openal_source_dll)"
            ;;
        2)
            OPENAL_SRC="$(openal_source_dll)"
            ;;
    esac

    if [ "$ENGINE_CHOICE" == "2" ]; then
        if [ ! -f "$OPENAL_SRC" ]; then
            print_error "Required OpenAL Soft source file was not found in the cache."
            echo -e "\n${WHITE}This usually means the download failed or was incomplete earlier in this run"
            echo -e "(check the Audio Engine Selection step's download output above), or the ${ARCH_FOLDER} build isn't present in it."
            echo -e "Re-run the script to retry the download.${NC}"
            exit 1
        fi
    elif [ ! -f "$DSOUND_SRC" ] || [ ! -f "$DSOAL_SRC" ]; then
        print_error "Required source files for the selected engine were not found in the cache."
        echo -e "\n${WHITE}This usually means the download for this engine failed or was incomplete earlier in this run"
        echo -e "(check the Audio Engine Selection step's download output above), or the ${ARCH_FOLDER} build isn't present in it."
        echo -e "Re-run the script to retry the download, or choose a different engine.${NC}"
        exit 1
    fi

    # The prefix copy comes after the game-folder copy, so check it can be
    # written now rather than failing halfway through deployment.
    if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows/system32" ]; then
        check_target_writable "$PREFIX_PATH/drive_c/windows/system32" "Wine/Proton prefix"
    fi
    for i in "${!COMPANION_IDS[@]}"; do
        check_target_writable "${COMPANION_PREFIXES[$i]}/drive_c/windows/system32" "${COMPANION_NAMES[$i]}'s Proton prefix"
    done

    # One bar step per STATUS: header below: OpenAL runtime, game folder,
    # configurations, plus VC++ (installing it, or setting up one that's
    # already there), the prefix copy and game settings when those run.
    phase_total=3
    [ "$OVERRIDE_METHOD" == "launcher" ] && phase_total=$(( phase_total + 1 ))
    [ ${#GAME_SETTINGS_PLAN[@]} -gt 0 ] && phase_total=$(( phase_total + 1 ))
    { [[ "$INSTALL_VCRUN" =~ $YES_RE ]] || [ -n "${APPLY_VCRUN_OVERRIDES_NEEDED:-}" ]; } && phase_total=$(( phase_total + 1 ))
    [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ] && phase_total=$(( phase_total + 1 ))
    # Each companion app's prefix setup, plus its VC++ install when it gets one.
    for i in "${!COMPANION_IDS[@]}"; do
        phase_total=$(( phase_total + 1 ))
        [ "${COMPANION_VCRUN[$i]:-}" == "install" ] && phase_total=$(( phase_total + 1 ))
    done
    start_phase_progress "$phase_total"

    print_phase_task "Installing Creative's OpenAL runtime into the prefix"
    install_openal_runtime

   VCRUN_INSTALLED_THIS_RUN="0"
   if [[ "$INSTALL_VCRUN" =~ $YES_RE ]]; then
        install_vcrun_dependencies && VCRUN_INSTALLED_THIS_RUN="1"
    elif [ -n "${APPLY_VCRUN_OVERRIDES_NEEDED:-}" ]; then
        # Deferred from step 5: the runtime was already present, so this just
        # sets the DLL overrides, only now that the user has confirmed and
        # this is actually happening (not back during configuration).
        # Recorded even if setting them failed (that warns on its own), so
        # uninstall still tries to clear any that did get written.
        print_phase_task "Setting up the VC++ runtime that's already in the prefix"
        apply_vcrun_dll_overrides
        VCRUN_INSTALLED_THIS_RUN="1"
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
    # Its CONFIG: lines (game settings changed last time) are kept too, so
    # apply_game_settings can keep each setting's original value and carry
    # over the ones still in effect.
    declare -A PREV_MANIFEST_FILES
    PREV_CONFIG_LINES=()
    # And its LAUNCHER: lines, for an override that's still in place: the
    # launcher step finds it "already set" and keeps the line, so uninstall
    # can still put back what was there before the first install.
    PREV_LAUNCHER_LINES=()
    if [ -s "$INSTALL_MANIFEST" ]; then
        while IFS= read -r line; do
            [[ "$line" == /* ]] && PREV_MANIFEST_FILES["$line"]=1
            [[ "$line" == CONFIG:* ]] && PREV_CONFIG_LINES+=("$line")
            [[ "$line" == LAUNCHER:* ]] && PREV_LAUNCHER_LINES+=("$line")
        done < "$INSTALL_MANIFEST"
    fi

    DEPLOY_FAILURES=0

    start_manifest "$INSTALL_MANIFEST"
    [ "$VCRUN_INSTALLED_THIS_RUN" == "1" ] && echo "VCRUN" >> "$INSTALL_MANIFEST"

    print_phase_task "Deploying files to local game folder"

    # DEPLOY_SRC/DEPLOY_DEST_NAME[0] is always the "primary" override DLL
    # (dsound.dll for engine 1, OpenAL32.dll for engine 2) — the one Wine
    # gets told to override. Any further entries are secondary implementation
    # files DSOAL itself needs (dsoal-aldrv.dll) that aren't overridden
    # directly. One shared list/loop serves both engine choices instead of
    # a separate copy-block per engine.
    DEPLOY_SRC=(); DEPLOY_DEST_NAME=()
    if [ "$ENGINE_CHOICE" == "2" ]; then
        DEPLOY_SRC=("$OPENAL_SRC")
        DEPLOY_DEST_NAME=("OpenAL32.dll")
    else
        DEPLOY_SRC=("$DSOUND_SRC" "$DSOAL_SRC")
        DEPLOY_DEST_NAME=("dsound.dll" "dsoal-aldrv.dll")
    fi

    # GAME_DIR plus any extra exe folders from the game profile (see
    # resolve_extra_exe_folders) — each exe loads these from its own folder.
    # The manifest stays in GAME_DIR; its absolute paths cover the rest.
    GAME_DIRS=("$GAME_DIR" "${EXTRA_GAME_DIRS[@]}")

    for deploy_dir in "${GAME_DIRS[@]}"; do
        for i in "${!DEPLOY_SRC[@]}"; do
            DEPLOY_DEST="$deploy_dir/${DEPLOY_DEST_NAME[$i]}"
            if handle_conflict "$DEPLOY_DEST"; then
                deploy_copy "${DEPLOY_SRC[$i]}" "$DEPLOY_DEST" "Copied"
            fi
        done
    done

    if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
        print_phase_task "Duplicating files to Wine/Proton system prefix"
        deploy_prefix_dlls
    fi

    print_phase_task "Applying configurations and tweaks"

    if [[ "$ADVANCED_DUMMY" =~ $YES_RE ]]; then
        # The dummy only helps a game that checks for the file's presence to
        # unlock its EAX menu. If a genuine eax.dll/eaxunified.dll is already
        # there the game ships and loads its own — shadowing it with a
        # zero-byte file can stop it booting — so leave a real one alone.
        for deploy_dir in "${GAME_DIRS[@]}"; do
            for dummy in eax.dll eaxunified.dll; do
                if is_genuine_dll "$(find_existing_variant "$deploy_dir/$dummy")"; then
                    print_status "Kept: existing $dummy in $(basename "$deploy_dir") (game ships its own — dummy skipped)"
                elif handle_conflict "$deploy_dir/$dummy"; then
                    if touch "$deploy_dir/$dummy"; then echo "$deploy_dir/$dummy" >> "$INSTALL_MANIFEST"; print_status "Created: $dummy dummy in $(basename "$deploy_dir")"
                    else record_deploy_failure "$deploy_dir/$dummy"; fi
                fi
            done
        done
    fi

    if handle_conflict "$GAME_DIR/alsoft.ini"; then
        speaker_alsoft_values

        if [[ "$ADVANCED_LIMITS" =~ $YES_RE ]]; then
            ALSOFT_HEADER="# Auto-generated by EAX Restore Script for Linux (Advanced Tweaks)"
        else
            ALSOFT_HEADER="# Auto-generated by EAX Restore Script for Linux"
        fi

        # Each setting carries its description from OpenAL Soft's reference
        # alsoft.ini, so the file explains itself to anyone tweaking it by hand.
        {
            cat <<EOF
$ALSOFT_HEADER

[general]

## channels:
#  Sets the default output channel configuration. If left unspecified, one will
#  try to be detected from the system, with a fallback to stereo. The available
#  values are: mono, stereo, quad, surround51, surround61, surround71,
#  surround714, 3d71, ambi1, ambi2, ambi3, ambi4. Note that the ambi*
#  configurations output ambisonic channels of the given order (using ACN
#  ordering and SN3D normalization by default), which need to be decoded to
#  play correctly on speakers.
channels = $ALSOFT_CHANNELS

## sample-type:
#  Sets the default output sample type. Currently, all mixing is done with
#  32-bit float and converted to the output sample type as needed. Available
#  values are:
#  int8    - signed 8-bit int
#  uint8   - unsigned 8-bit int
#  int16   - signed 16-bit int
#  uint16  - unsigned 16-bit int
#  int32   - signed 32-bit int
#  uint32  - unsigned 32-bit int
#  float32 - 32-bit float
sample-type = float32

## stereo-mode:
#  Specifies if stereo output is treated as being headphones or speakers. With
#  headphones, HRTF or crossfeed filters may be used for better audio quality.
#  Valid settings are auto, speakers, and headphones.
stereo-mode = $STEREO_MODE

## stereo-encoding:
#  Specifies the default encoding method for stereo output. Valid values are:
#  basic - Standard amplitude panning (aka pair-wise, stereo pair, etc) between
#          -30 and +30 degrees.
#  uhj - Creates a stereo-compatible two-channel UHJ mix, which encodes some
#        continuous surround sound information into stereo output that can be
#        decoded with a surround sound receiver.
#  tsme - Creates a stereo-compatible two-channel surround matrix encoded mix,
#         which encodes some discrete surround sound and height information
#         into the stereo output that can be decoded with a surround sound
#         receiver.
#  hrtf - Uses filters to provide better spatialization of sounds while using
#         stereo headphones.
#  If crossfeed filters are used, basic stereo mixing is used.
stereo-encoding = $STEREO_ENCODING

## hrtf-mode:
#  Specifies the rendering mode for HRTF processing. Setting the mode to full
#  (default) applies a unique HRIR filter to each source given its relative
#  location, providing the clearest directional response at the cost of the
#  highest CPU usage. Setting the mode to ambi1, ambi2, ambi3, or ambi4 will
#  instead mix to an ambisonic buffer of the given order, then decode that
#  buffer with HRTF filters. Ambi1 has the lowest CPU usage, replacing the per-
#  source HRIR filter for a simple 4-channel panning mix, but retains full 3D
#  placement at the cost of a more diffuse response. Higher ambisonic orders
#  increasingly improve the directional clarity, at the cost of more CPU usage
#  (still less than "full", given some number of active sources).
${HRTF_MODE_PREFIX}hrtf-mode = $HRTF_MODE

## hrtf-paths:
#  Specifies a comma-separated list of paths containing HRTF data sets. The
#  format of the files are described in docs/hrtf.txt. The files within the
#  directories must have the .mhr file extension to be recognized. By default,
#  OS-dependent data paths will be used. They will also be used if the list
#  ends with a comma. On Windows this is:
#  \$AppData\openal\hrtf
#  And on other systems, it's (in order):
#  \$XDG_DATA_HOME/openal/hrtf  (defaults to \$HOME/.local/share/openal/hrtf)
#  \$XDG_DATA_DIRS/openal/hrtf  (defaults to /usr/local/share/openal/hrtf and
#                               /usr/share/openal/hrtf)
hrtf-paths = HRTF, OpenAL/HRTF

## period_size:
#  Sets the update period size, in sample frames. This is the number of frames
#  needed for each mixing update. Acceptable values range between 64 and 8192.
#  If left unspecified it will default to 512 sample frames (~10.7ms).
period_size = 1024

## periods:
#  Sets the number of update periods. Higher values create a larger mix ahead,
#  which helps protect against skips when the CPU is under load, but increases
#  the delay between a sound getting mixed and being heard. Acceptable values
#  range between 2 and 16.
periods = 3

## resampler: (global)
#  Selects the default resampler used when mixing sources. Valid values are:
#  point - nearest sample, no interpolation
#  linear - extrapolates samples using a linear slope between samples
#  spline - extrapolates samples using a Catmull-Rom spline
#  gaussian - extrapolates samples using a 4-point Gaussian filter
#  bsinc12 - extrapolates samples using a band-limited Sinc filter (varying
#            between 12 and 24 points, with anti-aliasing)
#  fast_bsinc12 - same as bsinc12, except without interpolation between down-
#                 sampling scales
#  bsinc24 - extrapolates samples using a band-limited Sinc filter (varying
#            between 24 and 48 points, with anti-aliasing)
#  fast_bsinc24 - same as bsinc24, except without interpolation between down-
#                 sampling scales
#  bsinc48 - extrapolates samples using a band-limited Sinc filter (48 points,
#            with anti-aliasing)
#  fast_bsinc48 - same as bsinc48, except without interpolation between down-
#                 sampling scales
resampler = spline

## default-reverb: (global)
#  A reverb preset that applies by default to all sources on send 0
#  (applications that set their own slots on send 0 will override this).
#  Available presets include: None, Generic, PaddedCell, Room, Bathroom,
#  Livingroom, Stoneroom, Auditorium, ConcertHall, Cave, Arena, Hangar,
#  CarpetedHallway, Hallway, StoneCorridor, Alley, Forest, City, Mountains,
#  Quarry, Plain, ParkingLot, SewerPipe, Underwater, Drugged, Dizzy, Psychotic.
default-reverb = Generic
EOF
            if [[ "$ADVANCED_LIMITS" =~ $YES_RE ]]; then
                cat <<'EOF'

# Advanced Audio Limit Expansion

## sources:
#  Sets the maximum number of allocatable sources. Lower values may help for
#  systems with apps that try to play more sounds than the CPU can handle.
sources = 256

## frequency:
#  Sets the default output frequency. If left unspecified it will try to detect
#  a default from the system, otherwise it will fallback to 48000.
frequency = 48000
EOF
            fi
            if [ "$OUTPUT_MODE" == "surround" ]; then
                cat <<'EOF'

[decoder]

## hq-mode:
#  Enables a high-quality ambisonic decoder. This mode is capable of frequency-
#  dependent processing, creating a better reproduction of 3D sound rendering
#  over surround sound speakers.
hq-mode = true
EOF
            fi
            cat <<'EOF'

[reverb]

## boost: (global)
#  A global amplification for reverb output, expressed in decibels. The value
#  is logarithmic, so +6 will be a scale of (approximately) 2x, +12 will be a
#  scale of 4x, etc. Similarly, -6 will be about half, and -12 about 1/4th. A
#  value of 0 means no change.
boost = 0

[eax]

## enable: (global)
#  Sets whether to enable EAX extensions or not.
enable = true
EOF
        } > "$GAME_DIR/alsoft.ini"

        if [ -s "$GAME_DIR/alsoft.ini" ]; then
            echo "$GAME_DIR/alsoft.ini" >> "$INSTALL_MANIFEST"
            if [[ "$ADVANCED_LIMITS" =~ $YES_RE ]]; then print_status "Generated: Advanced alsoft.ini with expanded channel limits"
            else print_status "Generated: Linux-optimised alsoft.ini"; fi
            apply_alsoft_overrides
            # Copied after the overrides so every exe gets the same settings.
            for deploy_dir in "${EXTRA_GAME_DIRS[@]}"; do
                if handle_conflict "$deploy_dir/alsoft.ini"; then
                    deploy_copy "$GAME_DIR/alsoft.ini" "$deploy_dir/alsoft.ini" "Copied"
                fi
            done
        else
            record_deploy_failure "$GAME_DIR/alsoft.ini"
        fi
    fi

    if [[ "$ADVANCED_COM" =~ $YES_RE ]] || [ "$OVERRIDE_METHOD" == "registry" ]; then
        reg_com="n"; reg_override="n"
        [[ "$ADVANCED_COM" =~ $YES_RE ]] && reg_com="y"
        [ "$OVERRIDE_METHOD" == "registry" ] && reg_override="y"
        apply_prefix_registry "$reg_com" "$reg_override"
        # Show the manual WINEDLLOVERRIDES instructions below instead of
        # claiming the override was handled automatically.
        if [ "$REG_STATUS" != "ok" ] && [ "$reg_override" == "y" ]; then
            OVERRIDE_PATCH_FAILED="1"
            OVERRIDE_METHOD="manual"
        fi
    fi

    # Companion apps (DOOM 3's Resurrection of Evil): the same prefix steps in
    # each one's own prefix. Their launch options are set with the game's
    # below, so the launcher is only closed once.
    for i in "${!COMPANION_IDS[@]}"; do
        [ "${COMPANION_VCRUN[$i]:-}" == "install" ] && with_companion "$i" install_companion_vcrun "$i"
        print_phase_task "Setting up ${COMPANION_NAMES[$i]}'s Proton prefix"
        with_companion "$i" install_companion_prefix "$i"
    done

    # Step 10's launcher choice: Steam launch options / Heroic environment
    # variables. Drops back to manual instructions if it can't be written.
    apply_launcher_override

    # Always runs, even with nothing new to apply: it also carries last
    # install's still-active game settings over into the new manifest.
    apply_game_settings

    end_phase_progress
    print_run_summary

    if [ "${DEPLOY_FAILURES:-0}" -gt 0 ]; then
        print_banner "INSTALLATION INCOMPLETE" "$YELLOW"
        print_error "$DEPLOY_FAILURES step(s) failed (see the errors above), so the EAX fix" \
            "is NOT fully installed. The game may run without it or fail to start."
        print_paragraph "Fix the cause (usually a read-only drive or folder permissions), then run the" \
            "script again, or choose (u)ninstall to remove what was deployed."
        if [ -n "${OVERRIDE_PATCH_FAILED:-}" ]; then
            print_paragraph "Until then, you can set the DLL override by hand:" \
                "  $( [ "$LAUNCHER_TYPE" == "1" ] && echo "Steam Launch Options: WINEDLLOVERRIDES=\"${PRIMARY_DLL_NAME}=n,b\" %command%" || echo "Heroic Environment Variable: WINEDLLOVERRIDES = ${PRIMARY_DLL_NAME}=n,b" )"
        fi
        exit 1
    fi

    print_banner "INSTALLATION COMPLETE!"

    if [ "$OVERRIDE_METHOD" == "registry" ] || [ "$OVERRIDE_METHOD" == "launcher" ]; then
        override_where="the $(runner_label) prefix registry"
        [ "$OVERRIDE_METHOD" == "launcher" ] && override_where="$(launcher_override_where)"
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}The DLL Override is set in $(tilde_path "$override_where"), so just hit Play.${NC}"
        print_companion_final_steps
        # The game profile's audio settings already switched EAX on in the
        # game's own settings, so there's nothing left to do in its menus.
        game_audio_settings_done \
            || echo -e " 2. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}"
    else
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Set the Override:${NC} ${WHITE}Apply the WINEDLLOVERRIDES rule (see below).${NC}"
        print_companion_final_steps
        echo -e " 2. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}Start the game as you normally would.${NC}"
        game_audio_settings_done \
            || echo -e " 3. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}"
        echo ""

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
    # Each block below brings its own leading blank line (the game settings
    # summary, then the run log's "Log saved to:"), so none is added here.
    print_game_settings_summary
    print_community_patches_summary
fi

# An install Tools → Probe game settings handed off to: back to its second
# run (probe_after_install exits when it's done).
[ -n "$PROBE_PENDING" ] && probe_after_install

# Closes the main-menu loop opened above the main menu in vcrun-only-flow.sh.
break
done
