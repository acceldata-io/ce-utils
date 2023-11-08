## Bash Scripts for Automated Tasks

Here is a set of Bash scripts created to streamline various tasks within your ODP environment. The purpose of these scripts is to streamline and automate essential tasks in your ODP environment. Each script is conveniently linked for quick access and utilization. Ensure that you adhere to the provided instructions and personalize the scripts with the specific details of your environment as required.

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
2. [Setup Ambari SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
3. [Setup KNOX SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)
4. [Setup Ambari LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
5. [Setup Ranger LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)

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
