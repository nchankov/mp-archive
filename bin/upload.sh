#!/usr/bin/env bash
# upload.sh - Archive a path, split the archive in N parts, upload part i to account i.
# Usage: upload.sh <path_to_content> <archive_name>
set -euo pipefail

# Find the library with an absolute path.
MPA_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MPA_SCRIPT_NAME="upload.sh"
# shellcheck source=lib/common.sh
source "$MPA_BIN_DIR/lib/common.sh"

# Print the usage message, log it, and stop with code 2.
usage_error() {
    echo "Usage: upload.sh <path_to_content> <archive_name>" >&2
    # Read the log folder from the settings. Do not load the accounts.
    mpa_setup_paths >/dev/null 2>&1 || true
    log_error "Usage error: $1"
    exit 2
}

if [[ $# -ne 2 ]]; then
    usage_error "expected 2 arguments, got $#"
fi
CONTENT_PATH="$1"
ARCHIVE="$2"
if ! validate_archive_name "$ARCHIVE"; then
    usage_error "invalid archive name '$ARCHIVE'"
fi
if [[ ! -e "$CONTENT_PATH" ]]; then
    usage_error "path '$CONTENT_PATH' does not exist"
fi

mpa_init
# Use a low CPU priority and a low disk priority for tar, gzip and curl.
mpa_lower_priority || die "The priority settings are not valid. Read the errors above."
N="$MPA_ACCOUNT_COUNT"

# Resolve the absolute path. This handles trailing slashes and relative paths.
if [[ -d "$CONTENT_PATH" ]]; then
    FULL_PATH="$(cd "$CONTENT_PATH" && pwd -P)"
else
    FULL_PATH="$(cd "$(dirname -- "$CONTENT_PATH")" && pwd -P)/$(basename -- "$CONTENT_PATH")"
fi
if [[ "$FULL_PATH" == "/" ]]; then
    usage_error "the root directory is not a valid content path"
fi
PARENT_DIR="$(dirname -- "$FULL_PATH")"
BASE_NAME="$(basename -- "$FULL_PATH")"

# Step 1: pre-check. Compute the part size from the uncompressed size.
TOTAL="$(path_total_size "$FULL_PATH")" || die "Cannot read the size of '$CONTENT_PATH'"
PART_SIZE="$(ceil_div "$TOTAL" "$N")"

# Optional limit for the size of one file in remote storage.
# Allow leading zeros, then at most 18 digits, so the value fits in Bash math.
CHUNK_CAP=0
if [[ -n "${MPARCHIVE_CHUNK_MAX_BYTES:-}" ]]; then
    if [[ ! "$MPARCHIVE_CHUNK_MAX_BYTES" =~ ^0*([0-9]{1,18})$ ]] || ((10#${BASH_REMATCH[1]} < 1)); then
        die "MPARCHIVE_CHUNK_MAX_BYTES must be an integer of 1 or more (now: $MPARCHIVE_CHUNK_MAX_BYTES)"
    fi
    CHUNK_CAP=$((10#${BASH_REMATCH[1]}))
fi

# Ask each account for the free space and for the largest file size.
# Check all accounts before a decision.
# LIMIT[i] = the largest chunk for account i. 0 means no limit.
declare -a FREE=() LIMIT=()
SHORT=0
for ((i = 0; i < N; i++)); do
    if ! FREE[i]="$(provider_get_free_space "$i")"; then
        die "Cannot get the free space of account #$i"
    fi
    if [[ ! "${FREE[i]}" =~ ^[0-9]+$ ]]; then
        die "Account #$i returned an invalid free space value"
    fi
    LIMIT[i]="$CHUNK_CAP"
    if declare -F provider_get_max_file_size >/dev/null; then
        if ! max_file="$(provider_get_max_file_size "$i")"; then
            die "Cannot get the largest file size of account #$i"
        fi
        if [[ -n "$max_file" ]]; then
            [[ "$max_file" =~ ^[0-9]{1,18}$ ]] || die "Account #$i returned an invalid largest file size"
            max_file=$((10#$max_file))
            if ((max_file > 0 && (LIMIT[i] == 0 || max_file < LIMIT[i]))); then
                LIMIT[i]="$max_file"
            fi
        fi
    fi
    if ((FREE[i] < PART_SIZE)); then
        log_error "Account #$i has ${FREE[i]} bytes free; part size $PART_SIZE bytes is required"
        SHORT=1
    fi
done
if ((SHORT)); then
    die "Upload of '$ARCHIVE' cancelled: not enough free space"
fi

# Step 2: make a temp dir. Remove it when the script ends.
TMP="$(make_tmpdir)" || die "Cannot create a temporary directory"
cleanup() {
    [[ -n "${TMP:-}" && -d "$TMP" ]] && rm -rf -- "$TMP"
}
trap cleanup EXIT

# Step 3: make the archive. The archive keeps only the base name of the content.
if ! tar -C "$PARENT_DIR" -czf "$TMP/archive.tar.gz" -- "$BASE_NAME"; then
    die "Cannot create the archive of '$CONTENT_PATH'"
fi

# Step 4: split the archive in exactly N parts. Part k is for account k.
# Cut part k in chunks of at most LIMIT[k] bytes. Each part has at least
# one chunk, also an empty part. Keep the joined archive until the manifest
# is written in step 6.
ARCHIVE_FILE="$TMP/archive.tar.gz"
ARCHIVE_BYTES="$(file_size "$ARCHIVE_FILE")" || die "Cannot read the size of the archive"
PART_BYTES="$(ceil_div "$ARCHIVE_BYTES" "$N")"
declare -a SIZES=() CHUNKS=() CHUNK_FILES=()
for ((k = 0; k < N; k++)); do
    start=$((k * PART_BYTES))
    len=$((ARCHIVE_BYTES - start))
    ((len > PART_BYTES)) && len="$PART_BYTES"
    ((len < 0)) && len=0
    SIZES[k]="$len"
    step="${LIMIT[k]}"
    ((step == 0 || step > len)) && step="$len"
    if ((len == 0)); then
        count=1
    else
        count="$(ceil_div "$len" "$step")"
    fi
    if ((count > MPA_MAX_CHUNKS)); then
        die "Part $k needs $count files of at most ${LIMIT[k]} bytes; the maximum is $MPA_MAX_CHUNKS. Use a larger MPARCHIVE_CHUNK_MAX_BYTES or more accounts."
    fi
    CHUNKS[k]="$count"
    for ((j = 0; j < count; j++)); do
        off=$((start + j * step))
        clen=$((len - j * step))
        ((clen > step)) && clen="$step"
        cfile="$TMP/$(chunk_name "$ARCHIVE" "$k" "$j")"
        # tail reads from the offset (it does not read the bytes before it).
        # head stops tail after clen bytes. Code 141 (SIGPIPE) of tail is normal.
        if ! (set -o pipefail; { tail -c "+$((off + 1))" -- "$ARCHIVE_FILE" || [[ $? -eq 141 ]]; } | head -c "$clen" >"$cfile"); then
            die "Cannot cut chunk $j of part $k"
        fi
        [[ "$(file_size "$cfile")" == "$clen" ]] || die "Chunk $j of part $k has a wrong size"
        CHUNK_FILES+=("$cfile")
    done
done

# Step 5: second safety check on the real part sizes.
TOTAL_BYTES=0
for ((k = 0; k < N; k++)); do
    TOTAL_BYTES=$((TOTAL_BYTES + SIZES[k]))
    if ((SIZES[k] > FREE[k])); then
        die "Part $k is ${SIZES[k]} bytes but account #$k has ${FREE[k]} bytes free; upload cancelled"
    fi
done

# Step 6: upload the chunks of part k to account k.
for cfile in "${CHUNK_FILES[@]}"; do
    cname="${cfile##*/}"
    read -r k j _ <<<"$(part_parse_name "$ARCHIVE" "$cname")"
    if ! provider_upload_file "$k" "$cfile" "$cname"; then
        die "Upload of part $k, chunk $j ('$cname') to account #$k failed"
    fi
    log_info "Uploaded part $k, chunk $((j + 1)) of ${CHUNKS[k]} ($cname, $(file_size "$cfile") bytes) to account #$k"
done

# Write the manifest only after all chunks are uploaded. download.sh uses it
# to find files that were changed in remote storage.
if manifest_write "$ARCHIVE" "$ARCHIVE_FILE" "${CHUNK_FILES[@]}"; then
    log_info "Wrote the manifest '$(manifest_path "$ARCHIVE")'"
else
    log_error "Warning: cannot write the manifest of '$ARCHIVE'. A restore cannot verify the parts."
fi
rm -f -- "$ARCHIVE_FILE"

# Step 7: remove the files of this archive that the new upload did not write:
# files in the old format, files of another part, and chunks with a higher
# index. This step never changes the exit code.
for ((j = 0; j < N; j++)); do
    if ! LISTING="$(provider_list_files "$j" "$ARCHIVE")"; then
        log_error "Warning: cannot list old parts of '$ARCHIVE' in account #$j"
        continue
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line#*$'\t'}"
        parsed=""
        if ! parsed="$(part_parse_name "$ARCHIVE" "$name")"; then
            continue
        fi
        read -r pk pj pformat <<<"$parsed"
        if [[ "$pformat" != "c" ]] || ((pk != j || pj >= CHUNKS[j])); then
            if provider_delete_file "$j" "$name"; then
                log_info "Removed old part '$name' from account #$j"
            else
                log_error "Warning: cannot remove old part '$name' from account #$j"
            fi
        fi
    done <<< "$LISTING"
done

# Step 8: print the summary.
echo "Archive: $ARCHIVE"
echo "Parts: $N"
echo "Files: ${#CHUNK_FILES[@]}"
echo "Total bytes: $TOTAL_BYTES"
exit 0
