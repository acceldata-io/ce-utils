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

## Tags

The master playbook `install_cluster.yml` exposes phase-level tags:

| Tag | Phases | Example |
| --- | ------ | ------- |
| `prepare_nodes` | 1 | `ansible-playbook playbooks/install_cluster.yml --tags prepare_nodes` |
| `ambari` | 2 + 3 | `ansible-playbook playbooks/install_cluster.yml --tags ambari` |
| `blueprint` | 3 + 4 | `ansible-playbook playbooks/install_cluster.yml --tags blueprint` |
| `always` | variables import | runs regardless of `--tags` |

Task-level tags are not defined inside roles — use the phase-level scripts (`prepare_nodes.sh`, `install_ambari.sh`, `configure_ambari.sh`, `apply_blueprint.sh`) or the master playbook tags above to select execution scope.

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

**Idempotency:** Safe to re-run. Package installs, `/etc/hosts` entries, SELinux mode, firewall disable, and THP sysfs writes are all state-checked before changes apply.

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| Package install fails | `repo_base_url` reachability; `/etc/yum.repos.d/` entries on the target node |
| `JAVA_HOME` validation fails | `ls -d /usr/lib/jvm/java-*` on the node — confirm `java_home` matches an installed JDK |
| `/etc/hosts` not updated | `external_dns: true` skips host file edits — set `false` if relying on the playbook to populate hosts |
| THP still enabled after run | Some kernels ignore `/sys/kernel/mm/transparent_hugepage/enabled` writes under certain profiles — verify with `cat /sys/kernel/mm/transparent_hugepage/enabled` |

---

## ambari_repo

**Phase 2** | Executed as a dependency of `ambari_agent` and `ambari_server` (not called directly).

Sets up the Ambari YUM repository on each node by installing a `.repo` file under `/etc/yum.repos.d/`.

**Key variables:** `ambari_repo_url`

**Idempotency:** Safe to re-run. The `.repo` file under `/etc/yum.repos.d/` is templated — re-runs overwrite only on URL change.

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| `Failed to fetch metalink / base URL` | `curl -I $ambari_repo_url/repodata/repomd.xml` from the target node — confirm the mirror is reachable and path resolves to RHEL 8 vs RHEL 9 correctly |
| Wrong Ambari version downloaded after a `repo_base_url` change | `dnf clean all && dnf makecache` on the node, then re-run |

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

**Idempotency:** Safe to re-run. Config file edits use `lineinfile` / template with state checks; the service is restarted only when config changes.

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| Agent installed but not starting | `/var/log/ambari-agent/ambari-agent.log` on the node; `systemctl status ambari-agent` |
| Agent cannot reach server (connection refused) | `hostname = <ambari-server>` in `/etc/ambari-agent/conf/ambari-agent.ini`; TCP 8440 / 8441 open from node to server |
| TLS handshake failure on old RHEL kernels | Confirm `[security] force_https_protocol = PROTOCOL_TLSv1_2` is present in the agent ini |

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

**Idempotency:** Re-runs are safe **after** the first successful schema load. The DDL load step is guarded, but loading against a database that already contains Ambari schema without a backup is risky — take a snapshot before the first run (see [INSTALL_static.md → External database](../../INSTALL_static.md#external-database)).

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| `JDBC driver not found at <path>` | Copy the correct JAR to `/usr/share/java/` on the Ambari server node |
| `ambari-server setup` fails | `/var/log/ambari-server/ambari-server-setup.log` |
| DDL load fails (PostgreSQL / MySQL / MariaDB) | Verify DB exists, user has grants, and `vault.yml` passwords match what the DB was provisioned with |
| DDL load fails (Oracle) | See [docs/ORACLE_PREREQ.md → Troubleshooting](../../docs/ORACLE_PREREQ.md#7-troubleshooting) |

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

**Idempotency:** Safe to re-run. REST calls use `PUT` against existing resources and are tolerant of repeated application. The admin password change is guarded — re-runs after the first successful change auth against `vault_ambari_admin_password`.

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| Admin password change returns `403` / `401` | `vault_ambari_admin_default_password` must match the Ambari first-login default (ships as `admin`) |
| VDF upload returns `500` | `systemctl status ambari-server`; retry after 30s — server may still be warming up |
| Agents never register | Phase 2 never completed on one or more hosts; check each node's `/var/log/ambari-agent/ambari-agent.log` |

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

**Idempotency:** Blueprint upload and cluster creation are **not** idempotent — once a cluster exists in Ambari, re-running Phase 4 will fail with `Cluster already exists`. To retry after a partial failure, delete the blueprint and cluster via the Ambari API:

```bash
curl -u admin:<password> -H 'X-Requested-By: ambari' -X DELETE \
  http://<ambari-server>:8080/api/v1/clusters/<cluster_name>
curl -u admin:<password> -H 'X-Requested-By: ambari' -X DELETE \
  http://<ambari-server>:8080/api/v1/blueprints/<blueprint_name>
```

**Dry-run before committing:** use `ansible-playbook playbooks/check_dynamic_blueprint.yml` to render and validate the blueprint JSON without uploading it.

**Failure modes and where to look:**

| Symptom | First place to check |
| ------- | -------------------- |
| Blueprint upload returns `400` | Inventory group names must match `host_group` values in `blueprint_dynamic`; run the validation playbook above |
| Cluster create returns `400` — service component mismatch | A component in `blueprint_dynamic` is not registered in Ambari (e.g. MPack not installed); `ambari-server list-mpacks` |
| Deployment times out | Raise `wait_timeout` in `group_vars/all`; check Ambari UI → Background Operations for stuck tasks |
| Service fails to start | Component-specific log under `/var/log/<service>/` on the host where it was placed; common causes: port conflicts, insufficient memory |
