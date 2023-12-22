#!/bin/bash
# Acceldata Inc.
## Generating jks and cert
## Note: This is a sample instructionlist for internal service testing. You may configure the commands as per your setup requirements.

# sample password and Java_home values:
password="password"
java_home="/usr/lib/jvm/java-1.8.0-openjdk-1.8.0.392.b08-2.el7_9.x86_64"
hostname="odp.ad.ce"

mkdir -p /opt/security/pki/
cd /opt/security/pki/ || exit

#Generate SSL certificate
keytool -genkey -alias "$(hostname)" -keyalg RSA -keysize 2048 -dname "CN=$(hostname -f),OU=SU,O=ACCELO,L=BNG,ST=KN,C=IN" -keypass "$password" -keystore keystore.jks -storepass "$password"

#Export SSL certificate
keytool -export -alias "$(hostname)" -keystore keystore.jks -file "$(hostname).crt" -storepass "$password"

#Import SSL certificate into truststore
yes | keytool -import -file "$(hostname).crt" -keystore truststore.jks -alias "$(hostname)-trust" -storepass "$password"
ls -ltr /opt/security/pki/*
