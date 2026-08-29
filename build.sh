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

# Stamp the assembled output's version/date so a build says on its own what it
# is — `0.29` + the HEAD commit date for a stable/main build, `0.29-dev` + commit
# date + short SHA for a dev build. This patches dist/ only, never src/globals.sh.
#
# Precedence: an explicit BUILD_VERSION / BUILD_DATE in the environment always
# wins (escape hatch / forcing a value). Otherwise the branch decides which
# version gets stamped, and the git commit date drives SCRIPT_DATE. A checkout
# with no git (e.g. a source tarball) leaves both untouched, so the literals in
# src/globals.sh stand as the fallback.
stamp_version="${BUILD_VERSION:-}"
stamp_date="${BUILD_DATE:-}"

# `branch --show-current` is empty on a detached HEAD, which is how GitHub's
# checkout action leaves things — fall back to the ref name Actions exports.
branch="$(git branch --show-current 2>/dev/null || true)"
[ -n "$branch" ] || branch="${GITHUB_REF_NAME:-}"

on_release_tag=false
if git describe --exact-match --tags --match 'v[0-9]*' HEAD >/dev/null 2>&1; then
    on_release_tag=true
fi

# Dev build: identifiable, not on `main`, not sitting on a release tag.
is_dev_build=false
if [ -n "$branch" ] && [ "$branch" != "main" ] && [ "$on_release_tag" != true ]; then
    is_dev_build=true
fi

if [ -z "$stamp_version" ] && [ "$is_dev_build" = true ]; then
    base="$(sed -nE 's/^SCRIPT_VERSION="([^"]+)".*/\1/p' "$out")"
    stamp_version="${base}-dev"
fi

if [ -z "$stamp_date" ]; then
    # %cs is the committer date as YYYY-MM-DD (git >= 2.19). Empty when there's
    # no git — then the src/globals.sh literal is left in place. Deriving it from
    # the commit (not `date`) keeps a rebuild of the same commit byte-identical.
    commit_date="$(git show -s --format=%cs HEAD 2>/dev/null || true)"
    if [ -n "$commit_date" ]; then
        if [ "$is_dev_build" = true ]; then
            short_sha="g$(git rev-parse --short HEAD)"
            [ -z "$(git status --porcelain 2>/dev/null)" ] || short_sha="${short_sha}-dirty"
            stamp_date="${commit_date} build ${short_sha}"
        else
            stamp_date="$commit_date"
        fi
    fi
fi

# Values must not contain '|' or '&' (sed replacement metacharacters). The grep
# guard matters: a bare sed exits 0 on no-match even under `set -e`, so without
# it a future rename/indent of the assignment would silently ship an unstamped
# build.
if [ -n "$stamp_version" ]; then
    sed -i -E "s|^SCRIPT_VERSION=.*|SCRIPT_VERSION=\"${stamp_version}\"|" "$out"
    grep -qxF "SCRIPT_VERSION=\"${stamp_version}\"" "$out" \
        || { echo "build.sh: SCRIPT_VERSION stamp did not apply" >&2; exit 1; }
fi
if [ -n "$stamp_date" ]; then
    sed -i -E "s|^SCRIPT_DATE=.*|SCRIPT_DATE=\"${stamp_date}\"|" "$out"
    grep -qxF "SCRIPT_DATE=\"${stamp_date}\"" "$out" \
        || { echo "build.sh: SCRIPT_DATE stamp did not apply" >&2; exit 1; }
fi

chmod +x "$out"
echo "Built $out from ${#COMPONENTS[@]} component files."
