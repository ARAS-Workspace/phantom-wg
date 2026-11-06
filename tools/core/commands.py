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

The commands of a stack: discovery, dispatch, arguments and the help text.

A command is a directory: <flows>/<group>/<name>/command.py holds ABOUT and run,
and may hold ARGUMENTS and USAGE. With PASSTHROUGH its run takes the arguments
as they came. The directories give its name and its group.
Every command loads at the start, and one that does not load stops the tool.

argparse reads the arguments and prints nothing: its help and error texts
change between Python versions, the texts of this tool come from the commands.
"""

from __future__ import annotations

import argparse
import importlib
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType
from typing import Any, NoReturn

from core.runner import ToolError

HELP_NAMES = ("help", "-h", "--help")


@dataclass(frozen=True)
class Argument:
    """One argument of a command, as argparse takes it."""

    names: Sequence[str]
    options: Mapping[str, Any]


def argument(*names: str, **options: Any) -> Argument:
    return Argument(names, options)


FORCE = argument("-f", "--force", action="store_true")


class Command:
    """A command found on the disk."""

    def __init__(self, name: str, group: str, module: ModuleType) -> None:
        self.name = name
        self.group = group
        self.run = module.run
        self.about = module.ABOUT
        self.arguments = getattr(module, "ARGUMENTS", ())
        self.synopsis = getattr(module, "USAGE", name)
        self.passthrough = getattr(module, "PASSTHROUGH", False)


def discover(package: str) -> list[Command]:
    """Every command under a package of flows, in the order of their paths."""
    root = Path(next(iter(importlib.import_module(package).__path__)))
    commands = []
    for path in sorted(root.glob("*/*/command.py")):
        group, name = path.parent.parent.name, path.parent.name
        module = importlib.import_module(f"{package}.{group}.{name}.command")
        commands.append(Command(name.replace("_", "-"), group.capitalize(), module))
    return commands


class _Arguments(argparse.ArgumentParser):
    def error(self, message: str) -> NoReturn:
        raise ToolError(f"Usage: {self.prog}")


def _parse(entry: str, command: Command, argv: Sequence[str]) -> argparse.Namespace:
    parser = _Arguments(prog=f"{entry} {command.synopsis}", add_help=False, allow_abbrev=False)
    for item in command.arguments:
        parser.add_argument(*item.names, **item.options)
    return parser.parse_args(argv)


def print_help(entry: str, commands: Sequence[Command]) -> None:
    print(f"Usage: {entry} <command>")

    groups: dict[str, list[Command]] = {}
    for command in commands:
        groups.setdefault(command.group, []).append(command)

    for group, members in groups.items():
        print(f"\n  {group}:")
        for command in members:
            print(f"    {command.synopsis:<20} {command.about}")

    print(f"\n    {'help':<20} Show this help")


def dispatch(entry: str, package: str, argv: Sequence[str]) -> None:
    """Runs the command argv names, after its arguments."""
    commands = discover(package)
    name = argv[0] if argv else HELP_NAMES[0]
    if name in HELP_NAMES:
        print_help(entry, commands)
        return

    for command in commands:
        if command.name == name:
            if command.passthrough:
                command.run(argv[1:])
            else:
                command.run(**vars(_parse(entry, command, argv[1:])))
            return

    raise ToolError(f"Unknown command: {name}\nSee: {entry} help")
