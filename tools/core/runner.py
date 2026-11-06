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

Runs the commands of the host. No other module imports subprocess.

    stream    the output goes straight to the terminal
    capture   stdout comes back as text, stderr stays on the terminal
    probe     the answer comes back, a failure is an answer too
    replace   this process becomes the command

Every command starts in the root of the install. A failure of stream or
capture stops the tool with the exit code of the command.
"""

from __future__ import annotations

import os
import signal
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import NoReturn

ROOT = Path(__file__).resolve().parents[2]
NOT_STARTED = 127


class ToolError(Exception):
    """Stops the tool: the message goes to stderr, the code to the shell."""

    def __init__(self, message: str, code: int = 1) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class Answer:
    """What a probed command said."""

    ok: bool
    text: str


def _failed(args: Sequence[str], returncode: int) -> ToolError:
    """The failure of a command, with the exit code a shell reports for it."""
    code = 128 - returncode if returncode < 0 else returncode
    return ToolError(f"{' '.join(args[:2])} exited {code}", code)


def _not_started(args: Sequence[str], error: OSError) -> ToolError:
    return ToolError(f"{args[0]}: {error.strerror}", NOT_STARTED)


def _wait(process: subprocess.Popen) -> int | None:
    """Ctrl-C reaches the command from the terminal too: its exit ends the wait."""
    while True:
        try:
            return process.wait()
        except KeyboardInterrupt:
            continue


def stream(args: Sequence[str], cwd: str = ".", env: Mapping[str, str] | None = None) -> None:
    """Runs a command in front of the operator. cwd is relative to the root."""
    environment = None if env is None else {**os.environ, **env}
    try:
        process = subprocess.Popen(args, cwd=ROOT / cwd, env=environment)
    except OSError as error:
        raise _not_started(args, error) from error

    with process:
        returncode = _wait(process)

    if returncode != 0:
        raise _failed(args, returncode)


def capture(args: Sequence[str]) -> str:
    """Runs a command for the value it prints."""
    try:
        done = subprocess.run(
            args,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError as error:
        raise _not_started(args, error) from error

    if done.returncode != 0:
        raise _failed(args, done.returncode)
    return done.stdout.strip()


def probe(args: Sequence[str]) -> Answer:
    """Asks a command a question. Nothing reaches the terminal."""
    try:
        done = subprocess.run(
            args,
            cwd=ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except OSError:
        return Answer(False, "")
    return Answer(done.returncode == 0, done.stdout.strip())


def replace(args: Sequence[str]) -> NoReturn:
    """Becomes the command: the terminal, signals and exit code are its own."""
    os.chdir(ROOT)
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    try:
        os.execvp(args[0], list(args))
    except OSError as error:
        raise _not_started(args, error) from error
