ensure_known_games_json() {
    # Usage: ensure_known_games_json
    # Fetches known-eax-games.json fresh into a temp file, validates it's
    # well-formed JSON, then promotes it over the cached copy — never
    # overwrites a good cache with a truncated/bad response. Falls back to
    # the last-good cache if the fetch or validation fails, and to nothing
    # (KNOWN_GAMES_FILE stays empty, return 1) if there's no usable cache
    # either. Memoized per run via KNOWN_GAMES_FILE on success — but this
    # function is called several times per install (notes, no-op warning,
    # Audio API Detection), so a *failure* is memoized too via
    # KNOWN_GAMES_ATTEMPTED, otherwise a genuinely offline run retries the
    # full fetch (10s timeout each) and reprints the same failure message
    # on every single call instead of once.
    #
    # EAX_RESTORE_KNOWN_GAMES_FILE points this at a local file instead of
    # fetching — for testing schema/data edits to known-eax-games.json
    # before they've been pushed to the branch KNOWN_GAMES_URL fetches from.
    [ -n "$KNOWN_GAMES_FILE" ] && return 0
    [ -n "$KNOWN_GAMES_ATTEMPTED" ] && return 1
    KNOWN_GAMES_ATTEMPTED=1
    command -v jq &> /dev/null || return 1

    if [ -n "${EAX_RESTORE_KNOWN_GAMES_FILE:-}" ]; then
        if [ -s "$EAX_RESTORE_KNOWN_GAMES_FILE" ] && jq empty "$EAX_RESTORE_KNOWN_GAMES_FILE" 2>/dev/null; then
            KNOWN_GAMES_FILE="$EAX_RESTORE_KNOWN_GAMES_FILE"
            { print_note "EAX_RESTORE_KNOWN_GAMES_FILE is set — using $EAX_RESTORE_KNOWN_GAMES_FILE instead of fetching."; echo ""; } >&2
        else
            { print_error "EAX_RESTORE_KNOWN_GAMES_FILE is set but the file is missing or not valid JSON."; echo ""; } >&2
            return 1
        fi
    else
        local tmp
        tmp=$(mktemp 2>/dev/null)
        if [ -n "$tmp" ] && curl -fsSL --max-time 10 "$KNOWN_GAMES_URL" -o "$tmp" 2>/dev/null && jq empty "$tmp" 2>/dev/null; then
            mkdir -p "$BASE_SHARE" 2>/dev/null
            mv "$tmp" "$KNOWN_GAMES_CACHE"
            KNOWN_GAMES_FILE="$KNOWN_GAMES_CACHE"
        else
            rm -f "$tmp" 2>/dev/null
            if [ -s "$KNOWN_GAMES_CACHE" ] && jq empty "$KNOWN_GAMES_CACHE" 2>/dev/null; then
                KNOWN_GAMES_FILE="$KNOWN_GAMES_CACHE"
                { echo ""; print_note_arrow "couldn't refresh the known-EAX-games database (offline?) — using the last cached copy."; } >&2
            else
                # No message here — every caller that has something
                # meaningful to say about a missing database says it
                # itself, in its own context (scan_game_libraries has its
                # own explicit notice; confirm_continue_if_openal_native
                # explains it right under the Audio API Detection header).
                # A generic message from here would surface wherever this
                # function happens to be called first, disconnected from
                # whichever step the user is actually looking at.
                return 1
            fi
        fi
    fi

    # The database schema evolves alongside this script. If the loaded copy
    # predates the schema this version expects (served from a branch that
    # hasn't merged a schema change yet, or a stale offline cache), several
    # checks below silently fall back to a default instead of erroring —
    # jq's `//` can't tell "key legitimately absent" from "key doesn't
    # exist in this schema yet" apart. Warn once so that's visible instead
    # of a checkbox that quietly never fires.
    if ! jq -e --argjson want "$KNOWN_GAMES_SCHEMA_VERSION" \
        '(.schema_version // 1) >= $want' "$KNOWN_GAMES_FILE" >/dev/null 2>&1; then
        { echo ""; print_warning_arrow "$KNOWN_GAMES_FILE predates the schema this script version expects" \
            "(no per-store 'stores' block) — it looks like an older database. Audio API" \
            "Detection and some install-time notes won't work correctly until it updates."; } >&2
    fi

    return 0
}

record_recent_game() {
    # Usage: record_recent_game <path>
    # Adds/moves a game directory to the top of the recent-games history
    # (most-recently-used first), deduped, capped at 10 entries. Best-effort
    # — never blocks anything if it fails to write.
    local path="$1"
    mkdir -p "$BASE_SHARE" 2>/dev/null
    local tmp
    tmp=$(mktemp 2>/dev/null) || return
    { echo "$path"; [ -f "$RECENT_GAMES_FILE" ] && grep -Fxv "$path" "$RECENT_GAMES_FILE"; } | head -n 10 > "$tmp" 2>/dev/null
    mv "$tmp" "$RECENT_GAMES_FILE" 2>/dev/null
}

prompt_recent_game() {
    # Usage: prompt_recent_game
    # If a recent-games history exists, offers a numbered pick list plus the
    # option to enter a new path. For uninstall specifically, the list is
    # filtered to only games that actually have something installed via
    # this script right now — a folder with no manifest, or one that's just
    # the "already uninstalled" sentinel, has nothing to act on and would
    # only clutter the picker. Install shows every visited folder, since
    # revisiting any of them (installed before or not) is meaningful there.
    # Sets GAME_DIR and returns 0 if the user picked an existing entry;
    # returns 1 (GAME_DIR left empty) if they chose to enter a new path, or
    # if there's no usable history — callers fall through to manual entry.
    GAME_DIR=""
    [ -f "$RECENT_GAMES_FILE" ] || return 1

    local paths=()
    local p manifest
    while IFS= read -r p; do
        [ -n "$p" ] && [ -d "$p" ] || continue
        if [ "$SCRIPT_ACTION" == "u" ]; then
            manifest="$p/.eax-restore-manifest.txt"
            [ -s "$manifest" ] || continue
            head -n 1 "$manifest" | grep -q "^# EAX Restore: uninstalled" && continue
        fi
        paths+=("$p")
    done < "$RECENT_GAMES_FILE"

    [ ${#paths[@]} -eq 0 ] && return 1

    if [ "$SCRIPT_ACTION" == "u" ]; then
        echo -e "${WHITE}Games with something installed via this script:${NC}"
    else
        echo -e "${WHITE}Previously used game folders:${NC}"
    fi
    local i
    for i in "${!paths[@]}"; do
        print_option "$((i + 1))" "${paths[$i]}"
    done
    print_option 0 "Enter a different path"

    prompt "Selection [0-${#paths[@]}]: "
    local choice
    read -r choice

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#paths[@]} ]; then
        GAME_DIR="${paths[$((choice - 1))]}"
        return 0
    fi
    return 1
}

block_if_eax_not_implemented() {
    # Usage: block_if_eax_not_implemented <id> <steam|gog> <game_name>
    # Early twin of confirm_continue_if_eax_impossible's hard-block branches
    # (not_implemented, and removed_by_patch with no build_workaround_available)
    # — called right after the scan pick so a known dead end is caught before
    # wasting the user's time on AppID/prefix detection. On a match it hands
    # off to prompt_restart_or_quit, which either exits or sets
    # RESTART_REQUESTED for scan_game_libraries to unwind on.
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return
    ensure_known_games_json || return

    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local status workaround
    status=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_status // "supported"' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    workaround=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .build_workaround_available // false' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)

    if [ "$status" == "not_implemented" ]; then
        print_error "$3 never implemented EAX/environmental audio in the first place, so" \
            "there would be nothing here for this script to restore."
        prompt_restart_or_quit 1
        return
    fi

    if [ "$status" == "removed_by_patch" ] && [ "$workaround" != "true" ]; then
        print_error "EAX/A3D support was removed from $3's current build by a software update," \
            "and there's no known in-place fix — restoring it would need a separate install this" \
            "script isn't pointed at."
        prompt_restart_or_quit 1
        return
    fi
}

detect_steam_beta_branch() {
    # Usage: detect_steam_beta_branch <acf_file>
    # Echoes the appmanifest's opted-in/mounted Steam beta branch ("BetaKey"),
    # or nothing if there isn't one. Both "MountedConfig" (the branch actually
    # installed — only present once Steam finishes updating to it) and
    # "UserConfig" (the branch selected, which may not be downloaded yet)
    # carry a same-named "BetaKey" key, so a plain grep across the whole file
    # can't tell them apart — awk scopes the match to whichever block it's
    # inside. MountedConfig wins when both are present since it reflects the
    # actually-installed content, which is what the game will actually run.
    local acf="$1"
    [ -f "$acf" ] || return
    local key
    key=$(awk '/"MountedConfig"/{f=1} f&&/"BetaKey"/{print;exit}' "$acf" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"BetaKey"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')
    if [ -z "$key" ]; then
        key=$(awk '/"UserConfig"/{f=1} f&&/"BetaKey"/{print;exit}' "$acf" 2>/dev/null \
            | sed -n 's/^[[:space:]]*"BetaKey"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p')
    fi
    echo "$key"
}

scan_game_libraries() {
    # Usage: scan_game_libraries
    # Opt-in alternative to browsing/typing a path: scans Steam and Heroic
    # libraries for games present in known-eax-games.json, lists the
    # matches, and resolves the pick's actual .exe folder (via
    # resolve_exe_folder) into GAME_DIR. Also sets SCANNED_APPID so
    # detect_game_environment's Steam branch can skip its own redundant
    # AppID search/confirmation. Returns 1 (GAME_DIR left empty) if nothing
    # was found or picked, so get_game_directory falls through to its
    # normal manual/GUI-picker flow.
    GAME_DIR=""
    GAME_NAME=""
    SCANNED_APPID=""
    SCANNED_NOTES_SHOWN=""
    OPENAL_NATIVE_MODE=""
    EAX_UNIFIED=""

    if ! ensure_known_games_json; then
        print_note "library scanning needs the known-EAX-games database, which isn't available this run."
        echo ""
        return 1
    fi

    print_task "Scanning Steam and Heroic libraries for known EAX games"

    # names[] is the curated known-eax-games.json display name, used only for
    # the pick-list menu below. meta_names[] is the name as reported by the
    # game's OWN install metadata (the Steam appmanifest's "name" key, or the
    # GOG/Heroic install folder itself) — sourced the same way appid/gog_id
    # already are, independent of the JSON — and becomes GAME_NAME once a
    # pick is made, for use in prompts that need the actual game's name.
    local names=() meta_names=() paths=() stores=() ids=()

    # --- Steam ---
    local steam_ids
    steam_ids=$(jq -r '.games[] | select(.stores.steam.id != null) | .stores.steam.id' "$KNOWN_GAMES_FILE" 2>/dev/null)
    if [ -n "$steam_ids" ]; then
        local steam_roots=("$HOME/.local/share/Steam" "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam")
        local -A lib_seen=()
        local libs=()
        local root vdf extra
        for root in "${steam_roots[@]}"; do
            if [ -d "$root/steamapps" ] && [ -z "${lib_seen["$root/steamapps"]:-}" ]; then
                libs+=("$root/steamapps"); lib_seen["$root/steamapps"]=1
            fi
            vdf="$root/steamapps/libraryfolders.vdf"
            [ -f "$vdf" ] || continue
            while IFS= read -r extra; do
                [ -n "$extra" ] || continue
                if [ -d "$extra/steamapps" ] && [ -z "${lib_seen["$extra/steamapps"]:-}" ]; then
                    libs+=("$extra/steamapps"); lib_seen["$extra/steamapps"]=1
                fi
            done < <(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$vdf" 2>/dev/null)
        done

        local lib acf appid installdir name meta_name
        for lib in "${libs[@]}"; do
            for acf in "$lib"/appmanifest_*.acf; do
                [ -f "$acf" ] || continue
                appid=$(basename "$acf" | tr -dc '0-9')
                [ -z "$appid" ] && continue
                echo "$steam_ids" | grep -qx "$appid" || continue
                installdir=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" 2>/dev/null | head -n 1)
                [ -n "$installdir" ] && [ -d "$lib/common/$installdir" ] || continue
                name=$(jq -r --arg id "$appid" '.games[] | select((.stores.steam.id | tostring) == $id) | .name' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
                [ -z "$name" ] && name="AppID $appid"
                meta_name=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$acf" 2>/dev/null | head -n 1)
                [ -z "$meta_name" ] && meta_name="AppID $appid"
                names+=("$name")
                meta_names+=("$meta_name")
                paths+=("$lib/common/$installdir")
                stores+=("steam")
                ids+=("$appid")
            done
        done
    fi

    # --- Heroic ---
    local gog_ids
    gog_ids=$(jq -r '.games[] | select(.stores.gog.id != null) | .stores.gog.id' "$KNOWN_GAMES_FILE" 2>/dev/null)
    if [ -n "$gog_ids" ]; then
        local installed_jsons
        installed_jsons=$(find "$HOME/.config/heroic" "$HOME/.var/app/com.heroicgameslauncher.hgl/config/heroic" -type f -name "installed.json" 2>/dev/null)
        local json_file install_path app_name name meta_name
        while IFS= read -r json_file; do
            [ -z "$json_file" ] && continue
            while IFS=$'\t' read -r install_path app_name; do
                [ -z "$install_path" ] || [ -z "$app_name" ] && continue
                echo "$gog_ids" | grep -qx "$app_name" || continue
                [ -d "$install_path" ] || continue
                name=$(jq -r --arg id "$app_name" '.games[] | select((.stores.gog.id | tostring) == $id) | .name' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
                [ -z "$name" ] && name="GOG ID $app_name"
                meta_name="$(basename "$install_path")"
                [ -z "$meta_name" ] && meta_name="GOG ID $app_name"
                names+=("$name")
                meta_names+=("$meta_name")
                paths+=("$install_path")
                stores+=("gog")
                ids+=("$app_name")
            done < <(awk 'BEGIN { RS="}"; FS="," } { ip=""; an=""; for (i=1; i<=NF; i++) { if ($i ~ /"(install_path|installPath)"/) { line=$i; sub(/^.*"(install_path|installPath)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); ip=line } if ($i ~ /"(app_name|appName)"/) { line=$i; sub(/^.*"(app_name|appName)"[ \t]*:[ \t]*"/, "", line); sub(/".*$/, "", line); an=line } } if (ip != "") print ip "\t" an }' "$json_file")
        done <<< "$installed_jsons"
    fi

    if [ ${#names[@]} -eq 0 ]; then
        echo -e "\n${YELLOW}No known EAX games were found in your Steam or Heroic libraries.${NC}"
        echo -e "\n${WHITE}This only checks the community-maintained known-games list, which currently"
        echo -e "covers a small, hand-verified set of titles — it will grow over time. A game"
        echo -e "you own may still support EAX even if it's not listed yet.${NC}\n"
        return 1
    fi

    echo -e "\n${WHITE}Known EAX games found in your libraries:${NC}"
    local i store_label
    for i in "${!names[@]}"; do
        store_label="Steam"
        [ "${stores[$i]}" == "gog" ] && store_label="GOG"
        print_option "$((i + 1))" "${names[$i]}" "(${store_label})"
    done
    print_option 0 "None of these / enter a path manually"

    local choice
    while true; do
        prompt "Selection [0-${#names[@]}]: "
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 0 ] && [ "$choice" -le ${#names[@]} ]; then
            break
        fi
        print_warning "That's not a valid option — please enter a number from 0-${#names[@]}."
        echo ""
    done
    if [ "$choice" -eq 0 ]; then
        return 1
    fi

    local idx=$((choice - 1))

    show_game_details_block "${ids[$idx]}" "${stores[$idx]}" "${paths[$idx]}"
    block_if_eax_not_implemented "${ids[$idx]}" "${stores[$idx]}" "${meta_names[$idx]}"
    # User chose "pick a different game" at the EAX-impossible prompt — bail
    # back to get_game_directory's menu instead of asking to continue with it.
    [ -n "$RESTART_REQUESTED" ] && return 1

    confirm "Continue with this game?" || return 1

    GAME_NAME="${meta_names[$idx]}"

    resolve_exe_folder "${paths[$idx]}" || return 1

    [ "${stores[$idx]}" == "steam" ] && SCANNED_APPID="${ids[$idx]}"
    return 0
}

# Per-game notes and EAX-impossible flags now live in the community-
# maintained known-eax-games.json (see ensure_known_games_json above and
# known-eax-games.json in this repo) rather than hardcoded here, so entries
# can be added/corrected via PR without touching this script. Entries are
# still only added when independently verified against the storefront's
# own API — a wrong/stale ID would misdirect users to the wrong game.

resolve_eax_unified() {
    # Usage: resolve_eax_unified <id> <steam|gog>
    # Sets EAX_UNIFIED=1 when the known-games entry for this id is flagged
    # `eax_unified` (the ~32 titles that reach EAX through Creative's eax.dll
    # shim rather than native DirectSound3D), "" otherwise. Cheap and
    # idempotent — safe to call from more than one step. show_game_details_block
    # calls it for the common (matched) path; the Advanced Compatibility Tweaks
    # step calls it too so the guarded Tweak-A sub-flow still fires when the
    # user skipped the Audio API Detection database check.
    EAX_UNIFIED=""
    [ -z "$1" ] && return
    ensure_known_games_json || return
    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local flag
    flag=$(jq -r --arg id "$1" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_unified // false' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    [ "$flag" == "true" ] && EAX_UNIFIED=1
}

show_known_game_notes() {
    # Usage: show_known_game_notes <id> <steam|gog> [skip_availability]
    # Best-effort, install-only heads-up for well-known EAX titles, sourced
    # from the game-level `notes` field of known-eax-games.json. Notes are
    # stored as a single unwrapped line for easy editing, then word-wrapped to
    # the script's usual prose width at display time. stores.<store>.listing
    # ("delisted") is shown as an Availability line here too, EXCEPT when the
    # caller already surfaced it in a GAME DETAILS block (show_game_details_block
    # passes skip_availability=1 to avoid printing it twice) — call sites that
    # don't go through a GAME DETAILS block (e.g. an unmatched manual entry)
    # still need this fallback.
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return
    ensure_known_games_json || return

    local store="steam" store_label="Steam"
    if [ "$2" == "gog" ]; then
        store="gog"; store_label="GOG"
    fi

    local notes listing
    notes=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .notes // empty' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)

    if [ -z "$3" ]; then
        listing=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].listing // empty' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
        if [ "$listing" == "delisted" ]; then
            echo -e "\n${NOTE}  Note: this game is currently delisted from ${store_label}'s storefront —"
            echo -e "  existing owners keep access, but it can't be newly purchased there anymore.${NC}"
        fi
    fi

    [ -z "$notes" ] && return
    print_subheading "Notes"
    print_wrapped "$notes"
}

show_game_details_block() {
    # Usage: show_game_details_block <id> <steam|gog> <location>
    # The richer "--- GAME DETAILS ---" banner scan_game_libraries shows when
    # a game is picked from a library scan, factored out so the manual/GUI
    # path can show the same thing once detect_game_environment has confirmed
    # a prefix and therefore knows the id to look this up by. Only prints
    # when known-eax-games.json actually has a matching entry — an unmatched
    # manual pick has nothing to show, same as before this existed.
    local id="$1" store="$2" location="$3"
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$id" ] && return
    ensure_known_games_json || return

    local store_label="Steam"
    [ "$store" == "gog" ] && store_label="GOG"

    local match_count
    match_count=$(jq -r --arg id "$id" --arg store "$store" \
        '[.games[] | select((.stores[$store].id // "") | tostring == $id)] | length' \
        "$KNOWN_GAMES_FILE" 2>/dev/null)
    [ "${match_count:-0}" -gt 0 ] || return

    local name eax_versions api listing eax_status eax_status_details restore_details
    local store_details patches id_confidence
    name=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .name' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    eax_versions=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_versions // [] | join(", ")' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    api=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | (.stores[$store].api // .default_api // "directsound3d")' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    listing=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].listing // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    eax_status=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_status // "supported"' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    [ -z "$eax_status" ] && eax_status="supported"
    eax_status_details=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_status_details // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    restore_details=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .restore_details // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    store_details=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].store_details // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    patches=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].patches // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    id_confidence=$(jq -r --arg id "$id" --arg store "$store" \
        '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].id_confidence // empty' \
        "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)

    resolve_eax_unified "$id" "$store"

    # --- Field lines: identity, then how EAX stands on this build ---
    print_banner "GAME DETAILS"
    echo -e "\n -> ${YELLOW}Name${NC}:      ${BOLD}${name}${NC}"
    echo -e " -> ${YELLOW}Platform${NC}:  ${GREEN}$store_label${NC}"
    if [ "$listing" == "delisted" ]; then
        echo -e " -> ${YELLOW}Availability${NC}: ${WHITE}Delisted from $store_label ${DIM}(existing owners keep access)${NC}"
    fi
    if [ "$id_confidence" == "steamdb_historical" ]; then
        echo -e " -> ${YELLOW}ID source${NC}: ${WHITE}SteamDB records ${DIM}(not verified against a local install)${NC}"
    fi
    # eax_versions sits in the same slot for every game — the qualifier for a
    # patch-removed build comes after the list, not in place of it.
    local ver_display="${eax_versions:-Unknown}"
    if [ "$eax_status" == "supported" ]; then
        echo -e " -> ${YELLOW}EAX Support${NC}: ${GREEN}${BOLD}${ver_display}${NC}"
    elif [ "$eax_status" == "removed_by_patch" ]; then
        echo -e " -> ${YELLOW}EAX Support${NC}: ${YELLOW}${BOLD}${ver_display}${NC} ${DIM}(originally supported)${NC}"
    else
        echo -e " -> ${YELLOW}EAX Support${NC}: ${YELLOW}${BOLD}None${NC}"
    fi
    if [ "$api" == "openal" ]; then
        echo -e " -> ${YELLOW}Audio API${NC}: ${WHITE}OpenAL${NC}"
    else
        echo -e " -> ${YELLOW}Audio API${NC}: ${WHITE}DirectSound3D${NC}"
    fi
    [ -n "$EAX_UNIFIED" ] && echo -e " -> ${YELLOW}EAX Unified${NC}: ${WHITE}Yes${NC}"
    echo -e " -> ${YELLOW}Location${NC}:  ${DIM}${location}${NC}"

    # --- Blocks: status -> problem -> solution ---
    if [ "$eax_status" == "removed_by_patch" ] || [ "$eax_status" == "not_implemented" ]; then
        local state_line="Never implemented in this edition."
        [ "$eax_status" == "removed_by_patch" ] && state_line="Removed by a later patch."
        print_subheading "Status"
        if [ -n "$eax_status_details" ]; then
            print_wrapped "$state_line $eax_status_details"
        else
            print_wrapped "$state_line"
        fi
    fi
    if [ -n "$store_details" ]; then
        print_subheading "$store_label details"
        print_wrapped "$store_details"
    fi
    if [ "$eax_status" == "supported" ]; then
        local solution="DSOAL + OpenAL Soft"
        [ "$api" == "openal" ] && solution="OpenAL Soft"
        print_subheading "Restoring EAX with"
        print_wrapped "$solution"
    fi
    if [ -n "$restore_details" ]; then
        print_subheading "Additional steps"
        print_wrapped "$restore_details"
    fi
    show_known_game_notes "$id" "$store" 1
    SCANNED_NOTES_SHOWN=1
    if [ -n "$patches" ]; then
        print_subheading "Suggested community patches"
        print_wrapped "$patches"
    fi
    echo ""
}

confirm_continue_if_eax_impossible() {
    # Usage: confirm_continue_if_eax_impossible <id> <steam|gog> [acf_file]
    # eax_status distinguishes two reasons this script has nothing to restore
    # on a build: "removed_by_patch" (a software update stripped EAX/A3D
    # calls from an otherwise-DirectSound3D game) vs. "not_implemented" (a
    # remaster/rewrite that never had EAX in the first place — no
    # build-level fix exists). "not_implemented" is an unconditional no-op,
    # so it skips straight to prompt_restart_or_quit. "removed_by_patch" is
    # only a confirmable warning ("install anyway" stays offered) when
    # build_workaround_available is true — meaning restore_details documents
    # an in-place fix within this same store install (e.g. a Steam beta
    # branch) the user might already be on or willing to switch to;
    # otherwise (the field is absent) the only fix is a separate install this
    # run isn't pointed at, so it hard-blocks exactly like "not_implemented".
    # Either way the dead end offers "pick a different game" rather than just
    # ending the script — see prompt_restart_or_quit / the Steps 1-2 loop in
    # config-flow.sh.
    [ "$SCRIPT_ACTION" == "i" ] || return
    [ -z "$1" ] && return

    local store="steam"
    [ "$2" == "gog" ] && store="gog"
    local acf_file="$3"

    local status="" workaround="false" beta_branch=""
    if ensure_known_games_json; then
        status=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .eax_status // "supported"' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
        workaround=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .build_workaround_available // false' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
        beta_branch=$(jq -r --arg id "$1" --arg store "$store" '.games[] | select((.stores[$store].id // "") | tostring == $id) | .stores[$store].beta_branch // empty' "$KNOWN_GAMES_FILE" 2>/dev/null | head -n 1)
    elif [ "$store" != "gog" ] && [ -n "${EAX_IMPOSSIBLE_FALLBACK_STEAM[$1]:-}" ]; then
        # Only ever seeds Half-Life (AppID 70), which has no in-place
        # workaround — workaround stays "false".
        status="removed_by_patch"
    fi
    if [ -z "$status" ] || [ "$status" == "supported" ]; then
        return
    fi

    if [ "$status" == "not_implemented" ]; then
        print_error "This edition never implemented EAX/environmental audio in the first place, so" \
            "there would be nothing here for this script to restore."
        prompt_restart_or_quit 1
        return
    fi

    if [ "$workaround" != "true" ]; then
        print_error "EAX/A3D support was removed from this build by a software update, and there's" \
            "no known in-place fix — restoring it would need a separate install this script" \
            "isn't pointed at."
        prompt_restart_or_quit 1
        return
    fi

    # A known beta branch restores EAX in place — offer to check whether the
    # user is already on it before showing a warning that wouldn't apply to
    # them. Opt-in and reported before acting on it, same as every other
    # auto-detect in this script (Proton prefix, AppID search): ask first,
    # detect, report the raw result, then a separate confirm before it's
    # allowed to skip the warning below.
    if [ "$store" == "steam" ] && [ -n "$beta_branch" ] && [ -n "$acf_file" ]; then
        if confirm "Check if you're already on Steam's '$beta_branch' beta branch, which keeps EAX intact?"; then
            local detected
            detected=$(detect_steam_beta_branch "$acf_file")
            print_status "Detected beta branch: ${detected:-none}" ""
            if [ "$detected" == "$beta_branch" ]; then
                if confirm "Skip the EAX-removed warning — this build should already have EAX intact?"; then
                    return
                fi
            fi
        fi
    fi

    print_warning "EAX/A3D support was removed from this build by a software update, so there's" \
        "nothing for this script to restore on the current default build."

    if ! confirm "Continue installing anyway?" N; then
        prompt_restart_or_quit 0
        return
    fi
}
