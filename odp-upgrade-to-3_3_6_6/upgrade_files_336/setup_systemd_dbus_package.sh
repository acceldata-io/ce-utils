#!/bin/sh
#
# Acceldata Inc. | ODP
#
# OCR-2671: mpack metainfo.xml names the package
# python*-systemd-dbus_${stack_version}. Ambari expands that to a name such as
# python*-systemd-dbus_3_3_6_6_1010, which is not in the repository, and
# Install Packages fails with "No package found".
#
# Replace that name with python*-systemd-dbus (no stack suffix).
# https://accelcentral.atlassian.net/wiki/x/FoCzdQ
#
# Package install reads the registered copies under common-services and stacks,
# not only the mpack tree. This script updates all three.
#
# Run on the Ambari Server, from this directory:
#   bash ./setup_systemd_dbus_package.sh
#   ambari-server restart
#
# Then retry Install Packages.
# Optional: pass one or more directories instead of the defaults.

set -e

AMBARI_RESOURCES="${AMBARI_RESOURCES:-/var/lib/ambari-server/resources}"

rewrite_tree() {
  root="$1"

  if [ ! -d "$root" ]; then
    echo "[WARN] Skip missing directory: $root"
    return 0
  fi

  echo "[INFO] Scanning $root"
  tmp=$(mktemp)
  # grep exits 1 when nothing matches. That is not a failure.
  grep -rl 'python\*-systemd-dbus_${stack_version}' "$root" > "$tmp" || true

  if [ ! -s "$tmp" ]; then
    echo "[INFO] No python*-systemd-dbus_\${stack_version} entries under $root"
    rm -f "$tmp"
    return 0
  fi

  while read -r f; do
    if [ -z "$f" ]; then
      continue
    fi
    sed -i 's/python\*-systemd-dbus_\${stack_version}/python*-systemd-dbus/g' "$f"
    echo "[INFO] Updated $f"
  done < "$tmp"
  rm -f "$tmp"
}

echo "[INFO] OCR-2671: drop the stack_version suffix from python*-systemd-dbus"

if [ "$#" -gt 0 ]; then
  for root in "$@"; do
    rewrite_tree "$root"
  done
else
  rewrite_tree "$AMBARI_RESOURCES/mpacks"
  rewrite_tree "$AMBARI_RESOURCES/common-services"
  rewrite_tree "$AMBARI_RESOURCES/stacks"
fi

echo "[INFO] Restart Ambari Server, then retry Install Packages:"
echo "  ambari-server restart"
echo "[INFO] changes completed"
