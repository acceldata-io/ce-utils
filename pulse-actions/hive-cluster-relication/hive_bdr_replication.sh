#!/bin/bash
# -----------------------------------------------------------------------------
# Hive Cluster Replication Script
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
#
# Description:
#   This script automates Hive metastore and data replication between clusters
#   using Hive REPL DUMP/LOAD commands and DistCp for data transfer.
#   Supports:
#     - Bootstrap mode: Full initial replication when destination DB doesn't exist
#     - Incremental mode: Scheduled queries for ongoing replication when DB exists
#     - If schedule_expr is provided, creates scheduled queries for incremental replication
#
# Usage:
#   ./hive_bdr.sh \
#     "<HIVE_DB>" \
#     "<SRC_NAMESERVICE>" \
#     "<DST_NAMESERVICE>" \
#     "<SRC_JDBC_URL>" \
#     "<DST_JDBC_URL>" \
#     "<REPL_BASE_DIR>" \
#     "<DISTCP_OPTS>" \
#     "<LOG_DIR>" \
#     "<DISTCP_MAPREDUCE_OPTS>" \
#     "<SCHEDULE_EXPR>" \
#     "<LOAD_OFFSET>"
#
# Positional arguments (order matters):
#   1) HIVE_DB              - Hive database name to replicate
#   2) SRC_NAMESERVICE      - Source cluster nameservice
#   3) DST_NAMESERVICE      - Destination cluster nameservice
#   4) SRC_JDBC_URL         - Source HiveServer2 JDBC connection URL
#   5) DST_JDBC_URL         - Destination HiveServer2 JDBC connection URL
#   6) REPL_BASE_DIR        - Base replication directory (default: /user/hive/repl/)
#   7) DISTCP_OPTS          - DistCp options (default: -p -update -skipcrccheck)
#   8) LOG_DIR              - Log directory path (default: /var/log/hive-replication)
#   9) DISTCP_MAPREDUCE_OPTS - Additional DistCp mapreduce options
#   10) SCHEDULE_EXPR        - Optional Hive SCHEDULED QUERY expression for incremental runs
#                              Example: "CRON '0 */10 * * * ? *'" or "EVERY 30 MINUTES"
#   11) LOAD_OFFSET          - Time offset for LOAD schedule (default: 00:03:00)
#                              Applies only to EVERY schedules, not CRON
#                              Example: "00:05:00" for 5 minute delay
#
# Example (Bootstrap + Scheduled Incremental):
#   ./hive_bdr.sh \
#     "migration01" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "/user/hive/repl/" \
#     "-p -update -skipcrccheck" \
#     "/var/log/hive-replication" \
#     "-Dmapreduce.job.ha-hdfs.token-renewal.exclude=ODP-Aurora" \
#     "EVERY 5 MINUTES" \
#     "00:03:00"
#
# Example (Incremental only - DB already exists):
#   Same as above - script will detect existing DB and skip bootstrap
#
# Note: LOAD schedule will be offset by LOAD_OFFSET from DUMP schedule
#   DUMP: EVERY 5 MINUTES → runs at 0, 5, 10, 15, 20, 25...
#   LOAD: EVERY 5 MINUTES OFFSET BY '00:03:00' → runs at 3, 8, 13, 18, 23, 28...
#
# -----------------------------------------------------------------------------

set -euo pipefail

####################################
# Variables - Accept from positional arguments with defaults
####################################

HIVE_DB="${1:-}"
SRC_NAMESERVICE="${2:-}"
DST_NAMESERVICE="${3:-}"
SRC_JDBC_URL="${4:-}"
DST_JDBC_URL="${5:-}"
REPL_BASE_DIR="${6:-/user/hive/repl/}"
DISTCP_OPTS="${7:--p -update -skipcrccheck}"
LOG_DIR="${8:-/var/log/hive-replication}"
DISTCP_MAPREDUCE_OPTS="${9:--Dmapreduce.job.ha-hdfs.token-renewal.exclude=${DST_NAMESERVICE}}"
SCHEDULE_EXPR="${10:-}"
LOAD_OFFSET="${11:-00:03:00}"

# Detect HA enabled if both SRC_NAMESERVICE and DST_NAMESERVICE do NOT contain ':'
if [[ "$SRC_NAMESERVICE" != *:* ]] && [[ "$DST_NAMESERVICE" != *:* ]]; then
  HA_ENABLED=true
else
  HA_ENABLED=false
fi

# Define HDFS_TOKEN_EXCLUDE_PROP based on HA_ENABLED
if [[ "$HA_ENABLED" == true ]]; then
  HDFS_TOKEN_EXCLUDE_PROP="'mapreduce.job.hdfs-servers.token-renewal.exclude'='${SRC_NAMESERVICE},${DST_NAMESERVICE}',"
else
  HDFS_TOKEN_EXCLUDE_PROP=""
fi

# Validate mandatory parameters
if [[ -z "$HIVE_DB" ]]; then
    echo "Error: HIVE_DB (argument 1) is required"
    exit 1
fi
if [[ -z "$SRC_NAMESERVICE" ]]; then
    echo "Error: SRC_NAMESERVICE (argument 2) is required"
    exit 1
fi
if [[ -z "$DST_NAMESERVICE" ]]; then
    echo "Error: DST_NAMESERVICE (argument 3) is required"
    exit 1
fi
if [[ -z "$SRC_JDBC_URL" ]]; then
    echo "Error: SRC_JDBC_URL (argument 4) is required"
    exit 1
fi
if [[ -z "$DST_JDBC_URL" ]]; then
    echo "Error: DST_JDBC_URL (argument 5) is required"
    exit 1
fi

########################################
# Kerberos credential cache (KRB5CCNAME) - pick from Actions path first
# When kinit is run from Actions (adaxn-krb), cache is saved under $PULSE_HOME/actions/tmp (e.g. /opt/pulse/actions/tmp ).
# Shell kinit typically uses /tmp/krb5cc_<uid>. This block detects and sets KRB5CCNAME so beeline, hadoop, hdfs use the same cache.
########################################
detect_and_set_kerberos_cache() {
    if ! command -v klist >/dev/null 2>&1; then
        return 0
    fi
    # 1) If KRB5CCNAME is already set (e.g. passed from plugin env), trust but verify
    if [[ -n "${KRB5CCNAME:-}" ]]; then
        if klist -s 2>/dev/null; then
            export KRB5CCNAME
            echo "[INFO] Using Kerberos cache from environment: $KRB5CCNAME"
            return 0
        fi
        echo "[WARN] KRB5CCNAME is set but invalid: $KRB5CCNAME"
    fi
    # 2) Acceldata/Pulse Actions cache: $PULSE_HOME/actions/tmp
    local pulse_cache_dir="/opt/pulse/actions/tmp"
    if [[ ! -d "$pulse_cache_dir" ]] && [[ -f "/etc/default/hydra" ]]; then
        local pulse_home
        pulse_home=$(grep "^PULSE_HOME=" /etc/default/hydra 2>/dev/null | head -1 | sed -E 's/^PULSE_HOME=//' | sed -E 's/^["'\'']|["'\'']$//g' || echo "")
        if [[ -n "$pulse_home" ]]; then
            pulse_cache_dir="${pulse_home}/actions/tmp"
        fi
    fi
    if [[ -d "$pulse_cache_dir" ]]; then
        local cc
        for cc in "$pulse_cache_dir"/krb5cc_*; do
            [[ -f "$cc" ]] || continue
            if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                export KRB5CCNAME="$cc"
                echo "[INFO] Kerberos detected via Actions cache: $KRB5CCNAME"
                return 0
            fi
        done
    fi
    # 3) Fallback: /tmp/krb5cc_<uid>
    local uid cc_tmp
    uid="$(id -u 2>/dev/null || echo 0)"
    cc_tmp="/tmp/krb5cc_${uid}"
    if [[ -f "$cc_tmp" ]]; then
        if KRB5CCNAME="$cc_tmp" klist -s 2>/dev/null; then
            export KRB5CCNAME="$cc_tmp"
            echo "[INFO] Kerberos detected via default cache: $KRB5CCNAME"
            return 0
        fi
    fi
    # 4) Final fallback: default klist
    if klist -s 2>/dev/null; then
        echo "[INFO] Kerberos using default credential cache"
        return 0
    fi
    return 0
}
detect_and_set_kerberos_cache

# Derived variables
REPL_ROOT_DIR_SRC="hdfs://${SRC_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB}"
# IMPORTANT: REPL LOAD must use the same nameservice as REPL DUMP
REPL_ROOT_DIR_DST="${REPL_ROOT_DIR_SRC}"
# Base directory on destination for replicated EXTERNAL tables (per-DB)
REPL_EXTERNAL_BASE_DIR="hdfs://${DST_NAMESERVICE}/user/hive/external/${HIVE_DB}"

SRC_SCHEDULED_QUERY_NAME="sq_repl_dump_${HIVE_DB}"
DST_SCHEDULED_QUERY_NAME="sq_repl_load_${HIVE_DB}"
TOTAL_STEPS=7

create_scheduled_queries() {
  local dump_schedule="${SCHEDULE_EXPR}"
  local load_offset="${LOAD_OFFSET}"

  if [[ -z "$dump_schedule" ]]; then
    echo "No schedule expression provided; skipping scheduled queries."
    return
  fi

  echo "$SEP"
  echo " Configuring Hive Scheduled Queries (Incremental Replication)"
  echo "$SEP"
  echo "Dump schedule: ${dump_schedule}"
  echo "Load offset: ${load_offset}"
  echo ""

  # Build load schedule with offset
  local load_schedule
  if [[ "$dump_schedule" =~ ^EVERY ]]; then
    load_schedule="${dump_schedule} OFFSET BY '${load_offset}'"
  else
    # For CRON expressions, use same schedule (can't easily offset CRON)
    load_schedule="${dump_schedule}"
    echo "Note: CRON schedule detected - load will use same schedule as dump (offset not applied to CRON)"
  fi

  echo "$SUBSEP"
  # Check if source scheduled query already exists
  echo "Checking if scheduled query exists on source: ${SRC_SCHEDULED_QUERY_NAME}"
  SRC_SQ_OUTPUT=$( beeline -u "${SRC_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "SELECT schedule_name FROM sys.scheduled_queries WHERE schedule_name LIKE '${SRC_SCHEDULED_QUERY_NAME}%';" 2>&1 || true )

  SRC_SQ_EXISTS=$(echo "$SRC_SQ_OUTPUT" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | head -n 1 || true)

  if [[ -n "$SRC_SQ_EXISTS" && "$SRC_SQ_EXISTS" != "${SRC_SCHEDULED_QUERY_NAME}"* ]]; then
    echo "ERROR: Scheduled query exist check failed on source"
    echo "$SRC_SQ_OUTPUT"
    exit 1
  fi

  if [[ -n "$SRC_SQ_EXISTS" ]]; then
    echo "Scheduled query '${SRC_SCHEDULED_QUERY_NAME}' already exists on source. Skipping creation."
  else
    local dump_sql="CREATE SCHEDULED QUERY ${SRC_SCHEDULED_QUERY_NAME} ${dump_schedule} AS
REPL DUMP ${HIVE_DB} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating scheduled query on source: ${SRC_SCHEDULED_QUERY_NAME}"
    echo "Executing: ${dump_sql}"
    echo ""
    beeline -u "${SRC_JDBC_URL}" -e "${dump_sql}"
  fi
  echo ""

  echo "$SUBSEP"
  # Check if destination scheduled query already exists
  echo "Checking if scheduled query exists on destination: ${DST_SCHEDULED_QUERY_NAME}"

  DST_SQ_OUTPUT=$( beeline -u "${DST_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "SELECT schedule_name FROM sys.scheduled_queries WHERE schedule_name LIKE '${DST_SCHEDULED_QUERY_NAME}%';" 2>&1 || true )

  DST_SQ_EXISTS=$(echo "$DST_SQ_OUTPUT" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | head -n 1 || true)

  if [[ -n "$DST_SQ_EXISTS" && "$DST_SQ_EXISTS" != "${DST_SCHEDULED_QUERY_NAME}"* ]]; then
    echo "ERROR: Scheduled query exist check failed on destination"
    echo "$DST_SQ_OUTPUT"
    exit 1
  fi

  if [[ -n "$DST_SQ_EXISTS" ]]; then
    echo "Scheduled query '${DST_SCHEDULED_QUERY_NAME}' already exists on destination. Skipping creation."
  else
    local load_sql="CREATE SCHEDULED QUERY ${DST_SCHEDULED_QUERY_NAME} ${load_schedule} AS
REPL LOAD ${HIVE_DB} INTO ${HIVE_DB} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating scheduled query on destination: ${DST_SCHEDULED_QUERY_NAME}"
    echo "Executing: ${load_sql}"
    echo ""
    beeline -u "${DST_JDBC_URL}" -e "${load_sql}"
  fi
  echo ""

  echo "$SUBSEP"
  echo " Scheduled query setup completed"
  echo ""
}


########################################
# 1. Logging
########################################

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/hive_bdr_${HIVE_DB}_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

SEP="======================================================================"
SUBSEP="----------------------------------------------------------------------"

echo "$SEP"
echo " Hive Cluster Replication Script Started"
echo "$SEP"
echo "Timestamp : $(date)"
echo "Database  : $HIVE_DB"

echo "Source NS : $SRC_NAMESERVICE"
echo "Dest NS   : $DST_NAMESERVICE"
echo "Log File  : $LOG_FILE"
echo ""

########################################
# 2. Check DB existence on destination
########################################
echo "$SUBSEP"
echo "[1/${TOTAL_STEPS}] Checking if database exists on destination..."

DB_CHECK_OUTPUT=$( beeline -u "${DST_JDBC_URL}" \
  --silent=true \
  --showHeader=false \
  --outputformat=tsv2 \
  -e "SHOW DATABASES LIKE '${HIVE_DB}';" 2>&1 || true )

DB_EXISTS=$(echo "$DB_CHECK_OUTPUT" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | head -n 1 || true)

if [[ -n "$DB_EXISTS" && "$DB_EXISTS" != "${HIVE_DB}"* ]]; then
  echo "ERROR: Database exist check failed on destination"
  echo "$DB_CHECK_OUTPUT"
  exit 1
fi

########################################
# 3. Decide replication mode
########################################
echo "$SUBSEP"
echo "[2/${TOTAL_STEPS}] Determining replication mode..."

if [[ -n "$DB_EXISTS" ]]; then
  echo "Database '${HIVE_DB}' exists on destination cluster - Incremental replication mode"
  BOOTSTRAP=false
else
  echo "Database '${HIVE_DB}' DOES NOT exist on destination cluster - Bootstrap mode"
  BOOTSTRAP=true
fi
echo ""

if [[ "$BOOTSTRAP" == "true" ]]; then
  ########################################
  # 4. Run REPL DUMP (SOURCE) - Bootstrap
  ########################################
  echo "$SUBSEP"
  echo "[3/${TOTAL_STEPS}] Running REPL DUMP on source cluster (Bootstrap)..."

  DUMP_CMD="REPL DUMP ${HIVE_DB} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "$SUBSEP"
  echo "Executing: $DUMP_CMD"
  echo ""

  beeline -u "${SRC_JDBC_URL}" -e "$DUMP_CMD"
  echo ""

  ########################################
  # 5. DistCp dump to destination - Bootstrap
  ########################################
  echo "$SUBSEP"
  echo "[4/${TOTAL_STEPS}] Running DistCp from source to destination (Bootstrap)..."
  DISTCP_DEST_DIR="hdfs://${DST_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB}"
  echo "Source: ${REPL_ROOT_DIR_SRC}"
  echo "Dest  : ${DISTCP_DEST_DIR}"
  echo ""

  DISTCP_CMD="hadoop distcp ${DISTCP_MAPREDUCE_OPTS} ${DISTCP_OPTS} \"${REPL_ROOT_DIR_SRC}\" \"${DISTCP_DEST_DIR}\""

  echo "$SUBSEP"
  echo "Executing DistCp command:"
  echo "${DISTCP_CMD}"
  echo ""

  eval ${DISTCP_CMD}
  echo ""

  ########################################
  # Wait to ensure dump metadata is fully visible
  ########################################
  echo "Waiting 30 seconds before REPL LOAD to allow dump to stabilize..."
  sleep 30
  echo ""
  ########################################
  # 6. REPL LOAD (DESTINATION) - Bootstrap
  ########################################
  echo "$SUBSEP"
  echo "[5/${TOTAL_STEPS}] Running REPL LOAD on destination cluster (Bootstrap)..."

  # Add bootstrap-specific properties to destination JDBC URL
  DST_JDBC_URL_BOOTSTRAP="${DST_JDBC_URL};hive.repl.copyfile.use.distcp=false;hive.repl.copyfile.max.retries=50"

  LOAD_CMD="REPL LOAD ${HIVE_DB} INTO ${HIVE_DB} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Ensuring external table base directory exists on destination: ${REPL_EXTERNAL_BASE_DIR}"
  hdfs dfs -mkdir -p "${REPL_EXTERNAL_BASE_DIR}" || true
  hdfs dfs -chmod 1777 "${REPL_EXTERNAL_BASE_DIR}" || true
  echo ""

  echo "$SUBSEP"
  echo "Executing: $LOAD_CMD"
  echo "Note: Using bootstrap JDBC properties (copyfile.use.distcp=false, max.retries=50)"
  echo ""

  beeline -u "${DST_JDBC_URL_BOOTSTRAP}" -e "$LOAD_CMD"
  echo ""

  ########################################
  # 7. Post-load validation - Bootstrap
  ########################################
  echo "$SUBSEP"
  echo "[6/${TOTAL_STEPS}] Validating replication status on destination..."
  echo ""

  beeline -u "${DST_JDBC_URL}" -e "REPL STATUS ${HIVE_DB};"
  echo ""
else
  echo "$SUBSEP"
  echo "[3-6/${TOTAL_STEPS}] Skipping bootstrap steps - Database already exists on destination"
  echo ""
fi

########################################
# 8. Setup Scheduled Queries for Incremental Replication
########################################
echo "$SUBSEP"
echo "[7/${TOTAL_STEPS}] Setting up incremental replication..."
create_scheduled_queries

echo ""
echo "$SEP"
echo " Hive Cluster Replication Completed"
echo "$SEP"
echo ""
echo "Database     : $HIVE_DB"
echo "Mode         : $([ "$BOOTSTRAP" = "true" ] && echo "Bootstrap + Incremental" || echo "Incremental Only")"
echo "Source       : $SRC_NAMESERVICE"
echo "Destination  : $DST_NAMESERVICE"
echo ""
if [[ -n "$SCHEDULE_EXPR" ]]; then
  echo "Scheduled Queries:"
  echo "  - DUMP (Source): $SRC_SCHEDULED_QUERY_NAME"
  echo "  - LOAD (Dest)  : $DST_SCHEDULED_QUERY_NAME"
  echo "  - Schedule     : $SCHEDULE_EXPR"
  [[ "$SCHEDULE_EXPR" =~ ^EVERY ]] && echo "  - Load Offset  : $LOAD_OFFSET"
  echo ""
fi
echo "Completed    : $(date)"
echo "Log File     : $LOG_FILE"
echo ""
echo "$SEP"
echo ""
