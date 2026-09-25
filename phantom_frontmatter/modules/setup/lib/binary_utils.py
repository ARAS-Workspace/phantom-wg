"""
Setup Module — wstunnel Binary Installer

Extracts a bundled wstunnel binary into the install dir's ``bin/``.
The binaries ship inside the package at
``phantom_frontmatter/bin/lib/wstunnel_<version>_linux_<arch>.tar.gz``.

Bumping the version means rebuilding both archives via the
``ARAS-Workspace/wstunnel`` "Release Linux" workflow, placing the
fresh tarballs into ``phantom_frontmatter/bin/lib/``, and updating
``WSTUNNEL_VERSION`` below in the same commit.

Architecture is selected at install time by mapping ``uname -m``
to ``amd64`` or ``arm64``.

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0
"""

import re
import tarfile
from pathlib import Path
from typing import Callable, Optional


# Pinned version. To upgrade: drop new
# wstunnel_<NEW>_linux_amd64.tar.gz / wstunnel_<NEW>_linux_arm64.tar.gz
# into the bundled directory and bump this constant in the same commit.
WSTUNNEL_VERSION = "10.5.2+Phantom.Patch.1"

# Where the bundled tarballs live inside the package. Resolved
# relative to this file:
#     modules/setup/lib/binary_utils.py
#       → modules/setup/lib/        (parent)
#       → modules/setup/            (parent)
#       → modules/                  (parent)
#       → phantom_frontmatter/      (parent)
#       → phantom_frontmatter/bin/lib
BUNDLED_DIR = Path(__file__).parent.parent.parent.parent / "bin" / "lib"

# uname -m → release filename arch suffix
ARCH_MAP = {
    "x86_64": "amd64",
    "amd64":  "amd64",
    "aarch64": "arm64",
    "arm64":  "arm64",
}


def detect_architecture(run_command_func: Callable) -> Optional[str]:
    """Map ``uname -m`` to the bundled tarball's arch suffix.

    Returns ``amd64`` or ``arm64`` on a supported platform and
    ``None`` otherwise.
    """
    result = run_command_func(["uname", "-m"])
    if not result["success"]:
        return None
    raw = result["stdout"].strip()
    return ARCH_MAP.get(raw)


def bundled_tarball_path(arch: str) -> Path:
    """Return the path to the bundled tarball for the given arch."""
    filename = f"wstunnel_{WSTUNNEL_VERSION}_linux_{arch}.tar.gz"
    return BUNDLED_DIR / filename


def install_wstunnel(
    bin_dir: Path,
    run_command_func: Callable,
    logger,
) -> bool:
    """Extract the bundled wstunnel binary into ``bin_dir``.

    Returns True if ``bin_dir/wstunnel`` ends up executable. Logs
    and returns False on any failure (unsupported arch, missing
    bundled tarball, extract error, etc).

    The ``run_command_func`` parameter is used to call out to
    ``uname -m`` for architecture detection.
    """
    bin_dir.mkdir(parents=True, exist_ok=True)

    arch = detect_architecture(run_command_func)
    if arch is None:
        logger.error(
            "Unsupported architecture for the bundled wstunnel binary "
            "(only amd64 and arm64 are shipped)"
        )
        return False

    tarball = bundled_tarball_path(arch)
    if not tarball.exists():
        logger.error(
            f"Bundled wstunnel tarball missing: {tarball}. "
            "Re-install the frontmatter package or rebuild the "
            "ARAS-Workspace/wstunnel release."
        )
        return False

    logger.info(
        f"Extracting bundled wstunnel {WSTUNNEL_VERSION} ({arch}) "
        f"from {tarball}"
    )

    try:
        with tarfile.open(tarball, "r:gz") as archive:
            member = _find_binary_member(archive)
            if member is None:
                logger.error(
                    f"Bundled tarball {tarball} does not contain a "
                    "'wstunnel' file"
                )
                return False
            # Extract just the binary, flattening any directory prefix
            with archive.extractfile(member) as src:
                if src is None:
                    logger.error(
                        f"Failed to read 'wstunnel' from {tarball}"
                    )
                    return False
                binary = bin_dir / "wstunnel"
                with open(binary, "wb") as dst:
                    while True:
                        chunk = src.read(1024 * 1024)
                        if not chunk:
                            break
                        dst.write(chunk)
    except (tarfile.TarError, OSError) as e:
        logger.error(f"Failed to extract {tarball}: {e}")
        return False

    binary = bin_dir / "wstunnel"
    try:
        binary.chmod(0o755)
    except OSError as e:
        logger.warning(f"Could not chmod {binary}: {e}")

    logger.info(f"wstunnel {WSTUNNEL_VERSION} installed at {binary}")
    return True


def _find_binary_member(archive: tarfile.TarFile) -> Optional[tarfile.TarInfo]:
    """Locate the 'wstunnel' file inside an open tarball.

    Accepts both flat archives (``wstunnel``) and ones with a single
    directory prefix (``wstunnel-X.Y.Z/wstunnel``). Anything else
    returns None.
    """
    for member in archive.getmembers():
        if not member.isfile():
            continue
        name = member.name
        if name == "wstunnel" or name.endswith("/wstunnel"):
            return member
    return None


def get_installed_version(
    binary_path: Path,
    run_command_func: Callable,
) -> Optional[str]:
    """Return the version reported by ``wstunnel --version``.

    Used by ``setup status`` and the verification step at the end
    of ``setup init``. Returns None if the binary doesn't run or
    its output doesn't include a recognizable version triple.
    """
    if not binary_path.exists():
        return None
    result = run_command_func([str(binary_path), "--version"])
    if not result["success"]:
        return None
    match = re.search(r"(\d+\.\d+\.\d+)", result["stdout"] + result["stderr"])
    return match.group(1) if match else None
