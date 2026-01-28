#!/bin/bash

#---------------------------------------------------------
# Configuration Content
#---------------------------------------------------------

##########################################################################
# Acceldata Inc. | ODP
#
# This script updates configuration for various services to support JDK 11
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
echo -e "${GREEN}       Acceldata ODP Configuration Script for JDK 11       ${NC}"
echo -e "${GREEN}===========================================================${NC}"

echo -e "⚙️ ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "🏢 ${GREEN}CLUSTER:${NC} $CLUSTER"

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
        -b "Configuration updates to support JDK 11" \
    && echo -e "${GREEN}[OK]${NC} Updated ${config_file}:${key}" \
    || echo -e "${RED}Failed updating ${key} in ${config_file}.${NC}" | tee -a /tmp/jdk11_update.log
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
    || echo -e "${RED}Failed updating ${key} in ${config_file}.${NC}" | tee -a /tmp/jdk11_update.log
}

#---------------------------------------------------------
# Service-Specific Configuration Update Functions
#---------------------------------------------------------

update_hdfs_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for HDFS, YARN, and MapReduce...${NC}"

    set_config "hadoop-env" "content" "$(cat $TEMPLATE_DIR/hdfs-env-template)"
    set_config "yarn-env" "content" "$(cat $TEMPLATE_DIR/yarn-env-template)"

    echo -e "${GREEN}Successfully updated configurations for HDFS, YARN, and MapReduce.${NC}"
}

update_infra_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for Infra-Solr...${NC}"

    set_config "infra-solr-env" "content" "$(cat $TEMPLATE_DIR/infra-solr-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Infra-Solr.${NC}"
}

update_hive_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for Tez and Hive...${NC}"

    set_config "tez-env" "content" "$(cat $TEMPLATE_DIR/tez-env-template)"
    set_config "tez-site" "tez.am.launch.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"
    set_config "tez-site" "tez.am.launch.env" "$(cat $TEMPLATE_DIR/tez-site-template)"
    set_config "tez-site" "tez.task.launch.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"

    set_config "hive-env" "content" "$(cat $TEMPLATE_DIR/hive-env-template)"
    set_config "hive-site" "hive.tez.java.opts" "$(cat $TEMPLATE_DIR/hive-tez-java-opts)"

    echo -e "${GREEN}Successfully updated configurations for Tez and Hive.${NC}"
}

update_hbase_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for HBase...${NC}"

    set_config "hbase-env" "content" "$(cat $TEMPLATE_DIR/hbase-env-template)"

    echo -e "${GREEN}Successfully updated configurations for HBase.${NC}"
}

update_oozie_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for Oozie...${NC}"

    set_config "oozie-env" "content" "$(cat $TEMPLATE_DIR/oozie-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Oozie.${NC}"
}

update_druid_configuration_for_jdk11() {
    echo -e "${YELLOW}Starting to update configurations for Ranger Druid...${NC}"

    set_config "druid-env" "content" "$(cat $TEMPLATE_DIR/druid-env-template)"
    set_config "druid-env" "druid.broker.jvm.opts" "$(cat $TEMPLATE_DIR/druid-env-opts)"
    set_config "druid-env" "druid.coordinator.jvm.opt" "$(cat $TEMPLATE_DIR/druid-env-opts)"
    set_config "druid-env" "druid.historical.jvm.opt" "$(cat $TEMPLATE_DIR/druid-env-opts)"
    set_config "druid-env" "druid.middlemanager.jvm.opts" "$(cat $TEMPLATE_DIR/druid-env-opts)"
    set_config "druid-env" "druid.overlord.jvm.opts" "$(cat $TEMPLATE_DIR/druid-env-opts)"
    set_config "druid-env" "druid.router.jvm.opts" "$(cat $TEMPLATE_DIR/druid-env-opts)"

    echo -e "${GREEN}Successfully updated configurations for Ranger Druid.${NC}"
}

#---------------------------------------------------------
# Menu for Selecting Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "        ${GREEN}🚀  JDK 11 Configuration Upgrade Menu – Choose a Service${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}\n"

    echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
    echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
    echo -e "${GREEN}  3)${NC} 🐝   Hive & Tez"
    echo -e "${GREEN}  4)${NC} 🐘   HBase"
    echo -e "${GREEN}  5)${NC} 🌀   Oozie"
    echo -e "${GREEN}  6)${NC} 📊   Druid"

    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} 🌐   All Services (for the brave)"
    echo -e "${RED}  Q)${NC} ❌   Quit (no changes)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
}

handle_selection() {
    local choice="$1"

    case "$choice" in
        1) update_hdfs_configuration_for_jdk11 ;;
        2) update_infra_configuration_for_jdk11 ;;
        3) update_hive_configuration_for_jdk11 ;;
        4) update_hbase_configuration_for_jdk11 ;;
        5) update_oozie_configuration_for_jdk11 ;;
        6) update_druid_configuration_for_jdk11 ;;
        [Aa])
            update_hdfs_configuration_for_jdk11
            update_infra_configuration_for_jdk11
            update_hive_configuration_for_jdk11
            update_hbase_configuration_for_jdk11
            update_oozie_configuration_for_jdk11
            update_druid_configuration_for_jdk11
            ;;
        [Qq])
            echo -e "${YELLOW}Exiting without changes.${NC}"
            return 1
            ;;
        *)
            echo -e "${RED}Invalid selection. Please try again.${NC}"
            return 1
            ;;
    esac

    return 0
}

#---------------------------------------------------------
# Main Menu Loop
#---------------------------------------------------------
main() {
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