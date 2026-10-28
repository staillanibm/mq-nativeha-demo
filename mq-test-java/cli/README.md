# mq-test-java / cli

Java client that exercises an IBM MQ queue manager from a workstation or a VM
(sources in `../src`, built here as a fat jar):

- `producer.sh` puts one persistent message `Message <n>` on a queue every
  `SEND_INTERVAL_MILLIS`. A put that fails (queue manager unreachable, during a
  failover for example) is retried with the same number.
- `consumer.sh` gets (destructively) the messages of the queue, one unit of work
  per message, and checks the counter: it prints a log line on a gap, a duplicate
  or a restart of the producer.

Both connect with mutual TLS (PKCS12 keystores) and print one timestamped line
per event. `producer.sh`:

    [producer] 2024-01-01T11:46:43.333Z SENT seq=1 body=Message 1
    [producer] 2024-01-01T11:46:44.334Z SENT seq=2 body=Message 2

`consumer.sh`:

    [consumer] 2024-01-01T11:46:46.141Z RECEIVED Message 1
    [consumer] 2024-01-01T11:46:46.448Z RECEIVED Message 2
    [consumer] 2024-01-01T11:46:47.449Z GAP_DETECTED missingFrom=3 missingTo=4

Everything specific to a queue manager or a cluster is in `.env` and `config/`;
the scripts themselves never need to be edited.

    .
    ├── producer.sh
    ├── consumer.sh
    ├── .env.example            # template of .env (committed)
    ├── .env                    # your copy: queue manager, queue, rates, TLS passwords (git-ignored)
    └── config/
        ├── ccdt.json.template  # CCDT, filled from .env into ccdt.json
        ├── mqclient.ini        # OutboundSNI=HOSTNAME, DefRecon=YES
        ├── certs.yaml.template # cert-manager client certificates, filled from .env
        ├── get-certs.sh        # exports the certificates to config/certs
        ├── build-keystores.sh  # builds config/tls-* (CMS) and certs/*.p12 (PKCS12)
        └── env.sh              # loads .env, used by all the scripts

## What the queue manager must provide

- A server connection channel (`TEST.SVRCONN` by default) with `SSLCAUTH(REQUIRED)`,
  reachable from the workstation or VM (on OpenShift, a passthrough Route on port 443).
- CHLAUTH `SSLPEERMAP` rules mapping a client certificate with `OU=producer` to a
  user that can `PUT` and `OU=consumer` to a user that can `GET`, `BROWSE` and
  `INQ` on the queue (`app-producer` / `app-consumer` on the demo queue manager).
- The queue (`TEST.QUEUE` by default) with `DEFPSIST(YES)`: the producer relies on
  it to send persistent messages.

      DEFINE QLOCAL('TEST.QUEUE') REPLACE MAXDEPTH(100000) DEFPSIST(YES)

## 1. Build

    mvn -q package        # builds target/mq-test-cli.jar (Java 17)

## 2. Create `.env`

`.env` is not in the repository (it is git-ignored, it holds your host, paths and
TLS passwords). Create it from the template:

    cp .env.example .env

Then set at least `MQ_HOME` (where the MQ Redistributable Client is installed, `~/mqc`
above, written as an absolute path) and `MQ_HOST`, the host of the queue manager Route:

    oc -n ibm-mq get route mq-nativeha-ibm-mq-qm -o jsonpath='{.spec.host}'

The other values (`MQ_PORT`, `MQ_QMGR`, `MQ_CHANNEL`, `MQ_QUEUE`,
`SEND_INTERVAL_MILLIS`, `RECEIVE_INTERVAL_MILLIS`) are described in the file.
A variable set in the environment wins over `.env`:
`SEND_INTERVAL_MILLIS=500 ./producer.sh`.

Leave `MQ_KEYSTORE_PASSWORD` and `MQ_TRUSTSTORE_PASSWORD` as they are in the
template: `config/build-keystores.sh` (step 3) generates random passwords and
writes them into `.env`.

## 3. Client certificates (once)

`config/certs.yaml.template` asks cert-manager for a `producer` and a `consumer`
client certificate. The issuer is set in `.env` (`CLIENTS_ISSUER_KIND`,
`CLIENTS_ISSUER`): it must be the one the queue manager trusts. The CA of the
queue manager certificate is not issued again: it is read from the existing secret
`SERVER_CA_SECRET` (key `ca.crt`), in the namespace `OC_NAMESPACE`.

    config/get-certs.sh         # oc apply in OC_NAMESPACE (.env), exports PEM files to config/certs
    config/build-keystores.sh   # builds config/tls-* and certs/*.p12; updates .env passwords

`get-certs.sh` is the only script that uses the cluster. To get the PEM files
another way, put `producer.crt`, `producer.key`, `consumer.crt`, `consumer.key`,
`clients-ca.crt` (CA that signed the client certificates) and `servers-ca.crt`
in `config/certs/` and run only `build-keystores.sh`. `config/certs`,
`config/tls-*` and the generated `config/ccdt.json` are ignored by git.

## 4. Run

    ./producer.sh        # one terminal
    ./consumer.sh        # another one

Both loop until Ctrl+C.
