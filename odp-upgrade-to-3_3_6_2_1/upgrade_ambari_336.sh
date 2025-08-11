#!/bin/sh

echo "################# Starting the upgrade essentials script #################"

echo "1.################# copying the necessary files for upgrade #################"
cp upgrade_files_336/nonrolling-upgrade-3.3.xml  /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/

cp upgrade_files_336/upgrade-3.3.xml   /var/lib/ambari-server/resources/stacks/ODP/3.2/upgrades/

cp -r upgrade_files_336/3.3  /var/lib/ambari-server/resources/stacks/ODP/

echo 2."################# Creating backup directory #################"
mkdir backup-files

###### Handling Spark2 deps for Zeppelin
echo "################# Moving Zeppelin's metainfo.xml and master.py to backup directory #################"
mv /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/metainfo.xml    backup-files/Zeppelin_metainfo.xml_bkp
mv /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/package/scripts/master.py  backup-files/Zeppling_master.py_bkp
mv /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/package/scripts/params.py backup-files/Zeppling_params.py_bkp

echo "3.################# Replacing Zeppelin's metainfo.xml,params.py and master.py to Zeppelin's directory #################"
cp upgrade_files_336/zeppelin_metainfo.xml   /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/metainfo.xml
cp upgrade_files_336/zeppelin_pack_scripts_master.py  /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/package/scripts/master.py
cp upgrade_files_336/zeppelin_package_scripts_params.py /var/lib/ambari-server/resources/stacks/ODP/3.0/services/ZEPPELIN/package/scripts/params.py

echo "4.################# Moving Tez's  sericce chek to backup directory #################"
mv /var/lib/ambari-server/resources/stacks/ODP/3.0/services/TEZ/package/scripts/service_check.py backup-files/Tez_service_check.py_bkp

echo "5.################# Replaing Tez's  sericce chek to Tez's directory #################"
cp  upgrade_files_336/Tez_service_check.py  /var/lib/ambari-server/resources/stacks/ODP/3.0/services/TEZ/package/scripts/service_check.py

echo "6.################# Handling Knox scripts for oozie removal #################"
sed -i 's/if type(oozie_server_hosts) is list:/if type(oozie_server_hosts) is list and len(oozie_server_hosts) > 0:/g' /var/lib/ambari-server/resources/stacks/ODP/3.0/services/KNOX/package/scripts/params_linux.py

echo "################# changes completed #################"
