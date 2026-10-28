#!/bin/bash
# Build the CMS keystore (tls-<role>/key.kdb + key.sth) of each role from the PEM
# files in ./certs. Local only: needs openssl and the MQ client (runmqakm).
# MQ_HOME comes from ../.env.
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
for r in producer consumer; do
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
  runmqakm -cert -add -db tls-$r/key.kdb -pw "$pw" -label serverca -file certs/servers-ca.crt -trust enable
  runmqakm -cert -list -db tls-$r/key.kdb -pw "$pw"
done
