#!/usr/bin/env bash
# Dev helper for adding a game's Game Settings: finds which config files a game
# writes, what its exes call their sound options, and exactly what changes when
# a setting is switched in-game. Read-only towards the game — snapshots are
# copies under ~/.cache/eax-probe/. Not part of the shipped script.
#
# Usage: tools/probe-game.sh scan <game dir> [prefix]
#            Config files (with line endings), setting names in the game's
#            exes, its OpenAL DLL and any Miles 3D providers.
#        tools/probe-game.sh snap <name> [<game dir> [prefix]]
#            Copies every config file into the next numbered snapshot. The
#            folders are remembered from the first snap, so later ones only
#            need the name.
#        tools/probe-game.sh diff <name> [<from> <to>]
#            What changed between two snapshots (default: the last two).
#
# The usual round: snap before the first launch, snap after quitting at the
# main menu (the defaults), switch the EAX options on in-game, quit and snap
# again. diff 0 1 shows which file the game creates and where; diff 1 2 shows
# the exact keys and values to put in the game's entry.
set -euo pipefail

CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/eax-probe"
CONFIG_RE='.*\.(cfg|ini|ltx|gdb|con)$'
# Prefix folders where games keep their settings, below drive_c/users/<user>.
USER_DIRS=("Documents" "My Documents" "AppData" "Application Data" "Saved Games")
# Paths under those that are Wine's or Windows' own, never the game's.
NOISE_RE='/(Microsoft|Temp|wine_gecko|Mozilla|Steam|Valve|GOG\.com/Galaxy)/'
# DLLs that ship with every other game and never hold its setting names.
SKIP_DLL_RE='^(binkw?32|mss32|openal32|soft_oal|wrap_oal|dsound|dsoal-aldrv|steam_api(64)?|d3d.*|dxgi|msvc.*|vcruntime.*|ucrtbase|goggame-.*|galaxy(64)?|sdl2?|nvngx.*|sl\..*|amd_.*|gfsdk.*|dxcompiler|lua51|dbghelp|bugtrap)\.dll$'

die() { echo "$*" >&2; exit 1; }

# Usage: config_files <dir>...
# Every config file under the game folder, and under the prefix's user folders
# when a prefix is given, one absolute path per line.
config_files() {
    local game="$1" prefix="${2:-}" u d
    find "$game" -maxdepth 5 -type f -regextype posix-extended -iregex "$CONFIG_RE" 2>/dev/null
    [ -n "$prefix" ] || return 0
    for u in "$prefix"/drive_c/users/*/; do
        # Wine links users/<you> to users/steamuser; only look once.
        [ -L "${u%/}" ] && continue
        for d in "${USER_DIRS[@]}"; do
            [ -d "$u$d" ] || continue
            find "$u$d" -maxdepth 6 -type f -regextype posix-extended -iregex "$CONFIG_RE" 2>/dev/null
        done
    done | grep -v -E "$NOISE_RE" || true
}

# Usage: line_endings <file>
line_endings() {
    if ! LC_ALL=C grep -qI '' "$1" 2>/dev/null; then echo "binary"
    elif LC_ALL=C grep -q $'\r$' "$1" 2>/dev/null; then echo "CRLF"
    else echo "LF"; fi
}

cmd_scan() {
    local game="${1:-}" prefix="${2:-}" f name
    [ -d "$game" ] || die "Usage: $0 scan <game dir> [prefix]"
    [ -z "$prefix" ] || [ -d "$prefix/drive_c" ] || die "$prefix isn't a Wine prefix (no drive_c)."

    echo "== Config files"
    config_files "$game" "$prefix" | sort | while IFS= read -r f; do
        printf '  %-6s %8s  %s  %s\n' "$(line_endings "$f")" "$(stat -c %s "$f")" \
            "$(date -r "$f" '+%F %R')" "${f/#$HOME/\~}"
    done

    echo; echo "== Setting names in the game's binaries"
    find "$game" -maxdepth 2 -type f \( -iname '*.exe' -o -iname '*.dll' \) | sort | while IFS= read -r f; do
        name="$(basename "$f")"
        [[ "${name,,}" =~ $SKIP_DLL_RE ]] && continue
        [[ "${name,,}" =~ ^(unins[0-9]*|.*setup.*|.*redist.*|vc_?redist.*|dxsetup)\.exe$ ]] && continue
        local hits
        hits="$(strings -n 4 "$f" | grep -a -i -E \
            '\.(cfg|ini|ltx|gdb)$|eax|efx|a3d|3d ?sound|sound.*(provider|hardware|quality|device)|^snd_|reverb|environment(al)? audio' \
            | grep -v -E '@@|^\?|^\.\?A' | sort -u | head -40 || true)"
        [ -n "$hits" ] || continue
        echo "  $name:"
        printf '      %s\n' "${hits//$'\n'/$'\n      '}"
    done

    echo; echo "== OpenAL"
    local found=0
    while IFS= read -r f; do
        found=1
        local ver kind
        ver="$(strings -n 6 "$f" | grep -m1 -o -E 'ALSOFT [0-9.]+' || true)"
        if [ -n "$ver" ]; then kind="OpenAL Soft ${ver#ALSOFT }"
        elif [ -f "$(dirname "$f")/wrap_oal.dll" ]; then kind="Creative router (wrap_oal.dll next to it: DirectSound3D path)"
        else kind="not OpenAL Soft"; fi
        printf '  %s: %s, %s\n' "${f#"$game"/}" "$kind" "$(file -b "$f" | cut -d, -f1-2)"
    done < <(find "$game" -maxdepth 3 -type f \( -iname 'openal32.dll' -o -iname 'soft_oal.dll' \))
    [ "$found" -eq 1 ] || echo "  (none bundled)"

    local m3d
    m3d="$(find "$game" -maxdepth 3 -type f -iname '*.m3d' | sort)"
    if [ -n "$m3d" ]; then
        echo; echo "== Miles 3D providers"
        while IFS= read -r f; do
            # The provider's display name is the first vendor/API string that isn't
            # an error message; strings keeps the length byte in front of it.
            printf '  %-14s %s\n' "$(basename "$f")" "$(strings -n 6 "$f" \
                | grep -v -i -E 'error|fail|could|unable|missing|_AIL_|@' \
                | grep -m1 -E '^[^A-Za-z]?(Miles|Creative|Dolby|DirectSound|RAD Game Tools|Aureal|Sensaura|QSound)' \
                | sed 's/^[^A-Za-z]//' || true)"
        done <<< "$m3d"
    fi
}

cmd_snap() {
    local name="${1:-}" game="${2:-}" prefix="${3:-}" dir n f
    [ -n "$name" ] || die "Usage: $0 snap <name> [<game dir> [prefix]]"
    dir="$CACHE/$name"
    if [ -n "$game" ]; then
        [ -d "$game" ] || die "$game isn't a folder."
        mkdir -p "$dir"
        printf '%s\n%s\n' "$(realpath "$game")" "${prefix:+$(realpath "$prefix")}" > "$dir/.folders"
    fi
    [ -f "$dir/.folders" ] || die "First snap for $name needs the game folder: $0 snap $name <game dir> [prefix]"
    { IFS= read -r game; IFS= read -r prefix || true; } < "$dir/.folders"

    n=0; while [ -d "$dir/$n" ]; do n=$((n + 1)); done
    mkdir -p "$dir/$n"
    local count=0
    while IFS= read -r f; do
        # Keep the full path under the snapshot so files from the game folder and
        # the prefix can't collide, and diff shows where each one lives.
        mkdir -p "$dir/$n$(dirname "$f")"
        cp -p "$f" "$dir/$n$f"
        count=$((count + 1))
    done < <(config_files "$game" "$prefix")
    echo "Snapshot $n of $name: $count config files ($dir/$n)"
}

cmd_diff() {
    local name="${1:-}" from="${2:-}" to="${3:-}" dir last
    [ -n "$name" ] || die "Usage: $0 diff <name> [<from> <to>]"
    dir="$CACHE/$name"
    [ -d "$dir/0" ] || die "No snapshots for $name yet."
    last=0; while [ -d "$dir/$((last + 1))" ]; do last=$((last + 1)); done
    if [ -z "$from" ]; then
        [ "$last" -ge 1 ] || die "Only one snapshot of $name so far — snap again after running the game."
        from=$((last - 1)); to=$last
    fi
    [ -d "$dir/$from" ] && [ -d "$dir/$to" ] || die "Snapshots are 0 to $last."
    echo "== $name: snapshot $from → $to"
    # -N shows a file the game created as all-new lines; CR is ignored so the
    # diff shows values, not line endings (scan reports those).
    (cd "$dir" && diff -ruN --strip-trailing-cr "$from" "$to") | grep -v "^diff -ruN" | sed "s|$HOME|~|g" || true
}

case "${1:-}" in
    scan) shift; cmd_scan "$@" ;;
    snap) shift; cmd_snap "$@" ;;
    diff) shift; cmd_diff "$@" ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 1 ;;
esac
