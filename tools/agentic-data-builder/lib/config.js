import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

/** Absolute path to the tool root (…/tools/agentic-data-builder). */
export const TOOL_ROOT = path.resolve(__dirname, '..');

/** Absolute path to the template prepended to every generated file. */
export const TEMPLATE_PATH = path.join(TOOL_ROOT, 'template.md');

/** Canonical site base URL — used for the coordinate alternate-locale link. */
export const BASE_URL = 'https://www.phantom.tc';

/** Supported locales; the unsuffixed file is the default (en). */
export const LOCALES = ['en', 'tr'];

/**
 * Read the template. Returns an empty string when the file is absent, so
 * `--no-header` and a missing template behave the same.
 * @returns {string}
 */
export function loadTemplate() {
  if (!existsSync(TEMPLATE_PATH)) return '';
  return readFileSync(TEMPLATE_PATH, 'utf8');
}
