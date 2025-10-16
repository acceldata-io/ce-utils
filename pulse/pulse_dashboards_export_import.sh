#!/bin/bash
# © 2025 Acceldata Inc. All rights reserved.
set -euo pipefail
###############################################################################
# Usage:
#   ./pulse_dashplot_export_import.sh [function]
#
# Functions:
#   export_all_dashplot_dashboards     - Export all dashboards
#   export_custom_dashplot_dashboards  - Export only custom dashboards
#   list_custom_dashplot_dashboards    - List only custom dashboard names
#   import_dashplot_dashboards         - Import dashboards from ZIPs
#
# Example:
#   ./pulse_dashplot_export_import.sh export_custom_dashplot_dashboards
###############################################################################
# Color definitions
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'
BLUE='\033[0;34m'
GREY='\033[1;90m'
DARK_GREY='\033[1;30m'
NC='\033[0m'  # No Color

 # Determine protocol based on SSL settings
ssl_config_file="${AcceloHome}/config/docker/ad-core.yml"
protocol="http"
if [[ -f "$ssl_config_file" ]]; then
    if egrep -q 'SSL_ENFORCED[:=][[:space:]]*true' "$ssl_config_file" || \
       egrep -q 'SSL_ENABLED[:=][[:space:]]*true' "$ssl_config_file"; then
        protocol="https"
    fi
else
    echo -e "${YELLOW}Warning: SSL config file not found at ${ssl_config_file}. Defaulting to HTTP.${RESET}"
fi
DEFAULT_BASE_URL="${protocol}://$(hostname -f):4000"
DEFAULT_MONITOR_GROUP=""

###############################################################################
# Credentials (can be modified or exported before running)
# You can override PULSE_USERNAME and PULSE_PASSWORD_BASE64 by exporting them before running this script
PULSE_USERNAME="${PULSE_USERNAME:-admin}"
PULSE_PASSWORD_BASE64="${PULSE_PASSWORD_BASE64:-YWRtaW5fcGFzc3dvcmQ=}"  # use "accelo admin encrypt to get encrypted password"

# Global variables
BASE_URL=""
MONITOR_GROUP=""
csrf_token=""
xsrf_token=""
jwt_token_fixed=""

# Flag to ensure setup is performed only once
SETUP_DONE=false

###############################################################################
# Function: check_dependencies
# Purpose : Verify that required commands are available (curl, file)
#-------------------------------------------------------------------------------
check_dependencies() {
    local missing_dependencies=0
    for cmd in curl file; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}${BOLD}Error:${RESET} Command '$cmd' not found. Please install it."
            missing_dependencies=1
        fi
    done
    if [ $missing_dependencies -ne 0 ]; then
        exit 1
    fi
}

###############################################################################
# Function: get_pulse_details
# Purpose : Prompt the user to enter the BASE_URL and Monitor Group
###############################################################################
get_pulse_details() {
    echo -ne "${YELLOW}${BOLD}Enter the hostname for Pulse [default: ${MAGENTA}${DEFAULT_BASE_URL}${RESET}${YELLOW}${BOLD}]: ${RESET}"
    read -r input_base_url
    BASE_URL="${input_base_url:-$DEFAULT_BASE_URL}"
    # Normalize BASE_URL to ensure proper schema
    if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
        echo -ne "${YELLOW}Is Pulse running with HTTPS? (y/N): ${RESET}"
        read -r use_https
        if [[ "$use_https" =~ ^[Yy]$ ]]; then
            BASE_URL="https://${BASE_URL}"
        else
            BASE_URL="http://${BASE_URL}"
        fi
    fi
    echo -e "${CYAN}${BOLD}Using BASE_URL: ${MAGENTA}${BASE_URL}${RESET}"
    # Determine default Monitor Group from the work directory if it exists
    if [ -d "${AcceloHome}/work" ]; then
        DEFAULT_MONITOR_GROUP=$(ls -1 "${AcceloHome}/work" 2>/dev/null | grep -v "license" | head -n 1)
        echo -ne "${YELLOW}${BOLD}Detected Monitor Group: ${MAGENTA}${DEFAULT_MONITOR_GROUP}${RESET}${YELLOW}${BOLD} - Enter Monitor Group [default: ${MAGENTA}${DEFAULT_MONITOR_GROUP}${RESET}${YELLOW}${BOLD}]: ${RESET}"
    else
        DEFAULT_MONITOR_GROUP="default_group"
        echo -e "${YELLOW}${BOLD}Directory ${AcceloHome}/work does not exist. Please provide Monitor Group.${RESET}"
        echo -ne "${YELLOW}${BOLD}Enter Monitor Group [default: ${MAGENTA}${DEFAULT_MONITOR_GROUP}${RESET}${YELLOW}${BOLD}]: ${RESET}"
    fi
    read -r input_monitor_group
    MONITOR_GROUP="${input_monitor_group:-$DEFAULT_MONITOR_GROUP}"
    echo -e "${CYAN}${BOLD}Using Monitor Group: ${MAGENTA}${MONITOR_GROUP}${RESET}"
}
# Send curl request with --insecure and silent mode, allows for replacement in all dashboard functions
send_curl_request() {
    curl -s --insecure "$@"
}

###############################################################################
# Function: fetch_csrf_tokens
# Purpose : Retrieve CSRF tokens from the Pulse endpoint
###############################################################################
fetch_csrf_tokens() {
    echo -e "${DARK_GREY}${BOLD}Fetching CSRF tokens from ${BASE_URL}/csrfEndpoint...${RESET}"
    local csrf_response
    csrf_response=$(curl -s -i --insecure "${BASE_URL}/csrfEndpoint")
    echo "$csrf_response" > /tmp/csrf_dump.txt
    csrf_token=$(echo "$csrf_response" | grep -oP '_csrf=\K[^;]*')
    xsrf_token=$(echo "$csrf_response" | grep -oP 'XSRF-TOKEN=\K[^;]*')

    if [[ -z "$csrf_token" || -z "$xsrf_token" ]]; then
        echo -e "${RED}${BOLD}Failed to retrieve CSRF tokens.${RESET}"
        exit 1
    fi
    echo -e "${GREY}${BOLD}CSRF tokens retrieved successfully.${RESET}"
}

###############################################################################
# Function: fetch_jwt_token
# Purpose : Retrieve JWT token via the login endpoint
###############################################################################
fetch_jwt_token() {
    echo -e "${DARK_GREY}${BOLD}Fetching JWT token from ${BASE_URL}/login...${RESET}"
    local login_response
    login_response=$(curl -s -i --insecure "${BASE_URL}/login" \
      -H "Content-Type: application/json" \
      --data-raw "{\"email\":\"${PULSE_USERNAME}\",\"password\":\"${PULSE_PASSWORD_BASE64}\"}")
    local jwt_token
    jwt_token=$(echo "$login_response" | grep -oP 'jwt=\K[^;]*')
    jwt_token_fixed=$(echo "$jwt_token" | sed 's/%3A/:/g')

    if [[ -z "$jwt_token_fixed" ]]; then
        echo -e "${RED}${BOLD}Failed to retrieve JWT token.${RESET}"
        exit 1
    fi
    echo -e "${GREY}${BOLD}JWT token retrieved successfully.${RESET}"
}

###############################################################################
# Function: perform_curl_request
# Purpose : Execute a common curl request to the GraphQL endpoint
# Arguments:
#   $1 - Endpoint (not used directly here, but kept for extensibility)
#   $2 - JSON data payload
#   $3 - Additional headers (if any)
###############################################################################
perform_curl_request() {
    local endpoint="$1"
    local data="$2"
    local additional_headers="$3"

    local response
    response=$(curl -s --insecure "${BASE_URL}/graphql" \
      -H "Accept: application/json, text/plain, */*" \
      -H "Content-Type: application/json" \
      -H "Cookie: application=pulse; _csrf=${csrf_token}; jwt=${jwt_token_fixed}; XSRF-TOKEN=${xsrf_token}" \
      -H "MonitorGroup: ${MONITOR_GROUP}" \
      -H "X-XSRF-TOKEN: ${xsrf_token}" \
      -H "role: e30=" \
      $additional_headers \
      --data-raw "$data")

    if [ $? -ne 0 ]; then
        echo -e "${RED}${BOLD}API request failed.${RESET}"
        exit 1
    fi

    echo -e "${GREEN}${BOLD}API request completed successfully.${RESET}"
}

###############################################################################
# Function: setup
# Purpose : Run initial setup steps (dependencies check, prompt details, fetch tokens)
###############################################################################
setup() {
    if [ "$SETUP_DONE" = false ]; then
        check_dependencies
        get_pulse_details
        fetch_csrf_tokens
        fetch_jwt_token
        SETUP_DONE=true
    fi
}

###############################################################################
# Default Storage Configuration
###############################################################################
DASHBOARD_LIST=""
LOG_FILE=""
# Allow override of storage directory via environment variable
STORAGE_DIR="${STORAGE_DIR:-$(pwd)/pulse_exports}"
[[ -w "$(pwd)" ]] || STORAGE_DIR="${HOME}/pulse_exports"
DASHBOARD_LIST="${STORAGE_DIR}/dashboards_list.txt"
LOG_FILE="${STORAGE_DIR}/pulse_migration.log"

# Ensure the storage directory exists
mkdir -p "$STORAGE_DIR"
# Check if storage directory is writable
if [[ ! -w "$STORAGE_DIR" ]]; then
    echo -e "${RED}${BOLD}Error:${RESET} Cannot write to storage directory: $STORAGE_DIR"
    exit 1
fi

###############################################################################
# Function: export_all_dashplot_dashboards
# Purpose : Fetch and export Dashplot dashboards as ZIP archives
###############################################################################
export_all_dashplot_dashboards() {
    setup  # Ensure initial setup is complete
    echo -e "${CYAN}${BOLD}Fetching and Exporting Dashplot Dashboards...${RESET}" | tee -a "$LOG_FILE"
    local url="${BASE_URL}/dashplots/def/visualizations?sortOrder=1&sortColumn=name&pageNo=1&pageSize=900"
    # Fetch dashboard names and store them in a file
    send_curl_request "$url" \
        -H "Accept: application/json, text/plain, */*" \
        -H "MonitorGroup: ${MONITOR_GROUP}" \
        -H "ad-dashplot-app: pulse" \
        -H "role: e30=" \
        -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
        | grep dashplot_name | sed -E 's/.*"dashplot_name" : "(.*)".*/\1/' | sort | uniq > "$DASHBOARD_LIST"
    if [[ ! -s "$DASHBOARD_LIST" ]]; then
        echo -e "${RED}${BOLD}Error: No dashboards found.${RESET}" | tee -a "$LOG_FILE"
        exit 1
    fi
    # Remove any empty lines from the dashboard list
    sed -i '/^$/d' "$DASHBOARD_LIST"
    echo -e "${GREEN}Dashboards fetched successfully. Stored in: ${DASHBOARD_LIST}${RESET}" | tee -a "$LOG_FILE"
    # Export each dashboard
    while IFS= read -r dashboard; do
        local export_url="${BASE_URL}/dashplots/export"
        local output_file="${STORAGE_DIR}/${dashboard}.zip"
        echo -e "${YELLOW}Exporting: ${dashboard}...${RESET}" | tee -a "$LOG_FILE"
        send_curl_request "$export_url" \
            -H "Accept: application/json, text/plain, */*" \
            -H "Content-Type: application/json" \
            -H "MonitorGroup: ${MONITOR_GROUP}" \
            -H "ad-dashplot-app: pulse" \
            -H "role: e30=" \
            -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
            --data-raw "{\"nodeName\":\"$dashboard\"}" \
            --output "$output_file"
        if [[ -s "$output_file" && $(file "$output_file") =~ "Zip archive data" ]]; then
            echo -e "${GREEN}Exported: ${dashboard} -> ${output_file}${RESET}" | tee -a "$LOG_FILE"
        else
            echo -e "${RED}Failed to export: ${dashboard}${RESET}" | tee -a "$LOG_FILE"
            rm -f "$output_file"  # Remove corrupted file if any
        fi
    done < "$DASHBOARD_LIST"
    echo -e "${GREEN}${BOLD}Export process completed!${RESET}" | tee -a "$LOG_FILE"
}

export_custom_dashplot_dashboards() {
    setup  # Ensure initial setup is complete
    echo -e "${CYAN}${BOLD}Fetching and Exporting Custom Dashplot Dashboards...${RESET}" | tee -a "$LOG_FILE"
    local url="${BASE_URL}/dashplots/def/visualizations?sortOrder=1&sortColumn=name&pageNo=1&pageSize=900"
    # Fetch dashboard names and exclude default dashboards
    send_curl_request "$url" \
        -H "Accept: application/json, text/plain, */*" \
        -H "MonitorGroup: ${MONITOR_GROUP}" \
        -H "ad-dashplot-app: pulse" \
        -H "role: e30=" \
        -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
        | grep dashplot_name | sed -E 's/.*"dashplot_name" : "(.*)".*/\1/' | \
        grep -v -E '^(Airflow|CRUISE-CONTROL|CRUISE-CONTROL3|DRUID-DASHBOARD|HBASE-SERVICES|HDFS-DASHBOARD-NEW|HDFS-IO-METRICS|HIVE-SERVICE-NEW|HIVE-TABLE-USER|IMPALA-DAEMONS|KAFKA3-CONNECT|Kafka3-MirrorMaker-2|KAFKA-CONNECT|MirrorMaker-2|OZONE-DASHBOARD|PULSE-AGENT-STATS|SCHEMA-REGISTRY|STORAGE-IO-METRICS|YARN-NEW-DASHBOARD|YARN-OPTIMIZER-DASHBOARD|YARN-QUEUE-DASHBOARD)$' \
        | sort | uniq > "$DASHBOARD_LIST"
    if [[ ! -s "$DASHBOARD_LIST" ]]; then
        echo -e "${RED}${BOLD}Error: No custom dashboards found.${RESET}" | tee -a "$LOG_FILE"
        exit 1
    fi
    sed -i '/^$/d' "$DASHBOARD_LIST"
    echo -e "${GREEN}Custom dashboards fetched successfully. Stored in: ${DASHBOARD_LIST}${RESET}" | tee -a "$LOG_FILE"
    while IFS= read -r dashboard; do
        local export_url="${BASE_URL}/dashplots/export"
        local output_file="${STORAGE_DIR}/${dashboard}.zip"
        echo -e "${YELLOW}Exporting: ${dashboard}...${RESET}" | tee -a "$LOG_FILE"
        send_curl_request "$export_url" \
            -H "Accept: application/json, text/plain, */*" \
            -H "Content-Type: application/json" \
            -H "MonitorGroup: ${MONITOR_GROUP}" \
            -H "ad-dashplot-app: pulse" \
            -H "role: e30=" \
            -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
            --data-raw "{\"nodeName\":\"$dashboard\"}" \
            --output "$output_file"
        if [[ -s "$output_file" && $(file "$output_file") =~ "Zip archive data" ]]; then
            echo -e "${GREEN}Exported: ${dashboard} -> ${output_file}${RESET}" | tee -a "$LOG_FILE"
        else
            echo -e "${RED}Failed to export: ${dashboard}${RESET}" | tee -a "$LOG_FILE"
            rm -f "$output_file"
        fi
    done < "$DASHBOARD_LIST"
    echo -e "${GREEN}${BOLD}Custom Export process completed!${RESET}" | tee -a "$LOG_FILE"
}

#-----------------------------------------------------------------------------
# Function: list_custom_dashplot_dashboards
# Description: Fetches all dashboards, filters out known defaults,
#              and writes only custom names to $DASHBOARD_LIST.
# Usage:       list_custom_dashplot_dashboards
#-----------------------------------------------------------------------------
list_custom_dashplot_dashboards() {
    setup  # Ensure initial setup is complete
    echo -e "${BLUE}Listing custom dashboards only...${RESET}" | tee -a "$LOG_FILE"
    local url="${BASE_URL}/dashplots/def/visualizations?sortOrder=1&sortColumn=name&pageNo=1&pageSize=900"
    send_curl_request "$url" \
        -H "Accept: application/json, text/plain, */*" \
        -H "MonitorGroup: ${MONITOR_GROUP}" \
        -H "ad-dashplot-app: pulse" \
        -H "role: e30=" \
        -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
        | grep dashplot_name | \
        sed -E 's/.*"dashplot_name" : "(.*)".*/\1/' | \
        grep -v -E '^(Airflow|CRUISE-CONTROL|CRUISE-CONTROL3|DRUID-DASHBOARD|HBASE-SERVICES|HDFS-DASHBOARD-NEW|HDFS-IO-METRICS|HIVE-SERVICE-NEW|HIVE-TABLE-USER|IMPALA-DAEMONS|KAFKA3-CONNECT|Kafka3-MirrorMaker-2|KAFKA-CONNECT|MirrorMaker-2|OZONE-DASHBOARD|PULSE-AGENT-STATS|SCHEMA-REGISTRY|STORAGE-IO-METRICS|YARN-NEW-DASHBOARD|YARN-OPTIMIZER-DASHBOARD|YARN-QUEUE-DASHBOARD)$' | \
        sort | uniq > "$DASHBOARD_LIST"
    if [[ ! -s "$DASHBOARD_LIST" ]]; then
        echo -e "${RED}${BOLD}Error: No custom dashboards found.${RESET}" | tee -a "$LOG_FILE"
        exit 1
    fi
    echo -e "${GREEN}Custom dashboards names written to:${RESET} $DASHBOARD_LIST" | tee -a "$LOG_FILE"
}

###############################################################################
# Function: import_dashplot_dashboards
# Purpose : Import exported Dashplot dashboards from ZIP files
###############################################################################
import_dashplot_dashboards() {
    setup  # Ensure initial setup is complete
    echo -e "${CYAN}${BOLD}Starting Import Process...${RESET}" | tee -a "$LOG_FILE"
    if [[ ! -f "$DASHBOARD_LIST" ]]; then
        echo -e "${RED}${BOLD}Error: Dashboard list file not found. Please run the export process first.${RESET}" | tee -a "$LOG_FILE"
        exit 1
    fi
    # Clean blank lines from dashboard list
    sed -i '/^\s*$/d' "$DASHBOARD_LIST"
    # Import each exported dashboard
    while IFS= read -r dashboard; do
        local zip_file="${STORAGE_DIR}/${dashboard}.zip"
        local import_url="${BASE_URL}/dashplots/import?overwrite=true"
        if [[ ! -f "$zip_file" ]]; then
            echo -e "${RED}Skipped: ${dashboard} (ZIP file not found)${RESET}" | tee -a "$LOG_FILE"
            continue
        fi
        echo -e "${YELLOW}Importing: ${dashboard}...${RESET}" | tee -a "$LOG_FILE"
        local response
        response=$(send_curl_request -w "\n%{http_code}" "$import_url" \
            -H "Accept: application/json, text/plain, */*" \
            -H "MonitorGroup: ${MONITOR_GROUP}" \
            -H "ad-dashplot-app: pulse" \
            -H "role: e30=" \
            -H "Cookie: application=pulse; jwt=${jwt_token_fixed}" \
            -F "file=@${zip_file}")
        local http_status
        http_status=$(echo "$response" | tail -n1)
        local response_body
        response_body=$(echo "$response" | sed '$d')
        if [[ "$http_status" =~ ^[0-9]+$ && "$http_status" -eq 200 ]]; then
            echo -e "${GREEN}Successfully imported: ${dashboard}${RESET}" | tee -a "$LOG_FILE"
        else
            echo -e "${RED}Failed to import: ${dashboard} (HTTP ${http_status})${RESET}" | tee -a "$LOG_FILE"
            echo "$response_body" | tee -a "$LOG_FILE"
        fi
    done < "$DASHBOARD_LIST"
    echo -e "${GREEN}${BOLD}Import process completed!${RESET}" | tee -a "$LOG_FILE"
}

# Define color variables (if not already defined)
YELLOW="\033[1;33m"
RESET="\033[0m"

usage() {
  echo -e "${YELLOW}${BOLD}Usage:${RESET} ./$(basename "$0") <function>"
  echo ""
  echo -e "${CYAN}${BOLD}Available functions:${RESET}"
  echo ""
  printf "  %-35s %s\n" "export_all_dashplot_dashboards"    "→ Export all dashboards (Default + Custom)"
  printf "  %-35s %s\n" "export_custom_dashplot_dashboards" "→ Export only custom dashboards"
  printf "  %-35s %s\n" "list_custom_dashplot_dashboards"   "→ List names of only custom dashboards"
  printf "  %-35s %s\n" "import_dashplot_dashboards"        "→ Import dashboards from previously exported ZIPs"
  echo ""
  echo -e "${CYAN}${BOLD}Examples:${RESET}"
  echo "  ./$(basename "$0") export_custom_dashplot_dashboards"
  echo "  ./$(basename "$0") import_dashplot_dashboards"
}

###############################################################################
# Main Execution
###############################################################################
if [ $# -eq 0 ]; then
    usage
    exit 1
fi
case "${1:-}" in
    export_all_dashplot_dashboards)
        export_all_dashplot_dashboards
        ;;
    export_custom_dashplot_dashboards)
        export_custom_dashplot_dashboards
        ;;
    list_custom_dashplot_dashboards)
        list_custom_dashplot_dashboards
        ;;
    import_dashplot_dashboards)
        import_dashplot_dashboards
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac
