package eu.sttlab.mqtest;

import com.ibm.msg.client.wmq.WMQConstants;
import com.ibm.mq.jms.MQConnectionFactory;

import javax.net.ssl.KeyManagerFactory;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;
import java.io.FileInputStream;
import java.security.KeyStore;

public final class MqConnectionFactoryBuilder {

    private MqConnectionFactoryBuilder() {
    }

    public static MQConnectionFactory build(Config config) throws Exception {
        MQConnectionFactory cf = new MQConnectionFactory();
        cf.setTransportType(WMQConstants.WMQ_CM_CLIENT);
        cf.setHostName(config.host());
        cf.setPort(config.port());
        cf.setChannel(config.channel());
        cf.setQueueManager(config.queueManager());
        cf.setSSLCipherSuite(config.sslCipherSuite());
        cf.setSSLSocketFactory(buildSslContext(config).getSocketFactory());

        // Client-side automatic reconnection: transparently retries on
        // connection-broken (MQRC 2009/2059) and reconnects once a new
        // Native HA leader is elected and reachable through the route.
        cf.setIntProperty(WMQConstants.WMQ_CLIENT_RECONNECT_OPTIONS, WMQConstants.WMQ_CLIENT_RECONNECT);
        cf.setIntProperty(WMQConstants.WMQ_CLIENT_RECONNECT_TIMEOUT, config.reconnectTimeoutSeconds());

        return cf;
    }

    // IBM MQ classes for JMS build their own SSLContext rather than reusing
    // the JVM default, so javax.net.ssl.* system properties alone are not
    // enough - an explicit SSLSocketFactory must be set on the connection
    // factory.
    private static SSLContext buildSslContext(Config config) throws Exception {
        KeyStore keyStore = KeyStore.getInstance("PKCS12");
        try (FileInputStream in = new FileInputStream(config.keyStorePath())) {
            keyStore.load(in, config.keyStorePassword().toCharArray());
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm());
        kmf.init(keyStore, config.keyStorePassword().toCharArray());

        KeyStore trustStore = KeyStore.getInstance("PKCS12");
        try (FileInputStream in = new FileInputStream(config.trustStorePath())) {
            trustStore.load(in, config.trustStorePassword().toCharArray());
        }
        TrustManagerFactory tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
        tmf.init(trustStore);

        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);
        return sslContext;
    }
}
