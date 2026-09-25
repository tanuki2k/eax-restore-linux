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
  EAX_RESTORE_DSOAL_PIN=1             Use the frozen known-good DSOAL build
  EAX_RESTORE_VCRUN_ONLY=1            Only (re)install the VC++ runtime
  EAX_RESTORE_SKIP_CACHE_CHECK=1      Trust the existing local cache
  EAX_RESTORE_KNOWN_GAMES_FILE=PATH   Use a local known-games JSON file
  EAX_RESTORE_NO_LOG=1                Don't write a run log (normally saved to
                                      ~/.local/state/eax-restore-linux/logs/)

Full feature list, environment variable details, and README:
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
