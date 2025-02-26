#!/bin/bash
# Acceldata Inc.
# Script to update Knox SSL certificate and reset Knox master secret password if required.
# Incorporates backup of all keystore files, auto-detection of alias, configuration confirmation,
# and an option (FORCE=true) to bypass all user prompts.

# Set environment variables
export KEYSTORE="/opt/security/pki/keystore.jks"
export KEYSTORE_PASS="privateKeyPass"             # Set the keystore password here
export KNox_MASTER_SECRET_PASS="privateKeyPass"     # Set the Knox master secret password (used during Knox installation). Ensure that this matches the keystore password; otherwise, the script may reset it. It needs to be same.
# Optionally, provide an alias name. If left blank, the script will auto-detect the keystore alias to be used as the PrivateKeyEntry.
export ALIAS_NAME=""

# Set Knox installation and data directories
export KNox_DIR="/usr/odp/current/knox-server"
export DATA_DIR="$KNox_DIR/data/security/keystores"
export KNox_KEYTOOL="$KNox_DIR/bin/knoxcli.sh"



# Retrieve Knox user and group from the gateway configuration file
knox_user_group=$(stat -c %U:%G /etc/knox/conf/gateway-site.xml)
IFS=':' read -ra knox_user_group_arr <<< "$knox_user_group"
export KNox_USER="${knox_user_group_arr[0]}"
export KNox_GROUP="${knox_user_group_arr[1]}"

# Define colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[90m'
NC='\033[0m'  # No Color

# Logging error and exit
log_error() {
    echo -e "${YELLOW}Error:${NC} $1" >&2
    exit 1
}

# Run important commands and display them in gray
run_important_cmd() {
    echo -e "${GRAY}Running: $*${NC}"
    "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        log_error "Important command failed: $*"
    fi
}

# Prompt for yes/no, unless FORCE=true
prompt_yes_no() {
    if [ "$FORCE" == "true" ]; then
        echo -e "${GRAY}FORCE enabled: Skipping prompt '$1'${NC}"
        return 0
    fi
    while true; do
        read -r -p "$1 (yes/no): " choice
        case "$choice" in
            [Yy]es ) return 0;;
            [Nn]o ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Create a timestamped backup of all files in the keystore directory
backup_keystore() {
    local base_backup_dir="$DATA_DIR/backup_$(date +"%Y%m%d")"
    local backup_dir="$base_backup_dir"
    local counter=1

    # Ensure unique backup directory if one already exists.
    while [ -d "$backup_dir" ]; do
        backup_dir="${base_backup_dir}_$counter"
        counter=$((counter + 1))
    done

    mkdir -p "$backup_dir" || log_error "Cannot create backup directory $backup_dir."
    # Move all files from DATA_DIR to the backup directory.
    mv "$DATA_DIR"/* "$backup_dir"/ || log_error "Failed to move files to backup directory."
    echo -e "Backup created at: ${YELLOW}$backup_dir${NC}"
}

# Verify keystore access and auto-detect alias if not provided.
detect_alias() {
    echo -e "Verifying keystore accessibility..."
    if ! keytool -list -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" -alias "$ALIAS_NAME" &>/dev/null; then
        if [ -z "$ALIAS_NAME" ]; then
            if ! keytool -list -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" &>/dev/null; then
                log_error "Unable to open keystore '$KEYSTORE'. Check that the password is correct."
            fi
        else
            log_error "Alias '$ALIAS_NAME' not found or keystore password is incorrect. Please verify the alias and password."
        fi
    fi

    if [ -z "$ALIAS_NAME" ]; then
        echo "No keystore alias specified. Attempting to detect alias from keystore..."
        alias_list=$(keytool -list -v -keystore "$KEYSTORE" -storepass "$KEYSTORE_PASS" 2>/dev/null | \
                     grep -E "Alias name:" | awk '{print $3}' | grep -ivE "intca|interca|rootca")
        # If multiple aliases exist, filter for ones containing the hostname.
        if [ -n "$alias_list" ]; then
            host_aliases=$(echo "$alias_list" | grep -i "$(hostname)" || true)
            if [ -n "$host_aliases" ]; then
                alias_list="$host_aliases"
            fi
        fi
        alias_count=$(echo "$alias_list" | sed '/^$/d' | wc -l)
        if [ "$alias_count" -eq 0 ]; then
            log_error "Could not auto-determine the alias. Please specify ALIAS_NAME manually."
        elif [ "$alias_count" -gt 1 ]; then
            log_error "Multiple alias entries found in keystore ($(echo "$alias_list" | tr '\n' ',' | sed 's/,$//')). Please specify ALIAS_NAME manually."
        fi
        ALIAS_NAME=$(echo "$alias_list" | sed -n '1p')
        echo -e "Detected keystore alias: ${GREEN}$ALIAS_NAME${NC}"
    fi
}

# Confirm configuration with user before proceeding.
confirm_configuration() {
    echo -e "\n Make sure run Script on Knox node: Please review the settings below before continuing:"
    echo -e " - ${GREEN}Keystore file:${NC} $KEYSTORE"
    echo -e " - ${GREEN}Keystore password:${NC} ${YELLOW}********${NC}"
    echo -e " - ${GREEN}Certificate alias:${NC} $ALIAS_NAME"
    echo -e " - ${GREEN}Knox master secret (current):${NC} ${YELLOW}********${NC}"
    if ! prompt_yes_no "Are these details correct? Do you want to continue?"; then
        log_error "User canceled the certificate replacement."
    fi
}

# Update Knox certificate and optionally reset Knox master secret password.
update_knox_certificate() {
    detect_alias

    # Confirm configuration details with the user.
    confirm_configuration

    # Check certificate self-sign status. If FORCE is true, skip the check.
    if [ "$issuer_cn" == "$subject_cn" ] || [ "$FORCE" == "true" ]; then
        echo -e "${GREEN}Proceeding with certificate replacement...${NC}"
    else
        log_error "Certificate validation failed: The certificate is not self-signed (issuer and subject CNs differ). Use FORCE=true to override."
    fi

    echo -e "${GREEN}Replacing Knox Self-Signed Certificate with the Provided CA Certificate...${NC}"
    backup_keystore

    # Copy the new keystore into place.
    cp "$KEYSTORE" "$DATA_DIR/keystore.jks" || log_error "Failed to copy new keystore."

    # Important command: Change the alias to "gateway-identity"
    run_important_cmd keytool -changealias -keystore "$DATA_DIR/keystore.jks" \
        -storepass "$KEYSTORE_PASS" -alias "$ALIAS_NAME" -destalias "gateway-identity"

    # Always prompt whether to reset the Knox master secret password, even if passwords match.
    if prompt_yes_no "Would you like to reset the Knox master secret password using the keystore password? Both needs to be same. (If unsure, it's recommended)"; then
        rm -rf "$KNox_DIR/data/security/master" || log_error "Failed to remove Knox master directory."
        run_important_cmd sudo -u "$KNox_USER" "$KNox_KEYTOOL" create-master --force --master "$KEYSTORE_PASS"
        chown "$KNox_USER:$KNox_GROUP" "$KNox_DIR/data/security/master" || \
            log_error "Failed to set ownership for Knox master directory."
        echo -e "${GREEN}Knox master secret password has been reset successfully.${NC}"
    else
        echo -e "${GREEN}Skipping reset of Knox master secret password.${NC}"
    fi

    # Important command: Create the alias using Knox keytool.
    run_important_cmd "$KNox_KEYTOOL" create-alias gateway-identity --value "$KEYSTORE_PASS"

    # Rename the keystore to gateway.jks.
    mv "$DATA_DIR/keystore.jks" "$DATA_DIR/gateway.jks" || log_error "Failed to rename keystore."

    # Ensure correct ownership of the new keystore and credentials files.
    chown "$KNox_USER:$KNox_GROUP" "$DATA_DIR/gateway.jks" || log_error "Failed to set ownership for gateway.jks."
    chown "$KNox_USER:$KNox_GROUP" "$DATA_DIR/__gateway-credentials.jceks" 2>/dev/null

    echo -e "${GREEN}Knox certificate replacement was successful.${NC}"
    echo -e "Please restart the Knox Service (e.g., via Ambari UI) to apply the changes."
}

# Run the openssl command to extract the certificate and save it to a temporary file
echo -n | openssl s_client -connect localhost:8443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/knoxcert.crt

# Extract the Common Name (CN) from the issuer and subject fields using openssl x509
issuer_cn=$(openssl x509 -in /tmp/knoxcert.crt -noout -issuer | sed -n 's/.*CN=\([^/]\+\).*/\1/p')
subject_cn=$(openssl x509 -in /tmp/knoxcert.crt -noout -subject | sed -n 's/.*CN=\([^/]\+\).*/\1/p')

# Call the update_knox_certificate function
update_knox_certificate
