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

fetch-compose-bridge: the compose-bridge of this platform, from the latest
successful run of its publish workflow.
"""

from __future__ import annotations

import platform
import shutil
import tempfile
import zipfile
from pathlib import Path

from core import runner
from core.runner import ToolError

ABOUT = "Download compose-bridge for current platform"
REPO = "ARAS-Workspace/phantom-wg"
WORKFLOW = "publish-compose-bridge.yml"
DEST = "lib/compose_bridge"
ARCHITECTURES = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def _platform() -> str:
    machine = platform.machine()
    if machine not in ARCHITECTURES:
        raise ToolError(f"Unsupported architecture: {machine}")
    return f"{platform.system().lower()}-{ARCHITECTURES[machine]}"


def _latest_run() -> str:
    print(f"Locating latest successful {WORKFLOW}...")
    run_id = runner.capture([
        "gh", "run", "list", "--repo", REPO, "--workflow", WORKFLOW,
        "--status", "success", "--limit", "1", "--json", "databaseId", "--jq", ".[0].databaseId",
    ])
    if run_id in ("", "null"):
        raise ToolError(f"No successful run found for {WORKFLOW}")
    return run_id


def _artifact(run_id: str, target: str) -> str:
    print(f"Resolving artifact for {target} in run {run_id}...")
    names = runner.capture([
        "gh", "api", f"/repos/{REPO}/actions/runs/{run_id}/artifacts",
        "--jq", f'.artifacts[] | select(.name | endswith("-{target}")) | .name',
    ])
    if not names:
        raise ToolError(f"No artifact matching *-{target} in run {run_id}")
    return names.splitlines()[0]


def _install(download: Path, artifact: str, dest: Path) -> None:
    archive = download / f"{artifact}.zip"
    if archive.is_file():
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(download / "extracted")
        shutil.copytree(download / "extracted/compose_bridge", dest, dirs_exist_ok=True)
    else:
        shutil.copytree(download, dest, dirs_exist_ok=True)


def run() -> None:
    target = _platform()
    if not runner.probe(["gh", "--version"]).ok:
        raise ToolError("GitHub CLI (gh) required: brew install gh")
    if not runner.probe(["gh", "auth", "status"]).ok:
        raise ToolError("Not authenticated. Run: gh auth login")

    run_id = _latest_run()
    artifact = _artifact(run_id, target)
    print(f"Fetching {artifact} (run {run_id})...")

    dest = runner.ROOT / DEST
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as download:
        runner.stream(["gh", "run", "download", run_id, "--repo", REPO, "--name", artifact, "--dir", download])
        _install(Path(download), artifact, dest)

    print(f"Installed to {DEST}/")
    runner.stream(["ls", "-lh", f"{DEST}/"])
