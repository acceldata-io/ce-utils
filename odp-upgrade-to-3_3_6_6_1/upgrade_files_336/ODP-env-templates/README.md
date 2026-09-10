These template files are for the Ambari UI / manual config path.

Prefer `setup_jdk17_config.sh` when you can run it on the Ambari Server. If you cannot, apply the same keys in Ambari Configs as below. This is the 3.3.6.5-1 delta vs 3.3.6.4-1.

## Pinot JAVA_HOME (new)

Config type: `pinot-env`
Key: `JAVA_HOME`
Value: stack JDK 17 home, for example `/usr/lib/jvm/java-17-openjdk`

Ambari UI: Pinot -> Configs -> Advanced pinot-env.

## YARN Spark shuffle isolation (new)

Config type: `yarn-site`

Replace `spark3_shuffle` with `spark_shuffle_355` in `yarn.nodemanager.aux-services`.
Append `,spark_shuffle_333` if Spark3 3.3.3 is installed.
Append `,spark_shuffle_351` if Spark3 3.5.1 is installed.

Set:

```
yarn.nodemanager.aux-services.spark_shuffle_355.class=org.apache.spark.network.yarn.v355.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_355.classpath={{stack_root}}/{{version}}/spark3/aux/*
spark.shuffle.service.v355.port=7335
yarn.nodemanager.aux-services.spark_shuffle_411.class=org.apache.spark.network.yarn.v411.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_411.classpath={{stack_root}}/{{version}}/spark4/aux/*
spark.shuffle.service.v411.port=7341
yarn.nodemanager.aux-services.spark_shuffle_333.class=org.apache.spark.network.yarn.v333.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_333.classpath={{stack_root}}/{{version}}/spark3_3_3_3/aux/*
spark.shuffle.service.v333.port=7333
yarn.nodemanager.aux-services.spark_shuffle_351.class=org.apache.spark.network.yarn.v351.YarnShuffleService
yarn.nodemanager.aux-services.spark_shuffle_351.classpath={{stack_root}}/{{version}}/spark3_3_5_1/aux/*
spark.shuffle.service.v351.port=7351
```

Delete: `spark.shuffle.service.port`, `yarn.nodemanager.aux-services.spark3_shuffle.class`, `yarn.nodemanager.aux-services.spark3_shuffle.classpath`.

## Druid (changed: now JDK 8, 11, and 17)

3.3.6.4-1 only applied Druid on source JDK 8 and used the typo key `druid.coordinator.jvm.opt`.
3.3.6.5-1 uses `druid.*.jvm.opts` for every node type.

- Source JDK 8: `jdk8-specific/druid-env-template` and `jdk8-specific/druid-env-opts`
- Source JDK 11 or 17: `druid-env-template` and `druid-env-opts`

Set `druid.broker.jvm.opts`, `druid.coordinator.jvm.opts`, `druid.historical.jvm.opts`, `druid.middlemanager.jvm.opts`, `druid.overlord.jvm.opts`, `druid.router.jvm.opts`.

## ZooKeeper logback (same as 3.3.6.4-1)

Create config type `zookeeper-logback` from `zookeeper-logback.xml` if it is missing.
