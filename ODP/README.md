Describe what these scripts do and how to use them.

1. Setup SSL on ODP Environment via bash script.



### Setup SSL on ODP Environment via bash script.
- [setup_ssl_with_existing_jks.sh](https://github.com/acceldata-io/ce-utils/blob/main/ODP/scripts/setup_ssl_with_existing_jks.sh)
  - This Bash script can be used to Setup SSL for below services like HDFS Yarn MR, Infra-Solr, Hive, Ranger, Kafka, Hbase, Spark2 , Spark3 and oozie. 
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

- ambari_ldap.sh: Place the script here.
- ambari-ssl.sh: Place the script here.
- knox_ssl.sh: Place the script here.
- ranger_ldap.sh: Place the script here.
