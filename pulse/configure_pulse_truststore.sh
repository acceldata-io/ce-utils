#!/bin/bash
# Acceldata Inc
set -euo pipefail

#-----------------------------------------------
# Usage: configure_ssl.sh [OPTIONS]
#
# This script configures SSL for a Pulse Core Server or a Non-Core Server.
#
# For a Pulse Core Server, it will:
#   - Load the ad.sh profile and ensure AcceloHome is set.
#   - Prompt for the complete custom path of the cacerts file.
#   - Copy the cacerts file (as both cacerts and jssecacerts)
#     to $AcceloHome/config/security/.
#   - Ensure required configuration files exist (or create them via "accelo admin makeconfig").
#   - Update volume mappings in multiple YAML configuration files.
#
# For a Non-Core Server, it will:
#   - Run "docker ps" and check for an "ad-fsanalyticsv2-connector" service.
#   - If the service is found, it will prompt for the complete custom path of the cacerts file.
#   - It then ensures that the ad-fsanalyticsv2-connector configuration file exists (creating it if needed)
#     and updates the volume mappings in that file.
#
# OPTIONS:
#   -h, --help    Display this help message and exit.
#
# Requirements:
#   - Bash 4.x+
#   - sudo privileges (for creating directories and modifying files)
#   - The "accelo" command must be available in your PATH.
#-----------------------------------------------

# Color definitions for output formatting.
BLUE='\033[1;34m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

#-----------------------------------------------
# Logging functions for standardized messages.
log_info() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*"
}

#-----------------------------------------------
# Usage instructions.
usage() {
    echo -e "Usage: $0 [OPTIONS]\n"
    echo "This script configures SSL for a Pulse Core Server or a Non-Core Server."
    echo ""
    echo "Options:"
    echo "  -h, --help    Display this help message and exit."
    exit 0
}

# Parse command-line options.
if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
fi

#-----------------------------------------------
# Helper function to update volume mappings in a configuration file.
# Parameters:
#   1 - Config file path.
#   2 - Section start marker (e.g. "ad-streaming:" or "ad-fsanalyticsv2-connector:").
#   3 - Section end marker (e.g. "ulimits:").
#   4 - Source file path (local path to cacerts or jssecacerts).
#   5 - Destination path (container path).
update_volume_in_config() {
    local file="$1"
    local section_start="$2"
    local section_end="$3"
    local src_path="$4"
    local dest_path="$5"

    # Extract the relevant section from the file.
    local section
    section=$(awk "/$section_start/,/$section_end/" "$file")


    # Check if any volume mapping already exists for cacerts or jssecacerts.
    if echo "$section" | grep -Eq "[-\s]+.+/cacerts:.+/cacerts|[-\s]+.+/jssecacerts:.+/jssecacerts"; then
        log_info "A volume mapping for cacerts/jssecacerts is already present in ${file}. Skipping."
    else
        # Insert the volume mapping after the first occurrence of "volumes:" in the section.
        sed -i "/$section_start/,/$section_end/ s|volumes:|volumes:\n    - ${src_path}:${dest_path}|" "$file"
        log_info "Added volume mapping ${src_path}:${dest_path} to ${file}."
    fi
}

#-----------------------------------------------
# Main function: configure_ssl_for_pulse
configure_ssl_for_pulse() {

    # Ensure required commands are available.
    for cmd in accelo sed awk grep docker; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command '$cmd' is not available. Aborting."
            exit 1
        fi
    done

    # Ask if this is a Pulse Core Server.
    echo -ne "${CYAN}Is this a Pulse Core Server? (yes/no): ${NC}"
    read -r is_pulse_core
    case "$is_pulse_core" in
        [Yy][Ee][Ss] | [Yy])
            is_pulse_core="yes"
            ;;
        [Nn][Oo] | [Nn])
            is_pulse_core="no"
            ;;
        *)
            log_error "Invalid input. Please enter 'yes' or 'no'."
            exit 1
            ;;
    esac

    if [[ "$is_pulse_core" == "yes" ]]; then
        # ----------------------------
        # Pulse Core Server configuration.
        # ----------------------------

        # Load the ad.sh profile.
        if [ -f /etc/profile.d/ad.sh ]; then
            source /etc/profile.d/ad.sh
            log_info "Loaded /etc/profile.d/ad.sh."
        else
            log_error "/etc/profile.d/ad.sh not found. Aborting."
            exit 1
        fi

        # Check that AcceloHome is set.
        if [[ -z "${AcceloHome:-}" ]]; then
            log_error "AcceloHome variable is not set. Please set it before running the script."
            exit 1
        fi

        # Prompt for the cacerts file path.
        read -e -p "Enter the complete path of the cacerts file: " cacerts_path
        if [ ! -f "$cacerts_path" ]; then
            log_error "The cacerts file does not exist at ${cacerts_path}. Aborting."
            exit 1
        fi

        # Define destination directory for SSL files and ensure it exists.
        local security_dir="${AcceloHome}/config/security"
        if ! sudo mkdir -p "$security_dir"; then
            log_error "Failed to create ${security_dir}."
            exit 1
        fi

        # Copy the cacerts file (as both cacerts and jssecacerts).
        cp "$cacerts_path" "${security_dir}/cacerts" || { log_error "Error copying cacerts."; exit 1; }
        cp "$cacerts_path" "${security_dir}/jssecacerts" || { log_error "Error copying jssecacerts."; exit 1; }
        sudo chmod 0655 "${security_dir}/"* || { log_error "Error setting permissions on files in ${security_dir}."; exit 1; }
        log_info "SSL files have been copied to ${security_dir} and permissions updated."

        # Define configuration directories.
        local docker_config="${AcceloHome}/config/docker"
        local addons_dir="${docker_config}/addons"

        # Ensure required configuration files exist or create them.
        if [ ! -f "${addons_dir}/ad-core-connectors.yml" ]; then
            accelo admin makeconfig ad-core-connectors || { log_error "Failed to create ad-core-connectors.yml."; exit 1; }
            log_info "Created ad-core-connectors.yml via accelo admin makeconfig."
        fi

        if [ ! -f "${docker_config}/ad-core.yml" ]; then
            accelo admin makeconfig ad-core || { log_error "Failed to create ad-core.yml."; exit 1; }
            log_info "Created ad-core.yml via accelo admin makeconfig."
        fi

        if [ ! -f "${addons_dir}/ad-fsanalyticsv2-connector.yml" ]; then
            accelo admin makeconfig ad-fsanalyticsv2-connector || { log_error "Failed to create ad-fsanalyticsv2-connector.yml."; exit 1; }
            log_info "Created ad-fsanalyticsv2-connector.yml via accelo admin makeconfig."
        fi

        # Verify that the SSL file was copied.
        if [ ! -f "${security_dir}/cacerts" ]; then
            log_error "The cacerts file does not exist at ${security_dir}/cacerts. Aborting."
            exit 1
        fi

        # Update volume mappings in configuration files.
        update_volume_in_config "${docker_config}/ad-core.yml" "ad-streaming:" "ulimits:" "${security_dir}/cacerts" "/usr/local/openjdk-8/lib/security/cacerts"
        update_volume_in_config "${docker_config}/ad-core.yml" "ad-streaming:" "ulimits:" "${security_dir}/jssecacerts" "/usr/local/openjdk-8/lib/security/jssecacerts"
        update_volume_in_config "${addons_dir}/ad-core-connectors.yml" "ad-connectors:" "ulimits:" "${security_dir}/cacerts" "/usr/local/openjdk-8/lib/security/cacerts"
        update_volume_in_config "${addons_dir}/ad-core-connectors.yml" "ad-connectors:" "ulimits:" "${security_dir}/jssecacerts" "/usr/local/openjdk-8/lib/security/jssecacerts"
        update_volume_in_config "${addons_dir}/ad-core-connectors.yml" "ad-sparkstats:" "ulimits:" "${security_dir}/cacerts" "/usr/local/openjdk-8/lib/security/cacerts"
        update_volume_in_config "${addons_dir}/ad-core-connectors.yml" "ad-sparkstats:" "ulimits:" "${security_dir}/jssecacerts" "/usr/local/openjdk-8/lib/security/jssecacerts"
        update_volume_in_config "${addons_dir}/ad-fsanalyticsv2-connector.yml" "ad-fsanalyticsv2-connector:" "ulimits:" "${security_dir}/cacerts" "/usr/local/openjdk-8/lib/security/cacerts"
        update_volume_in_config "${addons_dir}/ad-fsanalyticsv2-connector.yml" "ad-fsanalyticsv2-connector:" "ulimits:" "${security_dir}/jssecacerts" "/usr/local/openjdk-8/lib/security/jssecacerts"

        log_info "SSL configuration for Pulse Core Server completed successfully."

    else
        # ----------------------------
        # Non-Core Server branch.
        # ----------------------------
        log_info "Non-core server detected. Running 'docker ps' to check for the ad-fsanalyticsv2-connector service..."
        docker ps

        if docker ps --format '{{.Names}}' | grep -q 'ad-fsanalyticsv2-connector'; then
            log_info "Found ad-fsanalyticsv2-connector service running."

            # For non-core server, we still require AcceloHome to update configuration files.
            if [[ -z "${AcceloHome:-}" ]]; then
                log_error "AcceloHome variable is not set. Please set it before running the script."
                exit 1
            fi

            local security_dir="${AcceloHome}/config/security"
            local docker_config="${AcceloHome}/config/docker"
            local addons_dir="${docker_config}/addons"
            if ! sudo mkdir -p "$security_dir"; then
                log_error "Failed to create ${security_dir}."
                exit 1
            fi

            # Always prompt for the complete path of the cacerts file.
            read -e -p "Enter the complete path of the cacerts file: " cacerts_path
            if [ ! -f "$cacerts_path" ]; then
                log_error "The cacerts file does not exist at ${cacerts_path}. Aborting."
                exit 1
            fi

            cp "$cacerts_path" "${security_dir}/cacerts" || { log_error "Error copying cacerts."; exit 1; }
            cp "$cacerts_path" "${security_dir}/jssecacerts" || { log_error "Error copying jssecacerts."; exit 1; }
            sudo chmod 0655 "${security_dir}/"* || { log_error "Error setting permissions on files in ${security_dir}."; exit 1; }
            log_info "SSL files have been copied to ${security_dir} and permissions updated."

            # Ensure the ad-fsanalyticsv2-connector configuration file exists.
            if [ ! -f "${addons_dir}/ad-fsanalyticsv2-connector.yml" ]; then
                accelo admin makeconfig ad-fsanalyticsv2-connector || { log_error "Failed to create ad-fsanalyticsv2-connector.yml."; exit 1; }
                log_info "Created ad-fsanalyticsv2-connector.yml via accelo admin makeconfig."
            fi

            # Update volume mappings in ad-fsanalyticsv2-connector.yml.
            update_volume_in_config "${addons_dir}/ad-fsanalyticsv2-connector.yml" "ad-fsanalyticsv2-connector:" "ulimits:" "${security_dir}/cacerts" "/usr/local/openjdk-8/lib/security/cacerts"
            update_volume_in_config "${addons_dir}/ad-fsanalyticsv2-connector.yml" "ad-fsanalyticsv2-connector:" "ulimits:" "${security_dir}/jssecacerts" "/usr/local/openjdk-8/lib/security/jssecacerts"

            log_info "SSL configuration for ad-fsanalyticsv2-connector on non-core server completed successfully."
        else
            log_warn "ad-fsanalyticsv2-connector service not found in Docker. Skipping SSL configuration for non-core server."
        fi
    fi
}

#-----------------------------------------------
# Main execution.
configure_ssl_for_pulse
