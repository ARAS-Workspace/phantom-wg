# ──────────────────────────────────────────────────────────────────
# phantom-daemon  ·  Development Image
# ──────────────────────────────────────────────────────────────────
# System deps, vendor bridges, and Python requirements only.
# Application source is mounted via compose volumes.
#
# Build:
#   docker build -f dev.Dockerfile -t phantom-daemon:dev .
#   docker build -f dev.Dockerfile --build-arg TARGETARCH=arm64 -t phantom-daemon:dev-arm64 .
# ──────────────────────────────────────────────────────────────────

FROM python:3.12.13-slim-trixie AS base

# ── Build args ───────────────────────────────────────────────────
# TARGETARCH is auto-set by BuildKit (amd64 | arm64).
# Manual override: --build-arg TARGETARCH=arm64
ARG TARGETARCH

ARG VENDOR_URL=https://vendor.phantom.tc
ARG VENDOR_DIR=/opt/phantom/vendor
# Pinned vendor releases. Verify any download against the trust root —
# the CHECKSUMS file maintained on each bridge's own branch:
#   https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/refs/heads/dev/firewall-bridge/CHECKSUMS
#   https://raw.githubusercontent.com/ARAS-Workspace/phantom-wg/refs/heads/dev/wireguard-go-bridge/CHECKSUMS
ARG FIREWALL_BRIDGE_VERSION=v2.1.7
ARG WIREGUARD_GO_BRIDGE_VERSION=v2.1.3

# ── System deps ──────────────────────────────────────────────────
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    curl unzip \
    libnftables1 nftables iproute2 iptables iputils-ping procps \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/iproute2

# ── Download & unpack vendor bridges ─────────────────────────────
RUN set -e; \
    case "${TARGETARCH}" in \
        amd64|arm64) ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    mkdir -p "${VENDOR_DIR}"; \
    for BRIDGE in firewall-bridge wireguard-go-bridge; do \
        case "${BRIDGE}" in \
            firewall-bridge)      VER="${FIREWALL_BRIDGE_VERSION}" ;; \
            wireguard-go-bridge)  VER="${WIREGUARD_GO_BRIDGE_VERSION}" ;; \
        esac; \
        URL="${VENDOR_URL}/${BRIDGE}/${VER}/linux-${TARGETARCH}.zip"; \
        echo "Fetching ${URL}"; \
        curl -fSL -o /tmp/bridge.zip "${URL}"; \
        unzip -o /tmp/bridge.zip -d "${VENDOR_DIR}"; \
        rm /tmp/bridge.zip; \
    done

# ── Bridge env vars (.so absolute paths) ─────────────────────────
# _ffi.py 3-tier discovery: env var → sibling → system ldconfig
# Setting env vars = tier-1 hit, zero probing.
ENV WIREGUARD_GO_BRIDGE_LIB_PATH="${VENDOR_DIR}/wireguard_go_bridge/wireguard_go_bridge.so"
ENV FIREWALL_BRIDGE_LIB_PATH="${VENDOR_DIR}/firewall_bridge/libfirewall_bridge_linux.so"

# Make bridge packages importable
ENV PYTHONPATH="${VENDOR_DIR}"

# ── Python deps ──────────────────────────────────────────────────
WORKDIR /app

COPY requirements.txt requirements-test.txt ./
RUN pip install --no-cache-dir -r requirements-test.txt

# ── Runtime defaults ─────────────────────────────────────────────
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

CMD ["python"]
