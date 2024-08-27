#!/bin/bash
#Acceldata Inc.
# Define color codes
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
BLUE="\e[34m"
CYAN="\e[36m"
BOLD="\e[1m"
UNDERLINE="\e[4m"
RESET="\e[0m"

# Get current time and hostname
CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S %Z")
HOSTNAME=$(hostname)

# Function to print a divider
print_divider() {
    printf "%0.s-" {1..60}
    echo
}

# Display current time and hostname
echo -e "${CYAN}${BOLD}Running on Host:${RESET} ${YELLOW}${HOSTNAME}${RESET}"
echo -e "${CYAN}${BOLD}Current Time:${RESET} ${YELLOW}${CURRENT_TIME}${RESET}\n"

# STEP 1: Check Installation of Pulse Agents
echo -e "${BLUE}${BOLD}---------------------------------------------"
echo -e "STEP 1: Verifying Installation of Pulse Agents"
echo -e "---------------------------------------------${RESET}\n"

dirs=(/opt/pulse/node /opt/pulse/logs /opt/pulse/jmx /opt/pulse/log /opt/pulse/hydra)
for dir in "${dirs[@]}"; do
    if [ -d "$dir" ]; then
        echo -e "${GREEN}${BOLD}$(printf "%-20s %-10s" "$(basename "$dir")" "Installed")${RESET}"
    else
        echo -e "${RED}${BOLD}$(printf "%-20s %-10s" "$(basename "$dir")" "Not Installed")${RESET}"
    fi
done

# STEP 2: Check Status of Pulse Services
echo -e "\n${BLUE}${BOLD}-----------------------------------------"
echo -e "STEP 2: Checking the Status of Pulse Agents"
echo -e "-----------------------------------------${RESET}\n"

print_divider
printf "${UNDERLINE}%-16s %-10s %s${RESET}\n" "Service" "Status" "Active Since"
print_divider

services=("pulsenode" "pulselogs" "pulsejmx" "hydra")
for service in "${services[@]}"; do
    if systemctl list-units --full -all | grep -q "$service.service"; then
        if systemctl is-active --quiet "$service"; then
            status="Running"
            active_since=$(systemctl show "$service" --property=ActiveEnterTimestamp | cut -d'=' -f2)
            echo -e "${GREEN}${BOLD}$(printf "%-16s %-10s %s" "$service" "$status" "$active_since")${RESET}"
        else
            status="Stopped"
            echo -e "${RED}${BOLD}$(printf "%-16s %-10s %s" "$service" "$status" "-")${RESET}"
        fi
    else
        # Check if the service is running as a standalone process
        if pgrep -f "/opt/pulse/bin/$service" > /dev/null; then
            status="Running (standalone)"
            echo -e "${GREEN}${BOLD}$(printf "%-16s %-10s %s" "$service" "$status" "-")${RESET}"
        else
            status="Not Found"
            echo -e "${YELLOW}${BOLD}$(printf "%-16s %-10s %s" "$service" "$status" "-")${RESET}"
        fi
    fi
done

# STEP 3: Validate Hydra Service
echo -e "\n${BLUE}${BOLD}--------------------------------"
echo -e "STEP 3: Validating Hydra Service"
echo -e "--------------------------------${RESET}\n"

# Get current date and time
CURRENT_DATE=$(date +"%Y-%m-%d")
CURRENT_TIME=$(date +"%H:%M:%S %Z")
CURRENT_EPOCH=$(date +%s)

# Log file path
HYDRA_LOG="/opt/pulse/hydra/log/hydra.log"
CONFIG_FILE="/opt/pulse/hydra/config/hydra.yml"

# Check if the Hydra log file exists and is up-to-date
echo -e "${BOLD}Checking Hydra Log File...${RESET}"

if [ -f "$HYDRA_LOG" ]; then
    LOG_SIZE=$(stat -c %s "$HYDRA_LOG")
    LOG_MOD_TIME=$(stat -c %y "$HYDRA_LOG")
    TIME_DIFF=$((CURRENT_EPOCH - $(stat -c %Y "$HYDRA_LOG")))

    echo -e "${CYAN}Log file size: ${LOG_SIZE} bytes${RESET}"
    echo -e "${CYAN}Last modified: ${LOG_MOD_TIME}${RESET}"

    if [ "$TIME_DIFF" -le 300 ]; then
        echo -e "${GREEN}Hydra log file is up-to-date (modified within the last 5 minutes).${RESET}"
    else
        echo -e "${YELLOW}Hydra log file is older (last modified more than 5 minutes ago).${RESET}"
    fi

    # Check for different log levels in the log file and validate timestamps
    echo -e "\n${BOLD}Checking for Log Levels in Hydra Log File...${RESET}"

    for LEVEL in "ERROR" "WARN" "CRITICAL"; do
        LOG_ENTRIES=$(tail -n3 "$HYDRA_LOG" | grep "$LEVEL")

        if [ -n "$LOG_ENTRIES" ]; then
            any_recent_entries=false
            echo -e "${RED}${LEVEL} entries found in Hydra log file:${RESET}"
            echo "$LOG_ENTRIES" | while IFS= read -r line; do
                ERROR_DATE=$(echo "$line" | awk -F'T' '{print $1}')
                ERROR_TIME=$(echo "$line" | awk -F'T' '{print $2}' | cut -d'.' -f1)
                ERROR_TIMESTAMP=$(date -d "$ERROR_DATE $ERROR_TIME" +%s)
                ERROR_TIME_DIFF=$((CURRENT_EPOCH - ERROR_TIMESTAMP))

                if [ "$ERROR_TIME_DIFF" -le 300 ]; then
                    echo -e "${RED}$line${RESET} ${YELLOW}(Within the last 5 minutes)${RESET}"
                    any_recent_entries=true
                elif [ "$ERROR_DATE" == "$CURRENT_DATE" ]; then
                    echo -e "${YELLOW}$line${RESET} (Today but older than 5 minutes)"
                    any_recent_entries=true
                else
                    continue
                fi
            done

            if [ "$any_recent_entries" = false ]; then
                echo -e "${GREEN}No recent ${LEVEL} entries found in Hydra log file.${RESET}"
            fi
        else
            echo -e "${GREEN}No ${LEVEL} entries found in Hydra log file.${RESET}"
        fi
    done
else
    echo -e "${RED}Hydra log file not found at $HYDRA_LOG!${RESET}"
fi

# Check if Hydra service is active or running
echo -e "\n${BOLD}Checking Hydra Service Status...${RESET}"

if systemctl is-active --quiet hydra; then
    echo -e "${GREEN}Hydra service is active and running.${RESET}"
else
    echo -e "${RED}Hydra service is not running!${RESET}"
fi

# Validate Hydra configuration file
echo -e "\n${BOLD}Validating Hydra Config File...${RESET}"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}Hydra config file found at $CONFIG_FILE.${RESET}"

    # Checking base_url configuration
    BASE_URL=$(grep -oP 'base_url:\s*\K.+' "$CONFIG_FILE")
    if [[ "$BASE_URL" =~ http://.*:[0-9]+ ]]; then
        echo -e "${GREEN}Base URL is valid: $BASE_URL${RESET}"
    else
        echo -e "${RED}Base URL is invalid or missing in the config file.${RESET}"
    fi
else
    echo -e "${RED}Hydra config file not found at $CONFIG_FILE!${RESET}"
fi

# STEP 4: Validate PulseNode Configuration and Logs
echo -e "\n${BLUE}${BOLD}--------------------------------"
echo -e "STEP 4: Validating PulseNode"
echo -e "--------------------------------${RESET}\n"

# Config and log file paths
CONFIG_FILE="/opt/pulse/node/config/node.conf"
LOG_DIR="/opt/pulse/node/log"

# Validate the configuration file
echo -e "${BOLD}Validating PulseNode Configuration File...${RESET}"

if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}Configuration file found at $CONFIG_FILE.${RESET}"

    # Check the file listing
    echo -e "\n${BOLD}Configuration File Listing:${RESET}"
    ls -tlr "$CONFIG_FILE"

    # InfluxDB URLs in Configuration File
    echo -e "\n${BOLD}InfluxDB URLs in Configuration File:${RESET}"
    grep -A2 'outputs.influxdb' "$CONFIG_FILE" | grep 'urls' | uniq 

else
    echo -e "${RED}Configuration file not found at $CONFIG_FILE!${RESET}"
fi

# Validate the logs
echo -e "\n${BOLD}Checking PulseNode Log Files...${RESET}"

if [ -d "$LOG_DIR" ]; then
    echo -e "${GREEN}Log directory found at $LOG_DIR.${RESET}"

    # List all log files with today's date
    echo -e "\n${BOLD}Log Files for Today (${CURRENT_DATE}):${RESET}"

    # Find log files modified today
    LOG_FILES=$(find "$LOG_DIR" -maxdepth 1 -type f -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")

    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            if [ -s "$file" ]; then  # Check if the file is not empty
                echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
                # Color code lines with errors only
                tail -n 2 "$file" | while IFS= read -r line; do
                    if [[ "$line" == *"ERROR"* ]]; then
                        echo -e "${RED}${line}${RESET}"
                    else
                        echo -e "${line}"
                    fi
                done
            else
                echo -e "${YELLOW}Skipping empty log file: $(basename "$file")${RESET}"
            fi
        done
    else
        echo -e "${RED}No log files found for today.${RESET}"
    fi
else
    echo -e "${RED}Log directory not found at $LOG_DIR!${RESET}"
fi

# Validate the pulselogs directory and files
echo -e "\n${BLUE}${BOLD}--------------------------------"
echo -e "STEP 5: Validating PulseLogs"
echo -e "--------------------------------${RESET}\n"

PULSELOGS_DIR="/opt/pulse/logs"
PULSELOGS_CONFIG_DIR="/opt/pulse/logs/config"
PULSELOGS_LOG_DIR="/opt/pulse/logs/log"

# Validate the configuration files in PulseLogs
echo -e "${BOLD}Validating PulseLogs Configuration Files...${RESET}"

if [ -d "$PULSELOGS_CONFIG_DIR" ]; then
    echo -e "${GREEN}Configuration directory found at $PULSELOGS_CONFIG_DIR.${RESET}"

    # List configuration files
    echo -e "\n${BOLD}Configuration Files:${RESET}"
    ls -ltr "$PULSELOGS_CONFIG_DIR"

    # Display InfluxDB URLs from configuration files
    echo -e "\n${BOLD}hosts details from config file:${RESET}"
    grep 'hosts' "$PULSELOGS_CONFIG_DIR"/logs.yml
else
    echo -e "${RED}Configuration directory not found at $PULSELOGS_CONFIG_DIR!${RESET}"
fi

# Validate the logs
echo -e "\n${BOLD}Checking PulseLogs Log Files...${RESET}"

if [ -d "$PULSELOGS_LOG_DIR" ]; then
    echo -e "${GREEN}Log directory found at $PULSELOGS_LOG_DIR.${RESET}"

    # List all log files with today's date
    echo -e "\n${BOLD}Log Files for Today (${CURRENT_DATE}):${RESET}"

    # Find log files modified today
    LOG_FILES=$(find "$PULSELOGS_LOG_DIR" -maxdepth 1 -type f -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")

    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
            tail -n 1 "$file" | sed "s/^/${RED}/"
        done
    else
        echo -e "${RED}No log files found for today.${RESET}"
    fi
else
    echo -e "${RED}Log directory not found at $PULSELOGS_LOG_DIR!${RESET}"
fi
# Validate the PulseJMX directory and files
echo -e "\n${BLUE}${BOLD}--------------------------------"
echo -e "STEP 6: Validating PulseJMX"
echo -e "--------------------------------${RESET}\n"

PULSEJMX_DIR="/opt/pulse/jmx"
PULSEJMX_CONFIG_DIR="/opt/pulse/jmx/config"
PULSEJMX_LOG_DIR="/opt/pulse/jmx/log"
CURRENT_DATE=$(date +"%Y-%m-%d")
CURRENT_TIME=$(date +"%Y-%m-%d %H:%M:%S")

# Validate the configuration files in PulseJMX
echo -e "${BOLD}Validating PulseJMX Configuration Files...${RESET}"

if [ -d "$PULSEJMX_CONFIG_DIR" ]; then
    echo -e "${GREEN}Configuration directory found at $PULSEJMX_CONFIG_DIR.${RESET}"

    if [ -f "$PULSEJMX_CONFIG_DIR/logback.xml" ]; then
        echo -e "\n${BOLD}Configuration File Listing:${RESET}"
        ls -tlr "$PULSEJMX_CONFIG_DIR/logback.xml" 
    else
        echo -e "${RED}Configuration file logback.xml not found in $PULSEJMX_CONFIG_DIR!${RESET}"
    fi

    if [ -d "$PULSEJMX_CONFIG_DIR/enabled" ]; then
        echo -e "\n${BOLD}JMX Enabled Files:${RESET}"
        ls -tlr "$PULSEJMX_CONFIG_DIR/enabled" 
    else
        echo -e "${RED}Enabled configuration directory not found in $PULSEJMX_CONFIG_DIR!${RESET}"
    fi
else
    echo -e "${RED}Configuration directory not found at $PULSEJMX_CONFIG_DIR!${RESET}"
fi

# Validate the log files in PulseJMX
echo -e "\n${BOLD}Checking PulseJMX Log Files...${RESET}"

if [ -d "$PULSEJMX_LOG_DIR" ]; then
    echo -e "${GREEN}Log directory found at $PULSEJMX_LOG_DIR.${RESET}"

    # List all log files with today's date
    echo -e "\n${BOLD}Log Files for Today (${CURRENT_DATE}):${RESET}"

    # Find log files modified today
    LOG_FILES=$(find "$PULSEJMX_LOG_DIR" -maxdepth 1 -type f -newermt "$CURRENT_DATE" ! -newermt "$CURRENT_DATE +1 day")

    if [ -n "$LOG_FILES" ]; then
        for file in $LOG_FILES; do
            echo -e "\n${CYAN}Tail of $(basename "$file") (${file}):${RESET}"
            tail -n 1 "$file" | sed "s/^/${RED}/"
        done
    else
        echo -e "${RED}No log files found for today.${RESET}"
    fi
else
    echo -e "${RED}Log directory not found at $PULSEJMX_LOG_DIR!${RESET}"
fi

# End of the script
echo -e "\n${BLUE}${BOLD}Validation Completed at $CURRENT_TIME on $(hostname).${RESET}"
