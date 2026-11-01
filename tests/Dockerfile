# ──────────────────────────────────────────────────────────────────
# Firewall Bridge — Unit Test Runner
# Builds .so, installs Python package, runs pytest
# ──────────────────────────────────────────────────────────────────

FROM rust:1.85-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    libnftables-dev libmnl-dev \
    nftables iproute2 iptables \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY requirements.txt ./
RUN pip3 install --break-system-packages --no-cache-dir -r requirements.txt

COPY Cargo.toml Cargo.lock ./
RUN mkdir -p src && echo "// stub" > src/lib.rs && cargo fetch && rm -rf src

COPY src/ src/
COPY include/ include/
RUN cargo build --release \
    && cp target/release/libfirewall_bridge_linux.so /workspace/libfirewall_bridge_linux.so

COPY firewall_bridge/ /workspace/firewall_bridge/
COPY tests/ /workspace/tests/
COPY pytest.ini /workspace/

ENV FIREWALL_BRIDGE_LIB_PATH=/workspace/libfirewall_bridge_linux.so
ENV PYTHONPATH=/workspace

CMD ["python3", "-m", "pytest", "tests/unit/", "-v", "--tb=short", "--cov=firewall_bridge", "--cov-report=term-missing"]
