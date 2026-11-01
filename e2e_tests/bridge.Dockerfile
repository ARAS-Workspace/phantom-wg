# ──────────────────────────────────────────────────────────────────
# Firewall Bridge E2E — single stage: build .so + runtime + tests
# Test code mounted via compose volumes at runtime.
# ──────────────────────────────────────────────────────────────────

FROM rust:1.85-bookworm

# System dependencies: nftables (build + runtime) + networking tools + Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    libnftables-dev libmnl-dev \
    nftables iproute2 iptables iputils-ping \
    wireguard-tools procps bash \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Python test dependencies
COPY requirements.txt ./
RUN pip3 install --break-system-packages --no-cache-dir -r requirements.txt

# Rust: fetch deps then build .so
COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo "// stub" > src/lib.rs && cargo fetch && rm -rf src

COPY src/ src/
COPY include/ include/
RUN cargo build --release \
    && cp target/release/libfirewall_bridge_linux.so /workspace/libfirewall_bridge_linux.so

# Python package
COPY firewall_bridge/ /workspace/firewall_bridge/

ENV FIREWALL_BRIDGE_LIB_PATH=/workspace/libfirewall_bridge_linux.so
ENV PYTHONPATH=/workspace

CMD ["sleep", "infinity"]
