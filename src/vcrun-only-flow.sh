# ==============================================================================
# STANDALONE VC++ RUNTIME INSTALL
# ==============================================================================
# Set EAX_RESTORE_VCRUN_ONLY=1 to skip everything else and just (re)install the
# MS VC++ 2022 Redistributable into a game's prefix — e.g. if you skipped it
# during a normal install and want to go back for it without redoing the rest.
EAX_RESTORE_VCRUN_ONLY="${EAX_RESTORE_VCRUN_ONLY:-}"
if is_truthy "$EAX_RESTORE_VCRUN_ONLY"; then
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- VC++ RUNTIME ONLY MODE ---${NC}"
    print_line
    echo -e "\n${WHITE}EAX_RESTORE_VCRUN_ONLY is set, so this run will only install the MS VC++ 2022"
    echo -e "Redistributable into a game's prefix — nothing else the script normally does (DSOAL,"
    echo -e "OpenAL Soft, alsoft.ini, registry overrides) will be touched.${NC}"
    echo -e "\n${WHITE}Unset EAX_RESTORE_VCRUN_ONLY to return to the normal install/uninstall flow.${NC}"

    SCRIPT_ACTION="i"

    echo ""
    print_divider
    echo -e "${CYAN}1. Game Location${NC}"
    print_line
    echo ""
    get_game_directory ""

    echo ""
    print_divider
    echo -e "${CYAN}2. Launcher Identification${NC}"
    print_line
    echo ""
    detect_game_environment

    select_architecture

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- READY ---${NC}"
    print_line
    echo -e "\n${WHITE}This will attempt to install the MS VC++ 2022 Redistributable into:${NC}"
    [ "$LAUNCHER_TYPE" == "1" ] && echo -e "${WHITE} -> Steam AppID: ${BOLD}$APPID${NC}"
    [ -n "$PREFIX_PATH" ] && echo -e "${WHITE} -> Prefix: ${BOLD}$PREFIX_PATH${NC}"
    echo -e "\n${YELLOW}Proceed? (Y/n): ${NC}"
    echo -e -n "> "
    read -r CONFIRM_VCRUN_ONLY
    if [[ "$CONFIRM_VCRUN_ONLY" =~ $NO_RE ]]; then
        echo -e "\n${YELLOW}Aborted. No changes made.${NC}"
        exit 0
    fi

    if install_vcrun_dependencies; then
        GAME_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
        if [ -f "$GAME_MANIFEST" ] && head -n 1 "$GAME_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
            # A stale "already uninstalled" sentinel would otherwise make a
            # future uninstall run stop before ever reading this marker.
            : > "$GAME_MANIFEST"
        fi
        echo "VCRUN" >> "$GAME_MANIFEST"
    fi

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- VC++ RUNTIME INSTALL COMPLETE ---${NC}"
    print_line
    echo ""
    exit 0
fi

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- SELECT OPERATION ---${NC}"
print_line

if is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13" || is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14" || is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL"; then
    SCRIPT_ACTION="i"
    echo -e "\n${GREEN}An EAX_RESTORE_DSOAL_* variable is set, so proceeding straight to install.${NC}"
else
    while true; do
        echo -e "\n${YELLOW}Would you like to (i)nstall or (u)ninstall the EAX audio fix? (i/u): ${NC}"
        echo -e -n "> "
        read -r SCRIPT_ACTION
        SCRIPT_ACTION="${SCRIPT_ACTION,,}"
        if [[ "$SCRIPT_ACTION" == "i" || "$SCRIPT_ACTION" == "u" ]]; then break
        else echo -e "\n${YELLOW}${BOLD}Invalid selection. Please type 'i' or 'u'.${NC}"; fi
    done
fi
