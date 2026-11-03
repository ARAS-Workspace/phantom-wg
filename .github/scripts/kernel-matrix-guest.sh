#!/usr/bin/env bash
# Runs as root in each guest of kernel-matrix-firewall-bridge.yml, from the
# repository the payload disk holds at /work: Docker CE at the versions of
# /work/matrix.env, then the steps test-firewall-bridge.yml runs, on this
# guest's kernel: the dev image, cargo test --lib in it, the Python unit
# runner and the E2E runner.
#
# Each step's output goes, line by line, to /results/<step>.log and, with
# "<step> | " before each line, to the virtio port matrix.log, which the
# runner shows while the step runs (to /dev/ttyS0 when the port is absent).
# Lines of the script itself start with "@@matrix ": "step-start <step>",
# "step-end <step> <exit code> <seconds>" and "note <text>"; a step's lines
# start with its name, so none of them starts with "@@matrix ". A line
# "<step> <exit code> <seconds>" goes to /results/steps; /results/kernel
# holds uname -r. On exit /results is written as a tar to the results disk
# and the guest powers off.
set -uo pipefail

WORK=/work
RESULTS=/results
mkdir -p "$RESULTS"
. "$WORK/matrix.env"
# Python writes each line when it is printed, not when its buffer fills.
export PYTHONUNBUFFERED=1 BUILDKIT_PROGRESS=plain

LOG=/dev/virtio-ports/matrix.log
for _ in $(seq 30); do
    [ -e "$LOG" ] && break
    sleep 1
done
if [ ! -e "$LOG" ]; then
    LOG=/dev/ttyS0
    echo "@@matrix note no virtio port matrix.log, writing to /dev/ttyS0" >> "$LOG"
fi

mark() {
    echo "@@matrix $*" >> "$LOG"
}

say() {
    echo "$*" >> "$RESULTS/progress"
    mark "note $*"
}

finish() {
    say "writing results"
    tar -cf /dev/disk/by-id/virtio-results -C "$RESULTS" .
    sync
    poweroff
}
trap finish EXIT

step() {
    local name=$1 t0=$SECONDS rc tick
    shift
    mark "step-start $name"
    # A note every five minutes while the step runs.
    (
        while sleep 300; do
            mark "note $name still running after $((SECONDS - t0)) s"
        done
    ) &
    tick=$!
    "$@" 2>&1 | tee -a "$RESULTS/$name.log" | sed -u -e "s/^/$name | /" -e '$a\' >> "$LOG"
    rc=${PIPESTATUS[0]}
    kill "$tick" 2>/dev/null
    wait "$tick" 2>/dev/null
    echo "$name $rc $((SECONDS - t0))" >> "$RESULTS/steps"
    mark "step-end $name $rc $((SECONDS - t0))"
    return "$rc"
}

install_docker() {
    # A command that fails ends the step with its exit code. (set -e would
    # not: the step is called on the left of ||, where bash ignores it.)
    # No terminal under cloud-init: debconf and needrestart ask nothing.
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    local apt=(apt-get -q -y -o DPkg::Lock::Timeout=600)
    "${apt[@]}" update || return
    "${apt[@]}" install --no-install-recommends ca-certificates curl gnupg python3-venv || return
    install -m 0755 -d /etc/apt/keyrings || return
    curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/gpg" -o /etc/apt/keyrings/docker.asc || return
    # The fingerprint Docker publishes for its repository key.
    gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
        | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:' || {
        echo "the key at download.docker.com is not 9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88"
        return 1
    }
    chmod a+r /etc/apt/keyrings/docker.asc || return
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DOCKER_OS $DOCKER_CODENAME stable" \
        > /etc/apt/sources.list.d/docker.list || return
    "${apt[@]}" update || return
    "${apt[@]}" install \
        "docker-ce=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "docker-ce-cli=${DOCKER_CE}${DOCKER_SUFFIX}" \
        "containerd.io=${CONTAINERD_IO}${DOCKER_SUFFIX}" \
        "docker-buildx-plugin=${BUILDX}${DOCKER_SUFFIX}" \
        "docker-compose-plugin=${COMPOSE}${DOCKER_SUFFIX}" || return
    python3 -m venv /opt/venv || return
    /opt/venv/bin/pip install --no-cache-dir "docker==${PY_DOCKER}" || return
    docker version || return
    docker compose version || return
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
