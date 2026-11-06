#!/usr/bin/env bash
# Runs as root in each guest of verify-linux-distribution-python-matrix-probe.yml,
# from the repository the payload disk holds at /work. The first step reads the
# host as the image left it, before anything is installed. A host under a floor
# ends there. The next steps run the Python install command the tools give an
# operator, install Docker, lay the package at /opt/phantom-wg and run the flow
# of the tools as a user of the docker group, without root.
#
# A kernel that comes with Docker starts at the next boot. When Docker does not
# start and a newer kernel is installed, the guest reboots once and cloud-init
# runs this script again: the steps repeat on the new kernel.
#
# Each step's output goes, line by line, to /results/<step>.log and, with
# "<step> | " before each line, to the virtio port probe.log, which the runner
# shows while the step runs (to /dev/ttyS0 when the port is absent). Lines of
# the script itself start with "@@probe ": "step-start <step>",
# "step-end <step> <exit code> <seconds>" and "note <text>". A line
# "<step> <exit code> <seconds>" goes to /results/steps, where the last line of
# a step counts. On exit /results is written as a tar to the results disk and
# the guest powers off.
set -uo pipefail

WORK=/work
RESULTS=/results
OPERATOR=phantomop
INSTALL=/opt/phantom-wg
SCRIPTS="$WORK/.github/scripts/probes/python-matrix"
PROBE="$SCRIPTS/python_matrix_probe.py"

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
        python) probe_python ;;
        gate) install_python ;;
        docker) install_docker ;;
        tree) make_tree ;;
        flow) run_flow ;;
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

# The packages of this image that need python3: what keeps it on the system.
python_dependents() {
    case "$FAMILY" in
        deb) apt-cache rdepends --installed python3 | sed -e '1,2d' -e 's/^[ |]*//' | sort -u ;;
        rpm) rpm -q --whatrequires python3 /usr/bin/python3 --qf '%{NAME}\n' 2>/dev/null | grep -v '^no package' | sort -u ;;
        arch) pacman -Qi python | sed -n 's/^Required By *: //p' | tr -s ' ' '\n' | grep -v '^None$' | sort -u ;;
    esac
}

# The command the tools give an operator without python3.
install_python() {
    case "$FAMILY" in
        deb)
            export DEBIAN_FRONTEND=noninteractive
            apt-get -q -y -o DPkg::Lock::Timeout=600 update || return
            apt-get -q -y -o DPkg::Lock::Timeout=600 install python3
            ;;
        rpm)
            dnf -y install python3
            ;;
        arch)
            pacman -Sy --noconfirm --needed python
            ;;
    esac
}

probe_python() {
    local preinstalled=yes rebooted=no
    [ -e "$RESULTS/rebooted" ] && rebooted=yes
    grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
    if ! command -v python3 > /dev/null; then
        preinstalled=no
        echo "no python3 on this image"
        install_python || return
    fi
    python_dependents > "$RESULTS/python-dependents"
    echo "packages that need python3: $(wc -l < "$RESULTS/python-dependents")"
    head -n 12 "$RESULTS/python-dependents"
    PROBE_REBOOTED=$rebooted PYTHON_PREINSTALLED=$preinstalled \
        python3 -I -B "$PROBE" host "$RESULTS/host.json"
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

install_docker_rpm() {
    curl -fsSL "https://download.docker.com/linux/$DOCKER_OS/docker-ce.repo" \
        -o /etc/yum.repos.d/docker-ce.repo || return
    dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return
    systemctl enable --now docker
}

# The running kernel stays: an upgrade takes its modules away.
install_docker_arch() {
    pacman -Syu --noconfirm --needed --ignore linux docker docker-compose || return
    systemctl enable --now docker
}

install_docker() {
    case "$FAMILY" in
        deb) install_docker_deb ;;
        rpm) install_docker_rpm ;;
        arch) install_docker_arch ;;
    esac || return
    docker version || return
    docker compose version
}

make_tree() {
    useradd -m -s /bin/bash -G docker "$OPERATOR" || return
    python3 -I -B "$WORK/tools/lib/helpers/packager.py" --clean || return
    mkdir -p "$INSTALL" || return
    cp -a "$WORK/dist/phantom-wg-modern/." "$INSTALL/" || return
    mkdir -p "$INSTALL/services/react-spa/dist" || return
    echo ok > "$INSTALL/services/react-spa/dist/index.html" || return
    chown -R "$OPERATOR:$OPERATOR" "$INSTALL" || return
    id "$OPERATOR"
    ls -ld "$INSTALL" /dev/net/tun
}

run_flow() {
    local rc
    runuser -u "$OPERATOR" -- env HOME="/home/$OPERATOR" \
        python3 -I -B "$PROBE" flow "$INSTALL" "/home/$OPERATOR/flow.json"
    rc=$?
    cp "/home/$OPERATOR/flow.json" "$RESULTS/"
    return "$rc"
}

newer_kernel() {
    local latest
    latest=$(printf '%s\n' /lib/modules/* | sort -V | tail -n 1)
    [ "${latest##*/}" != "$(uname -r)" ]
}

reboot_once() {
    touch "$RESULTS/rebooted"
    install -m 0755 "$SCRIPTS/python-matrix-probe-guest.sh" \
        /var/lib/cloud/scripts/per-boot/python-matrix-probe.sh || return
    mark "note a newer kernel came with Docker, rebooting"
    trap - EXIT
    save_results
    systemctl reboot
    exit 0
}

main() {
    mark "note kernel $(uname -r), role $ROLE"
    cd "$WORK" || return
    step python
    [ "$ROLE" = below-floor ] && return
    step gate
    if ! step docker; then
        if [ ! -e "$RESULTS/rebooted" ] && newer_kernel; then
            reboot_once
        fi
        return 1
    fi
    step tree || return
    step flow
}

main
