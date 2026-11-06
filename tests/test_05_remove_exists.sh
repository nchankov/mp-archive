#!/usr/bin/env bash
# Tests for bin/exists.sh and bin/remove.sh.
# The tests run the real scripts as child processes.
# They use the mock provider in a sandbox. They never change the real logs.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Paths of the scripts under test.
EXISTS_SH="$REPO_ROOT/bin/exists.sh"
REMOVE_SH="$REPO_ROOT/bin/remove.sh"

# Real log files of the project. The tests must leave them unchanged.
REAL_ERROR_LOG="$REPO_ROOT/error.log"
REAL_ACTIVITY_LOG="$REPO_ROOT/activity.log"

# Print the state of the real log files.
# Each line shows "absent", or "present" with a checksum of the content.
_real_log_state() {
    local f
    for f in "$REAL_ERROR_LOG" "$REAL_ACTIVITY_LOG"; do
        if [[ -e "$f" ]]; then
            printf '%s present %s\n' "$f" "$(cksum < "$f")"
        else
            printf '%s absent\n' "$f"
        fi
    done
}

# Save the state of the real log files before any test runs.
REAL_LOG_BEFORE="$(_real_log_state)"

# Print the number of lines in a file. Print 0 when the file is missing.
# Args: <path>
_line_count() {
    if [[ -f "$1" ]]; then
        wc -l < "$1" | tr -d ' '
    else
        echo 0
    fi
}

# Print the content of a file. Print nothing when the file is missing.
# Args: <path>
_read_file() {
    if [[ -f "$1" ]]; then
        cat -- "$1"
    fi
}

# Create one empty part file in a mock account folder.
# Args: <account idx> <file name>
seed_part() {
    local dir="$MOCK_STORAGE_DIR/acct$1"
    mkdir -p -- "$dir" || return 1
    : > "$dir/$2"
}

# Run one script as a child process inside the sandbox.
# Set RC to the exit code. Set OUT and OUT_BYTES for stdout.
# Set ERR for stderr. Args: <command> [args...]
run_script() {
    local out_file="$SANDBOX_DIR/stdout.txt" err_file="$SANDBOX_DIR/stderr.txt"
    RC=0
    "$@" >"$out_file" 2>"$err_file" || RC=$?
    OUT="$(cat -- "$out_file")"
    OUT_BYTES="$(wc -c < "$out_file" | tr -d ' ')"
    ERR="$(cat -- "$err_file")"
}

# Pass when stdout is exactly one line with the expected text.
# The line must end with one newline and nothing more.
# Args: <expected line> [label]
assert_stdout_line() {
    local expected="$1" label="${2:-stdout}"
    assert_eq "$expected" "$OUT" "$label text" || return 1
    assert_eq "$(( ${#expected} + 1 ))" "$OUT_BYTES" "$label bytes" || return 1
}

# Pass when stdout is empty.
assert_stdout_empty() {
    assert_eq "0" "$OUT_BYTES" "stdout must be empty" || return 1
}

# Check that exists prints true and exits 0 when a part exists.
test_exists_true_when_part_exists() {
    setup_sandbox 2
    seed_part 1 "b.p0.tar.gz" || return 1

    run_script "$EXISTS_SH" b
    assert_eq "0" "$RC" "exists b exit code" || return 1
    assert_stdout_line "true" "exists b" || return 1
    assert_eq "" "$ERR" "exists b must not write to stderr" || return 1

    teardown_sandbox
}

# Check that exists prints false and exits 1 when no part exists.
# A file that is not a part must not count.
test_exists_false_when_no_part() {
    setup_sandbox 2
    seed_part 0 "other.p0.tar.gz" || return 1
    seed_part 1 "b.txt" || return 1

    run_script "$EXISTS_SH" b
    assert_eq "1" "$RC" "exists b exit code" || return 1
    assert_stdout_line "false" "exists b" || return 1
    assert_eq "" "$ERR" "exists b must not write to stderr" || return 1
    assert_file_missing "$MPARCHIVE_LOG_DIR/error.log" "no error.log on the false path" || return 1

    teardown_sandbox
}

# Check that archive "b" does not match the parts of archive "b1".
test_exists_does_not_match_shared_prefix() {
    setup_sandbox 2
    seed_part 0 "b1.p0.tar.gz" || return 1
    seed_part 1 "b1.p1.tar.gz" || return 1

    run_script "$EXISTS_SH" b
    assert_eq "1" "$RC" "exists b exit code" || return 1
    assert_stdout_line "false" "exists b" || return 1

    # Check that archive b1 is still found.
    run_script "$EXISTS_SH" b1
    assert_eq "0" "$RC" "exists b1 exit code" || return 1
    assert_stdout_line "true" "exists b1" || return 1

    teardown_sandbox
}

# Check that names which the provider lists but which are not parts do not count.
# The mock lists "b.p*.tar.gz", so these names reach the part filter.
test_exists_ignores_non_index_names() {
    setup_sandbox 2
    seed_part 0 "b.pfoo.tar.gz" || return 1
    seed_part 1 "b.p.tar.gz" || return 1

    run_script "$EXISTS_SH" b
    assert_eq "1" "$RC" "exists b exit code" || return 1
    assert_stdout_line "false" "exists b" || return 1

    teardown_sandbox
}

# Check that a provider list error gives exit 2, no stdout and an error.log entry.
test_exists_provider_failure() {
    setup_sandbox 2
    seed_part 1 "b.p0.tar.gz" || return 1
    export MOCK_FAIL_LIST_0=3

    run_script "$EXISTS_SH" b
    assert_eq "2" "$RC" "exists b exit code" || return 1
    assert_stdout_empty || return 1

    local log
    log="$(_read_file "$MPARCHIVE_LOG_DIR/error.log")"
    assert_contains "$log" "[ERROR]" "error.log must have an entry" || return 1
    assert_contains "$log" "Cannot list parts of 'b' in account #0" || return 1

    teardown_sandbox
}

# Check that a missing accounts file gives exit 2 and no stdout.
test_exists_init_failure() {
    setup_sandbox 2
    rm -f -- "$MPARCHIVE_CONFIG_DIR/mock.json" || return 1

    run_script "$EXISTS_SH" b
    assert_eq "2" "$RC" "exists b exit code" || return 1
    assert_stdout_empty || return 1

    local log
    log="$(_read_file "$MPARCHIVE_LOG_DIR/error.log")"
    assert_contains "$log" "[ERROR]" "error.log must have an entry" || return 1

    teardown_sandbox
}

# Check that remove deletes every part of "b" in all accounts and keeps "b1".
test_remove_deletes_all_parts() {
    setup_sandbox 2
    seed_part 0 "b.p0.tar.gz" || return 1
    seed_part 0 "b.p1.tar.gz" || return 1
    seed_part 1 "b.p2.tar.gz" || return 1
    seed_part 1 "b.p10.tar.gz" || return 1
    seed_part 0 "b1.p0.tar.gz" || return 1
    seed_part 1 "b1.p0.tar.gz" || return 1
    seed_part 0 "other.p0.tar.gz" || return 1
    seed_part 0 "b.pfoo.tar.gz" || return 1

    run_script "$REMOVE_SH" b
    assert_eq "0" "$RC" "remove b exit code" || return 1
    assert_stdout_line "4" "remove b count" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct0/b.pfoo.tar.gz" "non-index name must be kept" || return 1

    local acct="$MOCK_STORAGE_DIR"
    assert_file_missing "$acct/acct0/b.p0.tar.gz" || return 1
    assert_file_missing "$acct/acct0/b.p1.tar.gz" || return 1
    assert_file_missing "$acct/acct1/b.p2.tar.gz" || return 1
    assert_file_missing "$acct/acct1/b.p10.tar.gz" || return 1
    assert_file_exists "$acct/acct0/b1.p0.tar.gz" || return 1
    assert_file_exists "$acct/acct1/b1.p0.tar.gz" || return 1
    assert_file_exists "$acct/acct0/other.p0.tar.gz" || return 1

    # Check the activity log for each deleted part.
    local act
    act="$(_read_file "$MPARCHIVE_LOG_DIR/activity.log")"
    assert_contains "$act" "Deleted b.p0.tar.gz from account #0" || return 1
    assert_contains "$act" "Deleted b.p1.tar.gz from account #0" || return 1
    assert_contains "$act" "Deleted b.p2.tar.gz from account #1" || return 1
    assert_contains "$act" "Deleted b.p10.tar.gz from account #1" || return 1
    assert_eq "4" "$(printf '%s\n' "$act" | grep -c ' Deleted ' || true)" \
        "activity.log must have 4 Deleted lines" || return 1

    assert_file_missing "$MPARCHIVE_LOG_DIR/error.log" "no error.log on success" || return 1

    teardown_sandbox
}

# Check that a second remove exits 0, prints 0 and adds no error.log lines.
test_remove_second_run_is_noop() {
    setup_sandbox 2
    seed_part 0 "b.p0.tar.gz" || return 1
    seed_part 1 "b.p1.tar.gz" || return 1

    run_script "$REMOVE_SH" b
    assert_eq "0" "$RC" "first remove exit code" || return 1
    assert_stdout_line "2" "first remove count" || return 1

    local before
    before="$(_line_count "$MPARCHIVE_LOG_DIR/error.log")"

    run_script "$REMOVE_SH" b
    assert_eq "0" "$RC" "second remove exit code" || return 1
    assert_stdout_line "0" "second remove count" || return 1
    assert_eq "$before" "$(_line_count "$MPARCHIVE_LOG_DIR/error.log")" \
        "second remove must not add error.log lines" || return 1

    local act
    act="$(_read_file "$MPARCHIVE_LOG_DIR/activity.log")"
    assert_contains "$act" "No parts of 'b' in account #0" || return 1
    assert_contains "$act" "No parts of 'b' in account #1" || return 1

    teardown_sandbox
}

# Check that a list error in account 0 does not stop account 1.
test_remove_list_failure_continues() {
    setup_sandbox 2
    seed_part 0 "b.p0.tar.gz" || return 1
    seed_part 1 "b.p1.tar.gz" || return 1
    export MOCK_FAIL_LIST_0=2

    run_script "$REMOVE_SH" b
    assert_eq "1" "$RC" "remove b exit code" || return 1
    assert_stdout_line "1" "remove b count" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct0/b.p0.tar.gz" || return 1
    assert_file_missing "$MOCK_STORAGE_DIR/acct1/b.p1.tar.gz" || return 1

    local log
    log="$(_read_file "$MPARCHIVE_LOG_DIR/error.log")"
    assert_contains "$log" "[ERROR]" "error.log must have an entry" || return 1
    assert_contains "$log" "Cannot list parts of 'b' in account #0" || return 1

    teardown_sandbox
}

# Check that a delete error gives exit 1 and keeps the failed part.
test_remove_delete_failure() {
    setup_sandbox 2
    seed_part 0 "b.p0.tar.gz" || return 1
    seed_part 1 "b.p1.tar.gz" || return 1
    export MOCK_FAIL_DELETE_1=2

    run_script "$REMOVE_SH" b
    assert_eq "1" "$RC" "remove b exit code" || return 1
    assert_stdout_line "1" "remove b count" || return 1
    assert_file_missing "$MOCK_STORAGE_DIR/acct0/b.p0.tar.gz" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct1/b.p1.tar.gz" || return 1

    local log
    log="$(_read_file "$MPARCHIVE_LOG_DIR/error.log")"
    assert_contains "$log" "[ERROR]" "error.log must have an entry" || return 1
    assert_contains "$log" "Cannot delete 'b.p1.tar.gz' from account #1 (rc=2)" || return 1

    teardown_sandbox
}

# Check the usage errors of both scripts. Each must exit 2.
test_usage_errors() {
    setup_sandbox 2
    local script name
    for script in "$EXISTS_SH" "$REMOVE_SH"; do
        name="$(basename -- "$script")"

        # No argument.
        run_script "$script"
        assert_eq "2" "$RC" "$name with no args exit code" || return 1
        assert_stdout_empty || return 1
        assert_contains "$ERR" "Usage:" "$name with no args usage" || return 1

        # Two arguments.
        run_script "$script" b c
        assert_eq "2" "$RC" "$name with two args exit code" || return 1
        assert_stdout_empty || return 1
        assert_contains "$ERR" "Usage:" "$name with two args usage" || return 1

        # A name with a slash.
        run_script "$script" "a/b"
        assert_eq "2" "$RC" "$name with a/b exit code" || return 1
        assert_stdout_empty || return 1
        assert_contains "$ERR" "Invalid archive name" "$name with a/b message" || return 1
    done

    teardown_sandbox
}

# Check that the real project logs are unchanged by all tests above.
test_real_logs_unchanged() {
    local after
    after="$(_real_log_state)"
    assert_eq "$REAL_LOG_BEFORE" "$after" "real error.log and activity.log must not change" || return 1
}

run_test "exists true when a part exists" test_exists_true_when_part_exists
run_test "exists false when no part exists" test_exists_false_when_no_part
run_test "exists does not match shared prefix b1" test_exists_does_not_match_shared_prefix
run_test "exists ignores names that are not parts" test_exists_ignores_non_index_names
run_test "exists provider failure gives exit 2" test_exists_provider_failure
run_test "exists init failure gives exit 2" test_exists_init_failure
run_test "remove deletes all parts and keeps b1" test_remove_deletes_all_parts
run_test "remove second run is a no-op" test_remove_second_run_is_noop
run_test "remove list failure continues with next account" test_remove_list_failure_continues
run_test "remove delete failure gives exit 1" test_remove_delete_failure
run_test "usage errors give exit 2" test_usage_errors
run_test "real project logs unchanged" test_real_logs_unchanged

finish_tests
