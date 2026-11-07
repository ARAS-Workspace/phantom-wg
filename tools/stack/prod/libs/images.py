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

The image source of this host and the images it gives.
"""

from __future__ import annotations

import re

from core import runner
from core.runner import ToolError
from stack.prod.libs import archive, compose

SOURCES = ("registry", "build", "archive")
SERVICES = ("daemon", "auth-service", "nginx")
DEFAULT_SOURCE = "registry"
VARIABLE = "PHANTOM_IMAGE_SOURCE"
SETTING = re.compile(rf"^[ \t]*(?:export[ \t]+)?{VARIABLE}[ \t]*=.*$", re.MULTILINE)


def _settings_file() -> str:
    """.env, else .env.example, as Compose takes them."""
    return ".env" if (runner.ROOT / ".env").is_file() else ".env.example"


def source() -> str:
    """The source Compose reads, so the tool and the stack never differ."""
    settings = runner.capture([
        "docker", "compose", "--project-directory", ".", "--env-file", _settings_file(),
        "-f", f"tools/compose/{DEFAULT_SOURCE}.yml", "config", "--environment",
    ])
    values = dict(line.split("=", 1) for line in settings.splitlines() if "=" in line)
    value = values.get(VARIABLE) or DEFAULT_SOURCE
    if value not in SOURCES:
        raise ToolError(f"Unknown image source: {value}\nUse one of: {', '.join(SOURCES)}")
    return value


def _compose(selected: str) -> list[str]:
    """Compose on the image file: on the stack, config --images also lists depends_on."""
    return ["docker", "compose", "-f", f"tools/compose/{selected}.yml"]


def _reference(selected: str, service: str) -> str:
    return runner.capture([*_compose(selected), "config", "--images", service])


def _present(reference: str) -> bool:
    return runner.probe(["docker", "image", "inspect", reference]).ok


def ensure(service: str) -> str:
    """The image of a service, from the source of this host when it is missing."""
    selected = source()
    reference = _reference(selected, service)
    if _present(reference):
        return reference

    if selected == "archive":
        raise ToolError(f"{reference} is not loaded. Run: ./tools/prod.sh images sync")
    action = "pull" if selected == "registry" else "build"
    print(f"Getting {reference}...")
    runner.stream([*_compose(selected), action, service])
    return reference


def status() -> None:
    selected = source()
    print(f"Image source: {selected}")
    if selected == "archive" and archive.version():
        print(f"  images/ version: {archive.version()}")
    for service in SERVICES:
        reference = _reference(selected, service)
        print(f"  {service:<13} {'present' if _present(reference) else 'missing':<8} {reference}")


def select(value: str) -> None:
    """Writes the source to .env. A source that is not there is refused first."""
    path = runner.ROOT / ".env"
    if not path.is_file():
        raise ToolError("Missing: .env\nRun './tools/prod.sh setup' first.")
    if value == "archive":
        archive.check()

    text = path.read_text(encoding="utf-8")
    line = f"{VARIABLE}={value}"
    changed, count = SETTING.subn(line, text)
    if not count:
        separator = "" if not text or text.endswith("\n") else "\n"
        changed = f"{text}{separator}{line}\n"
    path.write_text(changed, encoding="utf-8")

    print(f"Image source: {value}")
    print("  Apply it with: ./tools/prod.sh images sync, then ./tools/prod.sh up")


def pull() -> None:
    selected = source()
    if selected != "registry":
        print(f"Image source is {selected}, nothing to pull.")
        print("  Pull from the registry: ./tools/prod.sh images use registry")
        return
    print("Pulling images...")
    compose.run("pull")
    print("Images pulled.")


def built_here() -> bool:
    selected = source()
    if selected == "build":
        return True
    print(f"Images come from the {selected} source here, nothing to build.")
    print("  Fetch them:  ./tools/prod.sh images sync")
    print("  Build here:  ./tools/prod.sh images use build")
    return False


def build() -> None:
    if built_here():
        print("Building images...")
        compose.run("build")
        print("Images built.")


def sync() -> None:
    selected = source()
    if selected == "registry":
        pull()
    elif selected == "archive":
        archive.load()
    else:
        build()
