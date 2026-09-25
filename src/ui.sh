# ==============================================================================
# TEXT/OUTPUT STYLING HELPERS
# ==============================================================================
# Centralizes the recurring output shapes (banners, STATUS: task headers,
# arrow status lines, Note:/Warning:/Error: messages, (Y/n) confirms and
# free-value prompts, numbered menu options, wrapped prose) so call sites
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
# plain (non-bold) CYAN label with no surrounding dashes. When the calling
# flow has set the STEP_TOTAL global (its fixed step count — install is 9,
# uninstall is 6, VCRUN_ONLY is 2), renders "N/TOTAL. Label" instead of just
# "N. Label" so the user can gauge how much of the flow is left; a caller
# that never sets it (e.g. detection.sh's select_architecture, invoked from
# more than one flow) keeps today's plain "N. Label" behavior.
print_step() {
    local n="$1"
    local label="$2"
    local n_display="$n"
    [ -n "${STEP_TOTAL:-}" ] && n_display="${n}/${STEP_TOTAL}"
    echo ""
    print_divider
    echo -e "${CYAN}${n_display}. ${label}${NC}"
    print_line
}

# Usage: print_status "text" [COLOR=CYAN]
# The " -> text" arrow sub-step line used for progress/result output. Pass ""
# explicitly (not just omitting the arg) for plain/uncolored text — needed
# when the text embeds its own ${BOLD}...${NC} highlight, since WHITE already
# carries bold (1;37) and would swallow the contrast.
print_status() {
    local text="$1"
    local color="${2-$CYAN}"
    echo -e " -> ${color}${text}${NC}"
}

# Usage: print_task "text"
# The "\n${CYAN}STATUS: text...${NC}" header that announces a chunk of work
# about to run (a scan, a download, a deploy step). Begins with its own
# leading blank line; the trailing "..." is added here so callers pass just
# the phrase ("Deploying files to local game folder"). A call site whose
# stdout is captured redirects itself — print_task "..." >&2 — the same way
# detection.sh's Heroic scanners already do.
print_task() {
    echo -e "\n${CYAN}STATUS: ${1}...${NC}"
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

# Usage: print_subheading "Label"
# A "\n${NOTE}  Label:${NC}" section-header line introducing a print_wrapped
# body — the GAME DETAILS block's Status:/Restoring EAX with:/Additional
# steps:/Notes:/etc. labels.
print_subheading() {
    echo -e "\n${NOTE}  ${1}:${NC}"
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
# the historical inconsistency where the arrow form dropped BOLD. Both also
# record their headline (first arg) into RUN_WARNINGS for print_run_summary's
# end-of-run recap.
print_warning() {
    local first="$1"; shift
    RUN_WARNINGS+=("$first")
    local body="\n${YELLOW}${BOLD}Warning: ${first}"
    for line in "$@"; do body+="\n${line}"; done
    echo -e "${body}${NC}"
}
print_warning_arrow() {
    local first="$1"; shift
    RUN_WARNINGS+=("$first")
    local body=" -> ${YELLOW}${BOLD}Warning: ${first}"
    for line in "$@"; do body+="\n${YELLOW}${BOLD}${line}"; done
    echo -e "${body}${NC}"
}

# Usage: print_run_summary
# Recaps every Warning: headline emitted so far this run, right before a
# completion banner (INSTALLATION COMPLETE! / UNINSTALL COMPLETE! / VC++
# RUNTIME INSTALL COMPLETE) — a warning that scrolled by mid-run isn't the
# only place it's visible. No-op if RUN_WARNINGS is empty.
print_run_summary() {
    local count="${#RUN_WARNINGS[@]}"
    [ "$count" -eq 0 ] && return
    local noun="warning"
    [ "$count" -ne 1 ] && noun="warnings"
    echo ""
    print_divider
    echo -e "${YELLOW}${BOLD}${count} ${noun} occurred during this run:${NC}"
    local w
    for w in "${RUN_WARNINGS[@]}"; do
        echo -e "  ${YELLOW}- ${w}${NC}"
    done
    print_divider
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
    # EOF (closed/exhausted stdin — a non-interactive run that's out of
    # pre-fed answers) is not an answer: decline regardless of the default,
    # so the caller ends cleanly instead of looping on a prompt nothing will
    # ever respond to.
    read -r answer || return 1

    if [[ "${default^^}" == "N" ]]; then
        [[ "$answer" =~ $YES_RE ]]
    else
        [[ ! "$answer" =~ $NO_RE ]]
    fi
}

# Usage: prompt "question text: "   (caller then does its own `read -r VAR`)
# The non-yes/no counterpart of confirm(): a leading blank line, the YELLOW
# question line, then the separate "> " read line — but NO read, because
# these call sites need the raw typed value (menu numbers, free-text paths)
# and usually loop on their own validation. Use confirm() for actual y/n.
prompt() {
    echo -e "\n${YELLOW}${1}${NC}"
    echo -e -n "> "
}

# Usage: print_option N "Label" ["dim detail"]
# One row of a numbered selection menu: " N) Label", plain/uncolored to match
# the majority menu style (WHITE carries bold 1;37, so wrapping rows in it
# made them stand out inconsistently). An optional third arg is appended as a
# de-emphasized " detail" in DIM — e.g. "in /path/to/dir", "(Steam)". Callers
# still own the menu's leading/trailing blank lines and the ${YELLOW}
# "Selection [...]:" prompt + read loop.
print_option() {
    local n="$1" label="$2" detail="${3-}"
    if [ -n "$detail" ]; then
        echo -e " ${n}) ${label}${DIM} ${detail}${NC}"
    else
        echo -e " ${n}) ${label}"
    fi
}

# ==============================================================================
# PROGRESS HELPERS
# ==============================================================================
# The look follows dankinstall's installer (AvengeMedia/DankMaterialShell,
# MIT): a 30-cell █/░ bar with a percentage, and a braille dot spinner on
# the line of whatever long-running command is in progress. Everything
# redraws a single line with \r rather than scrolling, which also keeps the
# run log clean -- its writer collapses each \r-redrawn line to its final
# state.
SPINNER_FRAMES=(⣾ ⣽ ⣻ ⢿ ⡿ ⣟ ⣯ ⣷)

# Usage: progress_bar <done> <total>
# Prints "[██████░░░…] 40%" (no newline) for done/total.
progress_bar() {
    local done="$1" total="$2" width=30 filled bar="" i
    [ "${total:-0}" -gt 0 ] || total=1
    [ "$done" -gt "$total" ] && done="$total"
    filled=$(( done * width / total ))
    for (( i = 0; i < width; i++ )); do
        if [ "$i" -lt "$filled" ]; then bar+="█"; else bar+="░"; fi
    done
    printf '%b[%s]%b %3d%%' "$CYAN" "$bar" "$NC" $(( done * 100 / total ))
}

# Usage: print_phase_progress <step> <total>
# The overall PHASE 2 bar, printed once under each step's STATUS: header,
# e.g. "    [████████████░░░…]  40%  step 2 of 5".
print_phase_progress() {
    echo -e "    $(progress_bar "$1" "$2")  ${DIM}step $1 of $2${NC}"
}

# Usage: advance_phase_progress
# Bumps PHASE_STEP and prints its bar under the step header just printed.
# A no-op unless PHASE_TOTAL is set, so a helper shared with other flows
# (install_vcrun_dependencies, used by VC++-only mode too) can call it
# unconditionally.
advance_phase_progress() {
    [ -n "${PHASE_TOTAL:-}" ] || return 0
    PHASE_STEP=$(( ${PHASE_STEP:-0} + 1 ))
    print_phase_progress "$PHASE_STEP" "$PHASE_TOTAL"
}

# Runs "$@" in the background and redraws "$1"'s line until it finishes;
# the calling helper passes the pid-wait loop body as a function. Ctrl-C
# has to kill the job explicitly: a non-interactive shell starts
# background jobs with SIGINT ignored, so they'd outlive the script.
_bg_job_pid=""
_start_bg_job() {
    "$@" &
    _bg_job_pid=$!
    _bg_saved_int=$(trap -p INT)
    trap 'kill "$_bg_job_pid" 2>/dev/null; exit 130' INT
}
_finish_bg_job() {
    local rc
    wait "$_bg_job_pid"; rc=$?
    _bg_job_pid=""
    if [ -n "$_bg_saved_int" ]; then eval "$_bg_saved_int"; else trap - INT; fi
    return "$rc"
}

# Usage: fetch_with_progress <url> <dest>
# Drop-in for `curl -fL -# <url> -o <dest>` with a 30-cell bar and the
# downloaded/total size instead of curl's full-width row of #s. The total
# comes from a HEAD request (the last Content-Length after redirects); if
# the server doesn't send one, a spinner and the running size are shown.
# On failure the line is cleared (curl's own error goes to the run log), so
# the caller's error message stands alone. Returns curl's exit status.
fetch_with_progress() {
    local url="$1" dest="$2" total size frame=0 rc
    total=$(curl -sIL "$url" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "content-length:" { n = $2 } END { print n + 0 }')
    rm -f "$dest"
    _start_bg_job _run_logged "${EAX_LOG_FILE:-/dev/null}" curl -fsSL "$url" -o "$dest"
    while kill -0 "$_bg_job_pid" 2>/dev/null; do
        size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
        _draw_fetch_line "$size" "$total" "$frame"
        frame=$(( frame + 1 )); sleep 0.1
    done
    _finish_bg_job; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '\r\033[K'
        return "$rc"
    fi
    size=$(stat -c %s "$dest" 2>/dev/null || echo 0)
    total="$size"
    _draw_fetch_line "$size" "$total" 0
    echo ""
    return 0
}
_draw_fetch_line() {
    local size="$1" total="$2" mb
    mb=$(awk -v s="$size" -v t="$total" 'BEGIN { if (t > 0) printf "%.1f/%.1f MB", s / 1048576, t / 1048576; else printf "%.1f MB", s / 1048576 }')
    if [ "$total" -gt 0 ]; then
        printf '\r    %s  %b%s%b\033[K' "$(progress_bar "$size" "$total")" "$DIM" "$mb" "$NC"
    else
        printf '\r    %b%s%b  %b%s%b\033[K' "$CYAN" "${SPINNER_FRAMES[$(( $3 % 8 ))]}" "$NC" "$DIM" "$mb" "$NC"
    fi
}

# Usage: run_with_spinner "label" <log file> command [args...]
# Runs a slow, quiet command (winetricks, protontricks, a Windows installer)
# with its output appended to <log file>, showing " ⣾ label" while it
# works. The spinner line is cleared when the command ends, so the caller's
# own result line takes its place. Returns the command's exit status.
run_with_spinner() {
    local label="$1" log="$2" frame=0
    shift 2
    _start_bg_job _run_logged "$log" "$@"
    while kill -0 "$_bg_job_pid" 2>/dev/null; do
        printf '\r %b%s%b %s\033[K' "$CYAN" "${SPINNER_FRAMES[$(( frame % 8 ))]}" "$NC" "$label"
        frame=$(( frame + 1 )); sleep 0.1
    done
    printf '\r\033[K'
    _finish_bg_job
}
_run_logged() {
    local log="$1"; shift
    "$@" &>> "$log"
}
