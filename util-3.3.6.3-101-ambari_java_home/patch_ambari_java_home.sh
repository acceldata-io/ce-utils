#!/usr/bin/env bash
#
# ODP-6189: Use Ambari's JDK (ambari_java_home) for CredentialUtil on ODP 3.3 / Ambari Server.
#
# Stack: replace whole .py files from ./files/... (timestamped backup under BACKUP_ROOT).
# Cluster: configs.py get -> extract content -> sed/awk -> merge JSON -> configs.py set.
# After stack *.py changes: restart ambari-agent (and services) so agents drop stale cache — see README.
#
# Run on the Ambari Server (root for stack writes under /var/lib/ambari-server/resources).
#
#   export AMBARI_USER=admin AMBARI_PASSWORD='***'
#   export CLUSTER=name   # optional if API returns a single cluster
#   sudo -E ./patch_ambari_java_home.sh [--no-stack-python] [--no-cluster-config] [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AMBARI_RESOURCES="${AMBARI_RESOURCES:-/var/lib/ambari-server/resources}"
CONFIGS_PY="${CONFIGS_PY:-$AMBARI_RESOURCES/scripts/configs.py}"
# Default interpreter unless the caller exports PYTHON_BIN.
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
CONFIGS_PYTHON_BIN="${CONFIGS_PYTHON_BIN:-$PYTHON_BIN}"
JSON_TOOL="$SCRIPT_DIR/lib/json_content_roundtrip.py"
CLUSTER_TOOL="$SCRIPT_DIR/lib/ambari_cluster_name.py"
SHA256_TOOL="$SCRIPT_DIR/lib/file_sha256.py"

AMBARI_HOST="${AMBARI_HOST:-$(hostname -f)}"
AMBARI_PORT="${AMBARI_PORT-}"
AMBARI_PROTOCOL="${AMBARI_PROTOCOL:-http}"
VERSION_NOTE="${VERSION_NOTE:-ODP-6189 ambari_java_home for CredentialUtil (ce-utils util-3.3.6.3-101)}"
BACKUP_ROOT="${BACKUP_ROOT:-$SCRIPT_DIR/backups}"

STACK_PY_RELS=(
  "stacks/ODP/3.3/services/DRUID/package/scripts/params.py"
  "stacks/ODP/3.3/services/KAFKA/package/scripts/params.py"
  "stacks/ODP/3.3/services/KAFKA/package/scripts/kafka.py"
)

DO_STACK_PYTHON=1
DO_CLUSTER_CONFIG=1
DRY_RUN=0

usage() {
  cat <<'EOF'
Usage: patch_ambari_java_home.sh [options]

  --no-stack-python     Skip copying stack *.py from ./files/
  --no-cluster-config   Skip configs.py get / transform / set
  --dry-run             Stack: cmp only, no copy. Cluster: get+transform but no configs.py set
  -h, --help            This help

Env: AMBARI_USER, AMBARI_PASSWORD, CLUSTER (optional), AMBARI_HOST, AMBARI_PORT (1-65535, default 8080),
     AMBARI_PROTOCOL (http|https), AMBARI_RESOURCES, BACKUP_ROOT, PYTHON_BIN (default python3.11),
     CONFIGS_PYTHON_BIN (defaults to PYTHON_BIN; set e.g. python2 only for configs.py),
     AMBARI_SSL_VERIFY_STRICT (set to 1 with https to omit configs.py --unsafe; default is verify skip for self-signed)
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-stack-python) DO_STACK_PYTHON=0 ;;
    --no-cluster-config) DO_CLUSTER_CONFIG=0 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

log() { echo "[patch-ambari-java-home] $*"; }
die() { echo "[patch-ambari-java-home] ERROR: $*" >&2; exit 1; }

# Trim, validate protocol and API port; default port 8080 when unset or blank.
normalize_ambari_connection() {
  AMBARI_HOST="$(echo -n "${AMBARI_HOST:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -n "$AMBARI_HOST" ]] || die "AMBARI_HOST is empty (set it or fix hostname)."

  AMBARI_PROTOCOL="$(echo -n "${AMBARI_PROTOCOL:-http}" | tr '[:upper:]' '[:lower:]')"
  [[ "$AMBARI_PROTOCOL" == "http" || "$AMBARI_PROTOCOL" == "https" ]] \
    || die "AMBARI_PROTOCOL must be http or https (got: ${AMBARI_PROTOCOL})"

  local p
  p="$(echo -n "${AMBARI_PORT-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$p" ]]; then
    AMBARI_PORT="8080"
  else
    AMBARI_PORT="$p"
    [[ "$AMBARI_PORT" =~ ^[0-9]+$ ]] || die "AMBARI_PORT must be numeric (got: ${p})"
    if ((10#$AMBARI_PORT < 1 || 10#$AMBARI_PORT > 65535)); then
      die "AMBARI_PORT must be 1-65535 or unset for default 8080 (got: ${p})"
    fi
  fi
}

# This util mutates server paths and uses local configs.py; require the Ambari Server node.
require_ambari_server_node() {
  if [[ ! -d /var/lib/ambari-server ]]; then
    die "This host is not the Ambari Server (missing /var/lib/ambari-server). Run this script on the Ambari Server host."
  fi
  if [[ ! -f /etc/ambari-server/conf/ambari.properties ]]; then
    log "WARN: /etc/ambari-server/conf/ambari.properties missing (non-standard install?); continuing."
  fi
}

file_sha256() {
  "$PYTHON_BIN" "$SHA256_TOOL" "$1"
}

need_stack_prereqs() {
  local d="$AMBARI_RESOURCES/stacks/ODP/3.3"
  [[ -d "$d" ]] || die "Missing stack dir: $d (wrong AMBARI_RESOURCES?)"
  if [[ "$DO_STACK_PYTHON" -eq 1 ]]; then
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
      die "Stack file copies need root (sudo), or use --no-stack-python."
    fi
  fi
}

ensure_stack_py_sources() {
  local rel missing=0
  for rel in "${STACK_PY_RELS[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/files/$rel" ]]; then
      log "Missing: files/$rel"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "Add the three patched .py files under $SCRIPT_DIR/files/ (paths in README.md)."
  fi
}

replace_stack_py_files() {
  ensure_stack_py_sources
  local stamp bdir rel src dst
  stamp="$(date +%Y%m%d%H%M%S)"
  bdir="$BACKUP_ROOT/$stamp"
  for rel in "${STACK_PY_RELS[@]}"; do
    src="$SCRIPT_DIR/files/$rel"
    dst="$AMBARI_RESOURCES/$rel"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      if [[ ! -f "$dst" ]]; then
        log "DRY-RUN: target missing: $dst"
      elif cmp -s "$src" "$dst"; then
        log "DRY-RUN: $rel unchanged (matches bundle)"
      else
        log "DRY-RUN: would replace $rel"
      fi
      continue
    fi
    [[ -f "$dst" ]] || die "Target missing on server: $dst"
    mkdir -p "$bdir/$(dirname "$rel")"
    cp -a "$dst" "$bdir/$rel"
    cp -a "$src" "$dst"
    log "Installed $rel (backup: $bdir/$rel)"
  done
  if [[ "$DRY_RUN" -eq 0 ]]; then
    log "Stack Python backups: $bdir"
  fi
}

# CredentialUtil: PATH java -> $AMBARI_JAVA_HOME/bin/java; export AMBARI_JAVA_HOME after JAVA_HOME.
transform_env_content_file() {
  local f="$1" tmp
  tmp="$(mktemp "${f}.tmp.XXXXXX")" || die "mktemp failed for $f"
  sed 's|`java -cp "/var/lib/ambari-agent/cred/lib/\*"|`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*"|g' "$f" >"$tmp" || {
    rm -f "$tmp"
    die "sed failed on $f"
  }
  mv "$tmp" "$f" || {
    rm -f "$tmp"
    die "mv failed for $f"
  }
  if grep -qE '^[[:space:]]*export AMBARI_JAVA_HOME=' "$f"; then
    return 0
  fi
  tmp="$(mktemp "${f}.tmp.XXXXXX")" || die "mktemp failed for $f"
  awk '
    /^[[:space:]]*export JAVA_HOME=/ && !done {
      print
      match($0, /^[[:space:]]*/)
      indent = substr($0, 1, RLENGTH)
      print indent "export AMBARI_JAVA_HOME={{ambari_java_home}}"
      done = 1
      next
    }
    { print }
  ' "$f" >"$tmp" || {
    rm -f "$tmp"
    die "awk failed on $f"
  }
  mv "$tmp" "$f" || {
    rm -f "$tmp"
    die "mv failed for $f"
  }
}

# Autodiscover cluster via lib/ambari_cluster_name.py (urllib + JSON).
detect_cluster_name() {
  if [[ -n "${CLUSTER:-}" ]]; then
    echo -n "${CLUSTER}" | tr -d '\r\n'
    return 0
  fi
  if [[ -z "${AMBARI_USER:-}" || -z "${AMBARI_PASSWORD:-}" ]]; then
    return 1
  fi
  [[ -f "$CLUSTER_TOOL" ]] || die "Missing $CLUSTER_TOOL"
  local insecure=() err_tmp rc out multi
  [[ "${AMBARI_PROTOCOL}" == "https" ]] && insecure=(--insecure)
  err_tmp="$(mktemp "${TMPDIR:-/tmp}/amb-cn-err.XXXXXX")"
  set +e
  out="$("$PYTHON_BIN" "$CLUSTER_TOOL" \
    --host "$AMBARI_HOST" --port "$AMBARI_PORT" --protocol "$AMBARI_PROTOCOL" \
    --user "$AMBARI_USER" --password "$AMBARI_PASSWORD" "${insecure[@]}" 2>"$err_tmp")"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    rm -f "$err_tmp"
    echo -n "$out"
    return 0
  fi
  if [[ "$rc" -eq 2 ]]; then
    multi="$(cat "$err_tmp" 2>/dev/null || true)"
    rm -f "$err_tmp"
    die "Several Ambari clusters found; set CLUSTER to one of: ${multi}"
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do log "$line"; done <"$err_tmp"
  rm -f "$err_tmp"
  return 1
}

patch_cluster_config_type() {
  local config_type="$1"
  local work="$2"
  local raw="${work}/${config_type}.raw.json"
  local new="${work}/${config_type}.new.json"
  local content="${work}/${config_type}.content.sh"

  log "configs.py get: ${config_type}"
  local ssl_flag=()
  if [[ "${AMBARI_PROTOCOL}" == "https" ]]; then
    ssl_flag=(-s https)
    [[ "${AMBARI_SSL_VERIFY_STRICT:-0}" == "1" ]] || ssl_flag+=(--unsafe)
  fi

  local err
  err="$("$CONFIGS_PYTHON_BIN" "$CONFIGS_PY" \
    -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" "${ssl_flag[@]}" -a get -t "$AMBARI_PORT" \
    -l "$AMBARI_HOST" -n "$CLUSTER" -c "$config_type" -f "$raw" 2>&1)" || {
    if echo "$err" | grep -qiE 'not found|missing'; then
      log "Config type ${config_type} not present; skip."
      return 0
    fi
    die "configs.py get failed (${config_type}): $err"
  }

  "$PYTHON_BIN" "$JSON_TOOL" extract "$raw" "$content" || die "extract content failed (${config_type})"

  local before after
  before="$(file_sha256 "$content")"
  transform_env_content_file "$content"
  after="$(file_sha256 "$content")"

  if [[ "$before" == "$after" ]]; then
    log "${config_type}: content unchanged; skip set."
    return 0
  fi

  "$PYTHON_BIN" "$JSON_TOOL" merge "$raw" "$content" "$new" || die "merge failed (${config_type})"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY-RUN: would configs.py set ${config_type}"
    return 0
  fi

  log "configs.py set: ${config_type}"
  err="$("$CONFIGS_PYTHON_BIN" "$CONFIGS_PY" \
    -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" "${ssl_flag[@]}" -a set -t "$AMBARI_PORT" \
    -l "$AMBARI_HOST" -n "$CLUSTER" -c "$config_type" -f "$new" \
    -b "$VERSION_NOTE" 2>&1)" || die "configs.py set failed (${config_type}): $err"
  log "Updated ${config_type}."
}

main() {
  if [[ "$DO_STACK_PYTHON" -eq 1 || "$DO_CLUSTER_CONFIG" -eq 1 ]]; then
    require_ambari_server_node
  fi

  normalize_ambari_connection
  log "Ambari API: ${AMBARI_PROTOCOL}://${AMBARI_HOST}:${AMBARI_PORT}"
  if [[ "${AMBARI_PROTOCOL}" == "https" ]] && [[ "${AMBARI_SSL_VERIFY_STRICT:-0}" != "1" ]]; then
    log "configs.py will use --unsafe for HTTPS (urllib cert verify off). Export AMBARI_SSL_VERIFY_STRICT=1 to enforce verification."
  fi

  need_stack_prereqs

  if [[ "$DO_CLUSTER_CONFIG" -eq 1 ]]; then
    [[ -f "$CONFIGS_PY" ]] || die "Missing $CONFIGS_PY"
    [[ -f "$JSON_TOOL" ]] || die "Missing $JSON_TOOL"
    [[ -f "$CLUSTER_TOOL" ]] || die "Missing $CLUSTER_TOOL"
    [[ -f "$SHA256_TOOL" ]] || die "Missing $SHA256_TOOL"
  fi

  if [[ "$DO_STACK_PYTHON" -eq 1 ]]; then
    log "Stack Python: copy from files/ -> $AMBARI_RESOURCES (BACKUP_ROOT=$BACKUP_ROOT)"
    replace_stack_py_files
  fi

  if [[ "$DO_CLUSTER_CONFIG" -eq 1 ]]; then
    [[ -n "${AMBARI_USER:-}" ]] || die "Set AMBARI_USER (and AMBARI_PASSWORD), or use --no-cluster-config."
    [[ -n "${AMBARI_PASSWORD:-}" ]] || die "Set AMBARI_PASSWORD, or use --no-cluster-config."

    CLUSTER="$(detect_cluster_name)" || true
    CLUSTER="$(echo -n "${CLUSTER:-}" | tr -d '\r\n')"
    [[ -n "$CLUSTER" ]] || die "CLUSTER empty: export CLUSTER=... or fix Ambari REST (see messages above; try AMBARI_PROTOCOL=https on TLS ports)."

    # Not local: EXIT trap runs after main() returns; locals would be unset (set -u then errors on $work).
    _JAVA_HOME_PATCH_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ambari-java-home.XXXXXX")"
    trap 'rm -rf "${_JAVA_HOME_PATCH_WORK:-}"' EXIT

    patch_cluster_config_type "kafka-env" "$_JAVA_HOME_PATCH_WORK"
    patch_cluster_config_type "cruise-control-env" "$_JAVA_HOME_PATCH_WORK"

    trap - EXIT
    rm -rf "${_JAVA_HOME_PATCH_WORK}"
  fi

  log "Finished. Restart Kafka, Cruise Control, Druid (and other affected) components for new kafka-env / cruise-control-env."
  log "Stack *.py was updated on the server only — restart ambari-agent on hosts that run those services (or all nodes) so agent cache picks up fresh stack scripts; see README.md."
}

main "$@"
