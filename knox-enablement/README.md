# Knox Enablement for Ambari BigData Cluster

Automated Knox enablement scripts for Ambari-managed Hadoop clusters.

## Project Structure

```
knox-enablement/
├── main.py              # Entry point - run steps from here
├── requirements.txt     # Python dependencies
├── env.example          # Environment config template
├── config/
│   └── settings.py      # Configuration from env vars
├── modules/
│   ├── ssh_client.py    # SSH operations via paramiko
│   └── configs.py       # Ambari configuration manager
└── steps/
```

## Setup

```bash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

cp env.example .env
# Edit .env with your cluster details
```

## Usage

```bash
python main.py set_proxy_users    # Run a single step
python main.py knox_proxy_setup   # Run the full Knox proxy setup flow
python main.py knox_sso_setup     # Run the full Knox SSO + LDAP setup flow
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
from modules import AmbariConfigs

configs = AmbariConfigs(host, user, password, cluster)
value = configs.get_property("core-site", "hadoop.proxyuser.knox.hosts")
configs.set_property("core-site", "hadoop.proxyuser.knox.hosts", "*")
configs.set_properties("core-site", {"key1": "val1", "key2": "val2"})
```

### SSHClient

```python
from modules import SSHClient

with SSHClient() as ssh:
    exit_code, stdout, stderr = ssh.execute("ambari-server status")
    ssh.execute_sudo("openssl req -new ...")
```
