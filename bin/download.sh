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
        # upload.sh makes exactly N parts (0 to N-1). An index of N or higher
        # is not valid. Stop at once: a loop up to a very large index would
        # not end. Do not ignore the part, because an inactive account also
        # causes this.
        if ((idx >= N)); then
            die "Archive '$ARCHIVE': file '$name' in account #$i has part index $idx, but only $N active accounts exist. Make sure that all accounts that hold parts are active, or remove this file."
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
# Each index is below N, so the loop is short. Write at most 20 indices.
MISSING=""
MISSING_COUNT=0
for ((k = 0; k <= MAX; k++)); do
    if [[ -z "${SOURCE[$k]:-}" ]]; then
        MISSING_COUNT=$((MISSING_COUNT + 1))
        ((MISSING_COUNT <= 20)) && MISSING+="${MISSING:+, }$k"
    fi
done
if ((MISSING_COUNT > 0)); then
    die "Archive '$ARCHIVE' is incomplete; $MISSING_COUNT missing part indices: $MISSING"
fi

# Step 4: download all parts into the temp dir.
declare -a FILES=()
for k in "${INDICES[@]}"; do
    pname="$(part_name "$ARCHIVE" "$k")"
    if ! provider_download_file "${SOURCE[$k]}" "$pname" "$TMP/$pname"; then
        die "Download of part $k ('$pname') from account #${SOURCE[$k]} failed"
    fi
    # Optional limit for the size of one part.
    if [[ -n "${MPARCHIVE_PART_MAX_BYTES:-}" ]]; then
        [[ "$MPARCHIVE_PART_MAX_BYTES" =~ ^[0-9]+$ ]] || die "MPARCHIVE_PART_MAX_BYTES must be an integer"
        psize="$(file_size "$TMP/$pname")" || die "Cannot read the size of part $k"
        # 10#: a value such as "08" is decimal, not octal.
        ((psize <= 10#$MPARCHIVE_PART_MAX_BYTES)) \
            || die "Part $k ('$pname') has $psize bytes; the limit is $MPARCHIVE_PART_MAX_BYTES. Nothing is restored."
    fi
    FILES+=("$TMP/$pname")
done

# Step 5: join the parts in numeric order and check the members.
# The parts come from remote storage, so the archive is not trusted.
JOINED="$TMP/archive.tar.gz"
cat -- "${FILES[@]}" >"$JOINED" || die "Cannot join the parts"

# Compare the parts with the manifest that upload.sh wrote on this host.
rc=0
manifest_verify "$ARCHIVE" "$JOINED" "${FILES[@]}" || rc=$?
if ((rc == 3)); then
    if [[ "${MPARCHIVE_REQUIRE_MANIFEST:-0}" == "1" ]]; then
        die "No manifest for '$ARCHIVE' in '$(manifest_path "$ARCHIVE")'. MPARCHIVE_REQUIRE_MANIFEST=1, so nothing is restored."
    fi
    log_error "Warning: no manifest for '$ARCHIVE' on this host. The parts cannot be verified."
elif ((rc != 0)); then
    die "Archive '$ARCHIVE' does not match its manifest. Nothing is restored."
fi

tar -tzf "$JOINED" >"$TMP/names" 2>/dev/null || die "Extraction failed: cannot read the archive '$ARCHIVE'. Nothing is restored."
tar -tvzf "$JOINED" >"$TMP/verbose" 2>/dev/null || die "Extraction failed: cannot read the archive '$ARCHIVE'. Nothing is restored."
TOP="$(archive_check_members "$TMP/names" "$TMP/verbose")" \
    || die "Archive '$ARCHIVE' has unsafe members. Nothing is restored."

# Step 6: extract into a new empty staging folder, then move the entry.
# The extraction never writes through an entry that is already in the
# target directory, for example a symbolic link from an earlier restore.
# Check the space before extraction. A small archive can expand to a very
# large size or to very many files. The target can be absent, so measure
# the nearest folder that exists. Create the target only after the checks.
PROBE="$TARGET"
while [[ ! -e "$PROBE" ]]; do
    PROBE="$(dirname -- "$PROBE")"
done
INODES="$(archive_inode_bound "$TMP/names")" || die "Cannot count the archive members"
BLOCK="$(stat -f -c %S -- "$PROBE")" || die "Cannot read the block size of '$PROBE'"
AVAIL="$(df -P -B1 -- "$PROBE" | awk 'NR == 2 { print $4 }')"
IAVAIL="$(df -P -i -- "$PROBE" | awk 'NR == 2 { print $4 }')"
[[ "$BLOCK" =~ ^[0-9]+$ && "$AVAIL" =~ ^[0-9]+$ ]] || die "Cannot read the free space of '$PROBE'"
MAX_BYTES="${MPARCHIVE_RESTORE_MAX_BYTES:-$AVAIL}"
[[ "$MAX_BYTES" =~ ^[0-9]+$ ]] || die "MPARCHIVE_RESTORE_MAX_BYTES must be an integer"
# 10#: a value such as "08" is decimal, not octal. An octal error must not
# replace the cap with the free space.
MAX_BYTES=$((10#$MAX_BYTES))
AVAIL=$((10#$AVAIL))
BLOCK=$((10#$BLOCK))
((MAX_BYTES <= AVAIL)) || MAX_BYTES="$AVAIL"
STREAM="$(archive_stream_bytes "$JOINED" "$MAX_BYTES")" \
    || die "Extraction failed: cannot read the archive '$ARCHIVE'. Nothing is restored."
# Each new inode can use one block more than its data in the stream.
NEED=$((STREAM + INODES * BLOCK))
if ((NEED > MAX_BYTES)); then
    die "Archive '$ARCHIVE' can need more than $MAX_BYTES bytes (free: $AVAIL). Nothing is restored."
fi
if [[ "$IAVAIL" =~ ^[0-9]+$ ]] && ((10#$IAVAIL > 0 && INODES >= 10#$IAVAIL)); then
    die "Archive '$ARCHIVE' can create $INODES files and folders; only $IAVAIL are free. Nothing is restored."
fi
if [[ -n "${MPARCHIVE_RESTORE_MAX_INODES:-}" ]]; then
    [[ "$MPARCHIVE_RESTORE_MAX_INODES" =~ ^[0-9]+$ ]] || die "MPARCHIVE_RESTORE_MAX_INODES must be an integer"
    ((INODES <= 10#$MPARCHIVE_RESTORE_MAX_INODES)) \
        || die "Archive '$ARCHIVE' can create $INODES files and folders; the limit is $MPARCHIVE_RESTORE_MAX_INODES. Nothing is restored."
fi

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
