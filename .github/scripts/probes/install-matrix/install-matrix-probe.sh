#!/usr/bin/env bash
# Boots the guest of one job of verify-install-matrix.yml under KVM, from the
# directory that holds its disks, and shows the guest's lines as they come. The
# lines are described in install-matrix-guest.sh. The guest reboots once after
# Docker is installed; QEMU keeps running across it.
# Usage: .github/scripts/probes/install-matrix/install-matrix-probe.sh <name> <disk dir>
set -uo pipefail

NAME="${1:?name}"
cd "${2:?disk dir}" || exit 1

: > serial.log
: > guest.log

# -accel kvm has no fallback: without KVM, QEMU exits at once. The root disk is
# a -device with bootindex=0: a disk given with -drive if=virtio comes after the
# -device disks in PCI order. With cache=unsafe QEMU does not pass the guest's
# flushes of the root disk on to the host's disk: the guest is thrown away after
# the run. A reboot of the guest keeps QEMU running; its poweroff ends QEMU.
timeout 50m qemu-system-x86_64 -accel kvm -cpu host -smp 2 -m 6144 \
    -drive file=disk.qcow2,if=none,id=root,format=qcow2,cache=unsafe \
    -device virtio-blk-pci,drive=root,bootindex=0 \
    -drive file=seed.img,if=virtio,format=raw \
    -drive file=payload.tar,if=none,id=payload,format=raw,readonly=on \
    -device virtio-blk-pci,drive=payload,serial=payload \
    -drive file=results.img,if=none,id=results,format=raw \
    -device virtio-blk-pci,drive=results,serial=results \
    -nic user,model=virtio-net-pci \
    -device virtio-serial-pci -chardev file,id=probelog,path=guest.log \
    -device virtserialport,chardev=probelog,name=probe.log \
    -display none -monitor none -serial file:serial.log &
qemu=$!

# Ten minutes with no new line from the guest's script, the first boot, the
# reboot and every step alike: the end of the serial console is printed and the
# guest stopped. A running step writes a note every five minutes.
(
    while kill -0 "$qemu" 2>/dev/null; do
        sleep 10
        if [ $(($(date +%s) - $(stat -c %Y guest.log))) -ge 600 ]; then
            touch watchdog.fired
            echo "::error title=$NAME::no line from the guest's script for 10 min; the guest is stopped"
            echo "::group::serial console, last 60 lines"
            tail -n 60 serial.log | sed 's/^/console | /'
            echo "::endgroup::"
            kill "$qemu"
            exit 0
        fi
    done
) &

# "@@probe" lines become groups and notes; every other line starts with its
# step's name and is printed as it is. Reading a pipe, mawk holds the lines
# until its buffer fills; with -W interactive it takes each line as it comes.
tail -n +1 -F --pid="$qemu" guest.log 2>/dev/null | mawk -W interactive '
    $1 == "@@probe" && $2 == "step-start" { print "::group::" $3; fflush(); next }
    $1 == "@@probe" && $2 == "step-end" {
        print "::endgroup::"
        print $3 ": exit " $4 " after " $5 " s"
        fflush(); next
    }
    $1 == "@@probe" && $2 == "note" { sub(/^@@probe note /, ""); print "PROBE | " $0; fflush(); next }
    { print; fflush() }
' || true

rc=0
wait "$qemu" || rc=$?
echo "qemu exit: $rc"

if [ ! -e watchdog.fired ] && ! grep -q '^@@probe step-start ' guest.log; then
    echo "::group::serial console, last 60 lines (no step reached the virtio port)"
    tail -n 60 serial.log | sed 's/^/console | /'
    echo "::endgroup::"
fi

mkdir -p results
tar -xf results.img -C results || echo "the results disk holds no tar"
exit "$rc"
