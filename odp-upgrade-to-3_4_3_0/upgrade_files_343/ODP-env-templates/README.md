These template files are the Ambari config values pushed by `setup_jdk17_config.sh`.

Source: odp-ambari `rel/ODP-AMBARI-3.0.1.0-1` at `2264d0061c`. ODP 3.4 extends 3.3, so service env content is the ODP 3.3 definition. YARN aux-services is the ODP 3.4 default. Infra-Solr content is `common-services/AMBARI_INFRA_SOLR/3.0.0/properties/infra-solr-env.sh.j2`.

Prefer `setup_jdk17_config.sh` on the Ambari Server. If you cannot run it, apply the same keys in Ambari Configs. Use this for a JDK 17 cluster when the source JDK is 8 or 11.

## Source JDK

- JDK 8 and 11 use the same Ambari templates. Those templates branch on `java_version` (and Azul Prime where Ambari does).
- JDK 8 only: `jdk8-specific/yarn-nodemanager-aux-services` replaces `yarn.nodemanager.aux-services` with the ODP 3.4 default, and the script deletes the old Spark 2 shuffle keys.
- JDK 17: patch mode only (ZooKeeper logback, Pinot JVM templates, Spark 3.5.8 shuffle).

## Pinot

Source: ambari-mpacks `ODP-3.4.x-main` Pinot 1.5.1 (`3b4ff3b2d6b4`).

`pinot-env` / `JAVA_HOME` stays empty so Pinot uses the cluster JDK. The script deletes a leftover JDK 8 or JDK 11 path. It does not write a JDK 17 path while the cluster `java_version` is still 8.

`pinot/pinot-*-contentjmx` is the `contentjmx` value for controller, broker, server, and minion. JDK 8 keeps `-Xloggc`. JDK 11 and above use `-Xlog`. Ambari renders the branch from `java_version` at command time.

## YARN Spark 3.5.8 shuffle

ODP 3.4 supports Spark 3.5.8 only. Config type: `yarn-site`.

1. In `yarn.nodemanager.aux-services`, replace `spark3_shuffle` and `spark_shuffle_355` with `spark_shuffle_358`.
2. Remove `spark_shuffle_411`, `spark_shuffle_333`, and `spark_shuffle_351` if present.
3. Set:

```
yarn.nodemanager.aux-services.spark_shuffle_358.class=org.apache.spark.network.yarn.v358.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_358.classpath={{stack_root}}/{{version}}/spark3/aux/*
spark.shuffle.service.v358.port=7358
```

4. Delete if present: `spark.shuffle.service.port`, `yarn.nodemanager.aux-services.spark3_shuffle.class`, `yarn.nodemanager.aux-services.spark3_shuffle.classpath`, and the class, classpath, and port keys for `spark_shuffle_355`, `spark_shuffle_411`, `spark_shuffle_333`, and `spark_shuffle_351`.

Restart NodeManagers after this change.

## ZooKeeper logback

Create config type `zookeeper-logback` from `zookeeper-logback.xml` if it is missing.
