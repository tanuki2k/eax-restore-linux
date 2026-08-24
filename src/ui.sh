# ==============================================================================
# TEXT/OUTPUT STYLING HELPERS
# ==============================================================================
# Centralizes the recurring output shapes (banners, arrow status lines,
# Note:/Warning:/Error: messages, (Y/n) prompts, wrapped prose) so call sites
# share one implementation instead of hand-copied echo -e boilerplate. All
# helpers write to stdout; a call site whose output is captured or that needs
# stderr (e.g. a function whose stdout is used via $(...)) redirects the call
# itself with >&2 rather than this file growing a parallel _err() family.
# ==============================================================================
# VISUAL HELPERS
# ==============================================================================
# print_divider/print_line and the rest of the output-styling helpers live in
# ui.sh, sourced right after globals.sh.
print_divider() { echo -e "${CYAN}----------------------------------------------------------${NC}"; }
print_line() { print_divider; }

# Usage: print_banner "LABEL" [COLOR=GREEN]
# Emits the "--- LABEL ---" banner block: blank line, divider, label, divider.
# No trailing blank — callers provide their own leading blank before the
# first content line (most already do via "echo -e \"\n...\""), so the
# helper doesn't double it up. Used for both "--- PHASE N: X ---"-style
# banners and richer blocks like "--- GAME DETAILS ---".
print_banner() {
    local label="$1"
    local color="${2:-$GREEN}"
    echo ""
    print_divider
    echo -e "${color}${BOLD}--- ${label} ---${NC}"
    print_line
}

# Usage: print_step N "Label"
# Emits the numbered step header ("2. Launcher Identification") used to
# separate the sub-stages of PHASE 1: CONFIGURATION. Same blank/divider/
# label/divider wrapper as print_banner (no trailing blank either), but a
# plain (non-bold) CYAN label with no surrounding dashes.
print_step() {
    local n="$1"
    local label="$2"
    echo ""
    print_divider
    echo -e "${CYAN}${n}. ${label}${NC}"
    print_line
}

# Usage: print_status "text" [COLOR=CYAN]
# The " -> text" arrow sub-step line used for progress/result output.
print_status() {
    local text="$1"
    local color="${2:-$CYAN}"
    echo -e " -> ${color}${text}${NC}"
}

# Usage: print_result "text" [COLOR=WHITE]
# The first line of a new "component" of output (e.g. right after a
# print_step/print_banner header). Always begins with its own leading blank
# line so callers never hand-roll "\n${COLOR}text${NC}" or a standalone
# echo "" for this purpose. Distinct from print_status's " -> " arrow
# sub-step lines, which intentionally stack with NO blank between them.
print_result() {
    local text="$1"
    local color="${2:-$WHITE}"
    echo -e "\n${color}${text}${NC}"
}

# Usage: print_paragraph "line1" ["line2" ...]
# A standalone WHITE paragraph — same multi-line joining as print_note/
# print_warning/print_error but with no prefix. Always begins with its own
# leading blank line. Only use this for a block that is fully self-contained
# — i.e. nothing after it relies on a trailing blank this block would
# otherwise have supplied (a block whose last line's trailing "\n" is
# load-bearing for unrelated content further down should keep its manual
# echo -e instead).
print_paragraph() {
    local body="\n${WHITE}$1"
    shift
    for line in "$@"; do body+="\n${line}"; done
    echo -e "${body}${NC}"
}

# Usage: print_note "text" ["more text" ...]
# Usage: print_note_arrow "text" ["more text" ...]
# Standalone-paragraph and " -> " arrow-sub-step forms of a "Note: ..."
# message, in the dedicated NOTE (blue) color. Each argument is printed as
# its own already-wrapped line, joined with real newlines into a single
# echo -e call — a caller's manual line breaks are preserved exactly, never
# rejoined/rewrapped, and (unlike one echo per line) no stray reset-only line
# is emitted at the end.
print_note() {
    local first="$1"; shift
    local body="\n${NOTE}Note: ${first}"
    for line in "$@"; do body+="\n${line}"; done
    echo -e "${body}${NC}"
}
print_note_arrow() {
    local first="$1"; shift
    local body=" -> ${NOTE}Note: ${first}"
    for line in "$@"; do body+="\n${NOTE}${line}"; done
    echo -e "${body}${NC}"
}

# Usage: print_warning "text" ["more text" ...]
# Usage: print_warning_arrow "text" ["more text" ...]
# Standalone-paragraph and " -> " arrow-sub-step forms of a "Warning: ..."
# message. Both forms are bold YELLOW — kept identical on purpose, unlike
# the historical inconsistency where the arrow form dropped BOLD.
print_warning() {
    local first="$1"; shift
    local body="\n${YELLOW}${BOLD}Warning: ${first}"
    for line in "$@"; do body+="\n${line}"; done
    echo -e "${body}${NC}"
}
print_warning_arrow() {
    local first="$1"; shift
    local body=" -> ${YELLOW}${BOLD}Warning: ${first}"
    for line in "$@"; do body+="\n${YELLOW}${BOLD}${line}"; done
    echo -e "${body}${NC}"
}

# Usage: print_error "text" ["more text" ...]
# Usage: print_error_arrow "text" ["more text" ...]
# Standalone-paragraph and " -> " arrow-sub-step forms of an "Error: ..."
# message, bold YELLOW.
print_error() {
    local first="$1"; shift
    local body="\n${YELLOW}${BOLD}Error: ${first}"
    for line in "$@"; do body+="\n${line}"; done
    echo -e "${body}${NC}"
}
print_error_arrow() {
    local first="$1"; shift
    local body=" -> ${YELLOW}${BOLD}Error: ${first}"
    for line in "$@"; do body+="\n${YELLOW}${BOLD}${line}"; done
    echo -e "${body}${NC}"
}

# Usage: print_wrapped "free text"
# Word-wraps free-form prose (e.g. JSON-sourced notes/hints, not already
# hand-wrapped script text) at 76 columns and indents it two spaces, in
# WHITE. Distinct from print_note/print_warning/print_error, whose multi-line
# arguments are assumed already wrapped by the caller.
print_wrapped() {
    echo -e "${WHITE}$(printf '%s' "$1" | fold -s -w 76 | sed 's/^/  /')${NC}"
}

# Usage: confirm "Question?" [default=Y|N]
# Emits the canonical two-line (Y/n)/(y/N) prompt (question line, then a
# separate "> " read line) and returns 0 for yes, 1 for no. default (Y or N,
# case-insensitive; Y if omitted) picks which case the prompt hint and an
# empty answer resolve to. Only for actual yes/no confirms — call sites that
# need the raw typed value (free text, menu numbers) keep their own
# echo -e/read -r.
confirm() {
    local question="$1"
    local default="${2:-Y}"
    local hint="(Y/n)"
    [[ "${default^^}" == "N" ]] && hint="(y/N)"

    echo -e "\n${YELLOW}${question} ${hint}: ${NC}"
    echo -e -n "> "
    local answer
    read -r answer

    if [[ "${default^^}" == "N" ]]; then
        [[ "$answer" =~ $YES_RE ]]
    else
        [[ ! "$answer" =~ $NO_RE ]]
    fi
}
