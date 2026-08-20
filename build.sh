#!/usr/bin/env bash
# Assembles src/*.sh into the single distributed eax-restore-linux.sh, written
# to dist/ (gitignored build output).
#
# The script is split into component files under src/ for editing, but is
# still shipped and curled as one file, so this concatenates them back
# together in execution order. Never hand-edit dist/eax-restore-linux.sh
# directly — edit the relevant src/*.sh file and re-run this script.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Order matters: this is the exact order these sections run in the assembled
# script (constants/globals are grouped together here even though the
# original file interleaves a second globals block after the guards — pure
# variable assignments, so reordering them doesn't change behavior).
COMPONENTS=(
    header.sh
    globals.sh
    ui.sh
    common.sh
    guards.sh
    detection.sh
    known-games.sh
    vcrun.sh
    verify.sh
    cache.sh
    preflight.sh
    vcrun-only-flow.sh
    uninstall-flow.sh
    config-flow.sh
    install-flow.sh
)

mkdir -p dist
out="dist/eax-restore-linux.sh"
: > "$out"
for f in "${COMPONENTS[@]}"; do
    cat "src/$f" >> "$out"
    echo "" >> "$out"
done

chmod +x "$out"
echo "Built $out from ${#COMPONENTS[@]} component files."
