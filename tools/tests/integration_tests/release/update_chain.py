"""The stages of the update chain: releases reach a host through update.

.github/workflows/update-chain.yml runs one stage per step, so its log reads as
the story of a host. The release tree becomes a repository, each release enters
it the way bump.sh commits one, and a host clones it and follows it. The images
come from a local registry: each is a published image with a new digest.

Usage: update_chain.py <stage> [arguments]
  registry
  publish <n> [--dockerfile | --failing-hook | --failing-code]
  client
  prove <n> [--built]
  local-change | detached | diverged | invalid-override
  missing <path>
  failing-hook | failing-code
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
LABEL = "phantom.chain.release"
CLIENT = "chain-client"
SUBNET = "10.9.0.0/24"
PINS = "tools/compose/registry.yml"
VERSION_FILE = "phantom_daemon/__init__.py"
UPDATE_COMMAND = "tools/stack/prod/flows/stack/update/command.py"
HOOK = "tools/stack/prod/flows/stack/update/helper/update_hook.sh"
HOOK_MARK = "container-data/.chain-hook"
OVERRIDE = "docker-compose.override.yml"
DAEMON_MAIN = "phantom_daemon/main.py"
FAILING_HOOK = "exit 3\n"
FAILING_CODE = "this line is not python\n"
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


def heal() -> None:
    """A release after a failing one takes the failure back."""
    edit(PUBLISHER / HOOK, lambda text: text.replace(FAILING_HOOK, ""))
    edit(PUBLISHER / DAEMON_MAIN, lambda text: text.replace(FAILING_CODE, ""))


def change_the_tree(number: int, option: str) -> None:
    """Each release changes what a real one changes: compose, the tool, the hook, a Dockerfile."""

    def compose_label(text: str) -> str:
        text = re.sub(rf'^    labels:\n      {LABEL}: "\d+"\n', "", text, flags=re.MULTILINE)
        return text.replace("  nginx:\n", f'  nginx:\n    labels:\n      {LABEL}: "{number}"\n', 1)

    edit(PUBLISHER / "docker-compose.yml", compose_label)
    if number > 1:
        edit(PUBLISHER / UPDATE_COMMAND, lambda text: re.sub(r"Update complete[^\"]*", f"Update complete by release {number}.", text))
        edit(PUBLISHER / HOOK, lambda text: f"{text}printf '%s\\n' {number} > {HOOK_MARK}\n")
    if option == "--dockerfile":
        edit(PUBLISHER / "nginx.Dockerfile", lambda text: f"{text}LABEL {LABEL}={number}\n")
    if option == "--failing-hook":
        edit(PUBLISHER / HOOK, lambda text: f"{text}{FAILING_HOOK}")
    if option == "--failing-code":
        edit(PUBLISHER / DAEMON_MAIN, lambda text: f"{text}{FAILING_CODE}")


def publish(number: int, option: str) -> None:
    if number == 1:
        start_the_repository()
        version, subject = code_version(PUBLISHER), f"Release v{code_version(PUBLISHER)}"
    else:
        heal()
        version = bump()
        subject = f"Bump v{version}"

    write_pins(derive_images(number))
    change_the_tree(number, option)
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


def prove_images(number: int, built: bool) -> None:
    pins = read_pins(HOST)
    for service, (image, container) in SERVICES.items():
        expected = f"{image}:local" if built else pins[service]
        running = inspect("{{.Config.Image}}", container)
        proved(running == expected, f"{container} runs {running}")
    if built:
        label = inspect(f'{{{{index .Config.Labels "{LABEL}"}}}}', "phantom-nginx-base:local")
        proved(label == str(number), "the nginx image came from the Dockerfile of this release")
    else:
        label = inspect(f'{{{{index .Config.Labels "{LABEL}"}}}}', pins["nginx"])
        proved(label == str(number), "the nginx image is the one this release pinned")


def prove(number: int, built: bool) -> None:
    version = code_version(HOST)
    token = logged_in()
    answered = authorized(token, "/api/core/hello")["version"]
    proved(answered == version == code_version(PUBLISHER), f"the daemon runs version {answered}")

    prove_images(number, built)
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


# ── What stops an update ────────────────────────────────────────────


def run_update() -> subprocess.CompletedProcess:
    done = subprocess.run(
        [str(HOST / "tools/prod.sh"), "update"], cwd=HOST, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, encoding="utf-8", timeout=TIMEOUT, check=False,
    )
    print(done.stdout, flush=True)
    return done


def containers() -> dict[str, str]:
    return {container: inspect("{{.Id}}", container) for _, container in SERVICES.values()}


def update_stops(code: int, message: str) -> None:
    """The operator reads why, and the stack runs on as it did."""
    before = containers()
    done = run_update()
    proved(done.returncode == code, f"update exited {code}")
    proved(message in done.stdout, f"update said: {message}")
    proved(containers() == before, "the containers are the ones from before")


def head() -> str:
    return git("rev-parse", "HEAD", cwd=HOST)


def local_change() -> None:
    before = head()
    edit(HOST / "docker-compose.yml", lambda text: f"{text}# a local change\n")
    update_stops(1, "have local changes")
    proved(head() == before, "the clone did not move")
    git("checkout", "--", "docker-compose.yml", cwd=HOST)


def detached() -> None:
    before = head()
    git("checkout", "-q", "--detach", cwd=HOST)
    update_stops(1, "update follows main")
    proved(head() == before, "the clone did not move")
    git("checkout", "-q", "main", cwd=HOST)


def diverged() -> None:
    git("commit", "-q", "--allow-empty", "-m", "A local commit", cwd=HOST)
    before = head()
    update_stops(1, "has left origin/main")
    proved(head() == before, "the clone did not move")
    git("fetch", "-q", "origin", "main", cwd=HOST)
    git("reset", "-q", "--hard", "FETCH_HEAD", cwd=HOST)
    proved(code_version(HOST) == code_version(PUBLISHER), "the two commands update printed bring the clone back")


def missing(relative: str) -> None:
    path = HOST / relative
    aside = path.with_name(f"{path.name}.aside")
    path.rename(aside)
    update_stops(1, f"Missing: {relative}")
    aside.rename(path)


def invalid_override() -> None:
    path = HOST / OVERRIDE
    before = path.read_text(encoding="utf-8")
    path.write_text("services:\n  not-a-service:\n    ports:\n      - 1:1\n", encoding="utf-8")
    update_stops(1, "not-a-service")
    path.write_text(before, encoding="utf-8")


def failing_hook() -> None:
    update_stops(3, "update_hook.sh exited 3")


def failing_code() -> None:
    """The new daemon does not start: only the wait after up can see it."""
    done = run_update()
    proved(done.returncode == 1, "update exited 1")
    proved("The services did not settle" in done.stdout, "update said the services did not settle")
    proved("Update complete" not in done.stdout, "update did not call it complete")


def main() -> None:
    stage, *args = sys.argv[1:]
    if stage == "registry":
        registry()
    elif stage == "publish":
        publish(int(args[0]), args[1] if len(args) > 1 else "")
    elif stage == "client":
        client()
    elif stage == "prove":
        prove(int(args[0]), "--built" in args)
    elif stage == "local-change":
        local_change()
    elif stage == "detached":
        detached()
    elif stage == "diverged":
        diverged()
    elif stage == "missing":
        missing(args[0])
    elif stage == "invalid-override":
        invalid_override()
    elif stage == "failing-hook":
        failing_hook()
    elif stage == "failing-code":
        failing_code()
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
