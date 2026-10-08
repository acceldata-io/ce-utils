These steps copy the ODP 3.4 Express and Rolling upgrade packs onto the Ambari Server so MPACK services are included in the planner.

Source: odp-ambari branch rel/ODP-AMBARI-3.0.1.0-1 (facc6918eb).

The Express upgrade to ODP-3.4.3.0 uses `3.3/upgrades/nonrolling-upgrade-3.4.xml` when the source stack is ODP 3.3. That pack includes Kafka3, Pinot, HttpFS, Ozone, Spark3, Impala, Hue, Airflow, and JupyterHub. Ambari skips a group when that service is not installed.

## MPACK upgrade planner (ODP-8228)

Files are copied from this repo. Do not download an Ambari RPM for this step. Stacks that are not installed on the server are skipped. Existing XMLs are backed up under `mpacks-upgrade-planner-backup/`.

1. Clone the Acceldata utility repository and change the directory.

```
git clone https://github.com/acceldata-io/ce-utils.git
cd ce-utils
cd ./odp-upgrade-to-3_4_3_0/upgrade_files_343/
```

2. Launch the setup script.

```
bash ./setup_mpacks_upgrade_planner.sh
```

3. Restart Ambari Server so the planner reloads the packs.

```
ambari-server restart
```

4. Create a new Express or Rolling upgrade. A plan that is already paused keeps the groups it was created with. This copy does not rewrite that plan.
