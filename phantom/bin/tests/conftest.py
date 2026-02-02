# noinspection DuplicatedCode
# ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
# ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
# ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
# ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
# ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
# ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝
# Copyright (c) 2025 Rıza Emre ARAS
# Licensed under AGPL-3.0 - see LICENSE file for details
# Third-party licenses - see THIRD_PARTY_LICENSES file for details
# WireGuard® is a registered trademark of Jason A. Donenfeld.

import sys
from pathlib import Path
import pytest

INSTALL_DIR = Path("/opt/phantom-wg")

sys.path.insert(0, str(INSTALL_DIR))

# Import PhantomAPI after path setup
from phantom.api.core import PhantomAPI


def check_debian():
    return Path("/etc/debian_version").exists()


def check_phantom_installation():
    venv_python = INSTALL_DIR / ".phantom-venv/bin/python"

    if not INSTALL_DIR.exists():
        return False, "Installation directory not found"

    if not venv_python.exists():
        return False, "Virtual environment not found"

    return True, "Installation verified successfully"


# noinspection PyUnusedLocal
def pytest_configure(config):
    # Check Debian
    if not check_debian():
        pytest.exit("ERROR: This script requires Debian/Ubuntu", returncode=1)

    # Check Phantom-WG installation
    installed, message = check_phantom_installation()
    if not installed:
        pytest.exit(f"ERROR: {message}", returncode=1)


@pytest.fixture(scope="session")
def phantom_api():
    api = PhantomAPI()
    yield api
