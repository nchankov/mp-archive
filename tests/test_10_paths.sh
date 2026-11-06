#!/usr/bin/env bash
# QA tests for the folder settings (ticket 10).
# Covers bin/lib/common.sh (mpa_setup_paths, mpa_init, _mpa_log),
# bin/upload.sh and bin/download.sh (usage errors), and
# bin/lib/providers/box.sh (_box_state_dir and the mode warnings).
# Each check runs in a new bash process. No check changes the shell of another.
# The system folders /etc/mp-archive, /var/log/mp-archive and /var/lib/mp-archive
# are never created, read or written. The default values are checked with a stub for mkdir.
# Each check uses a sandbox for the project folder (MPARCHIVE_ROOT) and for the
# system config folder (MPA_DEFAULT_CONFIG_DIR). The real repo .env is never read.
# No check may create .state, activity.log or error.log in the repo root.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load the helpers. env.sh sets REPO_ROOT.
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/env.sh"

# Paths of the files under test. They are exported for the child bash processes.
COMMON_SH="$REPO_ROOT/bin/lib/common.sh"
BOX_SH="$REPO_ROOT/bin/lib/providers/box.sh"
UPLOAD_SH="$REPO_ROOT/bin/upload.sh"
DOWNLOAD_SH="$REPO_ROOT/bin/download.sh"
export COMMON_SH BOX_SH UPLOAD_SH DOWNLOAD_SH

# ---------------------------------------------------------------------
# Helpers for this file
# ---------------------------------------------------------------------

# Print the entries of the repo root, sorted. Then print the checksums of the real logs.
# Use this output to show that no check changed the repo root.
_repo_snapshot() {
    local f
    find "$REPO_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort
    for f in "$REPO_ROOT/activity.log" "$REPO_ROOT/error.log"; do
        if [[ -f "$f" ]]; then
            printf '%s %s\n' "$f" "$(cksum < "$f")"
        fi
    done
    return 0
}

# Save the state of the repo root before any check runs.
REPO_SNAPSHOT_BEFORE="$(_repo_snapshot)"

# Print the SHA-256 of the real repo .env, or "absent" when it does not exist.
# The content is never read or printed. Only the checksum is used.
_repo_env_sum() {
    if [[ -f "$REPO_ROOT/.env" ]]; then
        sha256sum -- "$REPO_ROOT/.env" | awk '{ print $1 }'
    else
        printf 'absent\n'
    fi
}

# Save the checksum of the real repo .env before any check runs.
REPO_ENV_SUM_BEFORE="$(_repo_env_sum)"

# Run one check function in a new sandbox. Remove the sandbox after the check.
# The sandbox also has a project folder (MPARCHIVE_ROOT) with no .env in it.
# Args: <account count> <function name>
with_sandbox() {
    local count="$1" fn="$2" rc=0
    teardown_sandbox
    setup_sandbox "$count" || { teardown_sandbox; return 1; }
    mkdir -p -- "$SANDBOX_DIR/project-root" || { teardown_sandbox; return 1; }
    export MPARCHIVE_ROOT="$SANDBOX_DIR/project-root"
    "$fn" || rc=$?
    unset MPARCHIVE_ROOT SYS_CFG PROJ_ROOT
    teardown_sandbox
    return "$rc"
}

# Replace the .env file of the sandbox config folder.
# Args: <line> [line...]
write_env() {
    printf '%s\n' "$@" > "$MPARCHIVE_CONFIG_DIR/.env"
}

# Create the system config folder (stand-in for /etc/mp-archive) in the sandbox.
# The project folder is the sandbox MPARCHIVE_ROOT. Neither folder has a .env yet.
# Exports SYS_CFG and PROJ_ROOT for the child processes.
# Remove MPARCHIVE_CONFIG_DIR, so that the config folder comes from the fallback sequence.
setup_config_folders() {
    SYS_CFG="$SANDBOX_DIR/system-config"
    PROJ_ROOT="$MPARCHIVE_ROOT"
    mkdir -p -- "$SYS_CFG" || return 1
    export SYS_CFG PROJ_ROOT
    unset MPARCHIVE_CONFIG_DIR
}

# Write a .env file into a folder.
# Args: <folder> <line> [line...]
write_env_in() {
    local folder="$1"
    shift
    printf '%s\n' "$@" > "$folder/.env"
}

# Write the mock accounts file into a folder.
# Args: <folder> <account count>
write_accounts_in() {
    make_accounts_json "$2" > "$1/mock.json"
}

# Print the entries that a child process created in its working folder.
# Print nothing when the folder is empty.
cwd_files() {
    find "$SANDBOX_DIR/cwd" -mindepth 1 -printf '%P\n' 2>/dev/null
}

# Print the number of lines in a text. An empty text counts as one line.
# Args: <text>
count_lines() {
    printf '%s\n' "$1" | wc -l | tr -d ' '
}

# Run a bash snippet in a new bash process. The child starts in the folder
# "cwd" of the sandbox, so that a stray file is easy to find.
# The child gets the sandbox variables, except the names given after the snippet.
# Args: <snippet> [variable names to unset in the child...]
# Set RC (exit code), OUT (stdout) and ERR (stderr).
run_snippet() {
    local snippet="$1" name
    local -a unset_args=()
    shift
    for name in "$@"; do
        unset_args+=(-u "$name")
    done
    mkdir -p -- "$SANDBOX_DIR/cwd" || return 1
    RC=0
    ( cd -- "$SANDBOX_DIR/cwd" && env "${unset_args[@]}" bash -c "$snippet" ) \
        >"$SANDBOX_DIR/stdout.txt" 2>"$SANDBOX_DIR/stderr.txt" || RC=$?
    OUT="$(cat -- "$SANDBOX_DIR/stdout.txt")"
    ERR="$(cat -- "$SANDBOX_DIR/stderr.txt")"
}

# Check that a relative path in the environment makes mpa_setup_paths fail.
# Args: <variable name> <relative value>
_check_relative_path_rejected() {
    local var="$1" value="$2"
    export "$var=$value"
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; exit $?'
    assert_eq "1" "$RC" "$var relative: mpa_setup_paths exit code" || return 1
    assert_contains "$ERR" "$var must be an absolute path" "$var relative: message" || return 1
    assert_contains "$ERR" "now: $value" "$var relative: shows the bad value" || return 1
    assert_eq "" "$(cwd_files)" "$var relative: no file in the working folder" || return 1
    assert_file_missing "$SANDBOX_DIR/cwd/$value" "$var relative: no folder made from the value" || return 1
}

# Check that mpa_init stops with the settings error for a relative path.
# Args: <variable name> <relative value>
_check_mpa_init_relative_path() {
    local var="$1" value="$2"
    export "$var=$value"
    run_snippet 'source "$COMMON_SH"; mpa_init; exit $?'
    assert_eq "1" "$RC" "$var relative: mpa_init exit code" || return 1
    assert_contains "$ERR" "The settings are not valid" "$var relative: mpa_init message" || return 1
    assert_contains "$ERR" "$var must be an absolute path" "$var relative: mpa_init reason" || return 1
    assert_eq "" "$(cwd_files)" "$var relative: mpa_init writes no file in the working folder" || return 1
}

# ---------------------------------------------------------------------
# Values from .env and the environment
# ---------------------------------------------------------------------

# Check that MPARCHIVE_LOG_DIR comes from .env when the environment does not set it.
_check_log_dir_from_env_file() {
    local want="$SANDBOX_DIR/dotenv-logs"
    write_env "PROVIDER=mock" "MPARCHIVE_LOG_DIR=$want"
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; rc=$?; printf "%s" "$MPARCHIVE_LOG_DIR"; exit $rc' MPARCHIVE_LOG_DIR
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$want" "$OUT" "LOG_DIR value from .env" || return 1
    assert_file_exists "$want" "LOG_DIR folder from .env is created" || return 1
}

# Check that MPARCHIVE_STATE_DIR comes from .env. mpa_setup_paths must not create it.
_check_state_dir_from_env_file() {
    local want="$SANDBOX_DIR/dotenv-state"
    write_env "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$want"
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; rc=$?; printf "%s" "$MPARCHIVE_STATE_DIR"; exit $rc' MPARCHIVE_STATE_DIR
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$want" "$OUT" "STATE_DIR value from .env" || return 1
    assert_file_missing "$want" "STATE_DIR folder is not created by mpa_setup_paths" || return 1
}

# Check that the environment wins over .env for LOG_DIR and STATE_DIR.
_check_environment_wins_over_env_file() {
    export MPARCHIVE_LOG_DIR="$SANDBOX_DIR/env-logs"
    export MPARCHIVE_STATE_DIR="$SANDBOX_DIR/env-state"
    write_env "PROVIDER=mock" \
        "MPARCHIVE_LOG_DIR=$SANDBOX_DIR/dotenv-logs" \
        "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/dotenv-state"
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; rc=$?; printf "%s|%s" "$MPARCHIVE_LOG_DIR" "$MPARCHIVE_STATE_DIR"; exit $rc'
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$SANDBOX_DIR/env-logs|$SANDBOX_DIR/env-state" "$OUT" "environment values win" || return 1
    assert_file_missing "$SANDBOX_DIR/dotenv-logs" "the .env log folder is not created" || return 1
}

# Check that quotes around a value in .env are removed and spaces are kept.
_check_quoted_values_in_env_file() {
    write_env "PROVIDER=mock" "MPARCHIVE_STATE_DIR=\"$SANDBOX_DIR/quoted state\""
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; rc=$?; printf "%s" "$MPARCHIVE_STATE_DIR"; exit $rc' MPARCHIVE_STATE_DIR
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$SANDBOX_DIR/quoted state" "$OUT" "quotes removed from the .env value" || return 1
}

# ---------------------------------------------------------------------
# Default values
# ---------------------------------------------------------------------

# Check the default values when nothing sets them. The mkdir stub records the call.
# No real folder is created, so the system folders stay as they are.
# The project folder has no .env, and the system config folder is a sandbox folder.
# The child sets MPA_DEFAULT_CONFIG_DIR after it sources common.sh.
_check_defaults_when_nothing_sets_them() {
    setup_config_folders || return 1
    export STUB_FILE="$SANDBOX_DIR/mkdir-calls.txt"
    run_snippet 'mkdir() { printf "%s\n" "$*" >> "$STUB_FILE"; return 0; }
source "$COMMON_SH"
MPA_DEFAULT_CONFIG_DIR="$SYS_CFG"
mpa_setup_paths
rc=$?
printf "%s|%s|%s|%s|%s" "$MPARCHIVE_CONFIG_DIR" "$MPARCHIVE_LOG_DIR" "$MPARCHIVE_STATE_DIR" "$MPA_CONFIG_FALLBACK" "$rc"
exit $rc' MPARCHIVE_CONFIG_DIR MPARCHIVE_LOG_DIR MPARCHIVE_STATE_DIR PROVIDER
    assert_eq "0" "$RC" "setup exit code" || { unset STUB_FILE; return 1; }
    assert_eq "$SYS_CFG|/var/log/mp-archive|/var/lib/mp-archive|1|0" "$OUT" \
        "default CONFIG, LOG and STATE values, and fallback flag" || { unset STUB_FILE; return 1; }
    assert_contains "$(cat -- "$STUB_FILE" 2>/dev/null)" "/var/log/mp-archive" \
        "default LOG folder is the one that mkdir gets" || { unset STUB_FILE; return 1; }
    unset STUB_FILE
}

# Check that STATE_DIR has its default when LOG_DIR is set to a sandbox folder.
# The box module then uses the default token folder.
_check_state_dir_default_with_sandbox_log_dir() {
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths || exit $?; source "$BOX_SH"; printf "%s|%s" "$MPARCHIVE_STATE_DIR" "$(_box_state_dir)"' MPARCHIVE_STATE_DIR
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "/var/lib/mp-archive|/var/lib/mp-archive/box" "$OUT" \
        "STATE_DIR default and box token folder" || return 1
    assert_eq "" "$ERR" "no error output" || return 1
}

# ---------------------------------------------------------------------
# Config folder selection (system folder, then project folder)
# ---------------------------------------------------------------------

# Run mpa_setup_paths in a child with the sandbox system folder as MPA_DEFAULT_CONFIG_DIR.
# Print "<config folder>|<STATE_DIR>|<fallback flag>". Set RC, OUT and ERR.
# The child has no PROVIDER or MPARCHIVE_STATE_DIR from the environment.
# MPARCHIVE_CONFIG_DIR is kept, so an explicit value from the caller reaches the child.
# setup_config_folders removes it for the fallback checks.
_run_select_config() {
    run_snippet 'source "$COMMON_SH"; MPA_DEFAULT_CONFIG_DIR="$SYS_CFG"; mpa_setup_paths; rc=$?; printf "%s|%s|%s" "$MPARCHIVE_CONFIG_DIR" "$MPARCHIVE_STATE_DIR" "$MPA_CONFIG_FALLBACK"; exit $rc' \
        PROVIDER MPARCHIVE_STATE_DIR
}

# Check the fallback: the system folder has no .env, the project folder has one.
# The project folder is used, its .env is loaded, and the fallback flag is 1.
_check_config_fallback_to_project_env() {
    setup_config_folders || return 1
    write_env_in "$PROJ_ROOT" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/proj-state" || return 1
    _run_select_config
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$PROJ_ROOT|$SANDBOX_DIR/proj-state|1" "$OUT" \
        "project folder used, its .env loaded, fallback flag 1" || return 1
    assert_file_missing "$SYS_CFG/.env" "system folder still has no .env" || return 1
}

# Check that the system folder wins when both folders have a .env.
# The project values are not loaded. The fallback flag is still 1, because
# MPARCHIVE_CONFIG_DIR was not set by the environment.
_check_config_system_env_wins() {
    setup_config_folders || return 1
    write_env_in "$SYS_CFG" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/sys-state" || return 1
    write_env_in "$PROJ_ROOT" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/proj-state" || return 1
    _run_select_config
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$SYS_CFG|$SANDBOX_DIR/sys-state|1" "$OUT" \
        "system folder used, project .env not loaded" || return 1
}

# Check that an unreadable system .env (mode 000) gives an error and no fallback.
# The file exists, so the project folder must not be used. The check does not run as root,
# because root can read a mode 000 file. The runner skips this check for root.
_check_config_unreadable_system_env_no_fallback() {
    setup_config_folders || return 1
    write_env_in "$SYS_CFG" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/sys-state" || return 1
    chmod 000 -- "$SYS_CFG/.env" || return 1
    write_env_in "$PROJ_ROOT" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/proj-state" || return 1
    assert_file_exists "$SYS_CFG/.env" "precondition: system .env exists" || return 1
    _run_select_config
    assert_eq "1" "$RC" "mpa_setup_paths returns 1" || return 1
    assert_contains "$ERR" "Cannot load the settings from $SYS_CFG/.env" \
        "error names the unreadable system .env" || return 1
    assert_eq "$SYS_CFG|/var/lib/mp-archive|1" "$OUT" \
        "project .env not loaded, system folder kept" || return 1
}

# Check that an explicit MPARCHIVE_CONFIG_DIR gives no fallback, even with a project .env.
# The explicit folder has no .env, so the STATE_DIR default is used. The flag is 0.
_check_config_explicit_no_fallback() {
    setup_config_folders || return 1
    write_env_in "$PROJ_ROOT" "PROVIDER=mock" "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/proj-state" || return 1
    export MPARCHIVE_CONFIG_DIR="$SANDBOX_DIR/explicit-config"
    _run_select_config
    assert_eq "0" "$RC" "setup exit code" || return 1
    assert_eq "$SANDBOX_DIR/explicit-config|/var/lib/mp-archive|0" "$OUT" \
        "explicit folder used, project .env not loaded, fallback flag 0" || return 1
}

# Check the message of mpa_init when neither folder has a .env and nothing is set.
# The message names both paths.
_check_init_no_env_anywhere_message() {
    setup_config_folders || return 1
    run_snippet 'source "$COMMON_SH"; MPA_DEFAULT_CONFIG_DIR="$SYS_CFG"; mpa_init; exit $?' \
        PROVIDER MPARCHIVE_CONFIG_DIR MPARCHIVE_STATE_DIR
    assert_eq "1" "$RC" "mpa_init exit code" || return 1
    assert_contains "$ERR" "PROVIDER is not set. Settings file not found: $SYS_CFG/.env or $PROJ_ROOT/.env. Copy .env.example to one of these paths and write your values." \
        "message names both paths" || return 1
}

# Check that mpa_init loads the accounts and the provider name from the project folder.
# The project .env sets PROVIDER. The accounts come from <project folder>/mock.json.
_check_init_fallback_loads_project_accounts() {
    setup_config_folders || return 1
    write_env_in "$PROJ_ROOT" "PROVIDER=mock" || return 1
    write_accounts_in "$PROJ_ROOT" 2 || return 1
    run_snippet 'source "$COMMON_SH"; MPA_DEFAULT_CONFIG_DIR="$SYS_CFG"; mpa_init; rc=$?; printf "%s|%s|%s|%s|%s" "$MPARCHIVE_CONFIG_DIR" "$PROVIDER" "$MPA_ACCOUNT_COUNT" "$(json_get_string "${MPA_ACCOUNTS[1]}" name)" "$MPA_CONFIG_FALLBACK"; exit $rc' \
        PROVIDER MPARCHIVE_CONFIG_DIR
    assert_eq "0" "$RC" "mpa_init exit code" || return 1
    assert_eq "$PROJ_ROOT|mock|2|acct1|1" "$OUT" \
        "project folder, provider from .env, two accounts from project mock.json" || return 1
}

# ---------------------------------------------------------------------
# Relative paths and missing settings
# ---------------------------------------------------------------------

# Check that a relative MPARCHIVE_LOG_DIR makes mpa_setup_paths return 1.
_check_relative_log_dir() {
    _check_relative_path_rejected MPARCHIVE_LOG_DIR "relative/logs"
}

# Check that a relative MPARCHIVE_STATE_DIR makes mpa_setup_paths return 1.
_check_relative_state_dir() {
    _check_relative_path_rejected MPARCHIVE_STATE_DIR "relative/state"
}

# Check that a relative MPARCHIVE_CONFIG_DIR makes mpa_setup_paths return 1.
_check_relative_config_dir() {
    _check_relative_path_rejected MPARCHIVE_CONFIG_DIR "relative/config"
}

# Check that mpa_init exits non-zero for a relative MPARCHIVE_LOG_DIR.
_check_mpa_init_relative_log_dir() {
    _check_mpa_init_relative_path MPARCHIVE_LOG_DIR "relative/logs"
}

# Check that mpa_init exits non-zero for a relative MPARCHIVE_STATE_DIR.
_check_mpa_init_relative_state_dir() {
    _check_mpa_init_relative_path MPARCHIVE_STATE_DIR "relative/state"
}

# Check the message when .env is missing and PROVIDER is not set.
_check_missing_env_file_message() {
    rm -f -- "$MPARCHIVE_CONFIG_DIR/.env"
    assert_file_missing "$MPARCHIVE_CONFIG_DIR/.env" "precondition: no .env" || return 1
    run_snippet 'source "$COMMON_SH"; mpa_init; exit $?' PROVIDER
    assert_eq "1" "$RC" "mpa_init exit code" || return 1
    assert_contains "$ERR" "PROVIDER is not set. Settings file not found: $MPARCHIVE_CONFIG_DIR/.env" \
        "missing .env message" || return 1
}

# Check the message when .env exists but PROVIDER is not in it.
_check_env_file_without_provider() {
    write_env "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/state"
    run_snippet 'source "$COMMON_SH"; mpa_init; exit $?' PROVIDER
    assert_eq "1" "$RC" "mpa_init exit code" || return 1
    assert_contains "$ERR" "PROVIDER is not set. Set PROVIDER in $MPARCHIVE_CONFIG_DIR/.env" \
        "message for .env without PROVIDER" || return 1
}

# Check that mpa_init reads the folders from .env and loads the provider.
_check_mpa_init_reads_env_file_paths() {
    write_env "PROVIDER=mock" \
        "MPARCHIVE_LOG_DIR=$SANDBOX_DIR/dotenv-logs" \
        "MPARCHIVE_STATE_DIR=$SANDBOX_DIR/dotenv-state"
    run_snippet 'source "$COMMON_SH"; mpa_init; rc=$?; printf "%s|%s|%s" "$MPARCHIVE_LOG_DIR" "$MPARCHIVE_STATE_DIR" "$MPA_ACCOUNT_COUNT"; exit $rc' MPARCHIVE_LOG_DIR MPARCHIVE_STATE_DIR
    assert_eq "0" "$RC" "mpa_init exit code" || return 1
    assert_eq "$SANDBOX_DIR/dotenv-logs|$SANDBOX_DIR/dotenv-state|1" "$OUT" \
        "paths from .env and one account" || return 1
    assert_file_exists "$SANDBOX_DIR/dotenv-logs" "LOG folder from .env is created" || return 1
}

# ---------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------

# Check that an empty LOG_DIR writes to stderr only, and no file in the working folder.
_check_empty_log_dir_writes_no_file() {
    run_snippet 'source "$COMMON_SH"; MPARCHIVE_LOG_DIR=""; log_error "boom"; log_info "hello"; exit 0'
    assert_eq "0" "$RC" "exit code" || return 1
    assert_contains "$ERR" "[ERROR]" "error line on stderr" || return 1
    assert_contains "$ERR" "boom" "error text on stderr" || return 1
    assert_contains "$ERR" "[INFO]" "info line on stderr" || return 1
    assert_eq "" "$(cwd_files)" "empty LOG_DIR: no file in the working folder" || return 1

    run_snippet 'source "$COMMON_SH"; log_error "boom"; exit 0' MPARCHIVE_LOG_DIR
    assert_eq "0" "$RC" "unset LOG_DIR exit code" || return 1
    assert_contains "$ERR" "boom" "unset LOG_DIR: error text on stderr" || return 1
    assert_eq "" "$(cwd_files)" "unset LOG_DIR: no file in the working folder" || return 1
}

# Check that a LOG_DIR that cannot be created gives one clear error and no shell error.
# mpa_setup_paths stays non-fatal (return 0). The later log line also stays quiet.
_check_uncreatable_log_dir_is_quiet() {
    local blocker="$SANDBOX_DIR/blocker" bad
    printf 'not a folder\n' > "$blocker" || return 1
    bad="$blocker/logs"
    export MPARCHIVE_LOG_DIR="$bad"
    run_snippet 'source "$COMMON_SH"; mpa_setup_paths; rc=$?; log_info "after"; exit $rc'
    assert_eq "0" "$RC" "mpa_setup_paths is not fatal" || return 1
    assert_contains "$ERR" "Cannot create log directory: $bad" "clear error for the folder" || return 1
    assert_not_contains "$ERR" "No such file or directory" "no shell error text (missing)" || return 1
    assert_not_contains "$ERR" "Not a directory" "no shell error text (not a directory)" || return 1
    assert_eq "2" "$(count_lines "$ERR")" "stderr has only the two log lines" || return 1
    assert_eq "" "$(cwd_files)" "no file in the working folder" || return 1
}

# ---------------------------------------------------------------------
# Usage errors of upload.sh and download.sh
# ---------------------------------------------------------------------

# Check that upload.sh writes its usage errors to the log folder of .env.
_check_upload_usage_error_env_log_dir() {
    local env_logs="$SANDBOX_DIR/dotenv-logs"
    write_env "PROVIDER=mock" "MPARCHIVE_LOG_DIR=$env_logs"

    run_snippet 'bash "$UPLOAD_SH" only-one' MPARCHIVE_LOG_DIR
    assert_eq "2" "$RC" "wrong count exit code" || return 1
    assert_contains "$ERR" "Usage: upload.sh" "usage line on stderr" || return 1
    assert_eq "" "$OUT" "no stdout" || return 1
    assert_file_exists "$env_logs/error.log" "error.log in the .env log folder" || return 1
    assert_contains "$(cat -- "$env_logs/error.log")" "Usage error: expected 2 arguments, got 1" \
        "wrong count text in error.log" || return 1

    run_snippet "bash '$UPLOAD_SH' '$SANDBOX_DIR/cwd' 'bad/name'" MPARCHIVE_LOG_DIR
    assert_eq "2" "$RC" "bad archive name exit code" || return 1
    assert_contains "$(cat -- "$env_logs/error.log")" "Usage error: invalid archive name 'bad/name'" \
        "bad archive name text in error.log" || return 1
    assert_eq "" "$(cwd_files)" "no file in the working folder" || return 1
}

# Check that download.sh writes its usage errors to the log folder of .env.
_check_download_usage_error_env_log_dir() {
    local env_logs="$SANDBOX_DIR/dotenv-logs"
    write_env "PROVIDER=mock" "MPARCHIVE_LOG_DIR=$env_logs"

    run_snippet 'bash "$DOWNLOAD_SH" only-one' MPARCHIVE_LOG_DIR
    assert_eq "2" "$RC" "wrong count exit code" || return 1
    assert_contains "$ERR" "Usage: download.sh" "usage line on stderr" || return 1
    assert_file_exists "$env_logs/error.log" "error.log in the .env log folder" || return 1
    assert_contains "$(cat -- "$env_logs/error.log")" "Usage error: expected 2 arguments, got 1" \
        "wrong count text in error.log" || return 1

    run_snippet "bash '$DOWNLOAD_SH' 'bad/name' '$SANDBOX_DIR/cwd'" MPARCHIVE_LOG_DIR
    assert_eq "2" "$RC" "bad archive name exit code" || return 1
    assert_contains "$(cat -- "$env_logs/error.log")" "Usage error: invalid archive name 'bad/name'" \
        "bad archive name text in error.log" || return 1

    run_snippet "bash '$DOWNLOAD_SH' 'good-name' ''" MPARCHIVE_LOG_DIR
    assert_eq "2" "$RC" "empty target exit code" || return 1
    assert_contains "$(cat -- "$env_logs/error.log")" "Usage error: the target directory is empty" \
        "empty target text in error.log" || return 1
    assert_eq "" "$(cwd_files)" "no file in the working folder" || return 1
}

# ---------------------------------------------------------------------
# Box token folder and provider warnings
# ---------------------------------------------------------------------

# Check that _box_state_dir uses MPARCHIVE_STATE_DIR when it is set.
_check_box_state_dir_from_env() {
    run_snippet 'source "$COMMON_SH"; source "$BOX_SH"; _box_state_dir'
    assert_eq "0" "$RC" "exit code" || return 1
    assert_eq "$MPARCHIVE_STATE_DIR/box" "$OUT" "token folder is STATE_DIR/box" || return 1
}

# Check that _box_state_dir uses /var/lib/mp-archive/box when STATE_DIR is unset.
_check_box_state_dir_default() {
    run_snippet 'source "$COMMON_SH"; source "$BOX_SH"; _box_state_dir' MPARCHIVE_STATE_DIR
    assert_eq "0" "$RC" "exit code" || return 1
    assert_eq "/var/lib/mp-archive/box" "$OUT" "default token folder" || return 1
}

# Check that provider_init warns about a .env with a mode that others can read.
# It reads .env from MPARCHIVE_CONFIG_DIR. No network call is made.
_check_box_warns_on_config_env_mode() {
    chmod 644 -- "$MPARCHIVE_CONFIG_DIR/.env" || return 1
    run_snippet 'source "$COMMON_SH"; source "$BOX_SH"; provider_init; exit $?'
    assert_eq "0" "$RC" "provider_init does not fail on a bad mode" || return 1
    assert_contains "$ERR" "WARNING: .env has mode 644" "warning for mode 644" || return 1

    chmod 600 -- "$MPARCHIVE_CONFIG_DIR/.env" || return 1
    run_snippet 'source "$COMMON_SH"; source "$BOX_SH"; provider_init; exit $?'
    assert_eq "0" "$RC" "provider_init exit code with mode 600" || return 1
    assert_not_contains "$ERR" "WARNING: .env" "no warning for mode 600" || return 1
}

# ---------------------------------------------------------------------
# Repo root
# ---------------------------------------------------------------------

# Check that the repo root is the same as before the checks ran.
# This shows that no check created .state, activity.log or error.log there.
test_repo_root_unchanged() {
    local after
    after="$(_repo_snapshot)"
    assert_eq "$REPO_SNAPSHOT_BEFORE" "$after" "repo root must not change" || return 1
}

# Check that the real repo .env has the same SHA-256 as before the checks ran.
# The content is never printed.
test_repo_env_unchanged() {
    local after
    after="$(_repo_env_sum)"
    assert_eq "$REPO_ENV_SUM_BEFORE" "$after" "real repo .env checksum must not change" || return 1
}

# ---------------------------------------------------------------------
# Test runner. Each test runs one check in a new sandbox.
# ---------------------------------------------------------------------

test_log_dir_from_env_file() { with_sandbox 1 _check_log_dir_from_env_file; }
test_state_dir_from_env_file() { with_sandbox 1 _check_state_dir_from_env_file; }
test_environment_wins_over_env_file() { with_sandbox 1 _check_environment_wins_over_env_file; }
test_quoted_values_in_env_file() { with_sandbox 1 _check_quoted_values_in_env_file; }
test_defaults_when_nothing_sets_them() { with_sandbox 1 _check_defaults_when_nothing_sets_them; }
test_state_dir_default_with_sandbox_log_dir() { with_sandbox 1 _check_state_dir_default_with_sandbox_log_dir; }
test_relative_log_dir_rejected() { with_sandbox 1 _check_relative_log_dir; }
test_relative_state_dir_rejected() { with_sandbox 1 _check_relative_state_dir; }
test_relative_config_dir_rejected() { with_sandbox 1 _check_relative_config_dir; }
test_mpa_init_relative_log_dir() { with_sandbox 1 _check_mpa_init_relative_log_dir; }
test_mpa_init_relative_state_dir() { with_sandbox 1 _check_mpa_init_relative_state_dir; }
test_missing_env_file_message() { with_sandbox 1 _check_missing_env_file_message; }
test_env_file_without_provider() { with_sandbox 1 _check_env_file_without_provider; }
test_mpa_init_reads_env_file_paths() { with_sandbox 1 _check_mpa_init_reads_env_file_paths; }
test_empty_log_dir_writes_no_file() { with_sandbox 1 _check_empty_log_dir_writes_no_file; }
test_uncreatable_log_dir_is_quiet() { with_sandbox 1 _check_uncreatable_log_dir_is_quiet; }
test_upload_usage_error_env_log_dir() { with_sandbox 1 _check_upload_usage_error_env_log_dir; }
test_download_usage_error_env_log_dir() { with_sandbox 1 _check_download_usage_error_env_log_dir; }
test_box_state_dir_from_env() { with_sandbox 1 _check_box_state_dir_from_env; }
test_box_state_dir_default() { with_sandbox 1 _check_box_state_dir_default; }
test_box_warns_on_config_env_mode() { with_sandbox 1 _check_box_warns_on_config_env_mode; }
test_config_fallback_to_project_env() { with_sandbox 1 _check_config_fallback_to_project_env; }
test_config_system_env_wins() { with_sandbox 1 _check_config_system_env_wins; }
test_config_unreadable_system_env_no_fallback() { with_sandbox 1 _check_config_unreadable_system_env_no_fallback; }
test_config_explicit_no_fallback() { with_sandbox 1 _check_config_explicit_no_fallback; }
test_init_no_env_anywhere_message() { with_sandbox 1 _check_init_no_env_anywhere_message; }
test_init_fallback_loads_project_accounts() { with_sandbox 1 _check_init_fallback_loads_project_accounts; }

run_test "env: LOG_DIR read from .env" test_log_dir_from_env_file
run_test "env: STATE_DIR read from .env" test_state_dir_from_env_file
run_test "env: environment wins over .env" test_environment_wins_over_env_file
run_test "env: quoted values in .env" test_quoted_values_in_env_file
run_test "defaults: values when nothing sets them" test_defaults_when_nothing_sets_them
run_test "defaults: STATE_DIR default with LOG_DIR set" test_state_dir_default_with_sandbox_log_dir
run_test "config: fallback to project .env when system .env is missing" test_config_fallback_to_project_env
run_test "config: system .env wins over project .env" test_config_system_env_wins
if [[ "$(id -u)" == "0" ]]; then
    # Root can read a mode 000 file, so this check cannot fail as root.
    printf 'SKIP  %s (running as root)\n' "config: unreadable system .env gives no fallback"
else
    run_test "config: unreadable system .env gives no fallback" test_config_unreadable_system_env_no_fallback
fi
run_test "config: explicit MPARCHIVE_CONFIG_DIR gives no fallback" test_config_explicit_no_fallback
run_test "paths: relative LOG_DIR is rejected" test_relative_log_dir_rejected
run_test "paths: relative STATE_DIR is rejected" test_relative_state_dir_rejected
run_test "paths: relative CONFIG_DIR is rejected" test_relative_config_dir_rejected
run_test "init: mpa_init fails on relative LOG_DIR" test_mpa_init_relative_log_dir
run_test "init: mpa_init fails on relative STATE_DIR" test_mpa_init_relative_state_dir
run_test "init: missing .env gives Settings file not found" test_missing_env_file_message
run_test "init: no .env anywhere gives the two-path message" test_init_no_env_anywhere_message
run_test "init: fallback loads accounts from project folder" test_init_fallback_loads_project_accounts
run_test "init: .env without PROVIDER gives Set PROVIDER" test_env_file_without_provider
run_test "init: mpa_init reads paths from .env" test_mpa_init_reads_env_file_paths
run_test "log: empty LOG_DIR writes no file in cwd" test_empty_log_dir_writes_no_file
run_test "log: uncreatable LOG_DIR is non-fatal and quiet" test_uncreatable_log_dir_is_quiet
run_test "usage: upload.sh usage error reaches .env log folder" test_upload_usage_error_env_log_dir
run_test "usage: download.sh usage error reaches .env log folder" test_download_usage_error_env_log_dir
run_test "box: _box_state_dir uses STATE_DIR" test_box_state_dir_from_env
run_test "box: _box_state_dir default" test_box_state_dir_default
run_test "box: provider_init mode warning reads CONFIG_DIR" test_box_warns_on_config_env_mode
run_test "repo: root unchanged by these checks" test_repo_root_unchanged
run_test "repo: real .env checksum unchanged by these checks" test_repo_env_unchanged

finish_tests
