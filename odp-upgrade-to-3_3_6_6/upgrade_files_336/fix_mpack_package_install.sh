#!/bin/bash
#
# Acceldata Inc. | ODP
#
# Fixes "Install Packages" failures for Spark3 and Hue when upgrading to
# ODP 3.3.6.6 from a cluster that still has the older mpacks installed.
#
# Install Packages runs BEFORE the mpacks are upgraded, so Ambari builds the
# package list from the OLD mpack metainfo.xml files. Two of them are broken:
#
#   Spark3 (spark3-ambari-3.5.5.mpack-3.5.5)
#     <name>spark3-${stack_version}=3.5.5*</name>
#     -> "No package found for spark3-${stack_version}=3.5.5*"
#     Ambari matches package NAMES from the repo; "=3.5.5*" is an apt version
#     pin, not part of a name, so nothing matches.
#
#   Hue (hue-ambari.mpack-4.11.0)
#     <package>gcc</package>   (no <name> tag)
#     -> "Package Manager failed to install packages: 'name'"  (KeyError)
#
# This script rewrites only those entries, keeps a backup of every file it
# changes, and is safe to run more than once. Files that are already correct
# (for example the 3.3.6.6 mpacks) are not touched.
#
# Run on the Ambari Server host BEFORE "Install Packages" (or after it failed,
# before Retry):
#
#   cd ./odp-upgrade-to-3_3_6_6/upgrade_files_336/
#   bash ./fix_mpack_package_install.sh
#   ambari-server restart
#
# Ambari reads metainfo.xml only at startup, so the restart is required.
#
# Options (environment variables):
#   MPACKS_DIR   default /var/lib/ambari-server/resources/mpacks
#   DRY_RUN=1    show what would change, change nothing

set -u

MPACKS_DIR="${MPACKS_DIR:-/var/lib/ambari-server/resources/mpacks}"
DRY_RUN="${DRY_RUN:-0}"
BACKUP_DIR="./mpack-metainfo-backup-$(date +%Y%m%d%H%M%S)"

GREEN='\e[32m'; YELLOW='\e[33m'; RED='\e[31m'; NC='\e[0m'

if [[ ! -d "$MPACKS_DIR" ]]; then
    echo -e "${RED}[ERROR] $MPACKS_DIR not found. Run this on the Ambari Server host.${NC}"
    exit 1
fi

changed=0

backup_file() {
    local f=$1
    mkdir -p "$BACKUP_DIR"
    cp -p "$f" "$BACKUP_DIR/$(echo "$f" | sed 's#^/##; s#/#__#g')"
}

show_diff() {
    local before=$1 after=$2
    diff "$before" "$after" | sed 's/^/    /'
}

# $1 = file, $2 = sed expression. Applies the edit (or previews it with DRY_RUN=1).
apply_fix() {
    local f=$1 expr=$2 label=$3
    local tmp
    tmp=$(mktemp)
    sed -E "$expr" "$f" > "$tmp"

    if cmp -s "$f" "$tmp"; then
        rm -f "$tmp"
        return 0
    fi

    echo -e "${YELLOW}[$label] $f${NC}"
    show_diff "$f" "$tmp"

    if [[ "$DRY_RUN" == "1" ]]; then
        rm -f "$tmp"
        return 0
    fi

    backup_file "$f"
    # Keep owner and mode of the original file.
    cat "$tmp" > "$f"
    rm -f "$tmp"
    changed=$((changed + 1))
}

echo "################# ODP 3.3.6.6: fix mpack package lists for Install Packages #################"
echo "[INFO] MPACKS_DIR=$MPACKS_DIR  DRY_RUN=$DRY_RUN"

#---------------------------------------------------------
# 1. Hue: wrap bare <package>X</package> as <package><name>X</name></package>
#---------------------------------------------------------
HUE_EXPR='s#<package>[[:space:]]*([^<[:space:]]+)[[:space:]]*</package>#<package><name>\1</name></package>#'
found=0
for f in "$MPACKS_DIR"/hue-ambari*/common-services/HUE/*/metainfo.xml \
         "$MPACKS_DIR"/hue-ambari*/addon-services/HUE/*/metainfo.xml; do
    [[ -f "$f" ]] || continue
    found=1
    apply_fix "$f" "$HUE_EXPR" "Hue"
done
[[ $found -eq 0 ]] && echo "[INFO] No Hue mpack found, skipping Hue."

#---------------------------------------------------------
# 2. Spark3: drop version pins from ${stack_version} package names
#    spark3-${stack_version}=3.5.5*        -> spark3-${stack_version}
#    spark3_${stack_version}-python-3.5.5* -> spark3_${stack_version}-python
#---------------------------------------------------------
SPARK_EXPR='s#(<name>[^<]*\$\{stack_version\}[^<=]*)=[^<]*</name>#\1</name>#; s#(<name>[^<]*\$\{stack_version\}[^<]*)-[0-9][0-9.]*\*</name>#\1</name>#'
found=0
for f in "$MPACKS_DIR"/spark3-ambari*/common-services/SPARK3/*/metainfo.xml \
         "$MPACKS_DIR"/spark3-ambari*/addon-services/SPARK3/*/metainfo.xml; do
    [[ -f "$f" ]] || continue
    found=1
    apply_fix "$f" "$SPARK_EXPR" "Spark3"
done
[[ $found -eq 0 ]] && echo "[INFO] No Spark3 mpack found, skipping Spark3."

#---------------------------------------------------------
# 3. Validate the XML we touched is still well formed
#---------------------------------------------------------
if [[ "$DRY_RUN" != "1" && $changed -gt 0 ]]; then
    for f in "$MPACKS_DIR"/hue-ambari*/*/HUE/*/metainfo.xml "$MPACKS_DIR"/spark3-ambari*/*/SPARK3/*/metainfo.xml; do
        [[ -f "$f" ]] || continue
        if ! python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" "$f" 2>/dev/null; then
            echo -e "${RED}[ERROR] $f is not valid XML after the change. Restore it from $BACKUP_DIR.${NC}"
            exit 1
        fi
    done
fi

echo
if [[ "$DRY_RUN" == "1" ]]; then
    echo -e "${YELLOW}[DRY RUN] No files were changed.${NC}"
elif [[ $changed -gt 0 ]]; then
    echo -e "${GREEN}[OK] Fixed $changed file(s). Backups: $BACKUP_DIR${NC}"
    echo -e "${YELLOW}Next: run 'ambari-server restart', then Install Packages (or Retry).${NC}"
else
    echo -e "${GREEN}[OK] Nothing to fix. The installed mpacks already have valid package lists.${NC}"
fi
