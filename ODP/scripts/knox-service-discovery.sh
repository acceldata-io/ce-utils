#!/bin/bash
# Acceldata Inc.
set -euo pipefail
IFS=$'\n\t'

#---------------------------
# Color Variables
#---------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#---------------------------
# Check if Knox Process is Running
#---------------------------
if ! ps aux | grep -q "[k]nox-server.*gateway.jar"; then
  echo -e "${RED}[ERROR] Knox process is not running. Please ensure Knox is up and running on the Knox node.${NC}"
  exit 1
fi

#---------------------------
# Configuration Variables (Update these placeholders with your environment details)
#---------------------------
AMBARI_SERVER="your-ambari-server.domain.com"
AMBARI_USER="your-ambari-user"
AMBARI_PASSWORD="your-ambari-password"
AMBARI_PORT=8080
AMBARI_PROTOCOL="http"

LDAP_HOST="your-ldap-host.domain.com"
LDAP_PROTOCOL="ldap"        # Use "ldaps" for secure connections if needed
LDAP_PORT=389
LDAP_URL="${LDAP_PROTOCOL}://${LDAP_HOST}:${LDAP_PORT}"
LDAP_BIND_USER="your-ldap-bind-user@domain.com"
LDAP_BIND_PASSWORD="your-ldap-bind-password"
LDAP_BASE_DN="DC=your,DC=domain,DC=com"
LDAP_USER_SEARCH_BASE="OU=users,OU=yourOU,DC=your,DC=domain,DC=com"
LDAP_GROUP_SEARCH_BASE="OU=groups,OU=yourOU,DC=your,DC=domain,DC=com"
LDAP_USER_OBJECT_CLASS="person"
LDAP_USER_SEARCH_ATTRIBUTE="sAMAccountName"
LDAP_GROUP_OBJECT_CLASS="group"
LDAP_GROUP_ID_ATTRIBUTE="cn"
LDAP_MEMBER_ATTRIBUTE="member"
LDAP_USER_SEARCH_FILTER="(&amp;(objectclass=${LDAP_USER_OBJECT_CLASS})(${LDAP_USER_SEARCH_ATTRIBUTE}={0}))"
LDAP_GROUP_SEARCH_FILTER="(&amp;(objectClass:${LDAP_GROUP_OBJECT_CLASS})(|(${LDAP_GROUP_ID_ATTRIBUTE}=*)))"

# Topology file base names (used for descriptor creation and topology file naming)
TOPOLOGY_SSO_PROXY_UI="odp-sso-proxy-ui"
TOPOLOGY_PROXY="odp-proxy"

#---------------------------
# Logging Functions
#---------------------------
info() {
    echo -e "${GREEN}[INFO] $*${NC}"
}
error() {
    echo -e "${RED}[ERROR] $*${NC}" >&2
}

#---------------------------
# Check for Required Commands
#---------------------------
check_requirements() {
    for cmd in curl perl; do
        if ! command -v "$cmd" &>/dev/null; then
            error "Required command '$cmd' is not installed. Aborting."
            exit 1
        fi
    done
}
check_requirements

#---------------------------
# Ensure Script is Run as Root
#---------------------------
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Use sudo."
  exit 1
fi

#---------------------------
# Function to Retrieve Ambari Cluster Name
#---------------------------
fetch_cluster() {
    info "Fetching Ambari cluster details..."
    CLUSTER=$(curl -s -k -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -i -H 'X-Requested-By: ambari' \
      "${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters" \
      | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
    if [[ -z "${CLUSTER}" ]]; then
        error "Failed to retrieve the cluster name. Verify Ambari credentials and URL."
        exit 1
    fi
    info "Cluster found: ${CLUSTER}"
}
# Fetch cluster name first so it can be shown to the user.
fetch_cluster

#---------------------------
# Display Configuration & Confirm
#---------------------------
echo -e "${YELLOW}========================================================"
echo "Configuration Variables:"
echo "--------------------------------------------------------"
echo "AMBARI_SERVER:           $AMBARI_SERVER"
echo "AMBARI_USER:             $AMBARI_USER"
echo "AMBARI_PASSWORD:         $AMBARI_PASSWORD"
echo "AMBARI_PORT:             $AMBARI_PORT"
echo "AMBARI_PROTOCOL:         $AMBARI_PROTOCOL"
echo "Cluster Name:            $CLUSTER"
echo "LDAP_HOST:               $LDAP_HOST"
echo "LDAP_PROTOCOL:           $LDAP_PROTOCOL"
echo "LDAP_PORT:               $LDAP_PORT"
echo "LDAP_URL:                $LDAP_URL"
echo "LDAP_BIND_USER:          $LDAP_BIND_USER"
echo "LDAP_BIND_PASSWORD:      $LDAP_BIND_PASSWORD"
echo "LDAP_BASE_DN:            $LDAP_BASE_DN"
echo "LDAP_USER_SEARCH_FILTER: $LDAP_USER_SEARCH_FILTER"
echo "LDAP_GROUP_SEARCH_FILTER: $LDAP_GROUP_SEARCH_FILTER"
echo "LDAP_USER_SEARCH_BASE:   $LDAP_USER_SEARCH_BASE"
echo "LDAP_GROUP_SEARCH_BASE:  $LDAP_GROUP_SEARCH_BASE"
echo "LDAP_USER_OBJECT_CLASS:  $LDAP_USER_OBJECT_CLASS"
echo "LDAP_USER_SEARCH_ATTR:   $LDAP_USER_SEARCH_ATTRIBUTE"
echo "LDAP_GROUP_OBJECT_CLASS: $LDAP_GROUP_OBJECT_CLASS"
echo "LDAP_GROUP_ID_ATTR:      $LDAP_GROUP_ID_ATTRIBUTE"
echo "LDAP_MEMBER_ATTR:        $LDAP_MEMBER_ATTRIBUTE"
echo "TOPOLOGY_SSO_PROXY_UI:   $TOPOLOGY_SSO_PROXY_UI"
echo "TOPOLOGY_PROXY:          $TOPOLOGY_PROXY"
echo "========================================================${NC}\n"
echo -e "${YELLOW}Proceed with these configuration variables? (y/n): ${NC}"
read -r confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${RED}User aborted. Exiting.${NC}"
    exit 1
fi

#---------------------------
# Function to Get Host for a Component
#---------------------------
get_host_for_component() {
  local component="$1"
  curl -s -k -u "${AMBARI_USER}:${AMBARI_PASSWORD}" -H 'X-Requested-By: ambari' \
    "${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}/api/v1/clusters/${CLUSTER}/host_components?HostRoles/component_name=${component}" \
    | grep -o '"host_name" : "[^"]*' | sed 's/"host_name" : "//' | head -n 1
}

fetch_knox_gateway() {
    export KNOX_GATEWAY=$(get_host_for_component "KNOX_GATEWAY")
    if [[ -z "$KNOX_GATEWAY" ]]; then
      error "Failed to retrieve KNOX_GATEWAY host. Exiting."
      exit 1
    fi
    info "KNOX_GATEWAY host: ${KNOX_GATEWAY}"
}
fetch_knox_gateway

#---------------------------
# Create Knox Alias for Ambari Discovery Password
#---------------------------
create_knox_alias() {
    info "Creating Knox alias for Ambari discovery password..."
    /usr/odp/current/knox-server/bin/knoxcli.sh create-alias ambari.discovery.password --value "${AMBARI_PASSWORD}"
}
create_knox_alias

#---------------------------
# Delete Existing Topology Files if They Exist
#---------------------------
delete_topology_files() {
    TOPOLOGY_FILES=(
      "/usr/odp/current/knox-server/conf/topologies/${TOPOLOGY_SSO_PROXY_UI}.xml"
      "/usr/odp/current/knox-server/conf/topologies/${TOPOLOGY_PROXY}.xml"
    )
    for file in "${TOPOLOGY_FILES[@]}"; do
      if [[ -f "$file" ]]; then
        info "Deleting existing topology file: $file"
        rm -f "$file"
      else
        info "Topology file $file does not exist; nothing to delete."
      fi
    done
}
delete_topology_files

sleep 5

#---------------------------
# Write Knox Custom Provider Configuration
#---------------------------
write_custom_provider() {
    KNOX_CUSTOM_PROVIDER="/etc/knox/conf/shared-providers/custom-provider.xml"
    TARGET_DIR=$(dirname "${KNOX_CUSTOM_PROVIDER}")
    if [[ ! -d "${TARGET_DIR}" ]]; then
      error "Directory ${TARGET_DIR} does not exist. Exiting."
      exit 1
    fi
    info "Writing Knox custom provider configuration to ${KNOX_CUSTOM_PROVIDER}..."
    cat <<EOF > "${KNOX_CUSTOM_PROVIDER}"
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
		<!-- main.ldapRealm.contextFactory needs to be placed before other main.ldapRealm.contextFactory* entries  -->
		<param>
			<name>main.ldapRealm.contextFactory</name>
			<value>\$ldapContextFactory</value>
		</param>
		<param>
			<name>main.ldapRealm.contextFactory.url</name>
			<value>${LDAP_PROTOCOL}://${LDAP_HOST}:${LDAP_PORT}</value>
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
</gateway>
EOF
    chown knox:hadoop "${KNOX_CUSTOM_PROVIDER}"
    info "Custom provider configuration updated successfully."
}
write_custom_provider

#---------------------------
# Write ODP SSO Provider Configuration (JSON)
#---------------------------
write_sso_provider() {
    SSO_PROVIDER_CONFIG="/etc/knox/conf/shared-providers/odp-sso-provider.json"
    TARGET_DIR=$(dirname "${SSO_PROVIDER_CONFIG}")
    if [[ ! -d "${TARGET_DIR}" ]]; then
      error "Directory ${TARGET_DIR} does not exist. Exiting."
      exit 1
    fi
    info "Writing ODP SSO provider configuration to ${SSO_PROVIDER_CONFIG}..."
    cat <<EOF > "${SSO_PROVIDER_CONFIG}"
{
  "providers": [
    {
      "role": "federation",
      "name": "SSOCookieProvider",
      "enabled": "true",
      "params": {
        "sso.authentication.provider.url": "https://${KNOX_GATEWAY}:8443/gateway/knoxsso/api/v1/websso"
      }
    },
    {
      "role": "identity-assertion",
      "name": "HadoopGroupProvider",
      "enabled": "true",
      "params": {
        "hadoop.security.group.mapping": "org.apache.hadoop.security.LdapGroupsMapping",
        "hadoop.security.group.mapping.ldap.url": "${LDAP_URL}",
        "hadoop.security.group.mapping.ldap.bind.user": "${LDAP_BIND_USER}",
        "hadoop.security.group.mapping.ldap.bind.password": "${LDAP_BIND_PASSWORD}",
        "hadoop.security.group.mapping.ldap.base": "${LDAP_GROUP_SEARCH_BASE}",
        "hadoop.security.group.mapping.ldap.search.filter.user": "${LDAP_USER_SEARCH_FILTER}",
        "hadoop.security.group.mapping.ldap.search.attr.member": "${LDAP_MEMBER_ATTRIBUTE}",
        "hadoop.security.group.mapping.ldap.search.attr.group.name": "${LDAP_GROUP_ID_ATTRIBUTE}",
        "hadoop.security.group.mapping.ldap.search.filter.group": "${LDAP_GROUP_SEARCH_FILTER}"
      }
    },
    {
      "role": "authorization",
      "name": "AclsAuthz",
      "enabled": "true"
    }
  ]
}
EOF
    chown knox:hadoop "${SSO_PROVIDER_CONFIG}"
    info "ODP SSO provider configuration updated successfully."
}
write_sso_provider

#---------------------------
# Create Descriptor JSON Files in /etc/knox/conf/descriptors
#---------------------------
write_descriptors() {
    DESCRIPTORS_DIR="/etc/knox/conf/descriptors"
    if [[ ! -d "${DESCRIPTORS_DIR}" ]]; then
      error "Directory ${DESCRIPTORS_DIR} does not exist. Exiting."
      exit 1
    fi

    # Descriptor file 1: odp-sso-proxy-ui.json with provider-config-ref "odp-sso-provider"
    SSO_DESCRIPTOR="${DESCRIPTORS_DIR}/${TOPOLOGY_SSO_PROXY_UI}.json"
    info "Creating descriptor file ${SSO_DESCRIPTOR}..."
    cat <<EOF > "${SSO_DESCRIPTOR}"
{
  "discovery-type": "Ambari",
  "discovery-address": "${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}",
  "discovery-user": "${AMBARI_USER}",
  "discovery-pwd-alias": "ambari.discovery.password",
  "cluster": "${CLUSTER}",
  "provider-config-ref": "odp-sso-provider",
  "services": [
    { "name": "AMBARI" },
    { "name": "AMBARIUI" },
    { "name": "HBASEUI" },
    { "name": "HDFSUI" },
    { "name": "JOBHISTORYUI" },
    { "name": "KNOXSSO" },
    { "name": "NAMENODE" },
    { "name": "NIFI" },
    { "name": "OOZIEUI" },
    { "name": "RANGER" },
    { "name": "RANGERUI" },
    { "name": "SPARKHISTORYUI" },
    { "name": "SPARK3HISTORYUI" },
    { "name": "YARNUI" },
    { "name": "YARNUIV2" },
    { "name": "ZEPPELINUI" }
  ]
}
EOF
    chown knox:hadoop "${SSO_DESCRIPTOR}"
    info "Descriptor ${SSO_DESCRIPTOR} created."

    # Descriptor file 2: odp-proxy.json with provider-config-ref "custom-provider"
    PROXY_DESCRIPTOR="${DESCRIPTORS_DIR}/${TOPOLOGY_PROXY}.json"
    info "Creating descriptor file ${PROXY_DESCRIPTOR}..."
    cat <<EOF > "${PROXY_DESCRIPTOR}"
{
  "discovery-type": "Ambari",
  "discovery-address": "${AMBARI_PROTOCOL}://${AMBARI_SERVER}:${AMBARI_PORT}",
  "discovery-user": "${AMBARI_USER}",
  "discovery-pwd-alias": "ambari.discovery.password",
  "cluster": "${CLUSTER}",
  "provider-config-ref": "custom-provider",
  "services": [
    { "name": "AMBARI" },
    { "name": "AMBARIUI" },
    { "name": "HBASEUI" },
    { "name": "HDFSUI" },
    { "name": "JOBHISTORYUI" },
    { "name": "KNOXSSO" },
    { "name": "NAMENODE" },
    { "name": "NIFI" },
    { "name": "HIVE" },
    { "name": "JOBTRACKER" },
    { "name": "LIVYSERVER" },
    { "name": "SOLR" },
    { "name": "OOZIE" },
    { "name": "OOZIEUI" },
    { "name": "RANGER" },
    { "name": "RANGERUI" },
    { "name": "RESOURCEMANAGER" },
    { "name": "RESOURCEMANAGERAPI" },
    { "name": "SPARKHISTORYUI" },
    { "name": "SPARK3HISTORYUI" },
    { "name": "WEBHBASE" },
    { "name": "WEBHDFS" },
    { "name": "YARNUI" },
    { "name": "YARNUIV2" },
    { "name": "ZEPPELIN" },
    { "name": "ZEPPELINWS" },
    { "name": "ZEPPELINUI" }
  ]
}
EOF
    chown knox:hadoop "${PROXY_DESCRIPTOR}"
    info "Descriptor ${PROXY_DESCRIPTOR} created."
}
write_descriptors

#---------------------------
# Update Topology Files for LDAP Filter Escaping
#---------------------------
update_topology_files() {
    TOPOLOGY_FILE_1="/usr/odp/current/knox-server/conf/topologies/${TOPOLOGY_SSO_PROXY_UI}.xml"
    TOPOLOGY_FILE_2="/usr/odp/current/knox-server/conf/topologies/${TOPOLOGY_PROXY}.xml"
    TOPOLOGY_FILES=("$TOPOLOGY_FILE_1" "$TOPOLOGY_FILE_2")

    info "Waiting for all topology files to be present..."
    while true; do
      all_present=true
      for file in "${TOPOLOGY_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
          all_present=false
          break
        fi
      done
      if $all_present; then
        info "All topology files are present."
        break
      else
        info "Not all topology files are present yet. Waiting..."
        sleep 5
      fi
    done

    for file in "${TOPOLOGY_FILES[@]}"; do
      info "Updating LDAP search filter in topology file $file ..."
      # Replace bare "(&" with "(&amp;" (if not already replaced) using Perl with negative lookahead
      perl -pi -e 's/\(\&(?!amp;)/(&amp;/g' "$file"
      info "Updated $file."
      touch "$file"
      info "Touched topology file: $file"
    done
}
update_topology_files

info "All Knox configurations updated successfully!"
