#!/bin/sh

echo "################# Starting the upgrade essentials script #################"

echo "1.################# copying the necessary files for upgrade #################"
cp upgrade_files_323701/3.3/upgrades/nonrolling-upgrade-3.3.xml  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/

cp upgrade_files_323701/3.3/upgrades/upgrade-3.3.xml   /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/

cp -r upgrade_files_323701/3.3  /var/lib/ambari-server/resources/stacks/ODP/

echo 2."################# Creating backup directory #################"
mkdir backup-files

echo "3.################# Handling Knox scripts for oozie removal #################"
sed -i 's/if type(oozie_server_hosts) is list:/if type(oozie_server_hosts) is list and len(oozie_server_hosts) > 0:/g' /var/lib/ambari-server/resources/stacks/ODP/3.0/services/KNOX/package/scripts/params_linux.py

echo "4. removing ranger-Admin and kms server's solr audit bootstrap warnings."
sed -i '/<execute-stage service="RANGER" component="RANGER_ADMIN" title="Disabling Ranger Audit Solr Bootstrap Configuration">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.2.xml

sed -i '/<execute-stage service="RANGER_KMS" component="RANGER_KMS_SERVER" title="Updating dbks-site configurations for Ranger KMS Keysecure support">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.2.xml

sed -i '/<execute-stage service="RANGER" component="RANGER_ADMIN" title="Disabling Ranger Audit Solr Bootstrap Configuration">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.3.xml

sed -i '/<execute-stage service="RANGER_KMS" component="RANGER_KMS_SERVER" title="Updating dbks-site configurations for Ranger KMS Keysecure support">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/nonrolling-upgrade-3.3.xml

sed -i '/<execute-stage service="RANGER" component="RANGER_ADMIN" title="Disabling Ranger Audit Solr Bootstrap Configuration">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.3/upgrades/nonrolling-upgrade-3.3.xml

sed -i '/<execute-stage service="RANGER_KMS" component="RANGER_KMS_SERVER" title="Updating dbks-site configurations for Ranger KMS Keysecure support">/,/<\/execute-stage>/d' /var/lib/ambari-server/resources/stacks/ODP/3.3/upgrades/nonrolling-upgrade-3.3.xml

echo "################# changes completed #################"
