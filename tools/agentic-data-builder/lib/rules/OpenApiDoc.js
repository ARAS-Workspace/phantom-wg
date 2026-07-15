// Rule (asset-reference): <OpenApiDoc /> → a directive pointing at the
// machine-readable OpenAPI definition. It is already the canonical machine
// format, so we reference it rather than inline ~68 KB of spec.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * @param {RuleProps} _props
 * @returns {string}
 */
export function rule(_props) {
  return '> API reference — machine-readable OpenAPI definition: `/openapi.json`';
}
