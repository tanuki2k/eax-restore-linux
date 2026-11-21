#!/usr/bin/env bash
# Writes the notes for a stable release to stdout, top to bottom:
#   1. .github/release-notes/<tag>.md, the hand-written "What's new", if there is one
#   2. GitHub's generated notes: its "What's Changed" PR list and the changelog link
#   3. when GitHub found no PRs, a "What's Changed" list of the commits instead
# GitHub only lists merged pull requests, and fixes reach main as cherry-picked
# commits, so without step 3 a patch release says nothing about what changed.
#
# Usage: tools/release-notes.sh <tag> [<commit>]   # commit defaults to the tag
# Needs gh with a token for step 2; without one it writes the changelog link itself.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

tag="$1"
ref="${2:-$tag}"
repo="${GITHUB_REPOSITORY:-tanuki2k/eax-restore-linux}"

# v[0-9]* skips the rolling "nightly" tag and the old "dev" tag.
prev=$(git describe --tags --abbrev=0 --match 'v[0-9]*' "$ref^" 2>/dev/null || true)

summary=".github/release-notes/$tag.md"
if [ -f "$summary" ]; then
    cat "$summary"
    echo
fi

generated=""
# ^{commit}: an annotated tag's own object id makes the API fail with a 500.
# A failed call prints its error JSON on stdout, so keep the output only on success.
if command -v gh >/dev/null 2>&1 \
    && out=$(gh api "repos/$repo/releases/generate-notes" -f tag_name="$tag" \
        -f target_commitish="$(git rev-parse "$ref^{commit}")" \
        ${prev:+-f previous_tag_name="$prev"} --jq .body 2>/dev/null); then
    generated="$out"
fi
if [ -z "$generated" ] && [ -n "$prev" ]; then
    generated="**Full Changelog**: https://github.com/$repo/compare/$prev...$tag"
fi

if [ -n "$prev" ] && ! grep -q "^## What's Changed" <<< "$generated"; then
    commits=$(git log --no-merges --format='* %s (%h)' "$prev..$ref" | grep -v '^\* Release v' || true)
    if [ -n "$commits" ]; then
        echo "## What's Changed"
        echo "$commits"
        echo
    fi
fi

[ -n "$generated" ] && echo "$generated"
exit 0
