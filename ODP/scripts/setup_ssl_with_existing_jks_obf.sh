#!/bin/bash
##########################################################################
# Acceldata Inc. | ODP
#
# SSL Configuration Script for Hadoop Services
# Enables SSL for various Hadoop-related services using existing JKS keystores.
#
# Password Obfuscation:
#   Set ENABLE_PASSWORD_OBFUSCATION=true to use Jetty Password utility for
#   obfuscated passwords (OBF: format). Supported components:
#   - HDFS/YARN/MapReduce, Infra-Solr, HBase, Schema Registry
#   Other components always use plaintext passwords.
#   Note: Password obfuscation is supported from ODP version 3.3.6.2-1 onwards.
#
# Environment Variables:
#   ENABLE_PASSWORD_OBFUSCATION - Enable password obfuscation (default: false)
#   CHECK_FILES                 - Validate keystore/truststore files (default: true)
#
# Usage:
#   ENABLE_PASSWORD_OBFUSCATION=true CHECK_FILES=false ./setup_ssl_with_existing_jks_obf.sh
##########################################################################
#---------------------------------------------------------
# Default Values (Edit these if required)
#---------------------------------------------------------
AMBARISERVER=$(hostname -f)
USER="admin"
PASSWORD="admin"
PORT=8080
PROTOCOL="http"  # Change to "https" if Ambari Server is configured with SSL

# Keystore and Truststore details (JKS format)
keystorepassword="changeit"
truststorepassword="changeit"
keystore="/opt/security/pki/keystore.jks"
truststore="/opt/security/pki/truststore.jks"

# File validation flag (set to "false" to skip file existence checks)
CHECK_FILES="${CHECK_FILES:-true}"  # Default: true (check files)

# Password obfuscation support
ENABLE_PASSWORD_OBFUSCATION="${ENABLE_PASSWORD_OBFUSCATION:-false}"  # Default: false (no obfuscation)
ODP_BASE_DIR="${ODP_BASE_DIR:-/usr/odp/current}"  # ODP base directory
# Use the same directory as keystore/truststore for obfuscated passwords
if [[ -z "${OBFUSCATED_PASSWORD_DIR}" ]]; then
    OBFUSCATED_PASSWORD_DIR="$(dirname "$keystore")"
fi
# Variables to store obfuscated passwords (set when obfuscation is enabled)
KEYSTORE_PASSWORD_OBF=""
TRUSTSTORE_PASSWORD_OBF=""

# Ensure that the keystore alias for the 
# ranger.service.https.attrib.keystore.keyalias property is correctly configured. By default, it is set to the Ranger and KMS node's hostname.
# To verify, log in to the Ranger node and run:
#   keytool -list -keystore $keystore
#---------------------------------------------------------
# Color codes for output formatting
#---------------------------------------------------------
GREEN='\e[32m'
YELLOW='\e[33m'
RED='\e[31m'
CYAN='\e[36m'
NC='\e[0m'  # No Color

#---------------------------------------------------------
# Handles SSL certificate verification failures and guides user for resolution
#---------------------------------------------------------
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
        echo -e "The Ambari server's SSL configuration only includes its own certificate without intermediate or root CA."
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
                echo -e "${RED}[ERROR] 'update-ca-trust' command not found. Please install the 'ca-certificates' package and rerun this script.${NC}"
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

#---------------------------------------------------------
# Password Obfuscation Functions
#---------------------------------------------------------
# Find jetty-util jar file
find_jetty_util_jar() {
    local jetty_jar
    jetty_jar=$(find "${ODP_BASE_DIR}/hadoop-client/lib" -iname 'jetty-util-*.jar' 2>/dev/null | grep -v ajax | head -n 1)
    
    if [[ -z "$jetty_jar" || ! -f "$jetty_jar" ]]; then
        echo -e "${RED}[ERROR]${NC} jetty-util jar not found in ${ODP_BASE_DIR}/hadoop-client/lib" >&2
        return 1
    fi
    
    echo "$jetty_jar"
}

# Obfuscate a password using Jetty Password utility
obfuscate_password() {
    local password="$1"
    local jetty_jar
    local java_output
    local obf_output
    
    if ! jetty_jar=$(find_jetty_util_jar); then
        return 1
    fi
    
    # Change to ODP base directory and run Jetty Password utility
    # Capture both stdout and stderr to show actual errors
    local current_dir
    current_dir=$(pwd)
    
    if [[ ! -d "$ODP_BASE_DIR" ]]; then
        echo -e "${RED}[ERROR]${NC} ODP base directory not found: $ODP_BASE_DIR" >&2
        return 1
    fi
    
    # Run from ODP base directory to ensure proper classpath resolution
    cd "$ODP_BASE_DIR" || {
        echo -e "${RED}[ERROR]${NC} Failed to change directory to $ODP_BASE_DIR" >&2
        return 1
    }
    
    # Capture both stdout and stderr
    java_output=$(java -cp "$jetty_jar" org.eclipse.jetty.util.security.Password "$password" 2>&1)
    local java_exit_code=$?
    
    # Return to original directory
    cd "$current_dir" || true
    
    if [[ $java_exit_code -ne 0 ]]; then
        echo -e "${RED}[ERROR]${NC} Failed to obfuscate password" >&2
        echo -e "${RED}Java command failed with exit code: $java_exit_code${NC}" >&2
        echo -e "${RED}Error output:${NC}" >&2
        echo "$java_output" >&2
        return 1
    fi
    
    # Extract OBF: line from output
    obf_output=$(echo "$java_output" | grep -E "^OBF:" | head -n 1)
    
    if [[ -z "$obf_output" ]]; then
        echo -e "${RED}[ERROR]${NC} Failed to obfuscate password - no OBF: output found" >&2
        echo -e "${RED}Java output:${NC}" >&2
        echo "$java_output" >&2
        return 1
    fi
    
    echo "$obf_output"
}

# Initialize password obfuscation
initialize_password_obfuscation() {
    if [[ "${ENABLE_PASSWORD_OBFUSCATION,,}" != "true" ]]; then
        return 0
    fi
    
    echo -e "${YELLOW}🔐 Password obfuscation is enabled. Generating obfuscated passwords...${NC}"
    
    # Create directory for obfuscated passwords
    mkdir -p "$OBFUSCATED_PASSWORD_DIR"
    
    # Always regenerate obfuscated passwords
    local keystore_obf_file="${OBFUSCATED_PASSWORD_DIR}/keystorepassword.obf"
    local truststore_obf_file="${OBFUSCATED_PASSWORD_DIR}/truststorepassword.obf"
    
    # Obfuscate keystore password (using original keystorepassword from line 40)
    echo -e "${CYAN}Obfuscating keystore password...${NC}"
    local keystore_obf
    if ! keystore_obf=$(obfuscate_password "$keystorepassword"); then
        echo -e "${RED}[ERROR]${NC} Failed to obfuscate keystore password. Disabling obfuscation."
        ENABLE_PASSWORD_OBFUSCATION="false"
        return 1
    fi
    
    # Obfuscate truststore password (using original truststorepassword from line 41)
    echo -e "${CYAN}Obfuscating truststore password...${NC}"
    local truststore_obf
    if ! truststore_obf=$(obfuscate_password "$truststorepassword"); then
        echo -e "${RED}[ERROR]${NC} Failed to obfuscate truststore password. Disabling obfuscation."
        ENABLE_PASSWORD_OBFUSCATION="false"
        return 1
    fi
    
    # Store obfuscated passwords in files
    echo "$keystore_obf" > "$keystore_obf_file"
    echo "$truststore_obf" > "$truststore_obf_file"
    
    # Set secure permissions
    chmod 600 "$keystore_obf_file" "$truststore_obf_file" 2>/dev/null
    
    # Store obfuscated passwords in variables (keep original keystorepassword/truststorepassword unchanged)
    KEYSTORE_PASSWORD_OBF="$keystore_obf"
    TRUSTSTORE_PASSWORD_OBF="$truststore_obf"
    
    echo -e "${GREEN}✅ Obfuscated passwords generated and stored:${NC}"
    echo -e "   Keystore: ${keystore_obf_file}"
    echo -e "   Truststore: ${truststore_obf_file}"
    echo ""
}

#---------------------------------------------------------
# Helper function: Get password (obfuscated or plaintext)
# Returns obfuscated password if ENABLE_PASSWORD_OBFUSCATION is true,
# otherwise returns plaintext password from original variables (lines 40-41)
#---------------------------------------------------------
get_keystore_password() {
    if [[ "${ENABLE_PASSWORD_OBFUSCATION,,}" == "true" ]]; then
        echo "$KEYSTORE_PASSWORD_OBF"  # Obfuscated password with OBF: prefix
    else
        echo "$keystorepassword"  # Original plaintext password from line 40
    fi
}

get_truststore_password() {
    if [[ "${ENABLE_PASSWORD_OBFUSCATION,,}" == "true" ]]; then
        echo "$TRUSTSTORE_PASSWORD_OBF"  # Obfuscated password with OBF: prefix
    else
        echo "$truststorepassword"  # Original plaintext password from line 41
    fi
}

#---------------------------------------------------------
# Ambari SSL Certificate Handling (if HTTPS enabled)
#---------------------------------------------------------
if [[ "${PROTOCOL,,}" == "https" ]]; then
    AMBARI_CERT_PATH="/tmp/ambari.crt"
    if openssl s_client -showcerts -connect "${AMBARISERVER}:${PORT}" </dev/null 2>/dev/null \
        | openssl x509 -outform PEM > "${AMBARI_CERT_PATH}" && [[ -s "${AMBARI_CERT_PATH}" ]]; then
        export REQUESTS_CA_BUNDLE="${AMBARI_CERT_PATH}"
    else
        handle_ssl_failure "Could not obtain Ambari SSL certificate"
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

# Initialize password obfuscation if enabled
initialize_password_obfuscation

echo -e "${GREEN}==========================================================${NC}"
echo -e "${GREEN}              Acceldata ODP SSL Configuration Script        ${NC}"
echo -e "${GREEN}===========================================================${NC}"
# Validate essential variables and files before starting (if CHECK_FILES is true)
if [[ "${CHECK_FILES,,}" == "true" ]]; then
    required_files=("$keystore" "$truststore" )
    for file in "${required_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            echo -e "${RED}Error:${NC} Required file '$file' not found. Please check before proceeding."
            echo -e "${YELLOW}To disable this check, set:${NC} CHECK_FILES=false"
            echo -e "${YELLOW}Example:${NC} CHECK_FILES=false bash setup_ssl_with_existing_jks_obf.sh"
            exit 1
        fi
    done
    echo -e "${YELLOW}✅ All required keystore and truststore files are present.${NC}"
else
    echo -e "${YELLOW}⚠️  File existence check is disabled (CHECK_FILES=false).${NC}"
fi
echo -e "${YELLOW}🔑 Please ensure that you have set all variables correctly.${NC}\n"
echo -e "⚙️ ${GREEN}AMBARISERVER:${NC} $AMBARISERVER"
echo -e "👤 ${GREEN}USER:${NC} $USER"
#echo -e "🔒 ${GREEN}PASSWORD:${NC} ******** (hidden for security)"
echo -e "🌐 ${GREEN}PORT:${NC} $PORT"
echo -e "🌐 ${GREEN}PROTOCOL:${NC} $PROTOCOL"
echo -e "🔐 ${GREEN}keystore:${NC} $keystore"
echo -e "🔐 ${GREEN}truststore:${NC} $truststore"
if [[ "${ENABLE_PASSWORD_OBFUSCATION,,}" == "true" ]]; then
    echo -e "🔒 ${GREEN}Password Obfuscation:${NC} ${YELLOW}ENABLED${NC}"
    echo -e "   ${CYAN}Obfuscated passwords stored in:${NC} $OBFUSCATED_PASSWORD_DIR"
    echo -e "   ${CYAN}Keystore password:${NC} ${keystorepassword:0:20}... (obfuscated)"
    echo -e "   ${CYAN}Truststore password:${NC} ${truststorepassword:0:20}... (obfuscated)"
else
    echo -e "🔒 ${GREEN}Password Obfuscation:${NC} ${YELLOW}DISABLED${NC}"
    #echo -e "🔐 ${GREEN}keystorepassword:${NC} ********"
    #echo -e "🔐 ${GREEN}truststorepassword:${NC} ********"
fi
echo -e "${YELLOW}ℹ️ Verify the keystore alias for Ranger and KMS nodes matches the configured alias \n (ranger.service.https.attrib.keystore.keyalias - default: host FQDN).${NC}"
echo -e "${GREEN}keytool -list -keystore \"$keystore\"${NC}"
#echo -e "${GREEN}────────────────────────────────────────────────────────${NC}"
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
    
    # Get passwords (obfuscated or plaintext based on ENABLE_PASSWORD_OBFUSCATION)
    local keystore_pass
    local truststore_pass
    keystore_pass=$(get_keystore_password)
    truststore_pass=$(get_truststore_password)
    
    set_config "core-site" "hadoop.ssl.require.client.cert" "false"
    set_config "core-site" "hadoop.ssl.hostname.verifier" "DEFAULT"
    set_config "core-site" "hadoop.ssl.keystores.factory.class" "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"
    set_config "core-site" "hadoop.ssl.server.conf" "ssl-server.xml"
    set_config "core-site" "hadoop.ssl.client.conf" "ssl-client.xml"
    set_config "hdfs-site" "dfs.namenode.https-address" "0.0.0.0:50470"
    set_config "hdfs-site" "dfs.namenode.secondary.https-address" "0.0.0.0:50091"
    # Use obfuscated passwords if ENABLE_PASSWORD_OBFUSCATION is true
    set_config "ssl-server" "ssl.server.keystore.keypassword" "$keystore_pass"
    set_config "ssl-server" "ssl.server.keystore.password" "$keystore_pass"
    set_config "ssl-server" "ssl.server.keystore.location" "$keystore"
    set_config "ssl-server" "ssl.server.truststore.location" "$truststore"
    set_config "ssl-server" "ssl.server.truststore.password" "$truststore_pass"
    set_config "ssl-client" "ssl.client.keystore.location" "$keystore"
    set_config "ssl-client" "ssl.client.keystore.password" "$keystore_pass"
    set_config "ssl-client" "ssl.client.truststore.location" "$truststore"
    set_config "ssl-client" "ssl.client.truststore.password" "$truststore_pass"
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
    
    # Get passwords (obfuscated or plaintext based on ENABLE_PASSWORD_OBFUSCATION)
    local keystore_pass
    local truststore_pass
    keystore_pass=$(get_keystore_password)
    truststore_pass=$(get_truststore_password)
    
    set_config "infra-solr-env" "infra_solr_ssl_enabled" "true"
    set_config "infra-solr-env" "infra_solr_keystore_location" "$keystore"
    # Use obfuscated passwords if ENABLE_PASSWORD_OBFUSCATION is true
    set_config "infra-solr-env" "infra_solr_keystore_password" "$keystore_pass"
    set_config "infra-solr-env" "infra_solr_keystore_type" "jks"
    set_config "infra-solr-env" "infra_solr_truststore_location" "$truststore"
    set_config "infra-solr-env" "infra_solr_truststore_password" "$truststore_pass"
    set_config "infra-solr-env" "infra_solr_truststore_type" "jks"
    set_config "infra-solr-env" "infra_solr_extra_java_opts" "-Dsolr.jetty.keystore.type=jks -Dsolr.jetty.truststore.type=jks" 
    set_config "ranger-admin-site" "ranger.truststore.file" "$truststore"
    set_config "ranger-admin-site" "ranger.truststore.password" "$truststorepassword"    
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
    set_config "ranger-trino-policymgr-ssl" "xasecure.policymgr.clientssl.keystore" "$keystore"
    set_config "ranger-trino-policymgr-ssl" "xasecure.policymgr.clientssl.keystore.password" "$keystorepassword"
    set_config "ranger-trino-policymgr-ssl" "xasecure.policymgr.clientssl.truststore" "$truststore"
    set_config "ranger-trino-policymgr-ssl" "xasecure.policymgr.clientssl.truststore.password" "$truststorepassword"
    set_config "ranger-trino-security" "ranger.plugin.trino.policy.rest.url" "https://$rangeradmin:6182" 
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
    
    # Get passwords (obfuscated or plaintext based on ENABLE_PASSWORD_OBFUSCATION)
    local keystore_pass
    keystore_pass=$(get_keystore_password)
    
    set_config "hbase-site" "hbase.ssl.enabled" "true"
    set_config "hbase-site" "hadoop.ssl.enabled" "true"
    # Use obfuscated passwords if ENABLE_PASSWORD_OBFUSCATION is true
    set_config "hbase-site" "ssl.server.keystore.keypassword" "$keystore_pass"
    set_config "hbase-site" "ssl.server.keystore.password" "$keystore_pass"
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

#---------------------------------------------------------
# NiFi Registry SSL enablement
#---------------------------------------------------------
enable_nifi_registry_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for NiFi Registry ...${NC}"    
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.ssl.isenabled" "true"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.keystore" "$keystore"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.keyPasswd" "$keystorepassword"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.keystorePasswd" "$keystorepassword"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.needClientAuth" "false"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.truststore" "$truststore"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.truststorePasswd" "$truststorepassword"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.keystoreType" "jks"
    set_config "nifi-registry-ambari-ssl-config" "nifi.registry.security.truststoreType" "jks"
    echo -e "${GREEN}Successfully enabled SSL for NiFi Registry.${NC}"
}

enable_schema_registry () {
    echo -e "${YELLOW}Starting to enable SSL for Schema Registry ...${NC}"
    
    # Get passwords (obfuscated or plaintext based on ENABLE_PASSWORD_OBFUSCATION)
    local keystore_pass
    local truststore_pass
    keystore_pass=$(get_keystore_password)
    truststore_pass=$(get_truststore_password)
    
    set_config "registry-ssl-config" "registry.ssl.isenabled" "true"
    set_config "registry-ssl-config" "registry.keyStoreType" "jks"
    set_config "registry-ssl-config" "registry.trustStoreType" "jks"
    set_config "registry-ssl-config" "registry.keyStorePath" "$keystore"
    set_config "registry-ssl-config" "registry.trustStorePath" "$truststore"
    # Use obfuscated passwords if ENABLE_PASSWORD_OBFUSCATION is true
    set_config "registry-ssl-config" "registry.keyStorePassword" "$keystore_pass"
    set_config "registry-ssl-config" "registry.trustStorePassword" "$truststore_pass"
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

enable_trino_ssl () {
    echo -e "${YELLOW}Starting to enable SSL for Trino...${NC}"
    set_config "trino-env" "ssl_enabled" "true"
    set_config "trino-env" "ssl_keystore" "$keystore"
    set_config "trino-env" "ssl_keystore_password" "$keystorepassword"
    set_config "trino-env" "java_truststore" "$truststore"
    set_config "trino-env" "java_truststore_password" "$truststorepassword"
    echo -e "${GREEN}Successfully enabled SSL for Trino.${NC}"
}

#---------------------------------------------------------
# Ambari Server Truststore Setup
#---------------------------------------------------------
enable_ambari_server_truststore() {
    echo -e "${YELLOW}Starting to configure Ambari Server truststore...${NC}"
    
    # Check if ambari-server command exists
    if ! command -v ambari-server >/dev/null 2>&1; then
        echo -e "${RED}[ERROR]${NC} ambari-server command not found. Please ensure Ambari Server is installed."
        return 1
    fi
    
    # Check if truststore file exists
    if [[ ! -f "$truststore" ]]; then
        echo -e "${RED}[ERROR]${NC} Truststore file not found: $truststore"
        return 1
    fi
    
    # Use plaintext password (not obfuscated) for ambari-server setup-security command
    local truststore_pass="$truststorepassword"
    
    echo -e "${CYAN}Configuring Ambari Server truststore...${NC}"
    echo -e "${CYAN}Truststore path:${NC} $truststore"
    echo -e "${CYAN}Truststore type:${NC} jks"
    echo ""
    
    # Run ambari-server setup-security command
    if ambari-server setup-security \
        --security-option=setup-truststore \
        --truststore-type=jks \
        --truststore-path="$truststore" \
        --truststore-password="$truststore_pass" \
        --truststore-reconfigure; then
        echo -e "${GREEN}✅ Ambari Server truststore configured successfully.${NC}"
        echo ""
        echo -e "${YELLOW}⚠️  IMPORTANT:${NC} You need to restart Ambari Server for the changes to take effect."
        echo ""
        read -p "Do you want to restart Ambari Server now? (yes/no): " restart_choice
        if [[ "${restart_choice,,}" == "yes" ]]; then
            echo -e "${CYAN}Restarting Ambari Server...${NC}"
            if ambari-server restart; then
                echo -e "${GREEN}✅ Ambari Server restarted successfully.${NC}"
            else
                echo -e "${RED}[ERROR]${NC} Failed to restart Ambari Server. Please restart manually."
                echo -e "${YELLOW}Run:${NC} ambari-server restart"
            fi
        else
            echo -e "${YELLOW}Please restart Ambari Server manually when ready:${NC}"
            echo -e "${GREEN}ambari-server restart${NC}"
        fi
    else
        echo -e "${RED}[ERROR]${NC} Failed to configure Ambari Server truststore."
        return 1
    fi
}

#---------------------------------------------------------
# Menu for Selecting SSL Configuration Services
#---------------------------------------------------------
display_service_options() {
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "        ${GREEN}🚀  SSL Configuration Menu – Choose a Service${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════╝${NC}\n"
    echo -e "${GREEN}  1)${NC} 🗃️   HDFS, YARN & MapReduce"
    echo -e "${GREEN}  2)${NC} 🔍   Infra-Solr"
    echo -e "${GREEN}  3)${NC} 🐝   Hive"
    echo -e "${GREEN}  4)${NC} 🛡️   Ranger"
    echo -e "${GREEN}  5)${NC} ✨   Spark2"
    echo -e "${GREEN}  6)${NC} 📡   Kafka"
    echo -e "${GREEN}  7)${NC} 📚   HBase"
    echo -e "${GREEN}  8)${NC} ⚡   Spark3"
    echo -e "${GREEN}  9)${NC} 🌀   Oozie"
    echo -e "${GREEN} 10)${NC} 🔑   Ranger KMS"
    echo -e "${GREEN} 11)${NC} ☁️   Ozone"
    echo -e "${GREEN} 12)${NC} ⚙️   NiFi"
    echo -e "${GREEN} 13)${NC} 🔄   Schema Registry"
    echo -e "${GREEN} 14)${NC} 🔬   Livy2"
    echo -e "${GREEN} 15)${NC} 📡   Kafka3"
    echo -e "${GREEN} 16)${NC} 🧪   Livy3"
    echo -e "${GREEN} 17)${NC} 📝   NiFi Registry"
    echo -e "${GREEN} 18)${NC} 🚀   Trino"
    echo -e "${GREEN} 19)${NC} 🖥️   Ambari Server Truststore"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
    echo -e "${GREEN}  A)${NC} 🌐   All Services (for the brave)"
    echo -e "${RED}  Q)${NC} ❌   Quit (no changes)"
    echo -e "${YELLOW}────────────────────────────────────────────────────────────${NC}"
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
        17) enable_nifi_registry_ssl ;;
        18) enable_trino_ssl ;;
        19) enable_ambari_server_truststore ;;
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
            enable_nifi_registry_ssl
            enable_schema_registry
            enable_livy2_ssl
            enable_livy3_ssl
            enable_kafka3_ssl
            enable_trino_ssl
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
