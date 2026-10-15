#!/usr/bin/env node
/**
 * Copies LICENSE and THIRD_PARTY_LICENSES into dist/ at the end of the build.
 *
 * dist/ is what travels. It is gitignored, the production compose mounts it
 * into nginx, and the release workflow copies it wholesale into the published
 * package (tools/lib/helpers/packager.py lists services/react-spa/dist). So
 * putting the notices inside dist/ is what makes them reach whoever holds the
 * artifact, by either path, with no change anywhere else.
 *
 * This does not generate anything. THIRD_PARTY_LICENSES is produced by
 * `npm run generate-licenses`, reviewed, and committed; if it is missing the
 * build stops here rather than shipping a dist without notices.
 *
 *     node tools/copy-licenses.js
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const DIST = path.join(ROOT, 'dist');
const FILES = ['LICENSE', 'THIRD_PARTY_LICENSES'];

function die(msg) {
  process.stderr.write(`copy-licenses: ${msg}\n`);
  process.exit(1);
}

if (!fs.existsSync(DIST) || !fs.statSync(DIST).isDirectory()) {
  die('dist/ does not exist — run this after vite build');
}

const missing = FILES.filter((f) => !fs.existsSync(path.join(ROOT, f)));
if (missing.length) {
  die(
    `${missing.join(' and ')} missing from the repository. ` +
      'THIRD_PARTY_LICENSES is written by `npm run generate-licenses` and ' +
      'committed after review; the build does not generate it.',
  );
}

for (const name of FILES) {
  const from = path.join(ROOT, name);
  const to = path.join(DIST, name);
  fs.copyFileSync(from, to);
  process.stderr.write(`copy-licenses: ${name} → dist/ (${fs.statSync(to).size} bytes)\n`);
}
