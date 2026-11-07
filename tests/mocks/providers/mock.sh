#!/usr/bin/env bash
# Mock storage provider for offline tests.
# Source this file. Do not execute it. It must not call exit.
#
# Storage layout: one folder per account, "$MOCK_STORAGE_DIR/acct<idx>".
# File id = file name.
#
# Environment:
#   MOCK_STORAGE_DIR         root folder for all accounts (required)
#   MOCK_FREE_SPACE_<idx>    free bytes for one account
#   MOCK_FREE_SPACE_DEFAULT  free bytes for other accounts
#                            (default 10000000000)
#   MOCK_MAX_FILE_<idx>      largest file size in bytes for one account.
#   MOCK_MAX_FILE_DEFAULT    largest file size for other accounts.
#                            Empty means no limit. An upload of a larger file
#                            fails with code 2, like the Box error 403.
#   MOCK_FAIL_<OP>_<idx>     when set and not empty, the call returns this code.
#                            OP is FREE, MAXFILE, LIST, FIND, UPLOAD, DOWNLOAD
#                            or DELETE.
#                            Invalid codes become 2.
#
# Every call appends "<OP> <idx> <name>" to "$MOCK_STORAGE_DIR/calls.log".
# The name is "-" for FREE and MAXFILE.

# Check the call and record it. Apply failure injection.
# Return 0 to continue. Return a non-zero code to stop the call.
# Args: <OP> <idx> <name>
_mock_enter() {
    local op="$1" idx="$2" name="$3" var code

    # Check the account index.
    if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
        log_error "mock: invalid account index: $idx"
        return 2
    fi

    # Check the storage root.
    if [[ -z "${MOCK_STORAGE_DIR:-}" ]]; then
        log_error "mock: MOCK_STORAGE_DIR is not set"
        return 2
    fi
    mkdir -p -- "$MOCK_STORAGE_DIR" || {
        log_error "mock: cannot create $MOCK_STORAGE_DIR"
        return 2
    }

    # Record the call before any failure is injected.
    printf '%s %s %s\n' "$op" "$idx" "$name" >> "$MOCK_STORAGE_DIR/calls.log" || {
        log_error "mock: cannot write calls.log"
        return 2
    }

    # Apply failure injection for this operation and account.
    var="MOCK_FAIL_${op}_${idx}"
    code="${!var:-}"
    if [[ -n "$code" ]]; then
        # Accept only codes from 1 to 255. Use base 10 for leading zeros.
        if [[ ! "$code" =~ ^[0-9]+$ ]] || (( 10#$code < 1 || 10#$code > 255 )); then
            code=2
        fi
        log_error "mock: injected $op failure on account $idx (code $code)"
        return "$((10#$code))"
    fi
    return 0
}

# Fail when a file name is empty or contains a slash.
# Args: <name>
_mock_check_name() {
    case "$1" in
        ""|.|..|*/*)
            log_error "mock: invalid file name: $1"
            return 2
            ;;
    esac
    return 0
}

# Print the folder of one account. Do not create it.
# Args: <idx>
_mock_acct_dir() {
    printf '%s/acct%s' "$MOCK_STORAGE_DIR" "$1"
}

# Check the storage root and create it when needed.
provider_init() {
    if [[ -z "${MOCK_STORAGE_DIR:-}" ]]; then
        log_error "mock: MOCK_STORAGE_DIR is not set"
        return 1
    fi
    mkdir -p -- "$MOCK_STORAGE_DIR" || {
        log_error "mock: cannot create $MOCK_STORAGE_DIR"
        return 1
    }
    return 0
}

# Print the free bytes for one account.
# Args: <idx>
provider_get_free_space() {
    local idx="$1" var value
    _mock_enter FREE "$idx" "-" || return $?

    # Use the account value first, then the default, then 10 GB.
    var="MOCK_FREE_SPACE_${idx}"
    value="${!var:-}"
    if [[ -z "$value" ]]; then
        value="${MOCK_FREE_SPACE_DEFAULT:-}"
    fi
    if [[ -z "$value" ]]; then
        value=10000000000
    fi
    printf '%s\n' "$value"
    return 0
}

# Print the largest file size of one account value (empty = no limit).
# Args: <idx>
_mock_max_file() {
    local var="MOCK_MAX_FILE_${1}"
    printf '%s' "${!var:-${MOCK_MAX_FILE_DEFAULT:-}}"
}

# Print the largest file size for one account. Empty output means no limit.
# Args: <idx>
provider_get_max_file_size() {
    local idx="$1"
    _mock_enter MAXFILE "$idx" "-" || return $?
    _mock_max_file "$idx"
    printf '\n'
    return 0
}

# Print "<id><TAB><name>" for each matching file in one account folder.
# Match names that start with "<archive>.p" and end with ".tar.gz".
# Args: <idx> <archive>
provider_list_files() {
    local idx="$1" archive="$2" dir path name nullglob_before
    _mock_enter LIST "$idx" "$archive" || return $?
    _mock_check_name "$archive" || return 2

    # A missing account folder means no files.
    dir="$(_mock_acct_dir "$idx")"
    if [[ ! -d "$dir" ]]; then
        return 0
    fi

    # Use nullglob so an empty folder gives no output. Restore it after.
    nullglob_before="$(shopt -p nullglob)"
    shopt -s nullglob
    for path in "$dir"/*; do
        name="${path##*/}"
        if [[ "$name" == "$archive".p* && "$name" == *.tar.gz && -f "$path" ]]; then
            printf '%s\t%s\n' "$name" "$name"
        fi
    done
    $nullglob_before
    return 0
}

# Print the file id when the file exists.
# Return 0 when found, 1 when not found.
# Args: <idx> <remote_name>
provider_find_file() {
    local idx="$1" name="$2" dir
    _mock_enter FIND "$idx" "$name" || return $?
    _mock_check_name "$name" || return 2

    dir="$(_mock_acct_dir "$idx")"
    if [[ -f "$dir/$name" ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    return 1
}

# Copy a local file into the account folder. Overwrite an existing file.
# Args: <idx> <local_path> <remote_name>
provider_upload_file() {
    local idx="$1" src="$2" name="$3" dir
    _mock_enter UPLOAD "$idx" "$name" || return $?
    _mock_check_name "$name" || return 2

    if [[ ! -f "$src" ]]; then
        log_error "mock: upload source not found: $src"
        return 2
    fi

    # Refuse a file that is larger than the limit of the account.
    local max
    max="$(_mock_max_file "$idx")"
    if [[ -n "$max" ]] && (( $(stat -c %s -- "$src") > max )); then
        log_error "mock: file_size_limit_exceeded: $name is larger than $max bytes"
        return 2
    fi

    # Create the account folder on demand.
    dir="$(_mock_acct_dir "$idx")"
    mkdir -p -- "$dir" || {
        log_error "mock: cannot create $dir"
        return 2
    }
    if ! cp -f -- "$src" "$dir/$name"; then
        log_error "mock: upload copy failed: $name"
        return 2
    fi
    return 0
}

# Copy a stored file to a local destination.
# Return 0 when copied, 1 when not found.
# Args: <idx> <remote_name> <dest_path>
provider_download_file() {
    local idx="$1" name="$2" dest="$3" dir
    _mock_enter DOWNLOAD "$idx" "$name" || return $?
    _mock_check_name "$name" || return 2

    dir="$(_mock_acct_dir "$idx")"
    if [[ ! -f "$dir/$name" ]]; then
        return 1
    fi
    if ! cp -f -- "$dir/$name" "$dest"; then
        log_error "mock: download copy failed: $name"
        return 2
    fi
    return 0
}

# Remove a stored file.
# Return 0 when deleted, 1 when not found.
# Args: <idx> <remote_name>
provider_delete_file() {
    local idx="$1" name="$2" dir
    _mock_enter DELETE "$idx" "$name" || return $?
    _mock_check_name "$name" || return 2

    dir="$(_mock_acct_dir "$idx")"
    if [[ ! -f "$dir/$name" ]]; then
        return 1
    fi
    if ! rm -f -- "$dir/$name"; then
        log_error "mock: delete failed: $name"
        return 2
    fi
    return 0
}
