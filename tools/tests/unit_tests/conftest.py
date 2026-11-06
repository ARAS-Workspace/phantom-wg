"""Fixtures of the unit tests of the core."""

from __future__ import annotations

import re
import textwrap
from types import SimpleNamespace

import pytest

from core import runner


@pytest.fixture
def root(tmp_path, monkeypatch):
    """A temporary root of the install."""
    resolved = tmp_path.resolve()
    monkeypatch.setattr(runner, "ROOT", resolved)
    return resolved


@pytest.fixture
def flows(tmp_path, monkeypatch):
    """A package of flows on the disk, as a stack holds it."""
    monkeypatch.syspath_prepend(str(tmp_path))
    package = "flows_" + re.sub(r"\W", "_", tmp_path.name)

    def add(group: str, name: str, source: str, file: str = "command.py") -> None:
        path = tmp_path / package / group / name / file
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(source), encoding="utf-8")

    return SimpleNamespace(package=package, add=add)
