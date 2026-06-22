# IBM MQ Native HA on OpenShift — Demo

A self-contained, configuration-as-code demo of an **IBM MQ Native HA** queue
manager on OpenShift, secured with a mutual-TLS IAM model (certificate-based
authentication + fine-grained per-queue authorization), together with a Java
JMS client pair used to validate high availability and message ordering across
a Native HA leader failover.

The whole stack is declarative: the queue manager, its certificates, its
security policy, and the test clients are all deployed from YAML manifests via
`oc`/`kubectl` — no manual configuration on the running queue manager.

## Repository layout

| Path | Contents |
|---|---|
| [`manifests/`](manifests/README.md) | The IBM MQ Native HA queue manager: operator subscription, cert-manager issuers/certificates, TLS, the `UserExternal` security policy, and the MQSC queue/channel/CHLAUTH/AUTHREC definitions that implement the IAM model. |
| [`mq-test/`](mq-test/README.md) | A minimal Java JMS producer/consumer pair (shared code and image, role selected by env var) plus its build pipeline and deployment manifests, used to verify automatic client reconnection and message ordering through a failover. |

Each directory has its own README with the full design rationale and
step-by-step instructions — start there for details.

## Highlights

- **Native HA** — three-replica queue manager with automatic leader election;
  clients reconnect transparently via the MQ client library's built-in
  automatic reconnection.
- **Certificate-based authentication** — `CHLAUTH SSLPEERMAP` maps each
  client's TLS certificate Subject DN to an MQ identity; no shared passwords or
  CCDT-embedded secrets.
- **Fine-grained authorization** — per-principal `AUTHREC` grants restrict the
  producer to `PUT` and the consumer to `GET`/`BROWSE` on `TEST.QUEUE`.
- **No OS users, no LDAP, no `group 0`** — `SecurityPolicy=UserExternal`
  (MQ 9.3+) lets the OAM authorize certificate-mapped principals that have no
  backing OS account, all within OpenShift's `restricted-v2` SCC.
- **End-to-end TLS** — mutual TLS through an OpenShift passthrough Route, with
  the SNI handling required to make the MQ app channel work through the router.

## Quick start

All steps assume `oc` is logged into the target OpenShift cluster.
Domain names, namespaces, and the IBM entitlement key are cluster-specific —
replace them before reuse.

1. **Deploy the queue manager** — follow [`manifests/README.md`](manifests/README.md)
   to subscribe the operator, generate certificates, and apply the
   `QueueManager` CR. Wait until the queue manager is `Running`.
2. **Run the validation clients** — follow [`mq-test/README.md`](mq-test/README.md)
   to build the image in-cluster, deploy the producer/consumer, trigger a
   Native HA failover, and confirm message ordering is preserved.

## Prerequisites

- An OpenShift cluster with the IBM MQ Operator available and
  [cert-manager](https://cert-manager.io/) installed.
- An IBM entitlement key from the
  [IBM Container Software Library](https://myibm.ibm.com/products-services/containerlibrary)
  to pull the MQ images.
- `oc` (or `kubectl`) configured for the cluster.

No local Maven, Docker, or JDK is required — the test client image is built
in-cluster from a binary `BuildConfig`.

## License

Licensed under the [Apache License 2.0](LICENSE).
