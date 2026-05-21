#!/bin/bash
# =============================================================================
#  pulse_ssl_setup.sh — Enable native HTTPS on the Acceldata Pulse Web UI
# =============================================================================
#
#  Synopsis:
#    ./pulse_ssl_setup.sh
#
#  Purpose:
#    Terminates TLS inside the ad-pulse-ui container (no ad-proxy sidecar).
#
#  Workflow:
#    1. Validate cert/key paths and passphrase.
#    2. Install cert/key as ssl.crt / ssl.key in $AcceloHome/config/proxy/certs.
#    3. Flip SSL_* env vars in the ad-pulse-ui section of ad-core.yml and add
#       the ./config/proxy/certs:/etc/acceldata/ssl volume mount.
#    4. Restart ad-pulse-ui and verify TLS on port 4000.
#
#  Required binaries:
#    bash, awk, sed, openssl, docker, accelo
#
#  Environment:
#    $AcceloHome  Pulse install directory (sourced from /etc/profile.d/ad.sh)
#
#  Exit codes:
#    0  success
#    1  generic failure
#
#  Author:    Acceldata Inc.
#  License:   Proprietary
# =============================================================================

# ---------------------------------------------------------------------------
#  ANSI color / glyph constants
# ---------------------------------------------------------------------------
YELLOW=$'\033[0;33m'
GREEN=$'\e[0;32m'
BLUE=$'\033[0;94m'
RED=$'\e[0;31m'
GREY=$'\033[90m'
ICyan=$'\033[0;96m'
CYAN=$'\033[0;36m'
NC=$'\e[0m'
TICK="✅"
CROSS="❌"

# ---------------------------------------------------------------------------
#  Logging helpers
# ---------------------------------------------------------------------------
print_success() {
  echo -e "${GREEN}${TICK} Success: $1${NC}"
}

print_info() {
  echo -e "${BLUE}${TICK} Success: $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}Warning: $1${NC}"
}

print_error() {
  echo -e "${RED}${CROSS} Error: $1${NC}" >&2
  exit 1
}

print_error_soft() {
  echo -e "${RED}${CROSS} Error: $1${NC}" >&2
}

print_header() {
  local separator="${GREY}***********************************************************************************${NC}"
  echo -e "${separator}"
  echo "$1"
  echo -e "${separator}"
}

# ---------------------------------------------------------------------------
#  TLS helpers
# ---------------------------------------------------------------------------

# Exit 1 if the named command is not on $PATH.
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || print_error "$cmd not found. Please install it."
}

# Copy a file to a destination, printing success or exiting on failure.
copy_file() {
  local source_file="$1"
  local destination="$2"

  if cp -f "$source_file" "$destination"; then
    print_success "File $source_file copied to $destination"
  else
    print_error "Failed to copy $source_file to $destination"
  fi
}

# Copy a certificate file into the Pulse proxy certs directory.
import_certificate() {
  local file_path="$1"
  if [ ! -f "$file_path" ]; then
    print_error "Certificate file not found: $file_path"
  fi
  copy_file "$file_path" "$AcceloHome/config/proxy/certs/$(basename "$file_path")"
}

# ---------------------------------------------------------------------------
#  Main: enable native HTTPS on the Pulse web UI
# ---------------------------------------------------------------------------
enable_ui_tls() {
  local PULSE_SERVICE="ad-pulse-ui"
  local PULSE_PORT=4000

  print_header "[1/9] Preflight: checking required tools and docker daemon"
  local required_commands=("openssl" "awk" "sed" "docker" "accelo")
  local cmd
  for cmd in "${required_commands[@]}"; do
    require_command "$cmd"
  done
  print_success "Found: ${required_commands[*]}"

  if ! docker info >/dev/null 2>&1; then
    print_error "Docker daemon is not reachable. Start docker and retry."
  fi
  print_success "Docker daemon is reachable"
  echo

  print_header "[2/9] Loading Acceldata environment"
  if [ -f "/etc/profile.d/ad.sh" ]; then
    # shellcheck source=/dev/null
    source /etc/profile.d/ad.sh || print_error "Failed to source /etc/profile.d/ad.sh."
  else
    print_error "Environment file /etc/profile.d/ad.sh not found."
  fi
  if [ -z "${AcceloHome:-}" ] || [ ! -d "$AcceloHome" ]; then
    print_error "AcceloHome is not set or directory missing: '${AcceloHome:-<unset>}'"
  fi
  local AD_CORE_YML="$AcceloHome/config/docker/ad-core.yml"
  local CERT_DIR="$AcceloHome/config/proxy/certs"
  local host
  host="$(hostname -f 2>/dev/null || hostname)"
  print_success "AcceloHome = $AcceloHome"
  echo -e "${BLUE}→ Expected ad-core.yml path: ${NC}$AD_CORE_YML"
  if [ -f "$AD_CORE_YML" ]; then
    echo -e "${BLUE}  (exists — will be edited in place)${NC}"
  else
    echo -e "${YELLOW}  (missing — will be generated via 'accelo admin makeconfig ad-core' in step 5)${NC}"
  fi
  echo -e "${BLUE}→ Certs directory: ${NC}$CERT_DIR"
  if [ -d "$CERT_DIR" ]; then
    echo -e "${BLUE}  (exists)${NC}"
  else
    echo -e "${YELLOW}  (missing — will be created in step 6)${NC}"
  fi
  echo

  print_header "[3/9] Collecting certificate and key paths"
  local cert_crt cert_key
  read -rp $'\e[36mEnter the path to the server certificate file (cert.crt): \e[0m' cert_crt
  read -rp $'\e[36mEnter the path to the private key file (cert.key): \e[0m' cert_key
  echo

  echo -e "${BLUE}→ Checking that both files exist and are readable...${NC}"
  [ -f "$cert_crt" ] || print_error "Certificate file not found: $cert_crt"
  [ -f "$cert_key" ] || print_error "Private key file not found: $cert_key"
  [ -r "$cert_crt" ] || print_error "Certificate file not readable: $cert_crt"
  [ -r "$cert_key" ] || print_error "Private key file not readable: $cert_key"
  print_success "Cert and key files exist and are readable"
  echo

  print_header "[4/9] Validating certificate and private key"
  echo -e "${BLUE}→ Verifying certificate is PEM-encoded...${NC}"
  if openssl x509 -in "$cert_crt" -noout &>/dev/null; then
    print_success "Certificate is in PEM format"
  else
    print_error "Certificate is not in PEM format: $cert_crt"
  fi

  echo -e "${BLUE}→ Checking certificate expiry (must be valid for >0 days)...${NC}"
  if openssl x509 -in "$cert_crt" -noout -checkend 0 &>/dev/null; then
    local not_after
    not_after=$(openssl x509 -in "$cert_crt" -noout -enddate | cut -d= -f2)
    print_success "Certificate is not expired (notAfter: $not_after)"
  else
    print_error "Certificate has already expired: $cert_crt"
  fi

  echo -e "${BLUE}→ Detecting whether the private key is password-protected...${NC}"
  local key_encrypted="no"
  local key_pass=""
  if grep -qE 'BEGIN ENCRYPTED PRIVATE KEY|Proc-Type: 4,ENCRYPTED' "$cert_key"; then
    key_encrypted="yes"
    print_warning "Private key is encrypted — a passphrase will be required"
  else
    print_success "Private key is NOT encrypted — no passphrase needed"
  fi

  if [ "$key_encrypted" = "yes" ]; then
    read -rsp $'\e[36mEnter the private key passphrase (input is hidden): \e[0m' key_pass
    echo
    echo
    if [ -z "$key_pass" ]; then
      print_error "Private key is encrypted but no passphrase was provided."
    fi
    echo -e "${BLUE}→ Verifying passphrase unlocks the private key...${NC}"
    if openssl rsa -in "$cert_key" -passin pass:"$key_pass" -noout &>/dev/null; then
      print_success "Passphrase verified against private key"
    else
      print_error "Provided passphrase does not unlock the private key."
    fi
  fi

  echo -e "${BLUE}→ Confirming certificate and key belong to the same pair...${NC}"
  local crt_mod key_mod openssl_rsa_args=()
  [ -n "$key_pass" ] && openssl_rsa_args=(-passin "pass:$key_pass")
  crt_mod=$(openssl x509 -in "$cert_crt" -noout -modulus 2>/dev/null | openssl md5)
  key_mod=$(openssl rsa  -in "$cert_key" "${openssl_rsa_args[@]}" -noout -modulus 2>/dev/null | openssl md5)
  if [ -n "$crt_mod" ] && [ "$crt_mod" = "$key_mod" ]; then
    print_success "Certificate and key modulus match"
  else
    print_error "Certificate and private key do not match (modulus mismatch)."
  fi

  echo -e "${BLUE}→ Certificate details:${NC}"
  openssl x509 -in "$cert_crt" -noout -subject -issuer \
    || print_error "Failed to read certificate subject/issuer."
  echo

  print_header "[5/9] Ensuring ad-core.yml is present and inspecting current SSL state"
  if [ ! -f "$AD_CORE_YML" ]; then
    echo -e "${BLUE}→ ad-core.yml missing; generating via 'accelo admin makeconfig ad-core'...${NC}"
    accelo admin makeconfig ad-core || print_error "Failed to create ad-core.yml."
    print_success "Generated $AD_CORE_YML"
  else
    print_success "ad-core.yml already present"
  fi

  if ! grep -qE '^[[:space:]]{2}'"$PULSE_SERVICE"':[[:space:]]*$' "$AD_CORE_YML"; then
    print_error "Section '$PULSE_SERVICE:' not found in $AD_CORE_YML — cannot continue."
  fi
  print_success "Found '$PULSE_SERVICE:' section in ad-core.yml"

  local ssl_already_on
  ssl_already_on=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && ($0 ~ /SSL_ENFORCED=true/ || $0 ~ /SSL_ENABLED=true/) { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$ssl_already_on" -gt 0 ]; then
    print_warning "Pulse SSL appears to be already enabled in '$PULSE_SERVICE' section."
    local answer
    read -rp $'\e[31mContinue with SSL enablement anyway? [y/N]: \e[0m' answer
    case "$answer" in
      [Yy]|[Yy][Ee][Ss]) print_info "Continuing per user confirmation" ;;
      [Nn]|[Nn][Oo]|"")  echo "Exiting without changes."; return 0 ;;
      *)                 print_error "Invalid input. Aborting." ;;
    esac
  else
    print_success "SSL not yet enabled in '$PULSE_SERVICE' — safe to proceed"
  fi

  echo -e "${BLUE}→ Backing up ad-core.yml to ad-core.yml.bak...${NC}"
  cp "$AD_CORE_YML" "$AD_CORE_YML.bak" || print_error "Failed to back up ad-core.yml."
  print_success "Backup saved to $AD_CORE_YML.bak"
  echo

  print_header "[6/9] Installing certificate and key as ssl.crt / ssl.key"
  mkdir -p "$CERT_DIR" || print_error "Failed to create $CERT_DIR."

  echo -e "${BLUE}→ Copying cert and key into $CERT_DIR...${NC}"
  import_certificate "$cert_crt"
  import_certificate "$cert_key"

  local staged_crt staged_key
  staged_crt="$CERT_DIR/$(basename "$cert_crt")"
  staged_key="$CERT_DIR/$(basename "$cert_key")"
  echo -e "${BLUE}→ Renaming to canonical ssl.crt / ssl.key (the names ad-pulse-ui reads)...${NC}"
  if [ "$staged_crt" != "$CERT_DIR/ssl.crt" ]; then
    mv -f "$staged_crt" "$CERT_DIR/ssl.crt" || print_error "Failed to rename cert to ssl.crt."
  fi
  if [ "$staged_key" != "$CERT_DIR/ssl.key" ]; then
    mv -f "$staged_key" "$CERT_DIR/ssl.key" || print_error "Failed to rename key to ssl.key."
  fi
  chmod 0644 "$CERT_DIR/ssl.crt" || print_error "Failed to chmod ssl.crt."
  chmod 0600 "$CERT_DIR/ssl.key" || print_error "Failed to chmod ssl.key."
  print_success "Installed ssl.crt (0644) and ssl.key (0600) in $CERT_DIR"
  echo

  print_header "[7/9] Updating SSL_* env vars and volume mount in ad-pulse-ui"

  local passphrase_value='""'
  local passphrase_encrypted="false"
  if [ -n "$key_pass" ]; then
    echo -e "${BLUE}→ Encrypting passphrase via 'accelo admin encrypt'...${NC}"
    local encrypt_out encrypted_pass
    encrypt_out=$(printf '%s\n' "$key_pass" | accelo admin encrypt 2>&1) \
      || print_error "accelo admin encrypt failed: $encrypt_out"
    encrypted_pass=$(echo "$encrypt_out" | awk -F'ENCRYPTED: *' '/ENCRYPTED:/ {print $2; exit}' | tr -d '[:space:]')
    if [ -z "$encrypted_pass" ]; then
      print_error "Could not parse ENCRYPTED: output from accelo admin encrypt."
    fi
    passphrase_value="$encrypted_pass"
    passphrase_encrypted="true"
    print_success "Passphrase encrypted (SSL_PASSPHRASE_ENCRYPTED=true)"
  else
    echo -e "${BLUE}→ No passphrase — writing SSL_PASSPHRASE=\"\" and SSL_PASSPHRASE_ENCRYPTED=false${NC}"
  fi

  echo -e "${BLUE}→ Setting SSL_ENFORCED=true, SSL_ENABLED=false, SSL_UI_PORT=$PULSE_PORT${NC}"
  local tmp_yml="$AD_CORE_YML.tmp"
  PASS_VALUE="$passphrase_value" PASS_ENC="$passphrase_encrypted" \
  awk -v svc="$PULSE_SERVICE:" -v port="$PULSE_PORT" '
    BEGIN {
      pass_value = ENVIRON["PASS_VALUE"]
      pass_enc   = ENVIRON["PASS_ENC"]
      ssl_port_seen = 0
      enc_seen      = 0
    }
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ {
      section = $1
      ssl_port_seen = 0
      enc_seen      = 0
    }
    {
      if (section == svc) {
        if ($0 ~ /SSL_UI_PORT=/) {
          if (ssl_port_seen) { next }
          ssl_port_seen = 1
          sub(/SSL_UI_PORT=[0-9]+/, "SSL_UI_PORT=" port)
        }
        sub(/SSL_ENFORCED=false/, "SSL_ENFORCED=true")
        sub(/SSL_ENABLED=true/,  "SSL_ENABLED=false")
        if ($0 ~ /SSL_PASSPHRASE_ENCRYPTED=/) {
          if (enc_seen) { next }
          enc_seen = 1
          sub(/SSL_PASSPHRASE_ENCRYPTED=.*/, "SSL_PASSPHRASE_ENCRYPTED=" pass_enc)
        } else if ($0 ~ /SSL_PASSPHRASE=/) {
          sub(/SSL_PASSPHRASE=.*/, "SSL_PASSPHRASE=" pass_value)
          print
          if (!enc_seen) {
            match($0, /^[[:space:]]*-[[:space:]]/)
            prefix = substr($0, RSTART, RLENGTH)
            print prefix "SSL_PASSPHRASE_ENCRYPTED=" pass_enc
            enc_seen = 1
          }
          next
        }
      }
      print
    }
  ' "$AD_CORE_YML" > "$tmp_yml"
  if [ $? -ne 0 ]; then
    rm -f "$tmp_yml"
    print_error "awk failed to rewrite ad-core.yml."
  fi
  mv "$tmp_yml" "$AD_CORE_YML" || { rm -f "$tmp_yml"; print_error "Failed to move updated ad-core.yml into place."; }
  print_success "SSL_* variables updated in '$PULSE_SERVICE' section"

  local ssl_port_count
  ssl_port_count=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && /SSL_UI_PORT=/ { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$ssl_port_count" -ne 1 ]; then
    print_error "Expected exactly 1 SSL_UI_PORT line in '$PULSE_SERVICE' after update, found $ssl_port_count. Restore from $AD_CORE_YML.bak and investigate."
  fi
  print_success "SSL_UI_PORT appears exactly once in '$PULSE_SERVICE' section"

  echo -e "${BLUE}→ Ensuring ./config/proxy/certs is mounted at /etc/acceldata/ssl inside the container...${NC}"
  local mount_in_section
  mount_in_section=$(awk -v svc="$PULSE_SERVICE:" '
    /^  [a-zA-Z0-9_-]+:[[:space:]]*$/ { section = $1 }
    section == svc && /\/config\/proxy\/certs/ { n++ }
    END { print n+0 }
  ' "$AD_CORE_YML")
  if [ "$mount_in_section" -eq 0 ]; then
    sed -i "/${PULSE_SERVICE}:/,/ulimits:/ s|volumes:|volumes:\n    - ./config/proxy/certs:/etc/acceldata/ssl|" "$AD_CORE_YML" \
      || print_error "Failed to add certs volume mount to $PULSE_SERVICE."
    print_success "Added volume mount: ./config/proxy/certs -> /etc/acceldata/ssl"
  else
    print_info "Volume mount already present in '$PULSE_SERVICE' — nothing to add"
  fi
  echo

  print_header "[8/9] Restarting $PULSE_SERVICE container"
  echo -e "${BLUE}→ Checking current state of '$PULSE_SERVICE'...${NC}"
  local pulse_container
  pulse_container=$(docker ps -a --format '{{.Names}}' | grep -E "^${PULSE_SERVICE}(_|$)" | head -n1)
  if [ -z "$pulse_container" ]; then
    print_warning "Container '$PULSE_SERVICE' not found in 'docker ps -a'."
    print_info    "If Pulse was never deployed, run 'accelo deploy all' before enabling TLS."
    print_error   "Cannot restart a container that does not exist."
  fi
  print_success "Found container: $pulse_container"

  echo -e "${BLUE}→ Running: accelo restart $PULSE_SERVICE${NC}"
  if ! echo "y" | accelo restart "$PULSE_SERVICE"; then
    print_error "Failed to restart $PULSE_SERVICE. Inspect with 'docker logs $pulse_container' and restore $AD_CORE_YML.bak if needed."
  fi
  print_success "Restart command completed"

  echo -e "${BLUE}→ Waiting 10 seconds for $PULSE_SERVICE to come up...${NC}"
  sleep 10
  if ! docker ps --format '{{.Names}}' | grep -qE "^${PULSE_SERVICE}(_|$)"; then
    print_error_soft "$PULSE_SERVICE is not running after restart — check 'docker logs $pulse_container'."
  else
    print_success "$PULSE_SERVICE is running"
  fi
  echo

  print_header "[9/9] Verifying TLS handshake on localhost:$PULSE_PORT"
  echo -e "${BLUE}→ Running openssl s_client against localhost:$PULSE_PORT...${NC}"
  if openssl s_client -connect "localhost:$PULSE_PORT" -showcerts </dev/null 2>/dev/null \
       | openssl x509 -noout -checkend 0 &>/dev/null; then
    print_success "TLS is live and certificate is valid on port $PULSE_PORT"
  else
    print_error_soft "Could not verify TLS on port $PULSE_PORT yet."
    print_info       "The container may still be starting up. Re-check with:"
    print_info       "  openssl s_client -connect localhost:$PULSE_PORT </dev/null"
    print_info       "  docker logs $pulse_container"
  fi
  echo
  echo -e "${GREEN}${TICK} Pulse Web UI is now served over HTTPS.${NC}"
  echo -e "${GREEN}   Access at: https://$host:$PULSE_PORT${NC}"
}

enable_ui_tls
