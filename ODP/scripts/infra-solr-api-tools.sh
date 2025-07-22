#!/bin/bash

#==============================================================================
# Enhanced Solr Admin API Tools Script
# Description: Comprehensive Solr cluster management and administration tool
# Copyright (c) 2025 Acceldata Inc. All rights reserved.
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
NC='\033[0m' # No Color

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
    log_with_timestamp "${BLUE}[INFO]${NC}" "$1"
}

log_warn() {
    log_with_timestamp "${YELLOW}[WARN]${NC}" "$1"
}

log_error() {
    log_with_timestamp "${RED}[ERROR]${NC}" "$1"
}

log_success() {
    log_with_timestamp "${GREEN}[OK]${NC}" "$1"
}

log_cmd() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        log_with_timestamp "${PURPLE}[CMD]${NC}" "$1"
    fi
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

test_connection() {
    log_info "Testing connection to Solr at $SOLR_URL..."
    if validate_url "$SOLR_URL"; then
        log_success "Connection to Solr successful"
    else
        log_error "Failed to connect to Solr"
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

    # Echo the curl command to the user before executing
    if [[ -n "$data" ]]; then
        echo -e "${CYAN}Running: curl -X $method $CURL_OPTS -H \"Content-Type: application/json\" -d '$data' \"$url\"${NC}"
    else
        echo -e "${CYAN}Running: curl -X $method $CURL_OPTS \"$url\"${NC}"
    fi

    # Optionally log the command if debug enabled
    if [[ "${DEBUG:-false}" == "true" ]]; then
        if [[ -n "$data" ]]; then
            log_with_timestamp "${PURPLE}[CMD]${NC}" "curl -X $method $CURL_OPTS -H \"Content-Type: application/json\" -d '$data' \"$url\""
        else
            log_with_timestamp "${PURPLE}[CMD]${NC}" "curl -X $method $CURL_OPTS \"$url\""
        fi
    fi

    if [[ -n "$data" ]]; then
        response=$(curl -s -w "%{http_code}" -X "$method" $CURL_OPTS -H "Content-Type: application/json" -d "$data" "$url" --output "$temp_file")
    else
        response=$(curl -s -w "%{http_code}" -X "$method" $CURL_OPTS "$url" --output "$temp_file")
    fi

    http_code="${response: -3}"
    response_body=$(cat "$temp_file")
    rm -f "$temp_file"

    if [[ "$http_code" -ge 400 ]]; then
        log_error "HTTP $http_code error occurred"
        echo -e "${RED}${response_body}${NC}"
        return 1
    fi

    echo -e "${YELLOW}"
    format_json_output "$response_body" "$DEFAULT_OUTPUT_FORMAT"
    echo -e "${NC}"
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
    echo -e "\n${GREEN}============================================${NC}"
    echo -e "${GREEN}         Solr Admin Tool                     ${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "${BLUE}Collection Management:${NC}"
    echo " 1.  List Collections"
    echo " 2.  Create ranger_audits collection"
    echo " 3.  Delete ranger_audits collection"
    echo " 4.  Reload Collection"
    echo " 5.  Backup Collection"
    echo " 6.  Restore Collection"
    echo
    echo -e "${BLUE}Cluster Operations:${NC}"
    echo " 7.  Cluster Status"
    echo " 8.  Health Check"
    echo " 9.  Split Shard"
    echo " 10. Add Replica"
    echo " 11. Authorization Status"
    echo
    echo -e "${BLUE}Monitoring & Performance:${NC}"
    echo " 12. System Info"
    echo " 13. View Metrics"
    echo " 14. Performance Test"
    echo
    echo -e "${BLUE}Utilities:${NC}"
    echo " 15. List Configsets"
    echo " 16. Add User to Admin Role"
    echo " 17. View Authorization Rules"
    echo " 18. Add User to Role"
    echo " 19. Remove User from Role"
    echo " 20. Set Global Permission"
    echo
    echo " 21. Exit"
    echo -e "${GREEN}============================================${NC}"
    echo
    read -r -p "Choose an option [1-21]: " option
}

handle_menu_selection() {
    case $option in
    1) list_collections ;;
    2) create_ranger_audits_collection ;;
    3) delete_ranger_audits_collection ;;
    4) reload_collection ;;
    5) backup_collection ;;
    6) restore_collection ;;
    7) cluster_status ;;
    8) health_check ;;
    9) split_shard ;;
    10) add_replica ;;
    11) authorization_status ;;
    12) system_info ;;
    13) view_metrics ;;
    14) performance_test ;;
    15) list_configsets ;;
    16) add_user_to_admin_role ;;
    17) get_authorization_rules ;;
    18) add_user_to_role ;;
    19) remove_user_from_role ;;
    20) set_global_permission ;;
    21)
        log_info "Exiting..."
        exit 0
        ;;
    *)
        log_error "Invalid option. Please try again."
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
    -a, --action ACTION         Action to perform (list, create, delete, reload, backup, restore)
    --non-interactive          Run in non-interactive mode
    --config FILE              Use custom configuration file
    --debug                    Enable debug mode
    -h, --help                 Show this help message

EXAMPLES:
    $0                                    # Interactive mode
    $0 --action list                      # List all collections
    $0 -c mycollection -a reload          # Reload specific collection
    $0 --non-interactive -c test -a delete # Delete collection in non-interactive mode

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
    "list") list_collections ;;
    "create") create_collection ;;
    "delete") delete_collection ;;
    "reload") reload_collection ;;
    "backup") backup_collection ;;
    "restore") restore_collection ;;
    "status") cluster_status ;;
    "health") health_check ;;
    "info") system_info ;;
    "metrics") view_metrics ;;
    "configsets") list_configsets ;;
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
    log_info "Solr Admin Tools started"

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
        while true; do
            show_menu
            handle_menu_selection
            echo
            read -r -p "Press Enter to continue..."
        done
    fi
}

# Execute main function with all arguments
main "$@"
