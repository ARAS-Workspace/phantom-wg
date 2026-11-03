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
FROM python:3.12.13-slim-trixie AS vendor-fetch

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
FROM python:3.12.13-slim-trixie AS deps

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ── Stage 3: runtime ────────────────────────────────────────────
FROM python:3.12.13-slim-trixie AS runtime

ARG VENDOR_DIR=/opt/phantom/vendor

# nft (nftables), the program the firewall bridge runs, and iproute2
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