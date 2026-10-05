# ==============================================================================
# ACTION: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "u" ]; then
    # Two phases, like the install: Phase 1 (steps 1-7) asks every question
    # and changes nothing; Phase 2 does all of it after one "Proceed?".
    # Fixed step count for Phase 1 (1-7) — read by print_step via the
    # STEP_TOTAL global so headers show "N/7. Label" instead of just "N. Label".
    # Step 7 ("Game Settings") only appears when the install changed any.
    STEP_TOTAL=7

    print_banner "UNINSTALL — PHASE 1: CONFIGURATION"

    # Steps 1-2 loop: same restart-on-dead-end mechanism as the install flow
    # (see the comment in config-flow.sh). Two things set RESTART_REQUESTED
    # here: step 1's [R]eturn to the main menu (continue 2, back to it) and
    # the no-prefix / no-AppID dead end in detect_game_environment (back to
    # step 1) — the EAX-impossible checks are install-only.
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        get_game_directory ""
        # Only step 1's [R]eturn to the main menu sets it here.
        [ -n "$RESTART_REQUESTED" ] && continue 2
        check_target_writable "$GAME_DIR" "game folder"

        print_step 2 "Launcher Identification"
        detect_game_environment
        [ -n "$RESTART_REQUESTED" ] && continue

        break
    done

    print_step 3 "Scanning For Installed Files"

    FILES_TO_REMOVE=()
    INSTALL_MANIFEST="$GAME_DIR/.eax-restore-manifest.txt"
    MANIFEST_FOUND=0
    REG_HAS_COM="n"
    REG_HAS_OVERRIDE="n"
    REG_OVERRIDE_DLL=""
    VCRUN_INSTALLED="n"
    CONFIG_LINES=()
    LAUNCHER_LINES=()

    if [ -s "$INSTALL_MANIFEST" ] && head -n 1 "$INSTALL_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
        print_task "Reading the install manifest"
        print_status "This game was already uninstalled in a previous run, so there's nothing left to remove." "$GREEN"
        print_status "If you've copied DSOAL/OpenAL files in by hand since, remove those yourself — there's no install record for them." ""
        exit 0
    fi

    if [ -s "$INSTALL_MANIFEST" ]; then
        MANIFEST_FOUND=1
        print_task "Reading the install manifest"
        print_detected "Found" "$INSTALL_MANIFEST"
        while IFS= read -r manifest_entry; do
            [ -z "$manifest_entry" ] && continue
            case "$manifest_entry" in
                # The format header (MANIFEST_HEADER) and any other comment.
                \#*) continue ;;
                "REGISTRY:COM") REG_HAS_COM="y"; continue ;;
                # Bare "REGISTRY:OVERRIDE" (no DLL suffix) is only ever read,
                # never written, by this version of the script — it's kept
                # for backward compatibility with manifests written by older
                # versions, from before the DLL name was appended (when
                # dsound was the only possible override).
                "REGISTRY:OVERRIDE") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="dsound"; continue ;;
                "REGISTRY:OVERRIDE:dsound") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="dsound"; continue ;;
                "REGISTRY:OVERRIDE:openal32") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="openal32"; continue ;;
                "VCRUN") VCRUN_INSTALLED="y"; continue ;;
                # Game settings changed in the game's own config files —
                # reverted in step 7, never removed as files.
                CONFIG:*) CONFIG_LINES+=("$manifest_entry"); continue ;;
                # The DLL override added to Steam's launch options / Heroic's
                # environment variables — reverted in step 5.
                LAUNCHER:*) LAUNCHER_LINES+=("$manifest_entry"); continue ;;
            esac
            { [ -e "$manifest_entry" ] || [ -L "$manifest_entry" ]; } && FILES_TO_REMOVE+=("$manifest_entry")
        done < "$INSTALL_MANIFEST"
    else
        print_task "Scanning for EAX files"
        print_status "No install manifest found (an older version of the script, or it was deleted), so looking for known DSOAL/OpenAL file names." ""
        print_warning_arrow "This can also pick up files that were already there before the script ran."

        TARGET_FILES=("dsound.dll" "dsoal-aldrv.dll" "dsound.vxd" "OpenAL32.dll" "eax.dll" "eaxunified.dll" "alsoft.ini")

        # Check the game folder, plus any extra exe folders the game profile
        # entry lists (GOG's F.E.A.R. Platinum expansions), which an install
        # fills the same way
        if [ "$LAUNCHER_TYPE" == "1" ]; then
            resolve_extra_exe_folders "$APPID" "steam"
        else
            resolve_extra_exe_folders "${HEROIC_APP_NAME:-}" "gog"
        fi
        for scan_dir in "$GAME_DIR" "${EXTRA_GAME_DIRS[@]}"; do
            for file in "${TARGET_FILES[@]}"; do
                [ -e "$scan_dir/$file" ] && FILES_TO_REMOVE+=("$scan_dir/$file")
                [ -L "$scan_dir/$file" ] && FILES_TO_REMOVE+=("$scan_dir/$file")
            done
            [ -d "$scan_dir/OpenAL" ] && FILES_TO_REMOVE+=("$scan_dir/OpenAL")
        done

        # Check prefix system folders
        if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
            for file in "dsound.dll" "dsoal-aldrv.dll" "OpenAL32.dll"; do
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

    # What was found, one line each — the steps below act on it.
    bak_count=0
    for f in "${FILES_TO_REMOVE[@]}"; do compgen -G "$f.bak*" >/dev/null && bak_count=$((bak_count + 1)); done
    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ]; then
        if [ "$MANIFEST_FOUND" -eq 1 ]; then print_status "Game files: none left to remove" ""
        else print_status "Game files: none found" ""; fi
    elif [ "$bak_count" -gt 0 ]; then
        print_status "Game files: ${#FILES_TO_REMOVE[@]} (${bak_count} with a backed-up original to put back)" ""
    else
        print_status "Game files: ${#FILES_TO_REMOVE[@]}" ""
    fi
    for line in "${LAUNCHER_LINES[@]}"; do
        mapfile -t -d $'\t' f_fields < <(printf '%s' "${line#LAUNCHER:}")
        OVERRIDE_LAUNCHER="${f_fields[0]}"
        print_status "Launcher: a DLL override in $(launcher_override_where)" ""
    done
    reg_what=""
    [ "$REG_HAS_COM" == "y" ] && reg_what="COM routing"
    [ "$REG_HAS_OVERRIDE" == "y" ] && reg_what+="${reg_what:+ and }the ${REG_OVERRIDE_DLL:-dsound/openal32} override"
    if [ "$MANIFEST_FOUND" -eq 1 ]; then
        print_status "Registry: ${reg_what:-nothing was added during install}" ""
    fi
    if [ "$VCRUN_INSTALLED" == "y" ]; then
        print_status "VC++ runtime: installed by this script" ""
    elif [ "$VCRUN_PRESENT" == "y" ]; then
        print_status "VC++ runtime: found in the prefix" ""
    fi
    if [ ${#CONFIG_LINES[@]} -gt 0 ]; then
        settings_count="$(for line in "${CONFIG_LINES[@]}"; do cut -f1,2 <<< "${line#CONFIG:}"; done | sort -u | wc -l)"
        print_status "Game settings: ${settings_count} changed during install" ""
    fi

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ] && [ "$REG_HAS_COM" == "n" ] && [ "$REG_HAS_OVERRIDE" == "n" ] && [ "$VCRUN_PRESENT" == "n" ] && [ ${#CONFIG_LINES[@]} -eq 0 ] && [ ${#LAUNCHER_LINES[@]} -eq 0 ]; then
        print_status "Nothing from this script was found in the game folder or prefix, so there's nothing to remove." ""
        exit 0
    fi

    print_step 4 "Game Files"

    # Phase 1 only works out what to do; nothing is removed until Phase 2.
    FILES_DECLINED="0"
    FINAL_REMOVE=()
    FINAL_RESTORE_TARGETS=()
    FINAL_RESTORE_SOURCES=()
    print_task "Checking game files"
    if [ ${#FILES_TO_REMOVE[@]} -gt 0 ]; then
        noun="files"; [ ${#FILES_TO_REMOVE[@]} -eq 1 ] && noun="file"
        print_status "${#FILES_TO_REMOVE[@]} ${noun} to remove; backed-up originals are put back automatically." ""
        print_warning_arrow "Anything overwritten without a backup can't be recovered — if the game won't start afterwards, use the launcher's verify/repair files option."
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
                printf "%2d  %s  " "$idx" "$(tilde_path "$f")"; echo -e "${GREEN}(original will be restored)${NC}"
            else
                printf "%2d  %s\n" "$idx" "$(tilde_path "$f")"
            fi
            idx=$((idx + 1))
        done

        echo -e "\n${YELLOW}Press Enter to remove all of these, or type the numbers of just the ones you"
        echo -e "want (e.g. \"1 2 3\", \"1-3\", or \"^4\" to remove everything except 4), or 'n' to keep them: ${NC}"
        echo -e -n "> "
        read_answer CONFIRM_UNINSTALL

        if [[ "$CONFIRM_UNINSTALL" =~ $NO_RE ]]; then
            FILES_DECLINED="1"
        else
            parse_selection "${#FILES_TO_REMOVE[@]}" "$CONFIRM_UNINSTALL"

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
                print_status "Nothing selected, so no files will be removed." "$YELLOW"
                FILES_DECLINED="1"
            else
                # A partial removal means some tracked files will still be
                # genuinely there — the "fully uninstalled" sentinel must not
                # be written in that case, same as a full decline.
                [ ${#FINAL_REMOVE[@]} -lt ${#FILES_TO_REMOVE[@]} ] && FILES_DECLINED="1"
            fi
        fi
    else
        print_status "No DSOAL/OpenAL files left to remove." ""
    fi

    print_step 5 "Registry and Launcher Cleanup"

    # Launcher overrides: say which will be removed, and if their launcher is
    # running now, ask here whether to close it, so Phase 2 doesn't stop to ask.
    LAUNCHER_WORK=0
    print_task "Checking launcher and registry changes"
    if [ ${#LAUNCHER_LINES[@]} -gt 0 ]; then
        for line in "${LAUNCHER_LINES[@]}"; do
            mapfile -t -d $'\t' f_fields < <(printf '%s' "${line#LAUNCHER:}")
            OVERRIDE_LAUNCHER="${f_fields[0]}"; OVERRIDE_FILE="${f_fields[1]}"; OVERRIDE_ID="${f_fields[2]}"
            [ -f "$OVERRIDE_FILE" ] || continue
            where="$(launcher_override_where)"
            print_status "${where^}: the DLL override will be removed" ""
            ask_close_launcher_early "$OVERRIDE_LAUNCHER" remove
            [ "${LAUNCHER_CLOSE_ANSWER[$OVERRIDE_LAUNCHER]:-}" == "n" ] \
                && print_status "The DLL override will stay in $(launcher_override_where)." "$YELLOW" \
                || LAUNCHER_WORK=1
        done
    fi

    if [ "$MANIFEST_FOUND" -eq 1 ]; then
        if [[ "$REG_HAS_COM" == "y" || "$REG_HAS_OVERRIDE" == "y" ]]; then
            print_status "Registry: ${reg_what} will be removed" ""
            REMOVE_REG="y"
        else
            print_status "Registry: nothing was added during install, so nothing to clean up" ""
            REMOVE_REG="n"
        fi
    else
        print_status "Registry: there's no install manifest to check, so only say yes if you turned on the DLL override or COM routing in the registry during install." ""
        if confirm "Do you want to remove Override/COM keys from the Wine registry?" N; then
            REG_HAS_COM="y"; REG_HAS_OVERRIDE="y"; REMOVE_REG="y"
        else
            REMOVE_REG="n"
        fi
    fi
    if [[ "$REMOVE_REG" =~ $YES_RE ]] && [ -z "$APPID" ] && [ ! -d "$PREFIX_PATH/drive_c" ]; then
        print_note_arrow "No prefix or AppID was found for this game, so there's nothing to clean up in the registry."
        REMOVE_REG="n"
    fi

    print_step 6 "VC++ Runtime"

    UNINSTALL_VCRUN="n"
    print_task "Checking for the VC++ runtime"
    if [ "$VCRUN_PRESENT" == "y" ]; then
        print_status "Found the MS VC++ 2022 Redistributable in this prefix." ""
        print_status "Only remove it if nothing else sharing this prefix needs it." ""
        confirm "Also remove the VC++ 2022 Redistributable from this prefix?" N && UNINSTALL_VCRUN="y"
    else
        print_status "Not installed in this prefix, so nothing to do." ""
    fi

    choose_game_settings_to_revert 7

    if [ ${#FINAL_REMOVE[@]} -eq 0 ] && [ "$LAUNCHER_WORK" -eq 0 ] && [[ ! "$REMOVE_REG" =~ $YES_RE ]] \
        && [ "$UNINSTALL_VCRUN" == "n" ] && [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -eq 0 ]; then
        echo -e "\n${WHITE}Nothing to change, so the uninstall is finished.${NC}"
        exit 0
    fi

    # ==============================================================================
    # UNINSTALL PHASE 2: EXECUTION
    # ==============================================================================
    print_banner "UNINSTALL — PHASE 2: EXECUTION"
    if ! confirm "Ready to remove the EAX fix from ${GAME_NAME:-this game}. Proceed?"; then
        echo -e "\n${YELLOW}Uninstall cancelled. Nothing was changed.${NC}"
        exit 0
    fi

    # One bar step per STATUS: header below.
    phase_total=0
    [ ${#FINAL_REMOVE[@]} -gt 0 ] && phase_total=$(( phase_total + 1 ))
    [ "$LAUNCHER_WORK" -eq 1 ] && phase_total=$(( phase_total + 1 ))
    [[ "$REMOVE_REG" =~ $YES_RE ]] && phase_total=$(( phase_total + 1 ))
    [ "$UNINSTALL_VCRUN" == "y" ] && phase_total=$(( phase_total + 1 ))
    [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ] && phase_total=$(( phase_total + 1 ))
    start_phase_progress "$phase_total"

    if [ ${#FINAL_REMOVE[@]} -gt 0 ]; then
        print_phase_task "Removing game files"
        for f in "${FINAL_REMOVE[@]}"; do rm -rf "$f"; done
        for i in "${!FINAL_RESTORE_TARGETS[@]}"; do
            mv "${FINAL_RESTORE_SOURCES[$i]}" "${FINAL_RESTORE_TARGETS[$i]}" \
                && print_status "Restored original $(basename "${FINAL_RESTORE_TARGETS[$i]}") in $(dirname "${FINAL_RESTORE_TARGETS[$i]}")"
            # Any other .bak* files still sitting around for this
            # same target are leftover junk — most likely backups
            # of our own prior output from before reinstalls were
            # handled correctly, not additional genuine originals —
            # so there's nothing left worth keeping them for.
            rm -f "${FINAL_RESTORE_TARGETS[$i]}".bak* 2>/dev/null
        done
        print_status "Selected files removed successfully." "$GREEN"
    fi

    if [ "$FILES_DECLINED" == "0" ]; then
        # Leave a sentinel behind rather than deleting the manifest outright.
        # If uninstall gets run again on this same game later, this lets the
        # script recognize "already cleaned up, nothing to do" and exit safely
        # instead of falling back to a filename-based guess — which could
        # otherwise mistake a just-restored original dsound.dll for one of
        # ours and delete it a second time. Skipped entirely if the user
        # declined removal in step 4, since the original manifest still
        # describes files that are genuinely still there.
        echo "# EAX Restore: uninstalled on $(date -u +"%Y-%m-%dT%H:%M:%SZ"). Nothing left to remove." > "$INSTALL_MANIFEST"
    fi

    LAUNCHER_LINES_KEPT=()
    if [ ${#LAUNCHER_LINES[@]} -gt 0 ]; then
        [ "$LAUNCHER_WORK" -eq 1 ] && print_phase_task "Removing the DLL override from the launcher"
        revert_launcher_overrides
    fi

    if [[ "$REMOVE_REG" =~ $YES_RE ]]; then
        print_phase_task "Cleaning registry"
        # Written into GAME_DIR rather than a temp dir: apply_registry_patch
        # (detection.sh) runs `protontricks -c` for Steam games, which
        # executes inside a Steam Runtime container that may not have
        # /tmp bind-mounted — the game's own library folder is
        # guaranteed to be visible instead.
        REG_FILE="$GAME_DIR/dsoal_registry_clean_$$.reg"
        echo "Windows Registry Editor Version 5.00" > "$REG_FILE"
        echo "" >> "$REG_FILE"

        if [[ "$REG_HAS_OVERRIDE" == "y" ]]; then
            if [ -z "$REG_OVERRIDE_DLL" ]; then
                # No manifest to say which DLL was overridden (dsound or
                # openal32) — clear both defensively; deleting a key that
                # was never set is a harmless no-op.
                cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"dsound"=-
"openal32"=-

EOF
            else
                cat <<EOF >> "$REG_FILE"
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"$REG_OVERRIDE_DLL"=-

EOF
            fi
        fi

        if [[ "$REG_HAS_COM" == "y" ]]; then
            cat <<EOF >> "$REG_FILE"
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
EOF
        fi

        if apply_registry_patch "$REG_FILE"; then
            print_status "Registry keys safely removed." "$GREEN"
        else
            print_warning_arrow "The registry keys couldn't be removed from the Wine prefix. The run log has the full output."
        fi
        rm -f "$REG_FILE"
    fi

    if [ "$UNINSTALL_VCRUN" == "y" ]; then
        print_phase_task "Removing the MS VC++ 2022 Redistributable"
        uninstall_vcrun_dependencies
    fi

    if [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ]; then
        print_phase_task "Putting back game settings"
        revert_game_settings
    fi

    # Settings the player chose to keep stay in the manifest, so a later
    # uninstall can still put them back. If the files step already replaced
    # the manifest with the "uninstalled" marker, the kept lines replace the
    # marker instead — that marker makes a later run stop before reaching
    # step 7. The same goes for launcher overrides left in place.
    kept_lines=("${GAME_SETTINGS_KEPT[@]}" "${LAUNCHER_LINES_KEPT[@]}")
    if { [ ${#CONFIG_LINES[@]} -gt 0 ] || [ ${#LAUNCHER_LINES[@]} -gt 0 ]; } && [ -f "$INSTALL_MANIFEST" ]; then
        if head -n 1 "$INSTALL_MANIFEST" | grep -q "^# EAX Restore: uninstalled"; then
            if [ ${#kept_lines[@]} -gt 0 ]; then
                start_manifest "$INSTALL_MANIFEST"
                printf '%s\n' "${kept_lines[@]}" >> "$INSTALL_MANIFEST"
            fi
        else
            { grep -v '^CONFIG:\|^LAUNCHER:' "$INSTALL_MANIFEST"
              [ ${#kept_lines[@]} -gt 0 ] && printf '%s\n' "${kept_lines[@]}"
              true
            } > "$INSTALL_MANIFEST.tmp" && mv -f "$INSTALL_MANIFEST.tmp" "$INSTALL_MANIFEST"
        fi
    fi

    end_phase_progress
    print_run_summary
    print_banner "UNINSTALL COMPLETE!"
    exit 0
fi
