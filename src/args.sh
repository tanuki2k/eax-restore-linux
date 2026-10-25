# ==============================================================================
# COMMAND-LINE ARGUMENTS
# ==============================================================================
# The install/uninstall flow itself has no flags — it's fully interactive (see
# the EAX_RESTORE_* environment variables below). This only handles -h/--help
# and -v/--version so a user can see what the script does and which build
# they have without stepping through the interactive flow. Placed right after
# globals.sh (needs SCRIPT_VERSION/SCRIPT_DATE/color vars only) and before
# guards.sh's root/Gaming-Mode checks and preflight.sh's screen clear, so both
# flags return instantly with no side effects.
# Kept for the self-update restart, which runs the new script the same way.
ORIGINAL_ARGS=("$@")
case "${1:-}" in
    -h|--help)
        # echo -e (not cat) because BOLD/NC etc. are literal backslash-escape
        # sequences that only render through something that interprets them.
        echo -e "$(cat <<EOF
${BOLD}DSOAL & OpenAL Soft Universal Installer${NC}  v${SCRIPT_VERSION} (${SCRIPT_DATE})

Restores EAX/DirectSound3D 3D audio in classic Windows games running under
Steam/Proton or Heroic/Wine on Linux, by deploying DSOAL + OpenAL Soft (or a
direct OpenAL Soft swap) into the game folder and Wine/Proton prefix.

Usage: $(basename "$0")

There are no command-line flags for the install itself — running the script
launches an interactive install/uninstall flow. Configuration beyond the
prompts is done via environment variables:

  EAX_RESTORE_SKIP_PREFLIGHT=1        Skip the dependency scan
  EAX_RESTORE_DSOAL_PIN=1             Use the stable DSOAL build without asking
  EAX_RESTORE_VCRUN_ONLY=1            Only (re)install the VC++ runtime
  EAX_RESTORE_SKIP_UPDATE_CHECK=1     Don't check for a newer version of the script
  EAX_RESTORE_SKIP_CACHE_CHECK=1      Only use builds already downloaded
  EAX_RESTORE_GAME_DATABASE_FILE=PATH   Use a local game database file
  EAX_RESTORE_UNTESTED=1              Include unverified game profiles (left out
                                      otherwise)
  EAX_RESTORE_UNTESTED_SETTINGS=1     Offer unverified game and alsoft.ini settings
                                      (left out otherwise)
  EAX_RESTORE_ANSWERS_FILE=PATH       Read the answers to every prompt from a file
  EAX_RESTORE_NO_LOG=1                Don't write a run log (normally saved to
                                      ~/.local/state/eax-restore-linux/logs/)

Full feature list, environment variable details, and docs:
https://github.com/tanuki2k/eax-restore-linux

  -h, --help     Show this help text and exit
  -v, --version  Show the script version and exit
EOF
)"
        exit 0
        ;;
    -v|--version)
        echo "eax-restore-linux v${SCRIPT_VERSION} (${SCRIPT_DATE})"
        exit 0
        ;;
esac

# Unattended runs (the profiler tool): a file of answers, one line per prompt,
# replaces the terminal. Everything already reads piped stdin, so no prompt
# needs to know.
if [ -n "${EAX_RESTORE_ANSWERS_FILE:-}" ]; then
    [ -r "$EAX_RESTORE_ANSWERS_FILE" ] || { echo "Answers file not readable: $EAX_RESTORE_ANSWERS_FILE" >&2; exit 1; }
    exec < <(grep -v '^[[:space:]]*#' "$EAX_RESTORE_ANSWERS_FILE")
fi
