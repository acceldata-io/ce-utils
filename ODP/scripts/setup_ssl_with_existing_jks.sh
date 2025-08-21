#!/bin/bash
##########################################################################
# Acceldata Inc. | ODP
#
# This script enables SSL for various Hadoop-related services using an
# existing Java KeyStore (JKS) and corresponding PKCS12 files.
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

# Keystore and Truststore details (JKS format)
keystorepassword="keystore_Password"       # Replace with actual keystore password
truststorepassword="truststore_Password"     # Replace with actual truststore password
keystore="/opt/security/pki/server.jks"
truststore="/opt/security/pki/ca-certs.jks"

# Ensure that the keystore alias for the 
# ranger.service.https.attrib.keystore.keyalias property is correctly configured. By default, it is set to the Ranger and KMS node's hostname.
# To verify, log in to the Ranger node and run:
#   keytool -list -keystore $keystore
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

timelineserver=$(get_host_for_component "APP_TIMELINE_SERVER")
historyserver=$(get_host_for_component "HISTORYSERVER")
rangeradmin=$(get_host_for_component "RANGER_ADMIN")
OOZIE_HOSTNAME=$(get_host_for_component "OOZIE_SERVER")
rangerkms=$(get_host_for_component "RANGER_KMS_SERVER")

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN}      Acceldata ODP SSL Configuration Script        ${NC}"
echo -e "${GREEN}====================================================${NC}"
# Validate essential variables and files before starting
required_files=("$keystore" "$truststore" )
for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo -e "${RED}Error:${NC} Required file '$file' not found. Please check before proceeding."
        exit 1
    fi
done

echo -e "${YELLOW}✅ All required keystore and truststore files are present.${NC}"
echo -e "${YELLOW}🔑 Please ensure that you have set all variables correctly.${NC}\n"
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🔒 ${GREEN}PASSWORD:${NC} ******** (hidden for security)"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "🔐 ${GREEN}keystore:${NC} $keystore"
echo -e "🔐 ${GREEN}truststore:${NC} $truststore"
echo -e "🔐 ${GREEN}keystorepassword:${NC} ********"
echo -e "🔐 ${GREEN}truststorepassword:${NC} ********"
echo -e "${YELLOW}ℹ️ Verify the keystore alias for Ranger and KMS nodes matches the configured alias \n (ranger.service.https.attrib.keystore.keyalias - default: host FQDN).${NC}"
echo -e "${GREEN}keytool -list -keystore \"$keystore\"${NC}"
echo -e "${GREEN}────────────────────────────────────────────────────────${NC}"
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
    && echo -e "${GREEN}[OK]${NC} Updated ${config_file}:${key}" \
    || echo -e "${RED}Failed updating ${key} in ${config_file}.${NC}" | tee -a /tmp/setup_ssl.log
}

#---------------------------------------------------------
# Service-Specific SSL Enable Functions with Start/Success Messages
#---------------------------------------------------------

enable_hdfs_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for HDFS, YARN, and MapReduce...${NC}"
    set_config "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"
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
    echo -e "${GREEN}Successfully enabled SSL for HDFS, YARN, and MapReduce.${NC}"
}

enable_infra_solr_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Infra-Solr...${NC}"
    set_config "infra-solr-env" "infra_solr_ssl_enabled" "true"
    set_config "infra-solr-env" "infra_solr_keystore_location" "$keystore"
    set_config "infra-solr-env" "infra_solr_keystore_password" "$keystorepassword"
    set_config "infra-solr-env" "infra_solr_keystore_type" "jks"
    set_config "infra-solr-env" "infra_solr_truststore_location" "$truststore"
    set_config "infra-solr-env" "infra_solr_truststore_password" "$truststorepassword"
    set_config "infra-solr-env" "infra_solr_truststore_type" "jks"
    set_config "infra-solr-env" "infra_solr_extra_java_opts" "-Dsolr.jetty.keystore.type=jks -Dsolr.jetty.truststore.type=jks" 
    echo -e "${GREEN}Successfully enabled SSL for Infra-Solr.${NC}"
}

enable_hive_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Hive...${NC}"
    set_config "hive-site" "hive.server2.use.SSL" "true"
    set_config "hive-site" "hive.server2.keystore.path" "$keystore"
    set_config "hive-site" "hive.server2.keystore.password" "$keystorepassword"
    set_config "hive-site" "hive.server2.webui.use.ssl" "true"
    set_config "hive-site" "hive.server2.webui.keystore.path" "$keystore"
    set_config "hive-site" "hive.server2.webui.keystore.password" "$keystorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Hive.${NC}"
}

enable_ranger_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Ranger...${NC}"
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
    set_config "ranger-knox-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-knox-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-knox-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-knox-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-nifi-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-nifi-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-nifi-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-nifi-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-nifi-registry-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-nifi-registry-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-nifi-registry-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-nifi-registry-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-kudu-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-kudu-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-kudu-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-kudu-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-knox-security" "ranger.plugin.knox.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-knox-audit" "xasecure.audit.destination.solr": "false"
    set_config "ranger-kms-security" "ranger.plugin.kms.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hbase-security" "ranger.plugin.hbase.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-yarn-security" "ranger.plugin.yarn.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hdfs-security" "ranger.plugin.hdfs.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-kafka-security" "ranger.plugin.kafka.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-hive-security" "ranger.plugin.hive.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-nifi-security" "ranger.plugin.nifi.policy.rest.url" "https://$rangeradmin:6182"
    set_config "ranger-nifi-registry-security" "ranger.plugin.nifi-registry.policy.rest.url" "https://$rangeradmin:6182"    
    set_config "ranger-kudu-security" "ranger.plugin.kudu.policy.rest.url" "https://$rangeradmin:6182"    
    set_config "ranger-ozone-security" "ranger.plugin.kudu.policy.rest.url" "https://$rangeradmin:6182"    
    set_config "ranger-kafka3-security" "ranger.plugin.kudu.policy.rest.url" "https://$rangeradmin:6182"  
    set_config "ranger-ozone-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-ozone-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-ozone-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-ozone-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-schema-registry-security" "ranger.plugin.schema-registry.policy.rest.url" "https://$rangeradmin:6182"    
    set_config "ranger-schema-registry-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-schema-registry-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-schema-registry-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-schema-registry-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-kafka3-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-kafka3-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-kafka3-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-kafka3-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"    
    echo -e "${GREEN}Successfully enabled SSL for Ranger.${NC}"
}

enable_ranger_kms_ssl() {
    echo -e "${YELLOW}Starting to configure SSL for ODP Ranger KMS...${NC}"
    set_config "ranger-kms-site" "ranger.service.https.attrib.ssl.enabled" "true"
    set_config "ranger-kms-site" "ranger.service.https.attrib.client.auth" "false"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.file" "$keystore"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.keyalias" "$rangerkms"
    set_config "ranger-kms-site" "ranger.service.https.attrib.keystore.pass" "$keystorepassword"
    set_config "hdfs-site" "dfs.encryption.key.provider.uri" "kms://https@$rangerkms:9393/kms"
    set_config "core-site" "hadoop.security.key.provider.path" "kms://https@$rangerkms:9393/kms"
    set_config "kms-env" "kms_port" "9393"
    echo -e "${GREEN}ODP Ranger KMS SSL configuration applied.${NC}"
}

enable_spark2_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Spark2...${NC}"
    set_config "yarn-site" "spark.authenticate" "false"
    set_config "spark2-defaults" "spark.authenticate" "false"
    set_config "spark2-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "spark2-defaults" "spark.ssl.enabled" "true"
    set_config "spark2-defaults" "spark.ssl.keyPassword" "$keystorepassword"
    set_config "spark2-defaults" "spark.ssl.keyStore" "$keystore"
    set_config "spark2-defaults" "spark.ssl.keyStorePassword" "$keystorepassword"
    set_config "spark2-defaults" "spark.ssl.protocol" "TLS"
    set_config "spark2-defaults" "spark.ssl.trustStore" "$truststore"
    set_config "spark2-defaults" "spark.ssl.trustStorePassword" "$truststorepassword"
    set_config "spark2-defaults" "spark.ui.https.enabled" "true"
    set_config "spark2-defaults" "spark.ssl.historyServer.port" "18481"
    echo -e "${GREEN}Successfully enabled SSL for Spark2.${NC}"
}

enable_kafka_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Kafka...${NC}"
    set_config "kafka-broker" "ssl.keystore.location" "$keystore"
    set_config "kafka-broker" "ssl.keystore.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.key.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.truststore.location" "$truststore"
    set_config "kafka-broker" "ssl.truststore.password" "$truststorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Kafka.${NC}"
}

enable_kafka3_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Kafka...${NC}"
    set_config "kafka3-broker" "ssl.keystore.location" "$keystore"
    set_config "kafka3-broker" "ssl.keystore.password" "$keystorepassword"
    set_config "kafka3-broker" "ssl.key.password" "$keystorepassword"
    set_config "kafka3-broker" "ssl.truststore.location" "$truststore"
    set_config "kafka3-broker" "ssl.truststore.password" "$truststorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Kafka3.${NC}"
}

enable_hbase_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for HBase...${NC}"
    set_config "hbase-site" "hbase.ssl.enabled" "true"
    set_config "hbase-site" "hadoop.ssl.enabled" "true"
    set_config "hbase-site" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.password" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.location" "$keystore"
    echo -e "${GREEN}Successfully enabled SSL for HBase.${NC}"
}

enable_spark3_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Spark3...${NC}"
    set_config "yarn-site" "spark.authenticate" "false"
    set_config "spark3-defaults" "spark.authenticate" "false"
    set_config "spark3-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "spark3-defaults" "spark.ssl.enabled" "true"
    set_config "spark3-defaults" "spark.ssl.keyPassword" "$keystorepassword"
    set_config "spark3-defaults" "spark.ssl.keyStore" "$keystore"
    set_config "spark3-defaults" "spark.ssl.keyStorePassword" "$keystorepassword"
    set_config "spark3-defaults" "spark.ssl.protocol" "TLS"
    set_config "spark3-defaults" "spark.ssl.trustStore" "$truststore"
    set_config "spark3-defaults" "spark.ssl.trustStorePassword" "$truststorepassword"
    set_config "spark3-defaults" "spark.ui.https.enabled" "true"
    set_config "spark3-defaults" "spark.ssl.historyServer.port" "18482"
    echo -e "${GREEN}Successfully enabled SSL for Spark3.${NC}"
}

enable_oozie_ssl() {
    echo -e "${YELLOW}Starting to enable SSL for Oozie...${NC}"
    set_config "oozie-site" "oozie.https.enabled" "true"
    set_config "oozie-site" "oozie.https.port" "11443"
    set_config "oozie-site" "oozie.https.keystore.file" "$keystore"
    set_config "oozie-site" "oozie.https.keystore.pass" "$keystorepassword"
    set_config "oozie-site" "oozie.https.truststore.file" "$truststore"
    set_config "oozie-site" "oozie.https.truststore.pass" "$truststorepassword"
    set_config "oozie-site" "oozie.base.url" "https://$OOZIE_HOSTNAME:11443/oozie"
    echo -e "${GREEN}Successfully enabled SSL for Oozie.${NC}"
}

enable_ozone_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for Ozone...${NC}"    
    set_config "ozone-env" "ozone_scm_ssl_enabled" "true"
    set_config "ozone-env" "ozone_manager_ssl_enabled" "true"
    set_config "ozone-env" "ozone_s3g_ssl_enabled" "true"
    set_config "ozone-env" "ozone_datanode_ssl_enabled" "true"
    set_config "ozone-env" "ozone_recon_ssl_enabled" "true"
    set_config "ozone-env" "ozone_scm_ssl_enabled" "true"
    set_config "ozone-site" "ozone.http.policy" "HTTPS_ONLY"
    set_config "ozone-site" "ozone.https.client.keystore.resource" "ssl-client.xml"
    set_config "ozone-site" "ozone.https.server.keystore.resource" "ssl-server.xml"   
    set_config "ssl-server-recon" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-recon" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client-datanode" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client-datanode" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client-om" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client-om" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client-recon" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client-recon" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client-s3g" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client-s3g" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-client-scm" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client-scm" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-datanode" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-datanode" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-datanode" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server-datanode" "ssl.server.keystore.password" "$keystorepassword"
    set_config "ssl-server-om" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-om" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-om" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server-om" "ssl.server.keystore.password" "$keystorepassword"
    set_config "ssl-server-recon" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-recon" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-recon" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server-recon" "ssl.server.keystore.password" "$keystorepassword"
    set_config "ssl-server-s3g" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-s3g" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-s3g" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server-s3g" "ssl.server.keystore.password" "$keystorepassword"
    set_config "ssl-server-scm" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-server-scm" "ssl.server.truststore.password" "$truststorepassword"
    set_config "ssl-server-scm" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server-scm" "ssl.server.keystore.password" "$keystorepassword"    
    set_config "ozone-ssl-client" "ssl.client.truststore.location" "$truststore"
    set_config "ozone-ssl-client" "ssl.client.truststore.password" "$truststorepassword"    
    set_config "ssl-server-datanode" "ssl.server.keystore.keypassword" "$keystorepassword"    
    set_config "ssl-server-om" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "ssl-server-recon" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "ssl-server-s3g" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "ssl-server-scm" "ssl.server.keystore.keypassword" "$keystorepassword"    
    echo -e "${GREEN}Successfully enabled SSL for Ozone.${NC}"
}

enable_nifi_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for NiFi ...${NC}"    
    set_config "nifi-ambari-ssl-config" "nifi.node.ssl.isenabled" "true"
    set_config "nifi-ambari-ssl-config" "nifi.security.keyPasswd" "$keystorepassword"
    set_config "nifi-ambari-ssl-config" "nifi.security.keystore" "$keystore"    
    set_config "nifi-ambari-ssl-config" "nifi.security.keystorePasswd" "$keystorepassword"
    set_config "nifi-ambari-ssl-config" "nifi.security.keystoreType" "jks"      
    set_config "nifi-ambari-ssl-config" "nifi.security.truststore" "$truststore"
    set_config "nifi-ambari-ssl-config" "nifi.security.truststoreType" "jks"    
    set_config "nifi-ambari-ssl-config" "nifi.security.truststorePasswd" "$truststorepassword"
    echo -e "${GREEN}Successfully enabled SSL for NiFi.${NC}"
}

enable_schema_registry () {
    echo -e "${YELLOW}Starting to enable SSL for Schema Registry ...${NC}"        
    set_config "registry-ssl-config" "registry.ssl.isenabled" "true"
    set_config "registry-ssl-config" "registry.keyStoreType" "jks"
    set_config "registry-ssl-config" "registry.trustStoreType" "jks"
    set_config "registry-ssl-config" "registry.keyStorePath" "$keystore"
    set_config "registry-ssl-config" "registry.trustStorePath" "$truststore"
    set_config "registry-ssl-config" "registry.keyStorePassword" "$keystorepassword"    
    set_config "registry-ssl-config" "registry.trustStorePassword" "$truststorepassword"  
    echo -e "${GREEN}Successfully enabled SSL for Schema Registry.${NC}"
}

#---------------------------------------------------------
# Livy3 SSL enablement
#---------------------------------------------------------
#---------------------------------------------------------
# Livy3 SSL enablement
#---------------------------------------------------------
enable_livy3_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for Livy3...${NC}"
    set_config "livy3-conf" "livy.keystore" "$keystore"
    set_config "livy3-conf" "livy.keystore.password" "$keystorepassword"
    set_config "livy3-conf" "livy.key-password" "$keystorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Livy3.${NC}"
}

#---------------------------------------------------------
# Livy2 SSL enablement
#---------------------------------------------------------
enable_livy2_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for Livy2...${NC}"
    set_config "livy2-conf" "livy.keystore" "$keystore"
    set_config "livy2-conf" "livy.keystore.password" "$keystorepassword"
    set_config "livy2-conf" "livy.key-password" "$keystorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Livy2.${NC}"
}
#---------------------------------------------------------
# Menu for Selecting SSL Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "\n🚀 ${YELLOW}SSL Configuration – Choose a Service:${NC}"
    echo -e "${GREEN}--------------------------------------------${NC}"
    echo -e "${GREEN} 1)${NC} 🗃️ HDFS, YARN & MapReduce"
    echo -e "${GREEN} 2)${NC} 🔍 Infra-Solr"
    echo -e "${GREEN} 3)${NC} 🐝 Hive"
    echo -e "${GREEN} 4)${NC} 🛡️ Ranger"
    echo -e "${GREEN} 5)${NC} ✨ Spark2"
    echo -e "${GREEN} 6)${NC} 📡 Kafka"
    echo -e "${GREEN} 7)${NC} 📚 HBase"
    echo -e "${GREEN} 8)${NC} ⚡ Spark3"
    echo -e "${GREEN} 9)${NC} 🌀 Oozie"
    echo -e "${GREEN}10)${NC} 🔑 Ranger KMS"
    echo -e "${GREEN}11)${NC} ☁️ Ozone"
    echo -e "${GREEN}12)${NC} ⚙️ NiFi" 
    echo -e "${GREEN}13)${NC} 🔄 Schema Registry"
    echo -e "${GREEN}14)${NC} 🔬 Livy2"
    echo -e "${GREEN}15)${NC} 📡 Kafka3"  
    echo -e "${GREEN}16)${NC} 🧪 Livy3"
    echo -e "${GREEN}--------------------------------------------${NC}" 
    echo -e "${GREEN} A)${NC} 🌐 All Services"
    echo -e "${RED} Q)${NC} ❌ Quit"
    echo -e "${GREEN}----------------------------------------${NC}"
}

#---------------------------------------------------------
# Main Menu Loop
#---------------------------------------------------------
while true; do
    display_service_options
    read -rp "Enter your selection:⇒ " choice
    case "$choice" in
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
        11) enable_ozone_ssl ;;
        12) enable_nifi_ssl ;;
        13) enable_schema_registry ;;
        14) enable_livy2_ssl ;;
        15) enable_kafka3_ssl ;;
        16) enable_livy3_ssl ;;
        [Aa]) 
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
            enable_ozone_ssl
            enable_nifi_ssl
            enable_schema_registry
            enable_livy2_ssl
            enable_livy3_ssl
            enable_kafka3_ssl
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
echo -e "${YELLOW}Access the Ambari UI and initiate a restart for the affected services to apply the SSL changes.${NC}"
