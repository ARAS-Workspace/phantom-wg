#!/usr/bin/env bash
# Boots the guest of one job of verify-linux-distribution-python-matrix-probe.yml
# under KVM, from the directory that holds its disks, and shows the guest's
# lines as they come. The lines are described in python-matrix-probe-guest.sh.
# Usage: .github/scripts/python-matrix-probe-host.sh <name> <disk dir>
set -uo pipefail

NAME="${1:?name}"
cd "${2:?disk dir}" || exit 1

: > serial.log
: > guest.log

# -accel kvm has no fallback: without KVM, QEMU exits at once. The root disk is
# a -device with bootindex=0: a disk given with -drive if=virtio comes after the
# -device disks in PCI order. With cache=unsafe QEMU does not pass the guest's
# flushes of the root disk on to the host's disk: the guest is thrown away after
# the run.
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
    -display none -monitor none -serial file:serial.log -no-reboot &
qemu=$!

# Ten minutes with no line from the guest's script: the end of the serial
# console is printed and the guest stopped.
(
    for _ in $(seq 600); do
        if grep -q '^@@probe ' guest.log || ! kill -0 "$qemu" 2>/dev/null; then
            exit 0
        fi
        sleep 1
    done
    touch watchdog.fired
    echo "::error title=$NAME::no line from the guest's script after 10 min; the guest is stopped"
    echo "::group::serial console, last 60 lines"
    tail -n 60 serial.log | sed 's/^/console | /'
    echo "::endgroup::"
    kill "$qemu"
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
