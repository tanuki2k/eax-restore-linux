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
        print_paragraph "This step finds the folder the game is installed in."
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
    VCRUN_OVERRIDES_ONLY="n"
    CONFIG_LINES=()
    LAUNCHER_LINES=()
    # Companion apps' prefix changes (lines tagged with their AppID, see
    # prefix-steps.sh), keyed by AppID; COMPANION_* is filled from them below.
    UNINSTALL_COMPANION_IDS=()
    declare -A UNINSTALL_COMPANION_VCRUN=() UNINSTALL_COMPANION_COM=() UNINSTALL_COMPANION_OVERRIDE=()
    UNINSTALL_COMPANION_VCRUN_REMOVE=()
    COMPANION_IDS=(); COMPANION_NAMES=(); COMPANION_PREFIXES=()

    if [ -s "$INSTALL_MANIFEST" ] && manifest_is_uninstalled "$INSTALL_MANIFEST"; then
        print_task "Reading the install manifest"
        print_status "This game was already uninstalled in a previous run, so there's nothing left to remove." "$GREEN"
        print_status "If you've copied DSOAL/OpenAL files in by hand since, remove those yourself — there's no install record for them." ""
        exit 0
    fi

    if [ -s "$INSTALL_MANIFEST" ]; then
        MANIFEST_FOUND=1
        print_task "Reading the install manifest"
        print_detected "Found" "$INSTALL_MANIFEST"
        declare -A manifest_seen=()
        while IFS= read -r manifest_entry; do
            [ -z "$manifest_entry" ] && continue
            case "$manifest_entry" in
                # The format header (MANIFEST_HEADER) and any other comment.
                \#*) continue ;;
                # A companion app's (its AppID after a tab).
                VCRUN$'\t'*|VCRUN:OVERRIDES$'\t'*|REGISTRY:*$'\t'*) note_companion_manifest_line "$manifest_entry"; continue ;;
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
                "VCRUN:OVERRIDES") VCRUN_OVERRIDES_ONLY="y"; continue ;;
                # Game settings changed in the game's own config files —
                # reverted in step 7, never removed as files.
                CONFIG:*) CONFIG_LINES+=("$manifest_entry"); continue ;;
                # The DLL override added to Steam's launch options / Heroic's
                # environment variables — reverted in step 5.
                LAUNCHER:*) LAUNCHER_LINES+=("$manifest_entry"); continue ;;
            esac
            # Only files the install itself puts down, by absolute path: a
            # manifest sits in a folder anyone can write to, and whatever it
            # lists gets deleted.
            manifest_entry="${manifest_entry%$'\r'}"
            if [[ "$manifest_entry" != /* || "/$manifest_entry/" == *"/../"* ]] \
                || ! manifest_file_is_ours "$manifest_entry"; then
                print_warning_arrow "Skipped ${manifest_entry} because it isn't one of the files this script installed."
                continue
            fi
            [ -n "${manifest_seen[$manifest_entry]:-}" ] && continue
            manifest_seen["$manifest_entry"]=1
            { [ -e "$manifest_entry" ] || [ -L "$manifest_entry" ]; } && FILES_TO_REMOVE+=("$manifest_entry")
        done < "$INSTALL_MANIFEST"
    else
        print_task "Scanning for EAX files"
        print_status "No install manifest found (an older version of the script, or it was deleted), so looking for known DSOAL/OpenAL file names." ""
        print_status "Only files that match what this script installs are listed, so a game's own copies are left alone." ""

        TARGET_FILES=("dsound.dll" "dsoal-aldrv.dll" "OpenAL32.dll" "eax.dll" "eaxunified.dll" "alsoft.ini")

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
                looks_like_our_file "$scan_dir/$file" && FILES_TO_REMOVE+=("$scan_dir/$file")
            done
        done

        # Check prefix system folders
        if [ -n "$PREFIX_PATH" ] && [ -d "$PREFIX_PATH/drive_c/windows" ]; then
            for file in "dsound.dll" "dsoal-aldrv.dll" "OpenAL32.dll"; do
                looks_like_our_file "$PREFIX_PATH/drive_c/windows/syswow64/$file" && FILES_TO_REMOVE+=("$PREFIX_PATH/drive_c/windows/syswow64/$file")
                looks_like_our_file "$PREFIX_PATH/drive_c/windows/system32/$file" && FILES_TO_REMOVE+=("$PREFIX_PATH/drive_c/windows/system32/$file")
            done
        fi
    fi

    VCRUN_PRESENT="n"
    if [ "$VCRUN_INSTALLED" == "y" ] || [ "$VCRUN_OVERRIDES_ONLY" == "y" ]; then
        VCRUN_PRESENT="y"
    elif [ -n "$PREFIX_PATH" ] && { is_genuine_dll "$PREFIX_PATH/drive_c/windows/system32/vcruntime140.dll" || is_genuine_dll "$PREFIX_PATH/drive_c/windows/syswow64/vcruntime140.dll"; }; then
        # No manifest record of it, but the runtime is actually there — cover
        # installs done with an older script version, or the standalone
        # VC++-only mode run before manifest tracking existed for it.
        VCRUN_PRESENT="y"
    fi

    # Another game installed into the same prefix needs the DLLs and registry
    # keys in it: its install backed up what this one put there, and removing
    # them would break it. They stay until the last game sharing the prefix is
    # uninstalled.
    PREFIX_SHARED=0
    if [ -n "$PREFIX_PATH" ] && { [ ${#FILES_TO_REMOVE[@]} -gt 0 ] || [ "$REG_HAS_COM" == "y" ] || [ "$REG_HAS_OVERRIDE" == "y" ]; }; then
        shared_games="$(games_sharing_prefix "$PREFIX_PATH" "$GAME_DIR")"
        if [ -n "$shared_games" ]; then
            PREFIX_SHARED=1
            shared_names="$(while IFS= read -r d; do basename "$d"; done <<< "$shared_games" | paste -sd, | sed 's/,/, /g')"
            print_warning_arrow "${shared_names} also uses this prefix, so the files and registry keys in it stay until ${shared_names} is uninstalled too."
            kept_files=()
            for f in "${FILES_TO_REMOVE[@]}"; do [[ "$f" == "$PREFIX_PATH/"* ]] || kept_files+=("$f"); done
            FILES_TO_REMOVE=("${kept_files[@]}")
        fi
    fi

    # What was found, one line each — the steps below act on it.
    bak_count=0
    for f in "${FILES_TO_REMOVE[@]}"; do oldest_backup "$f" >/dev/null && bak_count=$((bak_count + 1)); done
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
        OVERRIDE_LAUNCHER="${f_fields[0]}"; OVERRIDE_ID="${f_fields[2]}"
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
    [ ${#UNINSTALL_COMPANION_IDS[@]} -gt 0 ] && resolve_uninstall_companions
    if [ ${#CONFIG_LINES[@]} -gt 0 ]; then
        settings_count="$(for line in "${CONFIG_LINES[@]}"; do cut -f1,2 <<< "${line#CONFIG:}"; done | sort -u | wc -l)"
        print_status "Game settings: ${settings_count} changed during install" ""
    fi

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ] && [ "$REG_HAS_COM" == "n" ] && [ "$REG_HAS_OVERRIDE" == "n" ] && [ "$VCRUN_PRESENT" == "n" ] && [ ${#CONFIG_LINES[@]} -eq 0 ] && [ ${#LAUNCHER_LINES[@]} -eq 0 ] \
        && [ ${#COMPANION_IDS[@]} -eq 0 ]; then
        print_status "Nothing from this script was found in the game folder or prefix, so there's nothing to remove." ""
        exit 0
    fi

    print_step 4 "Game Files"
    print_paragraph "This step asks whether to remove the files the install added to ${GAME_NAME:-the game}'s" \
        "folder and put back any originals it replaced."

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
            # a redundant backup of our own previous output (cache.sh no
            # longer does, but older installs may have left these behind),
            # the earliest one is the one most likely to actually be the
            # genuine original.
            OLDEST_BAK=$(oldest_backup "$f")
            if [ -n "$OLDEST_BAK" ]; then
                RESTORE_TARGETS+=("$f")
                RESTORE_SOURCES+=("$OLDEST_BAK")
            fi
        done

        declare -A HAS_BACKUP
        for t in "${RESTORE_TARGETS[@]}"; do HAS_BACKUP["$t"]=1; done

        print_result "${BOLD}The following files will be removed:" "$YELLOW"
        idx=1
        for f in "${FILES_TO_REMOVE[@]}"; do
            if [ "${HAS_BACKUP[$f]:-0}" == "1" ]; then
                printf "%2d  %s  " "$idx" "$(tilde_path "$f")"; echo -e "${GREEN}(original will be restored)${NC}"
            else
                printf "%2d  %s\n" "$idx" "$(tilde_path "$f")"
            fi
            idx=$((idx + 1))
        done

        # One row per kind of answer (parse_selection's syntax); the number
        # rows only make sense with more than one file.
        if [ ${#FILES_TO_REMOVE[@]} -gt 1 ]; then
            print_result "Which files should be removed?" "$YELLOW"
            printf "  %-9s  %s\n" "Enter" "remove all of them"
            printf "  %-9s  %s\n" "1 2 3" "remove only these (or a range: 1-3)"
            printf "  %-9s  %s\n" "^2" "remove all except 2"
            printf "  %-9s  %s\n" "n" "keep them all"
        else
            print_result "Should this file be removed?" "$YELLOW"
            printf "  %-9s  %s\n" "Enter" "remove it"
            printf "  %-9s  %s\n" "n" "keep it"
        fi
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
    print_paragraph "This step undoes the DLL override and any Wine registry changes the install" \
        "made."

    # Launcher overrides: ask whether to remove each one. Yes also lets
    # Phase 2 close the launcher (if it's running then) and reopen it,
    # without stopping to ask.
    LAUNCHER_WORK=0
    print_task "Checking launcher and registry changes"
    if [ ${#LAUNCHER_LINES[@]} -gt 0 ]; then
        for line in "${LAUNCHER_LINES[@]}"; do
            mapfile -t -d $'\t' f_fields < <(printf '%s' "${line#LAUNCHER:}")
            OVERRIDE_LAUNCHER="${f_fields[0]}"; OVERRIDE_FILE="${f_fields[1]}"; OVERRIDE_ID="${f_fields[2]}"
            [ -f "$OVERRIDE_FILE" ] || continue
            where="$(launcher_override_where)"
            print_status "Launcher: the install added a DLL override to ${where}" ""
            if confirm_override_removal "$where"; then
                LAUNCHER_CLOSE_ANSWER[$OVERRIDE_LAUNCHER]="y"
                LAUNCHER_WORK=1
            else
                LAUNCHER_REMOVE_DECLINED["$line"]=1
                print_status "The DLL override will stay in ${where}." "$YELLOW"
            fi
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
    if [ "$PREFIX_SHARED" -eq 1 ] && [[ "$REMOVE_REG" =~ $YES_RE ]]; then
        print_status "Left the Wine registry changes in place, because ${shared_names} also uses this prefix." ""
        REMOVE_REG="n"
    fi
    if [[ "$REMOVE_REG" =~ $YES_RE ]] && [ -z "$APPID" ] && [ ! -d "$PREFIX_PATH/drive_c" ]; then
        print_note_arrow "No prefix or AppID was found for this game, so there's nothing to clean up in the registry."
        REMOVE_REG="n"
    fi
    for id in "${COMPANION_IDS[@]}"; do
        { [ -n "${UNINSTALL_COMPANION_COM[$id]:-}" ] || [ -n "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}" ]; } \
            && print_status "Registry: will be cleaned up in $(companion_name_for_id "$id")'s prefix too" ""
    done

    print_step 6 "VC++ Runtime"
    print_paragraph "This step checks whether the install added the VC++ 2022 Redistributable to" \
        "${GAME_NAME:-the game}'s prefix."

    UNINSTALL_VCRUN="n"
    print_task "Checking for the VC++ runtime"
    if [ "$VCRUN_PRESENT" == "y" ]; then
        print_status "Found the MS VC++ 2022 Redistributable in this prefix." ""
        print_status "Only remove it if nothing else sharing this prefix needs it." ""
        confirm "Also remove the VC++ 2022 Redistributable from this prefix?" N && UNINSTALL_VCRUN="y"
    else
        print_status "Not installed in this prefix, so nothing to do." ""
    fi
    COMPANION_WORK=0
    for i in "${!COMPANION_IDS[@]}"; do
        id="${COMPANION_IDS[$i]}"
        UNINSTALL_COMPANION_VCRUN_REMOVE[i]="n"
        if [ -n "${UNINSTALL_COMPANION_VCRUN[$id]:-}" ]; then
            confirm "Also remove the VC++ 2022 Redistributable from ${COMPANION_NAMES[$i]}'s prefix?" N \
                && UNINSTALL_COMPANION_VCRUN_REMOVE[i]="y"
        fi
        if [ "${UNINSTALL_COMPANION_VCRUN_REMOVE[$i]}" == "y" ] || [ -n "${UNINSTALL_COMPANION_COM[$id]:-}" ] \
            || [ -n "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}" ]; then
            COMPANION_WORK=$(( COMPANION_WORK + 1 ))
        fi
    done

    choose_game_settings_to_revert 7

    if [ ${#FINAL_REMOVE[@]} -eq 0 ] && [ "$LAUNCHER_WORK" -eq 0 ] && [[ ! "$REMOVE_REG" =~ $YES_RE ]] \
        && [ "$UNINSTALL_VCRUN" == "n" ] && [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -eq 0 ] && [ "$COMPANION_WORK" -eq 0 ]; then
        print_result "Nothing to change, so the uninstall is finished."
        exit 0
    fi

    # ==============================================================================
    # UNINSTALL PHASE 2: EXECUTION
    # ==============================================================================
    print_banner "UNINSTALL — PHASE 2: EXECUTION"
    if ! confirm "Ready to remove the EAX fix from ${GAME_NAME:-this game}. Proceed?"; then
        print_result "Uninstall cancelled. Nothing was changed." "$YELLOW"
        exit 0
    fi

    # One bar step per STATUS: header below.
    phase_total=0
    [ ${#FINAL_REMOVE[@]} -gt 0 ] && phase_total=$(( phase_total + 1 ))
    [ "$LAUNCHER_WORK" -eq 1 ] && phase_total=$(( phase_total + 1 ))
    [[ "$REMOVE_REG" =~ $YES_RE ]] && phase_total=$(( phase_total + 1 ))
    [ "$UNINSTALL_VCRUN" == "y" ] && phase_total=$(( phase_total + 1 ))
    [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ] && phase_total=$(( phase_total + 1 ))
    phase_total=$(( phase_total + COMPANION_WORK ))
    start_phase_progress "$phase_total"

    if [ ${#FINAL_REMOVE[@]} -gt 0 ]; then
        print_phase_task "Removing game files"
        for f in "${FINAL_REMOVE[@]}"; do rm -f "$f"; done
        for i in "${!FINAL_RESTORE_TARGETS[@]}"; do
            if mv "${FINAL_RESTORE_SOURCES[$i]}" "${FINAL_RESTORE_TARGETS[$i]}"; then
                print_status "Restored original $(basename "${FINAL_RESTORE_TARGETS[$i]}") in $(dirname "${FINAL_RESTORE_TARGETS[$i]}")"
                # Any other timestamped backups of this target are leftover
                # junk — most likely backups of our own prior output from
                # before reinstalls were handled correctly, not additional
                # genuine originals — so there's nothing left worth keeping
                # them for. Only after the original is back: a failed
                # restore must not cost the player their backups.
                rm -f "${FINAL_RESTORE_TARGETS[$i]}".bak.[0-9]*_[0-9]* 2>/dev/null
            else
                print_warning_arrow "Couldn't put back $(basename "${FINAL_RESTORE_TARGETS[$i]}"), so its backup was kept at $(tilde_path "${FINAL_RESTORE_SOURCES[$i]}")."
            fi
        done
        manifest_forget_paths "${FINAL_REMOVE[@]}"
        print_status "Selected files removed successfully." "$GREEN"
    fi

    LAUNCHER_LINES_KEPT=()
    if [ ${#LAUNCHER_LINES[@]} -gt 0 ]; then
        [ "$LAUNCHER_WORK" -eq 1 ] && print_phase_task "Removing the DLL override from the launcher"
        revert_launcher_overrides
    fi

    REG_CLEANED="n"
    if [[ "$REMOVE_REG" =~ $YES_RE ]]; then
        print_phase_task "Cleaning registry"
        reg_dll=""
        if [ "$REG_HAS_OVERRIDE" == "y" ]; then
            # No manifest to say which DLL was overridden (dsound or
            # openal32): clear both.
            reg_dll="${REG_OVERRIDE_DLL:-both}"
        fi
        if remove_prefix_registry "$REG_HAS_COM" "$reg_dll"; then
            REG_CLEANED="y"
            print_status "Registry keys safely removed." "$GREEN"
        else
            print_warning_arrow "The registry keys couldn't be removed from the Wine prefix. The run log has the full output."
        fi
    fi

    if [ "$UNINSTALL_VCRUN" == "y" ]; then
        print_phase_task "Removing the MS VC++ 2022 Redistributable"
        uninstall_vcrun_dependencies
    fi

    # Companion apps' own prefixes (DOOM 3's Resurrection of Evil).
    for i in "${!COMPANION_IDS[@]}"; do
        id="${COMPANION_IDS[$i]}"
        [ "${UNINSTALL_COMPANION_VCRUN_REMOVE[$i]}" == "y" ] || [ -n "${UNINSTALL_COMPANION_COM[$id]:-}" ] \
            || [ -n "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}" ] || continue
        print_phase_task "Cleaning up ${COMPANION_NAMES[$i]}'s Proton prefix"
        with_companion "$i" uninstall_companion_prefix "$i"
    done

    if [ ${#GAME_SETTINGS_REVERT_GROUPS[@]} -gt 0 ]; then
        print_phase_task "Putting back game settings"
        revert_game_settings
    fi

    # Last of all, so an uninstall that stops part way (Ctrl-C, a failed
    # registry cleanup) still has the manifest to go on. What was done is
    # dropped from it: the files removed or restored, the registry keys once
    # they're gone, the VC++ and companion records once nothing is left to
    # undo. Settings the player chose to keep, and launcher overrides left in
    # place, stay in it so a later uninstall can still put them back.
    kept_lines=("${GAME_SETTINGS_KEPT[@]}" "${LAUNCHER_LINES_KEPT[@]}")
    if [ -f "$INSTALL_MANIFEST" ] && ! manifest_is_uninstalled "$INSTALL_MANIFEST"; then
        # "core" lines are what still needs undoing: files, and registry keys
        # that weren't cleaned. The VC++ and companion records only matter
        # while one of those is left.
        core_left=(); extra_left=()
        while IFS= read -r line; do
            case "$line" in
                \#*|"") ;;
                CONFIG:*|LAUNCHER:*) ;;
                REGISTRY:*$'\t'*|VCRUN$'\t'*|VCRUN:OVERRIDES$'\t'*) extra_left+=("$line") ;;
                REGISTRY:*) [ "$REG_CLEANED" == "y" ] || core_left+=("$line") ;;
                VCRUN|VCRUN:OVERRIDES) [ "$UNINSTALL_VCRUN" == "y" ] || extra_left+=("$line") ;;
                *) core_left+=("$line") ;;
            esac
        done < "$INSTALL_MANIFEST"
        local_left=("${core_left[@]}")
        [ ${#core_left[@]} -gt 0 ] && local_left+=("${extra_left[@]}")
        if [ ${#local_left[@]} -eq 0 ] && [ ${#kept_lines[@]} -eq 0 ]; then
            # A marker rather than deleting the manifest: a later uninstall
            # of this game then sees "already cleaned up, nothing to do"
            # instead of falling back to a filename-based guess.
            echo "# EAX Restore: uninstalled on $(date -u +"%Y-%m-%dT%H:%M:%SZ"). Nothing left to remove." > "$INSTALL_MANIFEST"
        else
            { printf '%s\n' "$MANIFEST_HEADER"
              [ ${#local_left[@]} -gt 0 ] && printf '%s\n' "${local_left[@]}"
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
