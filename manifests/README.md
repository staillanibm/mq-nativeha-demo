# IBM MQ Native HA — Declarative Manifests

This directory contains the full configuration-as-code for an IBM MQ Native HA
queue manager on OpenShift, including a mutual-TLS IAM model with fine-grained
per-queue authorization. 

Domain names, namespaces and entitlement keys are cluster-specific — replace
them before reuse.

## Apply order

| File | Purpose |
|---|---|
| `00-mq-operator-csv.yaml` | Subscribes to the IBM MQ Operator. |
| `01-root-ca-issuer.yaml` | Self-signed root `ClusterIssuer`, used only to bootstrap the Servers CA. |
| `02-server-ca-cert.yaml` | `servers-ca-issuer` ClusterIssuer + its CA `Certificate` — signs the queue manager's server certificate. |
| `03-clients-ca-cert.yaml` | `clients-ca-issuer` ClusterIssuer + its CA `Certificate` — signs client (producer/consumer) certificates. |
| `10-mq-namespace.yaml` | The `ibm-mq` namespace. |
| `11-pull-secret.yaml` | IBM entitlement key, used by the operator to pull MQ images. |
| `12-qm-cert.yaml` | Queue manager's server certificate (CN=`mq-nativeha`, SANs include the OpenShift router wildcard so the app channel works through a passthrough Route). |
| `13-clients-ca-trust.yaml` | Imports the Clients CA's public certificate into the namespace, for the queue manager to trust client certificates. |
| `14-ini-configmap.yaml` | `qm.ini` stanza enabling `SecurityPolicy=UserExternal` — the linchpin of the IAM model, see below. |
| `15-mqsc-configmap.yaml` | MQSC: queue/channel definitions, `CHLAUTH` cert-to-user mapping, and per-user `AUTHREC` queue authorizations. |
| `16-queuemanager.yaml` | The `QueueManager` CR itself — Native HA, TLS, `pki.keys`/`pki.trust`, `ini`, and `mqsc` are all wired in from creation. |

`ini` and `mqsc` are only re-applied by the operator when the queue manager
(re)starts. If you edit `14-ini-configmap.yaml` or `15-mqsc-configmap.yaml`
after the QueueManager already exists, the operator must roll the pods for the
change to take effect — there is no live reload. Don't `oc rollout restart` the
StatefulSet directly (that bypasses the operator); instead trigger the roll
through the `QueueManager` CR by bumping an annotation, e.g.:

```bash
oc annotate queuemanager mq-nativeha -n ibm-mq \
  mq.ibm.com/restartedAt="$(date -u +%FT%TZ)" --overwrite
```

The operator detects the change and performs an ordered, quorum-aware rolling
update — restarting the pods one at a time and waiting for each to rejoin as a
`REPLICA` before continuing.

### Generating `11-pull-secret.yaml`

This file is gitignored (it contains your IBM entitlement key) — a redacted
`11-pull-secret.yaml.example` is checked in instead. Generate the real file
with `oc`/`kubectl`, which produces the correctly base64-encoded
`.dockerconfigjson` (including the `auth` field) without any manual encoding:

```bash
oc create secret docker-registry ibm-entitlement-key \
  --docker-server=cp.icr.io \
  --docker-username=cp \
  --docker-password=<YOUR_ENTITLEMENT_KEY> \
  --namespace=ibm-mq \
  --dry-run=client -o yaml > 11-pull-secret.yaml
```

`--dry-run=client -o yaml` renders the manifest locally without touching the
cluster, so it's safe to redirect straight to the file. The entitlement key
(used as `--docker-password`) is retrieved from the
[IBM Container Software Library](https://myibm.ibm.com/products-services/containerlibrary).

## IAM model: certificate-based authentication + fine-grained authorization

The goal: each client authenticates using the mutual-TLS certificate it
presents (no shared password, no CCDT-embedded secret), and is then restricted
to exactly the queue operations its role needs (producer = `PUT` only,
consumer = `GET`/`BROWSE` only) — **without** relying on anything that would
require changing the OpenShift `restricted-v2` SCC: no fixed/predictable UID,
no custom OS users baked into the image, no `group 0` authorization grants,
and no external LDAP directory.

### 1. Authentication — CHLAUTH SSLPEERMAP

`TEST.SVRCONN` requires client certificates (`SSLCAUTH(REQUIRED)`). Two
`CHLAUTH` records (`15-mqsc-configmap.yaml`) map the client certificate's
Subject DN to an MQ user identity (`MCAUSER`):

```
SET CHLAUTH('TEST.SVRCONN') TYPE(ADDRESSMAP) ADDRESS('*') USERSRC(NOACCESS) ...
SET CHLAUTH('TEST.SVRCONN') TYPE(SSLPEERMAP) SSLPEER('CN=mq-test-producer') USERSRC(MAP) MCAUSER('app-producer') ...
SET CHLAUTH('TEST.SVRCONN') TYPE(SSLPEERMAP) SSLPEER('CN=mq-test-consumer') USERSRC(MAP) MCAUSER('app-consumer') ...
```

The first record denies everyone by default; only a client presenting a
certificate whose CN is exactly `mq-test-producer` or `mq-test-consumer` is
let in, and is assigned the corresponding `MCAUSER`. The certificates
themselves are signed by `clients-ca-issuer` (`03-clients-ca-cert.yaml`; the
client certificates for the producer/consumer test apps are not included in
this directory — see the `mq-test` Java client manifests). The queue manager
trusts that CA via `13-clients-ca-trust.yaml` and `spec.pki.trust` in
`16-queuemanager.yaml`.

This is purely an *identity* decision: it says who the client is, not what
it's allowed to do.

### 2. Authorization — per-MCAUSER AUTHREC

Once mapped to `app-producer` or `app-consumer`, the Object Authority Manager
(OAM) decides what each identity can do, via explicit `AUTHREC` grants:

```
SET AUTHREC PRINCIPAL('app-producer') OBJTYPE(QMGR) AUTHADD(CONNECT,INQ)
SET AUTHREC PROFILE('TEST.QUEUE') PRINCIPAL('app-producer') OBJTYPE(QUEUE) AUTHADD(PUT)

SET AUTHREC PRINCIPAL('app-consumer') OBJTYPE(QMGR) AUTHADD(CONNECT,INQ)
SET AUTHREC PROFILE('TEST.QUEUE') PRINCIPAL('app-consumer') OBJTYPE(QUEUE) AUTHADD(GET,BROWSE,INQ)
```

`app-producer` can only `PUT` to `TEST.QUEUE`; it cannot `GET` or `BROWSE` it.
`app-consumer` can only `GET`/`BROWSE`/`INQ`; it cannot `PUT`. Neither has any
authority over any other queue. This is standard MQ least-privilege practice —
the only unusual part is *who* `app-producer`/`app-consumer` are to the OAM.

### 3. The constraint: no OS users, no LDAP, no group 0

By default, the MQ OAM resolves an `AUTHREC PRINCIPAL` against the **local OS
user/group registry inside the queue manager's container**. `app-producer` and
`app-consumer` are not real OS accounts — and under OpenShift's `restricted-v2`
SCC, the container runs with a random, non-deterministic UID assigned by
OpenShift per namespace, with no ability to bake fixed UIDs or extra OS users
into the image. The two usual workarounds were both ruled out:

- Granting authority to `GROUP('root')` (GID 0, which every `restricted-v2`
  pod belongs to) technically works, but defeats the purpose of fine-grained
  authorization — every identity in the container ends up in the same
  all-powerful group.
- Pointing the OAM at an external LDAP directory works, but is an unwanted
  extra dependency, the opposite of a self-contained, cloud-native deployment.

### 4. The mechanism: `SecurityPolicy=UserExternal`

`14-ini-configmap.yaml` sets a `qm.ini` `Service` stanza:

```ini
Service:
   Name=AuthorizationService
   SecurityPolicy=UserExternal
```

Available since MQ 9.3, this tells the OAM to accept `AUTHREC` principals that
have no corresponding OS account — as long as the name is a valid MQ user name
(≤ 12 characters, which `app-producer`/`app-consumer` satisfy). Such "external"
users are treated as belonging to no group except an implicit `nobody`, so
authority must be granted explicitly per principal — which is exactly the
fine-grained model required here. This is the one setting that makes
certificate-mapped, per-role MQ authorization possible with zero OS user
provisioning, zero LDAP, and zero `restricted-v2` SCC changes.

Because `SecurityPolicy` is only read when the queue manager (re)starts, and a
manual edit on a running pod is wiped out on the next Native HA failover (the
operator regenerates `qm.ini` from the ConfigMap), this must always be set via
`spec.queueManager.ini` from the queue manager's creation — not patched in
later.

### 5. Toward a more dynamic model

As implemented, identities are static — one `SSLPEERMAP` and one `AUTHREC` set
per client, baked into the MQSC ConfigMap. This is a design choice for this demo,
not an MQ-on-Kubernetes constraint: `SET CHLAUTH`/`SET AUTHREC` are dynamic and
the restart only comes from the operator replaying the ConfigMap at boot.

Possible improvements toward a role-based (RBAC) model:

- [ ] Map roles from an attribute of the client cert's DN (e.g. `OU=producer`).
- [ ] Externalize authentication to an external LDAP directory.
- [ ] Externalize authentication to an external IdP via OIDC + JWKS, using a
  token claim to assign the role.

In all cases the operator can still apply `runmqsc` live to add config. Such
config is persisted in the queue manager's data — and replicated across the
Native HA instances — so it is not lost on restart. The caveat is GitOps drift:
the operator replays the ConfigMap MQSC at the next (re)start, so live changes
and the declarative source can diverge. Two ways to handle this:

1. **Reconcile** live changes back into the ConfigMap, keeping it the single
   source of truth for the full configuration.
2. **Draw a clear boundary** between what is managed as config-as-code (the
   stable baseline) and what is managed dynamically at runtime — and never let
   the ConfigMap define the dynamic part, so a replay cannot overwrite it.

## Verifying the IAM configuration

```sh
# Confirm SecurityPolicy is active on the running queue manager
oc exec -n ibm-mq mq-nativeha-ibm-mq-0 -- \
  grep -A2 'Name=AuthorizationService' /mnt/mqm/data/qmgrs/*/qm.ini

# Confirm the per-role authorizations took effect
oc exec -n ibm-mq mq-nativeha-ibm-mq-0 -- bash -c "
echo \"DIS AUTHREC PROFILE('TEST.QUEUE') PRINCIPAL('app-producer')\" | runmqsc mqnativeha
echo \"DIS AUTHREC PROFILE('TEST.QUEUE') PRINCIPAL('app-consumer')\" | runmqsc mqnativeha
"
```

`app-producer` should show `AUTHLIST(PUT)` only; `app-consumer` should show
`AUTHLIST(BROWSE,GET,INQ)` only.
