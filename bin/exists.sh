#!/usr/bin/env bash
# Check whether any part of one archive exists in the storage accounts.
#
# Usage: exists.sh <archive_name>
#
# Stdout: only the word "true" or "false", one line.
# Exit codes: 0 = true (a part exists),
#             1 = false (no part exists),
#             2 = error (provider or usage error, nothing on stdout).
# Errors are written to error.log and to stderr.
# Normal INFO lines are not written to stderr.

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
# Use exit code 2 for an init failure. Exit code 1 means "false" here.
MPA_DIE_CODE=2
mpa_init

for (( idx = 0; idx < MPA_ACCOUNT_COUNT; idx++ )); do
  # List the files of this archive in account idx.
  # A provider error ends the check with exit 2.
  if ! listing="$(provider_list_files "$idx" "$ARCHIVE_NAME")"; then
    log_error "Cannot list parts of '$ARCHIVE_NAME' in account #$idx"
    exit 2
  fi

  # Check each listed file name for an exact part match.
  while IFS= read -r line; do
    # Skip empty lines.
    if [[ -z "$line" ]]; then
      continue
    fi
    # The file name follows the first TAB character.
    file_name="${line#*$'\t'}"
    if part_index_from_name "$ARCHIVE_NAME" "$file_name" >/dev/null; then
      printf 'true\n'
      exit 0
    fi
  done <<< "$listing"
done

# No account holds a part of this archive.
printf 'false\n'
exit 1
