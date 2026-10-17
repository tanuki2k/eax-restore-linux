#!/usr/bin/env bats
# A setting marked "tested": false is left out of load_game_config_rows unless
# EAX_RESTORE_UNTESTED_SETTINGS is set (or the browser asks for "all"), and its
# rows end with a "1" flag.

load ../helpers

setup() {
    load_script_functions
    source "$REPO_ROOT/src/game-database.sh"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/db.json"
    cat > "$GAME_DATABASE_FILE" <<'JSON'
{"games":[{"id":"g","name":"G","stores":{"steam":{"id":1}},"game_config":{
  "files":{"a.ini":{"format":"ini","locations":["game:a.ini"]}},
  "audio_settings":[
    {"title":"Enable EAX effects","reason":"r","changes":{"a.ini":{"Audio":{"UseEAX":true}}}},
    {"title":"Fix risky thing","reason":"r","tested":false,"changes":{"a.ini":{"Audio":{"Risky":1}}}}]}}]}
JSON
}

@test "untested settings are left out by default" {
    run load_game_config_rows 1 steam
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
    [[ "$output" == *"Enable EAX effects"* ]]
    [[ "$output" != *"Fix risky thing"* ]]
}

@test "EAX_RESTORE_UNTESTED_SETTINGS brings them back, flagged" {
    EAX_RESTORE_UNTESTED_SETTINGS=1 run load_game_config_rows 1 steam
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
    [[ "$(printf '%s\n' "$output" | tail -1)" == *$'\x1f1' ]]
    [[ "$(printf '%s\n' "$output" | head -1)" != *$'\x1f1' ]]
}

@test "the browser's all mode shows them without the variable" {
    run load_game_config_rows 1 steam all
    [[ "$output" == *"Fix risky thing"* ]]
}

@test "the profile tags every setting tested or untested" {
    source "$REPO_ROOT/src/game-database.sh"
    run game_setting_titles 1 steam
    [[ "$output" == *$'audio\tEnable EAX effects\t'* ]]
    [[ "$output" != *$'Enable EAX effects\t1'* ]]
    [[ "$output" == *$'Fix risky thing\t1'* ]]
    [ "$(verified_tag plain)" == "(tested)" ]
    [ "$(verified_tag plain 1)" == "(untested)" ]
}

@test "alsoft.ini values follow install.alsoft_tested" {
    source "$REPO_ROOT/src/game-database.sh"
    jq '.games[0].install = {alsoft_ini: {reverb: {boost: "6"}}, alsoft_tested: false}' "$GAME_DATABASE_FILE" > "$BATS_TEST_TMPDIR/o.json"
    GAME_DATABASE_FILE="$BATS_TEST_TMPDIR/o.json"
    run game_setting_titles 1 steam
    [[ "$output" == *$'openal\treverb boost = 6\t1'* ]]
    current_profile() { return 0; }
    KG_ID=1; KG_STORE=steam
    offer_alsoft_settings
    [ ${#ALSOFT_OVERRIDES[@]} -eq 0 ]
}
