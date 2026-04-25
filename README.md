# ODP Deployment Ansible

Ansible playbooks for automated deployment of **Acceldata ODP** (Open Data Platform) clusters using Ambari Blueprints. Supports single-node to multi-node HA topologies with role-based configuration, Ansible Vault secrets management, and dynamic blueprint generation.

## Features

| Capability | Detail |
| ---------- | ------ |
| **OS support** | RHEL 8 / RHEL 9 (Rocky Linux, AlmaLinux) |
| **HA topologies** | 1-node, 3-node, 3-node HA, multi-node HA |
| **Air-gapped** | Offline collections tarballs + local mirror support |
| **Secrets** | Ansible Vault with cascading master password |
| **Automation** | Ansible CLI and Ansible Tower / AWX ready |
| **Databases** | MariaDB, MySQL, PostgreSQL, Oracle 19c (external, pre-created) |

## Clone

```bash
git clone -b odp-ansible-deploy https://github.com/acceldata-io/ce-utils.git
```

## Documentation

| Guide | Purpose |
| ----- | ------- |
| [odp_deployment_ansible/README.md](odp_deployment_ansible/README.md) | Main documentation — architecture, topologies, blueprint reference, glossary |
| [odp_deployment_ansible/INSTALL_static.md](odp_deployment_ansible/INSTALL_static.md) | Step-by-step install guide for static inventories |
| [odp_deployment_ansible/docs/ORACLE_PREREQ.md](odp_deployment_ansible/docs/ORACLE_PREREQ.md) | Oracle 19c prerequisites and troubleshooting |
| [odp_deployment_ansible/playbooks/roles/README.md](odp_deployment_ansible/playbooks/roles/README.md) | Role-by-role reference |

## Requirements

- Ansible 2.16+ (or Ansible Tower / AWX)
- RHEL 8 / RHEL 9 target nodes, SSH-reachable from the workstation
- OpenJDK 17 (default) or OpenJDK 11 on target nodes
- External database server (one of: MariaDB, MySQL, PostgreSQL, Oracle 19c)

See the [ODP Support Matrix](https://docs.acceldata.io/odp/support-matrix) for certified OS / JDK / database versions.

## License

Copyright Acceldata, Inc. See [odp_deployment_ansible/README.md#license](odp_deployment_ansible/README.md#license).
