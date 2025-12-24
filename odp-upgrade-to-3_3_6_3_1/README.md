These steps will help to prepare the cluster for  ODP cluster upgrade to 3.3.6.3-1

## Usage Intsructions
1. Clone this repository or download it (as a zip/tar) on the Ambari Server node.
```
git clone https://github.com/acceldata-io/ce-utils.git
```
2. Navigate to ```odp-upgrade-to-3_3_6_3_1``` directory.
```` 
cd odp-upgrade-to-3_3_6_3_1
 ````
3. Execute the below command to add the pre-requisites to upgrade the cluster to ```3.3.6.3-1 ```
```
bash upgrade_ambari_336.sh
```
4. Please restart the ambari-server
```
ambari-server restart
```
