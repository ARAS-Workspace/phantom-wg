// noinspection JSValidateTypes

import { Command } from 'commander';
import { generate } from './generate.js';

/**
 * Parse argv and run the single-file generator:
 *   agentic-data-builder [options] <input> <output>
 *
 * Batch orchestration lives in the www prerender pipeline, not here.
 *
 * @param {string[]} argv
 * @returns {Promise<void>}
 */
export async function run(argv) {
  const program = new Command();
  program
    .name('agentic-data-builder')
    .description('Generate LLM-friendly markdown from docs MDX sources')
    .version('1.0.0', '-v, --version')
    .argument('<input>', 'Path to the source .mdx file')
    .argument('<output>', 'Path to write the generated .txt/.md file')
    .option('--no-header', 'Do not prepend the bilingual template header')
    .action(
      /**
       * @param {string} input
       * @param {string} output
       * @param {{ header: boolean }} opts
       * @returns {void}
       */
      (input, output, opts) => generate(input, output, opts),
    );

  await program.parseAsync(argv);
}
