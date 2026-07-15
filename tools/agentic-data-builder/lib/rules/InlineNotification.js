// Rule: <InlineNotification kind title subtitle /> → a GitHub-style alert
// carrying the notification's text. `title` + `subtitle` are primary content
// (notes, warnings, callouts) that the fallback directive would otherwise lose —
// this component is used ~30× across the docs.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/** Carbon `kind` → GitHub alert type. */
const ALERT = {
  info: 'NOTE',
  'info-square': 'NOTE',
  success: 'TIP',
  warning: 'WARNING',
  'warning-alt': 'WARNING',
  error: 'CAUTION',
};

/**
 * @param {RuleProps} props
 * @returns {string}
 */
export function rule(props) {
  const kind = typeof props.kind === 'string' ? props.kind : 'info';
  const title = typeof props.title === 'string' ? props.title : '';
  const subtitle = typeof props.subtitle === 'string' ? props.subtitle : '';

  const lines = [`> [!${ALERT[kind] ?? 'NOTE'}]`];
  if (title) lines.push(`> **${title}**`);
  if (subtitle) lines.push(`> ${subtitle}`);
  return lines.join('\n');
}
