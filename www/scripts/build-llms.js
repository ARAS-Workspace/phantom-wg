#!/usr/bin/env node
// noinspection JSUnusedGlobalSymbols

/**
 * Copy each page's committed `llms/` directory into the built `dist/` output at
 * its route path, so the CF worker can serve `/…/llms.txt` as static text.
 * Runs after prerender in `npm run prod`. Route ↔ page directory comes from the
 * router (lib/route-sources.js).
 *
 * Usage: node scripts/build-llms.js   (requires dist/ — run the build first)
 */

import { existsSync, readdirSync, mkdirSync, copyFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildRouteMap } from './lib/route-sources.js';

const WWW = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const DIST = path.join(WWW, 'dist');
const log = (msg) => console.log(`[llms] ${msg}`);

if (!existsSync(DIST)) {
  console.error('[llms] dist/ not found — run the build first');
  process.exit(1);
}

const routeMap = buildRouteMap(path.join(WWW, 'src/router/index.tsx'), path.join(WWW, 'src/pages'));

let copied = 0;
/** @type {string[]} */
const missing = [];

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
  for (const f of files) copyFileSync(path.join(src, f), path.join(dest, f));
  copied += files.length;
}

log(`Copied ${copied} file(s) across ${routeMap.size - missing.length} page(s).`);
if (missing.length) log(`No llms/: ${missing.join(', ')}`);
