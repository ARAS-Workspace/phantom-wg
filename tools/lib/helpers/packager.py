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

Production packager — copies deployment-ready files into dist/phantom-wg-modern/.

Included:
    SETUP                                   Setup and usage guide
    UPDATE                                  Update and maintenance guide
    LICENSE                                 AGPL-3.0 license
    THIRD_PARTY_LICENSES                    Dependency licenses
    Dockerfile                              Production image build
    nginx.Dockerfile                        Nginx image build
    docker-compose.yml                      Production compose stack
    docker-compose.override.yml.example     Compose override template
    .env.example                            Compose environment template
    .env.daemon.example                     Daemon environment template
    .env.auth-service.example               Auth service environment template
    requirements.txt                        Python dependencies
    phantom_daemon/                         Daemon source
    services/auth-service/                  Auth service (full)
    services/nginx/                         Nginx config
    services/react-spa/dist/                SPA build output only
    tools/prod.sh                           Production CLI
    tools/prod.vars                         Production variables
    tools/compose/build.yml                 Local image build
    tools/compose/registry.yml              Registry images
    tools/compose/MANIFEST.json             Contents of the registry images
    tools/lib/common.sh                     Color helpers
    tools/lib/images.sh                     Image source and references
    tools/lib/keys.sh                       WireGuard key generation
    tools/lib/auth.sh                       Auth service bootstrap
    tools/lib/tls.sh                        TLS certificate generation
    tools/lib/compose.sh                    Docker Compose operations
    tools/lib/certbot.sh                    Let's Encrypt certificates
    tools/lib/helpers/certbot/              Certbot image and script
    tools/lib/helpers/update/               Update hook

Excluded:
    dev.Dockerfile, docker-compose-dev.yml, e2e_tests/, lib/,
    scripts/, tests/, typings/, container-data/,
    services/react-spa/src, services/react-spa/node_modules,
    tools/dev.sh, tools/dev.vars, tools/compose/dev.yml, tools/lib/db.sh,
    tools/lib/test.sh, tools/lib/spa.sh, tools/lib/stubs.sh,
    tools/lib/openapi.sh, tools/lib/package.sh,
    tools/lib/helpers/packager.py, tools/lib/helpers/gen_stubs.py,
    tools/lib/templates/, __pycache__, *.pyc, .gitkeep

Templates:
    tools/lib/templates/production/.gitignore → .gitignore

Usage:
    python tools/lib/helpers/packager.py
    python tools/lib/helpers/packager.py --clean
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent.parent
DIST = ROOT / "dist"
PKG_NAME = "phantom-wg-modern"
TEMPLATES = ROOT / "tools" / "lib" / "templates"

INCLUDE = [
    "SETUP",
    "UPDATE",
    "LICENSE",
    "THIRD_PARTY_LICENSES",
    "Dockerfile",
    "nginx.Dockerfile",
    "docker-compose.yml",
    "docker-compose.override.yml.example",
    ".env.example",
    ".env.daemon.example",
    ".env.auth-service.example",
    "requirements.txt",
    "phantom_daemon",
    "services/auth-service",
    "services/nginx",
    "services/react-spa/dist",
    "tools/prod.sh",
    "tools/prod.vars",
    "tools/compose/build.yml",
    "tools/compose/registry.yml",
    "tools/compose/MANIFEST.json",
    "tools/lib/common.sh",
    "tools/lib/images.sh",
    "tools/lib/keys.sh",
    "tools/lib/auth.sh",
    "tools/lib/tls.sh",
    "tools/lib/compose.sh",
    "tools/lib/certbot.sh",
    "tools/lib/helpers/certbot",
    "tools/lib/helpers/update",
]

# (template_source, package_destination) pairs
TEMPLATE_FILES = [
    ("production/.gitignore", ".gitignore"),
]

EXCLUDE_SUFFIXES = (".pyc", ".pyo")


def _should_exclude(path: Path) -> bool:
    return "__pycache__" in path.parts or path.suffix in EXCLUDE_SUFFIXES or path.name == ".gitkeep"


def _copy_tree(src: Path, dst: Path) -> int:
    """Copy a file or directory tree, returning file count."""
    if src.is_file():
        if _should_exclude(src):
            return 0
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return 1

    count = 0
    for item in sorted(src.rglob("*")):
        if not item.is_file() or _should_exclude(item):
            continue
        target = dst / item.relative_to(src)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        count += 1
    return count


def package(clean: bool = False) -> Path:
    pkg_dir = DIST / PKG_NAME

    if clean and DIST.exists():
        shutil.rmtree(DIST)

    pkg_dir.mkdir(parents=True, exist_ok=True)

    total = 0
    for entry in INCLUDE:
        src = ROOT / entry
        if not src.exists():
            print(f"  SKIP (not found): {entry}")
            continue
        dst = pkg_dir / entry
        count = _copy_tree(src, dst)
        total += count
        label = f"{entry}/" if src.is_dir() else entry
        print(f"  {label} ({count} files)")

    # Templates — copied to fixed destinations, decoupled from source layout
    for template_src, package_dst in TEMPLATE_FILES:
        src = TEMPLATES / template_src
        if not src.exists():
            print(f"  SKIP template (not found): {template_src}")
            continue
        dst = pkg_dir / package_dst
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        total += 1
        print(f"  {package_dst} (template: {template_src})")

    # Ensure shell scripts are executable
    tools_dir = pkg_dir / "tools"
    if tools_dir.exists():
        for sh in tools_dir.rglob("*.sh"):
            sh.chmod(0o755)

    print(f"\nTotal: {total} files → {pkg_dir}")
    return pkg_dir


def main() -> None:
    parser = argparse.ArgumentParser(description="Package phantom-daemon for production")
    parser.add_argument("--clean", action="store_true", help="Remove dist/ before packaging")
    args = parser.parse_args()
    package(clean=args.clean)


if __name__ == "__main__":
    main()
