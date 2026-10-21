#!/usr/bin/env python
# -*- coding: utf-8 -*-
##########################################################################
# Acceldata Inc. | ODP
#
# This script enables SSL for various Hadoop-related services using an existing Java KeyStore (JKS).
# Python 2.7 and Python 3 compatible. Each menu selection is pushed to Ambari with one request per service it touches (Ambari rejects a request that spans services),
# with a config version note on every changed config type.
#
# Usage:
#   python setup_ssl_with_existing_jks.py
#   Override connection settings with env vars: AMBARI_HOST, AMBARI_PORT, AMBARI_USER,
#   AMBARI_PASSWORD, PROTOCOL, CHECK_FILES. DRY_RUN=true lists what would change, sends nothing.
#
# Supported Services: HDFS/YARN/MapReduce, Infra-Solr, Hive, Ranger, Spark2, Kafka, HBase, Spark3, Oozie, Ranger KMS, Ozone, NiFi, Schema Registry, Livy2, Kafka3, Livy3, NiFi Registry, Trino, Zeppelin, Solr, Atlas, Trino Gateway
##########################################################################
from __future__ import print_function

import base64
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
from collections import OrderedDict

try:  # Python 3
    from urllib.error import HTTPError, URLError
    from urllib.request import Request, urlopen
    read_input = input
except ImportError:  # Python 2
    from urllib2 import HTTPError, Request, URLError, urlopen
    read_input = raw_input

GREEN, YELLOW, RED, CYAN, NC = "\033[32m", "\033[33m", "\033[31m", "\033[36m", "\033[0m"

#---------------------------------------------------------
# Default Values (Edit these if required)
#---------------------------------------------------------
AMBARI_HOST = os.environ.get("AMBARI_HOST", socket.getfqdn())
AMBARI_PORT = os.environ.get("AMBARI_PORT", "8080")
AMBARI_USER = os.environ.get("AMBARI_USER", "admin")
AMBARI_PASSWORD = os.environ.get("AMBARI_PASSWORD", "admin")
PROTOCOL = os.environ.get("PROTOCOL", "http").lower()  # Change to "https" if Ambari Server is configured with SSL
CHECK_FILES = os.environ.get("CHECK_FILES", "true").lower() == "true"
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"

# Keystore and Truststore details (JKS format)
KEYSTORE_PASSWORD = "changeit"      # Replace with actual keystore password
TRUSTSTORE_PASSWORD = "changeit"  # Replace with actual truststore password
KEYSTORE = "/opt/security/pki/keystore.jks"
TRUSTSTORE = "/opt/security/pki/truststore.jks"

# Ranger plugin certificate CN enforcement.
#   "disabled"  -> (default) do not set common.name.for.certificate anywhere.
#   "wildcard"  -> set common.name.for.certificate=<RANGER_CERT_CN> on ALL ranger-<service>-plugin-properties.
RANGER_PLUGIN_CN_MODE = "disabled"
# Owner CN of the keystore cert. Used only in "wildcard" mode; prompted at runtime if empty.
RANGER_CERT_CN = ""

# Atlas reads keystore/truststore passwords from a JCEKS credential provider, created manually on the Atlas node.
ATLAS_JCEKS_LOCAL = "/etc/atlas/conf/atlas.jceks"
ATLAS_JCEKS_URI = "jceks://file" + ATLAS_JCEKS_LOCAL

# Set on first write: a private temp file, not a fixed name in /tmp.
CERT_PATH = None
LOG_FILE = "/tmp/setup_ssl.log"

RANGER_PLUGINS = ["hdfs", "yarn", "hive", "kms", "hbase", "kafka", "knox", "nifi", "nifi-registry",
                "kudu", "ozone", "schema-registry", "kafka3", "trino", "atlas", "solr"]

# (plugin, key used in ranger.plugin.<key>.policy.rest.url). ozone and kafka3 use the "kudu" key,
# as in the original bash script. Looks like a copy-paste bug; verify before relying on it.
RANGER_POLICY_URL_KEYS = [
    ("knox", "knox"), ("kms", "kms"), ("hbase", "hbase"), ("yarn", "yarn"), ("hdfs", "hdfs"),
    ("kafka", "kafka"), ("hive", "hive"), ("nifi", "nifi"), ("nifi-registry", "nifi-registry"),
    ("kudu", "kudu"), ("ozone", "kudu"), ("kafka3", "kudu"), ("schema-registry", "schema-registry"),
    ("trino", "trino"),
]

# Filled in by main() / set by the run.
CLUSTER = ""
HOSTS = {}
SSL_CONTEXT = None
ATLAS_SELECTED = False
APPLIED = []  # services Ambari accepted this run
FAILED = []   # services Ambari rejected this run


#---------------------------------------------------------
# Output helpers
#---------------------------------------------------------
def say(color, msg):
    print(color + msg + NC)


def die(msg):
    say(RED, msg)
    sys.exit(1)


def log_failure(msg):
    say(RED, msg)
    with open(LOG_FILE, "a") as log:
        log.write(msg + "\n")


#---------------------------------------------------------
# Ambari REST client (stdlib only, no configs.py dependency)
#---------------------------------------------------------
def api(method, path, body=None):
    url = "%s://%s:%s/api/v1%s" % (PROTOCOL, AMBARI_HOST, AMBARI_PORT, path)
    req = Request(url, data=json.dumps(body).encode("utf-8") if body is not None else None)
    req.get_method = lambda: method
    req.add_header("X-Requested-By", "ambari")
    req.add_header("Authorization", "Basic " + base64.b64encode(
        ("%s:%s" % (AMBARI_USER, AMBARI_PASSWORD)).encode("utf-8")).decode("ascii"))
    if body is not None:
        req.add_header("Content-Type", "application/json")
    kwargs = {"timeout": 30}
    if SSL_CONTEXT is not None:
        kwargs["context"] = SSL_CONTEXT
    return json.loads(urlopen(req, **kwargs).read().decode("utf-8"))


class MissingHost(Exception):
    """A service's host role is not on any host in the cluster, so its URLs cannot be built."""


def host(component):
    if not HOSTS.get(component):
        raise MissingHost(component)
    return HOSTS[component]


def is_cert_error(err):
    return "CERTIFICATE_VERIFY_FAILED" in str(err)


def fetch_chain():
    """Full certificate chain served by Ambari (leaf + intermediates + root), as PEM text."""
    try:
        proc = subprocess.Popen(["openssl", "s_client", "-showcerts", "-connect", "%s:%s" % (AMBARI_HOST, AMBARI_PORT)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out = proc.communicate(b"")[0].decode("utf-8", "replace")
    except OSError:
        return ""
    blocks = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", out, re.S)
    return "".join(block + "\n" for block in blocks)


def write_chain(chain):
    """Write the chain to a private temp file (once per run) and return its path."""
    global CERT_PATH
    if CERT_PATH is None:
        fd, CERT_PATH = tempfile.mkstemp(suffix=".crt")
        os.close(fd)
    with open(CERT_PATH, "w") as f:
        f.write(chain)
    return CERT_PATH


def prepare_https():
    """Trust the Ambari chain for this run only; the API calls then verify against it."""
    global SSL_CONTEXT
    chain = fetch_chain()
    if "BEGIN CERTIFICATE" not in chain:
        handle_ssl_failure("Could not obtain Ambari SSL certificate")
    path = write_chain(chain)
    if not hasattr(ssl, "create_default_context"):
        die("[ERROR] HTTPS needs Python 2.7.9+ or Python 3. Use PROTOCOL=http or run with a newer Python.")
    SSL_CONTEXT = ssl.create_default_context(cafile=path)


def handle_ssl_failure(err_msg):
    """Explain an SSL trust failure and offer to install Ambari's CA. Always exits."""
    chain = fetch_chain()
    cert_count = chain.count("BEGIN CERTIFICATE")

    print("")
    say(RED, "[ERROR] SSL certificate verification failed.")
    say(RED, "Exception: %s" % err_msg)
    print("")
    say(CYAN, "Detailed Explanation:")
    print("The SSL handshake failed because the Ambari server's certificate is not in your local trust store.")
    print("This prevents secure HTTPS communication.\n")

    if cert_count <= 1:
        say(CYAN, "Additional Note:")
        print("The Ambari server's SSL configuration only includes its own certificate without intermediate or root CA.")
        print("You will need to reconstruct your server.pem file to include the full chain:")
        print("  1. Append any Intermediate CA (if present) and the Root CA to your existing server.pem.")
        print("  2. Run: ambari-server setup-security")
        print("     • Choose to disable HTTPS.")
        print("     • Supply the updated server.pem.")
        print("     • Re-enable HTTPS so that Ambari serves the complete certificate chain.\n")
        sys.exit(1)

    say(CYAN, "Additional Note:")
    print("The Ambari server is serving a certificate chain (found %d certificates), but it may not be trusted locally.\n"
        % cert_count)
    say(CYAN, "If you answer 'yes', this script will:")
    print("  • Extract the Ambari CA certificates to a temporary file")
    print("  • Copy the certificate bundle to /etc/pki/ca-trust/source/anchors/")
    print("  • Run 'update-ca-trust extract' to add them to your system trust store\n")
    choice = read_input("Do you want to extract and install the Ambari CA certificate now? (yes/no): ")
    if choice.strip().lower() != "yes":
        say(YELLOW, "Aborting certificate installation. Please add the CA manually if needed.")
        sys.exit(1)

    path = write_chain(chain)
    try:
        shutil.copy(path, "/etc/pki/ca-trust/source/anchors/")
        subprocess.check_call(["update-ca-trust", "extract"])
    except (IOError, OSError, subprocess.CalledProcessError) as e:
        die("[ERROR] Could not install the CA bundle (%s). Install the 'ca-certificates' package and rerun." % e)
    say(YELLOW, "Please rerun this script now that the CA is trusted.")
    sys.exit(1)


# str() keeps values native: on Python 2, json gives unicode, and mixing that with the emoji byte strings fails.
def get_cluster():
    items = api("GET", "/clusters")["items"]
    return str(items[0]["Clusters"]["cluster_name"]) if items else ""


def get_host_for_component(component):
    items = api("GET", "/clusters/%s/host_components?HostRoles/component_name=%s" % (CLUSTER, component))["items"]
    return str(items[0]["HostRoles"]["host_name"]) if items else ""


#---------------------------------------------------------
# Config building: rows of (config type, key, value) -> {type: {key: value}}
#---------------------------------------------------------
def build(rows):
    changes = OrderedDict()
    for config_type, key, value in rows:
        changes.setdefault(config_type, OrderedDict())[key] = value
    return changes


def merge(into, other):
    for config_type, props in other.items():
        into.setdefault(config_type, OrderedDict()).update(props)


def policymgr_ssl_rows(config_type):
    return [
        (config_type, "xasecure.policymgr.clientssl.keystore", KEYSTORE),
        (config_type, "xasecure.policymgr.clientssl.keystore.password", KEYSTORE_PASSWORD),
        (config_type, "xasecure.policymgr.clientssl.truststore", TRUSTSTORE),
        (config_type, "xasecure.policymgr.clientssl.truststore.password", TRUSTSTORE_PASSWORD),
    ]


def ranger_plugin_cn_rows():
    """Rows for common.name.for.certificate. Empty unless RANGER_PLUGIN_CN_MODE is "wildcard"."""
    if RANGER_PLUGIN_CN_MODE.lower() != "wildcard":
        return []
    cn = RANGER_CERT_CN
    if not cn:
        say(YELLOW, "RANGER_PLUGIN_CN_MODE=wildcard: common.name.for.certificate will be set on all Ranger plugins.")
        say(CYAN, "Find the certificate Common Name (Owner CN) with:")
        say(GREEN, "  keytool -list -v -keystore \"%s\" | grep -i 'Owner:'" % KEYSTORE)
        cn = read_input("Enter the certificate Common Name (CN) to enforce: ").strip()
    if not cn:
        say(RED, "[WARNING] No CN provided; skipping common.name.for.certificate.")
        return []
    say(YELLOW, "Setting common.name.for.certificate=\"%s\" on all Ranger plugins..." % cn)
    # Relax Ranger Admin client auth so CN validation applies (want, not false).
    rows = [("ranger-admin-site", "ranger.service.https.attrib.clientAuth", "want")]
    rows += [("ranger-%s-plugin-properties" % svc, "common.name.for.certificate", cn) for svc in RANGER_PLUGINS]
    return rows


#---------------------------------------------------------
# Service builders. Each returns {config type: {key: value}} for its service.
#---------------------------------------------------------
def hdfs_ssl():
    return build([
        ("core-site", "hadoop.ssl.require.client.cert", "false"),
        ("core-site", "hadoop.ssl.hostname.verifier", "DEFAULT"),
        ("core-site", "hadoop.ssl.keystores.factory.class", "org.apache.hadoop.security.ssl.FileBasedKeyStoresFactory"),
        ("core-site", "hadoop.ssl.server.conf", "ssl-server.xml"),
        ("core-site", "hadoop.ssl.client.conf", "ssl-client.xml"),
        ("hdfs-site", "dfs.namenode.https-address", "0.0.0.0:50470"),
        ("hdfs-site", "dfs.namenode.secondary.https-address", "0.0.0.0:50091"),
        ("ssl-server", "ssl.server.keystore.keypassword", KEYSTORE_PASSWORD),
        ("ssl-server", "ssl.server.keystore.password", KEYSTORE_PASSWORD),
        ("ssl-server", "ssl.server.keystore.location", KEYSTORE),
        ("ssl-server", "ssl.server.truststore.location", TRUSTSTORE),
        ("ssl-server", "ssl.server.truststore.password", TRUSTSTORE_PASSWORD),
        ("ssl-client", "ssl.client.keystore.location", KEYSTORE),
        ("ssl-client", "ssl.client.keystore.password", KEYSTORE_PASSWORD),
        ("ssl-client", "ssl.client.truststore.location", TRUSTSTORE),
        ("ssl-client", "ssl.client.truststore.password", TRUSTSTORE_PASSWORD),
        ("hdfs-site", "dfs.http.policy", "HTTPS_ONLY"),
        ("mapred-site", "mapreduce.shuffle.ssl.enabled", "true"),
        ("mapred-site", "mapreduce.jobhistory.http.policy", "HTTPS_ONLY"),
        ("mapred-site", "mapreduce.jobhistory.webapp.https.address", "0.0.0.0:19890"),
        ("mapred-site", "mapreduce.jobhistory.webapp.address", "0.0.0.0:19890"),
        ("yarn-site", "yarn.http.policy", "HTTPS_ONLY"),
        ("yarn-site", "yarn.log.server.url", "https://%s:19890/jobhistory/logs" % host("HISTORYSERVER")),
        ("yarn-site", "yarn.log.server.web-service.url",
        "https://%s:8190/ws/v1/applicationhistory" % host("APP_TIMELINE_SERVER")),
        ("yarn-site", "yarn.nodemanager.webapp.https.address", "0.0.0.0:8044"),
        ("hdfs-site", "dfs.https.enable", "true"),
        ("tez-site", "tez.runtime.shuffle.ssl.enable", "true"),
        ("tez-site", "tez.runtime.shuffle.keep-alive.enabled", "true"),
    ])


def infra_solr_ssl():
    return build([
        ("infra-solr-env", "infra_solr_ssl_enabled", "true"),
        ("infra-solr-env", "infra_solr_keystore_location", KEYSTORE),
        ("infra-solr-env", "infra_solr_keystore_password", KEYSTORE_PASSWORD),
        ("infra-solr-env", "infra_solr_keystore_type", "jks"),
        ("infra-solr-env", "infra_solr_truststore_location", TRUSTSTORE),
        ("infra-solr-env", "infra_solr_truststore_password", TRUSTSTORE_PASSWORD),
        ("infra-solr-env", "infra_solr_truststore_type", "jks"),
        ("infra-solr-env", "infra_solr_extra_java_opts", "-Dsolr.jetty.keystore.type=jks -Dsolr.jetty.truststore.type=jks"),
    ])


def hive_ssl():
    return build([
        ("hive-site", "hive.server2.use.SSL", "true"),
        ("hive-site", "hive.server2.keystore.path", KEYSTORE),
        ("hive-site", "hive.server2.keystore.password", KEYSTORE_PASSWORD),
        ("hive-site", "hive.server2.webui.use.ssl", "true"),
        ("hive-site", "hive.server2.webui.keystore.path", KEYSTORE),
        ("hive-site", "hive.server2.webui.keystore.password", KEYSTORE_PASSWORD),
    ])


def ranger_ssl():
    rangeradmin = host("RANGER_ADMIN")
    ranger_url = "https://%s:6182" % rangeradmin
    rows = [
        ("ranger-admin-site", "ranger.service.http.enabled", "false"),
        ("ranger-admin-site", "ranger.https.attrib.keystore.file", KEYSTORE),
        ("ranger-admin-site", "ranger.service.https.attrib.keystore.pass", KEYSTORE_PASSWORD),
        ("ranger-admin-site", "ranger.service.https.attrib.keystore.keyalias", rangeradmin),
        ("ranger-admin-site", "ranger.service.https.attrib.clientAuth", "false"),
        ("ranger-admin-site", "ranger.service.https.attrib.ssl.enabled", "true"),
        ("ranger-admin-site", "ranger.service.https.port", "6182"),
        ("ranger-admin-site", "ranger.truststore.alias", rangeradmin),
        ("ranger-admin-site", "ranger.truststore.file", TRUSTSTORE),
        ("ranger-admin-site", "ranger.truststore.password", TRUSTSTORE_PASSWORD),
        ("ranger-admin-site", "ranger.service.https.attrib.keystore.file", KEYSTORE),
        ("ranger-admin-site", "ranger.service.https.attrib.client.auth", "false"),
        ("ranger-admin-site", "ranger.externalurl", ranger_url),
        ("admin-properties", "policymgr_external_url", ranger_url),
        ("ranger-ugsync-site", "ranger.usersync.truststore.file", TRUSTSTORE),
        ("ranger-ugsync-site", "ranger.usersync.truststore.password", TRUSTSTORE_PASSWORD),
        ("ranger-ugsync-site", "ranger.usersync.keystore.file", KEYSTORE),
        ("ranger-ugsync-site", "ranger.usersync.keystore.password", KEYSTORE_PASSWORD),
        # Original script wrote "xasecure.audit.destination.solr:" (stray colon). Fixed here.
        ("ranger-knox-audit", "xasecure.audit.destination.solr", "false"),
    ]
    for config_type in ["ranger-tagsync-policymgr-ssl"] + ["ranger-%s-policymgr-ssl" % svc for svc in RANGER_PLUGINS]:
        rows += policymgr_ssl_rows(config_type)
    for svc, key in RANGER_POLICY_URL_KEYS:
        rows.append(("ranger-%s-security" % svc, "ranger.plugin.%s.policy.rest.url" % key, ranger_url))
    rows += ranger_plugin_cn_rows()
    return build(rows)


def ranger_kms_ssl():
    rangerkms = host("RANGER_KMS_SERVER")
    return build([
        ("ranger-kms-site", "ranger.service.https.attrib.ssl.enabled", "true"),
        ("ranger-kms-site", "ranger.service.https.attrib.client.auth", "false"),
        ("ranger-kms-site", "ranger.service.https.attrib.keystore.file", KEYSTORE),
        ("ranger-kms-site", "ranger.service.https.attrib.keystore.keyalias", rangerkms),
        ("ranger-kms-site", "ranger.service.https.attrib.keystore.pass", KEYSTORE_PASSWORD),
        ("hdfs-site", "dfs.encryption.key.provider.uri", "kms://https@%s:9393/kms" % rangerkms),
        ("core-site", "hadoop.security.key.provider.path", "kms://https@%s:9393/kms" % rangerkms),
        ("kms-env", "kms_port", "9393"),
    ])


def spark_ssl(defaults, historyserver_port):
    """Spark2 and Spark3 share the same keys; only the config type and history server port differ."""
    return build([
        ("yarn-site", "spark.authenticate", "false"),
        (defaults, "spark.authenticate", "false"),
        (defaults, "spark.authenticate.enableSaslEncryption", "false"),
        (defaults, "spark.ssl.enabled", "true"),
        (defaults, "spark.ssl.keyPassword", KEYSTORE_PASSWORD),
        (defaults, "spark.ssl.keyStore", KEYSTORE),
        (defaults, "spark.ssl.keyStorePassword", KEYSTORE_PASSWORD),
        (defaults, "spark.ssl.protocol", "TLS"),
        (defaults, "spark.ssl.trustStore", TRUSTSTORE),
        (defaults, "spark.ssl.trustStorePassword", TRUSTSTORE_PASSWORD),
        (defaults, "spark.ui.https.enabled", "true"),
        (defaults, "spark.ssl.historyServer.port", historyserver_port),
    ])


def spark2_ssl():
    return spark_ssl("spark2-defaults", "18481")


def spark3_ssl():
    return spark_ssl("spark3-defaults", "18482")


def kafka_ssl(broker_type):
    return build([
        (broker_type, "ssl.keystore.location", KEYSTORE),
        (broker_type, "ssl.keystore.password", KEYSTORE_PASSWORD),
        (broker_type, "ssl.key.password", KEYSTORE_PASSWORD),
        (broker_type, "ssl.truststore.location", TRUSTSTORE),
        (broker_type, "ssl.truststore.password", TRUSTSTORE_PASSWORD),
    ])


def kafka2_ssl():
    return kafka_ssl("kafka-broker")


def kafka3_ssl():
    return kafka_ssl("kafka3-broker")


def hbase_ssl():
    return build([
        ("hbase-site", "hbase.ssl.enabled", "true"),
        ("hbase-site", "hadoop.ssl.enabled", "true"),
        ("hbase-site", "ssl.server.keystore.keypassword", KEYSTORE_PASSWORD),
        ("hbase-site", "ssl.server.keystore.password", KEYSTORE_PASSWORD),
        ("hbase-site", "ssl.server.keystore.location", KEYSTORE),
    ])


def oozie_ssl():
    return build([
        ("oozie-site", "oozie.https.enabled", "true"),
        ("oozie-site", "oozie.https.port", "11443"),
        ("oozie-site", "oozie.https.keystore.file", KEYSTORE),
        ("oozie-site", "oozie.https.keystore.pass", KEYSTORE_PASSWORD),
        ("oozie-site", "oozie.https.truststore.file", TRUSTSTORE),
        ("oozie-site", "oozie.https.truststore.pass", TRUSTSTORE_PASSWORD),
        ("oozie-site", "oozie.base.url", "https://%s:11443/oozie" % host("OOZIE_SERVER")),
    ])


def ozone_ssl():
    rows = [
        ("ozone-env", "ozone_scm_ssl_enabled", "true"),
        ("ozone-env", "ozone_manager_ssl_enabled", "true"),
        ("ozone-env", "ozone_s3g_ssl_enabled", "true"),
        ("ozone-env", "ozone_datanode_ssl_enabled", "true"),
        ("ozone-env", "ozone_recon_ssl_enabled", "true"),
        ("ozone-site", "ozone.http.policy", "HTTPS_ONLY"),
        ("ozone-site", "ozone.https.client.keystore.resource", "ssl-client.xml"),
        ("ozone-site", "ozone.https.server.keystore.resource", "ssl-server.xml"),
        ("ozone-ssl-client", "ssl.client.truststore.location", TRUSTSTORE),
        ("ozone-ssl-client", "ssl.client.truststore.password", TRUSTSTORE_PASSWORD),
    ]
    for comp in ["datanode", "om", "recon", "s3g", "scm"]:
        client = "ssl-client-%s" % comp
        server = "ssl-server-%s" % comp
        rows += [
            (client, "ssl.client.truststore.location", TRUSTSTORE),
            (client, "ssl.server.truststore.password", TRUSTSTORE_PASSWORD),
            (server, "ssl.client.truststore.location", TRUSTSTORE),
            (server, "ssl.server.truststore.password", TRUSTSTORE_PASSWORD),
            (server, "ssl.server.keystore.location", KEYSTORE),
            (server, "ssl.server.keystore.password", KEYSTORE_PASSWORD),
            (server, "ssl.server.keystore.keypassword", KEYSTORE_PASSWORD),
        ]
    return build(rows)


def nifi_ssl():
    return build([
        ("nifi-ambari-ssl-config", "nifi.node.ssl.isenabled", "true"),
        ("nifi-ambari-ssl-config", "nifi.security.keyPasswd", KEYSTORE_PASSWORD),
        ("nifi-ambari-ssl-config", "nifi.security.keystore", KEYSTORE),
        ("nifi-ambari-ssl-config", "nifi.security.keystorePasswd", KEYSTORE_PASSWORD),
        ("nifi-ambari-ssl-config", "nifi.security.keystoreType", "jks"),
        ("nifi-ambari-ssl-config", "nifi.security.truststore", TRUSTSTORE),
        ("nifi-ambari-ssl-config", "nifi.security.truststoreType", "jks"),
        ("nifi-ambari-ssl-config", "nifi.security.truststorePasswd", TRUSTSTORE_PASSWORD),
    ])


def nifi_registry_ssl():
    return build([
        ("nifi-registry-ambari-ssl-config", "nifi.registry.ssl.isenabled", "true"),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.keystore", KEYSTORE),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.keyPasswd", KEYSTORE_PASSWORD),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.keystorePasswd", KEYSTORE_PASSWORD),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.needClientAuth", "false"),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.truststore", TRUSTSTORE),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.truststorePasswd", TRUSTSTORE_PASSWORD),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.keystoreType", "jks"),
        ("nifi-registry-ambari-ssl-config", "nifi.registry.security.truststoreType", "jks"),
    ])


def schema_registry_ssl():
    return build([
        ("registry-ssl-config", "registry.ssl.isenabled", "true"),
        ("registry-ssl-config", "registry.keyStoreType", "jks"),
        ("registry-ssl-config", "registry.trustStoreType", "jks"),
        ("registry-ssl-config", "registry.keyStorePath", KEYSTORE),
        ("registry-ssl-config", "registry.trustStorePath", TRUSTSTORE),
        ("registry-ssl-config", "registry.keyStorePassword", KEYSTORE_PASSWORD),
        ("registry-ssl-config", "registry.trustStorePassword", TRUSTSTORE_PASSWORD),
    ])


def livy3_ssl():
    return build([
        ("livy3-conf", "livy.ssl", "true"),
        ("livy3-conf", "livy.keystore", KEYSTORE),
        ("livy3-conf", "livy.keystore.password", KEYSTORE_PASSWORD),
        ("livy3-conf", "livy.key-password", KEYSTORE_PASSWORD),
        ("livy3-conf", "livy.truststore", TRUSTSTORE),
        ("livy3-conf", "livy.truststore.password", TRUSTSTORE_PASSWORD),
    ])


def livy2_ssl():
    return build([
        ("livy2-conf", "livy.keystore", KEYSTORE),
        ("livy2-conf", "livy.keystore.password", KEYSTORE_PASSWORD),
        ("livy2-conf", "livy.key-password", KEYSTORE_PASSWORD),
    ])


def trino_ssl():
    return build([
        ("trino-env", "ssl_enabled", "true"),
        ("trino-env", "ssl_keystore", KEYSTORE),
        ("trino-env", "ssl_keystore_password", KEYSTORE_PASSWORD),
        ("trino-env", "java_truststore", TRUSTSTORE),
        ("trino-env", "java_truststore_password", TRUSTSTORE_PASSWORD),
    ])


def trino_gateway_ssl():
    return build([
        ("trino-gateway-ssl", "ssl_enabled", "true"),
        ("trino-gateway-ssl", "trino-gateway.keystore_path", KEYSTORE),
        ("trino-gateway-ssl", "trino-gateway.keystore_key", KEYSTORE_PASSWORD),
        ("trino-gateway-ssl", "process_forwarded", "true"),
    ])


def zeppelin_ssl():
    return build([
        ("zeppelin-site", "zeppelin.ssl", "true"),
        ("zeppelin-site", "zeppelin.ssl.key.manager.password", KEYSTORE_PASSWORD),
        ("zeppelin-site", "zeppelin.ssl.keystore.password", KEYSTORE_PASSWORD),
        ("zeppelin-site", "zeppelin.ssl.keystore.path", KEYSTORE),
        ("zeppelin-site", "zeppelin.ssl.keystore.type", "jks"),
        ("zeppelin-site", "zeppelin.ssl.truststore.password", TRUSTSTORE_PASSWORD),
        ("zeppelin-site", "zeppelin.ssl.truststore.path", TRUSTSTORE),
        ("zeppelin-site", "zeppelin.ssl.truststore.type", "jks"),
    ])


def solr_ssl():
    return build([
        ("solr-config", "solr_ssl_enabled", "true"),
        ("solr-config", "solr_keystore_location", KEYSTORE),
        ("solr-config", "solr_keystore_password", KEYSTORE_PASSWORD),
        ("solr-config", "solr_truststore_location", TRUSTSTORE),
        ("solr-config", "solr_truststore_password", TRUSTSTORE_PASSWORD),
    ])


def atlas_ssl():
    return build([
        ("application-properties", "atlas.enableTLS", "true"),
        ("application-properties", "keystore.file", KEYSTORE),
        ("application-properties", "keystore.password", KEYSTORE_PASSWORD),
        ("application-properties", "truststore.file", TRUSTSTORE),
        ("application-properties", "truststore.password", TRUSTSTORE_PASSWORD),
        ("application-properties", "cert.stores.credential.provider.path", ATLAS_JCEKS_URI),
        ("application-properties", "atlas.kafka.ssl.truststore.location", TRUSTSTORE),
        ("application-properties", "atlas.kafka.ssl.truststore.password", TRUSTSTORE_PASSWORD),
    ])


#---------------------------------------------------------
# Bulk push: one PUT per owning service
#---------------------------------------------------------
def owning_service_by_type():
    """Config type -> owning service. Ambari rejects one PUT whose config types span services."""
    owner = {}
    for version in api("GET", "/clusters/%s/configurations/service_config_versions?is_current=true" % CLUSTER)["items"]:
        for config in version.get("configurations", []):
            owner[str(config["type"])] = str(version["service_name"])
    return owner


def push(changes, note):
    """Write the changed config types, one Ambari request per owning service. Returns the number of failed properties."""
    desired = api("GET", "/clusters/%s?fields=Clusters/desired_configs" % CLUSTER)["Clusters"]["desired_configs"]
    owner = owning_service_by_type()
    tag = "version%d" % int(time.time() * 1000)
    groups = OrderedDict()  # service -> [(entry, changed keys)]
    failed = 0
    for config_type, props in changes.items():
        if config_type not in desired or config_type not in owner:
            say(RED, "[WARNING] Config type '%s' is not in this cluster; skipping %d properties." % (config_type, len(props)))
            failed += len(props)
            continue
        # Read-merge-write: a PUT replaces a config type, so keep the existing properties and their final flags.
        current = api("GET", "/clusters/%s/configurations?type=%s&tag=%s"
                      % (CLUSTER, config_type, desired[config_type]["tag"]))["items"][0]
        merged = OrderedDict(current["properties"])
        merged.update(props)
        entry = {"type": config_type, "tag": tag, "properties": merged, "service_config_version_note": note}
        if current.get("properties_attributes"):
            entry["properties_attributes"] = current["properties_attributes"]
        groups.setdefault(owner[config_type], []).append((entry, sorted(props)))
    for service, group in groups.items():
        failed += put_service(service, group)
    return failed


def put_service(service, group):
    """One PUT for every config type a service owns. Returns the number of properties that failed."""
    total = sum(len(keys) for _, keys in group)
    if DRY_RUN:
        for entry, keys in group:
            say(CYAN, "[DRY RUN] %s would set %s: %s" % (service, entry["type"], ", ".join(keys)))
        return 0
    try:
        api("PUT", "/clusters/%s" % CLUSTER, {"Clusters": {"desired_config": [entry for entry, _ in group]}})
    except HTTPError as e:
        log_failure("[ERROR] Ambari rejected the %s update (HTTP %s): %s"
                    % (service, e.code, e.read().decode("utf-8", "replace")[:300]))
        FAILED.append(service)
        return total
    except URLError as e:
        if is_cert_error(e):
            handle_ssl_failure("Ambari API rejected our certificate (CERTIFICATE_VERIFY_FAILED).")
        log_failure("[ERROR] Could not reach Ambari: %s" % e)
        FAILED.append(service)
        return total
    for entry, keys in group:
        say(GREEN, "[OK] Updated %s (%d properties)" % (entry["type"], len(keys)))
    APPLIED.append(service)
    return 0

#---------------------------------------------------------
# Atlas credential provider guide
#---------------------------------------------------------
def print_atlas_jceks_guide():
    print("")
    say(CYAN, "════════════════════════════════════════════════════════════")
    say(CYAN, " Atlas: create the credential provider (required)")
    say(CYAN, "════════════════════════════════════════════════════════════")
    print("Atlas reads the keystore/truststore passwords from a JCEKS credential")
    print("provider, not from application-properties. You configured:")
    say(GREEN, "  cert.stores.credential.provider.path = %s" % ATLAS_JCEKS_URI)
    print("")
    say(YELLOW, "The provider path can be local or in HDFS, e.g.:")
    print("  jceks://file/local/file/path/file.jceks")
    print("  jceks://hdfs@namenodehost:port/path/in/hdfs/to/file.jceks")
    print("")
    atlas_host = " (%s)" % HOSTS["ATLAS_SERVER"] if HOSTS.get("ATLAS_SERVER") else ""
    say(YELLOW, "To create it, log in to the Atlas node%s and run:" % atlas_host)
    say(GREEN, "  cd /usr/odp/current/atlas-server/bin")
    say(GREEN, "  ./cputil.py")
    print("")
    print("When prompted, enter the provider path and the passwords:")
    print("  Please enter the full path to the credential provider: %s" % ATLAS_JCEKS_URI)
    print("  Please enter the password value for keystore.password:   <keystore password>")
    print("  Please enter the password value for keystore.password again:")
    print("  Please enter the password value for truststore.password: <truststore password>")
    print("  Please enter the password value for truststore.password again:")
    print("  Please enter the password value for password:            <key/server cert password>")
    print("  Please enter the password value for password again:")
    print("")
    say(YELLOW, "Then fix ownership so the Atlas process can read it:")
    say(GREEN, "  chown atlas:hadoop %s" % ATLAS_JCEKS_LOCAL)
    print("")
    say(YELLOW, "Restart the Atlas service after creating the credential provider.")
    say(CYAN, "════════════════════════════════════════════════════════════")


#---------------------------------------------------------
# Menu
#---------------------------------------------------------
# key -> (label, builder). Builders run when the service is selected, so Ranger CN prompts happen then.
SERVICES = OrderedDict([
    ("1", ("HDFS, YARN & MapReduce", hdfs_ssl)),
    ("2", ("Infra-Solr", infra_solr_ssl)),
    ("3", ("Hive", hive_ssl)),
    ("4", ("Ranger", ranger_ssl)),
    ("5", ("Spark2", spark2_ssl)),
    ("6", ("Kafka", kafka2_ssl)),
    ("7", ("HBase", hbase_ssl)),
    ("8", ("Spark3", spark3_ssl)),
    ("9", ("Oozie", oozie_ssl)),
    ("10", ("Ranger KMS", ranger_kms_ssl)),
    ("11", ("Ozone", ozone_ssl)),
    ("12", ("NiFi", nifi_ssl)),
    ("13", ("Schema Registry", schema_registry_ssl)),
    ("14", ("Livy2", livy2_ssl)),
    ("15", ("Kafka3", kafka3_ssl)),
    ("16", ("Livy3", livy3_ssl)),
    ("17", ("NiFi Registry", nifi_registry_ssl)),
    ("18", ("Trino", trino_ssl)),
    ("19", ("Zeppelin", zeppelin_ssl)),
    ("20", ("Solr", solr_ssl)),
    ("21", ("Atlas", atlas_ssl)),
    ("22", ("Trino Gateway", trino_gateway_ssl)),
])


def display_service_options():
    say(YELLOW, "╔════════════════════════════════════════════════════════════╗")
    say(GREEN, "        🚀  SSL Configuration Menu – Choose a Service")
    say(YELLOW, "╚════════════════════════════════════════════════════════════╝\n")
    icons = ["🗃️", "🔍", "🐝", "🛡️", "✨", "📡", "📚", "⚡", "🌀", "🔑", "☁️", "⚙️", "🔄", "🔬", "📡", "🧪", "📝", "🚀", "📓", "🔍", "🗺️", "🚪"]
    for (key, (label, _)), icon in zip(SERVICES.items(), icons):
        say(GREEN, "%3s)%s %s   %s" % (key, NC, icon, label))
    say(YELLOW, "────────────────────────────────────────────────────────────")
    say(GREEN, "  A)%s 🌐   All Services (for the brave)" % NC)
    say(RED, "  Q)%s ❌   Quit (no changes)" % NC)
    say(YELLOW, "────────────────────────────────────────────────────────────")


def run_selection(keys):
    global ATLAS_SELECTED
    changes = OrderedDict()
    labels = []
    for key in keys:
        label, builder = SERVICES[key]
        say(YELLOW, "Starting to enable SSL for %s..." % label)
        try:
            merge(changes, builder())
        except MissingHost as e:
            say(RED, "[WARNING] %s has no %s host in this cluster; skipping it." % (label, e))
            continue
        labels.append(label)
    if "21" in keys:
        ATLAS_SELECTED = True

    # Config version note on every changed config type. Ambari caps the note length.
    failed = push(changes, ("SSL enabled via setup_ssl_with_existing_jks.py for " + ", ".join(labels))[:255])
    if DRY_RUN:
        say(CYAN, "[DRY RUN] Nothing written. Would enable SSL for %s." % ", ".join(labels))
    elif failed:
        say(RED, "[WARNING] %d properties failed while enabling SSL for %s. See %s." % (failed, ", ".join(labels), LOG_FILE))
    else:
        say(GREEN, "Successfully enabled SSL for %s." % ", ".join(labels))
    if "21" in keys:
        print_atlas_jceks_guide()


def menu():
    while True:
        display_service_options()
        choice = read_input("Enter your selection:⇒ ").strip().lower()
        if choice == "q":
            say(GREEN, "Exiting...")
            return
        if choice == "a":
            run_selection(list(SERVICES.keys()))
        elif choice in SERVICES:
            run_selection([choice])
        else:
            say(RED, "Invalid selection. Please choose a valid option.")


#---------------------------------------------------------
# Main
#---------------------------------------------------------
def check_files():
    if not CHECK_FILES:
        say(YELLOW, "⚠️  File existence check is disabled (CHECK_FILES=false).")
        return
    for path in (KEYSTORE, TRUSTSTORE):
        if not os.path.isfile(path):
            die("Error: Required file '%s' not found. Please check before proceeding." % path)
    say(YELLOW, "✅ All required keystore and truststore files are present.")


def main():
    global CLUSTER, HOSTS
    if PROTOCOL == "https":
        prepare_https()
    elif AMBARI_HOST not in ("localhost", "127.0.0.1"):
        say(RED, "[WARNING] PROTOCOL=http sends the Ambari login and keystore passwords in clear text.")
        if read_input("Continue over plain HTTP? (yes/no): ").strip().lower() != "yes":
            sys.exit(1)
    try:
        CLUSTER = get_cluster()
    except URLError as e:
        if is_cert_error(e):
            handle_ssl_failure("Ambari API rejected our certificate (CERTIFICATE_VERIFY_FAILED).")
        die("[ERROR] Could not reach Ambari at %s:%s: %s" % (AMBARI_HOST, AMBARI_PORT, e))
    if not CLUSTER:
        die("[ERROR] Could not retrieve cluster name from Ambari.\n"
            "Check AMBARI_HOST, AMBARI_PORT, PROTOCOL, AMBARI_USER, and AMBARI_PASSWORD — then re-run.")
    HOSTS = dict((component, get_host_for_component(component)) for component in [
        "APP_TIMELINE_SERVER", "HISTORYSERVER", "RANGER_ADMIN", "OOZIE_SERVER", "RANGER_KMS_SERVER", "ATLAS_SERVER"])

    say(GREEN, "==========================================================")
    say(GREEN, "              Acceldata ODP SSL Configuration Script        ")
    say(GREEN, "===========================================================")
    check_files()
    say(YELLOW, "🔑 Please ensure that you have set all variables correctly.\n")
    print("⚙️ %sAMBARI_HOST:%s %s" % (GREEN, NC, AMBARI_HOST))
    print("👤 %sUSER:%s %s" % (GREEN, NC, AMBARI_USER))
    print("🌐 %sPORT:%s %s" % (GREEN, NC, AMBARI_PORT))
    print("🌐 %sPROTOCOL:%s %s" % (GREEN, NC, PROTOCOL))
    print("🔐 %skeystore:%s %s" % (GREEN, NC, KEYSTORE))
    print("🔐 %struststore:%s %s" % (GREEN, NC, TRUSTSTORE))
    print("🗂️  %scluster:%s %s" % (GREEN, NC, CLUSTER))
    if DRY_RUN:
        say(YELLOW, "DRY_RUN=true: nothing will be written to Ambari.")
    say(YELLOW, "ℹ️ Verify the keystore alias for Ranger and KMS nodes matches the configured alias \n"
                " (ranger.service.https.attrib.keystore.keyalias - default: host FQDN).")
    say(GREEN, "keytool -list -keystore \"%s\"" % KEYSTORE)

    menu()

    if APPLIED:
        say(GREEN, "Applied to Ambari: %s" % ", ".join(APPLIED))
    if FAILED:
        say(RED, "Rejected by Ambari (nothing changed for these): %s" % ", ".join(FAILED))
    if ATLAS_SELECTED:
        print_atlas_jceks_guide()
    say(GREEN, "Script execution completed.")
    say(YELLOW, "Access the Ambari UI and initiate a restart for the affected services to apply the SSL changes.")


if __name__ == "__main__":
    main()
