#!/usr/bin/env ambari-python-wrap
"""
Licensed to the Apache Software Foundation (ASF) under one
or more contributor license agreements.  See the NOTICE file
distributed with this work for additional information
regarding copyright ownership.  The ASF licenses this file
to you under the Apache License, Version 2.0 (the
"License"); you may not use this file except in compliance
with the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

"""
import collections
import os

from resource_management.libraries.functions.version import format_stack_version
from resource_management.libraries.resources.properties_file import PropertiesFile
from resource_management.libraries.resources.template_config import TemplateConfig
from resource_management.core.resources.system import Directory, Execute, File, Link
from resource_management.core.source import StaticFile, Template, InlineTemplate
from resource_management.libraries.functions.default import default
from resource_management.libraries.functions import format
from resource_management.libraries.functions.generate_logfeeder_input_config import generate_logfeeder_input_config
from resource_management.libraries.functions.stack_features import check_stack_feature
from resource_management.libraries.functions import StackFeature
from resource_management.libraries.functions import Direction
from resource_management.core.exceptions import Fail
from ambari_commons.credential_store_helper import \
  create_password_in_credential_store, \
  delete_alias_from_credential_store
import re

from resource_management.core.logger import Logger


def kafka(upgrade_type=None):
    import params
    ensure_base_directories()

    kafka_server_config = mutable_config_dict(params.config['configurations']['kafka-broker'])
    kafka_connect_distributed_config = mutable_config_dict(params.config['configurations']['kafka-connect-distributed'])
    # This still has an issue of hostnames being alphabetically out-of-order for broker.id in ODP-2.2.
    # Starting in ODP 2.3, Kafka handles the generation of broker.id so Ambari doesn't have to.

    effective_version = params.stack_version_formatted if upgrade_type is None else format_stack_version(params.version)
    Logger.info(format("Effective stack version: {effective_version}"))

    # listeners and advertised.listeners are only added in 2.3.0.0 onwards.
    if effective_version is not None and effective_version != "" and \
       check_stack_feature(StackFeature.KAFKA_LISTENERS, effective_version):

       listeners = kafka_server_config['listeners'].replace("localhost", params.hostname)
       kafka_server_config['listeners'] = listeners

       if params.kerberos_security_enabled and params.kafka_kerberos_enabled:
         Logger.info("Kafka kerberos security is enabled.")

         inter_broker_protocol = kafka_server_config['security.inter.broker.protocol']
         inter_broker_protocol = replace_sasl_related_config(inter_broker_protocol, True)
         kafka_server_config['security.inter.broker.protocol'] = inter_broker_protocol

         listeners = kafka_server_config['listeners']
         listeners = replace_sasl_related_config(listeners)
         kafka_server_config['listeners'] = listeners

         if 'advertised.listeners' not in kafka_server_config:
           kafka_server_config['advertised.listeners'] = listeners
         else:
           if params.kafka_kerberos_merge_advertised_listeners:
             Logger.warning("User defined advertised.listeners will be merged with Ambari-managed advertised.listeners value. To leave value as is change kafka-env/kerberos_merge_advertised_listeners to false.")
             kafka_server_config['advertised.listeners'] = ",".join((listeners, kafka_server_config['advertised.listeners']))
       elif 'advertised.listeners' in kafka_server_config:
         advertised_listeners = kafka_server_config['advertised.listeners'].replace("localhost", params.hostname)
         kafka_server_config['advertised.listeners'] = advertised_listeners

       raw_listeners = kafka_server_config['raw.listeners'] if 'raw.listeners' in kafka_server_config else ""
       if 'raw.listeners' in kafka_server_config:
         del kafka_server_config['raw.listeners']
       if raw_listeners.strip():
         kafka_server_config['listeners'] = ",".join((kafka_server_config['listeners'], raw_listeners))
       effective_kafka_listeners = kafka_server_config['listeners']
       Logger.info("Kafka listeners: "+effective_kafka_listeners)
       if 'advertised.listeners' in kafka_server_config:
         effective_advertised_listeners = kafka_server_config['advertised.listeners']
         Logger.info("Kafka advertised listeners: "+effective_advertised_listeners)
    else:
      kafka_server_config['host.name'] = params.hostname

    if params.has_metric_collector:
      kafka_server_config['kafka.timeline.metrics.hosts'] = params.ams_collector_hosts
      kafka_server_config['kafka.timeline.metrics.port'] = params.metric_collector_port
      kafka_server_config['kafka.timeline.metrics.protocol'] = params.metric_collector_protocol
      kafka_server_config['kafka.timeline.metrics.truststore.path'] = params.metric_truststore_path
      kafka_server_config['kafka.timeline.metrics.truststore.type'] = params.metric_truststore_type
      kafka_server_config['kafka.timeline.metrics.truststore.password'] = params.metric_truststore_password

#Update the property metric.reporter in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('metric.reporters', '') != '':
            kafka_server_config['metric.reporters'] = kafka_server_config['metric.reporters']
        else:
            kafka_server_config['metric.reporters'] = "com.linkedin.kafka.cruisecontrol.metricsreporter.CruiseControlMetricsReporter"
    else:
        kafka_server_config['metric.reporters'] = ""

#Update the property cruise.control.metrics.reporter.bootstrap.servers in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.bootstrap.servers', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.bootstrap.servers'] = kafka_server_config['cruise.control.metrics.reporter.bootstrap.servers']
        else:
            kafka_server_config['cruise.control.metrics.reporter.bootstrap.servers'] = params.cc_bootstrap_servers
    else:
        kafka_server_config['cruise.control.metrics.reporter.bootstrap.servers'] = ""

#Update the property cruise.control.metrics.reporter.listeners in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.listeners', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.listeners'] = kafka_server_config['cruise.control.metrics.reporter.listeners']
        else:
            kafka_server_config['cruise.control.metrics.reporter.listeners'] = params.cc_bootstrap_servers
    else:
        kafka_server_config['cruise.control.metrics.reporter.listeners'] = ""

#Update the property cruise.control.metrics.reporter.security.protocol in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.security.protocol', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.security.protocol'] = kafka_server_config['cruise.control.metrics.reporter.security.protocol']
        else:
            kafka_server_config['cruise.control.metrics.reporter.security.protocol'] = kafka_server_config['security.inter.broker.protocol']
    else:
        kafka_server_config['cruise.control.metrics.reporter.security.protocol'] = ""

#Update the property cruise.control.metrics.reporter.security.inter.broker.protocol in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.security.inter.broker.protocol', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.security.inter.broker.protocol'] = kafka_server_config['cruise.control.metrics.reporter.security.inter.broker.protocol']
        else:
            kafka_server_config['cruise.control.metrics.reporter.security.inter.broker.protocol'] = kafka_server_config['security.inter.broker.protocol']
    else:
        kafka_server_config['cruise.control.metrics.reporter.security.inter.broker.protocol'] = ""

#Update the property cruise.control.metrics.reporter.authorizer.class.name in server.properties file,
#if cruise-control is installed and kerberos is enabled.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.authorizer.class.name', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name']
        elif params.kerberos_security_enabled and params.kafka_kerberos_enabled:
            kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = kafka_server_config['authorizer.class.name']
        else:
            kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name']
    else:
        kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = ""

#Update the property cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules in server.properties file,
#if cruise-control is installed and kerberos is enabled.
    if params.has_cruise_control:
       if kafka_server_config.get('cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules', '') != '':
           kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules'] = kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules']
       elif params.kerberos_security_enabled and params.kafka_kerberos_enabled:
           kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules'] = kafka_server_config['sasl.kerberos.principal.to.local.rules']
       else:
           kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.principal.to.local.rules']
    else:
       kafka_server_config['cruise.control.metrics.reporter.authorizer.class.name'] = ""

#Update the property cruise.control.metrics.reporter.sasl.kerberos.service.name in server.properties file,
#if cruise-control is installed and kerberos is enabled.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.sasl.kerberos.service.name', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name'] = kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name']
        elif params.kerberos_security_enabled and params.kafka_kerberos_enabled:
            kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name'] = "kafka"
        else:
            kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name'] = kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name']
    else:
        kafka_server_config['cruise.control.metrics.reporter.sasl.kerberos.service.name'] = ""

#Update the property cruise.control.metrics.reporter.ssl.client.auth in server.properties file,
#if cruise-control is installed.
    if params.has_cruise_control:
        if kafka_server_config.get('cruise.control.metrics.reporter.ssl.client.auth', '') != '':
            kafka_server_config['cruise.control.metrics.reporter.ssl.client.auth'] = kafka_server_config['cruise.control.metrics.reporter.ssl.client.auth']
        else:
            kafka_server_config['cruise.control.metrics.reporter.ssl.client.auth'] = kafka_server_config['ssl.client.auth']
    else:
        kafka_server_config['cruise.control.metrics.reporter.ssl.client.auth'] = ""

    ##### Handle SSL-related properties:
    ssl_credentials = {
        'ssl.key.password': 'ssl.key.password',
        'ssl.keystore.password': 'ssl.keystore.password',
        'ssl.truststore.password': 'ssl.truststore.password',
        'cruise.control.metrics.reporter.ssl.keystore.password': 'cruise.control.metrics.reporter.ssl.keystore.password',
        'cruise.control.metrics.reporter.ssl.truststore.password': 'cruise.control.metrics.reporter.ssl.truststore.password'
    }

    for config_key, jceks_alias in ssl_credentials.items():
      password_value = kafka_server_config.get(config_key)

      # Proceed only if the password is non-empty and not just whitespace
      if password_value and password_value.strip():
        cs_lib_path = '/var/lib/ambari-agent/cred/lib/*'
        java_home = params.config['ambariLevelParams']['java_home']
        jdk_location = params.config['ambariLevelParams']['jdk_location']

        # Delete existing credential
        try:
          delete_alias_from_credential_store(jceks_alias,
                                             params.kafka_credential_path_file,
                                             cs_lib_path,
                                             java_home,
                                             jdk_location)
        except Exception as e:
          if "does not exist in" not in str(e):
            raise e

        # Save new credential
        create_password_in_credential_store(jceks_alias,
                                            params.kafka_credential_path_file,
                                            cs_lib_path,
                                            java_home,
                                            jdk_location,
                                            password_value)
        Execute(
            ("chown", params.kafka_user, params.kafka_credential_path_file.replace("jceks://file", "")),
            sudo=True
        )

        # Replace in config with env reference
        env_var_name = config_key.upper().replace('.', '_')
        kafka_server_config[config_key] = "${{env:{}}}".format(env_var_name)
        # Add these in server.prop in order to use env variables at run time.
        kafka_server_config['config.providers'] = "env"
        kafka_server_config['config.providers.env.class'] = "org.apache.kafka.common.config.provider.EnvVarConfigProvider"

      # Remove sensitive data from memory
      del password_value

    kafka_data_dir = kafka_server_config['log.dirs']
    kafka_data_dirs = [_f for _f in kafka_data_dir.split(",") if _f]

    rack="/default-rack"
    i=0
    if len(params.all_racks) > 0:
     for host in params.all_hosts:
      if host == params.hostname:
        rack=params.all_racks[i]
        break
      i=i+1

    Directory(kafka_data_dirs,
              mode=0o755,
              cd_access='a',
              owner=params.kafka_user,
              group=params.user_group,
              create_parents = True,
              recursive_ownership = True,
    )

    PropertiesFile("server.properties",
                      mode=0o640,
                      dir=params.conf_dir,
                      properties=kafka_server_config,
                      owner=params.kafka_user,
                      group=params.user_group,
    )
    PropertiesFile("kafka-connect-distributed.properties",
                   mode=0o640,
                   dir=params.conf_dir,
                   properties=kafka_connect_distributed_config,
                   owner=params.kafka_user,
                   group=params.user_group,
    )

    env_exports = ""
    for alias in params.mirror_maker_password_props:
        if params.mirror_maker_password_props[alias] and params.mirror_maker_password_props[alias].strip():
            # Use Ambari's Java home for CredentialUtil (compiled with JDK17+)
            env_exports += (
                'export {{alias}}=`{ambari_java_home}/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "{{path}}" get "{{alias}}"`\n'
            ).format(ambari_java_home=params.ambari_java_home).format(alias=alias, path=params.kafka_mirrormaker_credential_path)

    params.kafka_env_sh_template += "\n" + env_exports

    File(format("{conf_dir}/kafka-env.sh"),
          owner=params.kafka_user,
          content=InlineTemplate(params.kafka_env_sh_template)
     )

    if (params.log4j_props != None):
        File(format("{conf_dir}/log4j.properties"),
             mode=0o644,
             group=params.user_group,
             owner=params.kafka_user,
             content=InlineTemplate(params.log4j_props)
         )

    if (params.kerberos_security_enabled and params.kafka_kerberos_enabled) or params.kafka_other_sasl_enabled:
      if params.kafka_jaas_conf_template:
        File(format("{conf_dir}/kafka_jaas.conf"),
             owner=params.kafka_user,
             content=InlineTemplate(params.kafka_jaas_conf_template)
        )
      else:
        TemplateConfig(format("{conf_dir}/kafka_jaas.conf"),
                         owner=params.kafka_user)

      if params.kafka_client_jaas_conf_template:
        File(format("{conf_dir}/kafka_client_jaas.conf"),
             owner=params.kafka_user,
             content=InlineTemplate(params.kafka_client_jaas_conf_template)
        )
      else:
        TemplateConfig(format("{conf_dir}/kafka_client_jaas.conf"),
                       owner=params.kafka_user)

    # On some OS this folder could be not exists, so we will create it before pushing there files
    Directory(params.limits_conf_dir,
              create_parents = True,
              owner='root',
              group='root'
    )

    File(os.path.join(params.limits_conf_dir, 'kafka.conf'),
         owner='root',
         group='root',
         mode=0o644,
         content=Template("kafka.conf.j2")
    )

    File(os.path.join(params.conf_dir, 'tools-log4j.properties'),
         owner='root',
         group='root',
         mode=0o644,
         content=Template("tools-log4j.properties.j2")
         )

    generate_logfeeder_input_config('kafka', Template("input.config-kafka.json.j2", extra_imports=[default]))

    setup_symlink(params.kafka_managed_pid_dir, params.kafka_pid_dir)
    setup_symlink(params.kafka_managed_log_dir, params.kafka_log_dir)


def replace_sasl_related_config(property, only_protocol=False):
  property = re.sub(r"(^|\b)PLAINTEXTSASL", "SASL_PLAINTEXT", property) if only_protocol else re.sub(r"(^|\b)PLAINTEXTSASL://", "SASL_PLAINTEXT://", property)
  property = re.sub(r"(^|\b)PLAINTEXT", "SASL_PLAINTEXT", property) if only_protocol else re.sub(r"(^|\b)PLAINTEXT://", "SASL_PLAINTEXT://", property)
  property = re.sub(r"(^|\b)SSL", "SASL_SSL", property) if only_protocol else re.sub(r"(^|\b)SSL://", "SASL_SSL://", property)
  return property


def mutable_config_dict(kafka_broker_config):
    kafka_server_config = {}
    for key, value in kafka_broker_config.items():
        kafka_server_config[key] = value
    return kafka_server_config


# Used to workaround the hardcoded pid/log dir used on the kafka bash process launcher
def setup_symlink(kafka_managed_dir, kafka_ambari_managed_dir):
  import params
  backup_folder_path = None
  backup_folder_suffix = "_tmp"
  if kafka_ambari_managed_dir != kafka_managed_dir:
    if os.path.exists(kafka_managed_dir) and not os.path.islink(kafka_managed_dir):

      # Backup existing data before delete if config is changed repeatedly to/from default location at any point in time time, as there may be relevant contents (historic logs)
      backup_folder_path = backup_dir_contents(kafka_managed_dir, backup_folder_suffix)

      Directory(kafka_managed_dir,
                action="delete",
                create_parents = True)

    elif os.path.islink(kafka_managed_dir) and os.path.realpath(kafka_managed_dir) != kafka_ambari_managed_dir:
      Link(kafka_managed_dir,
           action="delete")

    if not os.path.islink(kafka_managed_dir):
      Link(kafka_managed_dir,
           to=kafka_ambari_managed_dir)

  elif os.path.islink(kafka_managed_dir): # If config is changed and coincides with the kafka managed dir, remove the symlink and physically create the folder
    Link(kafka_managed_dir,
         action="delete")

    Directory(kafka_managed_dir,
              mode=0o755,
              cd_access='a',
              owner=params.kafka_user,
              group=params.user_group,
              create_parents = True,
              recursive_ownership = True,
    )

  if backup_folder_path:
    # Restore backed up files to current relevant dirs if needed - will be triggered only when changing to/from default path;
    for file in os.listdir(backup_folder_path):
      if os.path.isdir(os.path.join(backup_folder_path, file)):
        Execute(('cp', '-r', os.path.join(backup_folder_path, file), kafka_managed_dir),
                sudo=True)
        Execute(("chown", "-R", format("{kafka_user}:{user_group}"), os.path.join(kafka_managed_dir, file)),
                sudo=True)
      else:
        File(os.path.join(kafka_managed_dir,file),
             owner=params.kafka_user,
             content = StaticFile(os.path.join(backup_folder_path,file)))

    # Clean up backed up folder
    Directory(backup_folder_path,
              action="delete",
              create_parents = True)


# Uses agent temp dir to store backup files
def backup_dir_contents(dir_path, backup_folder_suffix):
  import params
  backup_destination_path = params.tmp_dir + os.path.normpath(dir_path)+backup_folder_suffix
  Directory(backup_destination_path,
            mode=0o755,
            cd_access='a',
            owner=params.kafka_user,
            group=params.user_group,
            create_parents = True,
            recursive_ownership = True,
  )
  # Safely copy top-level contents to backup folder
  for file in os.listdir(dir_path):
    if os.path.isdir(os.path.join(dir_path, file)):
      Execute(('cp', '-r', os.path.join(dir_path, file), backup_destination_path),
              sudo=True)
      Execute(("chown", "-R", format("{kafka_user}:{user_group}"), os.path.join(backup_destination_path, file)),
              sudo=True)
    else:
      File(os.path.join(backup_destination_path, file),
         owner=params.kafka_user,
         content = StaticFile(os.path.join(dir_path,file)))

  return backup_destination_path

def ensure_base_directories():
  import params
  Directory([params.kafka_log_dir, params.kafka_pid_dir, params.conf_dir],
            mode=0o755,
            cd_access='a',
            owner=params.kafka_user,
            group=params.user_group,
            create_parents = True,
            recursive_ownership = True,
            )