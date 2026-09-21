# Knox Enablement for Ambari BigData Cluster

Automated Knox enablement scripts for Ambari-managed Hadoop clusters.

## Project Structure

```
knox-enablement % tree
├── env.example                     # Environment config template
├── knox_setup
│   ├── config
│   │   ├── __init__.py
│   │   └── settings.py             # Configuration from env vars
│   ├── main.py                     # Entry point
│   ├── modules
│   │   ├── __init__.py
│   │   ├── ambari_state.py
│   │   ├── configs.py             # Ambari configuration manager
│   │   ├── knox_state.py
│   │   ├── service_utils.py
│   │   └── ssh_client.py          # SSH operations via paramiko
│   ├── steps
│   │   ├── __init__.py
│   │   ├── add_ranger_policy.py
│   │   ├── ambari_ldap_setup.py
│   │   ├── ambari_sso_setup.py
│   │   ├── base.py
│   │   ├── export_knox_cert.py
│   │   ├── import_knox_cert.py
│   │   ├── restart_ambari.py
│   │   ├── restart_services.py
│   │   ├── set_proxy_users.py
│   │   ├── start_knox.py
│   │   ├── update_topology.py
│   │   └── update_whitelist.py
│   └── templates
│       └── knox-topology.j2
├── LICENSE
├── LICENSES
├── pyproject.toml
├── README.md
└── setup.sh
```

## Setup

```bash
python3.11 -m venv venv
. venv/bin/activate
pip install "git+https://github.com/acceldata-io/ce-utils/@ODP-5751#egg=knox_setup&subdirectory=knox_setup"

cp env.example .env
# Edit .env with your cluster details
```

## Usage

```bash
knox_setup set_proxy_users    # Run a single step
knox_setup knox_proxy_setup   # Run the full Knox proxy setup flow
knox_setup knox_sso_setup     # Run the full Knox SSO + LDAP setup flow
```

## Steps

| Step | Description |
|------|-------------|
| start_knox | Verify Knox installed, start Knox & Demo LDAP |
| set_proxy_users | Configure Knox proxy user in core-site (groups/hosts = *) |
| update_topology | Update Knox topology with cluster hostnames (+ HaProvider if HDFS HA) |
| update_whitelist | Update gateway.dispatch.whitelist with cluster domain pattern |
| restart_services | Restart all services with stale configs (HDFS, YARN, MR2, Hive, Tez, Ranger, KMS, Knox) |
| export_knox_cert | Export Knox gateway certificate (PEM) and store in state |
| ambari_sso_setup | Configure Ambari SSO with Knox (setup-sso CLI) |
| ambari_ldap_setup | Configure Ambari LDAP with Knox Demo LDAP (setup-ldap + sync-ldap) |
| import_knox_cert | Import Knox certificate to Java cacerts + restart Ranger |
| restart_ambari | Restart Ambari server to apply SSO/LDAP config |

## Flows

| Flow | Steps | Description |
|------|-------|-------------|
| knox_proxy_setup | start_knox → set_proxy_users → update_topology → update_whitelist → restart_services | Knox proxy setup |
| knox_sso_setup | start_knox → ... → restart_ambari → restart_services | Full Knox SSO + LDAP setup |

## Modules

### AmbariConfigs

```python
from knox_setup.modules import AmbariConfigs

configs = AmbariConfigs(host, user, password, cluster)
value = configs.get_property("core-site", "hadoop.proxyuser.knox.hosts")
configs.set_property("core-site", "hadoop.proxyuser.knox.hosts", "*")
configs.set_properties("core-site", {"key1": "val1", "key2": "val2"})
```

### SSHClient

```python
from knox_setup.modules import SSHClient

with SSHClient() as ssh:
    exit_code, stdout, stderr = ssh.execute("ambari-server status")
    ssh.execute_sudo("openssl req -new ...")
```
