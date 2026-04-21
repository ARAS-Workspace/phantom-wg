import { Command } from 'commander';
import { loadEnv } from './config.js';
import { uploadCommand } from './commands/upload.js';
import { listCommand } from './commands/list.js';
import { infoCommand } from './commands/info.js';
import { deleteCommand } from './commands/delete.js';
import { configCommand } from './commands/config.js';

/**
 * Parse argv and dispatch to the chosen command.
 * @param {string[]} argv
 */
export async function run(argv) {
  // Load secrets/.env into process.env before anything that needs creds.
  // Env vars already set in the shell win over file values — see dotenv.
  loadEnv();

  const program = new Command();
  program
    .name('phantom-stream-tool')
    .description('Cloudflare Stream ops CLI for Phantom-WG')
    .version('0.1.0', '-v, --version');

  program.addCommand(uploadCommand());
  program.addCommand(listCommand());
  program.addCommand(infoCommand());
  program.addCommand(deleteCommand());
  program.addCommand(configCommand());

  await program.parseAsync(argv);
}
