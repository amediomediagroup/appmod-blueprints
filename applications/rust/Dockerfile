FROM rust:slim-buster AS builder

WORKDIR /app
COPY . .

RUN cargo build --release

FROM rust:slim-buster

COPY --from=builder /app/target/release/lambda /app/lambda

WORKDIR /app
COPY src/setup/res /app/res

ENTRYPOINT ["/app/lambda"]

