#!/usr/bin/env bash

# ==============================================================================
# DSOAL & OpenAL Soft Universal Installer for Linux
# ==============================================================================
#
# A streamlined Bash script designed to automate the restoration of EAX 3D
# audio in older Windows games running on Linux via Steam or Heroic.
#
# --- Features ---
# * Dual-Copy Architecture: Deploys DSOAL/OpenAL files to both the local game
#   folder and the Wine/Proton prefix system folders, with conflict backups
#   on both — not just the game folder.
#
# * Engine Choice: Toggle between ThreeDeeJay Community, PCGamingWiki (self-
#   hosted mirror), or kcat's official DSOAL + OpenAL Soft builds.
#
# * Recent Games: Remembers game folders you've used before and offers them
#   as a quick pick, without giving up the option to enter a new path.
#
# * Smart Detection: Opt-in auto-detection for Steam AppIDs and Heroic Wine
#   prefixes.
#
# * Proton Detection: Identifies Proton runners even within Heroic environments.
#
# * Deep Validation: Confirms Heroic/GOG prefixes are initialised via drive_c,
#   and points you to launch the game first if the prefix isn't ready yet.
#
# * Architecture Detection: Scans the game's .exe files for 32-bit vs 64-bit
#   PE headers to auto-select the matching wrapper build, with a manual
#   fallback if detection is inconclusive.
#
# * Interactive Conflicts: Existing files are backed up (timestamped) before
#   being overwritten, and restored automatically on uninstall.
#
# * Install Manifest: Tracks exactly what each install deployed — files and
#   registry keys alike — so uninstall only ever removes what this script
#   actually put there, never guesses by filename, and safely no-ops if run
#   again on an already-uninstalled game.
#
# * Checksum Verification: Pinned SHA256 hashes for the community builds, and
#   live verification against GitHub's published digests for kcat's official
#   builds, with a clear prompt if a file can't be verified either way.
#
# * Hardened Downloads: Fails loudly on bad HTTP responses, verifies zip
#   integrity before extracting, and preserves the existing cache instead of
#   wiping it on a failed download.
#
# * Pre-Flight Dependency Check: Verifies curl, unzip, file, protontricks,
#   winetricks, wine, and jq are available before touching the cache, and
#   offers to auto-install anything missing via your distro's package
#   manager (skipped in favour of Discover on SteamOS, per Safety Guards).
#
# * Advanced Tweaks: Optional EAX Unified dummies, COM registry routing,
#   expanded audio limits, and HRTF headphone profiles.
#
# * Auto-Overrides: Injects WINEDLLOVERRIDES natively into the Wine registry,
#   tracked so uninstall can clean it up automatically without re-prompting.
#
# * Hybrid Dependencies: Falls back to a direct Microsoft download for the
#   VC++ 2022 Redistributable when winetricks/protontricks fails, verifying
#   the actual runtime DLLs on disk rather than trusting exit codes. Uninstall
#   can offer to remove it again too, with a warning since a prefix may be
#   shared by other games or apps.
#
# * Safety Guards: Refuses to run as root or from Steam's Gaming Mode, and
#   won't auto-modify SteamOS's immutable filesystem.
#
# --- Environment Variables ---
# * EAX_RESTORE_SKIP_PREFLIGHT=1  Skips the pre-flight tool scan and its
#   auto-install prompts, trusting that curl, unzip, file, protontricks,
#   winetricks, and wine are already available. Speeds up repeat runs on a
#   machine you've already verified.
#
# * EAX_RESTORE_DSOAL_COMMUNITY_V13=1  Pre-selects the ThreeDeeJay Community
#   DSOAL engine (option 1), skipping the (i)nstall/(u)ninstall menu (goes
#   straight to install) and the interactive engine-selection prompt.
#
# * EAX_RESTORE_DSOAL_COMMUNITY_V14=1  Pre-selects the PCGamingWiki Community
#   DSOAL engine (option 2, self-hosted mirror) with the same effect.
#
# * EAX_RESTORE_DSOAL_OFFICIAL=1  Pre-selects kcat's official DSOAL + OpenAL
#   Soft engine (option 3) with the same effect.
#   Only set one EAX_RESTORE_DSOAL_* variable at a time.
#
# * EAX_RESTORE_VCRUN_ONLY=1  Skips the full install/uninstall flow and just
#   (re)installs the MS VC++ 2022 Redistributable into a game's prefix.
#   Useful if you skipped that step during a normal install and want to go
#   back for it without redoing everything else.
#
# * EAX_RESTORE_NO_LOG=1  Turns off the per-run log file. Normally every run
#   is logged to ~/.local/state/eax-restore-linux/logs/ (newest 10 kept,
#   latest.log points at the most recent) for attaching to bug reports.
#
# --- License ---
# MIT License
# Copyright (c) 2026 Tanuki2k
# ==============================================================================

# --- Build Info ---
SCRIPT_VERSION="0.28.2"
SCRIPT_DATE="2026-09-25"

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
print_divider() { echo -e "${CYAN}----------------------------------------------------------${NC}"; }
print_line() { echo -e "${CYAN}----------------------------------------------------------${NC}"; }
is_truthy() { [[ "${1,,}" =~ ^(1|true|yes|y)$ ]]; }
is_genuine_dll() {
    # Usage: is_genuine_dll <path>
    # Wine creates a "fake DLL" placeholder file with the real DLL's name in
    # system32/syswow64 for every one of its own builtin implementations, by
    # default, in every prefix — purely so apps that check "does this file
    # exist" before running don't refuse to start. These placeholders are
    # real PE files but contain no actual code, and Wine's own source embeds
    # a literal signature string in every one it generates: "Wine builtin
    # DLL" or "Wine placeholder DLL". A plain file-existence or non-empty
    # check can't tell a genuine installed DLL apart from one of these —
    # this checks for that signature so callers can. Returns true (0) only
    # for a file that exists, is non-empty, and does NOT carry that marker.
    local file="$1"
    [ -s "$file" ] || return 1
    grep -qa "Wine builtin DLL\|Wine placeholder DLL" "$file" 2>/dev/null && return 1
    return 0
}
parse_selection() {
    # Usage: parse_selection <total_count> <input_string>
    # Parses pacman-style selection syntax into the global SELECTED[1..N]
    # array (1 = keep/act on, 0 = skip). Empty input selects everything
    # (matches pressing Enter to accept pacman's full list). Plain numbers
    # or ranges ("1 2 3", "1-3") narrow the selection to only those. A "^"
    # prefix ("^4", "^1-3") always excludes — collected and applied in a
    # second pass after all inclusions, specifically so the order tokens
    # appear in doesn't matter ("^2 1-3" and "1-3 ^2" both correctly exclude
    # 2 — an earlier single-pass version let a later plain token's reset
    # silently wipe out an exclusion that appeared before it). Unrecognized
    # tokens are ignored rather than erroring, since this reads user input.
    local total="$1"
    local input="$2"
    local i

    SELECTED=()
    for ((i = 1; i <= total; i++)); do SELECTED[$i]=1; done

    [ -z "$input" ] && return

    input="${input//,/ }"
    local reset_done=0
    local token start end body
    local excludes=()

    for token in $input; do
        if [[ "$token" == ^* ]]; then
            excludes+=("$token")
            continue
        fi
        if [ "$reset_done" -eq 0 ]; then
            for ((i = 1; i <= total; i++)); do SELECTED[$i]=0; done
            reset_done=1
        fi
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            start="$token"; end="$token"
        else
            continue
        fi
        for ((i = start; i <= end && i <= total; i++)); do SELECTED[$i]=1; done
    done

    # Second pass: exclusions always win, applied last regardless of where
    # they appeared in the input.
    for token in "${excludes[@]}"; do
        body="${token#^}"
        if [[ "$body" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
        elif [[ "$body" =~ ^[0-9]+$ ]]; then
            start="$body"; end="$body"
        else
            continue
        fi
        for ((i = start; i <= end && i <= total; i++)); do SELECTED[$i]=0; done
    done
}

# ==============================================================================
# GUARDS (ROOT & GAMING MODE)
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

if [ -n "$SteamEnv" ] || [ -n "$STEAM_COMPAT_DATA_PATH" ]; then
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}--- ERROR: GAMING MODE DETECTED ---${NC}"
    print_line
    echo -e "${WHITE}This script requires keyboard input and terminal interaction.${NC}"
    echo -e "${WHITE}Please switch to Desktop Mode and run this script via Konsole or your preferred terminal.${NC}"
    exit 1
fi

# Paths
BASE_SHARE="$HOME/.local/share/eax-restore-linux"
RECENT_GAMES_FILE="$BASE_SHARE/recent_games.txt"
DSOAL_SHARE="$BASE_SHARE/dsoal"
DSOAL_OFFICIAL="$DSOAL_SHARE/official"
DSOAL_COMMUNITY_V13="$DSOAL_SHARE/community_v1.3"
DSOAL_COMMUNITY_V14="$DSOAL_SHARE/community_v1.4"
OPENAL_SHARE="$BASE_SHARE/openal-soft"
OPENAL_OFFICIAL="$OPENAL_SHARE/official"

# ==============================================================================
# RUN LOG
# ==============================================================================
# Every run gets its own timestamped log in $LOG_DIR (newest 10 kept, with
# latest.log always pointing at the current one; the path is shown on exit), so a bug report can attach
# the full picture: everything shown on screen, the output of the Wine /
# winetricks / protontricks calls that is hidden from the screen, a header
# with the system details the bug report template asks for, and a summary of
# what this run detected and chose. EAX_RESTORE_NO_LOG=1 turns it off.
# Dev builds (SCRIPT_VERSION stamped "<base>-dev" by build.sh) log to their
# own subfolder, so dev and stable runs never mix or rotate each other out.
# Logs are state data, so they live under $XDG_STATE_HOME (~/.local/state)
# per the XDG Base Directory spec, not beside the download cache.
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/eax-restore-linux/logs"
[[ "$SCRIPT_VERSION" == *-dev* ]] && LOG_DIR="$LOG_DIR/dev"
EAX_LOG_FILE="/dev/null"
BUG_REPORT_URL="https://github.com/tanuki2k/eax-restore-linux/issues/new?template=bug_report.md"

write_log_header() {
    local distro heroic_kind steam_kind
    distro=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-$NAME}")
    heroic_kind=""
    [ -d "$HOME/.config/heroic" ] && heroic_kind="native"
    [ -d "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" ] && heroic_kind="${heroic_kind:+$heroic_kind + }flatpak"
    steam_kind=""
    { [ -d "$HOME/.steam/steam" ] || [ -d "$HOME/.local/share/Steam" ]; } && steam_kind="native"
    [ -d "$HOME/.var/app/com.valvesoftware.Steam" ] && steam_kind="${steam_kind:+$steam_kind + }flatpak"
    {
        echo "=== eax-restore-linux run log ==="
        echo "Script version:  $SCRIPT_VERSION ($SCRIPT_DATE)"
        echo "Started:         $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "Distro:          ${distro:-unknown}"
        echo "Kernel:          $(uname -srm)"
        echo "Desktop:         ${XDG_CURRENT_DESKTOP:-unknown} (${XDG_SESSION_TYPE:-unknown})"
        echo "Steam install:   ${steam_kind:-not found}"
        echo "Heroic install:  ${heroic_kind:-not found}"
        echo "wine:            $(command -v wine &>/dev/null && wine --version 2>/dev/null || echo 'not in PATH')"
        echo "winetricks:      $(command -v winetricks &>/dev/null && winetricks --version 2>/dev/null | head -n 1 || echo 'not in PATH')"
        if command -v protontricks &>/dev/null; then echo "protontricks:    $(protontricks --version 2>/dev/null | head -n 1) (native)"
        elif command -v flatpak &>/dev/null && flatpak info com.github.Matoking.protontricks &>/dev/null; then echo "protontricks:    $(flatpak info com.github.Matoking.protontricks 2>/dev/null | awk -F': *' '/Version/ {print $2; exit}') (flatpak)"
        else echo "protontricks:    not found"; fi
        echo "jq:              $(command -v jq &>/dev/null && jq --version 2>/dev/null || echo 'not found')"
        echo "EAX_RESTORE_* set:"
        env | grep '^EAX_RESTORE_' | sed 's/^/  /' || true
        echo "================================="
        echo ""
    } >> "$EAX_LOG_FILE"
}

log_cmd() {
    # Usage: log_cmd <description>
    # Marks, in the log only, which command the following hidden output
    # (redirected with &>> "$EAX_LOG_FILE") came from.
    echo -e "\n[cmd $(date '+%H:%M:%S')] $*" >> "$EAX_LOG_FILE"
}

write_log_summary() {
    local rc="$1" runner="" last_section=""
    # Proton records its version next to the prefix (Steam: compatdata/<id>/
    # version beside pfx/; Heroic Proton prefixes keep it in the prefix root).
    if [ -n "$PREFIX_PATH" ]; then
        if [ -f "$(dirname "$PREFIX_PATH")/version" ]; then runner="Proton $(head -n 1 "$(dirname "$PREFIX_PATH")/version")"
        elif [ -f "$PREFIX_PATH/version" ]; then runner="Proton $(head -n 1 "$PREFIX_PATH/version")"; fi
        local heroic_conf
        heroic_conf=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/*.json" -exec grep -Fl "\"winePrefix\": \"$PREFIX_PATH\"" {} + 2>/dev/null | head -n 1)
        if [ -n "$heroic_conf" ]; then
            runner="${runner:+$runner; }Heroic runner: $(grep -A3 '"wineVersion"' "$heroic_conf" | grep '"name"' | head -n 1 | awk -F '"' '{print $4}') [$(grep -A3 '"wineVersion"' "$heroic_conf" | grep '"type"' | head -n 1 | awk -F '"' '{print $4}')]"
        fi
    fi
    # Last numbered step / banner reached, read back from the screen output
    # already in the log -- shows where a failed run stopped.
    last_section=$(grep -E '^[0-9]+\. [A-Z]|^--- .* ---$' "$EAX_LOG_FILE" | tail -n 1)
    {
        echo ""
        echo "=== Run summary ==="
        echo "Exit code:       $rc"
        echo "Finished:        $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "Last step:       ${last_section:-none}"
        [ -n "$GAME_NAME" ] && echo "Game name:       $GAME_NAME"
        echo "Game folder:     ${GAME_DIR:-not set}"
        echo "Launcher:        $(case "$LAUNCHER_TYPE" in 1) echo "Steam (AppID ${APPID:-unknown})";; 2) echo "Non-Steam / Heroic${HEROIC_APP_NAME:+ (app $HEROIC_APP_NAME)}";; *) echo "not detected";; esac)"
        echo "Prefix:          ${PREFIX_PATH:-not set}"
        echo "Runner:          ${runner:-unknown}${IS_PROTON:+ (IS_PROTON=$IS_PROTON)}"
        [ "$LAUNCHER_TYPE" == "2" ] && echo "Wine used:       ${WINE_CMD:-none}${WINESERVER_CMD:+ (wineserver $WINESERVER_CMD)}"
        echo "Architecture:    ${ARCH:-not set}"
        echo "Engine choice:   ${ENGINE_CHOICE:-not chosen} (DSOAL: ${DSOAL_VER:-?} | OpenAL Soft: ${OAL_VER:-?})"
        if [ -n "$INSTALL_MANIFEST" ] && [ -s "$INSTALL_MANIFEST" ]; then
            echo "Install manifest ($INSTALL_MANIFEST):"
            sed 's/^/  /' "$INSTALL_MANIFEST"
        fi
        echo "==================="
        # The VC++ installer keeps its own log (overwritten per install);
        # copy it in so this file alone is enough for a bug report.
        if [ -n "$VCRUN_LOG" ] && [ -s "$VCRUN_LOG" ]; then
            echo ""
            echo "--- vcrun2022 installer output ($VCRUN_LOG) ---"
            cat "$VCRUN_LOG"
            echo "--- end vcrun2022 installer output ---"
        fi
    } >> "$EAX_LOG_FILE"
}

finish_run_log() {
    local rc=$?
    trap - EXIT
    # Own line, with $HOME shown as ~, so the path fits the 76-column layout.
    echo -e "\n${WHITE}Log saved to:${NC}"
    echo -e "  ${GREEN}${EAX_LOG_FILE/#$HOME/\~}${NC}"
    if [ "$rc" -ne 0 ]; then
        echo -e "${YELLOW}If something went wrong, please attach this log to a bug report:${NC}"
        echo -e "${WHITE}$BUG_REPORT_URL${NC}"
    fi
    # Hand the terminal back and let tee drain before appending the summary,
    # so the summary really is the last thing in the file.
    exec 1>&3 2>&4 3>&- 4>&-
    local writer_pid
    writer_pid=$(cat "$EAX_LOG_FILE.pid" 2>/dev/null); rm -f "$EAX_LOG_FILE.pid"
    [ -n "$writer_pid" ] && timeout 5 tail --pid="$writer_pid" -f /dev/null 2>/dev/null
    write_log_summary "$rc"
    exit "$rc"
}

if ! is_truthy "${EAX_RESTORE_NO_LOG:-}" && mkdir -p "$LOG_DIR" 2>/dev/null; then
    EAX_LOG_FILE="$LOG_DIR/eax-restore-$(date +%Y%m%d-%H%M%S).log"
    ln -sfn "$(basename "$EAX_LOG_FILE")" "$LOG_DIR/latest.log"
    write_log_header
    # Keep the newest 10 (this run's included).
    ls -1t "$LOG_DIR"/eax-restore-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f --
    # Mirror everything on screen into the log, minus colour codes, with
    # curl's \r progress bars collapsed to their final state. tee and the
    # log writer run in their own session (setsid) so a Ctrl-C at the
    # terminal can't kill them before the "Log saved" line and summary are
    # written; the writer's PID is recorded so finish_run_log can wait for
    # it to drain.
    exec 3>&1 4>&2
    exec > >(exec setsid bash -c 'exec tee >(echo "$BASHPID" > "$1.pid"; exec sed -u -e "s/\x1b\[[0-9;]*[A-Za-z]//g" -e "s/.*\r//" >> "$1")' _ "$EAX_LOG_FILE") 2>&1
    trap finish_run_log EXIT
    # Turn Ctrl-C / kill into a normal exit with the conventional status, so
    # the EXIT trap above records the real exit code (not the last command's).
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

# Matches exactly what winetricks' own vcrun2022 verb overrides — Wine prefers
# its own (partial, ~80%-complete) builtin implementations of these DLLs over
# native ones by default, even when the real file is sitting right there on
# disk. Without this override, a game can crash on an "unimplemented
# function" that's simply missing from Wine's builtin, despite the genuine
# DLL being correctly installed and verified present.
VCRUN_DLL_NAMES=("concrt140" "msvcp140" "msvcp140_1" "msvcp140_2" "msvcp140_atomic_wait" "msvcp140_codecvt_ids" "vcamp140" "vccorlib140" "vcomp140" "vcruntime140" "vcruntime140_1")

DSOAL_OFFICIAL_URL="https://github.com/kcat/dsoal/releases/download/latest-master/DSOAL.zip"
DSOAL_OFFICIAL_API_URL="https://api.github.com/repos/kcat/dsoal/releases/tags/latest-master"
# Automatic fallback for when kcat's rolling latest-master release is missing
# (their CI deletes it before re-creating it, so a failed CI run leaves it
# gone) and there's no cached build to fall back on: one frozen revision from
# kcat's own "archive" release. Every already-superseded archive asset is
# static, so it has a stable SHA256 and can be hard-verified. To advance the
# pin, bump all three together (pick a revision that is no longer the newest).
DSOAL_PINNED_REV="r693"
DSOAL_PINNED_URL="https://github.com/kcat/dsoal/releases/download/archive/DSOAL_r693.zip"
DSOAL_PINNED_SHA256="5abe990ff5692fa070d549a8c28df2435842c5d3f586a59b0da5281bc1cb6605"
DSOAL_COMMUNITY_V13_URL="https://github.com/ThreeDeeJay/dsoal/releases/download/0.9.6/DSOAL+HRTF.zip"
DSOAL_COMMUNITY_V13_SHA256="271db46cffb086ffc0af06956ade3ee8e645e05fb108b5b6d1f74b733ecaf984"
# PCGamingWiki blocks automated/bot downloads from their site, so this build is
# re-hosted on our own GitHub release. The pinned SHA256 verifies the mirrored
# file matches what we uploaded; bump it whenever the mirrored zip is updated.
DSOAL_COMMUNITY_V14_URL="https://github.com/tanuki2k/eax-restore-linux/releases/download/assets/DSOALv1.4.zip"
DSOAL_COMMUNITY_V14_SHA256="064f600eac5637d8a8ea6b6cd0172b42202b792406530bf867c0144e722e7414"

# ==============================================================================
# CORE FUNCTIONS
# ==============================================================================
find_local_wine() {
    local search_paths=("$HOME/.config/heroic/tools" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic/tools")
    local found_wine=""
    for path in "${search_paths[@]}"; do
        if [ -d "$path" ]; then
            found_wine=$(find "$path" -type f -path "*/bin/wine" -executable 2>/dev/null | head -n 1)
            [ -n "$found_wine" ] && break
        fi
    done
    echo "$found_wine"
}

record_recent_game() {
    # Usage: record_recent_game <path>
    # Adds/moves a game directory to the top of the recent-games history
    # (most-recently-used first), deduped, capped at 10 entries. Best-effort
    # — never blocks anything if it fails to write.
    local path="$1"
    mkdir -p "$BASE_SHARE" 2>/dev/null
    local tmp
    tmp=$(mktemp 2>/dev/null) || return
    { echo "$path"; [ -f "$RECENT_GAMES_FILE" ] && grep -Fxv "$path" "$RECENT_GAMES_FILE"; } | head -n 10 > "$tmp" 2>/dev/null
    mv "$tmp" "$RECENT_GAMES_FILE" 2>/dev/null
}

prompt_recent_game() {
    # Usage: prompt_recent_game
    # If a recent-games history exists, offers a numbered pick list plus the
    # option to enter a new path. For uninstall specifically, the list is
    # filtered to only games that actually have something installed via
    # this script right now — a folder with no manifest, or one that's just
    # the "already uninstalled" sentinel, has nothing to act on and would
    # only clutter the picker. Install shows every visited folder, since
    # revisiting any of them (installed before or not) is meaningful there.
    # Sets GAME_DIR and returns 0 if the user picked an existing entry;
    # returns 1 (GAME_DIR left empty) if they chose to enter a new path, or
    # if there's no usable history — callers fall through to manual entry.
    GAME_DIR=""
    [ -f "$RECENT_GAMES_FILE" ] || return 1

    local paths=()
    local p manifest
    while IFS= read -r p; do
        [ -n "$p" ] && [ -d "$p" ] || continue
        if [ "$SCRIPT_ACTION" == "u" ]; then
            manifest="$p/.eax-restore-manifest.txt"
            [ -s "$manifest" ] || continue
            head -n 1 "$manifest" | grep -q "^# EAX Restore: uninstalled" && continue
        fi
        paths+=("$p")
    done < "$RECENT_GAMES_FILE"

    [ ${#paths[@]} -eq 0 ] && return 1

    if [ "$SCRIPT_ACTION" == "u" ]; then
        echo -e "${WHITE}Games with something installed via this script:${NC}"
    else
        echo -e "${WHITE}Previously used game folders:${NC}"
    fi
    local i
    for i in "${!paths[@]}"; do
        echo -e "${WHITE} $((i + 1))) ${paths[$i]}${NC}"
    done
    echo -e "${WHITE} 0) Enter a different path${NC}\n"

    echo -e "${YELLOW}Selection [0-${#paths[@]}]: ${NC}"
    echo -e -n "> "
    local choice
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#paths[@]} ]; then
        GAME_DIR="${paths[$((choice - 1))]}"
        return 0
    fi
    return 1
}

get_game_directory() {
    GAME_DIR=""

    if [ "$SCRIPT_ACTION" == "u" ] && prompt_recent_game; then
        echo -e "\n${GREEN}Using: $GAME_DIR${NC}"
        record_recent_game "$GAME_DIR"
        return
    fi

    echo -e "${WHITE}Common game locations:${NC}"
    echo -e "${WHITE} Linux Desktop (Steam): ~/.local/share/Steam/steamapps/common/[Game]${NC}"
    echo -e "${WHITE} Steam Deck (SD Card):  /run/media/mmcblk0p1/steamapps/common/[Game]${NC}"
    echo -e "${WHITE} Heroic / GOG:          ~/Games/Heroic/[Game]${NC}\n"

    echo -e "${YELLOW}Enter the full path to the game's .exe folder:${NC}"

    while [ -z "$GAME_DIR" ]; do
        echo -e -n "> "
        read -r GAME_DIR

        GAME_DIR="${GAME_DIR//\'/}"; GAME_DIR="${GAME_DIR//\"/}"; GAME_DIR="${GAME_DIR%/}"
        GAME_DIR="${GAME_DIR/#\~/$HOME}"

        if [ -d "$GAME_DIR" ]; then
            if [ "$SCRIPT_ACTION" == "i" ]; then
                EXE_COUNT=$(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" | wc -l)
                if [ "$EXE_COUNT" -eq 0 ]; then
                    echo -e "\n${YELLOW}${BOLD}Warning: No .exe files were found in this directory or its immediate subfolders.${NC}"
                    echo -e "\n${YELLOW}Are you absolutely sure this is the correct game folder? (y/N): ${NC}"
                    echo -e -n "> "
                    read -r FORCE_DIR
                    if [[ "$FORCE_DIR" =~ ^[Yy]$ ]]; then break; fi
                    GAME_DIR=""
                    echo -e "\n${YELLOW}Enter the full path to the game's .exe folder:${NC}"
                else
                    break
                fi
            else
                break
            fi
        else
            echo -e "${YELLOW}${BOLD}Error: Directory not found. Please check the path and try again.${NC}"
            GAME_DIR=""
            echo -e "\n${YELLOW}Enter the full path to the game's .exe folder:${NC}"
        fi
    done

    record_recent_game "$GAME_DIR"
}

detect_heroic_prefix_verbose() {
    local target_dir="$1"
    local auto_prefix=""
    local app_name=""

    echo -e "\n${CYAN}STATUS: Scanning Heroic configuration files...${NC}" >&2
    local installed_jsons
    installed_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)

    echo -e " -> Searching installed.json for matching game path..." >&2
    while IFS= read -r json_file; do
        [ -z "$json_file" ] && continue
        app_name=""
        # Match by install_path rather than a raw substring search, since the
        # user-supplied GAME_DIR may point at a subfolder of the actual
        # install (e.g. GameName/bin/x64) rather than the install root itself.
        while IFS=$'\t' read -r install_path record_app_name; do
            [ -z "$install_path" ] && continue
            if [ "$target_dir" == "$install_path" ] || [[ "$target_dir" == "$install_path"/* ]]; then
                app_name="$record_app_name"
            fi
        done < <(awk 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"install_path"|"installPath"/) { split($i, a, "\""); ip=a[4] } if ($i ~ /"app_name"|"appName"/) { split($i, b, "\""); an=b[4] } } if (ip != "") print ip "\t" an }' "$json_file")

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
    done <<< "$installed_jsons"

    # Games added manually via Heroic's "Add Game" (sideloaded) aren't in any
    # installed.json -- Heroic lists them in sideload_apps/library.json, keyed
    # by folder_name. Their prefix still lives in GamesConfig/<app_name>.json.
    local sideload_title=""
    if [ -z "$app_name" ]; then
        echo -e " -> Searching Heroic's manually-added games (sideload_apps/library.json)..." >&2
        local library_jsons
        library_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/sideload_apps/library.json" 2>/dev/null)
        while IFS= read -r json_file; do
            [ -z "$json_file" ] && continue
            # library.json nests an "install": {...} object inside each game,
            # so the RS="}" record split used for installed.json above would
            # cut each game in half. Track brace depth instead and emit one
            # line per game object (depth 2) when it closes. Fields are split on
            # \037 rather than tab: read collapses runs of whitespace IFS, which
            # would shift fields over whenever one (e.g. folder_name) is empty.
            while IFS=$'\037' read -r record_app_name record_title folder_name executable; do
                [ -z "$record_app_name" ] && continue
                [ -z "$folder_name" ] && [ -n "$executable" ] && folder_name=$(dirname "$executable")
                [ -z "$folder_name" ] && continue
                if [ "$target_dir" == "$folder_name" ] || [[ "$target_dir" == "$folder_name"/* ]]; then
                    app_name="$record_app_name"
                    sideload_title="$record_title"
                    break
                fi
            done < <(awk 'function val(s, key) { sub("^.*\"" key "\"[ \t]*:[ \t]*\"", "", s); sub(/".*$/, "", s); return s }
                { line = $0
                  if (depth == 2) { if (line ~ /"app_name"[ \t]*:/) an = val(line, "app_name"); if (line ~ /"title"[ \t]*:/) ti = val(line, "title"); if (line ~ /"folder_name"[ \t]*:/) fn = val(line, "folder_name") }
                  if (line ~ /"executable"[ \t]*:/) ex = val(line, "executable")
                  opens = gsub(/{/, "{", line); closes = gsub(/}/, "}", line); depth += opens - closes
                  if (closes > 0 && depth <= 1 && an != "") { print an "\037" ti "\037" fn "\037" ex; an = ""; ti = ""; fn = ""; ex = "" } }' "$json_file")
            [ -n "$app_name" ] && break
        done <<< "$library_jsons"

        if [ -n "$app_name" ]; then
            echo -e " -> Game found in Heroic's manually-added games: ${BOLD}${sideload_title:-$app_name}${NC}" >&2
            echo -e " -> Parsing GamesConfig/$app_name.json for custom prefix paths..." >&2
            local config_jsons
            config_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/$app_name.json" 2>/dev/null)
            while IFS= read -r conf_file; do
                [ -z "$conf_file" ] && continue
                auto_prefix=$(grep '"winePrefix"' "$conf_file" | awk -F '"' '{print $4}')
                [ -n "$auto_prefix" ] && break
            done <<< "$config_jsons"
        fi
    fi

    if [ -n "$app_name" ] && [ -z "$auto_prefix" ]; then
        echo -e " -> No custom prefix defined. Checking default Heroic locations..." >&2
        if [ -d "$HOME/Games/Heroic/Prefixes/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/$app_name"
        elif [ -d "$HOME/Games/Heroic/Prefixes/default/$app_name" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/default/$app_name"
        # Heroic names default prefixes after the game's title (as typed in
        # "Add Game" for sideloaded games), not its internal app_name.
        elif [ -n "$sideload_title" ] && [ -d "$HOME/Games/Heroic/Prefixes/default/$sideload_title" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/default/$sideload_title"
        elif [ -n "$sideload_title" ] && [ -d "$HOME/Games/Heroic/Prefixes/$sideload_title" ]; then auto_prefix="$HOME/Games/Heroic/Prefixes/$sideload_title"
        fi
    fi

    if [ -n "$auto_prefix" ]; then echo "$auto_prefix"; else echo -e " -> ${YELLOW}Search complete. No prefix found.${NC}" >&2; fi
}

detect_game_environment() {
    APPID=""
    PREFIX_PATH=""
    IS_PROTON=0

    if [[ "$GAME_DIR" == *"/steamapps/common/"* ]]; then
        LAUNCHER_TYPE="1"
        IS_PROTON=1
        echo -e "${GREEN}Steam installation detected!${NC}"
        echo -e "\n${YELLOW}Would you like the script to attempt to automatically find your Proton prefix? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO_S

        if [[ ! "$DO_AUTO_S" =~ ^[Nn]$ ]]; then
            echo -e "\n${CYAN}STATUS: Searching for Steam AppID...${NC}"
            # Use the top-level folder directly under steamapps/common/, not
            # the leaf of GAME_DIR — the .exe is often nested in a subfolder
            # (e.g. GameName/bin/x64), whose basename won't match the
            # appmanifest's "installdir" value.
            INSTALL_DIR="${GAME_DIR#*/steamapps/common/}"
            INSTALL_DIR="${INSTALL_DIR%%/*}"
            echo -e " -> Scanning local appmanifest files for folder: $INSTALL_DIR"
            # Escape BRE metacharacters (folder names with brackets, dots, etc.
            # are common — e.g. "[Definitive Edition]") since this pattern
            # also relies on \s as a wildcard, which -F would otherwise take
            # away by disabling regex interpretation entirely.
            INSTALL_DIR_ESCAPED=$(printf '%s' "$INSTALL_DIR" | sed 's/[][\.*^$]/\\&/g')
            MANIFEST_FILE=$(grep -il "\"installdir\"\s*\"$INSTALL_DIR_ESCAPED\"" "${GAME_DIR%/common/*}"/appmanifest_*.acf 2>/dev/null | head -n 1)

            if [ -n "$MANIFEST_FILE" ]; then
                AUTO_APPID=$(basename "$MANIFEST_FILE" | tr -dc '0-9')
                echo -e " -> Found AppID: ${BOLD}$AUTO_APPID${NC}"
                echo -e "\n${YELLOW}Use this detected Steam AppID? (Y/n): ${NC}"
                echo -e -n "> "
                read -r C_AUTO
                if [[ ! "$C_AUTO" =~ ^[Nn]$ ]]; then APPID="$AUTO_APPID"; fi
            else
                echo -e " -> ${YELLOW}Search complete. No matching AppID found.${NC}"
            fi
        fi

        echo -e "\n${CYAN}Verifying Wine Prefix...${NC}"
        while true; do
            if [ -z "$APPID" ]; then
                echo -e "\n${YELLOW}Enter the Steam AppID manually (or press Enter to skip): ${NC}"
                echo -e "${WHITE} Tip: Found on the game's Steam Store URL, or in Steam by right-clicking the game -> Properties -> Updates.${NC}"
                echo -e -n "> "
                read -r APPID
                APPID=$(echo "$APPID" | tr -dc '0-9')
                [ -z "$APPID" ] && break
            fi

            echo ""
            echo -e " -> Querying Protontricks database for AppID ${APPID}..."
            PREFIX_PATH=$(protontricks -c 'echo $WINEPREFIX' "$APPID" 2>/dev/null | grep "/pfx" | tail -n 1 | tr -d '\r')

            if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH" ]; then
                echo -e " -> ${GREEN}Prefix verified!${NC}"
                break
            else
                echo -e "\n${YELLOW}${BOLD}Error: Proton prefix not found for AppID ${APPID}.${NC}"
                echo -e "${WHITE}If you just installed this game, Proton has not generated the prefix yet."
                echo -e "Please launch the game at least once, close it, and try again.${NC}"
                echo -e "\n${YELLOW}Check this AppID again? (Y/n): ${NC}"
                echo -e -n "> "
                read -r RET
                if [[ "$RET" =~ ^[Nn]$ ]]; then APPID=""; fi
            fi
        done
    else
        LAUNCHER_TYPE="2"
        echo -e "${GREEN}Non-Steam (Heroic/GOG) installation detected!${NC}"
        echo -e "\n${YELLOW}Would you like the script to attempt to automatically find the game's prefix? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO_H

        if [[ ! "$DO_AUTO_H" =~ ^[Nn]$ ]]; then
            DETECTED_PREFIX=$(detect_heroic_prefix_verbose "$GAME_DIR")
            if [ -n "$DETECTED_PREFIX" ]; then
                echo -e " -> ${GREEN}Detected Prefix:${NC} $DETECTED_PREFIX"
                echo -e "\n${YELLOW}Use this detected prefix? (Y/n): ${NC}"
                echo -e -n "> "
                read -r C_AUTO
                if [[ ! "$C_AUTO" =~ ^[Nn]$ ]]; then PREFIX_PATH="$DETECTED_PREFIX"; fi
            fi
        fi

        while true; do
            if [ -z "$PREFIX_PATH" ]; then
                echo -e "\n${YELLOW}Enter the Wine Prefix path manually (or press Enter to skip): ${NC}"
                echo -e "${WHITE} Example Heroic: ~/Games/Heroic/Prefixes/[Game-Name]${NC}"
                echo -e -n "> "
                read -r PREFIX_PATH
                [ -z "$PREFIX_PATH" ] && break
                PREFIX_PATH="${PREFIX_PATH//\'/}"; PREFIX_PATH="${PREFIX_PATH//\"/}"; PREFIX_PATH="${PREFIX_PATH%/}"
                PREFIX_PATH="${PREFIX_PATH/#\~/$HOME}"
            fi

            if [ -d "$PREFIX_PATH/drive_c" ]; then
                echo ""
                echo -e " -> ${GREEN}Prefix verified!${NC}"
                break
            else
                echo -e "\n${YELLOW}${BOLD}Error: Initialised Wine prefix not found at that location.${NC}"
                echo -e "${WHITE}If you just installed this game, the launcher has not generated the prefix yet."
                echo -e "Please run the game at least once, close it, and try again.${NC}"

                echo -e "\n${YELLOW}Check this path again? (Y/n): ${NC}"
                echo -e -n "> "
                read -r RET
                if [[ "$RET" =~ ^[Nn]$ ]]; then PREFIX_PATH=""; fi
            fi
        done

        # Runs for uninstall too: its registry cleanup goes through the
        # same Wine binary, so it needs the game's own runner just as much.
        # Not gated or confirmed, unlike the prefix search: this reads the
        # settings of the prefix just confirmed rather than guessing, and
        # any other Wine would reintroduce the mismatch this fixes.
        if [ -n "$PREFIX_PATH" ]; then
            echo -e "\n${CYAN}STATUS: Checking which Wine version Heroic uses for this game...${NC}"
            resolve_heroic_runner
        fi
    fi
}

resolve_heroic_runner() {
    # Points WINE_CMD/WINESERVER_CMD at the Wine build Heroic actually runs
    # this game with, read from its GamesConfig/<app>.json "wineVersion".
    # Preflight's default is whatever `wine` is on PATH (or the first one
    # under Heroic's tools folder) — e.g. a system Wine 8.0 writing into a
    # GE-Proton 11 prefix, which is what a Halo CE bug report showed. Wine
    # and Proton keep the registry in different layouts between versions,
    # so the game's own runner is the only one whose changes are sure to
    # land where the game will read them. Heroic's Proton prefixes keep
    # drive_c at the prefix root (pfx is a symlink to "."), so Proton's own
    # files/bin/wine can run against PREFIX_PATH directly.
    local json runner_type runner_bin runner_name dir wine_bin="" server_bin=""
    json=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -path "*/GamesConfig/*.json" \
        \( -exec grep -Fq "\"winePrefix\": \"$PREFIX_PATH\"" {} \; -o -exec grep -Fq "\"winePrefix\": \"$PREFIX_PATH/\"" {} \; \) -print 2>/dev/null | head -n 1)
    HEROIC_JSON="$json"
    if [ -n "$json" ]; then
        # \x1f-separated rather than @tsv: tab is IFS whitespace, so an
        # empty field (no "name", say) would shift the rest one to the left.
        IFS=$'\x1f' read -r runner_type runner_bin runner_name server_bin <<< "$(jq -r \
            'first(.[] | objects | select(.wineVersion?) | .wineVersion) | [.type // "", .bin // "", .name // "", .wineserver // ""] | join("\u001f")' \
            "$json" 2>/dev/null)"
        case "$runner_type" in
            proton)
                IS_PROTON=1
                dir=$(dirname "$runner_bin")
                for d in "$dir/files/bin" "$dir/dist/bin"; do
                    if [ -x "$d/wine" ]; then wine_bin="$d/wine"; server_bin="$d/wineserver"; break; fi
                done
                ;;
            wine)
                [ -x "$runner_bin" ] && wine_bin="$runner_bin"
                [ -z "$server_bin" ] && server_bin="$(dirname "$runner_bin")/wineserver"
                ;;
        esac
    fi

    if [ -n "$wine_bin" ]; then
        WINE_CMD="$wine_bin"
        WINESERVER_CMD=""
        [ -x "$server_bin" ] && WINESERVER_CMD="$server_bin"
        # Name only, as Heroic's own Wine Version dropdown shows it; the
        # full path goes in the run log's "Wine used:" summary line.
        echo -e " -> ${GREEN}Using the same Wine version Heroic launches ${GAME_NAME:-this game} with: ${runner_name:-$runner_type}${NC}"
        return 0
    fi

    WINESERVER_CMD=""
    if [ -n "$runner_type" ]; then
        echo -e " -> ${CYAN}Note: the Wine version Heroic launches ${GAME_NAME:-this game} with (${runner_name:-$runner_type}) wasn't found at${NC}"
        echo -e "${CYAN}$runner_bin, so ${WINE_CMD:-no Wine binary} will be used instead. If EAX doesn't show up${NC}"
        echo -e "${CYAN}in-game, that's the likely cause.${NC}"
    elif [ -n "$WINE_CMD" ]; then
        echo -e " -> ${CYAN}Note: no Heroic settings were found for this prefix, so $WINE_CMD will be used. If${NC}"
        echo -e "${CYAN}${GAME_NAME:-the game} runs on Proton or a different Wine build, EAX may not show up in-game.${NC}"
    fi
    return 1
}

flush_wine_registry() {
    # Wine keeps the registry in wineserver's memory and only writes
    # user.reg once the server shuts down, so wait for that before reading
    # the file back. Best-effort: a timeout just means the check below may
    # not see the change yet.
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$APPID" ]; then
        log_cmd "protontricks wineserver -w (AppID $APPID)"
        # timeout goes inside -c: the Flatpak protontricks is a shell
        # function, which timeout can't run.
        protontricks -c "timeout 60 wineserver -w" "$APPID" &>> "$EAX_LOG_FILE"
    elif [ -n "$WINE_CMD" ]; then
        local server="${WINESERVER_CMD:-$(dirname "$WINE_CMD")/wineserver}"
        [ -x "$server" ] || server="wineserver"
        log_cmd "$server -w (prefix $PREFIX_PATH)"
        WINEPREFIX="$PREFIX_PATH" timeout 60 "$server" -w &>> "$EAX_LOG_FILE"
    fi
}

registry_has_value() {
    # Usage: registry_has_value <reg file> <section> <line>
    # e.g. registry_has_value "$PREFIX_PATH/user.reg" 'Software\\Wine\\DllOverrides' '"dsound"="native,builtin"'
    # Looks for an exact value line inside one section of a Wine .reg store
    # file. Values go through ENVIRON, not awk -v, because -v would collapse
    # the doubled backslashes Wine writes in section names.
    SEC="[$2]" WANT="$3" awk 'BEGIN { sec = ENVIRON["SEC"]; want = tolower(ENVIRON["WANT"]) }
        index($0, sec " ") == 1 || $0 == sec { in_sec = 1; next }
        /^\[/ { in_sec = 0 }
        in_sec && tolower($0) == want { found = 1 }
        END { exit !found }' "$1"
}

verify_dll_override() {
    # Usage: verify_dll_override <dll name>
    # Reads the override back from the prefix's user.reg after regedit
    # reported success — regedit can exit 0 without the key ever landing
    # (e.g. a different Wine build than the prefix's own). Returns 0 if
    # found, 1 if missing, 2 if there's no user.reg to check (never treated
    # as a failure, since that says nothing about the override itself).
    local dll="$1" store="$PREFIX_PATH/user.reg"
    flush_wine_registry
    [ -f "$store" ] || { log_cmd "override check skipped: $store not found"; return 2; }
    if registry_has_value "$store" 'Software\\Wine\\DllOverrides' "\"$dll\"=\"native,builtin\""; then
        log_cmd "override check: \"$dll\"=\"native,builtin\" found in $store"
        return 0
    fi
    log_cmd "override check: \"$dll\"=\"native,builtin\" NOT found in $store"
    return 1
}

apply_registry_patch() {
    # Returns regedit's exit status, or 1 when there was nothing to run it
    # with (no AppID / Wine binary / prefix) or the .reg file couldn't be
    # written — callers use this to decide whether to report "Injected" or
    # "removed", so it must never look like success when nothing happened.
    local reg_file="$1" rc=1
    if [ ! -s "$reg_file" ]; then
        log_cmd "regedit skipped: $reg_file is missing or empty"
        return 1
    fi
    if [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$APPID" ]; then
        log_cmd "protontricks regedit $reg_file (AppID $APPID)"; sed 's/^/  | /' "$reg_file" >> "$EAX_LOG_FILE" 2>/dev/null
        protontricks -c "regedit \"$reg_file\"" "$APPID" &>> "$EAX_LOG_FILE"; rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    elif [ "$LAUNCHER_TYPE" == "2" ] && [ -d "$PREFIX_PATH/drive_c" ] && [ -n "$WINE_CMD" ]; then
        log_cmd "$WINE_CMD regedit $reg_file (prefix $PREFIX_PATH)"; sed 's/^/  | /' "$reg_file" >> "$EAX_LOG_FILE" 2>/dev/null
        WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" regedit "$reg_file" &>> "$EAX_LOG_FILE"; rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    else
        log_cmd "regedit skipped: no AppID, Wine binary, or prefix to apply $reg_file to"
    fi
    return "$rc"
}

select_architecture() {
    # Sets ARCH ("32" or "64") and ARCH_FOLDER ("Win32" or "Win64") based on
    # the game's executable(s) in GAME_DIR, either via auto-detection or a
    # manual prompt. Shared by the normal install flow and any standalone
    # flow that needs to know the game's architecture (e.g. VC++-only mode).
    echo ""
    print_divider
    echo -e "${CYAN}3. Architecture Selection${NC}"
    print_line
    echo ""
    echo -e "${WHITE}This step determines whether the game executable is 32-bit or 64-bit so the script"
    echo -e "can deploy the correct architecture for the audio wrapper files. If the wrong version"
    echo -e "is selected, the game will silently fail to load the custom audio engine.${NC}\n"

    ARCH="MANUAL"
    if command -v file &> /dev/null; then
        echo -e "${YELLOW}Attempt to auto-detect 32/64-bit architecture? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_AUTO
        if [[ ! "$DO_AUTO" =~ ^[Nn]$ ]]; then
            A32=0; A64=0
            while IFS= read -r -d '' exe; do
                [[ $(file "$exe") == *"PE32+"* ]] && ((A64++)) || ((A32++))
            done < <(find "$GAME_DIR" -maxdepth 2 -type f -iname "*.exe" -print0)
            if [ "$A64" -gt 0 ] && [ "$A32" -eq 0 ]; then
                DETECTED="64"
            elif [ "$A32" -gt 0 ] && [ "$A64" -eq 0 ]; then
                DETECTED="32"
            else
                DETECTED="UNKNOWN"
            fi
            if [ "$DETECTED" != "UNKNOWN" ]; then
                echo -e "\n${GREEN}Detected ${DETECTED}-bit. Correct? (Y/n): ${NC}"
                echo -e -n "> "
                read -r CONF
                if [[ ! "$CONF" =~ ^[Nn]$ ]]; then ARCH="$DETECTED"; fi
            fi
        fi
    fi
    if [ "$ARCH" == "MANUAL" ]; then
        while true; do
            echo -e "\n${YELLOW}Architecture (32/64): ${NC}"
            echo -e -n "> "
            read -r ARCH
            if [[ "$ARCH" == "32" || "$ARCH" == "64" ]]; then break
            else echo -e "${YELLOW}${BOLD}Invalid selection. Please type 32 or 64.${NC}"; fi
        done
    fi
    ARCH_FOLDER=$([ "$ARCH" == "64" ] && echo "Win64" || echo "Win32")
}

verify_vcrun_files() {
    # Usage: verify_vcrun_files
    # Checks the actual VC++ 2015-2022 Redistributable DLLs in the prefix
    # (not just one file) and prints a per-file status table, so a "success"
    # can be confirmed by more than a single DLL's presence. Critically, this
    # uses is_genuine_dll rather than a plain existence check: Wine places a
    # same-named "fake DLL" placeholder for every one of these by default in
    # every prefix, so file presence alone is not evidence the real thing is
    # installed — that was a real bug in an earlier version of this check,
    # which could report [OK] for Wine's own empty placeholder and never
    # actually catch that the genuine runtime was missing. Uses ARCH and
    # PREFIX_PATH from the enclosing install flow. Sets VCRUN_SUCCESS=1 if
    # the core runtime files are genuinely present, 0 otherwise.
    VCRUN_SUCCESS=0

    local target_dir
    if [ "$ARCH" == "32" ] && [ -d "$PREFIX_PATH/drive_c/windows/syswow64" ]; then
        target_dir="$PREFIX_PATH/drive_c/windows/syswow64"
    else
        target_dir="$PREFIX_PATH/drive_c/windows/system32"
    fi
    [ -d "$target_dir" ] || return

    # Core: what DSOAL/OpenAL Soft actually need to load. Extra: installed
    # alongside by the same redistributable, reported for completeness but
    # not treated as a hard requirement.
    local core_files=("vcruntime140.dll" "msvcp140.dll")
    local extra_files=("vcomp140.dll" "concrt140.dll")
    [ "$ARCH" == "64" ] && extra_files+=("vcruntime140_1.dll")

    echo -e " -> Verifying VC++ runtime files in $(basename "$target_dir"):"

    local core_ok=1
    local f
    for f in "${core_files[@]}"; do
        if is_genuine_dll "$target_dir/$f"; then
            echo -e "      ${GREEN}[OK]${NC}      $f"
        elif [ -s "$target_dir/$f" ]; then
            echo -e "      ${YELLOW}[FAKE]${NC}    $f ${WHITE}(Wine's own placeholder, not the genuine file)${NC}"
            core_ok=0
        else
            echo -e "      ${YELLOW}[MISSING]${NC} $f"
            core_ok=0
        fi
    done
    for f in "${extra_files[@]}"; do
        if is_genuine_dll "$target_dir/$f"; then
            echo -e "      ${GREEN}[OK]${NC}      $f"
        elif [ -s "$target_dir/$f" ]; then
            echo -e "      ${YELLOW}[FAKE]${NC}    $f ${WHITE}(optional, Wine's own placeholder)${NC}"
        else
            echo -e "      ${YELLOW}[MISSING]${NC} $f ${WHITE}(optional, not always required)${NC}"
        fi
    done

    [ "$core_ok" -eq 1 ] && VCRUN_SUCCESS=1
}

apply_vcrun_dll_overrides() {
    # Sets WINEDLLOverrides to "native,builtin" for every VC++ DLL name, so
    # Wine actually loads the genuine installed files instead of its own
    # partial builtin implementations. Needed regardless of which install
    # path succeeded — winetricks' own vcrun2022 verb sets these itself, but
    # the direct-download fallback (vc_redist.exe /q) only places the files
    # and never touches this, which is exactly what caused a game to crash
    # on an "unimplemented function" despite every file being verified
    # present on disk.
    local reg_file="$GAME_DIR/vcrun_overrides_$$.reg"
    echo -e " -> Setting DLL overrides so Wine loads the native runtime instead of its own builtin..."
    echo "Windows Registry Editor Version 5.00" > "$reg_file"
    echo "" >> "$reg_file"
    echo "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]" >> "$reg_file"
    local dll
    for dll in "${VCRUN_DLL_NAMES[@]}"; do
        echo "\"$dll\"=\"native,builtin\"" >> "$reg_file"
    done
    local rc=0
    apply_registry_patch "$reg_file" || rc=1
    rm -f "$reg_file"
    if [ "$rc" -ne 0 ]; then
        echo -e " -> ${YELLOW}${BOLD}Warning: The VC++ DLL overrides couldn't be set, so Wine may still use its own builtin runtime.${NC}"
        echo -e "${WHITE}    The run log has the full output.${NC}"
    fi
    return "$rc"
}

remove_vcrun_dll_overrides() {
    # Removes the WINEDLLOverrides entries set by apply_vcrun_dll_overrides,
    # so a prefix that's had VC++ uninstalled doesn't keep telling Wine to
    # prefer "native" versions of DLLs that no longer exist (harmless in
    # practice — Wine falls back to builtin — but leaves a clean prefix).
    local reg_file="$GAME_DIR/vcrun_overrides_clean_$$.reg"
    echo "Windows Registry Editor Version 5.00" > "$reg_file"
    echo "" >> "$reg_file"
    echo "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]" >> "$reg_file"
    local dll
    for dll in "${VCRUN_DLL_NAMES[@]}"; do
        echo "\"$dll\"=-" >> "$reg_file"
    done
    if ! apply_registry_patch "$reg_file"; then
        echo -e " -> ${YELLOW}${BOLD}Warning: The VC++ DLL overrides couldn't be removed. The run log has the full output.${NC}"
    fi
    rm -f "$reg_file"
}

install_vcrun_dependencies() {
    # Installs the MS VC++ 2022 Redistributable into the current prefix (needs
    # LAUNCHER_TYPE, APPID/PREFIX_PATH, WINE_CMD, ARCH, and BASE_SHARE already
    # set by detect_game_environment / the architecture step). Tries
    # protontricks/winetricks first, verifies via verify_vcrun_files rather
    # than trusting the exit code, and falls back to a direct download from
    # Microsoft if the package manager didn't leave the files behind. All
    # installer output is captured to a log file rather than discarded, so a
    # failure (either path can silently "succeed" without leaving files
    # behind, e.g. if Wine's MSI engine chokes on it) is actually debuggable
    # instead of a dead end with no information.
    echo -e "\n${CYAN}STATUS: Installing MS VC++ 2022 Redistributable...${NC}"

    VCRUN_SHARE="$BASE_SHARE/vcrun2022"
    mkdir -p "$VCRUN_SHARE"
    VCRUN_LOG="$VCRUN_SHARE/install.log"
    : > "$VCRUN_LOG"

    echo -e " -> Attempting installation via package manager..."

    # 1. Run the package manager
    # --force bypasses winetricks' own checksum check for vc_redist.exe: it
    # ships with a baked-in expected hash, but Microsoft serves this file
    # from an "evergreen" URL that gets updated in place, so that hash can
    # go stale. Without --force, winetricks stops for a confirmation that
    # never gets answered in this non-interactive context — previously only
    # the Heroic/winetricks path below had this, not this protontricks path.
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks "$APPID" --force -q vcrun2022 &>> "$VCRUN_LOG"
    elif [ -n "$WINE_CMD" ]; then
        WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" WINESERVER="${WINESERVER_CMD:-}" winetricks --force -q vcrun2022 &>> "$VCRUN_LOG"
    fi

    # 2. Verify physical file presence instead of trusting exit codes
    verify_vcrun_files

    # 3. Handle the outcome
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        echo -e " -> ${GREEN}Package manager installation successful (core DLLs verified).${NC}"
        apply_vcrun_dll_overrides
        return 0
    fi

    echo -e " -> ${YELLOW}Package manager failed (core files missing). Falling back to direct download...${NC}"

    if [ "$ARCH" == "64" ]; then
        VCRUN_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
        VCRUN_EXE="vc_redist.x64.exe"
    else
        VCRUN_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
        VCRUN_EXE="vc_redist.x86.exe"
    fi

    if [ ! -s "$VCRUN_SHARE/$VCRUN_EXE" ]; then
        echo -e " -> Downloading $VCRUN_EXE from Microsoft..."
        curl -fL -# "$VCRUN_URL" -o "$VCRUN_SHARE/$VCRUN_EXE"
    else
        echo -e " -> Using cached $VCRUN_EXE"
    fi

    # Already registered in the prefix (an earlier install, even one whose
    # msvcp140.dll a Wine/Proton prefix update later swapped for its own
    # builtin): a plain install sees "already installed" and exits without
    # copying anything, so ask the installer to repair instead, which puts
    # back missing or replaced files. winetricks' own vcrun2022 verb can't
    # cover this either: it extracts "msvcp140.dll" from the cab, but the
    # current redistributable names that entry "msvcp140.dll_x86".
    local vc_mode="/q" vc_arch="X86"
    [ "$ARCH" == "64" ] && vc_arch="X64"
    if grep -q "\"DisplayName\"=\"Microsoft Visual C++ 2022 $vc_arch Minimum Runtime" "$PREFIX_PATH/system.reg" 2>/dev/null; then
        vc_mode="/repair /quiet"
        echo -e " -> VC++ 2022 is already registered in this prefix, but a core file was replaced, so running Microsoft's repair..."
    else
        echo -e " -> Running silent installer in prefix..."
    fi
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks -c "wine \"$VCRUN_SHARE/$VCRUN_EXE\" $vc_mode /norestart" "$APPID" &>> "$VCRUN_LOG"
    else
        # shellcheck disable=SC2086  # vc_mode is one or two flags
        WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$VCRUN_SHARE/$VCRUN_EXE" $vc_mode /norestart &>> "$VCRUN_LOG"
    fi

    # Final verification
    verify_vcrun_files
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        echo -e " -> ${GREEN}VC++ Redistributable installed successfully via fallback.${NC}"
        apply_vcrun_dll_overrides
        return 0
    else
        echo -e " -> ${YELLOW}Warning: Direct installation completed, but core DLLs could not be verified.${NC}"
        echo -e " -> ${WHITE}Full installer output saved to: $VCRUN_LOG${NC}"
        return 1
    fi
}

remove_vcrun_msi_registration() {
    # Deletes the Windows "Programs and Features" (MSI uninstall registry)
    # entries for VC++, searched by DisplayName rather than a hardcoded GUID
    # since the product code varies by servicing release and by 32/64-bit.
    # This matters beyond tidiness: MSI treats that registration as the
    # source of truth for "is this installed", independent of whether the
    # actual files are still there. Leaving it behind after deleting the
    # files makes a future reinstall attempt see "already installed" and
    # skip re-extracting anything — silently reproducing this exact failure
    # on a prefix that's been through an install/uninstall cycle before.
    # Best-effort and non-fatal throughout: reg.exe's query/delete syntax
    # under Wine can vary by build, and this should never be what blocks an
    # uninstall from completing.
    local hives=(
        "HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
        "HKLM\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
    )
    local hive query_output key removed_any=0

    for hive in "${hives[@]}"; do
        if [ "$LAUNCHER_TYPE" == "1" ]; then
            log_cmd "protontricks wine reg query $hive (Visual C++)"
            query_output=$(protontricks -c "wine reg query \"$hive\" /s /f \"Visual C++\" /d" "$APPID" 2>> "$EAX_LOG_FILE")
        elif [ -n "$WINE_CMD" ]; then
            log_cmd "$WINE_CMD reg query $hive (Visual C++)"
            query_output=$(WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" reg query "$hive" /s /f "Visual C++" /d 2>> "$EAX_LOG_FILE")
        else
            continue
        fi

        while IFS= read -r line; do
            [[ "$line" == HKEY_LOCAL_MACHINE* ]] || continue
            key="${line%$'\r'}"
            if [ "$LAUNCHER_TYPE" == "1" ]; then
                log_cmd "protontricks wine reg delete $key"
                protontricks -c "wine reg delete \"$key\" /f" "$APPID" &>> "$EAX_LOG_FILE"
            else
                log_cmd "$WINE_CMD reg delete $key"
                WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" reg delete "$key" /f &>> "$EAX_LOG_FILE"
            fi
            removed_any=1
        done <<< "$query_output"
    done

    [ "$removed_any" -eq 1 ] && echo -e " -> Removed leftover Programs and Features registry entries."
}

uninstall_vcrun_dependencies() {
    # Removes the MS VC++ 2022 Redistributable from the current prefix. Tries
    # the official uninstaller first as a best-effort step (it can also clean
    # up SxS manifests/policy files our manual list doesn't know about), but
    # never relies on it alone: testing earlier showed Wine's MSI engine can
    # report success on both install AND uninstall without actually doing
    # anything, so direct file/registry removal always runs afterward
    # regardless of what the uninstaller reports. Also removes the MSI
    # "Programs and Features" registration (see remove_vcrun_msi_registration)
    # so a future reinstall on this same prefix doesn't see a stale "already
    # installed" record and silently skip re-extracting the files. Uninstall
    # doesn't run the architecture-selection step, so this checks both
    # system32 and syswow64 for a genuine runtime (see below).
    if [ -z "$PREFIX_PATH" ] || [ ! -d "$PREFIX_PATH/drive_c/windows" ]; then
        echo -e " -> ${YELLOW}Prefix not found, skipping VC++ removal.${NC}"
        return
    fi

    # winetricks' vcrun2022 installs both the x86 and x64 runtimes, so a
    # 64-bit prefix usually has one in each folder: system32 holds the
    # 64-bit copy and syswow64 the 32-bit one. A 32-bit-only prefix (no
    # syswow64) keeps its 32-bit copy in system32. Every folder holding a
    # genuine runtime is handled with its own architecture's uninstaller --
    # stopping at the first one found left a 32-bit game's copy behind.
    local win="$PREFIX_PATH/drive_c/windows"
    local dirs=("$win/system32") arches=("x86")
    if [ -d "$win/syswow64" ]; then
        dirs=("$win/system32" "$win/syswow64"); arches=("x64" "x86")
    fi
    local i present=()
    for i in "${!dirs[@]}"; do
        if is_genuine_dll "${dirs[$i]}/vcruntime140.dll" || is_genuine_dll "${dirs[$i]}/msvcp140.dll"; then
            present+=("$i")
        fi
    done

    if [ "${#present[@]}" -eq 0 ]; then
        echo -e " -> ${YELLOW}No VC++ runtime files found in this prefix, nothing to remove.${NC}"
        return
    fi

    echo -e "\n${CYAN}STATUS: Removing MS VC++ 2022 Redistributable...${NC}"

    local vcrun_share="$BASE_SHARE/vcrun2022"
    mkdir -p "$vcrun_share"
    local dir arch vcrun_exe dll f
    for i in "${present[@]}"; do
        dir="${dirs[$i]}"; arch="${arches[$i]}"; vcrun_exe="vc_redist.$arch.exe"

        # 1. Best-effort: the official uninstaller. Fetches the installer
        # fresh if not already cached, but never blocks on a failed
        # download — this step is pure upside if it works, and a no-op if
        # it doesn't.
        if [ ! -s "$vcrun_share/$vcrun_exe" ]; then
            echo -e " -> Fetching the official $arch uninstaller (best-effort)..."
            curl -fL -# "https://aka.ms/vs/17/release/$vcrun_exe" -o "$vcrun_share/$vcrun_exe" 2>/dev/null
        fi
        if [ -s "$vcrun_share/$vcrun_exe" ]; then
            echo -e " -> Running the official $arch uninstaller (best-effort; direct cleanup follows regardless)..."
            if [ "$LAUNCHER_TYPE" == "1" ]; then
                log_cmd "protontricks $vcrun_exe /uninstall"
                protontricks -c "wine \"$vcrun_share/$vcrun_exe\" /uninstall /q /norestart" "$APPID" &>> "$EAX_LOG_FILE"; echo "[exit $?]" >> "$EAX_LOG_FILE"
            else
                log_cmd "$WINE_CMD $vcrun_exe /uninstall"
                WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$vcrun_share/$vcrun_exe" /uninstall /q /norestart &>> "$EAX_LOG_FILE"; echo "[exit $?]" >> "$EAX_LOG_FILE"
            fi
        else
            echo -e " -> Could not fetch the official $arch uninstaller, skipping straight to direct cleanup."
        fi

        # 2. Direct removal — the reliable part. Matches VCRUN_DLL_NAMES
        # (every DLL install could have set an override for), not a
        # shorter ad-hoc list. Only genuine Microsoft files: Wine's own
        # same-named placeholders aren't ours to remove.
        for dll in "${VCRUN_DLL_NAMES[@]}"; do
            f="$dir/${dll}.dll"
            if is_genuine_dll "$f" && rm -f "$f"; then
                echo -e " -> Removed ${dll}.dll from $(basename "$dir")"
            fi
        done
    done

    remove_vcrun_msi_registration
    remove_vcrun_dll_overrides

    # Checks every folder, not just the ones handled above.
    local left=()
    for dir in "${dirs[@]}"; do
        for dll in vcruntime140 msvcp140; do
            is_genuine_dll "$dir/$dll.dll" && left+=("$(basename "$dir")/$dll.dll")
        done
    done
    if [ "${#left[@]}" -gt 0 ]; then
        echo -e " -> ${YELLOW}${BOLD}Warning: some core VC++ runtime files are still present: ${left[*]}${NC}"
    else
        echo -e " -> ${GREEN}VC++ Redistributable removed successfully.${NC}"
    fi
}

print_offline_instructions() {
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}--- OFFLINE MODE INSTRUCTIONS ---${NC}"
    print_line
    echo -e "${WHITE}GitHub is unreachable and no local cache was found.${NC}"
    echo -e "${WHITE}Manually extract release .zips into these folders:${NC}\n"
    echo -e "${CYAN}1. kcat Official DSOAL:${NC} ${GREEN}$DSOAL_OFFICIAL${NC}"
    echo -e "${CYAN}2. kcat OpenAL Soft:${NC}   ${GREEN}$OPENAL_OFFICIAL${NC}"
    echo -e "${CYAN}3. ThreeDeeJay DSOAL:${NC}  ${GREEN}$DSOAL_COMMUNITY_V13${NC}"
    echo -e "${CYAN}4. PCGamingWiki DSOAL (self-hosted mirror):${NC} ${GREEN}$DSOAL_COMMUNITY_V14${NC}\n"
}

verify_checksum() {
    # Usage: verify_checksum <downloaded_file> <expected_sha256>
    # Verifies a downloaded file against a checksum. If sha256sum isn't
    # available, this skips verification with a warning rather than blocking
    # the install over a missing local tool. A mismatch against a known-good
    # hash, however, is treated as a hard failure.
    local file="$1"
    local expected="$2"

    if ! command -v sha256sum &> /dev/null; then
        echo -e " -> ${YELLOW}sha256sum not available, skipping checksum verification.${NC}"
        return 0
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo -e " -> ${YELLOW}${BOLD}Checksum mismatch! Expected $expected, got $actual.${NC}"
        return 1
    fi

    echo -e " -> ${GREEN}Checksum verified.${NC}"
    return 0
}

get_asset_digest() {
    # Usage: get_asset_digest <release_json> <asset_filename>
    # GitHub publishes an automatic SHA256 "digest" for every release asset
    # (https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/).
    # This pulls that digest for a named asset out of a Releases API response,
    # so a rolling/unpinned tag like kcat's "latest-master" can still be
    # verified against whatever GitHub says was actually uploaded. Requires
    # jq for reliable JSON parsing; prints nothing if jq is missing or the
    # asset/digest can't be found — callers should treat empty as "skip".
    local release_json="$1"
    local asset_name="$2"

    command -v jq &> /dev/null || return 0

    echo "$release_json" | jq -r --arg name "$asset_name" \
        '(.assets // [])[] | select(.name == $name) | .digest // empty' 2>/dev/null \
        | sed -n 's/^sha256://p'
}

confirm_unverified_download() {
    # Usage: confirm_unverified_download <label>
    # Called when a kcat "official" download couldn't be checksum-verified
    # (missing jq, or GitHub hasn't published a digest for it yet). Rather
    # than silently proceeding, this hands the decision to the user — noting
    # that the file comes straight from kcat's official GitHub repo, which
    # is reassuring but not a substitute for an actual checksum match.
    # Returns 0 to proceed, 1 to decline.
    local label="$1"

    echo -e " -> ${YELLOW}Could not obtain a checksum for $label (requires 'jq', or GitHub hasn't published one yet).${NC}"
    echo -e "    ${WHITE}This file is downloaded directly from kcat's official GitHub repository, so it should"
    echo -e "    be safe — but without a checksum, the script can't independently confirm that.${NC}"
    echo -e "    ${YELLOW}Install it anyway? (Y/n): ${NC}"
    echo -n "    > "
    read -r CONFIRM_UNVERIFIED
    [[ ! "$CONFIRM_UNVERIFIED" =~ ^[Nn]$ ]]
}

verify_or_confirm() {
    # Usage: verify_or_confirm <file> <expected_sha256_or_empty> <label>
    # Single gate for a downloaded kcat asset: verifies against a digest when
    # one was found, otherwise defers to confirm_unverified_download. Returns
    # 0 to proceed with installing the file, 1 to abort this download.
    local file="$1"
    local digest="$2"
    local label="$3"

    if [ -n "$digest" ]; then
        verify_checksum "$file" "$digest"
        return $?
    fi

    confirm_unverified_download "$label"
}

dsoal_official_cached() {
    [ -d "$DSOAL_OFFICIAL" ] && [ -n "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]
}

fetch_pinned_dsoal_into_official() {
    # Used when the rolling latest-master build can't be obtained and there's
    # no cache: installs the pinned archive revision into the same
    # $DSOAL_OFFICIAL folder, so the rest of the script needs no special
    # casing. Records "archive-<rev>" as the cached date, which can never
    # match a real latest-master updated_at, so the next run that can reach
    # latest-master upgrades to it automatically.
    echo -e " -> ${CYAN}Falling back to kcat's archived DSOAL build [$DSOAL_PINNED_REV]...${NC}"
    if curl -fL -# "$DSOAL_PINNED_URL" -o "$DSOAL_SHARE/pinned.zip" && unzip -tq "$DSOAL_SHARE/pinned.zip" &>/dev/null; then
        if verify_checksum "$DSOAL_SHARE/pinned.zip" "$DSOAL_PINNED_SHA256"; then
            rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
            unzip -q "$DSOAL_SHARE/pinned.zip" -d "$DSOAL_OFFICIAL"
            NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
            if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"; fi
            echo "archive-$DSOAL_PINNED_REV" > "$DSOAL_SHARE/updated_at.txt"; rm -f "$DSOAL_SHARE/pinned.zip"; echo -e " -> ${GREEN}Done.${NC}"
            return 0
        fi
        echo -e " -> ${YELLOW}${BOLD}The archived build failed checksum verification.${NC}"
    else
        echo -e " -> ${YELLOW}${BOLD}The archived build download failed or the file was corrupt.${NC}"
    fi
    rm -f "$DSOAL_SHARE/pinned.zip"
    echo -e " -> ${YELLOW}${BOLD}The kcat DSOAL + OpenAL Soft engine will be unavailable this run.${NC}"
    return 1
}

update_local_cache() {
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- REPOSITORY CACHE CHECK ---${NC}"
    print_line
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"

    echo -e "\n${CYAN}Checking kcat Official DSOAL repository...${NC}"
    # curl -s without -f still succeeds on an HTTP error, so a failure here
    # means GitHub is genuinely unreachable -- as opposed to reachable but
    # without an updated_at (latest-master missing upstream, or API rate limit).
    DSOAL_API_REACHABLE=1
    DSOAL_OFFICIAL_JSON=$(curl -s "$DSOAL_OFFICIAL_API_URL") || DSOAL_API_REACHABLE=0
    LATEST_DATE=$(echo "$DSOAL_OFFICIAL_JSON" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$LATEST_DATE" ]; then
        if dsoal_official_cached; then
            if [ "$DSOAL_API_REACHABLE" -eq 1 ]; then echo -e " -> ${YELLOW}Could not check for updates (kcat's latest-master release is unavailable). Using cached version [${LOCAL_DATE%%T*}]${NC}"
            else echo -e " -> ${YELLOW}Offline. Using cached version [${LOCAL_DATE%%T*}]${NC}"; fi
        elif [ "$DSOAL_API_REACHABLE" -eq 1 ]; then
            echo -e " -> ${YELLOW}kcat's latest-master build is unavailable upstream right now.${NC}"
            fetch_pinned_dsoal_into_official
        else
            echo -e " -> ${YELLOW}${BOLD}Offline and no cache found. The kcat DSOAL + OpenAL Soft engine will be unavailable this run.${NC}"
        fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading latest build...${NC}"
        if curl -fL -# "$DSOAL_OFFICIAL_URL" -o "$DSOAL_SHARE/dsoal.zip" && unzip -tq "$DSOAL_SHARE/dsoal.zip" &>/dev/null; then
            DSOAL_OFFICIAL_DIGEST=$(get_asset_digest "$DSOAL_OFFICIAL_JSON" "DSOAL.zip")
            if verify_or_confirm "$DSOAL_SHARE/dsoal.zip" "$DSOAL_OFFICIAL_DIGEST" "kcat Official DSOAL"; then
                rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
                unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_OFFICIAL"
                NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
                if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"; fi
                echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"; rm -f "$DSOAL_SHARE/dsoal.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/dsoal.zip"
                if dsoal_official_cached; then
                    echo -e " -> ${YELLOW}${BOLD}Skipping this download. Keeping existing cache [${LOCAL_DATE%%T*}].${NC}"
                else
                    echo -e " -> ${YELLOW}${BOLD}Could not verify or confirm this download, and no usable cache exists.${NC}"
                    fetch_pinned_dsoal_into_official
                fi
            fi
        else
            rm -f "$DSOAL_SHARE/dsoal.zip"
            if dsoal_official_cached; then
                echo -e " -> ${YELLOW}${BOLD}Download failed or file was corrupt. Keeping existing cache [${LOCAL_DATE%%T*}].${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Download failed and no usable cache exists.${NC}"
                fetch_pinned_dsoal_into_official
            fi
        fi
    else echo -e " -> ${GREEN}Up to date [${LOCAL_DATE%%T*}]${NC}"; fi

    echo -e "\n${CYAN}Checking kcat OpenAL Soft repository...${NC}"
    OAL_TAG=$(curl -sI https://github.com/kcat/openal-soft/releases/latest | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
    LOCAL_OAL_TAG=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$OAL_TAG" ]; then
        if [ -d "$OPENAL_OFFICIAL" ]; then echo -e " -> ${YELLOW}Offline. Using cached version [${LOCAL_OAL_TAG}]${NC}"
        else echo -e " -> ${YELLOW}${BOLD}Offline and no cache found. The kcat DSOAL + OpenAL Soft engine will be unavailable this run.${NC}"; fi
    elif [ "$OAL_TAG" != "$LOCAL_OAL_TAG" ] || [ ! -d "$OPENAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading OpenAL Soft [${OAL_TAG}]...${NC}"
        OAL_ASSET_NAME="openal-soft-${OAL_TAG}-bin.zip"
        OAL_URL="https://github.com/kcat/openal-soft/releases/download/${OAL_TAG}/${OAL_ASSET_NAME}"
        if curl -fL -# "$OAL_URL" -o "$OPENAL_SHARE/openal.zip" && unzip -tq "$OPENAL_SHARE/openal.zip" &>/dev/null; then
            OPENAL_OFFICIAL_JSON=$(curl -s "https://api.github.com/repos/kcat/openal-soft/releases/tags/${OAL_TAG}")
            OAL_DIGEST=$(get_asset_digest "$OPENAL_OFFICIAL_JSON" "$OAL_ASSET_NAME")
            if verify_or_confirm "$OPENAL_SHARE/openal.zip" "$OAL_DIGEST" "kcat OpenAL Soft [$OAL_TAG]"; then
                rm -rf "$OPENAL_OFFICIAL"; mkdir -p "$OPENAL_OFFICIAL"
                unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_OFFICIAL"
                echo "$OAL_TAG" > "$OPENAL_SHARE/updated_at.txt"; rm -f "$OPENAL_SHARE/openal.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$OPENAL_SHARE/openal.zip"
                if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                    echo -e " -> ${YELLOW}${BOLD}Skipping this download. Keeping existing cache [${LOCAL_OAL_TAG}].${NC}"
                else
                    echo -e " -> ${YELLOW}${BOLD}Could not verify or confirm this download, and no usable cache exists. The kcat DSOAL + OpenAL Soft engine will be unavailable this run.${NC}"
                fi
            fi
        else
            rm -f "$OPENAL_SHARE/openal.zip"
            if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                echo -e " -> ${YELLOW}${BOLD}Download failed or file was corrupt. Keeping existing cache [${LOCAL_OAL_TAG}].${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Download failed and no usable cache exists. The kcat DSOAL + OpenAL Soft engine will be unavailable this run.${NC}"
            fi
        fi
    else echo -e " -> ${GREEN}Up to date [${LOCAL_OAL_TAG}]${NC}"; fi

    echo -e "\n${CYAN}Checking ThreeDeeJay Community DSOAL...${NC}"
    if [ ! -d "$DSOAL_COMMUNITY_V13" ]; then
        echo -e " -> ${CYAN}Cache missing. Downloading stable build [v1.31a]...${NC}"
        mkdir -p "$DSOAL_COMMUNITY_V13"
        if curl -fL -# "$DSOAL_COMMUNITY_V13_URL" -o "$DSOAL_SHARE/community.zip" && unzip -tq "$DSOAL_SHARE/community.zip" &>/dev/null; then
            if verify_checksum "$DSOAL_SHARE/community.zip" "$DSOAL_COMMUNITY_V13_SHA256"; then
                unzip -q "$DSOAL_SHARE/community.zip" -d "$DSOAL_COMMUNITY_V13"; rm -f "$DSOAL_SHARE/community.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/community.zip"; rmdir "$DSOAL_COMMUNITY_V13" 2>/dev/null
                echo -e " -> ${YELLOW}${BOLD}Aborting: downloaded file failed checksum verification. This engine will be unavailable this run.${NC}"
            fi
        else
            rm -f "$DSOAL_SHARE/community.zip"; rmdir "$DSOAL_COMMUNITY_V13" 2>/dev/null
            echo -e " -> ${YELLOW}${BOLD}Error: Download failed or file was corrupt. This engine will be unavailable this run.${NC}"
        fi
    else echo -e " -> ${GREEN}Available in cache.${NC}"; fi

    echo -e "\n${CYAN}Checking PCGamingWiki Community DSOAL (self-hosted mirror)...${NC}"
    if [ ! -d "$DSOAL_COMMUNITY_V14" ]; then
        echo -e " -> ${CYAN}Cache missing. Downloading v1.4 build...${NC}"
        mkdir -p "$DSOAL_COMMUNITY_V14"
        if curl -fL -# "$DSOAL_COMMUNITY_V14_URL" -o "$DSOAL_SHARE/v1.4.zip" && unzip -tq "$DSOAL_SHARE/v1.4.zip" &>/dev/null; then
            if verify_checksum "$DSOAL_SHARE/v1.4.zip" "$DSOAL_COMMUNITY_V14_SHA256"; then
                unzip -q "$DSOAL_SHARE/v1.4.zip" -d "$DSOAL_COMMUNITY_V14"; rm -f "$DSOAL_SHARE/v1.4.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/v1.4.zip"; rmdir "$DSOAL_COMMUNITY_V14" 2>/dev/null
                echo -e " -> ${YELLOW}${BOLD}Aborting: downloaded file failed checksum verification. This engine will be unavailable this run.${NC}"
            fi
        else
            rm -f "$DSOAL_SHARE/v1.4.zip"; rmdir "$DSOAL_COMMUNITY_V14" 2>/dev/null
            echo -e " -> ${YELLOW}${BOLD}Error: Download failed or file was corrupt. This engine will be unavailable this run.${NC}"
        fi
    else echo -e " -> ${GREEN}Available in cache.${NC}"; fi

    # Each engine's download is allowed to fail on its own above, so one
    # upstream outage doesn't block the others. Only stop here if nothing at
    # all is installable.
    if ! engine_available 1 && ! engine_available 2 && ! engine_available 3; then
        print_offline_instructions; exit 1
    fi
}

engine_available() {
    # Usage: engine_available <1|2|3>  (the ENGINE_CHOICE numbering)
    case "$1" in
        1) [ -n "$(ls -A "$DSOAL_COMMUNITY_V13" 2>/dev/null)" ] ;;
        2) [ -n "$(ls -A "$DSOAL_COMMUNITY_V14" 2>/dev/null)" ] ;;
        3) dsoal_official_cached && [ -n "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ] ;;
        *) return 1 ;;
    esac
}

find_existing_variant() {
    # Usage: find_existing_variant <path>
    # Prints the path if it exists, otherwise any same-named file in that
    # folder that differs only by case (e.g. DSOUND.DLL for dsound.dll).
    # Linux filesystems -- NTFS via ntfs3/ntfs-3g included -- are
    # case-sensitive, so an exact-name check alone would drop a second
    # dsound.dll next to a game's own DSOUND.DLL rather than backing it up,
    # leaving Wine to pick either and Windows (on a shared NTFS drive) with
    # two names it can't tell apart.
    local f="$1"
    if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; return; fi
    find "$(dirname "$f")" -maxdepth 1 -iname "$(basename "$f")" 2>/dev/null | head -n 1
}

target_fs_type() {
    # Usage: target_fs_type <dir>  -> e.g. ext4, btrfs, ntfs3, ntfs (ntfs-3g)
    local dir="$1" fs src
    fs=$(findmnt -no FSTYPE -T "$dir" 2>/dev/null)
    # ntfs-3g (and exFAT via FUSE) mounts show up as plain "fuseblk", so ask
    # the block device what it actually is.
    if [ "$fs" == "fuseblk" ]; then
        src=$(findmnt -no SOURCE -T "$dir" 2>/dev/null)
        [ -n "$src" ] && fs=$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n 1)
        [ -z "$fs" ] && fs="fuseblk"
    fi
    echo "$fs"
}

check_target_writable() {
    # Usage: check_target_writable <dir> <label>
    # Confirms the script can actually write to <dir> before anything is
    # changed, and explains why not when it can't -- most often an NTFS drive
    # that Linux mounted read-only because Windows Fast Startup/hibernation
    # left it "dirty". Exits on failure; returns 0 when writable.
    local dir="$1" label="$2" probe fs opts
    probe="$dir/.eax-restore-write-test.$$"
    fs=$(target_fs_type "$dir")
    if touch "$probe" 2>/dev/null && rm -f "$probe" 2>/dev/null; then
        if [[ "$fs" == ntfs* ]] && [ "$SCRIPT_ACTION" == "i" ] && [ -z "$NTFS_NOTE_SHOWN" ]; then
            NTFS_NOTE_SHOWN=1
            echo -e "\n${YELLOW}Note: this $label is on an NTFS drive ($fs).${NC}"
            echo -e "${WHITE}If you also run this game from Windows, the files deployed here (dsound.dll,"
            echo -e "dsoal-aldrv.dll, alsoft.ini, and any dummy eax.dll) affect it there too — a dummy"
            echo -e "eax.dll in particular can stop it starting under Windows. Uninstalling with this"
            echo -e "script restores the original files.${NC}"
        fi
        return 0
    fi
    opts=$(findmnt -no OPTIONS -T "$dir" 2>/dev/null)
    echo -e "\n${YELLOW}${BOLD}Error: The $label can't be written to:${NC}"
    echo -e "${WHITE}  $dir${NC}"
    echo -e "${WHITE}  Filesystem: ${fs:-unknown}   Mount options: ${opts:-unknown}${NC}\n"
    if [[ "$fs" == ntfs* ]] && [[ ",$opts," == *,ro,* ]]; then
        echo -e "${WHITE}This NTFS drive is mounted read-only. That usually means Windows didn't fully"
        echo -e "shut down (Fast Startup or hibernation left the drive marked as in use), so Linux"
        echo -e "refuses to write to it. Boot into Windows and use Shut Down while holding Shift"
        echo -e "(or turn off Fast Startup in Power Options), then remount the drive and re-run.${NC}"
    elif [[ "$fs" == ntfs* ]]; then
        echo -e "${WHITE}This NTFS drive is mounted, but your user isn't allowed to write to it. NTFS has"
        echo -e "no Linux permissions of its own, so access comes from the mount options — mount it"
        echo -e "with uid=$(id -u),gid=$(id -g) (or through your file manager / fstab) and re-run.${NC}"
    elif [[ ",$opts," == *,ro,* ]]; then
        echo -e "${WHITE}This drive is mounted read-only. Remount it read-write and re-run.${NC}"
    else
        echo -e "${WHITE}Your user doesn't have write permission here (owner: $(stat -c '%U' "$dir" 2>/dev/null))."
        echo -e "Fix the folder's permissions and re-run. Don't run this script as root.${NC}"
    fi
    echo -e "\n${WHITE}Nothing has been changed.${NC}"
    exit 1
}

deploy_copy() {
    # Usage: deploy_copy <src> <dest> <verb>
    # Copies one file and only records it in the manifest (and reports it)
    # if the copy actually succeeded; failures are counted in
    # DEPLOY_FAILURES so the install can't report success when it isn't.
    if cp -f "$1" "$2"; then
        echo "$2" >> "$INSTALL_MANIFEST"
        echo -e " -> $3: $(basename "$2") to $(basename "$(dirname "$2")")"
        return 0
    fi
    record_deploy_failure "$2"
    return 1
}

record_deploy_failure() {
    echo -e " -> ${YELLOW}${BOLD}Error: Could not write $(basename "$1") to $(dirname "$1").${NC}"
    DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
}

handle_conflict() {
    local target_file="$1"
    local existing
    existing=$(find_existing_variant "$target_file")
    if [ -n "$existing" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            # Already ours from a previous install (tracked in the prior
            # manifest before it was reset) — not a genuine original, so
            # there's nothing here worth backing up. Overwrite directly;
            # any real original backup from the very first install, if one
            # exists, is left untouched rather than buried under this.
            if rm -f "$existing"; then return 0; fi
            record_deploy_failure "$target_file"
            return 1
        fi
        echo -e "\n${YELLOW}Conflict: $(basename "$existing")${NC} ${WHITE}already exists at $(dirname "$target_file").${NC}"
        while true; do
            echo -e "\n${YELLOW}Action - [o]verwrite, [B]ackup & overwrite (default), [s]kip: ${NC}"
            echo -e -n "> "
            read -r C_CHOICE
            C_CHOICE="${C_CHOICE:-b}"
            case "${C_CHOICE,,}" in
                o)
                    if rm -rf "$existing"; then return 0; fi
                    record_deploy_failure "$target_file"
                    return 1 ;;
                b)
                    # Named after the target (not a differently-cased
                    # original), so uninstall's "$f".bak* lookup finds it.
                    # A failed backup skips the copy: cp -f onto the file
                    # can still succeed (it needs only file write access,
                    # mv needs the folder's), which would destroy the
                    # original with no backup left.
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    if ! mv "$existing" "${target_file}.bak.${TIMESTAMP}"; then
                        echo -e " -> ${YELLOW}${BOLD}Error: Couldn't back up $(basename "$existing"), so it was left untouched.${NC}"
                        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
                        return 1
                    fi
                    echo -e " -> Backed up original $(basename "$existing") to $(basename "$target_file").bak.${TIMESTAMP}"
                    return 0 ;;
                s) echo -e " -> Skipped $(basename "$target_file")."; return 1 ;;
                *) echo -e "${YELLOW}${BOLD}Invalid choice. Type o, b, or s.${NC}" ;;
            esac
        done
    fi
    return 0
}

auto_backup_and_overwrite() {
    # Usage: auto_backup_and_overwrite <target_file>
    # Like handle_conflict's [b]ackup option, but never prompts — always
    # backs up an existing file (timestamped) before it gets overwritten.
    # Used for the prefix copy of dsound.dll: it's a genuine system DLL
    # likely to already exist there, and backup-and-overwrite is already
    # handle_conflict's own default, so skipping the prompt here removes a
    # step without changing what actually happens in the common case.
    # Returns 1 (and counts a deploy failure) if the existing file couldn't
    # be moved aside, so the caller skips the copy instead of overwriting it.
    local target_file="$1"
    local existing
    existing=$(find_existing_variant "$target_file")
    if [ -n "$existing" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            if rm -f "$existing"; then return 0; fi
            record_deploy_failure "$target_file"
            return 1
        fi
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        if ! mv "$existing" "${target_file}.bak.${TIMESTAMP}"; then
            echo -e " -> ${YELLOW}${BOLD}Error: Couldn't back up $(basename "$existing"), so it was left untouched.${NC}"
            DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
            return 1
        fi
        echo -e " -> Backed up existing $(basename "$existing") to $(basename "$target_file").bak.${TIMESTAMP}"
    fi
    return 0
}

# ==============================================================================
# SCRIPT START
# ==============================================================================
clear
echo -e "${CYAN}${BOLD}==========================================================${NC}"
echo -e "${CYAN}${BOLD}   DSOAL & OpenAL Soft Universal Installer                ${NC}"
echo -e "${CYAN}${BOLD}   v${SCRIPT_VERSION}  (${SCRIPT_DATE})${NC}"
echo -e "${CYAN}${BOLD}==========================================================${NC}"

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- PRE-FLIGHT SYSTEM CHECK ---${NC}"
print_line

EAX_RESTORE_SKIP_PREFLIGHT="${EAX_RESTORE_SKIP_PREFLIGHT:-}"
if is_truthy "$EAX_RESTORE_SKIP_PREFLIGHT"; then
    echo -e "\n${YELLOW}EAX_RESTORE_SKIP_PREFLIGHT is set — skipping the tool scan and trusting that curl,"
    echo -e "unzip, file, protontricks, winetricks, and wine are already available.${NC}"

    # Still needed by the rest of the script, just done quietly: the
    # protontricks Flatpak fallback function, and WINE_CMD.
    if ! command -v protontricks &> /dev/null && flatpak info com.github.Matoking.protontricks &> /dev/null; then
        protontricks() { flatpak run com.github.Matoking.protontricks "$@"; }
    fi
    WINE_CMD="wine"
    command -v wine &> /dev/null || WINE_CMD=$(find_local_wine)
else
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

    echo -n -e " -> Checking for ${YELLOW}jq${NC} (optional)... "
    if command -v jq &> /dev/null; then
        echo -e "${GREEN}FOUND${NC}"
    else
        echo -e "${YELLOW}MISSING (checksum verification for the kcat official builds will be skipped)${NC}"
    fi

    if [ ${#MISSING_BASE_PKGS[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}The script is missing essential tools to function: ${MISSING_BASE_PKGS[*]}${NC}"
        if grep -q "ID=steamos" /etc/os-release 2>/dev/null; then
            echo -e "\n${YELLOW}SteamOS detected. To protect your immutable filesystem, please install missing tools via the Discover software centre.${NC}"
            echo -e "${YELLOW}${BOLD}Cannot proceed without base dependencies. Exiting.${NC}"; exit 1
        else
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
            else echo -e "\n${YELLOW}${BOLD}Cannot proceed without base dependencies. Exiting.${NC}"; exit 1; fi
        fi
    else echo -e " -> ${GREEN}All base requirements met.${NC}"; fi
fi

# ==============================================================================
# STANDALONE VC++ RUNTIME INSTALL
# ==============================================================================
# Set EAX_RESTORE_VCRUN_ONLY=1 to skip everything else and just (re)install the
# MS VC++ 2022 Redistributable into a game's prefix — e.g. if you skipped it
# during a normal install and want to go back for it without redoing the rest.
EAX_RESTORE_VCRUN_ONLY="${EAX_RESTORE_VCRUN_ONLY:-}"
if is_truthy "$EAX_RESTORE_VCRUN_ONLY"; then
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- VC++ RUNTIME ONLY MODE ---${NC}"
    print_line
    echo -e "\n${WHITE}EAX_RESTORE_VCRUN_ONLY is set, so this run will only install the MS VC++ 2022"
    echo -e "Redistributable into a game's prefix — nothing else the script normally does (DSOAL,"
    echo -e "OpenAL Soft, alsoft.ini, registry overrides) will be touched.${NC}"
    echo -e "\n${WHITE}Unset EAX_RESTORE_VCRUN_ONLY to return to the normal install/uninstall flow.${NC}"

    SCRIPT_ACTION="i"

    echo ""
    print_divider
    echo -e "${CYAN}1. Game Location${NC}"
    print_line
    get_game_directory ""

    echo ""
    print_divider
    echo -e "${CYAN}2. Launcher Identification${NC}"
    print_line
    echo ""
    detect_game_environment

    select_architecture

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- READY ---${NC}"
    print_line
    echo -e "\n${WHITE}This will attempt to install the MS VC++ 2022 Redistributable into:${NC}"
    [ "$LAUNCHER_TYPE" == "1" ] && echo -e "${WHITE} -> Steam AppID: ${BOLD}$APPID${NC}"
    [ -n "$PREFIX_PATH" ] && echo -e "${WHITE} -> Prefix: ${BOLD}$PREFIX_PATH${NC}"
    echo -e "\n${YELLOW}Proceed? (Y/n): ${NC}"
    echo -e -n "> "
    read -r CONFIRM_VCRUN_ONLY
    if [[ "$CONFIRM_VCRUN_ONLY" =~ ^[Nn]$ ]]; then
        echo -e "\n${YELLOW}Aborted. No changes made.${NC}"
        exit 0
    fi

    if install_vcrun_dependencies; then
        GAME_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
        if [ -f "$GAME_MANIFEST" ] && head -n 1 "$GAME_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
            # A stale "already uninstalled" sentinel would otherwise make a
            # future uninstall run stop before ever reading this marker.
            : > "$GAME_MANIFEST"
        fi
        echo "VCRUN" >> "$GAME_MANIFEST"
    else
        echo ""
        print_divider
        echo -e "${YELLOW}${BOLD}--- VC++ RUNTIME INSTALL INCOMPLETE ---${NC}"
        print_line
        echo -e "\n${YELLOW}${BOLD}Error: The core VC++ runtime files couldn't be verified in the prefix, so the runtime${NC}"
        echo -e "${YELLOW}${BOLD}isn't installed. The installer output is saved in $VCRUN_LOG.${NC}"
        echo ""
        exit 1
    fi

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- VC++ RUNTIME INSTALL COMPLETE ---${NC}"
    print_line
    echo ""
    exit 0
fi

echo ""
print_divider
echo -e "${GREEN}${BOLD}--- SELECT OPERATION ---${NC}"
print_line

if is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13" || is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14" || is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL"; then
    SCRIPT_ACTION="i"
    echo -e "\n${GREEN}An EAX_RESTORE_DSOAL_* variable is set, so proceeding straight to install.${NC}"
else
    while true; do
        echo -e "\n${YELLOW}Would you like to (i)nstall or (u)ninstall the EAX audio fix? (i/u): ${NC}"
        echo -e -n "> "
        read -r SCRIPT_ACTION
        SCRIPT_ACTION="${SCRIPT_ACTION,,}"
        if [[ "$SCRIPT_ACTION" == "i" || "$SCRIPT_ACTION" == "u" ]]; then break
        else echo -e "${YELLOW}${BOLD}Invalid selection. Please type 'i' or 'u'.${NC}"; fi
    done
fi

# ==============================================================================
# ACTION: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "u" ]; then
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- UNINSTALL EAX FIX ---${NC}"
    print_line

    echo ""
    print_divider
    echo -e "${CYAN}1. Game Location${NC}"
    print_line
    get_game_directory ""
    check_target_writable "$GAME_DIR" "game folder"

    echo ""
    print_divider
    echo -e "${CYAN}2. Launcher Identification${NC}"
    print_line
    echo ""
    detect_game_environment

    echo ""
    print_divider
    echo -e "${CYAN}3. Scanning For Installed Files${NC}"
    print_line

    FILES_TO_REMOVE=()
    INSTALL_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
    MANIFEST_FOUND=0
    REG_HAS_COM="n"
    REG_HAS_OVERRIDE="n"
    VCRUN_INSTALLED="n"

    if [ -s "$INSTALL_MANIFEST" ] && head -n 1 "$INSTALL_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
        echo -e "\n${GREEN}This game was already uninstalled in a previous run — nothing left to remove.${NC}"
        echo -e "${WHITE}If you've since manually copied in DSOAL/OpenAL files outside this script, remove"
        echo -e "those by hand; there's no install record for them to safely automate.${NC}"
        exit 0
    fi

    if [ -s "$INSTALL_MANIFEST" ]; then
        MANIFEST_FOUND=1
        echo -e "\n${GREEN}Found an install manifest from a previous run.${NC}"
        echo -e "${WHITE}Removing files listed in the manifest. Backed-up originals are restored"
        echo -e "automatically — anything overwritten without a backup can't be recovered, even"
        echo -e "if the game still needs it. If it fails to launch afterward, try the launcher's"
        echo -e "verify/repair files option to get missing originals back.${NC}"
        while IFS= read -r manifest_entry; do
            [ -z "$manifest_entry" ] && continue
            case "$manifest_entry" in
                "REGISTRY:COM") REG_HAS_COM="y"; continue ;;
                "REGISTRY:OVERRIDE") REG_HAS_OVERRIDE="y"; continue ;;
                "VCRUN") VCRUN_INSTALLED="y"; continue ;;
            esac
            { [ -e "$manifest_entry" ] || [ -L "$manifest_entry" ]; } && FILES_TO_REMOVE+=("$manifest_entry")
        done < "$INSTALL_MANIFEST"
    else
        echo -e "\n${YELLOW}${BOLD}No install manifest found.${NC}"
        echo -e "${WHITE}This usually means the fix was installed with an older version of the script, or the"
        echo -e "manifest file was deleted. Falling back to a best-effort scan by filename instead — note this"
        echo -e "may also flag files that pre-date the script and were skipped rather than installed by it.${NC}"

        TARGET_FILES=("dsound.dll" "dsoal-aldrv.dll" "dsound.vxd" "eax.dll" "eaxunified.dll" "alsoft.ini")

        # Check standard game folder
        for file in "${TARGET_FILES[@]}"; do
            [ -e "$GAME_DIR/$file" ] && FILES_TO_REMOVE+=("$GAME_DIR/$file")
            [ -L "$GAME_DIR/$file" ] && FILES_TO_REMOVE+=("$GAME_DIR/$file")
        done
        [ -d "$GAME_DIR/OpenAL" ] && FILES_TO_REMOVE+=("$GAME_DIR/OpenAL")

        # Check prefix system folders
        if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
            for file in "dsound.dll" "dsoal-aldrv.dll"; do
                [ -f "$PREFIX_PATH/drive_c/windows/syswow64/$file" ] && FILES_TO_REMOVE+=("$PREFIX_PATH/drive_c/windows/syswow64/$file")
                [ -f "$PREFIX_PATH/drive_c/windows/system32/$file" ] && FILES_TO_REMOVE+=("$PREFIX_PATH/drive_c/windows/system32/$file")
            done
        fi
    fi

    VCRUN_PRESENT="n"
    if [ "$VCRUN_INSTALLED" == "y" ]; then
        VCRUN_PRESENT="y"
    elif [ -n "$PREFIX_PATH" ] && { is_genuine_dll "$PREFIX_PATH/drive_c/windows/system32/vcruntime140.dll" || is_genuine_dll "$PREFIX_PATH/drive_c/windows/syswow64/vcruntime140.dll"; }; then
        # No manifest record of it, but the runtime is actually there — cover
        # installs done with an older script version, or the standalone
        # VC++-only mode run before manifest tracking existed for it.
        VCRUN_PRESENT="y"
    fi

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ] && [ "$REG_HAS_COM" == "n" ] && [ "$REG_HAS_OVERRIDE" == "n" ] && [ "$VCRUN_PRESENT" == "n" ]; then
        echo -e "\n${YELLOW}No EAX files found in $GAME_DIR or the system prefix.${NC}"; exit 0
    fi

    echo ""
    print_divider
    echo -e "${CYAN}4. Game Files${NC}"
    print_line

    FILES_DECLINED="0"
    if [ ${#FILES_TO_REMOVE[@]} -gt 0 ]; then
        RESTORE_TARGETS=()
        RESTORE_SOURCES=()
        for f in "${FILES_TO_REMOVE[@]}"; do
            # The OLDEST backup, not the newest: if a reinstall ever created
            # a redundant backup of our own previous output (fixed above,
            # but older installs from before that fix may have left these
            # behind), the earliest one is the one most likely to actually
            # be the genuine original.
            OLDEST_BAK=$(ls -tr "$f".bak* 2>/dev/null | head -n 1)
            if [ -n "$OLDEST_BAK" ]; then
                RESTORE_TARGETS+=("$f")
                RESTORE_SOURCES+=("$OLDEST_BAK")
            fi
        done

        declare -A HAS_BACKUP
        for t in "${RESTORE_TARGETS[@]}"; do HAS_BACKUP["$t"]=1; done

        echo -e "\n${YELLOW}${BOLD}The following files will be removed:${NC}"
        idx=1
        for f in "${FILES_TO_REMOVE[@]}"; do
            if [ "${HAS_BACKUP[$f]:-0}" == "1" ]; then
                printf "%2d  %s  " "$idx" "$f"; echo -e "${GREEN}(original will be restored)${NC}"
            else
                printf "%2d  %s\n" "$idx" "$f"
            fi
            idx=$((idx + 1))
        done

        echo -e "\n${YELLOW}Press Enter to remove all, or pick which to remove (e.g. \"1 2 3\", \"1-3\", \"^4\""
        echo -e "to remove all except 4), or 'n' to cancel entirely: ${NC}"
        echo -e -n "> "
        read -r CONFIRM_UNINSTALL

        if [[ "$CONFIRM_UNINSTALL" =~ ^[Nn]$ ]]; then
            FILES_DECLINED="1"
        else
            parse_selection "${#FILES_TO_REMOVE[@]}" "$CONFIRM_UNINSTALL"

            FINAL_REMOVE=()
            FINAL_RESTORE_TARGETS=()
            FINAL_RESTORE_SOURCES=()
            idx=1
            for f in "${FILES_TO_REMOVE[@]}"; do
                if [ "${SELECTED[$idx]}" == "1" ]; then
                    FINAL_REMOVE+=("$f")
                    if [ "${HAS_BACKUP[$f]:-0}" == "1" ]; then
                        for j in "${!RESTORE_TARGETS[@]}"; do
                            if [ "${RESTORE_TARGETS[$j]}" == "$f" ]; then
                                FINAL_RESTORE_TARGETS+=("$f")
                                FINAL_RESTORE_SOURCES+=("${RESTORE_SOURCES[$j]}")
                            fi
                        done
                    fi
                fi
                idx=$((idx + 1))
            done

            if [ ${#FINAL_REMOVE[@]} -eq 0 ]; then
                echo -e "\n${YELLOW}Nothing selected, nothing removed.${NC}"
                FILES_DECLINED="1"
            else
                for f in "${FINAL_REMOVE[@]}"; do rm -rf "$f"; done
                for i in "${!FINAL_RESTORE_TARGETS[@]}"; do
                    mv "${FINAL_RESTORE_SOURCES[$i]}" "${FINAL_RESTORE_TARGETS[$i]}" \
                        && echo -e " -> Restored original $(basename "${FINAL_RESTORE_TARGETS[$i]}") in $(dirname "${FINAL_RESTORE_TARGETS[$i]}")"
                    # Any other .bak* files still sitting around for this
                    # same target are leftover junk — most likely backups
                    # of our own prior output from before reinstalls were
                    # handled correctly, not additional genuine originals —
                    # so there's nothing left worth keeping them for.
                    rm -f "${FINAL_RESTORE_TARGETS[$i]}".bak* 2>/dev/null
                done
                echo -e "\n${GREEN}Selected files removed successfully.${NC}"
                # A partial removal means some tracked files are still
                # genuinely there — the "fully uninstalled" sentinel below
                # must not be written in that case, same as a full decline.
                [ ${#FINAL_REMOVE[@]} -lt ${#FILES_TO_REMOVE[@]} ] && FILES_DECLINED="1"
            fi
        fi
    else
        echo -e "\n${WHITE}No DSOAL/OpenAL files to remove — the remaining steps (registry and/or VC++"
        echo -e "runtime) still apply, though.${NC}"
    fi

    if [ "$FILES_DECLINED" == "0" ]; then
        # Leave a sentinel behind rather than deleting the manifest outright.
        # If uninstall gets run again on this same game later, this lets the
        # script recognize "already cleaned up, nothing to do" and exit safely
        # instead of falling back to a filename-based guess — which could
        # otherwise mistake a just-restored original dsound.dll for one of
        # ours and delete it a second time. Skipped entirely if the user just
        # declined removal above, since the original manifest still describes
        # files that are genuinely still there.
        echo "# EAX Restore: uninstalled on $(date -u +"%Y-%m-%dT%H:%M:%SZ"). Nothing left to remove." > "$INSTALL_MANIFEST"
    fi

    echo ""
    print_divider
    echo -e "${CYAN}5. Registry Cleanup${NC}"
    print_line

    if [ "$MANIFEST_FOUND" -eq 1 ]; then
        if [[ "$REG_HAS_COM" == "y" || "$REG_HAS_OVERRIDE" == "y" ]]; then
            echo -e "\n${WHITE}The install manifest shows this install applied:${NC}"
            [[ "$REG_HAS_COM" == "y" ]] && echo -e "${WHITE} - COM Registry Routing${NC}"
            [[ "$REG_HAS_OVERRIDE" == "y" ]] && echo -e "${WHITE} - Automatic DLL Override (WINEDLLOVERRIDES)${NC}"
            echo -e "${WHITE}Removing those registry keys now.${NC}"
            REMOVE_REG="y"
        else
            echo -e "\n${WHITE}The install manifest shows no registry tweaks (COM Routing / Automatic DLL Override)"
            echo -e "were applied during install, so there's nothing to clean up in the Wine registry.${NC}"
            REMOVE_REG="n"
        fi
    else
        echo -e "\n${WHITE}This removes the WINEDLLOVERRIDES rule and the COM CLSID routing keys that were"
        echo -e "written into the Wine prefix registry during install (if you enabled those options)."
        echo -e "No manifest was found to confirm which of these were applied, so this is a manual choice —"
        echo -e "skip it if you never opted into 'Automatic DLL Override' or 'COM Registry Routing'.${NC}"
        echo -e "\n${YELLOW}Do you want to remove Override/COM keys from the Wine registry? (y/N): ${NC}"
        echo -e -n "> "
        read -r REMOVE_REG
        if [[ "$REMOVE_REG" =~ ^[Yy]$ ]]; then REG_HAS_COM="y"; REG_HAS_OVERRIDE="y"; fi
    fi

    if [[ "$REMOVE_REG" =~ ^[Yy]$ ]]; then
        if [ -n "$APPID" ] || [ -d "$PREFIX_PATH/drive_c" ]; then
            REG_FILE="$GAME_DIR/dsoal_registry_clean_$$.reg"
            echo "Windows Registry Editor Version 5.00" > "$REG_FILE"
            echo "" >> "$REG_FILE"

            if [[ "$REG_HAS_OVERRIDE" == "y" ]]; then
                cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"dsound"=-

EOF
            fi

            if [[ "$REG_HAS_COM" == "y" ]]; then
                cat <<EOF >> "$REG_FILE"
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
EOF
            fi

            echo -e "\n${CYAN}STATUS: Cleaning registry...${NC}"
            if apply_registry_patch "$REG_FILE"; then
                echo -e " -> ${GREEN}Registry keys safely removed.${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Warning: The registry keys couldn't be removed from the Wine prefix. The run log has the full output.${NC}"
            fi
            rm -f "$REG_FILE"
        else echo -e "${YELLOW}${BOLD}Prefix/AppID not found, skipping registry cleanup.${NC}"; fi
    fi

    echo ""
    print_divider
    echo -e "${CYAN}6. VC++ Runtime${NC}"
    print_line

    if [ "$VCRUN_PRESENT" == "y" ]; then
        echo -e "\n${WHITE}This prefix has the MS VC++ 2022 Redistributable installed (added for the kcat engine)."
        echo -e "A Wine prefix can be shared by multiple games or apps, so removing this could affect"
        echo -e "other software using the same prefix — only remove it if you're sure nothing else here"
        echo -e "needs it.${NC}"
        echo -e "\n${YELLOW}Also remove the VC++ 2022 Redistributable from this prefix? (y/N): ${NC}"
        echo -e -n "> "
        read -r REMOVE_VCRUN
        if [[ "$REMOVE_VCRUN" =~ ^[Yy]$ ]]; then
            uninstall_vcrun_dependencies
        fi
    else
        echo -e "\n${WHITE}No VC++ runtime recorded or detected in this prefix — nothing to do here.${NC}"
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
    update_local_cache

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- PHASE 1: CONFIGURATION ---${NC}"
    print_line

    # 1. Game Location
    echo ""
    print_divider
    echo -e "${CYAN}1. Game Location${NC}"
    print_line
    get_game_directory ""
    check_target_writable "$GAME_DIR" "game folder"

    # 2. Game Identification & Launcher Auto-Detect
    echo ""
    print_divider
    echo -e "${CYAN}2. Launcher Identification${NC}"
    print_line
    echo ""
    detect_game_environment

    # 3. Architecture Scan
    select_architecture

    # 4. Engine Selection
    echo ""
    print_divider
    echo -e "${CYAN}4. Audio Engine Selection${NC}"
    print_line
    echo ""
    DSOAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    DSOAL_VER=${DSOAL_DATE%%T*}
    [ -z "$DSOAL_VER" ] && DSOAL_VER="Unknown"
    OAL_VER=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    [ -z "$OAL_VER" ] && OAL_VER="Unknown"

    echo -e "${WHITE}Before choosing, here is a quick breakdown of the available engines:\n${NC}"
    echo -e " * ${BOLD}ThreeDeeJay Community:${NC} The best \"plug-and-play\" choice for older Windows 98/XP games."
    echo -e "   Specific compatibility tweaks curated by the retro-gaming community, though it relies on a"
    echo -e "   slightly older, locked codebase.\n"
    echo -e " * ${BOLD}PCGamingWiki Community DSOAL:${NC} A popular updated community fork offering compatibility"
    echo -e "   fixes for mid-2000s titles. PCGamingWiki blocks automated downloads, so this build is served"
    echo -e "   from a self-hosted mirror rather than their site directly.\n"
    echo -e " * ${BOLD}kcat DSOAL + OpenAL Soft:${NC} The official, rock-solid baseline from the original wrapper developer"
    echo -e "   paired directly with the newest, bleeding-edge audio renderer for the highest fidelity algorithms.\n"

    EAX_RESTORE_DSOAL_COMMUNITY_V13="${EAX_RESTORE_DSOAL_COMMUNITY_V13:-}"
    EAX_RESTORE_DSOAL_COMMUNITY_V14="${EAX_RESTORE_DSOAL_COMMUNITY_V14:-}"
    EAX_RESTORE_DSOAL_OFFICIAL="${EAX_RESTORE_DSOAL_OFFICIAL:-}"

    ENGINE_ENV_SET=0
    is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13" && ((ENGINE_ENV_SET++))
    is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14" && ((ENGINE_ENV_SET++))
    is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL" && ((ENGINE_ENV_SET++))

    if [ "$ENGINE_ENV_SET" -gt 1 ]; then
        echo -e "${YELLOW}${BOLD}Error: More than one EAX_RESTORE_DSOAL_* variable is set. Set only one and re-run.${NC}"
        exit 1
    fi

    if is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V13"; then
        ENGINE_CHOICE=1
        echo -e "${GREEN}EAX_RESTORE_DSOAL_COMMUNITY_V13 is set — using ThreeDeeJay Community DSOAL.${NC}"
    elif is_truthy "$EAX_RESTORE_DSOAL_COMMUNITY_V14"; then
        ENGINE_CHOICE=2
        echo -e "${GREEN}EAX_RESTORE_DSOAL_COMMUNITY_V14 is set — using PCGamingWiki Community DSOAL.${NC}"
    elif is_truthy "$EAX_RESTORE_DSOAL_OFFICIAL"; then
        ENGINE_CHOICE=3
        echo -e "${GREEN}EAX_RESTORE_DSOAL_OFFICIAL is set — using kcat DSOAL + OpenAL Soft.${NC}"
    else
        # An engine whose download failed in the cache check is shown but
        # can't be picked, and the default moves to the first one that works.
        ENGINE_DEFAULT=3
        if ! engine_available 3; then
            if engine_available 1; then ENGINE_DEFAULT=1; else ENGINE_DEFAULT=2; fi
        fi
        ENGINE_UNAVAILABLE_TAG=" ${YELLOW}[unavailable this run]${NC}"
        echo -e "${YELLOW}Selection (1, 2, or 3) [Default: $ENGINE_DEFAULT]: ${NC}"
        echo -e "\n 1) ThreeDeeJay Community DSOAL [v1.31a]$(engine_available 1 || echo -e "$ENGINE_UNAVAILABLE_TAG")"
        echo -e " 2) PCGamingWiki Community DSOAL (self-hosted mirror) [v1.4]$(engine_available 2 || echo -e "$ENGINE_UNAVAILABLE_TAG")"
        echo -e " 3) kcat DSOAL + OpenAL Soft    [DSOAL: $DSOAL_VER | OAL: $OAL_VER]$(engine_available 3 || echo -e "$ENGINE_UNAVAILABLE_TAG")"

        while true; do
            echo -e -n "\n> "
            read -r ENGINE_CHOICE
            ENGINE_CHOICE="${ENGINE_CHOICE:-$ENGINE_DEFAULT}"
            if [[ ! "$ENGINE_CHOICE" =~ ^[123]$ ]]; then echo -e "${YELLOW}${BOLD}Invalid selection. Please type 1, 2, or 3.${NC}"
            elif ! engine_available "$ENGINE_CHOICE"; then echo -e "${YELLOW}${BOLD}That engine couldn't be downloaded this run (see the REPOSITORY CACHE CHECK above). Please pick another.${NC}"
            else break; fi
        done
    fi

    if ! engine_available "$ENGINE_CHOICE"; then
        echo -e "\n${YELLOW}${BOLD}Error: The engine selected by your EAX_RESTORE_DSOAL_* variable couldn't be downloaded this run.${NC}"
        echo -e "${WHITE}Check the REPOSITORY CACHE CHECK output above, then re-run, or unset the variable to choose another engine.${NC}"
        exit 1
    fi

    # 5. VC++ Runtime Dependencies
    INSTALL_VCRUN="n"
    if [ "$ENGINE_CHOICE" == "3" ]; then
        echo ""
        print_divider
        echo -e "${CYAN}5. VC++ Runtime Dependencies${NC}"
        print_line
        echo -e "\n${WHITE}The modern kcat engine needs genuine Microsoft C++ runtime libraries. Older Proton/Wine"
        echo -e "builds (9 and below) tend to be missing them more often than newer ones — but rather"
        echo -e "than guess from a version number, this can check the prefix directly.${NC}"
        echo -e "\n${YELLOW}Check this prefix for existing VC++ runtime files? (Y/n): ${NC}"
        echo -e -n "> "
        read -r DO_VCRUN_CHECK

        if [[ "$DO_VCRUN_CHECK" =~ ^[Nn]$ ]]; then
            echo -e "\n${WHITE}Skipping. You can revisit this later with EAX_RESTORE_VCRUN_ONLY=1 without redoing"
            echo -e "the rest of the install.${NC}"
        else
            echo -e "\n${CYAN}STATUS: Checking prefix for existing VC++ runtime files...${NC}"

            if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
                verify_vcrun_files
            else
                VCRUN_SUCCESS=0
                echo -e " -> ${YELLOW}Prefix not resolved yet, can't check. Defaulting to asking below.${NC}"
            fi

            if [ "$VCRUN_SUCCESS" -eq 1 ]; then
                echo -e "\n${GREEN}Core VC++ runtime files are already present.${NC}"
                echo -e "${WHITE}Applying the DLL overrides so Wine actually loads them (file presence alone doesn't"
                echo -e "guarantee that), then skipping the install step itself.${NC}"
                apply_vcrun_dll_overrides
            else
                echo -e "\n${WHITE}These files are missing or incomplete here. Without them, the game may crash"
                echo -e "silently on startup when it tries to load the audio engine.${NC}"
                echo -e "\n${YELLOW}Install genuine MS VC++ runtimes? (Y/n): ${NC}"
                echo -e -n "> "
                read -r INSTALL_VCRUN
                INSTALL_VCRUN="${INSTALL_VCRUN:-y}"
            fi
        fi
    fi

    # 6. Audio Configuration
    echo ""
    print_divider
    echo -e "${CYAN}6. Speaker Configuration${NC}"
    print_line
    echo ""
    echo -e "${WHITE}What kind of audio output are you using?${NC}\n"
    echo -e " 1) Stereo (headphones or 2-speaker setup)"
    echo -e " 2) Surround Sound (4.0/5.1/6.1/7.1 speaker setup)"
    echo -e " 3) Matrix Encoding (stereo output decoded to surround by a receiver/soundbar)\n"

    while true; do
        echo -e "${YELLOW}Selection [1-3, Default: 1]: ${NC}"
        echo -e -n "> "
        read -r OUTPUT_MODE_CHOICE
        OUTPUT_MODE_CHOICE="${OUTPUT_MODE_CHOICE:-1}"
        if [[ "$OUTPUT_MODE_CHOICE" =~ ^[123]$ ]]; then break; else echo -e "${YELLOW}${BOLD}Invalid selection. Please type 1, 2, or 3.${NC}"; fi
    done

    ENABLE_HRTF=""
    SURROUND_CHANNELS=""

    if [ "$OUTPUT_MODE_CHOICE" == "1" ]; then
        OUTPUT_MODE="stereo"

        echo ""
        echo -e "${WHITE}What are you listening on?${NC}\n"
        echo -e " 1) Auto (let OpenAL Soft decide)"
        echo -e " 2) Speakers"
        echo -e " 3) Headphones\n"

        while true; do
            echo -e "${YELLOW}Selection [1-3, Default: 1]: ${NC}"
            echo -e -n "> "
            read -r STEREO_MODE_CHOICE
            STEREO_MODE_CHOICE="${STEREO_MODE_CHOICE:-1}"
            if [[ "$STEREO_MODE_CHOICE" =~ ^[123]$ ]]; then break; else echo -e "${YELLOW}${BOLD}Invalid selection. Please type 1, 2, or 3.${NC}"; fi
        done

        case "$STEREO_MODE_CHOICE" in
            1) STEREO_MODE="auto" ;;
            2) STEREO_MODE="speakers" ;;
            3) STEREO_MODE="headphones" ;;
        esac

        if [ "$STEREO_MODE_CHOICE" == "2" ]; then
            # HRTF is a headphone-only binaural technique — meaningless (and
            # actively harmful to positional accuracy) over real speakers.
            ENABLE_HRTF="n"
        else
            echo ""
            echo -e "${CYAN}Headphones Configuration (HRTF)${NC}\n"
            echo -e "${WHITE}Head-Related Transfer Function (HRTF) translates 3D positional audio into a binaural"
            echo -e "format specifically designed for standard stereo headphones. Turning this on will"
            echo -e "allow you to hear exactly whether a sound is coming from above, below, or behind you.${NC}\n"
            echo -e "${YELLOW}Do you want to enable HRTF for headphones? (y/N): ${NC}"
            echo -e -n "> "
            read -r ENABLE_HRTF
        fi
    elif [ "$OUTPUT_MODE_CHOICE" == "2" ]; then
        OUTPUT_MODE="surround"

        echo ""
        echo -e "${WHITE}Select your speaker channel configuration:${NC}\n"
        echo -e " 1) Quad       (4.0)"
        echo -e " 2) Surround51 (5.1)"
        echo -e " 3) Surround61 (6.1)"
        echo -e " 4) Surround71 (7.1)\n"

        while true; do
            echo -e "${YELLOW}Selection [1-4]: ${NC}"
            echo -e -n "> "
            read -r SURROUND_CHOICE
            case "$SURROUND_CHOICE" in
                1) SURROUND_CHANNELS="quad"; break ;;
                2) SURROUND_CHANNELS="surround51"; break ;;
                3) SURROUND_CHANNELS="surround61"; break ;;
                4) SURROUND_CHANNELS="surround71"; break ;;
                *) echo -e "${YELLOW}${BOLD}Invalid selection. Please type 1, 2, 3, or 4.${NC}" ;;
            esac
        done
    else
        OUTPUT_MODE="matrix"
    fi

    # 7. Advanced Compatibility Tweaks
    echo ""
    print_divider
    echo -e "${CYAN}7. Advanced Compatibility Tweaks${NC}"
    print_line
    echo ""
    echo -e "${WHITE}These optional workarounds are designed for extremely stubborn games"
    echo -e "that refuse to load EAX normally. In 90% of cases, you do not need these.${NC}\n"

    echo -e "${YELLOW}Would you like to view and opt-in to these advanced tweaks? (y/N): ${NC}"
    echo -e -n "> "
    read -r SHOW_ADVANCED

    ADVANCED_DUMMY="n"
    ADVANCED_LIMITS="n"
    ADVANCED_COM="n"

    if [[ "$SHOW_ADVANCED" =~ ^[Yy]$ ]]; then
        echo -e "\n${CYAN}${BOLD}Tweak A: EAX Unified Dummy Files${NC}"
        echo -e "${WHITE}Tricks certain games (like KOTOR, Max Payne, and early Unreal Engine titles)"
        echo -e "into unlocking the EAX menu option by creating harmless, empty eax.dll and eaxunified.dll files.${NC}"
        echo -e "\n${YELLOW}Inject EAX Unified dummy files? (y/N): ${NC}"
        echo -e -n "> "
        read -r ADVANCED_DUMMY

        echo ""
        echo -e "${CYAN}${BOLD}Tweak B: Expand Audio Limits${NC}"
        echo -e "${WHITE}Forces the engine to handle 256 simultaneous sounds and locks the sample rate to 48kHz."
        echo -e "Fixes audio dropping out in chaotic games (like F.E.A.R. or Thief), but uses more CPU.${NC}"
        echo -e "\n${YELLOW}Expand OpenAL audio limits? (y/N): ${NC}"
        echo -e -n "> "
        read -r ADVANCED_LIMITS

        echo ""
        echo -e "${CYAN}${BOLD}Tweak C: COM Registry Routing${NC}"
        echo -e "${WHITE}Explicitly forces the Windows registry to point directly to our custom dsound.dll."
        echo -e "Beneficial for stubborn late-90s and early-2000s games that actively ignore local DLL files.${NC}"
        echo -e "\n${YELLOW}Inject COM registry routing? (y/N): ${NC}"
        echo -e -n "> "
        read -r ADVANCED_COM
    fi

    # 8. Automatic DLL Override
    echo ""
    print_divider
    echo -e "${CYAN}8. Automatic DLL Override${NC}"
    print_line
    echo ""
    echo -e "${WHITE}Wine needs to be told to use the new dsound.dll file instead of its built-in one."
    echo -e "We can inject this rule directly into the Wine prefix registry so you don't have to"
    echo -e "manually type WINEDLLOVERRIDES=\"dsound=n,b\" %command% into your launcher.${NC}"
    echo -e "\n${YELLOW}Automatically set dsound.dll override in Wine registry? (y/N): ${NC}"
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
    echo -e -n "${CYAN}Ready to deploy the audio files to your game and system prefix. Proceed? (Y/n): ${NC}"; read -r CONFIRM_FIN
    if [[ "$CONFIRM_FIN" =~ ^[Nn]$ ]]; then echo -e "${YELLOW}Installation aborted.${NC}"; exit 0; fi

    echo -e "\n${CYAN}STATUS: Installing Creative's OpenAL runtime into the prefix...${NC}"
    echo -e " -> Installing via $( [ "$LAUNCHER_TYPE" == "1" ] && echo "protontricks" || echo "winetricks" )..."

    # A failure here is a warning, not a deploy failure: the engine's own
    # DLLs are copied in directly below and don't depend on this package —
    # but it must never be reported as applied when the tool failed.
    OPENAL_RC=""
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        log_cmd "protontricks $APPID -q openal"
        protontricks "$APPID" -q openal 2>> "$EAX_LOG_FILE"; OPENAL_RC=$?; echo "[exit $OPENAL_RC]" >> "$EAX_LOG_FILE"
    else
        if [ -n "$WINE_CMD" ] && [ -n "$PREFIX_PATH" ]; then
            # Using --force to bypass winetricks safety blocks in Heroic
            log_cmd "winetricks --force -q openal (WINE=$WINE_CMD, prefix $PREFIX_PATH)"
            WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" WINESERVER="${WINESERVER_CMD:-}" winetricks --force -q openal 2>> "$EAX_LOG_FILE"; OPENAL_RC=$?; echo "[exit $OPENAL_RC]" >> "$EAX_LOG_FILE"
        else
            echo -e " -> ${YELLOW}Warning: No local Wine binary or resolved prefix was found, so this step is being skipped.${NC}"
        fi
    fi
    if [ "$OPENAL_RC" == "0" ]; then
        echo -e " -> ${GREEN}OpenAL was installed successfully.${NC}"
    elif [ -n "$OPENAL_RC" ]; then
        echo -e " -> ${YELLOW}${BOLD}Warning: Creative's OpenAL runtime didn't install (exit code $OPENAL_RC), so the prefix may be missing it.${NC}"
        echo -e "${WHITE}    The run log has the full output.${NC}"
    fi

   VCRUN_INSTALLED_THIS_RUN="0"
   if [[ "$INSTALL_VCRUN" =~ ^[Yy]$ ]]; then
        install_vcrun_dependencies && VCRUN_INSTALLED_THIS_RUN="1"
    fi

    # Engine-specific paths
    if [ "$ENGINE_CHOICE" == "1" ]; then
        TARGET_COMMUNITY=$(find "$DSOAL_COMMUNITY_V13" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
        DSOUND_SRC="$TARGET_COMMUNITY/dsound.dll"
        DSOAL_SRC="$TARGET_COMMUNITY/dsoal-aldrv.dll"
    elif [ "$ENGINE_CHOICE" == "2" ]; then
        TARGET_V14=$(find "$DSOAL_COMMUNITY_V14" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
        DSOUND_SRC="$TARGET_V14/dsound.dll"
        DSOAL_SRC="$TARGET_V14/dsoal-aldrv.dll"
    elif [ "$ENGINE_CHOICE" == "3" ]; then
        TARGET_DSOAL=$(find "$DSOAL_OFFICIAL" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
        TARGET_OAL=$(find "$OPENAL_OFFICIAL" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)
        DSOUND_SRC="$TARGET_DSOAL/dsound.dll"
        DSOAL_SRC="$TARGET_OAL/soft_oal.dll"
    fi

    if [ ! -f "$DSOUND_SRC" ] || [ ! -f "$DSOAL_SRC" ]; then
        echo -e "\n${YELLOW}${BOLD}Error: Required source files for the selected engine were not found in the cache.${NC}"
        echo -e "${WHITE}This usually means the download for this engine failed or was incomplete earlier in this run"
        echo -e "(check the REPOSITORY CACHE CHECK output above), or the ${ARCH_FOLDER} build isn't present in it."
        echo -e "Re-run the script to retry the download, or choose a different engine.${NC}"
        exit 1
    fi

    # Manifest of everything THIS run actually deploys, so uninstall only ever
    # touches files the script itself put there (never pre-existing user files
    # that were left alone because of a [s]kip during a conflict prompt).
    INSTALL_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"

    # On a reinstall, files this script placed last time (e.g. dsound.dll)
    # are still sitting there and will look like a "conflict" to
    # handle_conflict() below — but they're not a genuine original worth
    # backing up, they're just our own previous output. Capture the old
    # manifest's file list BEFORE truncating it so conflict handling can
    # tell the two apart and skip a backup that would otherwise bury the
    # real original (if one exists) under a backup of our own DLL.
    declare -A PREV_MANIFEST_FILES
    if [ -s "$INSTALL_MANIFEST" ]; then
        while IFS= read -r line; do
            [[ "$line" == /* ]] && PREV_MANIFEST_FILES["$line"]=1
        done < "$INSTALL_MANIFEST"
    fi

    # The prefix copy happens after the game-folder copy, so check it can be
    # written now rather than failing halfway through deployment.
    if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows/system32" ]; then
        check_target_writable "$PREFIX_PATH/drive_c/windows/system32" "Wine/Proton prefix"
    fi
    DEPLOY_FAILURES=0

    : > "$INSTALL_MANIFEST"
    [ "$VCRUN_INSTALLED_THIS_RUN" == "1" ] && echo "VCRUN" >> "$INSTALL_MANIFEST"

    echo -e "\n${CYAN}STATUS: Deploying files to local game folder...${NC}"

    if handle_conflict "$GAME_DIR/dsound.dll"; then
        deploy_copy "$DSOUND_SRC" "$GAME_DIR/dsound.dll" "Copied"
    fi

    if handle_conflict "$GAME_DIR/dsoal-aldrv.dll"; then
        deploy_copy "$DSOAL_SRC" "$GAME_DIR/dsoal-aldrv.dll" "Copied"
    fi

    # V14 is the only bundle with genuine curated HRTF profiles (V13 has
    # none, despite its zip's name — see engine descriptions above). Since
    # update_local_cache always fetches V14 up front regardless of which
    # engine ends up chosen, its HRTF set is layered onto whichever engine's
    # DLLs are actually being deployed, rather than only being available
    # when V14 itself is the chosen engine.
    HRTF_SRC_DIR=$(find "$DSOAL_COMMUNITY_V14" -type d -iname "HRTF" 2>/dev/null | head -n 1)

    if [ -n "$HRTF_SRC_DIR" ]; then
        OPENAL_DIR_PREEXISTED=0
        [ -d "$GAME_DIR/OpenAL" ] && OPENAL_DIR_PREEXISTED=1

        if ! { mkdir -p "$GAME_DIR/OpenAL/HRTF" && cp -r "$HRTF_SRC_DIR/"* "$GAME_DIR/OpenAL/HRTF/"; }; then
            record_deploy_failure "$GAME_DIR/OpenAL/HRTF"
        elif [ "$OPENAL_DIR_PREEXISTED" -eq 1 ]; then
            # The OpenAL folder was already there before this run (game files
            # or an unrelated mod) — only track the HRTF subfolder we added,
            # so uninstall can't wipe out whatever else lives alongside it.
            echo "$GAME_DIR/OpenAL/HRTF" >> "$INSTALL_MANIFEST"
        else
            echo "$GAME_DIR/OpenAL" >> "$INSTALL_MANIFEST"
        fi
        [ -d "$GAME_DIR/OpenAL/HRTF" ] && echo -e " -> Deployed: HRTF profile directory to $(basename "$GAME_DIR")"
    fi

    if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
        echo -e "\n${CYAN}STATUS: Duplicating files to Wine/Proton system prefix...${NC}"
        if [ "$ARCH" == "32" ] && [ -d "$PREFIX_PATH/drive_c/windows/syswow64" ]; then
            PREFIX_TARGET_DIR="$PREFIX_PATH/drive_c/windows/syswow64"
        else
            PREFIX_TARGET_DIR="$PREFIX_PATH/drive_c/windows/system32"
        fi

        auto_backup_and_overwrite "$PREFIX_TARGET_DIR/dsound.dll" && deploy_copy "$DSOUND_SRC" "$PREFIX_TARGET_DIR/dsound.dll" "Duplicated"

        if handle_conflict "$PREFIX_TARGET_DIR/dsoal-aldrv.dll"; then
            deploy_copy "$DSOAL_SRC" "$PREFIX_TARGET_DIR/dsoal-aldrv.dll" "Duplicated"
        fi
    fi

    echo -e "\n${CYAN}STATUS: Applying configurations and tweaks...${NC}"

    if [[ "$ADVANCED_DUMMY" =~ ^[Yy]$ ]]; then
        if handle_conflict "$GAME_DIR/eax.dll"; then
            if touch "$GAME_DIR/eax.dll"; then echo "$GAME_DIR/eax.dll" >> "$INSTALL_MANIFEST"; echo -e " -> Created: eax.dll dummy"
            else record_deploy_failure "$GAME_DIR/eax.dll"; fi
        fi
        if handle_conflict "$GAME_DIR/eaxunified.dll"; then
            if touch "$GAME_DIR/eaxunified.dll"; then echo "$GAME_DIR/eaxunified.dll" >> "$INSTALL_MANIFEST"; echo -e " -> Created: eaxunified.dll dummy"
            else record_deploy_failure "$GAME_DIR/eaxunified.dll"; fi
        fi
    fi

    if handle_conflict "$GAME_DIR/alsoft.ini"; then
        if [ "$OUTPUT_MODE" == "surround" ]; then
            # Surround speaker setups bypass HRTF (headphone-only binaural
            # processing) and stereo-only encodings entirely.
            channels="$SURROUND_CHANNELS"
            STEREO_MODE="auto"
            STEREO_ENCODING="basic"
            HRTF_MODE=""
        elif [ "$OUTPUT_MODE" == "matrix" ]; then
            # Matrix-encoded stereo output also bypasses HRTF — the
            # matrix decoder (tsme) needs an unprocessed stereo signal.
            channels="stereo"
            STEREO_MODE="auto"
            STEREO_ENCODING="tsme"
            HRTF_MODE=""
        elif [[ "$ENABLE_HRTF" =~ ^[Yy]$ ]]; then
            channels="stereo"
            STEREO_ENCODING="hrtf"
            HRTF_MODE="full"
        else
            channels="stereo"
            STEREO_ENCODING="basic"
            HRTF_MODE=""
        fi

        if [ -n "$HRTF_MODE" ]; then
            HRTF_MODE_PREFIX=""
            HRTF_VALUE="auto"
        else
            HRTF_MODE_PREFIX="# "
            HRTF_MODE="full"
            HRTF_VALUE="off"
        fi

        if [[ "$ADVANCED_LIMITS" =~ ^[Yy]$ ]]; then
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux (Advanced Tweaks)

[general]
channels = $channels
sample-type = float32
stereo-mode = $STEREO_MODE
stereo-encoding = $STEREO_ENCODING
# hrtf is deprecated in favor of hrtf-mode, kept here for older builds
hrtf = $HRTF_VALUE
${HRTF_MODE_PREFIX}hrtf-mode = $HRTF_MODE
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

# Advanced Audio Limit Expansion
sources = 256
frequency = 48000

[decoder]
resampler = spline

[EAX]
enable = true
EOF
            if [ -s "$GAME_DIR/alsoft.ini" ]; then echo "$GAME_DIR/alsoft.ini" >> "$INSTALL_MANIFEST"; echo -e " -> Generated: Advanced alsoft.ini with expanded channel limits"
            else record_deploy_failure "$GAME_DIR/alsoft.ini"; fi
        else
            cat <<EOF > "$GAME_DIR/alsoft.ini"
# Auto-generated by EAX Restore Script for Linux

[general]
channels = $channels
sample-type = float32
stereo-mode = $STEREO_MODE
stereo-encoding = $STEREO_ENCODING
# hrtf is deprecated in favor of hrtf-mode, kept here for older builds
hrtf = $HRTF_VALUE
${HRTF_MODE_PREFIX}hrtf-mode = $HRTF_MODE
hrtf-paths = HRTF, OpenAL/HRTF
period_size = 1024
periods = 3

[decoder]
resampler = spline

[EAX]
enable = true
EOF
            if [ -s "$GAME_DIR/alsoft.ini" ]; then echo "$GAME_DIR/alsoft.ini" >> "$INSTALL_MANIFEST"; echo -e " -> Generated: Linux-optimised alsoft.ini"
            else record_deploy_failure "$GAME_DIR/alsoft.ini"; fi
        fi
    fi

    if [[ "$ADVANCED_COM" =~ ^[Yy]$ ]] || [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]]; then
        REG_FILE="$GAME_DIR/dsoal_master_patch_$$.reg"
        echo "Windows Registry Editor Version 5.00" > "$REG_FILE"
        echo "" >> "$REG_FILE"

        if [[ "$ADVANCED_COM" =~ ^[Yy]$ ]]; then
            cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}\InprocServer32]
@="dsound.dll"

[HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}\InprocServer32]
@="dsound.dll"

EOF
        fi

        if [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]]; then
            cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"dsound"="native,builtin"

EOF
        fi

        # The manifest lines are written whether or not regedit succeeded: a
        # partial import can still leave keys behind, and uninstall deleting
        # a key that was never set is harmless.
        [[ "$ADVANCED_COM" =~ ^[Yy]$ ]] && echo "REGISTRY:COM" >> "$INSTALL_MANIFEST"
        [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]] && echo "REGISTRY:OVERRIDE" >> "$INSTALL_MANIFEST"
        # REG_STATUS: ok, failed (regedit itself), or missing (regedit
        # reported success but the override isn't in the prefix). The
        # override is the one registry change EAX can't work without, so
        # it's read back rather than trusting regedit's exit code alone; a
        # prefix with no user.reg to read (return 2) is left as ok.
        REG_STATUS="ok"
        if ! apply_registry_patch "$REG_FILE"; then
            REG_STATUS="failed"
        elif [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]]; then
            verify_dll_override "dsound"
            [ $? -eq 1 ] && REG_STATUS="missing"
        fi

        if [ "$REG_STATUS" == "ok" ]; then
            [[ "$ADVANCED_COM" =~ ^[Yy]$ ]] && echo -e " -> Injected: COM Registry Routing"
            [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]] && echo -e " -> Injected: WINEDLLOVERRIDES (native,builtin) into registry"
        else
            if [ "$REG_STATUS" == "failed" ]; then
                echo -e " -> ${YELLOW}${BOLD}Error: Couldn't write the registry changes to the Wine prefix, so they aren't applied.${NC}"
                echo -e "${WHITE}    The run log has the full output.${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Error: The registry import reported success, but the dsound.dll override isn't in${NC}"
                echo -e "${YELLOW}${BOLD}the prefix's registry, so Wine won't load the new DLL. The run log has the details.${NC}"
            fi
            DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
            # Show the manual WINEDLLOVERRIDES instructions instead of
            # claiming the override was handled automatically.
            [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]] && OVERRIDE_PATCH_FAILED="1"
            AUTO_OVERRIDE="n"
        fi
        rm -f "$REG_FILE"
    fi

    if [ "${DEPLOY_FAILURES:-0}" -gt 0 ]; then
        echo ""
        print_divider
        echo -e "${YELLOW}${BOLD}--- INSTALLATION INCOMPLETE ---${NC}"
        print_line
        echo -e "\n${YELLOW}${BOLD}$DEPLOY_FAILURES step(s) failed (see the errors above), so the EAX fix${NC}"
        echo -e "${YELLOW}${BOLD}is NOT fully installed. The game may run without it or fail to start.${NC}"
        echo -e "${WHITE}Fix the cause (usually a read-only drive or folder permissions), then run the"
        echo -e "script again, or choose (u)ninstall to remove what was deployed.${NC}"
        if [ -n "${OVERRIDE_PATCH_FAILED:-}" ]; then
            echo -e "\n${WHITE}Until then, you can set the DLL override by hand:"
            if [ "$LAUNCHER_TYPE" == "1" ]; then
                echo -e "  Steam Launch Options: ${CYAN}WINEDLLOVERRIDES=\"dsound=n,b\" %command%${NC}"
            else
                echo -e "  Heroic Environment Variable: ${CYAN}WINEDLLOVERRIDES${NC} = ${CYAN}dsound=n,b${NC}"
            fi
        fi
        exit 1
    fi

    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- INSTALLATION COMPLETE! ---${NC}"
    print_line

    if [[ "$AUTO_OVERRIDE" =~ ^[Yy]$ ]]; then
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
            echo -e "${CYAN}WINEDLLOVERRIDES=\"dsound=n,b\" %command%${NC}"
        else
            echo -e "${BOLD}Heroic Environment Variable:${NC}"
            echo -e "Name:  ${CYAN}WINEDLLOVERRIDES${NC}"
            echo -e "Value: ${CYAN}dsound=n,b${NC}"
        fi
    fi
    echo ""
fi
