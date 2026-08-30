#!/bin/bash
# ODP-7526: Merge SPARK3 stack-select mappings (including SPARK3_CONNECT_SERVER)
# from the Ambari stack definition into cluster-env stack_packages.
# Required on clusters created before Spark3 Connect was added; otherwise
# ComponentVersionCheckAction reports UNKNOWN for SPARK3_CONNECT_SERVER.

set -euo pipefail

AMBARISERVER="${AMBARISERVER:-$(hostname -f)}"
USER="${USER:-admin}"
PASSWORD="${PASSWORD:-admin}"
PORT="${PORT:-8080}"
PROTOCOL="${PROTOCOL:-http}"
STACK_VERSION="${STACK_VERSION:-3.3}"

CLUSTER=$(curl -s -k -u "$USER:$PASSWORD" -i -H 'X-Requested-By: ambari' \
    "$PROTOCOL://$AMBARISERVER:$PORT/api/v1/clusters" \
    | sed -n 's/.*"cluster_name" : "\([^\"]*\)".*/\1/p')

STACK_PACKAGES_FILE="/var/lib/ambari-server/resources/stacks/ODP/${STACK_VERSION}/properties/stack_packages.json"

if [[ ! -f "$STACK_PACKAGES_FILE" ]]; then
    echo "[ERROR] Missing $STACK_PACKAGES_FILE (deploy odp-ambari ODP-7526 first)"
    exit 1
fi

python3 - "$CLUSTER" "$STACK_PACKAGES_FILE" "$AMBARISERVER" "$USER" "$PASSWORD" "$PORT" "$PROTOCOL" <<'PY'
import json, re, subprocess, sys, tempfile

cluster, stack_file, host, user, password, port, protocol = sys.argv[1:8]

with open(stack_file) as f:
    file_sp = json.load(f)

result = subprocess.run([
    "python3", "/var/lib/ambari-server/resources/scripts/configs.py",
    "-u", user, "-p", password, "-s", protocol, "-a", "get",
    "-t", port, "-l", host, "-n", cluster, "-c", "cluster-env"
], capture_output=True, text=True, check=True)
cluster_sp = json.loads(re.search(r"\{.*\}", result.stdout, re.S).group(0))
sp = json.loads(cluster_sp["properties"]["stack_packages"])

stack_select = sp.setdefault("ODP", {}).setdefault("stack-select", {})
file_select = file_sp["ODP"]["stack-select"]

for key in ("SPARK3", "SPARK3_3_3_3", "SPARK3_3_5_1"):
    if key in file_select:
        stack_select[key] = file_select[key]
        print(f"[OK] Merged stack-select mapping for {key}")

if "SPARK3_CONNECT_SERVER" not in stack_select.get("SPARK3", {}):
    print("[ERROR] SPARK3_CONNECT_SERVER still missing after merge")
    sys.exit(1)

new_sp = json.dumps(sp)
with tempfile.NamedTemporaryFile("w", delete=False, suffix=".xml") as tf:
    tf.write('<?xml version="1.0"?>\n<configuration>\n')
    tf.write('  <property>\n    <name>stack_packages</name>\n')
    tf.write('    <value><![CDATA[' + new_sp + ']]></value>\n')
    tf.write('  </property>\n</configuration>\n')
    path = tf.name

subprocess.run([
    "python3", "/var/lib/ambari-server/resources/scripts/configs.py",
    "-u", user, "-p", password, "-s", protocol, "-a", "set",
    "-t", port, "-l", host, "-n", cluster,
    "-c", "cluster-env", "-f", path,
    "-b", "ODP-7526: merge SPARK3 stack_packages including CONNECT_SERVER"
], check=True)
print("[OK] Updated cluster-env stack_packages for", cluster)
PY

echo "[INFO] Restart ambari-agents on Spark3 Connect hosts, then retry EU finalize."
