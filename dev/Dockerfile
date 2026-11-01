# ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
# ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
# ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
# ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
# ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
#
# firewall-bridge development container
# Full Linux environment: Rust + nftables + iproute2 + Python + pytest
#
# Usage:
#   dev/build.sh          # build image
#   dev/shell.sh          # interactive shell (source mounted)
#   dev/cargo.sh test     # run cargo commands inside container

FROM rust:1.99.1-trixie

# nft's command language and JSON output are what nft.rs drives, so nftables
# is installed at an exact version. nftables pins libnftables1 with "=".
ARG NFTABLES_VERSION=1.1.3-1

# System dependencies: nftables (runtime) + networking tools
RUN apt-get update && apt-get install -y --no-install-recommends \
    nftables=${NFTABLES_VERSION} libnftables1=${NFTABLES_VERSION} \
    iproute2 iptables iputils-ping procps \
    python3 python3-venv \
    sqlite3 bash \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/iproute2

# Debian marks the system site-packages as externally managed (PEP 668), so
# the test dependencies go into a venv.
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# Python test dependencies
RUN pip install pytest==9.0.2 pytest-cov==7.0.0

# Rust cache directory
ENV CARGO_HOME=/cargo
ENV PATH="/cargo/bin:${PATH}"

WORKDIR /workspace

# Pre-fetch dependencies for faster rebuilds
COPY Cargo.toml Cargo.lock /workspace/
RUN mkdir -p src && echo "// stub" > src/lib.rs && cargo fetch && rm -rf src

CMD ["bash"]
