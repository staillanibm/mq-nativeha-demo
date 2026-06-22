FROM registry.access.redhat.com/ubi9/openjdk-17:latest AS build
WORKDIR /build
COPY --chown=185:0 pom.xml .
COPY --chown=185:0 src ./src
RUN mvn -q -B package

FROM registry.access.redhat.com/ubi9/openjdk-17-runtime:latest
WORKDIR /app
COPY --from=build /build/target/mq-test-jar-with-dependencies.jar ./mq-test.jar
ENTRYPOINT ["java", "-jar", "mq-test.jar"]
