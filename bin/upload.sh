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

# Ask each account for the free space. Check all accounts before a decision.
declare -a FREE=()
SHORT=0
for ((i = 0; i < N; i++)); do
    if ! FREE[i]="$(provider_get_free_space "$i")"; then
        die "Cannot get the free space of account #$i"
    fi
    if [[ ! "${FREE[i]}" =~ ^[0-9]+$ ]]; then
        die "Account #$i returned an invalid free space value"
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

# Step 4: split in exactly N parts, then rename each chunk to the part name.
# Keep the joined archive until the manifest is written in step 6.
WIDTH="${#N}"
if ! split -n "$N" -d -a "$WIDTH" "$TMP/archive.tar.gz" "$TMP/chunk."; then
    die "Cannot split the archive"
fi
declare -a PARTS=()
for ((i = 0; i < N; i++)); do
    chunk="$(printf '%s/chunk.%0*d' "$TMP" "$WIDTH" "$i")"
    PARTS[i]="$TMP/$(part_name "$ARCHIVE" "$i")"
    if [[ -f "$chunk" ]]; then
        mv -- "$chunk" "${PARTS[i]}"
    else
        # Split can skip empty parts. Make an empty file for the part.
        : > "${PARTS[i]}"
    fi
done

# Step 5: second safety check on the real part sizes.
TOTAL_BYTES=0
declare -a SIZES=()
for ((i = 0; i < N; i++)); do
    SIZES[i]="$(file_size "${PARTS[i]}")"
    TOTAL_BYTES=$((TOTAL_BYTES + SIZES[i]))
    if ((SIZES[i] > FREE[i])); then
        die "Part $i is ${SIZES[i]} bytes but account #$i has ${FREE[i]} bytes free; upload cancelled"
    fi
done

# Step 6: upload part i to account i.
for ((i = 0; i < N; i++)); do
    if ! provider_upload_file "$i" "${PARTS[i]}" "$(part_name "$ARCHIVE" "$i")"; then
        die "Upload of part $i to account #$i failed"
    fi
    log_info "Uploaded part $i ($(part_name "$ARCHIVE" "$i"), ${SIZES[i]} bytes) to account #$i"
done

# Write the manifest only after all parts are uploaded. download.sh uses it
# to find parts that were changed in remote storage.
if manifest_write "$ARCHIVE" "$TMP/archive.tar.gz" "${PARTS[@]}"; then
    log_info "Wrote the manifest '$(manifest_path "$ARCHIVE")'"
else
    log_error "Warning: cannot write the manifest of '$ARCHIVE'. A restore cannot verify the parts."
fi
rm -f -- "$TMP/archive.tar.gz"

# Step 7: remove old parts with another index. This step never changes the exit code.
for ((j = 0; j < N; j++)); do
    if ! LISTING="$(provider_list_files "$j" "$ARCHIVE")"; then
        log_error "Warning: cannot list old parts of '$ARCHIVE' in account #$j"
        continue
    fi
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name="${line#*$'\t'}"
        idx=""
        if ! idx="$(part_index_from_name "$ARCHIVE" "$name")"; then
            continue
        fi
        if ((idx != j)); then
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
echo "Total bytes: $TOTAL_BYTES"
exit 0
