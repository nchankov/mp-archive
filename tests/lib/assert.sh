#!/usr/bin/env bash
# Assert helpers and test counters for the mp-archive test suite.
# Source this file. Do not execute it.
#
# Each assert returns 0 on pass and 1 on fail.
# A failed assert prints expected and actual values to stderr.

# Counters. The asserts and run_test update these.
ASSERT_PASS_COUNT=0
ASSERT_FAIL_COUNT=0
TEST_PASS_COUNT=0
TEST_FAIL_COUNT=0

# Count one passing assert.
_assert_pass() {
    ASSERT_PASS_COUNT=$((ASSERT_PASS_COUNT + 1))
}

# Count one failing assert and print its details.
# Args: <headline> [detail lines...]
_assert_fail() {
    local headline="$1"
    local line
    ASSERT_FAIL_COUNT=$((ASSERT_FAIL_COUNT + 1))
    printf '    ASSERT FAILED: %s\n' "$headline" >&2
    shift
    for line in "$@"; do
        printf '      %s\n' "$line" >&2
    done
    return 1
}

# Pass when both values are equal.
# Args: <expected> <actual> [label]
assert_eq() {
    local expected="$1" actual="$2" label="${3:-assert_eq}"
    if [[ "$expected" == "$actual" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "expected: [$expected]" "actual:   [$actual]"
}

# Pass when both values differ.
# Args: <not_expected> <actual> [label]
assert_ne() {
    local unexpected="$1" actual="$2" label="${3:-assert_ne}"
    if [[ "$unexpected" != "$actual" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "value must not be: [$unexpected]" "actual:   [$actual]"
}

# Pass when the haystack contains the needle.
# Args: <haystack> <needle> [label]
assert_contains() {
    local haystack="$1" needle="$2" label="${3:-assert_contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "expected to contain: [$needle]" "haystack:         [$haystack]"
}

# Pass when the haystack does not contain the needle.
# Args: <haystack> <needle> [label]
assert_not_contains() {
    local haystack="$1" needle="$2" label="${3:-assert_not_contains}"
    if [[ "$haystack" != *"$needle"* ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "must not contain: [$needle]" "haystack:         [$haystack]"
}

# Pass when the path exists (file or directory).
# Args: <path> [label]
assert_file_exists() {
    local path="$1" label="${2:-assert_file_exists}"
    if [[ -e "$path" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "path does not exist: $path"
}

# Pass when the path does not exist.
# Args: <path> [label]
assert_file_missing() {
    local path="$1" label="${2:-assert_file_missing}"
    if [[ ! -e "$path" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "path must not exist: $path"
}

# Pass when the command exits with the expected code.
# The command runs in a subshell. Its output is captured.
# Args: <expected_code> <command> [args...]
assert_exit_code() {
    local expected="$1" output="" rc=0
    shift
    output="$("$@" 2>&1)" || rc=$?
    if [[ "$rc" == "$expected" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "exit code of: $*" "expected exit: $expected" "actual exit:   $rc" "output: $output"
}

# Run one test function and count the result.
# A test passes when it returns 0 and no assert fails inside it.
# Args: <test name> <function name>
run_test() {
    local name="$1" fn="$2" rc=0 fails_before="$ASSERT_FAIL_COUNT"
    "$fn" || rc=$?
    if (( rc == 0 && ASSERT_FAIL_COUNT == fails_before )); then
        TEST_PASS_COUNT=$((TEST_PASS_COUNT + 1))
        printf 'PASS  %s\n' "$name"
    else
        TEST_FAIL_COUNT=$((TEST_FAIL_COUNT + 1))
        printf 'FAIL  %s (return code %s)\n' "$name" "$rc"
    fi
}

# Print the summary and exit. Exit 1 when any test or assert failed.
# Call this as the last line of a test file.
finish_tests() {
    printf '\nTests: %d passed, %d failed | Asserts: %d passed, %d failed\n' \
        "$TEST_PASS_COUNT" "$TEST_FAIL_COUNT" "$ASSERT_PASS_COUNT" "$ASSERT_FAIL_COUNT"
    if (( TEST_FAIL_COUNT > 0 || ASSERT_FAIL_COUNT > 0 )); then
        exit 1
    fi
    exit 0
}
