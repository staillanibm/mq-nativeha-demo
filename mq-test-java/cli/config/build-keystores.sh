#!/bin/bash
# Build the keystores of each role from the PEM files in ./certs:
#   - CMS keystore (tls-<role>/key.kdb + key.sth) for the MQ native client (amqsputc/dmpmqmsg)
#   - PKCS12 keystore (../certs/<role>.p12) and truststore (../certs/truststore.p12)
#     for the Java client (mq-test-cli); passwords are updated in ../.env.
# Needs openssl and the MQ client (runmqakm). MQ_HOME comes from ../.env.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. ./env.sh

for r in producer consumer; do
  for f in $r.crt $r.key clients-ca.crt servers-ca.crt; do
    [ -f certs/$f ] || { echo "certs/$f missing (see README)" >&2; exit 1; }
  done
done

umask 077
tmp=$(mktemp -d); trap 'rm -rf $tmp' EXIT
kspw=$(openssl rand -hex 12)
tspw=$(openssl rand -hex 12)

for r in producer consumer; do
  # --- CMS keystore (MQ native client) ---
  # the password is only needed here: the client opens the keystore through key.sth
  pw=$(openssl rand -hex 12)
  openssl pkcs12 -export -inkey certs/$r.key -in certs/$r.crt -name mqclient \
    -out $tmp/$r.p12 -passout pass:"$pw"
  rm -rf tls-$r; mkdir tls-$r
  runmqakm -keydb -create -db tls-$r/key.kdb -pw "$pw" -type cms -stash
  runmqakm -cert -import -file $tmp/$r.p12 -pw "$pw" -type pkcs12 \
    -target tls-$r/key.kdb -target_pw "$pw" -target_type cms
  # the imported certificate may keep its DN as label: the CCDT expects "mqclient"
  personal=$(runmqakm -cert -list personal -db tls-$r/key.kdb -pw "$pw" | sed -n 's/^[-!*#]*[[:space:]]*\([A-Za-z]*=.*\)$/\1/p' | head -1)
  [ -z "$personal" ] || runmqakm -cert -rename -db tls-$r/key.kdb -pw "$pw" -label "$personal" -new_label mqclient
  runmqakm -cert -add -db tls-$r/key.kdb -pw "$pw" -label clientsca -file certs/clients-ca.crt -trust enable
  runmqakm -cert -add -db tls-$r/key.kdb -pw "$pw" -label serverca  -file certs/servers-ca.crt -trust enable
  runmqakm -cert -list -db tls-$r/key.kdb -pw "$pw"

  # --- PKCS12 keystore (Java client) ---
  mkdir -p ../certs
  openssl pkcs12 -export \
    -inkey certs/$r.key -in certs/$r.crt -certfile certs/clients-ca.crt \
    -name mqclient \
    -out ../certs/$r.p12 -passout pass:"$kspw"
done

# Truststore: server CA only (Java client verifies the queue manager certificate).
# keytool -importcert is required: openssl pkcs12 -nokeys produces an empty store
# that the JVM rejects with "trustAnchors parameter must be non-empty".
# Remove any existing file first: keytool fails silently on a wrong-password store.
rm -f ../certs/truststore.p12
keytool -importcert -noprompt \
  -alias serverca -file certs/servers-ca.crt \
  -storetype PKCS12 -keystore ../certs/truststore.p12 \
  -storepass "$tspw"

chmod 600 ../certs/*.p12

# Update passwords in ../.env
sed -i "s|^MQ_KEYSTORE_PASSWORD=.*|MQ_KEYSTORE_PASSWORD=$kspw|"   ../.env
sed -i "s|^MQ_TRUSTSTORE_PASSWORD=.*|MQ_TRUSTSTORE_PASSWORD=$tspw|" ../.env
echo "config/tls-*, ../certs/*.p12 and ../.env passwords updated"
