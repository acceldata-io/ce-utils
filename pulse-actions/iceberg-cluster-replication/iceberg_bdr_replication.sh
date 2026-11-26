#!/bin/bash
# ==============================================================================
#  ICEBERG TABLE REPLICATION SCRIPT
#  Copyright (c) 2026 Acceldata Inc. All rights reserved.
# ==============================================================================
#
#  PURPOSE
#  -------
#  Replicates Apache Iceberg tables from a source cluster to a destination (DR) cluster, and is
#  designed to run as a Pulse "New Action".
#
#  WHY THIS EXISTS (Iceberg needs different handling than plain Hive tables)
#  ---------------------------------------------------------------------------
#  For a managed/external Hive table, the data files ARE the table -- a directory copy is enough.
#  Iceberg is different: the real source of truth is a chain of metadata files --
#
#      metadata.json -> manifest lists -> manifest files -> data files
#
#  -- and every file in that chain embeds ABSOLUTE paths (including the cluster's NameService
#  name). A verbatim directory copy across a NameService change leaves every one of those
#  pointers dangling, even though the underlying bytes copied correctly. Neither Hive's REPL
#  DUMP/LOAD nor a plain `hadoop distcp` of the table directory understands this snapshot model,
#  so this script drives Iceberg's own replication primitives instead, one table at a time:
#
#    STEP 1 - Verify the source table is an Iceberg table and read its metadata pointer
#             (metadata_location, format-version, table location).
#    STEP 2 - Check the table's Iceberg format-version against what this runtime can replicate
#             (see "ICEBERG FORMAT-VERSION SUPPORT" below).
#    STEP 3 - Read the CHECKPOINT (the source's last-replicated metadata.json, if any). Its
#             presence/absence decides bootstrap vs. incremental mode; a missing checkpoint for
#             a table that already exists on the destination is re-derived (auto-seed).
#    STEP 4 - CALL <catalog>.system.rewrite_table_path(...) against the SOURCE catalog. This
#             stages a path-corrected copy of the table's metadata (manifests, manifest lists,
#             metadata.json) into a staging directory, rewriting every source NameService prefix
#             to the destination NameService prefix, and returns an exact file list
#             (source,target CSV) of every file that changed.
#               - Bootstrap  -> full rewrite (every reachable metadata file)
#               - Incremental -> only metadata added since the checkpoint
#    STEP 5 - Copy EXACTLY the files named in that list (never a whole-directory copy), writing
#             each file straight to its exact target path.
#    STEP 6 - Point the destination catalog at the new metadata:
#               - Bootstrap  -> CALL <catalog>.system.register_table(...) (first registration
#                               only; fails if the table is already registered)
#               - Incremental -> ALTER TABLE ... SET TBLPROPERTIES ('metadata_location'=...) to
#                               re-point the already-registered table at the new path-corrected
#                               metadata.json
#    STEP 7 - Validate that the destination sits on the snapshot of the source version that was
#             replicated, and ONLY THEN write the new checkpoint. A failed run leaves the
#             last-good checkpoint untouched, so the next run safely retries the same delta
#             (idempotent, resumable).
#    STEP 8 - Print the table's summary and stage timings.
#  These are the STEP numbers the run log prints; a table with nothing new skips STEPs 4-6.
#
#  MODES OF OPERATION
#  -------------------
#    - Bootstrap mode    : No checkpoint exists yet for the table on the destination. Runs a
#                           complete-copy rewrite_table_path + register_table (first
#                           registration).
#    - Incremental mode  : A checkpoint already exists (either written by a prior run of this
#                           script, or pre-seeded against a DR cluster some other tool already
#                           populated). Runs an incremental rewrite_table_path (start_version =
#                           checkpoint) + a metadata re-point to the newest snapshot.
#    - Multi-table mode  : One invocation can replicate many databases/tables at once via
#                           INCLUDE_FILTERS (see below). Each resolved table is replicated
#                           independently: one table's failure never blocks the others, and a
#                           final summary reports success/failure per table.
#
#  SCOPE BOUNDARY: ROW/FILE DELETIONS ARE REPLICATED AS DATA, NOT AS DESTINATION STORAGE RECLAMATION
#  -----------------------------------------------------------------------------------------------------
#  A row deleted on source IS correctly reflected as deleted when querying the destination table: Iceberg
#  v2/v3 delete files (position deletes, equality deletes, v3 Puffin deletion vectors) are themselves
#  files in the manifest lineage, so rewrite_table_path picks them up and copies them like any other
#  referenced file, and the destination's query engine applies them at read time exactly as source's
#  does. This required no special handling here beyond STEP 2's existing v2/v3 compatibility gate.
#
#  What this script does NOT do is reclaim destination STORAGE. rewrite_table_path's file list is
#  strictly additive -- "every file added between start_version and end_version" -- and the Spark copier
#  never deletes a file already present on the destination. So when
#  source later runs expire_snapshots/remove_orphan_files (or its own retention policy prunes old
#  metadata/delete files that are no longer referenced), the now-unreferenced physical files are removed
#  from SOURCE's HDFS footprint, but the DESTINATION keeps its now-stale copies forever. Net effect:
#  destination storage grows monotonically over time even when source's footprint is bounded by its own
#  retention policy. This is a known, accepted scope boundary, not an oversight -- destination-side
#  expire_snapshots/remove_orphan_files is real, irreversible file deletion on DR and deliberately is NOT
#  automated here; running it safely requires coordinating its retention window against replication
#  cadence (so DR never expires a snapshot a still-in-flight or delayed replication run still depends on)
#  and is an operational decision for the cluster operator to make explicitly, table by table.
#
# USAGE
# -----
#   ./iceberg_bdr_replication.sh \
#     "<INCLUDE_FILTERS>" \
#     "<SRC_NAMESERVICE>" \
#     "<DST_NAMESERVICE>" \
#     "<SRC_JDBC_URL>" \
#     "<DST_JDBC_URL>" \
#     "<SRC_METASTORE_URI>" \
#     "<DST_METASTORE_URI>" \
#     "<LOG_DIR>" \
#     "<CHECKPOINT_DIR>" \
#     "<HDFS_USER>" \
#     "<SPARK_USER>" \
#     "<REBUILD_DST_TABLE_FROM_SOURCE>" \
#     "<SPARK_TUNING>" \
#     "<SPARK_EXTRA_CONF>" \
#     "<SEED_CHECKPOINT>"
#
# POSITIONAL ARGUMENTS
# ---------------------
#   All arguments are positional, NOT environment variables. This is deliberate: Pulse Actions
#   has no facility to pass environment variables into a script invocation, only positional
#   arguments. Order matters.
#
#   ARGUMENT ORDER. The script takes up to 15 positional arguments, listed below. An older
#   argument order had DISTCP_OPTS (distcp preserve/update flags) as slot #6; that slot no
#   longer exists, so LOG_DIR and everything after it sit one slot earlier than they did then.
#   The STEP 5 copy engine and its options are chosen with environment variables (COPY_ENGINE,
#   DISTCP_*), not with an argument. A caller still passing the old 13-argument form -- Pulse
#   Action configs in particular -- must drop the DISTCP_OPTS string. A startup guard (see
#   check_retired_distcp_opts_arg below) recognises that form by slot #6 not being a thrift://
#   URI and aborts with an explicit message rather than letting LOG_DIR silently absorb
#   "-pbugpcaxt -update -skipcrccheck" and every later argument land one slot off.
#
#   #   Name                           Required?   Default                                    Description
#   --  -----------------------------  ----------  -----------------------------------------  ------------------------------------------------
#   1   INCLUDE_FILTERS                MANDATORY   (none)                                     Tables to replicate. See "INCLUDE_FILTERS" below.
#   2   SRC_NAMESERVICE                MANDATORY   (none)                                     Source cluster's logical HA nameservice name.
#   3   DST_NAMESERVICE                MANDATORY   (none)                                     Destination cluster's logical HA nameservice name.
#   4   SRC_JDBC_URL                   MANDATORY   (none)                                     Source HiveServer2 JDBC URL (beeline catalog reads).
#   5   DST_JDBC_URL                   MANDATORY   (none)                                     Destination HiveServer2 JDBC URL.
#   6   SRC_METASTORE_URI              MANDATORY   (none)                                     Source Hive Metastore Thrift URI, e.g. thrift://host:9083.
#   7   DST_METASTORE_URI              MANDATORY   (none)                                     Destination Hive Metastore Thrift URI, e.g. thrift://host:9083.
#   8   LOG_DIR                        optional    /var/log/iceberg-replication               Run logs and per-table replication artifacts.
#   9   CHECKPOINT_DIR                 optional    /tmp/pulse_iceberg_replication_action      One checkpoint per table+direction. HDFS path, mirrored on both clusters.
#   10  HDFS_USER                      optional    hdfs                                       User for hadoop fs/hdfs, when Kerberos is NOT in use.
#   11  SPARK_USER                     optional    (same as HDFS_USER)                        User for spark-sql/spark-shell, when Kerberos is NOT in use.
#   12  REBUILD_DST_TABLE_FROM_SOURCE  optional    false                                      "true" to rebuild an unrelated destination table from source. See below.
#   13  SPARK_TUNING                   optional    (none, i.e. env-var/cluster defaults)     "key=value,..." Spark tuning knobs (queue, executor/driver sizing, dynamic allocation). See below.
#   14  SPARK_EXTRA_CONF                optional    (none)                                     Raw "--conf k=v ..." string, any Spark property, applied to both Spark jobs. See below.
#   15  SEED_CHECKPOINT                optional    false                                      "true" to only seed checkpoints and replicate NOTHING this run. See below.
#
#   Argument details:
#
#   1) INCLUDE_FILTERS (MANDATORY)
#      Comma-separated "database:table_regex" pairs.
#        Examples:
#          "sales_db:orders"                    one table: sales_db.orders and nothing else (the
#                                               match is anchored, so "orders" does not also
#                                               match "orders_2024" or "old_orders")
#          "sales_db:orders,sales_db:customers" two named tables of one database, as two rows
#          "sales_db:orders|customers"          the same two tables, as one row (regex alternation)
#          "sales_db:orders_.*,analytics:.*"    every sales_db table starting with "orders_", and
#                                               every table of analytics
#      For each listed database, every table whose name fully matches that regex (anchored,
#      full-string match, not a substring search) becomes a replication candidate. A bare
#      database name with no ":" is shorthand for "db:.*" (every table in that database).
#      Multiple rows for the same database are allowed; their matches are combined (union).
#      Details of how the spec is read:
#        - Rows are separated by commas, but a comma inside brackets belongs to the regex:
#          "sales_db:orders_[0-9]{1,3}" is ONE row. Whitespace around a row is ignored.
#        - Database names and table matching are case-insensitive, as they are in Hive:
#          "SALES_DB:Orders_.*" is the same as "sales_db:orders_.*", and resolves to the same
#          table, checkpoint and lock.
#        - A database that does not exist on the source (or cannot be listed), an invalid
#          database name, or a regex that does not compile: that row is skipped and reported,
#          every OTHER row is still replicated, and the run ends FAILED so it cannot be missed.
#        - A row whose regex matches no table is logged as a warning (it replicates nothing),
#          and listed under "Filter warnings" in the run summary.
#      Only Iceberg tables among the matches are actually replicated -- a matched table that
#      turns out to be a non-Iceberg table (e.g. plain Hive/Parquet) is skipped with a logged
#      reason, not treated as a hard failure for the whole run.
#
#   2) SRC_NAMESERVICE (MANDATORY)
#      The source cluster's nameservice name, used for CLI/logging purposes and to build the
#      cluster-level HA configuration (see AUTO_DERIVE_HA_CLIENT_CONFIG below). NOTE: the actual
#      `source_prefix` used for path rewriting is derived per-table from that table's real
#      LOCATION, not from this argument -- see the per-table WARN check later in the script for
#      what happens if they disagree.
#
#   3) DST_NAMESERVICE (MANDATORY)
#      The destination cluster's nameservice name. This MUST be the destination's LOGICAL HA
#      nameservice (e.g. "ODP-Phoenix-DR"), never a literal "host:port". If a literal host:port
#      is used instead, registered destination tables will fail to resolve after an HA failover,
#      because the Metastore row would point at one specific NameNode instead of the HA-aware
#      logical name. See "HA nameservice resolution" further below for the full explanation.
#
#   4) SRC_JDBC_URL (MANDATORY)
#      Source HiveServer2 JDBC connection URL, used for beeline catalog reads (SHOW
#      TBLPROPERTIES, DESCRIBE FORMATTED, etc.).
#        Example: "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2"
#
#   5) DST_JDBC_URL (MANDATORY)
#      Destination HiveServer2 JDBC connection URL. Same format as SRC_JDBC_URL above.
#
#   6) SRC_METASTORE_URI (MANDATORY)
#      Source Hive METASTORE Thrift URI, e.g. "thrift://host:9083". NOT the same thing as
#      SRC_JDBC_URL: this is the Metastore service (typically port 9083) that spark-sql's Iceberg
#      Hive catalog talks to directly, whereas SRC_JDBC_URL is HiveServer2 (typically port 10000,
#      or ZooKeeper discovery on 2181). Required for every "CALL <catalog>.system.*" procedure
#      call to resolve the table.
#
#   7) DST_METASTORE_URI (MANDATORY)
#      Destination Hive METASTORE Thrift URI. Same format/distinction as SRC_METASTORE_URI
#      above.
#
#   8) LOG_DIR (optional, default: "/var/log/iceberg-replication")
#      Directory where this script writes its run log, plus per-table replication artifacts: a
#      file-list CSV for every run. The run log is named
#      "iceberg_bdr_run_<databases>_<YYYYmmdd_HHMMSS>_<pid>.log", where <databases> is taken
#      from INCLUDE_FILTERS -- one run covering "sales_db:orders_.*" writes
#      iceberg_bdr_run_sales_db_20260903_152256_41873.log, and a run spanning several databases joins
#      them with "-" (collapsing to "<db1>-<db2>-<db3>+Nmore" past the first three, so the name
#      stays a sane length), followed by the PID of the run so two runs started in the same
#      second never share a file. After a SUCCESSFUL run, only the most recent runs (see
#      KEEP_RUN_ARTIFACTS, currently 5) are kept per table -- a FAILED run's artifacts are exempt
#      from that rule, since they're needed for debugging. Run logs and failed-run artifacts are
#      instead removed by age, once older than LOG_RETENTION_DAYS (env var, default 30 days,
#      0 = keep forever).
#
#   9) CHECKPOINT_DIR (optional, default: "/tmp/pulse_iceberg_replication_action")
#      HDFS path holding one checkpoint per table PER REPLICATION DIRECTION, mirrored onto BOTH
#      SRC's and DST's nameservice (see "CHECKPOINT ON HDFS" further below for the full mechanism,
#      and "TABLE LOCATION AND THE CHECKPOINT" for what a checkpoint is and why it's scoped by
#      direction). Not a local-disk path -- this script creates it on both clusters' HDFS at
#      startup if it does not already exist. Must be a plain absolute path (no "hdfs://" prefix;
#      the script adds each cluster's nameservice itself). A local directory of the SAME path is
#      also used on the host running the script, for the per-table lock files only, and must be
#      writable by the OS user running it. The default sits under HDFS /tmp, which cleanup
#      policies commonly sweep: a swept checkpoint is re-derived automatically (auto-seed), at
#      the cost of one Spark lookup per table, so a dedicated path outside /tmp is preferable
#      for a production schedule.
#
#   10) HDFS_USER (optional, default: "hdfs")
#       The user to run `hadoop fs` / `hdfs` commands as, when Kerberos is NOT detected (via
#       `sudo -u`). Ignored entirely when Kerberos IS detected -- in that case the current
#       user's active ticket is used instead.
#
#   11) SPARK_USER (optional, default: same value as HDFS_USER)
#       The user to run `spark-sql`/`spark-shell` as, when Kerberos is NOT detected (via
#       `sudo -E -u`). Also used, even when Kerberos IS detected, to select the correct Kerberos
#       credential cache by principal name when multiple caches are present on disk (the Pulse
#       Actions scenario, where multiple service tickets can coexist).
#
#   12) REBUILD_DST_TABLE_FROM_SOURCE (optional, default: "false")
#       "true" or "false". See "REBUILDING A DESTINATION TABLE THAT DOES NOT TRACE BACK TO SOURCE" further below for
#       the full explanation of what this does and when it's needed. Left at the default "false" this
#       argument has no effect at all -- it only changes behavior for a table whose destination already
#       exists but does not trace back to source's history (auto-seed's specific failure case).
#       NOTE: for backward compatibility with existing callers (e.g. Pulse Actions configs already
#       passing only the first 11 arguments), this can ALSO still be passed as a bare `--rebuild-dst-table-from-source`
#       flag token anywhere on the command line, in addition to being read positionally here -- either
#       form sets the same behavior; passing both is harmless.
#       RENAMED: this was previously called FORCE_RESEED_NONMATCHING / --force-reseed-nonmatching.
#       "reseed" wrongly suggested it only re-seeds a checkpoint (it rebuilds the entire destination
#       table), and "nonmatching" never said what was being matched against what. The old FLAG TOKEN
#       `--force-reseed-nonmatching` is still accepted as a deprecated alias, with a [WARN] naming the
#       new spelling, so existing callers keep working unchanged. The old ENV/positional spelling is
#       gone -- argument 12 is positional, so its name matters only to whoever reads this file.
#
#   13) SPARK_TUNING (optional, default: "" -- no override, env vars/cluster spark-defaults.conf apply)
#       A compact, positional way to set the Spark tuning knobs documented under "WHERE THE SPARK JOB
#       RUNS"/"SPARK_COPIER_*"/"SPARK_REWRITE_*" further below, for callers -- Pulse Actions in
#       particular -- that can only pass positional arguments, never environment variables. Exists
#       because argument 12 is the last argument every EXISTING caller already passes; this is
#       additive at the end, so a caller that never needs to tune Spark can simply omit it (or pass
#       "") and see no behavior change at all.
#       Format: comma-separated "key=value" pairs, no spaces around "=" or "," (matches the same
#       whitespace-only-split convention SPARK_REWRITE_EXTRA_ARGS/SPARK_COPIER_EXTRA_ARGS already use):
#         export SPARK_TUNING="queue=repl_low,rewrite_cores=2,rewrite_mem=4g,rewrite_dynamic=false,rewrite_max_executors=4,copier_cores=1,copier_mem=1g,copier_dynamic=false,copier_max_executors=10"
#       Recognized keys, each setting exactly the same-named env var documented below (see
#       apply_spark_tuning_arg() for the full mapping):
#         queue                 -> SPARK_QUEUE
#         yarn_archive          -> SPARK_YARN_ARCHIVE
#         rewrite_cores         -> SPARK_REWRITE_EXECUTOR_CORES
#         rewrite_mem           -> SPARK_REWRITE_EXECUTOR_MEMORY
#         rewrite_dynamic       -> SPARK_REWRITE_DYNAMIC_ALLOCATION ("true"/"false")
#         rewrite_max_executors -> SPARK_REWRITE_MAX_EXECUTORS (fixed --num-executors when rewrite_dynamic=false)
#         rewrite_driver_mem    -> SPARK_REWRITE_DRIVER_MEMORY
#         rewrite_driver_cores  -> SPARK_REWRITE_DRIVER_CORES
#         copier_cores          -> SPARK_COPIER_EXECUTOR_CORES
#         copier_mem            -> SPARK_COPIER_EXECUTOR_MEMORY
#         copier_dynamic        -> SPARK_COPIER_DYNAMIC_ALLOCATION ("true"/"false")
#         copier_max_executors  -> SPARK_COPIER_MAX_EXECUTORS (fixed --num-executors when copier_dynamic=false)
#         copier_driver_mem     -> SPARK_COPIER_DRIVER_MEMORY
#         copier_driver_cores   -> SPARK_COPIER_DRIVER_CORES
#       An unrecognized key, or an entry with no "=", is a hard startup error naming the bad token --
#       not a silently-ignored no-op -- since a typo'd key would otherwise leave a production run
#       silently un-tuned with no indication why.
#       PRECEDENCE: a key present here always overrides that same-named environment variable, if one
#       is also set in this process's environment; a key simply ABSENT from this spec leaves whatever
#       that env var (or its own hardcoded default) already was untouched. Passing both this argument
#       and the equivalent env vars is harmless, but this argument wins for any key it names.
#
#   14) SPARK_EXTRA_CONF (optional, default: "" -- no additional confs)
#       A raw, UNPARSED string of extra spark-sql/spark-shell flags -- typically one or more
#       "--conf key=value" pairs -- for any Spark property SPARK_TUNING's named keys don't cover
#       (e.g. spark.network.timeout, spark.executor.memoryOverhead, spark.task.maxFailures,
#       spark.hadoop.ipc.client.connect.max.retries). Exists so a genuinely new tuning need,
#       discovered only once this runs at real production scale, does not require a script change
#       (a new named SPARK_TUNING key) before it can be applied -- this is the same escape-hatch
#       role SPARK_REWRITE_EXTRA_ARGS/SPARK_COPIER_EXTRA_ARGS already play as env vars (see their own
#       declaration further below); this argument is simply appended to BOTH of them, so it applies
#       to STEP 4's rewrite/register job AND STEP 5's copier job at once.
#       Deliberately kept OUT of SPARK_TUNING's own comma-separated spec (argument 13): a raw --conf
#       string can itself contain commas (comma-separated property VALUES, e.g. a filesystem list,
#       or multiple space-separated --conf flags), which would collide with SPARK_TUNING's own
#       top-level comma splitting. Taking it as its own, separate, unsplit argument avoids that
#       entirely.
#         export SPARK_EXTRA_CONF="--conf spark.network.timeout=300s --conf spark.executor.memoryOverhead=512m"
#       Split on WHITESPACE only when finally read (same convention SPARK_REWRITE_EXTRA_ARGS/
#       SPARK_COPIER_EXTRA_ARGS already use) -- a value needing an embedded space cannot be expressed
#       this way. Applied AFTER whatever SPARK_REWRITE_EXTRA_ARGS/SPARK_COPIER_EXTRA_ARGS already held
#       from the environment, so spark-submit's own "last --conf for a repeated key wins" rule means
#       this argument can override an env-var-set conf for the same key, never the reverse.
#
#   15) SEED_CHECKPOINT (optional, default: "false")
#       "true" or "false". "true" puts the whole run in seed-only mode: for every resolved table it
#       writes a checkpoint and then stops -- no rewrite_table_path, no file copy, no destination
#       repoint. See "SEEDING CHECKPOINTS WITHOUT REPLICATING" further below for what is seeded and
#       when it applies. Exists as a positional argument because a caller such as Pulse Actions can
#       pass neither a bare `--seed-checkpoint` flag token nor an environment variable at run time;
#       this is the same switch, reachable through the argument list.
#       Three equivalent ways to turn it on, any one of which is enough:
#         - this argument set to "true";
#         - the SEED_CHECKPOINT environment variable set to "true" (used only when this argument is
#           omitted or empty -- an explicit argument always wins over the environment);
#         - the bare `--seed-checkpoint` flag token anywhere on the command line.
#       Anything other than "true"/"false" is a hard startup error rather than a silent "false": the
#       two values select completely different runs, so a typo must not quietly pick one of them.
#       IMPORTANT: this is a one-off maintenance mode, not a setting to leave on. A scheduled action
#       left at "true" replicates nothing at all, run after run. Set it back to "false" (or drop the
#       argument) once the seeding run has completed.
#
# ADDITIONAL REQUIREMENTS
# ------------------------
#   - `spark-sql` (Spark 3.5.x) must be on PATH, with the Iceberg runtime already on Spark's default
#     classpath (true for this ODP build). If a target host does NOT have it bundled, set
#     ICEBERG_SPARK_JAR to a pre-staged local jar path (see the variable declarations further below).
# NON-ROOT / NON-KERBEROS EXECUTION
# -----------------------------------
#   Identity-switching pattern for hadoop/hdfs/spark-sql/spark-shell/beeline calls (named
#   run_as_hdfs / run_as_spark_user here, since the latter wraps spark-sql/spark-shell):
#     - Kerberos IS detected: every hadoop/hdfs/spark-sql/spark-shell/beeline call runs as the current
#       user (root or otherwise), using the active ticket. HDFS_USER/SPARK_USER are not used for
#       process identity, but SPARK_USER is still used to pick the right credential cache by principal
#       if more than one valid Kerberos cache is found (e.g. under Pulse Actions, where multiple service
#       tickets may coexist).
#     - Kerberos is NOT detected: hadoop/hdfs calls run via `sudo -u $HDFS_USER`. beeline instead
#       authenticates via `-n <user> -p <password>` (see HIVE_USER / HIVE_LDAP_ENABLED / HIVE_PASSWORD
#       below), since it is a JDBC client rather than a process that can be re-exec'd as another user.
#       spark-sql/spark-shell run via `sudo -E -u $SPARK_USER` in this mode too (they ARE local
#       processes, unlike beeline), so they can read/write HDFS as an authorized user without Kerberos.
#
# BEELINE AUTH IN NON-KERBEROS MODE (env vars)
# -----------------------------------------------
#   HIVE_USER          optional, default "hdfs"    - Beeline username, passed as -n on every beeline
#                                                      call when Kerberos is not detected. Without it,
#                                                      HiveServer2 sees the connection as "anonymous".
#   HIVE_LDAP_ENABLED  optional, default "false"    - "true" or "false". When "false", the password is
#                                                      not actually validated by HS2; HIVE_USER is
#                                                      passed as both -n and -p purely to satisfy
#                                                      beeline's command-line syntax. When "true",
#                                                      HIVE_PASSWORD must be set to the real LDAP
#                                                      credential.
#   HIVE_PASSWORD      optional (required only       - Real LDAP password for HIVE_USER.
#                      when HIVE_LDAP_ENABLED=true)
#
# HA NAMESERVICE OVERRIDE (env vars)
# -------------------------------------
#   AUTO_DERIVE_HA_CLIENT_CONFIG   optional, default "no" ("yes"/"no")
#     Normally, an HA nameservice must already be resolvable to spark-sql/`hadoop fs` through the host's own hdfs-site.xml, configured once
#     cluster-wide (a plain `hdfs dfs -ls hdfs://<other-cluster-nameservice>/` should already work for
#     both clusters when this is the case). Set to "yes" to have this script inject the real NameNode
#     addresses directly as spark-sql --conf / hadoop fs -D flags instead -- useful when one cluster's
#     hdfs-site.xml does not yet know about the other cluster's nameservice. Requires SRC_NN_HOSTS and
#     DST_NN_HOSTS (below). When "no" (the default), no -D/--conf HA override is added at all, and
#     spark-sql/`hadoop fs` fall back to the host's own merged hdfs-site.xml -- which only reaches a LOCAL
#     driver/`hadoop fs` client reading files off this host's disk, NOT a YARN executor container. Because
#     SPARK_RUN_MODE now defaults to "yarn", this script REQUIRES AUTO_DERIVE_HA_CLIENT_CONFIG=yes
#     (and SRC_NN_HOSTS/DST_NN_HOSTS) whenever SPARK_RUN_MODE=yarn, and exits at startup otherwise --
#     an executor with no HA config for a nameservice can resolve it to a STANDBY NameNode and fail with
#     "Operation category READ is not supported in state standby". Example:
#       export AUTO_DERIVE_HA_CLIENT_CONFIG=yes
#       export SRC_NN_HOSTS="nn1=atlasdemo-01.adsre.com:8020,nn2=atlasdemo-02.adsre.com:8020"
#       export DST_NN_HOSTS="nn1=repl1.adsre.com:8020,nn2=repl2.adsre.com:8020"
#
#   SRC_NN_HOSTS / DST_NN_HOSTS   MANDATORY when AUTO_DERIVE_HA_CLIENT_CONFIG=yes, otherwise unused
#     Comma-separated "<nn-id>=<host>:<port>" pairs describing each nameservice's NameNodes.
#
#   AUTOMATIC_FAILOVER_ENABLED   optional, default "true"; only used when AUTO_DERIVE_HA_CLIENT_CONFIG=yes
#     "true" or "false".
#
# WHERE METADATA IS STAGED (env var)
# -------------------------------------
#   STAGING_ROOT   optional, default "/var/tmp/iceberg-repl-staging"
#     HDFS directory (not a local one) under which rewrite_table_path stages each table's
#     path-corrected metadata, as "<STAGING_ROOT>/<table-relative-path>" on the DESTINATION cluster
#     (it is passed to rewrite_table_path qualified with DST_NAMESERVICE, so staging lands there
#     whichever cluster's host launches the script). Deliberately NOT under /tmp:
#     HDFS /tmp is the conventional target of cluster cleanup policies, and a sweep that fires between
#     STEP 4 staging the metadata and STEP 5 copying it would delete those files mid-run. /var/tmp
#     carries no such convention.
#     The directory is created on demand, so its parents must be writable by the replication user --
#     if "/var" does not already exist on the destination HDFS, creating it needs write access at the
#     HDFS root (a superuser operation). Either pre-create "/var/tmp" once with the right ownership, or
#     point this somewhere the replication user already owns:
#       export STAGING_ROOT="/user/svc_replication/iceberg-repl-staging"
#
# HOW STEP 5 COPIES THE FILES (env vars)
# -----------------------------------------
#   STEP 5 copies the enumerated (source,target) file list using one of two engines, selected by
#   COPY_ENGINE:
#
#   COPY_ENGINE=spark (DEFAULT) -- ONE Spark job for the whole file list, however many partitions it
#     spans. Each task copies its share of (source,target) pairs straight to their exact target paths via
#     the Hadoop FileSystem API -- run_spark_copier(). No per-target-directory job-count constraint:
#     verified in production here at 3346 files (2568 copied, 778 already present) in a single
#     application. Runs on whatever master SPARK_RUN_MODE selects, which now defaults to "yarn" -- so out
#     of the box this is already a distributed Spark application. Overriding SPARK_RUN_MODE (or
#     ICEBERG_SPARK_MASTER) to "local" pins it to one job on this host instead; the script warns at
#     startup when it sees that combination. Does NOT replicate ACLs or XAttrs -- it explicitly re-applies
#     permission, owner/group and modification time after each file (best-effort -- failures are counted
#     and reported as a [WARN] summary, since setOwner needs superuser), but ACL/XAttr state is not
#     carried over.
#
#   COPY_ENGINE=distcp -- one `hadoop distcp -f` (MapReduce) job per distinct TARGET DIRECTORY the delta
#     touches -- run_distcp_copier(). Required because distcp -f copies every source path listed in one
#     invocation into a SINGLE target directory under its BASENAME only -- it cannot rebuild a nested
#     partition path from a flat file list -- so job count scales with the table's touched-partition
#     count (measured on this DR pair: 82 separate MapReduce jobs for a single 3035-file bootstrap, most
#     moving a few KB and dominated by AM/container launch; DISTCP_PARALLEL_JOBS controls how many of
#     these run at once). In exchange it gets real distcp preserve semantics: DISTCP_PRESERVE_OPTS
#     (default "-pugp") is passed straight to each `distcp -f` invocation, and `-update` is always added
#     so a partially-completed copy is cheap and idempotent to re-run. Runs as a plain `hadoop` CLI
#     process via run_as_hdfs (not a Spark job), using the same HDFS_HA_ARGS `-D dfs.*` flags already used
#     for this script's other `hadoop fs` calls.
#     UNDER KERBEROS + YARN: each distcp invocation ALSO gets its own
#     `-D mapreduce.job.hdfs-servers.token-renewal.exclude=...` -- the MapReduce-side property
#     (MRJobConfig.JOB_HDFS_SERVERS_TOKEN_RENEWAL_EXCLUDE), NOT a "mirror" of the Spark copier's fix: the
#     DELEGATION-TOKEN CONFS block (after resolve_active_namenode_hostport) explicitly found
#     spark.hadoop.mapreduce.job.hdfs-servers.token-renewal.exclude to be IGNORED by this cluster's
#     ResourceManager, and uses spark.yarn.kerberos.renewal.excludeHadoopFileSystems instead -- a
#     Spark-YARN-client-only property with no MapReduce/distcp equivalent. distcp submits its OWN YARN
#     application independent of SPARK_RUN_MODE and has no analogous "exclude" client flag to reach for,
#     so this property is what distcp actually has available; it has NOT been independently confirmed
#     effective on this cluster's ResourceManager the way the Spark-side fix was (no verified application ID
#     on record for it, unlike the Spark copier's). If a distcp run hits "Failed to submit application ...
#     Failed to renew token" despite this flag being present, that is the first thing to verify -- this is
#     computed fresh for every call from SRC_NAMESERVICE/DST_NAMESERVICE/the resolved active NameNode, so it
#     is at least well-formed for both same-nameservice-collision hops and the plain unique-nameservice case.
#
#   Neither engine replicates ACLs or XAttrs in the general case (distcp's own `-p[bugpcaxt]` set does not
#   include them either unless explicitly requested). Confirmed not needed on this deployment (access
#   control is managed at the Hive/Ranger catalog layer, not via raw HDFS ACLs/XAttrs on Iceberg data
#   files); a deployment that DOES rely on HDFS-level ACLs/XAttrs for these tables should verify its
#   chosen engine's preserve behaviour before adopting this script.
#
#   SPARK_COPY_PARTITIONS   optional, default 0 (auto) -- COPY_ENGINE=spark only
#     Number of Spark tasks the copy is spread across. Auto targets ~50 files per task, capped at 2000
#     tasks. Raise it for a very large delta on a large cluster; the copy is embarrassingly parallel.
#
#   DISTCP_PRESERVE_OPTS   optional, default "-pugp" -- COPY_ENGINE=distcp only
#     Preserve flags passed to each `hadoop distcp -f` invocation (user, group, permission by default).
#     See `hadoop distcp -help` for the full -p[rbugpcaxt] option set.
#
#   DISTCP_MAPPERS   optional, default "" (distcp's own default) -- COPY_ENGINE=distcp only
#     `-m <n>` on every distcp invocation -- max mapper tasks (parallelism) PER GROUP's job.
#
#   DISTCP_BANDWIDTH_MB   optional, default "" (unlimited) -- COPY_ENGINE=distcp only
#     `-bandwidth <n>` on every distcp invocation -- per-map bandwidth cap in MB/s.
#
#   DISTCP_QUEUE   optional, default "" (cluster default queue) -- COPY_ENGINE=distcp only
#     `-D mapreduce.job.queuename=<queue>` on every distcp invocation -- YARN scheduler queue.
#
#   DISTCP_EXTRA_ARGS   optional, default "" -- COPY_ENGINE=distcp only
#     Free-form extra distcp flags (e.g. "-atomic -skipcrccheck"), split on whitespace, appended to
#     every distcp invocation. Escape hatch for anything not covered by a dedicated knob above.
#
#   DISTCP_PARALLEL_JOBS   optional, default 1 (fully serial) -- COPY_ENGINE=distcp only
#     How many of a table's per-target-directory distcp groups run at once, via a bounded background-job
#     pool (same pattern as PARALLEL_TABLES). Default 1 matches this engine's original, verified
#     behavior; raise it so a bootstrap touching many partitions does not pay for each group's YARN
#     submission serially.
#
# WHERE THE SPARK JOB RUNS (env vars)
# --------------------------------------
#   SPARK_RUN_MODE   optional, default "yarn" ("local" | "yarn")
#     Controls STEP 4's rewrite_table_path/register_table job, always. Also controls STEP 5's copier job
#     when COPY_ENGINE=spark (the default) -- with COPY_ENGINE=distcp, STEP 5 instead submits one
#     `hadoop distcp -f` MapReduce job per touched target directory, independent of SPARK_RUN_MODE. See
#     "HOW STEP 5 COPIES THE FILES" above.
#       "yarn" (DEFAULT) -- --master yarn --deploy-mode client: a real distributed YARN application whose
#         executors are containers on cluster nodes, so the rewrite scales out. The script asks Spark
#         for delegation tokens for BOTH nameservices (spark.kerberos.access.hadoopFileSystems) and
#         excludes them from renewal by YARN, since the ResourceManager the job is submitted to cannot
#         renew another cluster's tokens (spark.yarn.kerberos.renewal.excludeHadoopFileSystems; see
#         SPARK_TOKEN_RENEWAL_EXCLUDE under "OTHER SETTINGS" below for excluding the remote one only).
#       "local" -- --master local[*]: one JVM on this host, doing every read itself under the ticket it
#         already holds. No executors, so no cross-cluster delegation-token hop at all, but no parallelism
#         either -- a very large table is bounded by this single host. Use this as the fallback on any
#         cluster pair where the renewer trust above has not been verified.
#       export SPARK_RUN_MODE=local   # to fall back if needed
#
#   SPARK_RUN_MODE=yarn + SAME-NAMESERVICE COLLISION: hop A's job needs to submit to YARN while
#   addressing DESTINATION under an identity distinct from the shared name (which hop A redirects to
#   SOURCE for its own duration). That identity is a resolved bare active-NameNode host:port (e.g.
#   "odp-new1.adsre.com:8020"), obtained at runtime via `hdfs haadmin -getServiceState`
#   (resolve_active_namenode_hostport(), declared near the DELEGATION-TOKEN CONFS block below), never a
#   synthetic HA nameservice name -- a bare host:port needs no HA configuration of its own
#   (dfs.nameservices, dfs.ha.namenodes.*, a failover proxy provider), since it is a literal address,
#   not a logical name any client has to resolve.
#
#   Resolved once per script invocation (cached in-process and via a file under LOG_DIR, since each
#   table replicates inside its own flock subshell) and reused identically by both hop A and hop B: hop
#   B's rewrite_table_path source_prefix must textually match whatever hop A wrote as its target_prefix.
#
#   Two Spark/YARN properties are required for this to succeed under Kerberos:
#     - spark.yarn.kerberos.renewal.excludeHadoopFileSystems, naming both the redirected shared-name
#       identity and the resolved bare host:port, so the ResourceManager does not attempt to renew a
#       delegation token it cannot renew.
#     - spark.yarn.stagingDir, qualified with the resolved bare active-NameNode host:port, so job
#       resources are staged on the correct cluster rather than defaulting against fs.defaultFS (the
#       shared name, redirected to SOURCE for hop A's job).
#
#   "local" remains available as a fallback for a cluster pair whose renewer trust has not been
#   verified.
#
#   SPARK_QUEUE   optional, default unset; only used when SPARK_RUN_MODE=yarn
#     YARN queue for the Spark application (spark.yarn.queue), applied to every spark-sql/spark-shell
#     submission this script makes (STEP 4's rewrite_table_path/register_table and STEP 5's copier alike).
#
#   SPARK_YARN_ARCHIVE   optional, default unset; only used when SPARK_RUN_MODE=yarn
#     HDFS URI of an archive holding Spark's jars (spark.yarn.archive), applied to every spark-sql/
#     spark-shell submission this script makes. Without it -- and without spark.yarn.archive or
#     spark.yarn.jars in the cluster's spark-defaults.conf -- every Spark job first zips and uploads
#     the whole of $SPARK_HOME/jars to HDFS ("Neither spark.yarn.jars nor spark.yarn.archive is set,
#     falling back to uploading libraries under SPARK_HOME"), and a replicated table costs three such
#     jobs. Build the archive once, on the cluster the script submits its jobs to, and name it here:
#       jar cv0f spark-libs.jar -C "$SPARK_HOME/jars/" .
#       hdfs dfs -mkdir -p /apps/spark && hdfs dfs -put -f spark-libs.jar /apps/spark/
#       export SPARK_YARN_ARCHIVE="hdfs://<this cluster's nameservice>/apps/spark/spark-libs.jar"
#     Must be a full URI: Spark reads a bare path as a file on the local disk and uploads it on every
#     submission. Rebuild the archive after a Spark upgrade. Settable positionally as SPARK_TUNING's
#     yarn_archive key.
#
#   ICEBERG_SPARK_MASTER   optional, no default
#     Escape hatch: a literal --master string ("local[4]", "spark://host:7077", ...). When set it
#     overrides SPARK_RUN_MODE entirely and no YARN-specific flags are added.
#
#   ICEBERG_DV_SUPPORT   optional, default "auto" ("auto" | "true" | "false")
#   ICEBERG_SKIP_UNSUPPORTED_V3   optional, default "false"
#     See "ICEBERG FORMAT-VERSION SUPPORT (v2 AND v3)" below.
#
# OTHER SETTINGS (env vars)
# ----------------------------
#   REGISTER_HIVE_ENGINE_ENABLED   optional, default "false" ("true" | "false")
#     "true" has register_table write the Hive InputFormat/OutputFormat/SerDe and storage_handler
#     itself (iceberg.engine.hive.enabled=true on that call), so the two fixup ALTERs after a
#     bootstrap registration are skipped unless STEP 7 finds storage_handler still missing. Turn it
#     on only after a bootstrap with it on has been followed by a successful Hive SELECT on the
#     destination table of this cluster pair.
#
#   BEELINE_MARKER_STYLE   optional, default "select" ("select" | "set")
#     How the batched beeline calls (table listing, STEP 1 property prefetch) mark where one
#     table's rows end and the next one's begin: a SELECT of a constant per marker, or a session
#     variable HiveServer2 echoes back without compiling a query. Try "set" where the prefetch is
#     slow and compare the "STEP 1 property prefetch: ... in <time>" line of the two runs.
#
#   SPARK_TOKEN_RENEWAL_EXCLUDE   optional, default "both" ("both" | "auto"); YARN + Kerberos only
#     Which nameservices' delegation tokens are excluded from renewal by YARN. A token excluded
#     from renewal stops working once the NameNode's renew interval (24 hours by default) has
#     passed. "both" excludes the remote and the local cluster's, which limits any single Spark job
#     to that interval. "auto" excludes only the remote cluster's -- the one this cluster's
#     ResourceManager cannot renew -- and lifts that limit; switch to it once a run that launches a
#     Spark job has succeeded with it on this cluster pair.
#
#   SPARK_STAGING_USER   optional, default derived; SAME-NAMESERVICE COLLISION path only
#     HDFS user whose home directory holds the Spark staging directory for hop A. Defaults to the
#     Hadoop short name of the Kerberos principal in use (or SPARK_USER without Kerberos).
#
# SAME-NAMESERVICE COLLISION (SRC_NAMESERVICE == DST_NAMESERVICE)
# -----------------------------------------------------------------
#   Two different physical clusters can both call their HA nameservice by the same name (a DR
#   cluster built from the same blueprint as production). Passing that one name as both
#   SRC_NAMESERVICE and DST_NAMESERVICE selects this mode. It requires
#   AUTO_DERIVE_HA_CLIENT_CONFIG=yes with SRC_NN_HOSTS/DST_NN_HOSTS, because only this script can
#   say which NameNodes the name stands for in a given call, and it expects to be run from a
#   destination-cluster host, where the shared name natively means DESTINATION.
#
#   A single Hadoop client cannot bind one nameservice name to two sets of NameNodes at once, and
#   the destination's metadata must end up reading the plain shared name (a literal host:port
#   there would stop resolving after a NameNode failover). STEPs 4-6 therefore run as two passes:
#     Hop A - for this one job only, the shared name is redirected to SOURCE's NameNodes.
#             rewrite_table_path reads source and rewrites its paths to the destination's ACTIVE
#             NameNode, addressed as a literal host:port (resolved once per run with
#             `hdfs haadmin -getServiceState`); the listed files are copied across.
#     Hop B - on the destination alone: hop A's output is registered in a throwaway
#             filesystem-backed (type=hadoop) catalog, and a second rewrite_table_path turns the
#             host:port prefix back into the plain shared name. Those files are written into the
#             table's directory, the throwaway catalog entry is deleted, and STEP 6 registers or
#             repoints the real table at hop B's metadata.
#   Every call outside hop A uses the shared name with its native meaning, DESTINATION.
#
#   What differs from the normal path:
#     - Checkpoints: both "sides" are the same HDFS location (the destination), so there is one
#       copy, and the checkpoint filename also carries the two Metastore hosts to keep the two
#       directions apart.
#     - Two marker files sit next to the checkpoint: "<checkpoint>.collision_hopab_completed" (the
#       first run in a direction always does a full hop A) and "<db>.<table>.collision_patched_upto"
#       (how far the table's ancestor metadata.json files have been re-prefixed for hop B).
#     - A metadata.json that still names a literal host:port after a run is refused by the next one
#       (assert_no_collision_scratch_leak); such a table needs a manual reset.
#     - The stage-timing table has no STEP 5 row: both hops' copies run inside STEP 4.
#
# ICEBERG FORMAT-VERSION SUPPORT (v2 AND v3)
# -----------------------------------------------------
#   Both format-version 2 and format-version 3 tables are replicated by this script. STEP 2 reads
#   the source table's `format-version` property and gates the run on it, rather than discovering an
#   incompatibility halfway through as an unreadable Spark stack trace out of STEP 4.
#
#   Only ONE v3 spec change actually affects this pipeline: DELETION VECTORS. Everything else v3 adds
#   is either already handled or invisible to replication:
#     - Row lineage (_row_id / _last_updated_sequence_number, `first-row-id` on snapshots and
#       manifests, `next-row-id` in table metadata) is preserved by rewrite_table_path from Iceberg
#       1.9.0 onward -- see RewriteTablePathUtil's metadata.nextRowId()/snapshot.firstRowId() calls.
#     - New types (variant, geometry, geography, unknown, timestamp_ns), default column values and
#       multi-argument partition transforms are all opaque to replication: the bytes and the metadata
#       are copied verbatim. They do require the DESTINATION cluster's Spark/Hive to be new enough to
#       READ them afterwards, which is a platform-version question, not a replication one.
#
#   DELETION VECTORS (the one real constraint). In v3 a positional delete is no longer a Parquet/Avro/
#   ORC delete file but a Puffin file (`file_format = 'PUFFIN'`) that records the data file it applies
#   to in TWO places: the manifest entry's `referencedDataFile` field, AND a "referenced-data-file"
#   property inside the Puffin blob itself. Both must be rewritten to the destination prefix, or the
#   DR-side reader fails when it tries to apply the deletes.
#
#   Iceberg only learned to do that in 1.11.0 (commit d2046a7d9e, "Core, Spark: Preserve DV-specific
#   fields for deletion vectors", PR #14351). On 1.9.x and 1.10.x -- 1.10 included -- a DV instead
#   falls through RewriteTablePathSparkAction's Avro/Parquet/ORC-only positionDeletesReader switch and
#   dies on its `default:` arm with:
#       UnsupportedOperationException: Unsupported file format: PUFFIN
#
#   So the gate this script applies to a v3 table is:
#     - Iceberg runtime >= 1.11.0  -> replicate normally, deletion vectors and all.
#     - Iceberg runtime <  1.11.0  -> probe the table for deletion vectors (a count over the
#       `all_delete_files` metadata table, WHERE file_format = 'PUFFIN'; skipped outright, with no
#       spark-sql launch, for a table whose SHOW TBLPROPERTIES reports `snapshot-count 0`, which has
#       never been written and so cannot hold a delete file of any kind):
#         * no DVs found -> replicate normally. A v3 table that has never had a positional delete
#           applied contains nothing rewrite_table_path cannot handle on 1.9.x/1.10.x.
#         * DVs found    -> refuse this table (the run's other tables continue; see
#           ICEBERG_SKIP_UNSUPPORTED_V3 below for how the outcome is bucketed).
#         * probe failed -> refuse, same as "DVs found". Conservative on purpose: a table that
#           cannot be proven DV-free must not be handed to a runtime that would corrupt or crash on
#           it.
#     v2 tables skip all of this entirely -- no extra spark-sql call, no behaviour change at all.
#
#   COST. The runtime-version detection is a single spark-sql launch for the whole run, cached across
#   tables, and only happens if at least one v3 table is seen. The deletion-vector probe is one more
#   spark-sql launch PER v3 TABLE, and only on a runtime older than 1.11.0 -- so a large v3 fleet on
#   an old runtime pays a JVM start per table for it. Upgrading to 1.11.0+ removes the per-table probe
#   entirely (the gate stops at the version check), which is the other reason to prefer the upgrade
#   over living on ICEBERG_SKIP_UNSUPPORTED_V3.
#
#   ICEBERG_DV_SUPPORT (default "auto")
#     "auto"  -- detect the Iceberg runtime version on Spark's classpath once per run (via
#                `SELECT reflect('org.apache.iceberg.IcebergBuild', 'version')`) and compare it to
#                1.11.0. This is the normal setting.
#     "true"  -- assert the runtime can rewrite deletion vectors, skipping detection. Use this for a
#                vendor build that backported PR #14351 without bumping its reported version.
#     "false" -- assert it cannot, skipping detection. Use this to force the DV probe/refusal path.
#
#   ICEBERG_SKIP_UNSUPPORTED_V3 (default "false")
#     "false" -- a v3 table this runtime cannot replicate is a table FAILURE: it lands in the run
#                summary's Failed bucket and the run exits non-zero. This is the correct default for
#                DR, where a table silently not arriving at the destination is the worst outcome.
#     "true"  -- downgrade it to a SKIP (Skipped bucket, run can still report SUCCESS). Only set this
#                once you have consciously accepted that those tables are NOT protected.
#
#   The fix for a refused table is to upgrade the Iceberg runtime to 1.11.0+, not to work around this
#   in the script -- the DV rewrite lives in Iceberg's RewriteTablePathUtil, not here.
#
# TABLE LOCATION AND THE CHECKPOINT (THE "ANCHOR")
# -----------------------------------------------------
#   Each Iceberg table's directory is assumed to be the same relative HDFS path on source and
#   destination, just under a different nameservice:
#     hdfs://<source-logical-nameservice>/<table-relative-path>
#     hdfs://<DST_NAMESERVICE>/<table-relative-path>
#
#   The CHECKPOINT is a small file under CHECKPOINT_DIR, one per table PER REPLICATION DIRECTION,
#   recording the last-replicated metadata.json filename (the "anchor"). Its presence or absence is
#   what decides bootstrap vs. incremental mode.
#
#   WHY PER-DIRECTION, NOT JUST PER-TABLE. The checkpoint filename is
#   "<db>.<table>.<SRC_NAMESERVICE>_<SRC_METASTORE_URI>__to__<DST_NAMESERVICE>_<DST_METASTORE_URI>.checkpoint"
#   (sanitized) -- it embeds the direction, not just the table. A checkpoint records "how far source's
#   history has been replicated to THIS destination," which is direction-specific state by construction.
#   An earlier version of this script keyed the filename on table name alone, so a prod->DR run and a
#   later DR->prod run against the SAME table silently read and wrote the exact identical file: the
#   second direction's checkpoint write clobbered the first direction's incremental cursor, and resuming
#   the original direction afterward fed rewrite_table_path a start_version filename that could never
#   appear in ITS source's metadata log (see the RULE below) -- confirmed in practice on
#   iceberg_dr_test202.orders202 (bootstrap prod->DR, then a DR->prod run, both sharing one checkpoint
#   file). Scoping the filename by direction gives each direction its own independent cursor, which is
#   also the only correct semantics once two directions are ever run against the same table -- whether
#   that's deliberate bidirectional testing, or a sequential failover/failback where the direction
#   permanently flips.
#
#   The key includes METASTORE URI, not just nameservice, because SRC_NAMESERVICE/DST_NAMESERVICE are
#   operator-supplied and not guaranteed distinct (e.g. two clusters sharing one HDFS nameservice, or a
#   same-cluster test) -- a nameservice-only key would collapse back to the same collision in that case.
#   SRC_METASTORE_URI/DST_METASTORE_URI are mandatory and are the actual identity rewrite_table_path
#   validates start_version against, so they always differ between two real catalogs even when the
#   nameservice strings coincide.
#
#   NOTE ON TOPOLOGY: checkpoints live on HDFS (see "CHECKPOINT ON HDFS" below), so both directions of
#   a pair read and write the same CHECKPOINT_DIR on the same two clusters whichever host runs the
#   command -- a centralized orchestrator (e.g. Pulse Actions) invoking both directions, or a table
#   replicated manually from an admin box. Scoping the filename by direction is what keeps the two
#   directions' cursors apart there.
#
#   RULE: the checkpoint must always be the SOURCE table's own metadata.json filename, never a
#   destination-side path. Iceberg's rewrite_table_path validates its `start_version` argument against
#   the metadata log of the table resolved from SRC_METASTORE_URI (the source catalog) -- it checks the
#   filename against that table's own prior metadata.json history, and a destination-side filename can
#   never appear there, because rewrite_table_path always writes the destination's rewritten copy under
#   a brand-new UUID that is never added to source's metadata log. Every checkpoint write in this script
#   (the end-of-run advance, auto-seed, and `--seed-checkpoint`) reads SOURCE's current
#   metadata_location, never destination's, for exactly this reason.
#
#   AUTO-SEED: if no checkpoint file exists for a table, but the destination table already exists as a
#   real Iceberg table (register_table would otherwise fail with AlreadyExistsException on a
#   re-bootstrap attempt), this script automatically adopts SOURCE's current metadata_location as the
#   checkpoint instead of attempting a full re-bootstrap. This is logged with [WARN] lines, since it
#   silently changes the run's mode from bootstrap to incremental and does not verify that the
#   destination's existing data actually matches the source's history -- it only checks that the
#   destination table exists. This covers both "destination populated by some other tool" and "a prior
#   run of this script registered the table but crashed before writing its first checkpoint": both
#   converge on the same correct action, which is to treat the destination as caught up to source's
#   state as of right now, and replicate only what source gains from this moment forward. If a
#   destination table's existing data is NOT actually equivalent to the source's history, auto-seed is
#   the wrong outcome for it -- drop and recreate that destination table before the next run to force a
#   real bootstrap instead.
#
#   `--seed-checkpoint` remains available for explicitly pre-seeding checkpoints for a batch of tables
#   without also running a replication in the same invocation (e.g. as a distinct one-time step ahead of
#   a cutover), but is no longer required before the first scheduled run of a table whose destination
#   already has data -- auto-seed above handles that case automatically.
#
#   ANCHOR SELECTION: wherever a checkpoint is derived from a snapshot-id (auto-seed,
#   `--seed-checkpoint`, a direction flip, the broken-chain re-anchor), it is the EARLIEST metadata.json
#   in source's metadata log that carries that snapshot -- the version that introduced it -- not the
#   latest. That version exists on both clusters, and every metadata-only commit made on top of it
#   (a schema or property change, Hive's own repoint commit) stays inside the next delta. See
#   resolve_src_metadata_json_for_snapshot().
#
#   DIRECTION FLIP (failover / failback): when a table has no checkpoint for the direction being run
#   but has one for the opposite direction, the roles have flipped. The new direction's anchor is
#   resolved from the destination's current snapshot (as auto-seed does), the opposite direction's
#   checkpoint is RETIRED -- renamed to "<name>.superseded" on both clusters, never deleted -- and
#   only then is the new direction's checkpoint written. One direction is live at a time, so every
#   later flip is resolved afresh from the destination's real state, and a destination whose current
#   snapshot is not in source's history is refused instead of being repointed over. A table that
#   still has live checkpoints for BOTH directions (replicated both ways before this retirement
#   existed) gets the same resolution once, on its next run that has something to replicate.
#
#   EMPTY TABLES: a table with no snapshot yet is replicated like any other -- registered on the
#   destination and checkpointed. STEP 7 accepts "neither side has a snapshot" as verified rather
#   than requiring a current-snapshot-id.
#
#   NO-OP SHORT-CIRCUIT: for a genuine incremental run (never bootstrap, never
#   --rebuild-dst-table-from-source), if the checkpoint already equals source's CURRENT metadata_location
#   -- i.e. source has not committed anything since the last successful run -- STEPs 4-6
#   (rewrite_table_path, the Spark copier, and the destination ALTER TABLE repoint) are skipped
#   entirely, each logged as SKIPPED under its own STEP banner. STEP 7's validation still always runs:
#   it reads the destination afresh and compares its snapshot-id with source's (as read in STEP 1; if
#   they differ, source is read again and the full check runs), so a short-circuited run is verified,
#   not just assumed correct. This exists because rewrite_table_path does not return an empty file list
#   merely because start_version already equals the table's current version -- it still re-emits that
#   boundary version's own files -- so without this check, a no-op run would still pay for a real Spark
#   copier job and a destination commit that changes nothing. See "DESTINATION METADATA RETENTION"
#   below for why that destination commit is not merely wasted time. A no-op run also leaves the
#   checkpoint file alone (its value has not changed) and skips the staging-directory cleanup
#   (nothing was staged), so an untouched table costs one checkpoint read and STEP 7's one
#   destination property read, nothing more.
#
# DESTINATION METADATA RETENTION -- DELIBERATELY LEFT AT ICEBERG'S OWN DEFAULT
# ---------------------------------------------------------------------------------
#   Every ALTER TABLE ... SET TBLPROPERTIES against an Iceberg-Hive table -- including every STEP 6
#   metadata_location repoint this script issues -- goes through Hive's Iceberg storage handler commit
#   path, which writes a BRAND NEW metadata.json of its own on each call, regardless of whether the
#   value being set actually changed. rewrite_table_path copies source's table properties verbatim, so
#   unless source itself sets write.metadata.delete-after-commit.enabled, the destination silently
#   inherits Iceberg's default "never delete old metadata.json versions" behaviour and accumulates one
#   extra, permanently-orphaned file per repoint commit -- confirmed in practice: two consecutive no-op
#   incremental runs each left a distinct never-referenced metadata.json under the table's metadata/
#   directory. This is a real, known cost (slow, unbounded metadata.json accumulation on destination) --
#   NOT one this script fixes automatically, for the reason below.
#
#   An earlier version of this script had register_bootstrap_fixups() set
#   write.metadata.delete-after-commit.enabled=true and write.metadata.previous-versions-max=5 on the
#   DESTINATION table at registration time, reasoning that rewrite_table_path's start_version validation
#   always resolves `table` from SRC_METASTORE_URI, so pruning destination's own metadata log could never
#   affect this script's own checkpoint correctness. That reasoning holds ONLY as long as this table is
#   never used as a SOURCE. It breaks the moment this pair fails over or fails back: the former
#   destination becomes the new source, and rewrite_table_path's start_version check now resolves against
#   ITS metadata log -- which this script had just pre-pruned to 5 versions (an even tighter window than
#   the 20-version, ~1-hour retention that caused a real production incident on the ORIGINAL source: see
#   the incremental-checkpoint-vs-source-retention note near resolve_src_metadata_json_for_snapshot()).
#   A failed-over deployment inheriting a 5-version cap would hit that same failure mode almost
#   immediately. This script no longer sets any destination-side retention property at all -- both sides
#   are left symmetric, at whatever retention their own commit pipeline already uses, so either side is
#   equally safe to use as a source after a direction change. Sizing metadata retention to actual
#   replication cadence (on whichever side is currently the source) is a table-property decision for the
#   cluster operator to make deliberately, not something this script should impose silently on a table it
#   doesn't yet know will become a source.
#
# CHAINED CROSS-CLUSTER REWRITES -- A BROKEN ANCESTOR IS NOT A BROKEN CHECKPOINT
# ---------------------------------------------------------------------------------
#   rewrite_table_path substitutes SOURCE_PREFIX for TARGET_PREFIX across the ENTIRE
#   metadata.json payload it copies -- not just the boundary between start_version and
#   end_version, but also historical metadata-log entries embedded in that payload that
#   are OLDER than start_version and were therefore never re-copied under the new prefix
#   (start_version is the "already have this, do not re-fetch it" boundary by design).
#   Those older entries still get their path prefix swapped, because the substitution is
#   a blanket text operation on the whole file, not one scoped to what was actually copied.
#
#   This is invisible on a single hop (prod -> DR once) because nothing ever reads those
#   older entries again. It becomes a real failure the moment the DESTINATION of one hop
#   becomes the SOURCE of a later hop in the other direction -- exactly failover/failback:
#     1. prod -> DR bootstrap. DR's copy of prod's metadata.json embeds a metadata-log
#        entry for an ancestor version, correctly still under the prod prefix (this
#        ancestor genuinely lives on prod).
#     2. Data written on DR, then DR -> prod (failover). This hop's incremental rewrite
#        copies DR's current lineage into prod and blanket-substitutes DR's prefix for
#        prod's prefix across that whole payload -- INCLUDING the ancestor entry from
#        step 1, which already read as a prod-side path before this hop ever ran. Its
#        content survives the substitution unchanged, but it is now baked into PROD'S
#        OWN current metadata as if it had always been native prod history.
#     3. prod -> DR again (failback). This hop's OWN checkpoint anchor is perfectly valid
#        (prod's own true historical file, untouched by step 2's checkpoint write -- see
#        checkpoint_basename_for()'s direction scoping above). But walking prod's ancestor
#        chain from that checkpoint to current now passes through a DIFFERENT, unrelated
#        ancestor that step 2 planted -- one whose bytes were never part of what step 2
#        physically copied to prod, because it predated THAT hop's own start_version.
#        rewrite_table_path fails with "IllegalArgumentException: Version file <path>
#        doesn't exist", even though the checkpoint anchor itself was never wrong.
#
#   Real incidents this fix responds to: iceberg_dr_test202.orders202 -- prod -> DR
#   bootstrap, then data added directly on DR, then DR -> prod (failover), then a row
#   deleted on prod, then prod -> DR (failback) failed with exactly this signature. Also
#   iceberg_dr_test204.orders204, which additionally proved that a full rewrite CANNOT be
#   relied on to dodge this: RewriteTablePathSparkAction walks source's CURRENT
#   metadata-log regardless of whether start_version is given, so dropping start_version
#   only WIDENS the walked range (from "the earliest entry" instead of "the checkpoint") --
#   it can never SHRINK it past a broken ancestor that already lies between the checkpoint
#   and current. Confirmed in practice: orders204's full-rewrite fallback hit the exact
#   same "Version file ...00003-....metadata.json doesn't exist" as the incremental
#   attempt it was meant to recover from.
#
#   FIX: STEP 4 recognizes this exact exception text on an INCREMENTAL run (never on an
#   already-full BOOTSTRAP/--rebuild-dst-table-from-source run, so this cannot mask a
#   genuinely broken checkpoint or loop) and tries TWO recoveries in order, both logged
#   loudly under [WARN]/[INFO] so an operator watching the log understands why a run that
#   should have been a small incremental delta took a different path:
#     1. RE-ANCHOR PAST THE BROKEN ANCESTOR (tried first, and usually succeeds): resolve
#        destination's own current-snapshot-id against source's metadata_log_entries
#        metadata table -- the exact same lookup AUTO-SEED uses (see
#        resolve_src_metadata_json_for_snapshot() below), a pure in-memory query by
#        snapshot-id that never reads a historical metadata.json file off HDFS, so it
#        cannot trip over the same missing-ancestor file that just failed. Destination's
#        current-snapshot-id already lies AFTER the broken ancestor whenever destination is
#        caught up to anything past it (the common case right after a failover/failback,
#        since the poisoned entry is normally an OLD ancestor relative to destination's
#        current data) -- so retrying as an incremental rewrite anchored THERE instead of
#        at the old checkpoint replicates only what source gained since destination's true
#        known-good point, without ever walking through the broken ancestor.
#     2. FULL REWRITE (fallback of last resort, only if re-anchoring above could not
#        resolve a usable, different start_version): retries once as a full
#        rewrite_table_path (no start_version). This is known NOT to dodge the SAME broken
#        ancestor that just failed (see above) -- it is kept only in case the underlying
#        failure differs from a simple single poisoned ancestor.
#   The same two recoveries also cover a STALE ANCHOR -- start_version itself rejected before
#   any walk begins, with "Cannot find provided version file ... in metadata log" (the checkpoint
#   has dropped off source's metadata log, which keeps only the newest
#   write.metadata.previous-versions-max entries, 100 by default) or "Version file ... does not
#   exist". Typical causes: more commits on source between two runs than the log retains, or a
#   failback after a long failover period.
#
#   The full rewrite (2) is followed by a normal repoint, which replaces whatever the destination
#   table currently points at. It is therefore taken only when the destination's current state is
#   known to be part of source's history (its snapshot was found in source's metadata log or
#   snapshot set) or the destination holds no snapshot at all. Otherwise the table is failed with
#   nothing changed, so destination commits that never reached source are never dropped by an
#   automatic fallback.
#
#   PREVENTION: the dangling metadata-log entry behind this failure came from anchoring a flipped
#   direction at a metadata.json only one cluster had (Hive's repoint commit). Anchors are now the
#   version that INTRODUCED the destination's snapshot (see ANCHOR SELECTION above), which both
#   clusters hold, so new flips no longer plant such entries; the recoveries here remain for
#   tables that already carry one.
#
#   Neither recovery is the same as --rebuild-dst-table-from-source: the table-uuid has not
#   changed (it is still the same table, just missing one ancestor in its audit trail), so
#   STEP 6 still repoints via the normal ALTER TABLE ... SET
#   TBLPROPERTIES('metadata_location'=...) -- no rename, no re-registration, no backup
#   table, whichever of the two recoveries above succeeded.
#
# CHECKPOINT ON HDFS
# ---------------------------------------------------------------------------------
#   A checkpoint always lives on HDFS, under CHECKPOINT_DIR (argument 9, default
#   "/tmp/pulse_iceberg_replication_action"), mirrored onto BOTH SRC's and DST's
#   nameservice (i.e. the actual locations are "hdfs://<SRC_NAMESERVICE><CHECKPOINT_DIR>/..."
#   and "hdfs://<DST_NAMESERVICE><CHECKPOINT_DIR>/..."), using the direction-scoped filename
#   checkpoint_basename_for() builds (see "TABLE LOCATION AND THE CHECKPOINT" above for what a
#   checkpoint is and why it's scoped by direction). The same CHECKPOINT_DIR path is used on
#   both clusters: the nameservice authority in each resulting URI keeps the two copies apart,
#   and the direction in the filename keeps them apart from the checkpoint of the OPPOSITE
#   replication direction for the same table. (When SRC_NAMESERVICE and DST_NAMESERVICE are the
#   same string -- SAME-NAMESERVICE COLLISION mode -- both URIs are one location, on the
#   destination, and there is a single copy.)
#
#   CONCURRENCY. Two invocations must not replicate the same table at once. On one host that
#   is prevented by a local flock file per table (kept in a local directory of the same path
#   as CHECKPOINT_DIR). Across hosts it is prevented by a lock directory on the destination's
#   HDFS, "<CHECKPOINT_DIR>/<db>.<table>.inprogress", taken only by a run that is about to
#   replicate -- see hdfs_table_lock_acquire() (CROSS_HOST_TABLE_LOCK / TABLE_LOCK_STALE_HOURS).
#
#   WHY HDFS, NOT LOCAL DISK: a local-disk checkpoint ties a table's incremental-replication
#   state to one specific host. Run the same direction from a different node later -- a
#   rebuilt host, a different node in a pool, a centralized orchestrator that doesn't pin a
#   table to a fixed runner -- and the checkpoint is simply not there, forcing an unwanted
#   auto-seed or bootstrap even though the destination is perfectly caught up. Mirroring onto
#   both clusters' HDFS instead means either cluster's copy is sufficient to resume the right
#   direction from any host with access to that cluster's HDFS.
#
#   PREREQUISITE: this script creates CHECKPOINT_DIR on both clusters at startup (once,
#   before any table is processed) if it does not already exist. The identity this script
#   runs `hadoop fs` as -- the active Kerberos principal when KERBEROS_ENABLED=yes, otherwise
#   HDFS_USER -- must have permission to create and write under that path on BOTH clusters;
#   startup fails fast, naming both nameservices, if it cannot.
#
#   A write failing on ONE side (transient connectivity, permissions) is logged as a [WARN]
#   and does not fail the run -- the surviving copy still serves the next read. A write
#   failing on BOTH sides IS fatal (nothing would durably record this run's progress at all)
#   and the checkpoint is reported as not advanced, exactly like any other STEP 7
#   verification failure.
#
# SEEDING CHECKPOINTS WITHOUT REPLICATING (SEED_CHECKPOINT / --seed-checkpoint)
# ---------------------------------------------------------------------------------
#   Turned on by positional argument 15 (SEED_CHECKPOINT="true"), by the SEED_CHECKPOINT environment
#   variable, or by a bare `--seed-checkpoint` flag token -- see argument 15 above. From a caller
#   that can only pass positional arguments, arguments 10-14 are given their defaults explicitly so
#   that 15 has a slot to sit in:
#
#     ./iceberg_bdr_replication.sh \
#       "sales_db:.*" "ODP-Aquaman" "ODP-Aurora" \
#       "<SRC_JDBC_URL>" "<DST_JDBC_URL>" "<SRC_METASTORE_URI>" "<DST_METASTORE_URI>" \
#       "/var/log/iceberg-replication" "/tmp/pulse_iceberg_replication_action" \
#       "hdfs" "hdfs" "false" "" "" \
#       "true"
#
#   or, from a shell:
#
#     ./iceberg_bdr_replication.sh ... --seed-checkpoint
#
#   For every table resolved from INCLUDE_FILTERS: confirms the table exists on the destination
#   (skipping, with a logged reason, any that don't -- this is the trigger condition for seeding), then
#   resolves the destination's own current-snapshot-id against SOURCE's metadata log and writes the
#   source metadata.json that introduced that snapshot as the table's checkpoint (always a source-side
#   file, per the RULE above), then moves on without copying any data. The next normal invocation is
#   then a genuine incremental run for every table that got seeded, replicating everything source has
#   gained since the point the destination is actually caught up to. A destination whose snapshot is
#   not in source's history is reported as a failure and gets no checkpoint.
#
#   WHEN IT IS NEEDED. A normal run already does this by itself for any table whose checkpoint is
#   missing but whose destination table exists (AUTO-SEED above), and then carries straight on to
#   replicate. Seed-only mode is for writing the checkpoints as a separate step, without replicating
#   in the same run -- e.g. ahead of a cutover, or to re-create lost checkpoint files for a batch of
#   tables before the next scheduled run.
#
# REBUILDING A DESTINATION TABLE THAT DOES NOT TRACE BACK TO SOURCE (--rebuild-dst-table-from-source)
# ----------------------------------------------------------------------------------
#   ./iceberg_bdr_replication.sh ... --rebuild-dst-table-from-source
#
#   Auto-seed (see AUTO-SEED above) normally refuses to proceed when a table has no checkpoint, the
#   destination table already exists, but its current-snapshot-id cannot be found anywhere in source's own
#   metadata log -- i.e. destination's data was NOT populated from a real point in source's history (e.g.
#   independently-written rows, or a table that just happens to share the qualified name). By default this
#   is a hard ERROR: a real bootstrap is impossible (register_table always fails with
#   AlreadyExistsException against an existing destination table), and incrementally seeding from an
#   unrelated snapshot would silently produce a wrong checkpoint. Dropping and recreating the destination
#   table forces a clean bootstrap, but is not always an option (e.g. permissions/grants, downstream
#   consumers, or other constraints tied to the existing table object).
#
#   --rebuild-dst-table-from-source is the explicit, loud opt-in for this case. When set, and only in exactly
#   this "destination exists but doesn't trace back to source" situation, the script:
#     - Runs a FULL rewrite_table_path (no start_version -- there is no valid incremental starting point,
#       since destination's data isn't anywhere in source's log), covering every file reachable from
#       source's CURRENT snapshot, and copies the exact files listed (via the Spark copier).
#     - Backs up the destination table by RENAMING it to
#       "<table>_pre_rebuild_<timestamp>" (a pure Metastore operation -- no data movement, no
#       purge/deletion risk at all), freeing the original name, then re-registers that freed name fresh
#       via register_table against the newly-replicated metadata.
#         WHY NOT A SIMPLE ALTER TABLE REPOINT: Hive's own Iceberg storage handler
#         (HiveIcebergMetaHook.assertNotCrossTableMetadataLocationChange, invoked by every
#         ALTER TABLE ... SET TBLPROPERTIES('metadata_location'=...)) unconditionally compares the
#         destination table's CURRENT table-uuid against the new metadata's table-uuid and throws
#         "Cannot change iceberg table ... metadata location pointing to another table's metadata" the
#         instant they differ -- which they always will here, since this flag exists precisely for the
#         case where destination's lineage is genuinely unrelated to source's. There is no override for
#         this specific check; it is a hard invariant in Hive's metastore hook, not a workaroundable bug.
#         register_table, by contrast, registers directly against the catalog with no UUID check at all
#         -- but only succeeds against a NOT-yet-registered table, hence the rename-out-of-the-way first.
#         WHY RENAME INSTEAD OF DROP: a rename can never lose data by construction (no purge flag, no
#         DROP TABLE involved at all), whereas a drop-then-register sequence is only as safe as correctly
#         disarming that table's purge flag first -- one avoidable failure mode away from deleting the
#         very files this run just replicated. Renaming removes that risk entirely.
#     - The renamed destination table (backup) remains a normal, fully-queryable Iceberg table under its
#       backup name, with its own prior data/metadata/lineage completely intact and untouched. This script
#       never drops it automatically -- do so by hand once you've confirmed it's no longer needed (the
#       exact backup name used is printed in the step 6/8 run log).
#     - Writes the checkpoint from SOURCE's current metadata_location once the post-replication
#       snapshot-id validation (step 7/8) passes, exactly as a normal run would.
#   This flag has no effect for any other case (a genuine first-time bootstrap, a normal incremental run,
#   or a successful auto-seed) -- it only changes behavior in this one specific failure path. Logged with
#   multiple [WARN] lines making clear that destination's existing history is being superseded, not merged.
#
# EXAMPLES
# ---------
#
#   Example 1 - Bootstrap (fresh DR, no checkpoints, no existing tables). Kerberos cluster, so
#   HDFS_USER/SPARK_USER are ignored -- the active ticket's identity is used for every
#   hadoop/hdfs/spark-sql call. Both nameservices already resolve via this host's own Hadoop
#   client config, so AUTO_DERIVE_HA_CLIENT_CONFIG is left at its "no" default:
#
#     ./iceberg_bdr_replication.sh \
#       "sales_db:.*" \
#       "ODP-Aquaman" \
#       "ODP-Aurora" \
#       "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "thrift://metastore-src-host:9083" \
#       "thrift://metastore-dst-host:9083" \
#       "/var/log/iceberg-replication" \
#       "/tmp/pulse_iceberg_replication_action"
#
#   Example 2 - Same as above, but a non-Kerberos cluster with a non-root, non-LDAP authorized
#   "svc_replication" user (sudo-switched for hadoop/spark-sql; beeline connects as
#   "svc_replication" with pass-through/NONE HS2 auth), replicating multiple databases in one run, on
#   clusters whose hdfs-site.xml files do NOT know about each other (so AUTO_DERIVE_HA_CLIENT_CONFIG is
#   turned on):
#
#     export AUTO_DERIVE_HA_CLIENT_CONFIG=yes
#     export SRC_NN_HOSTS="nn1=host1:8020,nn2=host2:8020"
#     export DST_NN_HOSTS="nn1=host3:8020,nn2=host4:8020"
#     export HIVE_USER="svc_replication"
#     ./iceberg_bdr_replication.sh \
#       "sales_db:.*,analytics:daily_summary" \
#       "ODP-Aquaman" "ODP-Aurora" \
#       "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "thrift://metastore-src-host:9083" "thrift://metastore-dst-host:9083" \
#       "/var/log/iceberg-replication" \
#       "/tmp/pulse_iceberg_replication_action" \
#       "svc_replication" "svc_replication"
#
#   Example 3 - Incremental (checkpoints already seeded or already exist on the destination). Same
#   invocation as either example above -- for each resolved table, the script detects the existing
#   checkpoint and automatically runs an incremental rewrite_table_path + Spark copy(delta) + metadata
#   re-point, instead of a full bootstrap copy.
#
#   Example 4 - Same as Example 1, but from a caller that can only pass positional arguments (Pulse
#   Actions) and needs to pin this run to a specific YARN queue with fixed (non-dynamic) executor
#   counts on both Spark jobs, plus one extra property (a longer network timeout) neither
#   SPARK_TUNING nor any other argument names directly:
#
#     ./iceberg_bdr_replication.sh \
#       "sales_db:.*" \
#       "ODP-Aquaman" \
#       "ODP-Aurora" \
#       "jdbc:hive2://host1:2181,host2:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "jdbc:hive2://host3:2181,host4:2181/;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2" \
#       "thrift://metastore-src-host:9083" \
#       "thrift://metastore-dst-host:9083" \
#       "/var/log/iceberg-replication" \
#       "/tmp/pulse_iceberg_replication_action" \
#       "hdfs" \
#       "hdfs" \
#       "false" \
#       "queue=repl_low,rewrite_cores=2,rewrite_mem=4g,rewrite_dynamic=false,rewrite_max_executors=4,copier_cores=1,copier_mem=1g,copier_dynamic=false,copier_max_executors=10" \
#       "--conf spark.network.timeout=300s"
#
#   Argument 12 (REBUILD_DST_TABLE_FROM_SOURCE) is passed explicitly here as "false" only because
#   arguments 13/14 need a slot to sit in -- every argument up through 12 keeps meaning exactly what
#   Examples 1-3 already document; 13/14 are purely additive at the end of the list.
#
# ==============================================================================

set -euo pipefail

########################################
# INTERRUPT HANDLING (SIGINT/SIGTERM). Without this, a plain Ctrl+C (or a
# `kill` of just the top-level PID) only stops whatever THIS shell is
# currently waiting on in the foreground -- it does NOT reach a `hadoop
# distcp`/`spark-sql`/`spark-shell` child already spawned via `sudo` (a
# separate process, not this shell's direct child under non-Kerberos mode),
# nor a per-table flock subshell's own background children under
# DISTCP_PARALLEL_JOBS/PARALLEL_TABLES>1. Confirmed in practice: a Ctrl+C'd
# run left its distcp/replication subshell alive and still holding the
# per-table flock lock (`ps aux` showed it still running, elapsed 15+
# minutes, well after the terminal had returned) -- the next invocation of
# the same table then failed fast with "already being replicated by another
# invocation," and the only fix was `kill -9` on the leftover PIDs by hand.
#
# FIX: trap INT/TERM at the top level (this is the ONLY place this trap is
# installed -- deliberately not repeated inside replicate_one_table()'s own
# subshell, since a subshell inherits traps from its parent unless it
# resets them, and this script's subshells never do) and, on receipt,
# kill this script's own process GROUP (`kill -TERM -- -$$`, the leading
# "-" targeting the group rather than one PID) before exiting. This reaches
# every child this script spawned -- hadoop/distcp/spark-sql/spark-shell
# processes and any background `... &` jobs -- as long as they were started
# in the same process group, which is the default for every child spawned
# without its own explicit `setsid`/process-group change (true for every
# invocation in this script: run_as_hdfs/run_as_spark_user's `sudo`/direct
# exec, and every `( ... ) &` background job).
#
# A `sudo`-spawned child (non-Kerberos mode) is the one case process-group
# signaling can still miss, since `sudo` by default starts the target
# command in its own session -- operators on a non-Kerberos deployment
# should additionally verify with `ps -ef | grep -E 'distcp|spark-(sql|shell)'`
# after an interrupt and kill any survivor by hand, same as documented in
# the lock-file recovery steps below.
#
# This handler does NOT attempt to release the per-table flock lock file
# itself: the lock's own fd-scoped semantics (see replicate_one_table()'s
# own comment on why the lock file is never explicitly unlinked) mean it is
# already released the instant the subshell holding fd 200 actually exits --
# killing the process group achieves that. If a lock is ever found stale
# with no corresponding process alive (`ps -ef | grep iceberg_bdr_replication`
# comes back empty), it is always safe to remove by hand:
#   rm -f <CHECKPOINT_DIR>/<db>.<table>.lock
_on_interrupt() {
  local sig="$1"
  # Untrap BOTH signals first: kill -TERM -- -$$ below targets this script's
  # own process GROUP, which includes this shell itself. Left trapped, that
  # self-delivered TERM would re-enter this same handler a second time
  # (bash's exact behavior for a signal delivered to a shell already
  # running its own trap for that signal is not something to rely on) --
  # untrapping first means the self-signal falls through to the default
  # disposition (terminate) instead, a clean single pass through this
  # handler rather than a risk of re-entry.
  trap - INT TERM
  log_error "Received ${sig} -- terminating this script's process group (any running hadoop"
  log_error "distcp/spark-sql/spark-shell child, and any background job under"
  log_error "DISTCP_PARALLEL_JOBS/PARALLEL_TABLES, is being killed now to avoid a leftover"
  log_error "process holding a per-table lock after this shell exits)."
  # Best-effort: a child that already exited, or one running under a
  # sudo-spawned separate session (non-Kerberos mode), may not receive
  # this -- verify with 'ps -ef | grep -E \"distcp|spark-(sql|shell)\"'
  # after this script exits if you suspect a survivor.
  kill -TERM -- -$$ 2>/dev/null || true
  exit 130
}
trap '_on_interrupt SIGINT' INT
trap '_on_interrupt SIGTERM' TERM

########################################
# Logging helpers. Defined before anything else runs (including Kerberos
# detection and HA-config validation below) so every line this script ever
# prints -- from the first argument check to the final run summary -- goes
# through the same timestamp + level tag format. Severity is then
# consistently greppable (`grep '\[ERROR\]'`) instead of some lines being
# bare text and others using ad hoc "ERROR:" prefixes.
########################################
SEP="======================================================================"
SUBSEP="----------------------------------------------------------------------"
# Indent prefix for raw third-party tool output (beeline/spark-sql/hadoop
# stdout) that this script passes through rather than generating itself --
# keeps it visually distinct at a glance from this script's own [INFO]/
# [WARN]/[ERROR] lines, without adding color codes (this output also lands
# in RUN_LOG_FILE via `tee`, where ANSI escapes would just show up as
# garbage when the log is viewed with a plain pager/grep).
INDENT="      | "

# Timestamps come from bash's own printf '%(...)T' (the -1 argument means
# "now"), not from an external `date`: every log line would otherwise cost a
# fork+exec, which adds up to minutes over a run that logs hundreds of
# thousands of lines. Same local-time format as before.
_log_ts() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }

# CURRENT_TABLE_LOG_TAG: empty at the top level (every startup/run-summary
# line is unaffected). Set to "[<qualified-table>] " by
# replicate_one_table()'s own subshell before that table's replication
# starts, so every [INFO]/[WARN]/[ERROR] line it emits carries its own
# table name. Exists because PARALLEL_TABLES>1 runs multiple tables'
# subshells concurrently, all writing into the same RUN_LOG_FILE -- without
# a tag, two tables' STEP banners/output interleave with no way to tell
# which line belongs to which table (confirmed confusing in practice on a
# 2-table PARALLEL_TABLES=5 run). Each table's own subshell is a forked
# copy of this shell's environment, so setting this global inside it never
# leaks to any other table's subshell or back to the parent.
CURRENT_TABLE_LOG_TAG="${CURRENT_TABLE_LOG_TAG:-}"

# RAW_LINE_TAG: the same table tag, applied to everything that is NOT an
# [INFO]/[WARN]/[ERROR] line -- banners, stage-timing rows, pretty-printed
# commands, and passed-through beeline/spark/hadoop output. Empty unless
# tables are running in parallel (set alongside CURRENT_TABLE_LOG_TAG in
# replicate_one_table(), only when PARALLEL_TABLES > 1): with tables run one
# at a time those lines sit under their own table's banner and need no
# tag, so a serial run's log is unchanged. With several tables writing at
# once they would otherwise be the majority of the log and impossible to
# attribute. RAW_LINE_TAG_SED is the same text escaped for use on the
# replacement side of a sed `s` command.
RAW_LINE_TAG=""
RAW_LINE_TAG_SED=""

# EARLY-LINE BUFFER. The run log file can only be opened once LOG_DIR and the
# run-log name are known, which is well after the first lines are logged
# (Kerberos cache selection, beeline auth mode, HA-config notes, deprecation
# warnings). Until then every line is also kept here, and written into the
# log file as its first lines when the file is opened (see where
# RUN_LOG_FILE is set), so the file holds the complete run, not just the
# part after that point. A startup error that exits before the file exists
# is still console-only -- there is no file yet to put it in.
_EARLY_LOG_BUFFERING=true
_EARLY_LOG_BUFFER=""

# TABLE_FIRST_ERROR_FILE: when set (by the per-table dispatcher, to a file of
# that table's own), the first [ERROR] message logged for the table is
# recorded there, so the run summary can show WHY a table failed next to its
# name instead of only that it did.
TABLE_FIRST_ERROR_FILE="${TABLE_FIRST_ERROR_FILE:-}"

# _log_emit <level-field> <message>: one timestamped, tagged log line.
_log_emit() {
  local _ts _line _msg="$2"
  # A multi-line message (e.g. a logged SQL statement) only carries the
  # timestamp and table tag on its first line; with tables running in
  # parallel its continuation lines get RAW_LINE_TAG so they stay
  # attributable too.
  if [[ -n "$RAW_LINE_TAG" && "$_msg" == *$'\n'* ]]; then
    _msg="${_msg//$'\n'/$'\n'${RAW_LINE_TAG}}"
  fi
  printf -v _ts '%(%Y-%m-%d %H:%M:%S)T' -1
  printf -v _line '[%s] %s %s%s' "$_ts" "$1" "${CURRENT_TABLE_LOG_TAG}" "$_msg"
  [[ "$_EARLY_LOG_BUFFERING" == "true" ]] && _EARLY_LOG_BUFFER+="${_line}"$'\n'
  printf '%s\n' "$_line"
}
log_info()  { _log_emit '[INFO] ' "$1"; }
log_warn()  { _log_emit '[WARN] ' "$1"; }
log_error() {
  if [[ -n "$TABLE_FIRST_ERROR_FILE" && ! -s "$TABLE_FIRST_ERROR_FILE" ]]; then
    printf '%s\n' "$1" > "$TABLE_FIRST_ERROR_FILE" 2>/dev/null || true
  fi
  _log_emit '[ERROR]' "$1" >&2
}
# Plain line (banners, table dividers, blank-line spacers) -- timestamp-free
# by design, since SEP/SUBSEP/blank lines are visual structure, not log
# events. Carries RAW_LINE_TAG when tables run in parallel (see above); a
# blank line stays blank.
log_line() {
  if [[ -n "$1" ]]; then
    printf '%s%s\n' "${RAW_LINE_TAG}" "$1"
  else
    printf '\n'
  fi
}
# _tag_lines: filter that prefixes every non-blank stdin line with
# RAW_LINE_TAG; a plain pass-through when no tag is set. A line that already
# carries the tag is left as it is -- captured stderr that is replayed
# through this filter includes this script's own, already tagged, lines
# (run_spark_sql's "Running spark-sql:" preamble and command).
_tag_lines() {
  if [[ -n "$RAW_LINE_TAG" ]]; then
    RAW_LINE_TAG_FOR_AWK="$RAW_LINE_TAG" awk '
      BEGIN { tag = ENVIRON["RAW_LINE_TAG_FOR_AWK"] }
      { if ($0 == "" || index($0, tag) > 0) print; else print tag $0 }'
  else
    cat
  fi
}
# Pipe a subprocess's raw stdout through this to prefix every line with
# INDENT, so a wall of beeline/spark-sql/hadoop chatter (JVM banners,
# ZooKeeper discovery, "INFO : Compiling command...", etc.) is visually
# offset from this script's own tagged log lines instead of blending into
# them. Usage: some_command | indent_output
indent_output() { sed "s/^/${RAW_LINE_TAG_SED}${INDENT}/"; }
# log_stage: uniform per-table step banner -- blank line, "$SUBSEP" rule,
# then "STEP n/TOTAL_STEPS -- <description>" on its own line, so all 8 steps
# read identically regardless of which one is running, instead of each
# step's [n/8] tag being buried inline at the start of a longer sentence.
# The leading blank line guarantees one blank row of separation before
# every step banner even when the previous step's own trailing blank was
# skipped on an early `return`.
log_stage() {
  local step="$1" description="$2"
  # Close out the previous stage's timer before announcing this one, so
  # each stage is measured from its own banner to the next one's.
  _stage_timing_close
  log_line ""
  log_line "$SUBSEP"
  log_info "STEP ${step}/${TOTAL_STEPS} -- ${description}"
  _STAGE_OPEN_STEP="$step"
  _STAGE_OPEN_DESC="$description"
  _STAGE_OPEN_START=$(date +%s)
}

# log_substage: a lighter banner for a named sub-phase WITHIN one STEP --
# e.g. STEP 4's SAME-NAMESERVICE COLLISION path, which internally runs
# several independent operations (hop A's rewrite, hop A's file copy, the
# ancestor metadata patch, temp-registration, hop B's rewrite, hop B's file
# copy, cleanup) under a single STEP banner. Purely visual: unlike
# log_stage, it does NOT touch the stage-timing machinery or TOTAL_STEPS --
# a sub-phase's own duration is visible from its own log timestamps, and
# introducing separate timing buckets here would fragment the per-table
# stage-timing summary beyond the 8 STEPs it is built to report.
log_substage() {
  local label="$1"
  log_line ""
  log_line "  ${SUBSEP:0:40}"
  log_info "  > ${label}"
}

########################################
# Timing. Every stage, every table, and the run as a whole are measured, so
# a slow run can be attributed to a specific step of a specific table
# (typically STEP 4's rewrite_table_path or STEP 5's Spark copier) rather than
# just "the run took four hours".
#
# Wall-clock epochs (`date +%s`) are used rather than bash's SECONDS: the
# per-table work runs inside the flock SUBSHELL in replicate_one_table(),
# and epochs stay meaningful across that boundary while a shell-local
# counter's semantics do not.
########################################

# format_duration: seconds -> a compact human string ("47s", "3m 09s",
# "1h 04m 22s"). Zero-padded minutes/seconds so a column of these stays
# aligned when read down the page.
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

# Per-table stage accumulator, as two parallel arrays (bash 4 has no array
# of structs). Reset at the start of every table; read back by
# print_table_timing_summary below.
STAGE_TIMING_LABELS=()
STAGE_TIMING_SECONDS=()
_STAGE_OPEN_STEP=""
_STAGE_OPEN_DESC=""
_STAGE_OPEN_START=0

stage_timing_reset() {
  STAGE_TIMING_LABELS=()
  STAGE_TIMING_SECONDS=()
  _STAGE_OPEN_STEP=""
  _STAGE_OPEN_DESC=""
  _STAGE_OPEN_START=0
}

# Record the currently-open stage's elapsed time, if there is one. Safe to
# call repeatedly: it clears _STAGE_OPEN_STEP, so a second call before the
# next log_stage is a no-op. That matters because it is called from BOTH
# log_stage (closing the prior stage) and print_table_timing_summary
# (closing the final stage, or whichever stage a table bailed out of).
_stage_timing_close() {
  [[ -z "$_STAGE_OPEN_STEP" ]] && return 0
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - _STAGE_OPEN_START ))
  STAGE_TIMING_LABELS+=("${_STAGE_OPEN_STEP}|${_STAGE_OPEN_DESC}")
  STAGE_TIMING_SECONDS+=("$elapsed")
  _STAGE_OPEN_STEP=""
  _STAGE_OPEN_DESC=""
  return 0
}

# print_table_timing_summary: the per-table stage breakdown. Invoked from
# an EXIT trap inside the flock subshell, so it prints on EVERY exit path
# -- a clean success, an early skip at STEP 1, or a hard failure partway
# through STEP 5 -- which is exactly when the breakdown is most wanted.
# A table that failed still shows how long each stage it did reach took.
#
# `local rc=$?` / `return $rc` preserves the subshell's exit status across
# the trap. Bash does restore it on its own, but the per-table result is
# what the run summary buckets on, so it is pinned explicitly here rather
# than left to depend on that.
print_table_timing_summary() {
  local rc=$?
  local qualified_table="$1" table_start="$2"
  _stage_timing_close
  local now total i step desc secs label
  now=$(date +%s)
  total=$(( now - table_start ))

  log_line ""
  log_info "Stage timings for ${qualified_table}:"
  # SAME-NAMESERVICE COLLISION: this path's own STEP 4 (see its branch in
  # _replicate_one_table_locked) folds hop A/B's rewrite AND their file
  # copies into one STEP 4 banner, so no separate STEP 5 timer is ever
  # opened -- the table below goes straight from STEP 4/8 to STEP 6/8.
  # That is expected on this path, not a missing/broken step; said here
  # once so it doesn't need re-discovering from the gap in step numbers
  # every time someone reads a collision-mode table's timing breakdown.
  if [[ "${SAME_NAMESERVICE_COLLISION:-false}" == "true" ]]; then
    log_info "(SAME-NAMESERVICE COLLISION path: STEP 5 is folded into STEP 4's hop A/B copy sub-phases,"
    log_info " so no separate STEP 5/8 row appears below -- this is expected, not a missing step.)"
  fi
  for (( i = 0; i < ${#STAGE_TIMING_LABELS[@]}; i++ )); do
    step="${STAGE_TIMING_LABELS[$i]%%|*}"
    desc="${STAGE_TIMING_LABELS[$i]#*|}"
    secs="${STAGE_TIMING_SECONDS[$i]}"
    # Truncate the description to a fixed width so the duration column
    # lines up; the full text is already on the stage's own banner above.
    # A description longer than the field gets an explicit "..." ellipsis
    # rather than a hard %-70.70s cutoff -- some STEP 4/6 descriptions on
    # the SAME-NAMESERVICE COLLISION path run right up against (and past)
    # 70 characters and, cut off mid-word with no indication anything was
    # dropped, read like a rendering bug rather than a deliberate truncation.
    if [[ "${#desc}" -gt 70 ]]; then
      desc="${desc:0:67}..."
    fi
    label=$(printf '  STEP %s/%s  %-70.70s %12s' \
      "$step" "$TOTAL_STEPS" "$desc" "$(format_duration "$secs")")
    log_line "$label"
  done
  # Width 80 == the "  STEP n/8  " prefix (12) plus the 70-wide description
  # field minus this line's own 2-space indent, so the duration column
  # lines up with the stage rows above it.
  log_line "$(printf '  %-80.80s %12s' 'TOTAL (this table)' "$(format_duration "$total")")"
  log_line ""
  return $rc
}

####################################
# Variables - Accept from positional arguments with defaults
####################################

# Snapshot the script's own argument vector while it is still reachable as
# "$@". The startup banner needs to report which optional arguments the
# CALLER actually supplied versus which fell back to a default, and it
# cannot read the positional parameters directly to find out: inside a
# shell function "$@"/"$4" are that FUNCTION's arguments, so a helper
# called from the banner sees its own three parameters, never the
# script's. This array is the only way to answer the question from inside
# a function.
#
# SCRIPT_ARGV_RAW keeps the vector EXACTLY as invoked, flag tokens and all,
# because the flag scan further below ("--seed-checkpoint",
# "--rebuild-dst-table-from-source") has to see them.
SCRIPT_ARGV_RAW=("$@")

# Separate the bare flag tokens from the positional stream before any
# positional is read. Those flags are documented as accepted ANYWHERE on
# the command line, which is only safe as long as they are not also counted
# as positions: a caller writing
#     ... "<DST_JDBC_URL>" --seed-checkpoint
# would otherwise have "--seed-checkpoint" read as argument 6, i.e.
# SRC_METASTORE_URI. That was harmless while slot 6 was the ignored
# DISTCP_OPTS/(reserved) placeholder; it is not harmless now that the slot
# holds a real, position-sensitive argument. Filtering them out here makes
# "anywhere" actually true, for every argument, regardless of how many
# positionals precede it.
SCRIPT_POSITIONAL_ARGV=()
for _arg in "${SCRIPT_ARGV_RAW[@]+"${SCRIPT_ARGV_RAW[@]}"}"; do
  case "$_arg" in
    --seed-checkpoint|--rebuild-dst-table-from-source|--force-reseed-nonmatching) ;;
    *) SCRIPT_POSITIONAL_ARGV+=("$_arg") ;;
  esac
done
unset _arg
set -- "${SCRIPT_POSITIONAL_ARGV[@]+"${SCRIPT_POSITIONAL_ARGV[@]}"}"
SCRIPT_ARGV=("$@")

# Which tables to replicate -- see the big comment block above. Positional
# (not an env var) because Pulse Actions has no facility to pass env vars
# into a script invocation, only positional arguments.
INCLUDE_FILTERS="${1:-}"
SRC_NAMESERVICE="${2:-}"
DST_NAMESERVICE="${3:-}"
SRC_JDBC_URL="${4:-}"
DST_JDBC_URL="${5:-}"
# NOTE (argument order changed): slot #6 used to be DISTCP_OPTS, then an accepted-and-ignored
# "(reserved)" placeholder after the distcp copy engine was retired in favour of the Spark copier.
# It is now removed outright, so LOG_DIR and everything after it moved up one slot. The old
# 13-argument form is detected and rejected at startup by check_retired_distcp_opts_arg below --
# without that guard, an un-updated caller would silently hand its distcp flag string to LOG_DIR
# and shift every remaining argument one position off.
#
# NOTE (argument order changed AGAIN): slots #6/#7 and #8/#9 were swapped -- SRC_METASTORE_URI/
# DST_METASTORE_URI are now #6/#7 and LOG_DIR/CHECKPOINT_DIR are now #8/#9 -- to group the two
# connection-URI pairs (JDBC in #4/#5, Metastore in #6/#7) together ahead of the operational
# path arguments. There is no startup guard for THIS reorder (unlike the DISTCP_OPTS removal
# above): both old-slot-6/7 values (a local LOG_DIR path and an HDFS CHECKPOINT_DIR path) and
# new-slot-6/7 values (thrift:// URIs) look nothing alike, so a caller still on the old order
# fails immediately and obviously (e.g. "thrift://" URI checks against a comparably passed
# LOG_DIR value never resolve) rather than silently misrouting arguments the way the old
# DISTCP_OPTS removal could have.
#
# Hive METASTORE Thrift URIs (thrift://host:9083[,thrift://host2:9083]) -- NOT the HiveServer2 JDBC URLs
# above. spark-sql's Iceberg Hive catalog talks to the Metastore service directly (typically port 9083),
# a different service/port than HiveServer2 (typically 10000, or ZK discovery on 2181 as used by
# SRC_JDBC_URL/DST_JDBC_URL). Required for every CALL <catalog>.system.* procedure to resolve a table.
SRC_METASTORE_URI="${6:-}"
DST_METASTORE_URI="${7:-}"
LOG_DIR="${8:-/var/log/iceberg-replication}"

# CHECKPOINT_DIR (argument 9): an HDFS path, mirrored onto BOTH SRC's and
# DST's nameservice (see "CHECKPOINT ON HDFS" in this script's header for
# the full mechanism) -- i.e. the actual locations are
# "hdfs://<SRC_NAMESERVICE><CHECKPOINT_DIR>/..." and
# "hdfs://<DST_NAMESERVICE><CHECKPOINT_DIR>/...". Default follows this DR
# toolchain's convention for cross-node HDFS state under /tmp/pulse_*_action,
# with "iceberg" distinguishing this script's checkpoints from any other
# tool's state files sharing that parent.
CHECKPOINT_DIR="${9:-/tmp/pulse_iceberg_replication_action}"
# CHECKPOINT_DIR must be a plain absolute path. It is combined with each
# cluster's nameservice as "hdfs://<nameservice><CHECKPOINT_DIR>/...", so a
# relative path would be glued onto the nameservice name ("hdfs://ns" +
# "ckpt" = "hdfs://nsckpt"), and a full URI would be nested inside another
# one. Both then fail much later, as a "not usable on one or both clusters"
# error that does not point at the real cause -- and, since the same string
# is also the local lock directory, a full URI would additionally create a
# local directory literally named "hdfs:". Rejected here, by name, instead.
# Trailing slashes are dropped.
while [[ "$CHECKPOINT_DIR" == */ && "$CHECKPOINT_DIR" != "/" ]]; do
  CHECKPOINT_DIR="${CHECKPOINT_DIR%/}"
done
if [[ "$CHECKPOINT_DIR" == *"://"* ]]; then
  log_error "CHECKPOINT_DIR (argument 9) must be a plain absolute path such as /apps/iceberg-replication/checkpoints, not a URI (got '${CHECKPOINT_DIR}')."
  log_error "The script adds 'hdfs://<nameservice>' for each cluster itself."
  exit 1
fi
if [[ "$CHECKPOINT_DIR" != /* ]]; then
  log_error "CHECKPOINT_DIR (argument 9) must be an absolute path (got '${CHECKPOINT_DIR}')."
  exit 1
fi
# CROSS_HOST_TABLE_LOCK (env var, default "true") / TABLE_LOCK_STALE_HOURS
# (env var, default 24; 0 = never treat a lock as stale by age). See
# hdfs_table_lock_acquire() for the lock these control.
CROSS_HOST_TABLE_LOCK="${CROSS_HOST_TABLE_LOCK:-true}"
case "${CROSS_HOST_TABLE_LOCK,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "CROSS_HOST_TABLE_LOCK must be one of: true, false (got '${CROSS_HOST_TABLE_LOCK}')"
    exit 1
    ;;
esac
TABLE_LOCK_STALE_HOURS="${TABLE_LOCK_STALE_HOURS:-24}"
if [[ ! "$TABLE_LOCK_STALE_HOURS" =~ ^[0-9]+$ ]]; then
  log_error "TABLE_LOCK_STALE_HOURS must be a non-negative integer number of hours, 0 = never stale by age (got '${TABLE_LOCK_STALE_HOURS}')"
  exit 1
fi
# PRUNE_RUN_ARTIFACTS (env var, not positional -- a safety knob, default: "true"). Set to "false" to
# disable ALL automatic pruning in LOG_DIR -- old per-table file-list CSVs, and the age-based removal
# of run logs and failed-run artifacts (LOG_RETENTION_DAYS) -- and keep every run's files
# forever. Production default is "true" (bounded retention beats unbounded log growth), but this is
# deliberately overridable since these artifacts matter for post-incident debugging, e.g.
# `PRUNE_RUN_ARTIFACTS=false ./iceberg_bdr_replication.sh ...`.
PRUNE_RUN_ARTIFACTS="${PRUNE_RUN_ARTIFACTS:-true}"
# RESOLVED_TABLES_LOG_LIMIT (env var, default 200) - cap on how many
# per-table "Included : ..."/bucket-list lines the table-resolution and
# run-summary sections print individually. At thousands of tables, one line
# each turns the run log into the bottleneck to read; past this many, only a
# count + "... and N more" is printed. Purely a log-verbosity knob -- every
# table is still replicated and still bucketed by outcome regardless of
# this value.
RESOLVED_TABLES_LOG_LIMIT="${RESOLVED_TABLES_LOG_LIMIT:-200}"
if [[ ! "$RESOLVED_TABLES_LOG_LIMIT" =~ ^[0-9]+$ ]]; then
  log_error "RESOLVED_TABLES_LOG_LIMIT must be a non-negative integer (got '${RESOLVED_TABLES_LOG_LIMIT}')"
  exit 1
fi
# PARALLEL_TABLES (env var, default 1) - how many tables this script
# replicates CONCURRENTLY. Default 1 keeps today's fully-serial behavior
# unchanged. At real fleet scale (thousands of tables), a serial loop is the
# actual wall-clock bottleneck: even a quiet, no-op incremental table still
# pays for 2-3 separate beeline/spark-sql JVM launches, so 10,000 tables at
# ~15-20s each serially is 40+ hours per run. Raising this runs that many
# tables' replicate_one_table() calls in parallel background jobs instead --
# safe to do because each table's own per-table flock (see
# replicate_one_table()) already exists specifically to let concurrent
# invocations coexist without racing on the SAME table; two DIFFERENT
# tables running at once never contended for anything before, and still
# don't now. The real ceiling is downstream capacity this script does not
# control -- Hive Metastore/HiveServer2 connection limits, and the YARN
# queue's capacity for that many concurrent spark-sql/spark-shell
# applications -- size this to what those can actually absorb, not to this
# host's own CPU count.
PARALLEL_TABLES="${PARALLEL_TABLES:-1}"
if [[ ! "$PARALLEL_TABLES" =~ ^[1-9][0-9]*$ ]]; then
  log_error "PARALLEL_TABLES must be a positive integer (got '${PARALLEL_TABLES}')"
  exit 1
fi
# QUIET_SKIP_LOG (env var, default "true") - once a table is determined to
# be a genuine no-op (SKIP_REPLICATION=true -- source has not advanced past
# the checkpoint), STEPs 4-7's own [INFO]/[WARN] lines (each step's
# SUBSEP+banner, STEP 7's snapshot-id printout, etc. -- roughly 20-30 lines
# per table) are suppressed, replaced by the single STEP 8 "Up to date"
# summary line every table already ends on. At real fleet scale this is
# the difference between a run log that stays readable and one that is
# 90%+ repeated "SKIPPED" banners for tables nothing happened to: 10,000
# skipped tables at ~25 lines each is 250,000 lines of pure noise. STEP
# 1-3's own output (what was checked, checkpoint found) and any [ERROR]
# line are NEVER suppressed -- errors go to stderr, a separate file
# descriptor untouched by this, and STEP 1-3 output is what explains how a
# table's outcome was even decided, which matters for both quiet and noisy
# tables alike. Set to "false" to restore full per-step logging for every
# table regardless of outcome (useful when debugging a specific table's
# skip decision).
QUIET_SKIP_LOG="${QUIET_SKIP_LOG:-true}"
case "${QUIET_SKIP_LOG,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "QUIET_SKIP_LOG must be one of: true, false (got '${QUIET_SKIP_LOG}')"
    exit 1
    ;;
esac
# QUIET_BEELINE_STATEMENTS (env var, default "true") - run_beeline_statement()/
# run_beeline_statement_tolerate_non_native() (CREATE DATABASE, every
# ALTER TABLE this script issues) stream beeline's raw output straight
# through indent_output with NO noise filtering, unlike the query helpers
# (run_beeline_query_soft/_strict), which already strip beeline's own JVM/
# log4j startup banner via filter_beeline_noise. On a genuinely successful
# statement this banner (log4j package-scanning warning, ZooKeeper HS2
# discovery, "Connected to:"/"Driver:"/"Transaction isolation:", every
# Hive "INFO : Compiling command(...)"/"Executing command(...)" line,
# "No rows affected", "Beeline version", "Closing:") is 15-20 lines of
# pure noise -- the caller already logged the SQL itself via its own
# "Executing: ..." line right before calling this, so none of it adds
# information on the success path. Set to "true" (default) to suppress
# ALL of it when the statement succeeds; a FAILURE always prints the full
# output regardless of this setting, since that is exactly when the detail
# is needed for diagnosis. Set to "false" to restore the original
# always-print behavior.
QUIET_BEELINE_STATEMENTS="${QUIET_BEELINE_STATEMENTS:-true}"
case "${QUIET_BEELINE_STATEMENTS,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "QUIET_BEELINE_STATEMENTS must be one of: true, false (got '${QUIET_BEELINE_STATEMENTS}')"
    exit 1
    ;;
esac
# QUIET_COPIER_OUTPUT (env var, default "true") - the STEP 5 Spark copier runs
# as a spark-shell script, and spark-shell echoes its whole session: the
# REPL banner, then every import and every `val ...` definition of the
# copier script as it is interpreted. On a copy that succeeded none of that
# adds anything to the "[5d] Spark copier finished: ..." line this script
# logs itself, so by default a CLEAN copy (exit 0, a result line, every row
# accounted for, zero failed files) prints only the copier's own plan line.
# Anything short of clean always prints the full session, regardless of
# this setting. Set to "false" to print the full session every time. Same
# idea as QUIET_BEELINE_STATEMENTS above.
QUIET_COPIER_OUTPUT="${QUIET_COPIER_OUTPUT:-true}"
case "${QUIET_COPIER_OUTPUT,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "QUIET_COPIER_OUTPUT must be one of: true, false (got '${QUIET_COPIER_OUTPUT}')"
    exit 1
    ;;
esac
# BEELINE_MARKER_STYLE (env var, default "select"; "select" | "set") - how the
# marker rows of the batched beeline calls (table listing, STEP 1 property
# prefetch) are produced; see MARKER ROWS next to beeline_marker_stmt.
# "select" issues a SELECT per marker. "set" has HiveServer2 echo a session
# variable instead, which involves no query compilation -- worth trying
# where a SELECT of a constant is slow (compare the "prefetch ... in <time>"
# line of two runs). If the set style returns nothing usable on a given
# HiveServer2, no marker is found, nothing is cached, and STEP 1 falls back
# to its per-table calls: slower, never wrong.
BEELINE_MARKER_STYLE="${BEELINE_MARKER_STYLE:-select}"
case "${BEELINE_MARKER_STYLE,,}" in
  select|set) ;;
  *)
    log_error "BEELINE_MARKER_STYLE must be one of: select, set (got '${BEELINE_MARKER_STYLE}')"
    exit 1
    ;;
esac
# REGISTER_HIVE_ENGINE_ENABLED (env var, default "false") - when "true", every
# register_table call against the destination catalog is made with
# iceberg.engine.hive.enabled=true. Iceberg's HiveCatalog then writes the
# Hive-Iceberg InputFormat/OutputFormat/SerDe and the storage_handler table
# property as part of the registration commit itself, which is what the two
# fixup ALTERs after register_table otherwise add (see
# apply_hive_engine_fixups). With it on, those ALTERs are not run in STEP 6;
# STEP 7 checks the registered table and runs them only if storage_handler
# is still missing. That saves two beeline launches per bootstrapped table
# and the extra metadata.json Hive commits on the destination for the
# storage_handler ALTER.
# Left at "false" by default: turn it on only after a bootstrap run with it
# set to "true" has been followed by a successful Hive SELECT against the
# destination table on this cluster pair.
REGISTER_HIVE_ENGINE_ENABLED="${REGISTER_HIVE_ENGINE_ENABLED:-false}"
case "${REGISTER_HIVE_ENGINE_ENABLED,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "REGISTER_HIVE_ENGINE_ENABLED must be one of: true, false (got '${REGISTER_HIVE_ENGINE_ENABLED}')"
    exit 1
    ;;
esac
# LOG_RETENTION_DAYS (env var, default 30; 0 = keep forever) - how long this
# script keeps its own files in LOG_DIR that nothing else ever removes: the
# per-run log (iceberg_bdr_run_*.log, one per invocation) and the artifacts
# of FAILED runs (*.FAILED.csv file/copy lists, and the copier's
# .copier.scala/.result/.out files left next to them). Files of those kinds
# whose last modification is older than this many days are deleted at the
# end of a run (see prune_aged_log_files). Only applies when
# PRUNE_RUN_ARTIFACTS=true; the current run's own files are never old
# enough to match.
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
if [[ ! "$LOG_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  log_error "LOG_RETENTION_DAYS must be a non-negative integer number of days, 0 = keep forever (got '${LOG_RETENTION_DAYS}')"
  exit 1
fi
# User to run hadoop fs/hdfs/spark-sql as when Kerberos is NOT detected (sudo -u / sudo -E -u).
# Ignored (current user/ticket used instead) when Kerberos IS detected. Named SPARK_USER since
# this script's identity-switch wrapper for spark-sql/spark-shell is run_as_spark_user
# (see that function's own declaration further below).
HDFS_USER="${10:-hdfs}"
SPARK_USER="${11:-$HDFS_USER}"
# "true" to force-reseed a destination table whose data doesn't trace back to source's history (see
# "REBUILDING A DESTINATION TABLE THAT DOES NOT TRACE BACK TO SOURCE" below). Default "false" -- no positional callers
# are affected unless they explicitly opt in. Still also settable via a bare --rebuild-dst-table-from-source
# flag token anywhere on the command line (see the flag-scan loop below) for backward compatibility with existing
# callers that stop at argument 11; either form sets the same behavior.
REBUILD_DST_TABLE_FROM_SOURCE_ARG="${12:-false}"
# SPARK_TUNING (argument 13, optional, default ""): a compact, positional
# way to set the Spark tuning knobs below (queue, executor cores/memory,
# dynamic-allocation on/off, fixed executor counts, driver memory/cores)
# for callers -- Pulse Actions in particular -- that can only pass
# positional arguments, never environment variables (see the header's
# POSITIONAL ARGUMENTS section for why that constraint exists at all).
# Format: comma-separated "key=value" pairs, e.g.
#   "queue=repl_low,rewrite_cores=2,rewrite_mem=4g,rewrite_dynamic=false,rewrite_max_executors=4,copier_cores=1,copier_mem=1g,copier_dynamic=false,copier_max_executors=10,rewrite_driver_mem=2g,copier_driver_mem=2g"
# Parsed by apply_spark_tuning_arg() below, which EXPORTS the corresponding
# SPARK_*/env var for each recognized key -- so this is purely an
# alternate way to set the exact same knobs the header's "WHERE THE SPARK
# JOB RUNS"/"SPARK_COPIER_*"/"SPARK_REWRITE_*" sections already document as
# env vars; nothing below treats a positionally-set knob any differently
# than an environment-set one. Recognized keys:
#   queue, yarn_archive, rewrite_cores, rewrite_mem, rewrite_dynamic, rewrite_max_executors,
#   rewrite_driver_mem, rewrite_driver_cores, copier_cores, copier_mem,
#   copier_dynamic, copier_max_executors, copier_driver_mem, copier_driver_cores
SPARK_TUNING_ARG="${13:-}"

####################################
# check_retired_distcp_opts_arg: refuse an invocation still written against
# the OLD 13-argument order, where slot #6 was DISTCP_OPTS.
#
# Removing that slot moved LOG_DIR and everything after it up by one, and
# nothing about the old form is otherwise invalid -- an un-updated caller
# would simply have LOG_DIR="-pbugpcaxt -update -skipcrccheck",
# CHECKPOINT_DIR=<the old LOG_DIR>, SRC_METASTORE_URI=<the old
# CHECKPOINT_DIR>, and so on down the line. The mandatory-argument checks
# further below would NOT catch it: they only test for emptiness, and every
# one of those shifted values is non-empty. The run would instead die much
# later, inside a Spark job, with a Hive Metastore URI that is really a
# filesystem path.
#
# DETECTION: argument 13 is now LEGITIMATELY used again (SPARK_TUNING_ARG
# above), so a bare "13 positional arguments" count can no longer be
# trusted alone to mean the old retired form -- doing so would reject every
# new-style caller that also supplies SPARK_TUNING. Disambiguated instead
# by slot 6's CONTENT: in the current argument order slot 6 is
# SRC_METASTORE_URI, which is mandatory and always a "thrift://..." URI; in
# the old retired form slot 6 was DISTCP_OPTS, which is never shaped like
# one (it was either dash-prefixed distcp flags, a literal "(reserved)"
# placeholder, or empty). A 13-argument call whose slot 6 IS a thrift://
# URI is therefore unambiguously the new form with SPARK_TUNING supplied;
# only a 13-argument call whose slot 6 is NOT a thrift:// URI is the old,
# retired form.
####################################
check_retired_distcp_opts_arg() {
  local positional_count="$1"
  local slot6="${2:-}"
  [[ "$positional_count" -eq 13 ]] || return 0
  [[ "$slot6" == thrift://* ]] && return 0
  log_error "Got 13 positional arguments with slot #6 = '${slot6}' -- that's the OLD, retired argument order"
  log_error "(slot #6 was DISTCP_OPTS). The DISTCP_OPTS slot was REMOVED: the STEP 5 copy engine and its options"
  log_error "are chosen with environment variables (COPY_ENGINE, DISTCP_*), not with an argument."
  log_error "Arguments 7-13 of the old form are now 6-12 in the CURRENT order, followed by the optional"
  log_error "arguments 13-15. Drop the old slot 6 value and pass:"
  log_error "  1 INCLUDE_FILTERS  2 SRC_NAMESERVICE  3 DST_NAMESERVICE  4 SRC_JDBC_URL  5 DST_JDBC_URL"
  log_error "  6 SRC_METASTORE_URI  7 DST_METASTORE_URI  8 LOG_DIR  9 CHECKPOINT_DIR"
  log_error "  10 HDFS_USER  11 SPARK_USER  12 REBUILD_DST_TABLE_FROM_SOURCE"
  log_error "  13 SPARK_TUNING (optional)  14 SPARK_EXTRA_CONF (optional)  15 SEED_CHECKPOINT (optional)"
  log_error "Update the caller (Pulse Action config, cron entry, wrapper script) before re-running."
  exit 1
}
check_retired_distcp_opts_arg "${#SCRIPT_POSITIONAL_ARGV[@]}" "${6:-}"

####################################
# apply_spark_tuning_arg: parse SPARK_TUNING_ARG's "key=value,key=value"
# spec (see its own declaration above) and EXPORT the corresponding
# SPARK_*/env var for each recognized key -- run before any of those
# variables' own "${VAR:-default}" declarations further below, so a
# positionally-set knob is picked up exactly like an environment-set one,
# with no separate code path. An env var already set in this process's
# environment before the script started still wins over a key that is
# ABSENT from the spec (export only happens for keys actually present),
# but a key that IS present in the spec always overrides that same-named
# env var -- the positional argument is the more specific, more recently
# stated intent when both are given.
#
# rewrite_driver_mem/rewrite_driver_cores and copier_driver_mem/
# copier_driver_cores have no dedicated SPARK_REWRITE_*/SPARK_COPIER_*
# variable of their own (see SPARK_REWRITE_DRIVER_MEMORY/
# SPARK_REWRITE_DRIVER_CORES and their copier equivalents, declared
# alongside SPARK_REWRITE_EXTRA_ARGS/SPARK_COPIER_EXTRA_ARGS below) --
# exported directly into those instead.
#
# Malformed entries (missing "=", or a key not on the recognized list) are
# a hard startup error, not a silently ignored no-op: a typo'd key here
# would otherwise leave a production run silently un-tuned with no
# indication why, which is worse than failing fast with the exact bad
# token named.
####################################
apply_spark_tuning_arg() {
  local spec="$1"
  [[ -z "$spec" ]] && return 0
  local -a pairs=()
  IFS=',' read -ra pairs <<< "$spec"
  local pair key value
  for pair in "${pairs[@]}"; do
    [[ -z "$pair" ]] && continue
    if [[ "$pair" != *=* ]]; then
      log_error "Malformed SPARK_TUNING entry '${pair}' (argument 13) -- expected 'key=value'."
      exit 1
    fi
    key="${pair%%=*}"
    value="${pair#*=}"
    case "$key" in
      queue)                  export SPARK_QUEUE="$value" ;;
      yarn_archive)           export SPARK_YARN_ARCHIVE="$value" ;;
      rewrite_cores)          export SPARK_REWRITE_EXECUTOR_CORES="$value" ;;
      rewrite_mem)            export SPARK_REWRITE_EXECUTOR_MEMORY="$value" ;;
      rewrite_dynamic)        export SPARK_REWRITE_DYNAMIC_ALLOCATION="$value" ;;
      rewrite_max_executors)  export SPARK_REWRITE_MAX_EXECUTORS="$value" ;;
      rewrite_driver_mem)     export SPARK_REWRITE_DRIVER_MEMORY="$value" ;;
      rewrite_driver_cores)   export SPARK_REWRITE_DRIVER_CORES="$value" ;;
      copier_cores)           export SPARK_COPIER_EXECUTOR_CORES="$value" ;;
      copier_mem)             export SPARK_COPIER_EXECUTOR_MEMORY="$value" ;;
      copier_dynamic)         export SPARK_COPIER_DYNAMIC_ALLOCATION="$value" ;;
      copier_max_executors)   export SPARK_COPIER_MAX_EXECUTORS="$value" ;;
      copier_driver_mem)      export SPARK_COPIER_DRIVER_MEMORY="$value" ;;
      copier_driver_cores)    export SPARK_COPIER_DRIVER_CORES="$value" ;;
      *)
        log_error "Unrecognized SPARK_TUNING key '${key}' (argument 13). Recognized keys: queue, yarn_archive,"
        log_error "rewrite_cores, rewrite_mem, rewrite_dynamic, rewrite_max_executors, rewrite_driver_mem,"
        log_error "rewrite_driver_cores, copier_cores, copier_mem, copier_dynamic, copier_max_executors,"
        log_error "copier_driver_mem, copier_driver_cores."
        exit 1
        ;;
    esac
  done
}
apply_spark_tuning_arg "$SPARK_TUNING_ARG"

# SPARK_EXTRA_CONF (argument 14, optional, default ""): a raw, UNPARSED
# escape hatch for any Spark property SPARK_TUNING's named keys don't
# cover -- e.g. "--conf spark.network.timeout=300s --conf
# spark.executor.memoryOverhead=512m". Deliberately NOT part of
# SPARK_TUNING's own comma-separated "key=value" spec: a raw --conf string
# can itself contain commas (comma-separated property values,
# space-separated multiple --conf flags), which would collide with
# SPARK_TUNING's own top-level comma splitting. This argument is taken
# verbatim instead and appended to BOTH SPARK_REWRITE_EXTRA_ARGS and
# SPARK_COPIER_EXTRA_ARGS (see their own declaration below) -- i.e. it
# applies to STEP 4's rewrite/register job AND STEP 5's copier job alike,
# same as those two env vars already do individually. A caller needing an
# asymmetric override (one job only) still has the env vars themselves
# available for that; this positional slot is deliberately the common,
# "just get me this one extra knob to both jobs" case, not a full
# per-job split -- adding that split can be a later argument if it's ever
# actually needed, since this one is purely additive at the end of the
# argument list.
SPARK_EXTRA_CONF_ARG="${14:-}"

# SEED_CHECKPOINT (argument 15, optional, default "false"): "true" runs
# this invocation in seed-only mode (see "SEEDING CHECKPOINTS WITHOUT
# REPLICATING" in the header). The positional form exists for callers that
# can pass neither the bare --seed-checkpoint flag token nor an environment
# variable at run time. When the argument is omitted or empty, the
# SEED_CHECKPOINT environment variable supplies the value instead; an
# explicit argument always wins over the environment, the same precedence
# SPARK_TUNING uses.
#
# Validated strictly: "true" and "false" select two entirely different runs
# (seed only vs. replicate), so an unrecognized value is a startup error
# rather than something to guess at.
SEED_CHECKPOINT_ARG="${15:-${SEED_CHECKPOINT:-false}}"
case "${SEED_CHECKPOINT_ARG,,}" in
  true|false) ;;
  *)
    log_error "SEED_CHECKPOINT (argument 15, or the SEED_CHECKPOINT environment variable) must be 'true' or 'false' (got '${SEED_CHECKPOINT_ARG}')"
    exit 1
    ;;
esac

# Iceberg Spark runtime jar. On this ODP build, Spark3's default classpath already bundles the Iceberg
# runtime, so the default here is to add NO extra runtime flag at all. Only set this if a given target
# host does NOT already have Iceberg on Spark's classpath: point it at a pre-staged local jar path,
# passed via --jars (no network access needed).
ICEBERG_SPARK_JAR="${ICEBERG_SPARK_JAR:-}"
# Spark catalog name that resolves to the Iceberg/Hive catalog on each side. CALL <catalog>.system.<procedure>
# requires a real catalog reference -- per iceberg/docs/docs/spark-procedures.md, this is always
# `spark_catalog` or an explicit named catalog, never a bare `sys`.
SPARK_CATALOG="${ICEBERG_SPARK_CATALOG:-spark_catalog}"

# ------------------------------------------------------------------------------------------------------
#  SPARK_RUN_MODE (env var, default: "yarn") - where the rewrite_table_path / register_table Spark job
#  runs. Only these two values are accepted:
#
#    "yarn" (DEFAULT) - a real distributed YARN application, --master yarn --deploy-mode client.
#      Executors are containers on cluster nodes, so the metadata rewrite scales out instead of being
#      bounded by one host. Executors reach the other cluster with delegation tokens; see the
#      DELEGATION-TOKEN CONFS block further below for which of them YARN renews.
#      REQUIRES AUTO_DERIVE_HA_CLIENT_CONFIG=yes (with SRC_NN_HOSTS/DST_NN_HOSTS set). A YARN executor
#      container does not inherit this host's hdfs-site.xml just because AUTO_DERIVE_HA_CLIENT_CONFIG=no
#      "relies on the host's own config" -- that fallback only reaches a LOCAL driver reading files off
#      this host's disk. Without the explicit spark.hadoop.dfs.ha.* --conf values that
#      AUTO_DERIVE_HA_CLIENT_CONFIG=yes adds, an executor has no HA knowledge of either nameservice and
#      can resolve it to a STANDBY NameNode, failing with "Operation category READ is not supported in
#      state standby" -- observed in practice, and now enforced at startup (SPARK_RUN_MODE=yarn with
#      AUTO_DERIVE_HA_CLIENT_CONFIG=no is a hard error, not just a warning).
#
#    "local" - one JVM on THIS host, --master local[*]. The process already holding a valid Kerberos
#      ticket does every read itself, so there is no executor-to-remote-NameNode hop at all. Does not
#      parallelise across the cluster, so a very large table is bounded by this one host's CPU/memory --
#      the fallback for a cluster where the token-renewal exclusion below has NOT been verified to work,
#      or where YARN capacity should not be spent on this job at all.
#
#  ICEBERG_SPARK_MASTER (env var, no default) - escape hatch that overrides SPARK_RUN_MODE entirely with
#  a literal --master string, for anything these two modes do not express ("local[4]", a standalone
#  "spark://host:7077", etc.). When set, SPARK_RUN_MODE is ignored and no YARN-specific flags are added.
#
#  SPARK_QUEUE (env var, default: unset) - YARN queue for the Spark application, when SPARK_RUN_MODE=yarn.
#  Applies to every spark-sql/spark-shell submission this script makes.
# ------------------------------------------------------------------------------------------------------
SPARK_RUN_MODE="${SPARK_RUN_MODE:-yarn}"
SPARK_QUEUE="${SPARK_QUEUE:-}"
# SPARK_YARN_ARCHIVE (env var, default unset) - see "WHERE THE SPARK JOB
# RUNS" in the header. A full URI is required: Spark resolves a bare path
# against the local disk, not HDFS.
SPARK_YARN_ARCHIVE="${SPARK_YARN_ARCHIVE:-}"
if [[ -n "$SPARK_YARN_ARCHIVE" && "$SPARK_YARN_ARCHIVE" != *"://"* ]]; then
  log_error "SPARK_YARN_ARCHIVE must be a full URI such as hdfs://<nameservice>/apps/spark/spark-libs.jar (got '${SPARK_YARN_ARCHIVE}')."
  exit 1
fi

case "${SPARK_RUN_MODE,,}" in
  local|yarn) ;;
  *)
    log_error "SPARK_RUN_MODE must be one of: local, yarn (got '${SPARK_RUN_MODE}')"
    log_error "Use ICEBERG_SPARK_MASTER to pass a literal --master string instead (e.g. 'local[4]')."
    exit 1
    ;;
esac

# Resolve SPARK_RUN_MODE (see its declaration near the top of the script)
# into the actual --master string, plus any mode-specific flags.
#
# Precedence: an explicit ICEBERG_SPARK_MASTER wins outright and suppresses
# the YARN extras, since a caller passing a literal master string is asking
# for exactly that and nothing else.
#
# WHY "yarn" IS THE DEFAULT: under --master yarn the executors are
# containers on remote nodes, which must authenticate to the OTHER
# cluster's NameNode with delegation tokens. The ResourceManager cannot
# renew the other cluster's tokens, so those are excluded from renewal (see
# the DELEGATION-TOKEN CONFS block below). "local" remains available as a
# fallback: the single process already holding a valid Kerberos ticket
# performs every read itself, with no executor-to-remote-NameNode hop, but
# it does not parallelise, so it is bounded by this one host for a very
# large table.
SPARK_YARN_ARGS=()
if [[ -n "${ICEBERG_SPARK_MASTER:-}" ]]; then
  SPARK_MASTER="${ICEBERG_SPARK_MASTER}"
  SPARK_RUN_MODE="explicit"
elif [[ "${SPARK_RUN_MODE,,}" == "yarn" ]]; then
  SPARK_MASTER="yarn"
  # deploy-mode MUST be client: spark-sql is an interactive driver that
  # reads SQL from -e and streams results back to this process, so its
  # driver cannot be relocated into a YARN AM container. `--deploy-mode
  # cluster` is rejected outright by spark-sql, not silently degraded.
  SPARK_YARN_ARGS+=(--deploy-mode client)
  # The delegation-token confs (spark.kerberos.access.hadoopFileSystems and
  # spark.yarn.kerberos.renewal.excludeHadoopFileSystems) are not emitted
  # here: their values depend on SAME_NAMESERVICE_COLLISION, which is not
  # known yet at this point in the script. They are emitted exactly once,
  # later, by the block headed "DELEGATION-TOKEN CONFS (single emission
  # point)", and must not also be added here: two emissions with different
  # values for one key leave Spark with whichever comes last.
  if [[ -n "$SPARK_QUEUE" ]]; then
    SPARK_YARN_ARGS+=(--conf "spark.yarn.queue=${SPARK_QUEUE}")
  fi
  if [[ -n "$SPARK_YARN_ARCHIVE" ]]; then
    SPARK_YARN_ARGS+=(--conf "spark.yarn.archive=${SPARK_YARN_ARCHIVE}")
  fi
else
  SPARK_MASTER="local[*]"
fi

# ------------------------------------------------------------------------------------------------------
#  AUTO_DERIVE_HA_CLIENT_CONFIG (env var, default: "no") - inject HA NameNode configuration directly into
#  spark-sql (--conf) and `hadoop fs`/`hdfs` (-D) invocations. Accepts "yes" or "no" (case-insensitive).
#
#  Normally, an HA nameservice must already be resolvable to spark-sql/`hadoop fs` through the host's own
#  hdfs-site.xml, configured once cluster-wide (a plain `hdfs dfs -ls hdfs://<other-cluster-nameservice>/`
#  should already work for both clusters when this is the case). Set AUTO_DERIVE_HA_CLIENT_CONFIG=yes to
#  have this script inject the real NameNode addresses directly into every spark-sql/hadoop-fs
#  call instead -- useful when one cluster's hdfs-site.xml does not yet know about the other cluster's
#  nameservice. Requires SRC_NN_HOSTS and DST_NN_HOSTS (below) to be set.
#
#  Default "no": no -D/--conf HA override is added at all, and spark-sql/`hadoop fs` fall back to the
#  host's own merged hdfs-site.xml.
# ------------------------------------------------------------------------------------------------------
AUTO_DERIVE_HA_CLIENT_CONFIG="${AUTO_DERIVE_HA_CLIENT_CONFIG:-no}"
case "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" in
  yes|no) ;;
  *)
    log_error "AUTO_DERIVE_HA_CLIENT_CONFIG must be 'yes' or 'no' (got '${AUTO_DERIVE_HA_CLIENT_CONFIG}')"
    exit 1
    ;;
esac

# SRC_NN_HOSTS / DST_NN_HOSTS - required when AUTO_DERIVE_HA_CLIENT_CONFIG=yes.
# Comma-separated "<nn-id>=<host>:<port>" pairs describing each
# nameservice's NameNodes, for example:
#   SRC_NN_HOSTS="nn1=atlasdemo-01.adsre.com:8020,nn2=atlasdemo-02.adsre.com:8020"
#   DST_NN_HOSTS="nn1=repl1.adsre.com:8020,nn2=repl2.adsre.com:8020"
SRC_NN_HOSTS="${SRC_NN_HOSTS:-}"
DST_NN_HOSTS="${DST_NN_HOSTS:-}"

# AUTOMATIC_FAILOVER_ENABLED - only used when AUTO_DERIVE_HA_CLIENT_CONFIG=yes.
AUTOMATIC_FAILOVER_ENABLED="${AUTOMATIC_FAILOVER_ENABLED:-true}"

if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
  if [[ -z "$SRC_NN_HOSTS" || -z "$DST_NN_HOSTS" ]]; then
    log_error "AUTO_DERIVE_HA_CLIENT_CONFIG=yes requires both SRC_NN_HOSTS and DST_NN_HOSTS to be set."
    log_error "(spark-sql/hadoop fs need each nameservice's real NameNode addresses to"
    log_error "resolve the OTHER cluster's logical HA nameservice name)."
    log_error "Example: SRC_NN_HOSTS=\"nn1=host1:8020,nn2=host2:8020\""
    exit 1
  fi
else
  log_info "AUTO_DERIVE_HA_CLIENT_CONFIG=no -- assuming '${SRC_NAMESERVICE}' and '${DST_NAMESERVICE}'"
  log_info "are already resolvable via this host's own Hadoop client config (no HA override)."
fi

# SAME-NAMESERVICE COLLISION (SRC_NAMESERVICE == DST_NAMESERVICE): two
# DIFFERENT physical clusters that both call themselves the same HA
# nameservice name (e.g. a DR cluster built from the same blueprint as
# production). See "SAME-NAMESERVICE COLLISION" in this script's header for
# the full mechanism this enables -- the short version:
#
#   A single Hadoop Configuration/JVM cannot bind one nameservice name to
#   two different sets of NameNodes AT THE SAME TIME. So a query that both
#   (a) needs to physically read source's real files (whose embedded paths
#   literally say "hdfs://<name>") and (b) needs the destination-side copy
#   to end up reading the SAME plain "hdfs://<name>" for its own HA safety,
#   cannot be done in one pass, one process. It is done in TWO passes
#   instead: an isolated, per-call override redirects "<name>" to SOURCE's
#   real NameNodes for exactly the one job that must read source (STEP
#   4/hop A); DESTINATION is addressed via a resolved, literal active-
#   NameNode host:port (resolve_active_namenode_hostport()) wherever this
#   run needs it reachable simultaneously with the redirected name (STEP
#   5's copier); and a second, purely LOCAL rewrite (hop B) then relabels
#   that content back to the plain shared name before anything is
#   registered/repointed -- a same-cluster operation with no cross-cluster
#   ambiguity at all.
#
# REQUIRES AUTO_DERIVE_HA_CLIENT_CONFIG=yes with SRC_NN_HOSTS/DST_NN_HOSTS:
# this script has to be the one supplying real NameNode addresses for the
# redirect, and no hdfs-site.xml can define two different address sets for
# one real, colliding name.
#
# UNLIKE a plain distinct-nameservice pair, this is NOT something
# AUTO_DERIVE_HA_CLIENT_CONFIG=no can ever cover, no matter how the two
# clusters' own hdfs-site.xml files are merged: merging cannot make one
# name resolve two different ways depending on which job asks.
SAME_NAMESERVICE_COLLISION=false
if [[ -n "$SRC_NAMESERVICE" && "$SRC_NAMESERVICE" == "$DST_NAMESERVICE" ]]; then
  if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]]; then
    log_error "SRC_NAMESERVICE and DST_NAMESERVICE are both '${SRC_NAMESERVICE}'."
    log_error "This is supported ONLY when it means two DIFFERENT physical clusters that happen to share"
    log_error "one HA nameservice name (e.g. a DR cluster built from the same blueprint as production) --"
    log_error "and even then, this script must be told both sides' real NameNode addresses explicitly, since"
    log_error "no hdfs-site.xml anywhere can express 'this one name means two different clusters depending"
    log_error "on which job asks.' Set AUTO_DERIVE_HA_CLIENT_CONFIG=yes with SRC_NN_HOSTS/DST_NN_HOSTS, or"
    log_error "give the two sides distinct labels on this script's command line instead (they do not need to"
    log_error "match either cluster's real internal nameservice ID), e.g. '${SRC_NAMESERVICE}-SRC' and"
    log_error "'${SRC_NAMESERVICE}-DST'."
    # Show the CURRENT effective values, not just what to set them to. This
    # is not a hypothetical config gap -- it is what actually triggered this
    # exit, and a bare "not set" won't distinguish "never configured" from
    # "configured in a different shell/session, which doesn't help this
    # one": env vars set with `export` in an earlier terminal, an earlier
    # `su`/`sudo -i`, or a previous SSH session are NOT visible here -- each
    # new shell starts with none of them unless this one also exported them
    # (or a caller like Pulse Actions passes them into THIS process's own
    # environment). Printing what this process actually sees turns "why did
    # this fail again, I already set these" into an immediately obvious
    # answer.
    log_error "Current values in THIS shell/process (env vars do not carry over from a different terminal,"
    log_error "a previous 'su'/'sudo -i', or an earlier session -- they must be exported in the exact shell"
    log_error "that invokes this script):"
    log_error "  AUTO_DERIVE_HA_CLIENT_CONFIG = ${AUTO_DERIVE_HA_CLIENT_CONFIG}"
    log_error "  SRC_NN_HOSTS                 = ${SRC_NN_HOSTS:-<unset>}"
    log_error "  DST_NN_HOSTS                 = ${DST_NN_HOSTS:-<unset>}"
    exit 1
  fi
  SAME_NAMESERVICE_COLLISION=true
  log_warn "SRC_NAMESERVICE and DST_NAMESERVICE are both '${SRC_NAMESERVICE}' -- treating this as a"
  log_warn "SAME-NAMESERVICE COLLISION (two different physical clusters sharing one HA nameservice name)."
  log_warn "See 'SAME-NAMESERVICE COLLISION' in this script's header for the full mechanism."
fi

# ------------------------------------------------------------------------------------------------------
#  STEP 5's copy engine is selected by COPY_ENGINE (env var, default "spark"):
#
#  COPY_ENGINE=spark (DEFAULT) -- one Spark job for the WHOLE file list, regardless of how many
#  partitions it spans. Each task copies its own share of (source,target) pairs via the Hadoop FileSystem
#  API, writing each file to its exact target path. Verified in production on this DR pair -- 3346 files
#  (2568 copied, 778 already present) in a single application. Runs on whatever master SPARK_RUN_MODE
#  selects, which now defaults to "yarn" -- so the out-of-the-box combination is already a real
#  distributed Spark application. If SPARK_RUN_MODE (or ICEBERG_SPARK_MASTER) is overridden to "local",
#  the copier falls back to one Spark job pinned to THIS host -- correct but not distributed. The script
#  warns at startup when it sees that combination.
#
#  COPY_ENGINE=distcp -- group the file list by TARGET directory, run one `hadoop distcp -f` job per
#  group. Required grouping, not a choice: distcp -f copies every listed source into ONE target directory
#  using only the file's BASENAME -- it cannot reconstruct a nested partition path -- so its YARN job
#  count is forced to equal the number of distinct target directories the delta touches, i.e. the table's
#  touched-partition count: observed here at 82 jobs for a single 3035-file bootstrap, most of them moving
#  a few KB and dominated by AM/container launch. The Spark copier has no such constraint, but the distcp
#  copier gets real distcp preserve/update semantics in exchange (DISTCP_PRESERVE_OPTS, always with
#  -update). Runs as a plain `hadoop` CLI process (run_as_hdfs), independent of SPARK_RUN_MODE.
#
#  WHAT THE SPARK COPIER GIVES UP relative to distcp: distcp's `-p[bugpcaxt]` preserve set is a distcp
#  feature, not a filesystem one. The Spark copier re-applies permission, owner/group, and modification
#  time explicitly after each copy (best-effort -- failures are counted and reported as a [WARN] summary,
#  not fatal, since setOwner needs superuser), but it does NOT replicate ACLs or XAttrs. Confirmed not
#  needed on this deployment (access control is managed at the Hive/Ranger catalog layer); a deployment
#  relying on HDFS-level ACLs/XAttrs for these tables should prefer COPY_ENGINE=distcp with an appropriate
#  DISTCP_PRESERVE_OPTS.
#
#  SPARK_COPY_PARTITIONS (env var, default 0 = auto) - COPY_ENGINE=spark only. How many Spark tasks the
#  copy is split across. Auto targets roughly 50 files per task, capped at 2000 tasks, which keeps
#  per-task overhead negligible without producing thousands of tiny tasks for a small delta. Raise it for
#  a very large delta on a large cluster; the copy is embarrassingly parallel, so this is a straight
#  throughput knob.
#
#  DISTCP_PRESERVE_OPTS (env var, default "-pugp") - COPY_ENGINE=distcp only. Preserve flags passed to
#  each `hadoop distcp -f` invocation.
# ------------------------------------------------------------------------------------------------------
# ------------------------------------------------------------------------------------------------------
#  STAGING_ROOT (env var, default "/var/tmp/iceberg-repl-staging") - HDFS directory under which
#  rewrite_table_path stages each table's path-corrected metadata, as
#  "<STAGING_ROOT>/<table-relative-path>". This is an HDFS path, NOT a local one, and it always lives on
#  the DESTINATION cluster: it is passed to rewrite_table_path qualified as
#  "hdfs://<DST_NAMESERVICE><STAGING_ROOT>/<table-relative-path>" (see STAGING_LOCATION in STEP 1), and
#  the [5b] staging check reads it back as "hdfs://<DST_NAMESERVICE><STAGING_DIR>/stats".
#
#  NOT under /tmp, deliberately. HDFS /tmp is conventionally the dumping ground that cluster cleanup
#  policies target -- an admin cron or retention rule that sweeps /tmp would delete a table's staged
#  metadata out from under an in-flight run, and (worse) could remove staged files between STEP 4 writing
#  them and STEP 5 copying them, producing a run that fails partway with files that "existed a moment
#  ago". /var/tmp carries no such convention and is the safer default for content that must survive for
#  the duration of a replication.
#
#  OPERATIONAL NOTE: the directory is created on demand by Spark/Iceberg (and by [5d]'s own mkdir for the
#  copy list), which needs write permission on the path's parents. If "/var" does not already exist on
#  the destination HDFS, creating it requires write access at the HDFS root -- normally a superuser
#  operation. Pre-create "/var/tmp" with appropriate ownership once, or point STAGING_ROOT somewhere the
#  replication user already owns, e.g.:
#    export STAGING_ROOT="/user/svc_replication/iceberg-repl-staging"
# ------------------------------------------------------------------------------------------------------
STAGING_ROOT="${STAGING_ROOT:-/var/tmp/iceberg-repl-staging}"
# Strip any trailing slash so "<STAGING_ROOT><TABLE_RELATIVE_PATH>" (the latter always begins with "/")
# can never produce a doubled separator.
STAGING_ROOT="${STAGING_ROOT%/}"
if [[ "$STAGING_ROOT" != /* ]]; then
  log_error "STAGING_ROOT must be an absolute path (got '${STAGING_ROOT}')"
  exit 1
fi

# COPY_ENGINE (env var, default "spark") - which engine STEP 5 uses to copy
# the enumerated (source,target) file list: "spark" (run_spark_copier, one
# Spark job for the whole delta -- see "HOW STEP 5 COPIES THE FILES" above)
# or "distcp" (run_distcp_copier, one `hadoop distcp -f` job per distinct
# target directory -- see that function's own header comment for why it must
# be grouped that way, and for what it gives back relative to the Spark
# copier: real -p[bugpcaxt] preserve flags and -update semantics, at the cost
# of job count scaling with touched-partition count rather than one job for
# the whole delta).
#
# STEP5_COPY_MODE is this variable's older, now-removed name; a caller still
# setting it gets an explicit error rather than a silently ignored value.
if [[ -n "${STEP5_COPY_MODE:-}" ]]; then
  log_error "STEP5_COPY_MODE is no longer used -- set COPY_ENGINE instead (got STEP5_COPY_MODE='${STEP5_COPY_MODE}')."
  exit 1
fi
COPY_ENGINE="${COPY_ENGINE:-spark}"
COPY_ENGINE="${COPY_ENGINE,,}"
if [[ "$COPY_ENGINE" != "spark" && "$COPY_ENGINE" != "distcp" ]]; then
  log_error "COPY_ENGINE must be 'spark' or 'distcp' (got '${COPY_ENGINE}')."
  exit 1
fi

SPARK_COPY_PARTITIONS="${SPARK_COPY_PARTITIONS:-0}"
if [[ ! "$SPARK_COPY_PARTITIONS" =~ ^[0-9]+$ ]]; then
  log_error "SPARK_COPY_PARTITIONS must be a non-negative integer (0 = auto) (got '${SPARK_COPY_PARTITIONS}')"
  exit 1
fi

# ------------------------------------------------------------------------------------------------------
#  SPARK_COPIER_* (env vars) - executor sizing for the STEP 5 Spark copier specifically, distinct from
#  whatever sizing the cluster's Spark defaults give an unconfigured spark-shell launch.
#
#  WHY THIS EXISTS. SPARK_COPY_PARTITIONS controls how many TASKS the copy is split into, but a task is
#  worthless in parallel if there are not enough EXECUTORS to run it on: an unconfigured `spark-shell`
#  launch typically starts with whatever the cluster's static defaults are (often just 1-2 executors),
#  so 2000 tasks queued onto 2 executors runs barely faster than the old serial distcp path it was meant
#  to replace. This is the actual lever for wall-clock time, separate from task count.
#
#  SPARK_COPIER_EXECUTOR_CORES (default 1) / SPARK_COPIER_EXECUTOR_MEMORY (default "1g") - deliberately
#  small. Copying a file is I/O-bound (open source, open target, stream bytes, close both), not
#  compute-bound -- many small executors saturate the cluster's read/write bandwidth far better than a
#  few large ones competing for the same NameNode/DataNode connections.
#
#  SPARK_COPIER_DYNAMIC_ALLOCATION (default "true", only used when SPARK_RUN_MODE=yarn) - lets YARN grow
#  executor count to match the task count for THIS job, then release them when it finishes, rather than
#  holding a fixed executor count for the whole run regardless of how large any one table's delta is.
#  Requires the cluster's own dynamicAllocation.enabled + shuffle-service prerequisites to actually be
#  configured; if they are not, Spark falls back to its static default and this has no effect (it does
#  not, itself, turn on the cluster-wide external shuffle service).
#
#  SPARK_COPIER_MAX_EXECUTORS (default 0 = no cap) - the max executors dynamic allocation is allowed to
#  grow to for this job, INDEPENDENT of SPARK_COPY_PARTITIONS. "0" intentionally omits maxExecutors
#  entirely rather than deriving a script-chosen ceiling: on a large production cluster the real limit is
#  the YARN queue's own capacity, and a hardcoded number here would just be an artificial bottleneck under
#  it. Set this explicitly if a job should be bounded below the queue's own capacity (e.g. to leave
#  headroom for other jobs sharing the same queue).
# ------------------------------------------------------------------------------------------------------
SPARK_COPIER_EXECUTOR_CORES="${SPARK_COPIER_EXECUTOR_CORES:-1}"
if [[ ! "$SPARK_COPIER_EXECUTOR_CORES" =~ ^[1-9][0-9]*$ ]]; then
  log_error "SPARK_COPIER_EXECUTOR_CORES must be a positive integer (got '${SPARK_COPIER_EXECUTOR_CORES}')"
  exit 1
fi

SPARK_COPIER_EXECUTOR_MEMORY="${SPARK_COPIER_EXECUTOR_MEMORY:-1g}"
if [[ ! "$SPARK_COPIER_EXECUTOR_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]]; then
  log_error "SPARK_COPIER_EXECUTOR_MEMORY must look like '512m' or '2g' (got '${SPARK_COPIER_EXECUTOR_MEMORY}')"
  exit 1
fi

SPARK_COPIER_DYNAMIC_ALLOCATION="${SPARK_COPIER_DYNAMIC_ALLOCATION:-true}"
case "${SPARK_COPIER_DYNAMIC_ALLOCATION,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "SPARK_COPIER_DYNAMIC_ALLOCATION must be one of: true, false (got '${SPARK_COPIER_DYNAMIC_ALLOCATION}')"
    exit 1
    ;;
esac

SPARK_COPIER_MAX_EXECUTORS="${SPARK_COPIER_MAX_EXECUTORS:-0}"
if [[ ! "$SPARK_COPIER_MAX_EXECUTORS" =~ ^[0-9]+$ ]]; then
  log_error "SPARK_COPIER_MAX_EXECUTORS must be a non-negative integer (0 = auto) (got '${SPARK_COPIER_MAX_EXECUTORS}')"
  exit 1
fi

# ------------------------------------------------------------------------------------------------------
#  SPARK_REWRITE_DRIVER_MEMORY / SPARK_REWRITE_DRIVER_CORES / SPARK_COPIER_DRIVER_MEMORY /
#  SPARK_COPIER_DRIVER_CORES (env vars, default empty = no override) - driver sizing for STEP 4's
#  rewrite/register job and STEP 5's copier job respectively, applied as --driver-memory/--driver-cores.
#
#  WHY THIS EXISTS. Neither spark-sql nor spark-shell is given a driver size anywhere else in this
#  script, so absent a cluster-wide spark.driver.memory/spark.driver.cores in spark-defaults.conf, both
#  jobs' drivers run at Spark's own hard-coded default (1g / effectively 1 core) -- normally plenty,
#  since the driver here only orchestrates (issues one CALL, or drives the copier's own Spark job) and
#  never holds the actual manifest/file data itself. Left empty (the default) on purpose: a hardcoded
#  non-empty default here would silently override whatever this cluster's own spark-defaults.conf or
#  Spark's built-in default already provides, for no reason, on every single run. Set these explicitly
#  only once a real driver-memory problem is observed (e.g. an unusually large file-list CSV or
#  metadata_log_entries result set for STEP 4/5's driver-side parsing).
#
#  Settable positionally via SPARK_TUNING's rewrite_driver_mem/rewrite_driver_cores/copier_driver_mem/
#  copier_driver_cores keys (see apply_spark_tuning_arg() above) for callers that cannot pass env vars.
# ------------------------------------------------------------------------------------------------------
SPARK_REWRITE_DRIVER_MEMORY="${SPARK_REWRITE_DRIVER_MEMORY:-}"
if [[ -n "$SPARK_REWRITE_DRIVER_MEMORY" && ! "$SPARK_REWRITE_DRIVER_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]]; then
  log_error "SPARK_REWRITE_DRIVER_MEMORY must look like '512m' or '2g' (got '${SPARK_REWRITE_DRIVER_MEMORY}')"
  exit 1
fi
SPARK_REWRITE_DRIVER_CORES="${SPARK_REWRITE_DRIVER_CORES:-}"
if [[ -n "$SPARK_REWRITE_DRIVER_CORES" && ! "$SPARK_REWRITE_DRIVER_CORES" =~ ^[1-9][0-9]*$ ]]; then
  log_error "SPARK_REWRITE_DRIVER_CORES must be a positive integer (got '${SPARK_REWRITE_DRIVER_CORES}')"
  exit 1
fi
SPARK_COPIER_DRIVER_MEMORY="${SPARK_COPIER_DRIVER_MEMORY:-}"
if [[ -n "$SPARK_COPIER_DRIVER_MEMORY" && ! "$SPARK_COPIER_DRIVER_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]]; then
  log_error "SPARK_COPIER_DRIVER_MEMORY must look like '512m' or '2g' (got '${SPARK_COPIER_DRIVER_MEMORY}')"
  exit 1
fi
SPARK_COPIER_DRIVER_CORES="${SPARK_COPIER_DRIVER_CORES:-}"
if [[ -n "$SPARK_COPIER_DRIVER_CORES" && ! "$SPARK_COPIER_DRIVER_CORES" =~ ^[1-9][0-9]*$ ]]; then
  log_error "SPARK_COPIER_DRIVER_CORES must be a positive integer (got '${SPARK_COPIER_DRIVER_CORES}')"
  exit 1
fi

# ------------------------------------------------------------------------------------------------------
#  SPARK_REWRITE_EXTRA_ARGS / SPARK_COPIER_EXTRA_ARGS (env vars, default empty) - free-form extra
#  spark-sql/spark-shell flags, appended AFTER every --conf this script builds itself, for the STEP 4
#  rewrite/register job and the STEP 5 copier job respectively. spark-submit's own argument parsing keeps
#  the LAST occurrence of a repeated --conf key (already relied on elsewhere in this script, e.g. the
#  SAME-NAMESERVICE COLLISION YARN-conf fix), so a value passed here silently wins over this script's own
#  default for the same key.
#
#  WHY THIS EXISTS. SPARK_REWRITE_*/SPARK_COPIER_* above name only the tuning knobs anticipated when this
#  script was written (executor cores/memory, dynamic allocation, its cap). Running this at "hundreds of
#  independently scheduled replication policies" scale will eventually need a knob this script has no
#  name for -- shuffle-partition count, memory overhead, speculative execution, a broadcast-join
#  threshold, a scheduler pool -- without waiting for a script change to add a new named variable for
#  every such case. This is that escape hatch: pass anything spark-sql/spark-shell accepts, verbatim.
#    export SPARK_REWRITE_EXTRA_ARGS="--conf spark.sql.shuffle.partitions=8 --conf spark.executor.memoryOverhead=512m"
#    export SPARK_COPIER_EXTRA_ARGS="--conf spark.speculation=false --conf spark.scheduler.pool=repl_low"
#
#  Split on WHITESPACE only (no shell-quoting support) -- every value this script's own SPARK_REWRITE_*/
#  SPARK_COPIER_* knobs accept (sizes like "4g", integers, booleans, class names, comma-separated lists)
#  is space-free by construction, and anything passed through here is expected to be the same shape. A
#  value that genuinely needs an embedded space cannot be expressed this way.
# ------------------------------------------------------------------------------------------------------
SPARK_REWRITE_EXTRA_ARGS="${SPARK_REWRITE_EXTRA_ARGS:-}"
SPARK_COPIER_EXTRA_ARGS="${SPARK_COPIER_EXTRA_ARGS:-}"
# SPARK_EXTRA_CONF_ARG (positional argument 14, see its own declaration
# above) is appended AFTER whatever the env vars already held, so
# spark-submit's own "last --conf for a repeated key wins" behavior means
# this positional argument can override an env-var-set conf for the same
# key, but never the reverse.
if [[ -n "$SPARK_EXTRA_CONF_ARG" ]]; then
  SPARK_REWRITE_EXTRA_ARGS="${SPARK_REWRITE_EXTRA_ARGS:+${SPARK_REWRITE_EXTRA_ARGS} }${SPARK_EXTRA_CONF_ARG}"
  SPARK_COPIER_EXTRA_ARGS="${SPARK_COPIER_EXTRA_ARGS:+${SPARK_COPIER_EXTRA_ARGS} }${SPARK_EXTRA_CONF_ARG}"
fi

# ------------------------------------------------------------------------------------------------------
#  SPARK_REWRITE_EXECUTOR_CORES / SPARK_REWRITE_EXECUTOR_MEMORY (env vars) - executor sizing for STEP 4's
#  rewrite_table_path/register_table spark-sql job specifically (run_spark_sql()), distinct from
#  SPARK_COPIER_* above, which only sizes the STEP 5 file-copy job.
#
#  WHY THESE ARE SEPARATE FROM SPARK_COPIER_*. STEP 4 does metadata-only work (walk the manifest/
#  manifest-list lineage between start_version and end_version, write corrected metadata to staging) --
#  no file bytes move here. That is fundamentally lighter per-task than STEP 5's actual data copy, so it
#  gets its own, smaller defaults rather than sharing the copier's knobs or being left at whatever the
#  cluster's unconfigured spark-sql default is (which may be sized for neither job well). No partition-
#  count knob is offered here to match: rewrite_table_path's own internal parallelism, not a
#  user-supplied task count, decides how the manifest walk is split.
#
#  Defaults (2 cores / 4g) are deliberately modest -- enough headroom for a large/many-partition table's
#  full (non-incremental) rewrite without reserving cluster capacity STEP 4 will not use on the common
#  case (a small incremental delta).
#
#  SPARK_REWRITE_DYNAMIC_ALLOCATION (default "true", only used when SPARK_RUN_MODE=yarn) - same idea as
#  SPARK_COPIER_DYNAMIC_ALLOCATION: let YARN grow executor count to match this job's actual work, then
#  release them when it finishes, rather than holding a fixed executor count for every STEP 4 call
#  regardless of whether this run is a tiny incremental repoint or a full bootstrap rewrite. Defaulted to
#  true for the same reason the copier defaults to true -- an idle-but-reserved executor on a shared
#  cluster is a real cost, and STEP 4's own workload size varies enormously between bootstrap and
#  incremental runs. Falls back to Spark's static default if the cluster's own dynamicAllocation
#  prerequisites are not configured, same caveat as the copier's equivalent knob.
#
#  SPARK_REWRITE_MAX_EXECUTORS (default 0 = no cap) - the ceiling dynamic allocation is allowed to grow
#  to for THIS job. At the default of 0, no maxExecutors conf is added at all -- STEP 4 is a
#  metadata-only manifest walk, not a per-file data copy, so unlike SPARK_COPIER_MAX_EXECUTORS there is
#  no task-count-derived formula to pick a sane ceiling from (see the note above on why no
#  partition-count knob exists here either), and a script-chosen number would just be an artificial
#  bottleneck under whatever the YARN queue's own capacity actually is. YARN's queue capacity is the
#  real backstop either way; set this explicitly (e.g. to 20) only if a single table's metadata rewrite
#  needs to be kept well under the queue's own limit on a specific shared cluster.
# ------------------------------------------------------------------------------------------------------
SPARK_REWRITE_EXECUTOR_CORES="${SPARK_REWRITE_EXECUTOR_CORES:-2}"
if [[ ! "$SPARK_REWRITE_EXECUTOR_CORES" =~ ^[1-9][0-9]*$ ]]; then
  log_error "SPARK_REWRITE_EXECUTOR_CORES must be a positive integer (got '${SPARK_REWRITE_EXECUTOR_CORES}')"
  exit 1
fi

SPARK_REWRITE_EXECUTOR_MEMORY="${SPARK_REWRITE_EXECUTOR_MEMORY:-4g}"
if [[ ! "$SPARK_REWRITE_EXECUTOR_MEMORY" =~ ^[1-9][0-9]*[mMgG]$ ]]; then
  log_error "SPARK_REWRITE_EXECUTOR_MEMORY must look like '512m' or '2g' (got '${SPARK_REWRITE_EXECUTOR_MEMORY}')"
  exit 1
fi

SPARK_REWRITE_DYNAMIC_ALLOCATION="${SPARK_REWRITE_DYNAMIC_ALLOCATION:-true}"
case "${SPARK_REWRITE_DYNAMIC_ALLOCATION,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "SPARK_REWRITE_DYNAMIC_ALLOCATION must be one of: true, false (got '${SPARK_REWRITE_DYNAMIC_ALLOCATION}')"
    exit 1
    ;;
esac

# ------------------------------------------------------------------------------------------------------
#  SPARK_REWRITE_VERBOSE_LOG (env var, default "false") - when true, adds --conf spark.log.level=INFO to
#  run_spark_sql()'s STEP 4 rewrite_table_path/register_table calls, so a long-running call's Metastore
#  lock polling / HA failover-proxy retries / commit progress is visible in the log instead of sitting
#  silent under spark-sql's default WARN level until it finishes or fails. Off by default because that
#  INFO stream is verbose and normally only worth paying for while diagnosing a slow or stuck STEP 4 call
#  (e.g. running with SPARK_MASTER=local[*], where there is no YARN UI to check progress in instead).
#  When true, STEP 4's rewrite_table_path stderr is also streamed to the log WHILE the call runs (it is
#  otherwise captured and shown once the call has ended -- see run_spark_sql_capturing_stderr), since
#  progress that only appears after the call is over is no help in telling a slow call from a stuck one.
# ------------------------------------------------------------------------------------------------------
SPARK_REWRITE_VERBOSE_LOG="${SPARK_REWRITE_VERBOSE_LOG:-false}"
case "${SPARK_REWRITE_VERBOSE_LOG,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "SPARK_REWRITE_VERBOSE_LOG must be one of: true, false (got '${SPARK_REWRITE_VERBOSE_LOG}')"
    exit 1
    ;;
esac

SPARK_REWRITE_MAX_EXECUTORS="${SPARK_REWRITE_MAX_EXECUTORS:-0}"
if [[ ! "$SPARK_REWRITE_MAX_EXECUTORS" =~ ^[0-9]+$ ]]; then
  log_error "SPARK_REWRITE_MAX_EXECUTORS must be a non-negative integer (0 = auto) (got '${SPARK_REWRITE_MAX_EXECUTORS}')"
  exit 1
fi

# Iceberg format-version 3 support. See "ICEBERG FORMAT-VERSION SUPPORT (v2
# AND v3)" in the header block for the full rationale; in short, the only
# v3 feature this pipeline cannot always handle is DELETION VECTORS, whose
# path rewriting landed in Iceberg 1.11.0 (PR #14351) and is absent from
# 1.9.x AND 1.10.x.
#
# ICEBERG_DV_SUPPORT: "auto" (detect the runtime version), "true" (assert
# supported -- for a vendor build that backported the fix without bumping
# its version string), or "false" (assert unsupported).
ICEBERG_DV_SUPPORT="${ICEBERG_DV_SUPPORT:-auto}"
# First Iceberg release whose rewrite_table_path rewrites both halves of a
# deletion vector's referenced-data-file path (the manifest entry field AND
# the "referenced-data-file" property inside the Puffin blob).
ICEBERG_MIN_DV_RUNTIME="1.11.0"
# "false" (default): a v3 table carrying deletion vectors that this runtime
# cannot rewrite is a table FAILURE. "true": downgrade it to a SKIP, so the
# run can still report SUCCESS -- only for operators who have accepted that
# those tables are not being protected.
ICEBERG_SKIP_UNSUPPORTED_V3="${ICEBERG_SKIP_UNSUPPORTED_V3:-false}"

# Reject a misspelled value up front rather than silently falling through to
# a default. ICEBERG_DV_SUPPORT in particular decides whether a v3 table's
# deletion vectors get rewritten at all, so a typo silently reading as
# "auto" (or, worse, ICEBERG_SKIP_UNSUPPORTED_V3="TRUE " reading as "fail")
# would change DR behaviour with nothing in the log to say so.
case "${ICEBERG_DV_SUPPORT,,}" in
  auto|true|yes|1|false|no|0) ;;
  *)
    log_error "ICEBERG_DV_SUPPORT must be one of: auto, true, false (got '${ICEBERG_DV_SUPPORT}')"
    exit 1
    ;;
esac
case "${ICEBERG_SKIP_UNSUPPORTED_V3,,}" in
  true|yes|1|false|no|0) ;;
  *)
    log_error "ICEBERG_SKIP_UNSUPPORTED_V3 must be one of: true, false (got '${ICEBERG_SKIP_UNSUPPORTED_V3}')"
    exit 1
    ;;
esac

if [[ -z "$SRC_METASTORE_URI" ]]; then
    log_error "SRC_METASTORE_URI (argument 6, e.g. thrift://host:9083) is required"
    exit 1
fi
if [[ -z "$DST_METASTORE_URI" ]]; then
    log_error "DST_METASTORE_URI (argument 7, e.g. thrift://host:9083) is required"
    exit 1
fi

if [[ -z "$INCLUDE_FILTERS" ]]; then
  log_error "INCLUDE_FILTERS (argument 1) is required."
  log_error "Example: \"sales_db:orders_.*,analytics:.*\""
  log_error "(a bare \"db\" with no \":\" means every table in that database)"
  exit 1
fi

# Positional argument 15 / the SEED_CHECKPOINT environment variable (default
# "false") sets the baseline; a bare --seed-checkpoint flag token anywhere on
# the command line (see the flag-scan loop below) can additionally turn it
# on. Either form is sufficient; passing both is harmless.
SEED_CHECKPOINT_ONLY=false
if [[ "${SEED_CHECKPOINT_ARG,,}" == "true" ]]; then
  SEED_CHECKPOINT_ONLY=true
fi
# Positional argument 12 (default "false") sets the baseline; a bare
# --rebuild-dst-table-from-source flag token anywhere on the command line
# (backward compatible with callers that stop at argument 11) can
# additionally turn it on. Either form is sufficient; passing both is
# harmless.
REBUILD_DST_TABLE_FROM_SOURCE=false
if [[ "${REBUILD_DST_TABLE_FROM_SOURCE_ARG,,}" == "true" ]]; then
  REBUILD_DST_TABLE_FROM_SOURCE=true
fi
# Scans SCRIPT_ARGV_RAW, not "$@": the flag tokens were deliberately removed
# from the positional stream up top (see SCRIPT_POSITIONAL_ARGV) so they can
# never be mistaken for LOG_DIR or any other position, which means the raw
# snapshot is now the only place they still appear.
for arg in "${SCRIPT_ARGV_RAW[@]+"${SCRIPT_ARGV_RAW[@]}"}"; do
  if [[ "$arg" == "--seed-checkpoint" ]]; then
    SEED_CHECKPOINT_ONLY=true
  fi
  if [[ "$arg" == "--rebuild-dst-table-from-source" ]]; then
    REBUILD_DST_TABLE_FROM_SOURCE=true
  fi
  # DEPRECATED ALIAS. This flag was originally named
  # --force-reseed-nonmatching; the name was changed because "reseed"
  # wrongly implied it only re-seeds a checkpoint (it rebuilds the whole
  # destination table), and "nonmatching" never said what was being
  # matched against what. Still accepted so callers already configured
  # with the old spelling -- Pulse Action configs in particular -- keep
  # working unchanged. Warned rather than silently accepted, so the log
  # says which spelling was used and existing configs can be migrated.
  if [[ "$arg" == "--force-reseed-nonmatching" ]]; then
    REBUILD_DST_TABLE_FROM_SOURCE=true
    log_warn "--force-reseed-nonmatching is a deprecated name for --rebuild-dst-table-from-source."
    log_warn "It still works exactly as before; update the caller to the new spelling when convenient."
  fi
done

# Validate mandatory parameters
if [[ -z "$SRC_NAMESERVICE" ]]; then
    log_error "SRC_NAMESERVICE (argument 2) is required"
    exit 1
fi
if [[ -z "$DST_NAMESERVICE" ]]; then
    log_error "DST_NAMESERVICE (argument 3) is required"
    exit 1
fi
if [[ -z "$SRC_JDBC_URL" ]]; then
    log_error "SRC_JDBC_URL (argument 4) is required"
    exit 1
fi
if [[ -z "$DST_JDBC_URL" ]]; then
    log_error "DST_JDBC_URL (argument 5) is required"
    exit 1
fi

########################################
# Kerberos detection (KRB5CCNAME). When more than one valid credential cache is
# present (the Pulse Actions scenario: multiple service tickets can coexist
# under /opt/pulse/actions/tmp, e.g. "hdfs-odp_phoenix@REALM" for a
# "hdfs"-prefixed SPARK_USER), this additionally matches a candidate
# cache's Default principal against SPARK_USER, so replication calls
# authenticate as the intended service identity rather than whichever
# cache happens to be newest.
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
    # cache whose principal matches SPARK_USER over just the newest valid one.
    local pulse_cache_dir="/opt/pulse/actions/tmp"
    if [[ ! -d "$pulse_cache_dir" ]] && [[ -f "/etc/default/hydra" ]]; then
        local pulse_home
        pulse_home=$(grep "^PULSE_HOME=" /etc/default/hydra 2>/dev/null | head -1 | sed -E 's/^PULSE_HOME=//' | sed -E 's/^["'\'']|["'\'']$//g' || echo "")
        if [[ -n "$pulse_home" ]]; then
            pulse_cache_dir="${pulse_home}/actions/tmp"
        fi
    fi
    if [[ -d "$pulse_cache_dir" ]]; then
        local best_cc="" fallback_cc="" cc cc_principal
        while IFS= read -r cc; do
            [[ -f "$cc" ]] || continue
            if KRB5CCNAME="$cc" klist -s 2>/dev/null; then
                cc_principal=$(KRB5CCNAME="$cc" klist 2>/dev/null | grep "Default principal:" | awk '{print $3}')
                # Exact match on the principal's primary component (the part
                # before "@"), not a glob prefix: "${SPARK_USER}"* would also
                # match an unrelated cache like "hdfs_backup@REALM" or
                # "hdfsadmin@REALM" when SPARK_USER="hdfs", picking the wrong
                # service identity out of Pulse Actions' shared cache dir.
                if [[ -n "$cc_principal" && "${cc_principal%%@*}" == "${SPARK_USER}" ]]; then
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

if detect_kerberos_enabled; then
    KERBEROS_ENABLED="yes"
else
    KERBEROS_ENABLED="no"
fi

# KERBEROS_PRINCIPAL: the principal of the ticket every hadoop/beeline/spark
# call of this run authenticates with (empty without Kerberos). Shown in the
# startup banner, since under Kerberos HDFS_USER/SPARK_USER do not decide
# the identity -- the ticket does.
KERBEROS_PRINCIPAL=""
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
    KERBEROS_PRINCIPAL=$(klist 2>/dev/null | awk '/Default principal:/ {print $3; exit}') || KERBEROS_PRINCIPAL=""
fi

# SPARK_STAGING_USER (env var, default: derived) - the HDFS user whose home
# directory holds the Spark staging directory on the SAME-NAMESERVICE
# COLLISION path (spark.yarn.stagingDir=hdfs://<active NN>/user/<this>/
# .sparkStaging, see build_collision_hop_a_ha_args). It has to be the user
# the job actually runs as:
#   - without Kerberos, that is SPARK_USER (the sudo target);
#   - with Kerberos, it is the short name Hadoop maps the ticket's principal
#     to (auth_to_local), which `hadoop kerbname` reports. SPARK_USER is
#     only the fallback there, used if that mapping cannot be obtained.
# Resolved only when the collision path is in use; set it explicitly to
# skip the lookup.
SPARK_STAGING_USER="${SPARK_STAGING_USER:-}"
if [[ -z "$SPARK_STAGING_USER" ]]; then
    SPARK_STAGING_USER="$SPARK_USER"
    if [[ "$SAME_NAMESERVICE_COLLISION" == "true" && -n "$KERBEROS_PRINCIPAL" ]]; then
        _kerb_short_name=$(hadoop kerbname "$KERBEROS_PRINCIPAL" 2>/dev/null | awk '/ to /{print $NF; exit}') || _kerb_short_name=""
        if [[ -n "$_kerb_short_name" ]]; then
            SPARK_STAGING_USER="$_kerb_short_name"
        else
            log_warn "Could not map Kerberos principal '${KERBEROS_PRINCIPAL}' to a Hadoop user name ('hadoop kerbname');"
            log_warn "using SPARK_USER ('${SPARK_USER}') for the Spark staging directory. Set SPARK_STAGING_USER if that is not the job's user."
        fi
        unset _kerb_short_name
    fi
fi

########################################
# Beeline auth in non-Kerberos mode. When Kerberos is NOT enabled, beeline needs an explicit -n <user>, or
# HiveServer2 authenticates the connection as "anonymous". Two sub-modes:
#   HIVE_LDAP_ENABLED=false (default) - HS2 uses pass-through/NONE auth, so
#     the password is not actually validated. Both -n and -p get HIVE_USER,
#     purely to satisfy beeline's command-line syntax.
#   HIVE_LDAP_ENABLED=true - HS2 is backed by real LDAP auth. HIVE_PASSWORD
#     must be the real credential for HIVE_USER; the script fails fast if
#     it is missing.
# When Kerberos IS enabled, none of this applies -- beeline authenticates
# via the active ticket and no -n/-p is passed at all.
########################################
HIVE_USER="${HIVE_USER:-hdfs}"
HIVE_LDAP_ENABLED="${HIVE_LDAP_ENABLED:-false}"
HIVE_PASSWORD="${HIVE_PASSWORD:-}"

BEELINE_AUTH_ARGS=()
if [[ "$KERBEROS_ENABLED" == "no" ]]; then
  if [[ "${HIVE_LDAP_ENABLED,,}" == "true" ]]; then
    if [[ -z "$HIVE_PASSWORD" ]]; then
      log_error "HIVE_LDAP_ENABLED=true but HIVE_PASSWORD is not set."
      log_error "Set HIVE_PASSWORD to the real LDAP credential for HIVE_USER='${HIVE_USER}'."
      exit 1
    fi
    BEELINE_AUTH_ARGS=(-n "$HIVE_USER" -p "$HIVE_PASSWORD")
    log_info "Beeline auth: LDAP mode, user=${HIVE_USER}"
  else
    BEELINE_AUTH_ARGS=(-n "$HIVE_USER" -p "$HIVE_USER")
    log_info "Beeline auth: non-LDAP mode, user=${HIVE_USER} (password=username)"
  fi
fi

########################################
# run_as_hdfs / run_as_spark_user: identity-switching wrappers. Named
# run_as_spark_user because it wraps spark-sql/spark-shell -- STEP 5 is the
# Spark copier, see the header block.
#   Kerberos enabled  -> run as the current user, preserving the active
#                        ticket.
#   Kerberos disabled -> sudo -u "$HDFS_USER" for hadoop fs/hdfs, or
#                        sudo -E -u "$SPARK_USER" for spark-sql/spark-shell
#                        (-E preserves the environment, e.g.
#                        HADOOP_CLIENT_OPTS).
# HDFS_USER/SPARK_USER must be HDFS-authorized users (superuser, or
# granted the appropriate permissions on both clusters) when Kerberos is
# disabled.
########################################
run_as_hdfs() {
  if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
    "$@"
  else
    sudo -u "$HDFS_USER" "$@"
  fi
}

run_as_spark_user() {
  if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
    "$@"
  else
    sudo -E -u "$SPARK_USER" "$@"
  fi
}

TOTAL_STEPS=8

########################################
# Logging setup. One shared log file covers the whole run, across every
# table replicated by this invocation.
########################################

# run_log_db_slug: the database part of the run-log filename, derived from
# INCLUDE_FILTERS (validated non-empty above, so this always yields at least
# one name). Multiple databases are joined with "-"; past the first 3 the
# remainder collapses into "+Nmore" so the filename stays bounded no matter
# how many filter rows a run is given. Every name is sanitised to
# [A-Za-z0-9_] because a database name arrives here as free-form text and
# lands in a path.
# split_filter_rows <spec>: split an INCLUDE_FILTERS spec into its rows,
# into the global array FILTER_ROWS. Rows are separated by commas, but a
# comma INSIDE brackets belongs to the table regex, not to the row list --
# "db:tbl_[0-9]{1,3}" is one row whose regex has a {1,3} quantifier, and
# "db:x[a,b]" is one row with a character class. So a comma only ends a
# row at bracket depth 0; a backslash-escaped comma ("\,") never does.
# If the brackets do not balance, depth can no longer be trusted to find
# the row boundaries, so the spec is split on every comma instead (the
# plain behaviour) and the row with the bad regex is reported as such by
# parse_filter_spec.
FILTER_ROWS=()
split_filter_rows() {
  local spec="$1"
  FILTER_ROWS=()
  local -i depth=0 i n=${#spec}
  local ch cur="" esc=false
  for (( i = 0; i < n; i++ )); do
    ch="${spec:i:1}"
    if [[ "$esc" == "true" ]]; then
      cur+="$ch"; esc=false
      continue
    fi
    case "$ch" in
      \\) cur+="$ch"; esc=true ;;
      '['|'('|'{') depth+=1; cur+="$ch" ;;
      ']'|')'|'}') if (( depth > 0 )); then depth+=-1; fi; cur+="$ch" ;;
      ,) if (( depth == 0 )); then FILTER_ROWS+=("$cur"); cur=""; else cur+="$ch"; fi ;;
      *) cur+="$ch" ;;
    esac
  done
  FILTER_ROWS+=("$cur")
  if (( depth != 0 )); then
    IFS=',' read -ra FILTER_ROWS <<< "$spec"
  fi
  return 0
}

run_log_db_slug() {
  local -a dbs=()
  local row db d seen
  split_filter_rows "$INCLUDE_FILTERS"
  local _rows=("${FILTER_ROWS[@]+"${FILTER_ROWS[@]}"}")
  for row in "${_rows[@]+"${_rows[@]}"}"; do
    row="${row#"${row%%[![:space:]]*}"}"
    db="${row%%:*}"
    db="${db,,}"
    db="${db//[^A-Za-z0-9_]/_}"
    [[ -z "$db" ]] && continue
    # Multiple rows for the same database are allowed (their matches are
    # unioned), so de-duplicate rather than repeating the name.
    seen=""
    for d in "${dbs[@]}"; do
      [[ "$d" == "$db" ]] && { seen="yes"; break; }
    done
    [[ -n "$seen" ]] || dbs+=("$db")
  done
  if (( ${#dbs[@]} == 0 )); then
    printf 'unknown_db'
  elif (( ${#dbs[@]} <= 3 )); then
    printf '%s' "$(IFS='-'; echo "${dbs[*]}")"
  else
    printf '%s-%s-%s+%dmore' "${dbs[0]}" "${dbs[1]}" "${dbs[2]}" "$(( ${#dbs[@]} - 3 ))"
  fi
}

mkdir -p "$LOG_DIR"
# The name ends in this process's PID: a timestamp to the second is not
# unique when two invocations covering the same database(s) start in the
# same second (two scheduled actions with different table filters), and
# both would then append to one file, interleaved.
RUN_LOG_FILE="$LOG_DIR/iceberg_bdr_run_$(run_log_db_slug)_$(date +%Y%m%d_%H%M%S)_$$.log"
# Wall-clock start of the whole run, for the elapsed total in the summary.
RUN_START_EPOCH=$(date +%s)

# Everything logged before this point went to the console only; write it
# into the log file now, ahead of the banner, and stop buffering (see
# EARLY-LINE BUFFER next to the logging helpers).
if [[ -n "$_EARLY_LOG_BUFFER" ]]; then
  printf '%s' "$_EARLY_LOG_BUFFER" >> "$RUN_LOG_FILE"
fi
_EARLY_LOG_BUFFERING=false
_EARLY_LOG_BUFFER=""

exec > >(tee -a "$RUN_LOG_FILE") 2>&1

log_line "$SEP"
log_line " Iceberg Table Replication Script Started"
log_line "$SEP"
log_line "Timestamp : $(date)"
log_line "Source NS : $SRC_NAMESERVICE"
log_line "Dest NS   : $DST_NAMESERVICE"
log_line "Log File  : $RUN_LOG_FILE"
log_line "Kerberos  : ${KERBEROS_ENABLED^^}"
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
  log_line "Principal : ${KERBEROS_PRINCIPAL:-<could not be read from klist>}"
  log_line "Exec Mode : current user/ticket (Kerberos)"
else
  log_line "Exec Mode : sudo (${HDFS_USER}/${SPARK_USER})"
fi
# Dynamic-allocation status appended to the Spark Mode line so a log reader
# doesn't have to cross-reference two separate env vars (SPARK_REWRITE_
# DYNAMIC_ALLOCATION / SPARK_COPIER_DYNAMIC_ALLOCATION) to know whether
# either of this run's two Spark jobs will actually scale out. Only
# meaningful under --master yarn -- local[*] has no executors to allocate
# dynamically (see build_executor_sizing_args), so it is omitted there
# rather than printed as a misleading "dynamic: true/false".
_DYNAMIC_ALLOC_SUFFIX=""
if [[ "$SPARK_MASTER" == "yarn" ]]; then
  _rewrite_dyn="off"; case "${SPARK_REWRITE_DYNAMIC_ALLOCATION,,}" in true|yes|1) _rewrite_dyn="on";; esac
  _copier_dyn="off"; case "${SPARK_COPIER_DYNAMIC_ALLOCATION,,}" in true|yes|1) _copier_dyn="on";; esac
  _DYNAMIC_ALLOC_SUFFIX=" [dynamic allocation: rewrite=${_rewrite_dyn}, copier=${_copier_dyn}]"
  unset _rewrite_dyn _copier_dyn
fi
log_line "Spark Mode: ${SPARK_RUN_MODE} (--master ${SPARK_MASTER})${_DYNAMIC_ALLOC_SUFFIX}"
unset _DYNAMIC_ALLOC_SUFFIX
# STEP 5's copy engine (COPY_ENGINE=spark|distcp). Surfaced in the startup
# banner so a log read later shows which engine (and, for spark, the task
# count) without having to infer it from the [5d] lines.
if [[ "$COPY_ENGINE" == "distcp" ]]; then
  log_line "Copy Mode : distcp (one 'hadoop distcp -f' job per touched target directory)"
elif [[ "$SPARK_COPY_PARTITIONS" -gt 0 ]]; then
  log_line "Copy Mode : spark (ONE Spark job for the whole file list, ${SPARK_COPY_PARTITIONS} tasks)"
else
  log_line "Copy Mode : spark (ONE Spark job for the whole file list, auto task count)"
fi
log_line "Checkpoint: HDFS, mirrored on both clusters under ${CHECKPOINT_DIR}"
log_line ""

# Spark-copier mode under a local master is correct but single-host: the whole
# point of the default (yarn) mode is a distributed job, and local[*] gives
# that up entirely, moving every file through this one host. Worth saying out
# loud at startup rather than leaving it to be discovered from the wall time.
if [[ "$SPARK_MASTER" == local* ]]; then
  log_warn "Spark copier with --master ${SPARK_MASTER}: the copy is still correct, but every file"
  log_warn "moves through THIS host rather than across the cluster. Set SPARK_RUN_MODE=yarn to scale it out."
  log_line ""
fi

# Under YARN, say so once if nothing provides Spark's jars from HDFS: each
# Spark job then uploads them itself before it starts. Only said when this
# host's spark-defaults.conf can actually be read and sets neither
# spark.yarn.archive nor spark.yarn.jars, and neither this script's own
# setting nor the extra-args escape hatches supply one.
if [[ "$SPARK_MASTER" == "yarn" && -z "$SPARK_YARN_ARCHIVE" \
      && "${SPARK_REWRITE_EXTRA_ARGS} ${SPARK_COPIER_EXTRA_ARGS}" != *spark.yarn.archive* \
      && "${SPARK_REWRITE_EXTRA_ARGS} ${SPARK_COPIER_EXTRA_ARGS}" != *spark.yarn.jars* ]]; then
  _spark_defaults_conf=""
  if [[ -n "${SPARK_CONF_DIR:-}" ]]; then
    _spark_defaults_conf="${SPARK_CONF_DIR}/spark-defaults.conf"
  elif [[ -n "${SPARK_HOME:-}" ]]; then
    _spark_defaults_conf="${SPARK_HOME}/conf/spark-defaults.conf"
  fi
  if [[ -n "$_spark_defaults_conf" && -r "$_spark_defaults_conf" ]] \
     && ! grep -qE '^[[:space:]]*spark\.yarn\.(archive|jars)[[:space:]=]' "$_spark_defaults_conf"; then
    log_info "Neither spark.yarn.archive nor spark.yarn.jars is set (${_spark_defaults_conf}): every Spark job of this run"
    log_info "uploads Spark's jars to HDFS before it starts, three jobs per replicated table. Building the archive once and"
    log_info "setting SPARK_YARN_ARCHIVE (or SPARK_TUNING's yarn_archive key) removes that -- see SPARK_YARN_ARCHIVE in this script's header."
    log_line ""
  fi
  unset _spark_defaults_conf
fi

########################################
# Echo every positional argument, with its EFFECTIVE value -- i.e. what the
# run actually used, after defaults were applied -- so a log read weeks
# later (or handed over by a customer) is self-contained: what this run was
# told to do is answerable from the log itself, with no need to hunt down
# the Pulse Action config or cron entry that launched it. Optional
# arguments the caller did not supply are marked "(default)", which is the
# distinction that actually matters when diagnosing "why did it write
# there / connect as that user".
########################################

# redact_secrets: blank out any password embedded in a JDBC URL before it
# reaches the log. HiveServer2 credentials normally arrive via the
# HIVE_PASSWORD env var (never echoed here), but a JDBC URL is free-form
# and CAN carry "password=" / "pwd=" inline -- and this banner is the one
# place that prints those URLs unconditionally on every run, rather than
# only in an error path. Values are delimited by ";" or "&" in a JDBC URL,
# so the match stops there and leaves the rest of the URL readable.
redact_secrets() {
  sed -E 's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Ww][Dd])=[^;&]*/\1=***REDACTED***/g' <<< "$1"
}

# log_positional_arg: one "<n>  <NAME> : <value>" row. Whether the caller
# actually supplied argument <n> is read from SCRIPT_ARGV (the script's own
# saved argument vector) rather than compared against a hardcoded default
# string -- so an argument explicitly passed a value that happens to equal
# its default is still correctly reported as supplied, not as defaulted.
# SCRIPT_ARGV is 0-indexed, hence idx-1.
log_positional_arg() {
  local idx="$1" name="$2" value="$3"
  # $4, optional: the note to show when the argument was NOT passed
  # positionally. Defaults to "(default)"; a caller whose value can also
  # come from somewhere else (an environment variable) passes its own.
  local not_passed_note="${4:-(default)}"
  local raw="${SCRIPT_ARGV[$((idx - 1))]:-}" suffix=""
  [[ -z "$raw" ]] && suffix="  ${not_passed_note}"
  log_line "$(printf '  %2s  %-29s : %s%s' "$idx" "$name" "${value:-<unset>}" "$suffix")"
}

log_line "Positional arguments (${#SCRIPT_ARGV[@]} passed, effective values shown):"
log_positional_arg 1  "INCLUDE_FILTERS"          "$INCLUDE_FILTERS"
log_positional_arg 2  "SRC_NAMESERVICE"          "$SRC_NAMESERVICE"
log_positional_arg 3  "DST_NAMESERVICE"          "$DST_NAMESERVICE"
log_positional_arg 4  "SRC_JDBC_URL"             "$(redact_secrets "$SRC_JDBC_URL")"
log_positional_arg 5  "DST_JDBC_URL"             "$(redact_secrets "$DST_JDBC_URL")"
log_positional_arg 6  "SRC_METASTORE_URI"        "$SRC_METASTORE_URI"
log_positional_arg 7  "DST_METASTORE_URI"        "$DST_METASTORE_URI"
log_positional_arg 8  "LOG_DIR"                  "$LOG_DIR"
log_positional_arg 9  "CHECKPOINT_DIR"           "$CHECKPOINT_DIR"
log_positional_arg 10 "HDFS_USER"                "$HDFS_USER"
log_positional_arg 11 "SPARK_USER"               "$SPARK_USER"
log_positional_arg 12 "REBUILD_DST_TABLE_FROM_SOURCE" "$REBUILD_DST_TABLE_FROM_SOURCE_ARG"
log_positional_arg 13 "SPARK_TUNING"              "$SPARK_TUNING_ARG"
log_positional_arg 14 "SPARK_EXTRA_CONF"          "$SPARK_EXTRA_CONF_ARG"
if [[ -n "${SEED_CHECKPOINT:-}" ]]; then
  log_positional_arg 15 "SEED_CHECKPOINT"           "$SEED_CHECKPOINT_ARG" "(from the SEED_CHECKPOINT environment variable)"
else
  log_positional_arg 15 "SEED_CHECKPOINT"           "$SEED_CHECKPOINT_ARG"
fi
log_line ""

# The two mode flags, printed separately because either can also be set by
# a bare flag token anywhere in "$@" (not just positionally), so the
# argument rows above do not always tell the whole story. These change what
# the run DOES, so their effective values belong in the header.
log_line "Mode flags:"
log_line "$(printf '      %-29s : %s' 'SEED_CHECKPOINT_ONLY' "$SEED_CHECKPOINT_ONLY")"
log_line "$(printf '      %-29s : %s' 'REBUILD_DST_TABLE_FROM_SOURCE' "$REBUILD_DST_TABLE_FROM_SOURCE")"
log_line "$(printf '      %-29s : %s' 'COPY_ENGINE' "$COPY_ENGINE")"
log_line "$(printf '      %-29s : %s' 'PARALLEL_TABLES' "$PARALLEL_TABLES")"
log_line ""

# Seed-only mode replicates nothing, which is easy to miss in a scheduled
# action whose argument was set for a one-off seeding run and never set
# back. Said once, up front, on every run that is in this mode.
if [[ "$SEED_CHECKPOINT_ONLY" == "true" ]]; then
  log_warn "SEED-ONLY MODE (SEED_CHECKPOINT=true / --seed-checkpoint): this run only writes checkpoints for"
  log_warn "tables that already exist on the destination. NO data is replicated and no destination table is"
  log_warn "changed. Set SEED_CHECKPOINT back to 'false' (argument 15) for normal replication runs."
  log_line ""
fi

########################################
# Helpers
########################################

# Pretty-print a command array to the console, one logical flag per line, so
# long commands with many -D/--conf property pairs (the HA nameservice arg
# sets can be 7+ flags per nameservice) stay readable instead of wrapping
# into one unreadable wall of text. Keeps a flag token together with its
# following value on one line for recognized two-token flags (-D, --conf,
# --jars, --master, --deploy-mode, -f, --executor-cores, --executor-memory,
# --driver-memory, --driver-cores, --num-executors, --name, -i), matching
# how a human would normally format the equivalent command by hand. The
# executor/driver-sizing and --name/-i flags are exactly the ones every
# spark-sql/spark-shell command this script builds also uses (see
# build_executor_sizing_args and run_spark_sql/run_spark_copier) -- without
# them here, every single one of those commands split its sizing flags
# across twice as many lines as necessary for no benefit.
print_cmd_pretty() {
  _print_cmd_pretty_raw "$@" | _tag_lines
}
_print_cmd_pretty_raw() {
  local -a cmd=("$@")
  local -i i=0
  local -i n=${#cmd[@]}
  printf '\n  %s' "${cmd[0]}"
  i=1
  while (( i < n )); do
    case "${cmd[$i]}" in
      -D|--conf|--jars|--master|--deploy-mode|-f|--executor-cores|--executor-memory|--driver-memory|--driver-cores|--num-executors|--name|-i)
        printf ' \\\n    %s %s' "${cmd[$i]}" "${cmd[$((i+1))]}"
        i=$((i+2))
        ;;
      *)
        printf ' \\\n    %s' "${cmd[$i]}"
        i=$((i+1))
        ;;
    esac
  done
  printf '\n\n'
}

# filter_beeline_noise: strip the JVM/log4j startup chatter that beeline
# prints on stderr (merged into stdout by the callers below, since the real
# "Error: ..." line beeline emits on a failed statement is ALSO on stderr --
# splitting the streams would just trade one lost signal for another). Two
# distinct logging frameworks' banners are filtered, since either can appear
# depending on the beeline build:
#   - Old Hive-CLI-style dated lines: "26/09/16 22:25:26 INFO ...".
#   - log4j2's ISO-8601-prefixed lines: "2026-09-16T16:56:24.713192Z main
#     WARN/INFO ...", PLUS its two un-timestamped continuation lines for the
#     "package scanning is deprecated" warning specifically (that warning's
#     wrapped text has no per-line timestamp of its own, so the timestamp
#     pattern alone does not catch it).
# Matched by CONTENT, not by only-known-good-lines-survive: an unrecognized
# future banner line would still pass through untouched here, which is the
# safe direction for a filter whose job is "hide known noise," not "hide
# everything not on an allowlist."
filter_beeline_noise() {
  grep -v "^[0-9]\{2\}/[0-9]\{2\}/[0-9]\{2\}.*INFO" \
    | grep -v "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}:[0-9]\{2\}:[0-9]\{2\}" \
    | grep -v "Please remove the .packages. attribute" \
    | grep -v "logging.apache.org/log4j/2.x/faq.html#package-scanning" \
    | grep -v "^[[:space:]]*$" \
    || true
}

# Run a beeline query and fail the script if the connection/query itself
# errors out, instead of silently returning empty output. Used wherever an
# empty result must be trusted as "no such row" rather than "couldn't check".
#
# A thin wrapper around run_beeline_query_soft (defined below) -- confirmed
# exactly one call site file-wide (list_tables_in_dbs), so this is low
# risk. One small, accepted behavior difference from the previous
# standalone implementation: on failure, this now logs soft's already
# INFO/blank-line-FILTERED output instead of the fully raw beeline output.
# Those filters only ever strip JDBC connection-banner/JVM-startup noise and
# empty lines, never actual error/stack-trace text, so no diagnostic signal
# is lost.
#
# THE HEADLINE [ERROR] LINE NAMES THE REAL CAUSE, not just an exit code.
# Before this, a failure here logged only "beeline query failed against
# <url> (exit 1):" on the ERROR line, with the actual reason (e.g.
# "Database does not exist: <db>") buried several lines down, past a wall of
# beeline's own JVM/log4j startup banner -- easy to miss, and useless for
# anyone grepping the log for '[ERROR]' lines alone. beeline's own failure
# line always starts with "Error: " (per HiveServer2's SQLException
# rendering, e.g. "Error: Error while compiling statement: FAILED:
# SemanticException [Error 10072]: Database does not exist: <db>
# (state=42000,code=10072)"), so that line is pulled out and put directly on
# the ERROR line; the full (noise-filtered) output is still logged right
# after it for anyone who needs the surrounding detail (state/error codes,
# multiple failed statements, etc.).
run_beeline_query_strict() {
  local jdbc_url="$1"
  local out rc=0
  out=$(run_beeline_query_soft "$@") || rc=$?
  if [[ $rc -ne 0 ]]; then
    report_beeline_failure "${jdbc_url}" "${rc}" "${out}"
    exit 1
  fi
  echo "${out}"
}

# report_beeline_failure <jdbc_url> <rc> <output>: the [ERROR] headline plus
# the full (redacted) output for a failed beeline query. Everything goes to
# stderr, so it is safe to call from a function whose stdout is captured.
report_beeline_failure() {
  local jdbc_url="$1" rc="$2" out="$3"
  if [[ "$rc" -ne 0 ]]; then
    local reason
    # `|| true`: no "Error: " line at all is an expected case (handled just
    # below), and under `set -e` + pipefail a grep that matches nothing
    # would otherwise end the script right here, before anything is logged.
    reason=$(echo "${out}" | grep -E '^Error: ' | tail -n 1) || true
    # jdbc_url and beeline's own output ("Connecting to jdbc:hive2://...")
    # can both carry an inline password, so both go through redact_secrets.
    local jdbc_url_redacted
    jdbc_url_redacted=$(redact_secrets "${jdbc_url}")
    if [[ -n "$reason" ]]; then
      log_error "beeline query failed against ${jdbc_url_redacted} (exit ${rc}): ${reason#Error: }"
    else
      log_error "beeline query failed against ${jdbc_url_redacted} (exit ${rc}); no 'Error: ...' line was found in its"
      log_error "output -- full output follows for diagnosis:"
    fi
    # >&2: this function's stdout is captured by its caller as the query
    # result, and the script exits right after -- written to stdout, this
    # detail would be swallowed into that capture and never be seen.
    log_info "$(redact_secrets "${out}")" >&2
  fi
  return 0
}

# Same as run_beeline_query_strict but returns non-zero on failure instead of
# exiting the whole script. Used inside the per-table loop so one table's
# beeline failure doesn't abort every other table in the run.
run_beeline_query_soft() {
  local jdbc_url="$1"
  local query="$2"
  local out rc
  out=$(beeline -u "${jdbc_url}" \
    "${BEELINE_AUTH_ARGS[@]}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    -e "${query}" 2>&1)
  rc=$?
  echo "${out}" | filter_beeline_noise
  return "$rc"
}

# run_beeline_statements_soft <jdbc_url> <statements>...: same output shape
# and soft failure handling as run_beeline_query_soft, but every argument
# after the URL is handed to beeline as its own -e, all on one connection.
# Used for batches that cover many tables: beeline stops a single -e at its
# first failing statement, so giving each table its own -e keeps one
# table's failure from cutting off the tables that follow it in the batch.
# The exit status is non-zero if any -e failed; the output still holds
# everything the successful ones returned, and the caller decides how much
# of it to trust (see _prefetch_src_batch).
run_beeline_statements_soft() {
  local jdbc_url="$1"
  shift
  local -a e_args=()
  local stmt
  for stmt in "$@"; do
    e_args+=(-e "${stmt}")
  done
  local out rc
  out=$(beeline -u "${jdbc_url}" \
    "${BEELINE_AUTH_ARGS[@]}" \
    --silent=true \
    --showHeader=false \
    --outputformat=tsv2 \
    "${e_args[@]}" 2>&1)
  rc=$?
  echo "${out}" | filter_beeline_noise
  return "$rc"
}

# MARKER ROWS. A batched beeline call returns the rows of all its statements
# as one headerless tsv2 stream, so each real statement is preceded by one
# that returns a single known row naming what follows (a database, or a
# table). BEELINE_MARKER_STYLE picks how that row is produced:
#   select -- SELECT '<marker>';  a query, compiled and run like any other.
#   set    -- set hivevar:<var>=<marker>; set hivevar:<var>;  HiveServer2
#             answers a "set <name>;" itself with the row "<name>=<value>",
#             without compiling a query.
# beeline_marker_stmt <out_var> <marker> stores the statement(s) in the named
# variable (printf -v rather than stdout, so building a batch for thousands
# of tables forks nothing). BEELINE_MARKER_ROW_PREFIX is what the set style
# puts in front of the marker in its result row; the parsers strip it, so
# they see the same marker text in both styles.
BEELINE_MARKER_VAR="iceberg_repl_marker"
BEELINE_MARKER_ROW_PREFIX="hivevar:${BEELINE_MARKER_VAR}="
beeline_marker_stmt() {
  case "${BEELINE_MARKER_STYLE,,}" in
    set) printf -v "$1" 'set hivevar:%s=%s; set hivevar:%s;' "${BEELINE_MARKER_VAR}" "$2" "${BEELINE_MARKER_VAR}" ;;
    *)   printf -v "$1" "SELECT '%s';" "$2" ;;
  esac
}

# Run a beeline statement (not a query -- no tsv2 parsing, used for
# ALTER TABLE ... SET TBLPROPERTIES). Same auth args as the query helpers.
# Unlike the query helpers above, this streams straight to the terminal
# (its output is never captured by a caller), so its beeline connection/JVM
# banner noise is piped through indent_output here to keep it visually
# offset from this script's own [INFO]/[WARN] lines. `set -o pipefail`
# means the pipeline's exit status is beeline's own, not sed's, so callers'
# `|| { ... }` failure handling still sees a real non-zero exit on failure.
run_beeline_statement() {
  local jdbc_url="$1"
  local statement="$2"
  local out rc=0
  out=$(beeline -u "${jdbc_url}" "${BEELINE_AUTH_ARGS[@]}" -e "${statement}" 2>&1) || rc=$?
  # QUIET_BEELINE_STATEMENTS (see its own declaration near the top of this
  # script): a failure ALWAYS prints, regardless of the setting -- that is
  # exactly when the JVM/log4j banner's detail (state/error codes, the
  # real Hive-side error line) is needed. Only the success path's pure
  # noise is ever suppressed.
  if [[ $rc -ne 0 ]]; then
    redact_secrets "${out}" | indent_output
  else
    case "${QUIET_BEELINE_STATEMENTS,,}" in
      true|yes|1) ;;
      *) redact_secrets "${out}" | indent_output ;;
    esac
  fi
  return "$rc"
}

# run_beeline_statement_tolerate_non_native: same as run_beeline_statement,
# except one specific Hive failure is treated as SUCCESS rather than an
# error: "ALTER TABLE can only be used for [ADDPROPS, DROPPROPS, ADDCOLS,
# EXECUTE] to a non-native table" (Hive error 10134).
#
# WHY THIS IS SAFE TO SWALLOW. apply_hive_engine_fixups()'s FILEFORMAT/
# storage_handler ALTERs exist because register_table (Iceberg's own
# catalog call, bypassing Hive's own CREATE TABLE path) used to leave the
# Metastore row without them -- Hive would otherwise see a plain/native
# table with no idea how to read it. On a Hive build with NATIVE Iceberg
# support (confirmed here against Hive 4.1.0.3.3.6.5-1012), HiveCatalog's
# own commit already marks the table Iceberg-native as part of
# register_table itself, before this script's fixup ALTER ever runs --
# which is EXACTLY the end state the fixup exists to reach. Hive then
# correctly refuses a FILEFORMAT change against what it already considers
# a non-native (custom storage handler) table, with this precise error
# text. Any OTHER beeline failure -- a real connectivity problem, a typo,
# a permissions issue -- still fails exactly as before; only this one
# documented, specific signature is treated as "already correct."
run_beeline_statement_tolerate_non_native() {
  local jdbc_url="$1"
  local statement="$2"
  local out rc=0
  out=$(beeline -u "${jdbc_url}" "${BEELINE_AUTH_ARGS[@]}" -e "${statement}" 2>&1) || rc=$?
  if [[ $rc -ne 0 ]]; then
    # The tolerated non-native signature is an EXPECTED outcome on a Hive
    # build with native Iceberg support (see this function's own header
    # comment) -- on a fleet running such a build, every single bootstrap
    # hits it, every time, for both fixup ALTERs. Dumping beeline's full
    # JVM/log4j/ZooKeeper connection banner for an outcome that is already
    # known-fine is exactly the kind of noise QUIET_BEELINE_STATEMENTS
    # exists to suppress elsewhere -- so this checks for the tolerated
    # signature FIRST and, when found, prints one quiet line instead of
    # the full output. Any OTHER failure (real connectivity problem, typo,
    # permissions issue) still dumps the full output unconditionally, same
    # as before -- that is genuinely diagnostic and QUIET_BEELINE_STATEMENTS
    # never suppresses a real failure.
    if echo "${out}" | grep -qE '\[Error 10134\]|ALTER TABLE can only be used for \[ADDPROPS, DROPPROPS, ADDCOLS, EXECUTE\] to a non-native table'; then
      log_warn "Hive already treats this table as native Iceberg (its own ALTER TABLE dispatch refused this"
      log_warn "fixup as inapplicable to a non-native table) -- treating as already correct, not a failure."
      return 0
    fi
    redact_secrets "${out}" | indent_output
    return "$rc"
  fi
  case "${QUIET_BEELINE_STATEMENTS,,}" in
    true|yes|1) ;;
    *) redact_secrets "${out}" | indent_output ;;
  esac
  return 0
}

# CHECKPOINT STORAGE: HDFS ONLY, MIRRORED ONTO BOTH CLUSTERS.
#
# See "CHECKPOINT ON HDFS" in this script's header for the full rationale.
# Every write and every read goes through checkpoint_write()/checkpoint_read()
# below, which always touch both SRC's and DST's copy under CHECKPOINT_DIR --
# there is no local-disk mode and no toggle for it.

# write_checkpoint_hdfs_one: write $value to one HDFS checkpoint path, in a
# single `hadoop fs -put -f` launch. -put writes the content to
# "<path>._COPYING_" and then renames that onto <path>, removing an existing
# <path> first when -f is given, so a reader can never observe a
# partially-written checkpoint. Between that removal and the rename the path
# briefly does not exist; a reader hitting that exact window falls through
# to "no checkpoint found" (see STEP 3) -- the same safe direction this
# script already defaults to whenever a checkpoint is genuinely absent --
# never to corrupt/partial content.
#
# The parent directory normally exists: CHECKPOINT_DIR is created on both
# clusters at startup. If the -put fails, the directory is (re)created and
# the -put is tried once more, which covers a directory removed mid-run;
# any other cause fails the second attempt too, and its error is the one
# that reaches the log.
write_checkpoint_hdfs_one() {
  local hdfs_path="$1"
  local value="$2"
  local hdfs_dir="${hdfs_path%/*}"
  local local_tmp
  local_tmp=$(mktemp) || return 1
  printf '%s\n' "${value}" > "${local_tmp}"
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -put -f "${local_tmp}" "${hdfs_path}" 2>/dev/null \
    || { run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir -p "${hdfs_dir}" \
         && run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -put -f "${local_tmp}" "${hdfs_path}"; }
  local rc=$?
  rm -f "${local_tmp}"
  return $rc
}

# checkpoint_write: the ONE call site every checkpoint write in this script
# goes through (--seed-checkpoint, auto-seed, and the normal end-of-run
# advance). Writes both SRC's and DST's copy, so either cluster's HDFS can
# serve the next read regardless of which host runs it. Both failing is
# fatal (nothing would durably record this run's progress at all); one
# failing is a [WARN] (the surviving copy still serves reads).
#
# checkpoint_hdfs_path_for() builds each side's path from its nameservice
# name alone -- when SRC_NAMESERVICE == DST_NAMESERVICE (SAME-NAMESERVICE
# COLLISION mode), both sides therefore resolve to the IDENTICAL HDFS path.
# Writing it twice in parallel is not merely redundant: two concurrent
# `write_checkpoint_hdfs_one` calls would each write the same
# "<path>._COPYING_" temporary and rename it onto the same file, and one
# can remove or rename it out from under the other, producing a real I/O
# error on BOTH sides even though the replication that led up to this
# write succeeded. Detected up front and handled with a single write
# instead.
#
# Otherwise, the two sides' writes run as PARALLEL background jobs (each
# its own `write_checkpoint_hdfs_one`, one `hadoop fs` launch) rather than
# one after the other, since this function unconditionally writes BOTH
# sides on every call. Each side's outcome is captured via a small result
# file (the same "background job can't set a variable the parent shell
# sees" pattern PARALLEL_TABLES/run_spark_copier already use elsewhere in
# this script), read back after both `wait`.
checkpoint_write() {
  local hive_db="$1" table_name="$2" src_ns="$3" dst_ns="$4" value="$5"

  local src_path dst_path
  src_path=$(checkpoint_hdfs_path_for "$src_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  dst_path=$(checkpoint_hdfs_path_for "$dst_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")

  if [[ "$src_path" == "$dst_path" ]]; then
    if write_checkpoint_hdfs_one "$src_path" "$value"; then
      log_info "Checkpoint written to HDFS: ${src_path}"
      return 0
    fi
    log_error "Could not write the checkpoint to HDFS for ${hive_db}.${table_name} at ${src_path}."
    log_error "This run's progress is not durably recorded anywhere. Check HDFS_USER's (or the current"
    log_error "Kerberos ticket's) permissions on CHECKPOINT_DIR (${CHECKPOINT_DIR})."
    return 1
  fi

  local -A _ckw_result_file=()
  local side path
  for side in SRC DST; do
    if [[ "$side" == "SRC" ]]; then path="$src_path"; else path="$dst_path"; fi
    _ckw_result_file[$side]=$(mktemp) || {
      log_error "Could not create a temp result file for the ${side} checkpoint write for ${hive_db}.${table_name}."
      return 1
    }
    (
      if write_checkpoint_hdfs_one "$path" "$value"; then
        printf '0\t%s\n' "$path" > "${_ckw_result_file[$side]}"
      else
        printf '1\t%s\n' "$path" > "${_ckw_result_file[$side]}"
      fi
    ) &
  done
  wait

  local ok_count=0 _rc _path
  for side in SRC DST; do
    IFS=$'\t' read -r _rc _path < "${_ckw_result_file[$side]}"
    rm -f "${_ckw_result_file[$side]}"
    if [[ "$_rc" == "0" ]]; then
      log_info "Checkpoint written to HDFS (${side}): ${_path}"
      ok_count=$((ok_count + 1))
    else
      log_warn "Could not write checkpoint to HDFS (${side}) at ${_path} for ${hive_db}.${table_name}."
    fi
  done
  if [[ $ok_count -eq 0 ]]; then
    log_error "Could not write the checkpoint to EITHER cluster's HDFS for ${hive_db}.${table_name}."
    log_error "This run's progress is not durably recorded anywhere. Check HDFS_USER's (or the current"
    log_error "Kerberos ticket's) permissions on CHECKPOINT_DIR (${CHECKPOINT_DIR}) on both clusters."
    return 1
  fi
  return 0
}

# checkpoint_present: does either cluster hold a checkpoint for this
# direction? A yes/no probe in ONE `hadoop fs` launch covering both copies
# (`-cat` keeps going past a path that does not exist), for callers that
# only need to know a checkpoint is there, not what it says.
checkpoint_present() {
  local hive_db="$1" table_name="$2" src_ns="$3" dst_ns="$4"
  local _ckp_src_path _ckp_dst_path _ckp_content
  _ckp_src_path=$(checkpoint_hdfs_path_for "$src_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  _ckp_dst_path=$(checkpoint_hdfs_path_for "$dst_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  _ckp_content=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${_ckp_src_path}" "${_ckp_dst_path}" 2>/dev/null) || true
  [[ -n "${_ckp_content//[[:space:]]/}" ]]
}

# checkpoint_retire: take one direction's checkpoint out of service on both
# clusters by renaming it to "<name>.superseded". Called when a direction
# flip is confirmed (see DIRECTION FLIP in STEP 3), for the direction that
# has just stopped being the active one. Renamed rather than deleted: the
# old anchor stays on HDFS for reference, and nothing in this script reads a
# ".superseded" file. An earlier ".superseded" copy for the same direction
# is replaced.
#
# Returns non-zero only if a checkpoint copy is still in place afterwards --
# a cluster that simply has no copy of it is not a failure. Both copies
# must be gone, because checkpoint_read() accepts either one.
checkpoint_retire() {
  local hive_db="$1" table_name="$2" src_ns="$3" dst_ns="$4"

  local -a _ckr_paths=()
  local _ckr_src_path _ckr_dst_path
  _ckr_src_path=$(checkpoint_hdfs_path_for "$src_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  _ckr_dst_path=$(checkpoint_hdfs_path_for "$dst_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  _ckr_paths+=("$_ckr_src_path")
  [[ "$_ckr_dst_path" != "$_ckr_src_path" ]] && _ckr_paths+=("$_ckr_dst_path")

  # `hdfs dfs -mv` refuses an existing target, so clear any earlier
  # ".superseded" copy first (one launch for both clusters).
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -rm -f "${_ckr_paths[@]/%/.superseded}" >/dev/null 2>&1 || true

  local _ckr_path _ckr_failed=0
  for _ckr_path in "${_ckr_paths[@]}"; do
    if run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mv "${_ckr_path}" "${_ckr_path}.superseded" >/dev/null 2>&1; then
      log_info "Retired checkpoint: ${_ckr_path} -> ${_ckr_path}.superseded"
    elif run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -test -e "${_ckr_path}" 2>/dev/null; then
      log_error "Could not retire checkpoint ${_ckr_path} (it is still in place)."
      _ckr_failed=1
    fi
  done
  return "$_ckr_failed"
}

# checkpoint_read: the ONE call site every checkpoint read in this script
# goes through. Prints the checkpoint value on stdout and returns 0 if
# found; returns 1 (nothing printed) if neither copy exists -- callers treat
# that as "no checkpoint for this direction yet."
#
# Both copies are read in ONE `hadoop fs -cat <SRC copy> <DST copy>` launch:
# -cat prints each file that exists, in the order given, and keeps going
# past one that does not (its exit status is then non-zero, which is why
# the status is ignored and the content decides). A checkpoint is a single
# line, so the first non-blank line of the output is SRC's copy when SRC
# has one and DST's otherwise -- the same preference order as reading them
# one after the other, without a second launch when SRC's copy is missing.
checkpoint_read() {
  local hive_db="$1" table_name="$2" src_ns="$3" dst_ns="$4"

  local src_path dst_path content line
  src_path=$(checkpoint_hdfs_path_for "$src_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  dst_path=$(checkpoint_hdfs_path_for "$dst_ns" "$hive_db" "$table_name" "$src_ns" "$dst_ns")
  local -a paths=("$src_path")
  [[ "$dst_path" != "$src_path" ]] && paths+=("$dst_path")
  content=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${paths[@]}" 2>/dev/null) || true
  while IFS= read -r line; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    printf '%s\n' "$line"
    return 0
  done <<< "$content"
  return 1
}

# read_rewrite_file_list: read rewrite_table_path's file_list_location into a
# local file, handling BOTH output shapes actually observed for it in
# practice -- this is NOT a collision-mode-specific concern, it is a real
# Iceberg-runtime-version difference that would bite the non-collision path
# too, on a cluster running the newer runtime:
#   - Iceberg 1.9.x/1.10.x (RewriteTablePathSparkAction writing the list via
#     Spark's own DataFrameWriter): file_list_location is a DIRECTORY
#     containing an "_SUCCESS" marker plus one or more "part-*.csv" files --
#     this is what every other comment in this script describing the file
#     list's shape assumes, and what the original verified prod/DR pair
#     (STEP 4/5's own header comments) was tested against.
#   - A newer Iceberg runtime (confirmed via a real same-nameservice test
#     run: `hdfs dfs -ls` showed file_list_location as a single 2825-byte
#     PLAIN FILE, no directory, no part-files, no _SUCCESS marker at all --
#     this cluster pair's Iceberg jar also needed a Java 17 JVM to even
#     load, unlike the original verified pair, confirming it is a genuinely
#     different/newer build) writes the CSV content directly to that one
#     file instead.
# A bare "${location}/part-*" glob against the second shape resolves to a
# path that doesn't exist at all (the "/part-*" suffix is appended to a
# PLAIN FILE's own path, not a directory), so `hadoop fs -cat` fails with
# "No such file or directory" -- exactly the failure this fixes.
#
# Detected via `hadoop fs -test -f` (one cheap NameNode round trip, an
# unambiguous yes/no), rather than by guessing from a version string: this
# script has no reliable way to obtain the Iceberg version for a rewrite
# call specifically (probe_iceberg_runtime_version exists only for the v3
# deletion-vector gate, and is not wired to this decision), and the shape
# difference could just as easily be a vendor build's own packaging choice
# as a strict function of upstream version -- testing the actual path
# in front of it is the only assumption-free way to know which shape it is.
read_rewrite_file_list() {
  local location="$1"
  local local_out="$2"
  if run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -test -f "${location}" 2>/dev/null; then
    run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${location}"
  else
    run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${location}/part-*"
  fi > "${local_out}"
}

# hive_table_ref <db.table>: the table name as it goes into a HiveQL
# statement, each part backtick-quoted (`db`.`table`). Quoted so a table or
# database whose name is a HiveQL reserved word (order, user, date, ...)
# parses; such a table can exist, because it can be created quoted. Only for
# statements sent through beeline -- the Spark procedure calls take the name
# as a string argument and the checkpoint/lock/cache keys use the plain
# "db.table" form.
hive_table_ref() {
  local _qualified="$1"
  printf '`%s`.`%s`' "${_qualified%%.*}" "${_qualified#*.}"
}

# fetch_tblproperties: wraps "SHOW TBLPROPERTIES <table>;" via
# run_beeline_query_soft, propagating its exit code UNCHANGED. Deliberately
# thin -- whether a failure here is fatal (STEP 1: return 1) or soft
# (--seed-checkpoint/auto-seed/STEP 7: `|| true`) is each call site's own
# decision, not something to hardcode into a shared helper.
fetch_tblproperties() {
  local jdbc_url="$1"
  local qualified_table="$2"
  run_beeline_query_soft "${jdbc_url}" "SHOW TBLPROPERTIES $(hive_table_ref "${qualified_table}");"
}

# parse_tblproperty: extract one property's value from a tsv2
# SHOW TBLPROPERTIES blob (as returned by fetch_tblproperties above).
# Replaces the ~8 near-identical `awk -F'\t' '$1=="..."'` one-liners
# previously hand-copied across STEP 1, --seed-checkpoint, auto-seed, and
# STEP 7.
parse_tblproperty() {
  local properties_blob="$1"
  local property_name="$2"
  echo "${properties_blob}" | awk -F'\t' -v p="${property_name}" '$1==p{print $2}'
}

# Run a Spark SQL statement. Used for the Iceberg rewrite_table_path /
# register_table system procedures, which are Spark-only -- there is no
# Hive/beeline CALL-equivalent for these.
#
# Takes a Hive METASTORE Thrift URI (thrift://host:9083), NOT a HiveServer2
# JDBC URL: spark_catalog's Iceberg Hive catalog talks to the Metastore
# service directly, a different port/service than HS2. Also sets the
# Iceberg SQL extensions and catalog conf explicitly, since CALL is not
# valid SQL without IcebergSparkSessionExtensions registered. No --jars
# flag is added unless ICEBERG_SPARK_JAR is set -- on this ODP build,
# Spark3's default classpath already bundles the Iceberg runtime. Also
# injects HA_CONF_ARGS (built once, cluster-level, before the per-table
# loop, and read at call time via the array).
#
# SPARK_MASTER / SPARK_YARN_ARGS are resolved from SPARK_RUN_MODE up in the
# variable-declaration block near the top of this script (before the startup
# banner, so the banner can report which mode the run is using).

# build_executor_sizing_args: appends --executor-cores/--executor-memory and,
# under --master yarn, the dynamic-allocation-vs-fixed-count args, into the
# array named by out_array_name. Shared by run_spark_sql (STEP 4's
# rewrite_table_path/register_table) and run_spark_copier (STEP 5's file
# copy) -- the two jobs' sizing logic was previously hand-duplicated and
# differed only in which SPARK_REWRITE_*/SPARK_COPIER_* variables fed it.
#
# --num-executors / dynamic allocation only mean anything under a real YARN
# application; local[*] has no executors to size (the driver does the work
# on its own threads), so this only adds cores/memory when spark_master
# isn't "yarn" -- callers always pass SPARK_MASTER as-is and let this
# function decide, rather than duplicating that check themselves.
#
# max_executors=0 (both callers' default) intentionally omits maxExecutors/
# --num-executors entirely rather than substituting a script-chosen ceiling:
# the real limit on a shared production cluster is the YARN queue's own
# capacity, and a hardcoded number here would just be an artificial
# bottleneck under it. Uncapped dynamic allocation still can't exceed the
# queue's actual resources -- YARN itself is the backstop. Pass an explicit
# max_executors to bound a job below the queue's own capacity deliberately.
build_executor_sizing_args() {
  local -n out_ref="$1"
  local cores="$2" memory="$3" dynamic_allocation="$4" max_executors="$5"
  local spark_master="$6"
  out_ref+=(--executor-cores "${cores}" --executor-memory "${memory}")
  # --num-executors / dynamic allocation only mean anything under a real
  # YARN application; local[*] has no executors to size (the driver does
  # the work on its own threads) -- cores/memory above still apply either
  # way.
  [[ "${spark_master}" == "yarn" ]] || return 0
  case "${dynamic_allocation,,}" in
    true|yes|1)
      out_ref+=(
        --conf "spark.dynamicAllocation.enabled=true"
        # Lets dynamic allocation work without a cluster-wide external
        # shuffle service: neither job has any shuffles (STEP 4 is a
        # metadata-only manifest walk; STEP 5's copier is mapPartitions
        # only), so shuffle tracking's actual tracking behavior is moot --
        # this conf exists purely to satisfy Spark's startup sanity check,
        # which otherwise refuses dynamic allocation outright when no
        # shuffle service is configured.
        --conf "spark.dynamicAllocation.shuffleTracking.enabled=true"
      )
      if [[ "${max_executors}" -gt 0 ]]; then
        out_ref+=(--conf "spark.dynamicAllocation.maxExecutors=${max_executors}")
      fi
      ;;
    *)
      if [[ "${max_executors}" -gt 0 ]]; then
        out_ref+=(--num-executors "${max_executors}")
      fi
      # max_executors=0 with dynamic allocation off: no --num-executors is
      # passed at all, so spark-sql/spark-shell falls back to whatever the
      # cluster's own static default is.
      ;;
  esac
}

# collapse_standby_nn_trace: stdin -> stdout filter for spark-sql's stderr.
#
# With an HA nameservice the HDFS client tries the NameNodes in the order
# they are listed (SRC_NN_HOSTS/DST_NN_HOSTS, or hdfs-site.xml). When the
# first one is the standby, the client logs
#   WARN Client: Exception encountered while connecting to the server <host>
#   org.apache.hadoop.ipc.RemoteException: Operation category READ is not
#   supported in state standby. ...
# followed by a stack trace of well over a hundred lines, then fails over to
# the active NameNode and carries on. The call succeeds; the trace is only
# the record of the first attempt. This filter keeps that record as ONE line
# (the WARN line, with a note appended) and drops the exception line and its
# "at ..." frames.
#
# Nothing else is touched. A call that really fails because no NameNode is
# active ends in Spark's own error and stack trace, which does not start
# with this WARN line and passes through unchanged. Output is flushed line
# by line, so a stream that is being watched live stays live.
collapse_standby_nn_trace() {
  awk '
    function flush_held() { if (held != "") { print held; held = "" } }
    {
      if (skipping) {
        if ($0 ~ /^[ \t]+at /) next
        skipping = 0
      }
      if (held != "") {
        if ($0 ~ /Operation category [A-Z]+ is not supported in state standby/) {
          print held " -- standby NameNode; the HDFS client fails over to the active one (stack trace omitted)"
          held = ""
          skipping = 1
          fflush()
          next
        }
        flush_held()
      }
      if ($0 ~ /WARN Client: Exception encountered while connecting to the server/) {
        held = $0
        next
      }
      print
      fflush()
    }
    END { flush_held() }
  '
}

# Runs via run_as_spark_user (not run_as_hdfs): spark-sql is a local process
# that needs to read/write HDFS as an authorized user in non-Kerberos mode --
# unlike beeline (a JDBC client, authenticated via -n/-p instead of a
# process identity switch).
run_spark_sql() {
  local metastore_uri="$1"
  local statement="$2"
  local runtime_args=()
  if [[ -n "${ICEBERG_SPARK_JAR}" ]]; then
    runtime_args=(--jars "${ICEBERG_SPARK_JAR}")
  fi

  # Executor sizing -- see build_executor_sizing_args (shared with
  # run_spark_copier's equivalent block).
  local -a _rewrite_executor_args=()
  build_executor_sizing_args _rewrite_executor_args \
    "${SPARK_REWRITE_EXECUTOR_CORES}" "${SPARK_REWRITE_EXECUTOR_MEMORY}" \
    "${SPARK_REWRITE_DYNAMIC_ALLOCATION}" "${SPARK_REWRITE_MAX_EXECUTORS}" \
    "${SPARK_MASTER}"

  # SPARK_REWRITE_EXTRA_ARGS: free-form escape hatch (see its own
  # declaration near the top of this script) -- split on whitespace only,
  # so a value with an embedded space cannot be expressed this way.
  local -a _rewrite_extra_args=()
  if [[ -n "$SPARK_REWRITE_EXTRA_ARGS" ]]; then
    read -ra _rewrite_extra_args <<< "$SPARK_REWRITE_EXTRA_ARGS"
  fi

  # INFO here is Spark/Hive/Iceberg's own internal logging (Metastore lock
  # polling, HA failover-proxy retries, commit progress) -- it goes to
  # spark-sql's stderr like the default WARN level does, never mixed into
  # the stdout query-result rows callers capture via $(...), so raising it
  # is safe. Without this, a long-running register_table/rewrite_table_path
  # call sits completely silent until it either finishes or fails, making a
  # slow call indistinguishable from a hung one. Gated behind
  # SPARK_REWRITE_VERBOSE_LOG (default false) since it is otherwise just
  # noise on a fast/incremental call.
  local -a _rewrite_log_level_args=()
  case "${SPARK_REWRITE_VERBOSE_LOG,,}" in
    true|yes|1) _rewrite_log_level_args=(--conf "spark.log.level=INFO") ;;
  esac

  # Driver sizing (see SPARK_REWRITE_DRIVER_MEMORY/SPARK_REWRITE_DRIVER_CORES's
  # own declaration) -- omitted entirely when unset, so this job's driver
  # falls back to spark-defaults.conf/Spark's own default rather than a
  # value this script picked for it.
  local -a _rewrite_driver_args=()
  [[ -n "$SPARK_REWRITE_DRIVER_MEMORY" ]] && _rewrite_driver_args+=(--driver-memory "$SPARK_REWRITE_DRIVER_MEMORY")
  [[ -n "$SPARK_REWRITE_DRIVER_CORES" ]] && _rewrite_driver_args+=(--driver-cores "$SPARK_REWRITE_DRIVER_CORES")

  local spark_cmd=(spark-sql
    --master "${SPARK_MASTER}"
    "${SPARK_YARN_ARGS[@]}"
    "${_rewrite_driver_args[@]}"
    "${_rewrite_executor_args[@]}"
    "${runtime_args[@]}"
    "${HA_CONF_ARGS[@]}"
    --conf "spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions"
    --conf "spark.sql.catalog.${SPARK_CATALOG}=org.apache.iceberg.spark.SparkCatalog"
    --conf "spark.sql.catalog.${SPARK_CATALOG}.type=hive"
    --conf "spark.sql.catalog.${SPARK_CATALOG}.uri=${metastore_uri}"
    "${EXTRA_CATALOG_ARGS[@]}"
    "${_rewrite_log_level_args[@]}"
    "${_rewrite_extra_args[@]}"
    -e "${statement}")

  # >&2: every caller that captures this function's output via $(...) must
  # get ONLY spark-sql's real output on fd1 -- this preamble is diagnostic
  # logging, not part of the result. Without the redirect, a captured
  # REWRITE_SQL containing its own "*.metadata.json" filename (any
  # incremental run's start_version) would land in the same captured blob
  # as the real result row, and a caller parsing for "the line containing
  # .metadata.json" could pick up the echoed command instead of the actual
  # output. Both lines are still fully visible in the log file: the
  # top-level `exec > >(tee -a "$RUN_LOG_FILE") 2>&1` merges fd1 and fd2
  # back into the same stream there, just unindented and interleaved
  # slightly earlier than before this change -- no information is lost.
  log_info "Running spark-sql:" >&2
  print_cmd_pretty "${spark_cmd[@]}" >&2

  # stderr goes through collapse_standby_nn_trace; stdout is untouched.
  # fd 3 carries the statement's stdout around the pipeline, and `pipefail`
  # (set at the top of this script) makes the pipeline's status spark-sql's
  # own -- the filter itself always exits 0.
  { run_as_spark_user "${spark_cmd[@]}" 2>&1 1>&3 | collapse_standby_nn_trace >&2; } 3>&1
}

# register_hive_engine_enabled: is REGISTER_HIVE_ENGINE_ENABLED on?
register_hive_engine_enabled() {
  case "${REGISTER_HIVE_ENGINE_ENABLED,,}" in
    true|yes|1) return 0 ;;
  esac
  return 1
}

# run_register_table <register_sql>: CALL register_table against the
# DESTINATION catalog. Same as run_spark_sql, plus
# iceberg.engine.hive.enabled=true when REGISTER_HIVE_ENGINE_ENABLED is on
# (see that variable's declaration). The conf goes in through
# EXTRA_CATALOG_ARGS, which is empty at every call site of this function and
# is left empty again afterwards.
run_register_table() {
  local register_sql="$1" _rc=0
  if register_hive_engine_enabled; then
    EXTRA_CATALOG_ARGS=(--conf "spark.hadoop.iceberg.engine.hive.enabled=true")
  fi
  run_spark_sql "${DST_METASTORE_URI}" "${register_sql}" || _rc=$?
  EXTRA_CATALOG_ARGS=()
  return "$_rc"
}

# dst_missing_hive_storage_handler <tblproperties_blob>: true when the blob
# is a registered Iceberg table's SHOW TBLPROPERTIES output (it carries a
# metadata_location) and has no storage_handler row. An empty or unreadable
# blob answers false: nothing can be concluded from it.
dst_missing_hive_storage_handler() {
  local _props="$1"
  [[ -n "$(parse_tblproperty "$_props" metadata_location)" ]] || return 1
  [[ -z "$(parse_tblproperty "$_props" storage_handler)" ]]
}

# STDERR HANDLING FOR STEP 4's rewrite_table_path CALLS.
#
# Those calls need their stderr in a FILE: the recovery logic greps it for
# specific exception texts, and stdout must stay clean for result-row
# parsing. Two modes, chosen by SPARK_REWRITE_VERBOSE_LOG:
#
#   - default (false): stderr goes to the file only, and is replayed to the
#     log once the call has ended. That lets a known, auto-recoverable
#     failure be introduced by an explanation and cut down to its error
#     lines, instead of dropping a bare Java stack trace into the log.
#   - verbose (true): stderr is ALSO streamed to the log while the call is
#     running. SPARK_REWRITE_VERBOSE_LOG exists to make a long rewrite's
#     progress visible as it happens, which a replay at the end cannot do.
#     Nothing is replayed afterwards (it has all been shown already).
#
# _spark_stderr_is_live: is the verbose (live) mode on?
_spark_stderr_is_live() {
  case "${SPARK_REWRITE_VERBOSE_LOG,,}" in
    true|yes|1) return 0 ;;
  esac
  return 1
}

# run_spark_sql_capturing_stderr <metastore_uri> <statement> <stderr_file>:
# run_spark_sql with its stderr captured into <stderr_file> (and, in verbose
# mode, streamed live as well). stdout is the statement's own output, exactly
# as with a bare run_spark_sql, and the exit status is run_spark_sql's.
#
# Verbose mode routes stderr through a real pipeline rather than a process
# substitution, so `tee` has finished writing <stderr_file> before this
# function returns and the caller greps it. fd 3 carries the statement's
# stdout around that pipeline; `pipefail` (set at the top of this script)
# makes the pipeline's status run_spark_sql's own.
run_spark_sql_capturing_stderr() {
  local metastore_uri="$1"
  local statement="$2"
  local stderr_file="$3"
  if _spark_stderr_is_live; then
    { run_spark_sql "${metastore_uri}" "${statement}" 2>&1 1>&3 | tee "${stderr_file}" >&2; } 3>&1
  else
    run_spark_sql "${metastore_uri}" "${statement}" 2>"${stderr_file}"
  fi
}

# replay_spark_stderr <stderr_file> [full|errors-only]: write a captured
# stderr file to the log after the call has ended. "errors-only" keeps just
# the first few error lines (for a failure that is about to be auto-
# recovered). A no-op in verbose mode, where it was already streamed live.
replay_spark_stderr() {
  local stderr_file="$1"
  local mode="${2:-full}"
  _spark_stderr_is_live && return 0
  if [[ "$mode" == "errors-only" ]]; then
    grep -E "(ERROR|IllegalArgumentException: (Version file|Cannot find provided version file))" "${stderr_file}" | head -n 3 | _tag_lines >&2 || true
  else
    _tag_lines < "${stderr_file}" >&2
  fi
  return 0
}

# log_yarn_application_id <label> <file> [text]: put the YARN application id
# of a Spark job on a log line of its own, so it can be looked up in the
# ResourceManager UI / `yarn logs -applicationId` without digging it out of
# Spark's output. Searches <file> (if it exists) and [text]; logs nothing if
# no id is found or the job did not run on YARN.
log_yarn_application_id() {
  local label="$1" file="$2" text="${3:-}" app_id=""
  [[ "$SPARK_MASTER" == "yarn" ]] || return 0
  app_id=$( { [[ -f "$file" ]] && cat "$file"; printf '%s\n' "$text"; } 2>/dev/null \
            | grep -aoE 'application_[0-9]+_[0-9]+' | head -n 1 ) || true
  if [[ -n "$app_id" ]]; then
    log_info "YARN application (${label}): ${app_id}"
  fi
  return 0
}

# run_spark_copier: copy every (source,target) pair in a normalized file list
# using ONE Spark job for STEP 5's whole delta, regardless of how many
# partitions it spans. This is the COPY_ENGINE=spark (default) engine; see
# run_distcp_copier() below for the COPY_ENGINE=distcp alternative and
# run_copy_engine() for the dispatcher between them.
#
# WHY THIS EXISTS. The distcp-based engine (still available as
# run_distcp_copier(), COPY_ENGINE=distcp) groups the file list by target
# directory and submits one MapReduce job per group -- required because
# `hadoop distcp -f <list> <target>` writes every listed source into ONE
# target directory under its BASENAME alone (it cannot reconstruct a nested
# partition path from a flat file list; verified on this DR pair: three files
# from three different leaf partitions, listed together against a single
# target, all landed flat with every partition level discarded). That pins
# the YARN job count to the table's touched-partition count (82 jobs for one
# 3035-file bootstrap here, most of them moving a few KB and dominated
# entirely by AM/container launch).
#
# Driving the copy loop ourselves removes that constraint completely: each task
# calls FileUtil.copy(source -> exact target), so one job covers every partition
# at once and parallelism is set by task count rather than by how the table
# happens to be partitioned.
#
# WHAT THIS DELIBERATELY DOES NOT DO: distcp's own -p[bugpcaxt] preserve set is
# a distcp feature, not a filesystem one. Permission, owner/group and
# modification time are re-applied explicitly below; ACLs and XAttrs are NOT
# replicated. Confirmed not needed on this deployment (access control managed
# at the Hive/Ranger catalog layer); a deployment relying on HDFS-level
# ACLs/XAttrs for these tables should use COPY_ENGINE=distcp with
# DISTCP_PRESERVE_OPTS including the flags it needs, or extend this copier.
#
# Correctness notes on the Scala below:
#   - The driver's Hadoop configuration is broadcast to the executors. A bare
#     `new Configuration()` on an executor reads only that node's on-disk
#     core-site/hdfs-site and would miss every HA override this script injects
#     when AUTO_DERIVE_HA_CLIENT_CONFIG=yes, so the far cluster's logical
#     nameservice would fail to resolve there.
#   - Rows are split on the FIRST comma, matching the bash reader's
#     `IFS=',' read -r src tgt` semantics exactly, rather than going through a
#     CSV parser whose quoting rules could differ on an odd partition value.
#   - A target that already exists with the same length is SKIPPED, which is
#     what distcp's own -update does, so re-running a partially-completed copy
#     is cheap and idempotent.
#   - Per-file failures are captured, not thrown: one unreadable file must not
#     abort a job that has already copied thousands. The counts come back in a
#     single sentinel line, and a non-zero failed count fails this table.
run_spark_copier() {
  local copy_list_local="$1"
  local copy_list_hdfs="$2"
  local qualified_table="$3"
  local expected_rows="$4"

  # expected_rows is substituted straight into the generated Scala as a numeric
  # literal, so a non-numeric value would produce a program that does not
  # compile -- and a compile failure surfaces only as "no result line", which
  # is a far more confusing symptom than the real problem. Check it here.
  if [[ ! "$expected_rows" =~ ^[0-9]+$ ]]; then
    log_error "Internal error: run_spark_copier got a non-numeric row count ('${expected_rows}') for ${qualified_table}."
    return 1
  fi

  local copy_list_hdfs_dir="${copy_list_hdfs%/*}"
  log_info "[5d] Staging copy list (${expected_rows} row(s)) at ${copy_list_hdfs} ..."
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir -p "${copy_list_hdfs_dir}" || {
    log_error "Could not create copy-list staging directory ${copy_list_hdfs_dir} for ${qualified_table}."
    return 1
  }
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -put -f "${copy_list_local}" "${copy_list_hdfs}" || {
    log_error "Could not stage copy list at ${copy_list_hdfs} for ${qualified_table}."
    return 1
  }

  local scala_script="${copy_list_local%.csv}.copier.scala"
  # WHERE THE RESULT IS READ FROM, and why it is not simply spark-shell's
  # stdout. Observed in production: the ICEBERG_COPY_* lines this job prints do
  # NOT appear in the file that `run_as_spark_user ... > "${copier_log}"` redirects
  # stdout into -- they arrive on the terminal instead, unindented, while every
  # other line of spark-shell output lands in the log file as expected. The
  # Scala REPL writes through its own terminal-attached writer rather than the
  # inherited stdout, so a redirect at the shell level does not capture it. A
  # run that copied 3346 files with zero failures was therefore reported as a
  # FAILURE, because grepping the log for the sentinel found nothing.
  #
  # So the driver writes the outcome to a plain local FILE (it runs on this
  # host -- spark-shell is always client mode), which bash then reads directly.
  # The log is still grepped as a fallback, so this keeps working if a future
  # Spark version starts honouring the redirect after all.
  local copier_result="${copy_list_local%.csv}.copier.result"
  rm -f "${copier_result}"
  # Unquoted heredoc: ${copy_list_hdfs}, ${copier_result} and
  # ${SPARK_COPY_PARTITIONS} are substituted by bash. The Scala below contains
  # no '$' of its own (no string interpolation, no shell-significant
  # sequences), so nothing else expands.
  cat > "${scala_script}" <<SCALA_EOF
import org.apache.hadoop.conf.Configuration
import org.apache.hadoop.fs.{FileUtil, Path}
import scala.collection.JavaConverters._

val listPath = "${copy_list_hdfs}"
val resultPath = "${copier_result}"
val numParts = ${SPARK_COPY_PARTITIONS}
val expectedRows = ${expected_rows}L

val hconf = spark.sparkContext.hadoopConfiguration
val confPairs = hconf.iterator().asScala
  .map(e => (e.getKey, e.getValue))
  .filter(kv => kv._1.startsWith("dfs.") || kv._1.startsWith("fs.") || kv._1.startsWith("hadoop.") || kv._1.startsWith("ipc."))
  .toMap
val bconf = spark.sparkContext.broadcast(confPairs)

// Task count is sized from the row count bash already counted, so no separate
// counting job is needed, and textFile's minPartitions argument splits the
// input directly -- a repartition() here would shuffle every row across the
// cluster before copying a single byte, which at millions of rows is a large
// cost for nothing (the rows are independent; their placement does not matter).
val parts = if (numParts > 0) {
  numParts
} else {
  // Adaptive: balance task overhead vs. parallelism based on dataset size
  // Small deltas: keep granular (better fault tolerance on small file sets)
  // Large deltas: more tasks (better cluster utilization, fewer stragglers)
  val filesPerTask = if (expectedRows < 10000L) {
    50L   // < 10K files: 50 files/task (up to 200 tasks)
  } else if (expectedRows < 500000L) {
    100L  // 10K-500K files: 100 files/task (up to 5K tasks)
  } else {
    200L  // >= 500K files: 200 files/task (better load distribution)
  }

  // Cap at 10K tasks to prevent driver OOM and excessive task scheduling overhead
  // With typical 50-100 executor clusters, 10K tasks = 100-200 tasks/executor (good balance)
  val maxTasks = 10000L

  val calculatedTasks = (expectedRows / filesPerTask) + 1L
  // Floor for small deltas: files-per-task alone would put a delta of fewer
  // than 50 files into ONE task, copied one file after another however large
  // the files are. Up to 16 tasks (never more tasks than rows) lets a
  // handful of big files copy side by side.
  val minTasks = math.min(expectedRows, 16L)
  math.max(1L, math.min(math.max(calculatedTasks, minTasks), maxTasks)).toInt
}
println("ICEBERG_COPY_PLAN rows=" + expectedRows + " tasks=" + parts + " (~" + (expectedRows / parts) + " files/task)")

val pairs = spark.sparkContext.textFile(listPath, parts).flatMap { line =>
  val i = line.indexOf(',')
  if (i <= 0 || i >= line.length - 1) None else Some((line.substring(0, i), line.substring(i + 1)))
}

// ONE action, returning per-partition counts plus a bounded sample of failure
// messages. Deliberately NOT "cache(), then count by status, then filter for
// failures": that is two actions over the same RDD, and if a cached partition
// were evicted between them Spark would RECOMPUTE it -- re-running the copy
// side effects, and (because the re-run would then see its own output already
// present) reporting those rows as SKIPPED, silently losing the very failure
// messages the second pass existed to collect.
val perPartition = pairs.mapPartitions { it =>
  val conf = new Configuration()
  bconf.value.foreach(kv => conf.set(kv._1, kv._2))
  var copied = 0L
  var skipped = 0L
  var failed = 0L
  var preserveWarn = 0L
  val msgs = new scala.collection.mutable.ArrayBuffer[String]()
  it.foreach { p =>
    val src = p._1
    val dst = p._2
    try {
      val sp = new Path(src)
      val dp = new Path(dst)
      val sfs = sp.getFileSystem(conf)
      val dfs = dp.getFileSystem(conf)
      val sst = sfs.getFileStatus(sp)
      // One getFileStatus, not exists()+getFileStatus: the two-call form costs
      // an extra NameNode round trip for EVERY file, and a not-found throw is
      // exactly the "absent" answer we want anyway.
      var present = false
      try {
        present = dfs.getFileStatus(dp).getLen == sst.getLen
      } catch {
        case t: Throwable => present = false
      }
      if (present) {
        skipped += 1
      } else {
        dfs.mkdirs(dp.getParent)
        FileUtil.copy(sfs, sp, dfs, dp, false, true, conf)
        // Best-effort metadata preservation. Counted rather than silently
        // swallowed: setOwner in particular requires superuser, and a DR copy
        // quietly landing with the wrong ownership is worth one summary line.
        try { dfs.setPermission(dp, sst.getPermission) } catch { case t: Throwable => preserveWarn += 1 }
        try { dfs.setOwner(dp, sst.getOwner, sst.getGroup) } catch { case t: Throwable => preserveWarn += 1 }
        try { dfs.setTimes(dp, sst.getModificationTime, -1L) } catch { case t: Throwable => preserveWarn += 1 }
        copied += 1
      }
    } catch {
      case t: Throwable =>
        failed += 1
        if (msgs.size < 5) msgs += (src + " -> " + dst + " : " + String.valueOf(t.getMessage))
    }
  }
  Iterator((copied, skipped, failed, preserveWarn, msgs.toArray))
}.collect()

val copied = perPartition.map(r => r._1).sum
val skipped = perPartition.map(r => r._2).sum
val failed = perPartition.map(r => r._3).sum
val preserveWarn = perPartition.map(r => r._4).sum
// The authoritative total is what was actually PROCESSED, not what bash
// counted -- keeping the two independent is what makes the row-count
// cross-check in the shell a real check rather than a tautology.
val total = copied + skipped + failed
val summary = "ICEBERG_COPY_RESULT total=" + total + " copied=" + copied + " skipped=" + skipped + " failed=" + failed + " preserve_warn=" + preserveWarn
val failureLines = perPartition.flatMap(r => r._5).take(50)

// Write the outcome to a real file, not just stdout: the REPL's stdout does
// not reach the shell redirect (see the note above this heredoc in the
// script). This file is what bash actually reads to decide pass/fail.
val pw = new java.io.PrintWriter(new java.io.File(resultPath))
try {
  failureLines.foreach(m => pw.println("ICEBERG_COPY_FAILURE " + m))
  pw.println(summary)
} finally {
  pw.close()
}

failureLines.foreach(m => println("ICEBERG_COPY_FAILURE " + m))
println(summary)
System.exit(if (failed > 0L) 1 else 0)
SCALA_EOF

  # Executor sizing. Deliberately separate from SPARK_COPY_PARTITIONS (task count): a task queued onto
  # too few executors runs no faster than the serial distcp path this mode replaces. See the
  # SPARK_COPIER_* declaration block for the full rationale, and build_executor_sizing_args (shared
  # with run_spark_sql's equivalent block) for the sizing logic itself.
  local -a _copier_executor_args=()
  build_executor_sizing_args _copier_executor_args \
    "${SPARK_COPIER_EXECUTOR_CORES}" "${SPARK_COPIER_EXECUTOR_MEMORY}" \
    "${SPARK_COPIER_DYNAMIC_ALLOCATION}" "${SPARK_COPIER_MAX_EXECUTORS}" \
    "${SPARK_MASTER}"

  # SPARK_COPIER_EXTRA_ARGS: free-form escape hatch (see its own
  # declaration near the top of this script) -- split on whitespace only,
  # so a value with an embedded space cannot be expressed this way.
  local -a _copier_extra_args=()
  if [[ -n "$SPARK_COPIER_EXTRA_ARGS" ]]; then
    read -ra _copier_extra_args <<< "$SPARK_COPIER_EXTRA_ARGS"
  fi

  # Driver sizing (see SPARK_COPIER_DRIVER_MEMORY/SPARK_COPIER_DRIVER_CORES's
  # own declaration) -- omitted entirely when unset, same rationale as
  # run_spark_sql's equivalent block.
  local -a _copier_driver_args=()
  [[ -n "$SPARK_COPIER_DRIVER_MEMORY" ]] && _copier_driver_args+=(--driver-memory "$SPARK_COPIER_DRIVER_MEMORY")
  [[ -n "$SPARK_COPIER_DRIVER_CORES" ]] && _copier_driver_args+=(--driver-cores "$SPARK_COPIER_DRIVER_CORES")

  # spark.speculation=false: each task WRITES files, so a speculative second
  # attempt of a slow task would have two attempts creating the same target
  # path at once -- one attempt's create() invalidates the other's open
  # stream, and that attempt reports a failed file for a copy that is in fact
  # fine. Pinned off here rather than left to the cluster default; placed
  # before SPARK_COPIER_EXTRA_ARGS so that escape hatch can still override it.
  #
  # Deliberately NOT passing the Iceberg SQL extensions/catalog conf here: this
  # job is plain Hadoop FileSystem work and never touches a catalog, so the
  # fewer moving parts on its classpath the better. SPARK_YARN_ARGS is however
  # essential -- it carries spark.kerberos.access.hadoopFileSystems for BOTH
  # nameservices, without which executors get a token for their own default
  # filesystem only and fail the instant they read the far cluster.
  local spark_cmd=(spark-shell
    --master "${SPARK_MASTER}"
    "${SPARK_YARN_ARGS[@]}"
    "${HA_CONF_ARGS[@]}"
    "${_copier_driver_args[@]}"
    "${_copier_executor_args[@]}"
    --conf "spark.speculation=false"
    "${_copier_extra_args[@]}"
    --name "iceberg-repl-copy-${qualified_table}"
    -i "${scala_script}")

  log_info "[5d] Running Spark copier (one job for all ${expected_rows} file(s)):"
  print_cmd_pretty "${spark_cmd[@]}"

  local copier_log="${copy_list_local%.csv}.copier.out"
  local _rc=0
  # </dev/null: spark-shell reads its REPL input from stdin, and would otherwise
  # consume whatever this script's stdin happens to be attached to and hang.
  run_as_spark_user "${spark_cmd[@]}" < /dev/null > "${copier_log}" 2>&1 || _rc=$?

  # QUIET_COPIER_OUTPUT (see its declaration): the full spark-shell session
  # is printed unless the copy is clean -- exit 0, and a result line that
  # accounts for every staged row with zero failed files. Decided here from
  # the same result line the checks below go on to parse; any doubt at all
  # (no result line, a failed file, a row-count mismatch, a non-zero exit)
  # prints everything, so a problem is never hidden by this.
  local _copier_clean=false _copier_quick_result=""
  if [[ $_rc -eq 0 ]]; then
    _copier_quick_result=$(grep -ah "^ICEBERG_COPY_RESULT " "${copier_result}" "${copier_log}" 2>/dev/null | tail -n 1) || true
    if [[ "$_copier_quick_result" == *" total=${expected_rows} "* && "$_copier_quick_result" == *" failed=0 "* ]]; then
      _copier_clean=true
    fi
  fi
  case "${QUIET_COPIER_OUTPUT,,}" in
    true|yes|1)
      if [[ "$_copier_clean" == "true" ]]; then
        grep -a "^ICEBERG_COPY_PLAN " "${copier_log}" 2>/dev/null | indent_output || true
      else
        indent_output < "${copier_log}"
      fi
      ;;
    *)
      indent_output < "${copier_log}"
      ;;
  esac
  log_yarn_application_id "copier, ${qualified_table}" "${copier_log}"

  # The sentinel line is the authority on the outcome, not spark-shell's exit
  # code alone: a script that fails to COMPILE never reaches System.exit, and
  # spark-shell can still exit 0 after printing the compilation error. Requiring
  # the sentinel means "no result line" is treated as a failure rather than as a
  # silently successful copy of nothing.
  #
  # Read the driver's own result FILE first (see the note above the heredoc:
  # the REPL's stdout does not reliably reach ${copier_log}), and fall back to
  # grepping the captured log so this still works if a future Spark version
  # does honour the redirect.
  local result_line=""
  if [[ -s "${copier_result}" ]]; then
    result_line=$(grep -a "^ICEBERG_COPY_RESULT " "${copier_result}" 2>/dev/null | tail -n 1) || true
  fi
  if [[ -z "$result_line" ]]; then
    result_line=$(grep -a "^ICEBERG_COPY_RESULT " "${copier_log}" 2>/dev/null | tail -n 1) || true
  fi
  if [[ -z "$result_line" ]]; then
    log_error "Spark copier for ${qualified_table} produced no ICEBERG_COPY_RESULT line (exit ${_rc})."
    log_error "Nothing can be assumed about what it copied -- treating this as a failure."
    log_error "Full copier output is above; the script it ran is at ${scala_script}"
    return 1
  fi

  local _c_total _c_copied _c_skipped _c_failed _c_preserve
  _c_total="${result_line#*total=}";     _c_total="${_c_total%% *}"
  _c_copied="${result_line#*copied=}";   _c_copied="${_c_copied%% *}"
  _c_skipped="${result_line#*skipped=}"; _c_skipped="${_c_skipped%% *}"
  _c_failed="${result_line#*failed=}";   _c_failed="${_c_failed%% *}"
  # preserve_warn is newer than the other fields; a result line from an older
  # copier script simply will not contain it, in which case the expansion
  # yields the whole line back -- so treat anything non-numeric as "unknown".
  _c_preserve="${result_line#*preserve_warn=}"; _c_preserve="${_c_preserve%% *}"
  [[ "$_c_preserve" =~ ^[0-9]+$ ]] || _c_preserve=0

  # Same precedence as the result line: the driver's own file, then the log.
  local _fail_src="${copier_log}"
  [[ -s "${copier_result}" ]] && _fail_src="${copier_result}"
  local _fail_line
  while IFS= read -r _fail_line; do
    [[ -z "$_fail_line" ]] && continue
    log_error "  ${_fail_line#ICEBERG_COPY_FAILURE }"
  done < <(grep -a "^ICEBERG_COPY_FAILURE " "${_fail_src}" 2>/dev/null || true)

  log_info "[5d] Spark copier finished: ${_c_copied} copied, ${_c_skipped} already present, ${_c_failed} failed (of ${_c_total})."

  # Export statistics to parent scope for STEP 8 summary (if variables exist)
  [[ -v FILES_COPIED ]] && FILES_COPIED=${_c_copied}
  [[ -v FILES_SKIPPED ]] && FILES_SKIPPED=${_c_skipped}
  [[ -v FILES_FAILED ]] && FILES_FAILED=${_c_failed}

  # Not fatal -- the DATA is correct either way -- but ownership/permission that
  # silently failed to transfer is exactly the kind of thing nobody notices
  # until a DR cutover, so it gets said out loud rather than swallowed.
  if [[ "$_c_preserve" != "0" ]]; then
    log_warn "[5d] ${_c_preserve} metadata-preservation call(s) failed (permission/owner/mtime) for ${qualified_table}."
    log_warn "[5d] File CONTENT is unaffected. setOwner in particular needs superuser; if ownership must"
    log_warn "[5d] match on the destination, run this script as a superuser."
  fi

  if [[ "$_c_failed" != "0" || $_rc -ne 0 ]]; then
    log_error "Spark copier failed for ${qualified_table} (${_c_failed} file(s) failed, exit ${_rc})."
    return 1
  fi

  # Sanity-check the row count the job actually saw against what this script
  # wrote. A mismatch means the two sides disagree about the copy plan (a
  # truncated upload, or a stale list read from a previous run), which must not
  # be reported as a clean success.
  if [[ -n "$expected_rows" && "$_c_total" != "$expected_rows" ]]; then
    log_error "Spark copier processed ${_c_total} row(s) but this run staged ${expected_rows} for ${qualified_table}."
    return 1
  fi

  # Clean up this call's own scala script + result/log files now that the
  # copy is confirmed successful -- same "no reason to keep it once it's
  # verified good" cleanup run_collision_metadata_patch_job() already does
  # for its own scala/result files. Deliberately ONLY on this success path,
  # never on a failure return above: a failed run's artifacts stay in place
  # for debugging (the same invariant KEEP_RUN_ARTIFACTS pruning documents
  # for the CSVs these files are companions of), and this function has no
  # way to tell a genuine failure from a table this script will retry.
  # Without this, these three files previously lived until PRUNE_RUN_
  # ARTIFACTS' next 5-runs-later sweep caught them as companions of their
  # originating copy-list.csv, leaking disk in the meantime.
  rm -f "${scala_script}" "${copier_result}" "${copier_log}"
  return 0
}

# run_distcp_copier: copy every (source,target) pair in a normalized file list
# using `hadoop distcp -f`, grouped by TARGET DIRECTORY -- one distcp
# (MapReduce) job per distinct target directory the delta touches.
#
# WHY GROUPED, NOT ONE JOB FOR THE WHOLE LIST. `hadoop distcp -f <list>
# <target>` copies every source path listed in <list> into ONE target
# directory, using each source's BASENAME only -- it cannot reconstruct a
# nested partition path from a flat file list (verified on this DR pair:
# three files from three different leaf partitions, listed together against a
# single target, all landed flat with every partition level discarded). So
# every row in the copy list must be routed to a `distcp -f` invocation whose
# target is EXACTLY that row's own target directory, which means grouping by
# target directory and running one job per group. This is the same engine
# this script used before the Spark copier replaced it as the default -- see
# "HOW STEP 5 COPIES THE FILES" in the header for the full history and the
# tradeoffs (job count scales with touched-partition count, e.g. 82 jobs for
# one 3035-file bootstrap on this DR pair, most moving a few KB and dominated
# by AM/container launch).
#
# WHAT THIS GIVES BACK relative to the Spark copier: distcp's own
# `-p[bugpcaxt]` preserve flags (DISTCP_PRESERVE_OPTS below), and `-update`
# skip-if-same-length semantics, both real distcp features rather than
# something this script re-implements. It does NOT get the Spark copier's
# single-job-for-the-whole-delta parallelism -- see COPY_ENGINE's own
# declaration for when to prefer one over the other.
#
# Same 4-argument signature as run_spark_copier (copy_list_local,
# copy_list_hdfs, qualified_table, expected_rows) so run_copy_engine can
# dispatch to either with no call-site changes: copy_list_hdfs is accepted
# for signature parity but unused here (distcp reads the LOCAL copy list
# directly -- there is no need to stage it on HDFS first the way the Spark
# copier's textFile() input does).
run_distcp_copier() {
  local copy_list_local="$1"
  local qualified_table="$3"
  local expected_rows="$4"
  # $5, optional: SAME-NAMESERVICE COLLISION Hop A only -- the plain shared
  # authority ("hdfs://<DST_NAMESERVICE>") to rewrite away from in every
  # source row, replaced with the SRCALIAS name
  # ("<DST_NAMESERVICE>-SRCALIAS") this call's own distcp invocations will
  # use instead. See build_collision_hop_a_distcp_alias_ha_args()'s header
  # comment for the full "why" -- in short, distcp/MapReduce has no
  # equivalent of Spark's spark.yarn.stagingDir override for its own
  # scheme-less job-staging path and mapreduce.application.framework.path,
  # so redirecting the PLAIN shared name (the way Hop A's spark-sql call
  # and the global HDFS_HA_ARGS this function would otherwise inherit both
  # do) makes fs.defaultFS itself ambiguous and breaks AM container
  # localization (confirmed by direct testing on this exact cluster pair:
  # "Resource .../mapreduce.tar.gz changed on src filesystem" failures).
  # Aliasing SOURCE under a distinct name instead, and rewriting only the
  # rows THIS call's own group files carry, leaves fs.defaultFS untouched.
  # Empty/unset for every other caller (the normal, non-collision path, and
  # Hop B, which is a purely local same-cluster rewrite) -- this rewrite and
  # the alias HA args below are skipped entirely then, byte-for-byte the
  # same behavior as before this parameter existed.
  local collision_src_plain_authority="${5:-}"

  if [[ ! "$expected_rows" =~ ^[0-9]+$ ]]; then
    log_error "Internal error: run_distcp_copier got a non-numeric row count ('${expected_rows}') for ${qualified_table}."
    return 1
  fi

  # SRCALIAS HA args, built ONCE per call (not per-group) when this is a
  # collision-mode Hop A invocation -- see this parameter's own comment
  # above and build_collision_hop_a_distcp_alias_ha_args()'s header for the
  # full mechanism. Left empty (falls through to the caller's own
  # HDFS_HA_ARGS, exactly as before this fix) for every other call.
  local -a _dc_alias_ha_args=()
  local _dc_src_alias=""
  if [[ -n "$collision_src_plain_authority" ]]; then
    _dc_src_alias="${DST_NAMESERVICE}-SRCALIAS"
    build_collision_hop_a_distcp_alias_ha_args _dc_alias_ha_args || {
      log_error "Could not build the SRCALIAS HA args for distcp Hop A copy of ${qualified_table}."
      return 1
    }
    log_info "[5d] Collision-mode Hop A: distcp will address source via alias 'hdfs://${_dc_src_alias}'"
    log_info "[5d] (not the plain shared name) to keep fs.defaultFS unambiguous -- see this script's"
    log_info "[5d] build_collision_hop_a_distcp_alias_ha_args() for why this is required for distcp"
    log_info "[5d] specifically, even though Spark's own Hop A copier does not need it."
  fi

  # Group rows by target directory (grouping key is the raw directory
  # string itself -- see the _group_file comment below for why). No per-row
  # fork in the loop that builds these groups -- see [5c]'s own PERFORMANCE
  # AT SCALE note for why a per-row `tr` fork does not survive at real scale.
  local group_dir="${copy_list_local%.csv}.distcp-groups"
  rm -rf "${group_dir}"
  mkdir -p "${group_dir}" || {
    log_error "Could not create distcp group-list directory ${group_dir} for ${qualified_table}."
    return 1
  }

  # _group_file[<target-dir>] = <local group-list path>, keyed on the RAW
  # target directory string (not a sanitised one): two distinct directories
  # that only differ in punctuation, e.g. "/data/part=A" and "/data/part_A",
  # must never collapse into the same group -- that would silently copy both
  # directories' files into whichever one's group file happened to be
  # created first. The sanitised form is used ONLY for the on-disk filename
  # (which cannot contain "/"), with a numeric suffix (group index) making it
  # unique regardless of any sanitisation collision.
  local -A _group_file=()
  local -a _group_dirs=()
  local _dc_line _dc_src _dc_tgt _dc_tgtdir _dc_group_file
  local _dc_rows_seen=0
  while IFS= read -r _dc_line; do
    [[ -z "$_dc_line" ]] && continue
    _dc_src="${_dc_line%%,*}"
    _dc_tgt="${_dc_line#*,}"
    [[ -z "$_dc_src" || -z "$_dc_tgt" || "$_dc_src" == "$_dc_line" ]] && continue
    # SRCALIAS rewrite (collision-mode Hop A only, see this function's own
    # $5 parameter comment): swap the plain shared authority for the alias
    # authority so this row's later `hadoop distcp` invocation never has to
    # resolve the plain name through a poisoned fs.defaultFS override.
    # Prefix match only (anchored at the start), not a blanket substring
    # replace -- a source path can legitimately contain the authority
    # string again later (e.g. in a filename), and only the LEADING
    # "hdfs://<authority>" is ever the actual filesystem authority.
    if [[ -n "$collision_src_plain_authority" && "$_dc_src" == "${collision_src_plain_authority}"* ]]; then
      _dc_src="hdfs://${_dc_src_alias}${_dc_src#${collision_src_plain_authority}}"
    fi
    _dc_tgtdir="${_dc_tgt%/*}"
    if [[ -z "${_group_file[$_dc_tgtdir]:-}" ]]; then
      _dc_group_file="${group_dir}/$(( ${#_group_dirs[@]} + 1 ))_${_dc_tgtdir//[^A-Za-z0-9]/_}.list"
      _group_file[$_dc_tgtdir]="$_dc_group_file"
      _group_dirs+=("$_dc_tgtdir")
      : > "${_dc_group_file}"
    fi
    printf '%s\n' "$_dc_src" >> "${_group_file[$_dc_tgtdir]}"
    _dc_rows_seen=$(( _dc_rows_seen + 1 ))
  done < "${copy_list_local}"

  log_info "[5d] Grouped ${_dc_rows_seen} row(s) into ${#_group_dirs[@]} target-directory group(s) for distcp."

  # DISTCP_PRESERVE_OPTS (env var, default "-pugp") - distcp's own preserve
  # flags: user, group, permission. Deliberately NOT "-pt" (modification
  # time) or "-pc" (checksum type) by default -- kept minimal and
  # overridable, same spirit as SPARK_COPIER_EXTRA_ARGS being a free-form
  # escape hatch elsewhere in this script.
  local distcp_preserve_opts="${DISTCP_PRESERVE_OPTS:--pugp}"
  local -a _dc_preserve_args=()
  if [[ -n "$distcp_preserve_opts" ]]; then
    read -ra _dc_preserve_args <<< "$distcp_preserve_opts"
  fi

  # DISTCP_MAPPERS (env var, default "" = distcp's own default, currently 20)
  # - passed as `-m <n>`, the max number of mapper tasks (parallelism) for
  # EACH group's distcp job. Unset by default rather than hardcoding a
  # number: distcp's own default already scales reasonably, and this script
  # cannot know how many groups a given delta will produce ahead of time
  # (mapper count and group count both add parallelism -- setting an
  # aggressive per-job mapper count on a delta that also produces many
  # groups can oversubscribe the cluster). Size it down for a small delta
  # spread across many small partitions, or up for a delta concentrated in
  # very few, very large partitions.
  local -a _dc_mapper_args=()
  if [[ -n "${DISTCP_MAPPERS:-}" ]]; then
    if [[ ! "$DISTCP_MAPPERS" =~ ^[0-9]+$ ]]; then
      log_error "DISTCP_MAPPERS must be a positive integer (got '${DISTCP_MAPPERS}')."
      return 1
    fi
    _dc_mapper_args=(-m "$DISTCP_MAPPERS")
  fi

  # DISTCP_BANDWIDTH_MB (env var, default "" = distcp's own default,
  # unlimited) - passed as `-bandwidth <n>`, per-map bandwidth cap in MB/s.
  # Throttles this job's impact on shared network/cluster bandwidth; unset
  # by default so a caller who wants the throughput of an unthrottled copy
  # gets it without having to know distcp's flag name.
  local -a _dc_bandwidth_args=()
  if [[ -n "${DISTCP_BANDWIDTH_MB:-}" ]]; then
    if [[ ! "$DISTCP_BANDWIDTH_MB" =~ ^[0-9]+$ ]]; then
      log_error "DISTCP_BANDWIDTH_MB must be a positive integer (got '${DISTCP_BANDWIDTH_MB}')."
      return 1
    fi
    _dc_bandwidth_args=(-bandwidth "$DISTCP_BANDWIDTH_MB")
  fi

  # DISTCP_QUEUE (env var, default "" = whatever queue this host's own
  # mapred-site.xml/YARN defaults resolve to) - passed as
  # `-D mapreduce.job.queuename=<queue>`, the YARN scheduler queue each
  # group's distcp MapReduce job is submitted to. Useful for routing DR
  # copy traffic into a dedicated queue rather than the default one shared
  # with other cluster workloads.
  local -a _dc_queue_args=()
  if [[ -n "${DISTCP_QUEUE:-}" ]]; then
    _dc_queue_args=(-D "mapreduce.job.queuename=${DISTCP_QUEUE}")
  fi

  # DISTCP_EXTRA_ARGS (env var, default "") - free-form escape hatch for any
  # other distcp flag this script does not surface a dedicated knob for
  # (e.g. "-atomic -skipcrccheck"), same spirit as SPARK_COPIER_EXTRA_ARGS
  # elsewhere in this script. Split on whitespace only, so a value with an
  # embedded space cannot be expressed this way.
  local -a _dc_extra_args=()
  if [[ -n "${DISTCP_EXTRA_ARGS:-}" ]]; then
    read -ra _dc_extra_args <<< "$DISTCP_EXTRA_ARGS"
  fi

  # TOKEN-RENEWAL EXCLUSION. distcp submits its OWN MapReduce job to YARN,
  # independent of SPARK_RUN_MODE/SPARK_MASTER (there is no "local mode" for
  # distcp -- it always goes through whatever mapreduce.framework.name this
  # host's own Hadoop client config resolves, which on a real cluster is
  # "yarn"). Without SOME exclusion, distcp's own delegation token(s) for the
  # far nameservice can hit the identical
  #   YarnException: Failed to submit application ... Failed to renew token
  # class of failure this script fixed for Spark -- ResourceManager tries to renew a
  # token against a nameservice name it has no configuration for, or that
  # its own un-overridden hdfs-site.xml resolves to the WRONG physical
  # cluster (the shared name in collision mode).
  #
  # NOT A VERIFIED FIX, UNLIKE THE SPARK SIDE. The property below
  # (mapreduce.job.hdfs-servers.token-renewal.exclude) is MapReduce's own
  # renewal-exclusion knob (MRJobConfig.JOB_HDFS_SERVERS_TOKEN_RENEWAL_EXCLUDE)
  # -- it is NOT the same mechanism as Spark's fix, and is not a "mirror" of
  # it: the DELEGATION-TOKEN CONFS block (near resolve_active_namenode_hostport's
  # declaration) explicitly found the Spark-side equivalent of this exact
  # property name (spark.hadoop.mapreduce.job.hdfs-servers.token-renewal.exclude)
  # to be IGNORED by this cluster's ResourceManager, and had to switch to
  # spark.yarn.kerberos.renewal.excludeHadoopFileSystems instead -- a
  # Spark-YARN-client-only property with no distcp/MapReduce equivalent. distcp
  # has no other client-side exclusion flag to fall back to, so this is what is
  # set, but it has NOT been confirmed effective on this cluster's ResourceManager
  # the same way the Spark-side fix was (no verified application ID on record for
  # it). If a distcp run hits "Failed to renew token" despite this flag being
  # present, that lack of verification is the first thing to suspect.
  #
  # The two identities to exclude are the two authorities this call's own
  # distcp invocation will actually resolve: for the normal (non-collision)
  # path, SRC_NAMESERVICE and DST_NAMESERVICE as-is. For collision-mode
  # Hop A (collision_src_plain_authority set, see this function's $5
  # parameter), the SRCALIAS name replaces the plain shared name as the
  # "source" identity -- the plain name is deliberately NEVER passed to
  # this specific distcp invocation (see build_collision_hop_a_distcp_alias_ha_args()'s
  # header for why), so excluding it here would be excluding an authority
  # this call never actually uses. Every OTHER collision-mode caller of
  # this function (Hop B, which has no $5) keeps the pre-existing
  # DST_NAMESERVICE-vs-resolved-active-NameNode pair unchanged.
  local _dc_tok_ns_a="${SRC_NAMESERVICE}" _dc_tok_ns_b="${DST_NAMESERVICE}"
  if [[ -n "$collision_src_plain_authority" ]]; then
    _dc_tok_ns_a="${_dc_src_alias}"
    _dc_tok_ns_b=$(resolve_active_namenode_hostport "$DST_NN_HOSTS") || {
      log_error "Could not resolve destination's active NameNode for distcp's token-renewal exclusion."
      return 1
    }
  elif [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    _dc_tok_ns_a="${DST_NAMESERVICE}"
    _dc_tok_ns_b=$(resolve_active_namenode_hostport "$DST_NN_HOSTS") || {
      log_error "Could not resolve destination's active NameNode for distcp's token-renewal exclusion."
      return 1
    }
  fi
  local -a _dc_token_exclude_args=(-D "mapreduce.job.hdfs-servers.token-renewal.exclude=${_dc_tok_ns_a},${_dc_tok_ns_b}")

  # DISTCP_PARALLEL_JOBS (env var, default 1) - how many of this table's
  # per-target-directory distcp groups run at once. Default 1 preserves
  # fully serial submission (today's safe, previously-verified behavior:
  # one MapReduce job in flight at a time) -- same default-1-means-serial
  # convention as PARALLEL_TABLES elsewhere in this script. A bootstrap
  # touching many partitions produces many groups (82 groups for one
  # 3035-file bootstrap on this DR pair -- see this function's own header
  # comment); each group is a full YARN application submission, and running
  # them one at a time makes bootstrap's wall-clock time scale with group
  # COUNT, not just group size. Raise this to submit more than one at once.
  #
  # Bounded concurrency via a counted `wait -n` (bash 4.3+), the exact same
  # pattern PARALLEL_TABLES uses to cap concurrent table jobs -- see that
  # dispatcher's own header comment for the full rationale (a background
  # job cannot set a variable this function's shell sees, so each job
  # writes its own small result file instead, read back after `wait`).
  local distcp_parallel_jobs="${DISTCP_PARALLEL_JOBS:-1}"
  if [[ ! "$distcp_parallel_jobs" =~ ^[1-9][0-9]*$ ]]; then
    log_error "DISTCP_PARALLEL_JOBS must be a positive integer (got '${distcp_parallel_jobs}')."
    return 1
  fi

  local _dc_group_idx=0 _dc_running=0
  local _dc_tgtdir2 _dc_group_log _dc_result_file
  for _dc_tgtdir2 in "${_group_dirs[@]}"; do
    _dc_group_idx=$(( _dc_group_idx + 1 ))
    _dc_group_file="${_group_file[$_dc_tgtdir2]}"
    _dc_group_log="${_dc_group_file%.list}.distcp.out"
    _dc_result_file="${_dc_group_file%.list}.distcp.result"

    (
      # PROPAGATE INTERRUPTS INTO THIS BACKGROUND JOB. A job started with
      # `&` is, by standard bash/POSIX job-control behavior, IMMUNE to a
      # terminal-generated SIGINT -- that immunity exists deliberately, so
      # pressing Ctrl+C in an interactive shell doesn't kill work you
      # intentionally backgrounded. It means the top-level interrupt trap
      # (see _on_interrupt near the top of this script) killing this
      # script's own process GROUP does NOT reach a `hadoop distcp` (or its
      # own child MapReduce/YARN submission) running inside this subshell --
      # confirmed in practice: an interrupted run left exactly this kind of
      # backgrounded distcp job running for 15+ minutes after the parent
      # script had already returned control to the terminal, still holding
      # this table's per-table flock lock. Trapping INT/TERM HERE, inside
      # the job itself, and killing THIS subshell's own process group in
      # response, closes that gap: the outer _on_interrupt's
      # `kill -TERM -- -$$` still reaches this subshell (both share the
      # same PGID as the parent script, since neither installs its own
      # session/process group), which now runs this trap instead of
      # silently ignoring the signal.
      trap 'printf "signal_interrupted %s\n" "${_this_count:-0}" > "${_dc_result_file}"; kill -TERM -- -$BASHPID 2>/dev/null; exit 130' INT TERM
      _this_count=$(awk 'END{print NR}' "${_dc_group_file}" | tr -d '[:space:]')
      # Ensure the target directory exists before distcp -f writes into it --
      # distcp does not create a missing target directory implicitly from a
      # -f source list the way `hadoop fs -put` treats an existing directory
      # target.
      if ! run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir -p "${_dc_tgtdir2}" > "${_dc_group_log}" 2>&1; then
        printf 'mkdir_failed %s\n' "${_this_count}" > "${_dc_result_file}"
        exit 0
      fi
      # HDFS_HA_ARGS and _dc_token_exclude_args spliced in right after
      # "distcp" (same -D generic-options form already used for the plain
      # `hadoop fs` calls above -- distcp goes through the same
      # GenericOptionsParser). run_as_hdfs (not run_as_spark_user): this is
      # a plain `hadoop` CLI process, same identity as the other hadoop fs
      # calls in this script, not a Spark job -- but it DOES submit its own
      # YARN application, which is exactly why _dc_token_exclude_args (see
      # its own comment above) is required here and not just on the Spark
      # copier's path.
      _job_rc=0
      # Build the distcp command ONCE as an array, then both print it (live,
      # to fd2/console -- without this the command itself is invisible until
      # this group's whole possibly-long-running job finishes and its
      # captured log is flushed to console down at [5d]'s own reporting
      # loop) and execute it FROM THE SAME ARRAY, so the two can never
      # diverge the way two separately-written invocations could if only one
      # were edited later. Printed once per group, from inside this
      # background job, so DISTCP_PARALLEL_JOBS>1 still shows each group's
      # command as that group actually starts, not batched at the end.
      #
      # SRCALIAS HA args (${_dc_alias_ha_args[@]}) replace the plain
      # HDFS_HA_ARGS here ONLY for collision-mode Hop A calls (see this
      # function's $5 parameter and build_collision_hop_a_distcp_alias_ha_args()
      # for the full "why"): using the caller's global HDFS_HA_ARGS here
      # would redirect the plain shared name for this distcp job too,
      # making fs.defaultFS ambiguous and breaking AM container
      # localization of mapreduce.tar.gz -- confirmed by direct testing.
      # Every group's source rows were already rewritten to the alias
      # authority above, so this flag set must match.
      if [[ -n "$collision_src_plain_authority" ]]; then
        _dc_cmd=(hadoop distcp "${_dc_alias_ha_args[@]}" "${_dc_token_exclude_args[@]}" "${_dc_queue_args[@]}"
          "${_dc_preserve_args[@]}" "${_dc_mapper_args[@]}" "${_dc_bandwidth_args[@]}" "${_dc_extra_args[@]}"
          -update -f "file://${_dc_group_file}" "${_dc_tgtdir2}")
      else
        _dc_cmd=(hadoop distcp "${HDFS_HA_ARGS[@]}" "${_dc_token_exclude_args[@]}" "${_dc_queue_args[@]}"
          "${_dc_preserve_args[@]}" "${_dc_mapper_args[@]}" "${_dc_bandwidth_args[@]}" "${_dc_extra_args[@]}"
          -update -f "file://${_dc_group_file}" "${_dc_tgtdir2}")
      fi
      print_cmd_pretty "${_dc_cmd[@]}" >&2
      run_as_hdfs "${_dc_cmd[@]}" >> "${_dc_group_log}" 2>&1 || _job_rc=$?
      if [[ $_job_rc -ne 0 ]]; then
        printf 'distcp_failed %s\n' "${_this_count}" > "${_dc_result_file}"
      else
        printf 'ok %s\n' "${_this_count}" > "${_dc_result_file}"
      fi
    ) &
    _dc_running=$(( _dc_running + 1 ))
    if [[ "$_dc_running" -ge "$distcp_parallel_jobs" ]]; then
      wait -n
      _dc_running=$(( _dc_running - 1 ))
    fi
  done
  # Drain whatever is still running after the last group was dispatched.
  wait

  local _dc_copied=0 _dc_failed=0
  local _dc_status _dc_this_count
  _dc_group_idx=0
  for _dc_tgtdir2 in "${_group_dirs[@]}"; do
    _dc_group_idx=$(( _dc_group_idx + 1 ))
    _dc_group_file="${_group_file[$_dc_tgtdir2]}"
    _dc_group_log="${_dc_group_file%.list}.distcp.out"
    _dc_result_file="${_dc_group_file%.list}.distcp.result"

    log_info "[5d] distcp group ${_dc_group_idx}/${#_group_dirs[@]}: -> ${_dc_tgtdir2}"
    [[ -f "${_dc_group_log}" ]] && indent_output < "${_dc_group_log}"

    if [[ ! -f "${_dc_result_file}" ]]; then
      log_error "No result recorded for distcp group ${_dc_group_idx}/${#_group_dirs[@]} (target ${_dc_tgtdir2}) of ${qualified_table} -- its background job did not report back."
      _dc_this_count=$(awk 'END{print NR}' "${_dc_group_file}" | tr -d '[:space:]')
      _dc_failed=$(( _dc_failed + _dc_this_count ))
      continue
    fi
    read -r _dc_status _dc_this_count < "${_dc_result_file}"
    case "$_dc_status" in
      ok)
        _dc_copied=$(( _dc_copied + _dc_this_count ))
        ;;
      mkdir_failed)
        log_error "Could not create target directory ${_dc_tgtdir2} for ${qualified_table} (distcp group ${_dc_group_idx}/${#_group_dirs[@]})."
        _dc_failed=$(( _dc_failed + _dc_this_count ))
        ;;
      signal_interrupted)
        log_error "distcp group ${_dc_group_idx}/${#_group_dirs[@]} (target ${_dc_tgtdir2}) of ${qualified_table} was interrupted"
        log_error "(SIGINT/SIGTERM) mid-copy -- re-run to retry this group; -update makes it safe to resume."
        _dc_failed=$(( _dc_failed + _dc_this_count ))
        ;;
      *)
        log_error "distcp failed for group ${_dc_group_idx}/${#_group_dirs[@]} (target ${_dc_tgtdir2}) of ${qualified_table}."
        _dc_failed=$(( _dc_failed + _dc_this_count ))
        ;;
    esac
  done

  log_info "[5d] distcp copier finished: ${#_group_dirs[@]} group(s), ${_dc_copied} file(s) OK, ${_dc_failed} file(s) failed (of ${_dc_rows_seen})."

  # Export statistics to parent scope for STEP 8 summary (if variables exist)
  [[ -v FILES_COPIED ]] && FILES_COPIED=${_dc_copied}
  [[ -v FILES_SKIPPED ]] && FILES_SKIPPED=0  # distcp doesn't track skipped separately
  [[ -v FILES_FAILED ]] && FILES_FAILED=${_dc_failed}

  if [[ "$_dc_failed" -ne 0 ]]; then
    log_error "distcp copier failed for ${qualified_table} (${_dc_failed} file(s) across one or more groups)."
    return 1
  fi

  if [[ -n "$expected_rows" && "$_dc_rows_seen" != "$expected_rows" ]]; then
    log_error "distcp copier processed ${_dc_rows_seen} row(s) but this run staged ${expected_rows} for ${qualified_table}."
    return 1
  fi
  return 0
}

# run_copy_engine: dispatch STEP 5's file copy to either the Spark copier or
# the distcp copier, based on COPY_ENGINE (see its own declaration near
# STAGING_ROOT for the full tradeoff writeup). Same 4-argument signature as
# both engines, so every call site stays engine-agnostic.
run_copy_engine() {
  case "$COPY_ENGINE" in
    distcp) run_distcp_copier "$@" ;;
    *)      run_spark_copier "$@" ;;
  esac
}

########################################
# run_collision_metadata_patch_job: batch-patch a list of metadata.json
# ancestor files in ONE Spark job (one JVM, many parallel tasks), instead of
# one `hadoop fs -cat` / `sed` / `-put` triplet PER FILE forked serially from
# bash. See the SAME-NAMESERVICE COLLISION patch step (its call site, right
# before hop A's temp-register) for the full rationale: each metadata.json is
# small text, but on this table's first-ever run under the high-water-mark
# scheme above, the file COUNT itself can be enormous (every ancestor commit
# the table has ever had), and thousands-to-millions of sequential JVM forks
# would dominate the whole replication run by itself.
#
# Arguments: any number of absolute hdfs:// file paths, then a literal "--",
# then: the plain substring to replace, the resolved bare-host substring to
# replace it with, and a qualified-table name (for logging only).
#
# Each task reads its files' full text (they are small JSON documents, never
# large), does the identical plain-substring -> bare-host-substring
# replacement `sed` did, and writes back ONLY if the content actually
# changed -- a no-op file (already correct, or never had the plain prefix at
# all) costs one read and zero writes, same as before.
########################################
run_collision_metadata_patch_job() {
  local -a _patch_files=()
  local _from _to _qualified_table
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    _patch_files+=("$1")
    shift
  done
  shift # drop the "--" separator
  _from="$1"; _to="$2"; _qualified_table="$3"

  if [[ ${#_patch_files[@]} -eq 0 ]]; then
    return 0
  fi

  local patch_list_local
  patch_list_local=$(mktemp) || {
    log_error "Could not create a temp file listing metadata.json files to patch for ${_qualified_table}."
    return 1
  }
  printf '%s\n' "${_patch_files[@]}" > "${patch_list_local}"

  local patch_list_hdfs
  patch_list_hdfs="${STAGING_ROOT}${TABLE_RELATIVE_PATH}-collision-patch-list/$(date +%Y%m%d_%H%M%S).txt"
  local patch_list_hdfs_dir="${patch_list_hdfs%/*}"
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir -p "${patch_list_hdfs_dir}" && \
    run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -put -f "${patch_list_local}" "${patch_list_hdfs}" || {
    log_error "Could not stage the metadata.json patch list at ${patch_list_hdfs} for ${_qualified_table}."
    rm -f "${patch_list_local}"
    return 1
  }

  local scala_script="${patch_list_local}.scala"
  local patch_result="${patch_list_local}.result"
  rm -f "${patch_result}"
  # Unquoted heredoc: ${patch_list_hdfs}/${patch_result}/${_from}/${_to} are
  # substituted by bash. Neither ${_from} nor ${_to} can contain a literal
  # double-quote (both are always "hdfs://<name>/", built from validated
  # nameservice strings elsewhere in this script), so embedding them as Scala
  # string literals here is safe.
  cat > "${scala_script}" <<SCALA_EOF
import org.apache.hadoop.conf.Configuration
import org.apache.hadoop.fs.Path
import org.apache.hadoop.io.IOUtils
import scala.collection.JavaConverters._

val listPath = "${patch_list_hdfs}"
val resultPath = "${patch_result}"
val fromStr = "${_from}"
val toStr = "${_to}"

val hconf = spark.sparkContext.hadoopConfiguration
val confPairs = hconf.iterator().asScala
  .map(e => (e.getKey, e.getValue))
  .filter(kv => kv._1.startsWith("dfs.") || kv._1.startsWith("fs.") || kv._1.startsWith("hadoop.") || kv._1.startsWith("ipc."))
  .toMap
val bconf = spark.sparkContext.broadcast(confPairs)

val paths = spark.sparkContext.textFile(listPath).filter(_.nonEmpty)

val perPartition = paths.mapPartitions { it =>
  val conf = new Configuration()
  bconf.value.foreach(kv => conf.set(kv._1, kv._2))
  var patched = 0L
  var unchanged = 0L
  var failed = 0L
  val msgs = new scala.collection.mutable.ArrayBuffer[String]()
  it.foreach { p =>
    try {
      val fp = new Path(p)
      val fs = fp.getFileSystem(conf)
      val in = fs.open(fp)
      val baos = new java.io.ByteArrayOutputStream()
      try { IOUtils.copyBytes(in, baos, conf, false) } finally { in.close() }
      val original = new String(baos.toByteArray, "UTF-8")
      val rewritten = original.replace(fromStr, toStr)
      if (rewritten != original) {
        val out = fs.create(fp, true)
        try { out.write(rewritten.getBytes("UTF-8")) } finally { out.close() }
        patched += 1
      } else {
        unchanged += 1
      }
    } catch {
      case t: Throwable =>
        failed += 1
        if (msgs.size < 20) msgs += (p + " : " + String.valueOf(t.getMessage))
    }
  }
  Iterator((patched, unchanged, failed, msgs.toArray))
}.collect()

val patched = perPartition.map(r => r._1).sum
val unchanged = perPartition.map(r => r._2).sum
val failed = perPartition.map(r => r._3).sum
val failureLines = perPartition.flatMap(r => r._4).take(50)
val summary = "ICEBERG_PATCH_RESULT patched=" + patched + " unchanged=" + unchanged + " failed=" + failed

val pw = new java.io.PrintWriter(new java.io.File(resultPath))
try {
  failureLines.foreach(m => pw.println("ICEBERG_PATCH_FAILURE " + m))
  pw.println(summary)
} finally {
  pw.close()
}
failureLines.foreach(m => println("ICEBERG_PATCH_FAILURE " + m))
println(summary)
System.exit(if (failed > 0L) 1 else 0)
SCALA_EOF

  local -a _patch_executor_args=()
  build_executor_sizing_args _patch_executor_args \
    "${SPARK_COPIER_EXECUTOR_CORES}" "${SPARK_COPIER_EXECUTOR_MEMORY}" \
    "${SPARK_COPIER_DYNAMIC_ALLOCATION}" "${SPARK_COPIER_MAX_EXECUTORS}" \
    "${SPARK_MASTER}"

  local spark_cmd=(spark-shell
    --master "${SPARK_MASTER}"
    "${SPARK_YARN_ARGS[@]}"
    "${HA_CONF_ARGS[@]}"
    "${_patch_executor_args[@]}"
    --name "iceberg-repl-metadata-patch-${_qualified_table}"
    -i "${scala_script}")

  log_info "Running Spark metadata-patch job for ${#_patch_files[@]} file(s):"
  print_cmd_pretty "${spark_cmd[@]}"

  local patch_log="${patch_list_local}.out"
  local _rc=0
  run_as_spark_user "${spark_cmd[@]}" < /dev/null > "${patch_log}" 2>&1 || _rc=$?
  indent_output < "${patch_log}"

  local result_line=""
  if [[ -s "${patch_result}" ]]; then
    result_line=$(grep -a "^ICEBERG_PATCH_RESULT " "${patch_result}" 2>/dev/null | tail -n 1) || true
  fi
  if [[ -z "$result_line" ]]; then
    result_line=$(grep -a "^ICEBERG_PATCH_RESULT " "${patch_log}" 2>/dev/null | tail -n 1) || true
  fi
  # patch_list_local/patch_list_hdfs are never referenced in a later log
  # message, so they're safe to clean up immediately. scala_script IS
  # referenced below in the "no result line" error -- deleting it here,
  # before that check, used to point an operator at a file this function
  # had already removed one line earlier. Kept alive until after every
  # message that names it (deleted alongside patch_result/patch_log
  # further below instead).
  rm -f "${patch_list_local}"
  run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -rm -f -skipTrash "${patch_list_hdfs}" >/dev/null 2>&1 || true

  if [[ -z "$result_line" ]]; then
    log_error "Spark metadata-patch job for ${_qualified_table} produced no ICEBERG_PATCH_RESULT line (exit ${_rc})."
    log_error "Full output is above; the script it ran is at ${scala_script}"
    rm -f "${scala_script}"
    return 1
  fi

  local _p_patched _p_unchanged _p_failed
  _p_patched="${result_line#*patched=}"; _p_patched="${_p_patched%% *}"
  _p_unchanged="${result_line#*unchanged=}"; _p_unchanged="${_p_unchanged%% *}"
  _p_failed="${result_line#*failed=}"; _p_failed="${_p_failed%% *}"

  local _fail_src="${patch_log}"
  [[ -s "${patch_result}" ]] && _fail_src="${patch_result}"
  local _fail_line
  while IFS= read -r _fail_line; do
    [[ -z "$_fail_line" ]] && continue
    log_error "  ${_fail_line#ICEBERG_PATCH_FAILURE }"
  done < <(grep -a "^ICEBERG_PATCH_FAILURE " "${_fail_src}" 2>/dev/null || true)
  rm -f "${patch_result}" "${patch_log}" "${scala_script}"

  log_info "Metadata-patch job finished: ${_p_patched} patched, ${_p_unchanged} already correct, ${_p_failed} failed."

  if [[ "$_p_failed" != "0" || $_rc -ne 0 ]]; then
    log_error "Spark metadata-patch job failed for ${_qualified_table} (${_p_failed} file(s) failed, exit ${_rc})."
    return 1
  fi
  return 0
}

########################################
# fix_puffin_stats_and_build_copy_list: normalizes a raw rewrite_table_path
# file-list CSV into a (source,target) copy list, working around the KNOWN
# UPSTREAM ICEBERG BUG (1.9.0/1.9.1/1.9.2, fixed in 1.10.0 -- see the [5b]
# call site below for the full bug writeup) where a Puffin statistics file is
# LISTED in the CSV's stats/ rows but never actually STAGED. Extracted out of
# the original inline [5b]/[5c] block (which only ever ran for the normal,
# non-collision STEP 4/5) so the SAME-NAMESERVICE COLLISION path's hop A and
# hop B can call it too -- each hop runs its OWN rewrite_table_path, so each
# is independently exposed to this exact bug for any table carrying Iceberg
# table statistics, and hop A's copier previously had NO recovery for it at
# all (any stats file made hop A's copy -- and therefore the whole table --
# fail every single run, since run_spark_copier treats one failed file as
# fatal for the table).
#
# Every location/prefix this hop actually used for ITS OWN rewrite_table_path
# call is passed in explicitly rather than assumed from the (normal-path-only)
# globals SRC_PREFIX/DST_PREFIX/DST_NAMESERVICE/STAGING_DIR, since hop A and
# hop B each use a DIFFERENT source/target prefix pair (see "SAME-NAMESERVICE
# COLLISION" in this script's header) and neither matches the normal path's.
#
# Arguments:
#   $1 local_file_list    - the raw file-list CSV already read to local disk
#   $2 staged_stats_dir    - fully-qualified hdfs:// dir where THIS hop's own
#                            staging_location would have put stats files if
#                            the upstream bug did not exist
#   $3 real_stats_dir      - fully-qualified hdfs:// dir where the REAL,
#                            un-staged stats file bytes actually live for
#                            THIS hop (the "before.path()" location)
#   $4 hop_target_prefix   - the target_prefix THIS hop's own rewrite_table_path
#                            call used, stripped from a row's target column to
#                            recover its relative path when redirecting
#   $5 real_source_prefix  - prefix substituted in place of hop_target_prefix
#                            when redirecting a recovered row to real_stats_dir
#   $6 scheme_less_prefix  - prefix ("hdfs://<name>", no trailing slash) for
#                            any bare/scheme-less SOURCE entry in THIS hop's
#                            own file list (rewrite_table_path does not
#                            consistently qualify every row -- see [5b]/[5c]
#                            below for why)
#   $7 out_copy_list       - where to write the normalized (source,target) CSV
#
# Sets (not `local` -- read by the caller immediately after this returns):
#   PUFFIN_FIX_ROW_COUNT (final copy-list row count, after skips)
########################################
fix_puffin_stats_and_build_copy_list() {
  local _local_file_list="$1"
  local _staged_stats_dir="$2"
  local _real_stats_dir="$3"
  local _hop_target_prefix="$4"
  local _real_source_prefix="$5"
  local _scheme_less_prefix="$6"
  local _out_copy_list="$7"

  local -A _STATS_ROW_OVERRIDE=()
  local -i _stats_row_count=0 _stats_recovered=0 _stats_missing=0
  local -a _stats_rows=()
  mapfile -t _stats_rows < <(awk -F',' 'index($2, "/stats/") { print $1 "\t" $2 }' "${_local_file_list}")
  _stats_row_count=${#_stats_rows[@]}

  local _t0 _elapsed
  _t0=$(date +%s)
  if (( _stats_row_count > 0 )); then
    # Two batched `-ls` calls total, no matter whether there are 3 stats
    # files or 3,000 -- see the [5b] call site's PERFORMANCE note for why a
    # per-row check is not survivable at real scale.
    local -A _STAGED_STATS_BASENAMES=()
    local _listing _ls_line _bn
    _listing=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -ls "${_staged_stats_dir}" 2>/dev/null) || true
    while IFS= read -r _ls_line; do
      [[ "$_ls_line" == -* ]] || continue
      _bn="${_ls_line##*/}"
      [[ -n "$_bn" ]] && _STAGED_STATS_BASENAMES["$_bn"]=1
    done <<< "$_listing"

    local -A _SRC_STATS_BASENAMES=()
    local _row _row_src _row_tgt _need_source_listing=false
    for _row in "${_stats_rows[@]}"; do
      _bn="${_row%%$'\t'*}"; _bn="${_bn##*/}"
      if [[ -z "${_STAGED_STATS_BASENAMES[$_bn]:-}" ]]; then
        _need_source_listing=true
        break
      fi
    done
    if [[ "$_need_source_listing" == "true" ]]; then
      _listing=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -ls "${_real_stats_dir}" 2>/dev/null) || true
      while IFS= read -r _ls_line; do
        [[ "$_ls_line" == -* ]] || continue
        _bn="${_ls_line##*/}"
        [[ -n "$_bn" ]] && _SRC_STATS_BASENAMES["$_bn"]=1
      done <<< "$_listing"
    fi

    local _direct
    for _row in "${_stats_rows[@]}"; do
      _row_src="${_row%%$'\t'*}"
      _row_tgt="${_row#*$'\t'}"
      _bn="${_row_src##*/}"
      [[ -n "${_STAGED_STATS_BASENAMES[$_bn]:-}" ]] && continue
      if [[ -n "${_SRC_STATS_BASENAMES[$_bn]:-}" ]]; then
        _direct="${_real_source_prefix}${_row_tgt#"${_hop_target_prefix}"}"
        log_info "Stats file not staged by rewrite_table_path (expected on Iceberg 1.9.x); copying it directly from source: ${_direct}"
        _STATS_ROW_OVERRIDE["$_row_src"]="$_direct"
        _stats_recovered=$((_stats_recovered + 1))
      else
        log_warn "Source file not found on staging OR source cluster, skipping: ${_row_src}"
        _STATS_ROW_OVERRIDE["$_row_src"]="__SKIP__"
        _stats_missing=$((_stats_missing + 1))
      fi
    done
  fi
  _elapsed=$(( $(date +%s) - _t0 ))
  log_info "[Puffin-stats check] ${_stats_row_count} stats/ row(s) via at most 2 batched listing(s) (${_stats_recovered} recovered, ${_stats_missing} missing) in $(format_duration "$_elapsed")."

  # Single awk pass over the WHOLE file list, replacing a per-row bash
  # `while read` loop. A bash `read` loop's throughput (one fork-free but
  # still per-line shell dispatch, string tests, and arithmetic) is far
  # below a single awk program's for a pure text transform like this one
  # -- fine at thousands of rows, but a real, multi-minute bottleneck for
  # a table with millions of files (continuous-write tables are called
  # out elsewhere in this script as a real scenario, not a hypothetical
  # one). _STATS_ROW_OVERRIDE (bash associative array, built above) is
  # handed to awk via a small serialized file rather than shell-expanded
  # into the awk program text -- correct regardless of how many entries
  # it has (a shell-expanded --v/text form would need one -v per entry, or
  # risk overflowing a single -v's practical size at real scale).
  PUFFIN_FIX_ROW_COUNT=0
  local -i _sp_skipped=0
  local _override_file
  _override_file=$(mktemp) || {
    log_error "Could not create a temp file for the Puffin-stats override map (building copy list at ${_out_copy_list})."
    return 1
  }
  local _ov_key
  for _ov_key in "${!_STATS_ROW_OVERRIDE[@]}"; do
    printf '%s\t%s\n' "${_ov_key}" "${_STATS_ROW_OVERRIDE[$_ov_key]}"
  done > "${_override_file}"

  rm -f "${_out_copy_list}"
  local _awk_summary _awk_rc=0
  _awk_summary=$(awk -F',' -v override_file="${_override_file}" -v scheme_prefix="${_scheme_less_prefix}" -v outfile="${_out_copy_list}" '
    BEGIN {
      while ((getline line < override_file) > 0) {
        n = split(line, parts, "\t")
        override[parts[1]] = (n >= 2) ? parts[2] : ""
      }
      close(override_file)
    }
    {
      src = $1
      # Rejoin every field after the first with "," -- matches the bash
      # `IFS="," read -r src tgt` semantics this replaces exactly: with
      # more than 2 comma-separated fields, the LAST variable absorbs the
      # remainder of the line, embedded commas and all.
      tgt = $2
      for (i = 3; i <= NF; i++) { tgt = tgt "," $i }
      if (src == "" || tgt == "") { next }
      if (src in override) {
        if (override[src] == "__SKIP__") { skipped++; next }
        src = override[src]
      } else if (index(src, "://") == 0) {
        s = src
        sub(/^\//, "", s)
        src = scheme_prefix "/" s
      }
      print src "," tgt >> outfile
      written++
    }
    END {
      print (written + 0) " " (skipped + 0)
    }
  ' "${_local_file_list}") || _awk_rc=$?
  rm -f "${_override_file}"

  # A failed normalization must never be read as "0 rows to copy": the caller
  # would skip the copy and go straight on to registering/repointing the
  # destination at metadata whose files were never copied. The summary line
  # is the awk program's own last output, so its absence means the pass did
  # not run to completion.
  if [[ $_awk_rc -ne 0 || ! "$_awk_summary" =~ ^[0-9]+\ [0-9]+$ ]]; then
    log_error "Could not build the copy list at ${_out_copy_list} from ${_local_file_list} (awk exit ${_awk_rc})."
    return 1
  fi

  PUFFIN_FIX_ROW_COUNT="${_awk_summary%% *}"
  _sp_skipped="${_awk_summary#* }"
  [[ "$PUFFIN_FIX_ROW_COUNT" =~ ^[0-9]+$ ]] || PUFFIN_FIX_ROW_COUNT=0
  [[ "$_sp_skipped" =~ ^[0-9]+$ ]] || _sp_skipped=0

  if [[ "$_stats_recovered" -gt 0 ]]; then
    log_info "Recovered ${_stats_recovered} file(s) directly from source (not staged by rewrite_table_path)."
  fi
  if [[ "$_sp_skipped" -gt 0 ]]; then
    log_info "Skipped ${_sp_skipped} file(s) not found in staging or on source (see WARN lines above)."
  fi
}

# spark_sql_scalar: run a single-value SELECT through run_spark_sql and echo
# just the result, with spark-sql's own chatter (JVM/log4j banners, the
# Spark UI/master lines, this script's "Running spark-sql:" preamble and
# its INDENT-prefixed command echo, the trailing "Time taken" line) stripped
# off. The value is the LAST surviving line.
#
# Returns non-zero ONLY when run_spark_sql itself failed. An empty result is
# a legitimate outcome for some callers, so the filtering pipeline must not
# be allowed to decide this function's exit status: piping through `grep -v`
# means grep exits 1 once every line has been filtered out (its documented
# "no lines selected" status), which under `pipefail` would turn a valid
# empty result into an error indistinguishable from a real spark-sql
# failure. The trailing `|| true` pins the status to run_spark_sql's alone.
spark_sql_scalar() {
  local metastore_uri="$1"
  local query="$2"
  local query_output
  query_output=$(run_spark_sql "${metastore_uri}" "${query}") || return 1
  echo "${query_output}" | grep -v "^Time taken" | grep -v "^Setting default log level" | grep -v "^To adjust logging" | grep -v "^Spark Web UI" | grep -v "^Spark master" | grep -v "Running spark-sql:" | grep -v "^  " | grep -v "^$" | tail -n 1 | tr -d '[:space:]' || true
}

# version_ge: numeric dotted-version comparison, "is $1 >= $2". Compares the
# first three components only, so a vendor-suffixed build string
# ("1.11.0.7.3.1", "1.11.0-odp-1") still compares correctly against a plain
# "1.11.0". A plain string/lexical compare cannot be used here: "1.9.1" >
# "1.11.0" lexically, but 1.9.1 is the OLDER release.
version_ge() {
  local -a lhs rhs
  local i lhs_part rhs_part lhs_num rhs_num
  IFS='.' read -r -a lhs <<< "${1%%-*}"
  IFS='.' read -r -a rhs <<< "${2%%-*}"
  for ((i = 0; i < 3; i++)); do
    # Strip any non-digit residue before arithmetic: an unparseable or
    # missing component is treated as 0 rather than aborting the script
    # under `set -e` on a bad $((10#...)) expansion.
    lhs_part="${lhs[i]:-0}"; lhs_part="${lhs_part//[!0-9]/}"
    rhs_part="${rhs[i]:-0}"; rhs_part="${rhs_part//[!0-9]/}"
    lhs_num=$((10#${lhs_part:-0}))
    rhs_num=$((10#${rhs_part:-0}))
    # `set -e` safe: a failing (( )) here is the LEFT operand of an && list,
    # and the shell only exits on the final command of such a list. Verified
    # rather than assumed -- see the note on set -e in the header block.
    ((lhs_num > rhs_num)) && return 0
    ((lhs_num < rhs_num)) && return 1
  done
  return 0
}

# probe_iceberg_runtime_version: determine the Iceberg version actually on
# spark-sql's classpath and leave it in the ICEBERG_RUNTIME_VERSION global
# (empty string = could not be determined).
#
# Read via Spark SQL's built-in `reflect()`, which invokes a static method
# and is the only in-band way to ask the running JVM this. Iceberg's
# org.apache.iceberg.IcebergBuild.version() is a public, no-arg static
# returning a String (it self-initialises from the jar's own
# /iceberg-build.properties), which is exactly what reflect() supports.
# Deliberately NOT derived from a jar filename on disk: the runtime jar may
# be shaded into the Spark distribution with no version in its name, and on
# this ODP build Iceberg comes off Spark's default classpath rather than
# from ICEBERG_SPARK_JAR at all.
#
# MUST be invoked as a bare statement, never as "$(probe_...)". The whole
# point of ICEBERG_RUNTIME_VERSION_PROBED is to launch this JVM at most once
# per run, and a command substitution runs the function in a SUBSHELL whose
# assignments are discarded the moment it exits -- the cache flag would
# never stick and every caller would pay for another spark-sql launch. Read
# the result from $ICEBERG_RUNTIME_VERSION afterwards.
#
# That in-memory cache flag ALSO does not survive across tables by itself:
# every table's replication runs inside its own `( ... )` subshell (see
# replicate_one_table()'s flock wrapper), forked fresh from this same
# still-unprobed parent each time, so the in-memory flag alone would still
# mean paying for a fresh spark-sql launch on every v3 table, not just once
# per run. ICEBERG_RUNTIME_VERSION_CACHE_FILE closes that gap: it's a
# small file under LOG_DIR, scoped to this one script invocation via `$$`
# (bash keeps `$$` fixed to the TOP-LEVEL script's PID even from inside
# arbitrarily nested subshells, unlike $BASHPID, which changes per fork),
# so every table's subshell reads/writes the same file and the probe
# really does happen at most once per run, cache misses across tables
# included. Cleaned up after the main per-table loop ends.
#
# Only ever called for a format-version >= 3 table, so a v2-only fleet never
# pays for it at all.
ICEBERG_RUNTIME_VERSION=""
ICEBERG_RUNTIME_VERSION_PROBED="false"
ICEBERG_RUNTIME_VERSION_CACHE_FILE="${LOG_DIR}/.iceberg_runtime_version_probe.$$"
probe_iceberg_runtime_version() {
  if [[ "$ICEBERG_RUNTIME_VERSION_PROBED" == "true" ]]; then
    return 0
  fi
  # Cross-subshell fast path: another table's subshell earlier in this same
  # run already probed and cached the result. -f (existence), not -s
  # (non-empty): an empty cache file is a legitimate cached "probed, but
  # version undetectable" result (see ICEBERG_RUNTIME_VERSION_PROBED being
  # set to "true" below even when detected="" ) and must not be re-probed
  # just because it's empty.
  if [[ -f "$ICEBERG_RUNTIME_VERSION_CACHE_FILE" ]]; then
    ICEBERG_RUNTIME_VERSION=$(cat "$ICEBERG_RUNTIME_VERSION_CACHE_FILE")
    ICEBERG_RUNTIME_VERSION_PROBED="true"
    return 0
  fi
  ICEBERG_RUNTIME_VERSION_PROBED="true"

  local detected
  detected=$(spark_sql_scalar "${SRC_METASTORE_URI}" \
    "SELECT reflect('org.apache.iceberg.IcebergBuild', 'version');") || detected=""
  # IcebergBuild.version() falls back to the literal "unknown" when the
  # build properties file is missing from the jar, and Spark's reflect()
  # yields "NULL" if the call throws. Treat those -- and anything else that
  # is not <digits>.<digits> -- as "not detected" rather than letting a
  # non-version string reach version_ge, where every component would
  # sanitise to 0 and compare as an implausibly ancient release.
  if [[ ! "$detected" =~ ^[0-9]+\.[0-9]+ ]]; then
    detected=""
  fi
  ICEBERG_RUNTIME_VERSION="$detected"
  # Atomic write-then-rename (a reader can never observe a partially-written
  # cache file) -- this isn't a replication checkpoint, just a
  # same-invocation probe cache, and this local file is unrelated to
  # CHECKPOINT_DIR's own (HDFS) storage.
  #
  # The .tmp name is suffixed with $BASHPID (this subshell's own PID, unlike
  # $$ which stays fixed to the top-level script even from inside a forked
  # subshell -- see this cache file's own name just above). Under
  # PARALLEL_TABLES>1, multiple tables' subshells can all miss the cache at
  # once and race to (re)populate it; without a per-writer-unique tmp name
  # they would all write/rename the SAME "<file>.tmp" concurrently, and the
  # loser's `mv` would fail (source already renamed away by the winner) --
  # silently, since it isn't (and shouldn't need to be) error-checked here.
  echo "${ICEBERG_RUNTIME_VERSION}" > "${ICEBERG_RUNTIME_VERSION_CACHE_FILE}.tmp.${BASHPID}"
  mv "${ICEBERG_RUNTIME_VERSION_CACHE_FILE}.tmp.${BASHPID}" "${ICEBERG_RUNTIME_VERSION_CACHE_FILE}"
  return 0
}

# runtime_supports_dv_rewrite: can this Iceberg runtime's
# rewrite_table_path correctly relocate a v3 deletion vector? Honours the
# ICEBERG_DV_SUPPORT override; otherwise probes the runtime version and
# compares it against ICEBERG_MIN_DV_RUNTIME. An undetectable version is
# answered "no" -- the conservative direction, since guessing "yes" wrong
# means a crash mid-rewrite or a destination table whose deletion vectors
# still point at the source cluster.
#
# Leaves ICEBERG_RUNTIME_VERSION populated for the caller's log messages in
# the "auto" case, and deliberately leaves it EMPTY under an explicit
# override, where no probe is run and there is no detected version to
# report. Callers must describe the override case from ICEBERG_DV_SUPPORT
# rather than printing an unprobed ICEBERG_RUNTIME_VERSION as if it were a
# detection result.
runtime_supports_dv_rewrite() {
  case "${ICEBERG_DV_SUPPORT,,}" in
    true|yes|1) return 0 ;;
    false|no|0) return 1 ;;
  esac
  probe_iceberg_runtime_version
  [[ -n "$ICEBERG_RUNTIME_VERSION" ]] || return 1
  version_ge "$ICEBERG_RUNTIME_VERSION" "$ICEBERG_MIN_DV_RUNTIME"
}

# describe_dv_runtime: one human-readable phrase for WHY the deletion-vector
# verdict came out the way it did, so the same wording is used by every log
# line and an explicit override is never misreported as a detected version.
describe_dv_runtime() {
  case "${ICEBERG_DV_SUPPORT,,}" in
    true|yes|1|false|no|0)
      printf 'asserted via ICEBERG_DV_SUPPORT=%s, not probed\n' "${ICEBERG_DV_SUPPORT}"
      ;;
    *)
      if [[ -n "$ICEBERG_RUNTIME_VERSION" ]]; then
        printf 'detected Iceberg runtime %s\n' "$ICEBERG_RUNTIME_VERSION"
      else
        printf 'Iceberg runtime version could not be detected\n'
      fi
      ;;
  esac
}

# unsupported_v3_outcome: the single place that decides what happens to a v3
# table this runtime cannot safely replicate. Logs the operator-facing
# consequence and returns the code the per-table loop buckets on: 1 =
# FAILED, 2 = SKIPPED.
#
# Default is FAILED, not SKIPPED, and deliberately so. A skipped table lands
# in a bucket the run summary still reports as overall SUCCESS, which for a
# DR pipeline means the worst possible outcome -- a table quietly absent
# from the destination -- would look like a green run.
unsupported_v3_outcome() {
  local qualified_table="$1"
  case "${ICEBERG_SKIP_UNSUPPORTED_V3,,}" in
    true|yes|1)
      log_warn "SKIP: ICEBERG_SKIP_UNSUPPORTED_V3=${ICEBERG_SKIP_UNSUPPORTED_V3} -- skipping ${qualified_table} instead of failing the run."
      log_warn "SKIP: ${qualified_table} is NOT protected on the destination until the Iceberg runtime is upgraded."
      return 2
      ;;
    *)
      return 1
      ;;
  esac
}

# table_has_deletion_vectors: does this table carry any deletion vectors?
#   0 -> yes, at least one DV
#   1 -> no DVs
#   2 -> could not determine (query failed or returned a non-count)
#
# A DV is exactly a delete file whose format is PUFFIN -- the same test
# Iceberg's own ContentFileUtil.isDV() applies (deleteFile.format() ==
# FileFormat.PUFFIN), and the manifest stores that enum as the string
# "PUFFIN", which is what the metadata table surfaces.
#
# Scoped to `all_delete_files` (every snapshot reachable from the table's
# metadata) rather than `delete_files` (current snapshot only), because a
# BOOTSTRAP rewrite walks all reachable snapshots, not just the current
# one. That makes this deliberately conservative for the INCREMENTAL case:
# a table whose DVs exist only in snapshots older than the checkpoint would
# rewrite fine but is refused anyway. Erring that way costs an upgrade
# prompt; erring the other way costs a broken destination table.
#
# $3 is the table's `snapshot-count` from SHOW TBLPROPERTIES (already read
# there, so it costs nothing here). A table with zero snapshots has never
# been written and therefore cannot hold a delete file of any kind, so it
# answers "no DVs" without launching spark-sql at all. That is not merely an
# optimisation: it keeps a freshly-created, still-empty v3 table -- an
# entirely ordinary thing to bootstrap -- from being refused should the
# metadata-table scan behave unexpectedly with no snapshots to scan.
#
# The shortcut fires ONLY on an explicit "0". A MISSING or unparseable
# snapshot-count deliberately falls through to the real probe rather than
# being read as "empty, therefore no DVs": every other branch of this gate
# errs towards refusing what it cannot verify, and treating an absent
# property as proof of absence would be the single fail-open path in it.
table_has_deletion_vectors() {
  local metastore_uri="$1"
  local qualified_table="$2"
  local snapshot_count="${3:-}"

  if [[ "$snapshot_count" == "0" ]]; then
    return 1
  fi

  # SAME-NAMESERVICE COLLISION: this query physically opens the table's
  # manifests to enumerate delete files -- the same "must reach SOURCE"
  # requirement as resolve_src_metadata_json_for_snapshot() above (see its
  # comment, and "SAME-NAMESERVICE COLLISION" in this script's
  # header). Only relevant when reading SOURCE specifically (this
  # function's only current caller, STEP 2, always passes
  # SRC_METASTORE_URI) -- gated on that explicitly rather than on collision
  # mode alone, so a future DST-side caller is never redirected by mistake.
  local _dv_saved_ha_conf=() _dv_saved_hdfs_ha=() _dv_override_installed=false
  if [[ "$SAME_NAMESERVICE_COLLISION" == "true" && "$metastore_uri" == "$SRC_METASTORE_URI" ]]; then
    _dv_saved_ha_conf=("${HA_CONF_ARGS[@]}")
    _dv_saved_hdfs_ha=("${HDFS_HA_ARGS[@]}")
    HA_CONF_ARGS=()
    HDFS_HA_ARGS=()
    build_collision_hop_a_ha_args
    _dv_override_installed=true
  fi
  local dv_count dv_rc=0
  dv_count=$(spark_sql_scalar "${metastore_uri}" \
    "SELECT count(*) FROM ${SPARK_CATALOG}.${qualified_table}.all_delete_files WHERE file_format = 'PUFFIN';") || dv_rc=$?
  if [[ "$_dv_override_installed" == "true" ]]; then
    HA_CONF_ARGS=("${_dv_saved_ha_conf[@]}")
    HDFS_HA_ARGS=("${_dv_saved_hdfs_ha[@]}")
  fi
  [[ $dv_rc -eq 0 ]] || return 2
  # An empty result is "could not determine", NOT zero: spark_sql_scalar
  # echoes an empty string both for a genuinely empty result set and for
  # output whose last line got filtered away, and a count(*) query always
  # produces exactly one row when it runs at all.
  [[ "$dv_count" =~ ^[0-9]+$ ]] || return 2
  [[ "$dv_count" -gt 0 ]]
}

# resolve_src_metadata_json_for_snapshot: given a snapshot-id that exists in
# SOURCE's history, return the metadata.json filename (bare, not a full
# path -- see the "start_version must be a bare filename" note elsewhere in
# this script) that was source's CURRENT metadata.json at the time that
# snapshot-id was introduced.
#
# This is the value that seeding (both --seed-checkpoint and auto-seed)
# must use whenever the destination's data is a true prefix of source's
# own history (DR seeded from an earlier point in source's timeline, not
# independently-written data). Seeding from source's CURRENT metadata.json
# instead would be wrong whenever source has advanced past the point DR is
# caught up to: rewrite_table_path's incremental delta is computed as
# "versions after start_version, up to end_version," so seeding from
# source's current version makes start_version == end_version and silently
# skips every snapshot in between, even though it should have been
# replicated.
#
# Uses Iceberg's own metadata_log_entries metadata table (a documented,
# stable Iceberg feature -- see iceberg/docs/docs/spark-queries.md:
# "SELECT * from prod.db.table.metadata_log_entries;"), which maps each
# historical metadata.json file to the latest snapshot-id that was current
# in that file at the time. Queried via spark-sql (the same mechanism used
# for rewrite_table_path/register_table), since Hive/beeline has no
# equivalent query.
#
# EARLIEST MATCH, NOT LATEST. Several metadata.json versions can share one
# snapshot-id: the version that introduced the snapshot, followed by any
# number of metadata-only commits made on top of it (a schema or property
# change, or the new metadata.json Hive's Iceberg storage handler writes on
# every metadata_location repoint). The query returns the EARLIEST of them
# (ORDER BY timestamp ASC, with the file name -- which starts with the
# zero-padded version number -- as the tie-break), for two reasons:
#   - Nothing is skipped. start_version is exclusive, so every later
#     metadata-only version falls inside the delta and reaches the
#     destination. Anchoring at the latest match would leave those versions
#     outside the delta.
#   - The anchor exists on BOTH clusters. The introducing version is the file
#     that carried this snapshot to the destination in the first place, so
#     the destination already holds its own copy. A later metadata-only
#     version may exist on source alone, and since rewrite_table_path never
#     copies start_version itself, anchoring there leaves an entry in the
#     destination's metadata log that points at a file the destination does
#     not have (see "CHAINED CROSS-CLUSTER REWRITES" in this script's header).
# An earlier anchor can only widen the delta, never narrow it: files the
# destination already holds are skipped by the copier's same-length check.
resolve_src_metadata_json_for_snapshot() {
  local qualified_table="$1"
  local target_snapshot_id="$2"
  local _log_query="SELECT file FROM ${SPARK_CATALOG}.${qualified_table}.metadata_log_entries WHERE latest_snapshot_id = ${target_snapshot_id} ORDER BY timestamp ASC, file ASC LIMIT 1;"

  # SAME-NAMESERVICE COLLISION: this query physically opens source's
  # CURRENT metadata.json to enumerate its metadata-log entries -- the
  # exact same "must reach SOURCE" requirement hop A's isolated override
  # exists for (see "SAME-NAMESERVICE COLLISION" in this
  # script's header). This function is called from --seed-checkpoint,
  # auto-seed, and STEP 7's slow-path verification -- none of which are
  # part of hop A/B's own STEP 4-6 branch, so without installing the SAME
  # isolated override here, this call would silently resolve the shared
  # name to DESTINATION under the (correct, deliberately un-overridden)
  # global HA args and read DESTINATION's own metadata-log instead of
  # SOURCE's -- a wrong answer returned with no error at all, risking a
  # checkpoint written against the wrong table's history.
  if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    local _SAVED_HA_CONF_ARGS=("${HA_CONF_ARGS[@]}")
    local _SAVED_HDFS_HA_ARGS=("${HDFS_HA_ARGS[@]}")
    HA_CONF_ARGS=()
    HDFS_HA_ARGS=()
    build_collision_hop_a_ha_args
    local _result _rc=0
    _result=$(spark_sql_scalar "${SRC_METASTORE_URI}" "${_log_query}") || _rc=$?
    HA_CONF_ARGS=("${_SAVED_HA_CONF_ARGS[@]}")
    HDFS_HA_ARGS=("${_SAVED_HDFS_HA_ARGS[@]}")
    [[ $_rc -eq 0 ]] || return 1
    printf '%s' "$_result"
    return 0
  fi

  # A target_snapshot_id with no matching row is a legitimate outcome (the
  # caller falls through to bootstrap for it, see ACCEPTED LIMITATION
  # below) -- NOT a query failure. spark_sql_scalar already distinguishes
  # the two: it fails only when spark-sql itself failed, and echoes an
  # empty string for an empty result set.
  spark_sql_scalar "${SRC_METASTORE_URI}" "${_log_query}"
}

# ACCEPTED LIMITATION: metadata_log_entries.latest_snapshot_id resolves each
# log entry's snapshot via table.snapshot(id) against source's CURRENT
# snapshot set. If the destination's current-snapshot-id belongs to a
# snapshot that source has since expired (EXPIRE_SNAPSHOTS / retention
# policy), that snapshot-id will not resolve to any row here, and the
# caller falls through to a real bootstrap. This is indistinguishable from
# "destination's data never came from source's history at all," but
# bootstrap is the correct, safe outcome either way: EXPIRE_SNAPSHOTS
# typically deletes the expired snapshot's underlying manifest/data files
# too, so there would usually be nothing left to incrementally recover
# from even if the two cases could be told apart.

# src_snapshot_exists: is this snapshot-id still part of SOURCE's snapshot
# set?
#   0 -> yes
#   1 -> no
#   2 -> could not determine (bad id, query failed, or a non-count result)
#
# Complements resolve_src_metadata_json_for_snapshot() above, which can only
# see as far back as source's metadata log reaches. The `snapshots` metadata
# table lists every snapshot source still retains, so a destination snapshot
# found here is part of source's history even when the metadata log no
# longer names the version that introduced it. Read from source's current
# metadata only -- no historical metadata.json is opened. Used to decide
# whether a full-rewrite fallback may supersede the destination's current
# state (see the FULL-REWRITE FALLBACK GUARD in STEP 4).
#
# Same SAME-NAMESERVICE COLLISION handling as the function above: the query
# must reach SOURCE, so hop A's isolated override is installed around it.
src_snapshot_exists() {
  local qualified_table="$1"
  local snapshot_id="$2"
  [[ "$snapshot_id" =~ ^-?[0-9]+$ ]] || return 2

  local _sse_saved_ha_conf=() _sse_saved_hdfs_ha=() _sse_override_installed=false
  if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    _sse_saved_ha_conf=("${HA_CONF_ARGS[@]}")
    _sse_saved_hdfs_ha=("${HDFS_HA_ARGS[@]}")
    HA_CONF_ARGS=()
    HDFS_HA_ARGS=()
    build_collision_hop_a_ha_args
    _sse_override_installed=true
  fi
  local _sse_count _sse_rc=0
  _sse_count=$(spark_sql_scalar "${SRC_METASTORE_URI}" \
    "SELECT count(*) FROM ${SPARK_CATALOG}.${qualified_table}.snapshots WHERE snapshot_id = ${snapshot_id};") || _sse_rc=$?
  if [[ "$_sse_override_installed" == "true" ]]; then
    HA_CONF_ARGS=("${_sse_saved_ha_conf[@]}")
    HDFS_HA_ARGS=("${_sse_saved_hdfs_ha[@]}")
  fi
  [[ $_sse_rc -eq 0 ]] || return 2
  [[ "$_sse_count" =~ ^[0-9]+$ ]] || return 2
  [[ "$_sse_count" -gt 0 ]]
}

# sanitize_for_filename: collapse anything outside [A-Za-z0-9._-] to '_' so
# an arbitrary SRC_NAMESERVICE/DST_NAMESERVICE string can never introduce a
# path separator, glob character, or other filesystem-unsafe byte into a
# checkpoint filename built from it below.
sanitize_for_filename() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# checkpoint_basename_for: the direction-scoped FILENAME (no directory)
# used by checkpoint_hdfs_path_for() below, consumed as
# path="$(checkpoint_hdfs_path_for ...)" -- it must emit a bare path on
# stdout and nothing else. Do not "tidy" this into log_info: that prepends
# a timestamp and a [INFO] tag, and the caller then uses
# "[2026-01-01 00:00:00] [INFO]  hdfs://.../db.tbl.checkpoint" as a path,
# so every run silently reads a checkpoint that is not there and
# re-bootstraps.
#
# DIRECTION-SCOPED (src/dst nameservice is part of the filename), not just
# per-table. A checkpoint records "how far source's history has been
# replicated to THIS destination" -- direction-specific state by
# definition. Keying it on table name alone (the original design) meant a
# prod->DR run and a later DR->prod run against the SAME table silently
# read and overwrote the exact same file: the second direction's checkpoint
# write clobbered the first direction's incremental cursor, so resuming the
# original direction afterward fed rewrite_table_path a start_version
# filename that could never appear in ITS source's metadata log (see the
# RULE in the header's "TABLE LOCATION AND THE CHECKPOINT" section) -- a
# real production incident on this exact table (iceberg_dr_test202.orders202:
# bootstrap prod->DR, then a DR->prod test run, both sharing one checkpoint
# file). Scoping the filename by direction gives each direction its own
# independent incremental cursor, which is also the only sane semantics for
# genuine bidirectional/failover-failback use: two directions on one table
# are two distinct replication pipelines, not one.
#
# NAMESERVICE ALONE IS ENOUGH IN THE NORMAL CASE -- metastore URI is
# deliberately left OUT of the filename then. Outside SAME-NAMESERVICE
# COLLISION mode (handled just below) the two nameservice strings differ,
# so a nameservice-only key cannot collapse into a collision there. Dropping the URI keeps the
# filename short and readable, e.g.
# "orders202.ODP-Phoenix__to__ODP-Phoenix-DR.checkpoint" instead of a name
# carrying two sanitized "thrift://host:port" strings end to end.
#
# SAME-NAMESERVICE COLLISION IS THE ONE CASE WHERE IT IS NOT ENOUGH, AND
# THIS IS A REAL, CONFIRMED PRODUCTION FAILURE, NOT A THEORETICAL ONE.
# SRC_NAMESERVICE and DST_NAMESERVICE are, by construction, the IDENTICAL
# string on EVERY invocation against a same-nameservice pair -- both the
# prod->DR run and the later DR->prod run pass the exact same
# "ODP-Phoenix ODP-Phoenix" pair, since that is the whole point of
# collision mode (two different physical clusters sharing one HA
# nameservice name). A nameservice-only direction key is therefore
# IDENTICAL for both directions ("ODP-Phoenix__to__ODP-Phoenix" every
# time) -- this is exactly the same-file collision this whole
# direction-scoping scheme was built to prevent (see iceberg_dr_test202's
# incident above), recreated one level up. Confirmed in practice on
# iceberg_dr_test209.orders209: a prod->DR run after a successful DR->prod
# failover read back the DR->prod run's own stale checkpoint anchor (an
# old ancestor no longer in prod's own metadata log after the failover
# already advanced it) and failed with "Cannot find provided version file
# ... in metadata log" -- prod->DR and DR->prod were silently sharing one
# checkpoint file the whole time.
#
# FIX: when SRC_NAMESERVICE == DST_NAMESERVICE (SAME_NAMESERVICE_COLLISION,
# a global set once at startup), also fold in SRC_METASTORE_URI/
# DST_METASTORE_URI's HOSTS (also globals, validated mandatory and always
# distinct between two real catalogs even when their nameservice strings
# coincide -- see "TABLE LOCATION AND THE CHECKPOINT" in this script's
# header) -- these are what actually distinguish the two physical clusters
# in this mode, since the nameservice strings by definition cannot. Only
# the host is kept (scheme and port stripped): two different physical
# clusters always have different metastore HOSTS, so the host alone is
# already a sufficient, much shorter disambiguator than the full URI --
# e.g. "orders2019.ODP-Phoenix__to__ODP-Phoenix__odp-new2__odp-2.checkpoint"
# instead of embedding "thrift___host_9083" twice. Left OUT for every other
# run (SAME_NAMESERVICE_COLLISION=false), so no existing non-collision
# checkpoint filename changes -- this only changes the filename
# collision-mode runs already had to have been silently sharing, which
# were never a valid/distinct pair of files to begin with.
checkpoint_basename_for() {
  local hive_db="$1"
  local table_name="$2"
  local src_ns="$3"
  local dst_ns="$4"
  local direction
  direction="$(sanitize_for_filename "${src_ns}")__to__$(sanitize_for_filename "${dst_ns}")"
  if [[ "${SAME_NAMESERVICE_COLLISION:-false}" == "true" ]]; then
    local src_metastore_host dst_metastore_host
    src_metastore_host="${SRC_METASTORE_URI#*://}"
    src_metastore_host="${src_metastore_host%%:*}"
    src_metastore_host="${src_metastore_host%%/*}"
    dst_metastore_host="${DST_METASTORE_URI#*://}"
    dst_metastore_host="${dst_metastore_host%%:*}"
    dst_metastore_host="${dst_metastore_host%%/*}"
    direction="${direction}__$(sanitize_for_filename "${src_metastore_host}")__$(sanitize_for_filename "${dst_metastore_host}")"
  fi
  printf '%s\n' "${hive_db}.${table_name}.${direction}.checkpoint"
}

# checkpoint_hdfs_path_for: the full HDFS path for one checkpoint, rooted
# under one specific nameservice -- reuses CHECKPOINT_DIR itself (see
# "CHECKPOINT ON HDFS" in this script's header for the full rationale for
# why a checkpoint is mirrored onto BOTH SRC's and DST's HDFS). With two
# distinct nameservices the two paths this produces for one checkpoint
# differ by authority; in SAME-NAMESERVICE COLLISION mode they are the same
# path, which checkpoint_write()/checkpoint_retire() detect and treat as a
# single copy.
checkpoint_hdfs_path_for() {
  local nameservice="$1"
  shift
  printf '%s\n' "hdfs://${nameservice}${CHECKPOINT_DIR}/$(checkpoint_basename_for "$@")"
}

########################################
# CROSS-HOST TABLE LOCK (on the destination cluster's HDFS).
#
# The flock in replicate_one_table() only excludes invocations on the SAME
# host -- it is a local file. The checkpoint, though, lives on HDFS so that
# any host can run a table, and two hosts replicating one table at the same
# time share its staging directory: one run can end up copying the file
# list the other one wrote, and then repoint the destination at metadata
# whose files it never copied. This lock closes that gap.
#
#   - It is a directory, "<CHECKPOINT_DIR>/<db>.<table>.inprogress", on the
#     DESTINATION cluster, created with a plain `-mkdir` (no -p), which the
#     NameNode performs atomically and refuses if the path already exists.
#     An "owner" file inside records "<host> <pid> <epoch>".
#   - Taken only by a run that is about to replicate (after STEP 3 has
#     decided this is not a no-op), and removed when that table's subshell
#     exits, on every exit path. A no-op run and --seed-checkpoint change
#     nothing that needs protecting and never take it.
#   - A lock that is still there is either a live run or a leftover of a run
#     that was killed before it could clean up. It is treated as a leftover,
#     removed and re-taken, when its owner is THIS host and that process no
#     longer exists, or -- for another host, whose processes cannot be
#     checked from here -- when it is older than TABLE_LOCK_STALE_HOURS
#     (default 24; 0 disables the age rule). Otherwise the table is
#     reported as Locked (busy), naming the owner and the path to remove by
#     hand if that run is known to be dead.
#   - If the lock cannot be created for a reason other than "it exists"
#     (e.g. permissions), the run goes ahead without it and says so: this
#     lock guards against an unusual overlap, and must not itself become
#     the reason nothing is replicated.
# CROSS_HOST_TABLE_LOCK=false turns it off (the same-host flock remains).
# Cost: three `hadoop fs` launches per table that actually replicates.
#
# HDFS_TABLE_LOCK_PATH is set while this (sub)shell holds the lock;
# HDFS_TABLE_LOCK_HA_ARGS keeps the HA arguments in force when it was taken,
# so the release addresses the same cluster even if a later step swapped
# the global ones.
########################################
HDFS_TABLE_LOCK_PATH=""
HDFS_TABLE_LOCK_HA_ARGS=()

hdfs_table_lock_acquire() {
  local hive_db="$1" table_name="$2"
  case "${CROSS_HOST_TABLE_LOCK,,}" in
    true|yes|1) ;;
    *) return 0 ;;
  esac
  local lock_path="hdfs://${DST_NAMESERVICE}${CHECKPOINT_DIR}/${hive_db}.${table_name}.inprogress"
  local this_host owner owner_host owner_pid owner_epoch now stale_reason attempt
  this_host=$(hostname 2>/dev/null) || this_host="unknown-host"

  for attempt in 1 2; do
    if run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir "${lock_path}" >/dev/null 2>&1; then
      HDFS_TABLE_LOCK_PATH="$lock_path"
      HDFS_TABLE_LOCK_HA_ARGS=("${HDFS_HA_ARGS[@]}")
      printf '%s %s %s\n' "$this_host" "$$" "$(date +%s)" \
        | run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -put -f - "${lock_path}/owner" >/dev/null 2>&1 \
        || log_warn "Cross-host lock taken for ${hive_db}.${table_name}, but its owner record could not be written at ${lock_path}/owner."
      return 0
    fi

    owner=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${lock_path}/owner" 2>/dev/null) || owner=""
    if [[ -z "$owner" ]]; then
      if run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -test -d "${lock_path}" 2>/dev/null; then
        log_error "${hive_db}.${table_name} is marked as being replicated by another invocation (cross-host lock ${lock_path}),"
        log_error "but the lock carries no owner record. Skipping. If no run is active, remove it: hdfs dfs -rm -r ${lock_path}"
        return 3
      fi
      log_warn "Could not create the cross-host lock ${lock_path} for ${hive_db}.${table_name} (it does not exist, so this is"
      log_warn "not another run holding it -- check permissions on CHECKPOINT_DIR on the destination). Proceeding without it."
      return 0
    fi

    read -r owner_host owner_pid owner_epoch <<< "$owner"
    now=$(date +%s)
    stale_reason=""
    if [[ "$owner_host" == "$this_host" && "$owner_pid" =~ ^[0-9]+$ ]] \
       && ! ps -p "$owner_pid" >/dev/null 2>&1; then
      stale_reason="its owner (PID ${owner_pid} on this host) is no longer running"
    elif [[ "$TABLE_LOCK_STALE_HOURS" -gt 0 && "$owner_epoch" =~ ^[0-9]+$ ]] \
         && (( now - owner_epoch > TABLE_LOCK_STALE_HOURS * 3600 )); then
      # Applies to this host as well: a PID that is "running" may simply have
      # been reused by an unrelated process since the owner died.
      stale_reason="it was taken on host ${owner_host} more than ${TABLE_LOCK_STALE_HOURS} hour(s) ago (TABLE_LOCK_STALE_HOURS)"
    fi

    if [[ -n "$stale_reason" && "$attempt" -eq 1 ]]; then
      log_warn "Removing a leftover cross-host lock for ${hive_db}.${table_name}: ${stale_reason}."
      run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -rm -r -f -skipTrash "${lock_path}" >/dev/null 2>&1 || true
      continue
    fi

    local owner_started="unknown time"
    if [[ "$owner_epoch" =~ ^[0-9]+$ ]]; then
      printf -v owner_started '%(%Y-%m-%d %H:%M:%S)T' "$owner_epoch"
    fi
    log_error "${hive_db}.${table_name} is already being replicated by another invocation: host ${owner_host}, PID ${owner_pid}, started ${owner_started}"
    log_error "(cross-host lock ${lock_path}). Skipping -- retry once that run finishes."
    log_error "If that run is known to be dead, remove the lock: hdfs dfs -rm -r ${lock_path}"
    return 3
  done
  return 3
}

hdfs_table_lock_release() {
  [[ -n "$HDFS_TABLE_LOCK_PATH" ]] || return 0
  run_as_hdfs hadoop fs "${HDFS_TABLE_LOCK_HA_ARGS[@]}" -rm -r -f -skipTrash "${HDFS_TABLE_LOCK_PATH}" >/dev/null 2>&1 || {
    log_warn "Could not remove the cross-host lock ${HDFS_TABLE_LOCK_PATH}. It is cleared automatically by the next run"
    log_warn "from this host; from another host, remove it by hand: hdfs dfs -rm -r ${HDFS_TABLE_LOCK_PATH}"
  }
  HDFS_TABLE_LOCK_PATH=""
  return 0
}

# _table_exit_trap: the per-table subshell's EXIT trap -- print the stage
# timings, then release the cross-host lock if this table holds it.
#
# print_table_timing_summary MUST be the first command here: it reads $? on
# entry to learn the table's exit status, and any command before it would
# overwrite that. Both calls are `|| true` because `set -e` is live inside a
# trap: the summary returns the table's own (possibly non-zero) status, and
# without the guard a failed table would end the trap right there, before
# the lock is released. The subshell's exit status is not affected by what
# the trap returns -- it stays whatever `exit` was called with.
_table_exit_trap() {
  print_table_timing_summary "$1" "$2" || true
  hdfs_table_lock_release || true
}

# lock_file_for: a LOCAL-disk path, regardless of checkpoint storage --
# flock (see replicate_one_table() below) has no HDFS equivalent, so the
# per-table lock always lives on this host's disk under CHECKPOINT_DIR,
# even though that same variable is otherwise an HDFS path once resolved
# through checkpoint_hdfs_path_for() above. Harmless overlap: CHECKPOINT_DIR
# is just reused here as a stable, already-configured LOCAL directory to
# hold lock files in, unrelated to what it means for a checkpoint's own
# storage.
lock_file_for() {
  local hive_db="$1"
  local table_name="$2"
  printf '%s\n' "${CHECKPOINT_DIR}/${hive_db}.${table_name}.lock"
}

# build_nameservice_ha_confs: emit both flag flavors -- spark.hadoop.dfs.*
# for HA_CONF_ARGS, plain -Ddfs.* for HDFS_HA_ARGS (used by `hadoop fs`
# calls) -- for
# dfs.namenode.rpc-address.<ns>.<nnid>, dfs.ha.namenodes.<ns>, and
# dfs.client.failover.proxy.provider.<ns>, for ONE nameservice, given its
# "<nn-id>=<host>:<port>[,...]" host list.
build_nameservice_ha_confs() {
  local nameservice="$1"
  local nn_hosts_spec="$2"
  local nn_ids=()
  local pair nn_id nn_addr
  local pairs=()

  IFS=',' read -ra pairs <<< "$nn_hosts_spec"
  for pair in "${pairs[@]}"; do
    nn_id="${pair%%=*}"
    nn_addr="${pair#*=}"
    if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_id" == "$pair" ]]; then
      log_error "Malformed NN host entry for nameservice '${nameservice}': '${pair}' (expected <nn-id>=<host>:<port>)"
      exit 1
    fi
    nn_ids+=("$nn_id")
    HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.namenode.rpc-address.${nameservice}.${nn_id}=${nn_addr}")
    HDFS_HA_ARGS+=(-D "dfs.namenode.rpc-address.${nameservice}.${nn_id}=${nn_addr}")
  done

  local joined_ids
  joined_ids="$(IFS=,; echo "${nn_ids[*]}")"
  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.ha.namenodes.${nameservice}=${joined_ids}")
  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.client.failover.proxy.provider.${nameservice}=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider")
  HDFS_HA_ARGS+=(-D "dfs.ha.namenodes.${nameservice}=${joined_ids}")
  HDFS_HA_ARGS+=(-D "dfs.client.failover.proxy.provider.${nameservice}=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider")
}

# resolve_active_namenode_hostport: given a "<nn-id>=<host>:<port>,..." spec
# (the same shape as DST_NN_HOSTS/SRC_NN_HOSTS), find whichever nn-id is
# currently ACTIVE via `hdfs haadmin -getServiceState <nn-id>` and echo its
# bare "host:port" on stdout. Used by the SAME-NAMESERVICE COLLISION path
# to address DESTINATION by a literal NameNode address rather than a
# synthetic HA nameservice name -- see "SAME-NAMESERVICE COLLISION" in this
# script's header for why.
#
# Cached two ways so this is queried at most ONCE per script invocation,
# no matter how many collision-mode tables are processed:
#   - in-process: DST_ACTIVE_NN_HOSTPORT, checked first
#   - cross-subshell: a file under LOG_DIR, same tmp-then-mv pattern as
#     ICEBERG_RUNTIME_VERSION_CACHE_FILE -- each table replicates inside its
#     own flock subshell (see replicate_one_table), so a bare shell global
#     alone would not survive across tables; the file does.
# This caching is not just an optimization: hop A and hop B must resolve to
# the textually identical host:port within one table's replication, since
# hop B's rewrite_table_path source_prefix has to exactly match what hop A
# wrote as its target_prefix, or rewrite_table_path fails with "does not
# start with source_prefix".
#
# Run via run_as_hdfs (this script's normal identity-switch wrapper for
# every other hadoop/hdfs CLI call) under NATIVE, un-overridden
# HDFS_HA_ARGS -- this resolves DST_NAMESERVICE's own real NameNodes, which
# are natively resolvable with no override, exactly like every other
# non-hop-A/B `hadoop fs`/`hdfs` call this script makes.
#
# Fails loudly (return 1) if no nn-id reports "active" -- never falls back
# to a guess. A transient failover in progress, or an unreachable `hdfs
# haadmin`, must abort collision-mode replication for that table rather
# than silently resolve to a standby NameNode.
DST_ACTIVE_NN_HOSTPORT=""
DST_ACTIVE_NN_HOSTPORT_CACHE_FILE="${LOG_DIR}/.dst_active_nn_hostport.$$"
resolve_active_namenode_hostport() {
  local nn_hosts_spec="$1"

  if [[ -n "$DST_ACTIVE_NN_HOSTPORT" ]]; then
    printf '%s\n' "$DST_ACTIVE_NN_HOSTPORT"
    return 0
  fi
  if [[ -f "$DST_ACTIVE_NN_HOSTPORT_CACHE_FILE" ]]; then
    DST_ACTIVE_NN_HOSTPORT=$(cat "$DST_ACTIVE_NN_HOSTPORT_CACHE_FILE")
    if [[ -n "$DST_ACTIVE_NN_HOSTPORT" ]]; then
      printf '%s\n' "$DST_ACTIVE_NN_HOSTPORT"
      return 0
    fi
  fi

  local pair nn_id hostport state active_hostport=""
  local -a pairs=()
  IFS=',' read -ra pairs <<< "$nn_hosts_spec"
  for pair in "${pairs[@]}"; do
    nn_id="${pair%%=*}"
    hostport="${pair#*=}"
    [[ -z "$nn_id" || -z "$hostport" || "$nn_id" == "$pair" ]] && continue
    state=$(run_as_hdfs hdfs haadmin -getServiceState "$nn_id" 2>/dev/null) || {
      # >&2: this function's stdout is its return value (callers capture it
      # as the host:port), so a log line on stdout would become part of the
      # address. Same rule run_spark_sql's own preamble follows.
      log_warn "resolve_active_namenode_hostport: 'hdfs haadmin -getServiceState ${nn_id}' failed; trying next nn-id." >&2
      continue
    }
    if [[ "$state" == "active" ]]; then
      active_hostport="$hostport"
      break
    fi
  done

  if [[ -z "$active_hostport" ]]; then
    log_error "resolve_active_namenode_hostport: no NameNode in [${nn_hosts_spec}] reported ACTIVE"
    log_error "(transient failover in progress, or 'hdfs haadmin' unreachable). Cannot proceed with"
    log_error "SAME-NAMESERVICE COLLISION mode without a resolved destination NameNode identity."
    return 1
  fi

  DST_ACTIVE_NN_HOSTPORT="$active_hostport"
  # $BASHPID-suffixed tmp name -- same PARALLEL_TABLES>1 race, and same fix,
  # as ICEBERG_RUNTIME_VERSION_CACHE_FILE's own write above: without it,
  # concurrent collision-mode tables' subshells that all miss this cache at
  # once would race on writing/renaming the SAME "<file>.tmp".
  echo "${active_hostport}" > "${DST_ACTIVE_NN_HOSTPORT_CACHE_FILE}.tmp.${BASHPID}"
  mv "${DST_ACTIVE_NN_HOSTPORT_CACHE_FILE}.tmp.${BASHPID}" "${DST_ACTIVE_NN_HOSTPORT_CACHE_FILE}"
  printf '%s\n' "$active_hostport"
  return 0
}

# DELEGATION-TOKEN CONFS (single emission point).
#
# These two confs are emitted HERE and NOWHERE ELSE. The YARN block far
# above deliberately does not emit them, because their correct values
# depend on SAME_NAMESERVICE_COLLISION, which is not resolved until after
# that block runs.
#
# spark.yarn.kerberos.renewal.excludeHadoopFileSystems, not
# spark.hadoop.mapreduce.job.hdfs-servers.token-renewal.exclude: the former
# is honored by this cluster's ResourceManager, the latter is not. Values
# are full "hdfs://..." URIs, not bare nameservice names.
#
# Only meaningful under --master yarn: local[*] has no YARN submission
# step, so no delegation token is ever exchanged with a ResourceManager.
if [[ "$SPARK_MASTER" == "yarn" ]]; then
  # Ask Spark for delegation tokens covering both namespaces. Without this
  # the driver only obtains a token for its own default filesystem, and
  # executors fail the moment they touch the far cluster.
  # spark.kerberos.access.hadoopFileSystems, NOT the older deprecated
  # spark.yarn.access.hadoopFileSystems (see SPARK_RUN_MODE header).
  local_tok_access_ns_a="${SRC_NAMESERVICE}"
  local_tok_access_ns_b="${DST_NAMESERVICE}"
  if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    local_tok_access_ns_a="${DST_NAMESERVICE}"
    local_tok_access_ns_b=$(resolve_active_namenode_hostport "$DST_NN_HOSTS") || {
      log_error "Could not resolve destination's active NameNode for delegation-token confs."
      exit 1
    }
  fi
  SPARK_YARN_ARGS+=(--conf "spark.kerberos.access.hadoopFileSystems=hdfs://${local_tok_access_ns_a},hdfs://${local_tok_access_ns_b}")

  # WHICH FILESYSTEMS ARE EXCLUDED FROM RENEWAL. A token Spark fetches for an
  # excluded filesystem carries no renewer: the ResourceManager does not
  # renew it, and it stops working once the NameNode's renew interval
  # (dfs.namenode.delegation.token.renew-interval, 24 hours by default) has
  # passed. The exclusion is needed for the REMOTE cluster, whose tokens
  # this cluster's ResourceManager cannot renew. It is not needed for the
  # cluster the job is submitted to, and excluding that one as well caps
  # every Spark job at the renew interval.
  #
  # SPARK_TOKEN_RENEWAL_EXCLUDE (env var, default "both"; "both" | "auto"):
  #   both -- exclude both nameservices, whatever this host's own is. Every
  #           Spark job is then limited to the renew interval, which only
  #           matters for a single job that runs longer than that.
  #   auto -- exclude only the remote nameservice, so YARN renews this
  #           cluster's own token and that limit goes away. The local one
  #           is whichever of SRC_NAMESERVICE/DST_NAMESERVICE this host's
  #           fs.defaultFS names (one `hdfs getconf` per run). If
  #           fs.defaultFS names neither -- the script is running from a
  #           third cluster -- or cannot be read, both are excluded.
  # SAME-NAMESERVICE COLLISION always excludes both of its identities (the
  # redirected shared name and the resolved bare host:port).
  SPARK_TOKEN_RENEWAL_EXCLUDE="${SPARK_TOKEN_RENEWAL_EXCLUDE:-both}"
  case "${SPARK_TOKEN_RENEWAL_EXCLUDE,,}" in
    auto|both) ;;
    *)
      log_error "SPARK_TOKEN_RENEWAL_EXCLUDE must be one of: both, auto (got '${SPARK_TOKEN_RENEWAL_EXCLUDE}')"
      exit 1
      ;;
  esac
  local_tok_renewal_exclude="hdfs://${local_tok_access_ns_a},hdfs://${local_tok_access_ns_b}"
  if [[ "$SAME_NAMESERVICE_COLLISION" != "true" && "$KERBEROS_ENABLED" == "yes" && "${SPARK_TOKEN_RENEWAL_EXCLUDE,,}" == "auto" ]]; then
    local_default_fs=$(run_as_hdfs hdfs getconf -confKey fs.defaultFS 2>/dev/null) || local_default_fs=""
    local_default_fs="${local_default_fs%/}"
    if [[ "$local_default_fs" == "hdfs://${DST_NAMESERVICE}" ]]; then
      local_tok_renewal_exclude="hdfs://${SRC_NAMESERVICE}"
    elif [[ "$local_default_fs" == "hdfs://${SRC_NAMESERVICE}" ]]; then
      local_tok_renewal_exclude="hdfs://${DST_NAMESERVICE}"
    fi
    if [[ "$local_tok_renewal_exclude" == *,* ]]; then
      log_info "Delegation-token renewal: this host's fs.defaultFS ('${local_default_fs:-<unreadable>}') is neither nameservice of this"
      log_info "run, so both are excluded from renewal; a single Spark job is then limited to the NameNode's token renew interval."
    else
      log_info "Delegation-token renewal: excluded for the remote cluster only (${local_tok_renewal_exclude}); this cluster's (${local_default_fs}) is renewed by YARN."
    fi
    unset local_default_fs
  fi
  SPARK_YARN_ARGS+=(--conf "spark.yarn.kerberos.renewal.excludeHadoopFileSystems=${local_tok_renewal_exclude}")
  if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    log_info "Collision mode (YARN): delegation-token access/renewal-exclusion set for '${local_tok_access_ns_a}' and '${local_tok_access_ns_b}'."
  fi
  unset local_tok_access_ns_a local_tok_access_ns_b local_tok_renewal_exclude
fi

# build_collision_hop_a_ha_args: appends to the (caller-blanked)
# HA_CONF_ARGS/HDFS_HA_ARGS the ISOLATED override for hop A -- the one
# spark-sql call per table that must physically read SOURCE while the
# shared nameservice name is redirected to do so.
#   - "${DST_NAMESERVICE}" (the shared name) -> redirected to SRC_NN_HOSTS
#     (SOURCE's real NameNodes) for this job only. This is what makes
#     source_prefix ('hdfs://<shared-name>', matching what is literally
#     embedded in source's own metadata) physically resolve to SOURCE.
# DESTINATION itself (rewrite_table_path's target_prefix/staging_location,
# and spark.yarn.stagingDir) is addressed via a resolved bare active-
# NameNode host:port (resolve_active_namenode_hostport), never a synthetic
# HA nameservice name -- a bare host:port needs no dfs.nameservices/
# dfs.ha.* entry at all, so nothing needs to be built for it here.
build_collision_hop_a_ha_args() {
  local active_nn
  active_nn=$(resolve_active_namenode_hostport "$DST_NN_HOSTS") || return 1

  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.nameservices=${DST_NAMESERVICE}")
  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.ha.automatic-failover.enabled=${AUTOMATIC_FAILOVER_ENABLED,,}")
  HDFS_HA_ARGS+=(-D "dfs.nameservices=${DST_NAMESERVICE}")
  HDFS_HA_ARGS+=(-D "dfs.ha.automatic-failover.enabled=${AUTOMATIC_FAILOVER_ENABLED,,}")
  build_nameservice_ha_confs "$DST_NAMESERVICE" "$SRC_NN_HOSTS"

  # spark.yarn.stagingDir, qualified with the resolved bare active NameNode
  # host:port (not left to default): without this, Spark's staging
  # directory defaults to the submitting user's home resolved against
  # fs.defaultFS -- which, for hop A's job, is the shared nameservice name
  # this job has just redirected to SOURCE, causing job resources to be
  # uploaded to the wrong cluster and a third renewable token (for SOURCE
  # under the shared name) that YARN cannot renew.
  HA_CONF_ARGS+=(--conf "spark.yarn.stagingDir=hdfs://${active_nn}/user/${SPARK_STAGING_USER}/.sparkStaging")

  # SPARK_YARN_ARCHIVE named under the shared nameservice would resolve to
  # SOURCE for this job, like every other path under that name, and the
  # archive lives on the cluster the job is submitted to. Re-address it
  # through the same resolved NameNode as the staging directory. This conf
  # comes after SPARK_YARN_ARGS on the command line, so it is the one Spark
  # keeps.
  if [[ "$SPARK_YARN_ARCHIVE" == "hdfs://${DST_NAMESERVICE}/"* ]]; then
    HA_CONF_ARGS+=(--conf "spark.yarn.archive=hdfs://${active_nn}/${SPARK_YARN_ARCHIVE#"hdfs://${DST_NAMESERVICE}/"}")
  fi
}

########################################
# build_collision_hop_a_distcp_alias_ha_args: the distcp-specific
# equivalent of build_collision_hop_a_ha_args() above, for
# COPY_ENGINE=distcp's Hop A copy only. Cannot reuse the Spark version's
# approach (redirect the plain shared name itself) or the global
# HDFS_HA_ARGS Hop A already has installed when this runs: distcp is a
# separate `hadoop` CLI process, not a Spark job, and CONFIRMED BY DIRECT
# TESTING on this exact cluster pair (see the manual verification that
# preceded this fix) that redirecting the plain name breaks distcp/YARN in
# a way Spark's own stagingDir override does not hit:
#
#   `-D dfs.nameservices=<shared-name>` (pointed at SOURCE's NameNodes, the
#   same override Hop A's spark-sql call uses) makes fs.defaultFS itself
#   ambiguous for the whole distcp/MapReduce JVM, because fs.defaultFS on
#   BOTH clusters is natively "hdfs://<shared-name>" in a same-nameservice
#   collision (that is the definition of this mode). Every SCHEME-LESS path
#   distcp's own MapReduce job touches then silently resolves against
#   whichever physical cluster the override says the shared name means --
#   critically `mapreduce.application.framework.path` (the cluster's
#   mapreduce.tar.gz) and the job's own "/user/<user>/.staging/job_<id>"
#   staging directory, NEITHER of which distcp exposes an equivalent to
#   Spark's spark.yarn.stagingDir override for. Confirmed in practice: this
#   produces "Resource .../mapreduce.tar.gz changed on src filesystem --
#   expected: ..., was: ..." AM container localization failures, because
#   the NodeManager ends up comparing two DIFFERENT physical clusters'
#   copies of that scheme-less path against each other.
#
# THE FIX, verified by direct manual testing on this cluster pair
# (odp-1/odp-new1, both "ODP-Phoenix"): alias SOURCE under a DISTINCT name
# instead of overriding the shared one, and rewrite every source row in the
# distcp group .list files from the plain shared-name authority to that
# alias (see run_distcp_copier()'s own use of this). fs.defaultFS is then
# NEVER touched, so every scheme-less path (framework.path, staging dir)
# keeps resolving natively.
#
# CRITICAL DETAIL, ALSO CONFIRMED BY DIRECT TESTING: dfs.nameservices must
# be the MERGED list "<shared-name>,<alias>", never the alias alone.
# Hadoop's "-D" REPLACES a property's value outright rather than merging
# it with whatever this host's own native hdfs-site.xml already declares
# -- passing "-D dfs.nameservices=<alias>" by itself was tested and found
# to break resolution of the plain shared name for the rest of the
# process (a bare `hadoop fs -ls /tmp/` under that override failed
# resolving "hdfs://<shared-name>" at all), even though nothing in that
# command referenced the shared name directly. Keeping the native name in
# the list alongside the new alias avoids that regression entirely.
#
# Sets (echoes on stdout, one arg per line via the array below -- not
# `local`, populated into the caller-named array via nameref):
#   $1 (nameref) -- array to append the distcp `-D ...` flag pairs into
# Returns the resolved alias name on stdout (second line of output is not
# used; the alias name itself is deterministic from DST_NAMESERVICE, so
# callers can just recompute "<DST_NAMESERVICE>-SRCALIAS" directly rather
# than parsing this function's output).
build_collision_hop_a_distcp_alias_ha_args() {
  local -n _out_ref="$1"
  local alias_ns="${DST_NAMESERVICE}-SRCALIAS"
  _out_ref+=(-D "dfs.nameservices=${DST_NAMESERVICE},${alias_ns}")
  _out_ref+=(-D "dfs.ha.automatic-failover.enabled=${AUTOMATIC_FAILOVER_ENABLED,,}")
  local pair nn_id nn_addr nn_ids=()
  local -a pairs=()
  IFS=',' read -ra pairs <<< "$SRC_NN_HOSTS"
  for pair in "${pairs[@]}"; do
    nn_id="${pair%%=*}"
    nn_addr="${pair#*=}"
    if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_id" == "$pair" ]]; then
      log_error "Malformed NN host entry in SRC_NN_HOSTS for distcp SRCALIAS: '${pair}' (expected <nn-id>=<host>:<port>)"
      return 1
    fi
    nn_ids+=("$nn_id")
    _out_ref+=(-D "dfs.namenode.rpc-address.${alias_ns}.${nn_id}=${nn_addr}")
  done
  local joined_ids
  joined_ids="$(IFS=,; echo "${nn_ids[*]}")"
  _out_ref+=(-D "dfs.ha.namenodes.${alias_ns}=${joined_ids}")
  _out_ref+=(-D "dfs.client.failover.proxy.provider.${alias_ns}=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider")
  return 0
}

########################################
# assert_no_collision_scratch_leak: guards the SAME-NAMESERVICE COLLISION
# path against the corruption class confirmed on iceberg_dr_test208.
# orders208 -- an OLDER ancestor's metadata.json/manifest-list, left
# behind by an EARLIER interrupted or partial collision-mode run, that
# still has a bare host:port authority baked into its content because
# rewrite_table_path's own blanket text substitution touches every
# occurrence across the WHOLE payload it rewrites, including ancestor
# entries OLDER than whatever start_version bounded THAT run's walk (see
# "CHAINED CROSS-CLUSTER REWRITES" in this script's header for the general
# mechanism -- this is that same class of corruption, confirmed to strike
# inside hop A/B's own intermediate content too, not only plain-prefix
# leakage). Once such a file exists, NEITHER an incremental NOR a full
# rewrite can walk past it cleanly: RewriteTablePathUtil.relativize()
# throws the instant it opens a path that does not start with the
# source_prefix it was told to expect.
#
# This cannot be fully prevented after the fact (an already-poisoned deep
# ancestor needs a manual reset -- see this script's own operator
# guidance for that). What CAN be prevented is trusting a table's CURRENT
# head silently: this checks one small, cheap file (never O(ancestor
# count) -- this is deliberately NOT the deep full-history scan a
# corrupted table would need, which is its own separate, explicit,
# operator-run diagnostic), and refuses the table outright with an
# actionable message instead of proceeding into a rewrite_table_path call
# that would fail confusingly 20-30 seconds later with a raw Java stack
# trace.
#
# DETECTION: the intermediate authority is a bare active-NameNode
# host:port, which is not one fixed, recognisable string -- whichever
# NameNode was active at the time of the interrupted run is the one that
# was left behind. So this checks for the SHAPE of a leaked authority
# instead of one specific value: after a clean run, every path in committed
# metadata must be "hdfs://${DST_NAMESERVICE}/..." (a logical nameservice
# name, never a literal host:port). Any "hdfs://<host>:<port>/" authority
# found is therefore a leak, regardless of which NameNode it names.
#
# Grep, not a JVM: content is stored as plain UTF-8 text inside Iceberg's
# Avro manifest-list/manifest files exactly as it is inside metadata.json
# (Avro string fields are length-prefixed UTF-8, not encoded/compressed),
# so a raw byte-level pattern search finds it in either file kind without
# needing Spark at all.
########################################
assert_no_collision_scratch_leak() {
  local file_path="$1" what="$2" qualified_table="$3"
  local content
  content=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${file_path}" 2>/dev/null) || {
    log_warn "Could not read ${what} (${file_path}) for ${qualified_table} to check for a leaked"
    log_warn "scratch authority -- proceeding without this check (a real read failure surfaces on its own shortly)."
    return 0
  }
  if grep -qaE 'hdfs://[A-Za-z0-9._-]+:[0-9]+/' <<< "${content}"; then
    log_error "${what} for ${qualified_table} contains a bare host:port HDFS authority (rather than the"
    log_error "logical '${DST_NAMESERVICE}' nameservice name) in its own content: ${file_path}"
    log_error "This means an EARLIER collision-mode run left this table's history poisoned -- most"
    log_error "likely a Hop A that staged content under a resolved NameNode's bare address and a Hop B"
    log_error "that never converted it back (interrupted mid-run, or a version of this script predating"
    log_error "this check). Neither an incremental nor a full rewrite_table_path can walk past a file"
    log_error "like this cleanly -- it will fail with 'does not start with hdfs://<prefix>/' deep inside"
    log_error "a Spark job, on this file or another one like it."
    log_error "This table needs a manual reset before collision-mode replication can trust it again:"
    log_error "drop and recreate ${qualified_table} on BOTH clusters (including its HDFS data under the"
    log_error "table's own directory), delete its checkpoint and *.collision_* marker files under"
    log_error "CHECKPOINT_DIR on both clusters, then re-bootstrap from a clean state."
    return 1
  fi
  return 0
}

########################################
# HA nameservice resolution for spark-sql AND `hadoop fs`/`hdfs`. Built
# ONCE, at the cluster level, before the per-table loop -- source and
# destination clusters cannot resolve each other's nameservice by name
# unless each host's hdfs-site.xml has been configured to know about the
# other's HA setup, and every table in one run shares the same two
# clusters, so a single set of overrides covers the whole run.
#
# Keyed by SRC_NAMESERVICE (the CLI arg, used here as a best-effort initial
# guess; each table's real logical source nameservice is verified against
# its own LOCATION inside the per-table function, with a loud warning if
# it differs) and DST_NAMESERVICE, which MUST be the destination's logical
# HA nameservice name for registered destination tables to be
# independently resolvable via HA failover. A literal host:port only works
# as long as that one NameNode stays master, defeating the purpose of HA.
#
# TWO SEPARATE PROCESSES need this, in TWO DIFFERENT FLAG SYNTAXES: `hadoop
# fs`/`hdfs` is a separate process from spark-sql with its own Hadoop
# client config resolution, and does not inherit spark-sql's `--conf
# spark.hadoop.*` settings at all.
#   - spark-sql: --conf spark.hadoop.<property>=<value>
#     (Spark forwards spark.hadoop.* into its own Hadoop Configuration.)
#   - hadoop/hdfs CLI (fs, dfsadmin, etc.): -D<property>=<value>
#     (Plain Hadoop generic options, spliced in right after the subcommand
#     token so they are parsed as client config, not a positional
#     argument.)
########################################
HA_CONF_ARGS=()
HDFS_HA_ARGS=()

# EXTRA_CATALOG_ARGS: caller-populated, consumed by run_spark_sql() exactly
# like HA_CONF_ARGS above -- empty by default (every normal call is
# unaffected), set by a caller immediately before run_spark_sql() to splice
# in one or more EXTRA `spark.sql.catalog.<name>.*` confs beyond the
# always-present ${SPARK_CATALOG} (Hive-backed) one, then reset to empty
# right after. Exists for the SAME-NAMESERVICE COLLISION temp-register/hop B
# calls, which need a SECOND, Hadoop-filesystem-backed catalog for their
# throwaway table -- see the "SAME-NAMESERVICE COLLISION" comment block
# further below for why a Hive Metastore catalog cannot be used for that
# throwaway entry at all.
EXTRA_CATALOG_ARGS=()

# Gated strictly on AUTO_DERIVE_HA_CLIENT_CONFIG (validated above: yes requires
# both SRC_NN_HOSTS and DST_NN_HOSTS to be set). When no (the default),
# this host's own Hadoop client config is assumed to already resolve both
# nameservices (e.g. a shared/merged hdfs-site.xml across the DR pair), and
# spark-sql/hadoop fs are left to use it as-is with no override at all.
if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
  # CRITICAL: do NOT call build_nameservice_ha_confs twice for the shared
  # name here, the way the branch below does for two genuinely distinct
  # names. SRC_NAMESERVICE and DST_NAMESERVICE are the IDENTICAL string in
  # this mode -- two calls against the same key would append duplicate
  # dfs.namenode.rpc-address.<name>.<nnid> entries (first from SRC_NN_HOSTS,
  # then from DST_NN_HOSTS) to the SAME global array, and Hadoop's
  # Configuration keeps only the LAST value set per key -- so DST_NN_HOSTS
  # would silently win for BOTH intended purposes, everywhere in this run,
  # exactly the "second call clobbers the first" failure this script's
  # SRC_NAMESERVICE==DST_NAMESERVICE guard (above) exists to prevent in the
  # first place. Leaving these GLOBAL arrays with NO override for the
  # shared name at all is the correct default: every call in this script
  # OTHER than hop A/hop B's own isolated overrides (see "SAME-NAMESERVICE
  # COLLISION" in this script's header) already wants the
  # shared name to keep meaning DESTINATION, which it does automatically
  # via this node's own unmodified hdfs-site.xml, with no injection needed.
  log_info "Collision mode: '${DST_NAMESERVICE}' resolves natively to DESTINATION at the cluster level;"
  log_info "hop A/B apply their own isolated overrides to reach SOURCE (see 'SAME-NAMESERVICE"
  log_info "COLLISION' in this script's header)."
elif [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.nameservices=${SRC_NAMESERVICE},${DST_NAMESERVICE}")
  HA_CONF_ARGS+=(--conf "spark.hadoop.dfs.ha.automatic-failover.enabled=${AUTOMATIC_FAILOVER_ENABLED,,}")
  HDFS_HA_ARGS+=(-D "dfs.nameservices=${SRC_NAMESERVICE},${DST_NAMESERVICE}")
  HDFS_HA_ARGS+=(-D "dfs.ha.automatic-failover.enabled=${AUTOMATIC_FAILOVER_ENABLED,,}")
  build_nameservice_ha_confs "$SRC_NAMESERVICE" "$SRC_NN_HOSTS"
  build_nameservice_ha_confs "$DST_NAMESERVICE" "$DST_NN_HOSTS"
  log_info "HA nameservices configured for spark-sql: ${SRC_NAMESERVICE}, ${DST_NAMESERVICE}"
else
  log_info "AUTO_DERIVE_HA_CLIENT_CONFIG=no -- relying on this host's own Hadoop client config"
  log_info "to resolve both nameservices (no -D/--conf HA overrides will be added)."
  # This is sound for a LOCAL driver/`hadoop fs` client, which reads this host's own
  # hdfs-site.xml off disk -- but a YARN executor container does NOT inherit
  # that file just because it exists on this host. Without an explicit
  # spark.hadoop.dfs.ha.namenodes.<nameservice> (etc.) passed via --conf, an
  # executor has no HA knowledge of either nameservice and can resolve it to
  # whichever NameNode it happens to hit first -- including a STANDBY one,
  # which fails hard with "Operation category READ is not supported in state
  # standby" and aborts the whole rewrite_table_path/copy job. This exact
  # failure mode is why this check exists: don't let SPARK_RUN_MODE=yarn run
  # with no HA config path into the executors.
  if [[ "${SPARK_MASTER}" == "yarn" ]]; then
    log_error "SPARK_RUN_MODE=yarn requires AUTO_DERIVE_HA_CLIENT_CONFIG=yes (with SRC_NN_HOSTS/DST_NN_HOSTS set)."
    log_error "Reason: YARN executor containers do not inherit this host's hdfs-site.xml, so with"
    log_error "AUTO_DERIVE_HA_CLIENT_CONFIG=no an executor has no HA config for '${SRC_NAMESERVICE}' or"
    log_error "'${DST_NAMESERVICE}' and can resolve either nameservice to a STANDBY NameNode, failing with"
    log_error "'Operation category READ is not supported in state standby'."
    log_error "Set AUTO_DERIVE_HA_CLIENT_CONFIG=yes and SRC_NN_HOSTS/DST_NN_HOSTS, or set SPARK_RUN_MODE=local."
    exit 1
  fi
fi
log_line ""

########################################
# CHECKPOINT_DIR pre-flight: ensure the checkpoint directory exists on BOTH
# SRC's and DST's HDFS before any table is processed -- once, at the
# cluster level, exactly like the HA config just above, rather than
# leaving directory creation to happen implicitly (and per-table) inside
# the first checkpoint write. Failing fast here, with both nameservices
# named explicitly, is a far clearer signal than discovering a
# permissions/connectivity problem only after STEP 1-6 of some table's
# replication has already run.
#
# PREREQUISITE: the identity this script runs `hadoop fs` as (the current
# Kerberos principal when KERBEROS_ENABLED=yes, otherwise HDFS_USER) must
# have permission to create and write under CHECKPOINT_DIR on BOTH
# clusters.
#
# SAME-NAMESERVICE COLLISION NOTE: SRC_NAMESERVICE and DST_NAMESERVICE are
# the IDENTICAL string in this mode, so both loop iterations below build
# the SAME "hdfs://<name>..." string and hit the SAME physical location
# (whichever cluster the shared name natively resolves to -- DESTINATION,
# per the "leave it un-overridden globally" note above). Checkpoint
# durability therefore degrades to "exists on DESTINATION only" in this
# mode, not truly mirrored on both clusters -- a known, accepted reduction
# in redundancy, not a correctness bug: checkpoint_read()/checkpoint_write()
# still work, they just have one real copy to fall back to instead of two.
########################################
# LOCAL LOCK DIRECTORY. The per-table flock files live in a LOCAL directory
# of the same name (see lock_file_for). Checked once, here, rather than
# discovered table by table: if this user cannot create files in it, no
# table could take its lock, and each one would be reported as "already
# being replicated by another invocation" -- a message that points away from
# the real cause. Typical when a different OS user ran the script first and
# owns the directory.
if ! mkdir -p "$CHECKPOINT_DIR" 2>/dev/null || [[ ! -d "$CHECKPOINT_DIR" || ! -w "$CHECKPOINT_DIR" ]]; then
  log_error "The local lock directory ${CHECKPOINT_DIR} (on this host's own disk, same path as CHECKPOINT_DIR) cannot be"
  log_error "created or written by OS user '$(id -un 2>/dev/null || echo unknown)'. Per-table lock files are kept there."
  log_error "Make it writable for this user (it may have been created by another user on an earlier run), then re-run."
  exit 1
fi
if [[ "$CHECKPOINT_DIR" == /tmp/* ]]; then
  log_info "Note: CHECKPOINT_DIR (${CHECKPOINT_DIR}) is under HDFS /tmp, which cluster cleanup policies often sweep."
  log_info "A swept checkpoint is not data loss -- the next run re-derives it from the destination table (auto-seed) --"
  log_info "but that costs one extra Spark lookup per table. A dedicated path outside /tmp avoids it."
fi
log_info "Ensuring checkpoint directory exists on both clusters..."
_checkpoint_hdfs_preflight_failed=false
for _ns in "$SRC_NAMESERVICE" "$DST_NAMESERVICE"; do
  _ckpt_dir="hdfs://${_ns}${CHECKPOINT_DIR}"
  if run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -mkdir -p "${_ckpt_dir}"; then
    log_info "  Confirmed/created: ${_ckpt_dir}"
  else
    log_error "  Could not create or access ${_ckpt_dir}."
    _checkpoint_hdfs_preflight_failed=true
  fi
done
unset _ns _ckpt_dir
if [[ "$_checkpoint_hdfs_preflight_failed" == "true" ]]; then
  log_error "CHECKPOINT_DIR (${CHECKPOINT_DIR}) is not usable on one or both clusters. Check that the user"
  log_error "this script runs HDFS commands as (the active Kerberos principal, or HDFS_USER='${HDFS_USER}'"
  log_error "when Kerberos is disabled) has permission to create/write under that path on both"
  log_error "${SRC_NAMESERVICE} and ${DST_NAMESERVICE}."
  exit 1
fi
unset _checkpoint_hdfs_preflight_failed
log_line ""

########################################
# Resolve the table set from INCLUDE_FILTERS: database name + table-name-
# or-regex rows. Populates the global RESOLVED_TABLES array with
# deduplicated "db.table" entries.
########################################

# parse_filter_spec: parse a "db1:regex1,db2:regex2,db3" spec into the
# global parallel arrays FILTER_DBS / FILTER_REGEXES (one entry per row). A
# bare "db" (no ":") becomes regex ".*" (every table in that database).
#
# Each row is trimmed of surrounding whitespace (so "db1:t1, db2" works),
# and the database name is lower-cased: Hive database and table names are
# case-insensitive and stored in lower case, and everything keyed on the
# qualified name downstream (the checkpoint file, the per-table lock, the
# de-duplication of rows) must see ONE spelling per table -- "DB1:t" and
# "db1:t" are the same table and must not get two checkpoints.
#
# A row that cannot be used is reported, recorded in FILTER_ERRORS and
# skipped; the other rows are still replicated, and the run ends FAILED
# (see the run summary) so the bad row cannot go unnoticed:
#   - a database name with anything but letters, digits and underscore
#     (nothing else can be a Hive database name, and the name is placed
#     into SQL statements and file names);
#   - a table regex that is not a valid regular expression. Without this
#     check such a row simply matches no table, silently.
# A structurally malformed row (empty database or empty regex) is still a
# startup error, as before.
FILTER_ERRORS=()
FILTER_WARNINGS=()
parse_filter_spec() {
  local spec="$1"
  FILTER_DBS=()
  FILTER_REGEXES=()
  FILTER_ROW_TEXT=()
  local row db_part regex_part _regex_rc
  split_filter_rows "$spec"
  for row in "${FILTER_ROWS[@]+"${FILTER_ROWS[@]}"}"; do
    row="${row#"${row%%[![:space:]]*}"}"
    row="${row%"${row##*[![:space:]]}"}"
    [[ -z "$row" ]] && continue
    if [[ "$row" == *:* ]]; then
      db_part="${row%%:*}"
      regex_part="${row#*:}"
    else
      db_part="$row"
      regex_part=".*"
    fi
    db_part="${db_part%"${db_part##*[![:space:]]}"}"
    regex_part="${regex_part#"${regex_part%%[![:space:]]*}"}"
    if [[ -z "$db_part" || -z "$regex_part" ]]; then
      log_error "Malformed filter entry '${row}' (expected 'database' or 'database:table_regex')"
      exit 1
    fi
    if [[ ! "$db_part" =~ ^[A-Za-z0-9_]+$ ]]; then
      log_error "INCLUDE_FILTERS row '${row}': '${db_part}' is not a valid database name (letters, digits and underscore only). Row skipped."
      FILTER_ERRORS+=("row '${row}': invalid database name '${db_part}'")
      continue
    fi
    db_part="${db_part,,}"
    # bash's =~ returns 2 (not 1) when the pattern itself does not compile.
    _regex_rc=0
    if [[ "probe" =~ ^(${regex_part})$ ]]; then :; else _regex_rc=$?; fi
    if [[ $_regex_rc -eq 2 ]]; then
      log_error "INCLUDE_FILTERS row '${row}': '${regex_part}' is not a valid regular expression. Row skipped -- NO table of '${db_part}' is replicated through this row."
      FILTER_ERRORS+=("row '${row}': invalid table regex '${regex_part}'")
      continue
    fi
    FILTER_DBS+=("$db_part")
    FILTER_REGEXES+=("$regex_part")
    FILTER_ROW_TEXT+=("$row")
  done
}

# list_tables_in_dbs: fetch "db<TAB>table" for every database named in
# dbs[] via ONE beeline process, instead of one `SHOW TABLES IN <db>`
# beeline launch per filter row. At INCLUDE_FILTERS scale in the
# hundreds/thousands of database rows, one beeline JVM start + ZooKeeper HS2
# discovery per row (several seconds each) turns table resolution alone
# into a multi-hour step.
#
# NOTE: information_schema.tables was tried here first and abandoned -- on
# this cluster it compiles to a real Tez/YARN job (15-30s of container
# launch per call) and returned zero rows for a database that demonstrably
# has tables, i.e. it is both slower AND unreliable here. `SHOW TABLES IN`
# is what actually works, so instead of one beeline call per database, a
# single beeline -e batches one "SHOW TABLES IN <db>;" per database,
# preceded by a `SELECT '<marker><db>'` sentinel row so the concatenated
# tsv2 output (which has no per-statement header) can be split back apart
# by database in bash. Every marker use the same literal tag
# (_LIST_TABLES_MARKER_) so a database or table name can never collide
# with it by accident.
list_tables_in_dbs() {
  local -n dbs_ref="$1"
  local db statements="" marker_stmt
  for db in "${dbs_ref[@]}"; do
    beeline_marker_stmt marker_stmt "_LIST_TABLES_MARKER_${db}"
    statements+="${marker_stmt} SHOW TABLES IN \`${db}\`; "
  done
  # Soft, not strict: the caller decides what a failure means (see
  # "Resolving table set" below) -- one database that cannot be listed must
  # not end the run for every other database.
  run_beeline_query_soft "${SRC_JDBC_URL}" "${statements}"
}

# parse_marked_table_listing: split list_tables_in_dbs' concatenated output
# back into TABLES_BY_DB[<db>] (newline-separated table names) and mark
# every database that produced at least one non-marker line in
# DBS_WITH_TABLES[<db>]=1.
parse_marked_table_listing() {
  local listing="$1"
  local line current_db=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    line="${line#"${BEELINE_MARKER_ROW_PREFIX}"}"
    if [[ "$line" == "_LIST_TABLES_MARKER_"* ]]; then
      current_db="${line#_LIST_TABLES_MARKER_}"
      continue
    fi
    [[ -z "$current_db" ]] && continue
    # A Hive table name is letters, digits and underscore. Anything else on
    # a line here is not a table -- it is a stray line of beeline/JVM
    # output that got past filter_beeline_noise -- and must not be taken
    # for one: under a ".*" regex it would "match" and be replicated as a
    # table that does not exist.
    if [[ ! "$line" =~ ^[A-Za-z0-9_]+$ ]]; then
      LISTING_IGNORED_LINES+=("$line")
      continue
    fi
    DBS_WITH_TABLES[$current_db]=1
    TABLES_BY_DB[$current_db]+="${line}"$'\n'
  done <<< "$listing"
}

log_line "$SUBSEP"
log_info "Resolving table set from INCLUDE_FILTERS..."
log_info "INCLUDE_FILTERS: ${INCLUDE_FILTERS}"

parse_filter_spec "$INCLUDE_FILTERS"
INCLUDE_DBS=("${FILTER_DBS[@]}")
INCLUDE_REGEXES=("${FILTER_REGEXES[@]}")

declare -A UNIQUE_DBS=()
UNIQUE_DB_LIST=()
for _db in "${INCLUDE_DBS[@]}"; do
  [[ -n "${UNIQUE_DBS[$_db]:-}" ]] && continue
  UNIQUE_DBS[$_db]=1
  UNIQUE_DB_LIST+=("$_db")
done

# One batched listing for every database. If it fails because of a
# DATABASE-level problem (a database that does not exist, or that this user
# may not list), each database is listed on its own instead, so only the
# one(s) that cannot be listed are dropped -- reported, recorded in
# FILTER_ERRORS, and the run ends FAILED -- while every other database is
# still replicated. Any other failure (HiveServer2 unreachable, bad
# credentials, ...) ends the run here, as it always did: retrying it once
# per database would only repeat the same failure many times over.
DB_LEVEL_ERROR_PATTERN='Database does not exist|\[Error 10072\]|NoSuchObjectException|HiveAccessControlException|does not have .*privilege|Permission denied'
declare -A UNLISTABLE_DBS=()
LISTING_IGNORED_LINES=()
ALL_SRC_TABLES=""
if [[ ${#UNIQUE_DB_LIST[@]} -gt 0 ]]; then
  _list_rc=0
  ALL_SRC_TABLES=$(list_tables_in_dbs UNIQUE_DB_LIST) || _list_rc=$?
  if [[ $_list_rc -ne 0 ]]; then
    if ! grep -qE "${DB_LEVEL_ERROR_PATTERN}" <<< "${ALL_SRC_TABLES}"; then
      report_beeline_failure "${SRC_JDBC_URL}" "${_list_rc}" "${ALL_SRC_TABLES}"
      exit 1
    fi
    log_warn "The batched table listing failed on at least one database; listing each database on its own so the rest are not affected..."
    ALL_SRC_TABLES=""
    for _db in "${UNIQUE_DB_LIST[@]}"; do
      _one_db=("$_db")
      _one_rc=0
      _one_out=$(list_tables_in_dbs _one_db) || _one_rc=$?
      if [[ $_one_rc -eq 0 ]]; then
        ALL_SRC_TABLES+="${_one_out}"$'\n'
      elif grep -qE "${DB_LEVEL_ERROR_PATTERN}" <<< "${_one_out}"; then
        _one_reason=$(grep -E '^Error: ' <<< "${_one_out}" | tail -n 1) || true
        log_error "Database '${_db}' could not be listed on the source: ${_one_reason#Error: }"
        log_error "Its filter row(s) are skipped -- NO table of '${_db}' is replicated by this run. Other databases are unaffected."
        FILTER_ERRORS+=("database '${_db}' could not be listed on the source")
        UNLISTABLE_DBS[$_db]=1
      else
        report_beeline_failure "${SRC_JDBC_URL}" "${_one_rc}" "${_one_out}"
        exit 1
      fi
    done
    unset _one_db _one_rc _one_out _one_reason
  fi
  unset _list_rc
fi

declare -A DBS_WITH_TABLES=()
declare -A TABLES_BY_DB=()
parse_marked_table_listing "$ALL_SRC_TABLES"
if [[ ${#LISTING_IGNORED_LINES[@]} -gt 0 ]]; then
  log_warn "Ignored ${#LISTING_IGNORED_LINES[@]} line(s) of the table listing that are not table names (first: '${LISTING_IGNORED_LINES[0]}')."
fi

declare -A SEEN_TABLES=()
RESOLVED_TABLES=()

for ((_i = 0; _i < ${#INCLUDE_DBS[@]}; _i++)); do
  _db="${INCLUDE_DBS[$_i]}"
  _regex="${INCLUDE_REGEXES[$_i]}"
  # Already reported (and recorded as a filter error) by the listing above.
  [[ -n "${UNLISTABLE_DBS[$_db]:-}" ]] && continue
  if [[ -z "${DBS_WITH_TABLES[$_db]:-}" ]]; then
    log_warn "No tables found for database '${_db}' (does it have any tables?); skipping filter row '${FILTER_ROW_TEXT[$_i]}'."
    FILTER_WARNINGS+=("row '${FILTER_ROW_TEXT[$_i]}': database '${_db}' has no tables")
    continue
  fi
  _row_matches=0
  # Case-insensitive match: Hive lists table names in lower case, so a
  # regex written with capitals ("ORDERS_.*") would otherwise match nothing.
  shopt -s nocasematch
  while IFS= read -r _tbl; do
    [[ -z "$_tbl" ]] && continue
    # Grouped, not just anchored: ^${_regex}$ without parens only anchors the
    # FIRST alternative of a top-level "|" on both ends and the LAST on
    # neither (ERE alternation binds looser than anchors), so
    # "orders_.*|invoices_.*" would let a table merely ENDING in
    # "invoices_.*" (e.g. "archived_invoices_2024") match as a false
    # positive. The group makes the anchors apply to the whole pattern.
    if [[ "$_tbl" =~ ^(${_regex})$ ]]; then
      _row_matches=$((_row_matches + 1))
      _key="${_db}.${_tbl}"
      if [[ -z "${SEEN_TABLES[$_key]:-}" ]]; then
        SEEN_TABLES[$_key]=1
        RESOLVED_TABLES+=("$_key")
        # RESOLVED_TABLES_LOG_LIMIT (env var, default 200): print one
        # "Included : ..." line per table only up to this many -- at
        # thousands of tables, one line each turns the run log itself into
        # the bottleneck to read, with no benefit (the final "Resolved N
        # table(s)" line below already gives the true count, and every
        # table's own outcome is still logged individually in the per-table
        # bucket lists at the end of the run).
        if [[ ${#RESOLVED_TABLES[@]} -le $RESOLVED_TABLES_LOG_LIMIT ]]; then
          log_info "  Included : ${_key}"
        fi
      fi
    fi
  done <<< "${TABLES_BY_DB[$_db]}"
  shopt -u nocasematch
  # A row that matches nothing replicates nothing. That can be intended (a
  # pattern for tables that do not exist yet), so it is a warning rather
  # than a failure -- but it must be said, since a mistyped pattern looks
  # exactly the same and would otherwise leave tables unprotected silently.
  if [[ $_row_matches -eq 0 ]]; then
    log_warn "Filter row '${FILTER_ROW_TEXT[$_i]}' matched NO table in database '${_db}' -- nothing is replicated through this row. Check the pattern if that is not intended."
    FILTER_WARNINGS+=("row '${FILTER_ROW_TEXT[$_i]}' matched no table")
  fi
done

if [[ ${#RESOLVED_TABLES[@]} -eq 0 ]]; then
  log_error "No tables matched INCLUDE_FILTERS."
  log_error "Check database names and regex patterns."
  exit 1
fi

if [[ ${#RESOLVED_TABLES[@]} -gt $RESOLVED_TABLES_LOG_LIMIT ]]; then
  log_info "  ... and $(( ${#RESOLVED_TABLES[@]} - RESOLVED_TABLES_LOG_LIMIT )) more (RESOLVED_TABLES_LOG_LIMIT=${RESOLVED_TABLES_LOG_LIMIT})"
fi

log_line ""
# The full name list is left OUT of this summary line once large -- at
# 10,000 tables "${RESOLVED_TABLES[*]}" alone is a single, effectively
# unreadable multi-hundred-KB log line for no benefit (every name already
# appeared, or was accounted for by the "... and N more" line, above).
if [[ ${#RESOLVED_TABLES[@]} -le $RESOLVED_TABLES_LOG_LIMIT ]]; then
  log_info "Resolved ${#RESOLVED_TABLES[@]} table(s) for this run: ${RESOLVED_TABLES[*]}"
else
  log_info "Resolved ${#RESOLVED_TABLES[@]} table(s) for this run (list suppressed above RESOLVED_TABLES_LOG_LIMIT=${RESOLVED_TABLES_LOG_LIMIT})."
fi
log_line ""

########################################
# Bucket arrays for the run summary. Declared here (before database
# creation) rather than right before the main per-table loop, since a
# database-creation failure below now needs to pre-populate FAILED_TABLES
# for that database's tables before the main loop even starts.
########################################
SUCCEEDED_TABLES=()
FAILED_TABLES=()
SKIPPED_TABLES=()
LOCKED_TABLES=()
# Per-table wall time, measured out here in the parent shell rather than
# read back from the flock subshell (whose variables do not survive it).
# Keyed by qualified table name, so the run summary can annotate every
# bucket entry with how long that table took.
declare -A TABLE_DURATIONS=()
# First [ERROR] message logged for a table that did not succeed (see
# TABLE_FIRST_ERROR_FILE next to the logging helpers), keyed by qualified
# table name. Shown under the table's name in the run summary's Failed and
# Locked buckets, so the summary says why, not only which.
declare -A TABLE_FAILURE_REASON=()

########################################
# Ensure every resolved table's database exists on the destination
# Metastore before any table-level replication is attempted. register_table
# (bootstrap) and the final SHOW TBLPROPERTIES validation both require the
# destination database to already exist. CREATE DATABASE IF NOT EXISTS is
# safe to repeat, so it is simply run once per unique destination database,
# with no existence check ahead of it.
#
# Deliberately bare (no LOCATION/COMMENT/DBPROPERTIES): this only unblocks
# table registration. It does not attempt to replicate database-level
# metadata, permissions, or placement from the source.
#
# A failure here used to `exit 1` the WHOLE script -- contradicting this
# script's own documented invariant that "one table's failure never blocks
# the others" (Multi-table mode, header block): a permissions issue on one
# database in a multi-database run killed every table in every OTHER
# database too, including ones that would have succeeded. Now it logs the
# failure, tracks the database in FAILED_DBS, and continues -- every table
# in a failed database is pre-emptively recorded as FAILED (not silently
# dropped) below, and only tables in databases that were actually created
# successfully reach the main per-table loop.
########################################
log_line "$SUBSEP"
log_info "Ensuring destination databases exist..."

declare -A SEEN_DBS=() FAILED_DBS=()
for _qualified in "${RESOLVED_TABLES[@]}"; do
  _db="${_qualified%%.*}"
  [[ -n "${SEEN_DBS[$_db]:-}" ]] && continue
  SEEN_DBS[$_db]=1
  log_info "  Ensuring database '${_db}' exists on destination..."
  run_beeline_statement "${DST_JDBC_URL}" "CREATE DATABASE IF NOT EXISTS \`${_db}\`;" || {
    log_error "Could not create destination database '${_db}' -- every table in this database will be"
    log_error "reported as FAILED below; tables in other databases are unaffected and still attempted."
    FAILED_DBS[$_db]=1
  }
done

# Build the actual set of tables the main loop will attempt: every resolved
# table EXCEPT those whose database failed above. RESOLVED_TABLES itself is
# left untouched (the "Resolved N table(s)" line above still refers to the
# true originally-resolved set) -- a separate array is used so the run
# summary can distinguish "resolved but never attempted" from "attempted".
TABLES_TO_REPLICATE=()
for _qualified in "${RESOLVED_TABLES[@]}"; do
  _db="${_qualified%%.*}"
  if [[ -n "${FAILED_DBS[$_db]:-}" ]]; then
    log_warn "  Skipping ${_qualified}: its database '${_db}' could not be created on the destination (see above)."
    FAILED_TABLES+=("$_qualified")
    TABLE_FAILURE_REASON[$_qualified]="its database '${_db}' could not be created on the destination"
    continue
  fi
  TABLES_TO_REPLICATE+=("$_qualified")
done
log_line ""

########################################
# prefetch_src_table_info: batch STEP 1's two per-table beeline calls
# (SHOW TBLPROPERTIES + DESCRIBE FORMATTED, against SOURCE) across EVERY
# table in TABLES_TO_REPLICATE via as few beeline JVM launches as possible,
# instead of one beeline launch per call per table. Populates
# SRC_TBLPROPERTIES_CACHE[qualified]/SRC_DESCRIBE_CACHE[qualified]; STEP 1
# (_replicate_one_table_locked, further below) reads from these first and
# only falls back to its own original per-table beeline call for a table
# whose cache entry came back empty.
#
# WHY THIS MATTERS MORE THAN QUIET_SKIP_LOG. STEP 1 runs for EVERY
# resolved table, unconditionally -- unlike STEPs 4-6, it is never skipped
# even for a confirmed no-op table, so at real fleet scale (10,000+ tables)
# its 2 beeline JVM launches per table (each several seconds: JVM start +
# ZooKeeper HS2 discovery) are pure multiplicative overhead paid by every
# single run regardless of how much actually changed. This mirrors
# EXACTLY the problem list_tables_in_dbs() already solved for table
# RESOLUTION (one beeline call covering many databases, split back apart
# by a sentinel marker) -- applied here to table PROPERTY reads instead.
#
# NOT applied to STEP 7's equivalent re-read: STEP 7 needs each table's
# CURRENT state as of AFTER that table's own replication work finished,
# and under PARALLEL_TABLES>1 different tables finish at different wall-
# clock times -- batching STEP 7 across tables would require holding
# every table back until the slowest one in the batch finishes (a
# synchronization barrier), which defeats the entire purpose of running
# tables in parallel. STEP 7 keeps its own per-table beeline calls.
#
# FAILURE HANDLING: this is a pure optimization, never a correctness
# dependency. A table with no cache entry is read by STEP 1's own
# per-table beeline call, so the worst a prefetch problem can do is cost
# time.
#   - Each table's statements travel as their own beeline -e (see
#     run_beeline_statements_soft), so a table that cannot be read (dropped
#     between table resolution and this prefetch, no privilege) ends only
#     its own -e. The tables after it are still read.
#   - When beeline reports a failure for a batch, only tables whose output
#     is known to be complete are kept: both of the table's markers were
#     seen, no "Error:" line fell inside its section, and another marker
#     follows it (the next table's, or the batch's end marker), which shows
#     its statements ran to the end. Everything else in that batch is
#     dropped from the cache. A truncated property list is therefore never
#     used as if it were whole.
#   - The end marker is only sent with BEELINE_MARKER_STYLE=set, where a
#     marker costs nothing. With the select style every marker is a query,
#     and one more per batch on every run is a poor trade for keeping the
#     last table of a batch that failed; that table falls back instead.
#   - A batch whose beeline call could not run at all caches nothing.
#
# Uses the same marker technique as list_tables_in_dbs/
# parse_marked_table_listing (see MARKER ROWS next to beeline_marker_stmt):
# a marker row naming the table precedes each real statement, so the
# concatenated tsv2 output (no per-statement header) can be split back
# apart by table afterward in bash.
########################################
declare -A SRC_TBLPROPERTIES_CACHE=()
declare -A SRC_DESCRIBE_CACHE=()

# PREFETCH_BATCH_MAX_CHARS: upper bound on the total length of the statement
# text one batched beeline call carries (the sum over its per-table -e
# arguments). It keeps a batch's command line well inside the kernel's
# limits (128 KiB per argument, about 2 MiB for the whole argument list on
# Linux) and bounds how much one failed beeline call can cost. The table
# list is split into as many batches as it takes; a fleet small enough to
# fit goes out as one call.
PREFETCH_BATCH_MAX_CHARS="${PREFETCH_BATCH_MAX_CHARS:-100000}"
if [[ ! "$PREFETCH_BATCH_MAX_CHARS" =~ ^[1-9][0-9]*$ ]]; then
  log_error "PREFETCH_BATCH_MAX_CHARS must be a positive integer (got '${PREFETCH_BATCH_MAX_CHARS}')"
  exit 1
fi

# _prefetch_src_batch <per-table statements>...: run ONE batch (one beeline
# call, one -e per argument) and fold its output into
# SRC_TBLPROPERTIES_CACHE/SRC_DESCRIBE_CACHE. Returns beeline's exit status.
# On a non-zero status only the tables whose output is known to be complete
# stay cached (see FAILURE HANDLING above); other batches are unaffected.
_prefetch_src_batch() {
  local _batch_output _batch_rc=0
  _batch_output=$(run_beeline_statements_soft "${SRC_JDBC_URL}" "$@") || _batch_rc=$?

  local _line _mode="" _cur="" _t
  local -a _seen=()
  local -A _has_desc=() _closed=() _errored=()
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _line="${_line#"${BEELINE_MARKER_ROW_PREFIX}"}"
    if [[ "$_line" == "_TP_MARKER_"* ]]; then
      [[ -n "$_cur" ]] && _closed[$_cur]=1
      _mode="tp"; _cur="${_line#_TP_MARKER_}"
      _seen+=("$_cur")
      continue
    fi
    if [[ "$_line" == "_DESC_MARKER_"* ]]; then
      _mode="desc"; _cur="${_line#_DESC_MARKER_}"
      _has_desc[$_cur]=1
      continue
    fi
    if [[ "$_line" == "_PREFETCH_END_MARKER_" ]]; then
      [[ -n "$_cur" ]] && _closed[$_cur]=1
      _mode=""; _cur=""
      continue
    fi
    [[ -z "$_cur" ]] && continue
    # beeline's own failure line for a statement. Never table content.
    if [[ "$_line" == "Error: "* ]]; then
      _errored[$_cur]=1
      continue
    fi
    case "$_mode" in
      tp)   SRC_TBLPROPERTIES_CACHE[$_cur]+="${_line}"$'\n' ;;
      desc) SRC_DESCRIBE_CACHE[$_cur]+="${_line}"$'\n' ;;
    esac
  done <<< "$_batch_output"

  if [[ $_batch_rc -ne 0 ]]; then
    for _t in "${_seen[@]+"${_seen[@]}"}"; do
      if [[ -n "${_errored[$_t]:-}" || -z "${_has_desc[$_t]:-}" || -z "${_closed[$_t]:-}" ]]; then
        unset 'SRC_TBLPROPERTIES_CACHE[$_t]' 'SRC_DESCRIBE_CACHE[$_t]'
      fi
    done
  fi
  return "$_batch_rc"
}

prefetch_src_table_info() {
  local -n _tables_ref="$1"
  if [[ ${#_tables_ref[@]} -eq 0 ]]; then
    return 0
  fi
  local _prefetch_start
  _prefetch_start=$(date +%s)
  local _qt _ref _tp_marker _desc_marker _end_marker _stmt
  local _batches=0 _failed_batches=0 _batch_chars=0
  local -a _batch=() _end_args=()
  if [[ "${BEELINE_MARKER_STYLE,,}" == "set" ]]; then
    beeline_marker_stmt _end_marker "_PREFETCH_END_MARKER_"
    _end_args=("${_end_marker}")
  fi
  for _qt in "${_tables_ref[@]}"; do
    # Same quoting as hive_table_ref, inline: no fork per table.
    _ref="\`${_qt%%.*}\`.\`${_qt#*.}\`"
    beeline_marker_stmt _tp_marker "_TP_MARKER_${_qt}"
    beeline_marker_stmt _desc_marker "_DESC_MARKER_${_qt}"
    _stmt="${_tp_marker} SHOW TBLPROPERTIES ${_ref}; ${_desc_marker} DESCRIBE FORMATTED ${_ref};"
    if [[ ${#_batch[@]} -gt 0 && $(( _batch_chars + ${#_stmt} )) -gt $PREFETCH_BATCH_MAX_CHARS ]]; then
      _batches=$((_batches + 1))
      _prefetch_src_batch "${_batch[@]}" "${_end_args[@]+"${_end_args[@]}"}" || _failed_batches=$((_failed_batches + 1))
      _batch=()
      _batch_chars=0
    fi
    _batch+=("$_stmt")
    _batch_chars=$(( _batch_chars + ${#_stmt} ))
  done
  if [[ ${#_batch[@]} -gt 0 ]]; then
    _batches=$((_batches + 1))
    _prefetch_src_batch "${_batch[@]}" "${_end_args[@]+"${_end_args[@]}"}" || _failed_batches=$((_failed_batches + 1))
  fi
  if [[ $_failed_batches -gt 0 ]]; then
    log_warn "Batched STEP 1 property prefetch: beeline reported a failure in ${_failed_batches} of ${_batches} batch(es) against source."
    log_warn "Tables it could not read completely fall back to a per-table beeline call (slower, but correctness is unaffected)."
  fi

  local _hit_count=0
  for _qt in "${_tables_ref[@]}"; do
    [[ -n "${SRC_TBLPROPERTIES_CACHE[$_qt]:-}" && -n "${SRC_DESCRIBE_CACHE[$_qt]:-}" ]] && _hit_count=$((_hit_count + 1))
  done
  log_info "STEP 1 property prefetch: ${_hit_count}/${#_tables_ref[@]} table(s) cached from ${_batches} batched beeline call(s) in $(format_duration "$(( $(date +%s) - _prefetch_start ))")"
  log_info "(marker style: ${BEELINE_MARKER_STYLE,,}). A table that is not cached is read by STEP 1's own per-table beeline call."
}

log_line "$SUBSEP"
log_info "Prefetching source table properties for STEP 1 (batched across all resolved tables)..."
prefetch_src_table_info TABLES_TO_REPLICATE
log_line ""

########################################
# Per-table lock: nothing else in this script prevents two invocations from
# racing on the SAME db.table (concurrent script runs, overlapping cron or
# Pulse Action triggers, etc.). The checkpoint path, STAGING_DIR, and the
# file-list/copy-list working files are all keyed by db.table, so same-named tables in
# DIFFERENT databases never collide -- but two runs against the SAME
# db.table would: both could read the same stale checkpoint, both write to
# the same STAGING_DIR mid-rewrite_table_path, and whichever run's
# checkpoint write finished last would silently clobber the other's. flock
# on a per-table lock file (CHECKPOINT_DIR/<db>.<table>.lock) closes this
# gap: a second invocation touching the same table while the first is still
# running fails fast with a clear error instead of racing silently.
#
# Uses `flock -n` (non-blocking) rather than blocking-and-waiting, since a
# queued-up second run would just replicate a now-stale delta anyway once
# it finally got the lock -- better to fail loudly and let the caller
# retry or reschedule than to silently queue.
#
# The lock is fd-scoped, not file-existence-scoped: flock holds the lock
# only as long as file descriptor 200 (opened via `exec 200<>lockfile`
# below) stays open in this subshell, and bash closes that fd
# automatically when the subshell exits -- on a clean return, an early
# `return 1`, or the process being killed. There is deliberately no
# "delete the lock file on exit" step: the lock file itself is left in
# place permanently (its mere existence is harmless and expected, since
# flock only cares whether an fd pointing at it is currently held), and
# unlinking it on exit would reopen exactly the TOCTOU race flock exists
# to prevent -- a second process could stat "does the lock file exist" in
# the gap between the first process's unlink and its own exit.
########################################
replicate_one_table() {
  local HIVE_DB="$1"
  local TABLE_NAME="$2"
  local TABLE_POSITION="${3:-}"
  local TABLE_TOTAL="${4:-}"
  local QUALIFIED_TABLE="${HIVE_DB}.${TABLE_NAME}"

  mkdir -p "$CHECKPOINT_DIR"
  local LOCK_FILE
  LOCK_FILE="$(lock_file_for "$HIVE_DB" "$TABLE_NAME")"

  (
    # See CURRENT_TABLE_LOG_TAG's own declaration near log_info/log_warn/
    # log_error for why this is set here: this whole block is a subshell
    # (forked memory only), so this assignment can never leak to another
    # table's concurrent subshell or back to the parent under
    # PARALLEL_TABLES>1.
    CURRENT_TABLE_LOG_TAG="[${QUALIFIED_TABLE}] "
    if [[ "$PARALLEL_TABLES" -gt 1 ]]; then
      RAW_LINE_TAG="$CURRENT_TABLE_LOG_TAG"
      RAW_LINE_TAG_SED="${RAW_LINE_TAG//\\/\\\\}"
      RAW_LINE_TAG_SED="${RAW_LINE_TAG_SED//&/\\&}"
      RAW_LINE_TAG_SED="${RAW_LINE_TAG_SED//\//\\/}"
    fi
    # A lock file that cannot be opened is its own failure, said plainly.
    # Left unchecked, the flock below would fail on the unopened descriptor
    # and report the table as locked by another run, which it is not.
    if ! { exec 200>"${LOCK_FILE}"; } 2>/dev/null; then
      log_error "Could not open the local lock file ${LOCK_FILE} for writing as OS user '$(id -un 2>/dev/null || echo unknown)'"
      log_error "(e.g. it was created by another user). Fix its ownership/permissions, or remove it if no run is active."
      exit 1
    fi
    if ! flock -n 200; then
      log_error "${QUALIFIED_TABLE} is already being replicated by another invocation (lock held on ${LOCK_FILE}). Skipping -- retry once the other run finishes."
      exit 3
    fi
    # Stage timers live and die with this subshell (its variables are
    # discarded on exit), so both the reset and the summary must happen
    # in here -- the parent loop cannot see STAGE_TIMING_* at all. The
    # EXIT trap is what guarantees the breakdown prints even when a table
    # returns early from the middle of a stage.
    local table_start
    table_start=$(date +%s)
    stage_timing_reset
    # Reset alongside the stage timers, for the same reason: LOCAL_FILE_LIST/
    # COPY_LIST_LOCAL are deliberately non-`local` inside
    # _replicate_one_table_locked so they survive its return (see their own
    # declarations), but each table's subshell still needs to start from a
    # clean slate rather than (harmlessly, since each fork is fresh from the
    # pristine parent, but for clarity/defense-in-depth) any prior value.
    LOCAL_FILE_LIST=""
    COPY_LIST_LOCAL=""
    trap '_table_exit_trap "${QUALIFIED_TABLE}" "${table_start}"' EXIT
    local rc=0
    _replicate_one_table_locked "${HIVE_DB}" "${TABLE_NAME}" "${TABLE_POSITION}" "${TABLE_TOTAL}" || rc=$?
    # Tag this run's file-list/copy-list CSVs (if any were created) so
    # KEEP_RUN_ARTIFACTS pruning permanently skips them -- matching the
    # documented invariant that "a FAILED run's artifacts are always left
    # in place, since they're needed for debugging" (see the pruning block
    # near the end of _replicate_one_table_locked). Only for a genuine
    # FAILURE (rc not 0/2/3): SKIPPED (2) and LOCKED (3) outcomes return
    # before STEP 5 ever creates these files, and a real SUCCESS (0)
    # doesn't need protecting. Uses `|| rc=$?`, not `; rc=$?` -- under this
    # script's `set -e`, a bare `cmd; rc=$?` aborts the subshell the
    # instant `cmd` returns non-zero, before `rc=$?` (or anything after it,
    # including this whole tagging block) ever runs.
    if [[ $rc -ne 0 && $rc -ne 2 && $rc -ne 3 ]]; then
      [[ -n "${LOCAL_FILE_LIST:-}" && -f "$LOCAL_FILE_LIST" ]] && mv -- "$LOCAL_FILE_LIST" "${LOCAL_FILE_LIST%.csv}.FAILED.csv"
      [[ -n "${COPY_LIST_LOCAL:-}" && -f "$COPY_LIST_LOCAL" ]] && mv -- "$COPY_LIST_LOCAL" "${COPY_LIST_LOCAL%.csv}.FAILED.csv"
    fi
    exit "$rc"
  )
  return $?
}

_replicate_one_table_locked() {
  local HIVE_DB="$1"
  local TABLE_NAME="$2"
  local TABLE_POSITION="${3:-}"
  local TABLE_TOTAL="${4:-}"
  local QUALIFIED_TABLE="${HIVE_DB}.${TABLE_NAME}"
  # The same name, quoted for HiveQL statements (see hive_table_ref).
  local HIVE_TABLE_REF
  HIVE_TABLE_REF=$(hive_table_ref "${QUALIFIED_TABLE}")

  # Copy statistics tracking (populated in STEP 5, reported in STEP 8)
  local FILES_TO_COPY=0
  local FILES_COPIED=0
  local FILES_SKIPPED=0
  local FILES_FAILED=0

  # apply_hive_engine_fixups: the Hive-engine INPUTFORMAT/OUTPUTFORMAT/
  # SERDE + storage_handler fixups every CALL system.register_table() call
  # needs (see the detailed explanation inside the function body). Shared
  # by every register_table call site in this function -- the real
  # bootstrap and the --rebuild-dst-table-from-source re-registration, on
  # BOTH the normal (non-collision) path and the SAME-NAMESERVICE
  # COLLISION path's own STEP 6.
  #
  # Defined HERE, unconditionally, at the very top of this function --
  # NOT nested inside one particular branch of STEP 6's own if/elif/else
  # (as an earlier version of this script had it) -- because a bash
  # function is only actually defined once its own "name() { ... }" line
  # executes, and only ONE branch of that if/elif/else ever runs per call.
  # A definition nested in the non-collision branch would simply not exist
  # when the collision branch runs, forcing each branch to carry its own
  # duplicate copy of this same SQL -- confirmed drift-prone in practice
  # (three near-identical copies before this was hoisted here). Defining it
  # once at the top, before any branch, means every call site -- regardless
  # of which path this table takes -- calls the exact same implementation.
  #
  # Three entry points share this one implementation:
  #   - register_bootstrap_fixups (right after register_table, STEP 6);
  #   - repair_unfinished_registration (STEP 3, for a table an earlier run
  #     registered and then stopped on before these ALTERs were applied);
  #   - STEP 7's check when REGISTER_HIVE_ENGINE_ENABLED=true deferred them.
  apply_hive_engine_fixups() {
    # CALL system.register_table() populates metadata_location and the
    # Iceberg-specific TBLPROPERTIES (table_type, current-snapshot-id, etc.)
    # correctly, but leaves the Metastore row missing what Hive's own SQL
    # engine (HiveServer2/beeline -- unlike Spark/Trino, which resolve the
    # table a different way) needs in order to run a `SELECT *` FetchTask
    # against it:
    #   1) INPUTFORMAT/OUTPUTFORMAT/SERDE are left at Spark's generic
    #      defaults (org.apache.hadoop.mapred.FileInputFormat/
    #      FileOutputFormat -- abstract base classes, not real
    #      implementations) instead of the real Hive-Iceberg classes.
    #      Symptom: "Cannot create an instance of InputFormat class
    #      org.apache.hadoop.mapred.FileInputFormat ... InstantiationException"
    #      (the class is abstract).
    #   2) The 'storage_handler' TBLPROPERTIES entry
    #      (org.apache.iceberg.mr.hive.HiveIcebergStorageHandler) is not set
    #      at all -- SHOW CREATE TABLE output right after register_table has
    #      no storage_handler row. Without it,
    #      HiveIcebergInputFormat.getSplits() ->
    #      org.apache.iceberg.mr.Catalogs.loadTable() has no catalog/
    #      identifier context and throws "IllegalArgumentException: Table
    #      identifier not set", even after fixing (1) above.
    # Both properties must be set explicitly, in this order, before a
    # Hive-engine SELECT * will succeed against a table registered this
    # way. Neither gap exists on the SOURCE table (never registered via
    # this path), so this is specific to register_table's Metastore row,
    # not a general Iceberg-on-Hive requirement.
    #
    # NOT NEEDED ON A HIVE BUILD WITH NATIVE ICEBERG SUPPORT. Confirmed
    # against Hive 4.1.0.3.3.6.5-1012: HiveCatalog's own register_table
    # commit already marks the table Iceberg-native, so the FILEFORMAT
    # ALTER below fails with Hive error 10134 ("ALTER TABLE can only be
    # used for [ADDPROPS, DROPPROPS, ADDCOLS, EXECUTE] to a non-native
    # table") -- which is Hive correctly refusing a no-longer-necessary
    # fixup, not a real failure. run_beeline_statement_tolerate_non_native
    # (used below instead of run_beeline_statement) recognizes exactly
    # this signature and treats it as already-correct.
    log_info "Fixing Hive InputFormat/OutputFormat/SerDe (register_table leaves these as generic Spark defaults)..."
    local FILEFORMAT_SQL="ALTER TABLE ${HIVE_TABLE_REF} SET FILEFORMAT
    INPUTFORMAT 'org.apache.iceberg.mr.hive.HiveIcebergInputFormat'
    OUTPUTFORMAT 'org.apache.iceberg.mr.hive.HiveIcebergOutputFormat'
    SERDE 'org.apache.iceberg.mr.hive.HiveIcebergSerDe';"
    log_info "Executing: ${FILEFORMAT_SQL}"
    run_beeline_statement_tolerate_non_native "${DST_JDBC_URL}" "${FILEFORMAT_SQL}" || {
      log_error "Setting Hive InputFormat/OutputFormat/SerDe failed for ${QUALIFIED_TABLE}."
      return 1
    }

    log_info "Fixing Hive storage_handler property (register_table does not set this either)..."
    local STORAGE_HANDLER_SQL="ALTER TABLE ${HIVE_TABLE_REF} SET TBLPROPERTIES (
    'storage_handler' = 'org.apache.iceberg.mr.hive.HiveIcebergStorageHandler'
  );"
    log_info "Executing: ${STORAGE_HANDLER_SQL}"
    run_beeline_statement_tolerate_non_native "${DST_JDBC_URL}" "${STORAGE_HANDLER_SQL}" || {
      log_error "Setting Hive storage_handler property failed for ${QUALIFIED_TABLE}."
      return 1
    }

    # Destination metadata.json retention is DELIBERATELY left untouched here (no
    # write.metadata.delete-after-commit.enabled / previous-versions-max ALTER TABLE).
    # See "DESTINATION METADATA RETENTION" in this script's header block for why: a
    # prior version of this script pruned the destination to 5 versions at
    # registration time, which is safe only as long as this table is never later
    # used as a SOURCE. Since failover/failback make that a real scenario, imposing
    # any retention cap here would silently set up the same
    # checkpoint-file-pruned-out-from-under-us failure this script's STEP 4 already
    # had to handle once, but sooner and on whichever side inherits the cap. Leaving
    # both sides at Iceberg's own default (unbounded metadata.json retention) keeps
    # them symmetric; an operator who wants bounded retention on whichever side is
    # currently the source should size it deliberately via table properties, not
    # inherit a value this script picked without knowing the table's role.
  }

  # register_bootstrap_fixups: what every register_table call site runs
  # right after a successful registration. Normally applies the fixups
  # straight away. With REGISTER_HIVE_ENGINE_ENABLED=true the registration
  # itself is expected to have written the same settings, so the ALTERs are
  # deferred: STEP 7 reads the destination's properties anyway, and applies
  # them there only if storage_handler is still missing.
  local HIVE_FIXUPS_DEFERRED=false
  register_bootstrap_fixups() {
    if register_hive_engine_enabled; then
      HIVE_FIXUPS_DEFERRED=true
      log_info "REGISTER_HIVE_ENGINE_ENABLED=true: register_table was asked to write the Hive InputFormat/OutputFormat/SerDe"
      log_info "and storage_handler itself; STEP 7 confirms that and applies the fixup ALTERs only if it did not."
      return 0
    fi
    apply_hive_engine_fixups
  }

  # repair_unfinished_registration <dst_tblproperties>: a destination table
  # that is registered but carries no storage_handler was registered by an
  # earlier run that stopped (a failed ALTER, a killed run) before the
  # fixups were applied. Such a table has no checkpoint yet, so the next run
  # reaches it through STEP 3's "destination already exists" handling, which
  # calls this before it writes the checkpoint: if the fixups fail again, no
  # checkpoint is written and the following run comes back here. A table
  # that already has storage_handler is left alone, at no cost -- the
  # properties passed in are the ones STEP 3 has already read.
  repair_unfinished_registration() {
    dst_missing_hive_storage_handler "$1" || return 0
    log_warn "Destination table ${QUALIFIED_TABLE} is registered but has no Hive storage_handler: an earlier run"
    log_warn "registered it and stopped before the Hive-engine fixups were applied. Applying them now."
    apply_hive_engine_fixups || {
      log_error "Could not complete the registration of ${QUALIFIED_TABLE} on the destination; no checkpoint is written,"
      log_error "so the next run retries this."
      return 1
    }
  }

  local _table_progress_suffix=""
  if [[ -n "$TABLE_POSITION" && -n "$TABLE_TOTAL" ]]; then
    _table_progress_suffix=" (table ${TABLE_POSITION}/${TABLE_TOTAL})"
  fi

  log_line "$SEP"
  log_line " Replicating: ${QUALIFIED_TABLE}${_table_progress_suffix}"
  log_line "$SEP"

  ########################################
  # [1/8] Verify the source table exists and is an Iceberg table.
  ########################################
  log_stage 1 "Verifying source table and reading Iceberg metadata pointer..."

  # Consult prefetch_src_table_info()'s batch cache first (see its own
  # header comment for the full rationale) -- only falls back to this
  # table's own beeline call when the cache has nothing for it (a total
  # batch failure, or this one table missing from an otherwise-successful
  # batch), so correctness never depends on the cache having been warm.
  local SRC_TBLPROPERTIES="${SRC_TBLPROPERTIES_CACHE[$QUALIFIED_TABLE]:-}"
  if [[ -z "$SRC_TBLPROPERTIES" ]]; then
    SRC_TBLPROPERTIES=$(fetch_tblproperties "${SRC_JDBC_URL}" "${QUALIFIED_TABLE}") || {
      log_error "Could not read table properties for ${QUALIFIED_TABLE} on source. Does the table exist?"
      return 1
    }
  fi

  if [[ -z "$SRC_TBLPROPERTIES" ]]; then
    log_error "Could not read table properties for ${QUALIFIED_TABLE} on source. Does the table exist?"
    return 1
  fi

  local SRC_TABLE_TYPE
  SRC_TABLE_TYPE=$(parse_tblproperty "$SRC_TBLPROPERTIES" table_type | tr '[:upper:]' '[:lower:]')
  if [[ "$SRC_TABLE_TYPE" != "iceberg" ]]; then
    log_warn "SKIP: ${QUALIFIED_TABLE} on source is not an Iceberg table (table_type='${SRC_TABLE_TYPE:-<unset>}')."
    log_warn "SKIP: A regex filter matched this table, but only Iceberg tables are replicated by this script."
    return 2
  fi

  local SRC_FORMAT_VERSION SRC_METADATA_LOCATION SRC_SNAPSHOT_COUNT SRC_SNAPSHOT_ID_STEP1
  SRC_FORMAT_VERSION=$(parse_tblproperty "$SRC_TBLPROPERTIES" format-version)
  SRC_METADATA_LOCATION=$(parse_tblproperty "$SRC_TBLPROPERTIES" metadata_location)
  # Read from the SAME property blob as SRC_METADATA_LOCATION, so the two
  # describe one and the same source version. Used by STEP 7 to recognise
  # that the destination landed exactly on that version (empty for a table
  # with no snapshot yet).
  SRC_SNAPSHOT_ID_STEP1=$(parse_tblproperty "$SRC_TBLPROPERTIES" current-snapshot-id)
  # Only consumed by STEP 2's deletion-vector probe, purely as a cheap
  # "is this table empty?" shortcut. Unlike metadata_location below, an
  # empty value here is NOT an error -- it just means the shortcut does not
  # apply and the real probe runs instead.
  SRC_SNAPSHOT_COUNT=$(parse_tblproperty "$SRC_TBLPROPERTIES" snapshot-count)
  if [[ -z "$SRC_METADATA_LOCATION" ]]; then
    log_error "Could not find 'metadata_location' table property on source for ${QUALIFIED_TABLE}."
    return 1
  fi

  log_info "Source metadata_location : ${SRC_METADATA_LOCATION}"
  log_info "Source format-version    : ${SRC_FORMAT_VERSION:-<unset>}"

  # Source table LOCATION (data+metadata directory root) via DESCRIBE FORMATTED
  local SRC_DESCRIBE SRC_TABLE_LOCATION
  SRC_DESCRIBE="${SRC_DESCRIBE_CACHE[$QUALIFIED_TABLE]:-}"
  if [[ -z "$SRC_DESCRIBE" ]]; then
    SRC_DESCRIBE=$(run_beeline_query_soft "${SRC_JDBC_URL}" "DESCRIBE FORMATTED ${HIVE_TABLE_REF};") || {
      log_error "DESCRIBE FORMATTED failed for ${QUALIFIED_TABLE} on source."
      return 1
    }
  fi
  # Hive right-pads "Location:" with spaces before the tab (e.g.
  # "Location:           \thdfs://..."), so an exact match against the
  # literal "Location:" never fires -- gsub trims that trailing padding
  # off $1 before comparing.
  SRC_TABLE_LOCATION=$(echo "$SRC_DESCRIBE" | awk -F'\t' '{k=$1; gsub(/[ \t]+$/,"",k)} k=="Location:"{print $2}' | head -n 1)
  if [[ -z "$SRC_TABLE_LOCATION" ]]; then
    # Fallback: some Hive versions render Location without a trailing colon key
    SRC_TABLE_LOCATION=$(echo "$SRC_DESCRIBE" | grep -i "^Location" | awk -F'\t' '{print $2}' | head -n 1)
  fi
  if [[ -z "$SRC_TABLE_LOCATION" ]]; then
    log_error "Could not determine table LOCATION for ${QUALIFIED_TABLE} on source."
    return 1
  fi
  log_info "Source table location: ${SRC_TABLE_LOCATION}"

  local TABLE_RELATIVE_PATH DST_TABLE_LOCATION
  TABLE_RELATIVE_PATH="${SRC_TABLE_LOCATION#hdfs://*/}"
  TABLE_RELATIVE_PATH="/${TABLE_RELATIVE_PATH}"
  DST_TABLE_LOCATION="hdfs://${DST_NAMESERVICE}${TABLE_RELATIVE_PATH}"

  # Derive the actual source prefix from the table's real LOCATION, not from
  # the user-supplied SRC_NAMESERVICE argument -- the two are not guaranteed
  # to match. A table's LOCATION/metadata_location typically embeds the
  # logical HA nameservice (e.g. "ODP-Phoenix"), while SRC_NAMESERVICE/
  # DST_NAMESERVICE are often passed as literal host:port authorities.
  # rewrite_table_path's source_prefix must exactly match what is actually
  # embedded in the table's metadata files, or it silently rewrites zero
  # paths (no error -- it just finds nothing to replace). Deriving
  # SRC_PREFIX by stripping the already-computed TABLE_RELATIVE_PATH suffix
  # off SRC_TABLE_LOCATION, instead of reassembling it from SRC_NAMESERVICE,
  # avoids that mismatch entirely.
  local SRC_PREFIX DST_PREFIX STAGING_DIR STAGING_LOCATION
  SRC_PREFIX="${SRC_TABLE_LOCATION%"${TABLE_RELATIVE_PATH}"}"
  DST_PREFIX="hdfs://${DST_NAMESERVICE}"
  STAGING_DIR="${STAGING_ROOT}${TABLE_RELATIVE_PATH}"
  # STAGING_LOCATION: STAGING_DIR qualified with the destination nameservice.
  # This, not the bare STAGING_DIR, is what the normal (non-collision) path
  # passes to rewrite_table_path as staging_location. A scheme-less path
  # would be resolved against the default filesystem of whichever host runs
  # spark-sql, while every later step (the [5b] staging check, the copy
  # list's source column, the post-run cleanup) addresses staging as
  # "hdfs://<DST_NAMESERVICE><STAGING_DIR>" -- the two only agree when the
  # script happens to run on a destination-cluster host. Qualifying it makes
  # staging land on the destination cluster regardless of where the script
  # is launched from, e.g. a failover run started from the same host that
  # normally runs the opposite direction.
  STAGING_LOCATION="hdfs://${DST_NAMESERVICE}${STAGING_DIR}"

  log_info "Destination table location: ${DST_TABLE_LOCATION}"
  log_info "Staging directory         : ${STAGING_LOCATION}"
  log_info "Derived source_prefix     : ${SRC_PREFIX}"

  # SRC_NAMESERVICE is still required (used for CLI validation, documentation,
  # matching your inventory, and to build the cluster-level HA conf above),
  # but warn loudly per-table if it does not match what is actually embedded
  # in THIS table, since that mismatch is otherwise invisible -- e.g. a
  # multi-table run where one database's tables live under a different
  # nameservice than the others.
  if [[ "${SRC_PREFIX}" != "hdfs://${SRC_NAMESERVICE}" ]]; then
    log_warn "SRC_NAMESERVICE argument ('${SRC_NAMESERVICE}') does not match the"
    log_warn "authority actually embedded in ${QUALIFIED_TABLE}'s LOCATION ('${SRC_PREFIX#hdfs://}')."
    log_warn "The cluster-level HA nameservice config was built from SRC_NAMESERVICE;"
    log_warn "if this table's real nameservice differs and isn't covered by that config,"
    log_warn "rewrite_table_path/the Spark copier may fail to resolve it. Re-run with SRC_NAMESERVICE"
    log_warn "set to this table's real value if that happens, or ensure SRC_NN_HOSTS covers"
    log_warn "every distinct source nameservice in play across this run's tables."
  fi
  log_line ""

  ########################################
  # --seed-checkpoint short-circuits HERE, entirely before STEP 2's v3/
  # deletion-vector gate below: seeding only reads metadata (this table's
  # checkpoint file, destination's current properties, source's metadata
  # log) and writes a checkpoint file -- it never calls rewrite_table_path,
  # so it has no dependency whatsoever on this runtime's ability to rewrite
  # deletion vectors. Running the DV/runtime-version gate first (as this
  # code used to) wrongly refused to seed a checkpoint for a v3 table
  # carrying deletion vectors on an old runtime, even though seeding
  # doesn't touch that code path at all.
  ########################################

  if [[ "$SEED_CHECKPOINT_ONLY" == "true" ]]; then
    log_stage 3 "Reading checkpoint (anchor) for ${QUALIFIED_TABLE}..."
    # The checkpoint must always be seeded from a value in SOURCE's own
    # metadata log, never destination's: rewrite_table_path's start_version
    # validation always checks against the SOURCE table's own metadata log,
    # and a destination-side filename can never appear there. Seeding from
    # source's CURRENT metadata_location is also wrong whenever the
    # destination is a true prefix of source's history but behind it (the
    # documented, intended use of --seed-checkpoint: "DR already has data
    # from some other tool," which may be caught up to any earlier point in
    # source's timeline, not necessarily source's current state) -- doing so
    # would make start_version == end_version on the next incremental run,
    # silently skipping every source write between the destination's real
    # state and source's current state.
    #
    # The correct value is destination's OWN current-snapshot-id, resolved
    # against SOURCE's metadata_log_entries metadata table to find the
    # metadata.json that was source's current version AT THE TIME that
    # snapshot-id was introduced. This only works when destination's data is
    # genuinely a prefix of source's own history (its snapshot-id must exist
    # in source's log) -- if it does not (destination has independently
    # written data unrelated to source), this correctly fails rather than
    # silently seeding a wrong value.
    log_info "Requiring destination table to exist first (this is what --seed-checkpoint is FOR: pre-seeding before a real run)..."
    # NOTE: a transient beeline/connectivity failure and a genuine "table
    # not found" both currently produce an empty DST_SEED_METADATA_LOCATION
    # below -- there's no robust, version-independent way to tell them
    # apart from HS2's error text (it varies by Hive version), so this is a
    # deliberately accepted ambiguity. Blast radius is limited to this
    # explicit, human-run maintenance command.
    local DST_TBLPROPERTIES_SEED DST_SEED_METADATA_LOCATION DST_SEED_SNAPSHOT_ID
    DST_TBLPROPERTIES_SEED=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || true
    # Test the PARSED metadata_location field, not DST_TBLPROPERTIES_SEED's
    # raw emptiness: a real "table not found" HS2 error is non-empty TEXT
    # (an error message), so testing the raw blob for emptiness never
    # actually triggers on a missing table -- it falls through and hits the
    # generic "no current-snapshot-id" error below instead, misreporting a
    # SKIP-worthy condition as a hard failure.
    DST_SEED_METADATA_LOCATION=$(parse_tblproperty "$DST_TBLPROPERTIES_SEED" metadata_location)
    if [[ -z "$DST_SEED_METADATA_LOCATION" ]]; then
      log_warn "SKIP: --seed-checkpoint requires ${QUALIFIED_TABLE} to already exist on the destination (e.g. DR populated by some other tool)."
      return 2
    fi
    DST_SEED_SNAPSHOT_ID=$(parse_tblproperty "$DST_TBLPROPERTIES_SEED" current-snapshot-id)
    if [[ -z "$DST_SEED_SNAPSHOT_ID" ]]; then
      log_error "Destination table ${QUALIFIED_TABLE} has no 'current-snapshot-id' property; cannot seed checkpoint."
      return 1
    fi

    log_info "Resolving destination's current-snapshot-id (${DST_SEED_SNAPSHOT_ID}) against SOURCE's metadata log..."
    local SRC_SEED_METADATA_FILENAME
    SRC_SEED_METADATA_FILENAME=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${DST_SEED_SNAPSHOT_ID}") || {
      log_error "Could not query source's metadata_log_entries for ${QUALIFIED_TABLE}."
      return 1
    }
    if [[ -z "$SRC_SEED_METADATA_FILENAME" ]]; then
      log_error "Destination's current-snapshot-id (${DST_SEED_SNAPSHOT_ID}) was not found in source's own metadata log for ${QUALIFIED_TABLE}. This means destination's data does NOT trace back to a real point in source's history (e.g. independently-written rows) -- --seed-checkpoint cannot safely seed a checkpoint for it."
      log_error "Drop and recreate the destination table to force a real bootstrap instead."
      return 1
    fi
    checkpoint_write "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE" "$SRC_SEED_METADATA_FILENAME" || return 1
    log_info "Checkpoint seeded: ${SRC_SEED_METADATA_FILENAME}"
    log_info "This is the metadata.json that was SOURCE's own current version at the exact point destination's current-snapshot-id was introduced -- the next incremental run replicates everything source has gained since THAT point (not just since right now), so no writes are silently skipped."
    return 0
  fi

  ########################################
  # [2/8] Version alignment check (mandatory prerequisite).
  #
  # Two separate things are checked here:
  #   a) PLATFORM version skew between the clusters. Best-effort only: it is
  #      meaningful only once the destination table is registered, and a
  #      full platform check is expected to have been performed as part of
  #      the Part B cutover (both clusters upgraded to the same ODP release)
  #      before this script is ever invoked in incremental mode.
  #   b) The source table's ICEBERG FORMAT-VERSION, which IS a hard gate.
  #      v2 and v3 are both supported; v3 additionally depends on the
  #      Iceberg runtime when the table carries deletion vectors. See
  #      "ICEBERG FORMAT-VERSION SUPPORT (v2 AND v3)" in the header block
  #      for the whole picture -- this is the code that enforces it.
  ########################################
  log_stage 2 "Checking source/destination version alignment..."

  if [[ -z "${SRC_FORMAT_VERSION:-}" ]]; then
    log_warn "Could not determine source Iceberg format-version; proceeding without a version-skew check."
  elif [[ ! "${SRC_FORMAT_VERSION}" =~ ^[0-9]+$ ]]; then
    log_warn "Source Iceberg format-version '${SRC_FORMAT_VERSION}' is not a number; proceeding without a format-version check."
  elif [[ "${SRC_FORMAT_VERSION}" -le 2 ]]; then
    # The v1/v2 path, i.e. every table in the current fleet. Nothing below
    # this point runs for them: no extra spark-sql probe, no added runtime
    # cost, no behavioural change from before v3 support existed.
    log_info "Iceberg format-version ${SRC_FORMAT_VERSION}: fully supported, no deletion vectors possible."
  else
    # format-version >= 3.
    if [[ "${SRC_FORMAT_VERSION}" -gt 3 ]]; then
      # v4 is already accepted by newer Iceberg runtimes
      # (TableMetadata.SUPPORTED_TABLE_FORMAT_VERSION = 4 as of 1.10) but
      # nothing above v3 has been validated through this pipeline. Warn and
      # then apply the v3 deletion-vector gate anyway, which is the closest
      # correct approximation.
      log_warn "Source Iceberg format-version is ${SRC_FORMAT_VERSION}, beyond the v3 this pipeline has been validated against."
      log_warn "Proceeding under the v3 rules; verify the replicated table on the destination before relying on it."
    fi

    if runtime_supports_dv_rewrite; then
      log_info "Iceberg format-version ${SRC_FORMAT_VERSION}: fully supported ($(describe_dv_runtime)), deletion vectors included."
    else
      # Runtime predates the deletion-vector path rewriting added in
      # Iceberg 1.11.0 (PR #14351). A v3 table is still replicable here as
      # long as it does not actually contain any DV, so probe the table
      # rather than refusing every v3 table outright.
      #
      # Both rc variables are captured explicitly via `|| rc=$?` rather than
      # called bare and read with `return $?`: under `set -e` a bare call
      # returning non-zero aborts the function before the `return` can run.
      # That happens to yield the same status today (this all runs inside the
      # flock subshell, whose exit status becomes the table's result), but it
      # is an accident of structure, not something to depend on.
      local DV_PROBE_RC=0 V3_OUTCOME_RC=0
      log_info "Deletion-vector rewriting unavailable ($(describe_dv_runtime); needs ${ICEBERG_MIN_DV_RUNTIME}+)."
      log_info "Checking whether ${QUALIFIED_TABLE} actually uses deletion vectors..."
      table_has_deletion_vectors \
        "${SRC_METASTORE_URI}" "${QUALIFIED_TABLE}" "${SRC_SNAPSHOT_COUNT:-}" || DV_PROBE_RC=$?

      case "$DV_PROBE_RC" in
        1)
          log_info "No deletion vectors found: format-version ${SRC_FORMAT_VERSION} is replicable on this runtime."
          log_warn "This table becomes unreplicable here the moment a positional delete (UPDATE/DELETE/MERGE,"
          log_warn "or a compaction that produces one) writes its first deletion vector. Upgrading the Iceberg"
          log_warn "runtime to ${ICEBERG_MIN_DV_RUNTIME}+ removes that cliff edge."
          ;;
        0)
          log_error "${QUALIFIED_TABLE} is format-version ${SRC_FORMAT_VERSION} and carries deletion vectors (Puffin delete files),"
          log_error "but this Iceberg runtime cannot rewrite their paths ($(describe_dv_runtime))."
          log_error "rewrite_table_path would fail in STEP 4 with: Unsupported file format: PUFFIN"
          log_error "A deletion vector records its data file's path BOTH in the manifest entry and inside the"
          log_error "Puffin blob; rewriting both only landed in Iceberg ${ICEBERG_MIN_DV_RUNTIME} (PR #14351)."
          log_error "FIX: upgrade the Iceberg runtime to ${ICEBERG_MIN_DV_RUNTIME}+, or set ICEBERG_DV_SUPPORT=true if"
          log_error "this build backported that fix without bumping its reported version."
          unsupported_v3_outcome "${QUALIFIED_TABLE}" || V3_OUTCOME_RC=$?
          return "$V3_OUTCOME_RC"
          ;;
        *)
          log_error "Could not determine whether ${QUALIFIED_TABLE} uses deletion vectors (the all_delete_files probe failed)."
          log_error "Refusing to replicate a format-version ${SRC_FORMAT_VERSION} table that cannot be proven free of them on a"
          log_error "runtime older than Iceberg ${ICEBERG_MIN_DV_RUNTIME}: an unhandled deletion vector yields a destination"
          log_error "table whose deletes still point at the source cluster."
          unsupported_v3_outcome "${QUALIFIED_TABLE}" || V3_OUTCOME_RC=$?
          return "$V3_OUTCOME_RC"
          ;;
      esac
    fi
  fi
  log_line ""

  ########################################
  # [3/8] Determine bootstrap vs. incremental mode from the CHECKPOINT (the
  # "anchor"; see the header block's "Note on table location & the
  # checkpoint" for the full model). checkpoint_read() reads it from HDFS
  # -- see its own comment above.
  ########################################
  log_stage 3 "Reading checkpoint (anchor) for ${QUALIFIED_TABLE}..."

  # FORCE_FULL_REWRITE: set only by the --rebuild-dst-table-from-source path
  # below. Distinct from BOOTSTRAP -- that flag alone conflates "full vs.
  # incremental rewrite_table_path call" with "register_table vs. ALTER
  # TABLE repoint", and force-reseed needs a combination neither existing
  # value expresses: a FULL rewrite (no valid start_version exists, since
  # destination's data doesn't trace back to any point in source's log),
  # but neither a plain ALTER TABLE repoint NOR a direct register_table
  # (the destination table already exists under its original name, so a
  # repoint is rejected by Hive's cross-table-uuid check and register_table
  # would throw AlreadyExistsException) -- see step 6/8 below, where this
  # resolves to renaming the existing table out of the way and then
  # register_table-ing the freed name.
  #
  # EMPTY_DST_FULL_REWRITE: set only by the "destination exists, is still
  # empty, and is the same table" case below. Like FORCE_FULL_REWRITE it
  # needs a FULL rewrite (there is no snapshot to derive a start_version
  # from), but unlike it the table-uuid matches, so STEP 6 takes the normal
  # ALTER TABLE repoint -- no rename, no re-registration.
  local BOOTSTRAP CHECKPOINT_METADATA="" FORCE_FULL_REWRITE=false EMPTY_DST_FULL_REWRITE=false
  log_substage "Read existing checkpoint"
  if CHECKPOINT_METADATA=$(checkpoint_read "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE"); then
    if [[ -z "$CHECKPOINT_METADATA" ]]; then
      log_warn "Checkpoint file exists but is empty; treating as bootstrap."
      BOOTSTRAP=true
    else
      log_info "Checkpoint found (${SRC_NAMESERVICE} -> ${DST_NAMESERVICE}): ${CHECKPOINT_METADATA}"
      log_info "Table '${QUALIFIED_TABLE}' has a prior anchor for this direction - Incremental replication mode"
      BOOTSTRAP=false

      # CHECKPOINTS IN BOTH DIRECTIONS. A table that was replicated in both
      # directions without the old direction's checkpoint being retired (see
      # DIRECTION FLIP below) has two live cursors, and at most one of them
      # reflects the pair's current roles. This direction's own checkpoint
      # may be the stale one -- written before the other cluster took over
      # as primary -- and replicating from it would end in a repoint over
      # whatever the destination wrote in the meantime. So when this run is
      # about to replicate (source has moved past the checkpoint) and an
      # opposite-direction checkpoint is also present, the anchor is
      # re-derived rather than trusted: the destination's own
      # current-snapshot-id is resolved against source's history, exactly as
      # a direction flip resolves it, and the opposite checkpoint is retired,
      # which makes this a one-time step per table.
      #   - snapshot found in source's metadata log -> that version becomes
      #     this direction's checkpoint;
      #   - not in the metadata log, but still in source's snapshot set ->
      #     the destination is behind source, not diverged; the existing
      #     checkpoint is kept;
      #   - in neither -> refused. The destination's current state cannot be
      #     shown to be part of source's history; nothing is changed.
      # Costs one `hadoop fs` launch when no opposite checkpoint exists, and
      # nothing at all on a no-op run (no repoint happens there, so nothing
      # is at risk).
      local BOTH_FORWARD_NAME BOTH_REVERSE_NAME
      BOTH_FORWARD_NAME=$(checkpoint_basename_for "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")
      BOTH_REVERSE_NAME=$(checkpoint_basename_for "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE")
      if [[ "$BOTH_REVERSE_NAME" != "$BOTH_FORWARD_NAME" && "$CHECKPOINT_METADATA" != "$SRC_METADATA_LOCATION" ]] \
         && checkpoint_present "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE"; then
        log_warn "Checkpoints exist for BOTH directions of ${QUALIFIED_TABLE} (${SRC_NAMESERVICE} -> ${DST_NAMESERVICE} and ${DST_NAMESERVICE} -> ${SRC_NAMESERVICE})."
        log_warn "This direction's checkpoint may predate a role change, so its anchor is re-derived from the destination's current snapshot before anything is replicated."
        local BOTH_DST_TBLPROPERTIES BOTH_DST_METADATA_LOCATION BOTH_DST_SNAPSHOT_ID BOTH_ANCHOR="" BOTH_REFUSAL=""
        BOTH_DST_TBLPROPERTIES=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || {
          log_error "Could not read destination table properties for ${QUALIFIED_TABLE}; cannot confirm the destination's state before replicating over it."
          return 1
        }
        BOTH_DST_METADATA_LOCATION=$(parse_tblproperty "$BOTH_DST_TBLPROPERTIES" metadata_location)
        BOTH_DST_SNAPSHOT_ID=$(parse_tblproperty "$BOTH_DST_TBLPROPERTIES" current-snapshot-id)
        if [[ -z "$BOTH_DST_METADATA_LOCATION" ]]; then
          log_error "Destination table ${QUALIFIED_TABLE} reported no 'metadata_location'; cannot confirm its state before replicating over it."
          return 1
        fi
        if [[ -n "$BOTH_DST_SNAPSHOT_ID" ]]; then
          BOTH_ANCHOR=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${BOTH_DST_SNAPSHOT_ID}") || {
            log_error "Could not query source's metadata_log_entries for ${QUALIFIED_TABLE}."
            return 1
          }
          if [[ -z "$BOTH_ANCHOR" ]]; then
            local BOTH_SRC_HAS_RC=0
            src_snapshot_exists "${QUALIFIED_TABLE}" "${BOTH_DST_SNAPSHOT_ID}" || BOTH_SRC_HAS_RC=$?
            case "$BOTH_SRC_HAS_RC" in
              0) log_info "Destination's current-snapshot-id (${BOTH_DST_SNAPSHOT_ID}) is no longer in source's metadata log but is still in source's snapshot set: the destination is behind source, not diverged." ;;
              1) BOTH_REFUSAL="the destination's current-snapshot-id (${BOTH_DST_SNAPSHOT_ID}) is in neither source's metadata log nor source's snapshot set" ;;
              *) BOTH_REFUSAL="source's snapshot set could not be queried to confirm the destination's current-snapshot-id (${BOTH_DST_SNAPSHOT_ID}) is part of source's history" ;;
            esac
          fi
        fi
        if [[ -n "$BOTH_REFUSAL" ]]; then
          log_error "Not replicating ${QUALIFIED_TABLE}: ${BOTH_REFUSAL}."
          log_error "The destination's current state cannot be shown to be part of source's history, so repointing it"
          log_error "at source's state could drop commits made on the destination that never reached source (e.g."
          log_error "written while this cluster was primary). Nothing has been changed by this run."
          log_error "To proceed: sync the destination's own commits to the other cluster first if they are needed."
          log_error "If the destination's current state is to be superseded by source's, remove this direction's"
          log_error "checkpoint and re-run with --rebuild-dst-table-from-source, which keeps the existing destination"
          log_error "table as a renamed backup:"
          log_error "  $(checkpoint_hdfs_path_for "$SRC_NAMESERVICE" "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")"
          log_error "  $(checkpoint_hdfs_path_for "$DST_NAMESERVICE" "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")"
          return 1
        fi
        checkpoint_retire "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE" || {
          log_error "Could not retire the opposite direction's checkpoint for ${QUALIFIED_TABLE}; not proceeding."
          log_error "Nothing has been replicated by this run -- the next run retries from the same state."
          return 1
        }
        if [[ -n "$BOTH_ANCHOR" && "$BOTH_ANCHOR" != "$CHECKPOINT_METADATA" ]]; then
          checkpoint_write "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE" "$BOTH_ANCHOR" || {
            log_error "Could not write the re-derived checkpoint for ${QUALIFIED_TABLE}; not proceeding."
            return 1
          }
          log_info "This direction's checkpoint re-anchored at the destination's current snapshot: ${CHECKPOINT_METADATA##*/} -> ${BOTH_ANCHOR##*/}"
          CHECKPOINT_METADATA="$BOTH_ANCHOR"
        else
          log_info "This direction's checkpoint is confirmed usable and kept as is: ${CHECKPOINT_METADATA##*/}"
        fi
      fi
    fi
  else
    # DIRECTION FLIP (failover / failback). No checkpoint exists for this
    # direction, but one may exist for the OPPOSITE direction -- the cursor
    # left behind from when the two clusters' roles were the other way
    # around. Its value is not reusable here: it names a metadata.json in the
    # old source's history, and a checkpoint must name one in THIS
    # direction's source. Only its presence is used, as the signal that the
    # roles have flipped. The anchor for the new direction is resolved the
    # same way auto-seed resolves it: the destination's own
    # current-snapshot-id, looked up in the new source's metadata log.
    #
    # When that resolves, the opposite direction's checkpoint is RETIRED
    # (checkpoint_retire(): renamed to "<name>.superseded" on both clusters,
    # never deleted) before this direction's checkpoint is written. After a
    # flip that old cursor is stale by definition. Left in place, the next
    # flip back would find it, skip this resolution, and replicate from a
    # point that predates everything the other cluster wrote in between --
    # ending in a repoint that can drop destination commits that never
    # reached source. With it retired, every flip comes back through this
    # resolution, and a destination whose current snapshot is not in source's
    # history is refused by the auto-seed path below.
    #
    # ORDER: retire first, write second. If the retire fails, the table fails
    # with nothing written, so the next run finds the same state and tries
    # again. Writing first would leave a checkpoint for this direction in
    # place, and this block would never run again to finish the retire.
    #
    # SAME-NAMESERVICE COLLISION: checkpoint_basename_for() yields one name
    # for both directions there (it appends the metastore hosts in a fixed
    # order), so the opposite-direction read below returns nothing and this
    # block does not act on that path; auto-seed below covers it.
    local REVERSE_CHECKPOINT_METADATA=""
    REVERSE_CHECKPOINT_METADATA=$(checkpoint_read "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE" 2>/dev/null) || true
    # Carried into the auto-seed block below, so it does not repeat the
    # destination read and the source lookup this block has already done.
    local FLIP_DST_TBLPROPERTIES="" FLIP_DST_PROPERTIES_READ=false FLIP_NOT_FOUND_SNAPSHOT_ID=""
    if [[ -n "$REVERSE_CHECKPOINT_METADATA" ]]; then
      log_info "No checkpoint found for current direction (${SRC_NAMESERVICE} -> ${DST_NAMESERVICE}), but a checkpoint for the opposite direction exists (${DST_NAMESERVICE} -> ${SRC_NAMESERVICE}): ${REVERSE_CHECKPOINT_METADATA}"
      log_info "Treating this as a direction flip (failover/failback): resolving the destination's current snapshot against the new source's metadata log..."

      local DST_FAILOVER_SNAPSHOT_ID=""
      if FLIP_DST_TBLPROPERTIES=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}"); then
        FLIP_DST_PROPERTIES_READ=true
      fi
      DST_FAILOVER_SNAPSHOT_ID=$(parse_tblproperty "$FLIP_DST_TBLPROPERTIES" current-snapshot-id)

      if [[ -n "$DST_FAILOVER_SNAPSHOT_ID" ]]; then
        local SRC_FAILOVER_METADATA_FILENAME="" FLIP_LOOKUP_RC=0
        SRC_FAILOVER_METADATA_FILENAME=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${DST_FAILOVER_SNAPSHOT_ID}") || FLIP_LOOKUP_RC=$?

        if [[ $FLIP_LOOKUP_RC -ne 0 ]]; then
          log_warn "Could not query the new source's metadata_log_entries for ${QUALIFIED_TABLE}; falling through to the auto-seed path."
        elif [[ -n "$SRC_FAILOVER_METADATA_FILENAME" ]]; then
          log_info "Direction flip confirmed: destination snapshot-id ${DST_FAILOVER_SNAPSHOT_ID} exists in the new source's metadata log."
          log_info "Anchor for the new direction: ${SRC_FAILOVER_METADATA_FILENAME}"
          local FLIP_FORWARD_NAME FLIP_REVERSE_NAME
          FLIP_FORWARD_NAME=$(checkpoint_basename_for "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")
          FLIP_REVERSE_NAME=$(checkpoint_basename_for "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE")
          if [[ "$FLIP_REVERSE_NAME" != "$FLIP_FORWARD_NAME" ]]; then
            checkpoint_retire "$HIVE_DB" "$TABLE_NAME" "$DST_NAMESERVICE" "$SRC_NAMESERVICE" || {
              log_error "Could not retire the opposite direction's checkpoint for ${QUALIFIED_TABLE}; not proceeding."
              log_error "Nothing has been replicated or written by this run -- the next run retries from the same state."
              return 1
            }
          fi
          checkpoint_write "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE" "$SRC_FAILOVER_METADATA_FILENAME" || {
            log_error "Could not write the checkpoint for the new direction for ${QUALIFIED_TABLE}; not proceeding."
            log_error "Nothing has been replicated by this run -- the next run resolves the same anchor again."
            return 1
          }
          CHECKPOINT_METADATA="$SRC_FAILOVER_METADATA_FILENAME"
          log_info "Checkpoint created for new direction (${SRC_NAMESERVICE} -> ${DST_NAMESERVICE}): ${CHECKPOINT_METADATA}"
          log_info "Table '${QUALIFIED_TABLE}' direction-flip checkpoint established - Incremental replication mode"
          BOOTSTRAP=false
        else
          FLIP_NOT_FOUND_SNAPSHOT_ID="$DST_FAILOVER_SNAPSHOT_ID"
          log_info "Destination's snapshot-id (${DST_FAILOVER_SNAPSHOT_ID}) was not found in the new source's metadata log; falling through to the auto-seed path."
        fi
      else
        log_info "Destination table has no snapshot-id (or could not be read); falling through to the auto-seed path."
      fi
    fi

    # If we didn't establish a failover checkpoint above, proceed with the
    # original no-checkpoint-found logic
    if [[ -z "$CHECKPOINT_METADATA" ]]; then
    # No checkpoint on disk. This is ambiguous by itself: it could mean (a)
    # this table has genuinely never been touched by this script and needs a
    # real bootstrap, or (b) the destination table already exists --
    # populated by some other tool/process, or by a prior manual
    # --seed-checkpoint that was never followed up -- in which case
    # re-bootstrapping would fail outright, since register_table throws
    # AlreadyExistsException against an already-registered table. Resolve
    # the ambiguity by checking whether the destination table actually
    # exists as a real Iceberg table right now, and auto-seed from its
    # current metadata_location if so -- loudly logged, which is what lets
    # an unattended scheduler run safely without a human pre-running
    # --seed-checkpoint for every new table it is handed. This deliberately
    # does not try to distinguish "seeded by another tool" from "this script
    # crashed after register_table but before writing its first checkpoint"
    # -- both cases converge on the same correct action (trust the
    # destination's current metadata_location as the anchor and proceed
    # incrementally from there), so no further disambiguation is needed.
    #
    # As with --seed-checkpoint above, the seed value MUST come from
    # SOURCE's own metadata log, never destination's: rewrite_table_path's
    # start_version validation always resolves `table` from the SOURCE
    # catalog and checks the passed filename against that table's OWN
    # metadata log. Seeding from source's CURRENT metadata_location instead
    # would be wrong whenever the destination is behind source (a true
    # prefix of source's history that has not caught up to source's current
    # state): it would make start_version == end_version on the next
    # incremental run, silently skipping every snapshot source gained before
    # the auto-seed moment.
    #
    # The correct value is destination's OWN current-snapshot-id, resolved
    # against SOURCE's metadata_log_entries metadata table (see
    # resolve_src_metadata_json_for_snapshot() above) to find exactly which
    # of source's own historical metadata.json versions the destination is
    # really caught up to. This only succeeds when the destination's data is
    # a true prefix of source's history (its snapshot-id must exist in
    # source's log) -- if the destination has independently written,
    # unrelated data instead, this correctly fails rather than silently
    # seeding a wrong value, and falls through to a real bootstrap.
    # NOTE: as with --seed-checkpoint above, a transient beeline/connectivity
    # failure and a genuine "table not found" both currently produce an
    # empty DST_AUTOSEED_METADATA_LOCATION below -- deliberately accepted;
    # see the note at --seed-checkpoint's equivalent check.
    log_substage "No checkpoint found -- check destination for auto-seed"
    local DST_TBLPROPERTIES_AUTOSEED DST_AUTOSEED_METADATA_LOCATION DST_AUTOSEED_SNAPSHOT_ID
    if [[ "$FLIP_DST_PROPERTIES_READ" == "true" ]]; then
      DST_TBLPROPERTIES_AUTOSEED="$FLIP_DST_TBLPROPERTIES"
    else
      DST_TBLPROPERTIES_AUTOSEED=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || true
    fi
    DST_AUTOSEED_METADATA_LOCATION=$(parse_tblproperty "$DST_TBLPROPERTIES_AUTOSEED" metadata_location)
    DST_AUTOSEED_SNAPSHOT_ID=$(parse_tblproperty "$DST_TBLPROPERTIES_AUTOSEED" current-snapshot-id)

    # Gate on metadata_location ALONE: a metadata_location is written at
    # CREATE TABLE time and alone proves the table exists, whereas
    # current-snapshot-id is only set after the first commit. Requiring
    # BOTH (as this used to) wrongly treated a pre-created-but-still-empty
    # destination table (schema staged ahead of the first replication run,
    # no data yet) as "no destination table" -- routing it into BOOTSTRAP
    # mode below, which is guaranteed to fail at register_table's
    # AlreadyExistsException, only after first burning a full
    # rewrite_table_path pass for nothing.
    if [[ -n "$DST_AUTOSEED_METADATA_LOCATION" ]]; then
      log_warn "No checkpoint found for '${QUALIFIED_TABLE}' in the ${SRC_NAMESERVICE} -> ${DST_NAMESERVICE} direction, but the destination table ALREADY EXISTS (metadata_location: ${DST_AUTOSEED_METADATA_LOCATION}, current-snapshot-id: ${DST_AUTOSEED_SNAPSHOT_ID:-<none yet>})."
      local SRC_AUTOSEED_METADATA_FILENAME="" AUTOSEED_FAILURE_REASON=""
      if [[ -n "$DST_AUTOSEED_SNAPSHOT_ID" ]]; then
        if [[ "$DST_AUTOSEED_SNAPSHOT_ID" == "$FLIP_NOT_FOUND_SNAPSHOT_ID" ]]; then
          # The direction-flip block above already ran this exact lookup for
          # this exact snapshot-id, and it completed with no match.
          log_info "Destination's current-snapshot-id was already looked up in SOURCE's metadata log above (no match); not repeating the query."
        else
          log_info "Resolving destination's current-snapshot-id against SOURCE's metadata log to auto-seed a checkpoint instead of re-bootstrapping (this run will be INCREMENTAL)..."
          SRC_AUTOSEED_METADATA_FILENAME=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${DST_AUTOSEED_SNAPSHOT_ID}") || {
            log_error "Could not query source's metadata_log_entries for ${QUALIFIED_TABLE}."
            return 1
          }
        fi
        AUTOSEED_FAILURE_REASON="its current-snapshot-id (${DST_AUTOSEED_SNAPSHOT_ID}) was not found in source's own metadata log"
      else
        # Table exists (has a metadata_location) but has never had a
        # snapshot committed -- e.g. pre-created with schema only. There is
        # no snapshot to resolve against source's history at all: do NOT
        # call resolve_src_metadata_json_for_snapshot with an empty
        # snapshot id -- it interpolates its argument unquoted into SQL
        # (`WHERE latest_snapshot_id = ${target_snapshot_id}`), so an empty
        # value produces a genuine Spark SQL syntax error, not a clean
        # empty result.
        log_warn "Destination table ${QUALIFIED_TABLE} exists but has no current-snapshot-id yet (no committed data)."
        AUTOSEED_FAILURE_REASON="it has no committed snapshot yet, so there is nothing to resolve against source's history"
      fi
      # SAME TABLE, STILL EMPTY. A destination with no snapshot holds no data,
      # so there is nothing a repoint could drop. If it is also the SAME
      # table as source (matching table uuid) -- e.g. an empty table this
      # script registered on an earlier run that never got as far as writing
      # its checkpoint -- the run proceeds as a full rewrite followed by the
      # normal repoint. A different (or unreported) uuid means the
      # destination is some other table that merely shares the name, and is
      # left to the explicit --rebuild-dst-table-from-source handling below.
      # Requires the destination to report snapshot-count 0 where it reports
      # one at all. Normal path only: the SAME-NAMESERVICE COLLISION path
      # keeps its existing behaviour for this case.
      local EMPTY_DST_SAME_TABLE=false
      if [[ -z "$DST_AUTOSEED_SNAPSHOT_ID" && "$SAME_NAMESERVICE_COLLISION" != "true" ]]; then
        local SRC_UUID_STEP1 DST_AUTOSEED_UUID DST_AUTOSEED_SNAPSHOT_COUNT
        SRC_UUID_STEP1=$(parse_tblproperty "$SRC_TBLPROPERTIES" uuid)
        DST_AUTOSEED_UUID=$(parse_tblproperty "$DST_TBLPROPERTIES_AUTOSEED" uuid)
        DST_AUTOSEED_SNAPSHOT_COUNT=$(parse_tblproperty "$DST_TBLPROPERTIES_AUTOSEED" snapshot-count)
        if [[ -n "$SRC_UUID_STEP1" && "$SRC_UUID_STEP1" == "$DST_AUTOSEED_UUID" ]] \
           && [[ -z "$DST_AUTOSEED_SNAPSHOT_COUNT" || "$DST_AUTOSEED_SNAPSHOT_COUNT" == "0" ]]; then
          EMPTY_DST_SAME_TABLE=true
        fi
      fi
      if [[ "$EMPTY_DST_SAME_TABLE" == "true" ]]; then
        log_info "Destination table ${QUALIFIED_TABLE} is the same table as source (table uuid ${DST_AUTOSEED_UUID}) and holds no data."
        log_info "Proceeding with a FULL rewrite and a normal repoint; there is no destination data to supersede."
        repair_unfinished_registration "$DST_TBLPROPERTIES_AUTOSEED" || return 1
        BOOTSTRAP=false
        EMPTY_DST_FULL_REWRITE=true
      elif [[ -z "$SRC_AUTOSEED_METADATA_FILENAME" ]]; then
        # NOTE: BOOTSTRAP is NOT set to true here. The destination table was
        # just confirmed to exist (DST_AUTOSEED_METADATA_LOCATION/
        # DST_AUTOSEED_SNAPSHOT_ID above), and register_table always throws
        # AlreadyExistsException against an already-registered table -- so a
        # bootstrap attempt here is guaranteed to fail, only after first
        # burning a full rewrite_table_path + Spark copy pass for nothing. Fail
        # fast instead, with the actionable remediation spelled out --
        # unless --rebuild-dst-table-from-source was passed (see below).
        if [[ "$REBUILD_DST_TABLE_FROM_SOURCE" == "true" ]]; then
          # Explicit opt-in: the operator has confirmed destination's
          # existing data/lineage should be superseded by source's current
          # state. There is no valid start_version for an incremental
          # rewrite (destination's data isn't anywhere in source's log),
          # so this forces a FULL rewrite_table_path (all of source's
          # currently-reachable files). The destination catalog cannot be
          # simply re-pointed via ALTER TABLE ... SET TBLPROPERTIES either:
          # Hive's Iceberg storage handler unconditionally rejects a
          # metadata_location change whose table-uuid differs from the
          # destination's current one (see the detailed explanation at
          # step 6/8, where this is handled). The existing destination
          # table is therefore RENAMED (as a backup -- see step 6/8) and
          # the freed name is re-registered fresh against source's
          # replicated metadata -- nothing is dropped or purged; the old
          # table remains fully live/queryable under its backup name.
          log_warn "--rebuild-dst-table-from-source set: destination table ${QUALIFIED_TABLE} already exists, but ${AUTOSEED_FAILURE_REASON} -- destination's data does NOT (yet) trace back to a verifiable point in source's history."
          log_warn "Proceeding anyway: this run will FULLY REWRITE the table's metadata from source's current state, then RENAME the existing destination table (as a backup) and RE-REGISTER the freed name against it -- Hive disallows a plain metadata_location repoint across different table lineages."
          log_warn "Destination's prior data/history is NOT deleted: it remains a normal, fully-queryable Iceberg table under its backup name (see step 6/8 log for the exact name), to be dropped by hand later once no longer needed."
          BOOTSTRAP=false
          FORCE_FULL_REWRITE=true
        else
          log_error "Destination table ${QUALIFIED_TABLE} already exists, but ${AUTOSEED_FAILURE_REASON} -- destination's data does NOT (yet) trace back to a verifiable point in source's history."
          log_error "Auto-seed cannot safely proceed, and a bootstrap is not possible either (the destination table already exists, so register_table would fail with AlreadyExistsException)."
          log_error "Drop and recreate the destination table yourself to force a real bootstrap, or re-run with --rebuild-dst-table-from-source to have this script back it up (rename, no data loss) and re-register the freed name, superseding it with source's current state automatically, or investigate why its history is unverifiable against source."
          return 1
        fi
      else
        log_info "Resolved: ${SRC_AUTOSEED_METADATA_FILENAME} -- this is what SOURCE's own current metadata.json was at the exact point destination's current-snapshot-id was introduced. The next incremental run replicates everything source has gained since THAT point, so no writes are skipped."
        log_warn "If that destination data is NOT actually equivalent to this table's source history, this auto-seeded checkpoint is WRONG for it -- drop and recreate the destination table, then re-run, to force a real bootstrap instead."
        repair_unfinished_registration "$DST_TBLPROPERTIES_AUTOSEED" || return 1
        checkpoint_write "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE" "$SRC_AUTOSEED_METADATA_FILENAME" || return 1
        CHECKPOINT_METADATA="$SRC_AUTOSEED_METADATA_FILENAME"
        BOOTSTRAP=false
      fi
    else
      log_info "No checkpoint found for '${QUALIFIED_TABLE}' in the ${SRC_NAMESERVICE} -> ${DST_NAMESERVICE} direction, and no existing destination table detected - Bootstrap mode"
      BOOTSTRAP=true
    fi
    fi  # End of: if [[ -z "$CHECKPOINT_METADATA" ]]; then (failover check)
  fi
  log_line ""

  ########################################
  # SKIP_REPLICATION: true only for a genuine incremental run (never
  # bootstrap, never --rebuild-dst-table-from-source) whose source has not
  # advanced AT ALL past the checkpoint -- CHECKPOINT_METADATA (this
  # table's last-replicated SOURCE metadata.json, from STEP 3) is
  # byte-for-byte identical to SRC_METADATA_LOCATION (source's CURRENT
  # metadata_location, already read for free back in STEP 1). Iceberg never
  # reuses a metadata.json filename across commits, so this identity check
  # is a sufficient, exact proof that zero commits happened on source since
  # the last successful run -- not a heuristic.
  #
  # WHY THIS EXISTS: rewrite_table_path does NOT return an empty file list
  # just because start_version already equals the table's current version
  # -- it still re-emits the boundary version's own metadata files (a
  # behaviour of Iceberg 1.9.x's RewriteTablePathSparkAction, not a bug in
  # this script). Left unchecked, every truly no-op incremental run still
  # paid for a full rewrite_table_path JVM launch, a real distcp MapReduce
  # job, AND a destination ALTER TABLE repoint that changed nothing -- on
  # this table, STEP 5 alone (distcp) ate ~60% of a ~2m25s run that copied
  # zero net data.
  #
  # That destination ALTER TABLE was not merely wasted time either: Hive's
  # Iceberg storage handler commits a BRAND NEW metadata.json of its own on
  # every SET TBLPROPERTIES('metadata_location'=...) call, even when the
  # value being set is unchanged. Confirmed on this cluster via `hdfs dfs
  # -ls .../employees/metadata/`: two consecutive no-op incremental runs
  # each left behind a distinct, permanently-orphaned metadata.json (never
  # referenced by anything, never cleaned up by anything). Skipping STEPs
  # 4-6 entirely when nothing changed avoids both costs -- the wasted
  # compute AND the destination-side metadata growth -- at once.
  #
  # Checked HERE, immediately after the checkpoint is resolved and before
  # STEP 4's own banner -- not partway through STEP 4 after already paying
  # for the rewrite_table_path launch. STEP 7 (validation) still always
  # runs afterward regardless of this flag: it reads the destination
  # afresh and compares snapshot-ids (see STEP7_NOOP_VERIFIED), so a
  # short-circuited run is still verified, not just assumed correct.
  ########################################
  local SKIP_REPLICATION=false
  if [[ "$BOOTSTRAP" != "true" && "$FORCE_FULL_REWRITE" != "true" \
        && -n "$CHECKPOINT_METADATA" \
        && "$CHECKPOINT_METADATA" == "$SRC_METADATA_LOCATION" ]]; then
    SKIP_REPLICATION=true
  fi

  # QUIET_SKIP_LOG (see its own declaration near the top of this script):
  # once this table is a confirmed no-op, redirect fd1 (this function's own
  # [INFO]/[WARN] output -- log_error is unaffected, it always writes to
  # fd2) to /dev/null for the remainder of this function. STEP 8's banner
  # restores fd1 right before printing, so every table -- quiet or not --
  # still ends on exactly one visible summary line. Saved onto fd9, an fd
  # number nothing else in this script uses, and restored via `exec 1>&9
  # 9>&-` so the save/restore pair never leaks a stray descriptor once this
  # table's subshell exits.
  # This run is going to replicate: take the cross-host lock first (see
  # hdfs_table_lock_acquire). A no-op run changes nothing and skips it.
  if [[ "$SKIP_REPLICATION" != "true" ]]; then
    hdfs_table_lock_acquire "$HIVE_DB" "$TABLE_NAME" || return 3
  fi

  local _QUIET_SKIP_ACTIVE=false
  if [[ "$SKIP_REPLICATION" == "true" ]]; then
    case "${QUIET_SKIP_LOG,,}" in
      true|yes|1)
        exec 9>&1 1>/dev/null
        _QUIET_SKIP_ACTIVE=true
        ;;
    esac
  fi

  # _restore_quiet_skip_fd: undo the fd1 redirect above. Idempotent (safe to
  # call more than once, and safe to call when the redirect was never
  # installed) via the _QUIET_SKIP_ACTIVE guard, which is also cleared here
  # so a second call is a no-op rather than a second `exec 1>&9 9>&-`
  # against an already-closed fd9.
  #
  # WHY THIS EXISTS. STEP 7 (validation) always runs even when STEPs 4-6
  # were skipped as a confirmed no-op, and every one of STEP 7's OWN
  # failure paths used to `return 1` while fd1 was still pointed at
  # /dev/null -- silently losing not just STEP 7's own [INFO] diagnostics
  # for a table that is actually FAILING at this point (not skipped), but
  # also print_table_timing_summary's entire stage breakdown, since that
  # runs from an EXIT trap in the CALLER (replicate_one_table's subshell)
  # and inherits whatever fd1 happens to be pointed at the moment this
  # function returns -- not whatever it was when the trap was installed.
  # Only log_error (always fd2) survived those paths; every other line
  # vanished for a table whose true outcome was FAILED, not skipped.
  # Call this immediately before any `return` in STEP 7 that signals a
  # real failure; the STEP 8 success banner further below still does its
  # own unconditional restore for the normal (success) path.
  _restore_quiet_skip_fd() {
    if [[ "$_QUIET_SKIP_ACTIVE" == "true" ]]; then
      exec 1>&9 9>&-
      _QUIET_SKIP_ACTIVE=false
    fi
  }

  # REWRITE_FULL_FALLBACK / REWRITE_REANCHORED: declared HERE, unconditionally,
  # before the if/elif/else below picks normal vs. SAME-NAMESERVICE COLLISION
  # -- NOT inside either branch -- because BOTH branches' own broken-
  # incremental-chain auto-recovery (see "CHAINED CROSS-CLUSTER REWRITES" in
  # this script's header) sets them, and STEP 8's mode-label summary far
  # below reads them regardless of which branch actually ran. A `local`
  # declaration only takes effect on the line that executes it; since only
  # ONE of the if/elif/else branches ever runs per call, a declaration
  # sitting inside just one of them (as an earlier version of this code had,
  # inside the normal path's own branch) would leave these two names
  # undeclared -- and therefore accidental bare globals -- for every
  # collision-mode run.
  #
  # REWRITE_FULL_FALLBACK: set only when recovery falls all the way back to
  # a full rewrite (no start_version). Deliberately distinct from
  # FORCE_FULL_REWRITE: that flag also changes STEP 6/8's behavior (rename +
  # re-register, because destination's table-uuid genuinely differs from
  # source's). Here the table-uuid has NOT changed -- this is the same
  # table, just missing one ancestor in its metadata-log audit trail -- so
  # STEP 6 must still take the normal ALTER TABLE repoint path. Only this
  # variable's use in each branch's own recovery logic is affected; STEP
  # 6/8 stay keyed on FORCE_FULL_REWRITE alone and correctly ignore this
  # flag.
  local REWRITE_FULL_FALLBACK=false
  # REWRITE_REANCHORED: set only when recovery manages to route around the
  # broken ancestor with a NEW incremental start_version (rather than
  # falling all the way back to a full rewrite). Same table-uuid-unchanged
  # reasoning as REWRITE_FULL_FALLBACK applies; exists purely so STEP 8's
  # summary line can say what actually happened.
  local REWRITE_REANCHORED=false
  # REPLICATED_SRC_METADATA_NAME: the bare filename of the SOURCE metadata.json
  # this run's rewrite_table_path used as its end version -- the procedure's
  # own `latest_version` result. Empty when no rewrite ran (a no-op run) or
  # on a path that does not set it. STEP 7 uses it to checkpoint the version
  # that was replicated rather than whatever source has moved on to by then,
  # and only after matching it against a metadata_location basename read
  # from source itself, so nothing rests on an assumption about how the
  # procedure names its output. Declared here, ahead of the branches below,
  # for the same reason as the two flags above.
  local REPLICATED_SRC_METADATA_NAME=""

  # NOTE ON INDENTATION: the STEP 4/5/6 body inside the `else` below
  # deliberately keeps its ORIGINAL indentation rather than being shifted
  # one level deeper. This is a large, carefully-verified block; reindenting
  # all of it in the same change that adds new control flow would make the
  # diff far harder to review for exactly the kind of one-character mistake
  # (a misplaced brace or quote) that is easy to introduce and easy to miss
  # across ~480 lines. The `if`/`else`/`fi` added here are the only new
  # control flow -- everything between them is byte-for-byte the pre-existing
  # STEP 4/5/6 code.
  if [[ "$SKIP_REPLICATION" == "true" ]]; then
    log_stage 4 "Staging path-corrected metadata (rewrite_table_path)..."
    log_info "SKIPPED -- source has not advanced past the checkpoint (still ${SRC_METADATA_LOCATION##*/})."

    log_stage 5 "Copying the exact files listed by rewrite_table_path..."
    log_info "SKIPPED -- nothing to copy."

    log_stage 6 "Refreshing destination catalog to latest metadata_location..."
    log_info "SKIPPED -- destination is already pointed at the correct metadata_location. Re-running this"
    log_info "ALTER TABLE anyway would accomplish nothing except triggering Hive's Iceberg storage handler to"
    log_info "commit yet another throwaway metadata.json on the destination (see SKIP_REPLICATION note above)."
    log_line ""
  elif [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
    ########################################
    # [4-6/8, SAME-NAMESERVICE COLLISION PATH] See "SAME-NAMESERVICE
    # COLLISION" in this script's header for the full
    # mechanism. Short version: SRC_NAMESERVICE == DST_NAMESERVICE means no
    # single spark-sql job can both (a) physically read source (whose
    # embedded paths say "hdfs://<shared-name>") and (b) leave the
    # destination copy reading that SAME plain name for its own HA safety.
    # Done as two passes instead:
    #   Hop A: redirect the shared name to SOURCE for this one job, rewrite
    #     to the destination's resolved active-NameNode host:port (a literal
    #     address standing in for DESTINATION), copy cross-cluster.
    #   Hop B: a purely LOCAL, same-cluster rewrite, that host:port -> the
    #     shared name -- needs the content resolvable via a CATALOG
    #     identifier (rewrite_table_path has no "raw metadata file" form),
    #     so hop A's output is temp-registered first, into a throwaway
    #     Hadoop-filesystem-backed catalog (NOT the Hive Metastore: see the
    #     temp-register comment further below). That throwaway catalog entry
    #     is retired by a plain recursive HDFS delete (no Hive table ever
    #     existed for it, so there is no purge flag to get wrong) once hop
    #     B's real output is captured.
    #
    # Hop A has the same broken-incremental-chain recovery as the normal
    # path's STEP 4 ("CHAINED CROSS-CLUSTER REWRITES" in the header): a
    # re-anchor at the destination's current snapshot, then a full rewrite.
    # The Puffin statistics-file mis-staging workaround is applied to both
    # hops' copy steps (fix_puffin_stats_and_build_copy_list()), same as the
    # normal path's [5b]/[5c].
    #
    # --rebuild-dst-table-from-source (FORCE_FULL_REWRITE) IS supported on
    # this path: hop A runs a FULL rewrite (same as bootstrap -- there is no
    # valid start_version, since destination's data isn't anywhere in
    # source's metadata log), hop B's own rewrite follows suit (it already
    # falls back to a full walk whenever hop A has no start_version to
    # match), and the final register/repoint step below renames the
    # existing, unrelated destination table out of the way (backup, no data
    # loss) and register_table's the freed name fresh -- identical in spirit
    # to the normal (non-collision) path's own FORCE_FULL_REWRITE handling.
    ########################################
    log_stage 4 "Staging path-corrected metadata (rewrite_table_path) -- SAME-NAMESERVICE COLLISION path"
    log_info "Table: ${QUALIFIED_TABLE}"

    # Save the GLOBAL HA arrays (used everywhere else in this script:
    # checkpoint I/O, STEP 1's DESCRIBE FORMATTED, etc.) and restore them
    # before this branch returns via ANY exit path -- hop A/B each install
    # their OWN, ISOLATED override in their place for the duration of their
    # one spark-sql/copier call, exactly as "CHECKPOINT ON HDFS"'s sibling
    # note on isolation describes for STEP 4's normal-path override.
    local _SAVED_HA_CONF_ARGS=("${HA_CONF_ARGS[@]}")
    local _SAVED_HDFS_HA_ARGS=("${HDFS_HA_ARGS[@]}")
    _collision_restore_ha_args() {
      HA_CONF_ARGS=("${_SAVED_HA_CONF_ARGS[@]}")
      HDFS_HA_ARGS=("${_SAVED_HDFS_HA_ARGS[@]}")
    }

    ########################################
    # HOPAB_COMPLETED_MARKER: read HERE, while HA_CONF_ARGS/HDFS_HA_ARGS
    # are still the NATIVE (un-overridden) args saved just above -- under
    # those, the shared name "${DST_NAMESERVICE}" correctly resolves to
    # DESTINATION via this node's own unmodified hdfs-site.xml, same as
    # every other checkpoint-style path this script reads/writes. Reading
    # it AFTER installing hop A's own override below would be wrong: that
    # override redirects the exact same "${DST_NAMESERVICE}" string to
    # SOURCE's real NameNodes for the duration of hop A's one spark-sql
    # call, so a `hadoop fs` command issued under it would resolve this
    # path to the wrong physical cluster entirely. See its own fuller
    # comment further below (at the Hop A mode decision) for what this
    # marker is FOR and the real incident it fixes.
    ########################################
    local HOPAB_COMPLETED_MARKER_PATH
    HOPAB_COMPLETED_MARKER_PATH="hdfs://${DST_NAMESERVICE}${CHECKPOINT_DIR}/$(checkpoint_basename_for "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE").collision_hopab_completed"
    local HOPAB_COMPLETED
    HOPAB_COMPLETED=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${HOPAB_COMPLETED_MARKER_PATH}" 2>/dev/null) || HOPAB_COMPLETED=""

    ########################################
    # HOP A -- cross-cluster fetch. source_prefix stays the plain shared
    # name (must match what is literally embedded in source's metadata);
    # target_prefix is the resolved bare active-NameNode host:port.
    # staging_location and the copier's own target column are BOTH
    # explicitly qualified with that host:port -- never scheme-less here,
    # since scheme-less resolution follows fs.defaultFS, which this job's
    # own override has redirected to SOURCE.
    ########################################
    log_substage "Hop A: rewrite table metadata from source"
    HA_CONF_ARGS=()
    HDFS_HA_ARGS=()
    build_collision_hop_a_ha_args || {
      log_error "Could not build hop A's HA/staging args for ${QUALIFIED_TABLE} (destination active"
      log_error "NameNode could not be resolved)."
      _collision_restore_ha_args
      return 1
    }

    # PREVENTION, not just diagnosis: refuse up front if source's OWN
    # current metadata.json already has a leftover collision-scratch
    # authority baked into it -- see assert_no_collision_scratch_leak()'s
    # own comment for the full incident this guards against. Checked here,
    # under hop A's override (so the plain-named path physically resolves
    # to SOURCE, as it is meant to for hop A), and BEFORE any Spark job is
    # launched -- a bad table fails in one cheap `hadoop fs -cat` instead
    # of a confusing stack trace 20-30 seconds into a rewrite_table_path
    # call.
    assert_no_collision_scratch_leak "${SRC_METADATA_LOCATION}" "source's current metadata.json" "${QUALIFIED_TABLE}" || {
      _collision_restore_ha_args
      return 1
    }

    local HOPA_ACTIVE_NN
    HOPA_ACTIVE_NN=$(resolve_active_namenode_hostport "$DST_NN_HOSTS") || {
      log_error "Could not resolve destination's active NameNode for hop A's target_prefix/staging_location"
      log_error "for ${QUALIFIED_TABLE}."
      _collision_restore_ha_args
      return 1
    }
    local HOPA_STAGING_LOCATION="hdfs://${HOPA_ACTIVE_NN}${STAGING_DIR}-hopA"
    local HOPA_TARGET_PREFIX="hdfs://${HOPA_ACTIVE_NN}"

    ########################################
    # HOPAB_COMPLETED_MARKER: has a FULL collision-mode hop A/B pair ever
    # completed for THIS table in THIS direction before? Real incident:
    # iceberg_dr_test208.orders208, first-ever run of a NEW direction
    # (auto-seeded checkpoint, e.g. '00008-....metadata.json') --
    # confirmed via `hdfs dfs -ls` that this checkpoint boundary file
    # exists on SOURCE but was NEVER staged to DESTINATION under any name.
    # Hop A's own incremental rewrite validates start_version against
    # SOURCE's metadata log (always resolvable there, so Hop A itself never
    # errors), but Hop A's incremental mode only stages the DELTA AFTER
    # start_version -- by design it never stages start_version itself, on
    # the assumption a PRIOR run's hop A/B already staged it. That
    # assumption is false on a direction's first-ever run: nothing has ever
    # staged ANY ancestor -- not the checkpoint boundary, not anything
    # older -- to destination under the resolved bare-host authority. Hop B
    # then fails immediately trying to open that never-staged boundary file:
    #   IllegalArgumentException: Version file hdfs://<host>:<port>/.../
    #   <checkpoint-boundary>.metadata.json does not exist.
    # This is the same "CHAINED CROSS-CLUSTER REWRITES" class of bug the
    # normal (non-collision) path already has re-anchor/full-rewrite
    # recovery for -- and exactly the gap this script's own header already
    # flagged for the collision path ("no broken-chain auto-recovery on
    # this path"). A full Hop B walk cannot dodge it either (older
    # ancestors below the checkpoint were never staged AT ALL, not even in
    # binary form -- there is nothing to patch or re-walk into on
    # destination for them).
    #
    # Fix: force a FULL Hop A rewrite -- staging EVERY reachable ancestor
    # to destination under the resolved bare-host authority, exactly like a real bootstrap --
    # on the first collision-mode run of any table+direction pair,
    # regardless of whether a (possibly auto-seeded) checkpoint already
    # exists. Tracked by a small marker file, mirrored the same way the
    # replication checkpoint is (write_checkpoint_hdfs_one), keyed by
    # direction (checkpoint_basename_for already embeds src/dst
    # nameservice+table) so a table replicated in BOTH directions tracks
    # each direction's own completion independently. Written once Hop B
    # succeeds below -- see its own comment at that point. Every run AFTER
    # the first, in the SAME direction, finds the marker and proceeds
    # incrementally as before (cost stays bounded to that run's delta).
    ########################################
    local HOPA_REWRITE_SQL
    if [[ "$BOOTSTRAP" == "true" || "$FORCE_FULL_REWRITE" == "true" || -z "$HOPAB_COMPLETED" ]]; then
      HOPA_REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${HOPA_TARGET_PREFIX}',
    staging_location => '${HOPA_STAGING_LOCATION}'
  );"
      if [[ "$BOOTSTRAP" == "true" ]]; then
        log_info "[Hop A] Mode: full rewrite (bootstrap)"
      elif [[ "$FORCE_FULL_REWRITE" == "true" ]]; then
        log_info "[Hop A] Mode: full rewrite (--rebuild-dst-table-from-source -- destination's data isn't"
        log_info "[Hop A] anywhere in source's metadata log, so there is no valid start_version)"
      else
        log_warn "[Hop A] No prior completed collision-mode run found for this table+direction -- forcing a"
        log_warn "[Hop A] FULL rewrite (not incremental, even though a checkpoint exists) so every ancestor is"
        log_warn "[Hop A] staged to destination at least once. See HOPAB_COMPLETED_MARKER_PATH's own comment above."
        log_info "[Hop A] Mode: full rewrite (first collision-mode run for this direction)"
      fi
    else
      local HOPA_START_VERSION="${CHECKPOINT_METADATA##*/}"
      HOPA_REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${HOPA_TARGET_PREFIX}',
    staging_location => '${HOPA_STAGING_LOCATION}',
    start_version => '${HOPA_START_VERSION}'
  );"
      log_info "[Hop A] Mode: incremental rewrite (start_version = ${HOPA_START_VERSION})"
    fi
    log_info "[Hop A] Executing: ${HOPA_REWRITE_SQL}"
    log_line ""

    # BROKEN INCREMENTAL CHAIN AUTO-RECOVERY -- same mechanism and same real
    # incident this responds to as the normal (non-collision) path's own
    # copy of this block (see "CHAINED CROSS-CLUSTER REWRITES" in this
    # script's header); hop A runs its own rewrite_table_path against
    # SOURCE, so it hits the exact same broken-ancestor signature under
    # exactly the same failover/failback circumstances. Ported here rather
    # than shared via one function because hop A's SQL differs from the
    # normal path's in every prefix (SRC_PREFIX/HOPA_TARGET_PREFIX/
    # HOPA_STAGING_LOCATION, not SRC_PREFIX/DST_PREFIX/STAGING_DIR) and it
    # must set REWRITE_REANCHORED/REWRITE_FULL_FALLBACK -- the SAME two
    # function-scoped locals STEP 8's mode-label summary already reads,
    # declared once near the top of _replicate_one_table_locked and equally
    # in scope for this elif branch.
    local HOPA_STDERR_FILE
    HOPA_STDERR_FILE=$(mktemp) || {
      log_error "[Hop A] Could not create a temp file to capture rewrite_table_path's stderr for ${QUALIFIED_TABLE}."
      _collision_restore_ha_args
      return 1
    }
    local HOPA_OUTPUT
    HOPA_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${HOPA_REWRITE_SQL}" "${HOPA_STDERR_FILE}")
    local HOPA_RC=$?

    # Detected BEFORE replaying the raw stderr below -- see the identical
    # comment on the normal (non-collision) path's own copy of this check
    # for why (a lead-in explanation before the raw Java stack trace, not
    # after, so an operator scanning the log isn't misled into reading this
    # as an unhandled crash).
    local HOPA_BROKEN_CHAIN_PATTERN="IllegalArgumentException: Version file .*\.metadata\.json doesn'?t exist"
    local HOPA_IS_KNOWN_RECOVERABLE=false
    if [[ $HOPA_RC -ne 0 && "$BOOTSTRAP" != "true" && "$FORCE_FULL_REWRITE" != "true" ]] \
       && { grep -qE "${HOPA_BROKEN_CHAIN_PATTERN}" <<<"${HOPA_OUTPUT}" \
            || grep -qE "${HOPA_BROKEN_CHAIN_PATTERN}" "${HOPA_STDERR_FILE}"; }; then
      HOPA_IS_KNOWN_RECOVERABLE=true
      if _spark_stderr_is_live; then
        log_warn "[Hop A] The incremental rewrite_table_path attempt above failed with a known, auto-recoverable"
        log_warn "[Hop A] condition (a 'Version file ... doesn't exist' exception) -- not a real failure. Auto-recovery"
        log_warn "[Hop A] follows; see 'CHAINED CROSS-CLUSTER REWRITES' in this script's header for the full mechanism."
      else
        log_warn "[Hop A] The first incremental rewrite_table_path attempt below is EXPECTED to fail with"
        log_warn "[Hop A] a 'Version file ... doesn't exist' exception -- this is a known, auto-recoverable"
        log_warn "[Hop A] condition, not a real failure. Auto-recovery follows the raw output below; see"
        log_warn "[Hop A] 'CHAINED CROSS-CLUSTER REWRITES' in this script's header for the full mechanism."
        log_line ""
        log_line "----- BEGIN raw rewrite_table_path output (expected failure, auto-recovering) -----"
      fi
    fi

    # For known-recoverable failures, show only the error message (not the full Java stack trace)
    if [[ "$HOPA_IS_KNOWN_RECOVERABLE" == "true" ]]; then
      # Extract just the error message lines (not the 200+ line stack trace)
      replay_spark_stderr "${HOPA_STDERR_FILE}" errors-only
    else
      # For unknown errors, show everything for debugging
      replay_spark_stderr "${HOPA_STDERR_FILE}"
    fi

    if [[ "$HOPA_IS_KNOWN_RECOVERABLE" == "true" ]] && ! _spark_stderr_is_live; then
      log_line "----- END raw rewrite_table_path output -----"
      log_line ""
    fi

    if [[ $HOPA_RC -ne 0 ]]; then
      if [[ "$HOPA_IS_KNOWN_RECOVERABLE" == "true" ]]; then
        log_warn "[Hop A] rewrite_table_path's incremental walk hit an ancestor version file that does not"
        log_warn "[Hop A] exist on SOURCE, even though the checkpoint anchor itself is source's own valid"
        log_warn "[Hop A] file -- signature of a metadata-log entry planted by an earlier cross-cluster hop"
        log_warn "[Hop A] in the other direction. See 'CHAINED CROSS-CLUSTER REWRITES' in this script's header."
        log_line ""

        local HOPA_REANCHOR_SNAPSHOT_ID="" HOPA_REANCHOR_VERSION_PATH="" HOPA_REANCHOR_VERSION=""
        local HOPA_DST_REANCHOR_PROPERTIES
        HOPA_DST_REANCHOR_PROPERTIES=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || true
        HOPA_REANCHOR_SNAPSHOT_ID=$(parse_tblproperty "$HOPA_DST_REANCHOR_PROPERTIES" current-snapshot-id)
        if [[ -n "$HOPA_REANCHOR_SNAPSHOT_ID" ]]; then
          log_info "[Hop A] Attempting to re-anchor past the broken ancestor: resolving destination's own"
          log_info "[Hop A] current-snapshot-id (${HOPA_REANCHOR_SNAPSHOT_ID}) against SOURCE's metadata_log_entries..."
          # resolve_src_metadata_json_for_snapshot() is already
          # collision-aware (see its own comment): it saves/installs/
          # restores its OWN nested copy of hop A's override around this one
          # query, safe to call while hop A's override is already active.
          HOPA_REANCHOR_VERSION_PATH=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${HOPA_REANCHOR_SNAPSHOT_ID}") || HOPA_REANCHOR_VERSION_PATH=""
          HOPA_REANCHOR_VERSION="${HOPA_REANCHOR_VERSION_PATH##*/}"
        fi

        if [[ -n "$HOPA_REANCHOR_VERSION" && "$HOPA_REANCHOR_VERSION" != "$HOPA_START_VERSION" ]]; then
          log_info "[Hop A] Resolved: ${HOPA_REANCHOR_VERSION} -- retrying as an incremental rewrite anchored"
          log_info "[Hop A] there instead of at the broken checkpoint."
          log_line ""
          HOPA_REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${HOPA_TARGET_PREFIX}',
    staging_location => '${HOPA_STAGING_LOCATION}',
    start_version => '${HOPA_REANCHOR_VERSION}'
  );"
          log_info "[Hop A] Executing: ${HOPA_REWRITE_SQL}"
          log_line ""
          : > "${HOPA_STDERR_FILE}"
          HOPA_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${HOPA_REWRITE_SQL}" "${HOPA_STDERR_FILE}")
          HOPA_RC=$?
          replay_spark_stderr "${HOPA_STDERR_FILE}"
          if [[ $HOPA_RC -eq 0 ]]; then
            REWRITE_REANCHORED=true
          else
            log_warn "[Hop A] Re-anchored retry also failed. Falling back to a FULL rewrite as a last resort."
            log_line ""
          fi
        else
          if [[ -z "$HOPA_REANCHOR_SNAPSHOT_ID" ]]; then
            log_warn "[Hop A] Destination has no current-snapshot-id yet; cannot re-anchor past the broken ancestor."
          elif [[ -z "$HOPA_REANCHOR_VERSION" ]]; then
            log_warn "[Hop A] Destination's current-snapshot-id was not found in source's own metadata log;"
            log_warn "[Hop A] cannot re-anchor past the broken ancestor."
          else
            log_warn "[Hop A] Re-anchoring resolved to the SAME start_version that just failed; cannot make"
            log_warn "[Hop A] progress this way."
          fi
          log_warn "[Hop A] Falling back to a FULL rewrite (no start_version) instead."
          log_line ""
        fi

        if [[ $HOPA_RC -ne 0 ]]; then
          REWRITE_FULL_FALLBACK=true
          HOPA_REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${HOPA_TARGET_PREFIX}',
    staging_location => '${HOPA_STAGING_LOCATION}'
  );"
          log_info "[Hop A] Mode: full rewrite (auto-recovered from a broken incremental metadata-log chain)"
          log_info "[Hop A] Executing: ${HOPA_REWRITE_SQL}"
          log_line ""
          : > "${HOPA_STDERR_FILE}"
          HOPA_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${HOPA_REWRITE_SQL}" "${HOPA_STDERR_FILE}")
          HOPA_RC=$?
          replay_spark_stderr "${HOPA_STDERR_FILE}"
          if [[ $HOPA_RC -ne 0 ]]; then
            log_error "[Hop A] rewrite_table_path (re-anchor and full-rewrite fallbacks both) failed for ${QUALIFIED_TABLE}."
            rm -f "${HOPA_STDERR_FILE}"
            _collision_restore_ha_args
            return 1
          fi
        fi
      else
        log_error "[Hop A] rewrite_table_path failed for ${QUALIFIED_TABLE}."
        rm -f "${HOPA_STDERR_FILE}"
        _collision_restore_ha_args
        return 1
      fi
    fi
    rm -f "${HOPA_STDERR_FILE}"
    printf '%s\n' "${HOPA_OUTPUT}" | indent_output

    local HOPA_RESULT_ROW HOPA_METADATA_NAME HOPA_FILE_LIST
    HOPA_RESULT_ROW=$(echo "${HOPA_OUTPUT}" | grep -E '\.metadata\.json' | tail -n 1 || true)
    HOPA_METADATA_NAME=$(echo "${HOPA_RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /\.metadata\.json$/){print $i; exit}}}' | tr -d '[:space:]')
    HOPA_FILE_LIST=$(echo "${HOPA_RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /file-list|\.csv$/){print $i; exit}}}' | tr -d '[:space:]')
    [[ -z "$HOPA_FILE_LIST" ]] && HOPA_FILE_LIST="${HOPA_STAGING_LOCATION%/}/file-list"
    if [[ -z "$HOPA_METADATA_NAME" ]]; then
      log_error "[Hop A] Could not determine rewritten metadata.json name for ${QUALIFIED_TABLE}."
      _collision_restore_ha_args
      return 1
    fi
    log_info "[Hop A] Rewritten metadata_location: ${HOPA_TARGET_PREFIX}${TABLE_RELATIVE_PATH}/metadata/${HOPA_METADATA_NAME}"

    local HOPA_LOCAL_FILE_LIST
    HOPA_LOCAL_FILE_LIST="${LOG_DIR}/${HIVE_DB}.${TABLE_NAME}.hopA-file-list.$(date +%Y%m%d_%H%M%S).csv"
    read_rewrite_file_list "${HOPA_FILE_LIST}" "${HOPA_LOCAL_FILE_LIST}" || {
      log_error "[Hop A] Could not read file list at ${HOPA_FILE_LIST} for ${QUALIFIED_TABLE}."
      _collision_restore_ha_args
      return 1
    }
    local HOPA_ROWS
    HOPA_ROWS=$(awk 'END{print NR}' "${HOPA_LOCAL_FILE_LIST}" | tr -d '[:space:]')
    log_substage "Hop A: copy staged files to destination"
    log_info "[Hop A] Files to copy: ${HOPA_ROWS}"
    local _HOPA_COPY_START
    _HOPA_COPY_START=$(date +%s)
    # Hop-scoped copy stats, captured right after this hop's own
    # run_copy_engine call so hop B's later call (which reuses the SAME
    # FILES_COPIED/FILES_SKIPPED/FILES_FAILED locals -- see [Hop A]/[Hop B]'s
    # shared run_copy_engine signature) cannot silently overwrite hop A's
    # numbers before STEP 8 reads them. See the STEP 8 summary fix's own
    # comment (near "Combined copy time" below) for why both hops' numbers
    # are summed rather than only the last hop's being reported.
    local _HOPA_FILES_TO_COPY=0 _HOPA_FILES_COPIED=0 _HOPA_FILES_SKIPPED=0 _HOPA_FILES_FAILED=0
    if [[ "$HOPA_ROWS" -gt 0 ]]; then
      # Same KNOWN UPSTREAM ICEBERG BUG the normal (non-collision) path's
      # [5b] works around (see fix_puffin_stats_and_build_copy_list()'s own
      # header comment) -- hop A runs its OWN rewrite_table_path, so it is
      # independently exposed to it for any table carrying Iceberg table
      # statistics. Without this, run_spark_copier treats the resulting
      # missing-source-file as a hard failure, failing hop A (and therefore
      # the whole table) on every single run.
      log_info "[Hop A] Verifying staged files (checking only Puffin stats/ files, which rewrite_table_path is known to mis-stage)..."
      local HOPA_COPY_LIST_LOCAL="${HOPA_LOCAL_FILE_LIST%.csv}.copy-list.csv"
      fix_puffin_stats_and_build_copy_list \
        "${HOPA_LOCAL_FILE_LIST}" \
        "${HOPA_STAGING_LOCATION}/stats" \
        "${SRC_PREFIX}${TABLE_RELATIVE_PATH}/stats" \
        "${HOPA_TARGET_PREFIX}" \
        "${SRC_PREFIX}" \
        "${HOPA_TARGET_PREFIX}" \
        "${HOPA_COPY_LIST_LOCAL}" || {
        log_error "[Hop A] Could not build the copy list for ${QUALIFIED_TABLE}."
        _collision_restore_ha_args
        return 1
      }
      local HOPA_COPY_ROWS="$PUFFIN_FIX_ROW_COUNT"
      if [[ "$HOPA_COPY_ROWS" -gt 0 ]]; then
        # 5th arg (collision_src_plain_authority, distcp-only -- see
        # run_distcp_copier()'s own parameter comment): HOPA_COPY_LIST_LOCAL's
        # source rows are all "${SRC_PREFIX}..." (the PLAIN shared name --
        # see fix_puffin_stats_and_build_copy_list()'s own args above),
        # which distcp cannot safely resolve via the global HDFS_HA_ARGS
        # override this Hop A branch has installed (confirmed by direct
        # testing: doing so makes fs.defaultFS ambiguous and breaks AM
        # container localization of mapreduce.tar.gz). Passing SRC_PREFIX
        # here tells run_distcp_copier to rewrite every source row to the
        # SRCALIAS authority and use alias-scoped -D args instead. Ignored
        # entirely by run_spark_copier when COPY_ENGINE=spark (Spark's own
        # Hop A copier does not need this fix -- see run_spark_copier()'s
        # header for why it doesn't hit the same ambiguity).
        run_copy_engine \
          "${HOPA_COPY_LIST_LOCAL}" \
          "hdfs://${HOPA_ACTIVE_NN}${STAGING_DIR}-hopA/copy-list/${HOPA_COPY_LIST_LOCAL##*/}" \
          "${QUALIFIED_TABLE}.hopA" \
          "${HOPA_COPY_ROWS}" \
          "${SRC_PREFIX}" || {
          _collision_restore_ha_args
          return 1
        }
        _HOPA_FILES_TO_COPY="$HOPA_COPY_ROWS"
        _HOPA_FILES_COPIED="$FILES_COPIED"
        _HOPA_FILES_SKIPPED="$FILES_SKIPPED"
        _HOPA_FILES_FAILED="$FILES_FAILED"
      fi
    fi
    local _HOPA_COPY_SECONDS=$(( $(date +%s) - _HOPA_COPY_START ))
    log_info "[Hop A] Copy engine (${COPY_ENGINE}) elapsed: $(format_duration "$_HOPA_COPY_SECONDS") for ${HOPA_ROWS} file(s)."

    # Restore to NATIVE (un-overridden) HA args for hop B and everything
    # after it -- hop B is a purely local, same-cluster rewrite: the shared
    # name already means DESTINATION via this node's own unmodified
    # hdfs-site.xml, exactly like every other non-hop-A call this script
    # makes, and DESTINATION's active NameNode is now addressed via the
    # bare host:port resolved by resolve_active_namenode_hostport (which
    # needs no HA config of its own -- it's a literal address). No isolated
    # override is needed here at all, unlike hop A's redirect.
    _collision_restore_ha_args

    ########################################
    # TEMP-REGISTER hop A's output on DST so hop B can address it through
    # the catalog -- rewrite_table_path only ever takes a "table =>"
    # identifier resolved via a real catalog entry, never a raw metadata
    # file location.
    #
    # A SECOND, HADOOP-FILESYSTEM-BACKED CATALOG, NOT ${SPARK_CATALOG} --
    # this is the key fix here. An earlier version of this code temp-
    # registered into ${SPARK_CATALOG} (Hive-backed), addressed via the
    # plain shared name. That got the READ half right (register_table
    # physically opens and parses metadata_file, so it needs a working
    # address for wherever hop A's copier put those bytes -- the plain name
    # works because this host's own native Hadoop client config already
    # resolves it, same as everywhere else in this script). But hop A's
    # rewritten content embeds the resolved bare active-NameNode host:port
    # in its own "location" field and every manifest/manifest-list path --
    # and a Hive-backed catalog's register_table commits that location into
    # the Hive Metastore SERVER, a SEPARATE, already-running JVM that never
    # sees this script's per-call --conf overrides (those only exist in the
    # spark-sql client process). The Metastore resolves that location with
    # its OWN, un-overridden Hadoop config, so an authority that only this
    # script's per-call overrides define cannot be resolved there, and the
    # commit retries until it gives up -- on every collision-mode bootstrap,
    # whatever the table's size.
    #
    # A Hadoop-filesystem-backed catalog (type=hadoop) never involves the
    # Metastore server at all -- register_table's whole read+commit happens
    # inside THIS spark-sql client JVM. A bare host:port authority resolves
    # even more trivially than a synthetic HA name would (a literal DFS
    # client connection, no HA proxy-provider lookup needed at all). Its
    # warehouse root is deliberately qualified with the SAME resolved bare
    # host:port hop A used (not the plain name): hop B's rewrite_table_path
    # validates that the table's OWN current metadata file address (as this
    # catalog reports it) starts with source_prefix, not just the
    # manifest-embedded content -- a plain-prefixed warehouse here would
    # make that check fail immediately with "does not start with
    # hdfs://<host>:<port>". This catalog and its backing directory are
    # 100% disposable: no Hive Metastore entry is ever created for the
    # throwaway table, so retiring it after hop B (further below) is a plain
    # recursive HDFS delete, not the purge-flag dance a real Hive table
    # would require.
    ########################################
    local TEMP_REGISTER_METADATA_FILE="hdfs://${DST_NAMESERVICE}${TABLE_RELATIVE_PATH}/metadata/${HOPA_METADATA_NAME}"

    log_substage "Patch ancestor metadata files before temp-registration"

    ########################################
    # PATCH EVERY METADATA.JSON IN THE ANCESTOR CHAIN: an INCREMENTAL hop A
    # rewrite (start_version set) only rewrites content for the delta since
    # the checkpoint. hop B (source_prefix = the resolved bare host:port,
    # always a FULL walk -- the throwaway scratch table has only ever had
    # one version, so it has no start_version of its own to give it) then
    # walks EVERY ancestor .metadata.json reachable in the table's history
    # (RewriteTablePathSparkAction.rewriteVersionFileS, plural -- confirmed
    # via the real failure's own stack trace), not just the current one.
    # Each ancestor file independently carries a FULL "snapshots" array
    # (Iceberg's metadata.json format always retains the complete list, not
    # just what changed in that version), and any ancestor whose CONTENT
    # was last finalized by a PREVIOUS run's hop B (i.e. every file already
    # sitting in this directory before hop A ran this time) still holds
    # PLAIN-prefixed references throughout -- hop A's incremental
    # substitution never touched them, because they were not part of THIS
    # run's delta. Confirmed via a real incremental collision-mode run:
    # hop B fails immediately on the first such untouched reference in
    # whichever ancestor file it opens first --
    # java.lang.IllegalArgumentException: Path hdfs://<plain>/.../snap-
    # <old-snapshot>-....avro does not start with hdfs://<host>:<port>/.
    # An earlier version of this fix patched only hop A's OWN (current)
    # output file, which is why that first attempt did not hold: the
    # failure was always going to be in one of the OTHER, older files hop B
    # also opens.
    #
    # A full (non-incremental) hop A rewrite would not hit this
    # (RewriteTablePathSparkAction's blanket substitution covers the WHOLE
    # walked range when nothing is excluded from it -- see "CHAINED
    # CROSS-CLUSTER REWRITES" in this script's header for the general
    # blanket-substitution behavior), but forcing a full walk on every
    # incremental run defeats incremental mode's entire purpose for a
    # large, long-lived table -- exactly the tables this collision path
    # most needs to scale for.
    #
    # Patched here instead: list every "*.metadata.json" file physically
    # present in the REAL table's metadata/ directory (this directory is
    # the union of every run's output, so it already contains every
    # ancestor hop B could possibly open), and for each one, replace any
    # remaining literal "hdfs://<plain-name>/" occurrence with
    # "hdfs://<active NameNode host:port>/" in place. Not a new kind of edit --
    # it is the EXACT SAME substitution hop A's own rewrite already applies
    # to its own output, just applied file-by-file to catch up whatever an
    # incremental walk (this run's or an earlier one's) left untouched. A
    # no-op on any file that already has no plain-prefixed reference left
    # (every file hop A actually rewrote this run, and every file a prior
    # sweep already caught up).
    #
    # SCALE NOTE: this directory's metadata.json COUNT grows by one on
    # every commit and is NOT pruned by this script (see "DESTINATION
    # METADATA RETENTION" in this script's header) -- for a table with a
    # very long commit history and no retention policy of its own, this
    # sweep's cost grows with total ancestor-file count over the table's
    # lifetime, not with this run's delta size. Acceptable for now (each
    # round trip is a small JSON file, and a no-op file is nearly free
    # since PATCH#1's own file, sed, and PATCH#2's write are all local/fast
    # operations); revisit with a metadata-log-driven file list (walking
    # only files actually reachable from the CURRENT metadata-log, via the
    # same technique table_has_deletion_vectors()/
    # resolve_src_metadata_json_for_snapshot() use to query Iceberg
    # metadata tables) if this ever shows up as a real cost on a
    # high-commit-frequency table.
    ########################################
    local HOPA_METADATA_DIR="hdfs://${DST_NAMESERVICE}${TABLE_RELATIVE_PATH}/metadata"
    local HOPA_METADATA_LISTING
    HOPA_METADATA_LISTING=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -ls "${HOPA_METADATA_DIR}" 2>/dev/null) || true
    local -a HOPA_METADATA_FILES=()
    local _hopa_ls_line _hopa_bn
    while IFS= read -r _hopa_ls_line; do
      [[ "$_hopa_ls_line" == -* ]] || continue
      _hopa_bn="${_hopa_ls_line##*/}"
      [[ "$_hopa_bn" == *.metadata.json ]] || continue
      HOPA_METADATA_FILES+=("${HOPA_METADATA_DIR}/${_hopa_bn}")
    done <<< "$HOPA_METADATA_LISTING"
    if [[ ${#HOPA_METADATA_FILES[@]} -eq 0 ]]; then
      log_error "Could not list any *.metadata.json file under ${HOPA_METADATA_DIR} for ${QUALIFIED_TABLE}"
      log_error "to patch before temp-registering."
      _collision_restore_ha_args
      return 1
    fi

    ########################################
    # HIGH-WATER-MARK: bound this sweep to ancestors that could still be
    # plain-prefixed, instead of re-listing/re-checking every ancestor
    # metadata.json ever written for this table on every single run. Once a
    # metadata.json is written (by hop A this run, or by a PAST run's hop A
    # or hop B), it is NEVER modified again except by this very sweep --
    # Iceberg always writes a brand-new file under a new version number for
    # the next commit, never edits an old one in place. That makes "already
    # checked/patched" a permanent, one-way fact per file: once this sweep
    # has seen a file, it never needs to look at it again, forever.
    #
    # Files are named "<NNNNN>-<uuid>.metadata.json" (Iceberg's own
    # convention; hop A's version-number computation for its HEAD file --
    # see HOPA_VERSION_NUM further below -- already relies on this same
    # leading-integer format). The marker below stores the highest such
    # <NNNNN> this table has ever had checked, mirrored on HDFS the same
    # way a checkpoint is (write_checkpoint_hdfs_one), so it survives across
    # runs/hosts exactly like the replication checkpoint does. Only files
    # whose version number is STRICTLY GREATER than the marker are read at
    # all; the marker then advances to the highest version number seen in
    # THIS listing (whether or not that file actually needed a rewrite),
    # so a fully clean run still moves the watermark forward.
    #
    # Effect at scale: a table with 1,000,000 historical metadata.json
    # files pays this sweep's O(ancestor count) cost ONCE (its first-ever
    # collision-mode run, when nothing has a watermark yet); every
    # run after that only checks the handful of metadata.json files hop A
    # itself just wrote this run -- the same delta-bounded cost profile the
    # rest of this design (Hop A/B's shared start_version) already commits
    # to, applied to this last remaining unbounded step.
    ########################################
    local HOPA_PATCH_MARKER_PATH
    HOPA_PATCH_MARKER_PATH="hdfs://${DST_NAMESERVICE}${CHECKPOINT_DIR}/$(sanitize_for_filename "${HIVE_DB}.${TABLE_NAME}").collision_patched_upto"
    local HOPA_PATCH_MARKER
    HOPA_PATCH_MARKER=$(run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -cat "${HOPA_PATCH_MARKER_PATH}" 2>/dev/null) || HOPA_PATCH_MARKER=""
    [[ "$HOPA_PATCH_MARKER" =~ ^[0-9]+$ ]] || HOPA_PATCH_MARKER="0"

    local -a HOPA_FILES_TO_PATCH=()
    local HOPA_PATCH_MAX_SEEN="$HOPA_PATCH_MARKER"
    local _hopa_meta_file _hopa_version_num
    for _hopa_meta_file in "${HOPA_METADATA_FILES[@]}"; do
      _hopa_bn="${_hopa_meta_file##*/}"
      _hopa_version_num="${_hopa_bn%%-*}"
      [[ "$_hopa_version_num" =~ ^[0-9]+$ ]] || _hopa_version_num="0"
      # 10#... forces base-10 (a zero-padded number like "00042" would
      # otherwise be misread as an invalid/octal literal by bash arithmetic).
      if (( 10#${_hopa_version_num} > 10#${HOPA_PATCH_MAX_SEEN} )); then
        HOPA_PATCH_MAX_SEEN="$_hopa_version_num"
      fi
      if (( 10#${_hopa_version_num} > 10#${HOPA_PATCH_MARKER} )); then
        HOPA_FILES_TO_PATCH+=("${_hopa_meta_file}")
      fi
    done
    log_info "Ancestor metadata.json files: ${#HOPA_METADATA_FILES[@]} total, ${#HOPA_FILES_TO_PATCH[@]} newer than watermark (version > ${HOPA_PATCH_MARKER}) and will be read/patched this run."

    if [[ ${#HOPA_FILES_TO_PATCH[@]} -eq 0 ]]; then
      log_info "No ancestor metadata.json files need checking this run (all already covered by the watermark)."
    else
      ########################################
      # BATCH THE ACTUAL PATCH VIA ONE SPARK JOB, not one `hadoop fs -cat`/
      # `sed`/`-put` triplet per file run serially in this bash loop. Each
      # `hadoop fs` invocation forks a brand-new JVM -- fine for the
      # handful of files a steady-state incremental run now sees thanks to
      # the watermark above, but this table's FIRST-EVER run under this
      # sweep (no watermark yet) can still face the table's ENTIRE ancestor
      # count in one go (potentially hundreds of thousands to millions of
      # files), where thousands of sequential JVM forks would dominate the
      # whole replication run by itself. run_spark_copier already solves
      # exactly this shape of problem (one Spark job, many parallel tasks,
      # one JVM total) for STEP 5's file copies; the same approach is used
      # here via a dedicated Scala job that reads each file's small JSON
      # text, does the identical plain->resolved-bare-host substitution sed
      # did, and writes it back only if it actually changed.
      ########################################
      log_info "Patching ${#HOPA_FILES_TO_PATCH[@]} metadata.json file(s) in the ancestor chain before temp-registering (via one batched Spark job)..."
      run_collision_metadata_patch_job \
        "${HOPA_FILES_TO_PATCH[@]}" \
        -- "hdfs://${DST_NAMESERVICE}/" "hdfs://${HOPA_ACTIVE_NN}/" "${QUALIFIED_TABLE}" || {
        log_error "Could not patch one or more metadata.json ancestor files for ${QUALIFIED_TABLE}."
        _collision_restore_ha_args
        return 1
      }
    fi

    # Advance the watermark to the highest version number actually seen in
    # THIS listing (not just what needed patching) -- a fully clean run
    # (every file already correct) still moves it forward, so next run's
    # listing-diff stays bounded to genuinely new ancestors only.
    if [[ "$HOPA_PATCH_MAX_SEEN" != "$HOPA_PATCH_MARKER" ]]; then
      write_checkpoint_hdfs_one "${HOPA_PATCH_MARKER_PATH}" "${HOPA_PATCH_MAX_SEEN}" || {
        log_warn "Could not advance the collision-mode metadata-patch watermark to ${HOPA_PATCH_MAX_SEEN} at"
        log_warn "${HOPA_PATCH_MARKER_PATH} for ${QUALIFIED_TABLE} -- harmless (the next run will simply"
        log_warn "re-check the same files this run already covered), but worth investigating if it recurs."
      }
    fi

    local TEMP_TABLE_NAME
    TEMP_TABLE_NAME="${TABLE_NAME}_collision_tmp_$(date +%Y%m%d_%H%M%S)"
    local HOPB_SCRATCH_CATALOG="iceberg_collision_scratch"
    local HOPB_SCRATCH_NAMESPACE="scratch"
    # Deliberately rooted at STAGING_ROOT directly (not STAGING_DIR, which
    # already ends in "-hopB" by the time hop B runs) -- kept as its own
    # variable (not just inlined into HOPB_SCRATCH_WAREHOUSE) because hop B's
    # file-list redirect logic further below needs this exact relative-path
    # string again, to predict and match the one line rewrite_table_path
    # produces for the throwaway table's own current-metadata-file address.
    local HOPB_SCRATCH_WAREHOUSE_REL="${STAGING_ROOT}/.iceberg-collision-scratch"
    local HOPB_SCRATCH_WAREHOUSE="hdfs://${HOPA_ACTIVE_NN}${HOPB_SCRATCH_WAREHOUSE_REL}"
    local HOPB_SCRATCH_QUALIFIED_TABLE="${HOPB_SCRATCH_NAMESPACE}.${TEMP_TABLE_NAME}"
    EXTRA_CATALOG_ARGS=(
      --conf "spark.sql.catalog.${HOPB_SCRATCH_CATALOG}=org.apache.iceberg.spark.SparkCatalog"
      --conf "spark.sql.catalog.${HOPB_SCRATCH_CATALOG}.type=hadoop"
      --conf "spark.sql.catalog.${HOPB_SCRATCH_CATALOG}.warehouse=${HOPB_SCRATCH_WAREHOUSE}"
    )
    log_substage "Temp-register hop A's output for hop B"
    log_info "Temp-registering hop A's output as ${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} (throwaway, filesystem-only catalog, retired after hop B)..."
    local TEMP_REGISTER_SQL="CALL ${HOPB_SCRATCH_CATALOG}.system.register_table(
    table => '${HOPB_SCRATCH_QUALIFIED_TABLE}',
    metadata_file => '${TEMP_REGISTER_METADATA_FILE}'
  );"
    log_info "Executing: ${TEMP_REGISTER_SQL}"
    log_line ""
    run_spark_sql "${DST_METASTORE_URI}" "${TEMP_REGISTER_SQL}" || {
      log_error "Could not temp-register hop A's output for ${QUALIFIED_TABLE}."
      EXTRA_CATALOG_ARGS=()
      _collision_restore_ha_args
      return 1
    }

    ########################################
    # HOP B -- local cleanup rewrite, resolved bare host:port -> the shared
    # name. Both identities mean DESTINATION here; the shared name is NOT redirected
    # (no override needed -- it already correctly means DESTINATION via
    # this node's own unmodified hdfs-site.xml), so staging_location can
    # safely stay scheme-less, exactly like the normal (non-collision)
    # path's STEP 4. Still against the throwaway HadoopCatalog above (same
    # EXTRA_CATALOG_ARGS, still active) -- HA args are unchanged from
    # temp-register's, so no re-install here.
    ########################################
    log_substage "Hop B: rewrite table metadata to destination naming"
    local HOPB_STAGING_LOCATION="${STAGING_DIR}-hopB"
    ########################################
    # Bound hop B's walk the same way hop A's is bounded: without a
    # start_version, rewrite_table_path walks EVERY snapshot reachable from
    # the temp-registered table's metadata-log (confirmed present above --
    # HOPA_METADATA_FILES/the sed sweep keeps it intact), including ancestor
    # snapshots whose manifest-list/manifest .avro content was finalized (and
    # correctly left PLAIN-prefixed) by a PREVIOUS run's hop B. Those files
    # were never touched by this run's incremental hop A or by the
    # metadata.json-only sed sweep above (sed only rewrites the JSON text,
    # never the binary manifest-list/manifest .avro payload), so a full walk
    # hits their still-plain manifest path and fails with "Encountered
    # manifest file ... not under the source prefix" on the FIRST ancestor
    # snapshot older than this run's delta.
    #
    # Reusing HOPA_START_VERSION (the same checkpoint-derived filename hop A
    # was anchored to) skips exactly those already-finalized ancestors and
    # walks only this run's delta -- the same snapshot range hop A itself
    # just rewrote, which is already correctly resolved-bare-host-prefixed.
    # Cost stays bounded by the run's delta instead of the table's full history.
    ########################################
    local HOPB_REWRITE_SQL="CALL ${HOPB_SCRATCH_CATALOG}.system.rewrite_table_path(
    table => '${HOPB_SCRATCH_QUALIFIED_TABLE}',
    source_prefix => 'hdfs://${HOPA_ACTIVE_NN}',
    target_prefix => 'hdfs://${DST_NAMESERVICE}',
    staging_location => '${HOPB_STAGING_LOCATION}'"
    if [[ -n "${HOPA_START_VERSION:-}" ]]; then
      HOPB_REWRITE_SQL="${HOPB_REWRITE_SQL},
    start_version => '${HOPA_START_VERSION}'"
      log_info "[Hop B] Mode: incremental rewrite (start_version = ${HOPA_START_VERSION}, matching hop A's anchor)"
    else
      log_warn "[Hop B] No hop A start_version available -- falling back to a FULL walk of every ancestor"
      log_warn "[Hop B] snapshot. On a table with a long commit history this is expected to be slow and may"
      log_warn "[Hop B] hit the same 'not under the source prefix' failure on an older, already-finalized"
      log_warn "[Hop B] ancestor. This should only happen on this table's first-ever collision-mode run."
    fi
    HOPB_REWRITE_SQL="${HOPB_REWRITE_SQL}
  );"
    log_info "[Hop B] Executing: ${HOPB_REWRITE_SQL}"
    log_line ""
    local HOPB_OUTPUT
    HOPB_OUTPUT=$(run_spark_sql "${DST_METASTORE_URI}" "${HOPB_REWRITE_SQL}") || {
      log_error "[Hop B] rewrite_table_path failed for ${QUALIFIED_TABLE} (throwaway table"
      log_error "${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} left registered for inspection --"
      log_error "retire it by hand, e.g. 'hdfs dfs -rm -r ${HOPB_SCRATCH_WAREHOUSE}/${HOPB_SCRATCH_QUALIFIED_TABLE//.//}')."
      EXTRA_CATALOG_ARGS=()
      _collision_restore_ha_args
      return 1
    }
    printf '%s\n' "${HOPB_OUTPUT}" | indent_output
    # Nothing after this point needs the throwaway catalog's own conf.
    EXTRA_CATALOG_ARGS=()

    # Hop B succeeded, meaning every ancestor it walked is now confirmed
    # staged/correct on destination -- record that for this table+direction
    # so the NEXT run (even a genuinely incremental one) never needs to
    # force a full Hop A again. See HOPAB_COMPLETED_MARKER_PATH's own
    # comment above hop A's mode decision for the full rationale. Written
    # via the same tmp-then-rename helper the replication checkpoint uses;
    # a failure here is a [WARN], not fatal -- it only costs one more
    # forced-full Hop A on some future run, never a correctness problem.
    write_checkpoint_hdfs_one "${HOPAB_COMPLETED_MARKER_PATH}" "1" || {
      log_warn "Could not write the collision-mode completion marker at ${HOPAB_COMPLETED_MARKER_PATH} for"
      log_warn "${QUALIFIED_TABLE} -- harmless (a future run would just force one more full Hop A), but"
      log_warn "worth investigating if it recurs."
    }

    local HOPB_RESULT_ROW HOPB_METADATA_NAME HOPB_FILE_LIST
    HOPB_RESULT_ROW=$(echo "${HOPB_OUTPUT}" | grep -E '\.metadata\.json' | tail -n 1 || true)
    HOPB_METADATA_NAME=$(echo "${HOPB_RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /\.metadata\.json$/){print $i; exit}}}' | tr -d '[:space:]')
    HOPB_FILE_LIST=$(echo "${HOPB_RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /file-list|\.csv$/){print $i; exit}}}' | tr -d '[:space:]')
    [[ -z "$HOPB_FILE_LIST" ]] && HOPB_FILE_LIST="${HOPB_STAGING_LOCATION%/}/file-list"
    if [[ -z "$HOPB_METADATA_NAME" ]]; then
      log_error "[Hop B] Could not determine rewritten metadata.json name for ${QUALIFIED_TABLE} (throwaway"
      log_error "table ${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} left registered for inspection)."
      _collision_restore_ha_args
      return 1
    fi

    local HOPB_LOCAL_FILE_LIST
    HOPB_LOCAL_FILE_LIST="${LOG_DIR}/${HIVE_DB}.${TABLE_NAME}.hopB-file-list.$(date +%Y%m%d_%H%M%S).csv"
    read_rewrite_file_list "${HOPB_FILE_LIST}" "${HOPB_LOCAL_FILE_LIST}" || {
      log_error "[Hop B] Could not read file list for ${QUALIFIED_TABLE} (throwaway table"
      log_error "${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} left registered for inspection)."
      _collision_restore_ha_args
      return 1
    }

    ########################################
    # Redirect hop B's HEAD-version line away from the throwaway catalog's
    # own scratch directory. rewrite_table_path preserves each file's
    # PRE-rewrite relative path when computing each row's TARGET (a real
    # substring substitution of source_prefix -> target_prefix over the
    # ORIGINAL absolute path), and the head/current version file's
    # pre-rewrite home is the throwaway catalog's own tree (that is where
    # temp-register put it) -- so its listed target, left as-is, would land
    # the corrected content right back in a directory this same code is
    # about to delete. Every OTHER line in this file list already targets
    # the REAL table's metadata directory correctly, because hop A
    # physically wrote its output under the real table's own relative path
    # (just prefixed with the resolved host:port) -- only this one, freshly-created-by-
    # temp-register file needs redirecting.
    #
    # THE SOURCE COLUMN IS NOT PREDICTABLE THE SAME WAY. Confirmed against
    # a real staged file-list CSV (iceberg_dr_test209.orders209): every
    # *.metadata.json row's SOURCE column is `<staging_location>/<bare
    # basename>` -- rewrite_table_path stages metadata.json files FLAT
    # under staging_location, not at their full pre-rewrite relative path
    # the way manifest/data files are. An earlier version of this code
    # predicted the source column as `<staging_location><full relative
    # path>` (mirroring the TARGET column's own derivation) and matched on
    # the exact "source,target" line -- which never matches, since the
    # real source is just the flat basename. Confirmed failure: "Could not
    # find the expected HEAD-version line" on every single collision-mode
    # run, both bootstrap and incremental, prod->DR and DR->prod alike.
    #
    # FIX: match on the TARGET column alone (the side that IS predictable
    # -- a real prefix substitution over the original absolute path, no
    # staging-layout assumption involved) and take whatever source column
    # rewrite_table_path actually wrote, rather than assuming that column's
    # shape. Named "<one-past-hop-A's-version>-hopb-final-<temp table
    # name>-..." (see the version-number computation just below) rather
    # than reusing hop A's exact version number OR the scratch catalog's
    # own bare "v1.metadata.json" (every run's scratch table starts its own
    # version counter fresh at v1, so the bare name alone would collide
    # across repeated incremental runs of the same real table) --
    # TEMP_TABLE_NAME's own timestamp suffix makes this unique per run, and
    # it also cannot collide with hop A's own same-numbered
    # "NNNNN-<uuid>.metadata.json" file already sitting in that directory
    # whose content still names the resolved host:port.
    ########################################
    local HOPB_SCRATCH_TABLE_REL="${HOPB_SCRATCH_WAREHOUSE_REL}/${HOPB_SCRATCH_NAMESPACE}/${TEMP_TABLE_NAME}/metadata/${HOPB_METADATA_NAME}"
    local HOPB_SCRATCH_STALE_TARGET="hdfs://${DST_NAMESERVICE}${HOPB_SCRATCH_TABLE_REL}"
    # Numeric-prefixed, matching Iceberg's own "<NNNNN>-<uuid>.metadata.json"
    # convention (hop A's ancestor files already follow it) -- a bare
    # "hopb-final-..." name with no leading digits makes Iceberg's own
    # BaseMetastoreTableOperations.parseVersion() throw a (non-fatal, but
    # needless) NumberFormatException on every future commit against this
    # table, since it always tries to parse an integer out of the CURRENT
    # metadata filename's leading token. One past hop A's own version number
    # is a safe, always-higher-than-anything-already-there choice; the
    # descriptive "hopb-final-<temp table>-..." suffix is kept for the same
    # collision-avoidance reasons documented above, just moved after the
    # number instead of replacing it (parseVersion only reads the token
    # before the first "-", so everything after it is free-form).
    local HOPA_VERSION_NUM="${HOPA_METADATA_NAME%%-*}"
    [[ "$HOPA_VERSION_NUM" =~ ^[0-9]+$ ]] || HOPA_VERSION_NUM="00000"
    local DST_HEAD_VERSION_NUM
    printf -v DST_HEAD_VERSION_NUM '%05d' "$((10#${HOPA_VERSION_NUM} + 1))"
    local DST_HEAD_METADATA_NAME="${DST_HEAD_VERSION_NUM}-hopb-final-${TEMP_TABLE_NAME}-${HOPB_METADATA_NAME}"
    local DST_HEAD_METADATA_LOCATION="hdfs://${DST_NAMESERVICE}${TABLE_RELATIVE_PATH}/metadata/${DST_HEAD_METADATA_NAME}"
    # Match on the TARGET column (everything after the LAST comma -- an
    # HDFS path never contains one) equalling HOPB_SCRATCH_STALE_TARGET,
    # and rewrite ONLY that column, keeping whatever source column
    # rewrite_table_path actually produced. `awk -v n=1` (a counter, not a
    # flag) confirms exactly one row was redirected -- zero means the
    # stale-target row genuinely was not found (still a hard error, same
    # as before), and more than one would mean this table has two rows
    # pointing at the same stale scratch location, which should not be
    # possible but is worth failing loudly on rather than redirecting the
    # wrong one silently.
    local HOPB_HEAD_MATCH_COUNT
    HOPB_HEAD_MATCH_COUNT=$(awk -F',' -v stale="${HOPB_SCRATCH_STALE_TARGET}" '
      { if ($NF == stale) count++ }
      END { print count+0 }
      ' "${HOPB_LOCAL_FILE_LIST}")
    if [[ "$HOPB_HEAD_MATCH_COUNT" != "1" ]]; then
      log_error "[Hop B] Expected exactly one row targeting the throwaway scratch location in its own file"
      log_error "list for ${QUALIFIED_TABLE} (throwaway table ${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE}"
      log_error "left registered for inspection), found ${HOPB_HEAD_MATCH_COUNT}. Expected target:"
      log_error "  ${HOPB_SCRATCH_STALE_TARGET}"
      _collision_restore_ha_args
      return 1
    fi
    awk -F',' -v OFS=',' -v stale="${HOPB_SCRATCH_STALE_TARGET}" -v new="${DST_HEAD_METADATA_LOCATION}" '
      { if ($NF == stale) { $NF = new }; print }
      ' "${HOPB_LOCAL_FILE_LIST}" > "${HOPB_LOCAL_FILE_LIST}.redirected" \
      && mv -- "${HOPB_LOCAL_FILE_LIST}.redirected" "${HOPB_LOCAL_FILE_LIST}"

    local HOPB_ROWS
    HOPB_ROWS=$(awk 'END{print NR}' "${HOPB_LOCAL_FILE_LIST}" | tr -d '[:space:]')
    log_substage "Hop B: copy rewritten files to destination"
    log_info "[Hop B] Files to (re)write: ${HOPB_ROWS} (data files with unchanged bytes are skipped by the copier's own already-present check; only manifest/manifest-list/metadata.json content needs new bytes)."
    local _HOPB_COPY_START
    _HOPB_COPY_START=$(date +%s)
    local _HOPB_FILES_TO_COPY=0 _HOPB_FILES_COPIED=0 _HOPB_FILES_SKIPPED=0 _HOPB_FILES_FAILED=0
    if [[ "$HOPB_ROWS" -gt 0 ]]; then
      # Same KNOWN UPSTREAM ICEBERG BUG hop A's own copy step works around
      # above (see fix_puffin_stats_and_build_copy_list()'s header comment)
      # -- hop B runs its OWN rewrite_table_path too, so it is independently
      # exposed. Applied AFTER the HEAD-version redirect above so the
      # redirected line is what gets normalized here, not the pre-redirect one.
      log_info "[Hop B] Verifying staged files (checking only Puffin stats/ files, which rewrite_table_path is known to mis-stage)..."
      local HOPB_COPY_LIST_LOCAL="${HOPB_LOCAL_FILE_LIST%.csv}.copy-list.csv"
      fix_puffin_stats_and_build_copy_list \
        "${HOPB_LOCAL_FILE_LIST}" \
        "hdfs://${DST_NAMESERVICE}${HOPB_STAGING_LOCATION}/stats" \
        "hdfs://${HOPA_ACTIVE_NN}${TABLE_RELATIVE_PATH}/stats" \
        "hdfs://${DST_NAMESERVICE}" \
        "hdfs://${HOPA_ACTIVE_NN}" \
        "hdfs://${DST_NAMESERVICE}" \
        "${HOPB_COPY_LIST_LOCAL}" || {
        log_error "[Hop B] Could not build the copy list for ${QUALIFIED_TABLE} (throwaway table"
        log_error "${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} left registered for inspection)."
        _collision_restore_ha_args
        return 1
      }
      local HOPB_COPY_ROWS="$PUFFIN_FIX_ROW_COUNT"
      if [[ "$HOPB_COPY_ROWS" -gt 0 ]]; then
        run_copy_engine \
          "${HOPB_COPY_LIST_LOCAL}" \
          "hdfs://${DST_NAMESERVICE}${STAGING_DIR}-hopB/copy-list/${HOPB_COPY_LIST_LOCAL##*/}" \
          "${QUALIFIED_TABLE}.hopB" \
          "${HOPB_COPY_ROWS}" || {
          log_error "[Hop B] copy failed for ${QUALIFIED_TABLE} (throwaway table"
          log_error "${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE} left registered for inspection)."
          _collision_restore_ha_args
          return 1
        }
        _HOPB_FILES_TO_COPY="$HOPB_COPY_ROWS"
        _HOPB_FILES_COPIED="$FILES_COPIED"
        _HOPB_FILES_SKIPPED="$FILES_SKIPPED"
        _HOPB_FILES_FAILED="$FILES_FAILED"
      fi
    fi
    local _HOPB_COPY_SECONDS=$(( $(date +%s) - _HOPB_COPY_START ))
    log_info "[Hop B] Copy engine (${COPY_ENGINE}) elapsed: $(format_duration "$_HOPB_COPY_SECONDS") for ${HOPB_ROWS} file(s)."
    log_info "[Collision] Combined copy time (Hop A + Hop B, ${COPY_ENGINE}): $(format_duration "$(( _HOPA_COPY_SECONDS + _HOPB_COPY_SECONDS ))")"

    # STEP 8 summary fix: on this (SAME-NAMESERVICE COLLISION) path, both
    # hops run their own copy engine, but FILES_COPIED/FILES_SKIPPED/
    # FILES_FAILED are the SAME shared locals each call overwrites -- left
    # unchecked, hop B's numbers alone would reach STEP 8, against a
    # FILES_TO_COPY that is never set on this path at all (it is only ever
    # assigned in the normal, non-collision copy path further below),
    # producing a nonsensical "N of 0" summary line. Combine both hops'
    # already-captured (_HOPA_*/_HOPB_*) totals here instead, so STEP 8
    # reports the true combined picture across both hops.
    FILES_TO_COPY=$(( _HOPA_FILES_TO_COPY + _HOPB_FILES_TO_COPY ))
    FILES_COPIED=$(( _HOPA_FILES_COPIED + _HOPB_FILES_COPIED ))
    FILES_SKIPPED=$(( _HOPA_FILES_SKIPPED + _HOPB_FILES_SKIPPED ))
    FILES_FAILED=$(( _HOPA_FILES_FAILED + _HOPB_FILES_FAILED ))

    ########################################
    # RETIRE the throwaway catalog entry. Unlike a real Hive table, this
    # HadoopCatalog registration never touched the Hive Metastore at all --
    # there is no external.table.purge to get wrong, because there is no
    # Hive table to accidentally purge. "Dropping" it is therefore a plain
    # recursive delete of its own disposable directory tree. Done here,
    # BEFORE restoring HA args to native, because this directory lives
    # under the resolved bare host:port -- the native args below no longer
    # resolve it.
    ########################################
    log_substage "Clean up temp-register scratch catalog"
    log_info "Retiring throwaway catalog entry ${HOPB_SCRATCH_CATALOG}.${HOPB_SCRATCH_QUALIFIED_TABLE}..."
    run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -rm -r -f -skipTrash \
      "${HOPB_SCRATCH_WAREHOUSE}/${HOPB_SCRATCH_QUALIFIED_TABLE//.//}" >/dev/null 2>&1 || {
      log_warn "Could not delete throwaway scratch directory"
      log_warn "${HOPB_SCRATCH_WAREHOUSE}/${HOPB_SCRATCH_QUALIFIED_TABLE//.//} -- harmless leftover (no Hive"
      log_warn "table, no purge risk) -- delete it by hand once convenient."
    }
    log_line ""

    _collision_restore_ha_args

    ########################################
    # FINAL register/repoint on the REAL destination table, using hop B's
    # redirected output (which reads the plain shared name throughout,
    # exactly like a normal, non-collision destination table). Same
    # register_table-vs-ALTER-TABLE-repoint split as the normal path's
    # STEP 6, and the same Hive-engine fixups (register_bootstrap_fixups(),
    # defined once near the top of this function so every branch --
    # collision or not -- can call it).
    ########################################
    local DST_METADATA_LOCATION="${DST_HEAD_METADATA_LOCATION}"

    # PREVENTION, symmetric with the pre-flight check before hop A: refuse
    # to ever register/repoint the destination catalog at output that
    # still has a leftover collision-scratch authority baked into it.
    # Checked under NATIVE (just-restored) args, so the plain-named path
    # physically resolves to DESTINATION as intended. This is this run's
    # OWN just-produced HEAD file, not a deep ancestor scan -- it catches
    # THIS run failing to fully convert its own output back to plain (a Hop
    # B bug, or a future change to this logic) before that output is ever
    # trusted as "final," rather than after, when it would poison this
    # table for every future run exactly like the incident
    # assert_no_collision_scratch_leak documents.
    assert_no_collision_scratch_leak "${DST_METADATA_LOCATION}" "hop B's own freshly-produced metadata.json" "${QUALIFIED_TABLE}" || return 1

    log_stage 6 "Registering/refreshing destination catalog (SAME-NAMESERVICE COLLISION path)..."
    if [[ "$FORCE_FULL_REWRITE" == "true" ]]; then
      # --rebuild-dst-table-from-source on the collision path: same
      # rename-out-of-the-way-then-register_table sequence as the
      # non-collision path's own FORCE_FULL_REWRITE branch (see that
      # branch's own comments, further below in this function, for the
      # full rationale on why a plain ALTER TABLE repoint cannot cross a
      # table-uuid boundary and why RENAME, not DROP, is used for the
      # backup).
      log_info "(ALTER TABLE ... SET TBLPROPERTIES('metadata_location'=...) cannot cross a table-uuid boundary --"
      log_info " Hive's Iceberg storage handler unconditionally rejects that. Re-registering fresh instead.)"
      local BACKUP_TABLE_NAME
      BACKUP_TABLE_NAME="${TABLE_NAME}_pre_rebuild_$(date +%Y%m%d_%H%M%S)"
      local BACKUP_QUALIFIED_TABLE="${HIVE_DB}.${BACKUP_TABLE_NAME}"
      log_info "Backing up destination's current (non-matching) table by renaming it to ${BACKUP_QUALIFIED_TABLE}"
      log_info "(still fully live/queryable under that name; nothing is deleted or purged)..."
      local RENAME_SQL="ALTER TABLE ${HIVE_TABLE_REF} RENAME TO $(hive_table_ref "${BACKUP_QUALIFIED_TABLE}");"
      log_info "Executing: ${RENAME_SQL}"
      run_beeline_statement "${DST_JDBC_URL}" "${RENAME_SQL}" || {
        log_error "Backup rename failed for ${QUALIFIED_TABLE} -> ${BACKUP_QUALIFIED_TABLE}; destination catalog"
        log_error "entry still points at its old, non-matching lineage under its original name. Nothing else"
        log_error "was changed -- safe to investigate and re-run."
        return 1
      }
      log_info "Backed up: ${BACKUP_QUALIFIED_TABLE} now holds destination's PRIOR (pre-rebuild) data/lineage."
      log_info "It is a normal, fully-queryable Iceberg table -- drop it by hand later once you've confirmed it's"
      log_info "no longer needed; this script never deletes it automatically."
      log_warn "CAUTION before dropping ${BACKUP_QUALIFIED_TABLE}: the rename did not move anything, so the backup"
      log_warn "and the re-registered ${QUALIFIED_TABLE} share ONE table directory (${DST_TABLE_LOCATION}),"
      log_warn "and files with the same name in both lineages are the same physical files. A DROP that purges"
      log_warn "data (DROP ... PURGE, or a table with external.table.purge=true) can delete files"
      log_warn "${QUALIFIED_TABLE} still needs. Disarm purge on the backup first, then drop it:"
      log_warn "  ALTER TABLE ${BACKUP_QUALIFIED_TABLE} SET TBLPROPERTIES ('external.table.purge'='false');"
      log_warn "  DROP TABLE ${BACKUP_QUALIFIED_TABLE};"

      log_info "Registering destination catalog against source's freshly-replicated metadata (register_table)..."
      local REGISTER_SQL="CALL ${SPARK_CATALOG}.system.register_table(
    table => '${QUALIFIED_TABLE}',
    metadata_file => '${DST_METADATA_LOCATION}'
  );"
      log_info "Executing: ${REGISTER_SQL}"
      log_line ""
      run_register_table "${REGISTER_SQL}" || {
        log_error "register_table failed for ${QUALIFIED_TABLE} after the backup rename. The destination table"
        log_error "no longer exists under its original name -- its prior data/lineage is safe under"
        log_error "${BACKUP_QUALIFIED_TABLE} (see above), and the freshly-replicated files are on HDFS at"
        log_error "${DST_TABLE_LOCATION}; retry register_table by hand, rename the backup back if needed, or"
        log_error "re-run this script."
        return 1
      }
      register_bootstrap_fixups || return 1
    elif [[ "$BOOTSTRAP" == "true" ]]; then
      local REGISTER_SQL="CALL ${SPARK_CATALOG}.system.register_table(
    table => '${QUALIFIED_TABLE}',
    metadata_file => '${DST_METADATA_LOCATION}'
  );"
      log_info "Executing: ${REGISTER_SQL}"
      log_line ""
      run_register_table "${REGISTER_SQL}" || {
        log_error "register_table failed for ${QUALIFIED_TABLE}."
        return 1
      }
      register_bootstrap_fixups || return 1
    else
      local REPOINT_SQL="ALTER TABLE ${HIVE_TABLE_REF} SET TBLPROPERTIES (
    'metadata_location' = '${DST_METADATA_LOCATION}'
  );"
      log_info "Executing: ${REPOINT_SQL}"
      log_line ""
      run_beeline_statement "${DST_JDBC_URL}" "${REPOINT_SQL}" || {
        log_error "metadata_location re-point failed for ${QUALIFIED_TABLE}."
        return 1
      }
    fi
    log_line ""
  else

  ########################################
  # [4/8] Stage path-corrected metadata via rewrite_table_path.
  #
  # Per iceberg/docs/docs/spark-procedures.md and the
  # RewriteTablePathProcedure/RegisterTableProcedure source in the Iceberg
  # repo:
  #   - The callable procedure is `<catalog>.system.rewrite_table_path`
  #     (e.g. `spark_catalog.system.rewrite_table_path`) -- a bare `sys.*`
  #     is not a resolvable catalog reference in Spark SQL.
  #   - Output columns are `latest_version`, `file_list_location`,
  #     `rewritten_manifest_file_paths_count`,
  #     `rewritten_delete_file_paths_count`.
  #   - `file_list_location` points at a CSV of exact `sourcepath,targetpath`
  #     pairs for every file added between start_version and end_version (or
  #     all reachable files, for a full/bootstrap rewrite). The Spark copier is driven
  #     off this CSV, copying only enumerated new/changed files instead of
  #     whole data/metadata directories.
  ########################################
  log_stage 4 "Staging path-corrected metadata (rewrite_table_path)..."

  # Fallback only; the real value is always read from rewrite_table_path's
  # own output below. RewriteTablePathSparkAction appends a "/" to the
  # staging location it is given and writes the list to
  # "<staging location>/file-list" (no extension).
  local FILE_LIST_LOCATION="${STAGING_LOCATION%/}/file-list"
  local REWRITE_SQL

  if [[ "$BOOTSTRAP" == "true" || "$FORCE_FULL_REWRITE" == "true" || "$EMPTY_DST_FULL_REWRITE" == "true" ]]; then
    # No start_version: either a real bootstrap (BOOTSTRAP=true), or
    # --rebuild-dst-table-from-source's full-rewrite-then-rename-and-register
    # case (FORCE_FULL_REWRITE=true, BOOTSTRAP=false) -- destination's data
    # isn't anywhere in source's metadata log, so there is no valid
    # start_version to give an incremental rewrite; every reachable file
    # in source's CURRENT state must be (re)considered.
    REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${DST_PREFIX}',
    staging_location => '${STAGING_LOCATION}'
  );"
    if [[ "$BOOTSTRAP" == "true" ]]; then
      log_info "Mode: full rewrite (bootstrap) - all reachable metadata files"
    elif [[ "$EMPTY_DST_FULL_REWRITE" == "true" ]]; then
      log_info "Mode: full rewrite (destination exists but is empty) - all reachable metadata files, then a normal repoint"
    else
      log_info "Mode: full rewrite (--rebuild-dst-table-from-source) - all reachable metadata files, then rename+re-register (not a repoint -- see step 6/8)"
    fi
  else
    # start_version must be a BARE FILENAME (e.g.
    # "00004-030a7dc0-....metadata.json"), never a full "hdfs://..." path,
    # even though the checkpoint file/CHECKPOINT_METADATA stores the full
    # path for human-readable debugging. Iceberg's
    # RewriteTablePathSparkAction.versionInFilePath(path, version) strips
    # each metadata-log entry's path down to a bare filename via
    # RewriteTablePathUtil.fileName(path), then compares it to `version`
    # (our input) as-is, unstripped -- so a full path can never match a
    # bare-filename comparison. This matches every test call site in
    # TestRewriteTablePathsAction.java and the Iceberg docs' own example
    # (start_version => 'v2.metadata.json'), which all pass bare filenames.
    # Strip to the bare filename right here, at the point of substitution
    # into start_version, rather than changing what is stored in the
    # checkpoint file -- keeping the full path there remains useful for a
    # human reading the checkpoint file directly.
    local START_VERSION_FILENAME="${CHECKPOINT_METADATA##*/}"
    REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${DST_PREFIX}',
    staging_location => '${STAGING_LOCATION}',
    start_version => '${START_VERSION_FILENAME}'
  );"
    log_info "Mode: incremental rewrite (start_version = ${START_VERSION_FILENAME}, end_version = latest)"
  fi

  log_info "Executing: ${REWRITE_SQL}"
  log_line ""
  local REWRITE_OUTPUT

  # REWRITE_STDERR_FILE: a side capture of this call's stderr, used ONLY to
  # detect the broken-chain signature below -- REWRITE_OUTPUT itself must
  # stay untouched (stdout alone), since the result-row parsing further
  # below greps/awks it for the returned latest_version/file_list_location
  # columns, and merging stderr into it (a plain `2>&1`) could feed that
  # parser the wrong line. Whether a given Spark/log4j deployment routes an
  # ERROR-level exception to fd1 or fd2 is not something this script
  # controls or should assume either way, so both streams are checked for
  # the signature below.
  #
  # Captured to a file rather than a second $(...) so it can be replayed to
  # the log verbatim afterward -- run_spark_sql()'s own diagnostic lines
  # ("Running spark-sql: ...", the pretty-printed command) are deliberately
  # written to fd2 (see that function's comment), and without replaying
  # this file to fd2 below, redirecting fd2 here would silently drop them
  # from the run log instead of just reordering them, as the previous
  # (non-file) redirect did.
  local REWRITE_STDERR_FILE
  REWRITE_STDERR_FILE=$(mktemp) || {
    log_error "Could not create a temp file to capture rewrite_table_path's stderr for ${QUALIFIED_TABLE}."
    return 1
  }
  REWRITE_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${REWRITE_SQL}" "${REWRITE_STDERR_FILE}")
  local REWRITE_RC=$?

  # BROKEN INCREMENTAL CHAIN AUTO-RECOVERY -- see "CHAINED CROSS-CLUSTER
  # REWRITES" in this script's header for the full mechanism and the real
  # incident this responds to. Only attempted for a genuine incremental run
  # (never already BOOTSTRAP/FORCE_FULL_REWRITE, which are already full
  # rewrites -- retrying those the same way would just repeat the same
  # failure or mask a different one).
  #
  # Checked BEFORE replaying the raw stderr below (rather than after, as
  # this used to be) so a run that is about to auto-recover can say so
  # first. Without this, an operator tailing/scanning the log hits an
  # unexplained ~80-line Java stack trace and an "ERROR SparkSQLDriver:
  # Failed" line before ever reaching the WARN that explains it is expected
  # and being handled -- easy to misread as a failed run even though the
  # final summary correctly says SUCCESS.
  local BROKEN_CHAIN_PATTERN="IllegalArgumentException: Version file .*\.metadata\.json doesn'?t exist"
  # STALE_ANCHOR_PATTERN: start_version itself was rejected, before any walk
  # began. Either the checkpoint names a metadata.json that is no longer in
  # source's metadata log (Iceberg keeps only the newest
  # write.metadata.previous-versions-max entries there, 100 by default, so an
  # anchor older than that many commits falls off it -- a long gap between
  # runs, or a failback after a long failover period), or that file is gone
  # from source. The checkpoint cannot be used as-is in either case, and the
  # recovery is the same one a broken ancestor gets: re-derive the anchor
  # from the destination's own current snapshot.
  local STALE_ANCHOR_PATTERN="IllegalArgumentException: (Cannot find provided version file .* in metadata log|Version file .*\.metadata\.json does not exist)"
  local REWRITE_IS_KNOWN_RECOVERABLE=false REWRITE_RECOVERY_KIND=""
  if [[ $REWRITE_RC -ne 0 && "$BOOTSTRAP" != "true" && "$FORCE_FULL_REWRITE" != "true" && "$EMPTY_DST_FULL_REWRITE" != "true" ]]; then
    if grep -qE "${BROKEN_CHAIN_PATTERN}" <<<"${REWRITE_OUTPUT}" \
       || grep -qE "${BROKEN_CHAIN_PATTERN}" "${REWRITE_STDERR_FILE}"; then
      REWRITE_RECOVERY_KIND="broken-ancestor"
    elif grep -qE "${STALE_ANCHOR_PATTERN}" <<<"${REWRITE_OUTPUT}" \
         || grep -qE "${STALE_ANCHOR_PATTERN}" "${REWRITE_STDERR_FILE}"; then
      REWRITE_RECOVERY_KIND="stale-anchor"
    fi
  fi
  if [[ -n "$REWRITE_RECOVERY_KIND" ]]; then
    REWRITE_IS_KNOWN_RECOVERABLE=true
    if _spark_stderr_is_live; then
      log_warn "The incremental rewrite_table_path attempt above failed with a known, auto-recoverable"
      log_warn "condition (${REWRITE_RECOVERY_KIND}) -- not a real failure. Auto-recovery follows; see 'CHAINED"
      log_warn "CROSS-CLUSTER REWRITES' in this script's header for the full mechanism."
    elif [[ "$REWRITE_RECOVERY_KIND" == "broken-ancestor" ]]; then
      log_warn "The first incremental rewrite_table_path attempt below is EXPECTED to fail with a"
      log_warn "'Version file ... doesn't exist' exception -- this is a known, auto-recoverable"
      log_warn "condition (a metadata-log entry planted by an earlier cross-cluster hop in the other"
      log_warn "direction, e.g. a prior failover/failback), not a real failure. Auto-recovery follows"
      log_warn "the raw output below; see 'CHAINED CROSS-CLUSTER REWRITES' in this script's header for"
      log_warn "the full mechanism."
    else
      log_warn "The first incremental rewrite_table_path attempt below failed because the checkpoint's"
      log_warn "metadata.json (${START_VERSION_FILENAME}) is no longer usable as start_version on source:"
      log_warn "it has dropped off source's metadata log, or its file no longer exists there. This is a"
      log_warn "known, auto-recoverable condition. Auto-recovery follows the raw output below."
    fi
    if ! _spark_stderr_is_live; then
      log_line ""
      log_line "----- BEGIN raw rewrite_table_path output (expected failure, auto-recovering) -----"
    fi
  fi

  # For known-recoverable failures, show only the error message (not the full Java stack trace)
  if [[ "$REWRITE_IS_KNOWN_RECOVERABLE" == "true" ]]; then
    # Extract just the error message lines (not the 200+ line stack trace)
    replay_spark_stderr "${REWRITE_STDERR_FILE}" errors-only
  else
    # For unknown errors, show everything for debugging
    replay_spark_stderr "${REWRITE_STDERR_FILE}"
  fi

  if [[ "$REWRITE_IS_KNOWN_RECOVERABLE" == "true" ]] && ! _spark_stderr_is_live; then
    log_line "----- END raw rewrite_table_path output -----"
    log_line ""
  fi

  if [[ $REWRITE_RC -ne 0 ]]; then
    if [[ "$REWRITE_IS_KNOWN_RECOVERABLE" == "true" ]]; then
      if [[ "$REWRITE_RECOVERY_KIND" == "broken-ancestor" ]]; then
        log_warn "rewrite_table_path's incremental walk hit an ancestor version file that does not"
        log_warn "exist on SOURCE (${SRC_NAMESERVICE}), even though the checkpoint anchor itself is"
        log_warn "source's own valid file. This is the signature of a metadata-log entry planted by an"
        log_warn "EARLIER cross-cluster rewrite_table_path hop in the other direction (e.g. a prior"
        log_warn "failover/failback) -- see 'CHAINED CROSS-CLUSTER REWRITES' in this script's header."
        log_warn "The checkpoint anchor is not wrong; the gap is an unreachable ancestor between it and"
        log_warn "source's current state."
      else
        log_warn "The checkpoint anchor (${START_VERSION_FILENAME}) is no longer a usable start_version on"
        log_warn "SOURCE (${SRC_NAMESERVICE}). Re-deriving the anchor from the destination's own current"
        log_warn "snapshot instead."
      fi
      log_line ""

      # RE-ANCHOR PAST THE BROKEN ANCESTOR (tried BEFORE a full rewrite).
      #
      # A full rewrite (dropping start_version) does NOT dodge this: Iceberg's
      # RewriteTablePathSparkAction walks source's CURRENT metadata-log
      # regardless of start_version, and dropping start_version only WIDENS
      # the walked range (from "the earliest entry" instead of "the
      # checkpoint") -- it can never SHRINK it past an ancestor that already
      # lies between the checkpoint and current. Confirmed in practice on
      # iceberg_dr_test204.orders204: the full-rewrite fallback hit the
      # exact same "Version file ...00003-....metadata.json doesn't exist"
      # as the incremental attempt it was supposed to recover from.
      #
      # The only way to skip the broken ancestor is a start_version that
      # lies AFTER it in source's history. destination's own
      # current-snapshot-id already IS such a point whenever destination is
      # caught up to anything past the poisoned entry (the common case right
      # after a failover/failback, since the poisoned entry is normally an
      # OLD ancestor relative to destination's current data). Resolve it via
      # the exact same mechanism auto-seed uses --
      # resolve_src_metadata_json_for_snapshot() queries Iceberg's
      # metadata_log_entries metadata table, a pure in-memory lookup by
      # snapshot-id against source's CURRENT metadata-log list. It never
      # reads a historical metadata.json file off HDFS, so it cannot trip
      # over the same missing-ancestor file that just failed above.
      local REANCHOR_SNAPSHOT_ID="" REANCHOR_VERSION_PATH="" REANCHOR_VERSION=""
      local DST_REANCHOR_PROPERTIES DST_REANCHOR_RC=0 DST_REANCHOR_METADATA_LOCATION=""
      DST_REANCHOR_PROPERTIES=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || DST_REANCHOR_RC=$?
      DST_REANCHOR_METADATA_LOCATION=$(parse_tblproperty "$DST_REANCHOR_PROPERTIES" metadata_location)
      REANCHOR_SNAPSHOT_ID=$(parse_tblproperty "$DST_REANCHOR_PROPERTIES" current-snapshot-id)
      if [[ -n "$REANCHOR_SNAPSHOT_ID" ]]; then
        log_info "Attempting to re-anchor past the broken ancestor: resolving destination's own"
        log_info "current-snapshot-id (${REANCHOR_SNAPSHOT_ID}) against SOURCE's metadata_log_entries..."
        REANCHOR_VERSION_PATH=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${REANCHOR_SNAPSHOT_ID}") || REANCHOR_VERSION_PATH=""
        REANCHOR_VERSION="${REANCHOR_VERSION_PATH##*/}"
      fi

      if [[ -n "$REANCHOR_VERSION" && "$REANCHOR_VERSION" != "$START_VERSION_FILENAME" ]]; then
        log_info "Resolved: ${REANCHOR_VERSION} -- source's own metadata.json at the exact point"
        log_info "destination's current data was introduced. Retrying as an incremental rewrite anchored"
        log_info "there instead of at the broken checkpoint (table-uuid is unchanged; STEP 6 will still"
        log_info "repoint normally afterward) -- this replicates only what source gained since"
        log_info "destination's true known-good point, without ever walking through the broken ancestor."
        log_line ""
        REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${DST_PREFIX}',
    staging_location => '${STAGING_LOCATION}',
    start_version => '${REANCHOR_VERSION}'
  );"
        log_info "Mode: incremental rewrite (auto-re-anchored past a broken metadata-log ancestor;"
        log_info "start_version = ${REANCHOR_VERSION}, end_version = latest)"
        log_info "Executing: ${REWRITE_SQL}"
        log_line ""
        : > "${REWRITE_STDERR_FILE}"
        REWRITE_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${REWRITE_SQL}" "${REWRITE_STDERR_FILE}")
        REWRITE_RC=$?
        replay_spark_stderr "${REWRITE_STDERR_FILE}"
        if [[ $REWRITE_RC -eq 0 ]]; then
          REWRITE_REANCHORED=true
        else
          log_warn "Re-anchored retry also failed for ${QUALIFIED_TABLE}. Falling back to a FULL rewrite"
          log_warn "(no start_version) as a last resort, though it is not expected to dodge an ancestor"
          log_warn "that lies between the re-anchor point and current -- only ancestors older than the"
          log_warn "re-anchor point are actually skipped by re-anchoring."
          log_line ""
        fi
      else
        if [[ -z "$REANCHOR_SNAPSHOT_ID" ]]; then
          log_warn "Destination has no current-snapshot-id yet (or its TBLPROPERTIES could not be read);"
          log_warn "cannot re-anchor past the broken ancestor."
        elif [[ -z "$REANCHOR_VERSION" ]]; then
          log_warn "Destination's current-snapshot-id (${REANCHOR_SNAPSHOT_ID}) was not found in source's"
          log_warn "own metadata log; cannot re-anchor past the broken ancestor."
        else
          log_warn "Re-anchoring resolved to the SAME start_version (${REANCHOR_VERSION}) that just failed;"
          log_warn "cannot make progress this way."
        fi
        log_warn "Falling back to a FULL rewrite (no start_version) for ${QUALIFIED_TABLE} instead --"
        log_warn "STEP 6 will still repoint normally afterward (table-uuid is unchanged; only this"
        log_warn "rewrite's mode changes)."
        log_line ""
      fi

      # FULL-REWRITE FALLBACK GUARD. A full rewrite followed by STEP 6's
      # repoint replaces whatever the destination table currently points at
      # with source's current state. That is only safe when the destination's
      # current state is already part of source's history -- otherwise the
      # destination holds commits source never received (e.g. writes made on
      # this cluster while it was primary that were never synced back), and
      # the repoint would drop them from the table. So the fallback is taken
      # only when one of these holds:
      #   - the destination table has no snapshot at all (nothing to drop);
      #   - the re-anchor lookup above already found the destination's
      #     snapshot in source's metadata log;
      #   - that lookup found nothing (the metadata log only reaches back
      #     write.metadata.previous-versions-max entries), but the snapshot
      #     still exists in source's own snapshot set.
      # Anything else is refused: nothing has been changed on the destination
      # at this point, and the table is left for an operator to decide.
      if [[ $REWRITE_RC -ne 0 ]]; then
        local FULL_FALLBACK_REFUSAL=""
        if [[ $DST_REANCHOR_RC -ne 0 || -z "$DST_REANCHOR_METADATA_LOCATION" ]]; then
          FULL_FALLBACK_REFUSAL="the destination table's properties could not be read, so its current state is unknown"
        elif [[ -n "$REANCHOR_SNAPSHOT_ID" && -z "$REANCHOR_VERSION" ]]; then
          local SRC_HAS_DST_SNAPSHOT_RC=0
          log_info "Checking whether destination's current-snapshot-id (${REANCHOR_SNAPSHOT_ID}) still exists in"
          log_info "SOURCE's snapshot set before allowing a full rewrite to supersede it..."
          src_snapshot_exists "${QUALIFIED_TABLE}" "${REANCHOR_SNAPSHOT_ID}" || SRC_HAS_DST_SNAPSHOT_RC=$?
          case "$SRC_HAS_DST_SNAPSHOT_RC" in
            0) log_info "Confirmed: source still holds that snapshot, so the destination's state is part of source's history." ;;
            1) FULL_FALLBACK_REFUSAL="the destination's current-snapshot-id (${REANCHOR_SNAPSHOT_ID}) does not exist in source's snapshot set" ;;
            *) FULL_FALLBACK_REFUSAL="source's snapshot set could not be queried to confirm the destination's current-snapshot-id (${REANCHOR_SNAPSHOT_ID}) is part of source's history" ;;
          esac
        fi
        if [[ -n "$FULL_FALLBACK_REFUSAL" ]]; then
          log_error "Not falling back to a full rewrite for ${QUALIFIED_TABLE}: ${FULL_FALLBACK_REFUSAL}."
          log_error "A full rewrite + repoint would replace the destination table's current state with source's."
          log_error "If the destination holds commits that never reached source (e.g. written while this cluster"
          log_error "was primary), they would be dropped from the table. Nothing has been changed on the"
          log_error "destination by this run."
          log_error "To proceed: sync the destination's own commits to the other cluster first if they are"
          log_error "needed. If the destination's current state is to be superseded by source's, remove this"
          log_error "direction's checkpoint and re-run with --rebuild-dst-table-from-source, which keeps the"
          log_error "existing destination table as a renamed backup:"
          log_error "  $(checkpoint_hdfs_path_for "$SRC_NAMESERVICE" "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")"
          log_error "  $(checkpoint_hdfs_path_for "$DST_NAMESERVICE" "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE")"
          rm -f "${REWRITE_STDERR_FILE}"
          return 1
        fi
        REWRITE_FULL_FALLBACK=true
        REWRITE_SQL="CALL ${SPARK_CATALOG}.system.rewrite_table_path(
    table => '${QUALIFIED_TABLE}',
    source_prefix => '${SRC_PREFIX}',
    target_prefix => '${DST_PREFIX}',
    staging_location => '${STAGING_LOCATION}'
  );"
        log_info "Mode: full rewrite (auto-recovered from a broken incremental metadata-log chain)"
        log_info "Executing: ${REWRITE_SQL}"
        log_line ""
        : > "${REWRITE_STDERR_FILE}"
        REWRITE_OUTPUT=$(run_spark_sql_capturing_stderr "${SRC_METASTORE_URI}" "${REWRITE_SQL}" "${REWRITE_STDERR_FILE}")
        REWRITE_RC=$?
        replay_spark_stderr "${REWRITE_STDERR_FILE}"
        if [[ $REWRITE_RC -ne 0 ]]; then
          log_error "rewrite_table_path (re-anchor and full-rewrite fallbacks both) failed for ${QUALIFIED_TABLE}."
          rm -f "${REWRITE_STDERR_FILE}"
          return 1
        fi
      fi
    else
      log_error "rewrite_table_path failed for ${QUALIFIED_TABLE}."
      rm -f "${REWRITE_STDERR_FILE}"
      return 1
    fi
  fi
  log_yarn_application_id "rewrite_table_path, ${QUALIFIED_TABLE}" "${REWRITE_STDERR_FILE}" "${REWRITE_OUTPUT}"
  rm -f "${REWRITE_STDERR_FILE}"
  # Indented only at the point of printing -- REWRITE_OUTPUT itself stays
  # unindented in memory, since the result-row parsing right below greps/
  # awks it for the returned latest_version/file_list_location columns.
  printf '%s\n' "${REWRITE_OUTPUT}" | indent_output

  # Parse the pipe/tab-delimited result row spark-sql prints for a CALL's
  # returned columns: latest_version, file_list_location, ... (in that order).
  local RESULT_ROW LATEST_METADATA_NAME FILE_LIST_FROM_OUTPUT
  RESULT_ROW=$(echo "${REWRITE_OUTPUT}" | grep -E '\.metadata\.json' | tail -n 1 || true)
  LATEST_METADATA_NAME=$(echo "${RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /\.metadata\.json$/){print $i; exit}}}' | tr -d '[:space:]')
  FILE_LIST_FROM_OUTPUT=$(echo "${RESULT_ROW}" | awk -F'[|\t]' '{for(i=1;i<=NF;i++){if($i ~ /file-list|\.csv$/){print $i; exit}}}' | tr -d '[:space:]')

  if [[ -z "$LATEST_METADATA_NAME" ]]; then
    log_error "Could not determine rewritten metadata.json name from rewrite_table_path output for ${QUALIFIED_TABLE}."
    return 1
  fi
  if [[ -n "$FILE_LIST_FROM_OUTPUT" ]]; then
    FILE_LIST_LOCATION="$FILE_LIST_FROM_OUTPUT"
  fi
  local DST_METADATA_LOCATION="${DST_PREFIX}${TABLE_RELATIVE_PATH}/metadata/${LATEST_METADATA_NAME}"
  REPLICATED_SRC_METADATA_NAME="${LATEST_METADATA_NAME}"
  log_line ""
  log_info "Rewritten target metadata_location : ${DST_METADATA_LOCATION}"
  log_info "File list (source,target pairs)    : ${FILE_LIST_LOCATION}"
  log_line ""

  ########################################
  # [5/8] Copy the exact enumerated files from rewrite_table_path's file list.
  #
  # The file list is a CSV of `sourcepath,targetpath` pairs covering every
  # data/delete/manifest/manifest-list/metadata.json/stats file added since
  # the checkpoint (or all reachable files, for bootstrap).
  #
  # Two properties of this CSV, on Iceberg 1.9.x / Spark 3.5.5, are worth
  # knowing when reading [5a]/[5b] below:
  #   1) file_list_location is a DIRECTORY (Spark part-file output:
  #      _SUCCESS + part-00000-*.csv), not a single file. It must be read
  #      by concatenating the part file(s) inside, not copyToLocal'd
  #      directly.
  #   2) Staged metadata sources are not under a predictable
  #      "staging/metadata/" subpath, and there are more than two target
  #      roots (metadata/, data/<partition>/, stats/) -- the Spark copier
  #      writes each row straight to its own exact target path, so neither
  #      property requires any special handling on this path.
  ########################################
  log_stage 5 "Copying the exact files listed by rewrite_table_path..."
  local _S5_START
  _S5_START=$(date +%s)

  # Deliberately NOT `local`: like STAGE_TIMING_LABELS/STAGE_TIMING_SECONDS
  # above, this needs to survive the return from this function so
  # replicate_one_table()'s wrapper (which forked the subshell this all
  # runs in) can tag it as a FAILED-run artifact if this table's run does
  # not succeed. Reset to "" at the top of that wrapper's subshell, same as
  # the stage timers.
  LOCAL_FILE_LIST="${LOG_DIR}/${HIVE_DB}.${TABLE_NAME}.file-list.$(date +%Y%m%d_%H%M%S).csv"
  # HDFS_HA_ARGS spliced in right after the "fs" subcommand token -- this
  # is a plain `hadoop` CLI process, separate from spark-sql, with its own
  # Hadoop client config resolution; it does not inherit spark-sql's
  # --conf spark.hadoop.* settings, so the nameservice FILE_LIST_LOCATION
  # sits on (the destination's, where staging lives) must be resolvable
  # here too.
  # run_as_hdfs: this is a read-only `hadoop fs` call.
  log_info "[5a] Reading file list from ${FILE_LIST_LOCATION} ..."
  local _t0 _elapsed
  _t0=$(date +%s)
  # read_rewrite_file_list (not a bare "-cat .../part-*"): a real
  # same-nameservice test run surfaced a newer Iceberg runtime that writes
  # file_list_location as a single plain file instead of the
  # _SUCCESS+part-*.csv directory this comment block otherwise assumes --
  # see that function's own comment for the full story. This one-line swap
  # is additive (the original directory shape still works unchanged); it
  # does not touch anything else in this verified block.
  read_rewrite_file_list "${FILE_LIST_LOCATION}" "${LOCAL_FILE_LIST}" || {
    log_error "Could not read file list at ${FILE_LIST_LOCATION} for ${QUALIFIED_TABLE}."
    return 1
  }

  local FILE_COUNT
  # awk 'END{print NR}' counts records regardless of whether the last line
  # has a trailing newline; `wc -l` counts newline characters, so it would
  # undercount by 1 (e.g. report 0 for a genuine single-file delta) if the
  # staged CSV's last row lacks one.
  FILE_COUNT=$(awk 'END{print NR}' "${LOCAL_FILE_LIST}" | tr -d '[:space:]')
  FILES_TO_COPY=$FILE_COUNT  # Track for STEP 8 summary
  _elapsed=$(( $(date +%s) - _t0 ))
  log_info "[5a] Files to copy: ${FILE_COUNT} (read in $(format_duration "$_elapsed"))"

  if [[ "${FILE_COUNT}" -eq 0 ]]; then
    log_info "No files to copy (destination already up to date with this checkpoint)."
  else
    # Uses the target (2nd CSV field) since it is always a correct,
    # fully-qualified hdfs:// path, regardless of the source's staging
    # location, which may be scheme-less or laid out differently.
    #
    # rewrite_table_path's file-list CSV does not consistently qualify every
    # source entry with a scheme: some rows (metadata.json and
    # statistics/Puffin files, e.g. "snap-<uuid>") are emitted as bare paths
    # that are already absolute (e.g.
    # "/var/tmp/iceberg-repl-staging/.../taxis/00002-....metadata.json"), just
    # missing the "hdfs://<ns>" scheme and authority -- they are NOT
    # relative to STAGING_DIR. Staging always lives on the DESTINATION
    # cluster (staging_location is passed qualified with DST_NAMESERVICE --
    # see STAGING_LOCATION in STEP 1), so a bare staged path means a path on
    # the destination's filesystem. A copy tool that resolves an un-prefixed
    # bare path against its OWN default filesystem instead could look on the
    # wrong cluster. Normalize here: prepend only "hdfs://<DST_NAMESERVICE>"
    # (no STAGING_DIR concatenation) to any source entry that is not already
    # scheme-qualified.
    #
    # NOTE: two unrelated file kinds both start with "snap-" -- do not
    # confuse them when reading a file-list CSV or an `hdfs dfs -ls` by eye:
    #   - snap-<snapshot-id>-<attempt>-<uuid>.avro is a manifest-list,
    #     targeting metadata/ (alongside *.metadata.json and *-m0.avro
    #     manifest files).
    #   - snap-<uuid> (no .avro extension, no snapshot-id/attempt prefix) is
    #     a real Puffin statistics file, targeting stats/.
    # Grouping by the CSV's own target column, rather than by eyeballing the
    # "snap-" prefix, is what keeps these from getting mixed up.
    #
    # KNOWN UPSTREAM ICEBERG BUG affecting Puffin statistics files, present
    # on Iceberg 1.9.0/1.9.1/1.9.2 (the version this pipeline targets --
    # every run will hit it for any table that has a Puffin statistics
    # file):
    #
    # RewriteTablePathSparkAction.statsFileCopyPlan() builds the CSV's
    # source column for stats files by calling
    # RewriteTablePathUtil.stagingPath(before.path(), sourcePrefix,
    # stagingDir) -- pointing the source column at the staging directory --
    # but nothing in the action ever actually copies the Puffin file's
    # bytes into that staging path. Every other file kind (data, manifest
    # .avro, manifest-list snap-<id>-<seq>-<uuid>.avro, metadata.json) is
    # both listed and physically staged correctly; only the bare snap-<uuid>
    # Puffin stats file is listed but not staged.
    #   - Introduced by Iceberg PR #11929 ("Spark: support statistics files
    #     in RewriteTablePath", merged 2025-02-08).
    #   - Fixed by Iceberg PR #13881 ("Spark 4.0: Fix source location in
    #     stats file copy plan in RewriteTablePathSparkAction", merged
    #     2025-08-22), backported to Spark 3.4/3.5 in PR #13917 (merged
    #     2025-08-25). Fix is a one-line change: use before.path() (the
    #     real source path) instead of the staging-rewritten path.
    #   - First fixed release: Iceberg 1.10.0 (2025-09-11). Affects 1.9.0,
    #     1.9.1, 1.9.2.
    # This workaround can be removed once the Iceberg runtime is upgraded
    # to 1.10.0+. Until then, the fallback below -- read the file directly
    # from SRC_PREFIX using the CSV's target column's relative path,
    # bypassing staging -- is the correct workaround. Do not skip the row:
    # skipping silently drops the destination table's column statistics.
    #
    # PERFORMANCE AT SCALE (a table can have millions of data files under
    # continuous write load). Two separate bottlenecks lived here; both are
    # eliminated below, not merely reduced:
    #
    #   1) Staging-existence used to be checked with one `hadoop fs -test -e`
    #      subprocess PER CSV ROW -- a full JVM launch each. At 948 rows
    #      that was already the dominant cost of this whole step; at
    #      millions of rows it is not survivable. A single `-ls -R` over
    #      the whole staging tree avoids the per-row JVM launches but does
    #      NOT avoid the underlying problem at real scale: its output would
    #      be millions of lines, all held in one bash string and hashed
    #      into an associative array in memory. [5b] below instead uses
    #      the fact this script's own investigation already established:
    #      the ONLY documented, understood reason a staged file can be
    #      missing is the Puffin stats/-file bug described above, and it
    #      is scoped EXCLUSIVELY to files targeting stats/ -- one per
    #      snapshot. [5b] filters the CSV down to just those rows (one
    #      cheap awk pass, not a per-row fork) and verifies ONLY that small
    #      set. Cost now tracks SNAPSHOT COUNT, not data-file count. Every
    #      other row is trusted outright -- not a weaker guarantee, just
    #      not re-checking rows already known to always stage correctly;
    #      if that were ever wrong for some future, undocumented reason, the
    #      Spark copier's own per-file copy attempt still fails loudly (a
    #      missing source file throws, gets counted into the failed tally,
    #      and fails the table) rather than silently dropping data.
    #
    #   2) An earlier distcp-based grouping loop forked `tr` once per row
    #      (`echo ... | tr ...`, to sanitise a target directory into a
    #      filesystem-safe group-file name). At millions of rows, millions
    #      of forks dominates every other cost combined by orders of
    #      magnitude (fork+exec is milliseconds; a pure-bash substitution
    #      is microseconds). [5c] below uses bash's own
    #      `${var//pattern/repl}` instead -- identical result, zero forks.
    log_info "[5b] Verifying staged files (only the Puffin stats/ files rewrite_table_path is known to mis-stage)..."
    # See fix_puffin_stats_and_build_copy_list()'s own header comment for the
    # full upstream-bug writeup (Iceberg 1.9.0/1.9.1/1.9.2, fixed in 1.10.0)
    # and the PERFORMANCE AT SCALE rationale (two batched `-ls` calls total,
    # never a per-row check, regardless of file-list size).
    _t0=$(date +%s)
    # Deliberately NOT `local` -- see LOCAL_FILE_LIST's declaration above
    # for why (FAILED-run artifact tagging in replicate_one_table()'s
    # wrapper).
    COPY_LIST_LOCAL="${LOG_DIR}/${HIVE_DB}.${TABLE_NAME}.copy-list.$(date +%Y%m%d_%H%M%S).csv"
    fix_puffin_stats_and_build_copy_list \
      "${LOCAL_FILE_LIST}" \
      "hdfs://${DST_NAMESERVICE}${STAGING_DIR}/stats" \
      "${SRC_PREFIX}${TABLE_RELATIVE_PATH}/stats" \
      "${DST_PREFIX}" \
      "${SRC_PREFIX}" \
      "hdfs://${DST_NAMESERVICE}" \
      "${COPY_LIST_LOCAL}" || {
      log_error "Could not build the copy list for ${QUALIFIED_TABLE}; nothing was copied and the destination catalog was not touched."
      return 1
    }
    local _sp_rows="$PUFFIN_FIX_ROW_COUNT"
    _elapsed=$(( $(date +%s) - _t0 ))
    log_info "[5c] Normalized ${FILE_COUNT} file(s) into a copy list: ${_sp_rows} row(s) (in $(format_duration "$_elapsed"))."

    if [[ "$_sp_rows" -eq 0 ]]; then
      log_info "No files left to copy after normalization (destination already up to date)."
    else
      run_copy_engine \
        "${COPY_LIST_LOCAL}" \
        "hdfs://${DST_NAMESERVICE}${STAGING_DIR}/copy-list/${COPY_LIST_LOCAL##*/}" \
        "${QUALIFIED_TABLE}" \
        "${_sp_rows}" || return 1
    fi
  fi
  log_info "STEP 5 total: $(format_duration "$(( $(date +%s) - _S5_START ))")"
  log_line ""

  ########################################
  # [6/8] Register (bootstrap / force-reseed) or refresh (incremental) the
  # destination catalog.
  #
  # register_table calls Catalog.registerTable(), which throws
  # AlreadyExistsException if the destination table is already registered
  # (per org.apache.iceberg.hive.HiveCatalog#registerTable: "Throw an
  # exception if this table already exists in the catalog."). So
  # register_table only ever runs against a NOT-yet-existing destination
  # table; every other run re-points the existing table's metadata_location
  # via ALTER TABLE ... SET TBLPROPERTIES instead.
  #
  # FORCE_FULL_REWRITE (--rebuild-dst-table-from-source) CANNOT use that ALTER
  # TABLE repoint, even though the destination table already exists: Hive's
  # own Iceberg storage handler (HiveIcebergMetaHook.
  # assertNotCrossTableMetadataLocationChange, called from every
  # ALTER TABLE ... SET TBLPROPERTIES('metadata_location'=...) via
  # doPreAlterTable/preAlterTable) unconditionally compares the CURRENT
  # table's live table-uuid (embedded in its metadata.json) against the
  # NEW metadata_location's table-uuid, and throws
  # "UnsupportedOperationException: Cannot change iceberg table ... metadata
  # location pointing to another table's metadata" the instant they differ
  # -- which they always will here, since FORCE_FULL_REWRITE exists
  # precisely for the case where destination's data is a genuinely
  # different table lineage than source's. There is no config flag or
  # override that bypasses this specific UUID check (only a separate,
  # unrelated stale-metadata-refresh flag exists, and it does not touch
  # this assertion) -- this is a hard invariant in Hive's metastore hook,
  # not a bug workaround. CALL system.register_table(), on the other hand,
  # registers directly against the catalog with no UUID/ALTER involvement
  # at all, so it has no such restriction -- but it requires the
  # destination table to NOT already be registered.
  #
  # The only way to attach the existing table NAME to source's completely
  # different metadata lineage is therefore: rename the existing
  # destination table out of the way first (a pure Metastore operation --
  # no data movement, no purge involved at all, since RENAME TO never
  # drops anything), freeing the original name, then register_table fresh
  # against the newly-written metadata under that freed name. The renamed
  # table remains a normal, fully-queryable Iceberg table under its backup
  # name -- a deliberate backup, not an incidental side effect -- and is
  # never dropped automatically by this script.
  ########################################

  # register_bootstrap_fixups() is now defined once, unconditionally, near
  # the top of this function -- see its own comment there for why (it used
  # to be nested here, which meant it was undefined whenever the
  # SAME-NAMESERVICE COLLISION branch of STEP 6 tried to call it).

  if [[ "$FORCE_FULL_REWRITE" == "true" ]]; then
    log_stage 6 "--rebuild-dst-table-from-source: backing up and re-registering destination catalog entry..."
    log_info "(ALTER TABLE ... SET TBLPROPERTIES('metadata_location'=...) cannot cross a table-uuid boundary --"
    log_info " Hive's Iceberg storage handler unconditionally rejects that. Re-registering fresh instead.)"

    # Back up the existing destination table by RENAMING it, rather than
    # dropping it outright: a rename is a Metastore-only operation (no data
    # movement, no purge concerns at all -- the table stays fully live and
    # queryable under its new name, still pointing at its own old
    # metadata_location/lineage untouched). This is strictly safer than a
    # disarm-purge-then-DROP sequence: even if the purge-disarm ALTER TABLE
    # were somehow skipped or failed, a bare DROP is one command away from
    # destroying data, whereas RENAME TO can never lose data by construction.
    # It does leave an extra table object behind (cleanup is a manual,
    # deliberate follow-up step, not something this script does automatically),
    # but that is the tradeoff for a backup with zero risk of accidental loss.
    local BACKUP_TABLE_NAME
    BACKUP_TABLE_NAME="${TABLE_NAME}_pre_rebuild_$(date +%Y%m%d_%H%M%S)"
    local BACKUP_QUALIFIED_TABLE="${HIVE_DB}.${BACKUP_TABLE_NAME}"
    log_info "Backing up destination's current (non-matching) table by renaming it to ${BACKUP_QUALIFIED_TABLE}"
    log_info "(still fully live/queryable under that name; nothing is deleted or purged)..."
    local RENAME_SQL="ALTER TABLE ${HIVE_TABLE_REF} RENAME TO $(hive_table_ref "${BACKUP_QUALIFIED_TABLE}");"
    log_info "Executing: ${RENAME_SQL}"
    run_beeline_statement "${DST_JDBC_URL}" "${RENAME_SQL}" || {
      log_error "Backup rename failed for ${QUALIFIED_TABLE} -> ${BACKUP_QUALIFIED_TABLE}; destination catalog"
      log_error "entry still points at its old, non-matching lineage under its original name. Nothing else"
      log_error "was changed -- safe to investigate and re-run."
      return 1
    }
    log_info "Backed up: ${BACKUP_QUALIFIED_TABLE} now holds destination's PRIOR (pre-rebuild) data/lineage."
    log_info "It is a normal, fully-queryable Iceberg table -- drop it by hand later once you've confirmed it's"
    log_info "no longer needed; this script never deletes it automatically."
    log_warn "CAUTION before dropping ${BACKUP_QUALIFIED_TABLE}: the rename did not move anything, so the backup"
    log_warn "and the re-registered ${QUALIFIED_TABLE} share ONE table directory (${DST_TABLE_LOCATION}),"
    log_warn "and files with the same name in both lineages are the same physical files. A DROP that purges"
    log_warn "data (DROP ... PURGE, or a table with external.table.purge=true) can delete files"
    log_warn "${QUALIFIED_TABLE} still needs. Disarm purge on the backup first, then drop it:"
    log_warn "  ALTER TABLE ${BACKUP_QUALIFIED_TABLE} SET TBLPROPERTIES ('external.table.purge'='false');"
    log_warn "  DROP TABLE ${BACKUP_QUALIFIED_TABLE};"

    log_info "Registering destination catalog against source's freshly-replicated metadata (register_table)..."
    local REGISTER_SQL="CALL ${SPARK_CATALOG}.system.register_table(
    table => '${QUALIFIED_TABLE}',
    metadata_file => '${DST_METADATA_LOCATION}'
  );"
    log_info "Executing: ${REGISTER_SQL}"
    log_line ""
    run_register_table "${REGISTER_SQL}" || {
      log_error "register_table failed for ${QUALIFIED_TABLE} after the backup rename. The destination table"
      log_error "no longer exists under its original name -- its prior data/lineage is safe under"
      log_error "${BACKUP_QUALIFIED_TABLE} (see above), and the freshly-replicated files are on HDFS at"
      log_error "${DST_TABLE_LOCATION}; retry register_table by hand, rename the backup back if needed, or"
      log_error "re-run this script."
      return 1
    }

    register_bootstrap_fixups || return 1
  elif [[ "$BOOTSTRAP" == "true" ]]; then
    log_stage 6 "Registering destination catalog (register_table)..."

    local REGISTER_SQL="CALL ${SPARK_CATALOG}.system.register_table(
    table => '${QUALIFIED_TABLE}',
    metadata_file => '${DST_METADATA_LOCATION}'
  );"

    log_info "Executing: ${REGISTER_SQL}"
    log_line ""
    run_register_table "${REGISTER_SQL}" || {
      log_error "register_table failed for ${QUALIFIED_TABLE}."
      return 1
    }

    register_bootstrap_fixups || return 1
  else
    log_stage 6 "Refreshing destination catalog to latest metadata_location..."

    local REPOINT_SQL="ALTER TABLE ${HIVE_TABLE_REF} SET TBLPROPERTIES (
    'metadata_location' = '${DST_METADATA_LOCATION}'
  );"

    log_info "Executing: ${REPOINT_SQL}"
    log_line ""
    run_beeline_statement "${DST_JDBC_URL}" "${REPOINT_SQL}" || {
      log_error "metadata_location re-point failed for ${QUALIFIED_TABLE}."
      return 1
    }
  fi
  fi
  log_line ""

  ########################################
  # [7/8] Validate the destination and write the checkpoint, but only on
  # success.
  ########################################
  log_stage 7 "Validating destination table and writing checkpoint..."
  log_line ""

  # The destination is read first: its state decides whether source needs
  # to be read again at all (see STEP7_EXACT_CASE below).
  local DST_TBLPROPERTIES_FINAL DST_SNAPSHOT_ID DST_METADATA_LOCATION_FINAL
  DST_TBLPROPERTIES_FINAL=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || true

  # Hive-engine fixups deferred from STEP 6 (REGISTER_HIVE_ENGINE_ENABLED=true,
  # see register_bootstrap_fixups): confirm the registration wrote
  # storage_handler, and apply the ALTERs here if it did not. A failure
  # leaves no checkpoint, so the next run finds the registered table and
  # completes it through repair_unfinished_registration.
  if [[ "$HIVE_FIXUPS_DEFERRED" == "true" ]]; then
    if dst_missing_hive_storage_handler "$DST_TBLPROPERTIES_FINAL"; then
      log_warn "register_table did not set storage_handler on ${QUALIFIED_TABLE} although REGISTER_HIVE_ENGINE_ENABLED=true."
      log_warn "Applying the Hive-engine fixup ALTERs instead. If this happens for every table, set"
      log_warn "REGISTER_HIVE_ENGINE_ENABLED=false for this cluster pair: the setting has no effect here."
      apply_hive_engine_fixups || return 1
      DST_TBLPROPERTIES_FINAL=$(fetch_tblproperties "${DST_JDBC_URL}" "${QUALIFIED_TABLE}") || true
    elif [[ -n "$(parse_tblproperty "$DST_TBLPROPERTIES_FINAL" storage_handler)" ]]; then
      log_info "register_table set the Hive storage_handler itself; no fixup ALTERs were needed."
    fi
  fi
  DST_SNAPSHOT_ID=$(parse_tblproperty "$DST_TBLPROPERTIES_FINAL" current-snapshot-id)
  DST_METADATA_LOCATION_FINAL=$(parse_tblproperty "$DST_TBLPROPERTIES_FINAL" metadata_location)

  # STEP7_EXACT_CASE: the version rewrite_table_path replicated is the very
  # version STEP 1 read, and the destination now sits on that version's
  # snapshot. Everything STEP 7 needs is then already known -- the checkpoint
  # is STEP 1's metadata_location -- so source is not read again. In every
  # other situation (source moved between STEP 1 and STEP 4, no rewrite ran
  # this run, an empty table) source's current properties are read here.
  local STEP7_EXACT_CASE=false
  if [[ -n "$DST_SNAPSHOT_ID" && -n "$REPLICATED_SRC_METADATA_NAME" \
        && "${SRC_METADATA_LOCATION##*/}" == "$REPLICATED_SRC_METADATA_NAME" \
        && -n "$SRC_SNAPSHOT_ID_STEP1" && "$SRC_SNAPSHOT_ID_STEP1" == "$DST_SNAPSHOT_ID" ]]; then
    STEP7_EXACT_CASE=true
  fi

  # STEP7_NOOP_VERIFIED: the same idea for a run that replicated nothing.
  # SKIP_REPLICATION means the checkpoint IS the version STEP 1 read, so when
  # the destination sits on that version's snapshot the table is verified
  # and the checkpoint stays as it is; source is not read again. Whatever
  # source commits after STEP 1 is left for the next run, with the
  # checkpoint untouched. If the two snapshot ids differ (the destination
  # was changed, or is behind), this does not apply and the full check
  # below runs, re-reading source.
  local STEP7_NOOP_VERIFIED=false
  if [[ "$SKIP_REPLICATION" == "true" && -n "$CHECKPOINT_METADATA" && -n "$DST_SNAPSHOT_ID" \
        && -n "$SRC_SNAPSHOT_ID_STEP1" && "$SRC_SNAPSHOT_ID_STEP1" == "$DST_SNAPSHOT_ID" ]]; then
    STEP7_NOOP_VERIFIED=true
  fi

  local SRC_TBLPROPERTIES_FINAL="" SRC_SNAPSHOT_ID="" SRC_METADATA_LOCATION_FINAL=""
  if [[ "$STEP7_NOOP_VERIFIED" == "true" ]]; then
    SRC_SNAPSHOT_ID="$SRC_SNAPSHOT_ID_STEP1"
    log_info "Source snapshot-id (unchanged)  : ${SRC_SNAPSHOT_ID}  (version ${SRC_METADATA_LOCATION##*/}, as read in STEP 1)"
  elif [[ "$STEP7_EXACT_CASE" == "true" ]]; then
    SRC_SNAPSHOT_ID="$SRC_SNAPSHOT_ID_STEP1"
    log_info "Source snapshot-id (replicated) : ${SRC_SNAPSHOT_ID}  (version ${REPLICATED_SRC_METADATA_NAME}, as read in STEP 1)"
  else
    SRC_TBLPROPERTIES_FINAL=$(fetch_tblproperties "${SRC_JDBC_URL}" "${QUALIFIED_TABLE}") || true
    SRC_SNAPSHOT_ID=$(parse_tblproperty "$SRC_TBLPROPERTIES_FINAL" current-snapshot-id)
    SRC_METADATA_LOCATION_FINAL=$(parse_tblproperty "$SRC_TBLPROPERTIES_FINAL" metadata_location)
    log_info "Source current-snapshot-id      : ${SRC_SNAPSHOT_ID:-<unset>}"
  fi
  log_info "Destination current-snapshot-id : ${DST_SNAPSHOT_ID:-<unset>}"

  # WHY THIS IS NOT "SRC_SNAPSHOT_ID == DST_SNAPSHOT_ID".
  #
  # That was the original check, and it is wrong for any table that is still
  # being written while the run is in flight. What this run replicated is
  # source's state as of STEP 4 (when rewrite_table_path resolved the table);
  # SRC_SNAPSHOT_ID here is re-read minutes -- or, for a large table, HOURS --
  # later. Every commit source makes in that window moves its current snapshot
  # forward while the destination correctly stays at the version that was
  # actually copied, so the two ids differ by construction. Observed exactly
  # that in production: destination at 2577854398884232156 (the id
  # register_table had returned two minutes earlier), source already at
  # 4899285375324799321, and a completely correct 3642-file run reported as a
  # FAILURE. On a continuously-ingested table the old check could essentially
  # never pass.
  #
  # The right question is not "has source stopped moving?" but "did the
  # destination land on a REAL point in source's history?" -- which is what
  # source's own metadata_log_entries answers, and which stays true no matter
  # how far source has advanced since.
  #
  # The equality case is kept as a fast path, not because it is a stronger
  # check, but because it is FREE: when the ids already agree, source's current
  # metadata_location is by definition the version that was replicated, so no
  # extra spark-sql launch is needed. A quiet table therefore costs exactly what
  # it did before; only a table that genuinely moved pays for the lookup.
  #
  # EMPTY TABLE. A table that has never been written has no current snapshot,
  # so neither side reports a current-snapshot-id and there is nothing for
  # the snapshot comparison below to compare. That is a correct replication
  # of an empty table, not a failed one, and is accepted when:
  #   - the destination table is registered (it reports a metadata_location)
  #     and reports no snapshot; and
  #   - source has no snapshot either -- now, or in the version this run
  #     replicated (source may take its first commit while the run is in
  #     flight); and
  #   - the two sides' table uuids agree, where both report one.
  # A destination with no snapshot against a source that had one is still
  # the failure it always was.
  local EMPTY_TABLE_VERIFIED=false
  if [[ -z "$DST_SNAPSHOT_ID" ]]; then
    local SRC_UUID_FINAL DST_UUID_FINAL EMPTY_SRC_CONFIRMED=false
    SRC_UUID_FINAL=$(parse_tblproperty "$SRC_TBLPROPERTIES_FINAL" uuid)
    DST_UUID_FINAL=$(parse_tblproperty "$DST_TBLPROPERTIES_FINAL" uuid)
    if [[ -n "$SRC_METADATA_LOCATION_FINAL" && -z "$SRC_SNAPSHOT_ID" ]]; then
      EMPTY_SRC_CONFIRMED=true
    elif [[ -n "$REPLICATED_SRC_METADATA_NAME" && "${SRC_METADATA_LOCATION##*/}" == "$REPLICATED_SRC_METADATA_NAME" \
            && -z "$SRC_SNAPSHOT_ID_STEP1" ]]; then
      EMPTY_SRC_CONFIRMED=true
    fi
    if [[ -n "$DST_METADATA_LOCATION_FINAL" && "$EMPTY_SRC_CONFIRMED" == "true" ]] \
       && [[ -z "$SRC_UUID_FINAL" || -z "$DST_UUID_FINAL" || "$SRC_UUID_FINAL" == "$DST_UUID_FINAL" ]]; then
      EMPTY_TABLE_VERIFIED=true
    else
      _restore_quiet_skip_fd
      log_error "Destination table ${QUALIFIED_TABLE} has no 'current-snapshot-id' after replication."
      log_error "The catalog repoint/registration did not take effect -- nothing was verified."
      log_info "The checkpoint has NOT been advanced; the next run will safely retry this delta."
      return 1
    fi
  fi

  # The checkpoint MUST be the SOURCE table's own current metadata.json,
  # never the destination's rewritten copy. rewrite_table_path's own
  # start_version validation (RewriteTablePathSparkAction.validateVersion,
  # called every incremental run) resolves `table` via the catalog
  # configured from SRC_METASTORE_URI -- i.e. it is always the SOURCE
  # table, regardless of which side's checkpoint value is passed in. It
  # checks the passed-in start_version's bare filename (via
  # RewriteTablePathUtil.fileName(), so scheme/prefix differences alone are
  # not the issue) against tableMetadata.previousFiles(), the SOURCE
  # table's own metadata log. rewrite_table_path always writes the
  # destination's rewritten metadata.json under a brand-new UUID that is
  # never appended to source's metadata log, so a destination-side
  # filename can never be found there -- this fails deterministically with
  # "Cannot find provided version file <dst-path> in metadata log"
  # whenever the wrong side's path is persisted as the anchor, regardless
  # of whether the two tables' data actually shares any lineage.
  # It must ALSO be the version this run actually replicated, not whatever
  # source happens to be at right now. Writing source's LIVE metadata_location
  # as the checkpoint would be silent DR data loss on a busy table: the next run
  # passes it as start_version, and every snapshot source committed between
  # STEP 4 and STEP 7 -- files that were never copied -- falls into the gap
  # between the checkpoint and that start point and is never replicated at all.
  # On a quiet table the two are identical, which is exactly why this went
  # unnoticed until a continuously-written table exposed it.
  #
  # EXACT CASE FIRST. When the version rewrite_table_path replicated
  # (REPLICATED_SRC_METADATA_NAME) is the very version STEP 1 read, and the
  # destination now sits on that version's snapshot, the checkpoint is STEP
  # 1's metadata_location -- known exactly, with no lookup and no dependence
  # on what source has done since. This matters in two ways the branches
  # below cannot provide:
  #   - A metadata-only commit on source between STEP 4 and here (a schema or
  #     property change) leaves the snapshot ids equal. Checkpointing
  #     source's live metadata_location would then put that never-copied
  #     version behind the anchor, and the change would not reach the
  #     destination until source's next commit.
  #   - A data commit in the same window needs no spark-sql lookup: the
  #     replicated version is already known.
  # Source is not re-read for this case at all (STEP7_EXACT_CASE, decided at
  # the top of this step), so whatever source has committed since STEP 4 is
  # neither needed nor reported here; the next run picks it up.
  # Any other situation (source moved between STEP 1 and STEP 4, or no
  # rewrite ran this run) falls through to the two branches below.
  # VERIFIED_NOTE: what this step established, in one phrase, for the STEP 8
  # summary. STEP 7's own lines are not shown for an unchanged table under
  # QUIET_SKIP_LOG, and the summary is the one place every table reports.
  local CHECKPOINT_VALUE="" VERIFIED_NOTE=""
  if [[ "$EMPTY_TABLE_VERIFIED" == "true" ]]; then
    # No snapshot to anchor on, so the checkpoint is the replicated version
    # where that is known to be source's current one, and otherwise STEP 1's
    # version -- which is at or before whatever was replicated, and an
    # earlier anchor only widens the next run's delta. A no-op run keeps the
    # checkpoint it already has.
    if [[ -n "$REPLICATED_SRC_METADATA_NAME" && "${SRC_METADATA_LOCATION_FINAL##*/}" == "$REPLICATED_SRC_METADATA_NAME" ]]; then
      CHECKPOINT_VALUE="$SRC_METADATA_LOCATION_FINAL"
    elif [[ "$SKIP_REPLICATION" == "true" && -n "$CHECKPOINT_METADATA" ]]; then
      CHECKPOINT_VALUE="$CHECKPOINT_METADATA"
    else
      CHECKPOINT_VALUE="$SRC_METADATA_LOCATION"
    fi
    log_info "Empty table: neither side has a snapshot yet -- destination is registered and matches source."
    VERIFIED_NOTE="empty table -- neither source nor destination has a snapshot yet"
  elif [[ "$STEP7_NOOP_VERIFIED" == "true" ]]; then
    CHECKPOINT_VALUE="$CHECKPOINT_METADATA"
    log_info "Snapshot ids match -- source is unchanged since the checkpoint and the destination sits on the same snapshot."
    VERIFIED_NOTE="source and destination both at snapshot ${DST_SNAPSHOT_ID}"
  elif [[ "$STEP7_EXACT_CASE" == "true" ]]; then
    CHECKPOINT_VALUE="$SRC_METADATA_LOCATION"
    log_info "Snapshot ids match -- destination sits at the snapshot of the source version this run replicated (${REPLICATED_SRC_METADATA_NAME})."
    VERIFIED_NOTE="destination at snapshot ${DST_SNAPSHOT_ID}, the snapshot of the replicated source version ${REPLICATED_SRC_METADATA_NAME}"
  elif [[ -n "$SRC_SNAPSHOT_ID" && "$SRC_SNAPSHOT_ID" == "$DST_SNAPSHOT_ID" ]]; then
    # Source has not moved since the rewrite, so its current metadata_location
    # IS the replicated version. No extra query needed.
    CHECKPOINT_VALUE="$SRC_METADATA_LOCATION_FINAL"
    if [[ -z "$CHECKPOINT_VALUE" ]]; then
      _restore_quiet_skip_fd
      log_error "Could not read source metadata_location after replication for ${QUALIFIED_TABLE}; cannot write checkpoint."
      log_info "The checkpoint has NOT been advanced; the next run will safely retry this delta."
      return 1
    fi
    log_info "Snapshot ids match -- replication verified against source's current state."
    VERIFIED_NOTE="source and destination both at snapshot ${DST_SNAPSHOT_ID}"
  else
    # Source advanced while this run was in flight. That is the NORMAL state of
    # a continuously-ingested table, not an error -- but it does mean the
    # checkpoint has to name the version that was replicated, which is resolved
    # from the destination's own snapshot-id against SOURCE's metadata log (the
    # same lookup auto-seed uses). That query doubles as the real correctness
    # check: a destination snapshot that does NOT appear in source's history did
    # not come from source, and must not be checkpointed.
    log_info "Source has advanced past what this run replicated (expected on a continuously-written table)."
    log_info "Verifying destination's snapshot-id is a real point in SOURCE's own history..."
    CHECKPOINT_VALUE=$(resolve_src_metadata_json_for_snapshot "${QUALIFIED_TABLE}" "${DST_SNAPSHOT_ID}") || {
      _restore_quiet_skip_fd
      log_error "Could not query source's metadata_log_entries for ${QUALIFIED_TABLE}; cannot verify or checkpoint."
      log_info "The checkpoint has NOT been advanced; the next run will safely retry this delta."
      return 1
    }
    if [[ -z "$CHECKPOINT_VALUE" ]]; then
      _restore_quiet_skip_fd
      log_error "Destination's current-snapshot-id (${DST_SNAPSHOT_ID}) was NOT found in source's own metadata"
      log_error "log for ${QUALIFIED_TABLE}. The destination is therefore not at any real point in source's"
      log_error "history -- this is a genuine replication failure, not merely source having moved on."
      log_error "(If source expired that snapshot mid-run, re-running replicates from the last good"
      log_error "checkpoint; if it never came from source, see --rebuild-dst-table-from-source.)"
      log_info "The checkpoint has NOT been advanced; the next run will safely retry this delta."
      return 1
    fi
    log_info "Verified: destination sits at source's own snapshot ${DST_SNAPSHOT_ID} (source is now at"
    log_info "${SRC_SNAPSHOT_ID:-<unset>}). Everything source has gained since is replicated by the NEXT run."
    VERIFIED_NOTE="destination at source's snapshot ${DST_SNAPSHOT_ID}; source has since moved to ${SRC_SNAPSHOT_ID:-<unset>} (next run)"
  fi
  # An unchanged checkpoint is not rewritten. CHECKPOINT_METADATA is what
  # STEP 3 read back from (or itself wrote to) HDFS for this direction, so
  # when the value to store is identical there is nothing to record -- and
  # writing it anyway costs a `hadoop fs` launch per cluster on every no-op
  # table of every run.
  if [[ -n "$CHECKPOINT_METADATA" && "$CHECKPOINT_VALUE" == "$CHECKPOINT_METADATA" ]]; then
    log_info "Checkpoint unchanged (${CHECKPOINT_VALUE}); not rewritten."
  else
    checkpoint_write "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE" "$CHECKPOINT_VALUE" || {
      _restore_quiet_skip_fd
      log_info "The checkpoint has NOT been advanced; the next run will safely retry this delta."
      return 1
    }
    log_info "Checkpoint advanced (source-side metadata.json, required for the next rewrite_table_path's start_version): ${CHECKPOINT_VALUE}"
  fi
  log_line ""

  # Prune this table's own file-list/copy-list CSVs (and their copier
  # companion files) in LOG_DIR, keeping only the KEEP_RUN_ARTIFACTS most
  # recent runs per artifact kind. These accumulate one set per run
  # (bootstrap or incremental, normal path or collision-mode hop A/B) with
  # no built-in cleanup otherwise. Only prune AFTER a successful run (this
  # point in the function), so a failed run's artifacts stay around for
  # debugging.
  #
  # COVERAGE: four CSV kinds are pruned, one pattern each --
  #   ${QUALIFIED_TABLE}.file-list.*.csv      (normal path, STEP 5a)
  #   ${QUALIFIED_TABLE}.copy-list.*.csv      (normal path, STEP 5c)
  #   ${QUALIFIED_TABLE}.hopA-file-list.*.csv (collision path, hop A -- this
  #                                            pattern's trailing "*" also
  #                                            matches its OWN derived
  #                                            "...hopA-file-list.<ts>.
  #                                            copy-list.csv" companion,
  #                                            since glob "*" matches
  #                                            "copy-list." too; no separate
  #                                            pattern is needed for it)
  #   ${QUALIFIED_TABLE}.hopB-file-list.*.csv (collision path, hop B; same
  #                                            copy-list-companion coverage)
  # An EARLIER version of this pruning only covered the first two patterns,
  # so every collision-mode run's own CSVs were never pruned at all --
  # fixed here by adding the hop A/B patterns.
  #
  # COPIER COMPANION FILES: run_spark_copier() writes a ".copier.scala"
  # script, a ".copier.result" file, and a ".copier.out" log next to
  # whichever CSV it was given as copy_list_local (COPY_LIST_LOCAL,
  # HOPA_COPY_LIST_LOCAL, or HOPB_COPY_LIST_LOCAL) -- identifiable by
  # "copy-list" appearing in the CSV's own filename. None of these three
  # were ever pruned before, even for the normal (non-collision) path --
  # only the CSV itself was. Deleted alongside their originating CSV below
  # (rm -f, so it is a harmless no-op for a CSV that was never actually
  # handed to run_spark_copier, e.g. a run with zero rows to copy).
  #
  # PRODUCTION SAFETY:
  #   - Opt-out via PRUNE_RUN_ARTIFACTS=false (env var, see top of script).
  #     Default is "true", but this deletes real files on a production box,
  #     so it must be possible to turn off entirely without editing the
  #     script.
  #   - QUALIFIED_TABLE is a hard-guard precondition: if it were ever empty
  #     (should be impossible, since it is built from HIVE_DB/TABLE_NAME at
  #     the top of this function, but a glob should never trust an
  #     unvalidated variable when the payload is `rm -f`), the find patterns
  #     below would degrade to "*.file-list.*.csv" etc. and match EVERY
  #     table's artifacts, not just this one. Refuse to prune rather than
  #     risk that.
  #   - -maxdepth 1 scopes the search to LOG_DIR itself, never descending
  #     into unrelated subdirectories a customer might keep there.
  #   - Only ever deletes files matching this table's own name pattern;
  #     never touches the checkpoint file itself or any other table's data.
  #   - "*.FAILED.csv" (see replicate_one_table()'s wrapper) is EXCLUDED
  #     from the candidate list entirely -- exempt from THIS keep-the-
  #     last-5 pruning, not merely kept among the most recent 5, so a
  #     genuinely failed run's artifacts outlast whichever 5 successful
  #     runs happen to follow it. They are removed by age instead (see
  #     prune_aged_log_files / LOG_RETENTION_DAYS). The plain "*" in the
  #     patterns below would otherwise still match a "...FAILED.csv" name.
  if [[ "${PRUNE_RUN_ARTIFACTS}" != "true" ]]; then
    log_info "Artifact pruning disabled (PRUNE_RUN_ARTIFACTS=${PRUNE_RUN_ARTIFACTS}); leaving all file-list/copy-list history for ${QUALIFIED_TABLE} in place."
  elif [[ -z "${QUALIFIED_TABLE}" ]]; then
    log_warn "QUALIFIED_TABLE is unexpectedly empty; refusing to prune LOG_DIR artifacts to avoid matching unrelated tables."
  else
    local KEEP_RUN_ARTIFACTS=5
    local -a _artifact_name_patterns=(
      "${QUALIFIED_TABLE}.file-list.*.csv"
      "${QUALIFIED_TABLE}.copy-list.*.csv"
      "${QUALIFIED_TABLE}.hopA-file-list.*.csv"
      "${QUALIFIED_TABLE}.hopB-file-list.*.csv"
    )
    local -a old_csvs=() _kind_old
    local _pattern
    for _pattern in "${_artifact_name_patterns[@]}"; do
      mapfile -t _kind_old < <(
        find "${LOG_DIR}" -maxdepth 1 -type f -name "${_pattern}" ! -name "*.FAILED.csv" 2>/dev/null \
          | sort -r | tail -n "+$((KEEP_RUN_ARTIFACTS + 1))"
      )
      old_csvs+=("${_kind_old[@]}")
    done
    local -a old_files=("${old_csvs[@]}")
    local _old_csv
    for _old_csv in "${old_csvs[@]}"; do
      case "$_old_csv" in
        *copy-list*.csv)
          old_files+=(
            "${_old_csv%.csv}.copier.scala"
            "${_old_csv%.csv}.copier.result"
            "${_old_csv%.csv}.copier.out"
          )
          ;;
      esac
    done
    if [[ ${#old_files[@]} -gt 0 ]]; then
      log_info "Pruning ${#old_csvs[@]} old CSV artifact(s) for ${QUALIFIED_TABLE} (plus copier companion files where"
      log_info "present, keeping last ${KEEP_RUN_ARTIFACTS} runs per artifact kind)..."
      rm -f -- "${old_files[@]}"
    fi
  fi

  ########################################
  # Clean up THIS table's own HDFS staging directory now that the run has
  # succeeded and the checkpoint has advanced -- nothing in it is needed
  # again: rewrite_table_path always writes fresh staged content on its
  # NEXT invocation rather than resuming from anything left behind, and the
  # per-table flock (see replicate_one_table()) guarantees no OTHER
  # invocation of this same table can be reading it concurrently. Gated on
  # the same PRUNE_RUN_ARTIFACTS switch as the LOG_DIR pruning above (one
  # on/off knob for "does this script clean up after itself"), and never
  # fatal to the table's own result if the delete itself fails -- the table
  # has ALREADY succeeded by this point; a leftover staging directory is
  # exactly the same harmless, purely cosmetic condition this script has
  # always left behind before this cleanup existed.
  #
  # SAME-NAMESERVICE COLLISION: hop A/B's own "-hopA"/"-hopB" suffixed
  # staging directories are what accumulate on this path (the plain
  # STAGING_DIR itself is never used directly in collision mode -- see the
  # hop A/B HOPA_STAGING_LOCATION/HOPB_STAGING_LOCATION declarations).
  # Addressed via the PLAIN shared name here, not the resolved host:port:
  # by this point in the function hop A/B's own isolated HA override has
  # already been restored to native (_collision_restore_ha_args, called
  # right after hop B's own retirement earlier), and on the destination the
  # shared name and the active NameNode's host:port are two addresses for
  # one filesystem, so the plain name reaches the same directories.
  ########################################
  # Skipped on a no-op run (SKIP_REPLICATION): nothing was staged, so the
  # delete would be one more `hadoop fs` launch per untouched table for no
  # effect. Anything a previous FAILED run left behind is removed by the
  # next run that actually replicates.
  if [[ "${PRUNE_RUN_ARTIFACTS}" == "true" && "$SKIP_REPLICATION" != "true" ]]; then
    local -a _staging_dirs_to_clean=()
    if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
      _staging_dirs_to_clean=(
        "hdfs://${DST_NAMESERVICE}${STAGING_DIR}-hopA"
        "hdfs://${DST_NAMESERVICE}${STAGING_DIR}-hopB"
      )
    else
      _staging_dirs_to_clean=("hdfs://${DST_NAMESERVICE}${STAGING_DIR}")
    fi
    local _staging_dir
    for _staging_dir in "${_staging_dirs_to_clean[@]}"; do
      run_as_hdfs hadoop fs "${HDFS_HA_ARGS[@]}" -rm -r -f -skipTrash "${_staging_dir}" >/dev/null 2>&1 || {
        log_warn "Could not delete staging directory ${_staging_dir} for ${QUALIFIED_TABLE} -- harmless leftover"
        log_warn "(the table's own replication already succeeded); delete it by hand once convenient."
      }
    done
  fi

  # Restore fd1 (see _restore_quiet_skip_fd's own declaration near
  # SKIP_REPLICATION above) BEFORE this table's one guaranteed-visible line
  # -- every table, quiet or not, still ends on this STEP 8 summary. A
  # no-op here if a STEP 7 failure path already restored it.
  _restore_quiet_skip_fd

  local _MODE_LABEL="Incremental"
  [[ "$BOOTSTRAP" == "true" ]] && _MODE_LABEL="Bootstrap"
  [[ "$REWRITE_REANCHORED" == "true" ]] && _MODE_LABEL="Incremental (auto-re-anchored at the destination's current snapshot)"
  [[ "$REWRITE_FULL_FALLBACK" == "true" ]] && _MODE_LABEL="Full rewrite (auto-recovered from an unusable incremental anchor), repointed normally"
  [[ "$EMPTY_DST_FULL_REWRITE" == "true" ]] && _MODE_LABEL="Full rewrite onto an existing empty destination, repointed normally"
  [[ "$FORCE_FULL_REWRITE" == "true" ]] && _MODE_LABEL="Rebuilt from source (full rewrite, re-registered)"
  [[ "$SKIP_REPLICATION" == "true" ]] && _MODE_LABEL="Up to date (source unchanged since last checkpoint)"
  log_stage 8 "${QUALIFIED_TABLE}: ${_MODE_LABEL} replication complete."
  log_info "Metadata Loc : $DST_METADATA_LOCATION_FINAL"
  [[ -n "$VERIFIED_NOTE" ]] && log_info "Verified     : ${VERIFIED_NOTE}"
  log_info "Checkpoint   : $(checkpoint_hdfs_path_for "$SRC_NAMESERVICE" "$HIVE_DB" "$TABLE_NAME" "$SRC_NAMESERVICE" "$DST_NAMESERVICE") (+ DST mirror)"

  # Copy statistics summary (if copy step ran)
  if [[ ${FILES_TO_COPY} -gt 0 || ${FILES_COPIED} -gt 0 ]]; then
    log_info "Files Copied : ${FILES_COPIED} of ${FILES_TO_COPY} (${FILES_SKIPPED} already present, ${FILES_FAILED} failed)"
  fi

  log_line "$SUBSEP"
  log_line ""
  return 0
}

########################################
# Loop over every table in TABLES_TO_REPLICATE (RESOLVED_TABLES minus any
# whose database failed to create above -- see FAILED_DBS). Continue-on-
# failure: one table's failure is recorded and reported at the end, but
# does not stop the remaining tables in this run. Bucket arrays and
# TABLE_DURATIONS were declared earlier, alongside FAILED_DBS, so the
# database-creation step could pre-populate FAILED_TABLES too.
#
# Guarded by a count check rather than bare-expanding
# "${TABLES_TO_REPLICATE[@]}": under this script's `set -u`, expanding an
# empty array bare (no every-element-failed-to-create-its-db edge case was
# previously reachable, since a database failure used to exit(1) before
# this loop was ever reached) throws "unbound variable" on bash < 4.4.
#
# PARALLELISM (PARALLEL_TABLES, default 1 = today's serial behavior). Each
# table is dispatched as its OWN background job running replicate_one_table
# in a subshell -- safe to run many of these at once because
# replicate_one_table() already flocks per table (see its own header
# comment); two DIFFERENT tables running concurrently were never contending
# for anything, lock or otherwise. What a background subshell CANNOT do is
# hand its result back to this parent shell's own SUCCEEDED_TABLES/
# TABLE_DURATIONS arrays (each job is a forked copy of this shell's state;
# any variable it sets is discarded when it exits) -- so each job instead
# writes one small "<rc> <elapsed>" result file into PARALLEL_RESULT_DIR,
# named after its own qualified table, and the parent reads every result
# file back into the bucket arrays only AFTER every job has finished. This
# is the exact same pattern run_spark_copier/run_spark_sql already use for
# getting a subprocess's outcome back to bash (a result FILE, not captured
# stdout) -- applied here across background bash jobs instead of spark-shell.
#
# Concurrency is capped at PARALLEL_TABLES via a simple counted `wait`: once
# PARALLEL_TABLES jobs are in flight, `wait -n` (bash 4.3+; this script
# already relies on bash 4+ features like namerefs) blocks for the next ONE
# job to finish before launching another, so at most PARALLEL_TABLES tables
# are ever replicating at the same instant.
#
# `wait -n` is always followed by `|| true` below. A table's own outcome
# never reaches `wait -n`'s return value -- the background job's last
# command is always the `printf > "$_result_file"` a few lines down, so
# under normal operation (including a normal replicate_one_table failure,
# caught by its own `|| _rc=$?`) the job exits 0 and `wait -n` returns 0.
# But an ABNORMAL job death -- OOM-killed, a crashed spark-shell/spark-sql
# JVM taking the subshell down with it, or the result-file printf itself
# failing (disk full/permission issue on PARALLEL_RESULT_DIR) -- makes the
# job exit non-zero, and `wait -n` then returns that same non-zero status.
# Under this script's `set -euo pipefail`, an unguarded `wait -n` returning
# non-zero would abort THIS script immediately, killing every other
# still-in-flight table's replication via the process-group kill semantics
# documented near the INT/TERM trap above -- exactly the "one table's
# problem blocks every other table" failure mode this whole parallel-tables
# feature, and the rest of the script's per-table isolation design, exists
# to avoid. `|| true` keeps a lost/crashed job from taking down the run;
# that job's own missing result file is still caught and bucketed as FAILED
# by the "no result file" check in the result-collection loop below.
########################################
PARALLEL_RESULT_DIR="${LOG_DIR}/.replicate_results.$$"
mkdir -p "$PARALLEL_RESULT_DIR"

_table_position=0
if [[ ${#TABLES_TO_REPLICATE[@]} -gt 0 ]]; then
  _running_jobs=0
  for _qualified in "${TABLES_TO_REPLICATE[@]}"; do
    _db="${_qualified%%.*}"
    _tbl="${_qualified#*.}"
    _table_position=$((_table_position + 1))
    # One result file per table, named from the sanitized qualified name so
    # it can never collide with another table's or contain a path
    # separator -- reused as-is from the checkpoint-filename sanitizer.
    _result_file="${PARALLEL_RESULT_DIR}/$(sanitize_for_filename "$_qualified")"
    (
      # Propagate interrupts into this background job -- see the matching
      # trap/comment in run_distcp_copier()'s own per-group background job
      # for the full explanation. This is the SAME bug class, at table
      # scope instead of per-distcp-group scope: this `&` job can run for
      # the entire duration of one table's replication (potentially hours),
      # and being a backgrounded job it is immune to a terminal's SIGINT by
      # default, exactly like the distcp case that motivated this fix.
      # Without this trap, the table's own per-table flock lock (acquired
      # deep inside replicate_one_table()) stays held by this now-orphaned
      # background job even after the top-level script has been Ctrl+C'd
      # and returned control to the terminal.
      trap 'printf "130 %s\n" "$(( $(date +%s) - _tbl_start ))" > "${_result_file}"; kill -TERM -- -$BASHPID 2>/dev/null; exit 130' INT TERM
      _tbl_start=$(date +%s)
      _rc=0
      # This table's first [ERROR] message lands in "<result file>.err"
      # (see TABLE_FIRST_ERROR_FILE); read back with the result below.
      TABLE_FIRST_ERROR_FILE="${_result_file}.err"
      replicate_one_table "$_db" "$_tbl" "$_table_position" "${#TABLES_TO_REPLICATE[@]}" || _rc=$?
      printf '%s %s\n' "$_rc" "$(( $(date +%s) - _tbl_start ))" > "${_result_file}"
    ) &
    _running_jobs=$((_running_jobs + 1))
    if [[ "$_running_jobs" -ge "$PARALLEL_TABLES" ]]; then
      wait -n || true
      _running_jobs=$((_running_jobs - 1))
    fi
  done
  # Drain whatever is still running after the last table was dispatched.
  # `|| true` for the same reason as the `wait -n || true` above: this
  # plain `wait` returns the exit status of the last job it waited for, and
  # under `set -e` a non-zero one here would abort the run after every
  # table has already finished, right before the result-collection loop
  # below gets to run -- pointless self-sabotage this late.
  wait || true

  for _qualified in "${TABLES_TO_REPLICATE[@]}"; do
    _result_file="${PARALLEL_RESULT_DIR}/$(sanitize_for_filename "$_qualified")"
    if [[ ! -f "$_result_file" ]]; then
      # A missing result file means the background subshell itself never
      # reached the printf (e.g. killed, or a bug in this dispatcher) --
      # treat as FAILED rather than silently dropping the table from every
      # bucket, which would make the run summary's own counts not add up
      # to TABLES_TO_REPLICATE.
      log_error "No result recorded for ${_qualified} (its background job did not report back) -- treating as FAILED."
      FAILED_TABLES+=("$_qualified")
      TABLE_FAILURE_REASON[$_qualified]="its background job did not report a result"
      continue
    fi
    read -r _rc _elapsed < "$_result_file"
    TABLE_DURATIONS[$_qualified]="$_elapsed"
    if [[ "$_rc" != "0" && "$_rc" != "2" && -s "${_result_file}.err" ]]; then
      IFS= read -r _reason < "${_result_file}.err" || true
      TABLE_FAILURE_REASON[$_qualified]="${_reason:-}"
    fi
    case "$_rc" in
      0) SUCCEEDED_TABLES+=("$_qualified") ;;
      2) SKIPPED_TABLES+=("$_qualified") ;;
      3) LOCKED_TABLES+=("$_qualified") ;;
      *) FAILED_TABLES+=("$_qualified") ;;
    esac
  done
fi
rm -rf "$PARALLEL_RESULT_DIR" 2>/dev/null || true

########################################
# prune_aged_log_files: age out this script's own files in LOG_DIR that no
# other cleanup ever touches (see LOG_RETENTION_DAYS):
#   - run logs: one per invocation, never pruned by the per-table artifact
#     cleanup in STEP 8;
#   - FAILED-run artifacts: "*.FAILED.csv" is deliberately exempt from the
#     keep-the-last-5 rule there so a failure's evidence outlives the next
#     few successes, and the copier's .copier.* files of a failed copy are
#     left for the same reason -- but a table that fails on every run would
#     otherwise add a full file list per run without limit.
# Age is by last modification time, and only files matching these exact
# name shapes directly inside LOG_DIR are considered (-maxdepth 1), so
# nothing else kept in that directory is ever touched. The current run's
# files are minutes old and cannot match. Skipped entirely when
# PRUNE_RUN_ARTIFACTS is not "true" or LOG_RETENTION_DAYS is 0.
########################################
prune_aged_log_files() {
  [[ "${PRUNE_RUN_ARTIFACTS}" == "true" && "$LOG_RETENTION_DAYS" -gt 0 ]] || return 0
  local -a _aged_match=(
    -maxdepth 1 -type f -mtime "+${LOG_RETENTION_DAYS}"
    '(' -name 'iceberg_bdr_run_*.log'
        -o -name '*.file-list.*.FAILED.csv'
        -o -name '*.copy-list.*.FAILED.csv'
        -o -name '*copy-list*.copier.scala'
        -o -name '*copy-list*.copier.result'
        -o -name '*copy-list*.copier.out' ')'
  )
  local _aged_count
  _aged_count=$(find "${LOG_DIR}" "${_aged_match[@]}" 2>/dev/null | wc -l | tr -d '[:space:]') || _aged_count=0
  if [[ "${_aged_count:-0}" -gt 0 ]]; then
    log_info "Removing ${_aged_count} run log / failed-run artifact file(s) older than ${LOG_RETENTION_DAYS} day(s) from ${LOG_DIR} (LOG_RETENTION_DAYS)."
    find "${LOG_DIR}" "${_aged_match[@]}" -exec rm -f -- {} + 2>/dev/null || true
  fi
  return 0
}
prune_aged_log_files

# Clean up the Iceberg-runtime-version probe cache (see
# probe_iceberg_runtime_version) now that every table in this run has had
# its chance to use it -- unconditional, so it runs regardless of whether
# any table actually needed it (a v2-only fleet never creates the file,
# and rm -f is a no-op then) or how the run as a whole turned out.
rm -f "${ICEBERG_RUNTIME_VERSION_CACHE_FILE}" 2>/dev/null || true
# Same cleanup for resolve_active_namenode_hostport()'s own cross-subshell
# cache file -- same "$$-scoped file under LOG_DIR" pattern as the runtime-
# version cache above, and previously had no matching cleanup at all: every
# SAME-NAMESERVICE COLLISION run left its own ".dst_active_nn_hostport.$$"
# file behind in LOG_DIR permanently. Harmless (a v2-only or non-collision
# fleet never creates the file, and rm -f is a no-op then), just an
# unbounded accumulation this closes.
rm -f "${DST_ACTIVE_NN_HOSTPORT_CACHE_FILE}" 2>/dev/null || true

########################################
# Run summary. Each outcome bucket is printed as its own header count line
# followed by one qualified-table-name-per-line list (instead of a single
# comma-run line), so a run touching dozens of tables stays scannable
# instead of wrapping into an unreadable wall of text.
########################################
log_line "$SEP"
if [[ ${#FAILED_TABLES[@]} -gt 0 || ${#LOCKED_TABLES[@]} -gt 0 || ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  log_line " Iceberg Table Replication Run Completed -- RESULT: FAILED"
else
  log_line " Iceberg Table Replication Run Completed -- RESULT: SUCCESS"
fi
log_line "$SEP"
log_line ""
log_info "Source         : $SRC_NAMESERVICE"
log_info "Destination    : $DST_NAMESERVICE"
log_info "Kerberos       : ${KERBEROS_ENABLED^^}"
if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
  log_info "Execution Mode : current user/ticket (Kerberos)"
else
  log_info "Execution Mode : sudo (${HDFS_USER}/${SPARK_USER})"
fi
log_line ""

print_table_bucket() {
  local level="$1" label="$2"
  shift 2
  # Drop empty-string entries: "${ARRAY[@]:-}" on a genuinely empty array
  # (under `set -u`) still expands to one empty-string element rather than
  # zero elements, which would otherwise inflate the count by one and print
  # a blank list line.
  local -a tables=()
  local t
  for t in "$@"; do
    [[ -n "$t" ]] && tables+=("$t")
  done
  # The level applies only to a NON-EMPTY bucket. "Failed : 0" is a healthy
  # result, and tagging it [ERROR] (or an empty Skipped/Locked bucket [WARN])
  # would put a severity line into the log of every clean run -- defeating
  # `grep '\[ERROR\]'` as a way to find runs that actually had a problem.
  local _show_reasons=false
  [[ "$level" != "info" ]] && _show_reasons=true
  if [[ ${#tables[@]} -eq 0 ]]; then
    level="info"
  fi
  case "$level" in
    error) log_error "${label} : ${#tables[@]}" ;;
    warn)  log_warn  "${label} : ${#tables[@]}" ;;
    *)     log_info  "${label} : ${#tables[@]}" ;;
  esac
  # Annotate each entry with that table's own wall time, so the slowest
  # tables in a large run are visible from the summary alone without
  # scrolling back to each table's stage breakdown. Capped at
  # RESOLVED_TABLES_LOG_LIMIT for the same reason table resolution's
  # "Included : ..." lines are -- at thousands of tables, one line each
  # here would make even the FAILED bucket (the one an operator most needs
  # to scan quickly) unreadable.
  local -i _printed=0
  for t in "${tables[@]}"; do
    if [[ $_printed -ge $RESOLVED_TABLES_LOG_LIMIT ]]; then
      log_line "$(printf '                    - ... and %d more (RESOLVED_TABLES_LOG_LIMIT=%d)' \
        "$(( ${#tables[@]} - _printed ))" "$RESOLVED_TABLES_LOG_LIMIT")"
      break
    fi
    log_line "$(printf '                    - %-56.56s %12s' \
      "$t" "$(format_duration "${TABLE_DURATIONS[$t]:-0}")")"
    # Why it is in this bucket: the table's first [ERROR] line (Failed and
    # Locked buckets only), cut to a readable length -- the full text and
    # everything after it is in the table's own section of the log.
    if [[ "$_show_reasons" == "true" && -n "${TABLE_FAILURE_REASON[$t]:-}" ]]; then
      log_line "$(printf '                        reason: %.220s' "${TABLE_FAILURE_REASON[$t]}")"
    fi
    _printed=$((_printed + 1))
  done
}

log_info "Tables resolved : ${#RESOLVED_TABLES[@]}"
print_table_bucket info  "Succeeded       " "${SUCCEEDED_TABLES[@]:-}"
print_table_bucket warn  "Skipped         " "${SKIPPED_TABLES[@]:-}"
print_table_bucket warn  "Locked (busy)   " "${LOCKED_TABLES[@]:-}"
print_table_bucket error "Failed          " "${FAILED_TABLES[@]:-}"
# INCLUDE_FILTERS rows that could not be used (FILTER_ERRORS: the run is
# FAILED because of them even if every table that WAS resolved succeeded)
# and rows that are usable but resolved to nothing (FILTER_WARNINGS). Shown
# here so a filter problem is visible in the summary and not only at the
# top of the log.
if [[ ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  log_error "Filter errors    : ${#FILTER_ERRORS[@]}  (tables behind these rows were NOT replicated)"
  for _f in "${FILTER_ERRORS[@]}"; do
    log_line "                    - ${_f}"
  done
fi
if [[ ${#FILTER_WARNINGS[@]} -gt 0 ]]; then
  log_warn "Filter warnings  : ${#FILTER_WARNINGS[@]}"
  for _f in "${FILTER_WARNINGS[@]}"; do
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

if [[ ${#FAILED_TABLES[@]} -gt 0 || ${#LOCKED_TABLES[@]} -gt 0 || ${#FILTER_ERRORS[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
