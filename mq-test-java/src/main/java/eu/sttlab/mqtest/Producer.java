package eu.sttlab.mqtest;

import com.ibm.mq.jms.MQConnectionFactory;
import javax.jms.Connection;
import javax.jms.DeliveryMode;
import javax.jms.JMSException;
import javax.jms.MessageProducer;
import javax.jms.Queue;
import javax.jms.Session;
import javax.jms.TextMessage;

import java.time.Instant;
import java.time.format.DateTimeFormatter;

public final class Producer {

    private final Config config;
    private long seq = 0;

    public Producer(Config config) {
        this.config = config;
    }

    public void run() throws Exception {
        MQConnectionFactory cf = MqConnectionFactoryBuilder.build(config);

        Connection connection = cf.createConnection();
        connection.setExceptionListener(this::onException);
        connection.start();

        // Transacted: commit() is only called after send() returns successfully, so
        // a connection break is unambiguous - either the commit was confirmed and
        // the message is durably enqueued, or it wasn't and the retry below resends
        // the same seq. Avoids the gap a non-transacted send leaves between "broker
        // accepted the data" and "the put is durable".
        Session session = connection.createSession(true, Session.SESSION_TRANSACTED);
        Queue queue = session.createQueue("queue:///" + config.queue());
        MessageProducer producer = session.createProducer(queue);
        producer.setDeliveryMode(DeliveryMode.PERSISTENT);

        log("STARTED queue=" + config.queue() + " channel=" + config.channel());

        while (true) {
            seq++;
            String ts = DateTimeFormatter.ISO_INSTANT.format(Instant.now());
            String body = "seq=" + seq + " ts=" + ts + " sender=producer";

            long beforeSend = System.currentTimeMillis();
            try {
                TextMessage message = session.createTextMessage(body);
                message.setLongProperty("seq", seq);
                producer.send(message);
                session.commit();
                long elapsed = System.currentTimeMillis() - beforeSend;
                if (elapsed > 2000) {
                    log("SENT seq=" + seq + " elapsedMillis=" + elapsed + " (slow send, likely failover in progress)");
                } else {
                    log("SENT seq=" + seq);
                }
            } catch (JMSException e) {
                log("SEND_FAILED seq=" + seq + " reason=" + e.getMessage());
                seq--; // retry the same sequence number, do not skip it
            }

            Thread.sleep(config.sendIntervalMillis());
        }
    }

    private void onException(JMSException e) {
        log("CONNECTION_EXCEPTION " + e.getMessage() + " linkedException=" + e.getLinkedException());
    }

    private void log(String message) {
        System.out.println("[producer] " + Instant.now() + " " + message);
    }
}
