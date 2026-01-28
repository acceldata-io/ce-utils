These steps will help to prepare the cluster for ODP cluster upgrade from 3.2.3.x-2/3 to 3.2.3.5-2/3

## Usage Intsructions
1. Clone this repository or download it (as a zip/tar) on the Ambari Server node.
```
git clone https://github.com/acceldata-io/ce-utils.git
```
2. Navigate to ```odp-upgrade-to-3_2_3_5``` directory.
```` 
cd odp-upgrade-to-3_2_3_5/upgrade_files_323
 ````
3. Execute the below command to update configurations to support JDK 11.
```
bash setup_jdk11_config.sh
```
4. Please restart the ambari-server
```
ambari-server restart
```
