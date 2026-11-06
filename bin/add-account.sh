#!/usr/bin/env bash
# add-account.sh - add a Box user to mp-archive, or renew the login of a user.
# Usage: bin/add-account.sh [name]
#   name  Optional name of a NEW account. Default: box-<Box user id>.
# The Box app credentials (BOX_APP_CLIENT_ID and BOX_APP_SECRET) come from .env.
# The script does one browser login (OAuth 2.0) and then:
#   - a Box user that is already an account: the script renews its tokens.
#   - a new Box user: the script saves the tokens and adds the account to box.json.
# Exit codes: 0 ok, 1 error, 2 usage error.
# The script never prints a token or a secret.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MPA_SCRIPT_NAME="add-account.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
    printf 'Usage: %s [name]\n' "$MPA_SCRIPT_NAME" >&2
    printf 'The name can contain only letters, digits, ".", "_" and "-".\n' >&2
    exit 2
}

# Remove white space and quotes at the start and the end of a text.
trim_input() {
    local s="$1"
    s="${s#"${s%%[![:space:]\"\']*}"}"
    s="${s%"${s##*[![:space:]\"\']}"}"
    printf '%s' "$s"
}

# Print the value of a query parameter. Return 1 when it is absent.
query_param() {
    local query="$1" name="$2" pair
    local -a pairs=()
    IFS='&' read -r -a pairs <<<"$query"
    for pair in "${pairs[@]}"; do
        if [[ "$pair" == "${name}="* ]]; then
            printf '%s' "${pair#"${name}="}"
            return 0
        fi
    done
    return 1
}

# Print the free space of the Box user (arguments: space_amount, space_used).
print_free_space() {
    local amount="$1" used="$2"
    [[ "$amount" =~ ^-?[0-9]+$ && "$used" =~ ^[0-9]+$ ]] || return 0
    if ((amount < 0)); then
        printf 'Free space: unlimited\n'
    else
        printf 'Free space: %s bytes\n' "$((amount > used ? amount - used : 0))"
    fi
}

# Print the name of account <idx> for a message: "name", else the key.
account_label() {
    local n
    n="$(json_get_string "${MPA_ACCOUNTS[$1]}" name)" || n=""
    [[ -n "$n" ]] || n="$(_box_key "$1" 2>/dev/null)" || n=""
    printf '%s' "${n:-no name}"
}

# Print every "name" value of the account file (also of accounts that are not active).
file_names() {
    [[ -f "$ACCT_FILE" ]] || return 0
    grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' -- "$ACCT_FILE" 2>/dev/null |
        sed 's/^"name"[[:space:]]*:[[:space:]]*"//; s/"$//' || true
}

# Step 1: check the arguments.
(($# <= 1)) || usage
NAME_ARG=""
if (($# == 1)); then
    NAME_ARG="$1"
    [[ "$NAME_ARG" =~ ^[A-Za-z0-9._-]+$ ]] || usage
fi

# Step 2: load the settings. This works when box.json is absent or has no account.
MPA_ALLOW_NO_ACCOUNTS=1
mpa_init
[[ "$PROVIDER" == "box" ]] || die "add-account.sh works only with PROVIDER=box (now: ${PROVIDER})."
if [[ -z "${BOX_APP_CLIENT_ID:-}" || -z "${BOX_APP_SECRET:-}" ]]; then
    die "Box app credentials are missing. Set BOX_APP_CLIENT_ID and BOX_APP_SECRET in .env."
fi
ACCT_FILE="${MPARCHIVE_CONFIG_DIR}/${PROVIDER}.json"

REDIRECT="${BOX_REDIRECT_URI:-http://localhost}"
[[ "$REDIRECT" =~ ^https?://[^[:space:]]+$ ]] ||
    die "BOX_REDIRECT_URI is not a valid http or https address."

TMP="$(make_tmpdir)" || die "Cannot create a temporary directory."
trap 'rm -rf -- "$TMP"' EXIT

# Create a random state value to stop forged redirects.
STATE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
[[ -n "$STATE" ]] || die "Cannot create a random state value."

# Step 3: show the login address and the instructions.
AUTH_URL="$(box_authorize_url app "$REDIRECT" "$STATE")" ||
    die "Cannot make the login address."

cat <<TXT
Add a Box account to mp-archive

Log in as the Box user that you want to add.
To add a different user, first log out of Box or use a private browser window.

1. Open the Box Developer Console. Go to your app, then Configuration.
   Add this exact address as "OAuth 2.0 Redirect URI":
   ${REDIRECT}
2. Open this address in a browser:
   ${AUTH_URL}
   Log in as the Box user. Push "Grant access to Box".
3. The browser goes to ${REDIRECT}/?state=..&code=..
   The page can show an error. This is normal.
4. Copy the FULL address from the address bar.
   Paste it here and push Enter within 30 seconds.
   (You can also paste only the code.)

TXT

printf 'Paste the address or the code: '
INPUT=""
if ! IFS= read -r -t "${BOX_AUTH_READ_TIMEOUT:-300}" INPUT; then
    printf '\n'
    die "No input received. Run the script again."
fi
INPUT="$(trim_input "$INPUT")"
[[ -n "$INPUT" ]] || die "The input is empty. Run the script again."

CODE=""
if [[ "$INPUT" == *"="* || "$INPUT" == *"/"* || "$INPUT" == *"?"* ]]; then
    # Full address. Read the query part, without a fragment.
    QUERY="${INPUT#*\?}"
    QUERY="${QUERY%%#*}"
    if ERR="$(query_param "$QUERY" error)"; then
        [[ "$ERR" =~ ^[A-Za-z0-9_]+$ ]] || ERR="unknown"
        die "Box returned the error: ${ERR}. Run the script again."
    fi
    CODE="$(query_param "$QUERY" code)" || die "The address has no code parameter."
    if GOT_STATE="$(query_param "$QUERY" state)"; then
        [[ "$GOT_STATE" == "$STATE" ]] ||
            die "The state value does not match. Do not use an old address. Run the script again."
    else
        log_info "The address has no state value. Skip the state check."
    fi
else
    CODE="$INPUT"
fi
[[ "$CODE" =~ ^[A-Za-z0-9_.~-]+$ ]] || die "The code has a bad character."

# Step 4: exchange the code. The tokens stay in memory until the account is known.
RC=0
box_oauth_exchange_new "$CODE" "$REDIRECT" || RC=$?
CODE=""
INPUT=""
if ((RC != 0)); then
    die "The login failed. The error.log file has the reason."
fi

# Step 5: read the Box user of the new tokens.
RC=0
INFO="$(box_new_user_info)" || RC=$?
if ((RC != 0)); then
    die "The login worked, but the check of the Box user failed. Nothing is saved."
fi
IFS=$'\t' read -r NEW_ID NEW_LOGIN NEW_AMOUNT NEW_USED <<<"$INFO"
[[ "$NEW_LOGIN" != "-" ]] || NEW_LOGIN="(unknown)"
[[ "$NEW_AMOUNT" != "-" ]] || NEW_AMOUNT=""
[[ "$NEW_USED" != "-" ]] || NEW_USED=""

# Step 6: backfill user_id and login for the accounts that do not have them.
declare -a UIDS=() LOGINS=()
for ((i = 0; i < MPA_ACCOUNT_COUNT; i++)); do
    ACCT="${MPA_ACCOUNTS[i]}"
    UID_I="$(json_get_string "$ACCT" user_id)" || UID_I="$(json_get_number "$ACCT" user_id)" || UID_I=""
    LOGIN_I="$(json_get_string "$ACCT" login)" || LOGIN_I=""
    if [[ -z "$UID_I" ]]; then
        # Read the Box user of the account with its own token.
        BRC=0
        box_request "$i" GET "${BOX_API}/users/me?fields=id,login" "${TMP}/body" || BRC=$?
        if ((BRC == 0)); then
            BODY="$(tr -d '\n\r\t' <"${TMP}/body")"
            BID="$(json_get_string "$BODY" id)" || BID=""
            BLOGIN="$(json_get_string "$BODY" login)" || BLOGIN=""
            if [[ "$BID" =~ ^[A-Za-z0-9_-]+$ ]] &&
                json_account_add_fields "$ACCT_FILE" "$i" \
                    "$(json_string_field user_id "$BID"), $(json_string_field login "$BLOGIN")"; then
                UID_I="$BID"
                LOGIN_I="$BLOGIN"
            else
                BRC=1
            fi
        fi
        if ((BRC != 0)); then
            log_info "WARNING: Account #${i} ($(account_label "$i")): cannot read its Box user; skip it"
        fi
    fi
    UIDS[i]="$UID_I"
    LOGINS[i]="$LOGIN_I"
done

# Step 7: look for two existing accounts with the same Box user.
for ((i = 0; i < MPA_ACCOUNT_COUNT; i++)); do
    [[ -n "${UIDS[i]}" ]] || continue
    for ((j = i + 1; j < MPA_ACCOUNT_COUNT; j++)); do
        if [[ "${UIDS[i]}" == "${UIDS[j]}" ]]; then
            log_info "WARNING: Accounts #${i} and #${j} are the same Box user ${LOGINS[i]:-${LOGINS[j]:-${UIDS[i]}}}. One Box user holds two parts."
        fi
    done
done

# Step 7: does the new Box user match an existing account?
MATCH=-1
for ((i = 0; i < MPA_ACCOUNT_COUNT; i++)); do
    if [[ -n "${UIDS[i]}" && "${UIDS[i]}" == "$NEW_ID" ]]; then
        MATCH=$i
        break
    fi
done

if ((MATCH >= 0)); then
    # The re-login path. Do not add an entry. Save the tokens of the account.
    OWN_CID="$(json_get_string "${MPA_ACCOUNTS[MATCH]}" client_id)" || OWN_CID=""
    if [[ -n "$OWN_CID" && "$OWN_CID" != "$BOX_APP_CLIENT_ID" ]]; then
        die "Account #${MATCH} has its own client_id in box.json. The tokens of the Box app in .env do not fit. Remove client_id and secret from this account."
    fi
    KEY="$(_box_key "$MATCH")" || KEY=""
    [[ -n "$KEY" ]] || die "Account #${MATCH} has no name. Add a \"name\" to it in box.json."
    box_store_tokens "$KEY" || die "Cannot save the tokens of account #${MATCH}."
    log_info "Box account #${MATCH}: the login is renewed."
    printf 'This Box user is already account #%s (%s). The login is renewed.\n' "$MATCH" "$NEW_LOGIN"
    if [[ -n "$NAME_ARG" && "$NAME_ARG" != "$(json_get_string "${MPA_ACCOUNTS[MATCH]}" name || true)" ]]; then
        printf "The name argument '%s' is ignored.\n" "$NAME_ARG"
    fi
    print_free_space "$NEW_AMOUNT" "$NEW_USED"
    exit 0
fi

# Step 8: a new account. Find the name and check that nobody uses it.
NAME="${NAME_ARG:-box-${NEW_ID}}"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "The name '${NAME}' has a bad character."
for ((i = 0; i < MPA_ACCOUNT_COUNT; i++)); do
    if [[ "$(_box_key "$i" 2>/dev/null || true)" == "$NAME" ]]; then
        die "The name '${NAME}' is already used by account #${i}. Nothing is saved. Run the script again with a different name."
    fi
done
while IFS= read -r USED_NAME; do
    if [[ "$USED_NAME" == "$NAME" ]]; then
        die "The name '${NAME}' is already used in ${PROVIDER}.json. Nothing is saved. Run the script again with a different name."
    fi
done < <(file_names)

# Step 9: save the tokens first. Then add the account to box.json.
STORE="$(_box_state_dir)"
if [[ -e "${STORE}/${NAME}.refresh_token" || -e "${STORE}/${NAME}.access_token" ]]; then
    log_info "The stale token file for '${NAME}' was replaced."
fi
box_store_tokens "$NAME" || die "Cannot save the tokens for '${NAME}'."
NEW_OBJ="$(printf '{"name":"%s","user_id":"%s","login":"%s"}' \
    "$(json_escape "$NAME")" "$(json_escape "$NEW_ID")" "$(json_escape "$NEW_LOGIN")")"
if ! json_accounts_append "$ACCT_FILE" "$NEW_OBJ"; then
    die "The tokens are saved, but the account was not added to ${PROVIDER}.json. Run the script again."
fi
log_info "Box account #${MPA_ACCOUNT_COUNT} (${NAME}) added."
printf 'Added account #%s: %s\n' "$MPA_ACCOUNT_COUNT" "$NEW_LOGIN"
print_free_space "$NEW_AMOUNT" "$NEW_USED"
exit 0
