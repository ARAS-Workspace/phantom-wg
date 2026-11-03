# ── Platform ─────────────────────────────────────────────────────
# debian:trixie-slim with Debian's python3 and a venv at /opt/venv for
# pip, as in Dockerfile.
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS platform-apt

# pip installs into /opt/venv; Debian's python3 refuses it (PEP 668).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
    python3 python3-venv ca-certificates netbase tzdata \
 && python3 -m venv /opt/venv \
 && rm -rf /var/lib/apt/lists/*

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
FROM scratch
COPY --from=platform-pruned / /
ENV PATH=/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LANG=C.UTF-8

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Test dependencies
RUN pip install --no-cache-dir pytest httpx

RUN mkdir -p /var/lib/phantom/auth

EXPOSE 8443

CMD ["python", "-m", "auth_service"]
