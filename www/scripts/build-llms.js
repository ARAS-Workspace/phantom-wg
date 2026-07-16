#!/usr/bin/env node
// noinspection JSUnusedGlobalSymbols

/**
 * Copy each page's committed `llms/` directory into the built `dist/` output at
 * its route path, then concatenate those pages into `dist/llms-full/<locale>.txt`
 * — so the CF worker can serve both `/…/llms.txt` and `/llms-full.txt` as static
 * text. Runs after prerender in `npm run prod`.
 *
 * `llms-full.txt` is a build artefact, not a committed file: it is a pure,
 * deterministic concatenation of the committed per-page `llms/` files, the same
 * way `robots.txt` and `sitemap.xml` are generated into `dist/` by prerender.js.
 * Route ↔ page directory comes from the router (lib/route-sources.js); locales
 * and the production URL come from the prerender config — the single sources the
 * rest of the pipeline already uses.
 *
 * Usage: node scripts/build-llms.js   (requires dist/ — run the build first)
 */

import { existsSync, readdirSync, mkdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import yaml from 'js-yaml';
import { buildRouteMap } from './lib/route-sources.js';

const WWW = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST = path.join(WWW, 'dist');
const CONFIG_PATH = path.join(WWW, 'scripts/utils/prerender-utility/config.yaml');
const log = (msg) => console.log(`[llms] ${msg}`);

if (!existsSync(DIST)) {
  console.error('[llms] dist/ not found — run the build first');
  process.exit(1);
}

const config = yaml.load(readFileSync(CONFIG_PATH, 'utf8'));
const BASE_URL = config.production_url.replace(/\/$/, '');
const LOCALES = config.locales;

// Page boundary. Not `---`: the pages themselves use that as a horizontal rule
// (96 times across the corpus), so it cannot mark a section break unambiguously.
// A long rule is still a markdown HR, occurs nowhere in the content, and splits
// cleanly on /^-{4,}$/.
const SEPARATOR = '-'.repeat(80);

/**
 * Drop a page's leading notice blockquote. It is identical in every page file,
 * so in a concatenation it would repeat once per page; the header carries it
 * once instead. The `**path:**` coordinate line that follows is kept — it is
 * what tells the reader which page a section came from.
 *
 * @param {string} text
 * @returns {string}
 */
function stripNotice(text) {
  const lines = text.split('\n');
  let i = 0;
  while (i < lines.length && lines[i].startsWith('>')) i++;
  while (i < lines.length && lines[i].trim() === '') i++;
  return lines.slice(i).join('\n').trim();
}

/**
 * @param {string} locale
 * @returns {string}
 */
function fullHeader(locale) {
  const others = LOCALES.filter((l) => l !== locale)
    .map((l) => `**${l}:** ${BASE_URL}/llms-full.txt?locale=${l}`)
    .join(' · ');
  return [
    '# Phantom-WG',
    '',
    '> **Full documentation — every page in a single file.**',
    '>',
    '> **EN:** Every page of the Phantom-WG documentation, concatenated from each',
    "> page's `llms.txt`. Pages are separated by a full-width `-----` rule and each",
    '> one opens with the `path:` coordinate it came from — a plain `---` inside a',
    '> page is that page\'s own horizontal rule, not a page break. Interactive',
    '> components (diagrams, players, API explorers, simulators) are replaced by',
    '> their source data or a short directive — read those as data pointers, not',
    '> missing content.',
    '>',
    '> **TR:** Phantom-WG dokümantasyonunun her sayfası, ilgili sayfanın `llms.txt`',
    '> dosyasından birleştirildi. Sayfalar tam genişlikte `-----` çizgisiyle ayrılır',
    '> ve her biri geldiği sayfanın `path:` koordinatıyla başlar — sayfa içindeki',
    '> düz `---` o sayfanın kendi yatay çizgisidir, sayfa ayracı değildir.',
    '> İnteraktif bileşenler (diyagram, oynatıcı, API gezgini, simülasyon) kaynak',
    '> verisiyle veya kısa bir direktifle değiştirildi — eksik içerik değil, veri',
    '> işaretçisi olarak okuyun.',
    '',
    `**locale:** ${locale} · ${others}`,
  ].join('\n');
}

const routeMap = buildRouteMap(path.join(WWW, 'src/router/index.tsx'), path.join(WWW, 'src/pages'));

let copied = 0;
/** @type {string[]} */
const missing = [];
/** @type {Record<string, string[]>} */
const sections = Object.fromEntries(LOCALES.map((l) => [l, []]));

for (const [route, dir] of [...routeMap].sort((a, b) => a[0].localeCompare(b[0]))) {
  const src = path.join(dir, 'llms');
  const files = existsSync(src) ? readdirSync(src).filter((f) => f.endsWith('.txt')) : [];
  if (files.length === 0) {
    missing.push(route);
    continue;
  }
  // route '/' → dist/llms/ ; '/docs/architecture/bridge' → dist/docs/architecture/bridge/llms/
  const dest = path.join(DIST, route.replace(/^\//, ''), 'llms');
  mkdirSync(dest, { recursive: true });
  for (const f of files) {
    copyFileSync(path.join(src, f), path.join(dest, f));
    const locale = path.basename(f, '.txt');
    if (sections[locale]) sections[locale].push(stripNotice(readFileSync(path.join(src, f), 'utf8')));
  }
  copied += files.length;
}

log(`Copied ${copied} file(s) across ${routeMap.size - missing.length} page(s).`);
if (missing.length) log(`No llms/: ${missing.join(', ')}`);

// llms-full — one file per locale, in the same route order as the copy pass
const fullDir = path.join(DIST, 'llms-full');
mkdirSync(fullDir, { recursive: true });
for (const locale of LOCALES) {
  const parts = sections[locale];
  if (parts.length === 0) continue;
  const out = `${fullHeader(locale)}\n\n${SEPARATOR}\n\n${parts.join(`\n\n${SEPARATOR}\n\n`)}\n`;
  writeFileSync(path.join(fullDir, `${locale}.txt`), out, 'utf8');
  log(`llms-full/${locale}.txt — ${parts.length} page(s), ${(out.length / 1024).toFixed(1)} KB`);
}
