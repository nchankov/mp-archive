#!/usr/bin/env bash
# Tests for mpa_lower_priority in bin/lib/common.sh (ticket 13).
# The function sets the CPU priority (nice) and the disk priority (ionice).
# Each check runs a probe in a new bash process. The probe changes only its own
# priority, so the test process keeps its priority.
# The integration checks run the real scripts with the mock provider.
# The real error.log and activity.log in the project root must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Paths of the files under test.
COMMON_LIB="$REPO_ROOT/bin/lib/common.sh"
UPLOAD="$REPO_ROOT/bin/upload.sh"
DOWNLOAD="$REPO_ROOT/bin/download.sh"

# Remove the last sandbox when the file ends, even after a failed test.
trap 'teardown_sandbox' EXIT

# ---------------------------------------------------------------------
# Helpers for this file
# ---------------------------------------------------------------------

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

# Write the probe script into the sandbox.
# The probe loads common.sh (argument 1), runs the function,
# and prints rc, nice and ionice for its own process.
write_probe() {
    cat > "$SANDBOX_DIR/probe.sh" <<'EOF'
#!/usr/bin/env bash
# Probe for test_13. Load the library, run the function, print the result.
source "$1" || exit 99
mpa_lower_priority
printf 'rc=%s\n' "$?"
printf 'nice=%s\n' "$(nice 2>/dev/null)"
printf 'ionice=%s\n' "$(ionice -p $$ 2>/dev/null)"
EOF
}

# Create a sandbox with the probe and a small content folder.
new_sandbox() {
    teardown_sandbox
    setup_sandbox 2 || return 1
    PROBE="$SANDBOX_DIR/probe.sh"
    write_probe || return 1
    make_fixture
}

# Build a small content folder for the upload tests.
make_fixture() {
    local src="$SANDBOX_DIR/src/data dir"
    mkdir -p -- "$src" || return 1
    head -c 4000 /dev/urandom > "$src/blob.bin" || return 1
    printf 'notes for the test\n' > "$src/notes.txt" || return 1
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

# Run a command with the priority settings removed from its environment.
# The command starts the probe with the settings that the check needs.
# Sets PROBE_OUT (stdout) and PROBE_ERR (stderr).
# Args: <command> [args...]
run_probe() {
    local err_file="$SANDBOX_DIR/probe-stderr.txt"
    PROBE_OUT="$(env -u MPARCHIVE_NICE -u MPARCHIVE_IONICE_CLASS "$@" 2>"$err_file")"
    PROBE_ERR="$(cat -- "$err_file")"
}

# Print one field of the probe output. Args: <field name>
probe_field() {
    printf '%s\n' "$PROBE_OUT" | sed -n "s/^$1=//p" | tail -n 1
}

# Print the niceness of this test process. Each probe starts from this value.
current_nice() {
    nice 2>/dev/null
}

# Print the disk class of this test process. Each probe starts from this value.
current_ionice() {
    ionice -p $$ 2>/dev/null
}

# Print the text of error.log in the sandbox.
error_log_text() {
    cat -- "$MPARCHIVE_LOG_DIR/error.log" 2>/dev/null
}

# Print the niceness that an upload must have: the current value or 10, the larger one.
expected_upload_nice() {
    local now
    now="$(current_nice)"
    if (( now > 10 )); then
        printf '%s\n' "$now"
    else
        printf '10\n'
    fi
}

# Make a folder of symbolic links to every command in /bin and /usr/bin.
# The names that follow the folder are left out.
# Args: <folder> [excluded command names...]
make_bin_without() {
    local dir="$1" f name skip
    shift
    mkdir -p -- "$dir" || return 1
    for f in /usr/bin/* /bin/*; do
        [[ -f "$f" && -x "$f" ]] || continue
        name="${f##*/}"
        for skip in "$@"; do
            [[ "$name" == "$skip" ]] && continue 2
        done
        [[ -e "$dir/$name" ]] || ln -s -- "$f" "$dir/$name" || return 1
    done
}

# Make a stub command in a folder. The stub is a shell script with one body.
# Args: <folder> <command name> <shell body>
make_stub() {
    mkdir -p -- "$1" || return 1
    printf '#!/bin/sh\n%s\n' "$3" > "$1/$2" || return 1
    chmod 755 -- "$1/$2"
}

# Write a provider module into the sandbox. The module loads the mock provider.
# Before each upload, it records "<nice> <ionice>" of the upload process.
# The record goes to the file in MOCK_NICE_LOG.
make_recording_provider() {
    local dir="$SANDBOX_DIR/providers"
    mkdir -p -- "$dir" || return 1
    cat > "$dir/mock.sh" <<'EOF'
# Test provider. Load the mock and record the priority before each upload.
source "$REPO_ROOT/tests/mocks/providers/mock.sh"
eval "$(declare -f provider_upload_file | sed '1s/^provider_upload_file ()/_recording_real_upload ()/')"
provider_upload_file() {
    printf '%s %s\n' "$(nice 2>/dev/null)" "$(ionice -p $$ 2>/dev/null)" >> "$MOCK_NICE_LOG"
    _recording_real_upload "$@"
}
EOF
    export MPARCHIVE_PROVIDER_DIR="$dir"
}

# ---------------------------------------------------------------------
# Default and custom values
# ---------------------------------------------------------------------

# Pass when the defaults set niceness 10 and the disk class idle.
test_default_values() {
    new_sandbox || return 1
    run_probe bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code with the defaults" || return 1
    assert_eq "10" "$(probe_field nice)" "niceness with the defaults" || return 1
    assert_eq "idle" "$(probe_field ionice)" "disk class with the defaults" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry with the defaults" || return 1
}

# Pass when MPARCHIVE_NICE=5 and MPARCHIVE_IONICE_CLASS=2 set nice 5 and best-effort 7.
test_custom_values() {
    new_sandbox || return 1
    run_probe env MPARCHIVE_NICE=5 MPARCHIVE_IONICE_CLASS=2 bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code with custom values" || return 1
    assert_eq "5" "$(probe_field nice)" "niceness with MPARCHIVE_NICE=5" || return 1
    assert_eq "best-effort: prio 7" "$(probe_field ionice)" "disk class with class 2" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry with custom values" || return 1
}

# ---------------------------------------------------------------------
# Empty values
# ---------------------------------------------------------------------

# Pass when empty values leave the niceness and the disk class unchanged.
test_empty_values_no_change() {
    local base_nice base_io
    new_sandbox || return 1
    base_nice="$(current_nice)"
    base_io="$(current_ionice)"
    run_probe env MPARCHIVE_NICE= MPARCHIVE_IONICE_CLASS= bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code with empty values" || return 1
    assert_eq "$base_nice" "$(probe_field nice)" "niceness stays the same" || return 1
    assert_eq "$base_io" "$(probe_field ionice)" "disk class stays the same" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry with empty values" || return 1
}

# ---------------------------------------------------------------------
# Never raise the priority
# ---------------------------------------------------------------------

# Pass when a process that starts at niceness 15 keeps 15 with MPARCHIVE_NICE=10.
test_never_raises_nice() {
    new_sandbox || return 1
    run_probe nice -n 15 env MPARCHIVE_NICE=10 bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code under nice 15" || return 1
    assert_eq "15" "$(probe_field nice)" "niceness stays 15" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry under nice 15" || return 1
}

# Pass when a process that starts in class idle stays idle with MPARCHIVE_IONICE_CLASS=2.
test_never_leaves_idle_class() {
    new_sandbox || return 1
    run_probe ionice -c 3 env MPARCHIVE_IONICE_CLASS=2 bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code in class idle" || return 1
    assert_eq "idle" "$(probe_field ionice)" "disk class stays idle" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry in class idle" || return 1
}

# ---------------------------------------------------------------------
# Number parsing
# ---------------------------------------------------------------------

# Pass when "08" gives niceness 8 and "010" gives niceness 10. Both are decimal.
test_leading_zero_is_decimal() {
    new_sandbox || return 1
    run_probe env MPARCHIVE_NICE=08 bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code for 08" || return 1
    assert_eq "8" "$(probe_field nice)" "niceness for 08" || return 1
    assert_eq "" "$(error_log_text)" "no error.log entry for 08" || return 1

    run_probe env MPARCHIVE_NICE=010 bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code for 010" || return 1
    assert_eq "10" "$(probe_field nice)" "niceness for 010 is decimal 10, not octal 8" || return 1
}

# ---------------------------------------------------------------------
# Invalid values
# ---------------------------------------------------------------------

# Pass when invalid MPARCHIVE_NICE values return 1, log an error and change nothing.
test_invalid_nice_values_fail() {
    local value base_nice
    new_sandbox || return 1
    base_nice="$(current_nice)"
    for value in 20 -1 abc 100 18446744073709551616; do
        run_probe env MPARCHIVE_NICE="$value" bash "$PROBE" "$COMMON_LIB"
        assert_eq "1" "$(probe_field rc)" "return code for MPARCHIVE_NICE=$value" || return 1
        assert_contains "$(error_log_text)" "MPARCHIVE_NICE must be an integer from 0 to 19 (now: $value)" \
            "error.log text for MPARCHIVE_NICE=$value" || return 1
        assert_eq "$base_nice" "$(probe_field nice)" "niceness stays the same for $value" || return 1
    done
}

# Pass when invalid MPARCHIVE_IONICE_CLASS values return 1 and nothing changes.
# The niceness must stay the same too, because all values are checked first.
test_invalid_ionice_class_fails() {
    local value base_nice base_io
    new_sandbox || return 1
    base_nice="$(current_nice)"
    base_io="$(current_ionice)"
    for value in 1 4; do
        run_probe env MPARCHIVE_IONICE_CLASS="$value" bash "$PROBE" "$COMMON_LIB"
        assert_eq "1" "$(probe_field rc)" "return code for class $value" || return 1
        assert_contains "$(error_log_text)" "MPARCHIVE_IONICE_CLASS must be 2 or 3 (now: $value)" \
            "error.log text for class $value" || return 1
        assert_eq "$base_nice" "$(probe_field nice)" "niceness stays the same for class $value" || return 1
        assert_eq "$base_io" "$(probe_field ionice)" "disk class stays the same for class $value" || return 1
    done
}

# ---------------------------------------------------------------------
# Missing tools and failed changes
# ---------------------------------------------------------------------

# Pass when a missing renice gives a warning, return 0, and the script goes on.
# The disk class is still set, because ionice exists.
test_missing_renice_warns() {
    local base_nice bin
    new_sandbox || return 1
    base_nice="$(current_nice)"
    bin="$SANDBOX_DIR/bin-no-renice"
    make_bin_without "$bin" renice || return 1
    run_probe env PATH="$bin" bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code without renice" || return 1
    assert_eq "$base_nice" "$(probe_field nice)" "niceness stays the same without renice" || return 1
    assert_eq "idle" "$(probe_field ionice)" "disk class is still set without renice" || return 1
    assert_contains "$(error_log_text)" "Warning: renice is not installed" \
        "warning for missing renice" || return 1
}

# Pass when a missing ionice gives a warning, return 0, and the niceness is still set.
test_missing_ionice_warns() {
    local bin
    new_sandbox || return 1
    bin="$SANDBOX_DIR/bin-no-ionice"
    make_bin_without "$bin" ionice || return 1
    run_probe env PATH="$bin" bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code without ionice" || return 1
    assert_eq "10" "$(probe_field nice)" "niceness is still set without ionice" || return 1
    assert_eq "" "$(probe_field ionice)" "no disk class is read without ionice" || return 1
    assert_contains "$(error_log_text)" "Warning: ionice is not installed" \
        "warning for missing ionice" || return 1
}

# Pass when renice exits 0 but does not change the niceness. Expect a warning.
test_renice_no_change_warns() {
    local base_nice stub
    new_sandbox || return 1
    base_nice="$(current_nice)"
    stub="$SANDBOX_DIR/stub-renice-ok"
    make_stub "$stub" renice 'exit 0' || return 1
    run_probe env PATH="$stub:$PATH" bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code when renice does nothing" || return 1
    assert_eq "$base_nice" "$(probe_field nice)" "niceness stays the same" || return 1
    assert_contains "$(error_log_text)" "Warning: cannot set the CPU priority (niceness) to 10." \
        "warning when renice does nothing" || return 1
}

# Pass when renice exits 1. Expect a warning and return 0.
test_renice_failure_warns() {
    local stub
    new_sandbox || return 1
    stub="$SANDBOX_DIR/stub-renice-fail"
    make_stub "$stub" renice 'exit 1' || return 1
    run_probe env PATH="$stub:$PATH" bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code when renice fails" || return 1
    assert_contains "$(error_log_text)" "Warning: cannot set the CPU priority" \
        "warning when renice fails" || return 1
}

# Pass when ionice reads the class but cannot set it. Expect a warning and return 0.
test_ionice_failure_warns() {
    local stub
    new_sandbox || return 1
    stub="$SANDBOX_DIR/stub-ionice-fail"
    make_stub "$stub" ionice 'case "$1" in -p) echo "none: prio 0" ;; *) exit 1 ;; esac' || return 1
    run_probe env PATH="$stub:$PATH" bash "$PROBE" "$COMMON_LIB"
    assert_eq "0" "$(probe_field rc)" "return code when ionice fails" || return 1
    assert_eq "10" "$(probe_field nice)" "niceness is still set when ionice fails" || return 1
    assert_contains "$(error_log_text)" "Warning: cannot set the disk priority" \
        "warning when ionice fails" || return 1
}

# ---------------------------------------------------------------------
# Integration with upload.sh and download.sh
# ---------------------------------------------------------------------

# Pass when upload.sh stops before the provider with an invalid MPARCHIVE_NICE.
test_upload_invalid_nice_dies() {
    new_sandbox || return 1
    run_cmd env -u MPARCHIVE_IONICE_CLASS MPARCHIVE_NICE=20 "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_ne "0" "$RUN_RC" "upload exit code with MPARCHIVE_NICE=20" || return 1
    assert_contains "$(error_log_text)" "The priority settings are not valid" \
        "upload error text" || return 1
    assert_file_missing "$MOCK_STORAGE_DIR/calls.log" "no provider call for an invalid nice" || return 1
}

# Pass when upload.sh stops before the provider with an invalid MPARCHIVE_IONICE_CLASS.
test_upload_invalid_class_dies() {
    new_sandbox || return 1
    run_cmd env -u MPARCHIVE_NICE MPARCHIVE_IONICE_CLASS=1 "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_ne "0" "$RUN_RC" "upload exit code with class 1" || return 1
    assert_contains "$(error_log_text)" "MPARCHIVE_IONICE_CLASS must be 2 or 3" \
        "upload error text for class 1" || return 1
    assert_file_missing "$MOCK_STORAGE_DIR/calls.log" "no provider call for an invalid class" || return 1
}

# Pass when download.sh stops before the provider with an invalid MPARCHIVE_NICE.
test_download_invalid_nice_dies() {
    new_sandbox || return 1
    run_cmd env -u MPARCHIVE_IONICE_CLASS MPARCHIVE_NICE=-1 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_ne "0" "$RUN_RC" "download exit code with MPARCHIVE_NICE=-1" || return 1
    assert_contains "$(error_log_text)" "The priority settings are not valid" \
        "download error text" || return 1
    assert_file_missing "$MOCK_STORAGE_DIR/calls.log" "no provider call for an invalid nice" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no restore folder for an invalid nice" || return 1
}

# Pass when upload.sh runs with no renice. It warns and still stores both parts.
test_upload_without_renice_continues() {
    local bin
    new_sandbox || return 1
    bin="$SANDBOX_DIR/bin-no-renice"
    make_bin_without "$bin" renice || return 1
    run_cmd env -u MPARCHIVE_NICE -u MPARCHIVE_IONICE_CLASS PATH="$bin" \
        "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "upload exit code without renice" || return 1
    assert_contains "$(error_log_text)" "Warning: renice is not installed" \
        "upload warning for missing renice" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct0/backup1.p0.c0.tar.gz" "part 0 is stored" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct1/backup1.p1.c0.tar.gz" "part 1 is stored" || return 1
}

# Pass when a real upload runs at niceness 10 (or higher, when the caller is higher)
# and in disk class idle. The provider records the priority of each upload.
test_upload_runs_at_nice_10() {
    local record expected line count=0 rc=0
    new_sandbox || return 1
    record="$SANDBOX_DIR/priority-seen.txt"
    make_recording_provider || return 1
    expected="$(expected_upload_nice)"

    run_cmd env -u MPARCHIVE_NICE -u MPARCHIVE_IONICE_CLASS MOCK_NICE_LOG="$record" \
        "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1

    while IFS= read -r line; do
        count=$((count + 1))
        assert_eq "$expected idle" "$line" "priority of upload $count" || rc=1
    done < "$record"
    (( rc == 0 )) || return 1
    assert_eq "2" "$count" "one record for each part" || return 1
}

# Pass when the real error.log and activity.log in the project root do not change.
test_real_logs_untouched() {
    assert_eq "$REAL_LOGS_BEFORE" "$(real_logs_state)" "real logs must not change"
}

# ---------------------------------------------------------------------
# Run the tests.
# ---------------------------------------------------------------------

run_test "default values are nice 10 and idle" test_default_values
run_test "custom values are nice 5 and best-effort 7" test_custom_values
run_test "empty values change nothing" test_empty_values_no_change
run_test "nice is never lowered below 15 by MPARCHIVE_NICE=10" test_never_raises_nice
run_test "idle class is never changed by class 2" test_never_leaves_idle_class
run_test "leading zero is decimal (08 and 010)" test_leading_zero_is_decimal
run_test "invalid MPARCHIVE_NICE values fail" test_invalid_nice_values_fail
run_test "invalid MPARCHIVE_IONICE_CLASS values fail" test_invalid_ionice_class_fails
run_test "missing renice warns and continues" test_missing_renice_warns
run_test "missing ionice warns and continues" test_missing_ionice_warns
run_test "renice that changes nothing warns" test_renice_no_change_warns
run_test "renice that fails warns" test_renice_failure_warns
run_test "ionice that fails warns" test_ionice_failure_warns
run_test "upload dies on invalid nice before the provider" test_upload_invalid_nice_dies
run_test "upload dies on invalid class before the provider" test_upload_invalid_class_dies
run_test "download dies on invalid nice before the provider" test_download_invalid_nice_dies
run_test "upload continues without renice" test_upload_without_renice_continues
run_test "upload runs at nice 10 and idle" test_upload_runs_at_nice_10
run_test "real logs untouched" test_real_logs_untouched

# Remove the last sandbox when the file ends, even after a failed test.
teardown_sandbox
finish_tests
