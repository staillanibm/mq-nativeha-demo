#!/bin/bash
# Local version of run-producer.sh (hac-scripts ConfigMap, 02-config.yaml): same
# logic, same output. One amqsputc per message, a failed put is retried with the
# same number.
# Configuration: .env (MQ_HOME, QMGR, QUEUE, ...), overridable from the environment.
. "$(dirname "$(readlink -f "$0")")/config/env.sh" producer || exit 1
delay_ms=$PRODUCE_DELAY_MS
pause=$(printf '%d.%03d' $((delay_ms / 1000)) $((delay_ms % 1000)))
i=0
while true; do
  i=$((i + 1))
  until out=$(echo "Message $i" | amqsputc "$QUEUE" "$QMGR" 2>&1) &&
        ! grep -q "ended with reason code" <<< "$out"; do
    echo "$(date +%T.%3N) put <Message $i> failed, retrying: $(grep 'reason code' <<< "$out" | tr '\n' ' ')"
    sleep 1
  done
  echo "$(date +%T.%3N) put <Message $i>"
  sleep "$pause"
done
