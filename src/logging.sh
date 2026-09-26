# ==============================================================================
# RUN LOG
# ==============================================================================
# Every run gets its own timestamped log in $LOG_DIR (newest 10 kept, with
# latest.log always pointing at the current one; the path is shown on exit), so a bug report can attach
# the full picture: everything shown on screen, the answers typed at its
# prompts, the output of the Wine /
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
    # (step headings read "3. Label", or "3/8. Label" once STEP_TOTAL is set).
    last_section=$(grep -E '^[0-9]+(/[0-9]+)?\. [A-Z]|^--- .* ---$' "$EAX_LOG_FILE" | tail -n 1)
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
    # Release a pinned PHASE 2 progress bar first, or an exit mid-deploy
    # leaves the terminal scrolling inside its region.
    end_phase_progress
    # Own line, with $HOME shown as ~, so the path fits the 76-column layout.
    echo -e "\n${WHITE}Log saved to:${NC}"
    echo -e "  ${GREEN}${EAX_LOG_FILE/#$HOME/\~}${NC}"
    if [ "$rc" -ne 0 ]; then
        echo -e "\n${YELLOW}If something went wrong, please attach this log to a bug report:${NC}"
        echo -e "  ${WHITE}$BUG_REPORT_URL${NC}"
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
    # curl's \r progress bars collapsed to their final state, and the
    # answers read_answer sends as a private OSC unwrapped onto their
    # prompt's line. tee and the
    # log writer run in their own session (setsid) so a Ctrl-C at the
    # terminal can't kill them before the "Log saved" line and summary are
    # written; the writer's PID is recorded so finish_run_log can wait for
    # it to drain.
    exec 3>&1 4>&2
    exec > >(exec setsid bash -c 'exec tee >(echo "$BASHPID" > "$1.pid"; exec sed -u -e "s/\x1b\]7137;\([^\x07]*\)\x07/\1/g" -e "s/\x1b\[[0-9;]*[A-Za-z]//g" -e "s/.*\r//" >> "$1")' _ "$EAX_LOG_FILE") 2>&1
    trap finish_run_log EXIT
    # Turn Ctrl-C / kill into a normal exit with the conventional status, so
    # the EXIT trap above records the real exit code (not the last command's).
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi
