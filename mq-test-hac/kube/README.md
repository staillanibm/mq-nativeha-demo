# mq-test-hac / kube

Failover test of the Native HA queue manager (`ibm-mq/mq-nativeha`) using the
sample programs shipped with IBM MQ, instead of a custom application:

| Deployment     | Program    | Role                                                              |
|----------------|------------|-------------------------------------------------------------------|
| `hac-producer` | `amqsputc` | Puts one persistent message every `PRODUCE_DELAY_MS` (2s), retrying a failed put |
| `hac-consumer` | `dmpmqmsg` | Gets the messages with an optional delay between each, and checks the counter |

Both log to the console and connect through the queue manager Route with mutual TLS
on `TEST.SVRCONN` (client certificate `OU=producer` / `OU=consumer`).

## Prerequisites

1. cert-manager with the `clients-ca-issuer` and `servers-ca-issuer` ClusterIssuers.
2. The queue `TEST.QUEUE` on the queue manager, with `DEFPSIST(YES)`: the producer
   relies on it to send persistent messages (`PUT` for `app-producer` and
   `GET`,`BROWSE`,`INQ` for `app-consumer` come from the `TEST.*` AUTHREC):

       DEFINE QLOCAL('TEST.QUEUE') REPLACE MAXDEPTH(100000) DEFPSIST(YES)

## Deploy

Everything is deployed in the queue manager namespace, `ibm-mq`, from this directory:

    oc -n ibm-mq create secret generic keystore-password \
      --from-literal=password="$(openssl rand -hex 12)"
    oc apply -f .

## Run the failover test

    oc -n ibm-mq logs -f deploy/hac-producer
    oc -n ibm-mq logs -f deploy/hac-consumer
    oc -n ibm-mq get pods -w

    # find and kill the active instance
    oc -n ibm-mq exec mq-nativeha-ibm-mq-0 -- dspmq -o nativeha -x
    oc -n ibm-mq delete pod <active-pod>

- The producer prints `put <Message n>`; a put that fails during the failover is
  retried with the same number (`failed, retrying: MQCONNX ended with reason code 2393`
  while the queue manager is unreachable).
- The consumer prints every message (`T Message n`) with a timestamp, and the
  errors of `dmpmqmsg` (it is restarted by the script if it stops during the
  failover). It also checks the counter and prints `CHECK:` lines on a gap, a
  duplicate, a producer restart, or when the first message it sees is not 1:

      oc -n ibm-mq logs deploy/hac-consumer | grep -E 'AMQ|ended|CHECK'

Both rates are set by environment variables (`set env` restarts the pod):

    oc -n ibm-mq set env deploy/hac-producer PRODUCE_DELAY_MS=500    # faster producer
    oc -n ibm-mq set env deploy/hac-consumer CONSUME_DELAY_MS=1000   # slower consumer

A producer restart resets its counter, so the consumer prints one
`CHECK: counter restarted at 1`.

To test that persistent messages survive a failover, slow the consumer down with
`CONSUME_DELAY_MS` (delay in ms between two messages, 0 = none) so that messages
pile up on the queue, kill the active pod, then set the delay back to 0 to drain
the queue:

    oc -n ibm-mq set env deploy/hac-consumer CONSUME_DELAY_MS=10000
    # ... wait for a backlog, kill the active pod ...
    oc -n ibm-mq set env deploy/hac-consumer CONSUME_DELAY_MS=0

`set env` restarts the consumer. `CHECK: first message seen is N, not 1` is
expected if the consumer had already read the first messages; look for `GAP`
and `DUPLICATE`.

## Expected results

A failover on a queue holding persistent messages must give **no `GAP`**: a
message is never lost. Up to one `DUPLICATE` on the consumer side, and one on the
producer side, is normal (at-least-once delivery):

- **Consumer.** For each message `dmpmqmsg` gets it (one unit of work per message,
  `-t 1`), prints it, then commits. If the connection is cut between the print and
  the commit, the queue manager rolls the get back and the message is delivered
  again after the reconnection. Example, with the active pod killed at 16:35:07:

      16:35:07.055 T Message 37
      16:35:07.062 MQBACK failed RC(2009) Connection Broken
      16:35:08.433 MQCONNX on object 'MQNATIVEHA' returned 2393 SSL Initialization Error.
      ...
      16:35:20.778 T Message 37
      16:35:20.778 CHECK: DUPLICATE/OUT OF ORDER, expected 38 got 37
      16:35:22.790 T Message 38

  Committing before printing would avoid the duplicate but lose the message if
  the connection is cut in between, which is worse for persistent messages: an
  application consuming from MQ has to tolerate duplicates (idempotent
  processing, for example by discarding a number it has already seen, as the
  `CHECK` does here).
- **Producer.** A put interrupted by the failover is retried with the same number
  (`failed, retrying`). If the queue manager had stored the message before the
  connection was cut, the retry makes a duplicate.
- `MQCONNX ... 2393` repeated for several seconds is the clients trying to
  reconnect while the new active instance takes over; it is not an error of the
  test.
- Without `-t 1`, `dmpmqmsg` reads the whole queue in a single unit of work and
  commits only when the queue stays empty: a failover then rolls back and replays
  every message read since the start (`CHECK: counter back at 1`).

## Notes

- `dmpmqmsg` is the MQ queue load/unload utility: `-I` gets the messages
  (destructively), `-D` sets the delay between two of them, and `-t 1` commits
  each message separately (by default nothing is committed until the queue stays
  empty, and a failover would replay every message read since the start). It does not print
  reconnection events, unlike `amqsghac`, which cannot be slowed down.
- `amqsphac` is not used because it hard-codes non-persistent messages, which
  Native HA does not replicate.
- `02-config.yaml` hardcodes the Route hostname of the cluster; update it if the
  cluster domain changes.
- The MQI samples need a CMS keystore: an init container converts the PKCS12
  keystore generated by cert-manager into `key.kdb` (`build-kdb.sh` in the
  `hac-scripts` ConfigMap, which also holds the launchers of the samples).
- `hac-mqclient-ini` sets `OutboundSNI=HOSTNAME` (without it the MQI client sends
  a channel-derived SNI that the router has no Route for) and `DefRecon=YES`.

To run the same producer and consumer from a workstation or a VM instead, see [`../cli`](../cli/README.md). The same test with a custom Java client is in [`../../mq-test-java`](../../mq-test-java/README.md).
