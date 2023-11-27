#!/bin/bash
# Acceldata Inc.

#One click script to upgrade pulse

# Define colors for output
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
BOLD_MAGENTA="\033[1;35m"
NC="\033[0m" # No Color

# Information message
echo -e "${BLUE}
██████  ██    ██ ██      ███████ ███████     ██    ██ ██████   ██████  ██████   █████  ██████  ███████
██   ██ ██    ██ ██      ██      ██          ██    ██ ██   ██ ██       ██   ██ ██   ██ ██   ██ ██
██████  ██    ██ ██      ███████ █████       ██    ██ ██████  ██   ███ ██████  ███████ ██   ██ █████
██      ██    ██ ██           ██ ██          ██    ██ ██      ██    ██ ██   ██ ██   ██ ██   ██ ██
██       ██████  ███████ ███████ ███████      ██████  ██       ██████  ██   ██ ██   ██ ██████  ███████
${NC}"
echo -e "${YELLOW}Upgrade Path for Pulse Versions:${NC}"
echo -e "If current Pulse version is ${BLUE}2.x.x${NC}, upgrade path to the latest Pulse version is:"
echo -e "   ${GREEN}Pulse 2.x.x${NC} --> ${GREEN}latest Pulse 3.0.x${NC} --> ${GREEN}latest Pulse 3.2.x|3.x${NC}"
echo -e "If current Pulse version is ${BLUE}3.0.x or 3.1.x or 3.2.x${NC}, upgrade path to the latest Pulse version is:"
echo -e "   ${GREEN}Pulse 3.0.x or 3.1.x or 3.2.x${NC} --> ${GREEN}latest Pulse 3.2.x|3.3.x${NC}"
echo -e "${BLUE}where x is the latest available Pulse version"

# Function to execute a command and log output
# Usage: execute_command <command> <log_file> [redirect_output]
execute_command() {
  local command="$1"
  local log_file="$2"
  local redirect_output="$3"

  echo -e "${YELLOW}Executing: $command${NC}"
  if [ "$redirect_output" == "true" ]; then
    eval "$command" >> "$log_file"
  else
    eval "$command" | tee "$log_file"
  fi

  local exit_code=$?
  if [ $exit_code -eq 0 ]; then
    echo -e "${GREEN}Success: $command${NC}"
  else
    echo -e "${RED}Error: $command${NC}"
    exit 1
  fi
}

# Function to update ImageTag in config file
update_image_tag() {
  sed -i "s/ImageTag: $1/ImageTag: $2/" "$3"
}

# Main script
# Check if Pulse is installed
if [ ! -f "/etc/profile.d/ad.sh" ] || [ ! -f "$AcceloHome/config/accelo.yml" ]; then
  echo -e "${RED}Error: Please check if Pulse is installed or not.${NC}"
  exit 1
fi

echo -e "${BLUE}Step 1: Backup Dashplots Charts${NC}"
echo -e "${YELLOW}Before proceeding, take a backup of Dashplots Charts using Export option , Alerts, List of Addons${NC}"
echo -e "${YELLOW}If taken, enter 'y' to proceed. If not taken, refer to: ${BLUE}https://docs.acceldata.io/pulse/documentation/upgrade-pulse${NC}"
read -p "Have you taken the backup? (y/n): " backup_choice

if [ "$backup_choice" != "y" ]; then
  echo -e "${RED}Please take the backup before proceeding.${NC}"
  exit 1
fi

# Check if Accelo binary and Pulse images are copied and loaded into Docker
read -p "Have you copied the Accelo binary and loaded Pulse images into Docker? (yes/no): " copy_and_load

if [ "$copy_and_load" == "no" ]; then
  echo "Please make sure you've copied the Accelo binary to $AcceloHome and loaded the Pulse docker images."
  echo "Ref: https://docs.acceldata.io/pulse-3.0.x/pulse/upgrade-pulse"
  echo "Once done, please run the upgrade process again."
  exit
fi

#Read the Pulse Version(VERSION) to upgrade to
echo -e "${BLUE}Step 2: Choose Pulse Version${NC}"
echo -e "Choose the Pulse version to upgrade to:"
echo -e "${YELLOW}For 3.0.x versions (0 to 12), provide the version number (e.g.3.0.12,3.2.3,3.3.0)."
echo -e "Provide the full version number.${NC}"
read -p "Pulse Version to upgrade: " VERSION

# Check if 3.1.x version is provided
if [[ "$VERSION" == 3.1.* ]]; then
  echo -e "${BLUE}Step 3: Check Pulse Hooks Deployment${NC}"
  echo -e "${YELLOW}Did you perform 'Pulse Hooks Deployment'? (y/n)"
  echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse-3.1.0/pulse/cluster-configuration-changes#place-hook-jars${NC}"
  read -p "Have you performed the 'Pulse Hooks Deployment'? (y/n): " hooks_choice

  if [ "$hooks_choice" != "y" ]; then
    echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse-3.1.0/pulse/upgrade-from-pulse-3-0-3-to-3-1-1#pulse-hooks-deployment${NC}"
    echo -e "${RED}Please make the 'Place Hook Jars' Changes in the cluster before proceeding.${NC}"
    exit 1
  fi
fi

# Check if 3.2.x version is provided
if [[ "$VERSION" == 3.2.* ]]; then
  echo -e "${BLUE}Step 3: Check Pulse Hooks Deployment${NC}"
  echo -e "${YELLOW}Did you perform 'Pulse Hooks Deployment'? (y/n)"
  echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse-3.2.0/pulse/cluster-configuration-changes#place-hook-jars${NC}"
  read -p "Have you performed the 'Pulse Hooks Deployment'? (y/n): " hooks_choice

  if [ "$hooks_choice" != "y" ]; then
    echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse-3.2.0/pulse/upgrade-from-3-1-1-to-3-2-0#pulse-hooks-deployment${NC}"
    echo -e "${RED}Please make the 'Place Hook Jars' Changes in the cluster before proceeding.${NC}"
    exit 1
  fi
fi

# Check if 3.3.x version is provided
if [[ "$VERSION" == 3.3.* ]]; then
  echo -e "${BLUE}Step 3: Check Pulse Hooks Deployment${NC}"
  echo -e "${YELLOW}Did you perform 'Pulse Hooks Deployment'? (y/n)"
  echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse/documentation/upgrade-to-version-3-3-0-from-previous-versions${NC}"
  read -p "Have you performed the 'Pulse Hooks Deployment'? (y/n): " hooks_choice

  if [ "$hooks_choice" != "y" ]; then
    echo -e "If not, refer to: ${BLUE}https://docs.acceldata.io/pulse/documentation/upgrade-to-version-3-3-0-from-previous-versions${NC}"
    echo -e "${RED}Please make the 'Place Hook Jars' Changes in the cluster before proceeding.${NC}"
    exit 1
  fi
fi

# Pulse upgrade from old version to new version
source /etc/profile.d/ad.sh
#log_file="$AcceloHome/pulse_upgrade_logs.log"
config_file="$AcceloHome/config/accelo.yml"

echo -e "${BLUE}Step 4: Updating ImageTag in Config${NC}"
# Get the current ImageTag version
current_version=$(awk '/ImageTag: [0-9.]*/ { print $2 }' "$config_file")

if [ -z "$current_version" ]; then
  echo -e "${RED}Error: Unable to retrieve the current ImageTag version.${NC}"
  exit 1
fi

echo -e "Current ImageTag version:-->${CYAN}$current_version${NC}<--. Is this current version correct? (yes/no):\c"
read update_choice
if [ "$update_choice" == "no" ]; then
    echo -e "Enter the ${CYAN}correct version${NC}:\c"
    read current_version
fi

update_image_tag "$current_version" "$VERSION" "$config_file"

export db_name=$(ls -1 "$AcceloHome/work" | grep -v "license" | head -n 1)
# Write auotomated way to get last 7 days epoc time in miliseconds
epoc_7=$(date -d "7 days ago" +%s%3N)

# Path to the .conf file
conf_file="$AcceloHome/config/acceldata_$db_name.conf"

# Check if the .conf file exists
if [ ! -f "$conf_file" ]; then
  echo "Error: The conf file '$conf_file' does not exist."
  exit 1
fi

# Extract the value of cli.distro
cli_distro=$(grep -oP 'cli\.distro\s*=\s*"\K[^"]+' "$conf_file")

log_file="$AcceloHome/pulse_upgrade_$current_version.log"

# Check if the extracted value is empty
if [ -z "$cli_distro" ]; then
  echo "Error: Unable to extract the value of cli.distro from the conf file."
  exit 1
fi

echo -e "${CYAN}The value of cli.distro is:${NC} $cli_distro"

execute_upgrade_2_1_1() {
  docker exec -it ad-db_default bash -c "mongo mongodb://accel:ACCELUSER_01082018@localhost:27017/admin <<-EOSQL
show databases;
use $db_name;
db.yarn_tez_queries.renameCollection(\"yarn_tez_queries_details\")
EOSQL"
}

execute_upgrade_2_1_1_mongoexport() {
  docker exec -it ad-db_default bash -c "mongoexport --username=\"accel\" --password=\"ACCELUSER_01082018\" --host=localhost:27017 --authenticationDatabase=admin --db=\"$db_name\" --collection=yarn_tez_queries_details  -f '__id,callerId,user,status,timeTaken,queue,appId,hiveAddress,dagId,uid,queue,counters,tablesUsed,startTime,endTime,llap' --query='{\"startTime\": {\"\$gte\": $epoc_7}}' --out=/tmp/tqq.json"
}

execute_upgrade_2_1_1_mongoimport() {
  docker exec -it ad-db_default bash -c "mongoimport  --username=\"accel\" --password=\"ACCELUSER_01082018\"  --host=localhost:27017 --authenticationDatabase=admin --db=\"$db_name\" --collection=yarn_tez_queries --file=/tmp/tqq.json"
}

execute_upgrade() {
  docker exec -ti ad-pg_default bash -c "psql -v ON_ERROR_STOP=1 --username \"pulse\" <<-EOSQL
\connect ad_management dashplot
BEGIN;
truncate table ad_management.dashplot_hierarchy cascade;
truncate table ad_management.dashplot cascade;
truncate table ad_management.dashplot_visualization cascade;
truncate table ad_management.dashplot_variables cascade;
INSERT INTO ad_management.dashplot_variables (stock_version,\"name\",definition,dashplot_id,dashplot_viz_id,\"global\") VALUES
(1,'appid','{\"_id\": \"1\", \"name\": \"appid\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"description\": \"AppID to be provided for user customization\", \"defaultValue\": \"app-20210922153251-0000\", \"selectionType\": \"\", \"stock_version\": 1}',NULL,NULL,true),
(1,'appname','{\"_id\": \"2\", \"name\": \"appname\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"description\": \"\", \"defaultValue\": \"Databricks Shell\", \"selectionType\": \"\", \"stock_version\": 1}',NULL,NULL,true),
(1,'FROM_DATE_EPOC','{\"id\": 0, \"_id\": \"3\", \"name\": \"FROM_DATE_EPOC\", \"type\": \"date\", \"query\": \"\", \"global\": true, \"shared\": false, \"options\": [], \"separator\": \"\", \"dashplot_id\": null, \"description\": \"\", \"displayName\": \"\", \"defaultValue\": \"1645641000000\", \"selectionType\": \"\", \"stock_version\": 1, \"dashplot_viz_id\": null}',NULL,NULL,true),
(1,'TO_DATE_EPOC','{\"id\": 0, \"_id\": \"4\", \"name\": \"TO_DATE_EPOC\", \"type\": \"date\", \"query\": \"\", \"global\": true, \"shared\": false, \"options\": [], \"separator\": \"\", \"dashplot_id\": null, \"description\": \"\", \"displayName\": \"\", \"defaultValue\": \"1645727399000\", \"selectionType\": \"\", \"stock_version\": 1, \"dashplot_viz_id\": null}',NULL,NULL,true),
(1,'FROM_DATE_SEC','{\"_id\": \"5\", \"name\": \"FROM_DATE_SEC\", \"type\": \"date\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"defaultValue\": \"1619807400\", \"selectionType\": \"\"}',NULL,NULL,true),
(1,'TO_DATE_SEC','{\"_id\": \"6\", \"name\": \"TO_DATE_SEC\", \"type\": \"date\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"defaultValue\": \"1622477134\", \"selectionType\": \"\"}',NULL,NULL,true),
(1,'dbcluster','{\"_id\": \"7\", \"name\": \"dbcluster\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"description\": \"\", \"defaultValue\": \"job-4108-run-808\", \"selectionType\": \"\", \"stock_version\": 1}',NULL,NULL,true),
(1,'id','{\"_id\": \"8\", \"name\": \"id\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"defaultValue\": \"hive_20210906102708_dcd9df9d-91b8-421a-a70f-94beed03e749\", \"selectionType\": \"\"}',NULL,NULL,true),
(1,'dagid','{\"_id\": \"9\", \"name\": \"dagid\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"description\": \"\", \"defaultValue\": \"dag_1631531795196_0009_1\", \"selectionType\": \"\", \"stock_version\": 1}',NULL,NULL,true),
(1,'hivequeryid','{\"_id\": \"10\", \"name\": \"hivequeryid\", \"type\": \"text\", \"query\": \"\", \"shared\": true, \"options\": [], \"separator\": \"\", \"defaultValue\": \"hive_20210912092701_cef246fa-cb3c-4130-aece-e6cac82751bd\", \"selectionType\": \"\"}',NULL,NULL,true);
INSERT INTO ad_management.dashplot_variables (stock_version,\"name\",definition,dashplot_id,dashplot_viz_id,\"global\") VALUES
(1,'TENANT_NAME','{\"_id\": \"11\", \"name\": \"TENANT_NAME\", \"type\": \"text\", \"query\": \"\", \"global\": true, \"shared\": false, \"options\": [], \"separator\": \"\", \"description\": \"\", \"defaultValue\": \"acceldata\", \"selectionType\": \"\", \"stock_version\": 1}',NULL,NULL,true);
COMMIT;
EOSQL"
}

# Function to check if a version is greater than or equal to a target version
version_ge() {
  local target_version=$1
  local version_to_check=$2
  if [[ "$(printf '%s\n' "$target_version" "$version_to_check" | sort -V | head -n1)" == "$target_version" ]]; then
    return 0 # Version is greater than or equal to the target
  else
    return 1 # Version is less than the target
  fi
}

# Function to upgrade Docker if necessary
upgrade_docker_if_needed() {
  # Check if the third digit of the version is greater than 3
  ##if [ "${VERSION:4:1}" -gt 3 ]; then
  if [ "$(echo -e "$VERSION\n3.2.3" | awk '$1 >= $2')" ]; then
    echo "Pulse version is greater than Pulse 3.2.3"

    # Check Docker version
    docker_version=$(docker --version | awk '{print $3}' | tr -d ',')
    echo "Current Docker version: $docker_version"

    # Compare Docker version
    if version_ge "20.10.0" "$docker_version"; then
      echo "Docker version is $docker_version which is 20.10.0 or higher."
    else
      echo "Docker version is $docker_version which is less than 20.10.0."
      read -p "Do you want to proceed with Docker upgrade? (yes/no): " docker_upgrade_choice
      if [ "$docker_upgrade_choice" == "yes" ]; then
        # Uninstall current Docker
        echo "Uninstalling current Docker..."
        yum remove -y docker-ce docker-ce-cli containerd.io

        # Install Docker latest version
        echo "Installing Docker latest version..."
        yum install -y docker-ce docker-ce-cli containerd.io

        # Enable and start Docker
        systemctl enable docker
        systemctl start docker

        echo "Docker has been upgraded and started."
      else
        echo "Docker upgrade cancelled."
      fi
    fi
  else
    echo ""
  fi
}

# Function to check if a Docker image exists
check_image_exists() {
  local image_name="$1"
  if docker image inspect "$image_name" &>/dev/null; then
    return 0 # Image exists
  else
    return 1 # Image does not exist
  fi
}

# Function to prompt for yes/no answer
prompt_yes_no() {
  while true; do
    read -p "$1 (yes/no): " answer
    case $answer in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    *) echo "Please answer yes or no." ;;
    esac
  done
}

upgrade_mongodb_version_5() {
  version=$(docker exec -it ad-db_default mongosh --eval "db.version()" | awk '/Using MongoDB/{print $3}' | tr -d '\r')

  if [[ "$version" == "5.0.16" ]]; then
    echo -e "${GREEN}MongoDB version is already 5.0.16. No need to upgrade.${NC}"
  else
    echo -e "${RED}MongoDB version is not 5.0.16. Upgrading...${NC}"

    # Check if the 'migrate-5.0.16' image exists
    if ! check_image_exists "191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:migrate-5.0.16"; then
      echo -e "${RED}The 'migrate-5.0.16' image does not exist.${NC}"

      # Prompt to load the tar file
      if prompt_yes_no "Do you have the tar file 'ad-database-5.tgz' to load?"; then
        read -p "Enter the path to the tar file: " TARBALL_PATH
        if [ -f "$TARBALL_PATH" ]; then
          echo -e "${GREEN}Loading the Docker tarball...${NC}"
          docker load -i "$TARBALL_PATH"
        else
          echo -e "${RED}The specified tar file '$TARBALL_PATH' does not exist.${NC}"
        fi
      else
        echo -e "${RED}The tar file 'ad-database-5.tgz' is not present.${NC}"
        echo -e "${RED}Check with Acceldata Support to get the necessary Docker image.${NC}"
      fi
    else
      echo -e "${GREEN}The 'migrate-5.0.16' image is present. Proceeding with the tagging command...${NC}"
      docker tag 191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:migrate-5.0.16 191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:$VERSION
    fi
    echo -e "${GREEN} Stopping ad-db_default and deploying the pulse core.${NC}"
    docker stop ad-db_default && docker rm ad-db_default
    yes | accelo deploy core
  fi
}

# Function to check the MongoDB version and image existence
upgrade_mongodb_version_6() {
  version=$(docker exec -it ad-db_default mongosh --eval "db.version()" | awk '/Using MongoDB/{print $3}' | tr -d '\r')

  if [[ "$version" == "6.0.5" ]]; then
    echo -e "${GREEN}MongoDB version is already 6.0.5. No need to upgrade.${NC}"
  else
    echo -e "${RED}MongoDB version is not 6.0.5. Upgrading...${NC}"

    # Check if the 'migrate-6.0.5' image exists
    if ! check_image_exists "191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:migrate-6.0.5"; then
      echo -e "${RED}The 'migrate-6.0.5' image does not exist.${NC}"

      # Prompt to load the tar file
      if prompt_yes_no "Do you have the tar file 'ad-database-6.tgz' to load?"; then
        read -p "Enter the path to the tar file: " TARBALL_PATH
        if [ -f "$TARBALL_PATH" ]; then
          echo -e "${GREEN}Loading the Docker tarball...${NC}"
          docker load -i "$TARBALL_PATH"
        else
          echo -e "${RED}The specified tar file '$TARBALL_PATH' does not exist.${NC}"
        fi
      else
        echo -e "${RED}The tar file 'ad-database-6.tgz' is not present.${NC}"
        echo -e "${RED}Check with Acceldata Support to get the necessary Docker image.${NC}"
      fi
    else
      echo -e "${GREEN}The 'migrate-6.0.5' image is present. Proceeding with the tagging command...${NC}"
      docker tag 191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:migrate-6.0.5 191579300362.dkr.ecr.us-east-1.amazonaws.com/acceldata/ad-database:$VERSION
    fi
    echo -e "${GREEN} Stopping ad-db_default and deploying the pulse core.${NC}"
    docker stop ad-db_default && docker rm ad-db_default
    yes | accelo deploy core
  fi
}

# Ask if this is a Pulse Core Server
echo -e "${CYAN}Is this a Pulse Core Server? (yes/no):${NC}\c"
read is_pulse_core
case "$is_pulse_core" in
[Yy][Ee][Ss] | [Yy])
  is_pulse_core="yes"
  ;;
[Nn][Oo] | [Nn])
  is_pulse_core="no"
  ;;
*)
  echo "Invalid input. Please enter 'yes' or 'no'."
  exit 1
  ;;
esac

# Check if 3.0.x version is provided
if [[ "$current_version" == 2.1.* && "$VERSION" == 3.0.* ]]; then
  # Additional commands for Pulse 3.0.x version
  source /etc/profile.d/ad.sh
  execute_command "docker stop ad-streaming_default" "$log_file"
  execute_command "docker stop ad-connectors_default" "$log_file"

  execute_upgrade_2_1_1
  execute_upgrade_2_1_1_mongoexport
  execute_upgrade_2_1_1_mongoimport
  execute_command "accelo admin database index-db" "$log_file"
  accelo info | tee /tmp/accelo_info.txt
  execute_command "accelo set" "$log_file"
  execute_command "echo | accelo migrate -v 3.0.0" "$log_file"

  if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
    execute_command "yes | accelo deploy core" "$log_file"
  fi

  execute_command "accelo deploy addons"

  if [[ "$cli_distro" == "HWX" ]]; then
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    execute_command "accelo reconfig cluster -a" "$log_file"
  fi
fi

# Check if 3.0.x version is provided
if [[ "$current_version" == 2.2.* && "$VERSION" == 3.0.* ]]; then
  echo "Upgrading from Pulse 2.2.x to 3.0.x."
  source /etc/profile.d/ad.sh
  accelo info | tee /tmp/accelo_info.txt
  execute_command "accelo set" "$log_file"
  echo "accelo migrate -v 3.0.0"
  accelo migrate -v 3.0.0

  if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
    execute_command "yes | accelo deploy core" "$log_file"
  fi

  cat /tmp/accelo_info.txt
  execute_command "accelo deploy addons"
  execute_command "accelo reconfig cluster -a" "$log_file"
  echo ""
  echo "Executing database queries Post Upgrade Tasks..."
  execute_upgrade
  accelo info
  if [[ "$cli_distro" == "HWX" ]]; then
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  elif [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse-3.0.x/pulse/hydra-services--parcel-#1-delete-the-hydra-service"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
  fi
fi

# Check if 3.0.x version is provided
if [[ "$current_version" == 3.0.* && "$VERSION" == 3.0.* ]]; then
  # Additional commands for Pulse 3.0.x version
  source /etc/profile.d/ad.sh
  execute_command "yes | accelo admin database push-config -a" "$log_file"
  execute_command "accelo login docker" "$log_file"

  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet
  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
    execute_command "yes | accelo pull all" "$log_file" "true"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded
    if [ "$docker_images_loaded" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "accelo reconfig cluster -a" "$log_file"
    elif [ "$docker_images_loaded" == "no" ]; then
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi

  if [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse-3.0.x/pulse/hydra-services--parcel-#1-delete-the-hydra-service"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
    echo "- Upgrade the Parcel"
    echo "- Install Hydra service"
  fi
fi

# Check if 3.1.x version is provided
if [[ "$current_version" == 3.1.* && "$VERSION" == 3.1.* ]]; then
  # Additional commands for Pulse 3.1.x version
  source /etc/profile.d/ad.sh
  execute_command "yes | accelo admin database push-config -a" "$log_file"
  execute_command "accelo login docker" "$log_file"
  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet
  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" && "$cli_distro" == "HWX" ]; then
    execute_command "yes | accelo pull all" "$log_file" "true"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded
    if [ "$docker_images_loaded" == "yes" && "$cli_distro" == "HWX" ]; then
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "accelo reconfig cluster -a" "$log_file"
    else
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi
fi

# Check if 3.2.x version is provided
if [[ "$current_version" == 3.0.* && "$VERSION" == 3.2.* ]]; then
  echo "Upgrading from Pulse 3.0.x to 3.2.x..."
  source /etc/profile.d/ad.sh
  # Call the function to upgrade Docker if needed
  upgrade_docker_if_needed
  execute_command "yes | accelo admin database push-config -a" "$log_file"
  execute_command "accelo reconfig cluster -a" "$log_file"
  execute_command "accelo migrate -v 3.1.0" "$log_file"
  execute_command "accelo migrate -v 3.2.0" "$log_file"
  execute_command "yes | accelo admin database push-config -a" "$log_file"

  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet

  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
    execute_command "accelo login docker" "$log_file"
    execute_command "yes | accelo pull all" "$log_file" "true"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
      execute_command "yes | accelo deploy core" "$log_file"
    fi
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded
    if [ "$docker_images_loaded" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
      if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
        execute_command "yes | accelo deploy core" "$log_file"
      fi
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "accelo reconfig cluster -a" "$log_file"
    elif [ "$docker_images_loaded" == "no" ]; then
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi

  if [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    execute_command "yes | accelo deploy core" "$log_file"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse-3.0.x/pulse/hydra-services--parcel-#1-delete-the-hydra-service"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
  fi
fi


if [[ "$current_version" == 3.1.* && "$VERSION" == 3.2.* ]]; then
  echo "Upgrading from Pulse 3.1.x to 3.2.x."
  source /etc/profile.d/ad.sh

  # Call the function to upgrade Docker if needed
  upgrade_docker_if_needed

  #  execute_command "yes | accelo admin database migrate" "$log_file"
  execute_command "accelo reconfig cluster -a" "$log_file"
  execute_command "accelo migrate -v 3.2.0" "$log_file"
  execute_command "yes | accelo admin database push-config -a" "$log_file"

  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet
  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
    execute_command "accelo login docker" "$log_file"
    execute_command "yes | accelo pull all" "$log_file" "true"
    if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
      execute_command "yes | accelo deploy core" "$log_file"
    fi
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded

    if [ "$docker_images_loaded" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
      if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
        execute_command "yes | accelo deploy core" "$log_file"
      fi
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "accelo reconfig cluster -a" "$log_file"
    elif [ "$docker_images_loaded" == "no" ]; then
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi

  if [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    execute_command "yes | accelo deploy core" "$log_file"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse-3.0.x/pulse/hydra-services--parcel-#1-delete-the-hydra-service"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
  fi
fi

if [[ "$current_version" == 3.2.* && "$VERSION" == 3.2.* ]]; then
  echo "Upgrading from Pulse $current_version to $VERSION"
  source /etc/profile.d/ad.sh

  # Call the function to upgrade Docker if needed
  upgrade_docker_if_needed

  #  execute_command "yes | accelo admin database migrate" "$log_file"
  execute_command "env PULSE_HIVE_LLAP_ENABLED=false accelo reconfig cluster -a" "$log_file"
  execute_command "accelo migrate -v 3.2.0" "$log_file"
  execute_command "yes | accelo admin database push-config -a" "$log_file"

  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet
  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
    execute_command "accelo login docker" "$log_file"
    execute_command "yes | accelo pull all" "$log_file" "true"
    if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
      execute_command "yes | accelo deploy core" "$log_file"
    fi
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "env PULSE_HIVE_LLAP_ENABLED=false accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded

    if [ "$docker_images_loaded" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
      if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
        execute_command "yes | accelo deploy core" "$log_file"
      fi
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "env PULSE_HIVE_LLAP_ENABLED=false accelo reconfig cluster -a" "$log_file"
    elif [ "$docker_images_loaded" == "no" ]; then
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi

  if [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    execute_command "yes | accelo deploy core" "$log_file"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse-3.0.x/pulse/hydra-services--parcel-#1-delete-the-hydra-service"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
  fi
fi

# Check if 3.3.x version is provided
if [[ ( "$current_version" == 3.0.* || "$current_version" == 3.2.* || "$current_version" == 3.3.* ) && "$VERSION" == 3.3.* ]]; then
  echo "Upgrading from Pulse $current_version to 3.3.x"
  source /etc/profile.d/ad.sh
  # Call the function to upgrade Docker if needed
  upgrade_docker_if_needed
  execute_command "yes | accelo admin database push-config -a" "$log_file"
  execute_command "accelo reconfig cluster -a" "$log_file"
  execute_command "accelo migrate -v 3.0.0 -i $current_version -a" "$log_file"
  execute_command "yes | accelo admin database push-config -a" "$log_file"

  echo -e "${BOLD_MAGENTA}Do you have internet access to pull Docker images? (yes/no):${NC}\c"
  read has_internet

  # Check if you have internet to pull Docker images
  if [ "$has_internet" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
    execute_command "accelo login docker" "$log_file"
    execute_command "accelo deploy core" "$log_file"
    execute_command "yes | accelo pull all" "$log_file" "true"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
      execute_command "yes | accelo deploy core" "$log_file"
    fi
    execute_command "accelo uninstall remote" "$log_file"
    execute_command "yes | accelo deploy hydra" "$log_file"
    execute_command "yes | accelo admin database push-config -a" "$log_file"
    execute_command "accelo reconfig cluster -a" "$log_file"
  else
    # Ask if new Pulse Docker images are loaded
    echo -e "${MAGENTA}Have you loaded the new Pulse $VERSION Docker images? (yes/no):${NC}\c"
    read docker_images_loaded
    if [ "$docker_images_loaded" == "yes" ] && [ "$cli_distro" == "HWX" ]; then
      if [[ "$is_pulse_core" == "yes" || "$is_pulse_core" == "y" ]]; then
        execute_command "yes | accelo deploy core" "$log_file"
      fi
      execute_command "yes | accelo restart all -d" "$log_file" "true"
      execute_command "accelo uninstall remote" "$log_file"
      execute_command "yes | accelo deploy hydra" "$log_file"
      execute_command "yes | accelo admin database push-config -a" "$log_file"
      execute_command "accelo reconfig cluster -a" "$log_file"
    elif [ "$docker_images_loaded" == "no" ]; then
      echo "Please load the Docker images for Pulse $VERSION."
      echo "Then execute the following commands for HDP/ODP Distribution:"
      echo "yes | accelo restart all -d"
      echo "accelo uninstall remote"
      echo "yes | accelo deploy hydra"
      echo "yes | accelo admin database push-config -a"
      echo "accelo reconfig cluster -a"
    fi
  fi

  if [[ "$cli_distro" == "CLDR" ]]; then
    echo ""
    execute_command "yes | accelo deploy core" "$log_file"
    execute_command "yes | accelo restart all -d" "$log_file" "true"
    echo "Upgrade Pulse Agent:"
    echo "Follow these steps: https://docs.acceldata.io/pulse/documentation/hydra-services--parcel-"
    echo "- Delete the Hydra service"
    echo "- Deactivate the Parcel"
    echo "- Remove the Parcel from the hosts"
    echo "- Delete the Parcel"
    echo "- Restart the cloudera-scm-server"
  fi
fi

# Print the additional message
echo "Import the zip file exported in the step 1 above with the < 3.0.0 dashboard option checked into the dashplot studio."

echo -e "${GREEN}Pulse Upgrade completed successfully to Pulse $VERSION.${NC}"
