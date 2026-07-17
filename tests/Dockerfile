FROM golang:1.25-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev

WORKDIR /build
COPY src/ /build/
# Go unit tests (guards_test.go: panic containment at the FFI boundary)
RUN CGO_ENABLED=1 go test ./...
RUN CGO_ENABLED=1 \
    go build -buildmode=c-shared -trimpath -ldflags="-s -w" \
    -o /wireguard_go_bridge.so .

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    wireguard-tools \
    iproute2 \
    iptables \
    iputils-ping \
    procps \
    tcpdump \
    sqlite3 \
    bash \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages pytest pytest-cov

WORKDIR /workspace

COPY --from=builder /wireguard_go_bridge.so /workspace/wireguard_go_bridge.so

ENV WIREGUARD_GO_BRIDGE_LIB_PATH=/workspace/wireguard_go_bridge.so
ENV PYTHONPATH=/workspace

RUN pip3 install --break-system-packages docker

CMD ["sleep", "infinity"]