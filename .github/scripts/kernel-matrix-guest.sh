#!/usr/bin/env bash
# Runs as root in each guest of kernel-matrix-firewall-bridge.yml, from the
# repository the payload disk holds at /work: Docker CE at the versions of
# /work/matrix.env, then the steps test-firewall-bridge.yml runs, on this
# guest's kernel: the dev image, cargo test --lib in it, the Python unit
# runner and the E2E runner.
#
# Each step's output goes to /results/<step>.log and a line "<step> <exit
# code> <seconds>" to /results/steps; /results/kernel holds uname -r. On exit
# /results is written as a tar to the results disk and the guest powers off.
# Progress lines start with "MATRIX |" on the serial console.
set -uo pipefail

WORK=/work
RESULTS=/results
mkdir -p "$RESULTS"
. "$WORK/matrix.env"

say() {
    echo "MATRIX | $*" | tee -a "$RESULTS/progress" >> /dev/ttyS0
}

finish() {
    say "writing results"
    tar -cf /dev/disk/by-id/virtio-results -C "$RESULTS" .
    sync
    poweroff
}
trap finish EXIT

step() {
    local name=$1 t0=$SECONDS rc=0
    shift
    say "$name started"
    "$@" > "$RESULTS/$name.log" 2>&1 || rc=$?
    echo "$name $rc $((SECONDS - t0))" >> "$RESULTS/steps"
    say "$name: exit $rc after $((SECONDS - t0)) s"
    return "$rc"
}

install_docker() {
    # No terminal under cloud-init: debconf and needrestart ask nothing.
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    local apt=(apt-get -q -y -o DPkg::Lock::Timeout=600)
    "${apt[@]}" update
    "${apt[@]}" install --no-install-recommends ca-certificates curl gnupg python3-venv
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/gpg" -o /etc/apt/keyrings/docker.asc
    # The fingerprint Docker publishes for its repository key.
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
        | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:' || {
        echo "the key at download.docker.com is not 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"
        return 1
    }
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_OS $DOCKER_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list
    "${apt[@]}" update
    "${apt[@]}" install \
        "docker-ce=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "docker-ce-cli=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "containerd.io=${CONTAINERD_IO}${DOCKER_SUFFIX}" \
        "docker-buildx-plugin=${BUILDX}${DOCKER_SUFFIX}" \
        "docker-compose-plugin=${COMPOSE}${DOCKER_SUFFIX}"
    python3 -m venv /opt/venv
    /opt/venv/bin/pip install --no-cache-dir "docker==${PY_DOCKER}"
    docker version
    docker compose version
    /opt/venv/bin/python --version
}

uname -r > "$RESULTS/kernel"
say "kernel $(uname -r), expected $EXPECT_KERNEL"
cd "$WORK" || exit 1
step docker install_docker || exit 1
step dev-image dev/build.sh || exit 1
step cargo dev/cargo.sh test --lib --verbose
step unit /opt/venv/bin/python tests/runner.py
step e2e /opt/venv/bin/python e2e_tests/runner.py
exit 0
