# Set EAX_RESTORE_VCRUN_ONLY=1 to skip everything else and just (re)install the
# MS VC++ 2022 Redistributable into a game's prefix — e.g. if you skipped it
# during a normal install and want to go back for it without redoing the rest.
# The main menu offers the same thing under Utilities.
EAX_RESTORE_VCRUN_ONLY="${EAX_RESTORE_VCRUN_ONLY:-}"
# Guarded here (the earliest point it's read) so cache.sh and config-flow.sh
# downstream can test it freely.
EAX_RESTORE_DSOAL_PIN="${EAX_RESTORE_DSOAL_PIN:-}"

# ==============================================================================
# MAIN MENU (SELECT OPERATION)
# ==============================================================================
# One letter menu for everything: the three install paths (each tells step 1
# how to find the game, so it doesn't ask again), removing the fix, the
# Utilities submenu, and quitting. Skipped when an environment variable has
# already decided the run.
VCRUN_ONLY_MODE=""
DSOAL_LOG_MODE=""
if is_truthy "$EAX_RESTORE_VCRUN_ONLY"; then
    VCRUN_ONLY_MODE="env"
else
    print_banner "SELECT OPERATION"
    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        SCRIPT_ACTION="i"
        print_result "EAX_RESTORE_DSOAL_PIN is set, so proceeding straight to install." "$GREEN"
    else
        SCRIPT_ACTION=""
        while [ -z "$SCRIPT_ACTION" ] && [ -z "$VCRUN_ONLY_MODE" ] && [ -z "$DSOAL_LOG_MODE" ]; do
            menu_keys=(s)
            echo -e "\n${WHITE}What would you like to do?${NC}\n"
            print_key_option "[S]can your Steam/Heroic library"
            if gui_picker_available; then
                print_key_option "[B]rowse for the game folder"; menu_keys+=(b)
            fi
            print_key_option "[M]anually type the game path"; menu_keys+=(m)
            echo ""
            print_key_option "[R]emove the EAX fix"
            print_key_option "[U]tilities"
            print_key_option "[Q]uit"
            menu_keys+=(r u q)
            prompt "Selection [$(IFS=/; echo "${menu_keys[*]}")]: "
            read_answer menu_choice || exit 0
            menu_choice="${menu_choice,,}"
            [[ " ${menu_keys[*]} " == *" $menu_choice "* ]] || menu_choice="?"
            case "$menu_choice" in
                s) SCRIPT_ACTION="i"; LOCATE_METHOD="scan" ;;
                b) SCRIPT_ACTION="i"; LOCATE_METHOD="gui" ;;
                m) SCRIPT_ACTION="i"; LOCATE_METHOD="manual" ;;
                r) SCRIPT_ACTION="u" ;;
                q) exit 0 ;;
                u)
                    print_banner "UTILITIES"
                    while true; do
                        echo ""
                        print_key_option "[V]C++ runtime install"
                        print_key_option "[D]SOAL logging for a game"
                        print_key_option "[B]ack to the main menu"
                        prompt "Selection [v/d/b]: "
                        read_answer menu_choice || exit 0
                        menu_choice="${menu_choice,,}"
                        case "$menu_choice" in
                            v) VCRUN_ONLY_MODE="menu"; break ;;
                            d) DSOAL_LOG_MODE=1; break ;;
                            b|"") print_banner "SELECT OPERATION"; break ;;
                            *) print_result "That's not a valid option — please type v, d or b." "$YELLOW" ;;
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
# Utilities → [V]C++ runtime install, or EAX_RESTORE_VCRUN_ONLY=1.
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

