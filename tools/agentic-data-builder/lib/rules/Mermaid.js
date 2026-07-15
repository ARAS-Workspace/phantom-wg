// Rule (mechanical): <Mermaid chart={`…`} /> → a fenced ```mermaid block.
//
// The `chart` prop is a static template literal across the docs (no `${}`
// interpolation), so we unwrap it to its cooked source without evaluating it.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * Strip the surrounding backticks of a template-literal expression and resolve
 * its escape sequences to the cooked string value. Assumes no `${}` interpolation.
 *
 * @param {string} raw
 * @returns {string}
 */
function unwrapTemplateLiteral(raw) {
  let s = raw.trim();
  if (s.startsWith('`') && s.endsWith('`')) s = s.slice(1, -1);
  return s.replace(/\\([\s\S])/g, (_, ch) => {
    switch (ch) {
      case 'n':
        return '\n';
      case 't':
        return '\t';
      case 'r':
        return '\r';
      case '`':
        return '`';
      case '$':
        return '$';
      case '\\':
        return '\\';
      default:
        return ch;
    }
  });
}

/**
 * @param {RuleProps} props
 * @returns {string}
 */
export function rule(props) {
  const chart = props.chart;
  const raw = chart && typeof chart === 'object' ? chart.expression : String(chart ?? '');
  const source = unwrapTemplateLiteral(raw).trim();
  return '```mermaid\n' + source + '\n```';
}
