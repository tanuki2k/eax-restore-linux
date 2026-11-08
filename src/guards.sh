# ==============================================================================
# GUARDS (ROOT & GAMING MODE)
# ==============================================================================
if [ "$EUID" -eq 0 ]; then
    print_banner "ERROR: ROOT PRIVILEGES DETECTED" "$YELLOW"
    print_paragraph "Running Wine or Protontricks as root will permanently break your prefix permissions." \
        "Run the script normally. It will ask for sudo only if installing system tools."
    exit 1
fi

if [ -n "$SteamEnv" ] || [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
    print_banner "ERROR: GAMING MODE DETECTED" "$YELLOW"
    print_paragraph "This script requires keyboard input and terminal interaction." \
        "Please switch to Desktop Mode and run this script via Konsole or your preferred terminal."
    exit 1
fi
