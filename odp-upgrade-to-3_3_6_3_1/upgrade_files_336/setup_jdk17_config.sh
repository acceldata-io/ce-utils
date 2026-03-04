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
            MIGRATION_PATH="$TEMPLATE_DIR/jdk8-specific"
            echo -e "${GREEN}Migration path set: JDK 8 → JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        11)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk11-specific"
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_PINOT_CONTROLLER_CONF="${SCRIPT_DIR}/../../../ambari-mpacks/common-services/PINOT/1.4.0/configuration/pinot-controller-conf.xml"

PINOT_CONTROLLER_STARTSCRIPT_XML=$(cat <<'EOF'
    <property>
        <name>contentcontrollerstartscript</name>
        <display-name>Pinot Controller Start Script</display-name>
        <description>Pinot Controller Start Script.</description>
        <value>#!/bin/bash

# Extract secrets from JCEKS using your command
export PINOT_ADMIN_PASSWORD=$(
{{java_home_from_ambari}}/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
org.apache.ambari.server.credentialapi.CredentialUtil \
-provider jceks://file/etc/security/credential/pinot.jceks get pinot.admin.pass
)

export PINOT_KEYSTORE_PASS=$(
{{java_home_from_ambari}}/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
org.apache.ambari.server.credentialapi.CredentialUtil \
-provider jceks://file/etc/security/credential/pinot.jceks get pinot.keystore.pass
)

export PINOT_TRUSTSTORE_PASS=$(
{{java_home_from_ambari}}/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
org.apache.ambari.server.credentialapi.CredentialUtil \
-provider jceks://file/etc/security/credential/pinot.jceks get pinot.truststore.pass
)

# Optionally source your /etc/sysconfig/pinot-controller for other variables
if [ -f /etc/sysconfig/pinot-controller ]; then
. /etc/sysconfig/pinot-controller
fi

# Start Pinot Controller
exec /usr/odp/{{stack_version_buildnum}}/pinot/bin/pinot-admin.sh StartController -config /usr/odp/{{stack_version_buildnum}}/pinot/conf/pinot-controller.conf
        </value>
        <value-attributes>
            <type>content</type>
        </value-attributes>
        <on-ambari-upgrade add="false"/>
    </property>
EOF
)

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

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "yarn-hbase-env" "content" "$(cat $MIGRATION_PATH/yarn-hbase-env-template)"
      set_config "yarn-site" "yarn.nodemanager.aux-services" "$(cat $MIGRATION_PATH/yarn-nodemanager-aux-services)"
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

    set_config "infra-solr-env" "infra_solr_gc_log_opts" "$(cat $TEMPLATE_DIR/infra-solr-gc-log-opts)"
    set_config "infra-solr-env" "infra_solr_gc_tune" "$(cat $TEMPLATE_DIR/infra-solr-gc-tune)"

    # Java 11 specific configuration changes
    if [ "$JAVA_VERSION" -eq "11" ]; then
      set_config "infra-solr-env" "content" "$(cat $MIGRATION_PATH/infra-solr-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for Infra-Solr.${NC}"
}

update_hive_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Tez and Hive...${NC}"

    set_config "tez-site" "jvm_flags" "${JVM_FLAGS_TEZ}"
    set_config "tez-env" "content" "$(cat $TEMPLATE_DIR/tez-env-template)"
    set_config "tez-site" "tez.am.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"
    set_config "tez-site" "tez.task.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"

    set_config "hive-site" "jvm_flags" "${JVM_FLAGS_HIVE}"
    set_config "hive-env" "content" "$(cat $TEMPLATE_DIR/hive-env-template)"
    set_config "hive-site" "hive.tez.java.opts" "$(cat $TEMPLATE_DIR/hive-tez-java-opts)"
    set_config "hive-interactive-env" "llap_java_opts" "$(cat $TEMPLATE_DIR/hive-llap-java-opts)"
    set_config "hive-interactive-env" "content" "$(cat $TEMPLATE_DIR/hive-interactive-env-template)"

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      # Remove configs
      delete_config "tez-site" "tez.am.launch.cmd-opts"
      delete_config "tez-site" "tez.task.launch.cmd-opts"
    fi

    echo -e "${GREEN}Successfully updated configurations for Tez and Hive.${NC}"
}

# Needed only in JDK 8
update_hbase_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HBase...${NC}"

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "hbase-env" "content" "$(cat $MIGRATION_PATH/hbase-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for HBase.${NC}"
}

update_oozie_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Oozie...${NC}"

    set_config "oozie-site" "jvm_flags" "${JVM_FLAGS_OOZIE}"
    set_config "oozie-env" "content" "$(cat $TEMPLATE_DIR/oozie-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Oozie.${NC}"
}

update_kms_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger KMS...${NC}"

    set_config "kms-site" "jvm_flags" "${JVM_FLAGS_KMS}"
    set_config "kms-env" "content" "$(cat $TEMPLATE_DIR/kms-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Ranger KMS.${NC}"
}

# Needed only in JDK 8
update_druid_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger Druid...${NC}"

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "druid-env" "content" "$(cat $MIGRATION_PATH/druid-env-template)"
      set_config "druid-env" "druid.broker.jvm.opts" "$(cat $MIGRATION_PATH/druid-env-opts)"
      set_config "druid-env" "druid.coordinator.jvm.opt" "$(cat $MIGRATION_PATH/druid-env-opts)"
      set_config "druid-env" "druid.historical.jvm.opt" "$(cat $MIGRATION_PATH/druid-env-opts)"
      set_config "druid-env" "druid.middlemanager.jvm.opts" "$(cat $MIGRATION_PATH/druid-env-opts)"
      set_config "druid-env" "druid.overlord.jvm.opts" "$(cat $MIGRATION_PATH/druid-env-opts)"
      set_config "druid-env" "druid.router.jvm.opts" "$(cat $MIGRATION_PATH/druid-env-opts)"
    fi
    echo -e "${GREEN}Successfully updated configurations for Ranger Druid.${NC}"
}

update_pinot_mpack_configuration_for_140() {
    local pinot_controller_conf="$DEFAULT_PINOT_CONTROLLER_CONF"
    local tmp_file

    echo -e "${YELLOW}Starting Pinot MPack consistency update for 1.4.0...${NC}"
    read -rp "Enter pinot-controller-conf.xml path [${pinot_controller_conf}]: " user_path
    pinot_controller_conf="${user_path:-$pinot_controller_conf}"

    if [[ ! -f "$pinot_controller_conf" ]]; then
        echo -e "${RED}File not found: $pinot_controller_conf${NC}"
        return 1
    fi

    if grep -q "<name>contentcontrollerstartscript</name>" "$pinot_controller_conf"; then
        echo -e "${GREEN}[OK]${NC} Pinot 1.4.0 start-script property already exists. No changes needed."
        return 0
    fi

    tmp_file=$(mktemp)
    awk -v block="$PINOT_CONTROLLER_STARTSCRIPT_XML" '
        /<\/configuration>/ && !inserted {
            print block
            inserted=1
        }
        { print }
    ' "$pinot_controller_conf" > "$tmp_file" && mv "$tmp_file" "$pinot_controller_conf"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}[OK]${NC} Added missing contentcontrollerstartscript property to:"
        echo -e "${GREEN}${pinot_controller_conf}${NC}"
    else
        echo -e "${RED}Failed to update ${pinot_controller_conf}.${NC}" | tee -a /tmp/jdk17_update.log
        rm -f "$tmp_file"
        return 1
    fi
}

#---------------------------------------------------------
# Menu for Selecting Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "        ${GREEN}🚀  JDK 17 Configuration Upgrade Menu – Choose a Service${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}\n"

    case "$source_jdk" in
            8)
                echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
                echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
                echo -e "${GREEN}  3)${NC} 🐝   Hive & Tez"
                echo -e "${GREEN}  4)${NC} 🐘   HBase"
                echo -e "${GREEN}  5)${NC} 🌀   Oozie"
                echo -e "${GREEN}  6)${NC} 🔑   Ranger KMS"
                echo -e "${GREEN}  7)${NC} 📊   Druid"
                echo -e "${GREEN}  8)${NC} 🧩   Pinot MPack Sync (1.4.0)"
                ;;
            11)
                echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
                echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
                echo -e "${GREEN}  3)${NC} 🐝   Hive & Tez"
                echo -e "${GREEN}  4)${NC} 🌀   Oozie"
                echo -e "${GREEN}  5)${NC} 🔑   Ranger KMS"
                echo -e "${GREEN}  6)${NC} 🧩   Pinot MPack Sync (1.4.0)"
                ;;
        esac

    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} 🌐   All Services (for the brave)"
    echo -e "${RED}  Q)${NC} ❌   Quit (no changes)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
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
                5) update_oozie_configuration_for_jdk17 ;;
                6) update_kms_configuration_for_jdk17 ;;
                7) update_druid_configuration_for_jdk17 ;;
                8) update_pinot_mpack_configuration_for_140 ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_hbase_configuration_for_jdk17
                    update_oozie_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_druid_configuration_for_jdk17
                    update_pinot_mpack_configuration_for_140
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
                4) update_oozie_configuration_for_jdk17 ;;
                5) update_kms_configuration_for_jdk17 ;;
                6) update_pinot_mpack_configuration_for_140 ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_oozie_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_pinot_mpack_configuration_for_140
                    ;;
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
        read -rp "Enter your selection: ⇒ " choice

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