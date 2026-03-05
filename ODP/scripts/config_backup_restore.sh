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

# Determine Python binary and version
PYTHON_BIN=python
PYTHON_VERSION=$($PYTHON_BIN --version 2>&1)
RESTORE_MODE="full"



# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

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

    # Note: On SSL failures, this script will automatically detect whether the Ambari server presents only its server certificate
    # or a full chain (including intermediate and root CAs). If only the server certificate is present, you will be prompted with
    # instructions to reconstruct and install the complete certificate chain. If a full chain is detected, you will be advised
    # to ensure that the CA certificates are trusted locally.
# Function to handle SSL verification failures by extracting and trusting CA
handle_ssl_failure() {
    local err_msg="$1"
    local cert_path="/tmp/ambari-ca-bundle.crt"

    # Extract certificates for validation
    echo | openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" 2>/dev/null \
        | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ print }' > "${cert_path}"
    if [[ -s "${cert_path}" ]]; then
        cert_count=$(grep -c "BEGIN CERTIFICATE" "${cert_path}")
    else
        cert_count=0
    fi

    echo ""
    echo -e "${RED}[ERROR] SSL certificate verification failed.${NC}"
    echo -e "${RED}Exception: ${err_msg}${NC}"
    echo ""
    echo -e "${CYAN}Detailed Explanation:${NC}"
    echo -e "The SSL handshake failed because the Ambari server's certificate is not in your local trust store."
    echo -e "This prevents secure HTTPS communication."
    echo ""

    if [[ "$cert_count" -le 1 ]]; then
        # Scenario 1: Only server certificate present
        echo -e "${CYAN}Additional Note:${NC}"
        echo -e "The Ambari server’s SSL configuration only includes its own certificate without intermediate or root CA."
        echo -e "You will need to reconstruct your server.pem file to include the full chain:"
        echo -e "  1. Append any Intermediate CA (if present) and the Root CA to your existing server.pem."
        echo -e "  2. Run: ambari-server setup-security"
        echo -e "     • Choose to disable HTTPS."
        echo -e "     • Supply the updated server.pem."
        echo -e "     • Re-enable HTTPS so that Ambari serves the complete certificate chain."
        echo ""
        exit 1
    else
        # Scenario 2: Full chain served but not trusted locally
        echo -e "${CYAN}Additional Note:${NC}"
        echo -e "The Ambari server is serving a certificate chain (found $cert_count certificates), but it may not be trusted locally."
        echo ""
        echo -e "${CYAN}If you answer 'yes', this script will:"
        echo -e "  • Extract the Ambari CA certificates and save them to ${cert_path}"
        echo -e "  • Copy the certificate bundle to /etc/pki/ca-trust/source/anchors/"
        echo -e "  • Run 'update-ca-trust extract' to add them to your system trust store"
        echo ""
        echo ""
        read -p "Do you want to extract and install the Ambari CA certificate now? (yes/no): " choice
        if [[ "${choice,,}" != "yes" ]]; then
            echo -e "${YELLOW}Aborting certificate installation. Please add the CA manually if needed.${NC}"
            exit 1
        fi
        echo "Attempting to extract the Ambari server's CA bundle..."
        echo | openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" 2>/dev/null \
            | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ print }' > "${cert_path}"
        if [[ -s "${cert_path}" ]]; then
            echo -e "${GREEN}✔ CA bundle saved to ${cert_path}.${NC}"
            echo "Installing to system trust store..."
            # Verify update-ca-trust is available
            if ! command -v update-ca-trust >/dev/null 2>&1; then
                print_error "'update-ca-trust' command not found. Please install the 'ca-certificates' package and rerun this script."
                exit 1
            fi
            sudo cp "${cert_path}" /etc/pki/ca-trust/source/anchors/
            sudo update-ca-trust extract
            echo ""
            echo -e "${YELLOW}Please rerun this script now that the CA is trusted.${NC}"
        else
            echo -e "${RED}[ERROR] Could not extract CA bundle. Please verify the Ambari server certificate manually.${NC}"
        fi
        exit 1
    fi
}

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

# Function to prompt restore strategy
prompt_restore_mode() {
    while true; do
        echo -e "${BOLD}${CYAN}┌────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${CYAN}│${NC} ${BOLD}Select restore strategy:${NC}                               ${BOLD}${CYAN}│${NC}"
        echo -e "${BOLD}${CYAN}├────────────────────────────────────────────────────────────┤${NC}"
        echo -e "${GREEN}[1]${NC} ${BOLD}Full restore${NC}  (current behavior, apply backup as-is)"
        echo -e "${GREEN}[2]${NC} ${BOLD}Delta restore${NC} (apply only values changed vs current)"
        echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────────────────┘${NC}"
        echo -ne "${BOLD}Enter your choice [1-2]:${NC} "
        read mode_choice
        case "$mode_choice" in
        1)
            RESTORE_MODE="full"
            print_success "Restore mode set to FULL."
            return 0
            ;;
        2)
            RESTORE_MODE="delta"
            print_success "Restore mode set to DELTA."
            return 0
            ;;
        *)
            print_error "Invalid option. Please enter either '1' or '2'."
            ;;
        esac
    done
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
    "hue-desktop-site"
    "hue-hadoop-site"
    "hue-hbase-site"
    "hue-hive-site"
    "hue-impala-site"
    "hue-log4j-env"
    "hue-notebook-site"
    "hue-oozie-site"
    "hue-pig-site"
    "hue-rdbms-site"
    "hue-solr-site"
    "hue-spark-site"
    "hue-ugsync-site"
    "hue-zookeeper-site"
    "hue.ini"
    "pseudo-distributed.ini"
    "services"
    "hue-env"
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

# NiFi Registry configuration array
NIFI_REGISTRY_CONFIG=(
    "ranger-nifi-registry-audit"
    "nifi-registry-ambari-config"
    "nifi-registry-bootstrap-env"
    "nifi-registry-providers-env"
    "nifi-registry-properties"
    "nifi-registry-identity-providers-env"
    "nifi-registry-authorizers-env"
    "ranger-nifi-registry-policymgr-ssl"
    "ranger-nifi-registry-plugin-properties"
    "nifi-registry-ambari-ssl-config"
    "nifi-registry-logback-env"
    "ranger-nifi-registry-security"
    "nifi-registry-env"
)

SCHEMA_REGISTRY_CONFIG=(
    "ranger-schema-registry-audit"
    "ranger-schema-registry-plugin-properties"
    "ranger-schema-registry-policymgr-ssl"
    "ranger-schema-registry-security"
    "registry-common"
    "registry-env"
    "registry-log4j"
    "registry-logsearch-conf"
    "registry-ssl-config"
    "registry-sso-config"
)

HTTPFS_CONFIG=(
    "httpfs-site"
    "httpfs-log4j"
    "httpfs-env"
    "httpfs"
)

KUDU_CONFIG=(
    "kudu-master-env"
    "kudu-master-stable-advanced"
    "kudu-tablet-env"
    "kudu-tablet-stable-advanced"
    "kudu-unstable"
    "ranger-kudu-plugin-properties"
    "ranger-kudu-policymgr-ssl"
    "ranger-kudu-security"
    "kudu-env"
    "ranger-kudu-audit"
)

JUPYTER_CONFIG=(
    "jupyterhub_config-py"
    "sparkmagic-conf"
    "jupyterhub-conf"
)

FLINK_CONFIG=(
    "flink-env"
    "flink-log4j-console.properties"
    "flink-log4j-historyserver"
    "flink-logback-rest"
    "flink-conf"
    "flink-log4j"
)

DRUID_CONFIG=(
    "druid-historical"
    "druid-logrotate"
    "druid-overlord"
    "druid-router"
    "druid-log4j"
    "druid-middlemanager"
    "druid-env"
    "druid-broker"
    "druid-common"
    "druid-coordinator"
)

AIRFLOW_CONFIG=(
    "airflow-admin-site"
    "airflow-api-site"
    "airflow-atlas-site"
    "airflow-celery-site"
    "airflow-cli-site"
    "airflow-core-site"
    "airflow-dask-site"
    "airflow-database-site"
    "airflow-elasticsearch-site"
    "airflow-email-site"
    "airflow-env"
    "airflow-githubenterprise-site"
    "airflow-hive-site"
    "airflow-kubernetes-site"
    "airflow-kubernetes_executor-site"
    "airflow-kubernetessecrets-site"
    "airflow-ldap-site"
    "airflow-lineage-site"
    "airflow-logging-site"
    "airflow-mesos-site"
    "airflow-metrics-site"
    "airflow-openlineage-site"
    "airflow-operators-site"
    "airflow-scheduler-site"
    "airflow-smtp-site"
    "airflow-kerberos-site"
    "airflow-webserver-site"
)

OZONE_CONFIG=(
    "ozone-log4j-datanode"
    "ozone-log4j-om"
    "ozone-log4j-properties"
    "ozone-log4j-recon"
    "ozone-log4j-s3g"
    "ozone-log4j-scm"
    "ozone-ssl-client"
    "ranger-ozone-plugin-properties"
    "ranger-ozone-policymgr-ssl"
    "ranger-ozone-security"
    "ssl-client-datanode"
    "ssl-client-om"
    "ssl-client-recon"
    "ssl-client-s3g"
    "ssl-client-scm"
    "ssl-server-datanode"
    "ssl-server-om"
    "ssl-server-recon"
    "ssl-server-s3g"
    "ssl-server-scm"
    "ozone-core-site"
    "ranger-ozone-audit"
    "ozone-env"
    "ozone-site"
)

# Pinot configuration array
PINOT_CONFIG=(
    "pinot-tools-log4j2"
    "pinot-server-conf"
    "pinot-service-log4j2"
    "pinot-env"
    "pinot-broker-conf"
    "pinot-broker-log4j2"
    "pinot-controller-conf"
    "pinot-server-log4j2"
    "pinot-minion-conf"
    "pinot-admin-log4j2"
    "pinot-minion-log4j2"
    "pinot-controller-log4j2"
    "pinot-ingestion-job-log4j2"
    "quickstart-log4j2"
    "log4j2"
)

# MLflow configuration array
MLFLOW_CONFIG=(
    "mlflow-conf"
)

# ClickHouse configuration array
CLICKHOUSE_CONFIGS=(
    "clickhouse-application"
    "clickhouse-client-config"
    "clickhouse-enable-keeper"
    "clickhouse-env"
    "clickhouse-keeper-config"
    "clickhouse-macros"
    "clickhouse-network-and-logging"
    "clickhouse-remote-servers"
    "clickhouse-server-config"
    "clickhouse-use-keeper"
    "clickhouse-users"
)

# Kafka3 configuration array
KAFKA3_CONFIGS=(
    "kafka3-env"
    "kafka3-log4j"
    "ranger-kafka3-policymgr-ssl"
    "kafka3-mirrormaker2-destination"
    "ranger-kafka3-audit"
    "kafka3-mirrormaker2-common"
    "kafka3-broker"
    "kafka3-connect-distributed"
    "kafka3_client_jaas_conf"
    "ranger-kafka3-plugin-properties"
    "ranger-kafka3-security"
    "kafka3_jaas_conf"
    "kafka3-mirrormaker2-source"
    "cruise-control3"
    "cruise-control3-log4j"
    "cruise-control3-capacityJBOD"
    "cruise-control3-ui-config"
    "cruise-control3-env"
    "cruise-control3-jaas-conf"
    "cruise-control3-capacity"
    "cruise-control3-clusterConfigs"
    "cruise-control3-capacityCores"
    "kraft-controller-env"
    "kraft-broker-env"
    "kraft-config"
    "kraft-broker"
    "kraft-broker-controller"
    "kraft-controller"
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
    # Run backup, capture SSL errors
    local err
    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" 2>&1 1>/dev/null) || {
        # Check for Python 3 print syntax error
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please modify the PYTHON_BIN variable at the top of this script to 'python2' so configs.py runs under Python 2."
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            handle_ssl_failure "$err"
        fi
        print_error "Failed to backup $config: $err"
        return 1
    }
    print_success "Backup of $config completed successfully."
}

# Function to restore configuration
restore_config() {
    local config="$1"
    if [[ "${RESTORE_MODE:-full}" == "delta" ]]; then
        restore_config_delta "$config"
        return $?
    fi
    local backup_dir="upgrade_backup/$config"
    print_warning "Restoring configuration: $config"
    local ssl_flag=""
    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi
    # Run restore, capture SSL errors
    local err
    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" 2>&1 1>/dev/null) || {
        # Check for Python 3 print syntax error
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please modify the PYTHON_BIN variable at the top of this script to 'python2' so configs.py runs under Python 2."
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            handle_ssl_failure "$err"
        fi
        print_error "Failed to restore $config: $err"
        return 1
    }
    print_success "Restore of $config completed successfully."
}

# Function to restore only delta changes from backup
restore_config_delta() {
    local config="$1"
    local backup_dir="upgrade_backup/$config"
    local backup_file="$backup_dir/$config.json"
    local current_file="/tmp/current_${config//[^A-Za-z0-9._-]/_}.json"
    local merged_file="/tmp/merged_${config//[^A-Za-z0-9._-]/_}.json"
    local delta_summary="/tmp/delta_${config//[^A-Za-z0-9._-]/_}.txt"
    local ssl_flag=""

    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi

    if [[ ! -f "$backup_file" ]]; then
        print_error "Backup file not found for $config: $backup_file"
        return 1
    fi

    print_warning "Preparing delta restore for configuration: $config"

    # Pull current config from Ambari for comparison
    local err
    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$current_file" 2>&1 1>/dev/null) || {
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please modify the PYTHON_BIN variable at the top of this script to 'python2' so configs.py runs under Python 2."
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            handle_ssl_failure "$err"
        fi
        print_error "Failed to fetch current config for $config: $err"
        return 1
    }

    # Compare backup vs current and build merged payload with only changed backup keys applied
    $PYTHON_BIN - "$backup_file" "$current_file" "$merged_file" "$delta_summary" <<'PY'
import json
import sys

backup_path, current_path, merged_path, summary_path = sys.argv[1:5]

def find_properties(node):
    if isinstance(node, dict):
        if isinstance(node.get("properties"), dict):
            return node["properties"], node, "properties"
        for value in node.values():
            props, parent, key = find_properties(value)
            if props is not None:
                return props, parent, key
    elif isinstance(node, list):
        for item in node:
            props, parent, key = find_properties(item)
            if props is not None:
                return props, parent, key
    return None, None, None

with open(backup_path) as bf:
    backup_data = json.load(bf)
with open(current_path) as cf:
    current_data = json.load(cf)

backup_props, _, _ = find_properties(backup_data)
current_props, current_parent, current_key = find_properties(current_data)

if backup_props is None or current_props is None or current_parent is None:
    sys.exit(3)

merged_props = dict(current_props)
changed_keys = []
new_keys = []

for key, value in backup_props.items():
    if key not in current_props:
        merged_props[key] = value
        changed_keys.append(key)
        new_keys.append(key)
    elif current_props[key] != value:
        merged_props[key] = value
        changed_keys.append(key)

if not changed_keys:
    sys.exit(2)

current_parent[current_key] = merged_props
with open(merged_path, "w") as mf:
    json.dump(current_data, mf, indent=2, sort_keys=True)

with open(summary_path, "w") as sf:
    sf.write("Changed keys count: {0}\n".format(len(changed_keys)))
    for key in changed_keys:
        suffix = " (new key)" if key in new_keys else ""
        sf.write("- {0}{1}\n".format(key, suffix))
PY
    local delta_status=$?

    case "$delta_status" in
    0)
        ;;
    2)
        print_warning "No differences found for $config. Skipping restore."
        rm -f "$current_file" "$merged_file" "$delta_summary"
        return 0
        ;;
    3)
        print_error "Could not parse properties from backup/current JSON for $config."
        rm -f "$current_file" "$merged_file" "$delta_summary"
        return 1
        ;;
    *)
        print_error "Failed to compute delta for $config."
        rm -f "$current_file" "$merged_file" "$delta_summary"
        return 1
        ;;
    esac

    print_warning "Applying delta changes for $config"
    if [[ -f "$delta_summary" ]]; then
        while IFS= read -r summary_line; do
            echo -e "${CYAN}${summary_line}${NC}"
        done < "$delta_summary"
    fi

    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" -p "$PASSWORD" $ssl_flag -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$merged_file" 2>&1 1>/dev/null) || {
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please modify the PYTHON_BIN variable at the top of this script to 'python2' so configs.py runs under Python 2."
            rm -f "$current_file" "$merged_file" "$delta_summary"
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            rm -f "$current_file" "$merged_file" "$delta_summary"
            handle_ssl_failure "$err"
        fi
        print_error "Failed to restore delta for $config: $err"
        rm -f "$current_file" "$merged_file" "$delta_summary"
        return 1
    }

    rm -f "$current_file" "$merged_file" "$delta_summary"
    print_success "Delta restore of $config completed successfully."
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

# Function to backup NiFi Registry configurations
backup_nifi_registry_configs() {
    for config in "${NIFI_REGISTRY_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to backup Schema Registry configurations
backup_schema_registry_configs() {
    for config in "${SCHEMA_REGISTRY_CONFIG[@]}"; do
        backup_config "$config"
    done
}
# Function to restore NiFi Registry configurations
restore_nifi_registry_configs() {
    for config in "${NIFI_REGISTRY_CONFIG[@]}"; do
        restore_config "$config"
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

# Function to backup Pinot configurations
backup_pinot_configs() {
    for config in "${PINOT_CONFIG[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Pinot configurations
restore_pinot_configs() {
    for config in "${PINOT_CONFIG[@]}"; do
        restore_config "$config"
    done
}

# Function to backup Kafka3 configurations
backup_kafka3_configs() {
    for config in "${KAFKA3_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore Kafka3 configurations
restore_kafka3_configs() {
    for config in "${KAFKA3_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup ClickHouse configurations
backup_clickhouse_configs() {
    for config in "${CLICKHOUSE_CONFIGS[@]}"; do
        backup_config "$config"
    done
}

# Function to restore ClickHouse configurations
restore_clickhouse_configs() {
    for config in "${CLICKHOUSE_CONFIGS[@]}"; do
        restore_config "$config"
    done
}

# Function to backup MLflow configurations
backup_mlflow_configs() {
    for config in "${MLFLOW_CONFIG[@]}"; do
        backup_config "$config"
    done
}

# Function to restore MLflow configurations
restore_mlflow_configs() {
    for config in "${MLFLOW_CONFIG[@]}"; do
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
        prompt_restore_mode
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
        echo -e "${GREEN}8) ${BOLD}🏷️ NiFi Registry${NC}"
        echo -e "${GREEN}9) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}10) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}11) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}12) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}13) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}14) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}15) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}16) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}17) ${BOLD}☕ Kafka3${NC}"
        echo -e "${GREEN}18) ${BOLD}🍷 Pinot${NC}"
        echo -e "${GREEN}19) ${BOLD}🏦 ClickHouse${NC}"
        echo -e "${GREEN}20) ${BOLD}🤖 MLflow${NC}"
        echo -e "${GREEN}21) ${BOLD}🔄 All (Backup configurations of all services)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-22, Q]:${NC} "
        read choice
        case "$choice" in
        1) backup_hue_configs ;;
        2) backup_impala_configs ;;
        3) backup_kafka_configs ;;
        4) backup_ranger_configs ;;
        5) backup_ranger_kms_configs ;;
        6) backup_spark3_configs ;;
        7) backup_nifi_configs ;;
        8) backup_nifi_registry_configs ;;
        9) backup_schema_registry_configs ;;
        10) backup_httpfs_configs ;;
        11) backup_kudu_configs ;;
        12) backup_jupyter_configs ;;
        13) backup_flink_configs ;;
        14) backup_druid_configs ;;
        15) backup_airflow_configs ;;
        16) backup_ozone_configs ;;
        17) backup_kafka3_configs ;;
        18) backup_pinot_configs ;;
        19) backup_clickhouse_configs ;;
        20) backup_mlflow_configs ;;
        21) backup_all_configs ;;
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
    backup_nifi_registry_configs
    backup_schema_registry_configs
    backup_httpfs_configs
    backup_kudu_configs
    backup_jupyter_configs
    backup_flink_configs
    backup_druid_configs
    backup_airflow_configs
    backup_ozone_configs
    backup_kafka3_configs
    backup_pinot_configs
    backup_clickhouse_configs
    backup_mlflow_configs
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
        echo -e "${GREEN}8) ${BOLD}🏷️ NiFi Registry${NC}"
        echo -e "${GREEN}9) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}10) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}11) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}12) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}13) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}14) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}15) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}16) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}17) ${BOLD}☕ Kafka3${NC}"
        echo -e "${GREEN}18) ${BOLD}🍷 Pinot${NC}"
        echo -e "${GREEN}19) ${BOLD}🏦 ClickHouse${NC}"
        echo -e "${GREEN}20) ${BOLD}🤖 MLflow${NC}"
        echo -e "${GREEN}21) ${BOLD}🔄 All (Restore configurations of all services)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-22, Q]:${NC} "
        read choice
        case "$choice" in
        1) restore_hue_configs ;;
        2) restore_impala_configs ;;
        3) restore_kafka_configs ;;
        4) restore_ranger_configs ;;
        5) restore_ranger_kms_configs ;;
        6) restore_spark3_configs ;;
        7) restore_nifi_configs ;;
        8) restore_nifi_registry_configs ;;
        9) restore_schema_registry_configs ;;
        10) restore_httpfs_configs ;;
        11) restore_kudu_configs ;;
        12) restore_jupyter_configs ;;
        13) restore_flink_configs ;;
        14) restore_druid_configs ;;
        15) restore_airflow_configs ;;
        16) restore_ozone_configs ;;
        17) restore_kafka3_configs ;;
        18) restore_pinot_configs ;;
        19) restore_clickhouse_configs ;;
        20) restore_mlflow_configs ;;
        21) restore_all_configs ;;
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
    restore_nifi_registry_configs
    restore_schema_registry_configs
    restore_httpfs_configs
    restore_kudu_configs
    restore_jupyter_configs
    restore_flink_configs
    restore_druid_configs
    restore_airflow_configs
    restore_ozone_configs
    restore_kafka3_configs
    restore_pinot_configs
    restore_clickhouse_configs
    restore_mlflow_configs
    print_success "Restore of all configurations completed successfully."
}

# Execute main function
main

#---------------------------------------------------------
# Post-Execution: Move Generated JSON Files (if any)
#---------------------------------------------------------
if ls doSet_version* 1> /dev/null 2>&1; then
    if [[ "$(pwd)" != "/tmp" ]]; then
        mv -f doSet_version* /tmp
        echo -e "${GREEN}JSON files moved to /tmp.${NC}"
    else
        echo -e "${YELLOW}Skipping move: script is already running in /tmp.${NC}"
    fi
else
    echo -e "${YELLOW}No JSON files found to move.${NC}"
fi
