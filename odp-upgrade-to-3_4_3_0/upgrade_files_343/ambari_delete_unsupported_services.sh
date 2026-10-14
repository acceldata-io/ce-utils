#!/bin/bash
# Ambari unsupported service removal
#
# Stops, backs up, and deletes services that are no longer supported:
#   KAFKA, DRUID, OOZIE, SPARK2, SQOOP, ZEPPELIN
#
# KAFKA3 is not touched. Only the legacy KAFKA service is removed.
#
# Flow matches ambari_delete_mpack_service.sh:
#   list installed targets -> confirm -> STOP -> BACKUP configs -> DELETE
#
# Backup layout (same as config_backup_restore.sh / configs.py):
#   <BACKUP_DIR>/<config-type>/<config-type>.json
#   <BACKUP_DIR>/_services/<SERVICE>_<timestamp>/
#
# Usage:
#   bash ambari_delete_unsupported_services.sh
#   bash ambari_delete_unsupported_services.sh --list
#   bash ambari_delete_unsupported_services.sh --yes
#   bash ambari_delete_unsupported_services.sh --skip-backup
#
# Environment overrides:
#   AMBARISERVER, AMBARI_USER, AMBARI_PASSWORD, PORT, PROTOCOL,
#   BACKUP_DIR (default ./upgrade_backup),
#   PYTHON_BIN (default: first of python3 / python / python2 found),
#   STOP_TIMEOUT (seconds to wait for the stop request, default 900)
#
# NOTE:
# - Deleting a service removes its components, host components, and config
#   history from Ambari. Packages on the hosts are not uninstalled.
# - Ambari refuses to delete a service that others depend on. The API error
#   is printed as-is so the dependency can be resolved first.
# - Ambari masks password properties as "SECRET:<type>:<version>:<key>".
#   Those references are removed with the service, so passwords cannot be
#   recovered from the backup.

set -o pipefail

UNSUPPORTED_SERVICES=(KAFKA DRUID OOZIE SPARK2 SQOOP ZEPPELIN)

AMBARISERVER="${AMBARISERVER:-$(hostname -f)}"
AMBARI_USER="${AMBARI_USER:-admin}"
AMBARI_PASSWORD="${AMBARI_PASSWORD:-admin}"
PORT="${PORT:-8080}"
PROTOCOL="${PROTOCOL:-http}"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/upgrade_backup}"
STOP_TIMEOUT="${STOP_TIMEOUT:-900}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python || command -v python2)}"

BASE_URL="$PROTOCOL://$AMBARISERVER:$PORT/api/v1"
CURL=(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H "X-Requested-By: ambari")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

LIST_ONLY=false
ASSUME_YES=false
SKIP_BACKUP=false
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --skip-backup) SKIP_BACKUP=true ;;
        -h|--help)
            sed -n '2,/^set -o pipefail/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
    shift
done

json_values() {
    grep -o "\"$1\" *: *\"[^\"]*\"" | sed 's/.*: *"//; s/"$//'
}

api_get() { "${CURL[@]}" -X GET "$BASE_URL$1"; }

echo -e "${BOLD}${YELLOW}+------------------------------------------------------------+${NC}"
echo -e "${BOLD}${YELLOW}|${NC} ${BOLD}${CYAN}Ambari unsupported service removal${NC}                         ${BOLD}${YELLOW}|${NC}"
echo -e "${BOLD}${YELLOW}|${NC} Targets: KAFKA, DRUID, OOZIE, SPARK2, SQOOP, ZEPPELIN.  ${BOLD}${YELLOW}|${NC}"
echo -e "${BOLD}${YELLOW}+------------------------------------------------------------+${NC}"
printf "   %-18s : %s\n" "AMBARISERVER" "$AMBARISERVER"
printf "   %-18s : %s\n" "AMBARI_USER" "$AMBARI_USER"
printf "   %-18s : ********\n" "AMBARI_PASSWORD"
printf "   %-18s : %s\n" "PORT" "$PORT"
printf "   %-18s : %s\n" "PROTOCOL" "$PROTOCOL"
printf "   %-18s : %s\n" "BACKUP_DIR" "$BACKUP_DIR"
printf "   %-18s : %s\n" "PYTHON_BIN" "${PYTHON_BIN:-<not found>}"
echo ""

if [ "$SKIP_BACKUP" != true ] && [ "$LIST_ONLY" != true ] && [ -z "$PYTHON_BIN" ]; then
    error "No python interpreter found; it is required to write config backups."
    error "Install python3 or re-run with --skip-backup."
    exit 1
fi

clusters_json=$(api_get "/clusters")
CLUSTER=$(echo "$clusters_json" | json_values cluster_name | head -n1)
if [ -z "$CLUSTER" ]; then
    error "Unable to retrieve cluster name from Ambari at $BASE_URL"
    echo "$clusters_json" | head -c 500; echo
    exit 1
fi
info "Cluster identified : ${BOLD}$CLUSTER${NC}"

declare -A INSTALLED_STATE
while read -r svc state; do
    [ -n "$svc" ] || continue
    INSTALLED_STATE["$svc"]="$state"
done < <(api_get "/clusters/$CLUSTER/services?fields=ServiceInfo/state" \
    | tr -d '\n' | grep -o '"ServiceInfo" *: *{[^}]*}' \
    | sed 's/.*"service_name" *: *"\([^"]*\)".*"state" *: *"\([^"]*\)".*/\1 \2/')

if [ ${#INSTALLED_STATE[@]} -eq 0 ]; then
    error "No services found in cluster $CLUSTER."
    exit 1
fi

echo ""
echo -e "${BOLD}Unsupported services in '$CLUSTER':${NC}"
printf "   %-4s %-20s %-14s %s\n" "#" "SERVICE" "STATE" "ACTION"
printf "   %-4s %-20s %-14s %s\n" "---" "--------------------" "--------------" "------"

SELECTED=()
n=0
for svc in "${UNSUPPORTED_SERVICES[@]}"; do
    n=$((n+1))
    state="${INSTALLED_STATE[$svc]:-}"
    if [ -n "$state" ]; then
        printf "   %-4s %-20s %-14s %s\n" "$n" "$svc" "$state" "STOP then DELETE"
        SELECTED+=("$svc")
    else
        printf "   %-4s %-20s %-14s %s\n" "$n" "$svc" "-" "not installed"
    fi
done
echo ""

[ "$LIST_ONLY" = true ] && exit 0

if [ ${#SELECTED[@]} -eq 0 ]; then
    info "None of the unsupported services are installed. Nothing to do."
    exit 0
fi

if [ "$SKIP_BACKUP" = true ]; then
    echo -e "${BOLD}The following service(s) will be STOPPED and DELETED from cluster '$CLUSTER' ${RED}(NO config backup)${NC}:"
else
    echo -e "${BOLD}The following service(s) will be STOPPED, their configs BACKED UP to $BACKUP_DIR, then DELETED from cluster '$CLUSTER':${NC}"
fi
for s in "${SELECTED[@]}"; do
    echo "   - $s  [${INSTALLED_STATE[$s]}]"
done
echo ""
echo "KAFKA3, and every service not in the list above, is left in place."
echo ""

if [ "$ASSUME_YES" != true ]; then
    read -r -p "Type DELETE to stop and delete these services: " confirm
    [ "$confirm" = "DELETE" ] || { echo "Aborted."; exit 0; }
fi

wait_for_request() {
    local req_id="$1" waited=0 status progress
    while [ "$waited" -lt "$STOP_TIMEOUT" ]; do
        out=$(api_get "/clusters/$CLUSTER/requests/$req_id?fields=Requests/request_status,Requests/progress_percent")
        status=$(echo "$out" | json_values request_status | head -n1)
        progress=$(echo "$out" | grep -o '"progress_percent" *: *[0-9.]*' | sed 's/.*: *//')
        printf "\r   request %s: %-12s %s%%   " "$req_id" "$status" "${progress%.*}"
        case "$status" in
            COMPLETED) echo; return 0 ;;
            FAILED|ABORTED|TIMEDOUT) echo; return 1 ;;
        esac
        sleep 5; waited=$((waited+5))
    done
    echo
    error "Timed out after ${STOP_TIMEOUT}s waiting for request $req_id."
    return 1
}

# Ambari DELETE rejects a service while any host component is STARTED,
# STARTING, or STOPPING. Desired state INSTALLED is not enough: a service
# PUT then returns HTTP 200 and does not stop a component that is still STARTED.
component_is_removable() {
    case "$1" in
        INIT|INSTALLING|INSTALLED|INSTALL_FAILED|UNINSTALLED|UNKNOWN|DISABLED) return 0 ;;
        *) return 1 ;;
    esac
}

list_host_components() {
    local svc="$1"
    [ -n "$PYTHON_BIN" ] || { error "python is required to read host component states."; return 1; }
    api_get "/clusters/$CLUSTER/services/$svc/components?fields=host_components/HostRoles/host_name,host_components/HostRoles/component_name,host_components/HostRoles/state" \
        | "$PYTHON_BIN" -c '
import json, sys
data = json.load(sys.stdin)
for comp in data.get("items", []):
    for hc in comp.get("host_components", []):
        h = hc.get("HostRoles", {})
        print("%s %s %s" % (h.get("component_name", ""), h.get("host_name", ""), h.get("state", "")))
'
}

stop_one_request() {
    local http_code resp req_id
    resp=$("${CURL[@]}" -w '\n%{http_code}' -X PUT -d "$1" "$2")
    http_code=$(echo "$resp" | tail -n1)
    resp=$(echo "$resp" | sed '$d')
    case "$http_code" in
        200) return 0 ;;
        202)
            req_id=$(echo "$resp" | grep -o '"id" *: *[0-9]*' | head -n1 | sed 's/.*: *//')
            [ -n "$req_id" ] || { error "Could not read request id from response: $resp"; return 1; }
            wait_for_request "$req_id" ;;
        *)
            error "Stop request returned HTTP $http_code:"
            echo "$resp" | head -c 800; echo
            return 1 ;;
    esac
}

stop_host_component() {
    local svc="$1" comp="$2" host="$3"
    stop_one_request \
        '{"RequestInfo":{"context":"Stop '"$comp"' on '"$host"' (unsupported service removal)","operation_level":{"level":"HOST_COMPONENT","cluster_name":"'"$CLUSTER"'","host_name":"'"$host"'","service_name":"'"$svc"'"}},"Body":{"HostRoles":{"state":"INSTALLED"}}}' \
        "$BASE_URL/clusters/$CLUSTER/hosts/$host/host_components/$comp"
}

ensure_components_removable() {
    local svc="$1" rows comp host state stuck=0
    rows=$(list_host_components "$svc") || return 1
    while read -r comp host state; do
        [ -n "$comp" ] || continue
        component_is_removable "$state" && continue
        info "Stopping $comp on $host (state $state) ..."
        stop_host_component "$svc" "$comp" "$host" || return 1
    done <<< "$rows"

    rows=$(list_host_components "$svc") || return 1
    while read -r comp host state; do
        [ -n "$comp" ] || continue
        if ! component_is_removable "$state"; then
            error "$comp on $host is still $state. Ambari will not delete $svc until that component is INSTALLED."
            stuck=1
        fi
    done <<< "$rows"
    [ "$stuck" -eq 0 ]
}

stop_service() {
    local svc="$1"
    info "Stopping $svc ..."
    stop_one_request \
        '{"RequestInfo":{"context":"Stop '"$svc"' (unsupported service removal)","operation_level":{"level":"SERVICE","cluster_name":"'"$CLUSTER"'","service_name":"'"$svc"'"}},"Body":{"ServiceInfo":{"state":"INSTALLED"}}}' \
        "$BASE_URL/clusters/$CLUSTER/services/$svc" || return 1
    ensure_components_removable "$svc"
}

backup_service() {
    local svc="$1"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local raw_dir="$BACKUP_DIR/_services/${svc}_${ts}"
    mkdir -p "$raw_dir" || { error "Cannot create $raw_dir"; return 1; }

    info "Backing up configurations of $svc ..."

    local scv="$raw_dir/${svc}_service_config_versions.json"
    api_get "/clusters/$CLUSTER/configurations/service_config_versions?service_name=$svc&is_current=true" > "$scv"
    if ! grep -q '"configurations"' "$scv"; then
        error "No current service config version found for $svc. Response:"
        head -c 800 "$scv"; echo
        return 1
    fi

    local pairs
    pairs=$("$PYTHON_BIN" - "$scv" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
items = data.get("items", [])
if not items:
    sys.exit(2)
chosen = None
for it in items:
    if it.get("group_id", -1) == -1:
        chosen = it
        break
if chosen is None:
    chosen = items[0]
for c in chosen.get("configurations", []):
    print("%s %s" % (c["type"], c.get("tag", "")))
PY
    ) || { error "Could not parse service config versions for $svc."; return 1; }

    if [ -z "$pairs" ]; then
        warn "$svc has no configuration types to back up."
    fi

    local cfg_count=0 failed=0
    while read -r ctype ctag; do
        [ -n "$ctype" ] || continue
        local out_dir="$BACKUP_DIR/$ctype"
        mkdir -p "$out_dir"
        local tmp="$raw_dir/${ctype}.raw.json"
        api_get "/clusters/$CLUSTER/configurations?type=$ctype&tag=$ctag" > "$tmp"
        if "$PYTHON_BIN" - "$tmp" "$out_dir/$ctype.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
items = data.get("items", [])
if not items:
    sys.exit(2)
cfg = items[0]
out = {
    "properties": cfg.get("properties", {}) or {},
    "properties_attributes": cfg.get("properties_attributes", {}) or {},
}
with open(sys.argv[2], "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
PY
        then
            printf "   %-45s -> %s\n" "$ctype (tag $ctag)" "$out_dir/$ctype.json"
            cfg_count=$((cfg_count+1))
        else
            error "Failed to back up config type $ctype (tag $ctag) of $svc."
            failed=$((failed+1))
        fi
    done <<< "$pairs"

    api_get "/clusters/$CLUSTER/services/$svc/components?fields=ServiceComponentInfo/state,host_components/HostRoles/host_name,host_components/HostRoles/state" \
        > "$raw_dir/${svc}_host_components.json"
    printf "   %-45s -> %s\n" "component/host layout" "$raw_dir/${svc}_host_components.json"

    local secret_files
    secret_files=$(grep -l '"SECRET:' "$BACKUP_DIR"/*/*.json 2>/dev/null | while read -r f; do
        t=$(basename "$(dirname "$f")")
        echo "$pairs" | awk -v t="$t" '$1==t{print}' | grep -q . && echo "$f"
    done)
    if [ -n "$secret_files" ]; then
        echo ""
        warn "The following password properties of $svc are stored as SECRET references and"
        warn "will NOT be recoverable once the service is deleted. Note their values now"
        warn "(Ambari UI -> $svc -> Configs, or the Ambari DB):"
        for f in $secret_files; do
            grep -o '"[^"]*" *: *"SECRET:[^"]*"' "$f" | sed "s|^|   $(basename "$(dirname "$f")") : |"
        done
        echo ""
        if [ "$ASSUME_YES" != true ]; then
            read -r -p "Have you recorded these passwords? Type 'yes' to continue with $svc: " c
            [ "$c" = "yes" ] || return 1
        fi
    fi

    if [ "$failed" -gt 0 ]; then
        error "$failed config type(s) of $svc could not be backed up."
        return 1
    fi
    echo -e "${GREEN}[OK]${NC}   $svc: $cfg_count config type(s) backed up under $BACKUP_DIR"
    return 0
}

delete_service() {
    local svc="$1"
    if ! ensure_components_removable "$svc"; then
        error "Refusing to delete $svc while a host component is still in a non-removable state."
        return 1
    fi
    info "Deleting $svc ..."
    local resp http_code
    resp=$("${CURL[@]}" -w '\n%{http_code}' -X DELETE "$BASE_URL/clusters/$CLUSTER/services/$svc")
    http_code=$(echo "$resp" | tail -n1)
    resp=$(echo "$resp" | sed '$d')
    if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        echo -e "${GREEN}[OK]${NC}   $svc has been deleted from cluster $CLUSTER."
        return 0
    fi
    error "Delete request for $svc returned HTTP $http_code:"
    echo "$resp" | head -c 800; echo
    return 1
}

FAILED=()
for svc in "${SELECTED[@]}"; do
    echo ""
    echo -e "${BOLD}=== $svc ===${NC}"
    if ! stop_service "$svc"; then
        warn "Stop did not complete cleanly for $svc."
        if [ "$ASSUME_YES" != true ]; then
            read -r -p "Continue with backup and DELETE anyway? (yes/no): " c
            [ "$c" = "yes" ] || { FAILED+=("$svc"); continue; }
        else
            FAILED+=("$svc"); continue
        fi
    fi

    if [ "$SKIP_BACKUP" = true ]; then
        warn "Skipping config backup of $svc (--skip-backup)."
    elif ! backup_service "$svc"; then
        warn "Backup of $svc did not complete."
        if [ "$ASSUME_YES" != true ]; then
            read -r -p "DELETE $svc without a complete backup? (yes/no): " c
            [ "$c" = "yes" ] || { FAILED+=("$svc"); continue; }
        else
            error "Refusing to delete $svc without a complete backup in --yes mode."
            FAILED+=("$svc"); continue
        fi
    fi

    delete_service "$svc" || FAILED+=("$svc")
done

echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
    error "The following service(s) were NOT deleted: ${FAILED[*]}"
    echo "   Check the Ambari API error above (commonly a dependency from another service)."
    exit 1
fi

info "Operation completed."
if [ "$SKIP_BACKUP" != true ]; then
    echo "   Config backups are under $BACKUP_DIR (one <type>/<type>.json per config type)."
fi
echo "   Packages on the hosts were not removed."
