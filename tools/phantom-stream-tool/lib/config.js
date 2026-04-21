import {
  existsSync,
  readFileSync,
  writeFileSync,
  mkdirSync,
  chmodSync,
} from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const TOOL_ROOT = path.resolve(__dirname, '..');
const SECRETS_DIR = path.join(TOOL_ROOT, 'secrets');
const ENV_PATH = path.join(SECRETS_DIR, '.env');

const REQUIRED_KEYS = ['CLOUDFLARE_API_TOKEN', 'CLOUDFLARE_ACCOUNT_ID'];
const OPTIONAL_KEYS = ['CLOUDFLARE_CUSTOMER_SUBDOMAIN'];
const ALL_KEYS = [...REQUIRED_KEYS, ...OPTIONAL_KEYS];

/**
 * Load secrets/.env into process.env if the file exists.
 * dotenv does not override values already set in the shell, so env > file.
 *
 * @returns {void}
 */
export function loadEnv() {
  if (existsSync(ENV_PATH)) {
    dotenv.config({ path: ENV_PATH });
  }
}

/**
 * Resolve a config value. Flag wins, then env (possibly loaded from file).
 * Returns null when no source has a non-empty value.
 *
 * @param {string} key
 * @param {string|undefined} [overrideFlag]
 * @returns {string|null}
 */
export function resolve(key, overrideFlag) {
  if (overrideFlag != null && overrideFlag !== '') return overrideFlag;
  const v = process.env[key];
  if (v != null && v !== '') return v;
  return null;
}

/**
 * Like `resolve`, but throws a user-facing error listing every way the
 * value can be provided when no source has a non-empty value.
 *
 * @param {string} key
 * @param {string|undefined} [overrideFlag]
 * @returns {string}
 */
export function requireValue(key, overrideFlag) {
  const v = resolve(key, overrideFlag);
  if (v == null) {
    const flag = toKebab(key);
    throw new Error(
      `Missing ${key}.\n` +
        `  • Run: phantom-stream-tool config set ${flag}=<value>\n` +
        `  • Or pass: --${flag} <value>\n` +
        `  • Or export: ${key}=<value>`,
    );
  }
  return v;
}

/**
 * Parse secrets/.env into a plain object; empty object if file missing.
 *
 * @returns {Record<string, string>}
 */
export function readConfig() {
  if (!existsSync(ENV_PATH)) return {};
  return dotenv.parse(readFileSync(ENV_PATH, 'utf8'));
}

/**
 * Merge the given updates into secrets/.env (creates dir/file as needed).
 * Rewrites the whole file so entries stay deterministic. Mode 0600.
 *
 * @param {Record<string, string>} updates
 * @returns {void}
 */
export function writeConfig(updates) {
  mkdirSync(SECRETS_DIR, { recursive: true });
  const current = readConfig();
  const merged = { ...current, ...updates };
  const orderedKeys = [
    ...ALL_KEYS.filter((k) => k in merged),
    ...Object.keys(merged).filter((k) => !ALL_KEYS.includes(k)),
  ];
  const contents =
    orderedKeys
      .filter((k) => merged[k] != null && merged[k] !== '')
      .map((k) => `${k}=${merged[k]}`)
      .join('\n') + '\n';
  writeFileSync(ENV_PATH, contents, { mode: 0o600 });
  try {
    chmodSync(ENV_PATH, 0o600);
  } catch {
    // Non-POSIX filesystems may reject chmod; not fatal.
  }
  // Reload so the current process observes the new values.
  loadEnv();
}

/**
 * Return the canonical list of known credential keys (required + optional).
 *
 * @returns {string[]}
 */
export function listAllKeys() {
  return [...ALL_KEYS];
}

/**
 * Normalize a kebab-case CLI key (e.g. `api-token`) into the canonical
 * env-variable form (e.g. `CLOUDFLARE_API_TOKEN`). Keys already prefixed
 * with `CLOUDFLARE_` pass through unchanged.
 *
 * @param {string} kebab
 * @returns {string}
 */
export function kebabToEnvKey(kebab) {
  const upper = kebab.trim().toUpperCase().replace(/-/g, '_');
  if (upper.startsWith('CLOUDFLARE_')) return upper;
  return `CLOUDFLARE_${upper}`;
}

/**
 * Inverse of `kebabToEnvKey` — drop the `CLOUDFLARE_` prefix and kebab-case
 * the remainder. Used only for crafting user-facing suggestions in errors.
 *
 * @param {string} envKey
 * @returns {string}
 */
function toKebab(envKey) {
  return envKey.toLowerCase().replace(/_/g, '-').replace(/^cloudflare-/, '');
}
