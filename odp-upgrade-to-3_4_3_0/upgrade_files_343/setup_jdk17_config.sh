#!/bin/bash

#---------------------------------------------------------
# Configuration Content
#---------------------------------------------------------

##########################################################################
# Acceldata Inc. | ODP
#
# ODP 3.4.3. Updates service configuration for a JDK 17 cluster when the
# source JDK is 8 or 11, and patch-upgrade fixes when the cluster is already
# on JDK 17.
#
# Run on the Ambari Server from upgrade_files_343, before Express or Rolling:
#   bash ./setup_jdk17_config.sh
#
# Source JDK 8 or 11: full service menu (HDFS, YARN, MapReduce, Infra-Solr,
# Hive, Tez, HBase, Ranger KMS, ZooKeeper, Pinot).
# Oozie and Druid are not part of ODP 3.4.3.
# Source JDK 17: ZooKeeper logback, Pinot JAVA_HOME, Spark 3.5.8 shuffle.
##########################################################################
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m'  # No Color
#---------------------------------------------------------
# Default Values (Edit these if required)
#---------------------------------------------------------
AMBARISERVER=$(hostname -f)
USER="admin"
PASSWORD="admin"
PORT=8080
PROTOCOL="http"  # Change to "https" if Ambari Server is configured with SSL


# Template directory
TEMPLATE_DIR="./ODP-env-templates"
MIGRATION_PATH=""  # Will be set based on source JDK version
JAVA_VERSION=""

#---------------------------------------------------------
# Ambari SSL Certificate Handling (if HTTPS enabled)
#---------------------------------------------------------
if [[ "${PROTOCOL,,}" == "https" ]]; then
    AMBARI_CERT_PATH="/tmp/ambari.crt"
    if openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" </dev/null 2>/dev/null \
        | openssl x509 -outform PEM > "${AMBARI_CERT_PATH}" && [[ -s "${AMBARI_CERT_PATH}" ]]; then
        export REQUESTS_CA_BUNDLE="${AMBARI_CERT_PATH}"
    else
        echo -e "${RED}[ERROR] Could not obtain Ambari SSL certificate.${NC}"
    fi
    export PYTHONHTTPSVERIFY=0  # Optional fallback
fi

#---------------------------------------------------------
# Helper Function: Retrieve Host for a Given Component
#---------------------------------------------------------
get_host_for_component() {
    local component="$1"
    curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' \
      "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=${component}" \
      | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | head -n 1
}

#---------------------------------------------------------
# Retrieve Ambari Cluster and Host Information
#---------------------------------------------------------
CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' \
    "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" \
    | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')


echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}       Acceldata ODP Configuration Script for JDK 17       ${NC}"
echo -e "${GREEN}===========================================================${NC}"

echo -e "${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "${GREEN}USER:${NC} $USER"
echo -e "${GREEN}PORT:${NC} $PORT"
echo -e "${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "${GREEN}CLUSTER:${NC} $CLUSTER"

#---------------------------------------------------------
# Detect source JDK version and set migration path
#---------------------------------------------------------
detect_source_jdk() {
    echo -e "${YELLOW}Detecting source JDK version...${NC}"
    read -rp "Select source JDK version (8/11/17): " source_jdk

    case "$source_jdk" in
        8)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk8-specific"
            echo -e "${GREEN}Migration path set: JDK 8 -> JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        11)
            MIGRATION_PATH=""
            echo -e "${GREEN}Migration path set: JDK 11 -> JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        17)
            MIGRATION_PATH=""
            echo -e "${GREEN}Patch-upgrade mode: cluster already on JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        *)
            echo -e "${RED}Invalid selection. Exiting.${NC}"
            exit 1
            ;;
    esac
}

#---------------------------------------------------------
# Function: set_config
# Invokes the Ambari configuration script to set a given property.
#---------------------------------------------------------
set_config() {
    local config_file=$1 key=$2 value=$3

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a set \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_file" \
        -k "$key" \
        -v "$value" \
        -b "Configuration updates to support JDK 17" \
    && echo -e "${GREEN}[OK]${NC} Updated ${config_file}:${key}" \
    || echo -e "${RED}Failed updating ${key} in ${config_file}.${NC}" | tee -a /tmp/jdk17_update.log
}

# Create/replace an entire config type from Ambari configuration XML (configs.py -f).
# Use this for new types (e.g. hbase-log4j2) that may not yet exist as desired configs.
set_config_from_file() {
    local config_type=$1
    local xml_file=$2

    if [[ ! -f "$xml_file" ]]; then
        echo -e "${RED}Template not found: ${xml_file}${NC}" | tee -a /tmp/jdk17_update.log
        return 1
    fi

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a set \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" \
        -f "$xml_file" \
        -b "Configuration updates to support JDK 17 / Log4j2" \
    && echo -e "${GREEN}[OK]${NC} Updated ${config_type} from $(basename "$xml_file")" \
    || echo -e "${RED}Failed updating ${config_type} from ${xml_file}.${NC}" | tee -a /tmp/jdk17_update.log
}

delete_config() {
    local config_file=$1 key=$2

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a delete \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_file" \
        -k "$key" \
        -b "Old configuration deleted" \
    && echo -e "${GREEN}[OK]${NC} Deleted ${config_file}:${key}" \
    || echo -e "${RED}Failed updating ${key} in ${config_file}.${NC}" | tee -a /tmp/jdk17_update.log
}

# Resolve cluster stack java.home (same source Ambari uses for hostLevelParams/java_home).
resolve_stack_java_home() {
    local java_home=""
    local candidate=""

    for candidate in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-17; do
        if [[ -d "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
            break
        fi
    done

    if [[ -z "$java_home" && -L /usr/lib/jvm/java ]]; then
        candidate=$(readlink -f /usr/lib/jvm/java 2>/dev/null || true)
        if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
        fi
    fi

    if [[ -z "$java_home" ]]; then
        candidate=$(ls -d /usr/lib/jvm/java-*openjdk* 2>/dev/null | sort -V | tail -1)
        if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
        fi
    fi

    echo "$java_home"
}

get_config_property() {
    local config_type=$1
    local property_key=$2
    local value=""

    value=$(python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a get \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" 2>/dev/null \
        | python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.search(r'\{.*\}', raw, re.S); d=json.loads(m.group(0)) if m else {}; print(d.get('properties',{}).get('${property_key}',''))" 2>/dev/null)

    echo "$value"
}

# Returns 0 when the Ambari config type exists and has at least one property.
config_type_present() {
    local config_type=$1
    local count=""

    count=$(python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a get \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" 2>/dev/null \
        | python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.search(r'\{.*\}', raw, re.S); d=json.loads(m.group(0)) if m else {}; print(len(d.get('properties',{})))" 2>/dev/null)

    [[ -n "$count" && "$count" -gt 0 ]]
}

#---------------------------------------------------------
# Service-Specific JVM options
#---------------------------------------------------------

JVM_FLAGS_HDFS="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_YARN="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED"
JVM_FLAGS_TEZ="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_HIVE="--add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.regex=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED --add-opens=java.base/jdk.internal.reflect=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/sun.nio.cs=ALL-UNNAMED --add-opens=java.base/sun.security.provider=ALL-UNNAMED --add-opens=java.sql/java.sql=ALL-UNNAMED"
JVM_FLAGS_KMS="--add-exports java.xml.crypto/com.sun.org.apache.xml.internal.security.utils=ALL-UNNAMED"

#---------------------------------------------------------
# Service-Specific Configuration Update Functions
#---------------------------------------------------------

update_hdfs_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HDFS, YARN, and MapReduce...${NC}"

    set_config "hdfs-site" "jvm_flags" "${JVM_FLAGS_HDFS}"
    set_config "hadoop-env" "content" "$(cat $TEMPLATE_DIR/hdfs-env-template)"

    set_config "yarn-site" "jvm_flags" "${JVM_FLAGS_YARN}"
    set_config "mapred-env" "content" "$(cat $TEMPLATE_DIR/mapred-env-template)"
    set_config "mapred-site" "yarn.app.mapreduce.am.admin-command-opts" "$(cat $TEMPLATE_DIR/mapred-site-template)"
    set_config "yarn-env" "content" "$(cat $TEMPLATE_DIR/yarn-env-template)"
    set_config "yarn-hbase-env" "content" "$(cat $TEMPLATE_DIR/yarn-hbase-env-template)"

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "yarn-site" "yarn.nodemanager.aux-services" "$(cat $MIGRATION_PATH/yarn-nodemanager-aux-services)"
      # Remove configs
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.class"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.class"
    fi

    # ODP 3.4 ships Spark 3.5.8 only (EU task odp_3_4_0_yarn_spark_358_only).
    # Required for JDK 8 -> 17 and JDK 11 -> 17 before Express or Rolling.
    if [ "$JAVA_VERSION" -eq "8" ] || [ "$JAVA_VERSION" -eq "11" ]; then
      update_yarn_spark_shuffle_isolation
    fi

    echo -e "${GREEN}Successfully updated configurations for HDFS, YARN, and MapReduce.${NC}"
}

# Mirrors Ambari config-upgrade task odp_3_4_0_yarn_spark_358_only.
# ODP 3.4 supports Spark 3.5.8 only. spark3_shuffle and spark_shuffle_355
# become spark_shuffle_358. Older handlers 411, 333, and 351 are removed.
update_yarn_spark_shuffle_isolation() {
    echo -e "${YELLOW}Migrating YARN NodeManager Spark shuffle to Spark 3.5.8 (odp_3_4_0_yarn_spark_358_only)...${NC}"

    local aux_services tokens token trimmed joined seen_358
    aux_services=$(get_config_property "yarn-site" "yarn.nodemanager.aux-services")

    if [[ -z "$aux_services" ]]; then
        echo -e "${RED}[ERROR] yarn.nodemanager.aux-services is empty or missing.${NC}" | tee -a /tmp/jdk17_update.log
        return 1
    fi

    joined=""
    seen_358=0
    IFS=',' read -ra tokens <<< "$aux_services"
    for token in "${tokens[@]}"; do
        trimmed="${token#"${token%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        case "$trimmed" in
            spark3_shuffle|spark_shuffle_355)
                trimmed="spark_shuffle_358"
                ;;
            spark_shuffle_411|spark_shuffle_333|spark_shuffle_351|"")
                continue
                ;;
        esac
        if [[ "$trimmed" == "spark_shuffle_358" ]]; then
            if [[ "$seen_358" -eq 1 ]]; then
                continue
            fi
            seen_358=1
        fi
        if [[ -n "$joined" ]]; then
            joined="${joined},${trimmed}"
        else
            joined="$trimmed"
        fi
    done
    if [[ "$seen_358" -eq 0 ]]; then
        if [[ -n "$joined" ]]; then
            joined="${joined},spark_shuffle_358"
        else
            joined="spark_shuffle_358"
        fi
    fi

    set_config "yarn-site" "yarn.nodemanager.aux-services" "$joined"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_358.class" "org.apache.spark.network.yarn.v358.YarnShuffleService"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_358.classpath" "{{stack_root}}/{{version}}/spark3/aux/*"
    set_config "yarn-site" "spark.shuffle.service.v358.port" "7358"

    delete_config "yarn-site" "spark.shuffle.service.port"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark3_shuffle.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark3_shuffle.classpath"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_355.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_355.classpath"
    delete_config "yarn-site" "spark.shuffle.service.v355.port"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_411.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_411.classpath"
    delete_config "yarn-site" "spark.shuffle.service.v411.port"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_333.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_333.classpath"
    delete_config "yarn-site" "spark.shuffle.service.v333.port"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_351.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_351.classpath"
    delete_config "yarn-site" "spark.shuffle.service.v351.port"

    echo -e "${GREEN}Successfully updated YARN Spark 3.5.8 shuffle configs.${NC}"
}

update_infra_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Infra-Solr...${NC}"

    set_config "infra-solr-env" "infra_solr_gc_log_opts" "$(cat $TEMPLATE_DIR/infra-solr-gc-log-opts)"
    set_config "infra-solr-env" "infra_solr_gc_tune" "$(cat $TEMPLATE_DIR/infra-solr-gc-tune)"
    # Ambari infra-solr-env.sh.j2 branches on java_version, so both source JDKs get the same content.
    set_config "infra-solr-env" "content" "$(cat $TEMPLATE_DIR/infra-solr-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Infra-Solr.${NC}"
}

update_hive_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Tez and Hive...${NC}"

    set_config "tez-site" "jvm_flags" "${JVM_FLAGS_TEZ}"
    set_config "tez-env" "content" "$(cat $TEMPLATE_DIR/tez-env-template)"
    set_config "tez-site" "tez.am.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-am-site-template)"
    set_config "tez-site" "tez.task.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-task-site-template)"

    set_config "hive-site" "jvm_flags" "${JVM_FLAGS_HIVE}"
    set_config "hive-env" "content" "$(cat $TEMPLATE_DIR/hive-env-template)"
    set_config "hive-site" "hive.tez.java.opts" "$(cat $TEMPLATE_DIR/hive-tez-java-opts)"
    set_config "hive-interactive-env" "llap_java_opts" "$(cat $TEMPLATE_DIR/hive-llap-java-opts)"
    set_config "hive-interactive-env" "content" "$(cat $TEMPLATE_DIR/hive-interactive-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Tez and Hive.${NC}"
}

update_hbase_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HBase...${NC}"

    # Push Log4j2 content as hbase-log4j2 (creates the desired config type if missing).
    # Same pattern as ZooKeeper logback / Hive-Infra JVM props via configs.py.
    set_config_from_file "hbase-log4j2" "$TEMPLATE_DIR/hbase-log4j2.xml"

    # Also refresh legacy hbase-log4j content for clusters that still use that type name.
    if [[ -f "$TEMPLATE_DIR/hbase-log4j2-template" ]]; then
      set_config "hbase-log4j" "content" "$(cat "$TEMPLATE_DIR/hbase-log4j2-template")"
    fi

    # Ambari hbase-env content branches on java_version (8 vs 11+ / Azul Prime).
    set_config "hbase-env" "content" "$(cat $TEMPLATE_DIR/hbase-env-template)"

    echo -e "${GREEN}Successfully updated configurations for HBase.${NC}"
}

update_kms_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger KMS...${NC}"

    set_config "kms-site" "jvm_flags" "${JVM_FLAGS_KMS}"
    set_config "kms-env" "content" "$(cat $TEMPLATE_DIR/kms-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Ranger KMS.${NC}"
}

update_zookeeper_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for ZooKeeper...${NC}"

    # Create the complete desired config when it is missing on upgraded clusters.
    set_config_from_file "zookeeper-logback" "$TEMPLATE_DIR/zookeeper-logback.xml"

    echo -e "${GREEN}Successfully updated configurations for ZooKeeper.${NC}"
}

update_pinot_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Pinot...${NC}"

    local stack_java_home
    stack_java_home=$(resolve_stack_java_home)
    if [[ -z "$stack_java_home" || ! -d "$stack_java_home" ]]; then
        echo -e "${RED}[ERROR] Could not resolve stack java.home for Pinot.${NC}" | tee -a /tmp/jdk17_update.log
        return 1
    fi

    echo -e "${GREEN}Resetting pinot-env JAVA_HOME to stack java.home: ${stack_java_home}${NC}"
    set_config "pinot-env" "JAVA_HOME" "${stack_java_home}"

    echo -e "${GREEN}Successfully updated configurations for Pinot.${NC}"
}

# Patch-upgrade helpers for clusters already on JDK 17 (for example 3.3.6 on JDK 17 -> 3.4.3).
run_jdk17_patch_upgrade_all() {
    update_zookeeper_configuration_for_jdk17
    update_pinot_configuration_for_jdk17
    update_yarn_spark_shuffle_isolation
}

#---------------------------------------------------------
# Menu for Selecting Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    echo -e "${GREEN}JDK 17 configuration menu - choose a service${NC}"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"

    case "$source_jdk" in
            8)
                echo -e "${GREEN}  1)${NC} HDFS, YARN and MapReduce"
                echo -e "${GREEN}  2)${NC} Infra-Solr"
                echo -e "${GREEN}  3)${NC} Hive and Tez"
                echo -e "${GREEN}  4)${NC} HBase (env + log4j2)"
                echo -e "${GREEN}  5)${NC} Ranger KMS"
                echo -e "${GREEN}  6)${NC} ZooKeeper (logback)"
                echo -e "${GREEN}  7)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN}  8)${NC} YARN Spark 3.5.8 shuffle (pre-EU)"
                ;;
            11)
                echo -e "${GREEN}  1)${NC} HDFS, YARN and MapReduce"
                echo -e "${GREEN}  2)${NC} Infra-Solr"
                echo -e "${GREEN}  3)${NC} Hive and Tez"
                echo -e "${GREEN}  4)${NC} HBase (env + log4j2)"
                echo -e "${GREEN}  5)${NC} Ranger KMS"
                echo -e "${GREEN}  6)${NC} ZooKeeper (logback)"
                echo -e "${GREEN}  7)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN}  8)${NC} YARN Spark 3.5.8 shuffle (pre-EU)"
                ;;
            17)
                echo -e "${GREEN}  1)${NC} ZooKeeper (logback)"
                echo -e "${GREEN}  2)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN}  3)${NC} YARN Spark 3.5.8 shuffle (pre-EU)"
                ;;
        esac

    echo -e "${YELLOW}------------------------------------------------------------${NC}"
    if [ "$source_jdk" != "17" ]; then
    echo -e "${GREEN}  A)${NC} All services"
    else
    echo -e "${GREEN}  A)${NC} All patch-upgrade fixes (ZooKeeper, Pinot, YARN Spark 3.5.8 shuffle)"
    fi
    echo -e "${RED}  Q)${NC} Quit (no changes)"
    echo -e "${YELLOW}------------------------------------------------------------${NC}"
}

handle_selection() {
    local choice="$1"
    case "$source_jdk" in
        8)
            case "$choice" in
                1) update_hdfs_configuration_for_jdk17 ;;
                2) update_infra_configuration_for_jdk17 ;;
                3) update_hive_configuration_for_jdk17 ;;
                4) update_hbase_configuration_for_jdk17 ;;
                5) update_kms_configuration_for_jdk17 ;;
                6) update_zookeeper_configuration_for_jdk17 ;;
                7) update_pinot_configuration_for_jdk17 ;;
                8) update_yarn_spark_shuffle_isolation ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_hbase_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_zookeeper_configuration_for_jdk17
                    update_pinot_configuration_for_jdk17
                    ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
        11)
            case "$choice" in
                1) update_hdfs_configuration_for_jdk17 ;;
                2) update_infra_configuration_for_jdk17 ;;
                3) update_hive_configuration_for_jdk17 ;;
                4) update_hbase_configuration_for_jdk17 ;;
                5) update_kms_configuration_for_jdk17 ;;
                6) update_zookeeper_configuration_for_jdk17 ;;
                7) update_pinot_configuration_for_jdk17 ;;
                8) update_yarn_spark_shuffle_isolation ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_hbase_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_zookeeper_configuration_for_jdk17
                    update_pinot_configuration_for_jdk17
                    ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
        17)
            case "$choice" in
                1) update_zookeeper_configuration_for_jdk17 ;;
                2) update_pinot_configuration_for_jdk17 ;;
                3) update_yarn_spark_shuffle_isolation ;;
                [Aa]) run_jdk17_patch_upgrade_all ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
    esac

    return 0
}

#---------------------------------------------------------
# Main Menu Loop
#---------------------------------------------------------
main() {
    # Detect and set migration path
    detect_source_jdk

    # Verify template directory exists
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        echo -e "${RED}Error: Template directory not found: $TEMPLATE_DIR${NC}"
        exit 1
    fi

    echo -e "${GREEN}Using templates from: $TEMPLATE_DIR${NC}\n"

    while true; do
        display_service_options
        read -rp "Enter your selection: " choice

        handle_selection "$choice" || break
    done

    #---------------------------------------------------------
    # Post-Execution: Move Generated JSON Files (if any)
    #---------------------------------------------------------
    if ls doSet_version* 1> /dev/null 2>&1; then
        mv doSet_version* /tmp
        echo -e "${GREEN}JSON files moved to /tmp.${NC}"
    else
        echo -e "${YELLOW}No JSON files found to move.${NC}"
    fi

    echo -e "${GREEN}Script execution completed.${NC}"
    echo -e "${YELLOW}Access the Ambari UI and restart the affected services to apply the changes.${NC}"
}

# Run main function
main