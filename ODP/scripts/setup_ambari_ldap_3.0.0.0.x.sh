#!/bin/bash
##########################################################################
# Ambari Server LDAP/AD Authentication Configuration Script
#
# This script automates the setup of LDAP or Active Directory authentication
# for Apache Ambari Server, including truststore configuration for LDAPS.
#
# Usage:
#   bash setup_ambari_ldap.sh
#   DEBUG=1 bash setup_ambari_ldap.sh    # Enable verbose shell trace
#
##########################################################################
set -e

# ======================================================================
# CONFIG — edit these values for your environment
# ======================================================================

# --- Directory server endpoint ---
LDAP_HOSTNAME="ldap.corp.example.com"             # LDAP/AD server hostname or IP
LDAP_PORT="636"                                   # 389 (LDAP) | 636 (LDAPS) | 3268 (AD GC) | 3269 (AD GC-LDAPS)
LDAP_TYPE="AD"                                    # AD (Active Directory) | IPA | Generic LDAP

# --- Directory search ---
BASE_DN="DC=corp,DC=example,DC=com"               # Search root: for AD use DC=....; for OpenLDAP use dc=...
REFERRAL="ignore"                                 # follow | ignore (usually ignore for AD)

# --- Bind credentials (service account) ---
# Ambari uses this account to query the directory for users/groups during login.
# For AD: UPN (user@domain.com) or distinguished name
# For OpenLDAP: distinguished name (e.g., cn=ambari,ou=services,dc=corp,dc=example,dc=com)
BIND_USER="svc-ambari@corp.example.com"
BIND_USER_PASSWORD="ChangeMe!SecurePassword123"
BIND_ANONYM="false"                               # Use true for anonymous bind (rare in production)

# --- Ambari REST API credentials (local Ambari admin) ---
# These are the *Ambari* admin credentials, not LDAP.
# Used to push configuration changes to Ambari via its REST API.
AMBARI_ADMIN_USER="admin"
AMBARI_ADMIN_PASSWORD="ChangeMe!AmbariPassword"

# --- Schema attributes (defaults below work for Active Directory) ---
userObjectClass="person"                          # AD: person      | OpenLDAP: inetOrgPerson | IPA: posixAccount
usernameAttribute="sAMAccountName"                # AD: sAMAccountName (or userPrincipalName) | OpenLDAP: uid
groupObjectClass="group"                          # AD: group       | OpenLDAP: posixGroup    | IPA: ipausergroup
groupNamingAttr="cn"                              # usually cn
groupMembershipAttr="member"                      # attr on the group listing its members (AD/OpenLDAP: member)
userGroupMemberAttr="memberof"                    # attr on the user listing their groups (AD: memberOf)
dnAttribute="distinguishedName"                   # DN attribute name (AD: distinguishedName | OpenLDAP: entryDN)

# --- Sync / login behavior ---
SYNC_COLLISIONS="convert"                         # convert | skip — how to handle username clashes on sync
FORCE_LOWERCASE_USERNAMES="true"                  # true recommended to avoid case-mismatch login issues
PAGINATION_ENABLED="false"                        # true if your directory enforces result size limits

# --- Enable LDAP + propagate to services ---
LDAP_ENABLED_AMBARI="true"                        # flip ambari.ldap.authentication.enabled
LDAP_MANAGE_SERVICES="true"                       # let Ambari push LDAP config to services
LDAP_ENABLED_SERVICES="*"                         # "*" = all, or "HDFS,HIVE,RANGER"

# --- Truststore (for LDAPS on port 636 or 3269) ---
# Required if LDAP_PORT is 636/3269 (LDAPS). Should contain your organization's CA
# certificate(s) that signed the LDAP server's certificate.
# See: ambari-server setup-security for how Ambari stores/manages truststores.
export truststore="/var/lib/ambari-server/resources/security/ldap-truststore.jks"
export truststorepassword="ChangeMe!TruststorePassword"
TRUSTSTORE_TYPE="jks"                             # jks | jceks | pkcs12

# ======================================================================
# End CONFIG — you should not need to edit below this line
# ======================================================================

# ----------------------------------------------------------------------
# Output formatting helpers
# ----------------------------------------------------------------------
if [ -t 1 ]; then
    BOLD=$(tput bold)
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    NC=$(tput sgr0)
else
    BOLD=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""
fi

log_section() { printf "\n${BOLD}${BLUE}==> %s${NC}\n" "$1"; }
log_info()    { printf "${CYAN}[INFO]${NC}  %s\n" "$1"; }
log_ok()      { printf "${GREEN}[ OK ]${NC}  %s\n" "$1"; }
log_warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$1"; }
log_err()     { printf "${RED}[FAIL]${NC}  %s\n" "$1" >&2; }

# Debug toggle: run with `DEBUG=1 bash setup_ambari_ldap.sh` for full tracing
DEBUG="${DEBUG:-0}"

# Persistent log for the setup-ldap invocation
LDAP_SETUP_LOG="/var/log/ambari-ldap-setup-$(date +%Y%m%d-%H%M%S).log"

# ----------------------------------------------------------------------
# Derive LDAP_SSL from port
# ----------------------------------------------------------------------
# Port 636: Standard LDAPS (LDAP over SSL)
# Port 3269: Global Catalog LDAPS (Active Directory)
if [ "$LDAP_PORT" = "636" ] || [ "$LDAP_PORT" = "3269" ]; then
    LDAP_SSL=true
else
    LDAP_SSL=false
fi

# ----------------------------------------------------------------------
# Preflight: skip if Ambari is already LDAP-configured
# ----------------------------------------------------------------------
log_section "Preflight checks"
if grep -q "ambari.server.ldap.enabled=true" /etc/ambari-server/conf/ambari.properties; then
    log_warn "Ambari is already configured for LDAP. Exiting..."
    exit 1
fi
log_ok "Ambari is not yet LDAP-configured — continuing."

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

# ----------------------------------------------------------------------
# Variable review
# ----------------------------------------------------------------------
log_section "Review LDAP variables"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_HOSTNAME:"             "$LDAP_HOSTNAME"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_PORT:"                 "$LDAP_PORT"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_TYPE:"                 "$LDAP_TYPE"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_SSL (derived):"        "$LDAP_SSL"
printf "  ${BOLD}%-27s${NC} %s\n" "BASE_DN:"                   "$BASE_DN"
printf "  ${BOLD}%-27s${NC} %s\n" "REFERRAL:"                  "$REFERRAL"
printf "  ${BOLD}%-27s${NC} %s\n" "BIND_USER:"                 "$BIND_USER"
printf "  ${BOLD}%-27s${NC} %s\n" "BIND_USER_PASSWORD:"        "${YELLOW}*** (hidden)${NC}"
printf "  ${BOLD}%-27s${NC} %s\n" "BIND_ANONYM:"               "$BIND_ANONYM"
printf "  ${BOLD}%-27s${NC} %s\n" "AMBARI_ADMIN_USER:"         "$AMBARI_ADMIN_USER"
printf "  ${BOLD}%-27s${NC} %s\n" "AMBARI_ADMIN_PASSWORD:"     "${YELLOW}*** (hidden)${NC}"
printf "  ${BOLD}%-27s${NC} %s\n" "userObjectClass:"           "$userObjectClass"
printf "  ${BOLD}%-27s${NC} %s\n" "usernameAttribute:"         "$usernameAttribute"
printf "  ${BOLD}%-27s${NC} %s\n" "groupObjectClass:"          "$groupObjectClass"
printf "  ${BOLD}%-27s${NC} %s\n" "groupNamingAttr:"           "$groupNamingAttr"
printf "  ${BOLD}%-27s${NC} %s\n" "groupMembershipAttr:"       "$groupMembershipAttr"
printf "  ${BOLD}%-27s${NC} %s\n" "userGroupMemberAttr:"       "$userGroupMemberAttr"
printf "  ${BOLD}%-27s${NC} %s\n" "dnAttribute:"               "$dnAttribute"
printf "  ${BOLD}%-27s${NC} %s\n" "SYNC_COLLISIONS:"           "$SYNC_COLLISIONS"
printf "  ${BOLD}%-27s${NC} %s\n" "FORCE_LOWERCASE_USERNAMES:" "$FORCE_LOWERCASE_USERNAMES"
printf "  ${BOLD}%-27s${NC} %s\n" "PAGINATION_ENABLED:"        "$PAGINATION_ENABLED"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_ENABLED_AMBARI:"       "$LDAP_ENABLED_AMBARI"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_MANAGE_SERVICES:"      "$LDAP_MANAGE_SERVICES"
printf "  ${BOLD}%-27s${NC} %s\n" "LDAP_ENABLED_SERVICES:"     "$LDAP_ENABLED_SERVICES"
printf "  ${BOLD}%-27s${NC} %s\n" "TRUSTSTORE_TYPE:"           "$TRUSTSTORE_TYPE"
printf "  ${BOLD}%-27s${NC} %s\n" "truststore:"                "$truststore"
echo

if ! prompt_yes_no "Do the variables look correct for LDAP configuration?"; then
    log_err "User aborted — exiting."
    exit 1
fi

# ----------------------------------------------------------------------
# Configure Ambari LDAP
# ----------------------------------------------------------------------
log_section "Running ambari-server setup-ldap"
log_info "Log file: $LDAP_SETUP_LOG"

# Build argv as an array so it's easy to echo/trace and hand to the command
setup_ldap_args=(
    # --- Connection ---
    --ldap-url="$LDAP_HOSTNAME:$LDAP_PORT"
    --ldap-type="$LDAP_TYPE"
    --ldap-ssl="$LDAP_SSL"

    # --- Schema / attributes ---
    --ldap-user-class="$userObjectClass"
    --ldap-user-attr="$usernameAttribute"
    --ldap-group-class="$groupObjectClass"
    --ldap-group-attr="$groupNamingAttr"
    --ldap-member-attr="$groupMembershipAttr"
    --ldap-user-group-member-attr="$userGroupMemberAttr"
    --ldap-dn="$dnAttribute"
    --ldap-base-dn="$BASE_DN"
    --ldap-referral="$REFERRAL"

    # --- Bind ---
    --ldap-bind-anonym="$BIND_ANONYM"
    --ldap-manager-dn="$BIND_USER"
    --ldap-manager-password="$BIND_USER_PASSWORD"

    # --- Behavior ---
    --ldap-save-settings
    --ldap-force-setup
    --ldap-force-lowercase-usernames="$FORCE_LOWERCASE_USERNAMES"
    --ldap-pagination-enabled="$PAGINATION_ENABLED"
    --ldap-sync-username-collisions-behavior="$SYNC_COLLISIONS"
    --ldap-sync-disable-endpoint-identification=true

    # --- Actually enable LDAP auth + propagate to services ---
    --ldap-enabled-ambari="$LDAP_ENABLED_AMBARI"
    --ldap-manage-services="$LDAP_MANAGE_SERVICES"
    --ldap-enabled-services="$LDAP_ENABLED_SERVICES"

    # --- Ambari admin (REST API) ---
    --ambari-admin-username="$AMBARI_ADMIN_USER"
    --ambari-admin-password="$AMBARI_ADMIN_PASSWORD"

    # --- Truststore (reconfigure so reruns work) ---
    --truststore-type="$TRUSTSTORE_TYPE"
    --truststore-path="$truststore"
    --truststore-password="$truststorepassword"
    --truststore-reconfigure
)

# Print a redacted copy of the command for debugging
log_info "Invocation (secrets redacted):"
for a in "${setup_ldap_args[@]}"; do
    case "$a" in
        --ldap-manager-password=*|--ambari-admin-password=*|--truststore-password=*)
            printf "    %s=***\n" "${a%%=*}" ;;
        *) printf "    %s\n" "$a" ;;
    esac
done
echo

# Enable shell tracing when DEBUG=1 so the exact command line is visible
if [ "$DEBUG" = "1" ]; then
    log_warn "DEBUG=1 — enabling 'set -x' trace for setup-ldap"
    set -x
fi

# Tee output to log file for post-mortem while keeping the exit status of setup-ldap
set +e
ambari-server setup-ldap --verbose "${setup_ldap_args[@]}" 2>&1 | tee "$LDAP_SETUP_LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$DEBUG" = "1" ]; then
    set +x
fi

if [ "$rc" -ne 0 ]; then
    log_err "ambari-server setup-ldap failed (exit $rc). See $LDAP_SETUP_LOG"
    log_info "Re-run with: DEBUG=1 bash $0"
    exit "$rc"
fi

log_section "✓ LDAP Configuration Complete"
log_ok "Ambari Server LDAP/AD authentication setup finished successfully."
log_info ""
log_info "Next steps:"
log_info "  1) Restart Ambari Server for changes to take effect:"
log_info "     $ ambari-server restart"
log_info ""
log_info "  2) Sync users and groups from LDAP into Ambari:"
log_info "     $ ambari-server sync-ldap --all"
log_info "     (or --existing for existing Ambari users, --users/--groups for specific sets)"
log_info ""
log_info "  3) Test LDAP login in the Ambari UI:"
log_info "     - Navigate to Ambari Web UI"
log_info "     - Sign out if logged in as 'admin'"
log_info "     - Log in with an LDAP user account (e.g., firstname.lastname@corp.example.com)"
log_info ""
log_warn "Important: This script configures Ambari Server LDAP only."
log_warn "Service-specific LDAP (Ranger, Hue, Knox, etc.) is NOT configured by this script."
log_warn "Each service manages its own LDAP configuration separately:"
log_warn "  - Ranger: configure via Ambari UI -> Ranger -> Configs -> 'Advanced ranger-admin-site'"
log_warn "  - Other services: check their documentation for LDAP setup"



# ----------------------------------------------------------------------
# Scope — what this script does vs. does NOT do
# ----------------------------------------------------------------------
# DOES:
#   * Configures LDAP/AD authentication for the Ambari UI + REST API.
#   * Saves central LDAP settings (ambari.ldap.*) to the Ambari DB.
#   * With --ldap-manage-services + --ldap-enabled-services=*, marks all
#     services as "LDAP-desired" so Ambari can push the central config to
#     any service whose stack declares ldap_integration_supported=true
#     (see Apache JIRA AMBARI-24927 / PR #2644 — this is just metadata
#     exposed via REST; it does NOT wire arbitrary services to LDAP).
#
# DOES NOT:
#   * Configure Ranger Admin UI login. Ranger has its own auth stack
#     (ranger.authentication.method, ranger.ldap.*) that is NOT wired to
#     Ambari's central LDAP. Configure Ranger LDAP separately via
#     Ambari UI -> Ranger -> Configs -> "Advanced ranger-admin-site".
#   * Configure Knox, Hue, or other service-level LDAP — each has its
#     own config keys in their respective service config types.
#   * Sync users/groups. Run `ambari-server sync-ldap` after this script
#     + a server restart.
# ----------------------------------------------------------------------
