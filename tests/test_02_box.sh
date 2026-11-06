#!/usr/bin/env bash
# Offline tests for the Box provider, bin/lib/providers/box.sh.
# No network call is made. The HTTP seam, box_http, is replaced by a mock.
# The mock returns canned responses and records every call.
# One test runs the real box_http with a fake curl script. It checks the token path.
# Run with: bash tests/test_02_box.sh

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"
source "$REPO_ROOT/bin/lib/common.sh"

BOX_SH="$REPO_ROOT/bin/lib/providers/box.sh"
BOX_TEST_TOKEN="FAKE-TOKEN-123"

# ---------------------------------------------------------------------------
# Canned folder listings. Entries are flat objects, as with fields=name.
# ---------------------------------------------------------------------------

ORDER_JSON='"order":[{"by":"type","direction":"ASC"},{"by":"name","direction":"ASC"}]'

# An empty folder.
LIST_EMPTY='{"total_count":0,"entries":[],"offset":0,"limit":1000,'"$ORDER_JSON"'}'

# One folder and three files. Only x.p0 and x.p1 belong to archive "x".
LIST_MIXED='{"total_count":4,"entries":[{"type":"folder","id":"900","name":"x.p2.tar.gz"},{"type":"file","id":"101","name":"x.p0.tar.gz"},{"type":"file","id":"102","name":"x.p1.tar.gz"},{"type":"file","id":"103","name":"y.p0.tar.gz"}],"offset":0,"limit":1000,'"$ORDER_JSON"'}'

# Two pages. Page 1 holds 2 of the 3 entries, so page 2 is needed.
LIST_PAGE1='{"total_count":3,"entries":[{"type":"folder","id":"900","name":"x.p2.tar.gz"},{"type":"file","id":"101","name":"x.p0.tar.gz"}],"offset":0,"limit":1000,'"$ORDER_JSON"'}'
LIST_PAGE2='{"total_count":3,"entries":[{"type":"file","id":"102","name":"x.p1.tar.gz"}],"offset":2,"limit":1000,'"$ORDER_JSON"'}'

# One file, x.p0.tar.gz, with id 777.
LIST_ONE_777='{"total_count":1,"entries":[{"type":"file","id":"777","name":"x.p0.tar.gz"}],"offset":0,"limit":1000,'"$ORDER_JSON"'}'

# A Box error for a name that is in use.
CONFLICT_409='{"type":"error","status":409,"code":"item_name_in_use","message":"Item with the same name already exists","context_info":{"conflicts":{"type":"file","id":"888","sequence_id":"0","etag":"0","sha1":"0000","name":"x.p0.tar.gz"}}}'

# ---------------------------------------------------------------------------
# Mock HTTP layer
# ---------------------------------------------------------------------------
# Routes are lines in $MOCK_DIR/routes.txt. Each line has six fields:
#   method|url-glob|code|body-file|response-header|repeat
# A route with repeat "*" answers every call. Other routes answer once.
# The first matching route answers the call.

# Start a new mock. Call after setup_sandbox.
mock_reset() {
    MOCK_DIR="$SANDBOX_DIR/mock"
    rm -rf -- "$MOCK_DIR"
    mkdir -p -- "$MOCK_DIR/bodies" "$MOCK_DIR/uploads" "$MOCK_DIR/parts" || return 1
    : >"$MOCK_DIR/routes.txt"
    : >"$MOCK_DIR/calls.txt"
    : >"$MOCK_DIR/unmatched.txt"
}

# Add a canned response.
# Args: <method> <url-glob> <code> <body> [response-header] [sticky]
# Pass "sticky" as the last argument to answer every call.
mock_route() {
    local method="$1" pattern="$2" code="$3" body="$4" header="${5:-}" flag="${6:-}"
    local count bodyfile rep=1
    count="$(ls -1 "$MOCK_DIR/bodies" | wc -l | tr -d ' ')"
    bodyfile="$MOCK_DIR/bodies/route-$((count + 1))"
    printf '%s' "$body" >"$bodyfile"
    if [[ "$flag" == sticky ]]; then
        rep="*"
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$method" "$pattern" "$code" "$bodyfile" "$header" "$rep" \
        >>"$MOCK_DIR/routes.txt"
}

# Record one call. Args: <idx> <method> <url> [curl args...]
_mock_record() {
    local idx="$1" method="$2" url="$3" a joined=""
    shift 3
    for a in "$@"; do
        joined="${joined:+${joined} | }${a}"
    done
    printf '%s\t%s\t%s\t%s\n' "$idx" "$method" "$url" "$joined" >>"$MOCK_DIR/calls.txt"
}

# Copy the upload part and the upload file, so the test can check their bytes.
# The name uses the call number, padded, so that the glob keeps the order.
_mock_capture() {
    local a prev="" seq p
    printf -v seq '%06d' "$(wc -l <"$MOCK_DIR/calls.txt" | tr -d ' ')"
    for a in "$@"; do
        case "$a" in
            file=@*)
                # The form value is file=@"<path>". Remove the quotes.
                p="${a#file=@}"
                p="${p#\"}"
                p="${p%\"}"
                cp -- "$p" "$MOCK_DIR/uploads/$seq"
                ;;
        esac
        if [[ "$prev" == "--data-binary" && "$a" == @* ]]; then
            cp -- "${a#@}" "$MOCK_DIR/parts/$seq"
        fi
        prev="$a"
    done
    return 0
}

# Print the number of the first route that matches. Return 1 if none does.
_mock_find() {
    local method="$1" url="$2" n=0 line m p
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        IFS='|' read -r m p _ <<<"$line"
        if [[ "$m" == "$method" && "$url" == $p ]]; then
            printf '%s\n' "$n"
            return 0
        fi
    done <"$MOCK_DIR/routes.txt"
    return 1
}

# Write the response header file when the caller passed -D.
# Args: <code> <header> [curl args...]
_mock_write_header() {
    local code="$1" header="$2" prev="" a
    shift 2
    for a in "$@"; do
        if [[ "$prev" == "-D" ]]; then
            printf 'HTTP/1.1 %s Mock\r\n' "$code" >"$a"
            if [[ -n "$header" ]]; then
                printf '%s\r\n' "$header" >>"$a"
            fi
            printf '\r\n' >>"$a"
        fi
        prev="$a"
    done
    return 0
}

# The mock for box_http. It has the same arguments and output as the real function.
mock_box_http() {
    local idx="$1" method="$2" url="$3" out="$4" n line m p c bf hf rep
    shift 4
    _mock_record "$idx" "$method" "$url" "$@"
    _mock_capture "$@"
    # An unknown call gets code 418. The box_request function treats it as an error.
    if ! n="$(_mock_find "$method" "$url")"; then
        printf '%s %s\n' "$method" "$url" >>"$MOCK_DIR/unmatched.txt"
        : >"$out"
        printf '418'
        return 0
    fi
    line="$(sed -n "${n}p" "$MOCK_DIR/routes.txt")"
    IFS='|' read -r m p c bf hf rep <<<"$line"
    # A one-shot route is removed after its use.
    if [[ "$rep" != "*" ]]; then
        sed -i "${n}d" "$MOCK_DIR/routes.txt"
    fi
    cp -- "$bf" "$out"
    _mock_write_header "$c" "$hf" "$@"
    printf '%s' "$c"
}

# Print the recorded calls that match a method and a URL glob.
# Each line: idx, method, url, and the curl args joined with " | ".
mock_calls() {
    local method="$1" pattern="$2" idx m u a
    while IFS=$'\t' read -r idx m u a; do
        if [[ "$m" == "$method" && "$u" == $pattern ]]; then
            printf '%s\t%s\t%s\t%s\n' "$idx" "$m" "$u" "$a"
        fi
    done <"$MOCK_DIR/calls.txt"
}

# Print the number of recorded calls that match a method and a URL glob.
mock_count() {
    mock_calls "$1" "$2" | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# Test setup helpers
# ---------------------------------------------------------------------------

# Start a sandbox and a fresh mock. Call first in each test.
box_begin() {
    unset MPARCHIVE_CURL SHIM_LOG SHIM_AUTH
    setup_sandbox 1 || return 1
    mock_reset || return 1
}

# Set the account and the settings for a test. Args: [chunk threshold].
_box_settings() {
    local threshold="${1:-}"
    MPA_ACCOUNTS=('{"developer_token":"FAKE-TOKEN-123"}')
    MPA_ACCOUNT_COUNT=1
    BOX_FOLDER_ID=0
    BOX_RETRY_SLEEP=0
    if [[ -n "$threshold" ]]; then
        BOX_CHUNK_THRESHOLD="$threshold"
    else
        unset BOX_CHUNK_THRESHOLD
    fi
    provider_init
}

# Load the provider with the mock box_http. Args: [chunk threshold].
box_setup() {
    source "$BOX_SH"
    # Replace the HTTP seam. The mock sends no token and no network call.
    box_http() { mock_box_http "$@"; }
    _box_settings "${1:-}"
}

# Load the provider with the real box_http. Args: [chunk threshold].
box_setup_real() {
    source "$BOX_SH"
    _box_settings "${1:-}"
}

# Check that every mock call had a route. Then remove the sandbox.
box_end() {
    local unmatched
    unmatched="$(cat "$MOCK_DIR/unmatched.txt" 2>/dev/null)"
    if ! assert_eq "" "$unmatched" "every mock call must have a route"; then
        teardown_sandbox
        return 1
    fi
    teardown_sandbox
}

# Print the known SHA-1 (base64) of a test text. These fixed values are the
# independent reference. They were calculated one time with a different tool.
# Return 1 for a text that is not in the table.
ref_sha1_text() {
    case "$1" in
        "") printf '%s' "2jmj7l5rSw0yVb/vlWAYkK/YBwk=" ;;
        "0123") printf '%s' "xLXIa9V32j2T/qfInLphx4tI5Yk=" ;;
        "4567") printf '%s' "g3h/BgpZSTrv3NSyNpmQ5zA+GG4=" ;;
        "89") printf '%s' "FrBr2bc4g14tE0/o1ZbpqwCGqYU=" ;;
        "0123456789") printf '%s' "h6zsF82dzSCnFsws9nQXtxyKcBY=" ;;
        "seq 1 2000") printf '%s' "djzqscH5FlxFAxyGMTwW8suwrQw=" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Tests: settings
# ---------------------------------------------------------------------------

# Check the folder id rules in provider_init.
test_init_folder_id_rules() {
    box_begin || return 1
    source "$BOX_SH"
    # A folder id with letters is rejected.
    BOX_FOLDER_ID="abc"
    assert_exit_code 2 provider_init || return 1
    # An unset folder id means the root folder, 0.
    unset BOX_FOLDER_ID
    provider_init || return 1
    assert_eq "0" "$BOX_FOLDER_ID" || return 1
    # A numeric folder id is kept.
    BOX_FOLDER_ID="123"
    provider_init || return 1
    assert_eq "123" "$BOX_FOLDER_ID" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: free space
# ---------------------------------------------------------------------------

# Check the free space math and the request URL.
test_free_space_math() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*users/me*' 200 '{"type":"user","space_amount":10000,"space_used":2500}' "" sticky
    assert_eq "7500" "$(provider_get_free_space 0)" || return 1
    assert_contains "$(mock_calls GET '*users/me*')" \
        "https://api.box.com/2.0/users/me?fields=space_amount,space_used" || return 1
    box_end
}

# Check that a negative or huge quota means unlimited storage.
test_free_space_unlimited() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*users/me*' 200 '{"type":"user","space_amount":-1,"space_used":5}'
    mock_route GET '*users/me*' 200 '{"type":"user","space_amount":1000000000000000,"space_used":5}'
    assert_eq "999999999999999" "$(provider_get_free_space 0)" || return 1
    assert_eq "999999999999999" "$(provider_get_free_space 0)" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: listing, find and delete
# ---------------------------------------------------------------------------

# Check that only files of archive "x" are listed. Folders and other archives are skipped.
test_list_files_filters() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_MIXED" "" sticky
    local expected
    expected=$'101\tx.p0.tar.gz\n102\tx.p1.tar.gz'
    assert_eq "$expected" "$(provider_list_files 0 x)" || return 1
    assert_eq "" "$(provider_list_files 0 zz)" || return 1
    assert_contains "$(mock_calls GET '*folders/0/items*')" \
        "https://api.box.com/2.0/folders/0/items?fields=name&limit=1000&offset=0" || return 1
    box_end
}

# Check that a second page is requested with the offset of the entries read so far.
test_list_files_pagination() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_PAGE1" "" sticky
    mock_route GET '*folders/0/items*offset=2' 200 "$LIST_PAGE2" "" sticky
    local expected
    expected=$'101\tx.p0.tar.gz\n102\tx.p1.tar.gz'
    assert_eq "$expected" "$(provider_list_files 0 x)" || return 1
    assert_eq "2" "$(mock_count GET '*folders/0/items*')" || return 1
    assert_eq "1" "$(mock_count GET '*folders/0/items*offset=2')" || return 1
    box_end
}

# Check the find rules. A folder with the same name is not a file.
test_find_file() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_MIXED" "" sticky
    assert_eq "102" "$(provider_find_file 0 x.p1.tar.gz)" || return 1
    assert_exit_code 0 provider_find_file 0 x.p1.tar.gz || return 1
    assert_exit_code 1 provider_find_file 0 x.p9.tar.gz || return 1
    assert_exit_code 1 provider_find_file 0 x.p2.tar.gz || return 1
    box_end
}

# Check the delete rules. A found file gets a DELETE call. A missing file gets return 1.
test_delete_found_and_missing() {
    box_begin || return 1
    box_setup || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_MIXED" "" sticky
    mock_route DELETE '*/files/102' 204
    assert_exit_code 0 provider_delete_file 0 x.p1.tar.gz || return 1
    assert_exit_code 1 provider_delete_file 0 x.p9.tar.gz || return 1
    assert_eq "1" "$(mock_count DELETE '*')" || return 1
    assert_contains "$(mock_calls DELETE '*')" "https://api.box.com/2.0/files/102" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: simple upload
# ---------------------------------------------------------------------------

# Check a new file with spaces in the local path. The content must arrive intact.
test_upload_new_file_with_spaces() {
    box_begin || return 1
    box_setup || return 1
    local dir="$SANDBOX_DIR/my files" rc=0
    mkdir -p -- "$dir" || return 1
    printf 'hello box' >"$dir/local file.bin" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/content' 201 '{"total_count":1,"entries":[{"type":"file","id":"555","name":"x.p0.tar.gz"}]}'
    provider_upload_file 0 "$dir/local file.bin" "x.p0.tar.gz" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "1" "$(mock_count POST '*/files/content')" || return 1
    assert_contains "$(mock_calls POST '*/files/content')" \
        'attributes={"name":"x.p0.tar.gz","parent":{"id":"0"}}' || return 1
    assert_eq "hello box" "$(cat "$MOCK_DIR"/uploads/*)" || return 1
    box_end
}

# Check a new version. An existing file id gets the content route for that id.
test_upload_new_version() {
    box_begin || return 1
    box_setup || return 1
    local file="$SANDBOX_DIR/v.bin" rc=0
    printf 'version two' >"$file" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_ONE_777" "" sticky
    mock_route POST '*/files/777/content' 201 '{"total_count":1,"entries":[{"type":"file","id":"777","name":"x.p0.tar.gz"}]}'
    provider_upload_file 0 "$file" "x.p0.tar.gz" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "1" "$(mock_count POST '*/files/777/content')" || return 1
    assert_eq "0" "$(mock_count POST '*/files/content')" || return 1
    assert_contains "$(mock_calls POST '*/files/777/content')" \
        'attributes={"name":"x.p0.tar.gz"}' || return 1
    assert_eq "version two" "$(cat "$MOCK_DIR"/uploads/*)" || return 1
    box_end
}

# Check the 409 fallback. A new-file 409 gives a conflict id. The upload then goes to that id.
test_upload_409_fallback() {
    box_begin || return 1
    box_setup || return 1
    local file="$SANDBOX_DIR/c.bin" rc=0
    printf 'hello' >"$file" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/content' 409 "$CONFLICT_409"
    mock_route POST '*/files/888/content' 201 '{"total_count":1,"entries":[{"type":"file","id":"888","name":"x.p0.tar.gz"}]}'
    provider_upload_file 0 "$file" "x.p0.tar.gz" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "1" "$(mock_count POST '*/files/content')" || return 1
    assert_eq "1" "$(mock_count POST '*/files/888/content')" || return 1
    # Both requests sent the same content.
    assert_eq "hellohello" "$(cat "$MOCK_DIR"/uploads/*)" || return 1
    box_end
}

# Check that a 0-byte file uploads with the simple path.
test_upload_empty_file() {
    box_begin || return 1
    box_setup || return 1
    local file="$SANDBOX_DIR/empty.bin" rc=0
    : >"$file" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/content' 201 '{"total_count":1,"entries":[{"type":"file","id":"556","name":"x.p0.tar.gz"}]}'
    provider_upload_file 0 "$file" "x.p0.tar.gz" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "1" "$(mock_count POST '*/files/content')" || return 1
    assert_eq "0" "$(stat -c %s "$MOCK_DIR"/uploads/*)" || return 1
    box_end
}

# Check a relative local path. The provider resolves it from the current folder.
test_upload_relative_path() {
    box_begin || return 1
    box_setup || return 1
    local dir="$SANDBOX_DIR/rel dir" rc=0
    mkdir -p -- "$dir" || return 1
    printf 'hello box' >"$dir/local file.bin" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/content' 201 '{"total_count":1,"entries":[{"type":"file","id":"557","name":"x.p0.tar.gz"}]}'
    ( cd -- "$dir" && provider_upload_file 0 "local file.bin" "x.p0.tar.gz" ) || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "hello box" "$(cat "$MOCK_DIR"/uploads/*)" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: chunked upload
# ---------------------------------------------------------------------------

# Check the chunked flow with a 10-byte file, a threshold of 5 and parts of 4 bytes.
# Expect 3 parts, Content-Range values, a commit with the 202 retry, and the 201 result.
test_chunked_upload_flow() {
    box_begin || return 1
    box_setup 5 || return 1
    local file="$SANDBOX_DIR/big file.bin" rc=0 puts commit
    printf '0123456789' >"$file" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/upload_sessions' 201 '{"type":"upload_session","id":"SID1","part_size":4,"total_parts":3,"num_parts_processed":0}'
    mock_route PUT '*/files/upload_sessions/SID1' 200 '{"part":{"part_id":"P0","offset":0,"size":4,"sha1":"s0"}}'
    mock_route PUT '*/files/upload_sessions/SID1' 200 '{"part":{"part_id":"P1","offset":4,"size":4,"sha1":"s1"}}'
    mock_route PUT '*/files/upload_sessions/SID1' 200 '{"part":{"part_id":"P2","offset":8,"size":2,"sha1":"s2"}}'
    # The first commit answers 202 (not ready). The second answers 201 (done).
    mock_route POST '*/upload_sessions/SID1/commit' 202 '' 'Retry-After: 0'
    mock_route POST '*/upload_sessions/SID1/commit' 201 '{"total_count":1,"entries":[{"type":"file","id":"999","name":"x.p0.tar.gz"}]}'
    provider_upload_file 0 "$file" "x.p0.tar.gz" || rc=$?
    assert_eq "0" "$rc" || return 1

    # The session request names the folder, the size and the file.
    assert_contains "$(mock_calls POST '*/files/upload_sessions')" \
        '{"folder_id":"0","file_size":10,"file_name":"x.p0.tar.gz"}' || return 1

    # Three part requests, with the right Content-Range and Digest for each part.
    assert_eq "3" "$(mock_count PUT '*/files/upload_sessions/SID1')" || return 1
    puts="$(mock_calls PUT '*/files/upload_sessions/SID1')"
    assert_contains "$(sed -n 1p <<<"$puts")" "Content-Range: bytes 0-3/10" || return 1
    assert_contains "$(sed -n 2p <<<"$puts")" "Content-Range: bytes 4-7/10" || return 1
    assert_contains "$(sed -n 3p <<<"$puts")" "Content-Range: bytes 8-9/10" || return 1
    assert_contains "$(sed -n 1p <<<"$puts")" "Digest: sha=$(ref_sha1_text "0123")" || return 1
    assert_contains "$(sed -n 2p <<<"$puts")" "Digest: sha=$(ref_sha1_text "4567")" || return 1
    assert_contains "$(sed -n 3p <<<"$puts")" "Digest: sha=$(ref_sha1_text "89")" || return 1

    # The part bytes, in order, rebuild the file.
    assert_eq "0123456789" "$(cat "$MOCK_DIR"/parts/*)" || return 1

    # Two commit calls: the 202 and the retry. The last one has the whole-file Digest and the parts.
    assert_eq "2" "$(mock_count POST '*/upload_sessions/SID1/commit')" || return 1
    commit="$(mock_calls POST '*/upload_sessions/SID1/commit' | tail -n 1)"
    assert_contains "$commit" "Digest: sha=$(ref_sha1_text "0123456789")" || return 1
    assert_contains "$commit" \
        '{"parts":[{"part_id":"P0","offset":0,"size":4,"sha1":"s0"},{"part_id":"P1","offset":4,"size":4,"sha1":"s1"},{"part_id":"P2","offset":8,"size":2,"sha1":"s2"}]}' || return 1

    # Progress is logged per chunk, and no temporary file is left.
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/activity.log")" "chunk 3/3" || return 1
    assert_eq "" "$(ls -A "$MPARCHIVE_TMPDIR")" "the temporary folder must be empty" || return 1
    box_end
}

# Check the cleanup after a failed part. The session is deleted and no commit is sent.
test_chunked_upload_part_failure() {
    box_begin || return 1
    box_setup 5 || return 1
    local file="$SANDBOX_DIR/fail.bin" rc=0
    printf '0123456789' >"$file" || return 1
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_EMPTY" "" sticky
    mock_route POST '*/files/upload_sessions' 201 '{"type":"upload_session","id":"SID1","part_size":4,"total_parts":3,"num_parts_processed":0}'
    mock_route PUT '*/files/upload_sessions/SID1' 200 '{"part":{"part_id":"P0","offset":0,"size":4,"sha1":"s0"}}'
    mock_route PUT '*/files/upload_sessions/SID1' 400 '{"type":"error","status":400,"code":"bad_request","message":"bad part"}'
    mock_route DELETE '*/files/upload_sessions/SID1' 204
    provider_upload_file 0 "$file" "x.p0.tar.gz" || rc=$?
    assert_eq "2" "$rc" || return 1
    assert_eq "1" "$(mock_count DELETE '*/files/upload_sessions/SID1')" || return 1
    assert_eq "0" "$(mock_count POST '*/upload_sessions/SID1/commit')" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "HTTP 400" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: download
# ---------------------------------------------------------------------------

# Check the redirect flow. The first request has the token. The Location request has no token.
test_download_redirect() {
    box_begin || return 1
    box_setup || return 1
    local dest="$SANDBOX_DIR/out.bin" rc=0 first hop
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_ONE_777" "" sticky
    mock_route GET '*/files/777/content' 302 '' 'Location: https://dl.boxcloud.test/file/abc'
    mock_route GET 'https://dl.boxcloud.test/file/abc' 200 'download-bytes'
    provider_download_file 0 "x.p0.tar.gz" "$dest" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "download-bytes" "$(cat "$dest")" || return 1

    # The first request uses the account (idx 0) and saves the headers with -D.
    first="$(mock_calls GET '*/files/777/content')"
    assert_eq "0" "${first%%$'\t'*}" "the first download request must use account 0" || return 1
    assert_contains "$first" "-D" || return 1

    # The redirect target must use idx none, so no token goes to that host.
    hop="$(mock_calls GET 'https://dl.boxcloud.test/file/abc')"
    assert_eq "none" "${hop%%$'\t'*}" "the redirect request must not use the token" || return 1
    assert_contains "$hop" "-L" || return 1
    box_end
}

# Check that an unknown name gives return 1 and makes no download request.
test_download_unknown_name() {
    box_begin || return 1
    box_setup || return 1
    local dest="$SANDBOX_DIR/none.bin" rc=0
    mock_route GET '*folders/0/items*offset=0' 200 "$LIST_ONE_777" "" sticky
    assert_exit_code 1 provider_download_file 0 "x.p9.tar.gz" "$dest" || return 1
    assert_file_missing "$dest" || return 1
    assert_eq "0" "$(mock_count GET '*/files/*/content')" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: errors and retries
# ---------------------------------------------------------------------------

# Check that a 401 gives return 3, a clear message, and no retry.
test_401_is_clear_and_not_retried() {
    box_begin || return 1
    box_setup || return 1
    local rc=0 out
    mock_route GET '*users/me*' 401 '{"type":"error","status":401,"code":"unauthorized","message":"Access token has expired"}'
    out="$(provider_get_free_space 0 2>&1)" || rc=$?
    assert_eq "3" "$rc" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "expired or invalid" || return 1
    assert_eq "1" "$(mock_count GET '*users/me*')" "a 401 must not be retried" || return 1
    assert_not_contains "$out" "$BOX_TEST_TOKEN" || return 1
    box_end
}

# Check the retry on 500. Two failures, then success.
test_retry_then_success() {
    box_begin || return 1
    box_setup || return 1
    local rc=0 out
    mock_route GET '*users/me*' 500 '{"type":"error","status":500,"code":"internal_server_error"}'
    mock_route GET '*users/me*' 500 '{"type":"error","status":500,"code":"internal_server_error"}'
    mock_route GET '*users/me*' 200 '{"type":"user","space_amount":10000,"space_used":2500}'
    out="$(provider_get_free_space 0)" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "7500" "$out" || return 1
    assert_eq "3" "$(mock_count GET '*users/me*')" || return 1
    box_end
}

# Check a permanent 500. The request is sent 4 times (1 try and 3 retries), then the call fails.
test_retry_permanent_failure() {
    box_begin || return 1
    box_setup || return 1
    local rc=0
    mock_route GET '*users/me*' 500 '{"type":"error","status":500,"code":"internal_server_error","message":"boom"}' "" sticky
    provider_get_free_space 0 >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" || return 1
    assert_eq "4" "$(mock_count GET '*users/me*')" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "HTTP 500" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: token handling
# ---------------------------------------------------------------------------

# Check that the token never appears in the logs, the stdout, or the stderr.
test_token_never_in_logs_or_output() {
    box_begin || return 1
    box_setup || return 1
    local rc=0 out leak=0
    mock_route GET '*users/me*' 401 '{"type":"error","status":401,"code":"unauthorized","message":"expired"}'
    out="$(provider_get_free_space 0 2>&1)" || rc=$?
    assert_eq "3" "$rc" || return 1
    assert_not_contains "$out" "$BOX_TEST_TOKEN" || return 1

    # A failing listing call, with the output captured.
    mock_route GET '*folders/0/items*offset=0' 500 '{"type":"error","code":"server_error","message":"boom"}' "" sticky
    out="$(provider_list_files 0 x 2>&1)" || true
    assert_not_contains "$out" "$BOX_TEST_TOKEN" || return 1

    # A passing call, with the output captured.
    mock_route GET '*users/me*' 200 '{"type":"user","space_amount":10000,"space_used":2500}'
    out="$(provider_get_free_space 0 2>&1)" || true
    assert_not_contains "$out" "$BOX_TEST_TOKEN" || return 1

    # The logs must hold the error text, so the search below is not empty.
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "expired or invalid" || return 1
    if grep -rqF -- "$BOX_TEST_TOKEN" "$MPARCHIVE_LOG_DIR"; then
        leak=1
    fi
    assert_eq "0" "$leak" "the token must not be in the log folder" || return 1
    assert_not_contains "$(cat "$MOCK_DIR/calls.txt")" "$BOX_TEST_TOKEN" || return 1
    box_end
}

# Write a fake curl. It never opens a socket. It logs argv without the header file.
# It stores the header file text in SHIM_AUTH, so the test can see where the token goes.
write_fake_curl() {
    local shim="$1"
    cat >"$shim" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for the offline test. It makes no network call.
has_auth=0 out="" hdr="" prev="" a="" url=""
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
        -D) hdr="$a" ;;
    esac
    if [[ "$a" == @* ]]; then
        # An argument with @ is the Authorization header file.
        has_auth=1
        cat -- "${a#@}" >>"$SHIM_AUTH"
    fi
    prev="$a"
    url="$a"
done
printf 'auth=%s url=%s argv=%s\n' "$has_auth" "$url" "$*" >>"$SHIM_LOG"
case "$url" in
    *users/me*) code=200; body='{"space_amount":10000,"space_used":2500}' ;;
    *folders/0/items*)
        code=200
        body='{"total_count":1,"entries":[{"type":"file","id":"777","name":"x.p0.tar.gz"}],"offset":0,"limit":1000}'
        ;;
    */files/777/content)
        code=302
        body=''
        if [[ -n "$hdr" ]]; then
            printf 'HTTP/1.1 302 Found\r\nLocation: https://dl.boxcloud.test/file/abc\r\n\r\n' >"$hdr"
        fi
        ;;
    https://dl.boxcloud.test/*) code=200; body='download-bytes' ;;
    *) code=404; body='{"type":"error","code":"not_found"}' ;;
esac
if [[ -n "$out" ]]; then
    printf '%s' "$body" >"$out"
fi
printf '%s' "$code"
SHIM
    chmod +x -- "$shim"
}

# Run the real box_http with a fake curl. Check the header path and the redirect path.
test_real_http_token_and_redirect() {
    box_begin || return 1
    local shim="$SANDBOX_DIR/fake-curl" log="$SANDBOX_DIR/shim.log"
    local auth="$SANDBOX_DIR/shim-auth.txt" dest="$SANDBOX_DIR/real.bin"
    local rc=0 space
    write_fake_curl "$shim" || return 1
    : >"$log"
    : >"$auth"
    export MPARCHIVE_CURL="$shim" SHIM_LOG="$log" SHIM_AUTH="$auth"
    box_setup_real || return 1

    space="$(provider_get_free_space 0)" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "7500" "$space" || return 1

    rc=0
    provider_download_file 0 "x.p0.tar.gz" "$dest" || rc=$?
    assert_eq "0" "$rc" || return 1
    assert_eq "download-bytes" "$(cat "$dest")" || return 1

    # The token is in the header file only. It is never in the curl argv.
    assert_not_contains "$(cat "$log")" "$BOX_TEST_TOKEN" "the token must not be in curl argv" || return 1
    assert_contains "$(cat "$auth")" "Authorization: Bearer $BOX_TEST_TOKEN" || return 1
    # The account requests send the header. The redirect request does not.
    assert_contains "$(grep 'users/me' "$log")" "auth=1" || return 1
    assert_contains "$(grep 'folders/0/items' "$log")" "auth=1" || return 1
    assert_contains "$(grep 'dl.boxcloud.test' "$log")" "auth=0" || return 1
    box_end
}

# ---------------------------------------------------------------------------
# Tests: hash helper
# ---------------------------------------------------------------------------

# Check box_sha1_base64 for "abc" and for other files. Fixed values are the reference.
test_sha1_base64_helper() {
    box_begin || return 1
    box_setup_real || return 1
    printf 'abc' >"$SANDBOX_DIR/abc.txt" || return 1
    assert_eq "qZk+NkcGgWq6PiVxeFDCbJzQ2J0=" "$(box_sha1_base64 "$SANDBOX_DIR/abc.txt")" || return 1
    : >"$SANDBOX_DIR/empty.bin" || return 1
    assert_eq "$(ref_sha1_text "")" \
        "$(box_sha1_base64 "$SANDBOX_DIR/empty.bin")" "empty file" || return 1
    seq 1 2000 >"$SANDBOX_DIR/seq.txt" || return 1
    assert_eq "$(ref_sha1_text "seq 1 2000")" \
        "$(box_sha1_base64 "$SANDBOX_DIR/seq.txt")" "2000 numbers" || return 1
    box_end
}

run_test "provider_init folder id rules" test_init_folder_id_rules
run_test "free space math" test_free_space_math
run_test "free space unlimited" test_free_space_unlimited
run_test "list files filters folders and other archives" test_list_files_filters
run_test "list files pagination" test_list_files_pagination
run_test "find file found and not found" test_find_file
run_test "delete found and not found" test_delete_found_and_missing
run_test "simple upload new file with spaces" test_upload_new_file_with_spaces
run_test "simple upload new version" test_upload_new_version
run_test "simple upload 409 fallback" test_upload_409_fallback
run_test "simple upload empty file" test_upload_empty_file
run_test "simple upload relative path" test_upload_relative_path
run_test "chunked upload flow with 202 retry" test_chunked_upload_flow
run_test "chunked upload part failure cleans up" test_chunked_upload_part_failure
run_test "download redirect without token" test_download_redirect
run_test "download unknown name" test_download_unknown_name
run_test "401 is clear and not retried" test_401_is_clear_and_not_retried
run_test "500 retry then success" test_retry_then_success
run_test "500 permanent failure" test_retry_permanent_failure
run_test "token never in logs or output" test_token_never_in_logs_or_output
run_test "real box_http keeps token in header only" test_real_http_token_and_redirect
run_test "base64 sha1 helper" test_sha1_base64_helper

finish_tests
