### These Template Files are for reference purpose only.
# Following Flags Needs to be added in the Hadoop, Hbase, Hive Env.

### The following flags should be added after upgrading Hadoop, HBase, and Hive env files before starting the services in a JDK11 environment.
### Hadoop-env -

The Java 11 flags have been addressed in the _**${else}**_ block, which will need to be updated after the upgrade is completed during the service start process.
```
{% elif java_version == 8 %}
      SHARED_HDFS_NAMENODE_OPTS="-server -XX:ParallelGCThreads=8 -XX:+UseG1GC -XX:ErrorFile={{hdfs_log_dir_prefix}}/$USER/hs_err_pid%p.log -XX:NewSize={{namenode_opt_newsize}} -XX:MaxNewSize={{namenode_opt_maxnewsize}} -Xlog:gc*,gc+heap=debug,gc+phases=debug:file={{hdfs_log_dir_prefix}}/$USER/gc.log-`date +'%Y%m%d%H%M'`:time,level,tags -XX:InitiatingHeapOccupancyPercent=70 -Xms{{namenode_heapsize}} -Xmx{{namenode_heapsize}} -Dhadoop.security.logger=INFO,DRFAS -Dhdfs.audit.logger=INFO,DRFAAUDIT"
      export HDFS_NAMENODE_OPTS="${SHARED_HDFS_NAMENODE_OPTS} -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-namenode/bin/kill-name-node\" -Dorg.mortbay.jetty.Request.maxFormContentSize=-1 ${HDFS_NAMENODE_OPTS}"
      export HDFS_DATANODE_OPTS="-server -XX:ParallelGCThreads=4 -XX:+UseG1GC -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-datanode/bin/kill-data-node\" -XX:ErrorFile=/var/log/hadoop/$USER/hs_err_pid%p.log -XX:NewSize=200m -XX:MaxNewSize=200m -Xlog:gc*,gc+heap=debug,gc+phases=debug:file=/var/log/hadoop/$USER/gc.log-`date +'%Y%m%d%H%M'`:time,level,tags -Xms{{dtnode_heapsize}} -Xmx{{dtnode_heapsize}} -Dhadoop.security.logger=INFO,DRFAS -Dhdfs.audit.logger=INFO,DRFAAUDIT ${HDFS_DATANODE_OPTS} -XX:InitiatingHeapOccupancyPercent=70"      export HDFS_SECONDARYNAMENODE_OPTS="${SHARED_HDFS_NAMENODE_OPTS} -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-secondarynamenode/bin/kill-secondary-name-node\" ${HDFS_SECONDARYNAMENODE_OPTS}"

      # The following applies to multiple commands (fs, dfs, fsck, distcp etc)
      export HADOOP_CLIENT_OPTS="-Xmx${HADOOP_HEAPSIZE}m $HADOOP_CLIENT_OPTS"

      {% else %}
      SHARED_HDFS_NAMENODE_OPTS="-server -XX:ParallelGCThreads=8 -XX:+UseG1GC -XX:ErrorFile={{hdfs_log_dir_prefix}}/$USER/hs_err_pid%p.log -XX:NewSize={{namenode_opt_newsize}} -XX:MaxNewSize={{namenode_opt_maxnewsize}} -Xlog:gc*,gc+heap=debug,gc+phases=debug:file={{hdfs_log_dir_prefix}}/$USER/gc.log-`date +'%Y%m%d%H%M'`:time,level,tags -XX:InitiatingHeapOccupancyPercent=70 -Xms{{namenode_heapsize}} -Xmx{{namenode_heapsize}} -Dhadoop.security.logger=INFO,DRFAS -Dhdfs.audit.logger=INFO,DRFAAUDIT"
      export HDFS_NAMENODE_OPTS="${SHARED_HDFS_NAMENODE_OPTS} -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-namenode/bin/kill-name-node\" -Dorg.mortbay.jetty.Request.maxFormContentSize=-1 ${HDFS_NAMENODE_OPTS}"
      export HDFS_DATANODE_OPTS="-server -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-datanode/bin/kill-data-node\" -XX:ErrorFile=/var/log/hadoop/$USER/hs_err_pid%p.log  -verbose:gc  -Xms{{dtnode_heapsize}} -Xmx{{dtnode_heapsize}} -Dhadoop.security.logger=INFO,DRFAS -Dhdfs.audit.logger=INFO,DRFAAUDIT ${HDFS_DATANODE_OPTS} "
      export HDFS_SECONDARYNAMENODE_OPTS="${SHARED_HDFS_NAMENODE_OPTS} -XX:OnOutOfMemoryError=\"/usr/odp/current/hadoop-hdfs-secondarynamenode/bin/kill-secondary-name-node\" ${HDFS_SECONDARYNAMENODE_OPTS}"
      {% endif %}
```
-----------------

### Hbase-env -
Hbase Java 11 flags -
```
{% if java_version < 8 %}
JDK_DEPENDED_OPTS="-XX:PermSize=128m -XX:MaxPermSize=128m -XX:ReservedCodeCacheSize=256m"
{% endif %}
 # Determine the Java version (major version only)

        if [ "$java_version" -eq 8 ]; then
        # For Java version  8
        export SERVER_GC_OPTS="-verbose:gc -XX:-PrintGCCause -XX:+PrintAdaptiveSizePolicy -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:{{log_dir}}/gc.log-`date +'%Y%m%d%H%M'` -XX:+PrintHeapAtGC -XX:+PrintGCApplicationStoppedTime -XX:+PrintGCTimeStamps -XX:+PrintTenuringDistribution"
        else
        # For Java 11 and above
        export SERVER_GC_OPTS="-Xlog:gc*,gc+heap=info,gc+age=debug:file={{log_dir}}/gc.log-`date +'%Y%m%d%H%M'`:time,uptime:filecount=10,filesize=200M -XX:+UseG1GC"
        fi
```
------

### Hive-env -
Hive Java 11 flags will be updated in 2 places, 
1. metastore
2. hiveserver2

Both have been addressed below.
```
# The heap size of the jvm, and jvm args stared by hive shell script can be controlled via:
java_version=$(java -version 2>&1 | awk -F[\".] '/version/ {print $2}')
if [ "$SERVICE" = "metastore" ]; then
      export HADOOP_HEAPSIZE={{hive_metastore_heapsize}} # Setting for HiveMetastore
      if [ "$java_version" -eq 8 ]; then
      export HADOOP_OPTS="$HADOOP_OPTS -Xloggc:{{hive_log_dir}}/hivemetastore-gc-%t.log -XX:+UseG1GC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -XX:+PrintGCCause -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=10M -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath={{hive_log_dir}}/hms_heapdump.hprof -Dhive.log.dir={{hive_log_dir}} -Dhive.log.file=hivemetastore.log"
      else
      export HADOOP_OPTS="$HADOOP_OPTS -Xlog:gc*,gc+heap=debug,gc+phases=debug:file={{hive_log_dir}}/hivemetastore-gc-%t.log:time,level,tags:filecount=10,filesize=10M -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath={{hive_log_dir}}/hms_heapdump.hprof -Dhive.log.dir={{hive_log_dir}} -Dhive.log.file=hivemetastore.log"
      fi
fi
if [ "$SERVICE" = "hiveserver2" ]; then
      export HADOOP_HEAPSIZE={{hive_heapsize}} # Setting for HiveServer2 and Client
      if [ "$java_version" -eq 8 ]; then
      # For Java 8
      export HADOOP_OPTS="$HADOOP_OPTS -Xloggc:{{hive_log_dir}}/hiveserver2-gc-%t.log -XX:+UseG1GC -XX:+PrintGCDetails -XX:+PrintGCTimeStamps -XX:+PrintGCCause -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=10M -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath={{hive_log_dir}}/hs2_heapdump.hprof -Dhive.log.dir={{hive_log_dir}} -Dhive.log.file=hiveserver2.log"
      else
      # For Java 11 and above
      export HADOOP_OPTS="$HADOOP_OPTS -Xlog:gc*,gc+heap=debug,gc+phases=debug:file={{hive_log_dir}}/hiveserver2-gc-%t.log:time,level,tags:filecount=10,filesize=10M -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath={{hive_log_dir}}/hs2_heapdump.hprof -Dhive.log.dir={{hive_log_dir}} -Dhive.log.file=hiveserver2.log"
      fi
fi
```
---
### Infra-solr-env -
Infra-solr Java11 flags-
```

if [ "$java_version" -lt 11 ]; then
  # For JDK 8 and below
  infra_solr_gc_log_opts="-verbose:gc -XX:+PrintHeapAtGC -XX:+PrintGCDetails -XX:+PrintGCDateStamps -XX:+PrintGCTimeStamps -XX:+PrintTenuringDistribution -XX:+PrintGCApplicationStoppedTime -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=15 -XX:GCLogFileSize=200M"
  GC_LOG_OPTS="{{infra_solr_gc_log_opts}} -Xloggc:{{infra_solr_log_dir}}/solr_gc.log"

  infra_solr_gc_tune="-XX:NewRatio=3 -XX:SurvivorRatio=4 -XX:TargetSurvivorRatio=90 -XX:MaxTenuringThreshold=8 -XX:+UseConcMarkSweepGC -XX:+UseParNewGC -XX:ConcGCThreads=4 -XX:ParallelGCThreads=4 -XX:+CMSScavengeBeforeRemark -XX:PretenureSizeThreshold=64m -XX:+UseCMSInitiatingOccupancyOnly -XX:CMSInitiatingOccupancyFraction=50 -XX:CMSMaxAbortablePrecleanTime=6000 -XX:+CMSParallelRemarkEnabled -XX:+ParallelRefProcEnabled"
else
  # For JDK 11 and above
 # Garbage Collection Logging
 GC_LOG_OPTS="-Xlog:gc*=info:file={{infra_solr_log_dir}}/solr_gc.log:time,uptime"

  # Use separate options to handle log file rotation and size
  LOG_ROTATION_OPTS="-XX:NumberOfGCLogFiles=15 -XX:GCLogFileSize=200M"

  # Garbage Collection Tuning
  infra_solr_gc_tune="-XX:NewRatio=3 -XX:SurvivorRatio=4 -XX:TargetSurvivorRatio=90 -XX:MaxTenuringThreshold=8 -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:ConcGCThreads=4 -XX:ParallelGCThreads=4 -XX:+DisableExplicitGC"

  # Combine all options
  JAVA_OPTS="${GC_LOG_OPTS} ${LOG_ROTATION_OPTS} ${infra_solr_gc_tune}"
fi
```
----

