
# Pulse Bash Script for Automated Tasks

This repository contains a Bash script designed to automate various tasks related to Pulse Server.

## 1. Pulse Server Information Capture
The `pulse_server_info` script is used to collect important information about the Pulse server before proceeding with an upgrade. It also provides an option to take a backup of Pulse configuration files as a precautionary step before initiating the Pulse Upgrade process.

- **script** [pulse_server_info](https://github.com/acceldata-io/ce-utils/blob/main/pulse/pulse_server_info.sh)
Example:
<details>
<summary>pulse_server_info</summary>
<br>
=============================================================
 Pulse Server Information
=============================================================

Hostname:		|  odp3.centos7.adsre.com
Avaialble Root Dir:	|  15.00 GB
AcceloHome Directory:	|  15.00 GB
Total Memory:		|  34.00 GB
Free Memory:		|  0.00 GB
CPU Cores:		|  6
Sockets:		|  3
Cores per Socket:	|  2
Pulse Version:		|  3.3.0
ImageTag Version:	|  3.3.0

=============================================================
 Services running in this stack
=============================================================

➟  ad-connectors
➟  ad-sparkstats
➟  ad-ldap
➟  ad-db
➟  ad-vmstorage
➟  ad-vminsert
➟  ad-vmselect
➟  ad-events
➟  ad-dashplot
➟  ad-pg
➟  ad-hydra
➟  ad-gauntlet
➟  ad-streaming
➟  ad-graphql
➟  ad-kafka-connector
➟  ad-fsanalyticsv2-connector
➟  ad-sql-analyser

=============================================================
 Clusters added to Pulse Server
=============================================================

⬨  odp_titan
⬨  odp_apollo

=============================================================
 Disk Space Utilized by Each Folder in /data01/acceldata/data
=============================================================

‣  20K	/data01/acceldata/data/alerts
‣  570M	/data01/acceldata/data/db
‣  4.5G	/data01/acceldata/data/elastic
‣  546M	/data01/acceldata/data/fsanalytics
‣  0	/data01/acceldata/data/hydra
‣  374M	/data01/acceldata/data/nats
‣  57M	/data01/acceldata/data/pg
‣  251M	/data01/acceldata/data/vmdb
Do you want to take a backup of Pulse related configs (yes/no)? yes
Creating a backup, please wait...
✔️ Backup completed successfully. Pulse config file: /data01/acceldata/acceldata_backup_20231103162501.tar.gz
</details>
