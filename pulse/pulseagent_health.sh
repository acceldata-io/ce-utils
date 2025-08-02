#!/bin/bash
# Acceldata Inc. | Pulse Platform Validation Script

#---------------------------------
# Color and Formatting Definitions
#---------------------------------
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
BOLD="\e[1m"
UNDERLINE="\e[4m"
RESET="\e[0m"

#---------------------------------
# Utility Functions
#---------------------------------
print_divider() {
    echo -e "${CYAN}------------------------------------------------------------${RESET}"
}

print_step() {
    local n="$1"
    local desc="$2"
    print_divider
    echo -e "${BLUE}${BOLD}STEP $n:${RESET} ${BOLD}${desc}${RESET}"
    print_divider
    echo
}

colored_echo() {
    # Usage: colored_echo COLOR "Message"
    local color="$1"
    shift
    echo -e "${!color}${BOLD}$*${RESET}"
}

colored_table_row() {
    # Usage: colored_table_row COLOR "col1" "col2" ...
    local color="$1"
    shift
    printf "${!color}${BOLD}%-20s %-16s %-20s${RESET}\n" "$@"
}

#---------------------------------
# Initialization
#---------------------------------
CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S %Z")
HOSTNAME=$(hostname)
CURRENT_DATE=$(date +"%Y-%m-%d")
CURRENT_EPOCH=$(date +%s)

#---------------------------------
# Script Banner
#---------------------------------
echo -e "${CYAN}${BOLD}Running on Host:${RESET} ${YELLOW}${HOSTNAME}${RESET}"
echo -e "${CYAN}${BOLD}Current Time:${RESET} ${YELLOW}${CURRENT_TIME}${RESET}\n"

#---------------------------------
# STEP 1: Verify Installation
#---------------------------------
print_step 1 "Verifying Installation of Pulse Agents"

dirs=(/opt/pulse/node /opt/pulse/logs /opt/pulse/jmx /opt/pulse/log /opt/pulse/hydra)
printf "${UNDERLINE}%-20s %-10s${RESET}\n" "Component" "Status"
print_divider
for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
        colored_table_row GREEN "$(basename "$dir")" "Installed" ""
    else
        colored_table_row RED "$(basename "$dir")" "Not Installed" ""
    fi
done
echo

#---------------------------------
# STEP 2: Check Pulse Services
#---------------------------------
print_step 2 "Checking the Status of Pulse Agents"

printf "${UNDERLINE}%-16s %-18s %-30s${RESET}\n" "Service" "Status" "Active Since"
print_divider
services=("pulsenode" "pulselogs" "pulsejmx" "hydra")
for service in "${services[@]}"; do
    if systemctl list-units --full -all | grep -q "$service.service"; then
        if systemctl is-active --quiet "$service"; then
            status="Running"
            active_since=$(systemctl show "$service" --property=ActiveEnterTimestamp | cut -d'=' -f2)
            colored_table_row GREEN "$service" "$status" "$active_since"
        else
            # Fallback: check if process is running
            if pgrep -f "/opt/pulse/bin/$service" > /dev/null; then
                colored_table_row YELLOW "$service" "Running (standalone)" "-"
            else
                colored_table_row RED "$service" "Stopped" "-"
            fi
        fi
    else
        if pgrep -f "/opt/pulse/bin/$service" > /dev/null; then
            colored_table_row GREEN "$service" "Running (standalone)" "-"
        else
            colored_table_row YELLOW "$service" "Not Found" "-"
        fi
    fi
done
echo

#---------------------------------
# STEP 3: Validate Hydra Service
#---------------------------------
print_step 3 "Validating Hydra Service"

HYDRA_LOG="/opt/pulse/hydra/log/hydra.log"
HYDRA_CONFIG="/opt/pulse/hydra/config/hydra.yml"

colored_echo BOLD "Checking Hydra Log File..."
if [ -f "$HYDRA_LOG" ]; then
    LOG_SIZE=$(stat -c %s "$HYDRA_LOG")
    LOG_MOD_TIME=$(stat -c %y "$HYDRA_LOG")
    TIME_DIFF=$((CURRENT_EPOCH - $(stat -c %Y "$HYDRA_LOG")))
    echo -e "${CYAN}Log file size: ${LOG_SIZE} bytes${RESET}"
    echo -e "${CYAN}Last modified: ${LOG_MOD_TIME}${RESET}"
    if [ "$TIME_DIFF" -le 300 ]; then
        colored_echo GREEN "Hydra log file is up-to-date (modified within last 5 minutes)."
    else
        colored_echo YELLOW "Hydra log file is older (last modified more than 5 minutes ago)."
    fi

    colored_echo BOLD "\nChecking for Log Levels in Hydra Log File..."
    for LEVEL in "ERROR"; do
        LOG_ENTRIES=$(tail -n3 "$HYDRA_LOG" | grep "$LEVEL")
        if [ -n "$LOG_ENTRIES" ]; then
            any_recent_entries=false
            colored_echo RED "$LEVEL entries found in Hydra log file:"
            echo "$LOG_ENTRIES" | while IFS= read -r line; do
                ERROR_DATE=$(echo "$line" | awk -F'T' '{print $1}')
                ERROR_TIME=$(echo "$line" | awk -F'T' '{print $2}' | cut -d'.' -f1)
                ERROR_TIMESTAMP=$(date -d "$ERROR_DATE $ERROR_TIME" +%s)
                ERROR_TIME_DIFF=$((CURRENT_EPOCH - ERROR_TIMESTAMP))
                if [ "$ERROR_TIME_DIFF" -le 300 ]; then
                    echo -e "${RED}$line${RESET} ${YELLOW}(Within last 5 minutes)${RESET}"
                    any_recent_entries=true
                elif [ "$ERROR_DATE" == "$CURRENT_DATE" ]; then
                    echo -e "${YELLOW}$line${RESET} (Today but older than 5 minutes)"
                    any_recent_entries=true
                fi
            done
            if [ "$any_recent_entries" = false ]; then
                colored_echo GREEN "No recent $LEVEL entries found in Hydra log file."
            fi
        else
            colored_echo GREEN "No $LEVEL entries found in Hydra log file."
        fi
    done
else
    colored_echo RED "Hydra log file not found at $HYDRA_LOG!"
fi

colored_echo BOLD "\nChecking Hydra Service Status..."
if systemctl list-units --full -all | grep -q "hydra.service"; then
    if systemctl is-active --quiet hydra; then
        colored_echo GREEN "Hydra service is active and running via systemd."
    else
        colored_echo RED "Hydra service is not running via systemd!"
    fi
else
    if ps aux | grep "/opt/pulse/bin/hydra" | grep -v grep > /dev/null; then
        colored_echo GREEN "Hydra process is running (non-systemd, likely Ambari-managed)."
        ps aux | grep "/opt/pulse/bin/hydra" | grep -v grep
    else
        colored_echo RED "Hydra process not found!"
    fi
fi

colored_echo BOLD "\nValidating Hydra Config File..."
if [ -f "$HYDRA_CONFIG" ]; then
    colored_echo GREEN "Hydra config file found at $HYDRA_CONFIG."
    BASE_URL=$(grep -oP 'base_url:\s*\K.+' "$HYDRA_CONFIG")
    if [[ "$BASE_URL" =~ http://.*:[0-9]+ ]]; then
        colored_echo GREEN "Base URL is valid: $BASE_URL"
    else
        colored_echo RED "Base URL is invalid or missing in the config file."
    fi
else
    colored_echo RED "Hydra config file not found at $HYDRA_CONFIG!"
fi
echo

#---------------------------------
# STEP 4: Validate PulseNode
#---------------------------------
print_step 4 "Validating PulseNode"

PULSENODE_CONFIG="/opt/pulse/node/config/node.conf"
PULSENODE_LOG_DIR="/opt/pulse/node/log"

colored_echo BOLD "Validating PulseNode Configuration File..."
if [ -f "$PULSENODE_CONFIG" ]; then
    colored_echo GREEN "Configuration file found at $PULSENODE_CONFIG."
    colored_echo BOLD "\nConfiguration File Listing:"
    ls -tlr "$PULSENODE_CONFIG"
    colored_echo BOLD "\nInfluxDB URLs in Configuration File:"
    grep -A2 'outputs.influxdb' "$PULSENODE_CONFIG" | grep 'urls' | uniq 
else
    colored_echo RED "Configuration file not found at $PULSENODE_CONFIG!"
fi

colored_echo BOLD "\nChecking PulseNode Log Files..."
if [ -d "$PULSENODE_LOG_DIR" ]; then
    colored_echo GREEN "Log directory found at $PULSENODE_LOG_DIR."
    colored_echo BOLD "\nLog Files for Today ($CURRENT_DATE):"
    LOG_FILES=$(find "$PULSENODE_LOG_DIR" -maxdepth 1 -type f ! -name '*.gz' -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")
    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            if [ -s "$file" ]; then
                echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
                tail -n 2 "$file" | while IFS= read -r line; do
                    if [[ "$line" == *"ERROR"* ]]; then
                        echo -e "${RED}${line}${RESET}"
                    else
                        echo -e "${line}"
                    fi
                done
            else
                colored_echo YELLOW "Skipping empty log file: $(basename "$file")"
            fi
        done
    else
        colored_echo RED "No log files found for today."
    fi
else
    colored_echo RED "Log directory not found at $PULSENODE_LOG_DIR!"
fi
echo

#---------------------------------
# STEP 5: Validate PulseLogs
#---------------------------------
print_step 5 "Validating PulseLogs"

PULSELOGS_CONFIG_DIR="/opt/pulse/logs/config"
PULSELOGS_LOG_DIR="/opt/pulse/logs/log"

colored_echo BOLD "Validating PulseLogs Configuration Files..."
if [ -d "$PULSELOGS_CONFIG_DIR" ]; then
    colored_echo GREEN "Configuration directory found at $PULSELOGS_CONFIG_DIR."
    colored_echo BOLD "\nConfiguration Files:"
    ls -ltr "$PULSELOGS_CONFIG_DIR"
    colored_echo BOLD "\nhosts details from config file:"
    grep 'hosts' "$PULSELOGS_CONFIG_DIR"/logs.yml
else
    colored_echo RED "Configuration directory not found at $PULSELOGS_CONFIG_DIR!"
fi

colored_echo BOLD "\nChecking PulseLogs Log Files..."
if [ -d "$PULSELOGS_LOG_DIR" ]; then
    colored_echo GREEN "Log directory found at $PULSELOGS_LOG_DIR."
    colored_echo BOLD "\nLog Files for Today ($CURRENT_DATE):"
    LOG_FILES=$(find "$PULSELOGS_LOG_DIR" -maxdepth 1 -type f -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")
    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
            tail -n 1 "$file" | while IFS= read -r line; do
                if [[ "$line" == *"ERROR"* ]]; then
                    echo -e "${RED}${line}${RESET}"
                else
                    echo -e "${line}"
                fi
            done
        done
    else
        colored_echo RED "No log files found for today."
    fi
else
    colored_echo RED "Log directory not found at $PULSELOGS_LOG_DIR!"
fi
echo

#---------------------------------
# STEP 6: Validate PulseJMX
#---------------------------------
print_step 6 "Validating PulseJMX"

PULSEJMX_CONFIG_DIR="/opt/pulse/jmx/config"
PULSEJMX_LOG_DIR="/opt/pulse/jmx/log"

colored_echo BOLD "Validating PulseJMX Configuration Files..."
if [ -d "$PULSEJMX_CONFIG_DIR" ]; then
    colored_echo GREEN "Configuration directory found at $PULSEJMX_CONFIG_DIR."
    if [ -f "$PULSEJMX_CONFIG_DIR/logback.xml" ]; then
        colored_echo BOLD "\nConfiguration File Listing:"
        ls -tlr "$PULSEJMX_CONFIG_DIR/logback.xml"
    else
        colored_echo RED "Configuration file logback.xml not found in $PULSEJMX_CONFIG_DIR!"
    fi
    if [ -d "$PULSEJMX_CONFIG_DIR/enabled" ]; then
        colored_echo BOLD "\nJMX Enabled Files:"
        ls -tlr "$PULSEJMX_CONFIG_DIR/enabled"
    else
        colored_echo RED "Enabled configuration directory not found in $PULSEJMX_CONFIG_DIR!"
    fi
else
    colored_echo RED "Configuration directory not found at $PULSEJMX_CONFIG_DIR!"
fi

colored_echo BOLD "\nChecking PulseJMX Log Files..."
if [ -d "$PULSEJMX_LOG_DIR" ]; then
    colored_echo GREEN "Log directory found at $PULSEJMX_LOG_DIR."
    colored_echo BOLD "\nLog Files for Today ($CURRENT_DATE):"
    LOG_FILES=$(find "$PULSEJMX_LOG_DIR" -maxdepth 1 -type f -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")
    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
            tail -n 1 "$file" | while IFS= read -r line; do
                if [[ "$line" == *"ERROR"* ]]; then
                    echo -e "${RED}${line}${RESET}"
                else
                    echo -e "${line}"
                fi
            done
        done
    else
        colored_echo RED "No log files found for today."
    fi
else
    colored_echo RED "Log directory not found at $PULSEJMX_LOG_DIR!"
fi
echo

#---------------------------------
# Script Complete
#---------------------------------
print_divider
colored_echo BLUE "✔ Validation Completed at $CURRENT_TIME on $HOSTNAME."
print_divider
