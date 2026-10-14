#!/bin/bash
# © 2026 Acceldata Inc. All rights reserved.
###############################################################################
# Usage:
#   ./pulse_dashboards_export_import.sh              # interactive menu
#   ./pulse_dashboards_export_import.sh <function>   # run a function directly
#
# Functions:
#   export_all_dashplot_dashboards     - Export all dashboards
#   export_custom_dashplot_dashboards  - Export only custom dashboards
#   list_custom_dashplot_dashboards    - List only custom dashboard names
#   list_all_dashplot_dashboards       - List all dashboard names
#   import_dashplot_dashboards         - Import dashboards from ZIPs
#
# Optional environment overrides:
#   PULSE_USERNAME, PULSE_PASSWORD_BASE64  - credentials; create the base64 password with:
#                                              echo -n 'MyP@ssw0rd' | base64
#   PULSE_BASE_URL                         - full URL incl. port, e.g. https://pulse-host:4001 (skips host/protocol/port prompts)
#   PULSE_MONITOR_GROUP                    - monitor group (skips the prompt); same as -m/--monitor-group
#   PULSE_VERSION                          - force version, e.g. 4.1.5 (skips detection)
#   STORAGE_DIR                            - base export folder; each export creates a dated sub-folder
#                                            <YYYY-MM-DD_HHMMSS>_pulse-<version>_<custom|all>; import uses the latest
#   IMPORT_DIR=/path                       - import from this folder instead of the latest export (skips prompt)
#                                            (default: <AcceloHome>/pulse_exports, else /tmp/pulse_exports;
#                                             AcceloHome is read from env or /etc/profile.d/ad.sh)
#   DEBUG=1                                - save raw API responses to $STORAGE_DIR/debug/
#   IMPORT_FROM_OLD_UI=true|false          - ZIPs came from Pulse < 4.0 (skips prompt)
#   IMPORT_OVERWRITE=true|false            - overwrite existing dashboards on import (skips prompt)
#   IMPORT_FOLDERS=true|false              - recreate folders and move dashboards back into them (skips prompt)
#
# Example:
#   ./pulse_dashboards_export_import.sh export_custom_dashplot_dashboards
###############################################################################

# Colors
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
RED='\033[0;31m'; BOLD='\033[1m'; RESET='\033[0m'; BLUE='\033[0;34m'
GREY='\033[1;90m'; DARK_GREY='\033[1;30m'

###############################################################################
# Configuration
###############################################################################
PULSE_USERNAME="${PULSE_USERNAME:-admin}"
# Base64 password - create it with:  echo -n 'MyP@ssw0rd' | base64
# (-n is required: without it a trailing newline gets encoded and login fails)
PULSE_PASSWORD_BASE64="${PULSE_PASSWORD_BASE64:-YWRtaW5fcGFzc3dvcmQ=}"
DEBUG="${DEBUG:-0}"

BASE_URL=""
MONITOR_GROUP=""
jwt_token_fixed=""
PULSE_VERSION="${PULSE_VERSION:-}"
SETUP_DONE=false

# Default (shipped) dashboards - excluded from "custom" operations
DEFAULT_DASHBOARDS_REGEX='^(Airflow|CRUISE-CONTROL|CRUISE-CONTROL3|DRUID-DASHBOARD|HBASE-SERVICES|HDFS-DASHBOARD-NEW|HDFS-IO-METRICS|HIVE-SERVICE-NEW|HIVE-TABLE-USER|IMPALA-DAEMONS|KAFKA3-CONNECT|Kafka3-MirrorMaker-2|KAFKA-CONNECT|MirrorMaker-2|OZONE-DASHBOARD|PULSE-AGENT-STATS|SCHEMA-REGISTRY|STORAGE-IO-METRICS|YARN-NEW-DASHBOARD|YARN-OPTIMIZER-DASHBOARD|YARN-QUEUE-DASHBOARD)$'

# AcceloHome detection (used for exports, SSL config and monitor groups)
#   1) $AcceloHome from the environment
#   2) AcceloHome=... in /etc/profile.d/ad.sh
#   3) /data/acceldata (standard install path)
AD_PROFILE="/etc/profile.d/ad.sh"
resolve_accelo_home() {
    local h=""
    if [[ -n "${AcceloHome:-}" && -d "${AcceloHome}" ]]; then
        h="${AcceloHome}"
    elif [[ -r "$AD_PROFILE" ]]; then
        h=$(sed -n "s/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}AcceloHome=[\"']\{0,1\}\([^\"' ;]*\).*/\2/p" "$AD_PROFILE" | tail -n1)
        [[ -n "$h" && -d "$h" ]] || h=""
    fi
    if [[ -z "$h" && -d "/data/acceldata" ]]; then
        h="/data/acceldata"
    fi
    [[ -n "$h" ]] && echo "${h%/}"
    return 0
}

# Storage: <AcceloHome>/pulse_exports, or /tmp/pulse_exports if AcceloHome is not found
# (override with STORAGE_DIR=/some/path)
if [[ -z "${STORAGE_DIR:-}" ]]; then
    _ah=$(resolve_accelo_home)
    if [[ -n "$_ah" && -w "$_ah" ]]; then
        STORAGE_DIR="${_ah}/pulse_exports"
    else
        STORAGE_DIR="/tmp/pulse_exports"
        echo -e "${YELLOW}AcceloHome not found (or not writable) - using ${STORAGE_DIR} for exports.${RESET}"
    fi
    unset _ah
fi
BASE_EXPORT_DIR="${STORAGE_DIR%/}"        # each export gets its own dated sub-folder here
LOG_FILE="${BASE_EXPORT_DIR}/pulse_migration.log"

mkdir -p "$BASE_EXPORT_DIR"
if [[ ! -w "$BASE_EXPORT_DIR" ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} Cannot write to storage directory: $BASE_EXPORT_DIR"
    exit 1
fi
# List output goes to the base folder; export/import switch to a dated folder
DASHBOARD_LIST="${BASE_EXPORT_DIR}/dashboards_list.txt"
DASHBOARD_LIST_DETAILED="${BASE_EXPORT_DIR}/dashboards_list_detailed.tsv"
EXPORT_MANIFEST="${BASE_EXPORT_DIR}/export_manifest.tsv"   # path<TAB>name<TAB>origin<TAB>created
EXPORT_INFO="${BASE_EXPORT_DIR}/export_info.txt"
DEBUG_DIR="${BASE_EXPORT_DIR}/debug"
[[ "$DEBUG" == "1" ]] && mkdir -p "$DEBUG_DIR"

log()  { echo -e "$*" | tee -a "$LOG_FILE"; }
dbg()  { [[ "$DEBUG" == "1" ]] && echo -e "${GREY}[debug] $*${RESET}" >&2; }

# All Pulse requests go through here (insecure, silent)
send_curl_request() {
    curl -s --insecure "$@"
}

# Common headers for dashplot APIs
dashplot_headers() {
    DASH_HEADERS=(
        -H "Accept: application/json, text/plain, */*"
        -H "MonitorGroup: ${MONITOR_GROUP}"
        -H "ad-dashplot-app: pulse"
        -H "role: e30="
        -H "Cookie: application=pulse; jwt=${jwt_token_fixed}"
    )
}

###############################################################################
# check_dependencies
###############################################################################
check_dependencies() {
    local missing=0
    for cmd in curl file grep sed; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}${BOLD}Error:${RESET} Command '$cmd' not found. Please install it."
            missing=1
        fi
    done
    if ! echo 'a' | grep -qP 'a' 2>/dev/null; then
        echo -e "${RED}${BOLD}Error:${RESET} 'grep -P' (PCRE) is not supported on this host."
        missing=1
    fi
    [[ $missing -ne 0 ]] && exit 1
    command -v jq &>/dev/null && dbg "jq found - will use it for JSON parsing"
    return 0
}

###############################################################################
#  Default Pulse ports (resolve_accelo_home is defined near the top of the script)
###############################################################################
DEFAULT_HTTPS_PORT=4001
DEFAULT_HTTP_PORT=4000


###############################################################################
# detect_default_protocol <host>
# Same rule as the original script: https if SSL_ENFORCED or SSL_ENABLED is true
# in <AcceloHome>/config/docker/ad-core.yml, otherwise http.
# If ad-core.yml is not found, probes HTTPS on 4001 and falls back to HTTP.
# Sets SSL_SOURCE to describe where the decision came from.
###############################################################################
detect_default_protocol() {
    local host="$1" home ssl_config_file
    home=$(resolve_accelo_home)
    ssl_config_file="${home}/config/docker/ad-core.yml"
    if [[ -n "$home" && -f "$ssl_config_file" ]]; then
        if grep -Eq 'SSL_ENFORCED[:=][[:space:]]*"?true' "$ssl_config_file" || \
           grep -Eq 'SSL_ENABLED[:=][[:space:]]*"?true' "$ssl_config_file"; then
            SSL_SOURCE="SSL enabled in ${ssl_config_file}"; DETECTED_PROTOCOL="https"
        else
            SSL_SOURCE="SSL not enabled in ${ssl_config_file}"; DETECTED_PROTOCOL="http"
        fi
        return
    fi
    if curl -sk -o /dev/null --max-time 5 "https://${host}:${DEFAULT_HTTPS_PORT}/"; then
        SSL_SOURCE="ad-core.yml not found - HTTPS responded on ${DEFAULT_HTTPS_PORT}"; DETECTED_PROTOCOL="https"
    else
        SSL_SOURCE="ad-core.yml not found - HTTPS not reachable, using HTTP"; DETECTED_PROTOCOL="http"
    fi
}

###############################################################################
# modify_base_url - host / protocol / port menus (only when the user chooses Modify)
###############################################################################
modify_base_url() {
    local default_host="$1"
    choose_option "Pulse host:" 1 "This host (${default_host})" "Enter a different hostname / URL"
    local host="$default_host"
    if [[ "$CHOICE" == 2 ]]; then
        ask_text "Hostname or URL (e.g. pulse-host.example.com or https://pulse-host:4001)" '^[^[:space:]]+$'
        host="$REPLY_TEXT"
    fi
    # Full URL with explicit port -> use as-is
    if [[ "$host" =~ ^https?://[^/]+:[0-9]+/?$ ]]; then
        BASE_URL="${host%/}"; return
    fi
    local typed_proto=""
    [[ "$host" =~ ^(https?):// ]] && typed_proto="${BASH_REMATCH[1]}"
    host="${host#*://}"; host="${host%%/*}"; host="${host%%:*}"

    local def_proto="${typed_proto:-$DETECTED_PROTOCOL}" def_idx=1
    [[ "$def_proto" == "http" ]] && def_idx=2
    choose_option "Protocol:" "$def_idx" "HTTPS (default port ${DEFAULT_HTTPS_PORT})" "HTTP  (default port ${DEFAULT_HTTP_PORT})"
    local protocol default_port
    if [[ "$CHOICE" == 1 ]]; then protocol="https"; default_port="$DEFAULT_HTTPS_PORT"
    else protocol="http"; default_port="$DEFAULT_HTTP_PORT"; fi

    choose_option "Pulse ${protocol^^} port:" 1 "${default_port} (default for ${protocol^^})" "Enter a different port"
    local port="$default_port"
    if [[ "$CHOICE" == 2 ]]; then
        while true; do
            ask_text "Port (1-65535)" '^[0-9]+$'
            (( REPLY_TEXT >= 1 && REPLY_TEXT <= 65535 )) && { port="$REPLY_TEXT"; break; }
            echo -e "${RED}Port must be between 1 and 65535.${RESET}"
        done
    fi
    BASE_URL="${protocol}://${host}:${port}"
}

###############################################################################
# get_pulse_details
# 1) Builds BASE_URL from hostname -f + SSL flags in ad-core.yml
#    (HTTPS -> 4001, HTTP -> 4000) and asks once: use it, or modify.
# 2) Picks the Monitor Group automatically from <AcceloHome>/work.
#    Dashboards are global (not cluster-specific), so any monitor group works.
###############################################################################
get_pulse_details() {
    if [[ -n "${PULSE_BASE_URL:-}" ]]; then
        BASE_URL="${PULSE_BASE_URL%/}"
    else
        local default_host; default_host=$(hostname -f 2>/dev/null || hostname)
        detect_default_protocol "$default_host"
        local port="$DEFAULT_HTTP_PORT"; [[ "$DETECTED_PROTOCOL" == "https" ]] && port="$DEFAULT_HTTPS_PORT"
        BASE_URL="${DETECTED_PROTOCOL}://${default_host}:${port}"

        echo -e "${GREY}(${SSL_SOURCE})${RESET}"
        choose_option "Pulse URL: ${MAGENTA}${BASE_URL}${RESET}" 1 "Use this URL" "Modify"
        [[ "$CHOICE" == 2 ]] && modify_base_url "$default_host"
    fi

    # Quick reachability check
    if ! curl -sk -o /dev/null --max-time 10 "${BASE_URL}/"; then
        echo -e "${YELLOW}${BOLD}Warning: ${BASE_URL} is not reachable. Check the protocol/port (HTTPS ${DEFAULT_HTTPS_PORT}, HTTP ${DEFAULT_HTTP_PORT}).${RESET}"
        ask_yes_no "Continue anyway?" no || exit 1
    fi
    echo -e "${CYAN}${BOLD}Using BASE_URL: ${MAGENTA}${BASE_URL}${RESET}"

    # --- Monitor Group (read live from this environment; nothing hard-coded) ---
    local home work_dir="" groups=()
    home=$(resolve_accelo_home)
    [[ -n "$home" && -d "${home}/work" ]] && work_dir="${home}/work"
    if [[ -n "$work_dir" ]]; then
        while IFS= read -r g; do groups+=("$g"); done < <(
            find "$work_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | grep -v -i "license" | sort)
    fi

    if [[ -n "${PULSE_MONITOR_GROUP:-}" ]]; then
        MONITOR_GROUP="$PULSE_MONITOR_GROUP"          # from -m/--monitor-group or env
    elif [[ ${#groups[@]} -gt 0 ]]; then
        MONITOR_GROUP="${groups[0]}"
    else
        echo -e "${YELLOW}No monitor group found under \$AcceloHome/work or /data/acceldata/work.${RESET}"
        ask_text "Monitor Group" '^[^[:space:]]+$'; MONITOR_GROUP="$REPLY_TEXT"
    fi

    # Show the selection and allow changing it
    while true; do
        echo -e "${CYAN}${BOLD}Using Monitor Group: ${MAGENTA}${MONITOR_GROUP}${RESET} ${GREY}(dashboards are global - same for all clusters)${RESET}"
        [[ -n "${PULSE_MONITOR_GROUP:-}" ]] && { echo ""; break; }   # set explicitly - don't ask
        choose_option "Monitor Group:" 1 "Continue with ${MONITOR_GROUP}" "Change monitor group"
        [[ "$CHOICE" == 1 ]] && break
        if [[ ${#groups[@]} -gt 0 ]]; then
            choose_option "Select the Monitor Group (from ${work_dir}):" 0 "${groups[@]}" "Enter manually"
            if (( CHOICE <= ${#groups[@]} )); then
                MONITOR_GROUP="$CHOICE_TEXT"
            else
                ask_text "Monitor Group" '^[^[:space:]]+$'; MONITOR_GROUP="$REPLY_TEXT"
            fi
        else
            ask_text "Monitor Group" '^[^[:space:]]+$'; MONITOR_GROUP="$REPLY_TEXT"
        fi
        # Check: warn if the name is not a monitor group directory on this host
        if [[ -n "$work_dir" && ! -d "${work_dir}/${MONITOR_GROUP}" ]]; then
            echo -e "${YELLOW}Note: '${MONITOR_GROUP}' is not a directory under ${work_dir} - check the name.${RESET}"
        fi
    done
}


###############################################################################
# show_banner - Acceldata wordmark + title + copyright
###############################################################################
show_banner() {
    [[ "${BANNER_SHOWN:-false}" == true ]] && return
    BANNER_SHOWN=true
    echo ""
    echo -e "${CYAN}${BOLD}"
    cat << 'LOGO'
   ███    ████   ████  █████  █      ████    ███   █████   ███
  █   █  █      █      █      █      █   █  █   █    █    █   █
  █████  █      █      ████   █      █   █  █████    █    █████
  █   █  █      █      █      █      █   █  █   █    █    █   █
  █   █   ████   ████  █████  █████  ████   █   █    █    █   █
LOGO
    echo -e "${RESET}"
    echo -e "${BOLD}  ==============================================================${RESET}"
    echo -e "${BOLD}${MAGENTA}        Pulse Dashboard Export / Import / List Utility${RESET}"
    echo -e "${GREY}           © 2026 Acceldata Inc. All rights reserved.${RESET}"
    echo -e "${BOLD}  ==============================================================${RESET}"
    echo ""
}

###############################################################################
# choose_option <prompt> <default_index> <option1> [option2 ...]
# Numbered menu; Enter selects the default. Pass 0 as default_index to force an
# explicit selection (no default). Result index (1-based) in CHOICE, text in CHOICE_TEXT.
###############################################################################
choose_option() {
    local prompt="$1" def="$2"; shift 2
    local opts=("$@") i ans
    echo -e "${YELLOW}${BOLD}${prompt}${RESET}"
    for i in "${!opts[@]}"; do
        if (( i + 1 == def )); then
            echo -e "  ${CYAN}${BOLD}$((i + 1)))${RESET} ${opts[$i]} ${GREY}(default)${RESET}"
        else
            echo -e "  ${CYAN}${BOLD}$((i + 1)))${RESET} ${opts[$i]}"
        fi
    done
    while true; do
        if (( def > 0 )); then
            echo -ne "${YELLOW}Select [1-${#opts[@]}, Enter = ${def}]: ${RESET}"
        else
            echo -ne "${YELLOW}Select [1-${#opts[@]}]: ${RESET}"
        fi
        read -r ans
        (( def > 0 )) && ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#opts[@]} )); then
            CHOICE="$ans"; CHOICE_TEXT="${opts[$((ans - 1))]}"
            echo ""
            return 0
        fi
        echo -e "${RED}Invalid choice '${ans}'.${RESET}"
    done
}

# ask_text <prompt> <validation regex> -> REPLY_TEXT
ask_text() {
    local prompt="$1" re="${2:-.+}"
    while true; do
        echo -ne "${YELLOW}${BOLD}${prompt}: ${RESET}"
        read -r REPLY_TEXT
        [[ "$REPLY_TEXT" =~ $re ]] && return 0
        echo -e "${RED}Invalid value '${REPLY_TEXT}'.${RESET}"
    done
}

# ask_yes_no <prompt> <default: yes|no> -> returns 0 for yes
ask_yes_no() {
    local def=1; [[ "$2" == "no" ]] && def=2
    choose_option "$1" "$def" "Yes" "No"
    [[ "$CHOICE" == 1 ]]
}

###############################################################################
# fetch_jwt_token
###############################################################################
fetch_jwt_token() {
    echo -e "${DARK_GREY}${BOLD}Logging in to ${BASE_URL}/login...${RESET}"
    local login_response http_line
    login_response=$(send_curl_request -i "${BASE_URL}/login" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/plain, */*" \
        --data-raw "{\"email\":\"${PULSE_USERNAME}\",\"password\":\"${PULSE_PASSWORD_BASE64}\"}")
    [[ "$DEBUG" == "1" ]] && echo "$login_response" | sed -E 's/(jwt=)[^;]*/\1<masked>/I' > "${DEBUG_DIR}/login_response.txt"

    http_line=$(echo "$login_response" | grep -m1 -E '^HTTP/' | tr -d '\r')
    jwt_token_fixed=$(echo "$login_response" | tr -d '\r' | grep -i '^set-cookie:' | grep -oP '(?i)\bjwt=\K[^;]*' | head -n1 | sed 's/%3A/:/gI')

    if [[ -z "$jwt_token_fixed" ]]; then
        echo -e "${RED}${BOLD}Failed to retrieve JWT token.${RESET} (${http_line:-no HTTP response})"
        echo -e "${YELLOW}Check: URL/protocol, username, and PULSE_PASSWORD_BASE64.${RESET}"
        echo -e "${YELLOW}Create the base64 password with: ${BOLD}echo -n 'MyP@ssw0rd' | base64${RESET}"
        exit 1
    fi
    echo -e "${GREY}${BOLD}JWT token retrieved successfully.${RESET}"
}

###############################################################################
# fetch_pulse_version
###############################################################################
fetch_pulse_version() {
    if [[ -n "$PULSE_VERSION" ]]; then
        echo -e "${GREY}${BOLD}Using Pulse version from environment: ${CYAN}${PULSE_VERSION}${RESET}"
        return
    fi
    echo -e "${DARK_GREY}${BOLD}Fetching Pulse version from ${BASE_URL}/get-pulse-version...${RESET}"
    local version_response
    version_response=$(send_curl_request "${BASE_URL}/get-pulse-version" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Cookie: application=pulse; jwt=${jwt_token_fixed}")
    [[ "$DEBUG" == "1" ]] && echo "$version_response" > "${DEBUG_DIR}/version_response.txt"

    PULSE_VERSION=$(echo "$version_response" | grep -oP '"version"\s*:\s*"\K[^"]*' | head -n1)
    if [[ -z "$PULSE_VERSION" ]]; then
        echo -e "${YELLOW}${BOLD}Warning: Could not detect Pulse version.${RESET}"
        choose_option "Select the Pulse version:" 1 "4.x (4.0 or later)" "3.x or older" "Enter exact version"
        case "$CHOICE" in
            1) PULSE_VERSION="4.x" ;;
            2) PULSE_VERSION="3.x" ;;
            3) ask_text "Pulse version (e.g. 4.1.5)" '^v?[0-9]+(\.[0-9]+)*'; PULSE_VERSION="$REPLY_TEXT" ;;
        esac
    fi
    echo -e "${GREY}${BOLD}Pulse version: ${CYAN}${PULSE_VERSION}${RESET}"
}

# Returns 0 if Pulse major version >= 4 (handles "4.1.5", "v4.1.5", "4.1.5-rc1")
is_version_gte_4() {
    local major
    major=$(echo "$PULSE_VERSION" | grep -oP '^\D*\K\d+' | head -n1)
    [[ "$major" =~ ^[0-9]+$ && "$major" -ge 4 ]]
}

setup() {
    if [[ "$SETUP_DONE" == false ]]; then
        check_dependencies
        get_pulse_details
        fetch_jwt_token
        fetch_pulse_version
        SETUP_DONE=true
    fi
}

###############################################################################
# parse_nodes_tsv
# Reads a /dashplots/nodes JSON response on stdin and prints one line per node:
#   <type>\t<nodeName>\t<path>\t<isGlobalTenant: true|false|"">\t<createdAt epoch ms>
# Uses jq, then python3, then an awk fallback for Jackson pretty-printed JSON.
###############################################################################
parse_nodes_tsv() {
    local body; body=$(cat)
    if command -v jq &>/dev/null; then
        echo "$body" | jq -r '(if type=="array" then .[] elif (.data|type)=="array" then .data[] else empty end)
                              | [(.type // ""), (.nodeName // ""), (.path // ""),
                                 (if .isGlobalTenant == null then "" else (.isGlobalTenant|tostring) end),
                                 ((.createdAt // "")|tostring)] | @tsv' 2>/dev/null && return
    fi
    if command -v python3 &>/dev/null; then
        echo "$body" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(d, dict):
    d = d.get("data", [])
for n in d if isinstance(d, list) else []:
    if isinstance(n, dict):
        g = n.get("isGlobalTenant")
        g = "" if g is None else str(g).lower()
        print("\t".join([str(n.get(k) or "") for k in ("type", "nodeName", "path")] + [g, str(n.get("createdAt") or "")]))
' && return
    fi
    # Fallback: top-level node fields are indented by exactly 2 spaces
    echo "$body" | awk '
        function out() { if (name != "") print t "\t" name "\t" p "\t" g "\t" c; t = ""; name = ""; p = ""; g = ""; c = "" }
        /^  "createdAt" : [0-9]+/ { v = $0; gsub(/[^0-9]/, "", v); c = v }
        /^  "isGlobalTenant" : (true|false)/ { g = ($0 ~ /true/) ? "true" : "false" }
        /^  "type" : "/     { v = $0; sub(/^  "type" : "/, "", v);     sub(/",?$/, "", v); t = v }
        /^  "nodeName" : "/ { v = $0; sub(/^  "nodeName" : "/, "", v); sub(/",?$/, "", v); name = v }
        /^  "path" : "/     { v = $0; sub(/^  "path" : "/, "", v);     sub(/",?$/, "", v); p = v }
        /^\}, \{/ || /^\} \]/ { out() }
        END { out() }'
}

###############################################################################
# fetch_nodes <path>   - GET /dashplots/nodes[?path=...]; prints body, exits on error
###############################################################################
fetch_nodes() {
    local path="$1" raw http_status body
    local args=(-G "${BASE_URL}/dashplots/nodes")
    [[ -n "$path" ]] && args+=(--data-urlencode "path=${path}")
    raw=$(send_curl_request -w $'\n%{http_code}' "${args[@]}" "${DASH_HEADERS[@]}")
    http_status=$(echo "$raw" | tail -n1)
    body=$(echo "$raw" | sed '$d')
    if [[ "$DEBUG" == "1" ]]; then
        echo "$body" > "${DEBUG_DIR}/nodes_$(echo "${path:-root}" | tr '/ ' '__').json"
    fi
    if [[ ! "$http_status" =~ ^2[0-9]{2}$ ]]; then
        echo "HTTP_ERROR ${http_status}" >&2
        echo "$body" | head -c 500 >&2; echo >&2
        return 1
    fi
    echo "$body"
}

###############################################################################
# fetch_dashboard_names <all|custom>
# Pulse >= 4: walks the /dashplots/nodes hierarchy (root + every folder) and
#             collects nodes of type DASHBOARD.
# Pulse <  4: uses the legacy /dashplots/def/visualizations listing.
# Writes names to $DASHBOARD_LIST and "path<TAB>name" to $DASHBOARD_LIST_DETAILED.
###############################################################################
fetch_dashboard_names() {
    local mode="$1"
    dashplot_headers
    local tmp_all; tmp_all=$(mktemp)

    if is_version_gte_4; then
        dbg "Using /dashplots/nodes hierarchy (Pulse ${PULSE_VERSION})"
        local -a queue=("") ; local -A visited=()
        local requests=0 max_requests=500
        while [[ ${#queue[@]} -gt 0 && $requests -lt $max_requests ]]; do
            local current="${queue[0]}"; queue=("${queue[@]:1}")
            [[ -n "${visited["k:$current"]:-}" ]] && continue
            visited["k:$current"]=1
            ((requests++))
            local body
            if ! body=$(fetch_nodes "$current"); then
                log "${RED}${BOLD}Error: /dashplots/nodes failed for path '${current:-/}'.${RESET}"
                rm -f "$tmp_all"; exit 1
            fi
            while IFS=$'\t' read -r ntype nname npath nglobal ncreated; do
                [[ -z "$nname" ]] && continue
                if [[ "${ntype^^}" == "DASHBOARD" ]]; then
                    local origin="unknown"
                    [[ "$nglobal" == "true" ]]  && origin="stock"
                    [[ "$nglobal" == "false" ]] && origin="custom"
                    local cdate="-"
                    if [[ "$ncreated" =~ ^[0-9]{10,}$ ]]; then
                        cdate=$(date -d "@$(( ${ncreated:0:10} ))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "-")
                    fi
                    printf '%s\t%s\t%s\t%s\n' "${npath:-/$nname}" "$nname" "$origin" "$cdate" >> "$tmp_all"
                elif [[ "${ntype^^}" == "LISTVIEW" ]]; then
                    dbg "Skipping list view '${nname}' (not a dashboard)"
                elif [[ -n "$npath" && "$npath" != "$current" && -z "${visited["k:$npath"]:-}" ]]; then
                    dbg "Folder '${npath}' (type ${ntype}) - descending"
                    queue+=("$npath")
                fi
            done < <(echo "$body" | parse_nodes_tsv)
        done
        [[ $requests -ge $max_requests ]] && log "${YELLOW}Warning: stopped after ${max_requests} folder requests.${RESET}"
    else
        dbg "Using legacy /dashplots/def/visualizations (Pulse ${PULSE_VERSION})"
        local url="${BASE_URL}/dashplots/def/visualizations?sortOrder=1&sortColumn=name&pageNo=1&pageSize=900"
        local raw http_status body
        raw=$(send_curl_request -w $'\n%{http_code}' "$url" "${DASH_HEADERS[@]}")
        http_status=$(echo "$raw" | tail -n1)
        body=$(echo "$raw" | sed '$d')
        [[ "$DEBUG" == "1" ]] && echo "$body" > "${DEBUG_DIR}/visualizations_response.json"
        if [[ ! "$http_status" =~ ^2[0-9]{2}$ ]]; then
            log "${RED}${BOLD}Error: dashboard listing returned HTTP ${http_status}.${RESET}"
            echo "$body" | head -c 500 | tee -a "$LOG_FILE"; echo
            rm -f "$tmp_all"; exit 1
        fi
        echo "$body" | grep -oP '"dashplot_name"\s*:\s*"\K(\\.|[^"\\])*' | while IFS= read -r n; do
            printf '/%s\t%s\tunknown\t-\n' "$n" "$n"
        done >> "$tmp_all"
    fi

    if [[ ! -s "$tmp_all" ]]; then
        log "${RED}${BOLD}Error: Pulse returned no dashboards. Rerun with DEBUG=1 and check ${DEBUG_DIR}/.${RESET}"
        rm -f "$tmp_all"; exit 1
    fi

    if [[ "$mode" == "custom" ]]; then
        # Pulse 4.x: stock dashboards have isGlobalTenant=true, user-created/imported ones false.
        # Older Pulse (origin "unknown"): fall back to the default-dashboard name list.
        awk -F'\t' -v re="$DEFAULT_DASHBOARDS_REGEX" \
            '$3 == "custom" || ($3 == "unknown" && $2 !~ re)' "$tmp_all" > "${tmp_all}.f" && mv "${tmp_all}.f" "$tmp_all"
    fi
    sort -t$'\t' -k2,2 -u "$tmp_all" > "$DASHBOARD_LIST_DETAILED"
    cut -f2 "$DASHBOARD_LIST_DETAILED" > "$DASHBOARD_LIST"
    rm -f "$tmp_all"

    if [[ ! -s "$DASHBOARD_LIST" ]]; then
        log "${RED}${BOLD}Error: No ${mode} dashboards found.${RESET}"
        exit 1
    fi
    log "${GREEN}$(wc -l < "$DASHBOARD_LIST") ${mode} dashboard(s) written to: ${DASHBOARD_LIST}${RESET}"
    log "${GREY}Details (path, name, stock/custom, created) written to: ${DASHBOARD_LIST_DETAILED}${RESET}"
}

# Pretty-print $DASHBOARD_LIST_DETAILED as: ORIGIN  NAME  PATH
print_dashboard_table() {
    printf "%-8s %-17s %-45s %s\n" "ORIGIN" "CREATED" "NAME" "PATH"
    sort -t$'\t' -k4,4 -k2,2 "$DASHBOARD_LIST_DETAILED" | \
        awk -F'\t' '{ printf "%-8s %-17s %-45s %s\n", $3, $4, $2, $1 }'
    awk -F'\t' '{ c[$3]++ } END { printf "\nTotal: %d", NR; for (k in c) printf " | %s: %d", k, c[k]; print "" }' "$DASHBOARD_LIST_DETAILED"
    # Created-date summary per origin (stock dashboards are seeded together on one date)
    awk -F'\t' '{ d = substr($4, 1, 10); key = $3 "\t" d; n[key]++ }
         END { for (k in n) { split(k, a, "\t"); printf "  %-7s created on %s : %d dashboard(s)\n", a[1], a[2], n[k] } }' \
         "$DASHBOARD_LIST_DETAILED" | sort
    # Sanity check: a custom dashboard created on the stock seed date, or stock spread over several dates
    local stock_dates custom_on_stock
    stock_dates=$(awk -F'\t' '$3=="stock"{ print substr($4,1,10) }' "$DASHBOARD_LIST_DETAILED" | sort -u)
    if [[ $(echo "$stock_dates" | sed '/^$/d' | wc -l) -gt 1 ]]; then
        echo -e "${YELLOW}Note: stock dashboards span more than one date (likely re-seeded by a Pulse upgrade).${RESET}"
    fi
    if [[ -n "$stock_dates" ]]; then
        custom_on_stock=$(awk -F'\t' -v sd="$(echo "$stock_dates" | tr '\n' ' ')" \
            '$3=="custom" && index(sd, substr($4,1,10)) { print "    " $2 }' "$DASHBOARD_LIST_DETAILED")
        if [[ -n "$custom_on_stock" ]]; then
            echo -e "${YELLOW}Note: these custom dashboards were created on the same date as the stock ones:${RESET}\n${custom_on_stock}"
        fi
    fi
    return 0
}

# File-safe name for a dashboard (replaces / and other unsafe characters)
safe_filename() {
    echo "$1" | sed -E 's#[/\\:*?"<>|]#_#g'
}

# Escape a string for inclusion in a JSON string literal
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

###############################################################################
# Folder (DIRECTORY) support
#   Create folder : POST /dashplots/nodes {"nodeName","parentPath","type":"DIRECTORY"}
#   Move items    : PUT  /dashplots/nodes {"paths":[...],"newPath":"<folder path>"}
#   (request shapes taken from the Pulse 4.x UI)
###############################################################################

# parent_of </a/b/c> -> /a/b   ;  parent_of </a> -> /
parent_of() {
    local p="${1%/*}"
    echo "${p:-/}"
}

# scan_hierarchy - walks /dashplots/nodes and fills:
#   EXISTING_DIRS[<path>]=1       for every DIRECTORY
#   DASH_PATH[<name>]=<path>      for every DASHBOARD
scan_hierarchy() {
    unset EXISTING_DIRS DASH_PATH
    declare -gA EXISTING_DIRS=() DASH_PATH=()
    dashplot_headers
    local -a queue=("") ; local -A seen=()
    local requests=0
    while [[ ${#queue[@]} -gt 0 && $requests -lt 500 ]]; do
        local current="${queue[0]}"; queue=("${queue[@]:1}")
        [[ -n "${seen["k:$current"]:-}" ]] && continue
        seen["k:$current"]=1; ((requests++))
        local body
        body=$(fetch_nodes "$current") || return 1
        while IFS=$'\t' read -r ntype nname npath _g _c; do
            [[ -z "$nname" ]] && continue
            case "${ntype^^}" in
                DASHBOARD) DASH_PATH["$nname"]="${npath:-/$nname}" ;;
                LISTVIEW)  ;;
                *)         EXISTING_DIRS["$npath"]=1
                           [[ -z "${seen["k:$npath"]:-}" ]] && queue+=("$npath") ;;
            esac
        done < <(echo "$body" | parse_nodes_tsv)
    done
    return 0
}

# create_folder </parent/child> - creates one folder (parent must exist)
create_folder() {
    local path="$1" name parent raw http_status
    name="${path##*/}"; parent=$(parent_of "$path")
    dashplot_headers
    raw=$(send_curl_request -w $'\n%{http_code}' -X POST "${BASE_URL}/dashplots/nodes" "${DASH_HEADERS[@]}" \
        -H "Content-Type: application/json" \
        --data-raw "{\"nodeName\":\"$(json_escape "$name")\",\"parentPath\":\"$(json_escape "$parent")\",\"type\":\"DIRECTORY\"}")
    http_status=$(echo "$raw" | tail -n1)
    if [[ "$http_status" =~ ^2[0-9]{2}$ ]]; then
        log "${GREEN}  Created folder: ${path}${RESET}"
        EXISTING_DIRS["$path"]=1
        return 0
    fi
    log "${RED}  Failed to create folder ${path} (HTTP ${http_status})${RESET}"
    echo "$raw" | sed '$d' | head -c 300 | tee -a "$LOG_FILE"; echo
    return 1
}

# ensure_folders <folder paths...> - creates any missing folders, parents first
ensure_folders() {
    local -A wanted=() ; local f p
    for f in "$@"; do
        p="$f"
        while [[ -n "$p" && "$p" != "/" ]]; do wanted["$p"]=1; p=$(parent_of "$p"); done
    done
    [[ ${#wanted[@]} -eq 0 ]] && return 0
    # shallowest first (count "/" characters)
    local sorted
    sorted=$(for f in "${!wanted[@]}"; do echo "$(tr -cd '/' <<< "$f" | wc -c)"$'\t'"$f"; done | sort -n -k1,1 | cut -f2-)
    local rc=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ -n "${EXISTING_DIRS[$f]:-}" ]]; then
            dbg "Folder exists: $f"
        else
            create_folder "$f" || rc=1
        fi
    done <<< "$sorted"
    return $rc
}

# move_to_folder <target folder> <item paths...>
move_to_folder() {
    local target="$1"; shift
    local items="" p raw http_status
    for p in "$@"; do items+="${items:+,}\"$(json_escape "$p")\""; done
    dashplot_headers
    raw=$(send_curl_request -w $'\n%{http_code}' -X PUT "${BASE_URL}/dashplots/nodes" "${DASH_HEADERS[@]}" \
        -H "Content-Type: application/json" \
        --data-raw "{\"paths\":[${items}],\"newPath\":\"$(json_escape "$target")\"}")
    http_status=$(echo "$raw" | tail -n1)
    if [[ "$http_status" =~ ^2[0-9]{2}$ ]]; then
        log "${GREEN}  Moved $# dashboard(s) into ${target}${RESET}"
        return 0
    fi
    log "${RED}  Failed to move into ${target} (HTTP ${http_status})${RESET}"
    echo "$raw" | sed '$d' | head -c 300 | tee -a "$LOG_FILE"; echo
    return 1
}

###############################################################################
# Dated export directories
#   Every export goes to <BASE_EXPORT_DIR>/<YYYY-MM-DD_HHMMSS>_pulse-<version>_<scope>/
#   Import uses the latest one by default (or another one you pick).
###############################################################################
DATED_DIR_REGEX='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}'

# set_work_dir <dir> - point list/manifest/zip paths at <dir>
set_work_dir() {
    STORAGE_DIR="${1%/}"
    DASHBOARD_LIST="${STORAGE_DIR}/dashboards_list.txt"
    DASHBOARD_LIST_DETAILED="${STORAGE_DIR}/dashboards_list_detailed.tsv"
    EXPORT_MANIFEST="${STORAGE_DIR}/export_manifest.tsv"
    EXPORT_INFO="${STORAGE_DIR}/export_info.txt"
    DEBUG_DIR="${STORAGE_DIR}/debug"
    [[ "$DEBUG" == "1" ]] && mkdir -p "$DEBUG_DIR"
    return 0
}

# new_export_dir <custom|all> - creates and switches to a new dated directory
new_export_dir() {
    local scope="$1" ver
    ver=$(echo "${PULSE_VERSION:-unknown}" | tr -c 'A-Za-z0-9.\n-' '_')
    local dir="${BASE_EXPORT_DIR}/$(date '+%Y-%m-%d_%H%M%S')_pulse-${ver}_${scope}"
    mkdir -p "$dir" || { log "${RED}${BOLD}Error: cannot create ${dir}${RESET}"; exit 1; }
    set_work_dir "$dir"
    log "${CYAN}Export directory: ${MAGENTA}${dir}${RESET}"
}

# write_export_info <scope> <ok> <fail>
write_export_info() {
    {
        echo "export_date=$(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "pulse_version=${PULSE_VERSION}"
        echo "pulse_url=${BASE_URL}"
        echo "monitor_group=${MONITOR_GROUP}"
        echo "host=$(hostname -f 2>/dev/null || hostname)"
        echo "scope=$1"
        echo "exported=$2"
        echo "failed=$3"
    } > "$EXPORT_INFO"
}

# info_value <dir> <key>
info_value() {
    [[ -f "$1/export_info.txt" ]] && sed -n "s/^$2=//p" "$1/export_info.txt" | head -n1
}

# list_export_dirs - dated export dirs that contain ZIPs, newest first
list_export_dirs() {
    local d
    find "$BASE_EXPORT_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | grep -E "$DATED_DIR_REGEX" | sort -r | while IFS= read -r d; do
            compgen -G "${BASE_EXPORT_DIR}/${d}/*.zip" > /dev/null && echo "${BASE_EXPORT_DIR}/${d}"
        done
}

# describe_export_dir <dir> -> one-line summary
describe_export_dir() {
    local d="$1" n
    n=$(find "$d" -maxdepth 1 -type f -name '*.zip' | wc -l)
    printf "%s  (%s ZIPs, Pulse %s, %s)" "$(basename "$d")" "$n" \
        "$(info_value "$d" pulse_version || true)" "$(info_value "$d" scope || true)"
}

# select_import_dir - chooses the directory to import from (latest by default)
select_import_dir() {
    if [[ -n "${IMPORT_DIR:-}" ]]; then
        [[ -d "$IMPORT_DIR" ]] || { log "${RED}${BOLD}Error: IMPORT_DIR ${IMPORT_DIR} does not exist.${RESET}"; exit 1; }
        set_work_dir "$IMPORT_DIR"; return 0
    fi
    local -a dirs=()
    while IFS= read -r d; do dirs+=("$d"); done < <(list_export_dirs)

    if [[ ${#dirs[@]} -eq 0 ]]; then
        # Older layout: ZIPs directly in the base directory
        if compgen -G "${BASE_EXPORT_DIR}/*.zip" > /dev/null; then
            log "${YELLOW}No dated export folders found - using ZIPs in ${BASE_EXPORT_DIR}${RESET}"
            set_work_dir "$BASE_EXPORT_DIR"; return 0
        fi
        log "${RED}${BOLD}Error: no exports found in ${BASE_EXPORT_DIR}. Run an export first, or set IMPORT_DIR=/path.${RESET}"
        exit 1
    fi

    choose_option "Import from:" 1 \
        "Latest export: $(describe_export_dir "${dirs[0]}")" \
        "Choose another export (${#dirs[@]} available)" \
        "Enter a folder path"
    case "$CHOICE" in
        1) set_work_dir "${dirs[0]}" ;;
        2)
            local -a labels=() ; local i
            for i in "${!dirs[@]}"; do (( i < 20 )) && labels+=("$(describe_export_dir "${dirs[$i]}")"); done
            choose_option "Select an export (newest first):" 1 "${labels[@]}"
            set_work_dir "${dirs[$((CHOICE - 1))]}"
            ;;
        3)
            while true; do
                ask_text "Folder containing the ZIPs" '^/'
                [[ -d "$REPLY_TEXT" ]] && compgen -G "${REPLY_TEXT%/}/*.zip" > /dev/null && break
                echo -e "${RED}No ZIP files found in ${REPLY_TEXT}.${RESET}"
            done
            set_work_dir "$REPLY_TEXT"
            ;;
    esac
    log "${CYAN}Importing from: ${MAGENTA}${STORAGE_DIR}${RESET}"
}

###############################################################################
# export_dashboards_from_list
###############################################################################
export_dashboards_from_list() {
    local ok=0 fail=0
    : > "${EXPORT_MANIFEST}.tmp"
    dashplot_headers
    while IFS= read -r dashboard || [[ -n "$dashboard" ]]; do
        [[ -z "$dashboard" ]] && continue
        local output_file="${STORAGE_DIR}/$(safe_filename "$dashboard").zip"
        echo -e "${YELLOW}Exporting: ${dashboard}...${RESET}" | tee -a "$LOG_FILE"
        local http_status
        http_status=$(send_curl_request -w '%{http_code}' "${BASE_URL}/dashplots/export" \
            "${DASH_HEADERS[@]}" \
            -H "Content-Type: application/json" \
            --data-raw "{\"nodeName\":\"$(json_escape "$dashboard")\"}" \
            --output "$output_file")
        if [[ "$http_status" =~ ^2[0-9]{2}$ && -s "$output_file" ]] && file "$output_file" | grep -q "Zip archive data"; then
            log "${GREEN}Exported: ${dashboard} -> ${output_file}${RESET}"
            awk -F'\t' -v n="$dashboard" '$2 == n { print; exit }' "$DASHBOARD_LIST_DETAILED" >> "${EXPORT_MANIFEST}.tmp"
            ((ok++))
        else
            log "${RED}Failed to export: ${dashboard} (HTTP ${http_status})${RESET}"
            [[ -f "$output_file" ]] && { head -c 300 "$output_file" | tee -a "$LOG_FILE"; echo; }
            rm -f "$output_file"
            ((fail++))
        fi
    done < "$DASHBOARD_LIST"
    mv -f "${EXPORT_MANIFEST}.tmp" "$EXPORT_MANIFEST"
    write_export_info "${1:-custom}" "$ok" "$fail"
    log "${GREEN}${BOLD}Export completed: ${ok} succeeded, ${fail} failed. Files in ${STORAGE_DIR}${RESET}"
    local in_folders
    in_folders=$(awk -F'\t' '{ p = $1; sub("/[^/]*$", "", p); if (p != "") print p }' "$EXPORT_MANIFEST" | sort -u)
    if [[ -n "$in_folders" ]]; then
        log "${CYAN}Folder structure saved in ${EXPORT_MANIFEST} (folders: $(echo "$in_folders" | tr '\n' ' '))${RESET}"
    fi
    return 0
}

export_all_dashplot_dashboards() {
    setup
    log "${CYAN}${BOLD}Fetching and exporting ALL Dashplot dashboards...${RESET}"
    new_export_dir all
    fetch_dashboard_names all
    export_dashboards_from_list all
    return 0
}

export_custom_dashplot_dashboards() {
    setup
    log "${CYAN}${BOLD}Fetching and exporting CUSTOM Dashplot dashboards...${RESET}"
    new_export_dir custom
    fetch_dashboard_names custom
    export_dashboards_from_list custom
    return 0
}

list_custom_dashplot_dashboards() {
    setup
    log "${BLUE}Listing custom dashboards only...${RESET}"
    fetch_dashboard_names custom
    print_dashboard_table
    return 0
}

list_all_dashplot_dashboards() {
    setup
    log "${BLUE}Listing all dashboards...${RESET}"
    fetch_dashboard_names all
    print_dashboard_table
    return 0
}

###############################################################################
# import_dashplot_dashboards
# Uses dashboards_list.txt if present; otherwise imports every ZIP in STORAGE_DIR.
#
# Pulse 4.x UI calls: POST /dashplots/import[?overwrite=true][&importedFromOldUI=true]
#   - importedFromOldUI=true only for ZIPs exported from Pulse < 4.0 (old UI)
#   - overwrite=true replaces dashboards that already exist
# Env overrides: IMPORT_FROM_OLD_UI=true|false, IMPORT_OVERWRITE=true|false
###############################################################################
import_one_zip() {
    # $1 = url, $2 = zip file ; prints "<body>\n<http_status>"
    send_curl_request -w $'\n%{http_code}' "$1" "${DASH_HEADERS[@]}" -F "file=@${2};type=application/zip"
}

import_dashplot_dashboards() {
    setup
    log "${CYAN}${BOLD}Starting import process...${RESET}"
    select_import_dir

    local import_url
    if is_version_gte_4; then
        local from_old="${IMPORT_FROM_OLD_UI:-}"
        local src_ver src_major def_src=1
        src_ver=$(info_value "$STORAGE_DIR" pulse_version || true)
        src_major=$(echo "$src_ver" | grep -oP '^\D*\K\d+' | head -n1)
        [[ "$src_major" =~ ^[0-9]+$ && "$src_major" -lt 4 ]] && def_src=2
        [[ -n "$src_ver" ]] && echo -e "${GREY}These ZIPs were exported from Pulse ${src_ver}.${RESET}"
        if [[ -z "$from_old" ]]; then
            choose_option "Where were these ZIPs exported from?" "$def_src" \
                "Pulse 4.x (new UI) - includes ZIPs exported by this script on 4.x" \
                "Pulse 3.x or older (old UI)"
            [[ "$CHOICE" == 2 ]] && from_old=true || from_old=false
        fi
        local overwrite="${IMPORT_OVERWRITE:-}"
        if [[ -z "$overwrite" ]]; then
            choose_option "If a dashboard already exists on the target:" 1 \
                "Overwrite it" "Keep the existing one (do not overwrite)"
            [[ "$CHOICE" == 1 ]] && overwrite=true || overwrite=false
        fi
        local params=()
        [[ "$overwrite" == "true" ]] && params+=("overwrite=true")
        [[ "$from_old" == "true" ]] && params+=("importedFromOldUI=true")
        import_url="${BASE_URL}/dashplots/import"
        [[ ${#params[@]} -gt 0 ]] && import_url="${import_url}?$(IFS='&'; echo "${params[*]}")"
    else
        import_url="${BASE_URL}/dashplots/import?overwrite=true"
    fi
    log "${CYAN}${BOLD}Pulse ${PULSE_VERSION} -> import URL: ${import_url}${RESET}"

    # Restore folders?
    local restore_folders="${IMPORT_FOLDERS:-}"
    if [[ -z "$restore_folders" ]] && is_version_gte_4 && [[ -s "$EXPORT_MANIFEST" ]] && \
       awk -F'\t' '{ p=$1; sub("/[^/]*$","",p); if (p!="") f=1 } END { exit !f }' "$EXPORT_MANIFEST"; then
        choose_option "Some dashboards were in folders when exported:" 1 \
            "Recreate the folders and put the dashboards back in them" "Import everything at the top level"
        [[ "$CHOICE" == 1 ]] && restore_folders=true || restore_folders=false

    fi

    local zip_files=() ; local -A zip_name=() zip_target=()
    if [[ -s "$EXPORT_MANIFEST" ]]; then
        log "${GREY}Using export manifest: ${EXPORT_MANIFEST}${RESET}"
        while IFS=$'\t' read -r mpath mname _o _c; do
            [[ -z "$mname" ]] && continue
            local z="${STORAGE_DIR}/$(safe_filename "$mname").zip"
            if [[ -f "$z" ]]; then
                zip_files+=("$z"); zip_name["$z"]="$mname"; zip_target["$z"]=$(parent_of "${mpath:-/$mname}")
            else
                log "${RED}Skipped: ${mname} (ZIP not found: ${z})${RESET}"
            fi
        done < "$EXPORT_MANIFEST"
    elif [[ -s "$DASHBOARD_LIST" ]]; then
        while IFS= read -r dashboard || [[ -n "$dashboard" ]]; do
            [[ -z "${dashboard// }" ]] && continue
            local z="${STORAGE_DIR}/$(safe_filename "$dashboard").zip"
            if [[ -f "$z" ]]; then zip_files+=("$z"); else log "${RED}Skipped: ${dashboard} (ZIP not found: ${z})${RESET}"; fi
        done < "$DASHBOARD_LIST"
    else
        log "${YELLOW}No ${DASHBOARD_LIST} found - importing all ZIP files in ${STORAGE_DIR}${RESET}"
        while IFS= read -r -d '' z; do zip_files+=("$z"); done \
            < <(find "$STORAGE_DIR" -maxdepth 1 -type f -name '*.zip' -print0 | sort -z)
    fi

    if [[ ${#zip_files[@]} -eq 0 ]]; then
        log "${RED}${BOLD}Error: No ZIP files to import in ${STORAGE_DIR}.${RESET}"
        exit 1
    fi

    # Create the folders before importing
    if [[ "$restore_folders" == "true" ]]; then
        local -a needed=()
        for zip_file in "${zip_files[@]}"; do
            [[ "${zip_target[$zip_file]:-/}" != "/" ]] && needed+=("${zip_target[$zip_file]}")
        done
        if [[ ${#needed[@]} -gt 0 ]]; then
            log "${CYAN}${BOLD}Checking folders on the target...${RESET}"
            scan_hierarchy || { log "${RED}Could not read the dashboard hierarchy - folders will not be restored.${RESET}"; restore_folders=false; }
            [[ "$restore_folders" == "true" ]] && ensure_folders "${needed[@]}"
        fi
    fi

    dashplot_headers
    local ok=0 fail=0 ; local -a imported_ok=()
    for zip_file in "${zip_files[@]}"; do
        local name="${zip_name[$zip_file]:-$(basename "$zip_file" .zip)}"
        echo -e "${YELLOW}Importing: ${name}...${RESET}" | tee -a "$LOG_FILE"
        local response http_status body
        response=$(import_one_zip "$import_url" "$zip_file")
        http_status=$(echo "$response" | tail -n1)
        body=$(echo "$response" | sed '$d')
        if [[ "$http_status" =~ ^2[0-9]{2}$ ]]; then
            log "${GREEN}Successfully imported: ${name}${RESET}"
            imported_ok+=("$zip_file")
            ((ok++))
        else
            log "${RED}Failed to import: ${name} (HTTP ${http_status})${RESET}"
            echo "$body" | head -c 500 | tee -a "$LOG_FILE"; echo
            ((fail++))
        fi
    done
    log "${GREEN}${BOLD}Import completed: ${ok} succeeded, ${fail} failed.${RESET}"

    # Put imported dashboards back into their folders
    if [[ "$restore_folders" == "true" && ${#imported_ok[@]} -gt 0 ]]; then
        log "${CYAN}${BOLD}Restoring folder placement...${RESET}"
        if ! scan_hierarchy; then
            log "${RED}Could not re-read the hierarchy - dashboards left where the import put them.${RESET}"
            return 1
        fi
        local -A by_folder=() ; local placed=0 moved=0 missing=0
        for zip_file in "${imported_ok[@]}"; do
            local n="${zip_name[$zip_file]:-$(basename "$zip_file" .zip)}" target="${zip_target[$zip_file]:-/}"
            local current="${DASH_PATH[$n]:-}"
            if [[ -z "$current" ]]; then
                log "${YELLOW}  ${n}: not found in the hierarchy after import${RESET}"; ((missing++)); continue
            fi
            if [[ "$(parent_of "$current")" == "$target" ]]; then
                ((placed++))
            else
                by_folder["$target"]+="${current}"$'\n'
            fi
        done
        local target
        for target in "${!by_folder[@]}"; do
            local -a items=()
            while IFS= read -r p; do [[ -n "$p" ]] && items+=("$p"); done <<< "${by_folder[$target]}"
            move_to_folder "$target" "${items[@]}" && moved=$((moved + ${#items[@]}))
        done
        log "${GREEN}${BOLD}Folder placement: ${placed} already in place, ${moved} moved, ${missing} not found.${RESET}"
        # Final view
        scan_hierarchy && for zip_file in "${imported_ok[@]}"; do
            local n="${zip_name[$zip_file]:-$(basename "$zip_file" .zip)}"
            printf "  %-45s %s\n" "$n" "${DASH_PATH[$n]:-?}"
        done | sort -k2 | tee -a "$LOG_FILE"
    fi
    return 0
}

###############################################################################
# Usage / main
###############################################################################
usage() {
    echo -e "${YELLOW}${BOLD}Usage:${RESET} ./$(basename "$0")              ${GREY}# interactive menu${RESET}"
    echo -e "       ./$(basename "$0") <function>   ${GREY}# run a function directly${RESET}"
    echo ""
    echo -e "${CYAN}${BOLD}Available functions:${RESET}"
    printf "  %-35s %s\n" "export_all_dashplot_dashboards"    "→ Export all dashboards (Default + Custom)"
    printf "  %-35s %s\n" "export_custom_dashplot_dashboards" "→ Export only custom dashboards"
    printf "  %-35s %s\n" "list_custom_dashplot_dashboards"   "→ List names of custom dashboards"
    printf "  %-35s %s\n" "list_all_dashplot_dashboards"      "→ List names of all dashboards"
    printf "  %-35s %s\n" "import_dashplot_dashboards"        "→ Import dashboards from exported ZIPs"
    echo ""
    echo -e "${CYAN}${BOLD}Examples:${RESET}"
    echo "  ./$(basename "$0") export_custom_dashplot_dashboards"
    echo "  PULSE_VERSION=4.1.5 ./$(basename "$0") import_dashplot_dashboards"
    echo "  DEBUG=1 ./$(basename "$0") list_custom_dashplot_dashboards"
    echo "  ./$(basename "$0") list_custom_dashplot_dashboards -m <monitor_group>"
    echo ""
    echo -e "${CYAN}${BOLD}Options:${RESET}"
    printf "  %-35s %s\n" "-m, --monitor-group <name>" "→ Use this monitor group (skips the monitor group prompt)"
}

# Options: -m|--monitor-group <name> can be given before or after the function name
ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--monitor-group)
            [[ -z "${2:-}" ]] && { echo -e "${RED}$1 needs a monitor group name.${RESET}"; exit 1; }
            PULSE_MONITOR_GROUP="$2"; shift 2 ;;
        --monitor-group=*) PULSE_MONITOR_GROUP="${1#*=}"; shift ;;
        -h|--help) ACTION="--help"; shift ;;
        *) [[ -z "$ACTION" ]] && ACTION="$1" || { echo -e "${RED}Unexpected argument: $1${RESET}"; exit 1; }; shift ;;
    esac
done

show_banner

# run_action <function> - runs it in a subshell so an error inside returns to the menu
run_action() {
    setup                       # connection details + login happen once, in this shell
    ( "$1" )
    local rc=$?
    echo ""
    if [[ $rc -ne 0 ]]; then
        echo -e "${RED}${BOLD}'${1}' finished with errors (exit code ${rc}). See ${LOG_FILE}${RESET}"
    fi
    echo -ne "${GREY}Press Enter to return to the main menu...${RESET}"
    read -r _
    echo ""
}

# Interactive loop - stays in the script until option 7 (Exit)
main_menu() {
    while true; do
        if [[ "$SETUP_DONE" == true ]]; then
            echo -e "${GREY}Connected: ${BASE_URL} | Monitor Group: ${MONITOR_GROUP} | Pulse ${PULSE_VERSION}${RESET}"
        fi
        choose_option "What would you like to do?" 1 \
            "List custom dashboards" \
            "List all dashboards (stock + custom)" \
            "Export custom dashboards" \
            "Export all dashboards" \
            "Import dashboards (latest export in ${BASE_EXPORT_DIR})" \
            "Help" \
            "Exit"
        case "$CHOICE" in
            1) run_action list_custom_dashplot_dashboards ;;
            2) run_action list_all_dashplot_dashboards ;;
            3) run_action export_custom_dashplot_dashboards ;;
            4) run_action export_all_dashplot_dashboards ;;
            5) run_action import_dashplot_dashboards ;;
            6) usage; echo ""; echo -ne "${GREY}Press Enter to return to the main menu...${RESET}"; read -r _; echo "" ;;
            7) echo -e "${CYAN}${BOLD}Bye.${RESET}"; exit 0 ;;
        esac
    done
}

case "${ACTION}" in
    "")                                main_menu ;;
    export_all_dashplot_dashboards)    export_all_dashplot_dashboards ;;
    export_custom_dashplot_dashboards) export_custom_dashplot_dashboards ;;
    list_custom_dashplot_dashboards)   list_custom_dashplot_dashboards ;;
    list_all_dashplot_dashboards)      list_all_dashplot_dashboards ;;
    import_dashplot_dashboards)        import_dashplot_dashboards ;;
    -h|--help)                         usage; exit 0 ;;
    *)                                 echo -e "${RED}Unknown option: ${ACTION}${RESET}\n"; usage; exit 1 ;;
esac
