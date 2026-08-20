print_offline_instructions() {
    print_banner "OFFLINE MODE INSTRUCTIONS" "$YELLOW"
    echo -e "${WHITE}GitHub is unreachable and no local cache was found.${NC}"
    echo -e "${WHITE}Manually extract release .zips into these folders:${NC}\n"
    echo -e "${CYAN}1. kcat Official DSOAL:${NC} ${GREEN}$DSOAL_OFFICIAL${NC}"
    echo -e "${CYAN}2. kcat OpenAL Soft:${NC}   ${GREEN}$OPENAL_OFFICIAL${NC}"
    echo -e "${CYAN}3. ThreeDeeJay DSOAL:${NC}  ${GREEN}$DSOAL_COMMUNITY_V13${NC}"
    echo -e "${CYAN}4. PCGamingWiki DSOAL (self-hosted mirror):${NC} ${GREEN}$DSOAL_COMMUNITY_V14${NC}\n"
}

verify_checksum() {
    # Usage: verify_checksum <downloaded_file> <expected_sha256>
    # Verifies a downloaded file against a checksum. If sha256sum isn't
    # available, this skips verification with a warning rather than blocking
    # the install over a missing local tool. A mismatch against a known-good
    # hash, however, is treated as a hard failure.
    local file="$1"
    local expected="$2"

    if ! command -v sha256sum &> /dev/null; then
        print_note_arrow "sha256sum not available, skipping checksum verification."
        return 0
    fi

    local actual
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        print_error_arrow "checksum mismatch — expected $expected, got $actual."
        return 1
    fi

    print_status "Checksum verified." "$GREEN"
    return 0
}

get_asset_digest() {
    # Usage: get_asset_digest <release_json> <asset_filename>
    # GitHub publishes an automatic SHA256 "digest" for every release asset
    # (https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/).
    # This pulls that digest for a named asset out of a Releases API response,
    # so a rolling/unpinned tag like kcat's "latest-master" can still be
    # verified against whatever GitHub says was actually uploaded. Requires
    # jq for reliable JSON parsing; prints nothing if jq is missing or the
    # asset/digest can't be found — callers should treat empty as "skip".
    local release_json="$1"
    local asset_name="$2"

    command -v jq &> /dev/null || return 0

    echo "$release_json" | jq -r --arg name "$asset_name" \
        '(.assets // [])[] | select(.name == $name) | .digest // empty' 2>/dev/null \
        | sed -n 's/^sha256://p'
}

confirm_unverified_download() {
    # Usage: confirm_unverified_download <label>
    # Called when a kcat "official" download couldn't be checksum-verified
    # (missing jq, or GitHub hasn't published a digest for it yet). Rather
    # than silently proceeding, this hands the decision to the user — noting
    # that the file comes straight from kcat's official GitHub repo, which
    # is reassuring but not a substitute for an actual checksum match.
    # Returns 0 to proceed, 1 to decline.
    local label="$1"

    echo -e " -> ${NOTE}Note: could not obtain a checksum for $label (requires 'jq', or GitHub hasn't published one yet).${NC}"
    echo -e "    ${WHITE}This file is downloaded directly from kcat's official GitHub repository, so it should"
    echo -e "    be safe — but without a checksum, the script can't independently confirm that.${NC}"
    echo -e "\n    ${YELLOW}Install it anyway? (Y/n): ${NC}"
    echo -n "    > "
    read -r CONFIRM_UNVERIFIED
    echo ""
    [[ ! "$CONFIRM_UNVERIFIED" =~ $NO_RE ]]
}

verify_or_confirm() {
    # Usage: verify_or_confirm <file> <expected_sha256_or_empty> <label>
    # Single gate for a downloaded kcat asset: verifies against a digest when
    # one was found, otherwise defers to confirm_unverified_download. Returns
    # 0 to proceed with installing the file, 1 to abort this download.
    local file="$1"
    local digest="$2"
    local label="$3"

    if [ -n "$digest" ]; then
        verify_checksum "$file" "$digest"
        return $?
    fi

    confirm_unverified_download "$label"
}
