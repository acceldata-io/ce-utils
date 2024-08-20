## Bash Scripts for Automated Tasks

Here is a set of Bash scripts created to streamline various tasks within your ODP environment. The purpose of these scripts is to streamline and automate essential tasks in your ODP environment. Each script is conveniently linked for quick access and utilization. Ensure that you adhere to the provided instructions and personalize the scripts with the specific details of your environment as required.

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
2. [Setup Ambari SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
3. [Setup KNOX SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)
4. [Setup Ambari LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
5. [Setup Ranger LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)
6. [Ambari Services Configuration backup and Restore](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/config_backup_restore.sh)
7. [Impala SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/README.md#7-impala-configuration-for-ssl)
8. [JAR Management Script](https://github.com/acceldata-io/ce-utils/tree/main/ODP#8-jar-management-script)

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

<img width="802" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/c9d220de-fb52-4cab-8635-05c5c3267d77">

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
<img width="1220" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/9777115f-aea8-4cc8-b569-1a53cf0cda06">

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

CONFIG_SCRIPT=/var/lib/ambari-server/resources/scripts/configs.py

python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_private_key -v $KEYSTORE_KEY
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_server_certificate -v $KEYSTORE_PEM
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k ssl_client_ca_certificate -v $TRUSTSTORE_PEM
python $CONFIG_SCRIPT -u $USER -p $PASSWORD -s $PROTOCOL -a set -t $PORT -l $AMBARISERVER -n $CLUSTER -c impala-env -k client_services_ssl_enabled -v true
```

### 8. JAR Management Script

This script provides functionalities to backup, replace, and restore JAR files in a specified directory. It is designed to handle JAR files used in applications, allowing you to safely back up, replace with a specific JAR, and restore files as needed.

## Features

- **Backup**: Backs up specified JAR files to a designated backup directory.
- **Replace**: Replaces original JAR files with a specified replacement JAR file.
- **Restore**: Restores JAR files from the backup directory to their original locations.
- **Dry Run**: Optionally simulate actions without executing them.

## Prerequisites

- Ensure you have read and write permissions to the specified directories.
- The replacement JAR file (`reload4j-1.2.19.jar`) should be located at `/root/`.

## Script Variables

- `DIR`: Directory containing the JAR files to be managed.
- `BACKUPDIR`: Directory where backup files will be stored.
- `JAR_FILES`: Array of JAR filenames to be backed up, replaced, and restored.
- `REPLACEMENT_JAR`: Path to the replacement JAR file.
- `DRY_RUN`: Flag to enable or disable dry-run mode (default is `true`).

## Usage

### 1. Backup JAR Files

Back up the specified JAR files to the backup directory.

```bash
./manage_jars.sh backup
```

### 2. Replace JAR Files

Replace the original JAR files with the `reload4j-1.2.19.jar`. Ensure the replacement JAR is located at `/root/`.

```bash
./manage_jars.sh replace
```

### 3. Restore JAR Files

Restore the JAR files from the backup directory to their original locations.

```bash
./manage_jars.sh restore
```

### 4. Dry Run Mode

By default, the script operates in dry-run mode, which simulates actions without executing them. To perform actual actions, disable dry-run mode by using the `-d` option:

```bash
./manage_jars.sh -d backup
```

```bash
./manage_jars.sh -d replace
```

```bash
./manage_jars.sh -d restore
```

## Example

```bash
# Backup JAR files and replace with reload4j
./manage_jars.sh backup

# Replace original JAR files with reload4j
./manage_jars.sh replace

# Restore JAR files from backup
./manage_jars.sh restore
```

## Notes

- Ensure you have sufficient permissions for all operations.
- The script will log actions to `/tmp/jar_backup_script.log`.
- The backup directory should be writable and have enough space to store backup files.
---
