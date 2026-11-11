#!/usr/bin/env python3
"""
The proofs of .github/workflows/verify-migration.yml: an install of 1.1.5 in
OLD moves to 2.0.0 in NEW as MIGRATION tells. Runs as root on the EC2 host:
the files of both installs belong to root. DOMAIN points straight to
ORIGIN_IP, the address of this host, and the install serves it with a Let's
Encrypt certificate. WORK keeps what 1.1.5 held, for the checks after the
migration. Each check prints an "ok" line; the first that fails prints
"FAIL" and exits 1.

Standard library only: it runs on the system Python of the host.

Usage: migration-probe.py <stage> [arguments]
  host                this host is ORIGIN_IP, DOMAIN points to it, no stack
                      runs and no install is there
  version <dir> <v>   the install in dir is version v, at the commit of its
                      release tag
  serves <dir>        DOMAIN: a Let's Encrypt certificate, the dashboard, the
                      API, and a login with the password of dir
  add-clients         three clients in the running install
  export              the v4 config of migration-1, for the client jobs
  record              what 1.1.5 holds: clients, audit log, certificate
  handshake           migration-1 shook hands with the running daemon after
                      it started
  copied              container-data and the environment files of NEW are
                      those of OLD
  setup               setup of NEW wrote .env and the override and left the
                      copy as it was
  same-certificate    DOMAIN serves the certificate of 1.1.5
  clients             the running install lists the clients of 1.1.5
  audit               the audit log lists the entries of 1.1.5
  pins                the containers run the images NEW pins
"""

from __future__ import annotations

import base64
import datetime
import functools
import hashlib
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DOMAIN = os.environ["DOMAIN"]
ORIGIN_IP = os.environ["ORIGIN_IP"]
OLD = Path(os.environ["OLD"])
NEW = Path(os.environ["NEW"])
WORK = Path(os.environ["WORK"])
BASELINE = WORK / "baseline.json"
COPIED = WORK / "copied.json"
SETUP_LOG = WORK / "setup.log"
PASSWORD = "container-data/secrets/production/.admin_password"
CLIENTS = ("migration-1", "migration-2", "migration-3")
CONNECTED = "migration-1"
ENV_FILES = (".env.daemon", ".env.auth-service")
CONTAINERS = {"daemon": "phantom-daemon", "auth-service": "phantom-auth", "nginx": "phantom-nginx"}
IMDS = "http://169.254.169.254/latest"
TRIES = 90
TIMEOUT = 10


def proved(condition: bool, text: str) -> None:
    if not condition:
        sys.exit(f"FAIL {text}")
    print(f"ok   {text}", flush=True)


def request(path: str, token: str = "", body: dict | None = None) -> tuple[int, bytes]:
    """https://DOMAIN, its certificate verified. A body makes a POST. Status 0 when nothing answers."""
    headers = {"Content-Type": "application/json", "User-Agent": "phantom-migration-probe"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    payload = None if body is None else json.dumps(body).encode()
    call = urllib.request.Request(f"https://{DOMAIN}{path}", data=payload, headers=headers)
    try:
        with urllib.request.urlopen(call, timeout=TIMEOUT) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except OSError:
        return 0, b""


def answered(ask, expected: int, text: str) -> bytes:
    """Asks until the answer is expected; the stack may still be starting."""
    status, body = 0, b""
    for attempt in range(1, TRIES + 1):
        status, body = ask()
        if status == expected:
            proved(True, f"{text}: {status}")
            return body
        if attempt % 15 == 0:
            print(f"     still {status} after {attempt} tries: {text}", flush=True)
        time.sleep(1)
    sys.exit(f"FAIL {text}: {status}, expected {expected}")


def data(body: bytes):
    return json.loads(body)["data"]


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, encoding="utf-8", timeout=60, check=False)


def login(directory: Path) -> str:
    password = (directory / PASSWORD).read_text(encoding="utf-8").strip()
    body = answered(
        lambda: request("/auth/login", body={"username": "admin", "password": password}), 200,
        f"the admin logs in with the password of {directory}",
    )
    return data(body)["token"]


def certificate() -> dict:
    """The certificate DOMAIN serves, verified against the system's authorities."""
    context = ssl.create_default_context()
    with socket.create_connection((DOMAIN, 443), timeout=TIMEOUT) as raw, \
            context.wrap_socket(raw, server_hostname=DOMAIN) as tls:
        der = tls.getpeercert(binary_form=True)
        parsed = tls.getpeercert()
    issuer = dict(item[0] for item in parsed["issuer"])
    return {"sha256": hashlib.sha256(der).hexdigest(), "issuer": issuer.get("organizationName", ""),
            "until": parsed["notAfter"]}


def clients(token: str) -> list:
    body = answered(lambda: request("/api/core/clients/list?page=1&limit=100&order=asc", token), 200,
                    "the clients are listed")
    keep = ("name", "ipv4_address", "ipv6_address", "public_key_hex")
    return [{key: client[key] for key in keep} for client in data(body)["clients"]]


def audit(token: str) -> dict:
    body = answered(lambda: request("/auth/audit?page=1&limit=100&order=asc", token), 200,
                    "the admin reads the audit log")
    page = data(body)
    keep = ("id", "action", "ip_address", "timestamp")
    return {"total": page["total"], "items": [{key: item[key] for key in keep} for item in page["items"]]}


def hashes(root: Path) -> dict:
    """sha256 of every file of container-data and of the environment files of an install."""
    files = sorted(path for path in (root / "container-data").rglob("*") if path.is_file())
    files += [root / name for name in ENV_FILES]
    return {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest() for path in files}


def started(container: str) -> float:
    """When the container started, as Docker reports it."""
    text = run("docker", "inspect", container, "--format", "{{.State.StartedAt}}").stdout.strip()
    whole, _, rest = text.partition(".")
    fraction = re.sub(r"\D.*$", "", rest)[:6].ljust(6, "0")
    moment = datetime.datetime.strptime(f"{whole.rstrip('Z')}.{fraction}", "%Y-%m-%dT%H:%M:%S.%f")
    return moment.replace(tzinfo=datetime.timezone.utc).timestamp()


def utc(seconds: float) -> str:
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).strftime("%H:%M:%S UTC")


def baseline() -> dict:
    return json.loads(BASELINE.read_text(encoding="utf-8"))


# ── Stages ───────────────────────────────────────────────────────────


def stage_host() -> None:
    session = urllib.request.Request(
        f"{IMDS}/api/token", method="PUT", headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    with urllib.request.urlopen(session, timeout=5) as response:
        metadata_token = response.read().decode()
    metadata = urllib.request.Request(
        f"{IMDS}/meta-data/public-ipv4", headers={"X-aws-ec2-metadata-token": metadata_token},
    )
    with urllib.request.urlopen(metadata, timeout=5) as response:
        public = response.read().decode().strip()
    proved(public == ORIGIN_IP, f"the public address of this host is {public}")
    resolved = sorted({entry[4][0] for entry in socket.getaddrinfo(DOMAIN, 443, socket.AF_INET)})
    proved(resolved == [ORIGIN_IP], f"{DOMAIN} points straight to this host: {', '.join(resolved)}")
    running = run("docker", "ps", "--filter", "name=phantom", "--format", "{{.Names}}")
    proved(running.returncode == 0, f"docker answers {running.stderr.strip()}".rstrip())
    names = running.stdout.split()
    proved(not names, f"no phantom container runs {', '.join(names)}".rstrip())
    for path in (OLD, NEW, WORK):
        proved(not path.exists(), f"nothing at {path}")


def stage_version(directory: str, expected: str) -> None:
    text = (Path(directory) / "phantom_daemon/__init__.py").read_text(encoding="utf-8")
    found = re.search(r'^__version__ = "(.*)"$', text, re.MULTILINE)
    version = found[1] if found else ""
    proved(version == expected, f"{directory} is version {version}")
    tag = run("git", "-C", directory, "describe", "--tags", "--exact-match", "HEAD").stdout.strip()
    proved(tag == f"v{expected}", f"its commit carries the tag {tag or '(none)'}")


def stage_serves(directory: str) -> None:
    served = certificate()
    proved(served["issuer"] == "Let's Encrypt",
           f"{DOMAIN} serves a certificate of {served['issuer']}, until {served['until']}")
    page = answered(lambda: request("/"), 200, "the dashboard answers")
    proved(b'<div id="root">' in page, "the answer is the dashboard")
    answered(lambda: request("/api/core/hello"), 401, "an anonymous API request answers")
    token = login(Path(directory))
    answered(lambda: request("/api/core/hello", token), 200, "an authorized request reaches the daemon")


def stage_add_clients() -> None:
    token = login(OLD)
    for name in CLIENTS:
        assign = functools.partial(request, "/api/core/clients/assign", token, {"name": name})
        record = data(answered(assign, 201, f"client {name} is added"))
        print(f"     {name}: {record['ipv4_address']}, {record['ipv6_address']}", flush=True)


def stage_export() -> None:
    token = login(OLD)
    body = answered(
        lambda: request("/api/core/clients/config", token, {"name": CONNECTED, "version": "v4"}), 200,
        f"the v4 config of {CONNECTED} is exported",
    )
    config = base64.b64decode(data(body)).decode()
    target = Path(os.environ["RUNNER_TEMP"]) / "client" / "wg0.conf"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(config, encoding="utf-8")
    target.chmod(0o600)
    for path in (target.parent, target):
        os.chown(path, int(os.environ["SUDO_UID"]), int(os.environ["SUDO_GID"]))
    shown = [line for line in config.splitlines() if line.split("=")[0].strip() in ("Address", "Endpoint", "AllowedIPs")]
    proved(any(line.endswith(f"{ORIGIN_IP}:51820") for line in shown), f"the config points to {ORIGIN_IP}:51820")
    for line in shown:
        print(f"     {line}", flush=True)


def stage_record() -> None:
    WORK.mkdir(mode=0o700, parents=True, exist_ok=True)
    token = login(OLD)
    held = {"clients": clients(token), "audit": audit(token), "certificate": certificate()}
    proved(len(held["audit"]["items"]) == held["audit"]["total"], "the audit log of 1.1.5 fits one page")
    BASELINE.write_text(json.dumps(held, indent=2) + "\n", encoding="utf-8")
    proved(True, f"1.1.5 holds {len(held['clients'])} clients and {held['audit']['total']} audit entries")
    proved(True, f"its certificate is {held['certificate']['sha256'][:16]}..., until {held['certificate']['until']}")


def stage_handshake() -> None:
    token = login(OLD)
    body = answered(lambda: request("/api/core/wireguard/peer", token, {"name": CONNECTED}), 200,
                    f"the daemon knows the peer {CONNECTED}")
    peer = data(body)
    since = started(CONTAINERS["daemon"])
    proved(peer["latest_handshake"] > since,
           f"{CONNECTED} shook hands at {utc(peer['latest_handshake'])} from {peer['endpoint']}, "
           f"after the daemon started at {utc(since)}")


def stage_copied() -> None:
    old, new = hashes(OLD), hashes(NEW)
    proved(bool(old) and old == new, f"{len(new)} files of {NEW} are byte for byte those of {OLD}")
    COPIED.write_text(json.dumps(new, indent=2) + "\n", encoding="utf-8")


def stage_setup() -> None:
    log = SETUP_LOG.read_text(encoding="utf-8")
    for line in ("Created .env from .env.example",
                 "Created docker-compose.override.yml from docker-compose.override.yml.example",
                 ".env.daemon already exists, skipping.", ".env.auth-service already exists, skipping."):
        proved(line in log, f"setup: {line}")
    for line in ("Generating WireGuard keypair", "Bootstrapping auth service",
                 "Generating self-signed TLS certificate", "Creating the address pool"):
        proved(line not in log, f"setup did not run: {line}")
    copied = json.loads(COPIED.read_text(encoding="utf-8"))
    proved(hashes(NEW) == copied, f"the {len(copied)} copied files are as step 4 left them")


def stage_same_certificate() -> None:
    served, held = certificate(), baseline()["certificate"]
    proved(served["sha256"] == held["sha256"],
           f"{DOMAIN} serves the certificate of 1.1.5: {served['sha256'][:16]}..., until {served['until']}")


def stage_clients() -> None:
    listed, held = clients(login(OLD)), baseline()["clients"]
    proved(listed == held, f"the {len(held)} clients of 1.1.5, with their addresses and keys: "
                           f"{', '.join(client['name'] for client in listed)}")


def stage_audit() -> None:
    read, held = audit(login(OLD)), baseline()["audit"]
    count = len(held["items"])
    proved(read["items"][:count] == held["items"],
           f"the first {count} entries are those of 1.1.5, with their ids, actions, addresses and times")
    proved(read["total"] > held["total"], f"{read['total'] - held['total']} entries of 2.0.0 follow them")


def stage_pins() -> None:
    text = (NEW / "tools/compose/registry.yml").read_text(encoding="utf-8")
    pins = dict(re.findall(r"^ {2}([a-z-]+):\n {4}image: (\S+)$", text, re.MULTILINE))
    for service, container in CONTAINERS.items():
        running = run("docker", "inspect", container, "--format", "{{.Config.Image}}").stdout.strip()
        proved(running == pins.get(service), f"{container} runs {running}")


STAGES = {
    "host": stage_host, "version": stage_version, "serves": stage_serves, "add-clients": stage_add_clients,
    "export": stage_export, "record": stage_record, "handshake": stage_handshake, "copied": stage_copied,
    "setup": stage_setup, "same-certificate": stage_same_certificate, "clients": stage_clients,
    "audit": stage_audit, "pins": stage_pins,
}


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in STAGES:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    STAGES[argv[1]](*argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
