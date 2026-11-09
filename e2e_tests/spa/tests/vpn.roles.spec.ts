import { expect, test } from "@playwright/test";

// The admin role against the access classes of auth-service (GRANTS in
// routes/proxy.py, copied in the SPA's access.ts). An admin keeps the reads,
// the pool check, the multihop status and the client tunnels. The controls of
// OPERATE and MULTIHOP routes are not on its pages, and none of its pages sends
// a request the proxy refuses. The superadmin keeps every control.

const SUPERADMIN = "admin"; // the bootstrap account, role superadmin
const ROLE_USER = "e2e-roles-admin";
const ROLE_PASSWORD = "E2e-Roles-Admin-2026!";

// daemon_api_codes.FORBIDDEN in English, the locale of the test browser
const FORBIDDEN_TEXT = "You do not have permission for this action.";

type Page = import("@playwright/test").Page;
type APIRequestContext = import("@playwright/test").APIRequestContext;

// ── Helpers ──────────────────────────────────────────────────────

async function superadminToken(request: APIRequestContext, password: string): Promise<string> {
  const login = await request.post("/auth/login", {
    data: { username: SUPERADMIN, password },
  });
  expect(login.status()).toBe(200);
  return (await login.json()).data.token as string;
}

async function login(page: Page, username: string, password: string) {
  await page.goto("/login");
  await page.getByTestId("login-username").fill(username);
  await page.getByTestId("login-password").fill(password);
  await page.getByTestId("login-submit").click();
  await expect(page).toHaveURL("/");
}

// Every /api/ request the proxy refuses (403) while the page is open
function watchRefusals(page: Page): string[] {
  const refused: string[] = [];
  page.on("response", (response) => {
    const path = new URL(response.url()).pathname;
    if (response.status() === 403 && path.startsWith("/api/")) {
      refused.push(`${response.request().method()} ${path}`);
    }
  });
  return refused;
}

test.describe.serial("VPN roles", () => {
  let password: string;

  test.beforeAll(() => {
    password = process.env.ADMIN_PASSWORD ?? "";
  });

  // ── 1. Setup ───────────────────────────────────────────────────
  test("Setup: an account with the admin role", async ({ request }) => {
    const token = await superadminToken(request, password);
    const headers = { Authorization: `Bearer ${token}` };

    // A failed attempt leaves the account behind; it is created again
    await request.delete(`/auth/users/${ROLE_USER}`, { headers });
    const created = await request.post("/auth/users", {
      headers,
      data: { username: ROLE_USER, password: ROLE_PASSWORD },
    });
    expect(created.status()).toBe(200);
    expect((await created.json()).data.role).toBe("admin");
  });

  // ── 2. Dashboard ───────────────────────────────────────────────
  test("Dashboard: the reads of the admin are answered", async ({ page }) => {
    const refused = watchRefusals(page);
    await login(page, ROLE_USER, ROLE_PASSWORD);

    // Drawn once hello, network, wireguard and multihop/status have answered
    await expect(page.getByTestId("dashboard-wg-total")).toBeVisible({ timeout: 10_000 });
    expect(refused).toEqual([]);
  });

  // ── 3. Network ─────────────────────────────────────────────────
  test("Network: the pool is checked, the CIDR is not changed", async ({ page }) => {
    const refused = watchRefusals(page);
    await login(page, ROLE_USER, ROLE_PASSWORD);
    await page.goto("/vpn/network");

    await expect(page.getByTestId("vpn-net-card-v4")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-net-refresh")).toBeVisible();
    await expect(page.getByTestId("vpn-net-edit-cidr")).toHaveCount(0);

    await page.getByTestId("vpn-net-validate-btn").click();
    await expect(page.getByTestId("vpn-net-validate-result")).toBeVisible();
    expect(refused).toEqual([]);
  });

  // ── 4. DNS ─────────────────────────────────────────────────────
  test("DNS: the servers are read, not edited", async ({ page }) => {
    const refused = watchRefusals(page);
    await login(page, ROLE_USER, ROLE_PASSWORD);
    await page.goto("/vpn/dns");

    await expect(page.getByTestId("vpn-dns-card-v4")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-dns-refresh-v4")).toBeVisible();
    await expect(page.getByTestId("vpn-dns-refresh-v6")).toBeVisible();
    await expect(page.getByTestId("vpn-dns-edit-v4")).toHaveCount(0);
    await expect(page.getByTestId("vpn-dns-edit-v6")).toHaveCount(0);
    expect(refused).toEqual([]);
  });

  // ── 5. Multihop ────────────────────────────────────────────────
  test("Multihop: the status tile, without the exits", async ({ page }) => {
    const refused = watchRefusals(page);
    await login(page, ROLE_USER, ROLE_PASSWORD);
    await page.goto("/vpn/multihop");

    // Drawn once every request of the page's first fetch has answered
    await expect(page.getByTestId("vpn-mh-status-tile")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-mh-table")).toHaveCount(0);
    await expect(page.getByTestId("vpn-mh-import-btn")).toHaveCount(0);
    expect(refused).toEqual([]);
  });

  // ── 6. Clients ─────────────────────────────────────────────────
  test("Clients: the tunnels stay with the admin", async ({ page }) => {
    const refused = watchRefusals(page);
    await login(page, ROLE_USER, ROLE_PASSWORD);
    await page.goto("/vpn/clients");

    // The table is drawn once the client list has answered
    await expect(page.getByTestId("vpn-cl-table")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-cl-add-client")).toBeVisible();
    expect(refused).toEqual([]);
  });

  // ── 7. Refused request ─────────────────────────────────────────
  // No control on the admin's pages is refused by the proxy, so the test
  // answers one request with 403 itself: the modal shows the permission
  // message of daemon_api_codes, not the generic error.
  test("Refused: a 403 shows the permission message", async ({ page }) => {
    await login(page, ROLE_USER, ROLE_PASSWORD);
    await page.goto("/vpn/clients");
    await expect(page.getByTestId("vpn-cl-add-client")).toBeVisible({ timeout: 10_000 });

    await page.route("**/api/core/clients/assign", (route) =>
      route.fulfill({
        status: 403,
        contentType: "application/json",
        body: JSON.stringify({ ok: false, error_code: "SUPERADMIN_REQUIRED" }),
      }),
    );

    await page.getByTestId("vpn-cl-add-client").click();
    const modal = page.getByTestId("vpn-cl-create-modal");
    await expect(modal).toBeVisible();
    await page.getByTestId("vpn-cl-create-name").fill("e2e-roles-refused");

    const createBtn = modal.locator(".cds--modal-footer .cds--btn--primary");
    await expect(createBtn).toBeEnabled();
    await createBtn.click();
    await expect(modal.locator(".clients__modal-error")).toContainText(FORBIDDEN_TEXT);
  });

  // ── 8. Superadmin ──────────────────────────────────────────────
  test("Superadmin: every control is on the pages", async ({ page }) => {
    await login(page, SUPERADMIN, password);

    await page.goto("/vpn/network");
    await expect(page.getByTestId("vpn-net-edit-cidr")).toBeVisible({ timeout: 10_000 });

    await page.goto("/vpn/dns");
    await expect(page.getByTestId("vpn-dns-edit-v4")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-dns-edit-v6")).toBeVisible();

    await page.goto("/vpn/multihop");
    await expect(page.getByTestId("vpn-mh-table")).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId("vpn-mh-import-btn")).toBeVisible();
  });

  // ── 9. Cleanup ─────────────────────────────────────────────────
  test("Cleanup: the admin account is removed", async ({ request }) => {
    const token = await superadminToken(request, password);
    const removed = await request.delete(`/auth/users/${ROLE_USER}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(removed.status()).toBe(200);
  });
});
