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
      printf "${GREEN}|  %s${NC}\n" "$item"
    else
      printf "${GREEN}|  -  %s${NC}\n" "$item"
    fi
    ((item_number++))
  done
}



# Function to print Pulse Server information
print_pulse_info() {
  print_section "Pulse Server Information"
  printf "Hostname:\t\t|  %s\n" "$pulse_hostname"
  printf "AcceloHome Used Space:\t|  %s\n" "$used_space_accelo"
  printf "AcceloHome Free Space:\t|  %s\n" "$available_space_accelo"
  printf "Total Memory:\t\t|  %s\n" "$total_memory"
  printf "Free Memory:\t\t|  %s\n" "$free_memory"
  printf "CPU Cores:\t\t|  %d\n" "$cpu_cores"
  printf "Sockets:\t\t|  %d\n" "$sockets"
  printf "Cores per Socket:\t|  %d\n" "$cores_per_socket"
  printf "Pulse Version:\t\t|  %s\n" "$pulse_version"
  printf "ImageTag Version:\t|  %s\n" "$image_tag"
  printf "OS Version:\t\t|  %s\n" "$os_version"
  printf "SELinux Status:\t\t|  %s\n" "$selinux_status"
}

# Check if Pulse is installed
if [ ! -f "/etc/profile.d/ad.sh" ] || [ ! -f "$AcceloHome/config/accelo.yml" ]; then
  echo -e "${RED}Error: Please check if Pulse is installed or not.${NC}"
  exit 1
fi

# Get Pulse Hostname
pulse_hostname=$(hostname)

# Get used and available disk space for the AcceloHome directory
df_accelo_output=$(df -h "$AcceloHome")
used_space_accelo=$(echo "$df_accelo_output" | awk 'NR==2 {print $3}')
available_space_accelo=$(echo "$df_accelo_output" | awk 'NR==2 {print $4}')

# Total and free memory
memory_output=$(free -h | awk 'NR==2')
total_memory=$(echo "$memory_output" | awk '{print $2}')
free_memory=$(echo "$memory_output" | awk '{print $7}')

available_memory=$(echo "$memory_output" | awk '{print $7}')

# Get available disk space for the AcceloHome directory
df_accelo_output=$(df -h "$AcceloHome")
available_space_accelo_gb=$(echo "$df_accelo_output" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')

# Free Memory
free_memory_gb=$(free -g | awk 'NR==2 {print $4}')

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

# OS Version
os_version=$(lsb_release -a 2>/dev/null | grep Description | awk -F ':\t' '{print $2}')

# SELinux status
selinux_status=$(sestatus 2>/dev/null | awk '/SELinux status:/ {printf "%s ", $3}; /Current mode:/ {print $3}')

# Call the function to print Pulse Server information
print_pulse_info

# Call the function to print Services
print_section "Services running in this stack"
display_list "${services[@]}"

# Call the function to print Clusters
print_section "Clusters added to Pulse Server"
for cluster in $clusters; do
  printf "${GREEN}|  %s${NC}\n" "$cluster"
done

# Call the function to print Disk Space Utilization
print_section "Disk Space Utilized by Each Folder in $AcceloHome/data"
du_output=$(du -sh $AcceloHome/data/*)
while read -r line; do
  printf "${YELLOW}|  %s${NC}\n" "$line"
done <<< "$du_output"

backup_pulse_config() {

  read -p "Do you want to take a backup of Pulse related configs (yes/no)? " answer

  if [ "$answer" = "yes" ]; then

    backup_file="$AcceloHome/acceldata_backup_$(date +\%Y\%m\%d).tar.gz"

    # Execute the 'find' and 'tar' commands
    find "$AcceloHome" -type f \( -name "*.conf" -o -name "accelo.log" -o -name "*.yml" -o -name "*.yaml" -o -name "*.sh" -o -name "*.json" -o -name "*.actions" -o -name "*.xml" -o -name ".activecluster" -o -name ".dist" \) | tar --exclude="*/director/*" --exclude="*/data/*" -zcvf "$backup_file" -T - > backup_output.txt

    # Check if the backup was successful
    if [ $? -eq 0 ]; then
      echo "Backup completed successfully. Backup file: $backup_file"
      echo "Backup output has been saved to backup_output.txt"
    else
      echo "Backup failed."
    fi
  else
    echo "Backup operation canceled."
  fi
}

source /etc/profile.d/ad.sh

# Define variables
export mongo_url="mongodb://accel:ACCELUSER_01082018@localhost:27017/admin"
export output_file="/tmp/output.txt"

# Export db_name
export db_name=$(ls -1 "$AcceloHome/work" | grep -v "license" | head -n 1)

# Execute MongoDB commands and disk usage command
docker exec -it ad-db_default bash -c "mongo $mongo_url <<-EOSQL
use $db_name;
// Function to convert bytes to human-readable format
function bytesToHuman(bytes) {
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length) {
        size /= 1024;
        unit++;
    }
    return size.toFixed(2) + ' ' + units[unit];
}
// Output file path
var outputContent = '';
// Get collection sizes
var collections = db.getCollectionNames();
collections.forEach(function(collection) {
    var stats = db[collection].stats();
    var sizeInBytes = stats.size;
    var sizeHumanReadable = bytesToHuman(sizeInBytes);
    outputContent += 'Collection: ' + collection + ', Size: ' + sizeHumanReadable + '\n';
});
// Get database sizes
var databases = db.adminCommand('listDatabases').databases;
databases.forEach(function(database) {
    var sizeInBytes = database.sizeOnDisk;
    var sizeHumanReadable = bytesToHuman(sizeInBytes);
    outputContent += 'Database: ' + database.name + ', Size: ' + sizeHumanReadable + '\n';
});
// Print the content
print(outputContent);
EOSQL" > $output_file

  echo ""
  printf "${BLUE} Mongo Collection Size:${NC}\n"
  echo ""
cat $output_file | grep -v db.getCollectionNames |egrep "Collection|Database"

  echo ""
  printf "${BLUE} Docker Stats:${NC}\n"
  echo ""

docker stats --no-stream

  echo ""
  printf "${BLUE} accelo info:${NC}\n"
  echo ""

accelo info

  echo ""
  printf "${BLUE} Memory:${NC}\n"
  echo ""

  free -h

backup_pulse_config
