These steps copy the ODP 3.4 Express and Rolling upgrade packs onto the Ambari Server so MPACK services are included in the planner.

Source: odp-ambari branch rel/ODP-AMBARI-3.0.1.0-1 (facc6918eb).

Ambari loads the upgrade pack from the source stack. A 3.2.3 cluster (ODP-8211) only sees packs under `stacks/ODP/3.2/upgrades/`. `3.2/upgrades/nonrolling-upgrade-3.4.xml` and `3.2/upgrades/upgrade-3.4.xml` are the ODP 3.3 target-3.4 packs, so Express and Rolling from 3.2.3 to 3.4.3.0 include Kafka3, Pinot, HttpFS, Ozone, Spark3, Impala, Hue, Airflow, and JupyterHub. A 3.3 source uses the same packs from `3.3/upgrades/`. Ambari skips a group when that service is not installed.

## MPACK upgrade planner (ODP-8228)

Files are copied from this repo. Do not download an Ambari RPM for this step. Stacks that are not installed on the server are skipped. Existing XMLs are backed up under `mpacks-upgrade-planner-backup/`.

1. Clone the Acceldata utility repository and change the directory.

```
git clone https://github.com/acceldata-io/ce-utils.git
cd ce-utils
cd ./odp-upgrade-to-3_4_3_0/upgrade_files_343/
```

2. Launch the setup script.

```
bash ./setup_mpacks_upgrade_planner.sh
```

3. Restart Ambari Server so the planner reloads the packs.

```
ambari-server restart
```

4. Apply JDK 17 service flags before the upgrade. Run this on the Ambari Server when the target cluster is JDK 17 and the source JDK is 8 or 11. The same script exists for 3.3.6.5-1 under `odp-upgrade-to-3_3_6_5_1/upgrade_files_336/`. Edit `USER`, `PASSWORD`, `PORT`, and `PROTOCOL` at the top of the script first. `AMBARISERVER` defaults to `hostname -f`.

```
cd ./odp-upgrade-to-3_4_3_0/upgrade_files_343/
bash ./setup_jdk17_config.sh
```

At the JDK prompt, enter the JDK the cluster runs on before this upgrade:

- `8`: JDK 8 -> JDK 17. Full menu. Choose `A` for every service.
- `11`: JDK 11 -> JDK 17. Full menu. Choose `A` for every service.
- `17`: cluster is already on JDK 17 (for example 3.3.6 on JDK 17 -> 3.4.3). Menu is ZooKeeper logback, Pinot `JAVA_HOME`, and Spark 3.5.8 shuffle.

Source JDK 8 and 11 update HDFS, YARN, MapReduce, Infra-Solr, Hive, Tez, HBase, Oozie, Ranger KMS, Druid, ZooKeeper, and Pinot. YARN shuffle is Spark 3.5.8 only (`spark_shuffle_358`). Templates are under `upgrade_files_343/ODP-env-templates/`. If the script cannot be run, apply those templates in Ambari Configs. Restart the affected services in Ambari after the script.

5. Create a new Express or Rolling upgrade. A plan that is already paused keeps the groups it was created with. This copy does not rewrite that plan.

A 3.2 source reads `stacks/ODP/3.2/upgrades/config-upgrade.xml` only. That file now defines `odp_3_4_0_hdfs_log4j_remove_event_counter` (Hadoop 3.4 removed `EventCounter`) and the JDK 8 to 17 `jvm_flags` copy for HDFS, YARN, MapReduce, Tez, and Hive. The env insert is rendered when `java_version` is greater than 11, so a cluster still on JDK 8 keeps its current opts until the stack JDK is 17. NodeManager pre-upgrade runs `odp_3_4_0_yarn_spark_358_only` so `yarn.nodemanager.aux-services` switches from Spark 3.5.5 (`spark_shuffle_355`) to Spark 3.5.8 (`spark_shuffle_358`) before the NodeManager restart. The shuffle jar is `spark3_python<version>_<stack>-yarn-shuffle`.
