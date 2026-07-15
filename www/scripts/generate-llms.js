#!/usr/bin/env node
// noinspection JSUnusedGlobalSymbols

/**
 * Generate `llms/{en,tr}.txt` for every MDX page by running the
 * agentic-data-builder tool on each page's `index.mdx` / `index.en.mdx`.
 * Route → page directory comes from the router (lib/route-sources.js). Pages
 * with no MDX source (manual pages) are skipped. Re-run whenever page MDX or
 * the builder's rules change; `scripts/build-llms.js` then copies the result
 * into `dist/`.
 *
 * Usage: node scripts/generate-llms.js
 */

import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { buildRouteMap } from './lib/route-sources.js';

const WWW = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TOOL = path.resolve(WWW, '..', 'tools', 'agentic-data-builder', 'bin', 'agentic-data-builder.js');
const log = (m) => console.log(`[gen-llms] ${m}`);

/** Source MDX → output file, per locale. */
const LOCALES = [
  { input: 'index.mdx', output: 'llms/tr.txt' },
  { input: 'index.en.mdx', output: 'llms/en.txt' },
];

if (!existsSync(TOOL)) {
  console.error(`[gen-llms] tool not found: ${TOOL}`);
  process.exit(1);
}

const routes = [...buildRouteMap(path.join(WWW, 'src/router/index.tsx'), path.join(WWW, 'src/pages'))].sort(
  (a, b) => a[0].localeCompare(b[0]),
);

let generated = 0;
let pages = 0;
/** @type {string[]} */
const skipped = [];
/** @type {Set<string>} */
const fallback = new Set();

for (const [route, dir] of routes) {
  let any = false;
  for (const { input, output } of LOCALES) {
    const inPath = path.join(dir, input);
    if (!existsSync(inPath)) continue;
    const stdout = execFileSync('node', [TOOL, inPath, path.join(dir, output)], { encoding: 'utf8' });
    for (const m of stdout.matchAll(/No rule for: ([^\n(]+)/g)) {
      for (const tag of m[1].split(',')) fallback.add(tag.trim());
    }
    generated += 1;
    any = true;
  }
  if (any) {
    pages += 1;
    log(route);
  } else {
    skipped.push(route);
  }
}

log(`Generated ${generated} file(s) across ${pages} page(s).`);
if (fallback.size) log(`Components left on fallback: ${[...fallback].sort().join(', ')}`);
if (skipped.length) log(`No MDX (manual pages, skipped): ${skipped.join(', ')}`);
