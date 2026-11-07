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
# Use a low CPU priority and a low disk priority for tar, gzip and curl.
mpa_lower_priority || die "The priority settings are not valid. Read the errors above."
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

# Step 1: list the files of the archive in each account.
# New format: chunk j of part k ("<archive>.p<k>.c<j>.tar.gz").
#   CSRC["k:j"] = account that holds the chunk. MAXC[k] = highest chunk index.
# Old format: one file for each part ("<archive>.p<k>.tar.gz").
#   PSRC[k] = account that holds the part.
declare -A CSRC=() PSRC=() MAXC=()
for ((i = 0; i < N; i++)); do
    if ! LISTING="$(provider_list_files "$i" "$ARCHIVE")"; then
        die "Cannot list the files of account #$i"
    fi
    FOUND=0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line#*$'\t'}"
        if ! parsed="$(part_parse_name "$ARCHIVE" "$name")"; then
            continue
        fi
        read -r idx cidx format <<<"$parsed"
        # upload.sh makes exactly N parts (0 to N-1). An index of N or higher
        # is not valid. Stop at once: a loop up to a very large index would
        # not end. Do not ignore the file, because an inactive account also
        # causes this.
        if ((idx >= N)); then
            die "Archive '$ARCHIVE': file '$name' in account #$i has part index $idx, but only $N active accounts exist. Make sure that all accounts that hold parts are active, or remove this file."
        fi
        if ((cidx >= MPA_MAX_CHUNKS)); then
            die "Archive '$ARCHIVE': file '$name' in account #$i has chunk index $cidx; the maximum is $((MPA_MAX_CHUNKS - 1))."
        fi
        FOUND=1
        # Prefer account k for part k. Else keep the first account that has it.
        if [[ "$format" == "c" ]]; then
            if [[ -z "${CSRC[$idx:$cidx]:-}" ]] || ((idx == i)); then
                CSRC[$idx:$cidx]="$i"
            fi
            if [[ -z "${MAXC[$idx]:-}" ]] || ((cidx > MAXC[$idx])); then
                MAXC[$idx]="$cidx"
            fi
        else
            if [[ -z "${PSRC[$idx]:-}" ]] || ((idx == i)); then
                PSRC[$idx]="$i"
            fi
        fi
    done <<< "$LISTING"
    if ((FOUND == 0)); then
        log_info "Account #$i has no parts of '$ARCHIVE'; skip it"
    fi
done

# Step 2: select the format. Stop if no file exists.
# A file in the old format can stay after an upload in the new format, when
# the removal of old files failed. The new format is the newer upload.
if ((${#CSRC[@]} > 0)); then
    FORMAT="c"
    if ((${#PSRC[@]} > 0)); then
        log_error "Warning: archive '$ARCHIVE' also has files in the old format. They are not used. Upload the archive again to remove them."
    fi
    mapfile -t INDICES < <(printf '%s\n' "${!MAXC[@]}" | sort_indices)
elif ((${#PSRC[@]} > 0)); then
    FORMAT="p"
    mapfile -t INDICES < <(printf '%s\n' "${!PSRC[@]}" | sort_indices)
else
    die "Archive '$ARCHIVE' not found in any account"
fi

# Step 3: make the list of files in the sequence of the join, and check
# for gaps. Each index has a limit, so the loops are short.
# Write at most 20 missing names.
MAX="${INDICES[${#INDICES[@]} - 1]}"
declare -a ORDER_ACCT=() ORDER_NAME=()
MISSING=""
MISSING_COUNT=0
add_missing() {
    MISSING_COUNT=$((MISSING_COUNT + 1))
    ((MISSING_COUNT <= 20)) && MISSING+="${MISSING:+, }$1"
    return 0
}
for ((k = 0; k <= MAX; k++)); do
    if [[ "$FORMAT" == "p" ]]; then
        if [[ -z "${PSRC[$k]:-}" ]]; then
            add_missing "part $k"
            continue
        fi
        ORDER_ACCT+=("${PSRC[$k]}")
        ORDER_NAME+=("$(part_name "$ARCHIVE" "$k")")
        continue
    fi
    if [[ -z "${MAXC[$k]:-}" ]]; then
        add_missing "part $k"
        continue
    fi
    for ((j = 0; j <= MAXC[$k]; j++)); do
        if [[ -z "${CSRC[$k:$j]:-}" ]]; then
            add_missing "part $k chunk $j"
            continue
        fi
        ORDER_ACCT+=("${CSRC[$k:$j]}")
        ORDER_NAME+=("$(chunk_name "$ARCHIVE" "$k" "$j")")
    done
done
if ((MISSING_COUNT > 0)); then
    die "Archive '$ARCHIVE' is incomplete; $MISSING_COUNT missing files: $MISSING"
fi

# Step 4: download all files into the temp dir.
declare -a FILES=()
for ((n = 0; n < ${#ORDER_NAME[@]}; n++)); do
    pname="${ORDER_NAME[n]}"
    acct="${ORDER_ACCT[n]}"
    if ! provider_download_file "$acct" "$pname" "$TMP/$pname"; then
        die "Download of '$pname' from account #$acct failed"
    fi
    # Optional limit for the size of one downloaded file.
    if [[ -n "${MPARCHIVE_PART_MAX_BYTES:-}" ]]; then
        [[ "$MPARCHIVE_PART_MAX_BYTES" =~ ^[0-9]+$ ]] || die "MPARCHIVE_PART_MAX_BYTES must be an integer"
        psize="$(file_size "$TMP/$pname")" || die "Cannot read the size of '$pname'"
        # 10#: a value such as "08" is decimal, not octal.
        ((psize <= 10#$MPARCHIVE_PART_MAX_BYTES)) \
            || die "File '$pname' has $psize bytes; the limit is $MPARCHIVE_PART_MAX_BYTES. Nothing is restored."
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

log_info "Restored '$ARCHIVE' ($((MAX + 1)) parts, ${#FILES[@]} files) to '$TARGET/$TOP'"
echo "$TARGET"
exit 0
