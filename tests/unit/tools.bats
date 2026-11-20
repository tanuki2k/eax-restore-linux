#!/usr/bin/env bats
# The repo's build tools: the wiki build, build.sh and the game database build.

load ../helpers

setup() {
    ROOT="$REPO_ROOT"
    OUT="$BATS_TEST_TMPDIR/wiki"
}

# ---- tools/build-wiki.py -----------------------------------------------------
# The wiki ignores folders, so tools/build-wiki.py flattens docs/ into one folder
# of pages and rewrites the links between them. A link that still names a folder
# or ends in .md opens the raw file on the wiki instead of the page.

@test "every docs page and the editor guide become a flat wiki page" {
    "$ROOT/tools/build-wiki.py" "$ROOT/docs" "$ROOT/tools/profiler/README.md" "$OUT"
    [ -f "$OUT/Home.md" ]
    [ -f "$OUT/how-it-works.md" ]
    [ -f "$OUT/profile-editor.md" ]
    [ -z "$(find "$OUT" -mindepth 2 -name '*.md')" ]
}

@test "links between wiki pages name a page, never a folder or a .md file" {
    "$ROOT/tools/build-wiki.py" "$ROOT/docs" "$ROOT/tools/profiler/README.md" "$OUT"
    ! grep -rnE '\]\((\.\./|[a-z-]+/)?[A-Za-z0-9_-]+\.md' "$OUT"/*.md
}

@test "every link between wiki pages lands on a page that exists" {
    "$ROOT/tools/build-wiki.py" "$ROOT/docs" "$ROOT/tools/profiler/README.md" "$OUT"
    run python3 - "$OUT" <<'PY'
import os, re, sys
out = sys.argv[1]
pages = {f[:-3] for f in os.listdir(out) if f.endswith(".md")}
bad = []
for f in sorted(os.listdir(out)):
    if not f.endswith(".md"):
        continue
    text = re.sub(r"```.*?```", "", open(os.path.join(out, f), encoding="utf-8").read(), flags=re.S)
    for link in re.findall(r"(?<!!)\]\(([^)\s]+)\)", text):
        if re.match(r"(https?:|mailto:|#)", link):
            continue
        if link.split("#")[0] not in pages:
            bad.append(f"{f}: {link}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
    [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "two pages with the same file name are refused" {
    mkdir -p "$BATS_TEST_TMPDIR/docs/a" "$BATS_TEST_TMPDIR/docs/b"
    echo "# one" > "$BATS_TEST_TMPDIR/docs/a/page.md"
    echo "# two" > "$BATS_TEST_TMPDIR/docs/b/page.md"
    echo "# editor" > "$BATS_TEST_TMPDIR/editor.md"
    run "$ROOT/tools/build-wiki.py" "$BATS_TEST_TMPDIR/docs" "$BATS_TEST_TMPDIR/editor.md" "$OUT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"would both become the wiki page page.md"* ]]
}

@test "external links and anchors are left alone" {
    mkdir -p "$BATS_TEST_TMPDIR/docs"
    printf '[a](https://example.com/x.md) [b](#top) [c](sub/other.md#part)\n' > "$BATS_TEST_TMPDIR/docs/p.md"
    echo "# editor" > "$BATS_TEST_TMPDIR/editor.md"
    "$ROOT/tools/build-wiki.py" "$BATS_TEST_TMPDIR/docs" "$BATS_TEST_TMPDIR/editor.md" "$OUT"
    [ "$(cat "$OUT/p.md")" == '[a](https://example.com/x.md) [b](#top) [c](other#part)' ]
}

# ---- build.sh and build-game-database ----------------------------------------

@test "build-game-database: a file that isn't valid JSON fails the build" {
    local w="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$w/tools" "$w/data/games/tested" "$w/data/games/untested" "$w/data/drafts"
    cp "$REPO_ROOT"/tools/*.sh "$REPO_ROOT"/tools/*.jq "$w/tools/" 2>/dev/null || cp -r "$REPO_ROOT"/tools/. "$w/tools/"
    echo '{ not json' > "$w/data/games/tested/broken.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *broken.json* ]]
    [ ! -e "$w/game-database.json" ]
}

@test "build.sh: a src file missing from COMPONENTS stops the build" {
    local w="$BATS_TEST_TMPDIR/b"; mkdir -p "$w"
    cp -r "$REPO_ROOT/src" "$REPO_ROOT/build.sh" "$w/"
    echo '# stray' > "$w/src/not-listed.sh"
    run "$w/build.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-listed.sh"* ]]
}
