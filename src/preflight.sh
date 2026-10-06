# ==============================================================================
# SCRIPT START
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Soft Universal Installer                ${NC}"
echo -e "${CYAN}${BOLD}   v${SCRIPT_VERSION}  (${SCRIPT_DATE})${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"

print_banner "PRE-FLIGHT SYSTEM CHECK"

EAX_RESTORE_SKIP_PREFLIGHT="${EAX_RESTORE_SKIP_PREFLIGHT:-}"
if is_truthy "$EAX_RESTORE_SKIP_PREFLIGHT"; then
    print_note "EAX_RESTORE_SKIP_PREFLIGHT is set — skipping the tool scan and trusting that curl," \
        "unzip, file, protontricks, winetricks, wine, and jq are already available."

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
        echo -e "${YELLOW}MISSING (required for checksum verification and the game database)${NC}"
        MISSING_BASE_PKGS+=("jq")
    fi

    if [ ${#MISSING_BASE_PKGS[@]} -gt 0 ]; then
        print_error "this script needs a few tools that aren't installed yet: ${MISSING_BASE_PKGS[*]}"
        if is_steamos; then
            print_warning "SteamOS detected. To protect your immutable filesystem, please install missing" \
                "tools via the Discover software centre."
            print_error "Cannot proceed without base dependencies. Exiting."; exit 1
        else
            if confirm "Auto-install these dependencies now? (Requires sudo)"; then
                install_packages "${MISSING_BASE_PKGS[@]}" \
                    || { print_error "Cannot proceed without base dependencies. Exiting."; exit 1; }
                print_status "Dependencies installed successfully." "$GREEN"
            else print_error "Cannot proceed without base dependencies. Exiting."; exit 1; fi
        fi
    else print_status "All base requirements met." "$GREEN"; fi
fi

# Fetched once here, before the main menu, so its status line doesn't show
# up partway through a step, and the menus can leave out what needs it when
# it's missing (GAME_DATABASE_FILE stays empty). Every later call reuses this
# result.
ensure_game_database
