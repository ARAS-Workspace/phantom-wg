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

generate-production-package: the SPA and the release tree.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from core import runner
from core.commands import argument
from core.runner import ToolError
from stack.dev.libs import spa

ABOUT = "Build dist/phantom-wg-modern/ package"
ARGUMENTS = (argument("--no-spa", action="store_true"),)
USAGE = "generate-production-package [--no-spa]"

DIST = "dist"
TREE = "dist/phantom-wg-modern"
GITIGNORE = Path(__file__).resolve().with_name("production.gitignore")
SKIPPED_SUFFIXES = (".pyc", ".pyo")
INCLUDE = (
    "SETUP",
    "UPDATE",
    "MIGRATION",
    "CHANGELOG",
    "LICENSE",
    "THIRD_PARTY_LICENSES",
    "Dockerfile",
    "nginx.Dockerfile",
    "docker-compose.yml",
    "docker-compose.override.yml.example",
    ".env.example",
    ".env.daemon.example",
    ".env.auth-service.example",
    ".env.cf.example",
    "requirements.txt",
    "phantom_daemon",
    "services/auth-service",
    "services/nginx",
    "services/react-spa/dist",
    "tools/__main__.py",
    "tools/prod.sh",
    "tools/core",
    "tools/stack/prod",
    "tools/compose/archive.yml",
    "tools/compose/build.yml",
    "tools/compose/registry.yml",
    "tools/compose/MANIFEST.json",
)


def _skipped(path: Path) -> bool:
    return "__pycache__" in path.parts or path.suffix in SKIPPED_SUFFIXES or path.name == ".gitkeep"


def _copy(source: Path, target: Path) -> int:
    """Copies a file or a tree, returns how many files went."""
    found = sorted(source.rglob("*")) if source.is_dir() else [source]
    files = [path for path in found if path.is_file() and not _skipped(path)]
    for path in files:
        destination = target / path.relative_to(source)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    return len(files)


def _package() -> None:
    missing = [entry for entry in INCLUDE if not (runner.ROOT / entry).exists()]
    if missing:
        raise ToolError("Missing from the package: " + ", ".join(missing))

    dist = runner.ROOT / DIST
    if dist.exists():
        shutil.rmtree(dist)

    tree = runner.ROOT / TREE
    total = 0
    for entry in INCLUDE:
        source = runner.ROOT / entry
        count = _copy(source, tree / entry)
        total += count
        print(f"  {entry}{'/' if source.is_dir() else ''} ({count} files)")

    shutil.copy2(GITIGNORE, tree / ".gitignore")
    print(f"  .gitignore (from {GITIGNORE.name})")
    print(f"\nTotal: {total + 1} files in {TREE}/")


def run(no_spa: bool) -> None:
    if not no_spa:
        spa.build()
    print("Generating production package...")
    _package()
    print(f"Production package ready: {TREE}/")
