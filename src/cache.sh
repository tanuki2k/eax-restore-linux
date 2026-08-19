update_local_cache() {
    echo ""
    print_divider
    echo -e "${GREEN}${BOLD}--- REPOSITORY CACHE CHECK ---${NC}"
    print_line
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"

    echo -e "\n${CYAN}Checking kcat Official DSOAL repository...${NC}"
    DSOAL_OFFICIAL_JSON=$(curl -s "$DSOAL_OFFICIAL_API_URL")
    LATEST_DATE=$(echo "$DSOAL_OFFICIAL_JSON" | grep -m 1 '"updated_at"' | cut -d '"' -f 4)
    LOCAL_DATE=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$LATEST_DATE" ]; then
        if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL")" ]; then echo -e " -> ${NOTE}Note: offline. Using cached version [${LOCAL_DATE%%T*}]${NC}"
        else echo -e " -> ${YELLOW}${BOLD}Error: Offline and no cache found.${NC}"; print_offline_instructions; exit 1; fi
    elif [ "$LATEST_DATE" != "$LOCAL_DATE" ] || [ ! -d "$DSOAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading latest build...${NC}"
        if curl -fL -# "$DSOAL_OFFICIAL_URL" -o "$DSOAL_SHARE/dsoal.zip" && unzip -tq "$DSOAL_SHARE/dsoal.zip" &>/dev/null; then
            DSOAL_OFFICIAL_DIGEST=$(get_asset_digest "$DSOAL_OFFICIAL_JSON" "DSOAL.zip")
            if verify_or_confirm "$DSOAL_SHARE/dsoal.zip" "$DSOAL_OFFICIAL_DIGEST" "kcat Official DSOAL"; then
                rm -rf "$DSOAL_OFFICIAL"; mkdir -p "$DSOAL_OFFICIAL"
                unzip -q "$DSOAL_SHARE/dsoal.zip" -d "$DSOAL_OFFICIAL"
                NESTED=$(find "$DSOAL_OFFICIAL" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
                if [ -n "$NESTED" ] && unzip -tq "$NESTED" &>/dev/null; then unzip -q "$NESTED" -d "$DSOAL_OFFICIAL"; fi
                echo "$LATEST_DATE" > "$DSOAL_SHARE/updated_at.txt"; rm -f "$DSOAL_SHARE/dsoal.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/dsoal.zip"
                if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]; then
                    echo -e " -> ${YELLOW}${BOLD}Skipping this download. Keeping existing cache [${LOCAL_DATE%%T*}].${NC}"
                else
                    echo -e " -> ${YELLOW}${BOLD}Error: Could not verify or confirm this download, and no usable cache exists.${NC}"; print_offline_instructions; exit 1
                fi
            fi
        else
            rm -f "$DSOAL_SHARE/dsoal.zip"
            if [ -d "$DSOAL_OFFICIAL" ] && [ "$(ls -A "$DSOAL_OFFICIAL" 2>/dev/null)" ]; then
                echo -e " -> ${YELLOW}${BOLD}Download failed or file was corrupt. Keeping existing cache [${LOCAL_DATE%%T*}].${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Error: Download failed and no usable cache exists.${NC}"; print_offline_instructions; exit 1
            fi
        fi
    else echo -e " -> ${GREEN}Up to date [${LOCAL_DATE%%T*}]${NC}"; fi

    echo -e "\n${CYAN}Checking kcat OpenAL Soft repository...${NC}"
    OAL_TAG=$(curl -sI https://github.com/kcat/openal-soft/releases/latest | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
    LOCAL_OAL_TAG=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ -z "$OAL_TAG" ]; then
        if [ -d "$OPENAL_OFFICIAL" ]; then echo -e " -> ${NOTE}Note: offline. Using cached version [${LOCAL_OAL_TAG}]${NC}"
        else echo -e " -> ${YELLOW}${BOLD}Error: OpenAL cache missing.${NC}"; exit 1; fi
    elif [ "$OAL_TAG" != "$LOCAL_OAL_TAG" ] || [ ! -d "$OPENAL_OFFICIAL" ]; then
        echo -e " -> ${CYAN}Updates found! Downloading OpenAL Soft [${OAL_TAG}]...${NC}"
        OAL_ASSET_NAME="openal-soft-${OAL_TAG}-bin.zip"
        OAL_URL="https://github.com/kcat/openal-soft/releases/download/${OAL_TAG}/${OAL_ASSET_NAME}"
        if curl -fL -# "$OAL_URL" -o "$OPENAL_SHARE/openal.zip" && unzip -tq "$OPENAL_SHARE/openal.zip" &>/dev/null; then
            OPENAL_OFFICIAL_JSON=$(curl -s "https://api.github.com/repos/kcat/openal-soft/releases/tags/${OAL_TAG}")
            OAL_DIGEST=$(get_asset_digest "$OPENAL_OFFICIAL_JSON" "$OAL_ASSET_NAME")
            if verify_or_confirm "$OPENAL_SHARE/openal.zip" "$OAL_DIGEST" "kcat OpenAL Soft [$OAL_TAG]"; then
                rm -rf "$OPENAL_OFFICIAL"; mkdir -p "$OPENAL_OFFICIAL"
                unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_OFFICIAL"
                echo "$OAL_TAG" > "$OPENAL_SHARE/updated_at.txt"; rm -f "$OPENAL_SHARE/openal.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$OPENAL_SHARE/openal.zip"
                if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                    echo -e " -> ${YELLOW}${BOLD}Skipping this download. Keeping existing cache [${LOCAL_OAL_TAG}].${NC}"
                else
                    echo -e " -> ${YELLOW}${BOLD}Error: Could not verify or confirm this download, and no usable cache exists.${NC}"; exit 1
                fi
            fi
        else
            rm -f "$OPENAL_SHARE/openal.zip"
            if [ -d "$OPENAL_OFFICIAL" ] && [ "$(ls -A "$OPENAL_OFFICIAL" 2>/dev/null)" ]; then
                echo -e " -> ${YELLOW}${BOLD}Download failed or file was corrupt. Keeping existing cache [${LOCAL_OAL_TAG}].${NC}"
            else
                echo -e " -> ${YELLOW}${BOLD}Error: Download failed and no usable cache exists.${NC}"; exit 1
            fi
        fi
    else echo -e " -> ${GREEN}Up to date [${LOCAL_OAL_TAG}]${NC}"; fi

    echo -e "\n${CYAN}Checking ThreeDeeJay Community DSOAL...${NC}"
    if [ ! -d "$DSOAL_COMMUNITY_V13" ]; then
        echo -e " -> ${CYAN}Cache missing. Downloading stable build [v1.31a]...${NC}"
        mkdir -p "$DSOAL_COMMUNITY_V13"
        if curl -fL -# "$DSOAL_COMMUNITY_V13_URL" -o "$DSOAL_SHARE/community.zip" && unzip -tq "$DSOAL_SHARE/community.zip" &>/dev/null; then
            if verify_checksum "$DSOAL_SHARE/community.zip" "$DSOAL_COMMUNITY_V13_SHA256"; then
                unzip -q "$DSOAL_SHARE/community.zip" -d "$DSOAL_COMMUNITY_V13"; rm -f "$DSOAL_SHARE/community.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/community.zip"; rmdir "$DSOAL_COMMUNITY_V13" 2>/dev/null
                echo -e " -> ${YELLOW}${BOLD}Error: downloaded file failed checksum verification. This engine will be unavailable this run.${NC}"
            fi
        else
            rm -f "$DSOAL_SHARE/community.zip"; rmdir "$DSOAL_COMMUNITY_V13" 2>/dev/null
            echo -e " -> ${YELLOW}${BOLD}Error: Download failed or file was corrupt. This engine will be unavailable this run.${NC}"
        fi
    else echo -e " -> ${GREEN}Available in cache.${NC}"; fi

    echo -e "\n${CYAN}Checking PCGamingWiki Community DSOAL (self-hosted mirror)...${NC}"
    if [ ! -d "$DSOAL_COMMUNITY_V14" ]; then
        echo -e " -> ${CYAN}Cache missing. Downloading v1.4 build...${NC}"
        mkdir -p "$DSOAL_COMMUNITY_V14"
        if curl -fL -# "$DSOAL_COMMUNITY_V14_URL" -o "$DSOAL_SHARE/v1.4.zip" && unzip -tq "$DSOAL_SHARE/v1.4.zip" &>/dev/null; then
            if verify_checksum "$DSOAL_SHARE/v1.4.zip" "$DSOAL_COMMUNITY_V14_SHA256"; then
                unzip -q "$DSOAL_SHARE/v1.4.zip" -d "$DSOAL_COMMUNITY_V14"; rm -f "$DSOAL_SHARE/v1.4.zip"; echo -e " -> ${GREEN}Done.${NC}"
            else
                rm -f "$DSOAL_SHARE/v1.4.zip"; rmdir "$DSOAL_COMMUNITY_V14" 2>/dev/null
                echo -e " -> ${YELLOW}${BOLD}Error: downloaded file failed checksum verification. This engine will be unavailable this run.${NC}"
            fi
        else
            rm -f "$DSOAL_SHARE/v1.4.zip"; rmdir "$DSOAL_COMMUNITY_V14" 2>/dev/null
            echo -e " -> ${YELLOW}${BOLD}Error: Download failed or file was corrupt. This engine will be unavailable this run.${NC}"
        fi
    else echo -e " -> ${GREEN}Available in cache.${NC}"; fi

    echo -e "\n${CYAN}Checking known EAX games database...${NC}"
    if ensure_known_games_json; then
        GAME_COUNT=$(jq '.games | length' "$KNOWN_GAMES_FILE" 2>/dev/null)
        echo -e " -> ${GREEN}Loaded (${GAME_COUNT:-0} games).${NC}"
    else
        echo -e " -> ${YELLOW}${BOLD}Error: Download failed or file was corrupt. Game database will be unavailable this run.${NC}"
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
        echo -e "\n${YELLOW}Conflict: $(basename "$target_file")${NC} ${WHITE}already exists at $(dirname "$target_file").${NC}"
        while true; do
            echo -e "\n${YELLOW}Action - [o]verwrite, [B]ackup & overwrite (default), [s]kip: ${NC}"
            echo -e -n "> "
            read -r C_CHOICE
            C_CHOICE="${C_CHOICE:-b}"
            case "${C_CHOICE,,}" in
                o) rm -rf "$target_file"; return 0 ;;
                b)
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    mv "$target_file" "${target_file}.bak.${TIMESTAMP}"
                    echo -e "\n -> Backed up original to $(basename "$target_file").bak.${TIMESTAMP}"
                    return 0 ;;
                s) echo -e "\n -> Skipped $(basename "$target_file")."; return 1 ;;
                *) echo -e "\n${YELLOW}${BOLD}Invalid choice. Type o, b, or s.${NC}" ;;
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
        echo -e " -> Backed up existing $(basename "$target_file") to $(basename "$target_file").bak.${TIMESTAMP}"
    fi
    return 0
}
