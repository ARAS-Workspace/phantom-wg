#!/usr/bin/env python3
"""
Phantom-WG Modern: Cloudflare mode tool

Runs in phantom-nginx-tools for ./tools/prod.sh cloudflare. /cloudflare is
container-data/cloudflare of the install, /override.yml its
docker-compose.override.yml, read only. The settings of .env.cf come on
stdin as one JSON document: token, zone, hostnames.

  on        reads the zone, its SSL/TLS mode and Authenticated Origin Pulls,
            makes a key and a CSR here, takes an Origin CA certificate for the
            hostnames, takes the origin pull CA and the address list, writes
            the nginx snippets, the firewall rules and a candidate override;
            a failure after the certificate revokes it again
  off       writes the candidate override: the override as it was before
            the mode, or, when the operator changed it since, the override
            without the lines the mode added
  revoke    revokes the certificate of the mode in Cloudflare
  rollback  revokes the certificate of the candidate state
  refresh   writes the address list again
  status    prints the mode, its certificate and its address list

./tools/prod.sh cloudflare checks the candidate with Compose and puts it in
place. The token goes to api.cloudflare.com and nowhere else.

Usage:
    cloudflare.py {on|off|revoke|rollback|refresh|status}

Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details
WireGuard® is a registered trademark of Jason A. Donenfeld.
"""

from __future__ import annotations

import difflib
import hashlib
import io
import ipaddress
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from ruamel.yaml import YAML
from ruamel.yaml.comments import CommentedMap, CommentedSeq
from ruamel.yaml.scalarstring import DoubleQuotedScalarString

# ── Constants ────────────────────────────────────────────────────

ROOT = Path("/cloudflare")
OVERRIDE = Path("/override.yml")
SNIPPETS = ROOT / "phantom.d"
TLS_CERT = ROOT / "tls_cert"
TLS_KEY = ROOT / "tls_key"
STATE = ROOT / "state.json"
BEFORE = ROOT / "override.before.yml"
CANDIDATE = ROOT / "override.candidate.yml"
STATE_CANDIDATE = ROOT / "state.candidate.json"

API = "https://api.cloudflare.com/client/v4"
IPS_URL = f"{API}/ips"
ORIGIN_PULL_CA_URL = "https://developers.cloudflare.com/ssl/static/authenticated_origin_pull_ca.pem"
TIMEOUT = 30
VALIDITY_DAYS = 5475

MOUNT = "/etc/nginx/phantom.d"
TABLE = "phantom_cloudflare"

# What the mode writes into the override, by path. An override that holds
# one of these paths already stops the mode.
ENTRIES = {
    ("services", "nginx", "cap_add"): ["NET_ADMIN"],
    ("services", "nginx", "command"): ["sh", "-c", f"nft -f {MOUNT}/firewall.nft && exec nginx -g 'daemon off;'"],
    ("services", "nginx", "volumes"): [f"./container-data/cloudflare/phantom.d:{MOUNT}:ro"],
    ("secrets", "tls_cert"): {"file": "./container-data/cloudflare/tls_cert"},
    ("secrets", "tls_key"): {"file": "./container-data/cloudflare/tls_key"},
}
NOTE = "Cloudflare mode: ./tools/prod.sh cloudflare off takes these back"
DASHBOARD = "SSL/TLS, Origin Server, in the Cloudflare dashboard"


class Refused(Exception):
    """The action stops here: the message goes to stderr."""


class CloudflareRefused(Refused):
    """An answer of the Cloudflare API that is not a success."""

    def __init__(self, method: str, path: str, code: int, errors: str, need: str) -> None:
        super().__init__(f"Cloudflare refused {method} {path} ({code}): {errors}. The token needs: {need}.")
        self.code = code


# ── Helpers ──────────────────────────────────────────────────────

def say(text: str) -> None:
    print(text, flush=True)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "phantom-nginx-tools"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.read()
    except OSError as error:
        raise Refused(f"{url}: {error}") from error


def openssl(*args: str) -> str:
    done = subprocess.run(["openssl", *args], capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise Refused(done.stderr.strip() or f"openssl {args[0]} exited {done.returncode}")
    return done.stdout


def read_settings() -> dict:
    """token, zone and hostnames, as ./tools/prod.sh cloudflare read them from .env.cf."""
    try:
        settings = json.loads(sys.stdin.read())
        return {"token": settings["token"], "zone": settings["zone"], "hostnames": list(settings["hostnames"])}
    except (ValueError, KeyError, TypeError) as error:
        raise Refused(f"The settings on stdin are not whole ({error}).") from None


def yaml() -> YAML:
    """Round trip: the comments and quotes of the operator stay."""
    loader = YAML()
    loader.preserve_quotes = True
    loader.indent(mapping=2, sequence=4, offset=2)
    loader.width = 4096
    return loader


def dump(document: CommentedMap) -> str:
    stream = io.StringIO()
    yaml().dump(document, stream)
    return stream.getvalue()


def node(value):
    """A value of ENTRIES as block YAML with double quoted strings."""
    if isinstance(value, dict):
        mapping = CommentedMap()
        for key, item in value.items():
            mapping[key] = node(item)
        return mapping
    if isinstance(value, list):
        return CommentedSeq(node(item) for item in value)
    return DoubleQuotedScalarString(value)


def plain(value):
    return json.loads(json.dumps(value))


def lookup(document, path: tuple):
    """The value at path, None when a key on the way is missing."""
    found = document
    for key in path:
        if not isinstance(found, dict) or key not in found:
            return None
        found = found[key]
    return found


def load_override(data: bytes) -> CommentedMap:
    document = yaml().load(data.decode("utf-8")) if data.strip() else None
    if document is None:
        return CommentedMap()
    if not isinstance(document, dict):
        raise Refused("docker-compose.override.yml is not a YAML mapping.")
    return document


def mode_state() -> dict:
    if not STATE.is_file():
        raise Refused("Cloudflare mode is off.")
    return json.loads(STATE.read_text(encoding="utf-8"))


# ── Cloudflare ───────────────────────────────────────────────────

class Cloudflare:
    """The calls of the mode, each with the permission it needs."""

    def __init__(self, token: str) -> None:
        self._token = token

    def call(self, method: str, path: str, need: str, body: dict | None = None):
        data = None if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(f"{API}{path}", data=data, method=method, headers={
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
            "User-Agent": "phantom-nginx-tools",
        })
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                answer = json.loads(response.read())
        except urllib.error.HTTPError as error:
            raise CloudflareRefused(method, path, error.code, self._errors(error.read()), need) from None
        except OSError as error:
            raise Refused(f"{method} {path}: {error}") from None
        except ValueError:
            raise Refused(f"{method} {path}: an answer that is not JSON") from None
        if not answer.get("success"):
            raise CloudflareRefused(method, path, 200, self._errors(json.dumps(answer).encode()), need)
        return answer["result"]

    @staticmethod
    def _errors(body: bytes) -> str:
        try:
            errors = json.loads(body).get("errors") or []
            return "; ".join(f"{error.get('code')} {error.get('message')}" for error in errors) or "no reason given"
        except (ValueError, AttributeError):
            return "an answer that is not JSON"

    def zone_id(self, zone: str) -> str:
        found = self.call("GET", f"/zones?name={urllib.parse.quote(zone)}", "Zone - Zone - Read")
        if not found:
            raise Refused(f"The token sees no zone named {zone}. It needs Zone - Zone - Read on that zone.")
        return found[0]["id"]

    def require_origin_pulls(self, zone_id: str, zone: str) -> None:
        """Full (strict) and Authenticated Origin Pulls: nginx requires Cloudflare's certificate."""
        need = "Zone - Zone Settings - Read"
        mode = self.call("GET", f"/zones/{zone_id}/settings/ssl", need)["value"]
        if mode != "strict":
            raise Refused(f"The SSL/TLS mode of {zone} is {mode}. The mode needs Full (strict): set it, then run on again.")
        pulls = self.call("GET", f"/zones/{zone_id}/settings/tls_client_auth", need)["value"]
        if pulls != "on":
            raise Refused(
                f"Authenticated Origin Pulls (Global) is {pulls} for {zone}. Turn it on in {DASHBOARD}, then run on again."
            )

    def create_certificate(self, hostnames: list, csr: str) -> dict:
        body = {"hostnames": hostnames, "requested_validity": VALIDITY_DAYS, "request_type": "origin-ecc", "csr": csr}
        return self.call("POST", "/certificates", "Zone - SSL and Certificates - Edit", body)

    def revoke(self, certificate_id: str) -> None:
        """Revokes the certificate; one Cloudflare answers as revoked or unknown counts as gone."""
        try:
            self.call("DELETE", f"/certificates/{certificate_id}", "Zone - SSL and Certificates - Edit")
            say(f"Origin CA certificate {certificate_id}: revoked")
            return
        except CloudflareRefused as refused:
            first = refused
        try:
            read = self.call("GET", f"/certificates/{certificate_id}", "Zone - SSL and Certificates - Read")
            gone = bool(read.get("revoked_at"))
        except CloudflareRefused as refused:
            gone = refused.code == 404
        if not gone:
            raise first
        say(f"Origin CA certificate {certificate_id}: already revoked")


# ── The files of the mode ────────────────────────────────────────

def key_and_csr(zone: str) -> str:
    """A P-256 key in tls_key, 600 from its first byte, and the CSR of it."""
    csr = Path(tempfile.mkdtemp()) / "tls.csr"
    umask = os.umask(0o077)
    try:
        openssl(
            "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", str(TLS_KEY), "-out", str(csr), "-subj", f"/CN={zone}",
        )
    finally:
        os.umask(umask)
    return csr.read_text(encoding="utf-8")


def take_ca() -> None:
    """The origin pull CA Cloudflare publishes."""
    target = SNIPPETS / "cf_origin_pull_ca.pem"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(fetch(ORIGIN_PULL_CA_URL))
    openssl("x509", "-in", str(target), "-noout")
    say(f"Origin pull CA: {ORIGIN_PULL_CA_URL}")


def addresses() -> tuple:
    """Cloudflare's address ranges, each read as a network."""
    try:
        result = json.loads(fetch(IPS_URL))["result"]
        v4 = [str(ipaddress.IPv4Network(cidr)) for cidr in result["ipv4_cidrs"]]
        v6 = [str(ipaddress.IPv6Network(cidr)) for cidr in result["ipv6_cidrs"]]
    except (ValueError, KeyError, TypeError) as error:
        raise Refused(f"{IPS_URL}: an answer without the address lists ({error})") from error
    if not v4 or not v6:
        raise Refused(f"{IPS_URL}: an empty address list")
    return v4, v6


def write_lists(v4: list, v6: list) -> None:
    """The real IP snippet and the firewall rules, from one address list."""
    http = SNIPPETS / "http"
    http.mkdir(parents=True, exist_ok=True)
    real_ip = [
        f"# Cloudflare mode, from {IPS_URL}",
        *(f"set_real_ip_from {cidr};" for cidr in (*v4, *v6)),
        "real_ip_header CF-Connecting-IP;",
    ]
    (http / "cloudflare.conf").write_text("\n".join(real_ip) + "\n", encoding="utf-8")

    rules = [
        f"# Cloudflare mode, from {IPS_URL}",
        f"table inet {TABLE}",
        f"delete table inet {TABLE}",
        "",
        f"table inet {TABLE} {{",
        "    set cloudflare_v4 {",
        "        type ipv4_addr",
        "        flags interval",
        f"        elements = {{ {', '.join(v4)} }}",
        "    }",
        "",
        "    set cloudflare_v6 {",
        "        type ipv6_addr",
        "        flags interval",
        f"        elements = {{ {', '.join(v6)} }}",
        "    }",
        "",
        "    chain input {",
        "        type filter hook input priority filter; policy accept;",
        "        tcp dport 443 ip saddr != @cloudflare_v4 counter drop",
        "        tcp dport 443 ip6 saddr != @cloudflare_v6 counter drop",
        "    }",
        "}",
    ]
    (SNIPPETS / "firewall.nft").write_text("\n".join(rules) + "\n", encoding="utf-8")
    say(f"Cloudflare addresses: {len(v4)} IPv4, {len(v6)} IPv6")


def write_server() -> None:
    server = SNIPPETS / "server"
    server.mkdir(parents=True, exist_ok=True)
    lines = [
        "# Cloudflare mode: authenticated origin pulls",
        f"ssl_client_certificate {MOUNT}/cf_origin_pull_ca.pem;",
        "ssl_verify_client on;",
    ]
    (server / "cloudflare.conf").write_text("\n".join(lines) + "\n", encoding="utf-8")


# ── The override ─────────────────────────────────────────────────

def override_for_the_mode() -> tuple:
    """The override and its document, when it holds none of the paths of the mode."""
    data = OVERRIDE.read_bytes()
    document = load_override(data)
    taken = [".".join(path) for path in ENTRIES if lookup(document, path) is not None]
    if taken:
        lines = [f"  {name}" for name in taken]
        raise Refused("\n".join(["docker-compose.override.yml holds what the Cloudflare mode writes:", *lines]))
    return data, document


def lines_of(text: str) -> list:
    """The lines of a file with their line ends; a last line without one gets one."""
    return (text if text.endswith("\n") or not text else f"{text}\n").splitlines(keepends=True)


def added_blocks(before: str, after: str) -> list:
    """The runs of lines after adds to before. A line of before that after rewrites stops the mode."""
    old, new = lines_of(before), lines_of(after)
    blocks, rewritten = [], []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag == "insert":
            blocks.append(new[j1:j2])
        elif tag != "equal":
            rewritten.extend(f"  {line.rstrip()}" for line in old[i1:i2])
    if rewritten:
        raise Refused("\n".join([
            "Writing the mode would rewrite these lines of docker-compose.override.yml:", *rewritten,
            "The mode only adds lines. Bring them to the layout of docker-compose.override.yml.example.",
        ]))
    return blocks


def write_candidate(data: bytes, document: CommentedMap, certificate: dict) -> None:
    """The override with the entries of the mode, its state, and the override before them."""
    created = []
    noted = set()
    for path, value in ENTRIES.items():
        parent = document
        for depth, key in enumerate(path[:-1]):
            if key not in parent:
                parent[key] = CommentedMap()
                created.append(path[:depth + 1])
            parent = parent[key]
            if not isinstance(parent, dict):
                raise Refused(f"{'.'.join(path[:depth + 1])} of docker-compose.override.yml is not a mapping.")
        parent[path[-1]] = node(value)
        created.append(path)
        if path[:-1] not in noted:
            parent.yaml_set_comment_before_after_key(path[-1], before=NOTE, indent=2 * (len(path) - 1))
            noted.add(path[:-1])

    text = dump(document)
    blocks = added_blocks(data.decode("utf-8"), text)
    CANDIDATE.write_text(text, encoding="utf-8")
    BEFORE.write_bytes(data)
    state = {
        **certificate,
        "before": sha256(data),
        "after": sha256(text.encode("utf-8")),
        "created": [list(path) for path in created],
        "entries": {".".join(path): value for path, value in ENTRIES.items()},
        "blocks": blocks,
    }
    STATE_CANDIDATE.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")


# ── Actions ──────────────────────────────────────────────────────

def on() -> None:
    settings = read_settings()
    data, document = override_for_the_mode()
    cloudflare = Cloudflare(settings["token"])
    zone = settings["zone"]
    zone_id = cloudflare.zone_id(zone)
    cloudflare.require_origin_pulls(zone_id, zone)
    csr = key_and_csr(zone)

    try:
        issued = cloudflare.create_certificate(settings["hostnames"], csr)
    except CloudflareRefused:
        raise
    except Refused as lost:
        raise Refused(
            f"{lost}\nCloudflare may have issued the certificate before its answer was lost: look in {DASHBOARD}."
        ) from None
    certificate = {
        "zone": zone,
        "zone_id": zone_id,
        "certificate_id": issued["id"],
        "hostnames": issued.get("hostnames", settings["hostnames"]),
        "expires_on": issued.get("expires_on", ""),
    }
    say(f"Origin CA certificate {certificate['certificate_id']}: {', '.join(certificate['hostnames'])}")
    try:
        umask = os.umask(0o077)
        try:
            TLS_CERT.write_text(issued["certificate"], encoding="utf-8")
        finally:
            os.umask(umask)
        take_ca()
        write_lists(*addresses())
        write_server()
        write_candidate(data, document, certificate)
    except BaseException:
        try:
            cloudflare.revoke(certificate["certificate_id"])
        except Refused as refused:
            say(f"{refused}\nThe certificate {certificate['certificate_id']} stays in Cloudflare: revoke it in {DASHBOARD}.")
        raise


def off() -> None:
    state = mode_state()
    data = OVERRIDE.read_bytes()
    if sha256(data) == state["after"]:
        CANDIDATE.write_bytes(BEFORE.read_bytes())
        say("Override: back to what it was before the mode")
        return

    document = load_override(data)
    found = {name: lookup(document, tuple(name.split("."))) for name in state["entries"]}
    if all(value is None for value in found.values()):
        CANDIDATE.write_bytes(data)
        say("Override: holds none of the entries of the mode, it stays as it is")
        return

    changed = [name for name, value in state["entries"].items() if plain(found[name]) != value]
    if changed:
        lines = [f"  {name}" for name in changed]
        raise Refused("\n".join([
            "docker-compose.override.yml changed by hand where the Cloudflare mode wrote:", *lines,
            "The mode stays on. Restore these entries, or take every entry of the mode out of the override",
            "yourself, then run off again.",
        ]))

    # What the override means without the entries of the mode ...
    entries = {tuple(name.split(".")) for name in state["entries"]}
    for path in reversed([tuple(path) for path in state["created"]]):
        parent = lookup(document, path[:-1]) if len(path) > 1 else document
        if path in entries or parent[path[-1]] == {}:
            del parent[path[-1]]
    expected = plain(document)

    # ... and the text without the lines the mode added, every other byte as it is.
    lines = lines_of(data.decode("utf-8"))
    for block in state["blocks"]:
        starts = [i for i in range(len(lines) - len(block) + 1) if lines[i:i + len(block)] == block]
        if len(starts) != 1:
            raise Refused("\n".join([
                "The lines the Cloudflare mode added to docker-compose.override.yml moved or changed:",
                *(f"  {line.rstrip()}" for line in block),
                "The mode stays on. Take these lines out of the override yourself, then run off again.",
            ]))
        del lines[starts[0]:starts[0] + len(block)]
    text = "".join(lines)
    if plain(load_override(text.encode("utf-8"))) != expected:
        raise Refused("Taking out the lines of the mode changes other entries of docker-compose.override.yml. The mode stays on.")
    CANDIDATE.write_text(text, encoding="utf-8")
    say("Override: the lines of the mode come out, the rest stays as changed")


def revoke() -> None:
    settings = read_settings()
    Cloudflare(settings["token"]).revoke(mode_state()["certificate_id"])


def rollback() -> None:
    settings = read_settings()
    certificate_id = json.loads(STATE_CANDIDATE.read_text(encoding="utf-8"))["certificate_id"]
    try:
        Cloudflare(settings["token"]).revoke(certificate_id)
    except Refused as refused:
        raise Refused(f"{refused}\nThe certificate {certificate_id} stays in Cloudflare: revoke it in {DASHBOARD}.") from None


def refresh() -> None:
    mode_state()
    write_lists(*addresses())


def status() -> None:
    state = mode_state()
    say("Cloudflare mode: on")
    say(f"  Zone: {state['zone']}")
    say(f"  Origin CA certificate {state['certificate_id']}: {', '.join(state['hostnames'])}")
    for line in openssl("x509", "-in", str(TLS_CERT), "-noout", "-enddate").splitlines():
        say(f"  {line}")
    ca = openssl("x509", "-in", str(SNIPPETS / "cf_origin_pull_ca.pem"), "-noout", "-enddate").strip()
    say(f"  Origin pull CA: {ca}")
    listed = (SNIPPETS / "http" / "cloudflare.conf").read_text(encoding="utf-8").splitlines()
    ranges = [line.split()[1].rstrip(";") for line in listed if line.startswith("set_real_ip_from ")]
    v6 = sum(":" in cidr for cidr in ranges)
    say(f"  Cloudflare addresses: {len(ranges) - v6} IPv4, {v6} IPv6")
    as_written = sha256(OVERRIDE.read_bytes()) == state["after"]
    say("  Override: as the mode wrote it" if as_written else "  Override: changed since the mode wrote it")


ACTIONS = {"on": on, "off": off, "revoke": revoke, "rollback": rollback, "refresh": refresh, "status": status}


def main(argv: list) -> int:
    if len(argv) != 2 or argv[1] not in ACTIONS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        ACTIONS[argv[1]]()
    except Refused as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
