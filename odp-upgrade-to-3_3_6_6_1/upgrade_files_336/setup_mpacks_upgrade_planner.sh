#!/bin/sh
#
# Acceldata Inc. | ODP
#
# Copy Ambari Express/Rolling upgrade-pack XMLs so MPACK services
# (Spark3 / Spark3 3.3.3 / Spark3 3.5.1, Livy3, Impala, Pinot, Kafka3,
# HttpFS, Ozone, Hue) are included in the Ambari upgrade planner.
# Also installs config-upgrade.xml and stack_packages.json so EU
# configure tasks and odp-select mappings resolve.
#
# ZooKeeper logback: bundled upgrade XMLs do not run create_and_configure during
# EU/RU (avoids cross-stack failure on 3.2->3.3). Apply zookeeper-logback with
# setup_jdk17_config.sh (option 8 or A) before resuming the upgrade.
#
# Run this file from upgrade_files_336 on the Ambari Server, then restart
# ambari-server. Bundled XMLs are copied in place; no RPM download.
#
#   cd ./odp-upgrade-to-3_3_6_6_1/upgrade_files_336/
#   bash ./setup_mpacks_upgrade_planner.sh
#   ambari-server restart

set -e

AMBARI_STACKS="${AMBARI_STACKS:-/var/lib/ambari-server/resources/stacks/ODP}"
BACKUP_DIR="./mpacks-upgrade-planner-backup"

echo "################# MPACK upgrade planner (3.3.6.6-1) #################"
echo "[INFO] Copying bundled upgrade pack XMLs onto the Ambari Server"
echo "[INFO] AMBARI_STACKS=$AMBARI_STACKS"

if [ ! -d "$AMBARI_STACKS" ]; then
  echo "[ERROR] Missing $AMBARI_STACKS. Run this on the Ambari Server host."
  exit 1
fi

mkdir -p "$BACKUP_DIR"

copy_xml() {
  src="$1"
  dest="$2"

  if [ ! -f "$src" ]; then
    echo "[ERROR] Missing bundled file: $src"
    exit 1
  fi

  dest_dir=$(dirname "$dest")
  if [ ! -d "$dest_dir" ]; then
    echo "[WARN] Skip $src (stack dir not installed: $dest_dir)"
    return 0
  fi

  if [ -f "$dest" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$src")"
    cp -a "$dest" "$BACKUP_DIR/$src"
  fi

  cp -a "$src" "$dest"
  echo "[INFO] Installed $dest"
}

echo "1.################# ODP 3.0 #################"
copy_xml 3.0/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.0/upgrades/config-upgrade.xml"
copy_xml 3.0/upgrades/nonrolling-upgrade-3.0.xml "$AMBARI_STACKS/3.0/upgrades/nonrolling-upgrade-3.0.xml"
copy_xml 3.0/upgrades/nonrolling-upgrade-3.1.xml "$AMBARI_STACKS/3.0/upgrades/nonrolling-upgrade-3.1.xml"
copy_xml 3.0/properties/stack_packages.json "$AMBARI_STACKS/3.0/properties/stack_packages.json"

echo "2.################# ODP 3.1 #################"
copy_xml 3.1/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.1/upgrades/config-upgrade.xml"
copy_xml 3.1/upgrades/nonrolling-upgrade-3.1.xml "$AMBARI_STACKS/3.1/upgrades/nonrolling-upgrade-3.1.xml"

echo "3.################# ODP 3.2 #################"
copy_xml 3.2/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.2/upgrades/config-upgrade.xml"
copy_xml 3.2/upgrades/nonrolling-upgrade-3.2.xml "$AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.2.xml"
copy_xml 3.2/upgrades/nonrolling-upgrade-3.3.xml "$AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.3.xml"
copy_xml 3.2/upgrades/upgrade-3.2.xml           "$AMBARI_STACKS/3.2/upgrades/upgrade-3.2.xml"
copy_xml 3.2/upgrades/upgrade-3.3.xml           "$AMBARI_STACKS/3.2/upgrades/upgrade-3.3.xml"

echo "4.################# ODP 3.3 #################"
copy_xml 3.3/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.3/upgrades/config-upgrade.xml"
copy_xml 3.3/upgrades/nonrolling-upgrade-3.3.xml "$AMBARI_STACKS/3.3/upgrades/nonrolling-upgrade-3.3.xml"
copy_xml 3.3/upgrades/nonrolling-upgrade-3.4.xml "$AMBARI_STACKS/3.3/upgrades/nonrolling-upgrade-3.4.xml"
copy_xml 3.3/upgrades/upgrade-3.3.xml           "$AMBARI_STACKS/3.3/upgrades/upgrade-3.3.xml"
copy_xml 3.3/upgrades/upgrade-3.4.xml           "$AMBARI_STACKS/3.3/upgrades/upgrade-3.4.xml"
copy_xml 3.3/properties/stack_packages.json "$AMBARI_STACKS/3.3/properties/stack_packages.json"

echo "5.################# ODP 3.4 #################"
copy_xml 3.4/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.4/upgrades/config-upgrade.xml"
copy_xml 3.4/upgrades/nonrolling-upgrade-3.4.xml "$AMBARI_STACKS/3.4/upgrades/nonrolling-upgrade-3.4.xml"
copy_xml 3.4/upgrades/upgrade-3.4.xml           "$AMBARI_STACKS/3.4/upgrades/upgrade-3.4.xml"

echo "6.################# Ozone Client no-op start/stop #################"
OZONE_CLIENT_SRC="./scripts/ozone_client.py"
if [ ! -f "$OZONE_CLIENT_SRC" ]; then
  echo "[ERROR] Missing bundled file: $OZONE_CLIENT_SRC"
  exit 1
fi

install_ozone_client() {
  dest="$1"
  if [ ! -f "$dest" ]; then
    return 0
  fi
  mkdir -p "$BACKUP_DIR/ozone_client"
  dest_key=$(echo "$dest" | tr '/' '_')
  cp -a "$dest" "$BACKUP_DIR/ozone_client/${dest_key}"
  if [ -w "$dest" ]; then
    cp -a "$OZONE_CLIENT_SRC" "$dest"
  else
    sudo cp -a "$OZONE_CLIENT_SRC" "$dest"
  fi
  echo "[INFO] Installed $dest"
}

# Agent STOP/RESTART uses the cached copy. Replace every ozone_client.py on this host.
found=0
for dest in $(find /var/lib/ambari-server/resources /var/lib/ambari-agent/cache -name ozone_client.py 2>/dev/null); do
  install_ozone_client "$dest"
  found=1
done
if [ "$found" = "0" ]; then
  echo "[WARN] No ozone_client.py found on this host. Ozone mpack may not be installed."
fi

# Other agents keep their own cache. Copy over SSH when Ambari API and host SSH work.
AMB_USER="${AMB_USER:-admin}"
AMB_PASS="${AMB_PASS:-admin}"
AMB_URL="${AMB_URL:-http://localhost:8080}"
THIS_HOST=$(hostname -s 2>/dev/null || hostname)
python3 - "$OZONE_CLIENT_SRC" "$AMB_URL" "$AMB_USER" "$AMB_PASS" "$THIS_HOST" << 'PY' || echo "[WARN] Could not copy ozone_client.py to remote agents. Copy scripts/ozone_client.py onto each agent cache path and Retry."
import json, os, subprocess, sys, urllib.request, base64

src, amb_url, user, password, this_host = sys.argv[1:6]
auth = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
req = urllib.request.Request(
    amb_url.rstrip("/") + "/api/v1/clusters?fields=Clusters/cluster_name",
    headers={"Authorization": "Basic " + auth},
)
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        clusters = json.load(r)
except Exception as e:
    print("[WARN] Ambari API cluster list failed: %s" % e)
    sys.exit(0)

if not clusters.get("items"):
    print("[WARN] No Ambari cluster found; skip remote ozone_client.py copy")
    sys.exit(0)

cluster = clusters["items"][0]["Clusters"]["cluster_name"]
req = urllib.request.Request(
    "%s/api/v1/clusters/%s/hosts?fields=Hosts/host_name" % (amb_url.rstrip("/"), cluster),
    headers={"Authorization": "Basic " + auth},
)
with urllib.request.urlopen(req, timeout=20) as r:
    hosts = [i["Hosts"]["host_name"] for i in json.load(r).get("items", [])]

remote_cmd = (
    "set -e; SRC=/tmp/ozone_client.py; "
    "for dest in $(find /var/lib/ambari-agent/cache /var/lib/ambari-server/resources -name ozone_client.py 2>/dev/null); do "
    "cp -a \"$dest\" \"${dest}.bak.mpacks-planner\"; "
    "if [ -w \"$dest\" ]; then cp -a \"$SRC\" \"$dest\"; else sudo cp -a \"$SRC\" \"$dest\"; fi; "
    "echo INSTALLED $dest; done"
)

for host in hosts:
    short = host.split(".")[0]
    if short == this_host or host == this_host:
        continue
    print("[INFO] Copying ozone_client.py to %s" % host)
    scp = subprocess.call(["scp", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", src, "%s:/tmp/ozone_client.py" % host])
    if scp != 0:
        print("[WARN] scp to %s failed. Copy scripts/ozone_client.py onto that agent and Retry." % host)
        continue
    rc = subprocess.call(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", host, remote_cmd])
    if rc != 0:
        print("[WARN] install on %s failed" % host)
PY

echo "[INFO] Backups (if any): $BACKUP_DIR"
echo "[INFO] Verify HttpFS and Ozone are in the Express pack used by this cluster:"
echo "  grep -E 'name=\"HTTPFS\"|name=\"OZONE\"|name=\"HUE\"' $AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.2.xml"
echo "[INFO] Same-stack Rolling on ODP 3.2 requires upgrade-3.2.xml to target ODP-3.2, not ODP-3.3:"
echo "  grep -E '<target>|<target-stack>|<type>' $AMBARI_STACKS/3.2/upgrades/upgrade-3.2.xml"
echo "[INFO] Expected: target 3.2.*.* , target-stack ODP-3.2 , type ROLLING"
echo "[INFO] Ozone Client STOP during EU needs empty start/stop in ozone_client.py:"
echo "  grep -n 'def start\\|def stop' /var/lib/ambari-agent/cache/common-services/OZONE/1.4.1/package/scripts/ozone_client.py"
echo "[INFO] Restart Ambari Server so the planner reloads these packs:"
echo "  ambari-server restart"
echo "################# changes completed #################"
