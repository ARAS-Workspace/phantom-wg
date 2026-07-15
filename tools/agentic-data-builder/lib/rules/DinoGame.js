// Rule (descriptive): <DinoGame /> → a hand-authored description. The component
// is a playable mini-game (Chrome-dino style) with no textual content to
// extract, so the rule simply explains what occupies this area.

/** @typedef {import('../types.js').RuleProps} RuleProps */

/**
 * @param {RuleProps} _props
 * @returns {string}
 */
export function rule(_props) {
  return '> [Interactive] A playable mini-game (Chrome-dino style). Visual/interactive content with no textual equivalent.';
}
