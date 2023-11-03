#!/bin/bash
# Acceldata Inc.

set -e

# User-defined variables

LDAP_HOSTNAME="ad-server.com"
LDAP_PORT="389"
BASE_DN="dc=accelo,dc=com"
GROUP_FILTER=""
SEARCH_USER_BASE=""
BIND_USER="cn=Manager,dc=accelo,dc=com"
BIND_USER_PASSWORD="PASSWORD"
AMBARI_ADMIN_USER="admin"
AMBARI_ADMIN_PASSWORD="admin"
userObjectClass="person"
usernameAttribute="sAMAccountName"
groupObjectClass="group"
groupNamingAttr="cn"
groupMembershipAttr="member"
useSSL="false"
referral="ignore"
export truststore=/opt/security/pki/ca-certs.jks
export truststorepassword=Password

# Check if LDAP_PORT is 636 (SSL enabled) and set LDAP_SSL accordingly
if [ "$LDAP_PORT" = "636" ]; then
    LDAP_SSL=true
else
    LDAP_SSL=false
fi

# Check if Ambari is already configured for LDAP
if grep -q "ambari.server.ldap.enabled=true" /etc/ambari-server/conf/ambari.properties; then
    echo "Ambari is already configured for LDAP. Exiting..."
    exit 1
fi

# Function to prompt yes/no and proceed
prompt_yes_no() {
    while true; do
        read -p "$1 (yes/no): " choice
        case "$choice" in
            [Yy]es ) return 0;;
            [Nn]o ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Prompt for variable validation before proceeding
echo "Please double-check the following variables before proceeding:"
echo "LDAP_HOSTNAME: $LDAP_HOSTNAME"
echo "LDAP_PORT: $LDAP_PORT"
echo "BASE_DN: $BASE_DN"
echo "GROUP_FILTER: $GROUP_FILTER"
echo "SEARCH_USER_BASE: $SEARCH_USER_BASE"
echo "BIND_USER: $BIND_USER"
echo "BIND_USER_PASSWORD: *** (not shown for security)"
echo "AMBARI_ADMIN_USER: $AMBARI_ADMIN_USER"
echo "AMBARI_ADMIN_PASSWORD: *** (not shown for security)"
echo "userObjectClass: $userObjectClass"
echo "usernameAttribute: $usernameAttribute"
echo "groupObjectClass: $groupObjectClass"
echo "groupNamingAttr: $groupNamingAttr"
echo "groupMembershipAttr: $groupMembershipAttr"
echo "useSSL: $useSSL"
echo "referral: $referral"

if ! prompt_yes_no "Do the variables look correct for LDAP configuration?"; then
    echo "Exiting..."
    exit 1
fi

# Rest of the script...

# Configure Ambari LDAP settings
ambari-server setup-ldap \
    --ldap-url="$LDAP_HOSTNAME:$LDAP_PORT" \
    --ldap-user-class="$userObjectClass" \
    --ldap-user-attr="$usernameAttribute" \
    --ldap-group-class="$groupObjectClass" \
    --ldap-type="AD" \
    --ldap-ssl="$LDAP_SSL" \
    --ldap-referral="ignore" \
    --ldap-group-attr="$groupNamingAttr" \
    --ldap-member-attr="$groupMembershipAttr" \
    --ldap-dn="$BIND_USER" \
    --ldap-base-dn="$BASE_DN" \
    --ldap-bind-anonym=false \
    --ldap-manager-dn="$BIND_USER" \
    --ldap-manager-password="$BIND_USER_PASSWORD" \
    --ldap-save-settings \
    --ldap-sync-username-collisions-behavior=convert \
    --ldap-force-setup \
    --ldap-force-lowercase-usernames=true \
    --ldap-pagination-enabled=false \
    --ambari-admin-username="$AMBARI_ADMIN_USER" \
    --ambari-admin-password="$AMBARI_ADMIN_PASSWORD" \
    --truststore-type=jks \
    --truststore-path="$truststore" \
    --truststore-password="$truststorepassword" \
    --ldap-secondary-host="" \
    --ldap-secondary-port=0 \
    --ldap-sync-disable-endpoint-identification=true

echo "LDAP configuration for Ambari completed."
echo "Please restart Ambari Server and sync the users using ambari-server sync-ldap [option]"
