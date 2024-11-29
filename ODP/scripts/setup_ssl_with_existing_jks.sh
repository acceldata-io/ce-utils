#!/bin/bash
# Acceldata Inc.
# ODP-3.2.2.0-1

GREEN='\033[0;32m'
NC='\033[0m'  # No Color

export AMBARISERVER=`hostname -f`
export USER=admin
export PASSWORD=admin
export PORT=8080
export PROTOCOL=http
export keystorepassword=keystore_Password       # Replace with actual keystore password
export truststorepassword=truststore_Password   # Replace with actual truststore password
export keystore=/opt/security/pki/server.jks
export truststore=/opt/security/pki/ca-certs.jks

# For Infra-Solr we need PKCS12 format keystore and truststore.
# keytool -importkeystore -srckeystore [MY_KEYSTORE.jks] -destkeystore [MY_FILE.p12] -srcstoretype JKS -deststoretype PKCS12 -deststorepass [PASSWORD_PKCS12]
export keystore_p12=/opt/security/pki/server.p12
export truststore_p12=/opt/security/pki/ca-certs.p12

# Make sure the Ranger keystore alias is set correctly for the "ranger.service.https.attrib.keystore.keyalias" property by default is set to Ranger node hostname.

# curl command to get the required details from Ambari Cluster
CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
timelineserver=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=APP_TIMELINE_SERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//')
historyserver=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=HISTORYSERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//')
rangeradmin=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=RANGER_ADMIN" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//'  |head -n 1)
OOZIE_HOSTNAME=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=OOZIE_SERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//'  |head -n 1)

echo -e "🔑 Please ensure that you have set all variables correctly."
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🔒 ${GREEN}PASSWORD:${NC} ********"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🔐 ${GREEN}keystorepassword:${NC} ********"  
echo -e "🔐 ${GREEN}truststorepassword:${NC} ********"
echo -e "🔐 ${GREEN}keystore:${NC} $keystore"
echo -e "🔐 ${GREEN}truststore:${NC} $truststore"
echo -e "🔐 ${GREEN}keystore_p12:${NC} $keystore_p12"
echo -e "🔐 ${GREEN}truststore_p12:${NC} $truststore_p12"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"

echo -e "ℹ️  ${GREEN}Make sure Keystore:${NC} $keystore"
echo -e "ℹ️  ${GREEN}Truststore:${NC} $truststore ${GREEN}are present on all cluster nodes.${NC}"

# Function to set configurations
set_config() {
    local config_file=$1
    local key=$2
    local value=$3

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER \
        -c $config_file -k $key -v $value
}

# Function to enable SSL for HDFS
enable_hdfs_ssl() {
    set_config "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"
    set_config "core-site" "hadoop.rpc.protection" "privacy"
    set_config "hdfs-site" "dfs.encrypt.data.transfer" "true"
    set_config "hdfs-site" "dfs.encrypt.data.transfer.algorithm" "3des"
    set_config "hdfs-site" "dfs.namenode.https-address" "0.0.0.0:50470"
    set_config "hdfs-site"  "dfs.namenode.secondary.https-address" "0.0.0.0:50091"
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
}

# Function to enable SSL for Hive
enable_infra_solr_ssl() {
    set_config "infra-solr-env" "infra_solr_ssl_enabled" "true"
    set_config "infra-solr-env" "infra_solr_keystore_location" "$keystore_p12"
    set_config "infra-solr-env" "infra_solr_keystore_password" "$keystorepassword"
    set_config "infra-solr-env" "infra_solr_keystore_type" "PKCS12"
    set_config "infra-solr-env" "infra_solr_truststore_location" "$truststore_p12"
    set_config "infra-solr-env" "infra_solr_truststore_password" "$truststorepassword"
    set_config "infra-solr-env" "infra_solr_truststore_type" "PKCS12"
}

# Function to enable SSL for Hive
enable_hive_ssl() {
    set_config "hive-site" "hive.server2.use.SSL" "true"
    set_config "hive-site" "hive.server2.keystore.path" "$keystore"
    set_config "hive-site" "hive.server2.keystore.password" "$keystorepassword"
}

# Function to enable SSL for Ranger
enable_ranger_ssl() {
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
}

# Function to enable SSL for Spark2
enable_spark2_ssl() {
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
}

# Function to enable SSL for Kafka
enable_kafka_ssl() {
    set_config "kafka-broker" "ssl.keystore.location" "$keystore"
    set_config "kafka-broker" "ssl.keystore.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.key.password" "$keystorepassword"
    set_config "kafka-broker" "ssl.truststore.location" "$truststore"
    set_config "kafka-broker" "ssl.truststore.password" "$truststorepassword"
}

# Function to enable SSL for Hbase
enable_hbase_ssl() {
    set_config "hbase-site" "hbase.ssl.enabled" "true"
    set_config "hbase-site" "hadoop.ssl.enabled" "true"
    set_config "hbase-site" "ssl.server.keystore.keypassword" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.password" "$keystorepassword"
    set_config "hbase-site" "ssl.server.keystore.location" "$keystore"
}

# Function to enable SSL for Spark3
enable_spark3_ssl() {
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
}
# Function to enable SSL for Oozie
enable_oozie_ssl() {
    set_config "oozie-site" "oozie.https.enabled" "true"
    set_config "oozie-site" "oozie.https.port" "11443"
    set_config "oozie-site" "oozie.https.keystore.file" "$keystore"
    set_config "oozie-site" "oozie.https.keystore.pass" "$keystorepassword"
    set_config "oozie-site" "oozie.https.truststore.file" "$truststore"
    set_config "oozie-site" "oozie.https.truststore.pass" "$truststorepassword"
    set_config "oozie-site" "oozie.base.url" "https://$OOZIE_HOSTNAME:11443/oozie"
}

# Display service options
function display_service_options() {
    echo "Select services to enable SSL:"
    echo "1) HDFS YARN MR"
    echo "2) Infra-Solr"
    echo "3) Hive"
    echo "4) Ranger"
    echo "5) Spark2"
    echo "6) Kafka"
    echo "7) Hbase"
    echo "8) Spark3"
    echo "9) Oozie"
    echo "A) All"
    echo "Q) Quit"
}

# Select services to enable SSL
while true; do
    display_service_options
    read -p "Enter your choice: " choice

    case $choice in
        1)
            enable_hdfs_ssl
            ;;
        2)
            enable_infra_solr_ssl
            ;;
        3)
            enable_hive_ssl
            ;;
        4)
            enable_ranger_ssl
            ;;
        5)
            enable_spark2_ssl
            ;;
        6)
            enable_kafka_ssl
            ;;
        7)
            enable_hbase_ssl
            ;;
        8)
            enable_spark3_ssl
            ;;
        9)
            enable_oozie_ssl
            ;;
        [Aa])
            for service in "hdfs" "infra_solr" "hive" "ranger" "spark2" "kafka" "hbase" "spark3" "oozie"; do
                enable_${service}_ssl
            done
            ;;
        [Qq])
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
done

# move generated JSON files to /tmp if they exist
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo "JSON files moved to /tmp."
else
    echo "No JSON files found to move."
fi

echo "Script execution completed."
echo -e "${GREEN}Access the Ambari UI and initiate a restart for the affected services in order to apply the SSL changes.${NC}"
