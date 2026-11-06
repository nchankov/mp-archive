#!/usr/bin/env bash
# Offline tests for bin/add-account.sh and the JSON writers of ticket 10.
# They cover the .env credentials, the duplicate and backfill rules, the
# state check, and the re-login messages of bin/lib/providers/box.sh.
# No network call is made. MPARCHIVE_CURL is tests/mocks/bin/fake-curl-box.sh.
# All secrets in this file are fake (CID-APP-TEST, SECRET-APP-XYZ, CODE-*, AT-*, RT-*).
# Run with: bash tests/test_10_add_account.sh

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

ADD_ACCOUNT="$REPO_ROOT/bin/add-account.sh"
BOX_SH="$REPO_ROOT/bin/lib/providers/box.sh"
COMMON_SH="$REPO_ROOT/bin/lib/common.sh"
FAKE_CURL="$REPO_ROOT/tests/mocks/bin/fake-curl-box.sh"

# Fake app credentials. They go to the .env file of each sandbox.
APP_CID="CID-APP-TEST"
APP_SECRET="SECRET-APP-XYZ"

# Secrets that must never reach stdout, stderr, the logs or the argv log.
LEAK_NEEDLES=(SECRET-APP-XYZ CODE-LEAK-1 CODE-LEAK-2 CODE-LEAK-3 CODE-LEAK-4
    AT-LEAK-1 AT-LEAK-2 AT-LEAK-3 RT-LEAK-1 RT-LEAK-2 RT-LEAK-3)

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

# Create a sandbox with its own config, log, state and tmp folders.
# The .env has PROVIDER=box and the fake app credentials. The fake data is empty.
ac_begin() {
    unset MPARCHIVE_ROOT BOX_REDIRECT_URI BOX_APP_CLIENT_ID BOX_APP_SECRET PROVIDER BOX_FOLDER_ID
    unset BOX_LOCK_WAIT BOX_LOCK_SLEEP BOX_LOCK_STALE MPA_LOCK_WAIT MPA_LOCK_STALE MPA_LOCK_SLEEP
    unset MPA_ALLOW_NO_ACCOUNTS
    AC_SB="$(mktemp -d "${TMPDIR:-/tmp}/dar-test10.XXXXXX")" || return 1
    SB="$AC_SB"
    mkdir -p -- "$SB/config" "$SB/logs" "$SB/state" "$SB/tmp" "$SB/fc" || return 1
    ac_write_env "$(printf 'PROVIDER=box\nBOX_APP_CLIENT_ID=%s\nBOX_APP_SECRET=%s\n' "$APP_CID" "$APP_SECRET")" || return 1
    : >"$SB/fc/codes"
    : >"$SB/fc/refresh"
    : >"$SB/fc/users"
    : >"$SB/fc/argv.log"
    export MPARCHIVE_CONFIG_DIR="$SB/config" MPARCHIVE_LOG_DIR="$SB/logs" \
        MPARCHIVE_STATE_DIR="$SB/state" MPARCHIVE_TMPDIR="$SB/tmp" \
        MPARCHIVE_CURL="$FAKE_CURL" FC_DIR="$SB/fc" \
        BOX_RETRY_SLEEP=0 BOX_AUTH_READ_TIMEOUT=5
}

# Remove the sandbox. Delete only a folder that ac_begin created.
ac_end() {
    if [[ -n "${AC_SB:-}" && "$(basename -- "$AC_SB")" == dar-test10.* && -d "$AC_SB" ]]; then
        rm -rf -- "$AC_SB"
    fi
    unset AC_SB SB MPARCHIVE_CONFIG_DIR MPARCHIVE_LOG_DIR MPARCHIVE_STATE_DIR \
        MPARCHIVE_TMPDIR MPARCHIVE_CURL FC_DIR BOX_RETRY_SLEEP BOX_AUTH_READ_TIMEOUT \
        MPA_ALLOW_NO_ACCOUNTS
}

# Run one test, then remove its sandbox, even when the test failed.
# Args: <test name> <function name>
run_case() {
    run_test "$1" "$2"
    ac_end
}

# Write the .env file of the sandbox. Args: <exact text>. The mode is 600.
ac_write_env() {
    printf '%s' "$1" >"$SB/config/.env" && chmod 600 -- "$SB/config/.env"
}

# Write the account file with exact text. Args: <exact text>. The mode is 600.
ac_write_box() {
    printf '%s' "$1" >"$SB/config/box.json" && chmod 600 -- "$SB/config/box.json"
}

# Write the token files of key <key>. Args: <key> <refresh token> [access token] [expiry]
ac_seed() {
    local key="$1" rt="$2" at="${3:-}" exp="${4:-}" dir="$SB/state/box"
    mkdir -p -- "$dir" && chmod 700 -- "$dir" || return 1
    printf '%s\n' "$rt" >"$dir/$key.refresh_token" && chmod 600 -- "$dir/$key.refresh_token" || return 1
    if [[ -n "$at" ]]; then
        printf '%s\n%s\n' "$at" "$exp" >"$dir/$key.access_token" && chmod 600 -- "$dir/$key.access_token" || return 1
    fi
}

# Print an expiry time far ahead, and an expiry time that already passed.
ac_future() { printf '%s' "$(( $(date +%s) + 100000 ))"; }
ac_past() { printf '%s' "$(( $(date +%s) - 10 ))"; }

# Add a code to the fake codes file. Args: <code> <access token> <refresh token>
ac_code() { printf '%s %s %s\n' "$1" "$2" "$3" >>"$SB/fc/codes"; }

# Add a Box user to the fake users file. Args: <access token> <user id> <login>
ac_user() { printf '%s %s %s 10000 2500\n' "$1" "$2" "$3" >>"$SB/fc/users"; }

# Add a refresh token to the fake refresh file. Args: <refresh> <access> <new refresh>
ac_refresh() { printf '%s %s %s\n' "$1" "$2" "$3" >>"$SB/fc/refresh"; }

# A full login: a code, and the Box user of the access token it gives.
# Args: <code> <access token> <refresh token> <user id> <login>
ac_login() {
    ac_code "$1" "$2" "$3"
    ac_user "$2" "$4" "$5"
}

# Run add-account.sh with the text <input> as the pasted line.
# Other arguments go to the script. Results: AC_RC, AC_OUT, AC_ERR.
# Both outputs are also added to captured.txt for the leak scan.
ac_run() {
    local input="$1"
    shift
    printf '%s\n' "$input" >"$SB/stdin.txt"
    AC_RC=0
    "$ADD_ACCOUNT" "$@" <"$SB/stdin.txt" >"$SB/out.txt" 2>"$SB/err.txt" || AC_RC=$?
    AC_OUT="$(cat -- "$SB/out.txt")"
    AC_ERR="$(cat -- "$SB/err.txt")"
    cat -- "$SB/out.txt" "$SB/err.txt" >>"$SB/captured.txt"
}

# Run a shell function with common.sh and box.sh loaded. The run is a subshell.
# Usage: ac_lib <function> [args...]
ac_lib() {
    (
        source "$COMMON_SH" || exit 99
        source "$BOX_SH" || exit 99
        "$@"
    )
}

# Call _box_token 0 for one account object. Args: <account JSON> [env]
# With the word "env", the .env file of the sandbox is loaded first (as mpa_init does).
ac_token_case() {
    if [[ "${2:-}" == env ]]; then
        load_env_file "$MPARCHIVE_CONFIG_DIR/.env" || return 1
    fi
    MPA_ACCOUNTS=("$1")
    MPA_ACCOUNT_COUNT=1
    _box_token 0
}

# Run mpa_init and print the account count. Used for the MPA_ALLOW_NO_ACCOUNTS tests.
ac_init_case() {
    mpa_init
    printf 'count=%s' "$MPA_ACCOUNT_COUNT"
}

# Print the number of active accounts that config_load_accounts reads. Arg: <file>
ac_count_case() {
    config_load_accounts "$1" || return 1
    printf '%s' "$MPA_ACCOUNT_COUNT"
}

# Print the names and the SHA-256 sums of the config and state folders, sorted.
ac_sums() {
    { find "$SB/config" "$SB/state" -print
      find "$SB/config" "$SB/state" -type f -exec sha256sum {} +
    } 2>/dev/null | sort
}

# Print each leak needle that appears in the captured output, the logs or the argv log.
# Args: <needle>...
ac_leak_scan() {
    local needle f found=""
    for f in "$SB/captured.txt" "$MPARCHIVE_LOG_DIR/activity.log" \
        "$MPARCHIVE_LOG_DIR/error.log" "$FC_DIR/argv.log"; do
        [[ -f "$f" ]] || continue
        for needle in "$@"; do
            if grep -qF -- "$needle" "$f"; then
                found+="${needle} in $(basename -- "$f"); "
            fi
        done
    done
    printf '%s' "$found"
}

# ---------------------------------------------------------------------------
# Assert helpers for this file
# ---------------------------------------------------------------------------

# Pass when the file holds exactly the expected text (including the last newline).
# Args: <expected text> <file> [label]
assert_file_text() {
    local expected="$1" file="$2" label="${3:-assert_file_text}" tmp="$SB/expected.tmp"
    printf '%s' "$expected" >"$tmp" || return 1
    if [[ -f "$file" ]] && cmp -s -- "$tmp" "$file"; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "file does not hold the expected bytes: $file" \
        "expected: [$(cat -- "$tmp")]" "actual:   [$(cat -- "$file" 2>/dev/null)]"
}

# Pass when two files have the same bytes. Args: <expected file> <actual file> [label]
assert_same_file() {
    local label="${3:-assert_same_file}"
    if cmp -s -- "$1" "$2"; then
        _assert_pass
        return 0
    fi
    _assert_fail "$label" "files differ: $1 and $2" \
        "expected: [$(cat -- "$1")]" "actual:   [$(cat -- "$2")]"
}

# Pass when the path has the octal mode. Args: <mode> <path> [label]
assert_mode() {
    local want="$1" path="$2" label="${3:-assert_mode}" got
    got="$(stat -c %a -- "$path" 2>/dev/null)" || got="missing"
    assert_eq "$want" "$got" "$label"
}

# Pass when no temp file or lock folder of the account file is left, and the tmp folder is empty.
# Args: [label]
assert_no_leftovers() {
    local label="${1:-leftovers}" n
    n="$(find "$SB/config" -maxdepth 1 -name '.box.json.*' | wc -l | tr -d ' ')"
    assert_eq "0" "$n" "$label: no .box.json temp file or lock folder" || return 1
    n="$(find "$SB/tmp" -mindepth 1 | wc -l | tr -d ' ')"
    assert_eq "0" "$n" "$label: the tmp folder is empty" || return 1
}

# Print the names of the token files of the sandbox, sorted and on one line.
ac_token_names() {
    ls -A -- "$SB/state/box" 2>/dev/null | paste -sd' ' -
}

# ---------------------------------------------------------------------------
# Tests: scripts and messages
# ---------------------------------------------------------------------------

# bin/box-auth.sh is gone. add-account.sh is executable. The changed files pass bash -n.
test_static_files() {
    assert_file_missing "$REPO_ROOT/bin/box-auth.sh" "bin/box-auth.sh must be deleted" || return 1
    local exec_ok="no"
    [[ -x "$ADD_ACCOUNT" ]] && exec_ok="yes"
    assert_eq "yes" "$exec_ok" "bin/add-account.sh must be executable" || return 1
    assert_exit_code 0 bash -n "$ADD_ACCOUNT" || return 1
    assert_exit_code 0 bash -n "$BOX_SH" || return 1
    assert_exit_code 0 bash -n "$COMMON_SH" || return 1
}

# The old name must not appear in bin/ or in the README.
test_no_box_auth_reference() {
    local hits=""
    hits="$(grep -rn -- 'box-auth' "$REPO_ROOT/bin" "$REPO_ROOT/README.md" 2>/dev/null || true)"
    assert_eq "" "$hits" "no box-auth reference in bin/ or README.md" || return 1
}

# ---------------------------------------------------------------------------
# Tests: credentials (.env, account override, missing values)
# ---------------------------------------------------------------------------

# The new login uses BOX_APP_CLIENT_ID and BOX_APP_SECRET from .env.
# The authorize address and the code exchange both use them.
test_env_credentials_authorize_and_exchange() {
    ac_begin || return 1
    ac_login CODE-B1 AT-B1 RT-B1 1001 a@x.test
    ac_run CODE-B1
    assert_eq "0" "$AC_RC" "env credentials: exit code" || return 1
    assert_contains "$AC_OUT" \
        "https://account.box.com/api/oauth2/authorize?response_type=code&client_id=${APP_CID}&redirect_uri=http%3A%2F%2Flocalhost&state=" \
        "env credentials: the authorize address has the app client_id" || return 1
    assert_file_text \
        "grant_type=authorization_code&code=CODE-B1&client_id=${APP_CID}&client_secret=${APP_SECRET}&redirect_uri=http%3A%2F%2Flocalhost" \
        "$SB/fc/forms/001" "env credentials: the exchange form" || return 1
}

# A refresh with no account credentials uses the .env values in the form.
test_env_credentials_refresh() {
    ac_begin || return 1
    ac_seed main RT-E1 AT-E0 "$(ac_past)" || return 1
    ac_refresh RT-E1 AT-E1 RT-E2
    local rc=0
    ac_lib ac_token_case '{"name":"main"}' env >"$SB/tok.out" 2>"$SB/tok.err" || rc=$?
    assert_eq "0" "$rc" "env refresh: return code" || return 1
    assert_eq "AT-E1" "$(cat -- "$SB/tok.out")" "env refresh: the new access token" || return 1
    assert_file_text \
        "grant_type=refresh_token&refresh_token=RT-E1&client_id=${APP_CID}&client_secret=${APP_SECRET}" \
        "$SB/fc/forms/001" "env refresh: the refresh form has the .env values" || return 1
    assert_eq "RT-E2" "$(head -n 1 -- "$SB/state/box/main.refresh_token")" \
        "env refresh: the rotated refresh token is saved" || return 1
}

# A per-account client_id and secret win over the .env values.
test_account_credentials_win() {
    ac_begin || return 1
    ac_seed main RT-O1 AT-O0 "$(ac_past)" || return 1
    ac_refresh RT-O1 AT-O1 RT-O2
    local rc=0 acct='{"name":"main","client_id":"ACC-CID","secret":"ACC-SEC"}'
    ac_lib ac_token_case "$acct" env >"$SB/tok.out" 2>"$SB/tok.err" || rc=$?
    assert_eq "0" "$rc" "account override: return code" || return 1
    assert_file_text "grant_type=refresh_token&refresh_token=RT-O1&client_id=ACC-CID&client_secret=ACC-SEC" \
        "$SB/fc/forms/001" "account override: the form has the account values, not .env" || return 1
}

# Missing app values give exit 1 for add-account, with the clear message. No call is made.
test_missing_credentials_add_account() {
    ac_begin || return 1
    ac_write_env "$(printf 'PROVIDER=box\n')" || return 1
    ac_login CODE-M1 AT-M1 RT-M1 1001 a@x.test
    ac_run CODE-M1
    assert_eq "1" "$AC_RC" "missing credentials: exit code" || return 1
    assert_contains "$AC_ERR" \
        "Box app credentials are missing. Set BOX_APP_CLIENT_ID and BOX_APP_SECRET in .env." \
        "missing credentials: the clear message" || return 1
    assert_eq "" "$(cat -- "$SB/fc/argv.log")" "missing credentials: no network call" || return 1
    assert_file_missing "$SB/config/box.json" "missing credentials: nothing saved" || return 1

    # Only one of the two values is not enough.
    ac_write_env "$(printf 'PROVIDER=box\nBOX_APP_CLIENT_ID=%s\n' "$APP_CID")" || return 1
    ac_run CODE-M1
    assert_eq "1" "$AC_RC" "only the client_id: exit code" || return 1
    assert_contains "$AC_ERR" "Box app credentials are missing" "only the client_id: the message" || return 1
}

# Missing app values give rc 2 in the provider: refresh, authorize address and code exchange.
test_missing_credentials_provider() {
    ac_begin || return 1
    ac_seed main RT-N1 AT-N0 "$(ac_past)" || return 1
    local rc=0 msg="Box app credentials are missing. Set BOX_APP_CLIENT_ID and BOX_APP_SECRET in .env."
    ac_lib ac_token_case '{"name":"main"}' >"$SB/tok.out" 2>"$SB/tok.err" || rc=$?
    assert_eq "2" "$rc" "provider refresh without credentials: return code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" "$msg" \
        "provider refresh without credentials: the message" || return 1

    rc=0
    ac_lib box_authorize_url app http://localhost STATE1 >"$SB/auth.out" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "authorize address without credentials: return code" || return 1

    rc=0
    ac_lib box_oauth_exchange_new CODE-X http://localhost >"$SB/ex.out" 2>/dev/null || rc=$?
    assert_eq "2" "$rc" "code exchange without credentials: return code" || return 1
    assert_eq "" "$(cat -- "$SB/fc/argv.log")" "no network call without credentials" || return 1
}

# A wide .env mode gives a warning in activity.log. Modes 600 and 400 give none.
test_env_mode_warning() {
    ac_begin || return 1
    chmod 644 -- "$SB/config/.env" || return 1
    ac_login CODE-W1 AT-W1 RT-W1 1001 a@x.test
    ac_run CODE-W1
    assert_eq "0" "$AC_RC" "wide .env: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/activity.log")" \
        "WARNING: .env has mode 644. Run chmod 600 .env." "wide .env: activity.log warning" || return 1

    : >"$MPARCHIVE_LOG_DIR/activity.log"
    chmod 600 -- "$SB/config/.env" || return 1
    ac_login CODE-W2 AT-W2 RT-W2 1001 a@x.test
    ac_run CODE-W2
    assert_eq "0" "$AC_RC" "mode 600: exit code" || return 1
    assert_not_contains "$(cat -- "$MPARCHIVE_LOG_DIR/activity.log")" "WARNING: .env has mode" \
        "mode 600: no warning" || return 1

    : >"$MPARCHIVE_LOG_DIR/activity.log"
    chmod 400 -- "$SB/config/.env" || return 1
    ac_login CODE-W3 AT-W3 RT-W3 1001 a@x.test
    ac_run CODE-W3
    assert_eq "0" "$AC_RC" "mode 400: exit code" || return 1
    assert_not_contains "$(cat -- "$MPARCHIVE_LOG_DIR/activity.log")" "WARNING: .env has mode" \
        "mode 400: no warning" || return 1
}

# A wide box.json mode gives the same kind of warning.
test_box_json_mode_warning() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "main", "user_id": "1001", "login": "a@x.test"}\n  ]\n}\n' || return 1
    chmod 644 -- "$SB/config/box.json" || return 1
    ac_login CODE-J1 AT-J1 RT-J1 1001 a@x.test
    ac_run CODE-J1
    assert_eq "0" "$AC_RC" "wide box.json: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/activity.log")" \
        "WARNING: box.json has mode 644. Run chmod 600 box.json." "wide box.json: activity.log warning" || return 1
}

# Two accounts without a name that use the .env client_id conflict. The error says to add a name.
test_token_key_conflict_message() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"user_id": "1001"},\n    {"user_id": "1002"}\n  ]\n}\n' || return 1
    cp -- "$SB/config/box.json" "$SB/orig.json" || return 1
    ac_login CODE-K1 AT-K1 RT-K1 1003 k@x.test
    ac_run CODE-K1
    assert_eq "1" "$AC_RC" "key conflict: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" 'Add a different "name"' \
        "key conflict: the error tells the user to add a name" || return 1
    assert_same_file "$SB/orig.json" "$SB/config/box.json" "key conflict: box.json unchanged" || return 1
}

# ---------------------------------------------------------------------------
# Tests: add-account for a new Box user
# ---------------------------------------------------------------------------

# With no box.json, the default name box-<id> is used. The file has mode 600 and the exact text.
# The token files are saved with mode 600 in a folder with mode 700.
test_new_user_default_name() {
    ac_begin || return 1
    ac_login CODE-1 AT-1 RT-1 1001 a@x.test
    ac_run CODE-1
    assert_eq "0" "$AC_RC" "default name: exit code" || return 1
    assert_contains "$AC_OUT" "Added account #0: a@x.test" "default name: stdout" || return 1
    assert_contains "$AC_OUT" "Free space: 7500 bytes" "default name: free space" || return 1
    assert_contains "$AC_OUT" "Log in as the Box user that you want to add." "default name: instruction" || return 1
    assert_contains "$AC_OUT" "within 30 seconds" "default name: the 30-second hint" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name":"box-1001","user_id":"1001","login":"a@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "default name: box.json text" || return 1
    assert_mode 600 "$SB/config/box.json" "default name: box.json mode" || return 1
    assert_eq "RT-1" "$(head -n 1 -- "$SB/state/box/box-1001.refresh_token")" "default name: refresh token" || return 1
    assert_eq "AT-1" "$(head -n 1 -- "$SB/state/box/box-1001.access_token")" "default name: access token" || return 1

    local now exp ok="no"
    now="$(date +%s)"
    exp="$(sed -n 2p -- "$SB/state/box/box-1001.access_token")"
    if (( exp - now >= 3500 && exp - now <= 3700 )); then
        ok="yes"
    fi
    assert_eq "yes" "$ok" "default name: the access token expiry is about 3600 s ahead" || return 1
    assert_mode 700 "$SB/state/box" "default name: token folder mode" || return 1
    assert_mode 600 "$SB/state/box/box-1001.refresh_token" "default name: refresh token mode" || return 1
    assert_mode 600 "$SB/state/box/box-1001.access_token" "default name: access token mode" || return 1
    assert_no_leftovers "default name" || return 1
}

# A custom name is used for the new account. A name with dot, underscore and hyphen is valid.
test_new_user_custom_name() {
    ac_begin || return 1
    ac_login CODE-2A AT-2A RT-2A 1001 a@x.test
    ac_run CODE-2A
    assert_eq "0" "$AC_RC" "first account: exit code" || return 1
    ac_login CODE-2B AT-2B RT-2B 1002 b@x.test
    ac_run CODE-2B my.acct_1-x
    assert_eq "0" "$AC_RC" "custom name: exit code" || return 1
    assert_contains "$AC_OUT" "Added account #1: b@x.test" "custom name: stdout" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name":"box-1001","user_id":"1001","login":"a@x.test"},\n    {"name":"my.acct_1-x","user_id":"1002","login":"b@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "custom name: box.json text" || return 1
    assert_eq "RT-2B" "$(head -n 1 -- "$SB/state/box/my.acct_1-x.refresh_token")" "custom name: token file" || return 1
    assert_mode 600 "$SB/config/box.json" "custom name: box.json mode" || return 1
}

# A bad name gives exit 2. So does a wrong number of arguments. Nothing is saved.
test_bad_name_and_usage() {
    ac_begin || return 1
    ac_login CODE-X AT-X RT-X 1001 a@x.test
    local name
    for name in "a b" "x/y" "" "a+b"; do
        ac_run CODE-X "$name"
        assert_eq "2" "$AC_RC" "bad name [$name]: exit code" || return 1
    done
    ac_run CODE-X first second
    assert_eq "2" "$AC_RC" "two arguments: exit code" || return 1
    assert_file_missing "$SB/config/box.json" "usage errors: nothing saved" || return 1
    assert_eq "" "$(cat -- "$SB/fc/argv.log")" "usage errors: no network call" || return 1
}

# A name that another account uses gives exit 1. Box.json and the token folder do not change.
test_name_in_use_rejected() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name":"main","user_id":"1001","login":"a@x.test"}\n  ]\n}\n' || return 1
    ac_seed main RT-M AT-M "$(ac_future)" || return 1
    ac_login CODE-N AT-N RT-N 2002 n@x.test
    local before after
    before="$(ac_sums)"
    ac_run CODE-N main
    assert_eq "1" "$AC_RC" "name in use: exit code" || return 1
    assert_contains "$AC_ERR" "already used by account #0" "name in use: the message" || return 1
    after="$(ac_sums)"
    assert_eq "$before" "$after" "name in use: box.json and the token folder are unchanged (checksums)" || return 1
    assert_no_leftovers "name in use" || return 1
}

# A new login that cannot read its Box user saves nothing.
test_new_login_check_failure_saves_nothing() {
    ac_begin || return 1
    ac_code CODE-X1 AT-X1 RT-X1
    ac_run CODE-X1
    assert_eq "1" "$AC_RC" "check failure: exit code" || return 1
    assert_contains "$AC_ERR" "The login worked, but the check of the Box user failed. Nothing is saved." \
        "check failure: the message" || return 1
    assert_file_missing "$SB/config/box.json" "check failure: no box.json" || return 1
    assert_eq "" "$(ac_token_names)" "check failure: no token files" || return 1
}

# A token file for the default name with no account is overwritten and logged.
test_stale_token_replaced() {
    ac_begin || return 1
    ac_seed box-1001 OLD-RT OLD-AT "$(ac_future)" || return 1
    ac_login CODE-S AT-S RT-S 1001 s@x.test
    ac_run CODE-S
    assert_eq "0" "$AC_RC" "stale token: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/activity.log")" \
        "The stale token file for 'box-1001' was replaced." "stale token: the activity.log message" || return 1
    assert_eq "RT-S" "$(head -n 1 -- "$SB/state/box/box-1001.refresh_token")" "stale token: refresh token replaced" || return 1
    assert_eq "AT-S" "$(head -n 1 -- "$SB/state/box/box-1001.access_token")" "stale token: access token replaced" || return 1
}

# A state value that does not match gives exit 1. Nothing is saved and no call is made.
test_state_mismatch_rejected() {
    ac_begin || return 1
    ac_login CODE-T AT-T RT-T 1001 t@x.test
    ac_run "http://localhost/?state=00000000000000000000000000000000&code=CODE-T"
    assert_eq "1" "$AC_RC" "state mismatch: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" "The state value does not match" \
        "state mismatch: the message" || return 1
    assert_file_missing "$SB/config/box.json" "state mismatch: no box.json" || return 1
    assert_eq "" "$(find "$SB/state" -type f)" "state mismatch: no token file" || return 1
    assert_eq "" "$(cat -- "$SB/fc/argv.log")" "state mismatch: no network call" || return 1
}

# An error= redirect from Box gives exit 1. Nothing is saved.
test_error_redirect_rejected() {
    ac_begin || return 1
    ac_run "http://localhost/?error=access_denied&state=x"
    assert_eq "1" "$AC_RC" "error redirect: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" "Box returned the error: access_denied" \
        "error redirect: the message" || return 1
    assert_file_missing "$SB/config/box.json" "error redirect: no box.json" || return 1
    assert_eq "" "$(find "$SB/state" -type f)" "error redirect: no token file" || return 1
}

# A code that Box rejects gives exit 1. Nothing is saved.
test_rejected_code_saves_nothing() {
    ac_begin || return 1
    ac_run "NOPE-1"
    assert_eq "1" "$AC_RC" "rejected code: exit code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "the authorization code is invalid or expired" "rejected code: the message" || return 1
    assert_file_missing "$SB/config/box.json" "rejected code: no box.json" || return 1
    assert_eq "" "$(find "$SB/state" -type f)" "rejected code: no token file" || return 1
}

# A pasted full address with the state from the script works. The state is read from stdout.
# The fifo keeps stdin open until the state value is known.
test_full_address_with_matching_state() {
    ac_begin || return 1
    ac_login CODE-F AT-F RT-F 1001 f@x.test
    local fifo="$SB/input.fifo" pid i st="" rc=0
    mkfifo -- "$fifo" || return 1
    exec 7<>"$fifo"
    "$ADD_ACCOUNT" <&7 >"$SB/fifo.out" 2>"$SB/fifo.err" &
    pid=$!
    # Wait until the script prints its address with the state value.
    for (( i = 0; i < 200; i++ )); do
        st="$(sed -n 's/.*[?&]state=\([0-9a-f]\{32\}\).*/\1/p' -- "$SB/fifo.out" | head -n 1)"
        [[ -n "$st" ]] && break
        sleep 0.05
    done
    printf 'http://localhost/?state=%s&code=CODE-F\n' "$st" >&7
    exec 7>&-
    wait "$pid" || rc=$?
    cat -- "$SB/fifo.out" "$SB/fifo.err" >>"$SB/captured.txt"
    assert_eq "32" "${#st}" "full address: the script printed a 32 hex state" || return 1
    assert_eq "0" "$rc" "full address with matching state: exit code" || return 1
    assert_contains "$(cat -- "$SB/fifo.out")" "Added account #0: f@x.test" \
        "full address with matching state: stdout" || return 1
}

# ---------------------------------------------------------------------------
# Tests: JSON writers in common.sh
# ---------------------------------------------------------------------------

# Appending keeps every old byte. Removing the inserted text gives the old file again.
test_writer_append_keeps_bytes() {
    ac_begin || return 1
    local f="$SB/config/box.json" obj='{"name":"new3","user_id":"1003","login":"c@x.test"}'
    cat >"$f" <<'JSON'
{
 "accounts" :[
     {"name":"a1" ,  "client_id":"x"} ,
    {  "name" : "a2"  }
 ],
 "keep":{"deep":[1,2]}
}
JSON
    chmod 600 -- "$f" || return 1
    cp -- "$f" "$SB/orig.json" || return 1
    local rc=0 new stripped needle
    ac_lib json_accounts_append "$f" "$obj" 2>"$SB/w.err" || rc=$?
    assert_eq "0" "$rc" "append: return code" || return 1

    # The inserted text is a comma, a new line, four spaces, and the object.
    new="$(cat -- "$f"; printf x)"
    new="${new%x}"
    needle=$',\n    '"$obj"
    assert_contains "$new" "$needle" "append: the object is inserted" || return 1
    stripped="${new/"$needle"/}"
    printf '%s' "$stripped" >"$SB/stripped.json"
    assert_same_file "$SB/orig.json" "$SB/stripped.json" "append: old bytes kept exactly" || return 1
    assert_mode 600 "$f" "append: mode stays 600" || return 1
    assert_eq "3" "$(ac_lib ac_count_case "$f")" "append: the file loads with three accounts" || return 1
    assert_no_leftovers "append" || return 1
}

# json_account_add_fields on index 1 changes only that object.
test_writer_add_fields_index1() {
    ac_begin || return 1
    local f="$SB/config/box.json" frag='"user_id": "U1", "login": "l1@x.test"' needle new stripped
    printf '%s' $'{\n  "accounts": [\n    {"name": "a0"},\n    {"name": "a1", "client_id": "x"},\n    {"name": "a2"}\n  ]\n}\n' >"$f" || return 1
    chmod 600 -- "$f" || return 1
    cp -- "$f" "$SB/orig.json" || return 1
    local rc=0
    ac_lib json_account_add_fields "$f" 1 "$frag" 2>"$SB/w.err" || rc=$?
    assert_eq "0" "$rc" "add fields: return code" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "a0"},\n    {"name": "a1", "client_id": "x", "user_id": "U1", "login": "l1@x.test"},\n    {"name": "a2"}\n  ]\n}\n' \
        "$f" "add fields: only account 1 changed" || return 1

    # Removing the inserted text gives the old file again.
    needle=", $frag"
    new="$(cat -- "$f"; printf x)"
    new="${new%x}"
    stripped="${new/"$needle"/}"
    printf '%s' "$stripped" >"$SB/stripped.json"
    assert_same_file "$SB/orig.json" "$SB/stripped.json" "add fields: old bytes kept exactly" || return 1
    assert_mode 600 "$f" "add fields: mode stays 600" || return 1
    assert_no_leftovers "add fields" || return 1
}

# A write that would make invalid JSON returns 1 and leaves the file unchanged.
test_writer_rejects_invalid_and_keeps_file() {
    ac_begin || return 1
    local f="$SB/config/box.json" rc
    printf '%s' $'{\n  "accounts": [\n    {"name": "a1"},\n    {"name": "a2"}\n  ]\n}\n' >"$f" || return 1
    chmod 600 -- "$f" || return 1
    cp -- "$f" "$SB/orig.json" || return 1

    rc=0
    ac_lib json_accounts_append "$f" 'not-an-object' 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "object that is not {...}: return code" || return 1

    rc=0
    ac_lib json_accounts_append "$f" '{"name":"x"}}' 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "extra brace makes invalid JSON: return code" || return 1

    rc=0
    ac_lib json_account_add_fields "$f" 9 '"user_id": "U9"' 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "index that does not exist: return code" || return 1

    rc=0
    ac_lib json_account_add_fields "$f" 0 '' 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "empty fields: return code" || return 1

    rc=0
    ac_lib json_account_add_fields "$f" x '"a": "b"' 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "index that is not a number: return code" || return 1

    assert_same_file "$SB/orig.json" "$f" "invalid writes: the file is unchanged" || return 1
    assert_mode 600 "$f" "invalid writes: mode stays 600" || return 1
    assert_no_leftovers "invalid writes" || return 1
}

# An empty accounts array gets the first object.
test_writer_append_to_empty_array() {
    ac_begin || return 1
    ac_write_box $'{"accounts": []}\n' || return 1
    ac_login CODE-E0 AT-E0 RT-E0 1001 e@x.test
    ac_run CODE-E0
    assert_eq "0" "$AC_RC" "empty array: exit code" || return 1
    assert_eq "1" "$(ac_lib ac_count_case "$SB/config/box.json")" "empty array: one account" || return 1
    assert_contains "$(cat -- "$SB/config/box.json")" '{"name":"box-1001","user_id":"1001","login":"e@x.test"}' \
        "empty array: the object is in the file" || return 1
}

# json_string_field escapes the quote and the backslash.
test_json_string_field_escapes() {
    local got
    got="$(ac_lib json_string_field login 'a"b\c')"
    assert_eq '"login": "a\"b\\c"' "$got" "json_string_field: quote and backslash are escaped" || return 1
}

# MPA_ALLOW_NO_ACCOUNTS: the default fails for a missing or empty account list.
# With the option, the count is 0. A malformed file still fails.
test_mpa_allow_no_accounts() {
    ac_begin || return 1
    local rc out

    # No box.json at all.
    rc=0
    out="$(ac_lib ac_init_case 2>/dev/null)" || rc=$?
    assert_eq "1" "$rc" "missing box.json, default: mpa_init fails" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" "Cannot load accounts for provider: box" \
        "missing box.json, default: the error.log message" || return 1
    rc=0
    export MPA_ALLOW_NO_ACCOUNTS=1
    out="$(ac_lib ac_init_case 2>/dev/null)" || rc=$?
    unset MPA_ALLOW_NO_ACCOUNTS
    assert_eq "0" "$rc" "missing box.json, option set: mpa_init works" || return 1
    assert_eq "count=0" "$out" "missing box.json, option set: count is 0" || return 1

    # A file with zero active accounts.
    ac_write_box $'{"accounts": [{"name": "x", "active": false}]}\n' || return 1
    rc=0
    out="$(ac_lib ac_init_case 2>/dev/null)" || rc=$?
    assert_eq "1" "$rc" "zero active accounts, default: mpa_init fails" || return 1
    rc=0
    export MPA_ALLOW_NO_ACCOUNTS=1
    out="$(ac_lib ac_init_case 2>/dev/null)" || rc=$?
    unset MPA_ALLOW_NO_ACCOUNTS
    assert_eq "0" "$rc" "zero active accounts, option set: mpa_init works" || return 1
    assert_eq "count=0" "$out" "zero active accounts, option set: count is 0" || return 1

    # A malformed file fails even with the option.
    ac_write_box $'{"accounts": [ {"name": "x"} \n' || return 1
    rc=0
    export MPA_ALLOW_NO_ACCOUNTS=1
    ac_lib ac_init_case >/dev/null 2>&1 || rc=$?
    unset MPA_ALLOW_NO_ACCOUNTS
    assert_eq "1" "$rc" "malformed file, option set: mpa_init still fails" || return 1
}

# ---------------------------------------------------------------------------
# Tests: duplicates (the Box user is already an account)
# ---------------------------------------------------------------------------

# A login of an existing user adds no entry. The token files of that account are renewed.
test_duplicate_adds_no_entry() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name":"main","user_id":"1001","login":"a@x.test"}\n  ]\n}\n' || return 1
    cp -- "$SB/config/box.json" "$SB/orig.json" || return 1
    ac_seed main RT-OLD AT-OLD "$(ac_future)" || return 1
    ac_login CODE-D1 AT-D1 RT-D1 1001 a@x.test
    ac_run CODE-D1
    assert_eq "0" "$AC_RC" "duplicate: exit code" || return 1
    assert_same_file "$SB/orig.json" "$SB/config/box.json" "duplicate: box.json is byte-identical" || return 1
    assert_eq "RT-D1" "$(head -n 1 -- "$SB/state/box/main.refresh_token")" "duplicate: refresh token renewed" || return 1
    assert_eq "AT-D1" "$(head -n 1 -- "$SB/state/box/main.access_token")" "duplicate: access token renewed" || return 1
    assert_contains "$AC_OUT" "This Box user is already account #0 (a@x.test). The login is renewed." \
        "duplicate: the message" || return 1
    assert_contains "$AC_OUT" "Free space: 7500 bytes" "duplicate: free space" || return 1
    assert_not_contains "$AC_OUT" "is ignored" "duplicate without a name: no ignore message" || return 1
    assert_eq "main.access_token main.refresh_token" "$(ac_token_names)" "duplicate: no new token files" || return 1
    assert_no_leftovers "duplicate" || return 1
}

# A name argument for a duplicate is ignored, with a message. The same name gives no message.
test_duplicate_name_argument_ignored() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name":"main","user_id":"1001","login":"a@x.test"}\n  ]\n}\n' || return 1
    cp -- "$SB/config/box.json" "$SB/orig.json" || return 1
    ac_seed main RT-OLD AT-OLD "$(ac_future)" || return 1
    ac_login CODE-E2 AT-E2 RT-E2 1001 a@x.test
    ac_run CODE-E2 foo
    assert_eq "0" "$AC_RC" "name ignored: exit code" || return 1
    assert_contains "$AC_OUT" "The name argument 'foo' is ignored." "name ignored: the message" || return 1
    assert_contains "$AC_OUT" "This Box user is already account #0 (a@x.test). The login is renewed." \
        "name ignored: the duplicate message" || return 1
    assert_same_file "$SB/orig.json" "$SB/config/box.json" "name ignored: box.json unchanged" || return 1

    ac_login CODE-E3 AT-E3 RT-E3 1001 a@x.test
    ac_run CODE-E3 main
    assert_eq "0" "$AC_RC" "same name: exit code" || return 1
    assert_not_contains "$AC_OUT" "is ignored" "same name as the account: no ignore message" || return 1
    assert_eq "RT-E3" "$(head -n 1 -- "$SB/state/box/main.refresh_token")" "same name: tokens renewed" || return 1
}

# An account with its own client_id that differs from the .env app is not renewed.
# The tokens of the .env app do not fit that account. box.json and the tokens do not change.
test_duplicate_other_client_refused() {
    ac_begin || return 1
    ac_write_box '{"accounts": [{"name": "main", "user_id": "1001", "login": "a@x.test", "client_id": "OTHER-CID", "secret": "OTHER-SEC"}]}' || return 1
    cp -- "$SB/config/box.json" "$SB/orig.json" || return 1
    ac_seed main RT-OLD AT-OLD "$(ac_future)" || return 1
    ac_login CODE-O AT-O RT-O 1001 a@x.test
    ac_run CODE-O
    assert_eq "1" "$AC_RC" "other client_id: exit code" || return 1
    assert_contains "$AC_ERR" "has its own client_id in box.json" "other client_id: the message" || return 1
    assert_same_file "$SB/orig.json" "$SB/config/box.json" "other client_id: box.json unchanged" || return 1
    assert_eq "RT-OLD" "$(head -n 1 -- "$SB/state/box/main.refresh_token")" "other client_id: tokens unchanged" || return 1
}

# An account without a name uses the .env client_id as its token key.
test_duplicate_key_is_client_id() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"user_id": "1001", "login": "a@x.test"}\n  ]\n}\n' || return 1
    cp -- "$SB/config/box.json" "$SB/orig.json" || return 1
    ac_login CODE-CK AT-CK RT-CK 1001 a@x.test
    ac_run CODE-CK
    assert_eq "0" "$AC_RC" "client_id key: exit code" || return 1
    assert_same_file "$SB/orig.json" "$SB/config/box.json" "client_id key: box.json unchanged" || return 1
    assert_eq "RT-CK" "$(head -n 1 -- "$SB/state/box/${APP_CID}.refresh_token")" \
        "client_id key: the token file uses the client_id" || return 1
}

# ---------------------------------------------------------------------------
# Tests: backfill (accounts without user_id)
# ---------------------------------------------------------------------------

# An old account without user_id gets user_id and login. The other bytes stay the same.
# The new Box user is then added after it.
test_backfill_adds_fields_and_appends() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "old1"}\n  ],\n  "note": "keep me"\n}\n' || return 1
    ac_seed old1 RT-OLD1 AT-OLD1 "$(ac_future)" || return 1
    ac_user AT-OLD1 5001 old@x.test
    ac_login CODE-N AT-N RT-N 9009 new@x.test
    ac_run CODE-N
    assert_eq "0" "$AC_RC" "backfill: exit code" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "old1", "user_id": "5001", "login": "old@x.test"},\n    {"name":"box-9009","user_id":"9009","login":"new@x.test"}\n  ],\n  "note": "keep me"\n}\n' \
        "$SB/config/box.json" "backfill: the fields are added, the rest is kept" || return 1
    assert_contains "$AC_OUT" "Added account #1: new@x.test" "backfill: the new account number" || return 1
    assert_eq "RT-OLD1" "$(head -n 1 -- "$SB/state/box/old1.refresh_token")" "backfill: the old token is not changed" || return 1
    assert_no_leftovers "backfill" || return 1
}

# A backfill that skips an inactive account gives the fields to the right account.
test_backfill_skips_inactive_account() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "off", "active": false},\n    {"name": "old1"}\n  ]\n}\n' || return 1
    ac_seed old1 RT-OLD1 AT-OLD1 "$(ac_future)" || return 1
    ac_user AT-OLD1 5501 x@x.test
    ac_login CODE-I AT-I RT-I 9011 n@x.test
    ac_run CODE-I
    assert_eq "0" "$AC_RC" "inactive account: exit code" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "off", "active": false},\n    {"name": "old1", "user_id": "5501", "login": "x@x.test"},\n    {"name":"box-9011","user_id":"9011","login":"n@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "inactive account: the fields go to old1 only" || return 1
    assert_contains "$AC_OUT" "Added account #1: n@x.test" "inactive account: the new account number" || return 1
}

# An account whose token fails is skipped with a warning. The run continues.
test_backfill_failure_is_skipped() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "bad1"}\n  ]\n}\n' || return 1
    # The fake API does not know AT-BAD1 (401). The fake refresh does not know RT-BAD1 (invalid_grant).
    ac_seed bad1 RT-BAD1 AT-BAD1 "$(ac_future)" || return 1
    ac_login CODE-B AT-B RT-B 9010 new2@x.test
    ac_run CODE-B
    assert_eq "0" "$AC_RC" "backfill failure: the run continues" || return 1
    assert_contains "$AC_ERR" "WARNING: Account #0 (bad1): cannot read its Box user; skip it" \
        "backfill failure: the warning" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "bad1"},\n    {"name":"box-9010","user_id":"9010","login":"new2@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "backfill failure: no fields for bad1, new account added" || return 1
    assert_eq "RT-BAD1" "$(head -n 1 -- "$SB/state/box/bad1.refresh_token")" "backfill failure: refresh token kept" || return 1
}

# Two existing accounts that are the same Box user give a warning. Both are kept.
test_backfill_two_accounts_same_user_warning() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "dupA"},\n    {"name": "dupB"}\n  ]\n}\n' || return 1
    ac_seed dupA RT-DA AT-DA "$(ac_future)" || return 1
    ac_seed dupB RT-DB AT-DB "$(ac_future)" || return 1
    ac_user AT-DA 6006 dup@x.test
    ac_user AT-DB 6006 dup@x.test
    ac_login CODE-Q AT-Q RT-Q 7007 new3@x.test
    ac_run CODE-Q
    assert_eq "0" "$AC_RC" "same user twice: exit code" || return 1
    assert_contains "$AC_ERR" \
        "WARNING: Accounts #0 and #1 are the same Box user dup@x.test. One Box user holds two parts." \
        "same user twice: the warning" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "dupA", "user_id": "6006", "login": "dup@x.test"},\n    {"name": "dupB", "user_id": "6006", "login": "dup@x.test"},\n    {"name":"box-7007","user_id":"7007","login":"new3@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "same user twice: both accounts kept, new account added" || return 1
}

# A backfill with an expired access token refreshes it first. The rotated refresh token is saved.
test_backfill_refreshes_expired_token() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "rf1"}\n  ]\n}\n' || return 1
    ac_seed rf1 RT-R1 AT-R0 "$(ac_past)" || return 1
    ac_refresh RT-R1 AT-R1 RT-R2
    ac_user AT-R1 8008 rf@x.test
    ac_login CODE-RF AT-RF RT-RF 8100 r2@x.test
    ac_run CODE-RF
    assert_eq "0" "$AC_RC" "backfill refresh: exit code" || return 1
    assert_eq "RT-R2" "$(head -n 1 -- "$SB/state/box/rf1.refresh_token")" \
        "backfill refresh: the rotated refresh token is saved" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "rf1", "user_id": "8008", "login": "rf@x.test"},\n    {"name":"box-8100","user_id":"8100","login":"r2@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "backfill refresh: the fields are added after the refresh" || return 1
    assert_no_leftovers "backfill refresh" || return 1
}

# A backfilled account that matches the new login is renewed. No new entry is added.
test_backfill_then_duplicate() {
    ac_begin || return 1
    ac_write_box $'{\n  "accounts": [\n    {"name": "old1"}\n  ]\n}\n' || return 1
    ac_seed old1 RT-O1 AT-O1 "$(ac_future)" || return 1
    ac_user AT-O1 3001 o@x.test
    ac_login CODE-BD AT-BD RT-BD 3001 o@x.test
    ac_run CODE-BD
    assert_eq "0" "$AC_RC" "backfill and duplicate: exit code" || return 1
    assert_contains "$AC_OUT" "This Box user is already account #0 (o@x.test). The login is renewed." \
        "backfill and duplicate: the message" || return 1
    assert_file_text $'{\n  "accounts": [\n    {"name": "old1", "user_id": "3001", "login": "o@x.test"}\n  ]\n}\n' \
        "$SB/config/box.json" "backfill and duplicate: only the backfill is in box.json" || return 1
    assert_eq "RT-BD" "$(head -n 1 -- "$SB/state/box/old1.refresh_token")" "backfill and duplicate: tokens renewed" || return 1
    assert_eq "old1.access_token old1.refresh_token" "$(ac_token_names)" "backfill and duplicate: no new token files" || return 1
}

# ---------------------------------------------------------------------------
# Tests: the re-login messages of bin/lib/providers/box.sh
# ---------------------------------------------------------------------------

# No token, login known: the message names the login.
test_relogin_message_with_login() {
    ac_begin || return 1
    local rc=0
    ac_lib ac_token_case '{"name":"main","login":"a@x.test"}' >"$SB/t.out" 2>"$SB/t.err" || rc=$?
    assert_eq "3" "$rc" "no token with login: return code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "Run ./bin/add-account.sh and log in as a@x.test to renew the login of account #0." \
        "no token with login: the message" || return 1
}

# No token, no login: the message names the account instead.
test_relogin_message_without_login() {
    ac_begin || return 1
    local rc=0
    ac_lib ac_token_case '{"name":"main"}' >"$SB/t.out" 2>"$SB/t.err" || rc=$?
    assert_eq "3" "$rc" "no token without login: return code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "Run ./bin/add-account.sh and log in as the Box user of account #0 (main) to renew the login of account #0." \
        "no token without login: the message" || return 1
}

# invalid_grant on a refresh, login known: the message names the login.
test_invalid_grant_message_with_login() {
    ac_begin || return 1
    ac_seed main RT-GONE AT-OLD "$(ac_past)" || return 1
    local rc=0
    ac_lib ac_token_case '{"name":"main","login":"a@x.test"}' env >"$SB/t.out" 2>"$SB/t.err" || rc=$?
    assert_eq "3" "$rc" "invalid_grant with login: return code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "the refresh token is expired or revoked. Run ./bin/add-account.sh and log in as a@x.test to renew the login of account #0." \
        "invalid_grant with login: the message" || return 1
}

# invalid_grant on a refresh, no login: the message names the account.
test_invalid_grant_message_without_login() {
    ac_begin || return 1
    ac_seed main RT-GONE AT-OLD "$(ac_past)" || return 1
    local rc=0
    ac_lib ac_token_case '{"name":"main"}' env >"$SB/t.out" 2>"$SB/t.err" || rc=$?
    assert_eq "3" "$rc" "invalid_grant without login: return code" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" \
        "the refresh token is expired or revoked. Run ./bin/add-account.sh and log in as the Box user of account #0 (main) to renew the login of account #0." \
        "invalid_grant without login: the message" || return 1
}

# ---------------------------------------------------------------------------
# Tests: secrets and token files
# ---------------------------------------------------------------------------

# A failed save of box.json keeps the token files and gives exit 1.
test_box_json_write_failure_keeps_tokens() {
    ac_begin || return 1
    ac_login CODE-I2 AT-I2 RT-I2 1001 a@x.test
    chmod 500 -- "$SB/config" || return 1
    ac_run CODE-I2
    chmod 700 -- "$SB/config" || return 1
    assert_eq "1" "$AC_RC" "box.json write failure: exit code" || return 1
    assert_contains "$AC_ERR" \
        "The tokens are saved, but the account was not added to box.json. Run the script again." \
        "box.json write failure: the message" || return 1
    assert_file_missing "$SB/config/box.json" "box.json write failure: no box.json" || return 1
    assert_eq "RT-I2" "$(head -n 1 -- "$SB/state/box/box-1001.refresh_token")" \
        "box.json write failure: the token files stay" || return 1
}

# No secret, token or code appears in stdout, stderr, the logs or the fake curl argv log.
# The run covers a new login, a duplicate, a failed user check and a rejected code.
test_no_secret_in_output_logs_or_argv() {
    ac_begin || return 1
    ac_login CODE-LEAK-1 AT-LEAK-1 RT-LEAK-1 1001 a@x.test
    ac_run CODE-LEAK-1
    assert_eq "0" "$AC_RC" "leak scan: first login" || return 1
    ac_login CODE-LEAK-2 AT-LEAK-2 RT-LEAK-2 1001 a@x.test
    ac_run CODE-LEAK-2 renamed
    assert_eq "0" "$AC_RC" "leak scan: duplicate login" || return 1
    ac_code CODE-LEAK-3 AT-LEAK-3 RT-LEAK-3
    ac_run CODE-LEAK-3
    assert_eq "1" "$AC_RC" "leak scan: failed user check" || return 1
    ac_run CODE-LEAK-4
    assert_eq "1" "$AC_RC" "leak scan: rejected code" || return 1
    # The scan must read real content. An empty file would pass for the wrong reason.
    assert_eq "yes" "$([[ -s "$FC_DIR/argv.log" ]] && echo yes || echo no)" \
        "leak scan: the fake curl argv log is not empty" || return 1
    assert_contains "$(cat -- "$SB/captured.txt")" "Added account" \
        "leak scan: the captured output holds the success text" || return 1
    assert_contains "$(cat -- "$MPARCHIVE_LOG_DIR/error.log")" "The login failed" \
        "leak scan: error.log holds the failure text" || return 1
    local found
    found="$(ac_leak_scan "${LEAK_NEEDLES[@]}")"
    assert_eq "" "$found" "no secret, token or code in stdout, stderr, logs or argv" || return 1
}

# ---------------------------------------------------------------------------
# Run the tests
# ---------------------------------------------------------------------------

run_case "static: box-auth.sh is gone, add-account.sh is executable, bash -n passes" test_static_files
run_case "static: no box-auth reference in bin/ or README.md" test_no_box_auth_reference
run_case "credentials: .env values for the authorize address and the code exchange" test_env_credentials_authorize_and_exchange
run_case "credentials: .env values for a refresh" test_env_credentials_refresh
run_case "credentials: account client_id and secret win over .env" test_account_credentials_win
run_case "credentials: missing values give exit 1 in add-account" test_missing_credentials_add_account
run_case "credentials: missing values give rc 2 in the provider" test_missing_credentials_provider
run_case "credentials: wide .env mode warns, modes 600 and 400 do not" test_env_mode_warning
run_case "credentials: wide box.json mode warns" test_box_json_mode_warning
run_case "credentials: two accounts without name on the same client_id say add a name" test_token_key_conflict_message
run_case "new user: default name, box.json created, token files and modes" test_new_user_default_name
run_case "new user: custom name appended to box.json" test_new_user_custom_name
run_case "new user: bad name and wrong argument count give exit 2" test_bad_name_and_usage
run_case "new user: name in use gives exit 1, checksums unchanged" test_name_in_use_rejected
run_case "new user: failed user check saves nothing" test_new_login_check_failure_saves_nothing
run_case "new user: stale token file replaced and logged" test_stale_token_replaced
run_case "new user: state mismatch gives exit 1 and saves nothing" test_state_mismatch_rejected
run_case "new user: error= redirect gives exit 1 and saves nothing" test_error_redirect_rejected
run_case "new user: rejected code gives exit 1 and saves nothing" test_rejected_code_saves_nothing
run_case "new user: full address with the matching state works" test_full_address_with_matching_state
run_case "writer: append keeps every old byte" test_writer_append_keeps_bytes
run_case "writer: add fields to index 1 changes only that object" test_writer_add_fields_index1
run_case "writer: invalid writes return 1 and keep the file" test_writer_rejects_invalid_and_keeps_file
run_case "writer: append to an empty accounts array" test_writer_append_to_empty_array
run_case "writer: json_string_field escapes" test_json_string_field_escapes
run_case "MPA_ALLOW_NO_ACCOUNTS: default fails, option gives count 0, malformed still fails" test_mpa_allow_no_accounts
run_case "duplicate: no new entry, box.json identical, tokens renewed" test_duplicate_adds_no_entry
run_case "duplicate: name argument ignored with a message" test_duplicate_name_argument_ignored
run_case "duplicate: account with another client_id is refused" test_duplicate_other_client_refused
run_case "duplicate: token key is the .env client_id when no name" test_duplicate_key_is_client_id
run_case "backfill: user_id and login added, other bytes kept, new account appended" test_backfill_adds_fields_and_appends
run_case "backfill: inactive account is skipped for the index" test_backfill_skips_inactive_account
run_case "backfill: failed account is skipped with a warning" test_backfill_failure_is_skipped
run_case "backfill: two accounts of the same user give a warning" test_backfill_two_accounts_same_user_warning
run_case "backfill: an expired token is refreshed and the rotated token is saved" test_backfill_refreshes_expired_token
run_case "backfill and duplicate: backfilled account is renewed, no new entry" test_backfill_then_duplicate
run_case "message: no token with login names the login" test_relogin_message_with_login
run_case "message: no token without login names the account" test_relogin_message_without_login
run_case "message: invalid_grant with login names the login" test_invalid_grant_message_with_login
run_case "message: invalid_grant without login names the account" test_invalid_grant_message_without_login
run_case "token write failure after login keeps the tokens and gives exit 1" test_box_json_write_failure_keeps_tokens
run_case "leak scan: no secret, token or code in output, logs or argv" test_no_secret_in_output_logs_or_argv

finish_tests
