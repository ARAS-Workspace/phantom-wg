// Central JSDoc typedefs for agentic-data-builder. No runtime code lives here.
// Reference via `@typedef {import('../types.js').Name} Name` in consuming files.

/**
 * A prop value extracted from an MDX JSX attribute.
 * - `string`          → literal attribute (`prop="x"`)
 * - `true`            → boolean attribute (`prop`)
 * - `{ expression }`  → JS expression attribute (`prop={…}`), raw source text
 *
 * @typedef {string | true | { expression: string }} RulePropValue
 */

/**
 * The props object handed to a component rule: attribute name → value.
 * @typedef {Record<string, RulePropValue>} RuleProps
 */

/**
 * A component rule: turns a component's props into agentic Markdown text.
 * `node` is the raw mdast JSX node; `context` carries the transform's
 * imports / exports / resolve for data rules (import-following, exported
 * literals). Both are optional.
 * @typedef {(props: RuleProps, node?: object, context?: object) => string} RuleFn
 */
