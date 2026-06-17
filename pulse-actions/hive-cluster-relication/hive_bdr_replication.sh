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
#     - Multi-database mode: Replicate multiple DBs in one invocation (pipe-delimited)
#     - Failover mode: Reverse replication direction after a cluster failover
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
#   1) HIVE_DB              - One or more Hive DB specs to replicate, separated by | (pipe)
#                              Single DB:    "sales"
#                              Multi DB:     "sales|analytics|hr"
#                              With tables:  "sales.'(t1|t2)'|analytics|hr.'orders'"
#                              Single table: "sales.'t1'"
#                              Exclude:      "sales.'(?!t1$).*'"
#                              NOTE: | inside single-quoted table patterns is NOT a separator
#   2) SRC_NAMESERVICE      - Source cluster nameservice (original primary)
#   3) DST_NAMESERVICE      - Destination cluster nameservice (original replica)
#   4) SRC_JDBC_URL         - Source HiveServer2 JDBC connection URL (original primary)
#   5) DST_JDBC_URL         - Destination HiveServer2 JDBC connection URL (original replica)
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
# Environment variable overrides:
#   DISTCP_QUEUE            - YARN queue for DistCp jobs (default: default)
#                              Example: DISTCP_QUEUE=replication ./hive_bdr.sh ...
#   FAILOVER_MODE           - Enable failover (direction reversal) for Hive BDR replication.
#                              Default: false
#                              Set to "true" when a failover has already occurred and DST has
#                              become the new primary cluster receiving production writes.
#
#                              Prerequisites:
#                                - Hive replication must already be configured and operational
#                                - At least one incremental REPL DUMP must have completed on DST
#                                  after bootstrap (Hive requires this before failover.start)
#                                - Cluster failover must have been completed
#                                - New writes must be occurring only on the DST cluster
#
#                              Workflow:
#                                Step 1: Disable existing scheduled queries on both clusters
#                                Step 2: REPL DUMP on DST (new primary) with
#                                        'hive.repl.failover.start'='true'
#                                Step 3: REPL LOAD on SRC (old primary, now new replica)
#                                Step 4: Create reversed scheduled queries:
#                                          DUMP on DST, LOAD on SRC
#                              This reverses replication so changes on the new primary (DST)
#                              are replicated back to the old primary (SRC).
#
#                              Example: FAILOVER_MODE=true ./hive_bdr.sh ...
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
# Example (Multi-database replication):
#   ./hive_bdr.sh \
#     "sales|analytics|hr.'orders'" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2"
#
# Example (Table-level replication - specific tables only):
#   ./hive_bdr.sh \
#     "sales.'(t1|orders|course)'" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2"
#
# Example (Incremental only - DB already exists):
#   Same as above - script will detect existing DB and skip bootstrap
#
# Example (Failover - reverse replication after ODP-Aurora became primary):
#   NOTE: Ensure at least one incremental REPL DUMP has completed on ODP-Aurora
#         after bootstrap, before enabling FAILOVER_MODE.
#   FAILOVER_MODE=true ./hive_bdr.sh \
#     "migration01" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "/user/hive/repl/" \
#     "-p -update -skipcrccheck" \
#     "/var/log/hive-replication" \
#     "" \
#     "EVERY 5 MINUTES" \
#     "00:03:00"
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

# Strip surrounding double-quotes that some callers (e.g. Pulse Actions) inject literally
HIVE_DB="${HIVE_DB#\"}"
HIVE_DB="${HIVE_DB%\"}"

# YARN queue for DistCp jobs (override via environment: DISTCP_QUEUE=myqueue)
DISTCP_QUEUE="${DISTCP_QUEUE:-default}"

# Failover mode: reverse replication direction (override via environment: FAILOVER_MODE=true)
FAILOVER_MODE="${FAILOVER_MODE:-false}"

# Normalize REPL_BASE_DIR to always have a trailing slash
REPL_BASE_DIR="${REPL_BASE_DIR%/}/"

# Validate mandatory parameters before deriving any variables from them
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

# parse_db_specs: split HIVE_DB on | only outside single-quoted sections.
# Populates the global DB_SPECS array with one entry per DB spec.
# Handles patterns like "sales.'(t1|t2)'|analytics" correctly — the pipe
# inside single quotes is part of the table regex, not a DB separator.
parse_db_specs() {
  local raw="$1"
  local parsed
  parsed=$(printf '%s' "$raw" | awk '
  BEGIN { token = ""; in_quote = 0 }
  {
    for (i = 1; i <= length($0); i++) {
      c = substr($0, i, 1)
      if (c == "'"'"'") { in_quote = !in_quote; token = token c }
      else if (c == "|" && !in_quote) { print token; token = "" }
      else { token = token c }
    }
  }
  END { if (token != "") print token }
  ')
  while IFS= read -r spec; do
    [[ -z "$spec" ]] && continue
    local q_count
    q_count=$(printf '%s' "$spec" | tr -cd "'" | wc -c)
    if (( q_count % 2 != 0 )); then
      echo "ERROR: Unmatched single quote in DB spec: '${spec}'"
      exit 1
    fi
    DB_SPECS+=("$spec")
  done <<< "$parsed"
  if [[ ${#DB_SPECS[@]} -eq 0 ]]; then
    echo "ERROR: No valid DB specs found in: '${raw}'"
    exit 1
  fi
}

# derive_db_vars: set all per-DB globals from a single spec string.
# Called at the start of each iteration so every function sees fresh values.
derive_db_vars() {
  local spec="$1"
  if [[ "$spec" == *.* ]]; then
    HIVE_DB_NAME="${spec%%.*}"
    HIVE_TABLE_PATTERN="${spec#*.}"
    HIVE_REPL_SPEC="${spec}"
  else
    HIVE_DB_NAME="${spec}"
    HIVE_TABLE_PATTERN=""
    HIVE_REPL_SPEC="${spec}"
  fi
  REPL_ROOT_DIR_SRC="hdfs://${SRC_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB_NAME}"
  # IMPORTANT: REPL LOAD must use the same nameservice as REPL DUMP
  REPL_ROOT_DIR_DST="${REPL_ROOT_DIR_SRC}"
  # Base directory on destination for replicated EXTERNAL tables (per-DB)
  REPL_EXTERNAL_BASE_DIR="hdfs://${DST_NAMESERVICE}/user/hive/external/${HIVE_DB_NAME}"
  SRC_SCHEDULED_QUERY_NAME="sq_repl_dump_${HIVE_DB_NAME}"
  DST_SCHEDULED_QUERY_NAME="sq_repl_load_${HIVE_DB_NAME}"
}

declare -a DB_SPECS=()
parse_db_specs "$HIVE_DB"

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
        while IFS= read -r cc; do
            [[ -f "$cc" ]] || continue
            if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                export KRB5CCNAME="$cc"
                echo "[INFO] Kerberos detected via Actions cache: $KRB5CCNAME"
                return 0
            fi
        done < <(ls -t "$pulse_cache_dir"/krb5cc_* 2>/dev/null)
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

TOTAL_STEPS=7
FAILOVER_TOTAL_STEPS=4

# Check if a scheduled query exists on a given cluster.
# Tries sys.scheduled_queries first; falls back to information_schema.scheduled_queries.
# Usage: check_scheduled_query_exists <jdbc_url> <query_name>
# Sets global SQ_CHECK_RESULT to the matched name (empty if not found).
check_scheduled_query_exists() {
  local jdbc_url="$1"
  local sq_name="$2"

  local sq_output
  local sq_sql="SELECT schedule_name FROM sys.scheduled_queries WHERE schedule_name = '${sq_name}';"
  echo "Executing: ${sq_sql}"
  sq_output=$( beeline -u "${jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "${sq_sql}" 2>&1 || true )

  # If sys.scheduled_queries is not available, fall back to information_schema
  if echo "$sq_output" | grep -q "Table not found.*scheduled_queries"; then
    echo "[INFO] sys.scheduled_queries not available, trying information_schema.scheduled_queries"
    sq_sql="SELECT schedule_name FROM information_schema.scheduled_queries WHERE schedule_name = '${sq_name}';"
    echo "Executing: ${sq_sql}"
    sq_output=$( beeline -u "${jdbc_url}" \
      --silent=true \
      --showHeader=false \
      --outputformat=tsv2 \
      -e "${sq_sql}" 2>&1 || true )

    # If information_schema also doesn't have the table, no scheduled queries exist yet
    if echo "$sq_output" | grep -q "Table not found.*scheduled_queries"; then
      echo "[INFO] information_schema.scheduled_queries also not available — no scheduled queries exist yet"
      SQ_CHECK_RESULT=""
      return 0
    fi
  fi

  SQ_CHECK_RESULT=$(echo "$sq_output" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | head -n 1 || true)

  # Validate: if we got output but it doesn't match expected name, it's an error
  if [[ -n "$SQ_CHECK_RESULT" && "$SQ_CHECK_RESULT" != "${sq_name}" ]]; then
    echo "ERROR: Scheduled query exist check returned unexpected output"
    echo "$sq_output"
    return 1
  fi
  return 0
}

# disable_scheduled_query: disable a scheduled query if it exists; no-op if absent.
# Usage: disable_scheduled_query <jdbc_url> <query_name>
disable_scheduled_query() {
  local jdbc_url="$1"
  local sq_name="$2"

  if ! check_scheduled_query_exists "${jdbc_url}" "${sq_name}"; then
    echo "ERROR: Could not check existence of scheduled query '${sq_name}'"
    exit 1
  fi

  if [[ -z "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${sq_name}' does not exist — nothing to disable."
    return 0
  fi

  local sql="ALTER SCHEDULED QUERY ${sq_name} DISABLE;"
  echo "Executing: ${sql}"
  beeline -u "${jdbc_url}" -e "${sql}"
  echo "Scheduled query '${sq_name}' disabled."
}

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
  if ! check_scheduled_query_exists "${SRC_JDBC_URL}" "${SRC_SCHEDULED_QUERY_NAME}"; then
    echo "ERROR: Scheduled query exist check failed on source"
    exit 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${SRC_SCHEDULED_QUERY_NAME}' already exists on source. Skipping creation."
  else
    local dump_sql="CREATE SCHEDULED QUERY ${SRC_SCHEDULED_QUERY_NAME} ${dump_schedule} AS
REPL DUMP ${HIVE_REPL_SPEC} WITH(
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
  if ! check_scheduled_query_exists "${DST_JDBC_URL}" "${DST_SCHEDULED_QUERY_NAME}"; then
    echo "ERROR: Scheduled query exist check failed on destination"
    exit 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${DST_SCHEDULED_QUERY_NAME}' already exists on destination. Skipping creation."
  else
    local load_sql="CREATE SCHEDULED QUERY ${DST_SCHEDULED_QUERY_NAME} ${load_schedule} AS
REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
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

# create_reversed_scheduled_queries: create DUMP on DST and LOAD on SRC
# (reversed direction, used after failover).
create_reversed_scheduled_queries() {
  local dump_schedule="${SCHEDULE_EXPR}"
  local load_offset="${LOAD_OFFSET}"

  if [[ -z "$dump_schedule" ]]; then
    echo "No schedule expression provided; skipping reversed scheduled queries."
    return
  fi

  echo "$SEP"
  echo " Configuring Reversed Scheduled Queries (Post-Failover Incremental)"
  echo "$SEP"
  echo "New primary (DUMP source) : $DST_NAMESERVICE"
  echo "New replica (LOAD target) : $SRC_NAMESERVICE"
  echo "Dump schedule             : ${dump_schedule}"
  echo "Load offset               : ${load_offset}"
  echo ""

  # Reversed query names have a _reverse suffix to avoid collision with old ones
  local rev_dump_sq_name="sq_repl_dump_${HIVE_DB_NAME}_reverse"
  local rev_load_sq_name="sq_repl_load_${HIVE_DB_NAME}_reverse"

  # Build load schedule with offset
  local load_schedule
  if [[ "$dump_schedule" =~ ^EVERY ]]; then
    load_schedule="${dump_schedule} OFFSET BY '${load_offset}'"
  else
    load_schedule="${dump_schedule}"
    echo "Note: CRON schedule detected - load will use same schedule as dump (offset not applied to CRON)"
  fi

  echo "$SUBSEP"
  # DUMP scheduled query on DST (new primary)
  echo "Checking if reversed dump scheduled query exists on new primary (${DST_NAMESERVICE}): ${rev_dump_sq_name}"
  if ! check_scheduled_query_exists "${DST_JDBC_URL}" "${rev_dump_sq_name}"; then
    echo "ERROR: Scheduled query exist check failed on new primary"
    exit 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Reversed dump scheduled query '${rev_dump_sq_name}' already exists on new primary. Skipping creation."
  else
    local dump_sql="CREATE SCHEDULED QUERY ${rev_dump_sq_name} ${dump_schedule} AS
REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating reversed dump scheduled query on new primary (${DST_NAMESERVICE}): ${rev_dump_sq_name}"
    echo "Executing: ${dump_sql}"
    echo ""
    beeline -u "${DST_JDBC_URL}" -e "${dump_sql}"
  fi
  echo ""

  echo "$SUBSEP"
  # LOAD scheduled query on SRC (new replica / old primary)
  echo "Checking if reversed load scheduled query exists on new replica (${SRC_NAMESERVICE}): ${rev_load_sq_name}"
  if ! check_scheduled_query_exists "${SRC_JDBC_URL}" "${rev_load_sq_name}"; then
    echo "ERROR: Scheduled query exist check failed on new replica"
    exit 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Reversed load scheduled query '${rev_load_sq_name}' already exists on new replica. Skipping creation."
  else
    local load_sql="CREATE SCHEDULED QUERY ${rev_load_sq_name} ${load_schedule} AS
REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating reversed load scheduled query on new replica (${SRC_NAMESERVICE}): ${rev_load_sq_name}"
    echo "Executing: ${load_sql}"
    echo ""
    beeline -u "${SRC_JDBC_URL}" -e "${load_sql}"
  fi
  echo ""

  echo "$SUBSEP"
  echo " Reversed scheduled query setup completed"
  echo "  DUMP: ${rev_dump_sq_name} on ${DST_NAMESERVICE}"
  echo "  LOAD: ${rev_load_sq_name} on ${SRC_NAMESERVICE}"
  echo ""
}

# failover_one_db: perform the 4-step failover sequence for a single DB.
#   Step 1: Disable existing scheduled queries on both clusters
#   Step 2: REPL DUMP with failover.start=true on DST (new primary)
#   Step 3: REPL LOAD on SRC (old primary, now new replica)
#   Step 4: Create reversed scheduled queries (DUMP on DST, LOAD on SRC)
failover_one_db() {
  local db_spec="$1"
  local db_index="$2"
  local db_total="$3"

  derive_db_vars "$db_spec"

  LOG_FILE="$LOG_DIR/hive_bdr_failover_${HIVE_DB_NAME}_$(date +%Y%m%d_%H%M%S).log"

  SEP="======================================================================"
  SUBSEP="----------------------------------------------------------------------"

  echo "$SEP"
  echo " Hive Failover Replication - DB ${db_index}/${db_total}: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo "Timestamp        : $(date)"
  echo "Database         : $HIVE_DB_NAME"
  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    echo "Tables           : $HIVE_TABLE_PATTERN"
  fi
  echo "Original primary : $SRC_NAMESERVICE (now new replica)"
  echo "Original replica : $DST_NAMESERVICE (now new primary)"
  echo "Log File         : $LOG_FILE"
  echo ""

  ########################################
  # Failover Step 1: Disable existing scheduled queries
  ########################################
  echo "$SUBSEP"
  echo "[1/${FAILOVER_TOTAL_STEPS}] Disabling existing scheduled queries..."
  echo ""

  echo "Disabling dump scheduled query on original primary (${SRC_NAMESERVICE}): ${SRC_SCHEDULED_QUERY_NAME}"
  disable_scheduled_query "${SRC_JDBC_URL}" "${SRC_SCHEDULED_QUERY_NAME}"
  echo ""

  echo "Disabling load scheduled query on original replica (${DST_NAMESERVICE}): ${DST_SCHEDULED_QUERY_NAME}"
  disable_scheduled_query "${DST_JDBC_URL}" "${DST_SCHEDULED_QUERY_NAME}"
  echo ""

  ########################################
  # Failover Step 2: REPL DUMP with failover.start=true on DST (new primary)
  ########################################
  echo "$SUBSEP"
  echo "[2/${FAILOVER_TOTAL_STEPS}] Running failover REPL DUMP on new primary (${DST_NAMESERVICE})..."

  local FAILOVER_DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
'hive.repl.failover.start'='true',
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${DST_NAMESERVICE}: ${FAILOVER_DUMP_CMD}"
  echo ""
  beeline -u "${DST_JDBC_URL}" -e "${FAILOVER_DUMP_CMD}"
  echo ""

  ########################################
  # Failover Step 3: REPL LOAD on SRC (old primary, now new replica)
  # No DistCp needed — rootdir is on SRC nameservice, accessible from both clusters.
  ########################################
  echo "$SUBSEP"
  echo "[3/${FAILOVER_TOTAL_STEPS}] Running failover REPL LOAD on new replica (${SRC_NAMESERVICE})..."

  local FAILOVER_LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${SRC_NAMESERVICE}: ${FAILOVER_LOAD_CMD}"
  echo ""
  beeline -u "${SRC_JDBC_URL}" -e "${FAILOVER_LOAD_CMD}"
  echo ""

  echo "Validating replication status on new replica (${SRC_NAMESERVICE})..."
  beeline -u "${SRC_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};"
  echo ""

  ########################################
  # Failover Step 4: Create reversed scheduled queries
  ########################################
  echo "$SUBSEP"
  echo "[4/${FAILOVER_TOTAL_STEPS}] Setting up reversed incremental replication..."
  create_reversed_scheduled_queries

  echo ""
  echo "$SEP"
  echo " Failover Replication Completed: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo ""
  echo "Database         : $HIVE_DB_NAME"
  echo "New primary      : $DST_NAMESERVICE (writes here)"
  echo "New replica      : $SRC_NAMESERVICE (receives replication)"
  if [[ -n "$SCHEDULE_EXPR" ]]; then
    echo "Reversed Scheduled Queries:"
    echo "  - DUMP (new primary ${DST_NAMESERVICE}): sq_repl_dump_${HIVE_DB_NAME}_reverse"
    echo "  - LOAD (new replica ${SRC_NAMESERVICE}): sq_repl_load_${HIVE_DB_NAME}_reverse"
    echo "  - Schedule : $SCHEDULE_EXPR"
    [[ "$SCHEDULE_EXPR" =~ ^EVERY ]] && echo "  - Load Offset: $LOAD_OFFSET"
  fi
  echo ""
  echo "Completed        : $(date)"
  echo "Log File         : $LOG_FILE"
  echo ""
  echo "$SEP"
  echo ""
}

replicate_one_db() {
  local db_spec="$1"
  local db_index="$2"
  local db_total="$3"

  derive_db_vars "$db_spec"

  ########################################
  # Logging (per-DB log file)
  ########################################
  LOG_FILE="$LOG_DIR/hive_bdr_${HIVE_DB_NAME}_$(date +%Y%m%d_%H%M%S).log"

  SEP="======================================================================"
  SUBSEP="----------------------------------------------------------------------"

  echo "$SEP"
  echo " Hive Cluster Replication - DB ${db_index}/${db_total}: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo "Timestamp : $(date)"
  echo "Database  : $HIVE_DB_NAME"
  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    echo "Tables    : $HIVE_TABLE_PATTERN"
  fi
  echo "Source NS : $SRC_NAMESERVICE"
  echo "Dest NS   : $DST_NAMESERVICE"
  echo "YARN Queue: $DISTCP_QUEUE"
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
    -e "SHOW DATABASES LIKE '${HIVE_DB_NAME}';" 2>&1 || true )

  DB_EXISTS=$(echo "$DB_CHECK_OUTPUT" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1 || true)

  if [[ -n "$DB_EXISTS" && "$DB_EXISTS" != "${HIVE_DB_NAME}" ]]; then
    echo "ERROR: Database exist check failed on destination"
    echo "$DB_CHECK_OUTPUT"
    exit 1
  fi

  ########################################
  # 3. Decide replication mode
  ########################################
  echo "$SUBSEP"
  echo "[2/${TOTAL_STEPS}] Determining replication mode..."

  local BOOTSTRAP
  if [[ -n "$DB_EXISTS" ]]; then
    echo "Database '${HIVE_DB_NAME}' exists on destination cluster - Incremental replication mode"
    BOOTSTRAP=false
  else
    echo "Database '${HIVE_DB_NAME}' DOES NOT exist on destination cluster - Bootstrap mode"
    BOOTSTRAP=true
  fi
  echo ""

  if [[ "$BOOTSTRAP" == "true" ]]; then
    # Trap errors during bootstrap to warn about potential partial state
    trap 'echo ""; echo "ERROR: Bootstrap failed at $(date). The destination database may be in an inconsistent state."; echo "Before re-running, check: REPL STATUS ${HIVE_DB_NAME} on destination and clean up if needed."; echo "Log File: $LOG_FILE"' ERR

    ########################################
    # 4. Run REPL DUMP (SOURCE) - Bootstrap
    ########################################
    echo "$SUBSEP"
    echo "[3/${TOTAL_STEPS}] Running REPL DUMP on source cluster (Bootstrap)..."

    DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
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
    DISTCP_DEST_DIR="hdfs://${DST_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB_NAME}"
    echo "Source: ${REPL_ROOT_DIR_SRC}"
    echo "Dest  : ${DISTCP_DEST_DIR}"
    echo ""

    # Build DistCp command as array for safe execution (no eval)
    # shellcheck disable=SC2206
    DISTCP_CMD=(hadoop distcp
      "-Dmapreduce.job.queuename=${DISTCP_QUEUE}"
      "-Dmapreduce.job.tags=hive-repl-distcp-${HIVE_DB_NAME}"
      ${DISTCP_MAPREDUCE_OPTS}
      ${DISTCP_OPTS}
      "${REPL_ROOT_DIR_SRC}"
      "${DISTCP_DEST_DIR}")

    echo "$SUBSEP"
    echo "Executing DistCp command:"
    echo "${DISTCP_CMD[*]}"
    echo ""

    "${DISTCP_CMD[@]}"
    echo ""

    ########################################
    # Wait to ensure dump data is fully visible on destination
    ########################################
    echo "Verifying DistCp data is visible on destination: ${DISTCP_DEST_DIR}"
    WAIT_TIMEOUT=300
    WAIT_INTERVAL=5
    WAITED=0
    while ! hdfs dfs -test -d "${DISTCP_DEST_DIR}" 2>/dev/null; do
      sleep ${WAIT_INTERVAL}
      WAITED=$((WAITED + WAIT_INTERVAL))
      if [[ ${WAITED} -ge ${WAIT_TIMEOUT} ]]; then
        echo "ERROR: Dump directory not visible on destination after ${WAIT_TIMEOUT}s: ${DISTCP_DEST_DIR}"
        exit 1
      fi
      echo "  Waiting for dump directory... (${WAITED}s/${WAIT_TIMEOUT}s)"
    done
    echo "Dump directory confirmed on destination (waited ${WAITED}s)"
    echo ""

    ########################################
    # 6. REPL LOAD (DESTINATION) - Bootstrap
    ########################################
    echo "$SUBSEP"
    echo "[5/${TOTAL_STEPS}] Running REPL LOAD on destination cluster (Bootstrap)..."

    # Add bootstrap-specific properties to destination JDBC URL
    DST_JDBC_URL_BOOTSTRAP="${DST_JDBC_URL};hive.repl.copyfile.use.distcp=false;hive.repl.copyfile.max.retries=50"

    LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
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

    beeline -u "${DST_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};"
    echo ""

    # Bootstrap completed successfully — clear the error trap
    trap - ERR
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
  echo " Hive Cluster Replication Completed: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo ""
  echo "Database     : $HIVE_DB_NAME"
  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    echo "Tables       : $HIVE_TABLE_PATTERN"
  fi
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
}

########################################
# 1. Logging (top-level, tee to a session log covering all DBs)
########################################

mkdir -p "$LOG_DIR"
SESSION_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_LOG_FILE="$LOG_DIR/hive_bdr_session_${SESSION_TIMESTAMP}.log"

exec > >(tee -a "$SESSION_LOG_FILE") 2>&1

SEP="======================================================================"
SUBSEP="----------------------------------------------------------------------"

DB_COUNT=${#DB_SPECS[@]}

echo "$SEP"
echo " Hive Cluster Replication Script Started"
echo "$SEP"
echo "Timestamp    : $(date)"
echo "Databases    : ${DB_COUNT} (${HIVE_DB})"
echo "Source NS    : $SRC_NAMESERVICE"
echo "Dest NS      : $DST_NAMESERVICE"
echo "YARN Queue   : $DISTCP_QUEUE"
echo "Failover Mode: $FAILOVER_MODE"
echo "Session Log  : $SESSION_LOG_FILE"
echo ""

########################################
# Main loop — replicate (or failover) each DB spec in sequence
########################################
DB_IDX=0
FAILED_DBS=()
for db_spec in "${DB_SPECS[@]}"; do
  DB_IDX=$(( DB_IDX + 1 ))
  echo "$SEP"
  echo " Processing DB ${DB_IDX}/${DB_COUNT}: ${db_spec}"
  echo "$SEP"

  if [[ "$FAILOVER_MODE" == "true" ]]; then
    if ! failover_one_db "$db_spec" "$DB_IDX" "$DB_COUNT"; then
      echo "ERROR: Failover failed for DB spec: ${db_spec}"
      FAILED_DBS+=("$db_spec")
    fi
  else
    if ! replicate_one_db "$db_spec" "$DB_IDX" "$DB_COUNT"; then
      echo "ERROR: Replication failed for DB spec: ${db_spec}"
      FAILED_DBS+=("$db_spec")
    fi
  fi
done

echo "$SEP"
echo " All Databases Processed"
echo "$SEP"
echo "Total     : ${DB_COUNT}"
echo "Failed    : ${#FAILED_DBS[@]}"
if [[ ${#FAILED_DBS[@]} -gt 0 ]]; then
  echo "Failed DBs:"
  for f in "${FAILED_DBS[@]}"; do
    echo "  - $f"
  done
  echo ""
  echo "Session Log: $SESSION_LOG_FILE"
  exit 1
fi
echo ""
echo "Session Log: $SESSION_LOG_FILE"
echo ""
