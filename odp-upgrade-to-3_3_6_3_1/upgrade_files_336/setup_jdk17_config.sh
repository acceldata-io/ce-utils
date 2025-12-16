#!/bin/bash

#---------------------------------------------------------
# Configuration Content
#---------------------------------------------------------

##########################################################################
# Acceldata Inc. | ODP
#
# This script updates configuration for various services to support JDK 17
#
# Usage:
#   ./setup_ssl_with_existing_jks.sh
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

echo -e "⚙️ ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "🏢 ${GREEN}CLUSTER:${NC} $CLUSTER"

#---------------------------------------------------------
# Detect source JDK version and set migration path
#---------------------------------------------------------
detect_source_jdk() {
    echo -e "${YELLOW}Detecting source JDK version...${NC}"
    read -rp "Select source JDK version (8/11): " source_jdk

    case "$source_jdk" in
        8)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk8-to-jdk17"
            echo -e "${GREEN}Migration path set: JDK 8 → JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        11)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk11-to-jdk17"
            echo -e "${GREEN}Migration path set: JDK 11 → JDK 17${NC}"
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

#---------------------------------------------------------
# Service-Specific JVM options
#---------------------------------------------------------

JVM_FLAGS_HDFS="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_YARN="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED"
JVM_FLAGS_TEZ="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_HIVE="--add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.regex=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED --add-opens=java.base/jdk.internal.reflect=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/sun.nio.cs=ALL-UNNAMED --add-opens=java.base/sun.security.provider=ALL-UNNAMED --add-opens=java.sql/java.sql=ALL-UNNAMED"
JVM_FLAGS_OOZIE="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_KMS="--add-exports java.xml.crypto/com.sun.org.apache.xml.internal.security.utils=ALL-UNNAMED"

#---------------------------------------------------------
# Service-Specific Configuration Update Functions
#---------------------------------------------------------

update_hdfs_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HDFS, YARN, and MapReduce...${NC}"

    set_config "hdfs-site" "jvm_flags" "${JVM_FLAGS_HDFS}"
    set_config "hadoop-env" "content" "$(cat $MIGRATION_PATH/HDFS-env-template)"

    set_config "yarn-site" "jvm_flags" "${JVM_FLAGS_YARN}"
    set_config "mapred-env" "content" "$(cat $MIGRATION_PATH/Mpreduce-env-template)"
    set_config "mapred-site" "yarn.app.mapreduce.am.admin-command-opts" "$(cat $MIGRATION_PATH/Mpreduce-site-template)"
    set_config "yarn-env" "content" "$(cat $MIGRATION_PATH/Yarn-env-template)"

    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "yarn-hbase-env" "content" "$(cat $MIGRATION_PATH/Yarn-hbase-env-template)"
      set_config "Node Manager" "yarn.nodemanager.aux-services" "$(cat $MIGRATION_PATH/Yarn-nodemanager-aux-services)"
      # Remove configs
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.class"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.class"
    fi

    echo -e "${GREEN}Successfully updated configurations for HDFS, YARN, and MapReduce.${NC}"
}

update_infra_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Infra-Solr...${NC}"

    set_config "infra-solr-env" "infra_solr_gc_log_opts" "$(cat $MIGRATION_PATH/Infra-solr-gc-log-opts)"
    set_config "infra-solr-env" "infra_solr_gc_tune" "$(cat $MIGRATION_PATH/Infra-solr-gc-tune)"

    if [ "$JAVA_VERSION" -eq "11" ]; then
      set_config "infra-solr-env" "content" "$(cat $MIGRATION_PATH/Infra-solr-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for Infra-Solr.${NC}"
}

update_hive_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Tez and Hive...${NC}"

    set_config "tez-site" "jvm_flags" "${JVM_FLAGS_TEZ}"
    set_config "tez-env" "content" "$(cat $MIGRATION_PATH/Tez-env-template)"
    set_config "tez-site" "tez.am.launch.cluster-default.cmd-opts" "$(cat $MIGRATION_PATH/Tez-site-template)"
    set_config "tez-site" "tez.task.launch.cluster-default.cmd-opts" "$(cat $MIGRATION_PATH/Tez-site-template)"

    set_config "hive-site" "jvm_flags" "${JVM_FLAGS_HIVE}"
    set_config "hive-env" "content" "$(cat $MIGRATION_PATH/Hive-env-template)"
    set_config "hive-site" "hive.tez.java.opts" "$(cat $MIGRATION_PATH/Hive-tez-java-opts)"

    set_config "hive-interactive-env" "llap_java_opts" "$(cat $MIGRATION_PATH/Hive-llap-java-opts)"
    set_config "hive-interactive-env" "content" "$(cat $MIGRATION_PATH/Hive-interactive-env-template)"

    if [ "$JAVA_VERSION" -eq "8" ]; then
      # Remove configs
      delete_config "tez-site" "tez.am.launch.cmd-opts"
      delete_config "tez-site" "tez.task.launch.cmd-opts"
    fi

    echo -e "${GREEN}Successfully updated configurations for Tez and Hive.${NC}"
}

update_hbase_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HBase...${NC}"

    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "hbase-env" "content" "$(cat $MIGRATION_PATH/HBase-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for HBase.${NC}"
}

update_oozie_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Oozie...${NC}"

    set_config "oozie-site" "jvm_flags" "${JVM_FLAGS_OOZIE}"
    set_config "oozie-env" "content" "$(cat $MIGRATION_PATH/Oozie-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Oozie.${NC}"
}

update_kms_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger KMS...${NC}"

    set_config "kms-site" "jvm_flags" "${JVM_FLAGS_KMS}"
    set_config "kms-env" "content" "$(cat $MIGRATION_PATH/Kms-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Ranger KMS.${NC}"
}

update_druid_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger Druid...${NC}"
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "druid-env" "content" "$(cat $MIGRATION_PATH/Druid-env-template)"
      set_config "druid-env" "druid.broker.jvm.opts" "$(cat $MIGRATION_PATH/Druid-env-opts)"
      set_config "druid-env" "druid.coordinator.jvm.opt" "$(cat $MIGRATION_PATH/Druid-env-opts)"
      set_config "druid-env" "druid.historical.jvm.opt" "$(cat $MIGRATION_PATH/Druid-env-opts)"
      set_config "druid-env" "druid.middlemanager.jvm.opts" "$(cat $MIGRATION_PATH/Druid-env-opts)"
      set_config "druid-env" "druid.overlord.jvm.opts" "$(cat $MIGRATION_PATH/Druid-env-opts)"
      set_config "druid-env" "druid.router.jvm.opts" "$(cat $MIGRATION_PATH/Druid-env-opts)"
    fi
    echo -e "${GREEN}Successfully updated configurations for Ranger Druid.${NC}"
}

#---------------------------------------------------------
# Menu for Selecting Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "        ${GREEN}🚀  JDK 17 Configuration Upgrade Menu – Choose a Service${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}\n"
    echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
    echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
    echo -e "${GREEN}  3)${NC} 🐝   Hive & Tez"
    echo -e "${GREEN}  4)${NC} 🌀   Oozie"
    echo -e "${GREEN}  5)${NC} 🔑   Ranger KMS"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} 🌐   All Services (for the brave)"
    echo -e "${RED}  Q)${NC} ❌   Quit (no changes)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
}

#---------------------------------------------------------
# Main Menu Loop
#---------------------------------------------------------
main() {
    # Detect and set migration path
    detect_source_jdk

    # Verify template directory exists
    if [[ ! -d "$MIGRATION_PATH" ]]; then
        echo -e "${RED}Error: Template directory not found: $MIGRATION_PATH${NC}"
        exit 1
    fi

    echo -e "${GREEN}Using templates from: $MIGRATION_PATH${NC}\n"

    while true; do
        display_service_options
        read -rp "Enter your selection: ⇒ " choice
        case "$choice" in
            1) update_hdfs_configuration_for_jdk17 ;;
            2) update_infra_configuration_for_jdk17 ;;
            3) update_hive_configuration_for_jdk17 ;;
            4) update_oozie_configuration_for_jdk17 ;;
            5) update_kms_configuration_for_jdk17 ;;
            [Aa])
                update_hdfs_configuration_for_jdk17
                update_infra_configuration_for_jdk17
                update_hive_configuration_for_jdk17
                update_oozie_configuration_for_jdk17
                update_kms_configuration_for_jdk17
                ;;
            [Qq])
                echo -e "${GREEN}Exiting...${NC}"
                break
                ;;
            *)
                echo -e "${RED}Invalid selection.${NC} Please choose a valid option."
                ;;
        esac
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