#!/usr/bin/env python3
"""Writes THIRD_PARTY_LICENSES from pip-licenses.

Builds a throwaway environment from requirements.txt and runs pip-licenses
against it, in order: fail-on gate, then report. Nothing here classifies a
licence — pip-licenses reads what each distribution declares. A string it
reports that is not an SPDX identifier has to be mapped in SPDX below, and a
package missing from LICENSE_URLS stops the run, so neither list can drift
quietly away from the dependency set.

pip-licenses only sees installed distributions, so two environments are
created under one temporary directory: one holding requirements.txt, one
holding the tool. They are kept apart because installing the tool beside the
dependencies adds 34 distributions of its own to the inventory.

Unlike the bridges there is no licenses/ tree and no licence text: the
packaged tree carries requirements.txt, not wheels, so no third-party code is
redistributed from here. See HOW TO READ THIS FILE in the output.

    python3 generate_licenses.py
    python3 generate_licenses.py --check
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap

REQUIREMENTS = "requirements.txt"
TARGET = "THIRD_PARTY_LICENSES"
RULE = "=" * 80

# Dockerfile pins python:3.12.13-slim-trixie; the inventory is resolved for the
# same minor version.
PYTHON = "3.12"

# pip-licenses is pinned so the report does not move with the host's tooling.
TOOL = "pip-licenses==5.5.5"

# Licence policy. A package resolving to anything unlisted stops the run.
#
# Order matters for a package that offers a choice: the first entry below that
# the offer satisfies is the one taken. uvloop is the only such package in the
# set — it ships LICENSE-APACHE and LICENSE-MIT side by side — so MIT ahead of
# Apache-2.0 takes MIT.
ACCEPTED = (
    "MIT",
    "Apache-2.0",
    "BSD-3-Clause",
    "MPL-2.0",
    "PSF-2.0",
)

# Substrings pip-licenses must not find in any declared licence. Matched with
# --partial-match, so GPL also covers AGPL and LGPL.
FAIL_ON = "GPL;SSPL;BUSL;CDDL;EPL;OSL;Proprietary"

# pip-licenses prints the metadata verbatim, and not every distribution writes
# an SPDX identifier there. These are the strings the current set produces that
# need rewriting; anything else stops the run instead of being guessed at.
SPDX = {
    "MIT License": "MIT",
}

# Where each licence can be read. pip-licenses reports the project URL, not the
# licence file, so these are written by hand; the run stops if a package in the
# report has no entry. blob/HEAD resolves to each repository's default branch.
LICENSE_URLS = {
    "annotated-doc": "https://github.com/fastapi/annotated-doc/blob/HEAD/LICENSE",
    "annotated-types": "https://github.com/annotated-types/annotated-types/blob/HEAD/LICENSE",
    "anyio": "https://github.com/agronholm/anyio/blob/HEAD/LICENSE",
    "certifi": "https://github.com/certifi/python-certifi/blob/HEAD/LICENSE",
    "cffi": "https://github.com/python-cffi/cffi/blob/HEAD/LICENSE",
    "click": "https://github.com/pallets/click/blob/HEAD/LICENSE.txt",
    "fastapi": "https://github.com/fastapi/fastapi/blob/HEAD/LICENSE",
    "h11": "https://github.com/python-hyper/h11/blob/HEAD/LICENSE.txt",
    "httpcore": "https://github.com/encode/httpcore/blob/HEAD/LICENSE.md",
    "httptools": "https://github.com/MagicStack/httptools/blob/HEAD/LICENSE",
    "httpx": "https://github.com/encode/httpx/blob/HEAD/LICENSE.md",
    "idna": "https://github.com/kjd/idna/blob/HEAD/LICENSE.md",
    "pycparser": "https://github.com/eliben/pycparser/blob/HEAD/LICENSE",
    "pydantic": "https://github.com/pydantic/pydantic/blob/HEAD/LICENSE",
    "pydantic-core": "https://github.com/pydantic/pydantic-core/blob/HEAD/LICENSE",
    "pynacl": "https://github.com/pyca/pynacl/blob/HEAD/LICENSE",
    "python-dotenv": "https://github.com/theskumar/python-dotenv/blob/HEAD/LICENSE",
    "pyyaml": "https://github.com/yaml/pyyaml/blob/HEAD/LICENSE",
    "starlette": "https://github.com/Kludex/starlette/blob/HEAD/LICENSE.md",
    "typing-extensions": "https://github.com/python/typing_extensions/blob/HEAD/LICENSE",
    "typing-inspection": "https://github.com/pydantic/typing-inspection/blob/HEAD/LICENSE",
    "uvicorn": "https://github.com/Kludex/uvicorn/blob/HEAD/LICENSE.md",
    "uvloop": "https://github.com/MagicStack/uvloop/blob/HEAD/LICENSE-MIT",
    "watchfiles": "https://github.com/samuelcolvin/watchfiles/blob/HEAD/LICENSE",
    "websockets": "https://github.com/python-websockets/websockets/blob/HEAD/LICENSE",
}


HEADER = textwrap.dedent("""\
    ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
    ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
    ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
    ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
    ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

    THIRD PARTY LICENSES
    ================================================================================

    Phantom-WG / auth-service
    Copyright (c) 2025 ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret Limited Şirketi
    Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
    Licensed under AGPL-3.0 - see LICENSE file for details

    Maintained by: Rıza Emre ARAS <r.emrearas@proton.me>

    HOW TO READ THIS FILE

      DEPENDENCIES lists every Python distribution the container image
      installs. requirements.in pins seven of them; the rest are what the
      resolver pulled in, and "Required By" is the via graph uv wrote into
      requirements.txt. None of them is conditional — requirements.txt carries
      no environment markers, so every listed version installs on every
      platform the image is built for.

      No third-party code is redistributed from this repository. The packaged
      tree carries auth_service/, the Dockerfile and requirements.txt; pip
      installs the wheels when the consumer builds the image, and each wheel
      brings its own licence text in its .dist-info/licenses/ directory.
      LICENSE URLS below is where the same text can be read upstream.

      DEPENDENCIES comes from pip-licenses. LICENSE URLS, BUNDLED NATIVE CODE,
      SYSTEM LIBRARIES AND BASE IMAGE and LICENSE COMPATIBILITY are written by
      hand: pip-licenses reads distribution metadata, and neither a licence
      file's address nor a library linked by the image is in it.

      Three packages need a word on how their licence was read:

        uvloop declares "MIT License" in its metadata and lists both Apache
        Software License and MIT in its classifiers, shipping LICENSE-APACHE
        and LICENSE-MIT side by side. It is offered under either; MIT is the
        one taken here, and the URL points at LICENSE-MIT.

        annotated-types declares no licence at all — neither a
        License-Expression nor a License field. Only its classifier says MIT
        License, and that is where its entry comes from.

        certifi is MPL-2.0, but the file in its wheel is not the licence text:
        it is the MPL notice block pointing at mozilla.org/MPL/2.0/, which is
        what MPL-2.0 section 3.1 asks a distributor to pass on. Nothing here
        distributes certifi in executable form, so section 3.2 does not apply.

      This file is generated. Regenerate with:

          python3 generate_licenses.py

      ACCEPTED in the script is the licence policy: a package resolving to
      anything unlisted stops the run before this file is written.
    """)


BUNDLED = textwrap.dedent("""\
    Eight of the distributions ship a compiled extension, nine modules in all.
    Measured on the manylinux x86_64 wheels, every one of them lists only
    glibc and GCC runtime libraries in DT_NEEDED (libc, libpthread, librt,
    libdl, libgcc_s and the loader), with no DT_RPATH and no DT_RUNPATH, so
    whatever C or Rust each was built from is linked into the extension
    rather than loaded from the image.

    | Package       | Modules | Size      | Links in  | Licence in the wheel |
    |---------------|---------|-----------|-----------|----------------------|
    | uvloop        |       1 | 15578 KiB | libuv     | no                   |
    | PyNaCl        |       1 |  5189 KiB | libsodium | yes, ISC             |
    | pydantic_core |       1 |  4769 KiB | Rust      | no                   |
    | PyYAML        |       1 |  2616 KiB | libyaml   | no                   |
    | httptools     |       2 |  1706 KiB | llhttp    | no                   |
    | watchfiles    |       1 |  1097 KiB | Rust      | no                   |
    | cffi          |       1 |   340 KiB | libffi    | no                   |
    | websockets    |       1 |    37 KiB | —         | —                    |

    PyNaCl is the only one that carries its bundled library's licence, as
    licenses/licenses/LICENSE.libsodium.txt inside the wheel:

      https://github.com/pyca/pynacl/blob/HEAD/src/libsodium/LICENSE

    The others ship their own licence only. Nothing in this repository
    redistributes those wheels, so the gap stays upstream's; a consumer that
    republishes a built image inherits it.
    """)


SYSTEM = textwrap.dedent("""\
    Resolved from the base image rather than from a wheel, so pip-licenses
    does not see them.

    | Component                      | License          | SPDX Identifier |
    |--------------------------------|------------------|-----------------|
    | python:3.12.13-slim-trixie     | PSF-2.0 + Debian | PSF-2.0         |

    The image installs no system library of its own. PyNaCl's manylinux wheel
    has libsodium compiled in and declares only glibc's own libraries and the
    loader among its needed objects, so cryptographic operations are served by
    the bundled copy; its ISC licence travels in the wheel and is listed under
    BUNDLED NATIVE CODE.

    CPython itself is PSF-2.0 and arrives with the base image; the Debian
    packages underneath it carry their own licences, which Debian keeps
    inside the image as /usr/share/doc/<package>/copyright.
    """)


COMPATIBILITY = textwrap.dedent("""\
    MIT, BSD-3-Clause, Apache-2.0 and PSF-2.0 are permissive and allow use in
    this AGPL-3.0 project.

    certifi is MPL-2.0, which is file-level copyleft rather than permissive.
    Section 1.12 of the MPL names the GNU Affero General Public License,
    Version 3.0 among its Secondary Licenses, and section 3.3 permits
    distributing a Larger Work that combines MPL-covered software with a work
    governed by one, provided the covered software is not marked Incompatible
    With Secondary Licenses. certifi's notice carries no such marking.
    certifi is installed from PyPI when the image is built and is imported as
    published; nothing here modifies it.

    No GPL-family licence appears in the dependency set; the run stops if one
    does.
    """)


def die(msg: str) -> None:
    sys.exit(f"generate_licenses: {msg}")


def canon(name: str) -> str:
    """PEP 503 normalised distribution name."""
    return re.sub(r"[-_.]+", "-", name).lower()

# noinspection PyDeprecation
def uv(*args: str) -> None:
    tool = shutil.which("uv")
    if tool is None:
        die("uv not on PATH — https://docs.astral.sh/uv/getting-started/installation/")
    done = subprocess.run([tool, *args], capture_output=True, text=True)
    if done.returncode != 0:
        die(f"uv {args[0]} {args[1]} failed:\n{done.stderr.strip()}")


def environments(root: pathlib.Path, tmp: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path]:
    """Install requirements.txt and the tool into two separate environments."""
    target, tools = tmp / "target", tmp / "tools"
    uv("venv", str(target), "--python", PYTHON, "-q")
    uv("pip", "install", "-q", "--python", str(target / "bin" / "python"),
       "-r", str(root / REQUIREMENTS))
    uv("venv", str(tools), "--python", PYTHON, "-q")
    uv("pip", "install", "-q", "--python", str(tools / "bin" / "python"), TOOL)
    return target, tools


def pip_licenses(tools: pathlib.Path, target: pathlib.Path,
                 *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [str(tools / "bin" / "pip-licenses"),
         "--python", str(target / "bin" / "python"), *args],
        capture_output=True, text=True)


def pins(root: pathlib.Path) -> dict[str, str]:
    """version and via graph for every pin in requirements.txt."""
    out: dict[str, str] = {}
    for line in (root / REQUIREMENTS).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Za-z0-9][^ =]*)==([^ \\]+)", line)
        if m:
            out[canon(m.group(1))] = m.group(2).strip()
    if not out:
        die(f"{REQUIREMENTS} carries no pins")
    return out


def graph(root: pathlib.Path) -> dict[str, list[str]]:
    """The via comments uv writes under each pin: package -> what needs it."""
    via: dict[str, list[str]] = {}
    name, reading = None, False
    for line in (root / REQUIREMENTS).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^([A-Za-z0-9][^ =]*)==", line)
        if m:
            name, reading = canon(m.group(1)), False
            via[name] = []
            continue
        text = line.strip()
        if text.startswith("--hash"):
            reading = False
        elif text.startswith("# via"):
            rest = text[len("# via"):].strip()
            if rest:
                via[name].append(rest)
            reading = True
        elif reading and text.startswith("#"):
            via[name].append(text[1:].strip())
    return {k: [v.replace("-r ", "") for v in vs] for k, vs in via.items()}


def resolve(licence: str, package: str) -> str | None:
    """Rewrite a declared licence string to an SPDX identifier."""
    if licence in ACCEPTED:
        return licence
    if licence in SPDX:
        return SPDX[licence]
    die(f"{package}: pip-licenses reports {licence!r}, "
        f"which is neither in ACCEPTED nor in SPDX")
    return None


def collect(root: pathlib.Path, tmp: pathlib.Path) -> list[tuple[str, str, str, str]]:
    """Gate, then report. Returns (package, version, licence, required by)."""
    target, tools = environments(root, tmp)

    done = pip_licenses(tools, target, "--from", "meta",
                        "--fail-on", FAIL_ON, "--partial-match")
    if done.returncode != 0:
        print(done.stdout.strip() or done.stderr.strip(), file=sys.stderr)
        die("pip-licenses fail-on gate rejected the dependency set")

    done = pip_licenses(tools, target, "--from", "meta", "--format", "json")
    if done.returncode != 0:
        die(f"pip-licenses report failed:\n{done.stderr.strip()}")
    report = json.loads(done.stdout)
    if not report:
        die("pip-licenses reported no distributions")

    # A distribution declaring neither a License-Expression nor a License field
    # reads UNKNOWN here; --from mixed falls back to its classifiers.
    unknown = [e["Name"] for e in report if e["License"] == "UNKNOWN"]
    if unknown:
        done = pip_licenses(tools, target, "--from", "mixed", "--format", "json")
        if done.returncode != 0:
            die(f"pip-licenses classifier report failed:\n{done.stderr.strip()}")
        fallback = {e["Name"]: e["License"] for e in json.loads(done.stdout)}
        for entry in report:
            if entry["License"] == "UNKNOWN":
                entry["License"] = fallback.get(entry["Name"], "UNKNOWN")
        print(f"read from classifiers: {', '.join(sorted(unknown))}", file=sys.stderr)

    pinned, via = pins(root), graph(root)

    # requirements.txt names packages the way uv normalises them; the table
    # keeps each distribution's own spelling, so the via graph is rewritten to
    # match it rather than carrying two spellings of the same package.
    spelling = {canon(e["Name"]): e["Name"] for e in report}

    rows = []
    for entry in sorted(report, key=lambda e: canon(e["Name"])):
        key = canon(entry["Name"])
        if key not in pinned:
            die(f"{entry['Name']}: installed but not pinned in {REQUIREMENTS}")
        if pinned[key] != entry["Version"]:
            die(f"{entry['Name']}: {REQUIREMENTS} pins {pinned[key]}, "
                f"the environment holds {entry['Version']}")
        if key not in LICENSE_URLS:
            die(f"{entry['Name']}: no entry in LICENSE_URLS")
        needs = [spelling.get(canon(v), v) for v in via.get(key, [])]
        rows.append((entry["Name"], entry["Version"],
                     resolve(entry["License"], entry["Name"]),
                     ", ".join(needs or ["—"])))

    missing = sorted(set(pinned) - {canon(r[0]) for r in rows})
    if missing:
        die(f"pinned but not installed: {', '.join(missing)}")
    stale = sorted(set(LICENSE_URLS) - set(pinned))
    if stale:
        die(f"LICENSE_URLS has entries for packages no longer pinned: "
            f"{', '.join(stale)}")
    return rows


def section(title: str) -> list[str]:
    return [RULE, title, RULE, ""]


def plural(n: int, word: str) -> str:
    return f"{n} {word}" + ("" if n == 1 else "s")


def table(rows: list[tuple[str, str, str, str]]) -> list[str]:
    head = ("Package", "Version", "License", "Required By")
    w = [max(len(r[i]) for r in [head, *rows]) for i in range(3)]
    return [f"| {head[0]:<{w[0]}} | {head[1]:<{w[1]}} | {head[2]:<{w[2]}} | {head[3]}",
            "|" + "|".join("-" * (x + 2) for x in w) + "|" + "-" * 14,
            *(f"| {a:<{w[0]}} | {b:<{w[1]}} | {c:<{w[2]}} | {d}" for a, b, c, d in rows)]


def urls(rows: list[tuple[str, str, str, str]]) -> list[str]:
    width = max(len(r[0]) for r in rows) + 1
    return [f"{name + ':':<{width}} {LICENSE_URLS[canon(name)]}" for name, *_ in rows]


def build(root: pathlib.Path) -> str:
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="pip-licenses-"))
    try:
        rows = collect(root, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return "\n".join([
        HEADER,
        *section(f"DEPENDENCIES — {plural(len(rows), 'package')}"), *table(rows), "",
        *section("LICENSE URLS"), *urls(rows), "",
        *section("BUNDLED NATIVE CODE"), BUNDLED,
        *section("SYSTEM LIBRARIES AND BASE IMAGE"), SYSTEM,
        *section("LICENSE COMPATIBILITY"), COMPATIBILITY.rstrip("\n"),
    ]) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", type=pathlib.Path,
                    default=pathlib.Path(__file__).resolve().parent,
                    help="repository root (default: this script's directory)")
    ap.add_argument("--check", action="store_true",
                    help=f"write nothing; exit 1 if {TARGET} is stale")
    args = ap.parse_args()

    root = args.root.resolve()
    doc = build(root)
    target = root / TARGET

    if args.check:
        current = target.read_text(encoding="utf-8") if target.is_file() else ""
        if current != doc:
            print(f"{TARGET} is stale", file=sys.stderr)
            return 1
        print(f"{TARGET} is current", file=sys.stderr)
        return 0

    target.write_text(doc, encoding="utf-8")
    print(f"{TARGET}: {len(doc.splitlines())} lines, {len(doc.encode())} bytes",
          file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
