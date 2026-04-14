# Roles

Six Ansible roles that together deploy a complete Acceldata ODP cluster.

## Role Summary

| Role | Phase | Playbook | Applied to | Dependencies |
| ---- | ----- | -------- | ---------- | ------------ |
| `common` | 1 | `prepare_nodes.yml` | All nodes (`hadoop-cluster`) | none |
| `ambari_repo` | 2 | (dependency) | All nodes | none |
| `ambari_agent` | 2 | `install_ambari.yml` | All nodes | `ambari_repo` |
| `ambari_server` | 2 | `install_ambari.yml` | `ambari-server` group | `ambari_repo` |
| `ambari_config` | 3 | `configure_ambari.yml` | `ambari-server` group | none |
| `ambari_blueprint` | 4 | `apply_blueprint.yml` | `ambari-server` group | none |

## Execution Order

```text
Phase 1: prepare_nodes.yml
  └── common .......................... all nodes

Phase 2: install_ambari.yml
  ├── ambari_agent .................... all nodes
  │     └── (dependency) ambari_repo
  └── ambari_server ................... ambari-server only
        └── (dependency) ambari_repo

Phase 3: configure_ambari.yml
  └── ambari_config ................... ambari-server only

Phase 4: apply_blueprint.yml
  └── ambari_blueprint ................ ambari-server only
```

---

## common

**Phase 1** | Applied to all nodes (`hadoop-cluster` group) | Prepares OS prerequisites.

| Task | Conditional |
| ---- | ----------- |
| Install required OS packages | always |
| Validate Java (`JAVA_HOME` exists) | always |
| Install OpenJDK package | `java: 'openjdk'` |
| Check NTP service (chronyd) | always |
| Populate `/etc/hosts` with all cluster nodes | `external_dns: false` |
| Stop and disable firewall service | `disable_firewall: true` |
| Disable SELinux | `disable_selinux: true` |
| Disable Transparent Huge Pages (THP) | `disable_thp: true` |
| Set timezone | `set_timezone: true` |

**Key variables:** `java`, `openjdk_package`, `java_home`, `external_dns`, `disable_firewall`, `disable_selinux`, `disable_thp`

---

## ambari_repo

**Phase 2** | Executed as a dependency of `ambari_agent` and `ambari_server` (not called directly).

Sets up the Ambari YUM repository on each node by installing a `.repo` file under `/etc/yum.repos.d/`.

**Key variables:** `ambari_repo_url`

---

## ambari_agent

**Phase 2** | Applied to all nodes | Depends on `ambari_repo`.

Installs, configures, and starts the Ambari Agent on every cluster node.

| Task | Detail |
| ---- | ------ |
| Install `ambari-agent` package | from Ambari YUM repo |
| Set Ambari Server hostname | in `/etc/ambari-agent/conf/ambari-agent.ini` |
| Configure TLS 1.2 | force minimum protocol version |
| Update log directory | configurable via variables |
| Start and enable `ambari-agent` service | systemd |

---

## ambari_server

**Phase 2** | Applied to `ambari-server` inventory group | Depends on `ambari_repo`.

Installs the Ambari Server and sets up the backing database.

| Task | Detail |
| ---- | ------ |
| Install `ambari-server` package | from Ambari YUM repo |
| Validate JDBC driver exists | fails with clear error if missing |
| Load database schema | PostgreSQL (`psql`) or MySQL/MariaDB (`mysql`) |
| Configure JDBC driver path | `ambari-server setup --jdbc-db` |
| Run `ambari-server setup` | Java home, database type, credentials |
| Start and enable `ambari-server` service | systemd |

**Key variables:** `database`, `jdbc_driver_path`, `database_options`, `java_home`

---

## ambari_config

**Phase 3** | Applied to `ambari-server` inventory group.

Post-install Ambari configuration via the REST API (`http://localhost:8080/api/v1`).

| Task | Detail |
| ---- | ------ |
| Accept GPL license | `accept_gpl: true` |
| Change default admin password | from `vault_ambari_admin_default_password` to `vault_ambari_admin_password` |
| Upload ODP Version Definition File (VDF) | from `vdf-ODP-3.x-latest.xml.j2` template |
| Register ODP repository URLs | `odp_repo_url`, `odp_utils_repo_url` |
| Wait for all Ambari Agents to register | polls until all inventory hosts check in |

**Key variables:** `ambari_admin_user`, `ambari_admin_password`, `accept_gpl`, `odp_version`, `repo_base_url`

---

## ambari_blueprint

**Phase 4** | Applied to `ambari-server` inventory group.

Deploys the ODP cluster via the Ambari Blueprints API.

| Task | Detail |
| ---- | ------ |
| Generate blueprint JSON | from [blueprint_dynamic.j2](ambari_blueprint/templates/blueprint_dynamic.j2) (Jinja2) or load a static JSON file |
| Generate cluster creation template | from [cluster_template.j2](ambari_blueprint/templates/cluster_template.j2) |
| Upload blueprint to Ambari | `POST /api/v1/blueprints/{name}` |
| Create cluster | `POST /api/v1/clusters/{name}` |
| Poll deployment status | waits up to `wait_timeout` seconds |

**Key variables:** `blueprint_name`, `blueprint_file`, `blueprint_dynamic`, `cluster_name`, `wait`, `wait_timeout`

**Templates:**

| Template | Purpose |
| -------- | ------- |
| `blueprint_dynamic.j2` | Generates Ambari Blueprint JSON from `blueprint_dynamic` variable |
| `cluster_template.j2` | Cluster creation request body (maps hosts to host groups) |
| `vdf-ODP-3.x-latest.xml.j2` | ODP Version Definition File |
| `repo_version_template.json.j2` | Repository version registration payload |

At the end of this role, the ODP cluster is fully installed and accessible via the Ambari UI.
