#!/bin/bash
# Acceldata Inc.

GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Function to print section headers
print_section() {
  echo -e "${BLUE}\n============================================================="
  echo -e " $1"
  echo -e "=============================================================${NC}\n"
}


# Function to display a list of items with indentation
display_list() {
  local item_number=1
  for item in "$@"; do
    item=$(echo "$item" | sed 's/^ *- *//')
    if [ $item_number -eq 1 ]; then
      printf "${GREEN}➟  %s${NC}\n" "$item"
    else
      printf "${GREEN}➟  %s${NC}\n" "$item"
    fi
    ((item_number++))
  done
}



# Function to print Pulse Server information
print_pulse_info() {
  print_section "Pulse Server Information"
  printf "Hostname:\t\t|  %s\n" "$pulse_hostname"
  printf "Avaialble Root Dir:\t|  %.2f GB\n" "$available_space_root_gb"
  printf "AcceloHome Directory:\t|  %.2f GB\n" "$available_space_accelo_gb"
  printf "Total Memory:\t\t|  %.2f GB\n" "$total_memory_gb"
  printf "Free Memory:\t\t|  %.2f GB\n" "$free_memory_gb"
  printf "CPU Cores:\t\t|  %d\n" "$cpu_cores"
  printf "Sockets:\t\t|  %d\n" "$sockets"
  printf "Cores per Socket:\t|  %d\n" "$cores_per_socket"
  printf "Pulse Version:\t\t|  %s\n" "$pulse_version"
  printf "ImageTag Version:\t|  %s\n" "$image_tag"
}

# Check if Pulse is installed
if [ ! -f "/etc/profile.d/ad.sh" ] || [ ! -f "$AcceloHome/config/accelo.yml" ]; then
  echo -e "${RED}Error: Please check if Pulse is installed or not.${NC}"
  exit 1
fi

# Get Pulse Hostname
pulse_hostname=$(hostname)

# Get available disk space for the root directory
df_root_output=$(df -h /)
available_space_root_gb=$(echo "$df_root_output" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')

# Get available disk space for the AcceloHome directory
df_accelo_output=$(df -h "$AcceloHome")
available_space_accelo_gb=$(echo "$df_accelo_output" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')

# Free Memory
free_memory_gb=$(free -g | awk 'NR==2 {print $4}')
total_memory_gb=$(free -g | awk 'NR==2 {print $2}')


# Number of CPU Cores, Sockets, and Cores per socket
cpu_cores=$(nproc)
cpu_info=$(lscpu)
sockets=$(echo "$cpu_info" | grep "Socket(s):" | awk '{print $2}')
cores_per_socket=$(echo "$cpu_info" | grep "Core(s) per socket:" | awk '{print $4}')

# Get Pulse version and number of services running
accelo_info_output=$(accelo info)
pulse_version=$(echo "$accelo_info_output" | grep "Accelo CLI Version:" | awk '{print $4}')
services=($(echo "$accelo_info_output" | awk '/Services running in this stack:/ {flag=1; next} flag; /^$/ {flag=0}' | sed 's/^[ \-]*//'))

# Get list of Cluster added to Pulse Server
AcceloHome="/data01/acceldata"
work_directory="$AcceloHome/work"
if [ -d "$work_directory" ]; then
  # Use 'find' to search for directories with both files
  clusters=$(find "$work_directory" -mindepth 1 -type d -exec test -e "{}/hydra_hosts.yml" \; -exec test -e "{}/vars.yml" \; -exec basename {} \;)

else
  echo "Work directory $work_directory not found"
fi

# Space utilized by all folders in $AcceloHome directory
data_directory="$AcceloHome/data"
folder_usages=($(du -sh "$data_directory"/*))

# Image tag version
accelo_config_file="$AcceloHome/config/accelo.yml"

# Check if the accelo.yml file exists
if [ -f "$accelo_config_file" ]; then
  # Use 'grep' to extract the 'ImageTag' value from the config file
  image_tag=$(grep 'ImageTag:' "$accelo_config_file" | awk '{print $2}')
fi

# Call the function to print Pulse Server information
print_pulse_info

# Call the function to print Services
print_section "Services running in this stack"
display_list "${services[@]}"

# Call the function to print Clusters
print_section "Clusters added to Pulse Server"
for cluster in $clusters; do
  printf "${GREEN}⬨  %s${NC}\n" "$cluster"
done

# Call the function to print Disk Space Utilization
print_section "Disk Space Utilized by Each Folder in $AcceloHome/data"
du_output=$(du -sh $AcceloHome/data/*)
while read -r line; do
  printf "${YELLOW}‣  %s${NC}\n" "$line"
done <<< "$du_output"

backup_pulse_config() {

  read -p "Do you want to take a backup of Pulse related configs (yes/no)? " answer

  if [ "$answer" = "yes" ] || [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    timestamp=$(date +\%Y\%m\%d\%H\%M\%S)
    backup_file="$AcceloHome/acceldata_backup_$timestamp.tar.gz"

    # Execute the 'find' and 'tar' commands
    echo "Creating a backup, please wait..."
    find "$AcceloHome" -type f \( -name "*.conf" -o -name "accelo.log" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.json" -o -name "*.actions" -o -name "*.xml" -o -name ".activecluster" -o -name ".dist" \) | tar --exclude="*/director/*" --exclude="*/data/*" -zcvf "$backup_file" -T - > /dev/null 2> backup_output.txt

    # Check if the backup was successful
    if [ $? -eq 0 ]; then
      echo -e "✔️ Backup completed successfully. Pulse config file: ${GREEN}$backup_file${NC}"
    else
      echo "Backup failed."
    fi
  else
    echo "Backup operation canceled."
  fi
}
backup_pulse_config
