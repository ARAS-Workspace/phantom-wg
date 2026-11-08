import { expect, test } from "@playwright/test";
import { execSync } from "child_process";

const ADMIN_USER = "admin";

// Container name: resolved from COMPOSE_PROJECT_NAME injected by runner.py
const project = process.env.COMPOSE_PROJECT_NAME ?? "spa";

// The exit of the story, and the exit the parity cases are saved into.
// Fixed names: the setup removes what a failed attempt left behind.
const PREFIX = "spa-edit-";
const LIVE = `${PREFIX}live`;
const PARITY = `${PREFIX}parity`;

// The stale side of the story: a port the exit server does not listen on and
// a server key that is not the exit server's. The key keeps the tunnel down
// even when the server reaches the daemon itself: after a session it knows the
// daemon's address (WireGuard roaming), and a retry of this group follows one.
const BROKEN_PORT = 1;
const STALE_KEY = Buffer.alloc(32, 7).toString("base64");
const OFFLINE_WAIT_MS = 6_000;
const HANDSHAKE_TIMEOUT_MS = 20_000;

// The keys the daemon reads; the stored config is rendered with these only
const STORED_KEYS = [
  "[Interface] PrivateKey",
  "[Interface] Address",
  "[Peer] PublicKey",
  "[Peer] PresharedKey",
  "[Peer] Endpoint",
  "[Peer] AllowedIPs",
  "[Peer] PersistentKeepalive",
];

type Page = import("@playwright/test").Page;
type Exit = { id: string; name: string; endpoint: string; public_key_hex: string };
type PeerStatus = { latest_handshake: number; rx_bytes: number } | null;

// ── Helpers ──────────────────────────────────────────────────────

function dockerExecRc(container: string, cmd: string): { rc: number; stdout: string } {
  try {
    const stdout = execSync(`docker exec ${container} ${cmd}`, { stdio: "pipe", encoding: "utf8" });
    return { rc: 0, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { status?: number; stdout?: string };
    return { rc: e.status ?? 1, stdout: (e.stdout ?? "").trim() };
  }
}

function info(label: string, value: string) {
  console.log(`  [INFO] ${label}: ${value}`);
}

async function goMultihop(page: Page, password: string) {
  await page.goto("/login");
  await page.getByTestId("login-username").fill(ADMIN_USER);
  await page.getByTestId("login-password").fill(password);
  await page.getByTestId("login-submit").click();
  await expect(page).toHaveURL("/");
  await page.goto("/vpn/multihop");
  await expect(page.getByTestId("vpn-mh-status-tile")).toBeVisible({ timeout: 10_000 });
}

async function apiCall<T>(
  page: Page,
  method: string,
  path: string,
  body?: Record<string, unknown>,
): Promise<T> {
  return await page.evaluate(
    async ({ method, path, body }) => {
      const token = localStorage.getItem("token") ?? "";
      const r = await fetch(path, {
        method,
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        ...(body ? { body: JSON.stringify(body) } : {}),
      });
      return r.json();
    },
    { method, path, body },
  );
}

async function exits(page: Page): Promise<Exit[]> {
  const res = await apiCall<{ ok: boolean; data: { exits: Exit[] } }>(page, "GET", "/api/multihop/list");
  expect(res.ok).toBe(true);
  return res.data.exits;
}

async function peerStatus(page: Page): Promise<PeerStatus> {
  const res = await apiCall<{ data: { peer: PeerStatus } }>(page, "GET", "/api/multihop/status");
  return res.data.peer;
}

// Enable and disable go through the API: the Carbon Toggle's testid lands on
// its wrapper and a click there does not reliably reach onToggle.
async function setEnabled(page: Page, name: string | null) {
  const res = name
    ? await apiCall<{ ok: boolean }>(page, "POST", "/api/multihop/enable", { name })
    : await apiCall<{ ok: boolean }>(page, "POST", "/api/multihop/disable");
  expect(res.ok).toBe(true);
  await page.reload();
  await expect(page.getByTestId("vpn-mh-status-tile")).toBeVisible({ timeout: 10_000 });
}

async function removeLeftovers(page: Page) {
  const status = await apiCall<{ data: { enabled: boolean; active: string } }>(
    page, "GET", "/api/multihop/status",
  );
  if (status.data.enabled && status.data.active.startsWith(PREFIX)) {
    await apiCall(page, "POST", "/api/multihop/disable");
  }
  for (const e of await exits(page)) {
    if (e.name.startsWith(PREFIX)) await apiCall(page, "POST", "/api/multihop/remove", { name: e.name });
  }
}

// "[Section] Key" → value, as written in the text
function fields(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  let section = "";
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      section = line;
      continue;
    }
    const equals = line.indexOf("=");
    if (equals < 0) continue;
    out[`${section} ${line.slice(0, equals).trim()}`] = line.slice(equals + 1).trim();
  }
  return out;
}

function stored(text: string): Record<string, string> {
  const all = fields(text);
  return Object.fromEntries(STORED_KEYS.filter((k) => k in all).map((k) => [k, all[k]]));
}

function setLine(conf: string, key: string, value: string): string {
  return conf.replace(new RegExp(`^${key} = .*$`, "m"), `${key} = ${value}`);
}

async function openEdit(page: Page, name: string) {
  await page.getByTestId(`vpn-mh-overflow-${name}`).click();
  await page.getByTestId(`vpn-mh-action-edit-${name}`).click();
  const modal = page.getByTestId("vpn-mh-edit-modal");
  await expect(modal).toBeVisible();
  // The stored config has arrived when the text area shows
  await expect(page.getByTestId("vpn-mh-edit-config")).toBeVisible({ timeout: 10_000 });
  return modal;
}

// ── Parity cases ─────────────────────────────────────────────────
// Each case is a text and the verdict both sides must give. A refused case
// names a label its error list must show. Line labels are matched without
// the word, which is translated.

type Label = string | RegExp | ((text: string) => RegExp);
type Case = { name: string; text: (base: string) => string; valid: boolean; label?: Label };

const lines = (base: string) => base.trimEnd().split("\n");
const insertAfter = (base: string, key: string, extra: string) =>
  lines(base).flatMap((l) => (l.startsWith(`${key} =`) ? [l, extra] : [l])).join("\n");
const peerSection = (base: string) => base.slice(base.indexOf("[Peer]"));
const interfaceSection = (base: string) => base.slice(0, base.indexOf("[Peer]"));
const lineOf = (text: string, needle: string) =>
  new RegExp(` ${lines(text).findIndex((l) => l.startsWith(needle)) + 1}: `);

const CASES: Case[] = [
  { name: "the exit server's config", text: (b) => b, valid: true },
  { name: "unused keys", text: (b) => insertAfter(b, "Address", "DNS = 1.1.1.1\nMTU = 1380"), valid: true },
  { name: "two Address lines", text: (b) => insertAfter(b, "Address", "Address = fd10:0:2::2/64"), valid: true },
  { name: "two AllowedIPs lines", text: (b) => insertAfter(b, "AllowedIPs", "AllowedIPs = 10.0.1.0/24"), valid: true },
  { name: "keepalive 0", text: (b) => setLine(b, "PersistentKeepalive", "0"), valid: true },
  { name: "keepalive with an underscore", text: (b) => setLine(b, "PersistentKeepalive", "2_5"), valid: true },
  { name: "hostname endpoint", text: (b) => setLine(b, "Endpoint", "exit.example.com:51820"), valid: true },
  { name: "bracketed IPv6 endpoint", text: (b) => setLine(b, "Endpoint", "[fd00::50]:51820"), valid: true },
  { name: "netmask address", text: (b) => setLine(b, "Address", "10.0.2.2/255.255.255.0"), valid: true },
  { name: "hostmask allowed IPs", text: (b) => setLine(b, "AllowedIPs", "10.0.2.0/0.0.0.255"), valid: true },
  { name: "section names in another case", text: (b) => b.replace("[Peer]", "[ peer ]"), valid: true },
  { name: "no preshared key", text: (b) => lines(b).filter((l) => !l.startsWith("PresharedKey")).join("\n"), valid: true },

  { name: "a second [Peer]", text: (b) => `${b.trimEnd()}\n\n${peerSection(b)}`, valid: false, label: "[Peer]:" },
  { name: "a second [Interface]", text: (b) => `${interfaceSection(b)}${b}`, valid: false, label: "[Interface]:" },
  { name: "a second peer as [ Peer ]", text: (b) => `${b.trimEnd()}\n\n${peerSection(b).replace("[Peer]", "[ Peer ]")}`, valid: false, label: "[Peer]:" },
  { name: "an unknown section", text: (b) => `${b.trimEnd()}\n\n[Peers]\nEndpoint = 1.2.3.4:5`, valid: false, label: "[Peers]" },
  { name: "a key before any section", text: (b) => `DNS = 1.1.1.1\n${b}`, valid: false, label: / 1: / },
  {
    name: "a line without =",
    text: (b) => insertAfter(b, "PublicKey", "PresharedKey Zm9v"),
    valid: false,
    label: (t) => lineOf(t, "PresharedKey Zm9v"),
  },
  {
    name: "a key followed by its padding",
    text: (b) => b.replace(/^PresharedKey = /m, "PresharedKey "),
    valid: false,
    label: (t) => lineOf(t, "PresharedKey "),
  },
  { name: "an unclosed header", text: (b) => b.replace("[Interface]", "[Interface"), valid: false, label: / 1: / },
  { name: "a repeated Endpoint", text: (b) => insertAfter(b, "Endpoint", "Endpoint = 1.2.3.4:5"), valid: false, label: "[Peer] Endpoint" },
  { name: "an unpadded private key", text: (b) => b.replace(/^(PrivateKey = .*)=$/m, "$1"), valid: false, label: "[Interface] PrivateKey" },
  { name: "a short public key", text: (b) => setLine(b, "PublicKey", "Zm9vYmFy"), valid: false, label: "[Peer] PublicKey" },
  { name: "an address out of range", text: (b) => setLine(b, "Address", "10.0.2.256/24"), valid: false, label: "[Interface] Address" },
  { name: "a bare IPv6 endpoint", text: (b) => setLine(b, "Endpoint", "fd00::50:51820"), valid: false, label: "[Peer] Endpoint" },
  { name: "a port out of range", text: (b) => setLine(b, "Endpoint", "172.31.0.50:65536"), valid: false, label: "[Peer] Endpoint" },
  { name: "a leading zero octet", text: (b) => setLine(b, "Endpoint", "172.031.0.50:51820"), valid: false, label: "[Peer] Endpoint" },
  { name: "an inline comment", text: (b) => setLine(b, "Endpoint", "172.31.0.50:51820 # exit"), valid: false, label: "[Peer] Endpoint" },
  { name: "keepalive out of range", text: (b) => setLine(b, "PersistentKeepalive", "65536"), valid: false, label: "[Peer] PersistentKeepalive" },
  { name: "keepalive in exponent form", text: (b) => setLine(b, "PersistentKeepalive", "1e3"), valid: false, label: "[Peer] PersistentKeepalive" },
  { name: "no Endpoint", text: (b) => lines(b).filter((l) => !l.startsWith("Endpoint")).join("\n"), valid: false, label: "[Peer] Endpoint" },
];

// ── Suite ────────────────────────────────────────────────────────

test.describe.serial("VPN Multihop — edit", () => {
  let adminPassword: string;
  let exitConf: string;
  let endpoint: string;
  let broken: string;

  test.beforeAll(() => {
    adminPassword = process.env.ADMIN_PASSWORD ?? "";
    const b64 = process.env.EXIT_CONF_B64 ?? "";
    exitConf = b64 ? Buffer.from(b64, "base64").toString("utf-8") : "";
    endpoint = fields(exitConf)["[Peer] Endpoint"] ?? "";
    const host = endpoint.slice(0, endpoint.lastIndexOf(":"));
    broken = setLine(setLine(exitConf, "Endpoint", `${host}:${BROKEN_PORT}`), "PublicKey", STALE_KEY);
  });

  test.beforeEach(() => {
    test.skip(!exitConf, "EXIT_CONF not provided");
  });

  test("Setup: the exit with a stale key and endpoint, imported from the modal", async ({ page }) => {
    await goMultihop(page, adminPassword);
    await removeLeftovers(page);
    await page.reload();

    await page.getByTestId("vpn-mh-import-btn").click();
    const modal = page.getByTestId("vpn-mh-import-modal");
    await expect(modal).toBeVisible();
    await page.getByTestId("vpn-mh-import-name").fill(LIVE);
    await page.getByTestId("vpn-mh-import-config").fill(broken);
    await modal.locator(".cds--modal-footer .cds--btn--primary").click();
    await expect(modal).not.toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId(`vpn-mh-row-${LIVE}`)).toBeVisible();

    const res = await apiCall<{ ok: boolean }>(page, "POST", "/api/multihop/import", {
      name: PARITY,
      config: exitConf.trim(),
    });
    expect(res.ok).toBe(true);
    info("exits", (await exits(page)).map((e) => e.name).join(", "));
  });

  test("Offline: no handshake, and Edit is closed while the exit is active", async ({ page }) => {
    await goMultihop(page, adminPassword);
    await setEnabled(page, LIVE);

    await page.waitForTimeout(OFFLINE_WAIT_MS);
    const peer = await peerStatus(page);
    expect(peer).not.toBeNull();
    expect([peer?.latest_handshake, peer?.rx_bytes]).toEqual([0, 0]);
    await expect(page.getByTestId("vpn-mh-status-tag").locator(".cds--tag--gray")).toBeVisible();

    await page.getByTestId(`vpn-mh-overflow-${LIVE}`).click();
    await expect(page.getByTestId(`vpn-mh-action-edit-${LIVE}`)).toBeDisabled();
    await page.keyboard.press("Escape");

    await setEnabled(page, null);
    info("stale key and endpoint", "no handshake, no bytes");
  });

  test("Edit: the stored config, the key and endpoint fixed, the same id and position", async ({ page }) => {
    await goMultihop(page, adminPassword);
    const before = await exits(page);

    const modal = await openEdit(page, LIVE);
    const shown = await page.getByTestId("vpn-mh-edit-config").inputValue();
    expect(stored(shown)).toEqual(stored(broken));

    await page.getByTestId("vpn-mh-edit-config").fill(exitConf);
    await modal.locator(".cds--modal-footer .cds--btn--primary").click();
    await expect(modal).not.toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-mh-notification-success")).toBeVisible();
    await expect(page.getByTestId(`vpn-mh-row-${LIVE}`)).toContainText(endpoint);

    const after = await exits(page);
    expect(after.map((e) => [e.id, e.name])).toEqual(before.map((e) => [e.id, e.name]));
    const live = after.find((e) => e.name === LIVE);
    expect(live?.endpoint).toBe(endpoint);
    const serverKey = Buffer.from(fields(exitConf)["[Peer] PublicKey"] ?? "", "base64").toString("hex");
    expect(live?.public_key_hex).toBe(serverKey);
  });

  test("Online: handshake after the edit, and the daemon reaches the exit server", async ({ page }) => {
    test.setTimeout(60_000);
    await goMultihop(page, adminPassword);
    await setEnabled(page, LIVE);

    await expect
      .poll(async () => {
        const peer = await peerStatus(page);
        return (peer?.latest_handshake ?? 0) > 0 && (peer?.rx_bytes ?? 0) > 0;
      }, { timeout: HANDSHAKE_TIMEOUT_MS })
      .toBe(true);
    await expect(page.getByTestId("vpn-mh-status-tag").locator(".cds--tag--green")).toBeVisible({
      timeout: 5_000,
    });

    const { rc } = dockerExecRc(`${project}-daemon-1`, "ping -c 3 -W 3 10.0.2.1");
    info("daemon → exit-server (10.0.2.1)", rc === 0 ? "OK" : "FAIL");
    expect(rc).toBe(0);

    await setEnabled(page, null);
  });

  test("Parity: the edit modal and the daemon decide alike", async ({ page }) => {
    test.setTimeout(240_000);
    await goMultihop(page, adminPassword);

    let sent = 0;
    page.on("request", (r) => {
      if (r.method() === "POST" && r.url().endsWith("/api/multihop/update")) sent++;
    });

    for (const c of CASES) {
      const text = c.text(exitConf);
      const modal = await openEdit(page, PARITY);
      const errors = modal.locator(".cds--inline-notification--error");
      const response = page
        .waitForResponse((r) => r.url().endsWith("/api/multihop/update"), { timeout: 10_000 })
        .catch(() => null);

      sent = 0;
      await page.getByTestId("vpn-mh-edit-config").fill(text);
      await modal.locator(".cds--modal-footer .cds--btn--primary").click();
      // The click shows the error list, or sends the update and the modal closes
      await expect.poll(async () => sent > 0 || (await errors.isVisible()), { timeout: 10_000 }).toBe(true);

      let spa: boolean;
      let daemon: boolean;
      if (sent === 0) {
        spa = false;
        const label = typeof c.label === "function" ? c.label(text) : c.label;
        if (label) await expect(errors).toContainText(label);
        await modal.locator(".cds--modal-footer .cds--btn--secondary").click();
        await expect(modal).not.toBeVisible();
        // The same text, straight to the daemon
        const res = await apiCall<{ ok: boolean; code?: string }>(page, "POST", "/api/multihop/update", {
          name: PARITY,
          config: text.trim(),
        });
        daemon = res.ok;
        if (!res.ok) expect(res.code).toBe("INVALID_EXIT_CONFIG");
      } else {
        spa = true;
        daemon = (await response)?.ok() ?? false;
        if (daemon) {
          await expect(modal).not.toBeVisible({ timeout: 10_000 });
        } else {
          await modal.locator(".cds--modal-footer .cds--btn--secondary").click();
          await expect(modal).not.toBeVisible();
        }
      }
      info(c.name, `spa ${spa ? "accepts" : "refuses"}, daemon ${daemon ? "accepts" : "refuses"}`);
      expect({ case: c.name, spa, daemon }).toEqual({ case: c.name, spa: c.valid, daemon: c.valid });
    }
  });

  test("Cleanup: remove the edit exits", async ({ page }) => {
    await goMultihop(page, adminPassword);
    await removeLeftovers(page);
    await page.reload();
    await expect(page.getByTestId(`vpn-mh-row-${LIVE}`)).not.toBeVisible({ timeout: 5_000 });
    expect((await exits(page)).filter((e) => e.name.startsWith(PREFIX))).toEqual([]);
  });
});
