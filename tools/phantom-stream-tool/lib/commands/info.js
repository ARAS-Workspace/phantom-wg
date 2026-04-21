import { Command } from 'commander';
import ora from 'ora';
import pc from 'picocolors';
import { createClient } from '../cf-stream.js';
import { formatUUID, formatJSON, formatVideoDetails } from '../formatters.js';

/**
 * Options parsed from the `info` sub-command.
 *
 * @typedef {object} InfoOptions
 * @property {"details"|"uuid"|"json"} [output]    Output format (default `details`).
 * @property {string}                  [apiToken]  Override CLOUDFLARE_API_TOKEN.
 * @property {string}                  [accountId] Override CLOUDFLARE_ACCOUNT_ID.
 */

const ALLOWED_OUTPUT = ['details', 'uuid', 'json'];

/**
 * Build the `info <uuid>` sub-command — fetches a single video and prints
 * human-readable details, the UID alone, or the raw API response.
 *
 * @returns {Command}
 */
export function infoCommand() {
  return new Command('info')
    .description('Get info about a specific video')
    .argument('<uuid>', 'Video UID')
    .option('--output <format>', `Output format: ${ALLOWED_OUTPUT.join(' | ')}`, 'details')
    .option('--api-token <token>', 'Override CLOUDFLARE_API_TOKEN')
    .option('--account-id <id>', 'Override CLOUDFLARE_ACCOUNT_ID')
    .action(
      /**
       * @param {string}      uuid
       * @param {InfoOptions} opts
       * @returns {Promise<void>}
       */
      async (uuid, opts) => {
        if (!opts.output || !ALLOWED_OUTPUT.includes(opts.output)) {
          throw new Error(
            `Invalid --output: ${opts.output}. Use one of: ${ALLOWED_OUTPUT.join(', ')}.`,
          );
        }

        const spinner = ora(`Fetching ${uuid}…`).start();
        const client = createClient({
          apiToken: opts.apiToken,
          accountId: opts.accountId,
        });

        let response;
        try {
          response = await client.getVideo(uuid);
        } catch (err) {
          spinner.fail(pc.red('Info fetch failed'));
          throw err;
        }
        spinner.stop();

        const video = response.result;
        if (opts.output === 'json') {
          console.log(formatJSON(video));
        } else if (opts.output === 'uuid') {
          console.log(formatUUID(video.uid));
        } else {
          console.log(formatVideoDetails(video));
        }
      },
    );
}
