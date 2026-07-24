#!/bin/bash
# -----------------------------------------------------------------------------
# Hive Cluster Replication Script
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
#
# Description:
#   This script automates Hive metastore and data replication between clusters
#   using Hive REPL DUMP/LOAD commands (REPL LOAD performs its own internal DistCp).
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
#     "<YARN_QUEUE>" \
#     "<REPL_BASE_DIR>" \
#     "<LOG_DIR>" \
#     "<HDFS_USER>" \
#     "<HIVE_USER>" \
#     "<HIVE_LDAP_ENABLED>" \
#     "<USE_SCHEDULED_QUERIES>" \
#     "<SCHEDULE_EXPR>" \
#     "<LOAD_OFFSET>" \
#     "<REPL_EXTERNAL_BASE_DIR_APPEND_DB>" \
#     "<REPL_EXTERNAL_BASE_DIR_ROOT>"
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
#   6) YARN_QUEUE           - YARN Capacity Scheduler queue for REPL LOAD's internal
#                              data-copy job (default: testqueue). See notes below.
#   7) REPL_BASE_DIR        - Base replication directory (default: /user/hive/repl/)
#   8) LOG_DIR              - Log directory path (default: /var/log/hive-replication)
#   9) HDFS_USER            - User to run `hdfs dfs` / `hdfs dfsadmin` commands as when
#                              Kerberos is NOT detected (default: hdfs). See notes below.
#   10) HIVE_USER            - Beeline username when Kerberos is NOT detected (default: hdfs).
#                              See notes below.
#   11) HIVE_LDAP_ENABLED    - "true" or "false" (default: false). See notes below.
#   12) USE_SCHEDULED_QUERIES - "true" or "false" (default: false). See notes below.
#   13) SCHEDULE_EXPR        - Optional Hive SCHEDULED QUERY expression for incremental runs
#                              Example: "CRON '0 */10 * * * ? *'" or "EVERY 30 MINUTES"
#   14) LOAD_OFFSET          - Time offset for LOAD schedule (default: 00:03:00)
#                              Applies only to EVERY schedules, not CRON
#                              Example: "00:05:00" for 5 minute delay
#   15) REPL_EXTERNAL_BASE_DIR_APPEND_DB - "true" or "false" (default: true). "true" appends
#                              ${HIVE_DB_NAME} to REPL_EXTERNAL_BASE_DIR_ROOT (option 1, the
#                              tested/working shape). "false" uses REPL_EXTERNAL_BASE_DIR_ROOT
#                              bare, with no per-DB suffix (option 2) - comparison-testing
#                              knob only; see compute_repl_external_base_dir().
#   16) REPL_EXTERNAL_BASE_DIR_ROOT - Base directory (per LOAD-target nameservice) under which
#                              replicated EXTERNAL table data is relocated on the destination
#                              (default: /user/hive/external/). Actual per-DB value is
#                              hdfs://<load-target-nameservice><this>/<db> (or just
#                              hdfs://<load-target-nameservice><this> when arg 15 is
#                              "false"). This is a RELOCATION root, not a mirror of the
#                              source's real external warehouse path - see
#                              compute_repl_external_base_dir().
#
#   NOTE: FAILOVER_MODE is NOT a positional argument - it is deliberately excluded from
#   routine positional invocation (failover is an operational decision, not a routine
#   invocation parameter) and can only be set via environment variable: FAILOVER_MODE=true.
#   Args 6 and 9-12 (YARN_QUEUE, HDFS_USER, HIVE_USER, HIVE_LDAP_ENABLED,
#   USE_SCHEDULED_QUERIES) can also be set via the identically-named environment variable
#   (e.g. HDFS_USER=hdfs ./hive_bdr.sh ...) for backward compatibility. If both are set, the
#   positional argument takes precedence.
#
# Environment variable overrides (YARN_QUEUE, HDFS_USER, HIVE_USER, HIVE_LDAP_ENABLED, and
# USE_SCHEDULED_QUERIES can also be set via positional args above; the positional argument
# takes precedence if both are set. FAILOVER_MODE is environment-only - see note above):
#   HDFS_USER               - (also positional arg 9) User to run `hdfs dfs` / `hdfs dfsadmin` commands as (mkdir,
#                              chmod on the external table base dir; allowSnapshot when
#                              HIVE_REPL_SNAPSHOT_COPY=true) when Kerberos is NOT detected
#                              (default: hdfs). MUST be an HDFS superuser (or a member of
#                              the HDFS supergroup) - allowSnapshot and chmod/mkdir on
#                              other users' (e.g. hive's) directories require superuser
#                              privileges; a non-superuser will fail these operations with
#                              AccessControlException. The script auto-detects Kerberos via
#                              klist; if no valid ticket cache is found, these commands are
#                              run via `sudo -u $HDFS_USER` instead. When Kerberos is
#                              detected, commands run as the current user to preserve
#                              tickets and HDFS_USER is not used. Note: this script no
#                              longer runs `hadoop distcp` itself - REPL LOAD performs its
#                              own internal data copy (see notes on
#                              hive.repl.run.data.copy.tasks.on.target below).
#                              Example: HDFS_USER=hdfs ./hive_bdr.sh ...
#   HIVE_USER               - (also positional arg 10) Beeline username (default: hdfs). Only
#                              used when Kerberos is NOT detected; passed as `-n $HIVE_USER`
#                              on every beeline call to avoid HiveServer2 authenticating the
#                              connection as "anonymous". When Kerberos is detected, beeline
#                              authenticates via the active ticket and HIVE_USER is not used.
#   HIVE_LDAP_ENABLED       - (also positional arg 11) "true" or "false" (default: false).
#                              Controls what is passed as
#                              the beeline password (`-p`) alongside HIVE_USER, when Kerberos
#                              is NOT detected:
#                                - "false": HS2 is using pass-through/NONE auth (password not
#                                  actually validated). Password = HIVE_USER value.
#                                - "true": HS2 is backed by real LDAP auth. Password = the
#                                  actual credential in HIVE_PASSWORD. Script exits with an
#                                  error if HIVE_LDAP_ENABLED=true but HIVE_PASSWORD is unset.
#   HIVE_PASSWORD           - Real LDAP password for HIVE_USER. Required only when
#                              HIVE_LDAP_ENABLED=true and Kerberos is NOT detected.
#   USE_SCHEDULED_QUERIES   - (also positional arg 12) "true" or "false" (default: false).
#                              Controls how incremental replication is driven after the first
#                              (bootstrap) run:
#                                - "false" (default): Hive Scheduled Queries are NOT created
#                                  (step 7 is skipped regardless of SCHEDULE_EXPR). Instead,
#                                  once bootstrap has completed, every subsequent script
#                                  invocation runs a real incremental REPL DUMP -> REPL LOAD
#                                  cycle directly (REPL LOAD copies data itself - no separate
#                                  DistCp is needed or run). Requires an external scheduler
#                                  (Pulse Actions, cron) to re-invoke this script on its own
#                                  interval per DB - incremental replication only happens
#                                  when this script runs again.
#                                - "true": step 7 creates Hive Scheduled Queries (requires
#                                  SCHEDULE_EXPR) that run DUMP on source / LOAD on
#                                  destination on Hive's own cron. Once bootstrap has
#                                  completed, subsequent script invocations detect the DB
#                                  already exists and simply skip - Hive itself is driving
#                                  incremental replication, not this script.
#                              Hive tracks replication state (repl.last.id) server-side, so
#                              each incremental DUMP only contains events since the last one
#                              regardless of which mode drives it.
#                              Example: USE_SCHEDULED_QUERIES=true ./hive_bdr.sh ...
#   INCREMENTAL_LOCK_DIR    - Directory for per-DB lock files used to prevent overlapping
#                              incremental cycles when USE_SCHEDULED_QUERIES=false (default:
#                              /var/tmp/hive-bdr-incremental-locks).
#   HIVE_REPL_SNAPSHOT_COPY - "true" or "false" (default: true; Hive's own default for
#                              hive.repl.externaltable.snapshotdiff.copy is false). When
#                              "true" (default here), REPL DUMP/LOAD WITH clauses add
#                              hive.repl.externaltable.snapshotdiff.copy=true (+
#                              external.warehouse.single.copy.task and
#                              externaltable.snapshot.overwrite.target=true), so REPL LOAD's
#                              internal external-table data copy uses HDFS snapshot-diff
#                              based DistCp (only changed blocks since the last snapshot)
#                              instead of a full listing-based copy - the scaling mechanism
#                              for large (e.g. 1TB+) external table bootstraps/incrementals.
#                              The script automatically runs `hdfs dfsadmin -allowSnapshot`
#                              (idempotent, per-DB lock file, checked/skipped on repeat runs)
#                              on the SOURCE external warehouse dir before every DUMP when
#                              this is "true" - no manual snapshot setup needed there. The
#                              DESTINATION side is intentionally NOT pre-enabled: Hive's
#                              DirCopyTask nests the source table's full path under
#                              hive.repl.replica.external.table.base.dir and enables
#                              snapshot on that nested path itself at copy time - HDFS does
#                              not allow a directory to be snapshottable if an ancestor
#                              already is, so pre-enabling the base dir would block Hive's
#                              own allowSnapshot call and fail the LOAD (confirmed via
#                              testing). When "false", none of the above properties are set
#                              and no snapshot setup runs; external table copy uses Hive's
#                              normal listing-based copy.
#                              NOTE: forced to "false" whenever FAILOVER_MODE=true, regardless
#                              of what is requested here - snapshot-diff copy is untested
#                              across a failover cycle (see HIVE_REPL_SNAPSHOT_COPY notes
#                              further below).
#
#                              Snapshot lifecycle / no cleanup needed (verified via testing
#                              and against HiveConf.java 
#                              Hive creates and manages exactly TWO rotating named snapshots
#                              per DB under this feature - "<db>replOld" and "<db>replNew" -
#                              NOT one new snapshot per replication cycle. Each cycle: a fresh
#                              "replNew" snapshot is taken, diffed against the previous
#                              "replOld" to find only what changed, that diff is copied, then
#                              "replOld" is rotated to become "replNew"'s state for next time.
#                              Confirmed empirically: after 4 script runs (4 incremental
#                              inserts) against the same table, `hdfs dfs -ls -R .../.snapshot`
#                              still showed exactly these 2 snapshot names, never
#                              replOld2/replOld3/etc. - the snapshot COUNT stays flat forever;
#                              only the underlying data files grow (normal table growth, not a
#                              snapshot leak). HiveConf.java has no retention-count/TTL/cleanup
#                              property for this feature (checked - none exists) because none
#                              is needed: this is architecturally different from
#                              hadoop_dr_replication.sh's SNAP_RETAIN/cleanup_old_snapshots
#                              (which intentionally keeps N historical dated snapshots for
#                              point-in-time rollback); this feature only ever needs "last
#                              cycle's state" vs "this cycle's state" to compute a diff, so
#                              there is no history to prune and no cleanup step to add here.
#                              Example: HIVE_REPL_SNAPSHOT_COPY=false ./hive_bdr.sh ...
#   SNAP_LOCK_DIR           - Directory for per-DB, per-dump-source external-table
#                              snapshot-capability lock files (one lock file per
#                              "<db>__<dump-source-nameservice>" pair, since failover
#                              flips which nameservice is the real dump source and each
#                              side needs its own independent check/enable - a lock
#                              written for one direction is never reused for the other),
#                              used only when HIVE_REPL_SNAPSHOT_COPY=true (default:
#                              /var/tmp/hive-bdr-snapshot-setup-locks).
#   HIVE_EXTERNAL_WAREHOUSE_DIR - Base dir Hive uses for EXTERNAL tables with no explicit
#                              LOCATION on the SOURCE cluster (i.e. its
#                              hive.metastore.warehouse.external.dir). Default:
#                              /warehouse/tablespace/external/hive (Hive 3+ default; verified
#                              on a real cluster: tables land at <this>/<db>.db/<table>).
#                              Older Hive/HDP clusters may use /user/hive/external instead -
#                              override if your source cluster's
#                              hive.metastore.warehouse.external.dir differs. Used ONLY to
#                              build REPL_EXTERNAL_SRC_DIR, the actual source-side path
#                              checked/allowSnapshot'd by enable_external_table_snapshots()
#                              (when HIVE_REPL_SNAPSHOT_COPY=true). Does NOT affect
#                              REPL_EXTERNAL_BASE_DIR (hive.repl.replica.external.table.base.dir)
#                              on the destination, which is an unrelated relocation root that
#                              Hive prefixes the source table's path onto - it must stay a
#                              distinct path (/user/hive/external/<db>), not mirror this value,
#                              or REPL LOAD fails with a doubled/nested destination path.
#                              Only covers tables using the default external location on
#                              source, not tables with a custom LOCATION.
#   YARN_QUEUE              - (also positional arg 6) YARN Capacity Scheduler queue for
#                              REPL LOAD's internal data-copy YARN job (default: "testqueue"
#                              in this script). Set via
#                              SET mapreduce.job.queuename / SET tez.queue.name issued in
#                              the same beeline session immediately before REPL LOAD.
#                              Only applies to LOAD (immediate executions: bootstrap,
#                              incremental cycle, failover) - DUMP does not launch a YARN
#                              copy job so setting a queue there has no effect. Does NOT
#                              apply to Hive Scheduled Query LOADs (USE_SCHEDULED_QUERIES=
#                              true) - see notes in create_scheduled_queries().
#                              Example: YARN_QUEUE=testqueue ./hive_bdr.sh ...
#   HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS - "true" or "false" (default: false, matches
#                              Hive's own default for hive.repl.include.materialized.views).
#                              When "true", adds 'hive.repl.include.materialized.views'=
#                              'true' to every REPL DUMP/LOAD WITH clause so materialized
#                              views are replicated along with regular tables. Left false by
#                              default: MVs are derived/rebuildable data, not source-of-truth
#                              - replication copies the MV's last-materialized snapshot as-is
#                              without triggering a REBUILD on the destination, so a
#                              replicated MV can silently drift out of sync with its base
#                              tables. Also adds data volume/time to every cycle. Enable only
#                              after confirming you need replicated MV data and have
#                              validated the staleness/rebuild implications on destination.
#                              Example: HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS=true ./hive_bdr.sh ...
#   FAILOVER_MODE           - Enable failover (direction reversal) for Hive BDR replication.
#                              Default: false. NOT a positional argument (env-var only,
#                              deliberately excluded from routine positional invocation).
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
# All examples below pass all 16 positional arguments explicitly (order matters - see
# "Positional arguments" above). Trailing args can be omitted to fall back to their
# defaults/environment overrides, but are spelled out here for clarity.
#
# Example (Bootstrap + Scheduled Incremental):
#   ./hive_bdr.sh \
#     "migration01" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "testqueue" \
#     "/user/hive/repl/" \
#     "/var/log/hive-replication" \
#     "hdfs" \
#     "hdfs" \
#     "false" \
#     "true" \
#     "EVERY 5 MINUTES" \
#     "00:03:00" \
#     "true" \
#     "/user/hive/external/"
#   NOTE: arg 12 (USE_SCHEDULED_QUERIES) must be "true" for Hive Scheduled Queries to
#         actually be created from SCHEDULE_EXPR - "false" skips scheduled-query creation
#         entirely and instead runs a direct incremental DUMP/LOAD cycle on every
#         subsequent invocation (see USE_SCHEDULED_QUERIES notes above).
#
# Example (Bootstrap + externally-scheduled incremental, e.g. cron/Pulse Actions):
#   USE_SCHEDULED_QUERIES=false (the default) - no Hive Scheduled Queries are created;
#   just re-invoke this same command on your own interval to drive incrementals. Args
#   13-14 (SCHEDULE_EXPR/LOAD_OFFSET) are irrelevant in this mode and left empty:
#   ./hive_bdr.sh \
#     "migration01" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "testqueue" \
#     "/user/hive/repl/" \
#     "/var/log/hive-replication" \
#     "hdfs" \
#     "hdfs" \
#     "false" \
#     "false" \
#     "" \
#     "00:03:00" \
#     "true" \
#     "/user/hive/external/"
#
# Example (Multi-database replication):
#   ./hive_bdr.sh \
#     "sales|analytics|hr.'orders'" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "testqueue" \
#     "/user/hive/repl/" \
#     "/var/log/hive-replication" \
#     "hdfs" \
#     "hdfs" \
#     "false" \
#     "false" \
#     "" \
#     "00:03:00" \
#     "true" \
#     "/user/hive/external/"
#
# Example (Table-level replication - specific tables only):
#   ./hive_bdr.sh \
#     "sales.'(t1|orders|course)'" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "testqueue" \
#     "/user/hive/repl/" \
#     "/var/log/hive-replication" \
#     "hdfs" \
#     "hdfs" \
#     "false" \
#     "false" \
#     "" \
#     "00:03:00" \
#     "true" \
#     "/user/hive/external/"
#
# Example (Incremental only - DB already exists):
#   Same as above - script will detect existing DB and skip bootstrap
#
# Example (Failover - reverse replication after ODP-Aurora became primary):
#   NOTE: Ensure at least one incremental REPL DUMP has completed on ODP-Aurora
#         after bootstrap, before enabling FAILOVER_MODE. FAILOVER_MODE is environment-only
#         (not a positional argument) - set it before the positional args.
#   FAILOVER_MODE=true ./hive_bdr.sh \
#     "migration01" \
#     "ODP-Aquaman" \
#     "ODP-Aurora" \
#     "jdbc:hive2://host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "jdbc:hive2://host3:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#     "testqueue" \
#     "/user/hive/repl/" \
#     "/var/log/hive-replication" \
#     "hdfs" \
#     "hdfs" \
#     "false" \
#     "true" \
#     "EVERY 5 MINUTES" \
#     "00:03:00" \
#     "true" \
#     "/user/hive/external/"
#   NOTE: arg 12 is "true" here too - failover's Step 4 (create_reversed_scheduled_queries)
#         only creates the reversed DUMP/LOAD scheduled queries when USE_SCHEDULED_QUERIES=
#         true; with "false" that step is a no-op and the reversed direction must instead be
#         driven by re-invoking this script (with SRC/DST swapped) on your own schedule.
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
YARN_QUEUE="${6:-${YARN_QUEUE:-default}}"
REPL_BASE_DIR="${7:-/user/hive/repl/}"
LOG_DIR="${8:-/var/log/hive-replication}"
HDFS_USER="${9:-${HDFS_USER:-hdfs}}"
HIVE_USER="${10:-${HIVE_USER:-hdfs}}"
HIVE_LDAP_ENABLED="${11:-${HIVE_LDAP_ENABLED:-false}}"
USE_SCHEDULED_QUERIES="${12:-${USE_SCHEDULED_QUERIES:-false}}"
SCHEDULE_EXPR="${13:-}"
LOAD_OFFSET="${14:-00:03:00}"
# "false" (default): use REPL_EXTERNAL_BASE_DIR_ROOT bare, with no per-DB suffix. Combined
# with REPL_EXTERNAL_BASE_DIR_ROOT="/" (its default, below), this makes the destination
# external-table path Hive constructs (REPL_EXTERNAL_BASE_DIR + the source table's own
# nested path) equal to the source path itself, modulo nameservice/host. Verified against a
# real bootstrap: with APPEND_DB=true the destination path came out prefixed with
# /<db_name> instead of matching source. "true": append ${HIVE_DB_NAME} to
# REPL_EXTERNAL_BASE_DIR_ROOT, giving each DB its own isolated relocation root - use this if
# REPL_EXTERNAL_BASE_DIR_ROOT is NOT "/" (e.g. /user/hive/external/) and per-DB isolation
# under that shared root is wanted.
REPL_EXTERNAL_BASE_DIR_APPEND_DB="${15:-${REPL_EXTERNAL_BASE_DIR_APPEND_DB:-false}}"
REPL_EXTERNAL_BASE_DIR_ROOT="${16:-/}"
FAILOVER_MODE="${FAILOVER_MODE:-false}"

# Strip surrounding double-quotes that some callers (e.g. Pulse Actions) inject literally
HIVE_DB="${HIVE_DB#\"}"
HIVE_DB="${HIVE_DB%\"}"

# Failover mode: reverse replication direction. Not a positional argument (deliberately
# excluded - failover is an operational decision, not a routine invocation parameter).
# Override via environment: FAILOVER_MODE=true.

# USE_SCHEDULED_QUERIES: "true" uses Hive's own Scheduled Queries to drive
# incremental DUMP/LOAD after bootstrap (current/existing behavior) - once bootstrap runs
# once, subsequent script invocations just detect the DB exists and skip, since Hive itself
# is driving incrementals. "false" (default) disables Hive Scheduled Query creation entirely
# and instead runs a real incremental REPL DUMP -> DistCp -> REPL LOAD cycle directly on
# every subsequent invocation - use this when an external scheduler (cron, Pulse Actions) is
# re-invoking this script on its own interval instead of relying on Hive's scheduler.
# Positional arg 12, or override via environment: USE_SCHEDULED_QUERIES=true (positional arg
# takes precedence if both are set).

# Lock directory used to prevent overlapping incremental cycles for the same DB when this
# script is invoked repeatedly (e.g. from an external cron loop) with
# USE_SCHEDULED_QUERIES=false. Concurrent REPL DUMP/LOAD against the same DB is not safe.
INCREMENTAL_LOCK_DIR="${INCREMENTAL_LOCK_DIR:-/var/tmp/hive-bdr-incremental-locks}"

########################################
# HIVE_REPL_SNAPSHOT_COPY: "true" or "false" (default: false, matches Hive's own default
# for hive.repl.externaltable.snapshotdiff.copy).
#
# When "true": REPL DUMP/LOAD WITH clauses add
#   'hive.repl.externaltable.snapshotdiff.copy'='true'
#   'hive.repl.external.warehouse.single.copy.task'='true'
#   'hive.repl.externaltable.snapshot.overwrite.target'='true'
# so REPL LOAD's internal external-table data copy uses HDFS snapshot-diff based DistCp
# (only transfers changed blocks since the last snapshot) instead of a full listing-based
# copy every time. This is the mechanism for scaling large (e.g. 1TB+) external table
# bootstraps/incrementals without disabling hive.repl.run.data.copy.tasks.on.target.
#
# Prerequisite: HDFS snapshots must be allowed (hdfs dfsadmin -allowSnapshot) on BOTH the
# source external table warehouse dir and REPL_EXTERNAL_BASE_DIR on the destination. This
# script handles that automatically (idempotent, per-directory lock files, same pattern as
# hadoop_dr_replication.sh Stage 2) via enable_external_table_snapshots() when this flag is
# "true" - see that function for details.
#
# When "false" (default): none of the above properties are set, external table copy uses
# Hive's normal listing-based copy (as before) - no snapshot prerequisite needed.
#
# Default is "false" here: this feature has NOT yet been validated end-to-end across a
# FAILOVER_MODE=true cycle (confirmed via testing: real failover DUMP/LOAD failures were
# hit independent of this flag's value, tied to hive.repl.rootdir reuse - see FAILOVER_MODE
# notes below - but the combination of snapshot-diff copy + failover remains untested past
# that point). Enable explicitly (HIVE_REPL_SNAPSHOT_COPY=true) only for non-failover
# bootstrap/incremental replication of large external tables.
########################################
HIVE_REPL_SNAPSHOT_COPY="${HIVE_REPL_SNAPSHOT_COPY:-false}"

# Snapshot-diff external table copy is untested against a failover cycle (see notes above)
# - force it off whenever FAILOVER_MODE=true, regardless of what was requested, rather than
# letting an unvalidated combination run.
if [[ "${FAILOVER_MODE,,}" == "true" && "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
  echo "[WARN] FAILOVER_MODE=true - forcing HIVE_REPL_SNAPSHOT_COPY=false (untested combination, see script header notes)"
  HIVE_REPL_SNAPSHOT_COPY="false"
fi

# Lock directory for per-directory external-table snapshot-capability locks, used only
# when HIVE_REPL_SNAPSHOT_COPY=true. Mirrors SNAP_LOCK_DIR in hadoop_dr_replication.sh.
SNAP_LOCK_DIR="${SNAP_LOCK_DIR:-/var/tmp/hive-bdr-snapshot-setup-locks}"

# Base directory Hive uses for EXTERNAL table data on the SOURCE cluster when a table has
# no explicit LOCATION (i.e. the source's hive.metastore.warehouse.external.dir). Used ONLY
# to build REPL_EXTERNAL_SRC_DIR as "<this>/<db>.db" (Hive's own default external table
# layout) - the real source-side path checked/allowSnapshot'd by
# enable_external_table_snapshots(). Does NOT affect REPL_EXTERNAL_BASE_DIR (the destination
# relocation root), which is a separate, unrelated path - see derive_db_vars.
# Verified default on a real cluster: /warehouse/tablespace/external/hive (tables land at
# /warehouse/tablespace/external/hive/<db>.db/<table>). Older Hive/HDP layouts used
# /user/hive/external instead - override this if your source cluster's actual
# hive.metastore.warehouse.external.dir differs from the default below.
# NOTE: only covers tables using the default external location; a table created with an
# explicit LOCATION outside this dir needs separate snapshot setup.
HIVE_EXTERNAL_WAREHOUSE_DIR="${HIVE_EXTERNAL_WAREHOUSE_DIR:-/warehouse/tablespace/external/hive}"

########################################
# YARN_QUEUE - YARN Capacity Scheduler queue that REPL LOAD's internal data-copy jobs
# (Stage-0:COPY, launched on the DESTINATION cluster during LOAD) should submit to.
# Default: "default".
#
# Only affects LOAD, not DUMP: DUMP does not launch a YARN copy job (it just reads/writes
# metadata + snapshot diffs on the source), so the queue is only set on the destination
# beeline session before REPL LOAD executes. Confirmed via YARN ResourceManager UI: without
# this, every "distcp: Repl#<db>" MAPREDUCE application launched by LOAD lands in the
# "default" queue regardless of intent.
#
# Set via two SET statements issued in the same beeline session immediately before the
# REPL LOAD statement (see beeline_exec_load()):
#   SET mapreduce.job.queuename=<YARN_QUEUE>;   -- the underlying MR/distcp job's queue
#   SET tez.queue.name=<YARN_QUEUE>;            -- the Tez session's queue (if HS2 uses Tez)
# Both are set together since the HS2 query itself may run on Tez while the DirCopyTask's
# internal copy job is a separate MapReduce/distcp job - either engine could be in play
# depending on cluster config, so both properties are set to be safe.
#
# Applies to: immediate LOAD executions this script runs directly (bootstrap, incremental
# cycle, failover). For Hive Scheduled Queries (USE_SCHEDULED_QUERIES=true), the same SET
# statements are embedded inside the CREATE SCHEDULED QUERY LOAD body itself, since that
# query runs later under Hive's own scheduler, not through this script's beeline session.
# Set via positional arg 6, or override via environment: YARN_QUEUE=testqueue (positional
# arg takes precedence if both are set).
########################################

########################################
# HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS - "true" or "false" (default: false, matches Hive's
# own default for hive.repl.include.materialized.views).
#
# When "true": REPL DUMP/LOAD WITH clauses add
#   'hive.repl.include.materialized.views'='true'
# so materialized views in the replicated DB(s) are included in DUMP/LOAD, same as regular
# tables.
#
# Left "false" by default deliberately, NOT just to mirror Hive's default:
#   - MVs are derived/rebuildable data, not source-of-truth data. Hive replication copies
#     the MV's last-materialized snapshot as-is; it does not trigger a REBUILD on the
#     destination, so a replicated MV can silently drift out of sync with its base tables
#     depending on the destination's own rewrite/refresh configuration.
#   - Adds extra data volume/time to every DUMP/LOAD cycle (bootstrap AND incremental) for
#     deployments that don't use or don't need to replicate MVs.
#   - Untested against this script's HIVE_REPL_SNAPSHOT_COPY (external-table snapshot-diff)
#     path - no validation here that the two features interact cleanly.
# Enable only for deployments that have confirmed they need replicated MV data and have
# validated the staleness/rebuild implications on the destination cluster.
# Override via environment: HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS=true
########################################
HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS="${HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS:-false}"

# Normalize REPL_BASE_DIR to always have a trailing slash
REPL_BASE_DIR="${REPL_BASE_DIR%/}/"

# Normalize REPL_EXTERNAL_BASE_DIR_ROOT to always have exactly one leading and one trailing slash
REPL_EXTERNAL_BASE_DIR_ROOT="/${REPL_EXTERNAL_BASE_DIR_ROOT#/}"
REPL_EXTERNAL_BASE_DIR_ROOT="${REPL_EXTERNAL_BASE_DIR_ROOT%/}/"

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

# compute_repl_external_base_dir: set REPL_EXTERNAL_BASE_DIR (the external-table relocation
# base dir, hive.repl.replica.external.table.base.dir) rooted at the given nameservice.
# NOTE: this is a RELOCATION root, not a mirror of the source's actual external warehouse
# path. Per HiveConf docs, hive.repl.replica.external.table.base.dir is "prefixed to the
# source external table path on target cluster" - i.e. Hive appends the source table's
# own path onto this base. Setting it to the SAME path shape as the source's real
# warehouse.external.dir causes a doubled/nested destination path and REPL LOAD failure
# (confirmed via testing: "Failed to AllowSnapshot on .../snap_test1.db/.../snap_test1.db").
# Keep this as an arbitrary, distinct relocation root (verified working in earlier tests).
#
# Must always be re-rooted at whichever nameservice is the actual REPL LOAD target for the
# current direction (DST_NAMESERVICE normally, SRC_NAMESERVICE during failover) - reusing a
# value rooted at the wrong side causes the destination LOCATION to compound-nest on every
# run (confirmed via testing: each cycle appended the PREVIOUS cycle's already-relocated
# full path onto the same base dir shape again).
#
# REPL_EXTERNAL_BASE_DIR_APPEND_DB=false (env var; default) drops the ${HIVE_DB_NAME} suffix,
# giving a bare per-nameservice root shared by every DB. Combined with the default
# REPL_EXTERNAL_BASE_DIR_ROOT="/", this is what makes the destination external-table path
# mirror the source path exactly (aside from nameservice/host) - confirmed via testing:
# with APPEND_DB=true the destination path came out prefixed with /<db_name>, not matching
# source. Set APPEND_DB=true only if REPL_EXTERNAL_BASE_DIR_ROOT is a shared non-root path
# (e.g. /user/hive/external/) and per-DB isolation under it is wanted instead of path parity.
compute_repl_external_base_dir() {
  local load_target_nameservice="$1"
  if [[ "${REPL_EXTERNAL_BASE_DIR_APPEND_DB,,}" == "false" ]]; then
    REPL_EXTERNAL_BASE_DIR="hdfs://${load_target_nameservice}${REPL_EXTERNAL_BASE_DIR_ROOT}"
  else
    REPL_EXTERNAL_BASE_DIR="hdfs://${load_target_nameservice}${REPL_EXTERNAL_BASE_DIR_ROOT}${HIVE_DB_NAME}"
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
  # Base directory on destination for replicated EXTERNAL tables (per-DB).
  # Normal bootstrap/incremental direction: REPL LOAD target is DST_NAMESERVICE.
  compute_repl_external_base_dir "$DST_NAMESERVICE"
  
  # NOTE: the dump-source external table warehouse dir (used by
  # enable_external_table_snapshots() when HIVE_REPL_SNAPSHOT_COPY=true) is computed
  # dynamically inside that function from whichever nameservice is passed to it - it varies
  # depending on dump direction (SRC_NAMESERVICE normally, DST_NAMESERVICE during failover),
  # so it is NOT precomputed here as a fixed per-DB global.
  # NOTE: this only matches tables using Hive's default external location - a table created
  # with an explicit LOCATION outside HIVE_EXTERNAL_WAREHOUSE_DIR will not be covered by the
  # allowSnapshot call in enable_external_table_snapshots() and needs its own snapshot setup.
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
#
# Returns 0 if valid Kerberos tickets were found (Kerberos mode), 1 otherwise (non-Kerberos / sudo mode).
########################################
detect_and_set_kerberos_cache() {
    if ! command -v klist >/dev/null 2>&1; then
        return 1
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
    return 1
}

if detect_and_set_kerberos_cache; then
    KERBEROS_ENABLED="yes"
else
    KERBEROS_ENABLED="no"
    echo "[INFO] Kerberos not detected — HDFS commands will run via sudo as HDFS_USER"
fi

########################################
# HDFS_USER - user to run `hdfs dfs` / `hdfs dfsadmin` commands as when Kerberos is NOT
# enabled. MUST be an HDFS superuser (or in the HDFS supergroup) - allowSnapshot and
# mkdir/chmod on directories owned by other users (e.g. hive) require superuser privileges;
# a non-superuser account will fail with AccessControlException.
# Set via positional arg 9, or override via environment: HDFS_USER=hdfs (positional arg
# takes precedence if both are set). When Kerberos is enabled, commands run as the current
# user (to preserve tickets) and HDFS_USER is not used.
########################################
# Beeline authentication (non-Kerberos only)
#
# When Kerberos is NOT enabled, beeline needs an explicit -n <user> or HiveServer2
# will authenticate the connection as "anonymous" (visible e.g. in
# sys.scheduled_queries.user). Two non-Kerberos sub-modes are supported:
#
#   HIVE_LDAP_ENABLED=false (default):
#     HS2 is using pass-through/NONE auth - the password value is not actually
#     validated. We pass -n "$HIVE_USER" -p "$HIVE_USER" (username as password)
#     purely to satisfy beeline's syntax and avoid the "anonymous" fallback.
#
#   HIVE_LDAP_ENABLED=true:
#     HS2 is backed by real LDAP auth - the password IS validated. HIVE_PASSWORD
#     must be set to the actual LDAP credential; the script fails fast if it is
#     missing rather than silently sending a wrong/empty password.
#
# Set via positional args, or override via environment (positional arg takes precedence
# if both are set):
#   HIVE_USER         - beeline username (default: hdfs). Also used as password
#                       when HIVE_LDAP_ENABLED=false. Positional arg 10.
#   HIVE_LDAP_ENABLED - "true" or "false" (default: false). Positional arg 11.
#   HIVE_PASSWORD     - real LDAP password; required when HIVE_LDAP_ENABLED=true. Not a
#                       positional arg (secret - env var only).
#
# When Kerberos IS enabled, none of this is used - beeline authenticates via the
# active Kerberos ticket and no -n/-p is passed.
########################################
HIVE_PASSWORD="${HIVE_PASSWORD:-}"

declare -a BEELINE_AUTH_ARGS=()
if [[ "$KERBEROS_ENABLED" == "no" ]]; then
    if [[ "${HIVE_LDAP_ENABLED,,}" == "true" ]]; then
        if [[ -z "$HIVE_PASSWORD" ]]; then
            echo "[ERROR] HIVE_LDAP_ENABLED=true but HIVE_PASSWORD is not set." >&2
            echo "[ERROR] Set HIVE_PASSWORD to the real LDAP credential for HIVE_USER='${HIVE_USER}'." >&2
            exit 1
        fi
        BEELINE_AUTH_ARGS=(-n "$HIVE_USER" -p "$HIVE_PASSWORD")
        echo "[INFO] Beeline auth: LDAP mode, user=${HIVE_USER}"
    else
        BEELINE_AUTH_ARGS=(-n "$HIVE_USER" -p "$HIVE_USER")
        echo "[INFO] Beeline auth: non-LDAP mode, user=${HIVE_USER} (password=username)"
    fi
fi

# beeline_exec: run beeline with the correct auth args spliced in after -u <jdbc_url>.
# Usage: beeline_exec <jdbc_url> [beeline args...]
beeline_exec() {
    local jdbc_url="$1"
    shift
    beeline -u "$jdbc_url" "${BEELINE_AUTH_ARGS[@]}" "$@"
}

# beeline_exec_load: like beeline_exec, but first issues SET statements (in the same
# session, as separate -e flags executed in order before the caller's statement) so
# REPL LOAD's internal data-copy YARN job (Stage-0:COPY) submits to YARN_QUEUE instead of
# the cluster's "default" queue. Only use this for REPL LOAD calls - DUMP does not launch
# a YARN copy job, so setting the queue there has no effect (see YARN_QUEUE comment above).
# Usage: beeline_exec_load <jdbc_url> -e "<REPL LOAD ...>"
beeline_exec_load() {
    local jdbc_url="$1"
    shift
    beeline -u "$jdbc_url" "${BEELINE_AUTH_ARGS[@]}" \
        -e "SET mapreduce.job.queuename=${YARN_QUEUE};" \
        -e "SET tez.queue.name=${YARN_QUEUE};" \
        "$@"
}

# Wrapper to run `hdfs dfs` / `hdfs dfsadmin` commands (mkdir, chmod, allowSnapshot).
# If Kerberos is enabled, run as current user (preserves tickets).
# Otherwise, sudo -u to HDFS_USER, which must be an HDFS superuser (preserving environment
# via -E for HADOOP_CLIENT_OPTS etc).
run_as_hdfs() {
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        "$@"
    else
        sudo -E -u "$HDFS_USER" "$@"
    fi
}

# allow_snapshot_idempotent: run `hdfs dfsadmin -allowSnapshot <dir>` and treat
# "already snapshottable" as success. Returns 0 on success (including already-enabled), 1
# on failure. Same idempotency semantics as hadoop_dr_replication.sh Stage 2.
allow_snapshot_idempotent() {
  local nameservice="$1"
  local dir="$2"
  local label="$3"
  local out rc
  out=$(run_as_hdfs hdfs dfsadmin -fs "hdfs://${nameservice}" -allowSnapshot "$dir" 2>&1 | grep -v "^SLF4J:")
  rc="${PIPESTATUS[0]}"
  if [[ $rc -eq 0 ]] || echo "$out" | grep -qi "already.*snapshottable"; then
    [[ -n "$out" ]] && echo "$out"
    echo "[INFO] Snapshot enabled on ${label}: ${dir}"
    return 0
  fi
  [[ -n "$out" ]] && echo "$out"
  echo "[ERROR] FAILED to enable snapshot on ${label}: ${dir}"
  return 1
}

# enable_external_table_snapshots: idempotently allowSnapshot on the ACTUAL dump-source
# external warehouse dir only, for the current DB (HIVE_DB_NAME - set by derive_db_vars).
# Required before hive.repl.externaltable.snapshotdiff.copy=true will work. Uses a per-DB
# lock file (keyed by DB name AND dump-source nameservice) so this only runs once per DB
# per dump-source, not on every script invocation. Only called when
# HIVE_REPL_SNAPSHOT_COPY=true.
#
# Usage: enable_external_table_snapshots [dump_source_nameservice]
#   dump_source_nameservice defaults to SRC_NAMESERVICE (the normal bootstrap/incremental
#   case, where SRC_NAMESERVICE is always the one running REPL DUMP). Callers in
#   failover_one_db MUST pass DST_NAMESERVICE explicitly, since failover reverses direction
#   and DST_NAMESERVICE is the one actually running REPL DUMP in that path - confirmed via
#   testing: without this, the real dump-source side (DST_NAMESERVICE post-failover) never
#   gets allowSnapshot applied at all, and the failover LOAD fails with "Unable to delete
#   snapshot ... snapshot name: <db>replOld" because the snapshot-diff machinery has no
#   valid snapshot capability to work with on that side.
#
# IMPORTANT: does NOT call allowSnapshot on REPL_EXTERNAL_BASE_DIR (the destination
# relocation root). Confirmed via testing: HDFS does not allow a directory to become
# snapshottable if an ancestor directory is already snapshottable. hive.repl.replica.
# external.table.base.dir is prefixed with the source table's full path by Hive's
# DirCopyTask (see derive_db_vars comment), so the directory Hive actually needs
# snapshottable on the destination is a NESTED subdirectory under REPL_EXTERNAL_BASE_DIR
# that does not exist until copy time - pre-enabling allowSnapshot on the base dir itself
# blocks Hive from enabling it on that nested path ("Failed to AllowSnapshot on
# .../REPL_EXTERNAL_BASE_DIR/<full source path>"). Hive's DirCopyTask handles the
# destination-side allowSnapshot itself at copy time; this script only needs to prepare
# the dump-source side in advance.
enable_external_table_snapshots() {
  local dump_source_ns="${1:-$SRC_NAMESERVICE}"
  local dump_source_path="hdfs://${dump_source_ns}${HIVE_EXTERNAL_WAREHOUSE_DIR}/${HIVE_DB_NAME}.db"

  mkdir -p "$SNAP_LOCK_DIR" 2>/dev/null || true
  # Lock is keyed by DB + dump-source nameservice, NOT just DB - a failover flips which
  # side is the real dump source, and that side needs its own independent check/enable;
  # a lock written for one direction must not be trusted for the other.
  local lock_file="${SNAP_LOCK_DIR}/${HIVE_DB_NAME}__${dump_source_ns}.lock"

  if [[ -f "$lock_file" ]]; then
    echo "[DEBUG] External table snapshot capability already enabled for ${HIVE_DB_NAME} on dump source ${dump_source_ns} (lock present: ${lock_file})"
    return 0
  fi

  echo "$SUBSEP"
  echo "Enabling HDFS snapshot capability for external-table snapshot-diff copy (dump source: ${dump_source_ns})..."
  local src_ok=false
  local src_path="${dump_source_path/hdfs:\/\/${dump_source_ns}/}"
  # REPL_EXTERNAL_BASE_DIR's own nameservice is the actual LOAD target's nameservice - it is
  # DST_NAMESERVICE in the normal bootstrap/incremental direction, but re-rooted to
  # SRC_NAMESERVICE by failover_one_db() during failover (since LOAD then runs against
  # SRC_JDBC_URL). Parse it out of the value itself rather than assuming DST_NAMESERVICE, or
  # this breaks under failover (confirmed via testing: hardcoding DST_NAMESERVICE here left
  # the prefix-strip below a no-op post-failover, since REPL_EXTERNAL_BASE_DIR no longer
  # started with "hdfs://${DST_NAMESERVICE}").
  local base_dir_ns="${REPL_EXTERNAL_BASE_DIR#hdfs://}"
  base_dir_ns="${base_dir_ns%%/*}"
  local dst_path="${REPL_EXTERNAL_BASE_DIR#hdfs://${base_dir_ns}}"

  if run_as_hdfs hdfs dfs -fs "hdfs://${dump_source_ns}" -test -d "$src_path"; then
    allow_snapshot_idempotent "$dump_source_ns" "$src_path" "DUMP SOURCE (${dump_source_ns})" && src_ok=true
  else
    echo "[WARN] Dump-source external warehouse dir does not exist yet, skipping allowSnapshot: ${dump_source_path}"
    echo "[WARN] It will be created by Hive on first external table creation; snapshot will be retried on next run."
  fi

  # Ensure the destination relocation root exists (but do NOT allowSnapshot it - see note
  # above). Hive's DirCopyTask creates and snapshot-enables the nested destination path
  # itself during copy.
  run_as_hdfs hdfs dfs -fs "hdfs://${base_dir_ns}" -mkdir -p "$dst_path" || true

  if [[ "$src_ok" == "true" ]]; then
    : >"$lock_file"
    echo "Snapshot capability enabled for ${HIVE_DB_NAME} external tables on dump source ${dump_source_ns} (lock: ${lock_file})"
  else
    echo "[WARN] Snapshot capability not fully enabled for ${HIVE_DB_NAME} on dump source ${dump_source_ns} - will retry on next invocation."
  fi
  echo ""
}

# snapshot_copy_props: echoes the extra HiveConf WITH-clause properties (each ending in a
# comma, ready to splice into a REPL DUMP/LOAD WITH() block) for snapshot-diff external
# table copy, when HIVE_REPL_SNAPSHOT_COPY=true. Echoes nothing when false.
snapshot_copy_props() {
  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    printf "%s\n" \
      "'hive.repl.externaltable.snapshotdiff.copy'='true'," \
      "'hive.repl.external.warehouse.single.copy.task'='true'," \
      "'hive.repl.externaltable.snapshot.overwrite.target'='true',"
  fi
}

# materialized_view_props: echoes the extra HiveConf WITH-clause property (ending in a
# comma, ready to splice into a REPL DUMP/LOAD WITH() block) to include materialized views,
# when HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS=true. Echoes nothing when false (default).
materialized_view_props() {
  if [[ "${HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS,,}" == "true" ]]; then
    printf "%s\n" "'hive.repl.include.materialized.views'='true',"
  fi
}

TOTAL_STEPS=6
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
  sq_output=$( beeline_exec "${jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "${sq_sql}" 2>&1 || true )

  # If sys.scheduled_queries is not available, fall back to information_schema
  if echo "$sq_output" | grep -q "Table not found.*scheduled_queries"; then
    echo "[INFO] sys.scheduled_queries not available, trying information_schema.scheduled_queries"
    sq_sql="SELECT schedule_name FROM information_schema.scheduled_queries WHERE schedule_name = '${sq_name}';"
    echo "Executing: ${sq_sql}"
    sq_output=$( beeline_exec "${jdbc_url}" \
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
    return 1
  fi

  if [[ -z "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${sq_name}' does not exist — nothing to disable."
    return 0
  fi

  local sql="ALTER SCHEDULED QUERY ${sq_name} DISABLE;"
  echo "Executing: ${sql}"
  if ! beeline_exec "${jdbc_url}" -e "${sql}"; then
    echo "ERROR: Failed to disable scheduled query '${sq_name}'"
    return 1
  fi
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
    return 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${SRC_SCHEDULED_QUERY_NAME}' already exists on source. Skipping creation."
  else
    local dump_sql
    dump_sql="CREATE SCHEDULED QUERY ${SRC_SCHEDULED_QUERY_NAME} ${dump_schedule} AS
REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating scheduled query on source: ${SRC_SCHEDULED_QUERY_NAME}"
    echo "Executing: ${dump_sql}"
    echo ""
    if ! beeline_exec "${SRC_JDBC_URL}" -e "${dump_sql}"; then
      echo "ERROR: Failed to create scheduled query '${SRC_SCHEDULED_QUERY_NAME}' on source"
      return 1
    fi
  fi
  echo ""

  echo "$SUBSEP"
  # Check if destination scheduled query already exists
  echo "Checking if scheduled query exists on destination: ${DST_SCHEDULED_QUERY_NAME}"
  if ! check_scheduled_query_exists "${DST_JDBC_URL}" "${DST_SCHEDULED_QUERY_NAME}"; then
    echo "ERROR: Scheduled query exist check failed on destination"
    return 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Scheduled query '${DST_SCHEDULED_QUERY_NAME}' already exists on destination. Skipping creation."
  else
    # NOTE: YARN_QUEUE is NOT applied here. CREATE SCHEDULED QUERY ... AS <body> takes a
    # single statement body, so the SET mapreduce.job.queuename/tez.queue.name approach
    # used for immediate LOAD calls (beeline_exec_load) doesn't apply - this scheduled
    # query runs later under Hive's own scheduler, not through this script's beeline
    # session. Left unresolved since USE_SCHEDULED_QUERIES=false is the tested/default
    # path; revisit if USE_SCHEDULED_QUERIES=true is actually used and queue targeting is
    # needed for the scheduler-driven LOAD.
    local load_sql="CREATE SCHEDULED QUERY ${DST_SCHEDULED_QUERY_NAME} ${load_schedule} AS
REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating scheduled query on destination: ${DST_SCHEDULED_QUERY_NAME}"
    echo "Executing: ${load_sql}"
    echo ""
    if ! beeline_exec "${DST_JDBC_URL}" -e "${load_sql}"; then
      echo "ERROR: Failed to create scheduled query '${DST_SCHEDULED_QUERY_NAME}' on destination"
      return 1
    fi
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

  if [[ "${USE_SCHEDULED_QUERIES,,}" == "false" ]]; then
    echo "USE_SCHEDULED_QUERIES=false; skipping reversed scheduled query setup (incremental cycle runs directly from this script)."
    return
  fi

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
    return 1
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
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating reversed dump scheduled query on new primary (${DST_NAMESERVICE}): ${rev_dump_sq_name}"
    echo "Executing: ${dump_sql}"
    echo ""
    if ! beeline_exec "${DST_JDBC_URL}" -e "${dump_sql}"; then
      echo "ERROR: Failed to create reversed dump scheduled query '${rev_dump_sq_name}' on new primary"
      return 1
    fi
  fi
  echo ""

  echo "$SUBSEP"
  # LOAD scheduled query on SRC (new replica / old primary)
  echo "Checking if reversed load scheduled query exists on new replica (${SRC_NAMESERVICE}): ${rev_load_sq_name}"
  if ! check_scheduled_query_exists "${SRC_JDBC_URL}" "${rev_load_sq_name}"; then
    echo "ERROR: Scheduled query exist check failed on new replica"
    return 1
  fi

  if [[ -n "$SQ_CHECK_RESULT" ]]; then
    echo "Reversed load scheduled query '${rev_load_sq_name}' already exists on new replica. Skipping creation."
  else
    # NOTE: YARN_QUEUE is NOT applied here - see the equivalent note in
    # create_scheduled_queries() for why (single-statement scheduled query body).
    local load_sql="CREATE SCHEDULED QUERY ${rev_load_sq_name} ${load_schedule} AS
REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Creating reversed load scheduled query on new replica (${SRC_NAMESERVICE}): ${rev_load_sq_name}"
    echo "Executing: ${load_sql}"
    echo ""
    if ! beeline_exec "${SRC_JDBC_URL}" -e "${load_sql}"; then
      echo "ERROR: Failed to create reversed load scheduled query '${rev_load_sq_name}' on new replica"
      return 1
    fi
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

  # Failover reverses direction: REPL DUMP now runs against DST_JDBC_URL (the new primary),
  # not SRC_JDBC_URL. derive_db_vars() unconditionally rooted REPL_ROOT_DIR_SRC/DST at
  # SRC_NAMESERVICE (the normal-direction dump source) - re-root them at the actual dump
  # source for this failover (DST_NAMESERVICE), or REPL DUMP writes its dump dir (including
  # the external-table file-list manifest) onto the WRONG cluster's HDFS. Confirmed via
  # testing: with the stale SRC_NAMESERVICE-rooted value, REPL LOAD's DirCopyTask read a
  # manifest whose paths were rooted at the old primary and copied "old primary -> old
  # primary" (a no-op), while metadata/partition events (small, embedded in the dump itself)
  # still replicated fine - so REPL STATUS/partition counts looked correct and REPL LOAD
  # logged "Data copy at load enabled: true" / "REPL::DATA_COPY_END: Completed all external
  # table copy tasks" as if it succeeded, but the actual new external-table row data (living
  # only on the new primary, DST_NAMESERVICE) never crossed clusters.
  REPL_ROOT_DIR_SRC="hdfs://${DST_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB_NAME}"
  REPL_ROOT_DIR_DST="${REPL_ROOT_DIR_SRC}"

  # Failover reverses direction: REPL LOAD now runs against SRC_JDBC_URL (old primary, now
  # new replica) instead of DST_JDBC_URL. derive_db_vars() computed REPL_EXTERNAL_BASE_DIR
  # rooted at DST_NAMESERVICE for the normal direction - re-root it at the actual LOAD
  # target (SRC_NAMESERVICE) for this failover. See compute_repl_external_base_dir().
  compute_repl_external_base_dir "$SRC_NAMESERVICE"

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
  if ! disable_scheduled_query "${SRC_JDBC_URL}" "${SRC_SCHEDULED_QUERY_NAME}"; then
    echo "ERROR: Failed to disable source scheduled query for ${HIVE_DB_NAME} - aborting failover for this DB"
    return 1
  fi
  echo ""

  echo "Disabling load scheduled query on original replica (${DST_NAMESERVICE}): ${DST_SCHEDULED_QUERY_NAME}"
  if ! disable_scheduled_query "${DST_JDBC_URL}" "${DST_SCHEDULED_QUERY_NAME}"; then
    echo "ERROR: Failed to disable destination scheduled query for ${HIVE_DB_NAME} - aborting failover for this DB"
    return 1
  fi
  echo ""

  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    # Failover reverses direction: DST_NAMESERVICE is the actual REPL DUMP source here
    # (the new primary), not SRC_NAMESERVICE - must be passed explicitly or the real
    # dump-source side never gets allowSnapshot applied (confirmed via testing: this
    # caused "Unable to delete snapshot ... snapshot name: <db>replOld" on the failover
    # LOAD, since the snapshot-diff machinery had no valid snapshot capability to work
    # with on the side that was actually dumping).
    enable_external_table_snapshots "$DST_NAMESERVICE"
    # The LOAD target (SRC_NAMESERVICE, the new replica) ALSO needs its own copy of the
    # external warehouse dir snapshottable, independent of the dump-source side above.
    # Confirmed via testing (snap_test7): ReplLoadTask's snapshot-diff apply manages a
    # replOld/replNew pair on the REPLICA's own warehouse dir too (not just the dump
    # source's) - if SRC_NAMESERVICE's copy was never enabled for snapshots (e.g. this DB's
    # earlier bootstrap/incrementals ran with HIVE_REPL_SNAPSHOT_COPY=false), the LOAD fails
    # with "Unable to delete snapshot for path: .../<db>.db snapshot name: <db>replOld" even
    # though that snapshot never existed there - Hive still expects the dir to be
    # snapshot-capable to proceed. Enabling it here is a no-op (lock-guarded) if the normal
    # bootstrap/incremental path already did this for SRC_NAMESERVICE previously.
    enable_external_table_snapshots "$SRC_NAMESERVICE"
  fi

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
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${DST_NAMESERVICE}: ${FAILOVER_DUMP_CMD}"
  echo ""
  if ! beeline_exec "${DST_JDBC_URL}" -e "${FAILOVER_DUMP_CMD}"; then
    echo "ERROR: Failover REPL DUMP failed on ${DST_NAMESERVICE} for ${HIVE_DB_NAME}"
    return 1
  fi
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
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${SRC_NAMESERVICE}: ${FAILOVER_LOAD_CMD}"
  echo ""
  if ! beeline_exec_load "${SRC_JDBC_URL}" -e "${FAILOVER_LOAD_CMD}"; then
    echo "ERROR: Failover REPL LOAD failed on ${SRC_NAMESERVICE} for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  echo "Validating replication status on new replica (${SRC_NAMESERVICE})..."
  beeline_exec "${SRC_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - failover DUMP/LOAD already succeeded)"
  echo ""

  ########################################
  # Failover Step 4: Create reversed scheduled queries
  ########################################
  echo "$SUBSEP"
  echo "[4/${FAILOVER_TOTAL_STEPS}] Setting up reversed incremental replication..."
  if ! create_reversed_scheduled_queries; then
    echo "ERROR: Failed to set up reversed scheduled queries for ${HIVE_DB_NAME}"
    return 1
  fi

  echo ""
  echo "$SEP"
  echo " Failover Replication Completed: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo ""
  echo "Database         : $HIVE_DB_NAME"
  echo "New primary      : $DST_NAMESERVICE (writes here)"
  echo "New replica      : $SRC_NAMESERVICE (receives replication)"
  echo "YARN Queue       : $YARN_QUEUE (REPL LOAD data-copy jobs)"
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

# run_incremental_cycle: perform one incremental REPL DUMP -> REPL LOAD cycle (REPL LOAD
# copies data itself via its internal COPY stage - no separate DistCp is run) for the
# current DB (HIVE_DB_NAME / HIVE_REPL_SPEC, set by derive_db_vars). Used when
# USE_SCHEDULED_QUERIES=false and the destination DB already exists (BOOTSTRAP=false path
# in replicate_one_db). Relies on Hive's own replication state (repl.last.id) to dump only
# events since the last successful DUMP - the WITH clause here intentionally sets
# bootstrap.external.tables=false, unlike the bootstrap cycle.
run_incremental_cycle() {
  echo "$SUBSEP"
  echo "[3-5/${TOTAL_STEPS}] Running incremental replication cycle (USE_SCHEDULED_QUERIES=false)..."
  echo ""

  # Prevent overlapping incremental cycles for the same DB (e.g. if this script is looped
  # externally faster than a cycle completes).
  mkdir -p "$INCREMENTAL_LOCK_DIR" 2>/dev/null || true
  local lock_file="${INCREMENTAL_LOCK_DIR}/${HIVE_DB_NAME}.lock"
  exec {lock_fd}>"$lock_file"
  if ! flock -n "$lock_fd"; then
    echo "WARN: Another incremental cycle for '${HIVE_DB_NAME}' appears to be in progress (lock: ${lock_file})."
    echo "Skipping this cycle to avoid concurrent REPL DUMP/LOAD against the same DB."
    exec {lock_fd}>&-
    return 0
  fi
  # Guarantee the lock fd is released on ANY exit from this function (normal completion,
  # explicit return, or set -e propagating a beeline_exec failure) - without this, a mid-cycle
  # failure would leave the fd open for the rest of the script process (verified: bash file
  # descriptors opened via `exec {fd}>` are shell-global, not function-scoped, so they are
  # not implicitly closed when the function returns).
  trap 'flock -u "$lock_fd" 2>/dev/null; exec {lock_fd}>&- 2>/dev/null; trap - RETURN' RETURN

  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    enable_external_table_snapshots
  fi

  echo "$SUBSEP"
  echo "Running incremental REPL DUMP on source cluster..."

  local incr_dump_cmd="REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing: $incr_dump_cmd"
  echo ""
  if ! beeline_exec "${SRC_JDBC_URL}" -e "$incr_dump_cmd"; then
    echo "ERROR: Incremental REPL DUMP failed for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  # NOTE: No separate DistCp step here. REPL LOAD reads 'hive.repl.rootdir' directly from
  # the SOURCE nameservice (REPL_ROOT_DIR_DST == REPL_ROOT_DIR_SRC by design - see
  # derive_db_vars) and performs its own internal COPY/DistCp (as a YARN job on the
  # destination cluster) for both metadata and actual table data - managed and external
  # alike - when hive.repl.run.data.copy.tasks.on.target=true. Verified: a pre-staged
  # destination-side copy of the dump dir is never read by REPL LOAD in this script, since
  # every REPL LOAD call uses the source-nameservice rootdir. Distcp-ing it separately was
  # dead work.
  echo "$SUBSEP"
  echo "Running incremental REPL LOAD on destination cluster..."

  local incr_load_cmd="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing: $incr_load_cmd"
  echo ""
  if ! beeline_exec_load "${DST_JDBC_URL}" -e "$incr_load_cmd"; then
    echo "ERROR: Incremental REPL LOAD failed for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  echo "$SUBSEP"
  echo "Validating replication status on destination..."
  beeline_exec "${DST_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - incremental DUMP/LOAD already succeeded)"
  echo ""

  echo "Incremental cycle completed for ${HIVE_DB_NAME}"
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
  echo "Log File  : $LOG_FILE"
  echo ""

  ########################################
  # 2. Check DB existence on destination
  ########################################
  echo "$SUBSEP"
  echo "[1/${TOTAL_STEPS}] Checking if database exists on destination..."

  DB_CHECK_OUTPUT=$( beeline_exec "${DST_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "SHOW DATABASES LIKE '${HIVE_DB_NAME}';" 2>&1 || true )

  DB_EXISTS=$(echo "$DB_CHECK_OUTPUT" | grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" | grep -v "^[[:space:]]*$" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n 1 || true)

  # Hive Metastore stores/returns database names lowercased, so compare case-insensitively
  if [[ -n "$DB_EXISTS" && "${DB_EXISTS,,}" != "${HIVE_DB_NAME,,}" ]]; then
    echo "ERROR: Database exist check failed on destination"
    echo "$DB_CHECK_OUTPUT"
    return 1
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

    if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
      enable_external_table_snapshots
    fi

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
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Executing: $DUMP_CMD"
    echo ""

    if ! beeline_exec "${SRC_JDBC_URL}" -e "$DUMP_CMD"; then
      echo "ERROR: Bootstrap REPL DUMP failed for ${HIVE_DB_NAME}"
      trap - ERR
      return 1
    fi
    echo ""

    # NOTE: No separate DistCp step here. REPL LOAD reads 'hive.repl.rootdir' directly from
    # the SOURCE nameservice (REPL_ROOT_DIR_DST == REPL_ROOT_DIR_SRC by design - see
    # derive_db_vars) and performs its own internal COPY/DistCp (as a YARN job on the
    # destination cluster) for both metadata and actual table data - managed and external
    # alike - when hive.repl.run.data.copy.tasks.on.target=true. Verified via REPL LOAD logs
    # (Stage:COPY / DistCp Counters) for both a managed table (data copied from source
    # .../hive/data/<db>/<table> straight into the destination warehouse dir) and an
    # external table (file_list_external-driven copy), with no destination-side pre-copy of
    # the dump dir present at all. A separate distcp of the dump dir to the destination was
    # dead work - its output was never read by REPL LOAD in this script.
    ########################################
    # 5. REPL LOAD (DESTINATION) - Bootstrap
    ########################################
    echo "$SUBSEP"
    echo "[4/${TOTAL_STEPS}] Running REPL LOAD on destination cluster (Bootstrap)..."

    # NOTE: 'hive.repl.run.data.copy.tasks.on.target' (default: true) is what makes REPL LOAD
    # actually copy external-table data (source external dir -> replica.external.table.base.dir)
    # as part of the LOAD itself. It is set explicitly to 'true' below rather than left to the
    # cluster default, since setting it 'false' silently skips the external-table data copy
    # entirely (verified: LOAD completes, metadata/partitions are created, but no bytes land
    # under the external base dir). Do not disable it - the DistCp step above only stages the
    # dump rootdir (metadata/events/_file_list_external manifest for external tables, plus
    # physical data for managed tables); it does NOT copy external table data itself.
    LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "Ensuring external table base directory exists on destination: ${REPL_EXTERNAL_BASE_DIR}"
    run_as_hdfs hdfs dfs -mkdir -p "${REPL_EXTERNAL_BASE_DIR}" || true
    run_as_hdfs hdfs dfs -chmod 1777 "${REPL_EXTERNAL_BASE_DIR}" || true
    echo ""

    echo "$SUBSEP"
    echo "Executing: $LOAD_CMD"
    echo ""

    if ! beeline_exec_load "${DST_JDBC_URL}" -e "$LOAD_CMD"; then
      echo "ERROR: Bootstrap REPL LOAD failed for ${HIVE_DB_NAME}"
      trap - ERR
      return 1
    fi
    echo ""

    ########################################
    # 6. Post-load validation - Bootstrap
    ########################################
    echo "$SUBSEP"
    echo "[5/${TOTAL_STEPS}] Validating replication status on destination..."
    echo ""

    beeline_exec "${DST_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - bootstrap DUMP/LOAD already succeeded)"
    echo ""

    # Bootstrap completed successfully — clear the error trap
    trap - ERR
  elif [[ "${USE_SCHEDULED_QUERIES,,}" == "false" ]]; then
    if ! run_incremental_cycle; then
      echo "ERROR: Incremental replication cycle failed for ${HIVE_DB_NAME}"
      return 1
    fi
  else
    echo "$SUBSEP"
    echo "[3-5/${TOTAL_STEPS}] Skipping bootstrap steps - Database already exists on destination"
    echo "Note: USE_SCHEDULED_QUERIES=true - Hive Scheduled Queries are expected to be driving"
    echo "      incremental replication. Set USE_SCHEDULED_QUERIES=false (the script default)"
    echo "      to run an incremental DUMP/LOAD cycle directly from this script invocation instead."
    echo ""
  fi

  ########################################
  # 7. Setup Scheduled Queries for Incremental Replication
  ########################################
  if [[ "${USE_SCHEDULED_QUERIES,,}" == "false" ]]; then
    echo "$SUBSEP"
    echo "[6/${TOTAL_STEPS}] Skipping Scheduled Query setup (USE_SCHEDULED_QUERIES=false)"
    echo ""
  else
    echo "$SUBSEP"
    echo "[6/${TOTAL_STEPS}] Setting up incremental replication..."
    if ! create_scheduled_queries; then
      echo "ERROR: Failed to set up scheduled queries for ${HIVE_DB_NAME}"
      return 1
    fi
  fi

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
  echo "YARN Queue   : $YARN_QUEUE (REPL LOAD data-copy jobs)"
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
echo "Failover Mode: $FAILOVER_MODE"
echo "Sched Queries: ${USE_SCHEDULED_QUERIES} $([ "${USE_SCHEDULED_QUERIES,,}" == "false" ] && echo "(incremental cycle runs directly from this script)" || echo "(Hive Scheduled Queries drive incrementals)")"
echo "Snapshot Copy: ${HIVE_REPL_SNAPSHOT_COPY} $([ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ] && echo "(snapshot-diff external table copy enabled)" || echo "(normal listing-based external table copy)")"
echo "YARN Queue   : ${YARN_QUEUE} (REPL LOAD data-copy jobs only)"
echo "Kerberos     : ${KERBEROS_ENABLED^^}"
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
  echo "Execution Mode: Kerberos (no sudo, beeline uses ticket)"
else
  echo "Execution Mode: sudo (HDFS user: ${HDFS_USER})"
  echo "Beeline Auth : user=${HIVE_USER}, ldap=${HIVE_LDAP_ENABLED}"
fi
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

########################################
# NOTE: why destination EXTERNAL TABLE LOCATION never matches source
########################################
# Hive's ReplExternalTables.externalTableDataPath() (ql/exec/repl/ReplExternalTables.java)
# always builds the destination path as:
#     REPL_EXTERNAL_BASE_DIR + <full source table path>
# (base dir is a RELOCATION ROOT, not a mirror of the source path) - unless the base dir's
# path component is exactly "/", which is special-cased to pass the source path through
# unchanged (still on the destination nameservice/authority).
#
# This means:
#   REPL_EXTERNAL_BASE_DIR="hdfs://${DST_NAMESERVICE}/${HIVE_DB_NAME}"
#     -> DOUBLED/NESTED path (e.g. /${HIVE_DB_NAME}/user/hive/external/${HIVE_DB_NAME})
#     -> this is the same bug already hit and fixed earlier in this script (see
#        derive_db_vars comment above REPL_EXTERNAL_BASE_DIR): confirmed via testing to
#        cause "Failed to AllowSnapshot on .../snap_test1.db/.../snap_test1.db" and
#        REPL LOAD failure. Do NOT use this form.
#
#   REPL_EXTERNAL_BASE_DIR="hdfs://${DST_NAMESERVICE}/"  (bare root)
#     -> destination LOCATION becomes path-identical to source (only nameservice differs)
#     -> BUT this pushes the snapshot-allow scope up to the filesystem root. With
#        HIVE_REPL_SNAPSHOT_COPY=true, enable_external_table_snapshots() (see comment above
#        that function) relies on the destination relocation root NOT already being
#        snapshottable, since Hive's DirCopyTask enables snapshot on a NESTED subdirectory
#        under it at copy time, and HDFS forbids a directory becoming snapshottable if an
#        ancestor already is. Root passthrough moves that ancestor conflict to the most
#        sensitive point in the tree. Untested here - do not switch to this form without
#        specifically validating snapshot-diff copy behavior at root first, or with
#        HIVE_REPL_SNAPSHOT_COPY=false.
#
# Current choice (REPL_EXTERNAL_BASE_DIR = "hdfs://${DST_NAMESERVICE}/user/hive/external/
# ${HIVE_DB_NAME}", set in derive_db_vars) is a deliberate, distinct relocation root: it
# does NOT match source LOCATION, but is the form verified working with snapshot-diff copy.
echo "Session Log: $SESSION_LOG_FILE"
echo ""

########################################
# NOTE: bare-root option (REPL_EXTERNAL_BASE_DIR_APPEND_DB=false + REPL_EXTERNAL_BASE_DIR_ROOT="/")
# deliberately tested and rejected as the default
########################################
# This combination (positional args 15 and 16) produces
# REPL_EXTERNAL_BASE_DIR="hdfs://<load-target-nameservice>/" - path component exactly "/" -
# which triggers Hive's bare-root passthrough special case described above: the
# destination EXTERNAL TABLE LOCATION becomes path-identical to the source (only the
# nameservice/authority differs). This was deliberately run (both normal and failover
# direction) specifically to get destination LOCATION to match source exactly.
#
# Deliberately NOT made the default (REPL_EXTERNAL_BASE_DIR_APPEND_DB stays "true"):
#   - Only validated with HIVE_REPL_SNAPSHOT_COPY=false. The untested-at-root concern
#     documented above (ancestor-snapshottable conflict with Hive's DirCopyTask) still
#     applies uncombined with HIVE_REPL_SNAPSHOT_COPY=true - do not flip that flag on
#     together with a bare "/" root without re-validating snapshot-diff copy at root first.
#   - A bare per-nameservice root is shared across every DB (no per-DB suffix), unlike the
#     default option-1 shape - multi-DB invocations relocate all DBs' external tables under
#     the same root, mirroring source layout exactly rather than isolating each DB under
#     its own relocation subdirectory.
# Kept available via positional args 15/16 for deployments that specifically need
# destination LOCATION to match source (e.g. tooling/scripts downstream that assume
# path-identical source/destination external table locations), not as a general default.
