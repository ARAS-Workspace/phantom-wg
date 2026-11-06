#!/usr/bin/env python3
"""Write MANIFEST.json from what publish-images.yml read out of the images.

Usage: image_manifest.py <contents dir> <output file>

Environment: TAG, GITHUB_SHA, DAEMON_IMAGE, AUTH_IMAGE, NGINX_IMAGE, SOURCES_IMAGE.

Contents dir, per image and architecture:
    <image>.<arch>.digest   Image digest
    <image>.<arch>.dpkg     package, version, source, source version
    <image>.<arch>.python   name, version (images that hold Python packages)
    <image>.<arch>.bridges  name, version (images that hold the bridges)

Contents dir, for all images:
    uris.txt                source, version, apt-get source --print-uris line
    missing.txt             source, version apt could not find

Every source package an image names has to resolve, or nothing is written.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

IMAGES = {
    "phantom-daemon-base": "DAEMON_IMAGE",
    "phantom-auth-base": "AUTH_IMAGE",
    "phantom-nginx-base": "NGINX_IMAGE",
}
ARCHITECTURES = ("amd64", "arm64")
URI = re.compile(r"^'[^']+' (?P<name>\S+) (?P<size>\d+) SHA256:(?P<sha256>[0-9a-f]{64})$")


def rows(path: Path, width: int) -> list[list[str]]:
    """Tab separated rows of a file, an empty list when the file is absent."""
    if not path.exists():
        return []
    result = []
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) != width:
            raise SystemExit(f"{path.name}: expected {width} fields: {line}")
        result.append(fields)
    return result


def named(path: Path) -> list[dict[str, str]]:
    return [{"name": name, "version": version} for name, version in sorted(rows(path, 2))]


def read_architecture(contents: Path, image: str, arch: str) -> dict:
    stem = f"{image}.{arch}"
    packages = [
        {"name": name, "version": version, "source": source, "source_version": source_version}
        for name, version, source, source_version in sorted(rows(contents / f"{stem}.dpkg", 4))
    ]
    if not packages:
        raise SystemExit(f"{stem}: no packages")

    entry: dict = {
        "digest": (contents / f"{stem}.digest").read_text().strip(),
        "packages": packages,
    }
    for key in ("python", "bridges"):
        found = named(contents / f"{stem}.{key}")
        if found:
            entry[key] = found
    return entry


def read_sources(contents: Path) -> dict[tuple[str, str], list[dict]]:
    sources: dict[tuple[str, str], list[dict]] = {}
    for name, version, line in rows(contents / "uris.txt", 3):
        match = URI.match(line)
        if match is None:
            raise SystemExit(f"uris.txt: unreadable line: {line}")
        sources.setdefault((name, version), []).append({
            "name": match["name"],
            "size": int(match["size"]),
            "sha256": match["sha256"],
        })
    return sources


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("Usage: image_manifest.py <contents dir> <output file>", file=sys.stderr)
        return 2

    contents = Path(argv[1])
    output = Path(argv[2])

    missing = rows(contents / "missing.txt", 2)
    if missing:
        for name, version in sorted(missing):
            print(f"Source not found: {name} {version}", file=sys.stderr)
        return 1

    images = {
        image: {
            "reference": os.environ[variable],
            "architectures": {
                arch: read_architecture(contents, image, arch) for arch in ARCHITECTURES
            },
        }
        for image, variable in IMAGES.items()
    }

    named_sources = {
        (package["source"], package["source_version"])
        for image in images.values()
        for entry in image["architectures"].values()
        for package in entry["packages"]
    }
    sources = read_sources(contents)
    unresolved = sorted(named_sources - sources.keys())
    if unresolved:
        for name, version in unresolved:
            print(f"Source without files: {name} {version}", file=sys.stderr)
        return 1

    manifest = {
        "version": os.environ["TAG"],
        "commit": os.environ["GITHUB_SHA"],
        "sources_image": os.environ["SOURCES_IMAGE"],
        "images": images,
        "sources": [
            {"name": name, "version": version, "files": sorted(sources[name, version], key=lambda f: f["name"])}
            for name, version in sorted(named_sources)
        ],
    }

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"{output}: {len(manifest['sources'])} source packages")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
