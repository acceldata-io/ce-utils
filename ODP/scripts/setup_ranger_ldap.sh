#!/bin/bash
# Acceldata Inc.

# Display messages with colors and formatting
GREEN='\033[0;32m'
NC='\033[0m'  # No Color

export AMBARISERVER=`hostname -f`
export USER=admin
export PASSWORD=admin
export PORT=8080
export PROTOCOL=http

export LDAP_HOSTNAME="ad.adsre.com"
export LDAP_PORT=636
export LDAP_URL="ldap://$LDAP_HOSTNAME:$LDAP_PORT"
export BASE_DN="DC=adsre,DC=com"
export DOMAIN="adsre.com"
export GROUP_FILTER="" # Add Filters via Ambari UI or use small filter string
export USER_FILTER="" # Add Filters via Ambari UI, or use small filter string
export SEARCH_USER_BASE="OU=users,OU=hadoop,DC=adsre,DC=com"
export BIND_USER="Administrator@ADSRE.COM"  # use UserPrincipalName only, do not use DN name
export BIND_USER_PASSWORD="PASSWORD"
export AMBARI_ADMIN_USER=admin
export AMBARI_ADMIN_PASSWORD=admin
export userObjectClass=person
export usernameAttribute=sAMAccountName
export groupObjectClass=group
export groupNamingAttr=cn
export groupMembershipAttr=member
export referral=ignore
export Groupsearchbase="OU=groups,OU=hadoop,DC=adsre,DC=com"

# curl command to get the required details from Ambari Cluster
CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

# Display LDAP-related variables with color
echo -e "${GREEN}Ambari URL:-${NC} $PROTOCOL://$AMBARISERVER:$PORT"
echo -e "${GREEN}LDAP Configuration Variables:${NC}"
echo -e "${GREEN}LDAP Hostname:${NC} $LDAP_HOSTNAME"
echo -e "${GREEN}LDAP Port:${NC} $LDAP_PORT"
echo -e "${GREEN}LDAP URL:${NC} $LDAP_URL"
echo -e "${GREEN}Base DN:${NC} $BASE_DN"
echo -e "${GREEN}Domain:${NC} $DOMAIN"
echo -e "${GREEN}Group Filter:${NC} $GROUP_FILTER"
echo -e "${GREEN}User Filter:${NC} $USER_FILTER"
echo -e "${GREEN}Search User Base:${NC} $SEARCH_USER_BASE"
echo -e "${GREEN}Bind User:${NC} $BIND_USER"
echo -e "${GREEN}Bind User Password:${NC} ********"  # Replace with actual password
echo -e "${GREEN}User Object Class:${NC} $userObjectClass"
echo -e "${GREEN}Username Attribute:${NC} $usernameAttribute"
echo -e "${GREEN}Group Object Class:${NC} $groupObjectClass"
echo -e "${GREEN}Group Naming Attribute:${NC} $groupNamingAttr"
echo -e "${GREEN}Group Membership Attribute:${NC} $groupMembershipAttr"
echo -e "${GREEN}Referral:${NC} $referral"
echo -e "${GREEN}Group Search Base:${NC} $Groupsearchbase"

echo "Make sure to update Ranger Usersync Truststore with LDAP Certificate"

# Function to set configurations
set_config() {
    local config_file=$1
    local key=$2
    local value=$3

    python /var/lib/ambari-server/resources/scripts/configs.py \
        -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER \
        -c $config_file -k $key -v $value
}

enable_ldap_usersync() {
    set_config "ranger-ugsync-site"  "ranger.usersync.group.nameattribute" "groupNamingAttr"
    set_config "ranger-ugsync-site"  "ranger.usersync.sink.impl.class" "org.apache.ranger.unixusersync.process.PolicyMgrUserGroupBuilder"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.referral" "$referral"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.searchenabled" "true"
    set_config "ranger-ugsync-site"  "ranger.usersync.pagedresultssize" "500"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.deltasync" "true"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.searchbase" "$Groupsearchbase"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.searchfilter" "$GROUP_FILTER"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.objectclass" "$groupObjectClass"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.search.first.enabled" "true"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.url" "$LDAP_URL"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.usermapsyncenabled" "true"
    set_config "ranger-ugsync-site"  "ranger.usersync.source.impl.class" "org.apache.ranger.ldapusersync.process.LdapUserGroupBuilder"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.nameattribute" "$usernameAttribute"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.searchbase" "$BASE_DN"
    set_config "ranger-ugsync-site"  "ranger.usersync.group.memberattributename" "$groupMembershipAttr"
    set_config "ranger-ugsync-site"  "ranger.usersync.enabled" "true"
    set_config "ranger-ugsync-site"  "ranger.usersync.user.searchenabled" "false"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.binddn" "$BIND_USER"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.searchbase" "$SEARCH_USER_BASE"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.searchfilter" "$USER_FILTER"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.searchscope" "sub"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.user.objectclass" "$userObjectClass"
    set_config "ranger-ugsync-site"  "ranger.usersync.ldap.ldapbindpassword" "$BIND_USER_PASSWORD"

}

enable_ldap_ranger_ui() {
    set_config "ranger-admin-site" "ranger.authentication.method" "ACTIVE_DIRECTORY"
    set_config "ranger-admin-site" "ranger.ldap.ad.bind.password" "$BIND_USER_PASSWORD"
    set_config "ranger-admin-site" "ranger.ldap.ad.referral" "$referral"
    set_config "ranger-admin-site" "ranger.ldap.ad.domain" "$DOMAIN"
    set_config "ranger-admin-site" "ranger.ldap.ad.user.searchfilter" "(sAMAccountName={0})"
    set_config "ranger-admin-site" "ranger.ldap.ad.base.dn" "$BASE_DN"
    set_config "ranger-admin-site" "ranger.ldap.ad.url" "$LDAP_URL"
}

# Display service options
function display_service_options() {
    echo "Select services to enable LDAP:"
    echo "1) Ranger Usersync LDAP"
    echo "2) Ranger UI LDAP"
    echo "A) All"
    echo "Q) Quit"
}


# Select services to enable SSL
while true; do
    display_service_options
    read -p "Enter your choice: " choice

    case $choice in
        1)
            enable_ldap_usersync
            ;;
        2)
            enable_ldap_ranger_ui
            ;;
        [Aa])
            for service in "usersync" "ranger_ui"; do
                enable_ldap_${service}
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
echo "PLEASE RESTART RANGER SERVICE"
