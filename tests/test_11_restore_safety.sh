#!/usr/bin/env bash
# Tests for the restore safety checks (archive_check_members and bin/download.sh).
# Unit tests: archive_check_members with hand-written GNU and BusyBox listings.
# Integration tests: bin/download.sh with crafted archives and the mock provider.
# The BusyBox tests need busybox. They are skipped when it is missing.
# Regression tests for two gaps that the first version of the check had.
# The real error.log and activity.log in the project root must not change.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Load the library under test. The unit tests call its functions directly.
source "$REPO_ROOT/bin/lib/common.sh"

# Paths of the scripts under test.
UPLOAD="$REPO_ROOT/bin/upload.sh"
DOWNLOAD="$REPO_ROOT/bin/download.sh"

# Save the state of the real logs before any test runs.
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
REAL_LOGS_BEFORE="$(real_logs_state)"

# Remove the last sandbox when the file ends, even after a failed test.
trap 'teardown_sandbox' EXIT

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Create a new sandbox with N accounts. Add the folders for the test files.
# The outside folder stands for a place that the restore must not write to.
# Args: <account count>
new_sandbox() {
    teardown_sandbox
    setup_sandbox "$1" || return 1
    OUTSIDE="$SANDBOX_DIR/outside"
    CRAFT="$SANDBOX_DIR/craft"
    TARGET="$SANDBOX_DIR/restore"
    mkdir -p -- "$OUTSIDE" "$CRAFT" || return 1
    printf 'keep\n' > "$OUTSIDE/.env" || return 1
    # Make a BusyBox tar wrapper when busybox exists. Tests check for it.
    make_busybox_bin 2>/dev/null || BB_BIN=""
}

# Make a "tar" wrapper that runs the BusyBox tar applet.
# The wrapper appends each call to calls.log, so a test can prove it ran.
# Sets BB_BIN to the folder that holds the wrapper.
make_busybox_bin() {
    local bb bin_dir="$SANDBOX_DIR/bb"
    bb="$(command -v busybox)" || return 1
    mkdir -p -- "$bin_dir" || return 1
    cat > "$bin_dir/tar" <<EOF
#!/bin/sh
# Record the call. Then run the BusyBox tar applet.
printf '%s\n' "\$*" >> "$bin_dir/calls.log"
exec "$bb" tar "\$@"
EOF
    chmod +x -- "$bin_dir/tar" || return 1
    BB_BIN="$bin_dir"
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

# Run one command with the BusyBox tar wrapper first in PATH.
# Args: <command> [args...]
run_busybox() {
    local saved_path="$PATH"
    PATH="${BB_BIN:?busybox is not set up}:$PATH"
    run_cmd "$@"
    PATH="$saved_path"
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

# Store a plain tar as part 0 (gzip) in account 0, and an empty part 1 in account 1.
# Args: <archive name> <plain tar path>
store_crafted() {
    local name="$1" plain="$2" dir="$MOCK_STORAGE_DIR"
    mkdir -p -- "$dir/acct0" "$dir/acct1" || return 1
    gzip -c -n -- "$plain" > "$dir/acct0/$(part_name "$name" 0)" || return 1
    : > "$dir/acct1/$(part_name "$name" 1)" || return 1
}

# Make a content folder with a real file and two symbolic links.
# The link "rel" is relative. The link "abs" is absolute.
make_tree() {
    local t="$SANDBOX_DIR/src/tree"
    mkdir -p -- "$t" || return 1
    printf 'real data\n' > "$t/real.txt" || return 1
    ln -s -- real.txt "$t/rel" || return 1
    ln -s -- "$t/real.txt" "$t/abs" || return 1
}

# Print the SHA-256 hash of one file. Print only the hash.
# Args: <file>
file_hash() {
    sha256sum -- "$1" | cut -d' ' -f1
}

# Run archive_check_members on two listing texts. Clear the error log first.
# Sets CHK_RC (exit code) and CHK_TOP (the top-level name that the check prints).
# Args: <names text> <verbose text>
check_raw() {
    local dir="$SANDBOX_DIR/listing"
    mkdir -p -- "$dir" || return 1
    rm -f -- "$MPARCHIVE_LOG_DIR/error.log"
    printf '%s' "$1" > "$dir/names" || return 1
    printf '%s' "$2" > "$dir/verbose" || return 1
    CHK_RC=0
    CHK_TOP="$(archive_check_members "$dir/names" "$dir/verbose" 2>/dev/null)" || CHK_RC=$?
}

# Build the two listings for one archive and run the check.
# Format is "gnu" or "bb". Each entry is one of these forms:
#   d:NAME           a directory (NAME ends with "/")
#   f:NAME           a regular file
#   l:NAME:TARGET    a symbolic link
#   h:NAME:TARGET    a hard link, written in the GNU or BusyBox form
# Args: <gnu|bb> <entry>...
check_entries() {
    local fmt="$1" entry kind name target names="" verbose=""
    shift
    for entry in "$@"; do
        IFS=: read -r kind name target <<< "$entry"
        names+="$name"$'\n'
        case "$kind" in
            d) verbose+="drwxr-xr-x u/g 0 2026-11-06 12:00 $name"$'\n' ;;
            f) verbose+="-rw-r--r-- u/g 3 2026-11-06 12:00 $name"$'\n' ;;
            l) verbose+="lrwxrwxrwx u/g 0 2026-11-06 12:00 $name -> $target"$'\n' ;;
            h)
                if [[ "$fmt" == gnu ]]; then
                    verbose+="hrw-r--r-- u/g 0 2026-11-06 12:00 $name link to $target"$'\n'
                else
                    verbose+="-rw-r--r-- u/g 0 2026-11-06 12:00:00 $name -> $target"$'\n'
                fi
                ;;
        esac
    done
    check_raw "$names" "$verbose"
}

# Pass when the check rejects the entries. It must print no name and log the text.
# Args: <gnu|bb> <expected log text> <entry>...
expect_reject() {
    local fmt="$1" want="$2"
    shift 2
    check_entries "$fmt" "$@" || return 1
    assert_eq "1" "$CHK_RC" "rejected ($fmt): $*" || return 1
    assert_eq "" "$CHK_TOP" "no top name when rejected ($fmt): $*" || return 1
    assert_contains "$(sandbox_log error.log)" "$want" "error.log text ($fmt): $*" || return 1
}

# Pass when the check accepts the entries and prints the expected top name.
# Args: <gnu|bb> <expected top name> <entry>...
expect_accept() {
    local fmt="$1" top="$2"
    shift 2
    check_entries "$fmt" "$@" || return 1
    assert_eq "0" "$CHK_RC" "accepted ($fmt): $*" || return 1
    assert_eq "$top" "$CHK_TOP" "top name ($fmt): $*" || return 1
}

# Run a regression test for a bug that is now fixed. It always runs.
# Args: <name> <function name>
run_known_bug() {
    run_test "regression: $1" "$2"
}

# Run a BusyBox test only when busybox exists. Otherwise print a SKIP line.
# Args: <name> <function name>
run_busybox_test() {
    if command -v busybox >/dev/null 2>&1; then
        run_test "$1" "$2"
    else
        printf 'SKIP  %s (busybox is not installed)\n' "$1"
    fi
}

# ---------------------------------------------------------------------
# Unit tests: archive_check_members
# The sandbox from the file start is used for the log. Integration tests make their own.
# ---------------------------------------------------------------------

# Pass when a plain tree is accepted in both formats, and the top name is printed.
test_unit_accepts_plain_tree() {
    local fmt
    for fmt in gnu bb; do
        expect_accept "$fmt" top d:top/ f:top/a d:top/sub/ f:top/sub/b || return 1
    done
}

# Pass when names with a "./" prefix are accepted and normalized to the top name.
test_unit_accepts_dot_slash_prefix() {
    expect_accept gnu top d:./top/ f:./top/a || return 1
    expect_accept bb top d:./top/ f:./top/a || return 1
}

# Pass when relative and absolute symbolic link members are accepted.
# A link alone is accepted too, with a relative or an absolute target.
test_unit_accepts_symlink_members() {
    local fmt
    for fmt in gnu bb; do
        expect_accept "$fmt" top d:top/ f:top/a l:top/rel:a l:top/abs:/etc/hostname || return 1
        expect_accept "$fmt" cfg l:cfg:/etc || return 1
        expect_accept "$fmt" cfg l:cfg:../outside || return 1
    done
}

# Pass when a link whose name only looks like another link is accepted.
# The check compares path parts, not text. "cfg2" is not below "cfg".
test_unit_accepts_similar_name_after_link() {
    local fmt
    for fmt in gnu bb; do
        expect_accept "$fmt" top d:top/ l:top/cfg:/outside f:top/cfg2/.env || return 1
    done
}

# Pass when an in-archive hard link is accepted in both formats.
test_unit_accepts_hard_link() {
    local fmt
    for fmt in gnu bb; do
        expect_accept "$fmt" top d:top/ f:top/a h:top/b:top/a || return 1
    done
}

# Pass when an empty archive is rejected.
test_unit_rejects_empty_archive() {
    expect_reject gnu "The archive is empty" || return 1
    expect_reject bb "The archive is empty" || return 1
}

# Pass when the two listings have a different line count.
test_unit_rejects_line_count_mismatch() {
    check_raw $'top/\ntop/a\n' $'drwxr-xr-x u/g 0 2026-11-06 12:00 top/\n' || return 1
    assert_eq "1" "$CHK_RC" "line count mismatch must be rejected" || return 1
    assert_eq "" "$CHK_TOP" "no top name on mismatch" || return 1
    assert_contains "$(sandbox_log error.log)" "not consistent" "error.log text" || return 1
}

# Pass when absolute member names are rejected in both formats.
test_unit_rejects_absolute_names() {
    local fmt
    for fmt in gnu bb; do
        expect_reject "$fmt" "Unsafe member name" f:/etc/passwd || return 1
        expect_reject "$fmt" "Unsafe member name" d:top/ f:/etc/passwd || return 1
    done
}

# Pass when member names with a ".." part are rejected in both formats.
test_unit_rejects_dotdot_names() {
    local fmt
    for fmt in gnu bb; do
        expect_reject "$fmt" "Unsafe member name" f:top/../x || return 1
        expect_reject "$fmt" "Unsafe member name" f:../x || return 1
        expect_reject "$fmt" "Unsafe member name" f:top/.. || return 1
        expect_reject "$fmt" "Unsafe member name" d:top/ f:top/sub/../../../x || return 1
    done
}

# Pass when a second top-level entry is rejected in both formats.
test_unit_rejects_two_top_level_entries() {
    local fmt
    for fmt in gnu bb; do
        expect_reject "$fmt" "more than one top-level entry" f:top/a f:other/b || return 1
        expect_reject "$fmt" "more than one top-level entry" d:top/ d:other/ || return 1
    done
}

# Pass when a member that goes through a symbolic link member is rejected.
# The check runs in both orders: the link first, and the link after the member.
test_unit_rejects_symlink_through_member() {
    local fmt
    for fmt in gnu bb; do
        expect_reject "$fmt" "goes through the symbolic link" \
            l:top/cfg:/outside f:top/cfg/.env || return 1
        expect_reject "$fmt" "goes through the symbolic link" \
            f:top/cfg/.env l:top/cfg:/outside || return 1
        expect_reject "$fmt" "goes through the symbolic link" \
            l:top/a/b:/outside f:top/a/b/c/d || return 1
        expect_reject "$fmt" "goes through the symbolic link" \
            d:top/ l:top/cfg:/outside f:top/cfg/sub/file || return 1
    done
}

# Pass when a hard link with an absolute, ".." or other top-level target is rejected.
test_unit_rejects_unsafe_hard_links() {
    local fmt
    for fmt in gnu bb; do
        expect_reject "$fmt" "Unsafe hard link" f:top/a h:top/b:/etc/passwd || return 1
        expect_reject "$fmt" "Unsafe hard link" f:top/a h:top/b:top/../../x || return 1
        expect_reject "$fmt" "Unsafe hard link" f:top/a h:top/b:other/x || return 1
        expect_reject "$fmt" "Unsafe hard link" f:top/a h:top/b:../x || return 1
    done
}

# Pass when a hard link whose target goes through a symbolic link is rejected.
# Known bug: the check accepts it. BusyBox tar then links to the outside file.
test_known_bug_unit_hard_link_through_symlink() {
    local fmt
    for fmt in gnu bb; do
        check_entries "$fmt" l:top/cfg:/outside h:top/h:top/cfg/secret || return 1
        assert_eq "1" "$CHK_RC" "hard link through a symbolic link ($fmt) must be rejected" || return 1
    done
}

# Pass when a member name with "/./" or "//" that goes through a link is rejected.
# Known bug: the check compares the raw path text, so it misses these names.
test_known_bug_unit_path_text_bypass() {
    check_entries gnu l:top/cfg:/outside f:top/./cfg/.env || return 1
    assert_eq "1" "$CHK_RC" "top/./cfg/.env must be rejected" || return 1
    check_entries gnu l:top/cfg:/outside f:top//cfg/.env || return 1
    assert_eq "1" "$CHK_RC" "top//cfg/.env must be rejected" || return 1
}

# ---------------------------------------------------------------------
# Integration tests: bin/download.sh
# ---------------------------------------------------------------------

# Build a crafted archive: a symbolic link "cfg" to the outside folder.
# Restore 1 uses it. Restore 2 has the member "cfg/.env" with no directory entry.
# Args: <runner> where runner is run_cmd (GNU tar) or run_busybox (BusyBox tar)
attack_two_restores() {
    local runner="$1"
    new_sandbox 2 || return 1
    mkdir -p -- "$CRAFT/a1" "$CRAFT/a2/cfg" || return 1
    ln -s -- "$OUTSIDE" "$CRAFT/a1/cfg" || return 1
    tar -C "$CRAFT/a1" -cf "$CRAFT/attack1.tar" cfg || return 1
    printf 'PWNED\n' > "$CRAFT/a2/cfg/.env" || return 1
    tar -C "$CRAFT/a2" -cf "$CRAFT/attack2.tar" cfg/.env || return 1
    assert_eq "cfg/.env" "$(tar -tf "$CRAFT/attack2.tar")" "attack 2 has only the file member" || return 1
    store_crafted attack1 "$CRAFT/attack1.tar" || return 1
    store_crafted attack2 "$CRAFT/attack2.tar" || return 1

    "$runner" "$DOWNLOAD" attack1 "$TARGET"
    assert_eq "0" "$RUN_RC" "restore 1 exit code ($runner)" || return 1
    assert_eq "$OUTSIDE" "$(readlink -- "$TARGET/cfg")" "restore 1 plants the symbolic link" || return 1

    "$runner" "$DOWNLOAD" attack2 "$TARGET"
    assert_eq "1" "$RUN_RC" "restore 2 exit code ($runner)" || return 1
    assert_contains "$(sandbox_log error.log)" "exists" "restore 2 error.log text ($runner)" || return 1
    assert_eq "keep" "$(cat -- "$OUTSIDE/.env")" "outside file unchanged ($runner)" || return 1
    assert_eq ".env" "$(ls -A -- "$OUTSIDE")" "no new file outside ($runner)" || return 1
    assert_eq "$OUTSIDE" "$(readlink -- "$TARGET/cfg")" "restore 1 link intact ($runner)" || return 1
    assert_clean "$TARGET" || return 1
    if [[ "$runner" == run_busybox ]]; then
        assert_file_exists "$BB_BIN/calls.log" "BusyBox tar wrapper was used" || return 1
    fi
}

# Pass when the two-restore attack is refused with GNU tar.
test_two_restore_attack_gnu() {
    attack_two_restores run_cmd
}

# Pass when the two-restore attack is refused with BusyBox tar.
test_two_restore_attack_busybox() {
    attack_two_restores run_busybox
}

# Pass when a file through a symbolic link in the same archive is refused.
# Both orders are tested. Each order builds the archive with tar -cf and tar -rf.
test_within_archive_symlink_through() {
    local d
    new_sandbox 2 || return 1

    # Order 1: the link first, then the file through the link.
    d="$CRAFT/w1"
    mkdir -p -- "$d/top" || return 1
    ln -s -- "$OUTSIDE" "$d/top/cfg" || return 1
    tar -C "$d" -cf "$CRAFT/within1.tar" top || return 1
    rm -f -- "$d/top/cfg" || return 1
    mkdir -p -- "$d/top/cfg" || return 1
    printf 'PWNED\n' > "$d/top/cfg/.env" || return 1
    tar -C "$d" -rf "$CRAFT/within1.tar" top/cfg/.env || return 1
    assert_contains "$(tar -tvf "$CRAFT/within1.tar")" "top/cfg -> " "order 1 has the link" || return 1
    store_crafted within1 "$CRAFT/within1.tar" || return 1

    run_cmd "$DOWNLOAD" within1 "$TARGET"
    assert_eq "1" "$RUN_RC" "order 1 exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "goes through the symbolic link" "order 1 error.log" || return 1
    assert_eq "keep" "$(cat -- "$OUTSIDE/.env")" "order 1: target unchanged" || return 1
    assert_file_missing "$TARGET/top" "order 1: nothing restored" || return 1
    assert_clean "$TARGET" || return 1

    # Order 2: the file through the path first, then the link.
    d="$CRAFT/w2"
    mkdir -p -- "$d/top/cfg" || return 1
    printf 'PWNED\n' > "$d/top/cfg/.env" || return 1
    tar -C "$d" -cf "$CRAFT/within2.tar" top || return 1
    rm -rf -- "$d/top/cfg" || return 1
    ln -s -- "$OUTSIDE" "$d/top/cfg" || return 1
    tar -C "$d" -rf "$CRAFT/within2.tar" top/cfg || return 1
    store_crafted within2 "$CRAFT/within2.tar" || return 1

    run_cmd "$DOWNLOAD" within2 "$TARGET"
    assert_eq "1" "$RUN_RC" "order 2 exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "goes through the symbolic link" "order 2 error.log" || return 1
    assert_eq "keep" "$(cat -- "$OUTSIDE/.env")" "order 2: target unchanged" || return 1
    assert_file_missing "$TARGET/top" "order 2: nothing restored" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when an absolute member (made with tar -P) is refused and the file is unchanged.
test_absolute_member_refused() {
    local victim
    new_sandbox 2 || return 1
    # Set the path after the sandbox exists. It is an absolute path.
    victim="$SANDBOX_DIR/src/abs.txt"
    mkdir -p -- "$SANDBOX_DIR/src" || return 1
    printf 'ARCHIVED\n' > "$victim" || return 1
    tar -P -cf "$CRAFT/abs.tar" "$victim" || return 1
    assert_eq "$victim" "$(tar -tf "$CRAFT/abs.tar")" "archive has the absolute name" || return 1
    store_crafted abs "$CRAFT/abs.tar" || return 1

    # Change the file after the archive is made. A restore must not change it back.
    printf 'VICTIM\n' > "$victim" || return 1
    run_cmd "$DOWNLOAD" abs "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "unsafe members" "error.log text" || return 1
    assert_eq "VICTIM" "$(cat -- "$victim")" "file outside is unchanged" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a legit backup with relative and absolute links restores with the links intact.
# Args: <runner> where runner is run_cmd (GNU tar) or run_busybox (BusyBox tar)
check_legit_links_round_trip() {
    local runner="$1"
    new_sandbox 2 || return 1
    make_tree || return 1
    upload_content "$SANDBOX_DIR/src/tree" legit || return 1

    "$runner" "$DOWNLOAD" legit "$TARGET"
    assert_eq "0" "$RUN_RC" "download exit code ($runner)" || return 1
    assert_eq "real.txt" "$(readlink -- "$TARGET/tree/rel")" "relative link target ($runner)" || return 1
    assert_eq "$SANDBOX_DIR/src/tree/real.txt" "$(readlink -- "$TARGET/tree/abs")" \
        "absolute link target ($runner)" || return 1
    assert_eq "real data" "$(cat -- "$TARGET/tree/rel")" "read through the relative link ($runner)" || return 1
    assert_eq "$(file_hash "$SANDBOX_DIR/src/tree/real.txt")" "$(file_hash "$TARGET/tree/real.txt")" \
        "sha256 of the real file ($runner)" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a legit backup with links restores with GNU tar.
test_legit_links_round_trip_gnu() {
    check_legit_links_round_trip run_cmd
}

# Pass when a legit backup with links restores with BusyBox tar.
test_legit_links_round_trip_busybox() {
    check_legit_links_round_trip run_busybox
}

# Pass when the same archive restores twice into one folder: the second run is refused.
# The first restore must stay intact.
test_restore_same_archive_twice() {
    new_sandbox 2 || return 1
    make_tree || return 1
    upload_content "$SANDBOX_DIR/src/tree" twice || return 1

    run_cmd "$DOWNLOAD" twice "$TARGET"
    assert_eq "0" "$RUN_RC" "first restore exit code" || return 1
    local want
    want="$(file_hash "$TARGET/tree/real.txt")"

    run_cmd "$DOWNLOAD" twice "$TARGET"
    assert_eq "1" "$RUN_RC" "second restore exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "exists" "second restore error.log text" || return 1
    assert_eq "$want" "$(file_hash "$TARGET/tree/real.txt")" "first restore intact" || return 1
    assert_eq "$SANDBOX_DIR/src/tree/real.txt" "$(readlink -- "$TARGET/tree/abs")" \
        "first restore link intact" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when an extraction failure after the check leaves no staging folder.
# The archive has a hard link whose target is not in the archive.
test_extraction_failure_leaves_no_staging() {
    new_sandbox 2 || return 1
    mkdir -p -- "$CRAFT/xf/src/top" || return 1
    printf 'x\n' > "$CRAFT/xf/src/top/a" || return 1
    ln -- "$CRAFT/xf/src/top/a" "$CRAFT/xf/src/top/b" || return 1
    tar -C "$CRAFT/xf/src" -cf "$CRAFT/xfail.tar" top || return 1
    tar -f "$CRAFT/xfail.tar" --delete top/a || return 1
    store_crafted xfail "$CRAFT/xfail.tar" || return 1

    run_cmd "$DOWNLOAD" xfail "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Extraction failed" "error.log text" || return 1
    assert_file_missing "$TARGET/top" "nothing restored" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a corrupt part is refused by the manifest, with no target folder.
test_corrupt_part_refused_by_manifest() {
    new_sandbox 2 || return 1
    make_tree || return 1
    upload_content "$SANDBOX_DIR/src/tree" corrupt || return 1
    head -c 50000 /dev/urandom > "$MOCK_STORAGE_DIR/acct0/$(part_name corrupt 0)" || return 1

    run_cmd "$DOWNLOAD" corrupt "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "does not match its manifest" \
        "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after a manifest refusal" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when a corrupt part gives exit 1 and the "Extraction failed" log entry.
# The manifest is removed first, so the extraction check is the one that fails.
test_corrupt_part_logs_extraction_failed() {
    new_sandbox 2 || return 1
    make_tree || return 1
    upload_content "$SANDBOX_DIR/src/tree" corrupt || return 1
    head -c 50000 /dev/urandom > "$MOCK_STORAGE_DIR/acct0/$(part_name corrupt 0)" || return 1
    assert_file_exists "$(manifest_path corrupt)" "manifest exists after the upload" || return 1
    rm -f -- "$(manifest_path corrupt)" || return 1
    rm -f -- "$MPARCHIVE_LOG_DIR/error.log" || return 1

    run_cmd "$DOWNLOAD" corrupt "$TARGET"
    assert_eq "1" "$RUN_RC" "exit code" || return 1
    assert_contains "$(sandbox_log error.log)" "Extraction failed" "error.log text" || return 1
    assert_file_missing "$TARGET" "no target folder after a corrupt part" || return 1
    assert_clean "$TARGET" || return 1
}

# Pass when the hard link to a file outside the folder is refused with BusyBox tar.
# The archive has a link "cfg" and a hard link "top/h" to "top/cfg/secret".
# Known bug: the check accepts it. BusyBox tar then links "top/h" to the outside file.
test_known_bug_hard_link_through_symlink_busybox() {
    local d
    new_sandbox 2 || return 1
    # Set the path after the sandbox exists. An earlier path leaks a folder.
    d="$CRAFT/hl"
    printf 'secret\n' > "$OUTSIDE/secret" || return 1
    mkdir -p -- "$d/src/top/d" || return 1
    printf 'inside\n' > "$d/src/top/d/secret" || return 1
    ln -- "$d/src/top/d/secret" "$d/src/top/h" || return 1
    ln -s -- "$OUTSIDE" "$d/src/top/cfg" || return 1
    tar -C "$d/src" -cf "$CRAFT/hardlink.tar" --transform='s,^top/d/secret$,top/cfg/secret,' \
        top/cfg top/d/secret top/h || return 1
    tar -f "$CRAFT/hardlink.tar" --delete top/cfg/secret || return 1
    store_crafted hardlink "$CRAFT/hardlink.tar" || return 1

    run_busybox "$DOWNLOAD" hardlink "$TARGET"
    assert_eq "1" "$RUN_RC" "restore must be refused" || return 1
    assert_file_missing "$TARGET/top" "nothing restored" || return 1
    assert_eq "1" "$(stat -c %h -- "$OUTSIDE/secret")" "no hard link to the outside file" || return 1
}

# Pass when the real error.log and activity.log did not change during the run.
test_real_logs_untouched() {
    local after
    after="$(real_logs_state)"
    assert_eq "$REAL_LOGS_BEFORE" "$after" "real logs must not change" || return 1
}

# ---------------------------------------------------------------------
# Run the tests. The unit tests run first, in the sandbox from this line.
# ---------------------------------------------------------------------

new_sandbox 1 || { echo "cannot create the sandbox" >&2; exit 1; }

run_test "accepts plain tree in GNU and BusyBox form" test_unit_accepts_plain_tree
run_test "accepts a dot slash prefix" test_unit_accepts_dot_slash_prefix
run_test "accepts relative and absolute symlink members" test_unit_accepts_symlink_members
run_test "accepts a name that only looks like a link path" test_unit_accepts_similar_name_after_link
run_test "accepts an in-archive hard link" test_unit_accepts_hard_link
run_test "rejects an empty archive" test_unit_rejects_empty_archive
run_test "rejects a line count mismatch" test_unit_rejects_line_count_mismatch
run_test "rejects absolute member names" test_unit_rejects_absolute_names
run_test "rejects member names with a .. part" test_unit_rejects_dotdot_names
run_test "rejects two top-level entries" test_unit_rejects_two_top_level_entries
run_test "rejects a member through a symlink member" test_unit_rejects_symlink_through_member
run_test "rejects unsafe hard link targets" test_unit_rejects_unsafe_hard_links
run_known_bug "hard link through a symlink is rejected (unit)" test_known_bug_unit_hard_link_through_symlink
run_known_bug "member path with ./ or // through a symlink is rejected (unit)" test_known_bug_unit_path_text_bypass

# Integration tests make their own sandbox. Each one removes the last sandbox.
run_test "two-restore attack is refused with GNU tar" test_two_restore_attack_gnu
run_busybox_test "two-restore attack is refused with BusyBox tar" test_two_restore_attack_busybox
run_test "file through a symlink in the same archive is refused" test_within_archive_symlink_through
run_test "absolute member is refused" test_absolute_member_refused
run_test "legit backup with links restores with GNU tar" test_legit_links_round_trip_gnu
run_busybox_test "legit backup with links restores with BusyBox tar" test_legit_links_round_trip_busybox
run_test "same archive twice into one folder is refused" test_restore_same_archive_twice
run_test "extraction failure leaves no staging folder" test_extraction_failure_leaves_no_staging
run_test "corrupt part is refused by the manifest" test_corrupt_part_refused_by_manifest
run_test "corrupt part logs Extraction failed" test_corrupt_part_logs_extraction_failed
run_known_bug "hard link to an outside file is refused with BusyBox tar" test_known_bug_hard_link_through_symlink_busybox
run_test "real logs untouched" test_real_logs_untouched

finish_tests
