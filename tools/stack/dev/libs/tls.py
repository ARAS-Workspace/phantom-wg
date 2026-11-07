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

The self-signed TLS certificate of development.
"""

from __future__ import annotations

from pathlib import Path

from core import runner
from stack.dev.libs import compose, images, paths

SUBJECT = "/C=TR/ST=Istanbul/L=Istanbul/O=Phantom-WG/OU=Development/CN=localhost"
SAN = "DNS:localhost,IP:127.0.0.1"


def _paths() -> tuple[Path, Path]:
    return paths.secrets() / "tls_cert", paths.secrets() / "tls_key"


def present() -> bool:
    return all(paths.filled(path) for path in _paths())


def generate() -> None:
    compose.require_down()
    cert_path, key_path = _paths()
    cert_path.parent.mkdir(parents=True, exist_ok=True)
    image = images.ensure(compose.DAEMON)

    print("Generating self-signed TLS certificate...")
    runner.stream([
        "docker", "run", "--rm", *images.as_operator(),
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
