import { Command } from 'commander';
import ora from 'ora';
import pc from 'picocolors';
import { createClient } from '../cf-stream.js';
import { formatJSON, formatTable } from '../formatters.js';

/**
 * Options parsed from the `list` sub-command. Filter fields map 1-to-1 onto
 * Cloudflare Stream list query parameters (see README → Options Reference).
 *
 * @typedef {object} ListOptions
 * @property {"table"|"json"}                            [output]    Output format (`--output`, default `table`).
 * @property {string}                                    [search]    Fuzzy match against video name.
 * @property {"ready"|"inprogress"|"queued"|"error"}     [status]    Filter by encoding state.
 * @property {string}                                    [creator]   Filter by creator identifier.
 * @property {string}                                    [before]    ISO-8601 — created before.
 * @property {string}                                    [after]     ISO-8601 — created after.
 * @property {boolean}                                   [asc]       Sort ascending by creation time.
 * @property {string}                                    [limit]     Max results (parsed to number).
 * @property {string}                                    [apiToken]  Override CLOUDFLARE_API_TOKEN.
 * @property {string}                                    [accountId] Override CLOUDFLARE_ACCOUNT_ID.
 */

const ALLOWED_STATUS = ['ready', 'inprogress', 'queued', 'error'];

/**
 * Build the `list` sub-command — lists videos in the account, optionally
 * filtered by the query parameters supported by the Cloudflare Stream API.
 *
 * @returns {Command}
 */
export function listCommand() {
  return new Command('list')
    .description('List videos in the Cloudflare Stream account')
    .option('--output <format>', 'Output format: table | json', 'table')
    .option('--search <query>', 'Fuzzy match against video name')
    .option('--status <state>', `Filter by status (${ALLOWED_STATUS.join(' | ')})`)
    .option('--creator <id>', 'Filter by creator identifier')
    .option('--before <iso>', 'Created before ISO-8601 timestamp')
    .option('--after <iso>', 'Created after ISO-8601 timestamp')
    .option('--asc', 'Sort ascending by creation time')
    .option('--limit <n>', 'Maximum number of results (CF cap: 1000)')
    .option('--api-token <token>', 'Override CLOUDFLARE_API_TOKEN')
    .option('--account-id <id>', 'Override CLOUDFLARE_ACCOUNT_ID')
    .action(
      /**
       * @param {ListOptions} opts
       * @returns {Promise<void>}
       */
      async (opts) => {
        if (opts.output !== 'table' && opts.output !== 'json') {
          throw new Error(`Invalid --output: ${opts.output}. Use 'table' or 'json'.`);
        }
        if (opts.status && !ALLOWED_STATUS.includes(opts.status)) {
          throw new Error(
            `Invalid --status: ${opts.status}. Use one of: ${ALLOWED_STATUS.join(', ')}.`,
          );
        }

        let limit;
        if (opts.limit != null) {
          limit = Number(opts.limit);
          if (!Number.isInteger(limit) || limit < 1) {
            throw new Error('--limit must be a positive integer.');
          }
        }

        const spinner = ora('Fetching videos…').start();
        const client = createClient({
          apiToken: opts.apiToken,
          accountId: opts.accountId,
        });

        let response;
        try {
          response = await client.listVideos({
            search: opts.search,
            status: opts.status,
            creator: opts.creator,
            before: opts.before,
            after: opts.after,
            asc: opts.asc,
            limit,
          });
        } catch (err) {
          spinner.fail(pc.red('List failed'));
          throw err;
        }
        spinner.stop();

        const videos = response.result ?? [];
        if (opts.output === 'json') {
          console.log(formatJSON(videos));
        } else {
          if (videos.length === 0) {
            console.log(pc.dim('No videos found.'));
            return;
          }
          console.log(formatTable(videos));
          console.log();
          console.log(pc.dim(`${videos.length} video(s)`));
        }
      },
    );
}
