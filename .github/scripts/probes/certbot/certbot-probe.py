#!/usr/bin/env python3
"""
The proofs of .github/workflows/verify-certbot.yml, run on the EC2 host after
the steps of the operator. DOMAIN is a DNS-only record that points to
ORIGIN_IP, the address of this host: Let's Encrypt reaches port 80 of this
host for it. HOST is the install, WORK holds it and the certificate the
proofs keep. Each check prints an "ok" line; the first that fails prints
"FAIL" and exits 1.

Standard library only: it runs on the system Python of the host.

Usage: certbot-probe.py <stage>
  host              this host is ORIGIN_IP, DOMAIN points to it, no stack
                    runs and no install of an earlier run is there
  before            DOMAIN serves the certificate of setup, which the
                    authorities of the system do not know
  certificate       DOMAIN serves a Let's Encrypt certificate, the one in
                    tls_cert, and the two files belong to the operator
  same-certificate  DOMAIN serves the certificate the certificate stage kept
  state             the certbot state holds entries of root
  reset             nothing is left of the certbot state
"""

from __future__ import annotations

import hashlib
import json
import os
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
SECRETS = HOST / "container-data/secrets/production"
STATE = HOST / "container-data/certbot"
KEPT = WORK / "certificate.json"
IMDS = "http://169.254.169.254/latest"
END = "-----END CERTIFICATE-----"
TRIES = 60
TIMEOUT = 10


def proved(condition: bool, text: str) -> None:
    if not condition:
        sys.exit(f"FAIL {text}")
    print(f"ok   {text}", flush=True)


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, encoding="utf-8", timeout=60, check=False)


def handshake() -> dict:
    """The certificate DOMAIN serves, verified against the system's authorities and the name."""
    context = ssl.create_default_context()
    with socket.create_connection((DOMAIN, 443), timeout=TIMEOUT) as raw, \
            context.wrap_socket(raw, server_hostname=DOMAIN) as tls:
        der = tls.getpeercert(binary_form=True)
        parsed = tls.getpeercert()
    issuer = dict(item[0] for item in parsed["issuer"])
    names = [value for kind, value in parsed.get("subjectAltName", ()) if kind == "DNS"]
    return {"sha256": hashlib.sha256(der).hexdigest(), "issuer": issuer.get("organizationName", ""),
            "names": names, "serial": parsed["serialNumber"], "until": parsed["notAfter"]}


def verified() -> dict:
    """handshake, once nginx answers; a certificate the system does not trust fails at once."""
    reason = "no attempt was made"
    for _ in range(TRIES):
        try:
            return handshake()
        except ssl.SSLCertVerificationError as error:
            sys.exit(f"FAIL {DOMAIN} serves a certificate the system does not trust: {error.verify_message}")
        except OSError as error:
            reason = str(error)
            time.sleep(1)
    sys.exit(f"FAIL {DOMAIN} did not answer on 443: {reason}")


def dashboard() -> int:
    """The status of the dashboard over a verified connection; 0 when nothing answers."""
    try:
        with urllib.request.urlopen(f"https://{DOMAIN}/", timeout=TIMEOUT) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code
    except OSError:
        return 0


def entries() -> list:
    """What the certbot state holds at its top level, each with its owner."""
    if not STATE.is_dir():
        return []
    return sorted((entry.name, entry.stat(follow_symlinks=False).st_uid) for entry in os.scandir(STATE))


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
    proved(not HOST.exists(), f"no install of an earlier run at {HOST}")


def stage_before() -> None:
    reason = "no attempt was made"
    for _ in range(TRIES):
        try:
            shown = handshake()
        except ssl.SSLCertVerificationError as error:
            proved(True, f"the certificate of setup does not pass the authorities of the system: {error.verify_message}")
            return
        except OSError as error:
            reason = str(error)
            time.sleep(1)
            continue
        sys.exit(f"FAIL {DOMAIN} serves a certificate of {shown['issuer']} before certbot ran")
    sys.exit(f"FAIL {DOMAIN} did not answer on 443: {reason}")


def stage_certificate() -> None:
    shown = verified()
    proved(shown["issuer"] == "Let's Encrypt",
           f"{DOMAIN} serves a certificate of {shown['issuer']}, verified against the authorities of the system")
    proved(DOMAIN in shown["names"], f"the certificate names {', '.join(shown['names'])}, until {shown['until']}")
    proved(dashboard() == 200, "the dashboard answers over the verified connection: 200")

    pem = (SECRETS / "tls_cert").read_text(encoding="utf-8")
    first = pem[: pem.index(END) + len(END)]
    on_disk = hashlib.sha256(ssl.PEM_cert_to_DER_cert(first)).hexdigest()
    proved(on_disk == shown["sha256"], f"nginx serves the certificate of {SECRETS.relative_to(HOST)}/tls_cert")
    for name in ("tls_cert", "tls_key"):
        info = (SECRETS / name).stat()
        proved(info.st_uid == os.getuid(), f"{name} belongs to the operator, mode {info.st_mode & 0o777:o}")
    proved((SECRETS / "tls_key").stat().st_mode & 0o077 == 0, "tls_key is closed to the group and to others")

    WORK.mkdir(parents=True, exist_ok=True)
    KEPT.write_text(json.dumps(shown, indent=2) + "\n", encoding="utf-8")
    print(f"     serial {shown['serial']}", flush=True)


def stage_same_certificate() -> None:
    kept = json.loads(KEPT.read_text(encoding="utf-8"))
    shown = verified()
    proved(shown["sha256"] == kept["sha256"],
           f"{DOMAIN} serves the same certificate: serial {shown['serial']}, kept {kept['serial']}")


def stage_state() -> None:
    held = entries()
    for name, owner in held:
        print(f"     {name}: uid {owner}", flush=True)
    of_root = [name for name, owner in held if owner == 0]
    proved(bool(of_root), f"the certbot state holds {len(of_root)} entries of root, of {len(held)}")


def stage_reset() -> None:
    held = entries()
    proved(not held, f"nothing is left of the certbot state: {len(held)} entries")


STAGES = {
    "host": stage_host, "before": stage_before, "certificate": stage_certificate,
    "same-certificate": stage_same_certificate, "state": stage_state, "reset": stage_reset,
}


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in STAGES:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    STAGES[argv[1]]()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
