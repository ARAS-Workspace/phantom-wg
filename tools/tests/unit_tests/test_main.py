"""__main__.py: the Python floor and the choice of the stack."""

from __future__ import annotations

import shutil
import sys

import pytest
from support import TOOLCHAIN, run

from core import floor

PYTHON_VERSION = f"{sys.version_info[0]}.{sys.version_info[1]}"


def start(path, *args):
    return run([sys.executable, "-I", "-B", "-u", str(path), *args], cwd="/")


def test_the_floor():
    assert floor.PYTHON == (3, 9)


def test_python_under_the_floor_reports_itself(tmp_path):
    copy = tmp_path / "tools"
    shutil.copytree(TOOLCHAIN, copy, ignore=shutil.ignore_patterns(".venv", ".idea", "__pycache__", "tests"))
    source = copy / "core/floor.py"
    source.write_text(source.read_text(encoding="utf-8").replace("PYTHON = (3, 9)", "PYTHON = (9, 9)"), encoding="utf-8")

    done = start(copy, "dev", "help")
    assert done.returncode == 1
    assert done.stdout == ""
    assert done.stderr == f"Python 9.9 or newer is required, this is {PYTHON_VERSION}.\n"


@pytest.mark.parametrize("argv", [[], ["nope"]])
def test_needs_a_stack(argv):
    done = start(TOOLCHAIN, *argv)
    assert done.returncode == 1
    assert done.stderr == "Start the toolchain with prod.sh or dev.sh.\n"


@pytest.mark.parametrize("stack", ["dev", "prod"])
def test_a_stack_starts(stack):
    done = start(TOOLCHAIN, stack, "help")
    assert done.returncode == 0, done.stderr
    assert done.stdout.startswith(f"Usage: ./tools/{stack}.sh <command>")
    assert done.stdout.isascii()
    assert "\x1b" not in done.stdout
