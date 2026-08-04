#!/bin/bash
#==============================================================================
# Enhanced Solr Admin API Tools Script
# Description: Comprehensive Solr cluster management and administration tool
# Copyright (c) 2026 Acceldata Inc. All rights reserved.
#==============================================================================
set -euo pipefail

# Configuration and Constants
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
#CONFIG_FILE="/etc/ambari-infra-solr/conf/infra-solr-env.sh"
LOG_FILE="${SCRIPT_DIR}/solr-admin.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
BOLD='\033[1m'
DIM='\033[2m'
UNDERLINE='\033[4m'
BLINK='\033[5m'
NC='\033[0m' # No Color

# Background colors
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'
BG_CYAN='\033[46m'

# Default configuration (can be overridden by config file or environment variables)
SOLR_HOST="${SOLR_ADMIN_HOST:-$(hostname -f)}"
SOLR_PORT="${SOLR_ADMIN_PORT:-8886}"
# Auto-detect protocol based on infra-solr-env.sh
SOLR_ENV_FILE="/etc/ambari-infra-solr/conf/infra-solr-env.sh"
if grep -qE '^[[:space:]]*SOLR_SSL_KEY_STORE[[:space:]]*=' "$SOLR_ENV_FILE" 2>/dev/null; then
    SOLR_PROTOCOL="https"
else
    SOLR_PROTOCOL="http"
fi
SOLR_URL="${SOLR_PROTOCOL}://${SOLR_HOST}:${SOLR_PORT}/solr"
KEYTAB_PATH="${SOLR_KEYTAB_PATH:-/etc/security/keytabs/ambari-infra-solr.service.keytab}"
BACKUP_LOCATION="${SOLR_BACKUP_LOCATION:-/hadoop/ambari-infra-solr/data/backups}"
DEFAULT_OUTPUT_FORMAT="${SOLR_OUTPUT_FORMAT:-pretty}"

# Global variables
INTERACTIVE_MODE=true
COLLECTION_NAME=""
ACTION=""
CURL_OPTS=""

#==============================================================================
# Logging Functions
#==============================================================================

log_with_timestamp() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="${timestamp} ${level} ${message}"
    echo -e "$log_entry"
    echo "${timestamp} $(echo "$level" | sed 's/\x1b\[[0-9;]*m//g') ${message}" >>"$LOG_FILE"
}

log_info() {
    log_with_timestamp "${CYAN}${BOLD}ℹ [INFO]${NC}" "$1"
}

log_warn() {
    log_with_timestamp "${YELLOW}${BOLD}⚠ [WARN]${NC}" "$1"
}

log_error() {
    log_with_timestamp "${RED}${BOLD}✖ [ERROR]${NC}" "$1"
}

log_success() {
    log_with_timestamp "${GREEN}${BOLD}✔ [SUCCESS]${NC}" "$1"
}

log_cmd() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_with_timestamp "${PURPLE}${BOLD}⚙ [CMD]${NC}" "$1"
    fi
}

print_header() {
    local title="$1"
    local width=80
    echo -e "\n${BOLD}${CYAN}╔$(printf '═%.0s' $(seq 1 $((width-2))))╗${NC}"
    printf "${BOLD}${CYAN}║${NC} ${WHITE}%-$((width-4))s${NC} ${BOLD}${CYAN}║${NC}\n" "$title"
    echo -e "${BOLD}${CYAN}╚$(printf '═%.0s' $(seq 1 $((width-2))))╝${NC}\n"
}

print_section() {
    local title="$1"
    echo -e "\n${BOLD}${BLUE}▌ ${title}${NC}"
    echo -e "${BLUE}$(printf '─%.0s' $(seq 1 78))${NC}"
}

#==============================================================================
# Configuration Management
#==============================================================================

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        log_info "Configuration loaded from $CONFIG_FILE"
    else
        log_info "Using default configuration"
    fi
}

#==============================================================================
# Validation Functions
#==============================================================================

validate_collection_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Collection name must contain only alphanumeric characters, hyphens, and underscores."
        return 1
    fi
    return 0
}

validate_numeric_input() {
    local value="$1"
    local name="$2"
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -eq 0 ]]; then
        log_error "$name must be a positive integer."
        return 1
    fi
    return 0
}

validate_url() {
    local url="$1"
    if ! curl -s -k --max-time 5 "$url/admin/info/system" >/dev/null 2>&1; then
        log_error "Cannot connect to Solr at $url"
        return 1
    fi
    return 0
}

#==============================================================================
# Authentication and Connection Setup
#==============================================================================

setup_authentication() {
    if [[ -f "$KEYTAB_PATH" ]]; then
        log_info "Setting up Kerberos authentication..."
        local resolved_principal=$(klist -kt "$KEYTAB_PATH" | sed -n "4p" | awk '{print $NF}')
        log_info "Resolved principal from keytab: $resolved_principal"
        kinit -kt "$KEYTAB_PATH" "$resolved_principal" 2>/dev/null || {
            log_error "Failed to authenticate with Kerberos"
            exit 1
        }
        CURL_OPTS="-k --negotiate -u :"
        log_success "Kerberos authentication successful"
    else
        log_warn "Keytab not found at $KEYTAB_PATH, using insecure connection"
        CURL_OPTS="-k"
    fi
}

show_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════════════════════════════════════════╗
║                                                                               ║
║   ███████╗ ██████╗ ██╗     ██████╗      █████╗ ██████╗ ███╗   ███╗██╗███╗   ██╗║
║   ██╔════╝██╔═══██╗██║     ██╔══██╗    ██╔══██╗██╔══██╗████╗ ████║██║████╗  ██║║
║   ███████╗██║   ██║██║     ██████╔╝    ███████║██║  ██║██╔████╔██║██║██╔██╗ ██║║
║   ╚════██║██║   ██║██║     ██╔══██╗    ██╔══██║██║  ██║██║╚██╔╝██║██║██║╚██╗██║║
║   ███████║╚██████╔╝███████╗██║  ██║    ██║  ██║██████╔╝██║ ╚═╝ ██║██║██║ ╚████║║
║   ╚══════╝ ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝  ╚═╝╚═════╝ ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝║
║                                                                               ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

test_connection() {
    print_section "CONNECTION TEST"
    log_info "Testing connection to Solr at ${BOLD}${WHITE}$SOLR_URL${NC}"

    if validate_url "$SOLR_URL"; then
        log_success "Connection to Solr successful"
        echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    else
        log_error "Failed to connect to Solr"
        echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        exit 1
    fi
}

#==============================================================================
# API Helper Functions
#==============================================================================

authorization_status() {
    log_info "Fetching Solr authorization status..."
    run_api "$SOLR_URL/admin/authorization"
}

run_api() {
    local url="$1"
    local method="${2:-GET}"
    local data="${3:-}"
    local http_code
    local response
    local temp_file=$(mktemp)
    local start_time=$(date +%s%N)

    # Show a prominent command box
    echo -e "\n${BOLD}${BG_CYAN}${WHITE}                                CURL COMMAND                                ${NC}"
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"

    if [[ -n "$data" ]]; then
        echo -e "${GREEN}${BOLD}  curl -X ${method} ${CURL_OPTS} \\${NC}"
        echo -e "${GREEN}    -H \"Content-Type: application/json\" \\${NC}"
        echo -e "${GREEN}    -d '${data}' \\${NC}"
        echo -e "${GREEN}    \"${url}\"${NC}"
    else
        echo -e "${GREEN}${BOLD}  curl -X ${method} ${CURL_OPTS} \"${url}\"${NC}"
    fi

    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    # Optionally log the command if debug enabled
    if [[ "${DEBUG:-false}" == "true" ]]; then
        if [[ -n "$data" ]]; then
            log_with_timestamp "${PURPLE}${BOLD}⚙ [CMD]${NC}" "curl -X $method $CURL_OPTS -H \"Content-Type: application/json\" -d '$data' \"$url\""
        else
            log_with_timestamp "${PURPLE}${BOLD}⚙ [CMD]${NC}" "curl -X $method $CURL_OPTS \"$url\""
        fi
    fi

    # Show executing indicator
    echo -e "${YELLOW}${BOLD}⏳ Executing...${NC}"

    if [[ -n "$data" ]]; then
        response=$(curl -s -w "%{http_code}" -X "$method" $CURL_OPTS -H "Content-Type: application/json" -d "$data" "$url" --output "$temp_file" 2>&1)
    else
        response=$(curl -s -w "%{http_code}" -X "$method" $CURL_OPTS "$url" --output "$temp_file" 2>&1)
    fi

    local end_time=$(date +%s%N)
    local duration=$(((end_time - start_time) / 1000000))

    http_code="${response: -3}"
    response_body=$(cat "$temp_file")
    rm -f "$temp_file"

    # Show response header with status
    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo -e "\n${BOLD}${BG_GREEN}${WHITE}                         RESPONSE (HTTP ${http_code}) - ${duration}ms                         ${NC}"
    elif [[ "$http_code" -ge 400 ]]; then
        echo -e "\n${BOLD}${BG_RED}${WHITE}                         RESPONSE (HTTP ${http_code}) - ${duration}ms                         ${NC}"
    else
        echo -e "\n${BOLD}${BG_YELLOW}${WHITE}                         RESPONSE (HTTP ${http_code}) - ${duration}ms                         ${NC}"
    fi

    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"

    if [[ "$http_code" -ge 400 ]]; then
        log_error "HTTP $http_code error occurred"
        echo -e "${RED}${response_body}${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
        return 1
    fi

    echo -e "${WHITE}"
    format_json_output "$response_body" "$DEFAULT_OUTPUT_FORMAT"
    echo -e "${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"

    log_success "Request completed in ${duration}ms"
    return 0
}

format_json_output() {
    local response="$1"
    local format="${2:-pretty}"

    case "$format" in
    "pretty")
        echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
        ;;
    "compact")
        echo "$response" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin), separators=(',', ':')))" 2>/dev/null || echo "$response"
        ;;
    "raw")
        echo "$response"
        ;;
    esac
}

#==============================================================================
# Collection Management Functions
#==============================================================================

list_collections() {
    log_info "Fetching collection list..."
    run_api "$SOLR_URL/admin/collections?action=LIST&wt=json"
}

create_ranger_audits_collection() {
    local numShards replicationFactor configName="ranger_audits"
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Number of shards for ranger_audits [default: 1]: " numShards
        read -r -p "Replication factor for ranger_audits [default: 1]: " replicationFactor
    else
        numShards="${NUM_SHARDS:-1}"
        replicationFactor="${REPLICATION_FACTOR:-1}"
    fi
    numShards=${numShards:-1}
    replicationFactor=${replicationFactor:-1}
    if validate_numeric_input "$numShards" "Number of shards" && validate_numeric_input "$replicationFactor" "Replication factor"; then
        log_info "Creating collection 'ranger_audits'..."
        run_api "$SOLR_URL/admin/collections?action=CREATE&name=ranger_audits&numShards=$numShards&replicationFactor=$replicationFactor&collection.configName=$configName&wt=json"
    fi
}

delete_ranger_audits_collection() {
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Are you sure you want to delete 'ranger_audits' collection? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Collection deletion cancelled"
            return 0
        fi
    fi
    log_info "Deleting collection 'ranger_audits'..."
    run_api "$SOLR_URL/admin/collections?action=DELETE&name=ranger_audits&wt=json"
}

reload_collection() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name to reload: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Reloading collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=RELOAD&name=$cname&wt=json"
    fi
}

backup_collection() {
    local cname backup_name location

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Backup name: " backup_name
        read -r -p "Backup location [default: $BACKUP_LOCATION]: " location
    else
        cname="$COLLECTION_NAME"
        backup_name="${BACKUP_NAME:-backup-$(date +%Y%m%d-%H%M%S)}"
        location="${BACKUP_LOCATION}"
    fi

    location=${location:-$BACKUP_LOCATION}

    # ===== Check/prepare backup directory =====
    if [[ ! -d "$location" ]]; then
        log_warn "Backup directory $location does not exist. Attempting to create it..."
        mkdir -p "$location" 2>/dev/null
        if [[ $? -ne 0 ]]; then
            log_error "Failed to create backup directory: $location"
            return 1
        fi
    fi

    # Always attempt to correct permissions
    chown -R infra-solr:hadoop "$location" 2>/dev/null
    chmod 755 -R "$location" 2>/dev/null

    if [[ ! -w "$location" ]]; then
        log_error "Backup directory $location is not writable by user $(whoami)."
        log_error "Please fix permissions (e.g., sudo chown -R solr:solr $location) and try again."
        return 1
    fi
    # ===== End check/prepare backup directory =====

    if validate_collection_name "$cname" && [[ -n "$backup_name" ]]; then
        log_info "Creating backup '$backup_name' for collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=BACKUP&name=$backup_name&collection=$cname&location=$location&wt=json"
    fi
}

restore_collection() {
    local backup_name cname location

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Backup name: " backup_name
        read -r -p "Collection name for restore: " cname
        read -r -p "Backup location [default: $BACKUP_LOCATION]: " location
    else
        backup_name="$BACKUP_NAME"
        cname="$COLLECTION_NAME"
        location="${BACKUP_LOCATION}"
    fi

    location=${location:-$BACKUP_LOCATION}

    if [[ -n "$backup_name" ]] && validate_collection_name "$cname"; then
        log_info "Restoring collection '$cname' from backup '$backup_name'..."
        run_api "$SOLR_URL/admin/collections?action=RESTORE&name=$backup_name&collection=$cname&location=$location&wt=json"
    fi
}

create_collection() {
    local cname numShards replicationFactor configName

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Number of shards [default: 1]: " numShards
        read -r -p "Replication factor [default: 1]: " replicationFactor
        read -r -p "Config name: " configName
    else
        cname="$COLLECTION_NAME"
        numShards="${NUM_SHARDS:-1}"
        replicationFactor="${REPLICATION_FACTOR:-1}"
        configName="${CONFIG_NAME:-}"
    fi

    numShards=${numShards:-1}
    replicationFactor=${replicationFactor:-1}

    if validate_collection_name "$cname" && validate_numeric_input "$numShards" "Number of shards" && validate_numeric_input "$replicationFactor" "Replication factor"; then
        log_info "Creating collection '$cname'..."
        local url="$SOLR_URL/admin/collections?action=CREATE&name=$cname&numShards=$numShards&replicationFactor=$replicationFactor&wt=json"

        if [[ -n "$configName" ]]; then
            url="$url&collection.configName=$configName"
        fi

        run_api "$url"
    fi
}

delete_collection() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name to delete: " cname
        read -r -p "Are you sure you want to delete '$cname' collection? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Collection deletion cancelled"
            return 0
        fi
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Deleting collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=DELETE&name=$cname&wt=json"
    fi
}

query_collection() {
    local cname query rows fields sort

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Query [default: *:*]: " query
        read -r -p "Number of rows [default: 10]: " rows
        read -r -p "Fields to return (comma-separated, leave empty for all): " fields
        read -r -p "Sort field (e.g., 'evtTime desc', leave empty for default): " sort
    else
        cname="$COLLECTION_NAME"
        query="${QUERY:-*:*}"
        rows="${ROWS:-10}"
        fields="${FIELDS:-}"
        sort="${SORT:-}"
    fi

    query=${query:-"*:*"}
    rows=${rows:-10}

    if validate_collection_name "$cname" && validate_numeric_input "$rows" "Number of rows"; then
        log_info "Querying collection '$cname' with query: $query"

        local url="$SOLR_URL/$cname/select?q=$query&rows=$rows&wt=json"

        if [[ -n "$fields" ]]; then
            url="$url&fl=$fields"
        fi

        if [[ -n "$sort" ]]; then
            url="$url&sort=$sort"
        fi

        run_api "$url"
    fi
}

query_collection_advanced() {
    local cname query rows fields sort fq facet

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Query [default: *:*]: " query
        read -r -p "Filter query (fq, optional): " fq
        read -r -p "Number of rows [default: 10]: " rows
        read -r -p "Fields to return (comma-separated, leave empty for all): " fields
        read -r -p "Sort field (e.g., 'evtTime desc', leave empty for default): " sort
        read -r -p "Facet field (optional): " facet
    else
        cname="$COLLECTION_NAME"
        query="${QUERY:-*:*}"
        fq="${FILTER_QUERY:-}"
        rows="${ROWS:-10}"
        fields="${FIELDS:-}"
        sort="${SORT:-}"
        facet="${FACET:-}"
    fi

    query=${query:-"*:*"}
    rows=${rows:-10}

    if validate_collection_name "$cname" && validate_numeric_input "$rows" "Number of rows"; then
        log_info "Executing advanced query on collection '$cname'"

        local url="$SOLR_URL/$cname/select?q=$query&rows=$rows&wt=json"

        if [[ -n "$fq" ]]; then
            url="$url&fq=$fq"
        fi

        if [[ -n "$fields" ]]; then
            url="$url&fl=$fields"
        fi

        if [[ -n "$sort" ]]; then
            url="$url&sort=$sort"
        fi

        if [[ -n "$facet" ]]; then
            url="$url&facet=true&facet.field=$facet"
        fi

        run_api "$url"
    fi
}

get_collection_stats() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Fetching statistics for collection '$cname'..."

        # Get document count
        log_info "Document count:"
        run_api "$SOLR_URL/$cname/select?q=*:*&rows=0&wt=json"

        echo

        # Get collection status with details
        log_info "Collection details:"
        run_api "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&collection=$cname&wt=json"
    fi
}

get_collection_schema() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Fetching schema for collection '$cname'..."
        run_api "$SOLR_URL/$cname/schema?wt=json"
    fi
}

get_collection_fields() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Fetching fields for collection '$cname'..."
        run_api "$SOLR_URL/$cname/schema/fields?wt=json"
    fi
}

delete_documents_by_query() {
    local cname query

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Delete query (e.g., 'status:inactive' or '*:*' for all): " query
        read -r -p "Are you sure you want to delete documents matching '$query'? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Document deletion cancelled"
            return 0
        fi
    else
        cname="$COLLECTION_NAME"
        query="${DELETE_QUERY:-}"
    fi

    if validate_collection_name "$cname" && [[ -n "$query" ]]; then
        log_info "Deleting documents from collection '$cname' matching query: $query"

        local data="<delete><query>$query</query></delete>"
        local delete_url="$SOLR_URL/$cname/update?commit=true&wt=json"

        echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║ CURL COMMAND:                                                              ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
        echo -e "${GREEN}curl -X POST $CURL_OPTS -H \"Content-Type: text/xml\" \\"
        echo -e "  --data-binary '$data' \\"
        echo -e "  \"$delete_url\"${NC}\n"

        local http_code
        local response
        local temp_file=$(mktemp)

        response=$(curl -s -w "%{http_code}" -X POST $CURL_OPTS -H "Content-Type: text/xml" --data-binary "$data" "$delete_url" --output "$temp_file")
        http_code="${response: -3}"
        response_body=$(cat "$temp_file")
        rm -f "$temp_file"

        echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║ RESPONSE (HTTP $http_code):                                                    ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

        if [[ "$http_code" -ge 400 ]]; then
            log_error "HTTP $http_code error occurred"
            echo -e "${RED}${response_body}${NC}"
            return 1
        fi

        echo -e "${YELLOW}"
        format_json_output "$response_body" "$DEFAULT_OUTPUT_FORMAT"
        echo -e "${NC}"
        log_success "Documents deleted successfully"
    fi
}

optimize_collection() {
    local cname maxSegments

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Max segments (default: 1 for full optimization): " maxSegments
    else
        cname="$COLLECTION_NAME"
        maxSegments="${MAX_SEGMENTS:-1}"
    fi

    maxSegments=${maxSegments:-1}

    if validate_collection_name "$cname"; then
        log_info "Optimizing collection '$cname' to $maxSegments segments..."
        log_warn "Note: Optimization can be resource-intensive on large collections"

        run_api "$SOLR_URL/$cname/update?optimize=true&maxSegments=$maxSegments&wt=json"
    fi
}

create_alias() {
    local alias_name collections

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Alias name: " alias_name
        read -r -p "Collections (comma-separated): " collections
    else
        alias_name="$ALIAS_NAME"
        collections="$ALIAS_COLLECTIONS"
    fi

    if validate_collection_name "$alias_name" && [[ -n "$collections" ]]; then
        log_info "Creating alias '$alias_name' for collections: $collections"
        run_api "$SOLR_URL/admin/collections?action=CREATEALIAS&name=$alias_name&collections=$collections&wt=json"
    fi
}

delete_alias() {
    local alias_name

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Alias name to delete: " alias_name
        read -r -p "Are you sure you want to delete alias '$alias_name'? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            log_info "Alias deletion cancelled"
            return 0
        fi
    else
        alias_name="$ALIAS_NAME"
    fi

    if validate_collection_name "$alias_name"; then
        log_info "Deleting alias '$alias_name'..."
        run_api "$SOLR_URL/admin/collections?action=DELETEALIAS&name=$alias_name&wt=json"
    fi
}

list_aliases() {
    log_info "Fetching aliases list..."
    run_api "$SOLR_URL/admin/collections?action=LISTALIASES&wt=json"
}

get_collection_config() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Fetching configuration for collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&collection=$cname&wt=json"
    fi
}

commit_collection() {
    local cname soft_commit

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Soft commit? (yes/no, default: no): " soft_commit
    else
        cname="$COLLECTION_NAME"
        soft_commit="${SOFT_COMMIT:-no}"
    fi

    if validate_collection_name "$cname"; then
        if [[ "$soft_commit" == "yes" ]]; then
            log_info "Performing soft commit on collection '$cname'..."
            run_api "$SOLR_URL/$cname/update?softCommit=true&wt=json"
        else
            log_info "Performing hard commit on collection '$cname'..."
            run_api "$SOLR_URL/$cname/update?commit=true&wt=json"
        fi
    fi
}

request_collection_status() {
    local cname

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
    else
        cname="$COLLECTION_NAME"
    fi

    if validate_collection_name "$cname"; then
        log_info "Fetching request status for collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=REQUESTSTATUS&collection=$cname&wt=json"
    fi
}

export_collection_config() {
    local cname output_dir

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Output directory [default: /tmp]: " output_dir
    else
        cname="$COLLECTION_NAME"
        output_dir="${OUTPUT_DIR:-/tmp}"
    fi

    output_dir=${output_dir:-/tmp}

    if validate_collection_name "$cname"; then
        log_info "Exporting configuration for collection '$cname' to $output_dir..."

        # Create output directory if it doesn't exist
        mkdir -p "$output_dir" 2>/dev/null

        local config_file="$output_dir/${cname}_config_$(date +%Y%m%d_%H%M%S).json"

        # Export schema
        log_info "Exporting schema..."
        curl -s $CURL_OPTS "$SOLR_URL/$cname/schema?wt=json" > "${config_file%.json}_schema.json"

        # Export config
        log_info "Exporting collection config..."
        curl -s $CURL_OPTS "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&collection=$cname&wt=json" > "$config_file"

        log_success "Configuration exported to:"
        echo "  - Schema: ${config_file%.json}_schema.json"
        echo "  - Config: $config_file"
    fi
}

get_live_nodes() {
    log_info "Fetching live nodes in the cluster..."
    run_api "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&wt=json"
}

get_overseer_status() {
    log_info "Fetching Overseer status..."
    run_api "$SOLR_URL/admin/collections?action=OVERSEERSTATUS&wt=json"
}

#==============================================================================
# Cluster Operations
#==============================================================================

cluster_status() {
    log_info "Fetching cluster status..."
    run_api "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&wt=json"
}

health_check() {
    log_info "Running Solr cluster health check..."

    # Check cluster status
    local status_response=$(curl -s $CURL_OPTS "$SOLR_URL/admin/collections?action=CLUSTERSTATUS&wt=json")

    # Check for down replicas
    if echo "$status_response" | grep -q '"state":"down"'; then
        log_warn "Found down replicas in the cluster"
    else
        log_success "All replicas are healthy"
    fi

    # Check system info
    log_info "System Information:"
    run_api "$SOLR_URL/admin/info/system?wt=json"

    # Check JVM metrics
    log_info "JVM Metrics:"
    run_api "$SOLR_URL/admin/metrics?group=jvm&wt=json"
}

split_shard() {
    local cname shard

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Shard name to split: " shard
    else
        cname="$COLLECTION_NAME"
        shard="$SHARD_NAME"
    fi

    if validate_collection_name "$cname" && [[ -n "$shard" ]]; then
        log_info "Splitting shard '$shard' in collection '$cname'..."
        run_api "$SOLR_URL/admin/collections?action=SPLITSHARD&collection=$cname&shard=$shard&wt=json"
    fi
}

add_replica() {
    local cname shard node

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Shard name: " shard
        read -r -p "Node (optional): " node
    else
        cname="$COLLECTION_NAME"
        shard="$SHARD_NAME"
        node="$NODE_NAME"
    fi

    if validate_collection_name "$cname" && [[ -n "$shard" ]]; then
        local url="$SOLR_URL/admin/collections?action=ADDREPLICA&collection=$cname&shard=$shard&wt=json"
        if [[ -n "$node" ]]; then
            url="$url&node=$node"
        fi

        log_info "Adding replica to shard '$shard' in collection '$cname'..."
        run_api "$url"
    fi
}

#==============================================================================
# Monitoring and Performance
#==============================================================================

system_info() {
    log_info "Fetching Solr system information..."
    run_api "$SOLR_URL/admin/info/system?wt=json"
}

view_metrics() {
    local metric_group

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        echo "Available metric groups: jvm, node, core, collection, jetty"
        read -r -p "Metric group [default: jvm]: " metric_group
    else
        metric_group="${METRIC_GROUP:-jvm}"
    fi

    metric_group=${metric_group:-jvm}

    log_info "Fetching $metric_group metrics..."
    run_api "$SOLR_URL/admin/metrics?group=$metric_group&wt=json"
}

performance_test() {
    local cname query iterations output_file

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Collection name: " cname
        read -r -p "Query [default: *:*]: " query
        read -r -p "Number of iterations [default: 10]: " iterations
    else
        cname="$COLLECTION_NAME"
        query="${QUERY:-*:*}"
        iterations="${ITERATIONS:-10}"
    fi

    query=${query:-"*:*"}
    iterations=${iterations:-10}
    output_file="/tmp/solr-perf-test-$(date +%Y%m%d-%H%M%S).log"

    if validate_collection_name "$cname" && validate_numeric_input "$iterations" "Number of iterations"; then
        log_info "Running $iterations queries against $cname..."
        log_info "Results will be saved to $output_file"

        local total_time=0
        local min_time=999999
        local max_time=0

        echo "Performance Test Results - $(date)" >"$output_file"
        echo "Collection: $cname" >>"$output_file"
        echo "Query: $query" >>"$output_file"
        echo "Iterations: $iterations" >>"$output_file"
        echo "=====================================" >>"$output_file"

        for ((i = 1; i <= iterations; i++)); do
            local start_time=$(date +%s%N)
            curl -s $CURL_OPTS "$SOLR_URL/$cname/select?q=$query&wt=json" >/dev/null
            local end_time=$(date +%s%N)
            local duration=$(((end_time - start_time) / 1000000))

            total_time=$((total_time + duration))

            if [[ $duration -lt $min_time ]]; then
                min_time=$duration
            fi

            if [[ $duration -gt $max_time ]]; then
                max_time=$duration
            fi

            local result="Query $i: ${duration}ms"
            echo "$result"
            echo "$result" >>"$output_file"
        done

        local avg_time=$((total_time / iterations))

        echo "=====================================" >>"$output_file"
        echo "Average: ${avg_time}ms" >>"$output_file"
        echo "Minimum: ${min_time}ms" >>"$output_file"
        echo "Maximum: ${max_time}ms" >>"$output_file"

        log_success "Performance test completed. Average: ${avg_time}ms"
    fi
}

#==============================================================================
# Utility Functions
#==============================================================================

list_configsets() {
    log_info "Fetching configsets list..."
    run_api "$SOLR_URL/admin/configs?action=LIST&wt=json"
}

#==============================================================================
# User Role Management Functions
#==============================================================================

add_user_to_admin_role() {
    local user realm user_principal

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Enter the username (e.g., ambari-qa): " user
    else
        user="${USERNAME:-}"
        if [[ -z "$user" ]]; then
            log_error "Username must be provided in non-interactive mode"
            return 1
        fi
    fi

    if [[ -f "$KEYTAB_PATH" ]]; then
        realm=$(klist -kt "$KEYTAB_PATH" | sed -n "4p" | awk -F@ '{print $2}')
    else
        log_error "Keytab file not found at $KEYTAB_PATH"
        return 1
    fi

    if [[ "$user" != *@* ]]; then
        user_principal="${user}@${realm}"
    else
        user_principal="$user"
    fi

    log_info "Assigning user $user_principal to admin role..."

    local data
    data=$(
        cat <<EOF
{
  "set-user-role": {
    "$user_principal": ["admin", "ranger_audit_user", "dev"]
  }
}
EOF
    )

    run_api "$SOLR_URL/admin/authorization" "POST" "$data"
}

get_authorization_rules() {
    log_info "Fetching current Solr authorization rules..."
    run_api "$SOLR_URL/admin/authorization"
}

add_user_to_role() {
    local user role realm user_principal

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Enter the username (e.g., ambari-qa): " user
        read -r -p "Enter the role to assign (e.g., admin): " role
    else
        user="${USERNAME:-}"
        role="${ROLE:-admin}"
        if [[ -z "$user" || -z "$role" ]]; then
            log_error "Username and role must be provided in non-interactive mode"
            return 1
        fi
    fi

    if [[ -f "$KEYTAB_PATH" ]]; then
        realm=$(klist -kt "$KEYTAB_PATH" | sed -n "4p" | awk -F@ '{print $2}')
    else
        log_error "Keytab file not found at $KEYTAB_PATH"
        return 1
    fi

    if [[ "$user" != *@* ]]; then
        user_principal="${user}@${realm}"
    else
        user_principal="$user"
    fi

    log_info "Assigning user $user_principal to role $role..."

    local data
    data=$(
        cat <<EOF
{
  "set-user-role": {
    "$user_principal": ["$role"]
  }
}
EOF
    )

    run_api "$SOLR_URL/admin/authorization" "POST" "$data"
}

remove_user_from_role() {
    local user role realm user_principal

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Enter the username to remove: " user
        read -r -p "Enter the role to remove from (e.g., admin): " role
    else
        user="${USERNAME:-}"
        role="${ROLE:-admin}"
        if [[ -z "$user" || -z "$role" ]]; then
            log_error "Username and role must be provided in non-interactive mode"
            return 1
        fi
    fi

    if [[ -f "$KEYTAB_PATH" ]]; then
        realm=$(klist -kt "$KEYTAB_PATH" | sed -n "4p" | awk -F@ '{print $2}')
    else
        log_error "Keytab file not found at $KEYTAB_PATH"
        return 1
    fi

    if [[ "$user" != *@* ]]; then
        user_principal="${user}@${realm}"
    else
        user_principal="$user"
    fi

    log_info "Removing user $user_principal from role $role..."

    local data
    data=$(
        cat <<EOF
{
  "remove-user-role": {
    "$user_principal": ["$role"]
  }
}
EOF
    )

    run_api "$SOLR_URL/admin/authorization" "POST" "$data"
}

set_global_permission() {
    local role permission

    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        read -r -p "Enter the role (e.g., admin): " role
        read -r -p "Enter the permission (e.g., security-edit): " permission
    else
        role="${ROLE:-admin}"
        permission="${PERMISSION:-security-edit}"
        if [[ -z "$role" || -z "$permission" ]]; then
            log_error "Role and permission must be provided in non-interactive mode"
            return 1
        fi
    fi

    log_info "Granting $permission to role $role..."

    local data
    data=$(
        cat <<EOF
{
  "set-permission": {
    "role": "$role",
    "name": "$permission"
  }
}
EOF
    )

    run_api "$SOLR_URL/admin/authorization" "POST" "$data"
}

#==============================================================================
# Menu System
#==============================================================================

show_menu() {
    clear
    echo -e "\n${GREEN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                         SOLR ADMIN TOOL v2.0                              ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}Connected to: ${SOLR_URL}${NC}\n"

    echo -e "${BLUE}╔═══════════════════════ COLLECTION MANAGEMENT ═════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 1.  List Collections              ${BLUE}│${NC} 2.  Create Collection              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 3.  Create ranger_audits          ${BLUE}│${NC} 4.  Delete Collection              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 5.  Delete ranger_audits          ${BLUE}│${NC} 6.  Reload Collection              ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 7.  Backup Collection             ${BLUE}│${NC} 8.  Restore Collection             ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 9.  Get Collection Config         ${BLUE}│${NC} 10. Export Collection Config       ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔═══════════════════════ QUERY & DATA OPERATIONS ═══════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 11. Query Collection (Basic)      ${BLUE}│${NC} 12. Query Collection (Advanced)    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 13. Get Collection Stats          ${BLUE}│${NC} 14. Get Collection Schema          ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 15. Get Collection Fields         ${BLUE}│${NC} 16. Delete Documents by Query      ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 17. Commit Collection             ${BLUE}│${NC} 18. Optimize Collection            ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔═══════════════════════ ALIAS MANAGEMENT ══════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 19. List Aliases                  ${BLUE}│${NC} 20. Create Alias                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 21. Delete Alias                  ${BLUE}│${NC}                                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔═══════════════════════ CLUSTER OPERATIONS ════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 22. Cluster Status                ${BLUE}│${NC} 23. Health Check                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 24. Split Shard                   ${BLUE}│${NC} 25. Add Replica                    ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 26. Get Live Nodes                ${BLUE}│${NC} 27. Get Overseer Status            ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 28. Authorization Status          ${BLUE}│${NC}                                    ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔═══════════════════════ MONITORING & PERFORMANCE ══════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 29. System Info                   ${BLUE}│${NC} 30. View Metrics                   ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 31. Performance Test              ${BLUE}│${NC} 32. Request Collection Status      ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔═══════════════════════ SECURITY & UTILITIES ══════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 33. List Configsets               ${BLUE}│${NC} 34. Add User to Admin Role         ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 35. View Authorization Rules      ${BLUE}│${NC} 36. Add User to Role               ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC} 37. Remove User from Role         ${BLUE}│${NC} 38. Set Global Permission          ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC} 39. ${RED}Exit${NC}                                                                   ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    read -r -p "$(echo -e ${YELLOW}Choose an option [1-39]:${NC} )" option
}

handle_menu_selection() {
    case $option in
    1) list_collections ;;
    2) create_collection ;;
    3) create_ranger_audits_collection ;;
    4) delete_collection ;;
    5) delete_ranger_audits_collection ;;
    6) reload_collection ;;
    7) backup_collection ;;
    8) restore_collection ;;
    9) get_collection_config ;;
    10) export_collection_config ;;
    11) query_collection ;;
    12) query_collection_advanced ;;
    13) get_collection_stats ;;
    14) get_collection_schema ;;
    15) get_collection_fields ;;
    16) delete_documents_by_query ;;
    17) commit_collection ;;
    18) optimize_collection ;;
    19) list_aliases ;;
    20) create_alias ;;
    21) delete_alias ;;
    22) cluster_status ;;
    23) health_check ;;
    24) split_shard ;;
    25) add_replica ;;
    26) get_live_nodes ;;
    27) get_overseer_status ;;
    28) authorization_status ;;
    29) system_info ;;
    30) view_metrics ;;
    31) performance_test ;;
    32) request_collection_status ;;
    33) list_configsets ;;
    34) add_user_to_admin_role ;;
    35) get_authorization_rules ;;
    36) add_user_to_role ;;
    37) remove_user_from_role ;;
    38) set_global_permission ;;
    39)
        log_info "Exiting Solr Admin Tool..."
        echo -e "${GREEN}Thank you for using Solr Admin Tool!${NC}"
        exit 0
        ;;
    *)
        log_error "Invalid option. Please choose a number between 1-39."
        sleep 2
        ;;
    esac
}

#==============================================================================
# Command Line Interface
#==============================================================================

show_help() {
    cat <<EOF
Enhanced Solr Admin API Tools

Usage: $0 [OPTIONS]

OPTIONS:
    -c, --collection NAME       Collection name for operations
    -a, --action ACTION         Action to perform
    --non-interactive          Run in non-interactive mode
    --config FILE              Use custom configuration file
    --debug                    Enable debug mode
    -h, --help                 Show this help message

ACTIONS:
    Collection Management:
        list                    List all collections
        create                  Create a new collection
        delete                  Delete a collection
        reload                  Reload a collection
        backup                  Backup a collection
        restore                 Restore a collection

    Query Operations:
        query                   Basic query on a collection
        query-advanced          Advanced query with filters
        stats                   Get collection statistics
        schema                  Get collection schema
        fields                  Get collection fields

    Cluster Operations:
        status                  Get cluster status
        health                  Run health check

    Monitoring:
        info                    Get system information
        metrics                 View metrics
        configsets              List configsets

EXAMPLES:
    $0                                          # Interactive mode
    $0 --action list                            # List all collections
    $0 -c mycollection -a reload                # Reload specific collection
    $0 -c ranger_audits -a query                # Query ranger_audits collection
    $0 --non-interactive -c test -a delete      # Delete collection in non-interactive mode

ENVIRONMENT VARIABLES:
    SOLR_ADMIN_HOST             Solr host (default: hostname -f)
    SOLR_ADMIN_PORT             Solr port (default: 8886)
    SOLR_KEYTAB_PATH            Kerberos keytab path
    SOLR_BACKUP_LOCATION        Backup directory
    QUERY                       Query string for query actions
    ROWS                        Number of rows for query actions
    FIELDS                      Fields to return in query
    SORT                        Sort field for query
    FILTER_QUERY                Filter query (fq) for advanced queries

CONFIGURATION:
    Copy solr-api-config.conf.sample to solr-api-config.conf and customize settings.

EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -c | --collection)
            COLLECTION_NAME="$2"
            shift 2
            ;;
        -a | --action)
            ACTION="$2"
            shift 2
            ;;
        --non-interactive)
            INTERACTIVE_MODE=false
            shift
            ;;
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --debug)
            DEBUG=true
            shift
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        esac
    done
}

execute_non_interactive() {
    case "$ACTION" in
    # Collection Management
    "list") list_collections ;;
    "create") create_collection ;;
    "delete") delete_collection ;;
    "reload") reload_collection ;;
    "backup") backup_collection ;;
    "restore") restore_collection ;;
    "config") get_collection_config ;;
    "export-config") export_collection_config ;;

    # Query & Data Operations
    "query") query_collection ;;
    "query-advanced") query_collection_advanced ;;
    "stats") get_collection_stats ;;
    "schema") get_collection_schema ;;
    "fields") get_collection_fields ;;
    "delete-docs") delete_documents_by_query ;;
    "commit") commit_collection ;;
    "optimize") optimize_collection ;;

    # Alias Management
    "list-aliases") list_aliases ;;
    "create-alias") create_alias ;;
    "delete-alias") delete_alias ;;

    # Cluster Operations
    "status") cluster_status ;;
    "health") health_check ;;
    "split-shard") split_shard ;;
    "add-replica") add_replica ;;
    "live-nodes") get_live_nodes ;;
    "overseer") get_overseer_status ;;

    # Monitoring & Performance
    "info") system_info ;;
    "metrics") view_metrics ;;
    "perf-test") performance_test ;;
    "request-status") request_collection_status ;;

    # Utilities
    "configsets") list_configsets ;;
    "auth-status") authorization_status ;;

    *)
        log_error "Unknown action: $ACTION"
        show_help
        exit 1
        ;;
    esac
}

#==============================================================================
# Main Function
#==============================================================================

main() {
    # Parse command line arguments
    parse_args "$@"

    # Load configuration
    load_config

    # Initialize logging
    touch "$LOG_FILE"

    # Show banner in interactive mode
    if [[ "$INTERACTIVE_MODE" == "true" ]]; then
        show_banner
    fi

    log_info "Solr Admin Tools started"

    # Display configuration
    print_section "CONFIGURATION"
    echo -e "  ${BOLD}Solr URL:${NC}         ${WHITE}$SOLR_URL${NC}"
    echo -e "  ${BOLD}Protocol:${NC}         ${WHITE}$SOLR_PROTOCOL${NC}"
    echo -e "  ${BOLD}Host:${NC}             ${WHITE}$SOLR_HOST${NC}"
    echo -e "  ${BOLD}Port:${NC}             ${WHITE}$SOLR_PORT${NC}"
    echo -e "  ${BOLD}Keytab:${NC}           ${WHITE}$KEYTAB_PATH${NC}"
    echo -e "  ${BOLD}Backup Location:${NC}  ${WHITE}$BACKUP_LOCATION${NC}"
    echo -e "  ${BOLD}Log File:${NC}         ${WHITE}$LOG_FILE${NC}"
    echo ""

    # Setup authentication and test connection
    setup_authentication
    test_connection

    if [[ "$INTERACTIVE_MODE" == "false" ]]; then
        # Non-interactive mode
        if [[ -z "$ACTION" ]]; then
            log_error "Action required in non-interactive mode"
            show_help
            exit 1
        fi
        execute_non_interactive
    else
        # Interactive mode
        echo -e "\n${GREEN}${BOLD}Press Enter to continue to main menu...${NC}"
        read -r
        while true; do
            show_menu
            handle_menu_selection
            echo -e "\n${CYAN}╔════════════════════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${CYAN}║                           Operation Completed                             ║${NC}"
            echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════╝${NC}\n"
            read -r -p "$(echo -e ${YELLOW}Press Enter to return to menu...${NC})"
        done
    fi
}

# Execute main function with all arguments
main "$@"
