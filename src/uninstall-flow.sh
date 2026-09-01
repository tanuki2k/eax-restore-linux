# ==============================================================================
# ACTION: UNINSTALL FROM GAME
# ==============================================================================
if [ "$SCRIPT_ACTION" == "u" ]; then
    print_banner "UNINSTALL EAX FIX"

    # Steps 1-2 loop: same restart-on-dead-end mechanism as the install flow
    # (see the comment in config-flow.sh). The only thing that sets
    # RESTART_REQUESTED here is the no-prefix / no-AppID dead end in
    # detect_game_environment — the EAX-impossible checks are install-only.
    while true; do
        RESTART_REQUESTED=""

        print_step 1 "Game Location"
        get_game_directory ""

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
                # Bare "REGISTRY:OVERRIDE" (no DLL suffix) is only ever read,
                # never written, by this version of the script — it's kept
                # for backward compatibility with manifests written by older
                # versions, from before the DLL name was appended (when
                # dsound was the only possible override).
                "REGISTRY:OVERRIDE") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="dsound"; continue ;;
                "REGISTRY:OVERRIDE:dsound") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="dsound"; continue ;;
                "REGISTRY:OVERRIDE:openal32") REG_HAS_OVERRIDE="y"; REG_OVERRIDE_DLL="openal32"; continue ;;
                "VCRUN") VCRUN_INSTALLED="y"; continue ;;
            esac
            { [ -e "$manifest_entry" ] || [ -L "$manifest_entry" ]; } && FILES_TO_REMOVE+=("$manifest_entry")
        done < "$INSTALL_MANIFEST"
    else
        echo -e "\n${YELLOW}${BOLD}No install manifest found.${NC}"
        echo -e "${WHITE}This usually means the fix was installed with an older version of the script, or the"
        echo -e "manifest file was deleted. Falling back to a best-effort scan by filename instead — note this"
        echo -e "may also flag files that pre-date the script and were skipped rather than installed by it.${NC}"

        TARGET_FILES=("dsound.dll" "dsoal-aldrv.dll" "dsound.vxd" "OpenAL32.dll" "eax.dll" "eaxunified.dll" "alsoft.ini")

        # Check standard game folder
        for file in "${TARGET_FILES[@]}"; do
            [ -e "$GAME_DIR/$file" ] && FILES_TO_REMOVE+=("$GAME_DIR/$file")
            [ -L "$GAME_DIR/$file" ] && FILES_TO_REMOVE+=("$GAME_DIR/$file")
        done
        [ -d "$GAME_DIR/OpenAL" ] && FILES_TO_REMOVE+=("$GAME_DIR/OpenAL")

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

    if [ ${#FILES_TO_REMOVE[@]} -eq 0 ] && [ "$REG_HAS_COM" == "n" ] && [ "$REG_HAS_OVERRIDE" == "n" ] && [ "$VCRUN_PRESENT" == "n" ]; then
        print_note "No EAX/DSOAL files were found in $GAME_DIR or the system prefix — nothing to remove."; exit 0
    fi

    print_step 4 "Game Files"

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

        echo -e "\n${YELLOW}Press Enter to remove all of these, or type the numbers of just the ones you"
        echo -e "want (e.g. \"1 2 3\", \"1-3\", or \"^4\" to remove everything except 4), or 'n' to cancel: ${NC}"
        echo -e -n "> "
        read -r CONFIRM_UNINSTALL

        if [[ "$CONFIRM_UNINSTALL" =~ $NO_RE ]]; then
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
                echo -e "\n${YELLOW}Nothing was selected, so nothing was removed.${NC}"
                FILES_DECLINED="1"
            else
                echo ""
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

    print_step 5 "Registry Cleanup"

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
        echo -e "\n${WHITE}Removes the Wine registry tweaks this script can add (DLL override, COM routing) —"
        echo -e "skip if you never enabled those during install. No manifest was found to check automatically.${NC}"
        if confirm "Do you want to remove Override/COM keys from the Wine registry?" N; then
            REG_HAS_COM="y"; REG_HAS_OVERRIDE="y"; REMOVE_REG="y"
        else
            REMOVE_REG="n"
        fi
    fi

    if [[ "$REMOVE_REG" =~ $YES_RE ]]; then
        if [ -n "$APPID" ] || [ -d "$PREFIX_PATH/drive_c" ]; then
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

            print_task "Cleaning registry"
            apply_registry_patch "$REG_FILE"
            rm -f "$REG_FILE"
            print_status "Registry keys safely removed." "$GREEN"
        else
            echo ""
            print_note_arrow "No prefix or AppID was found for this game, so there's nothing to clean up in the registry."
        fi
    fi

    print_step 6 "VC++ Runtime"

    if [ "$VCRUN_PRESENT" == "y" ]; then
        echo -e "\n${WHITE}This prefix has the MS VC++ 2022 Redistributable installed. Only remove it if"
        echo -e "nothing else sharing this prefix needs it.${NC}"
        if confirm "Also remove the VC++ 2022 Redistributable from this prefix?" N; then
            uninstall_vcrun_dependencies
        fi
    else
        echo -e "\n${WHITE}No VC++ runtime recorded or detected in this prefix — nothing to do here.${NC}"
    fi

    print_banner "UNINSTALL COMPLETE!"
    exit 0
fi
