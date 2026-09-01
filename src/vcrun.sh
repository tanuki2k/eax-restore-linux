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
    apply_registry_patch "$reg_file"
    rm -f "$reg_file"
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
    apply_registry_patch "$reg_file"
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

    VCRUN_SHARE="$BASE_SHARE/vcrun2022"
    mkdir -p "$VCRUN_SHARE"
    VCRUN_LOG="$VCRUN_SHARE/install.log"
    : > "$VCRUN_LOG"

    print_status "Attempting installation via package manager..."

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
        WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" winetricks --force -q vcrun2022 &>> "$VCRUN_LOG"
    fi

    # 2. Verify physical file presence instead of trusting exit codes
    verify_vcrun_files

    # 3. Handle the outcome
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        print_status "Package manager installation successful (core DLLs verified)." "$GREEN"
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
        curl -fL -# "$VCRUN_URL" -o "$VCRUN_SHARE/$VCRUN_EXE"
    else
        print_status "Using cached $VCRUN_EXE"
    fi

    print_status "Running silent installer in prefix..."
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        protontricks -c "wine \"$VCRUN_SHARE/$VCRUN_EXE\" /q /norestart" "$APPID" &>> "$VCRUN_LOG"
    else
        WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$VCRUN_SHARE/$VCRUN_EXE" /q /norestart &>> "$VCRUN_LOG"
    fi

    # Final verification
    verify_vcrun_files
    if [ "$VCRUN_SUCCESS" -eq 1 ]; then
        print_status "VC++ Redistributable installed successfully via fallback." "$GREEN"
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
            query_output=$(protontricks -c "wine reg query \"$hive\" /s /f \"Visual C++\" /d" "$APPID" 2>/dev/null)
        elif [ -n "$WINE_CMD" ]; then
            query_output=$(WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" reg query "$hive" /s /f "Visual C++" /d 2>/dev/null)
        else
            continue
        fi

        while IFS= read -r line; do
            [[ "$line" == HKEY_LOCAL_MACHINE* ]] || continue
            key="${line%$'\r'}"
            if [ "$LAUNCHER_TYPE" == "1" ]; then
                protontricks -c "wine reg delete \"$key\" /f" "$APPID" &>/dev/null
            else
                WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" reg delete "$key" /f &>/dev/null
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
    # doesn't run the architecture-selection step, so this detects 32 vs
    # 64-bit by checking which runtime is actually present, same as
    # verify_vcrun_files.
    if [ -z "$PREFIX_PATH" ] || [ ! -d "$PREFIX_PATH/drive_c/windows" ]; then
        echo ""
        print_note_arrow "prefix not found, skipping VC++ removal."
        return
    fi

    local target_dir=""
    local vcrun_arch=""
    if is_genuine_dll "$PREFIX_PATH/drive_c/windows/system32/vcruntime140.dll"; then
        target_dir="$PREFIX_PATH/drive_c/windows/system32"
        vcrun_arch="64"
    elif is_genuine_dll "$PREFIX_PATH/drive_c/windows/syswow64/vcruntime140.dll"; then
        target_dir="$PREFIX_PATH/drive_c/windows/syswow64"
        vcrun_arch="32"
    fi

    if [ -z "$target_dir" ]; then
        echo ""
        print_note_arrow "no VC++ runtime files found in this prefix, nothing to remove."
        return
    fi

    print_task "Removing MS VC++ 2022 Redistributable"

    # 1. Best-effort: the official uninstaller. Fetches the installer fresh
    # if not already cached, but never blocks on a failed download — this
    # step is pure upside if it works, and a no-op if it doesn't.
    local vcrun_share="$BASE_SHARE/vcrun2022"
    mkdir -p "$vcrun_share"
    local vcrun_url vcrun_exe
    if [ "$vcrun_arch" == "64" ]; then
        vcrun_url="https://aka.ms/vs/17/release/vc_redist.x64.exe"
        vcrun_exe="vc_redist.x64.exe"
    else
        vcrun_url="https://aka.ms/vs/17/release/vc_redist.x86.exe"
        vcrun_exe="vc_redist.x86.exe"
    fi
    if [ ! -s "$vcrun_share/$vcrun_exe" ]; then
        print_status "Fetching the official uninstaller (best-effort)..."
        curl -fL -# "$vcrun_url" -o "$vcrun_share/$vcrun_exe" 2>/dev/null
    fi
    if [ -s "$vcrun_share/$vcrun_exe" ]; then
        print_status "Running the official uninstaller (best-effort; direct cleanup follows regardless)..."
        if [ "$LAUNCHER_TYPE" == "1" ]; then
            protontricks -c "wine \"$vcrun_share/$vcrun_exe\" /uninstall /q /norestart" "$APPID" &>/dev/null
        else
            WINEPREFIX="$PREFIX_PATH" "$WINE_CMD" "$vcrun_share/$vcrun_exe" /uninstall /q /norestart &>/dev/null
        fi
    else
        print_note_arrow "could not fetch the official uninstaller — skipping straight to direct cleanup."
    fi

    # 2. Direct removal — the reliable part. Matches VCRUN_DLL_NAMES (every
    # DLL install could have set an override for), not a shorter ad-hoc list.
    local dll f
    for dll in "${VCRUN_DLL_NAMES[@]}"; do
        f="$target_dir/${dll}.dll"
        if [ -f "$f" ]; then
            rm -f "$f"
            print_status "Removed ${dll}.dll"
        fi
    done

    remove_vcrun_msi_registration
    remove_vcrun_dll_overrides

    if [ -f "$target_dir/vcruntime140.dll" ] || [ -f "$target_dir/msvcp140.dll" ]; then
        print_warning_arrow "some core VC++ runtime files are still present."
    else
        print_status "VC++ Redistributable removed successfully." "$GREEN"
    fi
}
