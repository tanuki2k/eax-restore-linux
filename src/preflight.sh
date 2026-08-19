# ==============================================================================
# SCRIPT START
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Soft Universal Installer                ${NC}"
echo -e "${CYAN}${BOLD}   v${SCRIPT_VERSION}  (${SCRIPT_DATE})${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- PRE-FLIGHT SYSTEM CHECK ---${NC}"
print_line

EAX_RESTORE_SKIP_PREFLIGHT="${EAX_RESTORE_SKIP_PREFLIGHT:-}"
if is_truthy "$EAX_RESTORE_SKIP_PREFLIGHT"; then
    echo -e "\n${NOTE}Note: EAX_RESTORE_SKIP_PREFLIGHT is set — skipping the tool scan and trusting that curl,"
    echo -e "unzip, file, protontricks, winetricks, wine, and jq are already available.${NC}"

    # Still needed by the rest of the script, just done quietly: the
    # protontricks Flatpak fallback function, and WINE_CMD.
    if ! command -v protontricks &> /dev/null && flatpak info com.github.Matoking.protontricks &> /dev/null; then
        protontricks() { flatpak run com.github.Matoking.protontricks "$@"; }
    fi
    WINE_CMD="wine"
    command -v wine &> /dev/null || WINE_CMD=$(find_local_wine)
else
    echo -e "\n${CYAN}Verifying required base tools before accessing cache...${NC}\n"

    REQUIRED_BASE_PKGS=("curl" "unzip" "file" "grep" "awk")
    MISSING_BASE_PKGS=()

    for pkg in "${REQUIRED_BASE_PKGS[@]}"; do
        echo -n -e " -> Checking for ${YELLOW}$pkg${NC}... "
        if command -v "$pkg" &> /dev/null; then echo -e "${GREEN}FOUND${NC}"; else echo -e "${YELLOW}${BOLD}MISSING${NC}"; MISSING_BASE_PKGS+=("$pkg"); fi
    done

    echo -n -e " -> Checking for ${YELLOW}protontricks${NC}... "
    if command -v protontricks &> /dev/null; then
        echo -e "${GREEN}FOUND${NC}"
    else
        if flatpak info com.github.Matoking.protontricks &> /dev/null; then
            echo -e "${GREEN}FOUND (Flatpak)${NC}"
            protontricks() { flatpak run com.github.Matoking.protontricks "$@"; }
        else
            echo -e "${YELLOW}MISSING (Required for Steam games)${NC}"
            MISSING_BASE_PKGS+=("protontricks")
        fi
    fi

    echo -n -e " -> Checking for ${YELLOW}winetricks${NC}... "
    if command -v winetricks &> /dev/null; then echo -e "${GREEN}FOUND${NC}"
    else echo -e "${YELLOW}MISSING (Required for Heroic/GOG games)${NC}"; MISSING_BASE_PKGS+=("winetricks"); fi

    echo -n -e " -> Checking for ${YELLOW}wine binary${NC}... "
    WINE_CMD="wine"
    if command -v wine &> /dev/null; then
        echo -e "${GREEN}FOUND (System)${NC}"
    else
        WINE_CMD=$(find_local_wine)
        if [ -n "$WINE_CMD" ]; then echo -e "${GREEN}FOUND (Local Heroic)${NC}"
        else echo -e "${YELLOW}MISSING (Registry patches for non-Steam games will be skipped)${NC}"; WINE_CMD=""; fi
    fi

    echo -n -e " -> Checking for ${YELLOW}jq${NC}... "
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}FOUND${NC}"
    else
        echo -e "${YELLOW}MISSING (required for checksum verification and the known-EAX-games database)${NC}"
        MISSING_BASE_PKGS+=("jq")
    fi

    if [ ${#MISSING_BASE_PKGS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}${BOLD}Error: the script is missing essential tools to function: ${MISSING_BASE_PKGS[*]}${NC}"
        if grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
            echo -e "\n${YELLOW}SteamOS detected. To protect your immutable filesystem, please install missing tools via the Discover software centre.${NC}"
            echo -e "${YELLOW}${BOLD}Cannot proceed without base dependencies. Exiting.${NC}"; exit 1
        else
            echo -e -n "\n${YELLOW}Auto-install these dependencies now? (Requires sudo) (Y/n): ${NC}"
            read -r AUTO_INSTALL_BASE
            if [[ ! "$AUTO_INSTALL_BASE" =~ $NO_RE ]]; then
                echo -e "\n${CYAN}STATUS: Installing missing packages...${NC}"
                source /etc/os-release
                OS_FLAVOR="${ID_LIKE:-$ID}"
                case "$OS_FLAVOR" in
                    *debian*|*ubuntu*) sudo apt-get update && sudo apt-get install -y "${MISSING_BASE_PKGS[@]}" ;;
                    *arch*) sudo pacman -Sy --noconfirm "${MISSING_BASE_PKGS[@]}" ;;
                    *fedora*) sudo dnf install -y "${MISSING_BASE_PKGS[@]}" ;;
                    *) echo -e "\n${YELLOW}${BOLD}Error: manual install required: ${MISSING_BASE_PKGS[*]}${NC}"; exit 1 ;;
                esac
                echo -e " -> ${GREEN}Dependencies installed successfully.${NC}"
            else echo -e "\n${YELLOW}${BOLD}Cannot proceed without base dependencies. Exiting.${NC}"; exit 1; fi
        fi
    else echo -e "\n${GREEN}All base requirements met.${NC}"; fi
fi
