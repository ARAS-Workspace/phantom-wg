import { Command } from 'commander';
import readline from 'node:readline/promises';
import { stdin, stdout } from 'node:process';
import ora from 'ora';
import pc from 'picocolors';
import { createClient } from '../cf-stream.js';

/**
 * Options parsed from the `delete` sub-command.
 *
 * @typedef {object} DeleteOptions
 * @property {boolean} [yes]        Skip the confirmation prompt (`-y, --yes`).
 * @property {string}  [apiToken]   Override CLOUDFLARE_API_TOKEN for this call.
 * @property {string}  [accountId]  Override CLOUDFLARE_ACCOUNT_ID for this call.
 */

/**
 * Build the `delete <uuid>` sub-command — removes a single video from
 * Cloudflare Stream, prompting for confirmation unless `--yes` is passed.
 *
 * @returns {Command}
 */
export function deleteCommand() {
  return new Command('delete')
    .description('Delete a video from Cloudflare Stream')
    .argument('<uuid>', 'Video UID to delete')
    .option('-y, --yes', 'Skip confirmation prompt')
    .option('--api-token <token>', 'Override CLOUDFLARE_API_TOKEN')
    .option('--account-id <id>', 'Override CLOUDFLARE_ACCOUNT_ID')
    .action(
      /**
       * @param {string}        uuid
       * @param {DeleteOptions} opts
       * @returns {Promise<void>}
       */
      async (uuid, opts) => {
        if (!opts.yes) {
          const rl = readline.createInterface({ input: stdin, output: stdout });
          const answer = await rl.question(
            `Delete video ${pc.yellow(uuid)}? [y/N] `,
          );
          rl.close();
          if (!/^y(es)?$/i.test(answer.trim())) {
            console.log(pc.dim('Cancelled.'));
            return;
          }
        }

        const spinner = ora(`Deleting ${uuid}…`).start();
        const client = createClient({
          apiToken: opts.apiToken,
          accountId: opts.accountId,
        });

        try {
          await client.deleteVideo(uuid);
        } catch (err) {
          spinner.fail(pc.red('Delete failed'));
          throw err;
        }

        spinner.succeed(pc.green(`Deleted ${uuid}`));
      },
    );
}
