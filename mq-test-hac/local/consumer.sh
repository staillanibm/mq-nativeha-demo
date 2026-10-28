#!/bin/bash
# Local version of run-consumer.sh (hac-scripts ConfigMap, 02-config.yaml): same
# logic, same output. dmpmqmsg -I gets the messages of the queue, restarted when
# it stops; the awk filter checks the "Message <n>" counter (CHECK: lines).
# Configuration: .env (MQ_HOME, QMGR, QUEUE, ...), overridable from the environment.
# Needs gawk (match() with an array) and stdbuf (coreutils).
. "$(dirname "$(readlink -f "$0")")/config/env.sh" consumer || exit 1
delay=()
[ "$CONSUME_DELAY_MS" -gt 0 ] && delay=(-D "$CONSUME_DELAY_MS")
while true; do
  stdbuf -oL dmpmqmsg -c -m "$QMGR" -I "$QUEUE" -f stdout \
      -dtHN -q -w 15 -t 1 "${delay[@]}" 2>&1
  echo "dmpmqmsg ended (rc=$?), restarting" >&2
  sleep 1
done |
  grep --line-buffered -E '^(T |.*(AMQ|MQ[A-Z]+|rror|ended))' |
  while IFS= read -r line; do echo "$(date +%T.%3N) $line"; done |
  stdbuf -oL awk '
    { print }
    match($0, /T Message ([0-9]+)$/, m) {
      ts = $1
      n = m[1] + 0
      if (!last && n != 1)     printf "%s CHECK: first message seen is %d, not 1\n", ts, n
      if (n == 1 && last > 1)  print ts, "CHECK: counter back at 1 (producer restarted, or messages replayed)"
      else if (last && n > last + 1)  printf "%s CHECK: GAP, expected %d got %d (%d missing)\n", ts, last + 1, n, n - last - 1
      else if (last && n <= last)     printf "%s CHECK: DUPLICATE/OUT OF ORDER, expected %d got %d\n", ts, last + 1, n
      last = n
    }
    { fflush() }'
