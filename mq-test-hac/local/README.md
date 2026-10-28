# mq-test-hac / local

Two scripts that exercise an IBM MQ queue manager from a workstation or a VM, using the
sample programs of the MQ client:

- `producer.sh` puts one persistent message `Message <n>` on a queue every
  `PRODUCE_DELAY_MS`. A put that fails (queue manager unreachable, during a
  failover for example) is retried with the same number.
- `consumer.sh` gets (destructively) the messages of the queue, one unit of work
  per message, restarts `dmpmqmsg` when it stops, and checks the counter: it prints
  a `CHECK:` line on a gap, a duplicate or a restart of the producer.

Both connect with mutual TLS through a client connection (CCDT), and print one
timestamped line per event. `producer.sh`:

    11:46:43.333 put <Message 1>
    11:46:43.930 put <Message 2>

`consumer.sh` (the last line shows a `CHECK:` line, printed only on an anomaly):

    11:46:46.141 T Message 1
    11:46:46.448 T Message 2
    11:46:46.449 CHECK: DUPLICATE/OUT OF ORDER, expected 3 got 2

Everything specific to a queue manager or a cluster is in `.env` and `config/`;
the scripts themselves never need to be edited.

    .
    ├── producer.sh
    ├── consumer.sh
    ├── .env                    # queue manager, queue, rates, MQ client path
    └── config/
        ├── ccdt.json.template  # CCDT, filled from .env into ccdt.json
        ├── mqclient.ini        # OutboundSNI=HOSTNAME, DefRecon=YES
        ├── certs.yaml.template # cert-manager client certificates, filled from .env
        ├── get-certs.sh        # exports the certificates to config/certs
        ├── build-keystores.sh  # builds config/tls-producer and config/tls-consumer
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

## 1. MQ client

Install the IBM MQ client with the samples, or the Redistributable Client, which
needs no root (Linux x64 here, other platforms: matching archive in the same
directory):

    mkdir -p ~/mqc && cd ~/mqc
    curl -O https://public.dhe.ibm.com/ibmdl/export/pub/software/websphere/messaging/mqdev/redist/9.4.5.1-IBM-MQC-Redist-LinuxX64.tar.gz
    tar xzf 9.4.5.1-IBM-MQC-Redist-LinuxX64.tar.gz

`openssl` and `gawk` are also needed (`consumer.sh` uses `gawk` and `stdbuf`).

## 2. Configure `.env`

Set at least `MQ_HOME` (where the client is installed, `~/mqc` above, written as
an absolute path) and `MQ_HOST`, the host of the queue manager. On OpenShift it is
the host of the queue manager Route:

    oc -n ibm-mq get route mq-nativeha-ibm-mq-qm -o jsonpath='{.spec.host}'

The other values (`MQ_PORT`, `QMGR`, `CHANNEL`, `QUEUE`, `TZ`, `PRODUCE_DELAY_MS`,
`CONSUME_DELAY_MS`) are described in the file. A variable set in the
environment wins over `.env`: `PRODUCE_DELAY_MS=500 ./producer.sh`.

## 3. Client certificates (once)

`config/certs.yaml.template` asks cert-manager for a `producer` and a `consumer`
client certificate. The issuer is set in `.env` (`CLIENTS_ISSUER_KIND`,
`CLIENTS_ISSUER`): it must be the one the queue manager trusts. The CA of the
queue manager certificate is not issued again: it is read from the existing secret
`SERVER_CA_SECRET` (key `ca.crt`), in the namespace `NS`.

    config/get-certs.sh         # oc apply in namespace NS (.env), exports the PEM files to config/certs
    config/build-keystores.sh   # local only: CMS keystores config/tls-producer and tls-consumer

`get-certs.sh` is the only script that uses the cluster. To get the PEM files
another way, put `producer.crt`, `producer.key`, `consumer.crt`, `consumer.key`,
`clients-ca.crt` (CA that signed the client certificates) and `servers-ca.crt`
in `config/certs/` and run only `build-keystores.sh`. `config/certs`,
`config/tls-*` and the generated `config/ccdt.json` are ignored by git.

## 4. Run

    ./producer.sh        # one terminal
    ./consumer.sh        # another one

Both loop until Ctrl+C. To use the tools by hand, source `config/env.sh` with a
role:

    . config/env.sh consumer
    amqsbcgc TEST.QUEUE MQNATIVEHA            # browse

`producer` can only put; `consumer` can get, browse and inquire.
