#!/usr/bin/env bash
#
# ┌──────────────────────────────────────────────────────────────────────────────┐
# │ © 2025 Acceldata Inc. All Rights Reserved.                                   │
# │                                                                              │
# │Main script to automate backup and restore of Ambari service configurations.  │
# │ Supports interactive and non-interactive (CLI) modes.                        │
# │ + Config groups (host-specific overrides) are backed up and restored too     │
# │ Runs on RHEL/CentOS 7, 8 and 9 (bash 4.2 or later).                          │
# └──────────────────────────────────────────────────────────────────────────────┘
set -o pipefail

if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2))); then
    echo "[ERROR] This script needs bash 4.2 or later (found $BASH_VERSION)."
    exit 1
fi
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

# Determine Python binary and version. ambari-python-wrap picks the interpreter the
# Ambari scripts (configs.py) are written for; "python" does not exist on RHEL/CentOS 8 and 9.
if [[ -z "$PYTHON_BIN" ]]; then
    for candidate in ambari-python-wrap python3 python python2; do
        if command -v "$candidate" >/dev/null 2>&1; then
            PYTHON_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$PYTHON_BIN" ]] || ! command -v "${PYTHON_BIN%% *}" >/dev/null 2>&1; then
    echo "[ERROR] Python interpreter not found: ${PYTHON_BIN:-ambari-python-wrap, python3, python or python2}."
    echo "        Set PYTHON_BIN to the interpreter used by Ambari on this host."
    exit 1
fi
PYTHON_VERSION="$($PYTHON_BIN --version 2>&1)"

# Define backup storage settings
# =========================
#  Backup settings
# =========================
BACKUP_SUBDIR="${BACKUP_SUBDIR:-upgrade_backup}"          # Backups go to ./$BACKUP_SUBDIR
INCLUDE_CONFIG_GROUPS="${INCLUDE_CONFIG_GROUPS:-yes}"     # Also back up / restore Ambari config groups (yes/no)
CONFIG_GROUPS_DIR="_config_groups"                        # Under BACKUP_SUBDIR, one JSON file per config group

# Track failures during backup/restore
RUN_ERRORS=0

# Config types that exist in the cluster (filled by load_cluster_types)
TYPES_KNOWN=""
declare -A CLUSTER_TYPES=()

# Define terminal color codes for formatted output
# =========================
#  Colors & formatting
# =========================
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color
DIM='\033[2m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'

echo -e "${BOLD}${YELLOW}┌───────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}${CYAN}Ambari Configuration Backup & Restore Tool${NC} ${BOLD}${YELLOW}   │${NC}"
echo -e "${BOLD}${YELLOW}└───────────────────────────────────────────────┘${NC}"
echo -e "${GREEN}🔑  Settings to Verify:${NC}"
if [[ "$BACKUP_SUBDIR" == /* ]]; then
    BACKUP_DIR="$BACKUP_SUBDIR"
else
    BACKUP_DIR="$(pwd)/$BACKUP_SUBDIR"
fi
printf "   %-16s : %s\n" "AMBARISERVER" "$AMBARISERVER"
printf "   %-16s : %s\n" "AMBARI_USER" "$AMBARI_USER"
printf "   %-16s : ********\n" "AMBARI_PASSWORD"
printf "   %-16s : %s\n" "PORT" "$PORT"
printf "   %-16s : %s\n" "PROTOCOL" "$PROTOCOL"
printf "   %-16s : %s\n" "PYTHON_BIN" "$PYTHON_BIN ($PYTHON_VERSION)"
printf "   %-16s : %s\n" "Backup dir" "$BACKUP_DIR"
printf "   %-16s : %s\n" "CONFIG_GROUPS" "$INCLUDE_CONFIG_GROUPS"
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

# Queries Ambari to get the cluster name
# =========================
#  Ambari helpers
# =========================
get_cluster_name() {
    local cluster
    cluster=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
    echo "$cluster"
}

# Sets CLUSTER, or stops with one clear error when Ambari cannot be read
resolve_cluster() {
    CLUSTER=$(get_cluster_name)
    [[ -n "$CLUSTER" ]] && return 0
    local url="$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" code
    code=$(curl -s -k -o /dev/null -w '%{http_code}' -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' "$url")
    print_error "[ERROR] Could not read the cluster name from $url (HTTP $code)."
    case "$code" in
    000) print_error "Ambari is not reachable. Check AMBARISERVER, PORT and PROTOCOL." ;;
    401 | 403) print_error "Ambari rejected the login. Check AMBARI_USER and AMBARI_PASSWORD." ;;
    *) print_error "Check that a cluster exists on this Ambari server." ;;
    esac
    exit 1
}

# configs.py leaves a doSet_version*.json file in the current directory for every config it sets
move_doset_files() {
    if ls doSet_version* 1>/dev/null 2>&1 && [[ "$(pwd)" != "/tmp" ]]; then
        mv -f doSet_version* /tmp
        echo -e "${GREEN}Temporary doSet_version*.json files moved to /tmp.${NC}"
    fi
}

# Displays script purpose and usage information
print_script_info() {
    echo -e "${CYAN}This tool lets you backup and restore service configs in Ambari-managed clusters.${NC}"
    echo -e "${CYAN}Run it without arguments for the interactive menu.${NC}"
}

confirm_action() {
    local action="$1" answer
    read -r -p "Are you sure you want to $action? (yes/no): " answer
    case "$answer" in
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
SPARK4_CONFIGS=("livy4-client-conf" "livy4-conf" "livy4-env" "livy4-log4j-properties" "livy4-spark-blacklist" "spark4-connect" "spark4-defaults" "spark4-env" "spark4-hive-site-override" "spark4-log4j-properties" "spark4-metrics-properties" "spark4-thrift-fairscheduler" "spark4-thrift-sparkconf")
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
ATLAS_CONFIGS=("application-properties" "atlas-env" "atlas-log4j" "atlas-simple-authz-policy" "ranger-atlas-audit" "ranger-atlas-plugin-properties" "ranger-atlas-policymgr-ssl" "ranger-atlas-security" "users-credentials")
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
ZOOKEEPER_CONFIGS=("zoo.cfg" "zookeeper-env" "zookeeper-log4j" "zookeeper-logback")

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
    print_warning "Backing up configuration: $config"
    if [[ -n "$TYPES_KNOWN" && -z "${CLUSTER_TYPES[$config]}" ]]; then
        if [[ -f "$backup_dir/$config.json" ]]; then
            print_warning "Config $config is not in Ambari, skipping backup. An older backup of it is kept: $backup_dir/$config.json"
        else
            print_warning "Config $config not found, skipping backup."
        fi
        return 2
    fi
    mkdir -p "$backup_dir"
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
        # Config type exists but holds no properties (configs.py cannot read those)
        if echo "$err" | grep -qE "KeyError: u?'properties'"; then
            echo '{"properties": {}}' >"$backup_dir/$config.json"
            print_success "Backup of $config completed successfully (no properties set)."
            return 0
        fi
        # Detect skip (missing config); only used when the config type list could not be read
        if echo "$err" | grep -qF "not found in server response"; then
            print_warning "Config $config not found, skipping backup."
            rmdir "$backup_dir" 2>/dev/null
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
    local backup_dir
    backup_dir="$(restore_base_dir)/$config"
    if [[ ! -f "$backup_dir/$config.json" ]]; then
        print_warning "No backup of $config in $(restore_base_dir), skipping."
        return 2
    fi
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

# Directory a restore reads from (holds <type>/<type>.json and _config_groups/):
# the path given to --restore-from, else ./$BACKUP_SUBDIR
restore_base_dir() {
    echo "${RESTORE_BASE:-$BACKUP_SUBDIR}"
}

# restore_base_dir as an absolute path, for messages
restore_dir_shown() {
    local dir
    dir="$(restore_base_dir)"
    [[ "$dir" == /* ]] || dir="$(pwd)/$dir"
    echo "$dir"
}

# Config groups (host-specific overrides) backup and restore
# =========================
#  Config groups
# =========================
# configs.py only reads/writes the Default group, so config groups go through the
# REST API. Each group is saved as $BACKUP_SUBDIR/_config_groups/<TAG>__<group>.json:
#   {"ConfigGroup": {"group_name", "tag", "description", "hosts": [{"host_name"}],
#                    "desired_configs": [{"type", "tag", "properties", "properties_attributes"}]}}
# "tag" is the Ambari service name the group belongs to.

# Ambari service names that differ from the names used for the arrays in this script
declare -A CG_TAG_ALIASES=([MR]="MAPREDUCE2" [INFRA_SOLR]="AMBARI_INFRA_SOLR" [SCHEMA_REGISTRY]="REGISTRY" [JUPYTER]="JUPYTERHUB")

# JSON helper for config groups (runs under python 2 or 3)
IFS= read -r -d '' CG_PY <<'PY'
from __future__ import print_function
import hashlib, io, json, re, sys, time

def load(path):
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)

def dump(obj, path):
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True)

def out(text):
    if sys.version_info[0] == 2 and not isinstance(text, str):
        text = text.encode("utf-8")
    print(text)

def groups(doc):
    # Ambari list response, or a single group as written by the backup
    if "items" in doc:
        return [i["ConfigGroup"] for i in doc["items"]]
    return [doc["ConfigGroup"]]

def by_id(doc, gid):
    return [g for g in groups(doc) if str(g.get("id")) == gid][0]

def configs(g):
    return g.get("desired_configs") or []

def hosts(g):
    return sorted(h["host_name"] for h in g.get("hosts") or [])

def matches(g, tags, types):
    # no filter = every group; else the group's service tag or one of its config types must match
    if not tags and not types:
        return True
    if g.get("tag") in tags:
        return True
    return any(c.get("type") in types for c in configs(g))

def safe(name):
    # file-name-safe; a short hash keeps names that only differ in special characters apart
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    if cleaned != name:
        cleaned += "_" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:6]
    return cleaned

def comparable(g):
    return (g.get("group_name"), g.get("tag"), g.get("description") or "", hosts(g),
            sorted((c["type"], json.dumps(c.get("properties") or {}, sort_keys=True),
                    json.dumps(c.get("properties_attributes") or {}, sort_keys=True)) for c in configs(g)))

cmd, args = sys.argv[1], sys.argv[2:]

if cmd == "select":      # select <file> <tag,tag> [type ...]  -> id, backup file name, tag, group name
    tags = [t for t in args[1].split(",") if t]
    for g in groups(load(args[0])):
        if matches(g, tags, set(args[2:])):
            out("\t".join([str(g.get("id", "-")), "%s__%s.json" % (safe(g["tag"]), safe(g["group_name"])),
                           g["tag"], g["group_name"]]))

elif cmd == "types":     # types <list file> <id>  -> type, tag of every override
    for c in configs(by_id(load(args[0]), args[1])):
        out("%s\t%s" % (c["type"], c["tag"]))

elif cmd == "build":     # build <list file> <id> <dir with <type>.json> <out file>
    g = by_id(load(args[0]), args[1])
    cg = {"group_name": g["group_name"], "tag": g["tag"], "description": g.get("description") or "",
          "hosts": [{"host_name": h} for h in hosts(g)], "desired_configs": []}
    if g.get("service_name"):
        cg["service_name"] = g["service_name"]
    for c in configs(g):
        item = load("%s/%s.json" % (args[2], c["type"]))["items"][0]
        entry = {"type": c["type"], "tag": c["tag"], "properties": item.get("properties") or {}}
        if item.get("properties_attributes"):
            entry["properties_attributes"] = item["properties_attributes"]
        cg["desired_configs"].append(entry)
    dump({"ConfigGroup": cg}, args[3])

elif cmd == "find":      # find <list file> <backup file>  -> id of the live group with the same name and tag
    want = groups(load(args[1]))[0]
    for g in groups(load(args[0])):
        if g.get("group_name") == want["group_name"] and g.get("tag") == want["tag"]:
            out(str(g["id"]))
            break

elif cmd == "same":      # same <backup file> <backup file>  -> exit 0 when equal apart from config tags
    a, b = groups(load(args[0]))[0], groups(load(args[1]))[0]
    sys.exit(0 if comparable(a) == comparable(b) else 1)

elif cmd == "describe":  # describe <backup file>
    g = groups(load(args[0]))[0]
    out("%s (%s) | hosts: %s | overrides: %s" % (
        g["group_name"], g["tag"], ", ".join(hosts(g)) or "none",
        ", ".join("%s [%d]" % (c["type"], len(c.get("properties") or {})) for c in configs(g)) or "none"))

elif cmd == "filetypes": # filetypes <backup file>  -> config types the group overrides
    for c in configs(groups(load(args[0]))[0]):
        out(c["type"])

elif cmd == "desired":   # desired <cluster desired_configs response>  -> every config type in the cluster
    for t in sorted(load(args[0])["Clusters"]["desired_configs"]):
        out(t)

elif cmd == "payload":   # payload <backup file> <out file> <put|post>
    cg = groups(load(args[0]))[0]
    # Ambari reuses an existing (type, tag) as-is, so the overrides need a fresh tag to be stored
    for c in configs(cg):
        c["tag"] = "version%d" % int(time.time() * 1000)
    body = {"ConfigGroup": cg}
    dump([body] if args[2] == "post" else body, args[1])
PY

cg_py() { $PYTHON_BIN -c "$CG_PY" "$@"; }

# ambari_get <path under the cluster>  -- body on stdout, non-zero on HTTP errors
ambari_get() {
    curl -s -k -f -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
        "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/$1"
}

# ambari_send <PUT|POST> <path under the cluster> <json file>  -- prints the response body on failure
ambari_send() {
    local body code
    body="$(mktemp)"
    code=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' -X "$1" -d "@$3" \
        -o "$body" -w '%{http_code}' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/$2")
    if [[ "$code" == 2* ]]; then
        rm -f "$body"
        return 0
    fi
    echo "HTTP $code $(cat "$body")"
    rm -f "$body"
    return 1
}

# Sets CG_TAGS / CG_TYPES from a config array name (e.g. KAFKA_CONFIGS); no argument = all groups
set_cg_filter() {
    CG_TAGS=""
    CG_TYPES=()
    [[ -z "$1" ]] && return 0
    local cg_array="$1[@]"
    local svc="${1%_CONFIGS}"
    svc="${svc%_CONFIG}"
    CG_TAGS="$svc${CG_TAG_ALIASES[$svc]:+,${CG_TAG_ALIASES[$svc]}}"
    CG_TYPES=("${!cg_array}")
}

# fetch_config_group <list file> <group id> <out file>  -- live group with its override values
fetch_config_group() {
    local list_file="$1" id="$2" out="$3" tmp type tag rc=0
    tmp="$(mktemp -d)"
    while IFS=$'\t' read -r type tag; do
        ambari_get "configurations?type=$type&tag=$tag" >"$tmp/$type.json" || rc=1
    done < <(cg_py types "$list_file" "$id")
    if ((rc == 0)); then
        cg_py build "$list_file" "$id" "$tmp" "$out" || rc=1
    fi
    rm -rf "$tmp"
    return $rc
}

# backup_config_groups [CONFIG_ARRAY_NAME]  -- one service's groups, or every group in the cluster
backup_config_groups() {
    [[ "${INCLUDE_CONFIG_GROUPS,,}" == "no" ]] && return 0
    [[ -n "$CG_DEFER" && -n "$1" ]] && return 0 # the "All" run backs up every group once, at the end
    set_cg_filter "$1"
    CG_DONE=0
    local out_dir="$BACKUP_SUBDIR/$CONFIG_GROUPS_DIR"
    local list_file selected id fname tag name f rc=0
    local -A written=()
    list_file="$(mktemp)"
    if ! ambari_get "config_groups?fields=ConfigGroup/*" >"$list_file" ||
        ! selected="$(cg_py select "$list_file" "$CG_TAGS" "${CG_TYPES[@]}")"; then
        print_error "Failed to list config groups from Ambari."
        ((RUN_ERRORS++))
        rm -f "$list_file"
        return 1
    fi
    if [[ -z "$selected" && -z "$1" ]]; then
        print_warning "No config groups defined in this cluster."
    fi
    [[ -n "$selected" ]] && echo
    while IFS=$'\t' read -r id fname tag name; do
        [[ -n "$id" ]] || continue
        mkdir -p "$out_dir"
        print_warning "Backing up config group: $name ($tag)"
        written["$fname"]=1
        if fetch_config_group "$list_file" "$id" "$out_dir/$fname"; then
            print_success "Config group backed up: $(cg_py describe "$out_dir/$fname")"
            ((CG_DONE++))
            if grep -q '"SECRET:' "$out_dir/$fname"; then
                print_warning "Config group $name has password overrides saved as SECRET references; they only restore on this cluster."
            fi
        else
            print_error "Failed to backup config group $name ($tag)."
            ((RUN_ERRORS++))
            rc=1
        fi
    done <<<"$selected"
    rm -f "$list_file"
    # Drop backups of groups that were deleted in Ambari, so a restore does not bring them back.
    # Backups of a service that is no longer installed are kept: they are what a re-install needs.
    local t in_cluster
    for f in "$out_dir"/*.json; do
        [[ -f "$f" && -z "${written[$(basename "$f")]}" ]] || continue
        [[ -n "$(cg_py select "$f" "$CG_TAGS" "${CG_TYPES[@]}")" ]] || continue
        in_cluster=""
        while read -r t; do
            [[ -n "$t" && -n "${CLUSTER_TYPES[$t]}" ]] && in_cluster=1
        done < <(cg_py filetypes "$f")
        [[ -n "$TYPES_KNOWN" ]] || continue
        if [[ -n "$in_cluster" ]]; then
            rm -f "$f"
            print_warning "Removed stale config group backup (group no longer in Ambari): $f"
        else
            print_warning "Kept config group backup of a service that is not in Ambari: $f"
        fi
    done
    return $rc
}

# restore_config_groups [CONFIG_ARRAY_NAME]  -- updates groups that exist, recreates the ones that do not
restore_config_groups() {
    [[ "${INCLUDE_CONFIG_GROUPS,,}" == "no" ]] && return 0
    [[ -n "$CG_DEFER" && -n "$1" ]] && return 0 # the "All" run restores every group once, at the end
    set_cg_filter "$1"
    CG_DONE=0
    local dir f files=() list_file tmp id name err rc=0
    dir="$(restore_base_dir)/$CONFIG_GROUPS_DIR"
    for f in "$dir"/*.json; do
        [[ -f "$f" ]] || continue
        [[ -n "$(cg_py select "$f" "$CG_TAGS" "${CG_TYPES[@]}")" ]] && files+=("$f")
    done
    ((${#files[@]} > 0)) || return 0

    echo
    echo -e "${BOLD}${CYAN}Config groups in backup ($(restore_dir_shown)/$CONFIG_GROUPS_DIR):${NC}"
    for f in "${files[@]}"; do echo "   - $(cg_py describe "$f")"; done
    if [[ -n "$INTERACTIVE" ]] && ! confirm_action "restore the config group(s) listed above (hosts and overrides)"; then
        print_warning "Skipped config group restore."
        return 0
    fi
    echo

    tmp="$(mktemp -d)"
    list_file="$tmp/list.json"
    if ! ambari_get "config_groups?fields=ConfigGroup/*" >"$list_file"; then
        print_error "Failed to list config groups from Ambari."
        ((RUN_ERRORS++))
        rm -rf "$tmp"
        return 1
    fi
    for f in "${files[@]}"; do
        name="$(cg_py describe "$f")"
        name="${name%% | *}"
        print_warning "Restoring config group: $name"
        id="$(cg_py find "$list_file" "$f")"
        if [[ -n "$id" ]]; then
            if fetch_config_group "$list_file" "$id" "$tmp/live.json" && cg_py same "$f" "$tmp/live.json"; then
                print_success "Config group $name already matches the backup, nothing to do."
                ((CG_DONE++))
                continue
            fi
            cg_py payload "$f" "$tmp/payload.json" put && err=$(ambari_send PUT "config_groups/$id" "$tmp/payload.json")
        else
            cg_py payload "$f" "$tmp/payload.json" post && err=$(ambari_send POST "config_groups" "$tmp/payload.json")
        fi
        if (($? == 0)); then
            print_success "Restore of config group $name completed successfully ($([[ -n "$id" ]] && echo updated || echo created))."
            ((CG_DONE++))
        else
            print_error "Failed to restore config group $name: $err"
            ((RUN_ERRORS++))
            rc=1
        fi
    done
    rm -rf "$tmp"
    return $rc
}

# Per-service backup and restore
# =========================
#  Per-service operations
# =========================
# Resolves a service name (kafka, ranger-kms, NIFI_REGISTRY) to its config array name
service_array() {
    local name="${1^^}"
    name="${name//-/_}"
    if declare -p "${name}_CONFIGS" &>/dev/null; then
        echo "${name}_CONFIGS"
    elif declare -p "${name}_CONFIG" &>/dev/null; then
        echo "${name}_CONFIG"
    else
        return 1
    fi
}

# print_service_summary <Backup|Restore> <CONFIG_ARRAY_NAME> <counts text> <directory>
print_service_summary() {
    local svc="${2%_CONFIGS}" groups=""
    svc="${svc%_CONFIG}"
    [[ "${INCLUDE_CONFIG_GROUPS,,}" != "no" ]] && groups=" | $CG_DONE config group(s)"
    echo
    echo -e "${BOLD}${CYAN}$1 summary for $svc:${NC} $3$groups"
    local dir="$4"
    [[ "$dir" == /* ]] || dir="$(pwd)/$dir"
    echo -e "${BOLD}${CYAN}Backup directory:${NC} $dir"
}

# backup_service <CONFIG_ARRAY_NAME>  -- returns 0 = all saved, 2 = some config types not present, 1 = failures
backup_service() {
    local array_name="$1" config saved=0 skipped=0 fail=0
    local svc_configs="$1[@]"
    CG_DONE=0
    for config in "${!svc_configs}"; do
        backup_config "$config"
        case $? in
        0) ((saved++)) ;;
        2) ((skipped++)) ;;
        *) ((fail++)) ;;
        esac
    done
    backup_config_groups "$array_name" || ((fail++))
    if [[ -z "$CG_DEFER" ]]; then
        print_service_summary "Backup" "$array_name" "$saved config type(s) saved, $skipped not present, $fail failed" "$BACKUP_DIR"
    fi
    if ((fail > 0)); then
        return 1
    elif ((skipped > 0)); then
        return 2
    else
        return 0
    fi
}

# restore_service <CONFIG_ARRAY_NAME>  -- returns 0 = restored, 2 = nothing in the backup for it, 1 = failures
restore_service() {
    local array_name="$1" config restored=0 missing=0 fail=0
    local svc_configs="$1[@]"
    CG_DONE=0
    for config in "${!svc_configs}"; do
        restore_config "$config"
        case $? in
        0) ((restored++)) ;;
        2) ((missing++)) ;;
        *) ((fail++)) ;;
        esac
    done
    restore_config_groups "$array_name" || ((fail++))
    if [[ -z "$CG_DEFER" ]]; then
        print_service_summary "Restore" "$array_name" "$restored config type(s) restored, $missing not in backup, $fail failed" "$(restore_base_dir)"
    fi
    if ((fail > 0)); then
        return 1
    elif ((restored == 0 && CG_DONE == 0)); then
        return 2
    else
        return 0
    fi
}

# Named entry points per service (used by the "All" runs and the CLI)
backup_yarn_configs() { backup_service YARN_CONFIGS; }
backup_mr_configs() { backup_service MR_CONFIGS; }
backup_tez_configs() { backup_service TEZ_CONFIGS; }
backup_hive_configs() { backup_service HIVE_CONFIGS; }
backup_sqoop_configs() { backup_service SQOOP_CONFIGS; }
backup_oozie_configs() { backup_service OOZIE_CONFIGS; }
backup_spark2_configs() { backup_service SPARK2_CONFIGS; }
backup_zookeeper_configs() { backup_service ZOOKEEPER_CONFIGS; }
backup_infra_solr_configs() { backup_service INFRA_SOLR_CONFIGS; }
backup_knox_configs() { backup_service KNOX_CONFIGS; }
backup_kerberos_configs() { backup_service KERBEROS_CONFIGS; }
backup_hue_configs() { backup_service HUE_CONFIGS; }
backup_impala_configs() { backup_service IMPALA_CONFIGS; }
backup_kafka_configs() { backup_service KAFKA_CONFIGS; }
backup_ranger_configs() { backup_service RANGER_CONFIGS; }
backup_ranger_kms_configs() { backup_service RANGER_KMS_CONFIGS; }
backup_spark3_configs() { backup_service SPARK3_CONFIGS; }
backup_spark4_configs() { backup_service SPARK4_CONFIGS; }
backup_nifi_configs() { backup_service NIFI_CONFIGS; }
backup_nifi_registry_configs() { backup_service NIFI_REGISTRY_CONFIG; }
backup_schema_registry_configs() { backup_service SCHEMA_REGISTRY_CONFIG; }
backup_httpfs_configs() { backup_service HTTPFS_CONFIG; }
backup_kudu_configs() { backup_service KUDU_CONFIG; }
backup_jupyter_configs() { backup_service JUPYTER_CONFIG; }
backup_flink_configs() { backup_service FLINK_CONFIG; }
backup_druid_configs() { backup_service DRUID_CONFIG; }
backup_airflow_configs() { backup_service AIRFLOW_CONFIG; }
backup_atlas_configs() { backup_service ATLAS_CONFIGS; }
backup_ozone_configs() { backup_service OZONE_CONFIG; }
backup_pinot_configs() { backup_service PINOT_CONFIG; }
backup_kafka3_configs() { backup_service KAFKA3_CONFIGS; }
backup_hdfs_configs() { backup_service HDFS_CONFIGS; }
restore_yarn_configs() { restore_service YARN_CONFIGS; }
restore_mr_configs() { restore_service MR_CONFIGS; }
restore_tez_configs() { restore_service TEZ_CONFIGS; }
restore_hive_configs() { restore_service HIVE_CONFIGS; }
restore_sqoop_configs() { restore_service SQOOP_CONFIGS; }
restore_oozie_configs() { restore_service OOZIE_CONFIGS; }
restore_spark2_configs() { restore_service SPARK2_CONFIGS; }
restore_zookeeper_configs() { restore_service ZOOKEEPER_CONFIGS; }
restore_infra_solr_configs() { restore_service INFRA_SOLR_CONFIGS; }
restore_knox_configs() { restore_service KNOX_CONFIGS; }
restore_kerberos_configs() { restore_service KERBEROS_CONFIGS; }
restore_hue_configs() { restore_service HUE_CONFIGS; }
restore_impala_configs() { restore_service IMPALA_CONFIGS; }
restore_kafka_configs() { restore_service KAFKA_CONFIGS; }
restore_ranger_configs() { restore_service RANGER_CONFIGS; }
restore_ranger_kms_configs() { restore_service RANGER_KMS_CONFIGS; }
restore_spark3_configs() { restore_service SPARK3_CONFIGS; }
restore_spark4_configs() { restore_service SPARK4_CONFIGS; }
restore_nifi_configs() { restore_service NIFI_CONFIGS; }
restore_nifi_registry_configs() { restore_service NIFI_REGISTRY_CONFIG; }
restore_schema_registry_configs() { restore_service SCHEMA_REGISTRY_CONFIG; }
restore_httpfs_configs() { restore_service HTTPFS_CONFIG; }
restore_kudu_configs() { restore_service KUDU_CONFIG; }
restore_jupyter_configs() { restore_service JUPYTER_CONFIG; }
restore_flink_configs() { restore_service FLINK_CONFIG; }
restore_druid_configs() { restore_service DRUID_CONFIG; }
restore_airflow_configs() { restore_service AIRFLOW_CONFIG; }
restore_atlas_configs() { restore_service ATLAS_CONFIGS; }
restore_ozone_configs() { restore_service OZONE_CONFIG; }
restore_pinot_configs() { restore_service PINOT_CONFIG; }
restore_kafka3_configs() { restore_service KAFKA3_CONFIGS; }
restore_hdfs_configs() { restore_service HDFS_CONFIGS; }

# print_backup_summary <ok services> <partial services> <failed services>
print_backup_summary() {
    echo
    echo -e "${BOLD}${CYAN}Backup Summary:${NC}"
    if [[ -n "$1" ]]; then
        echo -e "${GREEN}✔ Success:${NC}   $1"
    fi
    if [[ -n "$2" ]]; then
        echo -e "${YELLOW}⚠ Partial (some configs missing):${NC} $2"
    fi
    if [[ -n "$3" ]]; then
        echo -e "${RED}✗ Failed:${NC}    $3"
    fi
}

# Run backup/restore for all services by calling their respective functions
backup_all_configs() {
    local services=(hue impala kafka ranger ranger_kms spark3 spark4 spark2 nifi nifi_registry schema_registry httpfs kudu jupyter flink druid airflow atlas ozone kafka3 pinot mr tez hive sqoop oozie zookeeper infra_solr knox kerberos yarn hdfs)
    local ok=() partial=() fail=()
    local rc
    local CG_DEFER=1
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
    # Every config group in the cluster, including those of services not listed above
    if [[ "${INCLUDE_CONFIG_GROUPS,,}" != "no" ]]; then
        backup_config_groups && ok+=("config_groups") || fail+=("config_groups")
    fi
    print_backup_summary "${ok[*]}" "${partial[*]}" "${fail[*]}"
    echo -e "${BOLD}${CYAN}Backup directory:${NC} $BACKUP_DIR"
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
    local CG_DEFER=1
    restore_hue_configs
    restore_impala_configs
    restore_kafka_configs
    restore_ranger_configs
    restore_ranger_kms_configs
    restore_spark3_configs
    restore_spark4_configs
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
    restore_atlas_configs
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
    restore_config_groups
    if ((RUN_ERRORS == 0)); then
        print_success "Restore of all configurations completed successfully."
        return 0
    else
        print_error "Restore completed with $RUN_ERRORS error(s)."
        return 1
    fi
}

# Restore from a chosen backup directory
# =========================
#  Restore from a directory
# =========================
# Absolute path of a backup directory; accepts the directory holding $BACKUP_SUBDIR or $BACKUP_SUBDIR itself
restore_dir_abs() {
    local dir="$1"
    [[ -d "$dir/$BACKUP_SUBDIR" ]] && dir="$dir/$BACKUP_SUBDIR"
    (cd "$dir" 2>/dev/null && pwd) || {
        echo "[ERROR] Backup directory not found: $1" >&2
        return 1
    }
}

# Restore configurations from a given backup directory
restore_all_from_dir() {
    local base
    base="$(restore_dir_abs "$1")" || return 1
    (RESTORE_BASE="$base" && RUN_ERRORS=0 && restore_all_configs)
}

# Restore configurations from a given backup directory
restore_one_from_dir() {
    local service="$1" base
    base="$(restore_dir_abs "$2")" || return 1
    (
        RESTORE_BASE="$base"
        case "$service" in
        HUE | hue) restore_hue_configs ;;
        IMPALA | impala) restore_impala_configs ;;
        KAFKA | kafka) restore_kafka_configs ;;
        RANGER | ranger) restore_ranger_configs ;;
        RANGER_KMS | ranger_kms | ranger-kms) restore_ranger_kms_configs ;;
        SPARK3 | spark3) restore_spark3_configs ;;
        SPARK4 | spark4) restore_spark4_configs ;;
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
        ATLAS | atlas) restore_atlas_configs ;;
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

# Interactive menu for backing up/restoring service configurations
# =========================
#  Interactive menus
# =========================
# Menu entries, in menu order: label|config array.
# The first MENU_MPACK_COUNT entries are MPACK services, the rest are the stack's default services.
MENU_SERVICES=(
    "🎨 Hue|HUE_CONFIGS"
    "📂 HttpFS|HTTPFS_CONFIG"
    "🦌 Impala|IMPALA_CONFIGS"
    "📨 Kafka3|KAFKA3_CONFIGS"
    "🔥 Spark3|SPARK3_CONFIGS"
    "🔥 Spark4|SPARK4_CONFIGS"
    "🌍 Ozone|OZONE_CONFIG"
    "🐐 Kudu|KUDU_CONFIG"
    "🎛️ NiFi|NIFI_CONFIGS"
    "🏷️ NiFi Registry|NIFI_REGISTRY_CONFIG"
    "📜 Schema Registry|SCHEMA_REGISTRY_CONFIG"
    "📓 Jupyter|JUPYTER_CONFIG"
    "🦩 Flink|FLINK_CONFIG"
    "🍷 Pinot|PINOT_CONFIG"
    "🧙 Druid|DRUID_CONFIG"
    "🌬️ Airflow|AIRFLOW_CONFIG"
    "🧭 Atlas|ATLAS_CONFIGS"
    "📁 HDFS|HDFS_CONFIGS"
    "🧵 YARN|YARN_CONFIGS"
    "🚀 MapReduce2|MR_CONFIGS"
    "🛠️ Tez|TEZ_CONFIGS"
    "🐝 Hive|HIVE_CONFIGS"
    "🐘 Sqoop|SQOOP_CONFIGS"
    "🦫 ZooKeeper|ZOOKEEPER_CONFIGS"
    "🛰️ Infra Solr|INFRA_SOLR_CONFIGS"
    "📨 Kafka|KAFKA_CONFIGS"
    "🔐 Knox|KNOX_CONFIGS"
    "🛡️ Ranger|RANGER_CONFIGS"
    "🔑 Ranger KMS|RANGER_KMS_CONFIGS"
    "🔥 Spark2|SPARK2_CONFIGS"
    "🎩 Oozie|OOZIE_CONFIGS"
    "🛡️ Kerberos|KERBEROS_CONFIGS"
)
MENU_MPACK_COUNT=17

# Reads every config type that exists in the cluster into CLUSTER_TYPES
load_cluster_types() {
    TYPES_KNOWN=""
    declare -gA CLUSTER_TYPES=()
    local file types t
    file="$(mktemp)"
    if ambari_get "?fields=Clusters/desired_configs" >"$file" && types="$(cg_py desired "$file")" && [[ -n "$types" ]]; then
        while read -r t; do CLUSTER_TYPES["$t"]=1; done <<<"$types"
        TYPES_KNOWN=1
    fi
    rm -f "$file"
}

# Marks the menu services that exist in this cluster (at least one of their config types is present)
detect_installed_services() {
    INSTALLED_KNOWN=""
    INSTALLED_COUNT=0
    declare -gA SERVICE_INSTALLED=()
    load_cluster_types
    [[ -n "$TYPES_KNOWN" ]] || return 0
    local entry array menu_configs t
    for entry in "${MENU_SERVICES[@]}"; do
        array="${entry##*|}"
        menu_configs="$array[@]"
        for t in "${!menu_configs}"; do
            if [[ -n "${CLUSTER_TYPES[$t]}" ]]; then
                SERVICE_INSTALLED["$array"]=1
                ((INSTALLED_COUNT++))
                break
            fi
        done
    done
    INSTALLED_KNOWN=1
}

# backup_status <CONFIG_ARRAY_NAME>  -- what the restore directory holds for a service:
# sets BK_TYPES (config types), BK_GROUPS (config groups) and BK_DATE (newest file)
backup_status() {
    local svc_configs="$1[@]" dir t f tag newest=""
    dir="$(restore_base_dir)"
    BK_TYPES=0
    BK_GROUPS=0
    BK_DATE=""
    for t in "${!svc_configs}"; do
        f="$dir/$t/$t.json"
        [[ -f "$f" ]] || continue
        ((BK_TYPES++))
        [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"
    done
    if [[ "${INCLUDE_CONFIG_GROUPS,,}" != "no" ]]; then
        set_cg_filter "$1"
        for tag in ${CG_TAGS//,/ }; do
            for f in "$dir/$CONFIG_GROUPS_DIR/${tag}__"*.json; do
                [[ -f "$f" ]] || continue
                ((BK_GROUPS++))
                [[ -z "$newest" || "$f" -nt "$newest" ]] && newest="$f"
            done
        done
    fi
    [[ -n "$newest" ]] && BK_DATE="$(date -r "$newest" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    return 0
}

# plural <count> <word>  -- "1 group", "2 groups"
plural() {
    if (($1 == 1)); then echo "$1 $2"; else echo "$1 ${2}s"; fi
}

# service_menu <backup|restore>
# Backup lists every service; Restore lists only the services that have a backup in the backup directory.
service_menu() {
    local action="$1" total="${#MENU_SERVICES[@]}" choice i n entry label icon name array status section want
    local shown=()
    while true; do
        echo
        echo -e "${MAGENTA}${BOLD}┌──────────────────────────────────────────────┐${NC}"
        if [[ "$action" == "backup" ]]; then
            echo -e "${MAGENTA}${BOLD}│      ${CYAN}Backup Service Configurations${MAGENTA}${BOLD}           │${NC}"
            echo -e "${MAGENTA}${BOLD}└──────────────────────────────────────────────┘${NC}"
            echo -e "${BOLD}${CYAN}Backup directory:${NC} $BACKUP_DIR"
        else
            echo -e "${MAGENTA}${BOLD}│      ${CYAN}Restore Service Configurations${MAGENTA}${BOLD}          │${NC}"
            echo -e "${MAGENTA}${BOLD}└──────────────────────────────────────────────┘${NC}"
            echo -e "${BOLD}${CYAN}Backup directory:${NC} $(restore_dir_shown)"
        fi
        shown=()
        i=0
        section=""
        for entry in "${MENU_SERVICES[@]}"; do
            ((i++))
            label="${entry%%|*}"
            array="${entry##*|}"
            icon="${label%% *}"
            name="${label#* }"
            status=""
            if [[ "$action" == "restore" ]]; then
                backup_status "$array"
                ((BK_TYPES + BK_GROUPS > 0)) || continue
                status="$(plural "$BK_TYPES" config), $BK_GROUPS config group(s), $BK_DATE"
                [[ -n "$INSTALLED_KNOWN" && -z "${SERVICE_INSTALLED[$array]}" ]] && status+="  (not installed)"
            fi
            if ((i <= MENU_MPACK_COUNT)); then want="MPACK services"; else want="Default services"; fi
            if [[ "$section" != "$want" ]]; then
                section="$want"
                echo
                echo -e "${BOLD}${CYAN}── $section ──${NC}"
            fi
            shown+=("$entry")
            n="${#shown[@]}"
            if [[ "$action" == "restore" ]]; then
                printf "${GREEN}%2d)${NC} %s ${GREEN}${BOLD}%-16s${NC} ${CYAN}%s${NC}\n" "$n" "$icon" "$name" "$status"
            elif [[ -n "$INSTALLED_KNOWN" && -z "${SERVICE_INSTALLED[$array]}" ]]; then
                printf "${DIM}%2d) %s %-16s (not installed)${NC}\n" "$n" "$icon" "$name"
            else
                printf "${GREEN}%2d)${NC} %s ${GREEN}${BOLD}%s${NC}\n" "$n" "$icon" "$name"
            fi
        done
        n="${#shown[@]}"
        echo
        if [[ "$action" == "backup" ]]; then
            printf "${GREEN}%2d)${NC} 🔄 ${GREEN}${BOLD}All (Backup all)${NC}\n" "$((n + 1))"
        elif ((n > 0)); then
            printf "${GREEN}%2d)${NC} 🔄 ${GREEN}${BOLD}All (%s with a backup)${NC}\n" "$((n + 1))" "$(plural "$n" service)"
        fi
        echo -e "${RED} Q) ${BOLD}Back to main menu${NC}"
        echo
        if [[ "$action" == "restore" ]]; then
            if ((n == 0)); then
                print_warning "No backups found in this directory. Take a backup first, or run the script from the directory that holds $BACKUP_SUBDIR."
            elif ((n < total)); then
                echo -e "${CYAN}Note: $(plural "$((total - n))" "other service") of the $total supported have no backup in this directory.${NC}"
            fi
        elif [[ -n "$INSTALLED_KNOWN" ]]; then
            echo -e "${CYAN}Note: this tool supports every service listed. Dimmed entries are not installed on this cluster ($INSTALLED_COUNT of $total installed).${NC}"
        fi
        if [[ "$action" == "restore" ]] && ((n == 0)); then
            echo -ne "${BOLD}${YELLOW}Enter your choice [Q]:${NC} "
        else
            echo -ne "${BOLD}${YELLOW}Enter your choice [1-$((n + 1)), Q]:${NC} "
        fi
        read -r choice || return 0
        echo

        RUN_ERRORS=0
        if [[ "$choice" == [Qq] ]]; then
            return 0
        elif [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= n)); then
            entry="${shown[$((choice - 1))]}"
            label="${entry%%|*}"
            name="${label#* }"
            array="${entry##*|}"
            if [[ "$action" == "backup" ]]; then
                detect_installed_services
                if [[ -n "$INSTALLED_KNOWN" && -z "${SERVICE_INSTALLED[$array]}" ]]; then
                    print_warning "$name is not installed on this cluster, so there is nothing to back up."
                    array=""
                fi
            else
                backup_status "$array"
                if [[ -n "$INSTALLED_KNOWN" && -z "${SERVICE_INSTALLED[$array]}" ]]; then
                    print_warning "$name is not installed on this cluster."
                fi
                echo -e "${BOLD}${CYAN}Restore $name from:${NC} $(restore_dir_shown)"
                echo -e "${BOLD}${CYAN}Backup holds:${NC} $(plural "$BK_TYPES" config), $BK_GROUPS config group(s), taken $BK_DATE"
                confirm_action "overwrite the current $name configuration in Ambari with this backup" || array=""
                echo
            fi
            [[ -n "$array" ]] && "${action}_service" "$array"
        elif ((n > 0)) && [[ "$choice" == "$((n + 1))" ]]; then
            if [[ "$action" == "backup" ]]; then
                detect_installed_services
                backup_all_configs
            else
                echo -e "${BOLD}${CYAN}Restore ALL services from:${NC} $(restore_dir_shown)"
                echo -e "${BOLD}${CYAN}Backup holds:${NC} $(plural "$n" service)"
                confirm_action "overwrite the current configuration of these services in Ambari with this backup" && echo && restore_all_configs
            fi
        else
            print_error "Invalid option. Please select a valid service."
            continue
        fi
        echo
        read -r -p "Press Enter to return to the menu... " _ || return 0
    done
}

# CLI argument parsing for non-interactive usage
# =========================
#  Non-interactive CLI
# =========================
#
# Usage:
#   --restore-from <path> <service|all>   restore from a backup directory
if [[ "$1" == "--restore-from" ]]; then
    custom_path="$2"
    what="$3"
    if [[ -z "$custom_path" || -z "$what" ]]; then
        echo "[ERROR] Usage: --restore-from <path> <service|all>"
        exit 1
    fi
    resolve_cluster
    if [[ "$what" == "all" ]]; then
        echo "[INFO] Restoring ALL from: $custom_path"
        restore_all_from_dir "$custom_path"
    else
        echo "[INFO] Restoring $what from: $custom_path"
        restore_one_from_dir "$what" "$custom_path"
    fi
    rc=$?
    move_doset_files
    exit $rc
elif [[ "$1" == "--help" || "$1" == "-h" ]]; then
    print_script_info
    echo -e "${BOLD}${CYAN}Usage:${NC}"
    echo -e "  ${YELLOW}--restore-from <path> <service|all>${NC}  Restore from a specific backup directory"
    echo -e "  ${YELLOW}--help, -h${NC}                           Show this help message"
    echo -e "Config groups are backed up to <backup>/$CONFIG_GROUPS_DIR/ and restored with their service."
    echo -e "Set ${YELLOW}INCLUDE_CONFIG_GROUPS=no${NC} to handle the Default group only."
    exit 0
elif [[ -n "$1" ]]; then
    echo "[ERROR] Unknown option: $1 (see --help)"
    exit 1
fi

# Entrypoint function for interactive mode
# =========================
#  Interactive entrypoint
# =========================
main() {
    INTERACTIVE=1
    resolve_cluster
    detect_installed_services
    local choice
    while true; do
        echo
        echo -e "${BOLD}${CYAN}Cluster Name:${NC} ${GREEN}$CLUSTER${NC}"
        echo
        echo -e "${BOLD}${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
        echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}Select an option:${NC}                               ${BOLD}${YELLOW}│${NC}"
        echo -e "${BOLD}${YELLOW}├─────────────────────────────────────────────────┤${NC}"
        echo -e "${BOLD}${YELLOW}│${NC} ${GREEN}[1]${NC} ${BOLD}Backup service configurations${NC}               ${BOLD}${YELLOW}│${NC}"
        echo -e "${BOLD}${YELLOW}│${NC} ${GREEN}[2]${NC} ${BOLD}Restore service configurations${NC}              ${BOLD}${YELLOW}│${NC}"
        echo -e "${BOLD}${YELLOW}│${NC} ${RED}[Q]${NC} ${BOLD}Quit${NC}                                        ${BOLD}${YELLOW}│${NC}"
        echo -e "${BOLD}${YELLOW}└─────────────────────────────────────────────────┘${NC}"
        echo -ne "${BOLD}Enter your choice [1-2, Q]:${NC} "
        read -r choice || break
        case "$choice" in
        "1") service_menu backup ;;
        "2") service_menu restore ;;
        [Qq]) break ;;
        *) print_error "Invalid option. Please enter 1, 2 or Q." ;;
        esac
    done
}

main

move_doset_files
