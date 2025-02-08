#!/bin/bash
###############################################################################
# Script to configure SSL for various Ambari-managed services.
#
# Prerequisites:
#   - curl
#   - python (used by Ambari’s configs.py script)
#
# This script uses environment variables and interactive input to configure
# SSL properties via Ambari’s REST API. It avoids hard‑coding sensitive
# information where possible.
#
# Author: [Pravin Bhagade] (Improved by ChatGPT)
# Date: 2025-02-08
###############################################################################

# Color definitions using ANSI escape codes
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m'  # No Color

# Trap CTRL+C and other interrupts to exit gracefully
trap 'echo -e "\n${RED}Interrupted. Exiting...${NC}"; exit 1' INT

# Dependency checks
command -v curl >/dev/null 2>&1 || { echo -e "${RED}Error: curl is required but not installed. Aborting.${NC}"; exit 1; }
command -v python >/dev/null 2>&1 || { echo -e "${RED}Error: python is required but not installed. Aborting.${NC}"; exit 1; }

###############################################################################
# Environment Variables
###############################################################################

export AMBARISERVER=$(hostname -f)

# Avoid conflict with reserved variables (USER, PASSWORD)
export AMBARI_USER="admin"
export AMBARI_PASSWORD="admin"
export PORT="8080"
export PROTOCOL="http"

# Keystore and Truststore settings (update as needed)
export keystorepassword="keystore_Password"       # Replace with actual keystore password
export truststorepassword="truststore_Password"     # Replace with actual truststore password
export keystore="/opt/security/pki/server.jks"
export truststore="/opt/security/pki/ca-certs.jks"

# For Infra-Solr, the PKCS12 formatted files
export keystore_p12="/opt/security/pki/server.p12"
export truststore_p12="/opt/security/pki/ca-certs.p12"

# Disable Python HTTPS verification (if necessary)
export PYTHONHTTPSVERIFY=0

###############################################################################
# Retrieve Cluster and Component Host Information from Ambari
###############################################################################

# Get the cluster name by parsing the JSON response with sed/grep
CLUSTER=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -i -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

# Abort if no cluster name is found
if [[ -z "$CLUSTER" ]]; then
    echo -e "${RED}Error: Unable to determine cluster name. Check your Ambari credentials and API URL.${NC}"
    exit 1
fi

# Retrieve host names for various components
timelineserver=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=APP_TIMELINE_SERVER" | \
  grep -o '"host_name" *: *"[^"]*' | sed 's/"host_name" *: *"//')

historyserver=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=HISTORYSERVER" | \
  grep -o '"host_name" *: *"[^"]*' | sed 's/"host_name" *: *"//')

rangeradmin=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=RANGER_ADMIN" | \
  grep -o '"host_name" *: *"[^"]*' | sed 's/"host_name" *: *"//' | head -n 1)

OOZIE_HOSTNAME=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=OOZIE_SERVER" | \
  grep -o '"host_name" *: *"[^"]*' | sed 's/"host_name" *: *"//' | head -n 1)

rangerkms=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H 'X-Requested-By: ambari' \
  "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=RANGER_KMS_SERVER" | \
  grep -o '"host_name" *: *"[^"]*' | sed 's/"host_name" *: *"//' | head -n 1)

###############################################################################
# Display Current Configuration
###############################################################################

echo -e "${YELLOW}🔑 Please ensure that you have set all variables correctly.${NC}\n"
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}AMBARI_USER:${NC} $AMBARI_USER"
echo -e "🔒 ${GREEN}AMBARI_PASSWORD:${NC} ********"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🔐 ${GREEN}keystorepassword:${NC} ********"  
echo -e "🔐 ${GREEN}truststorepassword:${NC} ********"
echo -e "🔐 ${GREEN}keystore:${NC} $keystore"
echo -e "🔐 ${GREEN}truststore:${NC} $truststore"
echo -e "ℹ️ ${YELLOW}Make sure to create the .p12 keystore and truststore on the Infra-Solr node:${NC}"
echo -e "🔐 ${GREEN}keystore_p12:${NC} $keystore_p12"
echo -e "🔐 ${GREEN}truststore_p12:${NC} $truststore_p12"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL\n"

echo -e "ℹ️  ${YELLOW}Ensure the Keystore:${NC} $keystore"
echo -e "ℹ️  ${YELLOW}and Truststore:${NC} $truststore ${YELLOW}are present on all cluster nodes.${NC}\n"
echo -e "ℹ️  ${YELLOW}Verify the keystore alias on the Ranger node using:${NC}"
echo -e "🔍  ${GREEN}keytool -list -keystore $keystore${NC}\n"
echo -e "ℹ️  ${YELLOW}If the alias matches the FQDN, no changes are required. Otherwise, update the"
echo -e "   '${GREEN}ranger.service.https.attrib.keystore.keyalias${NC}' property in the Ranger configuration.\n"

###############################################################################
# Function to Set Configurations via Ambari’s REST API
###############################################################################
set_config() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" -s "$PROTOCOL" -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config_file" -k "$key" -v "$value"
}

###############################################################################
# Service Configuration Functions
###############################################################################

# Enable SSL for HDFS, YARN, and MapReduce
enable_hdfs_ssl() {
    echo -e "${YELLOW}Configuring SSL for HDFS, YARN, and MapReduce...${NC}"
    set_config "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"
    set_config "core-site" "hadoop.rpc.protection" "privacy"
    set_config "hdfs-site" "dfs.encrypt.data.transfer" "true"
    set_config "hdfs-site" "dfs.encrypt.data.transfer.algorithm" "3des"
    set_config "hdfs-site" "dfs.namenode.https-address" "0.0.0.0:50470"
    set_config "hdfs-site" "dfs.namenode.secondary.https-address" "0.0.0.0:50091"
    set_config "ssl-server" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "ssl-server" "ssl.server.keystore.password" "$keystorepassword"
    set_config "ssl-server" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server" "ssl.server.truststore.location" "$truststore"
    set_config "ssl-server" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client" "ssl.client.keystore.location" "$keystore"
    set_config "ssl-client" "ssl.client.keystore.password" "$keystorepassword"
    set_config "ssl-client" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client" "ssl.client.truststore.password" "$truststorepassword"
    set_config "hdfs-site" "dfs.http.policy" "HTTPS_ONLY"
    set_config "mapred-site" "mapreduce.shuffle.ssl.enabled" "true"
    set_config "mapred-site" "mapreduce.jobhistory.http.policy" "HTTPS_ONLY"
    set_config "mapred-site" "mapreduce.jobhistory.webapp.https.address" "0.0.0.0:19890"
    set_config "mapred-site" "mapreduce.jobhistory.webapp.address" "0.0.0.0:19890"
    set_config "yarn-site" "yarn.http.policy" "HTTPS_ONLY"
    set_config "yarn-site" "yarn.log.server.url" "https://$historyserver:19890/jobhistory/logs"
    set_config "yarn-site" "yarn.log.server.web-service.url" "https://$timelineserver:8190/ws/v1/applicationhistory"
    set_config "yarn-site" "yarn.nodemanager.webapp.https.address" "0.0.0.0:8044"
    set_config "hdfs-site" "dfs.https.enable" "true"
    set_config "tez-site" "tez.runtime.shuffle.ssl.enable" "true"
    set_config "tez-site" "tez.runtime.shuffle.keep-alive.enabled" "true"
    echo -e "${GREEN}HDFS, YARN, and MapReduce SSL configuration applied.${NC}\n"
}

# Enable SSL for Infra-Solr
enable_infra_solr_ssl() {
    echo -e "${YELLOW}Configuring SSL for Infra-Solr...${NC}"
    set_config "infra-solr-env" "infra_solr_ssl_enabled" "true"
    set_config "infra-solr-env" "infra_solr_keystore_location" "$keystore_p12"
    set_config "infra-solr-env" "infra_solr_keystore_password" "$keystorepassword"
    set_config "infra-solr-env" "infra_solr_keystore_type" "PKCS12"
    set_config "infra-solr-env" "infra_solr_truststore_location" "$truststore_p12"
    set_config "infra-solr-env" "infra_solr_truststore_password" "$truststorepassword"
    set_config "infra-solr-env" "infra_solr_truststore_type" "PKCS12"
    echo -e "${GREEN}Infra-Solr SSL configuration applied.${NC}\n"
}

# Enable SSL for Hive
enable_hive_ssl() {
    echo -e "${YELLOW}Configuring SSL for Hive...${NC}"
    set_config "hive-site" "hive.server2.use.SSL" "true"
    set_config "hive-site" "hive.server2.keystore.path" "$keystore"
    set_config "hive-site" "hive.server2.keystore.password" "$keystorepassword"
    echo -e "${GREEN}Hive SSL configuration applied.${NC}\n"
}

# Enable SSL for Ranger
enable_ranger_ssl() {
    echo -e "${YELLOW}Configuring SSL for Ranger...${NC}"
    set_config "ranger-admin-site" "ranger.service.http.enabled" "false"
    set_config "ranger-admin-site" "ranger.https.attrib.keystore.file" "$keystore"
    set_config "ranger-admin-site" "ranger.service.https.attrib.keystore.pass" "$keystorepassword"
    set_config "ranger-admin-site" "ranger.service.https.attrib.keystore.keyalias" "$rangeradmin"
    set_config "ranger-admin-site" "ranger.service.https.attrib.clientAuth" "false"
    set_config "ranger-admin-site" "ranger.service.https.attrib.ssl.enabled" "true"
    set_config "ranger-admin-site" "ranger.service.https.port" "6182"
    set_config "ranger-admin-site" "ranger.truststore.alias" "$rangeradmin"
    set_config "ranger-admin-site" "ranger.truststore.file" "$truststore"
    set_config "ranger-admin-site" "ranger.truststore.password" "$truststorepassword"
    set_config "ranger-admin-site" "ranger.service.https.attrib.keystore.file" "$keystore"
    set_config "ranger-admin-site" "ranger.service.https.attrib.client.auth" "false"
    set_config "ranger-admin-site" "ranger.externalurl" "https://$rangeradmin:6182"
    set_config "admin-properties" "policymgr_external_url" "https://$rangeradmin:6182"
    set_config "ranger-tagsync-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-tagsync-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-tagsync-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-tagsync-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-ugsync-site" "ranger.usersync.truststore.file" "$truststore"
    set_config "ranger-ugsync-site" "ranger.usersync.truststore.password" "$truststorepassword"
    set_config "ranger-ugsync-site" "ranger.usersync.keystore.file" "$keystore"
    set_config "ranger-ugsync-site" "ranger.usersync.keystore.password" "$keystorepassword"
    set_config "ranger-hdfs-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-hdfs-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-hdfs-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-hdfs-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-yarn-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-yarn-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-yarn-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-yarn-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-hive-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-hive-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-hive-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-hive-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-kms-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-kms-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-kms-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-kms-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-hbase-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-hbase-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-hbase-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-hbase-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-kafka-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-kafka-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-kafka-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-kafka-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-knox-security" "ranger.plugin.knox.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-kms-security" "ranger.plugin.kms.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hbase-security" "ranger.plugin.hbase.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-yarn-security" "ranger.plugin.yarn.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hdfs-security" "ranger.plugin.hdfs.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-kafka-security" "ranger.plugin.kafka.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hive-security" "ranger.plugin.hive.policy.rest.url" "https://$rangeradmin:6182"
    echo -e "${GREEN}Ranger SSL configuration applied.${NC}\n"
}

# Enable SSL for Ranger KMS (ODP)
enable_ranger_kms_ssl() {
    echo -e "${YELLOW}Configuring SSL for ODP Ranger KMS...${NC}"
    set_config "ranger-kms-site" "ranger.service.https.attrib.ssl.enabled" "true"
    set_config "ranger-kms-site" "ranger.service.https.attrib.client.auth" "false"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.file" "$keystore"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.keyalias" "$rangerkms"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.pass" "$keystorepassword"
    # Configure HDFS encryption properties to use Ranger KMS as the key provider
    set_config "hdfs-site" "dfs.encryption.key.provider.uri" "kms://https@$rangerkms:9393/kms"
    set_config "hdfs-site" "hadoop.security.key.provider.path" "kms://https@$rangerkms:9393/kms"
    echo -e "${GREEN}ODP Ranger KMS SSL configuration applied.${NC}\n"
}

# Enable SSL for Spark2
enable_spark2_ssl() {
    echo -e "${YELLOW}Configuring SSL for Spark2...${NC}"
    set_config "yarn-site" "spark.authenticate" "true"
    set_config "spark2-defaults" "spark.authenticate" "true"
    set_config "spark2-defaults" "spark.authenticate.enableSaslEncryption" "true"
    set_config "spark2-defaults" "spark.ssl.enabled" "true"
    set_config "spark2-defaults" "spark.ssl.keyPassword" "$keystorepassword"
    set_config "spark2-defaults" "spark.ssl.keyStore" "$keystore"
    set_config "spark2-defaults" "spark.ssl.keyStorePassword" "$keystorepassword"
    set_config "spark2-defaults" "spark.ssl.protocol" "TLS"
    set_config "spark2-defaults" "spark.ssl.trustStore" "$truststore"
    set_config "spark2-defaults" "spark.ssl.trustStorePassword" "$truststorepassword"
    set_config "spark2-defaults" "spark.ui.https.enabled" "true"
    set_config "spark2-defaults" "spark.ssl.historyServer.port" "18481"
    echo -e "${GREEN}Spark2 SSL configuration applied.${NC}\n"
}

# Enable SSL for Kafka
enable_kafka_ssl() {
    echo -e "${YELLOW}Configuring SSL for Kafka...${NC}"
    set_config "kafka-broker" "ssl.keystore.location" "$keystore"
    set_config "kafka-broker" "ssl.keystore.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.key.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.truststore.location" "$truststore"
    set_config "kafka-broker" "ssl.truststore.password" "$truststorepassword"
    echo -e "${GREEN}Kafka SSL configuration applied.${NC}\n"
}

# Enable SSL for HBase
enable_hbase_ssl() {
    echo -e "${YELLOW}Configuring SSL for HBase...${NC}"
    set_config "hbase-site" "hbase.ssl.enabled" "true"
    set_config "hbase-site" "hadoop.ssl.enabled" "true"
    set_config "hbase-site" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.password" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.location" "$keystore"
    echo -e "${GREEN}HBase SSL configuration applied.${NC}\n"
}

# Enable SSL for Spark3
enable_spark3_ssl() {
    echo -e "${YELLOW}Configuring SSL for Spark3...${NC}"
    set_config "yarn-site" "spark.authenticate" "true"
    set_config "spark3-defaults" "spark.authenticate" "true"
    set_config "spark3-defaults" "spark.authenticate.enableSaslEncryption" "true"
    set_config "spark3-defaults" "spark.ssl.enabled" "true"
    set_config "spark3-defaults" "spark.ssl.keyPassword" "$keystorepassword"
    set_config "spark3-defaults" "spark.ssl.keyStore" "$keystore"
    set_config "spark3-defaults" "spark.ssl.keyStorePassword" "$keystorepassword"
    set_config "spark3-defaults" "spark.ssl.protocol" "TLS"
    set_config "spark3-defaults" "spark.ssl.trustStore" "$truststore"
    set_config "spark3-defaults" "spark.ssl.trustStorePassword" "$truststorepassword"
    set_config "spark3-defaults" "spark.ui.https.enabled" "true"
    set_config "spark3-defaults" "spark.ssl.historyServer.port" "18482"
    echo -e "${GREEN}Spark3 SSL configuration applied.${NC}\n"
}

# Enable SSL for Oozie
enable_oozie_ssl() {
    echo -e "${YELLOW}Configuring SSL for Oozie...${NC}"
    set_config "oozie-site" "oozie.https.enabled" "true"
    set_config "oozie-site" "oozie.https.port" "11443"
    set_config "oozie-site" "oozie.https.keystore.file" "$keystore"
    set_config "oozie-site" "oozie.https.keystore.pass" "$keystorepassword"
    set_config "oozie-site" "oozie.https.truststore.file" "$truststore"
    set_config "oozie-site" "oozie.https.truststore.pass" "$truststorepassword"
    set_config "oozie-site" "oozie.base.url" "https://$OOZIE_HOSTNAME:11443/oozie"
    echo -e "${GREEN}Oozie SSL configuration applied.${NC}\n"
}

###############################################################################
# Interactive Menu Using select
###############################################################################
options=("HDFS, YARN, and MapReduce" "Infra-Solr" "Hive" "Ranger" "Spark2" "Kafka" "HBase" "Spark3" "Oozie" "Ranger KMS" "All" "Quit")
echo -e "${YELLOW}Select services to enable SSL:${NC}"

PS3="Enter your choice (1-${#options[@]}): "

select opt in "${options[@]}"; do
    case "$REPLY" in
        1) enable_hdfs_ssl ;;
        2) enable_infra_solr_ssl ;;
        3) enable_hive_ssl ;;
        4) enable_ranger_ssl ;;
        5) enable_spark2_ssl ;;
        6) enable_kafka_ssl ;;
        7) enable_hbase_ssl ;;
        8) enable_spark3_ssl ;;
        9) enable_oozie_ssl ;;
        10) enable_ranger_kms_ssl ;;
        11)
            # Call all configuration functions
            enable_hdfs_ssl
            enable_infra_solr_ssl
            enable_hive_ssl
            enable_ranger_ssl
            enable_spark2_ssl
            enable_kafka_ssl
            enable_hbase_ssl
            enable_spark3_ssl
            enable_oozie_ssl
            enable_ranger_kms_ssl
            ;;
        12)
            echo -e "${GREEN}Exiting...${NC}"
            break
            ;;
        *)
            echo -e "${YELLOW}Invalid choice. Please try again.${NC}"
            ;;
    esac
done

###############################################################################
# Post-execution Cleanup
###############################################################################
# Move any generated JSON files to /tmp if they exist
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo "JSON files moved to /tmp."
else
    echo "No JSON files found to move."
fi

echo -e "${GREEN}Script execution completed.${NC}"
echo -e "${YELLOW}Access the Ambari UI and initiate a restart for the affected services to apply the SSL changes.${NC}"
