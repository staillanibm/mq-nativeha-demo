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

        Session session = connection.createSession(false, Session.AUTO_ACKNOWLEDGE);
        Queue queue = session.createQueue("queue:///" + config.queue());
        MessageConsumer consumer = session.createConsumer(queue);

        log("STARTED queue=" + config.queue() + " channel=" + config.channel());

        long lastReceiveAt = System.currentTimeMillis();

        while (true) {
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
        }
    }

    private void checkOrdering(long seq) {
        if (lastSeq == -1) {
            log("FIRST_MESSAGE seq=" + seq);
        } else if (seq == lastSeq + 1) {
            // expected, strictly increasing
        } else if (seq <= lastSeq) {
            log("ORDER_VIOLATION seq=" + seq + " lastSeq=" + lastSeq + " (out-of-order or duplicate)");
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
