#!/bin/bash
# ┌───────────────────────────────────────────────────────────────────────────┐
# │ © 2025 Acceldata Inc. All Rights Reserved.                                │
# │                                                                           │
# │ Ambari MPACK Service Removal Tool                                         │
# │                                                                           │
# │ Lists every service installed in the cluster, flags the ones that were    │
# │ installed through an Ambari Management Pack (mpack), lets you pick one or │
# │ more services, then for each one: STOP -> BACKUP configs -> DELETE.       │
# └───────────────────────────────────────────────────────────────────────────┘
#
# Based on: ambari_delete_or_add_service_atsv2.sh and config_backup_restore.sh
#
# Backup layout (same as config_backup_restore.sh / configs.py, so the files can
# be restored with either of them):
#   <BACKUP_DIR>/<config-type>/<config-type>.json      {"properties":..., "properties_attributes":...}
#   <BACKUP_DIR>/_services/<SERVICE>_<timestamp>/      raw service_config_versions + host_components JSON
#
# Run this on the Ambari Server host (mpack detection reads
# /var/lib/ambari-server/resources). If it is run elsewhere, every installed
# service is still listed, but none can be flagged as MPACK.
#
# Usage:
#   bash ambari_delete_mpack_service.sh            # interactive menu
#   bash ambari_delete_mpack_service.sh --list     # only print the table and exit
#   bash ambari_delete_mpack_service.sh --all      # list all services (default: mpack only)
#   bash ambari_delete_mpack_service.sh --yes SPARK3 LIVY3   # non-interactive
#   bash ambari_delete_mpack_service.sh --skip-backup        # do not back up configs
#
# Environment overrides:
#   AMBARISERVER, AMBARI_USER, AMBARI_PASSWORD, PORT, PROTOCOL,
#   AMBARI_RESOURCES (default /var/lib/ambari-server/resources),
#   BACKUP_DIR (default ./upgrade_backup, same as config_backup_restore.sh),
#   PYTHON_BIN (default: first of python3 / python / python2 found),
#   STOP_TIMEOUT (seconds to wait for the stop request, default 900)
#
# NOTE:
# - Deleting a service is irreversible from Ambari's point of view: its
#   components, host components and config history are removed. Packages on
#   the hosts are NOT uninstalled, and the mpack itself stays registered on
#   the Ambari Server (use `ambari-server uninstall-mpack` for that).
# - Ambari refuses to delete a service that others depend on. The API error
#   is printed as-is so you can resolve the dependency first.
# - Ambari masks password properties in the API as "SECRET:<type>:<version>:<key>"
#   references. Those references point at config versions that are removed
#   together with the service, so passwords CANNOT be recovered from the backup.
#   The script lists any such properties and asks you to note them before
#   deleting.

set -o pipefail

# =========================
#  Ambari server settings
# =========================
AMBARISERVER="${AMBARISERVER:-$(hostname -f)}"
AMBARI_USER="${AMBARI_USER:-admin}"
AMBARI_PASSWORD="${AMBARI_PASSWORD:-admin}"
PORT="${PORT:-8080}"
PROTOCOL="${PROTOCOL:-http}"
AMBARI_RESOURCES="${AMBARI_RESOURCES:-/var/lib/ambari-server/resources}"
BACKUP_DIR="${BACKUP_DIR:-$(pwd)/upgrade_backup}"
STOP_TIMEOUT="${STOP_TIMEOUT:-900}"
PYTHON_BIN="${PYTHON_BIN:-$(command -v python3 || command -v python || command -v python2)}"

BASE_URL="$PROTOCOL://$AMBARISERVER:$PORT/api/v1"
CURL=(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -H "X-Requested-By: ambari")

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# =========================
#  CLI flags
# =========================
LIST_ONLY=false
SHOW_ALL=false
ASSUME_YES=false
SKIP_BACKUP=false
PRESELECTED=()
while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST_ONLY=true ;;
        --all)  SHOW_ALL=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --skip-backup) SKIP_BACKUP=true ;;
        -h|--help)
            sed -n '2,/^set -o pipefail/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) error "Unknown option: $1"; exit 1 ;;
        *)  PRESELECTED+=("${1^^}") ;;
    esac
    shift
done

# =========================
#  Helpers
# =========================
json_values() {
    # json_values <key>  -- prints every string value of "<key>" from stdin
    grep -o "\"$1\" *: *\"[^\"]*\"" | sed 's/.*: *"//; s/"$//'
}

api_get() { "${CURL[@]}" -X GET "$BASE_URL$1"; }

# =========================
#  Cluster discovery
# =========================
echo -e "${BOLD}${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}"
echo -e "${BOLD}${YELLOW}│${NC} ${BOLD}${CYAN}Ambari MPACK Service Removal Tool${NC}                          ${BOLD}${YELLOW}│${NC}"
echo -e "${BOLD}${YELLOW}└────────────────────────────────────────────────────────────┘${NC}"
printf "   %-18s : %s\n" "AMBARISERVER" "$AMBARISERVER"
printf "   %-18s : %s\n" "AMBARI_USER" "$AMBARI_USER"
printf "   %-18s : ********\n" "AMBARI_PASSWORD"
printf "   %-18s : %s\n" "PORT" "$PORT"
printf "   %-18s : %s\n" "PROTOCOL" "$PROTOCOL"
printf "   %-18s : %s\n" "AMBARI_RESOURCES" "$AMBARI_RESOURCES"
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

STACK_FULL=$(api_get "/clusters/$CLUSTER?fields=Clusters/version" | json_values version | head -n1)
STACK_NAME="${STACK_FULL%%-*}"
STACK_VER="${STACK_FULL#*-}"
info "Cluster identified : ${BOLD}$CLUSTER${NC}"
info "Stack              : ${BOLD}${STACK_FULL:-unknown}${NC}"

# =========================
#  Installed services (+ state)
# =========================
mapfile -t INSTALLED < <(api_get "/clusters/$CLUSTER/services?fields=ServiceInfo/state" \
    | tr -d '\n' | grep -o '"ServiceInfo" *: *{[^}]*}' \
    | sed 's/.*"service_name" *: *"\([^"]*\)".*"state" *: *"\([^"]*\)".*/\1 \2/')

if [ ${#INSTALLED[@]} -eq 0 ]; then
    error "No services found in cluster $CLUSTER."
    exit 1
fi

# =========================
#  MPACK detection
# =========================
# Two independent sources, unioned:
#   A) <resources>/mpacks/*/mpack.json  -> "service_name" entries
#   B) symlinks under stacks/<STACK>/<VER>/services and common-services
#      that resolve into <resources>/mpacks/
declare -A MPACK_OF   # service -> mpack name(s)

MPACK_DIR="$AMBARI_RESOURCES/mpacks"
if [ -d "$MPACK_DIR" ]; then
    for mj in "$MPACK_DIR"/*/mpack.json; do
        [ -f "$mj" ] || continue
        mpack_name=$(basename "$(dirname "$mj")")
        while read -r svc; do
            [ -n "$svc" ] || continue
            MPACK_OF["$svc"]="${MPACK_OF[$svc]:+${MPACK_OF[$svc]},}$mpack_name"
        done < <(json_values service_name < "$mj" | sort -u)
    done

    mpack_real=$(readlink -f "$MPACK_DIR")
    for d in "$AMBARI_RESOURCES/stacks/$STACK_NAME/$STACK_VER/services"/* \
             "$AMBARI_RESOURCES/common-services"/*/*; do
        [ -L "$d" ] || continue
        target=$(readlink -f "$d")
        case "$target" in
            "$mpack_real"/*)
                rel="${target#$mpack_real/}"
                mpack_name="${rel%%/*}"
                svc=$(basename "$d")
                # common-services/<SVC>/<ver> -> service is the parent dir
                case "$d" in */common-services/*) svc=$(basename "$(dirname "$d")") ;; esac
                case ",${MPACK_OF[$svc]}," in
                    *",$mpack_name,"*) ;;
                    *) MPACK_OF["$svc"]="${MPACK_OF[$svc]:+${MPACK_OF[$svc]},}$mpack_name" ;;
                esac ;;
        esac
    done
    MPACK_DETECTION=true
else
    warn "$MPACK_DIR not found. Run this on the Ambari Server to detect mpack services."
    warn "Listing all installed services without MPACK flags."
    MPACK_DETECTION=false
    SHOW_ALL=true
fi

# =========================
#  Build the menu
# =========================
MENU_SVC=(); MENU_STATE=(); MENU_MPACK=()
for entry in "${INSTALLED[@]}"; do
    svc="${entry%% *}"; state="${entry##* }"
    mp="${MPACK_OF[$svc]:-}"
    if [ -n "$mp" ] || [ "$SHOW_ALL" = true ]; then
        MENU_SVC+=("$svc"); MENU_STATE+=("$state"); MENU_MPACK+=("$mp")
    fi
done

if [ ${#MENU_SVC[@]} -eq 0 ]; then
    warn "No MPACK-installed services found in cluster $CLUSTER."
    echo "   Re-run with --all to see every installed service."
    exit 0
fi

echo ""
if [ "$SHOW_ALL" = true ]; then
    echo -e "${BOLD}Installed services in '$CLUSTER' (MPACK services are tagged):${NC}"
else
    echo -e "${BOLD}MPACK-installed services in '$CLUSTER' (use --all to see every service):${NC}"
fi
printf "   %-4s %-20s %-14s %s\n" "#" "SERVICE" "STATE" "SOURCE"
printf "   %-4s %-20s %-14s %s\n" "---" "--------------------" "--------------" "------"
for i in "${!MENU_SVC[@]}"; do
    if [ -n "${MENU_MPACK[$i]}" ]; then
        src="${CYAN}MPACK${NC} (${MENU_MPACK[$i]})"
    else
        src="stack"
    fi
    printf "   %-4s %-20s %-14s " "$((i+1))" "${MENU_SVC[$i]}" "${MENU_STATE[$i]}"
    echo -e "$src"
done
echo ""

[ "$LIST_ONLY" = true ] && exit 0

# =========================
#  Selection
# =========================
SELECTED=()
if [ ${#PRESELECTED[@]} -gt 0 ]; then
    for want in "${PRESELECTED[@]}"; do
        found=false
        for entry in "${INSTALLED[@]}"; do
            [ "${entry%% *}" = "$want" ] && { found=true; break; }
        done
        if [ "$found" = true ]; then
            SELECTED+=("$want")
        else
            error "Service '$want' is not installed in cluster $CLUSTER."
            exit 1
        fi
    done
else
    read -r -p "Enter the number(s) of the service(s) to STOP and DELETE (comma-separated, or 'q' to quit): " choice
    [ -z "$choice" ] || [ "${choice,,}" = "q" ] && { echo "Nothing selected. Exiting."; exit 0; }
    IFS=',' read -r -a picks <<< "$choice"
    for p in "${picks[@]}"; do
        p=$(echo "$p" | tr -d '[:space:]')
        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt ${#MENU_SVC[@]} ]; then
            error "Invalid selection: '$p'"
            exit 1
        fi
        SELECTED+=("${MENU_SVC[$((p-1))]}")
    done
fi

# De-duplicate while keeping order
declare -A seen; tmp=()
for s in "${SELECTED[@]}"; do [ -z "${seen[$s]}" ] && { seen[$s]=1; tmp+=("$s"); }; done
SELECTED=("${tmp[@]}")

echo ""
if [ "$SKIP_BACKUP" = true ]; then
    echo -e "${BOLD}The following service(s) will be STOPPED and DELETED from cluster '$CLUSTER' ${RED}(NO config backup)${NC}:"
else
    echo -e "${BOLD}The following service(s) will be STOPPED, their configs BACKED UP to $BACKUP_DIR, then DELETED from cluster '$CLUSTER':${NC}"
fi
for s in "${SELECTED[@]}"; do
    if [ -n "${MPACK_OF[$s]:-}" ]; then
        echo -e "   - $s  ${CYAN}[MPACK: ${MPACK_OF[$s]}]${NC}"
    else
        echo -e "   - $s  ${YELLOW}[NOT an MPACK service]${NC}"
    fi
done
echo ""

if [ "$ASSUME_YES" != true ]; then
    for s in "${SELECTED[@]}"; do
        if [ "$MPACK_DETECTION" = true ] && [ -z "${MPACK_OF[$s]:-}" ]; then
            warn "$s was not installed via an mpack. Deleting core stack services can break the cluster."
            read -r -p "Type 'yes' to confirm deleting the non-mpack service $s: " c
            [ "$c" = "yes" ] || { echo "Aborted."; exit 0; }
        fi
    done
    read -r -p "Type DELETE to proceed: " confirm
    [ "$confirm" = "DELETE" ] || { echo "Aborted."; exit 0; }
fi

# =========================
#  Stop + wait
# =========================
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

stop_service() {
    local svc="$1"
    info "Stopping $svc ..."
    local resp req_id http_code
    resp=$("${CURL[@]}" -w '\n%{http_code}' -X PUT \
        -d '{"RequestInfo":{"context":"Stop '"$svc"' (mpack removal)","operation_level":{"level":"SERVICE","cluster_name":"'"$CLUSTER"'","service_name":"'"$svc"'"}},"Body":{"ServiceInfo":{"state":"INSTALLED"}}}' \
        "$BASE_URL/clusters/$CLUSTER/services/$svc")
    http_code=$(echo "$resp" | tail -n1)
    resp=$(echo "$resp" | sed '$d')

    case "$http_code" in
        200)
            info "$svc is already stopped."
            return 0 ;;
        202)
            req_id=$(echo "$resp" | grep -o '"id" *: *[0-9]*' | head -n1 | sed 's/.*: *//')
            [ -n "$req_id" ] || { error "Could not read request id from response: $resp"; return 1; }
            wait_for_request "$req_id" ;;
        *)
            error "Stop request for $svc returned HTTP $http_code:"
            echo "$resp" | head -c 800; echo
            return 1 ;;
    esac
}

# =========================
#  Backup (configs + host layout)
# =========================
# Writes <BACKUP_DIR>/<type>/<type>.json for every config type that belongs to
# the service (default config group), in the exact format produced by
# configs.py -a get, plus raw dumps under <BACKUP_DIR>/_services/<SVC>_<ts>/.
backup_service() {
    local svc="$1"
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    local raw_dir="$BACKUP_DIR/_services/${svc}_${ts}"
    mkdir -p "$raw_dir" || { error "Cannot create $raw_dir"; return 1; }

    info "Backing up configurations of $svc ..."

    # 1) Current service config version(s) -> raw dump + list of "type tag" pairs
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
# Prefer the Default config group (group_id == -1); fall back to the first item.
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

    # 2) Fetch every type by tag (same source configs.py uses) and write it
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

    # 3) Component -> host layout, useful when re-adding the service later
    api_get "/clusters/$CLUSTER/services/$svc/components?fields=ServiceComponentInfo/state,host_components/HostRoles/host_name,host_components/HostRoles/state"         > "$raw_dir/${svc}_host_components.json"
    printf "   %-45s -> %s\n" "component/host layout" "$raw_dir/${svc}_host_components.json"

    # 4) Password properties are masked as SECRET references which die with the service
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

# =========================
#  Main loop
# =========================
FAILED=()
for svc in "${SELECTED[@]}"; do
    echo ""
    echo -e "${BOLD}=== $svc ===${NC}"
    # 1. STOP
    if ! stop_service "$svc"; then
        warn "Stop did not complete cleanly for $svc."
        if [ "$ASSUME_YES" != true ]; then
            read -r -p "Continue with backup and DELETE anyway? (yes/no): " c
            [ "$c" = "yes" ] || { FAILED+=("$svc"); continue; }
        else
            FAILED+=("$svc"); continue
        fi
    fi

    # 2. BACKUP
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

    # 3. DELETE
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
    echo "   To restore a type after re-adding the service:"
    echo "     python /var/lib/ambari-server/resources/scripts/configs.py -u $AMBARI_USER -p '***' \\"
    echo "       -l $AMBARISERVER -t $PORT $( [ "$PROTOCOL" = https ] && echo "-s https " )-n $CLUSTER -a set -c <type> -f $BACKUP_DIR/<type>/<type>.json"
    echo "   or use config_backup_restore.sh from the same directory if the service is in its menu."
fi
echo "   Packages on the hosts were not removed. To also unregister the mpack(s) from the Ambari Server:"
for s in "${SELECTED[@]}"; do
    [ -n "${MPACK_OF[$s]:-}" ] || continue
    IFS=',' read -r -a mps <<< "${MPACK_OF[$s]}"
    for mp in "${mps[@]}"; do
        echo "     ambari-server uninstall-mpack --mpack-name=${mp%%-[0-9]*}   # then: ambari-server restart"
    done
done | sort -u
