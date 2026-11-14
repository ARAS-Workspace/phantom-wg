"""
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.

What the toolchain reads from a host, and the gate matrix built on it.

The kernel comes from Docker: the containers run on that kernel, and on macOS
it is not the kernel of this machine.
"""

from __future__ import annotations

import platform
import re
import shutil
import sys
from collections.abc import Sequence
from pathlib import Path

from core import runner
from core.floor import PYTHON
from stack.prod.libs.gates import Gate, Reading

# The floor of the firewall-bridge matrix: the containers run on this kernel.
KERNEL = (5, 15)
TUN_DEVICE = Path("/dev/net/tun")
# An update takes the code and the images: a tree half written cannot be run again.
FREE_SPACE = 1 << 30


def dotted(version: Sequence[int]) -> str:
    return ".".join(str(part) for part in version)


def leading_version(text: str) -> tuple[int, int]:
    """The first two numbers of a version, (0, 0) when it has none."""
    found = re.match(r"(\d+)\.(\d+)", text)
    return (int(found[1]), int(found[2])) if found else (0, 0)


def read_python() -> Reading:
    version = platform.python_version()
    if sys.version_info[:2] < PYTHON:
        return Reading(False, f"{version} is under {dotted(PYTHON)}")
    return Reading(True, version)


def read_docker() -> Reading:
    # noinspection PyDeprecation
    if shutil.which("docker") is None:
        return Reading(False, "not installed")

    answer = runner.probe(["docker", "info", "--format", "{{.ServerVersion}}"])
    if not answer.ok or not answer.text:
        return Reading(False, "installed, does not answer")
    return Reading(True, answer.text)


def read_compose() -> Reading:
    answer = runner.probe(["docker", "compose", "version", "--short"])
    if not answer.ok or not answer.text:
        return Reading(False, "not installed")
    return Reading(True, answer.text)


def read_kernel() -> Reading:
    answer = runner.probe(["docker", "info", "--format", "{{.KernelVersion}}"])
    if not answer.ok or not answer.text:
        return Reading(False, "unknown, Docker does not answer")
    if leading_version(answer.text) < KERNEL:
        return Reading(False, f"{answer.text} is under {dotted(KERNEL)}")
    return Reading(True, answer.text)


def read_tun() -> Reading:
    if sys.platform != "linux":
        return Reading(True, "provided by Docker on this platform")
    if not TUN_DEVICE.exists():
        return Reading(False, f"{TUN_DEVICE} does not exist")
    return Reading(True, str(TUN_DEVICE))


def read_git() -> Reading:
    if not (runner.ROOT / ".git").exists():
        return Reading(True, "not a git clone")

    answer = runner.probe(["git", "--version"])
    if not answer.ok or not answer.text:
        return Reading(False, "this is a git clone, git does not answer")
    return Reading(True, answer.text)


def read_disk() -> Reading:
    free = shutil.disk_usage(runner.ROOT).free
    if free < FREE_SPACE:
        return Reading(False, f"{free >> 20} MiB free, under {FREE_SPACE >> 20} MiB")
    return Reading(True, f"{free >> 20} MiB free")


PYTHON_GATE = Gate("Python", read_python, f"Install Python {dotted(PYTHON)} or newer.")
DOCKER_GATE = Gate(
    "Docker",
    read_docker,
    "Install Docker, start it and give this user access. "
    "Docker that came with a new kernel starts after a reboot.",
)
COMPOSE_GATE = Gate("Compose", read_compose, "Install the Docker Compose plugin.")
KERNEL_GATE = Gate("Kernel", read_kernel, f"Use a host with kernel {dotted(KERNEL)} or newer.")
TUN_GATE = Gate("TUN", read_tun, "Load the tun kernel module.")
GIT_GATE = Gate("Git", read_git, "Install git: update runs it in a git clone.")
DISK_GATE = Gate("Disk", read_disk, "Free some space on this disk.")

DOCKER_GATES = (DOCKER_GATE, COMPOSE_GATE)
SETUP_GATES = (*DOCKER_GATES, KERNEL_GATE, TUN_GATE)
UPDATE_GATES = (*DOCKER_GATES, GIT_GATE, DISK_GATE)

PROD_GATES = (PYTHON_GATE, *SETUP_GATES, GIT_GATE, DISK_GATE)
