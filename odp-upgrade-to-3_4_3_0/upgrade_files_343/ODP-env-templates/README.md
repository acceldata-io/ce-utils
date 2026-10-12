These template files are the Ambari config values pushed by `setup_jdk17_config.sh`.

Prefer `setup_jdk17_config.sh` on the Ambari Server. If you cannot run it, apply the same keys in Ambari Configs. Use this for a JDK 17 cluster when the source JDK is 8 or 11.

## Source JDK

- JDK 8: `jdk8-specific/` overrides (YARN aux-services, HBase env, Druid env).
- JDK 11: `jdk11-specific/infra-solr-env-template` for Infra-Solr content. Druid uses the top-level `druid-env-template` and `druid-env-opts`.
- JDK 17: patch mode only (ZooKeeper logback, Pinot JAVA_HOME, Spark 3.5.8 shuffle).

## Pinot JAVA_HOME

Config type: `pinot-env`
Key: `JAVA_HOME`
Value: stack JDK 17 home, for example `/usr/lib/jvm/java-17-openjdk`

Ambari UI: Pinot -> Configs -> Advanced pinot-env.

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

## Druid

- Source JDK 8: `jdk8-specific/druid-env-template` and `jdk8-specific/druid-env-opts`
- Source JDK 11 or 17: `druid-env-template` and `druid-env-opts`

Set `druid.broker.jvm.opts`, `druid.coordinator.jvm.opts`, `druid.historical.jvm.opts`, `druid.middlemanager.jvm.opts`, `druid.overlord.jvm.opts`, `druid.router.jvm.opts`.

## ZooKeeper logback

Create config type `zookeeper-logback` from `zookeeper-logback.xml` if it is missing.
