"""The tree is the host of the production flows."""

from __future__ import annotations

import subprocess

import pytest
from prod_host import SPA_INDEX, wipe_the_tree


@pytest.fixture(scope="module", autouse=True)
def tree():
    """The tree is the host: empty at the start, and empty again at the end."""
    running = subprocess.run(
        ["docker", "ps", "-q", "--filter", "name=phantom"], capture_output=True, encoding="utf-8", timeout=30, check=True,
    )
    if running.stdout.strip():
        pytest.exit("A phantom container runs. This suite takes over the tree: stop the stack first.", returncode=1)

    placeholder = not SPA_INDEX.exists()
    if placeholder:
        SPA_INDEX.parent.mkdir(parents=True, exist_ok=True)
        SPA_INDEX.write_text("<!DOCTYPE html><html><body>test</body></html>\n", encoding="utf-8")

    wipe_the_tree()
    yield
    wipe_the_tree()
    if placeholder:
        SPA_INDEX.unlink()
