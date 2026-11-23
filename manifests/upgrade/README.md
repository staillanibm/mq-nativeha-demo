# Upgrade: IBM MQ 9.4.5.1 → 10.0.0.5 (Native HA, OpenShift)

This directory has the manifests that change for the upgrade of the
`mq-nativeha` queue manager from **MQ 9.4.5.1-r1 (Operator 3.9.2)** to
**MQ 10.0.0.5-r1 (Operator 4.0.4)**. They are full copies of the manifests in
`..`, not patches. Every other manifest stays as it is.

| File | Replaces | What changes |
|---|---|---|
| `00a-mq-catalog-source.yaml` | `../00-mq-operator-csv.yaml` (CatalogSource) | CatalogSource image → 4.0.4 catalog |
| `00b-mq-subscription.yaml` | `../00-mq-operator-csv.yaml` (Subscription) | Subscription channel `v3.9` → `v4.0-sc2` |
| `17-queuemanager.yaml` | `../17-queuemanager.yaml` | `spec.version` → `10.0.0.5-r1`; `spec.license.license` → `L-UMVX-XYNRAD`; `spec.queueManager.image` → 10.0.0.5-r1 digest |

> **The data migration is one-way.** When the queue manager first starts on
> 10.0, it migrates its data (queue files, logs) to the 10.0 format. MQ 9.4
> then refuses to start on these files, and the operator rejects any decrease
> of `spec.version`. Going back to 9.4 therefore means **recreating** the
> queue manager on 9.4 and moving the messages across. See
> [Rollback to 9.4.5.1](#rollback-to-9451).

## Why two steps

The manifests must be applied **in order, waiting between them**:

1. **Operator first**, in two parts. Apply the catalog source first. Change
   the Subscription channel only once the catalog serves `v4.0-sc2`, or OLM
   cannot resolve the channel. Operator 3.9.2 does not know MQ 10.0. A server-side
   dry-run of `17-queuemanager.yaml` against Operator 3.9.2 fails with
   `Supported upgrade versions for 9.4.5.1-r1: []`.
2. **Queue manager second.** Operator 4.0.4 still manages 9.4.5.1-r1 queue
   managers (it lists 9.4.0.0 to 9.4.5.1 as *allowed during migration*). The
   queue manager therefore keeps running unchanged on 9.4 until its CR is
   updated.

You can only move to Operator 4.0.x from **3.9.2** (CD) or 3.2.29 (SC2). This
cluster is already on 3.9.2.

## Prerequisites

Checked on the cluster before the upgrade:

| Prerequisite | Expected | How to check |
|---|---|---|
| Operator version | `ibm-mq.v3.9.2`, `Succeeded` | `oc get csv -n openshift-operators \| grep ibm-mq` |
| Queue manager version | `9.4.5.1-r1` (allowed during migration in 4.0.4) | `oc get qmgr mq-nativeha -n ibm-mq -o jsonpath='{.status.versions.reconciled}'` |
| OpenShift | 4.12 or later | `oc version` |
| Architecture | amd64 | `oc get nodes -o jsonpath='{.items[*].status.nodeInfo.architecture}'` |
| Native HA health | 1 active, 2 replicas `INSYNC(yes)`, `QUORUM(3/3)`, `BACKLOG(0)` | see below |
| Pull secret | `ibm-entitlement-key` in `ibm-mq`, with an entitlement key that covers MQ 10.0 | `oc get secret ibm-entitlement-key -n ibm-mq` |

The active instance can be any of the three pods, and it moves during the
upgrade. MQSC and `dmpmqcfg` only work on the active instance: on a replica
they fail with `AMQ8478E: Standby queue manager`. Only the active instance
passes the readiness probe, so it is the one pod that is Ready. The two
replica pods show `0/1`, which is normal.

Every block below that runs a command on the active instance therefore starts
by looking it up and storing it in `ACTIVE`. Run the whole block, not a
single line: the active instance changes during step 2, and an empty
`ACTIVE` makes `oc exec` fail with `pod, type/name or --filename must be
specified`.

```bash
ACTIVE=$(oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}'); echo "active: $ACTIVE"
oc exec -n ibm-mq "$ACTIVE" -- dspmq -o nativeha -x -m MQNATIVEHA
```

### License

MQ 10.0 uses new license IDs. The 9.4 ID `L-QWBN-T3PKLE` (MQ Advanced for
Non-Production 9.4) is replaced by **`L-UMVX-XYNRAD`** (MQ Advanced for
Non-Production Environment 10.0), still with `use: NonProduction`.

In 10.0, Native HA and Cross-Region Replication are a separate add-on
(`L-KFCR-53UGK9`). The licensing reference only accepts that add-on (through
`spec.license.additionalLicenses`) together with the base **IBM MQ** license
`L-MKDD-7KHY2Q`. MQ Advanced licenses include Native HA, so the add-on is not
set here. For production, use `L-CXDB-XTZ9J8` (MQ Advanced) with
`use: Production`.

### Images

The 9.4 CR pinned the queue manager image by digest
(`spec.queueManager.image`). **The digest must change together with
`spec.version`**: if only the version changes, the pods keep running the 9.4.5.1
image. `17-queuemanager.yaml` pins the 10.0.0.5-r1 digest listed in the
4.0.4 CASE. You can also remove `spec.queueManager.image`, and the operator then
uses its default image for `spec.version`.

To read the image digest from the files that ibm-pak generates in step 1a:

```bash
grep 10.0.0.5-r1 ~/.ibm-pak/data/mirror/ibm-mq/4.0.4/images-mapping.txt
```

On an air-gapped cluster, mirror these images (`oc image mirror -f
images-mapping.txt …`) before step 1b.

## Procedure

### 0. Back up

Back up the queue manager configuration and the live CR:

```bash
ACTIVE=$(oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}'); echo "active: $ACTIVE"
oc exec -n ibm-mq "$ACTIVE" -- dmpmqcfg -m MQNATIVEHA -a > MQNATIVEHA-9.4.5.1.mqsc
oc get qmgr mq-nativeha -n ibm-mq -o yaml > mq-nativeha-cr-9.4.5.1.yaml
```

The configuration is already declarative (`../14-*`, `../15-*`, `../17-*`). The
`dmpmqcfg` dump also captures anything that was changed at runtime. It does
**not** save messages. To keep them, unload the application queues with
`dmpmqmsg`, or take volume snapshots of the three `data-mq-nativeha-ibm-mq-N`
PVCs. Take the snapshots with the queue manager stopped, or they will not be
consistent.

### 1. Upgrade the operator to 4.0.4

#### 1a. Generate and apply the 4.0.4 catalog source

`00a-mq-catalog-source.yaml` is the catalog source that `oc ibm-pak` generates
from the ibm-mq 4.0.4 CASE, copied unchanged apart from a comment header. To
regenerate it, for example after IBM republishes the CASE:

```bash
export OPERATOR_PACKAGE_NAME=ibm-mq OPERATOR_VERSION=4.0.4
oc ibm-pak get $OPERATOR_PACKAGE_NAME --version $OPERATOR_VERSION
oc ibm-pak generate mirror-manifests $OPERATOR_PACKAGE_NAME icr.io --version $OPERATOR_VERSION
cp ~/.ibm-pak/data/mirror/$OPERATOR_PACKAGE_NAME/$OPERATOR_VERSION/catalog-sources.yaml 00a-mq-catalog-source.yaml
```

On an air-gapped cluster, replace `icr.io` with your local registry so that
the generated catalog source points to the mirrored catalog image.

Apply it:

```bash
oc apply -f 00a-mq-catalog-source.yaml
```

This updates the existing `ibmmq-operator-catalogsource` in place (same name)
with the 4.0.4 catalog image. Nothing is upgraded yet, because the
Subscription is still on channel `v3.9`.

Wait for the catalog pod to restart on the new image and for the catalog to
be `READY`. Then check that the package manifest lists the `v4.0-sc2`
channel with `ibm-mq.v4.0.4`:

```bash
oc get pods -n openshift-marketplace | grep ibmmq-operator-catalogsource
oc get catalogsource ibmmq-operator-catalogsource -n openshift-marketplace \
  -o jsonpath='{.spec.displayName}{" "}{.status.connectionState.lastObservedState}{"\n"}'   # ibm-mq-4.0.4 READY
oc get packagemanifest ibm-mq -n openshift-operators \
  -o jsonpath='{range .status.channels[*]}{.name}{" -> "}{.currentCSV}{"\n"}{end}' | grep v4.0   # v4.0-sc2 -> ibm-mq.v4.0.4
```

#### 1b. Move the Subscription to channel v4.0-sc2

```bash
oc apply -f 00b-mq-subscription.yaml
```

Because `installPlanApproval: Automatic` is set, OLM installs the 4.0.4 CSV
in place of the 3.9.2 one straight away. Wait for the new CSV and the
operator pod:

```bash
oc get csv -n openshift-operators -w | grep ibm-mq     # ibm-mq.v4.0.4  Succeeded
oc get pods -n openshift-operators | grep ibm-mq-operator
```

Then check that the queue manager is still healthy and **still on 9.4.5.1**.
The operator upgrade alone should not restart it:

```bash
oc get qmgr mq-nativeha -n ibm-mq \
  -o jsonpath='{.status.phase}{" "}{.status.versions.reconciled}{"\n"}'   # Running 9.4.5.1-r1
oc get pods -n ibm-mq
```

`status.versions.available` should now list `10.0.0.5-r1`:

```bash
oc get qmgr mq-nativeha -n ibm-mq -o jsonpath='{.status.versions.available.versions[*].name}{"\n"}'
```

You can now validate the queue manager manifest against the new operator
without applying it:

```bash
oc apply --dry-run=server -f 17-queuemanager.yaml
```

### 2. Upgrade the queue manager to 10.0.0.5-r1

Check Native HA health once more (all instances in sync, backlog 0), then:

```bash
oc apply -f 17-queuemanager.yaml
```

The operator runs a quorum-aware rolling update. It restarts the two replicas
one at a time on the 10.0 image, waits for each to rejoin and resynchronise,
and restarts the active instance last. Client applications only see that
final failover. Watch it:

```bash
oc get pods -n ibm-mq -w
oc get qmgr mq-nativeha -n ibm-mq -w
```

Don't stay in a mixed 9.4/10.0 state: a 10.0 instance cannot replicate its log
to a 9.4 instance. If the rollout stalls, look at the operator logs
(`oc logs -n openshift-operators deploy/ibm-mq-operator`) and the queue
manager pods. Do not delete pods or PVCs by hand.

### 3. Verify

```bash
# CR reconciled on 10.0
oc get qmgr mq-nativeha -n ibm-mq \
  -o jsonpath='{.status.phase}{" "}{.status.versions.reconciled}{"\n"}'    # Running 10.0.0.5-r1

# Every instance runs 10.0 (dspmqver works on replicas too)
for p in 0 1 2; do
  echo -n "mq-nativeha-ibm-mq-$p: "; oc exec -n ibm-mq mq-nativeha-ibm-mq-$p -- dspmqver -f 2
done

# The active instance has probably moved: look it up again
ACTIVE=$(oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}'); echo "active: $ACTIVE"

# Native HA: 1 active, 2 replicas in sync, quorum 3/3
oc exec -n ibm-mq "$ACTIVE" -- dspmq -o nativeha -x -m MQNATIVEHA

# Command level raised to 10.0 (CMDLEVEL(1000))
oc exec -n ibm-mq "$ACTIVE" -- bash -c "echo 'DISPLAY QMGR CMDLEVEL' | runmqsc MQNATIVEHA"
```

Then check the applications. Run the producer/consumer test clients from the repository
root (`mq-test-*`) to confirm that the TLS connection through the Route,
the `CHLAUTH` mapping, the `AUTHREC` authorizations and the MQ Console login
still work.

### 4. Promote the manifests

Once the upgrade is verified, make the upgraded manifests the source of truth,
so that a later `oc apply -f ..` does not try to put the CR back on 9.4 (the
operator would reject it anyway):

```bash
{ cat 00a-mq-catalog-source.yaml; echo '---'; cat 00b-mq-subscription.yaml; } > ../00-mq-operator-csv.yaml
cp 17-queuemanager.yaml ../17-queuemanager.yaml
```

The 9.4 CR stays in the git history: it is what a rollback re-applies.

## Rollback to 9.4.5.1

### Principle

The queue manager cannot go back to 9.4 in place: `spec.version` cannot be
decreased, and MQ 9.4 refuses to start on data that 10.0 has migrated. The
rollback therefore keeps everything the clients see and replaces the queue
manager behind it:

- **Same CR name (`mq-nativeha`), same namespace.** The operator recreates the
  same StatefulSet, Services and Route, so the hostname, port, SNI and TLS
  certificates do not change. Clients only see a reconnection.
- **New, empty PVCs** for a fresh 9.4.5.1 queue manager. Its configuration
  comes from the declarative manifests (`ini`, `mqsc`) plus the `dmpmqcfg`
  dump taken in step 0.
- **Messages are moved across with `dmpmqmsg`.** The unload/load format does
  not depend on the MQ version, and it keeps the full MQMD (MsgId, CorrelId,
  context).

Operator 4.0.4 stays installed. OLM cannot downgrade an operator, and there is
no need to: Operator 4.0.4 accepts creating a 9.4.5.1-r1 queue manager. The CR
then shows a `DeprecatedVersion` warning condition. A later operator release
may drop 9.4, so do not upgrade the operator while a queue manager is rolled
back to 9.4.

### Validated on this cluster (Operator 4.0.4)

The rollback mechanics were validated on throwaway queue managers in
`ibm-mq`:

| Test | Result |
|---|---|
| Create a new 9.4.5.1-r1 queue manager | ✅ Accepted by the webhook; `Running`, `CMDLEVEL(945)`, `DeprecatedVersion` warning |
| Delete a QueueManager CR | Pods deleted, **PVCs kept** (StatefulSet retention policy `Retain`) |
| Recreate the same CR name in 9.4.5.1 on the kept 10.0 PVC | ❌ `CrashLoopBackOff`: `AMQ7204E … It has previously been started by a newer release of IBM MQ` |
| Same, after deleting the PVC | ✅ `Running` on 9.4.5.1 with a fresh PVC |
| `dmpmqmsg` dump on 10.0.0.5, load on 9.4.5.1 | ✅ All messages loaded; MsgId, user and put application unchanged |
| Two CRs with the same `spec.queueManager.name` in the namespace | ✅ Accepted; independent queue managers with different QMIDs and Routes |

This has not been rehearsed end to end on a Native HA queue manager. Do that
in a test environment before relying on it, and time it, because the outage
lasts from step R1 to step R8.

### What a rollback does not bring back

- **Retained publications** and **durable subscriptions**: they are not
  messages on application queues. Re-create the subscriptions (they are in
  the `dmpmqcfg` dump) and have publishers republish.
- **In-doubt XA transactions**: resolve them before the rollback (R2).
- **Non-persistent messages** that are not drained, and anything put after
  the inbound flows are stopped (R1).
- **Configuration changes made on 10.0** after the upgrade: re-apply them by
  hand on 9.4 if they are still needed.
- **The queue manager identity**: the new queue manager has a new QMID. This
  matters only for MQ clusters and sender/receiver channels (R9).

### R0. Prerequisites

Before the upgrade:

- the `dmpmqcfg` dump of the 9.4 queue manager (`MQNATIVEHA-9.4.5.1.mqsc`,
  step 0);
- the 9.4 CR. If step 4 has not been done yet, it is still
  `../17-queuemanager.yaml`. Otherwise, restore it from git:

  ```bash
  git log --oneline -- ../17-queuemanager.yaml          # find the last 9.4 version
  git checkout <commit> -- ../17-queuemanager.yaml
  ```

On the workstation, a working directory for the message files:

```bash
mkdir -p rollback-msgs
```

### R1. Stop the inbound flows

Stop the producer and consumer applications (for example by scaling their
Deployments to 0), then stop the client channel so that nothing reconnects:

```bash
ACTIVE=$(oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}'); echo "active: $ACTIVE"
oc exec -n ibm-mq "$ACTIVE" -- bash -c "echo 'STOP CHANNEL(TEST.SVRCONN) MODE(QUIESCE)' | runmqsc MQNATIVEHA"
```

Do the same for any other inbound channel (receivers, cluster receivers).
Check that no client is still connected through the channel. The expected
answer is `AMQ8420I: Channel Status not found`:

```bash
oc exec -n ibm-mq "$ACTIVE" -- bash -c "echo 'DISPLAY CHSTATUS(TEST.SVRCONN)' | runmqsc MQNATIVEHA" | grep -E "AMQ|CONNAME"
```

### R2. Check for in-doubt transactions

```bash
oc exec -n ibm-mq "$ACTIVE" -- dspmqtrn -m MQNATIVEHA
```

`There are no matching prepared or heuristically completed transactions`
means there is nothing to resolve. Otherwise, resolve the transactions from
the transaction manager, or with `rsvmqtrn`, before going further.

### R3. Unload the messages

List the queues that hold messages, leaving out `SYSTEM.*` (queue manager
internal data) and `AMQ.*` (temporary dynamic queues):

```bash
QUEUES=$(oc exec -n ibm-mq "$ACTIVE" -- bash -c \
  "echo 'DISPLAY QLOCAL(*) WHERE(CURDEPTH GT 0)' | runmqsc MQNATIVEHA" \
  | grep -oE 'QUEUE\([^)]+\)' | sed -E 's/QUEUE\((.*)\)/\1/' | grep -vE '^(SYSTEM\.|AMQ\.)')
echo "$QUEUES"
```

Check the list. Add the dead-letter queue (`DISPLAY QMGR DEADQ`) and the
transmission queues if they hold messages, even when their names start with
`SYSTEM.`.

Unload each queue in **browse** mode (`-i`), so that the messages stay on the
10.0 queue manager until it is deleted. Then copy the files to the
workstation:

```bash
for q in $QUEUES; do
  oc exec -n ibm-mq "$ACTIVE" -- dmpmqmsg -m MQNATIVEHA -i "$q" -f "/tmp/$q.msg"
  oc cp "ibm-mq/$ACTIVE:/tmp/$q.msg" "rollback-msgs/$q.msg"
done
ls -l rollback-msgs/
```

Compare the `Messages:` count printed by `dmpmqmsg` with each queue's
`CURDEPTH`. `/tmp` in the pod is an `emptyDir`: for large queues, check that
there is enough space, or run `dmpmqmsg` in client mode from the
workstation.

### R4. Delete the 10.0 queue manager

```bash
oc delete qmgr mq-nativeha -n ibm-mq --wait=true
oc wait --for=delete pod -l app.kubernetes.io/instance=mq-nativeha -n ibm-mq --timeout=300s
oc get pvc -n ibm-mq | grep data-mq-nativeha     # the three PVCs are still there
```

The Route and Services are deleted with the CR and recreated in R6 with the
same names and hostname.

### R5. Delete the 10.0 PVCs

**Do not skip this step**: MQ 9.4 cannot start on the 10.0 data
(`AMQ7204E`). From here on, the messages only exist in the R3 files: check
them before deleting the PVCs.

```bash
oc delete pvc data-mq-nativeha-ibm-mq-0 data-mq-nativeha-ibm-mq-1 data-mq-nativeha-ibm-mq-2 -n ibm-mq --wait=true
```

### R6. Create the 9.4.5.1 queue manager

```bash
oc apply -f ../17-queuemanager.yaml      # the 9.4.5.1-r1 CR (R0)
oc get pods -n ibm-mq -w
```

The operator creates three new PVCs and a new Native HA queue manager, which
applies `qm.ini` and the MQSC from the ConfigMaps at startup. Wait for the
CR to be `Running` with one active instance and two replicas in sync:

```bash
oc get qmgr mq-nativeha -n ibm-mq \
  -o jsonpath='{.status.phase}{" "}{.status.versions.reconciled}{"\n"}'    # Running 9.4.5.1-r1
ACTIVE=$(oc get pods -n ibm-mq -l app.kubernetes.io/instance=mq-nativeha \
  -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}'); echo "active: $ACTIVE"
oc exec -n ibm-mq "$ACTIVE" -- dspmq -o nativeha -x -m MQNATIVEHA
```

`TEST.SVRCONN` accepts connections as soon as the queue manager starts, and
the applications would reconnect before their messages are back. Stop it
straight away:

```bash
oc exec -n ibm-mq "$ACTIVE" -- bash -c "echo 'STOP CHANNEL(TEST.SVRCONN) MODE(FORCE)' | runmqsc MQNATIVEHA"
```

### R7. Restore the runtime configuration

The ConfigMaps only hold the declarative definitions. Objects created at
runtime (for example `TEST.QUEUE`, which is not in `15-mqsc-configmap.yaml`)
come from the 9.4 dump taken in step 0:

```bash
oc cp MQNATIVEHA-9.4.5.1.mqsc "ibm-mq/$ACTIVE:/tmp/MQNATIVEHA-9.4.5.1.mqsc"
oc exec -n ibm-mq "$ACTIVE" -- bash -c "runmqsc MQNATIVEHA < /tmp/MQNATIVEHA-9.4.5.1.mqsc" | tail -5
```

A few commands are expected to fail on a fresh queue manager (for example on
some `SYSTEM.*` objects). Check that the application queues exist before
loading the messages. Also check that `TEST.SVRCONN` is still `STOPPED`
(`DISPLAY CHSTATUS(TEST.SVRCONN)`), and stop it again if it is not.

### R8. Reload the messages

```bash
for f in rollback-msgs/*.msg; do
  q=$(basename "$f" .msg)
  oc cp "$f" "ibm-mq/$ACTIVE:/tmp/$q.msg"
  oc exec -n ibm-mq "$ACTIVE" -- dmpmqmsg -m MQNATIVEHA -f "/tmp/$q.msg" -o "$q"
done
oc exec -n ibm-mq "$ACTIVE" -- bash -c \
  "echo 'DISPLAY QLOCAL(*) WHERE(CURDEPTH GT 0) CURDEPTH' | runmqsc MQNATIVEHA" | grep -E "QUEUE\(|CURDEPTH"
```

The depths must match the counts from R3.

### R9. Channels and MQ clusters

- **Client channels (`SVRCONN`)** have no sequence numbers: nothing to do.
- **Sender/receiver channels**: the new queue manager starts its sequence
  numbers from 1. Run `RESET CHANNEL(<name>)` on both ends.
- **MQ cluster member**: the new queue manager has a new QMID. On a full
  repository, run `RESET CLUSTER(<cluster>) QMID('<old QMID>') ACTION(FORCEREMOVE)`
  to remove the old one. Then run `REFRESH CLUSTER(<cluster>)` on the new
  queue manager.

### R10. Reopen the flows

```bash
oc exec -n ibm-mq "$ACTIVE" -- bash -c "echo 'START CHANNEL(TEST.SVRCONN)' | runmqsc MQNATIVEHA"
```

Restart the applications and check that they connect through the usual Route
and consume the reloaded messages. Once the rollback is validated, delete
the message files:

```bash
rm -r rollback-msgs
```

## Impact on messages

- **Kept:** persistent messages, durable subscriptions and retained
  publications. The queue manager converts them in place on the PVCs.
- **Lost at the failover of the active instance:** non-persistent messages
  and non-durable subscriptions, because Native HA does not replicate them.
- **Rolled back:** in-flight transactions. Clients must reconnect, for example
  with automatic client reconnection.

Plan the upgrade in a quiet window. If the queue manager is in an MQ cluster,
upgrade the full repositories before the partial repositories.
