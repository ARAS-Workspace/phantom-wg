"""The Cloudflare mode of a production host, on the real stack, from the outside.

DESTRUCTIVE like test_user_flows: the tree is wiped at the start and at the end,
.env.cf included. The first tests need no Cloudflare account: they stop the
mode before it takes a certificate, one of them on a token Cloudflare refuses.
The whole cycle runs when the run is given a token and its zone, which has
SSL/TLS Full (strict) and Authenticated Origin Pulls on. Each certificate it
takes is revoked again: by the tool, or at the end of the module when a test
fails before the tool does:

    read -rs PHANTOM_TEST_CF_TOKEN; export PHANTOM_TEST_CF_TOKEN
    PHANTOM_TEST_CF_ZONE=example.com pytest tests/integration_tests/prod/test_cloudflare.py -x -s

While the mode is on, port 443 drops this host, so the tests read the mode
from the containers; a request through Cloudflare belongs to the Cloudflare
workflow.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.request

import pytest
from prod_host import (
    CLOUDFLARE,
    CLOUDFLARE_SETTINGS,
    LONG,
    OVERRIDE_BACKUP,
    ROOT,
    api_answers,
    call,
    logged_in,
    prod,
)

OVERRIDE = ROOT / "docker-compose.override.yml"
EXAMPLE = ROOT / ".env.cf.example"
STATE = CLOUDFLARE / "state.json"
NGINX = "phantom-nginx"
TABLE = "phantom_cloudflare"
SNIPPETS = ("http/cloudflare.conf", "server/cloudflare.conf", "cf_origin_pull_ca.pem", "firewall.nft")
NOTE = "# a note of the operator\n"
REFUSED_TOKEN = "phantom-test-refused-token"
TOKEN = os.environ.get("PHANTOM_TEST_CF_TOKEN", "")
ZONE = os.environ.get("PHANTOM_TEST_CF_ZONE", "")
ORIGINAL = {}
TAKEN = []

with_cloudflare = pytest.mark.skipif(
    not (TOKEN and ZONE), reason="PHANTOM_TEST_CF_TOKEN and PHANTOM_TEST_CF_ZONE are not set",
)


def docker(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["docker", *args], capture_output=True, encoding="utf-8", timeout=60, check=False)


def merged() -> dict:
    """The stack as Compose reads it, the override included."""
    done = subprocess.run(
        ["docker", "compose", "config", "--format", "json"], cwd=ROOT, capture_output=True, encoding="utf-8",
        timeout=60, check=True,
    )
    return json.loads(done.stdout)


def table(seconds: int = 20) -> subprocess.CompletedProcess:
    """The rules of the mode in nginx, once its start loaded them."""
    done = docker("exec", NGINX, "nft", "list", "table", "inet", TABLE)
    for _ in range(seconds):
        if done.returncode == 0:
            break
        time.sleep(1)
        done = docker("exec", NGINX, "nft", "list", "table", "inet", TABLE)
    return done


def settings(token: str, zone: str, hostnames: str = "") -> None:
    CLOUDFLARE_SETTINGS.write_text(f"CF_API_TOKEN={token}\nCF_ZONE={zone}\nCF_HOSTNAMES={hostnames}\n", encoding="utf-8")


def unchanged() -> None:
    """A refused on leaves no trace: the override as setup wrote it, no .bak, no mode directory."""
    assert OVERRIDE.read_bytes() == ORIGINAL["override"]
    assert not OVERRIDE_BACKUP.exists()
    assert not CLOUDFLARE.exists()


def revoked(identifier: str) -> bool:
    """What Cloudflare answers for the certificate, read with the token of the run."""
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/certificates/{identifier}", headers={"Authorization": f"Bearer {TOKEN}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return bool(json.loads(response.read())["result"].get("revoked_at"))
    except urllib.error.HTTPError as error:
        return error.code == 404


def revoke_in_cloudflare(identifier: str) -> None:
    """What a keep-certificate run leaves to the operator, done by the test with the token of the run."""
    request = urllib.request.Request(
        f"https://api.cloudflare.com/client/v4/certificates/{identifier}", method="DELETE",
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        assert json.loads(response.read())["success"]


def certificate_id() -> str:
    return json.loads(STATE.read_text(encoding="utf-8"))["certificate_id"]


def cloudflare(*args: str, timeout: int = 120) -> subprocess.CompletedProcess:
    """prod.sh cloudflare; the certificates it takes go to TAKEN, as it prints them."""
    done = prod("cloudflare", *args, timeout=timeout)
    TAKEN.extend(re.findall(r"Origin CA certificate (\S+):", done.stdout))
    return done


@pytest.fixture(scope="module", autouse=True)
def revoke_what_the_run_took():
    """A certificate of the run that is not revoked at the end, after a failed test, is revoked here."""
    yield
    for identifier in dict.fromkeys(TAKEN):
        if not revoked(identifier):
            revoke_in_cloudflare(identifier)
            print(f"teardown: Origin CA certificate {identifier} revoked", flush=True)


# ── Before Cloudflare ───────────────────────────────────────────────

def test_a_new_host_is_off():
    done = prod("setup", timeout=LONG)
    assert done.returncode == 0, done.stdout
    ORIGINAL["override"] = OVERRIDE.read_bytes()
    done = cloudflare()
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Cloudflare mode: off")


def test_on_writes_env_cf_from_its_example():
    done = cloudflare("on")
    assert done.returncode == 1
    assert ".env.cf is written from .env.cf.example. Fill CF_API_TOKEN and CF_ZONE in it, then run again." in done.stdout
    assert CLOUDFLARE_SETTINGS.read_bytes() == EXAMPLE.read_bytes()
    assert CLOUDFLARE_SETTINGS.stat().st_mode & 0o777 == 0o600
    unchanged()


def test_on_asks_for_the_token_and_the_zone():
    done = cloudflare("on")
    assert done.returncode == 1
    assert done.stdout.strip().endswith("Fill CF_API_TOKEN and CF_ZONE in .env.cf, then run again.")
    unchanged()


def test_on_holds_env_cf_at_600():
    settings(REFUSED_TOKEN, "localhost")
    CLOUDFLARE_SETTINGS.chmod(0o644)
    done = cloudflare("on")
    assert done.returncode == 1
    assert done.stdout.strip().endswith("CF_ZONE of .env.cf is not a domain name: localhost")
    assert CLOUDFLARE_SETTINGS.stat().st_mode & 0o777 == 0o600
    unchanged()


def test_on_refuses_a_hostname_outside_the_zone():
    settings(REFUSED_TOKEN, "example.com", "example.com, www.example.org")
    done = cloudflare("on")
    assert done.returncode == 1
    assert "CF_HOSTNAMES of .env.cf holds names outside example.com:\n  www.example.org" in done.stdout
    unchanged()


def test_on_refuses_a_line_it_does_not_know():
    CLOUDFLARE_SETTINGS.write_text(f"CF_API_TOKEN={REFUSED_TOKEN}\nCF_ZONE=example.com\nCF_PROXY=on\n", encoding="utf-8")
    done = cloudflare("on")
    assert done.returncode == 1
    assert ".env.cf line 3: expected one of CF_API_TOKEN, CF_ZONE, CF_HOSTNAMES, as KEY=value." in done.stdout
    unchanged()


def test_on_refuses_an_override_that_holds_its_entries():
    settings(REFUSED_TOKEN, "example.com")
    OVERRIDE.write_bytes(ORIGINAL["override"] + b"secrets:\n  tls_cert:\n    file: ./elsewhere\n")
    try:
        done = cloudflare("on", timeout=LONG)
        assert done.returncode == 1
        assert "docker-compose.override.yml holds what the Cloudflare mode writes:\n  secrets.tls_cert" in done.stdout
        assert "Cloudflare refused" not in done.stdout
    finally:
        OVERRIDE.write_bytes(ORIGINAL["override"])
    unchanged()


def test_on_stops_on_a_token_cloudflare_refuses():
    settings(REFUSED_TOKEN, "example.com")
    done = cloudflare("on", timeout=LONG)
    assert done.returncode == 1
    assert "Cloudflare refused GET /zones?name=example.com" in done.stdout
    assert REFUSED_TOKEN not in done.stdout
    unchanged()


def test_refresh_and_off_need_the_mode():
    for args in (("refresh",), ("off",), ("off", "--keep-certificate")):
        done = cloudflare(*args)
        assert done.returncode == 1
        assert done.stdout.strip().endswith("Cloudflare mode is off.")


def test_keep_certificate_belongs_to_off():
    done = cloudflare("on", "--keep-certificate")
    assert done.returncode == 1
    assert done.stdout.strip().endswith("Usage: ./tools/prod.sh cloudflare [status|on|refresh|off [--keep-certificate]]")
    unchanged()


# ── Through Cloudflare ──────────────────────────────────────────────

@with_cloudflare
def test_on_turns_the_mode_on():
    settings(TOKEN, ZONE)
    done = cloudflare("on", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Cloudflare mode is on. Apply it: ./tools/prod.sh up")
    assert TOKEN not in done.stdout
    assert OVERRIDE_BACKUP.read_bytes() == ORIGINAL["override"]
    assert not revoked(certificate_id())

    config = merged()
    nginx = config["services"]["nginx"]
    assert "NET_ADMIN" in nginx["cap_add"]
    assert nginx["command"][-1].startswith("nft -f /etc/nginx/phantom.d/firewall.nft")
    assert config["secrets"]["tls_cert"]["file"] == str(CLOUDFLARE / "tls_cert")
    assert config["secrets"]["tls_key"]["file"] == str(CLOUDFLARE / "tls_key")
    assert [name for name in SNIPPETS if not (CLOUDFLARE / "phantom.d" / name).is_file()] == []
    assert (CLOUDFLARE / "tls_key").stat().st_mode & 0o777 == 0o600


@with_cloudflare
def test_on_twice_stops():
    done = cloudflare("on")
    assert done.returncode == 1
    assert "Cloudflare mode is on. Turn it off first: ./tools/prod.sh cloudflare off" in done.stdout


@with_cloudflare
def test_up_loads_the_rules_and_the_snippets():
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    rules = table()
    assert rules.returncode == 0, rules.stderr
    assert "set cloudflare_v4" in rules.stdout
    assert "set cloudflare_v6" in rules.stdout
    config = docker("exec", NGINX, "nginx", "-T")
    assert "ssl_verify_client on;" in config.stdout
    assert "real_ip_header CF-Connecting-IP;" in config.stdout


@with_cloudflare
def test_port_443_drops_this_host():
    assert call("/")[0] == 0
    chain = docker("exec", NGINX, "nft", "list", "chain", "inet", TABLE, "input")
    assert sum(int(packets) for packets in re.findall(r"counter packets (\d+)", chain.stdout)) > 0, chain.stdout


@with_cloudflare
def test_restart_loads_the_rules_again():
    done = prod("restart", "nginx", timeout=LONG)
    assert done.returncode == 0, done.stdout
    rules = table()
    assert rules.returncode == 0, rules.stderr


@with_cloudflare
def test_refresh_writes_the_lists_again():
    rules = CLOUDFLARE / "phantom.d/firewall.nft"
    rules.write_text("# stale\n", encoding="utf-8")
    done = cloudflare("refresh", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Apply the new lists: ./tools/prod.sh restart nginx")
    assert "set cloudflare_v4" in rules.read_text(encoding="utf-8")


@with_cloudflare
def test_status_reads_the_mode():
    done = cloudflare(timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "Cloudflare mode: on" in done.stdout
    assert f"Zone: {ZONE}" in done.stdout
    assert f"Origin CA certificate {certificate_id()}:" in done.stdout
    assert "Origin pull CA: notAfter=" in done.stdout
    assert "Override: as the mode wrote it" in done.stdout


@with_cloudflare
def test_off_stops_on_an_entry_changed_by_hand():
    written = OVERRIDE.read_text(encoding="utf-8")
    OVERRIDE.write_text(written.replace('"NET_ADMIN"', '"NET_RAW"'), encoding="utf-8")
    try:
        done = cloudflare("off", timeout=LONG)
        assert done.returncode == 1
        assert "services.nginx.cap_add" in done.stdout
        assert STATE.exists()
        assert not revoked(certificate_id())
    finally:
        OVERRIDE.write_text(written, encoding="utf-8")


@with_cloudflare
def test_off_revokes_and_puts_the_override_back():
    identifier = certificate_id()
    done = cloudflare("off", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert done.stdout.strip().endswith("Cloudflare mode is off. Apply it: ./tools/prod.sh up")
    assert revoked(identifier)
    assert OVERRIDE.read_bytes() == ORIGINAL["override"]
    assert not CLOUDFLARE.exists()
    assert CLOUDFLARE_SETTINGS.is_file()


@with_cloudflare
def test_up_serves_without_the_mode():
    done = prod("up", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert docker("inspect", NGINX, "--format", "{{.HostConfig.CapAdd}}").stdout.strip() == "[]"
    status, body = api_answers(logged_in())
    assert status == 200, body


@with_cloudflare
def test_off_keeps_what_the_operator_added_since():
    done = cloudflare("on", timeout=LONG)
    assert done.returncode == 0, done.stdout
    identifier = certificate_id()
    with OVERRIDE.open("a", encoding="utf-8") as override:
        override.write(NOTE)
    done = cloudflare("off", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert "the rest stays as changed" in done.stdout
    assert OVERRIDE.read_text(encoding="utf-8") == ORIGINAL["override"].decode("utf-8") + NOTE
    assert revoked(identifier)
    OVERRIDE.write_bytes(ORIGINAL["override"])


@with_cloudflare
def test_off_keep_certificate_takes_the_mode_back_without_the_token():
    done = cloudflare("on", timeout=LONG)
    assert done.returncode == 0, done.stdout
    identifier = certificate_id()

    settings(REFUSED_TOKEN, ZONE)
    done = cloudflare("off", timeout=LONG)
    assert done.returncode == 1
    assert "The certificate is not revoked and the mode stays on." in done.stdout
    assert "./tools/prod.sh cloudflare off --keep-certificate" in done.stdout
    assert STATE.exists()
    assert not revoked(identifier)

    done = cloudflare("off", "--keep-certificate", timeout=LONG)
    assert done.returncode == 0, done.stdout
    assert f"Origin CA certificate {identifier} stays in Cloudflare" in done.stdout
    assert OVERRIDE.read_bytes() == ORIGINAL["override"]
    assert not CLOUDFLARE.exists()
    assert not revoked(identifier)

    revoke_in_cloudflare(identifier)
    assert revoked(identifier)
    settings(TOKEN, ZONE)


@with_cloudflare
def test_on_revokes_its_certificate_when_compose_refuses():
    env = ROOT / ".env"
    kept = env.read_bytes()
    env.write_bytes(kept + b"PHANTOM_IMAGE_SOURCE=nowhere\n")
    try:
        done = cloudflare("on", timeout=LONG)
    finally:
        env.write_bytes(kept)
    assert done.returncode == 1
    assert "Compose refused the new override. docker-compose.override.yml is unchanged." in done.stdout
    identifier = re.search(r"Origin CA certificate (\S+): revoked", done.stdout)
    assert identifier, done.stdout
    assert revoked(identifier[1])
    assert OVERRIDE.read_bytes() == ORIGINAL["override"]
    assert not CLOUDFLARE.exists()
