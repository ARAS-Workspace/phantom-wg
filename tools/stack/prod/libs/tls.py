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

The self-signed TLS certificate of this host.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from core.runner import ToolError
from stack.prod.libs import compose, identity, images, paths

SUBJECT = "/C=TR/ST=Istanbul/L=Istanbul/O=Phantom-WG/OU=Phantom Certification Authority/CN=phantom-wg/emailAddress=ca@phantom.tc"
SAN = "DNS:phantom-wg,DNS:localhost,IP:127.0.0.1"


def _paths() -> tuple[Path, Path]:
    return paths.secrets() / "tls_cert", paths.secrets() / "tls_key"


def present() -> bool:
    return all(paths.filled(path) for path in _paths())


def require_whole() -> None:
    """A cert without its key, or the reverse, is not replaced without being asked."""
    found = [path for path in _paths() if paths.filled(path)]
    if len(found) == 1:
        lost = next(path for path in _paths() if path not in found)
        raise ToolError(
            f"{paths.SECRETS_DIR}/{lost.name} is missing, {found[0].name} is not.\n"
            "Restore it, or start over: ./tools/prod.sh setup-tls -f"
        )


def generate() -> None:
    compose.require_down()
    cert_path, key_path = _paths()
    identity.make_dir(cert_path.parent)
    image = images.ensure(compose.DAEMON)

    print("Generating self-signed TLS certificate...")
    runner.stream([
        "docker", "run", "--rm", *identity.as_operator(),
        "-v", f"{cert_path.parent}:/secrets",
        image,
        "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
        "-days", "365", "-nodes",
        "-keyout", "/secrets/tls_key",
        "-out", "/secrets/tls_cert",
        "-subj", SUBJECT,
        "-addext", f"subjectAltName={SAN}",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,digitalSignature,keyCertSign,keyEncipherment",
        "-addext", "extendedKeyUsage=serverAuth",
    ])

    key_path.chmod(0o600)
    cert_path.chmod(0o600)

    print(f"TLS certificate written to {paths.SECRETS_DIR}/")
    print(f"  Cert: {paths.SECRETS_DIR}/tls_cert")
    print(f"  Key:  {paths.SECRETS_DIR}/tls_key")
    print("\nCertificate details:")
    details = runner.capture([
        "docker", "run", "--rm", *identity.as_operator(),
        "-v", f"{cert_path.parent}:/secrets:ro",
        image, "openssl", "x509", "-in", "/secrets/tls_cert", "-noout", "-subject", "-issuer", "-dates",
    ])
    for line in details.splitlines():
        print(f"  {line}")
