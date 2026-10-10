## Bash Scripts for Automated Tasks

Here is a set of Bash scripts created to streamline various tasks within your ODP environment. The purpose of these scripts is to streamline and automate essential tasks in your ODP environment. Each script is conveniently linked for quick access and utilization. Ensure that you adhere to the provided instructions and personalize the scripts with the specific details of your environment as required.

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
2. [Setup Ambari SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
3. [Setup KNOX SSL](https://github.com/acceldata-io/ce-utils/tree/main/ODP#3-setup-knox-ssl)
4. [Setup Ambari LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
5. [Setup Ranger LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)
6. [Ambari Services Configuration backup and Restore](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/config_backup_restore.sh)
7. [Impala SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/README.md#7-impala-configuration-for-ssl)
8. [Disable SSL for Hadoop Services](https://github.com/acceldata-io/ce-utils/tree/main/ODP#8-disable-ssl-for-hadoop-services)
9. [Knox LDAP Configuration and Ambari Integration](https://github.com/acceldata-io/ce-utils/tree/main/ODP#9-knox-ldap-configuration-and-ambari-integration)
10. [Ambari MPACK Service Removal](https://github.com/acceldata-io/ce-utils/tree/main/ODP#10-ambari-mpack-service-removal)
11. [Ambari Config Manager (backup, restore, config groups)](https://github.com/acceldata-io/ce-utils/tree/main/ODP#11-ambari-config-manager)

## Detailed Information

### 1. Setup SSL on ODP Environment via Bash Script

- **Script:** [setup_ssl_with_existing_jks.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
  
- **Description:** This Bash script automates the setup of SSL for a variety of services, including **HDFS, YARN, MapReduce, Infra-Solr, Hive, Ranger, Kafka, HBase, Spark2, Spark3,** and **Oozie**. The script must be executed on the Ambari Server node.

To make use of this script for enabling SSL in your ODP environment, perform the following steps:

- Execute the script on the Ambari Server node.
- Modify the script to include the following details:
  - **USER:** Ambari Admin user
  - **PASSWORD:** Ambari Admin user Password
  - **PORT:** Ambari Server Port
  - **PROTOCOL:** Choose between 'http' or 'https' based on whether Ambari has SSL enabled or not.
  - **keystore:** Ensure the keystore file is available on all nodes.
  - **keystorepassword:** Provide the keystore password.
  - **truststore:** Ensure the truststore file is available on all nodes.
  - **truststorepassword:** Provide the truststore password.
  - For Infra-Solr, you will need a PKCS12 format keystore and truststore.
  - **keystore_p12:** Ensure the PKCS12 format keystore file is present on the Infra-Solr node.
  - **truststore_p12:** Verify that the PKCS12 format truststore file is present on the Infra-Solr node.

<img width="683" height="758" alt="image" src="https://github.com/user-attachments/assets/0ddfc18f-7879-4c6c-9b99-02426d3ce40d" />


### 2. Setup Ambari SSL
- **Script:** [setup_ssl_ambari.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
- Modify the script to include the following details:
- **IMPORT_CERT_PATH:** Ambari Server Certificate file
- **IMPORT_KEY_PATH:** Ambari Server Certificate private key
- **PEM_PASSWORD:** Ambari Server Certificate private key password
<img width="656" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/4e418710-c3cb-44f0-8ef4-18bae2472835">

### 3. Setup KNOX SSL
- **Script:** [knox_ssl.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)
- This script can be used to replace the default KNOX self-signed certificate with the provided CA-signed certificate.
- Download and execute this script on the Knox Server node.
- Verify that the Keystore password aligns with the master secret you created earlier. The script provides an option to reset it if needed.

### 4. Setup Ambari LDAP
- **Script:** [setup_ambari_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
- Modify the script with the correct LDAP/AD details before running the script.
- Once the script is executed, restart the Ambari Server and sync the ldap user.

### 5. Setup Ranger LDAP
- **Script:** [setup_ranger_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)
- Before running the script, make sure to adjust it with the accurate LDAP/AD details.
  
<img width="712" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/e7bae7ba-a55e-4545-ba3f-04447e515c56">

### 6. Ambari Services Configuration Backup and Restore
- **Script:** [Ambari Service Configuration backup and Restore](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/config_backup_restore.sh)

- This script allows you to backup and restore configurations for various services managed by Ambari, including Hue, Impala, Kafka, Ranger, Ranger KMS, Spark3, and NiFi. The script supports both SSL and non-SSL Ambari configurations and provides options for individual service or all-service backup and restore.

**Variables to Modify**
- **AMBARISERVER**: The fully qualified domain name of the Ambari server.
- **USER**: The username for Ambari authentication.
- **PASSWORD**: The password for Ambari authentication.
- **PORT**: The port number on which Ambari is running (8080 for HTTP, 8443 for HTTPS).
- **PROTOCOL**: The protocol used for Ambari server communication (http or https).

*How to Use It*

- Set Variables: Ensure that you have set the variables AMBARISERVER, USER, PASSWORD, PORT, and PROTOCOL correctly at the beginning of the script.

- Run the Script: Execute the script using the following command:

```bash
./config_backup_restore.sh
```
- ***Choose Action:*** The script will prompt you to choose whether you want to backup or restore configurations.*

- **Select Service:** Depending on your choice, you will be asked to select the service for which you want to perform the action. You can also choose the "All" option to perform the action on all supported services.
<img width="1500" alt="image" src="https://github.com/user-attachments/assets/a98a28a7-aef0-404f-8ca4-a9e04e66dd48" />


### 7. Impala Configuration for SSL

This script configures the Ambari server for SSL using the provided keystore and truststore files. Ensure to modify the values to match your environment.

```bash
#!/bin/bash

AMBARISERVER=`hostname -f`
USER=admin
PASSWORD=admin
PORT=8080
KEYSTORE_KEY=/opt/odp/security/pki/server.key
KEYSTORE_PEM=/opt/odp/security/pki/server.pem
TRUSTSTORE_PEM=/opt/odp/security/pki/ca-certs.pem
PROTOCOL=http
CLUSTER=ODP_CLUSTER_NAME

CONFIG_SCRIPT=/var/lib/ambari-server/resources/scripts/configs.py

python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_private_key -v $KEYSTORE_KEY
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_server_certificate -v $KEYSTORE_PEM
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k webserver_private_key_file -v $KEYSTORE_KEY
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k webserver_certificate_file -v $KEYSTORE_PEM
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_client_ca_certificate -v $TRUSTSTORE_PEM
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k client_services_ssl_enabled -v true
```

### 8. Disable SSL for Hadoop Services
- **Script:** [Disable SSL for Hadoop Services](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/disable_ssl.sh)
#### Overview
This script is designed to disable SSL configurations for various Hadoop-related services managed via Ambari API. It provides an interactive menu to selectively disable SSL for specific services or all at once.

#### Usage
Run the script with the following command-line options:

```bash
./disable_ssl.sh [-s <ambari_server>] [-u <user>] [-p <password>] [-P <port>] [-r <protocol>]
```

### Options:
- `-s <server>` : Ambari server hostname (default: detected automatically)
- `-u <user>` : Ambari API username (default: admin)
- `-p <password>` : Ambari API password (default: admin)
- `-P <port>` : Ambari API port (default: 8080)
- `-r <protocol>` : Protocol to use (default: http)
- `-h` : Display help information

#### Features
- **Interactive menu:** Choose specific services to disable SSL for.
- **Logging:** Outputs logs to `/tmp/disable_ssl.log`.
- **Automatic cluster detection:** Fetches the cluster name dynamically.
- **Graceful handling:** Includes interruption handling to exit safely.

#### Services Supported
This script can disable SSL for the following Hadoop ecosystem components:
- HDFS, YARN, MapReduce
- Infra-Solr
- Hive
- Ranger Admin
- Ranger KMS
- Kafka
- HBase
- Spark2
- Spark3
- Oozie

#### Example
Disable SSL for Hive and Ranger Admin:
```bash
./disable_ssl.sh -s my-ambari-server -u admin -p password -P 8080 -r http
```
Follow the interactive prompts to disable SSL for specific services.

## License
This script is provided by **Acceldata Inc** and is intended for internal use and administration of Hadoop clusters.

<img width="627" alt="image" src="https://github.com/user-attachments/assets/7cdcb118-04a7-45b3-b66b-aeb67d7ba4b1" />


### 9. Knox LDAP Configuration and Ambari Integration
- **Script:** [Knox LDAP Configuration and Ambari Integration](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox-service-discovery.sh)
#### Overview
This script automates the configuration of Knox with LDAP authentication and integrates it with Ambari for secure access control. It includes validation checks, Ambari cluster detection, and interactive prompts to ensure correct configurations.

#### Usage
Run the script with root privileges:

```bash
sudo ./knox-service-discovery.sh
```

#### Features
- **Knox Process Check:** Ensures Knox is running before proceeding.
- **Ambari Integration:** Fetches cluster details dynamically from Ambari.
- **LDAP Configuration:** Defines parameters for LDAP authentication and group mapping.
- **Interactive Validation:** Displays current settings before applying changes.
- **Automated Topology Management:** Updates Knox topology and provider configurations.
- **Logging & Error Handling:** Provides clear status updates and error messages.

#### Configuration Variables
The script sets up essential variables for Knox and Ambari integration:

| Parameter                 | Description |
|---------------------------|-------------|
| `AMBARI_SERVER`           | Ambari server hostname |
| `AMBARI_USER`             | Ambari API username |
| `AMBARI_PASSWORD`         | Ambari API password |
| `AMBARI_PORT`             | Ambari API port (default: 8080) |
| `AMBARI_PROTOCOL`         | HTTP/HTTPS protocol |
| `LDAP_HOST`               | LDAP server hostname |
| `LDAP_PROTOCOL`           | LDAP or LDAPS |
| `LDAP_PORT`               | LDAP server port |
| `LDAP_BIND_USER`          | LDAP bind DN |
| `LDAP_BASE_DN`            | LDAP base DN for user/group searches |
| `LDAP_USER_SEARCH_BASE`   | Base DN for user search |
| `LDAP_GROUP_SEARCH_BASE`  | Base DN for group search |

#### Steps Executed by the Script
1. **Pre-checks:** Ensures Knox and required commands (`curl`, `perl`) are available.
2. **Cluster Detection:** Retrieves the cluster name from Ambari.
3. **Knox Alias Creation:** Stores Ambari password securely for Knox integration.
4. **Knox Configuration Updates:**
   - Creates LDAP authentication provider configuration.
   - Updates topology files (`odp-sso-proxy-ui`, `odp-proxy`).
   - Generates descriptor files for Knox.
   - Ensures LDAP filters are correctly formatted.
5. **Final Validation:** Displays configured values and confirms readiness.

#### Example Execution Output
```bash
[INFO] Fetching Ambari cluster details...
[INFO] Cluster found: my-cluster
[INFO] Knox process is running
[INFO] Creating Knox alias for Ambari discovery password...
[INFO] Writing Knox custom provider configuration...
[INFO] Updating topology files...
[INFO] Knox configuration updated successfully!
```
<img width="800" alt="image" src="https://github.com/user-attachments/assets/9af15383-3005-4eb4-b006-282bfc22d9db" />

### 10. Ambari MPACK Service Removal
- **Script:** [ambari_delete_mpack_service.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/ambari_delete_mpack_service.sh)
- Based on `ambari_delete_or_add_service_atsv2.sh` and `config_backup_restore.sh`, this script lists the services installed in the cluster, flags the ones installed through an Ambari Management Pack (mpack), and lets you pick one or more services. For each selected service it runs **STOP → BACKUP configs → DELETE** via the Ambari REST API.
- Config backups use the same layout and JSON format as `config_backup_restore.sh` / `configs.py` (`upgrade_backup/<type>/<type>.json`), so they can be restored with either tool after the service is re-added. Config types are discovered dynamically from the service's current config version, so no hardcoded list is needed.
- Run it on the Ambari Server node: mpack detection reads `mpack.json` files under `/var/lib/ambari-server/resources/mpacks/` and the stack/common-services symlinks that point into that directory. If it is run elsewhere, every installed service is listed but none can be flagged as MPACK.

#### Usage
```bash
bash ambari_delete_mpack_service.sh                 # interactive: lists mpack services, select by number
bash ambari_delete_mpack_service.sh --list          # only print the table and exit
bash ambari_delete_mpack_service.sh --all           # list every installed service (mpack services are tagged)
bash ambari_delete_mpack_service.sh --yes SPARK3 LIVY3   # non-interactive, no prompts
bash ambari_delete_mpack_service.sh --skip-backup   # stop and delete without backing up configs
```

#### Variables (override via environment)
| Variable           | Default                             | Description |
|--------------------|-------------------------------------|-------------|
| `AMBARISERVER`     | `hostname -f`                       | Ambari Server FQDN |
| `AMBARI_USER`      | `admin`                             | Ambari admin user |
| `AMBARI_PASSWORD`  | `admin`                             | Ambari admin password |
| `PORT`             | `8080`                              | Ambari port (8443 for HTTPS) |
| `PROTOCOL`         | `http`                              | `http` or `https` |
| `AMBARI_RESOURCES` | `/var/lib/ambari-server/resources`  | Used for mpack detection |
| `BACKUP_DIR`       | `./upgrade_backup`                  | Where config backups are written (same default as `config_backup_restore.sh`) |
| `PYTHON_BIN`       | first of `python3`/`python`/`python2` | Used to write the backup JSON files |
| `STOP_TIMEOUT`     | `900`                               | Seconds to wait for the stop request |

#### What it does
1. Detects the cluster name and stack version from Ambari.
2. Lists installed services with their state and source (`MPACK (<mpack-name>)` or `stack`).
3. Asks you to select one or more services. Deleting a non-mpack service requires an extra confirmation.
4. **Stops** each selected service and polls the Ambari request until it completes.
5. **Backs up** every config type of the service (Default config group) to `BACKUP_DIR/<type>/<type>.json`, plus the raw `service_config_versions` response and the component-to-host layout under `BACKUP_DIR/_services/<SERVICE>_<timestamp>/`. If the backup is incomplete, the delete is skipped unless you explicitly confirm (never in `--yes` mode).
6. **Deletes** the service. Ambari API errors (for example a dependency from another service) are printed as-is.
7. Prints the `configs.py -a set` command to restore a config type and the matching `ambari-server uninstall-mpack` command for each removed mpack service.

#### Backup layout
```
upgrade_backup/
├── spark3-defaults/spark3-defaults.json        # {"properties": ..., "properties_attributes": ...}
├── spark3-env/spark3-env.json
├── livy3-conf/livy3-conf.json
└── _services/SPARK3_20250101_120000/
    ├── SPARK3_service_config_versions.json     # raw API response (all config groups)
    ├── SPARK3_host_components.json             # which component ran on which host
    └── <type>.raw.json                         # raw per-type API responses
```

> **Note:** Deleting a service removes its components and configuration history from Ambari. Packages on the hosts are not uninstalled, and the mpack stays registered on the Ambari Server until you run `ambari-server uninstall-mpack`.

> **Passwords:** Ambari returns password properties as `SECRET:<type>:<version>:<key>` references. Those references point at config versions that are deleted together with the service, so passwords cannot be recovered from the backup. The script lists every such property and asks you to confirm you have recorded them before it deletes the service.

### 11. Ambari Config Manager

- **Script:** [ambari-config-manager.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/ambari-config-manager.sh)
- Backs up and restores Ambari service configurations like `config_backup_restore.sh` (section 6), and adds **config groups** (host-specific overrides). Run it on the Ambari Server host; it supports RHEL/CentOS 7, 8 and 9 (bash 4.2 or later).

```bash
./ambari-config-manager.sh                                      # interactive menu
./ambari-config-manager.sh --restore-from <path> <service|all>  # restore from a specific backup directory
```

- **Settings** are environment variables: `AMBARISERVER`, `AMBARI_USER`, `AMBARI_PASSWORD`, `PORT`, `PROTOCOL`, `PYTHON_BIN` (auto-detected: `ambari-python-wrap`, then `python3`, `python`, `python2`). Example: `PROTOCOL=https PORT=8443 ./ambari-config-manager.sh`.
- **Backup menu:** MPACK services are listed first, then the default stack services. Services not installed on the cluster are dimmed and marked `(not installed)`; the tool supports every service listed. Each action ends with a summary and the backup directory.
- **Restore menu:** lists only the services that have a backup in the backup directory, each with what the backup holds and when it was taken (for example `Kafka  8 configs, 1 config group(s), 2026-10-10 20:14`). The script shows the backup directory and asks for confirmation before it overwrites anything in Ambari (`--restore-from` does not prompt).
- **Backup location:** backups go to `./upgrade_backup/<type>/<type>.json`; config groups go to `./upgrade_backup/_config_groups/<SERVICE>__<group>.json`.
- **Config group restore:** after the Default group, the script lists the groups in the backup and asks for confirmation. Existing groups are updated, deleted ones are created again, matching ones are left alone. Set `INCLUDE_CONFIG_GROUPS=no` to skip config groups.
- Restart the affected components from Ambari after a restore.

> **Note:** Passwords are saved as Ambari `SECRET:` references and restore on the same cluster only. Config types not listed in the script (for example `kafka-log4j` or Trino) are not backed up.
