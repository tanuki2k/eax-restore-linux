# Set EAX_RESTORE_VCRUN_ONLY=1 to skip everything else and just (re)install the
# MS VC++ 2022 Redistributable into a game's prefix — e.g. if you skipped it
# during a normal install and want to go back for it without redoing the rest.
# The main menu offers the same thing under Tools.
EAX_RESTORE_VCRUN_ONLY="${EAX_RESTORE_VCRUN_ONLY:-}"
# Guarded here (the earliest point it's read) so cache.sh and config-flow.sh
# downstream can test it freely.
EAX_RESTORE_DSOAL_PIN="${EAX_RESTORE_DSOAL_PIN:-}"

# ==============================================================================
# MAIN MENU (SELECT OPERATION)
# ==============================================================================
# One letter menu for everything: the three install paths (each tells step 1
# how to find the game, so it doesn't ask again), uninstalling the fix, the
# Tools submenu, and quitting. Skipped when an environment variable has
# already decided the run.
#
# Everything from here to the end of install-flow.sh runs inside one loop, so
# install step 1 can come back here (see MAIN_MENU_SHOWN): it's opened here
# and closed at the very bottom of install-flow.sh, the same way the install
# "if" spans config-flow.sh and install-flow.sh. Every flow ends in exit, so
# a pass only repeats when the install flow's step 1 asks for the menu, or a
# tool is left without finishing (OPEN_TOOLS_MENU: back to the Tools menu).

# Usage: tools_menu
# The Tools submenu: changing an installed game's settings, browsing the
# game database, then the runtime helpers, each group under its own heading.
# Sets the chosen tool's mode, or shows the SELECT OPERATION banner again for
# [R]eturn to the main menu.
# [O]ptional settings is left out when the game database is missing, since
# the settings come from the game's profile in it, and so is [B]rowse, which
# also needs a terminal for fzf. [B]rowse runs right here and comes back to
# this menu, since it doesn't pick a game.
tools_menu() {
    local -a tool_keys
    print_banner "TOOLS"
    while true; do
        tool_keys=()
        echo -e "\n${WHITE}Game settings:${NC}"
        if [ -n "$GAME_DATABASE_FILE" ]; then
            print_key_option "[O]ptional settings"; tool_keys+=(o)
        fi
        print_key_option "[S]peaker configuration"; tool_keys+=(s)
        if [ -n "$GAME_DATABASE_FILE" ] && interactive_tty; then
            echo -e "\n${WHITE}Game database:${NC}"
            print_key_option "[B]rowse game profiles"; tool_keys+=(b)
        fi
        echo -e "\n${WHITE}Runtime:${NC}"
        print_key_option "[V]C++ install"
        print_key_option "[D]SOAL logging"
        echo ""
        print_key_option "[R]eturn to the main menu"
        tool_keys+=(v d r)
        prompt "Selection [$(IFS=/; echo "${tool_keys[*]}")]: "
        read_answer menu_choice || exit 0
        menu_choice="${menu_choice,,}"
        [ -z "$menu_choice" ] || [[ " ${tool_keys[*]} " == *" $menu_choice "* ]] || menu_choice="?"
        case "$menu_choice" in
            o) SETTINGS_TOOL_MODE="optional"; return ;;
            s) SETTINGS_TOOL_MODE="speakers"; return ;;
            b) browse_game_database_tool ;;
            v) VCRUN_ONLY_MODE="menu"; return ;;
            d) DSOAL_LOG_MODE=1; return ;;
            r|"") print_banner "SELECT OPERATION"; return ;;
            *) print_result "That's not a valid option — please type $(join_choices "${tool_keys[@]}")." "$YELLOW" ;;
        esac
    done
}

# Usage: browse_game_database_tool
# Tools → [B]rowse game profiles. fzf isn't one of the script's own
# requirements, so it's offered here, the one place that needs it.
browse_game_database_tool() {
    if ! command -v fzf &> /dev/null; then
        print_note "Browsing the game profiles needs fzf, which isn't installed."
        if is_steamos; then
            print_paragraph "SteamOS's system files are read-only, so this script can't install it."
            return
        fi
        confirm "Install fzf now? (Requires sudo)" || return
        install_packages fzf || return
        command -v fzf &> /dev/null || return
    fi
    if ! fzf_at_least 0.35; then
        print_note "Browsing the game profiles needs fzf 0.35 or newer, and this system has" \
            "$(fzf --version | awk '{ print $1 }'). Your package manager's updates may have a newer one."
        return
    fi
    browse_game_database
}

while true; do
VCRUN_ONLY_MODE=""
DSOAL_LOG_MODE=""
SETTINGS_TOOL_MODE=""
LOCATE_METHOD=""
RESTART_REQUESTED=""
if is_truthy "$EAX_RESTORE_VCRUN_ONLY"; then
    VCRUN_ONLY_MODE="env"
else
    [ -n "$OPEN_TOOLS_MENU" ] || print_banner "SELECT OPERATION"
    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        SCRIPT_ACTION="i"
        print_result "EAX_RESTORE_DSOAL_PIN is set, so proceeding straight to install." "$GREEN"
    else
        SCRIPT_ACTION=""
        MAIN_MENU_SHOWN=1
        while [ -z "$SCRIPT_ACTION" ] && [ -z "$VCRUN_ONLY_MODE" ] && [ -z "$DSOAL_LOG_MODE" ] \
            && [ -z "$SETTINGS_TOOL_MODE" ]; do
            # A tool left without finishing comes back to the Tools menu.
            if [ -n "$OPEN_TOOLS_MENU" ]; then
                OPEN_TOOLS_MENU=""
                tools_menu
                continue
            fi
            # [S]can is left out when the game database is missing, since
            # it matches the libraries against it.
            menu_keys=()
            echo -e "\n${WHITE}What would you like to do?${NC}\n"
            if [ -n "$GAME_DATABASE_FILE" ]; then
                print_key_option "[S]can your Steam/Heroic library"; menu_keys+=(s)
            fi
            if gui_picker_available; then
                print_key_option "[B]rowse for the game folder"; menu_keys+=(b)
            fi
            print_key_option "[M]anually type the game path"; menu_keys+=(m)
            echo ""
            print_key_option "[U]ninstall the EAX fix"
            print_key_option "[T]ools"
            echo ""
            print_key_option "[Q]uit"
            menu_keys+=(u t q)
            prompt "Selection [$(IFS=/; echo "${menu_keys[*]}")]: "
            read_answer menu_choice || exit 0
            menu_choice="${menu_choice,,}"
            [[ " ${menu_keys[*]} " == *" $menu_choice "* ]] || menu_choice="?"
            case "$menu_choice" in
                s) SCRIPT_ACTION="i"; LOCATE_METHOD="scan" ;;
                b) SCRIPT_ACTION="i"; LOCATE_METHOD="gui" ;;
                m) SCRIPT_ACTION="i"; LOCATE_METHOD="manual" ;;
                u) SCRIPT_ACTION="u" ;;
                q) exit 0 ;;
                t) tools_menu ;;
                *) print_result "That's not a valid option — please type $(join_choices "${menu_keys[@]}")." "$YELLOW" ;;
            esac
        done
    fi
fi

# ==============================================================================
# STANDALONE VC++ RUNTIME INSTALL
# ==============================================================================
# Tools → [V]C++ install, or EAX_RESTORE_VCRUN_ONLY=1.
if [ -n "$VCRUN_ONLY_MODE" ]; then
    print_banner "VC++ RUNTIME ONLY MODE"
    if [ "$VCRUN_ONLY_MODE" == "env" ]; then
        echo -e "\n${WHITE}EAX_RESTORE_VCRUN_ONLY is set, so this run will only install the MS VC++ 2022"
        echo -e "Redistributable into a game's prefix — nothing else the script normally does (DSOAL,"
        echo -e "OpenAL Soft, alsoft.ini, registry overrides) will be touched.${NC}"
        echo -e "\n${WHITE}Unset EAX_RESTORE_VCRUN_ONLY to return to the normal install/uninstall flow.${NC}"
    else
        tool_gate "This installs the MS VC++ 2022 Redistributable into a game's prefix —" \
            "DSOAL, OpenAL Soft, alsoft.ini and registry overrides aren't touched." \
            || { OPEN_TOOLS_MENU=1; continue; }
    fi

    SCRIPT_ACTION="i"

    # Fixed step count for this flow (1-2) — read by print_step via the
    # STEP_TOTAL global so headers show "N/2. Label" instead of just "N. Label".
    STEP_TOTAL=2

    # Steps 1-2 loop, same as the normal install flow: an EAX-impossible game
    # still lets the user pick a different one instead of exiting (see
    # prompt_restart_or_quit).
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        print_paragraph "This step finds the folder the game is installed in."
        get_game_directory ""
        # Only step 1's [R]eturn sets it here: back to the Tools menu.
        [ -n "$RESTART_REQUESTED" ] && { OPEN_TOOLS_MENU=1; continue 2; }

        print_step 2 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    select_architecture
    # Steam apps that run this game from its folder with their own prefix
    # (DOOM 3's Resurrection of Evil) get the runtime too.
    resolve_companion_apps "$APPID"

    print_banner "READY"
    echo -e "\n${WHITE}This will attempt to install the MS VC++ 2022 Redistributable into:${NC}"
    [ "$LAUNCHER_TYPE" == "1" ] && echo -e "${WHITE} -> Steam AppID: ${BOLD}$APPID${NC}"
    [ -n "$PREFIX_PATH" ] && echo -e "${WHITE} -> Prefix: ${BOLD}$(tilde_path "$PREFIX_PATH")${NC}"
    for i in "${!COMPANION_IDS[@]}"; do
        echo -e "${WHITE} -> ${COMPANION_NAMES[$i]}'s prefix: ${BOLD}$(tilde_path "${COMPANION_PREFIXES[$i]}")${NC}"
    done
    echo -e "\n${YELLOW}Proceed? (Y/n): ${NC}"
    echo -e -n "> "
    read_answer CONFIRM_VCRUN_ONLY
    if [[ "$CONFIRM_VCRUN_ONLY" =~ $NO_RE ]]; then
        print_result "Cancelled — no changes were made." "$YELLOW"
        exit 0
    fi

    if install_vcrun_dependencies; then
        GAME_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
        if [ ! -s "$GAME_MANIFEST" ] || manifest_is_uninstalled "$GAME_MANIFEST"; then
            # A new manifest, or a stale "already uninstalled" sentinel, which
            # would otherwise make a future uninstall run stop before ever
            # reading this marker.
            start_manifest "$GAME_MANIFEST"
        fi
        echo "VCRUN" >> "$GAME_MANIFEST"
        # Each companion's own prefix, recorded with its AppID like an
        # install's (see prefix-steps.sh).
        COMPANION_VCRUN_FAILED=""
        for i in "${!COMPANION_IDS[@]}"; do
            VCRUN_TASK_FOR="${COMPANION_NAMES[$i]}"
            if with_companion "$i" install_vcrun_dependencies; then
                printf 'VCRUN\t%s\n' "${COMPANION_IDS[$i]}" >> "$GAME_MANIFEST"
            else
                COMPANION_VCRUN_FAILED+="${COMPANION_VCRUN_FAILED:+, }${COMPANION_NAMES[$i]}"
            fi
            VCRUN_TASK_FOR=""
        done
        if [ -n "$COMPANION_VCRUN_FAILED" ]; then
            print_run_summary
            print_banner "VC++ RUNTIME INSTALL INCOMPLETE" "$YELLOW"
            print_error "The core VC++ runtime files couldn't be verified in ${COMPANION_VCRUN_FAILED}'s prefix," \
                "so the runtime isn't installed there. The installer output is saved in $VCRUN_LOG."
            exit 1
        fi
    else
        print_run_summary
        print_banner "VC++ RUNTIME INSTALL INCOMPLETE" "$YELLOW"
        print_error "The core VC++ runtime files couldn't be verified in the prefix, so the runtime" \
            "isn't installed. The installer output is saved in $VCRUN_LOG."
        exit 1
    fi

    print_run_summary
    print_banner "VC++ RUNTIME INSTALL COMPLETE"
    exit 0
fi

