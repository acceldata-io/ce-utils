#!/bin/bash
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
# Enable SSL for ClickHouse via Ambari configs
set -euo pipefail

############################################################
# Need User Inputs
############################################################
# Path to the ClickHouse server's private key file (PEM format)
PRIVATE_KEY_FILE="/opt/security/pki/server.key"
# Path to the ClickHouse server's SSL certificate file (PEM format)
CERT_FILE="/opt/security/pki/server.crt"
# Path to the CA certificate file (optional, PEM format); leave blank if not used
CA_CERT_FILE=""    # e.g. "/opt/security/pki/ca.crt" or "" if not applicable
# Path to the Java Keystore (JKS) containing SSL/TLS credentials
KEYSTORE_FILE="/opt/security/pki/keystore.jks"
# Password used to access the Java Keystore
KEYSTORE_PASSWORD="YourSecureKeystorePassword"
# Alias of the key entry within the keystore (optional; script can auto-detect if left blank)
KEYSTORE_ALIAS=""       # e.g. "clickhouse-ssl-key" or "" to auto-detect


# Ambari connection
AMBARISERVER="$(hostname -f)"
AMBARI_USER="admin"
AMBARI_USER_PASSWORD="admin"
PORT="8080"
PROTOCOL="http"
CLUSTER=""   # will auto-detect if empty

############################################################
# Colors & Formatting
############################################################
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
RESET=$(tput sgr0)
BOLD=$(tput bold)
NC='\e[0m'  # No Color
############################################################
# Helpers
############################################################
handle_error() { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }

prompt_yes_no() {
  local prompt="$1"
  while true; do
    read -r -p "$(echo -e "${YELLOW}${prompt} (yes/no): ${RESET}")" choice
    case "$choice" in
      [Yy]es|[Yy]) return 0 ;;
      [Nn]o|[Nn])  return 1 ;;
      *) echo "Please answer yes or no." ;;
    esac
  done
}

timestamp() { date +"%Y%m%d-%H%M%S"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

require_core_tools() {
  local miss=0
  for c in curl python; do
    need_cmd "$c" || { echo -e "${RED}Missing command: $c${RESET}"; miss=1; }
  done
  [ -f /var/lib/ambari-server/resources/scripts/configs.py ] || { 
    echo -e "${RED}Missing Ambari configs.py${RESET}"; miss=1; }
  [ $miss -eq 0 ] || handle_error "Install missing prerequisites and retry."
}

detect_cluster() {
  CLUSTER=$(curl -s -k -u "$AMBARI_USER:$AMBARI_USER_PASSWORD" -i -H 'X-Requested-By: ambari' \
    "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" \
    | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')
  [ -n "$CLUSTER" ] || handle_error "Unable to auto-detect Ambari cluster name."
  echo "$CLUSTER"
}

set_config() {
  local config_file=$1
  local key=$2
  local value=$3
  python /var/lib/ambari-server/resources/scripts/configs.py \
    -u "$AMBARI_USER" -p "$AMBARI_USER_PASSWORD" -s "$PROTOCOL" -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
    -c "$config_file" -k "$key" -v "$value"
}

show_variables() {
  echo -e "\n${CYAN}${BOLD}========== Current Configuration ==========${RESET}"
  echo -e "${GREEN}PRIVATE_KEY_FILE:${RESET} $PRIVATE_KEY_FILE"
  echo -e "${GREEN}CERT_FILE:       ${RESET} $CERT_FILE"
  echo -e "${GREEN}CA_CERT_FILE:    ${RESET} ${CA_CERT_FILE:-N/A}"
  echo -e "${GREEN}KEYSTORE_FILE:   ${RESET} $KEYSTORE_FILE"
  echo -e "${GREEN}KEYSTORE_PASS:   ${RESET} ********"
  echo -e "${GREEN}KEYSTORE_ALIAS:  ${RESET} ${KEYSTORE_ALIAS:-Auto-detect}"
  echo -e "${GREEN}AMBARI_SERVER:   ${RESET} $AMBARISERVER"
  echo -e "${GREEN}AMBARI_USER:     ${RESET} $AMBARI_USER"
  echo -e "${GREEN}CLUSTER:         ${RESET} ${CLUSTER:-Auto-detect}"
  echo -e "${CYAN}${BOLD}===========================================${RESET}\n"
}

############################################################
# Certificate & Key Validations
############################################################
detect_cert_format_local() {
  local cert="$1"
  need_cmd openssl || { echo "UNKNOWN"; return 0; }
  if openssl x509 -in "$cert" -noout -text >/dev/null 2>&1; then
    echo "PEM"; return
  fi
  if openssl x509 -inform DER -in "$cert" -noout -text >/dev/null 2>&1; then
    echo "DER"; return
  fi
  echo "UNKNOWN"
}

convert_der_to_pem_inplace_local() {
  local cert="$1"
  local bak="${cert}.bak.$(timestamp)"
  local tmp="${cert}.tmp.$(timestamp)"
  local owner grp mode
  owner=$(stat -c "%u" "$cert")
  grp=$(stat -c "%g" "$cert")
  mode=$(stat -c "%a" "$cert")
  echo -e "${YELLOW}Taking backup of current certificate: $bak${RESET}"
  cp -p "$cert" "$bak"
  echo -e "${YELLOW}Converting DER -> PEM${RESET}"
  openssl x509 -inform DER -in "$cert" -out "$tmp"
  mv -f "$tmp" "$cert"
  chown "$owner:$grp" "$cert"
  chmod "$mode" "$cert"
  echo -e "${GREEN}Conversion complete. Backup retained at: $bak${RESET}"
}

is_key_encrypted_local() {
  local key="$1"
  grep -qE 'ENCRYPTED|Proc-Type: 4,ENCRYPTED|BEGIN ENCRYPTED PRIVATE KEY' "$key"
}

auto_alias_from_keystore() {
  local ks="$1" pass="$2"
  need_cmd keytool || { echo ""; return 0; }
  keytool -list -v -keystore "$ks" -storepass "$pass" 2>/dev/null \
    | awk -F': ' '/Alias name/ {print $2; exit}'
}

print_remote_instructions() {
  local kfile="$1"
  local cfile="$2"
  cat <<EOF

${CYAN}=================================================================${RESET}
Some files are missing locally. Perform these steps on EACH ClickHouse node:

1) Check and convert certificate (DER → PEM if needed):
   openssl x509 -in "${cfile}" -noout -text || \
   openssl x509 -inform DER -in "${cfile}" -out "${cfile}.pem" && mv -f "${cfile}.pem" "${cfile}"

2) Ensure private key is NOT encrypted:
   grep -E 'ENCRYPTED|Proc-Type: 4,ENCRYPTED|BEGIN ENCRYPTED PRIVATE KEY' "${kfile}" \
     && echo "Encrypted" || echo "Not encrypted"

3) If encrypted, decrypt:
   openssl rsa -in "${kfile}" -out "${kfile%.key}.unencrypted.key"
   or
   openssl pkcs8 -in "${kfile}" -out "${kfile%.key}.unencrypted.key" -nocrypt

4) Replace the original key with unencrypted one (after backup).
${CYAN}=================================================================${RESET}
EOF
}

############################################################
# Validation Pipeline
############################################################
validate_local_files() {
  local cert_local="present"
  local key_local="present"
  local ca_local="present"
  local ks_local="present"

  [ -f "$CERT_FILE" ] || cert_local="absent"
  [ -f "$PRIVATE_KEY_FILE" ] || key_local="absent"
  [ -z "$CA_CERT_FILE" ] || { [ -f "$CA_CERT_FILE" ] || ca_local="absent"; }
  [ -f "$KEYSTORE_FILE" ] || ks_local="absent"

  # Keystore alias auto-detect
  if [ -z "$KEYSTORE_ALIAS" ] && [ "$ks_local" = "present" ]; then
    KEYSTORE_ALIAS="$(auto_alias_from_keystore "$KEYSTORE_FILE" "$KEYSTORE_PASSWORD" || true)"
    [ -n "$KEYSTORE_ALIAS" ] || handle_error "Could not detect alias from keystore. Provide KEYSTORE_ALIAS."
    echo -e "${GREEN}Using keystore alias:${RESET} $KEYSTORE_ALIAS"
  fi

  # Certificate validation
  if [ "$cert_local" = "present" ]; then
    cf="$(detect_cert_format_local "$CERT_FILE")"
    case "$cf" in
      DER)
        echo -e "${RED}Certificate is in DER format — invalid for ClickHouse.${RESET}"
        if need_cmd openssl && prompt_yes_no "Convert DER → PEM in-place (backup will be taken)?"; then
          convert_der_to_pem_inplace_local "$CERT_FILE"
        else
          handle_error "Convert certificate to PEM and retry."
        fi ;;
      UNKNOWN)
        echo -e "${YELLOW}WARNING: Could not determine certificate format. Ensure PEM.${RESET}" ;;
      PEM)
        echo -e "${GREEN}Certificate is PEM — OK.${RESET}" ;;
    esac
  else
    print_remote_instructions "$PRIVATE_KEY_FILE" "$CERT_FILE"
    if ! prompt_yes_no "Proceed WITHOUT local validation?"; then
      handle_error "User aborted due to missing files."
    fi
  fi

  # Private key validation
  if [ "$key_local" = "present" ]; then
    if is_key_encrypted_local "$PRIVATE_KEY_FILE"; then
      cat >&2 <<'NOTE'
Detected: Private key appears ENCRYPTED.
ClickHouse requires an UNENCRYPTED PEM private key.

To decrypt:
  openssl rsa -in encrypted.key -out unencrypted.key
  OR
  openssl pkcs8 -in encrypted.key -out unencrypted.key -nocrypt

Backup and replace the original key if needed.
NOTE
      exit 1
    else
      echo -e "${GREEN}Private key appears unencrypted — OK.${RESET}"
    fi
  fi

  # CA cert check
  if [ -n "$CA_CERT_FILE" ] && [ "$ca_local" = "absent" ]; then
    echo -e "${YELLOW}NOTE: CA file path provided but not present locally. Ensure it's on all nodes.${RESET}"
  fi
}

############################################################
# Apply Configs
############################################################
apply_configs() {
  echo -e "${CYAN}Applying ClickHouse SSL configs via Ambari...${RESET}"

  set_config "clickhouse-application" "server_ssl_keystore"           "$KEYSTORE_FILE"
  set_config "clickhouse-application" "server_ssl_keystore_type"      "JKS"
  set_config "clickhouse-application" "server_ssl_key_alias"          "$KEYSTORE_ALIAS"
  set_config "clickhouse-application" "server_ssl_enabled"            "true"
  set_config "clickhouse-application" "server_ssl_keystore_password"  "$KEYSTORE_PASSWORD"

  set_config "clickhouse-env" "private_key_file"  "$PRIVATE_KEY_FILE"
  set_config "clickhouse-env" "certificate_file"  "$CERT_FILE"
  set_config "clickhouse-env" "enable_ssl"        "true"

  if [ -n "$CA_CERT_FILE" ]; then
    set_config "clickhouse-env" "ca_config_file" "$CA_CERT_FILE"
  else
    set_config "clickhouse-env" "ca_config_file" ""
  fi

  echo -e "${GREEN}Done. Ambari configs updated.${RESET}"
  echo "Ensure the following exist on ALL ClickHouse nodes:"
  echo "  - PEM certificate:         $CERT_FILE"
  echo "  - UNENCRYPTED private key: $PRIVATE_KEY_FILE"
  [ -n "$CA_CERT_FILE" ] && echo "  - CA certificate:          $CA_CERT_FILE"
  echo "Then restart the ClickHouse service in Ambari."
}

############################################################
# Main Workflow
############################################################
require_core_tools

if [ -z "${CLUSTER:-}" ]; then
  echo -e "${CYAN}Detecting Ambari cluster name...${RESET}"
  CLUSTER="$(detect_cluster)"
  echo -e "${GREEN}Detected cluster:${RESET} $CLUSTER"
fi

show_variables
validate_local_files

if ! prompt_yes_no "Proceed with applying these settings?"; then
  echo -e "${YELLOW}Aborted by user.${RESET}"
  exit 1
fi

apply_configs

#---------------------------------------------------------
# Post-Execution: Move Generated JSON Files (if any)
#---------------------------------------------------------
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo -e "${GREEN}JSON files moved to /tmp.${NC}"
else
    echo -e "${YELLOW}No JSON files found to move.${NC}"
fi
