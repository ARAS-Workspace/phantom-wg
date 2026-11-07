#!/usr/bin/env bash
# Installs a release zip as a user does, on the archive source, without a
# registry. Stops on the first failure; no image may come from a registry.
# Usage: .github/scripts/distribution/verify-release-zip.sh <zip>
set -euo pipefail

ZIP="$(cd "$(dirname "${1:?zip}")" && pwd)/$(basename "$1")"
WORK="$(mktemp -d)"
START="$(date +%s)"

fail() {
    echo "::error::$*"
    exit 1
}

wait_api() {
    local code=000
    for _ in $(seq 1 60); do
        code="$(curl -sk -o /dev/null -m 3 -w '%{http_code}' https://127.0.0.1/api/core/hello || true)"
        [ "${code}" = 401 ] && return 0
        sleep 1
    done
    docker compose ps || true
    docker compose logs --tail 20 || true
    fail "the API answers ${code}"
}

for NAME in phantom-daemon-base phantom-auth-base phantom-nginx-base; do
    docker image rm "${NAME}:archive" > /dev/null 2>&1 || true
done

cd "${WORK}"
unzip -q "${ZIP}"
cd phantom-wg-modern

[ ! -e .git ] || fail "the zip holds a git tree"
grep -q '^PHANTOM_IMAGE_SOURCE=archive$' .env.example || fail "the zip does not select the archive source"

./tools/prod.sh setup
grep -q '^PHANTOM_IMAGE_SOURCE=archive$' .env || fail "setup left another source in .env"
sed 's/^WIREGUARD_ENDPOINT_V4=.*/WIREGUARD_ENDPOINT_V4=127.0.0.1/' .env.daemon > .env.daemon.tmp
mv .env.daemon.tmp .env.daemon
./tools/prod.sh up
wait_api
[ "$(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1/)" = 200 ] || fail "the dashboard does not answer"

# A package has no git remote: update stops and the stack runs on.
if UPDATE="$(./tools/prod.sh update 2>&1)"; then
    fail "update ran in a package"
fi
grep -q 'no git remote' <<< "${UPDATE}" || fail "update said: ${UPDATE}"
wait_api

PULLS="$(docker events --since "${START}" --until "$(date +%s)" --filter type=image --filter event=pull --format '{{.Action}}' | wc -l)"
[ "${PULLS}" -eq 0 ] || fail "${PULLS} images came from a registry"

echo "The zip installed without a registry."
