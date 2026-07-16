// Rule (asset-reference): <OpenApiDoc /> → a directive pointing at the
// machine-readable OpenAPI definition. It is already the canonical machine
// format, so we reference it rather than inline ~68 KB of spec.

import { BASE_URL } from '../config.js';

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * The URL is absolute on purpose: this text is read standalone (and concatenated
 * into llms-full), so a bare `/openapi.json` would leave the reader guessing the
 * host instead of fetching the spec.
 *
 * @param {RuleProps} _props
 * @returns {string}
 */
export function rule(_props) {
  return `> API reference — machine-readable OpenAPI definition: \`${BASE_URL}/openapi.json\``;
}
