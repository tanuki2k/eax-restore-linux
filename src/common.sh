# ==============================================================================
# VISUAL HELPERS
# ==============================================================================
print_divider() { echo -e "${CYAN}----------------------------------------------------------${NC}"; }
print_line() { echo -e "${CYAN}----------------------------------------------------------${NC}"; }
is_truthy() { [[ "${1,,}" =~ ^(1|true|yes|y)$ ]]; }
is_genuine_dll() {
    # Usage: is_genuine_dll <path>
    # Wine creates a "fake DLL" placeholder file with the real DLL's name in
    # system32/syswow64 for every one of its own builtin implementations, by
    # default, in every prefix — purely so apps that check "does this file
    # exist" before running don't refuse to start. These placeholders are
    # real PE files but contain no actual code, and Wine's own source embeds
    # a literal signature string in every one it generates: "Wine builtin
    # DLL" or "Wine placeholder DLL". A plain file-existence or non-empty
    # check can't tell a genuine installed DLL apart from one of these —
    # this checks for that signature so callers can. Returns true (0) only
    # for a file that exists, is non-empty, and does NOT carry that marker.
    local file="$1"
    [ -s "$file" ] || return 1
    grep -qa "Wine builtin DLL\|Wine placeholder DLL" "$file" 2>/dev/null && return 1
    return 0
}
parse_selection() {
    # Usage: parse_selection <total_count> <input_string>
    # Parses pacman-style selection syntax into the global SELECTED[1..N]
    # array (1 = keep/act on, 0 = skip). Empty input selects everything
    # (matches pressing Enter to accept pacman's full list). Plain numbers
    # or ranges ("1 2 3", "1-3") narrow the selection to only those. A "^"
    # prefix ("^4", "^1-3") always excludes — collected and applied in a
    # second pass after all inclusions, specifically so the order tokens
    # appear in doesn't matter ("^2 1-3" and "1-3 ^2" both correctly exclude
    # 2 — an earlier single-pass version let a later plain token's reset
    # silently wipe out an exclusion that appeared before it). Unrecognized
    # tokens are ignored rather than erroring, since this reads user input.
    local total="$1"
    local input="$2"
    local i

    SELECTED=()
    for ((i = 1; i <= total; i++)); do SELECTED[$i]=1; done

    [ -z "$input" ] && return

    input="${input//,/ }"
    local reset_done=0
    local token start end body
    local excludes=()

    for token in $input; do
        if [[ "$token" == ^* ]]; then
            excludes+=("$token")
            continue
        fi
        if [ "$reset_done" -eq 0 ]; then
            for ((i = 1; i <= total; i++)); do SELECTED[$i]=0; done
            reset_done=1
        fi
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            start="$token"; end="$token"
        else
            continue
        fi
        for ((i = start; i <= end && i <= total; i++)); do SELECTED[$i]=1; done
    done

    # Second pass: exclusions always win, applied last regardless of where
    # they appeared in the input.
    for token in "${excludes[@]}"; do
        body="${token#^}"
        if [[ "$body" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
        elif [[ "$body" =~ ^[0-9]+$ ]]; then
            start="$body"; end="$body"
        else
            continue
        fi
        for ((i = start; i <= end && i <= total; i++)); do SELECTED[$i]=0; done
    done
}
