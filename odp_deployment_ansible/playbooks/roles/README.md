# Roles

## common

Applied to all nodes (`hadoop-cluster` group). Prepares OS prerequisites:

- Installs required OS packages
- Validates Java (JAVA_HOME)
- Checks NTP service (chronyd)
- Adds all nodes to `/etc/hosts` (when `external_dns: false`)
- Stops the firewall service (when `disable_firewall: true`)
- Disables SELinux (when `disable_selinux: true`)
- Disables THP (when `disable_thp: true`)

## ambari_repo

Executed as a dependency of `ambari_agent` and `ambari_server` roles.
Sets up the Ambari YUM repository on each node.

## ambari_agent

Applied to all nodes. Installs, configures, and starts the Ambari Agent:

- Installs `ambari-agent` package
- Sets the Ambari Server hostname
- Configures TLS 1.2
- Updates log directory

## ambari_server

Applied to the `ambari-server` inventory group. Installs and sets up the Ambari Server:

- Installs `ambari-server` package
- Loads the Ambari database schema (PostgreSQL or MySQL/MariaDB)
- Configures JDBC driver
- Runs `ambari-server setup` with Java and database options

## ambari_config

Applied to the `ambari-server` inventory group. Post-install Ambari configuration:

- Sets GPL license acceptance
- Changes default admin password
- Uploads the ODP Version Definition File (VDF)
- Registers repository URLs
- Waits for all Ambari Agents to register

## ambari_blueprint

Applied to the `ambari-server` inventory group. Deploys the ODP cluster via Ambari Blueprints:

- Generates a dynamic blueprint from [blueprint_dynamic.j2](ambari_blueprint/templates/blueprint_dynamic.j2) or loads a static one
- Generates the [Cluster Creation Template](ambari_blueprint/templates/cluster_template.j2)
- Uploads the blueprint to Ambari via REST API
- Creates the cluster and polls until deployment completes

At the end of this role, the ODP cluster is fully installed.
