# ODP Deployment Ansible

Ansible playbooks for deploying **Acceldata ODP** (Open Data Platform) clusters using Ambari Blueprints.

![Architecture](docs/architecture.svg)

---

## Table of Contents

- [Highlights](#highlights)
- [Quick Start](#quick-start)
- [Deployment Phases](#deployment-phases)
- [Blueprint Topologies](#blueprint-topologies)
- [Secrets Management](#secrets-management)
- [Dynamic Blueprint Services](#dynamic-blueprint-services)
- [Project Structure](#project-structure)
- [Roles](#roles)
- [Security & Compliance](#security--compliance)
- [Network & Ports](#network--ports)
- [Requirements](#requirements)
- [Performance Tuning](#performance-tuning)
- [Troubleshooting](#troubleshooting)
- [Glossary](#glossary)
- [License](#license)

---

## Highlights

| Feature | Detail |
| ------- | ------ |
| **ODP 3.x** | Acceldata Open Data Platform on Ambari 3.x |
| **OS support** | RHEL 8 / RHEL 9 (Rocky Linux, AlmaLinux) |
| **Automation** | Ansible CLI + Ansible Tower / AWX |
| **Secrets** | Ansible Vault with cascading master password |
| **Blueprints** | Dynamic (Jinja2) or static JSON |
| **High Availability** | NameNode, ResourceManager, HBase, Ranger KMS |
| **Air-gapped** | Pre-downloaded collection tarballs, local mirrors |

## Quick Start

```bash
# 1. Configure your inventory
vi inventory/static

# 2. Edit cluster variables
vi playbooks/group_vars/all

# 3. Set vault password and encrypt secrets
echo 'YOUR_VAULT_PASSWORD' > .vault_password && chmod 600 .vault_password
ansible-vault encrypt vault.yml

# 4. Deploy the cluster
bash install_cluster.sh
```

After deployment completes, the Ambari UI is available at `http://<ambari-server>:8080`.

See [INSTALL_static.md](INSTALL_static.md) for detailed step-by-step instructions.

## Deployment Phases

![Deployment Phases](docs/deployment-phases.svg)

| Phase | Script | Roles | Target | What it does |
| ----- | ------ | ----- | ------ | ------------ |
| **1** | `prepare_nodes.sh` | `common` | All nodes | OS packages, Java, NTP, firewall, SELinux, THP |
| **2** | `install_ambari.sh` | `ambari_repo`, `ambari_agent`, `ambari_server` | All nodes + server | YUM repo, Ambari agent & server, DB schema |
| **3** | `configure_ambari.sh` | `ambari_config` | Ambari server | VDF, repo URLs, admin password, agent sync |
| **4** | `apply_blueprint.sh` | `ambari_blueprint` | Ambari server | Blueprint generation, API upload, cluster creation |

All phases share `set_variables.yml` which initializes dynamic groups and computes helper variables.

```bash
# Run all phases at once
bash install_cluster.sh

# Or run individually
bash prepare_nodes.sh
bash install_ambari.sh
bash configure_ambari.sh
bash apply_blueprint.sh
```

**Validate before deploying.** Dry-run the blueprint without creating a cluster:

```bash
ansible-playbook playbooks/check_dynamic_blueprint.yml
```

This verifies that inventory group names match `blueprint_dynamic`, component placement is valid, and the blueprint JSON renders — catching misconfiguration before a long Phase 4 run.

## Blueprint Topologies

Three reference topologies are included. Copy the desired layout to `group_vars/all`:

```bash
cp playbooks/group_vars/all_3_node_ha playbooks/group_vars/all
```

### Inventory ↔ group_vars mapping

Pick the inventory file that matches your hardware, then copy the matching reference
template to `group_vars/all` (the file Ansible actually loads).

| Inventory file | Reference group_vars to copy | Topology |
| -------------- | ---------------------------- | -------- |
| [inventory/static_1_node](inventory/static_1_node) | `group_vars/all` (default) | 1-node PoC |
| [inventory/static_3_node](inventory/static_3_node) | `group_vars/all_3_node` | 3 nodes, no HA |
| [inventory/static_4_node](inventory/static_4_node) | `group_vars/all_3_node_ha` | 3-node HA + 1 worker |
| [inventory/static_6_node](inventory/static_6_node) | `group_vars/all_multi_node_ha` | 3 masters + 3 workers |
| [inventory/static_multi_node](inventory/static_multi_node) | `group_vars/all_multi_node_ha` | 3 masters + N workers |

### 1-Node All-in-One

| File | Layout | Use case |
| ---- | ------ | -------- |
| `group_vars/all` | 1-node | Development, testing, PoC — every service on a single node |

### 3-Node HA

![3-Node HA Topology](docs/topology-3node-ha.svg)

| File | Layout | Use case |
| ---- | ------ | -------- |
| `group_vars/all_3_node` | 3-node | Small cluster, master/master/worker split, no HA |
| `group_vars/all_3_node_ha` | 3-node HA | Small production — NameNode HA, ResourceManager HA, HBase HA |

### Multi-Node HA (Production)

![Multi-Node HA Topology](docs/topology-multi-node-ha.svg)

| File | Layout | Use case |
| ---- | ------ | -------- |
| custom | 3+ masters, N workers | Production — scale workers by adding hosts to `[odp-workers]` inventory group |

## Secrets Management

![Vault Secrets Architecture](docs/vault-secrets.svg)

All passwords are stored in `vault.yml` at the project root, encrypted with Ansible Vault. One master password (`vault_default_password`) cascades to 7 service passwords automatically.

![Variable Flow](docs/variable-flow.svg)

```bash
# Edit secrets
ansible-vault edit vault.yml

# Encrypt (first time)
ansible-vault encrypt vault.yml
```

### Ansible Tower / AWX

In Tower or AWX, add this repository as a Project and attach a **Vault Credential** to the Job Template — Tower reads the vault password from the credential, so no `.vault_password` file is required on disk. `requirements.yml` is resolved automatically at project sync.

## Dynamic Blueprint Services

| Category | Services |
| -------- | -------- |
| **Core** | HDFS, YARN + MapReduce2, ZooKeeper, Tez |
| **Data** | Hive, HBase, Oozie, Kafka, Sqoop |
| **Security** | Ranger, Ranger KMS, Knox, Kerberos (AD), Infra Solr (Ranger audit) |
| **HA** | NameNode, ResourceManager, HBase, Ranger KMS |

Services are assigned to host groups in `blueprint_dynamic` (inside `group_vars/all`). The Jinja2 template automatically generates the correct Ambari Blueprint JSON.

### Services Available via MPack

The following services are **not included by default** and must be added via [Ambari Management Packs](https://docs.acceldata.io/odp/documentation/odp-working-with-ambari-management-packs) before they can be deployed.

See the [MPacks repository listing](https://docs.acceldata.io/odp/documentation/ambari-repositories1#mpacks-link) for download links and version compatibility.

#### MPack Service Components

| Category | Server / Master Components | Client Components |
| -------- | -------------------------- | ----------------- |
| **Streaming** | `KAFKA3_BROKER`, `FLINK_JOBHISTORYSERVER`, `NIFI_MASTER`, `NIFI_REGISTRY_MASTER`, `REGISTRY_SERVER` | `FLINK_CLIENT` |
| **Compute** | `SPARK3_JOBHISTORYSERVER`, `SPARK3_THRIFTSERVER`, `LIVY3_SERVER`, `SPARK2_JOBHISTORYSERVER`, `IMPALA_DAEMON`, `IMPALA_STATE_STORE`, `IMPALA_CATALOG_SERVICE`, `TRINO_COORDINATOR`, `TRINO_WORKER` | `SPARK3_CLIENT`, `SPARK2_CLIENT` |
| **Storage** | `OZONE_MANAGER`, `OZONE_DATANODE`, `OZONE_STORAGE_CONTAINER_MANAGER`, `OZONE_S3_GATEWAY`, `OZONE_RECON`, `KUDU_MASTER`, `KUDU_TSERVER`, `HTTPFS_GATEWAY` | `OZONE_CLIENT` |
| **Analytics** | `PINOT_CONTROLLER`, `PINOT_SERVER`, `PINOT_BROKER`, `PINOT_MINION`, `CLICKHOUSE_SERVER`, `CLICKHOUSE_WEBSERVER`, `CLICKHOUSE_KEEPER` | `CLICKHOUSE_CLIENT` |
| **ML / Notebooks** | `MLFLOW_SERVER`, `JUPYTERHUB`, `ZEPPELIN_MASTER` | — |
| **Workflow** | `AIRFLOW_SCHEDULER`, `AIRFLOW_WEBSERVER`, `AIRFLOW_WORKER` | — |
| **UI** | `HUE_SERVER` | — |

#### MPack Extension Pattern

MPack services in the table above are recognized in `blueprint_dynamic` (host placement) but do not ship with generated `configurations` blocks — you provide those when you integrate an MPack. The pattern below is what to apply for each new MPack service; it mirrors how core services are wired in this project.

Three files are touched:

**1. `playbooks/group_vars/all`** — add component names to `blueprint_dynamic`:

```yaml
blueprint_dynamic:
  - host_group: "odp-master01"
    clients: ['...existing...', 'SPARK3_CLIENT']   # add client
    services:
      - ...existing...
      - SPARK3_JOBHISTORYSERVER                     # add server component
```

**2. `playbooks/set_variables.yml`** — register a host-list helper variable if the new service needs HA wiring, Ranger audit targeting, or cross-service references.

`set_variables.yml` computes these helpers from the combined `blueprint_dynamic`:

| Helper Variable | Populated When Service Present |
| --------------- | ------------------------------ |
| `namenode_groups` | `NAMENODE` |
| `resourcemanager_groups` | `RESOURCEMANAGER` |
| `zookeeper_groups` / `zookeeper_hosts` | `ZOOKEEPER_SERVER` |
| `hiveserver_hosts` | `HIVE_SERVER`, `HIVE_METASTORE`, `SPARK2_JOBHISTORYSERVER` |
| `oozie_hosts` | `OOZIE_SERVER` |
| `kafka_groups` / `kafka_hosts` | `KAFKA_BROKER` |
| `rangeradmin_groups` / `rangeradmin_hosts` | `RANGER_ADMIN`, `RANGER_USERSYNC` |
| `rangerkms_hosts` | `RANGER_KMS_SERVER` |
| `journalnode_groups` | `JOURNALNODE` |
| `zkfc_groups` | `ZKFC` |

Add entries using the same `set_fact` pattern. A new MPack service typically needs one helper per service that participates in HA, service discovery, or cross-component URLs (for example `SPARK3_JOBHISTORYSERVER` → `spark3_hosts`, `NIFI_MASTER` → `nifi_hosts`, `OZONE_MANAGER` → `ozone_hosts`).

**3. `playbooks/roles/ambari_blueprint/templates/blueprint_dynamic.j2`** — add a `configurations` block guarded by service presence.

The template uses `{% if 'SERVICE' in blueprint_all_services %}` guards. Core services already wired in the template:

| Config Blocks | Services |
| ------------- | -------- |
| Kerberos | `kerberos-env`, `krb5-conf` |
| Ranger | `admin-properties`, `ranger-admin-site`, `ranger-env`, audit plugins (HDFS, Hive, YARN, HBase, Knox, Kafka) |
| Ranger KMS | `kms-properties`, `dbks-site`, `kms-env`, `kms-site`, `ranger-kms-audit` |
| HDFS | `hadoop-env`, `hdfs-site`, `core-site` (includes HA wiring) |
| YARN | `yarn-env`, `yarn-site`, `yarn-hbase-env`, `yarn-hbase-site` (includes RM HA) |
| Hive | `hive-site`, `hiveserver2-site`, `hive-env` |
| HBase | `hbase-site`, `hbase-env` |
| Oozie | `oozie-site`, `oozie-env` |
| Tez | `tez-site`, `tez-env` |
| MapReduce | `mapred-site`, `mapred-env` |
| Sqoop | `sqoop-env` |
| Kafka | `kafka-env`, `kafka-broker` |
| ZooKeeper | `zookeeper-env`, `zoo.cfg` |
| Knox | `knox-env` |
| Infra Solr | `infra-solr-env`, `infra-solr-client-log4j` |
| Spark / Spark2 | `spark-env`, `spark2-env`, `livy-env`, `livy2-env` |
| Zeppelin | `zeppelin-env` |
| Solr (user) | `solr-config-env` |

When extending, follow the same guard style, for example:

```jinja
{% if 'SPARK3_JOBHISTORYSERVER' in blueprint_all_services %}
{
  "spark3-env": { ... },
  "livy3-env": { ... }
},
{% endif %}
```

Reference the relevant MPack's `configuration/*.xml` files (installed under `/var/lib/ambari-server/resources/mpacks/<mpack>/` after `ambari-server install-mpack`) for the exact property names expected by that stack.

## Project Structure

```text
odp_deployment_ansible/
  ansible.cfg                  # Ansible configuration
  vault.yml                    # Encrypted secrets (ansible-vault)
  requirements.yml             # Required Ansible collections
  install_cluster.sh           # Master orchestration (runs all phases)
  prepare_nodes.sh             # Phase 1: OS preparation
  install_ambari.sh            # Phase 2: Ambari install
  configure_ambari.sh          # Phase 3: Post-install config
  apply_blueprint.sh           # Phase 4: Blueprint deployment
  inventory/
    static                     # Default inventory (edit this)
    static_1_node              # Reference: 1-node all-in-one
    static_2_node              # Reference: 2-node cluster
    static_3_node              # Reference: 3-node cluster
    static_4_node              # Reference: 4-node cluster
    static_6_node              # Reference: 6-node cluster
    static_multi_node          # Reference: multi-node HA
  playbooks/
    install_cluster.yml        # Master playbook (all phases)
    prepare_nodes.yml          # Phase 1 playbook
    install_ambari.yml         # Phase 2 playbook
    configure_ambari.yml       # Phase 3 playbook
    apply_blueprint.yml        # Phase 4 playbook
    check_dynamic_blueprint.yml # Blueprint validation utility
    set_variables.yml          # Shared: dynamic groups + helper vars
    group_vars/
      all                      # Cluster configuration (edit this)
      all_3_node               # Reference: 3-node non-HA layout
      all_3_node_ha            # Reference: 3-node HA layout
      all_multi_node_ha        # Reference: multi-node HA layout
    roles/
      common/                  # OS prerequisites (Java, NTP, firewall)
      ambari_repo/             # YUM repository setup
      ambari_agent/            # Ambari agent install + config
      ambari_server/           # Ambari server install + DB setup
      ambari_config/           # Post-install configuration
      ambari_blueprint/        # Blueprint generation + cluster creation
  docs/                        # Architecture diagrams (SVG)
  collections-tarballs/        # Pre-downloaded collections (air-gapped)
```

## Roles

See [playbooks/roles/README.md](playbooks/roles/README.md) for detailed role documentation.

| Role | Phase | Applied to | Key tasks |
| ---- | ----- | ---------- | --------- |
| `common` | 1 | All nodes | OS packages, Java validation, NTP, `/etc/hosts`, firewall, SELinux, THP |
| `ambari_repo` | 2 | All nodes | Ambari YUM repository setup (dependency of agent & server) |
| `ambari_agent` | 2 | All nodes | Install agent, set server hostname, TLS 1.2, log directory |
| `ambari_server` | 2 | Ambari server | Install server, DB schema, JDBC driver, `ambari-server setup` |
| `ambari_config` | 3 | Ambari server | GPL license, admin password, VDF upload, repo URLs, agent sync |
| `ambari_blueprint` | 4 | Ambari server | Generate blueprint, upload via API, create cluster, poll status |

## Security & Compliance

These playbooks are designed for enterprise environments and follow security best practices:

| Practice | Detail |
| -------- | ------ |
| **Secrets management** | All passwords encrypted with Ansible Vault (`vault.yml`). No plaintext credentials in playbooks or group_vars |
| **Vault password file** | `.vault_password` has `0600` permissions and is git-ignored by default |
| **No hardcoded secrets** | Passwords use `vault_` prefixed variables; override via Tower/AWX Credential or extra vars |
| **ansible-lint compliant** | Passes `ansible-lint` (basic+ profile) — enforced across all roles and playbooks |
| **Fully Qualified Collection Names** | All modules use FQCN (e.g., `ansible.builtin.uri`, `community.postgresql.postgresql_db`) |
| **Explicit file permissions** | `mode` set on all file, copy, and template tasks |
| **No `ignore_errors`** | Proper `failed_when` conditions instead of blanket error suppression |
| **TLS 1.2 enforcement** | Ambari agent connections enforce TLS 1.2 minimum protocol version |
| **Minimal shell usage** | `ansible.builtin.command` or native modules preferred; `shell` only where required (e.g., sysfs writes) |
| **Preflight validation** | Checks for placeholder values, JDBC driver existence, Python interpreter, blueprint consistency, and agent registration before proceeding |
| **Idempotent execution** | Safe to re-run — tasks skip already-completed work without side effects |
| **No `become` escalation leaks** | Privilege escalation scoped to play level; delegated tasks use `become: false` |
| **Ansible Tower / AWX ready** | Overridable variables, no local path dependencies, Vault Credential support |

## Network & Ports

Phase 1 disables the local host firewall (`disable_firewall: true`). Any corporate or network firewall between cluster nodes, the Ambari server, clients, and the external database must allow the ports below. Ports are Ambari / ODP defaults — override in Ambari after deployment if your site uses non-defaults.

| Component | Port | Direction | Purpose |
| --------- | ---- | --------- | ------- |
| Ambari Server | `8080` | Inbound from operators | Ambari Web UI / REST API (HTTP) |
| Ambari Server | `8440` | Inbound from agents | Agent registration (HTTPS, two-way) |
| Ambari Server | `8441` | Inbound from agents | Agent heartbeat / commands (HTTPS) |
| NameNode | `8020` | Inbound from clients | HDFS RPC (`fs.defaultFS`) |
| NameNode | `9870` | Inbound from operators | NameNode Web UI |
| JournalNode | `8485` | Inbound from NameNodes | HDFS HA edit log |
| DataNode | `9864`, `9866`, `9867` | Inbound from cluster | DataNode HTTP / data transfer / IPC |
| ResourceManager | `8088` | Inbound from operators | YARN Web UI |
| ResourceManager | `8032`, `8030`, `8031` | Inbound from clients / NMs | YARN scheduler / RM / resource tracker |
| NodeManager | `8042`, `45454` | Inbound from RM | NodeManager UI / shuffle |
| HistoryServer (MR) | `19888`, `10020` | Inbound from clients | MR job history UI / IPC |
| Hive Server2 | `10000` (binary), `10001` (HTTP) | Inbound from clients | JDBC / ODBC |
| Hive Metastore | `9083` | Inbound from Hive / Spark | Metastore Thrift |
| HBase Master | `16000`, `16010` | Inbound from operators / RS | Master RPC / Web UI |
| HBase RegionServer | `16020`, `16030` | Inbound from clients | RegionServer RPC / Web UI |
| ZooKeeper | `2181` | Inbound from clients | Client connections |
| ZooKeeper | `2888`, `3888` | Inter-ZK | Quorum / leader election |
| Kafka Broker | `9092` (PLAINTEXT), `9093` (SASL_SSL) | Inbound from producers / consumers | Kafka protocol |
| Ranger Admin | `6080` (HTTP), `6182` (HTTPS) | Inbound from operators / plugins | Ranger UI / API |
| Ranger KMS | `9292` | Inbound from HDFS / clients | KMS API |
| Knox Gateway | `8443` | Inbound from external clients | Gateway HTTPS |
| Oozie | `11000` | Inbound from clients | Oozie Web UI / REST |
| Infra Solr | `8886` | Inbound from Ranger / Atlas | Ranger audit destination |
| Zeppelin | `9995` | Inbound from operators | Zeppelin UI |
| External DB (PostgreSQL) | `5432` | Outbound from Ambari / services | Configurable via `postgres_port` |
| External DB (MySQL / MariaDB) | `3306` | Outbound from Ambari / services | Configurable via `mysql_port` |
| External DB (Oracle) | `1521` | Outbound from Ambari / services | Configurable via `oracle_port` |
| KDC / Active Directory | `88` (TCP/UDP), `636` (LDAPS) | Outbound from cluster | Kerberos auth / LDAP lookup (when `security: active-directory`) |

Add reverse entries (outbound from operator workstations → Ambari Server 8080 / Knox 8443) to any user-facing firewall.

## Requirements

| Requirement | Detail |
| ----------- | ------ |
| **Ansible** | 2.16+ (`ansible` package recommended, or `ansible-core` + collections) |
| **Collections** | `ansible.posix`, `community.general`, `community.postgresql`, `community.mysql` |
| **Target OS** | RHEL 8 / RHEL 9 (or compatible: Rocky Linux, AlmaLinux) |
| **Database** | External MariaDB, MySQL, PostgreSQL, or Oracle 19c — pre-created |
| **Network** | SSH access from workstation to all cluster nodes |
| **Java** | OpenJDK 17 (default) or OpenJDK 11 |

For detailed OS, JDK, and database compatibility see the [ODP Support Matrix](https://docs.acceldata.io/odp/support-matrix).

### Dual-JDK behavior

Ambari 3.x requires JDK 17 — controlled by `ambari_openjdk_package` / `ambari_java_home` in `group_vars/all`. The ODP stack JDK (used by HDFS, YARN, Hive, Spark, etc.) is independent and set via `openjdk_package` / `java_home`. When the two differ (e.g. Ambari on JDK 17, ODP on JDK 11), both JDKs are installed on every node; Ambari uses its own, services use theirs. Do not change `ambari_openjdk_package` unless a future Ambari release certifies a different JDK.

## Performance Tuning

`ansible.cfg` ships with production-ready defaults. Adjust these if you hit scale or latency limits:

| Setting | Default | When to change |
| ------- | ------- | -------------- |
| `forks` | `40` | Raise for clusters >100 nodes; lower on resource-constrained workstations |
| `timeout` (defaults + ssh) | `60` | Raise on high-latency links or when SSH handshakes time out |
| `gathering` | `smart` | Keep smart — only gathers facts once per host. Set to `explicit` only for debugging |
| `pipelining` | `True` | Keep on — reduces SSH round trips per task. Requires `requiretty` disabled in sudoers (default on RHEL 8/9) |
| `ssh_args` `ControlMaster` / `ControlPersist=300s` | enabled | Keep on — reuses SSH connections across tasks for ~3–5× faster runs |
| `retries` (ssh) | `3` | Raise on flaky networks; lower to fail fast in CI |
| `host_key_checking` | `False` | Set to `True` in environments that require strict SSH host key verification |
| `wait_timeout` (in `group_vars/all`) | `3600` | Raise for very large clusters where Phase 4 cluster build exceeds one hour |

Playbooks use the `linear` strategy — required because `set_variables.yml` uses `add_host`, which is incompatible with the `free` strategy.

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `UNREACHABLE!` on ping | SSH connectivity issue | Verify `ansible_host`, `ansible_user`, and SSH key in `inventory/static` |
| `Vault password not found` | Missing `.vault_password` | Create the file: `echo 'PASSWORD' > .vault_password && chmod 600 .vault_password` |
| `JDBC driver not found` | Driver JAR not on Ambari server | Download the driver to `/usr/share/java/` on the Ambari server node (see [INSTALL_static.md](INSTALL_static.md#4-configure-cluster-variables)) |
| Phase 3 fails at VDF upload | Ambari server not running | Check `ambari-server status` and `systemctl start ambari-server` |
| Phase 4 hangs or times out | Slow cluster provisioning | Increase `wait_timeout` in `group_vars/all` (default: 3600 seconds) |
| Blueprint validation error | Inventory group names don't match `blueprint_dynamic` | Ensure each `[group]` in `inventory/static` has a matching entry in `blueprint_dynamic` |
| `PLACEHOLDER` error | Unconfigured variables | Search for `PLACEHOLDER` in `group_vars/all` and replace with actual values |
| Agent registration timeout | Agents can't reach server | Check DNS/hosts resolution and firewall between nodes |
| Database schema load fails | Wrong DB credentials or DB not created | Verify databases exist and passwords in `vault.yml` match |

**Re-running after failure:** All playbooks are idempotent. Fix the issue and re-run the same phase — it will skip completed tasks automatically.

## Glossary

| Term | Meaning |
| ---- | ------- |
| **Ambari** | Apache Ambari — management and monitoring platform for Hadoop/ODP clusters |
| **Agent** | `ambari-agent` daemon running on every node; executes commands from the Ambari Server |
| **Server** | `ambari-server` daemon on the designated node; owns cluster state and the REST API |
| **Blueprint** | JSON document describing services, host groups, and configurations — submitted to Ambari to provision a cluster |
| **Dynamic Blueprint** | Blueprint rendered from a Jinja2 template (`blueprint_dynamic.j2`) at playbook runtime based on `blueprint_dynamic` in `group_vars/all` |
| **Static Blueprint** | A hand-authored JSON blueprint referenced by `blueprint_file` |
| **Host Group** | Named group of hosts in a blueprint that share the same service assignments |
| **VDF** | Version Definition File — XML document that registers a specific ODP version and its repositories with Ambari |
| **MPack** | Management Pack — Ambari extension that adds service definitions (Spark3, NiFi, Ozone, Trino, etc.) not bundled with the core stack |
| **HA** | High Availability — active/standby or quorum-based redundancy for critical components (NameNode, ResourceManager, HBase Master, Ranger KMS) |
| **NameNode** | HDFS metadata service; supports active/standby HA via JournalNodes and ZKFC |
| **JournalNode** | Quorum participant storing the HDFS edit log for NameNode HA |
| **ZKFC** | ZooKeeper Failover Controller — monitors NameNodes and triggers HA failover |
| **ResourceManager** | YARN scheduler; supports active/standby HA |
| **Ranger** | Centralized authorization, auditing, and data masking for Hadoop services |
| **KMS** | Key Management Server — Ranger KMS provides transparent HDFS encryption keys |
| **Knox** | Perimeter gateway that proxies and secures REST/HTTP traffic to cluster services |
| **SPNEGO** | Kerberos-over-HTTP authentication used by Ambari and service Web UIs (`security_options.http_authentication: true`) |
| **Infra Solr** | Embedded Solr instance used by Ranger to store audit records |
| **VDF / `repo_version_template`** | Ambari API payloads registering the ODP stack build and RPM repositories |

## License

Copyright Acceldata, Inc.
