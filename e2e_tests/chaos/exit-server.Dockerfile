FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    wireguard-tools iproute2 iptables procps bash \
    && rm -rf /var/lib/apt/lists/*
COPY e2e_tests/chaos/exit-server-init.sh /init.sh
RUN chmod +x /init.sh
CMD ["/init.sh"]
