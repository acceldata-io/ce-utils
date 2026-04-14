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
- [Requirements](#requirements)
- [Troubleshooting](#troubleshooting)
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

![Role Dependencies](docs/role-dependencies.svg)

## Blueprint Topologies

Three reference topologies are included. Copy the desired layout to `group_vars/all`:

```bash
cp playbooks/group_vars/all_3_node_ha playbooks/group_vars/all
```

### 1-Node All-in-One

![1-Node Topology](docs/topology-1node.svg)

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

**Tower/AWX users:** add a Vault Credential to the Job Template — no `.vault_password` file needed.

## Dynamic Blueprint Services

| Category | Services |
| -------- | -------- |
| **Core** | HDFS, YARN + MapReduce2, ZooKeeper |
| **Data** | Hive, HBase, Oozie, Kafka |
| **Security** | Ranger, Ranger KMS, Knox, Kerberos (AD) |
| **Search** | Infra Solr |
| **Streaming** | Spark, NiFi, NiFi Registry |
| **HA** | NameNode, ResourceManager, HBase, Ranger KMS |

Services are assigned to host groups in `blueprint_dynamic` (inside `group_vars/all`). The Jinja2 template automatically generates the correct Ambari Blueprint JSON.

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
  playbooks/
    install_cluster.yml        # Master playbook (all phases)
    prepare_nodes.yml          # Phase 1 playbook
    install_ambari.yml         # Phase 2 playbook
    configure_ambari.yml       # Phase 3 playbook
    apply_blueprint.yml        # Phase 4 playbook
    set_variables.yml          # Shared: dynamic groups + helper vars
    group_vars/
      all                      # Cluster configuration (edit this)
      all_3_node               # Reference: 3-node non-HA layout
      all_3_node_ha            # Reference: 3-node HA layout
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
| **Minimal shell usage** | `ansible.builtin.command` or native modules preferred; `shell` only where required (e.g., sysfs writes) |
| **Preflight validation** | Checks for placeholder values, JDBC driver existence, Python interpreter, blueprint consistency, and agent registration before proceeding |
| **Idempotent execution** | Safe to re-run — tasks skip already-completed work without side effects |
| **No `become` escalation leaks** | Privilege escalation scoped to play level; delegated tasks use `become: false` |
| **Ansible Tower / AWX ready** | Overridable variables, no local path dependencies, Vault Credential support |

## Requirements

| Requirement | Detail |
| ----------- | ------ |
| **Ansible** | 2.16+ (`ansible` package recommended, or `ansible-core` + collections) |
| **Collections** | `ansible.posix`, `community.general`, `community.postgresql`, `community.mysql` |
| **Target OS** | RHEL 8 / RHEL 9 (or compatible: Rocky Linux, AlmaLinux) |
| **Database** | External MariaDB, MySQL, or PostgreSQL — pre-created |
| **Network** | SSH access from workstation to all cluster nodes |
| **Java** | OpenJDK 17 (default) or OpenJDK 11 |

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

## License

Copyright Acceldata, Inc.
