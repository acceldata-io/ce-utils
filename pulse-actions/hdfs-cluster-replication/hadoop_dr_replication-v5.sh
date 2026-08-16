#!/bin/bash
# -----------------------------------------------------------------------------
# Hadoop Disaster Recovery Continuous Replication Script
# Version: 4.2.0
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
#
#
# Description:
#   Pull-based HDFS disaster recovery replication script.
#   This script runs on the TARGET/DR cluster and pulls data from the SOURCE
#   (production) cluster using HDFS snapshots and incremental DistCp transfers.
#   YARN MapReduce jobs run on the target cluster only, keeping the source
#   cluster free from replication workload.
#
# Usage:
#   ./hadoop_dr_replication_4.2.0.sh \
#     "<SOURCE_NN_HOST:PORT>"   \
#     "<DEST_NN_HOST:PORT>"     \
#     "<DIR1,DIR2,...>"         \
#     "<SNAP_PREFIX>"           \
#     <SNAP_RETAIN>            \
#     "<HDFS_USER>"            \
#     "<DISTCP_USER>"          \
#     "<COPY_OPTS>"            \
#     "<YARN_QUEUE>"           \
#     "<AUTO_FULL_DISTCP>"     \
#     "<ROLLBACK_ON_FAILURE>"  \
#     "<KERBEROS_ENABLED>"     \
#     "<DISTCP_EXCLUDE_PATTERNS>" \
#     "<REPLICATION_MODE>"     \
#     "<LOG_PATH>"             \
#     "<REVERSE_DIFF_BOOTSTRAP>" \
#     "<HDFS_STATE_DIR>"
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
#                              Throughput / memory controls can be appended here:
#                                -m <N>            Max map tasks (parallelism). With "-strategy dynamic"
#                                                  this is the number of mappers splitting the chunks.
#                                -bandwidth <MBps> Throttle PER MAP. Effective network ceiling is
#                                                  roughly  N x MBps  (e.g. -m 20 -bandwidth 100 ~= 2000 MB/s).
#                                                  Tune -m and -bandwidth together.
#                                -Dmapreduce.map.memory.mb=<MB>        Mapper container memory.
#                                -Dmapreduce.map.java.opts=-Xmx<~80% of MB>m   Mapper JVM heap.
#                                                  Keep -Xmx < memory.mb (leave ~20% headroom) or YARN
#                                                  kills the container.
#                              Example value:
#                                "--strategy dynamic -direct -update -pugptx -skipcrccheck -m 20 -bandwidth 100"
#                              NOTE: the DistCp DRIVER/client heap is NOT a DistCp flag and cannot go here;
#                                    set it via the HADOOP_CLIENT_OPTS env var (see below) to avoid client OOM
#                                    while building the copy listing / running -diff.
#   9) YARN_QUEUE           - YARN queue name for DistCp jobs (default: "default")
#   10) AUTO_FULL_DISTCP    - Auto-run full DistCp on initial baseline (optional, default: "no")
#                              Values: "yes" or "no"
#   11) ROLLBACK_ON_FAILURE - Enable automatic rollback on snapshot-modified errors (optional, default: "no")
#                              Values: "yes" or "no"
#   12) KERBEROS_ENABLED     - Explicit Kerberos mode (REQUIRED)
#                              Values: "yes" (Kerberos enabled) or "no" (Kerberos disabled / sudo mode)
#                              This script does NOT auto-detect Kerberos.
#                              Must be provided via CLI argument or KERBEROS_ENABLED env var.
#   13) DISTCP_EXCLUDE_PATTERNS - DistCp path-exclusion regex pattern(s) (optional).
#                              Pass the regex pattern(s) THEMSELVES, inline, comma-separated
#                              -- NOT a file path. The script generates and manages the
#                              actual DistCp -filters file itself (job-keyed, idempotent;
#                              see DISTCP_EXCLUDE_DIR notes below), so there is nothing for
#                              the operator to pre-create:
#                                empty/omitted -> filtering DISABLED
#                                non-empty value -> filtering ENABLED using these pattern(s)
#                              Multiple comma-separated patterns = multiple exclude rules
#                              (each is ORed - a path matching ANY pattern is excluded).
#                              Each pattern is validated at startup and the run fails fast with the
#                              offending pattern if it does not compile as a regex.
#                              Example value:
#                                ".*dir4/sub2.*,.*\.tmp$,.*/staging/.*"
#   14) REPLICATION_MODE      - Replication direction mode (optional, default: "pull")
#                              Values: "pull" or "push"
#                              "pull" = YARN runs on DR/target cluster, source has no compute overhead
#                              "push" = YARN runs on source/production cluster
#   15) LOG_PATH            - Path to log file (default: /var/log/hadoop-dr-replicate.log)
#   16) REVERSE_DIFF_BOOTSTRAP - Attempt incremental reverse-diff bootstrap on a detected
#                              failover/failback direction reversal (optional, default: "no")
#                              Values: "yes" or "no". Also settable via the
#                              REVERSE_DIFF_BOOTSTRAP environment variable (used as fallback
#                              when this argument is omitted/empty). See Notes below.
#   17) HDFS_STATE_DIR      - HDFS-mirrored directory for cross-node DR state (optional,
#                              default: "/tmp/pulse_replication_action")
#                              Also settable via the HDFS_STATE_DIR environment variable
#                              (used as fallback when this argument is omitted/empty).
#                              See Environment Variables section below for full rationale.
#
# Notes:
#   - AUTO_FULL_DISTCP controls whether full DistCp runs automatically on initial run.
#     Can be set via: 10th argument, environment variable, or defaults to "no".
#     WARNING: For large datasets, DistCp can take significant time to complete.
#   - ROLLBACK_ON_FAILURE controls automatic rollback on snapshot-modified errors.
#     Can be set via: 11th argument, environment variable, or defaults to "no".
#   - DIR_BOOTSTRAP_MODE is HARDCODED to "yes" (auto-bootstrap missing destination
#     directories). It is NOT a CLI argument and NOT an environment variable --
#     there is no override. Missing destination directories are always created
#     automatically with the same owner/permissions as the source directory.
#   - Kerberos mode is explicit and mandatory. The script does not auto-detect Kerberos.
#     Operators must specify the mode using the 12th argument or the KERBEROS_ENABLED
#     environment variable to ensure deterministic behavior.
#   - REVERSE_DIFF_BOOTSTRAP controls whether a detected direction reversal (failover/failback)
#     attempts an incremental reverse-diff bootstrap instead of a full baseline re-copy.
#     Can be set via: 16th argument, environment variable, or defaults to "no".
#     Requires SNAP_PREFIX to be a FIXED identity for the replicated pair (not rotated across
#     failover), so snapshot indices keep incrementing across role swaps.
#   - LIVE-SNAPSHOT-DERIVED DIRECTION DETECTION (applies regardless of REVERSE_DIFF_BOOTSTRAP):
#     replication direction (forward continuation / reversed / split-brain) is derived FRESH,
#     every run, from live "hdfs dfs -ls <dir>/.snapshot" listings on BOTH clusters (see
#     derive_direction_state) -- it is never read from a cached label. State files at
#     /var/tmp/dr-last-snap-<sanitized_dir>.txt are written as a SINGLE line (the last common
#     snapshot name only) and serve ONLY as an optimistic performance-hint cache to skip the
#     full live listing on the common case where nothing changed (see
#     verify_cached_snap_fast_path); the hint is always re-verified live before being trusted,
#     and a missing/stale/absent hint never causes an incorrect direction verdict -- only a
#     slower run that falls through to the full live listing-and-intersection algorithm. Any
#     external tooling that reads this file should read only line 1 (`head -n 1`); older 2-line
#     files (snapshot name + a now-deprecated recorded-source-cluster line) are read the same
#     way (only line 1 is ever consulted) and self-migrate to the 1-line format on their next
#     write. Pre-existing state files at the old path
#     (/var/tmp/dr-last-snap-<sanitized_dir>-<SNAP_PREFIX>.txt, used before the state-file-path
#     format change) are still recognized as a fallback so already-replicating directories are
#     not mistaken for brand-new ones.
#   - HDFS STATE MIRROR (see HDFS_STATE_DIR env var below): in addition to the
#     local state file described above, the same 1-line content is mirrored to
#     HDFS on both clusters after every successful state write, to support
#     failover invocations from a node that has never run this script before.
#     This mirror write is best-effort/non-fatal (see HDFS_STATE_DIR docs) and is
#     purely a performance-hint cache (see above) -- it is never the sole basis
#     for a direction/safety decision.
#     IMPORTANT: forcing a full re-baseline by deleting the state file now
#     requires clearing the HDFS mirror copies too, not just the local file --
#     not because direction safety depends on it (it doesn't: direction is
#     always derived live), but because a stale local/mirror hint would still
#     cause resolve_state_file_and_check_new() to report an already-replicating
#     directory as not brand-new, preventing Stage 3 from re-baselining it. See
#     the operator guidance printed at the relevant failure points (direction
#     reversal, split-brain, reverse-diff-bootstrap divergent writes) for the
#     exact commands.
#     AND clearing all three copies is itself no longer sufficient to force a
#     re-baseline: Stage 3 confirms the "brand new" verdict against LIVE snapshot
#     listings on both clusters before creating a baseline (see
#     confirm_brand_new_against_live_snapshots), because state-cache absence is
#     NOT evidence that a directory was never replicated -- treating it as such
#     could re-baseline an already-replicating directory on top of live data and
#     silently gap DR. With state cleared but snapshots still present, Stage 3
#     REHYDRATES state from the live snapshots instead of baselining. To force a
#     real re-baseline, either delete every ${SNAP_PREFIX}_* snapshot for the
#     directory on BOTH clusters (preferred), or set FORCE_REBASELINE=yes to
#     override the live confirmation explicitly (see that env var below).
#
# Environment Variables (Optional):
#   - REVERSE_DIFF_BOOTSTRAP - Attempt incremental reverse-diff bootstrap on failover (default: "no")
#     Values: "yes" or "no". Settable via the 16th CLI argument (preferred for orchestration
#     wrappers) or this environment variable (used as fallback when the argument is
#     omitted/empty).
#     Only takes effect when a state file ALREADY EXISTS for a directory AND the live
#     snapshot-state derivation (derive_direction_state, or its verified fast-path) detects a
#     direction reversal -- i.e. DEST_CLUSTER has snapshot indices beyond the last common index
#     that SOURCE_CLUSTER lacks (typical after a DR failover/failback role swap).
#     "yes": attempt a one-time incremental reverse `distcp -diff` bootstrap
#       (reconcile_reverse_diff_bootstrap) instead of forcing a fresh full Stage 3 baseline.
#       Fails the directory cleanly (NOT a destructive rollback) if the reverse diff detects
#       the new destination was modified since its own last snapshot from this pair.
#     "no" (default): behavior is unchanged from today for non-reversed directories; a detected
#       direction reversal fails the directory cleanly with operator guidance instead of risking
#       the normal incremental path (see Stage 4 notes).
#     Brand-new directories (no state file at all) ALWAYS go through Stage 3's full baseline
#     path regardless of this flag.
#     Example: export REVERSE_DIFF_BOOTSTRAP=yes
#   - HDFS_STATE_DIR - HDFS-mirrored directory for cross-node DR state (default:
#     "/tmp/pulse_replication_action"). Settable via the 17th CLI argument (preferred
#     for orchestration wrappers) or this environment variable (used as fallback when
#     the argument is omitted/empty), same pattern as REVERSE_DIFF_BOOTSTRAP above.
#     WHY THIS FEATURE EXISTS: the on-disk state file (/var/tmp/dr-last-snap-*.txt)
#     is local to whichever host runs the script. Forward replication normally
#     runs on the DR node; a failover requires running the script on what WAS
#     the source node (now the new destination) -- a node that has never run
#     this script before and has no local state file, so its fast-path
#     performance-hint cache is cold and it must fall through to the full live
#     listing-and-intersection algorithm (still fully correct, just slower) for
#     this run. HDFS_STATE_DIR mitigates the "cold cache" cost: after every
#     successful state write, the same 1-line state content (the last common
#     snapshot name only) is ALSO written to
#     ${HDFS_STATE_DIR}/dr-last-snap-<sanitized_dir>.txt on BOTH the source and
#     destination cluster's HDFS (via "hdfs dfs -fs hdfs://<cluster>"). Because
#     this lives in HDFS rather than on local disk, it is readable from
#     whichever physical host you invoke the script from, regardless of which
#     cluster you pass as SOURCE_CLUSTER/DEST_CLUSTER that run.
#     As of the live-snapshot-direction-derivation rework, this mirror is an
#     OPTIONAL PERFORMANCE HINT ONLY -- the actual last common snapshot index is
#     derived fresh from live ".snapshot" listings on both clusters whenever the
#     mirror is absent, stale, or cannot be confirmed via a cheap existence
#     check. A stale or missing mirror degrades performance (forces the slower
#     full-listing path) but can NEVER cause an incorrect direction/safety
#     verdict.
#     RESOLUTION ORDER on read (see resolve_state_file): local new-format path,
#     then local old-format path (pre-existing back-compat), then the HDFS
#     mirror(s). Both clusters' mirrors are read (not a simple source-then-dest
#     fallback): if only one is usable, that one is used; if both are usable
#     and agree, either is used; if both are usable and DISAGREE, the mirror
#     with the HIGHER snapshot index wins (state only ever advances forward,
#     so a higher index is more recent -- SOURCE_CLUSTER's mirror is used only
#     as a last-resort tie-break when the index comparison is inconclusive).
#     If neither cluster has a usable mirror, the directory is "truly brand
#     new" as far as this cache goes (live snapshot listings may still find
#     real history -- see the direction-derivation notes above). If found only
#     in HDFS, the local state file is self-healed (hydrated) from the HDFS
#     content so subsequent runs on that node hit the fast local path -- the
#     same self-migration philosophy already used for the old-path ->
#     new-path format migration.
#     FAILURE HANDLING: the HDFS mirror write is best-effort. If it fails
#     (cluster unreachable, permission denied, path not yet created), a [WARN]
#     is logged and the run continues completely normally using local state --
#     this NEVER fails a directory's sync or the overall run. A failed mirror
#     write/read affects ONLY the fast-path performance optimization -- the run
#     always falls through to a live, verified snapshot listing before making
#     any direction/safety decision.
#     NAMING: the default directory name "/tmp/pulse_replication_action" is
#     intentionally NOT a dotfile/hidden path, and intentionally contains the
#     literal token "pulse_replication_action". This is Pulse's own
#     replication-action state (not customer data, not disposable scratch
#     space); a visible, clearly-branded name ensures any operator who runs a
#     plain "hdfs dfs -ls /tmp" immediately recognizes it as belonging to
#     Acceldata Pulse's DR replication tooling and does not mistake it for
#     generic scratch space safe to delete. Do not rename this to a generic
#     or hidden (dotfile) name.
#     Example: export HDFS_STATE_DIR=/tmp/pulse_replication_action
#   - FORCE_REBASELINE - Override Stage 3's live-snapshot confirmation of the
#     "brand new directory" verdict (default: "no"). Values: "yes" or "no".
#     Env var only (no CLI argument slot), since it is only used interactively
#     during operator recovery.
#     Stage 3 no longer decides "brand new" from state-file absence alone -- it
#     confirms that against live ".snapshot" listings on both clusters, and:
#       - shared snapshot found  -> REHYDRATES state from it, skips baseline
#       - unshared snapshots only, or a listing failed -> REFUSES to baseline
#       - nothing found          -> baselines as before
#     That closes a silent-data-gap hole (see the HDFS STATE MIRROR notes above
#     and confirm_brand_new_against_live_snapshots), but it also means the
#     documented "clear state to force a re-baseline" recovery no longer works on
#     its own. Set this to "yes" to make Stage 3 trust cleared state and baseline
#     anyway. It only affects directories whose state is ALREADY absent
#     (directories with intact state never reach the gate), so clearing state for
#     one directory plus this flag re-baselines exactly that directory.
#     WARNING: a re-baseline performs a FULL copy that overwrites the destination.
#     Example: export FORCE_REBASELINE=yes
#   - HADOOP_CLIENT_OPTS    - JVM options for the DistCp DRIVER/client (NOT the YARN mappers).
#     Default applied by this script if unset: -Xmx5g
#     The client builds the copy listing and computes snapshot diffs in-process; the Hadoop
#     default heap (~1 GB) can OOM on large directories (e.g. "java.lang.OutOfMemoryError" /
#     "GC overhead limit exceeded" before the YARN job is even submitted). Raise it for big trees:
#     Example: export HADOOP_CLIENT_OPTS="-Xmx4g"
#     (Mapper-side memory is tuned separately via -Dmapreduce.map.memory.mb in COPY_OPTS, arg 8.)
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
#   ./hadoop_dr_replication_4.2.0.sh \
#     "prod-namenode-1.example.com:8020" \
#     "dr-namenode-1.example.com:8020" \
#     "/data/warehouse,/data/analytics" \
#     "dr_snap" 3 "hdfs" "hdfs" "-strategy dynamic -direct -update -pugptx" \
#     "default" \
#     "no" "no" \
#     "no" \
#     "" \
#     "pull" \
#     "/var/log/hadoop-dr-replicate.log"
#
#   With path exclusion filter and push mode (patterns passed inline, NOT a
#   file path -- the script generates and manages the actual filter file):
#   ./hadoop_dr_replication_4.2.0.sh \
#     "prod-namenode-1.example.com:8020" \
#     "dr-namenode-1.example.com:8020" \
#     "/data/warehouse,/data/analytics" \
#     "dr_snap" 3 "hdfs" "hdfs" "-strategy dynamic -direct -update -pugptx" \
#     "default" \
#     "no" "no" \
#     "no" \
#     ".*dir4/sub2.*,.*/staging/.*" \
#     "push" \
#     "/var/log/hadoop-dr-replicate.log"
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
#            - Verify superuser privilege on BOTH clusters (unconditional; runs before
#              any of the branching below, via "hdfs dfsadmin -report")
#            - Validate NameNode JMX accessibility and HA ACTIVE state (if available)
#   Stage 2: Enable snapshot capability (idempotent, per-directory, re-verified every run)
#            - Allow snapshot on source and destination directories, every run (the
#              allowSnapshot RPC is idempotent server-side: "already snapshottable" counts
#              as success), so a destination that loses its snapshottable flag out-of-band
#              (recreated dir, disallowSnapshot, restore from a non-snapshottable backup)
#              is re-enabled automatically instead of silently staying broken.
#            - If destination dir missing:
#                * In "yes" mode (auto-bootstrap): create the dir on destination with same owner/permissions
#                * In "no" mode (manual): print full DistCp instructions and exit for operator
#            - Each directory has its own marker file recording whether Stage 2 last
#              succeeded (informational only -- never gates re-running allowSnapshot)
#   Stage 3: Baseline snapshot creation (idempotent)
#            - For directories lacking a state file, CONFIRM they are really brand new
#              against live ".snapshot" listings on both clusters before baselining
#              (confirm_brand_new_against_live_snapshots). State-cache absence alone is
#              not evidence a directory was never replicated:
#                * a snapshot shared by both clusters -> real history: rehydrate state
#                  from it and skip baselining (no full copy)
#                * unshared snapshots on both sides, destination-only history, or a
#                  failed listing -> refuse to baseline, fail the directory
#                * nothing found (or FORCE_REBASELINE=yes) -> create ${SNAP_PREFIX}_0
#                  on source and destination
#            - If baseline snapshots were created (only for those directories):
#                * If AUTO_FULL_DISTCP="yes": Automatically runs full DistCp for each
#                  directory, creates new baseline snapshot on destination (post-DistCp state),
#                  then exits. Operator must re-run script for incremental sync.
#                  WARNING: Can take significant time for large datasets.
#                * If AUTO_FULL_DISTCP="no" (default): Script exits and instructs
#                  operator to run a **full DistCp** for each directory (manual step)
#   Stage 4: Incremental sync loop (per-directory)
#            For each directory, FIRST determines direction/continuation state:
#              - resolve_state_file_and_check_new: resolve local/HDFS-mirrored last_snap
#                cache (brand-new-directory gate); see HDFS_STATE_DIR notes above.
#              - verify_cached_snap_fast_path: cheap, LIVE-VERIFIED check of the cached
#                last_snap against both clusters before trusting it (avoids a full
#                listing in the common unchanged-direction case).
#              - derive_direction_state (full path, only when the fast path can't
#                confirm): lists actual snapshots on BOTH clusters, finds the last
#                common index, and determines from LIVE snapshot existence (never a
#                cached label) whether this is normal forward continuation, a
#                direction reversal, or split-brain (both sides advanced past the
#                last common index independently) -- split-brain is detected
#                PROACTIVELY here, before any DistCp is attempted.
#            Then, for a normal (non-reversed, non-split-brain) directory:
#              4a) Ensure last known snapshot exists on destination (create if missing)
#              4b) Create the next snapshot on the source (next snapshot name)
#              4c) Baseline transition self-heal (runs ONCE per directory, only when
#                  last_snap is the ${SNAP_PREFIX}_0 baseline): reconcile_and_rebaseline_dest
#                  backfills any gap between the baseline snapshot and destination live data.
#              4d) Run DistCp with -diff from last -> next (stderr captured to temp file
#                  for error analysis, and displayed in real-time via global redirection)
#              4e) On success, create the next snapshot on destination
#              4f) Advance internal state (persist next snapshot name; also mirrors to
#                  HDFS on both clusters as a best-effort performance-cache update)
#              4g) Cleanup old snapshots on source (retain SNAP_RETAIN most recent)
#              4h) Cleanup old snapshots on destination (retain SNAP_RETAIN most recent)
#            If a direction reversal is detected: either runs an incremental reverse-diff
#            bootstrap (REVERSE_DIFF_BOOTSTRAP=yes) or fails cleanly with operator guidance
#            (default) -- never falls through to the normal path above, since doing so
#            could reach the destructive rollback path against real data on the new
#            destination. See REVERSE_DIFF_BOOTSTRAP notes above.
#            If snapshot-modified error detected during 4d and ROLLBACK_ON_FAILURE="yes":
#              - Attempt one-time automatic rollback (per-failure marker prevents retries)
#              - After rollback, retry DistCp once
#   Stage 5: Completion and logging
#
# Replication mode: PULL-BASED
#   This script is designed to run on the TARGET/DR cluster.
#   YARN DistCp jobs are submitted to the target cluster's ResourceManager.
#   The source (production) cluster is not burdened with replication compute.
#
# Operator checklist (before running on TARGET/DR cluster):
#   1. Ensure the DistCp user has superuser privileges on both clusters.
#   2. Verify network connectivity from TARGET to SOURCE cluster:
#        - NameNode RPC port (8020 or custom)
#        - DataNode data transfer ports (50010/50020 or custom)
#        - NameNode Web UI port (50070/9870) for JMX health checks
#   3. Ensure source cluster NameService is resolvable from target:
#        - Add source NameService config to target's hdfs-site.xml
#        - Validate: hdfs dfs -fs hdfs://<source-ns> -ls /
#   4. Ensure YARN queue (YARN_QUEUE arg) exists on the TARGET cluster.
#   5. Verify Kerberos cross-realm trust or shared realm (if applicable).
#   6. Run the script with the correct arguments (see Usage).
#   7. If the script creates baseline snapshots:
#        - If AUTO_FULL_DISTCP="yes": Script will automatically run full DistCp.
#          Monitor logs as this can take significant time for large datasets.
#        - If AUTO_FULL_DISTCP="no" (default): Run the full DistCp commands
#          printed by the script for each directory, then re-run the script.
#   8. Monitor the log file specified (10th positional argument: LOG_PATH).
#
# Pre-requisites:
#   • This script must run on the TARGET/DR cluster (pull-based replication).
#   • The DistCp/HDFS user must be superuser (or in superusergroup) on both clusters.
#   • Snapshot capability supported by HDFS and allowed for target directories.
#   • Network connectivity from target to source cluster (NameNode RPC, DataNode, JMX).
#   • Source cluster NameService must be configured in target's hdfs-site.xml.
#   • Kerberos credentials must be valid for both clusters (if Kerberos enabled).
#   • YARN queue for DistCp jobs must exist on the target cluster.
#
# -----------------------------------------------------------------------------
# ./hadoop_dr_replication_4.2.0.sh "prod-namenode-1.example.com:8020" "dr-namenode-1.example.com:8020" "/data/warehouse,/data/analytics" "dr_snap" 3 "hdfs" "hdfs" "-update -pugpx" "default" "no" "no" "no" "" "pull" "/var/log/hadoop-dr-replicate.log"
#

set -euo pipefail
SCRIPT_START_TS=$(date +%s)

# -----------------------------------------------------------------------------
# Early logging helpers (must be defined before first use) NOTE: Before exec/tee is enabled, errors should go
# directly to stderr
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
DISTCP_USER="${7:-$HDFS_USER}"
COPY_OPTS="${8:--strategy dynamic -direct -update -pugptx -skipcrccheck}"
YARN_QUEUE="${9:-default}"

#
# Configuration flags (can be set via CLI args 10-11, environment variables, or defaults)
# Priority: 1) CLI argument, 2) Environment variable, 3) Default value
AUTO_FULL_DISTCP_ARG="${10:-}"
ROLLBACK_ON_FAILURE_ARG="${11:-}"

###############################################################################
# Directory bootstrap mode: HARDCODED, not a CLI argument and not an
# environment variable. Missing destination directories are always
# auto-created (same owner/permissions as source). See DIR_BOOTSTRAP_MODE
# section below for details -- there is intentionally no override.
###############################################################################
DIR_BOOTSTRAP_MODE="yes"

###############################################################################
# Kerberos control source (priority: CLI arg 12 -> env var -> default)
# Default is "no" to ensure safe sudo-based execution unless explicitly enabled
###############################################################################
KERBEROS_ENABLED_ARG="${12:-${KERBEROS_ENABLED:-no}}"

###############################################################################
# DistCp path exclusion filter (priority: CLI arg 13 -> env var -> default)
# Operator passes the actual regex PATTERNS inline (comma-separated, like
# SOURCE_DIRS) -- NOT a pre-made file path. empty/omitted = disabled.
# The script itself materializes a job-keyed filter file (see
# resolve_distcp_exclude_file / DISTCP_EXCLUDE_DIR below); no file for the
# operator to create, own, or clean up.
###############################################################################
DISTCP_EXCLUDE_PATTERNS_ARG="${13:-}"

###############################################################################
# Replication mode (priority: CLI arg 14 -> env var -> default)
# Default is "pull" for backward compatibility.
###############################################################################
REPLICATION_MODE_ARG="${14:-}"

###############################################################################
# LOG_PATH (priority: CLI arg 15 -> default)
# Kept ahead of REVERSE_DIFF_BOOTSTRAP (arg 16) so existing arg-15 invocations
# of this script don't shift; new flags get appended after it instead.
###############################################################################
LOG="${15:-/var/log/hadoop-dr-replicate.log}"

###############################################################################
# Reverse-diff bootstrap for failover/failback (priority: CLI arg 16 -> env var -> default)
# Default is "no" for full backward compatibility.
###############################################################################
REVERSE_DIFF_BOOTSTRAP_ARG="${16:-}"
if [[ -n "$REVERSE_DIFF_BOOTSTRAP_ARG" ]]; then
    REVERSE_DIFF_BOOTSTRAP="$REVERSE_DIFF_BOOTSTRAP_ARG"
else
    REVERSE_DIFF_BOOTSTRAP="${REVERSE_DIFF_BOOTSTRAP:-no}"
fi

###############################################################################
# HDFS-mirrored state directory for cross-node failover state
# (priority: CLI arg 17 -> env var -> default)
#
# WHAT IT IS: a directory ON HDFS (not local disk) where this script mirrors
# its per-directory replication state (the last common snapshot name) after
# every successful run. It is a PERFORMANCE-HINT CACHE ONLY -- the real
# direction/safety decision always comes from a live ".snapshot" listing on
# both clusters (see derive_direction_state). Losing or clearing this mirror
# never causes an incorrect result, only a slower fallback run.
#
# WHY IT EXISTS: the primary state file (/var/tmp/dr-last-snap-*.txt) lives on
# local disk, so it is only visible to whichever host ran the script. Forward
# replication normally runs on the DR node. A failover/failback flips that: you
# must run the script on what WAS the source node (now the new destination) --
# a node that has never run this script before and therefore has no local
# state file, forcing a slow full live-listing fallback on that first run.
# Mirroring the same 1-line state to HDFS (readable from either node, via
# "hdfs dfs -fs hdfs://$CLUSTER") lets that first failover run hit the fast
# cached path too, instead of starting cold. See the HDFS_STATE_DIR entry in
# the "Environment Variables" section above for the full read/write and
# conflict-resolution rules.
#
# DEFAULT PATH: "/tmp/pulse_replication_action" -- this is a cluster-RELATIVE
# HDFS path, always resolved against a specific cluster via
# "hdfs dfs -fs hdfs://$CLUSTER", never containing a host/NameService itself.
#
# NAMING RATIONALE (why the default is NOT a dotfile): this directory holds
# Pulse's own replication-action state (a mirror of the local DR state file)
# -- it is not customer data and not disposable scratch space. A hidden
# dotfile name (e.g. "/tmp/.dr_replication_state") would make it invisible to
# a plain "hdfs dfs -ls /tmp", inviting an operator or a cleanup cron to treat
# it as safe-to-delete scratch, or to miss it entirely during an audit. The
# visible, branded name "pulse_replication_action" ensures anyone who runs
# "hdfs dfs -ls /tmp" immediately attributes the directory to Acceldata
# Pulse's DR replication tooling and does not casually delete it.
# Do NOT rename this back to a generic or hidden name.
###############################################################################
HDFS_STATE_DIR_ARG="${17:-}"
if [[ -n "$HDFS_STATE_DIR_ARG" ]]; then
    HDFS_STATE_DIR="$HDFS_STATE_DIR_ARG"
else
    HDFS_STATE_DIR="${HDFS_STATE_DIR:-/tmp/pulse_replication_action}"
fi

###############################################################################
# FORCE_REBASELINE: operator escape hatch for Stage 3's brand-new-directory gate.
#
# Stage 3 no longer decides "is this directory brand new?" from state-file
# presence alone -- it confirms that verdict against LIVE snapshot listings on
# both clusters (see confirm_brand_new_against_live_snapshots). That closed a
# real data-loss hole (total state loss -> re-baselining an already-replicating
# directory on top of live data), but it also means that clearing state files is
# by itself no longer enough to force a deliberate re-baseline: the gate would
# simply rehydrate the state from the live snapshots it finds.
#
# Set FORCE_REBASELINE=yes to make Stage 3 trust the cleared state and baseline
# anyway, for the documented manual-recovery procedures (no-common-snapshot,
# split-brain, direction reversal) printed at the relevant failure points.
#
# SCOPING: this is a global flag, but it only has any effect on directories
# whose state is ALREADY absent -- directories with intact state never reach the
# gate at all. So "clear state for directory X + FORCE_REBASELINE=yes"
# re-baselines exactly X, leaving every other directory on its normal
# incremental path. Env var only (no CLI slot), since it is only ever used
# interactively during operator recovery.
# Example: export FORCE_REBASELINE=yes
###############################################################################
FORCE_REBASELINE="${FORCE_REBASELINE:-no}"

###############################################################################
# Per-NameService HA client config injection (env var only for now -> default OFF). No CLI argument slot
# reserved yet -- same CLI-arg/env-var/default pattern as REVERSE_DIFF_BOOTSTRAP/HDFS_STATE_DIR.
#
# WHY THIS EXISTS: this script is typically run FROM the DR/target cluster, whose local hdfs-site.xml usually
# only has ITS OWN NameService's HA details (dfs.nameservices, dfs.ha.namenodes.<ns>,
# dfs.namenode.rpc-address.<ns>.*, dfs.client.failover.proxy.provider.<ns>). It commonly does NOT have the
# SOURCE/production cluster's NameService registered at all, which makes every "hdfs dfs -fs
# hdfs://<source-nameservice>" call in this script hang for the client's full RPC retry window (the
# NameService can't be resolved to actual NameNode hosts) instead of failing fast -- see
# check_nameservice_reachable's own doc comment for the exact symptom this was built to diagnose.
#
# The permanent, correct fix is to add the missing NameService's HA properties to hdfs-site.xml on every node
# that runs this script (see the operator checklist near the top of this file: "Ensure source cluster
# NameService is resolvable from target"). This feature is a SUPPLEMENTARY, script-scoped fallback for cases
# where that infra change can't be rolled out immediately (e.g. during initial rollout/migration, or a
# temporary DR drill), so this script can still run correctly without touching cluster-wide client config.
#
# HOW IT WORKS: when enabled, the script derives the 4 standard Hadoop HA client properties for BOTH clusters
# directly from SRC_NN_HOSTS/DST_NN_HOSTS (see below) -- no separate config file to author. Every real "hdfs
# dfs" / "hdfs dfsadmin" / "hdfs snapshotDiff" / "hadoop distcp" invocation this script makes is then scanned
# (inside run_as_hdfs()/run_as_distcp(), the single choke point ALL such calls already go through -- see those
# functions below) for any "hdfs://<nameservice>" URI reference, and the matching derived properties are
# injected as generic Hadoop "-D" options immediately after the "hdfs"/"hadoop" subcommand token (e.g. "hdfs
# dfs -Ddfs.nameservices=... -fs hdfs://<ns> -ls ...") so they are always parsed as client-side config, never
# mistaken for the subcommand's own arguments. This is a single choke-point change -- NONE of the ~35
# individual call sites elsewhere in the script needed to change.
#
# WHY KEYED BY NAMESERVICE NAME, NOT "source"/"dest": SOURCE_CLUSTER and DEST_CLUSTER are just role labels
# that can SWAP after a DR failover/failback (see REVERSE_DIFF_BOOTSTRAP above) -- the same physical
# NameService that was "source" today can be passed in as "dest" tomorrow. Both SRC_NN_HOSTS and DST_NN_HOSTS
# are loaded and derived for BOTH the current SOURCE_CLUSTER and DEST_CLUSTER NameService names every run (not
# pre-baked into a file keyed to a fixed name), so the lookup keeps working correctly across a role swap with
# ZERO reconfiguration -- whichever one the script currently calls SOURCE_CLUSTER or DEST_CLUSTER, its derived
# config is found by name.
#
# Values:
#   "no"  (default): completely inert. Zero behavior change, zero performance
#         cost -- run_as_hdfs()/run_as_distcp() skip the scan entirely.
#   "yes": enables the derive/inject behavior described above. Requires
#         SRC_NN_HOSTS and DST_NN_HOSTS to both be set (see below) -- if
#         either is missing/malformed, this script FAILS FAST at startup
#         with a clear error rather than silently running without the config
#         the operator thought they enabled.
#
# Example: export AUTO_DERIVE_HA_CLIENT_CONFIG=yes
###############################################################################
AUTO_DERIVE_HA_CLIENT_CONFIG="${AUTO_DERIVE_HA_CLIENT_CONFIG:-false}"

###############################################################################
# SRC_NN_HOSTS / DST_NN_HOSTS - required when AUTO_DERIVE_HA_CLIENT_CONFIG=true. Comma-separated
# "<nn-id>=<host>:<port>" pairs describing each NameService's NameNodes -- this is ALL the operator needs to
# provide; every other HA property (dfs.nameservices, dfs.ha.namenodes.<ns>, the failover proxy provider
# class) is derived automatically from these two variables. There is no config file to author.
#
#   SRC_NN_HOSTS  - NameNodes for whichever NameService is CURRENTLY passed
#                   as SOURCE_CLUSTER (arg 1).
#   DST_NN_HOSTS  - NameNodes for whichever NameService is CURRENTLY passed
#                   as DEST_CLUSTER (arg 2).
#
# Example:
#   export SRC_NN_HOSTS="nn1=atlasdemo-01.adsre.com:8020,nn2=atlasdemo-02.adsre.com:8020"
#   export DST_NN_HOSTS=""nn1=odplab001.adsre.com:8020,nn2=odplab002.adsre.com:8020"
#
# NN ids (nn1/nn2/...) can be any short token -- they only need to be unique within one NameService, and are
# used verbatim in "dfs.ha.namenodes.<ns>" and "dfs.namenode.rpc-address.<ns>.<nnid>". Two NN entries is the
# normal HA case, but the format supports more.
#
# FAILOVER NOTE: because these two variables are named by CURRENT ROLE (SRC/DST), not by a fixed NameService
# identity, an operator re-running this script after a failover/failback role swap (SOURCE_CLUSTER and
# DEST_CLUSTER arguments swapped -- see REVERSE_DIFF_BOOTSTRAP above) MUST also swap the values of
# SRC_NN_HOSTS and DST_NN_HOSTS to match, so each still describes the NameService now occupying that argument
# slot.
###############################################################################
SRC_NN_HOSTS="${SRC_NN_HOSTS:-}"
DST_NN_HOSTS="${DST_NN_HOSTS:-}"
#
#
# ROLLBACK_ON_FAILURE for DR Cluster is a safeguard for handling the common snapshot-modified error "DistCp:
# The target has been modified since snapshot" during DistCp (when DR data has diverged from expected snapshot
# state). If set to "yes", the script will attempt a one-time rollback on DR:
#   - Capture a rollback snapshot, restore to last good snapshot, retry DistCp.
#   - Uses per-failure markers (per directory + snapshot pair) to prevent infinite retries of
#     the same failure, but allows rollback for new failures (different snapshot pairs).
#   - Marker format: ${ROLLBACK_MARKER_DIR}/${dir_key}__from_${from_snap}__to_${to_snap}.marker
# If set to "no" (default), the script will just log the error and stop. Acceptable values: "yes" or "no".
# Priority: 1) CLI argument (11th arg), 2) Environment variable, 3) Default value
if [[ -n "$ROLLBACK_ON_FAILURE_ARG" ]]; then
    ROLLBACK_ON_FAILURE="$ROLLBACK_ON_FAILURE_ARG"
else
    ROLLBACK_ON_FAILURE="${ROLLBACK_ON_FAILURE:-no}"
fi

# HTTP scheme and port for accessing the NameNode JMX endpoint. Configurable separately for source and
# destination clusters to support different Hadoop distributions (e.g., ODP vs CDP) with different
# configurations
SOURCE_HTTP_SCHEME="${SOURCE_HTTP_SCHEME:-http}"  # http or https for source cluster
SOURCE_NN_WEB_PORT="${SOURCE_NN_WEB_PORT:-50070}" # NameNode web UI port for source (commonly 50070 or 9870)
DEST_HTTP_SCHEME="${DEST_HTTP_SCHEME:-http}"     # http or https for destination cluster
DEST_NN_WEB_PORT="${DEST_NN_WEB_PORT:-50070}"     # NameNode web UI port for destination (commonly 50070 or 9870)

# Kerberos credential cache path (KRB5CCNAME) If your Kerberos plugin stores cache at a custom location (e.g.,
# /tmp/krb_*), set this environment variable to point to the cache file. Example: export
# KRB5CCNAME=/tmp/krb_12345 If not set, curl will use the default Kerberos cache location.
KRB5CCNAME="${KRB5CCNAME:-}"

# DistCp driver/client JVM heap (NOT the YARN mappers). The DistCp client builds the copy listing and computes
# snapshot diffs in-process; the Hadoop default heap (~1 GB) can OOM on large directories before the YARN job
# is submitted. Apply a safe default of 5g unless the operator already set HADOOP_CLIENT_OPTS, and export it
# so it is inherited by the `hadoop distcp` / `hdfs` invocations (incl. via run_as_distcp).
export HADOOP_CLIENT_OPTS="${HADOOP_CLIENT_OPTS:--Xmx5g}"

# Marker file directory recording, per directory, whether Stage 2's allowSnapshot last
# succeeded on both clusters: ${SNAP_LOCK_DIR}/<sanitized_dir_path>.lock
# INFORMATIONAL ONLY -- Stage 2 calls allowSnapshot every run regardless of whether this
# marker exists (the RPC is idempotent), so a missing/stale/present marker never skips
# re-verification. See Stage 2's per-directory loop for the full rationale.
SNAP_LOCK_DIR="/var/tmp/dr-snapshot-setup-locks"

###############################################################################
# Directory bootstrap strategy for missing DR dirs: HARDCODED to "yes"
# (see DIR_BOOTSTRAP_MODE="yes" assignment in Stage 0 above -- no CLI argument,
# no environment variable, no override of any kind).
#
# Behavior in "yes" (auto-bootstrap) mode:
#   - If the destination directory is missing, it will be created automatically
#     with the same owner and permissions as the source directory.
#   - If the destination directory already exists, it will NOT be recreated,
#     and no chown/chmod is performed.
#   - allowSnapshot will be applied automatically to the destination
#     directory as part of Stage 2.
###############################################################################

###############################################################################
# Automatic full DistCp execution on initial run: "yes" or "no"
#
# When baseline snapshots are created (initial run), this flag controls whether the script automatically runs
# full DistCp commands or just displays them.
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
# Set AUTO_FULL_DISTCP to either "yes" or "no" as desired. Priority: 1) CLI argument (10th arg), 2)
# Environment variable, 3) Default value
###############################################################################
if [[ -n "$AUTO_FULL_DISTCP_ARG" ]]; then
    AUTO_FULL_DISTCP="$AUTO_FULL_DISTCP_ARG"
else
    AUTO_FULL_DISTCP="${AUTO_FULL_DISTCP:-no}"
fi

# Marker directory for per-failure rollback markers. Each marker is unique per directory + snapshot pair
# (from_snap -> to_snap). This allows rollback for new failures on the same directory (different snapshot
# pairs), while preventing infinite retries of the exact same failure.
ROLLBACK_MARKER_DIR="/var/tmp/dr-rollback-markers"

###############################################################################
# Maximum age (seconds) a rollback marker is honored before it is treated as
# STALE and a fresh rollback attempt is allowed again for that (dir,
# from_snap, to_snap) pair. Default: 86400 (24 hours).
#
# WHY THIS EXISTS: marker filenames are keyed ONLY by directory + the two
# literal snapshot NAMES (e.g. "dr_snap_5__to_dr_snap_6"), with no timestamp,
# run id, or cycle identifier in the filename itself, and nothing in the
# script ever deletes a marker automatically except reconcile_and_rebaseline_dest's
# narrow baseline-transition cleanup (which only clears markers whose
# from_snap is the ${SNAP_PREFIX}_0 baseline). Snapshot indices are small,
# reused-space integers shared across the ENTIRE lifetime of a replicated
# pair -- across ordinary operation they are strictly monotonic and never
# collide, but they CAN legitimately repeat after an operator performs the
# script's own documented "force a full re-baseline" recovery (printed at
# several failure points), which resets the index sequence back near 0. In a
# DR system that undergoes repeated failover/failback drills over months or
# years, a marker created during a rollback attempt from a MUCH earlier cycle
# could otherwise sit on disk forever and silently cause a genuinely new,
# unrelated rollback attempt with the same (from_snap, to_snap) pair to be
# skipped -- logged only as a routine "[ROLLBACK] Marker exists" line, not an
# alarm. An age-based expiry preserves the marker's real purpose (prevent a
# tight retry-loop against a still-broken condition within the same
# incident/window) while guaranteeing it can never block rollback forever.
#
# Priority: environment variable only (no CLI argument slot reserved).
# Example: export ROLLBACK_MARKER_MAX_AGE_SECS=3600   # 1 hour
###############################################################################
ROLLBACK_MARKER_MAX_AGE_SECS="${ROLLBACK_MARKER_MAX_AGE_SECS:-86400}"

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

# Validate SNAP_PREFIX doesn't contain invalid characters for HDFS snapshot names HDFS snapshot names cannot
# contain: / \ : * ? " < > |  -- and, separately, SNAP_PREFIX must not contain whitespace either: it is
# expanded UNQUOTED at every distcp call site (DISTCP_EXCLUDE_OPTS etc. rely on word-splitting for "-D"
# flags), and it is also embedded unquoted into the generated DistCp -filters file path
# (resolve_distcp_exclude_file's job_key). A space in SNAP_PREFIX would silently split that path into two
# bogus command-line arguments at the distcp invocation, the same failure mode as an unquoted line break, just
# triggered differently -- so it must be rejected here up front rather than relying on sanitize() (which only
# strips / and :, not whitespace).
if [[ "$SNAP_PREFIX" =~ [/\\:\*\?\"\<\>\|[:space:]] ]]; then
    echo "[ERROR] SNAP_PREFIX contains invalid characters for HDFS snapshot names: '$SNAP_PREFIX'" >&2
    echo "[ERROR] Invalid characters: / \\ : * ? \" < > | and whitespace (space/tab/newline)" >&2
    exit 13
fi

CURRENT_STAGE=""

# Global failure tracking variables
SCRIPT_FAILED="no"
FAILURE_REASON=""

# Metrics tracking for status determination (simplified - only success/failure counts)
METRICS_SUCCESSFUL_DIRECTORIES=0
METRICS_FAILED_DIRECTORIES=0

# Counter for HDFS state-mirror write/mkdir failures (ensure_hdfs_state_dir, mirror_state_file_to_hdfs /
# _mirror_one_cluster). These are all best-effort/ non-fatal by design (see HDFS_STATE_DIR docs) and never
# fail a directory's sync, but a mirror that has been silently broken for a long time (e.g. a permissions
# change on one cluster) would otherwise be invisible until the exact moment of a real failover. Surfaced in
# the Stage 5 summary so an operator sees it during routine, non-emergency runs instead of only discovering it
# mid-disaster.
METRICS_HDFS_MIRROR_FAILURES=0


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
            return 0
        else
            log "[WARN] KRB5CCNAME is set but invalid: $KRB5CCNAME"
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
        return 0
    fi

    log "[INFO] Kerberos not detected (no valid credential cache found)"
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
    # Kerberos status will be displayed in the startup banner after output redirection No need to display it
    # here separately
}

###############################################################################
# Per-NameService HA client config: derive + injection helpers. See the AUTO_DERIVE_HA_CLIENT_CONFIG /
# SRC_NN_HOSTS / DST_NN_HOSTS variable docs above for the full "why". This block is the single choke point
# that makes the feature apply to EVERY "hdfs dfs"/"hdfs dfsadmin"/"hdfs snapshotDiff"/ "hadoop distcp" call
# in the script, since all of them already funnel through run_as_hdfs()/run_as_distcp() below -- no other call
# site anywhere in this script needs to change.
#
# DESIGN (combined dfs.nameservices, matching the proven-working reference invocation this feature was modeled
# on): dfs.nameservices is a COMMA-SEPARATED LIST property -- Hadoop reads the whole list and resolves each
# named entry's "dfs.ha.namenodes.<name>" independently. The correct way to make both SOURCE_CLUSTER and
# DEST_CLUSTER resolvable via injected "-D" flags is therefore to build ONE combined
# "-Ddfs.nameservices=<SRC>,<DST>" (never two separate, competing single-name "-D" flags for the same property
# -- an earlier version of this feature did exactly that, and the SECOND flag silently overwrote the FIRST's
# single value, breaking whichever cluster's name was clobbered; see git history / incident notes for the
# production failure this caused). All derived properties (both clusters' NN addresses, proxy provider
# classes, and the combined dfs.nameservices/automatic-failover flag) are ALWAYS injected together as one
# fixed set whenever AUTO_DERIVE_HA_CLIENT_CONFIG=yes -- there is no per-cluster reachability probing or
# conditional logic here, by design: injecting the full combined set is always safe (it fully replaces, rather
# than partially conflicts with, whatever this host's own hdfs-site.xml may already define for either name).
#
# STORAGE: the combined property set is stored as ONE newline-joined string in NAMESERVICE_HA_ARGS (a plain
# string, not the array directly, so it is trivial to detect "has anything been derived yet" via [-n]), split
# back into an array with `readarray -t` using newline as the field separator -- NOT plain word splitting on
# spaces -- so a property value can safely contain a space without fragmenting into bogus extra tokens.
# Newline (not NUL) was chosen because bash string variables cannot hold an embedded NUL byte at all; a Hadoop
# "-D" property value is a single-line string by construction, so newline is a safe, always-available
# delimiter here.
###############################################################################

# Populated once by derive_nameservice_ha_conf(): newline-joined "-Dkey=value" tokens (split back out via
# `readarray -t` in _collect_nameservice_inject_args).
NAMESERVICE_HA_ARGS=""

# Build the ONE combined set of Hadoop HA client properties covering BOTH SOURCE_CLUSTER and DEST_CLUSTER from
# SRC_NN_HOSTS/DST_NN_HOSTS, matching the proven-working reference invocation exactly:
#
#   dfs.nameservices=<SOURCE_CLUSTER>,<DEST_CLUSTER>          (ONE combined value)
#   dfs.ha.namenodes.<SOURCE_CLUSTER>=<nn-id1>,<nn-id2>,...
#   dfs.ha.namenodes.<DEST_CLUSTER>=<nn-id1>,<nn-id2>,...
#   dfs.namenode.rpc-address.<SOURCE_CLUSTER>.<nn-id>=<host>:<port>   (one per NN)
#   dfs.namenode.rpc-address.<DEST_CLUSTER>.<nn-id>=<host>:<port>     (one per NN)
#   dfs.ha.automatic-failover.enabled=true
#   dfs.client.failover.proxy.provider.<SOURCE_CLUSTER>=...ConfiguredFailoverProxyProvider
#   dfs.client.failover.proxy.provider.<DEST_CLUSTER>=...ConfiguredFailoverProxyProvider
#
# Called ONCE from main(), only when AUTO_DERIVE_HA_CLIENT_CONFIG="yes". FAILS FAST (exit 18) on a malformed/empty
# NN_HOSTS string for either cluster -- an operator who explicitly enabled this flag did so BECAUSE at least
# one NameService is otherwise unresolvable; silently deriving a broken/partial property set would reproduce
# the exact hang this feature exists to prevent, just later and with a far more confusing error signature.
#
# KEYED BY NOTHING PER-CLUSTER (unlike an earlier version of this function): the combined value is
# unconditionally correct for both SOURCE_CLUSTER and DEST_CLUSTER as they are THIS run, so it survives a
# failover role-swap with zero extra logic -- whichever physical cluster is currently passed as arg 1/arg 2,
# SRC_NN_HOSTS/DST_NN_HOSTS are re-read fresh every run and the swap-awareness lives entirely in the FAILOVER
# NOTE on those two variables above (the operator must swap their values to match a swapped role).
_derive_one_cluster_ha_props() {
    local cluster_name="$1"
    local nn_hosts="$2"
    local role_label="$3" # "SOURCE" or "DEST", for error messages only

    if [[ -z "$nn_hosts" ]]; then
        echo "[ERROR] AUTO_DERIVE_HA_CLIENT_CONFIG=yes but the NN_HOSTS variable for $role_label ($cluster_name) is empty." >&2
        echo "[ERROR] Set SRC_NN_HOSTS / DST_NN_HOSTS to '<nn-id>=<host>:<port>,...' pairs, or set AUTO_DERIVE_HA_CLIENT_CONFIG=no." >&2
        exit 18
    fi

    local -a nn_ids=() pairs=()
    local pair nn_id nn_addr
    IFS=',' read -r -a pairs <<<"$nn_hosts"
    for pair in "${pairs[@]}"; do
        [[ -z "$pair" ]] && continue
        if [[ "$pair" != *=* ]]; then
            echo "[ERROR] Malformed entry in $role_label NN_HOSTS ('$nn_hosts'): '$pair' -- expected '<nn-id>=<host>:<port>'" >&2
            exit 18
        fi
        nn_id="${pair%%=*}"
        nn_addr="${pair#*=}"
        if [[ -z "$nn_id" || -z "$nn_addr" || "$nn_addr" != *:* ]]; then
            echo "[ERROR] Malformed entry in $role_label NN_HOSTS ('$nn_hosts'): '$pair' -- expected '<nn-id>=<host>:<port>'" >&2
            exit 18
        fi
        nn_ids+=("$nn_id")
        NAMESERVICE_HA_ARGS+="-Ddfs.namenode.rpc-address.${cluster_name}.${nn_id}=${nn_addr}"$'\n'
    done

    if [[ ${#nn_ids[@]} -eq 0 ]]; then
        echo "[ERROR] $role_label NN_HOSTS ('$nn_hosts') contained no usable '<nn-id>=<host>:<port>' entries." >&2
        exit 18
    fi

    local nn_ids_csv
    nn_ids_csv=$(IFS=,; echo "${nn_ids[*]}")
    NAMESERVICE_HA_ARGS+="-Ddfs.ha.namenodes.${cluster_name}=${nn_ids_csv}"$'\n'
    NAMESERVICE_HA_ARGS+="-Ddfs.client.failover.proxy.provider.${cluster_name}=org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider"$'\n'
}

derive_nameservice_ha_conf() {
    # Keyed by SRC_URI_NS/DST_URI_NS (set in main(), BEFORE this is called), not raw SOURCE_CLUSTER/
    # DEST_CLUSTER -- identical in the normal (non-colliding) case, but SRC_URI_NS becomes a synthetic alias
    # ("<name>-SRCALIAS") and DST_URI_NS becomes a bare, resolved host:port when SOURCE_CLUSTER and
    # DEST_CLUSTER share the same nameservice name. See the SRC_URI_NS/DST_URI_NS doc comment in main() for
    # the full "why" of that aliasing design.
    #
    # SAME-NAMESERVICE COLLISION CASE (confirmed by direct testing -- a real, distinct bug from the aliasing
    # design itself): "dfs.nameservices" is not merged with this node's own native hdfs-site.xml value, it is
    # REPLACED by whatever this "-D" flag sets. This node's native "dfs.nameservices" already lists the real
    # shared name (e.g. "ODP-Phoenix", since DR was built from the same blueprint as production) -- and
    # something UNRELATED to any URI this script builds needs that native entry to keep resolving: YARN's own
    # internal "FileContext"/"YARNRunner" cluster-startup code resolves "fs.defaultFS" (also
    # "hdfs://ODP-Phoenix" on this node) using whatever "dfs.nameservices" is in effect for the process. If
    # our injected "-D" replaces the list with only the alias, that startup code fails hard with "Could not
    # find any configured addresses for URI hdfs://ODP-Phoenix" -- confirmed reproducing this exact error via
    # direct testing, and confirmed fixed by keeping the real native name in the list alongside the alias
    # rather than replacing it.
    #
    # DST_URI_NS gets NO HA properties at all in the collision case: it is already a concrete, resolved
    # "host:port" (see resolve_active_namenode_hostport), not an HA nameservice name, and confirmed by direct
    # testing to need no "dfs.ha.namenodes.*"/"dfs.namenode.rpc-address.*" entries and no membership in
    # "dfs.nameservices" -- DistCp/YARN address it directly via the bare host:port already embedded in every
    # "hdfs://$DST_URI_NS" URI this script builds.
    _derive_one_cluster_ha_props "$SRC_URI_NS" "$SRC_NN_HOSTS" "SOURCE"
    local nameservices_csv
    if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
        nameservices_csv="${SOURCE_CLUSTER},${SRC_URI_NS}"
        log "[INFO] [NAMESERVICE-CONF] Same-nameservice collision: keeping native nameservice '$SOURCE_CLUSTER' in dfs.nameservices alongside alias '$SRC_URI_NS' (required for YARN's own internal cluster-startup resolution of fs.defaultFS -- confirmed by direct testing). DST_URI_NS ($DST_URI_NS) is a bare host:port and is intentionally NOT added here."
    else
        _derive_one_cluster_ha_props "$DST_URI_NS" "$DST_NN_HOSTS" "DEST"
        nameservices_csv="${SRC_URI_NS},${DST_URI_NS}"
    fi
    # Combined dfs.nameservices (ONE value listing both names -- see the DESIGN note above for why this must
    # never be two separate "-D" flags) and automatic-failover flag, matching the reference invocation.
    NAMESERVICE_HA_ARGS+="-Ddfs.nameservices=${nameservices_csv}"$'\n'
    NAMESERVICE_HA_ARGS+="-Ddfs.ha.automatic-failover.enabled=true"$'\n'
    log "[INFO] [NAMESERVICE-CONF] Derived combined HA client config for SOURCE_CLUSTER ($SRC_URI_NS) and DEST_CLUSTER ($DST_URI_NS) from SRC_NN_HOSTS/DST_NN_HOSTS."
}

# Render NAMESERVICE_HA_ARGS as a single space-joined string of "-D..." flags, suitable for splicing into a
# command line PRINTED for an operator to copy-paste (e.g. the manual-DistCp instructions in Stage 3).
#
# WHY THIS EXISTS: run_as_hdfs()/run_as_distcp() inject these same properties automatically for any command
# the SCRIPT ITSELF runs (see _collect_nameservice_inject_args), so a same-nameservice-alias URI like
# "hdfs://<name>-SRCALIAS" resolves correctly whenever this script is the one invoking hadoop/hdfs. But Stage 3's
# manual-mode DistCp instructions are printed text the OPERATOR runs by hand in their own shell, completely
# outside run_as_distcp -- copy-pasting the bare "hadoop distcp ... hdfs://<alias>/path ..." command without
# these flags fails, because no hdfs-site.xml anywhere defines the synthetic alias. Prefixing the printed
# command with the same "-D" set makes it correctly self-contained and runnable standalone.
#
# Returns empty string (safe to prefix unconditionally) when AUTO_DERIVE_HA_CLIENT_CONFIG is disabled or nothing
# has been derived yet -- callers should call this only after derive_nameservice_ha_conf() has run.
render_nameservice_ha_args_for_display() {
    if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]] || [[ -z "$NAMESERVICE_HA_ARGS" ]]; then
        printf ''
        return 0
    fi
    local -a props
    readarray -t props <<<"$NAMESERVICE_HA_ARGS"
    local prop out=""
    for prop in "${props[@]}"; do
        [[ -n "$prop" ]] && out+="$prop "
    done
    printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# resolve_active_namenode_hostport: for the same-nameservice-collision case (see main()'s SRC_URI_NS/
# DST_URI_NS doc comment), find the DR/destination side's CURRENTLY ACTIVE NameNode and return its bare
# "host:port" so DST_URI_NS can target it directly, instead of an ambiguous nameservice name.
#
# WHY THIS EXISTS: a bare, real NameNode host:port has none of the ambiguity problems a nameservice NAME
# does in the same-nameservice-collision case (see the SRC_URI_NS aliasing doc comment in main() for the
# full "why", including two confirmed-by-direct-testing failure modes: YARN token renewal/container
# localization cannot resolve a synthetic alias name, and fs.defaultFS becomes ambiguous if the real shared
# name is ever injected as a "-D" property for either side). YARN's RM/NM already know how to renew and
# localize against any concrete host:port using the cluster's normal Kerberos/token machinery, with no name
# ambiguity involved anywhere in the job.
#
# HOW IT WORKS (JMX-based, NOT haadmin): queries each nn-id's own NameNode web UI JMX endpoint directly --
# "http(s)://<host>:<web-port>/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem" -- and reads the
# "tag.HAState" field, exactly the same technique check_cluster_health() already uses elsewhere in this
# script to determine ACTIVE/STANDBY. This was chosen over "hdfs haadmin -getServiceState <alias>.<nn-id>"
# after direct testing showed haadmin does NOT accept ad-hoc "-D" HA properties as a resolvable
# nameservice the way "hdfs dfs"/"hdfs dfsadmin" do: even with the exact same derived HA properties
# haadmin failed with "Illegal argument: Unable to determine service address for namenode
# '<alias>.<nn-id>'" -- HAAdmin's own target-address resolution needs the nameservice statically present
# in hdfs-site.xml, not just passed as generic options. JMX has no such requirement: it is a plain HTTP
# call directly against a concrete host:port (no nameservice, alias, or hdfs-site.xml lookup involved at
# all), so it works identically regardless of whether this node's config knows about the DR nameservice.
#
# CAVEAT (accepted tradeoff, not fixable without a cluster config change): this resolves the active
# NameNode ONCE, near the top of main(). If the DR cluster's own internal NameNode HA fails over WHILE this
# script is running (a real failover of the DR cluster's own two NameNodes, not a DR drill), every
# subsequent hdfs/distcp call in this run would keep targeting the now-standby host and fail with
# "Operation category ... not supported in state standby" -- the operator would need to re-run the script,
# at which point this function re-resolves the (new) active NameNode fresh.
#
# FAILOVER/FAILBACK CORRECTNESS: this function always resolves whichever physical NameNode pair is
# CURRENTLY named by DST_NN_HOSTS -- it has no hardcoded notion of "prod" or "DR". Combined with the
# existing, already-documented operator requirement (see the SRC_NN_HOSTS/DST_NN_HOSTS doc comment above)
# to swap the VALUES of SRC_NN_HOSTS/DST_NN_HOSTS whenever SOURCE_CLUSTER/DEST_CLUSTER are swapped after a
# role reversal, this makes all three DR lifecycle directions work correctly with zero special-casing:
#   Prod -> DR (forward)  : DST_NN_HOSTS = DR's NN pair    -> resolves DR's active NameNode
#   DR -> Prod (failover) : DST_NN_HOSTS = Prod's NN pair  -> resolves Prod's active NameNode
#   Prod -> DR (failback) : DST_NN_HOSTS = DR's NN pair    -> resolves DR's active NameNode (again)
# In every direction, "the destination" is resolved by NAME (SRC_NN_HOSTS/DST_NN_HOSTS content), never by
# which physical cluster the operator mentally considers "production" -- exactly mirroring how
# SOURCE_CLUSTER/DEST_CLUSTER themselves already work as pure role labels elsewhere in this script.
#
# WHICH HTTP SCHEME/PORT: uses DEST_HTTP_SCHEME/DEST_NN_WEB_PORT (the same env vars check_cluster_health
# uses for DEST_CLUSTER) since DST_NN_HOSTS always describes whichever NameService is CURRENTLY the
# destination -- consistent with the FAILOVER/FAILBACK CORRECTNESS note above.
#
# Sets the global RESOLVED_ACTIVE_NN_HOSTPORT ("host:port") on success. FAILS FAST (exit 19) if no nn-id in
# DST_NN_HOSTS reports itself active -- proceeding without a confirmed active target would let every later
# hdfs/distcp call in this run hang or fail with a far more confusing standby-state error deep inside a
# stage, instead of one clear message here.
# -----------------------------------------------------------------------------
resolve_active_namenode_hostport() {
    local nn_hosts="$1"
    RESOLVED_ACTIVE_NN_HOSTPORT=""

    local -a pairs=()
    IFS=',' read -r -a pairs <<<"$nn_hosts"

    local pair nn_id nn_addr nn_host jmx_url jmx_response ha_state
    for pair in "${pairs[@]}"; do
        [[ -z "$pair" ]] && continue
        nn_id="${pair%%=*}"
        nn_addr="${pair#*=}"
        [[ -z "$nn_id" || -z "$nn_addr" ]] && continue
        nn_host="${nn_addr%%:*}"

        jmx_url="${DEST_HTTP_SCHEME}://${nn_host}:${DEST_NN_WEB_PORT}/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem"
        log "[DEBUG] [ACTIVE-NN-RESOLVE] Checking service state of ${nn_id} ($nn_addr) via JMX: $jmx_url"

        if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
            jmx_response=$(curl -ik --silent --max-time 10 --fail --negotiate -u : "$jmx_url" 2>/dev/null || true)
            if [[ -z "$jmx_response" ]] || ! echo "$jmx_response" | grep -q "FSNamesystem"; then
                jmx_response=$(curl -ik --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
            fi
        else
            jmx_response=$(curl -ik --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
        fi

        if [[ -z "$jmx_response" ]] || ! echo "$jmx_response" | grep -q "FSNamesystem"; then
            log "[DEBUG] [ACTIVE-NN-RESOLVE] ${nn_id} ($nn_addr) unreachable or no FSNamesystem JMX bean at $jmx_url"
            continue
        fi

        ha_state=$(echo "$jmx_response" | grep -o '"tag.HAState"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed -E 's/.*"tag.HAState"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/' || true)

        if [[ "${ha_state,,}" == "active" ]]; then
            RESOLVED_ACTIVE_NN_HOSTPORT="$nn_addr"
            log "[INFO] [ACTIVE-NN-RESOLVE] ${nn_id} ($nn_addr) is ACTIVE (via JMX). Using it directly for DST_URI_NS (bypasses the alias for all subsequent hdfs/distcp calls)."
            return 0
        fi
        log "[DEBUG] [ACTIVE-NN-RESOLVE] ${nn_id} ($nn_addr) is not active (HAState: ${ha_state:-<unknown>})"
    done

    echo "[ERROR] Could not find an ACTIVE NameNode among DST_NN_HOSTS ('$nn_hosts') via JMX." >&2
    echo "[ERROR] Verify manually, e.g.: curl -sk \"${DEST_HTTP_SCHEME}://<nn-host>:${DEST_NN_WEB_PORT}/jmx?qry=Hadoop:service=NameNode,name=FSNamesystem\"" >&2
    echo "[ERROR] Every nn-id reported non-active or unreachable -- see [DEBUG] [ACTIVE-NN-RESOLVE] lines" >&2
    echo "[ERROR] above (re-run with DISTCP_DEBUG=yes if those were suppressed) for the per-NameNode detail." >&2
    exit 19
}

# Scan "$@" for ANY "hdfs://" reference (covers both the "-fs hdfs://<ns>" form used by hdfs
# dfs/dfsadmin/snapshotDiff, and the bare "hdfs://<ns>/path" URIs hadoop distcp takes as its trailing
# source/dest args). If AUTO_DERIVE_HA_CLIENT_CONFIG is enabled AND at least one "hdfs://" is referenced, sets the
# global NAMESERVICE_INJECT_ARGS array to the FULL combined property set from NAMESERVICE_HA_ARGS (always the
# same set, covering both clusters -- see the DESIGN note above for why this is no longer a per-cluster
# lookup). Empty array if the feature is disabled or no "hdfs://" URI is referenced at all -- callers can
# always safely prepend this array with zero risk of injecting nothing.
#
# CALLING CONVENTION: plain statement only (same convention as the rest of this script's multi-value-return
# helpers, e.g. resolve_state_file) -- NEVER via command substitution, since this sets a global array, not
# stdout. IMPORTANT (set -e SAFETY): this function is invoked as a bare statement (not inside an
# `if`/`&&`/`while` condition) from run_as_hdfs()/run_as_distcp(), so under `set -e` its OWN exit status
# matters -- if the last command it executes happens to be a false `[[ ... ]]` test, bash treats the whole
# function as having "failed" and aborts the entire script right there. This bit the very first implementation
# here: the inner loop's last statement was `[[ -n "$prop" ]] && NAMESERVICE_INJECT_ARGS+=(...)`, and because
# every stored value ends with a trailing newline, the LAST element `readarray` ever produces is always an
# empty string, whose `[[ -n "" ]]` test is always false -- silently killing the calling hdfs/distcp command
# (and the whole run) under `set -e`. Every branch below therefore ends with an explicit `return 0` so this
# function's exit status is never accidentally determined by the last data-dependent test it happened to
# evaluate.
_collect_nameservice_inject_args() {
    NAMESERVICE_INJECT_ARGS=()
    if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]] || [[ -z "$NAMESERVICE_HA_ARGS" ]]; then
        return 0
    fi

    local arg prop found_hdfs_uri=false
    for arg in "$@"; do
        if [[ "$arg" == hdfs://* ]]; then
            found_hdfs_uri=true
            break
        fi
    done
    if [[ "$found_hdfs_uri" != "true" ]]; then
        return 0
    fi

    # Newline-delimited split -- NOT word splitting -- so a property value can safely contain spaces without
    # fragmenting. See the DESIGN note above. NAMESERVICE_HA_ARGS ends with a trailing newline (every append
    # in derive_nameservice_ha_conf adds one), so `readarray` always yields one trailing empty element, which
    # the "if" below (not a bare "&&") drops without ever letting a false test become this function's final
    # exit status.
    local -a props
    readarray -t props <<<"$NAMESERVICE_HA_ARGS"
    for prop in "${props[@]}"; do
        if [[ -n "$prop" ]]; then
            NAMESERVICE_INJECT_ARGS+=("$prop")
        fi
    done
    return 0
}

# Wrapper function to run commands as HDFS_USER If Kerberos is enabled, run as current user (root) to preserve
# tickets Otherwise, use sudo to switch to HDFS_USER
#
# Also the single choke point for per-NameService HA config injection (AUTO_DERIVE_HA_CLIENT_CONFIG): when
# enabled, any derived "-D..." options for a cluster referenced in "$@" (via "hdfs://<cluster>") are spliced
# in immediately after the subcommand token ("dfs"/"dfsadmin"/"snapshotDiff"), so they are always parsed as
# client-side Hadoop generic options, never mistaken for the subcommand's own positional arguments.
run_as_hdfs() {
    local cmd=("$@")
    _collect_nameservice_inject_args "$@"
    if [[ ${#NAMESERVICE_INJECT_ARGS[@]} -gt 0 ]]; then
        # cmd[0]=hdfs, cmd[1]=dfs|dfsadmin|snapshotDiff, cmd[2..]=rest
        cmd=("${cmd[0]}" "${cmd[1]}" "${NAMESERVICE_INJECT_ARGS[@]}" "${cmd[@]:2}")
    fi
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        # Kerberos enabled: run as current user (root) to preserve tickets
        "${cmd[@]}"
    else
        # Kerberos not enabled: switch to HDFS_USER via sudo
        sudo -u "$HDFS_USER" "${cmd[@]}"
    fi
}

# Wrapper function to run commands as DISTCP_USER with environment preservation If Kerberos is enabled, run as
# current user (root) to preserve tickets Otherwise, use sudo -E to switch to DISTCP_USER while preserving
# environment
#
# Also the single choke point for per-NameService HA config injection for distcp -- see run_as_hdfs's doc
# comment for the full rationale. Here the subcommand token is always "distcp" (cmd[0]=hadoop, cmd[1]=distcp),
# so injected args are spliced in right after it, same positioning logic.
run_as_distcp() {
    local cmd=("$@")
    _collect_nameservice_inject_args "$@"
    if [[ ${#NAMESERVICE_INJECT_ARGS[@]} -gt 0 ]]; then
        cmd=("${cmd[0]}" "${cmd[1]}" "${NAMESERVICE_INJECT_ARGS[@]}" "${cmd[@]:2}")
    fi
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        # Kerberos enabled: run as current user (root) to preserve tickets and environment
        "${cmd[@]}"
    else
        # Kerberos not enabled: switch to DISTCP_USER via sudo -E to preserve environment
        sudo -E -u "$DISTCP_USER" "${cmd[@]}"
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
    echo "$1" | sed 's|/|_|g; s|:|_|g; s|^_||' || echo "$1"
}

# Strip the standalone "-update" token from a space-separated DistCp options string (COPY_OPTS), since -update
# must be repositioned immediately before -diff for an incremental sync rather than left wherever the operator
# placed it in COPY_OPTS.
#
# CRITICAL: must remove ONLY the exact token "-update", never any option/value that merely CONTAINS that
# substring (e.g. a "-D" property whose value is "pre-update-value", or any future Hadoop flag that happens to
# embed "-update" as part of a longer name). The previous implementation here used `sed 's/-update\s*/ /g'`, a
# bare substring replacement that silently corrupted any such token -- splitting it into garbage fragments --
# on every incremental DistCp call. Tokenizing on whitespace and comparing each token for an EXACT match
# avoids this: only a token that is *exactly* "-update" is ever dropped, everything else in COPY_OPTS passes
# through byte-for-byte.
strip_update_flag() {
    local copy_opts="$1"
    local -a tokens=() out=()
    read -r -a tokens <<<"$copy_opts"
    local t
    for t in "${tokens[@]}"; do
        [[ "$t" == "-update" ]] && continue
        out+=("$t")
    done
    echo "${out[*]}"
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
    for f in ${TEMP_FILES[@]+"${TEMP_FILES[@]}"}; do
        if [[ -f "$f" ]]; then
            rm -f "$f" 2>/dev/null && cleaned=$((cleaned + 1)) || true
        fi
    done
    # Only log cleanup in debug mode to reduce output noise
    if [[ $cleaned -gt 0 ]] && [[ "${DISTCP_DEBUG,,}" == "yes" ]]; then
        log "[DEBUG] Cleaned up $cleaned temporary file(s)"
    fi
}

# Resolve the on-disk state file path for a directory, with backward-compatible fallback to the pre-patch path
# that included "-${SNAP_PREFIX}" in the filename.
#
# Historically (pre reverse-diff-bootstrap patch) the state file path was:
#   /var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt
# The current path is:
#   /var/tmp/dr-last-snap-${key}.txt
# Without this fallback, any directory already under replication before this patch would have its real state
# file become invisible: Stage 3 would misclassify an already-baselined, already-syncing directory as
# brand-new and attempt to recreate ${SNAP_PREFIX}_0, which already exists on both clusters and fails loudly.
#
# Resolution order (as of the HDFS_STATE_DIR cross-node-resilience patch):
#   (a) New-format local path, if it exists (already migrated / first run on this patch)
#   (b) Old-format local path, if it exists (pre-patch directory; use as-is, do NOT
#       silently rewrite the path here -- callers that write state always use
#       the new path going forward, which naturally migrates the file on next write)
#   (c) Neither exists locally, but an HDFS mirror exists on SOURCE_CLUSTER or
#       DEST_CLUSTER (see HDFS_STATE_DIR) -> hydrate the local new-path from HDFS,
#       then use the (now-populated) local new-path. NEW in the HDFS_STATE_DIR patch.
#   (d) Nothing anywhere -> truly brand new; new-format path is returned (does not
#       exist), so the caller's own "-f" test correctly reports absence.
#
# This function has ALWAYS been safe to call repeatedly (idempotent, side-effect-free for cases (a)/(b)/(d)).
# It NOW has a side effect for case (c): it writes the local new-path file as a hydration/self-heal step,
# mirroring the existing old-path -> new-path self-migration philosophy already in place for (a)/(b). Callers
# that need to distinguish "truly brand new" from "hydrated from HDFS" MUST call
# resolve_state_file_and_check_new() (below), not just stat the path themselves.
#
# CALLING CONVENTION (load-bearing, do not violate): this function calls log() internally (e.g. the
# [HDFS-STATE-MIRROR] diagnostic lines below), and log() writes to stdout via echo. Calling this function via
# command substitution, e.g. state="$(resolve_state_file "$key")", would capture those log lines as part of
# the "return value" and corrupt it (multi-line garbage instead of a path -- this exact bug was hit in
# production: it caused resolve_state_file's own successful HDFS-mirror hydration to appear as a failure to
# the caller, which then misclassified an already-replicating directory as brand new and re-created a baseline
# snapshot on top of real data). This function instead sets the global RESOLVED_STATE_PATH as its result.
# ALWAYS call it as a plain statement, e.g.:
#     resolve_state_file "$key"
#     state="$RESOLVED_STATE_PATH"
# and NEVER as state="$(resolve_state_file "$key")".
resolve_state_file() {
    local key="$1"
    local new_path="/var/tmp/dr-last-snap-${key}.txt"
    local old_path="/var/tmp/dr-last-snap-${key}-${SNAP_PREFIX}.txt"
    RESOLVED_STATE_PATH=""

    if [[ -f "$new_path" ]]; then
        RESOLVED_STATE_PATH="$new_path"
        return 0
    fi
    if [[ -f "$old_path" ]]; then
        RESOLVED_STATE_PATH="$old_path"
        return 0
    fi

    # Neither local path exists. Before concluding "brand new", check the HDFS mirror on BOTH clusters (not
    # just one) and reconcile:
    #
    # NOTE: mirror_state_file_to_hdfs's "-put -f" is non-atomic (documented KNOWN LIMITATION there), so a read
    # can race an in-flight write and observe a truncated/empty file. This is no longer the safety concern it
    # once was: since direction is derived live from snapshot listings every run (see derive_direction_state),
    # a truncated hydration here can only ever cost a fast-path skip on a later run, never an incorrect
    # direction verdict. _hdfs_mirror_content_is_complete still filters out empty/unreadable content so
    # hydration doesn't write garbage to the local cache.
    #
    # IMPORTANT (divergence): the two clusters' mirrors can also legitimately disagree (not just be truncated)
    # if a prior write's mirror-to-one-cluster step failed (best-effort, logged as [WARN], see
    # mirror_state_file_to_hdfs) or the process died between the two _mirror_one_cluster calls. Simply
    # trusting "whichever cluster we check first" (previously always SOURCE_CLUSTER) could silently pick a
    # STALE mirror over a fresher one on the other cluster, which would only degrade the fast-path hint (never
    # direction safety, which is always re-derived live). Since state only ever advances forward (snapshot
    # index strictly increases on every successful write), when both mirrors are usable and disagree we
    # deterministically prefer whichever one has the HIGHER snapshot index -- no clock/timestamp comparison
    # needed, and this requires reading both mirrors rather than short-circuiting on the first.
    local hydrated_content="" source_candidate="" dest_candidate=""
    local source_usable=false dest_usable=false
    if source_candidate="$(_read_hdfs_state_mirror "$key" "$SRC_URI_NS")" && _hdfs_mirror_content_is_complete "$source_candidate"; then
        source_usable=true
    elif [[ -n "${source_candidate:-}" ]]; then
        log "[WARN] [HDFS-STATE-MIRROR] HDFS mirror on SOURCE_CLUSTER ($SOURCE_CLUSTER) for key=$key looks empty/unreadable (likely raced an in-flight write). Ignoring it rather than hydrating a bogus fast-path hint."
    fi
    if dest_candidate="$(_read_hdfs_state_mirror "$key" "$DST_URI_NS")" && _hdfs_mirror_content_is_complete "$dest_candidate"; then
        dest_usable=true
    elif [[ -n "${dest_candidate:-}" ]]; then
        log "[WARN] [HDFS-STATE-MIRROR] HDFS mirror on DEST_CLUSTER ($DEST_CLUSTER) for key=$key looks truncated/incomplete. Ignoring it."
    fi

    if [[ "$source_usable" == "true" ]] && [[ "$dest_usable" == "true" ]]; then
        if [[ "$source_candidate" == "$dest_candidate" ]]; then
            hydrated_content="$source_candidate"
            log "[INFO] [HDFS-STATE-MIRROR] No local state file for key=$key; found matching HDFS mirrors on both SOURCE_CLUSTER and DEST_CLUSTER. Hydrating local state file from HDFS (self-heal, same philosophy as old-path->new-path migration)."
        else
            local source_idx dest_idx source_snap dest_snap
            source_snap=$(printf '%s' "$source_candidate" | sed -n '1p')
            dest_snap=$(printf '%s' "$dest_candidate" | sed -n '1p')
            source_idx=${source_snap##*_}
            dest_idx=${dest_snap##*_}
            if [[ "$source_idx" =~ ^[0-9]+$ ]] && [[ "$dest_idx" =~ ^[0-9]+$ ]] && ((dest_idx > source_idx)); then
                hydrated_content="$dest_candidate"
                log "[WARN] [HDFS-STATE-MIRROR] Divergent HDFS mirrors for key=$key: SOURCE_CLUSTER has '$source_snap', DEST_CLUSTER has '$dest_snap'. Preferring DEST_CLUSTER's mirror (higher snapshot index = more recent state; state only ever advances forward)."
            else
                hydrated_content="$source_candidate"
                log "[WARN] [HDFS-STATE-MIRROR] Divergent HDFS mirrors for key=$key: SOURCE_CLUSTER has '$source_snap', DEST_CLUSTER has '$dest_snap'. Preferring SOURCE_CLUSTER's mirror (index comparison inconclusive or SOURCE_CLUSTER's index is >= DEST_CLUSTER's)."
            fi
        fi
    elif [[ "$source_usable" == "true" ]]; then
        hydrated_content="$source_candidate"
        log "[INFO] [HDFS-STATE-MIRROR] No local state file for key=$key; found HDFS mirror on SOURCE_CLUSTER ($SOURCE_CLUSTER) (not found/usable on DEST_CLUSTER). Hydrating local state file from HDFS."
    elif [[ "$dest_usable" == "true" ]]; then
        hydrated_content="$dest_candidate"
        log "[INFO] [HDFS-STATE-MIRROR] No local state file for key=$key; found HDFS mirror on DEST_CLUSTER ($DEST_CLUSTER) (not found/usable on SOURCE_CLUSTER). Hydrating local state file from HDFS."
    fi

    if [[ -n "$hydrated_content" ]]; then
        if write_state_file "$new_path" "$hydrated_content" "$key" >/dev/null 2>&1; then
            log "[INFO] [HDFS-STATE-MIRROR] Local state file hydrated at $new_path for key=$key. Subsequent runs on this node will use the fast local path."
        else
            log "[ERROR] [HDFS-STATE-MIRROR] Found HDFS mirror for key=$key but failed to hydrate local file $new_path (local disk write failed -- check disk space/permissions on $(dirname "$new_path")). Proceeding this run using in-memory HDFS content only would be unsafe (caller reads via file path); treating as brand-new would be UNSAFE (would misclassify a directory with real replication history as brand new and re-baseline it). Failing loudly instead."
            echo "[ERROR] Could not hydrate local state file $new_path from HDFS mirror for key=$key (local disk write failed -- check disk space/permissions on $(dirname "$new_path")). Refusing to continue for this key rather than risk misclassifying it as brand-new." >&2
            # Do NOT echo new_path / fall through here: the caller's "-f" check would see it absent (the
            # hydration write just failed) and would misclassify a directory with real history as brand-new,
            # which is exactly the data-loss scenario this whole function exists to prevent. Returning
            # non-zero here instead aborts the run (via set -e at call sites, since RESOLVED_STATE_PATH is
            # left empty below and the caller never reaches a valid path) rather than silently proceeding on a
            # false "brand new" verdict.
            return 1
        fi
    fi

    RESOLVED_STATE_PATH="$new_path"
}

# Read the state mirror content for a given key from a specific cluster's HDFS. Returns the raw content
# (1-line: last common snapshot name) on stdout if found and readable; returns non-zero / empty stdout if not
# found, unreachable, or permission denied. NEVER hard-fails the script -- all failure modes are treated as
# "not found here, try the other cluster / conclude brand new".
_read_hdfs_state_mirror() {
    local key="$1"
    local cluster="$2"
    local uri_path="${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
    local out
    if out=$(run_as_hdfs hdfs dfs -fs "hdfs://${cluster}" -cat "$uri_path" 2>/dev/null); then
        if [[ -n "$out" ]]; then
            printf '%s' "$out"
            return 0
        fi
    fi
    return 1
}

# Validate that HDFS-mirror content read by _read_hdfs_state_mirror is usable before it is trusted for
# hydration.
#
# HISTORICAL NOTE: this function previously required BOTH lines of the old 2-line format (snapshot name +
# recorded SOURCE_CLUSTER) to guard against the documented non-atomic "-put -f" race in
# mirror_state_file_to_hdfs, where a read could observe a truncated, partial write (e.g. only line 1) and
# silently disable direction-reversal protection by hydrating a 1-line file. Now that the state file format is
# 1-line-only by design (last common snapshot name; see the live-snapshot-direction-derivation rework), that
# specific truncation race no longer applies: there is no second line to lose, so a non-empty read is exactly
# as complete as this format ever gets. Direction is derived live from snapshot listings every run regardless
# of what this mirror contains, so a merely-stale (but non-empty) mirror content here can only ever cost a
# fast-path skip, never a wrong safety decision. Returns 0 if content is non-empty.
_hdfs_mirror_content_is_complete() {
    local content="$1"
    local first_line
    first_line=$(printf '%s' "$content" | sed -n '1p')
    [[ -n "$first_line" ]]
}

# Resolve the state file path AND explicitly report whether this directory is "truly brand new" (case (d): no
# local file, no HDFS mirror on either cluster) vs. "has history somewhere" (cases (a)/(b)/(c)). Stage 3's
# baseline gate and any other "is this brand new" decision point MUST use this function instead of a bare "[[
# ! -f \"$state\" ]]" check on resolve_state_file's return value, because after the HDFS_STATE_DIR patch a
# directory can have ZERO local presence and still be a real, already-replicating directory (case (c)).
#
# Sets the globals IS_BRAND_NEW_DIR ("true"/"false") and RESOLVED_STATE_FILE (the resolved state file path) as
# side effects (bash has no multi-return without globals/nameref gymnastics; a global is the simplest, most
# auditable option here given the rest of the script's existing style, e.g. DISTCP_SUCCESS, ALL_OK, etc. are
# all similarly global).
#
# IMPORTANT: this function MUST be called as a plain statement, e.g.:
#     resolve_state_file_and_check_new "$key"
#     state="$RESOLVED_STATE_FILE"
# and NEVER as a command substitution, e.g. state="$(resolve_state_file_and_check_new "$key")", which would
# run the entire function body (including the IS_BRAND_NEW_DIR assignment) inside a subshell -- the assignment
# would then be discarded when the subshell exits and never reach the caller, leaving IS_BRAND_NEW_DIR
# unset/stale in the parent shell (an unbound-variable abort under `set -u`).
#
# Important correctness note on hydration ordering: after resolve_state_file runs, if hydration happened,
# $new_path now exists on local disk with the HDFS-sourced content, so the "-f" check below correctly reports
# IS_BRAND_NEW_DIR=false -- this is the load-bearing mechanic. The hydration write happens inside
# resolve_state_file itself, which runs first here.
resolve_state_file_and_check_new() {
    local key="$1"
    local state_file
    resolve_state_file "$key"
    state_file="$RESOLVED_STATE_PATH"
    if [[ -n "$state_file" ]] && [[ -f "$state_file" ]]; then
        IS_BRAND_NEW_DIR="false"
    else
        IS_BRAND_NEW_DIR="true"
    fi
    RESOLVED_STATE_FILE="$state_file"
}

# -----------------------------------------------------------------------------
# confirm_brand_new_against_live_snapshots: corroborate IS_BRAND_NEW_DIR against LIVE snapshot listings on both
# clusters before Stage 3 is allowed to create a ${SNAP_PREFIX}_0 baseline.
#
# WHY THIS EXISTS (data-loss hole this closes): IS_BRAND_NEW_DIR is derived purely from state-file PRESENCE --
# three [[ -f ]]/-cat probes (local path, old local path, both HDFS mirrors). "No state file anywhere" was then
# used as a proxy for "this directory has never been replicated", but those are NOT the same statement. Lose all
# three copies at once (node rebuilt + /var/tmp wiped + an HDFS_STATE_DIR cleanup, or a fresh node during a
# failover before any mirror was readable) and the proxy lies, with two outcomes:
#
#   (1) ${SNAP_PREFIX}_0 still exists on both clusters -> createSnapshot returns "already a snapshot with the
#       same name", Stage 3 treats that as idempotent success, and (AUTO_FULL_DISTCP=yes) a needless FULL copy
#       of an already-synced directory runs. Wasteful, but recoverable.
#   (2) ${SNAP_PREFIX}_0 was already pruned by retention (SNAP_RETAIN defaults to 3, and cleanup deletes
#       oldest-first, so index 0 is the FIRST to go) -> a FRESH ${SNAP_PREFIX}_0 is created on each cluster
#       capturing each side's CURRENT, DIVERGENT content. On the next run, ${SNAP_PREFIX}_1 is absent from the
#       destination too (also pruned), so verify_cached_snap_fast_path CONFIRMS the bogus baseline and Stage 4
#       runs "distcp -diff ${SNAP_PREFIX}_0 ${SNAP_PREFIX}_1". Every source change made between the last real
#       sync and the state loss lives INSIDE source's new ${SNAP_PREFIX}_0, so it is never in the diff and is
#       never copied -- a SILENT data gap on DR, with no error raised on any run.
#
# The fix is to stop treating cache absence as evidence about the clusters, and instead ask the clusters, using
# the same live listing-and-intersection algorithm Stage 4 already trusts for direction safety
# (derive_direction_state). A snapshot present on BOTH clusters is proof of real replication history no matter
# what the state cache says or doesn't say.
#
# Sets (globals; plain-statement calling convention -- this function calls log() internally and MUST NOT be
# invoked via command substitution, same rule as derive_direction_state / resolve_state_file):
#   BRAND_NEW_VERDICT        - "new"         genuinely brand new; safe to baseline.
#                              "has_history" real shared history exists; the state cache was lost. Caller must
#                                            REHYDRATE state from $BRAND_NEW_RECOVERED_SNAP and NOT baseline.
#                              "unsafe"      cannot confirm; caller MUST NOT baseline (fail the directory).
#   BRAND_NEW_VERDICT_REASON - human-readable reason, for logs and operator output.
#   BRAND_NEW_RECOVERED_SNAP - live last common snapshot name; set only for "has_history".
#
# Returns 0 always -- the verdict is the output, not the exit status.
# -----------------------------------------------------------------------------
confirm_brand_new_against_live_snapshots() {
    local d="$1"
    BRAND_NEW_VERDICT="unsafe"
    BRAND_NEW_VERDICT_REASON=""
    BRAND_NEW_RECOVERED_SNAP=""

    # Operator escape hatch: the documented manual-recovery procedures (no-common-snapshot, split-brain,
    # direction reversal) deliberately clear state to force a re-baseline. Those procedures also instruct
    # deleting every ${SNAP_PREFIX}_* snapshot on both clusters, which would make the live check below agree
    # anyway -- but FORCE_REBASELINE=yes lets an operator who has confirmed the authoritative side proceed
    # without that step. See the FORCE_REBASELINE block near the top of this script.
    if [[ "${FORCE_REBASELINE,,}" == "yes" ]]; then
        BRAND_NEW_VERDICT="new"
        BRAND_NEW_VERDICT_REASON="FORCE_REBASELINE=yes -- live snapshot confirmation deliberately bypassed by operator"
        log "[WARN] [BRAND-NEW-GATE] $d: FORCE_REBASELINE=yes -- skipping live snapshot confirmation and treating this directory as brand new. This creates ${SNAP_PREFIX}_0 and triggers a FULL copy that overwrites the destination."
        return 0
    fi

    derive_direction_state "$d"

    # Fail closed on an unreadable listing. Baselining blind is exactly outcome (2) above; also catches the case
    # where Stage 2's allowSnapshot failed (logged there as a [WARN], non-fatal), which leaves "$d/.snapshot"
    # nonexistent and unlistable on that cluster.
    if [[ "$DIRECTION_STATE_OK" != "true" ]]; then
        BRAND_NEW_VERDICT="unsafe"
        BRAND_NEW_VERDICT_REASON="live snapshot listing failed on one or both clusters (see the [ERROR] [DIRECTION-DERIVE] lines above; if Stage 2 reported an allowSnapshot [WARN] for this directory, fix that first)"
        return 0
    fi

    # THE LOAD-BEARING CHECK: a snapshot present on both clusters is real shared replication history.
    if ((LAST_COMMON_SNAP_INDEX >= 0)); then
        BRAND_NEW_VERDICT="has_history"
        BRAND_NEW_RECOVERED_SNAP="$LAST_COMMON_SNAP_NAME"
        BRAND_NEW_VERDICT_REASON="live listings show '$LAST_COMMON_SNAP_NAME' present on BOTH clusters -- this directory has real replication history despite its state cache being absent"
        return 0
    fi

    # No shared snapshot, but one side has history: divergence, not a fresh directory. Baselining here would
    # copy SOURCE over a destination that may hold the only copy of something.
    if [[ "$SPLIT_BRAIN_DETECTED" == "true" ]]; then
        BRAND_NEW_VERDICT="unsafe"
        BRAND_NEW_VERDICT_REASON="both clusters hold ${SNAP_PREFIX}_* snapshots but share none -- independent divergence, not a fresh directory"
        return 0
    fi
    if [[ "$DIRECTION_REVERSED" == "true" ]]; then
        BRAND_NEW_VERDICT="unsafe"
        BRAND_NEW_VERDICT_REASON="DEST_CLUSTER holds ${SNAP_PREFIX}_* snapshots that SOURCE_CLUSTER lacks, with no shared snapshot -- DEST_CLUSTER may be the authoritative side (post-failover), so baselining would overwrite it"
        return 0
    fi

    # No shared snapshot and no destination-side history: either both sides are clean, or only SOURCE has
    # leftover snapshots with no common point. Both genuinely need a full baseline.
    BRAND_NEW_VERDICT="new"
    BRAND_NEW_VERDICT_REASON="no ${SNAP_PREFIX}_* snapshot is shared by both clusters and DEST_CLUSTER has no snapshot history -- genuinely brand new"
    return 0
}

# Idempotently ensure ${HDFS_STATE_DIR} exists on the given cluster. Best-effort: logs [WARN] and returns 0
# (never aborts the script) on any failure -- an unreachable cluster, permission denied, or any other mkdir
# error just means the cross-node LAST-SNAP PERFORMANCE-HINT CACHE mirror is degraded for this run; local-disk
# operation is entirely unaffected and continues normally.
#
# NOTE (post live-direction-derivation rework): this directory no longer holds any value used for
# safety-critical direction determination. It only caches the last common snapshot NAME as an optimistic
# fast-path hint (see verify_cached_snap_fast_path / derive_direction_state) to avoid a live double-listing of
# .snapshot on both clusters on every run. A missing or stale mirror here never produces a wrong direction
# verdict -- it only means this run falls through to the full live listing-and-intersection algorithm, which
# is slower but always correct and always attempted before any safety-critical decision.
ensure_hdfs_state_dir() {
    local cluster="$1"
    local label="$2"
    local mkdir_err="/tmp/pulse_replication_action_mkdir_err_$$.log"
    if run_as_hdfs hdfs dfs -fs "hdfs://${cluster}" -mkdir -p "${HDFS_STATE_DIR}" 2>"$mkdir_err"; then
        log "[DEBUG] [HDFS-STATE-MIRROR] Confirmed/created ${HDFS_STATE_DIR} on $label cluster ($cluster)"
    else
        log "[WARN] [HDFS-STATE-MIRROR] Could not create/confirm ${HDFS_STATE_DIR} on $label cluster ($cluster). HDFS state mirroring will be unavailable for this run on this cluster (cross-node failover convenience degraded); LOCAL state file operation is unaffected and this run continues normally."
        [[ -s "$mkdir_err" ]] && log "[WARN] [HDFS-STATE-MIRROR] mkdir stderr: $(tr '\n' ' ' <"$mkdir_err")"
        METRICS_HDFS_MIRROR_FAILURES=$((METRICS_HDFS_MIRROR_FAILURES + 1))
    fi
    rm -f "$mkdir_err" 2>/dev/null || true
    return 0
}

# Atomic state file write to prevent corruption, PLUS best-effort HDFS mirror on both clusters for cross-node
# failover resilience.
#
# Local write remains the authoritative, synchronous, atomic operation and is unchanged in behavior/semantics
# from before this patch: if it fails, this function fails (return 1) exactly as before, and callers treat
# that exactly as before (log [ERROR], do not advance in-memory expectations further).
#
# The HDFS mirror write is DELIBERATELY best-effort and non-fatal: it runs only after the local write has
# already succeeded, and any failure there (network partition, permission issue, path not yet created) is
# logged as [WARN] and swallowed. It must NEVER cause this function to return non-zero, and it must NEVER
# cause the calling directory's sync to be marked failed -- the local state file is still fully authoritative
# for continued operation on THIS node. The HDFS copy is a cross-node convenience mirror only.
#
# Requires: $key (state file key, same value used to build $state_file's basename by the caller) to be passed
# explicitly, since HDFS mirror paths are keyed the same way as local paths but live in a different directory.
write_state_file() {
    local state_file="$1"
    local content="$2"
    local key="$3"
    local tmp_file="${state_file}.tmp.$$"
    if echo "$content" >"$tmp_file" && mv "$tmp_file" "$state_file"; then
        : # local write success
    else
        log "[ERROR] Failed to write state file $state_file"
        rm -f "$tmp_file" 2>/dev/null || true
        return 1
    fi

    # Best-effort HDFS mirror on BOTH clusters. Never fails the caller.
    mirror_state_file_to_hdfs "$key" "$content"
    return 0
}

# Mirror state content to the HDFS-side state directory on BOTH SOURCE_CLUSTER and DEST_CLUSTER. Best-effort:
# every failure is a [WARN], never a hard error. Uses a local temp file + "hdfs dfs -put -f" (overwrite) per
# cluster, since HDFS has no atomic rename-based overwrite equivalent to local `mv` that we rely on elsewhere;
# -put -f is the accepted (non-atomic) tradeoff here.
#
# PURPOSE (post live-direction-derivation rework): this mirror is a performance hint only -- a cross-node
# cache of the last common snapshot name, consulted by verify_cached_snap_fast_path to avoid a live
# double-listing of .snapshot on both clusters when nothing has changed. It is NOT a source of truth for
# direction/safety decisions; those are always derived live from .snapshot listings on both clusters
# (derive_direction_state). KNOWN LIMITATION: a reader could observe a truncated/partial file on the HDFS side
# if a read races an in-flight -put on that exact path. This is considered acceptable: the local state file
# remains authoritative for the node that just wrote it, and the HDFS mirror is a convenience path used only
# when local state is ABSENT (a different node), not concurrently written by two nodes for the same directory
# in normal operation. Since the mirrored content is now 1-line-only, a truncated read is simply empty/short,
# not "missing the second line" -- see _hdfs_mirror_content_is_complete.
mirror_state_file_to_hdfs() {
    local key="$1"
    local content="$2"
    local mirror_tmp="/tmp/pulse_replication_action_mirror_${key}_$$.tmp"
    TEMP_FILES+=("$mirror_tmp")

    if ! printf '%s' "$content" >"$mirror_tmp" 2>/dev/null; then
        log "[WARN] [HDFS-STATE-MIRROR] Could not create local temp file $mirror_tmp for HDFS mirror write (key=$key). Skipping HDFS mirror this run; local state is unaffected."
        METRICS_HDFS_MIRROR_FAILURES=$((METRICS_HDFS_MIRROR_FAILURES + 1))
        return 0
    fi

    _mirror_one_cluster "$key" "$mirror_tmp" "$SRC_URI_NS" "SOURCE"
    _mirror_one_cluster "$key" "$mirror_tmp" "$DST_URI_NS" "DEST"

    rm -f "$mirror_tmp" 2>/dev/null || true
}

# Single-cluster helper for mirror_state_file_to_hdfs. Split into two plain calls (rather than a colon-packed
# "$cluster:$label" pair looped over) because SOURCE_CLUSTER/DEST_CLUSTER are typically "host:port" -- packing
# "$cluster:$label" into one string and splitting on ":" would break on the port's own colon. Two explicit
# calls avoid that fragility entirely.
_mirror_one_cluster() {
    local key="$1" mirror_tmp="$2" cluster="$3" label="$4"
    local dest_uri="hdfs://${cluster}${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
    local put_err="/tmp/mirror_put_err_${key}_$$.log"
    if run_as_hdfs hdfs dfs -fs "hdfs://${cluster}" -put -f "$mirror_tmp" "${HDFS_STATE_DIR}/dr-last-snap-${key}.txt" 2>"$put_err"; then
        log "[DEBUG] [HDFS-STATE-MIRROR] Mirrored state for key=$key to $label cluster ($cluster): $dest_uri"
    else
        log "[WARN] [HDFS-STATE-MIRROR] Failed to mirror state for key=$key to $label cluster ($cluster) at $dest_uri. NON-FATAL: local state file remains authoritative; this directory's sync is unaffected. Cross-node failover convenience is degraded for this directory until a mirror write succeeds."
        [[ -s "$put_err" ]] && log "[WARN] [HDFS-STATE-MIRROR] hdfs -put stderr: $(tr '\n' ' ' <"$put_err")"
        METRICS_HDFS_MIRROR_FAILURES=$((METRICS_HDFS_MIRROR_FAILURES + 1))
    fi
    rm -f "$put_err" 2>/dev/null || true
}

# Read snapshot name (line 1) from a state file. Works for old (1-line) and new (2-line) formats -- only ever
# reads line 1, by construction, so it is agnostic to whatever else may follow it.
read_state_snapshot() {
    local state_file="$1"
    head -n 1 "$state_file"
}

# DEPRECATED / REMOVED: read_state_last_source() used to read line 2 (a cached "recorded SOURCE_CLUSTER at
# last write" label) so Stage 4 could compare it against the current SOURCE_CLUSTER to detect a direction
# reversal. That mechanism is exactly the staleness-prone cache this rework replaces: a node with a stale
# local/mirrored copy of this field could report "not reversed" when the live snapshot state on both clusters
# said otherwise. Direction is now derived live every run from actual .snapshot listings/existence checks on
# both clusters (see derive_direction_state / verify_cached_snap_fast_path), never from a cached label. This
# function has been deleted; nothing calls it.

# Build the state file content: last common snapshot name only (1 line). The previously-included second line
# (recorded SOURCE_CLUSTER at write time) has been removed -- direction is now derived live from snapshot
# state on both clusters every run (see derive_direction_state), never cached, so writing it here would be
# actively misleading to a future maintainer.
build_state_content() {
    local snap_name="$1"
    printf '%s' "$snap_name"
}

# Cleanup old snapshots on a cluster (reduces code duplication) Only removes snapshots matching the current
# SNAP_PREFIX to avoid deleting snapshots from other replication directions (e.g., forward vs failover)
cleanup_old_snapshots() {
    local cluster="$1"
    local d="$2"
    local cluster_name="$3"
    local snap_retain="$4"
    local snap_prefix="$5"

    log "[DEBUG] Cleaning old snapshots on $cluster_name cluster for $d (prefix: ${snap_prefix})"

    # Fail-closed check on the listing itself, same pattern derive_direction_state
    # uses for its safety-critical listing: check hdfs dfs -ls's OWN exit code via
    # PIPESTATUS[0], NOT stderr emptiness (unreliable). Without this, a failed/
    # unreachable -ls here was previously indistinguishable from "directory
    # genuinely has zero snapshots," silently skipping retention cleanup with
    # only a [DEBUG]-level "No snapshots to remove" line -- no operator-visible
    # warning that anything was actually wrong. This function's cleanup is
    # cosmetic/best-effort (unlike direction derivation), so a failed listing
    # here still does NOT abort the run or fail the directory -- it just skips
    # this cluster's cleanup for this run (retention simply catches up next
    # time) and now logs a clear [WARN] instead of a misleadingly normal DEBUG.
    #
    # IMPORTANT: the pipeline below MUST run as a plain foreground statement --
    # never via `mapfile -t x < <(pipeline)` (PIPESTATUS after that reflects
    # mapfile's OWN exit status, always 0, never the inner pipeline's) nor via
    # `out=$(pipeline)` (PIPESTATUS after a command substitution collapses to a
    # single value -- the LAST stage's exit code, e.g. grep's "no match" exit 1,
    # indistinguishable from a real -ls failure). Both forms were tried and
    # verified broken; see derive_direction_state's matching fix for the full
    # explanation. The pipeline is wrapped in `if ...; then :; fi` rather than
    # `|| true` for the same reason -- under this script's `set -euo pipefail`,
    # a bare `|| true` suffix ALSO destroys PIPESTATUS, while an `if` condition
    # is exempt from `set -e` and leaves PIPESTATUS undisturbed.
    local cleanup_ls_err="/tmp/pulse_replication_action_cleanup_ls_err_$$.log"
    local cleanup_ls_out="/tmp/pulse_replication_action_cleanup_ls_out_$$.log"
    TEMP_FILES+=("$cleanup_ls_err" "$cleanup_ls_out")
    local cleanup_ls_rc
    if run_as_hdfs hdfs dfs -fs "hdfs://$cluster" -ls "$d/.snapshot" 2>"$cleanup_ls_err" |
        awk '$1 ~ /^d/ {print $6, $7, $8}' | sort | awk -F/ '{print $NF}' |
        grep "^${snap_prefix}_" >"$cleanup_ls_out"; then
        :
    fi
    cleanup_ls_rc="${PIPESTATUS[0]}"

    if [[ "$cleanup_ls_rc" -ne 0 ]]; then
        log "[WARN] Could not list snapshots on $cluster_name cluster ($cluster) for $d (hdfs dfs -ls exit code $cleanup_ls_rc). stderr: $(tr '\n' ' ' <"$cleanup_ls_err")"
        log "[WARN] Skipping snapshot retention cleanup on $cluster_name for $d this run -- this does NOT fail the directory; retention will catch up on a future successful run. If this persists, check connectivity/permissions to $cluster_name."
        rm -f "$cleanup_ls_err" "$cleanup_ls_out" 2>/dev/null || true
        return 0
    fi
    mapfile -t snaps <"$cleanup_ls_out"
    rm -f "$cleanup_ls_err" "$cleanup_ls_out" 2>/dev/null || true

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

# -----------------------------------------------------------------------------
# derive_direction_state: derive replication-direction state for directory $d purely from LIVE snapshot
# listings on both clusters -- never from a cached label. Ground truth: a snapshot either exists on a cluster
# or it does not.
#
# Sets (globals, plain-statement calling convention -- see bug #1 note, this function calls log() internally
# and MUST NOT be invoked via command substitution):
#   LAST_COMMON_SNAP_INDEX   - integer, highest snapshot index present on BOTH
#                              clusters, or -1 if no common index exists.
#   LAST_COMMON_SNAP_NAME    - "${SNAP_PREFIX}_${LAST_COMMON_SNAP_INDEX}", or ""
#                              if LAST_COMMON_SNAP_INDEX=-1.
#   DIRECTION_REVERSED       - "true"/"false". true iff DEST_CLUSTER has
#                              indices > LAST_COMMON_SNAP_INDEX that
#                              SOURCE_CLUSTER lacks, and SOURCE_CLUSTER has
#                              none beyond it.
#   SPLIT_BRAIN_DETECTED     - "true"/"false". true iff BOTH clusters have
#                              indices > LAST_COMMON_SNAP_INDEX that the other
#                              lacks.
#   DIRECTION_STATE_OK       - "true"/"false". false means the live listing
#                              itself failed/was unreachable on either
#                              cluster -- caller MUST fail closed (abort this
#                              directory) rather than use any other global
#                              above, all of which are UNDEFINED when this is
#                              "false".
#
# Returns 0 always (errors are reported via DIRECTION_STATE_OK, not via exit status), so callers must check
# DIRECTION_STATE_OK explicitly and not rely on `if derive_direction_state ...; then`.
#
# CALLING CONVENTION: plain statement only, e.g.:
#     derive_direction_state "$d"
#     if [[ "$DIRECTION_STATE_OK" != "true" ]]; then ...abort... fi
# -----------------------------------------------------------------------------
derive_direction_state() {
    local d="$1"
    LAST_COMMON_SNAP_INDEX=-1
    LAST_COMMON_SNAP_NAME=""
    DIRECTION_REVERSED="false"
    SPLIT_BRAIN_DETECTED="false"
    DIRECTION_STATE_OK="false"

    local src_ls_err="/tmp/pulse_replication_action_snaplist_src_$$.log"
    local dst_ls_err="/tmp/pulse_replication_action_snaplist_dst_$$.log"
    local src_ls_out="/tmp/pulse_replication_action_snaplist_src_out_$$.log"
    local dst_ls_out="/tmp/pulse_replication_action_snaplist_dst_out_$$.log"
    TEMP_FILES+=("$src_ls_err" "$dst_ls_err" "$src_ls_out" "$dst_ls_out")

    # Fail-closed check: distinguish "-ls succeeded, zero snapshots matched prefix" (legitimately empty
    # directory listing / no snapshots yet) from "the underlying hdfs dfs -ls itself errored" (unreachable
    # cluster, permission denied, directory missing). We check hdfs dfs -ls's OWN exit code via PIPESTATUS[0]
    # -- NOT stderr content/emptiness, which is unreliable (a hung connection, timeout, or some failure modes
    # can produce empty stderr, which would let a masked failure slip through as "zero snapshots" and silently
    # mislead the safety-critical derivation below).
    #
    # IMPORTANT (a real bug found and fixed here): the ORIGINAL implementation ran this pipeline via
    # `mapfile -t src_snaps < <( pipeline | grep ... || true )` and then read PIPESTATUS[0] -- but
    # PIPESTATUS after `mapfile ... < <(...)` reflects mapfile's OWN exit status (always 0 on a
    # successful read), NEVER the inner process-substitution pipeline's exit codes. A plain
    # `out=$(pipeline)` command substitution has the SAME problem for a different reason: PIPESTATUS
    # after `var=$(...)` collapses to a single value (the substitution's own exit status, which for a
    # multi-stage pipeline is only the LAST stage's code -- e.g. grep's "no match" exit 1, indistinguishable
    # from a real hdfs dfs -ls failure). Both forms made this "safety-critical" fail-closed check
    # completely inert: a genuinely failed/unreachable -ls was silently treated as "zero snapshots found"
    # instead of failing closed, exactly the failure mode this check exists to prevent.
    #
    # The FIX: run the pipeline as a plain FOREGROUND statement (no `<()` process substitution, no `$()`
    # command substitution) redirecting stdout straight to a file, and read PIPESTATUS[0] immediately
    # after -- this is the only form that actually preserves the real per-stage exit codes. The pipeline
    # is wrapped in `if ...; then :; fi` rather than appending `|| true`, because under this script's
    # `set -euo pipefail`, a bare `|| true` suffix ALSO destroys PIPESTATUS the same way `$()` does,
    # while an `if` condition is exempt from `set -e` and leaves PIPESTATUS completely undisturbed (both
    # empirically verified). The array of matched snapshot names is then read from the file separately.
    local src_snaps=() dst_snaps=()
    local src_ls_rc dst_ls_rc
    if run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -ls "$d/.snapshot" 2>"$src_ls_err" |
        awk '$1 ~ /^d/ {print $6, $7, $8}' | sort | awk -F/ '{print $NF}' |
        grep "^${SNAP_PREFIX}_" >"$src_ls_out"; then
        :
    fi
    src_ls_rc="${PIPESTATUS[0]}"
    mapfile -t src_snaps <"$src_ls_out"

    if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "$d/.snapshot" 2>"$dst_ls_err" |
        awk '$1 ~ /^d/ {print $6, $7, $8}' | sort | awk -F/ '{print $NF}' |
        grep "^${SNAP_PREFIX}_" >"$dst_ls_out"; then
        :
    fi
    dst_ls_rc="${PIPESTATUS[0]}"
    mapfile -t dst_snaps <"$dst_ls_out"

    if [[ "$src_ls_rc" -ne 0 ]]; then
        log "[ERROR] [DIRECTION-DERIVE] Could not list snapshots on SOURCE_CLUSTER ($SOURCE_CLUSTER) for $d (hdfs dfs -ls exit code $src_ls_rc). stderr: $(tr '\n' ' ' <"$src_ls_err")"
        log "[ERROR] [DIRECTION-DERIVE] Cannot safely determine replication direction for $d without a live snapshot listing on both clusters. Failing closed."
        return 0
    fi
    if [[ "$dst_ls_rc" -ne 0 ]]; then
        log "[ERROR] [DIRECTION-DERIVE] Could not list snapshots on DEST_CLUSTER ($DEST_CLUSTER) for $d (hdfs dfs -ls exit code $dst_ls_rc). stderr: $(tr '\n' ' ' <"$dst_ls_err")"
        log "[ERROR] [DIRECTION-DERIVE] Cannot safely determine replication direction for $d without a live snapshot listing on both clusters. Failing closed."
        return 0
    fi

    # Build index sets (numeric suffix after last underscore).
    local -A src_idx_set=() dst_idx_set=()
    local s idx
    for s in "${src_snaps[@]}"; do
        idx="${s##*_}"
        [[ "$idx" =~ ^[0-9]+$ ]] && src_idx_set["$idx"]=1
    done
    for s in "${dst_snaps[@]}"; do
        idx="${s##*_}"
        [[ "$idx" =~ ^[0-9]+$ ]] && dst_idx_set["$idx"]=1
    done

    # Last common index = highest index present in both sets.
    local common_max=-1
    for idx in "${!src_idx_set[@]}"; do
        if [[ -n "${dst_idx_set[$idx]:-}" ]] && ((idx > common_max)); then
            common_max=$idx
        fi
    done

    # Indices strictly beyond common_max, per side.
    local src_beyond=false dst_beyond=false
    for idx in "${!src_idx_set[@]}"; do
        ((idx > common_max)) && src_beyond=true
    done
    for idx in "${!dst_idx_set[@]}"; do
        ((idx > common_max)) && dst_beyond=true
    done

    LAST_COMMON_SNAP_INDEX=$common_max
    if ((common_max >= 0)); then
        LAST_COMMON_SNAP_NAME="${SNAP_PREFIX}_${common_max}"
    fi

    if [[ "$src_beyond" == "true" ]] && [[ "$dst_beyond" == "true" ]]; then
        SPLIT_BRAIN_DETECTED="true"
        log "[ERROR] [DIRECTION-DERIVE] Split-brain for $d: both SOURCE_CLUSTER and DEST_CLUSTER have snapshot indices beyond the last common index ($common_max) that the other side lacks."
    elif [[ "$dst_beyond" == "true" ]]; then
        DIRECTION_REVERSED="true"
        log "[INFO] [DIRECTION-DERIVE] Direction reversal signal for $d: DEST_CLUSTER ($DEST_CLUSTER) has snapshot indices beyond the last common index ($common_max) that SOURCE_CLUSTER ($SOURCE_CLUSTER) lacks -- DEST_CLUSTER was acting as source more recently."
    elif [[ "$src_beyond" == "true" ]]; then
        log "[DEBUG] [DIRECTION-DERIVE] Normal forward continuation for $d: SOURCE_CLUSTER has snapshot indices beyond the last common index ($common_max); DEST_CLUSTER has none beyond it."
    else
        log "[DEBUG] [DIRECTION-DERIVE] No advancement beyond last common index ($common_max) for $d on either side."
    fi

    DIRECTION_STATE_OK="true"
    rm -f "$src_ls_err" "$dst_ls_err" 2>/dev/null || true
    return 0
}

# -----------------------------------------------------------------------------
# snapshot_content_signature: cheap content fingerprint for a single snapshot path, used to catch the case
# where a snapshot with the SAME NAME exists on both clusters but was cut at a DIFFERENT point in time (e.g.
# Stage 3's baseline is created on source and destination via two independent, non-atomic -createSnapshot
# calls with no copy in between -- a write landing on source between the two calls is silently captured in
# source's snapshot but not destination's, even though both snapshots share a name/index).
#
# Every other check in this script (verify_cached_snap_fast_path's -test -e, derive_direction_state's
# index-set comparison) treats name/index equality as a proxy for content equality. That proxy is usually
# true but is NOT guaranteed by HDFS, and nothing previously re-verified it -- a diverged pair of
# same-named snapshots was silently trusted forever, every run, with distcp -diff computing an empty (or
# wrong) delta against it.
#
# Uses "hdfs dfs -count -q" (dir count, file count, content size) as the fingerprint: cheap (single NN call,
# no data read), and sufficient to catch an added/removed/resized file -- which is exactly the failure mode
# seen (5 extra files present on one side's snapshot but not the other's). Prints "" (and returns non-zero)
# if the count itself fails, so callers can fail safe (treat an unreadable snapshot as "cannot confirm
# parity") rather than comparing garbage.
# -----------------------------------------------------------------------------
snapshot_content_signature() {
    local cluster_uri="$1"
    local snapshot_path="$2"
    local out
    if ! out=$(run_as_hdfs hdfs dfs -fs "$cluster_uri" -count -q "$snapshot_path" 2>/dev/null); then
        return 1
    fi
    # Columns: QUOTA REM_QUOTA SPACE_QUOTA REM_SPACE_QUOTA DIR_COUNT FILE_COUNT CONTENT_SIZE PATHNAME
    # Only the last three (DIR_COUNT, FILE_COUNT, CONTENT_SIZE) reflect actual data; quotas are unrelated to
    # content and would otherwise mask a real mismatch if they happened to differ for unrelated reasons.
    printf '%s' "$out" | awk '{print $(NF-3), $(NF-2), $(NF-1)}'
}

# Compares the content signature of the SAME-NAMED snapshot on both clusters. Returns 0 (parity confirmed)
# only if both signatures were readable AND identical; returns 1 otherwise (mismatch OR unreadable -- both
# treated as "cannot confirm parity", never as "assume it's fine"). On mismatch, logs an [ERROR] with both
# signatures so the operator can see exactly what diverged without re-deriving it by hand.
verify_snapshot_content_parity() {
    local d="$1"
    local snap="$2"
    local src_sig dst_sig
    src_sig=$(snapshot_content_signature "hdfs://$SRC_URI_NS" "$d/.snapshot/$snap") || {
        log "[WARN] [CONTENT-PARITY] Could not read content signature for '$snap' on SOURCE_CLUSTER ($SRC_URI_NS) -- cannot confirm parity for $d."
        return 1
    }
    dst_sig=$(snapshot_content_signature "hdfs://$DST_URI_NS" "$d/.snapshot/$snap") || {
        log "[WARN] [CONTENT-PARITY] Could not read content signature for '$snap' on DEST_CLUSTER ($DST_URI_NS) -- cannot confirm parity for $d."
        return 1
    }
    if [[ "$src_sig" != "$dst_sig" ]]; then
        log "[ERROR] [CONTENT-PARITY] Snapshot '$snap' for $d has the SAME NAME on both clusters but DIFFERENT content (DIR_COUNT FILE_COUNT CONTENT_SIZE) -- SOURCE: [$src_sig]  DEST: [$dst_sig]. This snapshot cannot be trusted as a common reference point."
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# verify_cached_snap_fast_path: optimistic, LIVE-VERIFIED fast path to avoid a full derive_direction_state
# double-listing when the cached last_snap is still confirmed current. NEVER trusted blindly -- every field it
# reports is backed by a live "hdfs dfs -test -e" check performed THIS run, not by assuming the cache is
# correct. See derive_direction_state for the fallback full algorithm this defers to when the fast path cannot
# confirm safety.
#
# Sets (plain-statement calling convention, same rules as derive_direction_state):
#   FAST_PATH_CONFIRMED   - "true"/"false". true only if the cached snapshot
#                           exists on BOTH clusters AND dest has not advanced
#                           beyond it. false means "fall through to
#                           derive_direction_state" (this is a normal, expected,
#                           non-error outcome, e.g. first run after a real
#                           advance -- NOT a failure).
#   LAST_COMMON_SNAP_INDEX, LAST_COMMON_SNAP_NAME - set to the cached snapshot's
#                           values ONLY when FAST_PATH_CONFIRMED="true";
#                           otherwise left unset/stale and MUST NOT be read by
#                           the caller (caller must call derive_direction_state
#                           next, which overwrites them properly).
#
# Takes the cached snapshot name (already read from local state file line 1 by the caller) as $2. Fails safe:
# any -test error/timeout is treated identically to "cache not confirmed" (FAST_PATH_CONFIRMED=false), NEVER
# as "assume the cache was right."
# -----------------------------------------------------------------------------
verify_cached_snap_fast_path() {
    local d="$1"
    local cached_snap="$2"
    FAST_PATH_CONFIRMED="false"

    [[ -z "$cached_snap" ]] && return 0

    if ! run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -test -e "$d/.snapshot/$cached_snap" 2>/dev/null; then
        return 0
    fi
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -test -e "$d/.snapshot/$cached_snap" 2>/dev/null; then
        return 0
    fi

    # Name/existence alone does not prove the two clusters' copies of $cached_snap are the same data (see
    # snapshot_content_signature doc comment above -- e.g. Stage 3's non-atomic baseline creation can leave
    # same-named snapshots content-diverged from the very first run). Refuse the fast path on any mismatch
    # or unreadable signature; derive_direction_state's full listing is not itself a content check either,
    # but forcing it at least surfaces the divergence in the main [DIRECTION-DERIVE] log path instead of
    # silently diffing against a cached reference this run has now proven is unsound.
    if ! verify_snapshot_content_parity "$d" "$cached_snap"; then
        log "[ERROR] [DIRECTION-DERIVE] Fast-path REFUSED for $d: cached snapshot '$cached_snap' failed content-parity verification (see [CONTENT-PARITY] above). Falling through to full live snapshot listing; if the mismatch persists, this directory needs manual reconciliation (recommend: full DistCp re-baseline)."
        return 0
    fi

    local idx next_on_dest
    idx="${cached_snap##*_}"
    [[ "$idx" =~ ^[0-9]+$ ]] || return 0
    next_on_dest="${SNAP_PREFIX}_$((idx + 1))"
    if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -test -e "$d/.snapshot/$next_on_dest" 2>/dev/null; then
        # DEST has advanced beyond the cached common point -- possible reversal. Do NOT confirm the fast path;
        # force the full algorithm.
        return 0
    fi

    # shellcheck disable=SC2034 # LAST_COMMON_SNAP_INDEX is part of this function's documented global-output
    # contract (mirrors derive_direction_state); Stage 4 currently only consumes LAST_COMMON_SNAP_NAME, but
    # callers/diagnostics are entitled to rely on the index too.
    LAST_COMMON_SNAP_INDEX=$idx
    LAST_COMMON_SNAP_NAME="$cached_snap"
    FAST_PATH_CONFIRMED="true"
    return 0
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
    
    # Ensure log directory exists
    local log_dir
    log_dir="$(dirname "$log_file")"
    mkdir -p "$log_dir" 2>/dev/null || {
        echo "[ERROR] Could not create log directory: $log_dir" >&2
        return 1
    }

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

# -----------------------------------------------------------------------------
# Validate that every non-blank, non-comment line in the DistCp filter file
# compiles as a regex, BEFORE it is ever handed to DistCp's -filters option.
# Fails fast with the offending line number/content instead of letting the
# error surface deep inside a running DistCp/YARN job.
#
# Uses python3's `re` module if available, falling back to perl (PCRE) --
# both are close enough supersets of Java regex syntax for this sanity check.
# If neither interpreter is present, validation is skipped with a [WARN]
# rather than failing the run (best-effort, non-fatal).
# -----------------------------------------------------------------------------
validate_exclude_regex_patterns() {
    local filter_file="$1"
    local checker=""

    if command -v python3 >/dev/null 2>&1; then
        checker="python3"
    elif command -v perl >/dev/null 2>&1; then
        checker="perl"
    else
        log "[WARN] Neither python3 nor perl found; skipping filter regex validation for $filter_file"
        return 0
    fi

    local line_num=0 bad_count=0 pattern
    while IFS= read -r pattern || [[ -n "$pattern" ]]; do
        line_num=$((line_num + 1))
        [[ -z "$pattern" || "$pattern" == \#* ]] && continue

        if [[ "$checker" == "python3" ]]; then
            if ! python3 -c 'import re,sys; re.compile(sys.argv[1])' "$pattern" 2>/dev/null; then
                echo "[ERROR] Invalid regex on line $line_num of $filter_file: '$pattern'" >&2
                bad_count=$((bad_count + 1))
            fi
        else
            if ! perl -e 'eval { qr/$ARGV[0]/ }; exit($@ ? 1 : 0)' "$pattern" 2>/dev/null; then
                echo "[ERROR] Invalid regex on line $line_num of $filter_file: '$pattern'" >&2
                bad_count=$((bad_count + 1))
            fi
        fi
    done < "$filter_file"

    if [[ "$bad_count" -gt 0 ]]; then
        echo "[ERROR] $bad_count invalid regex pattern(s) found in filter file: $filter_file" >&2
        echo "[ERROR] Fix the pattern(s) above (one Java regex per line) before rerunning" >&2
        exit 14
    fi
}

# -----------------------------------------------------------------------------
# Materialize the DistCp -filters file for this job from DISTCP_EXCLUDE_PATTERNS
# (inline regex patterns, comma or newline separated -- never a pre-made file
# path from the operator).
#
# The file path is DETERMINISTIC per replication job:
#   ${DISTCP_EXCLUDE_DIR}/<job_key>.filters
# where job_key = sanitize(SOURCE_CLUSTER)__sanitize(DEST_CLUSTER)__sanitize(SNAP_PREFIX)
#
# This guarantees:
#   - Uniqueness across concurrently-running jobs (different cluster pairs or
#     different SNAP_PREFIX lineages between the same pair never share a file).
#   - Idempotent reuse across repeated runs of the SAME job: the file is
#     overwritten (not appended, not uniquified with a PID/timestamp) every
#     run, so re-running never leaves behind extra files to clean up.
#
# Sets the global DISTCP_EXCLUDE_FILE to the generated path, then validates
# every pattern compiles as a regex before it is ever handed to DistCp.
# -----------------------------------------------------------------------------
resolve_distcp_exclude_file() {
    local job_key
    job_key="$(sanitize "$SOURCE_CLUSTER")__$(sanitize "$DEST_CLUSTER")__$(sanitize "$SNAP_PREFIX")"

    mkdir -p "$DISTCP_EXCLUDE_DIR"
    DISTCP_EXCLUDE_FILE="${DISTCP_EXCLUDE_DIR}/${job_key}.filters"

    # Explode comma-separated (and/or newline-separated) patterns into
    # one-per-line, skipping blank entries -- overwrite, never append.
    local IFS=','
    local -a patterns=()
    read -r -a patterns <<< "$DISTCP_EXCLUDE_PATTERNS"
    : > "$DISTCP_EXCLUDE_FILE"
    local p
    for p in "${patterns[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            echo "$line" >> "$DISTCP_EXCLUDE_FILE"
        done <<< "$p"
    done

    if [[ ! -s "$DISTCP_EXCLUDE_FILE" ]]; then
        echo "[ERROR] DISTCP_EXCLUDE_PATTERNS was set but produced no usable patterns" >&2
        echo "[ERROR] Pass one or more regexes, comma-separated (arg 13)" >&2
        exit 14
    fi

    validate_exclude_regex_patterns "$DISTCP_EXCLUDE_FILE"
}

###############################################################################
# DistCp path exclusion filter (single merged arg -- default: disabled)
#
# When enabled, DistCp will use the -filters flag to exclude paths matching
# regex patterns. This reduces data volume and improves replication SLA by
# skipping unwanted subdirectories.
#
# DISTCP_EXCLUDE_PATTERNS takes the regex patterns THEMSELVES inline (like
# SOURCE_DIRS takes a comma-separated directory list) -- NOT a pre-made file
# path. The script generates the actual DistCp -filters file itself:
#   - empty/unset    -> filtering DISABLED
#   - non-empty value -> filtering ENABLED using these pattern(s)
#
# Why not a file path (as in earlier versions): with hundreds of concurrent
# DR replication pairs on the same node, requiring each operator/orchestration
# wrapper to hand-create and own a distinct local file per pair is error-prone
# (path collisions, stale files, cleanup). Instead the script derives a STABLE
# per-job key from SOURCE_CLUSTER + DEST_CLUSTER + SNAP_PREFIX (see
# resolve_distcp_exclude_file below) and (re)writes
# ${DISTCP_EXCLUDE_DIR}/<job_key>.filters on every run:
#   - unique per replication job -> concurrent different jobs never collide
#   - same path every run of the SAME job -> idempotent overwrite, no
#     ever-growing pile of one-off files to clean up
#
# Priority: 1) CLI argument (13th arg), 2) Environment variable, 3) Default value (disabled)
#
# Pattern format (comma-separated on the CLI/env; matched against full
# relative path; multiple patterns = multiple exclude rules, ORed together):
#   ".*dir4/sub2.*,.*\.tmp$,.*/staging/.*"
#
# Example: To exclude /new03/dir4/sub2 when replicating /new03:
#   DISTCP_EXCLUDE_PATTERNS='.*dir4/sub2.*'
#
# NOTE: Filters apply to both full DistCp (Stage 3) and incremental (Stage 4).
# NOTE: Rollback DistCp (ROLLBACK_ON_FAILURE) does NOT use filters, as rollback
#       must restore the complete snapshot state.
###############################################################################
if [[ -n "$DISTCP_EXCLUDE_PATTERNS_ARG" ]]; then
    DISTCP_EXCLUDE_PATTERNS="$DISTCP_EXCLUDE_PATTERNS_ARG"
else
    DISTCP_EXCLUDE_PATTERNS="${DISTCP_EXCLUDE_PATTERNS:-}"
fi

# Derived internal toggle: enabled iff non-empty patterns were provided.
if [[ -n "$DISTCP_EXCLUDE_PATTERNS" ]]; then
    DISTCP_EXCLUDE_ENABLED="yes"
else
    DISTCP_EXCLUDE_ENABLED="no"
fi

# Directory holding generated, job-keyed filter files (one stable file per
# replication job, overwritten idempotently -- never a new file per run).
DISTCP_EXCLUDE_DIR="/var/tmp/dr-distcp-filters"

# Resolved at runtime once SOURCE_CLUSTER/DEST_CLUSTER/SNAP_PREFIX are known
# and validated (see resolve_distcp_exclude_file, called from main()).
DISTCP_EXCLUDE_FILE=""

# Build filter opts (validated later in main() after output redirection)
DISTCP_EXCLUDE_OPTS=""

###############################################################################
# Replication mode: "pull" or "push"
#
# Controls where YARN MapReduce jobs run and which cluster's delegation tokens are excluded from renewal.
#
# Supported modes:
#   - "pull" (default):
#       * Script runs on the TARGET/DR cluster
#       * YARN jobs run on TARGET/DR cluster
#       * Source cluster is excluded from token renewal
#       * Source cluster has zero replication compute overhead
#   - "push":
#       * Script runs on the SOURCE/Production cluster
#       * YARN jobs run on SOURCE/Production cluster
#       * Destination cluster is excluded from token renewal
#       * Source cluster bears YARN + DistCp MapReduce overhead
#
# Priority: 1) CLI argument (17th arg), 2) Environment variable, 3) Default value
###############################################################################
if [[ -n "$REPLICATION_MODE_ARG" ]]; then
    REPLICATION_MODE="$REPLICATION_MODE_ARG"
else
    REPLICATION_MODE="${REPLICATION_MODE:-pull}"
fi

# Enable verbose DistCp debug logging (yes/no)
DISTCP_DEBUG="${DISTCP_DEBUG:-no}"
DISTCP_DEBUG_OPTS=""

# Build DistCp options with YARN queue and application tags
YARN_QUEUE_OPTS="-Dmapred.job.queue.name=${YARN_QUEUE}"
YARN_APP_TAGS="-Dmapreduce.job.tags=pulse-dr-replication,mode:${REPLICATION_MODE},src:${SOURCE_CLUSTER},dst:${DEST_CLUSTER}"
DISTCP_FULL_OPTS="$YARN_QUEUE_OPTS $YARN_APP_TAGS $DISTCP_DEBUG_OPTS"


# -----------------------------------------------------------------------------
# check_nameservice_reachable: fast-fail reachability check for HA/NameService clusters (arg is a bare
# NameService with no ":port", so the JMX-based check_cluster_health cannot be used against it directly).
#
# WHY THIS EXISTS: without this check, an HA cluster entry skipped Stage 1 entirely with zero live validation,
# and the first real command against it was whatever Stage 2 happened to run first (e.g.
# ensure_hdfs_state_dir's "hdfs dfs ... -mkdir"). If the NameService is missing from this node's
# hdfs-site.xml, unreachable, or misconfigured, that first real call hangs for the client's full RPC
# retry/timeout window (can be many minutes) instead of failing immediately with a clear message -- exactly
# the "script just sits there" symptom this function exists to prevent.
#
# Runs a cheap "hdfs dfs -fs hdfs://<ns> -ls /" bounded by:
#   - `timeout` (wall-clock cap, TIMEOUT_SECS)
#   - reduced client-side RPC retries (-Dipc.client.connect.max.retries=1
#     -Dipc.client.connect.max.retries.on.timeouts=1) so a single unreachable
#     NameNode doesn't itself retry for minutes before the wall-clock timeout
#     even fires.
# This is a liveness/reachability check only, NOT a replacement for check_cluster_health's ACTIVE/STANDBY
# HA-state check -- for a NameService, hitting "/" already transparently proxies to whichever NameNode is
# ACTIVE, so a successful listing implies the NameService as a whole is usable.
#
# Returns 0 if reachable, 1 otherwise. Never hangs past TIMEOUT_SECS.
# -----------------------------------------------------------------------------
check_nameservice_reachable() {
    local nameservice="$1"
    local cluster_name="$2"
    local timeout_secs="${NAMESERVICE_CHECK_TIMEOUT:-30}"

    log "[CHECK] Verifying $cluster_name NameService '$nameservice' is reachable (timeout: ${timeout_secs}s)"

    local probe_err="/tmp/pulse_replication_action_ns_probe_${cluster_name}_$$.log"
    TEMP_FILES+=("$probe_err")

    # IMPORTANT: run_as_hdfs is a shell FUNCTION defined in this script, not an external binary. Both `env
    # VAR=x run_as_hdfs ...` and `timeout N run_as_hdfs ...` were tried here and BOTH are broken the same way:
    # `env` and `timeout` are real executables that `execvp()` the command that follows them directly --
    # neither one is a shell, so neither can ever resolve a bash function name, and both fail immediately with
    # "No such file or directory" (this exact bug shipped once already: the failure was
    # silent/non-fatal-looking because it happened inside an `if ...; then` condition, so the script logged a
    # confusing "exit code 0" reachability failure instead of crashing loudly). Wrapping in `timeout N bash -c
    # 'run_as_hdfs ...'` also does not reliably fix this: the exported function would need to survive across a
    # `sudo -u` boundary inside run_as_hdfs (non-Kerberos mode), and many sudo configurations strip
    # `BASH_FUNC_*` environment variables for security, silently breaking the export again in that mode.
    #
    # Instead, the timeout is implemented AS A SHELL, with no external `timeout`/`env` wrapping needed: run
    # the real (function) call in the background, race it against a `sleep` in a second background job, and
    # poll both PIDs with `kill -0` (portable back to bash 4.2 -- this deliberately avoids `wait -n PID...`,
    # which needs bash 4.3+ and may not be available on older RHEL/CentOS 7-era hosts this script targets) to
    # see which one finishes first. This works uniformly regardless of Kerberos mode, sudo config, or whether
    # run_as_hdfs is a function or a real binary.
    (
        run_as_hdfs hdfs dfs -fs "hdfs://${nameservice}" \
            -Dipc.client.connect.max.retries=1 \
            -Dipc.client.connect.max.retries.on.timeouts=1 \
            -ls / >/dev/null 2>"$probe_err"
    ) &
    local probe_pid=$!
    ( sleep "$timeout_secs" ) &
    local sleep_pid=$!

    local rc timed_out=false
    while true; do
        if ! kill -0 "$probe_pid" 2>/dev/null; then
            # The probe finished first -- reap its real exit status and stop the now-pointless sleep job.
            wait "$probe_pid"
            rc=$?
            kill "$sleep_pid" 2>/dev/null || true
            wait "$sleep_pid" 2>/dev/null || true
            break
        fi
        if ! kill -0 "$sleep_pid" 2>/dev/null; then
            # The sleep finished first -- the probe is still running -> timed out.
            timed_out=true
            kill "$probe_pid" 2>/dev/null || true
            wait "$probe_pid" 2>/dev/null || true
            rc=124
            break
        fi
        sleep 0.2
    done

    if [[ "$rc" -eq 0 ]]; then
        log "[INFO] $cluster_name NameService '$nameservice' is reachable"
        rm -f "$probe_err" 2>/dev/null || true
        return 0
    fi

    if [[ "$timed_out" == "true" ]]; then
        log "[ERROR] Timed out after ${timeout_secs}s verifying $cluster_name NameService '$nameservice'"
        log "[ERROR] The NameService did not respond in time. This usually means it is not configured"
        log "[ERROR] in this node's hdfs-site.xml (missing dfs.nameservices / dfs.ha.namenodes.${nameservice}"
        log "[ERROR] entries), is unreachable over the network, or Kerberos auth is hanging/negotiating."
    else
        log "[ERROR] Could not list '/' on $cluster_name NameService '$nameservice' (exit code $rc)"
    fi
    if [[ -s "$probe_err" ]]; then
        log "[ERROR] Probe stderr: $(tr '\n' ' ' <"$probe_err")"
    fi
    log "[ERROR] Verify manually: hdfs getconf -confKey dfs.nameservices"
    log "[ERROR] Verify manually: timeout 15 hdfs dfs -fs hdfs://${nameservice} -ls /"
    rm -f "$probe_err" 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# check_superuser_privilege: fast-fail check that the effective HDFS identity (HDFS_USER
# under sudo, or the current Kerberos principal when KERBEROS_ENABLED=yes -- run_as_hdfs
# already encodes exactly which identity every real "hdfs" call in this script runs as)
# has superuser privilege on the given cluster.
#
# WHY THIS EXISTS: without this, a missing superuser grant surfaced only much later and
# confusingly -- as an "allowSnapshot"/"createSnapshot" failure deep in Stage 2/3, or (worse)
# asymmetrically, e.g. superuser present on SOURCE_CLUSTER but not DEST_CLUSTER, which would
# let Stage 2's source-side allowSnapshot succeed and only fail on the destination side,
# looking like a directory-specific problem rather than an identity/permission one. Checking
# both clusters explicitly and up front, before any per-directory work begins, turns that
# into one clear Stage 1 error naming exactly which cluster and identity are missing the
# grant.
#
# Uses "hdfs dfsadmin -report" as the cheapest superuser-gated RPC available (no side
# effects, unlike e.g. -allowSnapshot on a real directory). A non-superuser caller gets a
# non-zero exit and a stderr line containing "Superuser privilege is required" -- checked by
# grep (primary, most specific signal) OR exit code (fallback, in case wording differs across
# Hadoop distributions/versions).
#
# Returns 0 if superuser privilege is confirmed, 1 otherwise. Never hangs (dfsadmin -report
# is a single RPC to the already-known-reachable NameNode; no timeout wrapper needed here,
# unlike check_nameservice_reachable's NameService-resolution concern).
# -----------------------------------------------------------------------------
check_superuser_privilege() {
    local cluster="$1"
    local cluster_name="$2"

    log "[CHECK] Verifying superuser privilege on $cluster_name cluster ($cluster)"

    # Effective identity this check (and every other run_as_hdfs call in the script) runs
    # as, shown up front so the printed command below is unambiguous about what's actually
    # being tested.
    local effective_identity
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        effective_identity="current Kerberos principal (cache: ${KRB5CCNAME:-<default>})"
    else
        effective_identity="HDFS_USER=\"$HDFS_USER\" (via sudo)"
    fi

    local report_cmd="hdfs dfsadmin -fs hdfs://${cluster} -report"
    echo ""
    echo "  >>> Superuser Check Command ($cluster_name, effective identity: $effective_identity):"
    echo "  >>>   $report_cmd"
    echo ""
    log "[DEBUG] Running: $report_cmd"

    local report_err="/tmp/pulse_replication_action_superuser_check_${cluster_name}_$$.log"
    TEMP_FILES+=("$report_err")

    if run_as_hdfs hdfs dfsadmin -fs "hdfs://${cluster}" -report >/dev/null 2>"$report_err"; then
        if grep -qi "Superuser privilege is required\|Access denied" "$report_err" 2>/dev/null; then
            log "[ERROR] $cluster_name cluster ($cluster): dfsadmin -report exited 0 but stderr indicates a permission denial. Treating as a failed superuser check."
        else
            log "[INFO] Superuser privilege confirmed on $cluster_name cluster ($cluster) for $effective_identity"
            rm -f "$report_err" 2>/dev/null || true
            return 0
        fi
    fi

    echo ""
    echo "=========================================================================================================================================="
    echo ">>> [ERROR] SUPERUSER PRIVILEGE CHECK FAILED on $cluster_name cluster ($cluster) <<<"
    echo "=========================================================================================================================================="
    echo ""
    echo "  Effective identity : $effective_identity"
    echo "  Cluster            : $cluster_name ($cluster)"
    if [[ -s "$report_err" ]]; then
        echo "  dfsadmin said      : $(tr '\n' ' ' <"$report_err")"
    fi
    echo ""
    echo "  This user/principal must have HDFS cluster-admin privilege on $cluster_name --"
    echo "  required for allowSnapshot, createSnapshot/deleteSnapshot, and DistCp to work"
    echo "  correctly in later stages. Granted via dfs.cluster.administrators (the ACL"
    echo "  that gates admin commands like 'dfsadmin -report') in hdfs-site.xml, or by"
    echo "  membership in HDFS's superuser group (dfs.permissions.superusergroup)."
    echo ""
    echo "  --- How to fix ---"
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo "    1. Check which principal is currently active:"
        echo "         klist ${KRB5CCNAME:+-c \"$KRB5CCNAME\"}"
        echo "    2. Obtain a ticket for a superuser principal instead, e.g.:"
        echo "         kinit -kt /etc/security/keytabs/hdfs.service.keytab hdfs/\$(hostname -f)"
        echo "    3. Re-run this script (or re-run just the check manually):"
        echo "         $report_cmd"
    else
        echo "    1. Confirm the configured HDFS_USER (arg 6 / HDFS_USER env var) is correct:"
        echo "         echo \"$HDFS_USER\""
        echo "    2. Verify that user has admin rights on $cluster_name, e.g. check"
        echo "         dfs.cluster.administrators (and/or dfs.permissions.superusergroup) in"
        echo "         hdfs-site.xml and that user's group membership on the NameNode host,"
        echo "         or grant it explicitly if intended."
        echo "    3. Re-run the check manually as that user to confirm the fix:"
        echo "         sudo -u \"$HDFS_USER\" $report_cmd"
    fi
    echo ""
    echo "=========================================================================================================================================="
    log "[ERROR] Superuser privilege check FAILED on $cluster_name cluster ($cluster) for $effective_identity. See guidance above."
    rm -f "$report_err" 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# Stage 1: Cluster health checks (JMX / HA) Supports both Kerberos and non-Kerberos modes If KRB5CCNAME is set
# at runtime, it will be used for Kerberos authentication
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
            curl_cmd="curl -ik --silent --max-time 10 --fail --negotiate -u : \"$jmx_url\""
            echo ""
            echo "  >>> Curl Command (Kerberos with custom cache):"
            echo "  >>>   KRB5CCNAME=\"${KRB5CCNAME}\" $curl_cmd"
            echo ""
            log "[DEBUG] Using Kerberos with KRB5CCNAME=\"${KRB5CCNAME}\""
        else
            # Kerberos mode but no custom cache - use default location
            curl_cmd="curl -ik --silent --max-time 10 --fail --negotiate -u : \"$jmx_url\""
            echo ""
            echo "  >>> Curl Command (Kerberos, default cache):"
            echo "  >>>   $curl_cmd"
            echo ""
            log "[DEBUG] Using Kerberos with default cache location"
        fi
        
        # Execute curl with Kerberos authentication
        jmx_response=$(curl -ik --silent --max-time 10 --fail --negotiate -u : "$jmx_url" 2>/dev/null || true)
        
        # Check if Kerberos authentication failed
        if [[ -z "$jmx_response" ]] || ! echo "$jmx_response" | grep -q "FSNamesystem"; then
            log "[WARN] Kerberos authentication failed, trying without Kerberos..."
            curl_cmd="curl -ik --silent --max-time 10 --fail \"$jmx_url\""
            echo ""
            echo "  >>> Fallback Curl Command (no Kerberos):"
            echo "  >>>   $curl_cmd"
            echo ""
            log "[DEBUG] Fallback to non-Kerberos mode"
            jmx_response=$(curl -ik --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
        fi
    else
        # Non-Kerberos mode
        curl_cmd="curl -ik --silent --max-time 10 --fail \"$jmx_url\""
        echo ""
        echo "  >>> Curl Command (no Kerberos):"
        echo "  >>>   $curl_cmd"
        echo ""
        log "[DEBUG] Using non-Kerberos mode"
        jmx_response=$(curl -ik --silent --max-time 10 --fail "$jmx_url" 2>/dev/null || true)
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
# rollback_once_for_failure: attempt single automatic rollback for a specific DistCp failure identified by
# directory + fromSnapshot + toSnapshot. Creates a per-failure marker in $ROLLBACK_MARKER_DIR to ensure this
# exact failure (same dir + same snapshot pair) isn't auto-rolled back again.
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

    # If marker exists, skip automatic rollback for this exact failure -- UNLESS
    # the marker is older than ROLLBACK_MARKER_MAX_AGE_SECS, in which case it is
    # treated as STALE (see that variable's doc comment for the full "why":
    # marker filenames are keyed only by directory + literal snapshot names,
    # with no timestamp/run-id, so a marker from a much earlier failover/
    # failback cycle could otherwise silently block a genuinely new rollback
    # attempt that happens to reuse the same (from_snap, to_snap) pair after an
    # operator-performed full re-baseline resets the index sequence). Note:
    # this only prevents retrying the SAME failure within the same window; a
    # different snapshot pair always gets its own, independent marker.
    if [[ -e "$marker_file" ]]; then
        local marker_age_secs marker_mtime
        marker_mtime=$(stat -c %Y "$marker_file" 2>/dev/null || stat -f %m "$marker_file" 2>/dev/null || echo "")
        if [[ -n "$marker_mtime" ]]; then
            marker_age_secs=$(( $(date +%s) - marker_mtime ))
            if [[ "$marker_age_secs" -ge "$ROLLBACK_MARKER_MAX_AGE_SECS" ]]; then
                log "[ROLLBACK] Marker exists for this failure ($marker_file) but is ${marker_age_secs}s old (>= ROLLBACK_MARKER_MAX_AGE_SECS=${ROLLBACK_MARKER_MAX_AGE_SECS}s). Treating as STALE and allowing a fresh rollback attempt."
                rm -f "$marker_file" 2>/dev/null || true
            else
                log "[ROLLBACK] Marker exists for this failure ($marker_file, ${marker_age_secs}s old). Skipping automatic rollback for $d from $from_snap -> $to_snap."
                log "[ROLLBACK] Note: This prevents retrying the exact same failure. If $d fails again with different snapshots, rollback will be attempted."
                return 1
            fi
        else
            # Could not stat the marker (permissions, race, unsupported stat
            # flavor) -- fail safe by honoring it as before rather than risking
            # a retry loop against an unreadable marker.
            log "[ROLLBACK] Marker exists for this failure ($marker_file, age unknown -- could not stat). Skipping automatic rollback for $d from $from_snap -> $to_snap."
            log "[ROLLBACK] Note: This prevents retrying the exact same failure. If $d fails again with different snapshots, rollback will be attempted."
            return 1
        fi
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
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$rollback_snap"; then
        echo "[ERROR] FAILED to create rollback snapshot '$rollback_snap' on DESTINATION: $d"
        log "[ERROR] Failed to create rollback snapshot $rollback_snap on destination $d"
        log "[ERROR] Rollback aborted. No marker created - rollback can be retried on next run if issue is resolved."
        return 1
    fi

    # Determine prev_snap to restore to. Prefer the 'from_snap' if present on DR; otherwise choose latest snapshot as fallback.
    local prev_snap="$from_snap"
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "${d}/.snapshot" 2>/dev/null | grep -q "/${prev_snap}\$"; then
        log "[WARN] Expected prev_snap '$prev_snap' not found on DR. Choosing latest available snapshot on DR as fallback."
        mapfile -t snaps_dst < <(
            run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "${d}/.snapshot" 2>/dev/null |
                awk '$1 ~ /^d/ {print $6, $7, $8}' |
                sort |
                awk -F/ '{print $NF}' || true
        )
        if [[ ${#snaps_dst[@]} -eq 0 ]]; then
            log "[ERROR] No snapshots found on DR for $d. Cannot perform automated rollback."
            # Clean up the rollback snapshot we just created
            run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -deleteSnapshot "$d" "$rollback_snap" 2>/dev/null || true
            log "[ERROR] Rollback aborted. No marker created - rollback can be retried on next run if issue is resolved."
            return 1
        fi
        prev_snap="${snaps_dst[$((${#snaps_dst[@]} - 1))]}"
        log "[ROLLBACK] Selected prev_snap='$prev_snap' from DR snapshot list"
    fi

    # CRITICAL SAFETY CHECK: prev_snap must also exist on SOURCE_CLUSTER before
    # we -rdiff DEST back to it. Without this, the fallback above (or even the
    # "expected from_snap" path, if from_snap was itself already pruned on
    # SOURCE between the failed diff and this rollback) could restore DEST to
    # a snapshot that SOURCE no longer has any record of -- e.g. an older
    # snapshot DR still has around but SOURCE's own cleanup_old_snapshots has
    # since retired past SNAP_RETAIN. Rolling back to such a point leaves DEST
    # with NO common ancestor left on SOURCE for any future incremental diff
    # to build on, effectively orphaning the directory: the next run's
    # derive_direction_state would find no shared snapshot index at all and
    # require full manual reconciliation. Verifying here, before the
    # destructive -rdiff runs, catches this while it's still a clean abort
    # instead of a silent data-loss-adjacent state.
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -ls "${d}/.snapshot" 2>/dev/null | grep -q "/${prev_snap}\$"; then
        echo "[ERROR] Rollback target snapshot '$prev_snap' does NOT exist on SOURCE_CLUSTER ($SOURCE_CLUSTER): $d"
        log "[ERROR] [ROLLBACK] prev_snap '$prev_snap' not found on SOURCE_CLUSTER. Refusing to -rdiff DEST to a"
        log "[ERROR] [ROLLBACK] snapshot with no matching history on SOURCE -- this would orphan the directory"
        log "[ERROR] [ROLLBACK] (no common ancestor left for any future incremental diff). Aborting rollback."
        log "[ERROR] [ROLLBACK] Manual reconciliation required: inspect snapshots on both clusters and decide"
        log "[ERROR] [ROLLBACK] whether a full re-baseline is needed for $d."
        # Clean up the rollback snapshot we just created (mirrors the
        # "no snapshots found on DR" failure path above).
        run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -deleteSnapshot "$d" "$rollback_snap" 2>/dev/null || true
        log "[ERROR] Rollback aborted. No marker created - rollback can be retried on next run if issue is resolved."
        return 1
    fi

    # Capture diff for audit
    local diff_out
    diff_out="/var/log/dr_rollback_diff_${key}_from_${rollback_snap}_to_${prev_snap}_$(date +%s).txt"
    log_substage "Rollback Step 2: Capturing snapshot diff for audit"
    log "[ROLLBACK] Capturing snapshotDiff between $rollback_snap and $prev_snap to $diff_out"
    run_as_hdfs hdfs snapshotDiff -fs "hdfs://$DST_URI_NS" "$d" "$rollback_snap" "$prev_snap" >"$diff_out" 2>&1 ||
        log "[WARN] snapshotDiff returned non-zero; check $diff_out for details."

    # Run DistCp rdiff to restore prev_snap -> live path on DR
    local src_snap_path="hdfs://$DST_URI_NS${d}"
    local dst_live_path="hdfs://$DST_URI_NS${d}"
    # DISTCP_ROLLBACK_OPTS carries the flags STRUCTURALLY required for a -rdiff
    # restore (rollback/prev snapshot names, dynamic strategy, direct write,
    # update semantics, preserve-status flags) followed by $COPY_OPTS (arg 8) so
    # any operator tuning there -- -bandwidth, -m (mapper count),
    # -skipcrccheck, -Dmapreduce.map.memory.mb=..., etc. -- also applies to the
    # single most destructive/highest-stakes DistCp job in the script. Without
    # this, rollback previously ran with completely untuned defaults regardless
    # of what the operator configured, which is exactly backwards: an
    # under-provisioned rollback (no bandwidth cap, default mapper memory) is
    # more likely to fail or contend with production traffic at precisely the
    # moment recovery matters most. A duplicate flag here (e.g. if COPY_OPTS
    # also happens to specify -strategy/-direct/-update/-pugptx, which the
    # documented default value does) is expected and harmless -- DistCp's
    # option parser takes the last occurrence of a repeated flag / tolerates a
    # repeated boolean flag as a no-op, so appending COPY_OPTS after the
    # required baseline here does not conflict with it.
    local DISTCP_ROLLBACK_OPTS="-rdiff $rollback_snap $prev_snap -strategy dynamic -direct -update -pugptx $COPY_OPTS"

    # IMPORTANT: use YARN_QUEUE_OPTS/YARN_APP_TAGS/DISTCP_DEBUG_OPTS directly
    # here, NOT the full $DISTCP_FULL_OPTS -- DISTCP_FULL_OPTS also bundles
    # DISTCP_MAPREDUCE_OPTS, a "-Dmapreduce.job.hdfs-servers.token-renewal.exclude=<other-cluster>"
    # flag computed once for the FORWARD pull/push distcp between TWO
    # DIFFERENT clusters (SOURCE_CLUSTER and DEST_CLUSTER). Rollback is a
    # same-cluster operation: both src_snap_path and dst_live_path point at
    # $DEST_CLUSTER, so excluding "the other cluster" from token renewal is
    # meaningless at best -- and in production this caused YARN's own
    # delegation-token renewal for $DEST_CLUSTER's real token to fail
    # ("Failed to renew token ... on ha-hdfs:<DEST_CLUSTER>"), aborting the
    # rollback job before it could even submit. Building a dedicated
    # rollback options string without the cross-cluster exclusion avoids
    # this entirely.
    local DISTCP_ROLLBACK_FULL_OPTS="$YARN_QUEUE_OPTS $YARN_APP_TAGS $DISTCP_DEBUG_OPTS"

    log_substage "Rollback Step 3: Running DistCp rollback to restore snapshot state"
    log_cmd "DistCp Rollback Command"
    echo "  hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_ROLLBACK_FULL_OPTS $DISTCP_ROLLBACK_OPTS $src_snap_path $dst_live_path"
    echo ""
    log "[ROLLBACK] Running DistCp rollback: hadoop distcp $DISTCP_ROLLBACK_FULL_OPTS $DISTCP_ROLLBACK_OPTS $src_snap_path $dst_live_path"
    # Rollback DistCp stderr goes through global redirection (exec 2>&1), no need to tee to LOG again
    local rollback_distcp_success=false
    # shellcheck disable=SC2086 # Intentional word splitting for distcp option flags
    if run_as_distcp hadoop distcp $DISTCP_ROLLBACK_FULL_OPTS $DISTCP_ROLLBACK_OPTS "$src_snap_path" "$dst_live_path"; then
        rollback_distcp_success=true
    fi
    
    # Create marker AFTER attempting the rollback DistCp operation This ensures that if rollback fails early
    # (before DistCp), we can retry on next run But once we've attempted the DistCp rollback, we create the
    # marker to prevent retrying the same rollback
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
        if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -deleteSnapshot "$d" "$rollback_snap"; then
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
# Baseline bootstrap completion / self-heal (runs ONCE per directory, on the baseline transition last_snap ==
# ${SNAP_PREFIX}_0, BEFORE the incremental -diff).
#
# Why this exists:
#   The destination baseline snapshot ${SNAP_PREFIX}_0 is created in Stage 3 while the
#   destination directory may still be EMPTY (AUTO_FULL_DISTCP=no, before manual copy),
#   PARTIAL (a full DistCp was interrupted / OOM'd), or filled out-of-band by an operator.
#   DistCp -diff requires the destination LIVE data to equal the destination ${SNAP_PREFIX}_0
#   snapshot, and the incremental diff only carries SOURCE-side deltas -- it can never
#   backfill files the bulk copy missed. The previous `snapshotDiff ... "."` heuristic was
#   unreliable (false negatives), which left the baseline stale and caused
#   "The target has been modified since snapshot" failures (and risked a silent empty DR
#   if -diff "succeeded" copying nothing).
#
# What it does (deterministic, works for BOTH AUTO_FULL_DISTCP=yes and =no):
#   1) One-time full `distcp -update` from the SOURCE ${SNAP_PREFIX}_0 snapshot into the
#      destination. Near-noop if already fully copied; backfills any gaps. If this fails we
#      do NOT re-baseline (re-baselining a bad state would freeze divergence).
#   2) Delete + recreate the destination ${SNAP_PREFIX}_0 snapshot from the reconciled state,
#      so DistCp's "target unchanged since fromSnapshot" precondition holds.
#   3) Clear any stale rollback markers for this baseline pair (from a prior failed run).
#
# Runs only while state == ${SNAP_PREFIX}_0; once state advances to _1 it never runs again. Returns 0 on
# success (caller proceeds to -diff), 1 on failure (caller fails the directory).
# -----------------------------------------------------------------------------
reconcile_and_rebaseline_dest() {
    local d="$1"
    local baseline_snap="$2"
    local key
    key=$(sanitize "$d")
    local src_base_uri="hdfs://$SRC_URI_NS${d}/.snapshot/${baseline_snap}"
    local dst_uri="hdfs://$DST_URI_NS${d}"

    log_substage "Baseline bootstrap: reconciling destination to source snapshot $baseline_snap"
    log "[INIT] Reconciling destination $d to source snapshot $baseline_snap (one-time bootstrap safeguard)"

    # Step 1: full -update from source baseline snapshot into destination (backfills any gaps)
    local reconcile_err="/tmp/distcp_reconcile_err_${key}_$$.log"
    TEMP_FILES+=("$reconcile_err")
    log_cmd "Baseline Reconcile DistCp Command"
    echo "  hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS $src_base_uri $dst_uri"
    echo ""
    # shellcheck disable=SC2086 # Intentional word splitting for distcp option flags
    if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS "$src_base_uri" "$dst_uri" 2> >(tee "$reconcile_err" >&2); then
        log "[INFO] Baseline reconcile DistCp succeeded for $d"
    else
        echo "[ERROR] Baseline reconcile DistCp FAILED for $d (see $reconcile_err)"
        log "[ERROR] Baseline reconcile DistCp failed for $d. Not re-baselining (would freeze an incorrect state)."
        if [[ -f "$reconcile_err" ]] && [[ -s "$reconcile_err" ]]; then
            analyze_error "$reconcile_err"
        fi
        return 1
    fi

    # Step 2: refresh the destination baseline snapshot to match the reconciled state
    if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${baseline_snap}\$"; then
        log "[DEBUG] Deleting destination baseline snapshot $baseline_snap to refresh it"
        if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -deleteSnapshot "$d" "$baseline_snap" 2>/dev/null; then
            log "[WARN] Failed to delete destination baseline snapshot $baseline_snap (will attempt recreate anyway)"
        fi
    fi
    if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$baseline_snap"; then
        log "[INFO] Destination baseline snapshot $baseline_snap refreshed to reconciled state for $d"
    else
        echo "[ERROR] FAILED to recreate destination baseline snapshot $baseline_snap for $d"
        log "[ERROR] Could not refresh destination baseline snapshot $baseline_snap for $d. Incremental -diff will likely fail."
        return 1
    fi

    # Step 3: clear any stale rollback markers for this baseline pair (from a previous failed run)
    local stale
    shopt -s nullglob
    for stale in "${ROLLBACK_MARKER_DIR}/${key}__from_${baseline_snap}__to_"*.marker; do
        if rm -f "$stale" 2>/dev/null; then
            log "[INFO] Cleared stale rollback marker: $stale"
        fi
    done
    shopt -u nullglob

    return 0
}

# -----------------------------------------------------------------------------
# reconcile_reverse_diff_bootstrap: one-time incremental reverse-diff bootstrap for a directory whose
# replication direction has reversed (failover/failback), used only when REVERSE_DIFF_BOOTSTRAP="yes" AND a
# state file already exists.
#
# Preconditions (all checked by caller in Stage 4 before invoking):
#   - $state file exists for $d (i.e. NOT a brand-new directory)
#   - derive_direction_state (or its verified fast-path) has determined
#     DIRECTION_REVERSED=true for $d, from LIVE snapshot listings on both
#     clusters (never from a cached label)
#   - REVERSE_DIFF_BOOTSTRAP=yes
#
# Diffs the COMMON ancestor snapshot ($last_snap, present on both clusters from the last successful run in
# either direction) against a NEW incremental snapshot created on the CURRENT $SOURCE_CLUSTER (physically the
# old destination), and applies that diff onto the CURRENT $DEST_CLUSTER (physically the old source, which may
# have taken writes during the outage).
#
# Uses an INCREMENTAL `distcp -diff`, NOT a full distcp, as the primary (and only automatic) attempt -- avoids
# re-copying the entire dataset on failover.
#
# On "target modified/changed since snapshot" from the incremental diff: does NOT perform any destructive
# rollback/rdiff. Fails cleanly with operator guidance, consistent with the baseline-snapshot split-brain
# philosophy in Stage 4 (see the last_snap==baseline_snap branch around line 2157).
#
# Returns 0 on success (state file already advanced by this function). Returns 1 on failure (no state
# mutation; caller marks directory failed).
# -----------------------------------------------------------------------------
reconcile_reverse_diff_bootstrap() {
    local d="$1"
    local last_snap="$2"
    local key state
    key=$(sanitize "$d")
    resolve_state_file "$key"
    state="$RESOLVED_STATE_PATH"
    # See the matching variable in Stage 4's per-directory loop for the full rationale: prefixes every
    # "hdfs"/"hadoop" command PRINTED below as manual operator recovery guidance so it is runnable standalone
    # (needed in the same-nameservice-collision case, where SRC_URI_NS is a synthetic alias). Empty string,
    # safe to prefix unconditionally, when AUTO_DERIVE_HA_CLIENT_CONFIG is disabled.
    local nameservice_ha_display_args
    nameservice_ha_display_args="$(render_nameservice_ha_args_for_display)"

    local idx reverse_next_snap
    idx=${last_snap##*_}
    reverse_next_snap="${SNAP_PREFIX}_$((idx + 1))"

    log_substage "Reverse-diff bootstrap: $d ($last_snap -> $reverse_next_snap, new source=$SOURCE_CLUSTER)"
    log "[REVERSE-BOOTSTRAP] Direction reversal for $d: attempting incremental reverse diff $last_snap -> $reverse_next_snap"

    # --- Precondition: common ancestor snapshot must exist on BOTH clusters ---
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${last_snap}\$"; then
        echo "[ERROR] Reverse-diff bootstrap: common snapshot '$last_snap' NOT FOUND on new source ($SOURCE_CLUSTER) for $d"
        log "[ERROR] [REVERSE-BOOTSTRAP] Missing '$last_snap' on new source for $d. Cannot compute incremental diff."
        log "[ERROR] This can happen if snapshot retention (SNAP_RETAIN) pruned '$last_snap' on this cluster. Manual reconciliation or full DistCp required."
        return 1
    fi
    if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${last_snap}\$"; then
        echo "[ERROR] Reverse-diff bootstrap: common snapshot '$last_snap' NOT FOUND on new destination ($DEST_CLUSTER) for $d"
        log "[ERROR] [REVERSE-BOOTSTRAP] Missing '$last_snap' on new destination for $d. Cannot compute incremental diff."
        log "[ERROR] This can happen if snapshot retention (SNAP_RETAIN) pruned '$last_snap' on this cluster. Manual reconciliation or full DistCp required."
        return 1
    fi

    # --- Step 1: create the next snapshot on the NEW source (idempotent) ---
    log_substage "Reverse-diff bootstrap Step 1: creating $reverse_next_snap on new source ($SOURCE_CLUSTER)"
    local out_src
    out_src=$(run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -createSnapshot "$d" "$reverse_next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
    if echo "$out_src" | grep -q "already a snapshot with the same name"; then
        log "[WARN] [REVERSE-BOOTSTRAP] Snapshot $reverse_next_snap already exists on new source for $d"
    elif echo "$out_src" | grep -q "Created snapshot"; then
        log "[INFO] [REVERSE-BOOTSTRAP] Snapshot $reverse_next_snap created on new source for $d"
    else
        echo "[ERROR] Reverse-diff bootstrap: FAILED to create $reverse_next_snap on new source ($SOURCE_CLUSTER): $d"
        log "[ERROR] [REVERSE-BOOTSTRAP] Source snapshot creation failed: $out_src"
        return 1
    fi

    # --- Step 2: incremental distcp -diff from new-source to new-destination ---
    local src_uri dst_uri copy_opts_no_update
    src_uri="hdfs://$SRC_URI_NS${d}"
    dst_uri="hdfs://$DST_URI_NS${d}"
    copy_opts_no_update=$(strip_update_flag "$COPY_OPTS")

    local bootstrap_err="/tmp/distcp_reverse_bootstrap_err_${key}_$$.log"
    TEMP_FILES+=("$bootstrap_err")
    log_cmd "Reverse-Diff Bootstrap DistCp Command"
    echo "  hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $copy_opts_no_update -update -diff $last_snap $reverse_next_snap $src_uri $dst_uri"
    echo ""
    local bootstrap_distcp_success
    # shellcheck disable=SC2086 # Intentional word splitting for distcp option flags
    if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $copy_opts_no_update -update -diff "$last_snap" "$reverse_next_snap" "$src_uri" "$dst_uri" 2> >(tee "$bootstrap_err" >&2); then
        bootstrap_distcp_success=true
    else
        bootstrap_distcp_success=false
    fi

    if [[ "$bootstrap_distcp_success" != "true" ]]; then
        echo ""
        echo "=========================================================================================================================================="
        echo ">>> [ERROR] REVERSE-DIFF BOOTSTRAP DISTCP FAILED for: $d <<<"
        echo "=========================================================================================================================================="
        log "[ERROR] [REVERSE-BOOTSTRAP] Incremental reverse diff failed for $d (see $bootstrap_err)"
        if [[ -f "$bootstrap_err" ]] && [[ -s "$bootstrap_err" ]]; then
            analyze_error "$bootstrap_err"
        fi

        # --- Split-brain safety: NEVER auto-discard data on the new destination ---
        if grep -q "The target has been modified since snapshot" "$bootstrap_err" 2>/dev/null ||
           grep -q "target has changed since snapshot" "$bootstrap_err" 2>/dev/null; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] DIVERGENT WRITES DETECTED DURING REVERSE-DIFF BOOTSTRAP for $d <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "  The new destination ($DEST_CLUSTER, the pre-failover source) has data that does"
            echo "  NOT match its own '$last_snap' snapshot. This typically means writes landed on"
            echo "  $DEST_CLUSTER (directly or via lingering jobs) after the outage/failover began."
            echo ""
            echo "  This script will NOT automatically discard or overwrite data on $DEST_CLUSTER."
            echo "  Automatic destructive rollback is intentionally never attempted in this path."
            echo ""
            echo "  --- Option 1: Manually reconcile divergent writes on $DEST_CLUSTER ---"
            echo "    Inspect what changed since '$last_snap':"
            echo "      hdfs ${nameservice_ha_display_args}snapshotDiff -fs hdfs://$DST_URI_NS $d $last_snap ."
            echo "    Reconcile or archive the divergent files, then re-run this script."
            echo ""
            echo "  --- Option 2: force a full re-baseline (explicit, discards diff optimization) ---"
            echo "    Confirm which side holds authoritative data, then clear ALL state (local AND"
            echo "    the HDFS-mirrored copies on both clusters) to force Stage 3 to re-baseline"
            echo "    from scratch in the CURRENT direction:"
            echo ""
            echo "      rm -f $state"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo ""
            echo "    IMPORTANT: Deleting only the local file ($state) is NOT sufficient and will"
            echo "    NOT work as expected -- an HDFS-mirrored copy of this state (written on both"
            echo "    clusters after every successful sync) will still exist, and the next run"
            echo "    will automatically rehydrate the local file from it, silently undoing this"
            echo "    step. All three locations above must be cleared together."
            echo ""
            echo "    ALSO REQUIRED: delete every existing ${SNAP_PREFIX}_* snapshot for $d on BOTH"
            echo "    clusters BEFORE re-running. Direction/continuation is now derived live from"
            echo "    actual snapshot indices on both clusters (see [DIRECTION-DERIVE] in the logs) --"
            echo "    if old numbered snapshots from before this recovery are left in place, a LATER"
            echo "    run could find one of them as a coincidental \"last common index\" between the"
            echo "    two clusters and treat it as valid continuation history, instead of the fresh"
            echo "    ${SNAP_PREFIX}_0 baseline Stage 3 is about to create. That would let a future"
            echo "    run attempt an incremental diff against data that has already moved past this"
            echo "    recovery, which (if ROLLBACK_ON_FAILURE=yes) risks a rollback that reverts the"
            echo "    destination to a state from BEFORE this recovery completed, discarding it."
            echo "    List and delete them explicitly, e.g.:"
            echo ""
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "      # for each ${SNAP_PREFIX}_<N> snapshot listed on EITHER cluster:"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo ""
            echo "    Deleting those snapshots is also what makes Stage 3 agree to re-baseline: it"
            echo "    confirms 'brand new' against live snapshot listings, not just against a missing"
            echo "    state file, and refuses to baseline while unshared ${SNAP_PREFIX}_* snapshots"
            echo "    remain. If you deliberately keep them, re-run with FORCE_REBASELINE=yes to"
            echo "    override that check -- but deleting them is the safer path."
            echo ""
            echo "    Then re-run. This performs a FULL distcp (not incremental) and creates a new"
            echo "    ${SNAP_PREFIX}_0 baseline in the CURRENT direction ($SOURCE_CLUSTER -> $DEST_CLUSTER)."
            echo "    WARNING: confirm which side holds authoritative data before doing this --"
            echo "    a full re-baseline copies $SOURCE_CLUSTER over $DEST_CLUSTER and will overwrite"
            echo "    whatever divergent data exists on $DEST_CLUSTER."
            echo ""
            echo "  --- Option 3: Inspect .snapshot dirs on both clusters ---"
            echo "    hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "    hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS -ls $d/.snapshot"
            echo ""
            echo "=========================================================================================================================================="
            log "[ERROR] [REVERSE-BOOTSTRAP] Divergent writes detected on $DEST_CLUSTER for $d. Manual reconciliation required. No automatic rollback attempted (by design)."
        else
            log "[ERROR] [REVERSE-BOOTSTRAP] Non-snapshot-modified failure for $d. Manual inspection required (see $bootstrap_err)."
        fi

        # Best-effort cleanup: remove the snapshot we created on the new source this attempt, so a re-run
        # doesn't see a stale "already exists" and skip re-checking it. (Left in place is also safe; harmless
        # either way. Removing keeps retry semantics closest to "nothing happened yet".)
        run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -deleteSnapshot "$d" "$reverse_next_snap" 2>/dev/null || true

        return 1
    fi

    log "[INFO] [REVERSE-BOOTSTRAP] Incremental reverse diff succeeded for $d"

    # --- Step 3: create matching snapshot on the NEW destination ---
    log_substage "Reverse-diff bootstrap Step 3: creating $reverse_next_snap on new destination ($DEST_CLUSTER)"
    local out_dst
    out_dst=$(run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$reverse_next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
    if echo "$out_dst" | grep -q "already a snapshot with the same name"; then
        log "[WARN] [REVERSE-BOOTSTRAP] Snapshot $reverse_next_snap already exists on new destination for $d"
    elif echo "$out_dst" | grep -q "Created snapshot"; then
        log "[INFO] [REVERSE-BOOTSTRAP] Snapshot $reverse_next_snap created on new destination for $d"
    else
        echo "[ERROR] Reverse-diff bootstrap: FAILED to create $reverse_next_snap on new destination ($DEST_CLUSTER): $d"
        log "[ERROR] [REVERSE-BOOTSTRAP] Destination snapshot creation failed: $out_dst. Data was copied but state NOT advanced -- re-run will retry snapshot creation."
        return 1
    fi

    # --- Step 4: advance state, recording the NEW direction ---
    if write_state_file "$state" "$(build_state_content "$reverse_next_snap")" "$key"; then
        log "[REVERSE-BOOTSTRAP] State advanced to $reverse_next_snap for $d (direction now: $SOURCE_CLUSTER -> $DEST_CLUSTER)"
    else
        log "[ERROR] [REVERSE-BOOTSTRAP] Failed to write state file $state after successful bootstrap for $d"
        return 1
    fi

    METRICS_SUCCESSFUL_DIRECTORIES=$((METRICS_SUCCESSFUL_DIRECTORIES + 1))

    # --- Step 5: cleanup old snapshots on both clusters (same as normal Stage 4 4g/4h) ---
    cleanup_old_snapshots "$SRC_URI_NS" "$d" "source" "$SNAP_RETAIN" "$SNAP_PREFIX"
    cleanup_old_snapshots "$DST_URI_NS" "$d" "destination" "$SNAP_RETAIN" "$SNAP_PREFIX"

    return 0
}

# -----------------------------------------------------------------------------
# main()
# -----------------------------------------------------------------------------
main() {
    # -------------------------------------------------------------------------
    # Same-nameservice DR support: SOURCE_CLUSTER and DEST_CLUSTER are ROLE LABELS (and, for state-file keys,
    # job tags, and log lines, remain exactly what the operator passed) -- but the actual "hdfs://<name>" URIs
    # this script builds, and the HA client -D properties derived for AUTO_DERIVE_HA_CLIENT_CONFIG, need each
    # cluster to resolve to a DISTINCT set of NameNodes. That's normally satisfied automatically because
    # production and DR nameservices have different names. It breaks when a DR cluster is built from the same
    # blueprint as production and BOTH sides legitimately use the same nameservice ID (e.g. both "ODP-Phoenix")
    # -- a single Hadoop client cannot bind two different NameNode sets to one nameservice name at the same
    # time, so a bare "hdfs://ODP-Phoenix" would be ambiguous about which physical cluster it means.
    #
    # SRC_URI_NS / DST_URI_NS below are the names actually used in every "hdfs://" URI and in the derived HA
    # -D properties (see derive_nameservice_ha_conf). In the normal (non-colliding) case they are just
    # SOURCE_CLUSTER/DEST_CLUSTER unchanged. In the colliding case, SRC_URI_NS becomes a synthetic,
    # script-internal alias ("<name>-SRCALIAS") and DST_URI_NS becomes the DR cluster's real, resolved bare
    # host:port (see the aliasing doc comment inside the collision branch below for the full "why" -- source
    # is aliased, not destination, specifically to avoid ever injecting the real shared nameservice name as a
    # "-D" property, which would make fs.defaultFS itself ambiguous). The real nameservice name is never
    # renamed on either cluster; the alias only ever appears in THIS script's own "-D" injected HA config and
    # the URIs it builds, both of which are process-local and thrown away when the script exits.
    #
    # This requires AUTO_DERIVE_HA_CLIENT_CONFIG=yes with SRC_NN_HOSTS/DST_NN_HOSTS set: aliasing the source only
    # fixes the ambiguity if the script is ALSO the thing supplying that alias's NameNode addresses via
    # injected -D properties. Without that, "hdfs://<alias>" would resolve nowhere (no hdfs-site.xml on earth
    # defines the synthetic alias), so we fail fast here instead of letting every later hdfs/distcp call hang
    # or error deep inside a stage.
    # -------------------------------------------------------------------------
    SRC_URI_NS="$SOURCE_CLUSTER"
    DST_URI_NS="$DEST_CLUSTER"
    SAME_NAMESERVICE_COLLISION="false"
    if [[ "$SOURCE_CLUSTER" == "$DEST_CLUSTER" ]]; then
        if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" != "yes" ]]; then
            echo "[ERROR] SOURCE_CLUSTER and DEST_CLUSTER are identical: '$SOURCE_CLUSTER'" >&2
            echo "[ERROR] This is only supported when the two are the SAME nameservice name shared by two" >&2
            echo "[ERROR] DIFFERENT physical clusters (e.g. a DR cluster built from the same blueprint as" >&2
            echo "[ERROR] production) -- and even then, this script needs AUTO_DERIVE_HA_CLIENT_CONFIG=yes with" >&2
            echo "[ERROR] SRC_NN_HOSTS/DST_NN_HOSTS set so it can tell the two clusters apart internally." >&2
            echo "[ERROR] Set those three variables, or pass distinct nameservice names / host:port values" >&2
            echo "[ERROR] for SOURCE_CLUSTER (arg 1) and DEST_CLUSTER (arg 2)." >&2
            exit 2
        fi
        SAME_NAMESERVICE_COLLISION="true"
        # -------------------------------------------------------------------------
        # ALIAS THE SOURCE, NOT THE DESTINATION. An earlier version of this fix aliased the
        # destination ("<name>-DRDST") and, once the destination was resolved to a bare
        # host:port, injected "dfs.nameservices=<real-name>" (e.g. "ODP-Phoenix") for the
        # SOURCE side directly -- since in the normal case SOURCE_CLUSTER/DEST_CLUSTER just
        # ARE the real name already. This seemed safe (the real name is a real, resolvable
        # nameservice, unlike a synthetic alias) but broke two ways, both confirmed by direct
        # testing on odplab001/odplab002 (DR) against atlasdemo-01/02 (prod), both literally
        # named "ODP-Phoenix" since DR was built from the same blueprint as prod:
        #
        #   1) fs.defaultFS on BOTH clusters is statically "hdfs://ODP-Phoenix" (their own
        #      native hdfs-site.xml -- normally correct, since it means "this cluster" on
        #      each). Injecting "-Ddfs.nameservices=ODP-Phoenix" pointed at PRODUCTION's
        #      NameNode addresses makes fs.defaultFS ITSELF ambiguous for the lifetime of the
        #      process: every scheme-less path this run touches (MapReduce's own job-staging
        #      directory, "/user/<user>/.staging/job_<id>", not overridable via a simple "-D")
        #      silently resolves to PRODUCTION instead of local DR HDFS. That staging dir then
        #      gets localized by the AM container using the SOURCE token -- which pull mode
        #      correctly excludes from renewal (YARN doesn't run on the source), so the token
        #      is non-renewable and the AM container fails: "Token for real user: , can't be
        #      found in cache" at FSDownload.verifyAndCopy -- confirmed by direct testing.
        #   2) The obvious counter-fix, "-Dfs.defaultFS=hdfs://<bare-DR-host:port>", DOES fix
        #      the localization failure above, but breaks resolution of the fully-qualified
        #      "hdfs://ODP-Phoenix/..." SOURCE URI itself: confirmed by direct testing that
        #      even a plain "hdfs dfs -Dfs.defaultFS=hdfs://<DR-host:port> -ls
        #      hdfs://ODP-Phoenix/<real-path>" (no DistCp involved at all) returns "No such
        #      file or directory" for a path that demonstrably exists. Hadoop's internal
        #      FileSystem/HA-proxy-provider cache keys by authority STRING, not by which "-D"
        #      property introduced it, so overriding fs.defaultFS to a different literal
        #      value while ALSO injecting "dfs.nameservices=ODP-Phoenix" (same string
        #      fs.defaultFS used to be) corrupts resolution of that name for the rest of the
        #      process -- a genuine Hadoop client-side ambiguity, not fixable by choosing a
        #      different property to override.
        #
        # The fix that avoids BOTH failure modes: never inject the literal string "ODP-Phoenix"
        # (or whatever SOURCE_CLUSTER's real name is) as a "-D" property AT ALL. Alias the
        # SOURCE side instead -- SRC_URI_NS becomes "<name>-SRCALIAS", with its OWN
        # "dfs.namenode.rpc-address.<alias>.*" entries pointing at production's real NameNode
        # addresses. fs.defaultFS ("hdfs://ODP-Phoenix") is then NEVER touched by anything this
        # script injects, so it keeps resolving via each cluster's own native, unmodified
        # hdfs-site.xml exactly as it always has -- no ambiguity, no staging-dir localization
        # failure, and (since the framework path is also scheme-less and default-FS-relative)
        # no need for the mapreduce.application.framework.path override either -- that
        # override existed ONLY to counteract fs.defaultFS becoming ambiguous, which no longer
        # happens under this design.
        #
        # DESTINATION SIDE IS UNCHANGED: DST_URI_NS is still resolved to the DR cluster's real,
        # currently-ACTIVE bare host:port (see resolve_active_namenode_hostport below) --
        # that part of the original design was already confirmed working via direct testing
        # (successful DistCp job submission, token renewal, AM localization all succeeded
        # once the alias was replaced with a concrete destination host:port) and is orthogonal
        # to the source-side ambiguity fixed here.
        # -------------------------------------------------------------------------
        SRC_URI_NS="${SOURCE_CLUSTER}-SRCALIAS"
        log "[INFO] [NAMESERVICE-ALIAS] SOURCE_CLUSTER and DEST_CLUSTER share nameservice '$SOURCE_CLUSTER'."
        log "[INFO] [NAMESERVICE-ALIAS] Using internal alias '$SRC_URI_NS' for SOURCE hdfs:// URIs and HA"
        log "[INFO] [NAMESERVICE-ALIAS] client config only -- the real production nameservice name is never"
        log "[INFO] [NAMESERVICE-ALIAS] injected as a '-D' property, so fs.defaultFS ('hdfs://$SOURCE_CLUSTER'"
        log "[INFO] [NAMESERVICE-ALIAS] on both clusters, since DR shares prod's blueprint) is never made"
        log "[INFO] [NAMESERVICE-ALIAS] ambiguous -- confirmed necessary because aliasing the destination"
        log "[INFO] [NAMESERVICE-ALIAS] alone let scheme-less paths (the MapReduce job staging directory)"
        log "[INFO] [NAMESERVICE-ALIAS] silently resolve against production using a non-renewable token."
        log "[INFO] [NAMESERVICE-ALIAS] DEST_URI_NS is separately resolved to the DR cluster's real, currently-"
        log "[INFO] [NAMESERVICE-ALIAS] ACTIVE NameNode host:port below (see resolve_active_namenode_hostport)."
    fi

    # -------------------------------------------------------------------------
    # Validate arguments FIRST (before any system-dependent checks like check_prerequisites) so that argument
    # errors are reported immediately regardless of whether hadoop/hdfs/curl are installed.
    # -------------------------------------------------------------------------

    # Materialize + validate the DistCp exclusion file from DISTCP_EXCLUDE_PATTERNS
    # (job-keyed, idempotent -- see resolve_distcp_exclude_file). No pre-made
    # file is ever expected from the operator.
    if [[ "${DISTCP_EXCLUDE_ENABLED,,}" == "yes" ]]; then
        resolve_distcp_exclude_file
        DISTCP_EXCLUDE_OPTS="-filters $DISTCP_EXCLUDE_FILE"
    else
        DISTCP_EXCLUDE_OPTS=""
    fi

    # Validate REPLICATION_MODE
    case "${REPLICATION_MODE,,}" in
        ""|pull|push)
            : # valid
            ;;
        *)
            echo "[ERROR] Invalid value for REPLICATION_MODE (arg 14): '${REPLICATION_MODE}'" >&2
            echo "[ERROR] Accepted values: 'pull' or 'push'" >&2
            exit 16
            ;;
    esac

    # Validate REVERSE_DIFF_BOOTSTRAP
    case "${REVERSE_DIFF_BOOTSTRAP,,}" in
        ""|no|yes)
            : # valid
            ;;
        *)
            echo "[ERROR] Invalid value for REVERSE_DIFF_BOOTSTRAP (arg 16): '${REVERSE_DIFF_BOOTSTRAP}'" >&2
            echo "[ERROR] Accepted values: 'yes' or 'no'" >&2
            exit 17
            ;;
    esac

    # Validate AUTO_DERIVE_HA_CLIENT_CONFIG
    case "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" in
        ""|no|yes)
            : # valid
            ;;
        *)
            echo "[ERROR] Invalid value for AUTO_DERIVE_HA_CLIENT_CONFIG (env var): '${AUTO_DERIVE_HA_CLIENT_CONFIG}'" >&2
            echo "[ERROR] Accepted values: 'yes' or 'no'" >&2
            exit 18
            ;;
    esac

    # Backup existing log file and create new one for this execution (before redirecting output)
    backup_and_create_new_log "$LOG"

    # Trap for failure summary on exit and temporary file cleanup
    trap '[[ "$SCRIPT_FAILED" == "yes" ]] && print_failure_summary; cleanup_temp_files' EXIT INT TERM

    # Check prerequisites (required commands) - must be after log setup
    check_prerequisites

    # Initialize Kerberos detection (must be done early, before output redirection)
    init_kerberos_detection

    # Re-enable debug logging if requested via environment variable
    enable_debug_if_needed

    # Log filter details (after validation passed above)
    if [[ "${DISTCP_EXCLUDE_ENABLED,,}" == "yes" ]]; then
        log "[INFO] DistCp path exclusion filter ENABLED: $DISTCP_EXCLUDE_FILE"
        log "[INFO] Filter patterns:"
        while IFS= read -r pattern; do
            [[ -z "$pattern" || "$pattern" == \#* ]] && continue
            log "[INFO]   - $pattern"
        done < "$DISTCP_EXCLUDE_FILE"
    fi

    # Extract hostnames without ports for JMX checks
    source_host="${SOURCE_CLUSTER%%:*}"
    dest_host="${DEST_CLUSTER%%:*}"
    
    # Redirect all output to log file and also echo to stdout This ensures all output (stdout and stderr) goes
    # through the same tee process for real-time visibility without buffering issues. All subsequent output
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
    if [[ "${REPLICATION_MODE,,}" == "push" ]]; then
        echo "Replication Mode    : PUSH (YARN jobs run on source/production cluster)"
    else
        echo "Replication Mode    : PULL (YARN jobs run on target/DR cluster)"
    fi
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
    echo "  Arg 10 (AUTO_FULL_DISTCP)    : $AUTO_FULL_DISTCP"
    echo "  Arg 11 (ROLLBACK_ON_FAILURE) : $ROLLBACK_ON_FAILURE"
    echo "  Arg 12 (KERBEROS_ENABLED)    : $KERBEROS_ENABLED"
    echo "  Arg 13 (DISTCP_EXCLUDE_PATTERNS) : ${DISTCP_EXCLUDE_PATTERNS:-<disabled>}"
    echo "  Arg 14 (REPLICATION_MODE)    : $REPLICATION_MODE"
    echo "  Arg 15 (LOG_PATH)            : $LOG"
    echo "  Arg 16 (REVERSE_DIFF_BOOTSTRAP) : $REVERSE_DIFF_BOOTSTRAP"
    echo "  Arg 17 (HDFS_STATE_DIR)      : $HDFS_STATE_DIR"
    echo "  DIR_BOOTSTRAP_MODE (fixed)   : $DIR_BOOTSTRAP_MODE (hardcoded, not configurable)"
    echo "  AUTO_DERIVE_HA_CLIENT_CONFIG     : $AUTO_DERIVE_HA_CLIENT_CONFIG"
    if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
        echo "  SRC_NN_HOSTS                 : $SRC_NN_HOSTS"
        echo "  DST_NN_HOSTS                 : $DST_NN_HOSTS"
        echo "  HA config will be derived for: $SOURCE_CLUSTER, $DEST_CLUSTER (at Stage 1)"
    fi
    echo "  YARN App Tags                : $YARN_APP_TAGS"
    if [[ "${DISTCP_EXCLUDE_ENABLED,,}" == "yes" ]]; then
        echo "  DistCp Exclude Filter        : ENABLED (generated: $DISTCP_EXCLUDE_FILE)"
    else
        echo "  DistCp Filter                : DISABLED"
    fi
    echo "════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════════"
    echo ""

    # -----------------------------------------------------------------------------
    # Stage 1: Pre-check clusters health (see check_cluster_health) Skip health checks if:
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
    
    # Configure DistCp MapReduce options based on replication mode The cluster where YARN does NOT run must be
    # excluded from token renewal, because the local ResourceManager cannot renew remote delegation tokens.
    DISTCP_MAPREDUCE_OPTS=""
    # Keyed by SRC_URI_NS/DST_URI_NS (the alias-aware names -- see main()'s doc comment), not raw
    # SOURCE_CLUSTER/DEST_CLUSTER, so the token-renewal-exclude property below always names whatever
    # dfs.nameservices/dfs.ha.namenodes.* (or, in the same-nameservice-collision case, the bare resolved
    # host:port -- see resolve_active_namenode_hostport) actually appears in the "hdfs://..." URIs this run
    # builds, never the ambiguous shared name.
    #
    # IMPORTANT: used verbatim, WITHOUT a "${VAR%%:*}" strip. An earlier version of this stripped everything
    # after the first ":" (intended to turn a "host:port" into a bare nameservice name for the normal case,
    # where SRC_URI_NS/DST_URI_NS never contain a colon anyway, making the strip a harmless no-op there). In
    # the same-nameservice-collision case, DST_URI_NS is a real, resolved "host:port" (e.g.
    # "odplab002.adsre.com:8020") -- stripping at the first ":" silently truncated it to just the bare
    # hostname, losing ":8020". PUSH mode uses DST_NAMESERVICE for
    # "-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${DST_NAMESERVICE}", so a truncated value there
    # would never match the real "host:port" authority actually present in every "hdfs://$DST_URI_NS" URI
    # this script builds, silently defeating the exclude and risking the exact token-renewal failure this
    # property exists to prevent. (PULL mode, the only mode confirmed by live testing so far, uses
    # SRC_NAMESERVICE instead, which is always a bare name with no colon -- collision or not -- so this bug
    # was dormant/untested until PUSH mode is exercised in the collision case.)
    SRC_NAMESERVICE="${SRC_URI_NS}"
    DST_NAMESERVICE="${DST_URI_NS}"

    case "${REPLICATION_MODE,,}" in
        ""|pull)
            # PULL MODE (default): YARN runs on target/destination cluster. Exclude SOURCE from token renewal.
            REPLICATION_MODE="pull"
            DISTCP_MAPREDUCE_OPTS="-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${SRC_NAMESERVICE}"
            log "[INFO] Pull mode: Excluding source ($SRC_NAMESERVICE) from token renewal (YARN runs on target)"
            ;;
        push)
            # PUSH MODE: YARN runs on source/production cluster. Exclude DESTINATION from token renewal.
            DISTCP_MAPREDUCE_OPTS="-Dmapreduce.job.hdfs-servers.token-renewal.exclude=${DST_NAMESERVICE}"
            log "[INFO] Push mode: Excluding destination ($DST_NAMESERVICE) from token renewal (YARN runs on source)"
            ;;
        *)
            echo "[ERROR] Invalid value for REPLICATION_MODE (arg 17): '${REPLICATION_MODE}'" >&2
            echo "[ERROR] Accepted values: 'pull' or 'push'" >&2
            exit 16
            ;;
    esac
    log "[INFO] Token renewal exclusion: $DISTCP_MAPREDUCE_OPTS"
    
    # Update DISTCP_FULL_OPTS with MapReduce options
    DISTCP_FULL_OPTS="$YARN_QUEUE_OPTS $YARN_APP_TAGS $DISTCP_MAPREDUCE_OPTS $DISTCP_DEBUG_OPTS"
    log "[INFO] Updated DistCp options: $DISTCP_FULL_OPTS"
    
    # -----------------------------------------------------------------------------
    # Kerberos detection before Stage 1 (if Kerberos is enabled) This ensures KRB5CCNAME is set before JMX
    # health checks
    # -----------------------------------------------------------------------------
    if [[ "$KERBEROS_ENABLED" == "yes" ]]; then
        echo ""
        echo "────────────────────────────────────────────"
        echo ">>> KERBEROS DETECTION (Before Stage 1) <<<"
        echo "────────────────────────────────────────────"
        log "[INFO] Detecting Kerberos credentials before Stage 1..."
        if detect_kerberos_enabled; then
            log "[INFO] Kerberos credentials detected successfully"
            if [[ -n "${KRB5CCNAME:-}" ]]; then
                log "[INFO] Using Kerberos cache: $KRB5CCNAME"
            fi
        else
            log "[WARN] Kerberos is enabled but no valid credentials detected"
            log "[WARN] JMX health checks may fail. Ensure Kerberos tickets are available."
        fi
        echo "────────────────────────────────────────────"
        echo ""
    fi
    
    # -----------------------------------------------------------------------------
    # Same-nameservice collision: resolve DST_URI_NS to the DR cluster's real, currently-ACTIVE NameNode
    # host:port BEFORE deriving any HA client config below. This must happen first (not after, as an earlier
    # version of this fix had it) so that derive_nameservice_ha_conf() never sees DST_URI_NS still equal to
    # the raw DEST_CLUSTER value (the literal shared nameservice name, e.g. "ODP-Phoenix") -- injecting that
    # literal name as a "-D" property is exactly the ambiguity the SRC_URI_NS aliasing above exists to avoid
    # (see the doc comment on SRC_URI_NS's aliasing, above), and it would defeat that fix if it slipped in via
    # the destination side instead. resolve_active_namenode_hostport() needs no "-D" HA properties itself (it
    # queries each candidate NameNode's own JMX endpoint directly by host:port -- see its doc comment), so it
    # has no ordering dependency on derive_nameservice_ha_conf() either way.
    # -----------------------------------------------------------------------------
    if [[ "$SAME_NAMESERVICE_COLLISION" == "true" ]]; then
        resolve_active_namenode_hostport "$DST_NN_HOSTS"
        DST_URI_NS="$RESOLVED_ACTIVE_NN_HOSTPORT"
        log "[INFO] [NAMESERVICE-ALIAS] DST_URI_NS resolved to active NameNode: $DST_URI_NS"
    fi

    # -----------------------------------------------------------------------------
    # Derive combined HA NameService client config (AUTO_DERIVE_HA_CLIENT_CONFIG), UNCONDITIONALLY and BEFORE any
    # Stage 1 branching below.
    #
    # CRITICAL FIX: this used to be called only from inside the "source_is_ha || dest_is_ha" elif branch of
    # Stage 1's health-check dispatch -- which meant it was SILENTLY SKIPPED whenever:
    #   (a) SKIP_HEALTH_CHECKS=yes was ALSO set (Stage 1's outer `if` took the
    #       "SKIP_HEALTH_CHECKS" arm instead of the HA arm, even though both
    #       conditions were true), or
    #   (b) neither cluster was in bare-NameService form (source_is_ha and
    #       dest_is_ha both false, e.g. during testing with host:port values),
    #       so the ENTIRE outer `if` was false and Stage 1 took the plain JMX
    #       health-check `else` branch instead.
    # In both cases, an operator who explicitly set AUTO_DERIVE_HA_CLIENT_CONFIG=yes (specifically because a
    # NameService is otherwise unresolvable) got NONE of the derived "-D" HA properties injected into any
    # later hdfs/distcp call, NONE of the fail-fast NN_HOSTS validation, and no indication whatsoever that the
    # flag had been ignored -- reproducing the exact multi-minute-hang failure this feature exists to prevent.
    # Deriving here, unconditionally, ahead of all Stage 1 branches, ensures the feature applies regardless of
    # SKIP_HEALTH_CHECKS or which cluster-address form is used.
    #
    # SAME-NAMESERVICE COLLISION CASE: by the time this runs, SRC_URI_NS is already the "<name>-SRCALIAS"
    # alias (set at the top of main(), before argument validation) and DST_URI_NS is already the real,
    # resolved bare host:port from the block immediately above -- derive_nameservice_ha_conf() therefore
    # derives "dfs.ha.namenodes.<name>-SRCALIAS.*"/"dfs.namenode.rpc-address.<name>-SRCALIAS.*" HA properties
    # for the SOURCE alias only (DST_URI_NS being a bare host:port needs, and must never receive, any HA
    # client config -- _derive_one_cluster_ha_props is never called for it). The combined
    # "dfs.nameservices=<name>-SRCALIAS,<bare-host>:<port>" property this produces is harmless: Hadoop simply
    # never finds "dfs.ha.namenodes.<bare-host>:<port>" for the second entry and treats it as a plain,
    # non-HA filesystem reference, which is exactly what it is.
    # -----------------------------------------------------------------------------
    if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
        derive_nameservice_ha_conf
    fi

    # -----------------------------------------------------------------------------
    # Stage 1a: Superuser privilege check (runs UNCONDITIONALLY, ahead of the
    # SKIP_HEALTH_CHECKS/HA branching below) -- same rationale as the
    # AUTO_DERIVE_HA_CLIENT_CONFIG derivation above: a check placed inside only one of Stage
    # 1's branches would be silently skipped whenever the other branch is the one that
    # fires. Missing superuser privilege on either cluster otherwise surfaces much later
    # and more confusingly, as an allowSnapshot/createSnapshot failure in Stage 2/3 --
    # or, if only ONE cluster is missing the grant, as what looks like a per-directory
    # problem instead of an identity/permission one.
    # -----------------------------------------------------------------------------
    log_stage "1" "Cluster Health Checks"
    log_substage "Verifying superuser privilege on both clusters"
    superuser_ok=true
    if ! check_superuser_privilege "$SRC_URI_NS" "SOURCE"; then
        superuser_ok=false
    fi
    if ! check_superuser_privilege "$DST_URI_NS" "DEST"; then
        superuser_ok=false
    fi
    if [[ "$superuser_ok" != "true" ]]; then
        log_stage_failed "1" "Cluster Health Checks" "Superuser privilege check failed (see [ERROR] lines above)"
        exit 1
    fi

    # -----------------------------------------------------------------------------
    # Stage 1b: Cluster reachability / HA-state checks (see check_cluster_health)
    # -----------------------------------------------------------------------------
    if [[ "$SKIP_HEALTH_CHECKS" == "yes" ]] || [[ "$source_is_ha" == "true" ]] || [[ "$dest_is_ha" == "true" ]]; then
        if [[ "$SKIP_HEALTH_CHECKS" == "yes" ]]; then
            log "[INFO] Skipping cluster health checks (SKIP_HEALTH_CHECKS=yes)"
            if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
                log "[WARN] AUTO_DERIVE_HA_CLIENT_CONFIG=yes: HA client config was derived above, but the"
                log "[WARN] reachability re-verification normally performed in Stage 1 is ALSO skipped here"
                log "[WARN] because SKIP_HEALTH_CHECKS=yes. A wrong SRC_NN_HOSTS/DST_NN_HOSTS value will"
                log "[WARN] now only surface later, as a real hdfs/distcp failure, not as a clear Stage 1 error."
            fi
        elif [[ "$source_is_ha" == "true" ]] || [[ "$dest_is_ha" == "true" ]]; then
            log "[INFO] JMX HA-state check skipped for NameService cluster(s) (cannot be accessed directly via JMX)."
            log "[INFO] Running a bounded reachability check instead so an unreachable/misconfigured NameService"
            log "[INFO] fails fast here rather than hanging on the first real HDFS command later."

            reachability_ok=true
            if [[ "${AUTO_DERIVE_HA_CLIENT_CONFIG,,}" == "yes" ]]; then
                # HA config (both clusters) was already derived above -- see derive_nameservice_ha_conf's doc
                # comment: this is ALWAYS a single combined "-Ddfs.nameservices=SRC,DST" set, never two
                # separate competing single-name flags. Verify reachability for BOTH clusters with it in
                # effect, regardless of which one is in bare-NameService form (a non-HA host:port cluster
                # paired with an HA one can still benefit from the combined config if this host's native
                # config only knows one side).
                if ! check_nameservice_reachable "$SRC_URI_NS" "SOURCE"; then
                    reachability_ok=false
                fi
                if ! check_nameservice_reachable "$DST_URI_NS" "DEST"; then
                    reachability_ok=false
                fi
            else
                if [[ "$source_is_ha" == "true" ]]; then
                    if ! check_nameservice_reachable "$SRC_URI_NS" "SOURCE"; then
                        reachability_ok=false
                    fi
                fi
                if [[ "$dest_is_ha" == "true" ]]; then
                    if ! check_nameservice_reachable "$DST_URI_NS" "DEST"; then
                        reachability_ok=false
                    fi
                fi
            fi
            if [[ "$reachability_ok" != "true" ]]; then
                log_stage_failed "1" "Cluster Health Checks" "NameService reachability check failed (see [ERROR] lines above)"
                exit 1
            fi
        fi
        log_stage_complete "1" "Cluster Health Checks"
    else
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
    # Stage 2: Enable snapshots on every directory, every run (idempotent -- see the
    # per-directory loop below for why this always re-verifies rather than trusting a
    # one-time lock file).
    # -----------------------------------------------------------------------------
    log_stage "2" "Enable Snapshot Capability (Per-Directory)"
    mkdir -p "$SNAP_LOCK_DIR"

    # Ensure the HDFS-mirrored state directory exists on BOTH clusters (idempotent, once per invocation, not
    # per-directory -- same idempotency philosophy as SNAP_LOCK_DIR above, just extended to two remote
    # filesystems). Best-effort: failure here does NOT abort the run. It only means HDFS state mirroring will
    # be unavailable this run (mirror_state_file_to_hdfs's own -put calls will then also fail and log [WARN],
    # but local-only operation continues normally).
    ensure_hdfs_state_dir "$SRC_URI_NS" "SOURCE"
    ensure_hdfs_state_dir "$DST_URI_NS" "DEST"

    log "[DEBUG] Enabling snapshots on source and destination directories"
    for d in "${SOURCE_DIRS[@]}"; do
        dir_start_ts=$(date +%s)
        key=$(sanitize "$d")
        dir_lock="${SNAP_LOCK_DIR}/${key}.lock"

        # NOTE: allowSnapshot is called EVERY run, regardless of whether $dir_lock already
        # exists. It is idempotent server-side ("already snapshottable" is treated as
        # success below), so this is safe and cheap. The lock file is kept only as an
        # informational marker of "has this directory ever completed Stage 2 successfully"
        # (used by nothing safety-critical) -- NOT as a gate that skips re-verification.
        # Trusting a stale lock forever previously let a destination directory that lost
        # its snapshottable flag out-of-band (recreated dir, disallowSnapshot, restore from
        # a non-snapshottable backup, etc.) silently stay broken run after run, since Stage 2
        # would skip straight past it while Stage 3/4 kept failing with "Directory is not a
        # snapshottable directory".
        log "[DEBUG] Enabling snapshots for directory: $d"
        log_substage "Enabling on SOURCE ($SRC_URI_NS): $d"
        log "[DEBUG] Allowing snapshot on source dir: $d"
        allow_snap_output=$(run_as_hdfs hdfs dfsadmin -fs "hdfs://$SRC_URI_NS" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true)
        allow_snap_rc=$?
        if [[ $allow_snap_rc -eq 0 ]] || echo "$allow_snap_output" | grep -qi "already.*snapshottable"; then
            [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
            log "[INFO] Snapshot enabled on source directory $d"
            src_snap_ok=true
        else
            [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
            echo "[ERROR] FAILED to enable snapshot on SOURCE directory $d"
            log "[ERROR] Failed to enable snapshot on source directory $d"
            log "[ERROR] This may indicate permission issues or the directory doesn't exist on source cluster."
            src_snap_ok=false
        fi

        # Check if destination dir exists
        log_substage "Enabling on DESTINATION ($DST_URI_NS): $d"
        if ! run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -test -d "$d"; then
            # auto mode: create dummy dir with source perms/ownership
            if [[ "$DIR_BOOTSTRAP_MODE" == "yes" ]]; then
                log "[INIT] Destination dir $d missing. Creating with same owner/permissions as source."
                # Capture output and filter out log lines (lines starting with timestamps like
                # "2026-01-03") Get only the actual stat output (should be in format "owner:group
                # permissions")
                prod_meta=$(run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -stat "%u:%g %a" "$d" 2>/dev/null | grep -v "^[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}" | tail -1 || true)
                owner_group=$(echo "$prod_meta" | awk '{print $1}' || echo "")
                perms=$(echo "$prod_meta" | awk '{print $2}' || echo "")
                # Validate that we got valid owner:group format
                if [[ ! "$owner_group" =~ ^[^:]+:[^:]+$ ]]; then
                    log "[ERROR] Failed to get valid owner:group from source directory. Got: '$owner_group'"
                    log "[ERROR] Raw output: '$prod_meta'"
                    log "[WARN] Skipping chown, will use default permissions"
                    owner_group=""
                fi
                run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -mkdir -p "$d"
                if [[ -n "$owner_group" ]]; then
                    run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -chown "$owner_group" "$d"
                fi
                if [[ -n "$perms" ]]; then
                    run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -chmod "$perms" "$d"
                fi
            else
                log "[INIT] Destination dir $d missing in manual mode. It will be created by full DistCp."
            fi
        fi

        # Now allowSnapshot on destination (whether just created or already exists)
        log "[DEBUG] Allowing snapshot on destination dir: $d"
        allow_snap_output=$(run_as_hdfs hdfs dfsadmin -fs "hdfs://$DST_URI_NS" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true)
        allow_snap_rc=$?
        if [[ $allow_snap_rc -eq 0 ]] || echo "$allow_snap_output" | grep -qi "already.*snapshottable"; then
            [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
            log "[INFO] Snapshot enabled on destination directory $d"
            dst_snap_ok=true
        else
            [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
            echo "[ERROR] FAILED to enable snapshot on DESTINATION directory $d"
            log "[ERROR] Failed to enable snapshot on destination directory $d"
            log "[ERROR] This may indicate permission issues or the directory doesn't exist on destination cluster."
            dst_snap_ok=false
        fi

        if [[ "$src_snap_ok" == "true" ]] && [[ "$dst_snap_ok" == "true" ]]; then
            : >"$dir_lock"
            log "[DEBUG] Snapshot capability confirmed for directory $d (marker: $dir_lock)"
        else
            rm -f "$dir_lock" 2>/dev/null || true
            log "[WARN] allowSnapshot failed on one or both clusters for $d (will retry every run until it succeeds)"
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
    # Directories this run ACTUALLY baselined, and those whose baseline attempt failed.
    #
    # The $need_init blocks below (full DistCp, destination post-DistCp re-baseline, manual command printout)
    # MUST iterate these arrays rather than "${SOURCE_DIRS[@]}". They previously looped over every configured
    # directory and used "state file exists" to mean "this was baselined this run" -- but an ordinary,
    # long-running, already-syncing directory also has a state file. Consequence: adding ONE new directory to a
    # config with N already-replicating ones set need_init=true and then ran a FULL DistCp against all N+1 and
    # deleted+recreated the destination ${SNAP_PREFIX}_0 snapshot for all N+1. Tracking the baselined set
    # explicitly is also what makes the brand-new gate below safe: a directory it rehydrates must not be handed
    # to those blocks.
    BASELINED_DIRS=()
    BASELINE_FAILED_DIRS=()
    for d in "${SOURCE_DIRS[@]}"; do
        log "[DEBUG] Checking baseline snapshot for directory: $d"
        key=$(sanitize "$d")
        resolve_state_file_and_check_new "$key"
        state="$RESOLVED_STATE_FILE"
        if [[ "$IS_BRAND_NEW_DIR" == "true" ]]; then
            # The state cache says "brand new". Confirm that against LIVE snapshot listings on both clusters
            # before creating a baseline: total state loss is indistinguishable from "never replicated" by cache
            # absence alone, and baselining an already-replicating directory can silently gap DR forever. See
            # confirm_brand_new_against_live_snapshots for the two concrete failure modes this closes.
            confirm_brand_new_against_live_snapshots "$d"

            if [[ "$BRAND_NEW_VERDICT" == "has_history" ]]; then
                log "[INFO] [BRAND-NEW-GATE] $d: state cache absent, but $BRAND_NEW_VERDICT_REASON. Rehydrating state from live snapshots and SKIPPING baseline creation (no full copy needed)."
                if write_state_file "$state" "$(build_state_content "$BRAND_NEW_RECOVERED_SNAP")" "$key"; then
                    log "[INFO] [BRAND-NEW-GATE] $d: state rebuilt at $state from live snapshot '$BRAND_NEW_RECOVERED_SNAP' (and re-mirrored to both clusters). Stage 4 continues incrementally from there."
                else
                    log "[ERROR] [BRAND-NEW-GATE] $d: recovered last common snapshot '$BRAND_NEW_RECOVERED_SNAP' from live listings but FAILED to write state file $state (check disk space/permissions on $(dirname "$state")). Failing this directory rather than baselining over real data."
                    BASELINE_FAILED_DIRS+=("$d")
                    continue
                fi
                # Deliberately NOT added to BASELINED_DIRS, and need_init is left untouched: nothing was
                # baselined here, so this directory gets no full DistCp and no destination re-baseline.
                continue
            fi

            if [[ "$BRAND_NEW_VERDICT" != "new" ]]; then
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> [ERROR] CANNOT CONFIRM $d IS BRAND NEW -- REFUSING TO CREATE A BASELINE <<<"
                echo "=========================================================================================================================================="
                echo ""
                echo "  This directory has no state file (local or HDFS-mirrored), which normally means"
                echo "  \"never replicated\". That could NOT be confirmed against the clusters:"
                echo ""
                echo "    $BRAND_NEW_VERDICT_REASON"
                echo ""
                echo "  Creating a ${SNAP_PREFIX}_0 baseline now could overwrite live data on"
                echo "  $DEST_CLUSTER, or leave a bogus baseline that makes later incremental diffs"
                echo "  silently skip real changes. Refusing to do either."
                echo ""
                echo "  Inspect both sides and decide which holds authoritative data:"
                echo "    hdfs $(render_nameservice_ha_args_for_display)dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
                echo "    hdfs $(render_nameservice_ha_args_for_display)dfs -fs hdfs://$DST_URI_NS -ls $d/.snapshot"
                echo ""
                echo "  If you have confirmed that a full re-baseline in the CURRENT direction"
                echo "  ($SOURCE_CLUSTER -> $DEST_CLUSTER) is what you want, re-run with:"
                echo ""
                echo "    export FORCE_REBASELINE=yes"
                echo ""
                echo "  WARNING: that performs a FULL copy which overwrites $DEST_CLUSTER."
                echo ""
                echo "=========================================================================================================================================="
                echo ""
                log "[ERROR] [BRAND-NEW-GATE] $d: refusing to create a baseline -- $BRAND_NEW_VERDICT_REASON"
                BASELINE_FAILED_DIRS+=("$d")
                continue
            fi

            log "[INFO] [BRAND-NEW-GATE] $d: confirmed brand new -- $BRAND_NEW_VERDICT_REASON. Proceeding with baseline creation."
            need_init=true
            base="${SNAP_PREFIX}_0"
            local src_snap_created=false
            local dst_snap_created=false
            local out_base_src out_base_dst

            log_substage "Creating on SOURCE ($SRC_URI_NS): $d"
            log "[INIT] Creating baseline snapshot '$base' on source: $d"
            out_base_src=$(run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -createSnapshot "$d" "$base" 2>&1 | grep -v "^SLF4J:" || true) || true
            if echo "$out_base_src" | grep -q "already a snapshot with the same name"; then
                [[ -n "$out_base_src" ]] && echo "$out_base_src"
                log "[WARN] Baseline snapshot '$base' already exists on source for $d (idempotent re-run, e.g. after 'rm -f' state-file recovery guidance)"
                src_snap_created=true
            elif echo "$out_base_src" | grep -q "Created snapshot"; then
                [[ -n "$out_base_src" ]] && echo "$out_base_src"
                log "[INFO] Baseline snapshot '$base' created on source for $d"
                src_snap_created=true
            else
                [[ -n "$out_base_src" ]] && echo "$out_base_src"
                echo "[ERROR] FAILED to create baseline snapshot '$base' on SOURCE: $d"
                log "[ERROR] Failed to create baseline snapshot on source for $d: $out_base_src"
                log "[ERROR] Ensure snapshot capability is enabled and the directory exists on source cluster."
                src_snap_created=false
            fi

            log_substage "Creating on DESTINATION ($DST_URI_NS): $d"
            log "[INIT] Creating baseline snapshot '$base' on destination: $d"
            out_base_dst=$(run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$base" 2>&1 | grep -v "^SLF4J:" || true) || true
            if echo "$out_base_dst" | grep -q "already a snapshot with the same name"; then
                [[ -n "$out_base_dst" ]] && echo "$out_base_dst"
                log "[WARN] Baseline snapshot '$base' already exists on destination for $d (idempotent re-run, e.g. after 'rm -f' state-file recovery guidance)"
                dst_snap_created=true
            elif echo "$out_base_dst" | grep -q "Created snapshot"; then
                [[ -n "$out_base_dst" ]] && echo "$out_base_dst"
                log "[INFO] Baseline snapshot '$base' created on destination for $d"
                dst_snap_created=true
            else
                [[ -n "$out_base_dst" ]] && echo "$out_base_dst"
                echo "[ERROR] FAILED to create baseline snapshot '$base' on DESTINATION: $d"
                log "[ERROR] Failed to create baseline snapshot on destination for $d: $out_base_dst"
                log "[ERROR] Ensure snapshot capability is enabled and the directory exists on destination cluster."
                dst_snap_created=false
            fi

            # Only create state file if BOTH snapshots were created successfully This prevents the script from
            # thinking baseline is done when it's not
            if [[ "$src_snap_created" == "true" ]] && [[ "$dst_snap_created" == "true" ]]; then
                if write_state_file "$state" "$(build_state_content "$base")" "$key"; then
                    log "[INIT] Recorded baseline snapshot state in $state"
                    # Baseline genuinely created for this directory this run -> it (and only it) needs the full
                    # DistCp and destination re-baseline below.
                    BASELINED_DIRS+=("$d")
                else
                    log "[ERROR] Failed to write state file $state"
                    # Matches pre-existing behavior: with no state file this directory was skipped by the
                    # DistCp/manual blocks as "baseline creation failed".
                    BASELINE_FAILED_DIRS+=("$d")
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
                BASELINE_FAILED_DIRS+=("$d")
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

            # Report directories that did NOT get a baseline this run. Previously detected by re-resolving state
            # inside the copy loop below; now tracked explicitly in Stage 3 (see BASELINED_DIRS) so that an
            # already-syncing directory with an intact state file is never mistaken for one awaiting a full copy.
            for d in ${BASELINE_FAILED_DIRS[@]+"${BASELINE_FAILED_DIRS[@]}"}; do
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> [WARNING] SKIPPING DistCp for directory: $d <<<"
                echo "=========================================================================================================================================="
                echo ">>> Reason: Baseline snapshot creation failed, or was refused by the brand-new gate"
                echo ">>> Action: Fix the issues reported above and re-run the script"
                echo "=========================================================================================================================================="
                echo ""
                log "[WARN] Skipping DistCp for $d - no baseline was created this run"
                DISTCP_ALL_OK=false
            done

            for d in ${BASELINED_DIRS[@]+"${BASELINED_DIRS[@]}"}; do
                src_uri="hdfs://$SRC_URI_NS${d}"
                dst_uri="hdfs://$DST_URI_NS${d}"
                # Prefix with the same "-D" HA properties run_as_distcp injects automatically below, so the
                # PRINTED command (log_cmd/echo, for operator visibility) matches what actually executes --
                # see render_nameservice_ha_args_for_display's doc comment.
                distcp_cmd="hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS $src_uri $dst_uri"

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
                # shellcheck disable=SC2086 # Intentional word splitting for distcp option flags
                if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_STDERR_FILE" >&2); then
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
                echo "   - If this was an OutOfMemory error, the DistCp client heap is likely too small."
                echo "     Raise it before re-running, e.g.:  export HADOOP_CLIENT_OPTS=\"-Xmx4g\""
                echo "     (Mapper-side memory can be tuned via -Dmapreduce.map.memory.mb in COPY_OPTS.)"
                echo "3. Re-run this script (recommended), OR run the failed full DistCp commands manually."
                echo ""
                echo "   IMPORTANT: The destination baseline snapshot ${SNAP_PREFIX}_0 was NOT refreshed"
                echo "   (the script exits before re-baselining on failure, so a partial copy can't poison it)."
                echo "   On the NEXT run, Stage 4 automatically reconciles the destination to the source"
                echo "   ${SNAP_PREFIX}_0 snapshot (one-time full -update) and refreshes the baseline before"
                echo "   the first incremental diff -- so simply fixing the issue and re-running is safe,"
                echo "   whether you let the script copy or you copy manually first."
                echo ""
                log "[ERROR] Baseline full DistCp failed for one or more directories. Script terminating."
                log "[INFO] On re-run, Stage 4 self-heals the baseline (reconcile + re-baseline) before incremental sync."
                exit 1
            fi
            
            # Re-enable snapshots on destination (they may have been disabled during DistCp).
            # Scoped to the directories this run actually baselined + copied -- every other configured directory
            # was already made snapshottable in Stage 2 and was not touched by the copies above.
            log_substage "Re-enabling snapshots on destination directories"
            for d in ${BASELINED_DIRS[@]+"${BASELINED_DIRS[@]}"}; do
                log "[DEBUG] Re-enabling snapshot on destination dir: $d"
                allow_snap_output=$(run_as_hdfs hdfs dfsadmin -fs "hdfs://$DST_URI_NS" -allowSnapshot "$d" 2>&1 | grep -v "^SLF4J:" || true)
                allow_snap_rc=$?
                if [[ $allow_snap_rc -eq 0 ]] || echo "$allow_snap_output" | grep -qi "already.*snapshottable"; then
                    [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
                    log "[INFO] Snapshot re-enabled on destination directory $d"
                else
                    [[ -n "$allow_snap_output" ]] && echo "$allow_snap_output"
                    log "[WARN] Failed to re-enable snapshot on destination directory $d (may already be enabled)"
                fi
            done
            
            # After full DistCp, the destination has been modified and no longer matches dr_snap_0. Create a
            # new baseline snapshot on destination to capture the current state after DistCp. This ensures
            # that on the next run, incremental sync will work correctly.
            # Scoped to BASELINED_DIRS: this block DELETES and recreates the destination's ${SNAP_PREFIX}_0.
            # Run against an already-replicating directory (which it was, when this looped over every configured
            # directory) it would destroy that directory's real baseline snapshot and replace it with one
            # capturing unrelated current content.
            log_substage "Creating post-DistCp baseline snapshot on destination"
            POST_DISTCP_BASELINE_FAILED_DIRS=()
            for d in ${BASELINED_DIRS[@]+"${BASELINED_DIRS[@]}"}; do
                key=$(sanitize "$d")
                base="${SNAP_PREFIX}_0"
                log "[DEBUG] Creating post-DistCp baseline snapshot for directory: $d"

                # Delete the old dr_snap_0 on destination (from before DistCp)
                if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "$d/.snapshot" 2>/dev/null | grep -q "/${base}\$"; then
                    log "[DEBUG] Deleting old baseline snapshot $base on destination (pre-DistCp state)"
                    if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -deleteSnapshot "$d" "$base" 2>/dev/null; then
                        log "[INFO] Deleted old baseline snapshot $base on destination"
                    else
                        log "[WARN] Failed to delete old baseline snapshot $base on destination (may proceed anyway)"
                    fi
                fi

                # Create new baseline snapshot on destination (post-DistCp state)
                log "[INIT] Creating new baseline snapshot '$base' on destination (post-DistCp state): $d"
                if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$base"; then
                    log "[INFO] New baseline snapshot '$base' created on destination for $d (post-DistCp state)"
                else
                    echo "[ERROR] FAILED to create post-DistCp baseline snapshot '$base' on DESTINATION: $d"
                    log "[ERROR] Failed to create post-DistCp baseline snapshot on destination for $d"
                    log "[ERROR] This may cause issues on the next incremental sync run."
                    POST_DISTCP_BASELINE_FAILED_DIRS+=("$d")
                fi
            done

            # A failed post-DistCp baseline snapshot must NOT be reported as full success: a cron/monitoring
            # wrapper checking only the exit code would never see the [ERROR] lines logged above. This does
            # not put data at risk -- Stage 4's baseline self-heal (reconcile_and_rebaseline_dest) detects the
            # stale/missing ${SNAP_PREFIX}_0 on the next run and refreshes it before the first incremental
            # diff -- but the run must still surface as failed so it gets noticed and re-run deliberately.
            if [[ ${#POST_DISTCP_BASELINE_FAILED_DIRS[@]} -gt 0 ]]; then
                echo ""
                echo "=========================================================================================================================================="
                echo ">>> [WARNING] BASELINE DISTCP COMPLETED WITH POST-COPY SNAPSHOT ERRORS <<<"
                echo "=========================================================================================================================================="
                SCRIPT_END_TS=$(date +%s)
                echo "Total Runtime       : $((SCRIPT_END_TS - SCRIPT_START_TS)) seconds"
                echo ""
                echo "Full DistCp completed for all directories, but the post-DistCp baseline snapshot"
                echo "could not be (re)created on the destination for:"
                for d in "${POST_DISTCP_BASELINE_FAILED_DIRS[@]}"; do
                    echo "    - $d"
                done
                echo ""
                echo "This does NOT put data at risk: Stage 4's baseline self-heal detects the stale/missing"
                echo "${SNAP_PREFIX}_0 snapshot on the next run and refreshes it before the first incremental"
                echo "diff. Re-run this script to retry."
                echo ""
                echo "=========================================================================================================================================="
                echo ""
                log "[WARN] Post-DistCp baseline snapshot creation failed for: ${POST_DISTCP_BASELINE_FAILED_DIRS[*]}. Not fatal (Stage 4 self-heals on next run), but the script must report this run as failed rather than fully successful."
                log_stage_complete "3" "Baseline Snapshot Creation"
                exit 1
            fi

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

            # Directories that got no baseline this run (see BASELINED_DIRS in Stage 3). Reported, but no DistCp
            # command is printed for them.
            for d in ${BASELINE_FAILED_DIRS[@]+"${BASELINE_FAILED_DIRS[@]}"}; do
                echo "📁 Directory: $d"
                echo ""
                echo "   [WARNING] SKIPPED: baseline snapshot creation failed, or was refused by the brand-new gate"
                echo "   Please fix the issues reported above and re-run the script."
                echo ""
                echo "------------------------------------------------------------------------------------------------------------------------------------------"
                echo ""
            done

            # Only directories actually baselined by THIS run need a full DistCp. Printing a full-copy command
            # for an already-syncing directory (which iterating all of SOURCE_DIRS did) invites an operator to
            # overwrite a healthy destination by hand.
            for d in ${BASELINED_DIRS[@]+"${BASELINED_DIRS[@]}"}; do
                has_valid_dirs=true
                src_uri="hdfs://$SRC_URI_NS${d}"
                dst_uri="hdfs://$DST_URI_NS${d}"
                # This command is copy-pasted and run BY HAND by the operator, entirely outside
                # run_as_distcp -- prefix with the same "-D" HA properties run_as_distcp would inject
                # automatically, so a same-nameservice alias like "$DST_URI_NS" actually resolves when run
                # standalone in the operator's own shell. See render_nameservice_ha_args_for_display's doc
                # comment.
                nameservice_ha_display_args="$(render_nameservice_ha_args_for_display)"
                distcp_cmd="hadoop distcp ${nameservice_ha_display_args}$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS $src_uri $dst_uri"
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
                    echo "   hdfs ${nameservice_ha_display_args}dfsadmin -fs hdfs://$DST_URI_NS -allowSnapshot $d"
                    echo "   hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS -ls $d/.snapshot   # verify"
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
        dir_start_ts=$(date +%s)
        echo ""
        log_cmd "Processing Directory: $d"
        log "[DEBUG] Starting incremental sync for directory: $d"
        key=$(sanitize "$d")
        # Computed once per directory for prefixing every "hdfs"/"hadoop" command PRINTED below as manual
        # operator recovery guidance (direction reversal, split-brain, no-common-snapshot, reverse-diff-
        # bootstrap divergent writes, post-rollback-retry failure, etc.) -- these are copy-paste instructions
        # run by hand in the operator's own shell, entirely outside run_as_hdfs/run_as_distcp's automatic "-D"
        # injection. Without this prefix, any command referencing "hdfs://$SRC_URI_NS" in the same-nameservice-
        # collision case (where SRC_URI_NS is a synthetic alias -- see main()'s doc comment) fails immediately
        # if copy-pasted, since no hdfs-site.xml anywhere defines the alias. Same rationale as Stage 3's
        # existing use of this same helper -- see render_nameservice_ha_args_for_display's doc comment. Empty
        # string (safe to prefix unconditionally) when AUTO_DERIVE_HA_CLIENT_CONFIG is disabled or nothing has
        # been derived (the normal, non-colliding case).
        nameservice_ha_display_args="$(render_nameservice_ha_args_for_display)"
        resolve_state_file_and_check_new "$key"
        state="$RESOLVED_STATE_FILE"

        # --- Direction / bootstrap decision ------------------------------------- (a) No state file at all
        # (local OR HDFS-mirrored) -> Stage 3 did not establish state for this
        #     directory. Two ways to get here, both already reported in Stage 3:
        #       - its baseline snapshot creation failed, or
        #       - confirm_brand_new_against_live_snapshots REFUSED to baseline it
        #         (unshared snapshots on both sides, destination-only history, or
        #         a failed live listing) -- see the [BRAND-NEW-GATE] output above.
        #     Either way the only safe action is to fail the directory: with no
        #     established last-common snapshot there is nothing to diff from, and
        #     guessing one risks copying over authoritative data. Directories that
        #     Stage 3 rehydrated from live snapshots DO have state and pass this
        #     check normally.
        if [[ "$IS_BRAND_NEW_DIR" == "true" ]]; then
            log "[ERROR] [Stage 4] Directory $d has no state file (local or HDFS-mirrored) at Stage 4 entry -- Stage 3 neither created nor rehydrated state for it (baseline failure, or the [BRAND-NEW-GATE] refused to baseline it; see the Stage 3 output above for the specific reason and the remedy). Failing this directory rather than guessing a diff base."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            ALL_OK=false
            continue
        fi

        # --- Direction determination: live-snapshot-derived, never cached ------ Optimistic fast path first
        # (avoids a full double-listing on the common unchanged-direction case), falling through to the full
        # live listing-and-intersection algorithm whenever the fast path cannot confirm safety. See
        # derive_direction_state / verify_cached_snap_fast_path.
        cached_snap=""
        [[ -f "$state" ]] && cached_snap=$(read_state_snapshot "$state")
        verify_cached_snap_fast_path "$d" "$cached_snap"
        if [[ "$FAST_PATH_CONFIRMED" == "true" ]]; then
            log "[DEBUG] [DIRECTION-DERIVE] Fast-path confirmed for $d: cached last-common snapshot '$cached_snap' verified present on both clusters with no further advancement on DEST_CLUSTER. Skipping full snapshot listing this run."
            DIRECTION_REVERSED="false"
            SPLIT_BRAIN_DETECTED="false"
            DIRECTION_STATE_OK="true"
        else
            log "[DEBUG] [DIRECTION-DERIVE] Fast-path not confirmed for $d (cache absent, stale, or DEST_CLUSTER has advanced). Falling through to full live snapshot listing on both clusters."
            derive_direction_state "$d"
        fi

        if [[ "$DIRECTION_STATE_OK" != "true" ]]; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] CANNOT SAFELY DETERMINE REPLICATION DIRECTION for $d <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "  A live snapshot listing on SOURCE_CLUSTER and/or DEST_CLUSTER failed for this"
            echo "  directory (network issue, permission denied, or another unexpected error --"
            echo "  see [ERROR] [DIRECTION-DERIVE] lines above for details)."
            echo ""
            echo "  This script will NOT fall back to any cached or assumed direction for a"
            echo "  safety-critical decision. Proceeding without a live-confirmed direction could"
            echo "  misclassify a reversed-direction directory as a normal forward continuation,"
            echo "  which can reach a destructive rollback path (ROLLBACK_ON_FAILURE=yes) against"
            echo "  real data. Failing this directory closed instead."
            echo ""
            echo "  --- To recover ---"
            echo "    1. Resolve the underlying issue (connectivity, permissions) reported above."
            echo "    2. Verify manually:"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "    3. Re-run this script; the live check will be retried."
            echo ""
            echo "=========================================================================================================================================="
            log "[ERROR] [Stage 4] Cannot safely determine replication direction for $d (live snapshot listing failed on one or both clusters). Failing closed rather than trusting any cached value. See guidance above."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (direction determination failed)"
            ALL_OK=false
            continue
        fi

        last_snap="$LAST_COMMON_SNAP_NAME"
        if [[ -z "$last_snap" ]]; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] NO COMMON SNAPSHOT FOUND for $d <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "  Neither SOURCE_CLUSTER ($SOURCE_CLUSTER) nor DEST_CLUSTER ($DEST_CLUSTER) has a"
            echo "  '${SNAP_PREFIX}_*' snapshot that also exists on the other side. This directory"
            echo "  reached Stage 4 with a state file present, but its baseline snapshot appears to"
            echo "  have been pruned (e.g. SNAP_RETAIN too low combined with missed runs) or removed"
            echo "  out-of-band on one cluster."
            echo ""
            echo "  This cannot be safely auto-resolved. Manual reconciliation required:"
            echo "    1. Inspect snapshots on both clusters:"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "    2. Decide which side holds authoritative data."
            echo "    3. Clear local AND HDFS-mirrored state to force a full re-baseline:"
            echo "         rm -f $state"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo "    4. Re-run this script with FORCE_REBASELINE=yes:"
            echo "         export FORCE_REBASELINE=yes"
            echo ""
            echo "       Clearing state alone is NOT enough here. Stage 3 confirms 'brand new' against"
            echo "       live snapshot listings before it will baseline, and it will REFUSE to baseline a"
            echo "       directory whose clusters still hold unshared ${SNAP_PREFIX}_* snapshots (exactly"
            echo "       the situation above). FORCE_REBASELINE=yes is the explicit override, and only"
            echo "       affects directories whose state you cleared."
            echo "       Alternatively, delete every ${SNAP_PREFIX}_* snapshot for $d on BOTH clusters"
            echo "       instead, which makes the directory genuinely brand new and needs no override."
            echo ""
            echo "       WARNING: either way this performs a FULL copy that overwrites $DEST_CLUSTER."
            echo ""
            echo "=========================================================================================================================================="
            log "[ERROR] [Stage 4] No common snapshot index found for $d despite an existing state file. Likely retention pruning removed all shared history. Manual reconciliation required."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (no common snapshot)"
            ALL_OK=false
            continue
        fi

        if [[ "$SPLIT_BRAIN_DETECTED" == "true" ]]; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] SPLIT-BRAIN DETECTED for $d — BOTH CLUSTERS HAVE DIVERGED INDEPENDENTLY <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "  Snapshot state on BOTH clusters shows independent advancement beyond the last"
            echo "  point they agree on:"
            echo ""
            echo "    Last common snapshot                 : $last_snap"
            echo "    SOURCE_CLUSTER ($SOURCE_CLUSTER) has snapshots beyond it that DEST_CLUSTER lacks"
            echo "    DEST_CLUSTER ($DEST_CLUSTER) has snapshots beyond it that SOURCE_CLUSTER lacks"
            echo ""
            echo "  This means BOTH clusters took independent snapshot-advancing actions (each"
            echo "  cluster acted as a source at some point) since '$last_snap' -- most likely two"
            echo "  replication pairs/directions were run concurrently, or a failover and a manual"
            echo "  operation both advanced state independently. This is detected PROACTIVELY here,"
            echo "  from live snapshot listings on both clusters, BEFORE any DistCp was attempted --"
            echo "  it is a stronger and earlier signal than the reactive 'target modified since"
            echo "  snapshot' DistCp error message this script also handles elsewhere."
            echo ""
            echo "  This script will NOT automatically discard or choose between the two divergent"
            echo "  histories. Automatic resolution is never attempted for this condition."
            echo ""
            echo "  --- Option 1: Manually inspect both clusters' snapshot history ---"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "    Identify which snapshots exist only on one side, and inspect the underlying"
            echo "    data changes with snapshotDiff, e.g.:"
            echo "      hdfs ${nameservice_ha_display_args}snapshotDiff -fs hdfs://$SRC_URI_NS $d $last_snap ."
            echo "      hdfs ${nameservice_ha_display_args}snapshotDiff -fs hdfs://$DST_URI_NS   $d $last_snap ."
            echo ""
            echo "  --- Option 2: Decide authoritative side and force a full re-baseline ---"
            echo "    Confirm which cluster's post-'$last_snap' history is authoritative, then"
            echo "    clear ALL state (local AND the HDFS-mirrored copies on both clusters) to force"
            echo "    Stage 3 to re-baseline from scratch in the CURRENT direction"
            echo "    ($SOURCE_CLUSTER -> $DEST_CLUSTER):"
            echo ""
            echo "      rm -f $state"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo ""
            echo "    ALSO REQUIRED: delete every existing ${SNAP_PREFIX}_* snapshot for $d on BOTH"
            echo "    clusters BEFORE re-running -- direction/continuation is derived live from actual"
            echo "    snapshot indices (see [DIRECTION-DERIVE] in the logs); leaving old numbered"
            echo "    snapshots in place risks a LATER run finding a coincidental \"last common index\""
            echo "    from before this recovery instead of the fresh ${SNAP_PREFIX}_0 baseline, and"
            echo "    (if ROLLBACK_ON_FAILURE=yes) rolling back to a pre-recovery state:"
            echo ""
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "      # for each ${SNAP_PREFIX}_<N> snapshot listed on EITHER cluster:"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo ""
            echo "    WARNING: this performs a FULL distcp that OVERWRITES $DEST_CLUSTER with"
            echo "    $SOURCE_CLUSTER's data, discarding whatever independent history existed only"
            echo "    on $DEST_CLUSTER. Confirm authoritative data BEFORE doing this."
            echo ""
            echo "  --- Option 3: Manually reconcile the divergent snapshots, then clear state ---"
            echo "    If the divergent changes on each side should both be preserved (merged),"
            echo "    reconcile the data out-of-band (e.g. manual copy of the missing pieces),"
            echo "    THEN clear state as in Option 2 to re-baseline from the now-reconciled data."
            echo ""
            echo "=========================================================================================================================================="
            log "[ERROR] [Stage 4] Split-brain detected for $d: both SOURCE_CLUSTER and DEST_CLUSTER have snapshot indices beyond the last common index ($last_snap) that the other lacks. Detected proactively from live snapshot listings, before any DistCp was attempted. No automatic resolution attempted (by design). See operator guidance above."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (split-brain detected)"
            ALL_OK=false
            continue
        fi

        if [[ "$DIRECTION_REVERSED" == "true" ]] && [[ "${REVERSE_DIFF_BOOTSTRAP,,}" == "yes" ]]; then
            # (c) direction reversed + REVERSE_DIFF_BOOTSTRAP=yes -> new bootstrap path
            log "[INFO] Direction reversal detected for $d: snapshot state shows DEST_CLUSTER ($DEST_CLUSTER) has advanced beyond the last common snapshot ($last_snap) that SOURCE_CLUSTER ($SOURCE_CLUSTER) lacks -- DEST_CLUSTER was acting as source more recently. Attempting reverse-diff bootstrap."
            if reconcile_reverse_diff_bootstrap "$d" "$last_snap"; then
                # Bootstrap function itself advances state + snapshots + logs metrics on success; nothing
                # further to do for this directory this iteration.
                dir_end_ts=$(date +%s)
                log "[METRIC] [STAGE 4] Directory '$d' completed in $((dir_end_ts - dir_start_ts)) seconds (reverse-diff bootstrap)"
                continue
            else
                # Bootstrap function already logged the failure, incremented METRICS_FAILED_DIRECTORIES via
                # caller below, and printed operator guidance.
                METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                dir_end_ts=$(date +%s)
                log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (reverse-diff bootstrap)"
                ALL_OK=false
                continue
            fi
        fi

        if [[ "$DIRECTION_REVERSED" == "true" ]]; then
            # REVERSE_DIFF_BOOTSTRAP is "no" (or unset). Do NOT fall through to the normal incremental path
            # below: last_snap/next_snap on a reversed-direction cluster pair does NOT mean "unchanged
            # snapshot state" the way it does for a normal forward run -- the current SOURCE_CLUSTER is the
            # OLD destination, which may hold nothing but the stale replicated snapshot, while the current
            # DEST_CLUSTER is the OLD source / DR-promoted cluster, which may now hold real production writes
            # made since the last replicated snapshot.
            #
            # If this directory were allowed to proceed into the normal Stage 4 incremental logic, an "idx>0"
            # DistCp "target has been modified since snapshot" failure (expected and likely here) combined
            # with ROLLBACK_ON_FAILURE=yes would trigger rollback_once_for_failure(), which runs a destructive
            # `distcp -rdiff` restore against DEST_CLUSTER -- i.e. against what is now the REAL PRODUCTION
            # dataset, discarding any writes made there since the last replicated snapshot. That is never
            # acceptable, so this directory is failed cleanly instead.
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] DIRECTION REVERSAL DETECTED for $d — REFUSING TO RUN NORMAL INCREMENTAL SYNC <<<"
            echo "=========================================================================================================================================="
            echo ""
            echo "  Snapshot state on both clusters indicates a reversal:"
            echo ""
            echo "    Last common snapshot                     : $last_snap"
            echo "    DEST_CLUSTER  ($DEST_CLUSTER) has snapshots beyond it"
            echo "    SOURCE_CLUSTER ($SOURCE_CLUSTER) has none beyond it"
            echo ""
            echo "  This means \$DEST_CLUSTER ($DEST_CLUSTER) has been acting as a SOURCE more"
            echo "  recently than \$SOURCE_CLUSTER ($SOURCE_CLUSTER) was -- i.e. \$DEST_CLUSTER"
            echo "  (arg 2) currently holds newer snapshot history than \$SOURCE_CLUSTER (arg 1)."
            echo "  This looks like a failover/failback role swap. This determination comes"
            echo "  directly from live snapshot listings on both clusters (primary evidence), not"
            echo "  from any cached label."
            echo ""
            echo "  Proceeding with the normal incremental sync path here is UNSAFE: \$DEST_CLUSTER"
            echo "  may now hold real production writes made since the last replicated snapshot,"
            echo "  and (if ROLLBACK_ON_FAILURE=yes) an expected 'target modified since snapshot'"
            echo "  error would trigger a DESTRUCTIVE rollback against that data. This script will"
            echo "  NOT do that automatically."
            echo ""
            echo "  --- Option 1 (recommended): enable the reverse-diff bootstrap ---"
            echo "    Re-run with the REVERSE_DIFF_BOOTSTRAP=yes environment variable set to"
            echo "    attempt a one-time incremental reverse-diff bootstrap for this directory"
            echo "    instead."
            echo ""
            echo "  --- Option 2: force a full re-baseline (explicit, discards diff optimization) ---"
            echo "    Confirm which side holds authoritative data, then clear ALL state (local AND"
            echo "    the HDFS-mirrored copies on both clusters) to force Stage 3 to re-baseline"
            echo "    from scratch in the CURRENT direction:"
            echo ""
            echo "      rm -f $state"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -rm -f ${HDFS_STATE_DIR}/dr-last-snap-${key}.txt"
            echo ""
            echo "    NOTE: clearing state is necessary but NOT sufficient. It is not what determines"
            echo "    direction safety (that is derived live from snapshot listings every run), and"
            echo "    Stage 3 now also confirms 'brand new' against those live listings before it will"
            echo "    baseline -- so with state cleared but snapshots still present it will REFUSE to"
            echo "    re-baseline. Complete the snapshot deletion below, or re-run with"
            echo "    FORCE_REBASELINE=yes to override that confirmation explicitly."
            echo ""
            echo "    ALSO REQUIRED: delete every existing ${SNAP_PREFIX}_* snapshot for $d on BOTH"
            echo "    clusters BEFORE re-running. Since direction is derived live from actual"
            echo "    snapshot indices, leaving old numbered snapshots in place risks a LATER run"
            echo "    finding a coincidental \"last common index\" from before this re-baseline instead"
            echo "    of the fresh ${SNAP_PREFIX}_0 baseline, and (if ROLLBACK_ON_FAILURE=yes) rolling"
            echo "    back to a pre-re-baseline state:"
            echo ""
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls $d/.snapshot"
            echo "      # for each ${SNAP_PREFIX}_<N> snapshot listed on EITHER cluster:"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -deleteSnapshot $d ${SNAP_PREFIX}_<N>"
            echo ""
            echo "    WARNING: this performs a FULL distcp that overwrites $DEST_CLUSTER with"
            echo "    $SOURCE_CLUSTER's data."
            echo ""
            echo "=========================================================================================================================================="
            log "[ERROR] Direction reversal detected for $d (snapshot state: DEST_CLUSTER has advanced beyond last common snapshot '$last_snap', SOURCE_CLUSTER has not) but REVERSE_DIFF_BOOTSTRAP=no. Refusing to run the normal incremental path (would risk a destructive rollback against production data on \$DEST_CLUSTER). See operator guidance above."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (direction reversal, bootstrap disabled)"
            ALL_OK=false
            continue
        fi

        idx=${last_snap##*_}
        next_snap="${SNAP_PREFIX}_$((idx + 1))"

        log "[SYNC] $d: $last_snap -> $next_snap"

        # 4a) Ensure last_snap exists on destination (create if missing)
        log "[DEBUG] Ensuring last snapshot $last_snap exists on destination directory $d"
        out_dr_last=$(run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -ls "$d/.snapshot" 2>/dev/null | grep "/$last_snap\$" || true)
        if [[ -z "$out_dr_last" ]]; then
            log "[INFO] Last snapshot $last_snap missing on destination, creating..."
            if run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$last_snap"; then
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
        out_src=$(run_as_hdfs hdfs dfs -fs "hdfs://$SRC_URI_NS" -createSnapshot "$d" "$next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
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

        # 4c) Baseline transition self-heal (deterministic; runs ONCE per directory).
        #      On the first incremental (last_snap == ${SNAP_PREFIX}_0), the destination may be
        #      empty (manual mode before copy), partial (interrupted/OOM'd full copy), or filled
        #      out-of-band. Instead of guessing with `snapshotDiff ... "."` (unreliable, gave
        #      false negatives), we reconcile the destination to the SOURCE baseline snapshot with
        #      a one-time full `distcp -update` (backfills any gaps), then refresh the destination
        #      baseline snapshot so DistCp's "target unchanged since fromSnapshot" precondition
        #      holds. This works for BOTH AUTO_FULL_DISTCP=yes and =no, and prevents a silently
        #      empty DR. Subsequent snapshots (idx > 0) skip this and rely on ROLLBACK_ON_FAILURE.
        baseline_snap="${SNAP_PREFIX}_0"
        if [[ "$last_snap" == "$baseline_snap" ]]; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> 🔧 BASELINE BOOTSTRAP SELF-HEAL for $d <<<"
            echo "=========================================================================================================================================="
            echo ">>> Reconciling destination to source snapshot $baseline_snap before the first incremental diff."
            echo ">>> (One-time per directory; ensures the destination baseline is complete and consistent.)"
            echo "=========================================================================================================================================="
            echo ""
            if ! reconcile_and_rebaseline_dest "$d" "$baseline_snap"; then
                echo "============================================"
                echo ">>> [ERROR] [STAGE 4] Baseline reconcile/re-baseline FAILED for: $d <<<"
                echo "============================================"
                log "[ERROR] [Stage 4] Baseline bootstrap self-heal failed for $d. Skipping incremental this run."
                log "[INFO] Fix the reconcile DistCp issue (network/permissions/heap) and re-run; the bootstrap will retry."
                METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                dir_end_ts=$(date +%s)
                log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                ALL_OK=false
                continue
            fi
        fi

        # 4d) Run distcp diff from last_snap to next_snap (capture stderr for analysis)
        #      NOTE: Uses tee to write distcp stderr to temp file AND to stderr. Since
        #            stderr is redirected to stdout via exec 2>&1, output appears in
        #            real-time through the global tee process without buffering delays.
        src_uri="hdfs://$SRC_URI_NS${d}"
        dst_uri="hdfs://$DST_URI_NS${d}"
        log_cmd "Syncing directory: $d ($last_snap -> $next_snap)"
        log "[DEBUG] Running distcp diff sync for $d"
        echo ""
        echo "=== DistCp Command ==="
        # Remove -update from COPY_OPTS and place it before -diff (required by DistCp) All other options must
        # come before -diff to avoid being treated as source paths
        COPY_OPTS_NO_UPDATE=$(strip_update_flag "$COPY_OPTS")
        echo "  hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS_NO_UPDATE -update -diff $last_snap $next_snap $src_uri $dst_uri"
        echo "======================"
        echo ""
        echo "[DEBUG MARKER] Starting DistCp execution for $d"
        DISTCP_STDERR_FILE="/tmp/distcp_err_${key}_$$.log"
        TEMP_FILES+=("$DISTCP_STDERR_FILE")
        # Use tee to write distcp stderr to temp file AND to stderr (which goes through global redirection to
        # LOG and console). Since stderr is redirected to stdout via exec 2>&1, this ensures real-time output
        # without buffering delays. shellcheck disable=SC2086 # Intentional word splitting for distcp option
        # flags
        if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS_NO_UPDATE -update -diff "$last_snap" "$next_snap" "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_STDERR_FILE" >&2); then
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
            # Detect snapshot-modified symptom. Baseline (idx 0) was already reconciled + re-baselined in 4c,
            # so it is handled separately below (no destructive rollback). Subsequent snapshots use
            # ROLLBACK_ON_FAILURE.
            if grep -q "The target has been modified since snapshot" "$DISTCP_STDERR_FILE" 2>/dev/null ||
                grep -q "target has changed since snapshot" "$DISTCP_STDERR_FILE" 2>/dev/null; then
                # Baseline case (last_snap == ${SNAP_PREFIX}_0): we already reconciled + refreshed the
                # destination baseline in 4c. A "target modified" error here means the destination changed
                # AGAIN between the re-baseline and this diff (e.g. concurrent writes). The destructive -rdiff
                # rollback (revert to ${SNAP_PREFIX}_0) is NEVER appropriate for the baseline -- it would
                # discard the data we just copied. Fail cleanly with guidance instead.
                if [[ "$last_snap" == "$baseline_snap" ]]; then
                    echo "============================================"
                    echo ">>> [ERROR] [STAGE 4] Baseline diff still failed after self-heal for: $d <<<"
                    echo "============================================"
                    log "[ERROR] [Stage 4] Destination was modified again after baseline re-baseline for $d (concurrent writes?)."
                    log "[ERROR] Destructive rollback is intentionally NOT attempted for the baseline snapshot."
                    log "[INFO] Ensure no writers are touching the destination $d during replication, then re-run."
                    METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
                    dir_end_ts=$(date +%s)
                    log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds"
                    ALL_OK=false
                    continue
                fi

                # Subsequent snapshots only (idx > 0): honor ROLLBACK_ON_FAILURE
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
                        # NOTE: intentionally NOT added to TEMP_FILES so it persists after script exit for
                        # forensic inspection Use tee to write retry distcp stderr to temp file AND to stderr
                        # Reuse COPY_OPTS_NO_UPDATE from earlier in the function
                        log_cmd "DistCp Retry Command (post-rollback)"
                        echo "  hadoop distcp $(render_nameservice_ha_args_for_display)$DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS_NO_UPDATE -update -diff $last_snap $next_snap $src_uri $dst_uri"
                        echo "======================"
                        echo ""
                        # shellcheck disable=SC2086 # Intentional word splitting for distcp option flags
                        if run_as_distcp hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS_NO_UPDATE -update -diff "$last_snap" "$next_snap" "$src_uri" "$dst_uri" 2> >(tee "$DISTCP_RETRY_STDERR" >&2); then
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
                            echo "    hadoop distcp $DISTCP_FULL_OPTS $DISTCP_EXCLUDE_OPTS $COPY_OPTS $src_uri $dst_uri"
                            echo ""
                            echo "    After it completes:"
                            echo "      - Delete the 'next' snapshot from source (if created this run):"
                            echo "          hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -deleteSnapshot $d $next_snap"
                            echo "      - Re-run this script to resume incremental sync."
                            echo ""
                            echo "  --- Option 2: Inspect .snapshot dirs on both clusters ---"
                            echo ""
                            echo "    Source snapshots:"
                            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls $d/.snapshot"
                            echo ""
                            echo "    Destination snapshots:"
                            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS -ls $d/.snapshot"
                            echo ""
                            echo "  --- Option 3: Recreate destination '$last_snap' snapshot and retrigger (RECOMMENDED) ---"
                            echo ""
                            echo "    The destination snapshot '$last_snap' may have stale metadata after rollback."
                            echo "    Recreating it refreshes the baseline so incremental DistCp can proceed."
                            echo ""
                            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS -deleteSnapshot $d $last_snap"
                            echo "      hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS -createSnapshot $d $last_snap"
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
        #     CRITICAL: state (4f) must NEVER advance past a snapshot that does
        #     not actually exist on the destination -- doing so would silently
        #     tell the next run "last_snap is real" when DEST's live data was
        #     never captured at that point, permanently masking a missed
        #     increment (the next run's baseline self-heal would just create
        #     the snapshot fresh from whatever DEST's live data has drifted to
        #     by then, with no error trail). dest_snap_ok tracks the real
        #     outcome (mirrors the same true/false gating Stage 3 already uses
        #     for baseline snapshot creation) so 4f only runs on success.
        echo ""
        log "[DEBUG] Creating next snapshot $next_snap on destination directory $d"
        out_dr_next=$(run_as_hdfs hdfs dfs -fs "hdfs://$DST_URI_NS" -createSnapshot "$d" "$next_snap" 2>&1 | grep -v "^SLF4J:" || true) || true
        log "[DEBUG] Destination snapshot creation output: $out_dr_next"
        dest_snap_ok=false
        if echo "$out_dr_next" | grep -q "already a snapshot with the same name"; then
            log "[WARN] Destination snapshot $next_snap already exists"
            dest_snap_ok=true
        elif echo "$out_dr_next" | grep -q "Created snapshot"; then
            log "[INFO] Destination snapshot $next_snap created"
            dest_snap_ok=true
        else
            log "[ERROR] Destination snapshot creation FAILED for $next_snap: $out_dr_next"
        fi

        if [[ "$dest_snap_ok" != "true" ]]; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] [STAGE 4] Destination snapshot creation FAILED for: $d <<<"
            echo "=========================================================================================================================================="
            log "[ERROR] [Stage 4] DistCp succeeded for $d but the destination snapshot '$next_snap' could not be created. Refusing to advance state -- last_snap remains '$last_snap' for this directory."
            log "[ERROR] The DistCp-copied data on the destination is real, but not yet captured in a snapshot. Re-run this script; the next run's baseline/diff logic will retry from '$last_snap'."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (destination snapshot creation failed)"
            ALL_OK=false
            continue
        fi

        # 4e-bis) Verify source's and destination's $next_snap actually agree on content before trusting
        # either as the new common reference point. This is the FIRST moment parity is both meaningful and
        # checkable without a false positive: destination's snapshot was just cut immediately after DistCp
        # applied source's diff onto it, so the two should now be identical. If they are not, either this
        # run's DistCp under/over-copied, or $last_snap (the diff base) was itself already diverged (e.g. a
        # Stage 3 baseline that silently drifted before any incremental ever ran) -- either way, advancing
        # state past a mismatched $next_snap would permanently hide the gap, exactly as happened when 5
        # files added on source were never reflected on destination but the run still reported SUCCESS.
        if ! verify_snapshot_content_parity "$d" "$next_snap"; then
            echo ""
            echo "=========================================================================================================================================="
            echo ">>> [ERROR] [STAGE 4] CONTENT PARITY MISMATCH for: $d <<<"
            echo "=========================================================================================================================================="
            echo "  Snapshot '$next_snap' exists on both clusters but its content differs (see"
            echo "  [CONTENT-PARITY] above for the DIR_COUNT/FILE_COUNT/CONTENT_SIZE on each side)."
            echo ""
            echo "  Refusing to advance state past this snapshot -- last_snap remains '$last_snap'."
            echo ""
            echo "  --- To recover ---"
            echo "    1. Compare source and destination directly to see what's missing/extra:"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$SRC_URI_NS -ls -R $d"
            echo "         hdfs ${nameservice_ha_display_args}dfs -fs hdfs://$DST_URI_NS   -ls -R $d"
            echo "    2. If destination is missing real data, run a manual full DistCp (not -diff) to"
            echo "       reconcile, then re-run this script."
            echo "=========================================================================================================================================="
            log "[ERROR] [Stage 4] DistCp and destination snapshot creation both reported success for $d, but '$next_snap' fails content-parity verification between SOURCE_CLUSTER and DEST_CLUSTER. Refusing to advance state -- last_snap remains '$last_snap' for this directory. Manual reconciliation required (see guidance above)."
            METRICS_FAILED_DIRECTORIES=$((METRICS_FAILED_DIRECTORIES + 1))
            dir_end_ts=$(date +%s)
            log "[METRIC] [STAGE 4] Directory '$d' failed after $((dir_end_ts - dir_start_ts)) seconds (content-parity verification failed)"
            ALL_OK=false
            continue
        fi

        # 4f) Advance state (persist the last successful snapshot name)
        if write_state_file "$state" "$(build_state_content "$next_snap")" "$key"; then
            log "[SYNC] State advanced to $next_snap for $d"
        else
            log "[ERROR] Failed to write state file $state"
        fi
        dir_end_ts=$(date +%s)
        log "[METRIC] [STAGE 4] Directory '$d' completed in $((dir_end_ts - dir_start_ts)) seconds"
        echo ""

        # 4g) Cleanup old snapshots on source (retain SNAP_RETAIN most recent, matching current prefix only)
        cleanup_old_snapshots "$SRC_URI_NS" "$d" "source" "$SNAP_RETAIN" "$SNAP_PREFIX"

        # 4h) Cleanup old snapshots on destination (retain SNAP_RETAIN most recent, matching current prefix only)
        cleanup_old_snapshots "$DST_URI_NS" "$d" "destination" "$SNAP_RETAIN" "$SNAP_PREFIX"
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
    log_stage_complete "4" "Incremental Synchronization"

    # -----------------------------------------------------------------------------
    # Final Summary and Completion
    # -----------------------------------------------------------------------------
    log_stage "5" "Completion"
    
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
    if [[ "$METRICS_HDFS_MIRROR_FAILURES" -gt 0 ]]; then
        echo "────────────────────────────────────────────────────────────────────────────"
        echo "  [WARN] HDFS State Mirror : $METRICS_HDFS_MIRROR_FAILURES failure(s) this run"
        echo "                            Cross-node failover state mirroring (HDFS_STATE_DIR=$HDFS_STATE_DIR)"
        echo "                            is degraded. Local state/replication itself is unaffected,"
        echo "                            but a fresh/failover node may misclassify an already-"
        echo "                            replicating directory as brand-new if this persists."
        echo "                            Search this log for '[HDFS-STATE-MIRROR]' [WARN] lines."
    fi
    echo "────────────────────────────────────────────────────────────────────────────"
    echo ""

    log_stage_complete "5" "Completion"
    if [[ "$OVERALL_STATUS" == "FAILED" || "$OVERALL_STATUS" == "PARTIAL" ]]; then
        exit 1
    fi
}

main "$@"

###############################################################################
#
#   ARTIFACTS & DESTRUCTIVE OPERATIONS REFERENCE
#
###############################################################################
#
# ── ARTIFACTS: LOCAL DISK (node running this script) ────────────────────────
#
#   [1] $LOG  (default: /var/log/hadoop-dr-replicate.log)
#         Full run log. Previous log is backed up (never overwritten in
#         place) as ${LOG}.<timestamp>, or ${LOG}.prev as a fallback.
#
#   [2] ${SNAP_LOCK_DIR}/<sanitized_dir>.lock
#         (/var/tmp/dr-snapshot-setup-locks/*)
#         Informational marker of whether Stage 2 allowSnapshot last succeeded on both
#         clusters for a directory. Empty file. Does NOT gate re-running allowSnapshot —
#         Stage 2 re-verifies every run regardless of this marker's presence.
#
#   [3] /var/tmp/dr-last-snap-<sanitized_dir>.txt   *** STATE FILE ***
#         (legacy fallback path: same name + "-<SNAP_PREFIX>" suffix)
#         1 line = last successfully-synced snapshot name. Authoritative
#         resume point for the NEXT run of this directory.
#
#   [4] ${ROLLBACK_MARKER_DIR}/<dir>__from_<snap>__to_<snap>.marker
#         (/var/tmp/dr-rollback-markers/*)
#         Written after a rollback attempt for one (dir, from_snap, to_snap)
#         failure; blocks auto-retrying that exact same failure again.
#
#   [5] /var/log/dr_rollback_diff_<dir>_from_<snap>_to_<snap>_<epoch>.txt
#         snapshotDiff output captured for audit, written every rollback.
#
#   [6] /tmp/distcp_retry_err_<sanitized_dir>_<pid>.log
#         Retry-attempt DistCp stderr after a rollback. NOT auto-cleaned —
#         intentionally kept on disk for forensic inspection.
#
#   [7] /tmp/*_$$.log , /tmp/*_$$.tmp   (scratch files)
#         mkdir/put/probe stderr captures, mirror temp files, direction-derive
#         listing stderr, etc. Auto-cleaned on exit via cleanup_temp_files().
#         Only survive a hard `kill -9` before the EXIT trap can run.
#
# ── ARTIFACTS: HDFS (SOURCE_CLUSTER and/or DEST_CLUSTER) ────────────────────
#
#   [1] <dir>/.snapshot/${SNAP_PREFIX}_0, _1, _2, ...   (on BOTH clusters)
#         The actual replication history. SNAP_RETAIN caps how many are kept
#         before old ones are pruned (see DESTRUCTIVE OPERATIONS below).
#
#   [2] <dir>/.snapshot/${SNAP_PREFIX}_rollback_<epoch>   (DEST_CLUSTER only)
#         Temporary snapshot created during a rollback attempt. Deleted again
#         on rollback success; left in place for inspection if it fails.
#
#   [3] ${HDFS_STATE_DIR}/dr-last-snap-<sanitized_dir>.txt   (on BOTH clusters)
#         (default dir: /tmp/pulse_replication_action)
#         HDFS-side mirror of the local state file, for cross-node failover
#         resilience.
#
#   [4] <destination directory>
#         Auto-created (with source's owner/permissions) only if missing AND
#         DIR_BOOTSTRAP_MODE=yes (Stage 2).
#
# ── DESTRUCTIVE OPERATIONS ───────────────────────────────────────────────────
#   (deletes or overwrites existing data/metadata — review before enabling)
#
#   [1] cleanup_old_snapshots()               Stage 4, steps 4g/4h — runs on
#       hdfs dfs -deleteSnapshot              EVERY successful sync.
#         Deletes old ${SNAP_PREFIX}_* snapshots on BOTH clusters once more
#         than SNAP_RETAIN exist. Metadata only, not live file data — but a
#         deleted snapshot cannot be recovered. Too-low SNAP_RETAIN can wipe
#         out the only common ancestor needed for a future diff/rollback.
#
#   [2] reconcile_and_rebaseline_dest()       Stage 4 baseline self-heal —
#       hdfs dfs -deleteSnapshot + recreate   runs ONCE per dir, only while
#       hadoop distcp -update (full)          last_snap == ${SNAP_PREFIX}_0.
#         Deletes + recreates DEST's ${SNAP_PREFIX}_0 snapshot, after first
#         running a full "distcp -update" from source into the destination's
#         LIVE path — can overwrite/backfill destination files that differ.
#
#   [3] rollback_once_for_failure()           Stage 4 — ONLY when a "target
#       hadoop distcp -rdiff                  modified since snapshot" error
#                                              occurs AND ROLLBACK_ON_FAILURE
#                                              ="yes" (arg 12).
#         *** MOST DESTRUCTIVE PATH IN THE SCRIPT ***
#         Runs "distcp -rdiff" against DEST's LIVE path, which REVERTS
#         destination files to the prior snapshot state, discarding any
#         destination-side changes made since. Gated behind an explicit
#         opt-in flag + a per-failure marker (won't retry the same failure).
#
#   [4] Stage 3 full baseline DistCp          AUTO_FULL_DISTCP="yes" (arg 11),
#       hadoop distcp -update (full)          or the equivalent commands
#                                              printed for manual execution.
#         Copies source into the destination's LIVE path — can overwrite
#         destination files that differ from the source.
#
#   [5] reconcile_reverse_diff_bootstrap()     Stage 4 — ONLY when a direction
#       hadoop distcp -diff (incremental)      reversal is detected AND
#                                               REVERSE_DIFF_BOOTSTRAP="yes"
#                                               (env var).
#         Can overwrite destination-side files with source-side versions for
#         the diffed range. Deliberately refuses (fails clean, no destructive
#         action) if the destination itself diverged from its last snapshot
#         — see in-function comments for the split-brain-safety rationale.
#
#   [6] Operator-guidance recovery commands    Printed only, on direction-
#       hdfs dfs -rm -f / -deleteSnapshot      reversal / split-brain /
#                                               divergent-write failures.
#         MANUAL execution by the operator — the script itself never runs
#         these; they are recovery instructions, not actions taken.
#
#   NOT destructive, for contrast: Stage 2's "hdfs dfsadmin -allowSnapshot"
#   and directory bootstrap (mkdir/chown/chmod on a MISSING destination dir
#   only) never delete or overwrite existing data.
#
###############################################################################
