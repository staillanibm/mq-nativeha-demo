package eu.sttlab.mqtest;

public final class Config {

    private final String host;
    private final int port;
    private final String channel;
    private final String queueManager;
    private final String queue;
    private final String sslCipherSuite;
    private final String keyStorePath;
    private final String keyStorePassword;
    private final String trustStorePath;
    private final String trustStorePassword;
    private final int reconnectTimeoutSeconds;
    private final long sendIntervalMillis;
    private final long receiveIntervalMillis;

    private Config(Builder b) {
        this.host = b.host;
        this.port = b.port;
        this.channel = b.channel;
        this.queueManager = b.queueManager;
        this.queue = b.queue;
        this.sslCipherSuite = b.sslCipherSuite;
        this.keyStorePath = b.keyStorePath;
        this.keyStorePassword = b.keyStorePassword;
        this.trustStorePath = b.trustStorePath;
        this.trustStorePassword = b.trustStorePassword;
        this.reconnectTimeoutSeconds = b.reconnectTimeoutSeconds;
        this.sendIntervalMillis = b.sendIntervalMillis;
        this.receiveIntervalMillis = b.receiveIntervalMillis;
    }

    public static Config fromEnv() {
        Builder b = new Builder();
        b.host = requiredEnv("MQ_HOST");
        b.port = Integer.parseInt(env("MQ_PORT", "443"));
        b.channel = env("MQ_CHANNEL", "TEST.SVRCONN");
        b.queueManager = requiredEnv("MQ_QMGR");
        b.queue = env("MQ_QUEUE", "TEST.QUEUE");
        b.sslCipherSuite = env("MQ_SSL_CIPHER_SUITE", "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384");
        b.keyStorePath = env("MQ_KEYSTORE_PATH", "/etc/mq-test/tls/keystore.p12");
        b.keyStorePassword = requiredEnv("MQ_KEYSTORE_PASSWORD");
        b.trustStorePath = env("MQ_TRUSTSTORE_PATH", "/etc/mq-test/tls/truststore.p12");
        b.trustStorePassword = requiredEnv("MQ_TRUSTSTORE_PASSWORD");
        b.reconnectTimeoutSeconds = Integer.parseInt(env("MQ_RECONNECT_TIMEOUT_SECONDS", "1800"));
        b.sendIntervalMillis = Long.parseLong(env("SEND_INTERVAL_MILLIS", "1000"));
        // Per-message consumer delay. Default 0 = drain at full speed. Set higher
        // (e.g. with a fast/bursting producer) to build a queue backlog, so a
        // failover hits persisted, not-yet-consumed messages — making the
        // no-message-loss proof meaningful rather than trivial.
        b.receiveIntervalMillis = Long.parseLong(env("RECEIVE_INTERVAL_MILLIS", "0"));
        return new Config(b);
    }

    private static String env(String key, String defaultValue) {
        String v = System.getenv(key);
        return (v == null || v.isBlank()) ? defaultValue : v;
    }

    private static String requiredEnv(String key) {
        String v = System.getenv(key);
        if (v == null || v.isBlank()) {
            throw new IllegalStateException("Missing required environment variable: " + key);
        }
        return v;
    }

    public String host() {
        return host;
    }

    public int port() {
        return port;
    }

    public String channel() {
        return channel;
    }

    public String queueManager() {
        return queueManager;
    }

    public String queue() {
        return queue;
    }

    public String sslCipherSuite() {
        return sslCipherSuite;
    }

    public String keyStorePath() {
        return keyStorePath;
    }

    public String keyStorePassword() {
        return keyStorePassword;
    }

    public String trustStorePath() {
        return trustStorePath;
    }

    public String trustStorePassword() {
        return trustStorePassword;
    }

    public int reconnectTimeoutSeconds() {
        return reconnectTimeoutSeconds;
    }

    public long sendIntervalMillis() {
        return sendIntervalMillis;
    }

    public long receiveIntervalMillis() {
        return receiveIntervalMillis;
    }

    private static final class Builder {
        String host;
        int port;
        String channel;
        String queueManager;
        String queue;
        String sslCipherSuite;
        String keyStorePath;
        String keyStorePassword;
        String trustStorePath;
        String trustStorePassword;
        int reconnectTimeoutSeconds;
        long sendIntervalMillis;
        long receiveIntervalMillis;
    }
}
