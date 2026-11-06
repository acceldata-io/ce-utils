#!/bin/bash

#---------------------------------------------------------
# Configuration Content
#---------------------------------------------------------

##########################################################################
# Acceldata Inc. | ODP
#
# This script updates configuration for various services to support JDK 17
# migration (source JDK 8 or 11) or patch-upgrade fixes on clusters already
# running JDK 17 (source JDK 17).
#
# Usage:
#   ./setup_jdk17_config.sh
##########################################################################
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
NC='\e[0m'  # No Color
#---------------------------------------------------------
# Default Values (Edit these if required)
#---------------------------------------------------------
# Every value can be overridden from the environment, for example:
#   AMBARI_PASSWORD='secret' bash ./setup_jdk17_config.sh
#   AMBARI_CA_CERT=/path/to/ca.pem bash ./setup_jdk17_config.sh
AMBARI_PROPERTIES="${AMBARI_PROPERTIES:-/etc/ambari-server/conf/ambari.properties}"
AMBARISERVER="${AMBARI_HOST:-$(hostname -f)}"
USER="${AMBARI_USER:-admin}"
PASSWORD="${AMBARI_PASSWORD:-admin}"

# Read a key from ambari.properties (empty when missing).
ambari_prop() {
    [[ -r "$AMBARI_PROPERTIES" ]] || return 0
    grep -E "^$1=" "$AMBARI_PROPERTIES" | tail -1 | cut -d= -f2-
}

# Protocol and port: taken from ambari.properties (api.ssl / client.api.ssl.port /
# client.api.port), unless AMBARI_PROTOCOL / AMBARI_PORT are set.
if [[ "$(ambari_prop api.ssl)" == "true" ]]; then
    PROTOCOL="${AMBARI_PROTOCOL:-https}"
    PORT="${AMBARI_PORT:-$(ambari_prop client.api.ssl.port)}"
    PORT="${PORT:-8443}"
else
    PROTOCOL="${AMBARI_PROTOCOL:-http}"
    PORT="${AMBARI_PORT:-$(ambari_prop client.api.port)}"
    PORT="${PORT:-8080}"
fi


# Template directory
TEMPLATE_DIR="./ODP-env-templates"
MIGRATION_PATH=""  # Will be set based on source JDK version
JAVA_VERSION=""
LOG_FILE="/tmp/jdk17_update.log"
FAILURES=0
CURL_TLS_OPTS=()

#---------------------------------------------------------
# Ambari SSL Certificate Handling (if HTTPS enabled)
#
# configs.py uses Python urllib, which verifies the server certificate against
# the CA bundle in SSL_CERT_FILE. Ambari HTTPS certificates are usually signed
# by a cluster-local CA (for example "HDPCA") or are self-signed, so Python
# rejects them with CERTIFICATE_VERIFY_FAILED unless we point SSL_CERT_FILE at
# that CA. (REQUESTS_CA_BUNDLE / PYTHONHTTPSVERIFY have no effect on urllib.)
#
# Order of lookup:
#   1. AMBARI_CA_CERT=<pem file> from the environment
#   2. the server certificate itself, if it is self-signed
#   3. the issuing CA found in the Ambari truststore (ssl.trustStore.* in ambari.properties)
#   4. the system CA bundle, if it already trusts the server
#---------------------------------------------------------
setup_ambari_tls() {
    [[ "${PROTOCOL,,}" == "https" ]] || return 0

    local work server_pem issuer subject ca_pem=""
    work=$(mktemp -d /tmp/ambari-tls.XXXXXX)
    AMBARI_TLS_WORKDIR="$work"
    trap 'rm -rf "$AMBARI_TLS_WORKDIR"' EXIT
    server_pem="$work/server.pem"

    if ! openssl s_client -connect "${AMBARISERVER}:${PORT}" -servername "${AMBARISERVER}" </dev/null 2>/dev/null \
        | openssl x509 -outform PEM > "$server_pem" 2>/dev/null || [[ ! -s "$server_pem" ]]; then
        echo -e "${RED}[ERROR] Could not read the Ambari certificate from ${AMBARISERVER}:${PORT}.${NC}"
        exit 1
    fi
    subject=$(openssl x509 -in "$server_pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
    issuer=$(openssl x509 -in "$server_pem" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')

    if [[ -n "${AMBARI_CA_CERT:-}" ]]; then
        ca_pem="$AMBARI_CA_CERT"
    elif [[ "$subject" == "$issuer" ]]; then
        ca_pem="$server_pem"
    else
        # Search the Ambari truststore for the certificate whose subject is our issuer.
        local ts ts_pass ts_type keytool_bin
        ts=$(ambari_prop ssl.trustStore.path)
        ts_pass=$(ambari_prop ssl.trustStore.password)
        ts_type=$(ambari_prop ssl.trustStore.type)
        keytool_bin=$(command -v keytool || true)
        [[ -z "$keytool_bin" && -n "$(ambari_prop java.home)" ]] && keytool_bin="$(ambari_prop java.home)/bin/keytool"
        if [[ -n "$ts" && -r "$ts" && -x "$keytool_bin" ]]; then
            AMBARI_TS_PASS="$ts_pass" "$keytool_bin" -list -rfc -keystore "$ts" -storepass:env AMBARI_TS_PASS ${ts_type:+-storetype "$ts_type"} 2>/dev/null \
                | awk -v dir="$work" '/-----BEGIN CERTIFICATE-----/{n++; f=dir"/ts-"n".pem"} f{print > f} /-----END CERTIFICATE-----/{f=""}'
            local c
            for c in "$work"/ts-*.pem; do
                [[ -f "$c" ]] || continue
                if [[ "$(openssl x509 -in "$c" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')" == "$issuer" ]]; then
                    ca_pem="$work/ambari-ca.pem"
                    cp "$c" "$ca_pem"
                    break
                fi
            done
        fi
    fi

    if [[ -n "$ca_pem" ]]; then
        if ! openssl verify -CAfile "$ca_pem" "$server_pem" >/dev/null 2>&1; then
            echo -e "${RED}[ERROR] ${ca_pem} did not sign the Ambari certificate (issuer: ${issuer}).${NC}"
            echo -e "${YELLOW}Set AMBARI_CA_CERT to the PEM file of '${issuer}' and run again.${NC}"
            exit 1
        fi
        export SSL_CERT_FILE="$ca_pem"
        CURL_TLS_OPTS=(--cacert "$ca_pem")
        echo -e "${GREEN}[INFO] Trusting Ambari CA '${issuer}' (${ca_pem}).${NC}"
    elif openssl s_client -connect "${AMBARISERVER}:${PORT}" -verify_return_error </dev/null >/dev/null 2>&1; then
        echo -e "${GREEN}[INFO] Ambari certificate is trusted by the system CA bundle.${NC}"
    else
        echo -e "${RED}[ERROR] Could not find the CA that signed the Ambari certificate (issuer: ${issuer}).${NC}"
        echo -e "${YELLOW}Export it to a PEM file and run: AMBARI_CA_CERT=/path/to/ca.pem bash $0${NC}"
        exit 1
    fi

    # Python also checks that the host name matches the certificate.
    if ! openssl verify -CAfile "${SSL_CERT_FILE:-$server_pem}" -verify_hostname "$AMBARISERVER" "$server_pem" >/dev/null 2>&1 \
        && [[ -n "${SSL_CERT_FILE:-}" ]]; then
        echo -e "${RED}[ERROR] The Ambari certificate is not issued for host '${AMBARISERVER}' (subject: ${subject}).${NC}"
        echo -e "${YELLOW}Run again with AMBARI_HOST=<host name in the certificate>.${NC}"
        exit 1
    fi
}
setup_ambari_tls

#---------------------------------------------------------
# Helper Function: Retrieve Host for a Given Component
#---------------------------------------------------------
get_host_for_component() {
    local component="$1"
    curl -s "${CURL_TLS_OPTS[@]}" -u "$USER:$PASSWORD" -H 'X-Requested-By: ambari' \
      "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters/$CLUSTER/host_components?HostRoles/component_name=${component}" \
      | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | head -n 1
}

#---------------------------------------------------------
# Retrieve Ambari Cluster and Host Information
#---------------------------------------------------------
CLUSTER=$(curl -s "${CURL_TLS_OPTS[@]}" -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' \
    "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" \
    | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

# Stop here if the Ambari API is not reachable, instead of failing every update later.
if [[ -z "$CLUSTER" ]]; then
    echo -e "${RED}[ERROR] Could not read the cluster name from ${PROTOCOL}://${AMBARISERVER}:${PORT}/api/v1/clusters.${NC}"
    echo -e "${YELLOW}Check AMBARI_USER / AMBARI_PASSWORD, AMBARI_PROTOCOL / AMBARI_PORT, and that Ambari Server is running.${NC}"
    exit 1
fi
if ! python /var/lib/ambari-server/resources/scripts/configs.py -u "$USER" -p "$PASSWORD" -s "$PROTOCOL" \
        -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" -c cluster-env >/dev/null 2>"/tmp/jdk17_preflight.err"; then
    echo -e "${RED}[ERROR] configs.py cannot reach the Ambari API. Nothing was changed.${NC}"
    tail -1 /tmp/jdk17_preflight.err
    exit 1
fi


echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}       Acceldata ODP Configuration Script for JDK 17       ${NC}"
echo -e "${GREEN}===========================================================${NC}"

echo -e "⚙️ ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "🏢 ${GREEN}CLUSTER:${NC} $CLUSTER"

#---------------------------------------------------------
# Detect source JDK version and set migration path
#---------------------------------------------------------
detect_source_jdk() {
    echo -e "${YELLOW}Detecting source JDK version...${NC}"
    read -rp "Select source JDK version (8/11/17): " source_jdk

    case "$source_jdk" in
        8)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk8-specific"
            echo -e "${GREEN}Migration path set: JDK 8 -> JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        11)
            MIGRATION_PATH="$TEMPLATE_DIR/jdk11-specific"
            echo -e "${GREEN}Migration path set: JDK 11 -> JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        17)
            MIGRATION_PATH=""
            echo -e "${GREEN}Patch-upgrade mode: cluster already on JDK 17${NC}"
            JAVA_VERSION="$source_jdk"
            ;;
        *)
            echo -e "${RED}Invalid selection. Exiting.${NC}"
            exit 1
            ;;
    esac
}

# ODP 3.3.6.6 spark3/aux has v355 only. The 3.4.3 JDK script writes
# spark_shuffle_358; this script must not.
refuse_spark_358() {
    local where=$1
    local payload=$2
    if [[ "$payload" == *"spark_shuffle_358"* || "$payload" == *"v358.YarnShuffleService"* || "$payload" == *"spark.shuffle.service.v358.port"* ]]; then
        echo -e "${RED}[ERROR] Refusing to push Spark shuffle v358 from the 3.3.6.6 JDK script (${where}). 3.3.6.6 ships v355 only.${NC}" | tee -a /tmp/jdk17_update.log
        exit 1
    fi
}

# Count and log a failed update so the run ends with an honest summary.
record_failure() {
    FAILURES=$((FAILURES + 1))
    echo -e "${RED}$1${NC}" | tee -a "$LOG_FILE"
}

#---------------------------------------------------------
# Function: set_config
# Invokes the Ambari configuration script to set a given property.
#---------------------------------------------------------
set_config() {
    local config_file=$1 key=$2 value=$3
    refuse_spark_358 "${config_file}:${key}" "${key} ${value}"

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
        -b "Configuration updates to support JDK 17" \
    && echo -e "${GREEN}[OK]${NC} Updated ${config_file}:${key}" \
    || record_failure "Failed updating ${key} in ${config_file}."
}

# Create/replace an entire config type from Ambari configuration XML (configs.py -f).
# Use this for new types (e.g. hbase-log4j2) that may not yet exist as desired configs.
set_config_from_file() {
    local config_type=$1
    local xml_file=$2

    if [[ ! -f "$xml_file" ]]; then
        record_failure "Template not found: ${xml_file}"
        return 1
    fi
    refuse_spark_358 "$xml_file" "$(cat "$xml_file")"

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a set \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" \
        -f "$xml_file" \
        -b "Configuration updates to support JDK 17 / Log4j2" \
    && echo -e "${GREEN}[OK]${NC} Updated ${config_type} from $(basename "$xml_file")" \
    || record_failure "Failed updating ${config_type} from ${xml_file}."
}

delete_config() {
    local config_file=$1 key=$2

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a delete \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_file" \
        -k "$key" \
        -b "Old configuration deleted" \
    && echo -e "${GREEN}[OK]${NC} Deleted ${config_file}:${key}" \
    || record_failure "Failed deleting ${key} from ${config_file}."
}

# Resolve cluster stack java.home (same source Ambari uses for hostLevelParams/java_home).
resolve_stack_java_home() {
    local java_home=""
    local candidate=""

    for candidate in /usr/lib/jvm/java-17-openjdk /usr/lib/jvm/java-17; do
        if [[ -d "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
            break
        fi
    done

    if [[ -z "$java_home" && -L /usr/lib/jvm/java ]]; then
        candidate=$(readlink -f /usr/lib/jvm/java 2>/dev/null || true)
        if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
        fi
    fi

    if [[ -z "$java_home" ]]; then
        candidate=$(ls -d /usr/lib/jvm/java-*openjdk* 2>/dev/null | sort -V | tail -1)
        if [[ -n "$candidate" && -x "$candidate/bin/java" ]]; then
            java_home="$candidate"
        fi
    fi

    echo "$java_home"
}

get_config_property() {
    local config_type=$1
    local property_key=$2
    local value=""

    local raw=""

    if ! raw=$(python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a get \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" 2>>"$LOG_FILE"); then
        echo -e "${RED}[ERROR] Could not read ${config_type} from the Ambari API (see ${LOG_FILE}).${NC}" >&2
        return 1
    fi

    value=$(printf '%s' "$raw" \
        | python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.search(r'\{.*\}', raw, re.S); d=json.loads(m.group(0)) if m else {}; print(d.get('properties',{}).get(sys.argv[1],''))" "$property_key" 2>/dev/null)

    echo "$value"
}

# Returns 0 when the Ambari config type exists and has at least one property.
config_type_present() {
    local config_type=$1
    local count=""

    count=$(python /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$USER" \
        -p "$PASSWORD" \
        -s "$PROTOCOL" \
        -a get \
        -t "$PORT" \
        -l "$AMBARISERVER" \
        -n "$CLUSTER" \
        -c "$config_type" 2>/dev/null \
        | python3 -c "import sys,json,re; raw=sys.stdin.read(); m=re.search(r'\{.*\}', raw, re.S); d=json.loads(m.group(0)) if m else {}; print(len(d.get('properties',{})))" 2>/dev/null)

    [[ -n "$count" && "$count" -gt 0 ]]
}

#---------------------------------------------------------
# Service-Specific JVM options
#---------------------------------------------------------

JVM_FLAGS_HDFS="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_YARN="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED"
JVM_FLAGS_TEZ="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_HIVE="--add-opens=java.base/java.io=ALL-UNNAMED --add-opens=java.base/java.lang.invoke=ALL-UNNAMED --add-opens=java.base/java.lang.reflect=ALL-UNNAMED --add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.math=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.security=ALL-UNNAMED --add-opens=java.base/java.text=ALL-UNNAMED --add-opens=java.base/java.time=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util.concurrent=ALL-UNNAMED --add-opens=java.base/java.util.regex=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED --add-opens=java.base/jdk.internal.ref=ALL-UNNAMED --add-opens=java.base/jdk.internal.reflect=ALL-UNNAMED --add-opens=java.base/sun.nio.ch=ALL-UNNAMED --add-opens=java.base/sun.nio.cs=ALL-UNNAMED --add-opens=java.base/sun.security.provider=ALL-UNNAMED --add-opens=java.sql/java.sql=ALL-UNNAMED"
JVM_FLAGS_OOZIE="--add-opens=java.base/java.lang=ALL-UNNAMED --add-opens=java.base/java.net=ALL-UNNAMED --add-opens=java.base/java.nio=ALL-UNNAMED --add-opens=java.base/java.util.concurrent.atomic=ALL-UNNAMED --add-opens=java.base/java.util=ALL-UNNAMED"
JVM_FLAGS_KMS="--add-exports java.xml.crypto/com.sun.org.apache.xml.internal.security.utils=ALL-UNNAMED"

#---------------------------------------------------------
# Service-Specific Configuration Update Functions
#---------------------------------------------------------

update_hdfs_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HDFS, YARN, and MapReduce...${NC}"

    set_config "hdfs-site" "jvm_flags" "${JVM_FLAGS_HDFS}"
    set_config "hadoop-env" "content" "$(cat $TEMPLATE_DIR/hdfs-env-template)"

    set_config "yarn-site" "jvm_flags" "${JVM_FLAGS_YARN}"
    set_config "mapred-env" "content" "$(cat $TEMPLATE_DIR/mapred-env-template)"
    set_config "mapred-site" "yarn.app.mapreduce.am.admin-command-opts" "$(cat $TEMPLATE_DIR/mapred-site-template)"
    set_config "yarn-env" "content" "$(cat $TEMPLATE_DIR/yarn-env-template)"

    # Ambari content already branches on java_version, so JDK 8 and 11 use one template.
    if [ "$JAVA_VERSION" -eq "8" ] || [ "$JAVA_VERSION" -eq "11" ]; then
      set_config "yarn-hbase-env" "content" "$(cat $TEMPLATE_DIR/yarn-hbase-env-template)"
    fi

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      set_config "yarn-site" "yarn.nodemanager.aux-services" "$(cat $MIGRATION_PATH/yarn-nodemanager-aux-services)"
      # Remove configs
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.class"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark2_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.classpath"
      delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle.class"
    fi

    # Migrate spark3_shuffle / spark_shuffle_358 to spark_shuffle_355.
    # 3.3.6.6 spark3/aux does not contain v358, including on a JDK 17 patch upgrade.
    update_yarn_spark_shuffle_isolation

    echo -e "${GREEN}Successfully updated configurations for HDFS, YARN, and MapReduce.${NC}"
}

# Mirrors Ambari config-upgrade task odp_3_3_yarn_spark_shuffle_isolation.
# Migrates yarn.nodemanager.aux-services from spark3_shuffle to versioned handlers
# (spark_shuffle_355 / spark_shuffle_333 / spark_shuffle_351) for multi-Spark clusters.
update_yarn_spark_shuffle_isolation() {
    echo -e "${YELLOW}Migrating YARN NodeManager Spark shuffle aux-services (odp_3_3_yarn_spark_shuffle_isolation)...${NC}"

    local aux_services
    aux_services=$(get_config_property "yarn-site" "yarn.nodemanager.aux-services")

    if [[ -z "$aux_services" ]]; then
        record_failure "[ERROR] yarn.nodemanager.aux-services is empty or missing."
        return 1
    fi

    local aux_services_original="$aux_services"

    # 3.3.6.6 spark3/aux contains v355 only. spark_shuffle_358 is the 3.4 name.
    if [[ "$aux_services" == *"spark_shuffle_358"* ]]; then
        aux_services="${aux_services//spark_shuffle_358/spark_shuffle_355}"
        aux_services="${aux_services//spark_shuffle_355,spark_shuffle_355/spark_shuffle_355}"
    fi

    if [[ "$aux_services" == *"spark_shuffle_355"* ]]; then
        echo -e "${GREEN}[INFO] spark_shuffle_355 already present; updating handler properties only.${NC}"
    else
        if [[ "$aux_services" == *"spark3_shuffle"* ]]; then
            aux_services="${aux_services//spark3_shuffle/spark_shuffle_355}"
        elif [[ "$aux_services" != *"spark_shuffle_355"* ]]; then
            aux_services="${aux_services},spark_shuffle_355"
        fi

        if config_type_present "spark3-3.3.3-env" && [[ "$aux_services" != *"spark_shuffle_333"* ]]; then
            aux_services="${aux_services},spark_shuffle_333"
        fi

        if config_type_present "spark3-3.5.1-env" && [[ "$aux_services" != *"spark_shuffle_351"* ]]; then
            aux_services="${aux_services},spark_shuffle_351"
        fi
    fi

    if [[ "$aux_services" != "$aux_services_original" ]]; then
        set_config "yarn-site" "yarn.nodemanager.aux-services" "$aux_services"
    fi

    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_355.class" "org.apache.spark.network.yarn.v355.YarnShuffleService"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_355.classpath" "{{stack_root}}/{{version}}/spark3/aux/*"
    set_config "yarn-site" "spark.shuffle.service.v355.port" "7335"

    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_411.class" "org.apache.spark.network.yarn.v411.YarnShuffleService"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_411.classpath" "{{stack_root}}/{{version}}/spark4/aux/*"
    set_config "yarn-site" "spark.shuffle.service.v411.port" "7341"

    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_333.class" "org.apache.spark.network.yarn.v333.YarnShuffleService"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_333.classpath" "{{stack_root}}/{{version}}/spark3_3_3_3/aux/*"
    set_config "yarn-site" "spark.shuffle.service.v333.port" "7333"

    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_351.class" "org.apache.spark.network.yarn.v351.YarnShuffleService"
    set_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_351.classpath" "{{stack_root}}/{{version}}/spark3_3_5_1/aux/*"
    set_config "yarn-site" "spark.shuffle.service.v351.port" "7351"

    delete_config "yarn-site" "spark.shuffle.service.port"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark3_shuffle.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark3_shuffle.classpath"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_358.class"
    delete_config "yarn-site" "yarn.nodemanager.aux-services.spark_shuffle_358.classpath"
    delete_config "yarn-site" "spark.shuffle.service.v358.port"

    # Spark clients must ask for the same service name/port the NodeManagers register.
    update_spark3_client_shuffle_service

    echo -e "${GREEN}Finished YARN Spark shuffle isolation configs.${NC}"
}

update_infra_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Infra-Solr...${NC}"

    set_config "infra-solr-env" "infra_solr_gc_log_opts" "$(cat $TEMPLATE_DIR/infra-solr-gc-log-opts)"
    set_config "infra-solr-env" "infra_solr_gc_tune" "$(cat $TEMPLATE_DIR/infra-solr-gc-tune)"

    # Ambari infra-solr-env.sh.j2 already branches on java_version.
    if [ "$JAVA_VERSION" -eq "8" ] || [ "$JAVA_VERSION" -eq "11" ]; then
      set_config "infra-solr-env" "content" "$(cat $TEMPLATE_DIR/infra-solr-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for Infra-Solr.${NC}"
}

update_hive_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Tez and Hive...${NC}"

    set_config "tez-site" "jvm_flags" "${JVM_FLAGS_TEZ}"
    set_config "tez-env" "content" "$(cat $TEMPLATE_DIR/tez-env-template)"
    set_config "tez-site" "tez.am.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"
    set_config "tez-site" "tez.task.launch.cluster-default.cmd-opts" "$(cat $TEMPLATE_DIR/tez-site-template)"

    # The Tez tarball has slf4j-api and reload4j, but not the binding. Without
    # slf4j-reload4j the ApplicationMaster swallows its startup exception.
    local tez_cp
    tez_cp=$(get_config_property "tez-site" "tez.cluster.additional.classpath.prefix")
    if [[ -n "$tez_cp" && "$tez_cp" != *"slf4j-reload4j"* ]]; then
        set_config "tez-site" "tez.cluster.additional.classpath.prefix" "/usr/odp/\${odp.version}/hadoop/lib/slf4j-reload4j-1.7.36.jar:${tez_cp}"
    fi

    set_config "hive-site" "jvm_flags" "${JVM_FLAGS_HIVE}"
    set_config "hive-env" "content" "$(cat $TEMPLATE_DIR/hive-env-template)"
    set_config "hive-site" "hive.tez.java.opts" "$(cat $TEMPLATE_DIR/hive-tez-java-opts)"
    set_config "hive-interactive-env" "llap_java_opts" "$(cat $TEMPLATE_DIR/hive-llap-java-opts)"
    set_config "hive-interactive-env" "content" "$(cat $TEMPLATE_DIR/hive-interactive-env-template)"

    # Java 8 specific configuration changes
    if [ "$JAVA_VERSION" -eq "8" ]; then
      # Remove configs
      delete_config "tez-site" "tez.am.launch.cmd-opts"
      delete_config "tez-site" "tez.task.launch.cmd-opts"
    fi

    echo -e "${GREEN}Successfully updated configurations for Tez and Hive.${NC}"
}

update_hbase_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for HBase...${NC}"

    # Push Log4j2 content as hbase-log4j2 (creates the desired config type if missing).
    # Same pattern as ZooKeeper logback / Hive-Infra JVM props via configs.py.
    set_config_from_file "hbase-log4j2" "$TEMPLATE_DIR/hbase-log4j2.xml"

    # Also refresh legacy hbase-log4j content for clusters that still use that type name.
    if [[ -f "$TEMPLATE_DIR/hbase-log4j2-template" ]]; then
      set_config "hbase-log4j" "content" "$(cat "$TEMPLATE_DIR/hbase-log4j2-template")"
    fi

    # Ambari hbase-env content already branches on java_version.
    if [ "$JAVA_VERSION" -eq "8" ] || [ "$JAVA_VERSION" -eq "11" ]; then
      set_config "hbase-env" "content" "$(cat $TEMPLATE_DIR/hbase-env-template)"
    fi

    echo -e "${GREEN}Successfully updated configurations for HBase.${NC}"
}

update_oozie_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Oozie...${NC}"

    set_config "oozie-site" "jvm_flags" "${JVM_FLAGS_OOZIE}"
    set_config "oozie-env" "content" "$(cat $TEMPLATE_DIR/oozie-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Oozie.${NC}"
}

update_kms_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Ranger KMS...${NC}"

    set_config "kms-site" "jvm_flags" "${JVM_FLAGS_KMS}"
    set_config "kms-env" "content" "$(cat $TEMPLATE_DIR/kms-env-template)"

    echo -e "${GREEN}Successfully updated configurations for Ranger KMS.${NC}"
}

update_druid_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Druid...${NC}"

    local druid_template_dir druid_opts
    druid_template_dir="$TEMPLATE_DIR"

    if [[ ! -f "${druid_template_dir}/druid-env-template" ]]; then
        record_failure "[ERROR] Druid template not found: ${druid_template_dir}/druid-env-template"
        return 1
    fi
    if [[ ! -f "${druid_template_dir}/druid-env-opts" ]]; then
        record_failure "[ERROR] Druid jvm.opts template not found: ${druid_template_dir}/druid-env-opts"
        return 1
    fi

    druid_opts="$(cat "${druid_template_dir}/druid-env-opts")"
    set_config "druid-env" "content" "$(cat "${druid_template_dir}/druid-env-template")"
    set_config "druid-env" "druid.broker.jvm.opts" "${druid_opts}"
    set_config "druid-env" "druid.coordinator.jvm.opts" "${druid_opts}"
    set_config "druid-env" "druid.historical.jvm.opts" "${druid_opts}"
    set_config "druid-env" "druid.middlemanager.jvm.opts" "${druid_opts}"
    set_config "druid-env" "druid.overlord.jvm.opts" "${druid_opts}"
    set_config "druid-env" "druid.router.jvm.opts" "${druid_opts}"

    echo -e "${GREEN}Successfully updated configurations for Druid.${NC}"
}

update_zookeeper_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for ZooKeeper...${NC}"

    # Create the complete desired config when it is missing on upgraded clusters.
    set_config_from_file "zookeeper-logback" "$TEMPLATE_DIR/zookeeper-logback.xml"

    echo -e "${GREEN}Successfully updated configurations for ZooKeeper.${NC}"
}

update_pinot_configuration_for_jdk17() {
    echo -e "${YELLOW}Starting to update configurations for Pinot...${NC}"

    local stack_java_home
    stack_java_home=$(resolve_stack_java_home)
    if [[ -z "$stack_java_home" || ! -d "$stack_java_home" ]]; then
        record_failure "[ERROR] Could not resolve stack java.home for Pinot."
        return 1
    fi

    echo -e "${GREEN}Resetting pinot-env JAVA_HOME to stack java.home: ${stack_java_home}${NC}"
    set_config "pinot-env" "JAVA_HOME" "${stack_java_home}"

    echo -e "${GREEN}Successfully updated configurations for Pinot.${NC}"
}

# Directory with the service's package/scripts as installed on the Ambari Server
# (follows the stack service symlink into the active mpack, if any).
service_scripts_dir() {
    local service=$1 svc_dir
    svc_dir=$(readlink -f "/var/lib/ambari-server/resources/stacks/ODP/3.3/services/${service}" 2>/dev/null)
    [[ -n "$svc_dir" ]] || return 0
    if [[ -d "$svc_dir/package/scripts" ]]; then
        echo "$svc_dir/package/scripts"
    elif [[ "$svc_dir" == */addon-services/* ]]; then
        # mpack layout: <mpack>/addon-services/<SVC>/<ver> -> <mpack>/common-services/<SVC>/<ver>
        local common="${svc_dir/\/addon-services\//\/common-services\/}"
        [[ -d "$common/package/scripts" ]] && echo "$common/package/scripts"
    fi
}

# Clusters installed with Ambari 3.0.0.0 have
#   export SERVER_JVMFLAGS="{{zk_server_jvm_heap_flags}}"
# in zookeeper-env. Ambari 3.0.1.x ZooKeeper scripts define zk_server_heapsize_flags
# instead, so ZooKeeper restarts fail to render the template during the upgrade.
# Run after the Ambari Server upgrade and before resuming the stack upgrade.
update_zookeeper_heap_flags_variable() {
    echo -e "${YELLOW}Checking zookeeper-env heap flags variable...${NC}"

    local scripts content
    scripts=$(service_scripts_dir ZOOKEEPER)
    if [[ -z "$scripts" ]]; then
        echo -e "${YELLOW}[SKIP] ZooKeeper scripts not found on this Ambari Server.${NC}"
        return 0
    fi
    if grep -qE '^\s*zk_server_jvm_heap_flags\s*=' "$scripts"/*.py; then
        echo -e "${GREEN}[SKIP] Installed ZooKeeper scripts still define zk_server_jvm_heap_flags; nothing to change.${NC}"
        return 0
    fi
    if ! grep -qE '^\s*zk_server_heapsize_flags\s*=' "$scripts"/*.py; then
        echo -e "${YELLOW}[SKIP] Installed ZooKeeper scripts define neither variable; upgrade Ambari Server first.${NC}"
        return 0
    fi

    content=$(get_config_property "zookeeper-env" "content") || { record_failure "Could not read zookeeper-env."; return 1; }
    if [[ "$content" != *'{{zk_server_jvm_heap_flags}}'* ]]; then
        echo -e "${GREEN}[SKIP] zookeeper-env does not use zk_server_jvm_heap_flags.${NC}"
        return 0
    fi

    local old_var='{{zk_server_jvm_heap_flags}}' new_var='{{zk_server_heapsize_flags}}'
    local new_content
    new_content=${content//"$old_var"/$new_var}
    set_config "zookeeper-env" "content" "$new_content"
}

# The Kafka3 3.3.6.6 mpack no longer defines cc_heapsize in params.py, but clusters
# upgraded from an older mpack keep
#   export KAFKA_HEAP_OPTS="-Xms{{cc_heapsize}} -Xmx{{cc_heapsize}}"
# in cruise-control3-env. It renders as "-Xms -Xmx" and Cruise Control fails with
# "Invalid initial heap size: -Xms". Write the configured value into the template.
# Run after the mpack upgrade.
update_cruise_control_heap() {
    echo -e "${YELLOW}Checking cruise-control3-env heap settings...${NC}"

    if ! config_type_present "cruise-control3-env"; then
        echo -e "${GREEN}[SKIP] Cruise Control (Kafka3) is not installed.${NC}"
        return 0
    fi

    local scripts content heap
    scripts=$(service_scripts_dir KAFKA3)
    if [[ -n "$scripts" ]] && grep -qE '^\s*cc_heapsize\s*=' "$scripts"/*.py; then
        echo -e "${GREEN}[SKIP] Installed Kafka3 scripts define cc_heapsize; nothing to change.${NC}"
        return 0
    fi

    content=$(get_config_property "cruise-control3-env" "content") || { record_failure "Could not read cruise-control3-env."; return 1; }
    if [[ "$content" != *'{{cc_heapsize}}'* ]]; then
        echo -e "${GREEN}[SKIP] cruise-control3-env does not use {{cc_heapsize}}.${NC}"
        return 0
    fi

    heap=$(get_config_property "cruise-control3-env" "cc_heapsize")
    heap="${heap//[[:space:]]/}"
    heap="${heap:-1024m}"
    [[ "$heap" =~ ^[0-9]+$ ]] && heap="${heap}m"

    echo -e "${GREEN}Setting Cruise Control heap to ${heap} in cruise-control3-env content.${NC}"
    local cc_var='{{cc_heapsize}}'
    local new_content
    new_content=${content//"$cc_var"/$heap}
    set_config "cruise-control3-env" "content" "$new_content"
}

# Spark clients must use the same shuffle service name and port that the
# NodeManagers register (spark_shuffle_355 on 7335 in ODP 3.3.6.6). Older
# clusters still have spark3_shuffle / 7447 in spark3-defaults. This only matters
# for jobs with spark.shuffle.service.enabled=true (e.g. dynamic allocation).
update_spark3_client_shuffle_service() {
    echo -e "${YELLOW}Aligning spark3-defaults shuffle service with NodeManager (spark_shuffle_355:7335)...${NC}"

    if ! config_type_present "spark3-defaults"; then
        echo -e "${GREEN}[SKIP] Spark3 is not installed.${NC}"
        return 0
    fi

    local name port
    name=$(get_config_property "spark3-defaults" "spark.shuffle.service.name")
    port=$(get_config_property "spark3-defaults" "spark.shuffle.service.port")

    [[ "$name" == "spark_shuffle_355" ]] || set_config "spark3-defaults" "spark.shuffle.service.name" "spark_shuffle_355"
    [[ "$port" == "7335" ]] || set_config "spark3-defaults" "spark.shuffle.service.port" "7335"
}

# Patch-upgrade helpers for clusters already on JDK 17 (e.g. 3.3.6.4 -> 3.3.6.5).
run_jdk17_patch_upgrade_all() {
    update_zookeeper_configuration_for_jdk17
    update_pinot_configuration_for_jdk17
    update_yarn_spark_shuffle_isolation
    run_odp3366_upgrade_fixes
}

# Fixes for template variables that the Ambari 3.0.1.x scripts / 3.3.6.6 mpacks
# no longer define. Safe on any cluster: each check skips when not needed.
run_odp3366_upgrade_fixes() {
    update_zookeeper_heap_flags_variable
    update_cruise_control_heap
}

#---------------------------------------------------------
# Menu for Selecting Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "        ${GREEN}🚀  JDK 17 Configuration Upgrade Menu – Choose a Service${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════════╝${NC}\n"

    case "$source_jdk" in
            8)
                echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
                echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
                echo -e "${GREEN}  3)${NC} 🐝   Hive & Tez"
                echo -e "${GREEN}  4)${NC} 🐘   HBase (env + log4j2)"
                echo -e "${GREEN}  5)${NC} 🌀   Oozie"
                echo -e "${GREEN}  6)${NC} 🔑   Ranger KMS"
                echo -e "${GREEN}  7)${NC} 📊   Druid"
                echo -e "${GREEN}  8)${NC} 🦎   ZooKeeper (logback)"
                echo -e "${GREEN}  9)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN} 10)${NC} YARN Spark shuffle isolation (pre-EU)"
                echo -e "${GREEN} 11)${NC} ZooKeeper heap flags variable (Ambari 3.0.1.x)"
                echo -e "${GREEN} 12)${NC} Cruise Control heap (Kafka3 mpack 3.3.6.6)"
                ;;
            11)
                echo -e "${GREEN}  1)${NC} HDFS, YARN & MapReduce"
                echo -e "${GREEN}  2)${NC} Infra-Solr"
                echo -e "${GREEN}  3)${NC} Hive & Tez"
                echo -e "${GREEN}  4)${NC} HBase (log4j2)"
                echo -e "${GREEN}  5)${NC} Oozie"
                echo -e "${GREEN}  6)${NC} Ranger KMS"
                echo -e "${GREEN}  7)${NC} Druid"
                echo -e "${GREEN}  8)${NC} ZooKeeper (logback)"
                echo -e "${GREEN}  9)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN} 10)${NC} YARN Spark shuffle isolation (pre-EU)"
                echo -e "${GREEN} 11)${NC} ZooKeeper heap flags variable (Ambari 3.0.1.x)"
                echo -e "${GREEN} 12)${NC} Cruise Control heap (Kafka3 mpack 3.3.6.6)"
                ;;
            17)
                echo -e "${GREEN}  1)${NC} ZooKeeper (logback)"
                echo -e "${GREEN}  2)${NC} Pinot (JAVA_HOME)"
                echo -e "${GREEN}  3)${NC} YARN Spark shuffle isolation (pre-EU)"
                echo -e "${GREEN}  4)${NC} ZooKeeper heap flags variable (Ambari 3.0.1.x)"
                echo -e "${GREEN}  5)${NC} Cruise Control heap (Kafka3 mpack 3.3.6.6)"
                ;;
        esac

    if [ "$source_jdk" != "17" ]; then
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} All Services (for the brave)"
    else
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} All patch-upgrade fixes (ZooKeeper, Pinot, YARN shuffle, heap variables)"
    fi
    echo -e "${RED}  Q)${NC} ❌   Quit (no changes)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
}

handle_selection() {
    local choice="$1"
    case "$source_jdk" in
        8)
            case "$choice" in
                1) update_hdfs_configuration_for_jdk17 ;;
                2) update_infra_configuration_for_jdk17 ;;
                3) update_hive_configuration_for_jdk17 ;;
                4) update_hbase_configuration_for_jdk17 ;;
                5) update_oozie_configuration_for_jdk17 ;;
                6) update_kms_configuration_for_jdk17 ;;
                7) update_druid_configuration_for_jdk17 ;;
                8) update_zookeeper_configuration_for_jdk17 ;;
                9) update_pinot_configuration_for_jdk17 ;;
                10) update_yarn_spark_shuffle_isolation ;;
                11) update_zookeeper_heap_flags_variable ;;
                12) update_cruise_control_heap ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_hbase_configuration_for_jdk17
                    update_oozie_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_druid_configuration_for_jdk17
                    update_zookeeper_configuration_for_jdk17
                    update_pinot_configuration_for_jdk17
                    run_odp3366_upgrade_fixes
                    ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
        11)
            case "$choice" in
                1) update_hdfs_configuration_for_jdk17 ;;
                2) update_infra_configuration_for_jdk17 ;;
                3) update_hive_configuration_for_jdk17 ;;
                4) update_hbase_configuration_for_jdk17 ;;
                5) update_oozie_configuration_for_jdk17 ;;
                6) update_kms_configuration_for_jdk17 ;;
                7) update_druid_configuration_for_jdk17 ;;
                8) update_zookeeper_configuration_for_jdk17 ;;
                9) update_pinot_configuration_for_jdk17 ;;
                10) update_yarn_spark_shuffle_isolation ;;
                11) update_zookeeper_heap_flags_variable ;;
                12) update_cruise_control_heap ;;
                [Aa])
                    update_hdfs_configuration_for_jdk17
                    update_infra_configuration_for_jdk17
                    update_hive_configuration_for_jdk17
                    update_hbase_configuration_for_jdk17
                    update_oozie_configuration_for_jdk17
                    update_kms_configuration_for_jdk17
                    update_druid_configuration_for_jdk17
                    update_zookeeper_configuration_for_jdk17
                    update_pinot_configuration_for_jdk17
                    run_odp3366_upgrade_fixes
                    ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
        17)
            case "$choice" in
                1) update_zookeeper_configuration_for_jdk17 ;;
                2) update_pinot_configuration_for_jdk17 ;;
                3) update_yarn_spark_shuffle_isolation ;;
                4) update_zookeeper_heap_flags_variable ;;
                5) update_cruise_control_heap ;;
                [Aa]) run_jdk17_patch_upgrade_all ;;
                [Qq]) return 1 ;;
                *) echo -e "${RED}Invalid selection.${NC}" ;;
            esac
            ;;
    esac

    return 0
}

#---------------------------------------------------------
# Main Menu Loop
#---------------------------------------------------------
main() {
    # Detect and set migration path
    detect_source_jdk

    # Verify template directory exists
    if [[ ! -d "$TEMPLATE_DIR" ]]; then
        echo -e "${RED}Error: Template directory not found: $TEMPLATE_DIR${NC}"
        exit 1
    fi

    echo -e "${GREEN}Using templates from: $TEMPLATE_DIR${NC}\n"

    while true; do
        display_service_options
        read -rp "Enter your selection: ⇒ " choice

        handle_selection "$choice" || break
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

    if [[ $FAILURES -gt 0 ]]; then
        echo -e "${RED}Script finished with ${FAILURES} failed update(s). See ${LOG_FILE}. Fix them and run again.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Script execution completed with no failed updates.${NC}"
    echo -e "${YELLOW}Access the Ambari UI and restart the affected services to apply the changes.${NC}"
}

# Run main function
main