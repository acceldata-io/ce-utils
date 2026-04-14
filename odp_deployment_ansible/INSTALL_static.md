# Installation Guide — Static Inventory

Deploy an Acceldata ODP cluster on pre-built infrastructure using a static Ansible inventory.

![Installation Steps](docs/install-steps.svg)

> **Prerequisites:** All cluster nodes must be reachable via SSH and have RHEL 8 or RHEL 9 (or compatible) installed.


## 1. Workstation Setup

> **Ansible Tower / AWX users:** Tower installs collections automatically from `requirements.yml` at project sync. Skip to [Set the Inventory](#2-set-the-inventory).

The workstation (or one of the cluster nodes) must have Ansible installed and SSH access to all nodes.

### Install Ansible

**Recommended — full `ansible` package** (includes all required collections):

```bash
sudo dnf -y install epel-release
sudo dnf -y install ansible
```

**Alternative — `ansible-core` only** (minimal, requires manual collection install):

```bash
sudo dnf -y install ansible-core
```

### Install Collections (only if using `ansible-core`)

> Skip this if you installed the full `ansible` package.

**Verify collections:**

```bash
ansible-galaxy collection list | grep -E "ansible.posix|community.general|community.postgresql|community.mysql"
```

**Online install:**

```bash
ansible-galaxy collection install -r requirements.yml
```

**Air-gapped install:**

```bash
# On a machine with internet — download tarballs:
ansible-galaxy collection download -r requirements.yml -p ./collections-tarballs

# On the air-gapped workstation — install from tarballs:
ansible-galaxy collection install ./collections-tarballs/*.tar.gz -p ./collections
```


## 2. Set the Inventory

Edit `inventory/static` to define your cluster nodes:

```ini
[odp-master01]
master01 ansible_host=10.0.1.10 ansible_user=root ansible_ssh_private_key_file="~/.ssh/id_rsa"

[odp-master02]
master02 ansible_host=10.0.1.11 ansible_user=root ansible_ssh_private_key_file="~/.ssh/id_rsa"

[odp-master03]
master03 ansible_host=10.0.1.12 ansible_user=root ansible_ssh_private_key_file="~/.ssh/id_rsa"
```

Each inventory group name must match the `host_group` names in your blueprint configuration (`blueprint_dynamic` in `group_vars/all`).

![Inventory Mapping](docs/inventory-mapping.svg)

### Inventory variables

| Variable | Description |
|----------|-------------|
| `ansible_host` | DNS name or IP of the node |
| `ansible_user` | SSH user with sudo privileges |
| `ansible_ssh_private_key_file` | Path to SSH private key |
| `ansible_ssh_pass` | SSH password (alternative to key) |
| `rack` | (Optional) Rack info. Default: `/default-rack` |

### Verify connectivity

```bash
ansible -i inventory/static all --list-hosts
ansible -i inventory/static all -m ping
```


## 3. Configure Vault Secrets

All passwords are stored in `vault.yml` at the project root, encrypted with Ansible Vault.

![Vault Secrets](docs/vault-secrets.svg)

### Vault password file

The vault password is read from `.vault_password` (configured in `ansible.cfg`).
This file is git-ignored and must be created on each workstation.

```bash
# Set your vault password (replace 'changeme' with a strong password)
echo 'YOUR_VAULT_PASSWORD' > .vault_password
chmod 600 .vault_password
```

### First-time setup — edit and encrypt

```bash
# Edit the plaintext vault file with your passwords
vi vault.yml

# Encrypt it (uses .vault_password automatically)
ansible-vault encrypt vault.yml
```

### Edit encrypted vault

```bash
ansible-vault edit vault.yml
```

### Change the vault password

```bash
# 1. Update .vault_password with the new password
echo 'NEW_PASSWORD' > .vault_password
chmod 600 .vault_password

# 2. Re-encrypt vault.yml with the new password
ansible-vault rekey vault.yml
```

**Vault variables:**

| Variable | Purpose |
|----------|---------|
| `vault_ambari_admin_password` | Ambari admin UI password |
| `vault_ambari_admin_default_password` | Ambari default password (for change flow) |
| `vault_default_password` | Base password for Ranger, Knox, NiFi, Kerberos |
| `vault_ambari_db_password` | Ambari database password |
| `vault_hive_db_password` | Hive metastore database password |
| `vault_oozie_db_password` | Oozie database password |
| `vault_rangeradmin_db_password` | Ranger Admin database password |
| `vault_rangerkms_db_password` | Ranger KMS database password |


## 4. Configure Cluster Variables

Edit `playbooks/group_vars/all` to set the cluster configuration.

### Cluster identity

| Variable | Description | Example |
|----------|-------------|---------|
| `cluster_name` | Cluster name | `'odp'` |
| `ambari_version` | Ambari version (4-part) | `'3.0.0.0-101'` |
| `odp_version` | ODP version (4-part) | `'3.3.6.3'` |
| `odp_build_number` | ODP build number | `'101'` |
| `odp_version_full` | Full version with build (auto-derived) | `"{{ odp_version }}-{{ odp_build_number }}"` |
| `repo_base_url` | Base mirror URL (all repo URLs are auto-constructed from this) | `'https://mirror.odp.acceldata.dev'` |

### Repository URLs (auto-constructed, override for local mirrors)

| Variable | Description |
|----------|-------------|
| `ambari_repo_url` | Ambari RPM repository URL |
| `odp_repo_url` | ODP stack repository URL |
| `odp_utils_repo_url` | ODP utilities repository URL |

### General options

| Variable | Description | Default |
|----------|-------------|---------|
| `external_dns` | Use existing DNS (`true`) or populate `/etc/hosts` (`false`) | `true` |
| `disable_firewall` | Disable local firewall service | `true` |
| `disable_selinux` | Disable SELinux on all nodes | `true` |
| `disable_thp` | Disable Transparent Huge Pages | `true` |
| `set_timezone` | Set timezone on all nodes | `false` |
| `timezone` | Timezone name (only when `set_timezone: true`) | `'UTC'` |

### Java

By default, the playbook installs OpenJDK on all nodes (`java: 'openjdk'`). Set `openjdk_package` and `java_home` to match your required JDK version.

| Variable | Description | Default |
|----------|-------------|---------|
| `java` | `'openjdk'` (install), `'custom'` (pre-installed), or `'embedded'` (Ambari managed) | `'openjdk'` |
| `openjdk_package` | JDK package to install (when `java: 'openjdk'`) | `'java-17-openjdk-devel'` |
| `java_home` | Path to JAVA_HOME (must match the installed JDK) | `'/usr/lib/jvm/java-17-openjdk'` |

**Available JDK packages (RHEL 8/9):**

| JDK Version | `openjdk_package`       | `java_home`                    |
|-------------|-------------------------|--------------------------------|
| JDK 17      | `java-17-openjdk-devel` | `/usr/lib/jvm/java-17-openjdk` |
| JDK 11      | `java-11-openjdk-devel` | `/usr/lib/jvm/java-11-openjdk` |

> If JDK is already installed on all nodes, set `java: 'custom'` and update `java_home` to point to the existing JAVA_HOME path. The playbook will validate the path exists on every node.

### External database

![Database Prerequisites](docs/database-prereqs.svg)

> All databases, users, and privileges must be pre-created before running the playbooks.

| Variable | Description |
|----------|-------------|
| `database` | `'postgres'`, `'mysql'`, or `'mariadb'` |
| `jdbc_driver_path` | Path to JDBC driver JAR on Ambari server node (must already exist) |
| `database_options.external_hostname` | Database server hostname or IP |

**JDBC driver must be present on the Ambari server node before running Phase 2.** The playbook will fail with a clear error if the driver is missing.

**MySQL / MariaDB** (MySQL Connector/J 8.0.x works with both MySQL 8 and MariaDB 10.11):

```bash
# Download the driver (run on the Ambari server node)
sudo mkdir -p /usr/share/java
sudo curl -Lo /usr/share/java/mysql-connector-java.jar \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.0.33/mysql-connector-j-8.0.33.jar
```

```yaml
# group_vars/all
database: 'mariadb'                   # or 'mysql'
jdbc_driver_path: '/usr/share/java/mysql-connector-java.jar'
```

**PostgreSQL**:

```bash
# Download the driver (run on the Ambari server node)
sudo mkdir -p /usr/share/java
sudo curl -Lo /usr/share/java/postgresql-jdbc.jar \
  https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.3/postgresql-42.7.3.jar
```

```yaml
# group_vars/all
database: 'postgres'
jdbc_driver_path: '/usr/share/java/postgresql-jdbc.jar'
```

> For air-gapped environments, download the JAR on a connected machine and copy it to `/usr/share/java/` on the Ambari server node.

The following databases must be pre-created with corresponding users and privileges:

| Service | DB name variable | Username variable | Password (in vault) |
|---------|-----------------|-------------------|---------------------|
| Ambari | `ambari_db_name` | `ambari_db_username` | `vault_ambari_db_password` |
| Hive | `hive_db_name` | `hive_db_username` | `vault_hive_db_password` |
| Oozie | `oozie_db_name` | `oozie_db_username` | `vault_oozie_db_password` |
| Ranger Admin | `rangeradmin_db_name` | `rangeradmin_db_username` | `vault_rangeradmin_db_password` |
| Ranger KMS | `rangerkms_db_name` | `rangerkms_db_username` | `vault_rangerkms_db_password` |

> Database passwords are stored in `vault.yml`, not in `group_vars`.

### Kerberos (optional)

| Variable | Description |
|----------|-------------|
| `security` | `'none'` or `'active-directory'` |
| `security_options.external_hostname` | KDC / Active Directory hostname |
| `security_options.realm` | Kerberos realm (e.g., `'EXAMPLE.COM'`) |
| `security_options.admin_principal` | Kerberos admin principal |
| `security_options.ldap_url` | LDAPS URL (AD only) |
| `security_options.container_dn` | DN for service principal container (AD only) |
| `security_options.http_authentication` | Enable SPNEGO for UIs (`true`/`false`) |
| `security_options.manage_krb5_conf` | Let Ambari manage krb5.conf (`false` for FreeIPA/IdM) |

### Ranger

| Variable | Description |
|----------|-------------|
| `ranger_options.enable_plugins` | Enable Ranger plugins for all services (`true`/`false`) |
| `ranger_security_options.ranger_admin_password` | Ranger admin password (defaults to `{{ default_password }}`) |
| `ranger_security_options.ranger_keyadmin_password` | Ranger key admin password (defaults to `{{ default_password }}`) |
| `ranger_security_options.kms_master_key_password` | KMS master key encryption password (defaults to `{{ default_password }}`) |

### Knox

| Variable | Description |
|----------|-------------|
| `knox_security_options.master_secret` | Knox gateway master secret (defaults to `{{ default_password }}`) |

### NiFi

| Variable | Description |
|----------|-------------|
| `nifi_security_options.encrypt_password` | NiFi configuration encryption password (defaults to `{{ default_password }}`) |
| `nifi_security_options.sensitive_props_key` | NiFi sensitive properties key (defaults to `{{ default_password }}`) |

> All security passwords above default to `{{ default_password }}` which resolves to `vault_default_password` from the vault. Change the vault value to update all at once, or override individual passwords in `group_vars/all`.

### Ambari

| Variable | Description | Default |
|----------|-------------|---------|
| `ambari_admin_user` | Ambari admin username | `'admin'` |
| `config_recommendation_strategy` | Blueprint config strategy | `'ALWAYS_APPLY_DONT_OVERRIDE_CUSTOM_VALUES'` |
| `wait` | Wait for cluster build to complete | `true` |
| `wait_timeout` | Max wait time in seconds | `3600` |
| `accept_gpl` | Accept GPL licensed packages | `false` |
| `cluster_template_file` | Cluster creation template | `'cluster_template.j2'` |

### Blueprint

| Variable | Description |
|----------|-------------|
| `blueprint_name` | Name stored in Ambari |
| `blueprint_file` | `'blueprint_dynamic.j2'` (generated) or path to static JSON |
| `blueprint_dynamic` | Service-to-host-group mapping (see `group_vars/all` for examples) |

### Paths (optional)

Override data and log directories. See `playbooks/roles/ambari_blueprint/defaults/main.yml` for all available path variables.

| Variable | Description | Default |
|----------|-------------|---------|
| `base_log_dir` | Base log directory | `'/var/log'` |
| `base_tmp_dir` | Base temp directory | `'/tmp'` |
| `postgres_port` | PostgreSQL port | `5432` |
| `mysql_port` | MySQL/MariaDB port | `3306` |


## 5. Deploy the Cluster

> The vault password file (`.vault_password`) must exist before running any playbook. See [Configure Vault Secrets](#3-configure-vault-secrets).
>
> `--ask-vault-pass` is not needed — `ansible.cfg` reads the password from `.vault_password` automatically.

### Option A — Run all phases at once

```bash
bash install_cluster.sh
```

This runs Phase 1 through Phase 4 sequentially.

### Option B — Run phases individually

Useful for debugging, resuming after a failure, or when you only need a specific phase.

**Phase 1 — Prepare nodes** (OS packages, Java, NTP, firewall, SELinux, THP):

```bash
bash prepare_nodes.sh
```

**Phase 2 — Install Ambari** (Ambari agent on all nodes, Ambari server on the designated node):

```bash
bash install_ambari.sh
```

**Phase 3 — Configure Ambari** (admin password, GPL license, VDF upload, repository URLs, agent sync):

```bash
bash configure_ambari.sh
```

**Phase 4 — Apply blueprint** (upload blueprint, create cluster, wait for deployment):

```bash
bash apply_blueprint.sh
```

### Using ansible-playbook directly

```bash
# All phases
ansible-playbook playbooks/install_cluster.yml

# Individual phases
ansible-playbook playbooks/prepare_nodes.yml
ansible-playbook playbooks/install_ambari.yml
ansible-playbook playbooks/configure_ambari.yml
ansible-playbook playbooks/apply_blueprint.yml
```


## 6. Multiple Clusters (Optional)

To manage multiple clusters from the same project:

### Create per-cluster inventory

```bash
cp inventory/static inventory/my_cluster
vi inventory/my_cluster
```

### Create per-cluster variables

```bash
cp playbooks/group_vars/all playbooks/group_vars/my_cluster
vi playbooks/group_vars/my_cluster
```

### Deploy with custom inventory

```bash
bash install_cluster.sh -i inventory/my_cluster
```


## Pre-Deployment Checklist

Verify all items before running `install_cluster.sh`:

### Infrastructure

- [ ] All cluster nodes running RHEL 8 or RHEL 9 (or compatible: Rocky Linux, AlmaLinux)
- [ ] SSH access from workstation to all nodes (key-based or password)
- [ ] Sufficient disk, memory, and CPU on all nodes for the planned services
- [ ] Network connectivity between all cluster nodes (no firewall blocking inter-node traffic)

### Workstation

- [ ] Ansible 2.16+ installed (`ansible --version`)
- [ ] Required collections available (`ansible-galaxy collection list`)
- [ ] Vault password file created (`.vault_password`) with correct permissions (`chmod 600`)
- [ ] Vault encrypted (`head -1 vault.yml` should show `$ANSIBLE_VAULT;1.1;AES256`)

### Inventory

- [ ] `inventory/static` updated with all node hostnames/IPs
- [ ] Inventory group names match `host_group` names in `blueprint_dynamic` (in `group_vars/all`)
- [ ] SSH connectivity verified (`ansible all -m ping`)

### Database

- [ ] External database server (MySQL, MariaDB, or PostgreSQL) running and reachable
- [ ] All required databases created: `ambari`, `hive`, `oozie`, `ranger`, `rangerkms`
- [ ] Database users created with appropriate privileges
- [ ] JDBC driver JAR present on the Ambari server node (`ls -l /usr/share/java/mysql-connector-java.jar`)
- [ ] `database_options.external_hostname` set to actual hostname (not the placeholder `EXTERNAL-DB-HOSTNAME`)

### Java Runtime

- [ ] If `java: 'openjdk'` (default): nodes have internet or local repo access to install the JDK package
- [ ] If `java: 'custom'`: JDK already installed on all nodes and `java_home` path is correct

### Variables

- [ ] `cluster_name` set in `group_vars/all`
- [ ] `ambari_version` and `odp_version` match your target release
- [ ] `repo_base_url` reachable from all nodes (`curl -s <repo_base_url>`)
- [ ] `database` type and `jdbc_driver_path` match the installed driver
- [ ] Vault passwords updated from defaults (`ansible-vault edit vault.yml`)
