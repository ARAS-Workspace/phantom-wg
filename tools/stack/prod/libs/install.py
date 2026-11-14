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

A clone follows its remote: update moves it forward or stops before it changes.
"""

from __future__ import annotations

from core import runner
from core.runner import ToolError

REMOTE = "origin"
BRANCH = "main"


def _git(*args: str) -> runner.Answer:
    return runner.probe(["git", *args])


def clone() -> bool:
    """A package has no remote, even with a .git of its operator or inside another tree."""
    return (runner.ROOT / ".git").exists() and _git("remote", "get-url", REMOTE).ok


def _require_clean() -> None:
    changed = _git("status", "--porcelain", "--untracked-files=no").text
    if changed:
        raise ToolError(
            f"Files of this clone have local changes:\n{changed}\n"
            "Server-specific changes belong in docker-compose.override.yml.\n"
            "Move them there, then discard them: git checkout -- <file>"
        )


def _require_branch() -> None:
    branch = _git("symbolic-ref", "--short", "-q", "HEAD").text
    if branch != BRANCH:
        place = branch or _git("describe", "--tags", "--always").text
        raise ToolError(f"This clone is at {place}, update follows {BRANCH}.\nTo follow it: git checkout {BRANCH}")


def pull() -> None:
    _require_clean()
    _require_branch()

    print("Fetching the latest release...")
    runner.stream(["git", "fetch", REMOTE, BRANCH])
    if not _git("merge-base", "--is-ancestor", "HEAD", "FETCH_HEAD").ok:
        raise ToolError(
            f"This clone has left {REMOTE}/{BRANCH}, nothing was applied.\n"
            "To follow it, dropping the local commits:\n"
            f"  git fetch {REMOTE} {BRANCH}\n"
            "  git reset --hard FETCH_HEAD\n"
            "Then: ./tools/prod.sh update"
        )
    runner.stream(["git", "merge", "--ff-only", "FETCH_HEAD"])
