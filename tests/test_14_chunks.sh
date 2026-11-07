#!/usr/bin/env bash
# Tests for the chunk format of the storage files.
# A part is cut in chunks. Each chunk is one remote file:
#   chunk j of part k: "<archive>.p<k>.c<j>.tar.gz"
# Older versions wrote one file for each part: "<archive>.p<k>.tar.gz".
# The tests run the real scripts as child processes, with the mock provider.
# Each test uses its own sandbox. The real error.log and activity.log must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Load the library. The name tests call its functions directly.
source "$REPO_ROOT/bin/lib/common.sh"

# Paths of the scripts under test.
UPLOAD="$REPO_ROOT/bin/upload.sh"
DOWNLOAD="$REPO_ROOT/bin/download.sh"
EXISTS_SH="$REPO_ROOT/bin/exists.sh"
REMOVE_SH="$REPO_ROOT/bin/remove.sh"

# Remove the last sandbox when the file ends, even after a failed test.
trap 'teardown_sandbox' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a new sandbox with N accounts and the content folders.
# The big folder holds 300 KB of random bytes. The small folder holds 600 bytes.
# Args: <account count>
new_sandbox() {
    teardown_sandbox
    setup_sandbox "$1" || return 1
    # Remove the settings of the scripts that the caller may have exported.
    unset MPARCHIVE_CHUNK_MAX_BYTES MPARCHIVE_PART_MAX_BYTES \
        MPARCHIVE_RESTORE_MAX_BYTES MPARCHIVE_RESTORE_MAX_INODES MPARCHIVE_REQUIRE_MANIFEST
    BIG_SRC="$SANDBOX_DIR/src/big dir"
    SMALL_SRC="$SANDBOX_DIR/src/small dir"
    mkdir -p -- "$BIG_SRC" "$SMALL_SRC" || return 1
    head -c 300000 /dev/urandom > "$BIG_SRC/data.bin" || return 1
    head -c 300000 /dev/urandom > "$SANDBOX_DIR/src/single.zip" || return 1
    head -c 600 /dev/urandom > "$SMALL_SRC/blob.bin" || return 1
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

# Print the value of one line of the upload summary, for example "Total bytes".
# Args: <label>
summary_value() {
    sed -n "s/^$1: //p" <<<"$RUN_OUT"
}

# Print the text of one log file in the sandbox.
# Args: <log file name>
sandbox_log() {
    cat -- "$MPARCHIVE_LOG_DIR/$1" 2>/dev/null
}

# Print the mock call log. It is empty when no call was made.
call_log() {
    cat -- "$MOCK_STORAGE_DIR/calls.log" 2>/dev/null
}

# Print the sorted file names in one account folder.
# Args: <account index>
account_names() {
    local dir="$MOCK_STORAGE_DIR/acct$1"
    [[ -d "$dir" ]] || return 0
    find "$dir" -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort
}

# Print the number of stored files in all accounts.
stored_count() {
    find "$MOCK_STORAGE_DIR" -mindepth 2 -type f | wc -l | tr -d ' '
}

# Print the number of stored files of one archive. Only "<archive>.p" names count.
# Args: <archive name>
archive_count() {
    find "$MOCK_STORAGE_DIR" -mindepth 2 -type f -name "$1.p*" | wc -l | tr -d ' '
}

# Print the number of stored files with zero bytes.
stored_empty_count() {
    find "$MOCK_STORAGE_DIR" -mindepth 2 -type f -size 0 | wc -l | tr -d ' '
}

# Print the temp folders that the script left behind.
temp_leftovers() {
    find "$MPARCHIVE_TMPDIR" -mindepth 1 -maxdepth 1 -name 'mp-archive.*' -printf '%f\n' 2>/dev/null
}

# Print the SHA-256 hash of one file. Print only the hash.
# Args: <file>
file_hash() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# Check the chunks of every part of one archive.
# upload.sh cuts part k of ceil(total / N) bytes. Each chunk has the chunk
# name and the size that the limit of the account gives. The last chunk is
# the rest. The account holds no other file of the archive.
# Args: <archive> <account count> <archive bytes> <limit of account 0> <limit of account 1> ...
# A limit of 0 means no chunk limit for that account.
check_layout() {
    local archive="$1" n="$2" total="$3" k j start len step count clen size expected part_bytes
    local -a lim
    shift 3
    lim=("$@")
    part_bytes=$(( (total + n - 1) / n ))
    for ((k = 0; k < n; k++)); do
        start=$((k * part_bytes))
        len=$((total - start))
        ((len > part_bytes)) && len=$part_bytes
        ((len < 0)) && len=0
        step="${lim[k]:-0}"
        if ((step == 0 || step > len)); then
            step="$len"
        fi
        # An empty part has one chunk with zero bytes.
        count=1
        if ((len > 0)); then
            count=$(( (len + step - 1) / step ))
        fi
        expected=""
        for ((j = 0; j < count; j++)); do
            clen=$((len - j * step))
            ((clen > step)) && clen="$step"
            expected+="$(chunk_name "$archive" "$k" "$j")"$'\n'
            size="$(file_size "$MOCK_STORAGE_DIR/acct$k/$(chunk_name "$archive" "$k" "$j")")"
            assert_eq "$clen" "$size" "size of chunk $j of part $k" || return 1
        done
        # account_names sorts the names as text, so sort the expected names the same way.
        assert_eq "$(printf '%s' "$expected" | LC_ALL=C sort)" "$(account_names "$k")" \
            "file names of account $k" || return 1
    done
}

# Print N zeros, one for each account, as limits for check_layout.
# Args: <account count>
no_limits() {
    local i
    for ((i = 0; i < $1; i++)); do
        printf '0 '
    done
}

# Pass when the file name is not a file of the archive.
# part_parse_name must return 1 and print nothing.
# Args: <archive> <file name>
assert_no_part() {
    local out rc=0
    out="$(part_parse_name "$1" "$2" 2>/dev/null)" || rc=$?
    if [[ "$rc" == "1" && -z "$out" ]]; then
        _assert_pass
        return 0
    fi
    _assert_fail "name must not match archive [$1]: [$2]" "return code: $rc" "output: [$out]"
}

# Real logs check. Save the state before the tests and compare it at the end.
real_logs_state() {
    local name path
    for name in error.log activity.log; do
        path="$REPO_ROOT/$name"
        if [[ -e "$path" ]]; then
            printf '%s: %s %s\n' "$name" "$(stat -c '%s %Y' -- "$path")" "$(file_hash "$path")"
        else
            printf '%s: missing\n' "$name"
        fi
    done
}
REAL_LOGS_BEFORE="$(real_logs_state)"

# ---------------------------------------------------------------------------
# Names: part_name, chunk_name, part_parse_name, part_index_from_name
# ---------------------------------------------------------------------------

# Pass when both name formats are built and read as the spec says.
test_names_both_formats() {
    assert_eq "backup1.p3.c12.tar.gz" "$(chunk_name backup1 3 12)" || return 1
    assert_eq "backup1.p3.tar.gz" "$(part_name backup1 3)" || return 1
    assert_eq "3 12 c" "$(part_parse_name backup1 backup1.p3.c12.tar.gz)" "chunk name" || return 1
    assert_eq "3 0 p" "$(part_parse_name backup1 backup1.p3.tar.gz)" "old format name" || return 1
    assert_eq "0 0 c" "$(part_parse_name backup1 backup1.p0.c0.tar.gz)" "chunk 0 of part 0" || return 1
    assert_eq "3" "$(part_index_from_name backup1 backup1.p3.c12.tar.gz)" "index of a chunk" || return 1
    assert_eq "3" "$(part_index_from_name backup1 backup1.p3.tar.gz)" "index of an old file" || return 1
}

# Pass when the largest 9-digit numbers are read. A chunk name with leading
# zeros is not a chunk, because download.sh asks for the exact name.
# An old name with leading zeros is decimal.
test_names_numbers() {
    local name
    assert_eq "999999999 999999999 c" \
        "$(part_parse_name backup1 backup1.p999999999.c999999999.tar.gz)" "9 digits" || return 1
    for name in backup1.p08.c010.tar.gz backup1.p0.c00.tar.gz backup1.p00.c0.tar.gz backup1.p1.c01.tar.gz; do
        if part_parse_name backup1 "$name" >/dev/null; then
            echo "          ASSERT FAILED: $name must not be a chunk name"
            return 1
        fi
    done
    assert_eq "7 0 p" "$(part_parse_name backup1 backup1.p007.tar.gz)" \
        "leading zeros in an old name" || return 1
}

# Pass when names of other archives and bad names are not parts of the archive "x".
test_names_reject_other_names() {
    local name
    for name in \
        "x.p0.p0.tar.gz" \
        "x.part3.p0.tar.gz" \
        "x.part3.c0.tar.gz" \
        "xp0.tar.gz" \
        "y.p0.c0.tar.gz" \
        "x.p.c0.tar.gz" \
        "x.p.tar.gz" \
        "x.p0.c.tar.gz" \
        "x.p0.cx.tar.gz" \
        "x.p0.c.tar.gz.bak" \
        "x.p0.c0.tar.gz.bak" \
        "x.p0.c0" \
        "x.p0.tar.gzX" \
        "x.pa.c0.tar.gz" \
        "x.p0c0.tar.gz" \
        "x.p0.c0.p0.tar.gz" \
        "x.p0-c0.tar.gz" \
        "x.p1234567890.tar.gz" \
        "x.p1234567890.c0.tar.gz" \
        "x.p0.c1234567890.tar.gz"; do
        assert_no_part x "$name" || return 1
    done
    # The empty archive name and the empty file name never match.
    assert_no_part "" "x.p0.tar.gz" || return 1
    assert_no_part x "" || return 1
}

# Pass when an archive with a longer name does not match the files of the shorter name.
test_names_other_archive_prefix() {
    # The file belongs to "x.p0", so it is not a file of "x".
    assert_no_part x "x.p0.p0.c0.tar.gz" || return 1
    assert_no_part x "x.p0.p0.tar.gz" || return 1
    # The file "x.p0.c0.tar.gz" belongs to "x". It is not a file of "x.p0".
    assert_no_part x.p0 "x.p0.c0.tar.gz" || return 1
    assert_no_part x.p0 "x.p0.tar.gz" || return 1
    # The file "x.p0.p0.c0.tar.gz" belongs to "x.p0".
    assert_eq "0 0 c" "$(part_parse_name x.p0 x.p0.p0.c0.tar.gz)" "file of x.p0" || return 1
}

# ---------------------------------------------------------------------------
# Chunk sizes
# ---------------------------------------------------------------------------

# Pass when every chunk of a 300 KB upload is at most the provider limit.
# Each part has more than one chunk, and the summary and the call log agree.
test_chunk_sizes_with_provider_limit() {
    local total
    new_sandbox 2 || return 1
    export MOCK_MAX_FILE_DEFAULT=50000
    run_cmd "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    total="$(summary_value "Total bytes")"
    assert_eq "1" "$(( total > 100000 ))" "archive is larger than 100000 bytes" || return 1
    check_layout backup1 2 "$total" 50000 50000 || return 1
    assert_eq "$(stored_count)" "$(summary_value "Files")" "summary file count" || return 1
    assert_contains "$(call_log)" "MAXFILE 0 -" "limit is asked for account 0" || return 1
    assert_contains "$(call_log)" "MAXFILE 1 -" "limit is asked for account 1" || return 1
}

# Pass when each account uses its own limit: 40 KB for account 0 and 90 KB for account 1.
# The account with the smaller limit has more chunks.
test_chunk_sizes_per_account_limits() {
    local total c0 c1
    new_sandbox 2 || return 1
    export MOCK_MAX_FILE_0=40000 MOCK_MAX_FILE_1=90000
    run_cmd "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 40000 90000 || return 1
    c0="$(account_names 0 | wc -l)"
    c1="$(account_names 1 | wc -l)"
    assert_eq "1" "$(( c0 > c1 ))" "account 0 has more chunks than account 1" || return 1
}

# Pass when the chunk setting is used if it is smaller than the provider limit.
test_chunk_setting_smaller_than_provider() {
    local total
    new_sandbox 2 || return 1
    export MOCK_MAX_FILE_DEFAULT=90000
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=30000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 30000 30000 || return 1
}

# Pass when the provider limit is used if the chunk setting is larger.
test_chunk_setting_larger_than_provider() {
    local total
    new_sandbox 2 || return 1
    export MOCK_MAX_FILE_DEFAULT=50000
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=200000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 50000 50000 || return 1
}

# Pass when "010" is ten bytes and "08" is eight bytes. Leading zeros are not octal.
test_chunk_setting_leading_zeros_are_decimal() {
    local total
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=010 "$UPLOAD" "$SMALL_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code with 010" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 10 10 || return 1

    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=08 "$UPLOAD" "$SMALL_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code with 08" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 8 8 || return 1
}

# Pass when 0, 00, abc, -5, 1.5 and 19 digits stop the upload before any upload call.
# An empty value means no chunk setting, so it is not an error.
test_chunk_setting_invalid_values_die() {
    local v
    new_sandbox 2 || return 1
    for v in 0 00 abc -5 1.5 1000000000000000000; do
        run_cmd env MPARCHIVE_CHUNK_MAX_BYTES="$v" "$UPLOAD" "$BIG_SRC" backup1
        assert_eq "1" "$RUN_RC" "exit code with value [$v]" || return 1
        assert_contains "$(sandbox_log error.log)" \
            "MPARCHIVE_CHUNK_MAX_BYTES must be an integer of 1 or more" \
            "error.log text with value [$v]" || return 1
    done
    assert_not_contains "$(call_log)" "UPLOAD" "no upload call" || return 1
    assert_eq "0" "$(stored_count)" "no stored files" || return 1
}

# Pass when 18 digits are accepted. The limit is then larger than any part.
test_chunk_setting_18_digits_accepted() {
    local total
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=999999999999999999 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code with 18 digits" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 0 0 || return 1
}

# Pass when an empty chunk setting means no limit: one chunk for each part.
test_chunk_setting_empty_means_no_limit() {
    local total
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES= "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code with an empty value" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 0 0 || return 1
}

# Pass when a provider without provider_get_max_file_size gives one chunk for each part.
# The wrapper loads the mock and removes the optional function.
test_provider_without_size_function_one_chunk() {
    local pdir total
    new_sandbox 2 || return 1
    pdir="$SANDBOX_DIR/provider-no-size"
    mkdir -p -- "$pdir" || return 1
    printf 'source "%s"\nunset -f provider_get_max_file_size\n' \
        "$REPO_ROOT/tests/mocks/providers/mock.sh" > "$pdir/mock.sh" || return 1
    run_cmd env MPARCHIVE_PROVIDER_DIR="$pdir" "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    total="$(summary_value "Total bytes")"
    check_layout backup1 2 "$total" 0 0 || return 1
    assert_not_contains "$(call_log)" "MAXFILE" "no size call" || return 1
}

# Pass when an empty part gets chunk 0 with zero bytes.
# With 100 accounts and a 600 byte file, the last parts hold no bytes.
test_empty_part_gets_chunk_zero() {
    local total
    new_sandbox 100 || return 1
    run_cmd "$UPLOAD" "$SMALL_SRC" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    assert_eq "100" "$(summary_value "Parts")" "summary parts" || return 1
    total="$(summary_value "Total bytes")"
    assert_eq "1" "$(( $(stored_empty_count) > 0 ))" "some parts are empty" || return 1
    check_layout backup1 100 "$total" $(no_limits 100) || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code" || return 1
    assert_exit_code 0 diff -r -- "$SMALL_SRC" "$SANDBOX_DIR/restore/small dir" || return 1
}

# Pass when more than 10000 chunks in one part stop the upload before any upload call.
# The part of about 150 KB with a 1 byte limit needs 150000 chunks.
test_too_many_chunks_dies_before_upload() {
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=1 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "the maximum is 10000" "error.log text" || return 1
    assert_not_contains "$(call_log)" "UPLOAD" "no upload call" || return 1
    assert_eq "0" "$(stored_count)" "no stored files" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when the provider refuses the size query. The upload stops before any upload call.
test_maxfile_failure_stops_before_upload() {
    new_sandbox 2 || return 1
    export MOCK_FAIL_MAXFILE_1=2
    run_cmd "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Cannot get the largest file size of account #1" \
        "error.log text" || return 1
    assert_not_contains "$(call_log)" "UPLOAD" "no upload call" || return 1
    assert_eq "0" "$(stored_count)" "no stored files" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# ---------------------------------------------------------------------------
# Round trips
# ---------------------------------------------------------------------------

# Pass when a restore of many chunks is byte-identical.
# With 10000 bytes per chunk, each part has 15 chunks. Lexical order would fail.
test_round_trip_many_chunks_identical() {
    local want
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=10000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    assert_eq "1" "$(( $(account_names 0 | wc -l) > 10 ))" "part 0 has more than 10 chunks" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code" || return 1
    assert_exit_code 0 diff -r -- "$BIG_SRC" "$SANDBOX_DIR/restore/big dir" || return 1
    assert_eq "" "$(sandbox_log error.log)" "no warning for a clean restore" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1

    # A single file with three accounts and many chunks restores with the same hash.
    want="$(file_hash "$SANDBOX_DIR/src/single.zip")"
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=10000 "$UPLOAD" "$SANDBOX_DIR/src/single.zip" backup2.zip
    assert_eq "0" "$RUN_RC" "upload of the single file" || return 1
    run_cmd "$DOWNLOAD" backup2.zip "$SANDBOX_DIR/restore2/"
    assert_eq "0" "$RUN_RC" "download of the single file" || return 1
    assert_eq "$want" "$(file_hash "$SANDBOX_DIR/restore2/single.zip")" "sha256 of the single file" || return 1
}

# Pass when the size limit of the download applies to each chunk file.
test_download_part_size_limit_per_chunk() {
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1

    run_cmd env MPARCHIVE_PART_MAX_BYTES=100 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code with a 100 byte limit" || return 1
    assert_contains "$(sandbox_log error.log)" "the limit is 100. Nothing is restored." \
        "error.log text" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after the refusal" || return 1

    run_cmd env MPARCHIVE_PART_MAX_BYTES=20000 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "exit code with a 20000 byte limit" || return 1
    assert_exit_code 0 diff -r -- "$BIG_SRC" "$SANDBOX_DIR/restore/big dir" || return 1
}

# ---------------------------------------------------------------------------
# Re-upload and old files
# ---------------------------------------------------------------------------

# Pass when a re-upload with fewer chunks removes the higher chunks and the old files
# of this archive. Files of other archives stay, even when their names look alike.
test_reupload_removes_only_stale_files_of_the_archive() {
    local want0 want1
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" bk
    assert_eq "0" "$RUN_RC" "first upload of bk" || return 1
    # The archive "bk.p0" is another archive. Its files look like parts of "bk".
    run_cmd "$UPLOAD" "$BIG_SRC" "bk.p0"
    assert_eq "0" "$RUN_RC" "upload of bk.p0" || return 1

    # Old file of "bk.p0", a file that is not a chunk, and an old file of "bk" in account 0.
    printf 'old\n' > "$MOCK_STORAGE_DIR/acct0/bk.p0.p0.tar.gz" || return 1
    printf 'other\n' > "$MOCK_STORAGE_DIR/acct0/bk.p0.c0.x.tar.gz" || return 1
    printf 'old\n' > "$MOCK_STORAGE_DIR/acct0/bk.p1.tar.gz" || return 1

    # The second upload uses one chunk for each part.
    run_cmd "$UPLOAD" "$BIG_SRC" bk
    assert_eq "0" "$RUN_RC" "second upload of bk" || return 1

    want0="$(printf '%s\n' bk.p0.c0.tar.gz bk.p0.c0.x.tar.gz bk.p0.p0.c0.tar.gz bk.p0.p0.tar.gz | LC_ALL=C sort)"
    want1="$(printf '%s\n' bk.p0.p1.c0.tar.gz bk.p1.c0.tar.gz | LC_ALL=C sort)"
    assert_eq "$want0" "$(account_names 0)" "account 0 after the second upload" || return 1
    assert_eq "$want1" "$(account_names 1)" "account 1 after the second upload" || return 1
    assert_contains "$(sandbox_log activity.log)" "Removed old part 'bk.p1.tar.gz' from account #0" \
        "activity.log removal entry" || return 1

    # The archive bk.p0 still restores. It has old files and chunks, so a warning is logged.
    run_cmd "$DOWNLOAD" bk.p0 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download of bk.p0" || return 1
    assert_exit_code 0 diff -r -- "$BIG_SRC" "$SANDBOX_DIR/restore/big dir" || return 1
    assert_contains "$(sandbox_log error.log)" "also has files in the old format" \
        "warning for the old files of bk.p0" || return 1
}

# Pass when an archive with chunks and an old file for part 0 restores with the chunks.
# The old file is not used, and the download does not remove it.
test_mixed_old_and_new_files_use_chunks() {
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    printf 'junk that is not gzip\n' > "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code" || return 1
    assert_exit_code 0 diff -r -- "$BIG_SRC" "$SANDBOX_DIR/restore/big dir" || return 1
    assert_contains "$(sandbox_log error.log)" \
        "Warning: archive 'backup1' also has files in the old format. They are not used." \
        "warning text" || return 1
    assert_file_exists "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" "old file is not removed" || return 1
}

# Pass when an archive in the old format restores. Its manifest is version 1,
# which has no file names, so the old names still verify.
test_old_format_archive_restores_with_v1_manifest() {
    local joined mf
    new_sandbox 2 || return 1
    run_cmd "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1

    # Rename each chunk to the old name. Each part is one chunk here.
    mv -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.c0.tar.gz" "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" || return 1
    mv -- "$MOCK_STORAGE_DIR/acct1/backup1.p1.c0.tar.gz" "$MOCK_STORAGE_DIR/acct1/backup1.p1.tar.gz" || return 1
    mkdir -p -- "$SANDBOX_DIR/check" || return 1
    joined="$SANDBOX_DIR/check/joined.tar.gz"
    cat -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz" "$MOCK_STORAGE_DIR/acct1/backup1.p1.tar.gz" > "$joined" || return 1

    # Write a version 1 manifest by hand, in the old text format.
    mf="$(manifest_path backup1)"
    printf 'version 1\narchive backup1\nparts 2\nbytes %s\nsha256 %s\npart 0 %s %s\npart 1 %s %s\n' \
        "$(file_size "$joined")" "$(file_hash "$joined")" \
        "$(file_size "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz")" \
        "$(file_hash "$MOCK_STORAGE_DIR/acct0/backup1.p0.tar.gz")" \
        "$(file_size "$MOCK_STORAGE_DIR/acct1/backup1.p1.tar.gz")" \
        "$(file_hash "$MOCK_STORAGE_DIR/acct1/backup1.p1.tar.gz")" > "$mf" || return 1

    run_cmd env MPARCHIVE_REQUIRE_MANIFEST=1 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "0" "$RUN_RC" "download exit code with a version 1 manifest" || return 1
    assert_exit_code 0 diff -r -- "$BIG_SRC" "$SANDBOX_DIR/restore/big dir" || return 1
    assert_eq "" "$(sandbox_log error.log)" "no warning for a verified old archive" || return 1
}

# Pass when a version 1 manifest compares sizes and hashes only. Names are not compared.
test_manifest_v1_ignores_names() {
    local d="$SANDBOX_DIR/unit-v1" joined rc
    new_sandbox 2 || return 1
    mkdir -p -- "$d" "$MPARCHIVE_STATE_DIR/manifests" || return 1
    printf 'AAA' > "$d/x1" || return 1
    printf 'BBB' > "$d/x2" || return 1
    cp -- "$d/x1" "$d/y1" || return 1
    cp -- "$d/x2" "$d/y2" || return 1
    joined="$d/joined"
    cat -- "$d/x1" "$d/x2" > "$joined" || return 1
    printf 'version 1\narchive u1\nparts 2\nbytes 6\nsha256 %s\npart 0 3 %s\npart 1 3 %s\n' \
        "$(file_hash "$joined")" "$(file_hash "$d/x1")" "$(file_hash "$d/x2")" > "$(manifest_path u1)" || return 1

    rc=0; manifest_verify u1 "$joined" "$d/y1" "$d/y2" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "different names with the same bytes give 0 in version 1" || return 1
}

# Pass when a version 2 manifest refuses files that are in another order or have other names.
test_manifest_v2_compares_names() {
    local d="$SANDBOX_DIR/unit-v2" joined_ab joined_ba rc
    new_sandbox 2 || return 1
    mkdir -p -- "$d" || return 1
    printf 'AAA' > "$d/u.p0.c0.tar.gz" || return 1
    printf 'BBBB' > "$d/u.p0.c1.tar.gz" || return 1
    joined_ab="$d/joined-ab"
    joined_ba="$d/joined-ba"
    cat -- "$d/u.p0.c0.tar.gz" "$d/u.p0.c1.tar.gz" > "$joined_ab" || return 1
    cat -- "$d/u.p0.c1.tar.gz" "$d/u.p0.c0.tar.gz" > "$joined_ba" || return 1
    manifest_write u "$joined_ab" "$d/u.p0.c0.tar.gz" "$d/u.p0.c1.tar.gz" || return 1
    assert_contains "$(cat -- "$(manifest_path u)")" "part 0 3 $(file_hash "$d/u.p0.c0.tar.gz") u.p0.c0.tar.gz" \
        "manifest line has the file name" || return 1

    rc=0; manifest_verify u "$joined_ab" "$d/u.p0.c0.tar.gz" "$d/u.p0.c1.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "the right order gives 0" || return 1

    # The same files in the wrong order: the names do not match.
    rc=0; manifest_verify u "$joined_ba" "$d/u.p0.c1.tar.gz" "$d/u.p0.c0.tar.gz" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "the wrong order gives 1" || return 1
    assert_contains "$(sandbox_log error.log)" \
        "File 0 of 'u' is 'u.p0.c1.tar.gz', but the manifest has 'u.p0.c0.tar.gz'" \
        "error.log names the file" || return 1
}

# ---------------------------------------------------------------------------
# Missing and swapped chunks
# ---------------------------------------------------------------------------

# Pass when a missing middle chunk gives "incomplete" with the chunk name, and nothing is restored.
test_missing_middle_chunk_is_incomplete() {
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    rm -f -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.c1.tar.gz" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "is incomplete" "error.log text" || return 1
    assert_contains "$(sandbox_log error.log)" "missing files: part 0 chunk 1" \
        "error.log names the chunk" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when a missing last chunk is refused by the manifest.
# The count of parts in the manifest is the count of chunks.
test_missing_last_chunk_refused_by_manifest() {
    local count
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    count="$(account_names 1 | wc -l)"
    rm -f -- "$MOCK_STORAGE_DIR/acct1/$(chunk_name backup1 1 $((count - 1)))" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "but the manifest has" "error.log text" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after a refusal" || return 1
}

# Pass when a missing last chunk, without the manifest, makes the extraction fail.
test_missing_last_chunk_without_manifest_fails() {
    local count
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    count="$(account_names 1 | wc -l)"
    rm -f -- "$MOCK_STORAGE_DIR/acct1/$(chunk_name backup1 1 $((count - 1)))" || return 1
    rm -f -- "$(manifest_path backup1)" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Extraction failed" "error.log text" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after a failure" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Pass when two chunks of the same size trade names. The manifest refuses the hashes.
test_swapped_chunks_refused_by_manifest() {
    local c0 c1
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    c0="$MOCK_STORAGE_DIR/acct0/$(chunk_name backup1 0 0)"
    c1="$MOCK_STORAGE_DIR/acct0/$(chunk_name backup1 0 1)"
    assert_eq "$(file_size "$c0")" "$(file_size "$c1")" "both chunks have the same size" || return 1

    mkdir -p -- "$SANDBOX_DIR/check" || return 1
    mv -- "$c0" "$SANDBOX_DIR/check/held" || return 1
    mv -- "$c1" "$c0" || return 1
    mv -- "$SANDBOX_DIR/check/held" "$c1" || return 1

    run_cmd "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "does not match its manifest" "error.log text" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder after a refusal" || return 1
}

# Pass when a chunk index of 10000 or more stops the restore at once.
# A chunk index of 9999 is a valid index. It makes the archive incomplete, not refused.
test_chunk_index_limit() {
    new_sandbox 2 || return 1
    run_cmd "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    printf 'decoy\n' > "$MOCK_STORAGE_DIR/acct0/backup1.p0.c10000.tar.gz" || return 1

    run_cmd timeout 20 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code (124 means the script hung)" || return 1
    assert_contains "$(sandbox_log error.log)" \
        "has chunk index 10000; the maximum is 9999" "error.log text" || return 1
    assert_file_missing "$SANDBOX_DIR/restore" "no target folder" || return 1

    rm -f -- "$MOCK_STORAGE_DIR/acct0/backup1.p0.c10000.tar.gz" || return 1
    printf 'decoy\n' > "$MOCK_STORAGE_DIR/acct0/backup1.p0.c9999.tar.gz" || return 1
    : > "$MPARCHIVE_LOG_DIR/error.log"
    run_cmd timeout 20 "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore/"
    assert_eq "1" "$RUN_RC" "exit code with chunk 9999" || return 1
    assert_contains "$(sandbox_log error.log)" "is incomplete" "chunk 9999 is only incomplete" || return 1
    assert_not_contains "$(sandbox_log error.log)" "chunk index" "no index refusal for 9999" || return 1
}

# ---------------------------------------------------------------------------
# exists.sh and remove.sh
# ---------------------------------------------------------------------------

# Pass when exists.sh and remove.sh work with chunk files.
# The archive "backup10" has a name that starts with "backup1", and it stays.
test_exists_and_remove_with_chunks() {
    local n1 out
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload of backup1" || return 1
    run_cmd "$UPLOAD" "$SMALL_SRC" backup10
    assert_eq "0" "$RUN_RC" "upload of backup10" || return 1
    n1="$(archive_count backup1)"
    assert_eq "1" "$(( n1 > 2 ))" "backup1 has several chunk files" || return 1

    run_cmd "$EXISTS_SH" backup1
    assert_eq "0" "$RUN_RC" "exists backup1 exit code" || return 1
    assert_eq "true" "$RUN_OUT" "exists backup1 prints true" || return 1
    run_cmd "$EXISTS_SH" nothere
    assert_eq "1" "$RUN_RC" "exists nothere exit code" || return 1
    assert_eq "false" "$RUN_OUT" "exists nothere prints false" || return 1

    run_cmd "$REMOVE_SH" backup1
    assert_eq "0" "$RUN_RC" "remove exit code" || return 1
    assert_eq "$n1" "$RUN_OUT" "remove prints the count of chunk files" || return 1
    assert_eq "0" "$(archive_count backup1)" "no backup1 files left" || return 1
    assert_eq "2" "$(archive_count backup10)" "backup10 files stay" || return 1
    assert_contains "$(sandbox_log activity.log)" "Deleted backup1.p0.c0.tar.gz from account #0" \
        "activity.log removal entry" || return 1

    run_cmd "$EXISTS_SH" backup1
    assert_eq "1" "$RUN_RC" "exists backup1 after removal" || return 1
    assert_eq "false" "$RUN_OUT" "exists backup1 after removal prints false" || return 1
}

# Pass when exists.sh says true while only a later chunk is left.
test_exists_true_with_only_a_later_chunk() {
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    rm -f -- "$MOCK_STORAGE_DIR/acct0/$(chunk_name backup1 0 0)" || return 1
    run_cmd "$EXISTS_SH" backup1
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    assert_eq "true" "$RUN_OUT" "output" || return 1
}

# Pass when remove.sh counts and deletes an old file together with the chunk files.
test_remove_counts_old_file_with_chunks() {
    local n
    new_sandbox 2 || return 1
    run_cmd env MPARCHIVE_CHUNK_MAX_BYTES=20000 "$UPLOAD" "$BIG_SRC" backup1
    assert_eq "0" "$RUN_RC" "upload exit code" || return 1
    printf 'old\n' > "$MOCK_STORAGE_DIR/acct1/backup1.p1.tar.gz" || return 1
    n="$(archive_count backup1)"

    run_cmd "$REMOVE_SH" backup1
    assert_eq "0" "$RUN_RC" "remove exit code" || return 1
    assert_eq "$n" "$RUN_OUT" "remove counts the old file too" || return 1
    assert_eq "0" "$(archive_count backup1)" "no files left" || return 1
}

# ---------------------------------------------------------------------------
# Unit tests: manifest checks and the library helpers
# ---------------------------------------------------------------------------

# Pass when chunk_name and part_name produce the names and the empty archive name is refused.
test_chunk_name_helper() {
    assert_eq "a.b.p0.c10.tar.gz" "$(chunk_name a.b 0 10)" "dotted archive name" || return 1
    assert_eq "x.p9999.c9999.tar.gz" "$(chunk_name x 9999 9999)" "large indices" || return 1
}

run_test "names: both formats" test_names_both_formats
run_test "names: numbers and leading zeros" test_names_numbers
run_test "names: other and bad names are rejected" test_names_reject_other_names
run_test "names: longer archive names do not match" test_names_other_archive_prefix
run_test "names: chunk_name helper" test_chunk_name_helper
run_test "chunk sizes with the provider limit" test_chunk_sizes_with_provider_limit
run_test "chunk sizes with per-account limits" test_chunk_sizes_per_account_limits
run_test "chunk setting smaller than provider" test_chunk_setting_smaller_than_provider
run_test "chunk setting larger than provider" test_chunk_setting_larger_than_provider
run_test "chunk setting leading zeros are decimal" test_chunk_setting_leading_zeros_are_decimal
run_test "chunk setting invalid values die" test_chunk_setting_invalid_values_die
run_test "chunk setting 18 digits accepted" test_chunk_setting_18_digits_accepted
run_test "chunk setting empty means no limit" test_chunk_setting_empty_means_no_limit
run_test "provider without size function gives one chunk" test_provider_without_size_function_one_chunk
run_test "empty part gets chunk 0" test_empty_part_gets_chunk_zero
run_test "more than 10000 chunks dies before upload" test_too_many_chunks_dies_before_upload
run_test "size query failure stops before upload" test_maxfile_failure_stops_before_upload
run_test "round trip with many chunks is identical" test_round_trip_many_chunks_identical
run_test "download size limit applies per chunk" test_download_part_size_limit_per_chunk
run_test "re-upload removes only stale files of the archive" test_reupload_removes_only_stale_files_of_the_archive
run_test "mixed old and new files use chunks" test_mixed_old_and_new_files_use_chunks
run_test "old format archive restores with v1 manifest" test_old_format_archive_restores_with_v1_manifest
run_test "manifest v1 ignores names" test_manifest_v1_ignores_names
run_test "manifest v2 compares names" test_manifest_v2_compares_names
run_test "missing middle chunk is incomplete" test_missing_middle_chunk_is_incomplete
run_test "missing last chunk is refused by manifest" test_missing_last_chunk_refused_by_manifest
run_test "missing last chunk without manifest fails" test_missing_last_chunk_without_manifest_fails
run_test "swapped chunks are refused by manifest" test_swapped_chunks_refused_by_manifest
run_test "chunk index limit" test_chunk_index_limit
run_test "exists and remove with chunks" test_exists_and_remove_with_chunks
run_test "exists true with only a later chunk" test_exists_true_with_only_a_later_chunk
run_test "remove counts old file with chunks" test_remove_counts_old_file_with_chunks

# Pass when the real error.log and activity.log did not change during the run.
test_real_logs_untouched() {
    assert_eq "$REAL_LOGS_BEFORE" "$(real_logs_state)" "real logs must not change"
}
run_test "real logs untouched" test_real_logs_untouched

finish_tests
