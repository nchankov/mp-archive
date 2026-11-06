#!/usr/bin/env bash
# download.sh - Find the parts of an archive in all accounts, download, join, and extract.
# Usage: download.sh <archive_name> <path_to_directory>
set -euo pipefail

# Find the library with an absolute path.
MPA_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPA_SCRIPT_NAME="download.sh"
# shellcheck source=lib/common.sh
source "$MPA_BIN_DIR/lib/common.sh"

# Print the usage message, log it, and stop with code 2.
usage_error() {
    echo "Usage: download.sh <archive_name> <path_to_directory>" >&2
    # Read the log folder from the settings. Do not load the accounts.
    mpa_setup_paths >/dev/null 2>&1 || true
    log_error "Usage error: $1"
    exit 2
}

if [[ $# -ne 2 ]]; then
    usage_error "expected 2 arguments, got $#"
fi
ARCHIVE="$1"
TARGET="$2"
if ! validate_archive_name "$ARCHIVE"; then
    usage_error "invalid archive name '$ARCHIVE'"
fi
if [[ -z "$TARGET" ]]; then
    usage_error "the target directory is empty"
fi

mpa_init
N="$MPA_ACCOUNT_COUNT"

# Make a temp dir. Remove it when the script ends.
TMP="$(make_tmpdir)" || die "Cannot create a temporary directory"
cleanup() {
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

# Step 1: list the parts in each account. SOURCE[k] = account that holds part k.
declare -A SOURCE=()
for ((i = 0; i < N; i++)); do
    if ! LISTING="$(provider_list_files "$i" "$ARCHIVE")"; then
        die "Cannot list the files of account #$i"
    fi
    FOUND=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line#*$'\t'}"
        if ! idx="$(part_index_from_name "$ARCHIVE" "$name")"; then
            continue
        fi
        FOUND=1
        # Prefer account k for part k. Else keep the first account that has it.
        if [[ -z "${SOURCE[$idx]:-}" ]] || ((idx == i)); then
            SOURCE[$idx]="$i"
        fi
    done <<< "$LISTING"
    if ((FOUND == 0)); then
        log_info "Account #$i has no parts of '$ARCHIVE'; skip it"
    fi
done

# Step 2: stop if no part exists.
if ((${#SOURCE[@]} == 0)); then
    die "Archive '$ARCHIVE' not found in any account"
fi

# Step 3: sort the indices in numeric order and check for gaps.
mapfile -t INDICES < <(printf '%s\n' "${!SOURCE[@]}" | sort_indices)
MAX="${INDICES[${#INDICES[@]} - 1]}"
MISSING=""
for ((k = 0; k <= MAX; k++)); do
    if [[ -z "${SOURCE[$k]:-}" ]]; then
        MISSING+="${MISSING:+, }$k"
    fi
done
if [[ -n "$MISSING" ]]; then
    die "Archive '$ARCHIVE' is incomplete; missing part indices: $MISSING"
fi

# Step 4: download all parts into the temp dir.
declare -a FILES=()
for k in "${INDICES[@]}"; do
    pname="$(part_name "$ARCHIVE" "$k")"
    if ! provider_download_file "${SOURCE[$k]}" "$pname" "$TMP/$pname"; then
        die "Download of part $k ('$pname') from account #${SOURCE[$k]} failed"
    fi
    FILES+=("$TMP/$pname")
done

# Step 5: join the parts in numeric order and extract.
mkdir -p -- "$TARGET" || die "Cannot create the target directory '$TARGET'"
if ! cat -- "${FILES[@]}" | tar -xzf - -C "$TARGET"; then
    die "Extraction failed"
fi

log_info "Restored '$ARCHIVE' (${#FILES[@]} parts) to '$TARGET'"
echo "$TARGET"
exit 0
