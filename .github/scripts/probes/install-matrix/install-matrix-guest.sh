#!/usr/bin/env bash
# Runs as root in each guest of verify-install-matrix.yml, from the repository
# the payload disk holds at /work. The first boot installs Docker and reboots:
# every host then runs the install on the kernel it boots after Docker came. The
# second boot lays the release tree at /opt/phantom-wg and, as a user of the
# docker group, runs the default install of tools/prod.sh twice in that tree:
# setup, up, a check of the running stack and hard-reset, first with the
# default address pool, then with SUBNET.
#
# Each step's output goes, line by line, to /results/<step>.log and, with
# "<step> | " before each line, to the virtio port probe.log, which the runner
# shows while the step runs (to /dev/ttyS0 when the port is absent). Lines of
# the script itself start with "@@probe ": "step-start <step>",
# "step-end <step> <exit code> <seconds>" and "note <text>". A line
# "<step> <exit code> <seconds>" goes to /results/steps. /results lives on the
# root disk across the reboot; on exit it is written as a tar to the results
# disk and the guest powers off.
set -uo pipefail

WORK=/work
RESULTS=/results
OPERATOR=phantomop
INSTALL=/opt/phantom-wg
SCRIPTS="$WORK/.github/scripts/probes/install-matrix"
REBOOTED="$RESULTS/rebooted"
PER_BOOT=/var/lib/cloud/scripts/per-boot/install-matrix.sh

mkdir -p "$RESULTS"
while IFS= read -r line; do
    export "${line//\'/}"
done < "$WORK/matrix.env"
cp "$WORK/matrix.env" "$RESULTS/"
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

save_results() {
    tar -cf /dev/disk/by-id/virtio-results -C "$RESULTS" .
    sync
}

finish() {
    mark "note writing results"
    save_results
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
        boot) check_boot ;;
        tree) make_tree ;;
        default-setup) prod setup ;;
        subnet-setup) prod setup "--terazi-ipv4-subnet=$SUBNET" ;;
        default-up | subnet-up) prod up ;;
        default-verify) check_stack "$DEFAULT_SUBNET" ;;
        subnet-verify) check_stack "$SUBNET" ;;
        default-reset | subnet-reset) reset_stack ;;
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

install_docker_deb() {
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
    local apt=(apt-get -q -y -o DPkg::Lock::Timeout=600)
    "${apt[@]}" update || return
    "${apt[@]}" install --no-install-recommends ca-certificates curl gnupg || return
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
        "docker-compose-plugin=${COMPOSE}${DOCKER_SUFFIX}"
}

# Docker starts at the next boot: on AlmaLinux the modules it needs come with
# a newer kernel.
install_docker_rpm() {
    curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/docker-ce.repo" \
        -o /etc/yum.repos.d/docker-ce.repo || return
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return
    systemctl enable docker
}

# The running kernel stays: an upgrade takes its modules away.
install_docker_arch() {
    pacman -Syu --noconfirm --needed --ignore linux docker docker-compose || return
    systemctl enable docker
}

install_docker() {
    case "$FAMILY" in
        deb) install_docker_deb ;;
        rpm) install_docker_rpm ;;
        arch) install_docker_arch ;;
    esac || return
    docker --version || return
    docker compose version
}

check_boot() {
    uname -r
    for _ in $(seq 60); do
        docker info > /dev/null 2>&1 && break
        sleep 1
    done
    docker info --format 'Docker {{.ServerVersion}} on kernel {{.KernelVersion}}, storage {{.Driver}}'
}

make_tree() {
    id "$OPERATOR" > /dev/null 2>&1 || useradd -m -s /bin/bash -G docker "$OPERATOR" || return
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

check_stack() {
    python3 -I -B "$SCRIPTS/install-matrix-check.py" "$INSTALL" "$1"
}

# The operator wipes what the containers wrote as root; the .env files and the
# override stay for the next round.
reset_stack() {
    local files containers
    prod down || return
    printf 'yes\n' | prod hard-reset || return
    files=$(find "$INSTALL/container-data" -type f | wc -l)
    containers=$(docker ps -aq --filter label=com.docker.compose.project=phantom-wg | wc -l)
    echo "files left in container-data: $files, containers left: $containers"
    [ "$files" -eq 0 ] && [ "$containers" -eq 0 ]
}

first_boot() {
    step docker || return
    install -m 0755 "$SCRIPTS/install-matrix-guest.sh" "$PER_BOOT" || return
    touch "$REBOOTED"
    mark "note Docker is installed, rebooting"
    trap - EXIT
    save_results
    systemctl reboot
    exit 0
}

second_boot() {
    # Runs once: a later boot does not start the install again.
    rm -f "$PER_BOOT"
    step boot || return
    step tree || return
    for round in default subnet; do
        step "$round-setup" || return
        step "$round-up" || return
        step "$round-verify" || return
        step "$round-reset" || return
    done
}

main() {
    mark "note kernel $(uname -r), role $ROLE"
    cd "$WORK" || return
    if [ -e "$REBOOTED" ]; then
        second_boot
    else
        first_boot
    fi
}

main
