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

    print_status "Verifying VC++ runtime files in $(basename "$target_dir"):"

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
    # Written into GAME_DIR rather than a temp dir: apply_registry_patch
    # (detection.sh) runs `protontricks -c` for Steam games, which executes
    # inside a Steam Runtime container that may not have /tmp bind-mounted —
    # the game's own library folder is guaranteed to be visible instead.
    local reg_file="$GAME_DIR/vcrun_overrides_$$.reg"
    print_status "Setting DLL overrides so Wine loads the native runtime instead of its own builtin..."
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
        print_warning_arrow "The VC++ DLL overrides couldn't be set, so Wine may still use its own builtin runtime." \
            "The run log has the full output."
    fi
    return "$rc"
}

remove_vcrun_dll_overrides() {
    # Removes the WINEDLLOverrides entries set by apply_vcrun_dll_overrides,
    # so a prefix that's had VC++ uninstalled doesn't keep telling Wine to
    # prefer "native" versions of DLLs that no longer exist (harmless in
    # practice — Wine falls back to builtin — but leaves a clean prefix).
    # See apply_vcrun_dll_overrides above for why this lives in GAME_DIR
    # instead of a temp dir.
    local reg_file="$GAME_DIR/vcrun_overrides_clean_$$.reg"
    print_status "Removing DLL overrides..."
    echo "Windows Registry Editor Version 5.00" > "$reg_file"
    echo "" >> "$reg_file"
    echo "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]" >> "$reg_file"
    local dll
    for dll in "${VCRUN_DLL_NAMES[@]}"; do
        echo "\"$dll\"=-" >> "$reg_file"
    done
    if ! apply_registry_patch "$reg_file"; then
        print_warning_arrow "The VC++ DLL overrides couldn't be removed. The run log has the full output."
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
    print_task "Installing MS VC++ 2022 Redistributable"
    advance_phase_progress

    VCRUN_SHARE="$BASE_SHARE/vcrun2022"
    mkdir -p "$VCRUN_SHARE"
    VCRUN_LOG="$VCRUN_SHARE/install.log"
    : > "$VCRUN_LOG"


    # 1. Run the package manager
    # --force bypasses winetricks' own checksum check for vc_redist.exe: it
    # ships with a baked-in expected hash, but Microsoft serves this file
    # from an "evergreen" URL that gets updated in place, so that hash can
    # go stale. Without --force, winetricks stops for a confirmation that
    # never gets answered in this non-interactive context — previously only
    # the Heroic/winetricks path below had this, not this protontricks path.
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        run_with_spinner "Installing via protontricks..." "$VCRUN_LOG" protontricks "$APPID" --force -q vcrun2022
    elif [ -n "$WINE_CMD" ]; then
        run_with_spinner "Installing via winetricks..." "$VCRUN_LOG" \
            env WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" WINESERVER="${WINESERVER_CMD:-}" winetricks --force -q vcrun2022
    fi

    # 2. Verify physical file presence instead of trusting exit codes
    verify_vcrun_files

    # 3. Handle the outcome
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        print_status "Package manager installation successful (core DLLs verified)." "$GREEN"
        # An overrides failure warns on its own; still return 0 so the
        # runtime (genuinely installed) is recorded for uninstall.
        apply_vcrun_dll_overrides
        return 0
    fi

    print_note_arrow "package manager didn't provide the core files — falling back to direct download..."

    if [ "$ARCH" == "64" ]; then
        VCRUN_URL="https://aka.ms/vs/17/release/vc_redist.x64.exe"
        VCRUN_EXE="vc_redist.x64.exe"
    else
        VCRUN_URL="https://aka.ms/vs/17/release/vc_redist.x86.exe"
        VCRUN_EXE="vc_redist.x86.exe"
    fi

    if [ ! -s "$VCRUN_SHARE/$VCRUN_EXE" ]; then
        print_status "Downloading $VCRUN_EXE from Microsoft..."
        fetch_with_progress "$VCRUN_URL" "$VCRUN_SHARE/$VCRUN_EXE"
    else
        print_status "Using cached $VCRUN_EXE"
    fi

    # Already registered in the prefix (an earlier install, even one whose
    # msvcp140.dll a Wine/Proton prefix update later swapped for its own
    # builtin): a plain install sees "already installed" and exits without
    # copying anything, so ask the installer to repair instead, which puts
    # back missing or replaced files. winetricks' own vcrun2022 verb can't
    # cover this either: it extracts "msvcp140.dll" from the cab, but the
    # current redistributable names that entry "msvcp140.dll_x86".
    local vc_mode="/q" vc_arch="X86" vc_label="Running Microsoft's installer in the prefix..."
    [ "$ARCH" == "64" ] && vc_arch="X64"
    if grep -q "\"DisplayName\"=\"Microsoft Visual C++ 2022 $vc_arch Minimum Runtime" "$PREFIX_PATH/system.reg" 2>/dev/null; then
        vc_mode="/repair /quiet"
        vc_label="Running Microsoft's repair in the prefix..."
        print_status "VC++ 2022 is already registered in this prefix, but a core file was replaced."
    fi
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        run_with_spinner "$vc_label" "$VCRUN_LOG" \
            protontricks -c "wine \"$VCRUN_SHARE/$VCRUN_EXE\" $vc_mode /norestart" "$APPID"
    else
        # shellcheck disable=SC2086  # vc_mode is one or two flags
        run_with_spinner "$vc_label" "$VCRUN_LOG" \
            env WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$VCRUN_SHARE/$VCRUN_EXE" $vc_mode /norestart
    fi

    # Final verification
    verify_vcrun_files
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        print_status "VC++ Redistributable installed successfully via fallback." "$GREEN"
        # An overrides failure warns on its own; still return 0 so the
        # runtime (genuinely installed) is recorded for uninstall.
        apply_vcrun_dll_overrides
        return 0
    else
        print_warning_arrow "Direct installation completed, but core DLLs could not be verified."
        print_status "Full installer output saved to: $VCRUN_LOG" "$WHITE"
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

    if [ "$removed_any" -eq 1 ]; then
        print_status "Removed leftover Programs and Features registry entries."
    else
        print_status "No leftover Programs and Features entries found."
    fi
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
        echo ""
        print_note_arrow "prefix not found, skipping VC++ removal."
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
        echo ""
        print_note_arrow "no VC++ runtime files found in this prefix, nothing to remove."
        return
    fi

    print_task "Removing MS VC++ 2022 Redistributable"

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
            print_status "Fetching the official $arch uninstaller (best-effort)..."
            fetch_with_progress "https://aka.ms/vs/17/release/$vcrun_exe" "$vcrun_share/$vcrun_exe"
        fi
        if [ -s "$vcrun_share/$vcrun_exe" ]; then
            if [ "$LAUNCHER_TYPE" == "1" ]; then
                log_cmd "protontricks $vcrun_exe /uninstall"
                run_with_spinner "Running the official $arch uninstaller..." "$EAX_LOG_FILE" \
                    protontricks -c "wine \"$vcrun_share/$vcrun_exe\" /uninstall /q /norestart" "$APPID"
            else
                log_cmd "$WINE_CMD $vcrun_exe /uninstall"
                run_with_spinner "Running the official $arch uninstaller..." "$EAX_LOG_FILE" \
                    env WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$vcrun_share/$vcrun_exe" /uninstall /q /norestart
            fi
            echo "[exit $?]" >> "$EAX_LOG_FILE"
        else
            print_note_arrow "could not fetch the official $arch uninstaller — skipping straight to direct cleanup."
        fi

        # 2. Direct removal — the reliable part. Matches VCRUN_DLL_NAMES
        # (every DLL install could have set an override for), not a
        # shorter ad-hoc list. Only genuine Microsoft files: Wine's own
        # same-named placeholders aren't ours to remove.
        for dll in "${VCRUN_DLL_NAMES[@]}"; do
            f="$dir/${dll}.dll"
            if is_genuine_dll "$f" && rm -f "$f"; then
                print_status "Removed ${dll}.dll from $(basename "$dir")"
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
        print_warning_arrow "some core VC++ runtime files are still present: ${left[*]}"
    else
        print_status "VC++ Redistributable removed successfully." "$GREEN"
    fi
}
