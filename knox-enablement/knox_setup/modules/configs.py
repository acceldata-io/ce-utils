#!/usr/bin/env ambari-python-wrap

'''
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
'''

from collections import OrderedDict
from typing import Optional

import argparse
import base64
import json
import logging
import os
import ssl
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

logger = logging.getLogger('AmbariConfig')

HTTP_PROTOCOL = 'http'
HTTPS_PROTOCOL = 'https'

SET_ACTION = 'set'
GET_ACTION = 'get'
DELETE_ACTION = 'delete'

GET_REQUEST_TYPE = 'GET'
PUT_REQUEST_TYPE = 'PUT'

# JSON Keywords
PROPERTIES = 'properties'
ATTRIBUTES = 'properties_attributes'
CLUSTERS = 'Clusters'
DESIRED_CONFIGS = 'desired_configs'
SERVICE_CONFIG_NOTE = 'service_config_version_note'
TYPE = 'type'
TAG = 'tag'
ITEMS = 'items'
TAG_PREFIX = 'version'

CLUSTERS_URL = '/api/v1/clusters/{0}'
DESIRED_CONFIGS_URL = CLUSTERS_URL + '?fields=Clusters/desired_configs'
CONFIGURATION_URL = CLUSTERS_URL + '/configurations?type={1}&tag={2}'

FILE_FORMAT = \
"""
"properties": {
  "key1": "value1"
  "key2": "value2"
},
"properties_attributes": {
  "attribute": {
    "key1": "value1"
    "key2": "value2"
  }
}
"""

class UsageException(Exception):
  pass


def api_accessor(host, login, password, protocol, port, unsafe=None):
    def do_request(api_url, request_type=GET_REQUEST_TYPE, request_body=None):
        try:
            url = '{0}://{1}:{2}{3}'.format(protocol, host, port, api_url)
            admin_auth = base64.encodebytes(('%s:%s' % (login, password)).encode()).decode().replace('\n', '')
            request = urllib.request.Request(url)
            request.add_header('Authorization', 'Basic %s' % admin_auth)
            request.add_header('X-Requested-By', 'ambari')
            request.data=request_body
            request.get_method = lambda: request_type
            if unsafe:
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                response = urllib.request.urlopen(request, context=ctx)
            else:
                response = urllib.request.urlopen(request)
            response_body = response.read()
            response_body = response_body.decode('utf-8') if isinstance(response_body, bytes) else response_body
        except Exception as exc:
            raise Exception('Problem with accessing api. Reason: {0}'.format(exc))
        return response_body
    return do_request


def get_config_tag(cluster, config_type, accessor):
    response = accessor(DESIRED_CONFIGS_URL.format(cluster))
    try:
        desired_tags = json.loads(response)
        current_config_tag = desired_tags[CLUSTERS][DESIRED_CONFIGS][config_type][TAG]
    except Exception:
        raise Exception('"{0}" not found in server response. Response:\n{1}'.format(config_type, response))
    return current_config_tag


def create_new_desired_config(cluster, config_type, properties, attributes, accessor, version_note):
    new_tag = TAG_PREFIX + str(int(time.time() * 1000000))
    new_config = {
        CLUSTERS: {
        DESIRED_CONFIGS: {
            TYPE: config_type,
            TAG: new_tag,
            SERVICE_CONFIG_NOTE:version_note,
            PROPERTIES: properties
        }
        }
    }
    if len(attributes.keys()) > 0:
        new_config[CLUSTERS][DESIRED_CONFIGS][ATTRIBUTES] = attributes
    request_body = json.dumps(new_config)
    request_body = request_body.encode('utf-8') if isinstance(request_body, str) else request_body
    new_file = 'doSet_{0}.json'.format(new_tag)
    logger.info('### PUTting json into: {0}'.format(new_file))
    output_to_file(new_file)(new_config)
    accessor(CLUSTERS_URL.format(cluster), PUT_REQUEST_TYPE, request_body)
    logger.info('### NEW Site:{0}, Tag:{1}'.format(config_type, new_tag))


def get_current_config(cluster, config_type, accessor):
    config_tag = get_config_tag(cluster, config_type, accessor)
    logger.info("### on (Site:{0}, Tag:{1})".format(config_type, config_tag))
    response = accessor(CONFIGURATION_URL.format(cluster, config_type, config_tag))
    config_by_tag = json.loads(response, object_pairs_hook=OrderedDict)
    current_config = config_by_tag[ITEMS][0]
    return current_config[PROPERTIES], current_config.get(ATTRIBUTES, {})


def update_config(cluster, config_type, config_updater, accessor, version_note):
    properties, attributes = config_updater(cluster, config_type, accessor)
    create_new_desired_config(cluster, config_type, properties, attributes, accessor, version_note)


def update_specific_property(config_name, config_value):
    def update(cluster, config_type, accessor):
        properties, attributes = get_current_config(cluster, config_type, accessor)
        properties[config_name] = config_value
        return properties, attributes
    return update


def update_from_xml(config_file):
    def update(cluster, config_type, accessor):
        return read_xml_data_to_map(config_file)
    return update


# Used DOM parser to read data into a map
def read_xml_data_to_map(path):
    configurations = {}
    properties_attributes = {}
    tree = ET.parse(path)
    root = tree.getroot()
    for properties in root.iter('property'):
        name = properties.find('name')
        value = properties.find('value')
        final = properties.find('final')
        if name is not None:
            name_text = name.text if name.text else ""
        else:
            logger.warning("No name is found for one of the properties in {0}, ignoring it".format(path))
            continue
        if value is not None:
            value_text = value.text if value.text else ""
        else:
            logger.warning("No value is found for \"{0}\" in {1}, using empty string for it".format(name_text, path))
            value_text = ""
        if final is not None:
            final_text = final.text if final.text else ""
            properties_attributes[name_text] = final_text
            configurations[name_text] = value_text

    return configurations, {"final" : properties_attributes}


def update_from_file(config_file):
  def update(cluster, config_type, accessor):
    try:
      with open(config_file) as in_file:
        file_content = in_file.read()
    except Exception:
      raise Exception('Cannot find file "{0}" to PUT'.format(config_file))
    try:
      file_properties = json.loads(file_content)
    except Exception:
      raise Exception('File "{0}" should be in the following JSON format ("properties_attributes" is optional):\n{1}'.format(config_file, FILE_FORMAT))
    new_properties = file_properties.get(PROPERTIES, {})
    new_attributes = file_properties.get(ATTRIBUTES, {})
    logger.info('### PUTting file: "{0}"'.format(config_file))
    return new_properties, new_attributes
  return update


def delete_specific_property(config_name):
    def update(cluster, config_type, accessor):
        properties, attributes = get_current_config(cluster, config_type, accessor)
        properties.pop(config_name, None)
        for attribute_values in attributes.values():
            attribute_values.pop(config_name, None)
        return properties, attributes
    return update


def output_to_file(filename):
    def output(config):
        with open(filename, 'w') as out_file:
            json.dump(config, out_file, indent=2)
    return output


def output_to_console(config):
    print(json.dumps(config, indent=2))


def get_config(cluster: str, config_type: str, accessor, output):
    properties, attributes = get_current_config(cluster, config_type, accessor)
    config = {PROPERTIES: properties}
    if len(attributes.keys()) > 0:
        config[ATTRIBUTES] = attributes
    output(config)


def set_properties(cluster: str, config_type: str, args, accessor, version_note):
    logger.info('### Performing "set":')
    if len(args) == 1:
        config_file = args[0]
        _, ext = os.path.splitext(config_file)
        if ext == ".xml":
            updater = update_from_xml(config_file)
        elif ext == ".json":
            updater = update_from_file(config_file)
        else:
            logger.error("File extension {0} is not supported".format(ext))
            return -1
        logger.info('### from file {0}'.format(config_file))
    else:
        config_name = args[0]
        config_value = args[1]
        updater = update_specific_property(config_name, config_value)
        logger.info('### new property - "{0}":"{1}"'.format(config_name, config_value))
    update_config(cluster, config_type, updater, accessor, version_note)
    return 0


def delete_properties(cluster: str, config_type: str, args, accessor, version_note):
    logger.info('### Performing "delete":')
    if len(args) == 0:
        logger.error("Not enough arguments. Expected config key.")
        return -1
    config_name = args[0]
    logger.info('### on property "{0}"'.format(config_name))
    update_config(cluster, config_type, delete_specific_property(config_name), accessor, version_note)
    return 0


def get_properties(cluster: str, config_type: str, args, accessor):
    logger.info("### Performing \"get\" content:")
    if len(args) > 0:
        filename = args[0]
        output = output_to_file(filename)
        logger.info('### to file "{0}"'.format(filename))
    else:
        output = output_to_console
    get_config(cluster, config_type, accessor, output)
    return 0


# ============================================================================
# AmbariConfigs Wrapper Class for use in steps
# ============================================================================

class AmbariConfigs:
    """
    Wrapper class for Ambari configuration management.

    Usage:
        configs = AmbariConfigs(host, user, password, cluster)

        # Get a property
        value = configs.get_property("core-site", "hadoop.proxyuser.knox.hosts")

        # Set a property
        configs.set_property("core-site", "hadoop.proxyuser.knox.hosts", "*")

        # Get all properties for a config type
        props = configs.get_config("core-site")
    """

    def __init__(
        self,
        host: str,
        user: str,
        password: str,
        cluster: str,
        protocol: str = "http",
        port: int = 8080,
        unsafe: bool = True,
    ):
        self.host = host
        self.user = user
        self.password = password
        self.cluster = cluster
        self.protocol = protocol
        self.port = port
        self.unsafe = unsafe
        self.accessor = api_accessor(host, user, password, protocol, port, unsafe)

    def get_config(self, config_type: str) -> dict:
        """Get all properties for a configuration type."""
        properties, _ = get_current_config(self.cluster, config_type, self.accessor)
        return dict(properties)

    def get_config_with_attributes(self, config_type: str) -> tuple:
        """Get properties and attributes for a configuration type."""
        return get_current_config(self.cluster, config_type, self.accessor)

    def get_property(self, config_type: str, key: str, default=None):
        """Get a specific property value."""
        properties = self.get_config(config_type)
        return properties.get(key, default)

    def set_property(self, config_type: str, key: str, value: str, version_note: Optional[str] = None):
        """Set a specific property value."""
        note = version_note or f"Set {key}={value}"
        print(f"[Config] Setting {config_type}/{key} = {value}")
        updater = update_specific_property(key, value)
        update_config(self.cluster, config_type, updater, self.accessor, note)

    def set_properties(self, config_type: str, properties: dict, version_note: Optional[str] = None):
        """Set multiple properties at once."""
        note = version_note or f"Set {len(properties)} properties"
        print(f"[Config] Setting {len(properties)} properties in {config_type}")

        def updater(cluster, cfg_type, accessor):
            current_props, attributes = get_current_config(cluster, cfg_type, accessor)
            current_props.update(properties)
            return current_props, attributes

        update_config(self.cluster, config_type, updater, self.accessor, note)

    def delete_property(self, config_type: str, key: str, version_note: Optional[str] = None):
        """Delete a property."""
        note = version_note or f"Delete {key}"
        print(f"[Config] Deleting {config_type}/{key}")
        updater = delete_specific_property(key)
        update_config(self.cluster, config_type, updater, self.accessor, note)


# ============================================================================
# CLI Main
# ============================================================================

def main():
    parser = argparse.ArgumentParser(usage="%(prog)s [options]")
    login_options_group = parser.add_argument_group("To specify credentials please use \"-e\" OR \"-u\" and \"-p\"")
    login_options_group.add_argument("-u", "--user", dest="user", default="admin", help="Optional user ID to use for authentication. Default is 'admin'")
    login_options_group.add_argument("-p", "--password", dest="password", default="admin", help="Optional password to use for authentication. Default is 'admin'")
    login_options_group.add_argument("-e", "--credentials-file", dest="credentials_file", help="Optional file with user credentials separated by new line.")
    parser.add_argument("-t", "--port", dest="port", default="8080", help="Optional port number for Ambari server. Default is '8080'. Provide empty string to not use port.")
    parser.add_argument("-s", "--protocol", dest="protocol", default="http", choices=["http", "https"], help="Optional support of SSL. Default protocol is 'http'")
    parser.add_argument("--unsafe", action="store_true", dest="unsafe", help="Skip SSL certificate verification.")
    parser.add_argument("-a", "--action", dest="action", required=True, choices=[GET_ACTION, SET_ACTION, DELETE_ACTION], help="Script action: <get>, <set>, <delete>")
    parser.add_argument("-l", "--host", dest="host", required=True, help="Server external host name")
    parser.add_argument("-n", "--cluster", dest="cluster", required=True, help="Name given to cluster. Ex: 'c1'")
    parser.add_argument("-c", "--config-type", dest="config_type", required=True, help="One of the various configuration types in Ambari. Ex: core-site, hdfs-site, mapred-queue-acls, etc.")
    parser.add_argument("-b", "--version-note", dest="version_note", default="", help="Version change notes which will help to know what has been changed in this config. This value is optional and is used for actions <set> and <delete>.")
    config_options_group = parser.add_argument_group("To specify property(s) please use \"-f\" OR \"-k\" and \"-v\"")
    config_file_or_key = config_options_group.add_mutually_exclusive_group()
    config_file_or_key.add_argument("-f", "--file", dest="file", help="File where entire configurations are saved to, or read from. Supported extensions (.xml, .json>)")
    config_file_or_key.add_argument("-k", "--key", dest="key", help="Key that has to be set or deleted. Not necessary for 'get' action.")
    config_options_group.add_argument("-v", "--value", dest="value", help="Optional value to be set. Not necessary for 'get' or 'delete' actions.")
    options = parser.parse_args()

    logger.setLevel(logging.INFO)
    formatter = logging.Formatter('%(asctime)s %(levelname)s %(message)s')
    stdout_handler = logging.StreamHandler(sys.stdout)
    stdout_handler.setLevel(logging.INFO)
    stdout_handler.setFormatter(formatter)
    logger.addHandler(stdout_handler)
    # options with default value
    if not options.credentials_file and (not options.user or not options.password):
        parser.error("You should use option (-e) to set file with Ambari user credentials OR use (-u) username and (-p) password")
    if options.credentials_file:
        if os.path.isfile(options.credentials_file):
            try:
                with open(options.credentials_file) as credentials_file:
                    file_content = credentials_file.read()
                    login_lines = [_f for _f in file_content.splitlines() if _f]
                    if len(login_lines) == 2:
                        user = login_lines[0]
                        password = login_lines[1]
                    else:
                        logger.error("Incorrect content of {0} file. File should contain Ambari username and password separated by new line.".format(options.credentials_file))
                        sys.exit(1)
            except Exception:
                logger.error("You don't have permissions to {0} file".format(options.credentials_file))
                sys.exit(1)
        else:
            logger.error("File {0} doesn't exist or you don't have permissions.".format(options.credentials_file))
            sys.exit(1)
    else:
        user = options.user
        password = options.password
    port = options.port
    protocol = options.protocol

    action = options.action
    host = options.host
    cluster = options.cluster
    config_type = options.config_type
    version_note = options.version_note
    accessor = api_accessor(host, user, password, protocol, port, options.unsafe)
    if action == SET_ACTION:
        if not options.file and (not options.key or options.value is None):
            parser.error("You should use option (-f) to set file where entire configurations are saved OR (-k) key and (-v) value for one property")
        if options.file:
            action_args = [options.file]
        else:
            action_args = [options.key, options.value]
        return set_properties(cluster, config_type, action_args, accessor, version_note)
    elif action == GET_ACTION:
        if options.file:
            action_args = [options.file]
        else:
            action_args = []
        return get_properties(cluster, config_type, action_args, accessor)
    elif action == DELETE_ACTION:
        if not options.key:
            parser.error("You should use option (-k) to set the property name to be deleted")
        else:
            action_args = [options.key]
        return delete_properties(cluster, config_type, action_args, accessor, version_note)

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nAborting ... Keyboard Interrupt.")
        sys.exit(1)
