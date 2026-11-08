import {expect, test} from "@playwright/test";
import {execSync} from "child_process";
import {unlinkSync, writeFileSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";

const ADMIN_USER = "admin";

// Run-scoped prefix prevents name collisions on retry
const RUN_ID = Date.now().toString(36).slice(-4);

// Number of wg-client replicas (set by runner.py via --wg-clients N)
const PEER_COUNT = parseInt(process.env.WG_CLIENT_COUNT ?? "1", 10);

// Container name: resolved from COMPOSE_PROJECT_NAME injected by runner.py
const project = process.env.COMPOSE_PROJECT_NAME ?? "spa";

// Peers table: default page size and the order the SPA sorts names in
const DEFAULT_PAGE_SIZE = 25;
const NAME_ORDER = new Intl.Collator("en", { numeric: true });

// ── Helpers ──────────────────────────────────────────────────────

function clientName(index: number): string {
  return `e2e-wg-${RUN_ID}-${index}`;
}

async function visibleRowNames(page: import("@playwright/test").Page): Promise<string[]> {
  return page
    .locator('[data-testid^="vpn-wg-row-"]')
    .evaluateAll((rows) =>
      rows.map((r) => (r.getAttribute("data-testid") ?? "").slice("vpn-wg-row-".length)),
    );
}

function containerName(index: number): string {
  return `${project}-wg-client-${index}`;
}

async function loginAndGoWireGuard(page: import("@playwright/test").Page, password: string) {
  await page.goto("/login");
  await page.getByTestId("login-username").fill(ADMIN_USER);
  await page.getByTestId("login-password").fill(password);
  await page.getByTestId("login-submit").click();
  await expect(page).toHaveURL("/");
  await page.goto("/vpn/wireguard");
  await expect(page.getByTestId("vpn-wg-table")).toBeVisible({ timeout: 10_000 });
}

function dockerExecOn(container: string, cmd: string): void {
  execSync(`docker exec ${container} ${cmd}`, { stdio: "pipe" });
}

function writeConfigToContainer(config: string, container: string): void {
  const tmpFile = join(tmpdir(), `wg0-${Date.now()}-${Math.random().toString(36).slice(2, 6)}.conf`);
  writeFileSync(tmpFile, config, "utf8");
  try {
    execSync(`docker cp ${tmpFile} ${container}:/etc/wireguard/wg0.conf`, { stdio: "pipe" });
  } finally {
    unlinkSync(tmpFile);
  }
}

async function apiCall<T>(
  page: import("@playwright/test").Page,
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

async function peerNames(page: import("@playwright/test").Page): Promise<string[]> {
  const res = await apiCall<{ ok: boolean; data: { peers: { name: string | null }[] } }>(
    page, "GET", "/api/core/wireguard",
  );
  expect(res.ok).toBe(true);
  return res.data.peers.map((p) => p.name ?? "");
}

// ── Suite ────────────────────────────────────────────────────────

test.describe.serial("WireGuard", () => {
  let adminPassword: string;

  // Track created client names for cleanup
  const createdClients: string[] = [];

  // Peers on the interface before the suite creates any
  let baselinePeers = 0;

  test.beforeAll(() => {
    adminPassword = process.env.ADMIN_PASSWORD ?? "";
  });

  test.afterAll(() => {
    // Ensure WireGuard is brought down on ALL containers even if tests fail
    for (let i = 1; i <= PEER_COUNT; i++) {
      try {
        dockerExecOn(containerName(i), "wg-quick down wg0");
      } catch {
        // Already down — ignore
      }
    }
  });

  // ── 1. Setup: Create N clients, distribute configs, connect ───
  test(`Setup: Create ${PEER_COUNT} clients and connect`, async ({ page }) => {
    // Extend timeout for multi-peer setup
    test.setTimeout(60_000 + PEER_COUNT * 5_000);

    await page.goto("/login");
    await page.getByTestId("login-username").fill(ADMIN_USER);
    await page.getByTestId("login-password").fill(adminPassword);
    await page.getByTestId("login-submit").click();
    await expect(page).toHaveURL("/");

    baselinePeers = (await peerNames(page)).length;

    // Create clients and connect each to its container
    for (let i = 1; i <= PEER_COUNT; i++) {
      const name = clientName(i);
      const container = containerName(i);

      // Assign client
      const assignRes = await apiCall<{ ok: boolean }>(
        page, "POST", "/api/core/clients/assign", { name },
      );
      expect(assignRes.ok).toBe(true);
      createdClients.push(name);

      // Get v4 WireGuard config (base64-encoded)
      const configRes = await apiCall<{ ok: boolean; data: string }>(
        page, "POST", "/api/core/clients/config", { name, version: "v4" },
      );
      expect(configRes.ok).toBe(true);
      const wgConfig = Buffer.from(configRes.data, "base64").toString("utf8");
      expect(wgConfig).toContain("[Interface]");

      // Write config and bring up WireGuard
      writeConfigToContainer(wgConfig, container);
      dockerExecOn(container, "wg-quick up wg0");
    }

    // Poll until ALL peers have completed handshake
    await expect
      .poll(
        async () => {
          let connected = 0;
          for (let i = 1; i <= PEER_COUNT; i++) {
            const res = await apiCall<{ ok: boolean; data: { latest_handshake: number } }>(
              page, "POST", "/api/core/wireguard/peer", { name: clientName(i) },
            );
            if (res.ok && res.data.latest_handshake > 0) connected++;
          }
          return connected;
        },
        { timeout: 30_000, intervals: [2_000] },
      )
      .toBe(PEER_COUNT);
  });

  // ── 2. Interface card ──────────────────────────────────────────
  test("Interface card shows server info", async ({ page }) => {
    await loginAndGoWireGuard(page, adminPassword);

    const card = page.getByTestId("vpn-wg-interface");
    await expect(card).toBeVisible();
    // Listen port should be visible
    await expect(card).toContainText("51820");
    // Public key field should have content
    const kvValue = card.locator(".wireguard__kv-value").first();
    const keyText = await kvValue.textContent();
    expect(keyText?.length).toBeGreaterThan(8);
  });

  // ── 3. All peers — Online status ──────────────────────────────
  test(`All ${PEER_COUNT} peers show Online`, async ({ page }) => {
    await loginAndGoWireGuard(page, adminPassword);

    // More peers than one page holds: show up to 100 on one page
    if (PEER_COUNT > DEFAULT_PAGE_SIZE) {
      await page
        .getByTestId("vpn-wg-pagination")
        .locator(".cds--pagination__left select")
        .selectOption("100");
    }

    for (let i = 1; i <= PEER_COUNT; i++) {
      const name = clientName(i);
      const row = page.getByTestId(`vpn-wg-row-${name}`);
      await expect(row).toBeVisible();
      // Online badge (Carbon Tag type="green")
      await expect(row.locator(".cds--tag--green")).toBeVisible();
    }
  });

  // ── 4. Peer detail modal (first peer) ─────────────────────────
  test("Peer detail modal shows full peer info", async ({ page }) => {
    await loginAndGoWireGuard(page, adminPassword);

    const name = clientName(1);
    await page.getByTestId(`vpn-wg-overflow-${name}`).click();
    await page.getByTestId(`vpn-wg-action-details-${name}`).click();

    const modal = page.getByTestId("vpn-wg-detail-modal");
    await expect(modal).toBeVisible();

    // Full public key should be visible (not truncated)
    const detailMono = modal.locator(".wireguard__detail-mono").first();
    const keyText = await detailMono.textContent();
    expect(keyText?.length).toBeGreaterThan(20);

    // Allowed IPs section should have content
    await expect(modal.locator(".wireguard__allowed-ips")).toBeVisible();

    // Close modal
    await modal.locator(".cds--modal-footer .cds--btn--primary").click();
    await expect(modal).not.toBeVisible();
  });

  // ── 5. Per-peer refresh (first peer) ──────────────────────────
  test("Per-peer refresh updates row", async ({ page }) => {
    await loginAndGoWireGuard(page, adminPassword);

    const name = clientName(1);
    await page.getByTestId(`vpn-wg-overflow-${name}`).click();
    await page.getByTestId(`vpn-wg-action-refresh-${name}`).click();

    // Row remains visible and Online after refresh
    await expect(page.getByTestId(`vpn-wg-row-${name}`)).toBeVisible();
    await expect(
      page.getByTestId(`vpn-wg-row-${name}`).locator(".cds--tag--green"),
    ).toBeVisible();
  });

  // ── 6. Cleanup: Disconnect all and revoke ─────────────────────
  test(`Cleanup: Disconnect ${PEER_COUNT} clients and revoke`, async ({ page }) => {
    test.setTimeout(30_000 + PEER_COUNT * 3_000);

    // Bring down WireGuard on all containers
    for (let i = 1; i <= PEER_COUNT; i++) {
      try {
        dockerExecOn(containerName(i), "wg-quick down wg0");
      } catch {
        // Already down — ignore
      }
    }

    // Login and revoke all clients via API
    await page.goto("/login");
    await page.getByTestId("login-username").fill(ADMIN_USER);
    await page.getByTestId("login-password").fill(adminPassword);
    await page.getByTestId("login-submit").click();
    await expect(page).toHaveURL("/");

    for (const name of createdClients) {
      const revokeRes = await apiCall<{ ok: boolean }>(
        page, "POST", "/api/core/clients/revoke", { name },
      );
      expect(revokeRes.ok).toBe(true);
    }

    // Only the peers from before the suite remain, on the API and in the table
    const remaining = await peerNames(page);
    expect(remaining.length).toBe(baselinePeers);
    await page.goto("/vpn/wireguard");
    await expect(page.getByTestId("vpn-wg-table")).toBeVisible({ timeout: 10_000 });
    await expect
      .poll(() => visibleRowNames(page))
      .toEqual([...remaining].sort(NAME_ORDER.compare).slice(0, DEFAULT_PAGE_SIZE));
  });
});