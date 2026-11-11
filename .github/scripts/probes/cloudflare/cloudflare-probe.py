#!/usr/bin/env python3
"""
The proofs of .github/workflows/verify-cloudflare.yml, run on the EC2 host
after the steps of the operator. DOMAIN is a proxied record of ZONE that
points to ORIGIN_IP, the address of this host: a request to DOMAIN goes out
to Cloudflare and comes back through it, a request to ORIGIN_IP comes
straight. HOST is the install, WORK holds it and the log of the cloudflare
commands. Each check prints an "ok" line; the first that fails prints "FAIL"
and exits 1.

Standard library only: it runs on the system Python of the host.

Usage: cloudflare-probe.py <stage>
  host          this host is ORIGIN_IP, DOMAIN resolves to Cloudflare, no
                stack and no install of an earlier run
  path          through Cloudflare: the dashboard, the API, a login
  visitor       Cloudflare, nginx and auth-service see the visitor's address
  around        a request to ORIGIN_IP that skips Cloudflare drops
  off           the certificate is revoked, nginx runs without the mode,
                ORIGIN_IP answers and Cloudflare answers 526
  revoke-taken  revokes each certificate of the run that is not revoked
"""

from __future__ import annotations

import ipaddress
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
HOST = Path(os.environ["HOST"])
WORK = Path(os.environ["WORK"])
LOG = WORK / "cloudflare.log"
PASSWORD_FILE = HOST / "container-data/secrets/production/.admin_password"
MODE_DIR = HOST / "container-data/cloudflare"
NGINX = "phantom-nginx"
TABLE = "phantom_cloudflare"
CLOUDFLARE_API = "https://api.cloudflare.com/client/v4"
IMDS = "http://169.254.169.254/latest"
DASHBOARD = "SSL/TLS, Origin Server, in the Cloudflare dashboard"
TRIES = 90
TIMEOUT = 10
AROUND = 5
TAKEN = re.compile(r"Origin CA certificate (\d+):")
REVOKED = re.compile(r"Origin CA certificate (\d+): (?:already )?revoked")

# DOMAIN has an A record and this host reaches Cloudflare over IPv4: every
# connection of this script goes over IPv4, so the visitor is ORIGIN_IP.
_getaddrinfo = socket.getaddrinfo


def _ipv4(*args, **kwargs):
    return [entry for entry in _getaddrinfo(*args, **kwargs) if entry[0] == socket.AF_INET]


socket.getaddrinfo = _ipv4


def proved(condition: bool, text: str) -> None:
    if not condition:
        sys.exit(f"FAIL {text}")
    print(f"ok   {text}", flush=True)


def request(url: str, token: str = "", body: dict | None = None, verify: bool = True,
            timeout: float = TIMEOUT) -> tuple[int, bytes]:
    """A body makes a POST, no body a GET. Status 0 when nothing answers."""
    context = ssl.create_default_context()
    if not verify:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    headers = {"Content-Type": "application/json", "User-Agent": "phantom-cloudflare-probe"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    call = urllib.request.Request(url, data=data, headers=headers)
    try:
        with urllib.request.urlopen(call, context=context, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except OSError:
        return 0, b""


def through(path: str, token: str = "", body: dict | None = None) -> tuple[int, bytes]:
    """A request to DOMAIN: out to Cloudflare, and through it to this host."""
    return request(f"https://{DOMAIN}{path}", token, body)


def direct(path: str, timeout: float = TIMEOUT) -> tuple[int, bytes]:
    """A request to ORIGIN_IP that skips Cloudflare; the origin certificate is not a public one."""
    return request(f"https://{ORIGIN_IP}{path}", verify=False, timeout=timeout)


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


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, encoding="utf-8", timeout=60, check=False)


def dropped() -> int:
    """The packets the rules of the mode dropped, once nginx holds them."""
    reason = ""
    for _ in range(TRIES):
        done = run("docker", "exec", NGINX, "nft", "list", "chain", "inet", TABLE, "input")
        if done.returncode == 0:
            return sum(int(packets) for packets in re.findall(r"counter packets (\d+)", done.stdout))
        reason = done.stderr.strip()
        time.sleep(1)
    sys.exit(f"FAIL nginx holds no rules of the mode: {reason}")


def login() -> str:
    password = PASSWORD_FILE.read_text(encoding="utf-8").strip()
    body = answered(
        lambda: through("/auth/login", body={"username": "admin", "password": password}), 200,
        "the admin logs in through Cloudflare",
    )
    return json.loads(body)["data"]["token"]


def cloudflare(method: str, path: str) -> tuple[int, dict]:
    """A call of the Cloudflare API with the token of the run."""
    call = urllib.request.Request(f"{CLOUDFLARE_API}{path}", method=method, headers={
        "Authorization": f"Bearer {os.environ['CF_API_TOKEN']}", "User-Agent": "phantom-cloudflare-probe",
    })
    try:
        with urllib.request.urlopen(call, timeout=30) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, {}


def revoked(identifier: str) -> bool:
    status, answer = cloudflare("GET", f"/certificates/{identifier}")
    if status == 404:
        return True
    if status != 200:
        sys.exit(f"FAIL Cloudflare answers {status} for certificate {identifier}")
    return bool(answer["result"].get("revoked_at"))


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
    proved(public == ORIGIN_IP, f"the public address of this host is ORIGIN_IP: {public}")

    with urllib.request.urlopen(f"{CLOUDFLARE_API}/ips", timeout=30) as response:
        networks = [ipaddress.ip_network(cidr) for cidr in json.loads(response.read())["result"]["ipv4_cidrs"]]
    resolved = sorted({entry[4][0] for entry in socket.getaddrinfo(DOMAIN, 443, type=socket.SOCK_STREAM)})
    outside = [address for address in resolved if not any(ipaddress.ip_address(address) in net for net in networks)]
    proved(bool(resolved) and not outside, f"{DOMAIN} resolves to Cloudflare: {', '.join(resolved)}")

    running = run("docker", "ps", "--filter", "name=phantom", "--format", "{{.Names}}")
    proved(running.returncode == 0, f"docker answers the runner {running.stderr.strip()}".rstrip())
    names = running.stdout.split()
    proved(not names, f"no phantom container runs {', '.join(names)}".rstrip())
    proved(not HOST.exists(), f"no install of an earlier run at {HOST}")


def stage_path() -> None:
    proved(True, f"nginx holds the rules of the mode, {dropped()} packets dropped so far")
    page = answered(lambda: through("/"), 200, "the dashboard answers through Cloudflare")
    proved(b'<div id="root">' in page, "the answer is the dashboard of this install")
    answered(lambda: through("/api/core/hello"), 401, "an anonymous API request answers through Cloudflare")
    token = login()
    answered(lambda: through("/api/core/hello", token), 200, "an authorized request reaches the daemon through Cloudflare")


def stage_visitor() -> None:
    trace = answered(lambda: through("/cdn-cgi/trace"), 200, "Cloudflare traces the request")
    seen = dict(line.split("=", 1) for line in trace.decode().splitlines() if "=" in line).get("ip", "")
    proved(seen == ORIGIN_IP, f"Cloudflare sees the visitor as {seen}")

    token = login()
    # nginx.Dockerfile links the access log to the container's stdout.
    lines = run("docker", "logs", "--tail", "200", NGINX).stdout.splitlines()
    logins = [line for line in lines if '"POST /auth/login ' in line]
    proved(bool(logins), "nginx logs the login")
    logged = logins[-1].split(" ", 1)[0]
    proved(logged == ORIGIN_IP, f"nginx logs the visitor's address, not Cloudflare's: {logged}")

    body = answered(
        lambda: through("/auth/audit?action=login_success&limit=1", token), 200, "the admin reads the audit log",
    )
    recorded = json.loads(body)["data"]["items"][0]["ip_address"]
    proved(recorded == ORIGIN_IP, f"auth-service records the login from the visitor's address: {recorded}")


def stage_around() -> None:
    before = dropped()
    status, _ = direct("/api/core/hello", timeout=AROUND)
    proved(status == 0, f"a request to {ORIGIN_IP} that skips Cloudflare gets no answer in {AROUND} seconds")
    after = dropped()
    proved(after > before, f"the rules of the mode dropped it: {before} -> {after} packets")


def stage_off() -> None:
    proved(not MODE_DIR.exists(), "the directory of the mode is gone")
    found = REVOKED.findall(LOG.read_text(encoding="utf-8"))
    proved(bool(found), "off names the certificate it revoked")
    proved(revoked(found[-1]), f"Cloudflare lists certificate {found[-1]} as revoked")
    caps = run("docker", "inspect", NGINX, "--format", "{{.HostConfig.CapAdd}}").stdout.strip()
    proved(caps == "[]", f"nginx runs without NET_ADMIN: {caps}")
    answered(lambda: direct("/api/core/hello"), 401, f"{ORIGIN_IP} answers without Cloudflare once the mode is off")
    answered(lambda: through("/api/core/hello"), 526, "Cloudflare refuses the certificate of the origin")


def stage_revoke_taken() -> None:
    if not LOG.is_file():
        print(f"     {LOG} is missing: the run took no certificate", flush=True)
        return
    taken = list(dict.fromkeys(TAKEN.findall(LOG.read_text(encoding="utf-8"))))
    if not taken:
        print("     the run took no certificate", flush=True)
    for identifier in taken:
        if revoked(identifier):
            proved(True, f"certificate {identifier} is revoked")
            continue
        status, answer = cloudflare("DELETE", f"/certificates/{identifier}")
        proved(
            status == 200 and answer.get("success"),
            f"certificate {identifier} is revoked at the end of the run ({status}); else revoke it in {DASHBOARD}",
        )


STAGES = {
    "host": stage_host, "path": stage_path, "visitor": stage_visitor, "around": stage_around, "off": stage_off,
    "revoke-taken": stage_revoke_taken,
}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in STAGES:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    STAGES[argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
