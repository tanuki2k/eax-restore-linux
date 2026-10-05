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
# a pass only repeats when the install flow's step 1 asks for the menu.
while true; do
VCRUN_ONLY_MODE=""
DSOAL_LOG_MODE=""
SETTINGS_TOOL_MODE=""
LOCATE_METHOD=""
RESTART_REQUESTED=""
if is_truthy "$EAX_RESTORE_VCRUN_ONLY"; then
    VCRUN_ONLY_MODE="env"
else
    print_banner "SELECT OPERATION"
    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        SCRIPT_ACTION="i"
        print_result "EAX_RESTORE_DSOAL_PIN is set, so proceeding straight to install." "$GREEN"
    else
        SCRIPT_ACTION=""
        MAIN_MENU_SHOWN=1
        while [ -z "$SCRIPT_ACTION" ] && [ -z "$VCRUN_ONLY_MODE" ] && [ -z "$DSOAL_LOG_MODE" ] \
            && [ -z "$SETTINGS_TOOL_MODE" ]; do
            menu_keys=(s)
            echo -e "\n${WHITE}What would you like to do?${NC}\n"
            print_key_option "[S]can your Steam/Heroic library"
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
                t)
                    # Changing an installed game's settings, then the runtime
                    # helpers, each group under its own heading.
                    print_banner "TOOLS"
                    while true; do
                        echo -e "\n${WHITE}Game settings:${NC}"
                        print_key_option "[O]ptional settings"
                        print_key_option "[S]peaker configuration"
                        echo -e "\n${WHITE}Runtime:${NC}"
                        print_key_option "[V]C++ install"
                        print_key_option "[D]SOAL logging"
                        echo ""
                        print_key_option "[R]eturn to the main menu"
                        prompt "Selection [o/s/v/d/r]: "
                        read_answer menu_choice || exit 0
                        menu_choice="${menu_choice,,}"
                        case "$menu_choice" in
                            o) SETTINGS_TOOL_MODE="optional"; break ;;
                            s) SETTINGS_TOOL_MODE="speakers"; break ;;
                            v) VCRUN_ONLY_MODE="menu"; break ;;
                            d) DSOAL_LOG_MODE=1; break ;;
                            r|"") print_banner "SELECT OPERATION"; break ;;
                            *) print_result "That's not a valid option — please type o, s, v, d or r." "$YELLOW" ;;
                        esac
                    done
                    ;;
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
        echo -e "\n${WHITE}This run only installs the MS VC++ 2022 Redistributable into a game's prefix —"
        echo -e "DSOAL, OpenAL Soft, alsoft.ini and registry overrides aren't touched.${NC}"
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
        get_game_directory ""
        # Only step 1's [R]eturn to the main menu sets it here.
        [ -n "$RESTART_REQUESTED" ] && continue 2

        print_step 2 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    select_architecture

    print_banner "READY"
    echo -e "\n${WHITE}This will attempt to install the MS VC++ 2022 Redistributable into:${NC}"
    [ "$LAUNCHER_TYPE" == "1" ] && echo -e "${WHITE} -> Steam AppID: ${BOLD}$APPID${NC}"
    [ -n "$PREFIX_PATH" ] && echo -e "${WHITE} -> Prefix: ${BOLD}$(tilde_path "$PREFIX_PATH")${NC}"
    echo -e "\n${YELLOW}Proceed? (Y/n): ${NC}"
    echo -e -n "> "
    read_answer CONFIRM_VCRUN_ONLY
    if [[ "$CONFIRM_VCRUN_ONLY" =~ $NO_RE ]]; then
        print_result "Cancelled — no changes were made." "$YELLOW"
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

