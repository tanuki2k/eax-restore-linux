#!/usr/bin/env bats
# A game whose profile only has an alsoft.ini value (a reverb boost) and no
# config files of its own: the install still offers it, under Phase 3's Game
# Audio Settings header, and writes the accepted value into alsoft.ini.

load env

setup() {
    [ -x "$REPO_ROOT/dist/eax-restore-linux.sh" ] || skip "run ./build.sh first"
    make_world
    DB_FILE="$BATS_TEST_TMPDIR/boost-db.json"
    jq '.games[0] |= (del(.game_config) | .install = {alsoft_ini: {reverb: {boost: "6"}}})' \
        "$REPO_ROOT/tests/fixtures/game-database.json" > "$DB_FILE"
}

# profile_install_answers without Game Audio Settings' and Optional Game
# Settings' answers, with the boost question (the first of $2) after the override.
boost_answers() {
    answers "$1" m "" "$GAME" \
        "" "" "" \
        "" "" \
        "" "" \
        "" \
        "" n \
        "" "" "" \
        "" \
        "" \
        "$2" \
        "" "" ""
}

@test "the boost is asked in phase 3 and written to alsoft.ini" {
    boost_answers "$BATS_TEST_TMPDIR/in" ""
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    grep -q "PHASE 3 OF 4: GAME SETTINGS" "$OUT"
    grep -q "Raise the reverb boost to +6 dB" "$OUT"
    # it comes after the Game Audio Settings header, not under Speaker Configuration
    awk '/3\/5\. Speaker Configuration/{sp=NR} /Game Audio Settings/{ga=NR} /Raise the reverb boost/{rb=NR} END{exit !(ga && rb>ga && rb>sp)}' "$OUT"
    grep -Eq "^boost *= *6$" "$GAME/alsoft.ini"
}

@test "declining the boost leaves alsoft.ini without it" {
    boost_answers "$BATS_TEST_TMPDIR/in" "n"
    run_script "$BATS_TEST_TMPDIR/in"
    grep -q "INSTALLATION COMPLETE" "$OUT" || { tail -30 "$OUT"; false; }
    grep -Eq "^boost *= *0$" "$GAME/alsoft.ini"
}
