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

A gate is one thing a production flow needs from the host. A flow enforces its
gates on its first line.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass

from core.runner import ToolError


@dataclass(frozen=True)
class Reading:
    """What a gate found on this host."""

    passed: bool
    detail: str


@dataclass(frozen=True)
class Gate:
    """Its name, how it reads the host and what the operator does when it fails."""

    name: str
    read: Callable[[], Reading]
    remedy: str


def enforce(gates: Sequence[Gate]) -> None:
    """Stops at the first gate this host does not pass."""
    for gate in gates:
        reading = gate.read()
        if not reading.passed:
            raise ToolError(f"{gate.name}: {reading.detail}\n{gate.remedy}")


def report(gates: Sequence[Gate]) -> bool:
    """Prints every gate. True when this host passes all of them."""
    passed = True
    for gate in gates:
        reading = gate.read()
        state = "pass" if reading.passed else "FAIL"
        print(f"{gate.name:<9}{state:<6}{reading.detail}")
        if not reading.passed:
            print(f"{'':<15}{gate.remedy}")
            passed = False
    return passed
