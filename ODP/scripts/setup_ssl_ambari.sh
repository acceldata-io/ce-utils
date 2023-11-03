#!/bin/bash
# Acceldata Inc.


# User-defined variables
AMBARISERVER_URL="https://$(hostname -f):8443"
IMPORT_CERT_PATH="/opt/security/pki/server.pem"
IMPORT_KEY_PATH="/opt/security/pki/server.key"
PEM_PASSWORD="Password"

# Check if the script is being run as root
if [ "$EUID" -ne 0 ]; then
    handle_error "This script must be run as root."
fi

# Check if ambari is already configured for SSL
if grep -q "^api\.ssl=true" /etc/ambari-server/conf/ambari.properties; then
    echo "SSL is already configured for Ambari Server. Exiting..."
    exit 0
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
echo "Please update the following variables before proceeding:"
echo "IMPORT_CERT_PATH: $IMPORT_CERT_PATH"
echo "IMPORT_KEY_PATH: $IMPORT_KEY_PATH"
echo "PEM_PASSWORD: *** (not shown for security)"

if ! prompt_yes_no "Do the variables look correct for Ambari HTTPS setup?"; then
    echo "Exiting..."
    exit 1
fi

# Execute Ambari HTTPS setup command
ambari-server setup-security --security-option=setup-https --api-ssl=true \
    --import-cert-path="$IMPORT_CERT_PATH" --import-key-path="$IMPORT_KEY_PATH" \
    --pem-password="$PEM_PASSWORD" --api-ssl-port=8443

# Display the Ambari URL
echo "Ambari URL: $AMBARISERVER_URL"
