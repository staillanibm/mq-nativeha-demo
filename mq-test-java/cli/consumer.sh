#!/usr/bin/env bash
# Usage: ./consumer.sh      (config: .env)
cd "$(dirname "$0")" || exit 1
set -a; . ./.env; set +a
ROLE=consumer MQ_KEYSTORE_PATH="${MQ_KEYSTORE_PATH:-certs/consumer.p12}" \
  exec java -Dcom.ibm.msg.client.commonservices.log.outputName=/dev/null \
            -jar target/mq-test-cli.jar
