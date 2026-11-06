"""What the unit tests of the core share."""

from __future__ import annotations

import subprocess
import sys
import textwrap
from pathlib import Path

TOOLCHAIN = Path(__file__).resolve().parents[2]
TIMEOUT = 20


def run(args, **options) -> subprocess.CompletedProcess:
    return subprocess.run(
        args,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        timeout=TIMEOUT,
        check=False,
        **options,
    )


def python_lines(code: str) -> list[str]:
    """A command that runs code with the toolchain on its path."""
    prelude = f"import sys\nsys.path.insert(0, {str(TOOLCHAIN)!r})\n"
    return [sys.executable, "-I", "-B", "-u", "-c", prelude + textwrap.dedent(code)]
