#!/bin/bash
# Acceldata Inc.
# Set environment variables
export keystore=/etc/security/certificates/keystore.jks
export password=PASSWORD
export knox_master_secret_password=PASSWORD
# Cmd to get the alias name "keytool -list -keystore "/etc/security/certificates/keystore.jks" -storepass "$password""
export alias_name=<alias name from keystore.jks to be used>

knox_user_group=$(stat -c %U:%G /etc/knox/conf/gateway-site.xml)
IFS=':' read -ra knox_user_group_arr <<< "$knox_user_group"
knox_user="${knox_user_group_arr[0]}"
knox_group="${knox_user_group_arr[1]}"
export knox_user
export knox_group
export knox_dir=/usr/odp/current/knox-server
export knox_keytool="$knox_dir/bin/knoxcli.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

# Function to log errors and exit
log_error() {
    echo "Error: $1" >&2
    exit 1
}

# Function to prompt yes/no and proceed
prompt_yes_no() {
    while true; do
        read -r -p "$1 (yes/no): " choice
        case "$choice" in
            [Yy]es ) return 0;;
            [Nn]o ) return 1;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Function to update Knox with the new certificate
update_knox_certificate() {
    # Check if the Common Name (CN) in the issuer and subject are the same
    if [ "$issuer_cn" == "$subject_cn" ]; then
        echo -e "The ${GREEN}KNOX certificate${NC} is ${GREEN}self-signed${NC} as the subject and issuer are the same."
        echo -e "Replacing Knox Self-Signed Certificate with the Provided Certificate......"
        echo ""
        echo -e "🔑 Please ensure that you have set all variables correctly."
        echo -e "🔐 ${GREEN}keystore:${NC} $keystore"
        echo -e "🔐 ${GREEN}password:${NC} ${YELLOW}********${NC}"  # Replace with actual keystore password
        echo -e "🔐 ${GREEN}alias_name:${NC} $alias_name"  # Replace with keystore alias name to be used as PrivateKeyEntry
        echo -e "🔐 ${GREEN}knox_master_secret_password:${NC} ${YELLOW}********${NC}"  # Replace with knox_master_secret_password used during Knox installation.
        echo -e "Do the variables look correct for Knox SSL setup and prceeed?"
        if prompt_yes_no ; then
            # Take a backup with the date
            date=$(date +"%Y%m%d")
            backup_dir="/var/lib/knox/data/security/keystores/backup$date"
            mkdir -p "$backup_dir"
            mv "/var/lib/knox/data/security/keystores/__gateway-credentials.jceks" "$backup_dir/gateway.jks"

            # Copy the new keystore to the specified location
            cp "$keystore" "/var/lib/knox/data/security/keystores/keystore.jks"

            # Check if the variable alias_name is not set or Get the alias name from keystore.jks
           if [ -z "$alias_name" ]; then
           alias_name=$(keytool -list -v -keystore "/var/lib/knox/data/security/keystores/keystore.jks" -storepass "$password" | grep "Alias name:" | awk -F' ' '{print $3}' | egrep -v "intca|interca|rootca" | grep $HOSTNAME)
           fi

            # Change the alias name to "gateway-identity"
            keytool -changealias -keystore "/var/lib/knox/data/security/keystores/keystore.jks" -storepass "$password" -alias "$alias_name" -destalias "gateway-identity"

            echo -e "Do you Want to Reset the Knox Master Secret Password?"

            # Check if $password and $knox_master_secret_password are the same
            if prompt_yes_no; then
                # The user answered "yes," so reset the Knox Master Secret Password
                rm -rf "$knox_dir/data/security/master"

                # Switch to the user and execute the knoxcli commands
                sudo -u "$knox_user" "$knox_keytool" create-master --force --master "$password"

                # Ensure ownership and group ownership are the same as "/etc/knox/conf/gateway-site.xml" file
                chown "$knox_user:$knox_group" "$knox_dir/data/security/master"
            else
                echo "Exiting..."
                return 1  # Exit the function with a non-zero status
            fi

            # Create the alias and rename the keystore
            "$knox_keytool" create-alias gateway-identity-passphrase --value "$password"
            mv "/var/lib/knox/data/security/keystores/keystore.jks" "/var/lib/knox/data/security/keystores/gateway.jks"

            # Ensure ownership and group ownership are set correctly for the files
            chown "$knox_user:$knox_group" "/var/lib/knox/data/security/keystores/gateway.jks"
            chown "$knox_user:$knox_group" "/var/lib/knox/data/security/keystores/__gateway-credentials.jceks"

            echo -e "${GREEN}Replacing Knox Self-Signed Certificate with CA Certificate is successful.${NC}"

            echo -e "Knox Backup files stored under ${YELLOW}$backup_dir${NC}"
            echo -e "Please restart the Knox Service from Ambari UI to apply the changes."
        else
            echo "Exiting..."
            exit 1
        fi
    else
        log_error "The certificate is not self-signed or the subject and issuer are different."
    fi
}

# Run the openssl command to extract the certificate and save it to a temporary file
echo -n | openssl s_client -connect localhost:8443 2>/dev/null | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/knoxcert.crt

# Extract the Common Name (CN) from the issuer and subject fields using openssl x509
issuer_cn=$(openssl x509 -in /tmp/knoxcert.crt -noout -issuer | sed -n 's/.*CN=\([^/]\+\).*/\1/p')
subject_cn=$(openssl x509 -in /tmp/knoxcert.crt -noout -subject | sed -n 's/.*CN=\([^/]\+\).*/\1/p')

# Call the update_knox_certificate function
update_knox_certificate
