# ──────────────────────────────────────────────────────────────────
# phantom-gateway  ·  socat for the development and e2e stacks
# ──────────────────────────────────────────────────────────────────
# debian:trixie-slim with Debian's socat. Compose passes the socat
# arguments as the command.
#
# Build:
#   docker build -f socat.Dockerfile -t phantom-gateway:latest .
# ──────────────────────────────────────────────────────────────────

# ── Platform ─────────────────────────────────────────────────────
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS platform-apt

RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/*

# apt, the packages only apt depends on, and mount. apt marks itself
# essential; --allow-remove-essential lets apt-get remove it.
FROM platform-apt AS platform-pruned
RUN apt-get purge -y --auto-remove --allow-remove-essential apt mount \
 && rm -rf /var/lib/apt /var/cache/apt /var/log/apt \
    /var/log/dpkg.log /var/log/alternatives.log

# One layer, without the files the purge removed.
FROM scratch
COPY --from=platform-pruned / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ENTRYPOINT ["socat"]
