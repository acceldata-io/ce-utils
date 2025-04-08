#!/bin/bash
# Acceldata Inc.

# Set Ambari server details
export AMBARISERVER=$(hostname -f)
export USER=admin
export PASSWORD=admin
export PORT=8080
export PROTOCOL=http

echo -e "🔑 Please ensure that you have set all variables correctly."
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🔒 ${GREEN}PASSWORD:${NC} ********"  # Replace with actual password above
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"

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

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
    echo -e "${GREEN}Ambari Configuration Backup and Restore Script${NC}"
    echo -e "This script enables you to backup and restore configurations for various services in Ambari-managed clusters."
    echo -e "Please ensure that you have set all necessary variables correctly before proceeding."
    echo -e "Usage: ./config_backup_restore.sh"
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
    "hue-env"
    "hue.ini"
)

IMPALA_CONFIGS=(
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

# Main function
main() {
    print_script_info
    CLUSTER=$(get_cluster_name)

    echo -e "${GREEN}Cluster Name:${NC} $CLUSTER"

    # Prompt user to select individual service backup or restore
    echo -e "Select an option:"
    echo -e "1. Backup individual service configurations"
    echo -e "2. Restore individual service configurations"
    read -p "Enter your choice: " choice

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
    echo -e "Select a service to backup configurations:"
    echo -e "1. Hue"
    echo -e "2. Impala"
    echo -e "3. Kafka"
    echo -e "4. Ranger"
    echo -e "5. Ranger KMS"
    echo -e "6. Spark3"    
    echo -e "7. NiFi"
    echo -e "8. All (Backup configurations of all services like Hue, Impala, Kafka, Ranger, Ranger KMS, NiFi)"    
    read -p "Enter your choice: " choice

    case "$choice" in
        "1")
            backup_hue_configs
            ;;
        "2")
            backup_impala_configs
            ;;
        "3")
            backup_kafka_configs
            ;;
        "4")
            backup_ranger_configs
            ;;
        "5")
            backup_ranger_kms_configs
            ;;
        "6")
            backup_spark3_configs
            ;;                
        "7")
            backup_nifi_configs
            ;;
        "8")
            backup_all_configs
            ;;
        *)            
            print_error "Invalid option. Please select a valid service."
            ;;
    esac
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
}

# Function to restore individual service configurations
restore_service_configs() {
    echo -e "Select a service to restore configurations:"
    echo -e "1. Hue"
    echo -e "2. Impala"
    echo -e "3. Kafka"
    echo -e "4. Ranger"
    echo -e "5. Ranger KMS"
    echo -e "6. Spark3"
    echo -e "7. NiFi"     
    echo -e "8. All (Restore configurations of all services like Hue, Impala, Kafka, Ranger, Ranger KMS, NiFi)"        
    read -p "Enter your choice: " choice

    case "$choice" in
        "1")
            restore_hue_configs
            ;;
        "2")
            restore_impala_configs
            ;;
        "3")
            restore_kafka_configs
            ;;
        "4")
            restore_ranger_configs
            ;;
        "5")
            restore_ranger_kms_configs
            ;;
        "6")
            restore_spark3_configs
            ;;            
        "7")
            restore_nifi_configs
            ;;
        "8")
            restore_all_configs
            ;;        
        *)
            print_error "Invalid option. Please select a valid service."
            ;;
    esac
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
}

# Execute main function
main
