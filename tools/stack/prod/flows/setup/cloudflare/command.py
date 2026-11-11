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


cloudflare: the stack served through Cloudflare, set from .env.cf. on reads
the zone through the API token, takes an Origin CA certificate for a key made
here, and writes the mode: nginx requires Cloudflare's authenticated origin
pull certificate, its port 443 drops what does not come from Cloudflare's
addresses, and it logs the visitor's address. off revokes the certificate and
takes the mode back; with --keep-certificate it takes the mode back and leaves
the certificate in Cloudflare. refresh writes Cloudflare's address list again. The work
runs in phantom-nginx-tools, built here from helper/; the override changes
only after Compose accepts the new one, and the last one stays as
docker-compose.override.yml.bak. A step of on that fails after the
certificate revokes it again.
"""

from __future__ import annotations

import json
import os
import re
import shutil
from pathlib import Path

from core import runner
from core.commands import argument
from core.runner import ToolError
from stack.prod.libs import compose, gates, host, identity, paths

ABOUT = "Serve through Cloudflare (Origin CA, origin pulls, firewall)"
ARGUMENTS = (
    argument("action", nargs="?", default="status", choices=("status", "on", "refresh", "off")),
    argument("--keep-certificate", action="store_true"),
)
USAGE = "cloudflare [status|on|refresh|off [--keep-certificate]]"
KEEP = "./tools/prod.sh cloudflare off --keep-certificate"
DASHBOARD = "SSL/TLS, Origin Server, in the Cloudflare dashboard"

HELPER = Path(__file__).resolve().parent / "helper"
IMAGE = "phantom-nginx-tools:latest"
OVERRIDE = "docker-compose.override.yml"
SETTINGS = ".env.cf"
EXAMPLE = ".env.cf.example"
KEYS = ("CF_API_TOKEN", "CF_ZONE", "CF_HOSTNAMES")
STATE = "state.json"
CANDIDATE = "override.candidate.yml"
STATE_CANDIDATE = "state.candidate.json"
LABEL = re.compile(r"^(?!-)[a-z0-9-]{1,63}(?<!-)$")


def _active() -> bool:
    return (paths.cloudflare() / STATE).is_file()


def _domain(name: str) -> bool:
    labels = name.split(".")
    return len(labels) >= 2 and all(LABEL.match(label) for label in labels)


def _in_zone(name: str, zone: str) -> bool:
    bare = name.removeprefix("*.")
    return _domain(bare) and (bare == zone or bare.endswith(f".{zone}"))


def _read(path: Path) -> dict:
    """KEY=value lines of .env.cf; a value in one pair of quotes loses them."""
    values = {}
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        text = line.strip()
        if not text or text.startswith("#"):
            continue
        key, separator, value = text.partition("=")
        if not separator or key.strip() not in KEYS:
            raise ToolError(f"{SETTINGS} line {number}: expected one of {', '.join(KEYS)}, as KEY=value.")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def _settings() -> dict:
    """token, zone and hostnames from .env.cf, which the tool writes from its example and holds at 600."""
    env = runner.ROOT / SETTINGS
    if not env.is_file():
        shutil.copyfile(runner.ROOT / EXAMPLE, env)
        identity.own(env)
        env.chmod(0o600)
        raise ToolError(f"{SETTINGS} is written from {EXAMPLE}. Fill CF_API_TOKEN and CF_ZONE in it, then run again.")
    env.chmod(0o600)

    values = _read(env)
    token = values.get("CF_API_TOKEN", "")
    zone = values.get("CF_ZONE", "").lower().rstrip(".")
    empty = [key for key, value in (("CF_API_TOKEN", token), ("CF_ZONE", zone)) if not value]
    if empty:
        raise ToolError(f"Fill {' and '.join(empty)} in {SETTINGS}, then run again.")
    if any(character.isspace() for character in token):
        raise ToolError(f"CF_API_TOKEN of {SETTINGS} holds a space.")
    if not _domain(zone):
        raise ToolError(f"CF_ZONE of {SETTINGS} is not a domain name: {zone}")

    names = [name.strip().lower() for name in values.get("CF_HOSTNAMES", "").split(",") if name.strip()]
    hostnames = names or [zone, f"*.{zone}"]
    outside = [name for name in hostnames if not _in_zone(name, zone)]
    if outside:
        lines = [f"  {name}" for name in outside]
        raise ToolError("\n".join([f"CF_HOSTNAMES of {SETTINGS} holds names outside {zone}:", *lines]))
    return {"token": token, "zone": zone, "hostnames": hostnames}


def _build() -> None:
    print(f"Building {IMAGE}...")
    runner.capture(["docker", "build", "-q", "-t", IMAGE, str(HELPER)])


def _tools(action: str, settings: dict | None = None) -> None:
    """helper/cloudflare.py as the operator, on the Cloudflare directory and the override; settings on stdin."""
    args = [
        "docker", "run", "--rm", *(["-i"] if settings else []), *identity.as_operator(),
        "-v", f"{paths.cloudflare()}:/cloudflare",
        "-v", f"{runner.ROOT / OVERRIDE}:/override.yml:ro",
        "-v", f"{HELPER / 'cloudflare.py'}:/app/cloudflare.py:ro",
        IMAGE, action,
    ]
    if settings is None:
        runner.stream(args)
    else:
        runner.feed(args, json.dumps(settings))


def _validate() -> None:
    try:
        compose.run("-f", "docker-compose.yml", "-f", str(paths.cloudflare() / CANDIDATE), "config", "-q")
    except ToolError:
        raise ToolError(f"Compose refused the new override. {OVERRIDE} is unchanged.") from None


def _replace() -> None:
    """The candidate takes the place of the override; the last override stays as .bak."""
    override = runner.ROOT / OVERRIDE
    backup = override.with_name(f"{OVERRIDE}.bak")
    shutil.copy2(override, backup)
    identity.own(backup)
    os.replace(paths.cloudflare() / CANDIDATE, override)


def _on() -> None:
    if _active():
        raise ToolError("Cloudflare mode is on. Turn it off first: ./tools/prod.sh cloudflare off")
    if not (runner.ROOT / OVERRIDE).is_file():
        raise ToolError(f"{OVERRIDE} is missing. Run: ./tools/prod.sh setup")
    settings = _settings()

    _build()
    directory = paths.cloudflare()
    identity.make_dir(directory)
    try:
        _tools("on", settings)
    except ToolError:
        shutil.rmtree(directory, ignore_errors=True)
        raise

    # A certificate is out from here: a stop before the state is kept revokes it.
    try:
        _validate()
        os.replace(directory / STATE_CANDIDATE, directory / STATE)
    except BaseException:
        try:
            _tools("rollback", settings)
        finally:
            shutil.rmtree(directory, ignore_errors=True)
        raise

    # The state is kept: a stop from here leaves the mode on, and off takes it back.
    _replace()
    print("Cloudflare mode is on. Apply it: ./tools/prod.sh up")


def _refresh() -> None:
    if not _active():
        raise ToolError("Cloudflare mode is off.")
    _build()
    _tools("refresh")
    print("Apply the new lists: ./tools/prod.sh restart nginx")


def _off(keep_certificate: bool) -> None:
    if not _active():
        raise ToolError("Cloudflare mode is off.")
    settings = None
    if not keep_certificate:
        try:
            settings = _settings()
        except ToolError as error:
            raise ToolError(f"{error}\nOr take the mode back and leave its certificate in Cloudflare: {KEEP}") from None

    directory = paths.cloudflare()
    certificate_id = json.loads((directory / STATE).read_text(encoding="utf-8"))["certificate_id"]
    _build()
    try:
        _tools("off")
        _validate()
        if settings is not None:
            try:
                _tools("revoke", settings)
            except ToolError:
                raise ToolError("\n".join([
                    "The certificate is not revoked and the mode stays on. Fix CF_API_TOKEN in .env.cf and run off",
                    f"again, or take the mode back and revoke the certificate in {DASHBOARD} yourself:",
                    f"  {KEEP}",
                ])) from None
    except ToolError:
        (directory / CANDIDATE).unlink(missing_ok=True)
        raise

    _replace()
    shutil.rmtree(directory)
    if keep_certificate:
        print(f"Origin CA certificate {certificate_id} stays in Cloudflare: revoke it in {DASHBOARD}.")
    print("Cloudflare mode is off. Apply it: ./tools/prod.sh up")


def _status() -> None:
    if not _active():
        print("Cloudflare mode: off")
        return
    _build()
    _tools("status")


ACTIONS = {"status": _status, "on": _on, "refresh": _refresh}


def run(action: str, keep_certificate: bool) -> None:
    if keep_certificate and action != "off":
        raise ToolError(f"Usage: ./tools/prod.sh {USAGE}")
    gates.enforce(host.DOCKER_GATES)
    if action == "off":
        _off(keep_certificate)
    else:
        ACTIONS[action]()
