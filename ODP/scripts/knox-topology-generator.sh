#!/bin/bash
# Acceldata Inc.
#
# Copyright (c) 2025 Acceldata Inc.
# All rights reserved.
#
# Description:
#   This script generates Knox Gateway topology XML files for ODP clusters.
#   It supports two topology types:
#   1. SSO Proxy Topology (odp-proxy-sso.xml) - Uses SSOCookieProvider for federated authentication
#   2. API Proxy Topology (odp-proxy.xml) - Uses ShiroProvider with LDAP for API authentication
#
#   The script fetches service configurations from Ambari, determines SSL/HTTPS settings,
#   retrieves host information, and generates topology XML files accordingly.
#
#   Additional features:
#   - Import TLS certificates to Knox Java cacerts
#   - Create truststore files from TLS endpoints
#
# Usage:
#   ./knox-topology-generator.sh
#
#   The script will prompt you to select one of the following options:
#   1. Generate SSO Proxy Topology (for UI access with SSO cookies)
#   2. Generate API Proxy Topology (for API access with LDAP/Basic auth)
#   3. Generate Both Topologies
#   4. Import TLS Certificate to Knox Java cacerts
#   5. Create Knox Truststore from TLS endpoint
#
IFS=$'\n\t'

#---------------------------
# Function to Get Ambari Server Hostname
#---------------------------
get_ambari_server_hostname() {
    local hostname_value
    hostname_value=$(grep -E "^hostname\s*=" /etc/ambari-agent/conf/ambari-agent.ini 2>/dev/null | sed 's/^hostname\s*=\s*//' | tr -d '[:space:]')
    [[ -n "${hostname_value}" ]] && echo "${hostname_value}" && return 0
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost"
}

#---------------------------
# Configuration Variables
#---------------------------
# NOTE: Update these variables with your environment-specific values before running the script
#
# Ambari Server Configuration
# These variables define the connection details for the Ambari server
AMBARI_SERVER=$(get_ambari_server_hostname)      # Ambari server hostname or IP address
AMBARI_USER="admin"               # Ambari admin username
AMBARI_PASSWORD="admin"           # Ambari admin password
AMBARI_PORT=8080                  # Ambari server port (default: 8080 for HTTP, 8443 for HTTPS)
AMBARI_PROTOCOL="http"            # Protocol to use: "http" or "https"

# LDAP Configuration
# These variables configure LDAP authentication for the API Proxy Topology (ShiroProvider)
# NOTE: LDAP configuration is only used for the API Proxy Topology, not for SSO Proxy Topology
LDAP_HOST="10.100.8.85"                              # LDAP server hostname or IP address
LDAP_PROTOCOL="ldap"                                  # Protocol: "ldap" or "ldaps" (for secure connections)
LDAP_PORT=33389                                       # LDAP server port
LDAP_URL="${LDAP_PROTOCOL}://${LDAP_HOST}:${LDAP_PORT}"  # Full LDAP URL
LDAP_BIND_USER="uid=admin,ou=people,dc=hadoop,dc=apache,dc=org"  # LDAP bind DN for authentication
LDAP_BIND_PASSWORD="admin-password"                   # LDAP bind password
LDAP_BASE_DN="dc=hadoop,dc=apache,dc=org"            # Base DN for LDAP searches
LDAP_USER_SEARCH_BASE="ou=people,dc=hadoop,dc=apache,dc=org"  # Base DN for user searches
LDAP_GROUP_SEARCH_BASE="ou=groups,dc=hadoop,dc=apache,dc=org" # Base DN for group searches
LDAP_USER_OBJECT_CLASS="person"                       # LDAP object class for users
LDAP_USER_SEARCH_ATTRIBUTE="uid"                      # LDAP attribute used for user search
LDAP_GROUP_OBJECT_CLASS="groupofnames"                # LDAP object class for groups
LDAP_GROUP_ID_ATTRIBUTE="cn"                          # LDAP attribute for group identifier
LDAP_MEMBER_ATTRIBUTE="member"                        # LDAP attribute for group membership
LDAP_USER_SEARCH_FILTER="(&amp;(objectclass=${LDAP_USER_OBJECT_CLASS})(${LDAP_USER_SEARCH_ATTRIBUTE}={0}))"  # User search filter template
LDAP_GROUP_SEARCH_FILTER="(&amp;(objectClass:${LDAP_GROUP_OBJECT_CLASS})(|(${LDAP_GROUP_ID_ATTRIBUTE}=*)))"  # Group search filter template

# Ranger Plugin Configuration
# Set to "true" if Ranger authorization plugin is enabled, "false" otherwise
# When enabled, uses XASecurePDPKnox for authorization; otherwise uses AclsAuthz
RANGER_PLUGIN_ENABLED="true"

# Topology File Names
# Base names for generated topology XML files (without .xml extension)
TOPOLOGY_SSO_PROXY_UI="odp-sso-proxy-ui"              # SSO Proxy Topology file name
TOPOLOGY_PROXY="odp-proxy"                            # API Proxy Topology file name

# Service Exclusion List
# List of Ambari services to exclude from topology generation (space-separated)
# These services will not appear in the generated topology files
EXCLUDED_SERVICES="HTTPFS KAFKA KAFKA3 KERBEROS KNOX MLFLOW RANGER_KMS REGISTRY SQOOP TEZ ZOOKEEPER"

#---------------------------
# Color Variables
#---------------------------
# RED: Error messages | GREEN: Success/Info messages | YELLOW: Warnings/Headers | MAGENTA: Labels | CYAN: Prompts/Highlights | NC: Reset
RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
MAGENTA="\033[1;35m"
CYAN="\033[1;36m"
NC="\033[0m"

#---------------------------
# Logging Functions
#---------------------------
# Display informational messages in green
info() {
    echo -e "${GREEN}[INFO] $*${NC}"
}

# Display error messages in red to stderr
error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
}


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

#---------------------------
# Function to Retrieve Ambari Cluster Name
#---------------------------
fetch_cluster() {
    info "Fetching Ambari cluster details..."
    local ambari_url="${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters"
    local http_code
    local curl_output
    local curl_stderr
    
    # Attempt to connect to Ambari server with timeout
    # Use a temporary file for stderr to capture connection errors
    local stderr_file
    stderr_file=$(mktemp) || {
        error "Failed to create temporary file for error capture."
        exit 1
    }
    # Capture curl output and exit code separately to handle set -e
    set +e  # Temporarily disable exit on error to capture curl exit code
    curl_output=$(curl -s -k -w "\n%{http_code}" -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -i -H 'X-Requested-By: ambari' \
      --connect-timeout 10 --max-time 30 \
      "${ambari_url}" 2>"${stderr_file}")
    local curl_exit_code=$?
    set -e  # Re-enable exit on error
    curl_stderr=$(cat "${stderr_file}" 2>/dev/null || echo "")
    rm -f "${stderr_file}" || true
    
    # Check if curl command failed
    if [[ $curl_exit_code -ne 0 ]]; then
        error "Failed to connect to Ambari server at ${ambari_url}"
        if [[ -n "$curl_stderr" ]]; then
            error "Error details: ${curl_stderr}"
        fi
        error "Curl exit code: ${curl_exit_code}"
        if [[ $curl_exit_code -eq 6 ]]; then
            error "Could not resolve host: ${AMBARI_SERVER}"
            error "Please verify that:"
            error "  1. AMBARI_SERVER is set to the correct hostname/IP (currently: ${AMBARI_SERVER})"
            error "  2. DNS resolution is working (try: ping ${AMBARI_SERVER})"
            error "  3. Network connectivity is available"
        elif [[ $curl_exit_code -eq 7 ]]; then
            error "Failed to connect to ${AMBARI_SERVER}:${AMBARI_PORT}"
            error "Please verify that:"
            error "  1. AMBARI_SERVER is set to the correct hostname/IP (currently: ${AMBARI_SERVER})"
            error "  2. AMBARI_PORT is correct (currently: ${AMBARI_PORT})"
            error "  3. Ambari server is running and accessible from this node"
            error "  4. Firewall rules allow connection to ${AMBARI_SERVER}:${AMBARI_PORT}"
        elif [[ $curl_exit_code -eq 28 ]]; then
            error "Connection timeout after 30 seconds."
            error "Ambari server at ${AMBARI_SERVER}:${AMBARI_PORT} may be unreachable or slow to respond."
            error "Please verify network connectivity and Ambari server status."
        else
            error "Connection error (exit code: ${curl_exit_code})."
            error "Please check network connectivity and Ambari server status."
        fi
        exit 1
    fi
    
    # Check if curl_output is empty (shouldn't happen with -w flag, but be safe)
    if [[ -z "$curl_output" ]]; then
        error "Received empty response from Ambari server."
        error "Please verify that Ambari server is running and accessible."
        exit 1
    fi
    
    # Extract HTTP status code (last line)
    http_code=$(echo "$curl_output" | tail -n 1 | tr -d '\r\n')
    
    # Check if we got a valid HTTP code
    if [[ -z "$http_code" ]] || ! [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        error "Failed to extract HTTP status code from Ambari response."
        error "Response may be malformed. First 500 chars of response:"
        echo "$curl_output" | head -c 500
        echo ""
        exit 1
    fi
    
    # Check HTTP status code
    if [[ "$http_code" != "200" ]]; then
        error "Failed to retrieve cluster information from Ambari server"
        error "HTTP Status Code: ${http_code}"
        if [[ "$http_code" == "401" ]] || [[ "$http_code" == "403" ]]; then
            error "Authentication failed. Please verify AMBARI_USER and AMBARI_PASSWORD."
            error "Current user: ${AMBARI_USER}"
        elif [[ "$http_code" == "000" ]]; then
            error "Could not connect to Ambari server at ${AMBARI_SERVER}:${AMBARI_PORT}"
            error "Please verify that:"
            error "  1. AMBARI_SERVER is set to the correct hostname/IP (currently: ${AMBARI_SERVER})"
            error "  2. AMBARI_PORT is correct (currently: ${AMBARI_PORT})"
            error "  3. Ambari server is running and accessible from this node"
        elif [[ "$http_code" == "404" ]]; then
            error "API endpoint not found. Please verify Ambari server version and API compatibility."
        else
            error "Unexpected HTTP response (${http_code}). Please verify Ambari server configuration."
        fi
        exit 1
    fi
    
    # Extract cluster name from response (remove the HTTP status code line first)
    CLUSTER=$(echo "$curl_output" | sed '$d' | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
    
    if [[ -z "${CLUSTER}" ]]; then
        error "Failed to retrieve the cluster name from Ambari response."
        error "Ambari server responded with HTTP 200, but cluster name was not found."
        error "Response preview (first 500 chars):"
        echo "$curl_output" | sed '$d' | head -c 500
        echo ""
        error "Please verify:"
        error "  1. Ambari server is properly configured"
        error "  2. At least one cluster exists in Ambari"
        error "  3. User '${AMBARI_USER}' has permissions to view clusters"
        exit 1
    fi
}
# Fetch cluster name first so it can be shown to the user.
fetch_cluster

#---------------------------
# Function to Get Host for a Component
#---------------------------
get_host_for_component() {
  local component="$1"
  local url="${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters/${CLUSTER}/host_components?HostRoles/component_name=${component}"
  local response
  local hostname
  local curl_exit_code
  local http_code
  
  # Make the API call (capture stderr separately)
  local curl_stderr
  curl_stderr=$(mktemp) || curl_stderr=/dev/null
  response=$(curl -s -k -w "\n%{http_code}" -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -H 'X-Requested-By: ambari' \
    --connect-timeout 10 --max-time 30 \
    "${url}" 2>"${curl_stderr}")
  curl_exit_code=$?
  
  if [[ -s "${curl_stderr}" ]]; then
    # curl stderr available if needed
    :
  fi
  [[ -f "${curl_stderr}" ]] && rm -f "${curl_stderr}" 2>/dev/null || true
  
  # Check if curl succeeded
  if [[ $curl_exit_code -ne 0 ]]; then
    return 1
  fi
  
  # Extract HTTP status code (last line)
  http_code=$(echo "$response" | tail -n 1 | tr -d '\r\n')
  
  # Check HTTP status code
  if [[ "$http_code" != "200" ]]; then
    return 1
  fi
  
  # Extract hostname(s) from response (remove HTTP status code line first)
  # Return only the first hostname (use get_all_hosts_for_component if you need all hosts)
  hostname=$(echo "$response" | sed '$d' | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | head -n 1)
  
  # Return the hostname or empty if not found
  if [[ -n "$hostname" ]]; then
    echo "$hostname"
    return 0
  else
    return 1
  fi
}

#---------------------------
# Function to Get All Hosts for a Component
#---------------------------
get_all_hosts_for_component() {
  local component="$1"
  curl -s -k -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -H 'X-Requested-By: ambari' \
    --connect-timeout 10 --max-time 30 \
    "${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters/${CLUSTER}/host_components?HostRoles/component_name=${component}" \
    | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | sort -u
}

# Set width variables (adjust these as needed)
TITLE_WIDTH=93
TABLE_WIDTH=93

# Function to print a centered title line within a decorative banner
print_title() {
  local title="$1"
  local padding=$(( (TITLE_WIDTH - ${#title}) / 2 ))
  # Top border
  printf "${CYAN}╔"
  for ((i=1; i<=TITLE_WIDTH; i++)); do printf "═"; done
  printf "╗\n"
  # Title line (using spaces to center)
  printf "║%*s%s%*s║\n" "$padding" "" "$title" "$padding" ""
  # Bottom border
  printf "╚"
  for ((i=1; i<=TITLE_WIDTH; i++)); do printf "═"; done
  printf "╝${NC}\n"
}

# Function to print a configuration line within the table
print_config_line() {
  local label="$1"
  local value="$2"
  # Adjust formatting: label left-aligned with fixed width, then colon and value left-aligned
  printf "${YELLOW}║ ${MAGENTA}%-28s${YELLOW} : ${GREEN}%-$(($TABLE_WIDTH - 34))s${YELLOW} ║${NC}\n" "$label" "$value"
}

#---------------------------
# Function to Import TLS Certificate to Knox Java cacerts
#---------------------------
# Imports TLS certificate chain into the Java cacerts used by the running Knox Gateway
# This function:
#   1. Detects the Knox JVM from running processes
#   2. Determines Java version and cacerts path
#   3. Backs up the existing cacerts file
#   4. Retrieves certificate chain from the specified hostname:port
#   5. Imports all certificates with unique aliases
# Returns: 0 on success, 1 on failure
import_certificate_to_cacerts() {
    local STOREPASS="changeit"
    local DEFAULT_PORT="8443"
    local DEFAULT_HOSTNAME
    DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
    
    # User input
    echo ""
    echo -e "${CYAN}Enter the hostname of the service whose certificate you want to import to Knox Java cacerts:${NC}"
    read -p "$(echo -e "${CYAN}Hostname [${DEFAULT_HOSTNAME}]: ${NC}")" HOSTNAME
    read -p "$(echo -e "${CYAN}Port [${DEFAULT_PORT}]: ${NC}")" PORT
    
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
    PORT=${PORT:-$DEFAULT_PORT}
    
    # Fetch certificate chain first (needed for both local and remote cases)
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    local CERT_BUNDLE
    CERT_BUNDLE="${TMP_DIR}/certs.pem"
    
    info "Retrieving certificate chain from ${HOSTNAME}:${PORT} ..."
    
    openssl s_client \
        -connect "${HOSTNAME}:${PORT}" \
        -servername "${HOSTNAME}" \
        -showcerts </dev/null 2>/dev/null |
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' \
        > "$CERT_BUNDLE"
    
    if [[ ! -s "$CERT_BUNDLE" ]]; then
        error "No certificates retrieved"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # Split cert chain
    awk '
    /-----BEGIN CERTIFICATE-----/ {i++}
    {print > "'"$TMP_DIR"'/cert-" i ".pem"}
    ' "$CERT_BUNDLE"
    
    # Detect Knox JVM
    local KNOX_JAVA_BIN
    KNOX_JAVA_BIN=$(ps aux | grep '[g]ateway.jar' | awk '{print $11}' | head -1)
    
    # Check if Knox is running on this node
    if [[ -z "$KNOX_JAVA_BIN" ]] || [[ ! -x "$KNOX_JAVA_BIN" ]]; then
        # Knox is not running on this node - export certificates and provide instructions
        info "Knox Gateway is not running on this node"
        info "Exporting certificates for manual import on Knox Gateway node..."
        
        # Get Knox Gateway hostname if available
        local KNOX_HOST
        if [[ -n "${KNOX_GATEWAY:-}" ]]; then
            KNOX_HOST="$KNOX_GATEWAY"
        elif [[ -n "${CLUSTER:-}" ]]; then
            set +e
            KNOX_HOST=$(get_host_for_component "KNOX_GATEWAY" 2>/dev/null)
            set -e
        fi
        
        if [[ -z "$KNOX_HOST" ]]; then
            KNOX_HOST="<knox-gateway-hostname>"
        fi
        
        # Create certificate export file
        local CERT_EXPORT_FILE
        CERT_EXPORT_FILE="/tmp/${HOSTNAME}-${PORT}-certificates-$(date +%Y%m%d%H%M%S).pem"
        cp "$CERT_BUNDLE" "$CERT_EXPORT_FILE"
        
        # Count certificates
        local CERT_COUNT
        CERT_COUNT=$(grep -c "BEGIN CERTIFICATE" "$CERT_EXPORT_FILE" || echo "0")
        
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}Certificate Export Instructions${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "${YELLOW}Certificates have been exported to:${NC}"
        echo -e "${GREEN}  ${CERT_EXPORT_FILE}${NC}"
        echo ""
        echo -e "${YELLOW}Number of certificates: ${GREEN}${CERT_COUNT}${NC}"
        echo ""
        echo -e "${CYAN}To import certificates on Knox Gateway node (${KNOX_HOST}):${NC}"
        echo ""
        echo -e "${YELLOW}1. Copy the certificate file to Knox Gateway node:${NC}"
        echo -e "   ${GREEN}scp ${CERT_EXPORT_FILE} ${KNOX_HOST}:${CERT_EXPORT_FILE}${NC}"
        echo ""
        echo -e "${YELLOW}2. SSH to Knox Gateway node and run the keytool command:${NC}"
        echo ""
        if [[ $CERT_COUNT -gt 1 ]]; then
            echo -e "${CYAN}   Note: Certificate bundle contains ${CERT_COUNT} certificates.${NC}"
            echo -e "${CYAN}   To import all certificates, you can split them or import the bundle (imports first cert).${NC}"
            echo ""
        fi
        echo -e "${CYAN}   For Java 8:${NC}"
        echo -e "   ${GREEN}keytool -importcert -noprompt -trustcacerts -alias \"${HOSTNAME}-${PORT}\" -file ${CERT_EXPORT_FILE} -keystore \${JAVA_HOME}/jre/lib/security/cacerts -storepass changeit${NC}"
        echo ""
        echo -e "${CYAN}   For Java 11 or higher:${NC}"
        echo -e "   ${GREEN}keytool -importcert -noprompt -trustcacerts -alias \"${HOSTNAME}-${PORT}\" -file ${CERT_EXPORT_FILE} -cacerts -storepass changeit${NC}"
        echo ""
        if [[ $CERT_COUNT -gt 1 ]]; then
            echo -e "${YELLOW}   To import all ${CERT_COUNT} certificates separately, split the bundle first:${NC}"
            echo -e "${CYAN}   awk '/BEGIN CERTIFICATE/{i++}{print > \"/tmp/cert-\" i \".pem\"}' ${CERT_EXPORT_FILE}${NC}"
            echo -e "${CYAN}   Then import each /tmp/cert-*.pem file with a unique alias${NC}"
            echo ""
        fi
        echo -e "${YELLOW}Note:${NC} Replace \${JAVA_HOME} with the actual Java home path used by Knox Gateway"
        echo -e "      Default cacerts password is: ${GREEN}changeit${NC}"
        echo ""
        echo -e "${CYAN}3. Restart Knox Gateway service after importing certificates${NC}"
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""
        
        rm -rf "$TMP_DIR"
        return 0
    fi
    
    # Root check (only needed if importing directly)
    if [[ $EUID -ne 0 ]]; then
        error "Must be run as root to import certificates directly"
        return 1
    fi
    
    local JAVA_HOME
    JAVA_HOME=$(dirname "$(dirname "$KNOX_JAVA_BIN")")
    
    info "Detected Knox JVM: ${KNOX_JAVA_BIN}"
    info "Resolved JAVA_HOME: ${JAVA_HOME}"
    
    # Detect Java version
    local JAVA_VERSION_RAW
    JAVA_VERSION_RAW=$("$KNOX_JAVA_BIN" -version 2>&1 | head -1)
    local JAVA_MAJOR
    JAVA_MAJOR=$(echo "$JAVA_VERSION_RAW" | sed -E 's/.*version "([0-9]+).*/\1/')
    
    if [[ "$JAVA_MAJOR" == "1" ]]; then
        JAVA_MAJOR=8
    fi
    
    info "Detected Java version: ${JAVA_VERSION_RAW}"
    
    # Resolve cacerts path
    local CACERTS
    if [[ "$JAVA_MAJOR" -eq 8 ]]; then
        CACERTS="${JAVA_HOME}/jre/lib/security/cacerts"
    else
        CACERTS="${JAVA_HOME}/lib/security/cacerts"
    fi
    
    if [[ ! -f "$CACERTS" ]]; then
        error "cacerts not found at ${CACERTS}"
        return 1
    fi
    
    info "Using cacerts: ${CACERTS}"
    
    # Backup cacerts
    local BACKUP
    BACKUP="${CACERTS}.$(date +%Y%m%d%H%M%S).bak"
    info "Backing up cacerts: ${BACKUP}"
    cp -p "$CACERTS" "$BACKUP"
    
    # Certificates are already fetched and split in TMP_DIR above
    # Import certs (ALWAYS UNIQUE aliases)
    local IMPORTED=0
    
    for CERT in "$TMP_DIR"/cert-*.pem; do
        if openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
            local TS
            TS=$(date +%Y%m%d%H%M%S)
            local RAND
            RAND=$(openssl rand -hex 2)
            local ALIAS
            ALIAS="${HOSTNAME}-${PORT}-${TS}-${RAND}"
            
            info "Importing: ${ALIAS}"
            
            if [[ "$JAVA_MAJOR" -ge 11 ]]; then
                keytool -importcert \
                    -noprompt \
                    -trustcacerts \
                    -alias "$ALIAS" \
                    -file "$CERT" \
                    -cacerts \
                    -storepass "$STOREPASS" || true
            else
                keytool -importcert \
                    -noprompt \
                    -trustcacerts \
                    -alias "$ALIAS" \
                    -file "$CERT" \
                    -keystore "$CACERTS" \
                    -storepass "$STOREPASS" || true
            fi
            
            ((IMPORTED++))
        fi
    done
    
    # Summary
    echo ""
    info "Certificate import completed successfully"
    info "Host     : ${HOSTNAME}"
    info "Port     : ${PORT}"
    info "Java     : ${JAVA_MAJOR}"
    info "Imported : ${IMPORTED}"
    info "Keystore : ${CACERTS}"
    info "Backup   : ${BACKUP}"
    
    rm -rf "$TMP_DIR"
    
    echo ""
    info "IMPORTANT: Restart Knox to apply changes"
    echo ""
}

#---------------------------
# Function to Create Knox Truststore from TLS endpoint
#---------------------------
# Creates a Java truststore (JKS file) from a TLS endpoint's certificate chain
# This function:
#   1. Prompts for hostname and port
#   2. Retrieves certificate chain from the endpoint
#   3. Creates a new truststore file with all certificates
#   4. Lists the truststore contents
# Returns: 0 on success, 1 on failure
create_knox_truststore() {
    local TRUSTSTORE="/tmp/truststore.jks"
    local PASSWORD="changeit"
    local DEFAULT_HOSTNAME
    local DEFAULT_PORT="8443"
    
    # Use Knox Gateway host as default if available, otherwise use current hostname
    if [[ -z "$KNOX_GATEWAY" ]]; then
        # Fetch Knox Gateway host if not already set
        # Only try if CLUSTER is available (requires Ambari connection)
        if [[ -n "$CLUSTER" ]]; then
            # Try to get Knox Gateway host directly using the same logic as fetch_knox_gateway
            local all_hosts
            set +e  # Temporarily disable exit on error
            all_hosts=$(get_host_for_component "KNOX_GATEWAY" 2>&1)
            local get_host_exit_code=$?
            set -e  # Re-enable exit on error
            
            if [[ $get_host_exit_code -eq 0 ]] && [[ -n "$all_hosts" ]] && [[ "$all_hosts" != "NONE" ]]; then
                # Clean up the hostname (get_host_for_component already returns only the first one)
                DEFAULT_HOSTNAME=$(echo "$all_hosts" | tr -d '\r\n' | xargs)
            else
                # Fallback to current hostname
                DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
            fi
        else
            DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
        fi
    else
        DEFAULT_HOSTNAME="$KNOX_GATEWAY"
    fi
    
    # Ensure DEFAULT_HOSTNAME is set (fallback to localhost if all else fails)
    if [[ -z "$DEFAULT_HOSTNAME" ]]; then
        DEFAULT_HOSTNAME=$(hostname -f 2>/dev/null || hostname || echo "localhost")
    fi
    
    # User input
    echo ""
    echo -e "${CYAN}Enter the hostname of the service whose certificate you want to use to create the Knox truststore:${NC}"
    read -p "$(echo -e "${CYAN}Hostname [${DEFAULT_HOSTNAME}]: ${NC}")" HOSTNAME
    read -p "$(echo -e "${CYAN}Port [${DEFAULT_PORT}]: ${NC}")" PORT
    
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}
    PORT=${PORT:-$DEFAULT_PORT}
    
    # Create temporary directory for certificates
    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    local CERT_BUNDLE
    CERT_BUNDLE="$TMP_DIR/certs.pem"
    
    info "Retrieving certificate chain from ${HOSTNAME}:${PORT} ..."
    
    openssl s_client -connect "${HOSTNAME}:${PORT}" -servername "$HOSTNAME" -showcerts </dev/null 2>/dev/null | \
        sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' > "$CERT_BUNDLE"
    
    if [[ ! -s "$CERT_BUNDLE" ]]; then
        error "No certificates retrieved"
        rm -rf "$TMP_DIR"
        return 1
    fi
    
    # Split certificate chain into individual files
    awk '/-----BEGIN CERTIFICATE-----/{i++}{print > "'"$TMP_DIR"'/cert-" i ".pem"}' "$CERT_BUNDLE"
    
    # Remove existing truststore if it exists
    if [[ -f "$TRUSTSTORE" ]]; then
        rm -f "$TRUSTSTORE"
    fi
    
    # Import certificates into truststore
    local IMPORTED=0
    set +e  # Temporarily disable exit on error for the loop
    for CERT in "$TMP_DIR"/cert-*.pem; do
        # Check if glob matched any files
        [[ ! -e "$CERT" ]] && break
        if openssl x509 -in "$CERT" -noout >/dev/null 2>&1; then
            local ALIAS
            ALIAS="cert-$IMPORTED"
            info "Executing: keytool -importcert -noprompt -alias ${ALIAS} -file ${CERT} -keystore ${TRUSTSTORE} -storepass ${PASSWORD}"
            keytool -importcert -noprompt -alias "${ALIAS}" -file "${CERT}" -keystore "${TRUSTSTORE}" -storepass "${PASSWORD}" || true
            IMPORTED=$((IMPORTED + 1))  # Use safer arithmetic expansion
        fi
    done
    set -e  # Re-enable exit on error
    
    # Summary
    echo ""
    info "Truststore created successfully"
    info "Certs imported: ${IMPORTED}"
    
    # Clean up temp directory
    rm -rf "$TMP_DIR"
    
    # List truststore contents (with error handling)
    echo ""
    info "Listing truststore contents:"
    set +e  # Temporarily disable exit on error
    keytool -list -keystore "$TRUSTSTORE" -storepass "$PASSWORD" 2>&1
    local list_exit_code=$?
    set -e  # Re-enable exit on error
    
    if [[ $list_exit_code -ne 0 ]]; then
        error "Warning: Failed to list truststore contents, but truststore was created successfully"
    fi
    
    # Final summary with path and password (always show this)
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}Truststore Information:${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}Path    : ${GREEN}${TRUSTSTORE}${NC}"
    echo -e "${YELLOW}Password: ${GREEN}${PASSWORD}${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

clear

# Display title
echo -e "${CYAN}Knox Gateway Topology Generator${NC}"
echo ""

#---------------------------
# Topology Selection Prompt
#---------------------------
echo ""
echo -e "${CYAN}Select an option:${NC}"
echo -e "  1) Generate SSO Proxy Topology (odp-proxy-sso.xml) - For UI access with SSO cookies"
echo -e "  2) Generate API Proxy Topology (odp-proxy.xml) - For API access with LDAP/Basic auth"
echo -e "  3) Generate Both Topologies - Create both SSO and API topology files"
echo -e "  4) Import TLS Certificate to Knox Java cacerts - Import service certificate to Knox JVM trust store"
echo -e "  5) Create Knox Truststore from TLS endpoint - Generate truststore.jks file from service certificate"
echo ""
read -p "Enter your choice (1, 2, 3, 4, or 5): " topology_choice

# Initialize topology generation flags
# These flags determine which topology files will be generated
GENERATE_SSO=false  # Flag to generate SSO Proxy Topology
GENERATE_API=false  # Flag to generate API Proxy Topology

# Validate and process user selection
case "$topology_choice" in
    1)
        # Option 1: Generate SSO Proxy Topology only
        GENERATE_SSO=true
        ;;
    2)
        # Option 2: Generate API Proxy Topology only
        GENERATE_API=true
        ;;
    3)
        # Option 3: Generate both topologies
        GENERATE_SSO=true
        GENERATE_API=true
        ;;
    4)
        # Option 4: Import TLS Certificate to Knox Java cacerts
        import_certificate_to_cacerts
        exit 0
        ;;
    5)
        # Option 5: Create Knox Truststore from TLS endpoint
        create_knox_truststore
        exit 0
        ;;
    *)
        # Invalid selection - exit with error
        error "Invalid choice. Please run the script again and select 1, 2, 3, 4, or 5."
        exit 1
        ;;
esac

# If API Proxy Topology is selected (or both), display full configuration
# This allows the user to review all LDAP and configuration settings before generation
# The SSO Proxy Topology doesn't require LDAP configuration, so we skip this for SSO-only mode
if [[ "$GENERATE_API" == "true" ]]; then
    echo ""
    print_title "Configuration Summary"
    
    # Top border for configuration table
    printf "${YELLOW}╔"
    for ((i=1; i<=TABLE_WIDTH; i++)); do printf "═"; done
    printf "╗${NC}\n"
    
    # Print all configuration items
    print_config_line "AMBARI_SERVER"           "$AMBARI_SERVER"
    print_config_line "AMBARI_USER"             "$AMBARI_USER"
    print_config_line "AMBARI_PASSWORD"         "$AMBARI_PASSWORD"
    print_config_line "AMBARI_PORT"             "$AMBARI_PORT"
    print_config_line "AMBARI_PROTOCOL"         "$AMBARI_PROTOCOL"
    print_config_line "Cluster Name"            "$CLUSTER"
    print_config_line "LDAP_HOST"               "$LDAP_HOST"
    print_config_line "LDAP_PROTOCOL"           "$LDAP_PROTOCOL"
    print_config_line "LDAP_PORT"               "$LDAP_PORT"
    print_config_line "LDAP_URL"                "$LDAP_URL"
    print_config_line "LDAP_BIND_USER"          "$LDAP_BIND_USER"
    print_config_line "LDAP_BIND_PASSWORD"      "***************"
    print_config_line "LDAP_BASE_DN"            "$LDAP_BASE_DN"
    print_config_line "LDAP_USER_SEARCH_FILTER" "$LDAP_USER_SEARCH_FILTER"
    print_config_line "LDAP_GROUP_SEARCH_FILTER" "$LDAP_GROUP_SEARCH_FILTER"
    print_config_line "LDAP_USER_SEARCH_BASE"   "$LDAP_USER_SEARCH_BASE"
    print_config_line "LDAP_GROUP_SEARCH_BASE"  "$LDAP_GROUP_SEARCH_BASE"
    print_config_line "LDAP_USER_OBJECT_CLASS"  "$LDAP_USER_OBJECT_CLASS"
    print_config_line "LDAP_USER_SEARCH_ATTR"   "$LDAP_USER_SEARCH_ATTRIBUTE"
    print_config_line "LDAP_GROUP_OBJECT_CLASS" "$LDAP_GROUP_OBJECT_CLASS"
    print_config_line "LDAP_GROUP_ID_ATTR"      "$LDAP_GROUP_ID_ATTRIBUTE"
    print_config_line "LDAP_MEMBER_ATTR"        "$LDAP_MEMBER_ATTRIBUTE"
    print_config_line "RANGER_PLUGIN_ENABLED"   "$RANGER_PLUGIN_ENABLED"
    print_config_line "AUTHZ_PROVIDER"          "$([ "${RANGER_PLUGIN_ENABLED}" = "true" ] && echo "XASecurePDPKnox" || echo "AclsAuthz")"
    print_config_line "TOPOLOGY_SSO_PROXY_UI"   "$TOPOLOGY_SSO_PROXY_UI"
    print_config_line "TOPOLOGY_PROXY"          "$TOPOLOGY_PROXY"
    
    # Bottom border for configuration table
    printf "${YELLOW}╚"
    for ((i=1; i<=TABLE_WIDTH; i++)); do printf "═"; done
    printf "╝${NC}\n"
    
    echo ""
    read -p "Do you want to proceed with topology generation? (yes/no): " proceed_choice
    
    if [[ "${proceed_choice,,}" != "yes" ]]; then
        info "Topology generation cancelled by user."
        exit 0
    fi
    echo ""
fi



#---------------------------
# Function to Get Components for a Service
#---------------------------
# Maps Ambari service names to their corresponding component names
# Each service may have one or more components that need to be queried
# for host information
# Arguments:
#   $1 - Service name (e.g., HDFS, YARN, HBASE)
# Returns:
#   Component name(s) corresponding to the service, or empty string if unmapped
get_components_for_service() {
    local service="$1"
    case "${service}" in
        HDFS)
            echo "NAMENODE"
            ;;
        YARN)
            echo "RESOURCEMANAGER"
            ;;
        KUDU)
            echo "KUDU_MASTER"
            ;;
        RANGER)
            echo "RANGER_ADMIN"
            ;;
        IMPALA)
            # IMPALA is handled separately with special logic (requires multiple components)
            # IMPALA_DAEMON (single host), IMPALA_CATALOG_SERVICE and IMPALA_STATE_STORE (all hosts)
            echo ""
            ;;
        TRINO)
            echo "TRINO_COORDINATOR"
            ;;
        SPARK3)
            echo "SPARK3_JOBHISTORYSERVER"
            ;;
        OOZIE)
            echo "OOZIE_SERVER"
            ;;
        AMBARI_INFRA_SOLR)
            echo "INFRA_SOLR"
            ;;
        MAPREDUCE2)
            echo "HISTORYSERVER"
            ;;
        FLINK)
            echo "FLINK_JOBHISTORYSERVER"
            ;;
        NIFI)
            echo "NIFI_MASTER"
            ;;
        HBASE)
            echo "HBASE_MASTER"
            ;;
        HIVE)
            echo "HIVE_SERVER"
            ;;
        ZEPPELIN)
            echo "ZEPPELIN_MASTER"
            ;;
        PINOT)
            echo "PINOT_SERVER"
            ;;
        OZONE)
            echo "OZONE_RECON"
            ;;
        HUE)
            echo "HUE_SERVER"
            ;;
        KNOX)
            echo "KNOX_GATEWAY"
            ;;
        *)
            # For unmapped services, use the service name as the component name
            # This provides a fallback for services not explicitly mapped
            echo "${service}"
            ;;
    esac
}

#---------------------------
# Function to Get All Hosts for All Services
#---------------------------
# Retrieves host information for all Ambari services and their components
# This function:
#   1. Reads the list of services from /tmp/knox-services-list.txt
#   2. Maps each service to its component(s)
#   3. Fetches host information for each component
#   4. Handles special cases (e.g., KNOX gets single host, others get all hosts)
#   5. Saves service-to-host mappings to /tmp/knox-service-hosts-mapping.txt
#   6. Exports environment variables for each component's host(s)
# Returns:
#   0 on success, 1 on failure
get_hosts_for_all_services() {
    info "Discovering service hosts..."
    
    # Read services from the file if available, otherwise use AMBARI_SERVICES
    local services
    local services_file="/tmp/knox-services-list.txt"
    if [[ -f "${services_file}" ]]; then
        services=$(cat "${services_file}")
    elif [[ -n "${AMBARI_SERVICES}" ]]; then
        services="${AMBARI_SERVICES}"
    else
        error "No services list available. Please run fetch_services() first."
        return 1
    fi
    
    if [[ -z "${services}" ]]; then
        error "Services list is empty."
        return 1
    fi
    
    local hosts_file="/tmp/knox-services-hosts.txt"
    local service_hosts_file="/tmp/knox-service-hosts-mapping.txt"
    local service_hosts_vars_file="/tmp/knox-service-hosts-vars.txt"
    
    # Clear output files
    : > "${hosts_file}"
    : > "${service_hosts_file}"
    : > "${service_hosts_vars_file}"
    
    local all_hosts=""
    local service_count=0
    
    # Process each service
    while IFS= read -r service; do
        if [[ -z "$service" ]]; then
            continue
        fi
        
        # Skip IMPALA for now - handle separately at the end
        # IMPALA requires special handling with different logic for each component
        if [[ "${service}" == "IMPALA" ]]; then
            continue
        fi
        
        # Get components for this service
        local components_str
        components_str=$(get_components_for_service "${service}" | tr -d '\r\n' | xargs)
        
        if [[ -z "${components_str}" ]]; then
            continue
        fi
        
        
        # Convert to array for proper iteration
        local -a components_array
        read -ra components_array <<< "$components_str"
        
        # Check if service has multiple components
        local component_count=${#components_array[@]}
        
        if [[ $component_count -gt 1 ]]; then
            # Multiple components - get all hostnames for each component
            service_count=$((service_count + 1))
            echo "${service}:" >> "${service_hosts_file}"
            
            for component in "${components_array[@]}"; do
                local component_hosts
                set +e  # Temporarily disable exit on error
                component_hosts=$(get_all_hosts_for_component "${component}" 2>/dev/null)
                local curl_exit_code=$?
                set -e  # Re-enable exit on error
                
                # Filter out empty lines and check if we have any valid hostnames
                local filtered_hosts
                filtered_hosts=$(echo "$component_hosts" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
                
                if [[ -z "${filtered_hosts}" ]]; then
                    echo "${component}=NONE" >> "${service_hosts_file}"
                    continue
                fi
                
                # Use the filtered hosts
                component_hosts="$filtered_hosts"
                
                # Count how many hosts for this component
                local host_count
                host_count=$(echo "$component_hosts" | grep -v '^$' | wc -l | tr -d ' ')
                
                # Get first host for primary variable
                local first_host
                first_host=$(echo "$component_hosts" | head -n 1)
                
                # Export primary variable in format: COMPONENT_HOST
                local var_name="${component}_HOST"
                export "${var_name}"="$first_host"
                echo "${var_name}=${first_host}" >> "${service_hosts_vars_file}"
                
                # If multiple hosts, save all of them (comma-separated)
                if [[ $host_count -gt 1 ]]; then
                    local all_hosts_list
                    all_hosts_list=$(echo "$component_hosts" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                    echo "${component}=${all_hosts_list}" >> "${service_hosts_file}"
                    
                    # Also export as array variable for all hosts
                    local var_name_all="${component}_HOSTS"
                    export "${var_name_all}"="$all_hosts_list"
                    echo "${var_name_all}=${all_hosts_list}" >> "${service_hosts_vars_file}"
                else
                    echo "${component}=${first_host}" >> "${service_hosts_file}"
                fi
                
                # Add all hosts to all_hosts list
                while IFS= read -r host; do
                    if [[ -n "$host" ]]; then
                        all_hosts="${all_hosts}${host}"$'\n'
                    fi
                done <<< "$component_hosts"
            done
        else
            # Single component
            local hosts
            # Special handling for KNOX: get only the first hostname
            # All other services: get all hostnames for high availability
            if [[ "${service}" == "KNOX" ]]; then
                hosts=$(get_all_hosts_for_component "${components_str}" | head -n 1)
            else
                # Get all hosts for the component to support HA configurations
                hosts=$(get_all_hosts_for_component "${components_str}")
            fi
            
            if [[ -z "$hosts" ]]; then
                echo "${service}=NONE" >> "${service_hosts_file}"
                continue
            fi
            
            service_count=$((service_count + 1))
            
            # Count how many hosts we have
            local host_count
            host_count=$(echo "$hosts" | grep -v '^$' | wc -l | tr -d ' ')
            
            # Get first host for primary variable export
            local first_host
            first_host=$(echo "$hosts" | head -n 1)
            
            # Export primary variable in format: COMPONENT_HOST (component names are unique)
            local var_name="${components_str}_HOST"
            export "${var_name}"="$first_host"
            echo "${var_name}=${first_host}" >> "${service_hosts_vars_file}"
            
            # If multiple hosts, save all of them (comma-separated for mapping file)
            if [[ $host_count -gt 1 ]]; then
                local all_hosts_list
                all_hosts_list=$(echo "$hosts" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                echo "${service}=${all_hosts_list}" >> "${service_hosts_file}"
                
                # Also export as array variable for all hosts
                local var_name_all="${components_str}_HOSTS"
                export "${var_name_all}"="$all_hosts_list"
                echo "${var_name_all}=${all_hosts_list}" >> "${service_hosts_vars_file}"
            else
                echo "${service}=${first_host}" >> "${service_hosts_file}"
            fi
            
            # Add all hosts to all_hosts list
            while IFS= read -r host; do
                if [[ -n "$host" ]]; then
                    all_hosts="${all_hosts}${host}"$'\n'
                fi
            done <<< "$hosts"
        fi
        
    done <<< "$services"
    
    # Handle IMPALA separately with special logic
    # IMPALA requires different host retrieval logic for each component:
    #   - IMPALA_DAEMON: Get only ONE host
    #   - IMPALA_CATALOG_SERVICE: Get ALL hosts
    #   - IMPALA_STATE_STORE: Get ALL hosts
    if grep -q "^IMPALA$" <<< "$services"; then
        service_count=$((service_count + 1))
        echo "IMPALA:" >> "${service_hosts_file}"
        
        # IMPALA_DAEMON: Get only ONE host
        local impala_daemon_host
        set +e
        impala_daemon_host=$(get_all_hosts_for_component "IMPALA_DAEMON" 2>/dev/null | head -n 1)
        set -e
        
        if [[ -n "${impala_daemon_host}" ]]; then
            export IMPALA_DAEMON_HOST="$impala_daemon_host"
            echo "IMPALA_DAEMON_HOST=${impala_daemon_host}" >> "${service_hosts_vars_file}"
            echo "IMPALA_DAEMON=${impala_daemon_host}" >> "${service_hosts_file}"
            all_hosts="${all_hosts}${impala_daemon_host}"$'\n'
        else
            echo "IMPALA_DAEMON=NONE" >> "${service_hosts_file}"
        fi
        
        # IMPALA_CATALOG_SERVICE: Get ALL hosts
        local impala_catalog_hosts
        set +e
        impala_catalog_hosts=$(get_all_hosts_for_component "IMPALA_CATALOG_SERVICE" 2>/dev/null)
        set -e
        
        local filtered_catalog
        filtered_catalog=$(echo "$impala_catalog_hosts" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
        
        if [[ -n "${filtered_catalog}" ]]; then
            local catalog_host_count
            catalog_host_count=$(echo "$filtered_catalog" | grep -v '^$' | wc -l | tr -d ' ')
            local first_catalog_host
            first_catalog_host=$(echo "$filtered_catalog" | head -n 1)
            
            export IMPALA_CATALOG_SERVICE_HOST="$first_catalog_host"
            echo "IMPALA_CATALOG_SERVICE_HOST=${first_catalog_host}" >> "${service_hosts_vars_file}"
            
            if [[ $catalog_host_count -gt 1 ]]; then
                local catalog_hosts_list
                catalog_hosts_list=$(echo "$filtered_catalog" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                echo "IMPALA_CATALOG_SERVICE=${catalog_hosts_list}" >> "${service_hosts_file}"
                export IMPALA_CATALOG_SERVICE_HOSTS="$catalog_hosts_list"
                echo "IMPALA_CATALOG_SERVICE_HOSTS=${catalog_hosts_list}" >> "${service_hosts_vars_file}"
            else
                echo "IMPALA_CATALOG_SERVICE=${first_catalog_host}" >> "${service_hosts_file}"
            fi
            
            # Add to all_hosts
            while IFS= read -r host; do
                if [[ -n "$host" ]]; then
                    all_hosts="${all_hosts}${host}"$'\n'
                fi
            done <<< "$filtered_catalog"
        else
            echo "IMPALA_CATALOG_SERVICE=NONE" >> "${service_hosts_file}"
        fi
        
        # IMPALA_STATE_STORE: Get ALL hosts
        local impala_state_hosts
        set +e
        impala_state_hosts=$(get_all_hosts_for_component "IMPALA_STATE_STORE" 2>/dev/null)
        set -e
        
        local filtered_state
        filtered_state=$(echo "$impala_state_hosts" 2>/dev/null | grep -v '^[[:space:]]*$' || true)
        
        if [[ -n "${filtered_state}" ]]; then
            local state_host_count
            state_host_count=$(echo "$filtered_state" | grep -v '^$' | wc -l | tr -d ' ')
            local first_state_host
            first_state_host=$(echo "$filtered_state" | head -n 1)
            
            export IMPALA_STATE_STORE_HOST="$first_state_host"
            echo "IMPALA_STATE_STORE_HOST=${first_state_host}" >> "${service_hosts_vars_file}"
            
            if [[ $state_host_count -gt 1 ]]; then
                local state_hosts_list
                state_hosts_list=$(echo "$filtered_state" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
                echo "IMPALA_STATE_STORE=${state_hosts_list}" >> "${service_hosts_file}"
                export IMPALA_STATE_STORE_HOSTS="$state_hosts_list"
                echo "IMPALA_STATE_STORE_HOSTS=${state_hosts_list}" >> "${service_hosts_vars_file}"
            else
                echo "IMPALA_STATE_STORE=${first_state_host}" >> "${service_hosts_file}"
            fi
            
            # Add to all_hosts
            while IFS= read -r host; do
                if [[ -n "$host" ]]; then
                    all_hosts="${all_hosts}${host}"$'\n'
                fi
            done <<< "$filtered_state"
        else
            echo "IMPALA_STATE_STORE=NONE" >> "${service_hosts_file}"
        fi
    fi
    
    # Save all unique hosts to hosts file
    if [[ -n "$all_hosts" ]]; then
        echo "$all_hosts" | sort -u > "${hosts_file}"
        local unique_host_count
        unique_host_count=$(cat "${hosts_file}" | grep -v '^$' | wc -l | tr -d ' ')
        info "Discovered ${service_count} services with ${unique_host_count} unique hosts"
    else
        error "No hosts found for any service"
        return 1
    fi
}

fetch_knox_gateway() {
    local knox_host
    knox_host=$(get_host_for_component "KNOX_GATEWAY")
    if [[ -z "$knox_host" ]]; then
      error "Failed to retrieve KNOX_GATEWAY host"
      exit 1
    fi
    # get_host_for_component already returns only the first hostname
    export KNOX_GATEWAY="$knox_host"
}

#---------------------------
# Function to Fetch List of Services
#---------------------------
fetch_services() {
    info "Discovering Ambari services..."
    local ambari_url="${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters/${CLUSTER}/services"
    local http_code
    local curl_output
    local curl_stderr
    
    # Attempt to connect to Ambari server with timeout
    local stderr_file
    stderr_file=$(mktemp) || {
        error "Failed to create temporary file for error capture."
        exit 1
    }
    
    set +e  # Temporarily disable exit on error to capture curl exit code
    curl_output=$(curl -s -k -w "\n%{http_code}" -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -i -H 'X-Requested-By: ambari' \
      --connect-timeout 10 --max-time 30 \
      "${ambari_url}" 2>"${stderr_file}")
    local curl_exit_code=$?
    set -e  # Re-enable exit on error
    curl_stderr=$(cat "${stderr_file}" 2>/dev/null || echo "")
    rm -f "${stderr_file}" || true
    
    # Check if curl command failed
    if [[ $curl_exit_code -ne 0 ]]; then
        error "Failed to connect to Ambari server at ${ambari_url}"
        if [[ -n "$curl_stderr" ]]; then
            error "Error details: ${curl_stderr}"
        fi
        return 1
    fi
    
    # Extract HTTP status code (last line)
    http_code=$(echo "$curl_output" | tail -n 1 | tr -d '\r\n')
    
    # Check HTTP status code
    if [[ "$http_code" != "200" ]]; then
        error "Failed to retrieve services from Ambari server"
        error "HTTP Status Code: ${http_code}"
        return 1
    fi
    
    # Extract service names from response (remove the HTTP status code line first)
    local all_services
    all_services=$(echo "$curl_output" | sed '$d' | grep -o '"service_name" : "[^"]*' | sed 's/"service_name" : "//' | sort)
    
    if [[ -z "${all_services}" ]]; then
        error "No services found in Ambari response."
        return 1
    fi
    
    # Filter out services in EXCLUDED_SERVICES list
    local services="$all_services"
    if [[ -n "${EXCLUDED_SERVICES}" ]]; then
        # Convert EXCLUDED_SERVICES to newline-separated list and exclude those services
        local excluded_services
        excluded_services=$(echo "${EXCLUDED_SERVICES}" | tr ' ' '\n')
        services=$(echo "$all_services" | grep -vF "$excluded_services")
    fi
    
    if [[ -z "${services}" ]]; then
        info "All services are in the excluded list. No services to display."
        export AMBARI_SERVICES=""
        return 0
    fi
    
    # Save services list to file under /tmp/
    local services_file="/tmp/knox-services-list.txt"
    if ! echo "$services" > "${services_file}" 2>/dev/null; then
        error "Failed to save services list"
        return 1
    fi
    
    local service_count
    service_count=$(echo "$services" | wc -l | tr -d ' ')
    info "Discovered ${service_count} services"
    export AMBARI_SERVICES="$services"
}

#---------------------------
# Function to Get Config from Ambari using configs.py
#---------------------------
# Retrieves configuration from Ambari for a specific config type using the configs.py script
# This function is used to fetch service configurations (e.g., hdfs-site, yarn-site)
# that are needed to determine SSL settings, ports, and other service-specific parameters
# Arguments:
#   $1 - Config type (e.g., "hdfs-site", "yarn-site", "hive-site")
#   $2 - Output file path where the JSON config will be saved
# Returns:
#   0 on success, 1 on error, 2 if config not found
get_ambari_config() {
    local config_type="$1"
    local output_file="$2"
    
    if [[ -z "$config_type" ]] || [[ -z "$output_file" ]]; then
        error "Usage: get_ambari_config <config_type> <output_file>"
        return 1
    fi
    
    local ssl_flag=""
    if [[ "$AMBARI_PROTOCOL" == "https" ]]; then
        ssl_flag="-s https"
    fi
    
    # Use python3 by default, but can use PYTHON_BIN if set
    local python_bin="${PYTHON_BIN:-python3}"
    
    local err
    err=$($python_bin /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" $ssl_flag -a get -t "$AMBARI_PORT" \
        -l "$AMBARI_SERVER" -n "$CLUSTER" \
        -c "$config_type" -f "$output_file" 2>&1 1>/dev/null)
    local rc=$?
    
    if ((rc != 0)); then
        if echo "$err" | grep -q "Missing parentheses in call to 'print'"; then
            error "Python version issue detected. Please set PYTHON_BIN=python2 for Python 2."
            return 1
        fi
        if [[ "$AMBARI_PROTOCOL" == "https" ]] && echo "$err" | grep -q "CERTIFICATE_VERIFY_FAILED"; then
            error "SSL certificate verification failed for config: $config_type"
            return 1
        fi
        if echo "$err" | grep -iqE "not[ _-]?found|missing"; then
            info "Config $config_type not found."
            return 2
        fi
        error "Failed to get config $config_type: $err"
        return 1
    fi
    
    if [[ -f "$output_file" ]] && [[ -s "$output_file" ]]; then
        return 0
    else
        error "Config file $output_file is empty or does not exist."
        return 1
    fi
}

#---------------------------
# Function to Get Config Value from JSON
#---------------------------
# Extracts a specific configuration value from a JSON config file
# This is used to retrieve specific settings like ports, SSL flags, etc.
# Arguments:
#   $1 - Path to the JSON config file
#   $2 - Configuration key to retrieve (e.g., "dfs.http.policy")
# Returns:
#   Configuration value if found, empty string otherwise
get_config_value() {
    local config_file="$1"
    local key="$2"
    
    if [[ ! -f "$config_file" ]]; then
        error "Config file not found: $config_file"
        return 1
    fi
    
    # Extract value from JSON (handles both quoted and unquoted values)
    grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$config_file" | \
        sed "s/\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\"/\1/" | head -n 1
}

#---------------------------
# Function to Check if HDFS HA is Enabled
#---------------------------
check_hdfs_ha_enabled() {
    local namenode_hosts="$1"
    
    if [[ -z "$namenode_hosts" ]]; then
        # Get hosts from the mapping file
        if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
            local hdfs_line
            hdfs_line=$(grep "^HDFS=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
            if [[ -n "$hdfs_line" ]]; then
                namenode_hosts=$(echo "$hdfs_line" | sed 's/^HDFS=//')
            fi
        fi
    fi
    
    if [[ -z "$namenode_hosts" ]]; then
        echo "false"
        return
    fi
    
    # Count hosts (comma-separated)
    local host_count
    host_count=$(echo "$namenode_hosts" | tr ',' '\n' | grep -v '^$' | wc -l | tr -d ' ')
    
    if [[ $host_count -gt 1 ]]; then
        echo "true"
    else
        echo "false"
    fi
}

#---------------------------
# Function to Get HDFS Nameservice
#---------------------------
get_hdfs_nameservice() {
    local temp_config="/tmp/hdfs-site-config.json"
    
    if ! get_ambari_config "hdfs-site" "$temp_config"; then
        error "Failed to get hdfs-site config"
        return 1
    fi
    
    local nameservice
    nameservice=$(get_config_value "$temp_config" "dfs.nameservices")
    
    if [[ -n "$nameservice" ]]; then
        echo "$nameservice"
        return 0
    else
        error "Nameservice not found in hdfs-site config"
        return 1
    fi
}

#---------------------------
# Function to Get HDFS Protocol (HTTP or HTTPS)
#---------------------------
get_hdfs_protocol() {
    local temp_config="/tmp/hdfs-site-config.json"
    
    if ! get_ambari_config "hdfs-site" "$temp_config"; then
        error "Failed to get hdfs-site config"
        echo "http"  # Default to http
        return 1
    fi
    
    local http_policy
    http_policy=$(get_config_value "$temp_config" "dfs.http.policy")
    
    if [[ "$http_policy" == "HTTPS_ONLY" ]]; then
        echo "https"
    else
        echo "http"  # Default or HTTP_ONLY
    fi
}

#---------------------------
# Function to Get HDFS Port
#---------------------------
get_hdfs_port() {
    local protocol="$1"
    local temp_config="/tmp/hdfs-site-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_hdfs_protocol)
    fi
    
    if ! get_ambari_config "hdfs-site" "$temp_config"; then
        error "Failed to get hdfs-site config"
        # Return default ports
        if [[ "$protocol" == "https" ]]; then
            echo "50470"
        else
            echo "50070"
        fi
        return 1
    fi
    
    if [[ "$protocol" == "https" ]]; then
        local port
        port=$(get_config_value "$temp_config" "dfs.https.port")
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "50470"  # Default HTTPS port
        fi
    else
        # For HTTP, check dfs.namenode.http-address or default to 50070
        local port
        port=$(get_config_value "$temp_config" "dfs.namenode.http-address" | cut -d':' -f2 2>/dev/null)
        if [[ -z "$port" ]]; then
            # Try alternative config key
            port=$(grep -o '"dfs\.namenode\.http-address"[^,}]*' "$temp_config" | grep -o ':[0-9]*' | sed 's/://' | head -n 1)
        fi
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "50070"  # Default HTTP port
        fi
    fi
}

#---------------------------
# Function to Get YARN Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, YARN will be HTTP by default
#---------------------------
get_yarn_protocol() {
    # First check HDFS protocol - if HDFS is non-SSL, YARN should also be non-SSL
    local hdfs_protocol
    hdfs_protocol=$(get_hdfs_protocol)
    
    if [[ "$hdfs_protocol" == "http" ]]; then
        # HDFS is non-SSL, so YARN should also be non-SSL by default
        echo "http"
        return 0
    fi
    
    # HDFS is HTTPS, so check YARN's own configuration
    local temp_config="/tmp/yarn-site-config.json"
    
    if ! get_ambari_config "yarn-site" "$temp_config"; then
        error "Failed to get yarn-site config"
        echo "https"  # Default to https if HDFS is https
        return 1
    fi
    
    # Check if https address exists (indicates HTTPS is enabled)
    local https_address
    https_address=$(get_config_value "$temp_config" "yarn.resourcemanager.webapp.https.address")
    
    if [[ -n "$https_address" ]]; then
        echo "https"
    else
        # Even if YARN doesn't have HTTPS config, if HDFS is HTTPS, use HTTPS for YARN
        echo "https"
    fi
}

#---------------------------
# Function to Get HBASE Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, HBASE will be HTTP by default
#---------------------------
get_hbase_protocol() {
    # Check HBASE's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/hbase-site-config.json"
    
    if ! get_ambari_config "hbase-site" "$temp_config"; then
        error "Failed to get hbase-site config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check hbase.ssl.enabled - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "hbase.ssl.enabled")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get HBASE Port
#---------------------------
get_hbase_port() {
    local temp_config="/tmp/hbase-site-config.json"
    
    if ! get_ambari_config "hbase-site" "$temp_config"; then
        error "Failed to get hbase-site config"
        echo "16010"  # Default HBASE port
        return 1
    fi
    
    # Get port from hbase.master.info.port
    local port
    port=$(get_config_value "$temp_config" "hbase.master.info.port")
    
    if [[ -n "$port" ]]; then
        echo "$port"
    else
        echo "16010"  # Default HBASE port
    fi
}

#---------------------------
# Function to Get HIVE Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, HIVE will be HTTP by default
#---------------------------
get_hive_protocol() {
    # Check HIVE's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/hive-site-config.json"
    
    if ! get_ambari_config "hive-site" "$temp_config"; then
        error "Failed to get hive-site config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check hive.server2.use.SSL - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "hive.server2.use.SSL")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get HIVE Port (default 10001)
#---------------------------
get_hive_port() {
    echo "10001"  # Default HIVE port
}

#---------------------------
# Function to Get HIVESERVER2UI Port
#---------------------------
get_hive_webui_port() {
    local temp_config="/tmp/hive-site-config.json"
    
    if ! get_ambari_config "hive-site" "$temp_config"; then
        error "Failed to get hive-site config"
        echo "10002"  # Default HIVESERVER2UI port
        return 1
    fi
    
    # Get port from hive.server2.webui.port
    local port
    port=$(get_config_value "$temp_config" "hive.server2.webui.port")
    
    if [[ -n "$port" ]]; then
        echo "$port"
    else
        echo "10002"  # Default HIVESERVER2UI port
    fi
}

#---------------------------
# Function to Get OOZIE Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, OOZIE will be HTTP by default
#---------------------------
get_oozie_protocol() {
    # Check OOZIE's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/oozie-site-config.json"
    
    if ! get_ambari_config "oozie-site" "$temp_config"; then
        error "Failed to get oozie-site config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check oozie.https.enabled - this is the primary decision
    # false means HTTP, true means HTTPS
    local https_enabled
    https_enabled=$(get_config_value "$temp_config" "oozie.https.enabled")
    
    if [[ "$https_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get OOZIE Port
#---------------------------
get_oozie_port() {
    local protocol="$1"
    local temp_config="/tmp/oozie-site-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_oozie_protocol)
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from oozie.https.port
        if ! get_ambari_config "oozie-site" "$temp_config"; then
            error "Failed to get oozie-site config"
            echo "11443"  # Default HTTPS port
            return 1
        fi
        
        local port
        port=$(get_config_value "$temp_config" "oozie.https.port")
        
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "11443"  # Default HTTPS port
        fi
    else
        # HTTP port is always 11000
        echo "11000"
    fi
}

#---------------------------
# Function to Get RANGER Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, RANGER will be HTTP by default
#---------------------------
get_ranger_protocol() {
    # Check RANGER's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/ranger-admin-site-config.json"
    
    if ! get_ambari_config "ranger-admin-site" "$temp_config"; then
        error "Failed to get ranger-admin-site config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check ranger.service.http.enabled - this is the primary decision
    # true means HTTP (SSL disabled), false means HTTPS (SSL enabled)
    local http_enabled
    http_enabled=$(get_config_value "$temp_config" "ranger.service.http.enabled")
    
    if [[ "$http_enabled" == "true" ]]; then
        echo "http"
    else
        # http.enabled=false means SSL is enabled
        echo "https"
    fi
}

#---------------------------
# Function to Get RANGER Port
#---------------------------
get_ranger_port() {
    local protocol="$1"
    local temp_config="/tmp/ranger-admin-site-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_ranger_protocol)
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from ranger.service.https.port
        if ! get_ambari_config "ranger-admin-site" "$temp_config"; then
            error "Failed to get ranger-admin-site config"
            echo "6182"  # Default HTTPS port
            return 1
        fi
        
        local port
        port=$(get_config_value "$temp_config" "ranger.service.https.port")
        
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "6182"  # Default HTTPS port
        fi
    else
        # HTTP port is always 6080
        echo "6080"
    fi
}

#---------------------------
# Function to Get Spark3 Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, Spark3 will be HTTP by default
#---------------------------
get_spark3_protocol() {
    # Check Spark3's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/spark3-defaults-config.json"
    
    if ! get_ambari_config "spark3-defaults" "$temp_config"; then
        error "Failed to get spark3-defaults config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check spark.ssl.enabled - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "spark.ssl.enabled")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get Spark3 Port
#---------------------------
get_spark3_port() {
    local temp_config="/tmp/spark3-defaults-config.json"
    
    if ! get_ambari_config "spark3-defaults" "$temp_config"; then
        error "Failed to get spark3-defaults config"
        echo "18082"  # Default Spark3 History UI port
        return 1
    fi
    
    # Get port from spark.history.ui.port
    local port
    port=$(get_config_value "$temp_config" "spark.history.ui.port")
    
    if [[ -n "$port" ]]; then
        echo "$port"
    else
        echo "18082"  # Default Spark3 History UI port
    fi
}

#---------------------------
# Function to Get TRINO Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, TRINO will be HTTP by default
#---------------------------
get_trino_protocol() {
    # Check TRINO's own SSL configuration first
    local temp_config="/tmp/trino-env-config.json"
    
    if ! get_ambari_config "trino-env" "$temp_config"; then
        error "Failed to get trino-env config"
        # Fallback to HDFS protocol if config unavailable
        local hdfs_protocol
        hdfs_protocol=$(get_hdfs_protocol)
        echo "$hdfs_protocol"
        return 1
    fi
    
    # Check ssl_enabled - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "ssl_enabled")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get TRINO Port
#---------------------------
get_trino_port() {
    local protocol="$1"
    local temp_config="/tmp/trino-env-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_trino_protocol)
    fi
    
    if ! get_ambari_config "trino-env" "$temp_config"; then
        error "Failed to get trino-env config"
        # Return default ports
        if [[ "$protocol" == "https" ]]; then
            echo "9098"
        else
            echo "9097"
        fi
        return 1
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from https_server_port
        local port
        port=$(get_config_value "$temp_config" "https_server_port")
        
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "9098"  # Default HTTPS port
        fi
    else
        # Get HTTP port from http_server_port
        local port
        port=$(get_config_value "$temp_config" "http_server_port")
        
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "9097"  # Default HTTP port
        fi
    fi
}

#---------------------------
# Function to Get PINOT Protocol (HTTP or HTTPS)
# Follows HDFS protocol: if HDFS is HTTP, PINOT will be HTTP by default
#---------------------------
get_pinot_protocol() {
    # Check PINOT's own SSL configuration first
    local temp_config="/tmp/pinot-env-config.json"
    
    if ! get_ambari_config "pinot-env" "$temp_config"; then
        error "Failed to get pinot-env config"
        # Fallback to HDFS protocol if config unavailable
        local hdfs_protocol
        hdfs_protocol=$(get_hdfs_protocol)
        echo "$hdfs_protocol"
        return 1
    fi
    
    # Check enable_ssl - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "enable_ssl")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get PINOT Port
#---------------------------
get_pinot_port() {
    local protocol="$1"
    local temp_config="/tmp/pinot-env-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_pinot_protocol)
    fi
    
    if ! get_ambari_config "pinot-env" "$temp_config"; then
        error "Failed to get pinot-env config"
        echo "9443"  # Default PINOT HTTPS port
        return 1
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from controller.access.protocols.https.port
        local port
        port=$(get_config_value "$temp_config" "controller.access.protocols.https.port")
        
        if [[ -n "$port" ]]; then
            echo "$port"
        else
            echo "9443"  # Default HTTPS port
        fi
    else
        # For HTTP, we need to find the HTTP port config or use default
        # Default HTTP port for PINOT is typically 9000
        echo "9000"  # Default HTTP port
    fi
}

#---------------------------
# Function to Get OZONE Protocol (HTTP or HTTPS)
# Independent from HDFS - checks its own SSL configuration
#---------------------------
get_ozone_protocol() {
    # Check OZONE's own SSL configuration (independent from HDFS)
    local temp_config="/tmp/ozone-env-config.json"
    
    if ! get_ambari_config "ozone-env" "$temp_config"; then
        error "Failed to get ozone-env config"
        echo "http"  # Default to http
        return 1
    fi
    
    # Check ozone_recon_ssl_enabled - this is the primary decision
    local ssl_enabled
    ssl_enabled=$(get_config_value "$temp_config" "ozone_recon_ssl_enabled")
    
    if [[ "$ssl_enabled" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

#---------------------------
# Function to Get OZONE Port
#---------------------------
get_ozone_port() {
    local protocol="$1"
    local temp_config="/tmp/ozone-site-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_ozone_protocol)
    fi
    
    if ! get_ambari_config "ozone-site" "$temp_config"; then
        error "Failed to get ozone-site config"
        # Return default ports
        if [[ "$protocol" == "https" ]]; then
            echo "9899"
        else
            echo "9898"
        fi
        return 1
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from ozone.recon.https-address
        local https_address
        https_address=$(get_config_value "$temp_config" "ozone.recon.https-address")
        if [[ -n "$https_address" ]]; then
            local port
            port=$(echo "$https_address" | cut -d':' -f2)
            if [[ -n "$port" ]]; then
                echo "$port"
            else
                echo "9899"  # Default HTTPS port
            fi
        else
            echo "9899"  # Default HTTPS port
        fi
    else
        # Get HTTP port from ozone.recon.http-address
        local http_address
        http_address=$(get_config_value "$temp_config" "ozone.recon.http-address")
        if [[ -n "$http_address" ]]; then
            local port
            port=$(echo "$http_address" | cut -d':' -f2)
            if [[ -n "$port" ]]; then
                echo "$port"
            else
                echo "9898"  # Default HTTP port
            fi
        else
            echo "9898"  # Default HTTP port
        fi
    fi
}

#---------------------------
# Function to Get JobHistory Server Details
#---------------------------
get_jobhistory_details() {
    local temp_config="/tmp/yarn-site-config.json"
    
    if ! get_ambari_config "yarn-site" "$temp_config"; then
        error "Failed to get yarn-site config for JobHistory"
        return 1
    fi
    
    # Get yarn.log.server.url value
    local log_server_url
    log_server_url=$(get_config_value "$temp_config" "yarn.log.server.url")
    
    if [[ -z "$log_server_url" ]]; then
        info "yarn.log.server.url not found in yarn-site config"
        return 1
    fi
    
    # Extract protocol, hostname, and port from URL
    # URL format: http://hostname:port/path
    # or: https://hostname:port/path
    local protocol
    local hostname_port
    local hostname
    local port
    
    # Extract protocol
    if [[ "$log_server_url" =~ ^https:// ]]; then
        protocol="https"
        hostname_port=$(echo "$log_server_url" | sed 's|^https://||' | cut -d'/' -f1)
    else
        protocol="http"
        hostname_port=$(echo "$log_server_url" | sed 's|^http://||' | cut -d'/' -f1)
    fi
    
    # Extract hostname and port
    if [[ "$hostname_port" =~ : ]]; then
        hostname=$(echo "$hostname_port" | cut -d':' -f1)
        port=$(echo "$hostname_port" | cut -d':' -f2)
    else
        hostname="$hostname_port"
        port="19888"  # Default JobHistory port
    fi
    
    # Return values (hostname:port:protocol format)
    echo "${hostname}:${port}:${protocol}"
}

#---------------------------
# Function to Get YARN Port
#---------------------------
get_yarn_port() {
    local protocol="$1"
    local temp_config="/tmp/yarn-site-config.json"
    
    if [[ -z "$protocol" ]]; then
        protocol=$(get_yarn_protocol)
    fi
    
    if ! get_ambari_config "yarn-site" "$temp_config"; then
        error "Failed to get yarn-site config"
        # Return default ports
        if [[ "$protocol" == "https" ]]; then
            echo "8090"
        else
            echo "8088"
        fi
        return 1
    fi
    
    if [[ "$protocol" == "https" ]]; then
        # Get HTTPS port from yarn.resourcemanager.webapp.https.address
        local https_address
        https_address=$(get_config_value "$temp_config" "yarn.resourcemanager.webapp.https.address")
        if [[ -n "$https_address" ]]; then
            local port
            port=$(echo "$https_address" | cut -d':' -f2)
            if [[ -n "$port" ]]; then
                echo "$port"
            else
                echo "8090"  # Default HTTPS port
            fi
        else
            echo "8090"  # Default HTTPS port
        fi
    else
        # Get HTTP port from yarn.resourcemanager.webapp.address
        local http_address
        http_address=$(get_config_value "$temp_config" "yarn.resourcemanager.webapp.address")
        if [[ -n "$http_address" ]]; then
            local port
            port=$(echo "$http_address" | cut -d':' -f2)
            if [[ -n "$port" ]]; then
                echo "$port"
            else
                echo "8088"  # Default HTTP port
            fi
        else
            echo "8088"  # Default HTTP port
        fi
    fi
}

#---------------------------
# Function to Generate SSO Proxy Topology XML
#---------------------------
# Generates the SSO Proxy Topology XML file (odp-proxy-sso.xml)
# This topology uses SSOCookieProvider for federated authentication and is suitable
# for UI-based access where users authenticate via SSO cookies
#
# The topology includes:
#   - SSOCookieProvider for authentication (federated SSO)
#   - Authorization provider (XASecurePDPKnox if Ranger enabled, AclsAuthz otherwise)
#   - All configured services (HDFS, YARN, HBASE, HIVE, OOZIE, RANGER, etc.)
#   - Proper SSL/HTTPS configuration based on service settings
#   - Support for High Availability (HA) configurations
#
# Output file: /tmp/odp-proxy-sso.xml
# Returns: 0 on success, 1 on failure
generate_sso_proxy_topology() {
    local output_file="/tmp/odp-proxy-sso.xml"
    
    info "Generating SSO proxy topology (${output_file##*/})..."
    
    # Get HDFS hosts from mapping file
    local hdfs_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hdfs_line
        hdfs_line=$(grep "^HDFS=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hdfs_line" ]]; then
            hdfs_hosts=$(echo "$hdfs_line" | sed 's/^HDFS=//')
        fi
    fi
    
    if [[ -z "$hdfs_hosts" ]]; then
        error "HDFS hosts not found in mapping file"
        return 1
    fi
    
    # Check if HA is enabled
    local ha_enabled
    ha_enabled=$(check_hdfs_ha_enabled "$hdfs_hosts")
    
    # Determine protocol and port
    local protocol
    protocol=$(get_hdfs_protocol)
    local port
    port=$(get_hdfs_port "$protocol")
    
    # Create XML content
    cat > "$output_file" <<EOF
<topology>
    <gateway>
        <provider>
            <role>federation</role>
            <name>SSOCookieProvider</name>
            <enabled>true</enabled>
            <param>
                <name>sso.authentication.provider.url</name>
                <value>https://${KNOX_GATEWAY}:8443/gateway/knoxsso/api/v1/websso</value>
            </param>
        </provider>
EOF
    
    # Add authorization provider based on Ranger plugin status
    if [[ "${RANGER_PLUGIN_ENABLED}" = "true" ]]; then
        cat >> "$output_file" <<EOF
        <provider>
            <role>authorization</role>
            <name>XASecurePDPKnox</name>
            <enabled>true</enabled>
        </provider>
EOF
    else
        cat >> "$output_file" <<EOF
        <provider>
            <role>authorization</role>
            <name>AclsAuthz</name>
            <enabled>true</enabled>
        </provider>
EOF
    fi
    
    cat >> "$output_file" <<EOF
        <provider>
            <role>identity-assertion</role>
            <name>Default</name>
            <enabled>true</enabled>
        </provider>
    </gateway>
    
    <service>
        <role>NAMENODE</role>
EOF
    
    if [[ "$ha_enabled" == "true" ]]; then
        # HA enabled - use nameservice
        local nameservice
        nameservice=$(get_hdfs_nameservice)
        if [[ -n "$nameservice" ]]; then
            echo "        <url>hdfs://${nameservice}</url>" >> "$output_file"
        else
            error "HA is enabled but nameservice not found. Using first host as fallback."
            local first_host
            first_host=$(echo "$hdfs_hosts" | cut -d',' -f1)
            echo "        <url>hdfs://${first_host}:8020</url>" >> "$output_file"
        fi
    else
        # HA not enabled - use single host
        local first_host
        first_host=$(echo "$hdfs_hosts" | cut -d',' -f1)
        echo "        <url>hdfs://${first_host}:8020</url>" >> "$output_file"
    fi
    
    cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HDFSUI</role>
        <version>2.7.0</version>
EOF
    
    # Add HDFSUI URLs for each host
    echo "$hdfs_hosts" | tr ',' '\n' | while IFS= read -r host; do
        if [[ -n "$host" ]]; then
            echo "        <url>${protocol}://${host}:${port}</url>" >> "$output_file"
        fi
    done
    
    cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>WEBHDFS</role>
EOF
    
    # Add WEBHDFS URLs for each host
    echo "$hdfs_hosts" | tr ',' '\n' | while IFS= read -r host; do
        if [[ -n "$host" ]]; then
            echo "        <url>${protocol}://${host}:${port}/webhdfs</url>" >> "$output_file"
        fi
    done
    
    cat >> "$output_file" <<EOF
    </service>
    
EOF
    
    # Add YARN services
    # Get YARN hosts from mapping file
    local yarn_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local yarn_line
        yarn_line=$(grep "^YARN=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$yarn_line" ]]; then
            yarn_hosts=$(echo "$yarn_line" | sed 's/^YARN=//')
        fi
    fi
    
    if [[ -n "$yarn_hosts" ]]; then
        # Determine YARN protocol and port
        local yarn_protocol
        yarn_protocol=$(get_yarn_protocol)
        local yarn_port
        yarn_port=$(get_yarn_port "$yarn_protocol")
        
        # Add YARNUI service
        cat >> "$output_file" <<EOF
    <service>
        <role>YARNUI</role>
EOF
        
        # Add YARNUI URLs for each host
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>YARNUIV2</role>
EOF
        
        # Add YARNUIV2 URLs for each host
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>RESOURCEMANAGER</role>
EOF
        
        # Add RESOURCEMANAGER URLs for each host (with /ws path)
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}/ws</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
        
        # Add JOBHISTORYUI service
        local jobhistory_details
        jobhistory_details=$(get_jobhistory_details)
        
        if [[ -n "$jobhistory_details" ]]; then
            # Parse the details (format: hostname:port:protocol)
            local jobhistory_host
            local jobhistory_port
            
            jobhistory_host=$(echo "$jobhistory_details" | cut -d':' -f1)
            jobhistory_port=$(echo "$jobhistory_details" | cut -d':' -f2)
            
            # Use protocol to follow HDFS/YARN protocol
            local yarn_protocol
            yarn_protocol=$(get_yarn_protocol)
            
            cat >> "$output_file" <<EOF
    <service>
        <role>JOBHISTORYUI</role>
        <url>${yarn_protocol}://${jobhistory_host}:${jobhistory_port}</url>
    </service>
    
EOF
        fi
    fi
    
    # Add HBASE services
    # Get HBASE hosts from mapping file
    local hbase_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hbase_line
        hbase_line=$(grep "^HBASE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hbase_line" ]]; then
            hbase_hosts=$(echo "$hbase_line" | sed 's/^HBASE=//')
        fi
    fi
    
    if [[ -n "$hbase_hosts" ]]; then
        # Determine HBASE protocol and port
        local hbase_protocol
        hbase_protocol=$(get_hbase_protocol)
        local hbase_port
        hbase_port=$(get_hbase_port)
        
        # Add HBASE service
        cat >> "$output_file" <<EOF
    <service>
        <role>HBASE</role>
EOF
        
        # Add HBASE URLs for each host
        echo "$hbase_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hbase_protocol}://${host}:${hbase_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HBASEUI</role>
        <version>2.1.0</version>
EOF
        
        # Add HBASEUI URLs for each host
        echo "$hbase_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hbase_protocol}://${host}:${hbase_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add HIVE services
    # Get HIVE hosts from mapping file
    local hive_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hive_line
        hive_line=$(grep "^HIVE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hive_line" ]]; then
            hive_hosts=$(echo "$hive_line" | sed 's/^HIVE=//')
        fi
    fi
    
    if [[ -n "$hive_hosts" ]]; then
        # Determine HIVE protocol and ports
        local hive_protocol
        hive_protocol=$(get_hive_protocol)
        local hive_port
        hive_port=$(get_hive_port)
        local hive_webui_port
        hive_webui_port=$(get_hive_webui_port)
        
        # Add HIVE service
        cat >> "$output_file" <<EOF
    <service>
        <role>HIVE</role>
EOF
        
        # Add HIVE URLs for each host (with /cliservice path)
        echo "$hive_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hive_protocol}://${host}:${hive_port}/cliservice</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HIVESERVER2UI</role>
EOF
        
        # Add HIVESERVER2UI URLs for each host
        echo "$hive_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hive_protocol}://${host}:${hive_webui_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add OOZIE services
    # Get OOZIE hosts from mapping file
    local oozie_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local oozie_line
        oozie_line=$(grep "^OOZIE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$oozie_line" ]]; then
            oozie_hosts=$(echo "$oozie_line" | sed 's/^OOZIE=//')
        fi
    fi
    
    if [[ -n "$oozie_hosts" ]]; then
        # Determine OOZIE protocol and port
        local oozie_protocol
        oozie_protocol=$(get_oozie_protocol)
        local oozie_port
        oozie_port=$(get_oozie_port "$oozie_protocol")
        
        # Add OOZIE service
        cat >> "$output_file" <<EOF
    <service>
        <role>OOZIE</role>
EOF
        
        # Add OOZIE URLs for each host (with /oozie path)
        echo "$oozie_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${oozie_protocol}://${host}:${oozie_port}/oozie</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>OOZIEUI</role>
EOF
        
        # Add OOZIEUI URLs for each host (with /oozie/ path)
        echo "$oozie_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${oozie_protocol}://${host}:${oozie_port}/oozie/</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add RANGER services
    # Get RANGER hosts from mapping file
    local ranger_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local ranger_line
        ranger_line=$(grep "^RANGER=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$ranger_line" ]]; then
            ranger_hosts=$(echo "$ranger_line" | sed 's/^RANGER=//')
        fi
    fi
    
    if [[ -n "$ranger_hosts" ]]; then
        # Determine RANGER protocol and port
        local ranger_protocol
        ranger_protocol=$(get_ranger_protocol)
        local ranger_port
        ranger_port=$(get_ranger_port "$ranger_protocol")
        
        # Add RANGER service
        cat >> "$output_file" <<EOF
    <service>
        <role>RANGER</role>
EOF
        
        # Add RANGER URLs for each host
        echo "$ranger_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ranger_protocol}://${host}:${ranger_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>RANGERUI</role>
EOF
        
        # Add RANGERUI URLs for each host
        echo "$ranger_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ranger_protocol}://${host}:${ranger_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add SPARK3 services
    # Get SPARK3 hosts from mapping file
    local spark3_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local spark3_line
        spark3_line=$(grep "^SPARK3=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$spark3_line" ]]; then
            spark3_hosts=$(echo "$spark3_line" | sed 's/^SPARK3=//')
        fi
    fi
    
    if [[ -n "$spark3_hosts" ]]; then
        # Determine Spark3 protocol and port
        local spark3_protocol
        spark3_protocol=$(get_spark3_protocol)
        local spark3_port
        spark3_port=$(get_spark3_port)
        
        # Add SPARK3HISTORYUI service
        cat >> "$output_file" <<EOF
    <service>
        <role>SPARK3HISTORYUI</role>
EOF
        
        # Add SPARK3HISTORYUI URLs for each host
        echo "$spark3_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${spark3_protocol}://${host}:${spark3_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add TRINO services
    # Get TRINO hosts from mapping file
    local trino_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local trino_line
        trino_line=$(grep "^TRINO=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$trino_line" ]]; then
            trino_hosts=$(echo "$trino_line" | sed 's/^TRINO=//')
        fi
    fi
    
    if [[ -n "$trino_hosts" ]]; then
        # Determine TRINO protocol and port
        local trino_protocol
        trino_protocol=$(get_trino_protocol)
        local trino_port
        trino_port=$(get_trino_port "$trino_protocol")
        
        # Add TRINOUI service
        cat >> "$output_file" <<EOF
    <service>
        <role>TRINOUI</role>
EOF
        
        # Add TRINOUI URLs for each host
        echo "$trino_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${trino_protocol}://${host}:${trino_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add PINOT services
    # Get PINOT hosts from mapping file
    local pinot_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local pinot_line
        pinot_line=$(grep "^PINOT=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$pinot_line" ]]; then
            pinot_hosts=$(echo "$pinot_line" | sed 's/^PINOT=//')
        fi
    fi
    
    if [[ -n "$pinot_hosts" ]]; then
        # Determine PINOT protocol and port
        local pinot_protocol
        pinot_protocol=$(get_pinot_protocol)
        local pinot_port
        pinot_port=$(get_pinot_port "$pinot_protocol")
        
        # Add PINOT service
        cat >> "$output_file" <<EOF
    <service>
        <role>PINOT</role>
EOF
        
        # Add PINOT URLs for each host
        echo "$pinot_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${pinot_protocol}://${host}:${pinot_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add OZONE services
    # Get OZONE hosts from mapping file
    local ozone_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local ozone_line
        ozone_line=$(grep "^OZONE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$ozone_line" ]]; then
            ozone_hosts=$(echo "$ozone_line" | sed 's/^OZONE=//')
        fi
    fi
    
    if [[ -n "$ozone_hosts" ]]; then
        # Determine OZONE protocol and port
        local ozone_protocol
        ozone_protocol=$(get_ozone_protocol)
        local ozone_port
        ozone_port=$(get_ozone_port "$ozone_protocol")
        
        # Add OZONE-RECON service
        cat >> "$output_file" <<EOF
    <service>
        <role>OZONE-RECON</role>
EOF
        
        # Add OZONE-RECON URLs for each host
        echo "$ozone_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ozone_protocol}://${host}:${ozone_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add AMBARI services using configuration variables
    cat >> "$output_file" <<EOF
    <service>
        <role>AMBARI</role>
        <url>${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}</url>
    </service>
    
    <service>
        <role>AMBARIUI</role>
        <url>${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}</url>
    </service>
    
EOF
    
    # Close topology
    echo "</topology>" >> "$output_file"
    
    info "SSO proxy topology generated successfully"
    return 0
}

#---------------------------
# Function to Generate API Proxy Topology XML (with ShiroProvider for API access)
#---------------------------
# Generates the API Proxy Topology XML file (odp-proxy.xml)
# This topology uses ShiroProvider with LDAP authentication and is suitable
# for programmatic API access where clients authenticate using Basic Auth with LDAP
#
# The topology includes:
#   - ShiroProvider for authentication with LDAP (Basic Auth)
#   - All LDAP configuration parameters (bind user, search bases, filters, etc.)
#   - Authorization provider (XASecurePDPKnox if Ranger enabled, AclsAuthz otherwise)
#   - All configured services (HDFS, YARN, HBASE, HIVE, OOZIE, RANGER, etc.)
#   - Proper SSL/HTTPS configuration based on service settings
#   - Support for High Availability (HA) configurations
#
# Output file: /tmp/odp-proxy.xml
# Returns: 0 on success, 1 on failure
generate_api_proxy_topology() {
    local output_file="/tmp/odp-proxy.xml"
    
    info "Generating proxy topology with ShiroProvider (${output_file##*/})..."
    
    # Get HDFS hosts from mapping file (needed for services)
    local hdfs_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hdfs_line
        hdfs_line=$(grep "^HDFS=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hdfs_line" ]]; then
            hdfs_hosts=$(echo "$hdfs_line" | sed 's/^HDFS=//')
        fi
    fi
    
    if [[ -z "$hdfs_hosts" ]]; then
        error "HDFS hosts not found in mapping file"
        return 1
    fi
    
    # Check if HA is enabled
    local ha_enabled
    ha_enabled=$(check_hdfs_ha_enabled "$hdfs_hosts")
    
    # Determine protocol and port
    local protocol
    protocol=$(get_hdfs_protocol)
    local port
    port=$(get_hdfs_port "$protocol")
    
    # Create XML content with ShiroProvider
    cat > "$output_file" <<EOF
<topology>
    <gateway>
        <provider>
            <role>authentication</role>
            <name>ShiroProvider</name>
            <enabled>true</enabled>
            <param>
                <name>sessionTimeout</name>
                <value>30</value>
            </param>
            <param>
                <name>main.ldapRealm</name>
                <value>org.apache.hadoop.gateway.shirorealm.KnoxLdapRealm</value>
            </param>
            <param>
                <name>main.ldapContextFactory</name>
                <value>org.apache.hadoop.gateway.shirorealm.KnoxLdapContextFactory</value>
            </param>
            <param>
                <name>main.ldapRealm.contextFactory</name>
                <value>\$ldapContextFactory</value>
            </param>
            <param>
                <name>main.ldapRealm.contextFactory.url</name>
                <value>${LDAP_URL}</value>
            </param>
            <param>
                <name>main.ldapRealm.contextFactory.systemUsername</name>
                <value>${LDAP_BIND_USER}</value>
            </param>
            <param>
                <name>main.ldapRealm.contextFactory.systemPassword</name>
                <value>${LDAP_BIND_PASSWORD}</value>
            </param>
            <param>
                <name>main.ldapRealm.contextFactory.authenticationMechanism</name>
                <value>simple</value>
            </param>
            <param>
                <name>urls./**</name>
                <value>authcBasic</value>
            </param>
            <param>
                <name>main.ldapRealm.searchBase</name>
                <value>${LDAP_BASE_DN}</value>
            </param>
            <param>
                <name>main.ldapRealm.userSearchBase</name>
                <value>${LDAP_USER_SEARCH_BASE}</value>
            </param>
            <param>
                <name>main.ldapRealm.userSearchFilter</name>
                <value>${LDAP_USER_SEARCH_FILTER}</value>
            </param>
            <param>
                <name>main.ldapRealm.userObjectClass</name>
                <value>${LDAP_USER_OBJECT_CLASS}</value>
            </param>
            <param>
                <name>main.ldapRealm.userSearchAttributeName</name>
                <value>${LDAP_USER_SEARCH_ATTRIBUTE}</value>
            </param>
            <param>
                <name>main.ldapRealm.groupSearchBase</name>
                <value>${LDAP_GROUP_SEARCH_BASE}</value>
            </param>
            <param>
                <name>main.ldapRealm.groupObjectClass</name>
                <value>${LDAP_GROUP_OBJECT_CLASS}</value>
            </param>
            <param>
                <name>main.ldapRealm.memberAttribute</name>
                <value>${LDAP_MEMBER_ATTRIBUTE}</value>
            </param>
            <param>
                <name>main.ldapRealm.groupIdAttribute</name>
                <value>${LDAP_GROUP_ID_ATTRIBUTE}</value>
            </param>
        </provider>
EOF
    
    # Add authorization provider based on Ranger plugin status
    if [[ "${RANGER_PLUGIN_ENABLED}" = "true" ]]; then
        cat >> "$output_file" <<EOF
        <provider>
            <role>authorization</role>
            <name>XASecurePDPKnox</name>
            <enabled>true</enabled>
        </provider>
EOF
    else
        cat >> "$output_file" <<EOF
        <provider>
            <role>authorization</role>
            <name>AclsAuthz</name>
            <enabled>true</enabled>
        </provider>
EOF
    fi
    
    cat >> "$output_file" <<EOF
        <provider>
            <role>identity-assertion</role>
            <name>Default</name>
            <enabled>true</enabled>
        </provider>
    </gateway>
    
    <service>
        <role>NAMENODE</role>
EOF
    
    if [[ "$ha_enabled" == "true" ]]; then
        # HA enabled - use nameservice
        local nameservice
        nameservice=$(get_hdfs_nameservice)
        if [[ -n "$nameservice" ]]; then
            echo "        <url>hdfs://${nameservice}</url>" >> "$output_file"
        else
            error "HA is enabled but nameservice not found. Using first host as fallback."
            local first_host
            first_host=$(echo "$hdfs_hosts" | cut -d',' -f1)
            echo "        <url>hdfs://${first_host}:8020</url>" >> "$output_file"
        fi
    else
        # HA not enabled - use single host
        local first_host
        first_host=$(echo "$hdfs_hosts" | cut -d',' -f1)
        echo "        <url>hdfs://${first_host}:8020</url>" >> "$output_file"
    fi
    
    cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HDFSUI</role>
        <version>2.7.0</version>
EOF
    
    # Add HDFSUI URLs for each host
    echo "$hdfs_hosts" | tr ',' '\n' | while IFS= read -r host; do
        if [[ -n "$host" ]]; then
            echo "        <url>${protocol}://${host}:${port}</url>" >> "$output_file"
        fi
    done
    
    cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>WEBHDFS</role>
EOF
    
    # Add WEBHDFS URLs for each host
    echo "$hdfs_hosts" | tr ',' '\n' | while IFS= read -r host; do
        if [[ -n "$host" ]]; then
            echo "        <url>${protocol}://${host}:${port}/webhdfs</url>" >> "$output_file"
        fi
    done
    
    cat >> "$output_file" <<EOF
    </service>
    
EOF
    
    # Copy all services from the first XML (YARN, HBASE, HIVE, OOZIE, RANGER, SPARK3, TRINO, PINOT, OZONE, AMBARI)
    # Get YARN hosts
    local yarn_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local yarn_line
        yarn_line=$(grep "^YARN=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$yarn_line" ]]; then
            yarn_hosts=$(echo "$yarn_line" | sed 's/^YARN=//')
        fi
    fi
    
    if [[ -n "$yarn_hosts" ]]; then
        local yarn_protocol
        yarn_protocol=$(get_yarn_protocol)
        local yarn_port
        yarn_port=$(get_yarn_port "$yarn_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>YARNUI</role>
EOF
        
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>YARNUIV2</role>
EOF
        
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>RESOURCEMANAGER</role>
EOF
        
        echo "$yarn_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${yarn_protocol}://${host}:${yarn_port}/ws</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
        
        # Add JOBHISTORYUI
        local jobhistory_details
        jobhistory_details=$(get_jobhistory_details)
        
        if [[ -n "$jobhistory_details" ]]; then
            local jobhistory_host
            local jobhistory_port
            jobhistory_host=$(echo "$jobhistory_details" | cut -d':' -f1)
            jobhistory_port=$(echo "$jobhistory_details" | cut -d':' -f2)
            
            cat >> "$output_file" <<EOF
    <service>
        <role>JOBHISTORYUI</role>
        <url>${yarn_protocol}://${jobhistory_host}:${jobhistory_port}</url>
    </service>
    
EOF
        fi
    fi
    
    # Add all other services (HBASE, HIVE, OOZIE, RANGER, SPARK3, TRINO, PINOT, OZONE, AMBARI)
    # This is a lot of code duplication - we could refactor this later
    # For now, let me just add the essential services that are already generated in the first function
    
    # Get HBASE hosts
    local hbase_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hbase_line
        hbase_line=$(grep "^HBASE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hbase_line" ]]; then
            hbase_hosts=$(echo "$hbase_line" | sed 's/^HBASE=//')
        fi
    fi
    
    if [[ -n "$hbase_hosts" ]]; then
        local hbase_protocol
        hbase_protocol=$(get_hbase_protocol)
        local hbase_port
        hbase_port=$(get_hbase_port)
        
        cat >> "$output_file" <<EOF
    <service>
        <role>HBASE</role>
EOF
        
        echo "$hbase_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hbase_protocol}://${host}:${hbase_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HBASEUI</role>
        <version>2.1.0</version>
EOF
        
        echo "$hbase_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hbase_protocol}://${host}:${hbase_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add HIVE services
    local hive_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local hive_line
        hive_line=$(grep "^HIVE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$hive_line" ]]; then
            hive_hosts=$(echo "$hive_line" | sed 's/^HIVE=//')
        fi
    fi
    
    if [[ -n "$hive_hosts" ]]; then
        local hive_protocol
        hive_protocol=$(get_hive_protocol)
        local hive_port
        hive_port=$(get_hive_port)
        local hive_webui_port
        hive_webui_port=$(get_hive_webui_port)
        
        cat >> "$output_file" <<EOF
    <service>
        <role>HIVE</role>
EOF
        
        echo "$hive_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hive_protocol}://${host}:${hive_port}/cliservice</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>HIVESERVER2UI</role>
EOF
        
        echo "$hive_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${hive_protocol}://${host}:${hive_webui_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add OOZIE services
    local oozie_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local oozie_line
        oozie_line=$(grep "^OOZIE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$oozie_line" ]]; then
            oozie_hosts=$(echo "$oozie_line" | sed 's/^OOZIE=//')
        fi
    fi
    
    if [[ -n "$oozie_hosts" ]]; then
        local oozie_protocol
        oozie_protocol=$(get_oozie_protocol)
        local oozie_port
        oozie_port=$(get_oozie_port "$oozie_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>OOZIE</role>
EOF
        
        echo "$oozie_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${oozie_protocol}://${host}:${oozie_port}/oozie</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>OOZIEUI</role>
EOF
        
        echo "$oozie_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${oozie_protocol}://${host}:${oozie_port}/oozie/</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add RANGER services
    local ranger_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local ranger_line
        ranger_line=$(grep "^RANGER=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$ranger_line" ]]; then
            ranger_hosts=$(echo "$ranger_line" | sed 's/^RANGER=//')
        fi
    fi
    
    if [[ -n "$ranger_hosts" ]]; then
        local ranger_protocol
        ranger_protocol=$(get_ranger_protocol)
        local ranger_port
        ranger_port=$(get_ranger_port "$ranger_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>RANGER</role>
EOF
        
        echo "$ranger_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ranger_protocol}://${host}:${ranger_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
    <service>
        <role>RANGERUI</role>
EOF
        
        echo "$ranger_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ranger_protocol}://${host}:${ranger_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add SPARK3 services
    local spark3_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local spark3_line
        spark3_line=$(grep "^SPARK3=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$spark3_line" ]]; then
            spark3_hosts=$(echo "$spark3_line" | sed 's/^SPARK3=//')
        fi
    fi
    
    if [[ -n "$spark3_hosts" ]]; then
        local spark3_protocol
        spark3_protocol=$(get_spark3_protocol)
        local spark3_port
        spark3_port=$(get_spark3_port)
        
        cat >> "$output_file" <<EOF
    <service>
        <role>SPARK3HISTORYUI</role>
EOF
        
        echo "$spark3_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${spark3_protocol}://${host}:${spark3_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add TRINO services
    local trino_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local trino_line
        trino_line=$(grep "^TRINO=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$trino_line" ]]; then
            trino_hosts=$(echo "$trino_line" | sed 's/^TRINO=//')
        fi
    fi
    
    if [[ -n "$trino_hosts" ]]; then
        local trino_protocol
        trino_protocol=$(get_trino_protocol)
        local trino_port
        trino_port=$(get_trino_port "$trino_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>TRINOUI</role>
EOF
        
        echo "$trino_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${trino_protocol}://${host}:${trino_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add PINOT services
    local pinot_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local pinot_line
        pinot_line=$(grep "^PINOT=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$pinot_line" ]]; then
            pinot_hosts=$(echo "$pinot_line" | sed 's/^PINOT=//')
        fi
    fi
    
    if [[ -n "$pinot_hosts" ]]; then
        local pinot_protocol
        pinot_protocol=$(get_pinot_protocol)
        local pinot_port
        pinot_port=$(get_pinot_port "$pinot_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>PINOT</role>
EOF
        
        echo "$pinot_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${pinot_protocol}://${host}:${pinot_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add OZONE services
    local ozone_hosts
    if [[ -f "/tmp/knox-service-hosts-mapping.txt" ]]; then
        local ozone_line
        ozone_line=$(grep "^OZONE=" /tmp/knox-service-hosts-mapping.txt | head -n 1)
        if [[ -n "$ozone_line" ]]; then
            ozone_hosts=$(echo "$ozone_line" | sed 's/^OZONE=//')
        fi
    fi
    
    if [[ -n "$ozone_hosts" ]]; then
        local ozone_protocol
        ozone_protocol=$(get_ozone_protocol)
        local ozone_port
        ozone_port=$(get_ozone_port "$ozone_protocol")
        
        cat >> "$output_file" <<EOF
    <service>
        <role>OZONE-RECON</role>
EOF
        
        echo "$ozone_hosts" | tr ',' '\n' | while IFS= read -r host; do
            if [[ -n "$host" ]]; then
                echo "        <url>${ozone_protocol}://${host}:${ozone_port}</url>" >> "$output_file"
            fi
        done
        
        cat >> "$output_file" <<EOF
    </service>
    
EOF
    fi
    
    # Add AMBARI services
    cat >> "$output_file" <<EOF
    <service>
        <role>AMBARI</role>
        <url>${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}</url>
    </service>
    
    <service>
        <role>AMBARIUI</role>
        <url>${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}</url>
    </service>
    
EOF
    
    # Close topology
    echo "</topology>" >> "$output_file"
    
    info "Proxy topology generated successfully"
    return 0
}

#---------------------------
# Main Execution Flow
#---------------------------
# This is the main script execution flow that:
#   1. Fetches Knox Gateway host information
#   2. Discovers available Ambari services
#   3. Retrieves host information for all services and their components
#   4. Generates topology XML files based on user selection (SSO, API, or both)
#   5. Displays completion message and copy instructions

info "Starting Knox topology generation..."

# Step 1: Fetch Knox Gateway host information
# This is required for SSO topology generation (SSOCookieProvider configuration)
fetch_knox_gateway

# Step 2: Discover and fetch list of available Ambari services
# Services matching EXCLUDED_SERVICES are filtered out
fetch_services

# Step 3: Retrieve host information for all services and their components
# This populates service-to-host mappings needed for topology generation
get_hosts_for_all_services

# Step 4: Generate topology files based on user selection
generated_files=""

# Generate SSO Proxy Topology if selected (uses SSOCookieProvider)
if [[ "$GENERATE_SSO" == "true" ]]; then
    generate_sso_proxy_topology
    generated_files="/tmp/odp-proxy-sso.xml"
fi

# Generate API Proxy Topology if selected (uses ShiroProvider with LDAP)
if [[ "$GENERATE_API" == "true" ]]; then
    generate_api_proxy_topology
    if [[ -n "$generated_files" ]]; then
        generated_files="${generated_files}, /tmp/odp-proxy.xml"
    else
        generated_files="/tmp/odp-proxy.xml"
    fi
fi

info "Topology generation completed successfully"
info "Generated files: ${generated_files}"
echo ""

# Only show copy instructions if files were generated
# Display scp commands only for the files that were actually generated
# We check both the flag AND file existence to ensure accuracy
if [[ -n "$generated_files" ]]; then
    echo ""
    echo -e "${CYAN}Next Steps:${NC}"
    echo ""
    echo "Copy the generated topology files to the Knox Gateway host:"
    echo ""
    
    # Show SSO file scp command only if SSO topology was generated AND file exists
    if [[ "$GENERATE_SSO" == "true" ]] && [[ -f "/tmp/odp-proxy-sso.xml" ]]; then
        echo "  scp /tmp/odp-proxy-sso.xml ${KNOX_GATEWAY}:/etc/knox/conf/topologies/"
    fi
    
    # Show API file scp command only if API topology was generated AND file exists
    if [[ "$GENERATE_API" == "true" ]] && [[ -f "/tmp/odp-proxy.xml" ]]; then
        echo "  scp /tmp/odp-proxy.xml ${KNOX_GATEWAY}:/etc/knox/conf/topologies/"
    fi
    
    echo ""
fi
