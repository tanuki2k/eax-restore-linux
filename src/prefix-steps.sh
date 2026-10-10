# ==============================================================================
# PREFIX STEPS, AND STEAM COMPANION APPS
# ==============================================================================
# The install's per-prefix work (Creative's OpenAL runtime, the DLL copy into
# the prefix, the registry changes) as functions, so the game's own prefix and
# each companion app's run the same code. A companion app (the profile's
# stores.steam.companion_apps) is another Steam app that runs the game's exe
# from its folder — DOOM 3's Resurrection of Evil is Doom3.exe started with
# "+set fs_game d3xp" — so the game-folder files and the manifest are already
# shared, but Steam gives it its own Proton prefix and its own launch options.
# Everything here works on the usual globals (APPID, PREFIX_PATH, GAME_NAME);
# with_companion points them at one companion for the length of a call.
#
# A companion's manifest lines carry its AppID after a tab: "VCRUN\t9070",
# "REGISTRY:COM\t9070", "REGISTRY:OVERRIDE:openal32\t9070". Its prefix DLLs
# are absolute paths and its LAUNCHER: line already names its AppID, so those
# look the same as the game's own.

# Usage: steam_acf_name <appmanifest_<id>.acf>
# The app's name as Steam shows it, from its appmanifest.
steam_acf_name() {
    acf_value "$1" name
}

# Usage: steam_prefix_for_appid <appid>
# The app's Proton prefix as protontricks reports it, or nothing when it has
# none yet (never launched) or protontricks can't see it. protontricks rather
# than compatdata/<id>/pfx directly, since every later step goes through it.
steam_prefix_for_appid() {
    local prefix
    log_cmd "protontricks -c 'echo \$WINEPREFIX' $1"
    # $WINEPREFIX is for protontricks' own shell; the log is only appended to.
    # shellcheck disable=SC2016,SC2094
    prefix=$(protontricks -c 'echo $WINEPREFIX' "$1" 2>> "$EAX_LOG_FILE" | tee -a "$EAX_LOG_FILE" | grep "/pfx" | tail -n 1 | tr -d '\r')
    [ -n "$prefix" ] && [ -d "$prefix/drive_c" ] && echo "$prefix"
}

# Usage: resolve_companion_apps <steam appid>
# Install Phase 1: sets COMPANION_IDS, COMPANION_NAMES and COMPANION_PREFIXES
# to the game's companion apps installed in its Steam library. One whose
# prefix doesn't exist yet gets the prefix step's "launch it once" check, and
# No leaves it out of this install.
resolve_companion_apps() {
    COMPANION_IDS=(); COMPANION_NAMES=(); COMPANION_PREFIXES=()
    [ "$LAUNCHER_TYPE" == "1" ] && [ -n "$1" ] || return 0
    ensure_game_database || return 0
    local lib="${GAME_DIR%/common/*}" id acf name prefix
    local -a ids
    # Read first: the confirm below must read the player's answer, not jq's
    # output, which a "while read ... < <(jq)" loop would hand it.
    mapfile -t ids < <(gdb_jq "$1" steam 'entry0 | .stores.steam.companion_apps // [] | .[]')
    for id in "${ids[@]}"; do
        [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" != "$1" ] || continue
        acf="$lib/appmanifest_${id}.acf"
        # Not installed (or in another library, which can't share the folder).
        [ -f "$acf" ] || continue
        name="$(steam_acf_name "$acf")"; [ -n "$name" ] || name="AppID $id"
        while true; do
            print_status "Looking up ${name}'s Proton prefix..." ""
            prefix="$(steam_prefix_for_appid "$id")"
            [ -n "$prefix" ] && break
            print_note "${name} doesn't have its own Proton prefix yet."
            print_paragraph "If you just installed ${name}, Proton creates its prefix the first time it runs." \
                "Please launch ${name} at least once, close it, and try again."
            confirm "Check for ${name}'s prefix again?" || break
        done
        if [ -z "$prefix" ]; then
            print_status "${name} will be left as it is." "$YELLOW"
            continue
        fi
        print_detected "${name}'s prefix" "$prefix"
        COMPANION_IDS+=("$id"); COMPANION_NAMES+=("$name"); COMPANION_PREFIXES+=("$prefix")
    done
    [ ${#COMPANION_IDS[@]} -gt 0 ] || return 0
    print_status "$(companion_names_list) $( [ ${#COMPANION_IDS[@]} -eq 1 ] && echo "runs" || echo "run" ) from ${GAME_NAME}'s folder, so $( [ ${#COMPANION_IDS[@]} -eq 1 ] && echo "its" || echo "their" ) own prefix and launch options get the same setup."
}

# Usage: companion_names_list
# COMPANION_NAMES joined for prose: "A", "A and B", "A, B and C".
companion_names_list() {
    local n=${#COMPANION_NAMES[@]} i out=""
    for (( i = 0; i < n; i++ )); do
        if [ "$i" -eq 0 ]; then out="${COMPANION_NAMES[$i]}"
        elif [ "$i" -eq $((n - 1)) ]; then out+=" and ${COMPANION_NAMES[$i]}"
        else out+=", ${COMPANION_NAMES[$i]}"; fi
    done
    echo "$out"
}

# Usage: companion_name_for_id <appid>
# The companion's name, from this run's list or else its appmanifest.
companion_name_for_id() {
    local i name
    for i in "${!COMPANION_IDS[@]}"; do
        [ "${COMPANION_IDS[$i]}" == "$1" ] && { echo "${COMPANION_NAMES[$i]}"; return; }
    done
    name="$(steam_acf_name "${GAME_DIR%/common/*}/appmanifest_$1.acf")"
    echo "${name:-AppID $1}"
}

# Usage: with_companion <index> <command> [args...]
# Runs the command with APPID, PREFIX_PATH and GAME_NAME pointing at
# companion <index>, then puts them back. Returns the command's status.
with_companion() {
    local i="$1"; shift
    local saved_appid="${APPID:-}" saved_prefix="${PREFIX_PATH:-}" saved_name="${GAME_NAME:-}" rc
    APPID="${COMPANION_IDS[$i]}"; PREFIX_PATH="${COMPANION_PREFIXES[$i]}"; GAME_NAME="${COMPANION_NAMES[$i]}"
    "$@"; rc=$?
    APPID="$saved_appid"; PREFIX_PATH="$saved_prefix"; GAME_NAME="$saved_name"
    return "$rc"
}

# Usage: install_openal_runtime
# Creative's OpenAL runtime into the current prefix. A failure is a warning,
# not a deploy failure: the engine's own DLLs are copied in directly and don't
# depend on this package — but it must never be reported as installed when
# the tool failed.
install_openal_runtime() {
    local tool rc=""
    tool=$( [ "$LAUNCHER_TYPE" == "1" ] && echo "protontricks" || echo "winetricks" )
    if [ "$LAUNCHER_TYPE" == "1" ]; then
        log_cmd "protontricks $APPID -q openal"
        run_with_spinner "Installing via $tool..." "$EAX_LOG_FILE" \
            protontricks "$APPID" -q openal
        rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    elif [ -n "$WINE_CMD" ] && [ -n "$PREFIX_PATH" ]; then
        # Using --force to bypass winetricks safety blocks in Heroic
        log_cmd "winetricks --force -q openal (WINE=$WINE_CMD, prefix $PREFIX_PATH)"
        run_with_spinner "Installing via $tool..." "$EAX_LOG_FILE" \
            env WINEPREFIX="$PREFIX_PATH" WINE="$WINE_CMD" WINESERVER="${WINESERVER_CMD:-}" winetricks --force -q openal
        rc=$?; echo "[exit $rc]" >> "$EAX_LOG_FILE"
    else
        print_warning_arrow "No local Wine binary or resolved prefix was found, so this step is being skipped."
    fi
    if [ "$rc" == "0" ]; then
        print_status "OpenAL was installed successfully." "$GREEN"
    elif [ -n "$rc" ]; then
        print_warning_arrow "Creative's OpenAL runtime didn't install (exit code $rc), so the prefix may be missing it." \
            "The run log has the full output."
    fi
}

# Usage: deploy_prefix_dlls
# Copies DEPLOY_SRC/DEPLOY_DEST_NAME into the current prefix's system folder.
# Index 0 (the primary override DLL) is unconditionally backed up and
# overwritten — it's the one file Wine is being told to override anyway. Any
# secondary files (dsoal-aldrv.dll) go through the interactive conflict prompt
# instead, same as the game-folder copy, since a pre-existing file of that
# exact name is unusual.
deploy_prefix_dlls() {
    local target_dir dest i
    if [ "$ARCH" == "32" ] && [ -d "$PREFIX_PATH/drive_c/windows/syswow64" ]; then
        target_dir="$PREFIX_PATH/drive_c/windows/syswow64"
    else
        target_dir="$PREFIX_PATH/drive_c/windows/system32"
    fi
    for i in "${!DEPLOY_SRC[@]}"; do
        dest="$target_dir/${DEPLOY_DEST_NAME[$i]}"
        if [ "$i" -eq 0 ]; then
            auto_backup_and_overwrite "$dest" && deploy_copy "${DEPLOY_SRC[$i]}" "$dest" "Duplicated"
        elif handle_conflict "$dest"; then
            deploy_copy "${DEPLOY_SRC[$i]}" "$dest" "Duplicated"
        fi
    done
}

# Usage: apply_prefix_registry <com y|n> <override y|n> [manifest tag]
# Writes COM routing and/or the DLL override into the current prefix's
# registry and records them in the manifest (with the tag, "\t<appid>", for a
# companion). Sets REG_STATUS: ok, failed (regedit itself), or missing
# (regedit reported success but the override isn't in the prefix). The
# override is the one registry change EAX can't work without, so it's read
# back rather than trusting regedit's exit code alone; a prefix with no
# user.reg to read (return 2) is left as ok.
apply_prefix_registry() {
    local com="$1" override="$2" tag="${3:-}" reg_file
    REG_STATUS="ok"
    # Written into GAME_DIR rather than a temp dir: apply_registry_patch
    # (detection.sh) runs `protontricks -c` for Steam games, which executes
    # inside a Steam Runtime container that may not have /tmp bind-mounted —
    # the game's own library folder is guaranteed to be visible instead.
    reg_file="$GAME_DIR/dsoal_master_patch_$$.reg"
    {
        echo "Windows Registry Editor Version 5.00"
        echo ""
        if [ "$com" == "y" ]; then
            cat <<EOF
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
        if [ "$override" == "y" ]; then
            cat <<EOF
[HKEY_CURRENT_USER\Software\Wine\DllOverrides]
"${PRIMARY_DLL_NAME}"="native,builtin"

EOF
        fi
    } > "$reg_file"

    # The manifest lines are written whether or not regedit succeeded: a
    # partial import can still leave keys behind, and uninstall deleting a
    # key that was never set is harmless.
    [ "$com" == "y" ] && echo "REGISTRY:COM${tag}" >> "$INSTALL_MANIFEST"
    [ "$override" == "y" ] && echo "REGISTRY:OVERRIDE:${PRIMARY_DLL_NAME}${tag}" >> "$INSTALL_MANIFEST"
    if ! apply_registry_patch "$reg_file"; then
        REG_STATUS="failed"
    elif [ "$override" == "y" ]; then
        verify_dll_override "$PRIMARY_DLL_NAME"
        [ $? -eq 1 ] && REG_STATUS="missing"
    fi
    rm -f "$reg_file"

    if [ "$REG_STATUS" == "ok" ]; then
        [ "$com" == "y" ] && print_status "Injected: COM Registry Routing"
        [ "$override" == "y" ] && print_status "Injected: WINEDLLOVERRIDES (native,builtin) into registry"
    elif [ "$REG_STATUS" == "failed" ]; then
        print_error_arrow "Couldn't write the registry changes to ${GAME_NAME}'s prefix, so they aren't applied." \
            "The run log has the full output."
        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
    else
        print_error_arrow "The registry import reported success, but the ${PRIMARY_DLL_NAME}.dll override isn't in" \
            "${GAME_NAME}'s prefix registry, so Wine won't load the new DLL. The run log has the details."
        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
    fi
}

# Usage: remove_prefix_registry <com y|n> <override dll|"">
# Uninstall: deletes COM routing and/or the DLL override from the current
# prefix's registry. An empty dll with no manifest to say which one was set
# clears both dsound and openal32 — deleting a key that was never set is a
# harmless no-op. Returns apply_registry_patch's status.
remove_prefix_registry() {
    local com="$1" dll="$2" reg_file rc
    # In GAME_DIR for the same reason as apply_prefix_registry's.
    reg_file="$GAME_DIR/dsoal_registry_clean_$$.reg"
    {
        echo "Windows Registry Editor Version 5.00"
        echo ""
        if [ "$dll" == "both" ]; then
            printf '[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n"dsound"=-\n"openal32"=-\n\n'
        elif [ -n "$dll" ]; then
            printf '[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\n"%s"=-\n\n' "$dll"
        fi
        if [ "$com" == "y" ]; then
            cat <<EOF
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{3901CC3F-84B5-4FA4-BA35-AA8172B8A09B}]
[-HKEY_CURRENT_USER\Software\Classes\WOW6432Node\CLSID\{47D4D946-62E8-11CF-93BC-444553540000}]
EOF
        fi
    } > "$reg_file"
    apply_registry_patch "$reg_file"; rc=$?
    rm -f "$reg_file"
    return "$rc"
}

# Usage: install_companion_vcrun <index>
# Install Phase 2, run through with_companion when this companion's prefix
# gets the VC++ runtime installed: its own task (header and bar step), ahead
# of install_companion_prefix's.
install_companion_vcrun() {
    VCRUN_TASK_FOR="$GAME_NAME"
    install_vcrun_dependencies && printf 'VCRUN\t%s\n' "$APPID" >> "$INSTALL_MANIFEST"
    VCRUN_TASK_FOR=""
}

# Usage: install_companion_prefix <index>
# Install Phase 2, run through with_companion: the same prefix steps the game
# itself just had, in this companion's prefix, recorded with its AppID.
install_companion_prefix() {
    local i="$1" tag=$'\t'"$APPID"
    if [ "${COMPANION_VCRUN[$i]:-}" == "overrides" ]; then
        # Recorded even if setting them failed (that warns on its own), so
        # uninstall still tries to clear any that did get written.
        apply_vcrun_dll_overrides
        echo "VCRUN${tag}" >> "$INSTALL_MANIFEST"
    fi
    install_openal_runtime
    deploy_prefix_dlls
    local com="n" override="n"
    [[ "$ADVANCED_COM" =~ $YES_RE ]] && com="y"
    [ "${COMPANION_OVERRIDE[$i]}" == "registry" ] && override="y"
    if [ "$com" == "y" ] || [ "$override" == "y" ]; then
        apply_prefix_registry "$com" "$override" "$tag"
        [ "$REG_STATUS" != "ok" ] && [ "$override" == "y" ] && COMPANION_OVERRIDE[i]="manual"
    fi
}

# Usage: apply_companion_launcher_overrides
# Install Phase 2, inside apply_launcher_override once the launcher is
# closed: the DLL override in each launcher-method companion's own Steam
# launch options. A companion it can't be written for drops to manual.
apply_companion_launcher_overrides() {
    local i saved_file="$OVERRIDE_FILE" saved_id="$OVERRIDE_ID"
    for i in "${!COMPANION_IDS[@]}"; do
        [ "${COMPANION_OVERRIDE[$i]}" == "launcher" ] || continue
        OVERRIDE_ID="${COMPANION_IDS[$i]}"; OVERRIDE_FILE="${COMPANION_OVERRIDE_FILES[$i]}"
        _write_launcher_override || COMPANION_OVERRIDE[i]="manual"
    done
    OVERRIDE_FILE="$saved_file"; OVERRIDE_ID="$saved_id"
}

# Usage: choose_companion_overrides
# Install step 10, after choose_override_method: each companion follows the
# game's choice. The launcher choice needs Steam to have saved settings for
# the companion; without them its override goes into its own prefix's
# registry instead.
choose_companion_overrides() {
    local i file
    COMPANION_OVERRIDE=(); COMPANION_OVERRIDE_FILES=()
    for i in "${!COMPANION_IDS[@]}"; do
        COMPANION_OVERRIDE[i]="$OVERRIDE_METHOD"; COMPANION_OVERRIDE_FILES[i]=""
        [ "$OVERRIDE_METHOD" == "launcher" ] || continue
        file="$(steam_localconfig_for_app "${COMPANION_IDS[$i]}")"
        if [ -n "$file" ]; then
            COMPANION_OVERRIDE_FILES[i]="$file"
        else
            COMPANION_OVERRIDE[i]="registry"
            print_note "Steam has no settings saved for ${COMPANION_NAMES[$i]} yet, so its DLL override" \
                "goes into its Proton prefix's registry instead."
        fi
    done
}

# Usage: choose_companion_vcrun <checked y|n>
# Install step 7, after the game's own prefix was checked: sets
# COMPANION_VCRUN to install / overrides / "" for each companion's prefix.
# Unchecked (the player skipped the check) leaves them all alone.
choose_companion_vcrun() {
    local i
    COMPANION_VCRUN=()
    for i in "${!COMPANION_IDS[@]}"; do
        COMPANION_VCRUN[i]=""
        [ "$1" == "y" ] || continue
        print_task "Checking ${COMPANION_NAMES[$i]}'s prefix for existing VC++ runtime files"
        with_companion "$i" verify_vcrun_files
        if [ "$VCRUN_SUCCESS" -eq 1 ]; then
            print_status "Core VC++ runtime files are already present, so there's nothing to install." "$GREEN"
            COMPANION_VCRUN[i]="overrides"
        elif [ "$INSTALL_VCRUN" == "y" ]; then
            COMPANION_VCRUN[i]="install"
        elif [ "${APPLY_VCRUN_OVERRIDES_NEEDED:-0}" == "1" ]; then
            # The game's own prefix had them, so the player hasn't been asked.
            confirm "Install genuine MS VC++ runtimes into ${COMPANION_NAMES[$i]}'s prefix?" \
                && COMPANION_VCRUN[i]="install"
        fi
    done
}

# Usage: print_companion_final_steps
# Under "Final Steps to activate EAX": where each companion's override went,
# or the launch options to set by hand.
print_companion_final_steps() {
    local i
    for i in "${!COMPANION_IDS[@]}"; do
        case "${COMPANION_OVERRIDE[$i]}" in
            launcher) print_status "${COMPANION_NAMES[$i]}: the DLL override is set in its own Steam launch options too." "$WHITE" ;;
            registry) print_status "${COMPANION_NAMES[$i]}: the DLL override is set in its own Proton prefix registry too." "$WHITE" ;;
            *) print_status "${COMPANION_NAMES[$i]}: add the same Steam launch options to it: WINEDLLOVERRIDES=\"${PRIMARY_DLL_NAME}=n,b\" %command%" "$YELLOW" ;;
        esac
    done
}

# Usage: note_companion_manifest_line <line>
# Uninstall step 3: records a companion's tagged VCRUN / REGISTRY: line in
# UNINSTALL_COMPANION_VCRUN / _COM / _OVERRIDE (keyed by AppID) and adds the
# AppID to UNINSTALL_COMPANION_IDS.
note_companion_manifest_line() {
    local id="${1##*$'\t'}" what="${1%%$'\t'*}" known
    [[ "$id" =~ ^[0-9]+$ ]] || return 0
    case "$what" in
        VCRUN) UNINSTALL_COMPANION_VCRUN[$id]="y" ;;
        REGISTRY:COM) UNINSTALL_COMPANION_COM[$id]="y" ;;
        REGISTRY:OVERRIDE:*) UNINSTALL_COMPANION_OVERRIDE[$id]="${what#REGISTRY:OVERRIDE:}" ;;
        *) return 0 ;;
    esac
    for known in "${UNINSTALL_COMPANION_IDS[@]}"; do [ "$known" == "$id" ] && return 0; done
    UNINSTALL_COMPANION_IDS+=("$id")
}

# Usage: resolve_uninstall_companions
# Uninstall step 3, after the manifest is read: fills COMPANION_IDS / _NAMES
# / _PREFIXES from UNINSTALL_COMPANION_IDS (so with_companion works) and says
# what's there. A companion whose prefix is gone (Steam deletes it with the
# app) has nothing left to clean up.
resolve_uninstall_companions() {
    COMPANION_IDS=(); COMPANION_NAMES=(); COMPANION_PREFIXES=()
    local id name prefix what
    for id in "${UNINSTALL_COMPANION_IDS[@]}"; do
        name="$(companion_name_for_id "$id")"
        prefix="$(steam_prefix_for_appid "$id")"
        if [ -z "$prefix" ]; then
            print_status "${name}: its prefix is gone, so there's nothing left to clean up there." ""
            continue
        fi
        COMPANION_IDS+=("$id"); COMPANION_NAMES+=("$name"); COMPANION_PREFIXES+=("$prefix")
        what=""
        [ -n "${UNINSTALL_COMPANION_COM[$id]:-}" ] && what="COM routing"
        [ -n "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}" ] && what+="${what:+ and }the ${UNINSTALL_COMPANION_OVERRIDE[$id]} override"
        [ -n "$what" ] && print_status "${name}'s registry: ${what}" ""
        [ -n "${UNINSTALL_COMPANION_VCRUN[$id]:-}" ] && print_status "${name}'s VC++ runtime: installed by this script" ""
    done
}

# Usage: uninstall_companion_prefix <index>
# Uninstall Phase 2, run through with_companion: removes this companion's
# registry changes, and its VC++ runtime when Phase 1's answer was yes.
uninstall_companion_prefix() {
    local i="$1" id="$APPID" com="n"
    [ -n "${UNINSTALL_COMPANION_COM[$id]:-}" ] && com="y"
    if [ "$com" == "y" ] || [ -n "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}" ]; then
        if remove_prefix_registry "$com" "${UNINSTALL_COMPANION_OVERRIDE[$id]:-}"; then
            print_status "Registry keys removed from ${GAME_NAME}'s prefix." "$GREEN"
        else
            print_warning_arrow "The registry keys couldn't be removed from ${GAME_NAME}'s prefix. The run log has the full output."
        fi
    fi
    [ "${UNINSTALL_COMPANION_VCRUN_REMOVE[$i]:-n}" == "y" ] && uninstall_vcrun_dependencies
}
