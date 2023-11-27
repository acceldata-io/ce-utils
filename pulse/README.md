
# Pulse Bash Script for Automated Tasks

This repository contains a Bash script designed to automate various tasks related to Pulse Server.

## 1. Pulse Server Information Capture
The `pulse_server_info` script is used to collect important information about the Pulse server before proceeding with an upgrade. It also provides an option to take a backup of Pulse configuration files as a precautionary step before initiating the Pulse Upgrade process.

- **Script:** --> [pulse_server_info](https://github.com/acceldata-io/ce-utils/blob/main/pulse/pulse_server_info.sh)

The script collects various useful information from the OS level. Here's a summary of what it collects:

1. **Pulse Server Information**:
   - Hostname
   - Available Root Directory Space
   - AcceloHome Directory Space
   - Total Memory
   - Free Memory
   - Available Memory
   - CPU Cores
   - Sockets
   - Cores per Socket
   - Pulse Version
   - ImageTag Version

2. **Services Running in This Stack**: It lists the services running on the Pulse server.

3. **Clusters Added to Pulse Server**: It lists the clusters added to the Pulse server.

4. **Disk Space Utilized by Each Folder in `$AcceloHome/data`**: It provides space utilization information for various folders in the `$AcceloHome/data` directory.

5. **Backup Pulse Related Configs**: It offers the option to create a backup of Pulse-related configuration files, and if the user chooses to backup, it generates a timestamped compressed backup file.

Overall, the script provides a comprehensive set of information about the Pulse Server and its environment. The option to create backups of Pulse-related configuration files is also a useful feature for system administrators.

<img width="662" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/09ef6a2e-59ab-4ed1-9f2e-7cb9695e7589">

## 2. Pulse Automated tasks Script

#### Functions (pulse_utility.sh)
1. **check_os_prerequisites**
   - Verify Umask, SELinux, and sysctl settings.

2. **check_docker_prerequisites**
   - Check and install Docker with required settings.

3. **install_pulse**
   - Install Acceldata Pulse following specific steps.

4. **full_install_pulse**
   - Include OS and Docker Pre-req setup along with Pulse initial setup.

5. **configure_ssl_for_pulse**
   - If SSL is enabled on the Hadoop Cluster, pass cacerts file to Pulse config.

6. **enable_gauntlet**
   - Delete elastic indices and run purge/compact operations on the Mongo DB collections.

7. **set_daily_cron_gauntlet**
   - Change CRON_TAB_DURATION for ad-gauntlet to the next 5 minutes or default value.

8. **setup_pulse_tls**
   - Enable SSL for Pulse UI using ad-proxy.

9. **collect_docker_logs**
   - Create a tar file with all pulse container logs.

10. **backup_pulse_config**
    - Create a tar file with all pulse configuration files.

