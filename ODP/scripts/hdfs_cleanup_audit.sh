#!/bin/bash
#
# Copyright (c) 2026 Acceldata Inc.
#
# hdfs_cleanup_audit.sh
# Cleanup script for HDFS Ranger audit directories
# Supports Kerberos, safe delete, bulk delete, parallel delete
#

# Exit immediately on any error, treat unset variables as errors,
# and propagate failures through pipes rather than masking them.
set -euo pipefail

# Require bash 4+ for mapfile
(( BASH_VERSINFO[0] >= 4 )) || { echo "ERROR: bash 4.0+ required (found: $BASH_VERSION)"; exit 1; }


# ── Defaults ──────────────────────────────────────────────────────────────────
# All path defaults can be overridden at runtime via --base-path and --keytab.
BASE_PATH="/ranger/audit"
KEYTAB="/etc/security/keytabs/hdfs.headless.keytab"
DRY_RUN=true
DELETE_OLDER_THAN_DAYS=""
KEEP_LAST=""
DELETE_MODE="safe"        # safe | bulk | parallel
PARALLEL_THREADS=8
LOG_DIR="${LOG_DIR:-/var/log}"
LOG_FILE="${LOG_DIR}/hdfs_cleanup_audit_$(date +%Y%m%d_%H%M%S).log"

# Exclusive lock prevents overlapping executions (e.g. from cron).
LOCKFILE="/tmp/hdfs_cleanup_audit.lock"


# ── Terminal Colors ────────────────────────────────────────────────────────────
# Must be checked before the exec/tee redirect below (which makes -t 1 false).
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[1;31m'
    C_CYAN=$'\033[36m'
    C_BOLD_CYAN=$'\033[1;36m'
    C_YELLOW=$'\033[33m'
    C_BOLD_YELLOW=$'\033[1;33m'
    C_GREEN=$'\033[32m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_CYAN='' C_BOLD_CYAN=''
    C_YELLOW='' C_BOLD_YELLOW='' C_GREEN=''
fi


# ── Logging ───────────────────────────────────────────────────────────────────
# Mirror all stdout and stderr to a timestamped log file for audit trail.
# Falls back to /tmp if LOG_DIR is not writable.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null \
    || LOG_FILE="/tmp/hdfs_cleanup_audit_$(date +%Y%m%d_%H%M%S).log"
# Terminal receives colored output; log file receives ANSI-stripped clean text.
exec > >(tee >(sed 's/\x1B\[[0-9;]*[a-zA-Z]//g' >> "$LOG_FILE")) 2>&1

log() {
    local msg="$*"
    local color="$C_RESET"
    case "$msg" in
        *"ERROR:"*)                       color="$C_RED" ;;
        *"WARNING:"*)                     color="$C_BOLD_YELLOW" ;;
        "(Dry-run)"* | *"Dry-run"*)       color="$C_CYAN" ;;
        "──"*)                            color="$C_DIM" ;;
        *"Summary:"*)                     color="$C_BOLD_CYAN" ;;
        "Starting "*)                     color="$C_BOLD" ;;
        "  Deleted:"* | \
        "Kerberos authentication "*)      color="$C_GREEN" ;;
        "Nothing to delete"*)             color="$C_YELLOW" ;;
    esac
    echo "${C_DIM}[$(date '+%Y-%m-%d %H:%M:%S')]${C_RESET} ${color}${msg}${C_RESET}"
}

log "Log file: $LOG_FILE"


# ── Acquire lock ──────────────────────────────────────────────────────────────
exec 200>"$LOCKFILE"
flock -n 200 || { log "ERROR: Another instance is already running (lock: $LOCKFILE)"; exit 1; }


############################################
# Usage
############################################
usage() {
    local script
    script=$(basename "$0")
    cat <<EOF

${C_BOLD_CYAN}HDFS Ranger Audit Cleanup Script${C_RESET}
${C_DIM}---------------------------------${C_RESET}
Removes dated Ranger audit directories from HDFS.
Runs in dry-run mode by default — pass ${C_BOLD}--force${C_RESET} to perform actual deletion.

${C_BOLD_YELLOW}Usage:${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--delete-older-than${C_RESET} ${C_YELLOW}<days>${C_RESET}    Delete all date folders older than N days
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--keep-last${C_RESET} ${C_YELLOW}<count>${C_RESET}           Keep only the N most recent folders per service

${C_BOLD_YELLOW}Options:${C_RESET}
  ${C_CYAN}--force${C_RESET}                               Perform actual deletion ${C_DIM}(default: dry-run)${C_RESET}
  ${C_CYAN}--delete-mode${C_RESET} ${C_YELLOW}<mode>${C_RESET}                  Deletion strategy ${C_DIM}(default: safe)${C_RESET}
                                          ${C_GREEN}safe${C_RESET}     — one folder at a time; safest, slowest
                                          ${C_GREEN}bulk${C_RESET}     — all folders in a single hdfs command
                                          ${C_GREEN}parallel${C_RESET} — up to ${C_BOLD}$PARALLEL_THREADS${C_RESET} concurrent threads; fastest
  ${C_CYAN}--base-path${C_RESET} ${C_YELLOW}<path>${C_RESET}                    HDFS audit base path ${C_DIM}(default: $BASE_PATH)${C_RESET}
  ${C_CYAN}--keytab${C_RESET}    ${C_YELLOW}<path>${C_RESET}                    Kerberos keytab file ${C_DIM}(default: $KEYTAB)${C_RESET}
  ${C_CYAN}--help, -h${C_RESET}                            Show this help message

${C_BOLD_YELLOW}Examples:${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--delete-older-than${C_RESET} ${C_YELLOW}30${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--delete-older-than${C_RESET} ${C_YELLOW}30${C_RESET} ${C_CYAN}--force${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--delete-older-than${C_RESET} ${C_YELLOW}30${C_RESET} ${C_CYAN}--force --delete-mode${C_RESET} ${C_GREEN}parallel${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--keep-last${C_RESET} ${C_YELLOW}10${C_RESET}
  ${C_BOLD}$script${C_RESET} ${C_CYAN}--keep-last${C_RESET} ${C_YELLOW}10${C_RESET} ${C_CYAN}--force --delete-mode${C_RESET} ${C_GREEN}bulk${C_RESET}

EOF
    exit 1
}


############################################
# Parse Arguments
############################################
# Show usage immediately when invoked with no arguments.
[[ $# -eq 0 ]] && usage

while [[ $# -gt 0 ]]; do
    case "$1" in
        --delete-older-than)
            DELETE_OLDER_THAN_DAYS=$2
            shift 2
            ;;
        --keep-last)
            KEEP_LAST=$2
            shift 2
            ;;
        --force)
            DRY_RUN=false
            shift
            ;;
        --delete-mode)
            DELETE_MODE=$2
            shift 2
            ;;
        # Override default paths for non-standard cluster layouts.
        --base-path)
            BASE_PATH=$2
            shift 2
            ;;
        --keytab)
            KEYTAB=$2
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        *)
            log "ERROR: Unknown argument: $1"
            usage
            ;;
    esac
done


############################################
# Validate Arguments
############################################
if [[ -n "$DELETE_OLDER_THAN_DAYS" && -n "$KEEP_LAST" ]]; then
    log "ERROR: Use only ONE option: --delete-older-than OR --keep-last"
    exit 1
fi

# Exactly one deletion mode must be supplied.
if [[ -z "$DELETE_OLDER_THAN_DAYS" && -z "$KEEP_LAST" ]]; then
    log "ERROR: Must specify --delete-older-than OR --keep-last"
    usage
fi

# Reject non-integer values early to prevent silent bad behaviour from date/awk.
if [[ -n "$DELETE_OLDER_THAN_DAYS" ]] && ! [[ "$DELETE_OLDER_THAN_DAYS" =~ ^[0-9]+$ ]]; then
    log "ERROR: --delete-older-than must be a positive integer, got: '$DELETE_OLDER_THAN_DAYS'"
    exit 1
fi

if [[ -n "$KEEP_LAST" ]] && ! [[ "$KEEP_LAST" =~ ^[0-9]+$ ]]; then
    log "ERROR: --keep-last must be a positive integer, got: '$KEEP_LAST'"
    exit 1
fi

# Validate delete mode upfront so errors surface before any HDFS operations begin.
case "$DELETE_MODE" in
    safe|bulk|parallel) ;;
    *)
        log "ERROR: Invalid --delete-mode '$DELETE_MODE'. Must be: safe | bulk | parallel"
        exit 1
        ;;
esac

log "Starting HDFS Ranger Audit Cleanup"
log "  BASE_PATH    : $BASE_PATH"
log "  DRY_RUN      : $DRY_RUN"
log "  DELETE_MODE  : $DELETE_MODE"


############################################
# Kerberos Authentication
############################################
auth=""
if [[ -f /etc/hadoop/conf/core-site.xml ]]; then
    auth=$(grep -A2 '<name>hadoop.security.authentication</name>' \
            /etc/hadoop/conf/core-site.xml \
            | grep '<value>' | cut -d'>' -f2 | cut -d'<' -f1 || true)
fi

log "Authentication type: ${auth:-simple}"

hdfs_kerberos() {
    if [[ "$auth" == "kerberos" ]]; then
        log "Kerberos enabled. Running kinit..."

        if [[ ! -f "$KEYTAB" ]]; then
            log "ERROR: Keytab missing: $KEYTAB"
            exit 1
        fi

        # klist -kt output has 3 header lines; skip them and take the first principal entry.
        local principal
        principal=$(klist -kt "$KEYTAB" | awk 'NR>3 {print $NF; exit}')
        if [[ -z "$principal" ]]; then
            log "ERROR: Could not extract principal from keytab."
            exit 1
        fi

        log "Using principal: $principal"
        if ! kinit -kt "$KEYTAB" "$principal"; then
            log "ERROR: kinit failed."
            exit 1
        fi

        log "Kerberos authentication successful."
    else
        log "Kerberos not enabled. Continuing without kinit."
    fi
}

hdfs_kerberos


############################################
# Cutoff Date — portable across GNU (Linux) and BSD (macOS) date
############################################
compute_cutoff() {
    local days=$1
    if date --version >/dev/null 2>&1; then
        # GNU date (Linux)
        date -d "$days days ago" +%Y%m%d
    else
        # BSD date (macOS)
        date -v "-${days}d" +%Y%m%d
    fi
}


############################################
# List & sort directories
############################################
log ""
log "Collecting audit directories under $BASE_PATH ..."

# Capture HDFS stderr to a temp file so connection or permission errors
# surface in the log rather than being silently discarded.
HDFS_ERR=$(mktemp)
DIRS=$(hdfs dfs -ls -d "$BASE_PATH"/*/* 2>"$HDFS_ERR" | sort -t/ -k5,5 || true)

if [[ -s "$HDFS_ERR" ]]; then
    # Filter out harmless SLF4J classpath binding warnings that every hdfs command emits.
    # Only surface genuine errors (NameNode issues, permission denied, etc.).
    if grep -qv '^SLF4J:' "$HDFS_ERR"; then
        log "WARNING: HDFS listing produced errors:"
        grep -v '^SLF4J:' "$HDFS_ERR"
    fi
fi
rm -f "$HDFS_ERR"

if [[ -z "$DIRS" ]]; then
    log "No directories found under $BASE_PATH"
    exit 0
fi

log "$DIRS"
log ""

# Derive the awk field index for the service name based on BASE_PATH depth.
# e.g. BASE_PATH=/ranger/audit → NF=3 → service name is at field 4 in the full path.
# This avoids a hardcoded field number that breaks if BASE_PATH depth changes.
SVC_FIELD=$(awk -F/ '{print NF+1}' <<< "$BASE_PATH")


############################################
# Space Usage — human-readable logical and on-disk sizes under BASE_PATH
# hdfs dfs -du -s -h returns: LOGICAL_SIZE  ON_DISK_SIZE  PATH
# ON_DISK_SIZE = LOGICAL_SIZE × replication factor (typically 3×)
############################################
space_used() {
    local out
    out=$(hdfs dfs -du -s -h "$BASE_PATH" 2>/dev/null) || { echo "unknown"; return; }
    local logical on_disk
    logical=$(awk '{print $1, $2}' <<< "$out")
    on_disk=$(awk '{print $3, $4}' <<< "$out")
    echo "logical: ${logical}  |  on-disk (with replicas): ${on_disk}"
}


############################################
# Delete Helper — wraps all three delete modes with error tracking
############################################
hdfs_delete() {
    local mode=$1
    shift
    local -a paths=("$@")
    local errors=0

    case "$mode" in
        safe)
            log "Deleting one-by-one (safe mode)..."
            for d in "${paths[@]}"; do
                if hdfs dfs -rm -r -skipTrash "$d"; then
                    log "  Deleted: $d"
                else
                    log "  ERROR: Failed to delete: $d"
                    (( errors++ )) || true
                fi
            done
            ;;
        bulk)
            log "Bulk deleting ${#paths[@]} path(s) at once..."
            if hdfs dfs -rm -r -skipTrash "${paths[@]}"; then
                log "  Bulk delete succeeded."
            else
                log "  ERROR: Bulk delete failed."
                errors=1
            fi
            ;;
        parallel)
            log "Parallel deleting ${#paths[@]} path(s) with $PARALLEL_THREADS threads..."
            # Each failed path is appended to a temp file so all failures are
            # reported together after xargs completes, not interleaved with output.
            local fail_log
            fail_log=$(mktemp)
            # $fail_log expands now (outer shell); \$1 expands per-job (inner bash -c)
            printf "%s\n" "${paths[@]}" \
                | xargs -P"$PARALLEL_THREADS" -I{} \
                    bash -c "hdfs dfs -rm -r -skipTrash \"\$1\" || echo \"\$1\" >> \"$fail_log\"" \
                    _ {}
            if [[ -s "$fail_log" ]]; then
                log "  ERROR: The following paths failed to delete:"
                cat "$fail_log"
                errors=$(wc -l < "$fail_log" | tr -d ' ')
            fi
            rm -f "$fail_log"
            ;;
    esac

    if [[ $errors -gt 0 ]]; then
        log "WARNING: $errors deletion(s) failed."
        return 1
    fi
    return 0
}


############################################
# DELETE older than N days
############################################
if [[ -n "$DELETE_OLDER_THAN_DAYS" ]]; then
    log "Mode: delete folders older than $DELETE_OLDER_THAN_DAYS days"
    CUTOFF=$(compute_cutoff "$DELETE_OLDER_THAN_DAYS")
    log "Cutoff date: $CUTOFF (folders strictly before this date will be deleted)"

    delete_list=()

    while read -r line; do
        FOLDER=$(awk '{print $NF}' <<< "$line")
        DATE=$(basename "$FOLDER")

        # Guard: only process YYYYMMDD-named directories to avoid mismatches
        if [[ "$DATE" =~ ^[0-9]{8}$ ]] && [[ "$DATE" < "$CUTOFF" ]]; then
            delete_list+=("$FOLDER")
        fi
    done <<< "$DIRS"

    log "Folders to delete (${#delete_list[@]}):"
    printf '  %s\n' "${delete_list[@]}"
    log ""

    if [[ "${#delete_list[@]}" -eq 0 ]]; then
        log "Nothing to delete."
        exit 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log ""
        log "──────────────────────────────────────────"
        log "Dry-run Summary:"
        log "  Folders that would be deleted  : ${#delete_list[@]}"
        log "──────────────────────────────────────────"
        log "(Dry-run) No deletion performed. Use --force to execute."
        exit 0
    fi

    SPACE_BEFORE=$(space_used)
    hdfs_delete "$DELETE_MODE" "${delete_list[@]}"
    SPACE_AFTER=$(space_used)

    log ""
    log "──────────────────────────────────────────"
    log "Summary:"
    log "  Folders deleted  : ${#delete_list[@]}"
    log "  Space before     : $SPACE_BEFORE"
    log "  Space after      : $SPACE_AFTER"
    log "──────────────────────────────────────────"
    exit 0
fi


############################################
# KEEP LAST N folders per service
############################################
if [[ -n "$KEEP_LAST" ]]; then
    log "Mode: keep last $KEEP_LAST folders per service"

    # Extract distinct service names using the depth-aware SVC_FIELD index.
    SERVICES=$(awk '{print $NF}' <<< "$DIRS" \
        | awk -F/ -v f="$SVC_FIELD" '{print $f}' \
        | sort -u)

    TOTAL_DELETED=0
    TOTAL_ERRORS=0
    TOTAL_WOULD_DELETE=0
    SPACE_BEFORE=""

    # Capture space before the deletion loop — only meaningful for actual runs.
    [[ "$DRY_RUN" == false ]] && SPACE_BEFORE=$(space_used)

    for svc in $SERVICES; do
        log ""
        log "Service: $svc"

        # mapfile populates the array one element per line, avoiding
        # word splitting on paths that contain spaces.
        mapfile -t svc_dirs < <(grep "/$svc/" <<< "$DIRS" | awk '{print $NF}' | sort)
        total=${#svc_dirs[@]}

        if [[ $total -le $KEEP_LAST ]]; then
            log "  $total folder(s) present — at or below threshold ($KEEP_LAST). Nothing to delete."
            continue
        fi

        num_to_delete=$(( total - KEEP_LAST ))
        # Oldest folders are first after sort; slice from the front
        delete_list=("${svc_dirs[@]:0:$num_to_delete}")

        log "  Total: $total | To delete: $num_to_delete | To keep: $KEEP_LAST"
        log "  Folders to delete:"
        printf '    %s\n' "${delete_list[@]}"
        log ""

        if [[ "$DRY_RUN" == true ]]; then
            log "  (Dry-run) No deletion performed. Use --force to execute."
            TOTAL_WOULD_DELETE=$(( TOTAL_WOULD_DELETE + num_to_delete ))
            continue
        fi

        if hdfs_delete "$DELETE_MODE" "${delete_list[@]}"; then
            TOTAL_DELETED=$(( TOTAL_DELETED + num_to_delete ))
        else
            TOTAL_ERRORS=$(( TOTAL_ERRORS + 1 ))
        fi
    done

    log ""
    log "──────────────────────────────────────────"

    if [[ "$DRY_RUN" == true ]]; then
        log "Dry-run Summary:"
        log "  Total folders that would be deleted  : $TOTAL_WOULD_DELETE"
        log "──────────────────────────────────────────"
        log "(Dry-run) No deletion performed. Use --force to execute."
        exit 0
    fi

    SPACE_AFTER=$(space_used)
    log "Summary:"
    log "  Total folders deleted  : $TOTAL_DELETED"
    log "  Services with errors   : $TOTAL_ERRORS"
    log "  Space before           : $SPACE_BEFORE"
    log "  Space after            : $SPACE_AFTER"
    log "──────────────────────────────────────────"

    if [[ $TOTAL_ERRORS -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

usage
