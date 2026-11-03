FROM golang:1.27.3-trixie AS builder

RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev

WORKDIR /build
COPY src/ /build/
# Go unit tests (guards_test.go: panic containment at the FFI boundary)
RUN CGO_ENABLED=1 go test ./...
RUN CGO_ENABLED=1 \
    go build -buildmode=c-shared -trimpath \
    -ldflags="-s -w -extldflags=-Wl,--version-script=/build/exports.map" \
    -o /wireguard_go_bridge.so .

FROM debian:trixie-slim

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
# The error codes and the prototypes cgo generated, for the contract tests.
COPY src/wireguard_go_bridge.h /workspace/include/wireguard_go_bridge.h
COPY --from=builder /wireguard_go_bridge.h /workspace/include/exports.h

ENV WIREGUARD_GO_BRIDGE_LIB_PATH=/workspace/wireguard_go_bridge.so
ENV PYTHONPATH=/workspace

RUN pip3 install --break-system-packages docker

CMD ["sleep", "infinity"]