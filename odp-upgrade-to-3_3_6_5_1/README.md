These steps will help to prepare the cluster for ODP cluster upgrade to 3.3.6.5-1

## Usage Instructions
1. Clone this repository or download it (as a zip/tar) on the Ambari Server node.
```
git clone https://github.com/acceldata-io/ce-utils.git
```
2. Navigate to `odp-upgrade-to-3_3_6_5_1` directory.
```
cd odp-upgrade-to-3_3_6_5_1
```
3. Execute the below command to add the pre-requisites to upgrade the cluster to `3.3.6.5-1`
```
bash upgrade_ambari_336.sh
```
4. Please restart the ambari-server
```
ambari-server restart
```

## MPACK upgrade planner (ODP-7693)

This copies bundled Express/Rolling upgrade-pack XMLs onto the Ambari Server so MPACK services (Spark3 / Spark3 3.3.3 / Spark3 3.5.1, Livy3, Impala, Pinot, Kafka3) appear in the upgrade plan. Files are copied from this repo; do not download an Ambari RPM for this step.

Source: https://github.com/acceldata-io/odp-ambari/commit/06daf47ad117c230b8bbf40ff6ff41f5a0f07871

Same flow as the Java 17 flags script: clone, change directory, run the script, restart Ambari.

1. Clone the Acceldata utility repository and change the directory.

```
git clone https://github.com/acceldata-io/ce-utils.git
cd ce-utils
cd ./odp-upgrade-to-3_3_6_5_1/upgrade_files_336/
```

2. Launch the setup script.

```
bash ./setup_mpacks_upgrade_planner.sh
```

Stacks that are not installed on the server are skipped. Existing XMLs are backed up under `mpacks-upgrade-planner-backup/`.

3. Restart Ambari Server so the planner reloads the packs.

```
ambari-server restart
```

4. In Ambari, create a new Express or Rolling upgrade (do not reuse a plan generated before this copy).

## ZooKeeper logback (before resume upgrade)

Bundled upgrade XMLs no longer run `create_and_configure` for `zookeeper-logback` during EU/RU. That avoids the cross-stack failure on rolling upgrades (for example 3.2 to 3.3).

Before resuming the upgrade (after Ambari and mpack steps), run:

```
cd ./odp-upgrade-to-3_3_6_5_1/upgrade_files_336/
bash ./setup_jdk17_config.sh
```

At the JDK prompt:

- **8** or **11**: full JDK migration configs (first-time move to JDK 17). Choose **8** or **11** based on the JDK the cluster ran on before JDK 17.
- **17**: patch-upgrade mode for clusters already on JDK 17 (for example 3.3.6.4-1 -> 3.3.6.5-1012). Menu options are limited to ZooKeeper logback, Pinot JAVA_HOME, and YARN Spark shuffle isolation.

For cross-stack EU (3.2 -> 3.3) on JDK 8/11, choose option **8** (ZooKeeper logback) or **A** (all services).

For patch EU on JDK 17, choose **17** at the prompt, then option **1**, **3**, or **A** as needed.
