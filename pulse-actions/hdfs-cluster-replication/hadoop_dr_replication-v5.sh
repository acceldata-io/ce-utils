#!/bin/bash
# -----------------------------------------------------------------------------
# Hadoop Disaster Recovery Continuous Replication Script
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
#
# Description:
#   This script automates continuous data replication between a primary and a
#   DR Hadoop cluster using HDFS snapshots and incremental DistCp transfers.
#
# Usage:
#   ./hadoop_dr_replication.sh \
#     "<SOURCE_NN_HOST:PORT>"   \
#     "<DEST_NN_HOST:PORT>"     \
#     "<DIR1,DIR2,...>"         \
#     "<SNAP_PREFIX>"           \
#     <SNAP_RETAIN>            \
#     "<HDFS_USER>"            \
#     "<DISTCP_USER>"          \
#     "<COPY_OPTS>"            \
#     "<YARN_QUEUE>"           \
#     "<LOG_PATH>"             \
#     "<AUTO_FULL_DISTCP>"     \
#     "<ROLLBACK_ON_FAILURE>"  \
#     "<DIR_BOOTSTRAP_MODE>"   \
#     "<KERBEROS_ENABLED>"
#
# Positional arguments (order matters):
#   1) SOURCE_NN_HOST:PORT  - Source HDFS NameNode URI (example: prod-namenode-1.example.com:8020)
#   2) DEST_NN_HOST:PORT    - Destination HDFS NameNode URI (example: dr-namenode-1.example.com:8020)
#   3) DIR1,DIR2,...        - Comma-separated list of absolute HDFS paths to replicate
#   4) SNAP_PREFIX          - Snapshot name prefix used for incremental snapshots (example: dr_snap)
#   5) SNAP_RETAIN          - Number of snapshots to retain on each cluster (integer, e.g. 3)
#   6) HDFS_USER            - User to run `hdfs dfs` / `hdfs dfsadmin` commands as (default: "hdfs")
#                              Also used for `hadoop distcp` if DISTCP_USER is not provided
#   7) DISTCP_USER          - User to run `hadoop distcp` as (default: same as HDFS_USER)
#                              If not provided or empty, will use HDFS_USER value
#   8) COPY_OPTS            - Additional DistCp options (quoted string)
#   9) YARN_QUEUE           - YARN queue name for DistCp jobs (default: "default")
#   10) LOG_PATH            - Path to log file (default: /var/log/hadoop-dr-replicate.log)
#   11) AUTO_FULL_DISTCP    - Auto-run full DistCp on initial baseline (optional, default: "no")
#                              Values: "yes" or "no"
#   12) ROLLBACK_ON_FAILURE - Enable automatic rollback on snapshot-modified errors (optional, default: "no")
#                              Values: "yes" or "no"
#   13) DIR_BOOTSTRAP_MODE  - Auto-bootstrap missing directories (optional, default: "yes")
#                              Values: "yes" (auto-create) or "no" (manual instructions)
#   14) KERBEROS_ENABLED     - Explicit Kerberos mode (REQUIRED)
#                              Values: "yes" (Kerberos enabled) or "no" (Kerberos disabled / sudo mode)
#                              This script does NOT auto-detect Kerberos.
#                              Must be provided via CLI argument or KERBEROS_ENABLED env var.
#
# Notes:
#   - AUTO_FULL_DISTCP controls whether full DistCp runs automatically on initial run.
#     Can be set via: 11th argument, environment variable, or defaults to "no".
#     WARNING: For large datasets, DistCp can take significant time to complete.
#   - ROLLBACK_ON_FAILURE controls automatic rollback on snapshot-modified errors.
#     Can be set via: 12th argument, environment variable, or defaults to "no".
#   - DIR_BOOTSTRAP_MODE controls how missing destination dirs are handled.
#     Can be set via: 13th argument, environment variable, or defaults to "yes".
#     Values: "yes" (auto-create dirs) or "no" (show manual instructions).
#   - Kerberos mode is explicit and mandatory. The script does not auto-detect Kerberos.
#     Operators must specify the mode using the 14th argument or the KERBEROS_ENABLED
#     environment variable to ensure deterministic behavior.
#
# Environment Variables (Optional):
#   - SOURCE_HTTP_SCHEME    - HTTP scheme for source cluster JMX access (default: http)
#     Example: export SOURCE_HTTP_SCHEME=https
#   - SOURCE_NN_WEB_PORT    - NameNode web UI port for source cluster (default: 50070)
#     Example: export SOURCE_NN_WEB_PORT=9870
#   - DEST_HTTP_SCHEME      - HTTP scheme for destination cluster JMX access (default: http)
#     Example: export DEST_HTTP_SCHEME=https
#   - DEST_NN_WEB_PORT      - NameNode web UI port for destination cluster (default: 50070)
#     Example: export DEST_NN_WEB_PORT=9870
#
#   Note: SOURCE_HTTP_SCHEME/PORT and DEST_HTTP_SCHEME/PORT are intentionally separate to support
#   cross-cluster replication between different Hadoop distributions or versions with different JMX
#   configurations. Common scenarios:
#
#   - ODP Source + CDP Destination:
#       * ODP typically uses: http scheme, port 50070 (or 9870 in newer versions)
#       * CDP typically uses: https scheme, port 9870
#       * Set: SOURCE_HTTP_SCHEME=http SOURCE_NN_WEB_PORT=50070
#               DEST_HTTP_SCHEME=https DEST_NN_WEB_PORT=9870
#
#   - Same distribution but different ports:
#       * Set the appropriate scheme and port for each cluster independently
#
#   - Default behavior (no variables set):
#       * Both clusters use http scheme and port 50070
#       * Works for homogeneous clusters with standard HDFS configuration
#
# Example:
#   ./hadoop_dr_replication.sh \
#     "prod-namenode-1.example.com:8020" \
#     "dr-namenode-1.example.com:8020" \
#     "/data/warehouse,/data/analytics" \
#     "dr_snap" 3 "hdfs" "hdfs" "-strategy dynamic -direct -update -pugptx" \
#     "default" \
#     "/var/log/hadoop-dr-replicate.log" \
#     "no" "no" "yes" \
#     "no"
#
# Purpose & properties:
#   - Idempotent and safe for repeated runs.
#   - Ensures snapshot capability is enabled once on both clusters (idempotent).
#   - Creates baseline snapshots if missing and instructs operator for initial
#     full DistCp when necessary.
#   - Performs incremental snapshot diffs and DistCp, advancing internal state only
#     after successful DistCp for a directory.
#   - Attempts a single automatic rollback for snapshot-modified failures if
#     ROLLBACK_ON_FAILURE is enabled (uses per-failure markers to prevent retrying
#     the exact same failure, but allows rollback for new failures on the same directory).
#
# Stages (high-level):
#   Stage 0: Initialization & argument parsing
#            - Parse CLI args and set defaults
#   Stage 1: Cluster health checks
#            - Validate NameNode JMX accessibility and HA ACTIVE state (if available)
#   Stage 2: Enable snapshot capability (idempotent, per-directory)
#            - Allow snapshot on source and destination directories
#            - Each directory has its own lock file to track snapshot enablement status
#            - If destination dir missing:
#                * In "yes" mode (auto-bootstrap): create the dir on destination with same owner/permissions
#                * In "no" mode (manual): print full DistCp instructions and exit for operator
#            - Create per-directory lock files to avoid re-running snapshot enablement repeatedly
#   Stage 3: Baseline snapshot creation (idempotent)
#            - Create initial snapshot ${SNAP_PREFIX}_0 on source and destination for
#              directories lacking a state file.
#            - If baseline snapshots were created:
#                * If AUTO_FULL_DISTCP="yes": Automatically runs full DistCp for each
#                  directory, creates new baseline snapshot on destination (post-DistCp state),
#                  then exits. Operator must re-run script for incremental sync.
#                  WARNING: Can take significant time for large datasets.
#                * If AUTO_FULL_DISTCP="no" (default): Script exits and instructs
#                  operator to run a **full DistCp** for each directory (manual step)
#   Stage 4: Incremental sync loop (per-directory)
#            For each directory:
#              4a) Ensure last known snapshot exists on destination (create if missing)
#              4b) Create the next snapshot on the source (next snapshot name)
#              4c) Run DistCp with -diff from last -> next (stderr captured to temp file
#                  for error analysis, and displayed in real-time via global redirection)
#              4d) On success, create the next snapshot on destination
#              4e) Advance internal state (persist next snapshot name)
#              4f) Cleanup old snapshots on source (retain SNAP_RETAIN most recent)
#              4g) Cleanup old snapshots on destination (retain SNAP_RETAIN most recent)
#            If snapshot-modified error detected and ROLLBACK_ON_FAILURE="yes":
#              - Attempt one-time automatic rollback (per-failure marker prevents retries)
#              - After rollback, retry DistCp once
#   Stage 5: Completion and logging
#
# Operator checklist (before running):
#   1. Ensure the DistCp user has superuser privileges on both clusters.
#   2. Verify network connectivity and Kerberos tickets (if applicable).
#   3. Run the script with the correct arguments (see Usage).
#   4. If the script creates baseline snapshots:
#        - If AUTO_FULL_DISTCP="yes": Script will automatically run full DistCp.
#          Monitor logs as this can take significant time for large datasets.
#        - If AUTO_FULL_DISTCP="no" (default): Run the full DistCp commands
#          printed by the script for each directory, then re-run the script.
#   5. Monitor the log file specified (10th positional argument: LOG_PATH).
#
# Pre-requisites:
#   • The DistCp/HDFS user must be superuser (or in superusergroup) on both clusters.
#   • Snapshot capability supported by HDFS and allowed for target directories.
#   • Network connectivity and Kerberos credentials must be in place for HDFS and JMX.
#
# -----------------------------------------------------------------------------
# ./hadoop_dr_replication.sh "prod-namenode-1.example.com:8020" "dr-namenode-1.example.com:8020" "/data/warehouse,/data/analytics" "dr_snap" 3 "hdfs" "hdfs" "-update -pugpx" "default" "/var/log/hadoop-dr-replicate.log" "no" "no" "yes" "no"
#

set -euo pipefail
SCRIPT_START_TS=$(date +%s)

# -----------------------------------------------------------------------------
# Early logging helpers (must be defined before first use)
# NOTE: Before exec/tee is enabled, errors should go directly to stderr
# -----------------------------------------------------------------------------
log() {
    local log_msg
    if [[ -n "${CURRENT_STAGE:-}" ]]; then
        log_msg="$(date '+%F %T') [$CURRENT_STAGE] $*"
    else
        log_msg="$(date '+%F %T') $*"
    fi
    echo "$log_msg"
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_stage() {
    local stage_num="$1"
    local stage_name="$2"
    CURRENT_STAGE="Stage $stage_num: $stage_name"
    echo "" >&2
    echo "────────────────────────────────────────────" >&2
    echo "STAGE $stage_num: $stage_name" >&2
    echo "────────────────────────────────────────────" >&2
}

log_stage_complete() {
    local stage_num="$1"
    local stage_name="$2"
    CURRENT_STAGE=""
    echo "" >&2
    echo "────────────────────────────────────────────" >&2
    echo "[STAGE $stage_num COMPLETED] $stage_name" >&2
    echo "────────────────────────────────────────────" >&2
    echo "" >&2
}

log_stage_failed() {
    local stage_num="$1"
    local stage_name="$2"
    local error_msg="${3:-Unknown error}"
    SCRIPT_FAILED="yes"
    FAILURE_REASON="Stage $stage_num ($stage_name): $error_msg"
    CURRENT_STAGE=""
    echo "" >&2
    echo "────────────────────────────────────────────" >&2
    echo "[STAGE $stage_num FAILED] $stage_name" >&2
    echo "Error: $error_msg" >&2
    echo "────────────────────────────────────────────" >&2
    echo "" >&2
}

# -----------------------------------------------------------------------------
# Stage 0: Initialization & configurable variables (can be overridden by CLI)
# -----------------------------------------------------------------------------
SOURCE_CLUSTER="${1:-production-1.adsre.com:8020}"
DEST_CLUSTER="${2:-dr-1.adsre.com:8020}"
SOURCE_DIRS_RAW="${3:-/demo/oldfiles}"
SNAP_PREFIX="${4:-dr_snap}"
SNAP_RETAIN="${5:-3}"
HDFS_USER="${6:-hdfs}"
DISTCP_USER="${7:-hdfs}"
COPY_OPTS="${8:--strategy dynamic -direct -update -pugptx -skipcrccheck}"
YARN_QUEUE="${9:-default}"
LOG="${10:-/var/log/hadoop-dr-replicate.log}"

#
# Configuration flags (can be set via CLI args 11-13, environment variables, or defaults)
# Priority: 1) CLI argument, 2) Environment variable, 3) Default value
AUTO_FULL_DISTCP_ARG="${11:-}"
ROLLBACK_ON_FAILURE_ARG="${12:-}"
DIR_BOOTSTRAP_MODE_ARG="${13:-}"

###############################################################################
# Kerberos control source (priority: CLI arg 14 -> env var -> default)
# Default is "no" to ensure safe sudo-based execution unless explicitly enabled
###############################################################################
KERBEROS_ENABLED_ARG="${14:-${KERBEROS_ENABLED:-no}}"

#
# ROLLBACK_ON_FAILURE for DR Cluster is a safeguard for handling the common snapshot-modified error
# "DistCp: The target has been modified since snapshot" during DistCp (when DR data has diverged
# from expected snapshot state).
# If set to "yes", the script will attempt a one-time rollback on DR:
#   - Capture a rollback snapshot, restore to last good snapshot, retry DistCp.
#   - Uses per-failure markers (per directory + snapshot pair) to prevent infinite retries of
#     the same failure, but allows rollback for new failures (different snapshot pairs).
#   - Marker format: ${ROLLBACK_MARKER_DIR}/${dir_key}__from_${from_snap}__to_${to_snap}.marker
# If set to "no" (default), the script will just log the error and stop.
# Acceptable values: "yes" or "no".
# Priority: 1) CLI argument (12th arg), 2) Environment variable, 3) Default value
if [[ -n "$ROLLBACK_ON_FAILURE_ARG" ]]; then
    ROLLBACK_ON_FAILURE="$ROLLBACK_ON_FAILURE_ARG"
else
    ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-no}"
fi

# HTTP scheme and port for accessing the NameNode JMX endpoint.
# Configurable separately for source and destination clusters to support
# different Hadoop distributions (e.g., ODP vs CDP) with different configurations
SOURCE_HTTP_SCHEME="${SOURCE_HTTP_SCHEME:-http}"  # http or https for source cluster
SOURCE_NN_WEB_PORT="${SOURCE_NN_WEB_PORT:-50070}" # NameNode web UI port for source (commonly 50070 or 9870)
DEST_HTTP_SCHEME="${DEST_HTTP_SCHEME:-http}"     # http or https for destination cluster
DEST_NN_WEB_PORT="${DEST_NN_WEB_PORT:-50070}"     # NameNode web UI port for destination (commonly 50070 or 9870)

# Kerberos credential cache path (KRB5CCNAME)
# If your Kerberos plugin stores cache at a custom location (e.g., /tmp/krb_*),
# set this environment variable to point to the cache file.
# Example: export KRB5CCNAME=/tmp/krb_12345
# If not set, curl will use the default Kerberos cache location.
KRB5CCNAME="${KRB5CCNAME:-}"

# Lock file directory used to store per-directory snapshot capability locks.
# Each directory will have its own lock file: ${SNAP_LOCK_DIR}/<sanitized_dir_path>.lock    
SNAP_LOCK_DIR="/var/tmp/dr-snapshot-setup-locks"

###############################################################################
# Directory bootstrap strategy for missing DR dirs: "yes" or "no"
#
# Supported modes:
#   - "yes" (auto-bootstrap):
#       * If the destination directory is missing, it will be created automatically
#         with the same owner and permissions as the source directory.
#       * If the destination directory already exists, it will NOT be recreated,
#         and no chown/chmod is performed.
#       * allowSnapshot will be applied automatically to the destination
#         directory as part of Stage 2.
#   - "no" (manual mode):
#       * If the destination directory is missing, the operator is instructed to
#         run a full DistCp for each directory, then manually re-enable allowSnapshot
#         on each destination directory before rerunning the script.
#       * If the destination directory already exists, allowSnapshot will be applied
#         automatically by the script.
#
# Set DIR_BOOTSTRAP_MODE to either "yes" or "no" as desired.
# Priority: 1) CLI argument (13th arg), 2) Environment variable, 3) Default value
###############################################################################
if [[ -n "$DIR_BOOTSTRAP_MODE_ARG" ]]; then
    DIR_BOOTSTRAP_MODE="$DIR_BOOTSTRAP_MODE_ARG"
else
    DIR_BOOTSTRAP_MODE="${DIR_BOOTSTRAP_MODE:-yes}"
fi

###############################################################################
# Automatic full DistCp execution on initial run: "yes" or "no"
#
# When baseline snapshots are created (initial run), this flag controls whether
# the script automatically runs full DistCp commands or just displays them.
#
# Supported modes:
#   - "yes":
#       * Automatically executes full DistCp for each directory after creating
#         baseline snapshots.
#       * After successful DistCp, creates new baseline snapshot on destination
#         (to capture post-DistCp state) and exits.
#       * Operator must re-run the script to begin incremental synchronization.
#       * If DistCp fails for any directory, script exits with error.
#       * WARNING: For large datasets, DistCp can take significant time to complete.
#         Monitor the logs and ensure adequate network bandwidth and cluster resources.
#   - "no" (default):
#       * Displays full DistCp commands for manual execution.
#       * Script exits after showing commands (operator must run DistCp manually).
#       * Operator must re-run the script after completing manual DistCp.
#
# Set AUTO_FULL_DISTCP to either "yes" or "no" as desired.
# Priority: 1) CLI argument (11th arg), 2) Environment variable, 3) Default value
###############################################################################
if [[ -n "$AUTO_FULL_DISTCP_ARG" ]]; then
    AUTO_FULL_DISTCP="$AUTO_FULL_DISTCP_ARG"
else
    AUTO_FULL_DISTCP="${AUTO_FULL_DISTCP:-no}"
fi

# Marker directory for per-failure rollback markers.
# Each marker is unique per directory + snapshot pair (from_snap -> to_snap).
# This allows rollback for new failures on the same directory (different snapshot pairs),
# while preventing infinite retries of the exact same failure.
ROLLBACK_MARKER_DIR="/var/tmp/dr-rollback-markers"

# Temporary files tracking for cleanup
declare -a TEMP_FILES=()


# Split SOURCE_DIRS_RAW into array
IFS=',' read -r -a SOURCE_DIRS <<<"$SOURCE_DIRS_RAW"

# Safety check: ensure at least one source directory is provided
if [[ ${#SOURCE_DIRS[@]} -eq 0 ]] || [[ -z "${SOURCE_DIRS[0]}" ]]; then
    echo "[ERROR] No source directories provided (SOURCE_DIRS is empty)" >&2
    echo "[ERROR] Provide a comma-separated list of HDFS directories as the 3rd argument" >&2
    exit 10
fi

# Validate SNAP_RETAIN is a positive integer
if ! [[ "$SNAP_RETAIN" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] SNAP_RETAIN must be a positive integer (got: '$SNAP_RETAIN')" >&2
    exit 11
fi

# Validate directory paths are absolute
for d in "${SOURCE_DIRS[@]}"; do
    if [[ ! "$d" =~ ^/ ]]; then
        echo "[ERROR] Directory paths must be absolute (start with /). Got: '$d'" >&2
        exit 12
    fi
done

# Validate SNAP_PREFIX doesn't contain invalid characters for HDFS snapshot names
# HDFS snapshot names cannot contain: / \ : * ? " < > |
if [[ "$SNAP_PREFIX" =~ [/\\:\*\?\"\<\>\|] ]]; then
    echo "[ERROR] SNAP_PREFIX contains invalid characters for HDFS snapshot names: '$SNAP_PREFIX'" >&2
    echo "[ERROR] Invalid characters: / \\ : * ? \" < > |" >&2
    exit 13
fi

CURRENT_STAGE=""

# Global failure tracking variables
SCRIPT_FAILED="no"
FAILURE_REASON=""

# Metrics tracking for status determination (simplified - only success/failure counts)
METRICS_SUCCESSFUL_DIRECTORIES=0
METRICS_FAILED_DIRECTORIES=0


# Print a summary of failure reasons and context if script failed
print_failure_summary() {
    echo ""
    echo "────────────────────────────────────────────"
    echo "[ERROR] DR REPLICATION FAILED"
    echo "────────────────────────────────────────────"
    echo "Reason              : ${FAILURE_REASON:-Unknown}"
    echo "Source Cluster      : $SOURCE_CLUSTER"
    echo "Destination Cluster : $DEST_CLUSTER"
    echo "Directories         : ${SOURCE_DIRS[*]}"
    echo "Kerberos            : ${KERBEROS_ENABLED^^}"
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo "Execution Mode      : Kerberos (no sudo)"
    else
        echo "Execution Mode      : sudo (${HDFS_USER}/${DISTCP_USER})"
    fi
    echo "Log File            : $LOG"
    SCRIPT_END_TS=$(date +%s)
    echo "Total Runtime       : $((SCRIPT_END_TS - SCRIPT_START_TS)) seconds"
    echo "────────────────────────────────────────────"
    echo ""
}

###############################################################################
# Kerberos detection and command execution wrappers
###############################################################################

# Strict validation helper for Kerberos config
fail_kerberos_config() {
    log "[ERROR] Invalid Kerberos configuration"
    log "[ERROR] KERBEROS_ENABLED must be set to: yes | no"
    log "[ERROR] Source (in priority order):"
    log "[ERROR]   1) 14th CLI argument"
    log "[ERROR]   2) KERBEROS_ENABLED environment variable"
    log "[ERROR]   3) Default: no"
    exit 1
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
        local best_cc="" fallback_cc=""
        # Iterate newest-first (by modification time)
        while IFS= read -r cc; do
            [[ -f "$cc" ]] || continue

            if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                # Extract the default principal from this cache
                local cc_principal
                cc_principal=$(KRB5CCNAME="$cc" klist 2>/dev/null | grep "Default principal:" | awk '{print $3}')

                # Match principal against DISTCP_USER (e.g., "hdfs" matches "hdfs-odp_phoenix@SPACE.COM")
                if [[ -n "$cc_principal" && "$cc_principal" == ${DISTCP_USER}* ]]; then
                    best_cc="$cc"
                    log "[DEBUG] Matched principal '$cc_principal' for DISTCP_USER='$DISTCP_USER' in $cc"
                    break
                elif [[ -z "$fallback_cc" ]]; then
                    # Keep the newest valid cache as fallback in case no principal matches
                    fallback_cc="$cc"
                    log "[DEBUG] Valid cache $cc has principal '$cc_principal' (no match for DISTCP_USER='$DISTCP_USER')"
                fi
            fi
        done < <(ls -t "$pulse_cache_dir"/krb5cc_* 2>/dev/null)

        # Prefer principal-matched cache, fall back to newest valid
        local selected_cc="${best_cc:-$fallback_cc}"
        if [[ -n "$selected_cc" ]]; then
            export KRB5CCNAME="$selected_cc"
            log "[INFO] Kerberos detected via Pulse cache: $KRB5CCNAME"
            echo "[INFO] Kerberos detected via Pulse cache: $KRB5CCNAME"
            return 0
        fi
        log "[DEBUG] No valid Kerberos cache found in $pulse_cache_dir"
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

# Initialize Kerberos detection (validated, explicit, single-sourced)
init_kerberos_detection() {

    case "${KERBEROS_ENABLED_ARG,,}" in
        ""|no)
            KERBEROS_ENABLED="no"
            ;;
        yes)
            KERBEROS_ENABLED="yes"
            # When Kerberos is enabled, detect and set KRB5CCNAME if available
            if detect_kerberos_enabled; then
                log "[INFO] Kerberos enabled and valid tickets detected"
                if [[ -n "${KRB5CCNAME:-}" ]]; then
                    log "[INFO] Using Kerberos cache: $KRB5CCNAME"
                fi
            else
                log "[WARN] Kerberos is enabled but no valid tickets detected"
                log "[WARN] JMX authentication may fail. Ensure Kerberos tickets are available."
            fi
            ;;
        *)
            log "[ERROR] Invalid value for KERBEROS_ENABLED: '$KERBEROS_ENABLED_ARG'"
            fail_kerberos_config
            ;;
    esac

    echo ""
    # Kerberos status will be displayed in the startup banner after output redirection
    # No need to display it here separately
}

# Wrapper function to run commands as HDFS_USER
# If Kerberos is enabled, run as current user (root) to preserve tickets
# Otherwise, use sudo to switch to HDFS_USER
run_as_hdfs() {
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        # Kerberos enabled: run as current user (root) to preserve tickets
        "$@"
    else
        # Kerberos not enabled: switch to HDFS_USER via sudo
        sudo -u "$HDFS_USER" "$@"
    fi
}

# Wrapper function to run commands as DISTCP_USER with environment preservation
# If Kerberos is enabled, run as current user (root) to preserve tickets
# Otherwise, use sudo -E to switch to DISTCP_USER while preserving environment
run_as_distcp() {
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        # Kerberos enabled: run as current user (root) to preserve tickets and environment
        "$@"
    else
        # Kerberos not enabled: switch to DISTCP_USER via sudo -E to preserve environment
        sudo -E -u "$DISTCP_USER" "$@"
    fi
}

log_substage() {
    local substage_name="$1"
    echo ""
    echo "  -> $substage_name"
    echo ""
}

log_cmd() {
    local cmd_desc="$1"
    echo ""
    echo "  -> $cmd_desc"
    echo ""
}

# Sanitize directory path for safe filenames/keys
sanitize() {
    echo "$1" | sed 's|/|_|g; s|^_||' || echo "$1"
}

# Check if required commands exist
check_prerequisites() {
    local missing_commands=()
    for cmd in hdfs hadoop curl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        echo "[ERROR] Missing required commands: ${missing_commands[*]}" >&2
        echo "[ERROR] Please install the required Hadoop tools and ensure they are in PATH" >&2
        exit 1
    fi
}

# Cleanup temporary files on exit (silent unless in debug mode)
cleanup_temp_files() {
    local cleaned=0
    for f in "${TEMP_FILES[@]}"; do
        if [[ -f "$f" ]]; then
            rm -f "$f" 2>/dev/null && cleaned=$((cleaned + 1)) || true
        fi
    done
    # Only log cleanup in debug mode to reduce output noise
    if [[ $cleaned -gt 0 ]] && [[ "${DISTCP_DEBUG,,}" == "yes" ]]; then
        log "[DEBUG] Cleaned up $cleaned temporary file(s)"
    fi
}

# Atomic state file write to prevent corruption
write_state_file() {
    local state_file="$1"
    local content="$2"
    local tmp_file="${state_file}.tmp.$$"
    echo "$content" >"$tmp_file" && mv "$tmp_file" "$state_file" || {
        log "[ERROR] Failed to write state file $state_file"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    }
}

# Cleanup old snapshots on a cluster (reduces code duplication)
# Only removes snapshots matching the current SNAP_PREFIX to avoid deleting
# snapshots from other replication directions (e.g., forward vs failover)
cleanup_old_snapshots() {
    local cluster="$1"
    local d="$2"
    local cluster_name="$3"
    local snap_retain="$4"
    local snap_prefix="$5"

    log "[DEBUG] Cleaning old snapshots on $cluster_name cluster for $d (prefix: ${snap_prefix})"
    mapfile -t snaps < <(
        run_as_hdfs hdfs dfs -fs "hdfs://$cluster" -ls "$d/.snapshot" 2>/dev/null |
            awk '$1 ~ /^d/ {print $6, $7, $8}' | sort | awk -F/ '{print $NF}' |
            grep "^${snap_prefix}_" || true
    )
    total_snaps=${#snaps[@]}
    log "[DEBUG] Found $total_snaps snapshots matching prefix '${snap_prefix}' on $cluster_name for $d"
    if ((total_snaps > snap_retain)); then
        local count_to_remove=$((total_snaps - snap_retain))
        log "[DEBUG] Removing $count_to_remove old snapshots from $cluster_name for $d"
        for s in "${snaps[@]:0:count_to_remove}"; do
            if run_as_hdfs hdfs dfs -fs "hdfs://$cluster" -ls "$d/.snapshot" 2>/dev/null | grep -q "/$s\$"; then
                if run_as_hdfs hdfs dfs -fs "hdfs://$cluster" -deleteSnapshot "$d" "$s" 2>/dev/null; then
                    log "[CLEAN] Removed old snapshot $s from $cluster_name for $d"
                else
                    log "[WARN] Failed to remove snapshot $s from $cluster_name for $d"
                fi
            else
                log "[CLEAN] Snapshot $s already removed from $cluster_name for $d"
            fi
        done
    else
        log "[DEBUG] No snapshots to remove on $cluster_name for $d"
    fi
}

# Backup existing log file and create a new one for this execution
backup_and_create_new_log() {
    local log_file="$1"
    
    if [[ -f "$log_file" ]]; then
        # Create backup with timestamp
        local timestamp
        timestamp=$(date '+%Y%m%d_%H%M%S')
        local backup_log="${log_file}.${timestamp}"
        
        # Try to move existing log to backup
        if mv "$log_file" "$backup_log" 2>/dev/null; then
            echo "[INFO] Previous log file backed up to: $backup_log" >&2
        else
            # Fallback: try with .prev extension
            local prev_log="${log_file}.prev"
            if mv "$log_file" "$prev_log" 2>/dev/null; then
                echo "[INFO] Previous log file backed up to: $prev_log" >&2
            else
                echo "[WARN] Could not backup existing log file: $log_file" >&2
            fi
        fi
    fi
    
    # Create new log file (will be written to after output redirection)
    touch "$log_file" 2>/dev/null || {
        echo "[ERROR] Could not create log file: $log_file" >&2
        return 1
    }
}

# Detect and provide helpful error messages for common failures
analyze_error() {
    local error_file="$1"
    local error_type=""
    local suggestion=""
    
    if [[ ! -f "$error_file" ]] || [[ ! -s "$error_file" ]]; then
        return 0
    fi
    
    # Check for common error patterns
    if grep -qi "Connection refused\|Connection timed out\|No route to host" "$error_file" 2>/dev/null; then
        error_type="NETWORK_CONNECTIVITY"
        suggestion="Check network connectivity between clusters. Verify firewall rules and network routing."
    elif grep -qi "Permission denied\|AccessControlException\|not authorized" "$error_file" 2>/dev/null; then
        error_type="PERMISSION_DENIED"
        suggestion="Verify that ${DISTCP_USER:-${HDFS_USER}} has superuser privileges or appropriate permissions on both clusters."
    elif grep -qi "quota exceeded\|No space left" "$error_file" 2>/dev/null; then
        error_type="QUOTA_EXCEEDED"
        suggestion="Check HDFS quota limits and available disk space on destination cluster."
    elif grep -qi "NameNode.*not.*active\|HAState.*standby" "$error_file" 2>/dev/null; then
        error_type="HA_STATE"
        suggestion="Verify that the NameNode is in ACTIVE state. Check HA configuration and failover status."
    elif grep -qi "SnapshotException\|snapshot.*already.*exists\|snapshot.*not.*found" "$error_file" 2>/dev/null; then
        error_type="SNAPSHOT_ERROR"
        suggestion="Check snapshot status on both clusters. Ensure snapshot capability is enabled and snapshots are not corrupted."
    elif grep -qi "Kerberos.*ticket\|GSS.*failed\|authentication.*failed" "$error_file" 2>/dev/null; then
        error_type="KERBEROS_AUTH"
        suggestion="Verify Kerberos tickets are valid (run 'klist'). Renew tickets if expired. Check krb5.conf configuration."
    fi
    
    if [[ -n "$error_type" ]]; then
        echo ""
        echo ">>> Error Analysis: $error_type"
        echo ">>> Suggestion: $suggestion"
        echo ""
        return 1
    fi
    return 0
}

# Re-enable normal logging if DEBUG is enabled
enable_debug_if_needed() {
    if [[ "${DISTCP_DEBUG,,}" == "yes" ]]; then
        export HADOOP_ROOT_LOGGER="DEBUG,console"
        log "[DEBUG] DistCp debug logging enabled"
    fi
}

# Enable verbose DistCp debug logging (yes/no)
DISTCP_DEBUG="${DISTCP_DEBUG:-no}"
DISTCP_DEBUG_OPTS=""

# Build DistCp options with YARN queue and application tags
YARN_QUEUE_OPTS="-Dmapred.job.queue.name=${YARN_QUEUE}"
YARN_APP_TAGS="-Dmapreduce.job.tags=pulse-dr-replication,src:${SOURCE_CLUSTER},dst:${DEST_CLUSTER}"
DISTCP_FULL_OPTS="$YARN_QUEUE_OPTS $YARN_APP_TAGS $DISTCP_DEBUG_OPTS"


# -----------------------------------------------------------------------------
# Stage 1: Cluster health checks (JMX / HA)
# Supports both Kerberos and non-Kerberos modes
# If KRB5CCNAME is set at runtime, it will be used for Kerberos authentication
# -----------------------------------------------------------------------------
check_cluster_health() {
    local cluster_host="$1"
    local cluster_name="$2"
    local http_scheme="$3"  # Protocol for this cluster (http or https)
    local nn_web_port="$4"  # Web port for this cluster
    local jmx_url="${http_scheme}://${cluster_host}:${nn_web_port}/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem"

    log "[CHECK] Checking accessibility and HA state for $cluster_name cluster at $cluster_host using $http_scheme on port $nn_web_port"

    local jmx_response
    local curl_cmd=""
    
    # Build and display curl command based on Kerberos mode
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        # Kerberos mode: use KRB5CCNAME if set at runtime, otherwise use default
        if [[ -n "${KRB5CCNAME:-}" ]]; then
            # Export KRB5CCNAME for curl to use
            export KRB5CCNAME
            curl_cmd="curl --silent --max-time 10 --fail --negotiate -u : \"$jmx_url\""
            echo ""
            echo "  >>> Curl Command (Kerberos with custom cache):"
            echo "  >>>   KRB5CCNAME=\"${KRB5CCNAME}\" $curl_cmd"
            echo ""
            log "[DEBUG] Using Kerberos with KRB5CCNAME=\"${KRB5CCNAME}\""
        else
            # Kerberos mode but no custom cache - use default location
            curl_cmd="curl --silent --max-time 10 --fail --negotiate -u : \"$jmx_url\""
            echo ""
            echo "  >>> Curl Command (Kerberos, default cache):"
            echo "  >>>   $curl_cmd"
            echo ""
            log "[DEBUG] Using Kerberos with default cache location"
        fi
        
        # Execute curl with Kerberos authentication
        jmx_response=$(curl --silent --max-time 10 --fail --negotiate -u : "$jmx_url" 2>/dev/null || true)
        
        # Check if Kerberos authentication failed
        if [[ -z "$jmx_response" ]] || ! echo "$jmx_response" | grep -q "FSNamesystem"; then
            log "[WARN] Kerberos authentication failed, trying without Kerberos..."
            curl_cmd="curl --silent --max-time 10 --fail \"$jmx_url\""
            echo ""
            echo "  >>> Fallback Curl Command (no Kerberos):"
            echo "  >>>   $curl_cmd"
            echo ""
            log "[DEBUG] Fallback to non-Kerberos mode"
            jmx_response=$(curl --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
        fi
    else
        # Non-Kerberos mode
        curl_cmd="curl --silent --max-time 10 --fail \"$jmx_url\""
        echo ""
        echo "  >>> Curl Command (no Kerberos):"
        echo "  >>>   $curl_cmd"
        echo ""
        log "[DEBUG] Using non-Kerberos mode"
        jmx_response=$(curl --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
    fi
    
    # Check if we got a valid response
    if [[ -z "$jmx_response" ]] || ! echo "$jmx_response" | grep -q "FSNamesystem"; then
        log "[ERROR] Cannot access JMX endpoint at $jmx_url"
        if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
            log "[ERROR] Kerberos cache path used: ${KRB5CCNAME:-<not set, using default>}"
            log "[ERROR] Verify Kerberos ticket is valid: klist ${KRB5CCNAME:+-c \"$KRB5CCNAME\"}"
        fi
        return 1
    fi
    log "[INFO] JMX endpoint reachable at $jmx_url"

    local ha_state
    ha_state=$(echo "$jmx_response" | grep -o '"tag.HAState"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed -E 's/.*"tag.HAState"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)

    if [[ -z "$ha_state" ]]; then
        log "[WARN] Could not determine HAState from JMX for $cluster_host. JMX response:"
        log "$jmx_response"
        log "[WARN] Assuming non-HA cluster or not available."
        return 0
    fi

    if [[ "$ha_state" == "active" ]]; then
        log "[INFO] $cluster_name NameNode at $cluster_host is ACTIVE"
        return 0
    else
        log "[ERROR] $cluster_name NameNode at $cluster_host is NOT active (HAState=$ha_state)"
        log "[DEBUG] Full JMX response:"
        log "$jmx_response"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# rollback_once_for_failure: attempt single automatic rollback for a specific
# DistCp failure identified by directory + fromSnapshot + toSnapshot.
# Creates a per-failure marker in $ROLLBACK_MARKER_DIR to ensure this exact
# failure (same dir + same snapshot pair) isn't auto-rolled back again.
#
# IMPORTANT: The marker is per-failure, NOT per-directory. This means:
#   - If rollback succeeds for dir /prod from snap_5 to snap_6, a marker is created
#   - Later, if /prod fails again with snap_10 to snap_11, rollback WILL be attempted
#     again (different snapshot pair = different marker)
#   - Only the EXACT same failure (same dir + same from_snap + same to_snap) will
#     be prevented from rolling back again
# -----------------------------------------------------------------------------
rollback_once_for_failure() {
    local d="$1"
    local from_snap="$2"
    local to_snap="$3"
    local key
    key=$(sanitize "$d")
    mkdir -p "$ROLLBACK_MARKER_DIR"
    local marker_file="${ROLLBACK_MARKER_DIR}/${key}__from_${from_snap}__to_${to_snap}.marker"

    # If marker exists, skip automatic rollback for this exact failure
    # Note: This only prevents retrying the SAME failure (same dir + same snapshot pair).
    # If the same directory fails later with different snapshots, rollback will be attempted again.
    if [[ -e "$marker_file" ]]; then
        log "[ROLLBACK] Marker exists for this failure ($marker_file). Skipping automatic rollback for $d from $from_snap -> $to_snap."
        log "[ROLLBACK] Note: This prevents retrying the exact same failure. If $d fails again with different snapshots, rollback will be attempted."
        return 1
    fi

    log "[ROLLBACK] No marker found for this failure. Proceeding with one-time rollback attempt for $d (from=$from_snap to=$to_snap)."

    # Rollback banner
    echo ""
    echo "=========================================================================================================================================="
    echo ">>> [ROLLBACK] Automatic Recovery Attempt for $d <<<"
    echo "=========================================================================================================================================="
    echo ">>> Rollback Details:"
    echo ">>>   Directory: $d"
    echo ">>>   From Snapshot: $from_snap"
    echo ">>>   To Snapshot: $to_snap"
    echo ">>>   Reason: Snapshot-modified error detected"
    echo "=========================================================================================================================================="
    echo ""

    # Create rollback snapshot on DR to preserve current (modified) DR state
    local rollback_snap
    rollback_snap="${SNAP_PREFIX}_rollback_$(date +%s)"
    log_substage "Rollback Step 1: Creating rollback snapshot $rollback_snap on destination"
    log "[ROLLBACK] Creating rollback snapshot $rollback_snap on destination $d"
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$rollback_snap"; then
        echo "[ERROR] FAILED to create rollback snapshot '$rollback_snap' on DESTINATION: $d"
        log "[ERROR] Failed to create rollback snapshot $rollback_snap on destination $d"
        log "[ERROR] Rollback aborted. No marker created - rollback can be retried on next run if issue is resolved."
        return 1
    fi

    # Determine prev_snap to restore to. Prefer the 'from_snap' if present on DR; otherwise choose latest snapshot as fallback.
    local prev_snap="$from_snap"
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -ls "${d}/.snapshot" 2>/dev/null | grep -q "/${prev_snap}\$"; then
        log "[WARN] Expected prev_snap '$prev_snap' not found on DR. Choosing latest available snapshot on DR as fallback."
        mapfile -t snaps_dst < <(
            run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -ls "${d}/.snapshot" 2>/dev/null |
                awk '$1 ~ /^d/ {print $6, $7, $8}' |
                sort |
                awk -F/ '{print $NF}' || true
        )
        if [[ ${#snaps_dst[@]} -eq 0 ]]; then
            log "[ERROR] No snapshots found on DR for $d. Cannot perform automated rollback."
            # Clean up the rollback snapshot we just created
            run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -deleteSnapshot "$d" "$rollback_snap" 2>/dev/null || true
            log "[ERROR] Rollback aborted. No marker created - rollback can be retried on next run if issue is resolved."
            return 1
        fi
        prev_snap="${snaps_dst[$((${#snaps_dst[@]} - 1))]}"
        log "[ROLLBACK] Selected prev_snap='$prev_snap' from DR snapshot list"
    fi

    # Capture diff for audit
    local diff_out
    diff_out="/var/log/dr_rollback_diff_${key}_from_${rollback_snap}_to_${prev_snap}_$(date +%s).txt"
    log_substage "Rollback Step 2: Capturing snapshot diff for audit"
    log "[ROLLBACK] Capturing snapshotDiff between $rollback_snap and $prev_snap to $diff_out"
    run_as_hdfs hdfs snapshotDiff -fs "hdfs://$DEST_CLUSTER" "$d" "$rollback_snap" "$prev_snap" >"$diff_out" 2>&1 ||
        log "[WARN] snapshotDiff returned non-zero; check $diff_out for details."

    # Run DistCp rdiff to restore prev_snap -> live path on DR
    local src_snap_path="hdfs://$DEST_CLUSTER${d}"
    local dst_live_path="hdfs://$DEST_CLUSTER${d}"
    local DISTCP_ROLLBACK_OPTS="-rdiff $rollback_snap $prev_snap -strategy dynamic -direct -update -pugptx"

    log_substage "Rollback Step 3: Running DistCp rollback to restore snapshot state"
    log_cmd "DistCp Rollback Command"
    echo "  hadoop distcp $DISTCP_FULL_OPTS $DISTCP_ROLLBACK_OPTS $src_snap_path $dst_live_path"
    echo ""
    log "[ROLLBACK] Running DistCp rollback: hadoop distcp $DISTCP_FULL_OPTS $DISTCP_ROLLBACK_OPTS $src_snap_path $dst_live_path"
    # Rollback DistCp stderr goes through global redirection (exec 2>&1), no need to tee to LOG again
    local rollback_distcp_success=false
    if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_ROLLBACK_OPTS "$src_snap_path" "$dst_live_path"; then
        rollback_distcp_success=true
    fi
    
    # Create marker AFTER attempting the rollback DistCp operation
    # This ensures that if rollback fails early (before DistCp), we can retry on next run
    # But once we've attempted the DistCp rollback, we create the marker to prevent retrying the same rollback
    local lockdir="${marker_file}.lock"
    if mkdir "$lockdir" 2>/dev/null; then
        {
            echo "marker_created_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            echo "host: $(hostname -f 2>/dev/null || hostname)"
            echo "dir: $d"
            echo "from_snap: $from_snap"
            echo "to_snap: $to_snap"
            echo "initiator_pid: $$"
            echo "rollback_snap: $rollback_snap"
            echo "prev_snap: $prev_snap"
            echo "rollback_distcp_attempted: true"
            echo "rollback_distcp_success: $rollback_distcp_success"
        } >"$marker_file"
        rmdir "$lockdir" || true
        log "[ROLLBACK] Marker created: $marker_file (after rollback DistCp attempt)"
    else
        # Race: someone else might be creating the marker; if marker now exists, skip.
        if [[ -e "$marker_file" ]]; then
            log "[ROLLBACK] Another process is handling rollback for this failure; marker already exists."
        else
            # Fallback: try to write marker non-atomically (best-effort)
            {
                echo "marker_created_at: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                echo "host: $(hostname -f 2>/dev/null || hostname)"
                echo "dir: $d"
                echo "from_snap: $from_snap"
                echo "to_snap: $to_snap"
                echo "initiator_pid: $$"
                echo "rollback_snap: $rollback_snap"
                echo "prev_snap: $prev_snap"
                echo "rollback_distcp_attempted: true"
                echo "rollback_distcp_success: $rollback_distcp_success"
            } >"$marker_file" 2>/dev/null || {
                log "[WARN] Could not create marker file $marker_file; this may allow duplicate rollback attempts."
            }
        fi
    fi
    
    if [[ "$rollback_distcp_success" == "true" ]]; then
        echo ""
        echo "------------------------------------------------------------------------------------------------------------------------------------------"
        echo "[ROLLBACK SUCCESS] DistCp rollback completed successfully for $d"
        echo "------------------------------------------------------------------------------------------------------------------------------------------"
        log "[ROLLBACK] DistCp rollback succeeded for $d. Audit diff saved to $diff_out"
        # Best-effort: delete the temporary rollback snapshot to keep snapshot list tidy
        log_substage "Rollback Step 4: Cleaning up temporary rollback snapshot"
        if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -deleteSnapshot "$d" "$rollback_snap"; then
            log "[ROLLBACK] Deleted temporary rollback snapshot $rollback_snap on destination"
        else
            log "[WARN] Could not delete temporary snapshot $rollback_snap (manual cleanup may be required)"
        fi
        echo ""
        return 0
    else
        echo ""
        echo "=========================================================================================================================================="
        echo ">>> [ERROR] ROLLBACK FAILED for $d <<<"
        echo "=========================================================================================================================================="
        log "[ERROR] DistCp rollback failed for $d. See $diff_out and DistCp logs. Marker created to prevent repeated auto-rollbacks for this exact failure."
        log "[ERROR] Note: Marker prevents retrying the same rollback. If the underlying issue is fixed, you may need to manually remove the marker: $marker_file"
        echo ""
        return 1
    fi
}

# -----------------------------------------------------------------------------
# main()
# -----------------------------------------------------------------------------
main() {
    # Safety check: refuse to run if source and destination clusters are the same
    if [[ "$SOURCE_CLUSTER" == "$DEST_CLUSTER" ]]; then
        echo "[ERROR] SOURCE_CLUSTER and DEST_CLUSTER are identical: '$SOURCE_CLUSTER'"
        echo "Refusing to run to prevent self-replication or data corruption."
        exit 2
    fi
    
    # Setup cleanup trap for temporary files
    trap cleanup_temp_files EXIT INT TERM
    
    # Backup existing log file and create new one for this execution (before redirecting output)
    backup_and_create_new_log "$LOG"
    
    # Trap for failure summary on exit if script failed
    trap '[[ "$SCRIPT_FAILED" == "yes" ]] && print_failure_summary; cleanup_temp_files' EXIT INT TERM

    # Check prerequisites (required commands) - must be after log setup
    check_prerequisites

    # Initialize Kerberos detection (must be done early, before output redirection)
    init_kerberos_detection

    # Re-enable debug logging if requested via environment variable
    enable_debug_if_needed

    # Extract hostnames without ports for JMX checks
    source_host="${SOURCE_CLUSTER%%:*}"
    dest_host="${DEST_CLUSTER%%:*}"
    
    # Redirect all output to log file and also echo to stdout
    # This ensures all output (stdout and stderr) goes through the same tee process
    # for real-time visibility without buffering issues. All subsequent output
    # (including DistCp stderr) will be logged to $LOG and displayed on console.
    exec > >(tee -a "$LOG") 2>&1
    log "[DEBUG] Starting DR replication script"
    echo ""
    echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
    echo "DR REPLICATION SCRIPT STARTED"
    echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
    echo "Start Time          : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Log File            : $LOG"
    echo "Source Cluster      : $SOURCE_CLUSTER"
    echo "Destination Cluster : $DEST_CLUSTER"
    echo "Directories         : ${SOURCE_DIRS[*]}"
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo "Kerberos            : ENABLED"
    else
        echo "Kerberos            : DISABLED"
        echo "Execution Mode      : sudo (${HDFS_USER}/${DISTCP_USER})"
    fi
    echo "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────"
    echo "Positional Arguments Received:"
    echo "  Arg 1  (SOURCE_CLUSTER)      : $SOURCE_CLUSTER"
    echo "  Arg 2  (DEST_CLUSTER)        : $DEST_CLUSTER"
    echo "  Arg 3  (SOURCE_DIRS)         : $SOURCE_DIRS_RAW"
    echo "  Arg 4  (SNAP_PREFIX)         : $SNAP_PREFIX"
    echo "  Arg 5  (SNAP_RETAIN)         : $SNAP_RETAIN"
    echo "  Arg 6  (HDFS_USER)           : $HDFS_USER"
    echo "  Arg 7  (DISTCP_USER)         : $DISTCP_USER"
    echo "  Arg 8  (COPY_OPTS)           : $COPY_OPTS"
    echo "  Arg 9  (YARN_QUEUE)          : $YARN_QUEUE"
    echo "  Arg 10 (LOG_PATH)            : $LOG"
    echo "  Arg 11 (AUTO_FULL_DISTCP)    : $AUTO_FULL_DISTCP"
    echo "  Arg 12 (ROLLBACK_ON_FAILURE) : $ROLLBACK_ON_FAILURE"
    echo "  Arg 13 (DIR_BOOTSTRAP_MODE)  : $DIR_BOOTSTRAP_MODE"
    echo "  Arg 14 (KERBEROS_ENABLED)    : $KERBEROS_ENABLED"
    echo "  YARN App Tags                : $YARN_APP_TAGS"
    echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
    echo ""

    # -----------------------------------------------------------------------------
    # Stage 1: Pre-check clusters health (see check_cluster_health)
    # Skip health checks if:
    #   1. SKIP_HEALTH_CHECKS environment variable is set to "yes"
    #   2. HA mode is detected (SOURCE_CLUSTER or DEST_CLUSTER don't contain ":")
    #      In HA mode, NameService is used instead of hostname:port, so JMX checks
    #      cannot be performed directly on the NameService
    # -----------------------------------------------------------------------------
    SKIP_HEALTH_CHECKS="${SKIP_HEALTH_CHECKS:-no}"
    
    # Detect HA mode: if SOURCE_CLUSTER or DEST_CLUSTER don't contain ":", it's likely a NameService (HA)
    source_is_ha=false
    dest_is_ha=false
    if [[ "$SOURCE_CLUSTER" != *":"* ]]; then
        source_is_ha=true
        log "[INFO] SOURCE cluster appears to be HA-enabled (NameService: $SOURCE_CLUSTER)"
    fi
    if [[ "$DEST_CLUSTER" != *":"* ]]; then
        dest_is_ha=true
        log "[INFO] DESTINATION cluster appears to be HA-enabled (NameService: $DEST_CLUSTER)"
    fi
    
    # Configure DistCp MapReduce options for destination cluster
    # Exclude destination from token renewal to avoid delegation token issues
    # This applies to both HA and non-HA destinations to prevent token conflicts
    DISTCP_MAPREDUCE_OPTS=""
    DST_NAMESERVICE="${DEST_CLUSTER%%:*}"
    DISTCP_MAPREDUCE_OPTS="-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${DST_NAMESERVICE}"
    
    if [[ "$dest_is_ha" == "true" ]]; then
        log "[INFO] HA mode detected for destination. Setting MapReduce option to exclude destination from token renewal: $DISTCP_MAPREDUCE_OPTS"
    else
        log "[INFO] Non-HA destination detected. Setting MapReduce option to exclude destination from token renewal: $DISTCP_MAPREDUCE_OPTS"
    fi
    
    # Update DISTCP_FULL_OPTS with MapReduce options
    DISTCP_FULL_OPTS="$YARN_QUEUE_OPTS $YARN_APP_TAGS $DISTCP_MAPREDUCE_OPTS $DISTCP_DEBUG_OPTS"
    log "[INFO] Updated DistCp options: $DISTCP_FULL_OPTS"
    
    # -----------------------------------------------------------------------------
    # Kerberos detection before Stage 1 (if Kerberos is enabled)
    # This ensures KRB5CCNAME is set before JMX health checks
    # -----------------------------------------------------------------------------
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo ""
        echo "────────────────────────────────────────────"
        echo ">>> KERBEROS DETECTION (Before Stage 1) <<<"
        echo "────────────────────────────────────────────"
        log "[INFO] Detecting Kerberos credentials before Stage 1..."
        echo "[INFO] Detecting Kerberos credentials before Stage 1..."
        if detect_kerberos_enabled; then
            log "[INFO] Kerberos credentials detected successfully"
            echo "[INFO] Kerberos credentials detected successfully"
            if [[ -n "${KRB5CCNAME:-}" ]]; then
                log "[INFO] Using Kerberos cache: $KRB5CCNAME"
                echo "[INFO] Using Kerberos cache: $KRB5CCNAME"
            fi
        else
            log "[WARN] Kerberos is enabled but no valid credentials detected"
            echo "[WARN] Kerberos is enabled but no valid credentials detected"
            log "[WARN] JMX health checks may fail. Ensure Kerberos tickets are available."
            echo "[WARN] JMX health checks may fail. Ensure Kerberos tickets are available."
        fi
        echo "────────────────────────────────────────────"
        echo ""
    fi
    
    # -----------------------------------------------------------------------------
    # Stage 1: Pre-check clusters health (see check_cluster_health)
    # -----------------------------------------------------------------------------
    if [[ "$SKIP_HEALTH_CHECKS" == "yes" ]] || [[ "$source_is_ha" == "true" ]] || [[ "$dest_is_ha" == "true" ]]; then
        log_stage "1" "Cluster Health Checks"
        if [[ "$SKIP_HEALTH_CHECKS" == "yes" ]]; then
            log "[INFO] Skipping cluster health checks (SKIP_HEALTH_CHECKS=yes)"
        elif [[ "$source_is_ha" == "true" ]] || [[ "$dest_is_ha" == "true" ]]; then
            log "[INFO] Skipping cluster health checks (HA mode detected - NameService cannot be accessed directly via JMX)"
        fi
        log_stage_complete "1" "Cluster Health Checks"
    else
        log_stage "1" "Cluster Health Checks"
        log_substage "Checking SOURCE cluster: $source_host"
        if ! check_cluster_health "$source_host" "SOURCE" "$SOURCE_HTTP_SCHEME" "$SOURCE_NN_WEB_PORT"; then
            log_stage_failed "1" "Cluster Health Checks" "Source cluster health check failed"
            exit 1
        fi

        log_substage "Checking DESTINATION cluster: $dest_host"
        if ! check_cluster_health "$dest_host" "DEST" "$DEST_HTTP_SCHEME" "$DEST_NN_WEB_PORT"; then
            log_stage_failed "1" "Cluster Health Checks" "Destination cluster health check failed"
            exit 1
        fi
        log_stage_complete "1" "Cluster Health Checks"
    fi

    # -----------------------------------------------------------------------------
    # Stage 2: Enable snapshots once per directory (idempotent using per-directory locks)
    # -----------------------------------------------------------------------------
    log_stage "2" "Enable Snapshot Capability (Per-Directory)"
    mkdir -p "$SNAP_LOCK_DIR"
    log "[DEBUG] Enabling snapshots on source and destination directories"
    for d in "${SOURCE_DIRS[@]}"; do
        dir_start_ts=$(date +%s)
        key=$(sanitize "$d")
        dir_lock="${SNAP_LOCK_DIR}/${key}.lock"
        
        if [[ ! -f "$dir_lock" ]]; then
            log "[DEBUG] Enabling snapshots for directory: $d"
            log_substage "Enabling on SOURCE: $d"
            log "[DEBUG] Allowing snapshot on source dir: $d"
            if run_as_hdfs hdfs dfsadmin -fs "hdfs://$SOURCE_CLUSTER" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true; then
                log "[INFO] Snapshot enabled on source directory $d"
            else
                echo "[ERROR] FAILED to enable snapshot on SOURCE directory $d"
                log "[ERROR] Failed to enable snapshot on source directory $d"
                log "[ERROR] This may indicate permission issues or the directory doesn't exist on source cluster."
            fi

            # Check if destination dir exists
            log_substage "Enabling on DESTINATION: $d"
            if ! run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -test -d "$d"; then
                # auto mode: create dummy dir with source perms/ownership
                if [[ "$DIR_BOOTSTRAP_MODE" == "yes" ]]; then
                    log "[INIT] Destination dir $d missing. Creating with same owner/permissions as source."
                    # Capture output and filter out log lines (lines starting with timestamps like "2026-01-03")
                    # Get only the actual stat output (should be in format "owner:group permissions")
                    prod_meta=$(run_as_hdfs hdfs dfs -fs "hdfs://$SOURCE_CLUSTER" -stat "%u:%g %a" "$d" 2>/dev/null | grep -v "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}" | tail -1 || true)
                    owner_group=$(echo "$prod_meta" | awk '{print $1}' || echo "")
                    perms=$(echo "$prod_meta" | awk '{print $2}' || echo "")
                    # Validate that we got valid owner:group format
                    if [[ ! "$owner_group" =~ ^[^:]+:[^:]+$ ]]; then
                        log "[ERROR] Failed to get valid owner:group from source directory. Got: '$owner_group'"
                        log "[ERROR] Raw output: '$prod_meta'"
                        log "[WARN] Skipping chown, will use default permissions"
                        owner_group=""
                    fi
                    run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -mkdir -p "$d"
                    if [[ -n "$owner_group" ]]; then
                        run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -chown "$owner_group" "$d"
                    fi
                    if [[ -n "$perms" ]]; then
                        run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -chmod "$perms" "$d"
                    fi
                else
                    log "[INIT] Destination dir $d missing in manual mode. It will be created by full DistCp."
                fi
            fi

            # Now allowSnapshot on destination (whether just created or already exists)
            log "[DEBUG] Allowing snapshot on destination dir: $d"
            if run_as_hdfs hdfs dfsadmin -fs "hdfs://$DEST_CLUSTER" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true; then
                log "[INFO] Snapshot enabled on destination directory $d"
            else
                echo "[ERROR] FAILED to enable snapshot on DESTINATION directory $d"
                log "[ERROR] Failed to enable snapshot on destination directory $d"
                log "[ERROR] This may indicate permission issues or the directory doesn't exist on destination cluster."
            fi
            
            : >"$dir_lock"
            log "[DEBUG] Snapshot capability enabled for directory $d (lock: $dir_lock)"
        else
            log "[DEBUG] Snapshot capability already enabled for directory $d (lock present: $dir_lock)"
        fi
    done
        log "[DEBUG] Per-directory snapshot capability check complete for all directories"
    log_stage_complete "2" "Enable Snapshot Capability (Per-Directory)"

    # -----------------------------------------------------------------------------
    # Stage 3: Create baseline snapshots if missing (idempotent)
    # -----------------------------------------------------------------------------
    log_stage "3" "Baseline Snapshot Creation"
    log "[DEBUG] Checking baseline snapshots for each directory"
    need_init=false
    for d in "${SOURCE_DIRS[@]}"; do
        log "[DEBUG] Checking baseline snapshot for directory: $d"
        key=$(sanitize "$d")
        state="/var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt"
        if [[ ! -f "$state" ]]; then
            need_init=true
            base="${SNAP_PREFIX}_0"
            local src_snap_created=false
            local dst_snap_created=false
            
            log_substage "Creating on SOURCE: $d"
            log "[INIT] Creating baseline snapshot '$base' on source: $d"
            if run_as_hdfs hdfs dfs -fs "hdfs://$SOURCE_CLUSTER" -createSnapshot "$d" "$base"; then
                log "[INFO] Baseline snapshot '$base' created on source for $d"
                src_snap_created=true
            else
                echo "[ERROR] FAILED to create baseline snapshot '$base' on SOURCE: $d"
                log "[ERROR] Failed to create baseline snapshot on source for $d"
                log "[ERROR] Ensure snapshot capability is enabled and the directory exists on source cluster."
                src_snap_created=false
            fi

            log_substage "Creating on DESTINATION: $d"
            log "[INIT] Creating baseline snapshot '$base' on destination: $d"
            if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$base"; then
                log "[INFO] Baseline snapshot '$base' created on destination for $d"
                dst_snap_created=true
            else
                echo "[ERROR] FAILED to create baseline snapshot '$base' on DESTINATION: $d"
                log "[ERROR] Failed to create baseline snapshot on destination for $d"
                log "[ERROR] Ensure snapshot capability is enabled and the directory exists on destination cluster."
                dst_snap_created=false
            fi

            # Only create state file if BOTH snapshots were created successfully
            # This prevents the script from thinking baseline is done when it's not
            if [[ "$src_snap_created" == "true" ]] && [[ "$dst_snap_created" == "true" ]]; then
                if write_state_file "$state" "$base"; then
                    log "[INIT] Recorded baseline snapshot state in $state"
                else
                    log "[ERROR] Failed to write state file $state"
                fi
            else
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> [ERROR] BASELINE SNAPSHOT CREATION FAILED for directory: $d <<<"
                echo "=========================================================================================================================================="
                if [[ "$src_snap_created" != "true" ]]; then
                    echo ">>> Source snapshot creation FAILED"
                fi
                if [[ "$dst_snap_created" != "true" ]]; then
                    echo ">>> Destination snapshot creation FAILED"
                fi
                echo "=========================================================================================================================================="
                echo ""
                log "[ERROR] Baseline snapshot creation failed for $d. State file NOT created."
                log "[ERROR] Please fix the issues above and re-run the script. The script will retry baseline snapshot creation."
                log "[ERROR] Common issues:"
                log "[ERROR]   - Permission denied: Ensure HDFS_USER has superuser privileges or is the directory owner"
                log "[ERROR]   - Snapshot not enabled: Ensure allowSnapshot was successful in Stage 2"
                log "[ERROR]   - Directory doesn't exist: Ensure the directory exists on both clusters"
                echo ""
                # Continue to next directory instead of exiting, so other directories can still be processed
                continue
            fi
        else
            log "[DEBUG] Baseline snapshot state file exists for $d"
        fi
    done
    log "[DEBUG] Baseline snapshot creation check complete"
    if ! $need_init; then
        log_stage_complete "3" "Baseline Snapshot Creation"
    fi

    if $need_init; then
        log "[INIT] Baseline snapshots created for directories: ${SOURCE_DIRS[*]}"
        echo ""
        echo "=========================================================================================================================================="
        
        # Check if automatic DistCp is enabled
        if [[ "${AUTO_FULL_DISTCP,,}" == "yes" ]]; then
            echo ">>> BASELINE SNAPSHOTS CREATED - AUTOMATIC FULL DISTCP ENABLED <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "[WARNING] Automatic full DistCp execution is enabled."
            echo "   For large datasets, DistCp can take significant time to complete."
            echo "   Please ensure:"
            echo "   - Adequate network bandwidth between clusters"
            echo "   - Sufficient cluster resources (CPU, memory, disk I/O)"
            echo "   - Monitor the logs for progress and potential issues"
            echo ""
            echo "   After successful DistCp, the script will:"
            echo "   - Create a new baseline snapshot on destination (post-DistCp state)"
            echo "   - Exit (you must re-run the script to begin incremental sync)"
            echo "   - If DistCp fails for any directory, the script will exit with an error."
            echo ""
            echo "=========================================================================================================================================="
            echo ""
            
            # Run full DistCp for each directory that successfully created baseline snapshots
            DISTCP_ALL_OK=true
            for d in "${SOURCE_DIRS[@]}"; do
                key=$(sanitize "$d")
                state="/var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt"

                # Skip directories that don't have state files (baseline creation failed)
                if [[ ! -f "$state" ]]; then
                    echo ""
                    echo "=========================================================================================================================================="
                    echo ">>> [WARNING] SKIPPING DistCp for directory: $d <<<"
                    echo "=========================================================================================================================================="
                    echo ">>> Reason: Baseline snapshot creation failed for this directory"
                    echo ">>> Action: Fix the issues reported above and re-run the script"
                    echo "=========================================================================================================================================="
                    echo ""
                    log "[WARN] Skipping DistCp for $d - baseline snapshot creation failed (no state file)"
                    DISTCP_ALL_OK=false
                    continue
                fi
                
                src_uri="hdfs://$SOURCE_CLUSTER${d}"
                dst_uri="hdfs://$DEST_CLUSTER${d}"
                distcp_cmd="hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS $src_uri $dst_uri"
                
                echo ""
                log_cmd "Running Full DistCp for Directory: $d"
                echo "📁 Directory: $d"
                echo ""
                echo "=== Full DistCp Command ==="
                echo "  $distcp_cmd"
                echo "==========================="
                echo ""
                log "[INIT] Running full DistCp for $d: $distcp_cmd"
                echo "[INFO] Starting full DistCp for $d (this may take a long time for large datasets)..."
                echo ""
                
                # Run DistCp with stderr captured for error analysis
                DISTCP_STDERR_FILE="/tmp/full_distcp_err_$(sanitize "$d")_$$.log"
                TEMP_FILES+=("$DISTCP_STDERR_FILE")
                if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_STDERR_FILE" >&2); then
                    echo ""
                    echo "------------------------------------------------------------------------------------------------------------------------------------------"
                    echo "[SUCCESS] Full DistCp completed successfully for $d"
                    echo "------------------------------------------------------------------------------------------------------------------------------------------"
                    log "[INFO] Full DistCp succeeded for $d"
                    echo ""
                else
                    echo ""
                    echo "=========================================================================================================================================="
                    echo ">>> [ERROR] FULL DISTCP FAILED for directory: $d <<<"
                    echo "=========================================================================================================================================="
                    log "[ERROR] Full DistCp failed for $d (see $DISTCP_STDERR_FILE)"
                    # Show key error messages
                    if [[ -f "$DISTCP_STDERR_FILE" ]] && [[ -s "$DISTCP_STDERR_FILE" ]]; then
                        echo ""
                        echo "Key Error Messages:"
                        grep -E "(ERROR|Exception|Failed|failed)" "$DISTCP_STDERR_FILE" | head -5 || echo "  No specific error messages found"
                        # Analyze error and provide suggestions
                        analyze_error "$DISTCP_STDERR_FILE"
                    fi
                    echo ""
                    DISTCP_ALL_OK=false
                fi
            done
            
            # Check if all DistCp operations succeeded
            if [[ "$DISTCP_ALL_OK" != "true" ]]; then
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> [ERROR] BASELINE DISTCP FAILED - SCRIPT TERMINATING <<<"
                echo "=========================================================================================================================================="
                echo ""
                echo "One or more full DistCp operations failed. Please:"
                echo "1. Review the error messages above"
                echo "2. Fix any issues (network, permissions, cluster health, etc.)"
                echo "3. Manually run the failed DistCp commands or re-run this script"
                echo ""
                log "[ERROR] Baseline full DistCp failed for one or more directories. Script terminating."
                exit 1
            fi
            
            # Re-enable snapshots on destination (they may have been disabled during DistCp)
            log_substage "Re-enabling snapshots on destination directories"
            for d in "${SOURCE_DIRS[@]}"; do
                log "[DEBUG] Re-enabling snapshot on destination dir: $d"
                if run_as_hdfs hdfs dfsadmin -fs "hdfs://$DEST_CLUSTER" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true; then
                    log "[INFO] Snapshot re-enabled on destination directory $d"
                else
                    log "[WARN] Failed to re-enable snapshot on destination directory $d (may already be enabled)"
                fi
            done
            
            # After full DistCp, the destination has been modified and no longer matches dr_snap_0.
            # Create a new baseline snapshot on destination to capture the current state after DistCp.
            # This ensures that on the next run, incremental sync will work correctly.
            log_substage "Creating post-DistCp baseline snapshot on destination"
            for d in "${SOURCE_DIRS[@]}"; do
                key=$(sanitize "$d")
                base="${SNAP_PREFIX}_0"
                log "[DEBUG] Creating post-DistCp baseline snapshot for directory: $d"
                
                # Delete the old dr_snap_0 on destination (from before DistCp)
                if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${base}\$" || true; then
                    log "[DEBUG] Deleting old baseline snapshot $base on destination (pre-DistCp state)"
                    if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -deleteSnapshot "$d" "$base" 2>/dev/null; then
                        log "[INFO] Deleted old baseline snapshot $base on destination"
                    else
                        log "[WARN] Failed to delete old baseline snapshot $base on destination (may proceed anyway)"
                    fi
                fi
                
                # Create new baseline snapshot on destination (post-DistCp state)
                log "[INIT] Creating new baseline snapshot '$base' on destination (post-DistCp state): $d"
                if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$base"; then
                    log "[INFO] New baseline snapshot '$base' created on destination for $d (post-DistCp state)"
                else
                    echo "[ERROR] FAILED to create post-DistCp baseline snapshot '$base' on DESTINATION: $d"
                    log "[ERROR] Failed to create post-DistCp baseline snapshot on destination for $d"
                    log "[ERROR] This may cause issues on the next incremental sync run."
                fi
            done
            
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [SUCCESS] BASELINE DISTCP COMPLETED SUCCESSFULLY <<<"
            echo "=========================================================================================================================================="
            SCRIPT_END_TS=$(date +%s)
            echo "Total Runtime       : $((SCRIPT_END_TS - SCRIPT_START_TS)) seconds"
            echo ""
            echo "All full DistCp operations completed successfully."
            echo "Post-DistCp baseline snapshots have been created on the destination."
            echo ""
            echo "[WARNING] IMPORTANT: Full DistCp bootstrap has completed."
            echo "   The script will now exit. Please re-run the script to begin incremental synchronization."
            echo ""
            echo "   On the next run, the script will:"
            echo "   - Skip baseline snapshot creation (already done)"
            echo "   - Skip full DistCp (already done)"
            echo "   - Proceed directly to Stage 4 (incremental synchronization)"
            echo ""
            echo "=========================================================================================================================================="
            echo ""
            log "[INFO] All baseline full DistCp operations completed successfully. Post-DistCp snapshots created. Exiting to allow next run for incremental sync."
            log_stage_complete "3" "Baseline Snapshot Creation"
            exit 0
        else
            # Manual mode: show commands and exit
            echo ">>> BASELINE SNAPSHOTS CREATED - MANUAL DISTCP REQUIRED <<<"
            echo "=========================================================================================================================================="
            echo ""
            if [[ "$DIR_BOOTSTRAP_MODE" == "no" ]]; then
                echo "[WARNING] Baseline snapshots have been created. You must run a FULL DistCp for each directory,"
                echo "   then re-enable snapshots on each destination directory before rerunning this script."
            else
                echo "[WARNING] Baseline snapshots have been created. You must run a FULL DistCp for each directory"
                echo "   before rerunning this script."
            fi
            echo ""
            echo "💡 TIP: To enable automatic full DistCp execution, set AUTO_FULL_DISTCP=\"yes\""
            echo "   (via environment variable or by editing the script)."
            echo "   WARNING: For large datasets, DistCp can take significant time to complete."
            echo ""
            echo "------------------------------------------------------------------------------------------------------------------------------------------"
            echo ">>> DISTCP COMMANDS TO RUN <<<"
            echo "------------------------------------------------------------------------------------------------------------------------------------------"
            echo ""
            local has_valid_dirs=false
            for d in "${SOURCE_DIRS[@]}"; do
                key=$(sanitize "$d")
                state="/var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt"

                # Skip directories that don't have state files (baseline creation failed)
                if [[ ! -f "$state" ]]; then
                    echo "📁 Directory: $d"
                    echo ""
                    echo "   [WARNING] SKIPPED: Baseline snapshot creation failed for this directory"
                    echo "   Please fix the issues reported above and re-run the script."
                    echo ""
                    echo "------------------------------------------------------------------------------------------------------------------------------------------"
                    echo ""
                    continue
                fi
                
                has_valid_dirs=true
                src_uri="hdfs://$SOURCE_CLUSTER${d}"
                dst_uri="hdfs://$DEST_CLUSTER${d}"
                distcp_cmd="hadoop distcp $COPY_OPTS $src_uri $dst_uri"
                echo "📁 Directory: $d"
                echo ""
                echo "   Run this command to sync baseline snapshots:"
                echo ""
                echo "   ==========================================================================================================================================="
                echo "   $distcp_cmd"
                echo "   ==========================================================================================================================================="
                echo ""
                if [[ "$DIR_BOOTSTRAP_MODE" == "no" ]]; then
                    echo "   After running DistCp, run the following commands to re-enable snapshots:"
                    echo ""
                    echo "   hdfs dfsadmin -fs hdfs://$DEST_CLUSTER -allowSnapshot $d"
                    echo "   hdfs dfs -fs hdfs://$DEST_CLUSTER -ls $d/.snapshot   # verify"
                    echo ""
                fi
                echo "------------------------------------------------------------------------------------------------------------------------------------------"
                echo ""
            done
            
            if [[ "$has_valid_dirs" != "true" ]]; then
                echo "[WARNING] No directories have valid baseline snapshots. All baseline snapshot creation attempts failed."
                echo "   Please fix the issues reported above and re-run the script."
                echo ""
            fi
            echo "=========================================================================================================================================="
            echo ">>> NEXT STEPS <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "1. Run the DistCp commands shown above for each directory"
            if [[ "$DIR_BOOTSTRAP_MODE" == "no" ]]; then
                echo "2. Re-enable snapshots on each destination directory (commands shown above)"
                echo "3. Re-run this script to begin incremental synchronization"
            else
                echo "2. Re-run this script to begin incremental synchronization"
            fi
            echo ""
            echo "=========================================================================================================================================="
            echo ""
            if [[ "$DIR_BOOTSTRAP_MODE" == "no" ]]; then
                log "[INIT] Baseline snapshots created. You must run a full DistCp for each directory, then allowSnapshot on each dir before rerunning this script."
            else
                log "[INIT] Baseline snapshots created. You must run a full DistCp for each directory before rerunning this script."
            fi
            exit 0
        fi
    fi

    # -----------------------------------------------------------------------------
    # Stage 4: Incremental sync (main loop per directory)
    # -----------------------------------------------------------------------------
    log_stage "4" "Incremental Synchronization"
    ALL_OK=true
    echo "[INFO] Starting incremental synchronization for directories: ${SOURCE_DIRS[*]}"
    for d in "${SOURCE_DIRS[@]}"; do
        echo ""
        log_cmd "Processing Directory: $d"
        log "[DEBUG] Starting incremental sync for directory: $d"
        key=$(sanitize "$d")
        state="/var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt"
        last_snap=$(<"$state")
        idx=${last_snap##*_}
        next_snap="${SNAP_PREFIX}_$((idx + 1))"

        log "[SYNC] $d: $last_snap -> $next_snap"

        # 4a) Ensure last_snap exists on destination (create if missing)
        log "[DEBUG] Ensuring last snapshot $last_snap exists on destination directory $d"
        out_dr_last=$(run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -ls "$d/.snapshot" 2>/dev/null | grep "/$last_snap\$" || true)
        if [[ -z "$out_dr_last" ]]; then
            log "[INFO] Last snapshot $last_snap missing on destination, creating..."
            if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$last_snap"; then
                log "[INFO] Created last snapshot $last_snap on destination"
            else
                log_error "FAILED to create last snapshot '$last_snap' on DESTINATION: $d"
                log "[ERROR] [Stage 4] Failed to create last snapshot $last_snap on destination"
                log "[ERROR] This prevents incremental sync. Check cluster health and permissions."
                METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                dir_end_ts=$(date +%s)
                log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                ALL_OK=false
                continue
            fi
        else
            log "[DEBUG] Last snapshot $last_snap already exists on destination"
        fi

        # 4b) Create next_snap snapshot on source before distcp
        log "[DEBUG] Creating next snapshot $next_snap on source directory $d"
        out_src=$(run_as_hdfs hdfs dfs -fs "hdfs://$SOURCE_CLUSTER" -createSnapshot "$d" "$next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
        log "[DEBUG] Source snapshot creation output: $out_src"
        if echo "$out_src" | grep -q "already a snapshot with the same name"; then
            log "[WARN] Source snapshot $next_snap already exists"
        elif echo "$out_src" | grep -q "Created snapshot"; then
            log "[INFO] Source snapshot $next_snap created"
        else
            log_error "FAILED to create next snapshot '$next_snap' on SOURCE: $d"
            log "[ERROR] [Stage 4] Source snapshot creation failed: $out_src"
            log "[ERROR] This prevents incremental sync. Check cluster health and permissions."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
            ALL_OK=false
            continue
        fi

        # 4c) Special handling for baseline snapshot: Check if destination was modified
        #      after manual DistCp (AUTO_FULL_DISTCP="no" scenario)
        #      Only applies to baseline snapshot (dr_snap_0), not subsequent snapshots
        #      For subsequent snapshots, ROLLBACK_ON_FAILURE handles modifications
        baseline_snap="${SNAP_PREFIX}_0"
        if [[ "$last_snap" == "$baseline_snap" ]]; then
            log "[DEBUG] Working with baseline snapshot $baseline_snap. Checking if destination was modified after manual DistCp..."
            
            # Use snapshotDiff to check if destination directory differs from snapshot
            # snapshotDiff returns non-zero if there are differences
            # We compare the snapshot to the current directory state (represented by ".")
            snapshot_diff_output=$(run_as_hdfs hdfs snapshotDiff -fs "hdfs://$DEST_CLUSTER" "$d" "$baseline_snap" "." 2>&1 || true)
            snapshot_diff_exit_code=$?
            
            # If snapshotDiff shows differences (exit code != 0) or if it indicates modifications,
            # the destination has been modified since the snapshot was created
            if [[ $snapshot_diff_exit_code -ne 0 ]] || 
               echo "$snapshot_diff_output" | grep -qE "(M\.|R\.|\\+)" || 
               echo "$snapshot_diff_output" | grep -q "has been modified"; then
                log "[WARN] Detected that destination was modified since baseline snapshot $baseline_snap"
                log "[INFO] This likely occurred after manual DistCp (AUTO_FULL_DISTCP=\"no\")"
                log "[INFO] Automatically recreating baseline snapshot on destination to match current state..."
                
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> 🔧 BASELINE SNAPSHOT DETECTION: Destination Modified After Manual DistCp <<<"
                echo "=========================================================================================================================================="
                echo ">>> Directory: $d"
                echo ">>> Baseline Snapshot: $baseline_snap"
                echo ">>> Action: Recreating baseline snapshot on destination to match current state"
                echo ">>> Reason: Destination was modified (likely from manual DistCp)"
                echo "=========================================================================================================================================="
                echo ""
                
                # Delete old baseline snapshot on destination
                if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${baseline_snap}\$" || true; then
                    log "[DEBUG] Deleting old baseline snapshot $baseline_snap on destination (pre-manual-DistCp state)"
                    if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -deleteSnapshot "$d" "$baseline_snap" 2>/dev/null; then
                        log "[INFO] Deleted old baseline snapshot $baseline_snap on destination"
                    else
                        log "[WARN] Failed to delete old baseline snapshot $baseline_snap on destination (may proceed anyway)"
                    fi
                fi
                
                # Create new baseline snapshot on destination (post-manual-DistCp state)
                log "[INIT] Creating new baseline snapshot '$baseline_snap' on destination (post-manual-DistCp state): $d"
                if run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$baseline_snap"; then
                    log "[INFO] New baseline snapshot '$baseline_snap' created on destination for $d (post-manual-DistCp state)"
                    echo ""
                    echo "------------------------------------------------------------------------------------------------------------------------------------------"
                    echo "[SUCCESS] Baseline snapshot recreated on destination"
                    echo "------------------------------------------------------------------------------------------------------------------------------------------"
                    echo ""
                else
                    echo "[ERROR] FAILED to create new baseline snapshot '$baseline_snap' on DESTINATION: $d"
                    log "[ERROR] Failed to create new baseline snapshot on destination for $d"
                    log "[ERROR] Incremental sync may fail. Manual intervention may be required."
                    # Continue anyway - let DistCp attempt and fail with clear error
                fi
            else
                log "[DEBUG] Baseline snapshot $baseline_snap is valid - destination not modified since snapshot creation"
            fi
        fi

        # 4d) Run distcp diff from last_snap to next_snap (capture stderr for analysis)
        #      NOTE: Uses tee to write distcp stderr to temp file AND to stderr. Since
        #            stderr is redirected to stdout via exec 2>&1, output appears in
        #            real-time through the global tee process without buffering delays.
        src_uri="hdfs://$SOURCE_CLUSTER${d}"
        dst_uri="hdfs://$DEST_CLUSTER${d}"
        log_cmd "Syncing directory: $d ($last_snap -> $next_snap)"
        log "[DEBUG] Running distcp diff sync for $d"
        echo ""
        echo "=== DistCp Command ==="
        # Remove -update from COPY_OPTS and place it before -diff (required by DistCp)
        # All other options must come before -diff to avoid being treated as source paths
        COPY_OPTS_NO_UPDATE=$(echo "$COPY_OPTS" | sed 's/-update\s*/ /g' | sed 's/\s\+/ /g' | sed 's/^\s*//;s/\s*$//' || echo "$COPY_OPTS")
        echo "  hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS_NO_UPDATE -update -diff $last_snap $next_snap $src_uri $dst_uri"
        echo "======================"
        echo ""
        echo "[DEBUG MARKER] Starting DistCp execution for $d"
        DISTCP_STDERR_FILE="/tmp/distcp_err_${key}_$$.log"
        TEMP_FILES+=("$DISTCP_STDERR_FILE")
        # Use tee to write distcp stderr to temp file AND to stderr (which goes through
        # global redirection to LOG and console). Since stderr is redirected to stdout
        # via exec 2>&1, this ensures real-time output without buffering delays.
        if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS_NO_UPDATE -update -diff "$last_snap" "$next_snap" "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_STDERR_FILE" >&2); then
            DISTCP_SUCCESS=true
        else
            DISTCP_SUCCESS=false
        fi
        
        if [[ "$DISTCP_SUCCESS" == "true" ]]; then
            echo ""
            echo "[DEBUG MARKER] DistCp execution completed successfully for $d"
            log "[INFO] Distcp diff sync succeeded for $d"
            METRICS_SUCCESSFUL_DIRECTORIES=$((METRICS_SUCCESSFUL_DIRECTORIES + 1))
            echo ""
        else
            echo ""
            echo "============================================"
            echo ">>> [ERROR] [STAGE 4] DistCp FAILED for directory: $d <<<"
            echo "============================================"
            log "[ERROR] [Stage 4] Distcp diff sync failed for $d (see $DISTCP_STDERR_FILE)"
            # Show key error message from stderr if available
            if [[ -f "$DISTCP_STDERR_FILE" ]] && [[ -s "$DISTCP_STDERR_FILE" ]]; then
                echo ""
                echo "Key Error Messages:"
                grep -E "(ERROR|Exception|Failed|failed)" "$DISTCP_STDERR_FILE" | head -5 || echo "  No specific error messages found"
                # Analyze error and provide suggestions
                analyze_error "$DISTCP_STDERR_FILE"
            fi
            echo ""
            # Detect snapshot-modified symptom
            # For baseline snapshot, we already tried to fix it above, so this is for subsequent snapshots
            # For subsequent snapshots, use ROLLBACK_ON_FAILURE logic
            if grep -q "The target has been modified since snapshot" "$DISTCP_STDERR_FILE" 2>/dev/null ||
                grep -q "target has changed since snapshot" "$DISTCP_STDERR_FILE" 2>/dev/null; then
                # Check if this is baseline snapshot - if so, we already tried to fix it, so this is unexpected
                if [[ "$last_snap" == "$baseline_snap" ]]; then
                    log "[ERROR] Baseline snapshot modification detected but automatic fix failed or destination was modified again"
                    log "[ERROR] Manual intervention required. Consider re-running bootstrap."
                fi
                
                # For baseline or subsequent snapshots, honor hardcoded ROLLBACK_ON_FAILURE
                if [[ "${ROLLBACK_ON_FAILURE,,}" == "yes" ]]; then
                    echo ""
                    echo "=========================================================================================================================================="
                    echo ">>> [WARNING] SNAPSHOT-MODIFIED ERROR DETECTED for $d <<<"
                    echo "=========================================================================================================================================="
                    echo ">>> Error: The target has been modified since snapshot"
                    echo ">>> Action: Automatic rollback will be attempted (ROLLBACK_ON_FAILURE=yes)"
                    echo "=========================================================================================================================================="
                    log "[WARN] Detected snapshot-modified error. Attempting one-time rollback for this failure..."
                    if rollback_once_for_failure "$d" "$last_snap" "$next_snap"; then
                        echo ""
                        echo "=========================================================================================================================================="
                        echo ">>> [RETRY] RETRYING DistCp after successful rollback for $d <<<"
                        echo "=========================================================================================================================================="
                        log "[INFO] Rollback attempt completed; retrying DistCp once."
                        DISTCP_RETRY_STDERR="/tmp/distcp_retry_err_${key}_$$.log"
                        # NOTE: intentionally NOT added to TEMP_FILES so it persists after script exit for forensic inspection
                        # Use tee to write retry distcp stderr to temp file AND to stderr
                        # Reuse COPY_OPTS_NO_UPDATE from earlier in the function
                        log_cmd "DistCp Retry Command (post-rollback)"
                        echo "  hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS_NO_UPDATE -update -diff $last_snap $next_snap $src_uri $dst_uri"
                        echo "======================"
                        echo ""
                        if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS_NO_UPDATE -update -diff "$last_snap" "$next_snap" "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_RETRY_STDERR" >&2); then
                            DISTCP_RETRY_SUCCESS=true
                        else
                            DISTCP_RETRY_SUCCESS=false
                        fi
                        
                        if [[ "$DISTCP_RETRY_SUCCESS" == "true" ]]; then
                            echo ""
                            echo "------------------------------------------------------------------------------------------------------------------------------------------"
                            echo "[RETRY SUCCESS] DistCp retry succeeded for $d after rollback"
                            echo "------------------------------------------------------------------------------------------------------------------------------------------"
                            log "[INFO] Distcp diff sync succeeded on retry for $d"
                            METRICS_SUCCESSFUL_DIRECTORIES=$((METRICS_SUCCESSFUL_DIRECTORIES + 1))
                            echo ""
                        else
                            echo "============================================"
                            echo ">>> [ERROR] [STAGE 4] DistCp FAILED AGAIN after rollback for: $d <<<"
                            echo "============================================"
                            log "[ERROR] [Stage 4] Distcp still failed after rollback retry for $d. Retry error log: $DISTCP_RETRY_STDERR. Manual intervention required."
                            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                            if [[ -f "$DISTCP_RETRY_STDERR" ]] && [[ -s "$DISTCP_RETRY_STDERR" ]]; then
                                echo "Retry Error Messages:"
                                grep -E "(ERROR|Exception|Failed|failed)" "$DISTCP_RETRY_STDERR" | head -5 || echo "  No specific error messages found"
                                analyze_error "$DISTCP_RETRY_STDERR"
                                echo ""
                                echo "--- Full retry stderr (also saved to $DISTCP_RETRY_STDERR) ---"
                                cat "$DISTCP_RETRY_STDERR"
                                echo "--- End of retry stderr ---"
                            fi
                            echo ""
                            echo "=========================================================================================================================================="
                            echo ">>> [RECOVERY GUIDANCE] Manual steps to recover: $d <<<"
                            echo "=========================================================================================================================================="
                            echo ""
                            echo "  Incremental DistCp failed after rollback. Choose one of the following recovery options:"
                            echo ""
                            echo "  --- Option 1: Full DistCp (force full re-sync, no snapshot diff) ---"
                            echo ""
                            echo "    hadoop distcp $DISTCP_FULL_OPTS $COPY_OPTS $src_uri $dst_uri"
                            echo ""
                            echo "    After it completes:"
                            echo "      - Delete the 'next' snapshot from source (if created this run):"
                            echo "          hdfs dfs -fs hdfs://$SOURCE_CLUSTER -deleteSnapshot $d $next_snap"
                            echo "      - Re-run this script to resume incremental sync."
                            echo ""
                            echo "  --- Option 2: Inspect .snapshot dirs on both clusters ---"
                            echo ""
                            echo "    Source snapshots:"
                            echo "      hdfs dfs -fs hdfs://$SOURCE_CLUSTER -ls $d/.snapshot"
                            echo ""
                            echo "    Destination snapshots:"
                            echo "      hdfs dfs -fs hdfs://$DEST_CLUSTER -ls $d/.snapshot"
                            echo ""
                            echo "  --- Option 3: Recreate destination '$last_snap' snapshot and retrigger (RECOMMENDED) ---"
                            echo ""
                            echo "    The destination snapshot '$last_snap' may have stale metadata after rollback."
                            echo "    Recreating it refreshes the baseline so incremental DistCp can proceed."
                            echo ""
                            echo "      hdfs dfs -fs hdfs://$DEST_CLUSTER -deleteSnapshot $d $last_snap"
                            echo "      hdfs dfs -fs hdfs://$DEST_CLUSTER -createSnapshot $d $last_snap"
                            echo ""
                            echo "    Then re-run this script — incremental sync will resume from $last_snap -> $next_snap."
                            echo ""
                            echo "=========================================================================================================================================="
                            dir_end_ts=$(date +%s)
                            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                            ALL_OK=false
                            continue
                        fi
                    else
                        echo "============================================"
                        echo ">>> [ERROR] [STAGE 4] Rollback NOT performed for: $d <<<"
                        echo "============================================"
                    log "[WARN] [Stage 4] Rollback not performed (marker existed or failure during rollback). Manual intervention required for $d"
                    METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                    dir_end_ts=$(date +%s)
                    log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                    ALL_OK=false
                    continue
                    fi
                else
                    echo "============================================"
                    echo ">>> [ERROR] [STAGE 4] Automatic Rollback DISABLED for: $d <<<"
                    echo "============================================"
                    log "[WARN] [Stage 4] Detected snapshot-modified error but automatic rollback is disabled (ROLLBACK_ON_FAILURE=${ROLLBACK_ON_FAILURE}). Failing this directory."
                    log "[INFO] To enable automatic rollback, set ROLLBACK_ON_FAILURE=\"yes\" in the script."
                    METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                    dir_end_ts=$(date +%s)
                    log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                    ALL_OK=false
                    continue
                fi
            else
                echo "============================================"
                echo ">>> [ERROR] [STAGE 4] DistCp FAILED (non-snapshot error) for: $d <<<"
                echo "============================================"
                log "[ERROR] [Stage 4] DistCp failed due to non-snapshot reason. Manual inspection required. (see $DISTCP_STDERR_FILE)"
                log "[INFO] Check network connectivity, permissions, and cluster health."
                METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                dir_end_ts=$(date +%s)
                log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                ALL_OK=false
                continue
            fi
        fi

        # 4e) Create next_snap snapshot on destination after successful distcp
        echo ""
        log "[DEBUG] Creating next snapshot $next_snap on destination directory $d"
        out_dr_next=$(run_as_hdfs hdfs dfs -fs "hdfs://$DEST_CLUSTER" -createSnapshot "$d" "$next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
        log "[DEBUG] Destination snapshot creation output: $out_dr_next"
        if echo "$out_dr_next" | grep -q "already a snapshot with the same name"; then
            log "[WARN] Destination snapshot $next_snap already exists"
        elif echo "$out_dr_next" | grep -q "Created snapshot"; then
            log "[INFO] Destination snapshot $next_snap created"
        else
            log "[WARN] Destination snapshot creation failed or skipped: $out_dr_next"
        fi

        # 4f) Advance state (persist the last successful snapshot name)
        if write_state_file "$state" "$next_snap"; then
            log "[SYNC] State advanced to $next_snap for $d"
        else
            log "[ERROR] Failed to write state file $state"
        fi
        dir_end_ts=$(date +%s)
        log "[METRIC] [STAGE 4] Directory '$d' completed in $((dir_end_ts - dir_start_ts)) seconds"
        echo ""

        # 4g) Cleanup old snapshots on source (retain SNAP_RETAIN most recent, matching current prefix only)
        cleanup_old_snapshots "$SOURCE_CLUSTER" "$d" "source" "$SNAP_RETAIN" "$SNAP_PREFIX"

        # 4h) Cleanup old snapshots on destination (retain SNAP_RETAIN most recent, matching current prefix only)
        cleanup_old_snapshots "$DEST_CLUSTER" "$d" "destination" "$SNAP_RETAIN" "$SNAP_PREFIX"
    done
    
    # Stage 4 completion - only show errors if any occurred
    if [[ "$ALL_OK" != "true" ]]; then
        echo ""
        log "[WARN] [Stage 4] Some directories failed during incremental synchronization. Check logs above for details."
        echo ""
        echo "=========================================================================================================================================="
        echo ">>> [WARNING] STAGE 4 COMPLETED WITH ERRORS <<<"
        echo "=========================================================================================================================================="
        echo ""
    fi

    # -----------------------------------------------------------------------------
    # Final Summary and Completion
    # -----------------------------------------------------------------------------
    
    SCRIPT_END_TS=$(date +%s)
    SCRIPT_RUNTIME=$((SCRIPT_END_TS - SCRIPT_START_TS))
    SCRIPT_START_TIME=$(date -d "@$SCRIPT_START_TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$SCRIPT_START_TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "N/A")
    SCRIPT_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Calculate human-readable runtime
    RUNTIME_HOURS=$((SCRIPT_RUNTIME / 3600))
    RUNTIME_MINUTES=$(((SCRIPT_RUNTIME % 3600) / 60))
    RUNTIME_SECONDS=$((SCRIPT_RUNTIME % 60))
    if [[ $RUNTIME_HOURS -gt 0 ]]; then
        RUNTIME_STR="${RUNTIME_HOURS}h ${RUNTIME_MINUTES}m ${RUNTIME_SECONDS}s"
    elif [[ $RUNTIME_MINUTES -gt 0 ]]; then
        RUNTIME_STR="${RUNTIME_MINUTES}m ${RUNTIME_SECONDS}s"
    else
        RUNTIME_STR="${RUNTIME_SECONDS}s"
    fi
    
    # Determine overall status
    if [[ "$ALL_OK" == "true" ]] && [[ $METRICS_FAILED_DIRECTORIES -eq 0 ]]; then
        OVERALL_STATUS="SUCCESS"
        STATUS_ICON="[OK]"
    elif [[ $METRICS_FAILED_DIRECTORIES -gt 0 ]] && [[ $METRICS_SUCCESSFUL_DIRECTORIES -gt 0 ]]; then
        OVERALL_STATUS="PARTIAL"
        STATUS_ICON="[WARN]"
    else
        OVERALL_STATUS="FAILED"
        STATUS_ICON="[ERROR]"
    fi

    # -----------------------------------------------------------------------------
    # Final Summary
    # -----------------------------------------------------------------------------
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "DR REPLICATION SUMMARY"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo "Status              : $STATUS_ICON $OVERALL_STATUS"
    echo ""
    echo "Execution Details:"
    echo "  Start Time        : $SCRIPT_START_TIME"
    echo "  End Time          : $SCRIPT_END_TIME"
    echo "  Total Runtime     : $RUNTIME_STR ($SCRIPT_RUNTIME seconds)"
    echo ""
    echo "Cluster Configuration:"
    echo "  Source Cluster    : $SOURCE_CLUSTER"
    echo "  Destination       : $DEST_CLUSTER"
    echo "  Directories       : ${#SOURCE_DIRS[@]} directory(ies)"
    echo "    ${SOURCE_DIRS[*]}"
    echo ""
    echo "Settings:"
    echo "  Snapshot Prefix   : $SNAP_PREFIX"
    echo "  Snapshots Retained: $SNAP_RETAIN per directory"
    echo "  Kerberos          : ${KERBEROS_ENABLED^^}"
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo "  Execution Mode    : Kerberos (no sudo)"
    else
        echo "  Execution Mode    : sudo (${HDFS_USER}/${DISTCP_USER})"
    fi
    echo "  Log File          : $LOG"
    echo "────────────────────────────────────────────────────────────────────────────"
    echo ""
    
    log_stage_complete "5" "Completion"
    if [[ "$OVERALL_STATUS" == "FAILED" || "$OVERALL_STATUS" == "PARTIAL" ]]; then
        exit 1
    fi
}

main "$@"
