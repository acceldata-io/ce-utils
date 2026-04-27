# util-3.3.6.3-101-ambari_java_home

Ambari Server utility for **ODP 3.3** (e.g. **3.3.6.3-101**): applies **[ODP-6189](https://github.com/acceldata-io/odp-ambari/pull/484)** so **CredentialUtil** uses **`ambari_java_home`** / **`$AMBARI_JAVA_HOME/bin/java`** instead of **`java`** on `PATH` (avoids failures when the stack uses Java 11).

**Does:** (1) copies three vendored **`files/stacks/ODP/3.3/.../*.py`** into **`/var/lib/ambari-server/resources/...`** with backups under **`$BACKUP_ROOT/<timestamp>/`**; (2) **`configs.py` get → sed/awk on `kafka-env` / `cruise-control-env` `content` → set** (skips set if nothing changed). Stack definition **XML** on disk is **not** changed here; use **`temp.md`** if you need that diff manually.

## Run (on Ambari Server)

```bash
export AMBARI_USER=admin AMBARI_PASSWORD='***'
export CLUSTER=mycluster   # optional if API infers one cluster
sudo -E ./patch_ambari_java_home.sh
```

| Flag | |
|------|--|
| `--no-stack-python` | Skip `files/` → resources copy |
| `--no-cluster-config` | Skip `configs.py` |
| `--dry-run` | Stack: compare only. Cluster: no `configs.py set` |

**Needs:** root for stack copies; **`configs.py`** at **`$AMBARI_RESOURCES/scripts/configs.py`** (default **`AMBARI_RESOURCES=/var/lib/ambari-server/resources`**). **`PYTHON_BIN`** defaults to **`python3.11`**. Set **`CONFIGS_PYTHON_BIN`** only if **`configs.py`** must use another interpreter.

Afterward: restart **Kafka**, **Cruise Control**, **Druid** if required; check Ambari for new **`kafka-env` / `cruise-control-env`** versions.
