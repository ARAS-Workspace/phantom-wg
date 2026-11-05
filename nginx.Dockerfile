# ──────────────────────────────────────────────────────────────────
# phantom-nginx  ·  TLS front for the SPA and the auth service
# ──────────────────────────────────────────────────────────────────
# debian:trixie-slim with Debian's nginx. nginx.conf, the SPA build
# and the TLS secrets are mounted by compose.
#
# Build:
#   docker build -f nginx.Dockerfile -t phantom-nginx-base:local .
# ──────────────────────────────────────────────────────────────────

# ── Platform ─────────────────────────────────────────────────────
FROM debian:trixie-20261027-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS platform-apt

# The logs go to the container's stdout and stderr.
# apt-get upgrade: every package at the version Debian serves, source included.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends nginx \
 && rm -rf /var/lib/apt/lists/* \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log

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

EXPOSE 443
STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
