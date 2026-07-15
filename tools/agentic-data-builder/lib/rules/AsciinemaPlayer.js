// Rule (asset-reference): <AsciinemaPlayer src="/…​.cast" /> → a short directive
// naming the recording and pointing at its source cast file ("at this src, this
// exists"). The raw .cast JSON is noise for an LLM, so we link rather than inline.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * @param {RuleProps} props
 * @returns {string}
 */
export function rule(props) {
  const src = typeof props.src === 'string' ? props.src : '';
  const title = typeof props.title === 'string' ? props.title : 'Terminal recording (asciinema)';
  return src
    ? `> ${title} — source cast: \`${src}\``
    : `> ${title} — interactive terminal recording (see the live page).`;
}
