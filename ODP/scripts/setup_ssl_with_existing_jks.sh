#!/usr/bin/env bash
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ © 2025 Acceldata Inc. All Rights Reserved.                                │
# │                                                                           │
# │ Backup & restore Ambari Mpack service configurations                      │
# └───────────────────────────────────────────────────────────────────────────┘

# Set Ambari server details
export AMBARISERVER=$(hostname -f)
export USER=admin
export PASSWORD=admin
export PORT=8080
export PROTOCOL=http

echo -e "${BOLD}${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}${CYAN}Ambari Configuration Backup & Restore Tool${NC} ${BOLD}${YELLOW}│${NC}"
echo -e "${BOLD}${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"
echo -e "${GREEN}🔑  Settings to Verify:${NC}"
printf "   %-15s : %s\n" "AMBARISERVER" "$AMBARISERVER"
printf "   %-15s : %s\n" "USER" "$USER"
printf "   %-15s : ********\n" "PASSWORD"
printf "   %-15s : %s\n" "PORT" "$PORT"
printf "   %-15s : %s\n" "PROTOCOL" "$PROTOCOL"
printf "   %-15s : %s\n" "CONFIG_BACKUP_DIR" "$(pwd)/upgrade_backup"
echo ""
# echo -e "🔑 Please ensure that you have set all variables correctly."
# echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
# echo -e "👤 ${GREEN}USER:${NC} $USER"
# echo -e "🔒 ${GREEN}PASSWORD:${NC} ********" # Replace with actual password above
# echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
# echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"

#---------------------------------------------------------
# Ambari SSL Certificate Handling (if HTTPS enabled)
#---------------------------------------------------------
if [[ "${PROTOCOL,,}" == "https" ]]; then
    AMBARI_CERT_PATH="/tmp/ambari-ca-bundle.crt"

    echo | openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" 2>/dev/null |
        awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ print $0; if (/END CERTIFICATE/) print "" }' > "${AMBARI_CERT_PATH}"

    if [[ -s "${AMBARI_CERT_PATH}" ]]; then
        echo -e "${GREEN}✔ [INFO] Full CA bundle saved at:${NC} ${AMBARI_CERT_PATH}"
        echo ""
        export REQUESTS_CA_BUNDLE="${AMBARI_CERT_PATH}"
    else
        echo -e "${RED}[ERROR] Could not extract CA bundle from Ambari.${NC}"
    fi

    export PYTHONHTTPSVERIFY=0 # Optional: disables HTTPS cert validation in Python (use cautiously)
fi


# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

# Function to display messages in green color
print_success() {
    echo -e "${GREEN}$1${NC}"
}

# Function to display messages in yellow color
print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

# Function to display messages in red color
print_error() {
    echo -e "${RED}$1${NC}"
}

# Function to retrieve cluster name from Ambari
get_cluster_name() {
    local cluster=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
    echo "$cluster"
}

# Function to display script information and usage instructions
print_script_info() {
    echo -e "${BOLD}${CYAN}┌────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│  Ambari Configuration Backup & Restore Tool    │${NC}"
    echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────┘${NC}"
    echo -e "${CYAN}This tool lets you backup and restore service configs in Ambari-managed clusters.${NC}"
    echo -e "${CYAN}Make sure all variables are set correctly before proceeding.${NC}"
    echo -e "${YELLOW}Usage: ./config_backup_restore.sh${NC}"
}

# Prompt user to confirm actions
confirm_action() {
    local action="$1"
    read -p "Are you sure you want to $action? (yes/no): " choice
    case "$choice" in
    [yY][eE][sS])
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

# Define configurations for each service
HUE_CONFIGS=(
    "hue-auth-site"
    hue-desktop-site
    hue-hadoop-site
    hue-hbase-site
    hue-hive-site
    hue-impala-site
    hue-log4j-env
    hue-notebook-site
    hue-oozie-site
    hue-pig-site
    hue-rdbms-site
    hue-solr-site
    hue-spark-site
    hue-ugsync-site
    hue-zookeeper-site
    hue.ini
    pseudo-distributed.ini
    services
    hue-env
)

IMPALA_CONFIGS=(
"fair-scheduler"
"impala-log4j-properties"
"llama-site"
"impala-env"
)

KAFKA_CONFIGS=(
    "kafka_client_jaas_conf"
    "kafka_jaas_conf"
    "ranger-kafka-policymgr-ssl"
    "ranger-kafka-security"
    "ranger-kafka-audit"
    "kafka-env"
    "ranger-kafka-plugin-properties"
    "kafka-broker"
)

RANGER_CONFIGS=(
    "admin-properties"
    "atlas-tagsync-ssl"
    "ranger-solr-configuration"
    "ranger-tagsync-policymgr-ssl"
    "ranger-tagsync-site"
    "tagsync-application-properties"
    "ranger-ugsync-site"
    "ranger-env"
    "ranger-admin-site"
)

RANGER_KMS_CONFIGS=(
    "kms-env"
    "kms-properties"
    "ranger-kms-policymgr-ssl"
    "ranger-kms-site"
    "ranger-kms-security"
    "dbks-site"
    "kms-site"
    "ranger-kms-audit"
)

SPARK3_CONFIGS=(
    "livy3-client-conf"
    "livy3-env"
    "livy3-log4j-properties"
    "livy3-spark-blacklist"
    "spark3-env"
    "spark3-hive-site-override"
    "spark3-log4j-properties"
    "spark3-thrift-fairscheduler"
    "spark3-metrics-properties"
    "livy3-conf"
    "spark3-defaults"
    "spark3-thrift-sparkconf"
)

NIFI_CONFIGS=(
    "nifi-ambari-config"
    "nifi-authorizers-env"
    "nifi-bootstrap-env"
    "nifi-bootstrap-notification-services-env"
    "nifi-env"
    "nifi-flow-env"
    "nifi-state-management-env"
    "ranger-nifi-policymgr-ssl"
    "ranger-nifi-security"
    "nifi-login-identity-providers-env"
    "nifi-properties"
    "ranger-nifi-plugin-properties"
    "nifi-ambari-ssl-config"
    "ranger-nifi-audit"
)

SCHEMA_REGISTRY_CONFIG=(
    ranger-schema-registry-audit
    ranger-schema-registry-plugin-properties
    ranger-schema-registry-policymgr-ssl
    ranger-schema-registry-security
    registry-common
    registry-env
    registry-log4j
    registry-logsearch-conf
    registry-ssl-config
    registry-sso-config
)

HTTPFS_CONFIG=(
    httpfs-site
    httpfs-log4j
    httpfs-env
    httpfs
)

KUDU_CONFIG=(
    kudu-master-env
    kudu-master-stable-advanced
    kudu-tablet-env
    kudu-tablet-stable-advanced
    kudu-unstable
    ranger-kudu-plugin-properties
    ranger-kudu-policymgr-ssl
    ranger-kudu-security
    kudu-env
    ranger-kudu-audit
)

JUPYTER_CONFIG=(
    jupyterhub_config-py
    sparkmagic-conf
    jupyterhub-conf
)

FLINK_CONFIG=(
    flink-env
    flink-log4j-console.properties
    flink-log4j-historyserver
    flink-logback-rest
    flink-conf
    flink-log4j
)

DRUID_CONFIG=(
    druid-historical
    druid-logrotate
    druid-overlord
    druid-router
    druid-log4j
    druid-middlemanager
    druid-env
    druid-broker
    druid-common
    druid-coordinator
)

AIRFLOW_CONFIG=(
    airflow-admin-site
    airflow-api-site
    airflow-atlas-site
    airflow-celery-site
    airflow-cli-site
    airflow-core-site
    airflow-dask-site
    airflow-database-site
    airflow-elasticsearch-site
    airflow-email-site
    airflow-env
    airflow-githubenterprise-site
    airflow-hive-site
    airflow-kubernetes-site
    airflow-kubernetes_executor-site
    airflow-kubernetessecrets-site
    airflow-ldap-site
    airflow-lineage-site
    airflow-logging-site
    airflow-mesos-site
    airflow-metrics-site
    airflow-openlineage-site
    airflow-operators-site
    airflow-scheduler-site
    airflow-smtp-site
    airflow-kerberos-site
    airflow-webserver-site
)

OZONE_CONFIG=(
ozone-log4j-datanode
ozone-log4j-om
ozone-log4j-properties
ozone-log4j-recon
ozone-log4j-s3g
ozone-log4j-scm
ozone-ssl-client
ranger-ozone-plugin-properties
ranger-ozone-policymgr-ssl
ranger-ozone-security
ssl-client-datanode
ssl-client-om
ssl-client-recon
ssl-client-s3g
ssl-client-scm
ssl-server-datanode
ssl-server-om
ssl-server-recon
ssl-server-s3g
ssl-server-scm
ozone-core-site
ranger-ozone-audit
ozone-env
ozone-site
)

# Function to backup configuration
backup_config() {
    local config="$1"
    local backup_dir="upgrade_backup/$config"
    mkdir -p "$backup_dir"
    print_warning "Backing up configuration: $config"
    local ssl_flag=""
    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi
    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        print_success "Backup of $config completed successfully."
    else
        print_error "Failed to backup $config. Please check logs for details."
    fi
}

# Function to restore configuration
restore_config() {
    local config="$1"
    local backup_dir="upgrade_backup/$config"
    print_warning "Restoring configuration: $config"
    local ssl_flag=""
    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi
    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        print_success "Restore of $config completed successfully."
    else
        print_error "Failed to restore $config. Please check logs for details."
    fi
}

# Function to backup Hue configurations
backup_hue_configs() {
    for config in "${HUE_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Hue configurations
restore_hue_configs() {
    for config in "${HUE_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Impala configurations
backup_impala_configs() {
    for config in "${IMPALA_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Impala configurations
restore_impala_configs() {
    for config in "${IMPALA_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Kafka configurations
backup_kafka_configs() {
    for config in "${KAFKA_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Kafka configurations
restore_kafka_configs() {
    for config in "${KAFKA_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Ranger configurations
backup_ranger_configs() {
    for config in "${RANGER_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Ranger configurations
restore_ranger_configs() {
    for config in "${RANGER_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Ranger KMS configurations
backup_ranger_kms_configs() {
    for config in "${RANGER_KMS_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Ranger KMS configurations
restore_ranger_kms_configs() {
    for config in "${RANGER_KMS_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Spark3 configurations
backup_spark3_configs() {
    for config in "${SPARK3_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Spark3 configurations
restore_spark3_configs() {
    for config in "${SPARK3_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup NiFi configurations
backup_nifi_configs() {
    for config in "${NIFI_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore NiFi configurations
restore_nifi_configs() {
    for config in "${NIFI_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Schema Registry configurations
backup_schema_registry_configs() {
    for config in "${SCHEMA_REGISTRY_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Schema Registry configurations
restore_schema_registry_configs() {
    for config in "${SCHEMA_REGISTRY_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup HTTPFS configurations
backup_httpfs_configs() {
    for config in "${HTTPFS_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore HTTPFS configurations
restore_httpfs_configs() {
    for config in "${HTTPFS_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Kudu configurations
backup_kudu_configs() {
    for config in "${KUDU_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Kudu configurations
restore_kudu_configs() {
    for config in "${KUDU_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Jupyter configurations
backup_jupyter_configs() {
    for config in "${JUPYTER_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Jupyter configurations
restore_jupyter_configs() {
    for config in "${JUPYTER_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Flink configurations
backup_flink_configs() {
    for config in "${FLINK_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Flink configurations
restore_flink_configs() {
    for config in "${FLINK_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Druid configurations
backup_druid_configs() {
    for config in "${DRUID_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Druid configurations
restore_druid_configs() {
    for config in "${DRUID_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Airflow configurations
backup_airflow_configs() {
    for config in "${AIRFLOW_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Airflow configurations
restore_airflow_configs() {
    for config in "${AIRFLOW_CONFIG[@]}"; do
        restore_config "$config"
    done
}
# Function to backup Ozone configurations
backup_ozone_configs() {
    for config in "${OZONE_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore Ozone configurations
restore_ozone_configs() {
    for config in "${OZONE_CONFIG[@]}"; do
        restore_config "$config"
    done
}

# Main function
main() {
    print_script_info
    CLUSTER=$(get_cluster_name)

    echo -e "${BOLD}${CYAN}Cluster Name:${NC} ${GREEN}$CLUSTER${NC}"
    echo
    echo -e "${BOLD}${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}Select an option:${NC} ${BOLD}${YELLOW}                                │${NC}"
    echo -e "${BOLD}${YELLOW}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${GREEN}[1]${NC} 🔄 ${BOLD}Backup individual service configurations${BOLD}${YELLOW}   │${NC}"
    echo -e "${GREEN}[2]${NC} 🔄 ${BOLD}Restore individual service configurations${BOLD}${YELLOW}  │${NC}"
    echo -e "${BOLD}${YELLOW}└─────────────────────────────────────────────────┘${NC}"
    echo -ne "${BOLD}Enter your choice [1-2]:${NC} "
    read choice
    case "$choice" in
    "1")
        backup_service_configs
        ;;
    "2")
        restore_service_configs
        ;;
    *)
        print_error "Invalid option. Please enter either '1' or '2'."
        ;;
    esac
}

# Function to backup individual service configurations
backup_service_configs() {
    while true; do
        echo -e "${MAGENTA}${BOLD}┌──────────────────────────────────────────────┐${NC}"
        echo -e "${MAGENTA}${BOLD}│      ${CYAN}Backup Service Configurations${MAGENTA}${BOLD}           │${NC}"
        echo -e "${MAGENTA}${BOLD}└──────────────────────────────────────────────┘${NC}"
        echo -e "${GREEN}1) ${BOLD}🎨 Hue${NC}"
        echo -e "${GREEN}2) ${BOLD}🦌 Impala${NC}"
        echo -e "${GREEN}3) ${BOLD}☕ Kafka${NC}"
        echo -e "${GREEN}4) ${BOLD}🛡️ Ranger${NC}"
        echo -e "${GREEN}5) ${BOLD}🔑 Ranger KMS${NC}"
        echo -e "${GREEN}6) ${BOLD}⚡ Spark3${NC}"
        echo -e "${GREEN}7) ${BOLD}🎛️ NiFi${NC}"
        echo -e "${GREEN}8) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}9) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}10) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}11) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}12) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}13) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}14) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}15) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}16) ${BOLD}🔄 All (Backup configurations of all services like Hue, Impala, Kafka, Ranger, Ranger KMS, NiFi, Schema Registry, HTTPFS, Kudu, Jupyter, Flink, Druid, Airflow, Ozone)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-16, Q]:${NC} "
        read choice

        case "$choice" in
        1) backup_hue_configs ;;
        2) backup_impala_configs ;;
        3) backup_kafka_configs ;;
        4) backup_ranger_configs ;;
        5) backup_ranger_kms_configs ;;
        6) backup_spark3_configs ;;
        7) backup_nifi_configs ;;
        8) backup_schema_registry_configs ;;
        9) backup_httpfs_configs ;;
        10) backup_kudu_configs ;;
        11) backup_jupyter_configs ;;
        12) backup_flink_configs ;;
        13) backup_druid_configs ;;
        14) backup_airflow_configs ;;
        15) backup_ozone_configs ;;
        16) backup_all_configs ;;
        [Qq]) break ;;
        *) print_error "Invalid option. Please select a valid service." ;;
        esac
    done
}

# Function to backup configurations for all services
backup_all_configs() {
    backup_hue_configs
    backup_impala_configs
    backup_kafka_configs
    backup_ranger_configs
    backup_ranger_kms_configs
    backup_spark3_configs
    backup_nifi_configs
    backup_schema_registry_configs
    backup_httpfs_configs
    backup_kudu_configs
    backup_jupyter_configs
    backup_flink_configs
    backup_druid_configs
    backup_airflow_configs
    backup_ozone_configs
    # Add any other services you want to backup here
    print_success "Backup of all configurations completed successfully."

}

# Function to restore individual service configurations
restore_service_configs() {
    while true; do
        echo -e "${MAGENTA}${BOLD}┌──────────────────────────────────────────────┐${NC}"
        echo -e "${MAGENTA}${BOLD}│      ${CYAN}Restore Service Configurations${MAGENTA}${BOLD}         │${NC}"
        echo -e "${MAGENTA}${BOLD}└──────────────────────────────────────────────┘${NC}"
        echo -e "${GREEN}1) ${BOLD}🎨 Hue${NC}"
        echo -e "${GREEN}2) ${BOLD}🦌 Impala${NC}"
        echo -e "${GREEN}3) ${BOLD}☕ Kafka${NC}"
        echo -e "${GREEN}4) ${BOLD}🛡️ Ranger${NC}"
        echo -e "${GREEN}5) ${BOLD}🔑 Ranger KMS${NC}"
        echo -e "${GREEN}6) ${BOLD}⚡ Spark3${NC}"
        echo -e "${GREEN}7) ${BOLD}🎛️ NiFi${NC}"
        echo -e "${GREEN}8) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}9) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}10) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}11) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}12) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}13) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}14) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}15) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}16) ${BOLD}🔄 All (Restore configurations of all services like Hue, Impala, Kafka, Ranger, Ranger KMS, NiFi, Schema Registry, HTTPFS, Kudu, Jupyter, Flink, Druid, Airflow, Ozone)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-16, Q]:${NC} "
        read choice

        case "$choice" in
        1) restore_hue_configs ;;
        2) restore_impala_configs ;;
        3) restore_kafka_configs ;;
        4) restore_ranger_configs ;;
        5) restore_ranger_kms_configs ;;
        6) restore_spark3_configs ;;
        7) restore_nifi_configs ;;
        8) restore_schema_registry_configs ;;
        9) restore_httpfs_configs ;;
        10) restore_kudu_configs ;;
        11) restore_jupyter_configs ;;
        12) restore_flink_configs ;;
        13) restore_druid_configs ;;
        14) restore_airflow_configs ;;
        15) restore_ozone_configs ;;
        16) restore_all_configs ;;
        [Qq]) break ;;
        *) print_error "Invalid option. Please select a valid service." ;;
        esac
    done
}
# Function to restore configurations for all services
restore_all_configs() {
    restore_hue_configs
    restore_impala_configs
    restore_kafka_configs
    restore_ranger_configs
    restore_ranger_kms_configs
    restore_spark3_configs
    restore_nifi_configs
    restore_schema_registry_configs
    restore_httpfs_configs
    restore_kudu_configs
    restore_jupyter_configs
    restore_flink_configs
    restore_druid_configs
    restore_airflow_configs
    restore_ozone_configs
    print_success "Restore of all configurations completed successfully."
}

# Execute main function
main

#---------------------------------------------------------
# Post-Execution: Move Generated JSON Files (if any)
#---------------------------------------------------------
if ls doSet_version* 1> /dev/null 2>&1; then
    if [[ "$(pwd)" != "/tmp" ]]; then
        mv doSet_version* /tmp
        echo -e "${GREEN}JSON files moved to /tmp.${NC}"
    else
        echo -e "${YELLOW}Skipping move: script is already running in /tmp.${NC}"
    fi
else
    echo -e "${YELLOW}No JSON files found to move.${NC}"
fi
