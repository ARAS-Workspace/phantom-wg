# ──────────────────────────────────────────────────────────────────
# phantom-daemon  ·  Production Image
# ──────────────────────────────────────────────────────────────────
# Multi-stage: platform → vendor fetch, python deps → runtime
#
# Build:
#   docker compose build
#   docker build -t phantom-daemon:latest .
# ──────────────────────────────────────────────────────────────────

# ── Stage 0: platform ────────────────────────────────────────────
# debian:trixie-slim with Debian's python3, a venv at /opt/venv for
# pip, and the system packages the runtime runs with; dev.Dockerfile
# builds the same platform with its own system packages.
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS platform-apt

# pip installs into /opt/venv; Debian's python3 refuses it (PEP 668).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 python3-venv ca-certificates netbase tzdata \
 && python3 -m venv /opt/venv \
 && rm -rf /var/lib/apt/lists/*

# nft (nftables), the program the firewall bridge runs, and iproute2
RUN apt-get update \
 && apt-get install -y --no-install-recommends libnftables1 nftables iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /etc/iproute2

# apt, the packages only apt depends on, mount, and the venv packages
# /opt/venv was created with. apt marks itself essential;
# --allow-remove-essential lets apt-get remove it. The __pycache__
# directories are the bytecode the installs compiled.
FROM platform-apt AS platform-pruned
RUN apt-get purge -y --auto-remove --allow-remove-essential \
    apt mount \
    python3-venv python3.13-venv python3-pip-whl python3-setuptools-whl \
 && rm -rf /var/lib/apt /var/cache/apt /var/log/apt \
    /var/log/dpkg.log /var/log/alternatives.log \
 && find /usr/lib/python3* /opt/venv -name __pycache__ -type d -prune -exec rm -rf {} +

# One layer, without the files the purge removed.
FROM scratch AS platform
COPY --from=platform-pruned / /
ENV PATH=/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LANG=C.UTF-8

# ── Stage 1: vendor fetch ────────────────────────────────────────
FROM platform-apt AS vendor-fetch

ARG TARGETARCH
ARG VENDOR_DIR=/opt/phantom/vendor
ARG VENDOR_REPO=ARAS-Workspace/phantom-wg

# Pinned vendor releases, with the SHA-256 of each archive as published with
# that release. The digests are written out here on purpose: the build checks
# what it downloaded without asking a second service, so a re-uploaded asset
# fails instead of passing quietly. To see what GitHub publishes for a tag:
#
#   gh api repos/ARAS-Workspace/phantom-wg/releases/tags/vendor-firewall-bridge-v2.2.0 \
#     --jq '.assets[] | "\(.name)  \(.digest)"'
#
ARG FIREWALL_BRIDGE_VERSION=v2.2.0
ARG FIREWALL_BRIDGE_SHA256_AMD64=cdb35fec6f356494476bbb575708e7c7206313cabde39b20ef329bf7f315e359
ARG FIREWALL_BRIDGE_SHA256_ARM64=4c98edf43aa42cff9a0d3f5eccb059227202baf54d61ed6deba104613a269542
ARG WIREGUARD_GO_BRIDGE_VERSION=v2.2.0
ARG WIREGUARD_GO_BRIDGE_SHA256_AMD64=c84cbd53ffe1f1b0e583b2903fdfa820ad99012f0a93aabd8452c543212c91c7
ARG WIREGUARD_GO_BRIDGE_SHA256_ARM64=6fbdfe59f09e3a3773b8123771c12b5588323b8f4c8611ab8beb54804e5f16c3

# The release package ships the bridges under vendor/linux-<arch>/; a clone of
# main does not, and fetches them below. The trailing glob is what makes the
# directory optional — a bare "COPY vendor/" fails the build when it is absent.
COPY vendor*/ /tmp/vendor/

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -e; \
    case "${TARGETARCH}" in \
        amd64|arm64) ;; \
        *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac; \
    mkdir -p "${VENDOR_DIR}"; \
    LOCAL="/tmp/vendor/linux-${TARGETARCH}"; \
    if [ -d "${LOCAL}/firewall_bridge" ] && [ -d "${LOCAL}/wireguard_go_bridge" ]; then \
        echo "Using the vendor tree shipped with this package: vendor/linux-${TARGETARCH}"; \
        cp -a "${LOCAL}/." "${VENDOR_DIR}/"; \
    else \
        if [ -d "${LOCAL}" ]; then \
            echo "vendor/linux-${TARGETARCH} is present but does not hold both bridges — fetching instead"; \
        fi; \
        for BRIDGE in firewall-bridge wireguard-go-bridge; do \
            case "${BRIDGE}" in \
                firewall-bridge) \
                    VER="${FIREWALL_BRIDGE_VERSION}"; \
                    case "${TARGETARCH}" in \
                        amd64) SHA="${FIREWALL_BRIDGE_SHA256_AMD64}" ;; \
                        arm64) SHA="${FIREWALL_BRIDGE_SHA256_ARM64}" ;; \
                    esac ;; \
                wireguard-go-bridge) \
                    VER="${WIREGUARD_GO_BRIDGE_VERSION}"; \
                    case "${TARGETARCH}" in \
                        amd64) SHA="${WIREGUARD_GO_BRIDGE_SHA256_AMD64}" ;; \
                        arm64) SHA="${WIREGUARD_GO_BRIDGE_SHA256_ARM64}" ;; \
                    esac ;; \
            esac; \
            URL="https://github.com/${VENDOR_REPO}/releases/download/vendor-${BRIDGE}-${VER}/linux-${TARGETARCH}.zip"; \
            echo "Fetching ${URL}"; \
            curl -fSL --retry 3 --retry-delay 2 -o /tmp/bridge.zip "${URL}"; \
            echo "${SHA}  /tmp/bridge.zip" | sha256sum -c -; \
            unzip -o /tmp/bridge.zip -d "${VENDOR_DIR}"; \
            rm /tmp/bridge.zip; \
        done; \
    fi; \
    EXPECT=$(case "${TARGETARCH}" in amd64) echo 62 ;; arm64) echo 183 ;; esac); \
    FOUND=0; \
    for SO in $(find "${VENDOR_DIR}" -name '*.so'); do \
        FOUND=$((FOUND + 1)); \
        GOT=$(python3 -c "import struct,sys; print(struct.unpack_from('<H', open(sys.argv[1],'rb').read(20), 0x12)[0])" "${SO}"); \
        if [ "${GOT}" != "${EXPECT}" ]; then \
            echo "Architecture mismatch: ${SO} reports ELF e_machine ${GOT}, expected ${EXPECT} for ${TARGETARCH}"; \
            exit 1; \
        fi; \
    done; \
    if [ "${FOUND}" -lt 2 ]; then \
        echo "Expected a shared library from each bridge, found ${FOUND}"; \
        exit 1; \
    fi; \
    echo "Vendor bridges ready for ${TARGETARCH} (${FOUND} shared libraries verified)"

# ── Stage 2: python deps ────────────────────────────────────────
FROM platform AS deps

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ── Stage 3: runtime ────────────────────────────────────────────
FROM platform AS runtime

ARG VENDOR_DIR=/opt/phantom/vendor

# Copy vendor artifacts (no curl/unzip in final image)
COPY --from=vendor-fetch ${VENDOR_DIR} ${VENDOR_DIR}

# Copy installed Python packages
COPY --from=deps /opt/venv /opt/venv

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