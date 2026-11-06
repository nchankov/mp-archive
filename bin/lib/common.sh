#!/usr/bin/env bash
# common.sh - core library for mp-archive.
# Source this file. Do not run it.
# This file does not call "set" and does not call "exit" (only "die" exits).
# Allowed tools: bash, coreutils, sed, awk, grep, curl, tar, gzip.
#
# ---------------------------------------------------------------------
# PROVIDER INTERFACE
# ---------------------------------------------------------------------
# A provider module is the file bin/lib/providers/<name>.sh.
# Account index "idx" is 0-based into the array MPA_ACCOUNTS.
# The provider reads its own keys from "${MPA_ACCOUNTS[idx]}"
# with json_get_string.
#
#   provider_init                      (optional) Validate settings.
#                                      Return non-zero on error.
#   provider_get_free_space <idx>      Print free bytes (integer).
#   provider_list_files <idx> <archive>
#                                      Print "<file_id><TAB><file_name>"
#                                      for each file whose name starts with
#                                      "<archive>.p" and ends with ".tar.gz".
#                                      Empty output means no file.
#                                      Callers filter with
#                                      part_index_from_name.
#   provider_find_file <idx> <remote_name>
#                                      Print the file id.
#                                      Return 0 found, 1 not found,
#                                      2 or more on error.
#   provider_upload_file <idx> <local_path> <remote_name>
#                                      Upload the file. Overwrite the file
#                                      when the name exists (new version).
#   provider_download_file <idx> <remote_name> <dest_path>
#                                      Return 0 ok, 1 not found,
#                                      2 or more on error.
#   provider_delete_file <idx> <remote_name>
#                                      Return 0 deleted, 1 not found,
#                                      2 or more on error.
#
# Return code 3 from any function means "authentication failed".
# A provider must not call "exit". A provider runs inside command
# substitution. A provider calls log_error and returns.
#
# Script exit codes: 0 success, 1 operation error, 2 usage error.
# exists.sh: 0 true, 1 false, 2 error.
# ---------------------------------------------------------------------

# Save the directory of this file when the shell sources it.
_MPA_COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Global arrays and counters for the loaded accounts.
MPA_ACCOUNTS=()
MPA_ACCOUNT_COUNT=0

# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------

# Print the time stamp for a log line.
_mpa_timestamp() {
    date +%Y-%m-%dT%H:%M:%S
}

# Write one log line. Arguments: level, message, then target files.
# The function never fails. A missing log directory is not an error.
_mpa_log() {
    local level="$1" msg="$2" line script dir
    shift 2
    script="${MPA_SCRIPT_NAME:-$(basename -- "$0")}"
    dir="${MPARCHIVE_LOG_DIR:-}"
    line="$(_mpa_timestamp) [${level}] [${script}] ${msg}"
    local f
    # Before the paths are set, write to stderr only.
    # This stops log files in the current directory.
    if [[ -n "$dir" ]]; then
        for f in "$@"; do
            # The group hides the error of the redirect too, for example a missing folder.
            { printf '%s\n' "$line" >>"${dir}/${f}"; } 2>/dev/null || true
        done
    fi
    printf '%s\n' "$line" >&2
    return 0
}

# Log an information message to activity.log and stderr.
log_info() {
    _mpa_log INFO "${1-}" activity.log
}

# Log an error message to error.log, activity.log, and stderr.
log_error() {
    _mpa_log ERROR "${1-}" error.log activity.log
}

# Log the message and stop the script.
# The exit code is argument 2, else MPA_DIE_CODE, else 1.
die() {
    log_error "${1-fatal error}"
    exit "${2:-${MPA_DIE_CODE:-1}}"
}

# ---------------------------------------------------------------------
# Environment file
# ---------------------------------------------------------------------

# Read KEY=VALUE lines from a file. The function never evaluates the file.
# Rules:
#   - Skip blank lines and lines that start with "#".
#   - Accept only keys that match ^[A-Z_][A-Z0-9_]*$.
#   - Remove one pair of matching quotes around the value.
#   - Keep a variable that the environment already sets.
#   - Export each accepted value.
load_env_file() {
    local file="${1-}" line key value
    if [[ -z "$file" || ! -r "$file" ]]; then
        log_error "Cannot read env file: ${file}"
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove a carriage return from the end of the line.
        line="${line%$'\r'}"
        # Remove white space at the start and the end.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
        # Accept an optional "export " prefix.
        if [[ "$line" == export[[:space:]]* ]]; then
            line="${line#export}"
            line="${line#"${line%%[![:space:]]*}"}"
        fi
        # A valid line must contain "=".
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        # Remove white space around the key and the value.
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        # Reject unsafe key names.
        [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        # Remove one pair of matching quotes.
        if [[ ${#value} -ge 2 ]]; then
            if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]] ||
                [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
                value="${value:1:${#value}-2}"
            fi
        fi
        # Do not override a variable that is already set.
        [[ -v "$key" ]] && continue
        printf -v "$key" '%s' "$value"
        export "${key?}"
    done <"$file"
    return 0
}

# ---------------------------------------------------------------------
# JSON helpers (no external JSON parser)
# ---------------------------------------------------------------------

# Read stdin. Delete newline, carriage return, and tab. Print one line.
json_compact() {
    tr -d '\n\r\t'
    printf '\n'
}

# Print the first string value of "key": "value".
# Assumption: values do not contain escaped quotes.
# Assumption: the key is a plain name (letters, digits, "_", "-", ".").
# Return 1 when the key is absent.
json_get_string() {
    local json="${1-}" key="${2-}"
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    local re="\"${key//./\\.}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\""
    if [[ "$json" =~ $re ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Print the first integer value of "key": 123 (optional minus sign).
# Return 1 when the key is absent.
json_get_number() {
    local json="${1-}" key="${2-}"
    [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    local re="\"${key//./\\.}\"[[:space:]]*:[[:space:]]*(-?[0-9]+)"
    if [[ "$json" =~ $re ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Escape backslash and double quote for use inside a JSON string.
json_escape() {
    local s="${1-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s\n' "$s"
}

# ---------------------------------------------------------------------
# JSON writers for the account file (no external JSON parser)
# ---------------------------------------------------------------------
# These functions change the "accounts" array and keep all other bytes
# of the file as they are. Assumption: the account objects are flat.
# The account index is the index in MPA_ACCOUNTS. An account with
# "active": false has no index.

# Print a JSON string field: "key": "value". The value is escaped.
# Usage: json_string_field <key> <value>
json_string_field() {
    printf '"%s": "%s"\n' "${1-}" "$(json_escape "${2-}")"
}

# Find the objects of the "accounts" array in a text.
# Result: _JS_OPEN (position after "["), _JS_CLOSE (position of "]"),
# and the arrays _JS_START, _JS_END, _JS_ACTIVE (one entry per object).
# The scan knows strings, so a brace inside a string does not count.
# Return 1 when the array is absent or not closed.
_json_scan_accounts() {
    local LC_ALL=C content="${1-}" m prefix i n c start depth instr esc obj
    local start_re='"accounts"[[:space:]]*:[[:space:]]*\['
    local active_re='"active"[[:space:]]*:[[:space:]]*false'
    _JS_START=()
    _JS_END=()
    _JS_ACTIVE=()
    _JS_OPEN=-1
    _JS_CLOSE=-1
    [[ "$content" =~ $start_re ]] || return 1
    m="${BASH_REMATCH[0]}"
    prefix="${content%%"$m"*}"
    i=$((${#prefix} + ${#m}))
    _JS_OPEN=$i
    n=${#content}
    while ((i < n)); do
        c="${content:i:1}"
        case "$c" in
            "{")
                start=$i
                depth=0
                instr=0
                esc=0
                for ((; i < n; i++)); do
                    c="${content:i:1}"
                    if ((instr)); then
                        if ((esc)); then
                            esc=0
                        elif [[ "$c" == "\\" ]]; then
                            esc=1
                        elif [[ "$c" == '"' ]]; then
                            instr=0
                        fi
                        continue
                    fi
                    case "$c" in
                        '"') instr=1 ;;
                        "{") depth=$((depth + 1)) ;;
                        "}")
                            depth=$((depth - 1))
                            ((depth == 0)) && break
                            ;;
                    esac
                done
                ((i < n)) || return 1
                obj="${content:start:i-start+1}"
                _JS_START+=("$start")
                _JS_END+=("$i")
                if [[ "$obj" =~ $active_re ]]; then
                    _JS_ACTIVE+=(0)
                else
                    _JS_ACTIVE+=(1)
                fi
                i=$((i + 1))
                ;;
            "]")
                _JS_CLOSE=$i
                return 0
                ;;
            *) i=$((i + 1)) ;;
        esac
    done
    return 1
}

# Take the lock directory <dir>. Wait for the lock of another process.
# The rules are the same as for the Box token lock:
# wait 60 s (MPA_LOCK_WAIT), remove a lock older than 120 s (MPA_LOCK_STALE),
# poll each second (MPA_LOCK_SLEEP). The BOX_LOCK_* values are the defaults.
_mpa_lock_acquire() {
    local lock="${1-}" waited=0 fails=0 mtime now
    local max="${MPA_LOCK_WAIT:-${BOX_LOCK_WAIT:-60}}"
    local stale="${MPA_LOCK_STALE:-${BOX_LOCK_STALE:-120}}"
    while :; do
        if (umask 077; mkdir -- "$lock") 2>/dev/null; then
            return 0
        fi
        if [[ ! -d "$lock" ]]; then
            fails=$((fails + 1))
            if ((fails > 5)); then
                log_error "Cannot create the lock directory: ${lock}"
                return 1
            fi
            continue
        fi
        mtime="$(stat -c %Y -- "$lock" 2>/dev/null)" || mtime=""
        now="$(date +%s)"
        if [[ "$mtime" =~ ^[0-9]+$ ]] && ((now - mtime > stale)); then
            log_info "Remove a stale lock: ${lock}"
            rmdir -- "$lock" 2>/dev/null || true
            continue
        fi
        if ((waited >= max)); then
            log_error "The lock is busy for ${max} seconds: ${lock}"
            return 1
        fi
        sleep "${MPA_LOCK_SLEEP:-${BOX_LOCK_SLEEP:-1}}"
        waited=$((waited + 1))
    done
}

# Release the lock directory <dir>.
_mpa_lock_release() {
    rmdir -- "${1-}" 2>/dev/null || true
}

# Read the account file under a lock, change the text, and write it again.
# Usage: _json_rewrite <file> <transform function> [args...]
# The transform function reads _JW_OLD (the text, empty when the file is
# absent) and _JW_EXISTS (1 or 0). It sets _JW_NEW and returns 0 on success.
# The new file is a temp file in the same folder (mode 600).
# The temp file must load with config_load_accounts before it replaces the file.
# The lock directory is "<folder>/.<file name>.lock".
# Return 0 on success, 1 on any error. The old file stays on an error.
_json_rewrite() {
    local file="${1-}" fn="${2-}" dir base lock tmp rc=0 count
    shift 2
    local -a saved=()
    [[ -n "$file" && -n "$fn" ]] || return 1
    dir="$(dirname -- "$file")"
    base="$(basename -- "$file")"
    lock="${dir}/.${base}.lock"
    if [[ ! -d "$dir" ]]; then
        log_error "The folder of the account file does not exist: ${dir}"
        return 1
    fi
    _mpa_lock_acquire "$lock" || return 1
    _JW_OLD=""
    _JW_NEW=""
    _JW_EXISTS=0
    if [[ -e "$file" ]]; then
        _JW_EXISTS=1
        # The added "x" keeps the last newline of the file.
        if ! _JW_OLD="$(cat -- "$file"; printf x)"; then
            log_error "Cannot read the account file: ${file}"
            _mpa_lock_release "$lock"
            return 1
        fi
        _JW_OLD="${_JW_OLD%x}"
    fi
    "$fn" "$@" || rc=$?
    if ((rc == 0)); then
        tmp="$(umask 077; mktemp -- "${dir}/.${base}.XXXXXX")" || rc=1
    fi
    if ((rc == 0)); then
        if ! { printf '%s' "$_JW_NEW" >"$tmp" && chmod 600 -- "$tmp"; }; then
            log_error "Cannot write the temporary account file."
            rc=1
        fi
    fi
    if ((rc == 0)); then
        # The check replaces the global account list. Keep a copy of it.
        saved=("${MPA_ACCOUNTS[@]}")
        count="$MPA_ACCOUNT_COUNT"
        MPA_ALLOW_NO_ACCOUNTS=0 config_load_accounts "$tmp" || rc=1
        MPA_ACCOUNTS=("${saved[@]}")
        MPA_ACCOUNT_COUNT="$count"
        ((rc == 0)) || log_error "The changed account file is not valid. The old file stays."
    fi
    if ((rc == 0)); then
        mv -f -- "$tmp" "$file" || {
            log_error "Cannot replace the account file: ${file}"
            rc=1
        }
    fi
    if ((rc != 0)) && [[ -n "${tmp:-}" ]]; then
        rm -f -- "$tmp"
    fi
    _mpa_lock_release "$lock"
    _JW_OLD=""
    _JW_NEW=""
    return "$rc"
}

# Transform: add a new object at the end of the "accounts" array.
_json_do_append() {
    local LC_ALL=C obj="${1-}" old="$_JW_OLD" n s e pre sep tail
    if ((_JW_EXISTS == 0)); then
        _JW_NEW="$(printf '{\n  "accounts": [\n    %s\n  ]\n}\n' "$obj"; printf x)"
        _JW_NEW="${_JW_NEW%x}"
        return 0
    fi
    if ! _json_scan_accounts "$old"; then
        log_error "No usable \"accounts\" array in the account file."
        return 1
    fi
    n="${#_JS_START[@]}"
    if ((n == 0)); then
        # An empty array. Put the object after the "[".
        tail="${old:_JS_OPEN}"
        sep=$'\n'"    "
        if [[ "${tail:0:1}" == "]" ]]; then
            _JW_NEW="${old:0:_JS_OPEN}${sep}${obj}"$'\n'"  ${tail}"
        else
            _JW_NEW="${old:0:_JS_OPEN}${sep}${obj}${tail}"
        fi
        return 0
    fi
    s="${_JS_START[n-1]}"
    e="${_JS_END[n-1]}"
    # Use the indentation of the last object when it starts on its own line.
    pre="${old:0:s}"
    sep=""
    if [[ "$pre" == *$'\n'* ]]; then
        pre="${pre##*$'\n'}"
        [[ "$pre" =~ ^[[:space:]]*$ ]] && sep=$'\n'"$pre"
    fi
    _JW_NEW="${old:0:e+1},${sep}${obj}${old:e+1}"
}

# Add one object at the end of the "accounts" array of a file.
# Usage: json_accounts_append <file> <object>
# <object> is a JSON object text. Build the values with json_string_field.
# A missing file is created with mode 600.
# Return 0 on success, 1 on any error.
json_accounts_append() {
    local obj="${2-}"
    if [[ ! "$obj" =~ ^\{.*\}$ ]]; then
        log_error "The new account is not a JSON object."
        return 1
    fi
    _json_rewrite "${1-}" _json_do_append "$obj"
}

# Transform: add fields to the Nth active account object.
_json_do_fields() {
    local LC_ALL=C idx="${1-}" frag="${2-}" old="$_JW_OLD" k=0 i s e j c
    if ((_JW_EXISTS == 0)) || ! _json_scan_accounts "$old"; then
        log_error "No usable \"accounts\" array in the account file."
        return 1
    fi
    for ((i = 0; i < ${#_JS_START[@]}; i++)); do
        ((_JS_ACTIVE[i] == 1)) || continue
        if ((k == idx)); then
            s="${_JS_START[i]}"
            e="${_JS_END[i]}"
            # Find the last character that is not white space, before the "}".
            j=$((e - 1))
            while ((j > s)); do
                c="${old:j:1}"
                [[ "$c" == [[:space:]] ]] || break
                j=$((j - 1))
            done
            if ((j == s)); then
                _JW_NEW="${old:0:s+1}${frag}${old:s+1}"
            else
                _JW_NEW="${old:0:j+1}, ${frag}${old:j+1}"
            fi
            return 0
        fi
        k=$((k + 1))
    done
    log_error "Account #${idx} is not in the account file."
    return 1
}

# Add fields to the Nth active account object (same index as MPA_ACCOUNTS).
# Usage: json_account_add_fields <file> <index> <fields_fragment>
# <fields_fragment> is text such as '"user_id": "1", "login": "a@b.c"'.
# Build the values with json_string_field. The function adds ", " before it.
# Return 0 on success, 1 on any error.
json_account_add_fields() {
    local idx="${2-}" frag="${3-}"
    if [[ ! "$idx" =~ ^[0-9]+$ || -z "$frag" ]]; then
        log_error "json_account_add_fields: bad index or empty fields."
        return 1
    fi
    _json_rewrite "${1-}" _json_do_fields "$((10#$idx))" "$frag"
}

# ---------------------------------------------------------------------
# Account configuration
# ---------------------------------------------------------------------

# Load the accounts from the top-level "accounts" array of a JSON file.
# Result: global array MPA_ACCOUNTS and number MPA_ACCOUNT_COUNT.
# Each element is one compact JSON object string.
# Assumption: account objects are flat (no nested objects or arrays).
# Assumption: string values contain no "{", "}" or escaped quotes.
# An account with "active": false is skipped.
# Return 1 (and log an error) on a missing, unreadable, or bad file,
# or when no active account exists.
# Option: when MPA_ALLOW_NO_ACCOUNTS=1, a missing file and a file with zero
# active accounts are not errors. The result is an empty list and count 0.
# A file that is not valid still returns 1. The default is unchanged.
config_load_accounts() {
    local file="${1-}" content rest obj
    MPA_ACCOUNTS=()
    MPA_ACCOUNT_COUNT=0
    if [[ "${MPA_ALLOW_NO_ACCOUNTS:-}" == "1" && -n "$file" && ! -e "$file" ]]; then
        return 0
    fi
    if [[ -z "$file" || ! -f "$file" || ! -r "$file" ]]; then
        log_error "Account file is missing or not readable: ${file}"
        return 1
    fi
    if ! content="$(json_compact <"$file")"; then
        log_error "Cannot read account file: ${file}"
        return 1
    fi
    local start_re='"accounts"[[:space:]]*:[[:space:]]*\['
    if [[ ! "$content" =~ $start_re ]]; then
        log_error "No \"accounts\" array in file: ${file}"
        return 1
    fi
    # Keep only the text after the "[" of the accounts array.
    rest="${content#*"${BASH_REMATCH[0]}"}"
    local obj_re='^[[:space:],]*\{([^{}]*)\}(.*)$'
    local end_re='^[[:space:]]*\]'
    while [[ "$rest" =~ $obj_re ]]; do
        obj="{${BASH_REMATCH[1]}}"
        rest="${BASH_REMATCH[2]}"
        # Skip an account that the user marks as not active.
        local active_re='"active"[[:space:]]*:[[:space:]]*false'
        if [[ "$obj" =~ $active_re ]]; then
            continue
        fi
        MPA_ACCOUNTS+=("$obj")
    done
    # The array must end with "]" after the last object.
    rest="${rest#"${rest%%[![:space:],]*}"}"
    if [[ ! "$rest" =~ $end_re ]]; then
        MPA_ACCOUNTS=()
        log_error "Malformed accounts array in file: ${file}"
        return 1
    fi
    MPA_ACCOUNT_COUNT="${#MPA_ACCOUNTS[@]}"
    if ((MPA_ACCOUNT_COUNT == 0)); then
        if [[ "${MPA_ALLOW_NO_ACCOUNTS:-}" == "1" ]]; then
            return 0
        fi
        log_error "No active account in file: ${file}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------

# Default folders. The code folder never holds configuration, tokens or logs.
MPA_DEFAULT_CONFIG_DIR="/etc/mp-archive"
MPA_DEFAULT_LOG_DIR="/var/log/mp-archive"
MPA_DEFAULT_STATE_DIR="/var/lib/mp-archive"

# Set the paths and load .env. The function does not load the accounts.
# Priority of a value: the environment, then .env, then the default.
# The config folder cannot come from .env, because .env is in this folder.
# The function selects the config folder in this sequence:
#   1. MPARCHIVE_CONFIG_DIR from the environment. No fallback.
#   2. /etc/mp-archive, if /etc/mp-archive/.env exists.
#   3. The project folder, if <project folder>/.env exists.
#   4. /etc/mp-archive. mpa_init then shows that no .env exists.
# Return 1 when .env cannot be read or a path is not absolute.
# The usage handlers call this function, so that their errors reach error.log.
mpa_setup_paths() {
    local rc=0
    : "${MPARCHIVE_ROOT:=$(cd -- "${_MPA_COMMON_DIR}/../.." && pwd)}"
    MPA_CONFIG_FALLBACK=0
    if [[ -z "${MPARCHIVE_CONFIG_DIR:-}" ]]; then
        MPA_CONFIG_FALLBACK=1
        # Use the project folder only when the system folder has no .env.
        # Check for the file, not for read access. Thus, a .env that the
        # user cannot read gives an error, not a silent change of file.
        if [[ ! -f "${MPA_DEFAULT_CONFIG_DIR}/.env" && -f "${MPARCHIVE_ROOT}/.env" ]]; then
            MPARCHIVE_CONFIG_DIR="$MPARCHIVE_ROOT"
        else
            MPARCHIVE_CONFIG_DIR="$MPA_DEFAULT_CONFIG_DIR"
        fi
    fi
    : "${MPARCHIVE_PROVIDER_DIR:=$MPARCHIVE_ROOT/bin/lib/providers}"
    : "${MPA_SCRIPT_NAME:=$(basename -- "$0")}"
    export MPARCHIVE_ROOT MPARCHIVE_CONFIG_DIR MPARCHIVE_PROVIDER_DIR MPA_SCRIPT_NAME

    MPA_ENV_FILE="${MPARCHIVE_CONFIG_DIR}/.env"
    # Check the config folder before the load. A relative path must not
    # load a .env from the current directory.
    if [[ "$MPARCHIVE_CONFIG_DIR" != /* ]]; then
        log_error "MPARCHIVE_CONFIG_DIR must be an absolute path (now: ${MPARCHIVE_CONFIG_DIR})."
        return 1
    fi
    if [[ -f "$MPA_ENV_FILE" ]]; then
        load_env_file "$MPA_ENV_FILE" || rc=1
    fi

    # Set the defaults after .env, so that .env can change these folders.
    : "${MPARCHIVE_LOG_DIR:=$MPA_DEFAULT_LOG_DIR}"
    : "${MPARCHIVE_STATE_DIR:=$MPA_DEFAULT_STATE_DIR}"
    : "${MPARCHIVE_TMPDIR:=${TMPDIR:-/tmp}}"
    export MPARCHIVE_LOG_DIR MPARCHIVE_STATE_DIR MPARCHIVE_TMPDIR

    # A relative path depends on the current directory, for example in cron.
    # Reject it. Do not write to a log file that has a relative path.
    if [[ "$MPARCHIVE_LOG_DIR" != /* ]]; then
        local bad="$MPARCHIVE_LOG_DIR"
        MPARCHIVE_LOG_DIR=""
        log_error "MPARCHIVE_LOG_DIR must be an absolute path (now: ${bad})."
        return 1
    fi
    if [[ "$MPARCHIVE_STATE_DIR" != /* ]]; then
        log_error "MPARCHIVE_STATE_DIR must be an absolute path (now: ${MPARCHIVE_STATE_DIR})."
        rc=1
    fi

    if ! mkdir -p -- "$MPARCHIVE_LOG_DIR" 2>/dev/null; then
        local bad="$MPARCHIVE_LOG_DIR"
        # Write the next messages to stderr only.
        MPARCHIVE_LOG_DIR=""
        log_error "Cannot create log directory: ${bad}. Create it and give the user who runs mp-archive write access."
        MPARCHIVE_LOG_DIR="$bad"
    fi
    [[ "$rc" -eq 0 ]] || log_error "Cannot load the settings from ${MPA_ENV_FILE}"
    return "$rc"
}

# Set the paths, load .env and accounts, and load the provider module.
mpa_init() {
    mpa_setup_paths || die "The settings are not valid. Read the errors above."

    if [[ -z "${PROVIDER:-}" ]]; then
        if [[ ! -f "$MPA_ENV_FILE" ]]; then
            if [[ "${MPA_CONFIG_FALLBACK:-0}" == "1" ]]; then
                die "PROVIDER is not set. Settings file not found: ${MPA_DEFAULT_CONFIG_DIR}/.env or ${MPARCHIVE_ROOT}/.env. Copy .env.example to one of these paths and write your values."
            fi
            die "PROVIDER is not set. Settings file not found: ${MPA_ENV_FILE}. Copy .env.example to this path and write your values."
        fi
        die "PROVIDER is not set. Set PROVIDER in ${MPA_ENV_FILE}."
    fi
    if [[ ! "$PROVIDER" =~ ^[a-z0-9_]+$ ]]; then
        die "PROVIDER has an invalid value. Use only a-z, 0-9 and _."
    fi

    config_load_accounts "${MPARCHIVE_CONFIG_DIR}/${PROVIDER}.json" ||
        die "Cannot load accounts for provider: ${PROVIDER}"

    local provider_file="${MPARCHIVE_PROVIDER_DIR}/${PROVIDER}.sh"
    if [[ ! -f "$provider_file" ]]; then
        die "Provider module not found: ${provider_file}"
    fi
    # shellcheck source=/dev/null
    source "$provider_file" || die "Cannot load provider module: ${provider_file}"

    if declare -F provider_init >/dev/null; then
        provider_init || die "Provider initialization failed: ${PROVIDER}"
    fi
    return 0
}

# ---------------------------------------------------------------------
# Archive names and part names
# ---------------------------------------------------------------------

# Return 0 only for a safe archive name.
validate_archive_name() {
    local name="${1-}"
    [[ -n "$name" ]] || return 1
    [[ "$name" != *"/"* ]] || return 1
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# Print the file name of one part.
part_name() {
    printf '%s.p%s.tar.gz\n' "${1-}" "${2-}"
}

# Print the part index when the file name is "<archive>.p<digits>.tar.gz".
# Return 1 for any other name. The function uses string operations,
# so dots in the archive name stay literal.
part_index_from_name() {
    local archive="${1-}" filename="${2-}" rest digits
    local prefix="${archive}.p" suffix=".tar.gz"
    [[ -n "$archive" && "$filename" == "$prefix"* ]] || return 1
    rest="${filename#"$prefix"}"
    [[ "$rest" == *"$suffix" ]] || return 1
    digits="${rest%"$suffix"}"
    [[ "$digits" =~ ^[0-9]+$ ]] || return 1
    # Reject a number that is too long for Bash integer math.
    ((${#digits} <= 9)) || return 1
    printf '%d\n' "$((10#$digits))"
}

# ---------------------------------------------------------------------
# Size and file helpers
# ---------------------------------------------------------------------

# Print the total size in bytes of a file or a directory tree.
path_total_size() {
    local path="${1-}" out size
    [[ -n "$path" && -e "$path" ]] || return 1
    out="$(du -sb -- "$path")" || return 1
    size="${out%%[[:space:]]*}"
    [[ "$size" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$size"
}

# Print the size in bytes of a file.
file_size() {
    stat -c %s -- "${1-}"
}

# Print the integer ceiling of a divided by b.
ceil_div() {
    local a="${1-}" b="${2-}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || return 1
    ((10#$b > 0)) || return 1
    printf '%d\n' "$(((10#$a + 10#$b - 1) / 10#$b))"
}

# Create a temporary directory and print its path.
make_tmpdir() {
    local base="${MPARCHIVE_TMPDIR:-${TMPDIR:-/tmp}}"
    mkdir -p -- "$base" || return 1
    mktemp -d "${base}/mp-archive.XXXXXX"
}

# Read integers from stdin. Print unique values in numeric order.
sort_indices() {
    sort -n -u
}

# ---------------------------------------------------------------------
# Archive member checks (restore)
# ---------------------------------------------------------------------

# Remove a "./" prefix and one "/" suffix from a member name.
_member_norm() {
    local n="${1-}"
    while [[ "$n" == ./* ]]; do n="${n#./}"; done
    printf '%s' "${n%/}"
}

# Check the member list of an archive before extraction.
# Arguments: a file with the output of "tar -tzf" and a file with the
# output of "tar -tvzf" for the same archive. Line i of each file is member i.
# The archive comes from remote storage, so it is not trusted.
# The function rejects:
#   - an empty archive, or listings with a different count of lines
#   - absolute names and names with a ".." part
#   - more than one top-level entry
#   - a member whose path goes through a symbolic link member
#   - a hard link to an absolute path, a ".." path, or another top-level entry
# A symbolic link member itself is accepted. Its target is not followed
# during the restore, because no later member can go through it.
# On success, print the top-level name and return 0.
# On failure, log the reason and return 1.
archive_check_members() {
    local names_file="${1-}" verbose_file="${2-}"
    local -a names=() lines=()
    local -A links=()
    local i n raw vline type target top="" part path
    mapfile -t names <"$names_file" || return 1
    mapfile -t lines <"$verbose_file" || return 1
    if ((${#names[@]} == 0)); then
        log_error "The archive is empty"
        return 1
    fi
    if ((${#names[@]} != ${#lines[@]})); then
        log_error "The archive listing is not consistent (a member name can contain a line break)"
        return 1
    fi
    # Pass 1: check each name and find the link members.
    for ((i = 0; i < ${#names[@]}; i++)); do
        raw="${names[i]}"
        n="$(_member_norm "$raw")"
        if [[ -z "$n" || "$n" == /* || "/$n/" == */../* ]]; then
            log_error "Unsafe member name in the archive: '$raw'"
            return 1
        fi
        if [[ -z "$top" ]]; then
            top="${n%%/*}"
        elif [[ "${n%%/*}" != "$top" ]]; then
            log_error "The archive has more than one top-level entry: '$top' and '${n%%/*}'"
            return 1
        fi
        vline="${lines[i]}"
        type="${vline:0:1}"
        target=""
        if [[ "$vline" == *" $raw -> "* ]]; then
            target="${vline#*" $raw -> "}"
        elif [[ "$vline" == *" $raw link to "* ]]; then
            target="${vline#*" $raw link to "}"
            type="h"
        fi
        if [[ "$type" == "l" ]]; then
            # A symbolic link. Record it. Pass 2 rejects members below it.
            links["$n"]=1
        elif [[ -n "$target" ]]; then
            # A hard link (BusyBox shows it with "->" and type "-").
            target="$(_member_norm "$target")"
            if [[ -z "$target" || "$target" == /* || "/$target/" == */../* \
                || "${target%%/*}" != "$top" ]]; then
                log_error "Unsafe hard link in the archive: '$raw' -> '$target'"
                return 1
            fi
        fi
    done
    # Pass 2: reject a member that goes through a symbolic link member.
    # Example: the link "top/cfg" and the member "top/cfg/.env".
    for raw in "${names[@]}"; do
        n="$(_member_norm "$raw")"
        path=""
        while [[ "$n" == */* ]]; do
            part="${n%%/*}"
            n="${n#*/}"
            path="${path:+$path/}$part"
            if [[ -n "${links[$path]+set}" ]]; then
                log_error "A member goes through the symbolic link '$path' in the archive: '$raw'"
                return 1
            fi
        done
    done
    printf '%s\n' "$top"
}
