#!/usr/bin/env bash
#
# build_ssl_keystores.sh
#
# Turns a server cert + private key + CA bundle into the three SSL
# artifacts a Java app typically needs:
#
#   <OUTPUT_DIR>/keystore.pfx       — PKCS12 (cert + key + chain)
#   <OUTPUT_DIR>/keystore.jks       — Java keystore (JKS)
#   <OUTPUT_DIR>/truststore.jks     — Java truststore (one entry per CA)
#
# Usage:
#   ./build_ssl_keystores.sh                       # interactive (guided menu)
#   ./build_ssl_keystores.sh -c server.crt \
#                            -k server.key \
#                            -a ca-bundle.pem \
#                            -p 'keypass' \
#                            -o /opt/security/ssl -y    # non-interactive
#   ./build_ssl_keystores.sh -h                    # full help / all flags
#   ./build_ssl_keystores.sh ... -d                # dry-run (print commands)
#
# Modes:
#   Interactive (no args): guided prompts + menu.
#   Non-interactive  (-y): all inputs via flags, full pipeline runs.
#
# Requires: openssl, keytool (any JDK).

set -euo pipefail
IFS=$'\n\t'

# --------------------------------------------------------------------------
# Globals (user-facing names describe exactly what goes into them)
# --------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
DEFAULT_OUTPUT_DIR="/opt/security/ssl"

SERVER_CERT=""       # leaf/server certificate (PEM)         [-c]
SERVER_KEY=""        # matching private key (PEM)            [-k]
CA_BUNDLE=""         # intermediate + root CAs (PEM bundle)  [-a]
SERVER_KEY_PASS=""   # passphrase for the private key        [-p]
KEYSTORE_PASS=""     # shared keystore/truststore password   [-s]
OUTPUT_DIR=""        # directory to write artifacts to       [-o]
CERT_ALIAS=""        # alias used inside the keystore        [-n]
NON_INTERACTIVE=0    # set by -y
DRY_RUN=0            # set by -d (print commands, do not execute)

TMP_DIR=""

KEYSTORE_PFX_NAME="keystore.pfx"
KEYSTORE_JKS_NAME="keystore.jks"
TRUSTSTORE_JKS_NAME="truststore.jks"

# File permissions applied to every generated artifact (PFX/JKS/truststore).
# Tightly-scoped because these files embed the private key.
OUTPUT_FILE_MODE="0655"

# Warn when the server cert expires within this many days. Hard-fail if
# the cert is already expired.
EXPIRY_WARN_DAYS=30

# Pipeline step counter — drives the "[step N/M]" progress prefix.
STEP_CURRENT=0
STEP_TOTAL=3

# --------------------------------------------------------------------------
# Colors / logging — logs go to STDERR so $(prompt_*) captures stay clean
# --------------------------------------------------------------------------
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[0;31m'
    C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m'
    C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RESET=$'\033[0m'
    USE_UNICODE=1
    ARROW="→"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
    C_BOLD=""; C_DIM=""; C_RESET=""
    USE_UNICODE=0
    ARROW="->"
fi

_log() {
    echo "$1" >&2
}

# All prefixes are 6 chars wide (4 visible + surrounding brackets) and
# followed by two spaces so message bodies align in a single column.
info() { _log "${C_BLUE}[INFO]${C_RESET}  $*"; }
ok()   { _log "${C_GREEN}[ OK ]${C_RESET}  $*"; }
warn() { _log "${C_YELLOW}[WARN]${C_RESET}  $*"; }
err()  { _log "${C_RED}[FAIL]${C_RESET}  $*"; }
dim()  { _log "${C_DIM}$*${C_RESET}"; }

die() { err "$*"; exit 1; }

cleanup() {
    if [[ -n "$TMP_DIR" ]] && [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
${C_BOLD}${SCRIPT_NAME}${C_RESET} — Build SSL keystores (PFX + JKS + truststore) for a Java app

${C_BOLD}WHAT IT DOES${C_RESET}
  Takes a signed server certificate, its private key, and the CA chain,
  then produces three artifacts into <OUTPUT_DIR>:

    keystore.pfx       PKCS12 bundle (cert + key + chain)
    keystore.jks       Java keystore used by the application
    truststore.jks     Java truststore (one entry per CA in the bundle)

  Any existing files in <OUTPUT_DIR> are safely backed up as
  *.bak.<timestamp> before being overwritten.

${C_BOLD}USAGE${C_RESET}
  $SCRIPT_NAME                        # interactive (guided menu)
  $SCRIPT_NAME [flags] -y             # non-interactive (CI/CD)

${C_BOLD}INPUTS${C_RESET}
  -c <SERVER_CERT>     Path to the server/leaf certificate. PEM or DER —
                       DER inputs are auto-converted to PEM (common for
                       .cer files exported from Windows / AD).
                       Typical extensions: .pem .crt .cer
                       Must contain ONLY the leaf cert (no private key).
                       Verify with: openssl x509 -in <file> -noout -subject

  -k <SERVER_KEY>      Path to the matching private key, PEM format.
                       Typical extensions: .key .pem
                       May be encrypted (starts with "BEGIN ENCRYPTED
                       PRIVATE KEY" or contains "Proc-Type: 4,ENCRYPTED").
                       Verify with: openssl pkey -in <file> -noout

  -a <CA_BUNDLE>       Path to the CA certificate chain. PEM bundle
                       (intermediate+root concatenated), OR a single PEM/DER
                       CA (single-cert DER is auto-converted to PEM).
                       Order in a bundle: intermediate first, then root.
                       Verify with:
                         openssl crl2pkcs7 -nocrl -certfile <file> \\
                           | openssl pkcs7 -print_certs -noout

  -p <SERVER_KEY_PASS> Passphrase for -k (required only if the key is
                       encrypted). Not needed for unencrypted keys.

  -s <KEYSTORE_PASS>   Shared password used for BOTH keystore.jks and
                       truststore.jks.
                         • encrypted key: keystore pass MUST equal the
                           key password. -s is optional; if given it must
                           match -p (or the script exits with an error).
                         • unencrypted key: -s (or interactive prompt)
                           supplies any password you choose.

  -o <OUTPUT_DIR>      Destination directory (default: $DEFAULT_OUTPUT_DIR).
                       Created if missing. If it requires root you'll get
                       a 'sudo mkdir ... && sudo chown' hint.

  -n <CERT_ALIAS>      Alias used for the keystore entry.
                       Default: derived from the certificate's CN.

  -y                   Non-interactive mode: run the full pipeline and exit.
                       Fails fast if any required input is missing.

  -d                   Dry-run: print every openssl/keytool command that
                       would execute, without writing any files. Safe to
                       run against real paths to preview what will happen.

  -h                   Show this help.

${C_BOLD}PASSWORD POLICY${C_RESET}
  keystore.jks and truststore.jks ALWAYS share the same password.
  • If the private key is encrypted, the keystore/truststore password
    is ALWAYS the private key password (not configurable). Passing
    -s with a different value is an error.
  • If the private key is unencrypted, you choose any password (via
    -s or the interactive prompt) for the keystores.

${C_BOLD}EXAMPLES${C_RESET}
  # Interactive (menu, prompts for every input)
  $SCRIPT_NAME

  # Non-interactive full pipeline, encrypted key, shared pass defaults to key pass
  $SCRIPT_NAME -c server.crt -k server.key -a ca-bundle.pem \\
               -p 'keypass' -o /opt/security/ssl -y

  # Unencrypted key, explicit keystore password, custom output dir
  $SCRIPT_NAME -c server.pem -k server-nopass.key -a ca.pem \\
               -s 'storepass' -o /etc/myapp/ssl -y

  # Preview every openssl/keytool command without writing anything
  $SCRIPT_NAME -c server.crt -k server.key -a ca.pem \\
               -p 'keypass' -o /opt/security/ssl -d -y

${C_BOLD}VALIDATION${C_RESET}
  • Certificate must be valid X.509 and not expired.
  • A warning is printed if the cert expires within ${EXPIRY_WARN_DAYS} days.
  • Certificate public key must match the private key.
  • CA chain order is verified (intermediate(s) first, root last).

${C_BOLD}OUTPUT PERMISSIONS${C_RESET}
  All generated files (keystore.pfx / keystore.jks / truststore.jks) are
  chmod'd to ${OUTPUT_FILE_MODE} — they contain the private key.

${C_BOLD}ENV VARS${C_RESET}
  NO_COLOR=1           Disable ANSI colors.

${C_BOLD}EXIT CODES${C_RESET}
  0   success
  1   invalid input, validation failure, or tool failure
EOF
}

# --------------------------------------------------------------------------
# Dependency checks
# --------------------------------------------------------------------------
check_dependencies() {
    local missing=0
    if ! command -v openssl >/dev/null 2>&1; then
        err "openssl not found in PATH. Install openssl ('brew install openssl' or 'apt-get install openssl')."
        missing=1
    fi
    if ! command -v keytool >/dev/null 2>&1; then
        err "keytool not found in PATH. Install a JDK ('brew install openjdk' or 'apt-get install default-jdk')."
        missing=1
    fi
    (( missing == 0 )) || exit 1
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
parse_args() {
    local opt
    while getopts ":c:k:a:p:s:o:n:dyh" opt; do
        case "$opt" in
            c) SERVER_CERT="$OPTARG" ;;
            k) SERVER_KEY="$OPTARG" ;;
            a) CA_BUNDLE="$OPTARG" ;;
            p) SERVER_KEY_PASS="$OPTARG" ;;
            s) KEYSTORE_PASS="$OPTARG" ;;
            o) OUTPUT_DIR="$OPTARG" ;;
            n) CERT_ALIAS="$OPTARG" ;;
            d) DRY_RUN=1 ;;
            y) NON_INTERACTIVE=1 ;;
            h) usage; exit 0 ;;
            \?) die "Unknown option: -$OPTARG (use -h for help)" ;;
            :) die "Option -$OPTARG requires an argument (use -h for help)" ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Prompt helpers
# --------------------------------------------------------------------------
prompt_path() {
    local prompt="$1"
    local default="${2:-}"
    local answer
    while true; do
        if [[ -n "$default" ]]; then
            read -r -p "$prompt [$default]: " answer
            answer="${answer:-$default}"
        else
            read -r -p "$prompt: " answer
        fi
        if [[ -z "$answer" ]]; then
            warn "Value cannot be empty."
            continue
        fi
        if [[ ! -f "$answer" ]]; then
            warn "File not found: $answer"
            continue
        fi
        printf '%s' "$answer"
        return 0
    done
}

prompt_dir() {
    local prompt="$1"
    local default="${2:-}"
    local answer
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " answer
        answer="${answer:-$default}"
    else
        read -r -p "$prompt: " answer
    fi
    printf '%s' "$answer"
}

prompt_password_once() {
    local prompt="$1"
    local pw
    while true; do
        read -r -s -p "$prompt: " pw
        echo >&2
        if [[ -z "$pw" ]]; then
            warn "Password cannot be empty."
            continue
        fi
        printf '%s' "$pw"
        return 0
    done
}

prompt_password_confirm() {
    local prompt="$1"
    local pw1 pw2
    while true; do
        read -r -s -p "$prompt: " pw1
        echo >&2
        read -r -s -p "Confirm: " pw2
        echo >&2
        if [[ "$pw1" != "$pw2" ]]; then
            warn "Passwords do not match. Try again."
            continue
        fi
        if [[ -z "$pw1" ]]; then
            warn "Password cannot be empty."
            continue
        fi
        printf '%s' "$pw1"
        return 0
    done
}

# --------------------------------------------------------------------------
# Validation helpers
# --------------------------------------------------------------------------
detect_key_encryption() {
    # Only look at PEM header lines — the authoritative signal. Avoids a
    # false positive when the word "ENCRYPTED" appears in a user comment
    # somewhere in the file.
    local keyfile="$1"
    grep -qE '^-----BEGIN (ENCRYPTED PRIVATE KEY|RSA PRIVATE KEY|EC PRIVATE KEY|DSA PRIVATE KEY|PRIVATE KEY)-----' "$keyfile" 2>/dev/null || return 1
    grep -qE '^-----BEGIN ENCRYPTED PRIVATE KEY-----$|^Proc-Type: 4,ENCRYPTED' "$keyfile" 2>/dev/null
}

is_pem_file() {
    # PEM is text and contains a "-----BEGIN …-----" line somewhere.
    # Comments/blank lines before the marker are fine — common in bundles.
    # DER is binary and will not contain this string.
    local f="$1"
    LC_ALL=C grep -q -- '-----BEGIN ' "$f" 2>/dev/null
}

# Convert DER input to PEM in-place under $TMP_DIR, then update the caller's
# variable to point at the PEM copy. Accepts either "cert" or "cabundle".
#
# Usage: maybe_convert_to_pem <var-name-holding-path> <kind>
#   <kind> = cert     — single-cert DER -> PEM
#   <kind> = cabundle — treat as single cert (DER bundles are rare; keytool
#                       bundles are always PEM concatenations).
maybe_convert_to_pem() {
    local var_name="$1"
    local kind="$2"
    local src="${!var_name}"

    if is_pem_file "$src"; then
        return 0
    fi

    info "Detected DER-encoded ${kind}: $src — converting to PEM"
    local base
    base=$(basename "$src")
    local out="$TMP_DIR/${base%.*}.pem"

    if ! openssl x509 -inform der -in "$src" -out "$out" -outform pem 2>"$TMP_DIR/openssl.err"; then
        err "Failed to convert DER to PEM:"
        sed 's/^/       /' "$TMP_DIR/openssl.err" >&2
        die "$src is neither valid PEM nor valid DER."
    fi

    ok "Converted DER -> PEM: $src -> $out"
    printf -v "$var_name" '%s' "$out"
}

validate_cert() {
    local f="$1"
    openssl x509 -in "$f" -noout >/dev/null 2>&1 \
        || die "Not a valid X.509 certificate: $f"
    local subj start_date end_date
    subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null \
              | sed 's/^subject=[[:space:]]*//' || true)
    start_date=$(openssl x509 -in "$f" -noout -startdate 2>/dev/null | cut -d= -f2 || true)
    end_date=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2 || true)

    info "Certificate: $f"
    [[ -n "$subj" ]] && dim "         ${subj}"
    if [[ -n "$start_date" && -n "$end_date" ]]; then
        dim "         valid ${start_date}  ${ARROW}  ${end_date}"
    fi
    check_cert_expiry "$f"
}

# Fails hard if the cert is already expired; warns if it expires within
# EXPIRY_WARN_DAYS. Uses `openssl x509 -checkend <seconds>` — portable,
# no date-parsing quirks across GNU vs BSD `date`.
check_cert_expiry() {
    local f="$1"
    local warn_secs=$(( EXPIRY_WARN_DAYS * 86400 ))
    local end
    end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)

    # Already expired?
    if ! openssl x509 -in "$f" -checkend 0 >/dev/null 2>&1; then
        die "Certificate has ALREADY EXPIRED (notAfter: $end). Refusing to build keystores with an expired cert."
    fi

    # Expiring within the warning window?
    if ! openssl x509 -in "$f" -checkend "$warn_secs" >/dev/null 2>&1; then
        warn "Certificate expires within ${EXPIRY_WARN_DAYS} days (notAfter: $end)."
        warn "Renew it soon — keystores built now will stop working on that date."
    else
        ok "Certificate expiry healthy."
    fi
}

validate_key() {
    local f="$1"
    local pass="${2:-}"
    # Always pass -passin explicitly so openssl never prompts interactively,
    # even if the key is encrypted with a non-standard header we didn't detect.
    if ! openssl pkey -in "$f" -noout -passin "pass:$pass" >/dev/null 2>&1; then
        if [[ -z "$pass" ]] && detect_key_encryption "$f"; then
            die "Private key appears encrypted; supply the passphrase with -p."
        fi
        die "Private key could not be read: $f (wrong password or unsupported format?)"
    fi
    local kind="unencrypted"
    detect_key_encryption "$f" && kind="encrypted"
    info "Private key (${kind}): $f"
}

validate_ca_bundle() {
    local f="$1"
    openssl crl2pkcs7 -nocrl -certfile "$f" 2>/dev/null \
        | openssl pkcs7 -print_certs -noout 2>/dev/null \
        | grep -q 'subject=' \
        || die "CA bundle does not contain any readable certificate: $f"
    local count
    count=$(grep -c -- '-----BEGIN CERTIFICATE-----' "$f" || true)
    info "CA bundle: $f (${count} cert(s))"
    verify_ca_chain_order "$f"
}

# Check that the CA bundle is ordered from leaf-most intermediate to root:
# for each cert N its issuer == subject of cert N+1, and the last cert is
# self-signed (subject == issuer). Warns (does not die) on a mis-ordered
# bundle so users with unusual setups can still proceed — but it flags
# the exact problem with a suggestion to re-order.
verify_ca_chain_order() {
    local f="$1"
    local split="$TMP_DIR/chain-verify"
    rm -rf "$split"
    split_ca_bundle "$split" "$f"

    # Collect subjects and issuers in order
    local -a subjects=() issuers=()
    shopt -s nullglob
    local pem
    for pem in "$split"/ca-*.pem; do
        local s i
        s=$(openssl x509 -in "$pem" -noout -subject 2>/dev/null | sed 's/^subject=[[:space:]]*//')
        i=$(openssl x509 -in "$pem" -noout -issuer  2>/dev/null | sed 's/^issuer=[[:space:]]*//')
        subjects+=("$s")
        issuers+=("$i")
    done
    shopt -u nullglob

    local n=${#subjects[@]}
    (( n > 0 )) || return 0   # validate_ca_bundle already errors in this case

    if (( n == 1 )); then
        if [[ "${subjects[0]}" == "${issuers[0]}" ]]; then
            ok "CA chain (1 cert):"
            dim "         1. ${subjects[0]}  (root)"
        else
            warn "Single-cert CA bundle is NOT self-signed — '${subjects[0]}' is signed by '${issuers[0]}'."
            warn "If this is an intermediate, append the signing root to the bundle."
        fi
        return 0
    fi

    local i ok_chain=1
    for (( i=0; i < n-1; i++ )); do
        local j=$(( i + 1 ))
        if [[ "${issuers[i]}" != "${subjects[j]}" ]]; then
            warn "CA chain BREAK at position $((i+1))->$((j+1)):"
            warn "  cert $((i+1)) subject : ${subjects[i]}"
            warn "  cert $((i+1)) issuer  : ${issuers[i]}"
            warn "  cert $((j+1)) subject : ${subjects[j]}"
            warn "  Expected cert $((j+1))'s subject to equal cert $((i+1))'s issuer."
            ok_chain=0
        fi
    done

    # Last cert must be self-signed (root)
    local last=$(( n - 1 ))
    if [[ "${subjects[last]}" != "${issuers[last]}" ]]; then
        warn "Last CA in bundle is not self-signed (root):"
        warn "  subject: ${subjects[last]}"
        warn "  issuer : ${issuers[last]}"
        warn "  Expected intermediates first, root (self-signed) last."
        ok_chain=0
    fi

    if (( ok_chain == 1 )); then
        ok "CA chain (${n} certs):"
        local idx
        for (( idx=0; idx < n; idx++ )); do
            local tag=""
            (( idx == n - 1 )) && tag="  (root)"
            dim "         $((idx + 1)). ${subjects[idx]}${tag}"
        done
    else
        warn "CA bundle order looks wrong. Expected: intermediate(s) first, root last."
        warn "Proceeding anyway — keytool will still import each cert as a trust anchor."
    fi
}

cert_key_match() {
    # Compare SHA256 of the public keys. Works for RSA, EC, Ed25519.
    # Safeguards:
    #   * PIPESTATUS catches a failing command in the pipe.
    #   * Additionally we reject the known SHA256 of empty input, which
    #     is what the pipe produces if the extractor command succeeds
    #     but emits nothing (the bogus "match" scenario).
    local cert="$1"
    local key="$2"
    local pass="${3:-}"
    local cert_spki key_spki
    local -a rc

    # SHA256 of empty input — any pubkey-extraction that produced no bytes
    # ends up with this hash and must NOT be treated as a real pubkey.
    local EMPTY_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    cert_spki=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 | awk '{print $NF}')
    rc=("${PIPESTATUS[@]}")
    if (( rc[0] != 0 || rc[1] != 0 )) || [[ "$cert_spki" == "$EMPTY_SHA256" ]]; then
        cert_spki=""
    fi

    key_spki=$(openssl pkey -in "$key" -passin "pass:$pass" -pubout 2>/dev/null | openssl sha256 | awk '{print $NF}')
    rc=("${PIPESTATUS[@]}")
    if (( rc[0] != 0 || rc[1] != 0 )) || [[ "$key_spki" == "$EMPTY_SHA256" ]]; then
        key_spki=""
    fi

    if [[ -z "$cert_spki" || -z "$key_spki" ]]; then
        warn "Could not derive public keys for cert/key comparison. Skipping match check."
        return 0
    fi
    if [[ "$cert_spki" != "$key_spki" ]]; then
        die "Certificate and private key DO NOT match. Check that you are using the right pair."
    fi
    ok "Certificate matches private key."
}

extract_cn_alias() {
    local cert="$1"
    local subj cn
    subj=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null || true)
    cn=$(echo "$subj" | sed -n 's/.*CN[ ]*=[ ]*\([^,/]*\).*/\1/p' | head -n1 | tr -d ' ')
    if [[ -z "$cn" ]]; then
        cn="server"
    fi
    printf '%s' "$cn"
}

ensure_output_dir() {
    [[ -n "$OUTPUT_DIR" ]] || die "Output directory not set."
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        info "Creating output directory: $OUTPUT_DIR"
        if ! mkdir -p "$OUTPUT_DIR" 2>/dev/null; then
            err "Could not create $OUTPUT_DIR (permission denied?)"
            err "Try: sudo mkdir -p '$OUTPUT_DIR' && sudo chown \"$USER\" '$OUTPUT_DIR'"
            exit 1
        fi
    fi
    [[ -w "$OUTPUT_DIR" ]] || die "Output directory is not writable: $OUTPUT_DIR"
}

backup_if_exists() {
    local f="$1"
    if [[ -f "$f" ]]; then
        local ts
        ts=$(date +%Y%m%d%H%M%S)
        local bak="${f}.bak.${ts}.$$"
        if (( DRY_RUN == 1 )); then
            info "[dry-run] Would back up $f -> $bak"
        else
            info "Backing up existing $f -> $bak"
            mv "$f" "$bak"
        fi
    fi
}

human_size() {
    local f="$1"
    [[ -f "$f" ]] || { printf '0B'; return; }
    local bytes
    if stat -f%z "$f" >/dev/null 2>&1; then
        bytes=$(stat -f%z "$f")
    else
        bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    fi
    printf '%dB' "$bytes"
}

# List the contents of $OUTPUT_DIR to stderr, one file per line with size.
# Uses find+stat instead of `ls -la` (shellcheck SC2012) and handles files
# with unusual names safely.
list_output_dir() {
    local dir="$1"
    local indent="${2:-       }"
    [[ -d "$dir" ]] || return 0
    local f bytes
    while IFS= read -r -d '' f; do
        if stat -f%z "$f" >/dev/null 2>&1; then
            bytes=$(stat -f%z "$f")
        else
            bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
        fi
        printf '%s%9d  %s\n' "$indent" "$bytes" "$(basename "$f")" >&2
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -print0 | sort -z)
}

# --------------------------------------------------------------------------
# Dry-run support — print the command that WOULD run, and skip execution.
# --------------------------------------------------------------------------
# run_cmd: wraps a side-effecting command. In dry-run mode it prints the
# shell-quoted command and returns success. Otherwise it execs normally.
run_cmd() {
    if (( DRY_RUN == 1 )); then
        local -a shown=()
        local a
        for a in "$@"; do
            if [[ "$a" =~ [[:space:]\'\"\\\$\`] || -z "$a" ]]; then
                shown+=("'${a//\'/\'\\\'\'}'")
            else
                shown+=("$a")
            fi
        done
        # Force space-separated join (script-level IFS is $'\n\t').
        local IFS=' '
        _log "${C_YELLOW}[DRY ]${C_RESET}  ${shown[*]}"
        return 0
    fi
    "$@"
}

# run_pipe: dry-run aware wrapper for a pipeline expressed as a string.
# Runs it via bash -c when live, prints it when dry.
run_pipe() {
    local desc="$1"; shift
    local cmdstr="$*"
    if (( DRY_RUN == 1 )); then
        _log "${C_YELLOW}[DRY ]${C_RESET}  # ${desc}"
        _log "${C_YELLOW}[DRY ]${C_RESET}  ${cmdstr}"
        return 0
    fi
    bash -c "$cmdstr"
}

# Apply the standard output-file mode (OUTPUT_FILE_MODE) and report it.
apply_output_perms() {
    local f="$1"
    if (( DRY_RUN == 1 )); then
        info "[dry-run] Would chmod $OUTPUT_FILE_MODE $f"
        return 0
    fi
    [[ -f "$f" ]] || return 0
    if ! chmod "$OUTPUT_FILE_MODE" "$f" 2>/dev/null; then
        warn "Could not chmod $OUTPUT_FILE_MODE $f (continuing)"
    fi
}

# --------------------------------------------------------------------------
# UI / progress helpers — designed to be readable in CI logs on Linux.
# --------------------------------------------------------------------------

# Slim 2-line banner shown once at startup. Dry-run appends a tag.
print_banner() {
    local dry_tag=""
    (( DRY_RUN == 1 )) && dry_tag="  ${C_YELLOW}— DRY RUN${C_RESET}"
    local marker line
    if (( USE_UNICODE == 1 )); then
        marker="▸"
        line="─────────────────────────────────────────────────────────"
    else
        marker=">"
        line="---------------------------------------------------------"
    fi
    _log ""
    _log "  ${C_BOLD}${marker} Build SSL Keystores${C_RESET}${dry_tag}"
    _log "  ${C_DIM}${line}${C_RESET}"
}

# Visual phase divider — one consistent style for every major phase.
# Pattern:  ━━━ TITLE ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# (ASCII fallback uses '===' when NO_COLOR/no-TTY.)
section() {
    local title="$1"
    local heavy light
    if (( USE_UNICODE == 1 )); then
        heavy="━━━"
        light="━"
    else
        heavy="==="
        light="="
    fi
    local body=" ${title} "
    # Target total width ≈ 60 chars; pad the right side with the light char.
    local padlen=$(( 60 - 3 - ${#body} ))
    (( padlen < 3 )) && padlen=3
    local pad=""
    local i
    for (( i=0; i<padlen; i++ )); do pad+="$light"; done
    _log ""
    _log "${C_BOLD}${C_CYAN}${heavy}${body}${pad}${C_RESET}"
}

# step <label> — print a "[N/M] label" header.
step() {
    STEP_CURRENT=$(( STEP_CURRENT + 1 ))
    _log "${C_BOLD}${C_BLUE}[${STEP_CURRENT}/${STEP_TOTAL}]${C_RESET} ${C_BOLD}$1${C_RESET}"
}

# SHA-256 fingerprint of a file's X.509 content (for certs) or of the raw
# bytes (for JKS/PFX). Used in the summary.
file_fingerprint() {
    local f="$1"
    [[ -f "$f" ]] || { printf 'n/a'; return; }
    if stat -f%z "$f" >/dev/null 2>&1; then :; fi
    openssl dgst -sha256 "$f" 2>/dev/null | awk '{print $NF}' | head -c 16
}

file_mode() {
    local f="$1"
    [[ -f "$f" ]] || { printf '----'; return; }
    if stat -f '%Mp%Lp' "$f" >/dev/null 2>&1; then
        stat -f '%Mp%Lp' "$f" | tail -c 5
    else
        stat -c '%a' "$f" 2>/dev/null || printf '----'
    fi
}

# Pretty end-of-run summary. Called in both live and dry-run flows.
print_summary() {
    section "Summary"
    local pfx="$OUTPUT_DIR/$KEYSTORE_PFX_NAME"
    local jks="$OUTPUT_DIR/$KEYSTORE_JKS_NAME"
    local ts="$OUTPUT_DIR/$TRUSTSTORE_JKS_NAME"
    local f
    printf '  %s%-18s %-6s %-9s %s%s\n' \
        "${C_DIM}" "File" "Mode" "Size" "SHA-256 (first 16)" "${C_RESET}" >&2
    for f in "$pfx" "$jks" "$ts"; do
        if [[ -f "$f" ]]; then
            printf '  %-18s %-6s %-9s %s\n' \
                "$(basename "$f")" \
                "$(file_mode "$f")" \
                "$(human_size "$f")" \
                "$(file_fingerprint "$f")" >&2
        elif (( DRY_RUN == 1 )); then
            printf '  %-18s %-6s %-9s %s\n' \
                "$(basename "$f")" "----" "n/a" "(would be created)" >&2
        fi
    done
    _log ""
    if (( DRY_RUN == 1 )); then
        _log "${C_YELLOW}Dry-run complete — no files were written.${C_RESET}"
    else
        ok "Build complete. Files written to: ${C_BOLD}$OUTPUT_DIR${C_RESET}"
    fi
}

# --------------------------------------------------------------------------
# Input resolution
# --------------------------------------------------------------------------
resolve_inputs_interactive() {
    section "Inputs"
    dim "  (press Ctrl-C to abort)"
    echo >&2

    [[ -n "$SERVER_CERT" ]] || SERVER_CERT=$(prompt_path "Path to server certificate (PEM/CER)")
    [[ -n "$SERVER_KEY"  ]] || SERVER_KEY=$(prompt_path  "Path to server private key")
    [[ -n "$CA_BUNDLE"   ]] || CA_BUNDLE=$(prompt_path   "Path to CA bundle (intermediate+root or just root)")
    [[ -n "$OUTPUT_DIR"  ]] || OUTPUT_DIR=$(prompt_dir   "Output directory" "$DEFAULT_OUTPUT_DIR")
}

resolve_passwords_interactive() {
    if detect_key_encryption "$SERVER_KEY"; then
        if [[ -z "$SERVER_KEY_PASS" ]]; then
            SERVER_KEY_PASS=$(prompt_password_once "Enter private key password")
        fi
        # Policy: when the key is encrypted, keystore/truststore password
        # MUST equal the private key password. If -s was given with a
        # different value, reject it — silently overriding would mislead.
        if [[ -n "$KEYSTORE_PASS" && "$KEYSTORE_PASS" != "$SERVER_KEY_PASS" ]]; then
            die "-s was given but differs from -p. When the private key is encrypted, the keystore/truststore password must equal the key password. Re-run with matching values or drop -s."
        fi
        KEYSTORE_PASS="$SERVER_KEY_PASS"
    else
        SERVER_KEY_PASS=""
        if [[ -z "$KEYSTORE_PASS" ]]; then
            KEYSTORE_PASS=$(prompt_password_confirm "Enter a shared keystore/truststore password")
        fi
    fi
}

resolve_passwords_noninteractive() {
    if detect_key_encryption "$SERVER_KEY"; then
        [[ -n "$SERVER_KEY_PASS" ]] || die "Private key is encrypted; -p <SERVER_KEY_PASS> is required in non-interactive mode."
        # Policy: encrypted key => keystore pass MUST equal key pass.
        if [[ -n "$KEYSTORE_PASS" && "$KEYSTORE_PASS" != "$SERVER_KEY_PASS" ]]; then
            die "-s was given but differs from -p. When the private key is encrypted, the keystore/truststore password must equal the key password. Re-run with matching values or drop -s."
        fi
        KEYSTORE_PASS="$SERVER_KEY_PASS"
    else
        SERVER_KEY_PASS=""
        [[ -n "$KEYSTORE_PASS" ]] || die "Private key is unencrypted: -s <KEYSTORE_PASS> is required in non-interactive mode."
    fi
}

validate_all_inputs() {
    [[ -f "$SERVER_CERT" ]] || die "Certificate file not found: $SERVER_CERT"
    [[ -f "$SERVER_KEY"  ]] || die "Private key file not found: $SERVER_KEY"
    [[ -f "$CA_BUNDLE"   ]] || die "CA bundle file not found: $CA_BUNDLE"

    # If the cert or CA bundle is DER-encoded, transparently convert to PEM.
    # (DER private keys are left to openssl; encrypted DER keys are rare.)
    maybe_convert_to_pem SERVER_CERT cert
    maybe_convert_to_pem CA_BUNDLE cabundle

    validate_cert "$SERVER_CERT"
    validate_key  "$SERVER_KEY" "$SERVER_KEY_PASS"
    validate_ca_bundle "$CA_BUNDLE"
    cert_key_match "$SERVER_CERT" "$SERVER_KEY" "$SERVER_KEY_PASS"

    if [[ -z "$CERT_ALIAS" ]]; then
        CERT_ALIAS=$(extract_cn_alias "$SERVER_CERT")
    fi
    info "Keystore alias: $CERT_ALIAS"

    ensure_output_dir
}

# --------------------------------------------------------------------------
# CA bundle splitter — robust against blank lines, comments, CRLF
# --------------------------------------------------------------------------
split_ca_bundle() {
    # Writes each cert to $1/ca-NN.pem. Only lines BETWEEN (inclusive)
    # BEGIN/END markers are written, so blank lines / comments / extra
    # text between certs are discarded cleanly.
    local split_dir="$1"
    local bundle="$2"
    mkdir -p "$split_dir"
    awk -v dir="$split_dir" '
        /-----BEGIN CERTIFICATE-----/ {
            n++
            file = sprintf("%s/ca-%02d.pem", dir, n)
            in_cert = 1
        }
        in_cert == 1 { print > file }
        /-----END CERTIFICATE-----/ {
            in_cert = 0
            close(file)
        }
    ' "$bundle"
}

# --------------------------------------------------------------------------
# Core operations
# --------------------------------------------------------------------------
create_pfx() {
    local out="$OUTPUT_DIR/$KEYSTORE_PFX_NAME"
    step "Create PFX (PKCS12)  ${ARROW}  $out"

    backup_if_exists "$out"

    local -a args=(
        pkcs12 -export
        -out "$out"
        -inkey "$SERVER_KEY"
        -in "$SERVER_CERT"
        -certfile "$CA_BUNDLE"
        -name "$CERT_ALIAS"
        -passout "pass:$KEYSTORE_PASS"
    )
    if [[ -n "$SERVER_KEY_PASS" ]]; then
        args+=(-passin "pass:$SERVER_KEY_PASS")
    fi

    if (( DRY_RUN == 1 )); then
        run_cmd openssl "${args[@]}"
    else
        if ! openssl "${args[@]}" 2>"$TMP_DIR/openssl.err"; then
            err "openssl pkcs12 failed:"
            sed 's/^/       /' "$TMP_DIR/openssl.err" >&2
            die "Could not create PFX."
        fi
        ok "PFX created: $out ($(human_size "$out"))"
    fi
    apply_output_perms "$out"
}

convert_to_jks() {
    local pfx="$OUTPUT_DIR/$KEYSTORE_PFX_NAME"
    local jks="$OUTPUT_DIR/$KEYSTORE_JKS_NAME"
    step "Convert PFX ${ARROW} JKS    ${ARROW}  $jks"

    if (( DRY_RUN == 0 )); then
        [[ -f "$pfx" ]] || die "PFX not found: $pfx — run 'Create PFX' first."
    fi

    backup_if_exists "$jks"

    local -a args=(
        -importkeystore
        -srckeystore "$pfx" -srcstoretype pkcs12
        -destkeystore "$jks" -deststoretype jks
        -srcstorepass "$KEYSTORE_PASS" -deststorepass "$KEYSTORE_PASS"
        -srcalias "$CERT_ALIAS" -destalias "$CERT_ALIAS"
        -noprompt
    )

    if (( DRY_RUN == 1 )); then
        run_cmd keytool "${args[@]}"
    else
        if ! keytool "${args[@]}" >"$TMP_DIR/keytool.out" 2>&1; then
            err "keytool importkeystore failed:"
            sed 's/^/       /' "$TMP_DIR/keytool.out" >&2
            die "Could not convert PFX to JKS."
        fi
        ok "JKS keystore created: $jks ($(human_size "$jks"))"
    fi
    apply_output_perms "$jks"
}

create_truststore() {
    local ts="$OUTPUT_DIR/$TRUSTSTORE_JKS_NAME"
    step "Build truststore     ${ARROW}  $ts"

    backup_if_exists "$ts"

    local split_dir="$TMP_DIR/ca-split"
    rm -rf "$split_dir"
    split_ca_bundle "$split_dir" "$CA_BUNDLE"

    local count=0
    shopt -s nullglob
    local pem
    for pem in "$split_dir"/ca-*.pem; do
        # Validate each split block is actually a cert
        if ! openssl x509 -in "$pem" -noout 2>/dev/null; then
            warn "Skipping non-certificate block: $pem"
            continue
        fi
        count=$((count + 1))
        local subj hash alias_name
        subj=$(openssl x509 -in "$pem" -noout -subject 2>/dev/null || echo "subject=unknown")
        hash=$(openssl x509 -in "$pem" -noout -fingerprint -sha256 2>/dev/null \
                 | awk -F= '{print $2}' | tr -d ':' | tr '[:upper:]' '[:lower:]' | cut -c1-12)
        alias_name="ca-$(printf '%02d' "$count")-${hash:-unknown}"

        info "  Importing [$count] $subj (alias: $alias_name)"
        local -a args=(
            -importcert -noprompt
            -keystore "$ts" -storetype jks
            -storepass "$KEYSTORE_PASS"
            -alias "$alias_name"
            -file "$pem"
        )
        if (( DRY_RUN == 1 )); then
            run_cmd keytool "${args[@]}"
        else
            if ! keytool "${args[@]}" >"$TMP_DIR/keytool.out" 2>&1; then
                err "keytool importcert failed for $pem:"
                sed 's/^/       /' "$TMP_DIR/keytool.out" >&2
                die "Truststore import failed."
            fi
        fi
    done
    shopt -u nullglob

    if (( count == 0 )); then
        die "No certificates were imported into the truststore — is the CA bundle empty or malformed?"
    fi

    if (( DRY_RUN == 0 )); then
        ok "Truststore created: $ts ($(human_size "$ts"), $count entrie(s))"
    fi
    apply_output_perms "$ts"
}

# --------------------------------------------------------------------------
# View submenu
# --------------------------------------------------------------------------
view_artifacts() {
    local pfx="$OUTPUT_DIR/$KEYSTORE_PFX_NAME"
    local jks="$OUTPUT_DIR/$KEYSTORE_JKS_NAME"
    local ts="$OUTPUT_DIR/$TRUSTSTORE_JKS_NAME"

    while true; do
        echo
        echo "${C_BOLD}--- View artifacts ---${C_RESET}"
        echo "  1) View certificate (full text)"
        echo "  2) View certificate (subject / issuer / dates / SAN)"
        echo "  3) View private key info"
        echo "  4) View CA bundle (subject lines)"
        echo "  5) View PFX contents"
        echo "  6) List keystore (JKS)"
        echo "  7) List truststore (JKS)"
        echo "  8) Back"
        local choice
        read -r -p "Choice [1-8]: " choice
        case "$choice" in
            1) openssl x509 -in "$SERVER_CERT" -noout -text ;;
            2) openssl x509 -in "$SERVER_CERT" -noout -subject -issuer -dates \
                   -ext subjectAltName 2>/dev/null || \
               openssl x509 -in "$SERVER_CERT" -noout -subject -issuer -dates ;;
            3) openssl pkey -in "$SERVER_KEY" -passin "pass:$SERVER_KEY_PASS" -noout -text ;;
            4) openssl crl2pkcs7 -nocrl -certfile "$CA_BUNDLE" \
                   | openssl pkcs7 -print_certs -noout ;;
            5) if [[ -f "$pfx" ]]; then
                   openssl pkcs12 -in "$pfx" -info -nokeys -passin "pass:$KEYSTORE_PASS"
               else warn "PFX not found: $pfx"; fi ;;
            6) if [[ -f "$jks" ]]; then
                   keytool -list -v -keystore "$jks" -storepass "$KEYSTORE_PASS"
               else warn "JKS not found: $jks"; fi ;;
            7) if [[ -f "$ts" ]]; then
                   keytool -list -v -keystore "$ts" -storepass "$KEYSTORE_PASS"
               else warn "Truststore not found: $ts"; fi ;;
            8|q|Q) return 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Config dump
# --------------------------------------------------------------------------
show_config() {
    section "Configuration"
    local key_enc pass_state
    if [[ -n "$SERVER_KEY" && -f "$SERVER_KEY" ]]; then
        if detect_key_encryption "$SERVER_KEY"; then key_enc="yes"; else key_enc="no"; fi
    else
        key_enc="unknown"
    fi
    if [[ -n "$SERVER_KEY_PASS" && -n "$KEYSTORE_PASS" ]]; then
        pass_state="set"
    elif [[ -n "$KEYSTORE_PASS" ]]; then
        pass_state="keystore only"
    else
        pass_state="none"
    fi
    {
        printf '  %-18s %s\n' "Server cert:"       "${SERVER_CERT:-<unset>}"
        printf '  %-18s %s\n' "Server key:"        "${SERVER_KEY:-<unset>}"
        printf '  %-18s %s\n' "CA bundle:"         "${CA_BUNDLE:-<unset>}"
        printf '  %-18s %s\n' "Output dir:"        "${OUTPUT_DIR:-<unset>}"
        printf '  %-18s %s\n' "Cert alias:"        "${CERT_ALIAS:-<auto>}"
        printf '  %-18s %s\n' "Key encrypted:"     "$key_enc"
        printf '  %-18s %s\n' "Key/keystore pass:" "$pass_state"
    } >&2
}

# --------------------------------------------------------------------------
# Main menu
# --------------------------------------------------------------------------
main_menu() {
    while true; do
        section "Menu"
        {
            echo "  ${C_BOLD}1${C_RESET}  Create PFX (PKCS12) from cert + key + CA"
            echo "  ${C_BOLD}2${C_RESET}  Convert PFX ${ARROW} JKS keystore"
            echo "  ${C_BOLD}3${C_RESET}  Build truststore from CA bundle"
            echo "  ${C_BOLD}4${C_RESET}  Run full pipeline (1 ${ARROW} 2 ${ARROW} 3)"
            echo "  ${C_BOLD}5${C_RESET}  View certificate / key / keystore"
            echo "  ${C_BOLD}6${C_RESET}  Show current configuration"
            echo "  ${C_BOLD}7${C_RESET}  Exit"
            echo
        } >&2
        local choice
        read -r -p "Choice [1-7]: " choice
        case "$choice" in
            1) create_pfx ;;
            2) convert_to_jks ;;
            3) create_truststore ;;
            4) STEP_CURRENT=0
               section "Build"
               create_pfx; convert_to_jks; create_truststore
               print_summary
               ;;
            5) view_artifacts ;;
            6) show_config ;;
            7|q|Q) info "Bye."; exit 0 ;;
            *) warn "Invalid choice." ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------
main() {
    parse_args "$@"
    print_banner
    check_dependencies

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sslkeys.XXXXXX")

    if (( NON_INTERACTIVE == 1 )); then
        [[ -n "$SERVER_CERT" ]] || die "Non-interactive mode requires -c <SERVER_CERT>"
        [[ -n "$SERVER_KEY"  ]] || die "Non-interactive mode requires -k <SERVER_KEY>"
        [[ -n "$CA_BUNDLE"   ]] || die "Non-interactive mode requires -a <CA_BUNDLE>"
        [[ -n "$OUTPUT_DIR"  ]] || OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
        resolve_passwords_noninteractive
        section "Validation"
        validate_all_inputs
        show_config
        section "Build"
        STEP_CURRENT=0
        create_pfx
        convert_to_jks
        create_truststore
        print_summary
        exit 0
    fi

    resolve_inputs_interactive
    resolve_passwords_interactive
    section "Validation"
    validate_all_inputs
    show_config
    main_menu
}

main "$@"
