#!/usr/bin/env bash
# Runs as root in the guest of verify-certbot.yml, from the repository the
# payload disk holds at /work. It installs Docker, lays the package at
# /opt/phantom-wg and runs the tools as a user of the docker group. Port 80 of
# the runner comes to this guest: tools/prod.sh certbot takes a certificate from
# Let's Encrypt for the name that points to the runner.
#
# Each step's output goes, line by line, to /results/<step>.log and, with
# "<step> | " before each line, to the virtio port probe.log, which the runner
# shows while the step runs (to /dev/ttyS0 when the port is absent). Lines of
# the script itself start with "@@probe ": "step-start <step>",
# "step-end <step> <exit code> <seconds>" and "note <text>". A line
# "<step> <exit code> <seconds>" goes to /results/steps. On exit /results is
# written as a tar to the results disk and the guest powers off.
set -uo pipefail

WORK=/work
RESULTS=/results
OPERATOR=phantomop
INSTALL=/opt/phantom-wg
SECRETS="$INSTALL/container-data/secrets/production"
STATE="$INSTALL/container-data/certbot"

mkdir -p "$RESULTS"
while IFS= read -r line; do
    export "${line//\'/}"
done < "$WORK/probe.env"
cp "$WORK/probe.env" "$RESULTS/"
export PYTHONUNBUFFERED=1

LOG=/dev/virtio-ports/probe.log
for _ in $(seq 30); do
    [ -e "$LOG" ] && break
    sleep 1
done
if [ ! -e "$LOG" ]; then
    LOG=/dev/ttyS0
    echo "@@probe note no virtio port probe.log, writing to /dev/ttyS0" >> "$LOG"
fi

mark() {
    echo "@@probe $*" >> "$LOG"
}

finish() {
    mark "note writing results"
    tar -cf /dev/disk/by-id/virtio-results -C "$RESULTS" .
    sync
    poweroff
}
trap finish EXIT

# Each line of a step, with the step's name before it.
label() {
    local text
    while IFS= read -r text || [ -n "$text" ]; do
        printf '%s | %s\n' "$1" "$text"
    done
}

run_step() {
    case "$1" in
        docker) install_docker ;;
        tree) make_tree ;;
        stack) run_stack ;;
        certbot) run_certbot ;;
        cron) run_cron ;;
        reset) run_reset ;;
    esac
}

step() {
    local name=$1 t0=$SECONDS rc tick
    mark "step-start $name"
    # A note every five minutes while the step runs.
    (
        while sleep 300; do
            mark "note $name still running after $((SECONDS - t0)) s"
        done
    ) &
    tick=$!
    run_step "$name" 2>&1 | tee -a "$RESULTS/$name.log" | label "$name" >> "$LOG"
    rc=${PIPESTATUS[0]}
    kill "$tick" 2>/dev/null
    wait "$tick" 2>/dev/null
    echo "$name $rc $((SECONDS - t0))" >> "$RESULTS/steps"
    mark "step-end $name $rc $((SECONDS - t0))"
    return "$rc"
}

install_docker() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    local apt=(apt-get -q -y -o DPkg::Lock::Timeout=600)
    "${apt[@]}" update || return
    "${apt[@]}" install --no-install-recommends ca-certificates curl gnupg openssl || return
    install -m 0755 -d /etc/apt/keyrings || return
    curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/gpg" -o /etc/apt/keyrings/docker.asc || return
    # The fingerprint Docker publishes for its repository key.
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
        | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:' || {
        echo "the key at download.docker.com is not 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"
        return 1
    }
    chmod a+r /etc/apt/keyrings/docker.asc || return
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_OS $DOCKER_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list || return
    "${apt[@]}" update || return
    "${apt[@]}" install \
        "docker-ce=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "docker-ce-cli=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "containerd.io=${CONTAINERD_IO}${DOCKER_SUFFIX}" \
        "docker-buildx-plugin=${BUILDX}${DOCKER_SUFFIX}" \
        "docker-compose-plugin=${COMPOSE}${DOCKER_SUFFIX}" || return
    docker version || return
    docker compose version
}

make_tree() {
    useradd -m -s /bin/bash -G docker "$OPERATOR" || return
    mkdir -p "$WORK/services/react-spa/dist" || return
    echo ok > "$WORK/services/react-spa/dist/index.html" || return
    "$WORK/tools/dev.sh" generate-production-package --no-spa || return
    mkdir -p "$INSTALL" || return
    cp -a "$WORK/dist/phantom-wg-modern/." "$INSTALL/" || return
    chown -R "$OPERATOR:$OPERATOR" "$INSTALL" || return
    id "$OPERATOR"
}

prod() {
    runuser -u "$OPERATOR" -- env HOME="/home/$OPERATOR" "$INSTALL/tools/prod.sh" "$@"
}

# curl -k takes any certificate: this waits for nginx, the checks come after it.
wait_for_nginx() {
    for _ in $(seq 60); do
        curl -ks -o /dev/null --max-time 5 https://127.0.0.1/ && return 0
        sleep 1
    done
    echo "nginx does not answer on 443 after 60 s"
    return 1
}

certificate_serial() {
    openssl x509 -in "$SECRETS/tls_cert" -noout -serial
}

run_stack() {
    prod setup || return
    prod up || return
    wait_for_nginx
}

run_certbot() {
    prod certbot "$DOMAIN" || return
    prod restart nginx || return
    wait_for_nginx || return

    # Without -k: curl checks the chain against the CAs of the system and the
    # name, the certificate of setup does not pass.
    curl -sS -o /dev/null -w 'nginx answers %{http_code}, certificate verified\n' --max-time 20 \
        --resolve "$DOMAIN:443:127.0.0.1" "https://$DOMAIN/" || return
    openssl x509 -in "$SECRETS/tls_cert" -noout -subject -issuer -enddate || return

    for name in tls_cert tls_key; do
        stat -c '%U %a %n' "$SECRETS/$name"
        [ "$(stat -c %U "$SECRETS/$name")" = "$OPERATOR" ] || return
    done
}

# A cron job: no terminal, no input, a bare environment, and another directory.
# The certificate is not due for renewal: the same one comes back.
run_cron() {
    local before after
    before=$(certificate_serial) || return
    runuser -u "$OPERATOR" -- env -i PATH=/usr/bin:/bin HOME="/home/$OPERATOR" sh -c \
        "cd / && $INSTALL/tools/prod.sh certbot $DOMAIN && $INSTALL/tools/prod.sh restart nginx" < /dev/null || return
    wait_for_nginx || return
    after=$(certificate_serial) || return
    echo "before $before"
    echo "after  $after"
    [ "$before" = "$after" ]
}

# The operator wipes what the certbot container left as root.
run_reset() {
    local left
    prod down || return
    find "$STATE" -mindepth 1 -maxdepth 1 -printf '%u %m %p\n' || return
    [ -n "$(find "$STATE" -mindepth 1 -user root -print -quit)" ] || {
        echo "$STATE holds no file of root"
        return 1
    }
    printf 'yes\n' | prod hard-reset || return
    left=$(find "$STATE" -mindepth 1 | wc -l)
    echo "left in $STATE: $left"
    [ "$left" -eq 0 ]
}

main() {
    mark "note kernel $(uname -r), domain $DOMAIN"
    cd "$WORK" || return
    step docker || return
    step tree || return
    step stack || return
    step certbot || return
    step cron || return
    step reset
}

main
