# Dockerfile for creating a statically-linked Rust application using docker's
# multi-stage build feature. This also leverages the docker build cache to avoid
# re-downloading dependencies if they have not changed.
FROM rust AS build
WORKDIR /usr/app

# Download the target for static linking.
RUN rustup target add x86_64-unknown-linux-musl

COPY Cargo.toml Cargo.lock ./
COPY src/lambda/ ./src/lambda/

RUN cargo build --bin lambda --release && exit 0

# Copy the statically-linked binary into a scratch container.
FROM scratch

COPY --from=build /usr/app/target/release/lambda .
USER 1000

ENV ROCKET_ADDRESS=0.0.0.0
ENV ROCKET_PORT=8080

CMD ["./lambda"]