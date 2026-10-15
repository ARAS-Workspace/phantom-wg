#!/usr/bin/env python3
"""Writes THIRD_PARTY_LICENSES and the licenses/ tree from go-licenses.

Runs go-licenses once per target platform, in order: check, report, save.
Reports are held in memory and merged into one table; save trees are written
to temporary directories and merged into licenses/. Nothing here classifies a
licence or decides what has to be kept — go-licenses does that.

A library, or a file, that two platforms disagree about stops the run.

    python3 generate_licenses.py
    python3 generate_licenses.py --check
"""
from __future__ import annotations

import argparse
import csv
import filecmp
import io
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import textwrap

MODULE_DIR = "src"
PACKAGES = "./..."
IGNORE = "wireguard-go-bridge"
LICENSES_DIR = "licenses"
RULE = "=" * 80

# The platforms the release builds for; see the publish workflow.
PLATFORMS = (("linux", "amd64"), ("linux", "arm64"))

# Licence classes go-licenses must not find. "restricted" covers the copyleft
# classes; the default set is forbidden and unknown only.
DISALLOWED = "forbidden,restricted,unknown"

HEADER = textwrap.dedent("""\
    ██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
    ██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
    ██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
    ██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
    ██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

    THIRD PARTY LICENSES
    ================================================================================

    Phantom-WG / wireguard-go-bridge
    Copyright (c) 2025 ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret Limited Şirketi
    Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
    Licensed under AGPL-3.0 - see LICENSE file for details

    Maintained by: Rıza Emre ARAS <r.emrearas@proton.me>

    HOW TO READ THIS FILE

      DEPENDENCIES lists every Go library compiled into the built artifact,
      with the licence go-licenses identified and a link to that licence at
      the version in use. It is the union over every platform the release
      builds for, so a library that only one platform pulls in is listed.

      requirements.txt is not covered here. It pins pytest, pytest-cov and
      docker with their transitive dependencies; those run the test suite and
      are not part of anything this project ships. The Python package in
      wireguard_go_bridge/ imports only the standard library.

      wireguard-go, embedded through cgo, is
      Copyright (C) 2017-2025 WireGuard LLC. All Rights Reserved.
      WireGuard® is a registered trademark of Jason A. Donenfeld.
      https://www.wireguard.com/

      licenses/ in this repository holds what each licence requires to travel
      with the artifact: the licence text, the NOTICE file where one exists,
      and the source code where the licence calls for it. The tree under
      licenses mirrors that directory, notices included, and is the union
      over the same platforms.

      Both sections are generated. Regenerate with:

          python3 generate_licenses.py

      go-licenses determines the licence of each library and what must be
      kept; this file lays that out.
    """)


def die(msg: str) -> None:
    sys.exit(f"generate_licenses: {msg}")


# noinspection PyDeprecation
def go_licenses(root: pathlib.Path, goos: str, goarch: str,
                *args: str) -> subprocess.CompletedProcess:
    tool = shutil.which("go-licenses")
    if tool is None:
        die("go-licenses not on PATH — go install github.com/google/go-licenses@v1.6.0")
    return subprocess.run(
        [tool, *args, PACKAGES, "--ignore", IGNORE],
        cwd=root / MODULE_DIR, capture_output=True, text=True,
        env={**os.environ, "GOOS": goos, "GOARCH": goarch,
             # src/Makefile builds every target with cgo on; cross-compiling
             # would otherwise default it to 0 and load a different file set.
             "CGO_ENABLED": "1"})


def collect(root: pathlib.Path, staging: pathlib.Path) -> dict[str, tuple[str, str]]:
    """Run go-licenses for every platform; merge reports and save trees.

    Returns library -> (licence, url). Writes the merged tree into staging.
    """
    merged: dict[str, tuple[str, str]] = {}
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="go-licenses-"))
    try:
        for goos, goarch in PLATFORMS:
            tag = f"{goos}/{goarch}"

            done = go_licenses(root, goos, goarch, "check",
                               f"--disallowed_types={DISALLOWED}")
            if done.returncode != 0:
                for line in done.stderr.splitlines():
                    if "Not allowed" in line:
                        print(line, file=sys.stderr)
                die(f"go-licenses check failed for {tag}")

            done = go_licenses(root, goos, goarch, "report")
            if done.returncode != 0:
                die(f"go-licenses report failed for {tag}:\n{done.stderr.strip()}")
            rows = [r for r in csv.reader(io.StringIO(done.stdout)) if r]
            if not rows:
                die(f"go-licenses report produced nothing for {tag}")
            for name, url, licence in rows:
                if licence == "Unknown":
                    die(f"{tag}: licence not identified for {name}")
                merge_row(merged, name, licence, url, tag)

            out = tmp / f"{goos}-{goarch}"
            done = go_licenses(root, goos, goarch, "save", f"--save_path={out}")
            if done.returncode != 0:
                die(f"go-licenses save failed for {tag}:\n{done.stderr.strip()}")
            added = merge_tree(out, staging, tag)
            print(f"{tag}: {len(rows)} libraries, {added} new files", file=sys.stderr)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return merged


def merge_row(merged: dict[str, tuple[str, str]], name: str, licence: str,
              url: str, tag: str) -> None:
    """Add one report row. A licence two platforms disagree about stops the
    run. For the URL, go-licenses resolves vanity import paths over the
    network and can answer Unknown; a resolved URL therefore wins over one."""
    seen = merged.get(name)
    if seen is None:
        merged[name] = (licence, url)
        return
    if seen[0] != licence:
        die(f"{name}: {tag} reports {licence}, an earlier platform reported {seen[0]}")
    if seen[1] == url:
        return
    if seen[1] == "Unknown":
        merged[name] = (licence, url)
    elif url != "Unknown":
        die(f"{name}: {tag} reports {url}, an earlier platform reported {seen[1]}")


def merge_tree(source: pathlib.Path, staging: pathlib.Path, tag: str) -> int:
    """Copy source into staging. A path that already exists with different
    content stops the run; an identical one is skipped."""
    added = 0
    for src in sorted(p for p in source.rglob("*") if p.is_file()):
        rel = src.relative_to(source)
        dst = staging / rel
        if dst.exists():
            if not filecmp.cmp(src, dst, shallow=False):
                die(f"{rel}: {tag} wrote different content than an earlier platform")
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        added += 1
    return added


def section(title: str) -> list[str]:
    return [RULE, title, RULE, ""]


def table(merged: dict[str, tuple[str, str]]) -> list[str]:
    head = ("Library", "License", "License URL")
    rows = [(name, licence, url) for name, (licence, url) in sorted(merged.items())]
    w0 = max(len(r[0]) for r in [head, *rows])
    w1 = max(len(r[1]) for r in [head, *rows])
    return [f"| {head[0]:<{w0}} | {head[1]:<{w1}} | {head[2]}",
            f"|{'-' * (w0 + 2)}|{'-' * (w1 + 2)}|{'-' * 13}",
            *(f"| {n:<{w0}} | {lic:<{w1}} | {url}" for n, lic, url in rows)]


def tree(root: pathlib.Path) -> list[str]:
    """Deterministic tree listing, directories before files, name order."""
    lines: list[str] = []

    def walk(path: pathlib.Path, prefix: str) -> None:
        entries = sorted(path.iterdir(), key=lambda p: (p.is_file(), p.name))
        for i, entry in enumerate(entries):
            last = i == len(entries) - 1
            lines.append(f"{prefix}{'└── ' if last else '├── '}"
                         f"{entry.name}{'/' if entry.is_dir() else ''}")
            if entry.is_dir():
                walk(entry, prefix + ("    " if last else "│   "))

    walk(root, "")
    return lines


def same_tree(a: pathlib.Path, b: pathlib.Path) -> bool:
    if not b.is_dir():
        return False
    left = sorted(p.relative_to(a) for p in a.rglob("*") if p.is_file())
    right = sorted(p.relative_to(b) for p in b.rglob("*") if p.is_file())
    if left != right:
        return False
    return all(filecmp.cmp(a / rel, b / rel, shallow=False) for rel in left)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root", type=pathlib.Path,
                    default=pathlib.Path(__file__).resolve().parent,
                    help="repository root (default: this script's directory)")
    ap.add_argument("--check", action="store_true",
                    help="write nothing; exit 1 if the file or licenses/ is stale")
    args = ap.parse_args()

    root = args.root.resolve()
    target = root / LICENSES_DIR
    doc_path = root / "THIRD_PARTY_LICENSES"

    staging = pathlib.Path(tempfile.mkdtemp(prefix="licenses-staging-"))
    try:
        merged = collect(root, staging)
        doc = "\n".join([HEADER, *section("DEPENDENCIES"), *table(merged), "",
                         *section(LICENSES_DIR), *tree(staging)]) + "\n"

        if args.check:
            stale = []
            if not doc_path.is_file() or doc_path.read_text(encoding="utf-8") != doc:
                stale.append("THIRD_PARTY_LICENSES")
            if not same_tree(staging, target):
                stale.append(f"{LICENSES_DIR}/")
            if stale:
                print(f"stale: {', '.join(stale)}", file=sys.stderr)
                return 1
            print("THIRD_PARTY_LICENSES and licenses/ are current", file=sys.stderr)
            return 0

        if target.exists():
            shutil.rmtree(target)
        shutil.move(str(staging), str(target))
        staging = target  # moved; nothing left to clean up
        doc_path.write_text(doc, encoding="utf-8")
        print(f"{len(merged)} libraries, "
              f"{sum(1 for p in target.rglob('*') if p.is_file())} files in "
              f"{LICENSES_DIR}/, {len(doc.splitlines())} lines", file=sys.stderr)
        return 0
    finally:
        if staging.exists() and staging != target:
            shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
