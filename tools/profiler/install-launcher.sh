#!/usr/bin/env bash
# Adds (or with --remove, deletes) the "EAX profile editor" entry in the app menu.
# Usage: tools/profiler/install-launcher.sh [--remove]
set -eu
if [ $# -gt 0 ] && [ "$1" != "--remove" ]; then
    echo "Usage: tools/profiler/install-launcher.sh [--remove]" >&2
    exit 1
fi
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
dest="${XDG_DATA_HOME:-$HOME/.local/share}/applications/eax-profiler.desktop"
if [ "${1:-}" == "--remove" ]; then
    rm -f "$dest"
    echo "Removed $dest"
else
    mkdir -p "$(dirname "$dest")"
    # The repo's file finds the launcher beside itself (%k); the installed copy names it outright.
    # Quoted the way the desktop-entry spec asks: \ " ` $ escaped, and % doubled.
    # awk puts it in, since sed would read an & or | in the path as its own.
    quoted="$here/eax-profiler"
    quoted="${quoted//\\/\\\\\\\\}"; quoted="${quoted//\"/\\\"}"; quoted="${quoted//\`/\\\`}"
    quoted="${quoted//\$/\\\$}"; quoted="${quoted//%/%%}"
    EXEC_LINE="Exec=\"$quoted\"" awk '/^Exec=/ { print ENVIRON["EXEC_LINE"]; next } { print }' "$here/eax-profiler.desktop" > "$dest"
    chmod +x "$dest"
    echo "Added \"EAX profile editor\" to the app menu ($dest)"
fi
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$(dirname "$dest")" 2>/dev/null || true
