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
# STAGE is the staging folder of the extraction. It is set in step 5.
TMP="$(make_tmpdir)" || die "Cannot create a temporary directory"
STAGE=""
cleanup() {
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"
    # Remove a staging folder that is left after a failure.
    # rm does not follow the symbolic links in the folder.
    [[ -n "${STAGE:-}" && -d "$STAGE" ]] && rm -rf -- "$STAGE"
    return 0
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

# Step 5: join the parts in numeric order and check the members.
# The parts come from remote storage, so the archive is not trusted.
JOINED="$TMP/archive.tar.gz"
cat -- "${FILES[@]}" >"$JOINED" || die "Cannot join the parts"
tar -tzf "$JOINED" >"$TMP/names" 2>/dev/null || die "Extraction failed: cannot read the archive '$ARCHIVE'. Nothing is restored."
tar -tvzf "$JOINED" >"$TMP/verbose" 2>/dev/null || die "Extraction failed: cannot read the archive '$ARCHIVE'. Nothing is restored."
TOP="$(archive_check_members "$TMP/names" "$TMP/verbose")" \
    || die "Archive '$ARCHIVE' has unsafe members. Nothing is restored."

# Step 6: extract into a new empty staging folder, then move the entry.
# The extraction never writes through an entry that is already in the
# target directory, for example a symbolic link from an earlier restore.
mkdir -p -- "$TARGET" || die "Cannot create the target directory '$TARGET'"
if [[ -e "$TARGET/$TOP" || -L "$TARGET/$TOP" ]]; then
    die "'$TARGET/$TOP' exists. Remove it, or restore into a different directory."
fi
STAGE="$(mktemp -d -- "$TARGET/.mp-archive-restore.XXXXXX")" \
    || die "Cannot create a staging folder in '$TARGET'"
if ! tar -xzf "$JOINED" -C "$STAGE"; then
    die "Extraction failed. Nothing is restored."
fi
# Some tar programs change member names during extraction. Thus make sure
# that the staging folder holds only the top-level entry that was checked.
STAGED="$(ls -A -- "$STAGE")" || die "Cannot read the staging folder"
if [[ "$STAGED" != "$TOP" ]]; then
    die "The extracted content does not match the archive listing. Nothing is restored."
fi
# -n: do not replace an entry that another process made in the meantime.
if ! mv -nT -- "$STAGE/$TOP" "$TARGET/$TOP" || [[ -e "$STAGE/$TOP" || -L "$STAGE/$TOP" ]]; then
    die "Cannot move '$TOP' into '$TARGET'. Nothing is restored."
fi
# The EXIT trap removes the empty staging folder.

log_info "Restored '$ARCHIVE' (${#FILES[@]} parts) to '$TARGET/$TOP'"
echo "$TARGET"
exit 0
