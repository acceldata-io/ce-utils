#!/bin/bash
# Acceldata Inc.

# Define colors for better output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print success message
print_success() {
  echo -e "${GREEN}Success: $1${NC}"
}

# Function to print warning message
print_warning() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

# Function to print error message and exit
print_error() {
  echo -e "${RED}Error: $1${NC}"
  exit 1
}

# Function to check command existence
check_command_existence() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || print_error "$cmd not found. Please install it."
}

# Check for required commands
required_commands=("openssl" "awk" "sed" "ex" "docker" "accelo")
for cmd in "${required_commands[@]}"; do
  check_command_existence "$cmd"
done

# Source the environment file
if [ -f "/etc/profile.d/ad.sh" ]; then
  source /etc/profile.d/ad.sh || print_error "Failed to source environment file."
else
  print_error "Environment file /etc/profile.d/ad.sh not found."
fi

# Prompt for certificate files with better wording and color
read -p $'\e[36mEnter the path to the server certificate file (cert.crt): \e[0m' cert_crt
read -p $'\e[36mEnter the path to the private key file (cert.key): \e[0m' cert_key


# Function to copy a file to the specified destination
copy_to_destination() {
  local source_file="$1"
  local destination="$2"

  cp -f "$source_file" "$destination" && print_success "File $source_file copied to $destination" || print_error "Failed to copy $source_file to $destination"
}

# Ensure the certificate files have the correct filenames
validate_certificate_file() {
  local file_path="$1"
  [ -f "$file_path" ] && copy_to_destination "$file_path" "$AcceloHome/config/proxy/certs/$(basename "$file_path")"
}

validate_certificate_file "$cert_crt"
validate_certificate_file "$cert_key"

# Function to securely read passphrase
read_secure_passphrase() {
  local prompt="$1"
  prompt+=": "
  read -rs -p "$prompt" passphrase
  echo  # Print a newline for a cleaner output
}

# Function to remove the password from the private key
remove_private_key_password() {
  read_secure_passphrase "Enter the passphrase to remove encryption from the private key"
  openssl rsa -in "$cert_key" -out "$cert_key" -passin pass:"$passphrase" &>/dev/null && print_success "Password removed from private key" || print_error "Failed to remove password from private key"
}

# Check if the private key is encrypted and remove the password if it is
check_and_remove_encryption() {
  if [ -f "$cert_key" ]; then
    encryption_indicator="-----BEGIN ENCRYPTED PRIVATE KEY-----"
    if [[ $(head -n 1 "$cert_key") == "$encryption_indicator" ]]; then
      print_warning "Private key is encrypted. Removing password..."
      remove_private_key_password
    else
      print_success "Private key is not encrypted."
    fi
  else
    print_error "Private key file not found: $cert_key"
  fi
}

# Check if the private key is encrypted and remove the password if it is
check_and_remove_encryption

# Verify if cert.crt is in plaintext (PEM) format
if openssl x509 -in "$cert_crt" -noout &>/dev/null; then
  print_success "Certificate is in plaintext (PEM) format."
  echo "You can merge server certificate, intermediate, and root CA in a single file."
  echo "Ensure the server certificate is on top and is followed by intermediate and root CA."
else
  print_error "Certificate is not in plaintext (PEM) format."
fi

# Display certificate information (subject and issuer)
echo -e "Certificate Information for $cert_crt:"
openssl x509 -in "$cert_crt" -noout -subject -issuer || print_error "Failed to display certificate information."

# Update permissions on certificate files
chmod 0655 "$cert_crt" "$cert_key" && print_success "Updated permissions on certificate files" || print_error "Failed to update permissions on certificate files."

# Check if ad-core.yml file exists
if [ ! -f "$AcceloHome/config/docker/ad-core.yml" ]; then
  accelo admin makeconfig ad-core || print_error "Failed to create ad-core.yml."
fi

# Edit the ad-core.yml file to remove the ports: field
# Modify the ad-core.yml file to remove the ports field in the ad-graphql section
if [ -f "$AcceloHome/config/docker/ad-core.yml" ]; then
    # Create a backup of the original file
    cp "$AcceloHome/config/docker/ad-core.yml" "$AcceloHome/config/docker/ad-core.yml.bak"

    # Use sed to remove only the 'ports' lines within the ad-graphql container
    sed -i '/^  ad-graphql:/,/^  - 4000:4000$/ {
        /^  - 4000:4000$/d
    }' "$AcceloHome/config/docker/ad-core.yml"

    print_success "Removed port 4000 from ad-graphql section in ad-core.yml"
else
    print_error "ad-core.yml file not found"
fi

# Restart the ad-graphql container
echo "Restarting ad-graphql container"
echo "y" | accelo restart ad-graphql && print_success "Restarted ad-graphql container" || print_error "Failed to restart ad-graphql container."

# Sleep for 10 seconds
echo "Sleeping for 10 seconds..."
sleep 10

# Echo message and perform additional task
print_success "Add proxy(ad-proxy) addons..."
accelo deploy addons || print_error "Failed to deploy proxy addons."

# Sleep for 5 seconds
echo "Sleeping for 5 seconds..."
sleep 5

# Display docker logs for the ad-proxy container and exit on it
print_success "Displaying docker logs for the ad-proxy container:"
docker logs ad-proxy_default || print_error "Failed to display docker logs."

print_success "PULSE TLS setup using ad-proxy execution completed successfully."

echo -e "${GREEN}Access Pulse WebUI https://$HOSTNAME:443${NC}"
