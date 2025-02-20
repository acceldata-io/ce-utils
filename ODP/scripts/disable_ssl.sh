#!/bin/bash
# Disable SSL for Hadoop Services
# Acceldata Inc
# Author: [Pravin Bhagade]
# Date: [23 Oct 2024]

GREEN='\033[0;32m'
NC='\033[0m'  # No Color

export AMBARISERVER=`hostname -f`
export USER=admin
export PASSWORD=admin
export PORT=8080
export PROTOCOL=http

# Retrieve cluster and host information
CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
timelineserver=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=APP_TIMELINE_SERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//')
historyserver=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=HISTORYSERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//')
rangeradmin=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=RANGER_ADMIN" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//'  | head -n 1)
OOZIE_HOSTNAME=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=OOZIE_SERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//'  | head -n 1)
rangerkms=$(curl -s -k -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=RANGER_KMS_SERVER" | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//'  |head -n 1)

echo -e "🔑 Please ensure that you have set all variables correctly."
echo -e "⚙️  ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🔒 ${GREEN}PASSWORD:${NC} ********"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"

# Function to set configurations
set_config() {
    local action=$1
    local config_file=$2
    local key=$3
    local value=$4

    if [ "$action" == "delete" ]; then
        python /var/lib/ambari-server/resources/scripts/configs.py \
            -u $USER -p $PASSWORD -s $PROTOCOL -a delete -t $PORT -l $AMBARISERVER -n $CLUSTER \
            -c $config_file -k $key
    else
        python /var/lib/ambari-server/resources/scripts/configs.py \
            -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER \
            -c $config_file -k $key -v $value
    fi
}

# Function to disable SSL for HDFS
disable_hdfs_ssl() {
    # HADOOP
    set_config "set" "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "set" "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "set" "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "set" "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "set" "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"

    # HDFS
    set_config "set" "core-site" "hadoop.rpc.protection" "authentication"
    set_config "set" "hdfs-site" "dfs.encrypt.data.transfer" "false"

    # HDFS UI
    set_config "set" "hdfs-site" "dfs.http.policy" "HTTP_ONLY"
    set_config "set" "hdfs-site" "dfs.https.enable" "false"

    # MR Shuffle
    set_config "set" "mapred-site" "mapreduce.shuffle.ssl.enabled" "false"

    # MapReduce2 UI
    set_config "set" "mapred-site" "mapreduce.jobhistory.http.policy" "HTTP_ONLY"

    # YARN
    set_config "set" "yarn-site" "yarn.http.policy" "HTTP_ONLY"
    set_config "set" "yarn-site" "yarn.log.server.url" "http://$historyserver:19888/jobhistory/logs"
    set_config "set" "yarn-site" "yarn.log.server.web-service.url" "http://$timelineserver:8188/ws/v1/applicationhistory"
    set_config "delete" "yarn-site" "yarn.nodemanager.webapp.https.address"

    # TEZ
    set_config "set" "tez-site" "tez.runtime.shuffle.ssl.enable" "false"
    set_config "set" "tez-site" "tez.runtime.shuffle.keep-alive.enabled" "false"
}

# Function to disable SSL for Kafka
disable_kafka_ssl() {
    set_config "delete" "kafka-broker" "ssl.keystore.location"
    set_config "delete" "kafka-broker" "ssl.keystore.password"
    set_config "delete" "kafka-broker" "ssl.key.password"
    set_config "delete" "kafka-broker" "ssl.truststore.location"
    set_config "delete" "kafka-broker" "ssl.truststore.password"
}

# Function to disable SSL for Hive
disable_hive_ssl() {
    set_config "set" "hive-site" "hive.server2.use.SSL" "false"
    set_config "delete" "hive-site" "hive.server2.keystore.path"
    set_config "delete" "hive-site" "hive.server2.keystore.password"
}

# Function to disable SSL for Infra-Solr
disable_infra_solr_ssl() {
    set_config "set" "infra-solr-env" "infra_solr_ssl_enabled" "false"
}

# Function to disable SSL for Ranger Admin
disable_ranger_ssl() {
    set_config "set" "ranger-admin-site" "ranger.service.http.enabled" "true"
    set_config "set" "ranger-admin-site" "ranger.service.https.attrib.clientAuth" "false"
    set_config "set" "ranger-admin-site" "ranger.service.https.attrib.ssl.enabled" "false"
    set_config "set" "ranger-admin-site" "ranger.externalurl" "http://$rangeradmin:6080"    

    set_config "set" "ranger-knox-security" "ranger.plugin.knox.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-kms-security" "ranger.plugin.kms.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-hbase-security" "ranger.plugin.hbase.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-yarn-security" "ranger.plugin.yarn.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-hdfs-security" "ranger.plugin.hdfs.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-kafka-security" "ranger.plugin.kafka.policy.rest.url" "http://$rangeradmin:6080"
    set_config "set" "ranger-hive-security" "ranger.plugin.hive.policy.rest.url" "http://$rangeradmin:6080"
}

# Function to disable SSL for ODP Ranger KMS (Revert changes)
disable_ranger_kms_ssl() {
    echo -e "${YELLOW}Reverting SSL configuration for ODP Ranger KMS...${NC}"
    
    # Disable SSL for Ranger KMS in ranger-kms-site
    set_config set "ranger-kms-site" "ranger.service.https.attrib.ssl.enabled" "false"

    # Revert HDFS encryption key provider properties to use HTTP
    set_config set "hdfs-site" "dfs.encryption.key.provider.uri" "kms://http@$rangerkms:9292/kms"
    set_config set "hdfs-site" "hadoop.security.key.provider.path" "kms://http@$rangerkms:9292/kms"    
    echo -e "${GREEN}ODP Ranger KMS SSL configuration reverted.${NC}"
}


# Function to disable SSL for HBase
disable_hbase_ssl() {
    set_config "set" "hbase-site" "hbase.ssl.enabled" "false"
    set_config "set" "hbase-site" "hadoop.ssl.enabled" "false"
}

# Function to disable SSL for Spark2
disable_spark2_ssl() {
    set_config "set" "yarn-site" "spark.authenticate" "false"
    set_config "set" "spark2-defaults" "spark.authenticate" "false"
    set_config "set" "spark2-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "set" "spark2-defaults" "spark.ssl.enabled" "false"
    set_config "set" "spark2-defaults" "spark.ui.https.enabled" "false"
    set_config "set" "spark2-hive-site-override" "hive.server2.transport.mode" "binary"
    set_config "set" "spark2-hive-site-override" "hive.server2.use.SSL" "false"

    # Delete Livy SSL configurations
    set_config "delete" "livy2-conf" "livy.keystore"
    set_config "delete" "livy2-conf" "livy.keystore.password"
    set_config "delete" "livy2-conf" "livy.key-password"
}

disable_spark3_ssl() {
    set_config "set" "yarn-site" "spark.authenticate" "false"
    set_config "set" "spark3-defaults" "spark.authenticate" "false"
    set_config "set" "spark3-defaults" "spark.authenticate.enableSaslEncryption" "false"
    set_config "set" "spark3-defaults" "spark.ssl.enabled" "false"
    set_config "set" "spark3-defaults" "spark.ui.https.enabled" "false"

    # Delete SSL configurations
    set_config "delete" "spark3-defaults" "spark.ssl.keyPassword"
    set_config "delete" "spark3-defaults" "spark.ssl.keyStore"
    set_config "delete" "spark3-defaults" "spark.ssl.keyStorePassword"
    set_config "delete" "spark3-defaults" "spark.ssl.protocol"
    set_config "delete" "spark3-defaults" "spark.ssl.trustStore"
    set_config "delete" "spark3-defaults" "spark.ssl.trustStorePassword"
}

# Function to disable SSL for Oozie
disable_oozie_ssl() {
    set_config "set" "oozie-site" "oozie.https.enabled" "false"
    set_config "set" "oozie-site" "oozie.base.url" "http://$OOZIE_HOSTNAME:11000/oozie"
}

# Function to display service options
display_service_options() {
    echo "Select services to disable SSL:"
    echo "1) HDFS YARN MR"
    echo "2) Infra-Solr"
    echo "3) Hive"
    echo "4) Ranger Admin"
    echo "5) Spark2"
    echo "6) Kafka"
    echo "7) HBase"
    echo "8) Spark3"
    echo "9) Oozie"
    echo "10) Ranger KMS"
    echo "A) All"
    echo "Q) Quit"
}

# Select services to disable SSL
while true; do
    display_service_options
    read -p "Enter your choice: " choice

    case $choice in
        1)
            disable_hdfs_ssl
            ;;
        2)
            disable_infra_solr_ssl
            ;;
        3)
            disable_hive_ssl
            ;;
        4)
            disable_ranger_ssl
            ;;
        5)
            disable_spark2_ssl
            ;;
        6)
            disable_kafka_ssl
            ;;
        7)
            disable_hbase_ssl
            ;;
        8)
            disable_spark3_ssl
            ;;
        9)
            disable_oozie_ssl
            ;; 
        10)
            disable_ranger_kms_ssl
            ;;          
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
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
done

# Move generated JSON files to /tmp if they exist
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo "JSON files moved to /tmp."
else
    echo "No JSON files found to move."
fi

echo "Script execution completed."
echo -e "${GREEN}Access the Ambari UI and initiate a restart for the affected services to apply the changes.${NC}"
