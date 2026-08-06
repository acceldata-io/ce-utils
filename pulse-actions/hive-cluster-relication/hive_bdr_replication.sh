#!/bin/bash
# ==============================================================================
#  Hive Cluster Replication Script (Hive BDR)
#  Version : 4.2.0
#  Purpose : Replicate one or more Hive databases from a source cluster to a
#            destination cluster using Hive's native REPL DUMP / REPL LOAD
#            commands, and manage direction reversal (failover / failback)
#            between the two clusters.
# ==============================================================================
#
# WHAT THIS SCRIPT DOES
# ----------------------------------------------------------------------------
#   Hive's built-in replication (REPL DUMP on the source, REPL LOAD on the
#   destination) keeps a destination database in sync with a source database,
#   including both metadata and table data. REPL LOAD copies data itself, so
#   this script does not run any separate `hadoop distcp` step.
#
#   This script wraps that workflow so it can be run unattended (e.g. from
#   cron or an orchestration tool) and gives you:
#
#     1. Bootstrap replication
#        The first time a database is replicated, the destination database
#        does not exist yet. The script detects this and runs a full
#        REPL DUMP + REPL LOAD (bootstrap) cycle to create it.
#
#     2. Incremental replication
#        On every later run, the script detects that the destination
#        database already exists and runs a lightweight incremental
#        REPL DUMP + REPL LOAD cycle instead - only the changes made on the
#        source since the last run are copied. There is no separate
#        "incremental mode" to configure; the script always decides this
#        for you by checking whether the destination database exists.
#        To get incremental replication on a schedule, re-run this script
#        periodically (cron, systemd timer, or any external scheduler).
#
#     3. Multiple databases in one invocation
#        Pass more than one database (or table pattern) separated by "|" and
#        the script replicates each one in turn, reporting success/failure
#        per database.
#
#     4. Failover and failback (direction reversal)
#        If the source cluster becomes unavailable and the destination
#        cluster is promoted to take live traffic, this script can reverse
#        the replication direction so the (former) destination now dumps and
#        the (former) source now loads. The same reversal can be repeated
#        back and forth any number of times without ever having to swap
#        which cluster's connection details are passed to the script - see
#        "FAILOVER AND FAILBACK" below.
#
# HOW TO RUN IT
# ----------------------------------------------------------------------------
#   ./hive_bdr_replication.sh \
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
#     "<FAILOVER_MODE>" \
#     "<RECONCILE_EXTERNAL_DATA>"
#
#   All 12 arguments are positional - the order matters. Trailing arguments
#   may be omitted and will fall back to their defaults (shown below).
#
# POSITIONAL ARGUMENTS
# ----------------------------------------------------------------------------
#   1. HIVE_DB            (required)
#        The database(s) to replicate. Separate multiple entries with "|".
#          Single database    : "sales"
#          Multiple databases : "sales|analytics|hr"
#          Specific tables    : "sales.'(orders|customers)'"
#          Single table        : "sales.'orders'"
#          Exclude a table     : "sales.'(?!orders$).*'"
#        Note: a "|" written inside single quotes (i.e. inside a table
#        pattern) is treated as part of the pattern, not as a database
#        separator.
#
#   2. SRC_NAMESERVICE     (required)
#        The source cluster's HDFS nameservice (or "host:port" for a
#        non-HA NameNode). This is a fixed label for this cluster and does
#        not change when the replication direction is reversed - see
#        "FAILOVER AND FAILBACK" below.
#
#   3. DST_NAMESERVICE     (required)
#        The destination cluster's HDFS nameservice (or "host:port"),
#        same rules as SRC_NAMESERVICE above.
#
#   4. SRC_JDBC_URL        (required)
#        JDBC connection string for the source cluster's HiveServer2.
#        Example:
#          jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2
#
#   5. DST_JDBC_URL        (required)
#        JDBC connection string for the destination cluster's HiveServer2,
#        same format as SRC_JDBC_URL.
#
#   6. YARN_QUEUE          (default: "default")
#        The YARN Capacity Scheduler queue that REPL LOAD's internal data
#        copy job should run in. See the YARN_QUEUE section below.
#
#   7. REPL_BASE_DIR       (default: "/user/hive/repl/")
#        The HDFS directory (on the source cluster) where Hive stages the
#        REPL DUMP output before REPL LOAD reads it.
#
#   8. LOG_DIR             (default: "/var/log/hive-replication")
#        Local directory where this script writes its log files.
#
#   9. HDFS_USER           (default: "hdfs")
#        The OS user the script uses to run `hdfs dfs` / `hdfs dfsadmin`
#        commands when Kerberos is not in use. See "AUTHENTICATION" below.
#
#  10. HIVE_USER           (default: "hdfs")
#        The username passed to beeline when Kerberos is not in use. See
#        "AUTHENTICATION" below.
#
#  11. FAILOVER_MODE       (default: "false")
#        Set to "true" to reverse the replication direction (failover), or
#        "false" for normal replication. See "FAILOVER AND FAILBACK" below.
#
#  12. RECONCILE_EXTERNAL_DATA (default: "false")
#        Set to "true" ONLY for a database (or table pattern) where every
#        table is an EXTERNAL_TABLE and the load target already has
#        partial or full matching HDFS data worth not re-copying - for
#        example, an existing DR database that was moved aside to a
#        "_backup" database so this script's bootstrap REPL LOAD could run
#        against an empty database (Hive's REPL LOAD bootstrap path
#        refuses a non-empty target database, with no override). See
#        "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" below for the full
#        explanation of what this changes and why. Leave this "false" (the
#        default) for normal replication, and for ANY database that may
#        contain managed/ACID tables - the script fails fast, before
#        REPL DUMP/LOAD runs at all, if RECONCILE_EXTERNAL_DATA=true is
#        requested for a database containing a non-external table.
#
#   Any of arguments 6, 9, 10, 11, and 12 (YARN_QUEUE, HDFS_USER, HIVE_USER,
#   FAILOVER_MODE, RECONCILE_EXTERNAL_DATA) can also be supplied as an
#   environment variable of the same name instead of a positional argument.
#   If both are set, the positional argument wins.
#
# FAILOVER AND FAILBACK
# ----------------------------------------------------------------------------
#   SRC_NAMESERVICE / DST_NAMESERVICE / SRC_JDBC_URL / DST_JDBC_URL always
#   describe the SAME two clusters for the lifetime of a replication setup
#   (for example SRC = your production cluster, DST = your DR cluster).
#   These four values are NEVER swapped between runs, no matter which
#   direction replication is currently flowing.
#
#   Instead, direction is controlled entirely by FAILOVER_MODE / an internal
#   REPLICATION_DIRECTION value:
#     FAILOVER_MODE=false -> REPL DUMP runs on SRC, REPL LOAD runs on DST
#                            (normal direction)
#     FAILOVER_MODE=true  -> REPL DUMP runs on DST, REPL LOAD runs on SRC
#                            (reversed direction, used after a real cluster
#                            failover)
#
#   This lets you flip back and forth indefinitely using the exact same
#   command, changing only this one value:
#     Primary -> DR : FAILOVER_MODE=false   (or omit the argument)
#     DR -> Primary : FAILOVER_MODE=true
#     Primary -> DR : FAILOVER_MODE=false
#     DR -> Primary : FAILOVER_MODE=true
#     ... and so on.
#
#   Before requesting a direction change, make sure:
#     - Replication is already configured and has completed at least one
#       successful REPL DUMP/LOAD cycle in the CURRENT direction. The script
#       checks this automatically via a REPL STATUS pre-flight check and
#       will refuse to proceed with a clear error message if the new
#       "dump" side is not yet an eligible replication source.
#     - The real cluster failover has already happened at the
#       infrastructure level, and new writes are only occurring on the
#       cluster that is about to become the new dump source.
#
#   When FAILOVER_MODE=true is passed, the script performs 3 steps for each
#   database:
#     Step 1 - Pre-flight check: confirm the new dump side is eligible.
#     Step 2 - REPL DUMP on the new primary, with
#              'hive.repl.failover.start'='true'.
#     Step 3 - REPL LOAD on the new replica.
#
#   To go back to normal replication after a failover, run the script again
#   with FAILOVER_MODE=false (or omit the argument) - typically you run
#   FAILOVER_MODE=true for exactly one invocation to perform the failover,
#   then revert to the default for every run after that.
#
# RECONCILING PRE-EXISTING EXTERNAL TABLE DATA (RECONCILE_EXTERNAL_DATA)
# ----------------------------------------------------------------------------
#   A bootstrap REPL LOAD (Step 4 above) normally sets
#   'hive.repl.run.data.copy.tasks.on.target'='true', which makes REPL LOAD
#   copy every external table's data itself, as part of the LOAD. That
#   internal copy always re-copies every file listed in the REPL DUMP
#   manifest, with no regard for what may already exist at the destination
#   path - confirmed by testing: files already present on the load target,
#   byte-identical (same size, same checksum) to the source, were still
#   re-copied in full. There is no Hive configuration property that makes
#   this internal copy skip unchanged files.
#
#   This matters for a specific, real scenario: a load-target database that
#   already has data for the same tables you are about to replicate - for
#   example, an earlier/legacy replication tool (such as Cloudera BDR) has
#   already copied some or all of a database's external table data, or an
#   existing DR database was deliberately renamed aside to a "_backup"
#   database (see the empty-database-prep step you may already be running
#   separately) purely so this script's bootstrap REPL LOAD has an empty
#   database to bootstrap into - Hive's REPL LOAD bootstrap path refuses to
#   run against a non-empty target database, with no override. In that
#   situation the load target's HDFS files are frequently still physically
#   present at their original path (renaming a Hive table does not move its
#   underlying data), so REPL LOAD's normal full re-copy wastes bandwidth
#   and time proportional to the FULL table size, not just the genuinely
#   missing data.
#
#   Setting RECONCILE_EXTERNAL_DATA=true for a bootstrap run changes two
#   things:
#     1. The bootstrap REPL LOAD sets
#        'hive.repl.run.data.copy.tasks.on.target'='false' instead of
#        "true" - REPL LOAD then recreates metadata only (databases,
#        tables, partitions) and copies NO table data itself.
#     2. Immediately after that metadata-only LOAD succeeds, this script
#        runs a manual `hadoop distcp ${DISTCP_OPTS}` once per external
#        table, directly between that table's real LOCATION on the dump
#        source and its real LOCATION on the load target (read via
#        DESCRIBE FORMATTED on both sides, so this works correctly even for
#        tables with a custom, non-default LOCATION). Unlike REPL LOAD's
#        own internal copy, a real `hadoop distcp` with -update/
#        -skipcrccheck (the DISTCP_OPTS default) genuinely compares source
#        and destination and skips files that already match - this is the
#        ONLY point in the whole pipeline where that comparison happens.
#
#   RECONCILE_EXTERNAL_DATA=true REQUIRES every table in the database (or
#   table pattern) to be EXTERNAL_TABLE. Managed/ACID table data (base and
#   delta directories, valid-txn-lists, and so on) is Hive-owned in a way
#   that is not safe to reconcile with a raw filesystem-level distcp - there
#   is no equivalent manual step for managed tables. This script checks
#   every table on the dump source BEFORE running REPL DUMP/LOAD at all, and
#   fails fast with a clear error if it finds even one non-external table,
#   rather than disabling data copy for the whole database and silently
#   leaving a managed table's data missing.
#
#   RECONCILE_EXTERNAL_DATA is a per-database judgment call, not a setting
#   to leave on for every replication:
#     - Leave it "false" (the default) for normal bootstraps, for
#       incremental cycles (which never read this setting - an incremental
#       cycle only ever copies new events/files, so there is no
#       pre-existing-data problem to reconcile there), for failover, and
#       for any database that may contain managed/ACID tables.
#     - Set it "true" only when you specifically know: every table in this
#       database is external, AND the load target already has matching (or
#       partially matching) HDFS data for those tables that is worth not
#       re-copying from scratch.
#   On a genuinely fresh/empty load target (nothing pre-existing at any
#   destination path), RECONCILE_EXTERNAL_DATA=true is harmless but brings
#   no benefit - -update has nothing to skip, so the same bytes move either
#   way, just via a separate `hadoop distcp` process instead of REPL LOAD's
#   internal copy. There is no reason to enable it in that case.
#
# AUTHENTICATION
# ----------------------------------------------------------------------------
#   The script automatically detects whether Kerberos is available (via
#   `klist`). This changes how it runs `hdfs`/`beeline` commands:
#
#     Kerberos available:
#       Commands run as the current OS user, using the active Kerberos
#       ticket. HDFS_USER / HIVE_USER are not used.
#
#     Kerberos not available:
#       - `hdfs dfs` / `hdfs dfsadmin` commands run via `sudo -u $HDFS_USER`.
#         HDFS_USER must be an HDFS superuser (or a member of the HDFS
#         supergroup), because operations like `allowSnapshot` and
#         `chmod`/`mkdir` on directories owned by another user (e.g. `hive`)
#         require superuser privileges.
#       - beeline connects with `-n $HIVE_USER` so HiveServer2 does not
#         authenticate the session as "anonymous".
#
# INCREMENTAL REPLICATION
# ----------------------------------------------------------------------------
#   This script always drives incremental replication itself by re-running
#   a direct REPL DUMP -> REPL LOAD cycle; it does not use Hive Scheduled
#   Queries. To keep a database up to date, re-invoke this script on your
#   own schedule (cron, a systemd timer, or your orchestration tool of
#   choice) with the same arguments used for the original bootstrap run.
#
# ENVIRONMENT VARIABLES (ADVANCED / OPTIONAL)
# ----------------------------------------------------------------------------
#   These are not positional arguments - set them in the environment before
#   invoking the script, only if you need to change the default behavior.
#
#   HDFS_USER
#     Also positional argument 9. See "AUTHENTICATION" above.
#     Default: hdfs
#
#   HIVE_USER
#     Also positional argument 10. See "AUTHENTICATION" above.
#     Default: hdfs
#
#   HIVE_LDAP_ENABLED / HIVE_PASSWORD
#     Not positional arguments (kept as environment-only settings since
#     HIVE_PASSWORD is a credential). Controls the password beeline sends
#     alongside HIVE_USER when Kerberos is not in use:
#       HIVE_LDAP_ENABLED=false (default) - HiveServer2 is using
#         pass-through/NONE authentication, so the password value is not
#         actually checked. The script sends HIVE_USER's own value as the
#         password, purely to satisfy beeline's syntax.
#       HIVE_LDAP_ENABLED=true - HiveServer2 is backed by real LDAP
#         authentication. HIVE_PASSWORD must be set to the real LDAP
#         password for HIVE_USER; the script exits with an error if it is
#         missing.
#     Default: HIVE_LDAP_ENABLED=false
#
#   INCREMENTAL_LOCK_DIR
#     Directory used to store a small per-database lock file so two
#     incremental cycles for the same database can never run at the same
#     time (for example, if this script is re-invoked before the previous
#     run has finished).
#     Default: /var/tmp/hive-bdr-incremental-locks
#
#   BEELINE_VERBOSE
#     "true" or "false". When "true", every beeline call adds
#     "--verbose=true" for extra JDBC/session detail - useful while
#     diagnosing a hang or an unexpected failure.
#     Default: false
#
#   HEARTBEAT_INTERVAL_SECONDS
#     How often (in seconds) this script prints a "[HEARTBEAT] ... still
#     running" line while a beeline statement (REPL DUMP/LOAD, status
#     checks, etc.) is executing. beeline itself prints no progress output
#     while a statement runs server-side, so this is what shows the script
#     is still alive during a long DUMP/LOAD instead of going silent.
#     Default: 30
#
#   BEELINE_COMMAND_TIMEOUT_SECONDS
#     If set to a positive number, a beeline statement that runs longer
#     than this many seconds is killed automatically, with a message
#     pointing at likely causes (metastore lock, a stuck YARN data-copy
#     job, or an unreachable remote cluster) to check next.
#     Default: 0 (disabled - statements run to completion no matter how
#     long they take)
#
#   HIVE_REPL_SNAPSHOT_COPY
#     "true" or "false". When "true", REPL DUMP/LOAD use HDFS
#     snapshot-diff based copying for external table data - only the
#     blocks that changed since the last run are copied, instead of a full
#     directory listing and copy every time. This is the recommended way
#     to scale replication of large (for example, 1 TB or more) external
#     tables. When enabled, the script automatically runs
#     `hdfs dfsadmin -allowSnapshot` on the source external table
#     directory before each DUMP; no manual snapshot setup is required.
#     Default: false
#
#   SNAP_LOCK_DIR
#     Directory used to store lock files that record which external table
#     directories have already been made snapshot-capable, so the script
#     does not repeat that setup on every run. Only used when
#     HIVE_REPL_SNAPSHOT_COPY=true.
#     Default: /var/tmp/hive-bdr-snapshot-setup-locks
#
#   HIVE_EXTERNAL_WAREHOUSE_DIR
#     The base HDFS directory the source cluster uses for external tables
#     that do not have an explicit LOCATION (Hive's
#     `hive.metastore.warehouse.external.dir`). Used only to compute the
#     source-side path that needs snapshot capability when
#     HIVE_REPL_SNAPSHOT_COPY=true. Change this only if your source
#     cluster uses a non-default external warehouse path.
#     Default: /warehouse/tablespace/external/hive
#
#   YARN_QUEUE
#     Also positional argument 6. The YARN Capacity Scheduler queue used
#     for REPL LOAD's internal data-copy job on the destination cluster.
#     Only affects REPL LOAD (REPL DUMP does not launch a YARN job).
#     Default: default
#
#   HA_CONFIG_IN_WITH_CLAUSE
#     "true" or "false". Normally, an HA nameservice must already be
#     resolvable to HiveServer2 through the cluster's own hdfs-site.xml
#     (configured once, cluster-wide, via Ambari or similar). Set this to
#     "true" to have the script instead inject the HA NameNode properties
#     directly into every REPL DUMP/LOAD statement - useful when one
#     cluster's hdfs-site.xml does not yet know about the other cluster's
#     nameservice. Requires SRC_NN_HOSTS and DST_NN_HOSTS to be set.
#     Default: false
#
#   SRC_NN_HOSTS / DST_NN_HOSTS
#     Required when HA_CONFIG_IN_WITH_CLAUSE=true. Comma-separated
#     "<nn-id>=<host>:<port>" pairs describing each cluster's NameNodes.
#     Example:
#       SRC_NN_HOSTS="nn1=prod-nn1.example.com:8020,nn2=prod-nn2.example.com:8020"
#       DST_NN_HOSTS="nn1=dr-nn1.example.com:8020,nn2=dr-nn2.example.com:8020"
#
#   AUTOMATIC_FAILOVER_ENABLED
#     "true" or "false". Only used when HA_CONFIG_IN_WITH_CLAUSE=true.
#     Default: true
#
#   HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS
#     "true" or "false". When "true", materialized views are replicated
#     along with regular tables. Left disabled by default because a
#     replicated materialized view is copied as-is (its last-computed
#     result), without triggering a rebuild on the destination - so it can
#     silently fall out of sync with its base tables over time. Only
#     enable this after confirming that behavior is acceptable for your
#     use case.
#     Default: false
#
#   RECONCILE_EXTERNAL_DATA
#     Also positional argument 12. See "RECONCILING PRE-EXISTING EXTERNAL
#     TABLE DATA" above for the full explanation.
#     Default: false
#
#   DISTCP_OPTS
#     Tool-specific flags passed to the manual `hadoop distcp` calls this
#     script runs when RECONCILE_EXTERNAL_DATA=true (see above). Not used
#     for anything else - the normal bootstrap/incremental DUMP/LOAD flow
#     never runs `hadoop distcp` itself; REPL LOAD performs its own
#     internal data copy. Not a positional argument, since it is only
#     relevant together with RECONCILE_EXTERNAL_DATA=true.
#     Default: "-p -update -skipcrccheck"
#
# EXAMPLES
# ----------------------------------------------------------------------------
#   Example 1 - Bootstrap a single database, then keep it in sync by
#   re-running this same command on a schedule (e.g. cron):
#
#     ./hive_bdr_replication.sh \
#       "sales" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181,prod-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181,dr-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "false"
#
#   Example 2 - Replicate multiple databases in one invocation:
#
#     ./hive_bdr_replication.sh \
#       "sales|analytics|hr.'orders'" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "false"
#
#   Example 3 - Replicate specific tables only, instead of a whole
#   database:
#
#     ./hive_bdr_replication.sh \
#       "sales.'(orders|customers)'" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "false"
#
#   Example 4 - Failover after the DR cluster has been promoted to
#   primary (reverses replication direction so DR now dumps and the
#   original primary now loads). Only the last argument changes from
#   Example 1:
#
#     ./hive_bdr_replication.sh \
#       "sales" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181,prod-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181,dr-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "true"
#
#   Example 5 - Failback: return to normal direction after Example 4.
#   SRC_NAMESERVICE / DST_NAMESERVICE are identical to every previous
#   invocation - only FAILOVER_MODE flips back to "false":
#
#     ./hive_bdr_replication.sh \
#       "sales" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181,prod-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181,dr-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "false"
#
#   This Example 4 / Example 5 pattern can be repeated indefinitely for any
#   number of failover / failback cycles.
#
#   Example 6 - Bootstrap a database whose load-target already has
#   pre-existing/partial HDFS data for its (all-external) tables, without
#   re-copying data that is already correct. Only the last argument changes
#   from Example 1 - see "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA"
#   above before using this:
#
#     ./hive_bdr_replication.sh \
#       "sales" \
#       "prod-nameservice" \
#       "dr-nameservice" \
#       "jdbc:hive2://prod-host1:2181,prod-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://dr-host1:2181,dr-host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "default" \
#       "/user/hive/repl/" \
#       "/var/log/hive-replication" \
#       "hdfs" \
#       "hdfs" \
#       "false" \
#       "true"
#
# ==============================================================================

set -euo pipefail

# Dedicated file descriptor for heartbeat/debug messages printed by
# run_with_heartbeat() and beeline_exec_load() below. These messages must
# NEVER be written to stdout (fd 1) directly: several callers capture a
# beeline command's stdout via $(...) (for example, the database-existence
# check in replicate_one_db()), and a heartbeat line printed at the wrong
# moment would land in the middle of that captured text and corrupt it.
#
# fd 3 is set up in two stages: a safe default here (pointing at the
# script's original, pre-redirect stdout) so it is always valid even if a
# function runs before the session log is set up, and then re-pointed at
# the session-log "tee" pipeline once that is established further down -
# so heartbeat/debug messages always land in both the console and
# SESSION_LOG_FILE. Every heartbeat/debug message must be written with
# "echo ... >&${HEARTBEAT_FD}", never plain "echo".
exec 3>&1
HEARTBEAT_FD=3

# ------------------------------------------------------------------------------
#  Read positional arguments and apply defaults.
#  For YARN_QUEUE, HDFS_USER, HIVE_USER, FAILOVER_MODE, and
#  RECONCILE_EXTERNAL_DATA: if the positional argument is not supplied,
#  fall back to the environment variable of the same name, and finally to
#  a hardcoded default.
# ------------------------------------------------------------------------------
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
FAILOVER_MODE="${11:-${FAILOVER_MODE:-false}}"
# See "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" near the top of this
# file. Per-database judgment call, NOT a setting to leave "true" always -
# keep this "false" (the default) for any database that may contain
# managed/ACID tables; the script fails fast, before REPL DUMP/LOAD runs at
# all, if this is "true" for a database containing a non-external table.
RECONCILE_EXTERNAL_DATA="${12:-${RECONCILE_EXTERNAL_DATA:-false}}"

# DISTCP_OPTS - tool-specific `hadoop distcp` flags used only by the manual
# distcp calls this script runs when RECONCILE_EXTERNAL_DATA=true (see
# reconcile_external_table_data() below). Not a positional argument - only
# relevant together with RECONCILE_EXTERNAL_DATA=true, and every other
# environment-only setting in this script (HIVE_REPL_SNAPSHOT_COPY,
# HA_CONFIG_IN_WITH_CLAUSE, etc.) follows the same env-var-only pattern for
# settings that are not part of the common/required call shape.
# "-update"/"-skipcrccheck" are what make distcp genuinely compare source
# vs. destination and skip files that already match - this is the actual
# mechanism that avoids re-copying pre-existing, unchanged data.
DISTCP_OPTS="${DISTCP_OPTS:--p -update -skipcrccheck}"

# Fixed relocation settings for replicated external table data on the
# destination cluster. These intentionally have no positional argument or
# environment override: keeping them fixed guarantees the destination
# EXTERNAL TABLE LOCATION is always path-identical to the source location
# (only the nameservice/authority differs). See compute_repl_external_base_dir()
# below for how these two values are used together.
REPL_EXTERNAL_BASE_DIR_APPEND_DB=false
REPL_EXTERNAL_BASE_DIR_ROOT="/"

# Some callers (for example, orchestration tools that pass shell arguments
# through an extra layer of quoting) may pass HIVE_DB wrapped in literal
# double quotes. Strip them here so a value like "\"sales\"" is treated as
# "sales".
HIVE_DB="${HIVE_DB#\"}"
HIVE_DB="${HIVE_DB%\"}"

# ------------------------------------------------------------------------------
#  Resolve FAILOVER_MODE into REPLICATION_DIRECTION.
#
#  REPLICATION_DIRECTION is the internal value that actually drives the
#  script: "src_to_dst" (REPL DUMP on SRC, REPL LOAD on DST) or
#  "dst_to_src" (REPL DUMP on DST, REPL LOAD on SRC). It can also be set
#  directly via the REPLICATION_DIRECTION environment variable if you
#  prefer that over FAILOVER_MODE true/false; if both are set,
#  REPLICATION_DIRECTION wins.
# ------------------------------------------------------------------------------
REPLICATION_DIRECTION="${REPLICATION_DIRECTION:-}"

if [[ -z "$REPLICATION_DIRECTION" ]]; then
  if [[ "${FAILOVER_MODE,,}" == "true" ]]; then
    REPLICATION_DIRECTION="dst_to_src"
  else
    REPLICATION_DIRECTION="src_to_dst"
  fi
fi
case "${REPLICATION_DIRECTION,,}" in
  src_to_dst|dst_to_src) REPLICATION_DIRECTION="${REPLICATION_DIRECTION,,}" ;;
  *)
    echo "[ERROR] REPLICATION_DIRECTION must be 'src_to_dst' or 'dst_to_src' (got: '${REPLICATION_DIRECTION}')" >&2
    exit 1
    ;;
esac

# Directory used for per-database lock files that prevent two incremental
# replication cycles for the same database from running at the same time.
INCREMENTAL_LOCK_DIR="${INCREMENTAL_LOCK_DIR:-/var/tmp/hive-bdr-incremental-locks}"

# ------------------------------------------------------------------------------
#  HIVE_REPL_SNAPSHOT_COPY - enable HDFS snapshot-diff based copying for
#  external table data (recommended for large external tables). See the
#  "ENVIRONMENT VARIABLES" section at the top of this file for details.
# ------------------------------------------------------------------------------
HIVE_REPL_SNAPSHOT_COPY="${HIVE_REPL_SNAPSHOT_COPY:-false}"

# Snapshot-diff copy is not currently supported together with a reversed
# replication direction. If both are requested, disable snapshot-diff copy
# for this run rather than proceeding with an unsupported combination.
if [[ "$REPLICATION_DIRECTION" == "dst_to_src" && "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
  echo "[WARN] REPLICATION_DIRECTION=dst_to_src - forcing HIVE_REPL_SNAPSHOT_COPY=false (not supported together with a reversed direction)"
  HIVE_REPL_SNAPSHOT_COPY="false"
fi

# Directory used for lock files that record which external table
# directories have already been made snapshot-capable. Only used when
# HIVE_REPL_SNAPSHOT_COPY=true.
SNAP_LOCK_DIR="${SNAP_LOCK_DIR:-/var/tmp/hive-bdr-snapshot-setup-locks}"

# Base directory the source cluster uses for external tables that have no
# explicit LOCATION. Only used to compute the source-side path that needs
# snapshot capability when HIVE_REPL_SNAPSHOT_COPY=true. Override this if
# your source cluster's hive.metastore.warehouse.external.dir is not the
# Hive 3 default below.
HIVE_EXTERNAL_WAREHOUSE_DIR="${HIVE_EXTERNAL_WAREHOUSE_DIR:-/warehouse/tablespace/external/hive}"

# ------------------------------------------------------------------------------
#  YARN_QUEUE - the YARN queue used for REPL LOAD's internal data-copy job.
#  Applied via two `SET` statements issued immediately before every
#  REPL LOAD statement (see beeline_exec_load() below):
#    SET mapreduce.job.queuename=<YARN_QUEUE>;
#    SET tez.queue.name=<YARN_QUEUE>;
#  Both are set together because HiveServer2 may execute the query itself
#  on Tez while the data-copy task runs as a separate MapReduce/DistCp job.
#  Only affects REPL LOAD - REPL DUMP does not launch a YARN job.
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
#  HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS - replicate materialized views
#  along with regular tables. Disabled by default: a replicated
#  materialized view is copied as a static snapshot and is not
#  automatically rebuilt on the destination, so it can silently drift out
#  of sync with its base tables. Enable only if you have confirmed that
#  behavior is acceptable.
# ------------------------------------------------------------------------------
HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS="${HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS:-false}"

# Ensure REPL_BASE_DIR always ends with exactly one trailing slash.
REPL_BASE_DIR="${REPL_BASE_DIR%/}/"

# Ensure REPL_EXTERNAL_BASE_DIR_ROOT always has exactly one leading and one
# trailing slash.
REPL_EXTERNAL_BASE_DIR_ROOT="/${REPL_EXTERNAL_BASE_DIR_ROOT#/}"
REPL_EXTERNAL_BASE_DIR_ROOT="${REPL_EXTERNAL_BASE_DIR_ROOT%/}/"

# ------------------------------------------------------------------------------
#  Validate required arguments before doing anything else.
# ------------------------------------------------------------------------------
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

# parse_db_specs: split the HIVE_DB argument on "|", but only outside of
# single-quoted sections, and populate the global DB_SPECS array with one
# entry per database spec.
#
# This lets a table pattern like "sales.'(orders|customers)'" keep its "|"
# intact (it is part of the regex), while still treating the "|" in
# "sales|analytics" as a separator between two different databases.
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

# compute_repl_external_base_dir: compute REPL_EXTERNAL_BASE_DIR, the
# destination-side base directory Hive relocates replicated external
# table data under (hive.repl.replica.external.table.base.dir).
#
# Hive prefixes the source table's own path onto this base directory when
# copying external table data to the destination, so this value must be a
# separate relocation root - not the same path shape as the source
# cluster's real external warehouse directory (doing so produces a
# doubled/nested destination path and causes REPL LOAD to fail).
#
# This must always be rooted at whichever nameservice is the actual
# REPL LOAD target for the current run (the "load_target_nameservice"
# argument, computed by derive_db_vars() from REPLICATION_DIRECTION).
#
# With REPL_EXTERNAL_BASE_DIR_APPEND_DB=false (the fixed value set at the
# top of this script) and REPL_EXTERNAL_BASE_DIR_ROOT="/", the destination
# external table path ends up identical to the source path except for the
# nameservice/host - for example, source hdfs://src-ns/warehouse/sales.db/orders
# becomes hdfs://dst-ns/warehouse/sales.db/orders on the destination.
compute_repl_external_base_dir() {
  local load_target_nameservice="$1"
  if [[ "${REPL_EXTERNAL_BASE_DIR_APPEND_DB,,}" == "false" ]]; then
    REPL_EXTERNAL_BASE_DIR="hdfs://${load_target_nameservice}${REPL_EXTERNAL_BASE_DIR_ROOT}"
  else
    REPL_EXTERNAL_BASE_DIR="hdfs://${load_target_nameservice}${REPL_EXTERNAL_BASE_DIR_ROOT}${HIVE_DB_NAME}"
  fi
}

# derive_db_vars: compute every per-database variable used by the rest of
# this script, from a single database spec string. Called once at the
# start of processing each database so every function that follows always
# sees fresh, correct values for that database.
#
# SRC_NAMESERVICE/DST_NAMESERVICE/SRC_JDBC_URL/DST_JDBC_URL are fixed
# labels for the two clusters (see "FAILOVER AND FAILBACK" at the top of
# this file) and are never swapped. This function derives which cluster is
# actually the DUMP source and which is the LOAD target for the CURRENT
# run, based on REPLICATION_DIRECTION.
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

  if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
    DUMP_NAMESERVICE="$DST_NAMESERVICE"
    LOAD_NAMESERVICE="$SRC_NAMESERVICE"
    DUMP_JDBC_URL="$DST_JDBC_URL"
    LOAD_JDBC_URL="$SRC_JDBC_URL"
  else
    DUMP_NAMESERVICE="$SRC_NAMESERVICE"
    LOAD_NAMESERVICE="$DST_NAMESERVICE"
    DUMP_JDBC_URL="$SRC_JDBC_URL"
    LOAD_JDBC_URL="$DST_JDBC_URL"
  fi

  # The REPL DUMP staging directory is suffixed with the dump-side
  # nameservice (for example .../repl/sales/from_prod-nameservice), so
  # each direction has its own independent, persistent staging path. This
  # keeps repeated failover/failback cycles from ever reusing (and
  # colliding with) a staging directory left over from the opposite
  # direction. The path is stable and reused across repeated runs in the
  # SAME direction - only a direction change moves to a different path.
  REPL_ROOT_DIR_SRC="hdfs://${DUMP_NAMESERVICE}${REPL_BASE_DIR}${HIVE_DB_NAME}/from_${DUMP_NAMESERVICE}"
  # REPL LOAD must read from the exact same location REPL DUMP wrote to.
  REPL_ROOT_DIR_DST="${REPL_ROOT_DIR_SRC}"

  # Base directory on the LOAD target for replicated external table data,
  # rooted at whichever nameservice is actually being loaded onto in this
  # run.
  compute_repl_external_base_dir "$LOAD_NAMESERVICE"
  # Note: only tables using Hive's default external table location are
  # covered by the automatic snapshot setup in
  # enable_external_table_snapshots() below. A table created with an
  # explicit, non-default LOCATION needs its own snapshot setup outside
  # this script.
}

declare -a DB_SPECS=()
parse_db_specs "$HIVE_DB"

# HA is assumed to be enabled when neither nameservice argument contains a
# ":" (a "host:port" value implies a single, non-HA NameNode instead of an
# HA nameservice name).
if [[ "$SRC_NAMESERVICE" != *:* ]] && [[ "$DST_NAMESERVICE" != *:* ]]; then
  HA_ENABLED=true
else
  HA_ENABLED=false
fi

# When both clusters are HA, exclude both nameservices from HDFS delegation
# token renewal for the MapReduce/DistCp job REPL LOAD launches internally
# (avoids a cross-cluster token-renewal failure for jobs that run entirely
# within a single, already-authenticated session).
if [[ "$HA_ENABLED" == true ]]; then
  HDFS_TOKEN_EXCLUDE_PROP="'mapreduce.job.hdfs-servers.token-renewal.exclude'='${SRC_NAMESERVICE},${DST_NAMESERVICE}',"
else
  HDFS_TOKEN_EXCLUDE_PROP=""
fi

# ------------------------------------------------------------------------------
#  HA_CONFIG_IN_WITH_CLAUSE - inject HA NameNode configuration directly
#  into REPL DUMP/LOAD statements.
#
#  Normally, an HA nameservice must already be resolvable to HiveServer2
#  through the cluster's own hdfs-site.xml, configured once cluster-wide.
#  Set HA_CONFIG_IN_WITH_CLAUSE=true to have this script inject the same
#  properties directly into every REPL DUMP/LOAD statement instead - useful
#  when one cluster's hdfs-site.xml does not yet know about the other
#  cluster's nameservice. Requires SRC_NN_HOSTS and DST_NN_HOSTS.
# ------------------------------------------------------------------------------
HA_CONFIG_IN_WITH_CLAUSE="${HA_CONFIG_IN_WITH_CLAUSE:-false}"

# SRC_NN_HOSTS / DST_NN_HOSTS - required when HA_CONFIG_IN_WITH_CLAUSE=true.
# Comma-separated "<nn-id>=<host>:<port>" pairs describing each
# nameservice's NameNodes, for example:
#   SRC_NN_HOSTS="nn1=prod-nn1.example.com:8020,nn2=prod-nn2.example.com:8020"
#   DST_NN_HOSTS="nn1=dr-nn1.example.com:8020,nn2=dr-nn2.example.com:8020"
SRC_NN_HOSTS="${SRC_NN_HOSTS:-}"
DST_NN_HOSTS="${DST_NN_HOSTS:-}"

# AUTOMATIC_FAILOVER_ENABLED - only used when HA_CONFIG_IN_WITH_CLAUSE=true.
AUTOMATIC_FAILOVER_ENABLED="${AUTOMATIC_FAILOVER_ENABLED:-true}"

if [[ "${HA_CONFIG_IN_WITH_CLAUSE,,}" == "true" ]]; then
  if [[ -z "$SRC_NN_HOSTS" || -z "$DST_NN_HOSTS" ]]; then
    echo "[ERROR] HA_CONFIG_IN_WITH_CLAUSE=true requires both SRC_NN_HOSTS and DST_NN_HOSTS to be set." >&2
    echo "[ERROR] Example: SRC_NN_HOSTS=\"nn1=host1:8020,nn2=host2:8020\"" >&2
    exit 1
  fi
fi

# build_nameservice_ha_props: print the dfs.ha.namenodes.<ns>,
# dfs.namenode.rpc-address.<ns>.<nn-id>, and
# dfs.client.failover.proxy.provider.<ns> properties for one nameservice
# (each line ending in a comma, ready to splice into a REPL DUMP/LOAD
# WITH() clause).
# Usage: build_nameservice_ha_props <nameservice> <nn_hosts_spec>
build_nameservice_ha_props() {
  local nameservice="$1"
  local nn_hosts_spec="$2"
  local nn_ids=()
  local pair nn_id nn_addr

  IFS=',' read -ra pairs <<< "$nn_hosts_spec"
  for pair in "${pairs[@]}"; do
    nn_id="${pair%%=*}"
    nn_addr="${pair#*=}"
    if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_id" == "$pair" ]]; then
      echo "[ERROR] Malformed NN host entry for nameservice '${nameservice}': '${pair}' (expected <nn-id>=<host>:<port>)" >&2
      exit 1
    fi
    nn_ids+=("$nn_id")
    printf "'dfs.namenode.rpc-address.%s.%s'='%s',\n" "$nameservice" "$nn_id" "$nn_addr"
  done

  local joined_ids
  joined_ids="$(IFS=,; echo "${nn_ids[*]}")"
  printf "'dfs.ha.namenodes.%s'='%s',\n" "$nameservice" "$joined_ids"
  printf "'dfs.client.failover.proxy.provider.%s'='org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider',\n" "$nameservice"
}

# ha_config_props: print the full HA property block for both clusters
# (each line ending in a comma, ready to splice into a REPL DUMP/LOAD
# WITH() clause) when HA_CONFIG_IN_WITH_CLAUSE=true. Prints nothing when
# false (the default), since HA resolution is then assumed to already be
# configured cluster-wide.
ha_config_props() {
  if [[ "${HA_CONFIG_IN_WITH_CLAUSE,,}" != "true" ]]; then
    return
  fi
  printf "'dfs.nameservices'='%s,%s',\n" "$SRC_NAMESERVICE" "$DST_NAMESERVICE"
  printf "'dfs.ha.automatic-failover.enabled'='%s',\n" "${AUTOMATIC_FAILOVER_ENABLED,,}"
  build_nameservice_ha_props "$SRC_NAMESERVICE" "$SRC_NN_HOSTS"
  build_nameservice_ha_props "$DST_NAMESERVICE" "$DST_NN_HOSTS"
}

# ------------------------------------------------------------------------------
#  Kerberos detection.
#
#  Locates a valid Kerberos credential cache (KRB5CCNAME) so beeline/hdfs
#  commands authenticate with the active ticket instead of falling back to
#  sudo. Checks, in order: an already-set KRB5CCNAME, a cache created by
#  Acceldata Pulse Actions, the default per-user cache under /tmp, and
#  finally the default klist cache.
#
#  Returns 0 (Kerberos available) or 1 (Kerberos not available - the
#  script falls back to sudo-based execution).
# ------------------------------------------------------------------------------
detect_and_set_kerberos_cache() {
    if ! command -v klist >/dev/null 2>&1; then
        return 1
    fi
    # 1) If KRB5CCNAME is already set (e.g. passed in from the calling
    #    environment), trust it but verify it is actually valid first.
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
    # 4) Final fallback: default klist cache
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

# ------------------------------------------------------------------------------
#  Beeline authentication.
#
#  When Kerberos is not available, beeline needs an explicit "-n <user>"
#  or HiveServer2 authenticates the session as "anonymous". Two modes are
#  supported, controlled by HIVE_LDAP_ENABLED:
#
#    HIVE_LDAP_ENABLED=false (default)
#      HiveServer2 is using pass-through/NONE authentication - the
#      password value is not actually checked. The script passes
#      "-n $HIVE_USER -p $HIVE_USER" (the username doubling as the
#      password) purely to satisfy beeline's syntax.
#
#    HIVE_LDAP_ENABLED=true
#      HiveServer2 is backed by real LDAP authentication - the password IS
#      checked. HIVE_PASSWORD must be set to the actual LDAP password; the
#      script exits with an error if it is missing.
#
#  When Kerberos IS available, none of this is used - beeline authenticates
#  via the active Kerberos ticket and no "-n"/"-p" flags are passed.
# ------------------------------------------------------------------------------
HIVE_LDAP_ENABLED="${HIVE_LDAP_ENABLED:-false}"
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

# ------------------------------------------------------------------------------
#  Long-running-command watchdog.
#
#  beeline gives no progress output at all while a statement executes
#  server-side (e.g. REPL DUMP/LOAD's internal metadata and data-copy
#  work), so a slow-but-healthy run and a truly stuck run look identical
#  in this script's log. run_with_heartbeat() runs a command in the
#  background and, every HEARTBEAT_INTERVAL_SECONDS, prints an
#  "still running" message with the elapsed time - so the log always
#  shows forward progress instead of going silent.
#
#  If BEELINE_COMMAND_TIMEOUT_SECONDS is set to a positive number, the
#  command is killed after that many seconds and a clear timeout message
#  is printed with troubleshooting pointers. Default (0) means no timeout
#  - only the heartbeat is active, and the command runs to completion.
# ------------------------------------------------------------------------------
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-30}"
BEELINE_COMMAND_TIMEOUT_SECONDS="${BEELINE_COMMAND_TIMEOUT_SECONDS:-0}"

# BEELINE_VERBOSE - "true" or "false". When "true", every beeline
# invocation adds "--verbose=true", which prints each statement beeline
# sends to HiveServer2 (in addition to the statements this script already
# echoes itself) and more detail on the JDBC connection/session setup.
# Useful while diagnosing a hang or an unexpected failure. Left off by
# default to keep normal runs less noisy.
BEELINE_VERBOSE="${BEELINE_VERBOSE:-false}"
declare -a BEELINE_VERBOSE_ARGS=()
if [[ "${BEELINE_VERBOSE,,}" == "true" ]]; then
  BEELINE_VERBOSE_ARGS=(--verbose=true)
fi

# run_with_heartbeat: run "$@" as a child process, printing a heartbeat
# line every HEARTBEAT_INTERVAL_SECONDS until it exits. Optionally enforces
# BEELINE_COMMAND_TIMEOUT_SECONDS. Preserves and returns the child's exit
# code.
# Usage: run_with_heartbeat <label> <command> [args...]
run_with_heartbeat() {
  local label="$1"
  shift

  "$@" &
  local cmd_pid=$!

  local elapsed=0
  while kill -0 "$cmd_pid" 2>/dev/null; do
    sleep "$HEARTBEAT_INTERVAL_SECONDS"
    elapsed=$(( elapsed + HEARTBEAT_INTERVAL_SECONDS ))

    if kill -0 "$cmd_pid" 2>/dev/null; then
      echo "[HEARTBEAT] ${label} still running - elapsed ${elapsed}s (pid ${cmd_pid})" >&${HEARTBEAT_FD}

      if [[ "$BEELINE_COMMAND_TIMEOUT_SECONDS" -gt 0 && "$elapsed" -ge "$BEELINE_COMMAND_TIMEOUT_SECONDS" ]]; then
        {
          echo "[ERROR] ${label} exceeded BEELINE_COMMAND_TIMEOUT_SECONDS=${BEELINE_COMMAND_TIMEOUT_SECONDS}s - killing pid ${cmd_pid}"
          echo "[ERROR] This usually means the statement is blocked server-side (metastore lock, a stuck"
          echo "[ERROR] MapReduce/Tez data-copy job, or an unreachable remote cluster) rather than genuinely"
          echo "[ERROR] still working. On the cluster ${label} is targeting, check:"
          echo "[ERROR]   - SHOW LOCKS DATABASE ${HIVE_DB_NAME:-<db>};"
          echo "[ERROR]   - yarn application -list  (look for a running data-copy job in queue '${YARN_QUEUE}')"
          echo "[ERROR]   - HiveServer2 logs for the queryId last printed above"
        } >&${HEARTBEAT_FD}
        kill -9 "$cmd_pid" 2>/dev/null
        wait "$cmd_pid" 2>/dev/null
        return 124
      fi
    fi
  done

  wait "$cmd_pid"
  return $?
}

# beeline_exec: run beeline against a given JDBC URL with the correct
# authentication arguments applied automatically. Wrapped in
# run_with_heartbeat() so a slow or stuck statement is visible in the log
# instead of producing silence.
# Usage: beeline_exec <jdbc_url> [beeline args...]
beeline_exec() {
    local jdbc_url="$1"
    shift
    run_with_heartbeat "beeline_exec (${jdbc_url})" \
        beeline -u "$jdbc_url" "${BEELINE_AUTH_ARGS[@]}" "${BEELINE_VERBOSE_ARGS[@]}" "$@"
}

# beeline_exec_load: same as beeline_exec, but first issues the two YARN
# queue `SET` statements (in the same beeline session, before the caller's
# statement) so REPL LOAD's internal data-copy job submits to YARN_QUEUE.
# Only use this for REPL LOAD calls - REPL DUMP does not launch a YARN job,
# so setting the queue has no effect there.
# Usage: beeline_exec_load <jdbc_url> -e "<REPL LOAD ...>"
beeline_exec_load() {
    local jdbc_url="$1"
    shift
    run_with_heartbeat "beeline_exec_load (${jdbc_url})" \
        beeline -u "$jdbc_url" "${BEELINE_AUTH_ARGS[@]}" "${BEELINE_VERBOSE_ARGS[@]}" \
            -e "SET mapreduce.job.queuename=${YARN_QUEUE};" \
            -e "SET tez.queue.name=${YARN_QUEUE};" \
            "$@"
}

# repl_status_last_id: run "REPL STATUS <db>" against the given JDBC URL
# and print its last_repl_id value. This is empty/NULL if the database has
# never been the target of a REPL LOAD on that cluster (i.e. it has never
# acted as a replica). Returns 1 if the query itself fails - for example,
# if the database does not exist yet on that cluster, or the cluster is
# unreachable.
repl_status_last_id() {
  local jdbc_url="$1"
  local db="$2"
  local output
  output=$(beeline_exec "${jdbc_url}" -e "REPL STATUS ${db};" 2>&1) || return 1
  # beeline prints results as a bordered ASCII table, e.g.:
  #   +--------------+---------------+
  #   |  dump_dir    | last_repl_id  |
  #   +--------------+---------------+
  #   | hdfs://...   | 10884         |
  #   +--------------+---------------+
  # last_repl_id is the LAST "|"-delimited column of the one data row
  # (the row that is not the header/border). Extract it directly rather
  # than filtering by shape, since the surrounding connection/session
  # chatter never matches this table format.
  echo "$output" | awk -F'|' '
    /^\| *[Hh]dfs:\/\// || /^\| *[Nn][Uu][Ll][Ll] *\|/ || /^\|.*\|.*[0-9].*\|/ {
      n = NF
      val = $(n-1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val != "" && val !~ /^-+$/) { print val; exit }
    }
  '
}

# preflight_check_direction_change: before reversing replication direction
# (a DUMP with 'hive.repl.failover.start'='true'), confirm that Hive's own
# metastore already considers the CURRENT replica (the side about to
# become the new dump source's replica... no - about to become the new
# LOAD target) a caught-up replica, i.e. it has a non-NULL last_repl_id
# from a previous successful REPL LOAD in the current direction.
#
# This check must be run against the current LOAD side (LOAD_NAMESERVICE),
# not the current DUMP side: Hive only records last_repl_id on the side
# that gets loaded into, never on the dump/source side. Checking the wrong
# side would always report "not caught up" even when replication is
# healthy.
#
# Only called from failover_one_db(), i.e. only when the caller explicitly
# requested a direction change for this invocation.
preflight_check_direction_change() {
  local current_replica_jdbc="$1"
  local current_replica_ns="$2"

  echo "$SUBSEP"
  echo "Pre-flight: verifying ${current_replica_ns} is a caught-up replica before reversing direction..."

  local last_id
  if ! last_id="$(repl_status_last_id "$current_replica_jdbc" "$HIVE_DB_NAME")"; then
    echo "ERROR: Could not query REPL STATUS ${HIVE_DB_NAME} on ${current_replica_ns} - aborting direction change rather than risk an invalid failover-start DUMP."
    echo "This usually means the database does not exist yet on ${current_replica_ns}, or that cluster is unreachable."
    return 1
  fi

  if [[ -z "$last_id" || "${last_id^^}" == "NULL" ]]; then
    echo "ERROR: ${current_replica_ns} has no recorded last_repl_id for '${HIVE_DB_NAME}' - Hive does not consider it a"
    echo "       caught-up replica, so a direction reversal is not yet safe."
    echo "       Ensure at least one successful REPL LOAD has completed onto ${current_replica_ns} in the CURRENT"
    echo "       direction before requesting a reversal."
    return 1
  fi

  echo "OK: ${current_replica_ns} last_repl_id=${last_id} - safe to reverse direction (it becomes the new replica)."
  echo ""
  return 0
}

# run_as_hdfs: run an `hdfs dfs` / `hdfs dfsadmin` command as the
# appropriate user. When Kerberos is available, runs as the current user
# (preserving the active ticket). Otherwise, runs via `sudo -u $HDFS_USER`
# (preserving the environment with -E, so variables like
# HADOOP_CLIENT_OPTS still apply).
run_as_hdfs() {
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        "$@"
    else
        sudo -E -u "$HDFS_USER" "$@"
    fi
}

# allow_snapshot_idempotent: run `hdfs dfsadmin -allowSnapshot <dir>` and
# treat "directory is already snapshottable" as success (not an error).
# Returns 0 on success (including already-enabled), 1 on failure.
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

# enable_external_table_snapshots: make the current database's external
# table warehouse directory on the dump source snapshot-capable, which is
# a prerequisite for HIVE_REPL_SNAPSHOT_COPY=true. Idempotent - uses a
# per-database, per-dump-source lock file so this setup only runs once,
# not on every invocation. Only called when HIVE_REPL_SNAPSHOT_COPY=true.
#
# Usage: enable_external_table_snapshots [dump_source_nameservice]
#   dump_source_nameservice defaults to SRC_NAMESERVICE (the normal
#   bootstrap/incremental case). Callers in failover_one_db() pass the
#   actual current dump-side nameservice explicitly, since a reversed
#   direction means DST_NAMESERVICE is the one actually running REPL DUMP.
#
# Note: this does NOT enable snapshots on REPL_EXTERNAL_BASE_DIR (the
# destination relocation root) - HDFS does not allow a directory to become
# snapshottable if an ancestor directory already is snapshottable, and
# Hive's own data-copy task enables snapshots on the correct nested
# destination path itself, at copy time. Pre-enabling the parent directory
# here would block that and cause REPL LOAD to fail.
enable_external_table_snapshots() {
  local dump_source_ns="${1:-$SRC_NAMESERVICE}"
  local dump_source_path="hdfs://${dump_source_ns}${HIVE_EXTERNAL_WAREHOUSE_DIR}/${HIVE_DB_NAME}.db"

  mkdir -p "$SNAP_LOCK_DIR" 2>/dev/null || true
  # The lock is keyed by database + dump-source nameservice (not just the
  # database), because a failover flips which cluster is the real dump
  # source, and each side needs its own independent setup/check.
  local lock_file="${SNAP_LOCK_DIR}/${HIVE_DB_NAME}__${dump_source_ns}.lock"

  if [[ -f "$lock_file" ]]; then
    echo "[DEBUG] External table snapshot capability already enabled for ${HIVE_DB_NAME} on dump source ${dump_source_ns} (lock present: ${lock_file})"
    return 0
  fi

  echo "$SUBSEP"
  echo "Enabling HDFS snapshot capability for external-table snapshot-diff copy (dump source: ${dump_source_ns})..."
  local src_ok=false
  local src_path="${dump_source_path/hdfs:\/\/${dump_source_ns}/}"
  # REPL_EXTERNAL_BASE_DIR's own nameservice is whichever cluster is the
  # actual LOAD target for the current direction. Parse it out of the
  # value itself, rather than assuming a fixed nameservice, so this
  # continues to work correctly regardless of replication direction.
  local base_dir_ns="${REPL_EXTERNAL_BASE_DIR#hdfs://}"
  base_dir_ns="${base_dir_ns%%/*}"
  local dst_path="${REPL_EXTERNAL_BASE_DIR#hdfs://${base_dir_ns}}"

  if run_as_hdfs hdfs dfs -fs "hdfs://${dump_source_ns}" -test -d "$src_path"; then
    allow_snapshot_idempotent "$dump_source_ns" "$src_path" "DUMP SOURCE (${dump_source_ns})" && src_ok=true
  else
    echo "[WARN] Dump-source external warehouse dir does not exist yet, skipping allowSnapshot: ${dump_source_path}"
    echo "[WARN] It will be created by Hive on first external table creation; snapshot will be retried on next run."
  fi

  # Ensure the destination relocation root exists (its snapshot capability
  # is handled separately by Hive itself at copy time - see the function
  # comment above).
  run_as_hdfs hdfs dfs -fs "hdfs://${base_dir_ns}" -mkdir -p "$dst_path" || true

  if [[ "$src_ok" == "true" ]]; then
    : >"$lock_file"
    echo "Snapshot capability enabled for ${HIVE_DB_NAME} external tables on dump source ${dump_source_ns} (lock: ${lock_file})"
  else
    echo "[WARN] Snapshot capability not fully enabled for ${HIVE_DB_NAME} on dump source ${dump_source_ns} - will retry on next invocation."
  fi
  echo ""
}

# snapshot_copy_props: print the extra WITH-clause properties (each line
# ending in a comma) that enable HDFS snapshot-diff based copying for
# external tables, when HIVE_REPL_SNAPSHOT_COPY=true. Prints nothing when
# false.
snapshot_copy_props() {
  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    printf "%s\n" \
      "'hive.repl.externaltable.snapshotdiff.copy'='true'," \
      "'hive.repl.external.warehouse.single.copy.task'='true'," \
      "'hive.repl.externaltable.snapshot.overwrite.target'='true',"
  fi
}

# materialized_view_props: print the extra WITH-clause property (ending
# in a comma) that includes materialized views in DUMP/LOAD, when
# HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS=true. Prints nothing when false
# (the default).
materialized_view_props() {
  if [[ "${HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS,,}" == "true" ]]; then
    printf "%s\n" "'hive.repl.include.materialized.views'='true',"
  fi
}

# Step counters used purely for the progress messages printed to the log
# (e.g. "[2/5] Running REPL DUMP..."). TOTAL_STEPS covers a normal
# replication run (replicate_one_db); FAILOVER_TOTAL_STEPS covers a
# direction-change run (failover_one_db).
TOTAL_STEPS=5
FAILOVER_TOTAL_STEPS=3

# failover_one_db: reverse the replication direction for a single
# database. Performs 3 steps:
#   Step 1 - Pre-flight check: confirm the new dump side is an eligible
#            replication source (see preflight_check_direction_change()).
#   Step 2 - REPL DUMP on the new primary, with
#            'hive.repl.failover.start'='true'.
#   Step 3 - REPL LOAD on the new replica.
#
# All of DUMP_NAMESERVICE / LOAD_NAMESERVICE / DUMP_JDBC_URL /
# LOAD_JDBC_URL / REPL_ROOT_DIR_* / REPL_EXTERNAL_BASE_DIR are already
# computed correctly for the current REPLICATION_DIRECTION by
# derive_db_vars() before this function is called.
failover_one_db() {
  local db_spec="$1"
  local db_index="$2"
  local db_total="$3"

  derive_db_vars "$db_spec"

  LOG_FILE="$LOG_DIR/hive_bdr_direction_change_${HIVE_DB_NAME}_$(date +%Y%m%d_%H%M%S).log"

  SEP="======================================================================"
  SUBSEP="----------------------------------------------------------------------"

  echo "$SEP"
  echo " Hive Direction-Change Replication - DB ${db_index}/${db_total}: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo "Timestamp        : $(date)"
  echo "Database         : $HIVE_DB_NAME"
  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    echo "Tables           : $HIVE_TABLE_PATTERN"
  fi
  echo "Direction        : $REPLICATION_DIRECTION"
  echo "New primary      : $DUMP_NAMESERVICE (writes here)"
  echo "New replica      : $LOAD_NAMESERVICE (receives replication)"
  echo "Log File         : $LOG_FILE"
  echo ""

  ########################################
  # Step 1: Pre-flight check
  ########################################
  echo "$SUBSEP"
  echo "[1/${FAILOVER_TOTAL_STEPS}] Pre-flight check..."
  if ! preflight_check_direction_change "$LOAD_JDBC_URL" "$LOAD_NAMESERVICE"; then
    echo "ERROR: Aborting direction change for ${HIVE_DB_NAME} - see pre-flight error above"
    return 1
  fi

  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    # Prepare both sides for snapshot-diff copy: the new dump source
    # (must be passed explicitly here, since it is not necessarily
    # SRC_NAMESERVICE once the direction has reversed) and the new load
    # target (harmless no-op if a previous cycle already prepared it).
    enable_external_table_snapshots "$DUMP_NAMESERVICE"
    enable_external_table_snapshots "$LOAD_NAMESERVICE"
  fi

  ########################################
  # Step 2: REPL DUMP with failover.start=true on the new primary
  ########################################
  echo "$SUBSEP"
  echo "[2/${FAILOVER_TOTAL_STEPS}] Running failover-start REPL DUMP on new primary (${DUMP_NAMESERVICE})..."

  local FAILOVER_DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
'hive.repl.failover.start'='true',
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${DUMP_NAMESERVICE}: ${FAILOVER_DUMP_CMD}"
  echo ""
  if ! beeline_exec "${DUMP_JDBC_URL}" -e "${FAILOVER_DUMP_CMD}"; then
    echo "ERROR: Failover REPL DUMP failed on ${DUMP_NAMESERVICE} for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  ########################################
  # Step 3: REPL LOAD on the new replica
  # (No separate DistCp step is needed - the staging directory lives on
  # the dump-side nameservice, which is reachable from both clusters, and
  # REPL LOAD copies data itself.)
  ########################################
  echo "$SUBSEP"
  echo "[3/${FAILOVER_TOTAL_STEPS}] Running failover REPL LOAD on new replica (${LOAD_NAMESERVICE})..."

  local FAILOVER_LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.run.data.copy.tasks.on.target'='true',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${LOAD_NAMESERVICE}: ${FAILOVER_LOAD_CMD}"
  echo ""
  if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "${FAILOVER_LOAD_CMD}"; then
    echo "ERROR: Failover REPL LOAD failed on ${LOAD_NAMESERVICE} for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  echo "Validating replication status on new replica (${LOAD_NAMESERVICE})..."
  beeline_exec "${LOAD_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - failover DUMP/LOAD already succeeded)"
  echo ""

  echo "$SEP"
  echo " Failover Replication Completed: ${HIVE_DB_NAME}"
  echo "$SEP"
  echo ""
  echo "Database         : $HIVE_DB_NAME"
  echo "New primary      : $DUMP_NAMESERVICE (writes here)"
  echo "New replica      : $LOAD_NAMESERVICE (receives replication)"
  echo "YARN Queue       : $YARN_QUEUE (REPL LOAD data-copy jobs)"
  echo ""
  echo "Completed        : $(date)"
  echo "Log File         : $LOG_FILE"
  echo ""
  echo "$SEP"
  echo ""
}

# run_incremental_cycle: run one incremental REPL DUMP -> REPL LOAD cycle
# for the current database (HIVE_DB_NAME / HIVE_REPL_SPEC, set by
# derive_db_vars()). Called by replicate_one_db() when the destination
# database already exists. Hive's own replication state (repl.last.id)
# ensures each DUMP only contains events since the last successful DUMP,
# so only the changes are transferred.
run_incremental_cycle() {
  echo "$SUBSEP"
  echo "[3-4/${TOTAL_STEPS}] Running incremental replication cycle..."
  echo ""

  # Prevent two incremental cycles for the same database from running at
  # the same time (for example, if this script is re-invoked before a
  # previous run has finished).
  mkdir -p "$INCREMENTAL_LOCK_DIR" 2>/dev/null || true
  local lock_file="${INCREMENTAL_LOCK_DIR}/${HIVE_DB_NAME}.lock"
  exec {lock_fd}>"$lock_file"
  if ! flock -n "$lock_fd"; then
    echo "WARN: Another incremental cycle for '${HIVE_DB_NAME}' appears to be in progress (lock: ${lock_file})."
    echo "Skipping this cycle to avoid concurrent REPL DUMP/LOAD against the same DB."
    exec {lock_fd}>&-
    return 0
  fi
  # Release the lock on any exit from this function - normal completion,
  # an explicit return, or set -e propagating a beeline failure.
  trap 'flock -u "$lock_fd" 2>/dev/null; exec {lock_fd}>&- 2>/dev/null; trap - RETURN' RETURN

  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    enable_external_table_snapshots "$DUMP_NAMESERVICE"
  fi

  echo "$SUBSEP"
  echo "Running incremental REPL DUMP on dump source (${DUMP_NAMESERVICE}, direction: ${REPLICATION_DIRECTION})..."

  local incr_dump_cmd="REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
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
  if ! beeline_exec "${DUMP_JDBC_URL}" -e "$incr_dump_cmd"; then
    echo "ERROR: Incremental REPL DUMP failed for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  echo "$SUBSEP"
  echo "Running incremental REPL LOAD on load target (${LOAD_NAMESERVICE})..."

  local incr_load_cmd="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
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
  if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "$incr_load_cmd"; then
    echo "ERROR: Incremental REPL LOAD failed for ${HIVE_DB_NAME}"
    return 1
  fi
  echo ""

  echo "$SUBSEP"
  echo "Validating replication status on load target..."
  beeline_exec "${LOAD_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - incremental DUMP/LOAD already succeeded)"
  echo ""

  echo "Incremental cycle completed for ${HIVE_DB_NAME}"
  echo ""
}

# check_all_tables_external: query the dump source and fail (return 1) if the
# current database/table pattern (HIVE_DB_NAME / HIVE_TABLE_PATTERN, set by
# derive_db_vars) contains any table that is NOT EXTERNAL_TABLE. Only called
# when RECONCILE_EXTERNAL_DATA=true - that mode disables REPL LOAD's own
# bootstrap data copy in favor of a manual per-table distcp, which is only a
# safe substitute for external-table data (plain files under a LOCATION).
# Managed/ACID table data has no equivalent manual-reconciliation step, so
# this check runs BEFORE REPL DUMP/LOAD is issued at all, rather than
# discovering a managed table mid-bootstrap with data copy already disabled
# for the whole database.
check_all_tables_external() {
  local jdbc_url="$1"

  local tables_output
  tables_output=$(beeline_exec "${jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "USE ${HIVE_DB_NAME}; SHOW TABLES;" 2>&1) || {
    echo "ERROR: Could not list tables in '${HIVE_DB_NAME}' on dump source to verify they are all external"
    return 1
  }

  local tables
  tables=$(echo "$tables_output" | grep -E "^[A-Za-z0-9_]+$")

  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    tables=$(echo "$tables" | grep -E "^${HIVE_TABLE_PATTERN}$" || true)
  fi

  if [[ -z "$tables" ]]; then
    echo "[WARN] No tables found in '${HIVE_DB_NAME}' matching pattern (nothing to check for RECONCILE_EXTERNAL_DATA)"
    return 0
  fi

  local non_external=()
  local tbl tbl_type
  while IFS= read -r tbl; do
    [[ -z "$tbl" ]] && continue
    tbl_type=$(beeline_exec "${jdbc_url}" \
      --silent=true \
      --showHeader=false \
      --outputformat=tsv2 \
      -e "USE ${HIVE_DB_NAME}; DESCRIBE FORMATTED ${tbl};" 2>&1 \
      | grep -i "^Table Type:" | awk -F'\t' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [[ "$tbl_type" != "EXTERNAL_TABLE" ]]; then
      non_external+=("${tbl} (${tbl_type:-unknown})")
    fi
  done <<< "$tables"

  if [[ ${#non_external[@]} -gt 0 ]]; then
    echo "ERROR: RECONCILE_EXTERNAL_DATA=true requires every table in '${HIVE_DB_NAME}' to be EXTERNAL_TABLE."
    echo "ERROR: Found non-external table(s):"
    for t in "${non_external[@]}"; do
      echo "  - ${t}"
    done
    echo "ERROR: Managed/ACID table data cannot be safely reconciled with a manual distcp (base/delta"
    echo "ERROR: directories, valid-txn-lists have no equivalent manual step). Re-run with"
    echo "ERROR: RECONCILE_EXTERNAL_DATA=false (the default) to use REPL LOAD's normal full data copy instead."
    return 1
  fi

  echo "OK: all tables in '${HIVE_DB_NAME}' (matching pattern) are EXTERNAL_TABLE - safe for RECONCILE_EXTERNAL_DATA=true"
  return 0
}

# table_location: print the LOCATION of a single table via DESCRIBE
# FORMATTED against the given JDBC URL. Works for both default-warehouse-
# path and custom-LOCATION tables.
table_location() {
  local jdbc_url="$1"
  local db="$2"
  local tbl="$3"

  beeline_exec "${jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "USE ${db}; DESCRIBE FORMATTED ${tbl};" 2>&1 \
    | grep -i "^Location:" | awk -F'\t' '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# reconcile_external_table_data: for every table actually present in
# HIVE_DB_NAME on the LOAD target after a metadata-only bootstrap REPL LOAD
# ('hive.repl.run.data.copy.tasks.on.target'='false'), read that table's
# real LOCATION on both the dump source and the load target (handles custom
# LOCATIONs, not just Hive's default warehouse path) and run a manual
# `hadoop distcp ${DISTCP_OPTS}` directly between those two paths. This is
# the ONLY point in the whole pipeline where a genuine destination-aware
# skip-if-unchanged copy happens - REPL LOAD's own bootstrap copy task has
# no such comparison (confirmed via testing: it re-copies every file in the
# dump manifest unconditionally, regardless of what already exists at the
# destination). Only called when RECONCILE_EXTERNAL_DATA=true, after
# check_all_tables_external has already confirmed every table in scope is
# EXTERNAL_TABLE.
reconcile_external_table_data() {
  # The token-renewal-exclude property must name the DUMP source's
  # nameservice (the far side being read from during this copy) for
  # whichever direction is actually running - DUMP_NAMESERVICE, computed
  # per-call by derive_db_vars - not a value fixed to one role label
  # regardless of direction.
  local distcp_token_exclude_opt="-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${DUMP_NAMESERVICE}"

  echo "$SUBSEP"
  echo "Reconciling external table data via manual distcp (RECONCILE_EXTERNAL_DATA=true)..."
  echo "DistCp options: ${distcp_token_exclude_opt} -Dmapreduce.job.queuename=${YARN_QUEUE} ${DISTCP_OPTS}"
  echo ""

  local tables_output tables
  tables_output=$(beeline_exec "${LOAD_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "USE ${HIVE_DB_NAME}; SHOW TABLES;" 2>&1) || {
    echo "ERROR: Could not list tables in '${HIVE_DB_NAME}' on load target for data reconciliation"
    return 1
  }
  tables=$(echo "$tables_output" | grep -E "^[A-Za-z0-9_]+$")

  if [[ -z "$tables" ]]; then
    echo "[WARN] No tables found in '${HIVE_DB_NAME}' on load target after metadata-only LOAD - nothing to reconcile"
    return 0
  fi

  # Split the tool-specific options string into an array once, up front -
  # deliberate word-splitting (meant to expand into multiple separate
  # distcp flags, e.g. "-p -update -skipcrccheck"), done explicitly via
  # read -ra rather than a bare unquoted expansion at the call site.
  #
  # ORDER MATTERS: `hadoop distcp` is a Tool, so its GenericOptionsParser
  # only recognizes -D/-fs/-conf/etc. when they appear BEFORE any
  # tool-specific arguments (-p, -update, -skipcrccheck, source/dest
  # paths). Confirmed via testing: with -D flags placed AFTER
  # -p -update -skipcrccheck, distcp's CopyListing treated the -D flags
  # themselves as literal source paths ("-Dmapreduce.job...=... doesn't
  # exist") instead of parsing them as JVM properties, failing with
  # InvalidInputException before any copy started. All -D options (the
  # token-exclude and queue flags below) are placed first for this reason;
  # DISTCP_OPTS (-p -update -skipcrccheck) comes after, then finally the
  # source/dest paths.
  local -a distcp_opts_arr
  read -ra distcp_opts_arr <<< "$DISTCP_OPTS"

  # YARN_QUEUE routes REPL LOAD's OWN internal copy job via SET
  # mapreduce.job.queuename/tez.queue.name in the beeline session (see
  # beeline_exec_load) - that mechanism only works for a job HiveServer2
  # itself submits. This manual `hadoop distcp` call is a plain CLI
  # invocation outside any beeline session, so the equivalent is passing
  # the same underlying MapReduce property directly as a -D generic
  # option instead.
  local -a distcp_dgen_arr=("$distcp_token_exclude_opt" -Dmapreduce.job.queuename="${YARN_QUEUE}")

  local tbl src_loc dst_loc
  local failed=0
  while IFS= read -r tbl; do
    [[ -z "$tbl" ]] && continue

    src_loc=$(table_location "$DUMP_JDBC_URL" "$HIVE_DB_NAME" "$tbl")
    dst_loc=$(table_location "$LOAD_JDBC_URL" "$HIVE_DB_NAME" "$tbl")

    if [[ -z "$src_loc" || -z "$dst_loc" ]]; then
      echo "ERROR: Could not resolve LOCATION for table '${tbl}' (source='${src_loc}' dest='${dst_loc}') - skipping distcp for this table"
      failed=1
      continue
    fi

    echo "$SUBSEP"
    echo "Table  : ${HIVE_DB_NAME}.${tbl}"
    echo "Source : ${src_loc}"
    echo "Dest   : ${dst_loc}"
    echo "Executing: hadoop distcp ${distcp_token_exclude_opt} -Dmapreduce.job.queuename=${YARN_QUEUE} ${DISTCP_OPTS} ${src_loc} ${dst_loc}"
    if ! run_as_hdfs hadoop distcp "${distcp_dgen_arr[@]}" "${distcp_opts_arr[@]}" "${src_loc}" "${dst_loc}"; then
      echo "ERROR: distcp failed for table '${tbl}' (${src_loc} -> ${dst_loc})"
      failed=1
      continue
    fi
    echo "OK: reconciled ${HIVE_DB_NAME}.${tbl}"
    echo ""
  done <<< "$tables"

  if [[ $failed -ne 0 ]]; then
    echo "ERROR: One or more tables failed external data reconciliation for '${HIVE_DB_NAME}'"
    return 1
  fi

  echo "All external tables in '${HIVE_DB_NAME}' reconciled successfully."
  echo ""
}

# replicate_one_db: replicate a single database - runs a bootstrap cycle
# if the destination database does not yet exist, or an incremental cycle
# if it does. This is the main entry point used for every database when
# REPLICATION_DIRECTION is "src_to_dst" (normal, non-failover) replication.
replicate_one_db() {
  local db_spec="$1"
  local db_index="$2"
  local db_total="$3"

  derive_db_vars "$db_spec"

  ########################################
  # Per-database log file
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
  echo "Direction : $REPLICATION_DIRECTION (DUMP: $DUMP_NAMESERVICE -> LOAD: $LOAD_NAMESERVICE)"
  echo "Log File  : $LOG_FILE"
  echo ""

  ########################################
  # Step 1: Check whether the database already exists on the load target
  ########################################
  echo "$SUBSEP"
  echo "[1/${TOTAL_STEPS}] Checking if database exists on load target..."

  DB_CHECK_OUTPUT=$( beeline_exec "${LOAD_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "SHOW DATABASES LIKE '${HIVE_DB_NAME}';" 2>&1 || true )

  # beeline prints its own connection/session chatter (e.g. "Setting
  # property: ...", "!connect ...", timestamped "INFO ..." lines,
  # "Executing command: ...") even with --silent=true - none of that is
  # suppressed by --silent, which only affects query RESULT formatting.
  # Only accept a line that looks like a valid Hive identifier (letters,
  # digits, underscore) as the actual result; every other line - no
  # matter its shape - is beeline chrome, not data.
  DB_EXISTS=$(echo "$DB_CHECK_OUTPUT" | grep -E "^[A-Za-z0-9_]+$" | head -n 1 || true)

  # The Hive Metastore stores and returns database names in lowercase, so
  # compare case-insensitively.
  if [[ -n "$DB_EXISTS" && "${DB_EXISTS,,}" != "${HIVE_DB_NAME,,}" ]]; then
    echo "ERROR: Database exist check failed on load target"
    echo "$DB_CHECK_OUTPUT"
    return 1
  fi

  ########################################
  # Step 2: Decide bootstrap vs. incremental
  #
  # A database that EXISTS but is genuinely empty (0 tables) is still
  # eligible for a bootstrap REPL LOAD - this matches Hive's own
  # LoadDatabase.getLoadDbType() constraint (bootstrap proceeds if the
  # target database is nonexistent, already at the dump's own repl
  # checkpoint, OR literally empty). Checking database existence alone
  # (SHOW DATABASES) is not enough to tell bootstrap from incremental
  # apart: an empty database (for example, one left behind after moving
  # its old tables aside to a "_backup" database so REPL LOAD could
  # bootstrap onto it at all - see RECONCILE_EXTERNAL_DATA above) still
  # exists as a database object, but has no tables to make an incremental
  # cycle meaningful against. Without this table-count check, such a
  # database would be routed to run_incremental_cycle() (which
  # unconditionally sets hive.repl.run.data.copy.tasks.on.target=true and
  # never reads RECONCILE_EXTERNAL_DATA at all), even though REPL DUMP/LOAD
  # would still internally perform a real bootstrap underneath - silently
  # skipping this script's own bootstrap-only safeguards
  # (RECONCILE_EXTERNAL_DATA check/flip, snapshot enablement, the ERR trap).
  ########################################
  echo "$SUBSEP"
  echo "[2/${TOTAL_STEPS}] Determining replication mode..."

  local BOOTSTRAP
  if [[ -n "$DB_EXISTS" ]]; then
    local existing_table_count
    existing_table_count=$(beeline_exec "${LOAD_JDBC_URL}" \
      --silent=true \
      --showHeader=false \
      --outputformat=tsv2 \
      -e "USE ${HIVE_DB_NAME}; SHOW TABLES;" 2>&1 \
      | grep -c -E "^[A-Za-z0-9_]+$")

    if [[ "$existing_table_count" -eq 0 ]]; then
      echo "Database '${HIVE_DB_NAME}' exists on load target but has 0 tables - Bootstrap mode (empty database is bootstrap-eligible per Hive's own REPL LOAD constraint)"
      BOOTSTRAP=true
    else
      echo "Database '${HIVE_DB_NAME}' exists on load target with ${existing_table_count} table(s) - Incremental replication mode"
      BOOTSTRAP=false
    fi
  else
    echo "Database '${HIVE_DB_NAME}' DOES NOT exist on load target - Bootstrap mode"
    BOOTSTRAP=true
  fi
  echo ""

  if [[ "$BOOTSTRAP" == "true" ]]; then
    # If bootstrap fails partway through, warn that the destination
    # database may be left in a partial state and should be checked
    # before re-running.
    trap 'echo ""; echo "ERROR: Bootstrap failed at $(date). The load-target database may be in an inconsistent state."; echo "Before re-running, check: REPL STATUS ${HIVE_DB_NAME} on the load target and clean up if needed."; echo "Log File: $LOG_FILE"' ERR

    if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
      enable_external_table_snapshots "$DUMP_NAMESERVICE"
      enable_external_table_snapshots "$LOAD_NAMESERVICE"
    fi

    if [[ "${RECONCILE_EXTERNAL_DATA,,}" == "true" ]]; then
      echo "$SUBSEP"
      echo "RECONCILE_EXTERNAL_DATA=true - verifying all tables in '${HIVE_DB_NAME}' are EXTERNAL_TABLE..."
      if ! check_all_tables_external "$DUMP_JDBC_URL"; then
        echo "ERROR: Aborting bootstrap for ${HIVE_DB_NAME} - see error above"
        trap - ERR
        return 1
      fi
      echo ""
    fi

    ########################################
    # Step 3: Bootstrap REPL DUMP on the dump source
    ########################################
    echo "$SUBSEP"
    echo "[3/${TOTAL_STEPS}] Running REPL DUMP on dump source (${DUMP_NAMESERVICE}) (Bootstrap)..."

    DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
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

    if ! beeline_exec "${DUMP_JDBC_URL}" -e "$DUMP_CMD"; then
      echo "ERROR: Bootstrap REPL DUMP failed for ${HIVE_DB_NAME}"
      trap - ERR
      return 1
    fi
    echo ""

    ########################################
    # Step 4: Bootstrap REPL LOAD on the load target
    ########################################
    echo "$SUBSEP"
    echo "[4/${TOTAL_STEPS}] Running REPL LOAD on load target (${LOAD_NAMESERVICE}) (Bootstrap)..."

    # 'hive.repl.run.data.copy.tasks.on.target'='true' is what makes
    # REPL LOAD actually copy external table data (from the source
    # external directory into REPL_EXTERNAL_BASE_DIR) as part of the LOAD
    # itself. Leaving this at "false" would silently skip copying
    # external table data, so it is always set explicitly here.
    #
    # EXCEPTION: when RECONCILE_EXTERNAL_DATA=true, this is deliberately
    # set to "false" instead - REPL LOAD then recreates metadata only (no
    # data copy at all), and reconcile_external_table_data() (called below)
    # does the data copy itself via a manual per-table `hadoop distcp`,
    # which can genuinely skip files already present/unchanged on the load
    # target. See "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" near the
    # top of this file for why this exists.
    local load_data_copy_flag="true"
    if [[ "${RECONCILE_EXTERNAL_DATA,,}" == "true" ]]; then
      load_data_copy_flag="false"
      echo "RECONCILE_EXTERNAL_DATA=true - bootstrap LOAD will be metadata-only; data copy is done via manual distcp after LOAD completes."
    fi

    LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.run.data.copy.tasks.on.target'='${load_data_copy_flag}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
'hive.repl.dump.metadata.only.for.external.table'='false',
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "Ensuring external table base directory exists on load target: ${REPL_EXTERNAL_BASE_DIR}"
    run_as_hdfs hdfs dfs -mkdir -p "${REPL_EXTERNAL_BASE_DIR}" || true
    run_as_hdfs hdfs dfs -chmod 1777 "${REPL_EXTERNAL_BASE_DIR}" || true
    echo ""

    echo "$SUBSEP"
    echo "Executing: $LOAD_CMD"
    echo ""

    if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "$LOAD_CMD"; then
      echo "ERROR: Bootstrap REPL LOAD failed for ${HIVE_DB_NAME}"
      trap - ERR
      return 1
    fi
    echo ""

    if [[ "${RECONCILE_EXTERNAL_DATA,,}" == "true" ]]; then
      if ! reconcile_external_table_data; then
        echo "ERROR: External data reconciliation failed for ${HIVE_DB_NAME}"
        trap - ERR
        return 1
      fi
    fi

    ########################################
    # Step 5: Post-load validation
    ########################################
    echo "$SUBSEP"
    echo "[5/${TOTAL_STEPS}] Validating replication status on load target..."
    echo ""

    beeline_exec "${LOAD_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - bootstrap DUMP/LOAD already succeeded)"
    echo ""

    # Bootstrap completed successfully - clear the error trap.
    trap - ERR
  else
    if ! run_incremental_cycle; then
      echo "ERROR: Incremental replication cycle failed for ${HIVE_DB_NAME}"
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
  echo "Direction    : $REPLICATION_DIRECTION"
  echo "Dump source  : $DUMP_NAMESERVICE"
  echo "Load target  : $LOAD_NAMESERVICE"
  echo "YARN Queue   : $YARN_QUEUE (REPL LOAD data-copy jobs)"
  echo ""
  echo "Completed    : $(date)"
  echo "Log File     : $LOG_FILE"
  echo ""
  echo "$SEP"
  echo ""
}

# ==============================================================================
#  Script entry point
# ==============================================================================

########################################
# Session logging - a single top-level log file covers every database
# processed in this invocation, in addition to each database's own
# per-database log file.
########################################

mkdir -p "$LOG_DIR"
SESSION_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
SESSION_LOG_FILE="$LOG_DIR/hive_bdr_session_${SESSION_TIMESTAMP}.log"

exec > >(tee -a "$SESSION_LOG_FILE") 2>&1

# Re-point fd 3 (opened earlier, at script startup) at the now-active
# session-log "tee" pipeline, so heartbeat/debug messages written to fd 3
# reach both the console and SESSION_LOG_FILE - while still never sharing
# a file descriptor with output a caller captures via $(...).
exec 3>&1

SEP="======================================================================"
SUBSEP="----------------------------------------------------------------------"

DB_COUNT=${#DB_SPECS[@]}

echo "$SEP"
echo " Hive Cluster Replication Script Started"
echo "$SEP"
echo "Timestamp    : $(date)"
echo "Databases    : ${DB_COUNT} (${HIVE_DB})"
echo "SRC (fixed)  : $SRC_NAMESERVICE"
echo "DST (fixed)  : $DST_NAMESERVICE"
echo "Direction    : $REPLICATION_DIRECTION"
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
# Main loop - process each database spec in sequence.
#
# REPLICATION_DIRECTION is read directly on every invocation: there is no
# local state file that tries to guess whether a direction change is
# intended. The caller (a human, cron, or an orchestration tool) is
# always responsible for explicitly passing FAILOVER_MODE /
# REPLICATION_DIRECTION to indicate whether this run should be a normal
# replication cycle or a direction change.
########################################
DB_IDX=0
FAILED_DBS=()
for db_spec in "${DB_SPECS[@]}"; do
  DB_IDX=$(( DB_IDX + 1 ))
  echo "$SEP"
  echo " Processing DB ${DB_IDX}/${DB_COUNT}: ${db_spec}"
  echo "$SEP"

  if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
    if ! failover_one_db "$db_spec" "$DB_IDX" "$DB_COUNT"; then
      echo "ERROR: Direction-change replication failed for DB spec: ${db_spec}"
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

# ==============================================================================
#  SUGGESTED FUTURE POSITIONAL ARGUMENTS
# ------------------------------------------------------------------------------
#  The settings below currently require editing this script (or exporting
#  an environment variable before running it) to change per environment.
#  If different environments running this script are expected to need
#  different values regularly, consider promoting these to positional
#  arguments (or documented environment variables, if they should stay
#  optional/advanced) so no manual script edits are needed. Listed in
#  rough order of how commonly they vary between environments; excludes
#  HIVE_LDAP_ENABLED / HIVE_PASSWORD, which should stay environment-only
#  since they carry credentials.
#
#    1. HIVE_REPL_SNAPSHOT_COPY
#       Whether to use HDFS snapshot-diff copying for external tables.
#       Environments with only small tables may never need this; those
#       with large (1 TB+) external tables likely always want it on.
#
#    2. HIVE_EXTERNAL_WAREHOUSE_DIR
#       The source cluster's external table warehouse path. Differs
#       between Hive 3+ clusters (default used here) and older Hive/HDP
#       clusters (commonly /user/hive/external).
#
#    3. HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS
#       Whether to replicate materialized views. Depends entirely on
#       whether a given deployment uses materialized views at all.
#
#    4. HA_CONFIG_IN_WITH_CLAUSE, SRC_NN_HOSTS, DST_NN_HOSTS,
#       AUTOMATIC_FAILOVER_ENABLED
#       Needed only when a cluster's own hdfs-site.xml does not already
#       know about the other cluster's HA nameservice. Whether this is
#       needed - and the NameNode host/port values themselves - is
#       entirely dependent on each customer's network and cluster setup.
#
#    5. INCREMENTAL_LOCK_DIR, SNAP_LOCK_DIR
#       Local lock file directories. Rarely need to change, but
#       environments with restricted /var/tmp access may require a
#       different path.
# ==============================================================================
