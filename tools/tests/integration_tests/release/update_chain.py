"""The stages of the update chain: three releases reach a host through update.

.github/workflows/update-chain.yml runs one stage per step, so its log reads as
the story of a host. The release tree becomes a repository, each release enters
it the way bump.sh commits one, and a host clones it and follows it. The images
come from a local registry: each is a published image with a new digest.

Usage: update_chain.py registry | publish <n> | client | prove <n>
"""

from __future__ import annotations

import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

CHAIN = Path(os.environ["CHAIN"])
PACKAGE = Path(os.environ["PACKAGE"]).resolve()
ORIGIN = CHAIN / "origin.git"
PUBLISHER = CHAIN / "publisher"
HOST = CHAIN / "phantom-wg"
PUBLISHED = CHAIN / "published-pins.json"
CLIENT_FILE = CHAIN / "client.json"
UPDATE_LOG = CHAIN / "update.log"

REGISTRY = "127.0.0.1:5055"
REGISTRY_NAME = "phantom-chain-registry"
REGISTRY_IMAGE = "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"

# Each service with its image and its container.
SERVICES = {
    "daemon": ("phantom-daemon-base", "phantom-daemon"),
    "auth-service": ("phantom-auth-base", "phantom-auth"),
    "nginx": ("phantom-nginx-base", "phantom-nginx"),
}
BUILT_RELEASE = 3
LABEL = "phantom.chain.release"
CLIENT = "chain-client"
SUBNET = "10.9.0.0/24"
PINS = "tools/compose/registry.yml"
VERSION_FILE = "phantom_daemon/__init__.py"
UPDATE_COMMAND = "tools/stack/prod/flows/stack/update/command.py"
HOOK = "tools/stack/prod/flows/stack/update/helper/update_hook.sh"
HOOK_MARK = "container-data/.chain-hook"
TIMEOUT = 300


def run(*args: str, cwd: Path | None = None, stdin: str | None = None) -> str:
    done = subprocess.run(
        args, cwd=cwd, input=stdin, capture_output=True, encoding="utf-8", timeout=TIMEOUT, check=False,
    )
    if done.returncode != 0:
        sys.exit(f"{' '.join(args[:3])} exited {done.returncode}\n{done.stdout}{done.stderr}")
    return done.stdout.strip()


def git(*args: str, cwd: Path = PUBLISHER) -> str:
    return run("git", "-c", "user.name=phantom", "-c", "user.email=phantom@localhost", *args, cwd=cwd)


def proved(condition: bool, text: str) -> None:
    if not condition:
        sys.exit(f"FAIL {text}")
    print(f"ok   {text}", flush=True)


def edit(path: Path, change) -> None:
    path.write_text(change(path.read_text(encoding="utf-8")), encoding="utf-8")


# ── The local registry ──────────────────────────────────────────────


def registry() -> None:
    run("docker", "run", "-d", "--rm", "--name", REGISTRY_NAME, "-p", f"{REGISTRY}:5000", REGISTRY_IMAGE)
    for _ in range(30):
        try:
            with urllib.request.urlopen(f"http://{REGISTRY}/v2/", timeout=2) as answer:
                proved(answer.status == 200, f"the local registry answers on {REGISTRY}")
                return
        except OSError:
            time.sleep(1)
    sys.exit(f"FAIL the local registry does not answer on {REGISTRY}")


def derive_images(number: int) -> dict[str, str]:
    """A published image with one more label: the same content under a new digest."""
    published = json.loads(PUBLISHED.read_text(encoding="utf-8"))
    pins = {}
    for service, (image, _) in SERVICES.items():
        reference = f"{REGISTRY}/aras-workspace/{image}:9.0.{number}"
        run("docker", "build", "-q", "-t", reference, "-", stdin=f"FROM {published[service]}\nLABEL {LABEL}={number}\n")
        run("docker", "push", "-q", reference)
        digest = run("docker", "buildx", "imagetools", "inspect", reference, "--format", "{{.Manifest.Digest}}")
        run("docker", "image", "rm", reference)
        pins[service] = f"{reference}@{digest}"
        print(f"     {service}: {pins[service]}", flush=True)
    return pins


# ── Releases ────────────────────────────────────────────────────────


def read_pins(root: Path) -> dict[str, str]:
    text = (root / PINS).read_text(encoding="utf-8")
    return {service: re.search(rf"^  {service}:\n    image: (.+)$", text, re.MULTILINE)[1] for service in SERVICES}


def write_pins(pins: dict[str, str]) -> None:
    def change(text: str) -> str:
        for service, pin in pins.items():
            text = re.sub(rf"^(  {service}:\n    image: ).+$", rf"\g<1>{pin}", text, flags=re.MULTILINE)
        return text

    edit(PUBLISHER / PINS, change)


def code_version(root: Path) -> str:
    return re.search(r'^__version__ = "(.+)"$', (root / VERSION_FILE).read_text(encoding="utf-8"), re.MULTILINE)[1]


def bump() -> str:
    """What bump.sh does: the patch number goes up in the one file that holds it."""
    current = code_version(PUBLISHER)
    major, minor, patch = current.split(".")
    new = f"{major}.{minor}.{int(patch) + 1}"
    edit(PUBLISHER / VERSION_FILE, lambda text: text.replace(f'__version__ = "{current}"', f'__version__ = "{new}"'))
    return new


def start_the_repository() -> None:
    CHAIN.mkdir(parents=True, exist_ok=True)
    git("init", "-q", "--bare", "-b", "main", str(ORIGIN), cwd=CHAIN)
    shutil.copytree(PACKAGE, PUBLISHER, symlinks=True)
    git("init", "-q", "-b", "main")
    git("remote", "add", "origin", f"file://{ORIGIN}")
    PUBLISHED.write_text(json.dumps(read_pins(PUBLISHER)), encoding="utf-8")


def change_the_tree(number: int) -> None:
    """Each release changes what a real one changes: compose, the tool, the hook, a Dockerfile."""

    def compose_label(text: str) -> str:
        text = re.sub(rf'^    labels:\n      {LABEL}: "\d+"\n', "", text, flags=re.MULTILINE)
        return text.replace("  nginx:\n", f'  nginx:\n    labels:\n      {LABEL}: "{number}"\n', 1)

    edit(PUBLISHER / "docker-compose.yml", compose_label)
    if number > 1:
        edit(PUBLISHER / UPDATE_COMMAND, lambda text: re.sub(r"Update complete[^\"]*", f"Update complete by release {number}.", text))
        edit(PUBLISHER / HOOK, lambda text: f"{text}printf '%s\\n' {number} > {HOOK_MARK}\n")
    if number == BUILT_RELEASE:
        edit(PUBLISHER / "nginx.Dockerfile", lambda text: f"{text}LABEL {LABEL}={number}\n")


def publish(number: int) -> None:
    if number == 1:
        start_the_repository()
        version, subject = code_version(PUBLISHER), f"Release v{code_version(PUBLISHER)}"
    else:
        version = bump()
        subject = f"Bump v{version}"

    write_pins(derive_images(number))
    change_the_tree(number)
    git("add", "-A", "-f")
    git("commit", "-q", "-m", subject)
    git("push", "-q", "origin", "main")
    proved(True, f"release {number} is on the local origin: {subject}")


# ── The host ────────────────────────────────────────────────────────


def call(path: str, token: str = "", body: dict | None = None) -> tuple:
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(f"https://127.0.0.1{path}", data=data, headers=headers)
    try:
        with urllib.request.urlopen(request, context=context, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, {}
    except OSError:
        return 0, {}


def logged_in() -> str:
    password = (HOST / "container-data/secrets/production/.admin_password").read_text(encoding="utf-8").strip()
    for _ in range(60):
        status, body = call("/auth/login", body={"username": "admin", "password": password})
        if status == 200:
            return body["data"]["token"]
        time.sleep(1)
    sys.exit("FAIL the host does not log in")


def authorized(token: str, path: str, body: dict | None = None) -> dict:
    """An authorized request reaches the daemon: an anonymous one stops at the auth service."""
    status = 0
    for _ in range(60):
        status, answer = call(path, token, body)
        if status in (200, 201):
            return answer["data"]
        time.sleep(1)
    sys.exit(f"FAIL {path} answers {status}")


def client() -> None:
    record = authorized(logged_in(), "/api/core/clients/assign", {"name": CLIENT})
    CLIENT_FILE.write_text(json.dumps(record), encoding="utf-8")
    proved(record["name"] == CLIENT, f"client {CLIENT} has the address {record['ipv4_address']}")


def inspect(*args: str) -> str:
    return run("docker", "inspect", "--format", *args)


def prove_images(number: int) -> None:
    pins = read_pins(HOST)
    for service, (image, container) in SERVICES.items():
        expected = f"{image}:local" if number == BUILT_RELEASE else pins[service]
        running = inspect("{{.Config.Image}}", container)
        proved(running == expected, f"{container} runs {running}")
    if number == BUILT_RELEASE:
        label = inspect(f'{{{{index .Config.Labels "{LABEL}"}}}}', "phantom-nginx-base:local")
        proved(label == str(number), "the nginx image came from the Dockerfile of this release")
    else:
        label = inspect(f'{{{{index .Config.Labels "{LABEL}"}}}}', pins["nginx"])
        proved(label == str(number), "the nginx image is the one this release pinned")


def prove(number: int) -> None:
    version = code_version(HOST)
    token = logged_in()
    answered = authorized(token, "/api/core/hello")["version"]
    proved(answered == version == code_version(PUBLISHER), f"the daemon runs version {answered}")

    prove_images(number)
    network = authorized(token, "/api/core/network")
    proved(network["ipv4_subnet"] == SUBNET, f"the pool stayed on {SUBNET}, IPv6 on {network['ipv6_subnet']}")
    label = inspect(f'{{{{index .Config.Labels "{LABEL}"}}}}', "phantom-nginx")
    proved(label == str(number), "the compose file of this release is applied")

    if number > 1:
        proved(f"Update complete by release {number}." in UPDATE_LOG.read_text(encoding="utf-8"), "the new code finished the update")
        proved((HOST / HOOK_MARK).read_text(encoding="utf-8").strip() == str(number), "the hook of this release ran")
        before = json.loads(CLIENT_FILE.read_text(encoding="utf-8"))
        after = authorized(token, "/api/core/clients/get", {"name": CLIENT})
        proved(after == before, f"client {CLIENT} is unchanged")


def main() -> None:
    stage = sys.argv[1]
    if stage == "registry":
        registry()
    elif stage == "publish":
        publish(int(sys.argv[2]))
    elif stage == "client":
        client()
    elif stage == "prove":
        prove(int(sys.argv[2]))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
