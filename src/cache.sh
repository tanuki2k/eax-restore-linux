# ==============================================================================
# BUILD DOWNLOADS (DSOAL and OpenAL Soft, stable or latest)
# ==============================================================================
# Nothing is downloaded up front. check_download_readiness runs at the start of
# the install and only works out whether GitHub can be reached; step 6 (Audio
# Engine Selection) asks which builds to use (choose_builds) and then fetches
# just those (ensure_dsoal_build / ensure_openal_build), into the script's own
# cache — never the game or prefix.
#
#   DSOAL stable  = the pinned, tested archive revision ($DSOAL_PINNED_REV).
#                   Advance it after testing a newer build.
#   DSOAL latest  = kcat's latest-master, or the newest archive build while
#                   latest-master is missing upstream.
#   OpenAL stable = the newest tagged OpenAL Soft release.
#   OpenAL latest = OpenAL Soft's rolling "latest" pre-release (master).

# Usage: build_cached <dir>
build_cached() { [ -d "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; }

# Usage: check_download_readiness
# Start of the install: can GitHub be reached? Sets GITHUB_REACHABLE (1/0).
# Offline with no OpenAL Soft at all there's nothing any engine could deploy,
# so this stops now, before any questions, with the manual-install folders.
# EAX_RESTORE_SKIP_CACHE_CHECK skips the probe and uses only cached builds.
check_download_readiness() {
    # Once per run: going back to the main menu runs Phase 1's start again.
    [ -n "${DOWNLOAD_READINESS_CHECKED:-}" ] && return 0
    DOWNLOAD_READINESS_CHECKED=1
    mkdir -p "$DSOAL_SHARE" "$OPENAL_SHARE"
    GITHUB_REACHABLE=0
    if is_truthy "${EAX_RESTORE_SKIP_CACHE_CHECK:-}"; then
        print_note "EAX_RESTORE_SKIP_CACHE_CHECK is set, so only DSOAL/OpenAL Soft builds already" \
            "downloaded will be used — nothing is checked or fetched."
    elif curl -s -o /dev/null -m 10 "$GITHUB_PROBE_URL"; then
        GITHUB_REACHABLE=1
        return 0
    else
        print_note "GitHub can't be reached, so only the builds already downloaded can be used this run."
    fi
    if ! build_cached "$OPENAL_OFFICIAL" && ! build_cached "$OPENAL_PRERELEASE"; then
        print_error "No OpenAL Soft build has been downloaded yet, so there's nothing to install."
        print_offline_instructions
        exit 1
    fi
}

# Usage: lookup_build_versions
# Fills the version labels step 6 shows for each build, without downloading
# anything: online from the release pages, offline from what's cached. A label
# is empty when the build can't be had this run (offline and not cached).
lookup_build_versions() {
    local json marker
    DSOAL_STABLE_LABEL=""; DSOAL_LATEST_LABEL=""; OAL_STABLE_LABEL=""; OAL_LATEST_LABEL=""

    if [ "$GITHUB_REACHABLE" -eq 1 ] || build_cached "$DSOAL_PINNED"; then
        DSOAL_STABLE_LABEL="$DSOAL_PINNED_REV"
    fi

    if [ "$GITHUB_REACHABLE" -eq 1 ]; then
        DSOAL_OFFICIAL_JSON=$(curl -s "$DSOAL_OFFICIAL_API_URL")
        DSOAL_LATEST_DATE=$(printf '%s' "$DSOAL_OFFICIAL_JSON" | jq -r '.updated_at // empty' 2>/dev/null)
        if [ -n "$DSOAL_LATEST_DATE" ]; then
            DSOAL_LATEST_LABEL=$(printf '%s' "$DSOAL_OFFICIAL_JSON" | jq -r '.name // empty' | grep -o 'r[0-9]\+' | head -n 1)
            [ -n "$DSOAL_LATEST_LABEL" ] || DSOAL_LATEST_LABEL="${DSOAL_LATEST_DATE%%T*}"
        elif newest_archive_dsoal; then
            DSOAL_LATEST_LABEL="$ARCHIVE_REV"
        fi
    fi
    if [ -z "$DSOAL_LATEST_LABEL" ] && build_cached "$DSOAL_OFFICIAL"; then
        marker=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
        DSOAL_LATEST_LABEL="${marker#archive-}"; DSOAL_LATEST_LABEL="${DSOAL_LATEST_LABEL%%T*}"
        [ -n "$DSOAL_LATEST_LABEL" ] || DSOAL_LATEST_LABEL="cached"
    fi

    if [ "$GITHUB_REACHABLE" -eq 1 ]; then
        # The /releases/latest redirect names the newest tagged release
        # without spending an API call.
        OAL_STABLE_TAG=$(curl -sI "$OPENAL_LATEST_RELEASE_URL" | grep -i "^location:" | awk -F '/' '{print $NF}' | tr -d '\r')
        OAL_STABLE_LABEL="$OAL_STABLE_TAG"
        OAL_PRERELEASE_JSON=$(curl -s "$OPENAL_PRERELEASE_API_URL")
        OAL_LATEST_LABEL=$(printf '%s' "$OAL_PRERELEASE_JSON" | jq -r '
            (.name // "" | sub("^OpenAL Soft v"; "")) as $v
            | ((.assets // [])[] | select(.name == "OpenALSoft.zip") | .updated_at[0:10]) as $d
            | if $v != "" then "\($v) (\($d))" else empty end' 2>/dev/null | head -n 1)
    fi
    if [ -z "$OAL_STABLE_LABEL" ] && build_cached "$OPENAL_OFFICIAL"; then
        OAL_STABLE_LABEL=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null); OAL_STABLE_LABEL="${OAL_STABLE_LABEL:-cached}"
    fi
    if [ -z "$OAL_LATEST_LABEL" ] && build_cached "$OPENAL_PRERELEASE"; then
        OAL_LATEST_LABEL=$(sed -n 2p "$OPENAL_PRERELEASE/.version" 2>/dev/null); OAL_LATEST_LABEL="${OAL_LATEST_LABEL:-cached}"
    fi
}

# Usage: install_dsoal_zip_into_official <zip> <cache marker>
# Unpacks a downloaded kcat DSOAL zip into $DSOAL_OFFICIAL (replacing what was
# there), records the marker in updated_at.txt and deletes the zip.
install_dsoal_zip_into_official() {
    unpack_dsoal_zip "$1" "$DSOAL_OFFICIAL"
    echo "$2" > "$DSOAL_SHARE/updated_at.txt"
}

# Usage: unpack_dsoal_zip <zip> <dir>
# kcat's zips sometimes wrap their real contents in a further nested
# DSOAL_*.zip, so a second extraction pass is needed to reach the DLLs.
unpack_dsoal_zip() {
    local zip="$1" dir="$2" nested
    rm -rf "$dir"; mkdir -p "$dir"
    unzip -q "$zip" -d "$dir"
    nested=$(find "$dir" -maxdepth 1 -name "DSOAL_*.zip" | head -n 1)
    if [ -n "$nested" ] && unzip -tq "$nested" &>/dev/null; then unzip -q "$nested" -d "$dir"; fi
    rm -f "$zip"
}

# Usage: newest_archive_dsoal
# Looks up the newest DSOAL_r<N>.zip in kcat's "archive" release. Sets
# ARCHIVE_REV (e.g. r695), ARCHIVE_URL and ARCHIVE_DIGEST (GitHub's SHA256 for
# the asset, empty if it has none). Returns 1 if the release can't be read or
# has no DSOAL build.
newest_archive_dsoal() {
    local json line
    ARCHIVE_REV=""; ARCHIVE_URL=""; ARCHIVE_DIGEST=""
    json=$(curl -s "$DSOAL_ARCHIVE_API_URL") || return 1
    line=$(printf '%s' "$json" | jq -r '
        [(.assets // [])[] | select(.name | test("^DSOAL_r[0-9]+\\.zip$"))
         | {rev: (.name | capture("^DSOAL_r(?<n>[0-9]+)").n | tonumber),
            url: .browser_download_url, digest: (.digest // "" | sub("^sha256:"; ""))}]
        | sort_by(.rev) | last // empty
        | "r\(.rev)\t\(.url)\t\(.digest)"' 2>/dev/null)
    [ -n "$line" ] || return 1
    IFS=$'\t' read -r ARCHIVE_REV ARCHIVE_URL ARCHIVE_DIGEST <<< "$line"
    [ -n "$ARCHIVE_REV" ] && [ -n "$ARCHIVE_URL" ]
}

# Usage: ensure_dsoal_build <stable|latest>
# Makes sure the chosen DSOAL build is in the cache, downloading it if it's
# missing or out of date. Returns 1 if it can't be had this run.
ensure_dsoal_build() {
    local local_date
    if [ "$1" == "stable" ]; then
        if build_cached "$DSOAL_PINNED"; then
            print_status "DSOAL stable [$DSOAL_PINNED_REV]: up to date" "$GREEN"; return 0
        fi
        [ "$GITHUB_REACHABLE" -eq 1 ] || return 1
        print_status "DSOAL stable [$DSOAL_PINNED_REV]: downloading..."
        if fetch_with_progress "$DSOAL_PINNED_URL" "$DSOAL_SHARE/pinned.zip" && unzip -tq "$DSOAL_SHARE/pinned.zip" &>/dev/null; then
            # Hard-fails on mismatch: a frozen, already-superseded archive
            # asset has a stable SHA256, so a mismatch means the file is wrong.
            if verify_checksum "$DSOAL_SHARE/pinned.zip" "$DSOAL_PINNED_SHA256"; then
                unpack_dsoal_zip "$DSOAL_SHARE/pinned.zip" "$DSOAL_PINNED"
                print_status "Done." "$GREEN"; return 0
            fi
            print_error_arrow "The stable DSOAL build failed checksum verification."
        else
            print_error_arrow "The stable DSOAL build couldn't be downloaded."
        fi
        rm -f "$DSOAL_SHARE/pinned.zip"; rm -rf "$DSOAL_PINNED"
        return 1
    fi

    local_date=$(cat "$DSOAL_SHARE/updated_at.txt" 2>/dev/null)
    if [ "$GITHUB_REACHABLE" -ne 1 ]; then
        build_cached "$DSOAL_OFFICIAL" || return 1
        print_status "DSOAL latest [$DSOAL_LATEST_LABEL]: using the cached build (offline)" "$YELLOW"; return 0
    fi
    if [ -z "$DSOAL_LATEST_DATE" ]; then
        # latest-master is missing upstream. kcat's nightly CI deletes it
        # before re-creating it, and when that last step fails (as it has
        # every night since 2026-09-23, when a commit title with quote marks
        # broke its release notes — kcat/dsoal#191) only the "archive"
        # release still gets the new build. Follow the newest archived build
        # until latest-master is back: its "archive-r<N>" marker never
        # matches a real latest-master updated_at, so the next run that finds
        # latest-master switches back.
        if [ -z "$ARCHIVE_REV" ] && ! newest_archive_dsoal; then
            build_cached "$DSOAL_OFFICIAL" || return 1
            print_status "DSOAL latest: couldn't check for updates, so using the cached build [${local_date%%T*}]" "$YELLOW"; return 0
        fi
        if [ "$local_date" == "archive-$ARCHIVE_REV" ] && build_cached "$DSOAL_OFFICIAL"; then
            print_status "DSOAL latest [$ARCHIVE_REV]: up to date (latest-master is missing upstream, so this is kcat's newest archived build)" "$GREEN"; return 0
        fi
        print_status "DSOAL latest [$ARCHIVE_REV]: downloading kcat's newest archived build (latest-master is missing upstream)..."
        if fetch_with_progress "$ARCHIVE_URL" "$DSOAL_SHARE/dsoal.zip" && unzip -tq "$DSOAL_SHARE/dsoal.zip" &>/dev/null \
            && verify_or_confirm "$DSOAL_SHARE/dsoal.zip" "$ARCHIVE_DIGEST" "kcat archived DSOAL [$ARCHIVE_REV]"; then
            install_dsoal_zip_into_official "$DSOAL_SHARE/dsoal.zip" "archive-$ARCHIVE_REV"
            print_status "Done." "$GREEN"; return 0
        fi
    else
        if [ "$DSOAL_LATEST_DATE" == "$local_date" ] && build_cached "$DSOAL_OFFICIAL"; then
            print_status "DSOAL latest [$DSOAL_LATEST_LABEL]: up to date" "$GREEN"; return 0
        fi
        print_status "DSOAL latest [$DSOAL_LATEST_LABEL]: downloading..."
        if fetch_with_progress "$DSOAL_OFFICIAL_URL" "$DSOAL_SHARE/dsoal.zip" && unzip -tq "$DSOAL_SHARE/dsoal.zip" &>/dev/null \
            && verify_or_confirm "$DSOAL_SHARE/dsoal.zip" "$(get_asset_digest "$DSOAL_OFFICIAL_JSON" "DSOAL.zip")" "kcat DSOAL [$DSOAL_LATEST_LABEL]"; then
            install_dsoal_zip_into_official "$DSOAL_SHARE/dsoal.zip" "$DSOAL_LATEST_DATE"
            print_status "Done." "$GREEN"; return 0
        fi
    fi
    rm -f "$DSOAL_SHARE/dsoal.zip"
    if build_cached "$DSOAL_OFFICIAL"; then
        print_warning_arrow "Couldn't get the new build, so keeping the cached one [${local_date#archive-}]."
        return 0
    fi
    print_error_arrow "The latest DSOAL build couldn't be downloaded."
    return 1
}

# Usage: ensure_openal_build <stable|latest>
# Same as ensure_dsoal_build, for OpenAL Soft. The two builds are laid out
# differently: stable is openal-soft-<v>-bin/bin/<Arch>/soft_oal.dll, the
# pre-release is <Arch>/OpenAL32.dll (see openal_source_dll).
ensure_openal_build() {
    local local_tag asset url digest updated version
    if [ "$1" == "stable" ]; then
        local_tag=$(cat "$OPENAL_SHARE/updated_at.txt" 2>/dev/null)
        if [ "$GITHUB_REACHABLE" -ne 1 ] || [ -z "${OAL_STABLE_TAG:-}" ]; then
            build_cached "$OPENAL_OFFICIAL" || return 1
            print_status "OpenAL Soft stable [$local_tag]: using the cached build" "$YELLOW"; return 0
        fi
        if [ "$OAL_STABLE_TAG" == "$local_tag" ] && build_cached "$OPENAL_OFFICIAL"; then
            print_status "OpenAL Soft stable [$local_tag]: up to date" "$GREEN"; return 0
        fi
        print_status "OpenAL Soft stable [$OAL_STABLE_TAG]: downloading..."
        asset="openal-soft-${OAL_STABLE_TAG}-bin.zip"
        url="https://github.com/kcat/openal-soft/releases/download/${OAL_STABLE_TAG}/${asset}"
        if fetch_with_progress "$url" "$OPENAL_SHARE/openal.zip" && unzip -tq "$OPENAL_SHARE/openal.zip" &>/dev/null; then
            digest=$(get_asset_digest "$(curl -s "https://api.github.com/repos/kcat/openal-soft/releases/tags/${OAL_STABLE_TAG}")" "$asset")
            if verify_or_confirm "$OPENAL_SHARE/openal.zip" "$digest" "kcat OpenAL Soft [$OAL_STABLE_TAG]"; then
                rm -rf "$OPENAL_OFFICIAL"; mkdir -p "$OPENAL_OFFICIAL"
                unzip -q "$OPENAL_SHARE/openal.zip" -d "$OPENAL_OFFICIAL"
                echo "$OAL_STABLE_TAG" > "$OPENAL_SHARE/updated_at.txt"; rm -f "$OPENAL_SHARE/openal.zip"
                print_status "Done." "$GREEN"; return 0
            fi
        fi
        rm -f "$OPENAL_SHARE/openal.zip"
        if build_cached "$OPENAL_OFFICIAL"; then
            print_warning_arrow "Couldn't get the new build, so keeping the cached one [$local_tag]."
            return 0
        fi
        print_error_arrow "The stable OpenAL Soft build couldn't be downloaded."
        return 1
    fi

    # Pre-release: the marker is the asset's upload time (it's rebuilt in
    # place, so the tag never changes) plus the version to show.
    local_tag=$(sed -n 1p "$OPENAL_PRERELEASE/.version" 2>/dev/null)
    if [ "$GITHUB_REACHABLE" -ne 1 ] || [ -z "${OAL_PRERELEASE_JSON:-}" ]; then
        build_cached "$OPENAL_PRERELEASE" || return 1
        print_status "OpenAL Soft latest [$OAL_LATEST_LABEL]: using the cached build" "$YELLOW"; return 0
    fi
    IFS=$'\t' read -r url digest updated version < <(printf '%s' "$OAL_PRERELEASE_JSON" | jq -r '
        (.name // "" | sub("^OpenAL Soft v"; "")) as $v
        | (.assets // [])[] | select(.name == "OpenALSoft.zip")
        | "\(.browser_download_url)\t\(.digest // "" | sub("^sha256:"; ""))\t\(.updated_at)\t\($v)"' 2>/dev/null)
    if [ -z "$url" ]; then
        build_cached "$OPENAL_PRERELEASE" || { print_error_arrow "OpenAL Soft's pre-release build isn't available right now."; return 1; }
        print_status "OpenAL Soft latest: couldn't check for updates, so using the cached build" "$YELLOW"; return 0
    fi
    if [ "$updated" == "$local_tag" ] && build_cached "$OPENAL_PRERELEASE"; then
        print_status "OpenAL Soft latest [$OAL_LATEST_LABEL]: up to date" "$GREEN"; return 0
    fi
    print_status "OpenAL Soft latest [$OAL_LATEST_LABEL]: downloading..."
    if fetch_with_progress "$url" "$OPENAL_SHARE/prerelease.zip" && unzip -tq "$OPENAL_SHARE/prerelease.zip" &>/dev/null \
        && verify_or_confirm "$OPENAL_SHARE/prerelease.zip" "$digest" "kcat OpenAL Soft pre-release [$version]"; then
        rm -rf "$OPENAL_PRERELEASE"; mkdir -p "$OPENAL_PRERELEASE"
        unzip -q "$OPENAL_SHARE/prerelease.zip" -d "$OPENAL_PRERELEASE"
        printf '%s\n%s\n' "$updated" "$OAL_LATEST_LABEL" > "$OPENAL_PRERELEASE/.version"
        rm -f "$OPENAL_SHARE/prerelease.zip"
        print_status "Done." "$GREEN"; return 0
    fi
    rm -f "$OPENAL_SHARE/prerelease.zip"
    if build_cached "$OPENAL_PRERELEASE"; then
        print_warning_arrow "Couldn't get the new build, so keeping the cached one."
        return 0
    fi
    print_error_arrow "OpenAL Soft's pre-release build couldn't be downloaded."
    return 1
}

# Usage: dsoal_source_dir / openal_source_dll
# Where Phase 2 copies the chosen builds from, for the architecture picked.
dsoal_source_dir() {
    local root="$DSOAL_OFFICIAL"
    local dir
    [ "$DSOAL_BUILD" == "stable" ] && root="$DSOAL_PINNED"
    # The zip has DSOAL/<Arch> and DSOAL+HRTF/<Arch>; prefer the plain one.
    dir=$(find "$root" -type d -ipath "*/DSOAL/${ARCH_FOLDER}" | head -n 1)
    [ -n "$dir" ] || dir=$(find "$root" -type d -ipath "*/${ARCH_FOLDER}" | head -n 1)
    echo "$dir"
}
openal_source_dll() {
    if [ "$OAL_BUILD" == "latest" ]; then
        echo "$OPENAL_PRERELEASE/$ARCH_FOLDER/OpenAL32.dll"
    else
        echo "$(find "$OPENAL_OFFICIAL" -type d -ipath "*/bin/${ARCH_FOLDER}" | head -n 1)/soft_oal.dll"
    fi
}

# Usage: choose_builds
# Step 6, once the engine is settled: asks which builds to deploy — both
# stable, both latest, or each chosen separately — then downloads just those.
# Sets DSOAL_BUILD / OAL_BUILD (stable|latest) and DSOAL_SELECTED_LABEL /
# OAL_SELECTED_LABEL. An option that can't be had this run (offline and never
# downloaded) is shown as "[not downloaded]" and refused.
choose_builds() {
    local needs_dsoal=0 answer
    [ "$ENGINE_CHOICE" == "1" ] && needs_dsoal=1
    print_task "Checking which DSOAL and OpenAL Soft builds are available"
    lookup_build_versions

    _label() { if [ -n "$1" ]; then printf '%s' "$1"; else printf '%s' "${YELLOW}[not downloaded]${NC}"; fi; }

    # Usage: _ask_component <name> <stable label> <latest label> <latest note>
    # One component's Stable/Latest question; sets ASKED_BUILD. (Not run in a
    # $(...) capture: read_answer writes the answer to stdout for the run log.)
    _ask_component() {
        local name="$1" st="$2" lt="$3" note="$4" a
        echo -e "\n${WHITE}${name}${NC}\n"
        print_key_option "[S]table  $(_label "$st")"
        print_key_option "[L]atest  $(_label "$lt")${note}"
        while true; do
            prompt "Selection [s/l, Default: s]: "
            read_answer a || exit 0
            a="${a,,}"; a="${a:-s}"
            case "$a" in
                s) [ -n "$st" ] && { ASKED_BUILD="stable"; return; } ;;
                l) [ -n "$lt" ] && { ASKED_BUILD="latest"; return; } ;;
                *) print_result "That's not a valid option — please type s or l." "$YELLOW"; continue ;;
            esac
            print_result "That build hasn't been downloaded and GitHub can't be reached, so it can't be used this run." "$YELLOW"
        done
    }

    local pre=" (pre-release)"
    if [ "$needs_dsoal" -eq 1 ] && is_truthy "$EAX_RESTORE_DSOAL_PIN"; then
        DSOAL_BUILD="stable"
        print_status "EAX_RESTORE_DSOAL_PIN is set, so DSOAL uses the stable build [$DSOAL_PINNED_REV]." "$GREEN"
        _ask_component "Which OpenAL Soft build?" "$OAL_STABLE_LABEL" "$OAL_LATEST_LABEL" "$pre"; OAL_BUILD="$ASKED_BUILD"
    elif [ "$needs_dsoal" -eq 0 ]; then
        _ask_component "Which OpenAL Soft build?" "$OAL_STABLE_LABEL" "$OAL_LATEST_LABEL" "$pre"; OAL_BUILD="$ASKED_BUILD"
    else
        local stable_ok=0 latest_ok=0
        [ -n "$DSOAL_STABLE_LABEL" ] && [ -n "$OAL_STABLE_LABEL" ] && stable_ok=1
        [ -n "$DSOAL_LATEST_LABEL" ] && [ -n "$OAL_LATEST_LABEL" ] && latest_ok=1
        echo -e "\n${WHITE}Which builds?${NC}\n"
        print_key_option "[S]table  DSOAL $(_label "$DSOAL_STABLE_LABEL") + OpenAL Soft $(_label "$OAL_STABLE_LABEL")"
        print_key_option "[L]atest  DSOAL $(_label "$DSOAL_LATEST_LABEL") + OpenAL Soft $(_label "$OAL_LATEST_LABEL")${pre}"
        print_key_option "[C]hoose each separately"
        while true; do
            prompt "Selection [s/l/c, Default: s]: "
            read_answer answer || exit 0
            answer="${answer,,}"; answer="${answer:-s}"
            case "$answer" in
                s) if [ "$stable_ok" -eq 1 ]; then DSOAL_BUILD="stable"; OAL_BUILD="stable"; break; fi ;;
                l) if [ "$latest_ok" -eq 1 ]; then DSOAL_BUILD="latest"; OAL_BUILD="latest"; break; fi ;;
                c)
                    _ask_component "Which DSOAL build?" "$DSOAL_STABLE_LABEL" "$DSOAL_LATEST_LABEL" ""; DSOAL_BUILD="$ASKED_BUILD"
                    _ask_component "Which OpenAL Soft build?" "$OAL_STABLE_LABEL" "$OAL_LATEST_LABEL" "$pre"; OAL_BUILD="$ASKED_BUILD"
                    break ;;
                *) print_result "That's not a valid option — please type s, l or c." "$YELLOW"; continue ;;
            esac
            print_result "Part of that pair hasn't been downloaded and GitHub can't be reached — try [C] to pick what's available." "$YELLOW"
        done
    fi

    print_task "Getting the chosen builds"
    if [ "$needs_dsoal" -eq 1 ]; then
        _ensure_or_switch dsoal || {
            print_error "kcat DSOAL couldn't be downloaded this run, and this game needs it."
            echo -e "${WHITE}Check your connection, then run the script again later.${NC}"
            exit 1
        }
    fi
    _ensure_or_switch openal || {
        print_error "OpenAL Soft couldn't be downloaded this run, and every engine needs it."
        echo -e "${WHITE}Check your connection, then run the script again later.${NC}"
        exit 1
    }
    DSOAL_SELECTED_LABEL="$DSOAL_STABLE_LABEL"; [ "$DSOAL_BUILD" == "latest" ] && DSOAL_SELECTED_LABEL="$DSOAL_LATEST_LABEL"
    OAL_SELECTED_LABEL="$OAL_STABLE_LABEL"; [ "$OAL_BUILD" == "latest" ] && OAL_SELECTED_LABEL="$OAL_LATEST_LABEL"
    unset -f _label _ask_component
}

# Usage: _ensure_or_switch <dsoal|openal>
# Gets the chosen build of one component; if that fails, offers the other
# build of it when that one can be had. Returns 1 when neither works.
_ensure_or_switch() {
    local var other label name fn
    if [ "$1" == "dsoal" ]; then var="DSOAL_BUILD"; name="DSOAL"; fn="ensure_dsoal_build"
    else var="OAL_BUILD"; name="OpenAL Soft"; fn="ensure_openal_build"; fi
    "$fn" "${!var}" && return 0
    other="latest"; [ "${!var}" == "latest" ] && other="stable"
    if [ "$1" == "dsoal" ]; then
        label="$DSOAL_STABLE_LABEL"; [ "$other" == "latest" ] && label="$DSOAL_LATEST_LABEL"
    else
        label="$OAL_STABLE_LABEL"; [ "$other" == "latest" ] && label="$OAL_LATEST_LABEL"
    fi
    [ -n "$label" ] || return 1
    confirm "Use the ${other} ${name} build [${label}] instead?" Y || return 1
    printf -v "$var" '%s' "$other"
    "$fn" "$other"
}

find_existing_variant() {
    # Usage: find_existing_variant <path>
    # Prints the path if it exists, otherwise any same-named file in that
    # folder that differs only by case (e.g. DSOUND.DLL for dsound.dll).
    # Linux filesystems -- NTFS via ntfs3/ntfs-3g included -- are
    # case-sensitive, so an exact-name check alone would drop a second
    # dsound.dll next to a game's own DSOUND.DLL rather than backing it up,
    # leaving Wine to pick either and Windows (on a shared NTFS drive) with
    # two names it can't tell apart.
    local f="$1"
    if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; return; fi
    find "$(dirname "$f")" -maxdepth 1 -iname "$(basename "$f")" 2>/dev/null | head -n 1
}

target_fs_type() {
    # Usage: target_fs_type <dir>  -> e.g. ext4, btrfs, ntfs3, ntfs (ntfs-3g)
    local dir="$1" fs src
    fs=$(findmnt -no FSTYPE -T "$dir" 2>/dev/null)
    # ntfs-3g (and exFAT via FUSE) mounts show up as plain "fuseblk", so ask
    # the block device what it actually is.
    if [ "$fs" == "fuseblk" ]; then
        src=$(findmnt -no SOURCE -T "$dir" 2>/dev/null)
        [ -n "$src" ] && fs=$(lsblk -no FSTYPE "$src" 2>/dev/null | head -n 1)
        [ -z "$fs" ] && fs="fuseblk"
    fi
    echo "$fs"
}

check_target_writable() {
    # Usage: check_target_writable <dir> <label>
    # Confirms the script can actually write to <dir> before anything is
    # changed, and explains why not when it can't -- most often an NTFS drive
    # that Linux mounted read-only because Windows Fast Startup/hibernation
    # left it "dirty". Exits on failure; returns 0 when writable.
    local dir="$1" label="$2" probe fs opts
    probe="$dir/.eax-restore-write-test.$$"
    fs=$(target_fs_type "$dir")
    if touch "$probe" 2>/dev/null && rm -f "$probe" 2>/dev/null; then
        if [[ "$fs" == ntfs* ]] && [ "$SCRIPT_ACTION" == "i" ] && [ -z "$NTFS_NOTE_SHOWN" ]; then
            NTFS_NOTE_SHOWN=1
            print_note "this $label is on an NTFS drive ($fs)." \
                "NTFS isn't a good fit for Linux gaming. Install the game to a Linux filesystem" \
                "(e.g. ext4 or btrfs). It's highly recommended to avoid NTFS for Wine/Proton" \
                "prefixes."
        fi
        return 0
    fi
    opts=$(findmnt -no OPTIONS -T "$dir" 2>/dev/null)
    print_error "The $label can't be written to:" \
        "${WHITE}  $dir" \
        "  Filesystem: ${fs:-unknown}   Mount options: ${opts:-unknown}"
    if [[ "$fs" == ntfs* ]] && [[ ",$opts," == *,ro,* ]]; then
        print_paragraph "Windows didn't fully shut down (Fast Startup or hibernation), so Linux" \
            "mounted this drive read-only."
    elif [[ "$fs" == ntfs* ]]; then
        print_paragraph "This NTFS drive is mounted without write access for your user."
    elif [[ ",$opts," == *,ro,* ]]; then
        print_paragraph "This drive is mounted read-only. Remount it read-write and re-run."
    else
        print_paragraph "Your user doesn't have write permission here (owner: $(stat -c '%U' "$dir" 2>/dev/null))." \
            "Fix the folder's permissions and re-run. Don't run this script as root."
    fi
    print_paragraph "Nothing has been changed."
    exit 1
}

deploy_copy() {
    # Usage: deploy_copy <src> <dest> <verb>
    # Copies one file and only records it in the manifest (and reports it)
    # if the copy actually succeeded; failures are counted in
    # DEPLOY_FAILURES so the install can't report success when it isn't.
    if cp -f "$1" "$2"; then
        echo "$2" >> "$INSTALL_MANIFEST"
        print_status "$3: $(basename "$2") to $(basename "$(dirname "$2")")"
        return 0
    fi
    record_deploy_failure "$2"
    return 1
}

record_deploy_failure() {
    print_error_arrow "Couldn't write $(basename "$1") to $(dirname "$1"), so it isn't installed."
    DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
}

handle_conflict() {
    local target_file="$1"
    local existing
    existing=$(find_existing_variant "$target_file")
    if [ -n "$existing" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            # Already ours from a previous install (tracked in the prior
            # manifest before it was reset) — not a genuine original, so
            # there's nothing here worth backing up. Overwrite directly;
            # any real original backup from the very first install, if one
            # exists, is left untouched rather than buried under this.
            if rm -f "$existing"; then return 0; fi
            record_deploy_failure "$target_file"
            return 1
        fi
        echo -e "\n${YELLOW}$(basename "$existing")${NC} ${WHITE}already exists at $(tilde_path "$(dirname "$target_file")").${NC}"
        while true; do
            prompt "What would you like to do? [B]ackup & overwrite (default), [o]verwrite, [s]kip: "
            read_answer C_CHOICE
            C_CHOICE="${C_CHOICE:-b}"
            case "${C_CHOICE,,}" in
                o)
                    if rm -rf "$existing"; then return 0; fi
                    record_deploy_failure "$target_file"
                    return 1 ;;
                b)
                    # Named after the target (not a differently-cased
                    # original), so uninstall's "$f".bak* lookup finds it.
                    # A failed backup skips the copy: cp -f onto the file
                    # can still succeed (it needs only file write access,
                    # mv needs the folder's), which would destroy the
                    # original with no backup left.
                    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
                    echo ""
                    if ! mv "$existing" "${target_file}.bak.${TIMESTAMP}"; then
                        print_error_arrow "Couldn't back up $(basename "$existing"), so it was left untouched."
                        DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
                        return 1
                    fi
                    print_status "Backed up original $(basename "$existing") to $(basename "$target_file").bak.${TIMESTAMP}"
                    return 0 ;;
                s) echo ""; print_status "Skipped $(basename "$target_file")."; return 1 ;;
                *) print_result "That's not a valid option — please type b, o, or s." "$YELLOW" ;;
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
    # Returns 1 (and counts a deploy failure) if the existing file couldn't
    # be moved aside, so the caller skips the copy instead of overwriting it.
    local target_file="$1"
    local existing
    existing=$(find_existing_variant "$target_file")
    if [ -n "$existing" ]; then
        if [ "${PREV_MANIFEST_FILES[$target_file]:-0}" == "1" ]; then
            if rm -f "$existing"; then return 0; fi
            record_deploy_failure "$target_file"
            return 1
        fi
        TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
        if ! mv "$existing" "${target_file}.bak.${TIMESTAMP}"; then
            print_error_arrow "Couldn't back up $(basename "$existing"), so it was left untouched."
            DEPLOY_FAILURES=$(( ${DEPLOY_FAILURES:-0} + 1 ))
            return 1
        fi
        print_status "Backed up existing $(basename "$existing") to $(basename "$target_file").bak.${TIMESTAMP}"
    fi
    return 0
}
