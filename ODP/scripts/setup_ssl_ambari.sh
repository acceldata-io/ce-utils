#!/bin/bash
# Acceldata Inc.

set -euo pipefail

IMPORT_CERT_PATH="/opt/security/pki/server.pem"
IMPORT_KEY_PATH="/opt/security/pki/server.key"
PEM_PASSWORD="Password"

handle_error() {
  echo "ERROR: $*" >&2
  exit 1
}

prompt_yes_no() {
  local prompt="$1"
  while true; do
    read -r -p "$prompt (yes/no): " choice
    case "$choice" in
      [Yy]es|[Yy]) return 0 ;;
      [Nn]o|[Nn])  return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

timestamp() {
  date +"%Y%m%d-%H%M%S"
}

detect_cert_format() {
  # Returns one of: PEM, DER, UNKNOWN
  local cert="$1"

  # Try PEM first
  if openssl x509 -in "$cert" -noout -text >/dev/null 2>&1; then
    echo "PEM"
    return
  fi

  # Try DER next
  if openssl x509 -inform DER -in "$cert" -noout -text >/dev/null 2>&1; then
    echo "DER"
    return
  fi

  echo "UNKNOWN"
}

convert_der_to_pem_inplace() {
  # Converts DER cert to PEM at the same path, taking a backup and preserving owner/perms
  local cert="$1"

  local bak="${cert}.bak.$(timestamp)"
  local tmp="${cert}.tmp.$(timestamp)"

  # Capture ownership/perms to restore later
  local owner grp mode
  owner=$(stat -c "%u" "$cert")
  grp=$(stat -c "%g" "$cert")
  mode=$(stat -c "%a" "$cert")

  echo "Taking backup of current certificate: $bak"
  cp -p "$cert" "$bak"

  # Convert
  echo "Converting DER -> PEM at: $cert"
  # exact command (also printed for user visibility):
  echo "Exact command: openssl x509 -inform DER -in \"$cert\" -out \"$tmp\""
  openssl x509 -inform DER -in "$cert" -out "$tmp"

  # Replace original with PEM, restore perms
  mv -f "$tmp" "$cert"
  chown "$owner:$grp" "$cert"
  chmod "$mode" "$cert"

  echo "Conversion complete. Backup retained at: $bak"
}

# ==========================
# Pre-flight checks
# ==========================
command -v openssl >/dev/null 2>&1 || handle_error "openssl is required."
command -v ambari-server >/dev/null 2>&1 || handle_error "ambari-server command not found in PATH."

# Root required
if [ "$EUID" -ne 0 ]; then
  handle_error "This script must be run as root."
fi

# SSL already configured?
if [ -f /etc/ambari-server/conf/ambari.properties ] && grep -q "^api\.ssl=true" /etc/ambari-server/conf/ambari.properties; then
  echo "SSL is already configured for Ambari Server. Exiting..."
  exit 0
fi

# Show variables and confirm
echo "Please validate the following before proceeding:"
echo "IMPORT_CERT_PATH: $IMPORT_CERT_PATH"
echo "IMPORT_KEY_PATH:  $IMPORT_KEY_PATH"
echo "PEM_PASSWORD:     *** (hidden)"
if ! prompt_yes_no "Do the variables look correct for Ambari HTTPS setup?"; then
  echo "Exiting..."
  exit 1
fi

# Validate file existence
[ -f "$IMPORT_CERT_PATH" ] || handle_error "Certificate not found at: $IMPORT_CERT_PATH"
[ -f "$IMPORT_KEY_PATH" ]  || handle_error "Private key not found at: $IMPORT_KEY_PATH"

# ==========================
# DER detection & handling
# ==========================
cert_format=$(detect_cert_format "$IMPORT_CERT_PATH")

if [ "$cert_format" = "DER" ]; then
  echo "Detected: Certificate is in DER format."
  echo "Ambari SSL requires PEM format; DER will not work."
  echo "You can convert it with the exact command:"
  echo "  openssl x509 -inform DER -in \"$IMPORT_CERT_PATH\" -out \"${IMPORT_CERT_PATH%.pem}.pem\""
  echo
  if prompt_yes_no "Do you want me to convert it to PEM now (backup will be taken)?"; then
    convert_der_to_pem_inplace "$IMPORT_CERT_PATH"
  else
    echo "Please convert the certificate to PEM before re-running this script."
    exit 1
  fi
elif [ "$cert_format" = "UNKNOWN" ]; then
  handle_error "Could not determine certificate format (neither valid PEM nor DER)."
else
  echo "Certificate appears to be PEM. Proceeding..."
fi

# (Optional) quick key sanity check (PEM header). Not failing, just warn.
if ! grep -qE '-----BEGIN (RSA |EC )?PRIVATE KEY-----' "$IMPORT_KEY_PATH"; then
  echo "WARNING: Private key does not look like a PEM key with a standard header."
  echo "Ensure $IMPORT_KEY_PATH is a PEM-encoded private key compatible with the provided certificate."
fi

# ==========================
# Configure Ambari HTTPS
# ==========================
ambari-server setup-security --security-option=setup-https --api-ssl=true \
  --import-cert-path="$IMPORT_CERT_PATH" \
  --import-key-path="$IMPORT_KEY_PATH" \
  --pem-password="$PEM_PASSWORD" \
  --api-ssl-port=8443

# ==========================
# Done
# ==========================
AMBARISERVER_URL="https://$(hostname -f):8443"
echo "Ambari URL: $AMBARISERVER_URL"
