#!/usr/bin/env node
/**
 * Writes THIRD_PARTY_LICENSES from what the bundler actually emits.
 *
 * The dependency closure is the wrong inventory for this package. npm marks 257
 * packages production, because @mdx-js/rollup and the three remark plugins live
 * in dependencies and drag the whole micromark/mdast tree with them — none of
 * which reaches dist/, since MDX is compiled at build time. Vite answers the
 * real question: a build with sourcemaps on names every module that survived
 * tree-shaking, and that list is the inventory.
 *
 * So this runs its own build into a temporary directory, reads the emitted
 * sourcemaps, and never touches dist/. The real build keeps sourcemap: false.
 *
 * Nothing here decides what a licence is: each package's own package.json
 * declares it, ACCEPTED states the policy, and the run stops on a package
 * resolving to anything unlisted, on a package whose licence text cannot be
 * found and is not declared in NO_TEXT, and on a declared entry that no longer
 * applies. Neither list can drift away from what ships.
 *
 * This is NOT part of `npm run build`. It is run by hand, its output is
 * reviewed, and the reviewed file is what the build copies into dist/.
 *
 *     npm run generate-licenses
 *     npm run generate-licenses -- --check
 */

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const TARGET = path.join(ROOT, 'THIRD_PARTY_LICENSES');
const MODULES = path.join(ROOT, 'node_modules');
const RULE = '='.repeat(80);
const SUB = '-'.repeat(80);

/**
 * Licence policy. A package resolving to anything unlisted stops the run.
 * Order is not significant: no package in this graph offers a choice.
 */
const ACCEPTED = ['MIT', 'Apache-2.0', 'ISC', 'OFL-1.1'];

/**
 * The fields this script reads out of an installed package's own manifest.
 * JSON.parse returns an untyped value, so the shape is declared here.
 *
 * @typedef {object} Manifest
 * @property {string} [version]
 * @property {string} [license] the SPDX field npm documents today
 * @property {{ type?: string, url?: string }[]} [licenses] the deprecated array
 *   form, still used by a few long-unmaintained packages
 * @property {string | { url?: string }} [repository]
 */

/**
 * The one field this script reads out of a sourcemap.
 *
 * @typedef {object} SourceMap
 * @property {string[]} [sources] every module that contributed to the chunk
 */

/**
 * Build-time packages that live in dependencies on purpose: @mdx-js/rollup is
 * the Vite plugin that compiles the 28 .mdx files, and the three remark
 * plugins feed it. They are referenced only from vite.config.ts, their output
 * ships and they do not, so they are listed without a licence text.
 */
const BUILD_TIME = [
  '@mdx-js/rollup',
  'remark-frontmatter',
  'remark-gfm',
  'remark-mdx-frontmatter',
];

/**
 * Fonts arrive as .woff2 assets through @carbon/styles' SCSS, not through the
 * JavaScript module graph, so they are matched by the file names Vite emits.
 */
const FONT_PREFIX = {
  IBMPlexMono: '@ibm/plex-mono',
  IBMPlexSans: '@ibm/plex-sans',
  IBMPlexSerif: '@ibm/plex-serif',
};

/**
 * Packages that declare a licence but ship no text with it. Each needs a
 * reason; a package missing its text and missing from here stops the run
 * rather than being quietly omitted.
 */
const NO_TEXT = {
  'toggle-selection':
    'declares MIT in package.json and ships no licence file. It arrives as a ' +
    'transitive of copy-to-clipboard. The text is not reproduced here because ' +
    'the package does not provide one; the declaration is the only statement ' +
    'its author made.',
};

const HEADER = `
██████╗ ██╗  ██╗ █████╗ ███╗   ██╗████████╗ ██████╗ ███╗   ███╗
██╔══██╗██║  ██║██╔══██╗████╗  ██║╚══██╔══╝██╔═══██╗████╗ ████║
██████╔╝███████║███████║██╔██╗ ██║   ██║   ██║   ██║██╔████╔██║
██╔═══╝ ██╔══██║██╔══██║██║╚██╗██║   ██║   ██║   ██║██║╚██╔╝██║
██║     ██║  ██║██║  ██║██║ ╚████║   ██║   ╚██████╔╝██║ ╚═╝ ██║
╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝   ╚═╝    ╚═════╝ ╚═╝     ╚═╝

THIRD PARTY LICENSES
================================================================================

Phantom-WG / react-spa
Copyright (c) 2025 ARTEK İnovasyon Ar-Ge Sanayi ve Ticaret Limited Şirketi
Copyright (c) 2025 Rıza Emre ARAS <r.emrearas@proton.me>
Licensed under AGPL-3.0 - see LICENSE file for details

Maintained by: Rıza Emre ARAS <r.emrearas@proton.me>

HOW TO READ THIS FILE

  BUNDLED DEPENDENCIES is every package whose code is in the JavaScript Vite
  emits, read from the sourcemaps of a build made for this purpose. It is the
  module graph after tree-shaking, not the dependency closure: npm reports 257
  production packages for this project, and most of them are the
  micromark/mdast tree that compiles the .mdx sources at build time and never
  reaches the browser.

  FONTS is matched separately. The IBM Plex faces arrive as .woff2 assets
  through @carbon/styles' SCSS rather than through the JavaScript graph, so
  they are identified by the file names in the build output. They are the one
  part of this package that ships as upstream binaries rather than as
  transformed source.

  STYLES names the packages that produce the emitted CSS. They contribute no
  JavaScript, so the module graph does not list them.

  BUILD-TIME DEPENDENCIES are in package.json's dependencies deliberately:
  they are what compiles the .mdx content. Their output ships and they do not,
  so they are named with their licence but carry no text here.

  LICENSE TEXTS carries the text of every licence above, as the package that
  shipped it wrote it. Packages sharing a byte-identical text share an entry.
  This project's own AGPL-3.0 is not repeated; it is in LICENSE.

  This file is generated, but not by the build. Regenerate with:

      npm run generate-licenses

  ACCEPTED in tools/generate-licenses.js is the licence policy: a package
  resolving to anything unlisted stops the run before this file is written.
  npm run build copies this file into dist/ and fails if it is absent — the
  build never generates it, so what ships is always what was reviewed.
`;

const FONT_NOTE = `The faces are redistributed as the upstream .woff2 binaries, unmodified.
SIL Open Font License 1.1 permits that, and its Reserved Font Name clause
binds the names "Plex": a modified version may not be distributed under
them. Nothing here modifies the fonts.
`;

const STYLE_NOTE = `@carbon/styles is the SCSS source the emitted stylesheet is compiled from,
and @carbon/react contributes the component styles alongside its JavaScript.
The compiled CSS is a transformation of their source, so both are listed even
though only one of them appears in the module graph.
`;

function die(msg) {
  process.stderr.write(`generate-licenses: ${msg}\n`);
  process.exit(1);
}

/**
 * npm accepts several shorthands in `repository`. Normalise them all to a
 * browsable https URL so the column is one kind of thing.
 */
function normaliseRepository(value) {
  let v = value.trim();
  if (v === '') return '';
  v = v.replace(/^git\+/, '').replace(/\.git$/, '');
  const shorthand = v.match(/^(?:(github|gitlab|bitbucket):)?([\w.-]+\/[\w.-]+)$/);
  if (shorthand) {
    const host = { gitlab: 'gitlab.com', bitbucket: 'bitbucket.org' }[shorthand[1]];
    return `https://${host ?? 'github.com'}/${shorthand[2]}`;
  }
  v = v.replace(/^git:\/\//, 'https://').replace(/^ssh:\/\/git@/, 'https://');
  v = v.replace(/^git@([^:]+):/, 'https://$1/');
  return v;
}

/** Wrap a paragraph to the width the rest of the document uses. */
function wrap(text, width, indent = '') {
  const words = text.split(/\s+/).filter(Boolean);
  const lines = [];
  let line = '';
  for (const word of words) {
    if (line === '') line = word;
    else if ((indent + line + ' ' + word).length <= width) line += ' ' + word;
    else {
      lines.push(indent + line);
      line = word;
    }
  }
  if (line) lines.push(indent + line);
  return lines;
}

/** Every package name appearing under node_modules/ in a sourcemap's sources. */
function bundledPackages(outDir) {
  const assets = path.join(outDir, 'assets');
  const maps = fs.existsSync(assets)
    ? fs.readdirSync(assets).filter((f) => f.endsWith('.js.map'))
    : [];
  if (maps.length === 0) die(`no sourcemap in ${assets} — the probe build emitted none`);

  const found = new Set();
  for (const file of maps) {
    /** @type {SourceMap} */
    const map = JSON.parse(fs.readFileSync(path.join(assets, file), 'utf8'));
    for (const source of map.sources ?? []) {
      const m = source.match(/node_modules\/((?:@[^/]+\/)?[^/]+)/);
      if (m) found.add(m[1]);
    }
  }
  if (found.size === 0) die('sourcemaps name no node_modules package');
  return found;
}

/** Font packages, matched by the .woff2 file names Vite emits. */
function fontPackages(outDir) {
  const assets = path.join(outDir, 'assets');
  const files = fs.existsSync(assets)
    ? fs.readdirSync(assets).filter((f) => f.endsWith('.woff2'))
    : [];
  const found = new Map();
  for (const file of files) {
    const prefix = Object.keys(FONT_PREFIX).find((p) => file.startsWith(p));
    if (!prefix) die(`${file}: no font package matches this name`);
    const pkg = FONT_PREFIX[prefix];
    found.set(pkg, (found.get(pkg) ?? 0) + 1);
  }
  return { found, total: files.length };
}

/** Scoped packages the project's own SCSS pulls in. */
function stylePackages() {
  const found = new Set();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.scss')) {
        const text = fs.readFileSync(full, 'utf8');
        for (const m of text.matchAll(/@(?:use|import|forward)\s+['"]([^'"]+)['"]/g)) {
          const spec = m[1];
          if (!spec.startsWith('@')) continue;
          const parts = spec.split('/');
          found.add(parts.slice(0, 2).join('/'));
        }
      }
    }
  };
  walk(path.join(ROOT, 'src'));
  return found;
}

/** version, licence, repository and licence text for one installed package. */
function describe(name) {
  const dir = path.join(MODULES, name);
  const manifest = path.join(dir, 'package.json');
  if (!fs.existsSync(manifest)) die(`${name}: not installed — run npm ci first`);
  /** @type {Manifest} */
  const meta = JSON.parse(fs.readFileSync(manifest, 'utf8'));

  let licence = meta.license;
  if (!licence && Array.isArray(meta.licenses)) {
    // Deprecated form, still used by a few packages: licenses: [{type, url}]
    licence = meta.licenses.map((l) => l.type).filter(Boolean).join(' OR ');
  }
  if (typeof licence !== 'string' || licence.length === 0) {
    die(`${name}: declares no licence in package.json`);
  }
  if (!ACCEPTED.includes(licence)) {
    die(`${name}: declares ${licence}, which is not in ACCEPTED`);
  }

  let repository = meta.repository;
  if (repository && typeof repository === 'object') repository = repository.url;
  if (typeof repository !== 'string') repository = '';
  repository = normaliseRepository(repository);

  const candidate = fs
    .readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isFile() && /^(licen[cs]e|copying)/i.test(e.name))
    .map((e) => e.name)
    .sort();
  const text = candidate.length
    ? fs.readFileSync(path.join(dir, candidate[0]), 'utf8').replace(/\s+$/, '')
    : null;

  if (text === null && !(name in NO_TEXT)) {
    die(`${name}: ships no licence text and has no NO_TEXT entry`);
  }
  return { name, version: meta.version, licence, repository, text };
}

function table(head, rows) {
  const widths = head.slice(0, -1).map((_, i) =>
    Math.max(...[head, ...rows].map((r) => String(r[i]).length)),
  );
  const line = (cells) =>
    '| ' +
    cells
      .slice(0, -1)
      .map((c, i) => String(c).padEnd(widths[i]))
      .join(' | ') +
    ' | ' +
    cells[cells.length - 1];
  const divider =
    '|' + widths.map((w) => '-'.repeat(w + 2)).join('|') + '|' + '-'.repeat(12);
  return [line(head), divider, ...rows.map(line)];
}

function section(title) {
  return [RULE, title, RULE, ''];
}

function plural(n, word) {
  return `${n} ${word}${n === 1 ? '' : 's'}`;
}

function probeBuild() {
  const vite = path.join(MODULES, '.bin', 'vite');
  if (!fs.existsSync(vite)) die('vite is not installed — run npm ci first');
  const out = fs.mkdtempSync(path.join(os.tmpdir(), 'spa-licenses-'));
  process.stderr.write(`probe build → ${out}\n`);
  try {
    execFileSync(
      vite,
      ['build', '--outDir', out, '--sourcemap', '--emptyOutDir', '--logLevel', 'warn'],
      { cwd: ROOT, stdio: ['ignore', 'inherit', 'inherit'] },
    );
  } catch {
    fs.rmSync(out, { recursive: true, force: true });
    die('the probe build failed');
  }
  return out;
}

function build() {
  const out = probeBuild();
  let bundled;
  let fonts;
  try {
    bundled = bundledPackages(out);
    fonts = fontPackages(out);
  } finally {
    fs.rmSync(out, { recursive: true, force: true });
  }

  const fontNames = [...fonts.found.keys()].sort();
  const styleNames = [...stylePackages()]
    .filter((n) => !bundled.has(n) || n === '@carbon/react')
    .sort();

  for (const n of BUILD_TIME) {
    if (bundled.has(n)) die(`${n}: listed as build-time but its code is in the bundle`);
  }

  const bundledNames = [...bundled].sort((a, b) => a.localeCompare(b));
  const described = new Map();
  for (const n of [...bundledNames, ...fontNames, ...styleNames, ...BUILD_TIME]) {
    if (!described.has(n)) described.set(n, describe(n));
  }

  for (const n of Object.keys(NO_TEXT)) {
    if (!described.has(n)) die(`NO_TEXT names ${n}, which is no longer in the graph`);
  }

  const out_ = [HEADER];

  out_.push(
    ...section(`BUNDLED DEPENDENCIES — ${plural(bundledNames.length, 'package')}`),
    ...table(
      ['Package', 'Version', 'License', 'Repository'],
      bundledNames.map((n) => {
        const d = described.get(n);
        return [d.name, d.version, d.licence, d.repository || '—'];
      }),
    ),
    '',
  );

  out_.push(
    ...section(
      `FONTS — ${plural(fontNames.length, 'package')}, ${fonts.total} files`,
    ),
    ...table(
      ['Package', 'Version', 'License', 'Files in the build'],
      fontNames.map((n) => {
        const d = described.get(n);
        return [d.name, d.version, d.licence, String(fonts.found.get(n))];
      }),
    ),
    '',
    FONT_NOTE,
  );

  out_.push(
    ...section('STYLES'),
    ...table(
      ['Package', 'Version', 'License', 'Repository'],
      styleNames.map((n) => {
        const d = described.get(n);
        return [d.name, d.version, d.licence, d.repository || '—'];
      }),
    ),
    '',
    STYLE_NOTE,
  );

  out_.push(
    ...section(
      `BUILD-TIME DEPENDENCIES — ${plural(BUILD_TIME.length, 'package')}, not bundled`,
    ),
    ...table(
      ['Package', 'Version', 'License', 'Repository'],
      [...BUILD_TIME].sort().map((n) => {
        const d = described.get(n);
        return [d.name, d.version, d.licence, d.repository || '—'];
      }),
    ),
    '',
  );

  // Licence texts, deduplicated by content. Build-time packages are named
  // above but ship no text here: their code is not redistributed.
  const shipped = [...new Set([...bundledNames, ...fontNames, ...styleNames])].sort();
  const byText = new Map();
  const noText = [];
  for (const n of shipped) {
    const d = described.get(n);
    if (d.text === null) {
      noText.push(d);
      continue;
    }
    const key = `${d.licence}\u0000${d.text}`;
    if (!byText.has(key)) byText.set(key, { licence: d.licence, text: d.text, users: [] });
    byText.get(key).users.push(d.name);
  }
  const texts = [...byText.values()].sort(
    (a, b) =>
      a.licence.localeCompare(b.licence) || a.users[0].localeCompare(b.users[0]),
  );

  out_.push(...section(`LICENSE TEXTS — ${plural(texts.length, 'text')}`));
  for (const t of texts) {
    out_.push(SUB, `${t.licence} — ${t.users.sort().join(', ')}`, SUB, '', t.text, '');
  }

  if (noText.length) {
    out_.push(...section(`DECLARED WITHOUT A TEXT — ${plural(noText.length, 'package')}`));
    for (const d of noText) {
      out_.push(
        `${d.name} ${d.version}, ${d.licence}`,
        '',
        ...wrap(NO_TEXT[d.name], 78, '  '),
        '',
      );
    }
  }

  return out_.join('\n').replace(/\n+$/, '\n');
}

function main() {
  const check = process.argv.includes('--check');
  const doc = build();

  if (check) {
    const current = fs.existsSync(TARGET) ? fs.readFileSync(TARGET, 'utf8') : '';
    if (current !== doc) {
      process.stderr.write('THIRD_PARTY_LICENSES is stale\n');
      process.exit(1);
    }
    process.stderr.write('THIRD_PARTY_LICENSES is current\n');
    return;
  }

  fs.writeFileSync(TARGET, doc, 'utf8');
  process.stderr.write(
    `THIRD_PARTY_LICENSES: ${doc.split('\n').length} lines, ` +
      `${Buffer.byteLength(doc)} bytes\n`,
  );
}

main();
