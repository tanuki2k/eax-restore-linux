#!/usr/bin/env bash

# DSOAL & OpenAL Automated Installer
# Works for Steam (via protontricks) and Heroic/GOG (via winetricks)

echo "=========================================="
echo "   DSOAL & OpenAL Universal Installer    "
echo "=========================================="

# 1. Get Game Location
read -p "Enter the full path to the game's .exe folder: " GAME_DIR
GAME_DIR="${GAME_DIR/#\~/$HOME}"

if [ ! -d "$GAME_DIR" ]; then
    echo "Error: Folder not found. Please double-check the path."
    exit 1
fi

# 2. Handle Audio Dependencies (OpenAL)
echo "------------------------------------------"
echo "Choose your launcher:"
echo "1) Steam"
echo "2) Heroic / GOG / Other"
read -p "Selection (1 or 2): " LAUNCHER_TYPE

if [ "$LAUNCHER_TYPE" == "1" ]; then
    # STEAM PATH
    read -p "Enter the Steam AppID: " APPID
    if command -v protontricks &> /dev/null; then
        echo "Installing OpenAL via Protontricks..."
        protontricks "$APPID" openal
    else
        echo "Error: 'protontricks' not found. Please install it (e.g., via Flatpak)."
    fi
else
    # HEROIC/GOG PATH
    echo "Tip: In Heroic, find the 'Wine Prefix' path in the game settings."
    read -p "Enter the path to the game's Wine Prefix: " PREFIX_PATH
    PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"

    if [ -d "$PREFIX_PATH" ]; then
        if command -v winetricks &> /dev/null; then
            echo "Installing OpenAL into prefix..."
            WINEPREFIX="$PREFIX_PATH" winetricks openal
        else
            echo "Error: 'winetricks' not found. Please install it."
        fi
    else
        echo "Error: Prefix path not found. Skipping OpenAL install."
    fi
fi

# 3. Download & Extract DSOAL
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || exit

echo "Downloading DSOAL..."
URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
curl -sL "$URL" -o dsoal.zip || { echo "Download failed"; exit 1; }

unzip -q dsoal.zip
NESTED=$(find . -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
[ -n "$NESTED" ] && unzip -q "$NESTED"

# 4. Select Architecture (Fixes the 'Game Won't Load' issue)
echo "------------------------------------------"
echo "Architecture Selection:"
echo "1) 32-bit (Recommended for 99% of EAX games)"
echo "2) 64-bit"
read -p "Selection (1 or 2): " ARCH_FIX

if [ "$ARCH_FIX" == "2" ]; then
    DLL_SRC=$(find . -type d -name "Win64" | head -n 1)
else
    DLL_SRC=$(find . -type d -name "Win32" | head -n 1)
fi

# 5. Finalize
if [ -n "$DLL_SRC" ]; then
    cp "$DLL_SRC/dsound.dll" "$GAME_DIR/"
    cp "$DLL_SRC/dsoal-aldrv.dll" "$GAME_DIR/"
    echo "Successfully installed DLLs to $GAME_DIR"
else
    echo "Error: Could not find DLLs in the archive."
fi

rm -rf "$TEMP_DIR"
echo "=========================================="
echo "DONE! Launch options remain the same:"
echo "WINEDLLOVERRIDES=\"dsound=n,b\" %command%"
echo "=========================================="
