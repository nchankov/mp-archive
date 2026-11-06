#!/usr/bin/env bash
# Smoke test for the test harness.
# It checks the asserts, the sandbox and the mock provider.
# It does not test the bin/ scripts. QA writes those tests.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Use the real core library when it exists. Otherwise use logging stubs.
if [[ -f "$REPO_ROOT/bin/lib/common.sh" ]]; then
    source "$REPO_ROOT/bin/lib/common.sh"
else
    log_info()  { printf 'stub INFO: %s\n' "$*" >&2; }
    log_error() { printf 'stub ERROR: %s\n' "$*" >&2; }
fi

# Run an assert that must fail. Hide its output and its count.
# Return 0 when the assert failed as expected.
# Args: <assert command> [args...]
_expect_fail() {
    local before="$ASSERT_FAIL_COUNT" rc=0
    "$@" >/dev/null 2>&1 || rc=$?
    ASSERT_FAIL_COUNT="$before"
    (( rc != 0 ))
}

# Check that the passing asserts return 0 and count as passes.
test_assert_helpers_pass() {
    assert_eq "abc" "abc" || return 1
    assert_ne "abc" "abd" || return 1
    assert_contains "hello world" "lo w" || return 1
    assert_not_contains "hello" "xyz" || return 1
    assert_file_exists "$REPO_ROOT/tests/run.sh" || return 1
    assert_file_missing "$REPO_ROOT/tests/does-not-exist" || return 1
    assert_exit_code 0 true || return 1
    assert_exit_code 1 false || return 1
}

# Check that the failing asserts return 1 and print the failure.
test_assert_helpers_detect_failure() {
    _expect_fail assert_eq "a" "b" || return 1
    _expect_fail assert_ne "a" "a" || return 1
    _expect_fail assert_contains "abc" "zzz" || return 1
    _expect_fail assert_not_contains "abc" "b" || return 1
    _expect_fail assert_file_exists "/nonexistent/path/x" || return 1
    _expect_fail assert_file_missing "$REPO_ROOT/tests/run.sh" || return 1
    _expect_fail assert_exit_code 0 false || return 1
}

# Check the sandbox layout and the exported variables.
test_sandbox_layout() {
    setup_sandbox 3
    assert_file_exists "$SANDBOX_DIR/config/.env" || return 1
    assert_eq "PROVIDER=mock" "$(cat "$MPARCHIVE_CONFIG_DIR/.env")" || return 1
    assert_eq "3" "$(grep -c '"name"' "$MPARCHIVE_CONFIG_DIR/mock.json")" || return 1
    assert_contains "$(cat "$MPARCHIVE_CONFIG_DIR/mock.json")" '"token": "fake2"' || return 1
    assert_file_exists "$MPARCHIVE_LOG_DIR" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR" || return 1
    assert_file_exists "$MPARCHIVE_TMPDIR" || return 1
    assert_eq "$REPO_ROOT/tests/mocks/providers" "$MPARCHIVE_PROVIDER_DIR" || return 1
    assert_eq "" "${PROVIDER:-}" "PROVIDER must be unset in the sandbox" || return 1

    # Check that no sandbox path points into the real project.
    assert_not_contains "$MPARCHIVE_CONFIG_DIR" "$REPO_ROOT/" || return 1
    assert_not_contains "$MPARCHIVE_LOG_DIR" "$REPO_ROOT/" || return 1

    local dir="$SANDBOX_DIR"
    teardown_sandbox
    assert_file_missing "$dir" || return 1
    assert_eq "" "${MPARCHIVE_CONFIG_DIR:-}" || return 1
}

# Check the default account count of two.
test_sandbox_default_accounts() {
    setup_sandbox
    assert_eq "2" "$(grep -c '"name"' "$MPARCHIVE_CONFIG_DIR/mock.json")" || return 1
    teardown_sandbox
}

# Check the mock provider round trip: upload, find, list, download, delete.
test_mock_round_trip() {
    setup_sandbox 2
    source "$MPARCHIVE_PROVIDER_DIR/mock.sh"

    local src="$SANDBOX_DIR/local.bin" dest="$SANDBOX_DIR/out.bin"
    printf 'payload-1' > "$src"
    provider_init || return 1

    assert_exit_code 0 provider_upload_file 0 "$src" "arch.p0.tar.gz" || return 1
    assert_exit_code 0 provider_find_file 0 "arch.p0.tar.gz" || return 1
    assert_eq "arch.p0.tar.gz" "$(provider_find_file 0 "arch.p0.tar.gz")" || return 1
    assert_exit_code 1 provider_find_file 0 "missing.tar.gz" || return 1

    # Add a second part and a file that must not be listed.
    provider_upload_file 0 "$src" "arch.p1.tar.gz" || return 1
    provider_upload_file 0 "$src" "other.p0.tar.gz" || return 1
    local listing
    listing="$(provider_list_files 0 arch)"
    assert_contains "$listing" $'arch.p0.tar.gz\tarch.p0.tar.gz' || return 1
    assert_contains "$listing" $'arch.p1.tar.gz\tarch.p1.tar.gz' || return 1
    assert_not_contains "$listing" "other" || return 1

    # Overwrite a file and check the new content.
    printf 'payload-2' > "$src"
    assert_exit_code 0 provider_upload_file 0 "$src" "arch.p0.tar.gz" || return 1
    assert_exit_code 0 provider_download_file 0 "arch.p0.tar.gz" "$dest" || return 1
    assert_eq "payload-2" "$(cat "$dest")" || return 1
    assert_exit_code 1 provider_download_file 0 "missing.tar.gz" "$dest.x" || return 1

    assert_exit_code 0 provider_delete_file 0 "arch.p0.tar.gz" || return 1
    assert_exit_code 1 provider_delete_file 0 "arch.p0.tar.gz" || return 1
    assert_exit_code 1 provider_find_file 0 "arch.p0.tar.gz" || return 1

    # Check that every call was recorded.
    local calls
    calls="$(cat "$MOCK_STORAGE_DIR/calls.log")"
    assert_contains "$calls" "UPLOAD 0 arch.p0.tar.gz" || return 1
    assert_contains "$calls" "DELETE 0 arch.p0.tar.gz" || return 1
    assert_contains "$calls" "LIST 0 arch" || return 1

    teardown_sandbox
}

# Check the free space rules and the failure injection.
test_mock_free_space_and_failures() {
    setup_sandbox 2
    source "$MPARCHIVE_PROVIDER_DIR/mock.sh"

    # Default free space when no setting exists.
    assert_eq "10000000000" "$(provider_get_free_space 0)" || return 1

    # Default setting, then per-account override.
    MOCK_FREE_SPACE_DEFAULT=500
    assert_eq "500" "$(provider_get_free_space 0)" || return 1
    MOCK_FREE_SPACE_0=42
    assert_eq "42" "$(provider_get_free_space 0)" || return 1
    assert_eq "500" "$(provider_get_free_space 1)" || return 1

    # Injected return codes.
    MOCK_FAIL_FIND_0=3
    assert_exit_code 3 provider_find_file 0 "x.p0.tar.gz" || return 1
    MOCK_FAIL_FREE_1=2
    assert_exit_code 2 provider_get_free_space 1 || return 1

    # A missing account folder gives no files and return code 0.
    assert_exit_code 0 provider_list_files 7 arch || return 1
    assert_eq "" "$(provider_list_files 7 arch)" || return 1

    teardown_sandbox
}

run_test "assert helpers pass on good values" test_assert_helpers_pass
run_test "assert helpers fail on bad values" test_assert_helpers_detect_failure
run_test "sandbox layout and exports" test_sandbox_layout
run_test "sandbox default account count" test_sandbox_default_accounts
run_test "mock provider round trip" test_mock_round_trip
run_test "mock free space and failure injection" test_mock_free_space_and_failures

finish_tests
