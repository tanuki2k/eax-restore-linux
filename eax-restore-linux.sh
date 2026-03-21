#!/usr/bin/env bash

# ==============================================================================
# DSOAL & OpenAL Soft Universal Installer for Linux
# ==============================================================================
#
# A streamlined Bash script designed to automate the restoration of EAX 3D
# audio in older Windows games running on Linux via Steam or Heroic.
#
# --- Features ---
# * Full Stack: Links DSOAL and OpenAL Soft directly to the game.
# * Engine Choice: Toggle between bundled DSOAL driver or latest OpenAL Soft.
# * Two-Action Menu: Install or Uninstall.
# * Smart Detection: Auto-detects Steam/GOG based on path, auto-finds AppID.
# * Bulletproof: Validates paths, pauses for missing prefixes politely.
# * Centralized Caching: Automatically downloads files to ~/.local/share.
#
# --- License ---
# MIT License
# Copyright (c) 2026 Benjamin van Houts
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
DSOAL_SHARE="$HOME/.local/share/dsoal"
DSOAL_EXTRACT="$DSOAL_SHARE/extracted"
URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
API_URL="https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master"

OPENAL_SHARE="$HOME/.local/share/openal-soft"
OPENAL_EXTRACT="$OPENAL_SHARE/extracted"

# ==============================================================================
# FUNCTION: UPDATE LOCAL CACHE
# ==============================================================================
update_local_cache() {
    echo -e "\n${CYAN}--- CHECKING CACHE (DSOAL & OPENAL SOFT) ---${NC}"
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"

    # --- 1. Fetch DSOAL ---
    LATEST_DATE=$(curl -s "$API_URL" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)

    if [ -z "$LATEST_DATE" ]; then
        if [ -d "$DSOAL_EXTRACT" ]; then
            echo -e "${YELLOW}Could not reach GitHub API for DSOAL. Using cached files.${NC}"
        else
            echo -e "${RED}Error: Could not reach GitHub and no local DSOAL cache exists.${NC}"
            exit 1
        fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_EXTRACT" ]; then
        echo -e "${CYAN}Downloading latest DSOAL...${NC}"
        rm -rf "$DSOAL_EXTRACT"
        mkdir -p "$DSOAL_EXTRACT"

        if curl -L -# "$URL" -o "$DSOAL_SHARE/dsoal.zip"; then
            unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_EXTRACT"
            NESTED=$(find "$DSOAL_EXTRACT" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
            if [ -n "$NESTED" ]; then
                unzip -q "$NESTED" -d "$DSOAL_EXTRACT"
            fi
            echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"
            rm -f "$DSOAL_SHARE/dsoal.zip"
            echo -e "${GREEN}DSOAL cache updated!${NC}"
        else
            echo -e "${RED}Error: DSOAL Download failed.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}DSOAL cache is ready.${NC}"
    fi

    # --- 2. Fetch OpenAL Soft ---
    OAL_TAG=$(curl -sI https://github.com/kcat/openal-soft/releases/latest | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
    LOCAL_OAL_TAG=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)

    if [ -z "$OAL_TAG" ]; then
         if [ -d "$OPENAL_EXTRACT" ]; then
            echo -e "${YELLOW}Could not fetch OpenAL Soft tag. Using cached files.${NC}"
         else
            echo -e "${RED}Error: Could not fetch OpenAL Soft and no cache exists.${NC}"
            exit 1
         fi
    elif [ "$OAL_TAG" != "$LOCAL_OAL_TAG" ] || [ ! -d "$OPENAL_EXTRACT" ]; then
        echo -e "${CYAN}Downloading latest OpenAL Soft (${OAL_TAG})...${NC}"
        OAL_URL="https://github.com/kcat/openal-soft/releases/download/${OAL_TAG}/openal-soft-${OAL_TAG}-bin.zip"

        rm -rf "$OPENAL_EXTRACT"
        mkdir -p "$OPENAL_EXTRACT"

        if curl -L -# "$OAL_URL" -o "$OPENAL_SHARE/openal.zip"; then
            unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_EXTRACT"
            echo "$OAL_TAG" > "$OPENAL_SHARE/updated_at.txt"
            rm -f "$OPENAL_SHARE/openal.zip"
            echo -e "${GREEN}OpenAL Soft cache updated!${NC}"
        else
            echo -e "${RED}Error: OpenAL Soft Download failed.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}OpenAL Soft cache is ready.${NC}"
    fi
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Soft Universal Installer                ${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}\n"

echo -e "${GREEN}${BOLD}--- MAIN MENU ---${NC}"
echo "1) Install EAX Fix for a game"
echo "2) Uninstall EAX Fix from a game folder"

while true; do
    echo -e -n "${YELLOW}Selection (1 or 2): ${NC}"
    read -r SCRIPT_ACTION
    if [[ "$SCRIPT_ACTION" == "1" || "$SCRIPT_ACTION" == "2" ]]; then
        break
    else
        echo -e "${RED}Invalid selection. Please type 1 or 2.${NC}"
    fi
done

# ==============================================================================
# ACTION 2: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "2" ]; then
    echo -e "\n${CYAN}--- UNINSTALL EAX FIX ---${NC}"

    while true; do
        echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
        echo -e -n "> "
        read -r GAME_DIR
        GAME_DIR="${GAME_DIR/#\~/$HOME}"
        GAME_DIR="${GAME_DIR%/}"

        if [ -d "$GAME_DIR" ]; then
            break
        else
            echo -e "${RED}Error: Directory not found. Please check the path and try again.${NC}"
        fi
    done

    FILES_TO_REMOVE=()
    [ -L "$GAME_DIR/dsound.dll" ] || [ -f "$GAME_DIR/dsound.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsound.dll")
    [ -L "$GAME_DIR/dsoal-aldrv.dll" ] || [ -f "$GAME_DIR/dsoal-aldrv.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsoal-aldrv.dll")
    [ -f "$GAME_DIR/alsoft.ini" ] && FILES_TO_REMOVE+=("$GAME_DIR/alsoft.ini")

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ]; then
        echo -e "${YELLOW}No EAX files found in $GAME_DIR.${NC}"; exit 0
    fi

    echo -e "\n${RED}${BOLD}The following files will be removed:${NC}"
    for f in "${FILES_TO_REMOVE[@]}"; do echo " - $f"; done
    echo -e -n "\n${YELLOW}Proceed with removal? (Y/n): ${NC}"
    read -r CONFIRM_UNINSTALL

    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Nn]$ ]]; then
        for f in "${FILES_TO_REMOVE[@]}"; do rm -f "$f"; done
        echo -e "${GREEN}EAX Fix removed from $GAME_DIR${NC}"
    fi
    exit 0
fi

# ==============================================================================
# ACTION 1: INSTALL (PHASE 1: GATHERING)
# ==============================================================================
if [ "$SCRIPT_ACTION" == "1" ]; then
    echo -e "\n${GREEN}${BOLD}--- INITIALIZING ---${NC}"

    update_local_cache

    echo -e "\n${GREEN}${BOLD}--- PHASE 1: CONFIGURATION ---${NC}"

    # 1. Game Location
    echo -e "\n${CYAN}1. Game Location${NC}"
    while true; do
        echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
        echo -e -n "> "
        read -r GAME_DIR
        GAME_DIR="${GAME_DIR/#\~/$HOME}"
        GAME_DIR="${GAME_DIR%/}"

        if [ -d "$GAME_DIR" ]; then
            break
        else
            echo -e "${RED}Error: Directory not found. Please check the path and try again.${NC}"
        fi
    done

    # 2. Game Identification & Launcher Auto-Detect
    echo -e "\n${CYAN}2. Game Identification${NC}"
    if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
        LAUNCHER_TYPE="1"
        echo -e "${GREEN}Steam installation detected!${NC}"

        STEAMAPPS_DIR="${GAME_DIR%/common/*}"
        INSTALL_DIR_TEMP="${GAME_DIR#*/common/}"
        INSTALL_DIR="${INSTALL_DIR_TEMP%%/*}"
        APPID=""

        # Outer Loop for AppID assignment
        while true; do
            # Try Auto-Detect First
            if [ -z "$APPID" ]; then
                MANIFEST_FILE=$(grep -il "\"installdir\"\s*\"$INSTALL_DIR\"" "$STEAMAPPS_DIR"/appmanifest_*.acf 2>/dev/null | head -n 1)

                if [ -n "$MANIFEST_FILE" ]; then
                    AUTO_APPID=$(basename "$MANIFEST_FILE" | tr -dc '0-9')
                    echo -e "${GREEN}Auto-detected Steam AppID: ${BOLD}$AUTO_APPID${NC} (Folder: $INSTALL_DIR)"
                    echo -e -n "${YELLOW}Use this AppID? (Y/n): ${NC}"
                    read -r CONFIRM_APPID
                    if [[ ! "$CONFIRM_APPID" =~ ^[Nn]$ ]]; then
                        APPID="$AUTO_APPID"
                    fi
                fi

                # Manual entry fallback
                if [ -z "$APPID" ]; then
                    echo -e -n "${YELLOW}Please enter the Steam AppID manually: ${NC}"
                    read -r APPID
                fi
            fi

            # Inner Loop for Prefix Verification (Pause and Wait Logic)
            echo -e "${CYAN}Verifying Wine Prefix for AppID ${APPID}...${NC}"
            while true; do
                PREFIX_PATH=$(protontricks -c 'echo $WINEPREFIX' "$APPID" 2>/dev/null | grep "/pfx" | tail -n 1 | tr -d '\r')

                if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH" ]; then
                    echo -e "${GREEN}Prefix verified!${NC}"
                    break 2 # Breaks out of both the Prefix Loop AND the AppID Loop
                else
                    echo -e "\n${CYAN}${BOLD}╭────────────────────────────────────────────────────────╮${NC}"
                    echo -e "${CYAN}${BOLD}│       WAIT! LET'S GET PROTON READY TO GO FIRST         │${NC}"
                    echo -e "${CYAN}${BOLD}╰────────────────────────────────────────────────────────╯${NC}"
                    echo -e "${YELLOW}${BOLD}It looks like Steam hasn't created the Proton prefix for AppID ${APPID} yet.${NC}"
                    echo -e "${YELLOW}No worries! This is an easy fix. Just follow these steps:${NC}\n"
                    echo -e "${WHITE}${BOLD}  1.${NC} ${YELLOW}Leave this script open right here.${NC}"
                    echo -e "${WHITE}${BOLD}  2.${NC} ${YELLOW}Go to Steam and click 'Play' on your game.${NC}"
                    echo -e "${WHITE}${BOLD}  3.${NC} ${YELLOW}Let it load up to the main menu, and then just quit back out.${NC}\n"
                    echo -e "${GREEN}${BOLD}This forces Steam to build the folders we need!${NC}"
                    echo -e -n "\n${CYAN}${BOLD}Press [ENTER] when you are ready to check again${NC} ${CYAN}(or type 'n' to enter a different AppID): ${NC}"
                    read -r PREFIX_RETRY

                    if [[ "${PREFIX_RETRY,,}" == "n" || "${PREFIX_RETRY,,}" == "no" ]]; then
                        APPID=""
                        break # Breaks out of the Prefix loop, sends you back to type a new AppID
                    fi
                    echo -e "\n${CYAN}Re-checking prefix...${NC}"
                fi
            done
        done

    else
        LAUNCHER_TYPE="2"
        echo -e "${GREEN}Non-Steam (GOG/Heroic) installation detected!${NC}"

        while true; do
            echo -e -n "${YELLOW}Paste the Wine Prefix path (e.g. ~/Games/Heroic/Prefixes/default/Game): ${NC}"
            read -r PREFIX_PATH
            PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
            PREFIX_PATH="${PREFIX_PATH%/}"

            if [ -d "$PREFIX_PATH" ]; then
                break
            else
                echo -e "${RED}Error: Prefix folder not found. Please try again.${NC}"
            fi
        done
    fi

    # 3. Engine Selection
    echo -e "\n${CYAN}3. Audio Engine Selection${NC}"
    echo "1) Bundled DSOAL Driver (Stable/Legacy - Best for older games)"
    echo "2) Latest OpenAL Soft Engine (Modern/Updated - Best for modern HRTF)"

    while true; do
        echo -e -n "${YELLOW}Selection (1 or 2): ${NC}"
        read -r ENGINE_CHOICE
        if [[ "$ENGINE_CHOICE" == "1" || "$ENGINE_CHOICE" == "2" ]]; then
            break
        else
            echo -e "${RED}Invalid selection. Please type 1 or 2.${NC}"
        fi
    done

    # 4. Audio Configuration
    echo -e "\n${CYAN}4. Audio Configuration${NC}"
    echo -e -n "${YELLOW}Do you want to enable HRTF? (Y/n): ${NC}"
    read -r ENABLE_HRTF
    BASE_FOLDER=$([[ "$ENABLE_HRTF" =~ ^[Nn]$ ]] && echo "DSOAL" || echo "DSOAL+HRTF")

    # 5. Dependency Check
    echo -e "\n${CYAN}5. System Check${NC}"
    REQUIRED_PKGS=("curl" "unzip" "file")
    [[ "$LAUNCHER_TYPE" == "1" ]] && REQUIRED_PKGS+=("protontricks") || REQUIRED_PKGS+=("winetricks")
    MISSING_PKGS=()
    for pkg in "${REQUIRED_PKGS[@]}"; do [[ ! $(command -v "$pkg") ]] && MISSING_PKGS+=("$pkg"); done

    AUTO_INSTALL="n"
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo -e "${YELLOW}Missing required tools: ${MISSING_PKGS[*]}${NC}"
        echo -e -n "${YELLOW}Auto-install dependencies? (Requires sudo) (y/N): ${NC}"
        read -r AUTO_INSTALL
    fi

    # 6. Architecture Scan
    echo -e "\n${CYAN}6. Architecture Selection${NC}"
    ARCH="MANUAL"
    if command -v file &> /dev/null; then
        echo -e -n "${YELLOW}Attempt to auto-detect 32/64 bit? (Y/n): ${NC}"
        read -r AUTO_DETECT
        if [[ ! "$AUTO_DETECT" =~ ^[Nn]$ ]]; then
            A32=0; A64=0
            while IFS= read -r -d '' exe; do
                [[ $(file "$exe") == *"PE32+"* ]] && ((A64++)) || ((A32++))
            done < <(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" -print0)

            DETECTED=$([[ $A64 -gt 0 && $A32 -eq 0 ]] && echo "64" || [[ $A32 -gt 0 && $A64 -eq 0 ]] && echo "32" || echo "UNKNOWN")
            if [ "$DETECTED" != "UNKNOWN" ]; then
                echo -e -n "${GREEN}Detected ${DETECTED}-bit. Correct? (Y/n): ${NC}"
                read -r CONF; [[ ! "$CONF" =~ ^[Nn]$ ]] && ARCH="$DETECTED"
            fi
        fi
    fi
    [ "$ARCH" == "MANUAL" ] && { echo -n -e "${YELLOW}Architecture (32/64): ${NC}"; read -r ARCH; }
    ARCH_FOLDER=$([ "$ARCH" == "64" ] && echo "Win64" || echo "Win32")

    # ==============================================================================
    # PHASE 2: EXECUTION
    # ==============================================================================
    echo -e "\n${YELLOW}${BOLD}==========================================================${NC}"
    echo -e "${YELLOW}${BOLD}   READY FOR FINAL DEPLOYMENT                             ${NC}"
    echo -e "${YELLOW}${BOLD}==========================================================${NC}"
    echo -e -n "${RED}${BOLD}>>> PRESS [ENTER] TO INJECT TRICKS AND LINK FILES <<<${NC}"
    read -r

    echo -e "\n${GREEN}${BOLD}--- PHASE 2: EXECUTION ---${NC}"

    # 1. Dependencies
    if [ ${#MISSING_PKGS[@]} -gt 0 ] && [[ "$AUTO_INSTALL" =~ ^[Yy]$ ]]; then
        source /etc/os-release
        OS_FLAVOR="${ID_LIKE:-$ID}"
        case "$OS_FLAVOR" in
            *debian*|*ubuntu*) sudo apt-get update && sudo apt-get install -y "${MISSING_PKGS[@]}" ;;
            *arch*) sudo pacman -Sy --noconfirm "${MISSING_PKGS[@]}" ;;
            *fedora*) sudo dnf install -y "${MISSING_PKGS[@]}" ;;
            *) echo -e "${RED}Manual install required: ${MISSING_PKGS[*]}${NC}"; exit 1 ;;
        esac
    fi

    # 2. Inject base OpenAL via protontricks/winetricks
    echo -e "\n${CYAN}STATUS: Ensuring base OpenAL routing via tricks...${NC}"
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks "$APPID" openal
    else
        WINEPREFIX="$PREFIX_PATH" winetricks openal
    fi

    # 3. Final File Placement
    TARGET_DSOAL=$(find "$DSOAL_EXTRACT" -type d -ipath "*/${BASE_FOLDER}/${ARCH_FOLDER}" | head -n 1)
    TARGET_OAL=$(find "$OPENAL_EXTRACT" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)

    if [[ -n "$TARGET_DSOAL" && -n "$TARGET_OAL" ]]; then
        # Link DSOAL wrapper
        ln -sf "$TARGET_DSOAL/dsound.dll" "$GAME_DIR/dsound.dll"

        # Link Engine
        if [ "$ENGINE_CHOICE" == "1" ]; then
            if [ -f "$TARGET_DSOAL/dsoal-aldrv.dll" ]; then
                ln -sf "$TARGET_DSOAL/dsoal-aldrv.dll" "$GAME_DIR/dsoal-aldrv.dll"
                echo -e "${GREEN}Linked Bundled DSOAL driver.${NC}"
            else
                echo -e "${YELLOW}Warning: Bundled driver missing from cache. Falling back to OpenAL Soft.${NC}"
                ln -sf "$TARGET_OAL/soft_oal.dll" "$GAME_DIR/dsoal-aldrv.dll"
            fi
        else
            ln -sf "$TARGET_OAL/soft_oal.dll" "$GAME_DIR/dsoal-aldrv.dll"
            echo -e "${GREEN}Linked Latest OpenAL Soft engine.${NC}"
        fi

        # Copy config
        [ -f "$TARGET_DSOAL/alsoft.ini" ] && cp -f "$TARGET_DSOAL/alsoft.ini" "$GAME_DIR/alsoft.ini"

        echo -e "${GREEN}Success! Files deployed to game folder.${NC}"
    else
        echo -e "${RED}Error: Target files missing from local cache.${NC}"; exit 1
    fi

    echo -e "\n${GREEN}${BOLD}==========================================================${NC}"
    echo -e "${GREEN}${BOLD}                INSTALLATION COMPLETE!                    ${NC}"
    echo -e "${GREEN}${BOLD}==========================================================${NC}"
    echo -e "To enable these files, you ${RED}${BOLD}MUST${NC} add this override:\n"

    if [ "$LAUNCHER_TYPE" == "1" ]; then
        echo -e "${BOLD}For Steam Launch Options:${NC}"
        echo -e "${CYAN}WINEDLLOVERRIDES=\"dsound=n,b\" %command%${NC}\n"
    else
        echo -e "${BOLD}For GOG (Heroic) Environment Variables:${NC}"
        echo -e "Variable Name:  ${CYAN}WINEDLLOVERRIDES${NC}"
        echo -e "Value:          ${CYAN}dsound=n,b${NC}"
    fi
    echo -e "${GREEN}${BOLD}==========================================================${NC}\n"
fi
