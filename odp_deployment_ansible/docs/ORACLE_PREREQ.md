# Oracle 19c Prerequisites

This document covers the Oracle-specific prerequisites for deploying ODP with an external Oracle 19c database.

There are two approaches for loading the Ambari schema:

- **Automated**: Set `oracle_load_ambari_schema: true` (default) in `group_vars/all`. The playbook loads the DDL via `sqlplus` using the `oracle_home` path.
- **Manual**: Set `oracle_load_ambari_schema: false` and follow the steps below to install `sqlplus` (via Instant Client) and load the DDL yourself.

---

## 1. Install Oracle Instant Client (sqlplus)

Run these steps on the **Ambari server node**. For air-gapped environments, download the ZIPs on a connected machine and copy them over.

```bash
export ORACLE_HOME=/opt/oracle/product/19c/dbhome_1

# create directory
mkdir -p $ORACLE_HOME/instantclient
cd /tmp

# download Instant Client (basic-lite + sqlplus)
wget https://download.oracle.com/otn_software/linux/instantclient/1930000/instantclient-basiclite-linux.x64-19.30.0.0.0dbru.zip
wget https://download.oracle.com/otn_software/linux/instantclient/1930000/instantclient-sqlplus-linux.x64-19.30.0.0.0dbru.zip

# unzip
unzip instantclient-basiclite-linux.x64-19.30.0.0.0dbru.zip -d $ORACLE_HOME/instantclient/
unzip instantclient-sqlplus-linux.x64-19.30.0.0.0dbru.zip -d $ORACLE_HOME/instantclient/

# symlink for convenience
cd $ORACLE_HOME/instantclient
ln -sfn instantclient_19_30 instantclient

# set environment (session only — add to ~/.bashrc for persistence)
export LD_LIBRARY_PATH=$ORACLE_HOME/instantclient/instantclient:$LD_LIBRARY_PATH
export PATH=$ORACLE_HOME/instantclient/instantclient:$PATH

# fix libocci symlink
cd $ORACLE_HOME/instantclient/instantclient
ln -sf libocci_gcc53.so.19.1 libocci_gcc53.so

# install missing dependency
yum install -y libnsl || dnf install -y libnsl

# verify sqlplus is working
sqlplus -v
```

## 2. Test Oracle Connectivity

```bash
# connect to Oracle (replace <hostname> with your DB server)
sqlplus ambari/bigdata@//<hostname>:1521/ACCELDATA
```

```sql
-- verify connection
SELECT user FROM dual;

-- exit
EXIT
```

## 3. Load the Ambari DDL

The Ambari DDL file is installed by the `ambari-server` RPM at `/var/lib/ambari-server/resources/Ambari-DDL-Oracle-CREATE.sql`.

> **Note:** Install the `ambari-server` package first (Phase 2 of the playbook installs it), then load the schema before running `ambari-server setup`.

```bash
sqlplus ambari/bigdata@//<hostname>:1521/ACCELDATA @/var/lib/ambari-server/resources/Ambari-DDL-Oracle-CREATE.sql
```

## 4. JDBC Driver

The Oracle JDBC driver (`ojdbc8.jar`) must be present on the Ambari server node before running the playbook.

```bash
# copy from the Oracle DB server or Instant Client
sudo mkdir -p /usr/share/java
sudo cp /path/to/ojdbc8.jar /usr/share/java/ojdbc8.jar
```

Set in `group_vars/all`:

```yaml
jdbc_driver_path: '/usr/share/java/ojdbc8.jar'
```

## 5. Oracle Database Users and Grants

Create the following users/schemas on the Oracle database before running the playbooks. See [INSTALL_static.md](../INSTALL_static.md#external-database) for the full SQL reference.

| Service | Oracle User | Tablespace | group_vars username variable |
| --------- | ------------- | ------------ | ------------------------------ |
| Ambari | `ambari` | `USERS` | `ambari_db_username` |
| Hive | `hive` | `USERS` | `hive_db_username` |
| Oozie | `oozie` | `USERS` | `oozie_db_username` |
| Ranger Admin | `rangerdba` | `rangerdba` (dedicated) | `rangeradmin_db_username` |
| Ranger KMS | `rangerkms` | `rangerkms` (dedicated) | `rangerkms_db_username` |

> Ensure the usernames in `database_options` in `group_vars/all` match the Oracle users created above.

## 6. group_vars/all Configuration

```yaml
database: 'oracle'
jdbc_driver_path: '/usr/share/java/ojdbc8.jar'

database_options:
  external_hostname: '10.100.8.4'            # Oracle DB server hostname or IP
  ambari_db_name: 'ambari'
  ambari_db_username: 'ambari'
  ambari_db_password: "{{ vault_ambari_db_password }}"
  hive_db_name: 'hive'
  hive_db_username: 'hive'
  hive_db_password: "{{ vault_hive_db_password }}"
  oozie_db_name: 'oozie'
  oozie_db_username: 'oozie'
  oozie_db_password: "{{ vault_oozie_db_password }}"
  rangeradmin_db_name: 'rangerdba'
  rangeradmin_db_username: 'rangerdba'
  rangeradmin_db_password: "{{ vault_rangeradmin_db_password }}"
  rangerkms_db_name: 'rangerkms'
  rangerkms_db_username: 'rangerkms'
  rangerkms_db_password: "{{ vault_rangerkms_db_password }}"

oracle_sid: 'ACCELDATA'
oracle_load_ambari_schema: false             # loading manually using the steps above
```
