# util-3.3.6.3-101-ambari_java_home

Ambari Server utility for **ODP 3.3** (e.g. **3.3.6.3-101**): applies **[ODP-6189](https://github.com/acceldata-io/odp-ambari/pull/484)** so **CredentialUtil** uses **`ambari_java_home`** / **`$AMBARI_JAVA_HOME/bin/java`** instead of **`java`** on `PATH` (avoids failures when the stack uses Java 11).

**Does:** (1) copies three vendored **`files/stacks/ODP/3.3/.../*.py`** into **`/var/lib/ambari-server/resources/...`** with backups under **`$BACKUP_ROOT/<timestamp>/`**; (2) **`configs.py` get → sed/awk on `kafka-env` / `cruise-control-env` `content` → set** (skips set if nothing changed). Helpers under **`lib/`**: **`ambari_cluster_name.py`** (autodiscover `CLUSTER` via REST), **`json_content_roundtrip.py`**, **`file_sha256.py`**. Stack definition **XML** is not applied here; see **`temp.md`** if you need that diff manually.

## Run

**Host:** must be the **Ambari Server** node (script checks for **`/var/lib/ambari-server`**). **`AMBARI_PORT`** defaults to **8080**; must be **1–65535** if set. **`AMBARI_PROTOCOL`** is **`http`** or **`https`** (case-insensitive).

```bash
export AMBARI_USER=admin AMBARI_PASSWORD='***'
export CLUSTER=mycluster   # optional if API infers one cluster
# export AMBARI_HOST=$(hostname -f) AMBARI_PORT=8443 AMBARI_PROTOCOL=https
sudo -E ./patch_ambari_java_home.sh
```

| Flag | |
|------|--|
| `--no-stack-python` | Skip `files/` → resources copy |
| `--no-cluster-config` | Skip `configs.py` |
| `--dry-run` | Stack: compare only. Cluster: no `configs.py set` |

**Needs:** root for stack copies; **`configs.py`** at **`$AMBARI_RESOURCES/scripts/configs.py`**. **`PYTHON_BIN`** defaults to **`python3.11`**. Override **`CONFIGS_PYTHON_BIN`** only if **`configs.py`** must use another interpreter. With **`AMBARI_PROTOCOL=https`**, **`configs.py`** is called with **`--unsafe`** (skip TLS cert verify) unless you set **`AMBARI_SSL_VERIFY_STRICT=1`**.

### After this util

1. **Cluster configs** (`kafka-env`, `cruise-control-env`): Ambari stores the new version; agents use it the next time those components run **install / configure / start / restart**. Do a **rolling restart** (or restart) of **Kafka**, **Cruise Control**, and **Druid** (and any other consumer of those configs).

2. **Stack `*.py`** on the server (`/var/lib/ambari-server/resources/stacks/...`): agents often keep **cached** copies under **`/var/lib/ambari-agent/`** (exact layout varies by Ambari/ODP). Until the cache is refreshed, a host might still run **old** `params.py` / `kafka.py` for stack-driven actions.

   **Recommended:** on **each host** that runs Kafka, Cruise Control, Druid (or simply **all** cluster nodes), as root:

   ```bash
   sudo ambari-agent restart
   ```

   That restarts the agent and typically rebuilds cache from the server on the next command.

3. **If something still looks stale** (rare): with the agent **stopped**, only after checking your Ambari/ODP version docs, some sites clear **`/var/lib/ambari-agent/cache`** (or the version-specific cache tree) then start the agent again — **do not** delete arbitrary paths without confirming with your runbook.

4. Optionally **restart Ambari Server** if your operations guide requires it after editing `resources/` (often **not** strictly required for stack file edits alone).
