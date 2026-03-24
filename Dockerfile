# ──────────────────────────────────────────────────────────────────
# phantom-daemon  ·  Production Image
# ──────────────────────────────────────────────────────────────────
# Multi-stage: build deps → slim runtime
#
# Build:
#   docker compose build
#   docker build -t phantom-daemon:latest .
# ──────────────────────────────────────────────────────────────────

# ── Stage 1: vendor fetch ────────────────────────────────────────
FROM python:3.12-slim AS vendor-fetch

ARG TARGETARCH
ARG VENDOR_URL=https://vendor.phantom.tc
ARG VENDOR_DIR=/opt/phantom/vendor
ARG FIREWALL_BRIDGE_VERSION=latest
ARG WIREGUARD_GO_BRIDGE_VERSION=latest

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip \
 && rm -rf /var/lib/apt/lists/*

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

# ── Stage 2: python deps ────────────────────────────────────────
FROM python:3.12-slim AS deps

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ── Stage 3: runtime ────────────────────────────────────────────
FROM python:3.12-slim AS runtime

ARG VENDOR_DIR=/opt/phantom/vendor

# nftables runtime library (required by firewall bridge)
RUN apt-get update \
 && apt-get install -y --no-install-recommends libnftables1 nftables iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/iproute2

# Copy vendor artifacts (no curl/unzip in final image)
COPY --from=vendor-fetch ${VENDOR_DIR} ${VENDOR_DIR}

# Copy installed Python packages
COPY --from=deps /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=deps /usr/local/bin /usr/local/bin

# Bridge env vars — tier-1 FFI discovery
ENV WIREGUARD_GO_BRIDGE_LIB_PATH="${VENDOR_DIR}/wireguard_go_bridge/wireguard_go_bridge.so"
ENV FIREWALL_BRIDGE_LIB_PATH="${VENDOR_DIR}/firewall_bridge/libfirewall_bridge_linux.so"
ENV PYTHONPATH="${VENDOR_DIR}"

# Runtime settings
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Socket directory
RUN mkdir -p /var/run/phantom

WORKDIR /app

EXPOSE 0

CMD ["python"]