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

## Manual configs (Ambari UI)

Use this only if you cannot run `setup_jdk17_config.sh`. These are the extra 3.3.6.5-1 items vs 3.3.6.4-1. Templates live under `upgrade_files_336/ODP-env-templates/`. After saving, restart the affected services.

### 1. Pinot JAVA_HOME (new in 3.3.6.5-1)

Ambari UI -> Pinot -> Configs -> Advanced pinot-env -> `JAVA_HOME`.

Set it to the stack JDK 17 home (same value as Ambari `stack.java.home`), for example:

```
/usr/lib/jvm/java-17-openjdk
```

If that directory does not exist, use `/usr/lib/jvm/java-17` or `readlink -f /usr/lib/jvm/java`. Skip this if Pinot is not installed.

### 2. YARN Spark shuffle isolation (new in 3.3.6.5-1)

Ambari UI -> YARN -> Configs -> Custom yarn-site.

1. Edit `yarn.nodemanager.aux-services`:
   - Replace `spark3_shuffle` with `spark_shuffle_355`.
   - If Spark3 3.3.3 is installed (`spark3-3.3.3-env` exists) and `spark_shuffle_333` is missing, append `,spark_shuffle_333`.
   - If Spark3 3.5.1 is installed (`spark3-3.5.1-env` exists) and `spark_shuffle_351` is missing, append `,spark_shuffle_351`.
2. Set these properties (create them if missing):

```
yarn.nodemanager.aux-services.spark_shuffle_355.class = org.apache.spark.network.yarn.v355.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_355.classpath = {{stack_root}}/{{version}}/spark3/aux/*
spark.shuffle.service.v355.port = 7335

yarn.nodemanager.aux-services.spark_shuffle_411.class = org.apache.spark.network.yarn.v411.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_411.classpath = {{stack_root}}/{{version}}/spark4/aux/*
spark.shuffle.service.v411.port = 7341

yarn.nodemanager.aux-services.spark_shuffle_333.class = org.apache.spark.network.yarn.v333.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_333.classpath = {{stack_root}}/{{version}}/spark3_3_3_3/aux/*
spark.shuffle.service.v333.port = 7333

yarn.nodemanager.aux-services.spark_shuffle_351.class = org.apache.spark.network.yarn.v351.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_351.classpath = {{stack_root}}/{{version}}/spark3_3_5_1/aux/*
spark.shuffle.service.v351.port = 7351
```

3. Delete if present: `spark.shuffle.service.port`, `yarn.nodemanager.aux-services.spark3_shuffle.class`, `yarn.nodemanager.aux-services.spark3_shuffle.classpath`.

Restart NodeManagers after this change.

### 3. Druid JDK 11/17 jvm.opts (changed in 3.3.6.5-1)

3.3.6.4-1 only pushed Druid on source JDK 8, and used a typo key `druid.coordinator.jvm.opt`. 3.3.6.5-1 applies Druid for JDK 8, 11, and 17, and uses `jvm.opts` for every node type.

Ambari UI -> Druid -> Configs -> Advanced druid-env.

Set all of these to the value in `ODP-env-templates/druid-env-opts` (JDK 11/17) or `ODP-env-templates/jdk8-specific/druid-env-opts` (source JDK 8):

- `druid.broker.jvm.opts`
- `druid.coordinator.jvm.opts`
- `druid.historical.jvm.opts`
- `druid.middlemanager.jvm.opts`
- `druid.overlord.jvm.opts`
- `druid.router.jvm.opts`

Also refresh `druid-env` `content` from `ODP-env-templates/druid-env-template` (JDK 11/17) or `ODP-env-templates/jdk8-specific/druid-env-template` (source JDK 8). Skip if Druid is not installed.

### 4. ZooKeeper logback (same as 3.3.6.4-1, still required)

If `zookeeper-logback` is missing in Ambari, create it from `ODP-env-templates/zookeeper-logback.xml` (Ambari UI -> ZooKeeper -> Configs, or `configs.py -a set -c zookeeper-logback -f ...`).
