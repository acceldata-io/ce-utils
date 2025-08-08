#!/usr/bin/env bash
#
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ © 2025 Acceldata Inc. All Rights Reserved.                                   │
# │                                                                              │
# │Main script to automate backup and restore of Ambari service configurations.  │
# │ Supports interactive and non-interactive (CLI) modes.                        │
# │ + Automated scheduled backups, retention, latest-successful restore          │
# └──────────────────────────────────────────────────────────────────────────────┘
set -o pipefail
#
# Define Ambari server connection and authentication parameters
# =========================
#  Ambari server settings
# =========================
export AMBARISERVER="${AMBARISERVER:-$(hostname -f)}"
export AMBARI_USER="${AMBARI_USER:-admin}"
export AMBARI_PASSWORD="${AMBARI_PASSWORD:-admin}"
export PORT="${PORT:-8080}"
export PROTOCOL="${PROTOCOL:-http}"

# Determine Python binary and version
PYTHON_BIN="${PYTHON_BIN:-python}"
PYTHON_VERSION="$($PYTHON_BIN --version 2>&1)"

# Define backup storage, log, and retention policy settings
# =========================
#  Automation settings
# =========================
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/ambari-configs}" # Where per-run, timestamped backups are stored
RETENTION_COUNT="${RETENTION_COUNT:-14}"                  # Keep last N runs (0=disabled)
RETENTION_DAYS="${RETENTION_DAYS:-0}"                     # And/or delete runs older than N days (0=disabled)
LOCKFILE="${LOCKFILE:-/tmp/ambari-config-backup.lock}"    # Cron lock
LOG_DIR="${LOG_DIR:-/var/log/ambari-config-backups}"      # Per-run logs
BACKUP_SUBDIR="${BACKUP_SUBDIR:-upgrade_backup}"
mkdir -p "$BACKUP_ROOT" "$LOG_DIR"

# Track failures during (auto) backup/restore
RUN_ERRORS=0

# Define terminal color codes for formatted output
# =========================
#  Colors & formatting
# =========================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

echo -e "${BOLD}${YELLOW}┌───────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}${CYAN}Ambari Configuration Backup & Restore Tool${NC} ${BOLD}${YELLOW}   │${NC}"
echo -e "${BOLD}${YELLOW}└───────────────────────────────────────────────┘${NC}"
echo -e "${GREEN}🔑  Settings to Verify:${NC}"
printf "   %-15s : %s\n" "AMBARISERVER" "$AMBARISERVER"
printf "   %-15s : %s\n" "USER" "$AMBARI_USER"
printf "   %-15s : ********\n" "PASSWORD"
printf "   %-15s : %s\n" "PORT" "$PORT"
printf "   %-15s : %s\n" "PROTOCOL" "$PROTOCOL"
printf "   %-15s : %s\n" "BACKUP_ROOT" "$BACKUP_ROOT"
printf "   %-15s : %s\n" "RETENTION_COUNT" "$RETENTION_COUNT"
printf "   %-15s : %s\n" "RETENTION_DAYS" "$RETENTION_DAYS"
echo ""

# Handles SSL certificate verification failures and guides user for resolution
# =========================
#  SSL failure helper
# =========================
handle_ssl_failure() {
    local err_msg="$1"
    local cert_path="/tmp/ambari-ca-bundle.crt"

    # Extract certificates for validation
    echo | openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" 2>/dev/null |
        awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ print }' >"${cert_path}"
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
        echo | openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" 2>/dev/null |
            awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/{ print }' >"${cert_path}"
        if [[ -s "${cert_path}" ]]; then
            echo -e "${GREEN}✔ CA bundle saved to ${cert_path}.${NC}"
            echo "Installing to system trust store..."
            if ! command -v update-ca-trust >/dev/null 2>&1; then
                print_error "'update-ca-trust' command not found. Please install the 'ca-certificates' package and rerun this script."
                exit 1
            fi
            cp "${cert_path}" /etc/pki/ca-trust/source/anchors/
            update-ca-trust extract
            echo ""
            echo -e "${YELLOW}Please rerun this script now that the CA is trusted.${NC}"
        else
            echo -e "${RED}[ERROR] Could not extract CA bundle. Please verify the Ambari server certificate manually.${NC}"
        fi
        exit 1
    fi
}

# Helper functions for formatted log messages
# =========================
#  Basic helpers
# =========================
print_success() { echo -e "${GREEN}$1${NC}"; }
print_warning() { echo -e "${YELLOW}$1${NC}"; }
print_error() { echo -e "${RED}$1${NC}"; }
timestamp() { date +"%Y%m%d_%H%M%S"; }

with_lock() {
    if (
        set -o noclobber
        echo "$$" >"$LOCKFILE"
    ) 2>/dev/null; then
        trap 'rm -f "$LOCKFILE"' EXIT
        return 0
    else
        echo "[WARN] Another run is active (lock: $LOCKFILE). Exiting."
        return 1
    fi
}

# Queries Ambari to get the cluster name
# =========================
#  Ambari helpers
# =========================
get_cluster_name() {
    local cluster
    cluster=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
    echo "$cluster"
}

# Displays script purpose and usage information
print_script_info() {
    echo -e "${BOLD}${CYAN}┌────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${CYAN}│  Ambari Configuration Backup & Restore Tool    │${NC}"
    echo -e "${BOLD}${CYAN}└────────────────────────────────────────────────┘${NC}"
    echo -e "${CYAN}This tool lets you backup and restore service configs in Ambari-managed clusters.${NC}"
    echo -e "${CYAN}Make sure all variables are set correctly before proceeding.${NC}"
    echo -e "${YELLOW}Usage: ./config_backup_restore.sh [--auto-backup | --restore-latest <service|all>]${NC}"
}

confirm_action() {
    local action="$1"
    read -p "Are you sure you want to $action? (yes/no): " choice
    case "$choice" in
    [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
    esac
}

# Configuration file lists per Ambari-managed service
# =========================
#  Service config arrays
# =========================
HUE_CONFIGS=("hue-auth-site" "hue-desktop-site" "hue-hadoop-site" "hue-hbase-site" "hue-hive-site" "hue-impala-site" "hue-log4j-env" "hue-notebook-site" "hue-oozie-site" "hue-pig-site" "hue-rdbms-site" "hue-solr-site" "hue-spark-site" "hue-ugsync-site" "hue-zookeeper-site" "hue.ini" "pseudo-distributed.ini" "services" "hue-env")
HDFS_CONFIGS=("core-site" "hadoop-env" "hadoop-metrics2.properties" "hadoop-policy" "hdfs-log4j" "hdfs-site" "ranger-hdfs-audit" "ranger-hdfs-plugin-properties" "ranger-hdfs-policymgr-ssl" "ranger-hdfs-security" "ssl-client" "ssl-server" "viewfs-mount-table")
IMPALA_CONFIGS=("fair-scheduler" "impala-log4j-properties" "llama-site" "impala-env")
KAFKA_CONFIGS=("kafka_client_jaas_conf" "kafka_jaas_conf" "ranger-kafka-policymgr-ssl" "ranger-kafka-security" "ranger-kafka-audit" "kafka-env" "ranger-kafka-plugin-properties" "kafka-broker")
RANGER_CONFIGS=("admin-properties" "atlas-tagsync-ssl" "ranger-solr-configuration" "ranger-tagsync-policymgr-ssl" "ranger-tagsync-site" "tagsync-application-properties" "ranger-ugsync-site" "ranger-env" "ranger-admin-site")
RANGER_KMS_CONFIGS=("kms-env" "kms-properties" "ranger-kms-policymgr-ssl" "ranger-kms-site" "ranger-kms-security" "dbks-site" "kms-site" "ranger-kms-audit")
SPARK3_CONFIGS=("livy3-client-conf" "livy3-env" "livy3-log4j-properties" "livy3-spark-blacklist" "spark3-env" "spark3-hive-site-override" "spark3-log4j-properties" "spark3-thrift-fairscheduler" "spark3-metrics-properties" "livy3-conf" "spark3-defaults" "spark3-thrift-sparkconf")
# SPARK2 configs
SPARK2_CONFIGS=("livy2-client-conf" "livy2-conf" "livy2-env" "livy2-log4j-properties" "livy2-spark-blacklist" "spark2-defaults" "spark2-env" "spark2-hive-site-override" "spark2-log4j-properties" "spark2-metrics-properties" "spark2-thrift-fairscheduler" "spark2-thrift-sparkconf")
KERBEROS_CONFIGS=("kerberos-env" "krb5-conf")
NIFI_CONFIGS=("nifi-ambari-config" "nifi-authorizers-env" "nifi-bootstrap-env" "nifi-bootstrap-notification-services-env" "nifi-env" "nifi-flow-env" "nifi-state-management-env" "ranger-nifi-policymgr-ssl" "ranger-nifi-security" "nifi-login-identity-providers-env" "nifi-properties" "ranger-nifi-plugin-properties" "nifi-ambari-ssl-config" "ranger-nifi-audit")
NIFI_REGISTRY_CONFIG=("ranger-nifi-registry-audit" "nifi-registry-ambari-config" "nifi-registry-bootstrap-env" "nifi-registry-providers-env" "nifi-registry-properties" "nifi-registry-identity-providers-env" "nifi-registry-authorizers-env" "ranger-nifi-registry-policymgr-ssl" "ranger-nifi-registry-plugin-properties" "nifi-registry-ambari-ssl-config" "nifi-registry-logback-env" "ranger-nifi-registry-security" "nifi-registry-env")
SCHEMA_REGISTRY_CONFIG=("ranger-schema-registry-audit" "ranger-schema-registry-plugin-properties" "ranger-schema-registry-policymgr-ssl" "ranger-schema-registry-security" "registry-common" "registry-env" "registry-log4j" "registry-logsearch-conf" "registry-ssl-config" "registry-sso-config")
HTTPFS_CONFIG=("httpfs-site" "httpfs-log4j" "httpfs-env" "httpfs")
KUDU_CONFIG=("kudu-master-env" "kudu-master-stable-advanced" "kudu-tablet-env" "kudu-tablet-stable-advanced" "kudu-unstable" "ranger-kudu-plugin-properties" "ranger-kudu-policymgr-ssl" "ranger-kudu-security" "kudu-env" "ranger-kudu-audit")
JUPYTER_CONFIG=("jupyterhub_config-py" "sparkmagic-conf" "jupyterhub-conf")
FLINK_CONFIG=("flink-env" "flink-log4j-console.properties" "flink-log4j-historyserver" "flink-logback-rest" "flink-conf" "flink-log4j")
DRUID_CONFIG=("druid-historical" "druid-logrotate" "druid-overlord" "druid-router" "druid-log4j" "druid-middlemanager" "druid-env" "druid-broker" "druid-common" "druid-coordinator")
AIRFLOW_CONFIG=("airflow-admin-site" "airflow-api-site" "airflow-atlas-site" "airflow-celery-site" "airflow-cli-site" "airflow-core-site" "airflow-dask-site" "airflow-database-site" "airflow-elasticsearch-site" "airflow-email-site" "airflow-env" "airflow-githubenterprise-site" "airflow-hive-site" "airflow-kubernetes-site" "airflow-kubernetes_executor-site" "airflow-kubernetessecrets-site" "airflow-ldap-site" "airflow-lineage-site" "airflow-logging-site" "airflow-mesos-site" "airflow-metrics-site" "airflow-openlineage-site" "airflow-operators-site" "airflow-scheduler-site" "airflow-smtp-site" "airflow-kerberos-site" "airflow-webserver-site")
OZONE_CONFIG=("ozone-log4j-datanode" "ozone-log4j-om" "ozone-log4j-properties" "ozone-log4j-recon" "ozone-log4j-s3g" "ozone-log4j-scm" "ozone-ssl-client" "ranger-ozone-plugin-properties" "ranger-ozone-policymgr-ssl" "ranger-ozone-security" "ssl-client-datanode" "ssl-client-om" "ssl-client-recon" "ssl-client-s3g" "ssl-client-scm" "ssl-server-datanode" "ssl-server-om" "ssl-server-recon" "ssl-server-s3g" "ssl-server-scm" "ozone-core-site" "ranger-ozone-audit" "ozone-env" "ozone-site")
PINOT_CONFIG=("pinot-tools-log4j2" "pinot-server-conf" "pinot-service-log4j2" "pinot-env" "pinot-broker-conf" "pinot-broker-log4j2" "pinot-controller-conf" "pinot-server-log4j2" "pinot-minion-conf" "pinot-admin-log4j2" "pinot-minion-log4j2" "pinot-controller-log4j2" "pinot-ingestion-job-log4j2" "quickstart-log4j2" "log4j2")
KAFKA3_CONFIGS=("kafka3-env" "kafka3-log4j" "ranger-kafka3-policymgr-ssl" "kafka3-mirrormaker2-destination" "ranger-kafka3-audit" "kafka3-mirrormaker2-common" "kafka3-broker" "kafka3-connect-distributed" "kafka3_client_jaas_conf" "ranger-kafka3-plugin-properties" "ranger-kafka3-security" "kafka3_jaas_conf" "kafka3-mirrormaker2-source" "cruise-control3" "cruise-control3-log4j" "cruise-control3-capacityJBOD" "cruise-control3-ui-config" "cruise-control3-env" "cruise-control3-jaas-conf" "cruise-control3-capacity" "cruise-control3-clusterConfigs" "cruise-control3-capacityCores" "kraft-controller-env" "kraft-broker-env" "kraft-config" "kraft-broker" "kraft-broker-controller" "kraft-controller")

# INFRA-SOLR configs
INFRA_SOLR_CONFIGS=("infra-solr-client-log4j" "infra-solr-env" "infra-solr-log4j" "infra-solr-security-json" "infra-solr-xml")

# KNOX configs
KNOX_CONFIGS=("admin-topology" "gateway-log4j" "gateway-site" "knox-env" "knoxsso-topology" "ldap-log4j" "ranger-knox-audit" "ranger-knox-plugin-properties" "ranger-knox-policymgr-ssl" "ranger-knox-security" "topology" "users-ldif")

# HIVE configs
HIVE_CONFIGS=("beeline-log4j2" "hive-atlas-application.properties" "hive-env" "hive-exec-log4j2" "hive-interactive-env" "hive-interactive-site" "hive-log4j2" "hive-site" "hivemetastore-site" "hiveserver2-interactive-site" "hiveserver2-site" "llap-cli-log4j2" "llap-daemon-log4j" "parquet-logging" "ranger-hive-audit" "ranger-hive-plugin-properties" "ranger-hive-policymgr-ssl" "ranger-hive-security" "tez-interactive-site")

# SQOOP configs
SQOOP_CONFIGS=("sqoop-atlas-application.properties" "sqoop-env")

# OOZIE configs
OOZIE_CONFIGS=("oozie-env" "oozie-log4j" "oozie-site")

# ZOOKEEPER configs
ZOOKEEPER_CONFIGS=("zoo.cfg" "zookeeper-env" "zookeeper-log4j")

# YARN configs
YARN_CONFIGS=("container-executor" "ranger-yarn-audit" "ranger-yarn-plugin-properties" "ranger-yarn-policymgr-ssl" "ranger-yarn-security" "yarn-env" "yarn-hbase-env" "yarn-hbase-log4j" "yarn-hbase-policy" "yarn-hbase-site" "yarn-log4j" "yarn-site")

# MR configs
MR_CONFIGS=("mapred-env" "mapred-site")

# TEZ configs
TEZ_CONFIGS=("tez-env" "tez-site")

# Backup and restore logic for individual configuration components
# =========================
#  Core backup/restore ops
# =========================
backup_config() {
    local config="$1"
    local backup_dir="$BACKUP_SUBDIR/$config"
    mkdir -p "$backup_dir"
    print_warning "Backing up configuration: $config"
    local ssl_flag=""
    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi
    local err
    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" $ssl_flag -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" 2>&1 1>/dev/null)
    local rc=$?
    if ((rc != 0)); then
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please set PYTHON_BIN=python2 so configs.py runs under Python 2."
            ((RUN_ERRORS++))
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            handle_ssl_failure "$err"
        fi
        # Detect skip (missing config)
        if echo "$err" | grep -iqE "not[ _-]?found|missing"; then
            print_warning "Config $config not found, skipping backup."
            return 2
        fi
        print_error "Failed to backup $config: $err"
        ((RUN_ERRORS++))
        return 1
    fi
    print_success "Backup of $config completed successfully."
    return 0
}

restore_config() {
    local config="$1"
    local backup_dir="$(latest_backup_run_dir)/$BACKUP_SUBDIR/$config"
    print_warning "Restoring configuration: $config"
    local ssl_flag=""
    if [ "$PROTOCOL" == "https" ]; then
        ssl_flag="-s https"
    fi
    local err
    err=$($PYTHON_BIN /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" $ssl_flag -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config" -f "$backup_dir/$config.json" 2>&1 1>/dev/null) || {
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            print_error "Detected Python version: $PYTHON_VERSION. Please set PYTHON_BIN=python2 so configs.py runs under Python 2."
            ((RUN_ERRORS++))
            return 1
        fi
        if [[ "$PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            handle_ssl_failure "$err"
        fi
        print_error "Failed to restore $config: $err"
        ((RUN_ERRORS++))
        return 1
    }
    print_success "Restore of $config completed successfully."
    return 0
}

# Wrapper to backup/restore all YARN service configs
# Per-service wrappers (collect per-config results and overall status)
backup_yarn_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${YARN_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all YARN service configs
restore_yarn_configs() {
    for config in "${YARN_CONFIGS[@]}"; do restore_config "$config"; done
}

# MR config backup/restore
# Wrapper to backup/restore all MR service configs
backup_mr_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${MR_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all MR service configs
restore_mr_configs() {
    for config in "${MR_CONFIGS[@]}"; do restore_config "$config"; done
}
# Wrapper to backup/restore all TEZ service configs
backup_tez_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${TEZ_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all TEZ service configs
restore_tez_configs() {
    for config in "${TEZ_CONFIGS[@]}"; do restore_config "$config"; done
}
# Wrapper to backup/restore all HIVE service configs
backup_hive_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${HIVE_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all HIVE service configs
restore_hive_configs() {
    for config in "${HIVE_CONFIGS[@]}"; do restore_config "$config"; done
}

# SQOOP config backup/restore
# Wrapper to backup/restore all SQOOP service configs
backup_sqoop_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${SQOOP_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all SQOOP service configs
restore_sqoop_configs() {
    for config in "${SQOOP_CONFIGS[@]}"; do restore_config "$config"; done
}

# OOZIE config backup/restore
# Wrapper to backup/restore all OOZIE service configs
backup_oozie_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${OOZIE_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all OOZIE service configs
restore_oozie_configs() {
    for config in "${OOZIE_CONFIGS[@]}"; do restore_config "$config"; done
}

# Wrapper to backup/restore all SPARK2 service configs
backup_spark2_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${SPARK2_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all SPARK2 service configs
restore_spark2_configs() {
    for config in "${SPARK2_CONFIGS[@]}"; do restore_config "$config"; done
}

# ZOOKEEPER config backup/restore
# Wrapper to backup/restore all ZOOKEEPER service configs
backup_zookeeper_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${ZOOKEEPER_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all ZOOKEEPER service configs
restore_zookeeper_configs() {
    for config in "${ZOOKEEPER_CONFIGS[@]}"; do restore_config "$config"; done
}
# Wrapper to backup/restore all INFRA_SOLR service configs
backup_infra_solr_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${INFRA_SOLR_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all INFRA_SOLR service configs
restore_infra_solr_configs() {
    for config in "${INFRA_SOLR_CONFIGS[@]}"; do restore_config "$config"; done
}

# KNOX config backup/restore
# Wrapper to backup/restore all KNOX service configs
backup_knox_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${KNOX_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all KNOX service configs
restore_knox_configs() {
    for config in "${KNOX_CONFIGS[@]}"; do restore_config "$config"; done
}

# KERBEROS config backup/restore
# Wrapper to backup/restore all KERBEROS service configs
backup_kerberos_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${KERBEROS_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all KERBEROS service configs
restore_kerberos_configs() {
    for config in "${KERBEROS_CONFIGS[@]}"; do restore_config "$config"; done
}
# Wrapper to backup/restore all HUE service configs
backup_hue_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${HUE_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all HUE service configs
restore_hue_configs() { for config in "${HUE_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all IMPALA service configs
backup_impala_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${IMPALA_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all IMPALA service configs
restore_impala_configs() { for config in "${IMPALA_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all KAFKA service configs
backup_kafka_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${KAFKA_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all KAFKA service configs
restore_kafka_configs() { for config in "${KAFKA_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all RANGER service configs
backup_ranger_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${RANGER_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all RANGER service configs
restore_ranger_configs() { for config in "${RANGER_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all RANGER_KMS service configs
backup_ranger_kms_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${RANGER_KMS_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all RANGER_KMS service configs
restore_ranger_kms_configs() { for config in "${RANGER_KMS_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all SPARK3 service configs
backup_spark3_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${SPARK3_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all SPARK3 service configs
restore_spark3_configs() { for config in "${SPARK3_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all NIFI service configs
backup_nifi_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${NIFI_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all NIFI service configs
restore_nifi_configs() { for config in "${NIFI_CONFIGS[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all NIFI_REGISTRY service configs
backup_nifi_registry_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${NIFI_REGISTRY_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all NIFI_REGISTRY service configs
restore_nifi_registry_configs() { for config in "${NIFI_REGISTRY_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all SCHEMA_REGISTRY service configs
backup_schema_registry_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${SCHEMA_REGISTRY_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all SCHEMA_REGISTRY service configs
restore_schema_registry_configs() { for config in "${SCHEMA_REGISTRY_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all HTTPFS service configs
backup_httpfs_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${HTTPFS_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all HTTPFS service configs
restore_httpfs_configs() { for config in "${HTTPFS_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all KUDU service configs
backup_kudu_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${KUDU_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all KUDU service configs
restore_kudu_configs() { for config in "${KUDU_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all JUPYTER service configs
backup_jupyter_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${JUPYTER_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all JUPYTER service configs
restore_jupyter_configs() { for config in "${JUPYTER_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all FLINK service configs
backup_flink_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${FLINK_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all FLINK service configs
restore_flink_configs() { for config in "${FLINK_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all DRUID service configs
backup_druid_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${DRUID_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all DRUID service configs
restore_druid_configs() { for config in "${DRUID_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all AIRFLOW service configs
backup_airflow_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${AIRFLOW_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all AIRFLOW service configs
restore_airflow_configs() { for config in "${AIRFLOW_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all OZONE service configs
backup_ozone_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${OZONE_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all OZONE service configs
restore_ozone_configs() { for config in "${OZONE_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all PINOT service configs
backup_pinot_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${PINOT_CONFIG[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all PINOT service configs
restore_pinot_configs() { for config in "${PINOT_CONFIG[@]}"; do restore_config "$config"; done; }
# Wrapper to backup/restore all KAFKA3 service configs
backup_kafka3_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${KAFKA3_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all KAFKA3 service configs
restore_kafka3_configs() { for config in "${KAFKA3_CONFIGS[@]}"; do restore_config "$config"; done; }

# HDFS config backup/restore
# Wrapper to backup/restore all HDFS service configs
backup_hdfs_configs() {
    local rc=0 skipped=0 fail=0
    for config in "${HDFS_CONFIGS[@]}"; do
        backup_config "$config"
        case $? in
        0) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}
# Wrapper to backup/restore all HDFS service configs
restore_hdfs_configs() {
    for config in "${HDFS_CONFIGS[@]}"; do restore_config "$config"; done
}

# Print summary of backup results (success, partial, failed)
print_backup_summary() {
    local -n ok_ref=$1
    local -n partial_ref=$2
    local -n fail_ref=$3
    echo -e "${BOLD}${CYAN}Backup Summary:${NC}"
    if ((${#ok_ref[@]} > 0)); then
        echo -e "${GREEN}✔ Success:${NC}   ${ok_ref[*]}"
    fi
    if ((${#partial_ref[@]} > 0)); then
        echo -e "${YELLOW}⚠ Partial (some configs missing):${NC} ${partial_ref[*]}"
    fi
    if ((${#fail_ref[@]} > 0)); then
        echo -e "${RED}✗ Failed:${NC}    ${fail_ref[*]}"
    fi
}

# Run backup/restore for all services by calling their respective functions
backup_all_configs() {
    local services=(hue impala kafka ranger ranger_kms spark3 spark2 nifi nifi_registry schema_registry httpfs kudu jupyter flink druid airflow ozone kafka3 pinot mr tez hive sqoop oozie zookeeper infra_solr knox kerberos yarn hdfs)
    local ok=() partial=() fail=()
    local rc
    for svc in "${services[@]}"; do
        local func="backup_${svc}_configs"
        $func
        rc=$?
        case $rc in
        0) ok+=("$svc") ;;
        2) partial+=("$svc") ;;
        *) fail+=("$svc") ;;
        esac
    done
    print_backup_summary ok partial fail
    if ((${#fail[@]} == 0)); then
        print_success "Backup of all configurations completed successfully."
        return 0
    else
        print_error "Backup completed with errors. See above summary."
        return 1
    fi
}

# Run backup/restore for all services by calling their respective functions
restore_all_configs() {
    restore_hue_configs
    restore_impala_configs
    restore_kafka_configs
    restore_ranger_configs
    restore_ranger_kms_configs
    restore_spark3_configs
    restore_spark2_configs
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
    restore_mr_configs
    restore_tez_configs
    restore_hive_configs
    restore_sqoop_configs
    restore_oozie_configs
    restore_zookeeper_configs
    restore_infra_solr_configs
    restore_knox_configs
    restore_kerberos_configs
    restore_yarn_configs
    restore_hdfs_configs
    if ((RUN_ERRORS == 0)); then
        print_success "Restore of all configurations completed successfully."
        return 0
    else
        print_error "Restore completed with $RUN_ERRORS error(s)."
        return 1
    fi
}

# Prunes old backups based on count and age retention policies
# =========================
#  Automation orchestration
# =========================
prune_backups() {
    local old
    mapfile -t all_runs < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -printf "%f\n" | sort -r)
    local total="${#all_runs[@]}"

    # Count-based retention
    if ((RETENTION_COUNT > 0)) && ((total > RETENTION_COUNT)); then
        for old in "${all_runs[@]:RETENTION_COUNT}"; do
            rm -rf "$BACKUP_ROOT/$old"
            echo "[INFO] Pruned old run (count): $old"
        done
    fi

    # Age-based retention
    if ((RETENTION_DAYS > 0)); then
        find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -mtime "+$RETENTION_DAYS" -print0 | xargs -0r rm -rf
    fi
}

# Finds the latest successful backup directory for a given service (or all)
latest_backup_run_dir() {
    local service="$1"
    local d
    while IFS= read -r d; do
        [[ -f "$d/SUCCESS" ]] || continue
        if [[ -z "$service" ]]; then
            echo "$d"
            return 0
        fi
        # Check if any of the configs for this service exist inside $BACKUP_SUBDIR/
        local found=0
        # Map service name to config array
        local -n service_configs="${service^^}_CONFIGS" # upper-case service name + _CONFIGS
        for cfg in "${service_configs[@]}"; do
            if [[ -f "$d/$BACKUP_SUBDIR/$cfg/$cfg.json" ]]; then
                found=1
                break
            fi
        done
        if ((found == 1)); then
            echo "$d"
            return 0
        fi
    done < <(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "20*" -printf "%T@ %p\n" | sort -nr | awk '{print $2}')
    return 1
}

# Executes a full automated backup run with logging and temp folder safety
auto_backup_all() {
    with_lock || return 0
    RUN_ERRORS=0

    local run_ts run_dir tmp_dir log
    run_ts="$(timestamp)"
    run_dir="$BACKUP_ROOT/$run_ts"
    tmp_dir="${run_dir}.tmp"
    log="$LOG_DIR/backup_${run_ts}.log"

    echo "[INFO] Starting automated backup at $run_ts -> $run_dir"
    mkdir -p "$tmp_dir/$BACKUP_SUBDIR"

    # Run backups in temp dir to avoid partials showing as latest
    pushd "$tmp_dir" >/dev/null

    if backup_all_configs >>"$log" 2>&1; then
        echo "[INFO] All services backed up OK." | tee -a "$log"
    else
        echo "[ERROR] Some backups failed ($RUN_ERRORS error(s)). See $log"
        popd >/dev/null
        rm -rf "$tmp_dir"
        return 1
    fi
    popd >/dev/null

    # Success marker + metadata
    echo "ok" >"$tmp_dir/SUCCESS"
    {
        echo "timestamp=$run_ts"
        echo "cluster=$CLUSTER"
        echo "server=$AMBARISERVER"
    } >"$tmp_dir/METADATA"

    # Publish atomically
    mv "$tmp_dir" "$run_dir"
    echo "[INFO] Published backup to $run_dir" | tee -a "$log"

    prune_backups
    echo "[INFO] Done. Latest: $run_dir"
}

# Restore configurations from a given backup directory
restore_all_from_dir() {
    local base="$1"
    (cd "$base" && RUN_ERRORS=0 && restore_all_configs)
}

# Restore configurations from a given backup directory
restore_one_from_dir() {
    local service="$1" base="$2"
    (
        cd "$base"
        case "$service" in
        HUE | hue) restore_hue_configs ;;
        IMPALA | impala) restore_impala_configs ;;
        KAFKA | kafka) restore_kafka_configs ;;
        RANGER | ranger) restore_ranger_configs ;;
        RANGER_KMS | ranger_kms | ranger-kms) restore_ranger_kms_configs ;;
        SPARK3 | spark3) restore_spark3_configs ;;
        SPARK2 | spark2) restore_spark2_configs ;;
        NIFI | nifi) restore_nifi_configs ;;
        NIFI_REGISTRY | nifi_registry | nifi-registry) restore_nifi_registry_configs ;;
        SCHEMA_REGISTRY | schema_registry | schema-registry) restore_schema_registry_configs ;;
        HTTPFS | httpfs) restore_httpfs_configs ;;
        KUDU | kudu) restore_kudu_configs ;;
        JUPYTER | jupyter) restore_jupyter_configs ;;
        FLINK | flink) restore_flink_configs ;;
        DRUID | druid) restore_druid_configs ;;
        AIRFLOW | airflow) restore_airflow_configs ;;
        OZONE | ozone) restore_ozone_configs ;;
        KAFKA3 | kafka3) restore_kafka3_configs ;;
        PINOT | pinot) restore_pinot_configs ;;
        MR | mr) restore_mr_configs ;;
        TEZ | tez) restore_tez_configs ;;
        HIVE | hive) restore_hive_configs ;;
        SQOOP | sqoop) restore_sqoop_configs ;;
        OOZIE | oozie) restore_oozie_configs ;;
        ZOOKEEPER | zookeeper) restore_zookeeper_configs ;;
        INFRA_SOLR | infra_solr | infra-solr) restore_infra_solr_configs ;;
        KNOX | knox) restore_knox_configs ;;
        KERBEROS | kerberos) restore_kerberos_configs ;;
        YARN | yarn) restore_yarn_configs ;;
        HDFS | hdfs) restore_hdfs_configs ;;
        *)
            echo "[ERROR] Unknown service: $service"
            return 1
            ;;
        esac
    )
}

# Restore from the latest successful backup for a specific service or all
restore_latest() {
    local what="$1" run_dir
    if [[ -z "$what" ]]; then
        echo "[ERROR] restore_latest needs a service name or 'all'"
        return 1
    fi
    if [[ "$what" == "all" ]]; then
        run_dir="$(latest_backup_run_dir)" || {
            echo "[ERROR] No successful backup found."
            return 1
        }
        echo "[INFO] Restoring ALL from: $run_dir"
        restore_all_from_dir "$run_dir/$BACKUP_SUBDIR"
    else
        run_dir="$(latest_backup_run_dir "$what")" || {
            echo "[ERROR] No successful backup found for service: $what"
            return 1
        }
        echo "[INFO] Restoring $what from: $run_dir"
        restore_one_from_dir "$what" "$run_dir/$BACKUP_SUBDIR"
    fi
}

# Interactive menu for backing up/restoring individual services
# =========================
#  Interactive menus
# =========================
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
        echo -e "${GREEN}7) ${BOLD}⚡ Spark2${NC}"
        echo -e "${GREEN}8) ${BOLD}🎛️ NiFi${NC}"
        echo -e "${GREEN}9) ${BOLD}🏷️ NiFi Registry${NC}"
        echo -e "${GREEN}10) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}11) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}12) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}13) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}14) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}15) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}16) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}17) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}18) ${BOLD}☕ Kafka3${NC}"
        echo -e "${GREEN}19) ${BOLD}🍷 Pinot${NC}"
        echo -e "${GREEN}20) ${BOLD}🐝 HIVE${NC}"
        echo -e "${GREEN}21) ${BOLD}🐘 SQOOP${NC}"
        echo -e "${GREEN}22) ${BOLD}🎩 OOZIE${NC}"
        echo -e "${GREEN}23) ${BOLD}🦫 ZOOKEEPER${NC}"
        echo -e "${GREEN}24) ${BOLD}🛰️ INFRA-SOLR${NC}"
        echo -e "${GREEN}25) ${BOLD}🔐 KNOX${NC}"
        echo -e "${GREEN}26) ${BOLD}🛡️ KERBEROS${NC}"
        echo -e "${GREEN}27) ${BOLD}🛠️ TEZ${NC}"
        echo -e "${GREEN}28) ${BOLD}🚀 MR${NC}"
        echo -e "${GREEN}29) ${BOLD}🧵 YARN${NC}"
        echo -e "${GREEN}30) ${BOLD}📁 HDFS${NC}"
        echo -e "${GREEN}31) ${BOLD}🔄 All (Backup all)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-31, Q]:${NC} "
        read choice

        case "$choice" in
        1) backup_hue_configs ;;
        2) backup_impala_configs ;;
        3) backup_kafka_configs ;;
        4) backup_ranger_configs ;;
        5) backup_ranger_kms_configs ;;
        6) backup_spark3_configs ;;
        7) backup_spark2_configs ;;
        8) backup_nifi_configs ;;
        9) backup_nifi_registry_configs ;;
        10) backup_schema_registry_configs ;;
        11) backup_httpfs_configs ;;
        12) backup_kudu_configs ;;
        13) backup_jupyter_configs ;;
        14) backup_flink_configs ;;
        15) backup_druid_configs ;;
        16) backup_airflow_configs ;;
        17) backup_ozone_configs ;;
        18) backup_kafka3_configs ;;
        19) backup_pinot_configs ;;
        20) backup_hive_configs ;;
        21) backup_sqoop_configs ;;
        22) backup_oozie_configs ;;
        23) backup_zookeeper_configs ;;
        24) backup_infra_solr_configs ;;
        25) backup_knox_configs ;;
        26) backup_kerberos_configs ;;
        27) backup_tez_configs ;;
        28) backup_mr_configs ;;
        29) backup_yarn_configs ;;
        30) backup_hdfs_configs ;;
        31) backup_all_configs ;;
        [Qq]) break ;;
        *) print_error "Invalid option. Please select a valid service." ;;
        esac
    done
}

# Interactive menu for backing up/restoring individual services
restore_service_configs() {
    while true; do
        echo -e "${MAGENTA}${BOLD}┌────────���─────────────────────────────────────┐${NC}"
        echo -e "${MAGENTA}${BOLD}│      ${CYAN}Restore Service Configurations${MAGENTA}${BOLD}         │${NC}"
        echo -e "${MAGENTA}${BOLD}└──────────────────────────────────────────────┘${NC}"
        echo -e "${GREEN}1) ${BOLD}🎨 Hue${NC}"
        echo -e "${GREEN}2) ${BOLD}🦌 Impala${NC}"
        echo -e "${GREEN}3) ${BOLD}☕ Kafka${NC}"
        echo -e "${GREEN}4) ${BOLD}🛡️ Ranger${NC}"
        echo -e "${GREEN}5) ${BOLD}🔑 Ranger KMS${NC}"
        echo -e "${GREEN}6) ${BOLD}⚡ Spark3${NC}"
        echo -e "${GREEN}7) ${BOLD}⚡ Spark2${NC}"
        echo -e "${GREEN}8) ${BOLD}🎛️ NiFi${NC}"
        echo -e "${GREEN}9) ${BOLD}🏷️ NiFi Registry${NC}"
        echo -e "${GREEN}10) ${BOLD}📜 Schema Registry${NC}"
        echo -e "${GREEN}11) ${BOLD}📂 HTTPFS${NC}"
        echo -e "${GREEN}12) ${BOLD}🐐 Kudu${NC}"
        echo -e "${GREEN}13) ${BOLD}📓 Jupyter${NC}"
        echo -e "${GREEN}14) ${BOLD}🦩 Flink${NC}"
        echo -e "${GREEN}15) ${BOLD}🧙 Druid${NC}"
        echo -e "${GREEN}16) ${BOLD}🌬️ Airflow${NC}"
        echo -e "${GREEN}17) ${BOLD}🌍 Ozone${NC}"
        echo -e "${GREEN}18) ${BOLD}☕ Kafka3${NC}"
        echo -e "${GREEN}19) ${BOLD}🍷 Pinot${NC}"
        echo -e "${GREEN}20) ${BOLD}🐝 HIVE${NC}"
        echo -e "${GREEN}21) ${BOLD}🐘 SQOOP${NC}"
        echo -e "${GREEN}22) ${BOLD}🎩 OOZIE${NC}"
        echo -e "${GREEN}23) ${BOLD}🦫 ZOOKEEPER${NC}"
        echo -e "${GREEN}24) ${BOLD}🛰️ INFRA-SOLR${NC}"
        echo -e "${GREEN}25) ${BOLD}🔐 KNOX${NC}"
        echo -e "${GREEN}26) ${BOLD}🛡️ KERBEROS${NC}"
        echo -e "${GREEN}27) ${BOLD}🛠️ TEZ${NC}"
        echo -e "${GREEN}28) ${BOLD}🚀 MR${NC}"
        echo -e "${GREEN}29) ${BOLD}🧵 YARN${NC}"
        echo -e "${GREEN}30) ${BOLD}📁 HDFS${NC}"
        echo -e "${GREEN}31) ${BOLD}🔄 All (Restore all)${NC}"
        echo -e "${RED}Q) ${BOLD}Quit${NC}"
        echo -ne "${BOLD}${YELLOW}Enter your choice [1-31, Q]:${NC} "
        read choice

        case "$choice" in
        1) restore_hue_configs ;;
        2) restore_impala_configs ;;
        3) restore_kafka_configs ;;
        4) restore_ranger_configs ;;
        5) restore_ranger_kms_configs ;;
        6) restore_spark3_configs ;;
        7) restore_spark2_configs ;;
        8) restore_nifi_configs ;;
        9) restore_nifi_registry_configs ;;
        10) restore_schema_registry_configs ;;
        11) restore_httpfs_configs ;;
        12) restore_kudu_configs ;;
        13) restore_jupyter_configs ;;
        14) restore_flink_configs ;;
        15) restore_druid_configs ;;
        16) restore_airflow_configs ;;
        17) restore_ozone_configs ;;
        18) restore_kafka3_configs ;;
        19) restore_pinot_configs ;;
        20) restore_hive_configs ;;
        21) restore_sqoop_configs ;;
        22) restore_oozie_configs ;;
        23) restore_zookeeper_configs ;;
        24) restore_infra_solr_configs ;;
        25) restore_knox_configs ;;
        26) restore_kerberos_configs ;;
        27) restore_tez_configs ;;
        28) restore_mr_configs ;;
        29) restore_yarn_configs ;;
        30) restore_hdfs_configs ;;
        31) restore_all_configs ;;
        [Qq]) break ;;
        *) print_error "Invalid option. Please select a valid service." ;;
        esac
    done
}

# CLI argument parsing for automation and non-interactive usage
# =========================
#  Non-interactive CLI
# =========================
#
# Usage:
#   --auto-backup                      run full backup to BACKUP_ROOT/<timestamp>
#   --restore-latest <service|all>     restore latest successful run
#   --restore-from [<path>] <service|all>   restore from provided or latest backup dir
if [[ "$1" == "--auto-backup" ]]; then
    CLUSTER="$(get_cluster_name)"
    auto_backup_all
    exit $?
elif [[ "$1" == "--restore-latest" ]]; then
    shift
    CLUSTER="$(get_cluster_name)"
    restore_latest "$1"
    exit $?
elif [[ "$1" == "--restore-from" ]]; then
    shift
    CLUSTER="$(get_cluster_name)"
    custom_path="$1"
    if [[ "$custom_path" == "all" || "$custom_path" == "" ]]; then
        what="all"
        run_dir="$(latest_backup_run_dir)" || {
            echo "[ERROR] No successful backup found."
            exit 1
        }
        echo "[INFO] Restoring ALL from: $run_dir"
        restore_all_from_dir "$run_dir/$BACKUP_SUBDIR"
        exit $?
    fi

    shift
    what="$1"
    if [[ -z "$what" ]]; then
        echo "[ERROR] Usage: --restore-from [<path>] <service|all>"
        exit 1
    fi

    if [[ "$what" == "all" ]]; then
        echo "[INFO] Restoring ALL from: $custom_path"
        restore_all_from_dir "$custom_path"
    else
        echo "[INFO] Restoring $what from: $custom_path"
        restore_one_from_dir "$what" "$custom_path"
    fi
    exit $?
elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
    print_script_info
    echo -e "${BOLD}${CYAN}Usage:${NC}"
    echo -e "  ${YELLOW}--auto-backup${NC}                      Run full backup to BACKUP_ROOT/<timestamp>"
    echo -e "  ${YELLOW}--restore-latest <service|all>${NC}     Restore latest successful backup"
    echo -e "  ${YELLOW}--restore-from <path> <service|all>${NC}  Restore from a specific backup directory"
    echo -e "  ${YELLOW}--help, -h${NC}                         Show this help message"
    exit 0
fi

# Entrypoint function for interactive mode
# =========================
#  Interactive entrypoint
# =========================
main() {
    print_script_info
    CLUSTER=$(get_cluster_name)

    echo -e "${BOLD}${CYAN}Cluster Name:${NC} ${GREEN}$CLUSTER${NC}"
    echo
    echo -e "${BOLD}${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}Select an option:${NC} ${BOLD}${YELLOW}                              │${NC}"
    echo -e "${BOLD}${YELLOW}├─────────────────────────────────────────────────┤${NC}"
    echo -e "${GREEN}[1]${NC} 🔄 ${BOLD}Backup individual service configurations${BOLD}${YELLOW}   │${NC}"
    echo -e "${GREEN}[2]${NC} 🔄 ${BOLD}Restore individual service configurations${BOLD}${YELLOW}  │${NC}"
    echo -e "${BOLD}${YELLOW}└─────────────────────────────────────────────────┘${NC}"
    echo -ne "${BOLD}Enter your choice [1-2]:${NC} "
    read choice
    case "$choice" in
    "1") backup_service_configs ;;
    "2") restore_service_configs ;;
    *) print_error "Invalid option. Please enter either '1' or '2'." ;;
    esac
}

main

#---------------------------------------------------------
# Post-Execution: Move Generated JSON Files (if any)
# (Kept from your original; harmless for interactive runs)
#---------------------------------------------------------
if ls doSet_version* 1>/dev/null 2>&1; then
    if [[ "$(pwd)" != "/tmp" ]]; then
        mv -f doSet_version* /tmp
        echo -e "${GREEN}JSON files moved to /tmp.${NC}"
    else
        echo -e "${YELLOW}Skipping move: script is already running in /tmp.${NC}"
    fi
else
    echo -e "${YELLOW}No JSON files found to move.${NC}"
fi
