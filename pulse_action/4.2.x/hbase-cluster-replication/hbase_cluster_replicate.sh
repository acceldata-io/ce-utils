#!/bin/bash
###############################################################################
# HBase Cluster Replication Script
#
# This script performs HBase table replication between clusters using snapshots.
# Snapshot is exported via ExportSnapshot (MapReduce), then restored on the
# destination cluster from the source node via destination ZooKeeper quorum.
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
#                                <DEST_HBASE_SNAPSHOT_DIR> <DEST_ZK_QUORUM> <DEST_ZK_ZNODE> \
#                                <KERBEROS_ENABLED> [USER] [MAPPERS] [MR_QUEUE] [EXPORT_OPTS]
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
#   6) DEST_ZK_QUORUM         - Destination ZooKeeper quorum (comma-separated hosts)
#                              e.g., odp100.acceldata.dvl,odp200.acceldata.dvl,odp300.acceldata.dvl
#   7) DEST_ZK_ZNODE          - Destination ZooKeeper znode parent (e.g., /hbase-secure)
#   8) KERBEROS_ENABLED       - Enable Kerberos authentication: "yes" or "no" (mandatory)
#
# Optional arguments (can also use environment variables):
#   9) USER                  - User to run commands as (for non-kerberos clusters, uses su)
#   10) MAPPERS               - Number of ExportSnapshot mappers (default: 8)
#   11) MR_QUEUE              - MapReduce queue name (default: default)
#   12) EXPORT_OPTS           - ExportSnapshot options (default: --chuser hbase --chgroup hbase)
#   13) LOG_DIR                - Log directory path (default: /var/log/hbase-replication)
#
# Notes:
#   - ZooKeeper port is hardcoded to 2181.
#   - MR job tags are auto-generated as: pulse_hbase_replication,<SNAP_NAME>
#   - For Kerberos clusters (KERBEROS_ENABLED=yes):
#     Plugin sets KRB5CCNAME from ccache_file_path; script auto-detects valid tickets.
#     Cross-realm trust must be configured between clusters.
#   - For non-Kerberos clusters (KERBEROS_ENABLED=no): USER should be set to run commands as specific user
#     * Commands use 'su' to switch to USER (root won't have access/authorization)
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
DEST_ZK_QUORUM="${6:-${DEST_ZK_QUORUM:-}}"
DEST_ZK_ZNODE="${7:-${DEST_ZK_ZNODE:-}}"

# Required Kerberos enabled flag (can also use environment variable)
# Accepts: yes, no, true, false, 1, 0 (case insensitive, but must be provided)
KERBEROS_ENABLED_FLAG="${8:-${KERBEROS_ENABLED:-}}"

# Optional user parameter (for non-kerberos clusters - uses su instead of sudo)
USER="${9:-${USER:-${RUN_AS_USER:-}}}"

# Optional parameters from positional arguments (with env var fallback and defaults)
MAPPERS="${10:-${MAPPERS:-8}}"
MR_QUEUE="${11:-${MR_QUEUE:-default}}"
EXPORT_OPTS="${12:-${EXPORT_OPTS:---chuser hbase --chgroup hbase}}"

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
    echo "[ERROR] Invalid KERBEROS_ENABLED value: ${KERBEROS_ENABLED_FLAG}. Expected 'yes' or 'no'" >&2
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

LOG_DIR="${13:-/var/log/hbase-replication}"

mkdir -p "$LOG_DIR"
SESSION_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_LOG_FILE="$LOG_DIR/hbase_cluster_replicate_session_${SESSION_TIMESTAMP}.log"

exec > >(tee -a "$SESSION_LOG_FILE") 2>&1

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
    echo "Session Log: $SESSION_LOG_FILE"
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

# Split EXPORT_OPTS into EXPORT_OPTS_ARR using default word splitting.
parse_export_opts() {
    local opts="${EXPORT_OPTS:-}"
    EXPORT_OPTS_ARR=()
    [[ -z "$opts" ]] && return 0
    local _saved_ifs="$IFS"
    IFS=$' '
    read -r -a EXPORT_OPTS_ARR <<< "$opts"
    IFS="$_saved_ifs"
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

# -----------------------------------------------------------------------------
# Detect if Kerberos is enabled by checking for valid Kerberos tickets
# -----------------------------------------------------------------------------
detect_kerberos_enabled() {
    # Kerberos tooling must exist
    if ! command -v klist >/dev/null 2>&1; then
        log "[DEBUG] klist not found; Kerberos not available"
        return 1
    fi

    # ---------------------------------------------------------
    # 1) If KRB5CCNAME is already set, trust but verify it
    # ---------------------------------------------------------
    if [[ -n "${KRB5CCNAME:-}" ]]; then
        if klist -s 2>/dev/null; then
            export KRB5CCNAME="$KRB5CCNAME"
            log "[INFO] Kerberos detected via existing KRB5CCNAME=$KRB5CCNAME"
            echo "[INFO] Kerberos detected via existing KRB5CCNAME=$KRB5CCNAME"
            return 0
        else
            log "[WARN] KRB5CCNAME is set but invalid: $KRB5CCNAME"
            echo "[WARN] KRB5CCNAME is set but invalid: $KRB5CCNAME"
        fi
    fi

    # ---------------------------------------------------------
    # 2) Acceldata Pulse Actions: scan known cache directory
    # ---------------------------------------------------------
    local pulse_cache_dir="/opt/pulse/actions/tmp"

    # If default path doesn't exist, try to get PULSE_HOME from /etc/default/hydra
    if [[ ! -d "$pulse_cache_dir" ]]; then
        if [[ -f "/etc/default/hydra" ]]; then
            local pulse_home
            # Extract PULSE_HOME value, handling both quoted and unquoted values
            pulse_home=$(grep "^PULSE_HOME=" /etc/default/hydra 2>/dev/null | head -1 | sed -E 's/^PULSE_HOME=//' | sed -E 's/^["'\'']|["'\'']$//g' || echo "")
            if [[ -n "$pulse_home" ]]; then
                pulse_cache_dir="${pulse_home}/actions/tmp"
                log "[DEBUG] Using PULSE_HOME from /etc/default/hydra: $pulse_home"
                echo "[DEBUG] Using PULSE_HOME from /etc/default/hydra: $pulse_home"
            fi
        fi
    fi

    if [[ -d "$pulse_cache_dir" ]]; then
            # Iterate newest-first (by modification time), pick first valid cache
            while IFS= read -r cc; do
                [[ -f "$cc" ]] || continue
                if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                    export KRB5CCNAME="$cc"
                    echo "[INFO] Kerberos detected via Pulse cache: $KRB5CCNAME"
                    return 0
                fi
            done < <(ls -t "$pulse_cache_dir"/krb5cc_* 2>/dev/null)
            echo "[DEBUG] No valid Kerberos cache found in $pulse_cache_dir"
        fi

    # ---------------------------------------------------------
    # 3) Explicit fallback: /tmp/krb5cc_<uid>
    # ---------------------------------------------------------
    local uid cc_tmp
    uid="$(id -u)"
    cc_tmp="/tmp/krb5cc_${uid}"

    if [[ -f "$cc_tmp" ]]; then
        if KRB5CCNAME="$cc_tmp" klist -s 2>/dev/null; then
            export KRB5CCNAME="$cc_tmp"
            log "[INFO] Kerberos detected via explicit default cache: $KRB5CCNAME"
            echo "[INFO] Kerberos detected via explicit default cache: $KRB5CCNAME"
            return 0
        else
            log "[DEBUG] Found $cc_tmp but it does not contain valid tickets"
        fi
    fi

    # ---------------------------------------------------------
    # 4) Final fallback: whatever klist resolves by default
    # ---------------------------------------------------------
    if klist -s 2>/dev/null; then
        log "[INFO] Kerberos detected via implicit default credential cache"
        echo "[INFO] Kerberos detected via implicit default credential cache"
        return 0
    fi

    log "[INFO] Kerberos not detected (no valid credential cache found)"
    echo "[INFO] Kerberos not detected (no valid credential cache found)"
    return 1
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

# Execute HBase shell against DESTINATION cluster via ZooKeeper (port 2181 hardcoded).
execute_hbase_shell_dest() {
    local hbase_cmd="$1"
    local zk_args=(
        -D "hbase.zookeeper.quorum=${DEST_ZK_QUORUM}"
        -D "hbase.zookeeper.property.clientPort=2181"
        -D "zookeeper.znode.parent=${DEST_ZK_ZNODE}"
    )

    if [[ "$KERBEROS_ENABLED" == true ]]; then
        echo "$hbase_cmd" | hbase shell "${zk_args[@]}"
    elif [[ "$USE_USER_SWITCHING" == true ]] && [[ -n "$USER" ]]; then
        local zk_args_str="-D hbase.zookeeper.quorum=${DEST_ZK_QUORUM} -D hbase.zookeeper.property.clientPort=2181 -D zookeeper.znode.parent=${DEST_ZK_ZNODE}"
        echo "$hbase_cmd" | su - "$USER" -c "hbase shell ${zk_args_str}"
    else
        echo "$hbase_cmd" | hbase shell "${zk_args[@]}"
    fi
}

###############################################################################
# Input Validation
###############################################################################

# Validate required parameters (all required parameters including KERBEROS_ENABLED)
if [[ -z "$TABLE_NAME" ]] || [[ -z "$SNAP_PREFIX" ]] || [[ -z "$DEST_NN_URI" ]] || \
   [[ -z "$DEST_HBASE_SNAPSHOT_DIR" ]] || [[ -z "$DEST_ZK_QUORUM" ]] || [[ -z "$DEST_ZK_ZNODE" ]] || \
   [[ -z "$KERBEROS_ENABLED_FLAG" ]]; then
    log_error "Missing required arguments"
    echo ""
    echo "Usage: $0 <TABLE_NAME> <SNAP_PREFIX> [RETENTION] <DEST_NN_URI> \\"
    echo "              <DEST_HBASE_SNAPSHOT_DIR> <DEST_ZK_QUORUM> <DEST_ZK_ZNODE> \\"
    echo "              <KERBEROS_ENABLED> [USER] [MAPPERS] [MR_QUEUE] [EXPORT_OPTS]"
    echo ""
    echo "Required arguments:"
    echo "  1) TABLE_NAME             - HBase table name (table for default namespace, or namespace:table)"
    echo "  2) SNAP_PREFIX            - Snapshot name prefix"
    echo "  3) RETENTION              - Number of snapshots to keep in rotation (default: 1)"
    echo "  4) DEST_NN_URI            - Destination namenode URI"
    echo "  5) DEST_HBASE_SNAPSHOT_DIR - Destination HBase snapshot directory"
    echo "  6) DEST_ZK_QUORUM         - Destination ZooKeeper quorum (comma-separated)"
    echo "  7) DEST_ZK_ZNODE          - Destination ZNode parent (e.g. /hbase-secure)"
    echo "  8) KERBEROS_ENABLED       - Enable Kerberos: 'yes' or 'no' (mandatory)"
    echo ""
    echo "Optional arguments (can also use environment variables):"
    echo "  9) USER                  - User to run commands as (for non-kerberos, uses su)"
    echo "  10) MAPPERS               - Number of ExportSnapshot mappers (default: 8)"
    echo "  11) MR_QUEUE              - MapReduce queue name (default: default)"
    echo "  12) EXPORT_OPTS           - ExportSnapshot options (default: --chuser hbase --chgroup hbase)"
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

# Validate DEST_ZK_QUORUM and DEST_ZK_ZNODE
if [[ -z "$DEST_ZK_QUORUM" ]] || [[ "$DEST_ZK_QUORUM" =~ ^[[:space:]]+$ ]]; then
    log_error "Invalid DEST_ZK_QUORUM: ${DEST_ZK_QUORUM}"
    exit 1
fi
if [[ ! "$DEST_ZK_ZNODE" =~ ^/ ]]; then
    log_error "DEST_ZK_ZNODE must start with /: ${DEST_ZK_ZNODE}"
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
else
    echo "Pattern Type     : Single table"
fi
echo "Snapshot Prefix  : ${SNAP_PREFIX}"
echo "Snapshot Retention : ${RETENTION} (keep last ${RETENTION} snapshot(s))"
if [[ "$KERBEROS_ENABLED" == true ]]; then
    echo "Kerberos Enabled : yes"
    echo "Mode             : Kerberos enabled "
else
    echo "Kerberos Enabled : no"
    echo "Mode             : Non-Kerberos"
    if [[ "$USE_USER_SWITCHING" == true ]]; then
        echo "Run as User      : ${USER}"
    fi
fi
echo "Destination ZK   : ${DEST_ZK_QUORUM}"
echo "Destination ZNode: ${DEST_ZK_ZNODE}"
echo "Mappers          : ${MAPPERS}"
echo "MR Queue         : ${MR_QUEUE}"
echo "Session Log      : ${SESSION_LOG_FILE}"
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
# (for Kerberos clusters, this happens after credential cache detection; for non-kerberos, hbase shell can run directly)

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

    if detect_kerberos_enabled; then
        log_success "Stage 1.1 completed: Valid Kerberos credential cache found"
        if [[ -n "${KRB5CCNAME:-}" ]]; then
            log_info "Using Kerberos cache: $KRB5CCNAME"
        fi
    else
        log_error "Kerberos is enabled but no valid credential cache was found"
        log_error "Chain krb action before replication so KRB5CCNAME is set (same as HDFS DR)"
        exit 1
    fi

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
    echo "[INFO] Kerberos is disabled - skipping credential cache detection"
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

parse_export_opts

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

# Record a per-table failure and append to FAILED_TABLES (caller must `continue` after).
mark_table_failed() {
    log_error "$1"
    FAILED_TABLES+=("$TABLE_NAME")
}

TOTAL_TABLES=${#TABLES_TO_REPLICATE[@]}
SUCCESS_COUNT=0
FAILED_TABLES=()

for ((table_idx = 0; table_idx < TOTAL_TABLES; table_idx++)); do
    TABLE_NAME="${TABLES_TO_REPLICATE[$table_idx]}"
    TABLE_INDEX=$((table_idx + 1))

    set +e  # Disable exit-on-error for per-table failure handling

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
    SNAPSHOT_INFO=$(get_next_snapshot_info "${TABLE_SNAP_PREFIX}" "${TABLE_NAME}" "${RETENTION}")
    snap_info_rc=$?
    if [[ $snap_info_rc -ne 0 ]] || [[ -z "$SNAPSHOT_INFO" ]]; then
        mark_table_failed "Failed to get snapshot info for table: ${TABLE_NAME} (exit ${snap_info_rc})"
        continue
    fi

    SNAP_NUMBER=$(echo "$SNAPSHOT_INFO" | cut -d':' -f1)
    OLDEST_SNAP_TO_DELETE=$(echo "$SNAPSHOT_INFO" | cut -d':' -f2)
    SNAP_NAME="${TABLE_SNAP_PREFIX}_${SNAP_NUMBER}"

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
    HBASE_OUT=$(execute_hbase_shell "snapshot '${TABLE_NAME}', '${SNAP_NAME}'" 2>&1)
    SNAPSHOT_RC=$?
    echo "$HBASE_OUT"
    echo "----------------------------------------------------------------------"
    if [[ $SNAPSHOT_RC -ne 0 ]] || echo "$HBASE_OUT" | grep -q '^ERROR:'; then
        mark_table_failed "Stage 2.2 FAILED: Snapshot creation failed for table ${TABLE_NAME} with exit code ${SNAPSHOT_RC}. Table may not exist or may be in use"
        continue
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

MR_JOB_TAGS="pulse_hbase_replication,${SNAP_NAME}"

# Build the ExportSnapshot command display string
EXPORT_CMD_DISPLAY="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -Dmapreduce.job.queuename=${MR_QUEUE} -Dmapreduce.job.tags=${MR_JOB_TAGS} -snapshot ${SNAP_NAME} -copy-to ${DEST_HDFS_PATH} -mappers ${MAPPERS}"
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
          -Dmapreduce.job.queuename="${MR_QUEUE}" \
          -Dmapreduce.job.tags="${MR_JOB_TAGS}" \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}" \
          "${EXPORT_OPTS_ARR[@]}"; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    else
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -Dmapreduce.job.queuename="${MR_QUEUE}" \
          -Dmapreduce.job.tags="${MR_JOB_TAGS}" \
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
        EXPORT_CMD_STR="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -Dmapreduce.job.queuename='${MR_QUEUE}' -Dmapreduce.job.tags='${MR_JOB_TAGS}' -snapshot '${SNAP_NAME}' -copy-to '${DEST_HDFS_PATH}' -mappers '${MAPPERS}' ${EXPORT_OPTS}"
    else
        EXPORT_CMD_STR="hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot -Dmapreduce.job.queuename='${MR_QUEUE}' -Dmapreduce.job.tags='${MR_JOB_TAGS}' -snapshot '${SNAP_NAME}' -copy-to '${DEST_HDFS_PATH}' -mappers '${MAPPERS}'"
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
          -Dmapreduce.job.queuename="${MR_QUEUE}" \
          -Dmapreduce.job.tags="${MR_JOB_TAGS}" \
          -snapshot "${SNAP_NAME}" \
          -copy-to  "${DEST_HDFS_PATH}" \
          -mappers "${MAPPERS}" \
          "${EXPORT_OPTS_ARR[@]}"; then
            EXPORT_RC=0
        else
            EXPORT_RC=$?
        fi
    else
        if hbase org.apache.hadoop.hbase.snapshot.ExportSnapshot \
          -Dmapreduce.job.queuename="${MR_QUEUE}" \
          -Dmapreduce.job.tags="${MR_JOB_TAGS}" \
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
    mark_table_failed "Stage 3.1 FAILED: ExportSnapshot failed for table ${TABLE_NAME} with exit code ${EXPORT_RC}"
    continue
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
# Run Restore on Destination cluster (via destination ZooKeeper)
###############################################################################
echo ""
echo "======================================================================"
echo "STEP 4: Restore Snapshot on Destination Cluster (via ZooKeeper)"
echo "======================================================================"
echo "Destination ZK Quorum : ${DEST_ZK_QUORUM}"
echo "Destination ZK Port   : 2181"
echo "Destination ZNode     : ${DEST_ZK_ZNODE}"
echo "Snapshot              : ${SNAP_NAME}"
echo "Table                 : ${TABLE_NAME}"
echo ""

# Check and create namespace if needed (for namespace:table format)
if [[ "$TABLE_NAME" =~ ^([^:]+):(.+)$ ]]; then
    NAMESPACE="${BASH_REMATCH[1]}"
    TABLE_ONLY="${BASH_REMATCH[2]}"
    echo "[INFO] Table name contains namespace: ${NAMESPACE}:${TABLE_ONLY}"
    echo ""

    echo "[INFO] Checking if namespace '${NAMESPACE}' exists..."
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell [dest ZK] <<< \"list_namespace\""
    NS_LIST=$(execute_hbase_shell_dest "list_namespace" 2>/dev/null | grep -i "^${NAMESPACE}" || echo "")

    if [[ -z "$NS_LIST" ]]; then
        echo "[INFO] Namespace '${NAMESPACE}' does not exist -> creating it..."
        echo ""
        echo ">>> EXECUTING COMMAND: hbase shell [dest ZK] <<< \"create_namespace '${NAMESPACE}'\""
        HBASE_OUT=$(execute_hbase_shell_dest "create_namespace '${NAMESPACE}'" 2>&1)
        NS_CREATE_RC=$?
        echo "$HBASE_OUT"
        if [[ $NS_CREATE_RC -ne 0 ]] || echo "$HBASE_OUT" | grep -q '^ERROR:'; then
            mark_table_failed "Failed to create namespace '${NAMESPACE}' for table ${TABLE_NAME} with exit code ${NS_CREATE_RC}"
            continue
        fi
        echo "[SUCCESS] Namespace '${NAMESPACE}' created successfully"
    else
        echo "[INFO] Namespace '${NAMESPACE}' already exists"
    fi
else
    echo "[INFO] Table name does not contain namespace (using default namespace)"
    echo ""
fi

# Check if table exists on destination
echo "[INFO] Checking if table '${TABLE_NAME}' exists..."
echo ""
echo ">>> EXECUTING COMMAND: hbase shell [dest ZK] <<< \"exists '${TABLE_NAME}'\""
EXISTS_OUTPUT=$(execute_hbase_shell_dest "exists '${TABLE_NAME}'" 2>/dev/null | grep -i "true" || echo "")

if echo "$EXISTS_OUTPUT" | grep -iq "true"; then
    echo "[INFO] Table ${TABLE_NAME} exists -> will disable + restore"
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell [dest ZK] <<< \"disable '${TABLE_NAME}'; restore_snapshot '${SNAP_NAME}'; enable '${TABLE_NAME}'\""
    echo ""
    HBASE_OUT=$(execute_hbase_shell_dest "
      disable '${TABLE_NAME}'
      restore_snapshot '${SNAP_NAME}'
      enable '${TABLE_NAME}'
      " 2>&1)
    RC=$?
    echo "$HBASE_OUT"
    if [[ $RC -ne 0 ]] || echo "$HBASE_OUT" | grep -q '^ERROR:'; then
        mark_table_failed "restore_snapshot failed for table ${TABLE_NAME} with exit code ${RC}"
        continue
    fi
    echo "[SUCCESS] restore_snapshot completed successfully."
else
    echo "[INFO] Table ${TABLE_NAME} does not exist -> will clone from snapshot"
    echo ""
    echo ">>> EXECUTING COMMAND: hbase shell [dest ZK] <<< \"clone_snapshot '${SNAP_NAME}', '${TABLE_NAME}'\""
    echo "----------------------------------------------------------------------"
    HBASE_OUT=$(execute_hbase_shell_dest "
clone_snapshot '${SNAP_NAME}', '${TABLE_NAME}'
" 2>&1)
    RC=$?
    echo "$HBASE_OUT"
    echo "----------------------------------------------------------------------"
    if [[ $RC -ne 0 ]] || echo "$HBASE_OUT" | grep -q '^ERROR:'; then
        mark_table_failed "clone_snapshot failed for table ${TABLE_NAME} with exit code ${RC}"
        continue
    fi
    echo "[SUCCESS] clone_snapshot completed successfully."
fi
echo "[SUCCESS] STEP 4 completed: Destination cluster updated"
echo "         Destination ZK: ${DEST_ZK_QUORUM}"
echo "         Snapshot: ${SNAP_NAME}"
echo "         Table: ${TABLE_NAME}"
echo "----------------------------------------------------------------------"

    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    log_success "Table ${TABLE_INDEX}/${TOTAL_TABLES} completed successfully: ${TABLE_NAME}"

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
