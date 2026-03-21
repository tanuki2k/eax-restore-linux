#!/usr/bin/env bash

# ==============================================================================
# DSOAL & OpenAL Universal Installer for Linux (Hybrid Cache Edition)
# ==============================================================================
#
# A streamlined Bash script designed to automate the restoration of EAX 3D
# audio in older Windows games running on Linux via Steam or Heroic.
#
# --- License ---
# MIT License
# Copyright (c) 2026 Benjamin van Houts
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ==============================================================================

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Paths
DSOAL_SHARE="$HOME/.local/share/dsoal"
DSOAL_EXTRACT="$DSOAL_SHARE/extracted"
URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
API_URL="https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master"

# ==============================================================================
# FUNCTION: UPDATE LOCAL CACHE
# ==============================================================================
update_local_cache() {
    echo -e "\n${CYAN}--- CHECKING FOR DSOAL UPDATES ---${NC}"
    mkdir -p "$DSOAL_SHARE"

    # Fetch latest release timestamp from GitHub
    LATEST_DATE=$(curl -s "$API_URL" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)

    if [ -z "$LATEST_DATE" ]; then
        if [ -d "$DSOAL_EXTRACT" ]; then
            echo -e "${YELLOW}Could not reach GitHub. Using cached files.${NC}"
            return 0
        else
            echo -e "${RED}Error: Could not reach GitHub and no local cache exists.${NC}"
            exit 1
        fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_EXTRACT" ]; then
        echo -e "${CYAN}A new version is available or cache is missing. Downloading...${NC}"
        rm -rf "$DSOAL_EXTRACT"
        mkdir -p "$DSOAL_EXTRACT"

        if curl -L -# "$URL" -o "$DSOAL_SHARE/dsoal.zip"; then
            unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_EXTRACT"
            # Extract nested zip if present
            NESTED=$(find "$DSOAL_EXTRACT" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
            if [ -n "$NESTED" ]; then
                unzip -q "$NESTED" -d "$DSOAL_EXTRACT"
            fi
            echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"
            rm -f "$DSOAL_SHARE/dsoal.zip"
            echo -e "${GREEN}Local cache updated successfully!${NC}"
        else
            echo -e "${RED}Error: Download failed.${NC}"
            exit 1
        fi
    else
        echo -e "${GREEN}Local cache is already up to date ($LATEST_DATE).${NC}"
    fi
}

# ==============================================================================
# MAIN MENU
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Universal Installer                     ${NC}"
echo -e "${CYAN}${BOLD}   By Benjamin van Houts                                  ${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}\n"

echo -e "${GREEN}${BOLD}--- MAIN MENU ---${NC}"
echo "1) Install DSOAL for a game"
echo "2) Update Local DSOAL Cache"
echo "3) Uninstall DSOAL from a game"
echo -e -n "${YELLOW}Selection (1, 2, or 3): ${NC}"
read -r SCRIPT_ACTION

# ==============================================================================
# ACTION 2: UPDATE GLOBAL CACHE
# ==============================================================================
if [ "$SCRIPT_ACTION" == "2" ]; then
    update_local_cache
    exit 0
fi

# ==============================================================================
# ACTION 3: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "3" ]; then
    echo -e "\n${CYAN}--- UNINSTALL DSOAL ---${NC}"
    echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
    echo -e -n "> "
    read -r GAME_DIR
    GAME_DIR="${GAME_DIR/#\~/$HOME}"

    if [ ! -d "$GAME_DIR" ]; then
        echo -e "${RED}Error: Directory not found.${NC}"; exit 1
    fi

    FILES_TO_REMOVE=()
    [ -f "$GAME_DIR/dsound.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsound.dll")
    [ -f "$GAME_DIR/dsoal-aldrv.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsoal-aldrv.dll")
    [ -f "$GAME_DIR/alsoft.ini" ] && FILES_TO_REMOVE+=("$GAME_DIR/alsoft.ini")

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ]; then
        echo -e "${YELLOW}No DSOAL files found in $GAME_DIR.${NC}"; exit 0
    fi

    echo -e "\n${RED}${BOLD}The following files will be removed:${NC}"
    for f in "${FILES_TO_REMOVE[@]}"; do echo " - $f"; done
    echo -e -n "\n${YELLOW}Proceed with removal? (Y/n): ${NC}"
    read -r CONFIRM_UNINSTALL

    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Nn]$ ]]; then
        for f in "${FILES_TO_REMOVE[@]}"; do rm -f "$f"; done
        echo -e "${GREEN}DSOAL removed from $GAME_DIR${NC}"
    fi
    exit 0
fi

# ==============================================================================
# ACTION 1: INSTALL (PHASE 1: GATHERING)
# ==============================================================================
echo -e "\n${GREEN}${BOLD}--- PHASE 1: CONFIGURATION ---${NC}"

# 1. Launcher Setup
echo -e "\n${CYAN}1. Launcher Setup${NC}"
echo "1) Steam"
echo "2) GOG (Heroic)"
echo -e -n "${YELLOW}Selection (1 or 2): ${NC}"
read -r LAUNCHER_TYPE

# 2. Game Location
echo -e "\n${CYAN}2. Game Location${NC}"
echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
echo -e -n "> "
read -r GAME_DIR
GAME_DIR="${GAME_DIR/#\~/$HOME}"
[ ! -d "$GAME_DIR" ] && { echo -e "${RED}Error: Path not found.${NC}"; exit 1; }

# 3. Game Identification
echo -e "\n${CYAN}3. Game Identification${NC}"
if [ "$LAUNCHER_TYPE" == "1" ]; then
    echo -e -n "${YELLOW}Enter the Steam AppID: ${NC}"
    read -r APPID
else
    echo -e -n "${YELLOW}Paste the Wine Prefix path (e.g. ~/Games/Heroic/Prefixes/default/Game): ${NC}"
    read -r PREFIX_PATH
    PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
fi

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
    echo -e "${YELLOW}Missing: ${MISSING_PKGS[*]}${NC}"
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
echo -e "\n${GREEN}${BOLD}--- PHASE 2: EXECUTION ---${NC}"
echo -e -n "${CYAN}Press Enter to begin installation...${NC}"
read -r

# 1. Ensure cache is ready
update_local_cache

# 2. Dependencies
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

# 3. Inject OpenAL
if [ "$LAUNCHER_TYPE" == "1" ]; then
    protontricks "$APPID" openal
else
    WINEPREFIX="$PREFIX_PATH" winetricks openal
fi

# 4. Final Linking
TARGET_SRC=$(find "$DSOAL_EXTRACT" -type d -ipath "*/${BASE_FOLDER}/${ARCH_FOLDER}" | head -n 1)
if [ -n "$TARGET_SRC" ]; then
    ln -sf "$TARGET_SRC/dsound.dll" "$GAME_DIR/dsound.dll"
    ln -sf "$TARGET_SRC/dsoal-aldrv.dll" "$GAME_DIR/dsoal-aldrv.dll"
    [ -f "$TARGET_SRC/alsoft.ini" ] && cp -f "$TARGET_SRC/alsoft.ini" "$GAME_DIR/alsoft.ini"
    echo -e "${GREEN}Success! DLLs linked, alsoft.ini copied to game folder.${NC}"
else
    echo -e "${RED}Error: Target files missing from local cache.${NC}"; exit 1
fi

echo -e "\n${GREEN}${BOLD}==========================================================${NC}"
echo -e "${GREEN}${BOLD}                INSTALLATION COMPLETE!                    ${NC}"
echo -e "${GREEN}${BOLD}==========================================================${NC}"
echo -e "Add: ${CYAN}WINEDLLOVERRIDES=\"dsound=n,b\"${NC} to your launch options."
