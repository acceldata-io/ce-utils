#!/bin/bash
#
# Acceldata Inc. — Confidential
#
# Pulse cluster pre-requisite configurator.
# Configures Hive and Tez to emit events to a Pulse server by updating
# hive-site and tez-site via Ambari's configs.py helper.
#
# Must be run on the Ambari Server node of an ODP cluster.

# Check if configs.py script exists
if [ ! -f "/var/lib/ambari-server/resources/scripts/configs.py" ]; then
    echo "The configs.py script does not exist in /var/lib/ambari-server/resources/scripts/ directory."
    echo "Please make sure you are running this script on an Ambari Server node."
    exit 1
fi

# Define color codes using tput
bold=$(tput bold)
normal=$(tput sgr0)
green=$(tput setaf 2)

#---------------------------
# Auto-detection helpers for Ambari server hostname, protocol, and port.
# Each prefers the value configured on the node, falling back to sensible
# defaults so the script still works on minimally-configured hosts.
#---------------------------
get_ambari_server_hostname() {
    local hostname_value
    hostname_value=$(grep -E "^hostname\s*=" /etc/ambari-agent/conf/ambari-agent.ini 2>/dev/null | sed 's/^hostname\s*=\s*//' | tr -d '[:space:]')
    [[ -n "${hostname_value}" ]] && echo "${hostname_value}" && return 0
    hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost"
}

# api.ssl=true → https, otherwise http.
get_ambari_protocol() {
    local ssl_value
    ssl_value=$(grep -E "^api\.ssl\s*=" /etc/ambari-server/conf/ambari.properties 2>/dev/null | sed 's/^api\.ssl\s*=\s*//' | tr -d '[:space:]')
    if [[ "${ssl_value,,}" == "true" ]]; then
        echo "https"
    else
        echo "http"
    fi
}

# Falls back to 8443 for https and 8080 for http when not explicitly configured.
get_ambari_port() {
    local protocol="$1"
    local port_value
    if [[ "$protocol" == "https" ]]; then
        port_value=$(grep -E "^client\.api\.ssl\.port\s*=" /etc/ambari-server/conf/ambari.properties 2>/dev/null | sed 's/^client\.api\.ssl\.port\s*=\s*//' | tr -d '[:space:]')
        [[ -n "${port_value}" ]] && echo "${port_value}" || echo "8443"
    else
        port_value=$(grep -E "^client\.api\.port\s*=" /etc/ambari-server/conf/ambari.properties 2>/dev/null | sed 's/^client\.api\.port\s*=\s*//' | tr -d '[:space:]')
        [[ -n "${port_value}" ]] && echo "${port_value}" || echo "8080"
    fi
}

# Fetch cluster information. Env vars win over auto-detection so callers can
# override per-invocation (e.g. AMBARI_HOST=foo AMBARI_PORT=8443 ./script.sh).
AMBARISERVER=${AMBARI_HOST:-$(get_ambari_server_hostname)}
PROTOCOL=${AMBARI_PROTOCOL:-$(get_ambari_protocol)}
PORT=${AMBARI_PORT:-$(get_ambari_port "$PROTOCOL")}

# Ambari credentials: prefer environment overrides, else prompt. We use a
# dedicated AMBARI_USER var rather than $USER so we don't shadow the shell's
# standard username variable.
AMBARI_USER=${AMBARI_USER:-}
AMBARI_PASSWORD=${AMBARI_PASSWORD:-}
if [ -z "$AMBARI_USER" ]; then
    read -rp "Ambari username [admin]: " AMBARI_USER
    AMBARI_USER=${AMBARI_USER:-admin}
fi
if [ -z "$AMBARI_PASSWORD" ]; then
    read -rsp "Ambari password for ${AMBARI_USER}: " AMBARI_PASSWORD
    echo
fi
if [ -z "$AMBARI_PASSWORD" ]; then
    echo "Error: Ambari password is required." >&2
    exit 1
fi

CLUSTER=$(curl -s -k -u "$AMBARI_USER:$AMBARI_PASSWORD" -i -H 'X-Requested-By: ambari' "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

# Convert cluster name to lowercase
CLUSTER_LOWER=$(echo "$CLUSTER" | tr '[:upper:]' '[:lower:]')

# Function to fetch configurations from Ambari
get_config_hive() {
    local config_file="$1"

    ambari-python-wrap /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" -s "$PROTOCOL" -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config_file" | grep -Ei "ad.cluster|ad.events.streaming.servers|hive.exec.failure.hooks|hive.exec.post.hooks|hive.exec.pre.hooks"
}

get_config_tez() {
    local config_file="$1"

    ambari-python-wrap /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" -s "$PROTOCOL" -a get -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config_file" | grep -Ei "ad.cluster|ad.events.streaming.servers|tez.history.logging.service.class"
}

# Function to set configurations in Ambari
set_config() {
    local config_file="$1"
    local key="$2"
    local value="$3"

    ambari-python-wrap /var/lib/ambari-server/resources/scripts/configs.py \
        -u "$AMBARI_USER" -p "$AMBARI_PASSWORD" -s "$PROTOCOL" -a set -t "$PORT" -l "$AMBARISERVER" -n "$CLUSTER" \
        -c "$config_file" -k "$key" -v "$value"
}

# Set Hive configurations
set_hive_site() {
    set_config "hive-site"  "ad.cluster" "$CLUSTER_LOWER"
    set_config "hive-site"  "ad.events.streaming.servers" "$PULSEIP:19009"
}

# Get Hive configurations
get_hive_site() {
    echo -e "${green}Pulse HIVE Configuration from ${bold}hive-site${normal}"
    get_config_hive "hive-site"
}

# Set Tez configurations
set_tez_site() {
    set_config "tez-site"  "ad.cluster" "$CLUSTER_LOWER"
    set_config "tez-site"  "ad.events.streaming.servers" "$PULSEIP:19009"
    if command -v odp-select &> /dev/null; then
        set_config "tez-site" "tez.history.logging.service.class" "org.apache.tez.dag.history.logging.proto.AdTezHook"
    elif command -v hdp-select &> /dev/null; then
        set_config "tez-site" "tez.history.logging.service.class" "io.acceldata.hive.AdTezEventsNatsClient"
    else
        echo "Neither odp-select nor hdp-select commands found. Skipping tez.history.logging.service.class configuration."
    fi
}

# Get Tez configurations
get_tez_site() {
    echo -e "${green}Pulse TEZ Configuration from ${bold}tez-site${normal}"
    get_config_tez "tez-site"
}

# Prompt for Pulse Server IP
get_pulse_ip() {
    read -rp "Enter the Pulse Server's IP address: " PULSEIP
}

# Display service options
display_service_options() {
    echo "Select an option:"
    echo "1) Check configurations (TEZ, HIVE)"
    echo "2) Set configurations (TEZ, HIVE)"
    echo "A) Check and Set all configurations"
    echo "Q) Quit"
}

# Main loop for selecting services
while true; do
    display_service_options
    read -rp "Enter your choice: " choice

    case $choice in
        1)
            get_hive_site
            get_tez_site
            ;;
        2)
            get_pulse_ip
            set_hive_site
            set_tez_site
            ;;
        [Aa])
            get_pulse_ip
            set_hive_site
            set_tez_site
            ;;
        [Qq])
            echo "Exiting..."
            break
            ;;
        *)
            echo "Invalid choice"
            ;;
    esac
done

# Move generated JSON files to /tmp if they exist
if ls doSet_version* 1> /dev/null 2>&1; then
    mv doSet_version* /tmp
    echo "JSON files moved to /tmp."
else
    echo "No JSON files found to move."
fi

echo "Script execution completed."
