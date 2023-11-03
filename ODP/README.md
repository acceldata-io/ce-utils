Following are the bash scripts to automate tasks:

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/README.md#setup-ssl-on-odp-environment-via-bash-script)
2. Setup Ambari LDAP
3. Setup KNOX SSL  
4. Setup Ambari LDAP
5. Setup Ranger LDAP

---------

### Setup SSL on ODP Environment via bash script.
- [setup_ssl_with_existing_jks.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
  - This Bash script can be used to Setup SSL for below services like HDFS Yarn MR, Infra-Solr, Hive, Ranger, Kafka, Hbase, Spark2 , Spark3, and oozie. 
  - Execute this script from Ambari Server node.

You can utilize the following script to activate SSL in an ODP environment where you have already generated and distributed the keystore and truststore JKS files to all nodes.
Ensure that you execute this script on the Ambari Server node.
Ensure that you update the following details in the script files:

* **USER**: Ambari Admin user
* **PASSWORD:** Ambari Admin user Password
* **PORT:** Ambari Server Port
* **PROTOCOL:** Use either 'http' or 'https' based on whether Ambari has SSL enabled or not.
* **keystore:** Ensure the keystore file is available on all nodes.
* **keystorepassword:** Provide the keystore password.
* **truststore:** Ensure the truststore file is available on all nodes.
* **truststorepassword:** Provide the truststore password.
* *For Infra-Solr, you'll need a PKCS12 format keystore and truststore.*
* **keystore_p12:** Make sure the PKCS12 format keystore file is present on the Infra-Solr node.
* **truststore_p12** → make sure PKCS12 format truststore file is present on infra-solr node
<img width="802" alt="image" src="https://github.com/acceldata-io/ce-utils/assets/28974904/c9d220de-fb52-4cab-8635-05c5c3267d77">

### Setup Ambari SSL

- [setup_ssl_ambari.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)

### Setup KNOX SSL  

- [knox_ssl.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)

### Setup Ambari LDAP

- [setup_ambari_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)

### Setup Ranger LDAP

- [setup_ranger_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)





Here is a reformatted and clarified version of the content:

## Bash Scripts for Automated Tasks

Below is a collection of Bash scripts designed to streamline various tasks in your ODP environment:

1. [Setup SSL on ODP Environment](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
2. [Setup Ambari LDAP](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)
3. [Setup KNOX SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)
4. [Setup Ambari SSL](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)
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

### 2. Setup Ambari LDAP
- **Script:** [setup_ambari_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ambari_ldap.sh)

### 3. Setup KNOX SSL
- **Script:** [knox_ssl.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/knox_ssl.sh)

### 4. Setup Ambari SSL
- **Script:** [setup_ssl_ambari.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_ambari.sh)

### 5. Setup Ranger LDAP
- **Script:** [setup_ranger_ldap.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ranger_ldap.sh)

These scripts are intended to simplify and automate crucial tasks within your ODP environment. Each script is linked for easy access and usage. Be sure to follow the provided instructions and customize the scripts with your environment-specific details as needed.
