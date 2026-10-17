# ==============================================================================
# SELF-UPDATE CHECK
# ==============================================================================
# Once per run, before the main menu: asks GitHub whether a newer build of this
# script exists on the channel this build came from (a stable build follows the
# latest vX.Y release, a -dev build the rolling dev release) and offers to swap
# it in and restart. Every failure is silent — being offline must not add
# output or cost an answer — and the check is skipped when nobody is there to
# answer (no terminal, or an answers file as the profiler's captures use).
SELF_UPDATE_REPO="tanuki2k/eax-restore-linux"
SELF_UPDATE_ATTEMPTED=""

# Usage: version_is_newer <candidate> <current>
# True when candidate is a higher version than current (0.28.6 < 0.29 < 0.30).
version_is_newer() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]
}

# Usage: script_update_channel
# Prints "dev" for a -dev build, else "stable".
script_update_channel() {
    case "$SCRIPT_VERSION" in *-dev*) echo dev ;; *) echo stable ;; esac
}

# Usage: script_update_available
# Succeeds when a newer build exists on this build's channel, setting
# SELF_UPDATE_VERSION (shown to the player) and SELF_UPDATE_URL (the script's
# download; its checksum is the same URL plus .sha256).
script_update_available() {
    local tag latest sha
    SELF_UPDATE_VERSION=""
    if [ "$(script_update_channel)" == "dev" ]; then
        # The build's own commit, from "<date> build g<sha>"; a dirty or
        # git-less build has nothing to compare.
        [[ "$SCRIPT_DATE" =~ build\ g([0-9a-f]+)$ ]] || return 1
        sha="${BASH_REMATCH[1]}"
        # "ahead" means dev has commits this build lacks; a commit GitHub
        # doesn't know (an unpushed local build) answers 404 and stays quiet.
        curl -fsS --max-time 5 -H "Accept: application/vnd.github+json" \
            "https://api.github.com/repos/$SELF_UPDATE_REPO/compare/$sha...dev" 2>/dev/null \
            | grep -q '"status": *"ahead"' || return 1
        SELF_UPDATE_VERSION="the newest dev build"
        SELF_UPDATE_URL="https://github.com/$SELF_UPDATE_REPO/releases/download/dev/eax-restore-linux.sh"
        return 0
    fi
    tag="$(curl -sIL -o /dev/null --max-time 5 -w '%{url_effective}' \
        "https://github.com/$SELF_UPDATE_REPO/releases/latest" 2>/dev/null)"
    tag="${tag##*/}"
    [[ "$tag" =~ ^v[0-9][0-9.]*$ ]] || return 1
    latest="${tag#v}"
    version_is_newer "$latest" "$SCRIPT_VERSION" || return 1
    SELF_UPDATE_VERSION="v$latest"
    SELF_UPDATE_URL="https://github.com/$SELF_UPDATE_REPO/releases/latest/download/eax-restore-linux.sh"
}

# Usage: install_script_update <url> <target>
# Downloads next to the target, checks it against the release's .sha256 and
# bash -n, then swaps it in (same folder, so the mv is atomic). Returns 1 and
# leaves the target alone on any failure.
install_script_update() {
    local url="$1" target="$2" tmp expected
    tmp="$(mktemp "$(dirname "$target")/.eax-restore-update.XXXXXX" 2>/dev/null)" || return 1
    expected="$(curl -fsSL --max-time 15 "$url.sha256" 2>/dev/null | awk '{ print $1; exit }')"
    if [ -z "$expected" ] || ! fetch_with_progress "$url" "$tmp" \
        || ! verify_checksum "$tmp" "$expected" || ! bash -n "$tmp" 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    chmod --reference="$target" "$tmp" 2>/dev/null
    mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

check_for_script_update() {
    [ -z "$SELF_UPDATE_ATTEMPTED" ] || return 0
    SELF_UPDATE_ATTEMPTED=1
    is_truthy "${EAX_RESTORE_SKIP_UPDATE_CHECK:-}" && return 0
    [ -z "${EAX_RESTORE_ANSWERS_FILE:-}" ] && interactive_tty || return 0
    command -v curl &> /dev/null || return 0
    script_update_available || return 0

    local release_page="https://github.com/$SELF_UPDATE_REPO/releases"
    if [ "$(script_update_channel)" == "dev" ]; then
        print_note "There's a newer dev build of this script than the one you're running (v${SCRIPT_VERSION})."
    else
        print_note "A newer version of this script is out: $SELF_UPDATE_VERSION (you're running v${SCRIPT_VERSION})."
    fi
    confirm "Download $SELF_UPDATE_VERSION and restart with it?" || return 0

    if [ ! -f "$0" ] || [ ! -w "$0" ] || [ ! -w "$(dirname "$0")" ]; then
        print_warning "This copy of the script can't update itself, so please download ${SELF_UPDATE_VERSION} yourself:"
        print_link "Releases" "$release_page"
        return 0
    fi
    if install_script_update "$SELF_UPDATE_URL" "$0"; then
        print_status "Updated to $SELF_UPDATE_VERSION. Restarting..." "$GREEN"
        exec "$0" "${ORIGINAL_ARGS[@]}"
    fi
    print_warning "The update didn't download, so you're staying on v${SCRIPT_VERSION} for now. You can get ${SELF_UPDATE_VERSION} here:"
    print_link "Releases" "$release_page"
}
