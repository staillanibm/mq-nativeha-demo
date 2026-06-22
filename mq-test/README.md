# mq-test — JMS Producer/Consumer for IBM MQ Native HA Validation

A minimal Java JMS client pair used to validate the IBM MQ Native HA queue
manager deployed from the parent repo's `manifests/` directory: one process
continuously produces sequenced messages, another continuously consumes them,
and their logs are used to verify that automatic client reconnection works and
that message ordering survives a Native HA leader failover.

Both roles share the same code and the same container image; only the `ROLE`
environment variable differs.

## Design

### Connectivity

The client connects to the queue manager as an MQ *client* (not bindings
mode) over `TEST.SVRCONN`, through the OpenShift Route exposing the queue
manager's app channel (passthrough TLS on port 443). See
`MqConnectionFactoryBuilder.java`:

- `WMQ_CM_CLIENT` transport, host/port/channel/queue manager all from config.
- **mutual TLS**: the connection factory is given an explicit `SSLSocketFactory`
  built from a PKCS12 keystore (this client's own certificate + key) and a
  PKCS12 truststore (the Servers CA, to validate the queue manager's
  certificate). This is necessary because IBM's MQ JMS classes build their own
  `SSLContext` internally and **ignore** the JVM's `javax.net.ssl.*` system
  properties — setting the trust/key store via `-D` flags has no effect; the
  `SSLSocketFactory` must be set explicitly on the `MQConnectionFactory`.
- `SSLContext.getInstance("TLS")` is used rather than `"TLSv1.2"` — the latter
  is rejected by the IBM MQ client at handshake time.
- **automatic client reconnection** is enabled
  (`WMQ_CLIENT_RECONNECT_OPTIONS=WMQ_CLIENT_RECONNECT`,
  `WMQ_CLIENT_RECONNECT_TIMEOUT`): on a broken connection (e.g. the Native HA
  leader pod is deleted), the MQ client library transparently retries and
  reconnects once a new leader has been elected and is reachable through the
  same Route, with no application-level retry logic needed.

### The SNI subtlety

`Main.java` sets `com.ibm.mq.cfg.SSL.outboundSNI=HOSTNAME` before anything
else runs. By default the MQ client sends the **channel name** as the TLS SNI
value, not the hostname it is connecting to. That default works for a direct
TCP connection to the queue manager, but breaks when going through an
OpenShift Route: the router uses SNI to decide which backend Service to send
the passthrough connection to, and a channel name doesn't match any route
host, so it falls back to the default certificate. Setting
`outboundSNI=HOSTNAME` makes the client send the actual connection hostname as
SNI, which the route can match against `manifests/12-qm-cert.yaml`'s wildcard
SAN.

### Producer (`Producer.java`)

Sends one persistent `TextMessage` per second (`SEND_INTERVAL_MILLIS`) to
`TEST.QUEUE`, body `seq=<n> ts=<ISO-8601 UTC> sender=producer`, with `seq` also
set as a JMS long property (read directly by the consumer, instead of parsing
the body). On a send failure, the sequence number is **not** incremented, so
the same `seq` is retried rather than silently skipped — gaps in the consumed
sequence therefore indicate genuine message loss, not retry numbering. A send
taking more than 2 seconds is logged as `SENT ... (slow send, likely failover
in progress)`.

### Consumer (`Consumer.java`)

Receives with a 5-second timeout in a loop and tracks the last `seq` seen to
detect, per message:

- `FIRST_MESSAGE` — first message of the run.
- `ORDER_VIOLATION` — `seq` ≤ last seen `seq` (out-of-order or duplicate).
- `GAP_DETECTED` — `seq` jumped ahead, some sequence numbers are missing
  (message loss).
- a normal `RECEIVED` log otherwise, annotated with `gapMillis` since the
  previous message — a gap over 3 seconds is flagged as "gap suggests
  reconnection/failover happened", since that's the expected latency signature
  of a Native HA leader election.
- `NO_MESSAGE idleMillis=...` if a 5-second receive times out with nothing
  delivered for over 5 seconds total — another possible failover signal if it
  coincides with the producer also stalling.

There is no JMS exception-driven reconnect logic in either class — both rely
entirely on the MQ client library's built-in automatic reconnection
(`WMQ_CLIENT_RECONNECT`), and `setExceptionListener` is only used to log
`CONNECTION_EXCEPTION` for visibility, not to drive any retry behavior.

### Build and image

A multi-stage `Dockerfile`: `ubi9/openjdk-17` to run `mvn package`
(`maven-assembly-plugin` produces a single `mq-test-jar-with-dependencies.jar`
via `com.ibm.mq:com.ibm.mq.allclient`), then `ubi9/openjdk-17-runtime` for the
final image. There is no local build step — the image is built **in-cluster**
from a binary `BuildConfig` (`manifests/01-build.yaml`) that takes this
directory as its Docker build context, so no local Maven or Docker
installation is required.

## Test procedure

All commands assume `oc` is logged into the target cluster and the queue
manager described in the parent repo's `manifests/` directory is already
`Running`.

### 1. Create the namespace, build pipeline, and certificates

```sh
cd mq-test
oc apply -f manifests/00-namespace.yaml
oc apply -f manifests/01-build.yaml
oc apply -f manifests/02-secrets.yaml
oc apply -f manifests/03-certs.yaml
```

Wait for the three client certificates to be issued:

```sh
oc wait --for=condition=Ready certificate/mq-test-producer certificate/mq-test-consumer certificate/mq-server-truststore -n mq-test --timeout=60s
```

### 2. Build the image

```sh
oc start-build mq-test -n mq-test --from-dir=. --follow
```

This must be re-run any time the Java source or `Dockerfile` changes — the
running Deployments use `imagePullPolicy: Always` but only pick up a new image
on pod restart, not automatically.

### 3. Point the apps at the queue manager and deploy

Edit `manifests/04-config.yaml` if needed — in particular `MQ_HOST` (the
queue manager's Route hostname) and `MQ_QMGR` (the queue manager name) must
match your cluster:

```sh
oc get route mq-nativeha-ibm-mq-qm -n ibm-mq -o jsonpath='{.spec.host}'
```

Then:

```sh
oc apply -f manifests/04-config.yaml
oc apply -f manifests/05-producer.yaml
oc apply -f manifests/06-consumer.yaml
```

### 4. Confirm both are connected and exchanging messages

```sh
oc get pods -n mq-test -l 'app in (mq-test-producer,mq-test-consumer)'
oc logs -n mq-test deployment/mq-test-producer --tail=20
oc logs -n mq-test deployment/mq-test-consumer --tail=20
```

You should see matching `SENT seq=N` / `RECEIVED seq=N ...` pairs advancing
together, no `SEND_FAILED`, `ORDER_VIOLATION`, or `GAP_DETECTED`.

If the consumer fails with `MQRC_NOT_AUTHORIZED` (2035) or the producer fails
with a TLS handshake error, see the IAM and TLS sections of the parent repo's
`manifests/README.md` — the queue manager-side configuration is the most
likely cause, not this client.

### 5. Trigger a Native HA failover and validate ordering

Identify the current leader (the only `1/1 Ready` pod) and delete it:

```sh
oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha
oc delete pod <leader-pod-name> -n ibm-mq
```

Watch both logs through the failover:

```sh
oc logs -n mq-test deployment/mq-test-producer -f
oc logs -n mq-test deployment/mq-test-consumer -f
```

Expect, in order: a `CONNECTION_EXCEPTION` or a slow `SENT` on the producer
side, a `NO_MESSAGE idleMillis=...` on the consumer side, then message flow
resuming once a new leader is elected — with no `ORDER_VIOLATION` or
`GAP_DETECTED` on the consumer once it catches up. A `RECEIVED ...
gapMillis=...` line over 3000 ms marks where the failover happened in the
sequence.

### 6. Validate ordering quantitatively

Extract the consumed sequence numbers and check for gaps or out-of-order
transitions:

```sh
oc logs -n mq-test deployment/mq-test-consumer | grep RECEIVED | \
  sed -n 's/.*seq=\([0-9]*\).*/\1/p' > /tmp/seqs.txt

python3 -c "
seqs = [int(x) for x in open('/tmp/seqs.txt')]
print('received:', len(seqs), 'range:', min(seqs), '-', max(seqs))
bad = [(seqs[i], seqs[i+1]) for i in range(len(seqs)-1) if seqs[i+1] != seqs[i]+1]
print('gaps/out-of-order transitions:', bad)
"
```

`bad` should be empty: every sequence number from the first to the last
received appears exactly once, in order, regardless of how many times the
Native HA leader failed over during the run.
