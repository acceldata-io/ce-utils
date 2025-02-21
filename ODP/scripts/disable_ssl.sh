#!/bin/bash
##########################################################################
# Disable SSL for Hadoop Services - Enhanced Interactive Version
# Company: Acceldata Inc
#
# This script disables SSL configurations for various Hadoop-related
# services via Ambari’s API.
#
# Usage:
#   ./disable_ssl.sh [-s <ambari_server>] [-u <user>] [-p <password>] [-P <port>] [-r <protocol>]
#
##########################################################################

# Color definitions
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'  # No Color

# Log file location
LOGFILE="/tmp/disable_ssl.log"
touch "$LOGFILE"

# Default values (editable by the user)
AMBARISERVER_DEFAULT=$(hostname -f)
USER_DEFAULT="admin"
PASSWORD_DEFAULT="admin"
PORT_DEFAULT=8080
PROTOCOL_DEFAULT="http"

# Simplified log function: prints colored messages without timestamps or level labels.
log() {
    local message="$1"
    local color="$2"
    echo -e "${color}${message}${NC}" | tee -a "$LOGFILE"
}

# Usage information
usage() {
    echo "Usage: $0 [-s <ambari_server>] [-u <user>] [-p <password>] [-P <port>] [-r <protocol>]"
    echo "  -s <server>      Ambari server hostname (default: ${AMBARISERVER_DEFAULT})"
    echo "  -u <user>        Username (default: ${USER_DEFAULT})"
    echo "  -p <password>    Password (default: ${PASSWORD_DEFAULT})"
    echo "  -P <port>        Port (default: ${PORT_DEFAULT})"
    echo "  -r <protocol>    Protocol (default: ${PROTOCOL_DEFAULT})"
    echo "  -h               Show help"
}

# Process command-line options
while getopts "s:u:p:P:r:h" opt; do
    case $opt in
        s) AMBARISERVER_DEFAULT="$OPTARG" ;;
        u) USER_DEFAULT="$OPTARG" ;;
        p) PASSWORD_DEFAULT="$OPTARG" ;;
        P) PORT_DEFAULT="$OPTARG" ;;
        r) PROTOCOL_DEFAULT="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Export environment variables
export AMBARISERVER="${AMBARISERVER_DEFAULT}"
export USER="${USER_DEFAULT}"
export PASSWORD="${PASSWORD_DEFAULT}"
export PORT="${PORT_DEFAULT}"
export PROTOCOL="${PROTOCOL_DEFAULT}"

# Display current configuration with emojis
echo -e "🔑 Please ensure that you have set all variables correctly."
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} ${AMBARISERVER}"
echo -e "👤 ${GREEN}USER:${NC} ${USER}"
echo -e "🔒 ${GREEN}PASSWORD:${NC} ********"
echo -e "🌐 ${GREEN}PORT:${NC} ${PORT}"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} ${PROTOCOL}"

# Handle interruptions gracefully
cleanup() {
    log "Script interrupted. Exiting..." "${RED}"
    exit 1
}
trap cleanup SIGINT SIGTERM

# Retrieve the cluster name from Ambari API
CLUSTER=$(curl -s -k -u "${USER}:${PASSWORD}" -i -H 'X-Requested-By: ambari' \
    "${PROTOCOL}://${AMBARISERVER}:${PORT}/api/v1/clusters" | \
    sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

if [ -z "$CLUSTER" ]; then
    log "Failed to retrieve cluster name. Check your Ambari server settings." "${RED}"
    exit 1
fi

# Function to get host for a given component
get_host_for_component() {
    local component="$1"
    local endpoint="${PROTOCOL}://${AMBARISERVER}:${PORT}/api/v1/clusters/${CLUSTER}/host_components?HostRoles/component_name=${component}"
    curl -s -k -u "${USER}:${PASSWORD}" -H 'X-Requested-By: ambari' "$endpoint" | \
        grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | head -n 1
}

# Retrieve host information for various components
timelineserver=$(get_host_for_component "APP_TIMELINE_SERVER")
historyserver=$(get_host_for_component "HISTORYSERVER")
rangeradmin=$(get_host_for_component "RANGER_ADMIN")
OOZIE_HOSTNAME=$(get_host_for_component "OOZIE_SERVER")
rangerkms=$(get_host_for_component "RANGER_KMS_SERVER")

# Function to set or delete configurations via Ambari API
set_config() {
    local action="$1"
    local config_file="$2"
    local key="$3"
    local value="$4"
    
    local cmd="python /var/lib/ambari-server/resources/scripts/configs.py -u ${USER} -p ${PASSWORD} -s ${PROTOCOL} -a ${action} -t ${PORT} -l ${AMBARISERVER} -n ${CLUSTER} -c ${config_file} -k ${key}"
    if [ "$action" != "delete" ]; then
        cmd+=" -v ${value}"
    fi
    eval "$cmd"
    if [ $? -ne 0 ]; then
        log "Failed to ${action} config ${key} in ${config_file}." "${RED}"
    else
        log "Successfully ${action}ed ${key} in ${config_file}." "${GREEN}"
    fi
}

# Service-specific SSL disable functions
disable_hdfs_ssl() {
    log "Disabling SSL for HDFS/YARN/MR and related components..." "${GREEN}"
    set_config "set" "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "set" "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "set" "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "set" "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "set" "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"
    set_config "set" "core-site" "hadoop.rpc.protection" "authentication"
    set_config "set" "hdfs-site" "dfs.encrypt.data.transfer" "false"
    set_config "set" "hdfs-site" "dfs.http.policy" "HTTP_ONLY"
    set_config "set" "hdfs-site" "dfs.https.enable" "false"
    set_config "set" "mapred-site" "mapreduce.shuffle.ssl.enabled" "false"
    set_config "set" "mapred-site" "mapreduce.jobhistory.http.policy" "HTTP_ONLY"
    set_config "set" "yarn-site" "yarn.http.policy" "HTTP_ONLY"
    set_config "set" "yarn-site" "yarn.log.server.url" "http://${historyserver}:19888/jobhistory/logs"
    set_config "set" "yarn-site" "yarn.log.server.web-service.url" "http://${timelineserver}:8188/ws/v1/applicationhistory"
    set_config "delete" "yarn-site" "yarn.nodemanager.webapp.https.address"
    set_config "set" "tez-site" "tez.runtime.shuffle.ssl.enable" "false"
    set_config "set" "tez-site" "tez.runtime.shuffle.keep-alive.enabled" "false"
}

disable_kafka_ssl() {
    log "Disabling SSL for Kafka..." "${GREEN}"
    set_config "delete" "kafka-broker" "ssl.keystore.location"
    set_config "delete" "kafka-broker" "ssl.keystore.password"
    set_config "delete" "kafka-broker" "ssl.key.password"
    set_config "delete" "kafka-broker" "ssl.truststore.location"
    set_config "delete" "kafka-broker" "ssl.truststore.password"
}

disable_hive_ssl() {
    log "Disabling SSL for Hive..." "${GREEN}"
    set_config "set" "hive-site" "hive.server2.use.SSL" "false"
    set_config "delete" "hive-site" "hive.server2.keystore.path"
    set_config "delete" "hive-site" "hive.server2.keystore.password"
}

disable_infra_solr_ssl() {
    log "Disabling SSL for Infra-Solr..." "${GREEN}"
    set_config "set" "infra-solr-env" "infra_solr_ssl_enabled" "false"
}

disable_ranger_ssl() {
    log "Disabling SSL for Ranger Admin..." "${GREEN}"
    set_config "set" "ranger-admin-site" "ranger.service.http.enabled" "true"
    set_config "set" "ranger-admin-site" "ranger.service.https.attrib.clientAuth" "false"
    set_config "set" "ranger-admin-site" "ranger.service.https.attrib.ssl.enabled" "false"
    set_config "set" "ranger-admin-site" "ranger.externalurl" "http://${rangeradmin}:6080"
    set_config "set" "ranger-knox-security" "ranger.plugin.knox.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-kms-security" "ranger.plugin.kms.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-hbase-security" "ranger.plugin.hbase.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-yarn-security" "ranger.plugin.yarn.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-hdfs-security" "ranger.plugin.hdfs.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-kafka-security" "ranger.plugin.kafka.policy.rest.url" "http://${rangeradmin}:6080"
    set_config "set" "ranger-hive-security" "ranger.plugin.hive.policy.rest.url" "http://${rangeradmin}:6080"
}

disable_ranger_kms_ssl() {
    log "Reverting SSL configuration for ODP Ranger KMS..." "${GREEN}"
    set_config "set" "ranger-kms-site" "ranger.service.https.attrib.ssl.enabled" "false"
    set_config "set" "hdfs-site" "dfs.encryption.key.provider.uri" "kms://http@${rangerkms}:9292/kms"
    set_config "set" "core-site" "hadoop.security.key.provider.path" "kms://http@${rangerkms}:9292/kms"
    set_config "set" "kms-env" "kms_port" "9292"
    log "ODP Ranger KMS SSL configuration reverted." "${GREEN}"
}

disable_hbase_ssl() {
    log "Disabling SSL for HBase..." "${GREEN}"
    set_config "set" "hbase-site" "hbase.ssl.enabled" "false"
    set_config "set" "hbase-site" "hadoop.ssl.enabled" "false"
}

disable_spark2_ssl() {
    log "Disabling SSL for Spark2..." "${GREEN}"
    set_config "set" "yarn-site" "spark.authenticate" "false"
    set_config "set" "spark2-defaults" "spark.authenticate" "false"
    set_config "set" "spark2-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "set" "spark2-defaults" "spark.ssl.enabled" "false"
    set_config "set" "spark2-defaults" "spark.ui.https.enabled" "false"
    set_config "set" "spark2-hive-site-override" "hive.server2.transport.mode" "binary"
    set_config "set" "spark2-hive-site-override" "hive.server2.use.SSL" "false"
    set_config "delete" "livy2-conf" "livy.keystore"
    set_config "delete" "livy2-conf" "livy.keystore.password"
    set_config "delete" "livy2-conf" "livy.key-password"
}

disable_spark3_ssl() {
    log "Disabling SSL for Spark3..." "${GREEN}"
    set_config "set" "yarn-site" "spark.authenticate" "false"
    set_config "set" "spark3-defaults" "spark.authenticate" "false"
    set_config "set" "spark3-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "set" "spark3-defaults" "spark.ssl.enabled" "false"
    set_config "set" "spark3-defaults" "spark.ui.https.enabled" "false"
    set_config "delete" "spark3-defaults" "spark.ssl.keyPassword"
    set_config "delete" "spark3-defaults" "spark.ssl.keyStore"
    set_config "delete" "spark3-defaults" "spark.ssl.keyStorePassword"
    set_config "delete" "spark3-defaults" "spark.ssl.protocol"
    set_config "delete" "spark3-defaults" "spark.ssl.trustStore"
    set_config "delete" "spark3-defaults" "spark.ssl.trustStorePassword"
}

disable_oozie_ssl() {
    log "Disabling SSL for Oozie..." "${GREEN}"
    set_config "set" "oozie-site" "oozie.https.enabled" "false"
    set_config "set" "oozie-site" "oozie.base.url" "http://${OOZIE_HOSTNAME}:11000/oozie"
}

# Interactive menu with colored output
display_service_options() {
    echo -e "\n${GREEN}Choose the services for which to disable SSL:${NC}"
    echo -e "${CYAN}1) HDFS/YARN/MR${NC}"
    echo -e "${CYAN}2) Infra-Solr${NC}"
    echo -e "${CYAN}3) Hive${NC}"
    echo -e "${CYAN}4) Ranger Admin${NC}"
    echo -e "${CYAN}5) Spark2${NC}"
    echo -e "${CYAN}6) Kafka${NC}"
    echo -e "${CYAN}7) HBase${NC}"
    echo -e "${CYAN}8) Spark3${NC}"
    echo -e "${CYAN}9) Oozie${NC}"
    echo -e "${CYAN}10) Ranger KMS${NC}"
    echo -e "${GREEN}A) All Services${NC}"
    echo -e "${RED}Q) Quit${NC}"
    echo -ne "${GREEN}Enter your choice: ${NC}"
}

# Main interactive loop
while true; do
    display_service_options
    read choice
    case $choice in
        1)  disable_hdfs_ssl ;;
        2)  disable_infra_solr_ssl ;;
        3)  disable_hive_ssl ;;
        4)  disable_ranger_ssl ;;
        5)  disable_spark2_ssl ;;
        6)  disable_kafka_ssl ;;
        7)  disable_hbase_ssl ;;
        8)  disable_spark3_ssl ;;
        9)  disable_oozie_ssl ;;
        10) disable_ranger_kms_ssl ;;
        [Aa])
            disable_hdfs_ssl
            disable_infra_solr_ssl
            disable_hive_ssl
            disable_ranger_ssl
            disable_spark2_ssl
            disable_kafka_ssl
            disable_hbase_ssl
            disable_spark3_ssl
            disable_oozie_ssl
            disable_ranger_kms_ssl
            ;;
        [Qq])
            log "Exiting script as requested by user." "${RED}"
            break ;;
        *)
            log "Invalid choice. Please try again." "${RED}"
            ;;
    esac
done

# Post-execution: Move generated JSON files to /tmp if they exist
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo -e "${GREEN}JSON files moved to /tmp.${NC}"
else
    echo -e "${CYAN}No JSON files found to move.${NC}"
fi

echo -e "${GREEN}Script execution completed. Access the Ambari UI and restart affected services to apply changes.${NC}"
