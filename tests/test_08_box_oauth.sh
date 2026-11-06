#!/usr/bin/env bash
# Offline tests for the Box OAuth 2.0 refresh tokens (ticket 08).
# They cover bin/lib/providers/box.sh. The tests of bin/add-account.sh are in test_10.
# No network call is made. The token endpoint is mocked with box_oauth_http.
# Some tests use the real token seam and the real box_http. Both use a fake curl.
# The fake curl opens no socket. Every test sets MPARCHIVE_CURL to the fake curl.
# All secrets in this file are fake: cid-test, SECRET-XYZ, RT-OLD, AT-OLD.
# Run with: bash tests/test_08_box_oauth.sh

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"
source "$REPO_ROOT/bin/lib/common.sh"

BOX_SH="$REPO_ROOT/bin/lib/providers/box.sh"
ADD_ACCOUNT="$REPO_ROOT/bin/add-account.sh"

# Fake account objects. Without a "name", the key is the client_id (cid-test).
ACCT_OAUTH='{"client_id":"cid-test","secret":"SECRET-XYZ","developer_token":""}'
ACCT_DEV='{"client_id":"cid-test","secret":"SECRET-XYZ","developer_token":"DEV-FAKE-1"}'

# Canned token endpoint answers.
TOKEN_OK_NEW='{"access_token":"AT-NEW","expires_in":3600,"refresh_token":"RT-NEW","token_type":"bearer"}'
TOKEN_INVALID_GRANT='{"error":"invalid_grant","error_description":"Refresh token has expired"}'

# ---------------------------------------------------------------------------
# Fake curl
# ---------------------------------------------------------------------------

# Write the fake curl to the path in $1. It is a bash script that opens no socket.
# It logs its argv to SHIM_LOG. It never logs a header or a form body.
# It logs a label of the bearer token (old, new, e2e, none) to SHIM_HDR.
# It copies each form body (from --data-binary @...) into SHIM_FORM_DIR.
# Env: FAKE_API_MODE is ok, reject-old or reject-all. FAKE_TOKEN_MODE is ok or invalid_grant.
write_fake_curl() {
    cat >"$1" <<'SHIM'
#!/usr/bin/env bash
# Fake curl for the offline tests. It makes no network call.
out="" prev="" a="" url="" hdr="" n="" code="" body="" lab="none"
for a in "$@"; do
    case "$prev" in
        -o) out="$a" ;;
    esac
    if [[ "$a" == @* ]]; then
        if [[ "$prev" == "-H" ]]; then
            # The Authorization header file. Read it, but never log it.
            hdr="$(cat -- "${a#@}")"
        else
            # A form body. Keep a copy in the sandbox, not in the log.
            n="$(ls -1 "$SHIM_FORM_DIR" | wc -l | tr -d ' ')"
            cp -- "${a#@}" "$SHIM_FORM_DIR/$(printf '%03d' $((n + 1)))"
        fi
    fi
    prev="$a"
    url="$a"
done
# The argv log. It holds no secret.
printf '%s\n' "$*" >>"$SHIM_LOG"
case "$url" in
    */oauth2/token)
        printf 'token\n' >>"$SHIM_HDR"
        if [[ "${FAKE_TOKEN_MODE:-ok}" == invalid_grant ]]; then
            code=400
            body='{"type":"error","error":"invalid_grant","error_description":"Invalid refresh token"}'
        else
            code=200
            body='{"access_token":"AT-E2E","expires_in":3600,"refresh_token":"RT-E2E","token_type":"bearer"}'
        fi
        ;;
    *users/me*)
        case "$hdr" in
            *AT-OLD*) lab=old ;;
            *AT-NEW*) lab=new ;;
            *AT-E2E*) lab=e2e ;;
        esac
        case "${FAKE_API_MODE:-ok}" in
            reject-all) code=401 ;;
            reject-old)
                if [[ "$lab" == old ]]; then code=401; else code=200; fi
                ;;
            *) code=200 ;;
        esac
        if [[ "$code" == 401 ]]; then
            body='{"type":"error","status":401,"code":"unauthorized"}'
        else
            body='{"type":"user","login":"user@example.test","space_amount":10000,"space_used":2500}'
        fi
        printf 'api %s %s\n' "$code" "$lab" >>"$SHIM_HDR"
        ;;
    *)
        code=404
        body='{"type":"error","code":"not_found"}'
        ;;
esac
if [[ -n "$out" ]]; then
    printf '%s' "$body" >"$out"
fi
printf '%s' "$code"
SHIM
    chmod +x -- "$1"
}

# ---------------------------------------------------------------------------
# Queues for the token endpoint mock
# ---------------------------------------------------------------------------

# Add one answer to a queue file. Args: <queue file> <code> <body>
# Each body has its own file, so the body can hold "|" characters.
queue_add() {
    local q="$1" code="$2" body="$3" bf
    QUEUE_SEQ=$((QUEUE_SEQ + 1))
    bf="${q}.body.${QUEUE_SEQ}"
    printf '%s' "$body" >"$bf" || return 1
    printf '%s|%s\n' "$code" "$bf" >>"$q" || return 1
}

# Take the first answer of a queue. Copy its body to <out>. Print its code.
# Return 1 when the queue is empty.
queue_pop() {
    local q="$1" out="$2" line code bf
    line="$(head -n 1 -- "$q")"
    [[ -n "$line" ]] || return 1
    sed -i '1d' -- "$q" || return 1
    code="${line%%|*}"
    bf="${line#*|}"
    cp -- "$bf" "$out" || return 1
    printf '%s' "$code"
}

# The mock for box_oauth_http. It has the same arguments and output as the real function.
# It records the call. It copies the form body into the sandbox, not into the argv log.
mock_oauth_http() {
    local idx="$1" method="$2" url="$3" out="$4" a form_src="" n code=""
    shift 4
    n="$(oauth_count)"
    for a in "$@"; do
        if [[ "$a" == @* ]]; then
            form_src="${a#@}"
        fi
    done
    if [[ -n "$form_src" ]]; then
        cp -- "$form_src" "$OAUTH_DIR/forms/$(printf '%03d' $((n + 1)))" 2>/dev/null || true
    fi
    printf '%s\t%s\t%s\t%s\n' "$idx" "$method" "$url" "$*" >>"$OAUTH_DIR/calls.txt"
    code="$(queue_pop "$OAUTH_DIR/queue.txt" "$out")" || code=""
    if [[ -z "$code" ]]; then
        # No answer was queued for this call. Report an error code and note the call.
        printf '%s %s\n' "$method" "$url" >>"$OAUTH_DIR/unmatched.txt"
        : >"$out"
        printf '418'
        return 0
    fi
    printf '%s' "$code"
}

# ---------------------------------------------------------------------------
# Test setup helpers
# ---------------------------------------------------------------------------

# Print the token store folder of the test.
store_dir() {
    printf '%s/box' "$MPARCHIVE_STATE_DIR"
}

# Print the number of token endpoint calls that the mock recorded.
oauth_count() {
    wc -l <"$OAUTH_DIR/calls.txt" | tr -d ' '
}

# Print line <n> of a file. Args: <path> [line number, default 1]
line_of() {
    sed -n "${2:-1}p" -- "$1"
}

# Print the octal mode of a path. Args: <path>
mode_of() {
    stat -c %a -- "$1"
}

# Write the token store of account cid-test. The folder starts with mode 755,
# so the provider must set it to 700. Args: <refresh token> [access token] [expiry]
seed_store() {
    local rt="$1" at="${2:-}" exp="${3:-}" dir
    dir="$(store_dir)"
    mkdir -p -- "$dir" || return 1
    chmod 755 -- "$dir" || return 1
    printf '%s\n' "$rt" >"$dir/cid-test.refresh_token" || return 1
    chmod 600 -- "$dir/cid-test.refresh_token" || return 1
    if [[ -n "$at" ]]; then
        printf '%s\n%s\n' "$at" "$exp" >"$dir/cid-test.access_token" || return 1
        chmod 600 -- "$dir/cid-test.access_token" || return 1
    fi
}

# Print the fake secret values that appear in a text. Print nothing when none appear.
# Args: <text> [more secret values...]
secrets_in() {
    local text="$1" s found=""
    shift
    for s in SECRET-XYZ RT-OLD RT-NEW RT-E2E AT-OLD AT-NEW AT-STALE AT-E2E "$@"; do
        if [[ "$text" == *"$s"* ]]; then
            found+="${s} "
        fi
    done
    printf '%s' "$found"
}

# Start a sandbox for one token test. Load box.sh with the token seam mocked.
# Args: [account JSON, default ACCT_OAUTH]
oauth_begin() {
    local acct="${1:-$ACCT_OAUTH}"
    setup_sandbox 1 || return 1
    unset BOX_REDIRECT_URI BOX_FOLDER_ID BOX_LOCK_WAIT BOX_LOCK_SLEEP BOX_LOCK_STALE
    unset FAKE_API_MODE FAKE_TOKEN_MODE

    export MPARCHIVE_STATE_DIR="$SANDBOX_DIR/state"
    export BOX_RETRY_SLEEP=0
    # The fake clock. The provider reads it through _box_now.
    BOX_TEST_NOW=1000000

    OAUTH_DIR="$SANDBOX_DIR/oauth"
    mkdir -p -- "$OAUTH_DIR/forms" "$SANDBOX_DIR/shim/forms" || return 1
    : >"$OAUTH_DIR/queue.txt"
    : >"$OAUTH_DIR/calls.txt"
    : >"$OAUTH_DIR/unmatched.txt"
    QUEUE_SEQ=0

    # The fake curl is always set, so the real curl is never used by this file.
    write_fake_curl "$SANDBOX_DIR/shim/fake-curl" || return 1
    SHIM_LOG="$SANDBOX_DIR/shim/argv.log"
    SHIM_HDR="$SANDBOX_DIR/shim/hdr.log"
    SHIM_FORM_DIR="$SANDBOX_DIR/shim/forms"
    : >"$SHIM_LOG"
    : >"$SHIM_HDR"
    export MPARCHIVE_CURL="$SANDBOX_DIR/shim/fake-curl" SHIM_LOG SHIM_HDR SHIM_FORM_DIR

    # Load the provider. Then replace the token seam and the clock.
    source "$BOX_SH" || return 1
    box_oauth_http() { mock_oauth_http "$@"; }
    _box_now() { printf '%s\n' "$BOX_TEST_NOW"; }

    MPA_ACCOUNTS=("$acct")
    MPA_ACCOUNT_COUNT=1
    BOX_FOLDER_ID=0
    provider_init || return 1
}

# Use the real token seam again. Its curl is the fake curl, so no socket opens.
oauth_use_real() {
    source "$BOX_SH" || return 1
    _box_now() { printf '%s\n' "$BOX_TEST_NOW"; }
}

# Remove the sandbox and the test variables.
oauth_end() {
    teardown_sandbox
    unset MPARCHIVE_STATE_DIR MPARCHIVE_CURL SHIM_LOG SHIM_HDR SHIM_FORM_DIR
    unset BOX_RETRY_SLEEP BOX_TEST_NOW BOX_REDIRECT_URI
    unset BOX_LOCK_WAIT BOX_LOCK_SLEEP BOX_LOCK_STALE FAKE_API_MODE FAKE_TOKEN_MODE
    MPA_ACCOUNTS=()
    MPA_ACCOUNT_COUNT=0
}

# Run one test, then remove its sandbox, even when the test failed.
# Args: <test name> <function name>
run_case() {
    run_test "$1" "$2"
    oauth_end
}

# ---------------------------------------------------------------------------
# Tests: scripts and helpers
# ---------------------------------------------------------------------------

# The provider and add-account.sh pass bash -n. add-account.sh is executable.
# bin/box-auth.sh is removed.
test_syntax_and_mode() {
    local exec_ok="no"
    assert_exit_code 0 bash -n "$BOX_SH" || return 1
    assert_exit_code 0 bash -n "$ADD_ACCOUNT" || return 1
    [[ -x "$ADD_ACCOUNT" ]] && exec_ok="yes"
    assert_eq "yes" "$exec_ok" "bin/add-account.sh must be executable" || return 1
}

# The authorize address has the client, the redirect address and the state.
test_authorize_url_shape() {
    oauth_begin || return 1
    assert_eq "https://account.box.com/api/oauth2/authorize?response_type=code&client_id=cid-test&redirect_uri=http%3A%2F%2Flocalhost&state=STATE123" \
        "$(box_authorize_url 0 "http://localhost" "STATE123")" "authorize URL" || return 1
}

# ---------------------------------------------------------------------------
# Tests: token cache and refresh (token endpoint mocked)
# ---------------------------------------------------------------------------

# A valid cached access token is used. No refresh call is made.
test_cache_valid_no_refresh() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-CACHED" "$((BOX_TEST_NOW + 3600))" || return 1
    local tok="" rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "valid cache: return code" || return 1
    assert_eq "AT-CACHED" "$tok" "valid cache: token" || return 1
    assert_eq "0" "$(oauth_count)" "valid cache: no refresh call" || return 1
    assert_eq "RT-OLD" "$(line_of "$(store_dir)/cid-test.refresh_token")" \
        "valid cache: refresh token unchanged" || return 1
}

# The cache counts as valid when more than 300 s are left. At 300 s, it refreshes.
test_cache_margin_300() {
    oauth_begin || return 1
    local tok="" rc=0
    seed_store "RT-OLD" "AT-CACHED" "$((BOX_TEST_NOW + 301))" || return 1
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "AT-CACHED" "$tok" "301 s left: cache is used" || return 1
    assert_eq "0" "$(oauth_count)" "301 s left: no refresh call" || return 1

    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    seed_store "RT-OLD" "AT-CACHED" "$((BOX_TEST_NOW + 300))" || return 1
    rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "300 s left: return code" || return 1
    assert_eq "AT-NEW" "$tok" "300 s left: the token is refreshed" || return 1
    assert_eq "1" "$(oauth_count)" "300 s left: one refresh call" || return 1
}

# An expired cache causes exactly one refresh. The new refresh token is saved.
# The folder mode is 700 and the file modes are 600.
test_expired_cache_refreshes_once() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    local tok="" rc=0 dir
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "expired cache: return code" || return 1
    assert_eq "AT-NEW" "$tok" "expired cache: the new access token is used" || return 1
    assert_eq "1" "$(oauth_count)" "expired cache: exactly one refresh call" || return 1

    dir="$(store_dir)"
    assert_eq "RT-NEW" "$(line_of "$dir/cid-test.refresh_token")" \
        "the rotated refresh token is saved" || return 1
    assert_eq "AT-NEW" "$(line_of "$dir/cid-test.access_token" 1)" \
        "the new access token is cached" || return 1
    assert_eq "$((BOX_TEST_NOW + 3600))" "$(line_of "$dir/cid-test.access_token" 2)" \
        "the cached expiry is now plus expires_in" || return 1

    assert_eq "700" "$(mode_of "$dir")" "the token folder must have mode 700" || return 1
    assert_eq "600" "$(mode_of "$dir/cid-test.refresh_token")" "the refresh token file must have mode 600" || return 1
    assert_eq "600" "$(mode_of "$dir/cid-test.access_token")" "the access token file must have mode 600" || return 1

    # No temporary file and no lock folder must stay behind.
    assert_eq "cid-test.access_token cid-test.refresh_token" "$(ls -A "$dir" | paste -sd' ' -)" \
        "the token folder must hold only the two files" || return 1

    # The form body holds the old refresh token and the client keys.
    assert_eq "grant_type=refresh_token&refresh_token=RT-OLD&client_id=cid-test&client_secret=SECRET-XYZ" \
        "$(cat "$OAUTH_DIR/forms/001")" "the refresh form body" || return 1
}

# invalid_grant gives rc 3 and the re-login message. The old refresh token stays.
# The lock is released. No secret reaches stderr or the logs.
test_invalid_grant_keeps_old_token() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 400 "$TOKEN_INVALID_GRANT" || return 1
    local tok="" rc=0 dir err
    err="$SANDBOX_DIR/stderr.txt"
    tok="$(_box_token 0 2>"$err")" || rc=$?
    dir="$(store_dir)"
    assert_eq "3" "$rc" "invalid_grant: return code" || return 1
    assert_eq "" "$tok" "invalid_grant: no token is printed" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" \
        "Run ./bin/add-account.sh and log in as the Box user of account #0 (cid-test) to renew the login of account #0." "error.log must have the re-login message" || return 1
    assert_eq "RT-OLD" "$(line_of "$dir/cid-test.refresh_token")" \
        "invalid_grant: the old refresh token is kept" || return 1
    assert_file_missing "$dir/cid-test.lock" "the lock is released after invalid_grant" || return 1
    assert_eq "" "$(secrets_in "$(cat "$err" "$MPARCHIVE_LOG_DIR"/*.log 2>/dev/null)")" \
        "no secret in stderr or the logs" || return 1
}

# The real token seam sends the form through a pipe, so the URL-encoded body
# is never in the curl argv. The rotated refresh token is saved.
test_refresh_form_encoded_real_path() {
    oauth_begin || return 1
    oauth_use_real || return 1
    # Special characters test the URL encoder: + / = & and a space.
    seed_store "RT+1/2=3&x" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    local tok="" rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "real refresh: return code" || return 1
    assert_eq "AT-E2E" "$tok" "real refresh: the new access token is used" || return 1
    assert_eq "grant_type=refresh_token&refresh_token=RT%2B1%2F2%3D3%26x&client_id=cid-test&client_secret=SECRET-XYZ" \
        "$(cat "$SHIM_FORM_DIR/001")" "the form body is URL-encoded" || return 1
    assert_contains "$(cat "$SHIM_LOG")" "--data-binary @/dev/fd/" \
        "the form body comes from a pipe" || return 1
    assert_eq "" "$(secrets_in "$(cat "$SHIM_LOG")" "RT+1/2=3&x")" \
        "no secret in the curl argv" || return 1
    assert_eq "RT-E2E" "$(line_of "$(store_dir)/cid-test.refresh_token")" \
        "the rotated refresh token is saved" || return 1
    assert_eq "a%20b%2Bc" "$(_box_urlencode 'a b+c')" "urlencode of space and plus" || return 1
}

# ---------------------------------------------------------------------------
# Tests: fallback and missing token
# ---------------------------------------------------------------------------

# With no refresh token, developer_token is used. A refresh token wins over it.
test_developer_token_fallback() {
    oauth_begin "$ACCT_DEV" || return 1
    local tok="" rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "fallback: return code" || return 1
    assert_eq "DEV-FAKE-1" "$tok" "fallback: developer_token is used" || return 1
    assert_eq "0" "$(oauth_count)" "fallback: no token call" || return 1

    seed_store "RT-OLD" "AT-CACHED" "$((BOX_TEST_NOW + 3600))" || return 1
    tok="$(_box_token 0 2>/dev/null)" || true
    assert_eq "AT-CACHED" "$tok" "a refresh token wins over developer_token" || return 1
}

# An account with no refresh token and no developer_token gives rc 3.
test_no_token_returns_3() {
    oauth_begin || return 1
    local tok="" rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "3" "$rc" "no token: return code" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "no token. Run ./bin/add-account.sh and log in as" \
        "no token: the error.log message" || return 1

    # An account with no name and no client_id has no token key at all.
    MPA_ACCOUNTS=('{"developer_token":""}')
    rc=0
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "3" "$rc" "no key and no token: return code" || return 1
}

# ---------------------------------------------------------------------------
# Tests: HTTP 401 handling (real box_http, fake curl)
# ---------------------------------------------------------------------------

# A 401 with an OAuth token causes one refresh and one retry with the new token.
test_401_oauth_one_refresh_one_retry() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-OLD" "$((BOX_TEST_NOW + 3600))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    # The fake API rejects only the old access token.
    export FAKE_API_MODE=reject-old
    local rc=0 body="$SANDBOX_DIR/api.json"
    box_request 0 GET "https://api.box.com/2.0/users/me?fields=login" "$body" \
        >"$SANDBOX_DIR/req.out" 2>"$SANDBOX_DIR/req.err" || rc=$?
    assert_eq "0" "$rc" "401 retry: return code" || return 1
    assert_eq "1" "$(oauth_count)" "401 retry: exactly one refresh" || return 1
    assert_eq $'api 401 old\napi 200 new' "$(cat "$SHIM_HDR")" \
        "401 retry: one call with the old token, then one with the new token" || return 1
    assert_eq "RT-NEW" "$(line_of "$(store_dir)/cid-test.refresh_token")" \
        "401 retry: the rotated refresh token is saved" || return 1
    assert_eq "" "$(secrets_in "$(cat "$SANDBOX_DIR/req.out" "$SANDBOX_DIR/req.err" "$SHIM_LOG" "$MPARCHIVE_LOG_DIR"/*.log 2>/dev/null)")" \
        "401 retry: no secret in the output, the argv or the logs" || return 1
}

# A second 401 after the refresh gives rc 3. There is no second refresh.
test_401_after_refresh_is_final() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-OLD" "$((BOX_TEST_NOW + 3600))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    export FAKE_API_MODE=reject-all
    local rc=0
    box_request 0 GET "https://api.box.com/2.0/users/me?fields=login" "$SANDBOX_DIR/api.json" \
        >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "second 401: return code" || return 1
    assert_eq "1" "$(oauth_count)" "second 401: no second refresh" || return 1
    assert_eq $'api 401 old\napi 401 new' "$(cat "$SHIM_HDR")" "second 401: two API calls only" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "Box rejected the new access token" \
        "second 401: the re-login message" || return 1
}

# A 401 with a developer token keeps the old message and is not retried.
test_401_developer_token_not_retried() {
    oauth_begin "$ACCT_DEV" || return 1
    export FAKE_API_MODE=reject-all
    local rc=0
    box_request 0 GET "https://api.box.com/2.0/users/me?fields=login" "$SANDBOX_DIR/api.json" \
        >/dev/null 2>&1 || rc=$?
    assert_eq "3" "$rc" "developer 401: return code" || return 1
    assert_eq "1" "$(wc -l <"$SHIM_HDR" | tr -d ' ')" "developer 401: one API call only" || return 1
    assert_eq "0" "$(oauth_count)" "developer 401: no refresh call" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "developer token is expired or invalid" \
        "developer 401: the old message" || return 1
}

# ---------------------------------------------------------------------------
# Tests: account keys
# ---------------------------------------------------------------------------

# Two accounts with the same client_id and no name fail in provider_init.
# The same client_id with two names is accepted. A bad name character is rejected.
test_same_client_id_rejected() {
    oauth_begin || return 1
    local rc=0
    MPA_ACCOUNTS=('{"client_id":"cid-test","secret":"SECRET-XYZ"}' '{"client_id":"cid-test","secret":"SECRET-XYZ"}')
    MPA_ACCOUNT_COUNT=2
    provider_init >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "same client_id without name: provider_init return code" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "use the same token key" \
        "same client_id without name: the error.log message" || return 1

    rc=0
    MPA_ACCOUNTS=('{"name":"work","client_id":"cid-test","secret":"SECRET-XYZ"}' '{"name":"home","client_id":"cid-test","secret":"SECRET-XYZ"}')
    provider_init >/dev/null 2>&1 || rc=$?
    assert_eq "0" "$rc" "distinct names: provider_init return code" || return 1

    rc=0
    MPA_ACCOUNTS=('{"name":"bad name","client_id":"cid-test","secret":"SECRET-XYZ"}')
    MPA_ACCOUNT_COUNT=1
    provider_init >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "bad name character: provider_init return code" || return 1
}

# ---------------------------------------------------------------------------
# Tests: token lock
# ---------------------------------------------------------------------------

# A held lock makes the call wait. The lock is released after 0.5 s, then the refresh runs.
test_lock_held_then_released() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    local lock tok="" rc=0 t0 t1 bg waited="no"
    lock="$(store_dir)/cid-test.lock"
    mkdir -- "$lock" || return 1
    export BOX_LOCK_WAIT=40 BOX_LOCK_SLEEP=0.05
    ( sleep 0.5; rmdir -- "$lock" ) &
    bg=$!
    t0="$(date +%s%N)"
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    t1="$(date +%s%N)"
    wait "$bg"
    assert_eq "0" "$rc" "held lock: return code" || return 1
    assert_eq "AT-NEW" "$tok" "held lock: the refresh runs after the release" || return 1
    assert_eq "1" "$(oauth_count)" "held lock: one refresh call" || return 1
    (( t1 - t0 >= 400000000 )) && waited="yes"
    assert_eq "yes" "$waited" "held lock: the call waited for the lock" || return 1
    assert_file_missing "$lock" "the lock is removed after the refresh" || return 1
}

# A lock that is never released gives rc 2 after the wait. The other lock is not removed.
test_lock_busy_gives_rc_2() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    local lock tok="" rc=0
    lock="$(store_dir)/cid-test.lock"
    mkdir -- "$lock" || return 1
    export BOX_LOCK_WAIT=3 BOX_LOCK_SLEEP=0.05
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "2" "$rc" "busy lock: return code" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/error.log")" "token lock is busy" \
        "busy lock: the error.log message" || return 1
    assert_eq "0" "$(oauth_count)" "busy lock: no refresh call" || return 1
    assert_file_exists "$lock" "a lock of another process is not removed" || return 1
    assert_eq "RT-OLD" "$(line_of "$(store_dir)/cid-test.refresh_token")" \
        "busy lock: the refresh token is unchanged" || return 1
}

# A stale lock (older than 120 s) is removed. The refresh then runs.
test_stale_lock_removed() {
    oauth_begin || return 1
    seed_store "RT-OLD" "AT-STALE" "$((BOX_TEST_NOW - 10))" || return 1
    queue_add "$OAUTH_DIR/queue.txt" 200 "$TOKEN_OK_NEW" || return 1
    local lock tok="" rc=0
    lock="$(store_dir)/cid-test.lock"
    mkdir -- "$lock" || return 1
    # The lock is 200 s old on the fake clock.
    touch -d "@$((BOX_TEST_NOW - 200))" -- "$lock" || return 1
    export BOX_LOCK_WAIT=3 BOX_LOCK_SLEEP=0.05
    tok="$(_box_token 0 2>/dev/null)" || rc=$?
    assert_eq "0" "$rc" "stale lock: return code" || return 1
    assert_eq "AT-NEW" "$tok" "stale lock: the refresh runs" || return 1
    assert_eq "1" "$(oauth_count)" "stale lock: one refresh call" || return 1
    assert_file_missing "$lock" "the stale lock is removed" || return 1
    assert_contains "$(cat "$MPARCHIVE_LOG_DIR/activity.log")" "remove a stale lock" \
        "stale lock: the activity.log message" || return 1
}

# ---------------------------------------------------------------------------
# Run the tests
# ---------------------------------------------------------------------------

run_case "syntax: box.sh and add-account.sh pass bash -n, add-account.sh is executable" test_syntax_and_mode
run_case "authorize address has the client, the redirect and the state" test_authorize_url_shape
run_case "token cache: a valid cache is used without refresh" test_cache_valid_no_refresh
run_case "token cache: 300 s margin" test_cache_margin_300
run_case "token refresh: expired cache refreshes once, rotates, sets modes" test_expired_cache_refreshes_once
run_case "token refresh: invalid_grant gives rc 3, message, old token kept" test_invalid_grant_keeps_old_token
run_case "token refresh: form is URL-encoded and argv has no secret" test_refresh_form_encoded_real_path
run_case "token fallback: developer_token used without refresh token" test_developer_token_fallback
run_case "token fallback: no token gives rc 3" test_no_token_returns_3
run_case "401 with OAuth token: one refresh and one retry" test_401_oauth_one_refresh_one_retry
run_case "401 after the refresh is final, no second refresh" test_401_after_refresh_is_final
run_case "401 with developer_token is not retried" test_401_developer_token_not_retried
run_case "keys: same client_id without name fails provider_init" test_same_client_id_rejected
run_case "lock: held lock makes a wait, then the refresh runs" test_lock_held_then_released
run_case "lock: a lock never released gives rc 2" test_lock_busy_gives_rc_2
run_case "lock: a stale lock is removed" test_stale_lock_removed

finish_tests
