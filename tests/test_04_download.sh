#!/usr/bin/env bash
# Tests for bin/download.sh.
# Each test uses its own sandbox with the mock provider.
# Each test runs the real scripts as child processes.
# The real error.log and activity.log in the project root must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Paths of the scripts under test.
UPLOAD="$REPO_ROOT/bin/upload.sh"
DOWNLOAD="$REPO_ROOT/bin/download.sh"

# Remove the sandbox of an earlier test, if one is left. Then make a new one.
# Args: <account count>
new_sandbox() {
    teardown_sandbox
    setup_sandbox "$1" || return 1
    make_fixture
}

# Build the fixture content inside the sandbox.
# The folder "data dir" holds a file with spaces in its name.
# The file "single.zip" is a second content item.
make_fixture() {
    local src="$SANDBOX_DIR/src"
    mkdir -p -- "$src/data dir" || return 1
    head -c 300000 /dev/urandom > "$src/data dir/Screen Shot 1.png" || return 1
    printf 'notes for the test\n' > "$src/data dir/notes.txt" || return 1
    head -c 300000 /dev/urandom > "$src/single.zip" || return 1
}

# Run one command and keep its exit code and its output.
# Sets RUN_RC (exit code), RUN_OUT (stdout) and RUN_ERR (stderr).
# Args: <command> [args...]
run_cmd() {
    local err_file="$SANDBOX_DIR/stderr.txt"
    RUN_RC=0
    RUN_OUT="$("$@" 2>"$err_file")" || RUN_RC=$?
    RUN_ERR="$(cat -- "$err_file")"
}

# Upload one content item with the real upload script.
# Pass when the upload exits 0.
# Args: <source path> <archive name>
upload_content() {
    run_cmd "$UPLOAD" "$1" "$2"
    assert_eq "0" "$RUN_RC" "upload before download must exit 0" || return 1
}

# Print the SHA-256 hash of one file. Print only the hash.
# Args: <file>
file_hash() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# Print the text of one log file in the sandbox.
# Args: <log file name>
sandbox_log() {
    cat -- "$MPARCHIVE_LOG_DIR/$1" 2>/dev/null
}

# Print the temp folders that the script left behind.
temp_leftovers() {
    find "$MPARCHIVE_TMPDIR" -mindepth 1 -maxdepth 1 -name 'mp-archive.*' -printf '%f\n' 2>/dev/null
}

# Print the state of the real logs in the project root.
# A missing log prints "missing". Otherwise print the size, mtime and hash.
real_logs_state() {
    local name path
    for name in error.log activity.log; do
        path="$REPO_ROOT/$name"
        if [[ -e "$path" ]]; then
            printf '%s: %s %s\n' "$name" "$(stat -c '%s %Y' -- "$path")" \
                "$(file_hash "$path")"
        else
            printf '%s: missing\n' "$name"
        fi
    done
}

# Save the state of the real logs before any test runs.
REAL_LOGS_BEFORE="$(real_logs_state)"
REAL_ACTIVITY_LINES_BEFORE=0
if [[ -f "$REPO_ROOT/activity.log" ]]; then
    REAL_ACTIVITY_LINES_BEFORE="$(wc -l < "$REPO_ROOT/activity.log")"
fi

# Remove the last sandbox when the file ends, even after a failed test.
trap 'teardown_sandbox' EXIT

# Check a directory restore into two targets: one with a trailing slash, one without.
# Args: <account count>
check_dir_round_trip() {
    local n="$1" src
    new_sandbox "$n" || return 1
    src="$SANDBOX_DIR/src/data dir"
    upload_content "$src" backup1 || return 1

    # Trailing slash: the target is "restore/".
    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download to restore/ exit code, N=$n" || return 1
    assert_eq "$SANDBOX_DIR/restore/" "$RUN_OUT" "download prints the target, N=$n" || return 1
    assert_exit_code 0 diff -r -- "$src" "$SANDBOX_DIR/restore/data dir" || return 1

    # No trailing slash: the target does not exist before the download.
    assert_file_missing "$SANDBOX_DIR/restore2" "restore2 must not exist yet" || return 1
    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore2"
    assert_eq "0" "$RUN_RC" "download to restore2 exit code, N=$n" || return 1
    assert_exit_code 0 diff -r -- "$src" "$SANDBOX_DIR/restore2/data dir" || return 1

    assert_eq "" "$(temp_leftovers)" "no temp folder left after success, N=$n" || return 1
}

# Pass when a directory restores with one account.
test_dir_round_trip_one_account() {
    check_dir_round_trip 1
}

# Pass when a directory restores with three accounts, to both target forms.
test_dir_round_trip_three_accounts() {
    check_dir_round_trip 3
}

# Pass when a single file restores with three accounts and the hashes match.
test_single_file_round_trip_three_accounts() {
    local src want
    new_sandbox 3 || return 1
    src="$SANDBOX_DIR/src/single.zip"
    upload_content "$src" backup2.zip || return 1
    want="$(file_hash "$src")"

    run_cmd "$DOWNLOAD" backup2.zip "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download to restore/ exit code" || return 1
    assert_eq "$want" "$(file_hash "$SANDBOX_DIR/restore/single.zip")" \
        "sha256 of restored single file (restore/)" || return 1

    assert_file_missing "$SANDBOX_DIR/restore2" "restore2 must not exist yet" || return 1
    run_cmd "$DOWNLOAD" backup2.zip "$SANDBOX_DIR/restore2"
    assert_eq "0" "$RUN_RC" "download to restore2 exit code" || return 1
    assert_eq "$want" "$(file_hash "$SANDBOX_DIR/restore2/single.zip")" \
        "sha256 of restored single file (restore2)" || return 1

    assert_eq "" "$(temp_leftovers)" "no temp folder left after success" || return 1
}

# Pass when twelve parts restore in numeric order (p0 to p11).
# A lexical order (p0, p1, p10, p11, p2, ...) would corrupt the archive.
test_twelve_part_round_trip() {
    local src
    new_sandbox 12 || return 1
    src="$SANDBOX_DIR/src/data dir"
    upload_content "$src" backup1 || return 1
    assert_eq "12" "$(find "$MOCK_STORAGE_DIR" -mindepth 2 -type f | wc -l)" \
        "twelve stored parts" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code, N=12" || return 1
    assert_exit_code 0 diff -r -- "$src" "$SANDBOX_DIR/restore/data dir" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left after success, N=12" || return 1
}

# Pass when an account added after the upload is skipped and the restore works.
test_account_without_parts_is_skipped() {
    local src
    new_sandbox 2 || return 1
    src="$SANDBOX_DIR/src/data dir"
    upload_content "$src" backup1 || return 1

    # Add a third account. It holds no parts of the archive.
    make_accounts_json 3 > "$MPARCHIVE_CONFIG_DIR/mock.json" || return 1
    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code with an extra account" || return 1
    assert_exit_code 0 diff -r -- "$src" "$SANDBOX_DIR/restore/data dir" || return 1
    assert_contains "$(sandbox_log activity.log)" "Account #2 has no parts of 'backup1'; skip it" \
        "activity.log skip entry" || return 1
}

# Pass when a missing middle part gives exit 1 and an error.log entry.
test_missing_middle_part() {
    new_sandbox 3 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    rm -f -- "$MOCK_STORAGE_DIR/acct1/backup1.p1.c0.tar.gz" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "missing files: part 1" \
        "error.log names the missing part" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left after failure" || return 1
}

# Pass when an archive that exists nowhere gives exit 1 and an error.log entry.
test_archive_absent() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1

    run_cmd "$DOWNLOAD" nothere "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Archive 'nothere' not found in any account" \
        "error.log entry" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder for an absent archive" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left after failure" || return 1
}

# Pass when a provider download failure gives exit 1, an error.log entry and no temp folder.
test_provider_download_failure() {
    new_sandbox 3 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    export MOCK_FAIL_DOWNLOAD_1=2

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Download of 'backup1.p1.c0.tar.gz' from account #1 failed" \
        "error.log entry" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left after failure" || return 1
}

# Pass when a corrupt part is refused by the manifest first, and when the
# manifest is removed, the corrupt part makes the extraction fail with exit 1
# and no temp folder.
test_corrupt_part_extraction_fails() {
    local manifest
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    head -c 50000 /dev/urandom > "$MOCK_STORAGE_DIR/acct0/backup1.p0.c0.tar.gz" || return 1

    # Step 1: the manifest from the upload refuses the changed part.
    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "manifest refusal exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "does not match its manifest" \
        "manifest refusal error.log entry" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after a manifest refusal" || return 1

    # Step 2: remove the manifest, so the extraction check runs.
    manifest="$MPARCHIVE_STATE_DIR/manifests/backup1.manifest"
    assert_file_exists "$manifest" "manifest exists after the upload" || return 1
    rm -f -- "$manifest" || return 1
    rm -f -- "$MPARCHIVE_LOG_DIR/error.log" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Extraction failed" \
        "error.log entry" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left after failure" || return 1
}

# Pass when every usage error exits with code 2.
test_download_usage_errors() {
    new_sandbox 2 || return 1
    run_cmd "$DOWNLOAD"
    assert_eq "2" "$RUN_RC" "no arguments" || return 1
    run_cmd "$DOWNLOAD" backup1
    assert_eq "2" "$RUN_RC" "one argument" || return 1
    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/" extra
    assert_eq "2" "$RUN_RC" "three arguments" || return 1
    run_cmd "$DOWNLOAD" "a/b" "$SANDBOX_DIR/restore/"
    assert_eq "2" "$RUN_RC" "invalid name a/b" || return 1
    run_cmd "$DOWNLOAD" backup1 ""
    assert_eq "2" "$RUN_RC" "empty target" || return 1
    assert_contains "$(sandbox_log error.log)" "Usage error" "error.log usage entry" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after usage errors" || return 1
}

# Pass when the script file is valid bash and has the executable bit.
test_download_script_syntax_and_mode() {
    assert_exit_code 0 bash -n "$DOWNLOAD" || return 1
    assert_eq "yes" "$([[ -x "$DOWNLOAD" ]] && echo yes || echo no)" \
        "bin/download.sh must be executable" || return 1
}

# Pass when the real error.log and activity.log did not change during the run.
# On failure, print the lines that were added to the real activity.log.
test_real_logs_untouched() {
    local after
    after="$(real_logs_state)"
    if [[ "$after" == "$REAL_LOGS_BEFORE" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "real logs must not change" \
        "before: $REAL_LOGS_BEFORE" \
        "after:  $after" \
        "added lines in real activity.log (not from this run's sandbox):" \
        "$(tail -n "+$((REAL_ACTIVITY_LINES_BEFORE + 1))" "$REPO_ROOT/activity.log" 2>/dev/null)"
}

run_test "script syntax and executable bit" test_download_script_syntax_and_mode
run_test "directory round trip with one account" test_dir_round_trip_one_account
run_test "directory round trip with three accounts" test_dir_round_trip_three_accounts
run_test "single file round trip with three accounts" test_single_file_round_trip_three_accounts
run_test "twelve part round trip in numeric order" test_twelve_part_round_trip
run_test "account without parts is skipped" test_account_without_parts_is_skipped
run_test "missing middle part fails" test_missing_middle_part
run_test "absent archive fails" test_archive_absent
run_test "provider download failure" test_provider_download_failure
run_test "corrupt part fails extraction" test_corrupt_part_extraction_fails
run_test "usage errors exit 2" test_download_usage_errors
run_test "real logs untouched" test_real_logs_untouched

finish_tests
