"""
Auth service packager — build production-ready distribution.

Creates dist/phantom-auth/ with only the files needed for deployment:
  auth_service/    source code + schema
  tools/           setup.sh + bootstrap.py
  Dockerfile       production image (no COPY, no test deps)
  compose.yml      includable compose fragment (secrets parametric)
  requirements.*   locked dependencies

Usage:
  python scripts/packager.py              Build dist/phantom-auth/
  python scripts/packager.py --clean      Remove dist/ before building
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist" / "phantom-auth"

# Files and directories to include (relative to ROOT)
INCLUDE = [
    "auth_service/",
    "tools/setup.sh",
    "tools/bootstrap.py",
    "Dockerfile",
    "docker-compose.yml",
    "requirements.in",
    "requirements.txt",
    "LICENSE",
    "THIRD_PARTY_LICENSES",
]

# Patterns to exclude from included directories
EXCLUDE_PATTERNS = {
    "__pycache__",
    ".pyc",
    ".pyo",
}


def _should_exclude(path: Path) -> bool:
    for part in path.parts:
        if part in EXCLUDE_PATTERNS:
            return True
    if path.suffix in EXCLUDE_PATTERNS:
        return True
    return False


def _copy_entry(src: Path, dst: Path) -> int:
    """Copy a file or directory tree. Returns number of files copied."""
    count = 0
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        return 1

    for item in sorted(src.rglob("*")):
        if not item.is_file():
            continue
        rel = item.relative_to(src)
        if _should_exclude(rel):
            continue
        target = dst / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        count += 1
    return count


def build(clean: bool = False) -> Path:
    """Build the distribution directory."""
    if clean and DIST.exists():
        shutil.rmtree(DIST)

    DIST.mkdir(parents=True, exist_ok=True)

    total = 0
    for entry in INCLUDE:
        src = ROOT / entry
        if not src.exists():
            print(f"  SKIP  {entry} (not found)")
            continue

        # Determine destination name
        if entry == "docker-compose.yml":
            dst = DIST / "compose.yml"
        else:
            dst = DIST / entry

        count = _copy_entry(src, dst)
        label = f"{count} files" if count > 1 else "1 file"
        print(f"  COPY  {entry} ({label})")
        total += count

    # Ensure setup.sh is executable
    setup_sh = DIST / "tools" / "setup.sh"
    if setup_sh.exists():
        setup_sh.chmod(0o755)

    print(f"\n  Total: {total} files → {DIST.relative_to(ROOT)}/")
    return DIST


def main() -> None:
    parser = argparse.ArgumentParser(description="Package auth service for distribution")
    parser.add_argument("--clean", action="store_true", help="Remove dist/ before building")
    args = parser.parse_args()

    print("Packaging phantom-auth...\n")
    build(clean=args.clean)
    print("\nDone.")


if __name__ == "__main__":
    main()
