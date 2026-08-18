#!/bin/bash
# ==============================================================================
#  Hive Cluster Replication Script (Hive BDR)
#  Version : 4.2.0
#  Purpose : Replicate one or more Hive databases from a source cluster to a destination cluster using Hive's native REPL DUMP / REPL LOAD commands, and manage direction reversal (failover / failback) between the two clusters.
# ==============================================================================
#
# QUICK REFERENCE - POSITIONAL ARGUMENTS & ENV VARS
# ----------------------------------------------------------------------------
#   Full explanations further down in this file. This block is just the name/default/order lookup.
#
#   Pos  Name                      Default
#   ---  ------------------------  ----------------------------------------
#    1   HIVE_DB                   (required)
#    2   SRC_NAMESERVICE           (required)
#    3   DST_NAMESERVICE           (required)
#    4   SRC_JDBC_URL              (required)
#    5   DST_JDBC_URL              (required)
#    6   YARN_QUEUE                default
#    7   REPL_BASE_DIR             /user/hive/repl/
#    8   LOG_DIR                   /var/log/hive-replication
#    9   HDFS_USER                 hdfs
#   10   HIVE_USER                 hdfs
#   11   FAILOVER_MODE             false
#   12   RECONCILE_EXTERNAL_DATA   false
#
#   Env-only (no positional slot):
#     REPLICATION_DIRECTION       (derived from FAILOVER_MODE)
#     DIRECTION_CHANGE            (derived from FAILOVER_MODE)
#     FAILOVER_MAX_ROUNDS         3
#     REPL_ROOT_SUFFIX            (derived from the dumping cluster's NN hosts)
#     PREFLIGHT_PRIMARY_CHECK     false
#     RECONCILE_ON_DIRECTION_CHANGE   true
#     METADATA_ONLY               false
#     DISTCP_OPTS                 --strategy dynamic -direct -update -pugptx -skipcrccheck
#     HIVE_REPL_SNAPSHOT_COPY      false
#     HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS   false
#     AUTO_DERIVE_HA_CLIENT_CONFIG     no
#     SRC_NN_HOSTS / DST_NN_HOSTS  (required if AUTO_DERIVE_HA_CLIENT_CONFIG=yes)
#     AUTOMATIC_FAILOVER_ENABLED   true
#     HIVE_LDAP_ENABLED / HIVE_PASSWORD   false / (unset)
#     INCREMENTAL_LOCK_DIR         /var/tmp/hive-bdr-incremental-locks
#     SNAP_LOCK_DIR                /var/tmp/hive-bdr-snapshot-setup-locks
#     HIVE_EXTERNAL_WAREHOUSE_DIR  /warehouse/tablespace/external/hive
#     BEELINE_VERBOSE              false
#     HEARTBEAT_INTERVAL_SECONDS   60
#     BEELINE_COMMAND_TIMEOUT_SECONDS   0
#
#   To change a default: edit the corresponding line in the "Read positional arguments" block (search for the variable name) further down in this script.
# ==============================================================================
#
# WHAT THIS SCRIPT DOES
# ----------------------------------------------------------------------------
#   Hive's built-in replication (REPL DUMP on the source, REPL LOAD on the destination) keeps a destination database in sync with a source database, including both metadata and table data. REPL LOAD copies data itself, so this script does not run any separate `hadoop distcp` step.
#
#   This script wraps that workflow so it can be run unattended (e.g. from cron or an orchestration tool) and gives you:
#
#     1. Bootstrap replication
#        The first time a database is replicated, the destination database does not exist yet. The script detects this and runs a full REPL DUMP + REPL LOAD (bootstrap) cycle to create it.
#
#     2. Incremental replication
#        On every later run, the script detects that the destination database already exists and runs a lightweight incremental REPL DUMP + REPL LOAD cycle instead - only the changes made on the source since the last run are copied. There is no separate "incremental mode" to configure; the script always decides this for you by checking whether the destination database exists. To get incremental replication on a schedule, re-run this script periodically (cron, systemd timer, or any external scheduler).
#
#     3. Multiple databases in one invocation
#        Pass more than one database (or table pattern) separated by "|" and the script replicates each one in turn, reporting success/failure per database.
#
#     4. Failover and failback (direction reversal)
#        If the source cluster becomes unavailable and the destination cluster is promoted to take live traffic, this script can reverse the replication direction so the (former) destination now dumps and the (former) source now loads. The same reversal can be repeated back and forth any number of times without ever having to swap which cluster's connection details are passed to the script - see "FAILOVER AND FAILBACK" below.
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
#   All 12 arguments are positional - the order matters. Trailing arguments may be omitted and will fall back to their defaults (shown below).
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
#          Regex db (prefix)   : "'sales_.*'"
#          Regex db (suffix)   : "'.*_backup'"
#          Regex db (exact set): "'(sales_us|sales_eu|sales_apac)'"
#          Regex db (multi-prefix): "'(sales|analytics)_.*'"
#          Regex db (numeric shard): "'sales_shard[0-9]+'"
#          Regex db (env suffix)  : "'.*_(dev|test)'"
#          Regex db (case variant): "'[Ss]ales_.*'"
#          Regex db (everything)  : "'.*'"
#          Regex db + table    : "'sales_.*'.'(orders|customers)'"
#          Regex db + exclude  : "'sales_.*'.'(?!orders$).*'"
#          Two regex db groups : "'sales_.*'|'analytics_.*'"
#          Regex db + literal  : "hr|'sales_.*'"
#        Note: a "|" written inside single quotes (i.e. inside a table pattern) is treated as part of the pattern, not as a database separator.
#        A database portion wrapped in single quotes (e.g. 'sales_.*') is treated as a regex instead of a literal database name, and is expanded to every real database matching it before REPL DUMP is ever issued (REPL DUMP itself only ever accepts one literal database name - it has no database-pattern grammar). This expansion match is a POSIX ERE (bash/grep -E) against SHOW DATABASES on the dump source - NOT Hive's own Java regex dialect used for HIVE_TABLE_PATTERN above, so a Java-only construct like the "(?!...)" negative lookahead shown above works for a table pattern (evaluated by Hive server-side) but will NOT work for a database pattern (evaluated by this script, client-side, via grep -E). The pattern is always implicitly anchored at both ends (matched as "^pattern$"), so "sales_.*" matches "sales_us" but not "old_sales_us" - do not add your own "^"/"$". There is no direct way to write "every database except X" as a single database regex (POSIX ERE has no negative lookahead) - list the databases you do want instead, e.g. via an exact-set alternation like the example above.
#
#   2. SRC_NAMESERVICE     (required)
#        The source cluster's HDFS nameservice (or "host:port" for a non-HA NameNode). This is a fixed label for this cluster and does not change when the replication direction is reversed - see "FAILOVER AND FAILBACK" below.
#
#   3. DST_NAMESERVICE     (required)
#        The destination cluster's HDFS nameservice (or "host:port"), same rules as SRC_NAMESERVICE above.
#
#   4. SRC_JDBC_URL        (required)
#        JDBC connection string for the source cluster's HiveServer2.
#        Example:
#          jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2
#
#   5. DST_JDBC_URL        (required)
#        JDBC connection string for the destination cluster's HiveServer2, same format as SRC_JDBC_URL.
#
#   6. YARN_QUEUE          (default: "default")
#        The YARN Capacity Scheduler queue that REPL LOAD's internal data copy job should run in. See the YARN_QUEUE section below.
#
#   7. REPL_BASE_DIR       (default: "/user/hive/repl/")
#        The HDFS directory (on the source cluster) where Hive stages the REPL DUMP output before REPL LOAD reads it.
#
#   8. LOG_DIR             (default: "/var/log/hive-replication")
#        Local directory where this script writes its log files.
#
#   9. HDFS_USER           (default: "hdfs")
#        The OS user the script uses to run `hdfs dfs` / `hdfs dfsadmin` commands when Kerberos is not in use. See "AUTHENTICATION" below.
#
#  10. HIVE_USER           (default: "hdfs")
#        The username passed to beeline when Kerberos is not in use. See "AUTHENTICATION" below.
#
#  11. FAILOVER_MODE       (default: "false")
#        Set to "true" to reverse the replication direction (failover), or "false" for normal replication. See "FAILOVER AND FAILBACK" below.
#
#  12. RECONCILE_EXTERNAL_DATA (default: "false")
#        Set to "true" ONLY for a database (or table pattern) where every table is an EXTERNAL_TABLE and the load target already has partial or full matching HDFS data worth not re-copying - for example, an existing DR database that was moved aside to a "_backup" database so this script's bootstrap REPL LOAD could run against an empty database (Hive's REPL LOAD bootstrap path refuses a non-empty target database, with no override). See "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" below for the full explanation of what this changes and why. Leave this "false" (the default) for normal replication, and for ANY database that may contain managed/ACID tables - the script fails fast, before REPL DUMP/LOAD runs at all, if RECONCILE_EXTERNAL_DATA=true is requested for a database containing a non-external table.
#
#   Any of arguments 6, 9, 10, 11, and 12 (YARN_QUEUE, HDFS_USER, HIVE_USER, FAILOVER_MODE, RECONCILE_EXTERNAL_DATA) can also be supplied as an environment variable of the same name instead of a positional argument. If both are set, the positional argument wins.
#
#   REPLICATION_DIRECTION and DIRECTION_CHANGE are NOT positional arguments - they are environment/in-file variables only, the same pattern as METADATA_ONLY and DISTCP_OPTS. Both default to empty, meaning "derive from FAILOVER_MODE", so the twelve positional arguments above are all most runs ever need. Set them only for the two DR phases FAILOVER_MODE cannot express - see "FAILOVER AND FAILBACK" below.
#
# FAILOVER AND FAILBACK
# ----------------------------------------------------------------------------
#   SRC_NAMESERVICE / DST_NAMESERVICE / SRC_JDBC_URL / DST_JDBC_URL describe the two clusters this setup replicates between. The simplest way to run is to keep them fixed for the lifetime of the setup (SRC = production, DST = DR) and express direction only through the variables below - but swapping them is also supported, and is often the natural choice when a separate deployment of this script runs on each cluster. See "CHOOSING SOURCE AND DESTINATION" below for both routes and the one rule that matters when swapping.
#
#   Instead, a run is described by TWO independent values:
#
#     REPLICATION_DIRECTION - which cluster dumps and which loads:
#       src_to_dst -> REPL DUMP on SRC, REPL LOAD on DST
#       dst_to_src -> REPL DUMP on DST, REPL LOAD on SRC
#
#     DIRECTION_CHANGE     - whether this run FLIPS which side is primary:
#       false -> ongoing replication in the direction already in force
#       true  -> a one-off failover/failback handshake
#
#   FAILOVER_MODE is a shorthand that sets both at once, and remains the only
#   thing most runs need:
#     FAILOVER_MODE=false -> src_to_dst + DIRECTION_CHANGE=false  (normal replication)
#     FAILOVER_MODE=true  -> dst_to_src + DIRECTION_CHANGE=true   (failover)
#
#   The full DR lifecycle needs all four combinations, and FAILOVER_MODE can
#   only express two of them - so the other two are requested explicitly:
#
#     phase                                    direction    DIRECTION_CHANGE
#     --------------------------------------   ----------   ----------------
#     1. normal replication  Primary -> DR     src_to_dst   false   (FAILOVER_MODE=false)
#     2. failover: promote DR                  dst_to_src   true    (FAILOVER_MODE=true)
#     3. ongoing replication DR -> Primary     dst_to_src   false   <- explicit
#     4. failback: promote Primary back        src_to_dst   true    <- explicit
#     5. back to phase 1                       src_to_dst   false   (FAILOVER_MODE=false)
#
#   Phase 3 is the one most easily missed: once a failover has converged, new
#   writes land on the promoted cluster and still have to reach the demoted one.
#   That is ordinary incremental replication that happens to point "backwards",
#   NOT another failover - and it copies table data like any other cycle.
#   Requesting it as a failover aborts at the pre-flight (the promoted cluster
#   is a primary, not a caught-up replica); requesting it as FAILOVER_MODE=false
#   dumps from the demoted cluster - the replica - and Hive rejects the result
#   with "Bootstrap REPL LOAD is not allowed on Database: <db> as it was already
#   done" (return code 40000).
#
#   Example - phase 3, an ongoing DR -> Primary cycle:
#     REPLICATION_DIRECTION=dst_to_src DIRECTION_CHANGE=false ./this_script.sh ...
#
#   Example - phase 4, failing back:
#     REPLICATION_DIRECTION=src_to_dst DIRECTION_CHANGE=true  ./this_script.sh ...
#
#   Before requesting a direction change, make sure:
#     - Replication is already configured and has completed at least one successful REPL DUMP/LOAD cycle in the CURRENT direction. The script checks this automatically via a REPL STATUS pre-flight check and will refuse to proceed with a clear error message if the new "dump" side is not yet an eligible replication source.
#     - The real cluster failover has already happened at the infrastructure level, and new writes are only occurring on the cluster that is about to become the new dump source.
#
#   On a direction-change run (DIRECTION_CHANGE=true), the script performs for each database:
#     Step 1 - Pre-flight check: confirm the new dump side is eligible.
#     Step 2 - REPL DUMP on the new primary, with 'hive.repl.failover.start'='true'.
#     Step 3 - REPL LOAD on the new replica.
#   ...with steps 2 and 3 REPEATED until the flip is confirmed. Hive's direction
#   change is a multi-round handshake: round 1's DUMP returns last_repl_id=-1 and
#   writes an "event_ack" file, its LOAD applies zero events and only records the
#   control state, and REPL STATUS on the new replica is still NULL. Round 2's
#   DUMP returns a real INCREMENTAL dump on the new primary's own event numbering
#   and its LOAD applies it, at which point REPL STATUS on the new replica
#   returns a real id: converged. The script loops up to FAILOVER_MAX_ROUNDS
#   (default 3) and treats a non-NULL REPL STATUS on the new replica as the only
#   proof of success - so an unconverged flip is reported as a FAILURE rather
#   than as "Completed".
#
#   The REPL LOAD statements in a direction-change run never copy data themselves
#   ('hive.repl.run.data.copy.tasks.on.target'='false'). What happens to external
#   table data afterwards is controlled by RECONCILE_ON_DIRECTION_CHANGE
#   (default "true"): once the handshake CONVERGES, the same manual per-table
#   `hadoop distcp` used by normal cycles runs once.
#
#   Why this is not simply skipped, as it once was: the round-2 REPL LOAD ends
#   with an inner BOOTSTRAP of the TABLE DIFF - the tables that had diverged
#   between the two clusters - and its "numTables" says how many. On a clean
#   flip that is 0, nothing diverged, and the reconcile finds nothing to move
#   (the distcp "-update" comparison skips unchanged files rather than
#   re-transferring them). On an UNPLANNED failover, where the old primary took
#   writes that never replicated, it is greater than 0 - Hive has re-created
#   those tables from the new primary, and their data does need copying. Forcing
#   the copy off unconditionally was safe only in the first case, and silently
#   produced tables with no data underneath in the second.
#
#   Set RECONCILE_ON_DIRECTION_CHANGE=false to restore the old skip-everything
#   behavior for a flip you know is clean, or for a large multi-database
#   direction change where a listing pass per table is not worth paying.
#
#   The copy never runs between handshake rounds - only after convergence. Round
#   1 produces last_repl_id=-1 and an event_ack marker with no metadata and no
#   tables, so there is nothing for a copy step to act on.
#
#   NOTE the exemption above is keyed on DIRECTION_CHANGE, not on direction. Phase 3
#   (dst_to_src + DIRECTION_CHANGE=false) is ordinary bulk replication and DOES copy
#   external table data, exactly like phase 1. Keying it on direction instead would
#   replicate metadata while never moving a byte - repl.last.id advancing on the
#   replica, tables appearing present, no data underneath.
#
#   FAILOVER_MODE=false does NOT return you to normal replication straight after a
#   failover: at that point SRC is the replica, so dumping from it is wrong. Go through
#   phase 4 (failback) first; only once SRC is primary again does FAILOVER_MODE=false
#   mean what it did in phase 1.
#
# CHOOSING SOURCE AND DESTINATION
# ----------------------------------------------------------------------------
#   There are TWO supported ways to drive the reversed direction after a failover.
#   They are equivalent - pick whichever fits how you deploy - because the REPL
#   DUMP staging directory is keyed to the DUMPING CLUSTER, never to the
#   direction label, so both routes read and write the same path:
#
#     A. Keep SRC/DST fixed, name the direction.
#        SRC stays production, DST stays DR, forever. Set
#        REPLICATION_DIRECTION=dst_to_src (+ DIRECTION_CHANGE as appropriate).
#        One configuration covers the whole lifecycle; only the two variables move.
#
#     B. Swap SRC/DST, keep the direction as src_to_dst.
#        Point SRC at whichever cluster is currently primary and DST at the
#        replica, and leave the direction alone. Natural when a separate
#        deployment of this script runs on each cluster - e.g. the action runs
#        on the DR node while production is primary, then on the production node
#        once DR has been promoted, which also places the manual `hadoop distcp`
#        compute on whichever cluster you want doing the copying.
#
#   If you choose B, swap ALL FOUR of that side's values together -
#   SRC_NAMESERVICE, SRC_JDBC_URL, SRC_NN_HOSTS (and the DST equivalents).
#   Swapping only some of them - for example the JDBC URLs but not the NN hosts -
#   binds each internal alias to the wrong physical cluster, and every "hdfs://"
#   URI this script builds then points at the wrong side.
#
#   Whichever route you take, the invariant is the same: the side being DUMPED
#   FROM must be the current primary, which Hive identifies by REPL STATUS
#   returning NULL there (a replica returns a real last_repl_id). Exactly one of
#   the two clusters should return NULL for a given database.
#
#   The script can assert that invariant for you, but does not by default - it
#   costs one extra beeline call per database per run, which is significant on a
#   large multi-database invocation and re-confirms something that does not
#   change between runs. Set PREFLIGHT_PRIMARY_CHECK=true for the FIRST run
#   after a failover, a failback, or a SRC/DST swap - the runs where the
#   direction could genuinely be wrong - and leave it off for steady-state
#   cycles. See PREFLIGHT_PRIMARY_CHECK's own doc comment further down.
#
#   MIGRATION NOTE for setups created before the staging suffix became
#   cluster-derived: those staging directories are named after the DIRECTION -
#   "from_src_to_dst" / "from_dst_to_src" - while the derivation now produces a
#   cluster name such as "from_odplab001". A database still carrying a
#   direction-named directory needs one of:
#     - REPL_ROOT_SUFFIX=src_to_dst (or dst_to_src) on every subsequent run, or
#     - a one-time `hdfs dfs -mv` of that directory to the cluster-derived name, or
#     - a fresh bootstrap.
#   Without one of those, the next run finds an empty rootdir, falls back to a
#   BOOTSTRAP dump, and the load target rejects it with return code 40000. The
#   "Staging dir" line in the run banner prints the path actually in use.
#
# RECONCILING PRE-EXISTING EXTERNAL TABLE DATA (RECONCILE_EXTERNAL_DATA)
# ----------------------------------------------------------------------------
#   A bootstrap REPL LOAD (Step 4 above) normally sets 'hive.repl.run.data.copy.tasks.on.target'='true', which makes REPL LOAD copy every external table's data itself, as part of the LOAD. That internal copy always re-copies every file listed in the REPL DUMP manifest, with no regard for what may already exist at the destination path - confirmed by testing: files already present on the load target, byte-identical (same size, same checksum) to the source, were still re-copied in full. There is no Hive configuration property that makes this internal copy skip unchanged files.
#
#   This matters for a specific, real scenario: a load-target database that already has data for the same tables you are about to replicate - for example, an earlier/legacy replication tool (such as Cloudera BDR) has already copied some or all of a database's external table data, or an existing DR database was deliberately renamed aside to a "_backup" database (see the empty-database-prep step you may already be running separately) purely so this script's bootstrap REPL LOAD has an empty database to bootstrap into - Hive's REPL LOAD bootstrap path refuses to run against a non-empty target database, with no override. In that situation the load target's HDFS files are frequently still physically present at their original path (renaming a Hive table does not move its underlying data), so REPL LOAD's normal full re-copy wastes bandwidth and time proportional to the FULL table size, not just the genuinely missing data.
#
#   Setting RECONCILE_EXTERNAL_DATA=true for a bootstrap run changes two things:
#     1. The bootstrap REPL LOAD sets 'hive.repl.run.data.copy.tasks.on.target'='false' instead of "true" - REPL LOAD then recreates metadata only (databases, tables, partitions) and copies NO table data itself.
#     2. Immediately after that metadata-only LOAD succeeds, this script runs a manual `hadoop distcp ${DISTCP_OPTS}` once per external table, directly between that table's real LOCATION on the dump source and its real LOCATION on the load target (read via DESCRIBE FORMATTED on both sides, so this works correctly even for tables with a custom, non-default LOCATION). Unlike REPL LOAD's own internal copy, a real `hadoop distcp` with -update/-skipcrccheck (the DISTCP_OPTS default) genuinely compares source and destination and skips files that already match - this is the ONLY point in the whole pipeline where that comparison happens.
#
#   RECONCILE_EXTERNAL_DATA=true REQUIRES every table in the database (or table pattern) to be EXTERNAL_TABLE. Managed/ACID table data (base and delta directories, valid-txn-lists, and so on) is Hive-owned in a way that is not safe to reconcile with a raw filesystem-level distcp - there is no equivalent manual step for managed tables. This script checks every table on the dump source BEFORE running REPL DUMP/LOAD at all, and fails fast with a clear error if it finds even one non-external table, rather than disabling data copy for the whole database and silently leaving a managed table's data missing.
#
#   RECONCILE_EXTERNAL_DATA is a per-database judgment call, not a setting to leave on for every replication:
#     - Leave it "false" (the default) for normal bootstraps, for incremental cycles (an incremental cycle only ever copies new events/files, so there is normally no pre-existing-data problem to reconcile there), and for any database that may contain managed/ACID tables. For a FAILOVER run the value is ignored entirely - that direction never copies external table data (see "FAILOVER AND FAILBACK" above).
#     - Set it "true" only when you specifically know: every table in this database is external, AND the load target already has matching (or partially matching) HDFS data for those tables that is worth not re-copying from scratch.
#   On a genuinely fresh/empty load target (nothing pre-existing at any destination path), RECONCILE_EXTERNAL_DATA=true is harmless but brings no benefit - -update has nothing to skip, so the same bytes move either way, just via a separate `hadoop distcp` process instead of REPL LOAD's internal copy. There is no reason to enable it in that case.
#
#   SAME_NAMESERVICE_COLLISION (SRC_NAMESERVICE == DST_NAMESERVICE) forces this
#   mechanism on for every NORMAL-DIRECTION data-copying operation - bootstrap
#   and incremental - regardless of what RECONCILE_EXTERNAL_DATA was actually
#   passed as. (A FAILOVER run copies no external table data at all and is
#   therefore excluded - see "FAILOVER AND FAILBACK" above and
#   EFFECTIVE_RECONCILE_EXTERNAL_DATA's own doc comment.)
#   See EFFECTIVE_RECONCILE_EXTERNAL_DATA's doc comment (near the
#   SAME_NAMESERVICE_COLLISION detection code) for the full reason: confirmed
#   via live testing, Hive's own internal REPL LOAD data copy resolves each
#   external table's LOCATION using the raw, un-aliased shared nameservice
#   name exactly as recorded in the dump metadata - which the LOAD-side
#   session deliberately resolves to ITS OWN native cluster, not the dump
#   side - so it silently lists zero files and copies nothing at all. In this
#   scenario there is no working alternative for external tables (hence the
#   manual distcp path is mandatory, not optional), and still no working path
#   at all for managed/ACID tables - check_all_tables_external() fails the
#   whole run fast, before any REPL DUMP/LOAD, if it finds one.
#
# AUTHENTICATION
# ----------------------------------------------------------------------------
#   The script automatically detects whether Kerberos is available (via `klist`). This changes how it runs `hdfs`/`beeline` commands:
#
#     Kerberos available:
#       Commands run as the current OS user, using the active Kerberos ticket. HDFS_USER / HIVE_USER are not used.
#
#     Kerberos not available:
#       - `hdfs dfs` / `hdfs dfsadmin` commands run via `sudo -u $HDFS_USER`. HDFS_USER must be an HDFS superuser (or a member of the HDFS supergroup), because operations like `allowSnapshot` and `chmod`/`mkdir` on directories owned by another user (e.g. `hive`) require superuser privileges.
#       - beeline connects with `-n $HIVE_USER` so HiveServer2 does not authenticate the session as "anonymous".
#
# INCREMENTAL REPLICATION
# ----------------------------------------------------------------------------
#   This script always drives incremental replication itself by re-running a direct REPL DUMP -> REPL LOAD cycle; it does not use Hive Scheduled Queries. To keep a database up to date, re-invoke this script on your own schedule (cron, a systemd timer, or your orchestration tool of choice) with the same arguments used for the original bootstrap run.
#
# ENVIRONMENT VARIABLES (ADVANCED / OPTIONAL)
# ----------------------------------------------------------------------------
#   These are not positional arguments - set them in the environment before invoking the script, only if you need to change the default behavior.
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
#     Not positional arguments (kept as environment-only settings since HIVE_PASSWORD is a credential). Controls the password beeline sends alongside HIVE_USER when Kerberos is not in use:
#       HIVE_LDAP_ENABLED=false (default) - HiveServer2 is using pass-through/NONE authentication, so the password value is not actually checked. The script sends HIVE_USER's own value as the password, purely to satisfy beeline's syntax.
#       HIVE_LDAP_ENABLED=true - HiveServer2 is backed by real LDAP authentication. HIVE_PASSWORD must be set to the real LDAP password for HIVE_USER; the script exits with an error if it is missing.
#     Default: HIVE_LDAP_ENABLED=false
#
#   INCREMENTAL_LOCK_DIR
#     Directory used to store a small per-database lock file so two incremental cycles for the same database can never run at the same time (for example, if this script is re-invoked before the previous run has finished).
#     Default: /var/tmp/hive-bdr-incremental-locks
#
#   BEELINE_VERBOSE
#     "true" or "false". When "true", every beeline call adds "--verbose=true" for extra JDBC/session detail - useful while diagnosing a hang or an unexpected failure.
#     Default: false
#
#   HEARTBEAT_INTERVAL_SECONDS
#     How often (in seconds) this script prints a "[HEARTBEAT] ... still running" line while a beeline statement (REPL DUMP/LOAD, status checks, etc.) is executing. beeline itself prints no progress output while a statement runs server-side, so this is what shows the script is still alive during a long DUMP/LOAD instead of going silent.
#     Default: 60
#
#   BEELINE_COMMAND_TIMEOUT_SECONDS
#     If set to a positive number, a beeline statement that runs longer than this many seconds is killed automatically, with a message pointing at likely causes (metastore lock, a stuck YARN data-copy job, or an unreachable remote cluster) to check next.
#     Default: 0 (disabled - statements run to completion no matter how long they take)
#
#   HIVE_REPL_SNAPSHOT_COPY
#     "true" or "false". When "true", REPL DUMP/LOAD use HDFS snapshot-diff based copying for external table data - only the blocks that changed since the last run are copied, instead of a full directory listing and copy every time. This is the recommended way to scale replication of large (for example, 1 TB or more) external tables. When enabled, the script automatically runs `hdfs dfsadmin -allowSnapshot` on the source external table directory before each DUMP; no manual snapshot setup is required.
#     Default: false
#
#   SNAP_LOCK_DIR
#     Directory used to store lock files that record which external table directories have already been made snapshot-capable, so the script does not repeat that setup on every run. Only used when HIVE_REPL_SNAPSHOT_COPY=true.
#     Default: /var/tmp/hive-bdr-snapshot-setup-locks
#
#   HIVE_EXTERNAL_WAREHOUSE_DIR
#     The base HDFS directory the source cluster uses for external tables that do not have an explicit LOCATION (Hive's `hive.metastore.warehouse.external.dir`). Used only to compute the source-side path that needs snapshot capability when HIVE_REPL_SNAPSHOT_COPY=true. Change this only if your source cluster uses a non-default external warehouse path.
#     Default: /warehouse/tablespace/external/hive
#
#   YARN_QUEUE
#     Also positional argument 6. The YARN Capacity Scheduler queue used for REPL LOAD's internal data-copy job on the destination cluster. Only affects REPL LOAD (REPL DUMP does not launch a YARN job).
#     Default: default
#
#   AUTO_DERIVE_HA_CLIENT_CONFIG
#     "yes" or "no". Normally, an HA nameservice must already be resolvable to HiveServer2 through the cluster's own hdfs-site.xml (configured once, cluster-wide, via Ambari or similar). Set this to "yes" to have the script instead inject the HA NameNode properties directly into every REPL DUMP/LOAD statement - useful when one cluster's hdfs-site.xml does not yet know about the other cluster's nameservice. Requires SRC_NN_HOSTS and DST_NN_HOSTS to be set.
#     Default: no
#
#   SRC_NN_HOSTS / DST_NN_HOSTS
#     Required when AUTO_DERIVE_HA_CLIENT_CONFIG=yes. Comma-separated "<nn-id>=<host>:<port>" pairs describing each cluster's NameNodes.
#     Example:
#       SRC_NN_HOSTS="nn1=prod-nn1.example.com:8020,nn2=prod-nn2.example.com:8020"
#       DST_NN_HOSTS="nn1=dr-nn1.example.com:8020,nn2=dr-nn2.example.com:8020"
#
#   AUTOMATIC_FAILOVER_ENABLED
#     "true" or "false". Only used when AUTO_DERIVE_HA_CLIENT_CONFIG=yes.
#     Default: true
#
#   HIVE_REPL_INCLUDE_MATERIALIZED_VIEWS
#     "true" or "false". When "true", materialized views are replicated along with regular tables. Left disabled by default because a replicated materialized view is copied as-is (its last-computed result), without triggering a rebuild on the destination - so it can silently fall out of sync with its base tables over time. Only enable this after confirming that behavior is acceptable for your use case.
#     Default: false
#
#   RECONCILE_EXTERNAL_DATA
#     Also positional argument 12. See "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" above for the full explanation.
#     Default: false
#
#   METADATA_ONLY
#     "true" or "false". Not a positional argument. When "true", every REPL DUMP/LOAD this script runs (bootstrap, incremental, failover) replicates Hive metastore metadata only - no table data (managed or external) is ever copied:
#       - DUMP sets 'hive.repl.dump.metadata.only.for.external.table'='true' instead of 'false' - Hive does not even write external-table file-list manifests into the dump.
#       - LOAD sets 'hive.repl.run.data.copy.tasks.on.target'='false' instead of 'true' - no data-copy YARN job runs on the load target for either managed or external tables.
#     Use this for a metadata-only DR catalog (schema/DDL parity without the storage cost/time of copying data), or to validate DUMP/LOAD mechanics quickly before committing to a full data replication run. Mutually exclusive with RECONCILE_EXTERNAL_DATA=true - that flag exists specifically to backfill real data via manual distcp after a metadata-only bootstrap LOAD, which contradicts METADATA_ONLY's "never copy data" intent. The script fails fast, before REPL DUMP/LOAD runs at all, if both are set to "true".
#     Default: false
#
#   DISTCP_OPTS
#     Tool-specific flags passed to the manual `hadoop distcp` calls this script runs when RECONCILE_EXTERNAL_DATA=true (see above). Not used for anything else - the normal bootstrap/incremental DUMP/LOAD flow never runs `hadoop distcp` itself; REPL LOAD performs its own internal data copy. Not a positional argument, since it is only relevant together with RECONCILE_EXTERNAL_DATA=true.
#     Default: "--strategy dynamic -direct -update -pugptx -skipcrccheck" (matches hadoop_dr_replication.sh's COPY_OPTS default)
#
# EXAMPLES
# ----------------------------------------------------------------------------
#   Example 1 - Bootstrap a single database, then keep it in sync by re-running this same command on a schedule (e.g. cron):
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
#   Example 3 - Replicate specific tables only, instead of a whole database:
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
#   Example 4 - Failover after the DR cluster has been promoted to primary (reverses replication direction so DR now dumps and the original primary now loads). Only the last argument changes from Example 1:
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
#   Example 5 - Ongoing replication in the reversed direction, after the Example 4 failover has converged (phase 3). New writes now land on DR and have to keep reaching the original primary. FAILOVER_MODE stays "false" - it cannot express this phase - and the direction is named explicitly. Prefix the invocation with:
#     REPLICATION_DIRECTION=dst_to_src DIRECTION_CHANGE=false
#   Equivalently, swap SRC/DST (all of nameservice + JDBC URL + NN_HOSTS on each side) and leave the direction alone - see "CHOOSING SOURCE AND DESTINATION" above. To fail back afterwards, use REPLICATION_DIRECTION=src_to_dst DIRECTION_CHANGE=true, and only then does a plain FAILOVER_MODE=false run mean what it did in Example 1:
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
#   This Example 4 / Example 5 pattern can be repeated indefinitely for any number of failover / failback cycles.
#
#   Example 6 - Bootstrap a database whose load-target already has pre-existing/partial HDFS data for its (all-external) tables, without re-copying data that is already correct. Only the last argument changes from Example 1 - see "RECONCILING PRE-EXISTING EXTERNAL TABLE DATA" above before using this:
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

# ------------------------------------------------------------------------------
#  Interrupt/termination cleanup.
#
#  run_with_heartbeat() below launches beeline (or hdfs/hadoop distcp) as a
#  BACKGROUND child ("$@" &) so it can poll it and print heartbeat lines.
#  Backgrounding a command does NOT put it under bash's automatic child-
#  reaping-on-exit behavior: if this script itself is interrupted (Ctrl-C)
#  or otherwise terminated while a child is running, bash does NOT kill
#  that child for you - it is simply orphaned and keeps running
#  independently, forever, or until whatever it was doing finishes or hangs
#  on its own. Confirmed via testing: multiple Ctrl-C'd runs each left
#  their own orphaned beeline/java process running in the background,
#  every one of them still holding an open connection (and potentially a
#  lock) against HiveServer2/the metastore, long after the script itself
#  had exited and returned control to the terminal.
#
#  CURRENT_CHILD_PID is set by run_with_heartbeat() for the duration of
#  whatever child it is currently tracking (empty otherwise). This trap
#  ensures that child is actually killed - first SIGTERM, then SIGKILL if
#  it has not exited after a short grace period - before this script
#  itself exits for any reason (a signal, or any other termination path).
# ------------------------------------------------------------------------------
CURRENT_CHILD_PID=""

on_terminate() {
  local sig="$1"
  if [[ -n "$CURRENT_CHILD_PID" ]] && kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; then
    echo "" >&2
    echo "[WARN] Received ${sig} - terminating in-flight child process (pid ${CURRENT_CHILD_PID})..." >&2
    kill -TERM "$CURRENT_CHILD_PID" 2>/dev/null || true
    sleep 2
    if kill -0 "$CURRENT_CHILD_PID" 2>/dev/null; then
      echo "[WARN] pid ${CURRENT_CHILD_PID} did not exit after SIGTERM - sending SIGKILL" >&2
      kill -KILL "$CURRENT_CHILD_PID" 2>/dev/null || true
    fi
  fi
  exit 130
}
trap 'on_terminate SIGINT' INT
trap 'on_terminate SIGTERM' TERM
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

# ------------------------------------------------------------------------------
#  REPLICATION_DIRECTION / DIRECTION_CHANGE - the two variables that describe a
#  run's direction and whether it flips which side is primary. NOT positional
#  arguments: environment/in-file variables only, the same pattern as
#  METADATA_ONLY and DISTCP_OPTS below. See "FAILOVER AND FAILBACK" near the top
#  of this file for the four-phase table.
#
#  Both default to empty, meaning "derive me from FAILOVER_MODE", so every
#  existing invocation behaves exactly as it always has. Set them only for the
#  two phases FAILOVER_MODE cannot express:
#
#    phase 3, ongoing replication DR -> Primary : dst_to_src + false
#    phase 4, failback: promote Primary back    : src_to_dst + true
#
#  Two equivalent ways to set them - per-run on the command line:
#
#    REPLICATION_DIRECTION=dst_to_src DIRECTION_CHANGE=false ./this_script.sh <db> ...
#
#  or pinned for every run by uncommenting the two lines immediately below,
#  exactly the way SRC_NN_HOSTS/DST_NN_HOSTS are pinned further down. Both are
#  written in "${VAR:-value}" form so an environment variable of the same name
#  still wins over the pinned value - a plain `VAR="value"` here would silently
#  clobber the environment instead, which would make a UI/wrapper that exports
#  these look like it was being ignored.
#
#  *** WHILE THESE TWO ARE UNCOMMENTED, FAILOVER_MODE IS IGNORED. ***
#  FAILOVER_MODE is only consulted to DERIVE these values, and derivation is
#  skipped entirely once they are non-empty. So a pinned "dst_to_src"/"false"
#  means every run is ongoing reverse replication no matter how FAILOVER_MODE is
#  set - a "Failover Mode = true" toggle in a wrapper UI will appear to do
#  nothing. Re-comment both lines to hand control back to FAILOVER_MODE.
#
#  Uncomment for phase 3 (ongoing DR -> Primary):
#REPLICATION_DIRECTION="${REPLICATION_DIRECTION:-dst_to_src}"
#DIRECTION_CHANGE="${DIRECTION_CHANGE:-false}"
#  ...or for phase 4 (failback, promote Primary back) use these two instead:
#REPLICATION_DIRECTION="${REPLICATION_DIRECTION:-src_to_dst}"
#DIRECTION_CHANGE="${DIRECTION_CHANGE:-true}"
# ------------------------------------------------------------------------------

# METADATA_ONLY - "true" or "false" (default: false). Not a positional
# argument - environment-only, same pattern as DISTCP_OPTS below. When
# "true", every REPL DUMP/LOAD this script runs (bootstrap, incremental,
# failover) replicates Hive metastore metadata only - no table data
# (managed or external) is ever copied:
#   - DUMP sets 'hive.repl.dump.metadata.only.for.external.table'='true'
#     instead of 'false' - Hive does not even write external-table
#     file-list manifests into the dump.
#   - LOAD sets 'hive.repl.run.data.copy.tasks.on.target'='false' instead
#     of 'true' - no data-copy YARN job runs on the load target for either
#     managed or external tables.
# Mutually exclusive with RECONCILE_EXTERNAL_DATA=true - that flag exists
# specifically to backfill real data via manual distcp after a
# metadata-only bootstrap LOAD, which contradicts METADATA_ONLY's "never
# copy data" intent. The script fails fast, before REPL DUMP/LOAD runs at
# all, if both are set to "true".
# Example: METADATA_ONLY=true ./hive_bdr.sh ...
METADATA_ONLY="${METADATA_ONLY:-false}"

if [[ "${METADATA_ONLY,,}" == "true" && "${RECONCILE_EXTERNAL_DATA,,}" == "true" ]]; then
  echo "[ERROR] METADATA_ONLY=true and RECONCILE_EXTERNAL_DATA=true are mutually exclusive - RECONCILE_EXTERNAL_DATA backfills real data after a metadata-only LOAD, which contradicts METADATA_ONLY's 'never copy data' intent. Set RECONCILE_EXTERNAL_DATA=false (or omit it) when using METADATA_ONLY=true." >&2
  exit 1
fi

# DISTCP_OPTS - tool-specific `hadoop distcp` flags used only by the manual
# distcp calls this script runs when RECONCILE_EXTERNAL_DATA=true (see
# reconcile_external_table_data() below). Not a positional argument - only
# relevant together with RECONCILE_EXTERNAL_DATA=true, and every other
# environment-only setting in this script (HIVE_REPL_SNAPSHOT_COPY,
# AUTO_DERIVE_HA_CLIENT_CONFIG, etc.) follows the same env-var-only pattern for
# settings that are not part of the common/required call shape.
# "-update"/"-skipcrccheck" are what make distcp genuinely compare source
# vs. destination and skip files that already match - this is the actual
# mechanism that avoids re-copying pre-existing, unchanged data. The full
# default below matches hadoop_dr_replication.sh's COPY_OPTS default
# exactly, for consistency between this script's manual distcp and that
# script's: "-strategy dynamic" rebalances file assignment across mappers
# as the job runs (instead of a fixed static split up front), "-direct"
# writes straight to the final destination path instead of via a temp
# location, and "-pugptx" preserves permissions/user/group/checksum-type/
# timestamp/xattr from source to destination.
DISTCP_OPTS="${DISTCP_OPTS:---strategy dynamic -direct -update -pugptx -skipcrccheck}"

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

# Recorded BEFORE the default below fills it in: the DIRECTION_CHANGE
# ambiguity check further down has to tell "the operator named this
# direction themselves" apart from "we derived it from FAILOVER_MODE".
if [[ -n "$REPLICATION_DIRECTION" ]]; then
  REPLICATION_DIRECTION_EXPLICIT=true
else
  REPLICATION_DIRECTION_EXPLICIT=false
fi

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

# ------------------------------------------------------------------------------
#  DIRECTION_CHANGE - "true" or "false" (default: derived from FAILOVER_MODE).
#
#  Answers a question that is INDEPENDENT of REPLICATION_DIRECTION: is this
#  run a one-off handshake that flips which cluster is primary (a failover or
#  a failback), or is it ongoing replication in whatever direction is already
#  in force?
#
#  This used to be inferred from REPLICATION_DIRECTION alone - "dst_to_src"
#  meant failover, "src_to_dst" meant normal replication - which conflated
#  the two questions and left two of the four real states unreachable:
#
#    direction    change  meaning                             reachable before
#    ----------   ------  ---------------------------------   ----------------
#    src_to_dst   false   ongoing replication SRC -> DST      yes
#    dst_to_src   true    failover: promote DST to primary    yes
#    dst_to_src   false   ongoing replication DST -> SRC      NO
#    src_to_dst   true    failback: promote SRC back          NO
#
#  The two missing states are exactly what a real DR lifecycle needs once a
#  failover has actually completed: new writes land on the promoted cluster
#  and must keep flowing back to the demoted one (dst_to_src + false), and
#  eventually the roles have to be handed back (src_to_dst + true).
#
#  Confirmed via live testing that neither could be faked with the two
#  settings that did exist:
#    - FAILOVER_MODE=true aborts at preflight_check_direction_change(), and
#      correctly so: after a converged failover the promoted cluster is a
#      PRIMARY, and Hive clears its repl.last.id, so it is no longer the
#      "caught-up replica" that a direction change requires.
#    - FAILOVER_MODE=false dumps from the demoted cluster - which is now the
#      replica - and, because repl_root_suffix is per-direction, points at a
#      rootdir with no dump history at all. Hive finds no previous dump to
#      compute an increment against, falls back to a BOOTSTRAP dump, and the
#      load target rejects it: "Bootstrap REPL LOAD is not allowed on
#      Database: <db> as it was already done" (ReplLoadTask, return code
#      40000). NOTE this describes the state of things when the staging suffix
#      was keyed to the DIRECTION; it is now keyed to the dumping CLUSTER, so
#      swapping SRC/DST is a supported alternative route to the reversed
#      direction rather than a trap - see "CHOOSING SOURCE AND DESTINATION" at
#      the top of this file. What is still true, and is what this flag exists
#      for, is that FAILOVER_MODE alone cannot express either phase 3 or
#      phase 4.
#
#  BACKWARD COMPATIBILITY: when DIRECTION_CHANGE is not set explicitly it is
#  derived from FAILOVER_MODE exactly as the old behavior did, so every
#  existing invocation - positional or environment - behaves identically.
#  The one case that cannot be derived safely is an explicit
#  REPLICATION_DIRECTION=dst_to_src with no FAILOVER_MODE and no
#  DIRECTION_CHANGE: before this flag existed that meant "failover", but
#  deriving "false" from the FAILOVER_MODE default would now silently turn it
#  into ongoing reverse replication instead. That combination is rejected
#  rather than guessed at.
# ------------------------------------------------------------------------------
DIRECTION_CHANGE="${DIRECTION_CHANGE:-}"
if [[ -z "$DIRECTION_CHANGE" ]]; then
  if [[ "$REPLICATION_DIRECTION_EXPLICIT" == true ]] \
     && [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]] \
     && [[ "${FAILOVER_MODE,,}" != "true" ]]; then
    echo "[ERROR] REPLICATION_DIRECTION=dst_to_src was set explicitly but DIRECTION_CHANGE was not." >&2
    echo "[ERROR] These are two different runs and the script will not guess between them:" >&2
    echo "[ERROR]   DIRECTION_CHANGE=true   -> failover: promote DST to primary (was FAILOVER_MODE=true)" >&2
    echo "[ERROR]   DIRECTION_CHANGE=false  -> ongoing replication DST -> SRC after a completed failover" >&2
    exit 1
  fi
  if [[ "${FAILOVER_MODE,,}" == "true" ]]; then
    DIRECTION_CHANGE=true
  else
    DIRECTION_CHANGE=false
  fi
fi
case "${DIRECTION_CHANGE,,}" in
  true|false) DIRECTION_CHANGE="${DIRECTION_CHANGE,,}" ;;
  *)
    echo "[ERROR] DIRECTION_CHANGE must be 'true' or 'false' (got: '${DIRECTION_CHANGE}')" >&2
    exit 1
    ;;
esac

# DIRECTION_CHANGE_KIND - purely for log/CSV wording. A direction change
# toward DST is a failover; a direction change back toward SRC is a failback.
if [[ "$DIRECTION_CHANGE" == true ]]; then
  if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
    DIRECTION_CHANGE_KIND="Failover"
  else
    DIRECTION_CHANGE_KIND="Failback"
  fi
else
  DIRECTION_CHANGE_KIND=""
fi

# FAILOVER_MAX_ROUNDS - how many DUMP -> LOAD rounds a single direction-change
# invocation will attempt before giving up. Hive's direction change is a
# MULTI-ROUND handshake, not one statement pair, and the round count is not
# something an operator should have to know:
#   round 1 - REPL DUMP returns last_repl_id=-1 and writes an "event_ack"
#             file; the matching REPL LOAD runs with numEvents:0 and records
#             the control state ("last failover type ... UNPLANNED",
#             "failover count ... 1"). REPL STATUS on the new replica is
#             still NULL - nothing has been loaded into it yet.
#   round 2 - REPL DUMP now returns a real INCREMENTAL dump on the new
#             primary's OWN event numbering, and the REPL LOAD applies it as
#             INCREMENTAL plus an inner BOOTSTRAP of the table diff. REPL
#             STATUS on the new replica becomes a real id: converged.
#   round 3 - would abort at the pre-flight, because by then the new primary
#             is no longer a replica. That is the natural stop, and the
#             default of 3 leaves exactly one round of headroom over the two
#             that a clean failover needs.
FAILOVER_MAX_ROUNDS="${FAILOVER_MAX_ROUNDS:-3}"
if ! [[ "$FAILOVER_MAX_ROUNDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "[ERROR] FAILOVER_MAX_ROUNDS must be a positive integer (got: '${FAILOVER_MAX_ROUNDS}')" >&2
  exit 1
fi

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
# A direction change copies no external table data by either mechanism (see
# EFFECTIVE_RECONCILE_EXTERNAL_DATA and load_data_copy_prop below), so
# snapshot-diff copy has nothing to accelerate on such a run whichever
# direction it points. Caught separately from the check just above so a
# src_to_dst FAILBACK is covered too.
if [[ "$DIRECTION_CHANGE" == true && "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
  echo "[WARN] DIRECTION_CHANGE=true (${DIRECTION_CHANGE_KIND}) - forcing HIVE_REPL_SNAPSHOT_COPY=false (a direction change copies no table data)"
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
# SRC_NAMESERVICE/DST_NAMESERVICE/SRC_JDBC_URL/DST_JDBC_URL/SRC_NN_HOSTS/
# DST_NN_HOSTS label the two clusters for this invocation - see "CHOOSING
# SOURCE AND DESTINATION" at the top of this file; they may be kept fixed for
# the lifetime of a setup or swapped between deployments, as long as all of one
# side's values are swapped together. This function derives which cluster is
# actually the DUMP source and which is the LOAD target for the CURRENT run,
# based on REPLICATION_DIRECTION.
derive_db_vars() {
  local spec="$1"
  if [[ "$spec" == *.* ]]; then
    HIVE_DB_NAME="${spec%%.*}"
    HIVE_TABLE_PATTERN="${spec#*.}"
    # REPL DUMP's table-level grammar takes <db_name>.'<table_pattern>' -
    # dot-joined, with the table pattern as its own quoted StringLiteral.
    # Confirmed directly against HiveServer2 (Hive 4.0.1) via beeline:
    #   REPL DUMP db 'table' WITH(...)   -> ParseException: missing EOF
    #                                        at ''table'' near 'db'
    #   REPL DUMP db.'table' WITH(...)   -> succeeds
    # A multi-table regex (e.g. "sales.'(orders|customers)'") must already
    # be single-quoted by the caller - that is what protects its "|" from
    # being treated as a database separator by parse_db_specs() above. If
    # HIVE_TABLE_PATTERN is already wrapped in a matching pair of single
    # quotes, use it as-is; only add quotes here for a bare, unquoted
    # single table name (e.g. "sales.orders"), so it is never quoted twice.
    if [[ "$HIVE_TABLE_PATTERN" == \'*\' ]]; then
      HIVE_REPL_SPEC="${HIVE_DB_NAME}.${HIVE_TABLE_PATTERN}"
    else
      HIVE_REPL_SPEC="${HIVE_DB_NAME}.'${HIVE_TABLE_PATTERN}'"
    fi
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
    DUMP_NN_HOSTS="$DST_NN_HOSTS"
    LOAD_NN_HOSTS="$SRC_NN_HOSTS"
    DUMP_ROOT_TOKEN="$DST_ROOT_TOKEN"
  else
    DUMP_NAMESERVICE="$SRC_NAMESERVICE"
    LOAD_NAMESERVICE="$DST_NAMESERVICE"
    DUMP_JDBC_URL="$SRC_JDBC_URL"
    LOAD_JDBC_URL="$DST_JDBC_URL"
    DUMP_NN_HOSTS="$SRC_NN_HOSTS"
    LOAD_NN_HOSTS="$DST_NN_HOSTS"
    DUMP_ROOT_TOKEN="$SRC_ROOT_TOKEN"
  fi

  # ----------------------------------------------------------------------------
  #  DUMP_URI_NS / LOAD_URI_NS - the names actually used in every "hdfs://" URI
  #  and WITH()-clause HA property this script builds. In the normal
  #  (non-colliding) case these are just DUMP_NAMESERVICE/LOAD_NAMESERVICE
  #  unchanged. When SAME_NAMESERVICE_COLLISION is true, BOTH become
  #  synthetic, script-internal aliases ("<name>-DUMPALIAS" / "<name>-LOADALIAS")
  #  - the real nameservice name is never renamed on either cluster; the
  #  aliases only ever appear in THIS script's own injected WITH()-clause/"-D"
  #  properties and the URIs it builds, both of which are process-local and
  #  thrown away when the script exits.
  #
  #  WHY BOTH SIDES NEED ALIASING HERE (unlike the sibling HDFS script's fix,
  #  which only aliases ONE side): REPL DUMP and REPL LOAD execute as TWO
  #  SEPARATE HiveServer2 sessions - one on the dump-side cluster, one on the
  #  load-side cluster - and the IDENTICAL WITH()-clause property text (in
  #  particular 'hive.repl.rootdir' and 'hive.repl.replica.external.table.base.dir')
  #  is sent to BOTH sessions verbatim, since REPL LOAD must read from the
  #  exact same rootdir REPL DUMP wrote to, and REPL DUMP itself is told the
  #  eventual external-table relocation base dir up front. Each of those two
  #  properties therefore needs to resolve correctly when interpreted by
  #  EITHER session:
  #    - 'hive.repl.rootdir' (DUMP's own staging area) resolves trivially on
  #      the dump-side session (it is that session's own cluster) but is a
  #      genuine cross-cluster reference from the load-side session's point of
  #      view - the load-side session's own native "ODP-Phoenix" means ITSELF,
  #      not the dump side, so a bare, unaliased name here would make REPL
  #      LOAD read from (or fail to find) its own local filesystem instead of
  #      the real dump side.
  #    - 'hive.repl.replica.external.table.base.dir' (LOAD's relocation root)
  #      has the exact same problem in reverse: trivial for the load-side
  #      session, a genuine cross-cluster reference for the dump-side session.
  #  Using ONE FIXED alias string per role, injected with that role's real
  #  NameNode addresses into BOTH sessions' WITH() clause (see
  #  ha_config_props() below), makes both properties resolve correctly
  #  regardless of which session is doing the resolving. The real, literal
  #  shared name (SRC_NAMESERVICE, identical to DST_NAMESERVICE in the
  #  collision case) is DELIBERATELY NEVER overridden itself (no
  #  "dfs.namenode.rpc-address.<real-name>.*"/"dfs.ha.namenodes.<real-name>"
  #  override is ever injected) - each session's own unrelated operations
  #  (reading its own warehouse tables, whose LOCATION values Hive itself
  #  reports using that literal real name) must keep resolving it via that
  #  session's own native, cluster-wide hdfs-site.xml, exactly as they always
  #  have. It is, however, still explicitly RE-LISTED (unaliased) in
  #  'dfs.nameservices' wherever that property is injected at all - omitting
  #  it there would silently break resolution of the session's OWN native
  #  identity, the same class of bug already confirmed (and fixed) in the
  #  sibling HDFS script: injecting "dfs.nameservices" REPLACES rather than
  #  merges with whatever the session's own native hdfs-site.xml already
  #  defines for that property, and Hadoop-internal code that needs to
  #  resolve the session's own default filesystem consults "dfs.nameservices"
  #  to decide whether a name is even a registered HA nameservice at all -
  #  dropping the real name from the list breaks that resolution even though
  #  the underlying "dfs.ha.namenodes.<real-name>"/rpc-address keys are still
  #  present (inherited, untouched) from the native config.
  #
  #  DUMP_NN_HOSTS/LOAD_NN_HOSTS (set above) are always the REAL NameNode
  #  addresses for whichever PHYSICAL cluster is currently playing that role -
  #  re-derived from SRC_NN_HOSTS/DST_NN_HOSTS every time derive_db_vars()
  #  runs, based on REPLICATION_DIRECTION, exactly parallel to how
  #  DUMP_NAMESERVICE/LOAD_NAMESERVICE are re-derived from SRC_NAMESERVICE/
  #  DST_NAMESERVICE above. A failover/failback role reversal needs no operator
  #  special-casing at all: whichever alias currently means "DUMP_URI_NS" is
  #  simply rebound to whichever physical cluster is now actually dumping.
  #
  #  SRC_NN_HOSTS/DST_NN_HOSTS may be swapped between deployments (see
  #  "CHOOSING SOURCE AND DESTINATION" at the top of this file), but ONLY
  #  together with that same side's SRC_NAMESERVICE/SRC_JDBC_URL - all of one
  #  side's values move or none do. Swapping the NN hosts alone, or the JDBC
  #  URLs alone, half-swaps against this function's role assignment above: the
  #  session that runs REPL DUMP ends up on one cluster while DUMP_NN_HOSTS -
  #  and therefore every alias binding and every "hdfs://" URI built from it -
  #  points at the other. Confirmed via live testing: that combination wrote a
  #  dump to one cluster while the load side looked for it on the other, and
  #  REPL LOAD silently did nothing (0 locks, sub-second, no REPL::START).
  # ----------------------------------------------------------------------------
  if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
    DUMP_URI_NS="${DUMP_NAMESERVICE}-DUMPALIAS"
    LOAD_URI_NS="${LOAD_NAMESERVICE}-LOADALIAS"
  else
    DUMP_URI_NS="$DUMP_NAMESERVICE"
    LOAD_URI_NS="$LOAD_NAMESERVICE"
  fi

  # HDFS_TOKEN_EXCLUDE_PROP - see the comment at its original computation
  # site (now removed) near HA_ENABLED, above. Recomputed every time this
  # function runs (idempotent - always the same value within one invocation,
  # since REPLICATION_DIRECTION never changes mid-run) so it can reference
  # DUMP_URI_NS/LOAD_URI_NS, which are only known once derived above.
  # SAME-NAMESERVICE COLLISION CASE: must exclude DUMP_URI_NS/LOAD_URI_NS
  # (the aliases), NOT the raw SRC_NAMESERVICE/DST_NAMESERVICE - those raw
  # names are never the authority in any "hdfs://" URI this script builds
  # once aliasing is active, so excluding them would exclude nothing real,
  # leaving the actual authorities (the aliases) subject to token renewal by
  # a ResourceManager that cannot renew a token for a synthetic name that
  # exists only in this script's own injected properties.
  if [[ "$HA_ENABLED" == true ]]; then
    if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
      HDFS_TOKEN_EXCLUDE_PROP="'mapreduce.job.hdfs-servers.token-renewal.exclude'='${DUMP_URI_NS},${LOAD_URI_NS}',"
    else
      HDFS_TOKEN_EXCLUDE_PROP="'mapreduce.job.hdfs-servers.token-renewal.exclude'='${SRC_NAMESERVICE},${DST_NAMESERVICE}',"
    fi
  else
    HDFS_TOKEN_EXCLUDE_PROP=""
  fi

  # The REPL DUMP staging directory is suffixed with a per-direction token
  # (for example .../repl/sales/from_prod-nameservice), so each direction has
  # its own independent, persistent staging path. This keeps repeated
  # failover/failback cycles from ever reusing (and colliding with) a
  # staging directory left over from the opposite direction. The path is
  # stable and reused across repeated runs in the SAME direction - only a
  # direction change moves to a different path.
  #
  # THE SUFFIX IDENTIFIES THE DUMPING CLUSTER, NEVER THE DIRECTION LABEL.
  # That distinction is what makes the staging path survive an operator
  # swapping SRC/DST between runs, which is a supported way to drive the
  # reversed direction (see "CHOOSING SOURCE AND DESTINATION" at the top of
  # this file). The non-collision branch below already had this property for
  # free - DUMP_NAMESERVICE is the dumping cluster's own identity, so
  # "dr-nameservice dumping" yields "from_dr-nameservice" whether that run
  # calls itself src_to_dst or dst_to_src.
  #
  # SAME-NAMESERVICE COLLISION CASE: DUMP_NAMESERVICE is useless here - it is
  # the identical string for both clusters - and DUMP_URI_NS is no better,
  # since it is a FIXED alias whose role never changes ("...-DUMPALIAS"
  # regardless of which physical cluster is bound to it). This branch used to
  # substitute REPLICATION_DIRECTION, which does differ between directions but
  # is a property of the RUN, not of the CLUSTER - so swapping SRC/DST moved
  # the staging path even though the same physical cluster was still dumping.
  # Confirmed via live testing: a swapped run pointed at a brand-new empty
  # rootdir, Hive found no previous dump to compute an increment against, fell
  # back to a BOOTSTRAP dump, and the load target rejected it with "Bootstrap
  # REPL LOAD is not allowed on Database: <db> as it was already done"
  # (return code 40000).
  #
  # DUMP_ROOT_TOKEN (derived from the dumping cluster's own NameNode hostnames
  # by nn_hosts_short_token(), computed once at startup) restores the same
  # cluster-identity property the non-collision branch has: odplab dumping is
  # always "from_odplab001" and atlasdemo dumping is always "from_atlasdemo-01",
  # in either direction, with or without a swap.
  #
  # REPL_ROOT_SUFFIX overrides all of this when set - the escape hatch for
  # pointing a run at a pre-existing staging path (notably a legacy
  # "from_src_to_dst"/"from_dst_to_src" directory created before this change).
  local repl_root_suffix
  if [[ -n "$REPL_ROOT_SUFFIX" ]]; then
    repl_root_suffix="$REPL_ROOT_SUFFIX"
  elif [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
    repl_root_suffix="$DUMP_ROOT_TOKEN"
  else
    repl_root_suffix="$DUMP_NAMESERVICE"
  fi
  REPL_ROOT_DIR_SRC="hdfs://${DUMP_URI_NS}${REPL_BASE_DIR}${HIVE_DB_NAME}/from_${repl_root_suffix}"
  # REPL LOAD must read from the exact same location REPL DUMP wrote to.
  REPL_ROOT_DIR_DST="${REPL_ROOT_DIR_SRC}"

  # Base directory on the LOAD target for replicated external table data.
  # DELIBERATELY uses the RAW LOAD_NAMESERVICE, NEVER LOAD_URI_NS (the
  # alias) - even in the same-nameservice-collision case. This value gets
  # baked PERMANENTLY into every replicated external table's LOCATION
  # metadata (hive.repl.replica.external.table.base.dir controls the "new
  # location" REPL LOAD computes and persists), and that LOCATION is later
  # resolved by the Hive METASTORE SERVER process itself - a separate JVM
  # from HiveServer2, with its own static hdfs-site.xml loaded once at
  # daemon startup. WITH()-clause properties are per-query values on the
  # HiveServer2 CLIENT's Configuration; they are never transmitted to the
  # Metastore server over the Thrift RPC, so the alias is something the
  # Metastore process can never resolve. Confirmed via live testing: with
  # the alias baked into LOCATION, the Metastore's own
  # StorageBasedAuthorizationProvider pre-event listener (which checks
  # HDFS permissions on the new table's LOCATION as part of CREATE TABLE)
  # hung indefinitely trying to open a TCP connection to
  # "ODP-Phoenix-LOADALIAS" as a literal, unresolvable hostname - a name
  # that exists ONLY inside HiveServer2's per-query Configuration, never in
  # any daemon's own config. The raw name has no such problem: it is the
  # LOAD side's own genuine nameservice, natively resolvable by the
  # Metastore's own hdfs-site.xml (it is literally running on that
  # cluster) - and by every future query against this table, forever
  # after, not just this one REPL LOAD statement. This is safe precisely
  # because this property is only actually consumed by the LOAD-side
  # session (confirmed: the "new location" computation happens in the same
  # thread executing REPL LOAD, never REPL DUMP), where the raw name
  # already and unambiguously means "this cluster itself" - no cross-
  # cluster confusion is possible for a value that is only ever read by
  # the side it natively belongs to.
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

# AUTO_DERIVE_HA_CLIENT_CONFIG must be defaulted before the collision check just
# below can read it - under `set -u`, "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" on a
# never-set variable is an unbound-variable error, not an empty string, so
# this cannot wait until the full AUTO_DERIVE_HA_CLIENT_CONFIG section further
# down (which still runs too, harmlessly re-applying the same default).
AUTO_DERIVE_HA_CLIENT_CONFIG="${AUTO_DERIVE_HA_CLIENT_CONFIG:-no}"

# ------------------------------------------------------------------------------
#  SAME_NAMESERVICE_COLLISION - true iff SRC_NAMESERVICE and DST_NAMESERVICE
#  are the literal identical string (e.g. both "ODP-Phoenix", because the DR
#  cluster was built from the same Ambari/CM blueprint as production). A
#  single Hadoop Configuration/HiveServer2 session cannot bind two different
#  NameNode sets to one nameservice name at the same time, so every "hdfs://"
#  URI and every WITH()-clause HA property this script builds needs to
#  disambiguate the two physical clusters whenever this is true - see the
#  DUMP_URI_NS/LOAD_URI_NS derivation inside derive_db_vars() below, and the
#  collision-aware branch inside ha_config_props()/build_nameservice_ha_props()
#  further down, for the actual fix. Mirrors the equivalent
#  SAME_NAMESERVICE_COLLISION fix already applied to the sibling
#  hadoop_dr_replication_4.2.0.sh script for its own pull-based HDFS
#  replication - the underlying ambiguity is the same, but the fix looks
#  different here because Hive's REPL DUMP/REPL LOAD execute as TWO SEPARATE
#  HiveServer2 sessions (one per physical cluster) that both receive the
#  IDENTICAL WITH()-clause property text, rather than one single driver JVM
#  building both sides' URIs itself - see the comments at each fix site for
#  why BOTH sides need aliasing here, not just one.
#
#  Requires AUTO_DERIVE_HA_CLIENT_CONFIG=yes with SRC_NN_HOSTS/DST_NN_HOSTS set:
#  aliasing only fixes the ambiguity if this script is ALSO the thing
#  supplying each alias's real NameNode addresses via injected WITH()-clause/
#  "-D" properties. Without that, an alias would resolve nowhere (no
#  hdfs-site.xml on earth defines a synthetic alias name), so this fails
#  fast here instead of letting every later beeline/hdfs/distcp call hang or
#  error deep inside a replication cycle.
# ------------------------------------------------------------------------------
if [[ "$SRC_NAMESERVICE" == "$DST_NAMESERVICE" ]]; then
  SAME_NAMESERVICE_COLLISION=true
  if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]]; then
    echo "[ERROR] SRC_NAMESERVICE and DST_NAMESERVICE are identical: '${SRC_NAMESERVICE}'" >&2
    echo "[ERROR] This is only supported when the two are the SAME nameservice name shared by two" >&2
    echo "[ERROR] DIFFERENT physical clusters (e.g. a DR cluster built from the same blueprint as" >&2
    echo "[ERROR] production) - and even then, this script needs AUTO_DERIVE_HA_CLIENT_CONFIG=yes with" >&2
    echo "[ERROR] SRC_NN_HOSTS/DST_NN_HOSTS set so it can tell the two clusters apart internally." >&2
    echo "[ERROR] Set those three variables, or pass distinct nameservice names / host:port values" >&2
    echo "[ERROR] for SRC_NAMESERVICE (arg 2) and DST_NAMESERVICE (arg 3)." >&2
    exit 1
  fi
  if [[ "$HA_ENABLED" != true ]]; then
    echo "[ERROR] SRC_NAMESERVICE and DST_NAMESERVICE are identical ('${SRC_NAMESERVICE}') but HA_ENABLED is" >&2
    echo "[ERROR] false (one of them looked like a 'host:port' value). A same-nameservice collision only" >&2
    echo "[ERROR] makes sense for two genuine HA nameservice NAMES - a bare host:port is already an" >&2
    echo "[ERROR] unambiguous, concrete address and cannot collide with anything." >&2
    exit 1
  fi
else
  SAME_NAMESERVICE_COLLISION=false
fi

# ------------------------------------------------------------------------------
#  EFFECTIVE_RECONCILE_EXTERNAL_DATA - whether external table data copy for
#  THIS run must go through the manual, alias-aware distcp path
#  (check_all_tables_external() + reconcile_external_table_data()) instead of
#  Hive's own internal REPL LOAD data copy ('hive.repl.run.data.copy.tasks.
#  on.target'='true').
#
#  This is "true" whenever the user explicitly asked for it
#  (RECONCILE_EXTERNAL_DATA=true), OR whenever SAME_NAMESERVICE_COLLISION is
#  true - REGARDLESS of what RECONCILE_EXTERNAL_DATA was passed as. Confirmed
#  via live testing: in the collision case, Hive's own internal data-copy
#  task resolves each external table's LOCATION using the raw, un-aliased
#  shared nameservice name exactly as recorded (verbatim) in the dump
#  metadata - and on the LOAD-side session, that raw name deliberately
#  resolves to the LOAD side's OWN native cluster (never overridden, by
#  design - see DUMP_URI_NS/LOAD_URI_NS's doc comment - so the session's own
#  unrelated native operations keep working). There is no way to make a
#  single Hadoop Configuration resolve one raw name two different ways in
#  the same session, so Hive's internal copy step structurally cannot find
#  the real source files: it lists zero files under the (wrong, local)
#  path and "succeeds" without copying anything ("number of splits:0"),
#  silently leaving the destination with no external table data at all.
#  This is forced on for every NORMAL-DIRECTION external-data-copying call
#  site (bootstrap, incremental) - each one submits its own REPL LOAD and
#  would independently hit the identical bug otherwise.
#
#  TWO CASES TAKE PRIORITY AND DISABLE THIS ENTIRELY:
#
#  1. METADATA_ONLY=true - if the run isn't copying any table data in the
#     first place, the bug above never triggers, so there is nothing to
#     route through the manual path.
#
#  2. DIRECTION_CHANGE=true (a failover or a failback) - a direction-change
#     run is a CONTROL operation that flips which side is primary, not a bulk
#     data movement. By the time one is run, every preceding cycle in the
#     direction being reversed FROM has already copied the data to the side
#     that is about to become the new replica, so at flip time that side
#     already holds it - there is nothing for a per-table distcp to move, and
#     running one would re-walk every file in every table of every database
#     purely to confirm that. Disabling this here also removes the
#     check_all_tables_external() pre-flight and the
#     reconcile_external_table_data() call from failover_one_db(), both of
#     which are gated on this same value. load_data_copy_prop() separately
#     forces Hive's OWN internal copy off for the same runs (see its doc
#     comment), so a direction-change REPL LOAD copies no external table data
#     by either mechanism - deliberately, and it says so in the log.
#
#     KEYED ON DIRECTION_CHANGE, NOT ON REPLICATION_DIRECTION. This condition
#     used to read `REPLICATION_DIRECTION == dst_to_src`, which was correct
#     only as long as "reversed direction" and "failover" were the same thing.
#     They are not: ongoing replication in the reversed direction
#     (dst_to_src + DIRECTION_CHANGE=false, i.e. the cycles that run after a
#     failover has completed) is genuine bulk data movement and MUST copy
#     data. Leaving this keyed on direction would have silently replicated
#     metadata while never moving a byte - repl.last.id advancing on the
#     replica, tables looking present, no data underneath. That is the worst
#     possible failure shape for a DR tool, which is why the split exists.
#
#     This is checked BEFORE the SAME_NAMESERVICE_COLLISION branch below:
#     the collision only forces the manual path on because Hive's internal
#     copy is broken in that scenario, which is irrelevant on a run that is
#     not copying data by either mechanism to begin with.
# ------------------------------------------------------------------------------
# RECONCILE_ON_DIRECTION_CHANGE must be defaulted before the branch just below
# can read it - under `set -u`, "${RECONCILE_ON_DIRECTION_CHANGE,,}" on a
# never-set variable is an unbound-variable error, not an empty string, so this
# cannot wait for its own fully-documented section further down (which still
# runs too, harmlessly re-applying the same default). Same pattern, and same
# reason, as AUTO_DERIVE_HA_CLIENT_CONFIG's early default above.
RECONCILE_ON_DIRECTION_CHANGE="${RECONCILE_ON_DIRECTION_CHANGE:-true}"

if [[ "${METADATA_ONLY,,}" == "true" ]]; then
  EFFECTIVE_RECONCILE_EXTERNAL_DATA=false
elif [[ "$DIRECTION_CHANGE" == true && "${RECONCILE_ON_DIRECTION_CHANGE,,}" != "true" ]]; then
  EFFECTIVE_RECONCILE_EXTERNAL_DATA=false
elif [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
  EFFECTIVE_RECONCILE_EXTERNAL_DATA=true
else
  EFFECTIVE_RECONCILE_EXTERNAL_DATA="${RECONCILE_EXTERNAL_DATA,,}"
fi

# HDFS_TOKEN_EXCLUDE_PROP (when both clusters are HA, excludes both
# nameservices from HDFS delegation token renewal for the MapReduce/DistCp
# job REPL LOAD launches internally - avoids a cross-cluster token-renewal
# failure for jobs that run entirely within a single, already-authenticated
# session) is computed inside derive_db_vars() below, NOT here - it depends
# on DUMP_URI_NS/LOAD_URI_NS, which only exist once derive_db_vars() has run
# at least once (they are direction-dependent in the same-nameservice-
# collision case, and derive_db_vars() is where DUMP_NAMESERVICE/
# LOAD_NAMESERVICE and their alias-aware counterparts are derived from
# REPLICATION_DIRECTION). See derive_db_vars()'s own comment for the full
# collision-case rationale.

# ------------------------------------------------------------------------------
#  AUTO_DERIVE_HA_CLIENT_CONFIG - inject HA NameNode configuration directly
#  into REPL DUMP/LOAD statements.
#
#  Normally, an HA nameservice must already be resolvable to HiveServer2
#  through the cluster's own hdfs-site.xml, configured once cluster-wide.
#  Set AUTO_DERIVE_HA_CLIENT_CONFIG=yes to have this script inject the same
#  properties directly into every REPL DUMP/LOAD statement instead - useful
#  when one cluster's hdfs-site.xml does not yet know about the other
#  cluster's nameservice. Requires SRC_NN_HOSTS and DST_NN_HOSTS.
#
#  (Already defaulted above, right after HA_ENABLED - see that comment - so
#  the collision check further up can safely read it under `set -u`.)
# ------------------------------------------------------------------------------

# SRC_NN_HOSTS / DST_NN_HOSTS - required when AUTO_DERIVE_HA_CLIENT_CONFIG=yes.
# Comma-separated "<nn-id>=<host>:<port>" pairs describing each
# nameservice's NameNodes, for example:
#   SRC_NN_HOSTS="nn1=prod-nn1.example.com:8020,nn2=prod-nn2.example.com:8020"
#   DST_NN_HOSTS="nn1=dr-nn1.example.com:8020,nn2=dr-nn2.example.com:8020"
SRC_NN_HOSTS="${SRC_NN_HOSTS:-}"
DST_NN_HOSTS="${DST_NN_HOSTS:-}"

#SRC_NN_HOSTS="nn1=atlasdemo-01.adsre.com:8020,nn2=atlasdemo-02.adsre.com:8020"
#DST_NN_HOSTS="nn1=odplab001.adsre.com:8020,nn2=odplab002.adsre.com:8020"

# AUTOMATIC_FAILOVER_ENABLED - only used when AUTO_DERIVE_HA_CLIENT_CONFIG=yes.
AUTOMATIC_FAILOVER_ENABLED="${AUTOMATIC_FAILOVER_ENABLED:-true}"

# validate_nn_hosts_spec: called directly in the MAIN shell (never via
# "$(...)" or "< <(...)"), so that a malformed entry actually aborts the
# whole script via `exit 1` instead of just killing a subshell. The
# equivalent parsing inside build_nameservice_ha_props()/
# nameservice_cli_dgen_args()/distcp_collision_dgen_args() further down
# always runs inside a command/process substitution to capture their stdout
# - "exit 1" there only terminates that subshell, silently truncating the
# WITH-clause/-D properties list those functions build rather than aborting,
# so a malformed SRC_NN_HOSTS/DST_NN_HOSTS value must be caught here, up
# front, to get a genuine fail-fast abort with a clear diagnostic.
validate_nn_hosts_spec() {
  local label="$1"
  local nn_hosts_spec="$2"
  local pair nn_id nn_addr
  IFS=',' read -ra pairs <<< "$nn_hosts_spec"
  for pair in "${pairs[@]}"; do
    nn_id="${pair%%=*}"
    nn_addr="${pair#*=}"
    if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_id" == "$pair" ]]; then
      echo "[ERROR] Malformed entry in ${label}: '${pair}' (expected <nn-id>=<host>:<port>)" >&2
      exit 1
    fi
  done
}

if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
  if [[ -z "$SRC_NN_HOSTS" || -z "$DST_NN_HOSTS" ]]; then
    echo "[ERROR] AUTO_DERIVE_HA_CLIENT_CONFIG=yes requires both SRC_NN_HOSTS and DST_NN_HOSTS to be set." >&2
    echo "[ERROR] Example: SRC_NN_HOSTS=\"nn1=host1:8020,nn2=host2:8020\"" >&2
    exit 1
  fi
  validate_nn_hosts_spec "SRC_NN_HOSTS" "$SRC_NN_HOSTS"
  validate_nn_hosts_spec "DST_NN_HOSTS" "$DST_NN_HOSTS"
fi

# ------------------------------------------------------------------------------
#  nn_hosts_short_token: derive a short, stable, filesystem-safe token that
#  identifies ONE PHYSICAL CLUSTER, from that cluster's NN_HOSTS spec.
#
#  Used only in the SAME_NAMESERVICE_COLLISION case, as the per-cluster suffix
#  for the REPL DUMP staging directory (see derive_db_vars()). In that case the
#  nameservice NAME cannot identify a cluster - both clusters share it - and
#  the script's own aliases cannot either, since those name a ROLE ("dump"/
#  "load") that gets rebound to a different cluster on a direction change. The
#  NameNode hostnames are the only thing available here that names the physical
#  cluster itself and never moves.
#
#  Each "<nn-id>=<host>:<port>" pair contributes its host's first label
#  ("odplab001.adsre.com:8020" -> "odplab001"). The results are SORTED and the
#  first taken, so the token depends only on WHICH hosts are listed, not on the
#  order they happen to be written in - reordering SRC_NN_HOSTS must never
#  silently move a database's staging path and orphan its replication lineage.
#
#  Assumes the spec is already well-formed: validate_nn_hosts_spec() has run
#  in the main shell above and aborted on any malformed entry, which matters
#  because this function is called via "$(...)" and an exit here would only
#  kill that subshell.
# ------------------------------------------------------------------------------
nn_hosts_short_token() {
  local nn_hosts_spec="$1"
  local pair addr host
  local -a shorts=()
  IFS=',' read -ra pairs <<< "$nn_hosts_spec"
  for pair in "${pairs[@]}"; do
    addr="${pair#*=}"
    host="${addr%%:*}"
    host="${host%%.*}"
    host="${host//[^A-Za-z0-9_-]/}"
    [[ -n "$host" ]] && shorts+=("$host")
  done
  [[ ${#shorts[@]} -eq 0 ]] && return 0
  printf '%s\n' "${shorts[@]}" | LC_ALL=C sort | head -n 1
}

# REPL_ROOT_SUFFIX - explicit override for the REPL DUMP staging directory's
# per-cluster suffix (the "from_<suffix>" component). Environment-only.
#
# Leave unset for normal operation: the suffix is then derived automatically
# and identifies the DUMPING cluster (see derive_db_vars()), which is what
# keeps a database's staging path stable across direction changes and across
# an operator swapping SRC/DST.
#
# Set it to point a run at a pre-existing staging path that the automatic
# derivation would not produce. The specific case this exists for: staging
# directories created before the suffix became cluster-derived are named
# "from_src_to_dst"/"from_dst_to_src" after the DIRECTION. A database still
# carrying such a directory needs either REPL_ROOT_SUFFIX=src_to_dst (or
# dst_to_src) on every subsequent run, or a one-time HDFS rename of the
# directory to the new cluster-derived name - otherwise the next run finds an
# empty rootdir, falls back to a BOOTSTRAP dump, and the load target rejects
# it with return code 40000.
REPL_ROOT_SUFFIX="${REPL_ROOT_SUFFIX:-}"

# ------------------------------------------------------------------------------
#  PREFLIGHT_PRIMARY_CHECK - "true" or "false" (default: false). Environment-only.
#
#  When "true", every ONGOING replication run (DIRECTION_CHANGE=false) first
#  asks the DUMP side "REPL STATUS <db>" and refuses to proceed if it comes back
#  with a real last_repl_id - which would mean Hive considers that side a
#  REPLICA, i.e. this run is about to dump from the wrong cluster. See
#  preflight_check_dump_side_is_primary().
#
#  DEFAULT OFF BECAUSE OF ITS COST, NOT ITS VALUE. The check is one additional
#  beeline invocation PER DATABASE PER RUN, and a beeline invocation is not
#  cheap here - JVM startup plus ZooKeeper HiveServer2 discovery plus connect
#  measures 10-20s in practice, which is why this script already goes to some
#  length elsewhere to avoid per-database beeline calls (see
#  run_with_heartbeat()'s doc comment on the poll-interval floor that once
#  dominated the entire runtime at thousands of databases). On a 6000-database
#  invocation this check alone would add on the order of a full day of
#  wall-clock time to every cycle, to re-confirm something that does not change
#  between runs.
#
#  TURN IT ON for the FIRST run after anything that could have changed which
#  cluster is primary, where a wrong direction is genuinely possible:
#    - the first ongoing run after a failover or failback converged
#    - the first run after swapping SRC/DST between deployments
#    - any run where you are not certain which side is currently primary
#  Leave it off for steady-state cycles, where the direction has already been
#  proven by the previous run and nothing has moved.
#
#  Leaving it off costs nothing in correctness - Hive still refuses to load a
#  dump taken from the replica side, just later and with a less direct message
#  ("Bootstrap REPL LOAD is not allowed on Database: <db> as it was already
#  done", return code 40000, raised by the LOAD after a full DUMP has run).
#  This check exists to turn that into an immediate, named failure, not to
#  prevent damage that would otherwise occur.
#
#  Direction-change runs (DIRECTION_CHANGE=true) are NOT governed by this flag:
#  they always run their own, different pre-flight
#  (preflight_check_direction_change()), because a direction change is a rare,
#  deliberate control operation where getting the side wrong is both more
#  likely and more consequential, and where the per-database cost is being
#  spent anyway.
# ------------------------------------------------------------------------------
PREFLIGHT_PRIMARY_CHECK="${PREFLIGHT_PRIMARY_CHECK:-false}"

# ------------------------------------------------------------------------------
#  RECONCILE_ON_DIRECTION_CHANGE - "true" or "false" (default: true).
#  Environment-only.
#
#  Whether a direction-change run (DIRECTION_CHANGE=true) copies external table
#  data after it converges.
#
#  This script used to force ALL data copy off for a direction change, on the
#  reasoning that the side about to become the new replica already holds
#  everything from the cycles that ran before the flip, so there is nothing to
#  move. Live testing showed that reasoning is CONDITIONAL, not absolute, and
#  the condition is visible in the round-2 REPL LOAD's own output:
#
#    REPL::START: {"loadType":"BOOTSTRAP","numTables":0,...}
#                                          ^^^^^^^^^^^^
#
#  That inner BOOTSTRAP is Hive's optimized bootstrap of the TABLE DIFF - the
#  tables that had diverged between the two clusters. "numTables":0 means
#  nothing diverged and the old assumption holds exactly: no data to copy. But
#  numTables > 0 means Hive has just rolled those tables back and re-created
#  them from the new primary, and their DATA genuinely does need to move. That
#  happens on an UNPLANNED failover - one where the old primary took writes
#  that never replicated before it was lost - which is precisely the scenario a
#  DR tool exists for. With all copy paths forced off, those tables would arrive
#  as metadata with no data underneath, and nothing would say so.
#
#  DEFAULT TRUE because the two failure modes are not comparable: a redundant
#  copy pass costs time, a skipped one loses data silently. The cost is also
#  much smaller than a full copy - the manual distcp path uses "-update"
#  (see DISTCP_OPTS), so unchanged files are skipped after a listing comparison
#  rather than re-transferred. Confirmed in testing: a reconcile pass over an
#  already-synced table reported "Files Skipped=2, Bytes Skipped=2598" against
#  "Files Copied=1" for the one genuinely new file.
#
#  SET IT FALSE for a failover you know is clean - a planned drill, or a
#  rehearsal where the replica was fully caught up first - and for large
#  multi-database direction changes where a listing pass per table across every
#  database is not worth paying to confirm zero divergence.
#
#  TIMING: this only ever applies AFTER the direction change has CONVERGED
#  (see failover_one_db()), never between handshake rounds. Round 1 produces
#  last_repl_id=-1 and an event_ack marker with no metadata and no tables, so
#  there is nothing for a copy step to act on; round 2 is the round that lands
#  metadata and the table diff.
# ------------------------------------------------------------------------------
RECONCILE_ON_DIRECTION_CHANGE="${RECONCILE_ON_DIRECTION_CHANGE:-true}"

# SRC_ROOT_TOKEN / DST_ROOT_TOKEN - the two clusters' staging-path tokens,
# computed ONCE here rather than per-database inside derive_db_vars(): the
# value depends only on SRC_NN_HOSTS/DST_NN_HOSTS, which never change during a
# run, and derive_db_vars() runs once per database (thousands of times on a
# large multi-database invocation).
SRC_ROOT_TOKEN=""
DST_ROOT_TOKEN=""
if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
  SRC_ROOT_TOKEN="$(nn_hosts_short_token "$SRC_NN_HOSTS")"
  DST_ROOT_TOKEN="$(nn_hosts_short_token "$DST_NN_HOSTS")"
  if [[ -z "$SRC_ROOT_TOKEN" || -z "$DST_ROOT_TOKEN" ]]; then
    echo "[ERROR] Could not derive a staging-directory token from the NameNode hostnames." >&2
    echo "[ERROR]   SRC_NN_HOSTS='${SRC_NN_HOSTS}' -> '${SRC_ROOT_TOKEN}'" >&2
    echo "[ERROR]   DST_NN_HOSTS='${DST_NN_HOSTS}' -> '${DST_ROOT_TOKEN}'" >&2
    echo "[ERROR] Each entry must be <nn-id>=<host>:<port> with a host containing at least one" >&2
    echo "[ERROR] alphanumeric character, or set REPL_ROOT_SUFFIX explicitly." >&2
    exit 1
  fi
  # Both clusters resolving to the same token would silently make BOTH
  # directions share one staging directory - each direction's dump would then
  # be read as the other direction's previous dump. Refuse rather than corrupt.
  if [[ "$SRC_ROOT_TOKEN" == "$DST_ROOT_TOKEN" ]]; then
    echo "[ERROR] SRC_NN_HOSTS and DST_NN_HOSTS produce the same staging-directory token" >&2
    echo "[ERROR] ('${SRC_ROOT_TOKEN}'), so both replication directions would share one staging" >&2
    echo "[ERROR] directory and each direction's dump would be mistaken for the other's." >&2
    echo "[ERROR]   SRC_NN_HOSTS='${SRC_NN_HOSTS}'" >&2
    echo "[ERROR]   DST_NN_HOSTS='${DST_NN_HOSTS}'" >&2
    echo "[ERROR] The token is the alphabetically first NameNode short hostname on each side, so" >&2
    echo "[ERROR] this means the two sides list a NameNode host in common - check that these are" >&2
    echo "[ERROR] genuinely two different physical clusters." >&2
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
# WITH() clause) when AUTO_DERIVE_HA_CLIENT_CONFIG=yes. Prints nothing when
# false (the default), since HA resolution is then assumed to already be
# configured cluster-wide. Called identically for injection into BOTH the
# REPL DUMP statement (dump-side session) and the REPL LOAD statement
# (load-side session) - see DUMP_URI_NS/LOAD_URI_NS's doc comment in
# derive_db_vars() for why the SAME combined property set must work
# correctly no matter which of the two sessions is doing the resolving.
#
# SAME-NAMESERVICE COLLISION CASE (SRC_NAMESERVICE == DST_NAMESERVICE): the
# non-collision behavior below - calling build_nameservice_ha_props once for
# SRC_NAMESERVICE and once for DST_NAMESERVICE - would emit the exact SAME
# property keys ("dfs.ha.namenodes.<name>",
# "dfs.namenode.rpc-address.<name>.<nn-id>") TWICE, with two DIFFERENT
# (prod vs. DR) sets of real addresses under the identical key. The
# resulting WITH()-clause text would contain a literal duplicate key with
# conflicting values - whichever occurrence Hive's property parser honors
# last silently wins, silently discarding the other cluster's real
# addresses. Instead: build_nameservice_ha_props is called exactly once for
# DUMP_URI_NS (with DUMP_NN_HOSTS) and once for LOAD_URI_NS (with
# LOAD_NN_HOSTS) - two DISTINCT alias keys, so no collision - and the real,
# literal shared name (SRC_NAMESERVICE) is re-listed in 'dfs.nameservices'
# UNALIASED and WITHOUT any dfs.ha.namenodes.*/dfs.namenode.rpc-address.*
# override of its own, so each session's own native hdfs-site.xml keeps
# supplying that name's address for that session's own (non-replication)
# operations - see derive_db_vars()'s doc comment for the full rationale.
ha_config_props() {
  if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]]; then
    return
  fi
  if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
    # DUMP_URI_NS/LOAD_URI_NS are fixed alias strings that get REBOUND to a
    # different physical cluster's addresses across a failover/failback
    # (the alias's role never changes, only which physical cluster plays
    # that role). Hadoop's FileSystem cache is JVM-global and keyed only by
    # (scheme, authority, user) - NOT by the Configuration properties in
    # effect for a given query - so a long-running HiveServer2 that already
    # resolved an alias once (e.g. every prior forward-direction run cached
    # DUMPALIAS -> atlasdemo) keeps handing back that stale FileSystem on a
    # later query even though this WITH clause now binds the same alias to
    # a different cluster's addresses. Confirmed via testing: a real
    # failover silently wrote/read every "hdfs://...DUMPALIAS/..." path
    # against the WRONG physical cluster because of exactly this. Disabling
    # the cache forces a fresh FileSystem to be built from THIS query's
    # properties every time - negligible cost given how infrequent REPL
    # DUMP/LOAD calls are.
    printf "'fs.hdfs.impl.disable.cache'='true',\n"
    printf "'dfs.nameservices'='%s,%s,%s',\n" "$SRC_NAMESERVICE" "$DUMP_URI_NS" "$LOAD_URI_NS"
    printf "'dfs.ha.automatic-failover.enabled'='%s',\n" "${AUTOMATIC_FAILOVER_ENABLED,,}"
    build_nameservice_ha_props "$DUMP_URI_NS" "$DUMP_NN_HOSTS"
    build_nameservice_ha_props "$LOAD_URI_NS" "$LOAD_NN_HOSTS"
  else
    printf "'dfs.nameservices'='%s,%s',\n" "$SRC_NAMESERVICE" "$DST_NAMESERVICE"
    printf "'dfs.ha.automatic-failover.enabled'='%s',\n" "${AUTOMATIC_FAILOVER_ENABLED,,}"
    build_nameservice_ha_props "$SRC_NAMESERVICE" "$SRC_NN_HOSTS"
    build_nameservice_ha_props "$DST_NAMESERVICE" "$DST_NN_HOSTS"
  fi
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
HEARTBEAT_INTERVAL_SECONDS="${HEARTBEAT_INTERVAL_SECONDS:-60}"
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
#
# The actual wait below is a single, exact, plain "wait $cmd_pid" with NO
# polling loop of its own - it returns the INSTANT the command exits, with
# zero artificial padding, however fast or slow that command genuinely is.
# Heartbeat messages and timeout enforcement are handled by a fully
# DECOUPLED background watchdog subshell instead, which polls on its own
# schedule and can act (print a message, kill the command) without ever
# affecting when the main wait below notices completion.
#
# This replaces an earlier single-loop design where the SAME loop both
# waited for completion AND handled heartbeat/timeout - that loop checked
# "is it still running?" BEFORE sleeping, then unconditionally slept the
# full poll interval, so completion was only ever noticed at the next
# poll boundary. Confirmed via testing: with a 60s poll interval (the
# original code, sleeping the full HEARTBEAT_INTERVAL_SECONDS per
# iteration), every beeline_exec call was floored to a minimum of ~60s of
# wall-clock time even for a SHOW DATABASES/SHOW TABLES query that itself
# completes in a couple of seconds - at 1000s of databases with several
# beeline calls each, that floor alone dwarfed every other cost in the
# script. A shorter poll interval shrinks that padding but can't remove
# it entirely as long as the same loop governs both concerns; decoupling
# them removes it completely for the thing that actually needs to be
# exact (how long the command took), while the watchdog's own 10s
# granularity remains fine for the things that don't need to be exact
# (roughly-periodic heartbeats, a timeout that doesn't need split-second
# precision).
#
# TIMEOUT_MARKER is how the watchdog reports "I killed it for exceeding
# BEELINE_COMMAND_TIMEOUT_SECONDS" back across the process boundary, since
# a background subshell can't set a variable in this shell directly: it
# touches the marker file just before sending SIGKILL, and the code below
# checks for that file (not just the resulting exit code) to decide
# whether to report 124 - inferring a timeout purely from the exit status
# a SIGKILL leaves behind would misattribute the same status from an
# unrelated external kill (e.g. an operator's own `kill`, an OOM kill) as
# "exceeded timeout" too.
# Usage: run_with_heartbeat <label> <command> [args...]
run_with_heartbeat() {
  local label="$1"
  shift

  "$@" &
  local cmd_pid=$!
  CURRENT_CHILD_PID="$cmd_pid"

  local timeout_marker
  timeout_marker=$(mktemp -u 2>/dev/null) || timeout_marker="/tmp/.rwh_timeout_$$_${RANDOM}"
  rm -f "$timeout_marker" 2>/dev/null

  (
    local poll_interval_seconds=10
    local elapsed=0
    local last_heartbeat=0
    while kill -0 "$cmd_pid" 2>/dev/null; do
      sleep "$poll_interval_seconds"
      elapsed=$(( elapsed + poll_interval_seconds ))
      kill -0 "$cmd_pid" 2>/dev/null || exit 0

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
        : > "$timeout_marker" 2>/dev/null
        kill -9 "$cmd_pid" 2>/dev/null
        exit 0
      fi

      if (( elapsed - last_heartbeat >= HEARTBEAT_INTERVAL_SECONDS )); then
        echo "[HEARTBEAT] ${label} still running - elapsed ${elapsed}s (pid ${cmd_pid})" >&${HEARTBEAT_FD}
        last_heartbeat=$elapsed
      fi
    done
  ) &
  local watchdog_pid=$!

  # 2>/dev/null suppresses bash's own "[pid] Killed: 9 <command>" job-
  # control notice for the timeout-kill case (confirmed via testing this
  # is where it surfaces, even though the watchdog subshell above is what
  # actually sends the kill) - without it, that notice would print
  # alongside the already-clear [ERROR] messages the watchdog just wrote,
  # adding redundant noise to an already-alarming log entry rather than
  # anything a reader needs.
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  CURRENT_CHILD_PID=""

  # The command has genuinely finished now - stop the watchdog immediately
  # (it may still be mid-sleep) rather than letting it linger up to
  # poll_interval_seconds longer on its own before noticing on its next
  # poll, and reap it so it never lingers as a zombie.
  kill "$watchdog_pid" 2>/dev/null
  wait "$watchdog_pid" 2>/dev/null

  if [[ -f "$timeout_marker" ]]; then
    rm -f "$timeout_marker" 2>/dev/null
    return 124
  fi
  return $rc
}

# format_duration: render a whole number of seconds as a compact,
# human-readable "XhYmZs" string, printing only the units that are
# actually non-zero (seconds are always shown) - e.g. 45 -> "45s",
# 65 -> "1m 5s", 3725 -> "1h 2m 5s". REPL DUMP/LOAD on a large database
# can run for hours, and a bare "5400s" is much harder to scan at a
# glance than "1h 30m 0s". Used for every stage/step timing line below -
# never for the RUN_SUMMARY_CSV duration_seconds column, which stays a
# plain integer on purpose (sorting/aggregation expects that).
# Usage: format_duration <seconds>
format_duration() {
  local total="${1:-0}" h m s
  h=$(( total / 3600 ))
  m=$(( (total % 3600) / 60 ))
  s=$(( total % 60 ))
  if (( h > 0 )); then
    printf '%dh %dm %ds' "$h" "$m" "$s"
  elif (( m > 0 )); then
    printf '%dm %ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
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

# split_db_spec: split a single DB_SPECS entry into its database portion
# and table portion, in the globals SPLIT_DB_PORTION / SPLIT_TABLE_PORTION.
#
# A naive first-"." split (the "${spec%%.*}" / "${spec#*.}" approach
# derive_db_vars() below uses) is only safe when the database portion is a
# bare, unquoted Hive identifier, which can never itself contain a ".". It
# breaks once the database portion is a quoted regex that contains a
# literal "." (e.g. the very common "'sales_.*'" - the wildcard "." in the
# regex, not a db/table separator): that split would cut into the regex
# itself instead of at the real db/table boundary. So a spec starting
# with "'" instead has its database portion delimited by the NEXT "'"
# (mirroring parse_db_specs()'s own no-escaping convention for quotes);
# anything else falls back to the safe plain first-"." split.
split_db_spec() {
  local spec="$1"
  if [[ "$spec" == \'* ]]; then
    local rest body after
    rest="${spec#\'}"
    body="${rest%%\'*}"
    after="${rest:$(( ${#body} + 1 ))}"
    SPLIT_DB_PORTION="'${body}'"
    if [[ -z "$after" ]]; then
      SPLIT_TABLE_PORTION=""
    elif [[ "$after" == .* ]]; then
      SPLIT_TABLE_PORTION="${after#.}"
    else
      # Anything else here is a typo, not a table pattern - e.g. a stray
      # character or wrong separator right after the closing quote
      # ("'sales_.*'x", "'sales_.*',"). Silently dropping it (treating the
      # spec as if it ended at the closing quote) would quietly narrow the
      # run to the regex-matched databases while discarding whatever the
      # caller actually appended - fail loudly instead.
      echo "ERROR: Malformed DB spec '${spec}' - unexpected text '${after}' right after the closing quote of the database portion (expected end of spec, or '.' followed by a table pattern)"
      exit 1
    fi
  elif [[ "$spec" == *.* ]]; then
    SPLIT_DB_PORTION="${spec%%.*}"
    SPLIT_TABLE_PORTION="${spec#*.}"
  else
    SPLIT_DB_PORTION="$spec"
    SPLIT_TABLE_PORTION=""
  fi
}

# expand_db_specs: resolve any database-regex entries in the already-split
# DB_SPECS array (populated by parse_db_specs() near the top of this
# script) into one literal entry per matching real database, in place.
#
# A DB spec's database portion is treated as a regex - instead of a
# literal database name - only when it is wrapped in single quotes,
# mirroring the existing HIVE_TABLE_PATTERN convention documented for
# HIVE_DB above:
#   "sales"                            -> literal (unchanged behavior)
#   "sales.'(orders|customers)'"      -> literal db, regex table (unchanged)
#   "'sales_.*'"                      -> regex db, every table
#   "'sales_.*'.'(orders|customers)'" -> regex db, regex table
#
# Unlike HIVE_TABLE_PATTERN (a regex REPL DUMP itself evaluates
# server-side, in Hive's own Java regex dialect), REPL DUMP has no
# database-pattern grammar - it only ever accepts one literal database
# name per call. So a database regex must be expanded to concrete names
# BEFORE any REPL DUMP is issued, which this does by matching it (via
# POSIX ERE / grep -E, NOT Hive's Java regex dialect - a Java-only
# construct such as a lookahead will not work here) against the real
# database list on the dump source, fetched with one SHOW DATABASES call.
#
# Must run after REPLICATION_DIRECTION is resolved (so the correct side
# of the same-nameservice-collision-aware pair is queried) and after
# beeline_exec is defined, but before anything downstream reads DB_SPECS
# (SESSION_DB_LABEL, DB_COUNT, the main per-database loop, etc.).
expand_db_specs() {
  local spec has_regex_spec=false
  for spec in "${DB_SPECS[@]}"; do
    split_db_spec "$spec"
    if [[ "$SPLIT_DB_PORTION" == \'*\' ]]; then
      has_regex_spec=true
      break
    fi
  done
  [[ "$has_regex_spec" == false ]] && return 0

  # Same REPLICATION_DIRECTION -> dump-source mapping as derive_db_vars()
  # below - only the JDBC URL is needed here, so it is not worth calling
  # derive_db_vars() itself (which also computes NN-hosts/nameservice
  # values that have no per-spec meaning yet at this point in the script).
  local regex_probe_jdbc_url
  if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
    regex_probe_jdbc_url="$DST_JDBC_URL"
  else
    regex_probe_jdbc_url="$SRC_JDBC_URL"
  fi

  echo "HIVE_DB contains a database regex - resolving it against SHOW DATABASES on ${regex_probe_jdbc_url}..."
  local all_dbs
  all_dbs=$(beeline_exec "${regex_probe_jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "SHOW DATABASES;" 2>&1) || {
    echo "ERROR: Could not list databases on ${regex_probe_jdbc_url} to resolve a database regex in HIVE_DB"
    exit 1
  }
  all_dbs=$(echo "$all_dbs" | grep -E "^[A-Za-z0-9_]+$" || true)
  if [[ -z "$all_dbs" ]]; then
    echo "ERROR: SHOW DATABASES returned no databases on ${regex_probe_jdbc_url} - cannot resolve a database regex in HIVE_DB"
    exit 1
  fi

  local -a expanded=()
  local table_portion pattern matches matched_db
  for spec in "${DB_SPECS[@]}"; do
    split_db_spec "$spec"
    table_portion="$SPLIT_TABLE_PORTION"

    if [[ "$SPLIT_DB_PORTION" != \'*\' ]]; then
      expanded+=("$spec")
      continue
    fi

    pattern="${SPLIT_DB_PORTION#\'}"
    pattern="${pattern%\'}"

    # grep -E's own exit status distinguishes "valid pattern, zero matches"
    # (1) from "invalid pattern" (>1, e.g. unbalanced parens) - without this
    # check, a syntax error's own "grep: ..." message leaks into the run's
    # output and the pattern is then reported as merely non-matching,
    # which reads like a naming mistake rather than the actual regex typo.
    local grep_rc
    matches=$(printf '%s\n' "$all_dbs" | grep -E "^${pattern}$" 2>/dev/null)
    grep_rc=$?
    if (( grep_rc > 1 )); then
      echo "ERROR: Database regex '${pattern}' (from DB spec '${spec}') is not a valid extended regular expression - grep -E rejected it"
      exit 1
    fi
    if [[ -z "$matches" ]]; then
      echo "ERROR: Database regex '${pattern}' (from DB spec '${spec}') matched no database on ${regex_probe_jdbc_url}"
      exit 1
    fi

    while IFS= read -r matched_db; do
      [[ -z "$matched_db" ]] && continue
      if [[ -n "$table_portion" ]]; then
        expanded+=("${matched_db}.${table_portion}")
      else
        expanded+=("$matched_db")
      fi
      echo "  Database regex '${pattern}' matched: ${matched_db}"
    done <<< "$matches"
  done

  # De-duplicate: a literal spec and a regex spec (or two regex specs) can
  # legitimately overlap and expand to the same literal spec twice (e.g.
  # "sales_us|'sales_.*'") - without this, the main loop below would
  # REPL DUMP/LOAD that database twice in one invocation.
  local -A seen=()
  local -a deduped=()
  local e
  for e in "${expanded[@]}"; do
    if [[ -n "${seen[$e]:-}" ]]; then
      echo "  Skipping duplicate DB spec after regex expansion: ${e}"
      continue
    fi
    seen[$e]=1
    deduped+=("$e")
  done

  DB_SPECS=("${deduped[@]}")
  echo "Resolved ${#DB_SPECS[@]} database spec(s) after regex expansion."
  echo ""
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
  local repl_status_cmd="REPL STATUS ${db};"
  echo "Executing on ${jdbc_url}: ${repl_status_cmd}" >&${HEARTBEAT_FD}
  output=$(beeline_exec "${jdbc_url}" -e "$repl_status_cmd" 2>&1) || return 1
  # beeline prints results as a bordered ASCII table. The shape varies:
  #   Two columns (a database that has itself been a DUMP source at some
  #   point, so it also carries a dump_dir):
  #     +--------------+---------------+
  #     |  dump_dir    | last_repl_id  |
  #     +--------------+---------------+
  #     | hdfs://...   | 10884         |
  #     +--------------+---------------+
  #   One column (the common case - a database queried on a cluster that
  #   has only ever been a LOAD target, never itself dumped from):
  #     +---------------+
  #     | last_repl_id  |
  #     +---------------+
  #     | 11166         |
  #     +---------------+
  # Confirmed via testing: the one-column shape is what a normal DR
  # replica returns, and the original pattern set here only matched the
  # two-column shape - a real, non-NULL last_repl_id on a one-column
  # result silently produced no match at all, which the caller could not
  # tell apart from a genuine NULL/not-yet-a-replica database. The
  # `/^\| *[0-9]+ *\|$/` alternative below (a row that is just one bare
  # numeric column) closes that gap.
  # last_repl_id is the LAST "|"-delimited column of the one data row
  # (the row that is not the header/border). Extract it directly rather
  # than filtering by shape, since the surrounding connection/session
  # chatter never matches this table format.
  echo "$output" | awk -F'|' '
    /^\| *[Hh]dfs:\/\// || /^\| *[Nn][Uu][Ll][Ll] *\|/ || /^\|.*\|.*[0-9].*\|/ || /^\| *[0-9][0-9]* *\|$/ {
      n = NF
      val = $(n-1)
      gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (val != "" && val !~ /^-+$/) { print val; exit }
    }
  '
}

# preflight_check_direction_change: before reversing replication direction
# (a DUMP with 'hive.repl.failover.start'='true'), confirm that Hive's own
# metastore already considers the CURRENT replica - the side that has been
# receiving replication in the direction ABOUT TO BE REVERSED FROM, i.e.
# the side about to become the NEW dump source - a caught-up replica, i.e.
# it has a non-NULL last_repl_id from a previous successful REPL LOAD in
# the current (pre-reversal) direction.
#
# This must be run against the NEW DUMP side (DUMP_NAMESERVICE, as already
# resolved for the target REPLICATION_DIRECTION by derive_db_vars()), NOT
# the NEW LOAD side (LOAD_NAMESERVICE): Hive only records last_repl_id on
# whichever side has actually been loaded into so far, and in a reversal
# that is always the side about to become the new dump source (it was the
# load target under the direction being reversed FROM). The new load side
# (LOAD_NAMESERVICE) is, by definition, the side that has never yet been a
# replica in this pairing - checking it there would always report "not
# caught up", even on a legitimate first-ever failover, since it has no
# replication history to have recorded a checkpoint into. Confirmed via
# testing: querying LOAD_NAMESERVICE here made a first-time failover
# unconditionally fail pre-flight, regardless of how caught-up the real
# current replica (DUMP_NAMESERVICE, post-reversal) actually was.
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

  # --------------------------------------------------------------------------
  #  SECOND precondition, which a non-NULL last_repl_id does NOT cover.
  #
  #  Hive refuses to REPL DUMP from a replica that has only ever been
  #  BOOTSTRAPPED - it must also have received at least one INCREMENTAL REPL
  #  LOAD first. A bootstrap load marks the database with a "first incremental
  #  pending" flag and ReplDumpTask rejects any dump while it is set:
  #
  #    FAILED: Execution Error, return code 40000 from
  #    org.apache.hadoop.hive.ql.exec.repl.ReplDumpTask. Replication dump not
  #    allowed for replicated database with first incremental dump pending :
  #    <db>
  #
  #  A bootstrap DOES set repl.last.id, so the last_repl_id check above passes
  #  happily on such a database - confirmed via live testing: a database that
  #  was bootstrapped and then immediately failed over passed pre-flight with
  #  last_repl_id=11850 and then died on the very next statement with the
  #  40000 above. Checking the flag here turns that into a clear, actionable
  #  abort before any REPL DUMP is issued.
  #
  #  Matched loosely on "first.inc.pending=true" rather than a fully-qualified
  #  key, since the property has carried both a "repl." and a "hive.repl."
  #  prefix across Hive versions. A DESCRIBE that fails, or output that simply
  #  does not contain the flag, is treated as "not pending" and allowed
  #  through - this check exists to convert a known Hive rejection into a
  #  better message, and must never itself become a new reason a legitimate
  #  failover is refused.
  # --------------------------------------------------------------------------
  local db_params
  if db_params="$(beeline_exec "$current_replica_jdbc" \
      --silent=true \
      --showHeader=false \
      --outputformat=tsv2 \
      -e "DESCRIBE DATABASE EXTENDED ${HIVE_DB_NAME};" 2>&1)"; then
    if echo "$db_params" | grep -qiE 'first\.inc\.pending[[:space:]]*=[[:space:]]*true'; then
      echo "ERROR: ${current_replica_ns} still has Hive's 'first incremental pending' flag set for"
      echo "       '${HIVE_DB_NAME}' - it has been BOOTSTRAPPED but has never received an INCREMENTAL"
      echo "       REPL LOAD, so Hive will not allow a REPL DUMP from it:"
      echo "         'Replication dump not allowed for replicated database with first incremental"
      echo "          dump pending : ${HIVE_DB_NAME}' (ReplDumpTask, return code 40000)"
      echo ""
      echo "       A non-NULL last_repl_id (${last_id}) is set by the bootstrap itself and is NOT"
      echo "       enough on its own - the replica needs one ordinary incremental cycle before it"
      echo "       is eligible to become a primary."
      echo ""
      echo "       Run ONE normal replication cycle in the CURRENT direction first (the same"
      echo "       invocation used for the bootstrap - FAILOVER_MODE=false, or"
      echo "       DIRECTION_CHANGE=false), then re-request this direction change."
      return 1
    fi
  else
    echo "[WARN] Could not read DESCRIBE DATABASE EXTENDED ${HIVE_DB_NAME} on ${current_replica_ns} -"
    echo "[WARN] proceeding without the 'first incremental pending' check. If the REPL DUMP below"
    echo "[WARN] fails with return code 40000 and 'first incremental dump pending', run one normal"
    echo "[WARN] replication cycle in the current direction first, then retry this direction change."
  fi

  echo "OK: ${current_replica_ns} last_repl_id=${last_id}, no first-incremental-pending flag - safe to reverse direction (it becomes the new replica)."
  echo ""
  return 0
}

# ------------------------------------------------------------------------------
# preflight_check_dump_side_is_primary: on an ONGOING replication run (any
# direction, DIRECTION_CHANGE=false), assert that the side about to be dumped
# from is genuinely the PRIMARY for this database.
#
# Hive records repl.last.id only on a database it has actually loaded into, so
# a primary reports REPL STATUS = NULL and a replica reports a real id. A real
# id on the DUMP side means this run is pointed the wrong way round - it is
# about to dump FROM the replica. Hive does eventually refuse that, but only
# several steps later and with a message that describes a symptom rather than
# the cause: "Bootstrap REPL LOAD is not allowed on Database: <db> as it was
# already done" (return code 40000), raised by the LOAD after a full DUMP has
# already run. This turns it into an immediate, named failure.
#
# APPLIES IN BOTH DIRECTIONS. It was originally scoped to dst_to_src only, on
# the reasoning that the forward path was long-established and should not gain
# a new way to fail. That reasoning no longer holds: once swapping SRC/DST is a
# supported way to drive the reversed direction (see "CHOOSING SOURCE AND
# DESTINATION" at the top of this file), "src_to_dst" no longer implies "dumping
# from the original production cluster" - a swapped run legitimately dumps from
# the other cluster, and a run where the operator MEANT to swap but didn't is
# exactly the mistake this catches.
#
# The regression risk that motivated the narrow scope is handled differently
# instead: an unqueryable REPL STATUS (database absent on that side, cluster
# unreachable, an unexpected beeline failure) only WARNS and proceeds. Only a
# definite non-NULL id aborts. So this can report a problem, but it cannot
# invent one - a run that works today and has nothing wrong with it cannot
# start failing here.
#
# Returns 0 to proceed, 1 to abort.
# ------------------------------------------------------------------------------
preflight_check_dump_side_is_primary() {
  local dump_side_jdbc="$1"
  local dump_side_ns="$2"
  local last_id

  echo "$SUBSEP"
  echo "Pre-flight: verifying ${dump_side_ns} is the current PRIMARY before replicating from it..."

  if ! last_id="$(repl_status_last_id "$dump_side_jdbc" "$HIVE_DB_NAME")"; then
    echo "[WARN] Could not query REPL STATUS ${HIVE_DB_NAME} on ${dump_side_ns} - skipping the"
    echo "[WARN] primary-side check and proceeding. (Usually means the database does not exist"
    echo "[WARN] there yet, which is normal for a first-ever bootstrap.) If the REPL LOAD later"
    echo "[WARN] fails with return code 40000 and 'already done', this run is dumping from the"
    echo "[WARN] replica side - check REPL STATUS on both clusters and correct the direction."
    echo ""
    return 0
  fi

  if [[ -n "$last_id" && "${last_id^^}" != "NULL" ]]; then
    echo "ERROR: ${dump_side_ns} reports last_repl_id=${last_id} for '${HIVE_DB_NAME}', which means Hive"
    echo "       considers it a REPLICA, not the primary - so this run would dump from the wrong side."
    echo ""
    echo "       Exactly one of the two clusters should return NULL for REPL STATUS ${HIVE_DB_NAME};"
    echo "       that one is the primary and is the only side that can be dumped from. Check both,"
    echo "       then either point this run in the other direction (REPLICATION_DIRECTION), or swap"
    echo "       which cluster is SRC and which is DST - both are supported."
    echo ""
    echo "       If you expected ${dump_side_ns} to be the primary, the failover meant to promote it"
    echo "       never converged - re-run the direction change and confirm it reports CONVERGED."
    return 1
  fi

  echo "OK: ${dump_side_ns} has no recorded last_repl_id - it is the primary, safe to replicate from."
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

# nameservice_cli_dgen_args: print the "-D..." generic-option equivalent of
# build_nameservice_ha_props(), one flag per line, for splicing into a
# direct `hdfs`/`hadoop` CLI invocation's argument list (as opposed to a
# REPL DUMP/LOAD WITH() clause). Prints nothing when AUTO_DERIVE_HA_CLIENT_CONFIG
# is not "true" or SAME_NAMESERVICE_COLLISION is not true - these direct CLI
# calls (allow_snapshot_idempotent, the -test/-mkdir calls in
# enable_external_table_snapshots) never got any "-D" injection before this
# fix, and continue not to whenever the collision-specific ambiguity this
# exists to resolve is not actually present, to avoid any behavior change
# for existing non-colliding deployments.
#
# UNLIKE the WITH()-clause fix (ha_config_props()), this does NOT need to
# retain the real/native nameservice name in "dfs.nameservices" alongside the
# alias: each call site here is a single, standalone CLI invocation - a
# fresh JVM/Configuration every time - that only ever needs ONE cluster
# resolved at a time (never both simultaneously, unlike a REPL DUMP/LOAD
# WITH() clause or a single `hadoop distcp` invocation spanning two URIs at
# once), so there is no risk of this override breaking that same JVM's
# resolution of "its own" identity for anything else.
#
# Usage: nameservice_cli_dgen_args <alias_or_nameservice> <nn_hosts_spec>
nameservice_cli_dgen_args() {
  local nameservice="$1"
  local nn_hosts_spec="$2"
  if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]] || [[ "$SAME_NAMESERVICE_COLLISION" != true ]]; then
    return 0
  fi
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
    printf -- "-Ddfs.namenode.rpc-address.%s.%s=%s\n" "$nameservice" "$nn_id" "$nn_addr"
  done
  local joined_ids
  joined_ids="$(IFS=,; echo "${nn_ids[*]}")"
  printf -- "-Ddfs.nameservices=%s\n" "$nameservice"
  printf -- "-Ddfs.ha.namenodes.%s=%s\n" "$nameservice" "$joined_ids"
  printf -- "-Ddfs.client.failover.proxy.provider.%s=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider\n" "$nameservice"
  printf -- "-Ddfs.ha.automatic-failover.enabled=%s\n" "${AUTOMATIC_FAILOVER_ENABLED,,}"
}

# allow_snapshot_idempotent: run `hdfs dfsadmin -allowSnapshot <dir>` and
# treat "directory is already snapshottable" as success (not an error).
# Returns 0 on success (including already-enabled), 1 on failure.
#
# <nameservice> may be DUMP_URI_NS/LOAD_URI_NS (an alias) in the same-
# nameservice-collision case - <nn_hosts_spec> must then be that alias's
# real NN host spec (DUMP_NN_HOSTS/LOAD_NN_HOSTS), so this call can inject
# its own "-D" resolution for the alias via nameservice_cli_dgen_args(). Pass
# an empty string for <nn_hosts_spec> in the non-collision case (its only
# effect there is a no-op, since nameservice_cli_dgen_args() itself checks
# SAME_NAMESERVICE_COLLISION and prints nothing when false).
allow_snapshot_idempotent() {
  local nameservice="$1"
  local dir="$2"
  local label="$3"
  local nn_hosts_spec="${4:-}"
  local -a dgen_args=()
  if [[ -n "$nn_hosts_spec" ]]; then
    mapfile -t dgen_args < <(nameservice_cli_dgen_args "$nameservice" "$nn_hosts_spec")
  fi
  local out rc
  out=$(run_as_hdfs hdfs dfsadmin "${dgen_args[@]}" -fs "hdfs://${nameservice}" -allowSnapshot "$dir" 2>&1 | grep -v "^SLF4J:")
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
#   In the same-nameservice-collision case, callers pass DUMP_URI_NS/
#   LOAD_URI_NS (the aliases), not the raw SRC_NAMESERVICE/DST_NAMESERVICE -
#   see the comment below on how this function determines which real
#   NN_HOSTS spec corresponds to whichever alias it was actually called
#   with.
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

  # Each standalone `hdfs` CLI call below only ever targets ONE cluster at a
  # time (see nameservice_cli_dgen_args()'s own doc comment for why that
  # means no aliasing ambiguity within a single call) - but in the same-
  # nameservice-collision case, DUMP_URI_NS and LOAD_URI_NS are the only two
  # DISTINCT strings this function ever sees (the raw, real nameservice name
  # is identical for both and cannot be used to tell them apart), so the
  # correct real NN_HOSTS spec for a given call is determined by comparing
  # against those two alias values, not by inspecting the string's content.
  # Resolves to empty (a no-op - see nameservice_cli_dgen_args()) whenever
  # SAME_NAMESERVICE_COLLISION is false, or if this function is ever called
  # with neither alias (defensive fallback, should not normally happen).
  local dump_source_nn_hosts=""
  if [[ "$dump_source_ns" == "$DUMP_URI_NS" ]]; then
    dump_source_nn_hosts="$DUMP_NN_HOSTS"
  elif [[ "$dump_source_ns" == "$LOAD_URI_NS" ]]; then
    dump_source_nn_hosts="$LOAD_NN_HOSTS"
  fi
  local -a dump_source_dgen_args=()
  if [[ -n "$dump_source_nn_hosts" ]]; then
    mapfile -t dump_source_dgen_args < <(nameservice_cli_dgen_args "$dump_source_ns" "$dump_source_nn_hosts")
  fi

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
  # REPL_EXTERNAL_BASE_DIR's authority is always the RAW LOAD_NAMESERVICE
  # (see compute_repl_external_base_dir()'s doc comment in derive_db_vars()
  # - never LOAD_URI_NS, even in the same-nameservice-collision case, since
  # this value gets baked permanently into replicated tables' LOCATION
  # metadata and must stay resolvable by the Metastore server's own native
  # config forever after), so it is always natively resolvable here too -
  # no -D injection needed for this call, unlike dump_source_ns above.
  local base_dir_ns="${REPL_EXTERNAL_BASE_DIR#hdfs://}"
  base_dir_ns="${base_dir_ns%%/*}"
  local dst_path="${REPL_EXTERNAL_BASE_DIR#hdfs://${base_dir_ns}}"

  if run_as_hdfs hdfs dfs "${dump_source_dgen_args[@]}" -fs "hdfs://${dump_source_ns}" -test -d "$src_path"; then
    allow_snapshot_idempotent "$dump_source_ns" "$src_path" "DUMP SOURCE (${dump_source_ns})" "$dump_source_nn_hosts" && src_ok=true
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

# metadata_only_dump_prop: print the
# 'hive.repl.dump.metadata.only.for.external.table' WITH-clause property
# (ending in a comma) for a REPL DUMP - 'true' when METADATA_ONLY=true,
# 'false' otherwise (the default/original behavior).
metadata_only_dump_prop() {
  if [[ "${METADATA_ONLY,,}" == "true" ]]; then
    printf "%s\n" "'hive.repl.dump.metadata.only.for.external.table'='true',"
  else
    printf "%s\n" "'hive.repl.dump.metadata.only.for.external.table'='false',"
  fi
}

# load_data_copy_prop: print the value ('true'/'false') for
# 'hive.repl.run.data.copy.tasks.on.target' on a REPL LOAD - 'false' when
# METADATA_ONLY=true or EFFECTIVE_RECONCILE_EXTERNAL_DATA=true (data copy is
# instead done via a manual distcp - see check_all_tables_external()/
# reconcile_external_table_data() call sites in run_incremental_cycle()),
# 'true' otherwise (the default/original behavior).
# Bootstrap LOAD has its own separate load_data_copy_flag local (see
# replicate_one_db) for its own EXCEPTION 1/EXCEPTION 2 messaging, but uses
# the same EFFECTIVE_RECONCILE_EXTERNAL_DATA/METADATA_ONLY logic.
#
# ALSO 'false' on a direction-change run (DIRECTION_CHANGE=true - a failover
# or a failback), which is exactly what reaches failover_one_db(). A direction
# change is a control operation that flips which side is primary; the side
# about to become the new replica already holds the data from every preceding
# cycle in the direction being reversed FROM, so there is nothing to copy (see
# EFFECTIVE_RECONCILE_EXTERNAL_DATA's doc comment, which disables the manual
# distcp path for the same runs and the same reason). This branch is what keeps
# the two mechanisms consistent: without it, switching
# EFFECTIVE_RECONCILE_EXTERNAL_DATA off for a direction change would silently
# flip this property back ON, handing the work to Hive's own internal copy -
# which in the SAME_NAMESERVICE_COLLISION case cannot resolve the dump-side
# LOCATIONs at all and "succeeds" having copied nothing ("number of
# splits:0"), i.e. it would trade one skipped copy for one fake copy.
#
# KEYED ON DIRECTION_CHANGE, NOT ON REPLICATION_DIRECTION - this used to read
# `REPLICATION_DIRECTION == dst_to_src`. Ongoing replication in the reversed
# direction (dst_to_src + DIRECTION_CHANGE=false) has to copy data like any
# other cycle; see the matching note in EFFECTIVE_RECONCILE_EXTERNAL_DATA's
# doc comment for why keying this on direction was a silent-data-loss bug.
load_data_copy_prop() {
  if [[ "${METADATA_ONLY,,}" == "true" || "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    printf "%s" "false"
  elif [[ "$DIRECTION_CHANGE" == true && "${RECONCILE_ON_DIRECTION_CHANGE,,}" != "true" ]]; then
    printf "%s" "false"
  else
    printf "%s" "true"
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
  echo "New primary      : $DUMP_URI_NS (writes here)"
  echo "New replica      : $LOAD_URI_NS (receives replication)"
  echo "Log File         : $LOG_FILE"
  echo ""

  ########################################
  # Step 1: pre-flight check - confirm the new dump side is already a
  # caught-up replica before reversing direction. Was documented (see the
  # header comment above and preflight_check_direction_change()'s own doc
  # comment) but never actually wired up - restored here so a direction
  # change is never attempted against a side Hive itself doesn't yet
  # consider a valid replication source.
  ########################################
  echo "$SUBSEP"
  echo "[1/${FAILOVER_TOTAL_STEPS}] Pre-flight check..."
  local _stage_t0=$(date +%s)
  if ! preflight_check_direction_change "$DUMP_JDBC_URL" "$DUMP_URI_NS"; then
    echo "ERROR: Pre-flight check failed for ${HIVE_DB_NAME} - aborting direction change (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  fi
  echo "[1/${FAILOVER_TOTAL_STEPS}] Completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

  if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
    # Prepare both sides for snapshot-diff copy: the new dump source
    # (must be passed explicitly here, since it is not necessarily
    # SRC_NAMESERVICE once the direction has reversed) and the new load
    # target (harmless no-op if a previous cycle already prepared it).
    local _stage_t0=$(date +%s)
    enable_external_table_snapshots "$DUMP_URI_NS"
    enable_external_table_snapshots "$LOAD_URI_NS"
    echo "Snapshot capability setup completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  fi

  if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    echo "$SUBSEP"
    echo "External data copy will go through manual distcp for this failover - verifying all tables in '${HIVE_DB_NAME}' are EXTERNAL_TABLE..."
    local _stage_t0=$(date +%s)
    if ! check_all_tables_external "$DUMP_JDBC_URL"; then
      echo "ERROR: Aborting direction change for ${HIVE_DB_NAME} - see error above (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      return 1
    fi
    echo "EXTERNAL_TABLE check completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    echo ""
  fi

  ########################################
  # Steps 2 and 3, REPEATED UNTIL CONVERGED.
  #
  # Hive's direction change is a multi-round handshake, not a single
  # DUMP/LOAD pair, and the round count is not something an operator should
  # have to know or count off by hand. Observed against Hive 4.0.1 (both a
  # two-distinct-nameservice lab pairing and a SAME_NAMESERVICE_COLLISION
  # pairing, identical behavior in both):
  #
  #   round 1 - REPL DUMP returns last_repl_id=-1 with no REPL::START/END and
  #             writes an "event_ack" file into the dump dir. The matching
  #             REPL LOAD runs as REPL_INCREMENTAL_LOAD with numEvents:0 and
  #             records only the control state ("Setting last failover type
  #             ... to: UNPLANNED", "failover count ... to: 1"). REPL STATUS
  #             on the new replica is still NULL - nothing has been loaded
  #             into it, so it is NOT a replica yet.
  #   round 2 - REPL DUMP now returns a real INCREMENTAL dump, numbered on the
  #             NEW primary's own event stream, and the REPL LOAD applies it
  #             as INCREMENTAL plus an inner BOOTSTRAP of the table diff.
  #             REPL STATUS on the new replica becomes a real id: converged.
  #   round 3 - would abort at preflight_check_direction_change(), because by
  #             then the new primary is no longer a replica. That is Hive's
  #             own natural stop, and it is why FAILOVER_MAX_ROUNDS defaults
  #             to 3 rather than 2.
  #
  # Before this loop existed the function ran exactly one round and then
  # printed "Failover Replication Completed" regardless - the REPL STATUS
  # query at the end had its VALUE discarded (only beeline's exit code was
  # checked), so a round-1 NULL was reported to the operator as a completed
  # failover with "Failed: 0". Convergence is now decided by that value.
  ########################################
  local _round=0
  local _converged=false
  local _load_side_id=""

  while (( _round < FAILOVER_MAX_ROUNDS )); do
  _round=$(( _round + 1 ))
  echo "$SUBSEP"
  echo "${DIRECTION_CHANGE_KIND} handshake round ${_round} of at most ${FAILOVER_MAX_ROUNDS}"
  echo "$SUBSEP"

  ########################################
  # Step 2: REPL DUMP with failover.start=true on the new primary
  ########################################
  echo "$SUBSEP"
  echo "[2/${FAILOVER_TOTAL_STEPS}] (round ${_round}) Running failover-start REPL DUMP on new primary (${DUMP_URI_NS})..."
  local _stage_t0=$(date +%s)

  local FAILOVER_DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
'hive.repl.failover.start'='true',
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${DUMP_URI_NS}: ${FAILOVER_DUMP_CMD}"
  echo ""
  if ! beeline_exec "${DUMP_JDBC_URL}" -e "${FAILOVER_DUMP_CMD}"; then
    echo "ERROR: ${DIRECTION_CHANGE_KIND} REPL DUMP failed on ${DUMP_URI_NS} for ${HIVE_DB_NAME} in round ${_round} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  fi
  echo "[2/${FAILOVER_TOTAL_STEPS}] (round ${_round}) REPL DUMP completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  echo ""

  ########################################
  # Step 3: REPL LOAD on the new replica.
  #
  # NO external table data is copied by this LOAD, by either mechanism:
  # 'hive.repl.run.data.copy.tasks.on.target' is forced to 'false' by
  # load_data_copy_prop() for this direction, and the manual distcp path is
  # disabled by EFFECTIVE_RECONCILE_EXTERNAL_DATA for the same direction.
  # A direction change flips which side is primary; every preceding
  # normal-direction cycle already copied the data to the side that is about
  # to become the new replica, so there is nothing left to move. See both
  # doc comments near the top of the script for the full rationale.
  ########################################
  echo "$SUBSEP"
  echo "[3/${FAILOVER_TOTAL_STEPS}] (round ${_round}) Running ${DIRECTION_CHANGE_KIND} REPL LOAD on new replica (${LOAD_URI_NS})..."
  if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    echo "NOTE: this LOAD itself copies no data ('hive.repl.run.data.copy.tasks.on.target'='false')."
    echo "      External table data is reconciled by manual distcp ONCE, after the handshake"
    echo "      converges - see RECONCILE_ON_DIRECTION_CHANGE. Watch the inner BOOTSTRAP's"
    echo "      \"numTables\" below: 0 means nothing diverged and the reconcile will find nothing"
    echo "      to move; greater than 0 means Hive re-created those tables from ${DUMP_URI_NS} and"
    echo "      their data genuinely needs copying."
  else
    echo "NOTE: external table DATA copy is intentionally skipped for this direction-change run"
    echo "      (no manual distcp, and 'hive.repl.run.data.copy.tasks.on.target'='false')."
    echo "      RECONCILE_ON_DIRECTION_CHANGE is not 'true', so this assumes ${LOAD_URI_NS} already"
    echo "      holds the data from every preceding cycle in the direction being reversed from."
    echo "      That assumption only holds when nothing diverged - if the inner BOOTSTRAP below"
    echo "      reports \"numTables\" greater than 0, those tables are arriving WITHOUT their data."
  fi
  local _stage_t0=$(date +%s)

  local FAILOVER_LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.run.data.copy.tasks.on.target'='$(load_data_copy_prop)',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing on ${LOAD_URI_NS}: ${FAILOVER_LOAD_CMD}"
  echo ""
  if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "${FAILOVER_LOAD_CMD}"; then
    echo "ERROR: ${DIRECTION_CHANGE_KIND} REPL LOAD failed on ${LOAD_URI_NS} for ${HIVE_DB_NAME} in round ${_round} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  fi
  echo "[3/${FAILOVER_TOTAL_STEPS}] (round ${_round}) REPL LOAD completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  echo ""

  ########################################
  # Convergence test for this round.
  #
  # The single authoritative signal that a direction change has actually
  # happened: REPL STATUS on the NEW REPLICA returns a real last_repl_id.
  # Hive only records last_repl_id on a database it has loaded into, so a
  # non-NULL value here means the new replica has genuinely received and
  # applied the reversed stream. NULL means the handshake has advanced but
  # the flip is not done - round 1 always lands here.
  #
  # Uses repl_status_last_id() (which parses the VALUE) rather than checking
  # beeline's exit code, which is 0 for a NULL result just as it is for a
  # real id - that indistinguishability is what made the old one-round
  # version report an unfinished failover as a success.
  ########################################
  echo "Checking whether ${LOAD_URI_NS} has become a replica of ${DUMP_URI_NS} (round ${_round})..."
  local _stage_t0=$(date +%s)
  if ! _load_side_id="$(repl_status_last_id "$LOAD_JDBC_URL" "$HIVE_DB_NAME")"; then
    echo "ERROR: Could not query REPL STATUS ${HIVE_DB_NAME} on ${LOAD_URI_NS} after round ${_round} -"
    echo "       cannot confirm whether the ${DIRECTION_CHANGE_KIND,,} took effect. Aborting rather than"
    echo "       reporting an unverified direction change as successful."
    return 1
  fi
  echo "REPL STATUS check completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

  if [[ -n "$_load_side_id" && "${_load_side_id^^}" != "NULL" ]]; then
    _converged=true
    echo "CONVERGED after round ${_round}: ${LOAD_URI_NS} last_repl_id=${_load_side_id}"
    echo "  ${DUMP_URI_NS} is now the primary; ${LOAD_URI_NS} is its replica."
    echo ""
    break
  fi

  echo "Round ${_round} handshake completed, but ${LOAD_URI_NS} still reports last_repl_id=NULL -"
  echo "  it has not been loaded into yet, so it is not a replica and the flip is incomplete."
  if (( _round < FAILOVER_MAX_ROUNDS )); then
    echo "  Running another round (this is expected: round 1 only writes the event_ack handshake)."
  fi
  echo ""
  done

  ########################################
  # Did it actually converge?
  ########################################
  if [[ "$_converged" != true ]]; then
    echo "ERROR: ${DIRECTION_CHANGE_KIND} did NOT converge for ${HIVE_DB_NAME} after ${FAILOVER_MAX_ROUNDS} round(s)."
    echo "       ${LOAD_URI_NS} still reports REPL STATUS = NULL, meaning it has never been loaded"
    echo "       into and is therefore NOT a replica of ${DUMP_URI_NS}. The direction has NOT flipped."
    echo ""
    echo "       Nothing is half-applied - each round's DUMP/LOAD pair either applied or did not -"
    echo "       but do NOT begin writing to ${DUMP_URI_NS} as though the flip had completed."
    echo ""
    echo "       Diagnostics, in order:"
    echo "         1. If every round's REPL DUMP returned last_repl_id=-1, Hive never progressed"
    echo "            past the event_ack handshake. Check that the dump dir under"
    echo "            ${REPL_ROOT_DIR_SRC} is physically on ${DUMP_URI_NS} and readable by the"
    echo "            LOAD-side HiveServer2 - a dump the load side cannot see makes REPL LOAD a"
    echo "            silent no-op (0 locks, sub-second, no REPL::START)."
    echo "         2. If a round's REPL LOAD logged no REPL::START at all, the load side resolved"
    echo "            '${DUMP_URI_NS}' to a different filesystem than the dump side did."
    echo "         3. Raise FAILOVER_MAX_ROUNDS only if a round showed real forward progress;"
    echo "            repeating a stuck handshake will not unstick it."
    return 1
  fi

  if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    local _stage_t0=$(date +%s)
    if ! reconcile_external_table_data; then
      echo "ERROR: External data reconciliation failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      return 1
    fi
    echo "External data reconciliation completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  fi

  echo "$SEP"
  echo " ${DIRECTION_CHANGE_KIND} Completed: ${HIVE_DB_NAME} (converged in ${_round} round(s))"
  echo "$SEP"
  echo ""
  echo "Database         : $HIVE_DB_NAME"
  echo "New primary      : $DUMP_URI_NS (writes here)"
  echo "New replica      : $LOAD_URI_NS (receives replication)"
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
    local _stage_t0=$(date +%s)
    enable_external_table_snapshots "$DUMP_URI_NS"
    echo "Snapshot capability setup completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  fi

  if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    echo "$SUBSEP"
    echo "External data copy will go through manual distcp for this cycle - verifying all tables in '${HIVE_DB_NAME}' are EXTERNAL_TABLE..."
    local _stage_t0=$(date +%s)
    if ! check_all_tables_external "$DUMP_JDBC_URL"; then
      echo "ERROR: Aborting incremental cycle for ${HIVE_DB_NAME} - see error above (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      return 1
    fi
    echo "EXTERNAL_TABLE check completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    echo ""
  fi

  echo "$SUBSEP"
  echo "Running incremental REPL DUMP on dump source (${DUMP_URI_NS}, direction: ${REPLICATION_DIRECTION})..."
  local _stage_t0=$(date +%s)

  local incr_dump_cmd="REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing: $incr_dump_cmd"
  echo ""
  if ! beeline_exec "${DUMP_JDBC_URL}" -e "$incr_dump_cmd"; then
    echo "ERROR: Incremental REPL DUMP failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  fi
  echo "Incremental REPL DUMP completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  echo ""

  echo "$SUBSEP"
  echo "Running incremental REPL LOAD on load target (${LOAD_URI_NS})..."
  local _stage_t0=$(date +%s)

  local incr_load_cmd="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.run.data.copy.tasks.on.target'='$(load_data_copy_prop)',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='false',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

  echo "Executing: $incr_load_cmd"
  echo ""
  if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "$incr_load_cmd"; then
    echo "ERROR: Incremental REPL LOAD failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  fi
  echo "Incremental REPL LOAD completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  echo ""

  if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
    local _stage_t0=$(date +%s)
    if ! reconcile_external_table_data; then
      echo "ERROR: External data reconciliation failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      return 1
    fi
    echo "External data reconciliation completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
  fi

  echo "$SUBSEP"
  echo "Validating replication status on load target..."
  local _stage_t0=$(date +%s)
  beeline_exec "${LOAD_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - incremental DUMP/LOAD already succeeded)"
  echo "REPL STATUS check completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
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
  local _stage_t0=$(date +%s)
  tables_output=$(beeline_exec "${jdbc_url}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "USE ${HIVE_DB_NAME}; SHOW TABLES;" 2>&1) || {
    echo "ERROR: Could not list tables in '${HIVE_DB_NAME}' on dump source to verify they are all external (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  }
  echo "SHOW TABLES completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

  local tables
  tables=$(echo "$tables_output" | grep -E "^[A-Za-z0-9_]+$")

  if [[ -n "$HIVE_TABLE_PATTERN" ]]; then
    # HIVE_TABLE_PATTERN may still be wrapped in the single quotes the
    # caller supplied (see derive_db_vars()) - those quotes are only
    # meaningful to parse_db_specs()/REPL DUMP's grammar, not to grep, so
    # strip one matched pair before using this as a raw -E regex. Without
    # this, a documented pattern like "sales.'(orders|customers)'" would
    # produce grep -E "^'(orders|customers)'$", which cannot match any
    # real table name and silently short-circuits the EXTERNAL_TABLE
    # safety check to "no tables to check - pass".
    local table_pattern_regex="$HIVE_TABLE_PATTERN"
    if [[ "$table_pattern_regex" == \'*\' ]]; then
      table_pattern_regex="${table_pattern_regex#\'}"
      table_pattern_regex="${table_pattern_regex%\'}"
    fi
    tables=$(echo "$tables" | grep -E "^${table_pattern_regex}$" || true)
  fi

  if [[ -z "$tables" ]]; then
    echo "[WARN] No tables found in '${HIVE_DB_NAME}' matching pattern (nothing to check for RECONCILE_EXTERNAL_DATA)"
    return 0
  fi

  local non_external=()
  local tbl tbl_type
  local _check_start=$(date +%s)
  local _check_count=0
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
    _check_count=$(( _check_count + 1 ))
  done <<< "$tables"
  # One beeline (JVM + ZooKeeper HS2 discovery) launch per table here - at
  # hundreds/thousands of tables this dominates the whole check's runtime,
  # so report it as its own total rather than leaving it hidden inside
  # "EXTERNAL_TABLE check completed in Ns" at the caller.
  echo "DESCRIBE FORMATTED checked ${_check_count} table(s) in $(format_duration $(( $(date +%s) - _check_start )))"

  if [[ ${#non_external[@]} -gt 0 ]]; then
    echo "ERROR: Every table in '${HIVE_DB_NAME}' must be EXTERNAL_TABLE for this run's data-copy mode."
    echo "ERROR: Found non-external table(s):"
    for t in "${non_external[@]}"; do
      echo "  - ${t}"
    done
    echo "ERROR: Managed/ACID table data cannot be safely reconciled with a manual distcp (base/delta"
    echo "ERROR: directories, valid-txn-lists have no equivalent manual step)."
    if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
      echo "ERROR: SAME_NAMESERVICE_COLLISION is active for this run (SRC_NAMESERVICE == DST_NAMESERVICE),"
      echo "ERROR: so Hive's own internal REPL LOAD data copy cannot be used instead - it resolves this"
      echo "ERROR: table's real location using the raw, un-aliased shared nameservice name, which the"
      echo "ERROR: LOAD-side session resolves to the WRONG physical cluster (confirmed via live testing:"
      echo "ERROR: it silently copies zero files instead of failing loudly). There is currently no working"
      echo "ERROR: data-copy path for managed/ACID tables in this scenario - narrow HIVE_DB's table pattern"
      echo "ERROR: to exclude this table, or use two genuinely distinct nameservice names/host:port values"
      echo "ERROR: for SRC_NAMESERVICE/DST_NAMESERVICE if that is possible in your environment instead."
    else
      echo "ERROR: Re-run with RECONCILE_EXTERNAL_DATA=false (the default) to use REPL LOAD's normal full data copy instead."
    fi
    return 1
  fi

  echo "OK: all tables in '${HIVE_DB_NAME}' (matching pattern) are EXTERNAL_TABLE - safe for the manual distcp data-copy path"
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
# distcp_collision_dgen_args: print the "-D..." generic-option properties
# needed for a single `hadoop distcp` invocation to correctly resolve BOTH
# DUMP_URI_NS and LOAD_URI_NS simultaneously, in the same-nameservice-
# collision case. Prints nothing when AUTO_DERIVE_HA_CLIENT_CONFIG is not "yes"
# or SAME_NAMESERVICE_COLLISION is not true.
#
# UNLIKE nameservice_cli_dgen_args() (used by the single-cluster-per-call
# standalone hdfs CLI calls above), this DOES retain the real/native
# nameservice name (SRC_NAMESERVICE, identical to DST_NAMESERVICE in the
# collision case) in "dfs.nameservices" alongside both aliases, and does NOT
# override that name's own dfs.ha.namenodes.*/dfs.namenode.rpc-address.*
# keys. Reason: `hadoop distcp` (unlike a plain `hdfs dfsadmin`/`hdfs dfs`
# call) submits a real YARN job - the ResourceManager's own background
# token-renewal thread and the NodeManager's container-localization step,
# and YARN's own internal cluster-startup code that resolves this admin
# host's "fs.defaultFS", all resolve nameservices from THEIR OWN static,
# cluster-wide hdfs-site.xml, not from this one CLI invocation's "-D" flags -
# dropping the native name from "dfs.nameservices" here would break that
# resolution exactly the same way it did in the sibling HDFS script (see
# resolve_active_namenode_hostport's doc comment there for the full history
# of that failure mode) even though NEITHER src_loc NOR dst_loc use the
# native name directly (both are rewritten to use DUMP_URI_NS/LOAD_URI_NS -
# see reconcile_external_table_data() below).
distcp_collision_dgen_args() {
  if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]] || [[ "$SAME_NAMESERVICE_COLLISION" != true ]]; then
    return 0
  fi
  printf -- "-Ddfs.nameservices=%s,%s,%s\n" "$SRC_NAMESERVICE" "$DUMP_URI_NS" "$LOAD_URI_NS"
  printf -- "-Ddfs.ha.automatic-failover.enabled=%s\n" "${AUTOMATIC_FAILOVER_ENABLED,,}"
  local nameservice nn_hosts_spec nn_ids pair nn_id nn_addr joined_ids nameservice_nn_hosts_pair
  for nameservice_nn_hosts_pair in "${DUMP_URI_NS}:${DUMP_NN_HOSTS}" "${LOAD_URI_NS}:${LOAD_NN_HOSTS}"; do
    nameservice="${nameservice_nn_hosts_pair%%:*}"
    nn_hosts_spec="${nameservice_nn_hosts_pair#*:}"
    nn_ids=()
    IFS=',' read -ra pairs <<< "$nn_hosts_spec"
    for pair in "${pairs[@]}"; do
      nn_id="${pair%%=*}"
      nn_addr="${pair#*=}"
      if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_id" == "$pair" ]]; then
        echo "[ERROR] Malformed NN host entry for nameservice '${nameservice}': '${pair}' (expected <nn-id>=<host>:<port>)" >&2
        exit 1
      fi
      nn_ids+=("$nn_id")
      printf -- "-Ddfs.namenode.rpc-address.%s.%s=%s\n" "$nameservice" "$nn_id" "$nn_addr"
    done
    joined_ids="$(IFS=,; echo "${nn_ids[*]}")"
    printf -- "-Ddfs.ha.namenodes.%s=%s\n" "$nameservice" "$joined_ids"
    printf -- "-Ddfs.client.failover.proxy.provider.%s=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider\n" "$nameservice"
  done
}

reconcile_external_table_data() {
  # The token-renewal-exclude property must name every authority that
  # actually appears in this distcp's src_loc/dst_loc URIs - BOTH sides, not
  # just the dump side, since both are passed to the same distcp invocation
  # and either could be foreign to whichever RM submits the job. Matches the
  # same both-sides pattern HDFS_TOKEN_EXCLUDE_PROP already uses for REPL
  # DUMP/LOAD (see derive_db_vars()). Uses DUMP_URI_NS/LOAD_URI_NS (the
  # aliases) in the same-nameservice-collision case, since that's what
  # src_loc/dst_loc are rewritten to below - excluding the raw shared name
  # instead would exclude an authority that no longer appears in either URI.
  local distcp_token_exclude_ns="${DUMP_NAMESERVICE},${LOAD_NAMESERVICE}"
  if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
    distcp_token_exclude_ns="${DUMP_URI_NS},${LOAD_URI_NS}"
  fi
  local distcp_token_exclude_opt="-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${distcp_token_exclude_ns}"

  # Same-nameservice-collision "-D" HA properties for this distcp
  # invocation - see distcp_collision_dgen_args()'s own doc comment.
  # Resolves to an empty array (harmless) whenever the collision-specific
  # ambiguity this exists to resolve is not actually present.
  local -a distcp_collision_dgen_arr=()
  mapfile -t distcp_collision_dgen_arr < <(distcp_collision_dgen_args)

  echo "$SUBSEP"
  echo "Reconciling external table data via manual distcp (EFFECTIVE_RECONCILE_EXTERNAL_DATA=true)..."
  echo "DistCp options: ${distcp_token_exclude_opt} -Dmapreduce.job.queuename=${YARN_QUEUE} ${distcp_collision_dgen_arr[*]} ${DISTCP_OPTS}"
  echo ""

  local tables_output tables
  local _stage_t0=$(date +%s)
  tables_output=$(beeline_exec "${LOAD_JDBC_URL}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "USE ${HIVE_DB_NAME}; SHOW TABLES;" 2>&1) || {
    echo "ERROR: Could not list tables in '${HIVE_DB_NAME}' on load target for data reconciliation (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
    return 1
  }
  tables=$(echo "$tables_output" | grep -E "^[A-Za-z0-9_]+$")
  echo "SHOW TABLES completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

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
  local -a distcp_dgen_arr=("$distcp_token_exclude_opt" -Dmapreduce.job.queuename="${YARN_QUEUE}" "${distcp_collision_dgen_arr[@]}")

  local tbl src_loc dst_loc
  local failed=0
  while IFS= read -r tbl; do
    [[ -z "$tbl" ]] && continue
    local _tbl_t0=$(date +%s)

    src_loc=$(table_location "$DUMP_JDBC_URL" "$HIVE_DB_NAME" "$tbl")
    dst_loc=$(table_location "$LOAD_JDBC_URL" "$HIVE_DB_NAME" "$tbl")

    if [[ -z "$src_loc" || -z "$dst_loc" ]]; then
      echo "ERROR: Could not resolve LOCATION for table '${tbl}' (source='${src_loc}' dest='${dst_loc}') - skipping distcp for this table"
      failed=1
      continue
    fi

    # table_location() reports each side's LOCATION exactly as that side's
    # OWN Hive/metastore natively understands it - i.e. using the raw,
    # literal DUMP_NAMESERVICE/LOAD_NAMESERVICE name, NEVER our synthetic
    # aliases (Hive has no knowledge of them). In the same-nameservice-
    # collision case, src_loc and dst_loc would therefore both come back as
    # "hdfs://<identical-real-name>/..." - indistinguishable from distcp's
    # point of view, exactly the "does this think it's copying from DR to
    # DR?" ambiguity already confirmed and fixed in the sibling HDFS script.
    # Rewrite each URI's authority to the corresponding alias so distcp
    # receives two genuinely distinct source/destination authorities.
    if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
      # Guard the rewrite: a bare "${var#pattern}" strip is a no-op on a
      # non-match rather than an error, so if src_loc/dst_loc ever doesn't
      # start with exactly the expected "hdfs://<name>" authority (a case
      # mismatch, an explicit host:port URI, a different scheme, or an
      # unrelated nameservice that merely shares a literal string prefix),
      # concatenating the alias in front would silently produce an
      # unresolvable double-scheme string instead of a clear error. Check
      # first and skip this table loudly if the assumption doesn't hold.
      if [[ "$src_loc" != "hdfs://${DUMP_NAMESERVICE}" && "$src_loc" != "hdfs://${DUMP_NAMESERVICE}/"* ]]; then
        echo "ERROR: Table '${tbl}' source LOCATION '${src_loc}' does not start with the expected authority 'hdfs://${DUMP_NAMESERVICE}' - cannot safely rewrite to the collision alias, skipping distcp for this table"
        failed=1
        continue
      fi
      if [[ "$dst_loc" != "hdfs://${LOAD_NAMESERVICE}" && "$dst_loc" != "hdfs://${LOAD_NAMESERVICE}/"* ]]; then
        echo "ERROR: Table '${tbl}' dest LOCATION '${dst_loc}' does not start with the expected authority 'hdfs://${LOAD_NAMESERVICE}' - cannot safely rewrite to the collision alias, skipping distcp for this table"
        failed=1
        continue
      fi
      src_loc="hdfs://${DUMP_URI_NS}${src_loc#hdfs://"${DUMP_NAMESERVICE}"}"
      dst_loc="hdfs://${LOAD_URI_NS}${dst_loc#hdfs://"${LOAD_NAMESERVICE}"}"
    fi

    echo "$SUBSEP"
    echo "Table  : ${HIVE_DB_NAME}.${tbl}"
    echo "Source : ${src_loc}"
    echo "Dest   : ${dst_loc}"
    echo "Executing: hadoop distcp ${distcp_token_exclude_opt} -Dmapreduce.job.queuename=${YARN_QUEUE} ${distcp_collision_dgen_arr[*]} ${DISTCP_OPTS} ${src_loc} ${dst_loc}"
    if ! run_as_hdfs hadoop distcp "${distcp_dgen_arr[@]}" "${distcp_opts_arr[@]}" "${src_loc}" "${dst_loc}"; then
      echo "ERROR: distcp failed for table '${tbl}' (${src_loc} -> ${dst_loc}) after $(format_duration $(( $(date +%s) - _tbl_t0 )))"
      failed=1
      continue
    fi
    echo "OK: reconciled ${HIVE_DB_NAME}.${tbl} in $(format_duration $(( $(date +%s) - _tbl_t0 ))) (LOCATION lookups + distcp)"
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
  echo "Direction : $REPLICATION_DIRECTION (DUMP: $DUMP_URI_NS -> LOAD: $LOAD_URI_NS)"
  echo "Log File  : $LOG_FILE"
  echo ""

  # Assert we are dumping from the primary, in EITHER direction - with SRC/DST
  # swapping supported, the direction label alone no longer tells you which
  # physical cluster this run dumps from. OPT-IN (default off) because it costs
  # one extra beeline invocation per database per run; see
  # PREFLIGHT_PRIMARY_CHECK's doc comment for when it is worth paying that.
  if [[ "${PREFLIGHT_PRIMARY_CHECK,,}" == "true" ]]; then
    if ! preflight_check_dump_side_is_primary "$DUMP_JDBC_URL" "$DUMP_URI_NS"; then
      echo "ERROR: Pre-flight check failed for ${HIVE_DB_NAME} - aborting replication"
      return 1
    fi
  fi

  ########################################
  # Step 1: Check whether the database already exists on the load target
  ########################################
  echo "$SUBSEP"
  echo "[1/${TOTAL_STEPS}] Checking if database exists on load target..."
  local _stage_t0=$(date +%s)

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
  echo "[1/${TOTAL_STEPS}] Completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

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
  local _stage_t0=$(date +%s)

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
  echo "[2/${TOTAL_STEPS}] Completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"

  # Exposes this run's mode to the main loop's per-database summary
  # (LAST_DB_MODE - see the "Main loop" section near the end of this
  # script) using the exact same label text this function's own
  # completion summary already prints below, for consistency. Set here
  # (right after BOOTSTRAP is decided) rather than only on success, so a
  # run that fails later still reports which mode it was attempting.
  LAST_DB_MODE=$([ "$BOOTSTRAP" = "true" ] && echo "Bootstrap + Incremental" || echo "Incremental Only")

  if [[ "$BOOTSTRAP" == "true" ]]; then
    # If bootstrap fails partway through, warn that the destination
    # database may be left in a partial state and should be checked
    # before re-running.
    trap 'echo ""; echo "ERROR: Bootstrap failed at $(date). The load-target database may be in an inconsistent state."; echo "Before re-running, check: REPL STATUS ${HIVE_DB_NAME} on the load target and clean up if needed."; echo "Log File: $LOG_FILE"' ERR

    if [[ "${HIVE_REPL_SNAPSHOT_COPY,,}" == "true" ]]; then
      local _stage_t0=$(date +%s)
      enable_external_table_snapshots "$DUMP_URI_NS"
      enable_external_table_snapshots "$LOAD_URI_NS"
      echo "Snapshot capability setup completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    fi

    if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
      echo "$SUBSEP"
      echo "External data copy will go through manual distcp for this run - verifying all tables in '${HIVE_DB_NAME}' are EXTERNAL_TABLE..."
      local _stage_t0=$(date +%s)
      if ! check_all_tables_external "$DUMP_JDBC_URL"; then
        echo "ERROR: Aborting bootstrap for ${HIVE_DB_NAME} - see error above (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
        trap - ERR
        return 1
      fi
      echo "EXTERNAL_TABLE check completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
      echo ""
    fi

    ########################################
    # Step 3: Bootstrap REPL DUMP on the dump source
    ########################################
    echo "$SUBSEP"
    echo "[3/${TOTAL_STEPS}] Running REPL DUMP on dump source (${DUMP_URI_NS}) (Bootstrap)..."
    local _stage_t0=$(date +%s)

    DUMP_CMD="REPL DUMP ${HIVE_REPL_SPEC} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_SRC}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    echo "$SUBSEP"
    echo "Executing: $DUMP_CMD"
    echo ""

    if ! beeline_exec "${DUMP_JDBC_URL}" -e "$DUMP_CMD"; then
      echo "ERROR: Bootstrap REPL DUMP failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      trap - ERR
      return 1
    fi
    echo "[3/${TOTAL_STEPS}] REPL DUMP completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    echo ""

    ########################################
    # Step 4: Bootstrap REPL LOAD on the load target
    ########################################
    echo "$SUBSEP"
    echo "[4/${TOTAL_STEPS}] Running REPL LOAD on load target (${LOAD_URI_NS}) (Bootstrap)..."
    local _stage_t0=$(date +%s)

    # 'hive.repl.run.data.copy.tasks.on.target'='true' is what makes
    # REPL LOAD actually copy external table data (from the source
    # external directory into REPL_EXTERNAL_BASE_DIR) as part of the LOAD
    # itself. Leaving this at "false" would silently skip copying
    # external table data, so it is always set explicitly here.
    #
    # EXCEPTION 1: when EFFECTIVE_RECONCILE_EXTERNAL_DATA=true (either the
    # user asked for RECONCILE_EXTERNAL_DATA=true, or SAME_NAMESERVICE_
    # COLLISION forces it - see that variable's doc comment), this is
    # deliberately set to "false" instead - REPL LOAD then recreates
    # metadata only (no data copy at all), and reconcile_external_table_data()
    # (called below) does the data copy itself via a manual per-table
    # `hadoop distcp`, which can genuinely skip files already present/
    # unchanged on the load target. See "RECONCILING PRE-EXISTING EXTERNAL
    # TABLE DATA" near the top of this file for why this exists.
    # EXCEPTION 2: when METADATA_ONLY=true, this is also set to "false" -
    # but unlike RECONCILE_EXTERNAL_DATA, no distcp backfill follows; data
    # is never copied at all. METADATA_ONLY takes priority in
    # EFFECTIVE_RECONCILE_EXTERNAL_DATA's own derivation, so only one of
    # these exceptions can be active in a given run.
    local load_data_copy_flag="true"
    if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
      load_data_copy_flag="false"
      if [[ "${RECONCILE_EXTERNAL_DATA,,}" == "true" ]]; then
        echo "RECONCILE_EXTERNAL_DATA=true - bootstrap LOAD will be metadata-only; data copy is done via manual distcp after LOAD completes."
      else
        echo "SAME_NAMESERVICE_COLLISION - bootstrap LOAD will be metadata-only; data copy is done via manual distcp after LOAD completes (Hive's own internal data copy cannot resolve this scenario correctly - see EFFECTIVE_RECONCILE_EXTERNAL_DATA's doc comment)."
      fi
    elif [[ "${METADATA_ONLY,,}" == "true" ]]; then
      load_data_copy_flag="false"
      echo "METADATA_ONLY=true - bootstrap LOAD will be metadata-only; no table data will be copied."
    fi

    LOAD_CMD="REPL LOAD ${HIVE_DB_NAME} INTO ${HIVE_DB_NAME} WITH(
${HDFS_TOKEN_EXCLUDE_PROP}
$(ha_config_props)
'hive.repl.rootdir'='${REPL_ROOT_DIR_DST}',
'hive.repl.run.data.copy.tasks.on.target'='${load_data_copy_flag}',
'hive.repl.include.external.tables'='true',
'hive.repl.bootstrap.external.tables'='true',
$(metadata_only_dump_prop)
$(snapshot_copy_props)
$(materialized_view_props)
'hive.repl.replica.external.table.base.dir'='${REPL_EXTERNAL_BASE_DIR}'
);"

    # REPL_EXTERNAL_BASE_DIR's authority is always the RAW LOAD_NAMESERVICE
    # (see compute_repl_external_base_dir() call in derive_db_vars() - never
    # LOAD_URI_NS, even in the same-nameservice-collision case), so no -D
    # HA-resolution flags are needed here: this standalone "hdfs dfs" call
    # runs on whichever host this script executes on, and the raw name is
    # always natively resolvable via that cluster's own hdfs-site.xml.
    echo "Ensuring external table base directory exists on load target: ${REPL_EXTERNAL_BASE_DIR}"
    run_as_hdfs hdfs dfs -mkdir -p "${REPL_EXTERNAL_BASE_DIR}" || true
    run_as_hdfs hdfs dfs -chmod 1777 "${REPL_EXTERNAL_BASE_DIR}" || true
    echo ""

    echo "$SUBSEP"
    echo "Executing: $LOAD_CMD"
    echo ""

    if ! beeline_exec_load "${LOAD_JDBC_URL}" -e "$LOAD_CMD"; then
      echo "ERROR: Bootstrap REPL LOAD failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
      trap - ERR
      return 1
    fi
    echo "[4/${TOTAL_STEPS}] REPL LOAD completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    echo ""

    if [[ "$EFFECTIVE_RECONCILE_EXTERNAL_DATA" == "true" ]]; then
      local _stage_t0=$(date +%s)
      if ! reconcile_external_table_data; then
        echo "ERROR: External data reconciliation failed for ${HIVE_DB_NAME} (after $(format_duration $(( $(date +%s) - _stage_t0 ))))"
        trap - ERR
        return 1
      fi
      echo "External data reconciliation completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
    fi

    ########################################
    # Step 5: Post-load validation
    ########################################
    echo "$SUBSEP"
    echo "[5/${TOTAL_STEPS}] Validating replication status on load target..."
    local _stage_t0=$(date +%s)
    echo ""

    beeline_exec "${LOAD_JDBC_URL}" -e "REPL STATUS ${HIVE_DB_NAME};" || echo "WARN: REPL STATUS check failed for ${HIVE_DB_NAME} (informational only - bootstrap DUMP/LOAD already succeeded)"
    echo "[5/${TOTAL_STEPS}] Completed in $(format_duration $(( $(date +%s) - _stage_t0 )))"
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
  echo "Dump source  : $DUMP_URI_NS"
  echo "Load target  : $LOAD_URI_NS"
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
#
# This is set up BEFORE expand_db_specs() runs (not after) so that
# expand_db_specs()'s own output - which literal database each regex in
# HIVE_DB actually matched - is captured here too, not just printed to the
# console. Without that ordering, an unattended run (cron/orchestration -
# this script's own stated primary use case) would have no durable record
# of what a database regex actually resolved to for that run; only a
# human watching the console in real time would ever see it.
########################################

mkdir -p "$LOG_DIR"
SESSION_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Fold the database name(s) for this invocation into the session log
# filename so it can be identified from `ls` alone, without opening the
# file - the per-database log files already do this (see LOG_FILE in
# replicate_one_db()/failover_one_db()), but until now the session log
# covering the whole run did not. A single DB spec contributes its DB name
# only (the table pattern, if any, is dropped - it can contain regex
# characters unsafe for a filename); multiple DB specs are joined with
# "+"; beyond 3 DBs, the name is truncated to the first 3 plus a count, to
# keep the filename from growing unbounded for a large multi-DB run.
#
# This runs on the PRE-expansion DB_SPECS (a database regex has not been
# resolved to literal names yet at this point - see above) - for the
# common case of literal-only DB_SPECS this produces the exact same label
# as before; a database-regex entry instead contributes a sanitized
# fragment of its own regex text (e.g. "'sales_.*'" -> "sales_"), not the
# real database names it will later resolve to. That is an acceptable
# trade-off for a log FILENAME - the real resolved names are always in the
# log's CONTENT, from expand_db_specs()'s own output further down.
SESSION_DB_LABEL=""
for db_spec in "${DB_SPECS[@]}"; do
  db_name_only="${db_spec%%.*}"
  db_name_only="${db_name_only//[^A-Za-z0-9_]/}"
  [[ -z "$db_name_only" ]] && continue
  if [[ -z "$SESSION_DB_LABEL" ]]; then
    SESSION_DB_LABEL="$db_name_only"
  else
    SESSION_DB_LABEL="${SESSION_DB_LABEL}+${db_name_only}"
  fi
done
if [[ ${#DB_SPECS[@]} -gt 3 ]]; then
  SESSION_DB_LABEL=$(printf '%s\n' "${DB_SPECS[@]:0:3}" | sed -E 's/\..*$//; s/[^A-Za-z0-9_]//g' | paste -sd+ -)
  SESSION_DB_LABEL="${SESSION_DB_LABEL}+${#DB_SPECS[@]}dbs"
fi

SESSION_LOG_FILE="$LOG_DIR/hive_bdr_session_${SESSION_DB_LABEL}_${SESSION_TIMESTAMP}.log"

exec > >(tee -a "$SESSION_LOG_FILE") 2>&1

# Re-point fd 3 (opened earlier, at script startup) at the now-active
# session-log "tee" pipeline, so heartbeat/debug messages written to fd 3
# reach both the console and SESSION_LOG_FILE - while still never sharing
# a file descriptor with output a caller captures via $(...).
exec 3>&1

SEP="======================================================================"
SUBSEP="----------------------------------------------------------------------"

# Resolve any database regex in HIVE_DB into concrete database names now
# that session logging is active - see the comment above. Everything
# below this point (DB_COUNT, the main per-database loop) reads DB_SPECS
# - see expand_db_specs() above.
expand_db_specs

DB_COUNT=${#DB_SPECS[@]}

echo "$SEP"
echo " Hive Cluster Replication Script Started"
echo "$SEP"
echo "Timestamp    : $(date)"
echo "Databases    : ${DB_COUNT} (${HIVE_DB})"
echo "SRC (fixed)  : $SRC_NAMESERVICE"
echo "DST (fixed)  : $DST_NAMESERVICE"
if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
  echo "  (same-nameservice collision: SRC and DST share this name across two different physical"
  echo "   clusters - disambiguated internally via SRC_NN_HOSTS=${SRC_NN_HOSTS} / DST_NN_HOSTS=${DST_NN_HOSTS})"
fi
echo "Direction    : $REPLICATION_DIRECTION"
if [[ "$DIRECTION_CHANGE" == true ]]; then
  echo "Run type     : DIRECTION CHANGE (${DIRECTION_CHANGE_KIND}) - flips which cluster is primary,"
  echo "               copies NO table data, converges over up to ${FAILOVER_MAX_ROUNDS} DUMP/LOAD rounds"
else
  echo "Run type     : ongoing replication (bootstrap/incremental) - copies table data"
fi

# ------------------------------------------------------------------------------
#  Print the RESOLVED dump/load role mapping for this run, so the direction
#  swap is visible in the log up front rather than only implied by
#  REPLICATION_DIRECTION.
#
#  This matters most in the SAME_NAMESERVICE_COLLISION case: SRC_NAMESERVICE
#  and DST_NAMESERVICE are the identical string there, so the two lines above
#  look the same in BOTH directions and give an operator no way to confirm the
#  swap actually happened. What carries the direction in that case is which
#  physical NameNodes each fixed alias is bound to - so that binding is what
#  gets printed.
#
#  Computed with banner-local variables (NOT DUMP_NN_HOSTS/LOAD_NN_HOSTS):
#  derive_db_vars() has not run yet at this point in the script - it runs
#  per-database inside the main loop below - so those variables are still
#  unset here and referencing them would abort under `set -u`. The mapping
#  itself depends only on REPLICATION_DIRECTION, never on the database, so it
#  is safe to derive it here with the exact same conditional derive_db_vars()
#  uses.
# ------------------------------------------------------------------------------
if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
  _banner_dump_label="DST"; _banner_load_label="SRC"
  _banner_dump_nn="$DST_NN_HOSTS"; _banner_load_nn="$SRC_NN_HOSTS"
  _banner_dump_jdbc="$DST_JDBC_URL"; _banner_load_jdbc="$SRC_JDBC_URL"
else
  _banner_dump_label="SRC"; _banner_load_label="DST"
  _banner_dump_nn="$SRC_NN_HOSTS"; _banner_load_nn="$DST_NN_HOSTS"
  _banner_dump_jdbc="$SRC_JDBC_URL"; _banner_load_jdbc="$DST_JDBC_URL"
fi
echo "Resolved roles for this run (${REPLICATION_DIRECTION}):"
echo "  REPL DUMP on : ${_banner_dump_label}  jdbc=${_banner_dump_jdbc}"
if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
  echo "                 nn=${_banner_dump_nn}"
fi
echo "  REPL LOAD on : ${_banner_load_label}  jdbc=${_banner_load_jdbc}"
if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
  echo "                 nn=${_banner_load_nn}"
fi
if [[ "$REPLICATION_DIRECTION" == "dst_to_src" ]]; then
  echo "  (REPLICATION_DIRECTION=dst_to_src - SRC/DST nameservice, JDBC URL and NN_HOSTS are"
  echo "   swapped into these roles internally. Swapping them yourself instead and leaving the"
  echo "   direction as src_to_dst reaches the same place: the staging path is keyed to the"
  echo "   DUMPING cluster, not to the direction label, so both routes read the same rootdir.)"
fi
if [[ "$SAME_NAMESERVICE_COLLISION" == true ]]; then
  echo "Staging dir  : ${REPL_BASE_DIR}<db>/from_$([ "$REPLICATION_DIRECTION" == "dst_to_src" ] && echo "$DST_ROOT_TOKEN" || echo "$SRC_ROOT_TOKEN")${REPL_ROOT_SUFFIX:+  (overridden: from_${REPL_ROOT_SUFFIX})}"
fi
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
# csv_field: quote a single CSV field per RFC 4180 (wrap in double quotes,
# double up any embedded double quote). Only ever applied to db_spec below
# - every other column is a value this script itself constructs from a
# fixed, known set of literal strings (mode/direction/status labels, an
# ISO timestamp, a plain integer), so it can never contain a "," or '"'
# and does not need escaping - skipping it for those columns avoids 7 of
# the 8 per-database subshells this would otherwise cost.
csv_field() { printf '"%s"' "${1//\"/\"\"}"; }

# RUN_SUMMARY_CSV - one row per database, appended immediately after that
# database finishes (not built up and written once at the end), so a run
# killed partway through (e.g. database 500 of 1000) still leaves a
# complete, readable record of every database that finished before that.
RUN_SUMMARY_CSV="$LOG_DIR/hive_bdr_session_${SESSION_DB_LABEL}_${SESSION_TIMESTAMP}_summary.csv"
echo 'db_spec,mode,direction,status,start_time,end_time,duration_seconds,error' > "$RUN_SUMMARY_CSV"

# STATUS_FILE - a small, cheap-to-read snapshot of overall progress,
# overwritten after every database. Session-specific (not a fixed
# "latest" name) so two concurrent invocations of this script for
# different database sets never clobber each other's status - the same
# reason SESSION_LOG_FILE/RUN_SUMMARY_CSV are session-specific too.
# Written via a temp file + atomic rename (not a direct "> $STATUS_FILE"
# overwrite) so a monitor reading it can never observe a truncated/
# half-written file mid-update.
STATUS_FILE="$LOG_DIR/hive_bdr_session_${SESSION_DB_LABEL}_${SESSION_TIMESTAMP}_status.txt"
RUN_STARTED_AT="$(date -Iseconds 2>/dev/null || date)"

DB_IDX=0
FAILED_DBS=()
for db_spec in "${DB_SPECS[@]}"; do
  DB_IDX=$(( DB_IDX + 1 ))
  echo "$SEP"
  echo " Processing DB ${DB_IDX}/${DB_COUNT}: ${db_spec}"
  echo "$SEP"

  db_start_epoch=$(date +%s)
  db_start_iso="$(date -Iseconds 2>/dev/null || date)"
  LAST_DB_MODE=""
  db_status="SUCCESS"
  db_error=""

  # DISPATCH KEYED ON DIRECTION_CHANGE, NOT ON REPLICATION_DIRECTION. This
  # used to read `REPLICATION_DIRECTION == dst_to_src`, which made "reversed
  # direction" and "failover" the same thing and left ongoing replication in
  # the reversed direction (dst_to_src + DIRECTION_CHANGE=false) and failback
  # (src_to_dst + DIRECTION_CHANGE=true) unreachable - see DIRECTION_CHANGE's
  # doc comment near the top of this file for the full four-state table.
  if [[ "$DIRECTION_CHANGE" == true ]]; then
    LAST_DB_MODE="$DIRECTION_CHANGE_KIND"
    if ! failover_one_db "$db_spec" "$DB_IDX" "$DB_COUNT"; then
      echo "ERROR: ${DIRECTION_CHANGE_KIND} (direction change) failed for DB spec: ${db_spec}"
      FAILED_DBS+=("$db_spec")
      db_status="FAILED"
      db_error="${DIRECTION_CHANGE_KIND} (direction change) failed"
    fi
  else
    if ! replicate_one_db "$db_spec" "$DB_IDX" "$DB_COUNT"; then
      echo "ERROR: Replication failed for DB spec: ${db_spec}"
      FAILED_DBS+=("$db_spec")
      db_status="FAILED"
      db_error="Replication failed"
    fi
  fi

  db_end_epoch=$(date +%s)
  db_end_iso="$(date -Iseconds 2>/dev/null || date)"
  db_duration=$(( db_end_epoch - db_start_epoch ))
  echo "Duration  : $(format_duration "$db_duration")"

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_field "$db_spec")" "${LAST_DB_MODE:-unknown}" "$REPLICATION_DIRECTION" \
    "$db_status" "$db_start_iso" "$db_end_iso" "$db_duration" "$db_error" >> "$RUN_SUMMARY_CSV"

  {
    echo "run_started: $RUN_STARTED_AT"
    echo "last_updated: $(date -Iseconds 2>/dev/null || date)"
    echo "databases_total: $DB_COUNT"
    echo "databases_done: $DB_IDX"
    echo "databases_failed: ${#FAILED_DBS[@]}"
    echo "current_db: $db_spec"
    echo "last_db_status: $db_status"
    echo "last_db_duration_seconds: $db_duration"
    echo "session_log: $SESSION_LOG_FILE"
    echo "summary_csv: $RUN_SUMMARY_CSV"
  } > "${STATUS_FILE}.tmp"
  mv -f "${STATUS_FILE}.tmp" "$STATUS_FILE"
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
  echo "Run Summary: $RUN_SUMMARY_CSV"
  exit 1
fi
echo ""
echo "Session Log: $SESSION_LOG_FILE"
echo "Run Summary: $RUN_SUMMARY_CSV"
