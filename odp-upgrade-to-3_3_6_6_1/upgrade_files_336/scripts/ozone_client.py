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

import sys
import os
from resource_management.libraries.script.script import Script
from resource_management.libraries.functions import stack_select
from resource_management.libraries.functions.constants import StackFeature
from resource_management.libraries.functions.stack_features import check_stack_feature
from ozone import ozone
from ambari_commons import OSCheck, OSConst
from ambari_commons.os_family_impl import OsFamilyImpl
from resource_management.core.exceptions import ClientComponentHasNoStatus
from resource_management.core.shell import as_sudo
from resource_management.libraries.functions import conf_select
from resource_management.core.resources.system import Execute
from resource_management.core.logger import Logger
from resource_management.core import sudo
import glob
import upgrade

class OzoneClient(Script):
  def install(self, env):
    import params
    env.set_params(params)
    self.install_packages(env)
    self.configure(env)

  def configure(self, env):
    import params
    env.set_params(params)
    ozone(name='ozone-client')
    self.create_30_config_version(env)

  def start(self, env, upgrade_type=None):
    import params
    env.set_params(params)

  def stop(self, env, upgrade_type=None):
    import params
    env.set_params(params)

  def status(self, env):
    raise ClientComponentHasNoStatus()

@OsFamilyImpl(os_family=OsFamilyImpl.DEFAULT)
class OzoneClientDefault(OzoneClient):
  def pre_upgrade_restart(self, env, upgrade_type=None):
    import params
    env.set_params(params)
    upgrade.prestart(env)

  def save_component_version_to_structured_out(self, command_name):
    upgrade.save_component_version_during_upgrade(self, command_name, "ozone-client")

  def create_30_config_version(self, env):
    package_name = 'ozone'
    stack_root = Script.get_stack_root()
    current_dir = "{0}/current/ozone/conf".format(stack_root)
    directories = [{"conf_dir": "/etc/ozone/conf","current_dir": current_dir}]
    stack_version = stack_select.get_stack_version_before_install(package_name)
    conf_dir = "/etc/ozone/conf"
    if stack_version:
      try:
        #Check if broken symbolic links issue exists
        os.stat(conf_dir)
        conf_select.convert_conf_directories_to_symlinks(package_name, stack_version, directories)
        cp_cmd = as_sudo(["cp","-a","-f","/etc/ozone/conf.backup/.","/etc/ozone/conf"])
        Execute(cp_cmd,logoutput = True)
      except OSError as e:
        Logger.warning("Detected broken symlink : {0}. Attempting to repair.".format(str(e)))
        #removing symlink conf directory
        sudo.unlink(conf_dir)
        #make conf dir again
        sudo.makedirs(conf_dir,0o755)
        #copy all files
        for files in glob.glob("/etc/ozone/conf.backup/*"):
          cp_cmd = as_sudo(["cp","-r",files,conf_dir])
          Execute(cp_cmd,logoutput = True)
        conf_select.convert_conf_directories_to_symlinks(package_name, stack_version, directories)


if __name__ == "__main__":
  OzoneClient().execute()
