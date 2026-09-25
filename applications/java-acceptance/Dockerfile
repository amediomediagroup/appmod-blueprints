# Stage 1: Builder
FROM ghcr.io/amediomediagroup/upstream/maven:3.9.16-eclipse-temurin-25-noble@sha256:dd8e01b3be719853578c07b57ff8d9bbbbfe746f802226f05b19689420815221 AS build
WORKDIR /workspace

COPY pom.xml .
RUN mvn --batch-mode --no-transfer-progress dependency:go-offline

COPY src ./src
RUN mvn --batch-mode --no-transfer-progress clean package -DskipTests

# Stage 2: Non-root Runtime
FROM ghcr.io/amediomediagroup/upstream/eclipse-temurin:25-jre-noble@sha256:b573af9e331196fbc42e246da4df24df9b6c556c73e7efddfde0511f1c9508c5
WORKDIR /app

RUN groupadd -r appgroup && useradd -r -g appgroup appuser
COPY --from=build /workspace/target/java-acceptance-1.0.0.jar /app/app.jar

USER appuser
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
