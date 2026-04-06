# Multi-stage build for Insight API Gateway
#
# Build context: src/backend/
# Usage: cd src/backend && docker build -f services/api-gateway/Dockerfile -t insight-api-gateway:dev .

# Stage 1: Builder
FROM rust:1.92-bookworm AS builder

# Install protobuf-compiler (required by grpc-hub → prost-build)
RUN apt-get update && \
    apt-get install -y --no-install-recommends protobuf-compiler libprotobuf-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy workspace Cargo files first for layer caching
COPY Cargo.toml Cargo.lock ./

# Copy all workspace members
COPY libs/ ./libs/
COPY plugins/ ./plugins/
COPY services/api-gateway/ ./services/api-gateway/

# Build release binary
RUN cargo build --release --bin insight-api-gateway

# Stage 2: Runtime
FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy binary
COPY --from=builder /build/target/release/insight-api-gateway /app/insight-api-gateway

# Copy config
COPY --from=builder /build/services/api-gateway/config/ /app/config/

# Create data dir and non-root user
RUN mkdir -p /app/data && \
    useradd -U -u 1000 appuser && \
    chown -R 1000:1000 /app
USER 1000

EXPOSE 8080

CMD ["/app/insight-api-gateway", "-c", "/app/config/insight.yaml", "run"]
