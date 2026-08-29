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

# Optional build-time stamp override — patches the assembled output only, never
# src/globals.sh. Used by the dev-release workflow so a dev build's banner reads
# unmistakably as one (e.g. "0.29-dev"); also handy for local testing. Left
# unset, the version comes straight from src/globals.sh. Values must not contain
# '|' or '&' (sed replacement metacharacters). The grep guard matters: a bare
# sed exits 0 on no-match even under `set -e`, so without it a future
# rename/indent of the assignment would silently ship an unstamped dev build.
if [ -n "${BUILD_VERSION:-}" ]; then
    sed -i -E "s|^SCRIPT_VERSION=.*|SCRIPT_VERSION=\"${BUILD_VERSION}\"|" "$out"
    grep -qxF "SCRIPT_VERSION=\"${BUILD_VERSION}\"" "$out" \
        || { echo "build.sh: SCRIPT_VERSION stamp did not apply" >&2; exit 1; }
fi
if [ -n "${BUILD_DATE:-}" ]; then
    sed -i -E "s|^SCRIPT_DATE=.*|SCRIPT_DATE=\"${BUILD_DATE}\"|" "$out"
    grep -qxF "SCRIPT_DATE=\"${BUILD_DATE}\"" "$out" \
        || { echo "build.sh: SCRIPT_DATE stamp did not apply" >&2; exit 1; }
fi

chmod +x "$out"
echo "Built $out from ${#COMPONENTS[@]} component files."
