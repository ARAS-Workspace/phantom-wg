import {expect, test} from "@playwright/test";
import {execSync} from "child_process";
import {unlinkSync, writeFileSync} from "fs";
import {tmpdir} from "os";
import {join} from "path";

const ADMIN_USER = "admin";

// Run-scoped prefix prevents name collisions on retry
const RUN_ID = Date.now().toString(36).slice(-4);

// Container name: resolved from COMPOSE_PROJECT_NAME injected by runner.py
const project = process.env.COMPOSE_PROJECT_NAME ?? "spa";

// Connected clients, one per wg-table container; client N sends N * PINGS_PER_STEP pings
const TABLE_CLIENTS = 3;
const PINGS_PER_STEP = 4;

// Never-connected clients, so the table spans more than one page
const IDLE_COUNT = 25;

// Peers table: default page size and the order the SPA sorts names in
const DEFAULT_PAGE_SIZE = 25;
const DASHBOARD_PAGE_SIZE = 10;
const NAME_ORDER = new Intl.Collator("en", { numeric: true });

type Peer = { name: string; latest_handshake: number; rx_bytes: number; tx_bytes: number };
type SortKey = "name" | "last_handshake" | "rx" | "tx";
type Direction = "ASC" | "DESC";

const NUMERIC_FIELD = {
  last_handshake: "latest_handshake",
  rx: "rx_bytes",
  tx: "tx_bytes",
} as const;

// ── Helpers ──────────────────────────────────────────────────────

function connectedName(index: number): string {
  return `e2e-wgt-${RUN_ID}-c${index}`;
}

function idleName(index: number): string {
  return `e2e-wgt-${RUN_ID}-i${index}`;
}

function tableContainer(index: number): string {
  return `${project}-wg-table-${index}-1`;
}

function dockerExecRc(container: string, cmd: string): { rc: number; stdout: string } {
  try {
    const stdout = execSync(`docker exec ${container} ${cmd}`, { stdio: "pipe", encoding: "utf8" });
    return { rc: 0, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { status?: number; stdout?: string };
    return { rc: e.status ?? 1, stdout: (e.stdout ?? "").trim() };
  }
}

function writeConfigToContainer(config: string, container: string): void {
  const tmpFile = join(tmpdir(), `wg0-wgt-${Date.now()}-${Math.random().toString(36).slice(2, 6)}.conf`);
  writeFileSync(tmpFile, config, "utf8");
  try {
    execSync(`docker cp ${tmpFile} ${container}:/etc/wireguard/wg0.conf`, { stdio: "pipe" });
  } finally {
    unlinkSync(tmpFile);
  }
}

async function login(page: import("@playwright/test").Page, password: string) {
  await page.goto("/login");
  await page.getByTestId("login-username").fill(ADMIN_USER);
  await page.getByTestId("login-password").fill(password);
  await page.getByTestId("login-submit").click();
  await expect(page).toHaveURL("/");
}

async function goTable(page: import("@playwright/test").Page, password: string) {
  await login(page, password);
  await page.goto("/vpn/wireguard");
  await expect(page.getByTestId("vpn-wg-table")).toBeVisible({ timeout: 10_000 });
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

async function peers(page: import("@playwright/test").Page): Promise<Peer[]> {
  const res = await apiCall<{
    ok: boolean;
    data: { peers: (Omit<Peer, "name"> & { name: string | null })[] };
  }>(page, "GET", "/api/core/wireguard");
  expect(res.ok).toBe(true);
  return res.data.peers.map((p) => ({ ...p, name: p.name ?? "" }));
}

// The order the table must show: by value, equal values by name ascending
function expectedOrder(list: Peer[], key: SortKey, direction: Direction): string[] {
  const sign = direction === "ASC" ? 1 : -1;
  const byName = (a: Peer, b: Peer) => NAME_ORDER.compare(a.name, b.name);
  const sorted = [...list].sort((a, b) => {
    if (key === "name") return sign * byName(a, b);
    const field = NUMERIC_FIELD[key];
    return sign * (a[field] - b[field]) || byName(a, b);
  });
  return sorted.map((p) => p.name);
}

async function visibleRowNames(
  page: import("@playwright/test").Page,
  prefix = "vpn-wg-row-",
): Promise<string[]> {
  return page
    .locator(`[data-testid^="${prefix}"]`)
    .evaluateAll(
      (rows, p) => rows.map((r) => (r.getAttribute("data-testid") ?? "").slice(p.length)),
      prefix,
    );
}

// ── Suite ────────────────────────────────────────────────────────

test.describe.serial("WireGuard peers table", () => {
  let adminPassword: string;

  // Track created client names for cleanup
  const createdClients: string[] = [];

  // Peers on the interface before the suite creates any
  let baselinePeers = 0;

  test.beforeAll(() => {
    adminPassword = process.env.ADMIN_PASSWORD ?? "";
  });

  test.afterAll(() => {
    // Bring WireGuard down on the table containers even if tests fail
    for (let i = 1; i <= TABLE_CLIENTS; i++) {
      dockerExecRc(tableContainer(i), "wg-quick down wg0");
    }
  });

  // ── 1. Setup: connected clients with their own traffic, idle clients ─
  test(`Setup: ${TABLE_CLIENTS} connected clients and ${IDLE_COUNT} idle clients`, async ({ page }) => {
    test.setTimeout(90_000);
    await login(page, adminPassword);
    baselinePeers = (await peers(page)).length;

    for (let i = 1; i <= TABLE_CLIENTS; i++) {
      const name = connectedName(i);
      const container = tableContainer(i);

      // A retry may find wg0 still up from the failed attempt
      dockerExecRc(container, "wg-quick down wg0");

      const assignRes = await apiCall<{ ok: boolean }>(
        page, "POST", "/api/core/clients/assign", { name },
      );
      expect(assignRes.ok).toBe(true);
      createdClients.push(name);

      const configRes = await apiCall<{ ok: boolean; data: string }>(
        page, "POST", "/api/core/clients/config", { name, version: "v4" },
      );
      expect(configRes.ok).toBe(true);
      writeConfigToContainer(Buffer.from(configRes.data, "base64").toString("utf8"), container);

      const up = dockerExecRc(container, "wg-quick up wg0");
      expect(up.rc, `wg-quick up on ${container}`).toBe(0);

      // Client N sends N * PINGS_PER_STEP pings through the tunnel
      const ping = dockerExecRc(container, `ping -c ${i * PINGS_PER_STEP} -i 0.2 -W 3 10.8.0.1`);
      expect(ping.rc, `ping from ${container}: ${ping.stdout}`).toBe(0);

      // The client completed a handshake
      const handshakes = dockerExecRc(container, "wg show wg0 latest-handshakes");
      expect(handshakes.rc).toBe(0);
      expect(handshakes.stdout).toMatch(/\t[1-9]\d*$/m);

      // The daemon recorded the handshake; handshake times have one-second resolution,
      // so the next client starts once the clock is past this handshake's second
      const peerRes = await apiCall<{ ok: boolean; data: { latest_handshake: number } }>(
        page, "POST", "/api/core/wireguard/peer", { name },
      );
      expect(peerRes.ok).toBe(true);
      expect(peerRes.data.latest_handshake).toBeGreaterThan(0);
      await expect
        .poll(() => Math.floor(Date.now() / 1000))
        .toBeGreaterThan(peerRes.data.latest_handshake);
    }

    for (let i = 1; i <= IDLE_COUNT; i++) {
      const name = idleName(i);
      const res = await apiCall<{ ok: boolean }>(
        page, "POST", "/api/core/clients/assign", { name },
      );
      expect(res.ok).toBe(true);
      createdClients.push(name);
    }
  });

  // ── 2. The API orders the connected clients by their traffic ──
  test("API: connected clients ordered by handshake, received and sent", async ({ page }) => {
    await login(page, adminPassword);
    const connected = (await peers(page)).filter((p) =>
      Array.from({ length: TABLE_CLIENTS }, (_, i) => connectedName(i + 1)).includes(p.name),
    );
    const latestFirst = Array.from({ length: TABLE_CLIENTS }, (_, i) =>
      connectedName(TABLE_CLIENTS - i),
    );
    for (const field of ["latest_handshake", "rx_bytes", "tx_bytes"] as const) {
      const order = [...connected].sort((a, b) => b[field] - a[field]).map((p) => p.name);
      expect(order, field).toEqual(latestFirst);
    }
  });

  // ── 3. Pagination ──────────────────────────────────────────────
  test("Pagination: name order across pages, refresh and page size", async ({ page }) => {
    await goTable(page, adminPassword);
    const all = await peers(page);
    expect(all.length).toBe(baselinePeers + TABLE_CLIENTS + IDLE_COUNT);
    const byName = expectedOrder(all, "name", "ASC");

    const pagination = page.getByTestId("vpn-wg-pagination");
    const refresh = page.getByTestId("vpn-wg-refresh");
    const rows = () => visibleRowNames(page);

    await expect.poll(rows).toEqual(byName.slice(0, DEFAULT_PAGE_SIZE));

    // Second page
    await pagination.locator(".cds--pagination__button--forward").click();
    await expect.poll(rows).toEqual(byName.slice(DEFAULT_PAGE_SIZE, 2 * DEFAULT_PAGE_SIZE));

    // A refresh keeps the page and its order (the API order changes on every call)
    await refresh.click();
    await expect(refresh).toBeEnabled();
    await expect.poll(rows).toEqual(byName.slice(DEFAULT_PAGE_SIZE, 2 * DEFAULT_PAGE_SIZE));

    // Page size 10 starts again from the first page
    await pagination.locator(".cds--pagination__left select").selectOption("10");
    await expect.poll(rows).toEqual(byName.slice(0, 10));
  });

  // ── 4. Search ──────────────────────────────────────────────────
  test("Search by name", async ({ page }) => {
    await goTable(page, adminPassword);
    const byName = expectedOrder(await peers(page), "name", "ASC");
    const search = page.getByTestId("vpn-wg-search");
    const rows = () => visibleRowNames(page);

    await search.fill(idleName(7));
    await expect.poll(rows).toEqual([idleName(7)]);
    await search.fill(connectedName(2));
    await expect.poll(rows).toEqual([connectedName(2)]);
    await search.fill("");
    await expect.poll(rows).toEqual(byName.slice(0, DEFAULT_PAGE_SIZE));
  });

  // ── 5. Sorting ─────────────────────────────────────────────────
  test("Sorting: name, last handshake, received and sent in both directions", async ({ page }) => {
    await goTable(page, adminPassword);
    const all = await peers(page);
    const rows = () => visibleRowNames(page);
    const firstPage = (key: SortKey, direction: Direction) =>
      expectedOrder(all, key, direction).slice(0, DEFAULT_PAGE_SIZE);

    // Name is the default sort: ascending, a click turns it descending
    await expect.poll(rows).toEqual(firstPage("name", "ASC"));
    await page.getByTestId("vpn-wg-sort-name").click();
    await expect.poll(rows).toEqual(firstPage("name", "DESC"));

    // Another column starts ascending, a second click turns it descending
    for (const key of ["last_handshake", "rx", "tx"] as const) {
      const header = page.getByTestId(`vpn-wg-sort-${key}`);
      await header.click();
      await expect.poll(rows, `${key} ASC`).toEqual(firstPage(key, "ASC"));
      await header.click();
      await expect.poll(rows, `${key} DESC`).toEqual(firstPage(key, "DESC"));
    }
  });

  test("Sorting: the headers hold their order and their next step", async ({ page }) => {
    await goTable(page, adminPassword);
    // Header names in English, the locale of the test browser
    const name = page.getByTestId("vpn-wg-sort-name");
    const received = page.getByTestId("vpn-wg-sort-rx");

    // Name ascending by default: its next click sorts descending
    await expect(page.locator("th", { has: name })).toHaveAttribute("aria-sort", "ascending");
    await expect(name).toHaveAccessibleDescription("Name: click to sort in descending order");
    // Another column starts ascending
    await expect(page.locator("th", { has: received })).toHaveAttribute("aria-sort", "none");
    await expect(received).toHaveAccessibleDescription(
      "Received: click to sort in ascending order",
    );

    // Name descending: its next click sorts ascending again, the table has no unsorted step
    await name.click();
    await expect(page.locator("th", { has: name })).toHaveAttribute("aria-sort", "descending");
    await expect(name).toHaveAccessibleDescription("Name: click to sort in ascending order");
  });

  // ── 6. Dashboard ───────────────────────────────────────────────
  test("Dashboard: latest handshake first, ten rows, total peers, one read", async ({ page }) => {
    // Every read of /api/core/wireguard, the test's own peers() included
    const reads: string[] = [];
    page.on("request", (r) => {
      if (new URL(r.url()).pathname === "/api/core/wireguard") reads.push(r.url());
    });

    // Login lands on the dashboard
    await login(page, adminPassword);
    const table = page.getByTestId("dashboard-wg-table");
    await expect(table).toBeVisible({ timeout: 10_000 });
    // The tile and the table show one read
    expect(reads, "reads of the dashboard").toHaveLength(1);
    const all = await peers(page);

    // Latest handshake first (the connected clients), equal values in name order
    await expect
      .poll(() => visibleRowNames(page, "dashboard-wg-row-"))
      .toEqual(expectedOrder(all, "last_handshake", "DESC").slice(0, DASHBOARD_PAGE_SIZE));

    // Six columns, no actions menu
    await expect(table.locator("thead th")).toHaveCount(6);
    await expect(table.locator(".cds--overflow-menu")).toHaveCount(0);

    // The WireGuard tile counts every peer
    await expect(page.getByTestId("dashboard-wg-total")).toHaveText(new RegExp(`^${all.length}\\s`));

    // The content of the other language reads the dashboard again, once
    const before = reads.length;
    await page.getByRole("button", { name: "Türkçe'ye geç" }).click();
    await expect(page.getByText("Sistem durumu ve genel bakış.")).toBeVisible();
    await expect(table).toBeVisible({ timeout: 10_000 });
    expect(reads.length - before, "reads after a language change").toBe(1);
  });

  // ── 7. Cleanup ─────────────────────────────────────────────────
  test("Cleanup: disconnect and revoke", async ({ page }) => {
    test.setTimeout(60_000);

    for (let i = 1; i <= TABLE_CLIENTS; i++) {
      dockerExecRc(tableContainer(i), "wg-quick down wg0");
    }

    await login(page, adminPassword);
    for (const name of createdClients) {
      const revokeRes = await apiCall<{ ok: boolean }>(
        page, "POST", "/api/core/clients/revoke", { name },
      );
      expect(revokeRes.ok).toBe(true);
    }

    // Only the peers from before the suite remain, on the API and in the table
    const remaining = await peers(page);
    expect(remaining.length).toBe(baselinePeers);
    await page.goto("/vpn/wireguard");
    await expect(page.getByTestId("vpn-wg-table")).toBeVisible({ timeout: 10_000 });
    await expect
      .poll(() => visibleRowNames(page))
      .toEqual(expectedOrder(remaining, "name", "ASC").slice(0, DEFAULT_PAGE_SIZE));
  });
});
