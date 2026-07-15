// Rule: <FormulaInfo formulas={<exportedArray>} /> → each formula as a bold
// formula/title header plus a `symbol | description` table, one under another.
// The `formulas` value is an `export const` array literal in the same MDX; the
// rule reads it from the transform context's exports (parsed from the ESTree).

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * @param {{ formula?: string, title?: string, symbols?: Array<{symbol: string, description: string}>, summary?: string }} f
 * @returns {string}
 */
function formatFormula(f) {
  // Escape pipes (and flatten newlines) so cell content can't break the table.
  const cell = (s) => String(s).replace(/\|/g, '\\|').replace(/\n+/g, ' ');
  const lines = [];
  if (f.formula) lines.push(`**formula:** \`${f.formula}\``);
  if (f.title) lines.push(`**title:** ${f.title}`);
  if (Array.isArray(f.symbols) && f.symbols.length) {
    lines.push('', '| symbol | description |', '| --- | --- |');
    for (const s of f.symbols) lines.push(`| \`${cell(s.symbol)}\` | ${cell(s.description)} |`);
  }
  if (f.summary) lines.push('', f.summary);
  return lines.join('\n');
}

/**
 * @param {RuleProps} props
 * @param {object} _node
 * @param {{ exports?: Map<string, unknown> }} [context]
 * @returns {string}
 */
export function rule(props, _node, context) {
  const id = props.formulas && typeof props.formulas === 'object' ? props.formulas.expression.trim() : '';
  const formulas = context?.exports?.get(id);
  if (!Array.isArray(formulas) || formulas.length === 0) {
    return '> [FormulaInfo] formula definitions — see the live page.';
  }
  return formulas.map(formatFormula).join('\n\n');
}
