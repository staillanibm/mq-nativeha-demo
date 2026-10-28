#!/usr/bin/env bash
# Usage: ./producer.sh      (config: .env)
cd "$(dirname "$0")" || exit 1
set -a; . ./.env; set +a
ROLE=producer MQ_KEYSTORE_PATH="${MQ_KEYSTORE_PATH:-certs/producer.p12}" \
  exec java -Dcom.ibm.msg.client.commonservices.log.outputName=/dev/null \
            -jar target/mq-test-cli.jar
