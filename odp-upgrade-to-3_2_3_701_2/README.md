These steps will help to prepare the cluster for ODP cluster upgrade to 3.2.3.701-2.

This kit is 3.3.6.5-1 plus HttpFS, Ozone, Hue, Airflow, and JupyterHub in the Ambari Express/Rolling upgrade packs (and `stack_packages.json` mappings for those services).

## Usage Instructions
1. Clone this repository or download it (as a zip/tar) on the Ambari Server node.
```
git clone https://github.com/acceldata-io/ce-utils.git
```
2. Navigate to `odp-upgrade-to-3_2_3_701_2` directory.
```
cd odp-upgrade-to-3_2_3_701_2
```
3. Execute the below command to add the pre-requisites to upgrade the cluster to `3.2.3.701-2`
```
bash upgrade_ambari_336.sh
```
4. Please restart the ambari-server
```
ambari-server restart
```

For a same-stack ODP 3.2 patch Express/Rolling upgrade (for example 3.2.3.5 to 3.2.3.7), skip `upgrade_ambari_336.sh`. That script copies the 3.3 stack definition onto the server. Use only the MPACK upgrade planner section below.

## MPACK upgrade planner

This copies bundled Express/Rolling upgrade-pack XMLs onto the Ambari Server so MPACK services (Spark3 / Spark3 3.3.3 / Spark3 3.5.1, Livy3, Impala, Pinot, Kafka3, HttpFS, Ozone, Hue, Airflow, JupyterHub) appear in the upgrade plan. Files are copied from this repo; do not download an Ambari RPM for this step.

On an ODP 3.2 cluster, Express uses `nonrolling-upgrade-3.2.xml` and Rolling uses `upgrade-3.2.xml`. HttpFS and Ozone restart after `HDFS_LEAVE_SAFEMODE`. Hue, Airflow, and JupyterHub restart after Zeppelin. Ambari skips a group when that service is not installed.

Same flow as the Java 17 flags script: clone, change directory, run the script, restart Ambari.

1. Clone the Acceldata utility repository and change the directory.

```
git clone https://github.com/acceldata-io/ce-utils.git
cd ce-utils
cd ./odp-upgrade-to-3_2_3_701_2/upgrade_files_323701/
```

2. Launch the setup script.

```
bash ./setup_mpacks_upgrade_planner.sh
```

Stacks that are not installed on the server are skipped. Existing XMLs are backed up under `mpacks-upgrade-planner-backup/`.

3. Confirm the packs on the Ambari Server before starting the upgrade:

```
grep -E 'name="HTTPFS"|name="OZONE"|name="HUE"|name="AIRFLOW"|name="JUPYTER"' \
  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.2.xml
grep -E 'name="HTTPFS"|name="OZONE"|name="HUE"|name="AIRFLOW"|name="JUPYTER"' \
  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/upgrade-3.2.xml
```

You should see `HTTPFS`, `OZONE`, `HUE`, `AIRFLOW`, and `JUPYTER` groups. For a same-stack 3.2 Rolling upgrade, confirm the Rolling pack targets ODP-3.2 (not ODP-3.3):

```
grep -E '<target>|<target-stack>|<type>' \
  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/upgrade-3.2.xml
```

Expected: `target 3.2.*.*`, `target-stack ODP-3.2`, `type ROLLING`. If this file targets 3.3, Ambari greys out Rolling with "Not allowed by the current version". Confirm Express service checks too:

```
grep -A20 'name="SERVICE_CHECK_1"' \
  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.2.xml
```

`SERVICE_CHECK_1` must list `HTTPFS` and `OZONE` after `HDFS`. `SERVICE_CHECK_2` must list `HUE`, `AIRFLOW`, and `JUPYTER` after Zeppelin. Express Upgrade only runs service checks that appear in those priority lists. Then restart Ambari Server so the planner reloads the packs.

```
ambari-server restart
```

4. In Ambari, create a new Express or Rolling upgrade (do not reuse a plan generated before this copy).

If `upgrade_files_323701/scripts/ozone_client.py` is present, the planner replaces `ozone_client.py` with empty `start()` / `stop()` (same as HDFS Client). Express Upgrade STOP of `OZONE_CLIENT` fails with `stop method isn't implemented` without that copy. This kit does not ship that script; the planner skips the patch and logs a warning. If a remote copy is still needed, place `ozone_client.py` onto each agent:

```
/var/lib/ambari-agent/cache/common-services/OZONE/1.4.1/package/scripts/ozone_client.py
```

Then click Retry. Ozone Client is not a daemon; IGNORE AND PROCEED on those STOP tasks is also safe.
