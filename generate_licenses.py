#!/usr/bin/env python3
"""Writes THIRD_PARTY_LICENSES from cargo-about.

Runs cargo-about against about.toml, which carries both the accepted licence
list and the target triples the release builds for. Nothing here decides what
a licence is or whether it is allowed — about.toml states the policy and
cargo-about enforces it; a crate it cannot resolve stops the run.

Unlike the Go bridges there is no licenses/ tree: cargo-about returns the
licence texts inline, so they are written into this one file.

    python3 generate_licenses.py
    python3 generate_licenses.py --check
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import textwrap

CRATE = "firewall-bridge-linux"
RULE = "=" * 80
SUB = "-" * 80

HEADER = textwrap.dedent("""\
    ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
    ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
    ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
    ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
    ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

    THIRD PARTY LICENSES
    ================================================================================

    Phantom-WG / firewall-bridge
    Copyright (c) 2025 ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret Limited Şirketi
    Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
    Licensed under AGPL-3.0 - see LICENSE file for details

    Maintained by: Rıza Emre ARAS <r.emrearas@proton.me>

    HOW TO READ THIS FILE

      DEPENDENCIES lists the Rust crates compiled into the shared library the
      release ships, resolved for both target triples in about.toml. "Offered"
      is the licence expression the crate declares; "Taken" is the one that
      applies here, picked by the order of the accepted list in about.toml.

      Crates that are not compiled for either target do not appear.
      proc-macro2, quote, syn, unicode-ident, serde and serde_derive are
      in Cargo.lock only because serde_json and serde_core declare them
      under [target.'cfg(any())'.dependencies], a condition no target
      satisfies. None of them is built, so none is redistributed.

      LICENSE TEXTS below carries the text of every licence taken, as shipped
      by the crate it came from. Crates sharing a byte-identical text share an
      entry. This project's own AGPL-3.0 is not repeated here; it is in
      LICENSE.

      DEPENDENCIES and LICENSE TEXTS come from cargo-about. SYSTEM LIBRARIES
      and LICENSE COMPATIBILITY are written by hand: cargo-about reads Cargo
      metadata, and a system library linked through build.rs is outside it.

      Two groups of Python dependencies exist and neither ships in the package:

        PyYAML is optional and loaded lazily. firewall_bridge/presets.py
        imports it inside the function that reads a preset from YAML, and
        raises a clear ImportError if it is absent. Installing it is the
        operator's choice and only needed on that path.

        pytest, pytest-cov, coverage, docker and rich run the test suite.
        requirements.txt pins them and their transitive dependencies.

      This file is generated. Regenerate with:

          python3 generate_licenses.py

      about.toml is the licence policy: cargo-about refuses to produce
      anything for a crate whose licence is not listed there.
    """)


SYSTEM = textwrap.dedent("""\
    Resolved from the operating system rather than from Cargo, so
    cargo-about does not see them.

    | Library     | License           | SPDX Identifier   | URL                                     |
    |-------------|-------------------|-------------------|-----------------------------------------|
    | libnftables | GPL-2.0-only      | GPL-2.0-only      | https://netfilter.org/projects/nftables/ |
    | libmnl      | LGPL-2.1-or-later | LGPL-2.1-or-later | https://netfilter.org/projects/libmnl/   |

    Usage Note:
    firewall-bridge links against libnftables (dynamically) to manage nftables
    rules via the nft_ctx API; build.rs emits the link flag and the build host
    needs libnftables-dev. All firewall rules are isolated in the "inet phantom"
    table, separate from system UFW/iptables rules.

    libmnl is a transitive dependency of libnftables for minimal netlink
    communication. Routing operations use raw NETLINK_ROUTE sockets directly
    via libc, without additional library dependencies.
    """)

COMPATIBILITY = textwrap.dedent("""\
    Every licence taken above is permissive and compatible with AGPL-3.0.

    libnftables (GPL-2.0-only) is not bundled with firewall-bridge. It is
    installed from the operating system's package repository when the user
    builds the container image, and is loaded dynamically at runtime.

    libmnl (LGPL-2.1-or-later) is not linked by firewall-bridge. It is a
    dependency of libnftables and comes with it from the operating system's
    package repository.
    """)


def die(msg: str) -> None:
    sys.exit(f"generate_licenses: {msg}")


def plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def collect(root: pathlib.Path) -> dict:
    if shutil.which("cargo-about") is None:
        die("cargo-about not on PATH — "
            "cargo install cargo-about --locked --features cli")
    done = subprocess.run(
        ["cargo-about", "generate", "--format", "json", "--fail"],
        cwd=root, capture_output=True, text=True)
    if done.returncode != 0:
        die(f"cargo-about failed:\n{done.stderr.strip()}")
    return json.loads(done.stdout)


def section(title: str) -> list[str]:
    return [RULE, title, RULE, ""]


def table(crates: list[dict]) -> list[str]:
    head = ("Crate", "Version", "Offered", "Taken", "Repository")
    rows = [(c["package"]["name"], c["package"]["version"],
             c["package"].get("license") or "—", c["_taken"],
             c["package"].get("repository") or "—") for c in crates]
    w = [max(len(r[i]) for r in [head, *rows]) for i in range(4)]
    return [f"| {head[0]:<{w[0]}} | {head[1]:<{w[1]}} | {head[2]:<{w[2]}} | {head[3]:<{w[3]}} | {head[4]}",
            "|" + "|".join("-" * (x + 2) for x in w) + "|" + "-" * 12,
            *(f"| {a:<{w[0]}} | {b:<{w[1]}} | {c:<{w[2]}} | {d:<{w[3]}} | {e}"
              for a, b, c, d, e in rows)]


def build(root: pathlib.Path) -> str:
    data = collect(root)

    taken: dict[str, str] = {}
    for lic in data["licenses"]:
        for use in lic.get("used_by", []):
            taken[use["crate"]["name"]] = lic["id"]

    crates = sorted((c for c in data["crates"] if c["package"]["name"] != CRATE),
                    key=lambda c: c["package"]["name"])
    if not crates:
        die("cargo-about returned no third-party crates")
    for c in crates:
        name = c["package"]["name"]
        if name not in taken:
            die(f"{name}: cargo-about resolved no licence")
        c["_taken"] = taken[name]

    texts = [lic for lic in data["licenses"]
             if any(u["crate"]["name"] != CRATE for u in lic.get("used_by", []))]
    texts.sort(key=lambda L: (L["id"],
                              sorted(u["crate"]["name"] for u in L["used_by"])))

    out = [HEADER, *section(f"DEPENDENCIES — {plural(len(crates), 'crate')}"),
           *table(crates), "",
           *section("SYSTEM LIBRARIES"), SYSTEM,
           *section("LICENSE COMPATIBILITY"), COMPATIBILITY,
           *section(f"LICENSE TEXTS — {plural(len(texts), 'text')}")]
    for lic in texts:
        users = sorted(u["crate"]["name"] for u in lic["used_by"]
                       if u["crate"]["name"] != CRATE)
        out += [SUB, f"{lic['id']} — {', '.join(users)}", SUB, "",
                lic["text"].strip("\n"), ""]
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", type=pathlib.Path,
                    default=pathlib.Path(__file__).resolve().parent,
                    help="repository root (default: this script's directory)")
    ap.add_argument("--check", action="store_true",
                    help="write nothing; exit 1 if THIRD_PARTY_LICENSES is stale")
    args = ap.parse_args()

    root = args.root.resolve()
    doc = build(root)
    target = root / "THIRD_PARTY_LICENSES"

    if args.check:
        current = target.read_text(encoding="utf-8") if target.is_file() else ""
        if current != doc:
            print("THIRD_PARTY_LICENSES is stale", file=sys.stderr)
            return 1
        print("THIRD_PARTY_LICENSES is current", file=sys.stderr)
        return 0

    target.write_text(doc, encoding="utf-8")
    print(f"{target.name}: {len(doc.splitlines())} lines, {len(doc.encode())} bytes",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
