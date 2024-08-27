
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

6. **setup_pulse_tls**
   - Enable SSL for Pulse UI using ad-proxy.

7. **collect_docker_logs**
Finally, the script prints a completion message with the current time and hostname.
   - Create a tar file with all pulse container logs.

8. **backup_pulse_config**
    - Create a tar file with all pulse configuration files.

## 3. Pulse Agent health Check:

[pulseagent_health.sh](https://github.com/acceldata-io/ce-utils/blob/main/pulse/pulseagent_health.sh)

### Script Summary:

This bash script performs a validation check on various Pulse components and services. Below is a summary of each step:

1. **Check Installation of Pulse Agents**: Verifies the installation of directories related to Pulse components (`node`, `logs`, `jmx`, `log`, and `hydra`).

2. **Check Status of Pulse Services**: Checks the running status of Pulse services (`pulsenode`, `pulselogs`, `pulsejmx`, `hydra`). It also identifies if services are running as standalone processes.

3. **Validate Hydra Service**: Verifies if the Hydra service log file is up-to-date (modified within the last 5 minutes) and checks for any recent errors in the Hydra log.

4. **Validate PulseNode Configuration and Logs**: Confirms the presence of the PulseNode configuration file and logs, lists log files modified today, and checks for errors in the logs.

5. **Validate PulseLogs Directory and Files**: Checks the configuration directory and log files for PulseLogs, listing today's logs and configuration files, and validating their contents.

6. **Validate PulseJMX Directory and Files**: Ensures the presence of PulseJMX configuration files and logs, listing those modified today, and checks for any issues.
