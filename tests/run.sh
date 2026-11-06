#!/usr/bin/env bash
# Run every tests/test_*.sh file, in sorted order.
# Each file runs in its own bash process.
#
# Usage: tests/run.sh [name-filter]
#   name-filter  Only run files whose name contains this text.
#
# Exit 0 when every file passes. Exit 1 on any failure.
# Exit 1 also when no file matches.

set -u

# Sort file names the same way on every system.
export LC_ALL=C

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILTER="${1:-}"

total=0
passed=0
failed=0

for test_file in "$TESTS_DIR"/test_*.sh; do
    # Skip the unmatched pattern when no file exists.
    [[ -f "$test_file" ]] || continue

    name="$(basename "$test_file")"

    # Skip files that do not match the filter.
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        continue
    fi

    total=$((total + 1))
    if output="$(bash "$test_file" 2>&1)"; then
        passed=$((passed + 1))
        printf 'PASS  %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAIL  %s\n' "$name"
        # Show the output of a failing file, indented.
        printf '%s\n' "$output" | sed 's/^/      /'
    fi
done

if (( total == 0 )); then
    printf 'No test files matched: %s\n' "$FILTER" >&2
    exit 1
fi

printf '\nTotal: %d file(s), %d passed, %d failed\n' "$total" "$passed" "$failed"

if (( failed > 0 )); then
    exit 1
fi
exit 0
