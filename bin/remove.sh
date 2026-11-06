#!/usr/bin/env bash
# Delete every part of one archive from all storage accounts.
#
# Usage: remove.sh <archive_name>
#
# Stdout: the number of deleted parts, one line.
# Exit codes: 0 = success (also when nothing was found),
#             1 = operation error (see error.log),
#             2 = usage error.

set -euo pipefail

# Resolve the absolute path of the bin directory of this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the core library by its absolute path.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/common.sh"

# Print the usage line to stderr.
usage() {
  echo "Usage: $(basename "$0") <archive_name>" >&2
}

# Check that exactly one argument is given.
if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

ARCHIVE_NAME="$1"

# Reject archive names that are not safe.
if ! validate_archive_name "$ARCHIVE_NAME"; then
  usage
  echo "Invalid archive name: '$ARCHIVE_NAME'" >&2
  exit 2
fi

# Load settings, accounts and the provider module.
mpa_init

deleted_count=0
failure_count=0

for (( idx = 0; idx < MPA_ACCOUNT_COUNT; idx++ )); do
  # List the files of this archive in account idx.
  if ! listing="$(provider_list_files "$idx" "$ARCHIVE_NAME")"; then
    log_error "Cannot list parts of '$ARCHIVE_NAME' in account #$idx"
    failure_count=$((failure_count + 1))
    continue
  fi

  # Collect the names that are parts of this archive.
  # Collect first, so no provider call runs while the list is read.
  part_names=()
  while IFS= read -r line; do
    # Skip empty lines.
    if [[ -z "$line" ]]; then
      continue
    fi
    # The file name follows the first TAB character.
    file_name="${line#*$'\t'}"
    if part_index_from_name "$ARCHIVE_NAME" "$file_name" >/dev/null; then
      part_names+=("$file_name")
    fi
  done <<< "$listing"

  if [[ ${#part_names[@]} -eq 0 ]]; then
    log_info "No parts of '$ARCHIVE_NAME' in account #$idx"
    continue
  fi

  # Delete each part of this archive.
  for file_name in "${part_names[@]}"; do
    delete_rc=0
    provider_delete_file "$idx" "$file_name" >/dev/null || delete_rc=$?
    case "$delete_rc" in
      0)
        deleted_count=$((deleted_count + 1))
        log_info "Deleted $file_name from account #$idx"
        ;;
      1)
        # Not found means the part is already gone. This is not an error.
        log_info "Part $file_name not found in account #$idx"
        ;;
      *)
        log_error "Cannot delete '$file_name' from account #$idx (rc=$delete_rc)"
        failure_count=$((failure_count + 1))
        ;;
    esac
  done
done

# Report the number of deleted parts on stdout.
echo "$deleted_count"

# Exit 1 when at least one account or part failed.
if [[ $failure_count -gt 0 ]]; then
  exit 1
fi
exit 0
