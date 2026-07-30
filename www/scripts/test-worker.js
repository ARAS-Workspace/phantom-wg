#!/usr/bin/env node

/**
 * End-to-end contract suite for the edge worker.
 *
 * The worker's header comment describes six stages; this file is that
 * description made executable. It runs against the real production artefact —
 * `wrangler pages dev` over the built `dist/`, the same worker and the same
 * asset store the deployment uses — because the behaviors under test live in
 * the seams between the worker and the platform (what Pages answers for a
 * miss, how redirects surface, which headers survive), and no unit test sees
 * a seam.
 *
 * Sections mirror the worker's stages, so a failure names the stage that
 * broke. Every assertion states the *observed, intended* contract, including
 * the deliberate oddities: unknown routes answer 200 with the shell (the
 * not-found page is the application's job), `/index.html` surfaces the
 * platform's 308, and a direct sidecar request is served but never cached as
 * immutable.
 *
 * Usage:
 *   npm run prod           # the suite tests the build output — build first
 *   npm run test:worker    # spawns wrangler on a scratch port, tears it down
 *   node scripts/test-worker.js --url http://127.0.0.1:8788   # reuse a server
 */

import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DIST = path.join(ROOT, 'dist');
// Overridable for the one environment the suite shares with other work — the
// self-hosted CI runner — so a port collision is a one-line workflow fix. The
// default deliberately differs from emrearascom-www's 8790: the two suites
// must be able to run side by side on the same runner.
const PORT = Number(process.env.TEST_WORKER_PORT) || 8791;

const urlFlag = process.argv.indexOf('--url');
const EXTERNAL = urlFlag !== -1 ? process.argv[urlFlag + 1].replace(/\/$/, '') : null;
const BASE = EXTERNAL ?? `http://127.0.0.1:${PORT}`;

const log = (msg) => console.log(`[test-worker] ${msg}`);

// ── Fixtures from the build ──────────────────────────────────────────────────
// Hashed filenames rotate every content change, so the suite reads them from
// the build it is testing instead of hard-coding names that were true once.

if (!existsSync(path.join(DIST, '_worker.js'))) {
  console.error('[test-worker] dist/_worker.js not found — run `npm run prod` first');
  process.exit(1);
}

const indexHtml = readFileSync(path.join(DIST, 'index.html'), 'utf8');
const HASHED_JS = indexHtml.match(/\/assets\/index-[\w-]{8}\.js/)?.[0];
const HASHED_CSS = indexHtml.match(/\/assets\/index-[\w-]{8}\.css/)?.[0];
const assetNames = readdirSync(path.join(DIST, 'assets'));
const HASHED_WOFF2 = assetNames.find((n) => n.endsWith('.woff2'));
// Optional on purpose: the sidecars are slated for removal, and the suite
// must stay green the day they go.
const SIDECAR = assetNames.find((n) => n.endsWith('.js.gz'));

if (!HASHED_JS || !HASHED_CSS || !HASHED_WOFF2) {
  console.error('[test-worker] could not locate hashed js/css/woff2 fixtures in dist/');
  process.exit(1);
}

// ── Server lifecycle ─────────────────────────────────────────────────────────
// Spawned detached so the whole process group (npx → wrangler → workerd) can
// be torn down with one signal; a stray workerd would hold the port hostage
// for every later run.

let server = null;
let serverLog = '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function startServer() {
  server = spawn('npx', ['wrangler', 'pages', 'dev', 'dist', '--port', String(PORT), '--ip', '127.0.0.1'], {
    cwd: ROOT,
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  server.stdout.on('data', (d) => (serverLog += d));
  server.stderr.on('data', (d) => (serverLog += d));

  const deadline = Date.now() + 45_000;
  while (Date.now() < deadline) {
    try {
      await fetch(`${BASE}/`, { signal: AbortSignal.timeout(2000) });
      return;
    } catch {
      await sleep(500);
    }
  }
  console.error('[test-worker] server did not come up; last output:');
  console.error(serverLog.split('\n').slice(-15).join('\n'));
  stopServer();
  process.exit(1);
}

function stopServer() {
  if (!server) return;
  try {
    process.kill(-server.pid, 'SIGTERM');
  } catch {
    server.kill('SIGTERM');
  }
  server = null;
}

process.on('SIGINT', () => {
  stopServer();
  process.exit(130);
});

// ── Assertion helpers ────────────────────────────────────────────────────────

let pass = 0;
let fail = 0;

// Redirects are never followed: a 308 is part of the contract under test,
// and following it would assert the wrong URL's behavior.
async function probe(pathname, headers = {}) {
  const res = await fetch(BASE + pathname, { headers, redirect: 'manual' });
  const body = await res.text();
  return { status: res.status, headers: res.headers, body };
}

function expect(cond, detail) {
  if (!cond) throw new Error(detail);
}

const header = (r, name) => r.headers.get(name) || '';
const sha = (s) => createHash('sha256').update(s).digest('hex');

async function test(name, fn) {
  try {
    await fn();
    pass += 1;
    console.log(`  ✓ ${name}`);
  } catch (error) {
    fail += 1;
    console.log(`  ✗ ${name} — ${error.message}`);
  }
}

const section = (title) => console.log(`\n── ${title} ${'─'.repeat(Math.max(1, 66 - title.length))}`);

// ── The suite ────────────────────────────────────────────────────────────────

async function run() {
  section('0. Negotiation — locale (query → cookie → default), theme (cookie)');

  await test('default document is English, white, no-cache, Vary set', async () => {
    const r = await probe('/');
    expect(r.status === 200, `status ${r.status}`);
    expect(r.body.includes('lang="en"'), 'lang is not en');
    expect(r.body.includes('data-carbon-theme="white"'), 'theme is not white');
    expect(header(r, 'content-language') === 'en', `Content-Language ${header(r, 'content-language')}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
    expect(header(r, 'vary') === 'Accept, Cookie', `Vary ${header(r, 'vary')}`);
  });

  await test('?locale=tr switches the document', async () => {
    const r = await probe('/?locale=tr');
    expect(r.body.includes('lang="tr"'), 'lang is not tr');
    expect(header(r, 'content-language') === 'tr', `Content-Language ${header(r, 'content-language')}`);
  });

  await test('preferred_locale cookie switches the document', async () => {
    const r = await probe('/', { cookie: 'preferred_locale=tr' });
    expect(r.body.includes('lang="tr"'), 'lang is not tr');
  });

  await test('explicit query outranks the cookie', async () => {
    const r = await probe('/?locale=en', { cookie: 'preferred_locale=tr' });
    expect(r.body.includes('lang="en"'), 'query did not win');
  });

  await test('unknown query locale falls through to the cookie', async () => {
    const r = await probe('/?locale=de', { cookie: 'preferred_locale=tr' });
    expect(r.body.includes('lang="tr"'), 'did not fall to cookie');
  });

  await test('unknown query locale without a cookie falls to the default', async () => {
    const r = await probe('/?locale=de');
    expect(r.body.includes('lang="en"'), 'did not fall to default');
  });

  await test('malformed locale cookie falls to the default', async () => {
    const r = await probe('/', { cookie: 'preferred_locale=trx' });
    expect(r.body.includes('lang="en"'), 'malformed cookie was honored');
  });

  await test('preferred_theme=g100 switches the document', async () => {
    const r = await probe('/', { cookie: 'preferred_theme=g100' });
    expect(r.body.includes('data-carbon-theme="g100"'), 'theme is not g100');
  });

  await test('malformed theme cookie falls to the default, not a prefix match', async () => {
    const r = await probe('/', { cookie: 'preferred_theme=g100x' });
    expect(r.body.includes('data-carbon-theme="white"'), 'g100x was prefix-matched');
  });

  await test('theme and locale combine', async () => {
    const r = await probe('/', { cookie: 'preferred_theme=g100; preferred_locale=tr' });
    expect(r.body.includes('data-carbon-theme="g100"'), 'theme lost');
    expect(r.body.includes('lang="tr"'), 'locale lost');
  });

  section('1. llms endpoints — negotiated markdown, explicit 404 on a miss');

  await test('/llms-full.txt serves markdown with the default locale', async () => {
    const r = await probe('/llms-full.txt');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/markdown'), header(r, 'content-type'));
    expect(header(r, 'content-language') === 'en', `Content-Language ${header(r, 'content-language')}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
    expect(header(r, 'vary') === 'Accept, Cookie', `Vary ${header(r, 'vary')}`);
  });

  await test('/llms-full.txt?locale=tr is a different document', async () => {
    const en = await probe('/llms-full.txt');
    const tr = await probe('/llms-full.txt?locale=tr');
    expect(header(tr, 'content-language') === 'tr', `Content-Language ${header(tr, 'content-language')}`);
    expect(sha(en.body) !== sha(tr.body), 'en and tr bodies are identical');
  });

  await test('the locale cookie reaches llms too', async () => {
    const r = await probe('/llms-full.txt', { cookie: 'preferred_locale=tr' });
    expect(header(r, 'content-language') === 'tr', `Content-Language ${header(r, 'content-language')}`);
  });

  await test('unknown ?locale on llms falls to the default', async () => {
    const r = await probe('/llms-full.txt?locale=de');
    expect(header(r, 'content-language') === 'en', `Content-Language ${header(r, 'content-language')}`);
  });

  await test('root /llms.txt maps to the home page dump', async () => {
    const r = await probe('/llms.txt');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/markdown'), header(r, 'content-type'));
  });

  await test('/docs/quickstart-guide/llms.txt serves that page\'s dump', async () => {
    const r = await probe('/docs/quickstart-guide/llms.txt');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/markdown'), header(r, 'content-type'));
  });

  await test('a path without llms/ answers a real 404, not the shell', async () => {
    const r = await probe('/docs/client-applications/llms.txt');
    expect(r.status === 404, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/plain'), header(r, 'content-type'));
  });

  await test('an unknown route follows the same 404 rule', async () => {
    const r = await probe('/this-route-does-not-exist/llms.txt');
    expect(r.status === 404, `status ${r.status}`);
  });

  await test('llms bodies are markdown, never the HTML shell', async () => {
    const r = await probe('/llms-full.txt');
    expect(!/^\s*<!doctype/i.test(r.body), 'body is the HTML shell');
  });

  section('2. Static files — immutable hashes, protocol 404s under /assets/');

  await test('hashed js is immutable for a year', async () => {
    const r = await probe(HASHED_JS);
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'public, max-age=31536000, immutable', header(r, 'cache-control'));
  });

  await test('hashed css is immutable for a year', async () => {
    const r = await probe(HASHED_CSS);
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'public, max-age=31536000, immutable', header(r, 'cache-control'));
  });

  await test('hashed woff2 is immutable for a year', async () => {
    const r = await probe(`/assets/${HASHED_WOFF2}`);
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'public, max-age=31536000, immutable', header(r, 'cache-control'));
  });

  await test('a query string does not change asset routing', async () => {
    const r = await probe(`${HASHED_JS}?cb=12345`);
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'public, max-age=31536000, immutable', header(r, 'cache-control'));
  });

  await test('a missing /assets/ js is a real 404 and never cached', async () => {
    const r = await probe('/assets/missing-AAAAAAAA.js');
    expect(r.status === 404, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/plain'), header(r, 'content-type'));
    expect(header(r, 'cache-control') === 'no-store', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('a missing /assets/ css follows the same rule', async () => {
    const r = await probe('/assets/missing-AAAAAAAA.css');
    expect(r.status === 404, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-store', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('an unhashed image under /assets/ revalidates, never immutable', async () => {
    const r = await probe('/assets/images/logo.png');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('favicon.svg revalidates (not hashed, not immutable)', async () => {
    const r = await probe('/favicon.svg');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('robots.txt is a file, not an llms endpoint', async () => {
    const r = await probe('/robots.txt');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/plain'), header(r, 'content-type'));
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('sitemap.xml revalidates', async () => {
    const r = await probe('/sitemap.xml');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('manifest.json revalidates', async () => {
    const r = await probe('/manifest.json');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  await test('openapi.json revalidates', async () => {
    const r = await probe('/openapi.json');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });

  if (SIDECAR) {
    await test('a sidecar asked for directly is served but never immutable', async () => {
      const r = await probe(`/assets/${SIDECAR}`);
      expect(r.status === 200, `status ${r.status}`);
      expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
    });
  } else {
    log('no .js.gz sidecar in dist/assets — sidecar test skipped (expected after their removal)');
  }

  section('3. Markdown negotiation — the same URL, a second representation');

  await test('Accept: text/markdown turns a page into its llms text', async () => {
    const r = await probe('/docs/quickstart-guide', { accept: 'text/markdown' });
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/markdown'), header(r, 'content-type'));
  });

  await test('the markdown representation negotiates locale too', async () => {
    const r = await probe('/docs/quickstart-guide', { accept: 'text/markdown', cookie: 'preferred_locale=tr' });
    expect(header(r, 'content-language') === 'tr', `Content-Language ${header(r, 'content-language')}`);
  });

  await test('Accept: text/html keeps the page HTML', async () => {
    const r = await probe('/docs/quickstart-guide', { accept: 'text/html' });
    expect(header(r, 'content-type').startsWith('text/html'), header(r, 'content-type'));
  });

  await test('Accept: */* means no preference — HTML stays primary', async () => {
    const r = await probe('/docs/quickstart-guide', { accept: '*/*' });
    expect(header(r, 'content-type').startsWith('text/html'), header(r, 'content-type'));
  });

  await test('a path without llms/ falls through to HTML instead of 406', async () => {
    const r = await probe('/docs/client-applications', { accept: 'text/markdown' });
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/html'), header(r, 'content-type'));
  });

  section('4. The document — variant chain');

  await test('a real route resolves its variant', async () => {
    const r = await probe('/docs');
    expect(r.status === 200, `status ${r.status}`);
    expect(r.body.includes('lang="en"'), 'lang is not en');
  });

  await test('a trailing slash is the same page', async () => {
    const r = await probe('/docs/');
    expect(r.status === 200, `status ${r.status}`);
    expect(/<title>Phantom-WG Documentation/.test(r.body), 'did not serve the Documentation document');
  });

  await test('the full matrix resolves: g100 + tr on a subpage', async () => {
    const r = await probe('/docs/quickstart-guide', { cookie: 'preferred_theme=g100; preferred_locale=tr' });
    expect(r.body.includes('data-carbon-theme="g100"'), 'theme lost');
    expect(r.body.includes('lang="tr"'), 'locale lost');
    expect(header(r, 'content-language') === 'tr', `Content-Language ${header(r, 'content-language')}`);
  });

  section('5. SPA fallback — the application answers for unknown pages');

  await test('an unknown route is the shell, 200, revalidated', async () => {
    const r = await probe('/a-page-that-does-not-exist');
    expect(r.status === 200, `status ${r.status}`);
    expect(header(r, 'content-type').startsWith('text/html'), header(r, 'content-type'));
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
    expect(r.body.includes('id="root"'), 'shell has no root element');
  });

  await test('/index.html surfaces the platform 308, stamped no-cache', async () => {
    const r = await probe('/index.html');
    expect(r.status === 308, `status ${r.status}`);
    expect(header(r, 'cache-control') === 'no-cache', `Cache-Control ${header(r, 'cache-control')}`);
  });
}

// ── Entry ────────────────────────────────────────────────────────────────────

if (EXTERNAL) {
  log(`using the already-running server at ${BASE}`);
} else {
  log(`starting wrangler pages dev on :${PORT} …`);
  await startServer();
}

try {
  await run();
} finally {
  stopServer();
}

console.log(`\n[test-worker] ${pass} passed, ${fail} failed`);
process.exit(fail === 0 ? 0 : 1);
