#!/bin/bash
###############################################################################
# HBase Cluster Replication Script
#
# This script performs HBase table replication between clusters using snapshots.
#
# Copyright (c) 2026 Acceldata Inc. All rights reserved.
#
# This software and associated documentation files (the "Software") are
# proprietary to Acceldata Inc. and may not be reproduced, distributed,
# transmitted, displayed, published, or broadcast without the prior written
# permission of Acceldata Inc.
###############################################################################

# Set strict error handling
set -euo pipefail

# Usage:
#   ./hbase_cluster_replicate.sh <TABLE_NAME> <SNAP_PREFIX> [RETENTION] <DEST_NN_URI> \
#                                <DEST_HBASE_SNAPSHOT_DIR> <DEST_HOST> \
#                                <DEST_SSH_USER> <KERBEROS_ENABLED> [PRINCIPAL] [KEYTAB] [DEST_KEYTAB] \
#                                [USER] [MAPPERS] [SSH_OPTS] [EXPORT_OPTS]
#
# Positional arguments (required):
#   1) TABLE_NAME             - HBase table name/pattern:
#                              * Single table: "table" (default namespace) or "namespace:table"
#                              * Wildcard pattern: "namespace:table*" or "*:table" or "namespace:*"
#                              * Example: "prod:customer_*" matches all tables in prod namespace starting with "customer_"
#   2) SNAP_PREFIX            - Snapshot name prefix
#   3) RETENTION              - Number of snapshots to keep in rotation (default: 1)
#   4) DEST_NN_URI            - Destination namenode URI (e.g., hdfs://ODP-Aurora)
#   5) DEST_HBASE_SNAPSHOT_DIR - Destination HBase snapshot directory
#   6) DEST_HOST              - Destination hostname or IP
#   7) DEST_SSH_USER          - SSH user for destination
#   8) KERBEROS_ENABLED       - Enable Kerberos authentication: "yes" or "no" (mandatory)
#
# Optional arguments (can also use environment variables):
#   9) PRINCIPAL              - Kerberos principal (required if KERBEROS_ENABLED=yes)
#   10) KEYTAB                 - Path to keytab file (required if KERBEROS_ENABLED=yes)
#   11) DEST_KEYTAB            - Keytab path on destination (required if KERBEROS_ENABLED=yes)
#   12) USER                  - User to run commands as (for non-kerberos clusters, uses su instead of sudo)
#   13) MAPPERS               - Number of mappers (default: 8)
#   14) SSH_OPTS              - SSH options (default: -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)
#   15) EXPORT_OPTS           - Additional ExportSnapshot options (e.g., --overwrite --bandwidth 100 --chuser MyUser --chgroup MyGroup --chmod 700, or JVM options like -Dsnapshot.export.default.map.group=10)
#
# Note:
#   - For Kerberos clusters (KERBEROS_ENABLED=yes): PRINCIPAL, KEYTAB, and DEST_KEYTAB are required
#     * kinit runs as root user (current user)
#     * All commands run as root user (no user switching needed)
#   - For non-Kerberos clusters (KERBEROS_ENABLED=no): USER should be set to run commands as specific user
#     * Commands use 'su' to switch to USER (root won't have access/authorization)
#     * Commands executed as: su - $USER -c "command"
#   - HBASE_CONF_DIR and HADOOP_CONF_DIR are hardcoded to /etc/hbase/conf and /etc/hadoop/conf respectively
###############################################################################

# Script metadata
START_TIME=$(date +%s)

# Load required parameters from positional arguments (with env var fallback)
TABLE_NAME="${1:-${TABLE_NAME:-}}"
SNAP_PREFIX="${2:-${SNAP_PREFIX:-}}"
RETENTION="${3:-${RETENTION:-1}}"  # Number of snapshots to keep (default: 1)
DEST_NN_URI="${4:-${DEST_NN_URI:-}}"
DEST_HBASE_SNAPSHOT_DIR="${5:-${DEST_HBASE_SNAPSHOT_DIR:-}}"
DEST_HOST="${6:-${DEST_HOST:-}}"
DEST_SSH_USER="${7:-${DEST_SSH_USER:-}}"

# Required Kerberos enabled flag (can also use environment variable)
# Accepts: yes, no, true, false, 1, 0 (case insensitive, but must be provided)
KERBEROS_ENABLED_FLAG="${8:-${KERBEROS_ENABLED:-}}"

# Optional Kerberos parameters (can also use environment variables)
PRINCIPAL="${9:-${PRINCIPAL:-}}"
KEYTAB="${10:-${KEYTAB:-}}"
DEST_KEYTAB="${11:-${DEST_KEYTAB:-}}"

# Optional user parameter (for non-kerberos clusters - uses su instead of sudo)
USER="${12:-${USER:-${RUN_AS_USER:-}}}"

# Optional parameters from positional arguments (with env var fallback and defaults)
MAPPERS="${13:-${MAPPERS:-8}}"
SSH_OPTS="${14:-${SSH_OPTS:--o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10}}"
EXPORT_OPTS="${15:-${EXPORT_OPTS:-}}"

# Parse SSH options into an array so ssh/scp receive safe, consistent arguments.
# Supports either defaults or user-provided SSH_OPTS string.
declare -a SSH_OPTS_ARR=()
if [[ -n "${SSH_OPTS:-}" ]]; then
    # shellcheck disable=SC2206
    SSH_OPTS_ARR=(${SSH_OPTS})
fi
if [[ ${#SSH_OPTS_ARR[@]} -eq 0 ]]; then
    SSH_OPTS_ARR=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)
fi
SSH_OPTS_DISPLAY="${SSH_OPTS_ARR[*]}"

# Normalize and determine if Kerberos is enabled
# Convert KERBEROS_ENABLED_FLAG to boolean (yes/no/true/false/1/0 -> true/false)
# Note: Empty check happens in main validation section, this only normalizes if provided
KERBEROS_ENABLED_FLAG_LOWER=$(echo "$KERBEROS_ENABLED_FLAG" | tr '[:upper:]' '[:lower:]')
KERBEROS_ENABLED=false

if [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "yes" ]] || \
   [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "true" ]] || \
   [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "1" ]] || \
   [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "y" ]]; then
    KERBEROS_ENABLED=true
elif [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "no" ]] || \
     [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "false" ]] || \
     [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "0" ]] || \
     [[ "$KERBEROS_ENABLED_FLAG_LOWER" == "n" ]]; then
    KERBEROS_ENABLED=false
elif [[ -n "$KERBEROS_ENABLED_FLAG" ]]; then
    # Only validate format if value is provided (empty check happens in validation section)
    log_error "Invalid KERBEROS_ENABLED value: ${KERBEROS_ENABLED_FLAG}. Expected 'yes' or 'no'"
    exit 1
fi

# Determine if user switching is needed (for non-kerberos clusters)
USE_USER_SWITCHING=false
if [[ -n "$USER" ]] && [[ "$KERBEROS_ENABLED" == false ]]; then
    USE_USER_SWITCHING=true
fi

###############################################################################
# Setup logging (early, before validation, so validation errors are logged)
###############################################################################

# Log directory (default: /var/log/hbase-replication, can be overridden via env var)
LOG_DIR="${LOG_DIR:-/var/log/hbase-replication}"

# Create log directory if it doesn't exist
if [[ ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}" 2>/dev/null || LOG_DIR="/tmp"
fi

# Create log file name (sanitize TABLE_NAME for filename, use fallback if invalid)
# We'll validate TABLE_NAME format later, but use it here if provided
# Special handling: if TABLE_NAME contains wildcards, use "wildcard_expansion" label instead
TABLE_NAME_SANITIZED="${TABLE_NAME//[:\/]/_}"
if [[ "$TABLE_NAME" =~ [\*\?] ]]; then
    # Wildcard pattern detected - use descriptive label instead of pattern with asterisks
    TABLE_NAME_SANITIZED="wildcard_expansion"
elif [[ -z "$TABLE_NAME_SANITIZED" ]] || [[ "$TABLE_NAME_SANITIZED" == "_" ]]; then
    TABLE_NAME_SANITIZED="unknown_table"
fi
LOG_FILE="${LOG_DIR}/hbase_cluster_replicate_${TABLE_NAME_SANITIZED}_$(date +%Y%m%d_%H%M%S).log"

# Redirect all output (stdout and stderr) to both console and log file
# This ensures ALL output from the script and subcommands is captured
exec > >(tee -a "${LOG_FILE}") 2>&1

###############################################################################
# Logging Functions and Utilities
###############################################################################

# Global variables for logging and timing
SCRIPT_START_TIME=$(date +%s)
STAGE_START_TIME=""
STAGE_NAME=""

# Function to get elapsed time in human-readable format
get_elapsed_time() {
    local start_time=$1
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))

    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    if [[ $hours -gt 0 ]]; then
        printf "%dh %dm %ds" $hours $minutes $seconds
    elif [[ $minutes -gt 0 ]]; then
        printf "%dm %ds" $minutes $seconds
    else
        printf "%ds" $seconds
    fi
}

# Function to mark stage start time
mark_stage_start() {
    STAGE_NAME="$1"
    STAGE_START_TIME=$(date +%s)
}

# Function to log with elapsed time
log_stage_complete() {
    if [[ -n "$STAGE_START_TIME" ]]; then
        local elapsed=$(get_elapsed_time "$STAGE_START_TIME")
        echo "[INFO] ⏱  ${STAGE_NAME} completed in ${elapsed}"
        STAGE_START_TIME=""
        STAGE_NAME=""
    fi
}

# Enhanced log function with structured format
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    case "$level" in
        ERROR)
            printf "[%s] ❌ [ERROR]   %s\n" "$timestamp" "$message"
            ;;
        SUCCESS)
            printf "[%s] ✓  [SUCCESS] %s\n" "$timestamp" "$message"
            ;;
        INFO)
            printf "[%s] ℹ️  [INFO]    %s\n" "$timestamp" "$message"
            ;;
        WARN)
            printf "[%s] ⚠️  [WARN]    %s\n" "$timestamp" "$message"
            ;;
        DEBUG)
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                printf "[%s] 🔍 [DEBUG]   %s\n" "$timestamp" "$message"
            fi
            ;;
        PROGRESS)
            printf "[%s] ▶️  [PROGRESS] %s\n" "$timestamp" "$message"
            ;;
        *)
            printf "[%s] %s\n" "$timestamp" "$message"
            ;;
    esac
}

# Convenience functions for different log levels
log_error()    { log_message "ERROR" "$1"; }
log_success()  { log_message "SUCCESS" "$1"; }
log_info()     { log_message "INFO" "$1"; }
log_warn()     { log_message "WARN" "$1"; }
log_debug()    { log_message "DEBUG" "$1"; }
log_progress() { log_message "PROGRESS" "$1"; }

# Function to print formatted section header
section_header() {
    echo ""
    echo "=========================================================================="
    echo "   $1"
    echo "=========================================================================="
    echo ""
}

# Function to print formatted subsection header
subsection_header() {
    echo ""
    echo "──────────────────────────────────────────────────────────────────────────"
    echo "   $1"
    echo "──────────────────────────────────────────────────────────────────────────"
    echo ""
}

# Function to log command execution
log_command_execution() {
    local cmd="$1"
    local description="${2:-}"
    log_progress "Executing: $cmd"
    if [[ -n "$description" ]]; then
        log_debug "Description: $description"
    fi
}

# Function to log script summary at the end
log_script_summary() {
    local total_time=$(get_elapsed_time "$SCRIPT_START_TIME")

    section_header "Script Execution Summary"
    echo "Total execution time: $total_time"
    if [[ -n "${SUCCESS_COUNT:-}" ]]; then
        echo "Successfully replicated tables: $SUCCESS_COUNT"
    fi
    if [[ -n "${FAILED_TABLES:-}" ]] && [[ ${#FAILED_TABLES[@]:-0} -gt 0 ]]; then
        echo "Failed tables: ${#FAILED_TABLES[@]}"
        for table in "${FAILED_TABLES[@]}"; do
            echo "  - $table"
        done
    fi
    echo "Log file: $LOG_FILE"
    echo ""
}

###############################################################################
# Helper Functions
###############################################################################

# Function to detect if TABLE_NAME contains wildcard characters
is_wildcard_pattern() {
    local pattern="$1"
    [[ "$pattern" =~ \* ]] || [[ "$pattern" =~ \? ]]
    return $?
}

# Function to list all HBase tables
get_all_hbase_tables() {
    # Returns list of tables in format "namespace:table" or "table" (for default namespace)
    local tables_output
    tables_output=$(execute_hbase_shell_input "list" 2>/dev/null || echo "")

    echo "[DEBUG] Raw HBase list output (first 500 chars):" >&2
    echo "$tables_output" | head -c 500 >&2
    echo "" >&2

    local tables=()

    # Try to extract tables from the array format: => ["table1", "table2", ...]
    # This is more reliable than parsing individual lines
    if echo "$tables_output" | grep -q "^=> \["; then
        echo "[DEBUG] Found array format in output" >&2
        # Extract the array line
        local array_line
        array_line=$(echo "$tables_output" | grep "^=> \[" | head -1)
        echo "[DEBUG] Array line: $array_line" >&2

        # Remove the "=> [" prefix and "]" suffix, then split by comma and quotes
        local table_list
        table_list=$(echo "$array_line" | sed 's/^=> \[//; s/\]$//')
        echo "[DEBUG] Table list after removing brackets: $table_list" >&2

        # Extract table names from quoted strings
        # Pattern: "tablename" or "namespace:tablename"
        while IFS= read -r line; do
            # Extract quoted strings
            echo "$line" | grep -oP '"[^"]*"' | sed 's/"//g'
        done <<< "$table_list" | while read -r table; do
            echo "[DEBUG] Processing table: '$table'" >&2
            [[ -z "$table" ]] && continue
            # Skip system tables and filter
            if [[ "$table" =~ ^hbase: ]]; then
                echo "[DEBUG] Skipping hbase: prefixed table: $table" >&2
                continue
            fi
            echo "[DEBUG] Adding table to results: $table" >&2
            echo "$table"
        done
    else
        echo "[DEBUG] Array format NOT found, using fallback line-by-line parsing" >&2
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Skip header and metadata lines
            [[ "$line" == "TABLE" ]] && continue
            [[ "$line" =~ ^(NAMESPACE|hbase:|row\(s\)|Took|Execution) ]] && continue
            [[ "$line" =~ ^(\+|---|\[|=>|=>) ]] && continue
            [[ "$line" =~ ^[[:space:]]*$ ]] && continue

            # Extract table name (first field, trim whitespace)
            local table
            table=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
            [[ -n "$table" ]] && echo "$table"
        done <<< "$tables_output"
    fi
}

# Function to match tables against wildcard pattern
expand_table_pattern() {
    local pattern="$1"

    # If pattern doesn't contain wildcards, return as-is (single table)
    if ! is_wildcard_pattern "$pattern"; then
        echo "$pattern"
        return 0
    fi

    echo "[DEBUG] expand_table_pattern: Processing wildcard pattern: $pattern" >&2

    # Get all tables from HBase
    local all_tables=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && all_tables+=("$line")
    done < <(get_all_hbase_tables)

    echo "[DEBUG] expand_table_pattern: Found ${#all_tables[@]} total tables:" >&2
    for tbl in "${all_tables[@]}"; do
        echo "[DEBUG]   - $tbl" >&2
    done

    if [[ ${#all_tables[@]} -eq 0 ]]; then
        echo "[WARN] No tables found in HBase cluster"
        return 1
    fi

    # Convert wildcard pattern to regex
    local regex_pattern="$pattern"
    echo "[DEBUG] expand_table_pattern: Original pattern: $regex_pattern" >&2
    regex_pattern="${regex_pattern//\./\\.}"  # Escape dots
    echo "[DEBUG] expand_table_pattern: After escaping dots: $regex_pattern" >&2
    regex_pattern="${regex_pattern//\*/.*}"    # Convert * to .*
    echo "[DEBUG] expand_table_pattern: After converting * to .*: $regex_pattern" >&2
    regex_pattern="${regex_pattern//\?/.}"     # Convert ? to . (escape ? to treat as literal)
    echo "[DEBUG] expand_table_pattern: After converting ? to .: $regex_pattern" >&2
    regex_pattern="^${regex_pattern}$"         # Anchor start and end
    echo "[DEBUG] expand_table_pattern: Final regex pattern: $regex_pattern" >&2

    # Filter tables against pattern
    local matched_tables=()
    for table in "${all_tables[@]}"; do
        if [[ "$table" =~ $regex_pattern ]]; then
            echo "[DEBUG] expand_table_pattern: MATCH - '$table' matches pattern" >&2
            matched_tables+=("$table")
        else
            echo "[DEBUG] expand_table_pattern: NO MATCH - '$table' does NOT match pattern" >&2
        fi
    done

    echo "[DEBUG] expand_table_pattern: Matched ${#matched_tables[@]} tables:" >&2
    for tbl in "${matched_tables[@]}"; do
        echo "[DEBUG]   - $tbl" >&2
    done

    if [[ ${#matched_tables[@]} -eq 0 ]]; then
        echo "[WARN] No tables matched pattern: $pattern"
        return 1
    fi

    # Return matched tables
    printf '%s\n' "${matched_tables[@]}"
}

# Function to execute command with user switching (for non-kerberos clusters)
# Uses 'su' instead of 'sudo' for user switching
# When Kerberos is enabled, commands run as root (current user)
# When Kerberos is disabled, commands run as specified USER using su
# This function works with simple commands that can be passed as a string
execute_as_user() {
    local cmd="$1"

    # When Kerberos is enabled, run commands as root (current user) - no user switching needed
    # When Kerberos is disabled, switch to USER using su (root won't have access/authorization)
    if [[ "$KERBEROS_ENABLED" == true ]]; then
        # Execute as current user (root) when Kerberos is enabled
        bash -c "$cmd"
        return $?
    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
        # Switch user using su (no sudo required) when Kerberos is disabled
        # -l flag ensures a login shell with proper environment setup
        su - "$USER" -c "$cmd"
        return $?
    else
        # Execute as current user (fallback - should not happen in normal operation)
        bash -c "$cmd"
        return $?
    fi
}

# Function to execute hbase shell commands with user switching
# Handles heredoc-style commands by using a temporary approach
# When Kerberos is enabled, runs as root; when disabled, uses su to switch to USER
execute_hbase_shell() {
    local hbase_cmd="$1"

    if [[ "$KERBEROS_ENABLED" == true ]]; then
        # When Kerberos is enabled, run as root (current user)
        hbase shell <<HBASE_EOF
${hbase_cmd}
HBASE_EOF
    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
        # When Kerberos is disabled, switch to USER using su
        echo "$hbase_cmd" | su - "$USER" -c "hbase shell"
    else
        # Fallback: run as current user
        hbase shell <<HBASE_EOF
${hbase_cmd}
HBASE_EOF
    fi
}

# Function to execute hbase shell with input string (for list commands)
# When Kerberos is enabled, runs as root; when disabled, uses su to switch to USER
execute_hbase_shell_input() {
    local hbase_input="$1"

    if [[ "$KERBEROS_ENABLED" == true ]]; then
        # When Kerberos is enabled, run as root (current user)
        hbase shell <<< "$hbase_input"
    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
        # When Kerberos is disabled, switch to USER using su
        su - "$USER" -c "hbase shell <<< \"${hbase_input}\""
    else
        # Fallback: run as current user
        hbase shell <<< "$hbase_input"
    fi
}

# Function to execute hdfs commands with user switching
# When Kerberos is enabled, runs as root; when disabled, uses su to switch to USER
execute_hdfs() {
    local hdfs_cmd="$1"

    if [[ "$KERBEROS_ENABLED" == true ]]; then
        # When Kerberos is enabled, run as root (current user)
        hdfs ${hdfs_cmd}
    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
        # When Kerberos is disabled, switch to USER using su
        su - "$USER" -c "hdfs ${hdfs_cmd}"
    else
        # Fallback: run as current user
        hdfs ${hdfs_cmd}
    fi
}

###############################################################################
# Input Validation
###############################################################################

# Validate required parameters (all required parameters including KERBEROS_ENABLED)
if [[ -z "$TABLE_NAME" ]] || [[ -z "$SNAP_PREFIX" ]] || [[ -z "$DEST_NN_URI" ]] || \
   [[ -z "$DEST_HBASE_SNAPSHOT_DIR" ]] || [[ -z "$DEST_HOST" ]] || [[ -z "$DEST_SSH_USER" ]] || \
   [[ -z "$KERBEROS_ENABLED_FLAG" ]]; then
    log_error "Missing required arguments"
    echo ""
    echo "Usage: $0 <TABLE_NAME> <SNAP_PREFIX> [RETENTION] <DEST_NN_URI> \\"
    echo "              <DEST_HBASE_SNAPSHOT_DIR> <DEST_HOST> <DEST_SSH_USER> \\"
    echo "              <KERBEROS_ENABLED> [PRINCIPAL] [KEYTAB] [DEST_KEYTAB] [USER] [MAPPERS] [SSH_OPTS] [EXPORT_OPTS]"
    echo ""
    echo "Required arguments:"
    echo "  1) TABLE_NAME             - HBase table name (table for default namespace, or namespace:table)"
    echo "  2) SNAP_PREFIX            - Snapshot name prefix"
    echo "  3) RETENTION              - Number of snapshots to keep in rotation (default: 1)"
    echo "  4) DEST_NN_URI            - Destination namenode URI"
    echo "  5) DEST_HBASE_SNAPSHOT_DIR - Destination HBase snapshot directory"
    echo "  6) DEST_HOST              - Destination hostname or IP"
    echo "  7) DEST_SSH_USER          - SSH user for destination"
    echo "  8) KERBEROS_ENABLED       - Enable Kerberos: 'yes' or 'no' (mandatory)"
    echo ""
    echo "Optional arguments (can also use environment variables):"
    echo "  9) PRINCIPAL              - Kerberos principal (required if KERBEROS_ENABLED=yes)"
    echo "  10) KEYTAB                 - Path to keytab file (required if KERBEROS_ENABLED=yes)"
    echo "  11) DEST_KEYTAB            - Keytab path on destination (required if KERBEROS_ENABLED=yes)"
    echo "  12) USER                  - User to run commands as (for non-kerberos, uses su instead of sudo)"
    echo "  13) MAPPERS               - Number of mappers (default: 8)"
    echo "  14) SSH_OPTS              - SSH options (default: -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)"
    echo "  15) EXPORT_OPTS           - Additional ExportSnapshot options (e.g., --overwrite --bandwidth 100 --chuser MyUser --chgroup MyGroup --chmod 700)"
    echo ""
    echo "Cluster Configuration:"
    if [[ "$KERBEROS_ENABLED" == true ]]; then
        echo "  Mode: Kerberos enabled"
    elif [[ "$USE_USER_SWITCHING" == true ]]; then
        echo "  Mode: Non-kerberos with user switching (USER=${USER})"
    else
        echo "  Mode: Non-kerberos (no user switching)"
        echo "  Note: For non-kerberos clusters, consider setting USER variable to run commands as specific user"
    fi
    echo ""
    exit 1
fi

# Validate Kerberos parameters only if Kerberos is explicitly enabled
if [[ "$KERBEROS_ENABLED" == true ]]; then
    if [[ -z "$PRINCIPAL" ]] || [[ -z "$KEYTAB" ]] || [[ -z "$DEST_KEYTAB" ]]; then
        echo "[ERROR] KERBEROS_ENABLED is set to 'yes' but required Kerberos parameters are missing"
        echo "[ERROR] When KERBEROS_ENABLED=yes, PRINCIPAL, KEYTAB, and DEST_KEYTAB are all required"
        exit 1
    fi
fi

# Warn if Kerberos is disabled but kerberos parameters are provided
if [[ "$KERBEROS_ENABLED" == false ]] && ([[ -n "$PRINCIPAL" ]] || [[ -n "$KEYTAB" ]] || [[ -n "$DEST_KEYTAB" ]]); then
    echo "[WARN] KERBEROS_ENABLED is set to 'no' but Kerberos parameters (PRINCIPAL, KEYTAB, DEST_KEYTAB) are provided"
    echo "[WARN] These parameters will be ignored"
fi

# Validate user switching configuration
if [[ "$USE_USER_SWITCHING" == true ]]; then
    # Verify user exists
    if ! id -u "$USER" >/dev/null 2>&1; then
        echo "[ERROR] User '${USER}' does not exist on this system"
        exit 1
    fi
fi

# Validate parameter formats and existence
log_info "Performing pre-flight checks..."

# Validate table name format (accepts both "table", "namespace:table", and wildcard patterns)
if ! is_wildcard_pattern "$TABLE_NAME"; then
    # Single table - validate format
    if [[ ! "$TABLE_NAME" =~ ^[a-zA-Z0-9_]+(:[a-zA-Z0-9_]+)?$ ]]; then
        log_error "Invalid table name format: ${TABLE_NAME}"
        log_error "Expected format: table (default namespace) or namespace:table"
        exit 1
    fi
else
    # Wildcard pattern - validate format (allow * and ?)
    if [[ ! "$TABLE_NAME" =~ ^[a-zA-Z0-9_*?]+(:[a-zA-Z0-9_*?]+)?$ ]]; then
        log_error "Invalid wildcard pattern format: ${TABLE_NAME}"
        log_error "Expected format: table* (default namespace) or namespace:table* or *:table"
        exit 1
    fi
fi

# Validate Kerberos parameters only if Kerberos is enabled
if [[ "$KERBEROS_ENABLED" == true ]]; then
    # Validate keytab file exists and is readable
    if [[ ! -f "$KEYTAB" ]]; then
        log_error "Keytab file does not exist: ${KEYTAB}"
        exit 1
    fi
    if [[ ! -r "$KEYTAB" ]]; then
        log_error "Keytab file is not readable: ${KEYTAB}"
        exit 1
    fi

    # Validate principal format
    if [[ ! "$PRINCIPAL" =~ ^[^@]+@.+$ ]]; then
        log_error "Invalid principal format: ${PRINCIPAL}"
        log_error "Expected format: user@REALM"
        exit 1
    fi
fi

# Validate RETENTION is a positive integer
if ! [[ "$RETENTION" =~ ^[1-9][0-9]*$ ]]; then
    log_error "RETENTION must be a positive integer, got: ${RETENTION}"
    exit 1
fi

# Validate MAPPERS is a positive integer
if ! [[ "$MAPPERS" =~ ^[1-9][0-9]*$ ]]; then
    log_error "MAPPERS must be a positive integer, got: ${MAPPERS}"
    exit 1
fi

# Validate DEST_NN_URI format
if [[ ! "$DEST_NN_URI" =~ ^hdfs:// ]]; then
    log_error "Invalid DEST_NN_URI format: ${DEST_NN_URI}"
    log_error "Expected format: hdfs://nameservice or hdfs://hostname:port"
    exit 1
fi

# Validate DEST_HBASE_SNAPSHOT_DIR starts with /
if [[ ! "$DEST_HBASE_SNAPSHOT_DIR" =~ ^/ ]]; then
    log_error "DEST_HBASE_SNAPSHOT_DIR must be an absolute path: ${DEST_HBASE_SNAPSHOT_DIR}"
    exit 1
fi

# Validate hostname/IP format (basic check)
if [[ -z "$DEST_HOST" ]] || [[ "$DEST_HOST" =~ ^[[:space:]]+$ ]]; then
    log_error "Invalid destination host: ${DEST_HOST}"
    exit 1
fi

log_success "All pre-flight checks passed"

# Function to log with timestamp (log file is already set up earlier)
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Detect if TABLE_NAME is a wildcard pattern and will need expansion
IS_TABLE_PATTERN=false
if is_wildcard_pattern "$TABLE_NAME"; then
    IS_TABLE_PATTERN=true
    echo "[INFO] TABLE_NAME contains wildcard pattern: ${TABLE_NAME}"
    echo "[INFO] Will expand pattern to matching tables after Kerberos authentication"
fi

# Log script start with full details (mask sensitive info in logs)
echo "======================================================================"
echo "HBase Cluster Replication Script Started"
echo "======================================================================"
echo "Timestamp        : $(date)"
echo "Table Name/Pattern : ${TABLE_NAME}"
if [[ "$TABLE_NAME" =~ [\*\?] ]]; then
    echo "Pattern Type     : Wildcard (will expand to multiple tables)"
    echo "Log File Label   : wildcard_expansion"
else
    echo "Pattern Type     : Single table"
fi
echo "Snapshot Prefix  : ${SNAP_PREFIX}"
echo "Snapshot Retention : ${RETENTION} (keep last ${RETENTION} snapshot(s))"
if [[ "$KERBEROS_ENABLED" == true ]]; then
    echo "Kerberos Enabled : yes"
    echo "Principal        : ${PRINCIPAL}"
    echo "Keytab           : ${KEYTAB}"
    echo "Mode             : Kerberos enabled"
else
    echo "Kerberos Enabled : no"
    echo "Mode             : Non-Kerberos"
    if [[ "$USE_USER_SWITCHING" == true ]]; then
        echo "Run as User      : ${USER}"
    fi
fi
echo "Destination      : ${DEST_HOST} (${DEST_SSH_USER})"
echo "Mappers          : ${MAPPERS}"
echo "Log File         : ${LOG_FILE}"
echo "PID              : $$"
echo "======================================================================"
echo ""

###############################################################################
# Generate runtime variables
###############################################################################

# 1. Snapshot name (using incremental rotation scheme: _1, _2, _3, _4, ...)
# Function to determine next snapshot number and return oldest snapshot to delete
get_next_snapshot_info() {
    local prefix="$1"
    local table="$2"
    local max_keep="${3:-${RETENTION:-1}}"  # Maximum number of snapshots to keep (default: RETENTION or 1)
    local prefix_regex
    prefix_regex=$(printf '%s' "$prefix" | sed 's/[][(){}.^$*+?|\\]/\\&/g')

    # Get all snapshots for this prefix and table
    SNAPSHOT_LIST=$(execute_hbase_shell_input "list_snapshots" 2>/dev/null || echo "")

    # Extract snapshot numbers for this prefix and table
    declare -a SNAP_NUMBERS=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^(SNAPSHOT|TABLE|\+|---|hbase:|row\(s\)|Took|HBase|Use|For|Version|=>|\[) ]] && continue
        [[ "$line" =~ ^hbase:[0-9]+:[0-9]+ ]] && continue

        SNAP_NAME_FROM_LINE=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
        TABLE_NAME_FROM_LINE=$(echo "$line" | awk '{print $2}' | tr -d '[:space:]')

        # Match pattern: prefix_<number> (e.g., snap_replication03_1, snap_replication03_42)
        if [[ "$SNAP_NAME_FROM_LINE" =~ ^${prefix_regex}_([0-9]+)$ ]] && [[ "$TABLE_NAME_FROM_LINE" == "$table" ]]; then
            SNAP_NUM="${BASH_REMATCH[1]}"
            SNAP_NUMBERS+=("$SNAP_NUM")
        fi
    done <<< "$SNAPSHOT_LIST"

    # Sort numbers numerically and find min/max
    local highest=0
    local lowest=0
    local count=${#SNAP_NUMBERS[@]}

    if [[ $count -eq 0 ]]; then
        # No snapshots exist, start with _1
        echo "1:"
        return
    fi

    # Find highest and lowest numbers
    highest=${SNAP_NUMBERS[0]}
    lowest=${SNAP_NUMBERS[0]}

    for num in "${SNAP_NUMBERS[@]}"; do
        if [[ $num -gt $highest ]]; then
            highest=$num
        fi
        if [[ $num -lt $lowest ]]; then
            lowest=$num
        fi
    done

    # Determine next number and oldest to delete
    local next_number=$((highest + 1))
    local oldest_to_delete=""

    # If we have max_keep or more snapshots, delete the oldest (lowest number)
    if [[ $count -ge $max_keep ]]; then
        oldest_to_delete=$lowest
    fi

    # Output format: "next_number:oldest_to_delete" (oldest_to_delete can be empty)
    echo "${next_number}:${oldest_to_delete}"
}

# Note: SNAP_NUMBER and SNAP_NAME will be determined after authentication
# (for Kerberos clusters, this happens after kinit; for non-kerberos, hbase shell can run directly)

# 2. Normalize DEST_HBASE_SNAPSHOT_DIR (remove trailing slash if present)
#    Handles both formats: /apps/hbase/data/ or /apps/hbase/data
DEST_HBASE_SNAPSHOT_DIR_NORM="${DEST_HBASE_SNAPSHOT_DIR%/}"

# 3. Destination HDFS full path where snapshot will be exported
#    Ensure no trailing slash in the normalized path before constructing full path
DEST_HDFS_PATH="${DEST_NN_URI}${DEST_HBASE_SNAPSHOT_DIR_NORM}"

# 4. Destination metadata directory (will be set per-table in replicate_single_table)

###############################################################################
# Kerberos Authentication (only for Kerberos clusters)
###############################################################################
if [[ "$KERBEROS_ENABLED" == true ]]; then
    echo ""
    echo "======================================================================"
    echo "STEP 1: Kerberos Authentication"
    echo "======================================================================"
    echo "[SOURCE] Authenticating with Kerberos..."

    # Stage 1.1: Execute kinit as root user (when Kerberos is enabled, always use root)
    echo "[1.1] Execute kinit as root user..."
    echo ">>> EXECUTING COMMAND: kinit -kt <keytab> ${PRINCIPAL}"
    echo "----------------------------------------------------------------------"

    # Retry logic for kinit (network issues can cause transient failures)
    # When Kerberos is enabled, kinit must run as root (current user), not with user switching
    log_info "Attempting Kerberos authentication with retry logic (up to 3 attempts)..."
    KINIT_RETRIES=3
    KINIT_RETRY_DELAY=5
    KINIT_RC=1

    for attempt in $(seq 1 $KINIT_RETRIES); do
        if [[ $attempt -gt 1 ]]; then
            log_progress "Retry attempt $attempt of $KINIT_RETRIES after ${KINIT_RETRY_DELAY} seconds..."
            sleep $KINIT_RETRY_DELAY
        fi

        # Run kinit as root (current user) when Kerberos is enabled - do not use user switching
        if kinit -kt "${KEYTAB}" "${PRINCIPAL}" 2>&1; then
            KINIT_RC=0
            break
        else
            KINIT_RC=$?
            log_warn "kinit attempt $attempt failed with exit code $KINIT_RC"
        fi
    done

    echo "----------------------------------------------------------------------"
    if [[ $KINIT_RC -ne 0 ]]; then
        log_error "Stage 1.1 FAILED: kinit failed after ${KINIT_RETRIES} attempts with exit code $KINIT_RC"
        log_error "Please verify keytab file and principal are correct"
        exit $KINIT_RC
    fi
    log_success "Stage 1.1 completed: kinit successful (run as root user)"

    # Stage 1.2: Verify ticket was obtained (also as root user)
    echo "[1.2] Verify Kerberos ticket..."
    if ! klist -s 2>/dev/null; then
        log_error "Stage 1.2 FAILED: Kerberos ticket verification failed"
        exit 1
    fi
    log_success "Stage 1.2 completed: Ticket verified"
    log_success "STEP 1 completed: Kerberos authentication successful (root user)"
    log_info "When Kerberos is enabled, all commands run as root user"
    echo "----------------------------------------------------------------------"
else
    echo ""
    echo "======================================================================"
    echo "STEP 1: Skipping Kerberos Configuration (Non-Kerberos Mode)"
    echo "======================================================================"
    echo "[INFO] Kerberos is disabled - skipping kinit"
    if [[ "$USE_USER_SWITCHING" == true ]]; then
        echo "[INFO] Using user switching mode: commands will run as user '${USER}' (root won't have access/authorization)"
        echo "[INFO] Commands will be executed using: su - ${USER} -c 'command'"
    else
        echo "[WARN] No user specified for non-kerberos mode - commands will run as current user (root)"
        echo "[WARN] Root may not have proper access/authorization for HBase/HDFS operations"
        echo "[INFO] Consider setting USER variable to run commands as a specific user"
    fi
    echo "----------------------------------------------------------------------"
fi

###############################################################################
# Expand TABLE_NAME pattern to actual tables (if wildcard pattern provided)
###############################################################################
section_header "STEP 1b: Expand Table Pattern (if wildcard provided)"

declare -a TABLES_TO_REPLICATE=()

if [[ "$IS_TABLE_PATTERN" == true ]]; then
    log_progress "Expanding wildcard pattern: ${TABLE_NAME}"
    log_info "Querying HBase for matching tables..."

    # Use associative array to track tables and remove duplicates
    declare -A UNIQUE_TABLES=()

    while IFS= read -r matched_table; do
        if [[ -n "$matched_table" ]]; then
            # Store in associative array to deduplicate
            UNIQUE_TABLES["$matched_table"]=1
        fi
    done < <(expand_table_pattern "${TABLE_NAME}")

    # Convert associative array back to indexed array
    for table_name in "${!UNIQUE_TABLES[@]}"; do
        TABLES_TO_REPLICATE+=("$table_name")
    done

    # Sort array for consistent ordering
    IFS=$'\n' TABLES_TO_REPLICATE=($(sort <<<"${TABLES_TO_REPLICATE[*]}"))

    if [[ ${#TABLES_TO_REPLICATE[@]} -eq 0 ]]; then
        log_error "STEP 1b FAILED: No tables matched pattern: ${TABLE_NAME}"
        exit 1
    fi

    log_success "Pattern expanded to ${#TABLES_TO_REPLICATE[@]} table(s):"
    for tbl in "${TABLES_TO_REPLICATE[@]}"; do
        log_info "  • ${tbl}"
    done
else
    # Single table - add to array
    TABLES_TO_REPLICATE+=("$TABLE_NAME")
    log_info "Processing single table: ${TABLE_NAME}"
fi

log_success "STEP 1b completed: Table pattern resolved"
echo "----------------------------------------------------------------------"

###############################################################################
# Determine snapshot name (using incremental rotation scheme: _1, _2, _3, _4, ...)
###############################################################################
# Note: Will be determined per-table in loop
# Normalize DEST_HBASE_SNAPSHOT_DIR (remove trailing slash if present)
#    Handles both formats: /apps/hbase/data/ or /apps/hbase/data
DEST_HBASE_SNAPSHOT_DIR_NORM="${DEST_HBASE_SNAPSHOT_DIR%/}"

# 3. Destination HDFS full path where snapshot will be exported
#    Ensure no trailing slash in the normalized path before constructing full path
DEST_HDFS_PATH="${DEST_NN_URI}${DEST_HBASE_SNAPSHOT_DIR_NORM}"

###############################################################################
# Cleanup old snapshots (keep snapshots based on RETENTION setting, delete oldest when creating new one)
###############################################################################
cleanup_old_snapshots() {
    local prefix="$1"
    local oldest_snap_num="$2"  # The oldest snapshot number to delete (can be empty)
    local table="$3"
    local retention="${4:-}"  # Retention value (number of snapshots to keep)

    # Use RETENTION global if retention parameter not provided
    if [[ -z "$retention" ]]; then
        retention="${RETENTION:-1}"
    fi

    echo "[2.0] Cleanup old snapshots (using incremental rotation scheme)..."
    echo "      Prefix pattern: ${prefix}_*"
    echo "      Table filter: ${table}"
    echo "      Retention policy: Keep last ${retention} snapshot(s), delete oldest if needed"

    if [[ -n "$oldest_snap_num" ]]; then
        local oldest_snap_name="${prefix}_${oldest_snap_num}"
        echo "[INFO] Found ${retention} or more snapshots (rotation limit reached) - will delete oldest: ${oldest_snap_name}"

        # Verify the snapshot exists before attempting to delete
        SNAPSHOT_LIST=$(execute_hbase_shell_input "list_snapshots" 2>/dev/null || echo "")
        SNAP_EXISTS=false

        while IFS= read -r line; do
            [[ "$line" =~ ^(SNAPSHOT|TABLE|\+|---|hbase:|row\(s\)|Took|HBase|Use|For|Version|=>|\[) ]] && continue
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^hbase:[0-9]+:[0-9]+ ]] && continue

            SNAP_NAME_FROM_LINE=$(echo "$line" | awk '{print $1}' | tr -d '[:space:]')
            TABLE_NAME_FROM_LINE=$(echo "$line" | awk '{print $2}' | tr -d '[:space:]')

            if [[ "$SNAP_NAME_FROM_LINE" == "$oldest_snap_name" ]] && [[ "$TABLE_NAME_FROM_LINE" == "$table" ]]; then
                SNAP_EXISTS=true
                break
            fi
        done <<< "$SNAPSHOT_LIST"

        if [[ "$SNAP_EXISTS" == true ]]; then
            echo ">>> EXECUTING COMMAND: hbase shell - delete_snapshot '${oldest_snap_name}'"
            execute_hbase_shell "delete_snapshot '${oldest_snap_name}'" 2>&1
            DELETE_RC=${PIPESTATUS[0]}
            if [[ $DELETE_RC -eq 0 ]]; then
                echo "[SUCCESS] Deleted oldest snapshot from HBase: ${oldest_snap_name}"

                # Also clean up destination HDFS snapshot directory if it exists
                # (HBase delete_snapshot only removes metadata, not HDFS directory on destination cluster)
                local dest_snap_path="${DEST_HDFS_PATH}/.hbase-snapshot/${oldest_snap_name}"
                echo "[INFO] Cleaning up destination HDFS snapshot directory: ${dest_snap_path}"
                echo "[DEBUG] DEST_HDFS_PATH=${DEST_HDFS_PATH}"
                echo "[DEBUG] oldest_snap_name=${oldest_snap_name}"
                echo "[DEBUG] Constructed path: ${dest_snap_path}"
                echo ">>> EXECUTING COMMAND: hdfs dfs -test -d ${dest_snap_path}"

                # Check if directory exists on destination cluster (cross-cluster access with Kerberos)
                # Run command and capture output and return code explicitly
                if [[ "$KERBEROS_ENABLED" == true ]]; then
                    # When Kerberos is enabled, run as root (current user)
                    echo "[DEBUG] Running as root user (Kerberos enabled)"
                    hdfs dfs -test -d "${dest_snap_path}" >/dev/null 2>&1
                    TEST_RC=$?
                    TEST_OUTPUT=""
                    if [[ $TEST_RC -ne 0 ]]; then
                        # Re-run to capture error message
                        TEST_OUTPUT=$(hdfs dfs -test -d "${dest_snap_path}" 2>&1 || true)
                    fi
                elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
                    # When Kerberos is disabled, switch to USER using su
                    echo "[DEBUG] Running as user ${USER} (user switching enabled)"
                    su - "$USER" -c "hdfs dfs -test -d '${dest_snap_path}'" >/dev/null 2>&1
                    TEST_RC=$?
                    TEST_OUTPUT=""
                    if [[ $TEST_RC -ne 0 ]]; then
                        # Re-run to capture error message
                        TEST_OUTPUT=$(su - "$USER" -c "hdfs dfs -test -d '${dest_snap_path}'" 2>&1 || true)
                    fi
                else
                    # Fallback: run as current user
                    echo "[DEBUG] Running as current user (fallback mode)"
                    hdfs dfs -test -d "${dest_snap_path}" >/dev/null 2>&1
                    TEST_RC=$?
                    TEST_OUTPUT=""
                    if [[ $TEST_RC -ne 0 ]]; then
                        # Re-run to capture error message
                        TEST_OUTPUT=$(hdfs dfs -test -d "${dest_snap_path}" 2>&1 || true)
                    fi
                fi

                echo "[DEBUG] hdfs dfs -test -d exit code: ${TEST_RC}"
                if [[ -n "$TEST_OUTPUT" ]]; then
                    echo "[DEBUG] hdfs dfs -test -d error output: ${TEST_OUTPUT}"
                else
                    echo "[DEBUG] hdfs dfs -test -d produced no output (normal for test command)"
                fi

                # Additional verification using ls (to see actual directory contents if it exists)
                echo "[DEBUG] Verifying with: hdfs dfs -ls ${dest_snap_path}"
                if [[ "$KERBEROS_ENABLED" == true ]]; then
                    LS_OUTPUT=$(hdfs dfs -ls "${dest_snap_path}" 2>&1 || true)
                    LS_RC=$?
                elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
                    LS_OUTPUT=$(su - "$USER" -c "hdfs dfs -ls '${dest_snap_path}'" 2>&1 || true)
                    LS_RC=$?
                else
                    LS_OUTPUT=$(hdfs dfs -ls "${dest_snap_path}" 2>&1 || true)
                    LS_RC=$?
                fi
                echo "[DEBUG] hdfs dfs -ls exit code: ${LS_RC}"
                if [[ -n "$LS_OUTPUT" ]]; then
                    echo "[DEBUG] hdfs dfs -ls output: ${LS_OUTPUT}"
                fi

                if [[ $TEST_RC -eq 0 ]]; then
                    echo "[INFO] Destination snapshot directory exists, deleting it..."
                    echo ">>> EXECUTING COMMAND: hdfs dfs -rm -r ${dest_snap_path}"
                    if [[ "$KERBEROS_ENABLED" == true ]]; then
                        DELETE_OUTPUT=$(hdfs dfs -rm -r "${dest_snap_path}" 2>&1)
                        DELETE_RC=$?
                    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
                        DELETE_OUTPUT=$(su - "$USER" -c "hdfs dfs -rm -r '${dest_snap_path}'" 2>&1)
                        DELETE_RC=$?
                    else
                        DELETE_OUTPUT=$(hdfs dfs -rm -r "${dest_snap_path}" 2>&1)
                        DELETE_RC=$?
                    fi

                    if [[ $DELETE_RC -eq 0 ]]; then
                        echo "[SUCCESS] Deleted destination HDFS snapshot directory: ${dest_snap_path}"
                    else
                        echo "[WARN] Failed to delete destination HDFS snapshot directory (exit code: $DELETE_RC)"
                        if [[ -n "$DELETE_OUTPUT" ]]; then
                            echo "[DEBUG] hdfs dfs -rm -r output: ${DELETE_OUTPUT}"
                        fi
                        echo "[WARN] This is non-critical - directory will be overwritten on next export if needed"
                    fi
                else
                    echo "[INFO] Destination HDFS snapshot directory does not exist or not accessible (exit code: ${TEST_RC})"
                    echo "[INFO] This may be normal if directory was already cleaned up, or due to cross-cluster access issues"
                    if [[ -n "$TEST_OUTPUT" ]]; then
                        echo "[DEBUG] Additional error details: ${TEST_OUTPUT}"
                    fi
                fi
            else
                echo "[WARN] Failed to delete snapshot ${oldest_snap_name} (exit code: $DELETE_RC), will attempt to create new snapshot anyway"
            fi
        else
            echo "[WARN] Oldest snapshot ${oldest_snap_name} was expected but not found in HBase - may have been deleted already"
        fi
    else
        echo "[INFO] Less than ${retention} snapshots exist - no cleanup needed (will keep all existing snapshots)"
    fi

    echo "[SUCCESS] Stage 2.0 completed: Cleanup finished"
    echo "----------------------------------------------------------------------"
}

###############################################################################
# Main Processing Loop - Replicate Each Table
###############################################################################
echo ""
echo "======================================================================"
echo "Processing Multiple Tables (${#TABLES_TO_REPLICATE[@]} total)"
echo "======================================================================"

# Pre-flight check: Validate snapshot prefix uniqueness (prevent collisions)
if [[ ${#TABLES_TO_REPLICATE[@]} -gt 1 ]]; then
    echo ""
    log_info "Validating snapshot prefix uniqueness for collision detection..."
    declare -A SNAPSHOT_PREFIX_MAP=()
    declare -a COLLISION_CONFLICTS=()

    for table_name in "${TABLES_TO_REPLICATE[@]}"; do
        # Generate snapshot prefix for this table (same logic as main loop)
        EFFECTIVE_TABLE_NAME="${table_name//:/_}"  # Replace colon with underscore
        TABLE_SNAP_PREFIX="${SNAP_PREFIX}_${EFFECTIVE_TABLE_NAME}"

        # Check for collision
        if [[ -n "${SNAPSHOT_PREFIX_MAP[$TABLE_SNAP_PREFIX]:-}" ]]; then
            COLLISION_CONFLICTS+=("TABLE 1: ${SNAPSHOT_PREFIX_MAP[$TABLE_SNAP_PREFIX]:-} | TABLE 2: ${table_name}")
            log_error "COLLISION DETECTED: Snapshot prefix collision for '${TABLE_SNAP_PREFIX}'"
            log_error "  Previous table: ${SNAPSHOT_PREFIX_MAP[$TABLE_SNAP_PREFIX]:-}"
            log_error "  Current table:  ${table_name}"
        else
            SNAPSHOT_PREFIX_MAP[$TABLE_SNAP_PREFIX]="$table_name"
        fi
    done

    if [[ ${#COLLISION_CONFLICTS[@]} -gt 0 ]]; then
        echo ""
        echo "[ERROR] COLLISION DETECTION FAILED: Found ${#COLLISION_CONFLICTS[@]} snapshot prefix collision(s)"
        echo "[ERROR] This occurs when table names produce identical snapshot prefixes after colon removal"
        echo "[ERROR] Example: 'namespace:table_name' and 'namespace_table:name' both → 'namespace_table_name'"
        echo "[ERROR]"
        echo "[ERROR] Conflicts:"
        for conflict in "${COLLISION_CONFLICTS[@]}"; do
            echo "[ERROR]   - $conflict"
        done
        echo ""
        echo "[ERROR] SOLUTION: Modify SNAP_PREFIX or table names to avoid collisions"
        echo "[ERROR] Consider using a more specific SNAP_PREFIX that includes namespace/region info"
        exit 1
    fi

    echo "[SUCCESS] No snapshot prefix collisions detected"
    echo ""
fi

TOTAL_TABLES=${#TABLES_TO_REPLICATE[@]}
SUCCESS_COUNT=0
FAILED_TABLES=()

for ((table_idx = 0; table_idx < TOTAL_TABLES; table_idx++)); do
    TABLE_NAME="${TABLES_TO_REPLICATE[$table_idx]}"
    TABLE_INDEX=$((table_idx + 1))
    TABLE_PROCESSING_FAILED=false

    # Set a trap to catch errors within this loop iteration
    trap 'TABLE_PROCESSING_FAILED=true' ERR

    set +e  # Disable exit-on-error temporarily to handle errors gracefully

    echo ""
    echo "========================================================================"
    echo "Table ${TABLE_INDEX}/${TOTAL_TABLES}: Replicating ${TABLE_NAME}"
    echo "========================================================================"

    # When using wildcard patterns (multiple tables), append table name to SNAP_PREFIX
    # to ensure each table gets unique snapshot names for clarity and independent rotation
    # Example: SNAP_PREFIX="backup", TABLE_NAME="prod:customers" → "backup_prod_customers"
    TABLE_SNAP_PREFIX="${SNAP_PREFIX}"
    if [[ $TOTAL_TABLES -gt 1 ]]; then
        # Multiple tables (wildcard pattern) - append table name to prefix
        # Convert namespace:table to namespace_table for snapshot name
        EFFECTIVE_TABLE_NAME="${TABLE_NAME//:/_}"  # Replace colon with underscore
        TABLE_SNAP_PREFIX="${SNAP_PREFIX}_${EFFECTIVE_TABLE_NAME}"
        echo "[INFO] Using table-specific snapshot prefix (due to wildcard pattern): ${TABLE_SNAP_PREFIX}"
    fi

    # Process this table - determine snapshot name for this table
    SNAPSHOT_INFO=$(get_next_snapshot_info "${TABLE_SNAP_PREFIX}" "${TABLE_NAME}" "${RETENTION}") || TABLE_PROCESSING_FAILED=true

    if [[ "$TABLE_PROCESSING_FAILED" == true ]]; then
        log_error "Failed to get snapshot info for table: ${TABLE_NAME}"
    else
        SNAP_NUMBER=$(echo "$SNAPSHOT_INFO" | cut -d':' -f1)
        OLDEST_SNAP_TO_DELETE=$(echo "$SNAPSHOT_INFO" | cut -d':' -f2)
        SNAP_NAME="${TABLE_SNAP_PREFIX}_${SNAP_NUMBER}"
    fi

    # Set destination metadata directory now that SNAP_NAME is known
    DEST_META_PATH="${DEST_HBASE_SNAPSHOT_DIR_NORM}/${SNAP_NAME}"

    echo ""
    echo "----------------------------------------------------------------------"
    echo "Table Configuration"
    echo "----------------------------------------------------------------------"
    echo "SNAP_NAME        = ${SNAP_NAME}"
    echo "DEST_HDFS_PATH   = ${DEST_HDFS_PATH}"
    echo "DEST_META_PATH   = ${DEST_META_PATH}"
    echo "----------------------------------------------------------------------"

###############################################################################
# Create snapshot on source
###############################################################################
echo ""
echo "======================================================================"
echo "STEP 2: Create HBase Snapshot"
echo "======================================================================"
echo "Table: ${TABLE_NAME}"
echo "Snapshot: ${SNAP_NAME}"
echo ""

# Stage 2.0: Cleanup old snapshots (using incremental rotation: delete oldest if we have RETENTION or more snapshots)
cleanup_old_snapshots "${TABLE_SNAP_PREFIX}" "${OLDEST_SNAP_TO_DELETE}" "${TABLE_NAME}" "${RETENTION}"

# Stage 2.1: Check if snapshot already exists
echo "[2.1] Check if snapshot already exists..."
SNAPSHOT_CHECK_OUTPUT=$(execute_hbase_shell_input "list_snapshots" 2>/dev/null)
if echo "$SNAPSHOT_CHECK_OUTPUT" | grep -q "^[[:space:]]*${SNAP_NAME}[[:space:]]" || echo "$SNAPSHOT_CHECK_OUTPUT" | grep -q "\"${SNAP_NAME}\""; then
    echo "[WARN] Snapshot ${SNAP_NAME} already exists. Skipping creation."
    echo "[INFO] Using existing snapshot: ${SNAP_NAME}"
    echo "[SUCCESS] Stage 2.1 completed: Snapshot found (already exists)"
    echo "[SUCCESS] STEP 2 completed: Using existing snapshot"
    echo "----------------------------------------------------------------------"
else
    echo "[SUCCESS] Stage 2.1 completed: Snapshot does not exist, will create new"

    # Stage 2.2: Create snapshot
    echo "[2.2] Create HBase snapshot..."
    echo ">>> EXECUTING COMMAND: hbase shell - snapshot '${TABLE_NAME}', '${SNAP_NAME}'"
    echo "----------------------------------------------------------------------"
    execute_hbase_shell "snapshot '${TABLE_NAME}', '${SNAP_NAME}'"

    SNAPSHOT_RC=${PIPESTATUS[0]}
    echo "----------------------------------------------------------------------"
    if [[ $SNAPSHOT_RC -ne 0 ]]; then
        echo "[ERROR] Stage 2.2 FAILED: Snapshot creation failed with exit code $SNAPSHOT_RC"
        echo "[ERROR] Table may not exist or may be in use"
        exit $SNAPSHOT_RC
    fi
    echo "[SUCCESS] Stage 2.2 completed: Snapshot created"

    # Stage 2.3: Verify snapshot was created
    echo "[2.3] Verify snapshot creation..."
    sleep 3  # Allow snapshot to be registered in HBase
    SNAPSHOT_VERIFY_OUTPUT=$(execute_hbase_shell_input "list_snapshots" 2>/dev/null)
    if echo "$SNAPSHOT_VERIFY_OUTPUT" | grep -q "^[[:space:]]*${SNAP_NAME}[[:space:]]" || echo "$SNAPSHOT_VERIFY_OUTPUT" | grep -q "\"${SNAP_NAME}\""; then
        echo "[SUCCESS] Stage 2.3 completed: Snapshot verified in HBase"
    else
        echo "[WARN] Stage 2.3: Snapshot ${SNAP_NAME} not immediately visible in list_snapshots"
        echo "[INFO] This may be normal - snapshot creation can take time to register"
        echo "[INFO] Continuing with export (snapshot was created successfully)"
    fi
    echo "[SUCCESS] STEP 2 completed: Snapshot ready: ${SNAP_NAME}"
    echo "----------------------------------------------------------------------"
fi

###############################################################################
# Export snapshot to destination HDFS
###############################################################################
echo ""
echo "======================================================================"
echo "STEP 3: Export Snapshot to Destination HDFS"
echo "======================================================================"
echo "Destination: ${DEST_HDFS_PATH}"
echo "Snapshot: ${SNAP_NAME}"
echo ""

# Stage 3.0: Clean up destination HDFS snapshot directory if it exists
# (ExportSnapshot will fail if the snapshot directory already exists on destination)
echo "[3.0] Clean up destination HDFS snapshot directory (if exists)..."
SNAPSHOT_DEST_PATH="${DEST_HDFS_PATH}/.hbase-snapshot/${SNAP_NAME}"
echo ">>> EXECUTING COMMAND: hdfs dfs -test -d ${SNAPSHOT_DEST_PATH}"

# Check if destination snapshot directory exists (cross-cluster access with Kerberos)
# Capture both stdout and stderr, but check return code
if execute_hdfs "dfs -test -d '${SNAPSHOT_DEST_PATH}'" >/dev/null 2>&1; then
    echo "[INFO] Destination snapshot directory exists, will delete it before export: ${SNAPSHOT_DEST_PATH}"
    echo ">>> EXECUTING COMMAND: hdfs dfs -rm -r ${SNAPSHOT_DEST_PATH}"
    if execute_hdfs "dfs -rm -r '${SNAPSHOT_DEST_PATH}'" 2>&1; then
        echo "[SUCCESS] Deleted existing destination snapshot directory: ${SNAPSHOT_DEST_PATH}"
    else
        DELETE_DEST_RC=$?
        echo "[WARN] Failed to delete destination snapshot directory (exit code: $DELETE_DEST_RC)"
        echo "[WARN] ExportSnapshot may fail if directory still exists - will attempt export anyway"
    fi
else
    echo "[INFO] Destination snapshot directory does not exist, no cleanup needed: ${SNAPSHOT_DEST_PATH}"
fi
echo "[SUCCESS] Stage 3.0 completed: Destination cleanup finished"
echo ""

# Stage 3.1: Execute ExportSnapshot
echo "[3.1] Execute ExportSnapshot..."

# Build the ExportSnapshot command display string
EXPORT_CMD_DISPLAY="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -snapshot ${SNAP_NAME} -copy-to ${DEST_HDFS_PATH} -mappers ${MAPPERS}"
if [[ -n "$EXPORT_OPTS" ]]; then
    EXPORT_CMD_DISPLAY="${EXPORT_CMD_DISPLAY} ${EXPORT_OPTS}"
fi

echo ">>> EXECUTING COMMAND: ${EXPORT_CMD_DISPLAY}"
echo "----------------------------------------------------------------------"
echo "[INFO] Starting ExportSnapshot..."
echo "[INFO] This may take a while for large tables..."

# When Kerberos is enabled, run as root (current user)
# When Kerberos is disabled, switch to USER using su
if [[ "$KERBEROS_ENABLED" == true ]]; then
    # Run as root (current user) when Kerberos is enabled
    if [[ -n "$EXPORT_OPTS" ]]; then
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}" \
          ${EXPORT_OPTS}; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    else
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}"; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    fi
elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
    # Switch to USER using su when Kerberos is disabled (root won't have access/authorization)
    # Build command as a string for su -c
    if [[ -n "$EXPORT_OPTS" ]]; then
        EXPORT_CMD_STR="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -snapshot '${SNAP_NAME}' -copy-to '${DEST_HDFS_PATH}' -mappers '${MAPPERS}' ${EXPORT_OPTS}"
    else
        EXPORT_CMD_STR="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -snapshot '${SNAP_NAME}' -copy-to '${DEST_HDFS_PATH}' -mappers '${MAPPERS}'"
    fi
    if su - "$USER" -c "${EXPORT_CMD_STR}"; then
        EXPORT_RC=0
    else
        EXPORT_RC=$?
    fi
else
    # Fallback: run as current user
    if [[ -n "$EXPORT_OPTS" ]]; then
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}" \
          ${EXPORT_OPTS}; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    else
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}"; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    fi
fi

echo "----------------------------------------------------------------------"
if [[ $EXPORT_RC -ne 0 ]]; then
    echo "[ERROR] Stage 3.1 FAILED: ExportSnapshot failed with exit code $EXPORT_RC"
    exit $EXPORT_RC
fi
echo "[SUCCESS] Stage 3.1 completed: ExportSnapshot command executed successfully"

# Stage 3.2: Verify export completed (check if snapshot exists in .hbase-snapshot directory)
echo "[3.2] Verify export completion..."
# ExportSnapshot creates snapshot in .hbase-snapshot directory on destination
# SNAPSHOT_DEST_PATH already defined in Stage 3.0
echo ">>> EXECUTING COMMAND: hdfs dfs -test -d ${SNAPSHOT_DEST_PATH}"
if execute_hdfs "dfs -test -d '${SNAPSHOT_DEST_PATH}'" 2>/dev/null; then
    echo "[SUCCESS] Stage 3.2 completed: Snapshot verified at destination"
    echo "         Snapshot location: ${SNAPSHOT_DEST_PATH}"
else
    echo "[WARN] Stage 3.2: Cannot verify snapshot destination path (may require cross-cluster access or namespace permissions)"
    echo "[INFO] ExportSnapshot command completed with exit code 0"
    echo "[INFO] Snapshot should be at: ${SNAPSHOT_DEST_PATH}"
fi
echo "[SUCCESS] STEP 3 completed: ExportSnapshot finished"
echo "----------------------------------------------------------------------"

###############################################################################
# Run Restore on Destination cluster
###############################################################################
echo ""
echo "======================================================================"
echo "STEP 4: Restore Snapshot on Destination Cluster"
echo "======================================================================"
echo "Destination Host: ${DEST_HOST}"
echo "SSH User: ${DEST_SSH_USER}"
echo ""

# Stage 4.1: Test SSH connectivity first
echo "[4.1] Test SSH connectivity to ${DEST_HOST}..."
echo ">>> EXECUTING COMMAND: ssh ${SSH_OPTS_DISPLAY} ${DEST_SSH_USER}@${DEST_HOST} \"echo 'SSH connection successful'\""
SSH_TEST_STDERR=$(ssh "${SSH_OPTS_ARR[@]}" "${DEST_SSH_USER}@${DEST_HOST}" "echo 'SSH connection successful'" 2>&1)
SSH_TEST_RC=$?
if [[ $SSH_TEST_RC -ne 0 ]]; then
    echo "[ERROR] Stage 4.1 FAILED: Cannot establish SSH connection to ${DEST_HOST}"
    echo "[ERROR] SSH command failed with exit code: ${SSH_TEST_RC}"
    if [[ -n "$SSH_TEST_STDERR" ]]; then
        echo "[ERROR] SSH error output:"
        echo "$SSH_TEST_STDERR" | sed 's/^/[ERROR]   /'
    fi
    echo "[ERROR] Please verify:"
    echo "         - Host is reachable"
    echo "         - SSH keys are configured"
    echo "         - User ${DEST_SSH_USER} has access"
    exit 1
fi
echo "[SUCCESS] Stage 4.1 completed: SSH connectivity verified"
echo ""

# Stage 4.2: Create destination script on source
echo "[4.2] Create destination restore script..."
LOCAL_DEST_SCRIPT="/tmp/hbase-apply-snapshot-dest.sh"
cat > "${LOCAL_DEST_SCRIPT}" <<DEST_SCRIPT_EOF
#!/bin/bash
# Usage: hbase-apply-snapshot-dest.sh <SNAP_NAME> <TABLE_NAME> [DEST_KEYTAB]
# Note: This script runs as the SSH user (destination user), no user switching needed

SNAP_NAME="\$1"
TABLE_NAME="\$2"
DEST_KEYTAB="\${3:-}"
HBASE_CONF_DIR="/etc/hbase/conf"
HADOOP_CONF_DIR="/etc/hadoop/conf"

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') [DEST] \$1"
}

if [[ -z "\$SNAP_NAME" || -z "\$TABLE_NAME" ]]; then
    log "ERROR: Missing arguments. Usage: hbase-apply-snapshot-dest.sh <SNAP_NAME> <TABLE_NAME> [DEST_KEYTAB]"
    exit 1
fi

# Script runs as the SSH user (whoever SSHed in), no user switching needed
log "Running commands as SSH user: \$(whoami)"
log "Received SNAP_NAME=\$SNAP_NAME TABLE_NAME=\$TABLE_NAME"

# Kerberos authentication on destination (if DEST_KEYTAB is provided)
if [[ -n "\$DEST_KEYTAB" ]]; then
    if [[ ! -f "\$DEST_KEYTAB" ]]; then
        log "ERROR: Destination keytab file does not exist: \${DEST_KEYTAB}"
        exit 1
    fi

    if [[ ! -r "\$DEST_KEYTAB" ]]; then
        log "ERROR: Destination keytab file is not readable: \${DEST_KEYTAB}"
        exit 1
    fi

    log "Kerberos enabled on destination - performing kinit..."
    log "Extracting principal from keytab: \${DEST_KEYTAB}"

    # Extract principal from keytab file using klist -kt
    # klist -kt outputs keytab entries, principal is typically on line 4 (after header lines)
    # Format: "    4  10/01/26 12:00:00 principal@REALM.COM"
    # Extract using: klist -kt KEYTAB | sed -n "4p" | cut -d ' ' -f7
    # If that fails, use awk to get the last field (principal is typically the last field)
    PRINCIPAL_FROM_KEYTAB=\$(klist -kt "\$DEST_KEYTAB" 2>/dev/null | sed -n "4p" | cut -d ' ' -f7 2>/dev/null || echo "")

    # If cut didn't work (empty or doesn't contain @), try awk to get last field
    if [[ -z "\$PRINCIPAL_FROM_KEYTAB" ]] || [[ ! "\$PRINCIPAL_FROM_KEYTAB" =~ @ ]]; then
        PRINCIPAL_FROM_KEYTAB=\$(klist -kt "\$DEST_KEYTAB" 2>/dev/null | sed -n "4p" | awk '{print \$NF}' || echo "")
    fi

    # Additional fallback: try to get any field containing @
    if [[ -z "\$PRINCIPAL_FROM_KEYTAB" ]] || [[ ! "\$PRINCIPAL_FROM_KEYTAB" =~ @ ]]; then
        PRINCIPAL_FROM_KEYTAB=\$(klist -kt "\$DEST_KEYTAB" 2>/dev/null | sed -n "4p" | tr ' ' '\n' | grep '@' | head -1 || echo "")
    fi

    if [[ -z "\$PRINCIPAL_FROM_KEYTAB" ]] || [[ ! "\$PRINCIPAL_FROM_KEYTAB" =~ @ ]]; then
        log "ERROR: Cannot extract principal from keytab file: \${DEST_KEYTAB}"
        log "ERROR: Please verify the keytab file is valid and contains principal entries"
        log "ERROR: Keytab format may differ from expected - check with: klist -kt \${DEST_KEYTAB}"
        exit 1
    fi

    log "Extracted principal: \${PRINCIPAL_FROM_KEYTAB}"
    log "Executing kinit with keytab..."
    echo ""
    echo ">>> EXECUTING COMMAND: kinit -kt \${DEST_KEYTAB} \${PRINCIPAL_FROM_KEYTAB}"

    # Retry logic for kinit
    KINIT_RETRIES=3
    KINIT_RETRY_DELAY=5
    KINIT_RC=1

    for attempt in \$(seq 1 \$KINIT_RETRIES); do
        if [[ \$attempt -gt 1 ]]; then
            log "Retry attempt \$attempt of \$KINIT_RETRIES after \$KINIT_RETRY_DELAY seconds..."
            sleep \$KINIT_RETRY_DELAY
        fi

        if kinit -kt "\$DEST_KEYTAB" "\$PRINCIPAL_FROM_KEYTAB" 2>&1; then
            KINIT_RC=0
            break
        else
            KINIT_RC=\$?
            log "WARN: kinit attempt \$attempt failed with exit code \$KINIT_RC"
        fi
    done

    if [[ \$KINIT_RC -ne 0 ]]; then
        log "ERROR: kinit failed after \$KINIT_RETRIES attempts with exit code \$KINIT_RC"
        log "ERROR: Please verify destination keytab file and principal are correct"
        exit \$KINIT_RC
    fi

    # Verify ticket was obtained
    if ! klist -s 2>/dev/null; then
        log "ERROR: Kerberos ticket verification failed after kinit"
        exit 1
    fi

    log "kinit successful on destination cluster"
    echo ""
else
    log "Kerberos not enabled on destination (no DEST_KEYTAB provided)"
    echo ""
fi

# 1. Get HBase root directory and verify snapshot exists
log "Getting HBase root directory..."
echo ""
echo ">>> EXECUTING COMMAND: hbase org.apache.hadoop.hbase.util.HBaseConfTool hbase.rootdir"
HBASE_ROOTDIR=\$(hbase org.apache.hadoop.hbase.util.HBaseConfTool hbase.rootdir 2>/dev/null | tail -1)
if [[ -z "\$HBASE_ROOTDIR" ]]; then
    log "ERROR: Cannot determine HBase root directory"
    exit 2
fi

# Snapshot should be in .hbase-snapshot directory
SNAP_PATH="\${HBASE_ROOTDIR}/.hbase-snapshot/\${SNAP_NAME}"

log "Checking snapshot at: \${SNAP_PATH}"
echo ""
echo ">>> EXECUTING COMMAND: hdfs dfs -test -d \${SNAP_PATH}"

# Try hdfs dfs -test -d first (primary check)
TEST_OUTPUT=\$(hdfs dfs -test -d "\${SNAP_PATH}" 2>&1)
TEST_RC=\$?

if [[ \$TEST_RC -ne 0 ]]; then
    # If test -d fails, try alternative: check if we can list the directory
    log "WARN: hdfs dfs -test -d failed (exit code: \$TEST_RC), trying alternative check with ls..."
    log "DEBUG: hdfs dfs -test -d output: \${TEST_OUTPUT}"
    echo ""
    echo ">>> EXECUTING COMMAND: hdfs dfs -ls \${SNAP_PATH}"

    LS_OUTPUT=\$(hdfs dfs -ls "\${SNAP_PATH}" 2>&1)
    LS_RC=\$?

    if [[ \$LS_RC -ne 0 ]]; then
        log "ERROR: Snapshot directory not found on destination: \${SNAP_PATH}"
        log "ERROR: hdfs dfs -test -d failed with exit code: \$TEST_RC"
        log "ERROR: hdfs dfs -ls failed with exit code: \$LS_RC"
        log "ERROR: hdfs dfs -ls output: \${LS_OUTPUT}"
        log "ERROR: Please verify:"
        log "ERROR:   1. Snapshot was successfully exported to destination cluster"
        log "ERROR:   2. HBase root directory is correct: \${HBASE_ROOTDIR}"
        log "ERROR:   3. Destination path exists: \${HBASE_ROOTDIR}/.hbase-snapshot/"
        log "ERROR:   4. You have permissions to access the snapshot directory"
        exit 2
    else
        log "SUCCESS: Snapshot directory verified via hdfs dfs -ls (found files in snapshot)"
        log "INFO: hdfs dfs -test -d may have issues, but snapshot exists and is accessible"
    fi
else
    log "Snapshot found at \${SNAP_PATH}"
fi

# 2. Check and create namespace if needed (for namespace:table format)
if [[ "\$TABLE_NAME" =~ ^([^:]+):(.+)$ ]]; then
    NAMESPACE="\${BASH_REMATCH[1]}"
    TABLE_ONLY="\${BASH_REMATCH[2]}"
    log "Table name contains namespace: \${NAMESPACE}:\${TABLE_ONLY}"
    echo ""

    # Check if namespace exists
    log "Checking if namespace '\${NAMESPACE}' exists..."
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell -n <<< \"list_namespace\""
    NS_LIST=\$(echo "list_namespace" | hbase shell -n 2>/dev/null | grep -i "^\${NAMESPACE}" || echo "")

    if [[ -z "\$NS_LIST" ]]; then
        log "Namespace '\${NAMESPACE}' does not exist -> creating it..."
        echo ""
        echo ">>> EXECUTING COMMAND: hbase shell -n <<< \"create_namespace '\${NAMESPACE}'\""
        echo "create_namespace '\${NAMESPACE}'" | hbase shell -n
        NS_CREATE_RC=\$?
        if [[ \$NS_CREATE_RC -ne 0 ]]; then
            log "ERROR: Failed to create namespace '\${NAMESPACE}' with exit code \$NS_CREATE_RC"
            exit 5
        fi
        log "Namespace '\${NAMESPACE}' created successfully"
    else
        log "Namespace '\${NAMESPACE}' already exists"
    fi
else
    log "Table name does not contain namespace (using default namespace)"
    echo ""
fi

# 3. Check if table exists on destination
log "Checking if table '\${TABLE_NAME}' exists..."
echo ""
echo ">>> EXECUTING COMMAND: hbase shell -n <<< \"exists '\${TABLE_NAME}'\""
EXISTS_OUTPUT=\$(echo "exists '\${TABLE_NAME}'" | hbase shell -n 2>/dev/null | grep -i "true" || echo "")

if echo "\$EXISTS_OUTPUT" | grep -iq "true"; then
    log "Table \${TABLE_NAME} exists -> will disable + restore"
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell -n <<< \"disable '\${TABLE_NAME}'; restore_snapshot '\${SNAP_NAME}'; enable '\${TABLE_NAME}'\""
    echo "
disable '\${TABLE_NAME}'
restore_snapshot '\${SNAP_NAME}'
enable '\${TABLE_NAME}'
" | hbase shell -n
    RC=\$?
    if [[ \$RC -ne 0 ]]; then
        log "ERROR: restore_snapshot failed with exit code \$RC"
        exit 3
    fi
    log "restore_snapshot completed successfully."
else
    log "Table \${TABLE_NAME} does not exist -> will clone from snapshot"
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell -n <<< \"clone_snapshot '\${SNAP_NAME}', '\${TABLE_NAME}'\""
    echo "
clone_snapshot '\${SNAP_NAME}', '\${TABLE_NAME}'
" | hbase shell -n
    RC=\$?
    if [[ \$RC -ne 0 ]]; then
        log "ERROR: clone_snapshot failed with exit code \$RC"
        exit 4
    fi
    log "clone_snapshot completed successfully."
fi

log "Destination replication completed OK"
exit 0
DEST_SCRIPT_EOF

chmod +x "${LOCAL_DEST_SCRIPT}"
if [[ ! -f "${LOCAL_DEST_SCRIPT}" ]]; then
    echo "[ERROR] Stage 4.2 FAILED: Failed to create destination script: ${LOCAL_DEST_SCRIPT}"
    exit 1
fi
echo "[SUCCESS] Stage 4.2 completed: Destination script created on source"
echo ""

# Stage 4.3: Copy script to destination
echo "[4.3] Copy script to destination host..."
REMOTE_SCRIPT="/home/${DEST_SSH_USER}/hbase-apply-snapshot-dest.sh"
echo ">>> EXECUTING COMMAND: scp ${SSH_OPTS_DISPLAY} ${LOCAL_DEST_SCRIPT} ${DEST_SSH_USER}@${DEST_HOST}:${REMOTE_SCRIPT}"
SCP_STDERR=$(scp "${SSH_OPTS_ARR[@]}" "${LOCAL_DEST_SCRIPT}" "${DEST_SSH_USER}@${DEST_HOST}:${REMOTE_SCRIPT}" 2>&1)
SCP_RC=$?
if [[ $SCP_RC -ne 0 ]]; then
    echo "[ERROR] Stage 4.3 FAILED: Failed to copy script to destination"
    echo "[ERROR] SCP command failed with exit code: ${SCP_RC}"
    if [[ -n "$SCP_STDERR" ]]; then
        echo "[ERROR] SCP error output:"
        echo "$SCP_STDERR" | sed 's/^/[ERROR]   /'
    fi
    echo "[ERROR] Please verify SSH access and destination path permissions"
    rm -f "${LOCAL_DEST_SCRIPT}" 2>/dev/null || true
    exit 1
fi

# Set executable permissions on destination
SSH_CHMOD_STDERR=$(ssh "${SSH_OPTS_ARR[@]}" "${DEST_SSH_USER}@${DEST_HOST}" "chmod +x ${REMOTE_SCRIPT}" 2>&1)
SSH_CHMOD_RC=$?
if [[ $SSH_CHMOD_RC -ne 0 ]]; then
    echo "[WARN] Failed to set executable permissions on destination script (exit code: ${SSH_CHMOD_RC})"
    if [[ -n "$SSH_CHMOD_STDERR" ]]; then
        echo "[WARN] SSH error output:"
        echo "$SSH_CHMOD_STDERR" | sed 's/^/[WARN]    /'
    fi
fi

# Verify script was copied
SSH_TEST_STDERR=$(ssh "${SSH_OPTS_ARR[@]}" "${DEST_SSH_USER}@${DEST_HOST}" "test -f ${REMOTE_SCRIPT}" 2>&1)
SSH_TEST_RC=$?
if [[ $SSH_TEST_RC -ne 0 ]]; then
    echo "[ERROR] Stage 4.3 FAILED: Script was not copied successfully to ${REMOTE_SCRIPT}"
    echo "[ERROR] SSH test command failed with exit code: ${SSH_TEST_RC}"
    if [[ -n "$SSH_TEST_STDERR" ]]; then
        echo "[ERROR] SSH error output:"
        echo "$SSH_TEST_STDERR" | sed 's/^/[ERROR]   /'
    fi
    rm -f "${LOCAL_DEST_SCRIPT}" 2>/dev/null || true
    exit 1
fi

# Cleanup local script
rm -f "${LOCAL_DEST_SCRIPT}" 2>/dev/null || true

echo "[SUCCESS] Stage 4.3 completed: Script copied to destination: ${REMOTE_SCRIPT}"
echo ""

# Stage 4.4: Execute remote restore script
# Note: Destination script runs as the SSH user (DEST_SSH_USER), no user switching needed
# Pass DEST_KEYTAB if Kerberos is enabled (for kinit on destination)
echo "[4.4] Execute remote restore script..."
if [[ "$KERBEROS_ENABLED" == true ]] && [[ -n "$DEST_KEYTAB" ]]; then
    echo ">>> EXECUTING COMMAND: ssh ${SSH_OPTS_DISPLAY} ${DEST_SSH_USER}@${DEST_HOST} ${REMOTE_SCRIPT} ${SNAP_NAME} ${TABLE_NAME} ${DEST_KEYTAB}"
    echo "----------------------------------------------------------------------"
    if ssh "${SSH_OPTS_ARR[@]}" \
        "${DEST_SSH_USER}@${DEST_HOST}" \
        "${REMOTE_SCRIPT} ${SNAP_NAME} ${TABLE_NAME} ${DEST_KEYTAB}"; then
        RC=0
    else
        RC=${PIPESTATUS[0]}
    fi
else
    echo ">>> EXECUTING COMMAND: ssh ${SSH_OPTS_DISPLAY} ${DEST_SSH_USER}@${DEST_HOST} ${REMOTE_SCRIPT} ${SNAP_NAME} ${TABLE_NAME}"
    echo "----------------------------------------------------------------------"
    if ssh "${SSH_OPTS_ARR[@]}" \
        "${DEST_SSH_USER}@${DEST_HOST}" \
        "${REMOTE_SCRIPT} ${SNAP_NAME} ${TABLE_NAME}"; then
        RC=0
    else
        RC=${PIPESTATUS[0]}
    fi
fi

echo "----------------------------------------------------------------------"

if [[ $RC -ne 0 ]]; then
    echo "[ERROR] Stage 4.4 FAILED: Remote restore failed with exit code $RC"
    echo "[ERROR] Check the log file for details: ${LOG_FILE}"
    echo "[ERROR] Verify remote script execution and permissions on ${DEST_HOST}"
    exit $RC
else
    echo "[SUCCESS] Stage 4.4 completed: Remote restore executed successfully"
fi
echo "[SUCCESS] STEP 4 completed: Remote restore finished"
echo "         Destination host: ${DEST_HOST}"
echo "         Snapshot: ${SNAP_NAME}"
echo "         Table: ${TABLE_NAME}"
echo "----------------------------------------------------------------------"

    # Track success for this table
    set -e  # Re-enable exit-on-error
    trap - ERR  # Remove the error trap

    if [[ "$TABLE_PROCESSING_FAILED" == true ]]; then
        log_error "Table ${TABLE_INDEX}/${TOTAL_TABLES} FAILED: ${TABLE_NAME}"
        FAILED_TABLES+=("$TABLE_NAME")
    else
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        log_success "Table ${TABLE_INDEX}/${TOTAL_TABLES} completed successfully: ${TABLE_NAME}"
    fi

done  # End of main processing loop

# Final summary
echo ""
echo "======================================================================"
echo "Final Processing Summary"
echo "======================================================================"
echo "Total Tables: ${TOTAL_TABLES}"
echo "Successful: ${SUCCESS_COUNT}"
echo "Failed: $((TOTAL_TABLES - SUCCESS_COUNT))"
if [[ ${#FAILED_TABLES[@]} -gt 0 ]]; then
    echo "Failed Tables:"
    for failed_tbl in "${FAILED_TABLES[@]}"; do
        echo "  - ${failed_tbl}"
    done
fi
echo "======================================================================"

# Calculate execution time and final summary
log_script_summary

if [[ $SUCCESS_COUNT -eq $TOTAL_TABLES ]]; then
    log_success "HBase Cluster Replication Completed Successfully"
    log_success "All ${TOTAL_TABLES} table(s) replicated successfully"
    exit 0
else
    log_error "HBase Cluster Replication Completed with Errors"
    log_error "Successfully replicated ${SUCCESS_COUNT} out of ${TOTAL_TABLES} table(s)"
    if [[ ${#FAILED_TABLES[@]} -gt 0 ]]; then
        log_error "Failed tables:"
        for table in "${FAILED_TABLES[@]}"; do
            log_error "  • $table"
        done
    fi
    exit 1
fi
