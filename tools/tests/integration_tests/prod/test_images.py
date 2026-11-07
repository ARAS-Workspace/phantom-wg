"""The three image sources of a production host, on the real stack, from the outside.

DESTRUCTIVE like test_user_flows.py. The pinned images come once from the registry,
the archive is made from them once, and one scenario builds for real.
"""

from __future__ import annotations

import contextlib
import hashlib
import platform
import shutil
import subprocess

import pytest
from prod_host import LONG, ROOT, api_answers, logged_in, lost, prod, set_the_endpoint

ENV = ROOT / ".env"
ENV_EXAMPLE = ROOT / ".env.example"
IMAGES = ROOT / "images"
DOCKERFILE = ROOT / "nginx.Dockerfile"
PINS = "tools/compose/registry.yml"
BASES = {"daemon": "phantom-daemon-base", "auth-service": "phantom-auth-base", "nginx": "phantom-nginx-base"}
UNKNOWN = "Unknown image source: regsitry"


def docker(*args: str) -> str:
    done = subprocess.run(["docker", *args], cwd=ROOT, capture_output=True, encoding="utf-8", timeout=LONG, check=True)
    return done.stdout.strip()


def image_id(reference: str) -> str:
    return docker("image", "inspect", "--format", "{{.Id}}", reference)


def source_of(done: subprocess.CompletedProcess) -> str:
    return next(line for line in done.stdout.splitlines() if line.startswith("Image source:")).split()[-1]


@contextlib.contextmanager
def rewritten(path, content: str):
    before = path.read_bytes()
    path.write_text(content, encoding="utf-8")
    try:
        yield
    finally:
        path.write_bytes(before)


@contextlib.contextmanager
def corrupted(path):
    size = path.stat().st_size
    with path.open("ab") as tar:
        tar.write(b"x")
    try:
        yield
    finally:
        with path.open("ab") as tar:
            tar.truncate(size)


@pytest.fixture(scope="module")
def archive():
    """images/ as a release zip carries it, made from the pinned images."""
    arch = "arm64" if platform.machine() in ("arm64", "aarch64") else "amd64"
    IMAGES.mkdir(exist_ok=True)
    sums = []
    for service, name in BASES.items():
        reference = docker("compose", "-f", PINS, "config", "--images", service)
        docker("pull", "-q", "--platform", f"linux/{arch}", reference)
        docker("tag", reference, f"{name}:archive")
        tar = IMAGES / f"{name}.tar"
        docker("save", "--platform", f"linux/{arch}", "-o", str(tar), f"{name}:archive")
        docker("image", "rm", f"{name}:archive")
        found = hashlib.sha256()
        with tar.open("rb") as content:
            for chunk in iter(lambda: content.read(1 << 20), b""):
                found.update(chunk)
        sums.append(f"{found.hexdigest()}  {tar.name}")
    (IMAGES / "SHA256SUMS").write_text("\n".join(sums) + "\n", encoding="utf-8")
    (IMAGES / "VERSION").write_text(f"{pinned_version()}\n", encoding="utf-8")
    yield IMAGES
    shutil.rmtree(IMAGES)
    for name in BASES.values():
        for tag in ("archive", "local"):
            subprocess.run(["docker", "image", "rm", f"{name}:{tag}"], capture_output=True, timeout=60, check=False)


def pinned_version() -> str:
    reference = docker("compose", "-f", PINS, "config", "--images", "daemon")
    return reference.split(":")[1].split("@")[0]


# ── Before setup ────────────────────────────────────────────────────


def test_images_shows_the_default_before_setup():
    done = prod("images")
    assert done.returncode == 0, done.stdout
    assert source_of(done) == "registry"
    for service in BASES:
        assert service in done.stdout


def test_use_needs_setup():
    done = prod("images", "use", "build")
    assert done.returncode == 1
    assert "Missing: .env" in done.stdout


@pytest.mark.parametrize(
    "args",
    [("images", "nope"), ("images", "use"), ("images", "use", "nope"), ("images", "sync", "build"), ("images", "status", "x")],
    ids=" ".join,
)
def test_bad_image_arguments_stop_with_the_usage(args):
    done = prod(*args)
    assert done.returncode == 1
    assert "Usage: ./tools/prod.sh images" in done.stdout


def test_setup_takes_the_registry_source():
    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    set_the_endpoint()


# ── How .env reads ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    "line",
    [
        'PHANTOM_IMAGE_SOURCE="build"',
        "PHANTOM_IMAGE_SOURCE='build'",
        "PHANTOM_IMAGE_SOURCE=build # with a note",
        "PHANTOM_IMAGE_SOURCE=build   ",
        "export PHANTOM_IMAGE_SOURCE=build",
    ],
)
def test_the_tool_reads_env_as_compose_does(line):
    with rewritten(ENV, f"{line}\n"):
        done = prod("images")
    assert done.returncode == 0, done.stdout
    assert source_of(done) == "build"


@pytest.mark.parametrize("args", [("images",), ("pull",), ("build",), ("images", "sync")], ids=" ".join)
def test_an_unknown_source_stops(args):
    with rewritten(ENV, "PHANTOM_IMAGE_SOURCE=regsitry\n"):
        done = prod(*args)
    assert done.returncode == 1
    assert UNKNOWN in done.stdout


def test_images_use_recovers_an_unknown_source():
    with rewritten(ENV, "PHANTOM_IMAGE_SOURCE=regsitry\n"):
        assert prod("images", "use", "registry").returncode == 0
        assert ENV.read_text(encoding="utf-8") == "PHANTOM_IMAGE_SOURCE=registry\n"


def test_env_without_the_line_does_not_fall_to_the_example():
    with rewritten(ENV, "PHANTOM_SUBNET_V4=172.28.0.0/24\n"), rewritten(ENV_EXAMPLE, "PHANTOM_IMAGE_SOURCE=build\n"):
        done = prod("images")
    assert source_of(done) == "registry"


def test_use_keeps_a_file_without_a_last_newline_whole():
    with rewritten(ENV, "PHANTOM_SUBNET_V4=172.28.0.0/24"):
        assert prod("images", "use", "build").returncode == 0
        assert ENV.read_text(encoding="utf-8") == "PHANTOM_SUBNET_V4=172.28.0.0/24\nPHANTOM_IMAGE_SOURCE=build\n"


def test_use_changes_only_its_line():
    before = ENV.read_text(encoding="utf-8")
    assert prod("images", "use", "build").returncode == 0
    after = ENV.read_text(encoding="utf-8")
    assert after == before.replace("PHANTOM_IMAGE_SOURCE=registry", "PHANTOM_IMAGE_SOURCE=build")
    assert prod("images", "use", "registry").returncode == 0
    assert ENV.read_text(encoding="utf-8") == before


# ── Registry ────────────────────────────────────────────────────────


def test_pull_brings_every_image():
    done = prod("pull", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Images pulled.")
    assert prod("images").stdout.count("present") == len(BASES)


def test_build_and_rebuild_leave_the_registry_source_alone():
    for command in ("build", "rebuild"):
        done = prod(command)
        assert done.returncode == 0, done.stdout
        assert "nothing to build" in done.stdout


# ── Archive ─────────────────────────────────────────────────────────


def test_use_refuses_an_archive_that_is_not_there():
    before = ENV.read_text(encoding="utf-8")
    done = prod("images", "use", "archive")
    assert done.returncode == 1
    assert "images/ holds no image archive." in done.stdout
    assert ENV.read_text(encoding="utf-8") == before


@pytest.mark.parametrize(
    ("damage", "message"),
    [
        (lambda: lost(IMAGES / "VERSION"), "holds no image archive"),
        (lambda: lost(IMAGES / "SHA256SUMS"), "holds no image archive"),
        (lambda: rewritten(IMAGES / "VERSION", "9.9.9\n"), "images/ holds 9.9.9, this package pins"),
        (lambda: rewritten(IMAGES / "SHA256SUMS", ""), "does not match SHA256SUMS"),
        (lambda: corrupted(IMAGES / "phantom-nginx-base.tar"), "does not match SHA256SUMS: phantom-nginx-base.tar"),
        (lambda: lost(IMAGES / "phantom-auth-base.tar"), "does not match SHA256SUMS: phantom-auth-base.tar"),
    ],
    ids=["no-version", "no-sums", "wrong-version", "empty-sums", "corrupt-tar", "lost-tar"],
)
def test_a_broken_archive_is_refused(archive, damage, message):
    before = ENV.read_text(encoding="utf-8")
    with damage():
        done = prod("images", "use", "archive", timeout=LONG)
    assert done.returncode == 1
    assert message in done.stdout
    assert ENV.read_text(encoding="utf-8") == before


def test_sync_loads_only_what_sha256sums_lists(archive):
    assert prod("images", "use", "archive", timeout=LONG).returncode == 0
    extra = IMAGES / "extra.tar"
    extra.write_text("not a tar", encoding="utf-8")
    try:
        done = prod("images", "sync", timeout=LONG)
    finally:
        extra.unlink()
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Images loaded.")


def test_images_shows_the_archive(archive):
    done = prod("images")
    assert source_of(done) == "archive"
    assert "images/ version:" in done.stdout
    assert done.stdout.count("present") == len(BASES)
    assert ":archive" in done.stdout


def test_the_stack_runs_on_the_archive(archive):
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert ":archive" in done.stdout
    assert api_answers(logged_in())[0] == 200
    assert prod("down").returncode == 0


def test_setup_replaces_a_stale_archive_tag(archive):
    right = image_id("phantom-daemon-base:archive")
    assert prod("hard-reset", stdin="yes\n", timeout=LONG).returncode == 0
    docker("tag", "phantom-nginx-base:archive", "phantom-daemon-base:archive")
    assert image_id("phantom-daemon-base:archive") != right

    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert image_id("phantom-daemon-base:archive") == right


def test_a_broken_archive_stops_setup_before_it_writes(archive):
    assert prod("hard-reset", stdin="yes\n", timeout=LONG).returncode == 0
    with corrupted(IMAGES / "phantom-daemon-base.tar"):
        done = prod("setup", timeout=LONG)
    assert done.returncode == 1
    assert "does not match SHA256SUMS" in done.stdout
    assert not (ROOT / "container-data/secrets/production/wg_private_key").exists()


def test_a_missing_image_names_the_way_back(archive):
    assert prod("setup", timeout=LONG).returncode == 0
    for name in BASES.values():
        docker("image", "rm", f"{name}:archive")
    for args in (("gen-keys", "-f"), ("hard-reset",)):
        done = prod(*args, stdin="yes\n")
        assert done.returncode == 1
        assert "images sync" in done.stdout
    assert (ROOT / "container-data/secrets/production/wg_private_key").is_file()
    assert prod("images", "sync", timeout=LONG).returncode == 0
    assert prod("gen-keys", "-f", timeout=LONG).returncode == 0


# ── Build ───────────────────────────────────────────────────────────


def test_pull_leaves_the_build_source_alone(archive):
    assert prod("images", "use", "build").returncode == 0
    done = prod("pull")
    assert done.returncode == 0, done.stdout
    assert "nothing to pull" in done.stdout


def test_the_stack_runs_on_images_built_here(archive):
    done = prod("images", "sync", timeout=LONG * 2)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Images built.")
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert ":local" in done.stdout
    assert api_answers(logged_in())[0] == 200


def test_a_failing_rebuild_leaves_the_stack_up(archive):
    token = logged_in()
    with rewritten(DOCKERFILE, "FROM scratch\nRUN no-such-command\n"):
        done = prod("rebuild", timeout=LONG)
    assert done.returncode != 0
    assert api_answers(token)[0] == 200


def test_rebuild_builds_from_scratch_and_stops_the_stack(archive):
    done = prod("rebuild", timeout=LONG * 2)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Rebuilt. Run 'up' to start.")
    assert prod("up", timeout=LONG).returncode == 0
    assert api_answers(logged_in())[0] == 200
    assert prod("down").returncode == 0


# ── Back to the registry ────────────────────────────────────────────


def test_the_stack_returns_to_the_registry(archive):
    assert prod("images", "use", "registry").returncode == 0
    assert prod("images", "sync", timeout=LONG).returncode == 0
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "ghcr.io/aras-workspace/phantom-daemon-base" in done.stdout
    assert api_answers(logged_in())[0] == 200
    assert prod("down").returncode == 0
