#!/usr/bin/env python3
"""
Checks a running install of tools/prod.sh from inside its host: the admin logs
in, an authorized request reaches the daemon of this tree, the address pool is
the expected one and nginx serves the dashboard. Each check prints an "ok"
line; the first that fails prints "FAIL" and exits 1.

Standard library only: it runs on the system Python of the host.

Usage: install-matrix-check.py <install dir> <expected IPv4 pool>
"""

from __future__ import annotations

import json
import re
import ssl
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

PASSWORD_FILE = "container-data/secrets/production/.admin_password"
VERSION_FILE = "phantom_daemon/__init__.py"
TRIES = 60


def proved(condition: bool, text: str) -> None:
    if not condition:
        sys.exit(f"FAIL {text}")
    print(f"ok   {text}", flush=True)


def request(path: str, token: str = "", body: dict | None = None) -> tuple[int, bytes]:
    """A body makes a POST, no body a GET. Status 0 when nothing answers."""
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    sent = urllib.request.Request(f"https://127.0.0.1{path}", data=data, headers=headers)
    try:
        with urllib.request.urlopen(sent, context=context, timeout=5) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, b""
    except OSError:
        return 0, b""


def answered(path: str, token: str = "", body: dict | None = None) -> dict:
    """The data of the first 200 within TRIES seconds: the first requests can meet a 502."""
    status = 0
    for _ in range(TRIES):
        status, raw = request(path, token, body)
        if status == 200:
            return json.loads(raw)["data"]
        time.sleep(1)
    sys.exit(f"FAIL {path} answers {status}")


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root, pool = Path(sys.argv[1]), sys.argv[2]

    password = (root / PASSWORD_FILE).read_text(encoding="utf-8").strip()
    token = answered("/auth/login", body={"username": "admin", "password": password})["token"]
    proved(bool(token), "the admin logs in")

    version = re.search(r'^__version__ = "(.+)"$', (root / VERSION_FILE).read_text(encoding="utf-8"), re.MULTILINE)[1]
    hello = answered("/api/core/hello", token)
    proved(hello["version"] == version, f"an authorized request reaches the daemon of this tree, version {version}")

    network = answered("/api/core/network", token)
    proved(network["ipv4_subnet"] == pool, f"the address pool is {network['ipv4_subnet']}, IPv6 {network['ipv6_subnet']}")

    status, _ = request("/")
    proved(status == 200, "nginx serves the dashboard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
