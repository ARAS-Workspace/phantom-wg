import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { transformMdx } from './transform.js';
import { loadTemplate, BASE_URL, LOCALES } from './config.js';
import { log, rel } from './formatters.js';

/**
 * Options for a single generation.
 * @typedef {object} GenerateOptions
 * @property {boolean} header  Prepend the template header + coordinates (default true).
 */

/**
 * Page coordinates injected after the header.
 * @typedef {object} Coordinates
 * @property {string} path       Route, e.g. '/docs/architecture/bridge'.
 * @property {string} locale     This file's locale (from the output filename).
 * @property {string} altLocale  The other locale.
 * @property {string} altUrl     Full URL to the other-locale llms.txt.
 */

/**
 * Derive coordinates by matching the input's directory to a route via the www
 * router (lib/route-sources.js), resolved from the input's own `…/www` root.
 * Returns null when the input is not a mapped www page — the caller then omits
 * the coordinate line. The tool is intentionally coupled to www.
 *
 * @param {string} input
 * @param {string} output
 * @returns {Promise<Coordinates | null>}
 */
async function resolveCoordinates(input, output) {
  const abs = path.resolve(input);
  const idx = abs.indexOf(`${path.sep}src${path.sep}pages${path.sep}`);
  if (idx === -1) return null; // not under www/src/pages
  const wwwRoot = abs.slice(0, idx);
  const inputDir = path.dirname(abs);

  try {
    const { buildRouteMap } = await import(
      pathToFileURL(path.join(wwwRoot, 'scripts/lib/route-sources.js')).href
    );
    const map = buildRouteMap(
      path.join(wwwRoot, 'src/router/index.tsx'),
      path.join(wwwRoot, 'src/pages'),
    );
    const route = [...map].find(([, dir]) => path.resolve(dir) === inputDir)?.[0];
    if (!route) return null;

    const locale = path.basename(output, '.txt'); // en.txt → en
    const altLocale = LOCALES.find((l) => l !== locale) ?? '';
    const altUrl = `${BASE_URL}${route === '/' ? '' : route}/llms.txt?locale=${altLocale}`;
    return { path: route, locale, altLocale, altUrl };
  } catch {
    return null; // route-sources unavailable → skip coordinates
  }
}

/**
 * Fill the template. When `coords` is null the coordinate line is removed
 * entirely, leaving header + content.
 *
 * @param {string} template
 * @param {Coordinates | null} coords
 * @param {string} body
 * @returns {string}
 */
function fillTemplate(template, coords, body) {
  let out = template;
  if (coords) {
    out = out
      .replaceAll('{{path}}', coords.path)
      .replaceAll('{{locale}}', coords.locale)
      .replaceAll('{{alt_locale}}', coords.altLocale)
      .replaceAll('{{alt_url}}', coords.altUrl);
  } else {
    out = out.replace(/^\*\*path:\*\*.*(?:\r?\n){1,2}/m, '');
  }
  return out.replace('{{content}}', body);
}

/**
 * Transform one MDX file into agentic markdown and write it to `output`.
 * Parent directories are created as needed.
 *
 * @param {string} input   Path to the source .mdx file.
 * @param {string} output  Path to write the generated .txt/.md file.
 * @param {GenerateOptions} opts
 * @returns {Promise<void>}
 */
export async function generate(input, output, opts) {
  if (!existsSync(input)) {
    throw new Error(`Input not found: ${input}`);
  }

  const source = readFileSync(input, 'utf8');
  /** @type {string[]} */
  const unknown = [];
  const body = transformMdx(source, { onUnknown: (t) => unknown.push(t), sourcePath: input });

  let out = body;
  if (opts.header) {
    const coords = await resolveCoordinates(input, output);
    out = fillTemplate(loadTemplate(), coords, body).trimEnd() + '\n';
  }

  mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
  writeFileSync(output, out, 'utf8');

  log.success(`${rel(input)} → ${rel(output)}`);
  if (unknown.length) {
    log.warn(`No rule for: ${[...new Set(unknown)].join(', ')} (used fallback directive)`);
  }
}
