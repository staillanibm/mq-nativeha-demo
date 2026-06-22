package eu.sttlab.mqtest;

public final class Main {

    public static void main(String[] args) throws Exception {
        // The MQ client defaults to sending the channel name as the TLS SNI
        // (outboundSNI=CHANNEL), but the OpenShift route routes by hostname,
        // so without this the route falls through to the cluster's default
        // certificate instead of the queue manager's.
        System.setProperty("com.ibm.mq.cfg.SSL.outboundSNI", "HOSTNAME");

        String role = System.getenv("ROLE");
        if (role == null) {
            throw new IllegalStateException("Missing required environment variable: ROLE (expected 'producer' or 'consumer')");
        }

        Config config = Config.fromEnv();

        switch (role) {
            case "producer" -> new Producer(config).run();
            case "consumer" -> new Consumer(config).run();
            default -> throw new IllegalArgumentException("Unknown ROLE: " + role + " (expected 'producer' or 'consumer')");
        }
    }
}
