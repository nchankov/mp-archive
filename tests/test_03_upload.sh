#!/usr/bin/env bash
# Tests for bin/upload.sh.
# Each test uses its own sandbox with the mock provider.
# Each test runs the real script as a child process.
# The real error.log and activity.log in the project root must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Path of the script under test.
UPLOAD="$REPO_ROOT/bin/upload.sh"

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

# Print every stored file as "<account>/<name>", sorted. The call log is skipped.
storage_files() {
    find "$MOCK_STORAGE_DIR" -mindepth 2 -type f -printf '%P\n' | LC_ALL=C sort
}

# Print the file names in one account folder, sorted.
# Args: <account index>
account_files() {
    local dir="$MOCK_STORAGE_DIR/acct$1"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort
}

# Print the expected stored files for one archive with N parts.
# Args: <archive name> <part count>
expected_parts() {
    local archive="$1" n="$2" i
    for ((i = 0; i < n; i++)); do
        printf 'acct%d/%s.p%d.tar.gz\n' "$i" "$archive" "$i"
    done | LC_ALL=C sort
}

# Concatenate the stored parts in numeric order into one file.
# Args: <archive name> <part count> <output file>
join_parts() {
    local archive="$1" n="$2" out="$3" i
    : > "$out" || return 1
    for ((i = 0; i < n; i++)); do
        cat -- "$MOCK_STORAGE_DIR/acct$i/$archive.p$i.tar.gz" >> "$out" || return 1
    done
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
                "$(sha256sum -- "$path" | cut -d' ' -f1)"
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

# Check the stored parts and one restore of an upload.
# Args: <archive name> <account count> <member name in the archive>
check_stored_parts() {
    local archive="$1" n="$2" member="$3"
    local joined="$SANDBOX_DIR/check/joined.tar.gz" listing
    mkdir -p -- "$SANDBOX_DIR/check" || return 1

    assert_eq "$(expected_parts "$archive" "$n")" "$(storage_files)" \
        "stored files, N=$n" || return 1
    join_parts "$archive" "$n" "$joined" || return 1
    assert_exit_code 0 gzip -t "$joined" || return 1
    listing="$(tar -tzf "$joined" 2>&1)"
    assert_contains "$listing" "$member" "tar listing, N=$n" || return 1
}

# Check a directory upload with N accounts.
# Args: <account count>
check_dir_upload() {
    local n="$1" total
    new_sandbox "$n" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "exit code, N=$n" || return 1

    # The summary must show the real total of the stored parts.
    total="$(find "$MOCK_STORAGE_DIR" -mindepth 2 -type f -printf '%s\n' \
        | awk '{ sum += $1 } END { print sum + 0 }')"
    assert_contains "$RUN_OUT" "Parts: $n" "summary parts, N=$n" || return 1
    assert_contains "$RUN_OUT" "Total bytes: $total" "summary total, N=$n" || return 1

    check_stored_parts backup1 "$n" "data dir/Screen Shot 1.png" || return 1
}

# Pass when one account gives one part with the right name.
test_upload_one_account() {
    check_dir_upload 1
}

# Pass when two accounts give two parts in numeric order.
test_upload_two_accounts() {
    check_dir_upload 2
}

# Pass when three accounts give three parts in numeric order.
test_upload_three_accounts() {
    check_dir_upload 3
}

# Pass when a single file uploads as three parts that restore to the file.
test_upload_single_file_three_accounts() {
    new_sandbox 3 || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/single.zip" backup2.zip
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    check_stored_parts backup2.zip 3 "single.zip" || return 1
}

# Pass when a relative path with a trailing slash uploads the same parts.
test_upload_relative_path_trailing_slash() {
    local rc=0
    new_sandbox 2 || return 1
    ( cd -- "$SANDBOX_DIR/src" && "$UPLOAD" "./data dir/" backup1 ) >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "exit code with relative path" || return 1
    check_stored_parts backup1 2 "data dir/Screen Shot 1.png" || return 1
}

# Pass when the script file is valid bash and has the executable bit.
test_upload_script_syntax_and_mode() {
    assert_exit_code 0 bash -n "$UPLOAD" || return 1
    assert_eq "yes" "$([[ -x "$UPLOAD" ]] && echo yes || echo no)" \
        "bin/upload.sh must be executable" || return 1
}

# Pass when too little space on one account stops the upload before any upload.
test_upload_insufficient_space() {
    new_sandbox 2 || return 1
    export MOCK_FREE_SPACE_1=10
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_ne "0" "$RUN_RC" "exit code must be non-zero" || return 1

    local errlog
    errlog="$(sandbox_log error.log)"
    assert_contains "$errlog" "not enough free space" "error.log entry" || return 1
    assert_contains "$errlog" "Account #1 has 10 bytes free" "error.log account line" || return 1

    # No upload call may happen. The free space calls are allowed.
    assert_not_contains "$(cat -- "$MOCK_STORAGE_DIR/calls.log" 2>/dev/null)" "UPLOAD" \
        "no upload call" || return 1
    assert_eq "" "$(storage_files)" "no stored files" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when a failed free space query stops the upload with exit 1.
test_upload_free_space_query_failure() {
    new_sandbox 2 || return 1
    export MOCK_FAIL_FREE_0=3
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Cannot get the free space of account #0" \
        "error.log entry" || return 1
    assert_eq "" "$(storage_files)" "no stored files" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when an upload failure gives exit 1, an error.log entry and no temp folder.
test_upload_provider_failure() {
    new_sandbox 3 || return 1
    export MOCK_FAIL_UPLOAD_1=2
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Upload of part 1 to account #1 failed" \
        "error.log entry" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when a re-upload with fewer accounts removes the stale parts of other indices.
test_upload_stale_parts_removed() {
    new_sandbox 3 || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "first upload exit code" || return 1

    # Use two accounts now. Seed a stale part in account 0 as an older run could leave.
    make_accounts_json 2 > "$MPARCHIVE_CONFIG_DIR/mock.json" || return 1
    printf 'stale part\n' > "$MOCK_STORAGE_DIR/acct0/backup1.p1.tar.gz" || return 1

    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "second upload exit code" || return 1
    assert_eq "backup1.p0.tar.gz" "$(account_files 0)" "account 0 holds only p0" || return 1
    assert_eq "backup1.p1.tar.gz" "$(account_files 1)" "account 1 holds only p1" || return 1
    assert_contains "$(sandbox_log activity.log)" "Removed old part 'backup1.p1.tar.gz' from account #0" \
        "activity.log removal entry" || return 1
}

# Pass when a second upload of the same name overwrites the parts and exits 0.
test_upload_reupload_overwrites() {
    local old new
    new_sandbox 2 || return 1
    old="$SANDBOX_DIR/check/old-p0.tar.gz"
    new="$SANDBOX_DIR/check/new-p0.tar.gz"
    mkdir -p -- "$SANDBOX_DIR/check" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "first upload exit code" || return 1
    cp -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" "$old" || return 1

    # Change the content, then upload the same name again.
    printf 'changed text\n' >> "$SANDBOX_DIR/src/data dir/notes.txt" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "second upload exit code" || return 1
    cp -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" "$new" || return 1
    assert_exit_code 1 cmp -s -- "$old" "$new" || return 1
    check_stored_parts backup1 2 "data dir/Screen Shot 1.png" || return 1
}

# Pass when every usage error exits with code 2 and writes no part.
test_upload_usage_errors() {
    new_sandbox 2 || return 1
    run_cmd "$UPLOAD"
    assert_eq "2" "$RUN_RC" "no arguments" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir"
    assert_eq "2" "$RUN_RC" "one argument" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1 extra
    assert_eq "2" "$RUN_RC" "three arguments" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/does-not-exist" backup1
    assert_eq "2" "$RUN_RC" "missing path" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" "a/b"
    assert_eq "2" "$RUN_RC" "invalid name a/b" || return 1
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" ""
    assert_eq "2" "$RUN_RC" "empty name" || return 1
    assert_contains "$(sandbox_log error.log)" "Usage error" "error.log usage entry" || return 1
    assert_eq "" "$(storage_files)" "no stored files" || return 1
}

# Pass when the real error.log and activity.log did not change during the run.
# On failure, print the lines that were added to the real logs.
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

run_test "script syntax and executable bit" test_upload_script_syntax_and_mode
run_test "upload one account" test_upload_one_account
run_test "upload two accounts" test_upload_two_accounts
run_test "upload three accounts" test_upload_three_accounts
run_test "upload single file with three accounts" test_upload_single_file_three_accounts
run_test "upload relative path with trailing slash" test_upload_relative_path_trailing_slash
run_test "insufficient free space stops upload" test_upload_insufficient_space
run_test "free space query failure" test_upload_free_space_query_failure
run_test "provider upload failure" test_upload_provider_failure
run_test "stale parts removed on re-upload" test_upload_stale_parts_removed
run_test "re-upload overwrites parts" test_upload_reupload_overwrites
run_test "usage errors exit 2" test_upload_usage_errors
run_test "real logs untouched" test_real_logs_untouched

finish_tests
