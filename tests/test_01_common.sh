#!/usr/bin/env bash
# QA tests for bin/lib/common.sh (ticket 01).
# Run with: bash tests/test_01_common.sh
# It uses only sandbox folders. It never writes the real logs or .env.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Load the library under test.
source "$REPO_ROOT/bin/lib/common.sh"

# ---------------------------------------------------------------------
# Helpers for this file
# ---------------------------------------------------------------------

# Check that a file name gives the expected part index.
# Args: <archive> <file name> <expected index>
_check_index() {
    local archive="$1" file="$2" expected="$3" out="" rc=0
    out="$(part_index_from_name "$archive" "$file")" || rc=$?
    assert_eq "0" "$rc" "return code for [$file] of archive [$archive]" || return 1
    assert_eq "$expected" "$out" "index for [$file] of archive [$archive]" || return 1
}

# Check that a file name does not match an archive.
# Args: <archive> <file name>
_check_no_index() {
    local archive="$1" file="$2" out="" rc=0
    out="$(part_index_from_name "$archive" "$file")" || rc=$?
    assert_eq "1" "$rc" "no match for [$file] of archive [$archive]" || return 1
    assert_eq "" "$out" "no output for [$file] of archive [$archive]" || return 1
}

# Check that a name passes validate_archive_name.
# Args: <name>
_check_name_ok() {
    local rc=0
    validate_archive_name "$1" || rc=$?
    assert_eq "0" "$rc" "archive name [$1] must be accepted" || return 1
}

# Check that a name fails validate_archive_name.
# Args: <name>
_check_name_bad() {
    local rc=0
    validate_archive_name "$1" || rc=$?
    assert_eq "1" "$rc" "archive name [$1] must be rejected" || return 1
}

# ---------------------------------------------------------------------
# config_load_accounts
# ---------------------------------------------------------------------

# Load a multi-line fixture with one account.
test_config_one_account_fixture() {
    setup_sandbox 1
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "return code for 1-account fixture" || return 1
    assert_eq "1" "$MPA_ACCOUNT_COUNT" "count for 1-account fixture" || return 1
    assert_contains "${MPA_ACCOUNTS[0]}" '"token": "fake0"' "first account keeps its token" || return 1
    teardown_sandbox
}

# Load a fixture with three accounts. Check the order too.
test_config_three_account_fixture() {
    setup_sandbox 3
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "return code for 3-account fixture" || return 1
    assert_eq "3" "$MPA_ACCOUNT_COUNT" "count for 3-account fixture" || return 1
    assert_eq "3" "${#MPA_ACCOUNTS[@]}" "array length for 3-account fixture" || return 1
    assert_contains "${MPA_ACCOUNTS[2]}" '"name": "acct2"' "third account is acct2" || return 1
    teardown_sandbox
}

# Load a fixture where one account has "active": false. Expect 2.
test_config_inactive_account_skipped() {
    setup_sandbox 1
    cat > "$MPARCHIVE_CONFIG_DIR/mock.json" <<'EOF'
{
  "accounts": [
    {
      "name": "one",
      "token": "fake-one"
    },
    {
      "name": "two",
      "token": "fake-two",
      "active": false
    },
    {
      "name": "three",
      "token": "fake-three"
    }
  ]
}
EOF
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "return code for inactive-account fixture" || return 1
    assert_eq "2" "$MPA_ACCOUNT_COUNT" "count with one inactive account" || return 1
    assert_not_contains "${MPA_ACCOUNTS[*]}" "fake-two" "inactive account must be skipped" || return 1
    assert_contains "${MPA_ACCOUNTS[1]}" "fake-three" "account after the skipped one is kept" || return 1
    teardown_sandbox
}

# Load a fixture with CRLF line ends and tabs. Expect 1 account.
test_config_crlf_and_tabs_fixture() {
    setup_sandbox 1
    printf '{\r\n\t"accounts": [\r\n\t\t{"name": "crlf", "token": "fake-crlf"}\r\n\t]\r\n}\r\n' \
        > "$MPARCHIVE_CONFIG_DIR/mock.json"
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "return code for CRLF fixture" || return 1
    assert_eq "1" "$MPA_ACCOUNT_COUNT" "count for CRLF fixture" || return 1
    assert_contains "${MPA_ACCOUNTS[0]}" "fake-crlf" "CRLF fixture keeps its token" || return 1
    teardown_sandbox
}

# A missing file must return 1 and write an error.log entry.
test_config_missing_file() {
    setup_sandbox 1
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/none.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code for missing file" || return 1
    assert_eq "0" "$MPA_ACCOUNT_COUNT" "count after missing file" || return 1
    assert_file_exists "$MPARCHIVE_LOG_DIR/error.log" "error.log must exist" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Account file is missing" \
        "error.log entry for missing file" || return 1
    teardown_sandbox
}

# An empty accounts array must return 1 and write an error.log entry.
test_config_empty_accounts_array() {
    setup_sandbox 1
    printf '{"accounts": []}\n' > "$MPARCHIVE_CONFIG_DIR/mock.json"
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code for empty accounts array" || return 1
    assert_eq "0" "$MPA_ACCOUNT_COUNT" "count for empty accounts array" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "No active account" \
        "error.log entry for empty accounts array" || return 1
    teardown_sandbox
}

# When every account is inactive, the result is the same as an empty array.
test_config_all_inactive() {
    setup_sandbox 1
    printf '{"accounts": [{"name": "a", "token": "fake-a", "active": false}]}\n' \
        > "$MPARCHIVE_CONFIG_DIR/mock.json"
    local rc=0
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code when all accounts are inactive" || return 1
    assert_eq "0" "$MPA_ACCOUNT_COUNT" "count when all accounts are inactive" || return 1
    teardown_sandbox
}

# Malformed files must return 1 and write an error.log entry.
test_config_malformed_files() {
    setup_sandbox 1
    local rc=0

    # The array is never closed.
    printf '{"accounts": [{"name": "a", "token": "fake-a"}\n' > "$MPARCHIVE_CONFIG_DIR/mock.json"
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code for unclosed array" || return 1
    assert_eq "0" "$MPA_ACCOUNT_COUNT" "count for unclosed array" || return 1

    # Text that is not an object sits in the array.
    rc=0
    printf '{"accounts": [{"name": "a"}, garbage]}\n' > "$MPARCHIVE_CONFIG_DIR/mock.json"
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code for garbage in array" || return 1

    # The file has no accounts key at all.
    rc=0
    printf '{"other": []}\n' > "$MPARCHIVE_CONFIG_DIR/mock.json"
    config_load_accounts "$MPARCHIVE_CONFIG_DIR/mock.json" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "return code without accounts key" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "No \"accounts\" array" \
        "error.log entry without accounts key" || return 1
    teardown_sandbox
}

# ---------------------------------------------------------------------
# JSON helpers
# ---------------------------------------------------------------------

# Read string values, with and without spaces around the colon.
test_json_get_string() {
    local json='{"name": "acct0", "developer_token" : "fake-token-123", "x": 1}'
    assert_eq "fake-token-123" "$(json_get_string "$json" developer_token)" \
        "developer_token with spaces around colon" || return 1
    assert_eq "acct0" "$(json_get_string "$json" name)" "name value" || return 1
    assert_eq "fake-token-456" "$(json_get_string '{"developer_token":"fake-token-456"}' developer_token)" \
        "developer_token without spaces" || return 1

    # A missing key returns 1.
    local rc=0
    json_get_string "$json" missing_key >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "missing key must return 1" || return 1
}

# Read integer values, including a negative value.
test_json_get_number() {
    local json='{"size" : 42, "neg": -7, "name":"x"}'
    assert_eq "42" "$(json_get_number "$json" size)" "positive number" || return 1
    assert_eq "-7" "$(json_get_number "$json" neg)" "negative number" || return 1

    # A missing key returns 1.
    local rc=0
    json_get_number "$json" missing_key >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "missing number key must return 1" || return 1
}

# Escape backslash and double quote.
test_json_escape() {
    assert_eq 'a\"b\\c' "$(json_escape 'a"b\c')" "escape quote and backslash" || return 1
    assert_eq "" "$(json_escape "")" "escape empty string" || return 1
    assert_eq "plain text" "$(json_escape "plain text")" "plain text stays the same" || return 1
}

# json_compact removes new lines, carriage returns and tabs.
test_json_compact() {
    assert_eq "ab c" "$(printf 'a\n\tb\r\n c\n' | json_compact)" "compact removes control characters" || return 1
}

# ---------------------------------------------------------------------
# Archive and part names
# ---------------------------------------------------------------------

# Build part names.
test_part_name() {
    assert_eq "b1.p10.tar.gz" "$(part_name b1 10)" "part name with index 10" || return 1
    assert_eq "b1.p0.tar.gz" "$(part_name b1 0)" "part name with index 0" || return 1
    assert_eq "a.b.p3.tar.gz" "$(part_name a.b 3)" "part name of dotted archive" || return 1
}

# Read the part index from a name. Check the examples from the ticket.
test_part_index_from_name_match() {
    _check_index b1 "b1.p10.tar.gz" 10 || return 1
    _check_index b1 "b1.p0.tar.gz" 0 || return 1
    _check_index a.b "a.b.p3.tar.gz" 3 || return 1
    _check_index b1 "b1.p007.tar.gz" 7 || return 1
    _check_index b1 "b1.p999999999.tar.gz" 999999999 || return 1
}

# Reject names that do not match. Check the examples from the ticket.
test_part_index_from_name_no_match() {
    _check_no_index b1 "b1.p.tar.gz" || return 1
    _check_no_index b1 "b1x.p0.tar.gz" || return 1
    _check_no_index b1 "b1.p0.tar.gz.bak" || return 1
    _check_no_index b1 "b1.p1a.tar.gz" || return 1
    _check_no_index b "b1.p0.tar.gz" || return 1
    _check_no_index b1 "b1.p0.p1.tar.gz" || return 1
    _check_no_index b1 "b1.p1234567890.tar.gz" || return 1
    _check_no_index "" "p0.tar.gz" || return 1
}

# Check the part index for an empty filename and an empty archive.
test_part_index_edge_cases() {
    _check_no_index b1 "" || return 1
    _check_no_index b1 "b1.p-1.tar.gz" || return 1
}

# Accept safe archive names and reject unsafe ones.
test_validate_archive_name() {
    _check_name_ok "backup1" || return 1
    _check_name_ok "a.b-c_d" || return 1
    _check_name_bad "" || return 1
    _check_name_bad "a/b" || return 1
    _check_name_bad ".hidden" || return 1
    _check_name_bad "-dash" || return 1
}

# ---------------------------------------------------------------------
# Size and file helpers
# ---------------------------------------------------------------------

# The size of a file equals its byte count. A missing path returns 1.
test_path_total_size_and_file_size() {
    setup_sandbox 1
    printf 'abcdef' > "$SANDBOX_DIR/six.bin"
    assert_eq "6" "$(path_total_size "$SANDBOX_DIR/six.bin")" "path_total_size of a 6 byte file" || return 1
    assert_eq "6" "$(file_size "$SANDBOX_DIR/six.bin")" "file_size of a 6 byte file" || return 1

    local rc=0
    path_total_size "$SANDBOX_DIR/no-such-path" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "missing path must return 1" || return 1
    teardown_sandbox
}

# Check the integer ceiling division and the part size math.
test_ceil_div_and_part_size() {
    assert_eq "4" "$(ceil_div 10 3)" "ceil_div 10 3" || return 1
    assert_eq "3" "$(ceil_div 9 3)" "ceil_div 9 3" || return 1
    assert_eq "0" "$(ceil_div 0 2)" "ceil_div 0 2" || return 1
    assert_eq "1" "$(ceil_div 1 1)" "ceil_div 1 1" || return 1

    # Size per part for TOTAL=68129136.
    local total=68129136
    assert_eq "68129136" "$(ceil_div "$total" 1)" "part size with N=1" || return 1
    assert_eq "22709712" "$(ceil_div "$total" 3)" "part size with N=3" || return 1
    assert_eq "22709713" "$(ceil_div 68129137 3)" "part size rounds up" || return 1

    # A zero divisor or a bad number returns 1.
    local rc=0
    ceil_div 5 0 >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "ceil_div by zero must return 1" || return 1
}

# sort_indices sorts numbers, not text.
test_sort_indices_numeric() {
    local out
    out="$(printf '%s\n' 10 2 1 0 11 2 | sort_indices | paste -sd' ' -)"
    assert_eq "0 1 2 10 11" "$out" "numeric unique sort" || return 1
}

# make_tmpdir creates a folder inside MPARCHIVE_TMPDIR.
test_make_tmpdir() {
    setup_sandbox 1
    local dir
    dir="$(make_tmpdir)" || return 1
    assert_file_exists "$dir" "make_tmpdir must create a folder" || return 1
    assert_contains "$dir" "$MPARCHIVE_TMPDIR/mp-archive." "folder must be under MPARCHIVE_TMPDIR" || return 1
    rmdir -- "$dir"
    teardown_sandbox
}

# ---------------------------------------------------------------------
# load_env_file
# ---------------------------------------------------------------------

# A command in the value must stay literal. No command must run.
test_load_env_file_never_executes() {
    setup_sandbox 1
    local env_file="$SANDBOX_DIR/inject.env"
    local marker="$SANDBOX_DIR/pwned"
    local marker2="$SANDBOX_DIR/pwned2"
    printf '%s\n' "PROVIDER=\$(touch $marker)" > "$env_file"
    printf '%s\n' "MPA_TEST_SEMI=x; touch $marker2" >> "$env_file"
    unset PROVIDER MPA_TEST_SEMI
    load_env_file "$env_file" || return 1
    assert_file_missing "$marker" "command substitution must not run" || return 1
    assert_file_missing "$marker2" "semicolon command must not run" || return 1
    assert_eq "\$(touch $marker)" "$PROVIDER" "PROVIDER must keep the literal text" || return 1
    unset PROVIDER MPA_TEST_SEMI
    teardown_sandbox
}

# Quotes around a value are removed. Spaces around the key and value are removed.
test_load_env_file_quotes_and_spaces() {
    setup_sandbox 1
    local env_file="$SANDBOX_DIR/quotes.env"
    cat > "$env_file" <<'EOF'
# A comment line is skipped.
MPA_TEST_DQ="hello world"
MPA_TEST_SQ='x y'
  MPA_TEST_WS =   spaced
export MPA_TEST_EXP=yes
lower_key=1
bad-key=2

EOF
    unset MPA_TEST_DQ MPA_TEST_SQ MPA_TEST_WS MPA_TEST_COMMENT MPA_TEST_EXP lower_key
    load_env_file "$env_file" || return 1
    assert_eq "hello world" "${MPA_TEST_DQ:-}" "double quotes must be removed" || return 1
    assert_eq "x y" "${MPA_TEST_SQ:-}" "single quotes must be removed" || return 1
    assert_eq "spaced" "${MPA_TEST_WS:-}" "spaces around key and value must be removed" || return 1
    assert_eq "yes" "${MPA_TEST_EXP:-}" "export prefix must be accepted" || return 1
    assert_eq "" "${lower_key:-}" "lower case key must be rejected" || return 1
    unset MPA_TEST_DQ MPA_TEST_SQ MPA_TEST_WS MPA_TEST_COMMENT MPA_TEST_EXP lower_key
    teardown_sandbox
}

# A variable that is already set must keep its value.
test_load_env_file_keeps_preset_value() {
    setup_sandbox 1
    local env_file="$SANDBOX_DIR/preset.env"
    printf 'MPA_TEST_PRESET=from-file\n' > "$env_file"
    export MPA_TEST_PRESET=from-env
    load_env_file "$env_file" || return 1
    assert_eq "from-env" "${MPA_TEST_PRESET:-}" "preset environment value must win" || return 1
    unset MPA_TEST_PRESET
    teardown_sandbox
}

# A missing env file returns 1 and writes an error.log entry.
test_load_env_file_missing() {
    setup_sandbox 1
    local rc=0
    load_env_file "$SANDBOX_DIR/none.env" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "missing env file must return 1" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Cannot read env file" \
        "error.log entry for missing env file" || return 1
    teardown_sandbox
}

# ---------------------------------------------------------------------
# Logging and die
# ---------------------------------------------------------------------

# log_info goes to activity.log only. log_error goes to both logs.
# The sandbox must not touch the real logs in the project root.
test_logging_targets() {
    setup_sandbox 1
    local real_err="$REPO_ROOT/error.log" real_act="$REPO_ROOT/activity.log"
    local before_err="missing" before_act="missing"
    [[ -e "$real_err" ]] && before_err="$(stat -c %s "$real_err")"
    [[ -e "$real_act" ]] && before_act="$(stat -c %s "$real_act")"

    MPA_SCRIPT_NAME="qa-test"
    log_info "info line" 2>/dev/null
    log_error "error line" 2>/dev/null

    local act err
    act="$(cat "$MPARCHIVE_LOG_DIR/activity.log")"
    err="$(cat "$MPARCHIVE_LOG_DIR/error.log")"
    assert_contains "$act" "[INFO] [qa-test] info line" "activity.log must get the info line" || return 1
    assert_contains "$act" "[ERROR] [qa-test] error line" "activity.log must get the error line" || return 1
    assert_contains "$err" "[ERROR] [qa-test] error line" "error.log must get the error line" || return 1
    assert_not_contains "$err" "info line" "error.log must not get the info line" || return 1

    # Check the time stamp format of the first line.
    local ts_ok="no"
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} \[ERROR\] ' \
        "$MPARCHIVE_LOG_DIR/error.log" && ts_ok="yes"
    assert_eq "yes" "$ts_ok" "log line must start with a time stamp" || return 1

    # Check that the real logs did not change.
    local after_err="missing" after_act="missing"
    [[ -e "$real_err" ]] && after_err="$(stat -c %s "$real_err")"
    [[ -e "$real_act" ]] && after_act="$(stat -c %s "$real_act")"
    assert_eq "$before_err" "$after_err" "real error.log must not change" || return 1
    assert_eq "$before_act" "$after_act" "real activity.log must not change" || return 1

    unset MPA_SCRIPT_NAME
    teardown_sandbox
}

# die uses the given code, then MPA_DIE_CODE, then 1.
test_die_exit_codes() {
    setup_sandbox 1
    local rc=0 out
    unset MPA_DIE_CODE

    out="$( (die "boom test" 5) 2>&1 )" && rc=0 || rc=$?
    assert_eq "5" "$rc" "die with explicit code 5" || return 1

    rc=0
    out="$( (die "boom default") 2>&1 )" && rc=0 || rc=$?
    assert_eq "1" "$rc" "die without code must exit 1" || return 1

    rc=0
    out="$( (MPA_DIE_CODE=7 die "boom env") 2>&1 )" && rc=0 || rc=$?
    assert_eq "7" "$rc" "die must use MPA_DIE_CODE" || return 1

    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "boom test" "die must write error.log" || return 1
    teardown_sandbox
}

# ---------------------------------------------------------------------
# mpa_init
# ---------------------------------------------------------------------

# A valid sandbox loads the provider and the accounts.
test_mpa_init_success() {
    setup_sandbox 2
    local rc=0 out
    out="$( (mpa_init && declare -F provider_upload_file >/dev/null \
        && printf 'count=%s\n' "$MPA_ACCOUNT_COUNT") 2>/dev/null )" || rc=$?
    assert_eq "0" "$rc" "mpa_init return code in sandbox" || return 1
    assert_eq "count=2" "$out" "mpa_init account count and provider functions" || return 1
    teardown_sandbox
}

# A missing mock.json must exit non-zero and write error.log.
test_mpa_init_missing_accounts_file() {
    setup_sandbox 1
    rm -f -- "$MPARCHIVE_CONFIG_DIR/mock.json"
    local rc=0 out
    unset MPA_DIE_CODE
    out="$( (mpa_init) 2>&1 )" && rc=0 || rc=$?
    assert_eq "1" "$rc" "mpa_init with missing mock.json must exit 1" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Account file is missing" \
        "error.log must name the missing accounts file" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Cannot load accounts" \
        "error.log must give the clear init error" || return 1
    teardown_sandbox
}

# MPA_DIE_CODE=2 must give exit code 2 from mpa_init.
test_mpa_init_die_code() {
    setup_sandbox 1
    rm -f -- "$MPARCHIVE_CONFIG_DIR/mock.json"
    local rc=0 out
    out="$( (MPA_DIE_CODE=2 mpa_init) 2>&1 )" && rc=0 || rc=$?
    assert_eq "2" "$rc" "mpa_init must use MPA_DIE_CODE=2" || return 1
    teardown_sandbox
}

# A missing provider module must fail with a clear error.log entry.
test_mpa_init_missing_provider_module() {
    setup_sandbox 1
    printf 'PROVIDER=ghost\n' > "$MPARCHIVE_CONFIG_DIR/.env"
    make_accounts_json 1 > "$MPARCHIVE_CONFIG_DIR/ghost.json"
    local rc=0 out
    unset MPA_DIE_CODE
    out="$( (mpa_init) 2>&1 )" && rc=0 || rc=$?
    assert_eq "1" "$rc" "mpa_init with missing provider module must exit 1" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Provider module not found" \
        "error.log must name the missing provider module" || return 1
    teardown_sandbox
}

# A missing .env and a bad PROVIDER value must fail with a clear error.
test_mpa_init_bad_provider_setting() {
    setup_sandbox 1
    local rc=0 out
    unset MPA_DIE_CODE

    rm -f -- "$MPARCHIVE_CONFIG_DIR/.env"
    out="$( (mpa_init) 2>&1 )" && rc=0 || rc=$?
    assert_eq "1" "$rc" "mpa_init without PROVIDER must exit 1" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "PROVIDER is not set" \
        "error.log must say PROVIDER is not set" || return 1

    rc=0
    printf 'PROVIDER=Bad-Name\n' > "$MPARCHIVE_CONFIG_DIR/.env"
    out="$( (mpa_init) 2>&1 )" && rc=0 || rc=$?
    assert_eq "1" "$rc" "mpa_init with invalid PROVIDER must exit 1" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "PROVIDER has an invalid value" \
        "error.log must say PROVIDER is invalid" || return 1
    teardown_sandbox
}

# ---------------------------------------------------------------------
# Run the tests
# ---------------------------------------------------------------------

run_test "config: one account fixture" test_config_one_account_fixture
run_test "config: three account fixture" test_config_three_account_fixture
run_test "config: inactive account is skipped" test_config_inactive_account_skipped
run_test "config: CRLF and tabs fixture" test_config_crlf_and_tabs_fixture
run_test "config: missing file gives rc 1 and error.log" test_config_missing_file
run_test "config: empty accounts array gives rc 1 and error.log" test_config_empty_accounts_array
run_test "config: all accounts inactive gives rc 1" test_config_all_inactive
run_test "config: malformed files give rc 1" test_config_malformed_files
run_test "json: json_get_string" test_json_get_string
run_test "json: json_get_number" test_json_get_number
run_test "json: json_escape" test_json_escape
run_test "json: json_compact" test_json_compact
run_test "names: part_name" test_part_name
run_test "names: part_index_from_name matches" test_part_index_from_name_match
run_test "names: part_index_from_name no match" test_part_index_from_name_no_match
run_test "names: part_index_from_name edge cases" test_part_index_edge_cases
run_test "names: validate_archive_name" test_validate_archive_name
run_test "size: path_total_size and file_size" test_path_total_size_and_file_size
run_test "size: ceil_div and part size math" test_ceil_div_and_part_size
run_test "size: sort_indices is numeric" test_sort_indices_numeric
run_test "size: make_tmpdir" test_make_tmpdir
run_test "env: load_env_file never executes content" test_load_env_file_never_executes
run_test "env: load_env_file quotes and spaces" test_load_env_file_quotes_and_spaces
run_test "env: load_env_file keeps preset value" test_load_env_file_keeps_preset_value
run_test "env: load_env_file missing file" test_load_env_file_missing
run_test "log: log targets and sandbox isolation" test_logging_targets
run_test "log: die exit codes" test_die_exit_codes
run_test "init: mpa_init success in sandbox" test_mpa_init_success
run_test "init: mpa_init missing accounts file" test_mpa_init_missing_accounts_file
run_test "init: mpa_init MPA_DIE_CODE=2" test_mpa_init_die_code
run_test "init: mpa_init missing provider module" test_mpa_init_missing_provider_module
run_test "init: mpa_init bad PROVIDER setting" test_mpa_init_bad_provider_setting

finish_tests
