#!/usr/bin/env bats
# tools/release-notes.sh: GitHub's notes only list pull requests, so a release
# made of cherry-picked commits had no "What's Changed". The script lists the
# commits itself and puts the hand-written summary on top. Runs in a scratch
# repo without gh, so the changelog link is the script's own fallback.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    R="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$R/tools" "$R/.github/release-notes" "$BATS_TEST_TMPDIR/bin"
    cp "$REPO_ROOT/tools/release-notes.sh" "$R/tools/"
    # git only: no gh on PATH
    ln -s "$(command -v git)" "$BATS_TEST_TMPDIR/bin/git"
    cd "$R"
    git init -q -b main
    git config user.email t@example.com; git config user.name t
    c() { echo "$1" >> f; git add f; git commit -qm "$1"; }
    c "First"; git tag -a v1.0 -m v1.0
    c "Fix a thing"; git tag nightly
    c "Add a game"; c "Release v1.0.1"; git tag -a v1.0.1 -m v1.0.1
}

notes() { PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" bash -c '"$@"' _ "$R/tools/release-notes.sh" "$@"; }

@test "lists the commits since the last v tag, without the Release commit" {
    run notes v1.0.1
    [ "$status" -eq 0 ]
    [[ "$output" == *"## What's Changed"* ]]
    [[ "$output" == *"* Fix a thing ("* ]]
    [[ "$output" == *"* Add a game ("* ]]
    [[ "$output" != *"Release v1.0.1"* ]]
    [[ "$output" != *"* First ("* ]]
    [[ "$output" == *"compare/v1.0...v1.0.1"* ]]
}

@test "puts the hand-written summary first when there is one" {
    printf '## What'"'"'s new in 1.0.1\n\nSummary line.\n' > .github/release-notes/v1.0.1.md
    run notes v1.0.1
    [ "${lines[0]}" == "## What's new in 1.0.1" ]
    [[ "$output" == *"Summary line."*"## What's Changed"* ]]
}

@test "the first release has no previous tag and no list" {
    run notes v1.0
    [ "$status" -eq 0 ]
    [[ "$output" != *"What's Changed"* ]]
}
