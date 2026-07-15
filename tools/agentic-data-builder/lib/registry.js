// noinspection JSUnusedGlobalSymbols

import { rule as Mermaid } from './rules/Mermaid.js';
import { rule as AsciinemaPlayer } from './rules/AsciinemaPlayer.js';
import { rule as OpenApiDoc } from './rules/OpenApiDoc.js';
import { rule as DinoGame } from './rules/DinoGame.js';
import { rule as ContentTabs } from './rules/ContentTabs.js';
import { rule as InlineNotification } from './rules/InlineNotification.js';
import { rule as FormulaInfo } from './rules/FormulaInfo.js';
import { rule as PhantomHLSPlayer } from './rules/PhantomHLSPlayer.js';

/**
 * Component tag → rule. This is the whole extension surface: to teach the
 * builder about a component, add a rule module and one entry here.
 * @type {Record<string, import('./types.js').RuleFn>}
 */
const REGISTRY = {
  Mermaid,
  AsciinemaPlayer,
  OpenApiDoc,
  DinoGame,
  ContentTabs,
  InlineNotification,
  FormulaInfo,
  PhantomHLSPlayer,
};

/**
 * Look up the rule for a JSX tag, or `null` when none is registered.
 * @param {string} tag
 * @returns {import('./types.js').RuleFn | null}
 */
export function getRule(tag) {
  // Member tags (e.g. `DinoGame.Lazy`) fall back to their base component's rule.
  return REGISTRY[tag] ?? REGISTRY[tag.split('.')[0]] ?? null;
}

/**
 * The set of component tags that currently have a rule.
 * @returns {string[]}
 */
export function knownTags() {
  return Object.keys(REGISTRY);
}
