#!/bin/sh
#
# Acceldata Inc. | ODP
#
# ODP-8228: copy Ambari Express/Rolling upgrade-pack XMLs so MPACK services
# (Spark3 / Spark3 3.3.3 / Spark3 3.5.1, Livy3, Impala, Pinot, Kafka3,
# HttpFS, Ozone, Hue, Airflow, JupyterHub) are included in the Ambari
# upgrade planner.
#
# ODP-8211: a 3.2.3 source only scans stacks/ODP/3.2/upgrades. The 3.2
# nonrolling-upgrade-3.4.xml and upgrade-3.4.xml files are the 3.3
# target-3.4 packs copied into that directory.
#
# Also installs config-upgrade.xml so EU configure tasks
# (for example odp_3_4_0_hdfs_log4j_remove_event_counter) resolve.
#
# Source: odp-ambari rel/ODP-AMBARI-3.0.1.0-1
#   facc6918eb3ef6ec11f49cdfcffc9e1dd5977e22
#
# Run this file from upgrade_files_343 on the Ambari Server, then restart
# ambari-server. Bundled XMLs are copied in place; no RPM download.
# A plan that is already created keeps its old groups. Create a new
# Express or Rolling upgrade after the restart.
#
#   cd ./odp-upgrade-to-3_4_3_0/upgrade_files_343/
#   bash ./setup_mpacks_upgrade_planner.sh
#   ambari-server restart

set -e

AMBARI_STACKS="${AMBARI_STACKS:-/var/lib/ambari-server/resources/stacks/ODP}"
BACKUP_DIR="./mpacks-upgrade-planner-backup"

echo "################# ODP-8228 MPACK upgrade planner #################"
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
copy_xml 3.0/upgrades/upgrade-3.0.xml           "$AMBARI_STACKS/3.0/upgrades/upgrade-3.0.xml"
copy_xml 3.0/upgrades/upgrade-3.1.xml           "$AMBARI_STACKS/3.0/upgrades/upgrade-3.1.xml"

echo "2.################# ODP 3.1 #################"
copy_xml 3.1/upgrades/nonrolling-upgrade-3.1.xml "$AMBARI_STACKS/3.1/upgrades/nonrolling-upgrade-3.1.xml"
copy_xml 3.1/upgrades/upgrade-3.1.xml           "$AMBARI_STACKS/3.1/upgrades/upgrade-3.1.xml"

echo "3.################# ODP 3.2 #################"
copy_xml 3.2/upgrades/nonrolling-upgrade-3.2.xml "$AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.2.xml"
copy_xml 3.2/upgrades/nonrolling-upgrade-3.3.xml "$AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.3.xml"
copy_xml 3.2/upgrades/nonrolling-upgrade-3.4.xml "$AMBARI_STACKS/3.2/upgrades/nonrolling-upgrade-3.4.xml"
copy_xml 3.2/upgrades/upgrade-3.2.xml           "$AMBARI_STACKS/3.2/upgrades/upgrade-3.2.xml"
copy_xml 3.2/upgrades/upgrade-3.3.xml           "$AMBARI_STACKS/3.2/upgrades/upgrade-3.3.xml"
copy_xml 3.2/upgrades/upgrade-3.4.xml           "$AMBARI_STACKS/3.2/upgrades/upgrade-3.4.xml"

echo "4.################# ODP 3.3 #################"
copy_xml 3.3/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.3/upgrades/config-upgrade.xml"
copy_xml 3.3/upgrades/nonrolling-upgrade-3.3.xml "$AMBARI_STACKS/3.3/upgrades/nonrolling-upgrade-3.3.xml"
copy_xml 3.3/upgrades/nonrolling-upgrade-3.4.xml "$AMBARI_STACKS/3.3/upgrades/nonrolling-upgrade-3.4.xml"
copy_xml 3.3/upgrades/upgrade-3.3.xml           "$AMBARI_STACKS/3.3/upgrades/upgrade-3.3.xml"
copy_xml 3.3/upgrades/upgrade-3.4.xml           "$AMBARI_STACKS/3.3/upgrades/upgrade-3.4.xml"

echo "5.################# ODP 3.4 #################"
copy_xml 3.4/upgrades/config-upgrade.xml "$AMBARI_STACKS/3.4/upgrades/config-upgrade.xml"
copy_xml 3.4/upgrades/nonrolling-upgrade-3.4.xml "$AMBARI_STACKS/3.4/upgrades/nonrolling-upgrade-3.4.xml"
copy_xml 3.4/upgrades/upgrade-3.4.xml           "$AMBARI_STACKS/3.4/upgrades/upgrade-3.4.xml"

echo "[INFO] Backups (if any): $BACKUP_DIR"
echo "[INFO] Restart Ambari Server so the planner reloads these packs:"
echo "  ambari-server restart"
echo "[INFO] Create a new Express or Rolling upgrade. A paused plan keeps its old groups."
echo "################# changes completed #################"
