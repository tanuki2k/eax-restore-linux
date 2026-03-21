#!/usr/bin/env bash

# DSOAL Installer for Linux (Steam/Heroic)
# Automates downloading and extracting DSOAL to restore EAX audio

echo "=========================================="
echo "      DSOAL Installer for Linux/Proton    "
echo "=========================================="

# 1. Get the game directory
read -p "Enter the full path to the game directory (where the .exe is located): " GAME_DIR

# Expand tilde (~) to the home directory if the user typed it
GAME_DIR="${GAME_DIR/#\~/$HOME}"

if [ ! -d "$GAME_DIR" ]; then
    echo "Error: Directory '$GAME_DIR' does not exist. Please check the path."
    exit 1
fi

echo "Game directory set to: $GAME_DIR"

# 2. Setup a temporary directory for safe downloading
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR" || exit

echo "Downloading the latest DSOAL release from GitHub..."
# Using the stable 'latest-master' tag that is automatically updated by GitHub Actions
DOWNLOAD_URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"

if ! curl -sL "$DOWNLOAD_URL" -o DSOAL_master.zip; then
    echo "Error: Failed to download DSOAL from GitHub. Check your internet connection."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "Extracting files..."
unzip -q DSOAL_master.zip

# The release usually contains a nested zip with the build version, let's extract that too
NESTED_ZIP=$(find . -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
if [ -n "$NESTED_ZIP" ]; then
    unzip -q "$NESTED_ZIP"
fi

# 3. Ask for Architecture
echo "Most older games with EAX support are 32-bit. If you are unsure, press Enter for 32-bit."
read -p "Do you need the 32-bit or 64-bit version? (Enter 32 or 64, default 32): " ARCH_CHOICE

if [ "$ARCH_CHOICE" == "64" ]; then
    DLL_DIR=$(find . -type d -name "Win64" | head -n 1)
else
    DLL_DIR=$(find . -type d -name "Win32" | head -n 1)
fi

if [ -z "$DLL_DIR" ]; then
    echo "Error: Could not find the extracted DLL folders. The archive structure might have changed."
    cd ~
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 4. Copy the files
echo "Installing DLLs to $GAME_DIR..."
cp "$DLL_DIR/dsound.dll" "$GAME_DIR/"
cp "$DLL_DIR/dsoal-aldrv.dll" "$GAME_DIR/"

# 5. Cleanup
cd ~
rm -rf "$TEMP_DIR"

echo "=========================================="
echo "Installation complete!"
echo "Don't forget to configure your launcher to use the override."
echo "=========================================="
