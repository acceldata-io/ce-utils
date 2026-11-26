#!/bin/bash
# ==============================================================================
#  ATLAS METADATA REPLICATION SCRIPT
#  Copyright (c) 2026 Acceldata Inc. All rights reserved.
# ==============================================================================
#
#  PURPOSE
#  -------
#  Replicates Apache Atlas metadata (entities, classifications, lineage, type definitions) for
#  Hive databases/tables from a source cluster's Atlas to a destination (DR) cluster's Atlas,
#  and is designed to run as a Pulse "New Action".
#
#  It drives Atlas's own Export / Import REST APIs, one INCLUDE_FILTERS row at a time:
#
#    STEP 1 - Read the CHECKPOINT (the change marker of the last successful replication of this
#             row in this direction, if any). Its presence/absence decides bootstrap vs.
#             incremental mode.
#    STEP 2 - POST /api/atlas/admin/export on the SOURCE Atlas. The response is a zip archive,
#             saved under LOG_DIR on the host running this script.
#               - Bootstrap   -> everything connected to the matched entities
#               - Incremental -> only entities changed since the checkpoint
#    STEP 3 - Validate the archive and read its operation status, change marker and entity
#             count.
#    STEP 4 - POST /api/atlas/admin/import on the DESTINATION Atlas with that archive.
#    STEP 5 - Write the new checkpoint, ONLY after the import reported success, and print the
#             row's summary. A failed run leaves the last-good checkpoint untouched, so the
#             next run safely retries the same delta (Atlas import is an upsert).
#  These are the STEP numbers the run log prints; a row with nothing new skips STEP 4.
#
#  WHEN A CHECKPOINT IS NOT TRUSTED
#  A checkpoint says "everything up to this change marker is on the destination". A row is
#  bootstrapped again (full export), even though a checkpoint exists, when:
#    - its export settings changed since the checkpoint was written (SKIP_LINEAGE, FETCH_TYPE
#      connected <-> incremental/full, db_type/table_type, IMPORT_TRANSFORMS), or
#    - its database/table is not on the destination Atlas (destination rebuilt or purged).
#      Checked for bare-database and plain-table rows when IMPORT_TRANSFORMS is not used.
#  After an import of such a row the script also confirms the database/table is on the
#  destination before it advances the checkpoint. To force a bootstrap by hand, delete the
#  row's ".marker" file in CHECKPOINT_DIR.
#  A row that was replicated before and no longer matches anything on the source (dropped or
#  renamed) FAILS: the destination still holds it and the script cannot remove it.
#  A FAILED bootstrap records nothing: the next run starts the full export again from scratch
#  (Atlas import is an upsert, so whatever a failed import already wrote is simply rewritten).
#
#  The host running this script needs HTTP(S) access to both Atlas services. No HDFS, Hive or
#  YARN access is used.
#
#  MODES OF OPERATION
#  -------------------
#    - Bootstrap mode    : No checkpoint exists yet for the row in this direction. Runs a full
#                           export + import.
#    - Incremental mode  : A checkpoint exists. Exports only what changed since its change
#                           marker. Re-run the script on a schedule to keep the destination
#                           current.
#    - Multi-row mode    : One invocation can replicate many databases/tables at once via
#                           INCLUDE_FILTERS (see below). Each row is replicated independently:
#                           one row's failure never blocks the others, and a final summary
#                           reports success/failure per row.
#
# USAGE
# -----
#   ./atlas_bdr_replication.sh \
#     "<INCLUDE_FILTERS>" \
#     "<SRC_ATLAS_URL>" \
#     "<DST_ATLAS_URL>" \
#     "<SRC_CLUSTER_NAME>" \
#     "<DST_CLUSTER_NAME>" \
#     "<LOG_DIR>" \
#     "<CHECKPOINT_DIR>" \
#     "<ATLAS_USER>" \
#     "<ATLAS_PASSWORD>" \
#     "<FETCH_TYPE>" \
#     "<SKIP_LINEAGE>" \
#     "<ATLAS_TUNING>" \
#     "<IMPORT_TRANSFORMS>"
#
# POSITIONAL ARGUMENTS
# ---------------------
#   All arguments are positional, NOT environment variables. This is deliberate: Pulse Actions
#   has no facility to pass environment variables into a script invocation, only positional
#   arguments. Order matters. Trailing arguments may be omitted and fall back to their defaults.
#
#   #   Name                 Required?   Default                                   Description
#   --  -------------------  ----------  ----------------------------------------  ------------------------------------------------
#   1   INCLUDE_FILTERS      MANDATORY   (none)                                    Databases/tables to replicate. See below.
#   2   SRC_ATLAS_URL        MANDATORY   (none)                                    Source Atlas base URL(s).
#   3   DST_ATLAS_URL        MANDATORY   (none)                                    Destination Atlas base URL(s).
#   4   SRC_CLUSTER_NAME     optional    default                                   Source Atlas's atlas.cluster.name.
#   5   DST_CLUSTER_NAME     optional    default                                   Destination Atlas's atlas.cluster.name.
#   6   LOG_DIR              optional    /var/log/atlas-replication                Run logs and export archives.
#   7   CHECKPOINT_DIR       optional    /var/tmp/pulse_atlas_replication_action   One checkpoint per row+direction. Local path.
#   8   ATLAS_USER           optional    admin                                     Atlas user (basic auth), or Kerberos principal name to prefer.
#   9   ATLAS_PASSWORD       optional    (none, i.e. Kerberos)                     ATLAS_USER's password, in plain text. Selects basic auth.
#   10  FETCH_TYPE           optional    incremental                               incremental | full | connected.
#   11  SKIP_LINEAGE         optional    false                                     "true" to leave lineage out of the export.
#   12  ATLAS_TUNING         optional    (none)                                    "key=value,..." tuning knobs. See below.
#   13  IMPORT_TRANSFORMS    optional    (none)                                    Raw Atlas import-transforms JSON. See below.
#
#   Argument details:
#
#   1) INCLUDE_FILTERS (MANDATORY)
#      Comma-separated "database:table_regex" pairs - the same format iceberg_bdr_replication.sh
#      and the other replication actions use.
#        Examples:
#          "sales_db:orders"                    one table: sales_db.orders and nothing else
#          "sales_db:orders,sales_db:customers" two named tables of one database, as two rows
#          "sales_db:orders|customers"          the same two tables, as one row (regex alternation)
#          "sales_db:orders_.*,analytics"       every sales_db table starting with "orders_", and
#                                               the whole analytics database
#      A bare database name with no ":" (or "db:.*") replicates the database entity and everything
#      connected to it - every table, column, storage descriptor and, unless SKIP_LINEAGE=true,
#      their lineage.
#      How each row is turned into an Atlas export request:
#        - bare database        -> typeName hive_db,    qualifiedName "db@SRC_CLUSTER_NAME",       matchType equals
#        - plain table name     -> typeName hive_table, qualifiedName "db.table@SRC_CLUSTER_NAME", matchType equals
#        - table regex          -> typeName hive_table, qualifiedName "db\.(regex)@SRC_CLUSTER_NAME", matchType matches
#      A table export also carries the entities connected to that table (its database, columns,
#      storage descriptor), so the destination holds a complete, browsable table.
#      LINEAGE SCOPE: a table row carries only that table's IMMEDIATE lineage - the processes
#      that read or wrote it and the tables/paths directly on the other side of them. The
#      lineage of those neighbouring tables (further upstream or downstream hops) is not part
#      of the export. To reproduce a whole lineage chain on the destination, replicate every
#      table in the chain - most simply by passing the bare database name, so all its tables
#      and their lineage are exported together.
#      Details of how the spec is read:
#        - Rows are separated by commas, but a comma inside brackets belongs to the regex:
#          "sales_db:orders_[0-9]{1,3}" is ONE row. Whitespace around a row is ignored.
#        - Database and table names are lower-cased, as Hive stores them and as they appear in
#          Atlas qualifiedNames.
#        - An invalid database name: that row is skipped and reported, every OTHER row is still
#          replicated, and the run ends FAILED so it cannot be missed.
#        - A row that matches no entity on the source is reported under "Skipped" in the run
#          summary (it replicates nothing).
#      Each row has its own checkpoint and its own lock.
#
#   2) SRC_ATLAS_URL (MANDATORY)
#      Base URL of the source cluster's Atlas, without the /api/atlas suffix. For Atlas HA pass
#      every instance, comma-separated; the script uses the one that reports ACTIVE.
#        Examples: "http://atlas1.src.example.com:21000"
#                  "https://atlas1.src.example.com:21443,https://atlas2.src.example.com:21443"
#
#   3) DST_ATLAS_URL (MANDATORY)
#      Base URL(s) of the destination cluster's Atlas. Same format as SRC_ATLAS_URL above.
#
#   4) SRC_CLUSTER_NAME (optional, default: "default")
#      The value of the atlas.cluster.name property of the SOURCE Atlas (Ambari: Atlas >
#      Configs > Advanced application-properties). This is NOT the Ambari/ODP cluster name. It is
#      the part after "@" in that Atlas's qualifiedNames (e.g. "default" in
#      "sales_db.orders@default"), and "default" unless it was changed. Used to build the
#      qualifiedName of every INCLUDE_FILTERS row and as "replicatedFrom" on the import.
#
#   5) DST_CLUSTER_NAME (optional, default: "default")
#      The value of atlas.cluster.name of the DESTINATION Atlas, same rules. Used, when
#      replicated_to=true (see ATLAS_TUNING), as "replicatedTo" on the export.
#
#   6) LOG_DIR (optional, default: "/var/log/atlas-replication")
#      Directory where this script writes its run log, named
#      "atlas_bdr_run_<databases>_<YYYYmmdd_HHMMSS>_<pid>.log", and the export archives
#      (LOG_DIR/exports). After a SUCCESSFUL row only its most recent archives are kept (see
#      retain_exports under ATLAS_TUNING); a FAILED row's archive is kept for debugging.
#
#   7) CHECKPOINT_DIR (optional, default: "/var/tmp/pulse_atlas_replication_action")
#      LOCAL directory, on the host running the script, holding one checkpoint per row PER
#      REPLICATION DIRECTION, and the per-row lock files (flock). Unlike the Iceberg action's
#      CHECKPOINT_DIR this is not an HDFS path: this script has no HDFS access. Every run for
#      the same rows must therefore be started from the same host (or share this directory);
#      a run that cannot see the checkpoint does a full export again, which is safe but slow.
#
#   8) ATLAS_USER (optional, default: "admin")
#      With ATLAS_PASSWORD: the Atlas user for basic authentication.
#      With Kerberos: selects the credential cache by principal name when several caches are
#      present on disk (the Pulse Actions scenario, where multiple service tickets can coexist) -
#      e.g. "atlas" picks the cache whose principal is atlas/<host>@REALM or atlas@REALM. If no
#      cache matches, the newest valid one is used.
#
#   9) ATLAS_PASSWORD (optional, default: "" - Kerberos)
#      ATLAS_USER's password, in plain text. Passing it selects basic authentication for BOTH
#      clusters. Left empty, the script uses Kerberos (SPNEGO) with an existing ticket and fails
#      at startup if there is no valid ticket. The value is passed as an argument because Pulse
#      Actions can only pass positional arguments; it is therefore visible in the Pulse Action
#      definition and in the process list of the host while the script runs. The run log shows
#      it as "********", and the script hands it to curl through a private config file rather
#      than on curl's command line.
#
#   10) FETCH_TYPE (optional, default: "incremental")
#       incremental : only entities changed since the row's checkpoint. The first run of a row
#                     (no checkpoint) exports everything.
#       full        : every entity connected to the matched entities, on every run.
#       connected   : only the matched entities and their directly connected entities.
#
#   11) SKIP_LINEAGE (optional, default: "false")
#       "true" excludes lineage (process entities and their inputs/outputs) from the export.
#
#   12) ATLAS_TUNING (optional, default: "" - no override)
#       A compact, positional way to set the knobs below, for callers - Pulse Actions in
#       particular - that can only pass positional arguments. Format: comma-separated
#       "key=value" pairs, no spaces around "=" or ",":
#         "retries=5,read_timeout=7200,retain_exports=10"
#       Recognized keys, each setting the same-named environment variable:
#         retries          -> ATLAS_RETRIES                  total attempts per request (default 3)
#         connect_timeout  -> ATLAS_CONNECT_TIMEOUT_SECONDS  (default 60)
#         read_timeout     -> ATLAS_READ_TIMEOUT_SECONDS     (default 3600)
#         insecure_tls     -> ATLAS_INSECURE_TLS             "true" passes -k to curl: https certificates are not verified; no effect on http (default true)
#         ca_cert          -> ATLAS_CA_CERT                  PEM bundle for the Atlas certificates; only used with insecure_tls=false (default: system trust store)
#         replicated_to    -> SET_REPLICATED_TO              "true" adds "replicatedTo" to the export (default false)
#         replicated_from  -> SET_REPLICATED_FROM            "true" adds "replicatedFrom" to the import (default true)
#         retain_exports   -> RETAIN_EXPORTS                 archives kept per row after success (default 5)
#         db_type          -> DB_ENTITY_TYPE                 Atlas type of a database (default hive_db)
#         table_type       -> TABLE_ENTITY_TYPE              Atlas type of a table (default hive_table)
#         dry_run          -> DRY_RUN                        "true" logs each request and performs no export/import (default false)
#         curl_bin         -> CURL_BIN                       curl executable to use, name or full path (default curl)
#         heartbeat        -> HEARTBEAT_INTERVAL_SECONDS     seconds between "still waiting" log lines during a request; 0 disables (default 60)
#         retain_logs      -> RETAIN_LOG_DAYS                run logs in LOG_DIR older than this many days are deleted at startup; 0 keeps them all (default 0)
#       The true/false keys accept true, false, yes, no, 1 or 0; anything else is a hard startup
#       error (so a typo such as dry_run=ture can never turn into a real run).
#       An unrecognized key, or an entry with no "=", is a hard startup error naming the bad
#       token. PRECEDENCE: a key present here overrides the same-named environment variable; a
#       key absent from this spec leaves that environment variable (or its default) untouched.
#
#   13) IMPORT_TRANSFORMS (optional, default: "" - none)
#       A raw Atlas import-transforms JSON object, passed to the import as its "transforms"
#       option. Entities are otherwise imported with the qualifiedName they have on the source
#       (e.g. "sales_db.orders@prod"). Example, renaming the cluster part during import:
#         '{"hive_db":{"qualifiedName":["replace:@prod:@dr"]},"hive_table":{"qualifiedName":["replace:@prod:@dr"]},"hive_column":{"qualifiedName":["replace:@prod:@dr"]},"hive_storagedesc":{"qualifiedName":["replace:@prod:@dr"]}}'
#
# REPLICATION DIRECTION, FAILOVER AND FAILBACK
# ---------------------------------------------
#   The direction is the order of the arguments: metadata always flows from SRC_* to DST_*. To
#   replicate the other way (failover / failback), invoke the script with the two clusters'
#   URLs and names swapped - exactly as with iceberg_bdr_replication.sh.
#
#   The checkpoint filename embeds the direction ("<row>__<SRC_CLUSTER_NAME>__to__<DST_CLUSTER_NAME>"),
#   so each direction has its own independent cursor. When both Atlas instances have the same
#   atlas.cluster.name (the usual case: both left at "default"), each name has that cluster's
#   Atlas host appended, so the two directions still get separate checkpoints. The first run of a row in a new direction
#   has no checkpoint for it and does a full export; later runs in that direction are incremental.
#
# AUTHENTICATION
# ---------------
#   Kerberos (default): SPNEGO with an existing ticket, located the same way
#   iceberg_bdr_replication.sh locates it (see detect_kerberos_enabled): KRB5CCNAME if set and
#   valid, else the Pulse Actions cache directory (preferring the cache whose principal matches
#   ATLAS_USER), else /tmp/krb5cc_<uid>, else the default cache. If the ATLAS_PRINCIPAL and
#   ATLAS_KEYTAB environment variables are both set the script runs kinit itself instead (and
#   again before each import, since a long export can outlive the ticket). The principal must be
#   allowed to export on the source Atlas and import on the destination Atlas (Atlas admin
#   export/import in Ranger).
#
#   Basic: selected by ATLAS_PASSWORD (argument 9), as ATLAS_USER (argument 8).
#
# ENTITY SELECTION BY SEARCH (env vars, manual runs only)
# --------------------------------------------------------
#   INCLUDE_FILTERS covers selection by database/table name. For selection by classification
#   or by an arbitrary query, set ENTITY_SELECTOR to resolve the starting entities through
#   Atlas's search APIs and export those exact entities by GUID. INCLUDE_FILTERS is then
#   ignored and the whole run is ONE row:
#
#     ENTITY_SELECTOR=basicSearch
#       POST /v2/search/basic (Solr-backed) once per ENTITY_TYPES entry, with SEARCH_QUERY as
#       free text and SEARCH_CLASSIFICATION as a classification filter (either or both).
#     ENTITY_SELECTOR=dsl
#       GET /v2/search/dsl once per ENTITY_TYPES entry, with SEARCH_QUERY as the Atlas DSL
#       query text, e.g. 'hive_table where name like "sales_%"'. DSL runs against the metadata
#       graph (JanusGraph/HBase).
#
#   Related environment variables: ENTITY_TYPES (comma-separated, default "hive_table"),
#   SEARCH_PAGE_SIZE (default 100), SEARCH_EXCLUDE_DELETED (default true, basicSearch only).
#   Both modes require jq and paginate until a page returns fewer rows than the page size.
#
# EXIT CODES
# -----------
#   0    every row succeeded, or had nothing to replicate
#   1    startup error, or at least one row failed, was locked by another run, or could not be parsed
#   130  interrupted (SIGINT, SIGTERM or SIGHUP); a request in flight is cancelled
#
# REQUIREMENTS
# -------------
#   bash 4.3+ (nameref variables), curl (with SPNEGO support for Kerberos), unzip, awk, flock
#   (util-linux). jq only for ENTITY_SELECTOR=basicSearch/dsl.
#
# EXAMPLES
# ---------
#   SRC_CLUSTER_NAME / DST_CLUSTER_NAME (arguments 4 and 5) are each Atlas's atlas.cluster.name,
#   which is "default" unless it was changed, so most examples pass "default" or leave them out.
#
#   1) One table, Kerberos. Only the 3 mandatory arguments; everything else takes its default.
#      A valid ticket must exist (e.g. kinit -kt /etc/security/keytabs/atlas.service.keytab atlas/$(hostname -f)).
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice:order_enriched" \
#          "http://repl1.adsre.com:31000" \
#          "http://atlasdemo-01.adsre.com:31000"
#
#      Run the same command again on a schedule: the first run is a bootstrap (full export),
#      every later run is incremental.
#
#   2) Same table from a Pulse Action with Kerberos, choosing the "atlas" ticket out of the
#      Pulse credential caches (argument 8).
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice:order_enriched" \
#          "http://repl1.adsre.com:31000" \
#          "http://atlasdemo-01.adsre.com:31000" \
#          "default" \
#          "default" \
#          "/var/log/atlas-replication" \
#          "/var/tmp/pulse_atlas_replication_action" \
#          "atlas"
#
#   3) Basic authentication (user admin), a whole database plus selected tables of another,
#      without lineage.
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice,sales_db:orders_.*,sales_db:customers" \
#          "http://repl1.adsre.com:31000" \
#          "http://atlasdemo-01.adsre.com:31000" \
#          "default" \
#          "default" \
#          "/var/log/atlas-replication" \
#          "/var/tmp/pulse_atlas_replication_action" \
#          "admin" \
#          "<admin-password>" \
#          "incremental" \
#          "true"
#
#   4) Atlas HA on both clusters, with tuning: more attempts, a longer read timeout, and tables
#      registered in Atlas as iceberg_table.
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice" \
#          "https://atlas1.src.example.com:21443,https://atlas2.src.example.com:21443" \
#          "https://atlas1.dst.example.com:21443,https://atlas2.dst.example.com:21443" \
#          "default" \
#          "default" \
#          "/var/log/atlas-replication" \
#          "/var/tmp/pulse_atlas_replication_action" \
#          "atlas" \
#          "" \
#          "incremental" \
#          "false" \
#          "retries=5,read_timeout=7200,table_type=iceberg_table"
#
#   5) The two Atlas instances have DIFFERENT atlas.cluster.name values ("prod" and "dr"):
#      pass them, and rename the cluster part of every qualifiedName during import
#      ("@prod" -> "@dr").
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice:order_enriched" \
#          "http://repl1.adsre.com:31000" \
#          "http://atlasdemo-01.adsre.com:31000" \
#          "prod" \
#          "dr" \
#          "/var/log/atlas-replication" \
#          "/var/tmp/pulse_atlas_replication_action" \
#          "atlas" \
#          "" \
#          "incremental" \
#          "false" \
#          "" \
#          '{"hive_db":{"qualifiedName":["replace:@prod:@dr"]},"hive_table":{"qualifiedName":["replace:@prod:@dr"]},"hive_column":{"qualifiedName":["replace:@prod:@dr"]},"hive_storagedesc":{"qualifiedName":["replace:@prod:@dr"]}}'
#
#   6) Dry run: log the export and import requests for each row, change nothing.
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice:order_enriched" \
#          "http://repl1.adsre.com:31000" \
#          "http://atlasdemo-01.adsre.com:31000" \
#          "default" \
#          "default" \
#          "/var/log/atlas-replication" \
#          "/var/tmp/pulse_atlas_replication_action" \
#          "atlas" \
#          "" \
#          "incremental" \
#          "false" \
#          "dry_run=true"
#
#   7) Failback: the same table in the other direction. Swap the two URLs (and the two cluster
#      names, when they differ).
#
#        ./atlas_bdr_replication.sh \
#          "atlas_ice:order_enriched" \
#          "http://atlasdemo-01.adsre.com:31000" \
#          "http://repl1.adsre.com:31000"
#
#   An argument left as "" takes its default; use "" to skip over an optional argument when a
#   later one is needed.
# ==============================================================================

set -o pipefail

SCRIPT_ARGV=("$@")

########################################
# Positional arguments
########################################
INCLUDE_FILTERS="${1:-}"
SRC_ATLAS_URL="${2:-}"
DST_ATLAS_URL="${3:-}"
SRC_CLUSTER_NAME="${4:-default}"
DST_CLUSTER_NAME="${5:-default}"
LOG_DIR="${6:-/var/log/atlas-replication}"
CHECKPOINT_DIR="${7:-/var/tmp/pulse_atlas_replication_action}"
ATLAS_USER="${8:-admin}"
ATLAS_PASSWORD="${9:-}"
FETCH_TYPE="${10:-incremental}"
SKIP_LINEAGE="${11:-false}"
ATLAS_TUNING_ARG="${12:-}"
IMPORT_TRANSFORMS="${13:-${IMPORT_TRANSFORMS:-}}"

########################################
# Environment-variable knobs (each also settable through ATLAS_TUNING)
########################################
ATLAS_RETRIES="${ATLAS_RETRIES:-3}"
ATLAS_CONNECT_TIMEOUT_SECONDS="${ATLAS_CONNECT_TIMEOUT_SECONDS:-60}"
ATLAS_READ_TIMEOUT_SECONDS="${ATLAS_READ_TIMEOUT_SECONDS:-3600}"
ATLAS_INSECURE_TLS="${ATLAS_INSECURE_TLS:-true}"
ATLAS_CA_CERT="${ATLAS_CA_CERT:-}"
SET_REPLICATED_TO="${SET_REPLICATED_TO:-false}"
SET_REPLICATED_FROM="${SET_REPLICATED_FROM:-true}"
RETAIN_EXPORTS="${RETAIN_EXPORTS:-5}"
DB_ENTITY_TYPE="${DB_ENTITY_TYPE:-hive_db}"
TABLE_ENTITY_TYPE="${TABLE_ENTITY_TYPE:-hive_table}"
DRY_RUN="${DRY_RUN:-false}"
# CURL_BIN: the curl executable every Atlas request is made with. Set it to a
# full path when curl is not on PATH, or to use a specific build (e.g. one
# with SPNEGO support).
CURL_BIN="${CURL_BIN:-curl}"
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-60}"
RETAIN_LOG_DAYS="${RETAIN_LOG_DAYS:-0}"

# Search-based selection (env only; see "ENTITY SELECTION BY SEARCH" above).
ENTITY_SELECTOR="${ENTITY_SELECTOR:-qualifiedName}"
ENTITY_TYPES="${ENTITY_TYPES:-hive_table}"
SEARCH_QUERY="${SEARCH_QUERY:-}"
SEARCH_CLASSIFICATION="${SEARCH_CLASSIFICATION:-}"
SEARCH_PAGE_SIZE="${SEARCH_PAGE_SIZE:-100}"
SEARCH_EXCLUDE_DELETED="${SEARCH_EXCLUDE_DELETED:-true}"

TOTAL_STEPS=5
SEP="================================================================================"
SUBSEP="--------------------------------------------------------------------------------"
RUN_START_EPOCH=$(date +%s)
RUN_TS="$(date +%Y%m%d_%H%M%S)"
RUN_LOG_FILE=""
WORK_DIR=""
LOCK_FD=""
CURL_PID=""
TEE_PID=""
HTTP_CODE=""

########################################
# Logging. Every line goes to stdout (which Pulse captures) and, once LOG_DIR
# is usable, to the run log as well.
########################################
_log_emit() {
  local _ts
  printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf '[%s] %s %s\n' "$_ts" "$1" "$2"
}
log_info()  { _log_emit '[INFO] ' "$1"; }
log_warn()  { _log_emit '[WARN] ' "$1"; }
log_error() {
  [[ -z "$UNIT_FIRST_ERROR" ]] && UNIT_FIRST_ERROR="$1"
  _log_emit '[ERROR]' "$1" >&2
}
# Plain line (banners, dividers, blank-line spacers) - timestamp-free by design.
log_line() { printf '%s\n' "$1"; }

# log_stage: uniform per-row step banner, and the boundary the stage timings are measured on.
log_stage() {
  local step="$1" description="$2"
  _stage_timing_close
  log_line ""
  log_line "$SUBSEP"
  log_info "STEP ${step}/${TOTAL_STEPS} -- ${description}"
  _STAGE_OPEN_STEP="$step"
  _STAGE_OPEN_START=$(date +%s)
}

# format_duration: seconds -> "47s", "3m 09s", "1h 04m 22s".
format_duration() {
  local total="${1:-0}" h m s
  h=$(( total / 3600 ))
  m=$(( (total % 3600) / 60 ))
  s=$(( total % 60 ))
  if (( h > 0 )); then
    printf '%dh %02dm %02ds' "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf '%dm %02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

declare -A STAGE_SECONDS=()
_STAGE_OPEN_STEP=""
_STAGE_OPEN_START=0
stage_timing_reset() { STAGE_SECONDS=(); _STAGE_OPEN_STEP=""; _STAGE_OPEN_START=0; }
_stage_timing_close() {
  [[ -z "$_STAGE_OPEN_STEP" ]] && return 0
  STAGE_SECONDS["$_STAGE_OPEN_STEP"]=$(( $(date +%s) - _STAGE_OPEN_START ))
  _STAGE_OPEN_STEP=""
}

fail_startup() {
  log_error "$1"
  exit 1
}

cleanup() {
  # A request still in flight (interrupted run) must not outlive the script.
  [[ -n "$CURL_PID" ]] && kill "$CURL_PID" 2>/dev/null
  [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] && rm -rf "$WORK_DIR"
  # The row lock is an flock on LOCK_FD and is released when the script exits.
  # Let tee drain the last lines into the run log before the script is gone.
  if [[ -n "$TEE_PID" ]]; then
    exec >&- 2>&-
    wait "$TEE_PID" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT
_on_interrupt() {
  trap '' INT TERM HUP
  log_error "Interrupted by signal $1 - the row in progress did not complete and its checkpoint was not advanced."
  exit 130
}
trap '_on_interrupt INT' INT
trap '_on_interrupt TERM' TERM
trap '_on_interrupt HUP' HUP


UNIT_FIRST_ERROR=""

########################################
# Helpers
########################################
is_true() {
  case "${1,,}" in
    true|yes|1) return 0 ;;
    *) return 1 ;;
  esac
}

# is_boolean: the spellings is_true understands, plus their false counterparts.
is_boolean() {
  case "${1,,}" in
    true|yes|1|false|no|0) return 0 ;;
    *) return 1 ;;
  esac
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

sanitize_for_filename() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

# apply_atlas_tuning_arg: parse ATLAS_TUNING ("key=value,...") into the
# environment-variable knobs. An unknown key or a token without "=" is fatal.
apply_atlas_tuning_arg() {
  local spec="$1" token key value
  local -a tokens=()
  [[ -z "$spec" ]] && return 0
  IFS=',' read -r -a tokens <<< "$spec"
  for token in "${tokens[@]}"; do
    token="${token#"${token%%[![:space:]]*}"}"
    token="${token%"${token##*[![:space:]]}"}"
    [[ -z "$token" ]] && continue
    [[ "$token" == *=* ]] || fail_startup "ATLAS_TUNING (argument 12): entry '${token}' is not in key=value form."
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      retries)         ATLAS_RETRIES="$value" ;;
      connect_timeout) ATLAS_CONNECT_TIMEOUT_SECONDS="$value" ;;
      read_timeout)    ATLAS_READ_TIMEOUT_SECONDS="$value" ;;
      insecure_tls)    ATLAS_INSECURE_TLS="$value" ;;
      ca_cert)         ATLAS_CA_CERT="$value" ;;
      replicated_to)   SET_REPLICATED_TO="$value" ;;
      replicated_from) SET_REPLICATED_FROM="$value" ;;
      retain_exports)  RETAIN_EXPORTS="$value" ;;
      db_type)         DB_ENTITY_TYPE="$value" ;;
      table_type)      TABLE_ENTITY_TYPE="$value" ;;
      dry_run)         DRY_RUN="$value" ;;
      curl_bin)        CURL_BIN="$value" ;;
      heartbeat)       HEARTBEAT_INTERVAL_SECONDS="$value" ;;
      retain_logs)     RETAIN_LOG_DAYS="$value" ;;
      *) fail_startup "ATLAS_TUNING (argument 12): unrecognized key '${key}'. Recognized keys: retries, connect_timeout, read_timeout, insecure_tls, ca_cert, replicated_to, replicated_from, retain_exports, db_type, table_type, dry_run, curl_bin, heartbeat, retain_logs." ;;
    esac
  done
}

# split_filter_rows: split INCLUDE_FILTERS on commas that are not inside
# [...], {...} or (...), one trimmed row per output line.
split_filter_rows() {
  local spec="$1" row="" ch depth=0 i
  for (( i = 0; i < ${#spec}; i++ )); do
    ch="${spec:i:1}"
    case "$ch" in
      '['|'{'|'(') depth=$((depth + 1)) ;;
      ']'|'}'|')') (( depth > 0 )) && depth=$((depth - 1)) ;;
    esac
    if [[ "$ch" == "," && $depth -eq 0 ]]; then
      printf '%s\n' "$row"
      row=""
    else
      row+="$ch"
    fi
  done
  printf '%s\n' "$row"
}

# run_log_db_slug: the database names of INCLUDE_FILTERS joined with "-",
# collapsed to "<db1>-<db2>-<db3>+Nmore" past the first three.
run_log_db_slug() {
  local -a dbs=()
  local -A seen=()
  local row db
  while IFS= read -r row; do
    row="${row#"${row%%[![:space:]]*}"}"
    db="${row%%:*}"
    db="${db%"${db##*[![:space:]]}"}"
    db="$(sanitize_for_filename "${db,,}")"
    [[ -z "$db" || -n "${seen[$db]:-}" ]] && continue
    seen["$db"]=1
    dbs+=("$db")
  done < <(split_filter_rows "$INCLUDE_FILTERS")
  local slug="" i
  for (( i = 0; i < ${#dbs[@]} && i < 3; i++ )); do
    slug+="${slug:+-}${dbs[$i]}"
  done
  (( ${#dbs[@]} > 3 )) && slug+="+$(( ${#dbs[@]} - 3 ))more"
  printf '%s' "${slug:-atlas}"
}

# Builds the curl authentication/TLS arguments into the array named by $1.
build_curl_args() {
  local -n out="$1"
  out=(-sS --connect-timeout "$ATLAS_CONNECT_TIMEOUT_SECONDS" --max-time "$ATLAS_READ_TIMEOUT_SECONDS")
  [[ -n "$ATLAS_CA_CERT" ]] && out+=(--cacert "$ATLAS_CA_CERT")
  is_true "$ATLAS_INSECURE_TLS" && out+=(-k)
  if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
    out+=(--negotiate -u :)
  else
    out+=(-K "${WORK_DIR}/atlas.curlrc")
  fi
}

# Prints the base URL of the ACTIVE Atlas instance out of a comma-separated list.
resolve_active_atlas() {
  local urls="$1" url body
  for url in ${urls//,/ }; do
    url="${url%/}"
    body="$("$CURL_BIN" "${CURL_ARGS[@]}" --max-time "$ATLAS_CONNECT_TIMEOUT_SECONDS" "${url}/api/atlas/admin/status" 2>/dev/null)"
    if grep -Eq '"Status"[[:space:]]*:[[:space:]]*"ACTIVE"' <<< "$body"; then
      echo "$url"
      return 0
    fi
    log_warn "Atlas instance not ACTIVE: ${url} (response: ${body:0:120})" >&2
  done
  return 1
}

# Runs one HTTP request, retrying on transport errors and 5xx. Response body
# goes to $1; remaining args are passed to curl. The final HTTP status is left
# in HTTP_CODE ("000" when Atlas never answered).
# It must be called directly, never inside $(...): curl runs in the background
# of the main shell so that a SIGTERM/SIGINT is acted on at once (bash defers
# traps while it waits for a command substitution) and cleanup can cancel the
# request.
# An export or import can legitimately take a long time and Atlas sends
# nothing until it is done, so while curl is waiting a heartbeat line is
# logged every HEARTBEAT_INTERVAL_SECONDS (0 disables it).
# A request that ran into the read timeout is NOT retried: Atlas is most
# likely still working on it, and a second export/import on top would only
# add load and time out again.
http_request() {
  local out_file="$1"; shift
  local attempt=1 code rc started next_beat elapsed
  local code_file="${out_file}.http_code"
  HTTP_CODE="000"
  while :; do
    # Never leave an earlier attempt's (or an earlier row's) body behind to be mistaken for this one's.
    rm -f "$out_file"
    "$CURL_BIN" -o "$out_file" -w '%{http_code}' "$@" > "$code_file" &
    CURL_PID=$!
    started=$(date +%s)
    next_beat=$HEARTBEAT_INTERVAL_SECONDS
    elapsed=0
    while kill -0 "$CURL_PID" 2>/dev/null; do
      # Poll quickly at first so short requests (status, search pages) are not padded to a full second.
      if (( elapsed < 2 )); then sleep 0.1; else sleep 1; fi
      elapsed=$(( $(date +%s) - started ))
      if (( HEARTBEAT_INTERVAL_SECONDS > 0 && elapsed >= next_beat )); then
        log_info "... still waiting for Atlas to answer ($(format_duration "$elapsed") elapsed, gives up after $(format_duration "$ATLAS_READ_TIMEOUT_SECONDS"); attempt ${attempt} of ${ATLAS_RETRIES})"
        next_beat=$(( next_beat + HEARTBEAT_INTERVAL_SECONDS ))
      fi
    done
    wait "$CURL_PID"
    rc=$?
    CURL_PID=""
    elapsed=$(( $(date +%s) - started ))
    code="$(cat "$code_file" 2>/dev/null)"
    rm -f "$code_file"
    if [[ $rc -eq 0 && "$code" =~ ^[234] ]]; then
      HTTP_CODE="$code"
      return 0
    fi
    HTTP_CODE="${code:-000}"
    log_warn "Request failed (curl rc=${rc}, http=${code:-none}), attempt ${attempt} of ${ATLAS_RETRIES}"
    if (( rc == 28 && elapsed >= ATLAS_READ_TIMEOUT_SECONDS - 1 )); then
      log_warn "The request ran into the read timeout ($(format_duration "$ATLAS_READ_TIMEOUT_SECONDS")) and is not retried: Atlas may still be working on it. Raise read_timeout (ATLAS_TUNING) if this operation legitimately takes longer."
      return 1
    fi
    if (( attempt >= ATLAS_RETRIES )); then
      return 1
    fi
    sleep $((attempt * 15))
    attempt=$((attempt + 1))
  done
}

########################################
# Kerberos detection (KRB5CCNAME). When more than one valid credential cache is
# present (the Pulse Actions scenario: multiple service tickets can coexist
# under /opt/pulse/actions/tmp, e.g. "atlas/host@REALM" for
# ATLAS_USER="atlas"), this additionally matches a candidate cache's Default
# principal against ATLAS_USER, so the Atlas calls authenticate as the
# intended service identity rather than whichever cache happens to be newest.
########################################
detect_kerberos_enabled() {
    if ! command -v klist >/dev/null 2>&1; then
        log_info "[DEBUG] klist not found; Kerberos not available"
        return 1
    fi

    # 1) If KRB5CCNAME is already set, trust but verify it
    if [[ -n "${KRB5CCNAME:-}" ]]; then
        if klist -s 2>/dev/null; then
            log_info "Kerberos detected via existing KRB5CCNAME=$KRB5CCNAME"
            return 0
        fi
        log_warn "KRB5CCNAME is set but invalid: $KRB5CCNAME"
    fi

    # 2) Acceldata Pulse Actions: scan known cache directory, preferring a
    # cache whose principal matches ATLAS_USER over just the newest valid one.
    local pulse_cache_dir="/opt/pulse/actions/tmp"
    if [[ ! -d "$pulse_cache_dir" ]] && [[ -f "/etc/default/hydra" ]]; then
        local pulse_home
        pulse_home=$(grep "^PULSE_HOME=" /etc/default/hydra 2>/dev/null | head -1 | sed -E 's/^PULSE_HOME=//' | sed -E 's/^["'\'']|["'\'']$//g' || echo "")
        if [[ -n "$pulse_home" ]]; then
            pulse_cache_dir="${pulse_home}/actions/tmp"
        fi
    fi
    if [[ -d "$pulse_cache_dir" ]]; then
        local best_cc="" fallback_cc="" cc cc_principal cc_primary
        while IFS= read -r cc; do
            [[ -f "$cc" ]] || continue
            if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                cc_principal=$(KRB5CCNAME="$cc" klist 2>/dev/null | grep "Default principal:" | awk '{print $3}')
                # Exact match on the principal's primary component (the part
                # before "/" or "@"), not a glob prefix, so ATLAS_USER="atlas"
                # matches "atlas/host@REALM" and "atlas@REALM" but not
                # "atlasadmin@REALM".
                cc_primary="${cc_principal%%@*}"
                cc_primary="${cc_primary%%/*}"
                if [[ -n "$cc_principal" && "$cc_primary" == "${ATLAS_USER}" ]]; then
                    best_cc="$cc"
                    break
                elif [[ -z "$fallback_cc" ]]; then
                    fallback_cc="$cc"
                fi
            fi
        done < <(ls -t "$pulse_cache_dir"/krb5cc_* 2>/dev/null)
        local selected_cc="${best_cc:-$fallback_cc}"
        if [[ -n "$selected_cc" ]]; then
            export KRB5CCNAME="$selected_cc"
            log_info "Kerberos detected via Pulse cache: $KRB5CCNAME"
            return 0
        fi
    fi

    # 3) Explicit fallback: /tmp/krb5cc_<uid>
    local uid cc_tmp
    uid="$(id -u 2>/dev/null || echo 0)"
    cc_tmp="/tmp/krb5cc_${uid}"
    if [[ -f "$cc_tmp" ]]; then
        if KRB5CCNAME="$cc_tmp" klist -s 2>/dev/null; then
            export KRB5CCNAME="$cc_tmp"
            log_info "Kerberos detected via default cache: $KRB5CCNAME"
            return 0
        fi
    fi

    # 4) Final fallback: whatever klist resolves by default
    if klist -s 2>/dev/null; then
        log_info "Kerberos detected via implicit default credential cache"
        return 0
    fi

    log_info "Kerberos not detected (no valid credential cache found)"
    return 1
}

# Re-run before each import: export + import together can outlive a ticket
# acquired at startup.
ensure_kerberos_ticket() {
  [[ "$KERBEROS_ENABLED" == "yes" ]] || return 0
  if [[ -n "${ATLAS_PRINCIPAL:-}" && -n "${ATLAS_KEYTAB:-}" ]]; then
    kinit -kt "$ATLAS_KEYTAB" "$ATLAS_PRINCIPAL" || { log_error "kinit failed for ${ATLAS_PRINCIPAL}"; return 1; }
  elif ! klist -s 2>/dev/null && ! detect_kerberos_enabled; then
    log_error "No valid Kerberos ticket. Run kinit, set ATLAS_PRINCIPAL and ATLAS_KEYTAB, or pass ATLAS_PASSWORD (argument 9) for basic authentication."
    return 1
  fi
}

build_items_from_guids() {
  local items="" guid sep=""
  for guid in "${ALL_GUIDS[@]}"; do
    items+="${sep}{\"guid\":\"$(json_escape "$guid")\"}"
    sep=","
  done
  printf '%s' "$items"
}

# Resolves starting entities through Atlas's search APIs, one search per
# ENTITY_TYPES entry, fully paginated. Populates ALL_GUIDS.
search_collect_guids() {
  local mode="$1"
  local -A seen=()
  ALL_GUIDS=()
  local IFS_OLD="$IFS" type
  IFS=','
  for type in $ENTITY_TYPES; do
    IFS="$IFS_OLD"
    type="${type//[[:space:]]/}"
    [[ -z "$type" ]] && continue

    local offset=0 page=0
    while :; do
      page=$((page + 1))
      if (( page > 100000 )); then
        log_error "Search pagination for type '${type}' (mode=${mode}) did not terminate after ${page} pages (offset=${offset})"
        return 1
      fi

      local resp_file="${WORK_DIR}/search_${mode}_${type}_${offset}.json" http_code body
      if [[ "$mode" == "basicSearch" ]]; then
        local exclude_deleted="false"
        is_true "$SEARCH_EXCLUDE_DELETED" && exclude_deleted="true"
        body="$(jq -n --arg typeName "$type" --arg query "$SEARCH_QUERY" --arg classification "$SEARCH_CLASSIFICATION" \
          --argjson limit "$SEARCH_PAGE_SIZE" --argjson offset "$offset" --argjson excludeDeleted "$exclude_deleted" \
          '{typeName: $typeName, limit: $limit, offset: $offset, excludeDeletedEntities: $excludeDeleted,
            includeSubTypes: true, includeSubClassifications: true}
           + (if $query != "" then {query: $query} else {} end)
           + (if $classification != "" then {classification: $classification} else {} end)')"
        printf '%s' "$body" > "${resp_file}.request"
        http_request "$resp_file" "${CURL_ARGS[@]}" -X POST \
          -H 'Content-Type: application/json' --data-binary "@${resp_file}.request" \
          "${SRC_URL}/api/atlas/v2/search/basic"
        http_code="$HTTP_CODE"
        rm -f "${resp_file}.request"
      else
        local -a qargs=(-G --data-urlencode "typeName=${type}" --data-urlencode "limit=${SEARCH_PAGE_SIZE}" --data-urlencode "offset=${offset}")
        [[ -n "$SEARCH_QUERY" ]] && qargs+=(--data-urlencode "query=${SEARCH_QUERY}")
        [[ -n "$SEARCH_CLASSIFICATION" ]] && qargs+=(--data-urlencode "classification=${SEARCH_CLASSIFICATION}")
        http_request "$resp_file" "${CURL_ARGS[@]}" "${qargs[@]}" "${SRC_URL}/api/atlas/v2/search/dsl"
        http_code="$HTTP_CODE"
      fi

      if [[ "$http_code" != "200" ]]; then
        log_error "Search request failed (mode=${mode}, type=${type}, offset=${offset}) with HTTP ${http_code}: $(head -c 1000 "$resp_file" 2>/dev/null)"
        return 1
      fi

      local count
      if ! count="$(jq '.entities | length' "$resp_file" 2>/dev/null)"; then
        log_error "Search response for type '${type}' is not valid JSON: $(head -c 500 "$resp_file" 2>/dev/null)"
        return 1
      fi
      [[ "$count" =~ ^[0-9]+$ ]] || count=0

      if (( count > 0 )); then
        local guid
        while IFS= read -r guid; do
          [[ -z "$guid" || -n "${seen[$guid]:-}" ]] && continue
          seen["$guid"]=1
          ALL_GUIDS+=("$guid")
        done < <(jq -r '.entities[].guid' "$resp_file")
      fi
      rm -f "$resp_file"

      (( count < SEARCH_PAGE_SIZE )) && break
      offset=$((offset + SEARCH_PAGE_SIZE))
    done
  done
  IFS="$IFS_OLD"
}

build_export_request() {
  local items="$1" match_type="$2" change_marker="$3"
  local options="\"fetchType\":\"${FETCH_TYPE}\""
  [[ -n "$match_type" ]] && options+=",\"matchType\":\"${match_type}\""
  is_true "$SKIP_LINEAGE" && options+=",\"skipLineage\":true"
  [[ "$FETCH_TYPE" == "incremental" ]] && options+=",\"changeMarker\":${change_marker}"
  is_true "$SET_REPLICATED_TO" && options+=",\"replicatedTo\":\"$(json_escape "$DST_CLUSTER_NAME")\""
  printf '{"itemsToExport":[%s],"options":{%s}}' "$items" "$options"
}

build_import_request() {
  local options="" sep=""
  if is_true "$SET_REPLICATED_FROM"; then
    options+="\"replicatedFrom\":\"$(json_escape "$SRC_CLUSTER_NAME")\""
    sep=","
  fi
  if [[ -n "$IMPORT_TRANSFORMS" ]]; then
    # Atlas expects the transforms object as a JSON-encoded string value.
    options+="${sep}\"transforms\":\"$(json_escape "$IMPORT_TRANSFORMS")\""
  fi
  printf '{"options":{%s}}' "$options"
}

# json_top_level: reads a JSON object on stdin and prints it with the content
# of every nested object and array removed, leaving only its own (top-level)
# keys and scalar values. Atlas's export result embeds the export REQUEST, and
# its import result embeds the whole export RESULT, and those carry fields of
# the same name (the request's changeMarker is the OLD marker, the embedded
# export's operationStatus is not the import's) - so a field must be read at
# the top level, never by a plain text search.
json_top_level() {
  awk '{ s = s $0 "\n" }
    END {
      n = length(s); d = 0; ins = 0; esc = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (ins) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") ins = 0
        } else if (c == "\"") ins = 1
        else if (c == "{" || c == "[") { d++; if (d > 1) continue }
        else if (c == "}" || c == "]") { d--; if (d >= 1) continue }
        if (d <= 1) printf "%s", c
      }
    }'
}

# json_top_level_field <field>: the scalar value of a top-level field of the JSON object on stdin.
json_top_level_field() {
  json_top_level | tr -d ' \n\r\t' | grep -o "\"${1}\":\"\\?[A-Za-z0-9_]*" | head -n 1 | sed 's/.*://; s/"//g'
}

export_info_field() {
  local zip="$1" field="$2"
  unzip -p "$zip" '*atlas-export-info.json' 2>/dev/null | json_top_level_field "$field"
}

prune_old_exports() {
  local prefix="$1"
  [[ "$RETAIN_EXPORTS" =~ ^[0-9]+$ ]] || return 0
  ls -1t "${EXPORT_DIR}/${prefix}"__*.zip 2>/dev/null | tail -n +$((RETAIN_EXPORTS + 1)) | while read -r old; do
    rm -f "$old"
  done
}

########################################
# Startup validation
########################################
if [[ -z "$INCLUDE_FILTERS" || -z "$SRC_ATLAS_URL" || -z "$DST_ATLAS_URL" ]]; then
  log_error "Missing mandatory argument(s). The first 3 arguments are required."
  log_line "Usage: $0 \"<INCLUDE_FILTERS>\" \"<SRC_ATLAS_URL>\" \"<DST_ATLAS_URL>\" [SRC_CLUSTER_NAME] [DST_CLUSTER_NAME] [LOG_DIR] [CHECKPOINT_DIR] [ATLAS_USER] [ATLAS_PASSWORD] [FETCH_TYPE] [SKIP_LINEAGE] [ATLAS_TUNING] [IMPORT_TRANSFORMS]"
  exit 1
fi

apply_atlas_tuning_arg "$ATLAS_TUNING_ARG"

for _tool in "$CURL_BIN" unzip awk flock; do
  command -v "$_tool" >/dev/null 2>&1 || fail_startup "Required command not found: ${_tool}"
done

FETCH_TYPE="${FETCH_TYPE,,}"
case "$FETCH_TYPE" in
  full|connected|incremental) ;;
  *) fail_startup "FETCH_TYPE (argument 10): invalid value '${FETCH_TYPE}' (expected incremental, full or connected)." ;;
esac

case "${SKIP_LINEAGE,,}" in
  true|false) SKIP_LINEAGE="${SKIP_LINEAGE,,}" ;;
  *) fail_startup "SKIP_LINEAGE (argument 11): invalid value '${SKIP_LINEAGE}' (expected true or false)." ;;
esac

[[ "$ATLAS_RETRIES" =~ ^[1-9][0-9]*$ ]] || fail_startup "retries / ATLAS_RETRIES must be a positive integer (got '${ATLAS_RETRIES}')."
[[ "$ATLAS_CONNECT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail_startup "connect_timeout / ATLAS_CONNECT_TIMEOUT_SECONDS must be a positive integer (got '${ATLAS_CONNECT_TIMEOUT_SECONDS}')."
[[ "$ATLAS_READ_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || fail_startup "read_timeout / ATLAS_READ_TIMEOUT_SECONDS must be a positive integer (got '${ATLAS_READ_TIMEOUT_SECONDS}')."
[[ "$HEARTBEAT_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || fail_startup "heartbeat / HEARTBEAT_INTERVAL_SECONDS must be a non-negative integer (got '${HEARTBEAT_INTERVAL_SECONDS}')."
[[ "$RETAIN_EXPORTS" =~ ^[0-9]+$ ]] || fail_startup "retain_exports / RETAIN_EXPORTS must be a non-negative integer (got '${RETAIN_EXPORTS}')."
[[ "$RETAIN_LOG_DAYS" =~ ^[0-9]+$ ]] || fail_startup "retain_logs / RETAIN_LOG_DAYS must be a non-negative integer (got '${RETAIN_LOG_DAYS}')."
is_boolean "$ATLAS_INSECURE_TLS" || fail_startup "insecure_tls / ATLAS_INSECURE_TLS must be true or false (got '${ATLAS_INSECURE_TLS}')."
is_boolean "$SET_REPLICATED_TO" || fail_startup "replicated_to / SET_REPLICATED_TO must be true or false (got '${SET_REPLICATED_TO}')."
is_boolean "$SET_REPLICATED_FROM" || fail_startup "replicated_from / SET_REPLICATED_FROM must be true or false (got '${SET_REPLICATED_FROM}')."
is_boolean "$DRY_RUN" || fail_startup "dry_run / DRY_RUN must be true or false (got '${DRY_RUN}')."
is_boolean "$SEARCH_EXCLUDE_DELETED" || fail_startup "SEARCH_EXCLUDE_DELETED must be true or false (got '${SEARCH_EXCLUDE_DELETED}')."

# validate_atlas_urls <argument label> <comma-separated URL list>
validate_atlas_urls() {
  local what="$1" url
  local -a urls=()
  IFS=',' read -r -a urls <<< "$2"
  for url in "${urls[@]}"; do
    [[ "$url" =~ ^https?://[^[:space:]/]+(/[^[:space:]]*)?$ ]] || fail_startup "${what}: '${url}' is not an http(s) URL (expected e.g. http://atlas1.example.com:21000)."
    url="${url%/}"
    [[ "$url" == */api/atlas ]] && fail_startup "${what}: pass the Atlas base URL without the /api/atlas suffix (got '${url}')."
  done
  return 0
}
validate_atlas_urls "SRC_ATLAS_URL (argument 2)" "$SRC_ATLAS_URL"
validate_atlas_urls "DST_ATLAS_URL (argument 3)" "$DST_ATLAS_URL"

# A malformed IMPORT_TRANSFORMS would otherwise only surface at the import, after the export.
if [[ -n "$IMPORT_TRANSFORMS" ]]; then
  if command -v jq >/dev/null 2>&1; then
    jq -e 'type == "object"' <<< "$IMPORT_TRANSFORMS" >/dev/null 2>&1 || fail_startup "IMPORT_TRANSFORMS (argument 13) is not a valid JSON object."
  elif [[ ! "$IMPORT_TRANSFORMS" =~ ^[[:space:]]*\{.*\}[[:space:]]*$ ]]; then
    fail_startup "IMPORT_TRANSFORMS (argument 13) is not a JSON object (it must start with '{' and end with '}')."
  fi
fi

[[ "$SRC_CLUSTER_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_startup "SRC_CLUSTER_NAME (argument 4) may only contain letters, digits, '_', '.' and '-'."
[[ "$DST_CLUSTER_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || fail_startup "DST_CLUSTER_NAME (argument 5) may only contain letters, digits, '_', '.' and '-'."
[[ "$DB_ENTITY_TYPE" =~ ^[A-Za-z0-9_]+$ ]] || fail_startup "db_type / DB_ENTITY_TYPE is not a valid Atlas type name (got '${DB_ENTITY_TYPE}')."
[[ "$TABLE_ENTITY_TYPE" =~ ^[A-Za-z0-9_]+$ ]] || fail_startup "table_type / TABLE_ENTITY_TYPE is not a valid Atlas type name (got '${TABLE_ENTITY_TYPE}')."
[[ -n "$ATLAS_CA_CERT" && ! -r "$ATLAS_CA_CERT" ]] && fail_startup "ca_cert / ATLAS_CA_CERT is not a readable file: ${ATLAS_CA_CERT}"

case "$ENTITY_SELECTOR" in
  qualifiedName) ;;
  basicSearch|dsl)
    command -v jq >/dev/null 2>&1 || fail_startup "ENTITY_SELECTOR=${ENTITY_SELECTOR} requires jq."
    [[ "$ENTITY_SELECTOR" == "dsl" && -z "$SEARCH_QUERY" ]] && fail_startup "ENTITY_SELECTOR=dsl requires SEARCH_QUERY."
    [[ "$SEARCH_PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || fail_startup "SEARCH_PAGE_SIZE must be a positive integer."
    [[ "$ENTITY_TYPES" =~ ^[A-Za-z0-9_,[:space:]]+$ ]] || fail_startup "Invalid ENTITY_TYPES '${ENTITY_TYPES}'."
    ;;
  *) fail_startup "Invalid ENTITY_SELECTOR '${ENTITY_SELECTOR}' (expected qualifiedName, basicSearch or dsl)." ;;
esac

mkdir -p "$LOG_DIR" 2>/dev/null || fail_startup "LOG_DIR (argument 6) cannot be created: ${LOG_DIR}"
[[ -w "$LOG_DIR" ]] || fail_startup "LOG_DIR (argument 6) is not writable by $(id -un): ${LOG_DIR}"
EXPORT_DIR="${LOG_DIR}/exports"
LOCK_DIR="${CHECKPOINT_DIR}/locks"
# Permissions are tightened only on directories this run creates: CHECKPOINT_DIR
# may be a pre-existing, shared directory whose mode is not this script's to change.
for _dir in "$EXPORT_DIR" "$CHECKPOINT_DIR"; do
  [[ -d "$_dir" ]] && continue
  mkdir -p "$_dir" 2>/dev/null || fail_startup "Cannot create ${_dir}."
  chmod 750 "$_dir" 2>/dev/null
done
mkdir -p "$LOCK_DIR" 2>/dev/null || fail_startup "Cannot create ${LOCK_DIR}."
[[ -w "$EXPORT_DIR" ]] || fail_startup "${EXPORT_DIR} is not writable by $(id -un)."
[[ -w "$CHECKPOINT_DIR" ]] || fail_startup "CHECKPOINT_DIR (argument 7) is not writable by $(id -un): ${CHECKPOINT_DIR}"
[[ -w "$LOCK_DIR" ]] || fail_startup "${LOCK_DIR} is not writable by $(id -un)."

RUN_LOG_FILE="${LOG_DIR}/atlas_bdr_run_$(run_log_db_slug)_${RUN_TS}_$$.log"
# tee ignores the interrupt signals so it survives a Ctrl-C of the whole process
# group and still records the last lines; it ends when cleanup closes its input.
exec > >(trap '' INT TERM HUP; exec tee -a "$RUN_LOG_FILE") 2>&1
TEE_PID=$!

if (( RETAIN_LOG_DAYS > 0 )); then
  find "$LOG_DIR" -maxdepth 1 -type f -name 'atlas_bdr_run_*.log' -mtime +"$RETAIN_LOG_DAYS" -delete 2>/dev/null
fi

# A work directory orphaned by a killed run can hold a credentials file; sweep
# those. A work directory is named ".work.<host>.<pid>.<random>" and is removed
# only when its run is known to be gone (same host, pid no longer alive) - a
# concurrent run for other rows can legitimately be hours old. Directories of
# other hosts (shared CHECKPOINT_DIR) or of an older script version are removed
# once they are two days old.
RUN_HOST="$(sanitize_for_filename "$(hostname 2>/dev/null || echo localhost)")"
for _dir in "$CHECKPOINT_DIR"/.work.*; do
  [[ -d "$_dir" ]] || continue
  _name="${_dir##*/.work.}"
  if [[ "$_name" =~ ^(.+)\.([0-9]+)\.[A-Za-z0-9]+$ && "${BASH_REMATCH[1]}" == "$RUN_HOST" ]]; then
    [[ -d "/proc/${BASH_REMATCH[2]}" ]] || rm -rf "$_dir" 2>/dev/null
  elif [[ -n "$(find "$_dir" -maxdepth 0 -mmin +2880 2>/dev/null)" ]]; then
    rm -rf "$_dir" 2>/dev/null
  fi
done
WORK_DIR="$(mktemp -d "${CHECKPOINT_DIR}/.work.${RUN_HOST}.$$.XXXXXX")" || fail_startup "Cannot create a work directory under ${CHECKPOINT_DIR}."
chmod 700 "$WORK_DIR"

########################################
# Authentication
########################################
if [[ -n "$ATLAS_PASSWORD" ]]; then
  KERBEROS_ENABLED="no"
  # Credentials reach curl through a config file so they never appear in the process list.
  ( umask 077; printf 'user = "%s:%s"\n' "$(json_escape "$ATLAS_USER")" "$(json_escape "$ATLAS_PASSWORD")" > "${WORK_DIR}/atlas.curlrc" )
else
  KERBEROS_ENABLED="yes"
  command -v klist >/dev/null 2>&1 || fail_startup "klist not found and no ATLAS_PASSWORD (argument 9) given: neither Kerberos nor basic authentication is available."
  if [[ -n "${ATLAS_PRINCIPAL:-}" && -n "${ATLAS_KEYTAB:-}" ]]; then
    ensure_kerberos_ticket || exit 1
  elif ! detect_kerberos_enabled; then
    fail_startup "No valid Kerberos ticket. Run kinit, set ATLAS_PRINCIPAL and ATLAS_KEYTAB, or pass ATLAS_PASSWORD (argument 9) for basic authentication."
  fi
fi

# KERBEROS_PRINCIPAL: the principal of the ticket every Atlas call of this run
# authenticates with (empty with basic authentication). Shown in the startup
# banner, since under Kerberos ATLAS_USER does not decide the identity -- the
# ticket does.
KERBEROS_PRINCIPAL=""
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
    KERBEROS_PRINCIPAL=$(klist 2>/dev/null | awk '/Default principal:/ {print $3; exit}') || KERBEROS_PRINCIPAL=""
fi

CURL_ARGS=()
build_curl_args CURL_ARGS

# first_atlas_host: the alphabetically first host of a comma-separated Atlas
# URL list, so the result does not depend on the order the URLs were passed in.
first_atlas_host() {
  local url host
  for url in ${1//,/ }; do
    host="${url#*://}"
    host="${host%%[:/]*}"
    printf '%s\n' "$host"
  done | sort | head -n 1
}

# SRC_DIRECTION_NAME / DST_DIRECTION_NAME: the two cluster labels the log and
# every checkpoint filename use. Normally the atlas.cluster.name values; when
# both Atlas instances carry the SAME value (the usual case: both left at
# "default"), the names alone cannot tell the two directions apart, so each
# gets its Atlas host appended.
SRC_DIRECTION_NAME="$SRC_CLUSTER_NAME"
DST_DIRECTION_NAME="$DST_CLUSTER_NAME"
if [[ "$SRC_CLUSTER_NAME" == "$DST_CLUSTER_NAME" ]]; then
  SRC_DIRECTION_NAME="${SRC_CLUSTER_NAME}-$(sanitize_for_filename "$(first_atlas_host "$SRC_ATLAS_URL")")"
  DST_DIRECTION_NAME="${DST_CLUSTER_NAME}-$(sanitize_for_filename "$(first_atlas_host "$DST_ATLAS_URL")")"
fi

########################################
# Run banner
########################################
log_line "$SEP"
log_line " Atlas Metadata Replication"
log_line "$SEP"
log_line "Started   : $(date)"
log_line "Run as    : $(id -un)@$(hostname -f 2>/dev/null || hostname)"
log_line "Direction : ${SRC_DIRECTION_NAME} -> ${DST_DIRECTION_NAME}"
log_line "Kerberos  : ${KERBEROS_ENABLED^^}"
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
  log_line "Principal : ${KERBEROS_PRINCIPAL:-<could not be read from klist>}"
else
  log_line "Atlas user: ${ATLAS_USER} (basic authentication)"
fi
log_line "Log File  : ${RUN_LOG_FILE}"
log_line ""

log_positional_arg() {
  local idx="$1" name="$2" value="$3"
  local raw="${SCRIPT_ARGV[$((idx - 1))]:-}" suffix=""
  [[ -z "$raw" ]] && suffix="  (default)"
  log_line "$(printf '  %2s  %-20s : %s%s' "$idx" "$name" "${value:-<unset>}" "$suffix")"
}

log_line "Positional arguments (${#SCRIPT_ARGV[@]} passed, effective values shown):"
log_positional_arg 1  "INCLUDE_FILTERS"     "$INCLUDE_FILTERS"
log_positional_arg 2  "SRC_ATLAS_URL"       "$SRC_ATLAS_URL"
log_positional_arg 3  "DST_ATLAS_URL"       "$DST_ATLAS_URL"
log_positional_arg 4  "SRC_CLUSTER_NAME"    "$SRC_CLUSTER_NAME"
log_positional_arg 5  "DST_CLUSTER_NAME"    "$DST_CLUSTER_NAME"
log_positional_arg 6  "LOG_DIR"             "$LOG_DIR"
log_positional_arg 7  "CHECKPOINT_DIR"      "$CHECKPOINT_DIR"
log_positional_arg 8  "ATLAS_USER"          "$ATLAS_USER"
log_positional_arg 9  "ATLAS_PASSWORD"      "${ATLAS_PASSWORD:+********}"
log_positional_arg 10 "FETCH_TYPE"          "$FETCH_TYPE"
log_positional_arg 11 "SKIP_LINEAGE"        "$SKIP_LINEAGE"
log_positional_arg 12 "ATLAS_TUNING"        "$ATLAS_TUNING_ARG"
log_positional_arg 13 "IMPORT_TRANSFORMS"   "$IMPORT_TRANSFORMS"
log_line ""
log_line "Effective settings:"
log_line "$(printf '      %-20s : %s' 'ENTITY_SELECTOR' "$ENTITY_SELECTOR")"
log_line "$(printf '      %-20s : %s / %s' 'Entity types' "$DB_ENTITY_TYPE" "$TABLE_ENTITY_TYPE")"
log_line "$(printf '      %-20s : %s attempt(s), connect %ss, read %ss' 'Requests' "$ATLAS_RETRIES" "$ATLAS_CONNECT_TIMEOUT_SECONDS" "$ATLAS_READ_TIMEOUT_SECONDS")"
log_line "$(printf '      %-20s : replicatedTo=%s, replicatedFrom=%s' 'Replication marks' "$SET_REPLICATED_TO" "$SET_REPLICATED_FROM")"
log_line "$(printf '      %-20s : %s' 'ATLAS_INSECURE_TLS' "$ATLAS_INSECURE_TLS")"
log_line "$(printf '      %-20s : %s' 'RETAIN_EXPORTS' "$RETAIN_EXPORTS")"
log_line "$(printf '      %-20s : %s' 'RETAIN_LOG_DAYS' "$RETAIN_LOG_DAYS")"
log_line "$(printf '      %-20s : %s' 'DRY_RUN' "$DRY_RUN")"
log_line "$(printf '      %-20s : %s' 'CURL_BIN' "$(command -v "$CURL_BIN")")"
log_line ""

if is_true "$DRY_RUN"; then
  log_warn "DRY-RUN MODE (dry_run=true): each row's export and import requests are logged, NOTHING is exported or imported and no checkpoint is changed."
  log_line ""
fi

########################################
# Resolve the active Atlas instance on each cluster
########################################
SRC_URL="$(resolve_active_atlas "$SRC_ATLAS_URL")" || fail_startup "No ACTIVE Atlas instance found on source ${SRC_CLUSTER_NAME} (${SRC_ATLAS_URL})."
DST_URL="$(resolve_active_atlas "$DST_ATLAS_URL")" || fail_startup "No ACTIVE Atlas instance found on destination ${DST_CLUSTER_NAME} (${DST_ATLAS_URL})."
[[ "$SRC_URL" == "$DST_URL" ]] && fail_startup "Source and destination resolve to the same Atlas instance (${SRC_URL}); refusing to replicate an Atlas onto itself."
log_info "Source Atlas      : ${SRC_URL} (ACTIVE)"
log_info "Destination Atlas : ${DST_URL} (ACTIVE)"

# check_atlas_login: /admin/status answers without authentication, so an
# ACTIVE reply says nothing about the credentials. Make one authenticated
# call per cluster up front, so a rejected login is reported here and not
# halfway through a row (after the export, at the import).
check_atlas_login() {
  local side="$1" url="$2" code
  code="$("$CURL_BIN" "${CURL_ARGS[@]}" --max-time "$ATLAS_CONNECT_TIMEOUT_SECONDS" -o /dev/null -w '%{http_code}' "${url}/api/atlas/v2/types/typedefs/headers" 2>/dev/null)"
  case "$code" in
    200) log_info "${side} Atlas login OK (${url})" ;;
    401|403)
      if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        fail_startup "${side} Atlas rejected the Kerberos ticket of ${KERBEROS_PRINCIPAL:-<unknown principal>} with HTTP ${code} (${url}). The ticket's realm must be trusted by that cluster and the principal must be allowed in its Atlas."
      else
        fail_startup "${side} Atlas rejected user '${ATLAS_USER}' with HTTP ${code} (${url}). ATLAS_USER / ATLAS_PASSWORD (arguments 8 and 9) are used for BOTH clusters and must be valid on each."
      fi ;;
    *) log_warn "${side} Atlas login check returned HTTP ${code:-none} (${url}); continuing." ;;
  esac
}
check_atlas_login "Source" "$SRC_URL"
check_atlas_login "Destination" "$DST_URL"

########################################
# Resolve INCLUDE_FILTERS into rows. Each row is one export + import cycle
# with its own checkpoint and lock.
#   UNIT_LABEL[i]  the row as shown in the log and summary
#   UNIT_ITEMS[i]  the row's "itemsToExport" JSON (empty for a search row)
#   UNIT_MATCH[i]  the row's export matchType (empty for a search row)
########################################
UNIT_LABEL=(); UNIT_ITEMS=(); UNIT_MATCH=()
# UNIT_ROOT_TYPE[i] / UNIT_ROOT_QN[i]: the single root entity of an "equals" row
# (empty for a regex or search row), used to check that the destination really
# holds the row before a checkpoint is trusted or advanced.
UNIT_ROOT_TYPE=(); UNIT_ROOT_QN=()
FILTER_ERRORS=()

if [[ "$ENTITY_SELECTOR" != "qualifiedName" ]]; then
  log_warn "ENTITY_SELECTOR=${ENTITY_SELECTOR}: INCLUDE_FILTERS is ignored; the run is one row selected by search."
  UNIT_LABEL+=("search:${ENTITY_SELECTOR}:$(printf '%s|%s|%s' "$ENTITY_TYPES" "$SEARCH_QUERY" "$SEARCH_CLASSIFICATION" | cksum | cut -d' ' -f1)")
  UNIT_ITEMS+=("")
  UNIT_MATCH+=("")
  UNIT_ROOT_TYPE+=(""); UNIT_ROOT_QN+=("")
else
  declare -A _seen_rows=()
  while IFS= read -r _row; do
    _row="${_row#"${_row%%[![:space:]]*}"}"
    _row="${_row%"${_row##*[![:space:]]}"}"
    [[ -z "$_row" ]] && continue
    if [[ "$_row" == *:* ]]; then
      _db="${_row%%:*}"; _tbl="${_row#*:}"
    else
      _db="$_row"; _tbl=".*"
    fi
    _db="${_db,,}"
    if [[ ! "$_db" =~ ^[a-z0-9_]+$ ]]; then
      FILTER_ERRORS+=("${_row}  (invalid database name '${_db}')")
      continue
    fi
    if [[ -z "$_tbl" || "$_tbl" == ".*" ]]; then
      _label="${_db}"
      _items="{\"typeName\":\"${DB_ENTITY_TYPE}\",\"uniqueAttributes\":{\"qualifiedName\":\"$(json_escape "${_db}@${SRC_CLUSTER_NAME}")\"}}"
      _match="equals"; _root_type="$DB_ENTITY_TYPE"; _root_qn="${_db}@${SRC_CLUSTER_NAME}"
    elif [[ "$_tbl" =~ ^[A-Za-z0-9_]+$ ]]; then
      _tbl="${_tbl,,}"
      _label="${_db}:${_tbl}"
      _items="{\"typeName\":\"${TABLE_ENTITY_TYPE}\",\"uniqueAttributes\":{\"qualifiedName\":\"$(json_escape "${_db}.${_tbl}@${SRC_CLUSTER_NAME}")\"}}"
      _match="equals"; _root_type="$TABLE_ENTITY_TYPE"; _root_qn="${_db}.${_tbl}@${SRC_CLUSTER_NAME}"
    else
      _label="${_db}:${_tbl}"
      _items="{\"typeName\":\"${TABLE_ENTITY_TYPE}\",\"uniqueAttributes\":{\"qualifiedName\":\"$(json_escape "${_db}\\.(${_tbl})@${SRC_CLUSTER_NAME}")\"}}"
      _match="matches"; _root_type=""; _root_qn=""
    fi
    [[ -n "${_seen_rows[$_label]:-}" ]] && continue
    _seen_rows["$_label"]=1
    UNIT_LABEL+=("$_label"); UNIT_ITEMS+=("$_items"); UNIT_MATCH+=("$_match")
    UNIT_ROOT_TYPE+=("$_root_type"); UNIT_ROOT_QN+=("$_root_qn")
  done < <(split_filter_rows "$INCLUDE_FILTERS")
fi

log_info "Rows resolved     : ${#UNIT_LABEL[@]}"
for _l in "${UNIT_LABEL[@]}"; do
  log_line "                      - ${_l}"
done
for _f in "${FILTER_ERRORS[@]}"; do
  log_error "INCLUDE_FILTERS row skipped: ${_f}"
done
UNIT_FIRST_ERROR=""

########################################
# Per-row replication
########################################

# unit_tag: filesystem-safe, direction-scoped name for a row's checkpoint,
# lock and archives. The checksum keeps two rows whose sanitized text would
# coincide (e.g. regexes differing only in punctuation) apart.
unit_tag() {
  local label="$1"
  printf '%s_%s__%s__to__%s' "$(sanitize_for_filename "$label" | cut -c1-80)" \
    "$(printf '%s' "$label" | cksum | cut -d' ' -f1)" "$SRC_DIRECTION_NAME" "$DST_DIRECTION_NAME"
}

# unit_fingerprint: checksum of everything that decides WHAT a row exports and
# how it lands on the destination. It is stored with the checkpoint; when it
# differs on a later run, the entities already replicated were produced under
# other settings and an incremental export would never revisit them, so the
# row is bootstrapped again.
unit_fingerprint() {
  local idx="$1" scope="full"
  [[ "$FETCH_TYPE" == "connected" ]] && scope="connected"
  printf '%s|%s|%s|%s|%s' "${UNIT_ITEMS[$idx]}" "${UNIT_MATCH[$idx]}" "$scope" "$SKIP_LINEAGE" "$IMPORT_TRANSFORMS" | cksum | cut -d' ' -f1
}

# dst_root_state <type> <qualifiedName>: is the row's root entity on the
# destination Atlas? 0 = yes, 1 = no (HTTP 404), 2 = could not be determined.
dst_root_state() {
  local resp="${WORK_DIR}/dst_root.json"
  http_request "$resp" "${CURL_ARGS[@]}" -G \
    --data-urlencode "attr:qualifiedName=$2" --data-urlencode "minExtInfo=true" --data-urlencode "ignoreRelationships=true" \
    "${DST_URL}/api/atlas/v2/entity/uniqueAttribute/type/$1"
  rm -f "$resp"
  case "$HTTP_CODE" in
    200) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

print_unit_timing_summary() {
  _stage_timing_close
  local step
  log_line ""
  log_info "Stage timings:"
  for step in 1 2 3 4 5; do
    [[ -n "${STAGE_SECONDS[$step]:-}" ]] || continue
    log_line "$(printf '                      STEP %s/%s  %12s' "$step" "$TOTAL_STEPS" "$(format_duration "${STAGE_SECONDS[$step]}")")"
  done
}

# replicate_one_unit <index>
# Returns 0 = replicated / up to date, 1 = failed, 2 = skipped (matched nothing), 3 = locked.
replicate_one_unit() {
  local idx="$1"
  local label="${UNIT_LABEL[$idx]}"
  local tag lock_file holder rc
  tag="$(unit_tag "$label")"
  lock_file="${LOCK_DIR}/${tag}.flock"

  # The lock is an flock held on LOCK_FD for the duration of the row. The kernel
  # releases it when this process ends, however it ends, so there is never a
  # stale lock to detect or break. The lock file itself is left in place.
  if ! exec {LOCK_FD}>>"$lock_file"; then
    LOCK_FD=""
    log_error "Cannot open the lock file ${lock_file}."
    return 1
  fi
  if ! flock -n "$LOCK_FD"; then
    holder="$(head -n 1 "$lock_file" 2>/dev/null)"
    exec {LOCK_FD}>&-
    LOCK_FD=""
    log_error "Another run is replicating this row in this direction (lock: ${lock_file}, held by ${holder:-an unknown process})."
    return 3
  fi
  printf 'pid %s on %s since %s\n' "$$" "$(hostname 2>/dev/null)" "$(date '+%Y-%m-%d %H:%M:%S')" > "$lock_file"

  _replicate_one_unit_locked "$idx" "$tag"
  rc=$?
  # Also after a failure: the failed archive is the newest and is kept, but a
  # row failing run after run must not pile up one archive per run.
  prune_old_exports "$tag"
  print_unit_timing_summary

  exec {LOCK_FD}>&-
  LOCK_FD=""
  return $rc
}

_replicate_one_unit_locked() {
  local idx="$1" tag="$2"
  local label="${UNIT_LABEL[$idx]}" items="${UNIT_ITEMS[$idx]}" match_type="${UNIT_MATCH[$idx]}"
  local checkpoint_file="${CHECKPOINT_DIR}/${tag}.marker"
  local export_zip="${EXPORT_DIR}/${tag}__${RUN_TS}.zip"
  local root_type="${UNIT_ROOT_TYPE[$idx]}" root_qn="${UNIT_ROOT_QN[$idx]}"
  local last_marker=0 mode="BOOTSTRAP" had_checkpoint=false fingerprint stored_fingerprint
  fingerprint="$(unit_fingerprint "$idx")"
  [[ -s "$checkpoint_file" ]] && had_checkpoint=true

  # ---- STEP 1 ---------------------------------------------------------------
  log_stage 1 "Read checkpoint"
  log_info "Checkpoint file : ${checkpoint_file}"

  if [[ "$FETCH_TYPE" != "incremental" ]]; then
    mode="${FETCH_TYPE^^}"
    log_info "FETCH_TYPE=${FETCH_TYPE}: the checkpoint is not used to limit the export; it is still updated after a successful import."
  elif [[ -s "$checkpoint_file" ]]; then
    last_marker="$(head -n 1 "$checkpoint_file" | tr -d '[:space:]')"
    if [[ ! "$last_marker" =~ ^[0-9]+$ ]]; then
      log_error "Checkpoint ${checkpoint_file} does not contain a numeric change marker (found '${last_marker:0:60}'). Remove the file to bootstrap this row again."
      return 1
    fi
    mode="INCREMENTAL"
    log_info "Checkpoint found: change marker ${last_marker} -> INCREMENTAL mode"
    # A checkpoint only says "everything up to this marker was sent". It is
    # trusted only while that is still true of THIS destination under THESE settings.
    stored_fingerprint="$(sed -n 's/^fingerprint=//p' "$checkpoint_file" | head -n 1)"
    if [[ -n "$stored_fingerprint" && "$stored_fingerprint" != "$fingerprint" ]]; then
      log_warn "The row's export settings (SKIP_LINEAGE, FETCH_TYPE scope, entity type or IMPORT_TRANSFORMS) changed since the checkpoint was written -> BOOTSTRAP mode (full export), so entities replicated under the old settings are sent again."
      last_marker=0; mode="BOOTSTRAP"
    elif [[ -n "$root_qn" && -z "$IMPORT_TRANSFORMS" ]]; then
      dst_root_state "$root_type" "$root_qn"
      if [[ $? -eq 1 ]]; then
        log_warn "A checkpoint exists but ${root_type} '${root_qn}' is NOT on the destination Atlas (rebuilt, purged or a different destination?) -> BOOTSTRAP mode (full export)."
        last_marker=0; mode="BOOTSTRAP"
      fi
    fi
  else
    log_info "No checkpoint for this row in direction ${SRC_DIRECTION_NAME} -> ${DST_DIRECTION_NAME} -> BOOTSTRAP mode (full export)"
  fi

  # ---- STEP 2 ---------------------------------------------------------------
  log_stage 2 "Export from source Atlas (${mode})"
  if [[ "$ENTITY_SELECTOR" != "qualifiedName" ]]; then
    log_info "Resolving entities via ${ENTITY_SELECTOR} search on ${SRC_URL}"
    search_collect_guids "$ENTITY_SELECTOR" || return 1
    log_info "${#ALL_GUIDS[@]} entities matched by search"
    if (( ${#ALL_GUIDS[@]} == 0 )); then
      log_warn "The search matched no entity on the source - nothing to replicate for this row."
      return 2
    fi
    items="$(build_items_from_guids)"
  fi

  local export_request import_request
  export_request="$(build_export_request "$items" "$match_type" "$last_marker")"
  import_request="$(build_import_request)"
  if (( ${#export_request} > 4000 )); then
    log_info "Export request  : ${export_request:0:4000}... (${#export_request} characters, truncated in the log)"
  else
    log_info "Export request  : ${export_request}"
  fi

  if is_true "$DRY_RUN"; then
    log_info "Import request  : ${import_request}"
    log_info "DRY_RUN: no export or import performed for this row."
    return 0
  fi

  local http_code export_start export_seconds
  log_info "Waiting for the source Atlas to build the export (no output until it answers; read timeout $(format_duration "$ATLAS_READ_TIMEOUT_SECONDS"))."
  export_start=$(date +%s)
  # The request goes through a file: a search row can list thousands of GUIDs,
  # more than a single command-line argument may hold.
  local export_request_file="${WORK_DIR}/export_request.json"
  printf '%s' "$export_request" > "$export_request_file" || { log_error "Cannot write ${export_request_file}."; return 1; }
  http_request "$export_zip" "${CURL_ARGS[@]}" -X POST \
    -H 'Content-Type: application/json' -H 'Cache-Control: no-cache' \
    --data-binary "@${export_request_file}" "${SRC_URL}/api/atlas/admin/export"
  http_code="$HTTP_CODE"
  export_seconds=$(( $(date +%s) - export_start ))
  if [[ "$http_code" != "200" ]]; then
    log_error "Export failed with HTTP ${http_code}: $(head -c 1000 "$export_zip" 2>/dev/null)"
    rm -f "$export_zip"
    return 1
  fi
  log_info "Export finished in $(format_duration "$export_seconds")"

  # ---- STEP 3 ---------------------------------------------------------------
  log_stage 3 "Validate the export archive"
  if ! unzip -tq "$export_zip" >/dev/null 2>&1; then
    log_error "Export response is not a valid zip archive: $(head -c 1000 "$export_zip" 2>/dev/null)"
    rm -f "$export_zip"
    return 1
  fi

  local export_status new_marker entity_count zip_bytes
  export_status="$(export_info_field "$export_zip" operationStatus)"
  new_marker="$(export_info_field "$export_zip" changeMarker)"
  entity_count="$(unzip -Z1 "$export_zip" 2>/dev/null | grep -vcE '(^|/)atlas-[^/]*$')"
  zip_bytes="$(wc -c < "$export_zip" | tr -d ' ')"
  log_info "Archive         : ${export_zip}"
  log_info "Archive size    : ${zip_bytes} bytes"
  log_info "Entities        : ${entity_count}"
  log_info "Export status   : ${export_status:-unknown}"
  log_info "Change marker   : ${new_marker:-none}"

  if [[ -n "$export_status" && "$export_status" != "SUCCESS" ]] && (( entity_count == 0 )); then
    # Atlas answers an export whose items match no entity with HTTP 200 and an
    # entity-less archive marked operationStatus=FAIL.
    if [[ "$had_checkpoint" == "true" ]]; then
      # This row WAS replicated before and its root is gone from the source now
      # (dropped or renamed). Nothing can be exported for it any more, so the
      # destination keeps the old entities - that must not pass silently.
      log_error "This row was replicated before (checkpoint ${checkpoint_file}) but no longer matches any entity on the source: it was dropped or renamed there. The destination still holds it. Remove the row from INCLUDE_FILTERS (and its checkpoint), and delete the entities on the destination if they should go."
      rm -f "$export_zip"
      return 1
    fi
    log_stage 4 "Import into destination Atlas -- SKIPPED"
    log_warn "No entity on the source matched this row (export operationStatus=${export_status}, 0 entities). Check the database/table name, SRC_CLUSTER_NAME (argument 4, the source's atlas.cluster.name; currently '${SRC_CLUSTER_NAME}') and table_type."
    rm -f "$export_zip"
    return 2
  fi
  if [[ -n "$export_status" && "$export_status" != "SUCCESS" ]]; then
    log_error "Export finished with operationStatus=${export_status}; archive kept at ${export_zip}."
    return 1
  fi

  # ---- STEP 4 ---------------------------------------------------------------
  local import_seconds=0
  if (( entity_count == 0 )) && [[ "$mode" != "INCREMENTAL" ]]; then
    log_stage 4 "Import into destination Atlas -- SKIPPED"
    log_warn "No entity on the source matched this row. Check the database/table name, SRC_CLUSTER_NAME (argument 4, the source's atlas.cluster.name; currently '${SRC_CLUSTER_NAME}') and table_type."
    rm -f "$export_zip"
    return 2
  elif (( entity_count == 0 )); then
    # An archive without entities is not imported: Atlas answers such an import
    # with operationStatus=FAIL and applies nothing. The archive still lists the
    # type definitions of the row (Atlas always includes them), but a type
    # change reaches the destination with the next export that carries an entity.
    log_stage 4 "Import into destination Atlas -- SKIPPED (nothing changed since the checkpoint)"
    rm -f "$export_zip"
  else
    log_stage 4 "Import into destination Atlas"
    ensure_kerberos_ticket || return 1
    local import_request_file="${WORK_DIR}/import_request.json" import_response_file="${WORK_DIR}/import_response.json"
    printf '%s' "$import_request" > "$import_request_file" || { log_error "Cannot write ${import_request_file}."; return 1; }
    log_info "Import request  : ${import_request}"

    local import_start
    import_start=$(date +%s)
    http_request "$import_response_file" "${CURL_ARGS[@]}" -g -X POST \
      -H 'Cache-Control: no-cache' \
      -F "request=@${import_request_file};type=application/json" \
      -F "data=@${export_zip};type=application/octet-stream" \
      "${DST_URL}/api/atlas/admin/import"
    http_code="$HTTP_CODE"
    import_seconds=$(( $(date +%s) - import_start ))

    if [[ "$http_code" != "200" ]]; then
      log_error "Import failed with HTTP ${http_code}: $(head -c 2000 "$import_response_file" 2>/dev/null)"
      log_error "Checkpoint NOT advanced; archive kept at ${export_zip}."
      return 1
    fi
    # Top-level field only: the response also embeds the export result, whose own
    # operationStatus=SUCCESS must not be taken for the import's.
    local import_status
    import_status="$(json_top_level_field operationStatus < "$import_response_file")"
    if [[ "$import_status" != "SUCCESS" ]]; then
      log_error "Import did not report operationStatus=SUCCESS (got '${import_status:-none}'): $(head -c 2000 "$import_response_file")"
      log_error "Checkpoint NOT advanced; archive kept at ${export_zip}."
      return 1
    fi
    log_info "Import response : $(head -c 2000 "$import_response_file")"
    log_info "Import finished in $(format_duration "$import_seconds")"

    # The checkpoint is the point of no return: once it advances, an incremental
    # export never sends these entities again. Atlas's import response carries no
    # usable entity count, so confirm on the destination itself that the row landed.
    if [[ -n "$root_qn" && -z "$IMPORT_TRANSFORMS" ]]; then
      dst_root_state "$root_type" "$root_qn"
      case $? in
        0) log_info "Verified on destination: ${root_type} '${root_qn}' is present." ;;
        1) log_error "Import reported SUCCESS but ${root_type} '${root_qn}' is not on the destination Atlas."
           log_error "Checkpoint NOT advanced; archive kept at ${export_zip}."
           return 1 ;;
        *) log_warn "Could not verify ${root_type} '${root_qn}' on the destination (HTTP ${HTTP_CODE}); relying on the import status." ;;
      esac
    fi
  fi

  # ---- STEP 5 ---------------------------------------------------------------
  log_stage 5 "Write checkpoint and summarize"
  if [[ "$new_marker" =~ ^[0-9]+$ ]] && (( new_marker > 0 )); then
    if (( new_marker < last_marker )); then
      log_warn "The source returned change marker ${new_marker}, OLDER than the checkpoint's ${last_marker} (source Atlas clock set back, restored from a backup, or a different source?). The checkpoint follows the source."
    fi
    # Line 1 is the change marker and the only line Atlas needs; the rest records
    # what the marker is valid for (fingerprint) and when/how it was written.
    if ! { printf '%s\nfingerprint=%s\nupdated=%s\nmode=%s\nentities=%s\nsource=%s\ndestination=%s\n' \
             "$new_marker" "$fingerprint" "$(date '+%Y-%m-%d %H:%M:%S %z')" "$mode" "$entity_count" "$SRC_URL" "$DST_URL" > "${checkpoint_file}.tmp" \
           && mv -f "${checkpoint_file}.tmp" "$checkpoint_file"; }; then
      log_error "Import succeeded but the checkpoint could not be written to ${checkpoint_file}. The next run will re-export from change marker ${last_marker}."
      return 1
    fi
    log_info "Checkpoint written: ${new_marker}"
  else
    log_warn "The export archive carried no change marker; checkpoint left at ${last_marker}."
    new_marker="$last_marker"
  fi

  log_line ""
  log_info "Row               : ${label}"
  log_info "Direction         : ${SRC_DIRECTION_NAME} -> ${DST_DIRECTION_NAME}"
  log_info "Mode              : ${mode}"
  log_info "Entities Exported : ${entity_count}"
  log_info "Archive Size      : ${zip_bytes} bytes"
  log_info "Change Marker     : ${last_marker} -> ${new_marker}"
  log_info "Export Time       : $(format_duration "$export_seconds")"
  log_info "Import Time       : $(format_duration "$import_seconds")"
  return 0
}

SUCCEEDED_UNITS=(); SKIPPED_UNITS=(); LOCKED_UNITS=(); FAILED_UNITS=()
declare -A UNIT_DURATIONS=() UNIT_FAILURE_REASON=()

for _i in "${!UNIT_LABEL[@]}"; do
  _label="${UNIT_LABEL[$_i]}"
  log_line ""
  log_line "$SEP"
  log_line " Row $(( _i + 1 )) of ${#UNIT_LABEL[@]} : ${_label}"
  log_line "$SEP"
  UNIT_FIRST_ERROR=""
  stage_timing_reset
  _unit_start=$(date +%s)
  replicate_one_unit "$_i"
  _rc=$?
  UNIT_DURATIONS["$_label"]=$(( $(date +%s) - _unit_start ))
  case $_rc in
    0) SUCCEEDED_UNITS+=("$_label")
       log_info "RESULT: SUCCESS -- ${_label} ($(format_duration "${UNIT_DURATIONS[$_label]}"))" ;;
    2) SKIPPED_UNITS+=("$_label")
       UNIT_FAILURE_REASON["$_label"]="no entity on the source matched this row"
       log_warn "RESULT: SKIPPED -- ${_label}" ;;
    3) LOCKED_UNITS+=("$_label")
       UNIT_FAILURE_REASON["$_label"]="$UNIT_FIRST_ERROR"
       log_warn "RESULT: LOCKED -- ${_label}" ;;
    *) FAILED_UNITS+=("$_label")
       UNIT_FAILURE_REASON["$_label"]="$UNIT_FIRST_ERROR"
       log_error "RESULT: FAILED -- ${_label} ($(format_duration "${UNIT_DURATIONS[$_label]}"))" ;;
  esac
done

########################################
# Run summary
########################################
log_line ""
log_line "$SEP"
if [[ ${#FAILED_UNITS[@]} -gt 0 || ${#LOCKED_UNITS[@]} -gt 0 || ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  log_line " Atlas Metadata Replication Run Completed -- RESULT: FAILED"
else
  log_line " Atlas Metadata Replication Run Completed -- RESULT: SUCCESS"
fi
log_line "$SEP"
log_line ""
log_info "Source         : ${SRC_CLUSTER_NAME} (${SRC_URL})"
log_info "Destination    : ${DST_CLUSTER_NAME} (${DST_URL})"
log_info "Kerberos       : ${KERBEROS_ENABLED^^}"
log_line ""

print_unit_bucket() {
  local level="$1" label="$2"
  shift 2
  local -a units=()
  local u show_reasons=false
  for u in "$@"; do
    [[ -n "$u" ]] && units+=("$u")
  done
  [[ "$level" != "info" ]] && show_reasons=true
  # The level applies only to a non-empty bucket, so a clean run logs no [ERROR]/[WARN] line.
  [[ ${#units[@]} -eq 0 ]] && level="info"
  case "$level" in
    error) log_error "${label} : ${#units[@]}" ;;
    warn)  log_warn  "${label} : ${#units[@]}" ;;
    *)     log_info  "${label} : ${#units[@]}" ;;
  esac
  for u in "${units[@]}"; do
    log_line "$(printf '                    - %-56.56s %12s' "$u" "$(format_duration "${UNIT_DURATIONS[$u]:-0}")")"
    if [[ "$show_reasons" == "true" && -n "${UNIT_FAILURE_REASON[$u]:-}" ]]; then
      log_line "$(printf '                        reason: %.220s' "${UNIT_FAILURE_REASON[$u]}")"
    fi
  done
}

log_info "Rows resolved    : ${#UNIT_LABEL[@]}"
print_unit_bucket info  "Succeeded       " "${SUCCEEDED_UNITS[@]}"
print_unit_bucket warn  "Skipped         " "${SKIPPED_UNITS[@]}"
print_unit_bucket warn  "Locked (busy)   " "${LOCKED_UNITS[@]}"
print_unit_bucket error "Failed          " "${FAILED_UNITS[@]}"
if [[ ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  log_error "Filter errors    : ${#FILTER_ERRORS[@]}  (these rows were NOT replicated)"
  for _f in "${FILTER_ERRORS[@]}"; do
    log_line "                    - ${_f}"
  done
fi
log_line ""
log_info "Completed : $(date)"
log_info "Elapsed   : $(format_duration "$(( $(date +%s) - RUN_START_EPOCH ))")"
log_info "Log File  : $RUN_LOG_FILE"
log_line ""
log_line "$SEP"
log_line ""

if [[ ${#FAILED_UNITS[@]} -gt 0 || ${#LOCKED_UNITS[@]} -gt 0 || ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
