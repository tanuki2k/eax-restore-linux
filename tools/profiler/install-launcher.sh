#!/usr/bin/env bash
# Adds (or with --remove, deletes) the "EAX profile editor" entry in the app menu.
# Usage: tools/profiler/install-launcher.sh [--remove]
set -eu
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dest="${XDG_DATA_HOME:-$HOME/.local/share}/applications/eax-profiler.desktop"
if [ "${1:-}" == "--remove" ]; then
    rm -f "$dest"
    echo "Removed $dest"
else
    mkdir -p "$(dirname "$dest")"
    # The repo's file finds the launcher beside itself (%k); the installed copy names it outright.
    sed "s|^Exec=.*|Exec=\"$here/eax-profiler\"|" "$here/eax-profiler.desktop" > "$dest"
    chmod +x "$dest"
    echo "Added \"EAX profile editor\" to the app menu ($dest)"
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$dest")" 2>/dev/null || true
