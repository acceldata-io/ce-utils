## Bash Scripts for Automated Tasks

Below is a collection of Bash scripts designed to streamline various tasks in your ODP environment:

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
2. [Setup Ambari SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
3. [Setup KNOX SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)
4. [Setup Ambari LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
5. [Setup Ranger LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)

## Detailed Information

### 1. Setup SSL on ODP Environment via Bash Script
- **Script:** [setup_ssl_with_existing_jks.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
- **Description:** This Bash script automates the setup of SSL for a variety of services, including HDFS, YARN, MapReduce, Infra-Solr, Hive, Ranger, Kafka, HBase, Spark2, Spark3, and Oozie. The script should be executed on the Ambari Server node.

To utilize this script for enabling SSL in your ODP environment, please ensure the following steps:

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
- This script can be used to replace default KNOX self-signed certificate with the provided CA-signed certificate.
- Download and Execute this Script on the Knox Server node.

### 4. Setup Ambari LDAP
- **Script:** [setup_ambari_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
- Modify the script with the correct LDAP/AD details before running the script.
- Once the script is executed, please restart the Ambari Server and sync ldap user.

### 5. Setup Ranger LDAP
- **Script:** [setup_ranger_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)
- Modify the script with the correct LDAP/AD details before running the script.
  
<img width="712" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/e7bae7ba-a55e-4545-ba3f-04447e515c56">


These scripts are intended to simplify and automate crucial tasks within your ODP environment. Each script is linked for easy access and usage. Be sure to follow the provided instructions and customize the scripts with your environment-specific details as needed.
