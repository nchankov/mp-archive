#!/usr/bin/env bash
# Sandbox helpers for the mp-archive test suite.
# Source this file. Do not execute it.
#
# A sandbox is a temp folder with its own config, logs, storage and tmp.
# The sandbox never uses the real .env, box.json, tokens, error.log or activity.log.
# The real files are in /etc/mp-archive, /var/lib/mp-archive and /var/log/mp-archive.

# Absolute path of the project root. This file lives in tests/lib/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# Print the JSON text for N mock accounts to stdout.
# Each account is an object with "name" and "token" keys.
# Args: <count>
make_accounts_json() {
    local count="${1:-}" i
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "make_accounts_json: count must be a non-negative integer" >&2
        return 2
    fi
    printf '{\n  "accounts": [\n'
    for (( i = 0; i < count; i++ )); do
        # Write a comma before every account except the first.
        if (( i > 0 )); then
            printf ',\n'
        fi
        printf '    {\n      "name": "acct%d",\n      "token": "fake%d"\n    }' "$i" "$i"
    done
    printf '\n  ]\n}\n'
}

# Create a sandbox and export the paths that the code under test reads.
# Unset PROVIDER and BOX_FOLDER_ID first, so real .env values never leak in.
# Args: [account count, default 2]
setup_sandbox() {
    local count="${1:-2}" var

    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "setup_sandbox: account count must be a non-negative integer" >&2
        return 2
    fi

    # Remove values that could come from the real .env.
    unset PROVIDER BOX_FOLDER_ID
    # Remove mock settings from earlier tests.
    while IFS= read -r var; do
        unset "$var"
    done < <(compgen -v MOCK_)

    SANDBOX_DIR="$(mktemp -d)" || return 1
    mkdir -p "$SANDBOX_DIR/config" "$SANDBOX_DIR/logs" "$SANDBOX_DIR/state" \
        "$SANDBOX_DIR/storage" "$SANDBOX_DIR/tmp" || return 1

    # Write the mock configuration into the sandbox config folder.
    printf 'PROVIDER=mock\n' > "$SANDBOX_DIR/config/.env" || return 1
    make_accounts_json "$count" > "$SANDBOX_DIR/config/mock.json" || return 1

    # Point every path variable at the sandbox.
    export MPARCHIVE_CONFIG_DIR="$SANDBOX_DIR/config"
    export MPARCHIVE_LOG_DIR="$SANDBOX_DIR/logs"
    export MPARCHIVE_STATE_DIR="$SANDBOX_DIR/state"
    export MPARCHIVE_PROVIDER_DIR="$REPO_ROOT/tests/mocks/providers"
    export MPARCHIVE_TMPDIR="$SANDBOX_DIR/tmp"
    export MOCK_STORAGE_DIR="$SANDBOX_DIR/storage"
    export REPO_ROOT
}

# Remove the sandbox and unset the sandbox variables.
# Delete only folders that mktemp created (name starts with "tmp.").
teardown_sandbox() {
    local var
    if [[ -n "${SANDBOX_DIR:-}" && -d "$SANDBOX_DIR" ]] \
        && [[ "$(basename "$SANDBOX_DIR")" == tmp.* ]] \
        && [[ "$SANDBOX_DIR" != "$REPO_ROOT" ]]; then
        rm -rf -- "$SANDBOX_DIR"
    fi
    unset SANDBOX_DIR MPARCHIVE_CONFIG_DIR MPARCHIVE_LOG_DIR MPARCHIVE_STATE_DIR \
        MPARCHIVE_PROVIDER_DIR MPARCHIVE_TMPDIR
    while IFS= read -r var; do
        unset "$var"
    done < <(compgen -v MOCK_)
}
