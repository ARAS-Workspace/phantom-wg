// Rule (import-following): <ContentTabs tabs={[{ label, content: <Imported> }]} />
// → each tab's imported MDX content, transformed and separated. The `content`
// values are imported component identifiers; the rule follows them through the
// transform context (context.resolve), which reads + transforms the imported
// MDX file relative to the source page.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/** Match `{ label: '…', content: Identifier }` entries in the tabs array. */
const TAB_RE = /{\s*label:\s*['"]([^'"]+)['"]\s*,\s*content:\s*([A-Za-z_$][\w$]*)\s*}/g;

/**
 * @param {RuleProps} props
 * @param {object} _node
 * @param {{ resolve?: (id: string) => string | null }} [context]
 * @returns {string}
 */
export function rule(props, _node, context) {
  const expr = props.tabs && typeof props.tabs === 'object' ? props.tabs.expression : '';
  const tabs = [...String(expr).matchAll(TAB_RE)].map((m) => ({ label: m[1], content: m[2] }));
  if (tabs.length === 0) {
    return '> [ContentTabs] tabbed content — see the live page.';
  }

  const sections = tabs.map(({ label, content }) => {
    const md = context?.resolve?.(content) ?? null;
    return `**Tab: ${label}**\n\n${md || '_(tab content unavailable)_'}`;
  });
  return sections.join('\n\n---\n\n');
}
