# ──────────────────────────────────────────────────────────────────
# phantom-certbot  ·  Let's Encrypt certificate tool
# ──────────────────────────────────────────────────────────────────
# debian:trixie-slim with Debian's certbot. certbot_obtain.py, the
# secrets and the certbot state are mounted by tools/lib/certbot.sh.
#
# Build:
#   docker build -t phantom-certbot:latest tools/lib/helpers/certbot
# ──────────────────────────────────────────────────────────────────

# ── Platform ─────────────────────────────────────────────────────
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS platform-apt

RUN apt-get update \
 && apt-get install -y --no-install-recommends certbot ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# apt, the packages only apt depends on, and mount. apt marks itself
# essential; --allow-remove-essential lets apt-get remove it. The
# __pycache__ directories are the bytecode the installs compiled.
FROM platform-apt AS platform-pruned
RUN apt-get purge -y --auto-remove --allow-remove-essential apt mount \
 && rm -rf /var/lib/apt /var/cache/apt /var/log/apt \
    /var/log/dpkg.log /var/log/alternatives.log \
 && find /usr/lib/python3* -name __pycache__ -type d -prune -exec rm -rf {} +

# One layer, without the files the purge removed.
FROM scratch
COPY --from=platform-pruned / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV LANG=C.UTF-8

# Runtime settings
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python3", "/app/certbot_obtain.py"]
