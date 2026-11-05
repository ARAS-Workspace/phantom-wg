import { test, expect } from "@playwright/test";
import * as fs from "fs";
import * as path from "path";
import * as os from "os";

const ADMIN_USER = "admin";
const ROLE_USER = "e2e-backup-role";
const ROLE_PASSWORD = "E2e-Backup-Role-2026!";

test.describe.serial("VPN Backup", () => {
  let adminPassword: string;
  let downloadDir: string;
  let exportedFile: string;

  test.beforeAll(() => {
    adminPassword = process.env.ADMIN_PASSWORD ?? "";
    downloadDir = fs.mkdtempSync(path.join(os.tmpdir(), "backup-e2e-"));
  });

  test.afterAll(() => {
    fs.rmSync(downloadDir, { recursive: true, force: true });
  });

  // ── Helper: login and navigate to backup page ─────────────────
  async function loginAndGoBackup(page: import("@playwright/test").Page) {
    await page.goto("/login");
    await page.getByTestId("login-username").fill(ADMIN_USER);
    await page.getByTestId("login-password").fill(adminPassword);
    await page.getByTestId("login-submit").click();
    await expect(page).toHaveURL("/");
    await page.goto("/vpn/backup");
    await expect(page.getByTestId("vpn-backup-tile-export")).toBeVisible({
      timeout: 10_000,
    });
  }

  // ── 1. Page loads with both tiles ─────────────────────────────
  test("Backup page shows export and import tiles", async ({ page }) => {
    await loginAndGoBackup(page);

    await expect(page.getByTestId("nav-vpn-backup")).toHaveCount(1);
    await expect(page.getByTestId("vpn-backup-tile-export")).toBeVisible();
    await expect(page.getByTestId("vpn-backup-tile-import")).toBeVisible();
    await expect(page.getByTestId("vpn-backup-export-btn")).toBeVisible();
    await expect(page.getByTestId("vpn-backup-import-btn")).toBeVisible();
  });

  // ── 2. Export backup — download .tar ──────────────────────────
  test("Export downloads a .tar file", async ({ page }) => {
    await loginAndGoBackup(page);

    const [download] = await Promise.all([
      page.waitForEvent("download"),
      page.getByTestId("vpn-backup-export-btn").click(),
    ]);

    const suggestedName = download.suggestedFilename();
    expect(suggestedName).toMatch(/^phantom-backup-.*\.tar$/);

    exportedFile = path.join(downloadDir, suggestedName);
    await download.saveAs(exportedFile);

    const stat = fs.statSync(exportedFile);
    expect(stat.size).toBeGreaterThan(0);
  });

  // ── 3. Import — upload exported .tar → preview → confirm ─────
  test("Import uploaded backup shows preview and restores", async ({
    page,
  }) => {
    await loginAndGoBackup(page);

    // Trigger file input with the exported .tar
    const fileInput = page.getByTestId("vpn-backup-file-input");
    await fileInput.setInputFiles(exportedFile);

    // Preview should appear with manifest data
    await expect(page.getByTestId("vpn-backup-preview")).toBeVisible({
      timeout: 10_000,
    });
    await expect(page.getByTestId("vpn-backup-preview-subnet")).toBeVisible();
    await expect(page.getByTestId("vpn-backup-preview-clients")).toBeVisible();
    await expect(page.getByTestId("vpn-backup-preview-exits")).toBeVisible();
    await expect(
      page.getByTestId("vpn-backup-preview-timestamp"),
    ).toBeVisible();

    // Confirm import
    await page.getByTestId("vpn-backup-confirm-btn").click();

    // Done state
    await expect(page.getByTestId("vpn-backup-done")).toBeVisible({
      timeout: 15_000,
    });
  });

  // ── 4. Import invalid file — client-side validation error ─────
  test("Import invalid file shows validation error", async ({ page }) => {
    await loginAndGoBackup(page);

    // Create a fake .tar file with garbage content
    const fakeFile = path.join(downloadDir, "fake-backup.tar");
    fs.writeFileSync(fakeFile, "this is not a tar file");

    const fileInput = page.getByTestId("vpn-backup-file-input");
    await fileInput.setInputFiles(fakeFile);

    // Should show failed state with error
    await expect(page.getByTestId("vpn-backup-retry-btn")).toBeVisible({
      timeout: 5_000,
    });

    // Error notification should be visible
    await expect(
      page.locator(".cds--inline-notification--error"),
    ).toBeVisible();

    // Retry button returns to idle
    await page.getByTestId("vpn-backup-retry-btn").click();
    await expect(page.getByTestId("vpn-backup-import-btn")).toBeVisible();
  });

  // ── 5. Import cancel from preview ─────────────────────────────
  test("Cancel from preview returns to idle", async ({ page }) => {
    await loginAndGoBackup(page);

    const fileInput = page.getByTestId("vpn-backup-file-input");
    await fileInput.setInputFiles(exportedFile);

    await expect(page.getByTestId("vpn-backup-preview")).toBeVisible({
      timeout: 10_000,
    });

    // Cancel
    await page.getByTestId("vpn-backup-cancel-btn").click();

    // Back to idle
    await expect(page.getByTestId("vpn-backup-import-btn")).toBeVisible();
  });

  // ── 6. Admin role: no menu item, the page sends back ──────────
  test("Admin role has no backup menu item or page", async ({
    page,
    request,
  }) => {
    const login = await request.post("/auth/login", {
      data: { username: ADMIN_USER, password: adminPassword },
    });
    const { data } = await login.json();
    const created = await request.post("/auth/users", {
      headers: { Authorization: `Bearer ${data.token}` },
      data: { username: ROLE_USER, password: ROLE_PASSWORD },
    });
    expect([200, 409]).toContain(created.status());

    await page.goto("/login");
    await page.getByTestId("login-username").fill(ROLE_USER);
    await page.getByTestId("login-password").fill(ROLE_PASSWORD);
    await page.getByTestId("login-submit").click();
    await expect(page).toHaveURL("/");

    await expect(page.getByTestId("nav-vpn-clients")).toHaveCount(1);
    await expect(page.getByTestId("nav-vpn-backup")).toHaveCount(0);

    await page.goto("/vpn/backup");
    await expect(page).toHaveURL("/");
    await expect(page.getByTestId("vpn-backup-tile-export")).toHaveCount(0);
  });
});
