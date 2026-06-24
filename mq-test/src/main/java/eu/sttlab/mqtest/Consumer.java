package eu.sttlab.mqtest;

import com.ibm.mq.jms.MQConnectionFactory;
import javax.jms.Connection;
import javax.jms.JMSException;
import javax.jms.Message;
import javax.jms.MessageConsumer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TextMessage;

import java.time.Instant;

public final class Consumer {

    private final Config config;
    private long lastSeq = -1;

    public Consumer(Config config) {
        this.config = config;
    }

    public void run() throws Exception {
        MQConnectionFactory cf = MqConnectionFactoryBuilder.build(config);

        Connection connection = cf.createConnection();
        connection.setExceptionListener(this::onException);
        connection.start();

        // Transacted: message is only removed on explicit commit() after processing,
        // so a crash before commit redelivers rather than loses it. A redelivery
        // after a sent-but-unconfirmed commit can still surface as a duplicate,
        // logged below as DUPLICATE_MESSAGE rather than silently absorbed. Real
        // end-to-end exactly-once (consumer side effects atomic with the dequeue)
        // would need 2PC/XA across both resources - not done here.
        Session session = connection.createSession(true, Session.SESSION_TRANSACTED);
        Queue queue = session.createQueue("queue:///" + config.queue());
        MessageConsumer consumer = session.createConsumer(queue);

        log("STARTED queue=" + config.queue() + " channel=" + config.channel());

        long lastReceiveAt = System.currentTimeMillis();

        while (true) {
            try {
                Message message = consumer.receive(5000);
                long now = System.currentTimeMillis();

                if (message == null) {
                    long idleMillis = now - lastReceiveAt;
                    if (idleMillis > 5000) {
                        log("NO_MESSAGE idleMillis=" + idleMillis + " (possible failover in progress)");
                    }
                    continue;
                }

                long gapMillis = now - lastReceiveAt;
                lastReceiveAt = now;

                long seq = message.getLongProperty("seq");
                String body = (message instanceof TextMessage tm) ? tm.getText() : message.toString();

                checkOrdering(seq);

                if (gapMillis > 3000) {
                    log("RECEIVED " + body + " gapMillis=" + gapMillis + " (gap suggests reconnection/failover happened)");
                } else {
                    log("RECEIVED " + body);
                }

                // Optional throttle (RECEIVE_INTERVAL_MILLIS) to drain slower than the
                // producer and let a backlog build up in the queue.
                if (config.receiveIntervalMillis() > 0) {
                    Thread.sleep(config.receiveIntervalMillis());
                }

                // Commit only after processing is fully done, so a crash/disconnect
                // before this point redelivers the message instead of losing it.
                session.commit();
            } catch (JMSException e) {
                // A connection broken mid-receive or mid-commit (e.g. a Native HA
                // failover) surfaces here. The MQ client library reconnects
                // automatically; an uncommitted message is rolled back and
                // redelivered, so we just log and retry rather than letting the
                // exception kill the process.
                log("RECEIVE_FAILED reason=" + e.getMessage() + " (will retry; message redelivered if rolled back)");
            }
        }
    }

    private void checkOrdering(long seq) {
        if (lastSeq == -1) {
            log("FIRST_MESSAGE seq=" + seq);
        } else if (seq == lastSeq + 1) {
            // expected, strictly increasing
        } else if (seq == lastSeq) {
            log("DUPLICATE_MESSAGE seq=" + seq + " (redelivery after an unconfirmed commit)");
        } else if (seq < lastSeq) {
            log("ORDER_VIOLATION seq=" + seq + " lastSeq=" + lastSeq + " (out-of-order)");
        } else {
            log("GAP_DETECTED missingFrom=" + (lastSeq + 1) + " missingTo=" + (seq - 1) + " (message loss)");
        }
        lastSeq = seq;
    }

    private void onException(JMSException e) {
        log("CONNECTION_EXCEPTION " + e.getMessage() + " linkedException=" + e.getLinkedException());
    }

    private void log(String message) {
        System.out.println("[consumer] " + Instant.now() + " " + message);
    }
}
