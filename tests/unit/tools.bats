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

# A copy of the database tooling with no games, for the build tests below.
_db_workdir() {
    local w="$BATS_TEST_TMPDIR/repo"
    mkdir -p "$w/tools" "$w/data/games" "$w/data/drafts"
    cp "$REPO_ROOT"/tools/*.sh "$REPO_ROOT"/tools/*.jq "$w/tools/"
    echo "$w"
}

@test "build-game-database: a file that isn't valid JSON fails the build" {
    local w; w="$(_db_workdir)"
    echo '{ not json' > "$w/data/games/broken.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *broken.json* ]]
    [ ! -e "$w/game-database.json" ]
}

@test "build-game-database: a game left in the old tested/ folder stops the build and says where it goes" {
    local w; w="$(_db_workdir)"
    mkdir -p "$w/data/games/tested"
    echo '{"name":"Old","stores":{"steam":{"id":1}},"eax":{"api":"openal"}}' > "$w/data/games/tested/old.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"data/games/tested/old.json"* ]]
    [[ "$output" == *'"compatibility": "verified"'* ]]
}

@test "build-game-database: a playable or unsupported game without a problem text stops the build" {
    local w; w="$(_db_workdir)"
    echo '{"name":"P","compatibility":"playable","stores":{"steam":{"id":1}},"eax":{"api":"openal"}}' > "$w/data/games/p.json"
    echo '{"name":"U","stores":{"steam":{"id":2},"gog":{"id":3,"compatibility":"unsupported"}},"eax":{"api":"openal"}}' > "$w/data/games/u.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"p.json: steam is playable"* ]]
    [[ "$output" == *"u.json: gog is unsupported"* ]]
}

@test "build-game-database: the fields compatibility replaced are refused in a game file" {
    local w; w="$(_db_workdir)"
    echo '{"name":"S","stores":{"steam":{"id":1}},"eax":{"api":"openal","status":"built_in"},"install":{"alsoft_tested":true},
           "game_config":{"files":{"a.ini":{"format":"ini","locations":["game_exe:a.ini"]}},"audio_settings":[{"title":"Enable EAX","reason":"r","changes":{"a.ini":{"k":"1"}},"tested":true}]}}' > "$w/data/games/s.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"eax.status and eax.fix_in_place are replaced"* ]]
    [[ "$output" == *"alsoft_tested is now install.alsoft_verified"* ]]
    [[ "$output" == *"settings use tested, which is now verified: Enable EAX"* ]]
}

@test "build-game-database: each store gets its compatibility, and older scripts still get their fields" {
    local w; w="$(_db_workdir)"
    echo '{"name":"Remaster","compatibility":"unsupported","stores":{"steam":{"id":1}},"eax":{"api":"openal","problem":"No EAX."}}' > "$w/data/games/remaster.json"
    echo '{"name":"Patched","compatibility":"unsupported","stores":{"steam":{"id":2}},"eax":{"api":"directsound3d","versions":["1.0"],"problem":"An update removed it."}}' > "$w/data/games/patched.json"
    echo '{"name":"Rolled","compatibility":"verified","stores":{"steam":{"id":3,"beta_branch":"old"},"gog":{"id":4,"compatibility":"playable","problem":"GOG only."}},"eax":{"api":"directsound3d"}}' > "$w/data/games/rolled.json"
    echo '{"name":"Built","stores":{"steam":{"id":5}},"eax":{"api":"openal","built_in":true},"install":{"alsoft_ini":{"reverb":{"boost":"3"}},"alsoft_verified":true},
           "game_config":{"files":{"a.ini":{"format":"ini","locations":["game_exe:a.ini"]}},"audio_settings":[{"title":"Enable EAX","reason":"r","changes":{"a.ini":{"k":"1"}},"verified":true},{"title":"Other","reason":"r","changes":{"a.ini":{"j":"1"}}}]}}' > "$w/data/games/built.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -eq 0 ]
    q() { jq -c --arg id "$1" ".games[] | select(.id == \$id) | $2" "$w/game-database.json"; }
    [ "$(q remaster '[.tested, .eax.status, .stores.steam.compatibility]')" == '[null,"not_implemented","unsupported"]' ]
    [ "$(q patched '.eax.status')" == '"removed_by_patch"' ]
    [ "$(q rolled '[.eax.status, .eax.fix_in_place, .stores.steam.compatibility, .stores.gog.compatibility, .stores.gog.problem, .stores.steam.problem]')" == '["removed_by_patch",true,"verified","playable","GOG only.",null]' ]
    [ "$(q built '[.tested, .eax.status, .stores.steam.compatibility, .install.alsoft_tested, [.game_config.audio_settings[].tested]]')" == '[false,"built_in","unknown",true,[true,null]]' ]
}

@test "build-game-database: the owned list never ships, and a game missing from it only warns" {
    local w; w="$(_db_workdir)"
    echo '{"name":"Mine","stores":{"steam":{"id":1}},"eax":{"api":"openal"}}' > "$w/data/games/mine.json"
    echo '["mine", "gone"]' > "$w/data/owned.json"
    run "$w/tools/build-game-database.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"data/owned.json lists games with no file"*"gone"* ]]
    ! grep -q owned "$w/game-database.json"
}

@test "build.sh: a src file missing from COMPONENTS stops the build" {
    local w="$BATS_TEST_TMPDIR/b"; mkdir -p "$w"
    cp -r "$REPO_ROOT/src" "$REPO_ROOT/build.sh" "$w/"
    echo '# stray' > "$w/src/not-listed.sh"
    run "$w/build.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not-listed.sh"* ]]
}
