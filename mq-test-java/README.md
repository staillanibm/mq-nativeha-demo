# mq-test-java — JMS Producer/Consumer for IBM MQ Native HA Validation

A minimal Java JMS client pair used to validate the IBM MQ Native HA queue
manager deployed from the parent repo's `manifests/` directory: one process
continuously produces sequenced messages, another continuously consumes them,
and their logs are used to verify that automatic client reconnection works and
that message ordering survives a Native HA leader failover.

Both roles share the same code and the same container image; only the `ROLE`
environment variable differs.

Layout: `kube/` holds the OpenShift manifests (in-cluster deployment, described
below), [`cli/`](cli/README.md) runs the same client from a workstation or a VM,
and [`../mq-test-hac/`](../mq-test-hac/kube/README.md) does the same test with
the MQ sample programs instead of this Java client.

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
  `SSLSocketFactory` must be set explicitly on the `MQConnectionFactory`. The
  client certificate carries the role in its `OU` (`OU=producer` /
  `OU=consumer`, see `kube/03-certs.yaml`); the queue manager maps that
  `OU` to the corresponding MQ identity, so the role is conveyed entirely by the
  certificate — the Java code is identical for both roles and never references
  the DN.
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
from a binary `BuildConfig` (`kube/01-build.yaml`) that takes this
directory as its Docker build context, so no local Maven or Docker
installation is required.

## Building without Internet access (air-gapped)

The in-cluster build above needs two things from the Internet:

| Step                    | Fetched from                                   | What                                                                 |
|-------------------------|------------------------------------------------|----------------------------------------------------------------------|
| `FROM` (both stages)    | `registry.access.redhat.com`                   | `ubi9/openjdk-17` (build) and `ubi9/openjdk-17-runtime` (runtime)    |
| `RUN mvn package`       | Maven Central (`repo.maven.apache.org`)        | the Maven plugins and `com.ibm.mq:com.ibm.mq.allclient`              |

On a cluster without Internet access, the build fails with an error such as
`Unknown host repo.maven.apache.org` or an image pull error. Pick one of the
options below; the rest of the [test procedure](#test-procedure) is unchanged.

### Base images

All options need at least `ubi9/openjdk-17-runtime` (option B also needs
`ubi9/openjdk-17`). If the cluster already mirrors `registry.access.redhat.com`
(`ImageTagMirrorSet`), there is nothing to do. Otherwise copy the images into a
registry the cluster can reach, from a machine that can reach both:

```sh
skopeo copy --all \
  docker://registry.access.redhat.com/ubi9/openjdk-17-runtime:latest \
  docker://registry.example.internal/ubi9/openjdk-17-runtime:latest
```

and replace `registry.access.redhat.com` with your registry in the `FROM`
lines of the `Dockerfile` you use.

### Option A — prebuilt jar, no Maven in the cluster (recommended)

The fat jar is attached to the GitHub release
[`mq-test-java-v1.0.0`](https://github.com/staillanibm/mq-nativeha-demo/releases/tag/mq-test-java-v1.0.0)
(`mq-test-1.0.0.jar` and its `.sha256`). Download both on a connected machine,
or build the jar yourself there with `mvn -q package` (it produces
`target/mq-test-jar-with-dependencies.jar`), and bring the jar to a
workstation logged into the cluster. Then build a runtime-only image with the
same `BuildConfig`:

```sh
shasum -a 256 -c mq-test-1.0.0.jar.sha256

mkdir airgap-build
cp mq-test-1.0.0.jar airgap-build/mq-test.jar
cat > airgap-build/Dockerfile <<'EOF'
FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /app
COPY mq-test.jar ./mq-test.jar
ENTRYPOINT ["java", "-jar", "mq-test.jar"]
EOF

oc start-build mq-test -n mq-test --from-dir=airgap-build --follow
```

`oc start-build --from-dir` uploads the directory from the workstation to the
cluster, so only the runtime base image has to be reachable from the cluster.
This command replaces [step 2](#2-build-the-image).

### Option B — internal Maven repository (Nexus, Artifactory)

If an internal repository proxies Maven Central, keep the source build and point
Maven at it. Create `settings.xml` in this directory:

```xml
<settings>
  <mirrors>
    <mirror>
      <id>internal</id>
      <mirrorOf>*</mirrorOf>
      <url>https://nexus.example.internal/repository/maven-public/</url>
    </mirror>
  </mirrors>
  <!-- Only if the repository requires authentication:
  <servers>
    <server><id>internal</id><username>...</username><password>...</password></server>
  </servers>
  -->
</settings>
```

and change the build stage of the `Dockerfile` to use it:

```dockerfile
COPY --chown=185:0 settings.xml .
RUN mvn -q -B -s settings.xml package
```

If the cluster reaches the Internet through an HTTP proxy instead, keep the
`Dockerfile` unchanged and pass the proxy to Maven:
`RUN mvn -q -B -Dhttps.proxyHost=<host> -Dhttps.proxyPort=<port> package`.
Then run [step 2](#2-build-the-image) as usual.


## Test procedure

All commands assume `oc` is logged into the target cluster and the queue
manager described in the parent repo's `manifests/` directory is already
`Running`.

### 1. Create the namespace, build pipeline, and certificates

```sh
cd mq-test-java
oc apply -f kube/00-namespace.yaml
oc apply -f kube/01-build.yaml
oc apply -f kube/02-secrets.yaml
oc apply -f kube/03-certs.yaml
```

Wait for the three client certificates to be issued:

```sh
oc wait --for=condition=Ready certificate/mq-test-producer certificate/mq-test-consumer certificate/mq-server-truststore -n mq-test --timeout=60s
```

### 2. Build the image

```sh
oc start-build mq-test -n mq-test --from-dir=. --follow
```

Without Internet access from the cluster, see
[Building without Internet access](#building-without-internet-access-air-gapped).

This must be re-run any time the Java source or `Dockerfile` changes — the
running Deployments use `imagePullPolicy: Always` but only pick up a new image
on pod restart, not automatically.

### 3. Ensure TEST.QUEUE exists on the queue manager

The parent repo's `manifests/15-mqsc-configmap.yaml` only defines the
`TEST.SVRCONN` channel, CHLAUTH mappings, and AUTHREC grants — it does not
define `TEST.QUEUE` itself. If it doesn't already exist, create it directly
on the running queue manager:

```sh
oc exec -n ibm-mq mq-nativeha-ibm-mq-0 -- bash -c "
echo \"DEFINE QLOCAL('TEST.QUEUE') REPLACE DESCR('Application test queue for producer/consumer testing')\" | runmqsc MQNATIVEHA
"
```

Without this, the producer and consumer fail immediately on startup with
`MQRC_UNKNOWN_OBJECT_NAME` (2085) and crash-loop.

### 4. Point the apps at the queue manager and deploy

Edit `kube/04-config.yaml` if needed — in particular `MQ_HOST` (the
queue manager's Route hostname) and `MQ_QMGR` (the queue manager name) must
match your cluster:

```sh
oc get route mq-nativeha-ibm-mq-qm -n ibm-mq -o jsonpath='{.spec.host}'
```

Then:

```sh
oc apply -f kube/04-config.yaml
oc apply -f kube/05-producer.yaml
oc apply -f kube/06-consumer.yaml
```

### 5. Confirm both are connected and exchanging messages

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

### 6. Trigger a Native HA failover and validate ordering

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

### 7. Validate ordering quantitatively

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

### 8. Tear down the producer and consumer

Scale both Deployments to zero to stop message flow without deleting them
(config, certs, and Deployment specs are kept, so scaling back up to 1
resumes the test):

```sh
oc scale deployment/mq-test-producer -n mq-test --replicas=0
oc scale deployment/mq-test-consumer -n mq-test --replicas=0
```
