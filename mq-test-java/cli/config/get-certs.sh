#!/bin/bash
# Have cert-manager issue the client certificates (certs.yaml.template) and export
# them as PEM to ./certs, with the CA of the queue manager certificate taken from
# the existing secret SERVER_CA_SECRET. This is the only script that talks to the
# cluster. Run it once. NS, CLIENTS_ISSUER* and SERVER_CA_SECRET come from ../.env.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
. ./env.sh

sed -e "s|\${CLIENTS_ISSUER_KIND}|$CLIENTS_ISSUER_KIND|g" -e "s|\${CLIENTS_ISSUER}|$CLIENTS_ISSUER|g" \
    certs.yaml.template | oc apply -n $NS -f -
oc -n $NS wait certificate/mq-test-producer certificate/mq-test-consumer \
  --for=condition=Ready --timeout=120s

umask 077
mkdir -p certs
for r in producer consumer; do
  for k in tls.crt tls.key; do
    oc -n $NS get secret mq-test-$r-tls -o jsonpath="{.data.${k//./\\.}}" | base64 -d > certs/$r.${k#tls.}
  done
done
# CA that signed the client certificates: completes the chain in the keystore
oc -n $NS get secret mq-test-producer-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/clients-ca.crt
oc -n $NS get secret $SERVER_CA_SECRET -o jsonpath='{.data.ca\.crt}' | base64 -d > certs/servers-ca.crt
ls -l certs
