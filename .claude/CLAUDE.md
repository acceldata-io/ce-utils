# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Acceldata customer-engineering utilities for **ODP** (Acceldata's Hadoop distribution, managed by Ambari) and **Pulse** (Acceldata's observability product). Everything here is a script or a config/XML payload that an engineer copies onto a customer host and runs by hand. There is no build, no package, no test suite, and no CI.

Scripts are meant to run on specific hosts, not on a dev machine:
- `odp-upgrade-to-*`, `ODP/scripts/*`, `util-*`: the **Ambari Server** node (they touch `/var/lib/ambari-server/resources/...` and call the Ambari REST API on localhost).
- `pulse/*`: the **Pulse server** (needs `$AcceloHome`, docker, `accelo`).
- `ODP/scripts/knox_ssl.sh`, `knox-service-discovery.sh`: the **Knox** node.

## Checking changes locally

Since nothing here can be executed end-to-end off-cluster, validate syntax only:

```bash
bash -n path/to/script.sh            # most scripts; note upgrade_ambari_336.sh and setup_mpacks_upgrade_planner.sh use #!/bin/sh
shellcheck path/to/script.sh         # if installed
python3 -m py_compile path/to/file.py
xmllint --noout path/to/file.xml     # upgrade packs, VDFs, Ambari config XML
```

Python versions are mixed on purpose. Match the file you are editing:
- `ambari-api/ambari-api.py` is Python 2 (print statements, `ConfigParser`).
- `generate-auth-token/` and `util-3.3.6.3-101-ambari_java_home/lib/` are Python 3 (the util pins `python3.11`).
- `service_advisor.py`, `params.py`, `master.py`, `kafka.py`, `Tez_service_check.py` inside the kits are **Ambari stack scripts**. They import `resource_management` and only run inside the Ambari server/agent interpreter; do not try to run them standalone, and keep them compatible with the Ambari Python runtime on the target ODP version.

## Layout and the three script families

### 1. ODP upgrade kits: `odp-upgrade-to-<version>/`

One directory per target ODP release (`3_3_6_0_1` ... `3_3_6_5_1`, plus `3_2_3_701_2` and the older `3_2_3_5`). Each kit is a **full, independent copy**, not a shared module: a new kit is created by copying the previous one and applying the delta. Fixes made to one kit do not propagate; when you fix the latest kit, decide explicitly whether older kits (still used by customers on those versions) need the same change, and say so.

Standard kit shape:

```
odp-upgrade-to-X/
  README.md                       # customer-facing runbook; keep in sync with the scripts
  upgrade_ambari_336.sh           # step 1: copy 3.3 stack definition + patch Zeppelin/Tez/Knox/Infra-Solr scripts on the server
  upgrade_files_<ver>/
    3.0/ 3.1/ 3.2/ 3.3/ 3.4/      # mirrors /var/lib/ambari-server/resources/stacks/ODP/<ver>/
      upgrades/*.xml              #   Express (nonrolling-upgrade-N.M.xml) / Rolling (upgrade-N.M.xml) packs + config-upgrade.xml
      services/<SVC>/             #   metainfo.xml, service_advisor.py, configuration/*.xml overrides
    setup_mpacks_upgrade_planner.sh   # copies the upgrades/*.xml above into the live stacks dir (backs up to ./mpacks-upgrade-planner-backup/)
    setup_jdk17_config.sh         # interactive menu; pushes env/opts templates into Ambari configs via configs.py
    ODP-env-templates/            # content for *-env / *-site / logback / log4j2 config types; jdk8-specific/ and jdk11-specific/ variants
    zeppelin_*.py, zeppelin_metainfo.xml, Tez_service_check.py, ambari_infra_solr_package_scripts_params.py
```

Customer flow (see each README): `bash upgrade_ambari_336.sh` → `ambari-server restart` → `bash setup_mpacks_upgrade_planner.sh` → `ambari-server restart` → `bash setup_jdk17_config.sh` before resuming the EU/RU in Ambari.

Things that matter when editing a kit:
- `upgrade_ambari_336.sh` is **not idempotent**: it `mv`s originals into `./backup-files/` and `mkdir`s that dir without `-p`. Running it twice fails on the moves. Don't "fix" this silently; it is relied on as a one-shot.
- The `3_2_3_701_2` kit is "3.3.6.5-1 plus HttpFS, Ozone, Hue, Airflow, JupyterHub in the packs". It was developed as `odp-upgrade-to-3_3_6_6_1` and renamed in commit e074326, so older commit messages and READMEs that say "3.3.6.6-1 kit" mean this directory. Its files dir is `upgrade_files_323701/`, and its `upgrade_ambari_336.sh` deliberately **omits** the Zeppelin/Tez replacement steps. For a same-stack 3.2 patch upgrade customers skip `upgrade_ambari_336.sh` entirely and only run the planner script.
- For ODP 3.2 clusters, Express uses `3.2/upgrades/nonrolling-upgrade-3.2.xml` and Rolling uses `3.2/upgrades/upgrade-3.2.xml`. A Rolling pack whose `<target-stack>` says ODP-3.3 makes Ambari grey out Rolling for same-stack upgrades (this bit us once; see commit c314805).
- Express Upgrade only runs service checks listed in the `SERVICE_CHECK_*` priority groups of the nonrolling pack. Adding a service to the pack without adding it there means its check never runs.
- `setup_jdk17_config.sh` asks for the *source* JDK (8/11/17). 8 and 11 select `ODP-env-templates/jdk8-specific/` or `jdk11-specific/` overrides; 17 is "patch-upgrade mode" with a reduced menu. Templates under `ODP-env-templates/` are the exact `content` values pushed to Ambari, so whitespace and Jinja (`{{stack_root}}`) matter.
- The upgrade-pack XMLs and `service_advisor.py` files are copied from `acceldata-io/odp-ambari`; READMEs and script headers cite the source commit. When updating them, cite the odp-ambari commit/PR you took them from.

### 2. ODP day-2 operations: `ODP/scripts/`

Standalone, interactive Bash tools for SSL enable/disable, keystore generation, LDAP for Ambari/Ranger/Knox, Knox topology generation, Infra-Solr API operations, config backup/restore, HDFS cleanup audit, and `cluster_compare.py`. `ODP/README.md` is the user-facing index and per-script instructions; add a numbered section there when adding a script.

### 3. Pulse: `pulse/`

`pulse_utility.sh` is the main entry point (`./pulse_utility.sh <command>`, with a documented exit-code table in its header). The others are focused helpers (pre-reqs, SSL/TLS, dashboards export/import, upgrade, agent health). `pulse/README.md` documents them.

### Other top-level dirs

- `sample-vdfs/`: Version Definition File XMLs customers upload in the Ambari upgrade wizard, one per ODP build. Repo URLs inside point at public Acceldata repos and customers edit them for air-gapped mirrors.
- `util-3.3.6.3-101-ambari_java_home/`: post-install patch (ODP-6189) with its own README, flags (`--dry-run`, `--no-stack-python`, `--no-cluster-config`) and env-var config. Follows a stricter style than the rest of the repo (set -e, timestamped backups, python3.11 helpers in `lib/`).
- `upgrade_3_2_2_*`, `upgrade_3_2_3_2-*`: legacy single-purpose upgrade helpers; keep as-is.
- `ambari-api/`, `generate-auth-token/`: tiny Python helpers driven by an adjacent `.cfg` file.

## Conventions shared across scripts

- **Ambari access pattern.** Scripts talk to Ambari two ways: raw `curl -u USER:PASSWORD -H 'X-Requested-By: ambari' $PROTOCOL://$AMBARISERVER:$PORT/api/v1/...`, and the server-bundled `python /var/lib/ambari-server/resources/scripts/configs.py -a get|set|delete -c <config-type> -k <key> -v <value>` (or `-f <xml>` to replace a whole config type). Cluster name is autodetected from `/api/v1/clusters`. Reuse these helpers (`set_config`, `delete_config`, `get_config_property`, `config_type_present`, `get_host_for_component` in `setup_jdk17_config.sh`) rather than inventing new call shapes.
- **Credentials are edit-in-place variables** at the top of each script (`AMBARISERVER`, `USER`, `PASSWORD`, `PORT`, `PROTOCOL`), defaulting to `admin/admin`, `8080`, `http`. The READMEs tell customers to edit them. Newer scripts also accept CLI flags (`disable_ssl.sh`) or env vars (`util-*`); either is fine, but keep the variable names.
- **Back up before overwriting** anything under `/var/lib/ambari-server/resources`. Existing conventions: `./backup-files/`, `./mpacks-upgrade-planner-backup/`, `$BACKUP_ROOT/<timestamp>/`.
- **Skip, don't fail, when a service or stack isn't installed** (check for the stack dir, or `config_type_present`), since one kit serves many cluster shapes.
- **Output style** is `echo` with `[INFO]/[WARN]/[ERROR]` prefixes or coloured `${GREEN}...${NC}` banners; failures also `tee -a /tmp/<script>.log`.
- **Commit messages** start with the Jira key: `ODP-NNNN: ...` (also `API-NNNN`, `OCR-NNNN`). READMEs link to files by absolute GitHub URL on `acceldata-io/ce-utils` `main`.
- **READMEs are the deliverable to customers.** Any change in a script's prompts, options, file names or run order must be mirrored in the directory's README (and `ODP-env-templates/README.md` for manual-config fallbacks).
