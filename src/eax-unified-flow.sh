# ==============================================================================
# EAX UNIFIED INSTALL (Tools → [E]AX Unified)
# ==============================================================================
# Installs Creative's EAX Unified into one game's prefix on its own, for a game
# that asks Windows for eax.dll. The install offers the same thing in Phase 1;
# this is for a game that is already set up. Like the VC++ tool it works on a
# game with no manifest, and it records an EAXUNIFIED line so uninstall removes
# it again.
if [ -n "$EAX_UNIFIED_MODE" ]; then
    print_banner "EAX UNIFIED"
    tool_gate "This installs Creative's EAX Unified into a game's prefix, for games that look for" \
        "Creative's eax.dll. Nothing else in the prefix or the game folder is changed." \
        || { OPEN_TOOLS_MENU=1; continue; }

    SCRIPT_ACTION="i"
    STEP_TOTAL=2

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

    if eax_unified_dll > /dev/null; then
        print_note "EAX Unified is already in ${GAME_NAME}'s prefix, so there's nothing to install."
        OPEN_TOOLS_MENU=1; continue
    fi

    print_banner "READY"
    if game_ships_eax_dll; then
        print_note "${GAME_NAME} has its own eax.dll in its game folder, so it may not need EAX Unified."
    fi
    [ "$LAUNCHER_TYPE" == "1" ] && echo -e "${WHITE} -> Steam AppID: ${BOLD}$APPID${NC}"
    [ -n "$PREFIX_PATH" ] && echo -e "${WHITE} -> Prefix: ${BOLD}$(tilde_path "$PREFIX_PATH")${NC}"
    if ! confirm "Install Creative's EAX Unified into ${GAME_NAME}'s prefix?"; then
        print_result "Cancelled — no changes were made." "$YELLOW"
        OPEN_TOOLS_MENU=1; continue
    fi

    eax_unified_status=0
    install_eax_unified || eax_unified_status=$?
    if [ "$eax_unified_status" -eq 0 ]; then
        GAME_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
        if [ ! -s "$GAME_MANIFEST" ] || manifest_is_uninstalled "$GAME_MANIFEST"; then
            # A new manifest, or a stale "already uninstalled" sentinel, which
            # would otherwise make a future uninstall stop before reading this.
            start_manifest "$GAME_MANIFEST"
        fi
        grep -qx "EAXUNIFIED" "$GAME_MANIFEST" || echo "EAXUNIFIED" >> "$GAME_MANIFEST"
        print_run_summary
        print_banner "EAX UNIFIED INSTALL COMPLETE"
        exit 0
    fi

    print_run_summary
    print_banner "EAX UNIFIED INSTALL INCOMPLETE" "$YELLOW"
    print_error "Creative's EAX Unified didn't install, so it isn't in ${GAME_NAME}'s prefix." \
        "Its output is saved in $(tilde_path "$EAX_UNIFIED_SHARE")/install.log."
    exit 1
fi

