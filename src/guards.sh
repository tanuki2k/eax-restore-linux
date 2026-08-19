# ==============================================================================
# GUARDS (ROOT & GAMING MODE)
# ==============================================================================
if [ "$EUID" -eq 0 ]; then
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}--- ERROR: ROOT PRIVILEGES DETECTED ---${NC}"
    print_line
    echo -e "${WHITE}Running Wine or Protontricks as root will permanently break your prefix permissions.${NC}"
    echo -e "${WHITE}Run the script normally. It will ask for sudo only if installing system tools.${NC}"
    exit 1
fi

if [ -n "$SteamEnv" ] || [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}--- ERROR: GAMING MODE DETECTED ---${NC}"
    print_line
    echo -e "${WHITE}This script requires keyboard input and terminal interaction.${NC}"
    echo -e "${WHITE}Please switch to Desktop Mode and run this script via Konsole or your preferred terminal.${NC}"
    exit 1
fi
