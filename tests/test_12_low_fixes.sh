#!/usr/bin/env bash
# Tests for the log modes, the part manifest and the restore limits.
# Log modes: _mpa_log and mpa_setup_paths in bin/lib/common.sh.
# Manifest: upload.sh writes it, download.sh checks the parts with it.
# Limits: download.sh checks the part sizes, the free space and the inode count.
# Unit tests call the library functions directly. The other tests run the real scripts.
# The real error.log and activity.log in the project root must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Load the library. The unit tests call its functions directly.
source "$REPO_ROOT/bin/lib/common.sh"

# Use umask 022 for the whole file. The log modes must not depend on it.
umask 022

# Remove the last sandbox when the file ends, even after a failed test.
trap 'teardown_sandbox' EXIT

# Paths of the scripts under test.
UPLOAD="$REPO_ROOT/bin/upload.sh"
DOWNLOAD="$REPO_ROOT/bin/download.sh"

# Create a new sandbox with N accounts and a small content folder.
# Args: <account count>
new_sandbox() {
    teardown_sandbox
    setup_sandbox "$1" || return 1
    TARGET="$SANDBOX_DIR/restore"
    CRAFT="$SANDBOX_DIR/craft"
    mkdir -p -- "$CRAFT" || return 1
    make_fixture
}

# Build a small content folder. The folder "data dir" holds a random file and a text file.
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

# Upload one content item with the real upload script.
# Pass when the upload exits 0.
# Args: <source path> <archive name>
upload_content() {
    run_cmd "$UPLOAD" "$1" "$2"
    assert_eq "0" "$RUN_RC" "upload must exit 0" || return 1
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

# Pass when no staging folder is in the target and no temp folder is left.
# Args: <target folder>
assert_clean() {
    local target="$1" left
    left="$(find "$target" -mindepth 1 -maxdepth 1 -name '.mp-archive-restore.*' 2>/dev/null)"
    assert_eq "" "$left" "no staging folder left in $target" || return 1
    assert_eq "" "$(temp_leftovers)" "no temp folder left" || return 1
}

# Print the octal mode of a file or a folder. Follow no symbolic link.
# Args: <path>
mode_of() {
    stat -c %a -- "$1"
}

# Print the SHA-256 hash of one file. Print only the hash.
# Args: <file>
file_hash() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# Print the path of the manifest of an archive, as the spec defines it.
# Args: <archive name>
manifest_file() {
    printf '%s/manifests/%s.manifest\n' "$MPARCHIVE_STATE_DIR" "$1"
}

# Print the path of the stored chunk 0 of part i. Upload puts part i in account i.
# Each small part is one chunk, so the chunk index is 0.
# Args: <archive name> <index>
stored_part() {
    printf '%s/acct%s/%s\n' "$MOCK_STORAGE_DIR" "$2" "$(chunk_name "$1" "$2" 0)"
}

# Print the manifest text that an upload of N parts must write (version 2).
# The joined archive is the parts in index order. Each part line has the file name.
# Args: <archive name> <part count>
expected_manifest() {
    local name="$1" count="$2" i part joined="$SANDBOX_DIR/joined.check"
    : > "$joined" || return 1
    for ((i = 0; i < count; i++)); do
        cat -- "$(stored_part "$name" "$i")" >> "$joined" || return 1
    done
    printf 'version 2\narchive %s\nparts %s\nbytes %s\nsha256 %s\n' \
        "$name" "$count" "$(file_size "$joined")" "$(file_hash "$joined")"
    for ((i = 0; i < count; i++)); do
        part="$(stored_part "$name" "$i")"
        printf 'part %s %s %s %s\n' "$i" "$(file_size "$part")" "$(file_hash "$part")" \
            "$(chunk_name "$name" "$i" 0)"
    done
}

# Print the error.log line that holds the text. Print nothing when no line matches.
# Args: <text>
error_line() {
    sandbox_log error.log | grep -F -- "$1" | tail -n 1
}

# Pass when a clean upload restores with no manifest warning.
test_clean_restore_is_accepted() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "0" "$RUN_RC" "download exit code" || return 1
    assert_exit_code 0 diff -r -- "$SANDBOX_DIR/src/data dir" "$TARGET/data dir" || return 1
    assert_eq "" "$(sandbox_log error.log)" "no error.log entry for a clean restore" || return 1
    assert_clean "$TARGET" || return 1
}

# ---------------------------------------------------------------------
# Log modes
# ---------------------------------------------------------------------

# Pass when, under umask 022, a new log folder is 700 and new log files are 600.
# The download of an absent archive writes both log files.
test_log_modes_under_umask_022() {
    local newdir
    new_sandbox 2 || return 1
    assert_eq "0022" "$(umask)" "the test runs with umask 022" || return 1
    newdir="$SANDBOX_DIR/newlogs/deep"
    export MPARCHIVE_LOG_DIR="$newdir"

    run_cmd "$DOWNLOAD" nothere "$TARGET/"
    assert_eq "1" "$RUN_RC" "exit code for an absent archive" || return 1
    assert_eq "700" "$(mode_of "$SANDBOX_DIR/newlogs")" "new log parent folder mode" || return 1
    assert_eq "700" "$(mode_of "$newdir")" "new log folder mode" || return 1
    assert_eq "600" "$(mode_of "$newdir/error.log")" "new error.log mode" || return 1
    assert_eq "600" "$(mode_of "$newdir/activity.log")" "new activity.log mode" || return 1
}

# Pass when the umask of the caller does not change the new log modes.
# The caller runs download.sh with umask 000.
test_log_modes_with_caller_umask_000() {
    new_sandbox 2 || return 1
    export MPARCHIVE_LOG_DIR="$SANDBOX_DIR/newlogs2"

    run_cmd bash -c 'umask 000; exec "$@"' _ "$DOWNLOAD" nothere "$TARGET/"
    assert_eq "1" "$RUN_RC" "exit code for an absent archive" || return 1
    assert_eq "700" "$(mode_of "$MPARCHIVE_LOG_DIR")" "new log folder mode with umask 000" || return 1
    assert_eq "600" "$(mode_of "$MPARCHIVE_LOG_DIR/error.log")" "error.log mode with umask 000" || return 1
    assert_eq "600" "$(mode_of "$MPARCHIVE_LOG_DIR/activity.log")" "activity.log mode with umask 000" || return 1
}

# Pass when an existing log file with mode 644 becomes 600, and keeps its text.
test_existing_log_mode_is_fixed() {
    new_sandbox 2 || return 1
    printf 'old activity line\n' > "$MPARCHIVE_LOG_DIR/activity.log" || return 1
    printf 'old error line\n' > "$MPARCHIVE_LOG_DIR/error.log" || return 1
    chmod 644 -- "$MPARCHIVE_LOG_DIR/activity.log" "$MPARCHIVE_LOG_DIR/error.log" || return 1
    assert_eq "644" "$(mode_of "$MPARCHIVE_LOG_DIR/error.log")" "mode before the run" || return 1

    run_cmd "$DOWNLOAD" nothere "$TARGET/"
    assert_eq "1" "$RUN_RC" "exit code for an absent archive" || return 1
    assert_eq "600" "$(mode_of "$MPARCHIVE_LOG_DIR/error.log")" "existing error.log mode" || return 1
    assert_eq "600" "$(mode_of "$MPARCHIVE_LOG_DIR/activity.log")" "existing activity.log mode" || return 1
    assert_eq "old error line" "$(head -n 1 -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "old text stays in error.log" || return 1
    assert_eq "old activity line" "$(head -n 1 -- "$MPARCHIVE_LOG_DIR/activity.log")" \
        "old text stays in activity.log" || return 1
}

# Pass when a symbolic link in place of a log file is not written through.
# The target of the link keeps its text and its mode.
test_symlinked_log_not_written_through() {
    local victim1 victim2
    new_sandbox 2 || return 1
    victim1="$SANDBOX_DIR/victim1.txt"
    victim2="$SANDBOX_DIR/victim2.txt"
    printf 'victim one\n' > "$victim1" || return 1
    printf 'victim two\n' > "$victim2" || return 1
    chmod 644 -- "$victim1" "$victim2" || return 1
    ln -s -- "$victim1" "$MPARCHIVE_LOG_DIR/error.log" || return 1
    ln -s -- "$victim2" "$MPARCHIVE_LOG_DIR/activity.log" || return 1

    run_cmd "$DOWNLOAD" nothere "$TARGET/"
    assert_eq "1" "$RUN_RC" "exit code for an absent archive" || return 1
    assert_eq "victim one" "$(cat -- "$victim1")" "error.log target text unchanged" || return 1
    assert_eq "victim two" "$(cat -- "$victim2")" "activity.log target text unchanged" || return 1
    assert_eq "644" "$(mode_of "$victim1")" "error.log target mode unchanged" || return 1
    assert_eq "644" "$(mode_of "$victim2")" "activity.log target mode unchanged" || return 1
    assert_eq "yes" "$([[ -L "$MPARCHIVE_LOG_DIR/error.log" ]] && echo yes || echo no)" \
        "error.log is still a symbolic link" || return 1
    assert_contains "$RUN_ERR" "Archive 'nothere' not found" "the message still reaches stderr" || return 1
}

# ---------------------------------------------------------------------
# Manifest written by upload.sh
# ---------------------------------------------------------------------

# Pass when a full upload writes the manifest with the right text and modes.
test_upload_writes_manifest() {
    local mf want
    new_sandbox 3 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    mf="$(manifest_file backup1)"
    assert_file_exists "$mf" "manifest must exist after a full upload" || return 1
    assert_eq "600" "$(mode_of "$mf")" "manifest file mode" || return 1
    assert_eq "700" "$(mode_of "$MPARCHIVE_STATE_DIR/manifests")" "manifests folder mode" || return 1
    want="$(expected_manifest backup1 3)" || return 1
    assert_eq "$want" "$(cat -- "$mf")" "manifest text" || return 1
}

# Pass when a failed upload writes no manifest and no file in the state folder.
test_upload_failure_writes_no_manifest() {
    new_sandbox 2 || return 1
    export MOCK_FAIL_UPLOAD_1=2
    run_cmd "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "1" "$RUN_RC" "upload exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Upload of part 1, chunk 0 ('backup1.p1.c0.tar.gz') to account #1 failed" \
        "error.log entry" || return 1
    assert_file_missing "$(manifest_file backup1)" "no manifest after a failed upload" || return 1
    assert_eq "" "$(find "$MPARCHIVE_STATE_DIR" -type f 2>/dev/null)" \
        "no file in the state folder after a failed upload" || return 1
}

# ---------------------------------------------------------------------
# Manifest checks in download.sh
# ---------------------------------------------------------------------

# Pass when a part with the same size and other bytes is refused. Nothing is restored.
test_verify_changed_part_refused() {
    local part
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    part="$(stored_part backup1 1)"
    # Zeros have the same size as the random part, but other bytes.
    head -c "$(file_size "$part")" /dev/zero > "$part" || return 1

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Part 1 of 'backup1' does not match the manifest" \
        "error.log names the changed part" || return 1
    assert_contains "$(sandbox_log error.log)" "Nothing is restored" "error.log says nothing is restored" || return 1
    assert_file_missing "$TARGET" "no target folder after a refusal" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when an extra part (a third account holds part 2) is refused.
test_verify_extra_part_refused() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    mkdir -p -- "$MOCK_STORAGE_DIR/acct2" || return 1
    cp -- "$(stored_part backup1 0)" "$MOCK_STORAGE_DIR/acct2/$(chunk_name backup1 2 0)" || return 1
    make_accounts_json 3 > "$MPARCHIVE_CONFIG_DIR/mock.json" || return 1

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "has 3 files, but the manifest has 2" \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after a refusal" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a missing part (the archive now has two accounts, not three) is refused.
test_verify_fewer_parts_refused() {
    new_sandbox 3 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    make_accounts_json 2 > "$MPARCHIVE_CONFIG_DIR/mock.json" || return 1

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "has 2 files, but the manifest has 3" \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after a refusal" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a restore without a manifest logs a warning and restores the content.
test_verify_no_manifest_warns_and_restores() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    rm -f -- "$(manifest_file backup1)" || return 1

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Warning: no manifest for 'backup1'" \
        "error.log warning" || return 1
    assert_exit_code 0 diff -r -- "$SANDBOX_DIR/src/data dir" "$TARGET/data dir" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when MPARCHIVE_REQUIRE_MANIFEST=1 refuses a restore without a manifest.
# With the manifest in place, the same setting still restores.
test_verify_require_manifest_refuses() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    rm -f -- "$(manifest_file backup1)" || return 1

    run_cmd env MPARCHIVE_REQUIRE_MANIFEST=1 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code without a manifest" || return 1
    assert_contains "$(sandbox_log error.log)" "MPARCHIVE_REQUIRE_MANIFEST=1" \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder without a manifest" || return 1
    assert_clean "$TARGET" || return 1

    # Upload again, so that the manifest exists.
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    run_cmd env MPARCHIVE_REQUIRE_MANIFEST=1 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code with a manifest" || return 1
    assert_exit_code 0 diff -r -- "$SANDBOX_DIR/src/data dir" "$TARGET/data dir" || return 1
}

# ---------------------------------------------------------------------
# Part index, part size and count limits in download.sh
# ---------------------------------------------------------------------

# Pass when a part with index 999999999 stops the restore at once and names the file.
test_decoy_index_fails_fast() {
    local t0 t1 ms
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    printf 'decoy\n' > "$MOCK_STORAGE_DIR/acct0/backup1.p999999999.tar.gz" || return 1

    t0="$(date +%s%N)"
    # The timeout stops a script that hangs. A hang gives exit code 124.
    run_cmd timeout 20 "$DOWNLOAD" backup1 "$TARGET"
    t1="$(date +%s%N)"
    ms=$(( (t1 - t0) / 1000000 ))

    assert_eq "1" "$RUN_RC" "exit code (124 means the script hung)" || return 1
    assert_contains "$(sandbox_log error.log)" \
        "file 'backup1.p999999999.tar.gz' in account #0 has part index 999999999, but only 2 active accounts exist" \
        "error.log names the file" || return 1
    assert_eq "yes" "$([[ "$ms" -lt 2000 ]] && echo yes || echo no)" \
        "fails in under 2 s (took ${ms} ms)" || return 1
    assert_file_missing "$TARGET" "no target folder after a decoy" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a missing list lists 20 entries and gives the full count (25).
test_missing_index_list_is_capped() {
    local i line want="" sep=""
    new_sandbox 30 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    for ((i = 1; i <= 25; i++)); do
        rm -f -- "$(stored_part backup1 "$i")" || return 1
    done

    run_cmd "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    line="$(error_line "is incomplete")"
    assert_contains "$line" "25 missing files: " "error.log gives the full count" || return 1
    for ((i = 1; i <= 20; i++)); do
        want+="${sep}part $i"
        sep=", "
    done
    assert_eq "$want" "${line##*missing files: }" "the list has the first 20 entries only" || return 1
    assert_file_missing "$TARGET" "no target folder after a missing part" || return 1
}

# Pass when a part larger than MPARCHIVE_PART_MAX_BYTES is refused.
# A large enough limit restores. A limit that is not a number is refused.
test_part_max_bytes_refuses() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1

    run_cmd env MPARCHIVE_PART_MAX_BYTES=100 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a 100 byte limit" || return 1
    assert_contains "$(sandbox_log error.log)" "the limit is 100. Nothing is restored." \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after a size refusal" || return 1
    assert_clean "$TARGET" || return 1

    run_cmd env MPARCHIVE_PART_MAX_BYTES=100000 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code with a large limit" || return 1
    assert_exit_code 0 diff -r -- "$SANDBOX_DIR/src/data dir" "$TARGET/data dir" || return 1

    run_cmd env MPARCHIVE_PART_MAX_BYTES=abc "$DOWNLOAD" backup1 "$SANDBOX_DIR/restore2"
    assert_eq "1" "$RUN_RC" "exit code with a limit that is not a number" || return 1
    assert_contains "$(sandbox_log error.log)" "MPARCHIVE_PART_MAX_BYTES must be an integer" \
        "error.log text for a bad limit" || return 1
}

# Pass when a gzip bomb (16 MiB of zeros in about 16 KiB) is refused by a 1 MiB cap.
# Without a cap the same archive restores.
test_gzip_bomb_refused_by_cap() {
    local bomb
    new_sandbox 2 || return 1
    bomb="$CRAFT/bomb"
    mkdir -p -- "$bomb/top" || return 1
    head -c 16777216 /dev/zero > "$bomb/top/zeros.bin" || return 1
    tar -C "$bomb" -cf "$CRAFT/bomb.tar" top || return 1
    store_crafted_bomb bomb "$CRAFT/bomb.tar" || return 1
    assert_file_missing "$(manifest_file bomb)" "the crafted archive has no manifest" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_BYTES=1048576 "$DOWNLOAD" bomb "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a 1 MiB cap" || return 1
    assert_contains "$(sandbox_log error.log)" "can need more than 1048576 bytes" \
        "error.log text" || return 1
    assert_file_missing "$TARGET/top" "nothing restored with a cap" || return 1
    assert_clean "$TARGET" || return 1

    run_cmd "$DOWNLOAD" bomb "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code without a cap" || return 1
    assert_eq "16777216" "$(file_size "$TARGET/top/zeros.bin")" \
        "restored file size without a cap" || return 1
    assert_clean "$TARGET" || return 1
}

# Store a plain tar as part 0 (gzip) in account 0, and an empty part 1 in account 1.
# This is the same layout as the crafted archives of the restore safety tests.
# Args: <archive name> <plain tar path>
store_crafted_bomb() {
    local name="$1" plain="$2" dir="$MOCK_STORAGE_DIR"
    mkdir -p -- "$dir/acct0" "$dir/acct1" || return 1
    gzip -c -n -- "$plain" > "$dir/acct0/$(chunk_name "$name" 0 0)" || return 1
    : > "$dir/acct1/$(chunk_name "$name" 1 0)" || return 1
}

# Pass when an archive with 401 files and folders is refused by a limit of 100.
# The same archive restores with a large limit.
test_many_members_refused_by_inode_cap() {
    local i
    new_sandbox 2 || return 1
    mkdir -p -- "$SANDBOX_DIR/src/many" || return 1
    for ((i = 0; i < 200; i++)); do
        : > "$SANDBOX_DIR/src/many/f$i" || return 1
    done
    upload_content "$SANDBOX_DIR/src/many" many || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_INODES=100 "$DOWNLOAD" many "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a limit of 100" || return 1
    assert_contains "$(sandbox_log error.log)" "can create 401 files and folders; the limit is 100" \
        "error.log text" || return 1
    assert_eq "" "$(find "$TARGET" -mindepth 1 -maxdepth 1 -name 'many' 2>/dev/null)" \
        "nothing restored with the limit" || return 1
    assert_clean "$TARGET" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_INODES=100000 "$DOWNLOAD" many "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code with a large limit" || return 1
    assert_eq "200" "$(find "$TARGET/many" -type f | wc -l)" "all 200 files restored" || return 1
}

# Pass when a deep path (30 folders, one file) is refused by a limit of 100.
# The bound of this archive is 528, so the limit refuses it.
test_deep_path_refused_by_inode_cap() {
    local p i
    new_sandbox 2 || return 1
    p="$SANDBOX_DIR/src/deep"
    for ((i = 1; i <= 30; i++)); do
        p="$p/d$i"
    done
    mkdir -p -- "$p" || return 1
    : > "$p/leaf.txt" || return 1
    upload_content "$SANDBOX_DIR/src/deep" deep || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_INODES=100 "$DOWNLOAD" deep "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a limit of 100" || return 1
    assert_contains "$(sandbox_log error.log)" "can create 528 files and folders; the limit is 100" \
        "error.log text" || return 1
    assert_file_missing "$TARGET/deep" "nothing restored with the limit" || return 1
    assert_clean "$TARGET" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_INODES=100000 "$DOWNLOAD" deep "$TARGET"
    assert_eq "0" "$RUN_RC" "exit code with a large limit" || return 1
    assert_eq "yes" "$([[ -f "$TARGET/deep/$(printf 'd%s/' $(seq 1 30))leaf.txt" ]] && echo yes || echo no)" \
        "the file at the bottom is restored" || return 1
}

# ---------------------------------------------------------------------
# Unit tests: the library functions
# ---------------------------------------------------------------------

# Pass when archive_stream_bytes stops at limit + 1 and counts a full stream.
test_unit_stream_bytes_stops_at_limit() {
    new_sandbox 2 || return 1
    local d="$SANDBOX_DIR/unit"
    mkdir -p -- "$d" || return 1
    head -c 2097152 /dev/zero | gzip -c -n > "$d/zeros.gz" || return 1
    assert_eq "1001" "$(archive_stream_bytes "$d/zeros.gz" 1000)" "stops at the limit + 1" || return 1
    assert_eq "1" "$(archive_stream_bytes "$d/zeros.gz" 0)" "a zero limit gives 1" || return 1
    assert_eq "2097152" "$(archive_stream_bytes "$d/zeros.gz" 10000000)" \
        "a larger limit gives the full stream size" || return 1
}

# Print the return code and the output of archive_stream_bytes for bad input.
# Sets SB_RC and SB_OUT.
# Args: <file> <limit>
stream_bytes_bad() {
    SB_RC=0
    SB_OUT="$(archive_stream_bytes "$1" "$2" 2>/dev/null)" || SB_RC=$?
}

# Pass when archive_stream_bytes returns 1 and prints nothing for bad gzip data.
# A cut gzip file (its output is below the limit) also fails.
test_unit_stream_bytes_fails_on_invalid_gzip() {
    new_sandbox 2 || return 1
    local d="$SANDBOX_DIR/unit2"
    mkdir -p -- "$d" || return 1
    printf 'not gzip data\n' > "$d/bad.gz" || return 1
    : > "$d/empty.gz" || return 1
    head -c 2000 /dev/urandom | gzip -c -n > "$d/full.gz" || return 1
    head -c 40 "$d/full.gz" > "$d/cut.gz" || return 1

    stream_bytes_bad "$d/bad.gz" 1000
    assert_eq "1" "$SB_RC" "garbage file gives return 1" || return 1
    assert_eq "" "$SB_OUT" "garbage file prints nothing" || return 1

    stream_bytes_bad "$d/empty.gz" 1000
    assert_eq "1" "$SB_RC" "empty file gives return 1" || return 1

    stream_bytes_bad "$d/cut.gz" 1000
    assert_eq "1" "$SB_RC" "cut gzip file gives return 1" || return 1

    stream_bytes_bad "$d/full.gz" "abc"
    assert_eq "1" "$SB_RC" "a limit that is not a number gives return 1" || return 1
}

# Pass when archive_inode_bound gives the sum of the path parts of a small listing.
# The listing has 5 names: 1 + 2 + 3 + 2 + 3 = 11.
test_unit_inode_bound_values() {
    new_sandbox 2 || return 1
    local d="$SANDBOX_DIR/unit3"
    mkdir -p -- "$d" || return 1
    printf 'top/\ntop/a\ntop/sub/b\n./top/c\ntop/d//e\n' > "$d/names" || return 1
    assert_eq "11" "$(archive_inode_bound "$d/names")" "five names give 11" || return 1
    printf 'a\n' > "$d/one" || return 1
    assert_eq "1" "$(archive_inode_bound "$d/one")" "one name gives 1" || return 1
    : > "$d/none" || return 1
    assert_eq "0" "$(archive_inode_bound "$d/none")" "an empty listing gives 0" || return 1
}

# Pass when manifest_verify gives 0 for a match, 1 for a changed part, and 3 without a manifest.
test_unit_manifest_verify_codes() {
    new_sandbox 2 || return 1
    local d="$SANDBOX_DIR/unit4" rc
    mkdir -p -- "$d" || return 1
    printf 'AAA' > "$d/p0" || return 1
    printf 'BBB' > "$d/p1" || return 1
    cat -- "$d/p0" "$d/p1" > "$d/joined" || return 1
    manifest_write mvtest "$d/joined" "$d/p0" "$d/p1" || return 1

    rc=0; manifest_verify mvtest "$d/joined" "$d/p0" "$d/p1" >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "matching parts give 0" || return 1

    printf 'CCC' > "$d/p0" || return 1
    cat -- "$d/p0" "$d/p1" > "$d/joined" || return 1
    rc=0; manifest_verify mvtest "$d/joined" "$d/p0" "$d/p1" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "a changed part gives 1" || return 1

    rm -f -- "$(manifest_file mvtest)" || return 1
    rc=0; manifest_verify mvtest "$d/joined" "$d/p0" "$d/p1" >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "no manifest gives 3" || return 1
}

# -------------------------------------------------------------------------
# Regression tests for three fixes in bin/.
# B1: numeric limits are decimal, so "08" and "010" are not octal.
# B2: a hash error in manifest_write warns and does not stop upload.sh.
# B3: a refused restore creates no target folder.

# Pass when the caps "8" and "08" refuse with the same message, and "010" is 10 bytes.
# The archive is about 4 KB, so every cap here refuses it.
test_octal_looking_caps_refuse_like_decimal() {
    local line8 line08 line010
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_BYTES=8 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a cap of 8" || return 1
    line8="$(error_line "can need more than")"
    assert_contains "$line8" "can need more than 8 bytes" "cap 8 message" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_BYTES=08 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a cap of 08" || return 1
    line08="$(error_line "can need more than")"
    # The timestamp and the free space can change between runs.
    # Compare the text after the timestamp and before the free space.
    line8="${line8#* }"; line08="${line08#* }"
    assert_eq "${line8%% (free*}" "${line08%% (free*}" "cap 08 gives the same refusal as cap 8" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_BYTES=010 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a cap of 010" || return 1
    line010="$(error_line "can need more than")"
    assert_contains "$line010" "can need more than 10 bytes" "cap 010 is decimal 10" || return 1

    assert_file_missing "$TARGET" "no target folder after the refusals" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a part limit of "08" refuses a part of about 2 KB, as a plain number would.
test_octal_looking_part_limit_refuses() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    run_cmd env MPARCHIVE_PART_MAX_BYTES=08 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with a part limit of 08" || return 1
    assert_contains "$(sandbox_log error.log)" "the limit is 08. Nothing is restored." \
        "error.log text for the part limit" || return 1
    assert_file_missing "$TARGET" "no target folder after the part refusal" || return 1
}

# Pass when a sha256sum failure on part 0 gives a warning and exit 0, with no manifest.
# The shim fails only for part 0 names, so the parts are still uploaded.
# No leftover temp file of the manifest may stay in the state folder.
test_manifest_hash_failure_warns_and_exits_zero() {
    local real shim_dir
    new_sandbox 2 || return 1
    shim_dir="$SANDBOX_DIR/shim"
    mkdir -p -- "$shim_dir" || return 1
    real="$(command -v sha256sum)" || return 1
    cat > "$shim_dir/sha256sum" <<EOF
#!/bin/bash
# Fail for part 0 only. Other calls run the real program.
case "\$*" in *.p0.c0.tar.gz*) exit 1 ;; esac
exec "$real" "\$@"
EOF
    chmod +x -- "$shim_dir/sha256sum" || return 1

    run_cmd env PATH="$shim_dir:$PATH" "$UPLOAD" "$SANDBOX_DIR/src/data dir" backup1
    assert_eq "0" "$RUN_RC" "upload exit code is 0 after a manifest warning" || return 1
    assert_contains "$(sandbox_log error.log)" "Warning: cannot write the manifest of 'backup1'" \
        "error.log warning" || return 1
    assert_file_missing "$(manifest_file backup1)" "no manifest after the hash failure" || return 1
    assert_eq "" "$(find "$MPARCHIVE_STATE_DIR" -name 'backup1.manifest.*' 2>/dev/null)" \
        "no leftover manifest temp file" || return 1
    assert_eq "" "$(temp_leftovers)" "no upload temp folder left" || return 1
}

# Pass when a refused restore with an absent target creates no target folder.
test_refused_restore_creates_no_target() {
    new_sandbox 2 || return 1
    upload_content "$SANDBOX_DIR/src/data dir" backup1 || return 1
    assert_file_missing "$TARGET" "target must not exist yet" || return 1

    run_cmd env MPARCHIVE_RESTORE_MAX_INODES=1 "$DOWNLOAD" backup1 "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code with an inode limit of 1" || return 1
    assert_contains "$(sandbox_log error.log)" "the limit is 1. Nothing is restored." \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after the refusal" || return 1
    assert_clean "$TARGET" || return 1
}

# Real logs check. Save the state before the tests and compare it at the end.
# -------------------------------------------------------------------------

# Print the state of the real logs in the project root.
real_logs_state() {
    local name path
    for name in error.log activity.log; do
        path="$REPO_ROOT/$name"
        if [[ -e "$path" ]]; then
            printf "%s: %s %s\n" "$name" "$(stat -c "%s %Y" -- "$path")" "$(file_hash "$path")"
        else
            printf "%s: missing\n" "$name"
        fi
    done
}
REAL_LOGS_BEFORE="$(real_logs_state)"

# Pass when the real error.log and activity.log did not change during the run.
test_real_logs_untouched() {
    assert_eq "$REAL_LOGS_BEFORE" "$(real_logs_state)" "real logs must not change"
}

# ---------------------------------------------------------------------
# Run the tests.
# ---------------------------------------------------------------------

run_test "clean restore is accepted with no warning" test_clean_restore_is_accepted
run_test "log modes under umask 022" test_log_modes_under_umask_022
run_test "log modes with caller umask 000" test_log_modes_with_caller_umask_000
run_test "existing log file mode 644 becomes 600" test_existing_log_mode_is_fixed
run_test "symbolic link log file is not written through" test_symlinked_log_not_written_through
run_test "upload writes the manifest" test_upload_writes_manifest
run_test "failed upload writes no manifest" test_upload_failure_writes_no_manifest
run_test "changed part with the same size is refused" test_verify_changed_part_refused
run_test "extra part is refused" test_verify_extra_part_refused
run_test "fewer parts are refused" test_verify_fewer_parts_refused
run_test "no manifest warns and restores" test_verify_no_manifest_warns_and_restores
run_test "MPARCHIVE_REQUIRE_MANIFEST=1 refuses without a manifest" test_verify_require_manifest_refuses
run_test "decoy part index fails fast and names the file" test_decoy_index_fails_fast
run_test "missing index list is capped at 20" test_missing_index_list_is_capped
run_test "MPARCHIVE_PART_MAX_BYTES refuses a large part" test_part_max_bytes_refuses
run_test "gzip bomb is refused by a 1 MiB cap" test_gzip_bomb_refused_by_cap
run_test "many members are refused by the inode cap" test_many_members_refused_by_inode_cap
run_test "deep path is refused by the inode cap" test_deep_path_refused_by_inode_cap
run_test "archive_stream_bytes stops at limit + 1" test_unit_stream_bytes_stops_at_limit
run_test "archive_stream_bytes fails on invalid gzip" test_unit_stream_bytes_fails_on_invalid_gzip
run_test "archive_inode_bound gives the path part count" test_unit_inode_bound_values
run_test "manifest_verify gives 0, 1 and 3" test_unit_manifest_verify_codes
run_test "caps 08 and 010 are decimal (B1)" test_octal_looking_caps_refuse_like_decimal
run_test "part cap 08 is decimal (B1)" test_octal_looking_part_limit_refuses
run_test "manifest hash failure warns and exits 0 (B2)" test_manifest_hash_failure_warns_and_exits_zero
run_test "refused restore creates no target (B3)" test_refused_restore_creates_no_target
run_test "real logs untouched" test_real_logs_untouched

# Remove the last sandbox when the file ends, even after a failed test.
teardown_sandbox
finish_tests
