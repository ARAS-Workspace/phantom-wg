import { expect, test } from "@playwright/test";

// The audit log page against auth-service 1.3.0. Every read of the log writes
// an audit_viewed row on top of it. Page 1 opens a snapshot (its as_of) and
// the other pages read in it: page 2 holds the ten rows right below page 1,
// whatever was written in between. Going back to page 1 opens a new snapshot.
// The filter lists the actions of 1.3.0; one user action sends one read, so
// it writes one row. The time header shows its order and tells a screen
// reader what its next click does.

const SUPERADMIN = "admin"; // the bootstrap account, role superadmin
const PAGE_SIZE = 10;
const TIME = "Time"; // audit.timestamp in English, the locale of the test browser

type Page = import("@playwright/test").Page;
type APIRequestContext = import("@playwright/test").APIRequestContext;
type Response = import("@playwright/test").Response;

interface AuditRow {
  id: number;
  action: string;
  detail: Record<string, unknown>;
}

interface AuditPage {
  items: AuditRow[];
  total: number;
  as_of: number | null;
}

// ── Helpers ──────────────────────────────────────────────────────

async function superadminToken(request: APIRequestContext, password: string): Promise<string> {
  const login = await request.post("/auth/login", {
    data: { username: SUPERADMIN, password },
  });
  expect(login.status()).toBe(200);
  return (await login.json()).data.token as string;
}

async function login(page: Page, password: string) {
  await page.goto("/login");
  await page.getByTestId("login-username").fill(SUPERADMIN);
  await page.getByTestId("login-password").fill(password);
  await page.getByTestId("login-submit").click();
  await expect(page).toHaveURL("/");
}

// A read of the log through the API: it writes its own audit_viewed row
async function readLog(request: APIRequestContext, token: string, query: string) {
  const res = await request.get(`/auth/audit?${query}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  expect(res.status()).toBe(200);
  return (await res.json()).data as AuditPage;
}

// Runs the action and returns the query of the log read it sends
async function pageRead(page: Page, action: () => Promise<unknown>): Promise<URLSearchParams> {
  const [response] = await Promise.all([
    page.waitForResponse(
      (r: Response) =>
        new URL(r.url()).pathname === "/auth/audit" && r.request().method() === "GET"
    ),
    action(),
  ]);
  expect(response.status()).toBe(200);
  return new URL(response.url()).searchParams;
}

// Row ids on the page, top to bottom
async function rowIds(page: Page): Promise<number[]> {
  return page
    .locator("[data-testid^='audit-overflow-']")
    .evaluateAll((elements) =>
      elements.map((el) => Number(el.getAttribute("data-testid")!.replace("audit-overflow-", "")))
    );
}

test.describe.serial("Admin audit log", () => {
  let password: string;

  test.beforeAll(() => {
    password = process.env.ADMIN_PASSWORD ?? "";
  });

  // ── 1. Setup ───────────────────────────────────────────────────

  test("Setup: the log holds more than two pages", async ({ request }) => {
    const token = await superadminToken(request, password);
    for (let i = 0; i < 2 * PAGE_SIZE + 5; i++) {
      await readLog(request, token, "limit=1");
    }
    const log = await readLog(request, token, "limit=1");
    expect(log.total).toBeGreaterThan(2 * PAGE_SIZE);
  });

  // ── 2. Pages of one query ──────────────────────────────────────

  test("Pages: page 2 reads in the snapshot of page 1", async ({ page, request }) => {
    await login(page, password);
    await pageRead(page, () => page.goto("/admin/audit"));
    await expect(page.getByTestId("audit-table")).toBeVisible();

    let first: number[] = [];
    await test.step("page 1 of ten rows opens a snapshot", async () => {
      const query = await pageRead(page, () =>
        page.locator(".cds--pagination__left select").selectOption(String(PAGE_SIZE))
      );
      expect(query.get("page")).toBe("1");
      expect(query.has("as_of")).toBe(false);
      await expect(page.locator("[data-testid^='audit-overflow-']")).toHaveCount(PAGE_SIZE);
      first = await rowIds(page);
    });
    const top = first[0];
    const bottom = first[PAGE_SIZE - 1];

    await test.step("page 2 holds the ten rows below page 1", async () => {
      await pageRead(page, () => page.locator(".cds--pagination__button--forward").click());
      const below = Array.from({ length: PAGE_SIZE }, (_, i) => bottom - 1 - i);
      await expect.poll(() => rowIds(page)).toEqual(below);
    });

    await test.step("the read of page 2 sent the as_of of page 1", async () => {
      const token = await superadminToken(request, password);
      const log = await readLog(request, token, "action=audit_viewed&limit=20");
      const read = log.items.find(
        (row) => row.detail.page === 2 && row.detail.limit === PAGE_SIZE
      );
      expect(read, "the audit_viewed row of the page 2 read").toBeDefined();
      expect(read!.detail.as_of).toBe(top);
    });

    await test.step("page 1 again opens a new snapshot", async () => {
      const query = await pageRead(page, () =>
        page.locator(".cds--pagination__button--backward").click()
      );
      expect(query.get("page")).toBe("1");
      expect(query.has("as_of")).toBe(false);
      await expect.poll(async () => (await rowIds(page))[0]).toBeGreaterThan(top);
    });
  });

  // ── 3. Filter ──────────────────────────────────────────────────

  test("Filter: one selection, one read, its action only", async ({ page, request }) => {
    await login(page, password);
    await pageRead(page, () => page.goto("/admin/audit"));
    await expect(page.getByTestId("audit-table")).toBeVisible();

    const token = await superadminToken(request, password);
    const before = (await readLog(request, token, "action=audit_viewed&limit=1")).total;

    const reads: string[] = [];
    page.on("request", (r) => {
      if (new URL(r.url()).pathname === "/auth/audit") reads.push(r.url());
    });
    await page.locator(".audit-log__filter-btn").click();
    const select = page.locator("#audit-action-popover-select");
    const option = (action: string) => select.locator(`option[value='${action}']`);
    for (const action of ["reauth_failed", "request_refused", "audit_viewed"]) {
      await expect(option(action), `filter option ${action}`).toHaveCount(1);
    }
    const query = await pageRead(page, () => select.selectOption("audit_viewed"));
    expect(query.get("action")).toBe("audit_viewed");
    await page.waitForLoadState("networkidle");
    expect(reads, "log reads of one selection").toHaveLength(1);

    const actions = await page
      .getByTestId("audit-table")
      .locator("tbody .cds--tag")
      .allTextContents();
    expect(actions.length).toBeGreaterThan(0);
    expect(new Set(actions)).toEqual(new Set(["audit_viewed"]));

    // the count read above, then the one read of the selection
    const after = (await readLog(request, token, "action=audit_viewed&limit=1")).total;
    expect(after - before, "audit_viewed rows of one selection and one count").toBe(2);
  });

  // ── 4. Sort ────────────────────────────────────────────────────

  test("Sort: the time header holds its order and its next step", async ({ page }) => {
    await login(page, password);
    await pageRead(page, () => page.goto("/admin/audit"));
    const button = page.getByTestId("audit-sort-timestamp");
    const header = page.locator("th", { has: button });

    // newest first; the next click sorts ascending
    await expect(header).toHaveAttribute("aria-sort", "descending");
    await expect(button).toHaveClass(/cds--table-sort--active/);
    await expect(button).toHaveAccessibleDescription(`${TIME}: click to sort in ascending order`);

    const query = await pageRead(page, () => button.click());
    expect(query.get("order")).toBe("asc");
    await expect(header).toHaveAttribute("aria-sort", "ascending");
    await expect(button).toHaveAccessibleDescription(`${TIME}: click to sort in descending order`);
  });
});
