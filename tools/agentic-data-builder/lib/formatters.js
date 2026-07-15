// noinspection JSUnusedGlobalSymbols

import path from 'node:path';
import pc from 'picocolors';

const TAG = pc.cyan('[agentic]');

/** Namespaced console logger — one prefix, colour by severity. */
export const log = {
  /** @param {string} m */
  info: (m) => console.log(`${TAG} ${m}`),
  /** @param {string} m */
  step: (m) => console.log(`${TAG} ${pc.dim(m)}`),
  /** @param {string} m */
  success: (m) => console.log(`${TAG} ${pc.green(m)}`),
  /** @param {string} m */
  warn: (m) => console.log(`${TAG} ${pc.yellow(m)}`),
  /** @param {string} m */
  error: (m) => console.error(`${TAG} ${pc.red(m)}`),
};

/**
 * Shorten an absolute path for display, relative to the current directory.
 * @param {string} p
 * @returns {string}
 */
export function rel(p) {
  const r = path.relative(process.cwd(), p);
  return r === '' ? '.' : r;
}
