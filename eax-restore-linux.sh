#!/usr/bin/env bash

# ==============================================================================
# DSOAL & OpenAL Soft Universal Installer for Linux
# ==============================================================================
#
# A streamlined Bash script designed to automate the restoration of EAX 3D
# audio in older Windows games running on Linux via Steam or Heroic.
#
# --- Project Repository ---
# https://github.com/tanuki2k/eax-steam-proton
#
# --- Features ---
# * Full Stack: Links DSOAL and OpenAL Soft directly to the game.
# * Engine Choice: Toggle between ThreeDeeJay or kcat builds.
# * Interactive Conflicts: Safely handles existing files with timestamped backups.
# * Smart Detection: Opt-in auto-detection for Steam AppIDs and Heroic Prefixes.
# * Verbose Logic: Step-by-step terminal feedback during system searches.
# * Deep Validation: Ensures Heroic/GOG prefixes are initialized via drive_c.
# * COM Registry Injection: Optional routing of DirectSound CLSIDs in Wine.
# * Legacy Support: Optional safe injection of dsound.vxd for 90s titles.
# * Advanced Tweaks: Optional EAX Unified dummies and expanded audio limits.
# * Auto-Overrides: Injects WINEDLLOVERRIDES natively into Wine registry.
#
# --- Credits & Upstream Sources ---
# * kcat (Christopher Robinson) - DSOAL & OpenAL Soft: https://github.com/kcat
# * ThreeDeeJay - DSOAL Community Fork: https://github.com/ThreeDeeJay
#
# --- License ---
# MIT License
# Copyright (c) 2026 Tanuki2k
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

# --- Colour Definitions ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# VISUAL HELPERS
# ==============================================================================
print_divider() {
    echo -e "${CYAN}----------------------------------------------------------${NC}"
}

print_line() {
    echo -e "${CYAN}----------------------------------------------------------${NC}"
}

# ==============================================================================
# ROOT GUARD (CRITICAL WINE SAFETY)
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

# Paths
BASE_SHARE="$HOME/.local/share/eax-restore-linux"
DSOAL_SHARE="$BASE_SHARE/dsoal"
DSOAL_OFFICIAL="$DSOAL_SHARE/official"
DSOAL_COMMUNITY="$DSOAL_SHARE/community"
OPENAL_SHARE="$BASE_SHARE/openal-soft"
OPENAL_OFFICIAL="$OPENAL_SHARE/official"

URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
API_URL="https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master"
COMMUNITY_URL="https://github.com/ThreeDeeJay/dsoal/releases/download/0.9.6/DSOAL+HRTF.zip"

# ==============================================================================
# FUNCTION: OFFLINE INSTRUCTIONS
# ==============================================================================
print_offline_instructions() {
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}--- OFFLINE MODE INSTRUCTIONS ---${NC}"
    print_line
    echo -e "${WHITE}GitHub is unreachable and no local cache was found.${NC}"
    echo -e "${WHITE}Manually extract release .zips into these folders:${NC}\n"
    echo -e "${CYAN}1. kcat Official DSOAL:${NC} ${GREEN}$DSOAL_OFFICIAL${NC}"
    echo -e "${CYAN}2. kcat OpenAL Soft:${NC}   ${GREEN}$OPENAL_OFFICIAL${NC}"
    echo -e "${CYAN}3. ThreeDeeJay DSOAL:${NC}  ${GREEN}$DSOAL_COMMUNITY${NC}\n"
}

# ==============================================================================
# FUNCTION: UPDATE LOCAL CACHE
# ==============================================================================
update_local_cache() {
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- REPOSITORY CACHE CHECK ---${NC}"
    print_line
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"

    # --- 1. kcat Official DSOAL ---
    echo -e "\n${CYAN}Checking kcat Official DSOAL repository...${NC}"
    LATEST_DATE=$(curl -s "$API_URL" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)

    if [ -z "$LATEST_DATE" ]; then
        if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL")" ]; then
            echo -e " -> ${YELLOW}Offline. Using cached version [${LOCAL_DATE%%T*}]${NC}"
        else
            echo -e " -> ${YELLOW}${BOLD}Error: Offline and no cache found.${NC}"
            print_offline_instructions; exit 1
        fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading latest build...${NC}"
        rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
        if curl -L -# "$URL" -o "$DSOAL_SHARE/dsoal.zip"; then
            unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_OFFICIAL"
            NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
            [ -n "$NESTED" ] && unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"
            echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"
            rm -f "$DSOAL_SHARE/dsoal.zip"
            echo -e " -> ${GREEN}Done.${NC}"
        fi
    else
        echo -e " -> ${GREEN}Up to date [${LOCAL_DATE%%T*}]${NC}"
    fi

    # --- 2. kcat OpenAL Soft ---
    echo -e "\n${CYAN}Checking kcat OpenAL Soft repository...${NC}"
    OAL_TAG=$(curl -sI https://github.com/kcat/openal-soft/releases/latest | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
    LOCAL_OAL_TAG=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)

    if [ -z "$OAL_TAG" ]; then
        if [ -d "$OPENAL_OFFICIAL" ]; then echo -e " -> ${YELLOW}Offline. Using cached version [${LOCAL_OAL_TAG}]${NC}"
        else echo -e " -> ${YELLOW}${BOLD}Error: OpenAL cache missing.${NC}"; exit 1; fi
    elif [ "$OAL_TAG" != "$LOCAL_OAL_TAG" ] || [ ! -d "$OPENAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading OpenAL Soft [${OAL_TAG}]...${NC}"
        OAL_URL="https://github.com/kcat/openal-soft/releases/download/${OAL_TAG}/openal-soft-${OAL_TAG}-bin.zip"
        rm -rf "$OPENAL_OFFICIAL"; mkdir -p "$OPENAL_OFFICIAL"
        if curl -L -# "$OAL_URL" -o "$OPENAL_SHARE/openal.zip"; then
            unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_OFFICIAL"
            echo "$OAL_TAG" > "$OPENAL_SHARE/updated_at.txt"; rm -f "$OPENAL_SHARE/openal.zip"
            echo -e " -> ${GREEN}Done.${NC}"
        fi
    else
        echo -e " -> ${GREEN}Up to date [${LOCAL_OAL_TAG}]${NC}"
    fi

    # --- 3. ThreeDeeJay Community DSOAL ---
    echo -e "\n${CYAN}Checking ThreeDeeJay Community DSOAL...${NC}"
    if [ ! -d "$DSOAL_COMMUNITY" ]; then
        echo -e " -> ${CYAN}Cache missing. Downloading stable build [v0.9.6]...${NC}"
        mkdir -p "$DSOAL_COMMUNITY"
        if curl -L -# "$COMMUNITY_URL" -o "$DSOAL_SHARE/community.zip"; then
            unzip -q "$DSOAL_SHARE/community.zip" -d "$DSOAL_COMMUNITY"
            rm -f "$DSOAL_SHARE/community.zip"
            echo -e " -> ${GREEN}Done.${NC}"
        fi
    else
        echo -e " -> ${GREEN}Available in cache.${NC}"
    fi
}

# ==============================================================================
# FUNCTION: INTERACTIVE FILE CONFLICT HANDLER
# ==============================================================================
handle_conflict() {
    local target_file="$1"
    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        echo -e "\n${YELLOW}Conflict: $(basename "$target_file") already exists in the game folder.${NC}"
        while true; do
            echo -e "${YELLOW}Action - [o]verwrite, [b]ackup & overwrite, [s]kip: ${NC}"
            echo -e -n "> "
            read -r C_CHOICE
            case "${C_CHOICE,,}" in
                o)
                    rm -rf "$target_file"
                    echo -e " -> Overwriting $(basename "$target_file")..."
                    return 0
                    ;;
                b)
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    mv "$target_file" "${target_file}.bak.${TIMESTAMP}"
                    echo -e " -> Backed up original to $(basename "$target_file").bak.${TIMESTAMP}"
                    return 0
                    ;;
                s)
                    echo -e " -> Skipped $(basename "$target_file")."
                    return 1
                    ;;
                *)
                    echo -e "${YELLOW}${BOLD}Invalid choice. Type o, b, or s.${NC}"
                    ;;
            esac
        done
    fi
    return 0
}

# ==============================================================================
# FUNCTION: VERBOSE HEROIC PREFIX SEARCH
# ==============================================================================
detect_heroic_prefix_verbose() {
    local target_dir="$1"
    local auto_prefix=""
    local app_name=""

    # Redirecting all verbose text to stderr (>&2) so the function ONLY returns the raw path
    echo -e "\n${CYAN}STATUS: Scanning Heroic configuration files...${NC}" >&2
    local installed_jsons
    installed_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)

    echo -e " -> Searching installed.json for matching game path..." >&2
    while IFS= read -r json_file; do
        [ -z "$json_file" ] && continue
        if grep -Fiq "$target_dir" "$json_file"; then
            app_name=$(awk -v path="$target_dir" 'BEGIN { RS="}"; FS="," } $0 ~ path { for (i=1; i<=NF; i++) { if ($i ~ /"app_name"|"appName"/) { split($i, a, "\""); print a[4]; exit; } } }' "$json_file")
            if [ -n "$app_name" ]; then
                echo -e " -> Game found! Internal ID: ${BOLD}$app_name${NC}" >&2
                echo -e " -> Parsing GamesConfig/$app_name.json for custom prefix paths..." >&2
                local config_jsons
                config_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/$app_name.json" 2>/dev/null)
                while IFS= read -r conf_file; do
                    [ -z "$conf_file" ] && continue
                    auto_prefix=$(grep '"winePrefix"' "$conf_file" | awk -F '"' '{print $4}')
                    [ -n "$auto_prefix" ] && break
                done <<< "$config_jsons"
            fi
            [ -n "$auto_prefix" ] && break
        fi
    done <<< "$installed_jsons"

    if [ -n "$app_name" ] && [ -z "$auto_prefix" ]; then
        echo -e " -> No custom prefix defined. Checking default Heroic locations..." >&2
        if [ -d "$HOME/Games/Heroic/Prefixes/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/$app_name"
        elif [ -d "$HOME/Games/Heroic/Prefixes/default/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/default/$app_name"
        fi
    fi

    if [ -n "$auto_prefix" ]; then
        echo -e " -> Prefix path located!" >&2
        echo "$auto_prefix" # This is the ONLY string sent to standard output
    else
        echo -e " -> ${YELLOW}Search complete. No prefix found.${NC}" >&2
    fi
}

# ==============================================================================
# SCRIPT START
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Soft Universal Installer                ${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- PRE-FLIGHT SYSTEM CHECK ---${NC}"
print_line
echo -e "\n${CYAN}Verifying required base tools before accessing cache...${NC}"

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
    echo -e "${YELLOW}MISSING (Required for Steam games)${NC}"
fi

echo -n -e " -> Checking for ${YELLOW}winetricks${NC}... "
if command -v winetricks &> /dev/null; then
    echo -e "${GREEN}FOUND${NC}"
else
    echo -e "${YELLOW}MISSING (Required for Heroic/GOG games)${NC}"
fi

if ! command -v protontricks &> /dev/null && ! command -v winetricks &> /dev/null; then
    MISSING_BASE_PKGS+=("protontricks" "winetricks")
fi

if [ ${#MISSING_BASE_PKGS[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}The script is missing essential tools to function: ${MISSING_BASE_PKGS[*]}${NC}"
    echo -e -n "${YELLOW}Auto-install these dependencies now? (Requires sudo) (Y/n): ${NC}"
    read -r AUTO_INSTALL_BASE
    if [[ ! "$AUTO_INSTALL_BASE" =~ ^[Nn]$ ]]; then
        echo -e "\n${CYAN}STATUS: Installing missing packages...${NC}"
        source /etc/os-release
        OS_FLAVOR="${ID_LIKE:-$ID}"
        case "$OS_FLAVOR" in
            *debian*|*ubuntu*) sudo apt-get update && sudo apt-get install -y "${MISSING_BASE_PKGS[@]}" ;;
            *arch*) sudo pacman -Sy --noconfirm "${MISSING_BASE_PKGS[@]}" ;;
            *fedora*) sudo dnf install -y "${MISSING_BASE_PKGS[@]}" ;;
            *) echo -e "${YELLOW}${BOLD}Manual install required: ${MISSING_BASE_PKGS[*]}${NC}"; exit 1 ;;
        esac
        echo -e " -> ${GREEN}Dependencies installed successfully.${NC}"
    else
        echo -e "\n${YELLOW}${BOLD}Cannot proceed without base dependencies. Exiting.${NC}"
        exit 1
    fi
else
    echo -e " -> ${GREEN}All base requirements met.${NC}"
fi

update_local_cache

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- SELECT OPERATION ---${NC}"
print_line
while true; do
    echo -e "\n${YELLOW}Would you like to (i)nstall or (u)ninstall the EAX audio fix? (i/u): ${NC}"
    echo -e -n "> "
    read -r SCRIPT_ACTION
    SCRIPT_ACTION="${SCRIPT_ACTION,,}"

    if [[ "$SCRIPT_ACTION" == "i" || "$SCRIPT_ACTION" == "u" ]]; then
        break
    else
        echo -e "${YELLOW}${BOLD}Invalid selection. Please type 'i' or 'u'.${NC}"
    fi
done

# ==============================================================================
# ACTION: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "u" ]; then
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- UNINSTALL EAX FIX ---${NC}"
    print_line

    while true; do
        echo ""
        print_divider
        echo -e "${CYAN}1. Game Location${NC}"
        print_line
        echo ""
        echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
        echo -e "${WHITE} Example Steam:  ~/.local/share/Steam/steamapps/common/[Game]${NC}"
        echo -e "${WHITE} Example Heroic: ~/Games/Heroic/[Game]${NC}"
        echo -e -n "> "
        read -r GAME_DIR
        GAME_DIR="${GAME_DIR//\'/}"; GAME_DIR="${GAME_DIR//\"/}"; GAME_DIR="${GAME_DIR%/}"
        GAME_DIR="${GAME_DIR/#\~/$HOME}"

        if [ -d "$GAME_DIR" ]; then
            break
        else
            echo -e "${YELLOW}${BOLD}Error: Directory not found. Please check the path and try again.${NC}"
        fi
    done

    FILES_TO_REMOVE=()
    [ -L "$GAME_DIR/dsound.dll" ] || [ -f "$GAME_DIR/dsound.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsound.dll")
    [ -L "$GAME_DIR/dsoal-aldrv.dll" ] || [ -f "$GAME_DIR/dsoal-aldrv.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsoal-aldrv.dll")
    [ -f "$GAME_DIR/dsound.vxd" ] && FILES_TO_REMOVE+=("$GAME_DIR/dsound.vxd")
    [ -f "$GAME_DIR/eax.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/eax.dll")
    [ -f "$GAME_DIR/eaxunified.dll" ] && FILES_TO_REMOVE+=("$GAME_DIR/eaxunified.dll")
    [ -f "$GAME_DIR/alsoft.ini" ] && FILES_TO_REMOVE+=("$GAME_DIR/alsoft.ini")
    [ -d "$GAME_DIR/OpenAL" ] && FILES_TO_REMOVE+=("$GAME_DIR/OpenAL")

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}No EAX files found in $GAME_DIR.${NC}"; exit 0
    fi

    echo -e "\n${YELLOW}${BOLD}The following files will be removed:${NC}"
    for f in "${FILES_TO_REMOVE[@]}"; do echo " - $f"; done
    echo -e "\n${YELLOW}Proceed with file removal? (Y/n): ${NC}"
    echo -e -n "> "
    read -r CONFIRM_UNINSTALL

    if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Nn]$ ]]; then
        for f in "${FILES_TO_REMOVE[@]}"; do rm -rf "$f"; done
        echo -e "\n${GREEN}EAX Fix files removed from $GAME_DIR${NC}"

        # Restore the newest timestamped backup
        LATEST_DSOUND_BAK=$(ls -t "$GAME_DIR"/dsound.dll.bak* 2>/dev/null | head -n 1)
        if [ -n "$LATEST_DSOUND_BAK" ]; then
            mv "$LATEST_DSOUND_BAK" "$GAME_DIR/dsound.dll" && echo -e " -> Restored original dsound.dll"
        fi

        LATEST_ALSOFT_BAK=$(ls -t "$GAME_DIR"/alsoft.ini.bak* 2>/dev/null | head -n 1)
        if [ -n "$LATEST_ALSOFT_BAK" ]; then
            mv "$LATEST_ALSOFT_BAK" "$GAME_DIR/alsoft.ini" && echo -e " -> Restored original alsoft.ini"
        fi
    fi

    echo -e "\n${YELLOW}Do you also want to remove COM Registry routing & Override keys from Wine? (y/n): ${NC}"
    echo -e -n "> "
    read -r REMOVE_REG

    if [[ "$REMOVE_REG" =~ ^[Yy]$ ]]; then
        APPID=""
        PREFIX_PATH=""

        echo -e "\n${YELLOW}Would you like the script to attempt to automatically find your Wine/Proton prefix for registry cleaning? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO_UN
        if [[ ! "$DO_AUTO_UN" =~ ^[Nn]$ ]]; then
            if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
                 echo -e "\n${CYAN}STATUS: Searching for Steam AppID...${NC}"
                 INSTALL_DIR=$(basename "$GAME_DIR")
                 echo -e " -> Scanning local appmanifest files for folder: $INSTALL_DIR"
                 MANIFEST_FILE=$(grep -il "\"installdir\"\s*\"$INSTALL_DIR\"" "${GAME_DIR%/common/*}"/appmanifest_*.acf 2>/dev/null | head -n 1)

                 if [ -n "$MANIFEST_FILE" ]; then
                     AUTO_APPID=$(basename "$MANIFEST_FILE" | tr -dc '0-9')
                     echo -e " -> Found AppID: ${BOLD}$AUTO_APPID${NC}"
                     echo -e -n "Use this detected Steam AppID? (Y/n): "
                     read -r C_AUTO
                     [[ ! "$C_AUTO" =~ ^[Nn]$ ]] && APPID="$AUTO_APPID"
                 else
                     echo -e " -> ${YELLOW}Search complete. No matching AppID found.${NC}"
                 fi
            else
                 DETECTED_PREFIX=$(detect_heroic_prefix_verbose "$GAME_DIR")
                 if [ -n "$DETECTED_PREFIX" ]; then
                     echo -e "\nDetected Prefix: $DETECTED_PREFIX"
                     echo -e -n "Use this detected prefix? (Y/n): "
                     read -r C_AUTO
                     if [[ ! "$C_AUTO" =~ ^[Nn]$ ]]; then
                         PREFIX_PATH="$DETECTED_PREFIX"
                     fi
                 fi
            fi
        fi

        if [ -z "$APPID" ] && [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
            echo -e "\n${YELLOW}Enter the Steam AppID manually: ${NC}"
            echo -e -n "> "
            read -r APPID
            APPID=$(echo "$APPID" | tr -dc '0-9')
        fi

        if [ -z "$PREFIX_PATH" ] && [[ "$GAME_DIR" != *"/steamapps/common/"* ]]; then
            while true; do
                echo -e "\n${YELLOW}Enter the full Wine Prefix path manually: ${NC}"
                echo -e -n "> "
                read -r PREFIX_PATH
                PREFIX_PATH="${PREFIX_PATH//\'/}"; PREFIX_PATH="${PREFIX_PATH//\"/}"; PREFIX_PATH="${PREFIX_PATH%/}"; PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
                [ -d "$PREFIX_PATH/drive_c" ] && break
                echo -e "${YELLOW}${BOLD}Error: Initialized Wine prefix not found (missing drive_c).${NC}"
                echo -e -n "${YELLOW}Check again? (y/n): ${NC}"
                read -r RET; [[ "$RET" =~ ^[Nn]$ ]] && break || PREFIX_PATH=""
            done
        fi

        # Registry Cleaning Logic
        if [ -n "$APPID" ] || [ -d "$PREFIX_PATH/drive_c" ]; then
            REG_FILE="/tmp/dsoal_registry_clean_$$.reg"
            cat <<EOF > "$REG_FILE"
Windows Registry Editor Version 5.00

[-HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
[-HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"dsound"=-
EOF
            echo -e "\n${CYAN}STATUS: Cleaning registry...${NC}"
            if [ -n "$APPID" ]; then
                echo -e " -> Cleaning registry via protontricks..."
                protontricks -c "regedit \"$REG_FILE\"" "$APPID" &>/dev/null
            elif [ -d "$PREFIX_PATH/drive_c" ]; then
                echo -e " -> Cleaning registry via winetricks..."
                WINEPREFIX="$PREFIX_PATH" wine regedit "$REG_FILE" &>/dev/null
            fi
            rm -f "$REG_FILE"
            echo -e " -> ${GREEN}COM routing and Override keys safely removed.${NC}"
        else
            echo -e "${YELLOW}${BOLD}Prefix/AppID not found, skipping registry cleanup.${NC}"
        fi
    fi

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- UNINSTALL COMPLETE! ---${NC}"
    print_line
    exit 0
fi

# ==============================================================================
# ACTION: INSTALL (PHASE 1: CONFIGURATION)
# ==============================================================================
if [ "$SCRIPT_ACTION" == "i" ]; then
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- PHASE 1: CONFIGURATION ---${NC}"
    print_line

    # 1. Game Location
    echo ""
    print_divider
    echo -e "${CYAN}1. Game Location${NC}"
    print_line
    echo ""
    while true; do
        echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"
        echo -e "${WHITE} Example Steam:  ~/.local/share/Steam/steamapps/common/[Game]${NC}"
        echo -e "${WHITE} Example Heroic: ~/Games/Heroic/[Game]${NC}"
        echo -e -n "> "
        read -r GAME_DIR
        GAME_DIR="${GAME_DIR//\'/}"; GAME_DIR="${GAME_DIR//\"/}"; GAME_DIR="${GAME_DIR%/}"
        GAME_DIR="${GAME_DIR/#\~/$HOME}"

        if [ -d "$GAME_DIR" ]; then
            EXE_COUNT=$(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" | wc -l)
            if [ "$EXE_COUNT" -eq 0 ]; then
                echo -e "\n${YELLOW}${BOLD}Warning: No .exe files were found in this directory or its immediate subfolders.${NC}"
                echo -e "${YELLOW}Are you absolutely sure this is the correct game folder? (y/N): ${NC}"
                echo -e -n "> "
                read -r FORCE_DIR
                if [[ "$FORCE_DIR" =~ ^[Yy]$ ]]; then
                    break
                fi
            else
                break
            fi
        else
            echo -e "${YELLOW}${BOLD}Error: Directory not found. Please check the path and try again.${NC}"
        fi
    done

    # 2. Game Identification & Launcher Auto-Detect
    echo ""
    print_divider
    echo -e "${CYAN}2. Launcher Identification${NC}"
    print_line
    echo ""
    PREFIX_PATH=""
    if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
        LAUNCHER_TYPE="1"
        echo -e "${GREEN}Steam installation detected!${NC}"
        echo -e "\n${YELLOW}Would you like the script to attempt to automatically find your Proton prefix? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO_S

        APPID=""
        if [[ ! "$DO_AUTO_S" =~ ^[Nn]$ ]]; then
            echo -e "\n${CYAN}STATUS: Searching for Steam AppID...${NC}"
            INSTALL_DIR=$(basename "$GAME_DIR")
            echo -e " -> Scanning local appmanifest files for folder: $INSTALL_DIR"
            MANIFEST_FILE=$(grep -il "\"installdir\"\s*\"$INSTALL_DIR\"" "${GAME_DIR%/common/*}"/appmanifest_*.acf 2>/dev/null | head -n 1)

            if [ -n "$MANIFEST_FILE" ]; then
                AUTO_APPID=$(basename "$MANIFEST_FILE" | tr -dc '0-9')
                echo -e " -> Found AppID: ${BOLD}$AUTO_APPID${NC}"
                echo -e -n "Use this detected Steam AppID? (Y/n): "
                read -r C_AUTO
                if [[ ! "$C_AUTO" =~ ^[Nn]$ ]]; then
                    APPID="$AUTO_APPID"
                fi
            else
                echo -e " -> ${YELLOW}Search complete. No matching AppID found.${NC}"
            fi
        fi

        # Validation Loop for Steam AppID and Prefix
        echo -e "\n${CYAN}Verifying Wine Prefix...${NC}"
        while true; do
            if [ -z "$APPID" ]; then
                echo -e "\n${YELLOW}Enter the Steam AppID manually: ${NC}"
                echo -e "${WHITE} Tip: Found on game's Steam Store URL (store.steampowered.com/app/APPID)${NC}"
                echo -e -n "> "
                read -r APPID
                APPID=$(echo "$APPID" | tr -dc '0-9')
            fi

            echo -e " -> Querying Protontricks database for AppID ${APPID}..."
            PREFIX_PATH=$(protontricks -c 'echo $WINEPREFIX' "$APPID" 2>/dev/null | grep "/pfx" | tail -n 1 | tr -d '\r')

            if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH" ]; then
                echo -e " -> ${GREEN}Prefix verified!${NC}"
                break
            else
                echo -e "\n${YELLOW}${BOLD}Error: Proton prefix not found for AppID ${APPID}.${NC}"
                echo -e "${WHITE}If you just installed this game, Proton has not generated the prefix yet."
                echo -e "Please run the game at least once in Steam, close it, and try again.${NC}"

                echo -e "\n${YELLOW}Check this AppID again? (y/n): ${NC}"
                echo -e -n "> "
                read -r RET
                if [[ "$RET" =~ ^[Nn]$ ]]; then
                    echo -e "\n${YELLOW}Enter a different Steam AppID manually: ${NC}"
                    echo -e -n "> "
                    read -r NEW_APPID
                    APPID=$(echo "$NEW_APPID" | tr -dc '0-9')
                fi
            fi
        done
    else
        LAUNCHER_TYPE="2"
        echo -e "${GREEN}Non-Steam (GOG/Heroic) installation detected!${NC}"
        echo -e "\n${YELLOW}Would you like the script to attempt to automatically find your Wine prefix? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO_H

        if [[ ! "$DO_AUTO_H" =~ ^[Nn]$ ]]; then
            DETECTED_PREFIX=$(detect_heroic_prefix_verbose "$GAME_DIR")
            if [ -n "$DETECTED_PREFIX" ]; then
                echo -e "\nDetected Prefix: $DETECTED_PREFIX"
                echo -e -n "Use this detected prefix? (Y/n): "
                read -r C_AUTO
                if [[ ! "$C_AUTO" =~ ^[Nn]$ ]]; then
                    PREFIX_PATH="$DETECTED_PREFIX"
                fi
            fi
        fi

        while true; do
            if [ -z "$PREFIX_PATH" ]; then
                echo -e "\n${YELLOW}Enter the Wine Prefix path manually: ${NC}"
                echo -e "${WHITE} Example Heroic: ~/Games/Heroic/Prefixes/[Game-Name]${NC}"
                echo -e -n "> "
                read -r PREFIX_PATH
                PREFIX_PATH="${PREFIX_PATH//\'/}"; PREFIX_PATH="${PREFIX_PATH//\"/}"; PREFIX_PATH="${PREFIX_PATH%/}"
                PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
            fi

            if [ -d "$PREFIX_PATH/drive_c" ]; then
                echo -e " -> ${GREEN}Prefix verified!${NC}"
                break
            else
                echo -e "\n${YELLOW}${BOLD}Error: Initialized Wine prefix not found at that location.${NC}"
                echo -e "${WHITE}If you just installed this game, Heroic has not generated the prefix yet."
                echo -e "Please run the game at least once in Heroic, close it, and try again.${NC}"
                echo -e "\n${YELLOW}Check this path again? (y/n): ${NC}"
                echo -e -n "> "
                read -r RET
                if [[ "$RET" =~ ^[Nn]$ ]]; then
                    PREFIX_PATH=""
                fi
            fi
        done
    fi

    # 3. Engine Selection
    echo ""
    print_divider
    echo -e "${CYAN}3. Audio Engine Selection${NC}"
    print_line
    echo ""
    DSOAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    DSOAL_VER=${DSOAL_DATE%%T*}
    [ -z "$DSOAL_VER" ] && DSOAL_VER="Unknown"
    OAL_VER=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    [ -z "$OAL_VER" ] && OAL_VER="Unknown"

    echo -e "${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"

    echo -e " * ${BOLD}ThreeDeeJay Community:${NC} The best \"plug-and-play\" choice for older Windows 98/XP games."
    echo -e "   It includes pre-configured HRTF profiles and specific compatibility tweaks curated by the"
    echo -e "   retro-gaming community, though it relies on a slightly older, locked codebase.\n"

    echo -e " * ${BOLD}kcat DSOAL (Stable):${NC} The official, rock-solid baseline from the original wrapper developer."
    echo -e "   It is a highly reliable fallback if the community version gives you trouble.\n"

    echo -e " * ${BOLD}kcat Latest OpenAL Soft:${NC} Pulls the absolute newest, bleeding-edge audio renderer. It offers"
    echo -e "   the highest fidelity algorithms, but constant updates carry a slight risk of introducing"
    echo -e "   unforeseen audio bugs in 25-year-old games.\n"

    echo -e "${YELLOW}Selection (1, 2, or 3) [Default: 1]: ${NC}"
    echo -e "\n 1) ThreeDeeJay Community DSOAL [v1.31a]"
    echo -e " 2) kcat DSOAL                  [$DSOAL_VER]"
    echo -e " 3) kcat Latest OpenAL Soft     [$OAL_VER]"

    while true; do
        echo -e -n "\n> "
        read -r ENGINE_CHOICE
        ENGINE_CHOICE="${ENGINE_CHOICE:-1}"
        if [[ "$ENGINE_CHOICE" =~ ^[123]$ ]]; then break; else echo -e "${YELLOW}${BOLD}Invalid selection.${NC}"; fi
    done

    # 4. Audio Configuration
    echo ""
    print_divider
    echo -e "${CYAN}4. Headphones Configuration${NC}"
    print_line
    echo ""
    echo -e "${YELLOW}Do you want to enable HRTF for headphones? (y/N): ${NC}"
    echo -e -n "> "
    read -r ENABLE_HRTF
    BASE_FOLDER=$([[ "$ENABLE_HRTF" =~ ^[Yy]$ ]] && echo "DSOAL+HRTF" || echo "DSOAL")

    # 5. COM Registry Routing
    echo ""
    print_divider
    echo -e "${CYAN}5. COM Registry Routing${NC}"
    print_line
    echo ""
    echo -e "${YELLOW}Do you want to inject the COM registry routing? (y/N): ${NC}"
    echo -e "${WHITE} Tip: Only needed if EAX options remain greyed out in the game menu.${NC}"
    echo -e -n "> "
    read -r INJECT_REGISTRY

    # 6. Legacy Windows 95/98 Compatibility
    echo ""
    print_divider
    echo -e "${CYAN}6. Legacy Windows 95/98 Compatibility${NC}"
    print_line
    echo ""
    echo -e "${WHITE}Many games released in the late 90s specifically check for the presence of an old"
    echo -e "virtual device driver before they allow you to click the \"Enable 3D Audio\" checkbox."
    echo -e "Creating a harmless, empty dsound.vxd file perfectly bypasses this check."
    echo -e "(Note: This is 100% safe and will not cause crashes in newer games).${NC}"
    echo -e "\n${YELLOW}Inject legacy dsound.vxd dummy file? (Y/n): ${NC}"
    echo -e -n "> "
    read -r LEGACY_VXD

    # 7. Advanced Compatibility Tweaks
    echo ""
    print_divider
    echo -e "${CYAN}7. Advanced Compatibility Tweaks${NC}"
    print_line
    echo ""
    echo -e "${WHITE}Some extremely stubborn games require specific workarounds to unlock EAX."
    echo -e "${YELLOW}${BOLD}WARNING:${NC} ${WHITE}These tweaks fix certain games but may cause others to crash or stutter."
    echo -e "If you are unsure, just press [Enter] on both to safely skip them.${NC}\n"

    echo -e "${YELLOW}Tweak A: EAX Unified Dummy Files${NC}"
    echo -e "${WHITE}Tricks certain games (like KOTOR, Max Payne, and early Unreal Engine titles)"
    echo -e "into unlocking the EAX menu option by creating harmless, empty eax.dll and eaxunified.dll files.${NC}"
    echo -e -n "> Inject EAX Unified dummy files? (y/N): "
    read -r ADVANCED_DUMMY

    echo -e "\n${YELLOW}Tweak B: Expand Audio Limits${NC}"
    echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
    echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
    echo -e -n "> Expand OpenAL audio limits? (y/N): "
    read -r ADVANCED_LIMITS

    # 8. Architecture Scan
    echo ""
    print_divider
    echo -e "${CYAN}8. Architecture Selection${NC}"
    print_line
    echo ""
    ARCH="MANUAL"
    if command -v file &> /dev/null; then
        echo -e "${YELLOW}Attempt to auto-detect 32/64 bit architecture? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO
        if [[ ! "$DO_AUTO" =~ ^[Nn]$ ]]; then
            A32=0; A64=0
            while IFS= read -r -d '' exe; do
                [[ $(file "$exe") == *"PE32+"* ]] && ((A64++)) || ((A32++))
            done < <(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" -print0)
            DETECTED=$([[ $A64 -gt 0 && $A32 -eq 0 ]] && echo "64" || [[ $A32 -gt 0 && $A64 -eq 0 ]] && echo "32" || echo "UNKNOWN")
            if [ "$DETECTED" != "UNKNOWN" ]; then
                echo -e "\n${GREEN}Detected ${DETECTED}-bit. Correct? (Y/n): ${NC}"
                echo -e -n "> "
                read -r CONF
                if [[ ! "$CONF" =~ ^[Nn]$ ]]; then ARCH="$DETECTED"; fi
            fi
        fi
    fi
    if [ "$ARCH" == "MANUAL" ]; then
        echo -e "\n${YELLOW}Architecture (32/64): ${NC}"
        echo -e -n "> "
        read -r ARCH
    fi
    ARCH_FOLDER=$([ "$ARCH" == "64" ] && echo "Win64" || echo "Win32")

    # 9. Automatic DLL Override
    echo ""
    print_divider
    echo -e "${CYAN}9. Automatic DLL Override${NC}"
    print_line
    echo ""
    echo -e "${WHITE}Wine needs to be told to use the new dsound.dll file instead of its built-in one."
    echo -e "We can inject this rule directly into the Wine prefix registry so you don't have to"
    echo -e "manually type WINEDLLOVERRIDES=\"dsound=n\" %command% into your launcher.${NC}"
    echo -e "\n${YELLOW}Automatically set dsound.dll override in Wine registry? (Y/n): ${NC}"
    echo -e -n "> "
    read -r AUTO_OVERRIDE

    # ==============================================================================
    # PHASE 2: EXECUTION
    # ==============================================================================
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- PHASE 2: EXECUTION ---${NC}"
    print_line
    echo -e "\n${CYAN}${BOLD}Configuration finished!${NC}"
    echo -e -n "${CYAN}Ready to deploy files to the game directory. Proceed? (Y/n): ${NC}"; read -r CONFIRM_FIN
    if [[ "$CONFIRM_FIN" =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Installation aborted.${NC}"
        exit 0
    fi

    if [ "$LAUNCHER_TYPE" == "1" ]; then
        echo -e "\n${CYAN}STATUS: Executing 'openal' verb via protontricks (Silent Mode)...${NC}"
        protontricks "$APPID" -q openal
    else
        echo -e "\n${CYAN}STATUS: Executing 'openal' verb via winetricks (Silent Mode)...${NC}"
        WINEPREFIX="$PREFIX_PATH" winetricks -q openal
    fi
    echo -e " -> ${GREEN}OpenAL trick applied.${NC}"

    echo -e "\n${CYAN}STATUS: Deploying files to game folder...${NC}"

    if [ "$ENGINE_CHOICE" == "1" ]; then
        TARGET_COMMUNITY=$(find "$DSOAL_COMMUNITY" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)

        if handle_conflict "$GAME_DIR/dsound.dll"; then
            echo -e " -> Linking: dsound.dll (Community Edition)"
            ln -sf "$TARGET_COMMUNITY/dsound.dll" "$GAME_DIR/dsound.dll"
        fi

        if handle_conflict "$GAME_DIR/dsoal-aldrv.dll"; then
            echo -e " -> Linking: dsoal-aldrv.dll (Community Edition)"
            ln -sf "$TARGET_COMMUNITY/dsoal-aldrv.dll" "$GAME_DIR/dsoal-aldrv.dll"
        fi

        if [ -d "$DSOAL_COMMUNITY/HRTF" ]; then
            echo -e " -> Deploying HRTF profile directory"
            mkdir -p "$GAME_DIR/OpenAL/HRTF"
            ln -sf "$DSOAL_COMMUNITY/HRTF/"* "$GAME_DIR/OpenAL/HRTF/"
        fi
        echo -e " -> ${GREEN}Successfully deployed ThreeDeeJay Community DSOAL.${NC}"

    else
        TARGET_DSOAL=$(find "$DSOAL_OFFICIAL" -type d -ipath "*/${BASE_FOLDER}/${ARCH_FOLDER}" | head -n 1)
        TARGET_OAL=$(find "$OPENAL_OFFICIAL" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)

        if handle_conflict "$GAME_DIR/dsound.dll"; then
            echo -e " -> Linking: dsound.dll"
            ln -sf "$TARGET_DSOAL/dsound.dll" "$GAME_DIR/dsound.dll"
        fi

        if [ "$ENGINE_CHOICE" == "2" ]; then
            if handle_conflict "$GAME_DIR/dsoal-aldrv.dll"; then
                echo -e " -> Linking: dsoal-aldrv.dll (kcat DSOAL Stable)"
                ln -sf "$TARGET_DSOAL/dsoal-aldrv.dll" "$GAME_DIR/dsoal-aldrv.dll"
            fi
            echo -e " -> ${GREEN}Successfully deployed kcat DSOAL.${NC}"
        else
            if handle_conflict "$GAME_DIR/dsoal-aldrv.dll"; then
                echo -e " -> Linking: dsoal-aldrv.dll (Latest OpenAL Soft)"
                ln -sf "$TARGET_OAL/soft_oal.dll" "$GAME_DIR/dsoal-aldrv.dll"
            fi
            echo -e " -> ${GREEN}Successfully deployed kcat Latest OpenAL Soft Engine.${NC}"
        fi
    fi

    # Legacy VXD Dummy
    if [[ ! "$LEGACY_VXD" =~ ^[Nn]$ ]]; then
        if handle_conflict "$GAME_DIR/dsound.vxd"; then
            echo -e " -> Creating dummy: dsound.vxd"
            touch "$GAME_DIR/dsound.vxd"
        fi
    fi

    # Advanced Tweaks Dummies
    if [[ "$ADVANCED_DUMMY" =~ ^[Yy]$ ]]; then
        if handle_conflict "$GAME_DIR/eax.dll"; then
            echo -e " -> Creating dummy: eax.dll (Advanced Option)"
            touch "$GAME_DIR/eax.dll"
        fi
        if handle_conflict "$GAME_DIR/eaxunified.dll"; then
            echo -e " -> Creating dummy: eaxunified.dll (Advanced Option)"
            touch "$GAME_DIR/eaxunified.dll"
        fi
    fi

    echo -e "\n${CYAN}STATUS: Generating Linux-optimised alsoft.ini...${NC}"
    if handle_conflict "$GAME_DIR/alsoft.ini"; then
        ALSOFT_HRTF=$([[ "$ENABLE_HRTF" =~ ^[Yy]$ ]] && echo "true" || echo "false")

        if [[ "$ADVANCED_LIMITS" =~ ^[Yy]$ ]]; then
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux (Advanced Tweaks)

[General]
hrtf = $ALSOFT_HRTF
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

# Advanced Audio Limit Expansion
sources = 256
frequency = 48000

[decoder]
resampler = cubic
EOF
            echo -e " -> ${GREEN}Created Advanced alsoft.ini with expanded channel limits.${NC}"
        else
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux

[General]
hrtf = $ALSOFT_HRTF
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

[decoder]
resampler = cubic
EOF
            echo -e " -> ${GREEN}Created standard custom alsoft.ini in game folder.${NC}"
        fi
    fi

    if [[ "$INJECT_REGISTRY" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}STATUS: Injecting DirectSound COM routing into Registry...${NC}"
        REG_FILE="/tmp/dsoal_registry_fix_$$.reg"
        echo -e " -> Generating temporary registry patch: $REG_FILE"
        cat <<EOF > "$REG_FILE"
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"
EOF
        echo -e " -> Injecting keys into Wine prefix..."
        if [ "$LAUNCHER_TYPE" == "1" ]; then protontricks -c "regedit \"$REG_FILE\"" "$APPID" &>/dev/null
        else WINEPREFIX="$PREFIX_PATH" wine regedit "$REG_FILE" &>/dev/null; fi
        rm -f "$REG_FILE"
        echo -e " -> ${GREEN}Registry keys injected successfully.${NC}"
    else
        echo -e "\n${YELLOW}STATUS: Skipping COM Registry Injection based on user input.${NC}"
    fi

    if [[ ! "$AUTO_OVERRIDE" =~ ^[Nn]$ ]]; then
        echo -e "\n${CYAN}STATUS: Injecting WINEDLLOVERRIDES into Wine prefix...${NC}"
        OVR_REG_FILE="/tmp/dsoal_override_$$.reg"
        cat <<EOF > "$OVR_REG_FILE"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"dsound"="native,builtin"
EOF
        echo -e " -> Injecting DLL override keys..."
        if [ "$LAUNCHER_TYPE" == "1" ]; then protontricks -c "regedit \"$OVR_REG_FILE\"" "$APPID" &>/dev/null
        else WINEPREFIX="$PREFIX_PATH" wine regedit "$OVR_REG_FILE" &>/dev/null; fi
        rm -f "$OVR_REG_FILE"
        echo -e " -> ${GREEN}DLL Override injected successfully.${NC}"
    fi

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- INSTALLATION COMPLETE! ---${NC}"
    print_line

    if [[ ! "$AUTO_OVERRIDE" =~ ^[Nn]$ ]]; then
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}The DLL Override was handled automatically! Just hit Play.${NC}"
        echo -e " 2. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}\n"
    else
        echo -e "\n${YELLOW}${BOLD}Final Steps to activate EAX:${NC}"
        echo -e " 1. ${YELLOW}${BOLD}Set the Override:${NC} ${WHITE}Apply the WINEDLLOVERRIDES rule (see below).${NC}"
        echo -e " 2. ${YELLOW}${BOLD}Launch the game:${NC} ${WHITE}Start the game as you normally would.${NC}"
        echo -e " 3. ${YELLOW}${BOLD}In-Game Settings:${NC} ${WHITE}Go to Audio settings and enable 'EAX', '3D Sound', or 'Hardware Acceleration'.${NC}\n"

        if [ "$LAUNCHER_TYPE" == "1" ]; then
            echo -e "${BOLD}Steam Launch Options:${NC}"
            echo -e "${CYAN}WINEDLLOVERRIDES=\"dsound=n\" %command%${NC}"
        else
            echo -e "${BOLD}Heroic Environment Variable:${NC}"
            echo -e "Name:  ${CYAN}WINEDLLOVERRIDES${NC}"
            echo -e "Value: ${CYAN}dsound=n${NC}"
        fi
    fi
    echo ""
fi
