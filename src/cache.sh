dsoal_official_cached() {
    [ -d "$DSOAL_OFFICIAL" ] && [ -n "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]
}

engine_available() {
    # Usage: engine_available <1|2>  (the ENGINE_CHOICE numbering)
    # Engine 1 needs DSOAL (the pinned build when EAX_RESTORE_DSOAL_PIN is
    # set) plus OpenAL Soft; engine 2 needs only OpenAL Soft.
    [ -n "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ] || return 1
    case "$1" in
        1) if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then [ -n "$(ls -A "$DSOAL_PINNED" 2>/dev/null)" ]; else dsoal_official_cached; fi ;;
        2) return 0 ;;
        *) return 1 ;;
    esac
}

fetch_pinned_dsoal_into_official() {
    # Used when the rolling latest-master build can't be obtained and there's
    # no cache (kcat's CI deletes latest-master before re-creating it, so a
    # failed CI run leaves it gone): installs the pinned archive revision into
    # the same $DSOAL_OFFICIAL folder, so the rest of the script needs no
    # special casing. Records "archive-<rev>" as the cached date, which can
    # never match a real latest-master updated_at, so the next run that can
    # reach latest-master upgrades to it automatically.
    print_status "Falling back to kcat's archived DSOAL build [$DSOAL_PINNED_REV]..."
    if curl -fL -# "$DSOAL_PINNED_URL" -o "$DSOAL_SHARE/pinned.zip" && unzip -tq "$DSOAL_SHARE/pinned.zip" &>/dev/null; then
        if verify_checksum "$DSOAL_SHARE/pinned.zip" "$DSOAL_PINNED_SHA256"; then
            rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
            unzip -q "$DSOAL_SHARE/pinned.zip" -d "$DSOAL_OFFICIAL"
            NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
            if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"; fi
            echo "archive-$DSOAL_PINNED_REV" > "$DSOAL_SHARE/updated_at.txt"; rm -f "$DSOAL_SHARE/pinned.zip"; print_status "Done." "$GREEN"
            return 0
        fi
        print_error_arrow "The archived build failed checksum verification."
    else
        print_error_arrow "The archived build download failed or the file was corrupt."
    fi
    rm -f "$DSOAL_SHARE/pinned.zip"
    print_error_arrow "kcat DSOAL will be unavailable this run (the OpenAL native engine still works)."
    return 1
}

update_local_cache() {
    print_banner "REPOSITORY CACHE CHECK"
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"

    echo -e "\n${CYAN}Checking kcat Official DSOAL repository...${NC}"
    # curl -s without -f still succeeds on an HTTP error, so a failure here
    # means GitHub is genuinely unreachable -- as opposed to reachable but
    # without an updated_at (latest-master missing upstream, or API rate limit).
    DSOAL_API_REACHABLE=1
    DSOAL_OFFICIAL_JSON=$(curl -s "$DSOAL_OFFICIAL_API_URL") || DSOAL_API_REACHABLE=0
    LATEST_DATE=$(echo "$DSOAL_OFFICIAL_JSON" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$LATEST_DATE" ]; then
        if dsoal_official_cached; then
            if [ "$DSOAL_API_REACHABLE" -eq 1 ]; then print_note_arrow "could not check for updates (kcat's latest-master release is unavailable). Using cached version [${LOCAL_DATE%%T*}]"
            else print_note_arrow "offline. Using cached version [${LOCAL_DATE%%T*}]"; fi
        elif [ "$DSOAL_API_REACHABLE" -eq 1 ]; then
            print_warning_arrow "kcat's latest-master build is unavailable upstream right now."
            fetch_pinned_dsoal_into_official
        else
            print_error_arrow "Offline and no cache found. kcat DSOAL will be unavailable this run."
        fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_OFFICIAL" ]; then
        print_status "Updates found! Downloading latest build..."
        if curl -fL -# "$DSOAL_OFFICIAL_URL" -o "$DSOAL_SHARE/dsoal.zip" && unzip -tq "$DSOAL_SHARE/dsoal.zip" &>/dev/null; then
            DSOAL_OFFICIAL_DIGEST=$(get_asset_digest "$DSOAL_OFFICIAL_JSON" "DSOAL.zip")
            if verify_or_confirm "$DSOAL_SHARE/dsoal.zip" "$DSOAL_OFFICIAL_DIGEST" "kcat Official DSOAL"; then
                rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
                unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_OFFICIAL"
                # kcat's DSOAL.zip release asset sometimes wraps its real
                # contents in a further nested DSOAL_*.zip, so a second
                # extraction pass is needed to actually reach the DLLs.
                NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
                if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"; fi
                echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"; rm -f "$DSOAL_SHARE/dsoal.zip"; print_status "Done." "$GREEN"
            else
                rm -f "$DSOAL_SHARE/dsoal.zip"
                if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]; then
                    print_warning_arrow "Skipping this download. Keeping existing cache [${LOCAL_DATE%%T*}]."
                else
                    print_error_arrow "Could not verify or confirm this download, and no usable cache exists."
                    fetch_pinned_dsoal_into_official
                fi
            fi
        else
            rm -f "$DSOAL_SHARE/dsoal.zip"
            if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]; then
                print_warning_arrow "Download failed or file was corrupt. Keeping existing cache [${LOCAL_DATE%%T*}]."
            else
                print_error_arrow "Download failed and no usable cache exists."
                fetch_pinned_dsoal_into_official
            fi
        fi
    else print_status "Up to date [${LOCAL_DATE%%T*}]" "$GREEN"; fi

    echo -e "\n${CYAN}Checking kcat OpenAL Soft repository...${NC}"
    # Unlike DSOAL_OFFICIAL_API_URL above, this resolves the tag via the
    # /releases/latest redirect rather than the Releases API. DSOAL is
    # pinned to the rolling "latest-master" tag (not a real "latest
    # release"), so the redirect trick can't resolve it there and the API
    # must be queried by tag name directly. OpenAL Soft does publish normal
    # dated releases, so the cheaper redirect trick works here.
    OAL_TAG=$(curl -sI https://github.com/kcat/openal-soft/releases/latest | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
    LOCAL_OAL_TAG=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$OAL_TAG" ]; then
        if [ -d "$OPENAL_OFFICIAL" ]; then print_note_arrow "offline. Using cached version [${LOCAL_OAL_TAG}]"
        else print_error_arrow "OpenAL cache missing."; print_offline_instructions; exit 1; fi
    elif [ "$OAL_TAG" != "$LOCAL_OAL_TAG" ] || [ ! -d "$OPENAL_OFFICIAL" ]; then
        print_status "Updates found! Downloading OpenAL Soft [${OAL_TAG}]..."
        OAL_ASSET_NAME="openal-soft-${OAL_TAG}-bin.zip"
        OAL_URL="https://github.com/kcat/openal-soft/releases/download/${OAL_TAG}/${OAL_ASSET_NAME}"
        if curl -fL -# "$OAL_URL" -o "$OPENAL_SHARE/openal.zip" && unzip -tq "$OPENAL_SHARE/openal.zip" &>/dev/null; then
            OPENAL_OFFICIAL_JSON=$(curl -s "https://api.github.com/repos/kcat/openal-soft/releases/tags/${OAL_TAG}")
            OAL_DIGEST=$(get_asset_digest "$OPENAL_OFFICIAL_JSON" "$OAL_ASSET_NAME")
            if verify_or_confirm "$OPENAL_SHARE/openal.zip" "$OAL_DIGEST" "kcat OpenAL Soft [$OAL_TAG]"; then
                rm -rf "$OPENAL_OFFICIAL"; mkdir -p "$OPENAL_OFFICIAL"
                unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_OFFICIAL"
                echo "$OAL_TAG" > "$OPENAL_SHARE/updated_at.txt"; rm -f "$OPENAL_SHARE/openal.zip"; print_status "Done." "$GREEN"
            else
                rm -f "$OPENAL_SHARE/openal.zip"
                if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                    print_warning_arrow "Skipping this download. Keeping existing cache [${LOCAL_OAL_TAG}]."
                else
                    print_error_arrow "Could not verify or confirm this download, and no usable cache exists."; exit 1
                fi
            fi
        else
            rm -f "$OPENAL_SHARE/openal.zip"
            if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                print_warning_arrow "Download failed or file was corrupt. Keeping existing cache [${LOCAL_OAL_TAG}]."
            else
                print_error_arrow "Download failed and no usable cache exists."; exit 1
            fi
        fi
    else print_status "Up to date [${LOCAL_OAL_TAG}]" "$GREEN"; fi

    # Only fetched when the user asks for the frozen fallback build. It's a
    # break-glass lever for when a rolling latest-master build regresses a
    # game, so there's no reason to pull it on every run.
    if is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        echo -e "\n${CYAN}Checking pinned kcat DSOAL [$DSOAL_PINNED_REV]...${NC}"
        if [ ! -d "$DSOAL_PINNED" ]; then
            print_status "Cache missing. Downloading pinned build [$DSOAL_PINNED_REV]..."
            mkdir -p "$DSOAL_PINNED"
            if curl -fL -# "$DSOAL_PINNED_URL" -o "$DSOAL_SHARE/pinned.zip" && unzip -tq "$DSOAL_SHARE/pinned.zip" &>/dev/null; then
                # Hard-fails on mismatch, unlike verify_or_confirm's softer
                # handling of the rolling latest-master download: a frozen,
                # already-superseded archive asset has a stable SHA256, so a
                # mismatch here means the file is genuinely wrong, not just
                # that GitHub hasn't published a digest yet.
                if verify_checksum "$DSOAL_SHARE/pinned.zip" "$DSOAL_PINNED_SHA256"; then
                    rm -rf "$DSOAL_PINNED"; mkdir -p "$DSOAL_PINNED"
                    unzip -q "$DSOAL_SHARE/pinned.zip" -d "$DSOAL_PINNED"
                    # Same nested DSOAL_*.zip wrapping as the latest-master asset.
                    NESTED=$(find "$DSOAL_PINNED" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
                    if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_PINNED"; fi
                    rm -f "$DSOAL_SHARE/pinned.zip"; print_status "Done." "$GREEN"
                else
                    rm -f "$DSOAL_SHARE/pinned.zip"; rm -rf "$DSOAL_PINNED"
                    print_error_arrow "The pinned build failed checksum verification, so it will be unavailable this run."
                fi
            else
                rm -f "$DSOAL_SHARE/pinned.zip"; rm -rf "$DSOAL_PINNED"
                print_error_arrow "The pinned build download failed or the file was corrupt, so it will be unavailable this run."
            fi
        else print_status "Available in cache." "$GREEN"; fi
    fi

    echo -e "\n${CYAN}Checking known EAX games database...${NC}"
    if ensure_known_games_json; then
        GAME_COUNT=$(jq '.games | length' "$KNOWN_GAMES_FILE" 2>/dev/null)
        print_status "Loaded (${GAME_COUNT:-0} games)." "$GREEN"
    else
        print_error_arrow "The download failed or the file was corrupt, so the game database will be unavailable this run."
    fi
}

handle_conflict() {
    local target_file="$1"
    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            # Already ours from a previous install (tracked in the prior
            # manifest before it was reset) — not a genuine original, so
            # there's nothing here worth backing up. Overwrite directly;
            # any real original backup from the very first install, if one
            # exists, is left untouched rather than buried under this.
            rm -f "$target_file"
            return 0
        fi
        echo -e "\n${YELLOW}$(basename "$target_file")${NC} ${WHITE}already exists at $(dirname "$target_file").${NC}"
        while true; do
            prompt "What would you like to do? [o]verwrite, [b]ackup & overwrite (default), [s]kip: "
            read -r C_CHOICE
            C_CHOICE="${C_CHOICE:-b}"
            case "${C_CHOICE,,}" in
                o) rm -rf "$target_file"; return 0 ;;
                b)
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    mv "$target_file" "${target_file}.bak.${TIMESTAMP}"
                    echo ""
                    print_status "Backed up original to $(basename "$target_file").bak.${TIMESTAMP}"
                    return 0 ;;
                s) echo ""; print_status "Skipped $(basename "$target_file")."; return 1 ;;
                *) print_warning "That's not a valid option — please type o, b, or s." ;;
            esac
        done
    fi
    return 0
}

auto_backup_and_overwrite() {
    # Usage: auto_backup_and_overwrite <target_file>
    # Like handle_conflict's [b]ackup option, but never prompts — always
    # backs up an existing file (timestamped) before it gets overwritten.
    # Used for the prefix copy of dsound.dll: it's a genuine system DLL
    # likely to already exist there, and backup-and-overwrite is already
    # handle_conflict's own default, so skipping the prompt here removes a
    # step without changing what actually happens in the common case.
    local target_file="$1"
    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            rm -f "$target_file"
            return 0
        fi
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        mv "$target_file" "${target_file}.bak.${TIMESTAMP}"
        print_status "Backed up existing $(basename "$target_file") to $(basename "$target_file").bak.${TIMESTAMP}"
    fi
    return 0
}
