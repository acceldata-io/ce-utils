Util for Fixing ambari java home related issues for 3.3.6.3-101

To update scripts on ambari server for following patch

https://github.com/acceldata-io/odp-ambari/pull/484/files


```patch
Date: Sun, 5 Apr 2026 13:34:22 -0400
Subject: [PATCH] ODP-6189 Update plain java to ambari_java_home for
 CredentialUtil class

---
 .../services/DRUID/package/scripts/params.py  |  3 ++-
 .../configuration/cruise-control-env.xml      | 13 ++++++------
 .../KAFKA/configuration/kafka-env.xml         | 21 ++++++++++---------
 .../services/KAFKA/package/scripts/kafka.py   |  5 +++--
 .../services/KAFKA/package/scripts/params.py  |  2 ++
 5 files changed, 25 insertions(+), 19 deletions(-)

diff --git a/ambari-server/src/main/resources/stacks/ODP/3.3/services/DRUID/package/scripts/params.py b/ambari-server/src/main/resources/stacks/ODP/3.3/services/DRUID/package/scripts/params.py
index e5be6d081e..3367e3dec4 100644
--- a/ambari-server/src/main/resources/stacks/ODP/3.3/services/DRUID/package/scripts/params.py
+++ b/ambari-server/src/main/resources/stacks/ODP/3.3/services/DRUID/package/scripts/params.py
@@ -98,7 +98,8 @@
 
 # jceks params
 jceks_path = "jceks://file/etc/security/credential/druid.jceks"
-password_command = "{0}/bin/java -cp '/var/lib/ambari-agent/cred/lib/*' org.apache.ambari.server.credentialapi.CredentialUtil -provider {1} get ".format(java8_home, jceks_path)
+# Use Ambari's Java home for CredentialUtil (compiled with JDK17+)
+password_command = "{0}/bin/java -cp '/var/lib/ambari-agent/cred/lib/*' org.apache.ambari.server.credentialapi.CredentialUtil -provider {1} get ".format(ambari_java_home, jceks_path)
 
 # log4j params
 log4j_props = config['configurations']['druid-log4j']['content']
diff --git a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/cruise-control-env.xml b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/cruise-control-env.xml
index 5dad466bdc..c07b798374 100644
--- a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/cruise-control-env.xml
+++ b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/cruise-control-env.xml
@@ -70,6 +70,7 @@
 
       # The java implementation to use.
       export JAVA_HOME={{cc_java_home}}
+      export AMBARI_JAVA_HOME={{ambari_java_home}}
       export PATH=$PATH:$JAVA_HOME/bin
       export PID_DIR={{cruise_control_pid_dir}}
       export LOG_DIR={{cruise_control_log_dir}}
@@ -82,12 +83,12 @@
       {% endif %}
 
       ##export ssl password variables for cruise-control:
-      export SSL_KEY_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.key.password"`
-      export SSL_KEYSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.keystore.password"`
-      export SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.truststore.password"`
-      export WEBSERVER_SSL_KEY_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.key.password"`
-      export WEBSERVER_SSL_KEYSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.keystore.password"`
-      export WEBSERVER_SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.truststore.password"`
+      export SSL_KEY_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.key.password"`
+      export SSL_KEYSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.keystore.password"`
+      export SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "ssl.truststore.password"`
+      export WEBSERVER_SSL_KEY_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.key.password"`
+      export WEBSERVER_SSL_KEYSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.keystore.password"`
+      export WEBSERVER_SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "jceks://file/etc/security/credential/cruise-control.jceks" get  "webserver.ssl.truststore.password"`
     </value>
     <value-attributes>
       <type>content</type>
diff --git a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/kafka-env.xml b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/kafka-env.xml
index da56406d43..fbaa48f29b 100644
--- a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/kafka-env.xml
+++ b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/configuration/kafka-env.xml
@@ -112,6 +112,7 @@
 
       # The java implementation to use.
       export JAVA_HOME={{java64_home}}
+      export AMBARI_JAVA_HOME={{ambari_java_home}}
       export PATH=$PATH:$JAVA_HOME/bin
       export PID_DIR={{kafka_pid_dir}}
       export LOG_DIR={{kafka_log_dir}}
@@ -139,15 +140,15 @@
 
       {% if kafka_ssl_isenabled %}
       ## export ssl password variables for kafka-broker:
-      export SSL_KEY_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export SSL_KEY_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka.jceks" get "ssl.key.password"`
 
-      export SSL_KEYSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export SSL_KEYSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka.jceks" get "ssl.keystore.password"`
 
-      export SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka.jceks" get "ssl.truststore.password"`
       {% else %}
@@ -156,11 +157,11 @@
 
       {% if cc_ssl_isenabled %}
       ## export ssl password variables for cruise-control:
-      export CRUISE_CONTROL_METRICS_REPORTER_SSL_KEYSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CRUISE_CONTROL_METRICS_REPORTER_SSL_KEYSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka.jceks" get "cruise.control.metrics.reporter.ssl.keystore.password"`
 
-      export CRUISE_CONTROL_METRICS_REPORTER_SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CRUISE_CONTROL_METRICS_REPORTER_SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka.jceks" get "cruise.control.metrics.reporter.ssl.truststore.password"`
       {% else %}
@@ -169,23 +170,23 @@
 
       {% if connect_ssl_isenabled %}
       ## export ssl password variables for kafka connect:
-      export CONNECT_CONSUMER_SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CONNECT_CONSUMER_SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka-connect.jceks" get "connect.consumer.ssl.truststore.password"`
 
-      export CONNECT_PRODUCER_SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CONNECT_PRODUCER_SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka-connect.jceks" get "connect.producer.ssl.truststore.password"`
 
-      export CONNECT_SSL_KEY_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CONNECT_SSL_KEY_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka-connect.jceks" get "connect.ssl.key.password"`
 
-      export CONNECT_SSL_KEYSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CONNECT_SSL_KEYSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka-connect.jceks" get "connect.ssl.keystore.password"`
 
-      export CONNECT_SSL_TRUSTSTORE_PASSWORD=`java -cp "/var/lib/ambari-agent/cred/lib/*" \
+      export CONNECT_SSL_TRUSTSTORE_PASSWORD=`$AMBARI_JAVA_HOME/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" \
       org.apache.ambari.server.credentialapi.CredentialUtil \
       -provider "jceks://file/etc/security/credential/kafka-connect.jceks" get "connect.ssl.truststore.password"`
       {% else %}
diff --git a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/kafka.py b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/kafka.py
index a98f27ef0c..e28d5375e7 100644
--- a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/kafka.py
+++ b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/kafka.py
@@ -287,9 +287,10 @@ def kafka(upgrade_type=None):
     env_exports = ""
     for alias in params.mirror_maker_password_props:
         if params.mirror_maker_password_props[alias] and params.mirror_maker_password_props[alias].strip():
+            # Use Ambari's Java home for CredentialUtil (compiled with JDK17+)
             env_exports += (
-                'export {alias}=`java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "{path}" get "{alias}"`\n'
-            ).format(alias=alias, path=params.kafka_mirrormaker_credential_path)
+                'export {{alias}}=`{ambari_java_home}/bin/java -cp "/var/lib/ambari-agent/cred/lib/*" org.apache.ambari.server.credentialapi.CredentialUtil -provider "{{path}}" get "{{alias}}"`\n'
+            ).format(ambari_java_home=params.ambari_java_home).format(alias=alias, path=params.kafka_mirrormaker_credential_path)
 
     params.kafka_env_sh_template += "\n" + env_exports
 
diff --git a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/params.py b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/params.py
index c12b84280d..5c24f0f883 100644
--- a/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/params.py
+++ b/ambari-server/src/main/resources/stacks/ODP/3.3/services/KAFKA/package/scripts/params.py
@@ -49,6 +49,8 @@
 
 jdk_name = default("/ambariLevelParams/jdk_name", None)
 java_home = config['ambariLevelParams']['java_home']
+# Use Ambari's Java home for credential store operations (tools compiled with JDK17+)
+ambari_java_home = default("/ambariLevelParams/ambari_java_home", java_home)
 java_version = expect("/ambariLevelParams/java_version", int)
 # Version being upgraded/downgraded to
 version = default("/commandParams/version", None)

```