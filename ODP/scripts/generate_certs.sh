#!/bin/bash
set -euo pipefail
#------------------------------------------------------------------------------
# SSL Certificate Automation Script
#
# Version: 1.2.0
#
# This script provides the following options:
#   1) Generate Self-Signed Certificate For Ambari Cluster 
#      (Includes SAN entries for all hosts plus extra domain entries)
#   2) Generate Certificate using Internal CA for Ambari Cluster 
#      (Includes SAN entries for all hosts plus extra domain entries)
#   3) Generate CSR for Certificate using OpenSSL 
#      (Customize DName and key password; includes SAN, key usage, extended key usage)
#   4) Distribute certificate files to remote cluster nodes
#
# Requirements: keytool, openssl, curl (and optionally sshpass)
#------------------------------------------------------------------------------

###############################################
# Global Configuration
###############################################
BASE_DIR="/opt/security/pki"
DEFAULT_STOREPASS="Welcome"
VALIDITY_DAYS=365
DNAME_BASE="OU=IT,O=MyOrg,L=City,ST=State,C=US"

# Ambari connection details (customize if needed)
AMBARISERVER=$(hostname -f)
AMBARI_USER="admin"
AMBARI_PASSWORD="admin"
AMBARI_PORT=8080
AMBARI_PROTOCOL="http"

# Domain settings (used in SAN entries)
DOMAIN_NAME=$(hostname -d)         # e.g. dc.adsre.com
WILDCARD_DOMAIN="*.${DOMAIN_NAME}"   # e.g. *.dc.adsre.com

###############################################
# Terminal Colors & Formatting
###############################################
BOLD=$(tput bold)
RESET=$(tput sgr0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
BLUE=$(tput setaf 4)
CYAN=$(tput setaf 6)

###############################################
# Logging Functions (No Timestamps)
###############################################
log_info()    { echo -e "${BOLD}${BLUE}[INFO]${RESET} $1"; }
log_success() { echo -e "${BOLD}${GREEN}[SUCCESS]${RESET} $1"; }
log_warn()    { echo -e "${BOLD}${YELLOW}[WARN]${RESET} $1"; }
log_error()   { echo -e "${BOLD}${RED}[ERROR]${RESET} $1"; }

###############################################
# Banner Function
###############################################
print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "┌─────────────────────────────────────────────────────────────┐"
    printf "│ %-61s │\n" "SSL Certificate Automation Script"
    printf "│ %-61s │\n" "Version: 1.2.0"
    echo "└─────────────────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

###############################################
# Dependency Check
###############################################
check_dependencies() {
    log_info "Checking dependencies..."
    local cmds=(curl keytool openssl)
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Command '$cmd' is required but not installed. Aborting."
            exit 1
        fi
    done
    log_success "All required dependencies are installed."
}

###############################################
# Usage Function
###############################################
usage() {
    echo -e "${BOLD}Usage:${RESET} $0 [--help]"
    echo "Options:"
    echo "  --help       Display this help message"
    exit 0
}

if [[ "${1:-}" == "--help" ]]; then
    usage
fi

###############################################
# Function: Retrieve Ambari SAN Entries
#   - Retrieves the cluster name and hostnames from Ambari.
#   - Builds a comma-separated string of SAN entries from the hosts.
#   - Appends extra domain entries (DOMAIN_NAME & WILDCARD_DOMAIN).
###############################################
get_ambari_san_entries() {
    log_info "Retrieving Ambari cluster information for SAN entries..."
    CLUSTER=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -i -H 'X-Requested-By: ambari' \
        "$AMBARI_PROTOCOL://$AMBARISERVER:$AMBARI_PORT/api/v1/clusters" | \
        sed -n 's/.*"cluster_name" *: *"\([^"]*\)".*/\1/p')
    if [ -z "$CLUSTER" ]; then
        log_error "Failed to retrieve cluster name from Ambari. Exiting."
        exit 1
    fi
    log_success "Cluster name: ${CLUSTER}"

    log_info "Fetching host names from Ambari..."
    HOST_NAMES=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" \
        "$AMBARI_PROTOCOL://$AMBARISERVER:$AMBARI_PORT/api/v1/clusters/$CLUSTER/hosts" | \
        grep -o '"host_name" *: *"[^"]*' | awk -F'"' '{print $4}')
    if [ -z "$HOST_NAMES" ]; then
        log_error "No hosts found in cluster ${CLUSTER}. Exiting."
        exit 1
    fi

    log_info "Found hosts:"
    for h in $HOST_NAMES; do
        echo "  - ${GREEN}$h${RESET}"
    done

    ALL_SAN=""
    for h in $HOST_NAMES; do
        ALL_SAN="${ALL_SAN}dns:${h},"
    done
    # Append extra domain entries
    if [ -n "$DOMAIN_NAME" ]; then
        log_info "Additional domain: ${CYAN}${DOMAIN_NAME}${RESET}"
        log_info "Wildcard domain: ${CYAN}${WILDCARD_DOMAIN}${RESET}"
        ALL_SAN="${ALL_SAN}dns:${DOMAIN_NAME},dns:${WILDCARD_DOMAIN}"
    else
        ALL_SAN=${ALL_SAN%,}  # Remove trailing comma if no extra domains
    fi

    log_info "Computed SAN entries: ${CYAN}${ALL_SAN}${RESET}"
}

###############################################
# Function: Verify Remote Host Connectivity
#   - Checks if a remote host is reachable via SSH.
###############################################
verify_remote_host() {
    local host="$1"
    local user="$2"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$user@$host" "echo ok" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

###############################################
# Function: Select Certificate Directory for Distribution
#   - Asks the user which certificate set (directory) to distribute.
###############################################
select_cert_directory() {
    cat <<EOF 1>&2
Select the certificate set to distribute:
  1) Self-Signed Certificate For Ambari Cluster -> ${BASE_DIR}/selfsigned
  2) Certificate using Internal CA for Ambari Cluster -> ${BASE_DIR}/internal_ca
EOF
    read -r -p "Enter option number [1-2]: " choice
    case "$choice" in
         1) echo "${BASE_DIR}/selfsigned" ;;
         2) echo "${BASE_DIR}/internal_ca" ;;
         *) log_error "Invalid choice"; exit 1 ;;
    esac
}

###############################################
# Function: Distribute Certificate Files to Remote Nodes
#   - Retrieves the node list via Ambari.
#   - Creates the remote directory if it does not exist.
#   - Supports both passwordless and password-based SSH.
#   - Prints a summary of successes and failures.
###############################################
distribute_certificate() {
    local cert_dir="$1"

    # Retrieve Ambari node list if not already set
    if [ -z "${HOST_NAMES:-}" ]; then
        get_ambari_san_entries
    fi

    log_info "Distributing certificate files from '${cert_dir}' to the following nodes:"
    for host in $HOST_NAMES; do
        echo "  - ${GREEN}$host${RESET}"
    done

    read -p "Enter SSH username for distribution (default: root): " ssh_user
    ssh_user=${ssh_user:-root}

    read -p "Is SSH access for user '$ssh_user' passwordless? (y/n): " passless
    if [[ "$passless" =~ ^[Yy]$ ]]; then
        ssh_pass=""
    else
        read -s -p "Enter SSH password for $ssh_user: " ssh_pass
        echo ""
    fi

    read -p "Enter remote directory to copy certificate files (default: same as local directory): " remote_dir
    remote_dir=${remote_dir:-$cert_dir}

    declare -a success_hosts
    declare -a failed_hosts

    for host in $HOST_NAMES; do
        log_info "Processing host: $host"
        if ! verify_remote_host "$host" "$ssh_user"; then
            log_warn "Cannot connect to $host. Skipping..."
            failed_hosts+=("$host")
            continue
        fi

        # Create the remote directory on the host
        if [ -z "$ssh_pass" ]; then
            ssh -o StrictHostKeyChecking=no "$ssh_user@$host" "mkdir -p '$remote_dir'" || \
                log_warn "Failed to create directory on $host"
            if scp -o StrictHostKeyChecking=no -r "$cert_dir"/* "$ssh_user@$host:$remote_dir/"; then
                success_hosts+=("$host")
            else
                failed_hosts+=("$host")
            fi
        else
            if ! command -v sshpass &>/dev/null; then
                log_error "sshpass is not installed. Cannot distribute with password. Skipping host $host."
                failed_hosts+=("$host")
                continue
            fi
            sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no "$ssh_user@$host" "mkdir -p '$remote_dir'" || \
                log_warn "Failed to create directory on $host"
            if sshpass -p "$ssh_pass" scp -o StrictHostKeyChecking=no -r "$cert_dir"/* "$ssh_user@$host:$remote_dir/"; then
                success_hosts+=("$host")
            else
                failed_hosts+=("$host")
            fi
        fi
        log_success "Files copied to $host"
    done

    log_info "Distribution Summary:"
    if [ ${#success_hosts[@]} -gt 0 ]; then
        echo -e "  ${GREEN}Success on:${RESET} ${success_hosts[*]}"
    fi
    if [ ${#failed_hosts[@]} -gt 0 ]; then
        echo -e "  ${RED}Failed on:${RESET} ${failed_hosts[*]}"
    fi
    log_success "Certificate distribution completed."
}

###############################################
# Function: Ask & Distribute Certificate Files
###############################################
ask_and_distribute() {
    local cert_dir="$1"
    read -p "Would you like to distribute the generated certificate to all cluster nodes? (y/n): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        distribute_certificate "$cert_dir"
    else
        log_info "Certificate distribution skipped."
    fi
}

###############################################
# Option 1: Generate Self-Signed Certificate For Ambari Cluster
#   - Includes SAN entries for all hosts plus extra domain entries.
###############################################
generate_self_signed_cert() {
    log_info "Generating Self-Signed Certificate for Ambari Cluster..."
    mkdir -p "$BASE_DIR/selfsigned"
    cd "$BASE_DIR/selfsigned" || { log_error "Failed to change directory to $BASE_DIR/selfsigned"; exit 1; }

    get_ambari_san_entries

    LOCAL_HOST=$(hostname -f)
    keytool -genkeypair \
        -alias "$LOCAL_HOST" \
        -keyalg RSA \
        -keysize 2048 \
        -dname "CN=${LOCAL_HOST},${DNAME_BASE}" \
        -validity "$VALIDITY_DAYS" \
        -ext "SAN=${ALL_SAN}" \
        -ext "KU=digitalSignature,keyEncipherment" \
        -ext "EKU=serverAuth,clientAuth" \
        -keystore keystore.jks \
        -storepass "$DEFAULT_STOREPASS" \
        -keypass "$DEFAULT_STOREPASS" \
        -noprompt

    keytool -exportcert \
        -alias "$LOCAL_HOST" \
        -keystore keystore.jks \
        -file "${LOCAL_HOST}.crt" \
        -storepass "$DEFAULT_STOREPASS" \
        -rfc

    keytool -import -file "${LOCAL_HOST}.crt" \
        -alias "${LOCAL_HOST}-trust" \
        -keystore truststore.jks \
        -storepass "$DEFAULT_STOREPASS" \
        -noprompt

    log_success "Self-Signed Certificate generated in ${BASE_DIR}/selfsigned."
    ask_and_distribute "$(pwd)"
}

###############################################
# Option 2: Generate Certificate using Internal CA for Ambari Cluster
#   - Includes SAN entries for all hosts plus extra domain entries.
###############################################
generate_cert_with_internal_ca() {
    log_info "Generating Certificate using Internal CA for Ambari Cluster..."
    mkdir -p "$BASE_DIR/internal_ca"
    cd "$BASE_DIR/internal_ca" || { log_error "Failed to change directory to $BASE_DIR/internal_ca"; exit 1; }

    get_ambari_san_entries

    LOCAL_HOST=$(hostname -f)
    if [ ! -f ca.key ]; then
        log_info "Generating internal CA key and certificate..."
        openssl req -new -x509 -nodes -days "$VALIDITY_DAYS" \
            -subj "/C=US/ST=State/L=City/O=MyOrg/OU=CA/CN=InternalCA" \
            -keyout ca.key -out ca.crt
        log_success "Internal CA created."
    else
        log_info "Internal CA already exists. Skipping CA generation."
    fi

    keytool -genkeypair \
        -alias "$LOCAL_HOST" \
        -keyalg RSA \
        -keysize 2048 \
        -dname "CN=${LOCAL_HOST},${DNAME_BASE}" \
        -validity "$VALIDITY_DAYS" \
        -ext "SAN=${ALL_SAN}" \
        -ext "KU=digitalSignature,keyEncipherment" \
        -ext "EKU=serverAuth,clientAuth" \
        -keystore keystore.jks \
        -storepass "$DEFAULT_STOREPASS" \
        -keypass "$DEFAULT_STOREPASS" \
        -noprompt

    keytool -certreq \
        -alias "$LOCAL_HOST" \
        -keystore keystore.jks \
        -storepass "$DEFAULT_STOREPASS" \
        -file "${LOCAL_HOST}.csr" \
        -noprompt

    cat > cert_ext.cnf <<EOF
subjectAltName=${ALL_SAN}
KU=digitalSignature,keyEncipherment
EKU=serverAuth,clientAuth
EOF

    openssl x509 -req -in "${LOCAL_HOST}.csr" \
        -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out "${LOCAL_HOST}.signed.crt" -days "$VALIDITY_DAYS" -extfile cert_ext.cnf
    log_success "Certificate signed by Internal CA."

    cat "${LOCAL_HOST}.signed.crt" ca.crt > chain.crt

    keytool -import -alias internalCA -file ca.crt -keystore keystore.jks \
        -storepass "$DEFAULT_STOREPASS" -noprompt
    keytool -import -alias "$LOCAL_HOST" -file chain.crt -keystore keystore.jks \
        -storepass "$DEFAULT_STOREPASS" -noprompt

    keytool -import -file ca.crt \
        -alias internalCA-trust -keystore truststore.jks \
        -storepass "$DEFAULT_STOREPASS" -noprompt

    log_success "Certificate (signed by Internal CA) generated in ${BASE_DIR}/internal_ca."
    ask_and_distribute "$(pwd)"
}

###############################################
# Option 3: Generate CSR for Certificate using OpenSSL
#   - Prompts for a custom Distinguished Name and key password.
#   - Uses OpenSSL commands to generate a private key and CSR.
#   - Includes SAN entries (converted to OpenSSL format), key usage, and extended key usage.
###############################################
generate_csr_with_options() {
    log_info "Generating CSR for Certificate using OpenSSL..."
    mkdir -p "$BASE_DIR/csr"
    cd "$BASE_DIR/csr" || { log_error "Failed to change directory to $BASE_DIR/csr"; exit 1; }

    get_ambari_san_entries

    # Prompt for custom subject and key password
    DEFAULT_SUBJ="/C=US/ST=State/L=City/O=MyOrg/OU=IT/CN=$(hostname -f)"
    read -p "Enter Distinguished Name (subject) [default: ${DEFAULT_SUBJ}]: " custom_subj
    custom_subj=${custom_subj:-$DEFAULT_SUBJ}

    read -p "Enter key password (for private key) [default: ${DEFAULT_STOREPASS}]: " custom_keypass
    custom_keypass=${custom_keypass:-$DEFAULT_STOREPASS}

    # Convert ALL_SAN to OpenSSL format: replace all "dns:" with "DNS:" (case sensitive)
    ALL_SAN_OPENSSL="${ALL_SAN//dns:/DNS:}"

    # Create a temporary OpenSSL configuration file for CSR generation
    cat > csr_openssl.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
# Using -subj command line parameter

[ req_ext ]
subjectAltName = ${ALL_SAN_OPENSSL}
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EOF

    # Generate an encrypted private key using the provided password
    openssl genrsa -aes256 -passout pass:"$custom_keypass" -out key.pem 2048

    # Generate CSR using the private key and custom subject
    openssl req -new -key key.pem -passin pass:"$custom_keypass" -out csr.pem -subj "$custom_subj" -config csr_openssl.cnf

    log_success "CSR generated as csr.pem and private key as key.pem in ${BASE_DIR}/csr."
    echo "Review csr.pem and send it to your CA for signing."
}

###############################################
# Option 4: Distribute Certificate Files to Remote Nodes (Standalone)
###############################################
distribute_certificate_option() {
    log_info "Distributing certificate files to remote nodes..."
    cert_dir=$(select_cert_directory)
    distribute_certificate "$cert_dir"
}

###############################################
# Main Menu
###############################################
print_banner
check_dependencies

echo -e "${BOLD}Select an option:${RESET}"
echo "  1) Generate Self-Signed Certificate For Ambari Cluster"
echo "     (Includes SAN entries for all hosts plus domain entries: ${DOMAIN_NAME} & ${WILDCARD_DOMAIN})"
echo "  2) Generate Certificate using Internal CA for Ambari Cluster"
echo "     (Includes SAN entries for all hosts plus domain entries: ${DOMAIN_NAME} & ${WILDCARD_DOMAIN})"
echo "  3) Generate CSR for Certificate using OpenSSL"
echo "     (Customize DName and key password; includes SAN, key usage, extended key usage)"
echo "  4) Distribute certificate files to remote cluster nodes"
echo -e "  ${BOLD}--help${RESET}     Display help message"
echo "└─────────────────────────────────────────────────────────────"

read -p "Enter option number [1-4]: " option

case "$option" in
  1)
    generate_self_signed_cert
    ;;
  2)
    generate_cert_with_internal_ca
    ;;
  3)
    generate_csr_with_options
    ;;
  4)
    distribute_certificate_option
    ;;
  *)
    log_error "Invalid option. Exiting."
    exit 1
    ;;
esac

exit 0
