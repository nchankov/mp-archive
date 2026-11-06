#!/usr/bin/env bash
# Box provider for mp-archive.
# This file is sourced by common.sh. It implements the PROVIDER INTERFACE.
# Do not call "exit" here. Return the contract codes (3 = authentication failure).
#
# Token sources, in this order:
#   1. OAuth 2.0 refresh token in the state directory (bin/add-account.sh saves it).
#   2. The key developer_token in the account object (it expires after 60 minutes).
# Account keys that this file reads: name, client_id, secret, developer_token,
# user_id, login.
# App credentials: the keys client_id and secret of an account win.
# Else the values BOX_APP_CLIENT_ID and BOX_APP_SECRET (from .env) are used.
# A secret never goes to a log, to stdout, or to the curl command line.
# Curl reads the secrets from a header file or a form body in a pipe.

BOX_API="https://api.box.com/2.0"
BOX_UPLOAD_API="https://upload.box.com/api/2.0"
BOX_TOKEN_URL="https://api.box.com/oauth2/token"
BOX_AUTHORIZE_URL="https://account.box.com/api/oauth2/authorize"

# Default folders. These values are the same as in common.sh.
# They apply only when this file is used without mpa_init.
_BOX_CONFIG_DIR_DEFAULT="${MPA_DEFAULT_CONFIG_DIR:-/etc/mp-archive}"
_BOX_STATE_DIR_DEFAULT="${MPA_DEFAULT_STATE_DIR:-/var/lib/mp-archive}"

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------

# Check the provider settings and the account keys.
provider_init() {
  BOX_FOLDER_ID="${BOX_FOLDER_ID:-0}"
  if [[ ! "$BOX_FOLDER_ID" =~ ^[0-9]+$ ]]; then
    log_error "Box: BOX_FOLDER_ID must contain only digits."
    return 2
  fi
  BOX_CHUNK_THRESHOLD="${BOX_CHUNK_THRESHOLD:-52428800}"
  if [[ ! "$BOX_CHUNK_THRESHOLD" =~ ^[0-9]+$ ]]; then
    log_error "Box: BOX_CHUNK_THRESHOLD must contain only digits."
    return 2
  fi
  # Warn when a file with secrets is readable by other users. Do not fail.
  _box_warn_mode "${MPARCHIVE_CONFIG_DIR:-$_BOX_CONFIG_DIR_DEFAULT}/.env" ".env"
  _box_warn_mode "${MPARCHIVE_CONFIG_DIR:-$_BOX_CONFIG_DIR_DEFAULT}/${PROVIDER:-box}.json" "${PROVIDER:-box}.json"
  _box_check_keys || return 2
  return 0
}

# Write a warning when a file has a group or other permission bit.
# Usage: _box_warn_mode <path> <display name>
_box_warn_mode() {
  local path="$1" label="$2" mode
  [[ -f "$path" ]] || return 0
  mode="$(stat -c %a -- "$path" 2>/dev/null)" || return 0
  if [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 8#077) != 0 )); then
    log_info "WARNING: ${label} has mode ${mode}. Run chmod 600 ${label}."
  fi
  return 0
}

# Print the client_id of account <idx>: the account value, else BOX_APP_CLIENT_ID.
# <idx> "app" means the .env value only. Print nothing when there is none.
_box_client_id() {
  local v=""
  if [[ "$1" != "app" ]]; then
    v="$(json_get_string "${MPA_ACCOUNTS[$1]:-}" client_id)" || v=""
  fi
  [[ -n "$v" ]] || v="${BOX_APP_CLIENT_ID:-}"
  printf '%s' "$v"
}

# Print the secret of account <idx>: the account value, else BOX_APP_SECRET.
# The secret goes only to stdout of a command substitution. Never log it.
_box_client_secret() {
  local v=""
  if [[ "$1" != "app" ]]; then
    v="$(json_get_string "${MPA_ACCOUNTS[$1]:-}" secret)" || v=""
  fi
  [[ -n "$v" ]] || v="${BOX_APP_SECRET:-}"
  printf '%s' "$v"
}

# Log the error for missing app credentials. Return 2.
_box_creds_missing() {
  log_error "Box app credentials are missing. Set BOX_APP_CLIENT_ID and BOX_APP_SECRET in .env."
  return 2
}

# Print the text for a new login of account <idx>.
_box_relogin_hint() {
  local idx="$1" acct login name who
  acct="${MPA_ACCOUNTS[idx]:-}"
  login="$(json_get_string "$acct" login)" || login=""
  if [[ -n "$login" ]]; then
    who="log in as ${login}"
  else
    name="$(json_get_string "$acct" name)" || name=""
    [[ -n "$name" ]] || name="$(_box_key "$idx" 2>/dev/null)" || name=""
    who="log in as the Box user of account #${idx} (${name:-no name})"
  fi
  printf 'Run ./bin/add-account.sh and %s to renew the login of account #%s.' "$who" "$idx"
}

# Check that each account has a valid and unique token-store key.
_box_check_keys() {
  local i key j other count="${#MPA_ACCOUNTS[@]}"
  local -a keys=()
  for (( i = 0; i < count; i++ )); do
    key="$(_box_key "$i")" || return 1
    keys[i]="$key"
    [[ -n "$key" ]] || continue
    for (( j = 0; j < i; j++ )); do
      other="${keys[j]}"
      if [[ "$other" == "$key" ]]; then
        log_error "Box accounts #${j} and #${i} use the same token key. Add a different \"name\" to each account in the account file."
        return 1
      fi
    done
  done
  return 0
}

# ---------------------------------------------------------------------------
# Token store
# ---------------------------------------------------------------------------

# Print the current time as epoch seconds. Tests can replace this function.
_box_now() {
  date +%s
}

# Print the key of account <idx>: the "name", else the effective client_id.
# Print nothing when the account has neither. Return 2 on a bad key.
_box_key() {
  local idx="$1" acct key
  acct="${MPA_ACCOUNTS[idx]:-}"
  key="$(json_get_string "$acct" name)" || key=""
  if [[ -z "$key" ]]; then
    key="$(_box_client_id "$idx")"
  fi
  [[ -n "$key" ]] || return 0
  if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "Box account #${idx}: the name or client_id has a bad character. Use only A-Z, a-z, 0-9, dot, underscore, and hyphen."
    return 2
  fi
  printf '%s' "$key"
}

# Print the directory of the token store.
_box_state_dir() {
  printf '%s/box' "${MPARCHIVE_STATE_DIR:-$_BOX_STATE_DIR_DEFAULT}"
}

# Create the token store with mode 700.
_box_state_prepare() {
  local dir="$1"
  if ! ( umask 077; mkdir -p -- "$dir" ) 2>/dev/null; then
    log_error "Box: cannot create the token directory."
    return 1
  fi
  chmod 700 -- "$dir" 2>/dev/null || true
}

# Write stdin to a file. Use a temp file in the same directory, then rename.
_box_atomic_write() {
  local dest="$1" tmp
  tmp="$(umask 077; mktemp -- "${dest}.XXXXXX")" || return 1
  if cat >"$tmp" && chmod 600 -- "$tmp" && mv -f -- "$tmp" "$dest"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# Return 0 when account <idx> has an OAuth refresh token.
_box_is_oauth() {
  local key
  key="$(_box_key "$1" 2>/dev/null)" || return 1
  [[ -n "$key" && -f "$(_box_state_dir)/${key}.refresh_token" ]]
}

# Print the cached access token. Return 1 when it is missing or near expiry.
_box_cached_access() {
  local key="$1" file tok="" exp="" now
  file="$(_box_state_dir)/${key}.access_token"
  [[ -r "$file" ]] || return 1
  { IFS= read -r tok || true; IFS= read -r exp || true; } <"$file"
  [[ -n "$tok" && "$exp" =~ ^[0-9]+$ ]] || return 1
  now="$(_box_now)"
  (( exp - now > 300 )) || return 1
  printf '%s' "$tok"
}

# Delete the cached access token of account <idx>.
_box_drop_access() {
  local key
  key="$(_box_key "$1" 2>/dev/null)" || return 0
  [[ -n "$key" ]] || return 0
  rm -f -- "$(_box_state_dir)/${key}.access_token"
}

# Encode a text for a form body. Pure Bash, byte by byte.
_box_urlencode() {
  local LC_ALL=C s="$1" out="" c hex i
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Za-z0-9._~-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

# Take the lock <dir>. Wait for a lock of another process.
# Settings: BOX_LOCK_WAIT (60 s), BOX_LOCK_STALE (120 s), BOX_LOCK_SLEEP (1 s).
_box_lock_acquire() {
  local lock="$1" waited=0 fails=0 mtime now
  local max="${BOX_LOCK_WAIT:-60}" stale="${BOX_LOCK_STALE:-120}"
  while :; do
    if ( umask 077; mkdir -- "$lock" ) 2>/dev/null; then
      return 0
    fi
    if [[ ! -d "$lock" ]]; then
      # The mkdir failed for another reason. Do not loop for ever.
      fails=$((fails + 1))
      if (( fails > 5 )); then
        log_error "Box: cannot create the lock directory."
        return 1
      fi
      continue
    fi
    mtime="$(stat -c %Y -- "$lock" 2>/dev/null)" || mtime=""
    now="$(_box_now)"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( now - mtime > stale )); then
      log_info "Box: remove a stale lock."
      rmdir -- "$lock" 2>/dev/null || true
      continue
    fi
    if (( waited >= max )); then
      log_error "Box: the token lock is busy for ${max} seconds."
      return 1
    fi
    sleep "${BOX_LOCK_SLEEP:-1}"
    waited=$((waited + 1))
  done
}

# Release the lock <dir>.
_box_lock_release() {
  rmdir -- "$1" 2>/dev/null || true
}

# Run a function with the lock of account <idx>.
# The function always releases the lock before it returns.
# Usage: _box_with_lock <idx> <function> [args...]
_box_with_lock() {
  local idx="$1" fn="$2" key
  shift 2
  key="$(_box_key "$idx")" || return 2
  if [[ -z "$key" ]]; then
    log_error "Box account #${idx}: the account has no name and no client_id."
    return 2
  fi
  _box_with_key_lock "$key" "$fn" "$@"
}

# Run a function with the lock of the token key <key>.
# Usage: _box_with_key_lock <key> <function> [args...]
_box_with_key_lock() {
  local key="$1" fn="$2" dir rc=0
  shift 2
  dir="$(_box_state_dir)"
  _box_state_prepare "$dir" || return 2
  _box_lock_acquire "${dir}/${key}.lock" || return 2
  "$fn" "$@" || rc=$?
  _box_lock_release "${dir}/${key}.lock"
  return "$rc"
}

# The network seam for the token endpoint. Tests replace it.
# Usage: box_oauth_http <idx> <method> <url> <body_out_file> [extra curl args...]
# Same contract as box_http, but it sends no Authorization header.
# Print the HTTP status code on stdout. Print 000 on a transport failure.
box_oauth_http() {
  local method="$2" url="$3" out="$4" code
  shift 4
  code="$("${MPARCHIVE_CURL:-curl}" -sS --max-time 60 -X "$method" -o "$out" \
    -w '%{http_code}' "$@" "$url")" || true
  printf '%s' "${code:-000}"
}

# Send a form to the token endpoint. Keep the answer in memory.
# Result: _BOX_TK_ACCESS, _BOX_TK_REFRESH, _BOX_TK_EXPIRES (seconds). Secrets!
# <idx> is an account number, or "new" for a login that has no account yet.
# Usage: _box_token_post <tmp> <idx> <form> <kind: refresh|exchange>
_box_token_post() {
  local tmp="$1" idx="$2" form="$3" kind="$4"
  local who="Box account #${idx}"
  local code attempt=0 body err desc
  [[ "$idx" == "new" ]] && who="Box login"
  _BOX_TK_ACCESS=""
  _BOX_TK_REFRESH=""
  _BOX_TK_EXPIRES=""
  while :; do
    # The process substitution keeps the form (with secrets) off the command line.
    code="$(box_oauth_http "$idx" POST "$BOX_TOKEN_URL" "$tmp/body" \
      --data-binary @<(printf '%s' "$form"))" || code=000
    [[ -n "$code" ]] || code=000
    case "$code" in
      000|429|5??)
        if (( attempt < 2 )); then
          sleep "${BOX_RETRY_SLEEP:-$((attempt + 1))}"
          attempt=$((attempt + 1))
          continue
        fi
        log_error "${who}: the token request failed (HTTP ${code})."
        return 2
        ;;
    esac
    break
  done
  body=""
  [[ -s "$tmp/body" ]] && body="$(head -c 8192 "$tmp/body" | tr -d '\n\r\t')"
  if [[ "$code" == "200" ]]; then
    _BOX_TK_ACCESS="$(json_get_string "$body" access_token)" || _BOX_TK_ACCESS=""
    _BOX_TK_REFRESH="$(json_get_string "$body" refresh_token)" || _BOX_TK_REFRESH=""
    _BOX_TK_EXPIRES="$(json_get_number "$body" expires_in)" || _BOX_TK_EXPIRES=3600
    # A valid answer has an access token and a refresh token.
    if [[ -z "$_BOX_TK_ACCESS" || -z "$_BOX_TK_REFRESH" ]]; then
      log_error "${who}: the token response has no token."
      _BOX_TK_ACCESS=""
      _BOX_TK_REFRESH=""
      return 2
    fi
    return 0
  fi
  err="$(json_get_string "$body" error)" || err=""
  desc="$(json_get_string "$body" error_description)" || desc=""
  [[ "$err" =~ ^[a-z_]+$ ]] || err=""
  desc="${desc:0:200}"
  if [[ "$err" == "invalid_grant" ]]; then
    if [[ "$kind" == "refresh" ]]; then
      log_error "Box account #${idx}: the refresh token is expired or revoked. $(_box_relogin_hint "$idx")"
    else
      log_error "${who}: the authorization code is invalid or expired. Run ./bin/add-account.sh again and paste the address within 30 seconds."
    fi
    return 3
  fi
  log_error "${who}: the token request failed (HTTP ${code})${err:+ error=${err}}${desc:+ description=${desc}}"
  case "$code" in
    400|401) return 3 ;;
  esac
  return 2
}

# Send a form to the token endpoint, then save the new tokens of account <idx>.
# Print the new access token. The caller holds the lock.
# Usage: _box_token_call <tmp> <idx> <form> <kind: refresh|exchange>
_box_token_call() {
  local idx="$2" key dir
  key="$(_box_key "$idx")" || return 2
  dir="$(_box_state_dir)"
  _box_token_post "$@" || return $?
  if ! _box_store_both "$dir" "$key"; then
    # The refresh token is saved first. The access token is the second file.
    log_error "Box account #${idx}: cannot save the new tokens. $(_box_relogin_hint "$idx")"
    return 2
  fi
  printf '%s' "$_BOX_TK_ACCESS"
  _BOX_TK_ACCESS=""
  _BOX_TK_REFRESH=""
  return 0
}

# Save the access token in memory (_BOX_TK_*) to the cache file of <key>.
_box_store_access() {
  local dir="$1" key="$2" now
  now="$(_box_now)"
  printf '%s\n%s\n' "$_BOX_TK_ACCESS" "$((now + _BOX_TK_EXPIRES))" |
    _box_atomic_write "${dir}/${key}.access_token"
}

# Save the refresh token FIRST (the old one is now invalid), then the access token.
_box_store_both() {
  local dir="$1" key="$2"
  printf '%s\n' "$_BOX_TK_REFRESH" | _box_atomic_write "${dir}/${key}.refresh_token" || return 1
  _box_store_access "$dir" "$key"
}

# Save the tokens that box_oauth_exchange_new keeps in memory under <key>.
# Usage: box_store_tokens <key>. Return 0 ok, 1 on a write error.
# The memory is cleared in both cases. Take the key lock while it writes.
box_store_tokens() {
  local key="$1" rc=0
  if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log_error "Box: the token key has a bad character."
    return 1
  fi
  _box_with_key_lock "$key" _box_store_locked "$key" || rc=1
  _BOX_TK_ACCESS=""
  _BOX_TK_REFRESH=""
  return "$rc"
}

_box_store_locked() {
  _box_store_both "$(_box_state_dir)" "$1"
}

# Refresh the access token. The caller holds the lock.
# Use the cache first: another process can have refreshed it.
_box_refresh_locked() {
  local idx="$1" key dir tok="" rt="" cid secret form
  key="$(_box_key "$idx")" || return 2
  dir="$(_box_state_dir)"
  if tok="$(_box_cached_access "$key")"; then
    printf '%s' "$tok"
    return 0
  fi
  [[ -r "${dir}/${key}.refresh_token" ]] && IFS= read -r rt <"${dir}/${key}.refresh_token" || true
  if [[ -z "$rt" ]]; then
    log_error "Box account #${idx}: no token. $(_box_relogin_hint "$idx")"
    return 3
  fi
  cid="$(_box_client_id "$idx")"
  secret="$(_box_client_secret "$idx")"
  if [[ -z "$cid" || -z "$secret" ]]; then
    _box_creds_missing
    return
  fi
  form="grant_type=refresh_token&refresh_token=$(_box_urlencode "$rt")"
  form+="&client_id=$(_box_urlencode "$cid")&client_secret=$(_box_urlencode "$secret")"
  _box_with_tmp _box_token_call "$idx" "$form" refresh
}

# Exchange an authorization code for tokens of the Box app in .env.
# The tokens stay in memory until box_store_tokens saves them.
# Result: _BOX_TK_ACCESS, _BOX_TK_REFRESH, _BOX_TK_EXPIRES. They are secrets.
# Usage: box_oauth_exchange_new <code> <redirect_uri>
# Return 0 ok, 3 when the code or the client is rejected, 2 on other errors.
box_oauth_exchange_new() {
  local code="$1" redirect="$2" cid secret form
  cid="$(_box_client_id app)"
  secret="$(_box_client_secret app)"
  if [[ -z "$cid" || -z "$secret" ]]; then
    _box_creds_missing
    return
  fi
  form="grant_type=authorization_code&code=$(_box_urlencode "$code")"
  form+="&client_id=$(_box_urlencode "$cid")&client_secret=$(_box_urlencode "$secret")"
  form+="&redirect_uri=$(_box_urlencode "$redirect")"
  _box_with_tmp _box_token_post new "$form" exchange
}

# Print the URL for the browser login.
# Usage: box_authorize_url <idx|app> <redirect_uri> <state>
# "app" uses BOX_APP_CLIENT_ID only. A number uses the account value, else .env.
box_authorize_url() {
  local cid
  cid="$(_box_client_id "$1")"
  if [[ -z "$cid" ]]; then
    _box_creds_missing
    return
  fi
  printf '%s?response_type=code&client_id=%s&redirect_uri=%s&state=%s\n' \
    "$BOX_AUTHORIZE_URL" "$(_box_urlencode "$cid")" "$(_box_urlencode "$2")" \
    "$(_box_urlencode "$3")"
}

# Read the user of the tokens that are in memory (_BOX_TK_ACCESS).
# Print one line: "<id><TAB><login><TAB><space_amount><TAB><space_used>".
# A field that is absent in the answer is written as "-". Return 0 ok, 3 on HTTP 401, 2 on other errors.
box_new_user_info() {
  _box_with_tmp _box_new_user_info_run
}

_box_new_user_info_run() {
  local tmp="$1" code attempt=0 body id login amount used
  while :; do
    # The process substitution keeps the token off the command line.
    code="$("${MPARCHIVE_CURL:-curl}" -sS -X GET -o "$tmp/body" -w '%{http_code}' \
      -H @<(printf 'Authorization: Bearer %s\n' "$_BOX_TK_ACCESS") \
      "${BOX_API}/users/me?fields=id,login,space_amount,space_used")" || code=000
    [[ -n "$code" ]] || code=000
    case "$code" in
      000|429|5??)
        if (( attempt < 2 )); then
          sleep "${BOX_RETRY_SLEEP:-$((attempt + 1))}"
          attempt=$((attempt + 1))
          continue
        fi
        log_error "Box: the request for the Box user failed (HTTP ${code})."
        return 2
        ;;
    esac
    break
  done
  case "$code" in
    2??) ;;
    401) log_error "Box: Box rejected the new access token (HTTP 401)."; return 3 ;;
    *) log_error "Box: the request for the Box user failed (HTTP ${code}) $(_box_error_detail "$tmp/body")"; return 2 ;;
  esac
  body="$(_box_body "$tmp/body")"
  id="$(_box_acct_value "$body" id)"
  login="$(json_get_string "$body" login)" || login=""
  amount="$(json_get_number "$body" space_amount)" || amount=""
  used="$(json_get_number "$body" space_used)" || used=""
  if [[ ! "$id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log_error "Box: the answer has no valid user id."
    return 2
  fi
  printf '%s\t%s\t%s\t%s\n' "$id" "${login:--}" "${amount:--}" "${used:--}"
}

# Print a value of an account key. Accept a string or a number.
# Print nothing when the key is absent.
_box_acct_value() {
  local acct="$1" key="$2" v
  v="$(json_get_string "$acct" "$key")" || v=""
  if [[ -z "$v" ]]; then
    v="$(json_get_number "$acct" "$key")" || v=""
  fi
  printf '%s' "$v"
}

# Print the access token of account <idx>. Return 3 when there is no token.
_box_token() {
  local idx="$1" key token
  if [[ ! "$idx" =~ ^[0-9]+$ || -z "${MPA_ACCOUNTS[idx]+set}" ]]; then
    log_error "Box: account #${idx} does not exist."
    return 2
  fi
  key="$(_box_key "$idx")" || return 2
  # OAuth has the first priority, then developer_token.
  if [[ -n "$key" && -f "$(_box_state_dir)/${key}.refresh_token" ]]; then
    if token="$(_box_cached_access "$key")"; then
      printf '%s' "$token"
      return 0
    fi
    _box_with_lock "$idx" _box_refresh_locked "$idx"
    return
  fi
  token="$(json_get_string "${MPA_ACCOUNTS[idx]}" developer_token)" || token=""
  if [[ -n "$token" ]]; then
    printf '%s' "$token"
    return 0
  fi
  log_error "Box account #${idx}: no token. $(_box_relogin_hint "$idx")"
  return 3
}

# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

# The only function that starts curl. Tests replace it.
# Usage: box_http <idx> <method> <url> <body_out_file> [extra curl args...]
# Print the HTTP status code on stdout. Print 000 on a transport failure.
# If <idx> is "none", send no Authorization header (used for download URLs).
box_http() {
  local idx="$1" method="$2" url="$3" out="$4" token code
  shift 4
  if [[ "$idx" == "none" ]]; then
    code="$("${MPARCHIVE_CURL:-curl}" -sS -X "$method" -o "$out" -w '%{http_code}' \
      "$@" "$url")" || true
  else
    token="$(_box_token "$idx")" || { printf '000'; return 0; }
    # The process substitution keeps the token out of the process list.
    code="$("${MPARCHIVE_CURL:-curl}" -sS -X "$method" -o "$out" -w '%{http_code}' \
      -H @<(printf 'Authorization: Bearer %s\n' "$token") \
      "$@" "$url")" || true
  fi
  printf '%s' "${code:-000}"
}

# Send a request with retry and error handling.
# Usage: box_request <idx> <method> <url> <body_out_file> [extra curl args...]
# Return 0 on 2xx (and on codes listed in BOX_OK_CODES). Set BOX_LAST_CODE.
# Return 3 on HTTP 401. Return 2 on other errors.
box_request() {
  local idx="$1" method="$2" url="$3" out="$4" code attempt=0 ok detail msg oauth_retry=0
  local -a delays=(1 2 4)
  shift 4
  # Check the token only when the account exists (tests can skip accounts).
  if [[ "$idx" != "none" && -n "${MPA_ACCOUNTS[idx]+set}" ]]; then
    # This call also refreshes an expired OAuth token. Keep its return code.
    _box_token "$idx" >/dev/null || return $?
  fi
  while :; do
    code="$(box_http "$idx" "$method" "$url" "$out" "$@")" || code=000
    [[ -n "$code" ]] || code=000
    BOX_LAST_CODE="$code"
    case "$code" in
      2??) return 0 ;;
      401)
        if [[ "$idx" != "none" ]] && _box_is_oauth "$idx"; then
          if (( oauth_retry == 0 )); then
            # Delete the access cache, refresh once, and send the call again.
            oauth_retry=1
            _box_drop_access "$idx"
            _box_token "$idx" >/dev/null || return $?
            continue
          fi
          log_error "Box account #${idx}: Box rejected the new access token (HTTP 401). $(_box_relogin_hint "$idx")"
          return 3
        fi
        log_error "Box account #${idx}: the developer token is expired or invalid (HTTP 401). Generate a new developer token in the Box Developer Console and update box.json."
        return 3
        ;;
      000|429|5??)
        if (( attempt < 3 )); then
          sleep "${BOX_RETRY_SLEEP:-${delays[attempt]}}"
          attempt=$((attempt + 1))
          continue
        fi
        log_error "Box account #${idx}: ${method} request failed after 3 retries (HTTP ${code})."
        return 2
        ;;
    esac
    for ok in ${BOX_OK_CODES:-}; do
      [[ "$ok" == "$code" ]] && return 0
    done
    detail="$(_box_error_detail "$out")"
    log_error "Box account #${idx}: ${method} request failed (HTTP ${code})${detail:+ $detail}"
    return 2
  done
}

# Print the Box error code and message from a response body file.
_box_error_detail() {
  local file="$1" body c m
  [[ -s "$file" ]] || return 0
  body="$(head -c 4096 "$file" | tr -d '\n\r\t')"
  c="$(json_get_string "$body" code)" || c=""
  m="$(json_get_string "$body" message)" || m=""
  [[ -n "$c$m" ]] && printf 'code=%s message=%s' "$c" "$m"
  return 0
}

# Read a body file as one line.
_box_body() {
  tr -d '\n\r\t' <"$1"
}

# Make a work directory and run a function in it. Remove the directory after.
# Usage: _box_with_tmp <function> [args...]. The function gets the directory first.
_box_with_tmp() {
  local fn="$1" tmp rc=0
  shift
  tmp="$(make_tmpdir)" || { log_error "Box: cannot create a temporary directory."; return 2; }
  "$fn" "$tmp" "$@" || rc=$?
  rm -rf -- "$tmp"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Hash helper
# ---------------------------------------------------------------------------

# Print the base64 text of the binary SHA-1 of a file.
# Method: hex digest -> \xHH escapes -> printf %b -> base64. No xxd.
box_sha1_base64() {
  local esc
  esc="$(sha1sum -- "$1" | cut -c1-40 | sed 's/\(..\)/\\x\1/g')"
  printf '%b' "$esc" | base64
}

# ---------------------------------------------------------------------------
# Interface functions
# ---------------------------------------------------------------------------

_box_free_space() {
  local tmp="$1" idx="$2" body amount used free rc=0
  box_request "$idx" GET "${BOX_API}/users/me?fields=space_amount,space_used" "$tmp/body" || rc=$?
  (( rc == 0 )) || return "$rc"
  body="$(_box_body "$tmp/body")"
  amount="$(json_get_number "$body" space_amount)" || amount=""
  used="$(json_get_number "$body" space_used)" || used=""
  if [[ -z "$amount" || -z "$used" ]]; then
    log_error "Box account #${idx}: the space fields are missing in the response."
    return 2
  fi
  # A negative or very large quota means unlimited storage.
  if (( amount < 0 || amount >= 999999999999999 )); then
    printf '999999999999999\n'
    return 0
  fi
  free=$((amount - used))
  (( free < 0 )) && free=0
  printf '%s\n' "$free"
}

# Print the free space of account <idx> in bytes.
provider_get_free_space() {
  _box_with_tmp _box_free_space "$1"
}

# Print "<id><TAB><name>" for every file in the folder (all pages).
_box_list_all() {
  local tmp="$1" idx="$2" offset=0 total body entries entry n rc
  while :; do
    rc=0
    box_request "$idx" GET \
      "${BOX_API}/folders/${BOX_FOLDER_ID:-0}/items?fields=name&limit=1000&offset=${offset}" \
      "$tmp/body" || rc=$?
    (( rc == 0 )) || return "$rc"
    body="$(_box_body "$tmp/body")"
    total="$(json_get_number "$body" total_count)" || total=0
    entries="$(printf '%s' "$body" | grep -o '{[^{}]*}' || true)"
    n=0
    while IFS= read -r entry; do
      [[ "$entry" =~ \"type\"[[:space:]]*: ]] || continue
      n=$((n + 1))
      # Keep files only. Ignore folders and web links.
      [[ "$entry" =~ \"type\"[[:space:]]*:[[:space:]]*\"file\" ]] || continue
      local id name
      id="$(json_get_string "$entry" id)" || continue
      name="$(json_get_string "$entry" name)" || continue
      printf '%s\t%s\n' "$id" "$name"
    done <<<"$entries"
    offset=$((offset + n))
    # Stop on an empty page or when all entries are read.
    (( n > 0 && offset < total )) || break
  done
}

_box_list_files() {
  local tmp="$1" idx="$2" archive="$3" all rc=0 id name
  all="$(_box_list_all "$tmp" "$idx")" || rc=$?
  (( rc == 0 )) || return "$rc"
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    # The quoted archive text is literal. Only the "*" is a pattern.
    case "$name" in
      "$archive".p*.tar.gz) printf '%s\t%s\n' "$id" "$name" ;;
    esac
  done <<<"$all"
}

# Print "<id><TAB><name>" for the parts of an archive.
provider_list_files() {
  _box_with_tmp _box_list_files "$1" "$2"
}

_box_find_file() {
  local tmp="$1" idx="$2" remote="$3" all rc=0 id name
  all="$(_box_list_all "$tmp" "$idx")" || rc=$?
  (( rc == 0 )) || return "$rc"
  while IFS=$'\t' read -r id name; do
    if [[ -n "$id" && "$name" == "$remote" ]]; then
      printf '%s\n' "$id"
      return 0
    fi
  done <<<"$all"
  return 1
}

# Print the id of a file. Return 0 found, 1 not found, 2+ error.
provider_find_file() {
  local rc=0
  _box_with_tmp _box_find_file "$1" "$2" || rc=$?
  # Keep code 3 (authentication) and code 1 (not found) as they are.
  return "$rc"
}

# Simple upload with one multipart request.
# <existing_id> is empty for a new file.
_box_upload_simple() {
  local tmp="$1" idx="$2" local_path="$3" remote="$4" existing="$5"
  local attrs url link abs rc=0 body conflict
  # A symlink with a safe name avoids problems with spaces and commas in -F.
  case "$local_path" in
    /*) abs="$local_path" ;;
    *) abs="$PWD/$local_path" ;;
  esac
  link="$tmp/upload.bin"
  ln -s -- "$abs" "$link" || { log_error "Box: cannot link the file ${local_path}."; return 2; }
  if [[ -n "$existing" ]]; then
    attrs="{\"name\":\"$(json_escape "$remote")\"}"
    url="${BOX_UPLOAD_API}/files/${existing}/content"
  else
    attrs="{\"name\":\"$(json_escape "$remote")\",\"parent\":{\"id\":\"${BOX_FOLDER_ID:-0}\"}}"
    url="${BOX_UPLOAD_API}/files/content"
  fi
  # A 409 on a new file means the name exists. Handle it below.
  if [[ -z "$existing" ]]; then
    BOX_OK_CODES="409" box_request "$idx" POST "$url" "$tmp/body" \
      --form-string "attributes=${attrs}" -F "file=@\"${link}\"" || rc=$?
  else
    box_request "$idx" POST "$url" "$tmp/body" \
      --form-string "attributes=${attrs}" -F "file=@\"${link}\"" || rc=$?
  fi
  (( rc == 0 )) || return "$rc"
  if [[ "$BOX_LAST_CODE" == "409" ]]; then
    body="$(_box_body "$tmp/body")"
    # Read the id of the conflicting file from context_info.conflicts.
    conflict="$(json_get_string "${body#*\"conflicts\"}" id)" || conflict=""
    if [[ -z "$conflict" ]]; then
      log_error "Box account #${idx}: the name is in use but the conflict id is missing."
      return 2
    fi
    rc=0
    box_request "$idx" POST "${BOX_UPLOAD_API}/files/${conflict}/content" "$tmp/body2" \
      --form-string "attributes={\"name\":\"$(json_escape "$remote")\"}" \
      -F "file=@\"${link}\"" || rc=$?
    return "$rc"
  fi
  return 0
}

# Cancel an upload session. Ignore errors.
_box_abort_session() {
  local tmp="$1" idx="$2" sid="$3"
  BOX_OK_CODES="404" box_request "$idx" DELETE "${BOX_UPLOAD_API}/files/upload_sessions/${sid}" \
    "$tmp/abort" >/dev/null 2>&1 || true
}

# Chunked upload with an upload session.
_box_upload_chunked() {
  local tmp="$1" idx="$2" local_path="$3" remote="$4" existing="$5" size="$6"
  local json url body sid part_size total_parts k start end len code rc parts="" part
  local digest wait tries
  if [[ -n "$existing" ]]; then
    json="{\"file_size\":${size},\"file_name\":\"$(json_escape "$remote")\"}"
    url="${BOX_UPLOAD_API}/files/${existing}/upload_sessions"
  else
    json="{\"folder_id\":\"${BOX_FOLDER_ID:-0}\",\"file_size\":${size},\"file_name\":\"$(json_escape "$remote")\"}"
    url="${BOX_UPLOAD_API}/files/upload_sessions"
  fi
  rc=0
  # A 409 on a new file means the name exists. Use the new version session.
  BOX_OK_CODES="409" box_request "$idx" POST "$url" "$tmp/body" \
    -H 'Content-Type: application/json' --data-binary "$json" || rc=$?
  (( rc == 0 )) || return "$rc"
  body="$(_box_body "$tmp/body")"
  if [[ "$BOX_LAST_CODE" == "409" ]]; then
    existing="$(json_get_string "${body#*\"conflicts\"}" id)" || existing=""
    [[ -n "$existing" ]] || { log_error "Box account #${idx}: the conflict id is missing."; return 2; }
    json="{\"file_size\":${size},\"file_name\":\"$(json_escape "$remote")\"}"
    rc=0
    box_request "$idx" POST "${BOX_UPLOAD_API}/files/${existing}/upload_sessions" "$tmp/body" \
      -H 'Content-Type: application/json' --data-binary "$json" || rc=$?
    (( rc == 0 )) || return "$rc"
    body="$(_box_body "$tmp/body")"
  fi
  sid="$(json_get_string "$body" id)" || sid=""
  part_size="$(json_get_number "$body" part_size)" || part_size=""
  total_parts="$(json_get_number "$body" total_parts)" || total_parts=""
  if [[ -z "$sid" || -z "$part_size" || -z "$total_parts" ]] || (( part_size <= 0 )); then
    log_error "Box account #${idx}: the upload session response is not valid."
    return 2
  fi

  for (( k = 0; k < total_parts; k++ )); do
    start=$((k * part_size))
    len=$part_size
    (( start + len > size )) && len=$((size - start))
    end=$((start + len - 1))
    log_info "Box account #${idx}: ${remote} chunk $((k + 1))/${total_parts}"
    dd if="$local_path" of="$tmp/chunk" bs="$part_size" skip="$k" count=1 \
      iflag=fullblock status=none || {
        log_error "Box: cannot read chunk $((k + 1)) of ${local_path}."
        _box_abort_session "$tmp" "$idx" "$sid"
        return 2
      }
    digest="$(box_sha1_base64 "$tmp/chunk")"
    rc=0
    box_request "$idx" PUT "${BOX_UPLOAD_API}/files/upload_sessions/${sid}" "$tmp/body" \
      -H 'Content-Type: application/octet-stream' \
      -H "Content-Range: bytes ${start}-${end}/${size}" \
      -H "Digest: sha=${digest}" \
      --data-binary "@${tmp}/chunk" || rc=$?
    if (( rc != 0 )); then
      _box_abort_session "$tmp" "$idx" "$sid"
      return "$rc"
    fi
    part="$(_box_body "$tmp/body" | grep -o '{[^{}]*}' | head -n 1 || true)"
    if [[ -z "$part" ]]; then
      log_error "Box account #${idx}: no part data in the response for chunk $((k + 1))."
      _box_abort_session "$tmp" "$idx" "$sid"
      return 2
    fi
    parts="${parts:+${parts},}${part}"
  done
  rm -f -- "$tmp/chunk"

  # Commit the session. Box can answer 202 when it is not ready.
  digest="$(box_sha1_base64 "$local_path")"
  for (( tries = 0; tries < 10; tries++ )); do
    rc=0
    BOX_OK_CODES="202" box_request "$idx" POST "${BOX_UPLOAD_API}/files/upload_sessions/${sid}/commit" \
      "$tmp/body" -D "$tmp/hdr" \
      -H 'Content-Type: application/json' -H "Digest: sha=${digest}" \
      --data-binary "{\"parts\":[${parts}]}" || rc=$?
    if (( rc != 0 )); then
      _box_abort_session "$tmp" "$idx" "$sid"
      return "$rc"
    fi
    [[ "$BOX_LAST_CODE" == "202" ]] || return 0
    wait=2
    if [[ -r "$tmp/hdr" ]]; then
      code="$(tr -d '\r' <"$tmp/hdr" | sed -n 's/^[Rr]etry-[Aa]fter:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
      [[ -n "$code" ]] && wait="$code"
    fi
    sleep "${BOX_RETRY_SLEEP:-$wait}"
  done
  log_error "Box account #${idx}: the commit for ${remote} is not ready after 10 tries."
  _box_abort_session "$tmp" "$idx" "$sid"
  return 2
}

_box_upload() {
  local tmp="$1" idx="$2" local_path="$3" remote="$4" size existing="" rc=0
  if [[ ! -f "$local_path" || ! -r "$local_path" ]]; then
    log_error "Box: the local file ${local_path} is missing or not readable."
    return 2
  fi
  size="$(file_size "$local_path")"
  existing="$(_box_find_file "$tmp" "$idx" "$remote")" || rc=$?
  case "$rc" in
    0) ;;
    1) existing="" ;;
    *) return "$rc" ;;
  esac
  rc=0
  if (( size >= ${BOX_CHUNK_THRESHOLD:-52428800} )); then
    _box_upload_chunked "$tmp" "$idx" "$local_path" "$remote" "$existing" "$size" || rc=$?
  else
    _box_upload_simple "$tmp" "$idx" "$local_path" "$remote" "$existing" || rc=$?
  fi
  return "$rc"
}

# Upload a file. An existing file with the same name gets a new version.
provider_upload_file() {
  _box_with_tmp _box_upload "$1" "$2" "$3"
}

_box_download() {
  local tmp="$1" idx="$2" remote="$3" dest="$4" id rc=0 loc
  id="$(_box_find_file "$tmp" "$idx" "$remote")" || rc=$?
  (( rc == 0 )) || return "$rc"
  # Request without -L. Curl can resend a custom Authorization header on a
  # redirect, so we read the Location header and fetch it without the token.
  BOX_OK_CODES="301 302 303 307 308 404" box_request "$idx" GET "${BOX_API}/files/${id}/content" \
    "$tmp/body" -D "$tmp/hdr" || { rc=$?; return "$rc"; }
  case "$BOX_LAST_CODE" in
    404) return 1 ;;
    2??)
      # Box sent the data directly.
      mv -f -- "$tmp/body" "$dest" || return 2
      return 0
      ;;
  esac
  loc="$(tr -d '\r' <"$tmp/hdr" | sed -n 's/^[Ll]ocation:[[:space:]]*//p' | tail -n 1)"
  if [[ -z "$loc" ]]; then
    log_error "Box account #${idx}: the download redirect has no Location header."
    return 2
  fi
  rc=0
  box_request none GET "$loc" "$dest" -L || rc=$?
  if (( rc != 0 )); then
    rm -f -- "$dest"
    return "$rc"
  fi
  return 0
}

# Download a file to <dest_path>. Return 0 ok, 1 not found, 2+ error.
provider_download_file() {
  _box_with_tmp _box_download "$1" "$2" "$3"
}

_box_delete() {
  local tmp="$1" idx="$2" remote="$3" id rc=0
  id="$(_box_find_file "$tmp" "$idx" "$remote")" || rc=$?
  (( rc == 0 )) || return "$rc"
  box_request "$idx" DELETE "${BOX_API}/files/${id}" "$tmp/body" || rc=$?
  return "$rc"
}

# Delete a file by name. Return 0 deleted, 1 not found, 2+ error.
provider_delete_file() {
  _box_with_tmp _box_delete "$1" "$2"
}
