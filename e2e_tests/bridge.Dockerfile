# ──────────────────────────────────────────────────────────────────
# Firewall Bridge E2E — single stage: build .so + runtime + tests
# Test code mounted via compose volumes at runtime.
# ──────────────────────────────────────────────────────────────────

FROM rust:1.99.1-trixie

# nft's command language and JSON output are what nft.rs drives, so nftables
# is installed at an exact version. nftables pins libnftables1 with "=".
ARG NFTABLES_VERSION=1.1.3-1

# System dependencies: nftables (runtime) + networking tools + Python
RUN apt-get update && apt-get install -y --no-install-recommends \
    nftables=${NFTABLES_VERSION} libnftables1=${NFTABLES_VERSION} \
    iproute2 iptables iputils-ping \
    wireguard-tools procps bash \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/iproute2

# Debian marks the system site-packages as externally managed (PEP 668), so
# the test dependencies go into a venv.
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /workspace

# Python test dependencies
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

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
