# ──────────────────────────────────────────────────────────────────
# Firewall Bridge — Unit Test Runner
# Builds .so, installs Python package, runs pytest
# ──────────────────────────────────────────────────────────────────

FROM rust:1.99.1-trixie

# nft's command language and JSON output are what nft.rs drives, so nftables
# is installed at an exact version. nftables pins libnftables1 with "=".
ARG NFTABLES_VERSION=1.1.3-1

RUN apt-get update && apt-get install -y --no-install-recommends \
    nftables=${NFTABLES_VERSION} libnftables1=${NFTABLES_VERSION} \
    iproute2 iptables \
    python3 python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/iproute2

# Debian marks the system site-packages as externally managed (PEP 668), so
# the test dependencies go into a venv.
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /workspace

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

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
