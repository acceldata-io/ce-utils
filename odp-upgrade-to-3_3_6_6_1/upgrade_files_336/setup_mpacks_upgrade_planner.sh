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

echo "[INFO] Backups (if any): $BACKUP_DIR"
echo "[INFO] Verify HttpFS and Ozone are in the Express pack used by this cluster:"
echo "  grep -E 'name=\"HTTPFS\"|name=\"OZONE\"|name=\"HUE\"' $AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.2.xml"
echo "[INFO] Same-stack Rolling on ODP 3.2 requires upgrade-3.2.xml to target ODP-3.2, not ODP-3.3:"
echo "  grep -E '<target>|<target-stack>|<type>' $AMBARI_STACKS/3.2/upgrades/upgrade-3.2.xml"
echo "[INFO] Expected: target 3.2.*.* , target-stack ODP-3.2 , type ROLLING"
echo "[INFO] Restart Ambari Server so the planner reloads these packs:"
echo "  ambari-server restart"
echo "################# changes completed #################"
