#!/usr/bin/env node
// noinspection HttpUrlsUsage

/**
 * SSG Pre-Rendering Pipeline — Phantom-WG Website
 *
 * Adapted from ARTEK Homepage prerender utility.
 * Cookie-based locale: output as index[.theme][.locale].html
 *
 * Usage: npm run prod
 * Requirements: npm install -D @playwright/test js-yaml p-limit prettier
 *               npx playwright install chromium
 */

import { chromium } from '@playwright/test';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { spawn } from 'child_process';
import yaml from 'js-yaml';
import pLimit from 'p-limit';
import prettier from 'prettier';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const PROJECT_ROOT = join(__dirname, '..', '..', '..');
const DIST_DIR = join(PROJECT_ROOT, 'dist');
const CONFIG_PATH = join(__dirname, 'config.yaml');
const ROUTES_PATH = join(PROJECT_ROOT, 'routes.yaml');

/**
 * @typedef {Object} Config
 * @property {string} production_url
 * @property {number} preview_port
 * @property {string} default_locale
 * @property {string} default_theme
 * @property {string[]} locales
 * @property {string[]} themes
 * @property {string[]} routes
 * @property {string[]} [exclude_from_sitemap]
 * @property {{ headless?: boolean, concurrency?: number }} [playwright]
 * @property {number} page_load_timeout
 * @property {number} wait_for_ready_timeout
 * @property {number} network_idle_timeout
 * @property {number} additional_wait
 */

const log = {
  info: (/** @type {string} */ msg) => console.log(`[INFO] ${msg}`),
  error: (/** @type {string} */ msg) => console.error(`[ERROR] ${msg}`),
  warning: (/** @type {string} */ msg) => console.log(`[WARNING] ${msg}`),
};

/**
 * Load configuration from YAML files
 * @returns {Config}
 */
function loadConfig() {
  const configContents = readFileSync(CONFIG_PATH, 'utf8');
  /** @type {Config} */
  const config = /** @type {Config} */ (yaml.load(configContents));

  const routesContents = readFileSync(ROUTES_PATH, 'utf8');
  const routesData = /** @type {{ routes?: string[] }} */ (yaml.load(routesContents));

  return {
    ...config,
    routes: routesData.routes || [],
  };
}

/**
 * Start preview server as subprocess
 * @param {Config} config
 * @returns {Promise<import('child_process').ChildProcess>}
 */
function startPreviewServer(config) {
  return new Promise((resolve, reject) => {
    log.info(`Starting preview server on port ${config.preview_port}`);

    const serverProcess = spawn(
      'npm',
      ['run', 'preview', '--', '--port', config.preview_port.toString()],
      { cwd: PROJECT_ROOT, stdio: 'pipe', shell: true }
    );

    const timeout = setTimeout(() => {
      log.info(`Preview server started (PID: ${serverProcess.pid})`);
      resolve(serverProcess);
    }, 3000);

    serverProcess.on('error', (error) => {
      clearTimeout(timeout);
      reject(error);
    });

    serverProcess.on('exit', (code) => {
      if (code !== null && code !== 0) {
        clearTimeout(timeout);
        reject(new Error(`Server exited with code ${code}`));
      }
    });
  });
}

/**
 * Stop preview server
 * @param {import('child_process').ChildProcess | null} serverProcess
 */
function stopPreviewServer(serverProcess) {
  if (serverProcess && !serverProcess.killed) {
    log.info('Stopping preview server');
    try {
      serverProcess.kill('SIGTERM');
      setTimeout(() => {
        if (!serverProcess.killed) serverProcess.kill('SIGKILL');
      }, 3000);
    } catch (error) {
      log.warning(`Server stop error: ${error.message}`);
    }
  }
}

/**
 * Pre-render a single route with locale and theme
 * @param {import('@playwright/test').Page} page
 * @param {string} route
 * @param {string} locale
 * @param {string} theme
 * @param {Config} config
 * @returns {Promise<boolean>}
 */
async function prerenderRoute(page, route, locale, theme, config) {
  const renderUrl = `${config.production_url}${route}?__prerendering=true&locale=${locale}&theme=${theme}`;

  // Filename pattern: index[.theme][.locale].html
  const outputFile = route === '/' ? 'index' : `${route.replace(/^\//, '')}/index`;
  const themeSuffix = theme === config.default_theme ? '' : `.${theme}`;
  const localeSuffix = locale === config.default_locale ? '' : `.${locale}`;
  const outputPath = join(DIST_DIR, `${outputFile}${themeSuffix}${localeSuffix}.html`);

  const label = `${route} [${locale}] [${theme}]`;
  log.info(`Rendering ${label}`);

  /** @type {{ css: Set<string>, js: Set<string> }} */
  const resources = { css: new Set(), js: new Set() };

  page.on('response', (response) => {
    const url = response.url();
    if (!response.ok() || !url.includes('/assets/')) return;
    const relativePath = url.replace(config.production_url, '');
    if (url.endsWith('.css')) resources.css.add(relativePath);
    else if (url.endsWith('.js') && !relativePath.includes('/assets/index-')) resources.js.add(relativePath);
  });

  try {
    await page.goto(renderUrl, {
      waitUntil: 'domcontentloaded',
      timeout: config.page_load_timeout * 1000,
    });

    await page.waitForFunction(() => document.querySelector('#root')?.innerHTML?.length > 100, {
      timeout: config.wait_for_ready_timeout * 1000,
    });

    await page.waitForLoadState('networkidle', {
      timeout: config.network_idle_timeout * 1000,
    });

    await page.waitForTimeout(config.additional_wait * 1000);

    let html = await page.content();

    if (html.length < 1000) {
      log.error(`Empty HTML for ${label}`);
      return false;
    }

    // Inject preload hints
    /** @type {string[]} */
    const preloadHints = [];
    Array.from(resources.css).forEach((href) => {
      preloadHints.push(`  <link rel="preload" href="${href}" as="style" crossorigin>`);
    });
    Array.from(resources.js).forEach((href) => {
      preloadHints.push(`  <link rel="modulepreload" href="${href}" crossorigin>`);
    });

    if (preloadHints.length > 0) {
      html = html.replace('</head>', `\n${preloadHints.join('\n')}\n  </head>`);
      log.info(`  → ${resources.css.size} CSS + ${resources.js.size} JS preload(s)`);
    }

    const beautifiedHtml = await prettier.format(html, {
      parser: 'html',
      printWidth: 120,
      tabWidth: 2,
      useTabs: false,
    });

    const outputDir = dirname(outputPath);
    if (!existsSync(outputDir)) mkdirSync(outputDir, { recursive: true });

    writeFileSync(outputPath, beautifiedHtml, 'utf-8');
    log.info(`Success: ${label}`);
    return true;
  } catch (error) {
    log.error(`Failed ${label}: ${error.message.substring(0, 150)}`);
    return false;
  }
}

/**
 * Pre-render all route × locale × theme combinations
 * @param {Config} config
 * @returns {Promise<number>} Number of successful renders
 */
async function prerenderAll(config) {
  // noinspection HttpUrlsUsage
  const prodDomain = config.production_url.replace('https://', '').replace('http://', '');

  log.info(`Pre-rendering ${config.routes.length} routes × ${config.locales.length} locales × ${config.themes.length} themes`);
  log.info(`DNS Override: ${prodDomain} → localhost:${config.preview_port}`);

  const browser = await chromium.launch({
    headless: config.playwright?.headless ?? true,
    args: [
      `--host-resolver-rules=MAP ${prodDomain}:443 localhost:${config.preview_port}`,
      '--ignore-certificate-errors',
    ],
  });

  const context = await browser.newContext({ ignoreHTTPSErrors: true });
  const concurrency = config.playwright?.concurrency || 5;
  const limit = pLimit(concurrency);

  log.info(`Rendering with concurrency: ${concurrency}`);

  /** @type {Array<{ route: string, locale: string, theme: string }>} */
  const tasks = [];
  for (const route of config.routes) {
    for (const locale of config.locales) {
      for (const theme of config.themes) {
        tasks.push({ route, locale, theme });
      }
    }
  }

  const results = await Promise.all(
    tasks.map(({ route, locale, theme }) =>
      limit(async () => {
        const page = await context.newPage();
        try {
          return await prerenderRoute(page, route, locale, theme, config);
        } finally {
          await page.close();
        }
      })
    )
  );

  await browser.close();
  return results.filter((success) => success).length;
}

/**
 * Generate sitemap.xml from routes and config
 * @param {Config} config
 */
function generateSitemap(config) {
  const today = new Date().toISOString().split('T')[0];
  const productionUrl = config.production_url.replace(/\/$/, '');
  const excluded = config.exclude_from_sitemap || [];

  const urls = config.routes.filter((route) => !excluded.includes(route)).map((route) => {
    const loc = route === '/' ? productionUrl + '/' : `${productionUrl}${route}`;

    // hreflang alternates: ?locale=xx → Worker serves correct prerendered HTML
    const alternates = config.locales.map((altLocale) => {
      const altLoc = `${loc}${loc.endsWith('/') ? '' : ''}?locale=${altLocale}`;
      return `    <xhtml:link rel="alternate" hreflang="${altLocale}" href="${altLoc}" />`;
    });
    const defaultLoc = `${loc}${loc.endsWith('/') ? '' : ''}?locale=${config.default_locale}`;
    alternates.push(`    <xhtml:link rel="alternate" hreflang="x-default" href="${defaultLoc}" />`);

    return [
      '  <url>',
      `    <loc>${loc}</loc>`,
      `    <lastmod>${today}</lastmod>`,
      ...alternates,
      '  </url>',
    ].join('\n');
  });

  const sitemap = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"',
    '        xmlns:xhtml="http://www.w3.org/1999/xhtml">',
    ...urls,
    '</urlset>',
    '',
  ].join('\n');

  writeFileSync(join(DIST_DIR, 'sitemap.xml'), sitemap, 'utf-8');
  log.info(`Sitemap generated (${config.routes.length} URLs)`);
}

/**
 * Generate robots.txt with sitemap reference
 * @param {Config} config
 */
function generateRobotsTxt(config) {
  const productionUrl = config.production_url.replace(/\/$/, '');

  const robotsTxt = [
    'User-agent: *',
    'Allow: /',
    '',
    `Sitemap: ${productionUrl}/sitemap.xml`,
    '',
  ].join('\n');

  writeFileSync(join(DIST_DIR, 'robots.txt'), robotsTxt, 'utf-8');
  log.info('robots.txt generated');
}

/**
 * Main execution
 */
async function main() {
  log.info('SSG Pre-Rendering - Starting');
  /** @type {import('child_process').ChildProcess | null} */
  let serverProcess = null;

  try {
    const config = loadConfig();
    log.info(`Config: ${config.routes.length} routes, ${config.locales.length} locales, ${config.themes.length} themes`);

    if (!existsSync(DIST_DIR)) {
      log.error('dist/ not found. Run npm run build first');
      return false;
    }

    // Build CF Worker
    try {
      const workerTemplate = readFileSync(join(__dirname, '_worker.js'), 'utf-8');
      const workerCode = workerTemplate
        .replace('__LOCALES__', JSON.stringify(config.locales))
        .replace('__DEFAULT_LOCALE__', `'${config.default_locale}'`)
        .replace('__THEMES__', JSON.stringify(config.themes))
        .replace('__DEFAULT_THEME__', `'${config.default_theme}'`);

      writeFileSync(join(DIST_DIR, '_worker.js'), workerCode, 'utf-8');
      log.info(`CF Worker built (locales: ${config.locales.join(', ')}, themes: ${config.themes.join(', ')})`);
    } catch (error) {
      log.warning(`Failed to build _worker.js: ${error.message}`);
    }

    // Generate SEO files
    try {
      generateSitemap(config);
      generateRobotsTxt(config);
    } catch (error) {
      log.warning(`Failed to generate sitemap/robots.txt: ${error.message}`);
    }

    // Start preview server
    serverProcess = await startPreviewServer(config);

    // Pre-render all routes
    const successCount = await prerenderAll(config);
    const total = config.routes.length * config.locales.length * config.themes.length;

    log.info(`Complete: ${successCount}/${total} successful`);
    return successCount === total;
  } catch (error) {
    if (error.code === 'ENOENT') {
      log.error(`File not found: ${error.path}`);
    } else {
      log.error(`Fatal error: ${error.message}`);
    }
    return false;
  } finally {
    stopPreviewServer(serverProcess);
  }
}

// Run
main()
  .then((success) => process.exit(success ? 0 : 1))
  .catch((error) => {
    log.error(`Unhandled error: ${error}`);
    process.exit(1);
  });
